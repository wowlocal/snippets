//! All bodies, identifiers and keys below are public fictional test data.
use super::*;
use crate::{crypto, wire::WireRecord};
use zeroize::Zeroizing;

fn record(wall: u64, body: &str) -> Envelope {
    Envelope {
        id: Uuid::parse_str("00000000-0000-4000-8000-000000000021").unwrap(),
        hlc: Hlc::parse(&format!("{wall:012x}-0000-aaaaaaa1")).unwrap(),
        origin: "aaaaaaa1".into(),
        secure: false,
        deleted: false,
        fields: Some(Fields {
            name: "Public losing fixture".into(),
            keyword: "fixture".into(),
            content: Zeroizing::new(body.as_bytes().to_vec()),
            tags: vec!["Work".into()],
            is_enabled: true,
            is_pinned: true,
            created_at: 0.0,
            updated_at: 120.0,
        }),
        extensions: BTreeMap::new(),
    }
}
fn secure(wall: u64, body: &str, hash: &str, kid: &str) -> Envelope {
    let mut record = record(wall, body);
    record.secure = true;
    record
        .extensions
        .insert("vaultContentHash".into(), Value::text(hash));
    record
        .extensions
        .insert("vaultKID".into(), Value::text(kid));
    record
}
fn fields(envelope: &mut Envelope) -> &mut Fields {
    envelope.fields.as_mut().unwrap()
}
fn checked_merge(base: Option<&Envelope>, local: &Envelope, remote: &Envelope) -> Outcome {
    let forward = merge(base, Some(local), Some(remote)).unwrap();
    let reverse = merge(base, Some(remote), Some(local)).unwrap();
    assert!(
        forward == reverse,
        "mirrored peers must preserve identical output"
    );
    for e in forward.survivor.iter().chain(&forward.conflict_copies) {
        validate(e).unwrap();
        assert!(Envelope::parse(&e.encode().unwrap()).unwrap() == *e);
    }
    forward
}

#[test]
fn independent_metadata_and_body_edits_combine_without_clock_skew_loss() {
    let base = record(1, "Original fictional text");
    let mut local = base.clone();
    local.hlc = Hlc::foreign(1000);
    fields(&mut local).name = "Renamed on another device".into();
    fields(&mut local).is_pinned = false;
    fields(&mut local).tags = vec!["WORK".into(), "Local".into()];
    fields(&mut local).updated_at = 200.0;
    let mut remote = record(2, "Body edited independently");
    fields(&mut remote).keyword = "new-keyword".into();
    fields(&mut remote).is_enabled = false;
    fields(&mut remote).tags = vec!["Work".into(), "Remote".into()];
    fields(&mut remote).created_at = -1.0;
    let outcome = checked_merge(Some(&base), &local, &remote);
    assert!(outcome.conflict_copies.is_empty());
    let f = outcome.survivor.unwrap().fields.unwrap();
    assert_eq!(f.name, "Renamed on another device");
    assert_eq!(f.keyword, "new-keyword");
    assert!(*f.content == b"Body edited independently");
    assert!(!f.is_enabled && !f.is_pinned);
    assert_eq!(f.tags, ["WORK", "Local", "Remote"]);
    assert_eq!((f.created_at, f.updated_at), (-1.0, 200.0));
}

#[test]
fn tag_removals_win_and_no_ancestor_keeps_preferred_hand_order() {
    let mut base = record(1, "Same text");
    fields(&mut base).tags = vec!["Work".into(), "Discard".into(), "Last".into()];
    let mut local = record(2, "Same text");
    fields(&mut local).tags = vec!["WORK".into(), "Zulu".into(), "Last".into()];
    let mut remote = record(3, "Same text");
    fields(&mut remote).tags = vec!["Work".into(), "Discard".into(), "alpha".into()];
    let result = checked_merge(Some(&base), &local, &remote)
        .survivor
        .unwrap();
    assert_eq!(result.fields.unwrap().tags, ["Work", "alpha", "Zulu"]);
    fields(&mut remote).tags = vec!["Zulu".into(), "Alpha".into()];
    fields(&mut local).tags = vec!["Extra".into(), "Alpha".into()];
    let result = checked_merge(None, &local, &remote).survivor.unwrap();
    assert_eq!(result.fields.unwrap().tags, ["Zulu", "Alpha", "Extra"]);
}

