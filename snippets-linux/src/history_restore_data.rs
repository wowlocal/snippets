//! Resolve archived bodies, never archived deletion or transport authority.
use super::*;
use crate::{
    journal::RestorationGeneration,
    materializer::{Evidence, Keyring},
};

pub(super) struct Data {
    pub saved: BTreeMap<Uuid, Envelope>,
    pub preservation: BTreeMap<Uuid, (Envelope, Vec<Envelope>)>,
    pub history: Vec<RestorationGeneration>,
    pub links: Vec<(Uuid, Uuid)>,
}
fn crypto_failure(error: crate::materializer::Failure) -> Failure {
    Failure::Primary(error.into())
}
pub(super) fn resolve(archived: &Journal, keys: Option<&Keyring<'_>>) -> Result<Data> {
    resolve_inner(archived, keys, false)
}
pub(super) fn resolve_archived(archived: &Journal, keys: &Keyring<'_>) -> Result<Data> {
    resolve_inner(archived, Some(keys), true)
}
fn evidence(
    sources: &[Envelope],
    keys: &Keyring<'_>,
    originals: &BTreeMap<Uuid, Envelope>,
    archived: bool,
) -> Result<Evidence> {
    if archived {
        crate::materializer::Archived::new(keys).evidence(sources, originals)
    } else {
        Evidence::prepare(sources, keys, originals)
    }
    .map_err(crypto_failure)
}
fn resolve_inner(archived: &Journal, keys: Option<&Keyring<'_>>, legacy: bool) -> Result<Data> {
    if archived.primary_intent.is_some() {
        return Err(Failure::Changed);
    }
    let mut frames = archived.restoration_generations()?;
    let mut support = BTreeMap::new();
    let mut participants = BTreeSet::new();
    for frame in &mut frames {
        let mut originals = BTreeMap::new();
        for (source, copies) in &frame.sources {
            participants.insert(source.id);
            for copy in copies {
                let p = merge::provenance(copy).ok_or(Failure::PreservationRequired)?;
                if copy.deleted
                    || p.source_id != source.id
                    || originals.insert(copy.id, copy.clone()).is_some()
                {
                    return Err(Failure::PreservationRequired);
                }
                participants.insert(copy.id);
            }
        }
        let sources: Vec<_> = frame
            .sources
            .iter()
            .map(|(source, _)| source.clone())
            .collect();
        if sources
            .iter()
            .map(merge::secure_variants)
            .collect::<merge::Result<Vec<_>>>()?
            .iter()
            .any(|v| !v.is_empty())
        {
            let keys = keys.ok_or(primary::Failure::VaultLocked)?;
            // Exact retained C0 nonces win after authentication. A genuinely
            // missing C0 is sealed once here, before it becomes selected intent.
            let evidence = evidence(&sources, keys, &originals, legacy)?;
            for (id, copy) in evidence.copies() {
                let parent = merge::provenance(copy)
                    .ok_or(Failure::PreservationRequired)?
                    .source_id;
                let copies = &mut frame
                    .sources
                    .iter_mut()
                    .find(|(source, _)| source.id == parent)
                    .ok_or(Failure::PreservationRequired)?
                    .1;
                if !copies.iter().any(|c| c.id == *id) {
                    copies.push(copy.clone());
                }
                participants.insert(*id);
                frame.targets.entry(*id).or_insert_with(|| copy.clone());
            }
        }
        // Original copies are fallback bodies; a retained source/C1 or a later
        // ordered live target takes precedence for the explicit final selection.
        let mut live: BTreeMap<Uuid, Envelope> = BTreeMap::new();
        for e in frame
            .sources
            .iter()
            .flat_map(|(_, copies)| copies)
            .chain(frame.sources.iter().map(|(source, _)| source))
            .chain(frame.targets.values())
        {
            merge::validate(e)?;
            if !e.deleted && live.get(&e.id).is_none_or(|old| old.hlc <= e.hlc) {
                live.insert(e.id, e.clone());
            }
        }
        support.extend(live);
        // A tombstone parent has no restorable fields. Its live originals can
        // be kept independently, without manufacturing a parent or sending its
        // old deletion. Their provenance still identifies the original role.
        frame.targets.retain(|_, e| !e.deleted);
        for (_, copies) in &frame.sources {
            for copy in copies {
                frame.targets.entry(copy.id).or_insert_with(|| copy.clone());
            }
        }
        frame.sources.retain(|(source, _)| !source.deleted);
        for (source, _) in &frame.sources {
            frame
                .targets
                .entry(source.id)
                .or_insert_with(|| source.clone());
        }
    }
    let mut saved = archived.projected().clone();
    for (id, envelope) in archived.projection_knowledge() {
        if let Some(entry) = archived.entry(id) {
            saved.insert(id, entry.desired.clone());
        } else {
            saved.entry(id).or_insert(envelope);
        }
    }
    for frame in &frames {
        for (id, e) in &frame.targets {
            saved.entry(*id).or_insert_with(|| e.clone());
        }
    }
    for id in participants {
        if saved.get(&id).is_none_or(|e| e.deleted)
            && let Some(body) = support.get(&id)
        {
            saved.insert(id, body.clone());
        }
    }
    for envelope in saved.values() {
        merge::validate(envelope)?;
    }
    saved.retain(|_, e| !e.deleted);
    let active: BTreeSet<_> = archived.preservation_data().keys().copied().collect();
    let mut preservation: BTreeMap<_, _> = frames
        .first()
        .map(|frame| {
            frame
                .sources
                .iter()
                .filter(|(source, _)| active.contains(&source.id))
                .cloned()
                .map(|(source, copies)| (source.id, (source, copies)))
                .collect()
        })
        .unwrap_or_default();
    // The latest selected carrier can predate materialization/staging of its
    // dependency. Authenticate it too, and make an absent/deleted original an
    // explicit selected outcome rather than an implicit resurrection.
    let mut pending: std::collections::VecDeque<_> = saved.keys().copied().collect();
    let mut visited = BTreeSet::new();
    while let Some(id) = pending.pop_front() {
        if !visited.insert(id) {
            continue;
        }
        let source = saved[&id].clone();
        if merge::secure_variants(&source)?.is_empty() {
            continue;
        }
        let keys = keys.ok_or(primary::Failure::VaultLocked)?;
        let (_, copies) = preservation
            .entry(id)
            .or_insert_with(|| (source.clone(), Vec::new()));
        let frozen = copies.iter().map(|c| (c.id, c.clone())).collect();
        let evidence = evidence(std::slice::from_ref(&source), keys, &frozen, legacy)?;
        for (copy_id, copy) in evidence.copies() {
            if !copies.iter().any(|c| c.id == *copy_id) {
                copies.push(copy.clone());
            }
            if let std::collections::btree_map::Entry::Vacant(entry) = saved.entry(*copy_id) {
                entry.insert(copy.clone());
                pending.push_back(*copy_id);
            }
        }
    }
    let history = if archived.has_queued_generations() {
        frames
            .into_iter()
            .filter(|frame| !frame.targets.is_empty())
            .collect()
    } else {
        Vec::new()
    };
    Ok(Data {
        saved,
        preservation,
        history,
        links: archived.preservation_links(),
    })
}

