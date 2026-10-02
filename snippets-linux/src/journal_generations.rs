//! Pending local generations never own server offers or acceptance. Their
//! immutable copies and delivery targets wait behind the active source receipts.
use super::*;

fn owned(dependencies: &BTreeMap<Uuid, Dependency>) -> BTreeSet<Uuid> {
    dependencies
        .iter()
        .flat_map(|(id, edge)| {
            std::iter::once(*id).chain(edge.requirements.values().map(|r| r.copy_id))
        })
        .collect()
}
impl Journal {
    /// A reviewed absence may wait behind complete saved originals. Missing
    /// evidence still needs the vault/materialization owner; this never infers
    /// copy acceptance from the current record or its provenance.
    pub(crate) fn preservation_materialized(&self, id: Uuid) -> Result<bool> {
        codec::validate(self)?;
        let affected = self.preservation_component_ids(id);
        Ok(self
            .dependencies
            .iter()
            .chain(self.generations.iter().flat_map(|g| &g.dependencies))
            .filter(|(id, _)| affected.contains(id))
            .all(|(_, e)| e.requirements.values().all(|r| r.snapshot.is_some())))
    }
    fn preservation_component_ids(&self, id: Uuid) -> BTreeSet<Uuid> {
        let mut links: BTreeMap<Uuid, BTreeSet<Uuid>> = BTreeMap::new();
        for (a, b) in self.preservation_links() {
            links.entry(a).or_default().insert(b);
            links.entry(b).or_default().insert(a);
        }
        let mut affected = BTreeSet::from([id]);
        let mut queue = std::collections::VecDeque::from([id]);
        while let Some(id) = queue.pop_front() {
            if let Some(neighbors) = links.get(&id) {
                for next in neighbors {
                    if affected.insert(*next) {
                        queue.push_back(*next);
                    }
                }
            }
        }
        affected
    }
    pub(crate) fn preservation_generations(&self, id: Uuid) -> Result<Vec<RestorationGeneration>> {
        let affected = self.preservation_component_ids(id);
        let mut frames = self.restoration_generations()?;
        for frame in &mut frames {
            frame.targets.retain(|id, _| affected.contains(id));
            frame
                .sources
                .retain(|(source, _)| affected.contains(&source.id));
        }
        frames.retain(|frame| !frame.targets.is_empty() || !frame.sources.is_empty());
        Ok(frames)
    }
    pub(crate) fn can_release_deletion_source(&self, id: Uuid) -> bool {
        self.dependencies
            .get(&id)
            .is_some_and(|e| e.source_offered.is_none())
            && !self.delivery.contains_key(&id)
    }
    pub(crate) fn is_preservation_copy(&self, id: Uuid) -> bool {
        self.dependencies
            .values()
            .chain(
                self.generations
                    .iter()
                    .flat_map(|g| g.dependencies.values()),
            )
            .any(|edge| edge.requirements.values().any(|r| r.copy_id == id))
    }
    pub(crate) fn deletion_repair(
        &self,
        id: Uuid,
        current: &BTreeMap<Uuid, Envelope>,
        retained: &Envelope,
    ) -> Result<Option<PreservationRepair>> {
        codec::validate(self)?;
        if !self.dependencies.values().any(|edge| {
            edge.requirements
                .values()
                .any(|r| r.copy_id == id && r.accepted_version.is_some())
        }) {
            return Ok(None);
        }
        if retained.id != id || retained.deleted || !self.preservation_materialized(id)? {
            return Err(Failure::InvalidState);
        }
        let frames = self.preservation_generations(id)?;
        let mut requires_vault = false;
        for e in frames.iter().flat_map(|frame| {
            frame
                .targets
                .values()
                .chain(frame.sources.iter().map(|(e, _)| e))
                .chain(frame.sources.iter().flat_map(|(_, copies)| copies))
        }) {
            requires_vault |= e.secure || !merge::secure_variants(e)?.is_empty();
        }
        let mut frame = frames.into_iter().next().ok_or(Failure::InvalidState)?;
        frame.targets.clear();
        for (source, _) in &frame.sources {
            let target = self
                .local_intent(source.id, current.get(&source.id))?
                .or_else(|| {
                    self.entry(source.id)
                        .filter(|_| self.known_absence(source.id))
                        .map(|e| &e.desired)
                })
                .or_else(|| (source.id == id).then_some(retained))
                .ok_or(Failure::InvalidState)?;
            if target.deleted
                && (!self.known_absence(target.id) || !self.deletion_approved(target)?)
            {
                return Err(Failure::InvalidState);
            }
            let mut target = target.clone();
            // Earlier frames already retain every known original. Strip only
            // those exact carriers from this FUTURE delivery target; primary
            // and current intent stay unchanged until actual acknowledgements.
            let keys: Vec<_> = target
                .extensions
                .keys()
                .filter(|k| k.starts_with(merge::CONFLICT_PREFIX))
                .cloned()
                .collect();
            for key in keys {
                let value = &target.extensions[&key];
                let known = self
                    .dependencies
                    .iter()
                    .chain(self.generations.iter().flat_map(|g| &g.dependencies))
                    .filter(|(source_id, _)| **source_id == source.id)
                    .any(|(_, edge)| {
                        edge.requirements.values().any(|r| {
                            r.snapshot.is_some()
                                && r.carrier
                                    .as_ref()
                                    .is_some_and(|(k, v)| k == &key && v == value)
                        })
                    });
                if !known {
                    return Err(Failure::InvalidState);
                }
                target.extensions.remove(&key);
            }
            merge::validate(&target)?;
            frame.targets.insert(source.id, target);
        }
        for (_, copies) in &frame.sources {
            for copy in copies {
                frame.targets.entry(copy.id).or_insert_with(|| copy.clone());
            }
        }
        Ok(Some(PreservationRepair {
            id,
            frame,
            requires_vault,
        }))
    }
    /// The reviewed inbox record is an authoritative occupant with a different
    /// CAS. Retire only its impossible old prerequisite request; every unrelated
    /// wire byte and CAS stays with the original packet owner.
    pub(crate) fn retire_deleted_prerequisite(
        &mut self,
        deleted: &Envelope,
        version: &RecordVersion,
    ) -> Result<()> {
        if !deleted.deleted {
            return Err(Failure::InvalidState);
        }
        let retire = self.outbound.as_ref().is_some_and(|packet| {
            packet.receipts.is_none()
                && packet.offers.iter().any(|offer| {
                    offer.wire.id == deleted.id
                        && self.is_prerequisite_offer(&offer.offered)
                        && offer.offered.record_version.as_ref() != Some(version)
                })
        });
        if retire {
            self.reject(deleted.id);
            let packet = self.outbound.as_mut().ok_or(Failure::InvalidState)?;
            packet.offers.retain(|offer| offer.wire.id != deleted.id);
            if packet.offers.is_empty() {
                self.outbound = None;
            }
        }
        Ok(())
    }
    /// Replace only an exact tombstone that has no transmission owner. Queued
    /// frames never have offers; an ambiguous active deletion keeps its bytes
    /// and CAS until the actual receipt arrives, ahead of the new keep intent.
    pub(crate) fn supersede_unoffered_deletion(
        &mut self,
        deleted: &Envelope,
        keep: &Envelope,
    ) -> Result<()> {
        if !deleted.deleted
            || keep.deleted
            || deleted.id != keep.id
            || self.entry(keep.id).is_none_or(|e| e.desired != *keep)
        {
            return Err(Failure::InvalidState);
        }
        let hash = deleted.hash()?;
        let offered = self
            .entries
            .values()
            .filter_map(|e| e.offered.as_ref())
            .chain(
                self.dependencies
                    .values()
                    .filter_map(|e| e.source_offered.as_ref()),
            )
            .any(|o| o.envelope.id == deleted.id && o.envelope.hash().is_ok_and(|h| h == hash));
        let mut next = self.clone();
        if !offered
            && let Some(target) = next.delivery.get_mut(&deleted.id)
            && target.hash()? == hash
        {
            *target = keep.clone();
        }
        for generation in &mut next.generations {
            if let Some(target) = generation.targets.get_mut(&deleted.id)
                && target.hash()? == hash
            {
                *target = keep.clone();
            }
        }
        codec::validate(&next)?;
        *self = next;
        Ok(())
    }
    pub(crate) fn restoration_generations(&self) -> Result<Vec<RestorationGeneration>> {
        codec::validate(self)?;
        if self.primary_intent.is_some() {
            return Err(Failure::InvalidState);
        }
        let data = |graph: &BTreeMap<Uuid, Dependency>, mut targets: BTreeMap<Uuid, Envelope>| {
            let sources: Vec<_> = graph
                .values()
                .map(|edge| {
                    targets
                        .entry(edge.source.id)
                        .or_insert_with(|| edge.source.clone());
                    let copies: Vec<_> = edge
                        .requirements
                        .values()
                        .filter_map(|r| r.snapshot.clone())
                        .collect();
                    for copy in &copies {
                        targets.entry(copy.id).or_insert_with(|| copy.clone());
                    }
                    (edge.source.clone(), copies)
                })
                .collect();
            RestorationGeneration { targets, sources }
        };
        let mut result = Vec::new();
        let active = data(&self.dependencies, self.release_targets(&self.projected)?);
        if !active.targets.is_empty() {
            result.push(active);
        }
        result.extend(
            self.generations
                .iter()
                .map(|g| data(&g.dependencies, g.targets.clone())),
        );
        Ok(result)
    }
    pub(crate) fn has_queued_generations(&self) -> bool {
        !self.generations.is_empty()
    }
    pub(crate) fn release_targets(
        &self,
        current: &BTreeMap<Uuid, Envelope>,
    ) -> Result<BTreeMap<Uuid, Envelope>> {
        let mut targets = self.delivery.clone();
        for (id, edge) in &self.dependencies {
            if targets.contains_key(id) {
                continue;
            }
            let target = edge
                .source_offered
                .as_ref()
                .map(|o| &o.envelope)
                .or(self.local_intent(*id, current.get(id))?)
                .unwrap_or(&edge.source);
            merge::validate(target)?;
            targets.insert(*id, target.clone());
        }
        Ok(targets)
    }
    /// The primary owner already authenticated these data-only C0s and targets.
    /// Stage the entire reviewed batch before changing either primary file.
    pub(crate) fn stage_generation(
        &mut self,
        nonce: [u8; 16],
        sources: &[(Envelope, Vec<Envelope>)],
        authenticated: &[Envelope],
        targets: &BTreeMap<Uuid, Envelope>,
        old_targets: &BTreeMap<Uuid, Envelope>,
    ) -> Result<()> {
        self.stage_generation_impl(nonce, sources, authenticated, targets, old_targets, false)
    }
    pub(crate) fn stage_restoration_generation(
        &mut self,
        nonce: [u8; 16],
        generation: &RestorationGeneration,
        old_targets: &BTreeMap<Uuid, Envelope>,
    ) -> Result<()> {
        let authenticated: Vec<_> = generation
            .sources
            .iter()
            .flat_map(|(_, copies)| copies.iter())
            .filter(|e| e.secure)
            .cloned()
            .collect();
        self.stage_generation_impl(
            nonce,
            &generation.sources,
            &authenticated,
            &generation.targets,
            old_targets,
            true,
        )
    }
    fn stage_generation_impl(
        &mut self,
        nonce: [u8; 16],
        sources: &[(Envelope, Vec<Envelope>)],
        authenticated: &[Envelope],
        targets: &BTreeMap<Uuid, Envelope>,
        old_targets: &BTreeMap<Uuid, Envelope>,
        historical: bool,
    ) -> Result<()> {
        if nonce == [0; 16] || targets.is_empty() {
            return Err(Failure::InvalidState);
        }
        let mut fresh = Self::new(self.scope.clone());
        for (source, copies) in sources {
            fresh.stage_conflict(source, copies)?;
        }
        for copy in authenticated {
            fresh.freeze_authenticated_copy(copy)?;
        }
        let ids: BTreeSet<_> = targets
            .keys()
            .copied()
            .chain(owned(&fresh.dependencies))
            .collect();
        if ids.iter().all(|id| !self.dependency_owns(*id)) {
            let mut next = self.clone();
            next.dependencies.extend(fresh.dependencies);
            if historical {
                next.delivery.extend(targets.clone());
            }
            codec::validate(&next)?;
            *self = next;
            return Ok(());
        }
        // Replaying a published primary decision must not append the same
        // graph again. Compare only its data; existing offers and receipts stay
        // with the original owner. A later generation cannot take this path.
        let fresh_owned = owned(&fresh.dependencies);
        let replay = !historical
            && !fresh.dependencies.is_empty()
            && ids
                .iter()
                .all(|id| !self.dependency_owns(*id) || fresh_owned.contains(id))
            && self.delivery.keys().all(|id| !ids.contains(id))
            && self
                .generations
                .iter()
                .all(|g| g.targets.keys().all(|id| !ids.contains(id)))
            && fresh.dependencies.iter().all(|(id, edge)| {
                self.dependencies.get(id).is_some_and(|old| {
                    old.source == edge.source
                        && old.requirements.len() == edge.requirements.len()
                        && edge.requirements.iter().all(|(fingerprint, r)| {
                            old.requirements.get(fingerprint).is_some_and(|before| {
                                before.copy_id == r.copy_id
                                    && before.fingerprint == r.fingerprint
                                    && before.carrier == r.carrier
                                    && before.snapshot == r.snapshot
                            })
                        })
                })
            });
        if replay {
            return Ok(());
        }
        if self.generations.len() >= MAX_PRESERVATION_GENERATIONS {
            return Err(Failure::GenerationExhausted);
        }
        if self.generations.iter().any(|g| g.nonce == nonce) {
            return Err(Failure::InvalidState);
        }
        // Freeze all active sources linked to this batch, including ancestors
        // reached through an earlier queued generation. Later intent cannot
        // replace a current generation's exact post-copy source delivery.
        let mut links: BTreeMap<Uuid, BTreeSet<Uuid>> = BTreeMap::new();
        for (a, b) in self.preservation_links() {
            links.entry(a).or_default().insert(b);
            links.entry(b).or_default().insert(a);
        }
        let mut affected = ids;
        let mut queue: std::collections::VecDeque<_> = affected.iter().copied().collect();
        while let Some(id) = queue.pop_front() {
            if let Some(neighbors) = links.get(&id) {
                for next in neighbors {
                    if affected.insert(*next) {
                        queue.push_back(*next);
                    }
                }
            }
        }
        let mut next = self.clone();
        for id in affected {
            if next.dependencies.contains_key(&id) && !next.delivery.contains_key(&id) {
                next.delivery.insert(
                    id,
                    old_targets.get(&id).ok_or(Failure::InvalidState)?.clone(),
                );
            }
        }
        next.generations.push(PreservationGeneration {
            nonce,
            targets: targets.clone(),
            dependencies: fresh.dependencies,
        });
        codec::validate(&next)?;
        *self = next;
        Ok(())
    }
    fn future_carrier(&self, id: Uuid, key: &str, value: &Value) -> bool {
        self.generations.iter().any(|g| {
            g.targets
                .get(&id)
                .or_else(|| g.dependencies.get(&id).map(|e| &e.source))
                .is_some_and(|e| e.extensions.get(key) == Some(value))
        })
    }
    pub(super) fn deferred_source(&self, source: &Envelope) -> Result<bool> {
        if !self.delivery.contains_key(&source.id)
            && !self
                .generations
                .iter()
                .any(|g| g.targets.contains_key(&source.id))
        {
            return Ok(false);
        }
        for (key, value) in &source.extensions {
            if key.starts_with(merge::CONFLICT_PREFIX)
                && !self
                    .dependencies
                    .get(&source.id)
                    .is_some_and(|edge| edge.source.extensions.get(key) == Some(value))
                && !self.future_carrier(source.id, key, value)
            {
                return Err(Failure::InvalidState);
            }
        }
        Ok(true)
    }
    pub(super) fn generation_primary_safe(&self, source: &Envelope) -> bool {
        source
            .extensions
            .iter()
            .filter(|(key, _)| key.starts_with(merge::CONFLICT_PREFIX))
            .all(|(key, value)| self.future_carrier(source.id, key, value))
    }
    fn remove_confirmed_delivery(&mut self) -> Result<()> {
        let owned = owned(&self.dependencies);
        let mut finished = Vec::new();
        for (id, target) in &self.delivery {
            if !owned.contains(id)
                && self
                    .confirmed
                    .get(id)
                    .map(|c| same(target, &c.envelope))
                    .transpose()?
                    .unwrap_or(false)
            {
                finished.push(*id);
            }
        }
        for id in finished {
            self.delivery.remove(&id);
        }
        Ok(())
    }
    pub(super) fn advance_generations(&mut self) -> Result<()> {
        loop {
            self.remove_confirmed_delivery()?;
            let before = self.generations.len();
            let mut blocked: BTreeSet<_> = owned(&self.dependencies)
                .into_iter()
                .chain(self.delivery.keys().copied())
                .collect();
            let mut waiting = Vec::new();
            for generation in std::mem::take(&mut self.generations) {
                let ids: BTreeSet<_> = generation
                    .targets
                    .keys()
                    .copied()
                    .chain(owned_ids(&generation.dependencies))
                    .collect();
                if ids.is_disjoint(&blocked) {
                    for (id, edge) in generation.dependencies {
                        self.dependencies.insert(id, edge);
                    }
                    self.delivery.extend(generation.targets);
                } else {
                    waiting.push(generation);
                }
                blocked.extend(ids);
            }
            self.generations = waiting;
            // A reviewed deletion may also be the active source's post-copy
            // release. Its real ACK already covers the identical queued target;
            // do not leave an empty pending set behind a redundant delivery halt.
            // Dependency-owned targets still require their own original/source ACKs.
            self.remove_confirmed_delivery()?;
            // Confirmed fixed targets can unblock another queued frame immediately.
            // Each pass consumes a frame or stops; originals still require real ACKs.
            if self.generations.len() == before {
                return Ok(());
            }
        }
    }
}
fn owned_ids(dependencies: &BTreeMap<Uuid, Dependency>) -> BTreeSet<Uuid> {
    owned(dependencies)
}
