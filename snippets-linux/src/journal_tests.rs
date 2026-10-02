//! Isolated checkpoint/crash fixtures. No user roots, real credentials or keys.
use super::*;
use crate::{clock::Hlc, model::Snippet, wire::Fields};
use std::os::unix::fs::symlink;
#[path = "journal_generation_tests.rs"]
mod generation_tests;

fn scope() -> Scope {
    Scope {
        membership: Binding::from_checkpoint([0x33; 32]),
        dataset: Binding::from_checkpoint([0x44; 32]),
    }
}
fn version(label: &str) -> RecordVersion {
    RecordVersion::from_checkpoint(format!("public-fictional-server-generation-{label}")).unwrap()
}
fn record(wall: u64, body: &str) -> Envelope {
    let mut snippet = Snippet::new("Public journal fixture", body);
    snippet.id = Uuid::parse_str("00000000-0000-4000-8000-000000000021").unwrap();
    snippet.created_at = 0.0;
    snippet.updated_at = wall as f64;
    Envelope::plain(&snippet, Hlc::foreign(wall), "aaaaaaa1".into()).unwrap()
}
fn restart(journal: &Journal) -> Journal {
    let bytes = codec::encode(journal).unwrap();
    let recovered = codec::decode(&bytes, scope()).unwrap();
    assert!(&recovered == journal);
    recovered
}
fn key() -> RootKey {
    RootKey::from_bytes(&[0x55; 32]).unwrap()
}
fn plain_conflict() -> (Envelope, Envelope) {
    let merged = merge::merge(
        None,
        Some(&record(1, "Losing public body")),
        Some(&record(2, "Winning public body")),
    )
    .unwrap();
    (merged.survivor.unwrap(), merged.conflict_copies[0].clone())
}
fn secure_conflict() -> (Envelope, Envelope) {
    let root = key();
    let salt = [0x66; 32];
    let mut loser = record(1, "");
    loser.secure = true;
    let body = crypto::seal_record(
        b"Public losing secure body",
        &root,
        &salt,
        "fictional-vault",
        loser.id,
        false,
    )
    .unwrap();
    loser.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(body.text().as_bytes().to_vec());
    loser.extensions = BTreeMap::from([
        ("vaultKID".into(), Value::text("fictional-vault")),
        (
            "vaultContentHash".into(),
            Value::text(crypto::content_hash(
                b"Public losing secure body",
                &root,
                &salt,
            )),
        ),
    ]);
    let source = merge::merge(
        None,
        Some(&loser),
        Some(&record(2, "Winning ordinary body")),
    )
    .unwrap()
    .survivor
    .unwrap();
    let v = &merge::secure_variants(&source).unwrap()[0];
    // This explicit owner boundary authenticates under the old UUID and reseals
    // under the copy UUID. The journal itself never receives the vault root.
    let plaintext =
        crypto::open_record(&body, &root, &salt, "fictional-vault", v.source_id, false).unwrap();
    let resealed = crypto::seal_record(
        &plaintext,
        &root,
        &salt,
        "fictional-vault",
        v.copy_id,
        false,
    )
    .unwrap();
    let mut fields = v.fields.clone();
    fields.content = zeroize::Zeroizing::new(resealed.text().as_bytes().to_vec());
    fields.keyword.clear();
    fields.is_enabled = false;
    fields.is_pinned = false;
    let mut extensions = v.source_extensions.clone();
    extensions.insert(
        merge::COPY_PROVENANCE.into(),
        merge::provenance_value(v.source_id, &v.fingerprint),
    );
    let copy = Envelope {
        id: v.copy_id,
        hlc: v.source_hlc.clone(),
        origin: v.source_origin.clone(),
        secure: true,
        deleted: false,
        fields: Some(fields),
        extensions,
    };
    assert!(
        *crypto::open_record(&resealed, &root, &salt, "fictional-vault", v.copy_id, false).unwrap()
            == b"Public losing secure body"
    );
    (source, copy)
}

#[test]
fn lost_ack_retries_original_offer_and_cas_while_new_intent_survives_restart() {
    let mut j = Journal::new(scope());
    let ancestor = record(1, "Ancestor");
    j.record_confirmed(ancestor, version("V1")).unwrap();
    let first = record(2, "First local edit");
    j.desire(first.clone()).unwrap();
    let offered = j.mark_offered(std::slice::from_ref(&first)).unwrap()[0].clone();
    assert!(offered.record_version == Some(version("V1")));
    let latest = record(4, "Newer local edit");
    j.desire(latest.clone()).unwrap();
    j.record_confirmed(record(3, "Independent remote edit"), version("V2"))
        .unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![first.clone()]);
    assert!(j.mark_offered(&[first]).unwrap() == vec![offered.clone()]);
    assert!(j.entry(latest.id).unwrap().desired == latest);
    // Original V1 must conflict against the independent V2. Only that
    // authoritative rejection lets a new offer use V2 and the latest intent.
    j.reject(latest.id);
    j = restart(&j);
    let new_offer = j.mark_offered(&j.pending().unwrap()).unwrap().remove(0);
    assert!(new_offer.envelope == latest);
    assert!(new_offer.record_version == Some(version("V2")));
    assert_eq!(new_offer.generation, 2);
}

