//! Data-only evidence for a reviewed current preservation unit. Never consent.
use super::*;

pub(crate) struct DeletionGroup {
    id: Uuid,
    sources: Vec<Envelope>,
    evidence: Evidence,
}
impl DeletionGroup {
    pub(crate) fn id(&self) -> Uuid {
        self.id
    }
    pub(crate) fn prepare(
        id: Uuid,
        sources: Vec<Envelope>,
        journal: &Journal,
        keys: &Keyring<'_>,
    ) -> Result<Self> {
        let mut seen = BTreeSet::new();
        let mut frozen = BTreeMap::new();
        for source in &sources {
            if source.deleted || merge::has_unknown_version(source) || !seen.insert(source.id) {
                return Err(Failure::InvalidState);
            }
            if source.secure {
                materializer::authenticate(source, keys, true)?;
            }
            for variant in merge::secure_variants(source)? {
                if let Some(copy) = journal.preservation_original(variant.copy_id) {
                    frozen.insert(copy.id, copy.clone());
                }
            }
        }
        if !seen.contains(&id) {
            return Err(Failure::InvalidState);
        }
        let evidence = Evidence::prepare(&sources, keys, &frozen)?;
        Ok(Self {
            id,
            sources,
            evidence,
        })
    }
    pub(crate) fn originals(&self) -> &BTreeMap<Uuid, Envelope> {
        self.evidence.copies()
    }
    pub(crate) fn sources(&self) -> &[Envelope] {
        &self.sources
    }
    fn dependencies(&self) -> Vec<(Envelope, Vec<Envelope>)> {
        self.sources
            .iter()
            .map(|source| {
                let copies = self
                    .originals()
                    .values()
                    .filter(|copy| {
                        merge::provenance(copy).is_some_and(|p| p.source_id == source.id)
                    })
                    .cloned()
                    .collect();
                (source.clone(), copies)
            })
            .collect()
    }
    pub(crate) fn repair(
        &self,
        journal: &Journal,
        current: &BTreeMap<Uuid, Envelope>,
        retained: &Envelope,
    ) -> journal::Result<Option<crate::journal::PreservationRepair>> {
        journal.deletion_repair_with_sources(self.id, current, retained, &self.dependencies())
    }
    pub(crate) fn tombstone(&self, live: &Envelope, stamp: crate::clock::Hlc) -> Result<Envelope> {
        if !self
            .sources
            .iter()
            .any(|source| source.id == self.id && source == live)
        {
            return Err(Failure::InvalidState);
        }
        let mut resolved = live.clone();
        for variant in merge::secure_variants(live)? {
            resolved.extensions.remove(&variant.extension_key);
        }
        let mut deleted = resolved.tombstone(stamp.clone(), stamp.device().into(), true)?;
        deleted.extensions.insert(
            "userDeletion.v1".into(),
            crate::canonical::Value::Array(vec![crate::canonical::Value::text(live.hash()?)]),
        );
        Ok(deleted)
    }
    pub(super) fn validate(
        &self,
        journal: &Journal,
        primary: &BTreeMap<Uuid, Envelope>,
        expected: &ReadSet,
        outcomes: &[Outcome],
        keys: &Keyring<'_>,
    ) -> Result<()> {
        if !outcomes
            .iter()
            .any(|outcome| outcome.survivor.as_ref().is_some_and(|e| e.id == self.id))
        {
            return Err(Failure::InvalidState);
        }
        self.evidence.validate(&self.sources, keys)?;
        for source in &self.sources {
            if !expected.contains_key(&source.id) {
                return Err(Failure::InvalidState);
            }
            if let Some(current) = primary.get(&source.id) {
                let mut selected = if source.id == self.id {
                    current.clone()
                } else {
                    journal
                        .local_intent(source.id, Some(current))?
                        .unwrap_or(current)
                        .clone()
                };
                for (key, value) in &current.extensions {
                    if key.starts_with(merge::CONFLICT_PREFIX) {
                        if selected.extensions.get(key).is_some_and(|v| v != value) {
                            return Err(Failure::InvalidState);
                        }
                        selected.extensions.insert(key.clone(), value.clone());
                    }
                }
                if selected != *source {
                    return Err(Failure::StalePrimary);
                }
                if current.secure {
                    materializer::authenticate(current, keys, true)?;
                }
            } else if journal.local_intent(source.id, None)? != Some(source)
                && !journal
                    .entry(source.id)
                    .is_some_and(|entry| entry.desired == *source)
                && !(source.id == self.id
                    && (journal
                        .entry(source.id)
                        .is_some_and(|entry| entry.desired == *source)
                        || journal.projected().get(&source.id) == Some(source)
                        || journal
                            .confirmed(source.id)
                            .is_some_and(|c| c.envelope == *source)
                        || journal
                            .deletion_approvals
                            .get(&source.id)
                            .and_then(|a| a.ancestor.as_ref())
                            == Some(source)))
            {
                return Err(Failure::StalePrimary);
            }
            if source.secure {
                materializer::authenticate(source, keys, true)?;
            }
        }
        for copy in self.originals().values() {
            if !expected.contains_key(&copy.id) {
                return Err(Failure::InvalidState);
            }
            if let Some(current) = primary.get(&copy.id) {
                let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
                if !merge::matching_provenance(current, p.source_id, &p.fingerprint) {
                    return Err(Failure::ReservedCollision);
                }
                if current.secure {
                    materializer::authenticate(current, keys, true)?;
                }
            }
        }
        Ok(())
    }
    pub(super) fn permits(&self, id: Uuid, current: Option<&Envelope>) -> bool {
        id == self.id
            && current.is_some_and(|current| self.sources.iter().any(|source| source == current))
    }
    pub(super) fn attach(&self, prepared: &mut Prepared, journal: &Journal) -> Result<()> {
        let active = journal.preservation_data();
        for source in &self.sources {
            if journal.can_release_deletion_source(source.id)
                && let Some((old, copies)) = active.get(&source.id)
                && !old.deleted
                && prepared
                    .release_targets
                    .get(&source.id)
                    .is_none_or(|e| !e.deleted)
                && (source != old
                    || prepared
                        .dependencies
                        .iter()
                        .filter(|(e, _)| e.id == source.id)
                        .flat_map(|(_, originals)| originals)
                        .any(|copy| copies.iter().all(|old| old.id != copy.id)))
            {
                // New raw carriers belong to the later authenticated frame.
                // Finish the active source's own original body first, without
                // replacing any previously offered or fixed release target.
                let mut carriers = BTreeMap::new();
                for variant in merge::secure_variants(old)? {
                    if !copies.iter().any(|copy| copy.id == variant.copy_id) {
                        return Err(Failure::InvalidState);
                    }
                    carriers.insert(
                        variant.extension_key.clone(),
                        old.extensions[&variant.extension_key].clone(),
                    );
                }
                let resolved = merge::resolve(old, &carriers).ok_or(Failure::InvalidState)?;
                if merge::has_unresolved(Some(&resolved)) {
                    return Err(Failure::InvalidState);
                }
                prepared.release_targets.insert(source.id, resolved);
                // Consent for this newer decision belongs behind its newly
                // authenticated originals, never to the earlier active edge.
                prepared.deferred_deletion_sources.insert(source.id);
            }
            // Outcomes own selected delivery intent, which may be a tombstone.
            // The preservation edge owns the authenticated live carrier data,
            // including held versions added by those outcomes. Mixing the
            // tombstone into that edge would discard its raw prerequisites.
            for (staged, _) in &mut prepared.dependencies {
                if staged.id == source.id {
                    *staged = source.clone();
                }
            }
            let copies = self
                .originals()
                .values()
                .filter(|copy| merge::provenance(copy).is_some_and(|p| p.source_id == source.id))
                .cloned()
                .collect();
            prepared.dependencies.push((source.clone(), copies));
        }
        prepared
            .authenticated
            .extend(self.originals().values().cloned());
        Ok(())
    }
}
