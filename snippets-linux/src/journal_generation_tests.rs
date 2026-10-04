//! Fictional local generations, real immutable offer ownership and restart.
use super::*;

fn stage(
    j: &mut Journal,
    nonce: u8,
    source: &Envelope,
    copy: &Envelope,
    physical: &BTreeMap<Uuid, Envelope>,
) {
    let release = j.release_targets(physical).unwrap();
    j.desire(source.clone()).unwrap();
    j.desire(copy.clone()).unwrap();
    j.stage_generation(
        [nonce; 16],
        &[(source.clone(), vec![copy.clone()])],
        &[],
        &BTreeMap::from([(source.id, source.clone()), (copy.id, copy.clone())]),
        &release,
    )
    .unwrap();
}
fn ack(j: &mut Journal, expected: &Envelope, label: &str) -> Offered {
    assert!(j.pending().unwrap() == vec![expected.clone()]);
    let offered = j
        .mark_offered(std::slice::from_ref(expected))
        .unwrap()
        .remove(0);
    j.accept_offered(&offered, version(label)).unwrap();
    *j = restart(j);
    offered
}

#[test]
fn an_exact_reviewed_deletion_can_wait_in_a_frame_while_its_original_is_current() {
    let (old, c0) = plain_conflict();
    let mut fresh = old.clone();
    fresh.fields.as_mut().unwrap().name = "Public later source metadata".into();
    let deleted = fresh
        .tombstone(Hlc::foreign(50), "11111111".into(), true)
        .unwrap();
    let mut j = Journal::new(scope());
    j.key_epoch = Some(1);
    j.stage_conflict(&old, std::slice::from_ref(&c0)).unwrap();
    j.desire(old.clone()).unwrap();
    let physical = BTreeMap::from([(old.id, old.clone()), (c0.id, c0.clone())]);
    let release = j.release_targets(&physical).unwrap();
    j.projected.insert(deleted.id, deleted.clone());
    j.desire(deleted.clone()).unwrap();
    j.approve_deletion(&deleted, Some(fresh.clone())).unwrap();
    j.stage_generation(
        [1; 16],
        &[(fresh.clone(), vec![c0.clone()])],
        &[],
        &BTreeMap::from([(deleted.id, deleted.clone()), (c0.id, c0)]),
        &release,
    )
    .unwrap();
    j.record_confirmed(deleted.clone(), version("prior-delete"))
        .unwrap();
    assert!(j.entry(deleted.id).is_none());
    j.record_confirmed(fresh.clone(), version("original-delivery"))
        .unwrap();
    j.projected.insert(fresh.id, fresh.clone());
    let saved = restart(&j);
    assert!(saved.deletion_approved(&deleted).unwrap());
    assert!(saved.primary_deletion_approved(&deleted, &fresh).unwrap());
    let mut changed = fresh.clone();
    changed.fields.as_mut().unwrap().name = "Public separately changed source".into();
    assert!(!saved.primary_deletion_approved(&deleted, &changed).unwrap());
    let mut unrepresented = saved;
    unrepresented.entries.remove(&deleted.id);
    unrepresented.generations[0].targets.insert(
        deleted.id,
        fresh
            .tombstone(Hlc::foreign(51), "11111111".into(), true)
            .unwrap(),
    );
    assert!(codec::encode(&unrepresented).err() == Some(Failure::InvalidState));
    let mut kept = j;
    kept.desire(changed.clone()).unwrap();
    assert!(kept.deletion_approved(&deleted).unwrap());
    assert!(!kept.primary_deletion_approved(&deleted, &changed).unwrap());
    kept.supersede_unoffered_deletion(&deleted, &changed)
        .unwrap();
    assert!(!kept.deletion_approved(&deleted).unwrap());
    restart(&kept);
}

