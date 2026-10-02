//! Authenticate every archived generation before the single final primary WAL.
//! Only ciphertext and local graph data survive the bounded key borrow.
use super::*;
use crate::journal::RestorationGeneration;

pub(super) fn prepare(
    history: &[RestorationGeneration],
    physical: &BTreeMap<Uuid, Envelope>,
    expected: &ReadSet,
    keys: Option<&Keyring<'_>>,
) -> Result<Vec<([u8; 16], RestorationGeneration)>> {
    prepare_data(history, physical, expected, keys, None)
}
pub(super) fn prepare_repair(
    repair: &crate::journal::PreservationRepair,
    journal: &Journal,
    physical: &BTreeMap<Uuid, Envelope>,
    expected: &ReadSet,
    keys: Option<&Keyring<'_>>,
) -> Result<Vec<([u8; 16], RestorationGeneration)>> {
    prepare_data(
        std::slice::from_ref(repair.frame()),
        physical,
        expected,
        keys,
        Some(journal),
    )
}
fn prepare_data(
    history: &[RestorationGeneration],
    physical: &BTreeMap<Uuid, Envelope>,
    expected: &ReadSet,
    keys: Option<&Keyring<'_>>,
    current: Option<&Journal>,
) -> Result<Vec<([u8; 16], RestorationGeneration)>> {
    let mut result = Vec::new();
    for data in history {
        let mut generation = data.clone();
        let mut originals = BTreeMap::new();
        for (source, copies) in &generation.sources {
            merge::validate(source)?;
            for copy in copies {
                let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
                if p.source_id != source.id || originals.insert(copy.id, copy.clone()).is_some() {
                    return Err(Failure::InvalidState);
                }
            }
        }
        for e in generation
            .targets
            .values()
            .chain(generation.sources.iter().map(|(e, _)| e))
            .chain(originals.values())
        {
            merge::validate(e)?;
            if !expected.contains_key(&e.id) {
                return Err(Failure::InvalidState);
            }
            if e.deleted
                && (generation.targets.get(&e.id) != Some(e)
                    || generation.sources.iter().any(|(source, _)| source == e)
                    || originals.values().any(|copy| copy == e)
                    || physical.contains_key(&e.id)
                    || !current
                        .map(|journal| {
                            Ok::<_, Failure>(
                                journal.known_absence(e.id) && journal.deletion_approved(e)?,
                            )
                        })
                        .transpose()?
                        .unwrap_or(false))
            {
                return Err(Failure::InvalidState);
            }
            if !equal(
                physical.get(&e.id),
                expected.get(&e.id).and_then(Option::as_ref),
            )? {
                return Err(Failure::StalePrimary);
            }
            if let Some(p) = merge::provenance(e)
                && physical.get(&e.id).is_some_and(|occupant| {
                    !merge::matching_provenance(occupant, p.source_id, &p.fingerprint)
                })
            {
                return Err(Failure::ReservedCollision);
            }
            if e.secure && !e.deleted {
                materializer::authenticate(e, keys.ok_or(Failure::VaultLocked)?, true)?;
            }
            if !merge::secure_variants(e)?.is_empty() && keys.is_none() {
                return Err(Failure::VaultLocked);
            }
        }
        if let Some(keys) = keys {
            let sources: Vec<_> = generation.sources.iter().map(|(e, _)| e.clone()).collect();
            let evidence = Evidence::prepare(&sources, keys, &originals)?;
            for (id, copy) in evidence.copies() {
                if !expected.contains_key(id) {
                    return Err(Failure::InvalidState);
                }
                generation
                    .targets
                    .entry(*id)
                    .or_insert_with(|| copy.clone());
                let parent = merge::provenance(copy)
                    .ok_or(Failure::InvalidState)?
                    .source_id;
                let copies = &mut generation
                    .sources
                    .iter_mut()
                    .find(|(e, _)| e.id == parent)
                    .ok_or(Failure::InvalidState)?
                    .1;
                if !copies.iter().any(|e| e.id == *id) {
                    copies.push(copy.clone());
                }
            }
        }
        result.push((crypto::random()?, generation));
    }
    Ok(result)
}
