//! All key material, text and identities are public fictional fixtures.
use super::*;
use crate::clock::Hlc;
fn document() -> Document {
    let value: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    Document::decode(&serde_json::to_vec(&value["document"]).unwrap()).unwrap()
}
fn key() -> RootKey {
    RootKey::from_bytes(&[0x11; 32]).unwrap()
}
pub(super) fn source(document: &Document, name: &str) -> Envelope {
    let record = &document.records[0];
    let mut fields = Fields::from_snippet(&record.metadata.shell());
    fields.name = name.into();
    fields.created_at = 0.0;
    fields.updated_at = 120.125;
    fields.content = Zeroizing::new(record.sealed.text().as_bytes().to_vec());
    let secure = Envelope {
        id: record.metadata.id,
        hlc: Hlc::foreign(10),
        origin: "11111111".into(),
        secure: true,
        deleted: false,
        fields: Some(fields.clone()),
        extensions: BTreeMap::from([
            ("vaultKID".into(), Value::text(&document.kid)),
            ("vaultContentHash".into(), Value::text(&record.content_hash)),
        ]),
    };
    fields.content = Zeroizing::new(b"Public plain winner".to_vec());
    let winner = Envelope {
        secure: false,
        hlc: Hlc::foreign(20),
        fields: Some(fields),
        extensions: BTreeMap::new(),
        ..secure.clone()
    };
    merge::merge(None, Some(&secure), Some(&winner))
        .unwrap()
        .survivor
        .unwrap()
}
fn evidence(source: &Envelope, keys: &Keyring<'_>) -> Evidence {
    Evidence::prepare(std::slice::from_ref(source), keys, &BTreeMap::new()).unwrap()
}
#[test]
fn opens_independent_openssl_source_and_reseals_for_copy_uuid_only() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    let source = source(&document, "Public name");
    let result = materialize(&source, &keys, &[], &document.records, &BTreeMap::new()).unwrap();
    let variant = merge::secure_variants(&source).unwrap().remove(0);
    let copy = &result.evidence.copies()[&variant.copy_id];
    assert!(result.materialized_ids == BTreeSet::from([variant.copy_id]));
    assert!(merge::has_unresolved(Some(&source)));
    let record = result
        .records
        .iter()
        .find(|r| r.metadata.id == copy.id)
        .unwrap();
    let body = crypto::open_record(
        &record.sealed,
        &root,
        &keys.salt,
        keys.kid(),
        copy.id,
        false,
    )
    .unwrap();
    let original = keys
        .open(&variant.fields.content, variant.source_id)
        .unwrap();
    assert!(body == original);
    assert!(
        crypto::open_record(
            &record.sealed,
            &root,
            &keys.salt,
            keys.kid(),
            variant.source_id,
            false
        )
        .is_err()
    );
    assert_eq!(
        record.metadata.name,
        "Public name (conflict 2001-01-01 00:02 UTC)"
    );
    assert!(
        record.metadata.keyword.is_empty()
            && !record.metadata.is_enabled
            && !record.metadata.is_pinned
    );
    assert_eq!(record.extra.len(), 1);
    assert!(record.extra.contains_key(merge::COPY_PROVENANCE));
    validate_evidence(copy, &variant, &keys).unwrap();
    result
        .evidence
        .validate(std::slice::from_ref(&source), &keys)
        .unwrap();
}
#[test]
fn empty_secure_names_never_use_plaintext_preview_and_whitespace_is_preserved() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    for (name, expected) in [("", "Untitled"), ("   ", "   ")] {
        let source = source(&document, name);
        let proof = evidence(&source, &keys);
        assert!(
            proof
                .copies
                .values()
                .next()
                .unwrap()
                .fields
                .as_ref()
                .unwrap()
                .name
                .starts_with(&format!("{expected} (conflict"))
        );
    }
}
#[test]
fn independent_random_seals_are_valid_c0_but_frozen_journal_bytes_win() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    let source = source(&document, "Public name");
    let first = evidence(&source, &keys);
    let second = evidence(&source, &keys);
    assert!(first != second);
    let repeated = Evidence::prepare(std::slice::from_ref(&source), &keys, first.copies()).unwrap();
    assert!(repeated == first);
    let variant = merge::secure_variants(&source).unwrap().remove(0);
    validate_evidence(second.copies.values().next().unwrap(), &variant, &keys).unwrap();
}
#[test]
fn authenticated_c1_is_preserved_but_cannot_replace_exact_c0_evidence() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    let source = source(&document, "Public name");
    let proof = evidence(&source, &keys);
    let variant = merge::secure_variants(&source).unwrap().remove(0);
    let c0 = proof.copies.values().next().unwrap();
    let mut c1 = c0.clone();
    c1.fields.as_mut().unwrap().name = "Public user rename".into();
    c1.fields.as_mut().unwrap().content = Zeroizing::new(
        crypto::seal_record(
            b"Public later edit",
            &root,
            &keys.salt,
            keys.kid(),
            c1.id,
            false,
        )
        .unwrap()
        .text()
        .as_bytes()
        .to_vec(),
    );
    c1.extensions.insert(
        "vaultContentHash".into(),
        Value::text(crypto::content_hash(
            b"Public later edit",
            &root,
            &keys.salt,
        )),
    );
    authenticate(&c1, &keys, true).unwrap();
    assert!(matches!(
        validate_evidence(&c1, &variant, &keys),
        Err(Failure::MalformedVariant)
    ));
    let record = crate::projection::vault_record(&c1, None, keys.kid())
        .unwrap()
        .unwrap();
    let result = materialize(
        &source,
        &keys,
        &[],
        std::slice::from_ref(&record),
        proof.copies(),
    )
    .unwrap();
    assert!(result.records == vec![record] && result.materialized_ids.is_empty());
    assert!(result.evidence == proof);
    assert!(matches!(
        Evidence::prepare(
            std::slice::from_ref(&source),
            &keys,
            &BTreeMap::from([(c1.id, c1)])
        ),
        Err(Failure::MalformedVariant)
    ));
}
#[test]
fn prepared_evidence_rejects_every_later_or_extended_derived_generation() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    let source = source(&document, "Public name");
    let proof = evidence(&source, &keys);
    let variant = merge::secure_variants(&source).unwrap().remove(0);
    let copy = proof.copies.values().next().unwrap();
    for index in 0..10 {
        let mut candidate = copy.clone();
        let fields = candidate.fields.as_mut().unwrap();
        match index {
            0 => candidate.hlc = Hlc::foreign(100),
            1 => candidate.origin = "22222222".into(),
            2 => fields.keyword = "later".into(),
            3 => fields.tags.push("later".into()),
            4 => fields.created_at = 1.0,
            5 => fields.updated_at = 121.0,
            6 => fields.is_enabled = true,
            7 => fields.is_pinned = true,
            8 => {
                candidate
                    .extensions
                    .insert("future".into(), Value::Bool(true));
            }
            _ => {
                candidate.extensions.insert(
                    merge::COPY_PROVENANCE.into(),
                    merge::provenance_value(Uuid::from_u128(9), &variant.fingerprint),
                );
            }
        }
        authenticate(&candidate, &keys, true).unwrap();
        assert!(matches!(
            validate_evidence(&candidate, &variant, &keys),
            Err(Failure::MalformedVariant)
        ));
    }
}
#[test]
fn malformed_ciphertext_hash_and_foreign_key_or_salt_refuse_the_whole_result() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    let source = source(&document, "Public name");
    let proof = evidence(&source, &keys);
    let copy = proof.copies.values().next().unwrap();
    let mut damaged = copy.clone();
    damaged.fields.as_mut().unwrap().content = Zeroizing::new(b"v1.invalid.invalid".to_vec());
    assert!(matches!(
        authenticate(&damaged, &keys, true),
        Err(Failure::MalformedVariant)
    ));
    let mut wrong_hash = copy.clone();
    wrong_hash
        .extensions
        .insert("vaultContentHash".into(), Value::text("00".repeat(16)));
    assert!(matches!(
        authenticate(&wrong_hash, &keys, true),
        Err(Failure::ContentHashMismatch)
    ));
    let mut foreign = copy.clone();
    foreign
        .extensions
        .insert("vaultKID".into(), Value::text("foreign"));
    assert!(matches!(
        authenticate(&foreign, &keys, true),
        Err(Failure::IncompatibleVault)
    ));
    let wrong_key = RootKey::from_bytes(&[0x77; 32]).unwrap();
    assert!(authenticate(copy, &Keyring::new(&wrong_key, &document).unwrap(), true).is_err());
    let mut changed = document.clone();
    changed.vault_salt = crypto::b64(&[0x78; 32]);
    assert!(!keys.matches(&changed));
    assert!(authenticate(copy, &Keyring::new(&root, &changed).unwrap(), true).is_err());
}
#[test]
fn collisions_duplicate_records_and_corrupted_matching_occupants_are_not_overwritten() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    let source = source(&document, "Public name");
    let proof = evidence(&source, &keys);
    let copy = proof.copies.values().next().unwrap();
    let record = crate::projection::vault_record(copy, None, keys.kid())
        .unwrap()
        .unwrap();
    let mut plain = Snippet::new("Public collision", "Public text");
    plain.id = copy.id;
    assert!(matches!(
        materialize(&source, &keys, &[plain], &[], proof.copies()),
        Err(Failure::IdentifierCollision)
    ));
    assert!(matches!(
        materialize(
            &source,
            &keys,
            &[],
            &[record.clone(), record.clone()],
            proof.copies()
        ),
        Err(Failure::IdentifierCollision)
    ));
    let mut unrelated = record.clone();
    unrelated.extra.remove(merge::COPY_PROVENANCE);
    assert!(matches!(
        materialize(&source, &keys, &[], &[unrelated], proof.copies()),
        Err(Failure::IdentifierCollision)
    ));
    let mut corrupted = record;
    corrupted.content_hash = "00".repeat(16);
    assert!(matches!(
        materialize(&source, &keys, &[], &[corrupted], proof.copies()),
        Err(Failure::ContentHashMismatch)
    ));
}
#[test]
fn complete_proof_set_is_unique_and_unknown_versions_remain_opaque() {
    let document = document();
    let root = key();
    let keys = Keyring::new(&root, &document).unwrap();
    let source = source(&document, "Public name");
    let proof = evidence(&source, &keys);
    assert!(matches!(
        Evidence::prepare(&[source.clone(), source.clone()], &keys, &BTreeMap::new()),
        Err(Failure::IdentifierCollision)
    ));
    assert!(proof.validate(&[], &keys).is_err());
    assert!(
        Evidence {
            copies: BTreeMap::new()
        }
        .validate(std::slice::from_ref(&source), &keys)
        .is_err()
    );
    let mut future = source.clone();
    future
        .extensions
        .retain(|key, _| !key.starts_with(merge::CONFLICT_PREFIX));
    future.extensions.insert(
        format!("contentConflict.v2.{}", "ab".repeat(32)),
        Value::Int(9),
    );
    let result = materialize(&future, &keys, &[], &document.records, &BTreeMap::new()).unwrap();
    assert!(result.records == document.records && result.evidence.copies.is_empty());
    assert!(merge::has_unresolved(Some(&future)));
}