#[test]
fn an_active_reviewed_delete_keeps_its_exact_permit_until_its_source_ack_or_explicit_keep() {
    let (old, c0) = plain_conflict();
    let deleted = old
        .tombstone(Hlc::foreign(50), "11111111".into(), true)
        .unwrap();
    let mut j = Journal::new(scope());
    j.key_epoch = Some(1);
    j.stage_conflict(&old, std::slice::from_ref(&c0)).unwrap();
    j.desire(old.clone()).unwrap();
    ack(&mut j, &c0, "copy-before-reviewed-delete");
    j.desire(deleted.clone()).unwrap();
    j.approve_deletion(&deleted, Some(old.clone())).unwrap();
    j.delivery.insert(old.id, deleted.clone());
    j.record_confirmed(deleted.clone(), version("cloud-marker-before-release"))
        .unwrap();
    j.projected.insert(old.id, old.clone());
    j.desire(old.clone()).unwrap();
    assert!(j.deletion_approved(&deleted).unwrap());
    assert!(j.primary_deletion_approved(&deleted, &old).unwrap());
    let mut changed = old.clone();
    changed.fields.as_mut().unwrap().name = "Public separately changed active source".into();
    assert!(!j.primary_deletion_approved(&deleted, &changed).unwrap());
    restart(&j);
    let mut kept = j.clone();
    kept.desire(changed.clone()).unwrap();
    kept.supersede_unoffered_deletion(&deleted, &changed)
        .unwrap();
    assert!(!kept.deletion_approved(&deleted).unwrap());
    restart(&kept);
    let offered = j
        .mark_offered(std::slice::from_ref(&deleted))
        .unwrap()
        .remove(0);
    j.accept_offered(&offered, version("actual-post-copy-source-ACK"))
        .unwrap();
    assert!(!j.deletion_approved(&deleted).unwrap());
    restart(&j);
}

#[test]
fn an_ordinary_copy_delivery_retains_only_its_exact_reviewed_delete_until_keep_or_ack() {
    let (_, copy) = plain_conflict();
    let deleted = copy
        .tombstone(Hlc::foreign(50), "11111111".into(), true)
        .unwrap();
    let mut j = Journal::new(scope());
    j.key_epoch = Some(1);
    j.record_confirmed(deleted.clone(), version("prior-copy-delete"))
        .unwrap();
    j.projected.insert(copy.id, copy.clone());
    j.desire(deleted.clone()).unwrap();
    j.approve_deletion(&deleted, Some(copy.clone())).unwrap();
    j.delivery.insert(copy.id, deleted.clone());
    assert!(j.dependencies.is_empty());
    j.record_confirmed(copy.clone(), version("temporary-copy-original"))
        .unwrap();
    j.desire(copy.clone()).unwrap();
    j = restart(&j);
    assert!(j.deletion_approved(&deleted).unwrap());
    assert!(j.primary_deletion_approved(&deleted, &copy).unwrap());
    let mut changed = copy.clone();
    changed.fields.as_mut().unwrap().name = "Public separately changed copy".into();
    assert!(!j.primary_deletion_approved(&deleted, &changed).unwrap());
    let mut different_marker = j.clone();
    different_marker.delivery.insert(
        copy.id,
        copy.tombstone(Hlc::foreign(51), "11111111".into(), true)
            .unwrap(),
    );
    assert!(codec::encode(&different_marker).err() == Some(Failure::InvalidState));
    let mut kept = j.clone();
    kept.desire(changed.clone()).unwrap();
    kept.supersede_unoffered_deletion(&deleted, &changed)
        .unwrap();
    assert!(!kept.deletion_approved(&deleted).unwrap());
    restart(&kept);
    let offered = j
        .mark_offered(std::slice::from_ref(&deleted))
        .unwrap()
        .remove(0);
    j.accept_offered(&offered, version("actual-copy-delete-ACK"))
        .unwrap();
    assert!(!j.deletion_approved(&deleted).unwrap());
    restart(&j);
}