#[test]
fn absence_never_deletes_and_explicit_delete_yields_to_a_real_edit() {
    let base = record(1, "Original");
    assert!(merge(Some(&base), None, Some(&base)).unwrap().survivor == Some(base.clone()));
    assert!(merge(Some(&base), Some(&base), None).unwrap().survivor == Some(base.clone()));
    assert!(merge(Some(&base), None, None).unwrap().survivor.is_none());
    let delete = base
        .tombstone(Hlc::foreign(100), "bbbbbbb2".into(), true)
        .unwrap();
    assert!(
        checked_merge(Some(&base), &delete, &base)
            .survivor
            .unwrap()
            .deleted
    );
    let edited = record(2, "Edited while deletion happened");
    assert!(checked_merge(Some(&base), &delete, &edited).survivor == Some(edited.clone()));
    assert!(checked_merge(None, &delete, &base).survivor == Some(base.clone()));
    let mut other_delete = delete.clone();
    other_delete.hlc = Hlc::foreign(200);
    assert!(checked_merge(Some(&base), &delete, &other_delete).survivor == Some(other_delete));
}

#[test]
fn ordinary_conflict_copy_matches_independent_snapshot_sha_and_uuid_v5() {
    let reference: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/merge-v1.json")).unwrap();
    let loser = record(10, "Fictional lost body 🦀\n");
    let winner = record(11, "Winning fictional body");
    assert!(
        *Value::Object(snapshot(&loser).unwrap()).encode().unwrap()
            == reference["snapshotCanonical"].as_str().unwrap().as_bytes()
    );
    let outcome = checked_merge(None, &loser, &winner);
    let copy = &outcome.conflict_copies[0];
    assert_eq!(copy.id.to_string(), reference["copyID"].as_str().unwrap());
    assert_eq!(
        provenance(copy).unwrap().fingerprint,
        reference["fingerprint"].as_str().unwrap()
    );
    assert!(valid_copy_identity(copy));
    assert!(matching_plain_copy(copy, copy));
    let f = copy.fields.as_ref().unwrap();
    assert!(f.content == loser.fields.as_ref().unwrap().content);
    assert_eq!(
        f.name,
        "Public losing fixture (conflict 2001-01-01 00:02 UTC)"
    );
    assert!(f.keyword.is_empty() && !f.is_enabled && !f.is_pinned);
    assert_eq!(f.tags, ["Work", "conflict"]);
    let repeated = checked_merge(None, &loser, &winner);
    assert!(repeated == outcome);
    let survivor = outcome.survivor.unwrap();
    assert!(
        checked_merge(Some(&survivor), &survivor, &survivor)
            .conflict_copies
            .is_empty()
    );
}

#[test]
fn generated_copy_keeps_unknown_extensions_but_never_nested_conflict_carriers() {
    let mut loser = record(2, "Plain body");
    loser
        .extensions
        .insert("futureMetadata".into(), Value::text("Public future value"));
    loser
        .extensions
        .insert("vaultKID".into(), Value::text("obsolete-vault"));
    loser
        .extensions
        .insert("vaultContentHash".into(), Value::text("obsolete-hash"));
    let future = format!("contentConflict.v2.{}", "a".repeat(64));
    loser.extensions.insert(future.clone(), Value::Int(99));
    let winner = record(3, "Other body");
    let outcome = checked_merge(None, &loser, &winner);
    let copy = &outcome.conflict_copies[0];
    assert!(copy.extensions.contains_key("futureMetadata"));
    assert!(!copy.extensions.contains_key(&future));
    assert!(!copy.extensions.contains_key("vaultKID"));
    assert!(!copy.extensions.contains_key("vaultContentHash"));
    assert!(outcome.survivor.unwrap().extensions.contains_key(&future));
}

#[test]
fn copy_display_name_handles_blank_lines_and_extended_graphemes() {
    let mut loser = record(1, &format!("\n \r\n {}!\n", "👨‍👩‍👧‍👦".repeat(51)));
    fields(&mut loser).name = "  ".into();
    fields(&mut loser).updated_at = -60.0;
    let copy = plain_copy(&loser).unwrap();
    assert_eq!(
        copy.fields.unwrap().name,
        format!("{}… (conflict 2000-12-31 23:59 UTC)", "👨‍👩‍👧‍👦".repeat(50))
    );
}

