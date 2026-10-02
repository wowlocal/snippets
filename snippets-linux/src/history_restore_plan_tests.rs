//! Fictional envelopes and authenticated-journal intent, without user storage.
use super::*;
use crate::{
    cloud::Binding,
    journal::Scope,
    snapshot_review::tests::{envelope, version},
};

fn journal(seed: u8) -> Journal {
    Journal::new(Scope {
        membership: Binding::from_checkpoint([seed; 32]),
        dataset: Binding::from_checkpoint([seed + 1; 32]),
    })
}
fn stamp() -> Hlc {
    Hlc::parse("000000000100-0000-11111111").unwrap()
}
fn map(values: &[Envelope]) -> BTreeMap<Uuid, Envelope> {
    values.iter().map(|e| (e.id, e.clone())).collect()
}
fn archive(values: &[Envelope]) -> Journal {
    let mut archived = journal(20);
    archived.projected = map(values);
    archived.key_epoch = Some(9);
    for e in values {
        archived
            .record_confirmed(e.clone(), version("public-archived-cas"))
            .unwrap();
    }
    archived
}

#[test]
fn saved_fields_restore_as_new_edits_with_complete_current_metadata_preserved() {
    let saved = envelope(1, "Public historical body", 4);
    let mut live = envelope(1, "Public current body", 8);
    let fields = live.fields.as_mut().unwrap();
    fields.name = "Public current name".into();
    fields.keyword = "public-current".into();
    fields.tags = vec!["public-current-tag".into()];
    fields.is_pinned = true;
    let extra = envelope(2, "Public new local record", 9);
    let physical = map(&[live.clone(), extra.clone()]);
    let current = journal(1);
    let plan = prepare(
        &archive(std::slice::from_ref(&saved)),
        &current,
        &physical,
        stamp(),
        15.0,
    )
    .unwrap();
    assert_eq!(plan.summary.restored_records, 1);
    assert_eq!(plan.summary.preserved_versions, 1);
    let target = plan.outcomes[0].survivor.as_ref().unwrap();
    assert!(target.hlc > live.hlc && target.origin == "11111111");
    let fields = target.fields.as_ref().unwrap();
    assert!(fields.content == saved.fields.as_ref().unwrap().content);
    assert_eq!(fields.updated_at, 15.0);
    let copy = &plan.outcomes[0].conflict_copies[0];
    assert!(merge::matching_provenance(
        copy,
        live.id,
        &merge::provenance(copy).unwrap().fingerprint
    ));
    let fields = copy.fields.as_ref().unwrap();
    assert!(fields.content == live.fields.as_ref().unwrap().content);
    assert!(
        fields.name.contains("Public current name")
            && fields.tags.contains(&"public-current-tag".into())
    );
    assert!(!fields.is_enabled && !fields.is_pinned && fields.keyword.is_empty());
    assert!(!plan.expected.contains_key(&extra.id)); // Outside the restore read set.
}

#[test]
fn metadata_only_changes_are_preserved_even_when_body_is_identical() {
    let saved = envelope(1, "Public identical body", 4);
    let mut live = saved.clone();
    live.hlc = Hlc::foreign(8);
    live.fields.as_mut().unwrap().name = "Public later title".into();
    let plan = prepare(
        &archive(std::slice::from_ref(&saved)),
        &journal(1),
        &map(&[live]),
        stamp(),
        15.0,
    )
    .unwrap();
    assert_eq!(plan.summary.preserved_versions, 1);
    assert_eq!(plan.outcomes[0].conflict_copies.len(), 1);
}

#[test]
fn existing_confirmations_offers_feed_and_epoch_are_current_facts_only() {
    let saved = envelope(1, "Public saved body", 4);
    let live = envelope(1, "Public current body", 8);
    let mut current = journal(1);
    current.key_epoch = Some(3);
    current.projected = map(std::slice::from_ref(&live));
    current
        .record_confirmed(
            envelope(1, "Public confirmed ancestor", 6),
            version("public-current-cas"),
        )
        .unwrap();
    current.desire(live.clone()).unwrap();
    let offered = current.mark_offered(std::slice::from_ref(&live)).unwrap();
    current
        .inbox
        .select_feed(crate::inbound::Feed::new(Uuid::from_u128(44), 3).unwrap())
        .unwrap();
    let before = current.clone();
    let plan = prepare(
        &archive(std::slice::from_ref(&saved)),
        &current,
        &map(&[live]),
        stamp(),
        15.0,
    )
    .unwrap();
    assert!(plan.next.scope() == current.scope() && plan.next.key_epoch == Some(3));
    assert!(plan.next.inbox == before.inbox && plan.next.outbound == before.outbound);
    assert!(plan.next.confirmed(saved.id) == before.confirmed(saved.id));
    assert!(plan.next.entry(saved.id).unwrap().offered.as_ref() == Some(&offered[0]));
    assert!(current == before);
}