#[test]
fn old_offer_acknowledgement_keeps_a_newer_local_generation_pending() {
    let mut j = Journal::new(scope());
    j.record_confirmed(record(1, "Ancestor"), version("V1"))
        .unwrap();
    let first = record(2, "First edit");
    j.desire(first.clone()).unwrap();
    let offer = j
        .mark_offered(std::slice::from_ref(&first))
        .unwrap()
        .remove(0);
    let latest = record(3, "Edited while the first write was in flight");
    j.desire(latest.clone()).unwrap();
    j = restart(&j);
    j.accept_offered(&offer, version("V2")).unwrap();
    j = restart(&j);
    let next = j.mark_offered(&j.pending().unwrap()).unwrap().remove(0);
    assert!(next.envelope == latest);
    assert!(next.record_version == Some(version("V2")));
    assert_eq!(next.generation, 2);
}

#[test]
fn create_cas_is_explicit_absence_and_rejection_releases_only_the_latest_desire() {
    let mut j = Journal::new(scope());
    let first = record(1, "Create");
    j.desire(first.clone()).unwrap();
    let offer = j.mark_offered(std::slice::from_ref(&first)).unwrap()[0].clone();
    assert!(offer.record_version.is_none());
    let next = record(2, "Changed during create");
    j.desire(next.clone()).unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![first]);
    j.reject(next.id);
    assert!(j.pending().unwrap() == vec![next]);
    let before = j.clone();
    assert!(j.mark_offered(&[record(99, "Never captured")]).is_err());
    assert!(j == before);
}

#[test]
fn exact_copy_acceptance_precedes_source_then_held_copy_deletion() {
    let (source, copy) = plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, std::slice::from_ref(&copy))
        .unwrap();
    j.desire(source.clone()).unwrap();
    j.desire(copy.clone()).unwrap();
    let deletion = copy
        .tombstone(Hlc::foreign(9), "bbbbbbb2".into(), true)
        .unwrap();
    j.desire(deletion.clone()).unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![copy.clone()]);
    let copy_offer = j.mark_offered(&[copy]).unwrap()[0].clone();
    j.accept_offered(&copy_offer, version("copy-C0")).unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![source.clone()]);
    let source_offer = j.mark_offered(std::slice::from_ref(&source)).unwrap()[0].clone();
    j.accept_offered(&source_offer, version("source-post-copy"))
        .unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap().is_empty());
    j.reconcile_dependencies(&BTreeMap::from([(source.id, source)]))
        .unwrap();
    assert!(j.dependencies.is_empty());
    assert!(j.pending().unwrap() == vec![deletion]);
}

#[test]
fn later_same_provenance_c1_cannot_manufacture_frozen_c0_receipt() {
    let (source, copy) = plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, std::slice::from_ref(&copy))
        .unwrap();
    let copy_offer = j.mark_offered(std::slice::from_ref(&copy)).unwrap()[0].clone();
    let mut edited_copy = copy.clone();
    edited_copy.hlc = Hlc::foreign(20);
    edited_copy.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Later public copy edit".to_vec());
    j.record_confirmed(edited_copy, version("C1")).unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![copy]);
    assert!(
        j.dependencies[&source.id]
            .requirements
            .values()
            .next()
            .unwrap()
            .accepted_version
            .is_none()
    );
    j.accept_offered(&copy_offer, version("C0-proof")).unwrap();
    assert!(j.pending().unwrap() == vec![source]);
}

#[test]
fn old_carrier_free_base_never_proves_the_post_copy_source_ack() {
    let (source, copy) = plain_conflict();
    let mut j = Journal::new(scope());
    j.record_confirmed(source.clone(), version("old-source"))
        .unwrap();
    j.stage_conflict(&source, std::slice::from_ref(&copy))
        .unwrap();
    let copy_offer = j.mark_offered(&[copy]).unwrap()[0].clone();
    j.accept_offered(&copy_offer, version("copy")).unwrap();
    let source_offer = j.mark_offered(std::slice::from_ref(&source)).unwrap()[0].clone();
    assert!(source_offer.record_version == Some(version("old-source")));
    j = restart(&j);
    j.reconcile_dependencies(&BTreeMap::from([(source.id, source.clone())]))
        .unwrap();
    assert!(!j.dependencies.is_empty());
    j.record_confirmed(source.clone(), version("old-source"))
        .unwrap();
    j.reconcile_dependencies(&BTreeMap::from([(source.id, source.clone())]))
        .unwrap();
    assert!(!j.dependencies.is_empty());
    j.accept_offered(&source_offer, version("post-copy-source"))
        .unwrap();
    j.reconcile_dependencies(&BTreeMap::from([(source.id, source)]))
        .unwrap();
    assert!(j.dependencies.is_empty());
}