#[test]
fn secure_selected_body_keeps_its_own_key_and_hash_despite_newer_metadata_clock() {
    let base = secure(
        1,
        "Fictional original seal",
        "same-original-hash",
        "vault-original",
    );
    let mut metadata = base.clone();
    metadata.hlc = Hlc::foreign(1000);
    fields(&mut metadata).name = "Renamed securely".into();
    let edited = secure(2, "Fictional changed seal", "edited-hash", "vault-edited");
    let outcome = checked_merge(Some(&base), &metadata, &edited);
    assert!(outcome.conflict_copies.is_empty());
    let survivor = outcome.survivor.unwrap();
    assert_eq!(survivor.fields.as_ref().unwrap().name, "Renamed securely");
    assert!(survivor.fields.as_ref().unwrap().content == edited.fields.unwrap().content);
    assert_eq!(
        survivor.extensions["vaultKID"].as_text().unwrap(),
        "vault-edited"
    );
    assert_eq!(
        survivor.extensions["vaultContentHash"].as_text().unwrap(),
        "edited-hash"
    );
}

#[test]
fn fresh_secure_nonce_is_not_an_edit_and_a_different_vault_is_a_conflict() {
    let root = crypto::RootKey::from_bytes(&[0x11; 32]).unwrap();
    let salt = [0x22; 32];
    let source = record(1, "Fictional public secret");
    let first = crypto::seal_record(
        b"Fictional public secret",
        &root,
        &salt,
        "fixture-vault",
        source.id,
        false,
    )
    .unwrap();
    let second = crypto::seal_record(
        b"Fictional public secret",
        &root,
        &salt,
        "fixture-vault",
        source.id,
        false,
    )
    .unwrap();
    assert_ne!(first.text(), second.text());
    let hash = crypto::content_hash(b"Fictional public secret", &root, &salt);
    let a = secure(2, first.text(), &hash, "fixture-vault");
    let b = secure(3, second.text(), &hash, "fixture-vault");
    let outcome = checked_merge(None, &a, &b);
    assert!(outcome.conflict_copies.is_empty());
    assert!(!has_unresolved(outcome.survivor.as_ref()));
    let other_vault_seal = crypto::seal_record(
        b"Fictional public secret",
        &root,
        &salt,
        "different-vault",
        source.id,
        false,
    )
    .unwrap();
    let c = secure(4, other_vault_seal.text(), &hash, "different-vault");
    let survivor = checked_merge(None, &b, &c).survivor.unwrap();
    assert_eq!(secure_variants(&survivor).unwrap().len(), 1);
}

#[test]
fn secure_losing_bytes_stay_under_source_aad_until_key_aware_materialization() {
    let root = crypto::RootKey::from_bytes(&[0x11; 32]).unwrap();
    let salt = [0x22; 32];
    let mut loser = record(1, "");
    let sealed = crypto::seal_record(
        b"Losing fictional secret",
        &root,
        &salt,
        "fixture-vault",
        loser.id,
        false,
    )
    .unwrap();
    loser = secure(
        1,
        sealed.text(),
        &crypto::content_hash(b"Losing fictional secret", &root, &salt),
        "fixture-vault",
    );
    loser.extensions.insert(
        "futurePrivateExtension".into(),
        Value::text("Must not enter the mirrored snapshot"),
    );
    let winner = secure(2, "Opaque newer seal", "newer-hash", "fixture-vault");
    let outcome = checked_merge(None, &loser, &winner);
    assert!(outcome.conflict_copies.is_empty());
    let survivor = outcome.survivor.unwrap();
    let variants = secure_variants(&survivor).unwrap();
    let v = &variants[0];
    assert_eq!(variants.len(), 1);
    assert_eq!(v.source_id, loser.id);
    assert_ne!(v.copy_id, loser.id);
    assert!(!v.source_extensions.contains_key("futurePrivateExtension"));
    assert_eq!(v.source_extensions.len(), 2);
    assert!(crypto::open_record(&sealed, &root, &salt, "fixture-vault", v.copy_id, false).is_err());
    assert!(
        *crypto::open_record(&sealed, &root, &salt, "fixture-vault", v.source_id, false).unwrap()
            == b"Losing fictional secret"
    );
    let wire = WireRecord::seal(&survivor, &root, &salt).unwrap();
    assert!(wire.open(&root, &salt).unwrap() == survivor);
}

