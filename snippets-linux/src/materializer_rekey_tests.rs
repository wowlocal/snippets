//! Two independent fictional vaults; no filesystem, transport or native keys.
use super::*;
use crate::clock::Hlc;

fn document() -> Document {
    let value: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    Document::decode(&serde_json::to_vec(&value["document"]).unwrap()).unwrap()
}
fn source(document: &Document) -> Envelope {
    super::super::tests::source(document, "Public rekey fixture")
}
fn target(document: &Document) -> Document {
    let mut target = document.clone();
    target.kid = "Public different vault".into();
    target.vault_salt = crypto::b64(&[0x55; 32]);
    target.records.clear();
    target
}

#[test]
fn rekey_changes_carrier_copy_and_aad_together_while_original_and_edited_bodies_stay_distinct() {
    let old = document();
    let new = target(&old);
    let old_root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let new_root = RootKey::from_bytes(&[0x44; 32]).unwrap();
    let old_keys = Keyring::new(&old_root, &old).unwrap();
    let new_keys = Keyring::new(&new_root, &new).unwrap();
    let source = source(&old);
    let c0 = Evidence::prepare(std::slice::from_ref(&source), &old_keys, &BTreeMap::new())
        .unwrap()
        .copies
        .values()
        .next()
        .unwrap()
        .clone();
    let mut c1 = c0.clone();
    c1.hlc = Hlc::foreign(25);
    let edited = b"Public independently edited secure C1";
    c1.fields.as_mut().unwrap().content = Zeroizing::new(
        crypto::seal_record(
            edited,
            &old_root,
            &old_keys.salt,
            old_keys.kid(),
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
        Value::text(crypto::content_hash(edited, &old_root, &old_keys.salt)),
    );
    let rekey = Rekey::prepare(&[&source, &c0, &c1], &old_keys, &new_keys).unwrap();
    let translated_source = rekey.record(&source).unwrap();
    let translated_c0 = rekey.record(&c0).unwrap();
    let translated_c1 = rekey.record(&c1).unwrap();
    assert!(translated_source.id == source.id && translated_c0.id != c0.id);
    assert!(translated_c0.id == translated_c1.id && merge::valid_copy_identity(&translated_c1));
    let variant = merge::secure_variants(&translated_source)
        .unwrap()
        .remove(0);
    validate_evidence(&translated_c0, &variant, &new_keys).unwrap();
    assert!(validate_evidence(&translated_c1, &variant, &new_keys).is_err());
    assert!(
        new_keys
            .open(
                &translated_c1.fields.as_ref().unwrap().content,
                translated_c1.id
            )
            .unwrap()
            .as_slice()
            == edited
    );
    assert!(
        old_keys
            .open(
                &translated_c1.fields.as_ref().unwrap().content,
                translated_c1.id
            )
            .is_err()
    );
    assert!(
        new_keys
            .open(&translated_c1.fields.as_ref().unwrap().content, c1.id)
            .is_err()
    );
    assert!(rekey.record(&c0).unwrap() == translated_c0);
}

#[test]
fn separately_frozen_original_nonces_remain_separate_and_repeatable_in_the_new_vault() {
    let old = document();
    let new = target(&old);
    let a = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let b = RootKey::from_bytes(&[0x44; 32]).unwrap();
    let old_keys = Keyring::new(&a, &old).unwrap();
    let new_keys = Keyring::new(&b, &new).unwrap();
    let source = source(&old);
    let first = Evidence::prepare(std::slice::from_ref(&source), &old_keys, &BTreeMap::new())
        .unwrap()
        .copies
        .values()
        .next()
        .unwrap()
        .clone();
    let second = Evidence::prepare(std::slice::from_ref(&source), &old_keys, &BTreeMap::new())
        .unwrap()
        .copies
        .values()
        .next()
        .unwrap()
        .clone();
    assert!(first != second);
    let result = Rekey::prepare(&[&source, &first, &second, &first], &old_keys, &new_keys).unwrap();
    let converted = result.record(&source).unwrap();
    let variant = merge::secure_variants(&converted).unwrap().remove(0);
    let first = result.record(&first).unwrap();
    let second = result.record(&second).unwrap();
    assert!(first != second && first.id == second.id);
    validate_evidence(&first, &variant, &new_keys).unwrap();
    validate_evidence(&second, &variant, &new_keys).unwrap();
}

#[test]
fn damaged_own_body_or_carrier_unknown_versions_and_conflicting_roles_refuse_the_whole_translation()
{
    let old = document();
    let new = target(&old);
    let a = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let b = RootKey::from_bytes(&[0x44; 32]).unwrap();
    let old_keys = Keyring::new(&a, &old).unwrap();
    let new_keys = Keyring::new(&b, &new).unwrap();
    let source = source(&old);
    let copy = Evidence::prepare(std::slice::from_ref(&source), &old_keys, &BTreeMap::new())
        .unwrap()
        .copies
        .values()
        .next()
        .unwrap()
        .clone();
    for kind in 0..4 {
        let mut wrong = copy.clone();
        let mut source = source.clone();
        match kind {
            0 => {
                wrong.extensions.insert(
                    "vaultContentHash".into(),
                    Value::text("00000000000000000000000000000000"),
                );
            }
            1 => {
                source.extensions.insert(
                    format!("contentConflict.v9.{}", "a".repeat(64)),
                    Value::Bool(true),
                );
            }
            2 => {
                wrong.extensions.remove(merge::COPY_PROVENANCE);
            }
            _ => {
                let key = merge::secure_variants(&source).unwrap()[0]
                    .extension_key
                    .clone();
                source.extensions.insert(key, Value::Bool(true));
            }
        }
        assert!(Rekey::prepare(&[&source, &wrong], &old_keys, &new_keys).is_err());
    }
}
