//! A reviewed source decision keeps every distinct held source version as data.
//! No current offers, receipts or queued targets are replaced by this proposal.
use super::*;
use std::collections::{BTreeMap, BTreeSet};

/// Find the exact raw v1 owner in the already pinned local view. This never
/// infers an original from its UUID alone or grants the source any consent.
pub(super) fn find_prerequisite_sources(
    journal: &Journal,
    current: &BTreeMap<Uuid, Envelope>,
    id: Uuid,
) -> Result<Vec<Envelope>> {
    let known = journal.projection_knowledge();
    let ids: BTreeSet<_> = current
        .keys()
        .chain(known.keys())
        .chain(journal.projected().keys())
        .copied()
        .collect();
    let mut found = None;
    for source_id in ids {
        let Some(live) = retained_live(journal, current.get(&source_id), source_id) else {
            continue;
        };
        if merge::secure_variants(live)
            .map_err(|_| Failure::PreservationRequired)?
            .iter()
            .any(|variant| variant.copy_id == id)
        {
            if found.is_some() {
                return Err(Failure::PreservationRequired);
            }
            found = Some(current_group(journal, current, live)?);
        }
    }
    Ok(found.unwrap_or_default())
}

pub(super) fn prerequisite_variant(
    sources: &[Envelope],
    id: Uuid,
) -> Result<Option<merge::SecureVariant>> {
    let mut found = None;
    for source in sources {
        for variant in merge::secure_variants(source).map_err(|_| Failure::PreservationRequired)? {
            if variant.copy_id == id {
                if found.is_some() {
                    return Err(Failure::PreservationRequired);
                }
                found = Some(variant);
            }
        }
    }
    Ok(found)
}

/// Freeze authenticated raw-carrier evidence in the decision's journal clone.
/// No source primary outcome, receipt, absence or deletion consent is created.
pub(super) fn materialize_prerequisite(
    id: Uuid,
    sources: &[Envelope],
    journal: &Journal,
    current: &BTreeMap<Uuid, Envelope>,
    keys: &crate::materializer::Keyring<'_>,
) -> primary::Result<Journal> {
    let source = sources.first().ok_or(primary::Failure::InvalidState)?;
    let group = primary::DeletionGroup::prepare(source.id, sources.to_vec(), journal, keys)?;
    if !group.originals().contains_key(&id) {
        return Err(primary::Failure::InvalidState);
    }
    let dependencies: Vec<_> = group
        .sources()
        .iter()
        .map(|source| {
            let copies = group
                .originals()
                .values()
                .filter(|copy| merge::provenance(copy).is_some_and(|p| p.source_id == source.id))
                .cloned()
                .collect();
            (source.clone(), copies)
        })
        .collect();
    let mut targets = BTreeMap::new();
    for participant in group.sources().iter().chain(group.originals().values()) {
        let target = journal
            .local_intent(participant.id, current.get(&participant.id))?
            .or_else(|| journal.entry(participant.id).map(|entry| &entry.desired))
            .unwrap_or(participant);
        targets.insert(participant.id, target.clone());
    }
    let mut next = journal.clone();
    next.stage_generation(
        crate::crypto::random()?,
        &dependencies,
        &group.originals().values().cloned().collect::<Vec<_>>(),
        &targets,
        &journal.release_targets(current)?,
    )?;
    next.materialize_preservation(id, keys)
}

pub(super) fn current_group(
    journal: &Journal,
    current: &BTreeMap<Uuid, Envelope>,
    live: &Envelope,
) -> Result<Vec<Envelope>> {
    let mut links = BTreeMap::<Uuid, BTreeSet<Uuid>>::new();
    for (a, b) in journal.preservation_links() {
        links.entry(a).or_default().insert(b);
        links.entry(b).or_default().insert(a);
    }
    let mut queue = std::collections::VecDeque::from([live.id]);
    let mut seen = BTreeSet::new();
    let mut sources = Vec::new();
    while let Some(id) = queue.pop_front() {
        if !seen.insert(id) {
            continue;
        }
        if let Some(neighbors) = links.get(&id) {
            queue.extend(neighbors);
        }
        let physical = current.get(&id);
        let intent = journal.local_intent(id, physical)?;
        let selected = if id == live.id {
            Some(live)
        } else {
            intent
                .or(physical)
                .or_else(|| journal.entry(id).map(|entry| &entry.desired))
        };
        let Some(selected) = selected else {
            continue;
        };
        let mut selected = selected.clone();
        if let Some(physical) = physical {
            for (key, value) in &physical.extensions {
                if key.starts_with(merge::CONFLICT_PREFIX) {
                    if selected.deleted || selected.extensions.get(key).is_some_and(|v| v != value)
                    {
                        return Err(Failure::PreservationRequired);
                    }
                    selected.extensions.insert(key.clone(), value.clone());
                }
            }
        }
        if merge::has_unknown_version(&selected) {
            return Err(Failure::PreservationRequired);
        }
        let variants =
            merge::secure_variants(&selected).map_err(|_| Failure::PreservationRequired)?;
        queue.extend(variants.iter().map(|v| v.copy_id));
        if !variants.is_empty() {
            sources.push(selected);
        }
    }
    Ok(sources)
}

