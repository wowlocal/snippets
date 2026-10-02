//! Bounded outbound owner, preserving exact ciphertext/CAS and partial receipts.
//! Native callers hold the credential mutex; primary locks never span HTTP.
use crate::{
    cloud::{self, BoundTransport, ErrorCode, Offer, Outcome, Role},
    inbound::PAGE_LIMIT,
    journal::{Checkpoint, Journal},
    merge,
    outbound::{Packet, Receipt, Transmission},
    primary,
    receiver::{self, Failure, Observation, Owner, RemoteResult, Result},
    wire::{Envelope, WireRecord},
};
use std::collections::BTreeMap;

pub struct SendObservation {
    pub observation: Observation,
    pub role: Role,
}
pub struct Reply {
    pub observation: Observation,
    pub outcomes: Vec<Outcome>,
    pub partial: bool,
}
pub trait Remote {
    fn preflight(&mut self) -> RemoteResult<SendObservation>;
    fn submit(&mut self, offers: &[Offer]) -> RemoteResult<Reply>;
}
impl Remote for BoundTransport {
    fn preflight(&mut self) -> RemoteResult<SendObservation> {
        let observation = receiver::Remote::preflight(self)?;
        Ok(SendObservation {
            observation,
            role: self.current_role(),
        })
    }
    fn submit(&mut self, offers: &[Offer]) -> RemoteResult<Reply> {
        let batch = self.submit_chunk(offers)?;
        Ok(Reply {
            observation: Observation {
                scope: self.checkpoint_scope(),
                feed: self.feed().map_err(|_| cloud::Failure::InvalidResponse)?,
            },
            outcomes: batch.outcomes,
            partial: batch.partial,
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// All currently captured sendable intent is confirmed. Not a receive claim.
    Settled,
    MoreBatches,
    ReceiveFirst,
    LocalReview,
    SnapshotReview,
    PreservationRequired,
    ConflictReview,
    VaultLocked,
    IncompatibleVault,
    DeletionReview,
    PrimaryChanged,
    ReadOnly,
    ServerDeferred {
        code: ErrorCode,
        retry_after: Option<u32>,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Progress {
    pub status: Status,
    pub accepted: usize,
    pub confirmed: usize,
    pub conflicts: usize,
    pub rejected: usize,
    pub batches: usize,
}
impl Owner<'_> {
    fn send_preflight(&self, remote: &mut impl Remote) -> Result<SendObservation> {
        (self.validate_session)()?;
        let observed = remote.preflight().map_err(Failure::Remote)?;
        (self.validate_session)()?;
        self.verify(&observed.observation)?;
        Ok(observed)
    }
    fn send_save(&self, checkpoint: &mut Checkpoint, fault: &mut Fault) -> Result<()> {
        fault.before()?;
        checkpoint.save(self.library, self.checkpoint_key, self.checkpoint_salt)?;
        fault.after()
    }
    fn capture_send(
        &self,
        checkpoint: &mut Checkpoint,
        device: &str,
        fault: &mut Fault,
    ) -> Result<Option<Status>> {
        (self.validate_session)()?;
        let _guard = self
            .library
            .lock()
            .map_err(|_| Failure::Journal(crate::journal::Failure::Storage))?;
        let current = primary::current_locked(self.library, &checkpoint.journal, device)?;
        let known = checkpoint.journal.projection_knowledge();
        if known
            .values()
            .chain(checkpoint.journal.projected().values())
            .any(|e| {
                !e.deleted
                    && !current.contains_key(&e.id)
                    && !checkpoint.journal.known_absence(e.id)
            })
        {
            // Missing files and unknown absences are never mass tombstones.
            return Ok(Some(Status::LocalReview));
        }
        let mut next = checkpoint.journal.clone();
        next.key_epoch = Some(self.key_epoch);
        next.reconcile_dependencies(&current)?;
        for e in current.values() {
            let intent = next.local_intent(e.id, Some(e))?.cloned();
            if let Some(intent) = intent
                && (next.entry(e.id).is_some()
                    || !next
                        .confirmed(e.id)
                        .map(|c| c.envelope.hash())
                        .transpose()?
                        .is_some_and(|h| e.hash().is_ok_and(|hash| hash == h)))
            {
                next.desire(intent)?;
            }
        }
        next.projected
            .retain(|id, e| e.deleted && !current.contains_key(id));
        next.projected.extend(current);
        if next != checkpoint.journal {
            checkpoint.journal = next;
            fault.before()?;
            checkpoint.save_locked(self.library, self.checkpoint_key, self.checkpoint_salt)?;
            fault.after()?;
        }
        Ok(None)
    }
    pub(crate) fn local_device(&self, checkpoint: &Checkpoint) -> Result<String> {
        if let Some(device) = self.device {
            return Ok(device.to_owned());
        }
        let _guard = self
            .library
            .lock()
            .map_err(|_| Failure::Journal(crate::journal::Failure::Storage))?;
        primary::require_ready(&self.library.root)
            .map_err(|_| Failure::Primary(primary::Failure::RecoveryRequired))?;
        let known = checkpoint.journal.projection_knowledge();
        let floor = known
            .values()
            .chain(checkpoint.journal.projected().values())
            .map(|e| &e.hlc)
            .max();
        Ok(crate::clock::stamp(
            &self.library.root,
            floor,
            chrono::Utc::now().timestamp_millis().max(0) as u64,
        )
        .map_err(|_| Failure::Journal(crate::journal::Failure::Storage))?
        .device()
        .to_owned())
    }
    fn cleanup_carriers(
        &self,
        checkpoint: &mut Checkpoint,
        device: &str,
    ) -> Result<Option<Status>> {
        let current = primary::current(self.library, &checkpoint.journal, device)?;
        for resolution in checkpoint.journal.carrier_resolutions(&current)? {
            let next = checkpoint
                .journal
                .stage_carrier_resolution(&resolution, &current)?;
            let outcome = merge::Outcome {
                survivor: Some(resolution.resolved),
                conflict_copies: vec![],
            };
            if let Some(status) =
                self.apply_send_outcome(checkpoint, device, &current, &outcome, Some(next))?
            {
                return Ok(Some(status));
            }
        }
        Ok(None)
    }
    fn restore_reviewed_intent(
        &self,
        checkpoint: &mut Checkpoint,
        device: &str,
    ) -> Result<Option<Status>> {
        let current = primary::current(self.library, &checkpoint.journal, device)?;
        let held = current
            .iter()
            .filter_map(|(id, physical)| {
                match checkpoint.journal.local_intent(*id, Some(physical)) {
                    Ok(Some(intent)) if intent != physical => Some(Ok(intent.clone())),
                    Ok(_) => None,
                    Err(failure) => Some(Err(failure)),
                }
            })
            .collect::<crate::journal::Result<Vec<_>>>()?;
        for intent in held {
            let fresh = primary::current(self.library, &checkpoint.journal, device)?;
            if checkpoint
                .journal
                .local_intent(intent.id, fresh.get(&intent.id))?
                != Some(&intent)
                || fresh.get(&intent.id) == Some(&intent)
            {
                continue;
            }
            let outcome = merge::Outcome {
                survivor: Some(intent),
                conflict_copies: vec![],
            };
            if let Some(status) =
                self.apply_send_outcome(checkpoint, device, &fresh, &outcome, None)?
            {
                return Ok(Some(status));
            }
        }
        Ok(None)
    }
    fn apply_send_outcome(
        &self,
        checkpoint: &mut Checkpoint,
        device: &str,
        current: &BTreeMap<uuid::Uuid, Envelope>,
        outcome: &merge::Outcome,
        staged: Option<Journal>,
    ) -> Result<Option<Status>> {
        let mut secure_unit = false;
        for e in outcome.survivor.iter().chain(&outcome.conflict_copies) {
            if e.deleted
                && let Some(physical) = current.get(&e.id)
                && !checkpoint.journal.primary_deletion_approved(e, physical)?
            {
                return Ok(Some(Status::DeletionReview));
            }
            let variants = merge::secure_variants(e).map_err(|_| Failure::InvalidPage)?;
            secure_unit |= e.secure || !variants.is_empty();
        }
        let expected = primary::preservation_read_set(std::slice::from_ref(outcome), current)?;
        let prepared = primary::prepare(
            self.library,
            &checkpoint.journal,
            device,
            std::slice::from_ref(outcome),
            &expected,
        )?;
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
        if status.is_some() {
            return Ok(status);
        }
        (self.validate_session)()?;
        let result = if let Some(next) = staged {
            primary::commit_staged(
                self.library,
                checkpoint,
                self.checkpoint_key,
                self.checkpoint_salt,
                prepared,
                next,
                None,
            )
        } else {
            primary::commit(
                self.library,
                checkpoint,
                self.checkpoint_key,
                self.checkpoint_salt,
                prepared,
            )
        };
        match result {
            Err(primary::Failure::StalePrimary) => Ok(Some(Status::PrimaryChanged)),
            result => {
                result?;
                Ok(None)
            }
        }
    }
    pub fn send(&self, remote: &mut impl Remote, max_batches: usize) -> Result<Progress> {
        self.send_inner(remote, max_batches, &mut Fault::default())
    }
    fn send_inner(
        &self,
        remote: &mut impl Remote,
        max_batches: usize,
        fault: &mut Fault,
    ) -> Result<Progress> {
        if !(1..=8).contains(&max_batches) {
            return Err(Failure::InvalidPage);
        }
        let mut observed = self.send_preflight(remote)?;
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
                        .inbox
                        .feed
                        .as_ref()
                        .is_some_and(|f| f.key_epoch != self.key_epoch)
                    || journal
                        .outbound
                        .as_ref()
                        .is_some_and(|p| p.key_epoch != self.key_epoch)
                {
                    return Err(primary::Failure::RecoveryRequired);
                }
                Ok(())
            },
        )?;
        let mut progress = Progress {
            status: Status::MoreBatches,
            accepted: 0,
            confirmed: 0,
            conflicts: 0,
            rejected: 0,
            batches: 0,
        };
        if checkpoint.journal.inbox.needs_review() {
            progress.status = Status::SnapshotReview;
            return Ok(progress);
        }
        if checkpoint.journal.outbound.is_none()
            && receive_required(&checkpoint.journal, &observed.observation)
        {
            progress.status = Status::ReceiveFirst;
            return Ok(progress);
        }
        let device = self.local_device(&checkpoint)?;
        for batch_index in 0..max_batches {
            if batch_index > 0 {
                observed = self.send_preflight(remote)?;
            }
            // Finish retained bytes/receipts first, but never prepare another
            // batch against an incomplete or newly rotated applied feed.
            if checkpoint.journal.outbound.is_none()
                && receive_required(&checkpoint.journal, &observed.observation)
            {
                progress.status = Status::ReceiveFirst;
                return Ok(progress);
            }
            let received = checkpoint
                .journal
                .outbound
                .as_ref()
                .is_some_and(|p| p.receipts.is_some());
            if !received {
                if observed.role == Role::Reader {
                    progress.status = Status::ReadOnly;
                    return Ok(progress);
                }
                if let Some(status) = self.restore_reviewed_intent(&mut checkpoint, &device)? {
                    progress.status = status;
                    return Ok(progress);
                }
                if let Some(status) = self.capture_send(&mut checkpoint, &device, fault)? {
                    progress.status = status;
                    return Ok(progress);
                }
                if let Some(status) = self.cleanup_carriers(&mut checkpoint, &device)? {
                    progress.status = status;
                    return Ok(progress);
                }
                if let Some(status) = self.capture_send(&mut checkpoint, &device, fault)? {
                    progress.status = status;
                    return Ok(progress);
                }
                if checkpoint.journal.outbound.is_none() {
                    let pending = checkpoint.journal.pending()?;
                    if pending.is_empty() {
                        progress.status = if checkpoint.journal.has_preservation_work() {
                            Status::PreservationRequired
                        } else {
                            Status::Settled
                        };
                        return Ok(progress);
                    }
                    let pending: Vec<_> = pending.into_iter().take(PAGE_LIMIT).collect();
                    if pending.iter().any(|e| {
                        e.deleted && !checkpoint.journal.deletion_approved(e).unwrap_or(false)
                    }) {
                        progress.status = Status::DeletionReview;
                        return Ok(progress);
                    }
                    let offered = checkpoint.journal.mark_offered(&pending)?;
                    let offers = offered
                        .into_iter()
                        .map(|offered| {
                            let wire =
                                WireRecord::seal(&offered.envelope, self.wire_key, self.wire_salt)
                                    .map_err(|_| Failure::InvalidPage)?;
                            let deletion_authorized = offered.envelope.deleted
                                && checkpoint.journal.deletion_approved(&offered.envelope)?;
                            Ok(Transmission {
                                offered,
                                wire,
                                deletion_authorized,
                            })
                        })
                        .collect::<Result<Vec<_>>>()?;
                    checkpoint.journal.outbound = Some(Packet {
                        key_epoch: self.key_epoch,
                        offers,
                        receipts: None,
                        received_at: None,
                        position: 0,
                    });
                    self.send_save(&mut checkpoint, fault)?;
                }
                let packet = checkpoint
                    .journal
                    .outbound
                    .as_ref()
                    .ok_or(Failure::InvalidPage)?;
                for offer in &packet.offers {
                    if offer.offered.envelope.deleted && !offer.deletion_authorized {
                        progress.status = Status::DeletionReview;
                        return Ok(progress);
                    }
                    if !checkpoint.journal.retains_offer(&offer.offered) {
                        progress.status = Status::ConflictReview;
                        return Ok(progress);
                    }
                    if offer
                        .wire
                        .open(self.wire_key, self.wire_salt)
                        .map_err(|_| Failure::InvalidPage)?
                        .hash()?
                        != offer.offered.envelope.hash()?
                    {
                        return Err(Failure::InvalidPage);
                    }
                }
                let offers: Vec<_> = packet
                    .offers
                    .iter()
                    .map(|o| Offer {
                        record: o.wire.clone(),
                        expected_record_version: o.offered.record_version.clone(),
                    })
                    .collect();
                (self.validate_session)()?;
                let reply = remote.submit(&offers).map_err(Failure::Remote)?;
                // The reply pins its original scope. Save complete receipts before
                // post-HTTP session/role/scope observations can fail or expire.
                self.verify(&reply.observation)?;
                let receipts = receipts(reply, &offers)?;
                checkpoint
                    .journal
                    .outbound
                    .as_mut()
                    .ok_or(Failure::InvalidPage)?
                    .receipts = Some(receipts);
                checkpoint
                    .journal
                    .outbound
                    .as_mut()
                    .ok_or(Failure::InvalidPage)?
                    .received_at = Some(epoch_millis()?);
                self.send_save(&mut checkpoint, fault)?;
                observed = self.send_preflight(remote)?;
            }
            let mut deferred = None;
            while let Some((offer, receipt)) = next_receipt(&checkpoint.journal) {
                (self.validate_session)()?;
                match receipt {
                    Receipt::Accepted(version) => {
                        checkpoint.journal.accept_offered(&offer.offered, version)?;
                        progress.accepted += 1;
                    }
                    Receipt::Rejected { code, retry_after } => {
                        checkpoint.journal.reject(offer.wire.id);
                        progress.rejected += 1;
                        deferred.get_or_insert(Status::ServerDeferred { code, retry_after });
                    }
                    Receipt::Conflict { wire, version } => {
                        let remote = wire
                            .open(self.wire_key, self.wire_salt)
                            .map_err(|_| Failure::InvalidPage)?;
                        merge::validate(&remote).map_err(|_| Failure::InvalidPage)?;
                        let source_delete_retry = remote.deleted
                            && offer.deletion_authorized
                            && checkpoint.journal.requires_source_ack(&offer.offered)
                            && remote.hash()? == offer.offered.envelope.hash()?;
                        if remote.hash()? != offer.offered.envelope.hash()? {
                            if checkpoint.journal.is_prerequisite_offer(&offer.offered) {
                                // Edited C1 is not proof of immutable C0 and must
                                // never be overwritten to manufacture that proof.
                                progress.status = if remote.deleted {
                                    Status::DeletionReview
                                } else {
                                    Status::ConflictReview
                                };
                                return Ok(progress);
                            }
                            let current =
                                primary::current(self.library, &checkpoint.journal, &device)?;
                            if !current.contains_key(&remote.id)
                                && !offer.offered.envelope.deleted
                                && !checkpoint.journal.known_absence(remote.id)
                            {
                                progress.status = Status::LocalReview;
                                return Ok(progress);
                            }
                            let outcome = merge::merge(
                                checkpoint.journal.merge_ancestor(remote.id),
                                checkpoint
                                    .journal
                                    .local_intent(remote.id, current.get(&remote.id))?,
                                Some(&remote),
                            )
                            .map_err(|_| Failure::InvalidPage)?;
                            if let Some(status) = self.apply_send_outcome(
                                &mut checkpoint,
                                &device,
                                &current,
                                &outcome,
                                None,
                            )? {
                                progress.status = status;
                                return Ok(progress);
                            }
                            fault.primary()?;
                            for e in outcome.survivor.into_iter().chain(outcome.conflict_copies) {
                                checkpoint.journal.desire(e)?;
                            }
                            progress.conflicts += 1;
                        } else {
                            progress.confirmed += 1;
                        }
                        // A conflict proves current content, never an actual
                        // post-copy source ACK. Reoffer with fresh authoritative CAS.
                        checkpoint.journal.reject(remote.id);
                        checkpoint.journal.record_confirmed(remote, version)?;
                        if source_delete_retry {
                            // The original native packet authorized these exact
                            // bytes. An authoritative CAS rejection supplies new
                            // CAS, but not the required actual post-copy ACK.
                            // This send-only permit has no live primary ancestor;
                            // it cannot erase the user's newer restored record.
                            checkpoint
                                .journal
                                .approve_deletion(&offer.offered.envelope, None)?;
                        }
                    }
                }
                checkpoint
                    .journal
                    .outbound
                    .as_mut()
                    .ok_or(Failure::InvalidPage)?
                    .position += 1;
                self.send_save(&mut checkpoint, fault)?;
            }
            if let Some((code, seconds)) = checkpoint
                .journal
                .outbound
                .as_ref()
                .ok_or(Failure::InvalidPage)?
                .cooldown(epoch_millis()?)?
            {
                progress.status = Status::ServerDeferred {
                    code,
                    retry_after: Some(seconds),
                };
                progress.batches += 1;
                return Ok(progress);
            }
            checkpoint.journal.outbound = None;
            self.send_save(&mut checkpoint, fault)?;
            progress.batches += 1;
            if let Some(status) = deferred {
                progress.status = status;
                return Ok(progress);
            }
            if observed.role == Role::Reader {
                progress.status = Status::ReadOnly;
                return Ok(progress);
            }
            if receive_required(&checkpoint.journal, &observed.observation) {
                progress.status = Status::ReceiveFirst;
                return Ok(progress);
            }
            if let Some(status) = self.capture_send(&mut checkpoint, &device, fault)? {
                progress.status = status;
                return Ok(progress);
            }
            if checkpoint.journal.pending()?.is_empty() {
                let current = primary::current(self.library, &checkpoint.journal, &device)?;
                if !checkpoint.journal.carrier_resolutions(&current)?.is_empty() {
                    // A copy ACK can enable cleanup while its source remains
                    // fenced. Continue the bounded cycle instead of halting
                    // before the next iteration can publish that removal.
                    continue;
                }
                progress.status = if checkpoint.journal.has_preservation_work() {
                    Status::PreservationRequired
                } else {
                    Status::Settled
                };
                return Ok(progress);
            }
        }
        Ok(progress)
    }
}
fn receive_required(journal: &Journal, observed: &Observation) -> bool {
    journal.inbox.has_pending_page()
        || journal.inbox.snapshot.is_some()
        || (journal.inbox.feed.is_some()
            && (journal.inbox.applied_cursor.is_none()
                || journal.inbox.feed.as_ref() != Some(&observed.feed)))
}
fn next_receipt(journal: &Journal) -> Option<(Transmission, Receipt)> {
    let packet = journal.outbound.as_ref()?;
    Some((
        packet.offers.get(packet.position)?.clone(),
        packet.receipts.as_ref()?.get(packet.position)?.clone(),
    ))
}
fn epoch_millis() -> Result<u64> {
    let now =
        u64::try_from(chrono::Utc::now().timestamp_millis()).map_err(|_| Failure::InvalidPage)?;
    if now == 0 {
        return Err(Failure::InvalidPage);
    }
    Ok(now)
}
fn receipts(reply: Reply, offers: &[Offer]) -> Result<Vec<Receipt>> {
    if reply.outcomes.len() != offers.len()
        || reply.partial
            != reply
                .outcomes
                .iter()
                .any(|o| !matches!(o, Outcome::Accepted { .. }))
    {
        return Err(Failure::InvalidPage);
    }
    reply
        .outcomes
        .into_iter()
        .zip(offers)
        .map(|(outcome, offer)| match outcome {
            Outcome::Accepted {
                record_version,
                revision,
            } => {
                if revision != offer.record.rev {
                    return Err(Failure::InvalidPage);
                }
                record_version
                    .validate()
                    .map_err(|_| Failure::InvalidPage)?;
                Ok(Receipt::Accepted(record_version))
            }
            Outcome::Conflict {
                authoritative_record,
            } => {
                let (wire, version) = authoritative_record.into_parts();
                wire.validate().map_err(|_| Failure::InvalidPage)?;
                version.validate().map_err(|_| Failure::InvalidPage)?;
                if wire.id != offer.record.id {
                    return Err(Failure::InvalidPage);
                }
                Ok(Receipt::Conflict { wire, version })
            }
            Outcome::Rejected {
                error_code,
                retry_after_seconds,
            } => {
                if retry_after_seconds.is_some_and(|s| !(1..=86400).contains(&s)) {
                    return Err(Failure::InvalidPage);
                }
                Ok(Receipt::Rejected {
                    code: error_code,
                    retry_after: retry_after_seconds,
                })
            }
        })
        .collect()
}
#[derive(Default)]
struct Fault {
    #[cfg(test)]
    saves: usize,
    #[cfg(test)]
    save: Option<(usize, bool)>,
    #[cfg(test)]
    after_primary: bool,
}
impl Fault {
    fn before(&mut self) -> Result<()> {
        #[cfg(test)]
        {
            self.saves += 1;
            if self.save == Some((self.saves, false)) {
                return Err(Failure::Journal(crate::journal::Failure::Storage));
            }
        }
        Ok(())
    }
    fn after(&self) -> Result<()> {
        #[cfg(test)]
        if self.save == Some((self.saves, true)) {
            return Err(Failure::Journal(crate::journal::Failure::Storage));
        }
        Ok(())
    }
    fn primary(&self) -> Result<()> {
        #[cfg(test)]
        if self.after_primary {
            return Err(Failure::Primary(primary::Failure::RecoveryRequired));
        }
        Ok(())
    }
}
#[cfg(test)]
#[path = "sender_tests.rs"]
mod tests;
