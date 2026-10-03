//! One-record deletion/restore decisions. Only native confirmation can create
//! a checkpoint-local exact-hash permit; remote userDeletion extensions cannot.
//! Decision, receipt position and primary images publish through the same WAL.
use crate::{
    cloud::RecordVersion,
    inbound::Feed,
    journal::{self, Checkpoint, Journal, ReviewAncestor},
    merge, primary,
    receiver::{self, Owner, Remote},
    snapshot_review::{self, check_epoch},
    wire::Envelope,
};
use uuid::Uuid;

#[path = "deletion_sources.rs"]
mod sources;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    LocalAbsence,
    CloudDeletion,
    PendingDeletion,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    Delete,
    Keep,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Data(receiver::Failure),
    Unavailable,
    MissingFile,
    Changed,
    PreservationRequired,
    VaultLocked,
    IncompatibleVault,
    RestoreUnavailable,
    SendPending,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<receiver::Failure> for Failure {
    fn from(v: receiver::Failure) -> Self {
        Self::Data(v)
    }
}
impl From<primary::Failure> for Failure {
    fn from(v: primary::Failure) -> Self {
        match v {
            primary::Failure::VaultLocked => Self::VaultLocked,
            primary::Failure::IncompatibleVault => Self::IncompatibleVault,
            primary::Failure::StalePrimary => Self::Changed,
            other => Self::Data(receiver::Failure::Primary(other)),
        }
    }
}
impl From<journal::Failure> for Failure {
    fn from(v: journal::Failure) -> Self {
        Self::Data(receiver::Failure::Journal(v))
    }
}
impl From<crate::model::Error> for Failure {
    fn from(_: crate::model::Error) -> Self {
        Self::Data(receiver::Failure::InvalidPage)
    }
}
impl From<snapshot_review::Failure> for Failure {
    fn from(v: snapshot_review::Failure) -> Self {
        match v {
            snapshot_review::Failure::Data(v) => Self::Data(v),
            _ => Self::Changed,
        }
    }
}
// Metadata for the explicit review dialog only; no diagnostic/Debug surface.
#[derive(Clone)]
pub struct Summary {
    pub kind: Kind,
    pub name: String,
    pub keyword: String,
    pub secure: bool,
    pub can_keep: bool,
    pub keep_requires_vault: bool,
    pub delete_requires_vault: bool,
    pub preserved_source_versions: usize,
    pub restored_conflict_copies: usize,
    pub preserved_conflict_copies: usize,
    pub prerequisite: bool,
}
enum Source {
    Local,
    Pending(Envelope),
    Inbound(Envelope, RecordVersion),
    Outbound(Envelope, RecordVersion),
}
pub struct Review {
    root: std::path::PathBuf,
    checkpoint: Checkpoint,
    snapshot: primary::Snapshot,
    device: String,
    feed: Feed,
    id: Uuid,
    live: Option<Envelope>,
    source: Source,
    repair: Option<crate::journal::PreservationRepair>,
    materialize: bool,
    source_versions: Vec<Envelope>,
    missing_originals: Vec<Uuid>,
    current_sources: Vec<Envelope>,
    prerequisite_sources: Vec<Envelope>,
    summary: Summary,
}
impl Review {
    pub fn summary(&self) -> Summary {
        self.summary.clone()
    }
}
fn retained_live<'a>(
    journal: &'a Journal,
    current: Option<&'a Envelope>,
    id: Uuid,
) -> Option<&'a Envelope> {
    let previous = journal.entry(id).and_then(|e| match &e.review {
        ReviewAncestor::Reviewed { previous_merge, .. } => previous_merge.as_deref(),
        _ => None,
    });
    [
        current,
        journal.entry(id).map(|e| &e.desired),
        journal
            .deletion_approvals
            .get(&id)
            .and_then(|a| a.ancestor.as_ref()),
        journal.projected().get(&id),
        journal.confirmed(id).map(|c| &c.envelope),
        previous,
        journal.preservation_original(id),
    ]
    .into_iter()
    .flatten()
    .find(|e| !e.deleted)
}
fn requires_remote_delete(
    journal: &Journal,
    snapshot: &primary::Snapshot,
    e: &Envelope,
) -> Result<bool> {
    if !e.deleted {
        return Ok(false);
    }
    if journal.is_preservation_copy(e.id) {
        return Ok(true);
    }
    if retained_live(journal, snapshot.records.get(&e.id), e.id)
        .is_some_and(|live| merge::has_unresolved(Some(live)))
    {
        return Ok(true);
    }
    if !snapshot.records.contains_key(&e.id) {
        return Ok(false);
    }
    let outcome = merge::merge(
        journal.merge_ancestor(e.id),
        journal.local_intent(e.id, snapshot.records.get(&e.id))?,
        Some(e),
    )
    .map_err(|_| Failure::PreservationRequired)?;
    Ok(outcome.survivor.is_some_and(|e| e.deleted))
}
fn missing_source(journal: &Journal, id: Uuid) -> Source {
    journal
        .entry(id)
        .map(|entry| &entry.desired)
        .filter(|e| e.deleted)
        .map(|e| Source::Pending(e.clone()))
        .unwrap_or(Source::Local)
}
fn candidate(
    journal: &Journal,
    snapshot: &primary::Snapshot,
    owner: &Owner<'_>,
) -> Result<(Uuid, Source)> {
    if let Some(packet) = &journal.outbound
        && let Some(crate::outbound::Receipt::Conflict { wire, version }) = packet
            .receipts
            .as_ref()
            .and_then(|r| r.get(packet.position))
    {
        let e = wire.open(owner.wire_key, owner.wire_salt)?;
        if requires_remote_delete(journal, snapshot, &e)? {
            return Ok((e.id, Source::Outbound(e, version.clone())));
        }
    }
    if let Some(record) = journal.inbox.next()
        && requires_remote_delete(journal, snapshot, &record.envelope)?
    {
        if journal.outbound.as_ref().is_some_and(|packet| {
            packet.receipts.is_some()
                && packet.offers[packet.position..]
                    .iter()
                    .any(|offer| offer.wire.id == record.envelope.id)
        }) {
            return Err(Failure::SendPending);
        }
        return Ok((
            record.envelope.id,
            Source::Inbound(record.envelope.clone(), record.record_version.clone()),
        ));
    }
    for e in journal
        .projection_knowledge()
        .values()
        .chain(journal.projected().values())
    {
        if !e.deleted && !snapshot.records.contains_key(&e.id) && !journal.known_absence(e.id) {
            return Ok((e.id, missing_source(journal, e.id)));
        }
    }
    for variant in journal.unmaterialized_variants()? {
        if !snapshot.records.contains_key(&variant.copy_id)
            && !journal.known_absence(variant.copy_id)
        {
            return Ok((variant.copy_id, missing_source(journal, variant.copy_id)));
        }
    }
    // Preserve a prepared tombstone's original wire bytes and generation.
    if let Some(packet) = &journal.outbound
        && packet.receipts.is_none()
    {
        for offer in &packet.offers {
            if offer.offered.envelope.deleted {
                return Ok((
                    offer.wire.id,
                    Source::Pending(offer.offered.envelope.clone()),
                ));
            }
        }
    }
    for e in journal.pending()? {
        if e.deleted {
            return Ok((e.id, Source::Pending(e)));
        }
    }
    // A reviewed deletion can wait behind C0/source acknowledgements. Keeping
    // it must remain available before that tombstone becomes sendable.
    for e in journal.projection_knowledge().values() {
        if e.deleted && journal.entry(e.id).is_some_and(|entry| entry.desired == *e) {
            return Ok((e.id, Source::Pending(e.clone())));
        }
    }
    Err(Failure::Unavailable)
}
impl Owner<'_> {
    pub fn prepare_deletion_review(&self, remote: &mut impl Remote) -> Result<Review> {
        self.prepare_deletion_review_inner(remote, true)
    }
    fn prepare_deletion_review_inner(
        &self,
        remote: &mut impl Remote,
        follow_prerequisites: bool,
    ) -> Result<Review> {
        let observed = self.review_preflight(remote)?;
        let checkpoint = primary::recover_checked(
            &self.library.root,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
            |j| check_epoch(j, self.key_epoch),
        )?;
        let device = self.local_device(&checkpoint)?;
        let snapshot = {
            let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
            primary::snapshot_locked(self.library, &checkpoint.journal, &device)?
        };
        let (mut id, mut source) = candidate(&checkpoint.journal, &snapshot, self)?;
        let initial = id;
        let mut visited = std::collections::BTreeSet::new();
        let mut prerequisite_sources = Vec::new();
        loop {
            (self.validate_session)()?;
            if !visited.insert(id) {
                return Err(Failure::PreservationRequired);
            }
            if prerequisite_sources.is_empty() && !checkpoint.journal.is_preservation_copy(id) {
                prerequisite_sources =
                    sources::find_prerequisite_sources(&checkpoint.journal, &snapshot.records, id)?;
            }
            let live = retained_live(&checkpoint.journal, snapshot.records.get(&id), id).cloned();
            let current_sources = if let Some(live) = &live
                && merge::has_unresolved(Some(live))
            {
                sources::current_group(&checkpoint.journal, &snapshot.records, live)?
            } else {
                Vec::new()
            };
            let materialize = !current_sources.is_empty()
                || !prerequisite_sources.is_empty()
                || (checkpoint.journal.dependency_owns(id)
                    && !checkpoint.journal.preservation_materialized(id)?);
            let variant = checkpoint
                .journal
                .unmaterialized_variants()?
                .into_iter()
                .find(|v| v.copy_id == id)
                .or(sources::prerequisite_variant(&prerequisite_sources, id)?);
            let source_versions = if materialize {
                sources::versions(&checkpoint.journal, id, live.as_ref())?
            } else {
                Vec::new()
            };
            let frames = checkpoint.journal.preservation_generations(id)?;
            let mut identities = sources::identities(&source_versions)?;
            let mut current_copies = std::collections::BTreeSet::new();
            for source in &current_sources {
                for v in
                    merge::secure_variants(source).map_err(|_| Failure::PreservationRequired)?
                {
                    current_copies.insert(v.copy_id);
                    identities.push((v.copy_id, v.source_id, v.fingerprint));
                }
            }
            for frame in &frames {
                for (source, copies) in &frame.sources {
                    for copy in copies {
                        let p = merge::provenance(copy).ok_or(Failure::PreservationRequired)?;
                        identities.push((copy.id, p.source_id, p.fingerprint));
                    }
                    for v in
                        merge::secure_variants(source).map_err(|_| Failure::PreservationRequired)?
                    {
                        identities.push((v.copy_id, v.source_id, v.fingerprint));
                    }
                }
            }
            let mut missing_originals = std::collections::BTreeSet::new();
            for (copy_id, source_id, fingerprint) in identities {
                if snapshot
                    .records
                    .get(&copy_id)
                    .is_some_and(|e| !merge::matching_provenance(e, source_id, &fingerprint))
                {
                    return Err(primary::Failure::ReservedCollision.into());
                }
                if materialize
                    && (checkpoint.journal.is_preservation_source(id)
                        || !current_sources.is_empty())
                    && copy_id != id
                    && (checkpoint.journal.is_preservation_copy(copy_id)
                        || current_copies.contains(&copy_id))
                    && !snapshot.records.contains_key(&copy_id)
                    && !checkpoint.journal.known_absence(copy_id)
                {
                    missing_originals.insert(copy_id);
                }
            }
            if let Some(variant) = &variant
                && snapshot.records.get(&id).is_some_and(|e| {
                    !merge::matching_provenance(e, variant.source_id, &variant.fingerprint)
                })
            {
                return Err(primary::Failure::ReservedCollision.into());
            }
            if matches!(source, Source::Local)
                && live.as_ref().map_or_else(
                    || variant.is_none() || !snapshot.has_file(true),
                    |e| !snapshot.has_file(e.secure),
                )
            {
                return Err(Failure::MissingFile);
            }
            let repair = if !materialize
                && matches!(source, Source::Inbound(..) | Source::Outbound(..))
                && let Some(retained) = &live
            {
                checkpoint
                    .journal
                    .deletion_repair(id, &snapshot.records, retained)?
            } else {
                None
            };
            let repair_requires_vault = repair.as_ref().is_some_and(|r| r.needs_vault());
            let kind = match &source {
                Source::Local => Kind::LocalAbsence,
                Source::Pending(_) => Kind::PendingDeletion,
                _ => Kind::CloudDeletion,
            };
            let fields = live.as_ref().and_then(|e| e.fields.as_ref());
            let copy_name = variant
                .as_ref()
                .map(crate::materializer::copy_display_name)
                .transpose()
                .map_err(primary::Failure::from)?;
            let secure = live.as_ref().map_or_else(
                || {
                    if variant.is_some() {
                        true
                    } else {
                        match &source {
                            Source::Pending(e) | Source::Inbound(e, _) | Source::Outbound(e, _) => {
                                e.secure
                            }
                            _ => false,
                        }
                    }
                },
                |e| e.secure,
            );
            let summary = Summary {
                kind,
                name: fields
                    .map(|f| f.name.clone())
                    .or(copy_name)
                    .unwrap_or_else(|| "Deleted snippet".into()),
                keyword: fields.map(|f| f.keyword.clone()).unwrap_or_default(),
                secure,
                can_keep: (live.is_some() || variant.is_some())
                    && (!secure || snapshot.has_file(true)),
                keep_requires_vault: materialize
                    || repair_requires_vault
                    || live.as_ref().is_some_and(|e| {
                        e.secure
                            && (e.extensions.contains_key(merge::COPY_PROVENANCE)
                                || !e.extensions.contains_key("vaultKID"))
                    }),
                delete_requires_vault: materialize || repair_requires_vault,
                preserved_source_versions: source_versions.len(),
                restored_conflict_copies: missing_originals.len(),
                preserved_conflict_copies: current_copies.len(),
                prerequisite: id != initial,
            };
            if follow_prerequisites
                && let Some(deleted) = missing_originals.iter().find_map(|id| {
                    checkpoint
                        .journal
                        .entry(*id)
                        .map(|entry| &entry.desired)
                        .filter(|e| e.deleted)
                })
            {
                // A parent's preservation review cannot approve this child's own
                // tombstone. Offer that exact independent decision first, using
                // the same frozen checkpoint/primary view. No receipt is consumed.
                id = deleted.id;
                source = Source::Pending(deleted.clone());
                prerequisite_sources = if checkpoint.journal.dependency_owns(id) {
                    Vec::new()
                } else {
                    current_sources.clone()
                };
                continue;
            }
            let after = self.review_preflight(remote)?;
            if after.feed != observed.feed {
                return Err(Failure::Changed);
            }
            return Ok(Review {
                root: self.library.root.clone(),
                checkpoint,
                snapshot,
                device,
                feed: observed.feed,
                id,
                live,
                source,
                repair,
                materialize,
                source_versions,
                missing_originals: missing_originals.into_iter().collect(),
                current_sources,
                prerequisite_sources,
                summary,
            });
        }
    }
    pub fn decide_deletion_review(
        &self,
        remote: &mut impl Remote,
        review: Review,
        choice: Choice,
    ) -> Result<Kind> {
        self.decide_deletion_inner(remote, review, choice, None)
    }
    pub fn decide_deletion_review_with_vault(
        &self,
        remote: &mut impl Remote,
        review: Review,
        choice: Choice,
        vault: Option<&mut crate::vault::Vault>,
    ) -> Result<Kind> {
        self.decide_deletion_authenticated(remote, review, choice, vault, None)
    }
    fn decide_deletion_inner(
        &self,
        remote: &mut impl Remote,
        review: Review,
        choice: Choice,
        fault: Option<u8>,
    ) -> Result<Kind> {
        self.decide_deletion_authenticated(remote, review, choice, None, fault)
    }
    fn decide_deletion_authenticated(
        &self,
        remote: &mut impl Remote,
        mut review: Review,
        choice: Choice,
        mut vault: Option<&mut crate::vault::Vault>,
        fault: Option<u8>,
    ) -> Result<Kind> {
        if review.root != self.library.root || review.checkpoint.journal.scope() != self.scope {
            return Err(receiver::Failure::ScopeReview.into());
        }
        check_epoch(&review.checkpoint.journal, self.key_epoch)?;
        let observed = self.review_preflight(remote)?;
        if observed.feed != review.feed {
            return Err(Failure::Changed);
        }
        {
            let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
            let saved = Checkpoint::load_locked(
                self.library,
                self.checkpoint_key,
                self.checkpoint_salt,
                self.scope.clone(),
            )?;
            check_epoch(&saved.journal, self.key_epoch)?;
            if !saved.same_snapshot(&review.checkpoint)
                || primary::snapshot_locked(self.library, &saved.journal, &review.device)?
                    != review.snapshot
            {
                return Err(Failure::Changed);
            }
        }
        let mut next = review.checkpoint.journal.clone();
        next.key_epoch = Some(self.key_epoch);
        let mut source_copies = Vec::new();
        let mut group = None;
        if review.materialize {
            let vault = vault.as_deref_mut().ok_or(Failure::VaultLocked)?;
            let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
            (next, source_copies, group) =
                vault.with_restoration_keys_locked(self.library, |keys| {
                    let mut next = next.materialize_preservation(review.id, keys)?;
                    if !review.prerequisite_sources.is_empty() {
                        next = sources::materialize_prerequisite(
                            review.id,
                            &review.prerequisite_sources,
                            &next,
                            &review.snapshot.records,
                            keys,
                        )?;
                    }
                    let group = if review.current_sources.is_empty() {
                        None
                    } else {
                        Some(primary::DeletionGroup::prepare(
                            review.id,
                            review.current_sources.clone(),
                            &next,
                            keys,
                        )?)
                    };
                    let copies = sources::copies(
                        &review.source_versions,
                        &next,
                        keys,
                        group.as_ref().map(primary::DeletionGroup::originals),
                    )?;
                    Ok::<_, primary::Failure>((next, copies, group))
                })??;
            if review.live.is_none() {
                review.live = next.preservation_original(review.id).cloned();
            }
            review.repair = if matches!(review.source, Source::Inbound(..) | Source::Outbound(..)) {
                review
                    .live
                    .as_ref()
                    .map(|live| {
                        if let Some(group) = &group {
                            group.repair(&next, &review.snapshot.records, live)
                        } else {
                            next.deletion_repair(review.id, &review.snapshot.records, live)
                        }
                    })
                    .transpose()?
                    .flatten()
            } else {
                None
            };
        }
        if review
            .repair
            .as_ref()
            .is_some_and(|repair| repair.needs_vault())
            && vault.is_none()
        {
            return Err(Failure::VaultLocked);
        }
        let previous = next.merge_ancestor(review.id).cloned();
        let target = match choice {
            Choice::Delete => match &review.source {
                Source::Pending(e) | Source::Inbound(e, _) | Source::Outbound(e, _) => e.clone(),
                Source::Local => {
                    let live = review.live.as_ref().ok_or(Failure::RestoreUnavailable)?;
                    let stamp = self.deletion_stamp(&review)?;
                    if let Some(group) = &group {
                        group.tombstone(live, stamp)?
                    } else {
                        live.tombstone(stamp.clone(), stamp.device().into(), true)?
                    }
                }
            },
            Choice::Keep => {
                let mut live = review.live.clone().ok_or(Failure::RestoreUnavailable)?;
                let stamp = self.deletion_stamp(&review)?;
                live.origin = stamp.device().into();
                live.hlc = stamp;
                // An explicit keep/restore is a new local edit, retaining the
                // same sealed body/UUID/vault identity without revealing it.
                live.fields
                    .as_mut()
                    .ok_or(Failure::RestoreUnavailable)?
                    .updated_at = crate::model::timestamp();
                live
            }
        };
        let mut outcomes = vec![merge::Outcome {
            survivor: Some(target.clone()),
            conflict_copies: source_copies,
        }];
        for id in &review.missing_originals {
            let original = next
                .local_intent(*id, None)?
                .or_else(|| {
                    group
                        .as_ref()
                        .and_then(|group| group.sources().iter().find(|source| source.id == *id))
                })
                .or_else(|| next.entry(*id).map(|entry| &entry.desired))
                .or_else(|| next.preservation_original(*id))
                .or_else(|| group.as_ref().and_then(|group| group.originals().get(id)))
                .cloned()
                .ok_or(Failure::PreservationRequired)?;
            // This review cannot grant another record's deletion permission or
            // replace its separately unresolved local intent with an ancestor.
            if original.deleted
                || (merge::has_unresolved(Some(&original))
                    && !group
                        .as_ref()
                        .is_some_and(|group| group.sources().contains(&original)))
            {
                return Err(Failure::PreservationRequired);
            }
            outcomes.push(merge::Outcome {
                survivor: Some(original),
                conflict_copies: vec![],
            });
        }
        if let Some(group) = &group {
            for source in group
                .sources()
                .iter()
                .filter(|source| source.id != review.id)
            {
                if !outcomes
                    .iter()
                    .any(|outcome| outcome.survivor.as_ref().is_some_and(|e| e.id == source.id))
                {
                    outcomes.push(merge::Outcome {
                        survivor: Some(source.clone()),
                        conflict_copies: vec![],
                    });
                }
            }
        }
        let mut expected = primary::preservation_read_set(&outcomes, &review.snapshot.records)?;
        if let Some(repair) = &review.repair {
            let frame = repair.frame();
            for e in frame
                .targets
                .values()
                .chain(frame.sources.iter().map(|(e, _)| e))
                .chain(frame.sources.iter().flat_map(|(_, copies)| copies))
            {
                expected.insert(e.id, review.snapshot.records.get(&e.id).cloned());
            }
        }
        if let Some(group) = &group {
            for e in group.sources().iter().chain(group.originals().values()) {
                expected.insert(e.id, review.snapshot.records.get(&e.id).cloned());
            }
        }
        let mut prepared = if let Some(group) = &group {
            vault.ok_or(Failure::VaultLocked)?.prepare_deletion_group(
                self.library,
                &next,
                &review.device,
                &outcomes,
                &expected,
                review.id,
                group,
                review.repair.as_ref(),
            )?
        } else if let Some(repair) = &review.repair {
            if let Some(vault) = vault {
                vault.prepare_deletion_repair(
                    self.library,
                    &next,
                    &review.device,
                    &outcomes,
                    &expected,
                    repair,
                )?
            } else {
                primary::prepare_deletion_repair(
                    self.library,
                    &next,
                    &review.device,
                    &outcomes,
                    &expected,
                    repair,
                    None,
                )?
            }
        } else if (choice == Choice::Keep || review.materialize)
            && let Some(vault) = vault
        {
            vault.prepare_deletion_apply(
                self.library,
                &next,
                &review.device,
                &outcomes,
                &expected,
                review.id,
            )?
        } else {
            primary::prepare(self.library, &next, &review.device, &outcomes, &expected)?
        };
        if !prepared.matches_snapshot(&review.snapshot) {
            return Err(Failure::Changed);
        }
        if !prepared.incompatible_ids.is_empty() {
            return Err(Failure::IncompatibleVault);
        }
        if !prepared.deferred_ids.is_empty() {
            return Err(Failure::VaultLocked);
        }
        if !prepared.retry_ids.is_empty() {
            return Err(Failure::Changed);
        }
        next.desire(target.clone())?;
        if choice == Choice::Delete {
            next.approve_deletion(&target, review.live.clone())?;
            next.review_absence(review.id, previous)?;
            prepared.release_reviewed_deletion(&review.checkpoint.journal, &next, &target)?;
            if matches!(&review.source, Source::Pending(_))
                && let Some(packet) = next.outbound.as_mut()
                && packet.receipts.is_none()
            {
                for offer in packet.offers.iter_mut().filter(|o| o.wire.id == review.id) {
                    if offer.offered.envelope.hash()? == target.hash()? {
                        offer.deletion_authorized = true;
                    }
                }
            }
        } else if matches!(&review.source, Source::Pending(_)) {
            // A false frozen consent bit proves this batch could not have been
            // posted by the native sender. An authorized ambiguous transmission
            // retains its original consent/bytes while the newer live edit waits.
            let Source::Pending(deleted) = &review.source else {
                unreachable!()
            };
            let deleted_hash = deleted.hash()?;
            let unsent = next.outbound.as_ref().is_some_and(|p| {
                p.receipts.is_none()
                    && p.offers.iter().any(|o| {
                        o.wire.id == review.id
                            && !o.deletion_authorized
                            && o.offered.envelope.deleted
                            && o.offered.envelope.hash().is_ok_and(|h| h == deleted_hash)
                    })
            });
            if unsent {
                let packet = next.outbound.as_mut().ok_or(Failure::Changed)?;
                packet.offers.retain(|o| o.wire.id != review.id);
                if packet.offers.is_empty() {
                    next.outbound = None;
                }
                next.reject(review.id);
            }
            next.supersede_unoffered_deletion(deleted, &target)?;
            prepared.release_reviewed_keep(&review.checkpoint.journal, deleted, &target)?;
        }
        match &review.source {
            Source::Inbound(e, version) | Source::Outbound(e, version) => {
                if matches!(review.source, Source::Outbound(..)) {
                    next.reject(review.id);
                } else {
                    next.retire_deleted_prerequisite(e, version)?;
                }
                next.record_confirmed(e.clone(), version.clone())?;
                if choice == Choice::Delete && group.is_some() {
                    // The authenticated current group is staged only when its
                    // primary WAL is published. An equal received tombstone
                    // can therefore consume the unowned ordinary approval
                    // before that group exists. This exact reviewed decision
                    // still needs consent for its post-original source send;
                    // it is not a source acknowledgement.
                    next.approve_deletion(&target, review.live.clone())?;
                }
                if matches!(review.source, Source::Inbound(..)) {
                    next.inbox.acknowledge_record()?;
                } else {
                    next.outbound.as_mut().ok_or(Failure::Changed)?.position += 1;
                }
            }
            _ => (),
        }
        (self.validate_session)()?;
        primary::commit_staged(
            self.library,
            &mut review.checkpoint,
            self.checkpoint_key,
            self.checkpoint_salt,
            prepared,
            next,
            fault,
        )?;
        Ok(review.summary.kind)
    }
    fn deletion_stamp(&self, review: &Review) -> Result<crate::clock::Hlc> {
        let journal = &review.checkpoint.journal;
        let known = journal.projection_knowledge();
        // The reviewed remote tombstone has not yet been confirmed. Observe
        // its clock too, so an explicit keep is causally newer even after skew.
        let deletion = match &review.source {
            Source::Pending(e) | Source::Inbound(e, _) | Source::Outbound(e, _) => Some(e),
            Source::Local => None,
        };
        let frames = journal.preservation_generations(review.id)?;
        let envelopes = known
            .values()
            .chain(journal.projected().values())
            .chain(review.snapshot.records.values())
            .chain(review.live.as_ref())
            .chain(deletion)
            .chain(frames.iter().flat_map(|g| g.targets.values()))
            .chain(frames.iter().flat_map(|g| &g.sources).map(|(e, _)| e))
            .chain(
                frames
                    .iter()
                    .flat_map(|g| &g.sources)
                    .flat_map(|(_, copies)| copies),
            );
        let mut floor = None;
        for e in envelopes {
            floor = floor.max(Some(e.hlc.clone()));
            for variant in merge::secure_variants(e).map_err(|_| Failure::PreservationRequired)? {
                floor = floor.max(Some(variant.source_hlc));
            }
        }
        let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
        primary::require_ready(&self.library.root)?;
        Ok(crate::clock::stamp(
            &self.library.root,
            floor.as_ref(),
            chrono::Utc::now().timestamp_millis().max(0) as u64,
        )?)
    }
}
#[cfg(test)]
#[path = "deletion_review_tests.rs"]
mod tests;
