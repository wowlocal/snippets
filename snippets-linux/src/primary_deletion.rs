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
            }
        }
        Ok(())
    }
    pub(super) fn permits(&self, id: Uuid, current: Option<&Envelope>) -> bool {
        id == self.id
            && current.is_some_and(|current| self.sources.iter().any(|source| source == current))
    }
    pub(super) fn attach(&self, prepared: &mut Prepared) {
        for source in &self.sources {
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
    }
}