#[test]
fn secure_carrier_cleanup_requires_exact_copy_receipt_and_primary_cas() {
    let (source, copy) = secure_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, &[]).unwrap();
    j.desire(source.clone()).unwrap();
    assert!(j.pending().unwrap().is_empty());
    j.freeze_authenticated_copy(&copy).unwrap();
    j = restart(&j);
    let current = BTreeMap::from([(source.id, source.clone()), (copy.id, copy.clone())]);
    assert!(j.carrier_resolutions(&current).unwrap().is_empty());
    let offer = j.mark_offered(std::slice::from_ref(&copy)).unwrap()[0].clone();
    j.accept_offered(&offer, version("secure-C0")).unwrap();
    j = restart(&j);
    let resolution = j.carrier_resolutions(&current).unwrap().remove(0);
    assert!(!merge::has_unresolved(Some(&resolution.resolved)));
    let mut concurrent = source.clone();
    concurrent.extensions.clear();
    assert!(merge::resolve(&concurrent, &resolution.expected).is_none());
    j.desire(resolution.resolved.clone()).unwrap();
    let mut current = BTreeMap::from([(source.id, resolution.resolved.clone()), (copy.id, copy)]);
    j.reconcile_dependencies(&current).unwrap();
    let source_offer = j
        .mark_offered(std::slice::from_ref(&resolution.resolved))
        .unwrap()[0]
        .clone();
    j.accept_offered(&source_offer, version("clean-source"))
        .unwrap();
    // A restored exact carrier during the awaited source write starts another
    // cleanup epoch, preserving copy receipts but invalidating the old release.
    current.insert(source.id, source.clone());
    j.reconcile_dependencies(&current).unwrap();
    j = restart(&j);
    assert!(!j.dependencies.is_empty());
    assert!(j.dependencies[&source.id].source_offered.is_none());
    assert!(j.dependencies[&source.id].source_accepted_version.is_none());
    assert_eq!(j.carrier_resolutions(&current).unwrap().len(), 1);
}

#[test]
fn immutable_prerequisite_cannot_be_replaced_by_later_same_provenance_bytes() {
    let (source, mut copy) = secure_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, &[]).unwrap();
    j.freeze_authenticated_copy(&copy).unwrap();
    let before = j.clone();
    copy.fields.as_mut().unwrap().name = "Edited after materialization".into();
    assert!(j.freeze_authenticated_copy(&copy).is_err());
    assert!(j == before);
    let mut occupant = record(99, "Unrelated record");
    occupant.id = copy.id;
    assert!(
        j.record_confirmed(occupant.clone(), version("unrelated"))
            .is_err()
    );
    assert!(
        j.reconcile_dependencies(&BTreeMap::from([(copy.id, occupant)]))
            .is_err()
    );
    assert!(j == before);
}

fn nested_plain_conflict() -> (Envelope, Envelope, Envelope, Envelope) {
    let (source, c0) = plain_conflict();
    let mut edited = c0.clone();
    edited.hlc = Hlc::foreign(20);
    edited.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public edited preservation copy".to_vec());
    let merged = merge::merge(None, Some(&c0), Some(&edited)).unwrap();
    (
        source,
        c0,
        merged.survivor.unwrap(),
        merged.conflict_copies[0].clone(),
    )
}