pub(super) fn rekey(data: Data, old: &Keyring<'_>, current: &Keyring<'_>) -> Result<Data> {
    let records = data
        .saved
        .values()
        .chain(data.preservation.values().map(|(source, _)| source))
        .chain(data.preservation.values().flat_map(|(_, copies)| copies))
        .chain(data.history.iter().flat_map(|g| g.targets.values()))
        .chain(
            data.history
                .iter()
                .flat_map(|g| &g.sources)
                .map(|(source, _)| source),
        )
        .chain(
            data.history
                .iter()
                .flat_map(|g| &g.sources)
                .flat_map(|(_, copies)| copies),
        )
        .collect::<Vec<_>>();
    let mapping = crate::materializer::Rekey::prepare_archived(&records, old, current)
        .map_err(crypto_failure)?;
    let translated = |e: &Envelope| mapping.record(e).map_err(crypto_failure);
    let copies = |copies: &[Envelope]| copies.iter().map(translated).collect::<Result<Vec<_>>>();
    let saved = data
        .saved
        .values()
        .map(|e| Ok((mapping.id(e.id), translated(e)?)))
        .collect::<Result<_>>()?;
    let preservation = data
        .preservation
        .into_iter()
        .map(|(id, (source, originals))| {
            Ok((mapping.id(id), (translated(&source)?, copies(&originals)?)))
        })
        .collect::<Result<_>>()?;
    let history = data
        .history
        .into_iter()
        .map(|frame| {
            Ok(RestorationGeneration {
                targets: frame
                    .targets
                    .values()
                    .map(|e| Ok((mapping.id(e.id), translated(e)?)))
                    .collect::<Result<_>>()?,
                sources: frame
                    .sources
                    .into_iter()
                    .map(|(source, originals)| Ok((translated(&source)?, copies(&originals)?)))
                    .collect::<Result<_>>()?,
            })
        })
        .collect::<Result<_>>()?;
    Ok(Data {
        saved,
        preservation,
        history,
        links: data
            .links
            .into_iter()
            .map(|(a, b)| (mapping.id(a), mapping.id(b)))
            .collect(),
    })
}