#[test]
fn representation_changes_preserve_losing_plain_or_secure_body() {
    let plain = record(1, "Plain original");
    let promoted = secure(2, "Opaque promoted seal", "secure-hash", "fixture-vault");
    let edited = record(3, "Plain independently edited");
    let winner_plain = checked_merge(Some(&plain), &promoted, &edited);
    assert!(!winner_plain.survivor.as_ref().unwrap().secure);
    assert_eq!(
        secure_variants(winner_plain.survivor.as_ref().unwrap())
            .unwrap()
            .len(),
        1
    );
    assert!(
        !winner_plain
            .survivor
            .unwrap()
            .extensions
            .contains_key("vaultKID")
    );
    let mut newer_promoted = promoted.clone();
    newer_promoted.hlc = Hlc::foreign(4);
    let winner_secure = checked_merge(Some(&plain), &edited, &newer_promoted);
    assert!(winner_secure.survivor.unwrap().secure);
    assert_eq!(winner_secure.conflict_copies.len(), 1);
    assert!(
        winner_secure.conflict_copies[0]
            .fields
            .as_ref()
            .unwrap()
            .content
            == edited.fields.unwrap().content
    );
    let demoted = record(5, "Plain demoted");
    let secure_edit = secure(6, "Opaque edited seal", "other-hash", "fixture-vault");
    assert_eq!(
        checked_merge(Some(&promoted), &demoted, &secure_edit)
            .conflict_copies
            .len(),
        1
    );
}

#[test]
fn equal_fields_backfill_legacy_vault_extensions_and_plain_removes_stale_routing() {
    let mut older = secure(1, "Same seal", "hash", "kid");
    let mut newer = older.clone();
    newer.hlc = Hlc::foreign(2);
    newer.extensions.remove("vaultKID");
    let survivor = checked_merge(None, &older, &newer).survivor.unwrap();
    assert_eq!(survivor.extensions["vaultKID"].as_text().unwrap(), "kid");
    older.secure = false;
    newer.secure = false;
    let survivor = checked_merge(None, &older, &newer).survivor.unwrap();
    assert!(!survivor.extensions.contains_key("vaultKID"));
    assert!(!survivor.extensions.contains_key("vaultContentHash"));
}

#[test]
fn tie_rank_ignores_unionable_variants_and_does_not_reverse_selected_body() {
    let a = secure(2, "Seal A", "hash-a", "kid");
    let mut b = secure(2, "Seal B", "hash-b", "kid");
    fields(&mut b).name = "Different name".into();
    let initial = checked_merge(None, &a, &b);
    let selected = initial
        .survivor
        .as_ref()
        .unwrap()
        .fields
        .as_ref()
        .unwrap()
        .content
        .clone();
    let losing = if selected == a.fields.as_ref().unwrap().content {
        &b
    } else {
        &a
    };
    let winner = if selected == a.fields.as_ref().unwrap().content {
        &a
    } else {
        &b
    };
    let mut carried_winner = winner.clone();
    carried_winner.extensions.extend(
        initial
            .survivor
            .unwrap()
            .extensions
            .into_iter()
            .filter(|(k, _)| k.starts_with(CONFLICT_PREFIX)),
    );
    let repeated = checked_merge(None, &carried_winner, losing)
        .survivor
        .unwrap();
    assert!(repeated.fields.as_ref().unwrap().content == selected);
    assert_eq!(secure_variants(&repeated).unwrap().len(), 1);
    assert!(checked_merge(None, &repeated, &repeated).survivor == Some(repeated));
}

#[test]
fn independently_carried_variants_union_and_resolve_only_exact_understood_values() {
    let a = secure(1, "Seal A", "a", "kid");
    let b = secure(2, "Seal B", "b", "kid");
    let current = secure(3, "Current seal", "current", "kid");
    let carried_a = checked_merge(None, &a, &current).survivor.unwrap();
    let carried_b = checked_merge(None, &b, &current).survivor.unwrap();
    let mut union = checked_merge(None, &carried_a, &carried_b)
        .survivor
        .unwrap();
    assert_eq!(secure_variants(&union).unwrap().len(), 2);
    let future = format!("contentConflict.v2.{}", "c".repeat(64));
    union
        .extensions
        .insert(future.clone(), Value::text("Opaque future fixture"));
    validate(&union).unwrap();
    assert!(has_unknown_version(&union));
    let expected: BTreeMap<_, _> = union
        .extensions
        .iter()
        .filter(|(k, _)| k.starts_with(CONFLICT_V1_PREFIX))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let resolved = resolve(&union, &expected).unwrap();
    assert!(resolved.extensions.contains_key(&future));
    assert!(has_unresolved(Some(&resolved)));
    assert!(resolve(&resolved, &expected).is_none());
    let mut stale = expected.clone();
    *stale.values_mut().next().unwrap() = Value::Null;
    assert!(resolve(&union, &stale).is_none());
    assert!(
        resolve(
            &union,
            &BTreeMap::from([(future, Value::text("Opaque future fixture"))])
        )
        .is_none()
    );
}