#[test]
fn nested_copies_deliver_leaf_then_original_then_parent_then_edited_copy() {
    let (source, c0, c1, d0) = nested_plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, std::slice::from_ref(&c0))
        .unwrap();
    j.stage_conflict(&c1, std::slice::from_ref(&d0)).unwrap();
    for e in [&source, &c1, &d0] {
        j.desire(e.clone()).unwrap();
    }
    // A fetched C1 is authentic local/remote data, never an ACK for C0.
    j.record_confirmed(c1.clone(), version("fetched-C1"))
        .unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![d0.clone()]);
    let leaf = j.mark_offered(&j.pending().unwrap()).unwrap().remove(0);
    j.accept_offered(&leaf, version("D0")).unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![c0.clone()]);
    let original = j.mark_offered(&j.pending().unwrap()).unwrap().remove(0);
    assert!(original.record_version == Some(version("fetched-C1")));
    j.accept_offered(&original, version("C0")).unwrap();
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![source.clone()]);
    let current = BTreeMap::from([
        (source.id, source.clone()),
        (c1.id, c1.clone()),
        (d0.id, d0),
    ]);
    // Neither nested copy receipts nor a previously fetched parent release it.
    j.record_confirmed(source.clone(), version("fetched-parent"))
        .unwrap();
    j.reconcile_dependencies(&current).unwrap();
    assert_eq!(j.dependencies.len(), 2);
    let parent = j.mark_offered(&j.pending().unwrap()).unwrap().remove(0);
    j.accept_offered(&parent, version("parent-after-copies"))
        .unwrap();
    j = restart(&j);
    j.reconcile_dependencies(&current).unwrap();
    assert_eq!(j.dependencies.len(), 1);
    assert!(j.pending().unwrap() == vec![c1.clone()]);
    let edited = j.mark_offered(&j.pending().unwrap()).unwrap().remove(0);
    assert!(edited.record_version == Some(version("C0")));
    j.accept_offered(&edited, version("C1-after-parent"))
        .unwrap();
    j.reconcile_dependencies(&current).unwrap();
    j = restart(&j);
    assert!(j.dependencies.is_empty());
    assert!(j.pending().unwrap().is_empty());
}

#[test]
fn nested_group_replays_a_preexisting_ambiguous_offer_with_its_original_cas() {
    let (source, c0, c1, d0) = nested_plain_conflict();
    let mut j = Journal::new(scope());
    j.record_confirmed(c0.clone(), version("old-C0")).unwrap();
    j.desire(c1.clone()).unwrap();
    let old = j.mark_offered(std::slice::from_ref(&c1)).unwrap().remove(0);
    j.stage_conflict(&source, std::slice::from_ref(&c0))
        .unwrap();
    j.stage_conflict(&c1, std::slice::from_ref(&d0)).unwrap();
    j.record_confirmed(c0.clone(), version("new-C0")).unwrap();
    j = restart(&j);
    let pending = j.pending().unwrap();
    assert!(pending.contains(&c1));
    assert!(pending.contains(&d0));
    assert!(!pending.contains(&c0));
    assert!(!pending.contains(&source));
    assert!(j.mark_offered(std::slice::from_ref(&c1)).unwrap() == vec![old.clone()]);
    assert!(old.record_version == Some(version("old-C0")));
    j.reject(c1.id);
    j = restart(&j);
    assert!(j.pending().unwrap() == vec![d0]);
}

#[test]
fn preservation_traversal_rejects_cycles_and_multiple_parents_without_recursion() {
    let (source, copy) = plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, &[copy]).unwrap();
    let template = j.dependencies[&source.id].clone();
    j.dependencies.clear();
    for i in 1..=4096u128 {
        let mut edge = template.clone();
        edge.source.id = Uuid::from_u128(i);
        edge.requirements.values_mut().next().unwrap().copy_id = Uuid::from_u128(i + 1);
        j.dependencies.insert(edge.source.id, edge);
    }
    assert_eq!(j.preservation_order().unwrap().len(), 4096);
    j.dependencies
        .get_mut(&Uuid::from_u128(4096))
        .unwrap()
        .requirements
        .values_mut()
        .next()
        .unwrap()
        .copy_id = Uuid::from_u128(1);
    assert!(j.preservation_order().is_err());
    j.dependencies
        .get_mut(&Uuid::from_u128(4096))
        .unwrap()
        .requirements
        .values_mut()
        .next()
        .unwrap()
        .copy_id = Uuid::from_u128(2);
    assert!(j.preservation_order().is_err());
}

#[test]
fn carrier_cleanup_stages_held_intent_and_review_anchor_without_erasing_an_original_offer() {
    let (source, copy) = secure_conflict();
    let mut clear = source.clone();
    clear
        .extensions
        .retain(|key, _| !key.starts_with(merge::CONFLICT_PREFIX));
    let mut j = Journal::new(scope());
    j.record_confirmed(clear.clone(), version("original-CAS"))
        .unwrap();
    let mut original = clear.clone();
    original.hlc = Hlc::foreign(3);
    j.desire(original.clone()).unwrap();
    let original_offer = j.mark_offered(&[original]).unwrap().remove(0);
    j.stage_conflict(&source, &[]).unwrap();
    j.freeze_authenticated_copy(&copy).unwrap();
    let mut held = source.clone();
    held.hlc = Hlc::foreign(20);
    held.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public newer held fields".to_vec());
    j.desire(held.clone()).unwrap();
    j.entries.get_mut(&source.id).unwrap().review = ReviewAncestor::Reviewed {
        primary: Some(Box::new(source.clone())),
        previous_merge: Some(Box::new(clear)),
    };
    let offered_copy = j
        .mark_offered(std::slice::from_ref(&copy))
        .unwrap()
        .remove(0);
    j.accept_offered(&offered_copy, version("real-copy-ACK"))
        .unwrap();
    let physical = BTreeMap::from([(source.id, source.clone()), (copy.id, copy)]);
    let resolution = j.carrier_resolutions(&physical).unwrap().remove(0);
    let staged = restart(&j.stage_carrier_resolution(&resolution, &physical).unwrap());
    assert!(j.preserves_transport_state(&staged));
    assert!(staged.entry(source.id).unwrap().offered.as_ref() == Some(&original_offer));
    let cleaned = &staged.entry(source.id).unwrap().desired;
    assert!(cleaned.fields == held.fields && !merge::has_unresolved(Some(cleaned)));
    assert!(
        staged
            .local_intent(source.id, Some(&resolution.resolved))
            .unwrap()
            == Some(cleaned)
    );
    let mut forged = resolution;
    forged.resolved.fields.as_mut().unwrap().name = "Public unreviewed edit".into();
    assert!(j.stage_carrier_resolution(&forged, &physical).is_err());
}