pub(super) fn versions(
    journal: &Journal,
    id: Uuid,
    live: Option<&Envelope>,
) -> Result<Vec<Envelope>> {
    if !journal.is_preservation_source(id) {
        return Ok(Vec::new());
    }
    let frames = journal.preservation_generations(id)?;
    let own_version = |source: &Envelope| {
        let mut own = source.clone();
        own.extensions
            .retain(|key, _| !key.starts_with(merge::CONFLICT_PREFIX));
        own
    };
    let live = live.map(own_version);
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for e in frames.iter().flat_map(|frame| {
        frame
            .sources
            .iter()
            .map(|(source, _)| source)
            .chain(frame.targets.values())
    }) {
        let own = own_version(e);
        if e.id == id && !e.deleted && Some(&own) != live.as_ref() && seen.insert(own.hash()?) {
            result.push(e.clone());
        }
    }
    Ok(result)
}

fn carrier(source: &Envelope) -> Result<Envelope> {
    let mut holder = source.clone();
    // Its older losing variants already have owners in the current graph.
    // This new copy represents the source's own exact retained body/version.
    holder
        .extensions
        .retain(|key, _| !key.starts_with(merge::CONFLICT_PREFIX));
    let (key, value) = merge::secure_variant(source).map_err(|_| Failure::PreservationRequired)?;
    holder.extensions.insert(key, value);
    Ok(holder)
}

pub(super) fn identities(sources: &[Envelope]) -> Result<Vec<(Uuid, Uuid, String)>> {
    sources
        .iter()
        .map(|source| {
            if source.secure {
                let variant = merge::secure_variants(&carrier(source)?)
                    .map_err(|_| Failure::PreservationRequired)?
                    .pop()
                    .ok_or(Failure::PreservationRequired)?;
                Ok((variant.copy_id, source.id, variant.fingerprint))
            } else {
                let copy = merge::plain_copy(source).map_err(|_| Failure::PreservationRequired)?;
                let p = merge::provenance(&copy).ok_or(Failure::PreservationRequired)?;
                Ok((copy.id, p.source_id, p.fingerprint))
            }
        })
        .collect()
}

pub(super) fn copies(
    sources: &[Envelope],
    journal: &Journal,
    keys: &crate::materializer::Keyring<'_>,
    prepared: Option<&BTreeMap<Uuid, Envelope>>,
) -> primary::Result<Vec<Envelope>> {
    let mut result = BTreeMap::new();
    for source in sources {
        if source.secure {
            let holder = carrier(source).map_err(|_| primary::Failure::InvalidState)?;
            let variant = merge::secure_variants(&holder)?
                .pop()
                .ok_or(primary::Failure::InvalidState)?;
            let frozen = result
                .get(&variant.copy_id)
                .or_else(|| prepared.and_then(|copies| copies.get(&variant.copy_id)))
                .or_else(|| journal.preservation_original(variant.copy_id))
                .map(|copy| BTreeMap::from([(copy.id, copy.clone())]))
                .unwrap_or_default();
            let evidence = crate::materializer::Evidence::prepare(&[holder], keys, &frozen)?;
            for copy in evidence.copies().values() {
                retain_copy(&mut result, copy.clone())?;
            }
        } else {
            let copy = merge::plain_copy(source)?;
            retain_copy(&mut result, copy)?;
        }
    }
    Ok(result.into_values().collect())
}

fn retain_copy(copies: &mut BTreeMap<Uuid, Envelope>, copy: Envelope) -> primary::Result<()> {
    if copies.get(&copy.id).is_some_and(|before| before != &copy) {
        return Err(primary::Failure::ReservedCollision);
    }
    copies.insert(copy.id, copy);
    Ok(())
}