#[test]
fn a_fetched_prior_copy_marker_cannot_discard_its_queued_reviewed_absence() {
    let (_, copy) = plain_conflict();
    let deleted = copy
        .tombstone(Hlc::foreign(50), "11111111".into(), true)
        .unwrap();
    let mut j = Journal::new(scope());
    j.key_epoch = Some(1);
    j.record_confirmed(deleted.clone(), version("prior-cloud-copy-marker"))
        .unwrap();
    j.projected.insert(copy.id, deleted.clone());
    j.desire(deleted.clone()).unwrap();
    j.review_absence(copy.id, Some(deleted.clone())).unwrap();
    j.approve_deletion(&deleted, Some(copy.clone())).unwrap();
    j.delivery.insert(copy.id, deleted.clone());
    j.record_confirmed(deleted.clone(), version("same-marker-before-original"))
        .unwrap();
    j = restart(&j);
    assert!(j.entry(copy.id).is_none());
    assert!(j.local_intent(copy.id, None).unwrap() == Some(&deleted));
    j.record_confirmed(copy, version("original-copy-delivered"))
        .unwrap();
    j = restart(&j);
    assert!(j.entry(deleted.id).is_none());
    assert!(j.local_intent(deleted.id, None).unwrap() == Some(&deleted));
    let offered = j
        .mark_offered(std::slice::from_ref(&deleted))
        .unwrap()
        .remove(0);
    j.accept_offered(&offered, version("actual-reviewed-copy-delete-ACK"))
        .unwrap();
    assert!(j.entry(deleted.id).is_none());
    assert!(!j.deletion_approved(&deleted).unwrap());
    restart(&j);
}

#[test]
fn an_earlier_delete_ack_keeps_a_queued_reviewed_marker_as_local_absence() {
    let (_, copy) = plain_conflict();
    let deleted = copy
        .tombstone(Hlc::foreign(50), "11111111".into(), true)
        .unwrap();
    let mut j = Journal::new(scope());
    j.key_epoch = Some(1);
    j.projected.insert(copy.id, deleted.clone());
    j.desire(deleted.clone()).unwrap();
    j.review_absence(copy.id, Some(copy.clone())).unwrap();
    j.approve_deletion(&deleted, Some(copy.clone())).unwrap();
    j.delivery.insert(copy.id, deleted.clone());
    j.stage_generation(
        [1; 16],
        &[(copy.clone(), vec![])],
        &[],
        &BTreeMap::from([(copy.id, deleted.clone())]),
        &BTreeMap::from([(copy.id, deleted.clone())]),
    )
    .unwrap();
    let offered = j
        .mark_offered(std::slice::from_ref(&deleted))
        .unwrap()
        .remove(0);
    j.accept_offered(&offered, version("earlier-copy-delete-ACK"))
        .unwrap();
    assert!(j.entry(copy.id).is_none() && j.deletion_approved(&deleted).unwrap());
    j.record_confirmed(copy.clone(), version("later-original-delivery"))
        .unwrap();
    j = restart(&j);
    assert!(j.local_intent(copy.id, None).unwrap() == Some(&deleted));
    assert!(
        merge::merge(
            j.merge_ancestor(copy.id),
            j.local_intent(copy.id, None).unwrap(),
            Some(&copy),
        )
        .unwrap()
        .survivor
            == Some(deleted)
    );
    let mut edited = copy.clone();
    edited.fields.as_mut().unwrap().name = "Public new physical copy edit".into();
    assert!(j.local_intent(copy.id, Some(&edited)).unwrap() == Some(&edited));
}

#[test]
fn queued_restore_keeps_original_copy_or_source_offer_and_uses_fresh_cas_after_release() {
    for source_in_flight in [false, true] {
        let (old, c0) = plain_conflict();
        let next = record(30, "Public restored next generation");
        let d0 = merge::plain_copy(&old).unwrap();
        let mut j = Journal::new(scope());
        j.record_confirmed(record(0, "Public confirmed ancestor"), version("V0"))
            .unwrap();
        j.stage_conflict(&old, std::slice::from_ref(&c0)).unwrap();
        j.desire(old.clone()).unwrap();
        if source_in_flight {
            ack(&mut j, &c0, "old-copy-ACK");
        }
        let initial = if source_in_flight { &old } else { &c0 };
        let original = j
            .mark_offered(std::slice::from_ref(initial))
            .unwrap()
            .remove(0);
        let before = j.clone();
        stage(
            &mut j,
            1,
            &next,
            &d0,
            &BTreeMap::from([(old.id, old.clone()), (c0.id, c0.clone())]),
        );
        assert!(before.preserves_transport_state(&j));
        j = restart(&j);
        assert!(j.pending().unwrap() == vec![initial.clone()]);
        assert!(j.mark_offered(std::slice::from_ref(initial)).unwrap() == vec![original.clone()]);
        j.accept_offered(&original, version("original-ACK"))
            .unwrap();
        if !source_in_flight {
            ack(&mut j, &old, "old-source-ACK");
        }
        let old_cas = j.confirmed(old.id).unwrap().record_version.clone();
        let physical = BTreeMap::from([
            (next.id, next.clone()),
            (c0.id, c0.clone()),
            (d0.id, d0.clone()),
        ]);
        j.reconcile_dependencies(&physical).unwrap();
        j = restart(&j);
        assert!(j.generations.is_empty());
        assert!(j.pending().unwrap() == vec![d0.clone()]);
        ack(&mut j, &d0, "new-copy-ACK");
        let source = ack(&mut j, &next, "new-source-ACK");
        assert!(source.record_version == Some(old_cas));
        j.reconcile_dependencies(&physical).unwrap();
        j = restart(&j);
        assert!(!j.has_preservation_work() && j.pending().unwrap().is_empty());
    }
}

