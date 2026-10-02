//! Ordered, encrypted-checkpoint inbox. Receiving a cursor never acknowledges
//! primary application, and an incomplete snapshot never proves record absence.
use crate::{
    cloud::Cursor,
    journal::{Confirmed, Failure, Result},
    merge, model,
};
use std::collections::BTreeSet;
use uuid::Uuid;

pub const PAGE_LIMIT: usize = 10;

// Opaque server feed identity. No diagnostic or plaintext serialization surface.
#[derive(Clone, PartialEq, Eq)]
pub struct Feed {
    pub(crate) epoch: Uuid,
    pub(crate) key_epoch: u64,
}
impl Feed {
    pub(crate) fn new(epoch: Uuid, key_epoch: u64) -> Result<Self> {
        let feed = Self { epoch, key_epoch };
        feed.validate()?;
        Ok(feed)
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if self.epoch.is_nil() || self.key_epoch == 0 || self.key_epoch > i64::MAX as u64 {
            return Err(Failure::InvalidState);
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq)]
pub(crate) struct Page {
    pub generation: u64,
    pub records: Vec<Confirmed>,
    pub position: usize,
    pub cursor: Cursor,
    pub full_snapshot: bool,
    pub has_more: bool,
}
#[derive(Clone, PartialEq)]
pub(crate) struct Snapshot {
    pub open: bool,
    pub seen: BTreeSet<Uuid>,
}
#[derive(Clone, PartialEq, Default)]
pub struct Inbox {
    pub(crate) feed: Option<Feed>,
    pub(crate) received: u64,
    pub(crate) completed: u64,
    pub(crate) fetched_cursor: Option<Cursor>,
    pub(crate) applied_cursor: Option<Cursor>,
    pub(crate) pending: Option<Page>,
    pub(crate) snapshot: Option<Snapshot>,
    pub(crate) review: bool,
}
impl Inbox {
    /// The old authenticated page must drain before changing the feed cursor.
    /// Key changes require explicit recovery, even when no page is queued.
    pub fn select_feed(&mut self, feed: Feed) -> Result<bool> {
        feed.validate()?;
        if self.review {
            return Err(Failure::ScopeReview);
        }
        if let Some(old) = &self.feed {
            if old.key_epoch != feed.key_epoch {
                return Err(Failure::ScopeReview);
            }
            if old == &feed {
                return Ok(false);
            }
            if self.pending.is_some() || self.snapshot.as_ref().is_some_and(|s| !s.open) {
                return Err(Failure::InvalidState);
            }
        }
        self.feed = Some(feed);
        self.fetched_cursor = None;
        self.applied_cursor = None;
        self.snapshot = None;
        Ok(true)
    }
    pub fn cursor(&self) -> Option<&Cursor> {
        self.fetched_cursor.as_ref()
    }
    pub fn next(&self) -> Option<&Confirmed> {
        self.pending
            .as_ref()
            .and_then(|p| p.records.get(p.position))
    }
    pub fn needs_review(&self) -> bool {
        self.review
    }
    pub fn has_pending_page(&self) -> bool {
        self.pending.is_some()
    }
    pub fn page_has_more(&self) -> bool {
        self.pending.as_ref().is_some_and(|p| p.has_more)
    }
    /// A server's cursor-invalid response may restart a feed, never discard
    /// queued records, outbound offers, confirmed ancestors or primary intent.
    pub fn restart_snapshot(&mut self) -> Result<()> {
        if self.review || self.pending.is_some() || self.feed.is_none() {
            return Err(Failure::InvalidState);
        }
        if self.snapshot.as_ref().is_some_and(|s| !s.open) {
            return Err(Failure::InvalidState);
        }
        self.fetched_cursor = None;
        self.applied_cursor = None;
        self.snapshot = None;
        Ok(())
    }
    /// Validate the complete authenticated page before publishing any part of it.
    /// Delta pages may contain several ordered generations of the same record.
    pub fn receive(
        &mut self,
        feed: &Feed,
        requested: Option<&Cursor>,
        records: Vec<Confirmed>,
        cursor: Cursor,
        full_snapshot: bool,
        has_more: bool,
    ) -> Result<()> {
        self.validate()?;
        cursor.validate().map_err(|_| Failure::InvalidState)?;
        if self.review
            || self.pending.is_some()
            || self.feed.as_ref() != Some(feed)
            || requested != self.fetched_cursor.as_ref()
            || records.len() > PAGE_LIMIT
            || (has_more && (records.is_empty() || requested == Some(&cursor)))
            || (!records.is_empty() && requested == Some(&cursor))
            || (requested.is_none() && !full_snapshot)
            || (requested.is_some() && full_snapshot != self.snapshot.is_some())
            || self.snapshot.as_ref().is_some_and(|s| !s.open)
        {
            return Err(Failure::InvalidState);
        }
        for record in &records {
            merge::validate(&record.envelope)?;
            record
                .record_version
                .validate()
                .map_err(|_| Failure::InvalidState)?;
        }
        let generation = self
            .received
            .checked_add(1)
            .ok_or(Failure::GenerationExhausted)?;
        let mut snapshot = self.snapshot.clone();
        if full_snapshot {
            let snapshot = snapshot.get_or_insert_with(|| Snapshot {
                open: true,
                seen: BTreeSet::new(),
            });
            for record in &records {
                if !snapshot.seen.insert(record.envelope.id)
                    || snapshot.seen.len() > model::MAX_SNIPPETS
                {
                    return Err(Failure::InvalidState);
                }
            }
            snapshot.open = has_more;
        }
        self.pending = Some(Page {
            generation,
            records,
            position: 0,
            cursor: cursor.clone(),
            full_snapshot,
            has_more,
        });
        self.snapshot = snapshot;
        self.received = generation;
        self.fetched_cursor = Some(cursor);
        Ok(())
    }
    /// Call only in the same checkpoint as the confirmed ancestor/local intent,
    /// after the journal-first primary transaction has completed.
    pub(crate) fn acknowledge_record(&mut self) -> Result<()> {
        let page = self.pending.as_mut().ok_or(Failure::InvalidState)?;
        if page.position >= page.records.len() {
            return Err(Failure::InvalidState);
        }
        page.position += 1;
        Ok(())
    }
    pub(crate) fn complete_page(&mut self) -> Result<()> {
        let page = self.pending.as_ref().ok_or(Failure::InvalidState)?;
        if page.position != page.records.len() {
            return Err(Failure::InvalidState);
        }
        self.completed = page.generation;
        self.applied_cursor = Some(page.cursor.clone());
        self.pending = None;
        Ok(())
    }
    /// Missing previously confirmed records are a sticky review halt, never
    /// synthesized deletions. Only the fully received AND applied snapshot counts.
    pub(crate) fn finish_snapshot(&mut self, known: impl Iterator<Item = Uuid>) -> Result<()> {
        let Some(snapshot) = &self.snapshot else {
            return Ok(());
        };
        if snapshot.open {
            return Ok(());
        }
        if self.pending.is_some() {
            return Err(Failure::InvalidState);
        }
        if known.into_iter().any(|id| !snapshot.seen.contains(&id)) {
            self.review = true;
        } else {
            self.snapshot = None;
        }
        Ok(())
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if let Some(feed) = &self.feed {
            feed.validate()?;
        } else if self.received != 0
            || self.completed != 0
            || self.fetched_cursor.is_some()
            || self.applied_cursor.is_some()
            || self.pending.is_some()
            || self.snapshot.is_some()
            || self.review
        {
            return Err(Failure::InvalidState);
        }
        for cursor in self.fetched_cursor.iter().chain(&self.applied_cursor) {
            cursor.validate().map_err(|_| Failure::InvalidState)?;
        }
        if self
            .completed
            .checked_add(u64::from(self.pending.is_some()))
            != Some(self.received)
            || (self.applied_cursor.is_some() && self.completed == 0)
            || self.applied_cursor.is_some() && self.fetched_cursor.is_none()
            || (self.pending.is_none() && self.fetched_cursor != self.applied_cursor)
            || (self.received == 0 && self.fetched_cursor.is_some())
        {
            return Err(Failure::InvalidState);
        }
        if let Some(page) = &self.pending {
            if self.review
                || page.generation != self.received
                || page.generation == 0
                || page.position > page.records.len()
                || page.records.len() > PAGE_LIMIT
                || self.fetched_cursor.as_ref() != Some(&page.cursor)
                || page.full_snapshot != self.snapshot.is_some()
                || (page.has_more && page.records.is_empty())
            {
                return Err(Failure::InvalidState);
            }
            if let Some(snapshot) = &self.snapshot {
                let mut ids = BTreeSet::new();
                if snapshot.open != page.has_more
                    || page.records.iter().any(|r| {
                        !ids.insert(r.envelope.id) || !snapshot.seen.contains(&r.envelope.id)
                    })
                {
                    return Err(Failure::InvalidState);
                }
            }
            for record in &page.records {
                merge::validate(&record.envelope)?;
                record
                    .record_version
                    .validate()
                    .map_err(|_| Failure::InvalidState)?;
            }
        }
        if let Some(snapshot) = &self.snapshot {
            if self.fetched_cursor.is_none()
                || snapshot.seen.len() > model::MAX_SNIPPETS
                || self.review && (snapshot.open || self.pending.is_some())
            {
                return Err(Failure::InvalidState);
            }
        } else if self.review {
            return Err(Failure::InvalidState);
        }
        Ok(())
    }
}