#[test]
fn new_requirements_and_new_parents_cannot_discard_an_ambiguous_source_cas() {
    let (source, c0, c1, d0) = nested_plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, std::slice::from_ref(&c0))
        .unwrap();
    let offer = j.mark_offered(std::slice::from_ref(&c0)).unwrap().remove(0);
    j.accept_offered(&offer, version("C0")).unwrap();
    let original = j
        .mark_offered(std::slice::from_ref(&source))
        .unwrap()
        .remove(0);
    let before = restart(&j);
    let mut newer = source.clone();
    newer.hlc = Hlc::foreign(30);
    newer.fields.as_mut().unwrap().content =
        zeroize::Zeroizing::new(b"Public later source version".to_vec());
    let new_copy = merge::plain_copy(&newer).unwrap();
    assert!(j.stage_conflict(&source, &[new_copy]).is_err());
    assert!(j == before && j.retains_offer(&original));
    let mut child = Journal::new(scope());
    child
        .stage_conflict(&c1, std::slice::from_ref(&d0))
        .unwrap();
    let offered = child.mark_offered(&[d0]).unwrap().remove(0);
    child.accept_offered(&offered, version("D0")).unwrap();
    let original = child
        .mark_offered(std::slice::from_ref(&c1))
        .unwrap()
        .remove(0);
    let before = restart(&child);
    assert!(child.stage_conflict(&source, &[c0]).is_err());
    assert!(child == before && child.retains_offer(&original));
}

#[test]
fn checkpoint_encrypts_all_bodies_and_detects_key_salt_scope_and_tampering() {
    let mut j = Journal::new(scope());
    j.desire(record(
        1,
        "Visible only inside the encrypted public fixture",
    ))
    .unwrap();
    let plain = codec::encode(&j).unwrap();
    let salt = [0x66; 32];
    let sealed = crypto::seal_checkpoint(&plain, &key(), &salt).unwrap();
    assert!(!sealed.windows(12).any(|w| w == b"Visible only"));
    assert!(
        codec::decode(
            &crypto::open_checkpoint(&sealed, &key(), &salt).unwrap(),
            scope()
        )
        .unwrap()
            == j
    );
    let wrong = RootKey::from_bytes(&[0x77; 32]).unwrap();
    assert!(crypto::open_checkpoint(&sealed, &wrong, &salt).is_err());
    assert!(crypto::open_checkpoint(&sealed, &key(), &[0x88; 32]).is_err());
    let mut bad = sealed.clone();
    bad[20] ^= 1;
    assert!(crypto::open_checkpoint(&bad, &key(), &salt).is_err());
    let other = Scope {
        membership: scope().membership,
        dataset: Binding::from_checkpoint([0x99; 32]),
    };
    assert!(codec::decode(&plain, other) == Err(Failure::ScopeReview));
    // Binding is checked before parsing any envelope, even if the later bytes
    // were independently corrupted or belong to an unrecognized body schema.
    let mut corrupt = plain.clone();
    corrupt.truncate(68);
    corrupt.extend_from_slice(b"invalid payload");
    let other = Scope {
        membership: Binding::from_checkpoint([0x99; 32]),
        dataset: scope().dataset,
    };
    assert!(codec::decode(&corrupt, other) == Err(Failure::ScopeReview));
    let id = record(1, "").id;
    assert!(crypto::open_wire(&sealed, &key(), &salt, id, false).is_err());
}