#[test]
fn two_restorations_keep_every_generation_while_primary_already_contains_the_latest() {
    let (old, c0) = plain_conflict();
    let second = record(30, "Public second restored version");
    let second_copy = merge::plain_copy(&old).unwrap();
    let third = record(40, "Public third restored version");
    let third_copy = merge::plain_copy(&second).unwrap();
    let mut j = Journal::new(scope());
    j.stage_conflict(&old, std::slice::from_ref(&c0)).unwrap();
    j.desire(old.clone()).unwrap();
    stage(
        &mut j,
        1,
        &second,
        &second_copy,
        &BTreeMap::from([(old.id, old.clone())]),
    );
    stage(
        &mut j,
        2,
        &third,
        &third_copy,
        &BTreeMap::from([(second.id, second.clone())]),
    );
    assert_eq!(j.generations.len(), 2);
    let physical = BTreeMap::from([
        (third.id, third.clone()),
        (c0.id, c0.clone()),
        (second_copy.id, second_copy.clone()),
        (third_copy.id, third_copy.clone()),
    ]);
    for (n, (source, copy, remaining)) in [
        (&old, &c0, 1),
        (&second, &second_copy, 0),
        (&third, &third_copy, 0),
    ]
    .into_iter()
    .enumerate()
    {
        ack(&mut j, copy, &format!("copy-{n}"));
        ack(&mut j, source, &format!("source-{n}"));
        j.reconcile_dependencies(&physical).unwrap();
        j = restart(&j);
        assert_eq!(j.generations.len(), remaining);
    }
    assert!(!j.has_preservation_work() && j.pending().unwrap().is_empty());
}

#[test]
fn generation_capacity_and_invalid_protocol_facts_fail_without_eviction_or_mutation() {
    let (old, c0) = plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&old, &[c0]).unwrap();
    let physical = BTreeMap::from([(old.id, old.clone())]);
    for n in 1..=MAX_PRESERVATION_GENERATIONS as u8 {
        let source = record(30 + u64::from(n), "Public queued version");
        let copy = merge::plain_copy(&source).unwrap();
        stage(&mut j, n, &source, &copy, &physical);
    }
    let before = restart(&j);
    let next = record(90, "Public ninth generation");
    let copy = merge::plain_copy(&next).unwrap();
    let release = j.release_targets(&physical).unwrap();
    assert!(matches!(
        j.stage_generation(
            [99; 16],
            &[(next.clone(), vec![copy.clone()])],
            &[],
            &BTreeMap::from([(next.id, next), (copy.id, copy)]),
            &release
        ),
        Err(Failure::GenerationExhausted)
    ));
    assert!(j == before);
    let mut invalid = j.clone();
    invalid.generations[0]
        .dependencies
        .values_mut()
        .next()
        .unwrap()
        .requirements
        .values_mut()
        .next()
        .unwrap()
        .accepted_version = Some(version("forged-old-ACK"));
    assert!(codec::encode(&invalid).is_err());
    invalid = j.clone();
    invalid.generations[1].nonce = invalid.generations[0].nonce;
    assert!(codec::encode(&invalid).is_err());
    assert!(codec::encode_legacy_five(&j).is_err());
}

