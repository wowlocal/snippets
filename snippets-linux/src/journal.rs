//! Owner-worker journal kernel. Exact offers, their original CAS versions and
//! copy-before-source ordering survive a crash. The inbound owner is wired to
//! explicit app receiving/sending and missing-snapshot review. Account/key
//! replacement and absence recovery remain separate admission boundaries.
use crate::{
    canonical::Value,
    cloud::{Binding, RecordVersion},
    crypto::{self, RootKey},
    merge,
    model::{self, Error, Library},
    wire::Envelope,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    InvalidState,
    ScopeReview,
    GenerationExhausted,
    StaleCheckpoint,
    Storage,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<Error> for Failure {
    fn from(_: Error) -> Self {
        Self::InvalidState
    }
}
impl From<merge::Failure> for Failure {
    fn from(_: merge::Failure) -> Self {
        Self::InvalidState
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Scope {
    pub membership: Binding,
    pub dataset: Binding,
}
#[derive(Clone, PartialEq)]
pub struct Offered {
    pub envelope: Envelope,
    pub generation: u64,
    pub record_version: Option<RecordVersion>,
}
#[derive(Clone, PartialEq)]
pub struct Confirmed {
    pub envelope: Envelope,
    pub record_version: RecordVersion,
}
#[derive(Clone, PartialEq, Default)]
pub enum ReviewAncestor {
    #[default]
    Unknown,
    // Known absence is distinct from an unknown state; retain the older merge
    // ancestor separately until a post-review edit/deletion supersedes it.
    Reviewed {
        primary: Option<Box<Envelope>>,
        previous_merge: Option<Box<Envelope>>,
    },
}
#[derive(Clone, PartialEq)]
pub struct Entry {
    pub desired: Envelope,
    pub offered: Option<Offered>,
    pub generation: u64,
    pub review: ReviewAncestor,
}
#[derive(Clone, PartialEq)]
pub(crate) struct DeletionApproval {
    pub hash: String,
    pub ancestor: Option<Envelope>,
}
#[derive(Clone, PartialEq)]
struct Requirement {
    copy_id: Uuid,
    fingerprint: String,
    carrier: Option<(String, Value)>,
    snapshot: Option<Envelope>,
    offered: Option<Offered>,
    accepted_version: Option<RecordVersion>,
}
#[derive(Clone, PartialEq)]
struct Dependency {
    source: Envelope,
    requirements: BTreeMap<String, Requirement>,
    source_offered: Option<Offered>,
    source_accepted_version: Option<RecordVersion>,
}
#[derive(Clone, PartialEq)]
struct PreservationGeneration {
    nonce: [u8; 16],
    targets: BTreeMap<Uuid, Envelope>,
    dependencies: BTreeMap<Uuid, Dependency>,
}
const MAX_PRESERVATION_GENERATIONS: usize = 8;

/// Archived local data only. This view cannot carry server versions, offers,
/// acceptance, permissions, cursors, scope or operation identities.
#[derive(Clone)]
pub(crate) struct RestorationGeneration {
    pub targets: BTreeMap<Uuid, Envelope>,
    pub sources: Vec<(Envelope, Vec<Envelope>)>,
}
/// Current local graph data selected by the journal for a reviewed remote
/// prerequisite deletion. Construction cannot import historical server facts.
pub(crate) struct PreservationRepair {
    id: Uuid,
    frame: RestorationGeneration,
    requires_vault: bool,
}
impl PreservationRepair {
    pub(crate) fn id(&self) -> Uuid {
        self.id
    }
    pub(crate) fn frame(&self) -> &RestorationGeneration {
        &self.frame
    }
    pub(crate) fn needs_vault(&self) -> bool {
        self.requires_vault
    }
}
#[derive(Clone, PartialEq)]
pub struct CarrierResolution {
    pub source_id: Uuid,
    pub expected: BTreeMap<String, Value>,
    pub resolved: Envelope,
}
#[derive(Clone, PartialEq)]
pub struct Journal {
    scope: Scope,
    entries: BTreeMap<Uuid, Entry>,
    confirmed: BTreeMap<Uuid, Confirmed>,
    dependencies: BTreeMap<Uuid, Dependency>,
    delivery: BTreeMap<Uuid, Envelope>,
    generations: Vec<PreservationGeneration>,
    pub(crate) projected: BTreeMap<Uuid, Envelope>,
    pub(crate) primary_intent: Option<crate::primary::Intent>,
    pub(crate) primary_epoch: Option<[u8; 16]>,
    pub(crate) inbox: crate::inbound::Inbox,
    pub(crate) outbound: Option<crate::outbound::Packet>,
    pub(crate) key_epoch: Option<u64>,
    pub(crate) deletion_approvals: BTreeMap<Uuid, DeletionApproval>,
}
fn same(a: &Envelope, b: &Envelope) -> Result<bool> {
    Ok(a.hash()? == b.hash()?)
}
impl Journal {
    /// Fictional historical-client fixtures only. Raw carrier fingerprints,
    /// UUIDs, sealed bodies and offer/receipt generations stay exact.
    #[cfg(test)]
    pub(crate) fn test_omit_vault_metadata(&mut self, mask: u8) {
        self.test_transform_own_records(|e| {
            if e.secure {
                if mask & 1 != 0 {
                    e.extensions.remove("vaultKID");
                }
                if mask & 2 != 0 {
                    e.extensions.remove("vaultContentHash");
                }
            }
        });
    }
    #[cfg(test)]
    pub(crate) fn test_transform_own_records(&mut self, mut own: impl FnMut(&mut Envelope)) {
        assert!(self.outbound.is_none() && self.primary_intent.is_none());
        fn graph(graph: &mut BTreeMap<Uuid, Dependency>, own: &mut impl FnMut(&mut Envelope)) {
            for edge in graph.values_mut() {
                own(&mut edge.source);
                if let Some(offer) = &mut edge.source_offered {
                    own(&mut offer.envelope);
                }
                for requirement in edge.requirements.values_mut() {
                    if let Some(e) = &mut requirement.snapshot {
                        own(e);
                    }
                    if let Some(offer) = &mut requirement.offered {
                        own(&mut offer.envelope);
                    }
                }
            }
        }
        for e in self
            .projected
            .values_mut()
            .chain(self.delivery.values_mut())
        {
            own(e);
        }
        for entry in self.entries.values_mut() {
            own(&mut entry.desired);
            if let Some(offer) = &mut entry.offered {
                own(&mut offer.envelope);
            }
            if let ReviewAncestor::Reviewed {
                primary,
                previous_merge,
            } = &mut entry.review
            {
                for e in primary.iter_mut().chain(previous_merge) {
                    own(e);
                }
            }
        }
        for confirmed in self.confirmed.values_mut() {
            own(&mut confirmed.envelope);
        }
        graph(&mut self.dependencies, &mut own);
        for generation in &mut self.generations {
            for e in generation.targets.values_mut() {
                own(e);
            }
            graph(&mut generation.dependencies, &mut own);
        }
    }

    /// Frozen local restoration may add intent and preservation dependencies,
    /// but cannot import historical server acceptance, permissions or packets.
    pub(crate) fn preserves_transport_state(&self, next: &Self) -> bool {
        self.scope == next.scope
            && self.key_epoch == next.key_epoch
            && self.confirmed == next.confirmed
            && self.inbox == next.inbox
            && self.outbound == next.outbound
            && self.deletion_approvals.iter().all(|(id, approval)| {
                next.deletion_approvals
                    .get(id)
                    .is_none_or(|saved| saved == approval)
            })
            && next
                .deletion_approvals
                .iter()
                .all(|(id, approval)| self.deletion_approvals.get(id) == Some(approval))
            && self.entries.iter().all(|(id, entry)| {
                entry.offered.as_ref().is_none_or(|offer| {
                    next.entries.get(id).and_then(|e| e.offered.as_ref()) == Some(offer)
                })
            })
            && self
                .dependencies
                .iter()
                .all(|(id, edge)| next.dependencies.get(id) == Some(edge))
            && self
                .delivery
                .iter()
                .all(|(id, target)| next.delivery.get(id) == Some(target))
            && next.generations.starts_with(&self.generations)
    }
    pub fn new(scope: Scope) -> Self {
        Self {
            scope,
            entries: BTreeMap::new(),
            confirmed: BTreeMap::new(),
            dependencies: BTreeMap::new(),
            delivery: BTreeMap::new(),
            generations: Vec::new(),
            projected: BTreeMap::new(),
            primary_intent: None,
            primary_epoch: None,
            inbox: crate::inbound::Inbox::default(),
            outbound: None,
            key_epoch: None,
            deletion_approvals: BTreeMap::new(),
        }
    }
    pub fn entry(&self, id: Uuid) -> Option<&Entry> {
        self.entries.get(&id)
    }
    pub fn scope(&self) -> &Scope {
        &self.scope
    }
    pub fn inbox(&self) -> &crate::inbound::Inbox {
        &self.inbox
    }
    pub(crate) fn has_preservation_work(&self) -> bool {
        !self.dependencies.is_empty() || !self.delivery.is_empty() || !self.generations.is_empty()
    }
    pub(crate) fn dependency_owns(&self, id: Uuid) -> bool {
        self.dependencies.contains_key(&id)
            || self
                .dependencies
                .values()
                .any(|d| d.requirements.values().any(|r| r.copy_id == id))
            || self.delivery.contains_key(&id)
            || self.generations.iter().any(|g| g.targets.contains_key(&id))
    }
    pub(crate) fn deletion_approved(&self, e: &Envelope) -> Result<bool> {
        let hash = e.hash()?;
        Ok(e.deleted
            && self
                .deletion_approvals
                .get(&e.id)
                .is_some_and(|a| hash == a.hash))
    }
    pub(crate) fn primary_deletion_approved(
        &self,
        e: &Envelope,
        current: &Envelope,
    ) -> Result<bool> {
        let current_hash = current.hash()?;
        Ok(self.deletion_approved(e)?
            && self
                .deletion_approvals
                .get(&e.id)
                .and_then(|a| a.ancestor.as_ref())
                .is_some_and(|a| a.hash().is_ok_and(|hash| hash == current_hash)))
    }
    pub(crate) fn approve_deletion(
        &mut self,
        e: &Envelope,
        ancestor: Option<Envelope>,
    ) -> Result<()> {
        if !e.deleted || self.key_epoch.is_none() {
            return Err(Failure::InvalidState);
        }
        let mut next = self.clone();
        next.deletion_approvals.insert(
            e.id,
            DeletionApproval {
                hash: e.hash()?,
                ancestor,
            },
        );
        codec::validate(&next)?;
        *self = next;
        Ok(())
    }
    pub(crate) fn known_absence(&self, id: Uuid) -> bool {
        if self.entry(id).is_some_and(|e| !e.desired.deleted) {
            return false;
        }
        self.projected.get(&id).is_some_and(|e| e.deleted)
            || self.entry(id).is_some_and(|e| {
                e.desired.deleted
                    && matches!(e.review, ReviewAncestor::Reviewed { primary: None, .. })
            })
            || (self.entry(id).is_none() && self.confirmed(id).is_some_and(|c| c.envelope.deleted))
    }
    pub(crate) fn review_absence(&mut self, id: Uuid, previous: Option<Envelope>) -> Result<()> {
        let entry = self.entries.get_mut(&id).ok_or(Failure::InvalidState)?;
        if !entry.desired.deleted {
            return Err(Failure::InvalidState);
        }
        entry.review = ReviewAncestor::Reviewed {
            primary: None,
            previous_merge: previous.map(Box::new),
        };
        Ok(())
    }
    pub(crate) fn retains_offer(&self, offer: &Offered) -> bool {
        self.entries
            .get(&offer.envelope.id)
            .and_then(|e| e.offered.as_ref())
            == Some(offer)
            || self.dependencies.values().any(|edge| {
                edge.source_offered.as_ref() == Some(offer)
                    || edge
                        .requirements
                        .values()
                        .any(|r| r.offered.as_ref() == Some(offer))
            })
    }
    pub(crate) fn requires_source_ack(&self, offer: &Offered) -> bool {
        self.dependencies
            .get(&offer.envelope.id)
            .is_some_and(|edge| {
                edge.source_offered.as_ref() == Some(offer)
                    && edge.source_accepted_version.is_none()
            })
    }
    pub(crate) fn is_prerequisite_offer(&self, offer: &Offered) -> bool {
        self.dependencies.values().any(|edge| {
            edge.requirements
                .values()
                .any(|r| r.offered.as_ref() == Some(offer))
        })
    }
    pub fn confirmed(&self, id: Uuid) -> Option<&Confirmed> {
        self.confirmed.get(&id)
    }
    pub(crate) fn merge_ancestor(&self, id: Uuid) -> Option<&Envelope> {
        self.confirmed(id)
            .map(|c| &c.envelope)
            .or_else(|| match &self.entry(id)?.review {
                ReviewAncestor::Reviewed { previous_merge, .. } => previous_merge.as_deref(),
                ReviewAncestor::Unknown => None,
            })
    }
    /// A reviewed journal-only desire is not overwritten by the unchanged
    /// primary image which the user reviewed. A later primary edit supersedes it.
    pub(crate) fn local_intent<'a>(
        &'a self,
        id: Uuid,
        current: Option<&'a Envelope>,
    ) -> Result<Option<&'a Envelope>> {
        if let Some(entry) = self.entry(id)
            && let ReviewAncestor::Reviewed { primary, .. } = &entry.review
        {
            let unchanged = match (primary.as_deref(), current) {
                (Some(a), Some(b)) => same(a, b)?,
                (None, None) => true,
                _ => false,
            };
            if unchanged {
                return Ok(Some(&entry.desired));
            }
        }
        Ok(current)
    }
    /// Explicit review only, after a complete snapshot proved a missing record.
    /// Preserve current and journal-only intent plus immutable C0 snapshots;
    /// invalidate every old cursor, offer, CAS and acceptance generation together.
    pub(crate) fn resume_missing_snapshot(
        &mut self,
        current: &BTreeMap<Uuid, Envelope>,
        feed: crate::inbound::Feed,
    ) -> Result<()> {
        if !self.inbox.needs_review()
            || self.primary_intent.is_some()
            || self.key_epoch.is_some_and(|epoch| epoch != feed.key_epoch)
        {
            return Err(Failure::InvalidState);
        }
        self.reset_preserving_intent(current, self.scope.clone(), feed, true)
    }
    /// Explicit account/key review only. Previous server confirmations and
    /// deletion consent cannot become facts in the newly admitted scope.
    pub(crate) fn resume_scope(
        &mut self,
        current: &BTreeMap<Uuid, Envelope>,
        scope: Scope,
        feed: crate::inbound::Feed,
    ) -> Result<()> {
        if self.primary_intent.is_some() {
            return Err(Failure::InvalidState);
        }
        self.reset_preserving_intent(current, scope, feed, false)
    }
    fn reset_preserving_intent(
        &mut self,
        current: &BTreeMap<Uuid, Envelope>,
        scope: Scope,
        feed: crate::inbound::Feed,
        same_library: bool,
    ) -> Result<()> {
        let mut candidate = self.clone();
        candidate.scope = scope;
        for entry in candidate.entries.values_mut() {
            entry.generation = 1;
            entry.offered = None;
        }
        for confirmed in self
            .confirmed
            .values()
            .filter(|c| same_library && c.envelope.deleted)
        {
            if !candidate.entries.contains_key(&confirmed.envelope.id)
                && !current.contains_key(&confirmed.envelope.id)
            {
                candidate.desire(confirmed.envelope.clone())?;
            }
        }
        for envelope in current.values() {
            let journal_only = self.entry(envelope.id).is_some_and(|entry| {
                self.projected.get(&envelope.id) == Some(envelope) && entry.desired != *envelope
            });
            if !journal_only {
                candidate.desire(envelope.clone())?;
            }
        }
        for (id, entry) in &mut candidate.entries {
            entry.review = ReviewAncestor::Reviewed {
                primary: current.get(id).cloned().map(Box::new),
                previous_merge: if same_library {
                    self.merge_ancestor(*id).cloned().map(Box::new)
                } else {
                    None
                },
            };
            entry.offered = None;
            entry.generation = 1;
        }
        for edge in candidate.dependencies.values_mut() {
            edge.source_offered = None;
            edge.source_accepted_version = None;
            for requirement in edge.requirements.values_mut() {
                requirement.offered = None;
                requirement.accepted_version = None;
            }
        }
        candidate.confirmed.clear();
        candidate.outbound = None;
        candidate.deletion_approvals.clear();
        if !same_library {
            candidate.primary_epoch = None;
        }
        candidate.inbox = crate::inbound::Inbox::default();
        candidate.inbox.select_feed(feed.clone())?;
        candidate.key_epoch = Some(feed.key_epoch);
        candidate.projected = current.clone();
        codec::validate(&candidate)?;
        *self = candidate;
        Ok(())
    }
    pub fn projected(&self) -> &BTreeMap<Uuid, Envelope> {
        &self.projected
    }
    /// Immutable dependency snapshots, not latest desired/confirmed C1 values.
    pub fn conflict_snapshots(&self) -> BTreeMap<Uuid, Envelope> {
        self.dependencies
            .values()
            .flat_map(|edge| edge.requirements.values())
            .filter_map(|r| r.snapshot.as_ref().map(|s| (r.copy_id, s.clone())))
            .collect()
    }
    /// Data ownership only; callers cannot infer acknowledgement or CAS from it.
    pub(crate) fn preservation_links(&self) -> Vec<(Uuid, Uuid)> {
        self.dependencies
            .iter()
            .chain(self.generations.iter().flat_map(|g| &g.dependencies))
            .flat_map(|(id, edge)| edge.requirements.values().map(|r| (*id, r.copy_id)))
            .collect()
    }
    /// Archived data may be restored as new local intent. No offers, receipts,
    /// accepted versions, feed cursors or deletion permissions leave this view.
    pub(crate) fn preservation_data(&self) -> BTreeMap<Uuid, (Envelope, Vec<Envelope>)> {
        self.dependencies
            .iter()
            .map(|(id, edge)| {
                (
                    *id,
                    (
                        edge.source.clone(),
                        edge.requirements
                            .values()
                            .filter_map(|r| r.snapshot.clone())
                            .collect(),
                    ),
                )
            })
            .collect()
    }
    pub fn agreed_envelopes(&self) -> BTreeMap<Uuid, Envelope> {
        self.confirmed
            .iter()
            .map(|(id, c)| (*id, c.envelope.clone()))
            .collect()
    }
    pub fn projection_knowledge(&self) -> BTreeMap<Uuid, Envelope> {
        let mut known = self.agreed_envelopes();
        for (id, entry) in &self.entries {
            known.insert(
                *id,
                entry
                    .offered
                    .as_ref()
                    .map(|o| &o.envelope)
                    .unwrap_or(&entry.desired)
                    .clone(),
            );
        }
        for (id, edge) in &self.dependencies {
            if let Some(offered) = &edge.source_offered {
                known.insert(*id, offered.envelope.clone());
            } else if !self.entries.contains_key(id) {
                known.insert(*id, edge.source.clone());
            }
            for r in edge.requirements.values() {
                if let Some(offered) = &r.offered {
                    known.insert(r.copy_id, offered.envelope.clone());
                } else if let Some(snapshot) = &r.snapshot {
                    known.insert(r.copy_id, snapshot.clone());
                }
            }
        }
        for id in self
            .delivery
            .keys()
            .chain(self.generations.iter().flat_map(|g| g.targets.keys()))
        {
            if let Some(target) = self
                .entries
                .get(id)
                .map(|e| &e.desired)
                .or(self.projected.get(id))
            {
                known.insert(*id, target.clone());
            }
        }
        known
    }
    /// Captures already projected/stamped intent. Primary absence must be turned
    /// into an explicit tombstone by the future projection boundary, never here.
    pub fn desire(&mut self, envelope: Envelope) -> Result<()> {
        merge::validate(&envelope)?;
        if self.deletion_approvals.get(&envelope.id).is_some_and(|a| {
            envelope.hash().is_ok_and(|h| h != a.hash)
                && !self.retains_release_permission(envelope.id, a)
        }) {
            self.deletion_approvals.remove(&envelope.id);
        }
        if let Some(entry) = self.entries.get_mut(&envelope.id) {
            if same(&entry.desired, &envelope)? {
                return Ok(());
            }
            entry.generation = entry
                .generation
                .checked_add(1)
                .ok_or(Failure::GenerationExhausted)?;
            entry.desired = envelope;
        } else {
            self.entries.insert(
                envelope.id,
                Entry {
                    desired: envelope,
                    offered: None,
                    generation: 1,
                    review: ReviewAncestor::Unknown,
                },
            );
        }
        Ok(())
    }
    fn retains_release_permission(&self, id: Uuid, approval: &DeletionApproval) -> bool {
        // A send-only retry permit comes from an exact authorized packet and
        // authoritative CAS rejection. Later physical intent must not revoke
        // that original release, and the absent ancestor forbids primary delete.
        approval.ancestor.is_none()
            && self.dependencies.get(&id).is_some_and(|edge| {
                edge.source_accepted_version.is_none() && Self::prerequisites_accepted(edge)
            })
            && self
                .delivery
                .get(&id)
                .is_some_and(|e| e.deleted && e.hash().is_ok_and(|hash| hash == approval.hash))
    }
    /// Call before primary apply, then fsync the complete checkpoint. This method
    /// commits its in-memory change only after every snapshot validates.
    pub fn stage_conflict(&mut self, source: &Envelope, copies: &[Envelope]) -> Result<()> {
        merge::validate(source)?;
        let mut additions = BTreeMap::new();
        for variant in merge::secure_variants(source)? {
            additions.insert(
                variant.fingerprint.clone(),
                Requirement {
                    copy_id: variant.copy_id,
                    fingerprint: variant.fingerprint,
                    carrier: Some((
                        variant.extension_key.clone(),
                        source.extensions[&variant.extension_key].clone(),
                    )),
                    snapshot: None,
                    offered: None,
                    accepted_version: None,
                },
            );
        }
        let mut copy_ids = BTreeSet::new();
        for copy in copies {
            merge::validate(copy)?;
            let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
            if copy.deleted
                || p.source_id != source.id
                || !merge::valid_copy_identity(copy)
                || !copy_ids.insert(copy.id)
            {
                return Err(Failure::InvalidState);
            }
            if additions.contains_key(&p.fingerprint) {
                let requirement = &additions[&p.fingerprint];
                if copy.secure && requirement.copy_id == copy.id && requirement.carrier.is_some() {
                    // The protected/vault boundary supplies the authenticated C0
                    // separately. Provenance alone never freezes a secure body.
                    continue;
                }
                return Err(Failure::InvalidState);
            }
            additions.insert(
                p.fingerprint.clone(),
                Requirement {
                    copy_id: copy.id,
                    fingerprint: p.fingerprint,
                    carrier: None,
                    snapshot: Some(copy.clone()),
                    offered: None,
                    accepted_version: None,
                },
            );
        }
        if additions.is_empty() {
            return Ok(());
        }
        for addition in additions.values() {
            let existing_parent = self.dependencies.get(&source.id).is_some_and(|edge| {
                edge.requirements
                    .values()
                    .any(|r| r.copy_id == addition.copy_id)
            });
            if !existing_parent
                && self
                    .dependencies
                    .get(&addition.copy_id)
                    .is_some_and(|child| child.source_offered.is_some())
            {
                return Err(Failure::InvalidState);
            }
        }
        let mut edge = self
            .dependencies
            .get(&source.id)
            .cloned()
            .unwrap_or_else(|| Dependency {
                source: source.clone(),
                requirements: BTreeMap::new(),
                source_offered: None,
                source_accepted_version: None,
            });
        let (mut recovery, other) = if edge.source.hlc > source.hlc {
            (edge.source.clone(), source)
        } else {
            (source.clone(), &edge.source)
        };
        for (key, value) in &other.extensions {
            if key.starts_with(merge::CONFLICT_PREFIX) {
                insert_exact(&mut recovery.extensions, key, value)?;
            }
        }
        for requirement in edge.requirements.values().chain(additions.values()) {
            if let Some((key, value)) = &requirement.carrier {
                insert_exact(&mut recovery.extensions, key, value)?;
            }
        }
        merge::validate(&recovery)?;
        edge.source = recovery;
        for (fingerprint, addition) in additions {
            if edge.source_offered.is_some()
                && edge.source_accepted_version.is_none()
                && edge
                    .requirements
                    .get(&fingerprint)
                    .is_none_or(|existing| existing.carrier.is_none() && addition.carrier.is_some())
            {
                return Err(Failure::InvalidState);
            }
            if let Some(existing) = edge.requirements.get_mut(&fingerprint) {
                if existing.copy_id != addition.copy_id {
                    return Err(Failure::InvalidState);
                }
                match (&existing.carrier, &addition.carrier) {
                    (Some(a), Some(b)) if a != b => return Err(Failure::InvalidState),
                    (Some(_), None) => return Err(Failure::InvalidState),
                    (None, Some(_)) => {
                        existing.carrier = addition.carrier;
                        edge.source_offered = None;
                        edge.source_accepted_version = None;
                    }
                    _ => (),
                }
                if existing.snapshot.is_none() {
                    existing.snapshot = addition.snapshot;
                }
            } else {
                edge.requirements.insert(fingerprint, addition);
                edge.source_offered = None;
                edge.source_accepted_version = None;
            }
        }
        let mut candidate = self.clone();
        candidate.dependencies.insert(source.id, edge);
        codec::validate(&candidate)?;
        *self = candidate;
        Ok(())
    }
    /// Only call after the vault owner has authenticated/resealed this copy under
    /// its own deterministic UUID. Provenance alone cannot authenticate its body.
    pub fn freeze_authenticated_copy(&mut self, copy: &Envelope) -> Result<()> {
        merge::validate(copy)?;
        let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
        if copy.deleted || !merge::valid_copy_identity(copy) {
            return Err(Failure::InvalidState);
        }
        let requirement = self
            .dependencies
            .get_mut(&p.source_id)
            .and_then(|d| d.requirements.get_mut(&p.fingerprint))
            .ok_or(Failure::InvalidState)?;
        if requirement.copy_id != copy.id {
            return Err(Failure::InvalidState);
        }
        if let Some(snapshot) = &requirement.snapshot {
            if !same(snapshot, copy)? {
                return Err(Failure::InvalidState);
            }
        } else {
            requirement.snapshot = Some(copy.clone());
        }
        Ok(())
    }
    fn prerequisites_accepted(edge: &Dependency) -> bool {
        !edge.requirements.is_empty()
            && edge.requirements.values().all(|r| {
                r.accepted_version.is_some()
                    && r.snapshot.as_ref().is_some_and(|s| {
                        !s.deleted && merge::matching_provenance(s, edge.source.id, &r.fingerprint)
                    })
            })
    }
    /// A copy may itself own preservation work. Each copy has one parent;
    /// source/copy roles may overlap, but cycles never authorize delivery.
    /// Iterative leaf-first traversal keeps deep groups off the process stack.
    fn preservation_order(&self) -> Result<Vec<Uuid>> {
        Self::preservation_order_for(&self.dependencies)
    }
    fn preservation_order_for(dependencies: &BTreeMap<Uuid, Dependency>) -> Result<Vec<Uuid>> {
        let mut waiting = BTreeMap::new();
        let mut parents = BTreeMap::new();
        for (id, edge) in dependencies {
            let mut count = 0usize;
            for r in edge.requirements.values() {
                if dependencies.contains_key(&r.copy_id) {
                    if parents.insert(r.copy_id, *id).is_some() {
                        return Err(Failure::InvalidState);
                    }
                    count += 1;
                }
            }
            waiting.insert(*id, count);
        }
        let mut leaves: std::collections::VecDeque<_> = waiting
            .iter()
            .filter_map(|(id, count)| (*count == 0).then_some(*id))
            .collect();
        let mut order = Vec::with_capacity(waiting.len());
        while let Some(id) = leaves.pop_front() {
            order.push(id);
            if let Some(parent) = parents.get(&id) {
                let count = waiting.get_mut(parent).ok_or(Failure::InvalidState)?;
                *count = count.checked_sub(1).ok_or(Failure::InvalidState)?;
                if *count == 0 {
                    leaves.push_back(*parent);
                }
            }
        }
        if order.len() != dependencies.len() {
            return Err(Failure::InvalidState);
        }
        Ok(order)
    }
    fn preservation_ready(&self) -> Result<BTreeSet<Uuid>> {
        let mut ready = BTreeSet::new();
        for id in self.preservation_order()? {
            let edge = &self.dependencies[&id];
            if Self::prerequisites_accepted(edge)
                && edge.requirements.values().all(|r| {
                    !self.dependencies.contains_key(&r.copy_id) || ready.contains(&r.copy_id)
                })
            {
                ready.insert(id);
            }
        }
        Ok(ready)
    }
    /// Deterministic offers, never desired values beside an ambiguous old offer.
    /// Dependency-owned ids remain fenced through the later source acceptance.
    pub fn pending(&self) -> Result<Vec<Envelope>> {
        if self.primary_intent.is_some() {
            return Err(Failure::InvalidState);
        }
        let mut result = BTreeMap::new();
        let mut blocked = BTreeSet::new();
        blocked.extend(
            self.generations
                .iter()
                .flat_map(|g| g.targets.keys().copied()),
        );
        let ready = self.preservation_ready()?;
        let parents: BTreeSet<_> = self
            .dependencies
            .values()
            .flat_map(|edge| edge.requirements.values().map(|r| r.copy_id))
            .collect();
        // An already frozen offer precedes every newly eligible role for its
        // UUID. A group cannot bypass an ambiguous old CAS generation.
        let mut offers = BTreeMap::new();
        for offer in self
            .entries
            .values()
            .filter_map(|e| e.offered.as_ref())
            .chain(self.dependencies.values().flat_map(|edge| {
                edge.source_offered
                    .iter()
                    .filter(|_| edge.source_accepted_version.is_none())
                    .chain(
                        edge.requirements
                            .values()
                            .filter_map(|r| r.offered.as_ref()),
                    )
            }))
        {
            if offers
                .insert(offer.envelope.id, offer)
                .is_some_and(|old| old != offer)
            {
                return Err(Failure::InvalidState);
            }
            result.insert(offer.envelope.id, offer.envelope.clone());
        }
        for edge in self.dependencies.values() {
            blocked.insert(edge.source.id);
            for r in edge.requirements.values() {
                blocked.insert(r.copy_id);
            }
            if !Self::prerequisites_accepted(edge) {
                for r in edge.requirements.values() {
                    if !offers.contains_key(&r.copy_id)
                        && r.accepted_version.is_none()
                        && let Some(snapshot) = &r.snapshot
                        && (!self.dependencies.contains_key(&r.copy_id)
                            || ready.contains(&r.copy_id))
                    {
                        result.insert(r.copy_id, snapshot.clone());
                    }
                }
            } else if edge.source_offered.is_none()
                && !offers.contains_key(&edge.source.id)
                && !parents.contains(&edge.source.id)
                && ready.contains(&edge.source.id)
            {
                let source = self
                    .delivery
                    .get(&edge.source.id)
                    .or_else(|| self.entries.get(&edge.source.id).map(|e| &e.desired))
                    .unwrap_or(&edge.source);
                if !merge::has_unresolved(Some(source)) {
                    result.insert(source.id, source.clone());
                }
            }
        }
        for id in self.entries.keys().chain(self.delivery.keys()) {
            if blocked.contains(id)
                && (!self.delivery.contains_key(id)
                    || self.dependencies.contains_key(id)
                    || parents.contains(id))
            {
                continue;
            }
            if !offers.contains_key(id)
                && let Some(target) = self
                    .delivery
                    .get(id)
                    .or_else(|| self.entries.get(id).map(|e| &e.desired))
                && !self
                    .confirmed
                    .get(id)
                    .map(|c| same(target, &c.envelope))
                    .transpose()?
                    .unwrap_or(false)
            {
                result.insert(*id, target.clone());
            }
        }
        Ok(result.into_values().collect())
    }
    /// Freeze before writing the checkpoint, and send only after it is durable.
    /// Existing offers retain their exact bytes and original nullable CAS.
    pub fn mark_offered(&mut self, envelopes: &[Envelope]) -> Result<Vec<Offered>> {
        let pending: BTreeMap<_, _> = self.pending()?.into_iter().map(|e| (e.id, e)).collect();
        let mut candidate = self.clone();
        let mut result = Vec::new();
        let mut seen = BTreeSet::new();
        let ready = candidate.preservation_ready()?;
        for envelope in envelopes {
            if !seen.insert(envelope.id)
                || !pending
                    .get(&envelope.id)
                    .map(|p| same(p, envelope))
                    .transpose()?
                    .unwrap_or(false)
            {
                return Err(Failure::InvalidState);
            }
            let existing = candidate
                .entries
                .get(&envelope.id)
                .and_then(|e| e.offered.as_ref())
                .or_else(|| {
                    candidate.dependencies.values().find_map(|edge| {
                        edge.requirements
                            .values()
                            .find(|r| r.copy_id == envelope.id)
                            .and_then(|r| r.offered.as_ref())
                            .or_else(|| {
                                (edge.source.id == envelope.id
                                    && edge.source_accepted_version.is_none())
                                .then_some(edge.source_offered.as_ref())
                                .flatten()
                            })
                    })
                });
            if let Some(existing) = existing {
                if !same(&existing.envelope, envelope)? {
                    return Err(Failure::InvalidState);
                }
                result.push(existing.clone());
                continue;
            }
            let version = candidate
                .confirmed
                .get(&envelope.id)
                .map(|c| c.record_version.clone());
            let generation = candidate
                .entries
                .get(&envelope.id)
                .map_or(1, |e| e.generation);
            let parent = candidate.dependencies.iter().find_map(|(id, edge)| {
                edge.requirements
                    .iter()
                    .find(|(_, r)| r.copy_id == envelope.id)
                    .map(|(fingerprint, _)| (*id, fingerprint.clone()))
            });
            let target = if let Some((id, fingerprint)) = parent {
                &mut candidate
                    .dependencies
                    .get_mut(&id)
                    .unwrap()
                    .requirements
                    .get_mut(&fingerprint)
                    .unwrap()
                    .offered
            } else if let Some(edge) = candidate.dependencies.get_mut(&envelope.id) {
                if !ready.contains(&envelope.id) || merge::has_unresolved(Some(envelope)) {
                    return Err(Failure::InvalidState);
                }
                &mut edge.source_offered
            } else {
                if !candidate.entries.contains_key(&envelope.id) {
                    candidate.desire(envelope.clone())?;
                }
                &mut candidate
                    .entries
                    .get_mut(&envelope.id)
                    .ok_or(Failure::InvalidState)?
                    .offered
            };
            let offer = target.get_or_insert_with(|| Offered {
                envelope: envelope.clone(),
                generation,
                record_version: version,
            });
            result.push(offer.clone());
        }
        *self = candidate;
        Ok(result)
    }
    /// A fetched occupant can resolve an exact lost ACK. A later C1 carrying the
    /// same provenance never proves acceptance of C0. Deletions prove neither.
    pub fn record_confirmed(&mut self, envelope: Envelope, version: RecordVersion) -> Result<()> {
        merge::validate(&envelope)?;
        version.validate().map_err(|_| Failure::InvalidState)?;
        if self.deletion_approved(&envelope)? && !self.dependency_owns(envelope.id) {
            self.deletion_approvals.remove(&envelope.id);
        }
        for edge in self.dependencies.values() {
            if let Some(r) = edge
                .requirements
                .values()
                .find(|r| r.copy_id == envelope.id)
                && !envelope.deleted
                && !merge::matching_provenance(&envelope, edge.source.id, &r.fingerprint)
            {
                return Err(Failure::InvalidState);
            }
        }
        for edge in self.dependencies.values_mut() {
            for r in edge
                .requirements
                .values_mut()
                .filter(|r| r.copy_id == envelope.id)
            {
                if r.snapshot
                    .as_ref()
                    .map(|s| same(s, &envelope))
                    .transpose()?
                    .unwrap_or(false)
                {
                    r.accepted_version = Some(version.clone());
                    if r.offered
                        .as_ref()
                        .map(|o| same(&o.envelope, &envelope))
                        .transpose()?
                        .unwrap_or(false)
                    {
                        r.offered = None;
                    }
                }
            }
        }
        if let Some(entry) = self.entries.get_mut(&envelope.id)
            && entry
                .offered
                .as_ref()
                .map(|o| same(&o.envelope, &envelope))
                .transpose()?
                .unwrap_or(false)
        {
            entry.offered = None;
            entry.review = ReviewAncestor::Unknown;
        }
        if self
            .entries
            .get(&envelope.id)
            .is_some_and(|e| e.offered.is_none())
            && self
                .entries
                .get(&envelope.id)
                .map(|e| same(&e.desired, &envelope))
                .transpose()?
                .unwrap_or(false)
        {
            self.entries.remove(&envelope.id);
        }
        self.confirmed.insert(
            envelope.id,
            Confirmed {
                envelope,
                record_version: version,
            },
        );
        Ok(())
    }
    /// A source release needs an actual acknowledgement of its exact post-copy
    /// offer. An old carrier-free confirmed value cannot manufacture this proof.
    pub fn accept_offered(&mut self, offered: &Offered, version: RecordVersion) -> Result<()> {
        let mut candidate = self.clone();
        let id = offered.envelope.id;
        let mut found =
            candidate.entries.get(&id).and_then(|e| e.offered.as_ref()) == Some(offered);
        for edge in candidate.dependencies.values() {
            found |= edge.source_offered.as_ref() == Some(offered)
                || edge
                    .requirements
                    .values()
                    .any(|r| r.offered.as_ref() == Some(offered));
        }
        if !found {
            return Err(Failure::InvalidState);
        }
        candidate.record_confirmed(offered.envelope.clone(), version.clone())?;
        if let Some(edge) = candidate.dependencies.get_mut(&id)
            && edge.source_offered.as_ref() == Some(offered)
        {
            if !Self::prerequisites_accepted(edge) {
                return Err(Failure::InvalidState);
            }
            edge.source_accepted_version = Some(version);
        }
        if candidate.deletion_approved(&offered.envelope)?
            && !candidate.generations.iter().any(|generation| {
                (generation.dependencies.contains_key(&id)
                    || generation.dependencies.values().any(|edge| {
                        edge.requirements
                            .values()
                            .any(|requirement| requirement.copy_id == id)
                    }))
                    && generation
                        .targets
                        .get(&id)
                        .is_some_and(|e| same(e, &offered.envelope).unwrap_or(false))
            })
        {
            candidate.deletion_approvals.remove(&id);
        }
        *self = candidate;
        Ok(())
    }
    /// Only an authoritative fetch/rejection permits clearing an ambiguous offer.
    pub fn reject(&mut self, id: Uuid) {
        if let Some(e) = self.entries.get_mut(&id) {
            e.offered = None;
        }
        for edge in self.dependencies.values_mut() {
            if edge.source.id == id {
                edge.source_offered = None;
                edge.source_accepted_version = None;
            }
            for r in edge.requirements.values_mut().filter(|r| r.copy_id == id) {
                r.offered = None;
            }
        }
    }
    pub fn carrier_resolutions(
        &self,
        current: &BTreeMap<Uuid, Envelope>,
    ) -> Result<Vec<CarrierResolution>> {
        let mut result = Vec::new();
        for edge in self.dependencies.values() {
            let Some(source) = current.get(&edge.source.id) else {
                continue;
            };
            let expected: BTreeMap<_, _> = edge
                .requirements
                .values()
                .filter(|r| r.accepted_version.is_some())
                .filter_map(|r| r.carrier.clone())
                .collect();
            if expected.is_empty() {
                continue;
            }
            if let Some(resolved) = merge::resolve(source, &expected) {
                merge::validate(&resolved)?;
                result.push(CarrierResolution {
                    source_id: source.id,
                    expected,
                    resolved,
                });
            }
        }
        Ok(result)
    }
    /// Stage the same proven removal in latest intent and its reviewed primary
    /// anchor. The primary owner publishes this together with the file update.
    pub(crate) fn stage_carrier_resolution(
        &self,
        resolution: &CarrierResolution,
        current: &BTreeMap<Uuid, Envelope>,
    ) -> Result<Self> {
        if !self.carrier_resolutions(current)?.contains(resolution) {
            return Err(Failure::InvalidState);
        }
        let physical = current
            .get(&resolution.source_id)
            .ok_or(Failure::InvalidState)?;
        let mut intent = self
            .local_intent(resolution.source_id, Some(physical))?
            .ok_or(Failure::InvalidState)?
            .clone();
        for (key, value) in &resolution.expected {
            if intent.extensions.get(key).is_some_and(|e| e != value) {
                return Err(Failure::InvalidState);
            }
            intent.extensions.remove(key);
        }
        let mut next = self.clone();
        next.desire(intent)?;
        if let Some(entry) = next.entries.get_mut(&resolution.source_id)
            && let ReviewAncestor::Reviewed { primary, .. } = &mut entry.review
            && primary
                .as_deref()
                .map(|e| same(e, physical))
                .transpose()?
                .unwrap_or(false)
        {
            *primary = Some(Box::new(resolution.resolved.clone()));
        }
        codec::validate(&next)?;
        Ok(next)
    }
    /// Reread primary storage after every awaited operation, before pruning an
    /// edge. Restored carriers reopen the epoch and invalidate an older release.
    pub fn reconcile_dependencies(&mut self, current: &BTreeMap<Uuid, Envelope>) -> Result<()> {
        let mut candidate = self.clone();
        for source in current.values() {
            if !candidate.deferred_source(source)? && !merge::secure_variants(source)?.is_empty() {
                candidate.stage_conflict(source, &[])?;
            }
        }
        let mut completed = Vec::new();
        let ready = candidate.preservation_ready()?;
        let future_safe: BTreeSet<_> = current
            .values()
            .filter(|s| candidate.generation_primary_safe(s))
            .map(|s| s.id)
            .collect();
        let mut reviewed_deleted = BTreeSet::new();
        for id in candidate.dependencies.keys() {
            if current.contains_key(id) || !candidate.known_absence(*id) {
                continue;
            }
            let targets = candidate
                .entries
                .get(id)
                .map(|entry| &entry.desired)
                .into_iter()
                .chain(candidate.delivery.get(id))
                .chain(
                    candidate
                        .generations
                        .iter()
                        .filter_map(|g| g.targets.get(id)),
                );
            for target in targets {
                if target.deleted && candidate.deletion_approved(target)? {
                    // A received equal tombstone can consume ordinary intent.
                    // An earlier repair may still release C1 while this exact
                    // approved final deletion waits in an ordered generation.
                    reviewed_deleted.insert(*id);
                    break;
                }
            }
        }
        for (source_id, edge) in &mut candidate.dependencies {
            for r in edge.requirements.values_mut() {
                if r.accepted_version.is_some()
                    && let Some((key, value)) = &r.carrier
                    && let Some(target) = candidate.delivery.get_mut(source_id)
                {
                    if target
                        .extensions
                        .get(key)
                        .is_some_and(|actual| actual != value)
                    {
                        return Err(Failure::InvalidState);
                    }
                    target.extensions.remove(key);
                }
                for occupant in current
                    .get(&r.copy_id)
                    .into_iter()
                    .chain(candidate.confirmed.get(&r.copy_id).map(|c| &c.envelope))
                {
                    if !occupant.deleted
                        && !merge::matching_provenance(occupant, *source_id, &r.fingerprint)
                    {
                        return Err(Failure::InvalidState);
                    }
                }
                if r.accepted_version.is_some()
                    && let Some((key, value)) = &r.carrier
                {
                    if let Some(source) = current.get(source_id).filter(|s| !s.deleted) {
                        if let Some(actual) = source.extensions.get(key) {
                            if actual != value {
                                return Err(Failure::InvalidState);
                            }
                        } else {
                            r.carrier = None;
                        }
                    } else if reviewed_deleted.contains(source_id) {
                        // A reviewed source deletion has no physical carrier
                        // to clean. Retire only after this exact C0's actual
                        // acceptance; the source still needs its own ACK below.
                        r.carrier = None;
                    }
                }
            }
            let accepted_source = edge
                .source_offered
                .as_ref()
                .zip(candidate.confirmed.get(source_id))
                .map(|(o, c)| same(&o.envelope, &c.envelope))
                .transpose()?
                .unwrap_or(false);
            let primary_safe = current
                .get(source_id)
                .map(|s| {
                    !merge::has_unresolved(Some(s))
                        || (candidate.delivery.contains_key(source_id)
                            && future_safe.contains(source_id))
                })
                .unwrap_or(true);
            if accepted_source
                && edge.source_accepted_version.is_some()
                && primary_safe
                && Self::prerequisites_accepted(edge)
                && ready.contains(source_id)
                && edge.requirements.values().all(|r| r.carrier.is_none())
            {
                completed.push(*source_id);
            }
        }
        for id in completed {
            candidate.dependencies.remove(&id);
            candidate.delivery.remove(&id);
        }
        candidate.advance_generations()?;
        codec::validate(&candidate)?;
        *self = candidate;
        Ok(())
    }
}
fn insert_exact(values: &mut BTreeMap<String, Value>, key: &str, value: &Value) -> Result<()> {
    if let Some(existing) = values.get(key)
        && existing != value
    {
        return Err(Failure::InvalidState);
    }
    values.insert(key.into(), value.clone());
    Ok(())
}

/// Atomic encrypted storage, guarded by the same lock as ordinary/vault edits.
/// No files or keys are created by the app unless its future sync owner opts in.
pub struct Checkpoint {
    pub journal: Journal,
    snapshot: Option<Vec<u8>>,
}
impl Checkpoint {
    pub(crate) fn has_snapshot(&self) -> bool {
        self.snapshot.is_some()
    }
    pub(crate) fn seal_journal(
        journal: &Journal,
        key: &RootKey,
        salt: &[u8; 32],
    ) -> Result<Vec<u8>> {
        Ok(crypto::seal_checkpoint(
            &codec::encode(journal)?,
            key,
            salt,
        )?)
    }
    pub(crate) fn encrypted_image(&self, key: &RootKey, salt: &[u8; 32]) -> Result<Vec<u8>> {
        match &self.snapshot {
            Some(bytes) => Ok(bytes.clone()),
            None => Ok(crypto::seal_checkpoint(
                &codec::encode(&self.journal)?,
                key,
                salt,
            )?),
        }
    }
    pub(crate) fn from_encrypted(
        bytes: Vec<u8>,
        key: &RootKey,
        salt: &[u8; 32],
        scope: Scope,
    ) -> Result<Self> {
        let journal = codec::decode(&crypto::open_checkpoint(&bytes, key, salt)?, scope)?;
        Ok(Self {
            journal,
            snapshot: Some(bytes),
        })
    }
    /// Publish an already encrypted, authenticated replacement with the original
    /// file's CAS. This keeps a retained transition's exact completion receipt.
    pub(crate) fn publish_replacement_locked(
        &mut self,
        library: &Library,
        replacement: Self,
    ) -> Result<()> {
        let bytes = replacement.snapshot.ok_or(Failure::InvalidState)?;
        self.publish_locked(library, bytes)?;
        self.journal = replacement.journal;
        Ok(())
    }
    pub(crate) fn same_snapshot(&self, other: &Self) -> bool {
        self.snapshot == other.snapshot
    }
    pub fn load(library: &Library, key: &RootKey, salt: &[u8; 32], scope: Scope) -> Result<Self> {
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        Self::load_locked(library, key, salt, scope)
    }
    pub(crate) fn load_locked(
        library: &Library,
        key: &RootKey,
        salt: &[u8; 32],
        scope: Scope,
    ) -> Result<Self> {
        let directory = library.root.join("Sync");
        check_directory(&directory)?;
        let snapshot = model::read_regular_bounded(
            &directory.join("journal.bin"),
            crypto::MAX_CHECKPOINT_BYTES + 32,
        )
        .map_err(|_| Failure::Storage)?;
        let journal = match &snapshot {
            Some(bytes) => codec::decode(&crypto::open_checkpoint(bytes, key, salt)?, scope)?,
            None => Journal::new(scope),
        };
        Ok(Self { journal, snapshot })
    }
    pub fn save(&mut self, library: &Library, key: &RootKey, salt: &[u8; 32]) -> Result<()> {
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        crate::primary::require_ready(&library.root).map_err(|_| Failure::InvalidState)?;
        self.save_locked(library, key, salt)
    }
    pub(crate) fn save_locked(
        &mut self,
        library: &Library,
        key: &RootKey,
        salt: &[u8; 32],
    ) -> Result<()> {
        let bytes = crypto::seal_checkpoint(&codec::encode(&self.journal)?, key, salt)?;
        self.publish_locked(library, bytes)
    }
    fn publish_locked(&mut self, library: &Library, bytes: Vec<u8>) -> Result<()> {
        let directory = library.root.join("Sync");
        check_directory(&directory)?;
        let path = directory.join("journal.bin");
        let current = model::read_regular_bounded(&path, crypto::MAX_CHECKPOINT_BYTES + 32)
            .map_err(|_| Failure::Storage)?;
        if current != self.snapshot {
            return Err(Failure::StaleCheckpoint);
        }
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .or_else(|e| {
                if e.kind() == std::io::ErrorKind::AlreadyExists {
                    Ok(())
                } else {
                    Err(e)
                }
            })
            .map_err(|_| Failure::Storage)?;
        check_directory(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| Failure::Storage)?;
        // The first journal-first transaction also needs the Sync directory
        // entry durable in its parent before any primary apply can follow.
        fs::File::open(&library.root)
            .and_then(|file| file.sync_all())
            .map_err(|_| Failure::Storage)?;
        model::atomic_write(&path, &bytes).map_err(|_| Failure::Storage)?;
        self.snapshot = Some(bytes);
        Ok(())
    }
}
fn check_directory(path: &std::path::Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if m.is_dir() && !m.file_type().is_symlink() => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        _ => Err(Failure::Storage),
    }
}

#[path = "journal_codec.rs"]
mod codec;
#[path = "journal_generations.rs"]
mod generations;
#[cfg(test)]
#[path = "journal_tests.rs"]
mod tests;