#[test]
fn bounded_codec_refuses_unknown_schema_truncation_invalid_tags_and_trailing_bytes() {
    let mut j = Journal::new(scope());
    j.desire(record(1, "Body")).unwrap();
    let bytes = codec::encode(&j).unwrap();
    for n in [0, 3, 67, 68, 72, bytes.len() - 1] {
        assert!(codec::decode(&bytes[..n], scope()).is_err());
    }
    let mut bad = bytes.clone();
    bad[3] = b'9';
    assert!(codec::decode(&bad, scope()).is_err());
    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(codec::decode(&trailing, scope()).is_err());
    let mut count = bytes.clone();
    count[68..72].copy_from_slice(&u32::MAX.to_be_bytes());
    assert!(codec::decode(&count, scope()).is_err());
    // Invalid reviewed-state and optional-offer tags are never interpreted as
    // absent. Their offsets follow the length-prefixed desired envelope.
    let envelope_len = u32::from_be_bytes(bytes[88..92].try_into().unwrap()) as usize;
    let offer_tag = 92 + envelope_len + 8;
    let mut invalid_offer = bytes.clone();
    invalid_offer[offer_tag] = 2;
    assert!(codec::decode(&invalid_offer, scope()).is_err());
    let mut invalid_review = bytes.clone();
    invalid_review[offer_tag + 1] = 2;
    assert!(codec::decode(&invalid_review, scope()).is_err());
}

#[test]
fn reviewed_absence_round_trips_separately_from_unknown_and_older_merge_ancestor() {
    let mut j = Journal::new(scope());
    let desired = record(2, "Recovered intent");
    j.desire(desired.clone()).unwrap();
    j.entries.get_mut(&desired.id).unwrap().review = ReviewAncestor::Reviewed {
        primary: None,
        previous_merge: Some(Box::new(record(1, "Older ancestor"))),
    };
    let recovered = restart(&j);
    assert!(matches!(
        recovered.entries[&desired.id].review,
        ReviewAncestor::Reviewed {
            primary: None,
            previous_merge: Some(_)
        }
    ));
    let mut unknown = recovered.clone();
    unknown.entries.get_mut(&desired.id).unwrap().review = ReviewAncestor::Unknown;
    assert!(codec::encode(&unknown).unwrap() != codec::encode(&recovered).unwrap());
}

#[test]
fn legacy_schema_one_upgrades_without_erasing_immutable_conflict_proofs() {
    let (source, copy) = plain_conflict();
    let mut journal = Journal::new(scope());
    journal
        .stage_conflict(&source, std::slice::from_ref(&copy))
        .unwrap();
    journal.desire(source).unwrap();
    journal.mark_offered(&[copy]).unwrap();
    let mut old = codec::encode_legacy_five(&journal).unwrap();
    assert_eq!(&old[..4], b"JNL5");
    old[3] = b'1';
    // Schema 1 ends before the empty projection map and absent primary intent.
    let old_len = old.len() - 6 - 22 - 2 - 4;
    old.truncate(old_len);
    let upgraded = codec::decode(&old, scope()).unwrap();
    assert!(upgraded == journal);
    assert_eq!(&codec::encode(&upgraded).unwrap()[..4], b"JNL6");
}

#[test]
fn legacy_schema_two_preserves_primary_projection_and_starts_with_an_empty_inbox() {
    let mut journal = Journal::new(scope());
    let e = record(1, "Public schema-two fixture");
    journal.projected.insert(e.id, e);
    journal.primary_epoch = Some([0x55; 16]);
    let mut old = codec::encode_legacy_five(&journal).unwrap();
    old[3] = b'2';
    let old_len = old.len() - 22 - 2 - 4;
    old.truncate(old_len);
    let upgraded = codec::decode(&old, scope()).unwrap();
    assert!(upgraded == journal);
    assert_eq!(&codec::encode(&upgraded).unwrap()[..4], b"JNL6");
}

#[test]
fn legacy_schema_three_preserves_the_inbox_and_starts_without_an_outbound_packet() {
    use crate::inbound::Feed;
    let mut journal = Journal::new(scope());
    journal
        .inbox
        .select_feed(Feed::new(Uuid::from_u128(3), 1).unwrap())
        .unwrap();
    let mut old = codec::encode_legacy_five(&journal).unwrap();
    old[3] = b'3';
    let len = old.len() - 2 - 4;
    old.truncate(len);
    let upgraded = codec::decode(&old, scope()).unwrap();
    assert!(upgraded == journal);
    assert_eq!(&codec::encode(&upgraded).unwrap()[..4], b"JNL6");
}