#[test]
fn saved_tombstones_do_not_delete_current_records_and_missing_live_data_can_be_restored() {
    let saved = envelope(1, "Public restorable record", 4);
    let deleted = envelope(2, "Public historical deleted record", 4)
        .tombstone(Hlc::foreign(5), "22222222".into(), true)
        .unwrap();
    let live = envelope(2, "Public current retained record", 8);
    let plan = prepare(
        &archive(&[saved.clone(), deleted]),
        &journal(1),
        &map(&[live]),
        stamp(),
        15.0,
    )
    .unwrap();
    assert_eq!(plan.summary.added_records, 1);
    assert_eq!(plan.outcomes.len(), 1);
    assert_eq!(plan.outcomes[0].survivor.as_ref().unwrap().id, saved.id);
    assert!(
        plan.outcomes
            .iter()
            .all(|o| o.survivor.as_ref().is_none_or(|e| !e.deleted))
    );
}

#[test]
fn reviewed_journal_only_and_visible_current_versions_are_both_kept() {
    let visible = envelope(1, "Public visible current version", 6);
    let held = envelope(1, "Public held current intent", 8);
    let saved = envelope(1, "Public selected old state", 4);
    let mut current = journal(1);
    current.projected = map(std::slice::from_ref(&visible));
    current.desire(held.clone()).unwrap();
    current
        .resume_scope(
            &map(std::slice::from_ref(&visible)),
            current.scope().clone(),
            crate::inbound::Feed::new(Uuid::from_u128(33), 1).unwrap(),
        )
        .unwrap();
    let plan = prepare(
        &archive(&[saved]),
        &current,
        &map(std::slice::from_ref(&visible)),
        stamp(),
        15.0,
    )
    .unwrap();
    assert_eq!(plan.summary.preserved_versions, 2);
    let copies = &plan.outcomes[0].conflict_copies;
    assert!(
        copies
            .iter()
            .any(|e| e.fields.as_ref().unwrap().content == held.fields.as_ref().unwrap().content)
    );
    assert!(copies.iter().any(|e| e.fields.as_ref().unwrap().content == visible.fields.as_ref().unwrap().content));
}

#[test]
fn archived_latest_desire_wins_over_old_projection_without_replaying_its_offer() {
    let projected = envelope(1, "Public old projection", 4);
    let held = envelope(1, "Public newer saved local intent", 6);
    let mut archived = archive(std::slice::from_ref(&projected));
    archived.desire(held.clone()).unwrap();
    archived.mark_offered(std::slice::from_ref(&held)).unwrap();
    let plan = prepare(&archived, &journal(1), &BTreeMap::new(), stamp(), 15.0).unwrap();
    assert!(
        plan.outcomes[0]
            .survivor
            .as_ref()
            .unwrap()
            .fields
            .as_ref()
            .unwrap()
            .content
            == held.fields.as_ref().unwrap().content
    );
    assert!(plan.next.entry(held.id).unwrap().offered.is_none());
    assert!(plan.next.confirmed(held.id).is_none());
}

