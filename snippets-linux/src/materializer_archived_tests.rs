//! Independent public body vectors and complete canonical v1 carriers.
use super::*;
use crate::clock::Hlc;

#[path = "materializer_multiple_tests.rs"]
mod multiple;

fn document() -> Document {
    let value: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    Document::decode(&serde_json::to_vec(&value["document"]).unwrap()).unwrap()
}
fn own(document: &Document) -> Envelope {
    let record = &document.records[0];
    let mut fields = Fields::from_snippet(&record.metadata.shell());
    fields.content = Zeroizing::new(record.sealed.text().as_bytes().to_vec());
    Envelope {
        id: record.metadata.id,
        hlc: Hlc::foreign(10),
        origin: "11111111".into(),
        secure: true,
        deleted: false,
        fields: Some(fields),
        extensions: BTreeMap::from([
            ("vaultKID".into(), Value::text(&document.kid)),
            ("vaultContentHash".into(), Value::text(&record.content_hash)),
        ]),
    }
}
fn omit(envelope: &mut Envelope, mask: u8) {
    if mask & 1 != 0 {
        envelope.extensions.remove("vaultKID");
    }
    if mask & 2 != 0 {
        envelope.extensions.remove("vaultContentHash");
    }
}
fn carrier(document: &Document) -> Envelope {
    super::super::tests::source(document, "Public archived source")
}

#[test]
fn archived_own_metadata_is_repairable_only_after_authenticating_explicit_old_aad() {
    let doc = document();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = Keyring::new(&root, &doc).unwrap();
    let original = own(&doc);
    for mask in 1..=3 {
        let mut missing = original.clone();
        omit(&mut missing, mask);
        let before = missing.hash().unwrap();
        assert!(authenticate(&missing, &keys, true).is_err());
        assert!(
            Archived::new(&keys).body(&missing).unwrap().as_slice()
                == "Fictional secret 🦀\n".as_bytes()
        );
        assert_eq!(missing.hash().unwrap(), before);
    }
    for bad in 0..8 {
        let mut value = original.clone();
        match bad {
            0 => {
                value
                    .extensions
                    .insert("vaultKID".into(), Value::text("Public wrong vault"));
            }
            1 => {
                value.extensions.insert("vaultKID".into(), Value::text(""));
            }
            2 => {
                value
                    .extensions
                    .insert("vaultKID".into(), Value::Bool(true));
            }
            3 => {
                value.extensions.insert(
                    "vaultContentHash".into(),
                    Value::text("00000000000000000000000000000000"),
                );
            }
            4 => {
                value
                    .extensions
                    .insert("vaultContentHash".into(), Value::text(""));
            }
            5 => {
                value
                    .extensions
                    .insert("vaultContentHash".into(), Value::Bool(true));
            }
            6 => {
                omit(&mut value, 3);
                value.id = Uuid::from_u128(990);
            }
            _ => {
                omit(&mut value, 3);
                value.fields.as_mut().unwrap().content =
                    Zeroizing::new(b"Public invalid seal".to_vec());
            }
        }
        assert!(Archived::new(&keys).body(&value).is_err(), "Refusal {bad}");
    }
    let wrong = RootKey::from_bytes(&[0x44; 32]).unwrap();
    let wrong = Keyring::new(&wrong, &doc).unwrap();
    let mut missing = original;
    omit(&mut missing, 3);
    assert!(Archived::new(&wrong).body(&missing).is_err());
}