#[test]
fn legacy_schema_four_keeps_exact_tombstone_bytes_without_inventing_consent() {
    use crate::outbound::{Packet, Transmission};
    let mut j = Journal::new(scope());
    j.key_epoch = Some(1);
    let old = record(1, "Public deleted legacy body");
    let deleted = old
        .tombstone(Hlc::foreign(2), "aaaaaaa1".into(), true)
        .unwrap();
    j.desire(deleted.clone()).unwrap();
    let offered = j
        .mark_offered(std::slice::from_ref(&deleted))
        .unwrap()
        .remove(0);
    let wire = crate::wire::WireRecord::seal(&deleted, &key(), &[0x66; 32]).unwrap();
    j.outbound = Some(Packet {
        key_epoch: 1,
        offers: vec![Transmission {
            offered,
            wire: wire.clone(),
            deletion_authorized: false,
        }],
        receipts: None,
        received_at: None,
        position: 0,
    });
    let old = codec::encode_legacy_four(&j).unwrap();
    assert_eq!(&old[..4], b"JNL4");
    let upgraded = codec::decode(&old, scope()).unwrap();
    assert!(upgraded == j);
    assert!(!upgraded.deletion_approved(&deleted).unwrap());
    assert!(upgraded.outbound.as_ref().unwrap().offers[0].wire == wire);
    assert!(!upgraded.outbound.as_ref().unwrap().offers[0].deletion_authorized);
    assert_eq!(&codec::encode(&upgraded).unwrap()[..4], b"JNL6");
}

#[test]
fn deletion_consent_is_exact_scoped_encrypted_state_and_cannot_match_a_new_generation() {
    let mut j = Journal::new(scope());
    j.key_epoch = Some(1);
    let old = record(1, "Public consent ancestor");
    let deleted = old
        .tombstone(Hlc::foreign(2), "aaaaaaa1".into(), true)
        .unwrap();
    j.desire(deleted.clone()).unwrap();
    j.approve_deletion(&deleted, Some(old.clone())).unwrap();
    let recovered = restart(&j);
    assert!(recovered.deletion_approved(&deleted).unwrap());
    let changed = old
        .tombstone(Hlc::foreign(3), "aaaaaaa1".into(), true)
        .unwrap();
    assert!(!recovered.deletion_approved(&changed).unwrap());
    let mut invalid = j.clone();
    invalid.entries.get_mut(&old.id).unwrap().desired = changed.clone();
    assert!(codec::encode(&invalid).is_err());
    j.desire(changed).unwrap();
    assert!(j.deletion_approvals.is_empty());
    assert!(
        codec::decode(
            &codec::encode(&recovered).unwrap(),
            Scope {
                membership: Binding::from_checkpoint([0x99; 32]),
                dataset: scope().dataset
            }
        )
        .is_err()
    );
}

#[test]
fn schema_three_retains_partial_page_and_rejects_inconsistent_cursor_or_receipt_state() {
    use crate::{cloud::Cursor, inbound::Feed};
    let mut j = Journal::new(scope());
    let feed = Feed::new(Uuid::from_u128(12), 1).unwrap();
    j.inbox.select_feed(feed.clone()).unwrap();
    let mut a = record(1, "Public queued A");
    a.id = Uuid::from_u128(1);
    let mut b = record(2, "Public queued B");
    b.id = Uuid::from_u128(2);
    j.inbox
        .receive(
            &feed,
            None,
            vec![
                Confirmed {
                    envelope: a,
                    record_version: version("a"),
                },
                Confirmed {
                    envelope: b,
                    record_version: version("b"),
                },
            ],
            Cursor::from_checkpoint("public-fixture-snapshot-cursor".into()).unwrap(),
            true,
            true,
        )
        .unwrap();
    j.inbox.acknowledge_record().unwrap();
    let encoded = codec::encode(&j).unwrap();
    assert!(codec::decode(&encoded, scope()).unwrap() == j);
    for change in 0..8 {
        let mut invalid = j.clone();
        match change {
            0 => invalid.inbox.feed = None,
            1 => invalid.inbox.pending.as_mut().unwrap().position = 3,
            2 => invalid.inbox.pending.as_mut().unwrap().generation = 2,
            3 => invalid.inbox.completed = 1,
            4 => {
                invalid.inbox.fetched_cursor =
                    Some(Cursor::from_checkpoint("public-other-cursor".into()).unwrap())
            }
            5 => {
                invalid
                    .inbox
                    .snapshot
                    .as_mut()
                    .unwrap()
                    .seen
                    .remove(&Uuid::from_u128(1));
            }
            6 => invalid.inbox.snapshot.as_mut().unwrap().open = false,
            7 => invalid.inbox.review = true,
            _ => unreachable!(),
        }
        assert!(codec::encode(&invalid).is_err());
    }
    for cut in [86, 112, 128, encoded.len() / 2, encoded.len() - 1] {
        assert!(codec::decode(&encoded[..cut], scope()).is_err());
    }
    let mut bad = encoded.clone();
    let last = bad.len() - 1;
    bad[last] = 2;
    assert!(codec::decode(&bad, scope()).is_err());
    bad[last] = 1;
    assert!(codec::decode(&bad, scope()).is_err());
}

