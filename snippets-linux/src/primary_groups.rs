//! Connected preservation units separate immutable evidence from selected intent.
//! A source and an edited copy in one batch share one read-set and apply decision.
use super::*;
use std::collections::VecDeque;

pub(super) struct Group {
    pub outcomes: Vec<usize>,
    pub targets: BTreeMap<Uuid, Envelope>,
    pub originals: Vec<Envelope>,
    pub authenticated: Vec<Envelope>,
    pub held: BTreeMap<Uuid, Envelope>,
    pub implicit: BTreeSet<Uuid>,
}
fn connect(edges: &mut BTreeMap<Uuid, BTreeSet<Uuid>>, a: Uuid, b: Uuid) {
    edges.entry(a).or_default().insert(b);
    edges.entry(b).or_default().insert(a);
}
fn related(edges: &mut BTreeMap<Uuid, BTreeSet<Uuid>>, envelope: &Envelope) -> Result<Vec<Uuid>> {
    edges.entry(envelope.id).or_default();
    if let Some(p) = merge::provenance(envelope) {
        connect(edges, envelope.id, p.source_id);
    }
    let mut copies = Vec::new();
    for variant in merge::secure_variants(envelope)? {
        connect(edges, envelope.id, variant.copy_id);
        copies.push(variant.copy_id);
    }
    Ok(copies)
}
fn occupant(copy: &Envelope, primary: &BTreeMap<Uuid, Envelope>) -> Result<Envelope> {
    let Some(current) = primary.get(&copy.id) else {
        return Ok(copy.clone());
    };
    let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
    if !merge::matching_provenance(current, p.source_id, &p.fingerprint) {
        return Err(Failure::ReservedCollision);
    }
    Ok(current.clone())
}
fn held_intent(
    copy: &Envelope,
    target: &Envelope,
    primary: &BTreeMap<Uuid, Envelope>,
    journal: &Journal,
) -> Result<Option<Envelope>> {
    let intent = journal
        .local_intent(copy.id, primary.get(&copy.id))?
        .cloned()
        .unwrap_or_else(|| target.clone());
    let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
    if !intent.deleted && !merge::matching_provenance(&intent, p.source_id, &p.fingerprint) {
        return Err(Failure::ReservedCollision);
    }
    Ok((intent != *copy).then_some(intent))
}
pub(super) fn prepare(
    outcomes: &[Outcome],
    primary: &BTreeMap<Uuid, Envelope>,
    journal: &Journal,
    expected: &ReadSet,
    keys: Option<&Keyring<'_>>,
    discover: bool,
) -> Result<Vec<Group>> {
    let mut selected = BTreeMap::new();
    let mut originals = BTreeMap::new();
    let mut owners = BTreeMap::new();
    let mut edges = BTreeMap::new();
    let mut queue = VecDeque::new();
    // Validate every explicit role before preparing any independently applicable group.
    for (index, outcome) in outcomes.iter().enumerate() {
        for e in outcome.survivor.iter().chain(&outcome.conflict_copies) {
            merge::validate(e)?;
            if !expected.contains_key(&e.id)
                || (e.extensions.contains_key(merge::COPY_PROVENANCE)
                    && !merge::valid_copy_identity(e))
            {
                return Err(Failure::InvalidState);
            }
            queue.extend(related(&mut edges, e)?);
            owners
                .entry(e.id)
                .or_insert_with(BTreeSet::new)
                .insert(index);
        }
        if let Some(e) = &outcome.survivor
            && selected.insert(e.id, e.clone()).is_some()
        {
            return Err(Failure::InvalidState);
        }
        for copy in &outcome.conflict_copies {
            let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
            if copy.deleted
                || outcome.survivor.as_ref().map(|e| e.id) != Some(p.source_id)
                || originals.insert(copy.id, copy.clone()).is_some()
            {
                return Err(Failure::InvalidState);
            }
            connect(&mut edges, p.source_id, copy.id);
            queue.push_back(copy.id);
        }
    }
    for (id, copy) in &originals {
        if let Some(e) = selected.get(id) {
            let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
            if !merge::matching_provenance(e, p.source_id, &p.fingerprint) {
                return Err(Failure::ReservedCollision);
            }
        }
    }
    for (a, b) in journal.preservation_links() {
        connect(&mut edges, a, b);
    }
    // Existing edited implicit copies may carry their own losing versions.
    // Discover those descendants before grouping and before borrowing the key.
    let mut visited = BTreeSet::new();
    let mut implicit_sources = BTreeMap::new();
    while let Some(id) = queue.pop_front() {
        if discover
            && visited.insert(id)
            && !selected.contains_key(&id)
            && let Some(e) = primary.get(&id)
        {
            queue.extend(related(&mut edges, e)?);
            implicit_sources.insert(id, e.clone());
        }
    }
    let mut frozen = journal.conflict_snapshots();
    for (id, copy) in &originals {
        if let Some(existing) = frozen.get(id)
            && existing != copy
        {
            let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
            if !copy.secure
                || !existing.secure
                || !merge::matching_provenance(existing, p.source_id, &p.fingerprint)
            {
                return Err(Failure::ReservedCollision);
            }
        }
        frozen.insert(*id, copy.clone());
    }
    let mut groups = Vec::new();
    let mut visited = BTreeSet::new();
    for start in owners.keys() {
        if !visited.insert(*start) {
            continue;
        }
        let mut component = BTreeSet::from([*start]);
        let mut indices = BTreeSet::new();
        let mut queue = VecDeque::from([*start]);
        while let Some(id) = queue.pop_front() {
            if let Some(unit) = owners.get(&id) {
                indices.extend(unit);
            }
            if let Some(neighbors) = edges.get(&id) {
                for next in neighbors {
                    if visited.insert(*next) {
                        component.insert(*next);
                        queue.push_back(*next);
                    }
                }
            }
        }
        let mut group = Group {
            outcomes: indices.into_iter().collect(),
            targets: BTreeMap::new(),
            originals: Vec::new(),
            authenticated: Vec::new(),
            held: BTreeMap::new(),
            implicit: BTreeSet::new(),
        };
        for index in &group.outcomes {
            for copy in &outcomes[*index].conflict_copies {
                group.originals.push(copy.clone());
                let target = selected
                    .get(&copy.id)
                    .cloned()
                    .map(Ok)
                    .unwrap_or_else(|| occupant(copy, primary))?;
                if !selected.contains_key(&copy.id) {
                    group.implicit.insert(copy.id);
                    if let Some(intent) = held_intent(copy, &target, primary, journal)? {
                        group.held.insert(copy.id, intent);
                    }
                }
                group.targets.insert(copy.id, target);
            }
            if let Some(e) = &outcomes[*index].survivor {
                group.targets.insert(e.id, e.clone());
            }
        }
        for id in &component {
            if let Some(e) = implicit_sources.get(id) {
                group.targets.entry(*id).or_insert_with(|| e.clone());
                group.implicit.insert(*id);
            }
        }
        if let Some(keys) = keys {
            let sources: Vec<_> = group.targets.values().cloned().collect();
            let evidence = Evidence::prepare(&sources, keys, &frozen)?;
            for (id, copy) in evidence.copies() {
                if !expected.contains_key(id) {
                    return Err(Failure::InvalidState);
                }
                let target = if let Some(e) = selected.get(id) {
                    let p = merge::provenance(copy).ok_or(Failure::InvalidState)?;
                    if !merge::matching_provenance(e, p.source_id, &p.fingerprint) {
                        return Err(Failure::ReservedCollision);
                    }
                    e.clone()
                } else {
                    let target = occupant(copy, primary)?;
                    group.implicit.insert(copy.id);
                    if let Some(intent) = held_intent(copy, &target, primary, journal)? {
                        group.held.insert(copy.id, intent);
                    }
                    target
                };
                group.targets.insert(*id, target);
                group.authenticated.push(copy.clone());
            }
        }
        if group.targets.keys().any(|id| !expected.contains_key(id)) {
            return Err(Failure::InvalidState);
        }
        groups.push(group);
    }
    Ok(groups)
}