#[test]
fn malformed_or_tampered_reserved_values_halt_before_survivor_is_returned() {
    let source = secure(1, "Losing seal", "hash-a", "kid");
    let winner = secure(2, "Winning seal", "hash-b", "kid");
    let valid = checked_merge(None, &source, &winner).survivor.unwrap();
    let key = secure_variants(&valid).unwrap()[0].extension_key.clone();
    for mutation in 0..11 {
        let mut bad = valid.clone();
        let Value::Object(object) = bad.extensions.get_mut(&key).unwrap() else {
            unreachable!()
        };
        match mutation {
            0 => {
                object.insert("extra".into(), Value::Bool(true));
            }
            1 => {
                object.insert("secure".into(), Value::Bool(false));
            }
            2 => {
                object.insert("version".into(), Value::Float(1.0));
            }
            3 => {
                object.insert(
                    "sourceID".into(),
                    Value::text(Uuid::from_u128(99).to_string()),
                );
            }
            4 => {
                object.insert("sourceHLC".into(), Value::text("invalid"));
            }
            5 => {
                object.insert("sourceOrigin".into(), Value::text("AAAAAAA1"));
            }
            6 => {
                object.insert(
                    "copyID".into(),
                    Value::text(Uuid::from_u128(100).to_string()),
                );
            }
            7 => {
                object.remove("x");
            }
            8 => {
                object.insert("fields".into(), Value::Null);
            }
            9 => {
                object.insert(
                    "copyID".into(),
                    Value::text(
                        secure_variants(&valid).unwrap()[0]
                            .copy_id
                            .to_string()
                            .to_uppercase(),
                    ),
                );
            }
            _ => {
                object.insert(
                    "x".into(),
                    Value::Object(BTreeMap::from([
                        ("vaultKID".into(), Value::text("kid")),
                        ("vaultContentHash".into(), Value::text("x".repeat(257))),
                    ])),
                );
            }
        }
        assert!(merge(None, Some(&bad), Some(&winner)) == Err(Failure::MalformedConflict));
    }
    for key in [
        "contentConflict.v1.bad",
        "contentConflict.v2.",
        "contentConflict.v1234.000",
        "contentConflict.vx.000",
        "contentConflict..000",
    ] {
        let mut bad = winner.clone();
        bad.extensions.insert(key.into(), Value::Null);
        assert!(validate(&bad).is_err());
    }
    let mut missing_legacy_hash = source.clone();
    missing_legacy_hash.extensions.remove("vaultContentHash");
    assert!(merge(None, Some(&missing_legacy_hash), Some(&winner)).is_err());
    let mut mismatched = winner.clone();
    mismatched.id = Uuid::from_u128(99);
    assert!(
        merge(Some(&source), Some(&winner), Some(&mismatched)) == Err(Failure::MismatchedIdentity)
    );
}

#[test]
fn unresolved_ancestor_blocks_tombstones_and_future_variants_remain_opaque() {
    let clean = record(1, "Body");
    let deletion = clean
        .tombstone(Hlc::foreign(100), "bbbbbbb2".into(), true)
        .unwrap();
    let mut base = clean.clone();
    base.extensions.insert(
        format!("contentConflict.v002.{}", "f".repeat(64)),
        Value::Int(2),
    );
    validate(&base).unwrap();
    assert!(has_unknown_version(&base));
    assert!(
        base.tombstone(Hlc::foreign(100), "bbbbbbb2".into(), true)
            .is_err()
    );
    assert!(
        merge(Some(&base), Some(&deletion), Some(&base))
            == Err(Failure::UnresolvedConflictDeletion)
    );
    assert!(
        merge(Some(&base), Some(&deletion), Some(&deletion))
            == Err(Failure::UnresolvedConflictDeletion)
    );
    let mut corrupt_tombstone = deletion.clone();
    corrupt_tombstone.extensions = base.extensions.clone();
    assert!(validate(&corrupt_tombstone) == Err(Failure::MalformedConflict));
    let edited = record(101, "Real edit preserved");
    assert!(checked_merge(Some(&base), &deletion, &edited).survivor == Some(edited));
}