#[test]
fn legacy_five_migrates_and_scope_review_preserves_generation_data_without_old_server_facts() {
    let (old, c0) = plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&old, std::slice::from_ref(&c0)).unwrap();
    j.mark_offered(std::slice::from_ref(&c0)).unwrap();
    let old_bytes = codec::encode_legacy_five(&j).unwrap();
    let mut recovered = codec::decode(&old_bytes, scope()).unwrap();
    assert!(recovered == j && recovered.generations.is_empty() && recovered.delivery.is_empty());
    assert_eq!(&codec::encode(&recovered).unwrap()[..4], b"JNL6");
    let next = record(30, "Public queued restoration");
    let copy = merge::plain_copy(&old).unwrap();
    let physical = BTreeMap::from([
        (next.id, next.clone()),
        (copy.id, copy.clone()),
        (c0.id, c0.clone()),
    ]);
    stage(
        &mut recovered,
        1,
        &next,
        &copy,
        &BTreeMap::from([(old.id, old)]),
    );
    let generations = recovered.generations.clone();
    let delivery = recovered.delivery.clone();
    recovered
        .resume_scope(
            &physical,
            scope(),
            crate::inbound::Feed::new(Uuid::from_u128(9), 2).unwrap(),
        )
        .unwrap();
    assert!(recovered.generations == generations && recovered.delivery == delivery);
    assert!(recovered.confirmed.is_empty() && recovered.outbound.is_none());
    assert!(recovered.dependencies.values().all(|e| {
        e.source_offered.is_none()
            && e.source_accepted_version.is_none()
            && e.requirements
                .values()
                .all(|r| r.offered.is_none() && r.accepted_version.is_none())
    }));
    assert!(recovered.pending().unwrap() == vec![c0]);
    let offered = recovered
        .mark_offered(&recovered.pending().unwrap())
        .unwrap()
        .remove(0);
    assert!(offered.record_version.is_none());
}

#[test]
fn queued_codec_rejects_nested_queues_and_transport_fact_smuggling_and_torn_frames() {
    let (old, c0) = plain_conflict();
    let mut journal = Journal::new(scope());
    journal.stage_conflict(&old, &[c0]).unwrap();
    let next = record(30, "Public codec generation");
    let copy = merge::plain_copy(&old).unwrap();
    stage(
        &mut journal,
        1,
        &next,
        &copy,
        &BTreeMap::from([(old.id, old)]),
    );
    let encoded = codec::encode(&journal).unwrap();
    let offset = encoded
        .windows(4)
        .enumerate()
        .skip(1)
        .find_map(|(n, tag)| (tag == b"JNL6").then_some(n))
        .unwrap();
    let length = u32::from_be_bytes(encoded[offset - 4..offset].try_into().unwrap()) as usize;
    assert_eq!(offset + length, encoded.len());
    let generation = &journal.generations[0];
    for nested in [false, true] {
        let mut invalid = Journal::new(scope());
        invalid.delivery = generation.targets.clone();
        invalid.dependencies = generation.dependencies.clone();
        if nested {
            invalid.generations = journal.generations.clone();
        } else {
            invalid
                .record_confirmed(next.clone(), version("smuggled-ACK"))
                .unwrap();
        }
        let inner = codec::encode(&invalid).unwrap();
        let mut forged = encoded[..offset - 4].to_vec();
        forged.extend_from_slice(&(inner.len() as u32).to_be_bytes());
        forged.extend_from_slice(&inner);
        assert!(codec::decode(&forged, scope()).is_err());
    }
    for boundary in [0, 3, 4, offset - 4, offset, offset + length - 1] {
        assert!(codec::decode(&encoded[..boundary], scope()).is_err());
    }
    let mut trailing = encoded.to_vec();
    trailing.push(0);
    assert!(codec::decode(&trailing, scope()).is_err());
    assert!(codec::decode(&encoded, scope()).unwrap() == journal);
}

