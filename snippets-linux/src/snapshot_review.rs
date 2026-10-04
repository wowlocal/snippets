//! Explicit recovery of a complete snapshot which omitted known records.
//! A review ticket owns the exact encrypted checkpoint and complete primary
//! image. Confirmation rechecks both, the live session, scope, feed and key epoch
//! before one journal-first reset. Confirmation neither posts records nor
//! changes primary. Preparation first recovers any already authorized primary WAL.
use crate::{
    inbound::Feed,
    journal::{self, Checkpoint, Journal},
    primary,
    receiver::{self, Observation, Owner, Remote},
    wire::Envelope,
};
use std::collections::BTreeMap;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Data(receiver::Failure),
    Unavailable,
    LocalAbsence,
    Changed,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<receiver::Failure> for Failure {
    fn from(value: receiver::Failure) -> Self {
        Self::Data(value)
    }
}
impl From<primary::Failure> for Failure {
    fn from(value: primary::Failure) -> Self {
        Self::Data(receiver::Failure::Primary(value))
    }
}
impl From<journal::Failure> for Failure {
    fn from(value: journal::Failure) -> Self {
        Self::Data(receiver::Failure::Journal(value))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Summary {
    pub local_records: usize,
    pub missing_records: usize,
    pub preservation_copies: usize,
}
// Payload stays in the serialized owner, never in GTK, diagnostics or a message.
pub struct Review {
    root: std::path::PathBuf,
    checkpoint: Checkpoint,
    current: BTreeMap<Uuid, Envelope>,
    device: String,
    feed: Feed,
    summary: Summary,
}
impl Review {
    pub fn summary(&self) -> Summary {
        self.summary
    }
}
pub(crate) fn check_epoch(journal: &Journal, epoch: u64) -> primary::Result<()> {
    if journal.key_epoch.is_some_and(|old| old != epoch)
        || journal
            .inbox
            .feed
            .as_ref()
            .is_some_and(|f| f.key_epoch != epoch)
        || journal
            .outbound
            .as_ref()
            .is_some_and(|p| p.key_epoch != epoch)
    {
        return Err(primary::Failure::RecoveryRequired);
    }
    Ok(())
}
impl Owner<'_> {
    pub(crate) fn review_preflight(&self, remote: &mut impl Remote) -> Result<Observation> {
        (self.validate_session)()?;
        let observed = remote.preflight().map_err(receiver::Failure::Remote)?;
        (self.validate_session)()?;
        self.verify(&observed)?;
        Ok(observed)
    }
    pub fn prepare_missing_snapshot_review(&self, remote: &mut impl Remote) -> Result<Review> {
        let observed = self.review_preflight(remote)?;
        let checkpoint = primary::recover_checked(
            &self.library.root,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
            |journal| check_epoch(journal, self.key_epoch),
        )?;
        if !checkpoint.journal.inbox.needs_review() {
            return Err(Failure::Unavailable);
        }
        let snapshot = checkpoint
            .journal
            .inbox
            .snapshot
            .as_ref()
            .filter(|snapshot| !snapshot.open)
            .ok_or(Failure::Unavailable)?;
        let missing_records = checkpoint
            .journal
            .agreed_envelopes()
            .keys()
            .filter(|id| !snapshot.seen.contains(id))
            .count();
        let device = self.local_device(&checkpoint)?;
        let current = primary::current(self.library, &checkpoint.journal, &device)?;
        if checkpoint
            .journal
            .projection_knowledge()
            .values()
            .chain(checkpoint.journal.projected().values())
            .any(|e| !e.deleted && !current.contains_key(&e.id))
        {
            // Absence is a different user decision. This action cannot approve
            // a local deletion, restore it, or infer mass cloud tombstones.
            return Err(Failure::LocalAbsence);
        }
        let summary = Summary {
            local_records: current.len(),
            missing_records,
            preservation_copies: checkpoint.journal.conflict_snapshots().len(),
        };
        let after = self.review_preflight(remote)?;
        if after.feed != observed.feed {
            return Err(Failure::Changed);
        }
        Ok(Review {
            root: self.library.root.clone(),
            checkpoint,
            current,
            device,
            feed: observed.feed,
            summary,
        })
    }
    pub fn resume_missing_snapshot_review(
        &self,
        remote: &mut impl Remote,
        review: Review,
    ) -> Result<Summary> {
        self.resume_review_inner(remote, review, None)
    }
    fn resume_review_inner(
        &self,
        remote: &mut impl Remote,
        mut review: Review,
        fault: Option<bool>,
    ) -> Result<Summary> {
        // A ticket cannot be borrowed by another library/key owner. Check before
        // primary reads or recovery; old cursors never enter a new data plane.
        if review.root != self.library.root || review.checkpoint.journal.scope() != self.scope {
            return Err(receiver::Failure::ScopeReview.into());
        }
        check_epoch(&review.checkpoint.journal, self.key_epoch)?;
        let observed = self.review_preflight(remote)?;
        if observed.feed != review.feed {
            return Err(Failure::Changed);
        }
        (self.validate_session)()?;
        let _guard = self.library.lock().map_err(|_| journal::Failure::Storage)?;
        // Authenticate the still-current encrypted file with this owner's
        // material before reading primary, including when a key was replaced.
        let saved = Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
        )?;
        check_epoch(&saved.journal, self.key_epoch)?;
        if !review.checkpoint.same_snapshot(&saved) {
            return Err(Failure::Changed);
        }
        let current =
            primary::current_locked(self.library, &review.checkpoint.journal, &review.device)?;
        if current != review.current {
            return Err(Failure::Changed);
        }
        review
            .checkpoint
            .journal
            .resume_missing_snapshot(&current, observed.feed)?;
        if fault == Some(false) {
            return Err(journal::Failure::Storage.into());
        }
        review
            .checkpoint
            .save_locked(self.library, self.checkpoint_key, self.checkpoint_salt)?;
        if fault == Some(true) {
            return Err(journal::Failure::Storage.into());
        }
        Ok(review.summary)
    }
}

#[cfg(test)]
#[path = "snapshot_review_tests.rs"]
pub(crate) mod tests;