#[test]
fn variant_count_aggregate_and_generated_wire_budget_fail_closed() {
    // Both peers' future metadata fit, but the union would exceed our decoder's
    // node budget. Never emit a record/checkpoint this client cannot reopen.
    let mut many_local = record(1, "Body");
    many_local
        .extensions
        .insert("futureLeft".into(), Value::Array(vec![Value::Null; 50_000]));
    let mut many_remote = record(2, "Body");
    many_remote.extensions.insert(
        "futureRight".into(),
        Value::Array(vec![Value::Null; 50_000]),
    );
    validate(&many_local).unwrap();
    validate(&many_remote).unwrap();
    assert!(merge(None, Some(&many_local), Some(&many_remote)).is_err());
    let mut crowded = record(1, "Body");
    for n in 0..MAX_VARIANTS {
        crowded
            .extensions
            .insert(format!("contentConflict.v2.{n:064x}"), Value::Null);
    }
    validate(&crowded).unwrap();
    crowded.extensions.insert(
        format!("contentConflict.v2.{:064x}", MAX_VARIANTS),
        Value::Null,
    );
    assert!(validate(&crowded).is_err());
    let mut big = record(1, "Body");
    big.extensions.insert(
        format!("contentConflict.v2.{}", "a".repeat(64)),
        Value::text("x".repeat(MAX_VARIANT_BYTES)),
    );
    assert!(big.encode().is_ok());
    assert!(validate(&big).is_err());
    let local = record(2, &"a".repeat(350_000));
    let remote = secure(1, &"b".repeat(350_000), "hash", "kid");
    validate(&local).unwrap();
    validate(&remote).unwrap();
    assert!(merge(None, Some(&local), Some(&remote)) == Err(Failure::MalformedConflict));
    // The losing ordinary input fits, but the generated copy's extra name and
    // provenance cannot. No oversized output may be applied or cursor advanced.
    let mut maximum_plain = record(1, "");
    let overhead = maximum_plain.encode().unwrap().len();
    fields(&mut maximum_plain).content =
        Zeroizing::new(vec![b'x'; crate::canonical::MAX_BYTES - overhead]);
    assert_eq!(
        maximum_plain.encode().unwrap().len(),
        crate::canonical::MAX_BYTES
    );
    assert!(merge(None, Some(&maximum_plain), Some(&record(2, "Winner"))).is_err());
}

#[test]
fn copy_provenance_is_not_durability_proof_for_an_arbitrary_identifier() {
    let source = record(1, "Source");
    let copy = plain_copy(&source).unwrap();
    assert!(valid_copy_identity(&copy));
    let mut impostor = copy.clone();
    impostor.id = Uuid::from_u128(100);
    assert!(!valid_copy_identity(&impostor));
    assert!(!matching_plain_copy(&impostor, &copy));
    let fingerprint = provenance(&copy).unwrap().fingerprint;
    assert!(matching_provenance(&copy, source.id, &fingerprint));
    for raw in [
        Value::Null,
        Value::Object(BTreeMap::from([
            ("version".into(), Value::Int(2)),
            ("sourceID".into(), Value::text(source.id.to_string())),
            ("fingerprint".into(), Value::text(&fingerprint)),
        ])),
    ] {
        impostor.extensions.insert(COPY_PROVENANCE.into(), raw);
        assert!(provenance(&impostor).is_none());
    }
}