#[test]
fn archived_nested_group_retains_original_c0_separately_from_selected_c1_and_old_receipts() {
    let root = merge::merge(
        None,
        Some(&envelope(1, "Public archived loser", 1)),
        Some(&envelope(1, "Public archived root", 2)),
    )
    .unwrap();
    let source = root.survivor.unwrap();
    let c0 = root.conflict_copies[0].clone();
    let mut edit = c0.clone();
    edit.hlc = Hlc::foreign(20);
    edit.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public archived copy edit".to_vec());
    let child = merge::merge(None, Some(&c0), Some(&edit)).unwrap();
    let c1 = child.survivor.unwrap();
    let d0 = child.conflict_copies[0].clone();
    let mut archived = archive(&[source.clone(), c1.clone(), d0.clone()]);
    archived
        .stage_conflict(&source, std::slice::from_ref(&c0))
        .unwrap();
    archived
        .stage_conflict(&c1, std::slice::from_ref(&d0))
        .unwrap();
    archived.desire(c1.clone()).unwrap();
    let offer = archived
        .mark_offered(std::slice::from_ref(&d0))
        .unwrap()
        .remove(0);
    archived
        .accept_offered(&offer, version("public-old-nested-ack"))
        .unwrap();
    archived.mark_offered(std::slice::from_ref(&c0)).unwrap();
    let mut live = c1.clone();
    live.hlc = Hlc::foreign(30);
    live.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public current copy edit".to_vec());
    let physical = map(&[source.clone(), live, d0]);
    let mut current = journal(1);
    current.projected = physical.clone();
    let before = current.clone();
    let plan = prepare(&archived, &current, &physical, stamp(), 15.0).unwrap();
    assert_eq!(plan.summary.restored_records, 3); // Unchanged supporting members included.
    let parent = plan
        .outcomes
        .iter()
        .find(|o| o.survivor.as_ref().unwrap().id == source.id)
        .unwrap();
    assert!(parent.conflict_copies.iter().any(|e| e == &c0));
    let selected = &plan.next.entry(c1.id).unwrap().desired;
    assert!(selected.fields.as_ref().unwrap().content == c1.fields.as_ref().unwrap().content);
    assert!(selected.hlc == stamp());
    assert!(plan.next.entry(c1.id).unwrap().offered.is_none());
    assert!(plan.next.agreed_envelopes().is_empty());
    assert!(before.preserves_transport_state(&plan.next));
}

#[test]
fn stale_or_exhausted_clocks_and_empty_restoration_are_refused() {
    let saved = envelope(1, "Public old record", 4);
    assert!(matches!(
        prepare(
            &archive(std::slice::from_ref(&saved)),
            &journal(1),
            &BTreeMap::new(),
            Hlc::foreign(8),
            15.0
        ),
        Err(Failure::Changed)
    ));
    let mut future = saved.clone();
    future.hlc = Hlc::foreign(9999);
    assert!(matches!(
        prepare(
            &archive(&[future]),
            &journal(1),
            &BTreeMap::new(),
            stamp(),
            15.0
        ),
        Err(Failure::Changed)
    ));
    assert!(matches!(
        prepare(
            &archive(std::slice::from_ref(&saved)),
            &journal(1),
            &map(&[saved]),
            stamp(),
            15.0
        ),
        Err(Failure::Unavailable)
    ));
}

#[test]
fn restored_fields_with_only_a_later_local_timestamp_are_already_current() {
    let saved = envelope(1, "Public identical restored body", 4);
    let mut physical = saved.clone();
    physical.hlc = stamp();
    physical.origin = "11111111".into();
    physical.fields.as_mut().unwrap().updated_at = 15.0;
    let mut current = journal(1);
    current.projected = map(std::slice::from_ref(&physical));
    current.desire(physical.clone()).unwrap();
    assert!(matches!(
        prepare(
            &archive(&[saved]),
            &current,
            &map(&[physical]),
            Hlc::parse("000000000200-0000-11111111").unwrap(),
            16.0
        ),
        Err(Failure::Unavailable)
    ));
}

fn plain_group() -> (Envelope, Envelope, Envelope) {
    let outcome = merge::merge(
        None,
        Some(&envelope(1, "Public archived loser", 1)),
        Some(&envelope(1, "Public archived root", 2)),
    )
    .unwrap();
    let source = outcome.survivor.unwrap();
    let original = outcome.conflict_copies[0].clone();
    let mut edit = original.clone();
    edit.hlc = Hlc::foreign(20);
    edit.fields.as_mut().unwrap().content = zeroize::Zeroizing::new(b"Public archived C1".to_vec());
    (source, original, edit)
}