#[test]
fn archived_originals_without_metadata_still_require_actual_c0_body_and_exact_role() {
    let doc = document();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = Keyring::new(&root, &doc).unwrap();
    let source = carrier(&doc);
    let first = Evidence::prepare(std::slice::from_ref(&source), &keys, &BTreeMap::new()).unwrap();
    let original = first.copies.values().next().unwrap();
    for mask in 1..=3 {
        let mut c0 = original.clone();
        omit(&mut c0, mask);
        let frozen = BTreeMap::from([(c0.id, c0.clone())]);
        assert!(Evidence::prepare(std::slice::from_ref(&source), &keys, &frozen).is_err());
        assert!(
            Archived::new(&keys)
                .evidence(std::slice::from_ref(&source), &frozen)
                .unwrap()
                .copies[&c0.id]
                == c0
        );
        let mut c1 = c0.clone();
        c1.fields.as_mut().unwrap().content = Zeroizing::new(
            crypto::seal_record(
                b"Public edited C1 cannot impersonate C0",
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
        assert!(
            Archived::new(&keys)
                .evidence(
                    std::slice::from_ref(&source),
                    &BTreeMap::from([(c1.id, c1)])
                )
                .is_err()
        );
        c0.fields.as_mut().unwrap().name = "Public wrong original metadata".into();
        assert!(
            Archived::new(&keys)
                .evidence(
                    std::slice::from_ref(&source),
                    &BTreeMap::from([(c0.id, c0)])
                )
                .is_err()
        );
    }
}

#[test]
fn archived_rekey_fills_current_metadata_preserves_nonces_and_keeps_edited_c1_distinct() {
    let old = document();
    let a = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let mut new = old.clone();
    new.kid = "Public new vault".into();
    new.vault_salt = crypto::b64(&[0x55; 32]);
    new.records.clear();
    let b = RootKey::from_bytes(&[0x44; 32]).unwrap();
    let old_keys = Keyring::new(&a, &old).unwrap();
    let new_keys = Keyring::new(&b, &new).unwrap();
    let source = carrier(&old);
    let mut first = Evidence::prepare(std::slice::from_ref(&source), &old_keys, &BTreeMap::new())
        .unwrap()
        .copies
        .values()
        .next()
        .unwrap()
        .clone();
    let mut second = Evidence::prepare(std::slice::from_ref(&source), &old_keys, &BTreeMap::new())
        .unwrap()
        .copies
        .values()
        .next()
        .unwrap()
        .clone();
    omit(&mut first, 3);
    omit(&mut second, 3);
    let mut selected = first.clone();
    selected.hlc = Hlc::foreign(30);
    let body = b"Public selected archived C1 body";
    selected.fields.as_mut().unwrap().content = Zeroizing::new(
        crypto::seal_record(body, &a, &old_keys.salt, old_keys.kid(), selected.id, false)
            .unwrap()
            .text()
            .as_bytes()
            .to_vec(),
    );
    assert!(Rekey::prepare(&[&source, &first, &second, &selected], &old_keys, &new_keys).is_err());
    let map = Rekey::prepare_archived(
        &[&source, &first, &second, &selected, &first],
        &old_keys,
        &new_keys,
    )
    .unwrap();
    let translated = map.record(&source).unwrap();
    let variant = merge::secure_variants(&translated).unwrap().remove(0);
    let a = map.record(&first).unwrap();
    let b = map.record(&second).unwrap();
    let c = map.record(&selected).unwrap();
    assert!(a != b && a.id == b.id && a.id == c.id);
    assert!(map.record(&first).unwrap() == a);
    validate_evidence(&a, &variant, &new_keys).unwrap();
    validate_evidence(&b, &variant, &new_keys).unwrap();
    assert!(validate_evidence(&c, &variant, &new_keys).is_err());
    assert!(
        new_keys
            .open(&c.fields.as_ref().unwrap().content, c.id)
            .unwrap()
            .as_slice()
            == body
    );
    assert!(
        old_keys
            .open(&c.fields.as_ref().unwrap().content, c.id)
            .is_err()
    );
}

#[test]
fn archived_repair_does_not_rewrite_malformed_or_incomplete_v1_carriers() {
    let doc = document();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let keys = Keyring::new(&root, &doc).unwrap();
    for missing in ["vaultKID", "vaultContentHash"] {
        let mut value = carrier(&doc);
        let variant = merge::secure_variants(&value).unwrap().remove(0);
        let Value::Object(mut snapshot) = value.extensions.remove(&variant.extension_key).unwrap()
        else {
            unreachable!()
        };
        let Value::Object(x) = snapshot.get_mut("x").unwrap() else {
            unreachable!()
        };
        x.remove(missing);
        snapshot.remove("copyID");
        let fingerprint = crate::wire::sha256(&Value::Object(snapshot.clone()).encode().unwrap());
        snapshot.insert(
            "copyID".into(),
            Value::text(merge::copy_id(value.id, &fingerprint).to_string()),
        );
        value.extensions.insert(
            format!("{}{}", merge::CONFLICT_V1_PREFIX, fingerprint),
            Value::Object(snapshot),
        );
        assert!(
            Archived::new(&keys)
                .evidence(&[value], &BTreeMap::new())
                .is_err()
        );
    }
}