#[test]
fn deletion_review_matches_exact_uppercase_uuid_fingerprint_and_changed_small_batch() {
    let reference: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/merge-v1.json")).unwrap();
    let ids: BTreeSet<_> = reference["deletionIDs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| Uuid::parse_str(v.as_str().unwrap()).unwrap())
        .collect();
    assert_eq!(
        deletion_fingerprint(&ids),
        reference["deletionFingerprint"].as_str().unwrap()
    );
    assert_eq!(allowed_deletions(0), 5);
    assert_eq!(allowed_deletions(25), 5);
    assert_eq!(allowed_deletions(26), 6);
    assert!(allowed_deletions(usize::MAX) > 5);
    let live: BTreeSet<_> = (0..30).map(Uuid::from_u128).collect();
    let keep: BTreeSet<_> = live.iter().copied().skip(6).collect();
    assert!(deletion_review(&live, &keep).is_none());
    let keep_less: BTreeSet<_> = live.iter().copied().skip(7).collect();
    assert_eq!(
        deletion_review(&live, &keep_less)
            .unwrap()
            .requested_deletions,
        7
    );
    let only_one: BTreeSet<_> = live.iter().copied().skip(1).collect();
    assert!(deletion_review(&live, &only_one).is_none());
    assert_eq!(
        deletion_facts(&live, &only_one)
            .unwrap()
            .requested_deletions,
        1
    );
    assert!(deletion_facts(&live, &live).is_none());
    assert!(
        deletion_facts(&live, &only_one).unwrap().batch_fingerprint
            != deletion_facts(&live, &keep_less).unwrap().batch_fingerprint
    );
}

#[test]
fn metadata_uses_canonical_equivalence_while_body_bytes_still_preserve_a_conflict() {
    let mut base = record(1, "Original");
    fields(&mut base).name = "Café".into();
    let mut local = base.clone();
    local.hlc = Hlc::foreign(100);
    fields(&mut local).name = "Cafe\u{301}".into();
    let mut remote = record(2, "Changed");
    fields(&mut remote).name = "Renamed".into();
    let result = checked_merge(Some(&base), &local, &remote)
        .survivor
        .unwrap();
    assert_eq!(result.fields.unwrap().name, "Renamed");
    let a = record(1, "Café");
    let b = record(2, "Cafe\u{301}");
    assert_eq!(checked_merge(None, &a, &b).conflict_copies.len(), 1);
}

#[test]
fn finite_ordinary_edit_matrix_never_loses_a_body_and_is_commutative() {
    let base = record(1, "Ancestor");
    for local_body in ["Ancestor", "L", "R", ""] {
        for remote_body in ["Ancestor", "L", "R", ""] {
            for wall in [2, 3] {
                let mut local = record(wall, local_body);
                fields(&mut local).name = "Local name".into();
                let mut remote = record(2, remote_body);
                fields(&mut remote).keyword = "remote-keyword".into();
                let result = checked_merge(Some(&base), &local, &remote);
                let bodies: Vec<_> = result
                    .survivor
                    .iter()
                    .chain(&result.conflict_copies)
                    .map(|e| e.fields.as_ref().unwrap().content.as_slice())
                    .collect();
                if local_body != "Ancestor" {
                    assert!(bodies.contains(&local_body.as_bytes()));
                }
                if remote_body != "Ancestor" {
                    assert!(bodies.contains(&remote_body.as_bytes()));
                }
                assert_eq!(
                    result
                        .survivor
                        .as_ref()
                        .unwrap()
                        .fields
                        .as_ref()
                        .unwrap()
                        .name,
                    "Local name"
                );
                assert_eq!(
                    result
                        .survivor
                        .as_ref()
                        .unwrap()
                        .fields
                        .as_ref()
                        .unwrap()
                        .keyword,
                    "remote-keyword"
                );
            }
        }
    }
}

#[test]
fn canonical_conflict_copies_match_the_cross_client_vectors() {
    // Shared with Apple (SyncConflictCopyVectorTests) and Android
    // (AndroidConflictCopyTests): one losing envelope, one copy, on every client.
    let reference: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/conflict-copy-v1.json")).unwrap();
    for vector in reference["vectors"].as_array().unwrap() {
        let source = Envelope::parse(vector["source"].as_str().unwrap().as_bytes()).unwrap();
        let expected = Envelope::parse(vector["copy"].as_str().unwrap().as_bytes()).unwrap();
        let copy = plain_copy(&source).unwrap();
        assert!(*copy.encode().unwrap() == *expected.encode().unwrap());
        assert_eq!(copy.id.to_string(), vector["copyID"].as_str().unwrap());
        assert_eq!(
            provenance(&copy).unwrap().fingerprint,
            vector["fingerprint"].as_str().unwrap()
        );
        assert!(
            valid_copy_identity(&copy)
                && copy_id(source.id, &provenance(&copy).unwrap().fingerprint) == copy.id
        );
        let f = copy.fields.as_ref().unwrap();
        assert!(!f.is_enabled && !f.is_pinned && f.keyword.is_empty());
        assert!(f.content == source.fields.as_ref().unwrap().content);
    }
}