#[test]
fn archived_deleted_copy_restores_live_original_and_preserves_a_new_current_edit() {
    let (source, original, _) = plain_group();
    let deleted = original
        .tombstone(Hlc::foreign(30), "22222222".into(), true)
        .unwrap();
    let mut archived = archive(&[source.clone(), deleted]);
    archived
        .stage_conflict(&source, std::slice::from_ref(&original))
        .unwrap();
    let mut live = original.clone();
    live.hlc = Hlc::foreign(40);
    live.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public new current copy".to_vec());
    let plan = prepare(
        &archived,
        &journal(1),
        &map(&[source.clone(), live]),
        stamp(),
        15.0,
    )
    .unwrap();
    assert_eq!(plan.summary.restored_records, 2);
    assert_eq!(plan.summary.preserved_versions, 1);
    let restored = &plan.next.entry(original.id).unwrap().desired;
    assert!(
        !restored.deleted
            && restored.fields.as_ref().unwrap().content
                == original.fields.as_ref().unwrap().content
    );
    assert!(restored.hlc == stamp());
    assert!(
        plan.outcomes
            .iter()
            .flat_map(|o| &o.conflict_copies)
            .any(|e| e.fields.as_ref().unwrap().content.as_slice() == b"Public new current copy")
    );
    assert!(plan.next.deletion_approvals.is_empty());
}

#[test]
fn deleted_source_uses_retained_live_source_without_replaying_the_tombstone() {
    let (source, original, _) = plain_group();
    let deleted = source
        .tombstone(Hlc::foreign(30), "22222222".into(), true)
        .unwrap();
    let mut archived = archive(&[deleted, original.clone()]);
    archived
        .stage_conflict(&source, std::slice::from_ref(&original))
        .unwrap();
    let plan = prepare(&archived, &journal(1), &BTreeMap::new(), stamp(), 15.0).unwrap();
    assert_eq!(plan.summary.restored_records, 2);
    let restored = &plan.next.entry(source.id).unwrap().desired;
    assert!(restored.fields.as_ref().unwrap().content == source.fields.as_ref().unwrap().content);
    assert!(restored.hlc == stamp() && !restored.deleted);
    assert!(plan.next.deletion_approvals.is_empty());
}

#[test]
fn tombstone_parent_with_no_live_source_restores_only_its_retained_live_copy() {
    let (source, original, _) = plain_group();
    let deleted = source
        .tombstone(Hlc::foreign(30), "22222222".into(), true)
        .unwrap();
    let mut archived = archive(std::slice::from_ref(&deleted));
    archived
        .stage_conflict(&deleted, std::slice::from_ref(&original))
        .unwrap();
    let current = envelope(1, "Public current parent must stay", 40);
    let plan = prepare(
        &archived,
        &journal(1),
        &map(std::slice::from_ref(&current)),
        stamp(),
        15.0,
    )
    .unwrap();
    assert_eq!(plan.summary.restored_records, 1);
    assert!(plan.next.entry(source.id).is_none());
    assert_eq!(plan.outcomes[0].survivor.as_ref().unwrap().id, original.id);
    assert!(plan.history.is_empty());
}

#[test]
fn deleted_nested_copy_prefers_its_retained_c1_source_beside_the_parent_c0() {
    let (source, original, edit) = plain_group();
    let nested = merge::merge(None, Some(&original), Some(&edit)).unwrap();
    let selected = nested.survivor.unwrap();
    let leaf = nested.conflict_copies[0].clone();
    let deleted = selected
        .tombstone(Hlc::foreign(30), "22222222".into(), true)
        .unwrap();
    let mut archived = archive(&[source.clone(), deleted, leaf.clone()]);
    archived
        .stage_conflict(&source, std::slice::from_ref(&original))
        .unwrap();
    archived
        .stage_conflict(&selected, std::slice::from_ref(&leaf))
        .unwrap();
    let plan = prepare(&archived, &journal(1), &BTreeMap::new(), stamp(), 15.0).unwrap();
    assert_eq!(plan.summary.restored_records, 3);
    assert!(
        plan.next
            .entry(selected.id)
            .unwrap()
            .desired
            .fields
            .as_ref()
            .unwrap()
            .content
            == selected.fields.as_ref().unwrap().content
    );
    let parent = plan
        .outcomes
        .iter()
        .find(|o| o.survivor.as_ref().unwrap().id == source.id)
        .unwrap();
    assert!(parent.conflict_copies.iter().any(|e| e == &original));
}