#[test]
fn full_snapshot_receipt_requires_application_before_missing_record_review() {
    use crate::{cloud::Cursor, inbound::Feed};
    let mut j = Journal::new(scope());
    let feed = Feed::new(Uuid::from_u128(12), 1).unwrap();
    j.inbox.select_feed(feed.clone()).unwrap();
    j.inbox
        .receive(
            &feed,
            None,
            vec![Confirmed {
                envelope: record(1, "Public final page"),
                record_version: version("a"),
            }],
            Cursor::from_checkpoint("public-final-snapshot-cursor".into()).unwrap(),
            true,
            false,
        )
        .unwrap();
    assert!(
        j.inbox
            .finish_snapshot([Uuid::from_u128(2)].into_iter())
            .is_err()
    );
    assert!(!j.inbox.needs_review());
    assert!(j.inbox.complete_page().is_err());
    j.inbox.acknowledge_record().unwrap();
    j.inbox.complete_page().unwrap();
    j.inbox
        .finish_snapshot([Uuid::from_u128(2)].into_iter())
        .unwrap();
    assert!(restart(&j).inbox.needs_review());
    assert!(j.inbox.restart_snapshot().is_err());
    assert!(
        j.inbox
            .select_feed(Feed::new(Uuid::from_u128(13), 1).unwrap())
            .is_err()
    );
}

#[test]
fn filesystem_checkpoint_is_atomic_private_and_rejects_a_stale_writer() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let salt = [0x66; 32];
    let mut first = Checkpoint::load(&library, &key(), &salt, scope()).unwrap();
    assert!(!library.root.join("Sync").exists());
    let mut stale = Checkpoint::load(&library, &key(), &salt, scope()).unwrap();
    first
        .journal
        .desire(record(1, "Persistent public fictional body"))
        .unwrap();
    first.save(&library, &key(), &salt).unwrap();
    let path = library.root.join("Sync/journal.bin");
    assert_eq!(
        fs::metadata(path.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let before = fs::read(&path).unwrap();
    stale
        .journal
        .desire(record(2, "Stale unrelated edit"))
        .unwrap();
    assert!(stale.save(&library, &key(), &salt) == Err(Failure::StaleCheckpoint));
    assert_eq!(fs::read(&path).unwrap(), before);
    assert!(
        Checkpoint::load(&library, &key(), &salt, scope())
            .unwrap()
            .journal
            == first.journal
    );
    let mut bad = before;
    bad[20] ^= 1;
    fs::write(&path, bad).unwrap();
    assert!(Checkpoint::load(&library, &key(), &salt, scope()).is_err());
}

#[test]
fn checkpoint_refuses_linked_directories_and_nonregular_files() {
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let outside = tempfile::tempdir().unwrap();
    symlink(outside.path(), library.root.join("Sync")).unwrap();
    assert!(Checkpoint::load(&library, &key(), &[0x66; 32], scope()).is_err());
    assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
    fs::remove_file(library.root.join("Sync")).unwrap();
    fs::create_dir(library.root.join("Sync")).unwrap();
    symlink(
        outside.path().join("anything"),
        library.root.join("Sync/journal.bin"),
    )
    .unwrap();
    assert!(Checkpoint::load(&library, &key(), &[0x66; 32], scope()).is_err());
    let mut checkpoint = Checkpoint {
        journal: Journal::new(scope()),
        snapshot: None,
    };
    assert!(checkpoint.save(&library, &key(), &[0x66; 32]).is_err());
}

#[test]
fn state_validation_refuses_forged_receipts_and_conflicting_dependency_ownership() {
    let (source, copy) = plain_conflict();
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, std::slice::from_ref(&copy))
        .unwrap();
    let r = j
        .dependencies
        .get_mut(&source.id)
        .unwrap()
        .requirements
        .values_mut()
        .next()
        .unwrap();
    r.snapshot = None;
    r.accepted_version = Some(version("forged"));
    assert!(codec::encode(&j).is_err());
    let mut j = Journal::new(scope());
    j.stage_conflict(&source, std::slice::from_ref(&copy))
        .unwrap();
    let mut foreign_source = record(3, "Another source");
    foreign_source.id = copy.id;
    let before = j.clone();
    // Different independent source cannot claim a UUID reserved as this copy.
    let foreign_copy = merge::merge(
        None,
        Some(&foreign_source),
        Some(&Envelope {
            hlc: Hlc::foreign(4),
            fields: Some(Fields {
                content: zeroize::Zeroizing::new(b"Other".to_vec()),
                ..foreign_source.fields.clone().unwrap()
            }),
            ..foreign_source.clone()
        }),
    )
    .unwrap()
    .conflict_copies
    .remove(0);
    assert!(j.stage_conflict(&foreign_source, &[foreign_copy]).is_err());
    assert!(j == before);
}
