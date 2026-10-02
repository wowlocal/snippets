//! Payload stays in the owner. This is a pure proposal, never authorization.
use super::*;
use crate::{clock::Hlc, journal::Journal, merge, wire::Envelope};
use std::collections::{BTreeMap, BTreeSet};

#[path = "history_restore_data.rs"]
mod data;

pub(super) struct Plan {
    pub outcomes: Vec<merge::Outcome>,
    pub expected: primary::ReadSet,
    pub next: Journal,
    pub summary: Summary,
    pub history: Vec<crate::journal::RestorationGeneration>,
}
fn equivalent(a: &Envelope, b: &Envelope) -> bool {
    let fields_match = match (&a.fields, &b.fields) {
        (Some(a), Some(b)) => {
            a.name == b.name
                && a.keyword == b.keyword
                && a.content == b.content
                && a.tags == b.tags
                && a.is_enabled == b.is_enabled
                && a.is_pinned == b.is_pinned
                && a.created_at == b.created_at
        }
        (None, None) => true,
        _ => false,
    };
    a.deleted == b.deleted && a.secure == b.secure && fields_match && a.extensions == b.extensions
}
#[cfg(test)]
pub(super) fn prepare(
    archived: &Journal,
    current: &Journal,
    physical: &BTreeMap<Uuid, Envelope>,
    stamp: Hlc,
    updated_at: f64,
) -> Result<Plan> {
    prepare_with_keys(archived, current, physical, stamp, updated_at, None)
}
pub(super) fn prepare_foreign(
    archived: &Journal,
    current: &Journal,
    physical: &BTreeMap<Uuid, Envelope>,
    stamp: Hlc,
    updated_at: f64,
    old: &crate::materializer::Keyring<'_>,
    keys: &crate::materializer::Keyring<'_>,
) -> Result<Plan> {
    if current.primary_intent.is_some() || !updated_at.is_finite() || stamp.device() == "00000000" {
        return Err(Failure::Changed);
    }
    let data = data::rekey(data::resolve_archived(archived, old)?, old, keys)?;
    prepare_data(data, current, physical, stamp, updated_at)
}
pub(super) fn prepare_with_keys(
    archived: &Journal,
    current: &Journal,
    physical: &BTreeMap<Uuid, Envelope>,
    stamp: Hlc,
    updated_at: f64,
    keys: Option<&crate::materializer::Keyring<'_>>,
) -> Result<Plan> {
    if current.primary_intent.is_some() || !updated_at.is_finite() || stamp.device() == "00000000" {
        return Err(Failure::Changed);
    }
    prepare_data(
        data::resolve(archived, keys)?,
        current,
        physical,
        stamp,
        updated_at,
    )
}
fn prepare_data(
    data: data::Data,
    current: &Journal,
    physical: &BTreeMap<Uuid, Envelope>,
    stamp: Hlc,
    updated_at: f64,
) -> Result<Plan> {
    if current.primary_intent.is_some() || !updated_at.is_finite() || stamp.device() == "00000000" {
        return Err(Failure::Changed);
    }
    let data::Data {
        saved,
        preservation,
        history,
        links: archived_links,
    } = data;
    if saved
        .values()
        .chain(physical.values())
        .chain(current.projection_knowledge().values())
        .chain(history.iter().flat_map(|g| g.targets.values()))
        .chain(history.iter().flat_map(|g| &g.sources).map(|(e, _)| e))
        .chain(
            history
                .iter()
                .flat_map(|g| &g.sources)
                .flat_map(|(_, copies)| copies),
        )
        .any(|envelope| envelope.hlc >= stamp)
    {
        return Err(Failure::Changed);
    }
    let mut plan = Plan {
        outcomes: Vec::new(),
        expected: BTreeMap::new(),
        next: current.clone(),
        summary: Summary::default(),
        history,
    };
    let mut selected = BTreeSet::new();
    for (id, e) in &saved {
        let live = physical.get(id);
        let intent = current.local_intent(*id, live)?;
        if !(live.is_some_and(|live| equivalent(live, e))
            && intent.is_some_and(|intent| equivalent(intent, e)))
        {
            selected.insert(*id);
        }
    }
    selected.extend(plan.history.iter().flat_map(|g| g.targets.keys().copied()));
    let mut links: BTreeMap<Uuid, BTreeSet<Uuid>> = BTreeMap::new();
    for (a, b) in archived_links.into_iter().chain(
        preservation
            .values()
            .flat_map(|(source, copies)| copies.iter().map(|copy| (source.id, copy.id))),
    ) {
        links.entry(a).or_default().insert(b);
        links.entry(b).or_default().insert(a);
    }
    let mut queue: std::collections::VecDeque<_> = selected.iter().copied().collect();
    while let Some(id) = queue.pop_front() {
        if let Some(neighbors) = links.get(&id) {
            for next in neighbors {
                if selected.insert(*next) {
                    queue.push_back(*next);
                }
            }
        }
    }
    for generation in &plan.history {
        for e in generation
            .targets
            .values()
            .chain(generation.sources.iter().map(|(e, _)| e))
            .chain(generation.sources.iter().flat_map(|(_, copies)| copies))
        {
            plan.expected.insert(e.id, physical.get(&e.id).cloned());
            for variant in merge::secure_variants(e)? {
                plan.expected
                    .insert(variant.copy_id, physical.get(&variant.copy_id).cloned());
            }
        }
    }
    for (id, saved) in saved {
        if !selected.contains(&id) {
            continue;
        }
        let live = physical.get(&id);
        let intent = current.local_intent(id, live)?;
        let mut target = saved.clone();
        target.hlc = stamp.clone();
        target.origin = stamp.device().into();
        target.fields.as_mut().ok_or(Failure::Changed)?.updated_at = updated_at;
        let mut outcome = merge::merge(None, intent, Some(&target))?;
        let survivor = outcome.survivor.as_mut().ok_or(Failure::Changed)?;
        // This explicit decision restores the selected fields, rather than
        // silently performing metadata LWW/tag union. Losing metadata is kept
        // with the current version's disabled preservation copy.
        survivor.fields = target.fields;
        survivor.secure = target.secure;
        let mut copies = BTreeMap::new();
        for copy in outcome.conflict_copies.drain(..) {
            copies.insert(copy.id, copy);
        }
        if let Some((source, originals)) = preservation.get(&id) {
            for (key, value) in &source.extensions {
                if key.starts_with(merge::CONFLICT_PREFIX) {
                    if survivor.extensions.get(key).is_some_and(|e| e != value) {
                        return Err(Failure::PreservationRequired);
                    }
                    survivor.extensions.insert(key.clone(), value.clone());
                }
            }
            for original in originals {
                if copies.get(&original.id).is_some_and(|e| e != original) {
                    return Err(Failure::PreservationRequired);
                }
                copies.insert(original.id, original.clone());
            }
        }
        let mut preserved = BTreeSet::new();
        for old in [intent, live]
            .into_iter()
            .flatten()
            .filter(|old| !old.deleted && !equivalent(old, &saved))
        {
            let hash = old.hash().map_err(|_| Failure::Changed)?;
            if !preserved.insert(hash) {
                continue;
            }
            // Preserve opaque carriers verbatim. A colliding future carrier
            // cannot be replaced just because its fields won this decision.
            for (key, value) in &old.extensions {
                if key.starts_with(merge::CONFLICT_PREFIX) {
                    if survivor
                        .extensions
                        .get(key)
                        .is_some_and(|existing| existing != value)
                    {
                        return Err(Failure::PreservationRequired);
                    }
                    survivor.extensions.insert(key.clone(), value.clone());
                }
            }
            if old.secure {
                let (key, value) = merge::secure_variant(old)?;
                if survivor
                    .extensions
                    .get(&key)
                    .is_some_and(|existing| existing != &value)
                {
                    return Err(Failure::PreservationRequired);
                }
                survivor.extensions.insert(key, value);
            } else {
                let copy = merge::plain_copy(old)?;
                if copies
                    .get(&copy.id)
                    .is_some_and(|existing| existing != &copy)
                {
                    return Err(Failure::PreservationRequired);
                }
                copies.insert(copy.id, copy);
            }
        }
        outcome.conflict_copies = copies.into_values().collect();
        merge::validate(outcome.survivor.as_ref().ok_or(Failure::Changed)?)?;
        plan.summary.restored_records += 1;
        plan.summary.added_records += usize::from(live.is_none());
        plan.summary.secure_records += usize::from(
            saved.secure
                || [intent, live].into_iter().flatten().any(|e| e.secure)
                || !merge::secure_variants(outcome.survivor.as_ref().ok_or(Failure::Changed)?)?
                    .is_empty(),
        );
        plan.summary.preserved_versions += preserved.len();
        for e in outcome.survivor.iter().chain(&outcome.conflict_copies) {
            plan.expected.insert(e.id, physical.get(&e.id).cloned());
            for variant in merge::secure_variants(e)? {
                plan.expected
                    .insert(variant.copy_id, physical.get(&variant.copy_id).cloned());
            }
        }
        plan.outcomes.push(outcome);
    }
    // Complete the read-set through existing edited copies' own carriers. The
    // apply boundary groups these descendants with their parent and retains
    // separately ordered generations for existing acknowledgement owners.
    let mut queue: std::collections::VecDeque<_> = plan.expected.keys().copied().collect();
    let mut visited = BTreeSet::new();
    while let Some(id) = queue.pop_front() {
        if !visited.insert(id) {
            continue;
        }
        if let Some(e) = physical.get(&id) {
            for variant in merge::secure_variants(e)? {
                plan.expected
                    .entry(variant.copy_id)
                    .or_insert_with(|| physical.get(&variant.copy_id).cloned());
                queue.push_back(variant.copy_id);
            }
        }
    }
    // Immutable C0 promises are staged separately. Explicit selected C1 intent
    // wins regardless of UUID sorting and outcome order.
    for copy in plan.outcomes.iter().flat_map(|o| &o.conflict_copies) {
        plan.next.desire(copy.clone())?;
    }
    for target in plan.outcomes.iter().filter_map(|o| o.survivor.as_ref()) {
        plan.next.desire(target.clone())?;
    }
    if plan.outcomes.is_empty() {
        return Err(Failure::Unavailable);
    }
    Ok(plan)
}

#[cfg(test)]
#[path = "history_restore_plan_tests.rs"]
mod tests;