#[test]
fn independent_graph_does_not_delay_queued_generation_or_allow_an_overlapping_epoch_to_overtake() {
    let (old, copy) = plain_conflict();
    let mut unrelated = record(10, "Public unrelated source");
    unrelated.id = Uuid::from_u128(700);
    let unrelated_copy = merge::plain_copy(&unrelated).unwrap();
    let next = record(30, "Public next source");
    let next_copy = merge::plain_copy(&old).unwrap();
    let mut j = Journal::new(scope());
    j.stage_conflict(&old, std::slice::from_ref(&copy)).unwrap();
    j.stage_conflict(&unrelated, std::slice::from_ref(&unrelated_copy))
        .unwrap();
    let physical = BTreeMap::from([(old.id, old.clone()), (unrelated.id, unrelated.clone())]);
    stage(&mut j, 1, &next, &next_copy, &physical);
    for (n, e) in [&copy, &old].into_iter().enumerate() {
        assert!(j.pending().unwrap().contains(e));
        let offer = j.mark_offered(std::slice::from_ref(e)).unwrap().remove(0);
        j.accept_offered(&offer, version(&format!("independent-{n}")))
            .unwrap();
    }
    let physical = BTreeMap::from([
        (next.id, next),
        (copy.id, copy),
        (next_copy.id, next_copy.clone()),
        (unrelated.id, unrelated),
        (unrelated_copy.id, unrelated_copy.clone()),
    ]);
    j.reconcile_dependencies(&physical).unwrap();
    j = restart(&j);
    assert!(j.generations.is_empty());
    let pending = j.pending().unwrap();
    assert!(pending.contains(&next_copy) && pending.contains(&unrelated_copy));
}

#[test]
fn restored_ordinary_targets_deliver_before_later_queued_targets_without_a_dependency_role() {
    let first = record(10, "Public first historical intent");
    let second = record(20, "Public second historical intent");
    let latest = record(30, "Public latest selected intent");
    let mut j = Journal::new(scope());
    j.desire(latest.clone()).unwrap();
    for (n, target) in [&first, &second, &latest].into_iter().enumerate() {
        j.stage_restoration_generation(
            [n as u8 + 1; 16],
            &RestorationGeneration {
                targets: BTreeMap::from([(target.id, target.clone())]),
                sources: Vec::new(),
            },
            &BTreeMap::new(),
        )
        .unwrap();
    }
    for (n, target) in [&first, &second, &latest].into_iter().enumerate() {
        let offer = ack(&mut j, target, &format!("historical-target-{n}"));
        assert_eq!(offer.record_version.is_some(), n != 0);
        j.reconcile_dependencies(&BTreeMap::from([(latest.id, latest.clone())]))
            .unwrap();
        j = restart(&j);
    }
    assert!(!j.has_preservation_work() && j.pending().unwrap().is_empty());
}

#[test]
fn archived_generations_keep_data_order_but_never_supply_old_cas_offers_or_acceptance() {
    let (first, copy) = plain_conflict();
    let next = record(30, "Public next archived data");
    let next_copy = merge::plain_copy(&first).unwrap();
    let mut archived = Journal::new(scope());
    archived
        .record_confirmed(first.clone(), version("archived-source-CAS"))
        .unwrap();
    archived
        .stage_conflict(&first, std::slice::from_ref(&copy))
        .unwrap();
    archived.desire(first.clone()).unwrap();
    archived.mark_offered(std::slice::from_ref(&copy)).unwrap();
    stage(
        &mut archived,
        1,
        &next,
        &next_copy,
        &BTreeMap::from([(first.id, first.clone())]),
    );
    let archived_before = restart(&archived);
    let layers = archived.restoration_generations().unwrap();
    assert_eq!(layers.len(), 2);
    assert!(layers[0].sources[0].1 == vec![copy.clone()]);
    assert!(layers[1].sources[0].1 == vec![next_copy]);
    let mut current = Journal::new(scope());
    current
        .record_confirmed(
            record(40, "Public real current ancestor"),
            version("current-CAS"),
        )
        .unwrap();
    current.desire(next).unwrap();
    let before = current.clone();
    for (n, layer) in layers.iter().enumerate() {
        current
            .stage_restoration_generation([100 + n as u8; 16], layer, &BTreeMap::new())
            .unwrap();
    }
    assert!(before.preserves_transport_state(&current));
    assert!(current.confirmed(first.id).unwrap().record_version == version("current-CAS"));
    assert!(current.dependencies.values().all(|edge| {
        edge.source_offered.is_none()
            && edge.source_accepted_version.is_none()
            && edge
                .requirements
                .values()
                .all(|r| r.offered.is_none() && r.accepted_version.is_none())
    }));
    assert!(current.pending().unwrap() == vec![copy]);
    assert!(archived == archived_before);
}
