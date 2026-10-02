//! Bounded inbound owner cycle. A successful receive is not an outbound sync
//! acknowledgement. Every failure drops the checkpoint; the next cycle recovers
//! from disk before another request or primary read.
use crate::{
    cloud::{self, BoundTransport, Cursor, ServerRecord},
    crypto::RootKey,
    inbound::Feed,
    journal::{self, Checkpoint, Confirmed, Scope},
    merge,
    model::Library,
    primary,
};
pub type RemoteResult<T> = std::result::Result<T, cloud::Failure>;

pub struct Observation {
    pub scope: Scope,
    pub feed: Feed,
}
pub struct FetchedPage {
    pub observation: Observation,
    pub records: Vec<ServerRecord>,
    pub cursor: Cursor,
    pub full_snapshot: bool,
    pub has_more: bool,
}
/// The credential owner also validates the current local session around every
/// awaited HTTP operation through `Owner::validate_session`.
pub trait Remote {
    fn preflight(&mut self) -> RemoteResult<Observation>;
    fn fetch(&mut self, cursor: Option<&Cursor>) -> RemoteResult<FetchedPage>;
}
impl Remote for BoundTransport {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        BoundTransport::preflight(self)?;
        Ok(Observation {
            scope: self.checkpoint_scope(),
            feed: self.feed().map_err(|_| cloud::Failure::InvalidResponse)?,
        })
    }
    fn fetch(&mut self, cursor: Option<&Cursor>) -> RemoteResult<FetchedPage> {
        let page = self.fetch_page(cursor)?;
        Ok(FetchedPage {
            observation: Observation {
                scope: self.checkpoint_scope(),
                feed: self.feed().map_err(|_| cloud::Failure::InvalidResponse)?,
            },
            records: page.records,
            cursor: page.cursor,
            full_snapshot: page.full_snapshot,
            has_more: page.has_more,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Remote(cloud::Failure),
    ScopeReview,
    InvalidPage,
    Journal(journal::Failure),
    Primary(primary::Failure),
    SessionChanged,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<journal::Failure> for Failure {
    fn from(value: journal::Failure) -> Self {
        Self::Journal(value)
    }
}
impl From<primary::Failure> for Failure {
    fn from(value: primary::Failure) -> Self {
        if value == primary::Failure::AuthorizationExpired {
            Self::SessionChanged
        } else {
            Self::Primary(value)
        }
    }
}
impl From<crate::model::Error> for Failure {
    fn from(_: crate::model::Error) -> Self {
        Self::InvalidPage
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// The received feed is current; says nothing about outbound offers.
    Current,
    MorePages,
    LocalReview,
    ConflictReview,
    VaultLocked,
    IncompatibleVault,
    SnapshotReview,
    DeletionReview,
    PrimaryChanged,
    SendFirst,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Progress {
    pub status: Status,
    pub received_records: usize,
    pub applied_records: usize,
    pub completed_pages: usize,
}
pub struct Owner<'a> {
    pub library: &'a Library,
    pub scope: &'a Scope,
    pub key_epoch: u64,
    pub checkpoint_key: &'a RootKey,
    pub checkpoint_salt: &'a [u8; 32],
    pub wire_key: &'a RootKey,
    pub wire_salt: &'a [u8; 32],
    /// Native callers reserve the installation clock only after admission.
    pub device: Option<&'a str>,
    /// Borrowed only for an explicitly authenticated, revocable bounded cycle.
    pub vault_keys: Option<&'a crate::materializer::Keyring<'a>>,
    pub validate_session: &'a dyn Fn() -> Result<()>,
}
impl Owner<'_> {
    pub(crate) fn prepare_primary(
        &self,
        journal: &crate::journal::Journal,
        device: &str,
        outcome: &crate::merge::Outcome,
        expected: &primary::ReadSet,
    ) -> Result<primary::Prepared> {
        (self.validate_session)()?;
        let result = if let Some(keys) = self.vault_keys {
            primary::prepare_authenticated(
                self.library,
                journal,
                device,
                std::slice::from_ref(outcome),
                expected,
                keys,
            )
        } else {
            primary::prepare(
                self.library,
                journal,
                device,
                std::slice::from_ref(outcome),
                expected,
            )
        };
        (self.validate_session)()?;
        Ok(result?)
    }
    pub(crate) fn check_publication(&self) -> primary::Result<()> {
        (self.validate_session)().map_err(|_| primary::Failure::AuthorizationExpired)
    }
    pub(crate) fn verify(&self, observation: &Observation) -> Result<()> {
        if &observation.scope != self.scope || observation.feed.key_epoch != self.key_epoch {
            return Err(Failure::ScopeReview);
        }
        observation.feed.validate()?;
        Ok(())
    }
    pub(crate) fn preflight(&self, remote: &mut impl Remote) -> Result<Observation> {
        (self.validate_session)()?;
        let observation = remote.preflight().map_err(Failure::Remote)?;
        (self.validate_session)()?;
        self.verify(&observation)?;
        Ok(observation)
    }
    fn save(&self, checkpoint: &mut Checkpoint, fault: &mut Fault) -> Result<()> {
        fault.before_save()?;
        checkpoint.save(self.library, self.checkpoint_key, self.checkpoint_salt)?;
        fault.after_save()
    }
    pub fn receive(&self, remote: &mut impl Remote, max_pages: usize) -> Result<Progress> {
        self.receive_inner(remote, max_pages, &mut Fault::default())
    }
    fn receive_inner(
        &self,
        remote: &mut impl Remote,
        max_pages: usize,
        fault: &mut Fault,
    ) -> Result<Progress> {
        if !(1..=8).contains(&max_pages) {
            return Err(Failure::InvalidPage);
        }
        let mut observed = self.preflight(remote)?;
        // Verified account/dataset/key ownership precedes recovery and primary reads.
        let mut checkpoint = primary::recover_checked(
            &self.library.root,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
            |journal| {
                if journal
                    .key_epoch
                    .is_some_and(|epoch| epoch != self.key_epoch)
                    || journal
                        .outbound
                        .as_ref()
                        .is_some_and(|p| p.key_epoch != self.key_epoch)
                    || journal
                        .inbox
                        .feed
                        .as_ref()
                        .is_some_and(|f| f.key_epoch != self.key_epoch)
                {
                    return Err(primary::Failure::RecoveryRequired);
                }
                Ok(())
            },
        )?;
        let mut progress = Progress {
            status: Status::MorePages,
            received_records: 0,
            applied_records: 0,
            completed_pages: 0,
        };
        if checkpoint.journal.inbox.needs_review() {
            progress.status = Status::SnapshotReview;
            return Ok(progress);
        }
        if checkpoint
            .journal
            .outbound
            .as_ref()
            .is_some_and(|p| !p.acknowledged())
        {
            progress.status = Status::SendFirst;
            return Ok(progress);
        }
        (self.validate_session)()?;
        let device = match self.device {
            Some(device) => device.to_owned(),
            None => {
                let _guard = self
                    .library
                    .lock()
                    .map_err(|_| Failure::Journal(journal::Failure::Storage))?;
                primary::require_ready(&self.library.root)
                    .map_err(|_| Failure::Primary(primary::Failure::RecoveryRequired))?;
                let known = checkpoint.journal.projection_knowledge();
                let floor = known
                    .values()
                    .chain(checkpoint.journal.projected().values())
                    .map(|e| &e.hlc)
                    .max();
                crate::clock::stamp(
                    &self.library.root,
                    floor,
                    chrono::Utc::now().timestamp_millis().max(0) as u64,
                )
                .map_err(|_| Failure::Journal(journal::Failure::Storage))?
                .device()
                .to_owned()
            }
        };
        for page_index in 0..max_pages {
            if page_index > 0 {
                observed = self.preflight(remote)?;
            }
            if !checkpoint.journal.inbox.has_pending_page() {
                let missing_epoch = checkpoint.journal.key_epoch.is_none();
                checkpoint.journal.key_epoch = Some(self.key_epoch);
                if checkpoint
                    .journal
                    .inbox
                    .select_feed(observed.feed.clone())?
                    || missing_epoch
                {
                    self.save(&mut checkpoint, fault)?;
                }
                let cursor = checkpoint.journal.inbox.cursor().cloned();
                (self.validate_session)()?;
                let fetched = remote.fetch(cursor.as_ref());
                (self.validate_session)()?;
                match fetched {
                    Err(cloud::Failure::Server {
                        code: cloud::ErrorCode::CursorInvalid,
                        ..
                    }) if cursor.is_some() => {
                        self.preflight(remote)?;
                        checkpoint.journal.inbox.restart_snapshot()?;
                        self.save(&mut checkpoint, fault)?;
                        return Ok(progress); // bounded retry in the next explicit cycle
                    }
                    Err(failure) => return Err(Failure::Remote(failure)),
                    Ok(page) => {
                        self.verify(&page.observation)?;
                        let after = self.preflight(remote)?;
                        if page.observation.feed != observed.feed || after.feed != observed.feed {
                            // Never publish a cursor from a different feed, even if
                            // the dataset and wire key remain unchanged.
                            if checkpoint.journal.inbox.select_feed(after.feed)? {
                                self.save(&mut checkpoint, fault)?;
                            }
                            return Ok(progress);
                        }
                        let mut records =
                            Vec::with_capacity(page.records.len().min(crate::inbound::PAGE_LIMIT));
                        if page.records.len() > crate::inbound::PAGE_LIMIT {
                            return Err(Failure::InvalidPage);
                        }
                        for record in page.records {
                            let (wire, record_version) = record.into_parts();
                            let envelope = wire
                                .open(self.wire_key, self.wire_salt)
                                .map_err(|_| Failure::InvalidPage)?;
                            merge::validate(&envelope).map_err(|_| Failure::InvalidPage)?;
                            records.push(Confirmed {
                                envelope,
                                record_version,
                            });
                        }
                        let received = records.len();
                        checkpoint.journal.inbox.receive(
                            &observed.feed,
                            cursor.as_ref(),
                            records,
                            page.cursor,
                            page.full_snapshot,
                            page.has_more,
                        )?;
                        // Page and fetched cursor share one authenticated atomic write.
                        self.save(&mut checkpoint, fault)?;
                        progress.received_records += received;
                    }
                }
            }
            while let Some(remote_record) = checkpoint.journal.inbox.next().cloned() {
                (self.validate_session)()?;
                let id = remote_record.envelope.id;
                // A tombstone cannot satisfy a retained original-copy delivery.
                // Review it even when a newer local copy wins the merge or the
                // physical copy is absent; only the native choice can stage repair.
                if remote_record.envelope.deleted && checkpoint.journal.is_preservation_copy(id) {
                    progress.status = Status::DeletionReview;
                    return Ok(progress);
                }
                let current = primary::current(self.library, &checkpoint.journal, &device)?;
                // Absent known live primary can be an unjournaled local deletion.
                // A future explicit absence boundary will stamp it; never resurrect.
                if !current.contains_key(&id)
                    && !checkpoint.journal.known_absence(id)
                    && [
                        checkpoint.journal.projected().get(&id),
                        checkpoint.journal.confirmed(id).map(|c| &c.envelope),
                        checkpoint.journal.entry(id).map(|e| &e.desired),
                    ]
                    .into_iter()
                    .flatten()
                    .any(|e| !e.deleted)
                {
                    progress.status = Status::LocalReview;
                    return Ok(progress);
                }
                let outcome = merge::merge(
                    checkpoint.journal.merge_ancestor(id),
                    checkpoint.journal.local_intent(id, current.get(&id))?,
                    Some(&remote_record.envelope),
                )
                .map_err(|_| Failure::InvalidPage)?;
                if outcome.survivor.as_ref().is_some_and(|e| e.deleted)
                    && let Some(physical) = current.get(&id)
                    && !checkpoint.journal.primary_deletion_approved(
                        outcome.survivor.as_ref().ok_or(Failure::InvalidPage)?,
                        physical,
                    )?
                {
                    progress.status = Status::DeletionReview;
                    return Ok(progress);
                }
                let mut secure_unit = false;
                for e in outcome.survivor.iter().chain(&outcome.conflict_copies) {
                    let variants = merge::secure_variants(e).map_err(|_| Failure::InvalidPage)?;
                    secure_unit |= e.secure || !variants.is_empty();
                }
                let expected =
                    primary::preservation_read_set(std::slice::from_ref(&outcome), &current)?;
                let prepared =
                    self.prepare_primary(&checkpoint.journal, &device, &outcome, &expected)?;
                let status = if !prepared.incompatible_ids.is_empty() {
                    Some(Status::IncompatibleVault)
                } else if !prepared.deferred_ids.is_empty() {
                    Some(if secure_unit {
                        Status::VaultLocked
                    } else {
                        Status::ConflictReview
                    })
                } else if !prepared.retry_ids.is_empty() {
                    Some(Status::PrimaryChanged)
                } else {
                    None
                };
                if let Some(status) = status {
                    progress.status = status;
                    return Ok(progress);
                }
                (self.validate_session)()?;
                match primary::commit_checked(
                    self.library,
                    &mut checkpoint,
                    self.checkpoint_key,
                    self.checkpoint_salt,
                    prepared,
                    &|| self.check_publication(),
                ) {
                    Err(primary::Failure::StalePrimary) => {
                        progress.status = Status::PrimaryChanged;
                        return Ok(progress);
                    }
                    result => result?,
                }
                fault.after_primary()?;
                // Preserve merged/local survivors and losing copies, then confirm
                // the remote generation. Offers retain their original CAS ancestor.
                for e in outcome.survivor.into_iter().chain(outcome.conflict_copies) {
                    checkpoint.journal.desire(e)?;
                }
                checkpoint
                    .journal
                    .record_confirmed(remote_record.envelope, remote_record.record_version)?;
                checkpoint.journal.inbox.acknowledge_record()?;
                self.save(&mut checkpoint, fault)?;
                progress.applied_records += 1;
            }
            let has_more = checkpoint.journal.inbox.page_has_more();
            checkpoint.journal.inbox.complete_page()?;
            let known = checkpoint.journal.agreed_envelopes();
            checkpoint
                .journal
                .inbox
                .finish_snapshot(known.keys().copied())?;
            self.save(&mut checkpoint, fault)?;
            progress.completed_pages += 1;
            if checkpoint.journal.inbox.needs_review() {
                progress.status = Status::SnapshotReview;
                return Ok(progress);
            }
            if checkpoint.journal.inbox.feed.as_ref() != Some(&observed.feed) {
                checkpoint
                    .journal
                    .inbox
                    .select_feed(observed.feed.clone())?;
                self.save(&mut checkpoint, fault)?;
                return Ok(progress);
            }
            if !has_more {
                progress.status = Status::Current;
                return Ok(progress);
            }
        }
        Ok(progress)
    }
}

// Test-only failures model uncertain durability. Production has no injected I/O.
#[derive(Default)]
struct Fault {
    #[cfg(test)]
    saves: usize,
    #[cfg(test)]
    save: Option<(usize, bool)>,
    #[cfg(test)]
    primary: bool,
}
impl Fault {
    fn before_save(&mut self) -> Result<()> {
        #[cfg(test)]
        {
            self.saves += 1;
            if self.save == Some((self.saves, false)) {
                return Err(Failure::Journal(journal::Failure::Storage));
            }
        }
        Ok(())
    }
    fn after_save(&mut self) -> Result<()> {
        #[cfg(test)]
        if self.save == Some((self.saves, true)) {
            return Err(Failure::Journal(journal::Failure::Storage));
        }
        Ok(())
    }
    fn after_primary(&mut self) -> Result<()> {
        #[cfg(test)]
        if self.primary {
            return Err(Failure::Primary(primary::Failure::RecoveryRequired));
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "receiver_tests.rs"]
mod tests;
