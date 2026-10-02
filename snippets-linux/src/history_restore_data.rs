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
}
fn crypto_failure(error: crate::materializer::Failure) -> Failure {
    Failure::Primary(error.into())
}
pub(super) fn resolve(archived: &Journal, keys: Option<&Keyring<'_>>) -> Result<Data> {
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
            let evidence = Evidence::prepare(&sources, keys, &originals).map_err(crypto_failure)?;
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
        let evidence = Evidence::prepare(std::slice::from_ref(&source), keys, &frozen)
            .map_err(crypto_failure)?;
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
    })
}
