//! Independent public seals across two authenticated source scopes and one target.
use super::*;

fn second(document: &Document) -> Document {
    let mut value = document.clone();
    // Deliberately the same stamp: body/AAD ownership also needs salt and root.
    value.vault_salt = crypto::b64(&[0x77; 32]);
    value.records.clear();
    value
}
fn reseal(source: &Envelope, keys: &Keyring<'_>, body: &[u8]) -> Envelope {
    let mut value = source.clone();
    value.secure = true;
    value.fields.as_mut().unwrap().content = Zeroizing::new(
        crypto::seal_record(body, keys.key, &keys.salt, keys.kid(), value.id, false)
            .unwrap()
            .text()
            .as_bytes()
            .to_vec(),
    );
    value
        .extensions
        .insert("vaultKID".into(), Value::text(keys.kid()));
    value.extensions.insert(
        "vaultContentHash".into(),
        Value::text(crypto::content_hash(body, keys.key, &keys.salt)),
    );
    value
}
#[test]
fn mixed_raw_originals_and_selected_bodies_translate_as_one_authenticated_graph() {
    let doc = document();
    let other = second(&doc);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let alternate = RootKey::from_bytes(&[0x66; 32]).unwrap();
    let a = Keyring::new(&root, &doc).unwrap();
    let b = Keyring::new(&alternate, &other).unwrap();
    let mut target = other.clone();
    target.kid = "Public third vault".into();
    target.vault_salt = crypto::b64(&[0x99; 32]);
    let final_root = RootKey::from_bytes(&[0x88; 32]).unwrap();
    let current = Keyring::new(&final_root, &target).unwrap();
    let source = reseal(&carrier(&doc), &b, b"Public B source with A raw loser");
    let original = Evidence::prepare(std::slice::from_ref(&source), &a, &BTreeMap::new())
        .unwrap()
        .copies
        .into_values()
        .next()
        .unwrap();
    let mut selected = reseal(&original, &b, b"Public B selected child");
    selected.hlc = Hlc::foreign(30);
    let mut loser = reseal(&original, &a, b"Public A nested original");
    loser.hlc = Hlc::foreign(20);
    let (field, raw) = merge::secure_variant(&loser).unwrap();
    selected.extensions.insert(field, raw);
    let parents = vec![source.clone(), selected.clone()];
    let keys = [&a, &b];
    let proof = ArchivedKeys::new(&keys)
        .unwrap()
        .evidence(&parents, &BTreeMap::from([(original.id, original.clone())]))
        .unwrap();
    assert!(proof.copies[&original.id] == original);
    let nested = proof.copies.values().find(|e| e.id != original.id).unwrap();
    let records = [&source, &original, &selected, nested];
    for missing in [&a, &b] {
        assert!(Rekey::prepare_archived(&records, missing, &current).is_err());
    }
    let translated = Rekey::prepare_archived_many(&records, &keys, &current).unwrap();
    let new_source = translated.record(&source).unwrap();
    let new_original = translated.record(&original).unwrap();
    let new_selected = translated.record(&selected).unwrap();
    let new_nested = translated.record(nested).unwrap();
    assert!(new_original.id != original.id && new_original.id == new_selected.id);
    validate_evidence(
        &new_original,
        &merge::secure_variants(&new_source).unwrap()[0],
        &current,
    )
    .unwrap();
    validate_evidence(
        &new_nested,
        &merge::secure_variants(&new_selected).unwrap()[0],
        &current,
    )
    .unwrap();
    assert!(
        current
            .open(
                &new_selected.fields.as_ref().unwrap().content,
                new_selected.id
            )
            .unwrap()
            .as_slice()
            == b"Public B selected child"
    );
    assert!(
        ArchivedKeys::new(&[&a, &a, &b])
            .unwrap()
            .body(&original)
            .is_err()
    );
    for mut damaged in [source.clone(), selected.clone()] {
        damaged
            .extensions
            .insert("vaultContentHash".into(), Value::text("00".repeat(32)));
        assert!(
            Rekey::prepare_archived_many(&[&damaged, &original, nested], &keys, &current).is_err()
        );
    }
}
#[test]
fn cross_scope_frozen_c0_requires_exact_original_body_even_without_own_metadata() {
    let doc = document();
    let other = second(&doc);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let alternate = RootKey::from_bytes(&[0x66; 32]).unwrap();
    let a = Keyring::new(&root, &doc).unwrap();
    let b = Keyring::new(&alternate, &other).unwrap();
    let source = carrier(&doc);
    let original = Evidence::prepare(std::slice::from_ref(&source), &a, &BTreeMap::new())
        .unwrap()
        .copies
        .into_values()
        .next()
        .unwrap();
    let original_body = a
        .open(&original.fields.as_ref().unwrap().content, original.id)
        .unwrap();
    let mut cross = reseal(&original, &b, &original_body);
    for mask in 0..=3 {
        let mut copy = cross.clone();
        omit(&mut copy, mask);
        let keys = [&a, &b];
        assert!(
            ArchivedKeys::new(&keys)
                .unwrap()
                .evidence(
                    std::slice::from_ref(&source),
                    &BTreeMap::from([(copy.id, copy.clone())])
                )
                .unwrap()
                .copies[&copy.id]
                == copy
        );
    }
    cross = reseal(&cross, &b, b"Public edited body pretending to be C0");
    omit(&mut cross, 3);
    assert!(
        ArchivedKeys::new(&[&a, &b])
            .unwrap()
            .evidence(
                std::slice::from_ref(&source),
                &BTreeMap::from([(cross.id, cross)])
            )
            .is_err()
    );
    let missing = own(&doc);
    let mut missing_stamp = missing.clone();
    omit(&mut missing_stamp, 3);
    assert!(
        ArchivedKeys::new(&[&a, &b])
            .unwrap()
            .body(&missing_stamp)
            .unwrap()
            .0
            == 0
    );
    assert!(
        ArchivedKeys::new(&[&b])
            .unwrap()
            .body(&missing_stamp)
            .is_err()
    );
}
