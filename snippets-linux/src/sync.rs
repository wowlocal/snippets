//! Bounded bidirectional cycles. Receipts and original offers remain owned by
//! the encrypted journal; this coordinator never keeps a second queue or cursor.
use crate::{
    journal::Checkpoint,
    primary,
    receiver::{self, Owner},
    sender,
    snapshot_review::check_epoch,
};

pub trait Remote: receiver::Remote + sender::Remote {}
impl<T: receiver::Remote + sender::Remote> Remote for T {}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Receive,
    Send,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Both directions are clean at this cycle's applied feed/primary view.
    Current,
    MoreWork(Direction),
    Receiving(receiver::Status),
    Sending(sender::Status),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Number of bounded receive attempts, including cursor/feed restarts.
    pub receive: usize,
    /// Number of bounded send attempts, including retained receipt processing.
    pub send: usize,
}
impl Limits {
    pub const DEFAULT: Self = Self {
        receive: 4,
        send: 4,
    };
    fn validate(self) -> receiver::Result<()> {
        if !(1..=8).contains(&self.receive) || !(1..=8).contains(&self.send) {
            return Err(receiver::Failure::InvalidPage);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Progress {
    pub status: Status,
    pub received_records: usize,
    pub applied_records: usize,
    pub completed_pages: usize,
    pub accepted: usize,
    pub confirmed: usize,
    pub conflicts: usize,
    pub rejected: usize,
    pub batches: usize,
    pub receive_attempts: usize,
    pub send_attempts: usize,
}

impl Owner<'_> {
    // Fresh scope/key admission always precedes recovery and primary reads.
    // Comparing the actual primary view detects edits after the sender's capture.
    fn sync_direction(&self, remote: &mut impl Remote) -> receiver::Result<Option<Direction>> {
        (self.validate_session)()?;
        let observed = sender::Remote::preflight(remote).map_err(receiver::Failure::Remote)?;
        (self.validate_session)()?;
        self.verify(&observed.observation)?;
        let checkpoint = primary::recover_checked(
            &self.library.root,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
            |journal| check_epoch(journal, self.key_epoch),
        )?;
        let device = self.local_device(&checkpoint)?;
        let _guard = self
            .library
            .lock()
            .map_err(|_| crate::journal::Failure::Storage)?;
        let saved = Checkpoint::load_locked(
            self.library,
            self.checkpoint_key,
            self.checkpoint_salt,
            self.scope.clone(),
        )?;
        check_epoch(&saved.journal, self.key_epoch)?;
        let journal = &saved.journal;
        if journal.inbox.needs_review() {
            return Ok(Some(Direction::Receive));
        }
        if journal.outbound.is_some() {
            return Ok(Some(Direction::Send));
        }
        if journal.inbox.feed.as_ref() != Some(&observed.observation.feed)
            || journal.inbox.has_pending_page()
            || journal.inbox.snapshot.is_some()
            || journal.inbox.applied_cursor.is_none()
        {
            return Ok(Some(Direction::Receive));
        }
        let current = primary::current_locked(self.library, journal, &device)?;
        if !journal.pending()?.is_empty() || journal.has_preservation_work() {
            return Ok(Some(Direction::Send));
        }
        for e in current.values() {
            let confirmed = journal
                .confirmed(e.id)
                .map(|c| c.envelope.hash())
                .transpose()?;
            if confirmed.as_ref() != Some(&e.hash()?) {
                return Ok(Some(Direction::Send));
            }
        }
        if journal
            .projection_knowledge()
            .values()
            .any(|e| !e.deleted && !current.contains_key(&e.id) && !journal.known_absence(e.id))
        {
            return Ok(Some(Direction::Send));
        }
        (self.validate_session)()?;
        Ok(None)
    }

    pub fn synchronize(
        &self,
        remote: &mut impl Remote,
        limits: Limits,
    ) -> receiver::Result<Progress> {
        limits.validate()?;
        let mut progress = Progress {
            status: Status::MoreWork(Direction::Receive),
            received_records: 0,
            applied_records: 0,
            completed_pages: 0,
            accepted: 0,
            confirmed: 0,
            conflicts: 0,
            rejected: 0,
            batches: 0,
            receive_attempts: 0,
            send_attempts: 0,
        };
        let mut direction = Direction::Receive;
        let mut received_current = false;
        let mut deferred = None;
        loop {
            match direction {
                Direction::Receive => {
                    if progress.receive_attempts == limits.receive {
                        progress.status = Status::MoreWork(direction);
                        return Ok(progress);
                    }
                    progress.receive_attempts += 1;
                    let received = self.receive(remote, 1)?;
                    progress.received_records += received.received_records;
                    progress.applied_records += received.applied_records;
                    progress.completed_pages += received.completed_pages;
                    received_current = received.status == receiver::Status::Current;
                    direction = match received.status {
                        receiver::Status::Current => {
                            if let Some(status) = deferred {
                                progress.status = Status::Sending(status);
                                return Ok(progress);
                            }
                            match self.sync_direction(remote)? {
                                Some(direction) => direction,
                                None => {
                                    progress.status = Status::Current;
                                    return Ok(progress);
                                }
                            }
                        }
                        receiver::Status::MorePages => Direction::Receive,
                        receiver::Status::SendFirst => {
                            if let Some(status) = deferred {
                                progress.status = Status::Sending(status);
                                return Ok(progress);
                            }
                            Direction::Send
                        }
                        status => {
                            progress.status = Status::Receiving(status);
                            return Ok(progress);
                        }
                    };
                }
                Direction::Send => {
                    if progress.send_attempts == limits.send {
                        progress.status = Status::MoreWork(direction);
                        return Ok(progress);
                    }
                    progress.send_attempts += 1;
                    let sent = self.send(remote, 1)?;
                    progress.accepted += sent.accepted;
                    progress.confirmed += sent.confirmed;
                    progress.conflicts += sent.conflicts;
                    progress.rejected += sent.rejected;
                    progress.batches += sent.batches;
                    direction = match sent.status {
                        sender::Status::Settled => {
                            if received_current && sent.batches == 0 {
                                match self.sync_direction(remote)? {
                                    Some(direction) => direction,
                                    None => {
                                        progress.status = Status::Current;
                                        return Ok(progress);
                                    }
                                }
                            } else {
                                Direction::Receive
                            }
                        }
                        sender::Status::MoreBatches => Direction::Send,
                        sender::Status::ReceiveFirst => Direction::Receive,
                        sender::Status::ReadOnly => {
                            if received_current && sent.batches == 0 {
                                progress.status = Status::Sending(sent.status);
                                return Ok(progress);
                            }
                            // A role change after an acknowledged write cannot
                            // starve receiving. An unacknowledged original offer
                            // still blocks the next fetch and stops without replay.
                            deferred = Some(sent.status);
                            Direction::Receive
                        }
                        status @ sender::Status::ServerDeferred { .. } => {
                            // Rejected/processed backoff packets no longer block
                            // receiving. Read new cloud changes, without retrying
                            // these mutations again in this same action.
                            deferred = Some(status);
                            Direction::Receive
                        }
                        status => {
                            progress.status = Status::Sending(status);
                            return Ok(progress);
                        }
                    };
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "sync_tests.rs"]
mod tests;
