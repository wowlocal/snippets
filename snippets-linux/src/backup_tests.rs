//! Public independently generated vectors; no host data, network or keyring.
use super::*;
use crate::crypto;
pub(super) fn document() -> Document {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    document.extra.insert(
        "local.syncConflictC0Receipts.v1".into(),
        serde_json::json!({"public-receipt":true}),
    );
    document.extra.insert(
        "futurePublicBackupField".into(),
        serde_json::json!({"enabled":true}),
    );
    document
}
pub(super) fn plain() -> Snippet {
    let mut plain = Snippet::new("Public backup name", "Public ordinary backup body 🦀");
    plain.id = uuid::Uuid::from_u128(2);
    plain.keyword = "public-backup".into();
    plain.created_at = 123.25;
    plain.updated_at = 456.5;
    plain
}
#[test]
fn opens_independent_openssl_backup_with_nfc_password_and_preserved_future_fields() {
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/backup-v1.json")).unwrap();
    let bytes = serde_json::to_vec(&fixture["container"]).unwrap();
    let opened = open(&bytes, "Cafe\u{301} public backup fixture").unwrap();
    assert!(is_backup(&bytes));
    assert_eq!(opened.counts(), (1, 1));
    let expected = Snippet::decode(fixture["ordinary"].clone()).unwrap();
    assert!(opened.snippets == vec![expected]);
    let vault = opened.vault.as_ref().unwrap();
    assert!(
        !vault
            .extra
            .keys()
            .any(|k| k.starts_with("local.syncConflictC0Receipts."))
    );
    assert!(vault.extra["futurePublicBackupField"] == serde_json::json!({"enabled":true}));
    assert!(
        crypto::open_record(
            &vault.records[0].sealed,
            opened.vault_key.as_ref().unwrap(),
            &vault.salt().unwrap(),
            &vault.kid,
            vault.records[0].metadata.id,
            false
        )
        .unwrap()
        .as_slice()
            == "Fictional secret 🦀\n".as_bytes()
    );
}
#[test]
fn round_trip_seals_metadata_and_bodies_with_independent_random_keys_and_nonces() {
    let document = document();
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let plain = plain();
    let first = seal_inner(
        std::slice::from_ref(&plain),
        Some((&document, &key)),
        "Public backup passphrase",
        2000,
    )
    .unwrap();
    let second = seal_inner(
        std::slice::from_ref(&plain),
        Some((&document, &key)),
        "Public backup passphrase",
        2000,
    )
    .unwrap();
    assert!(first != second);
    for text in [
        &plain.name,
        &plain.keyword,
        &plain.content,
        &document.records[0].metadata.name,
        &document.records[0].metadata.keyword,
        &document.kid,
    ] {
        assert!(!String::from_utf8_lossy(&first).contains(text));
    }
    assert!(!String::from_utf8_lossy(&first).contains("Public backup passphrase"));
    let opened = open(&first, "Public backup passphrase").unwrap();
    assert!(opened.snippets == vec![plain]);
    assert!(opened.vault.as_ref().unwrap() == &portable(&document));
}
#[test]
fn changed_header_ciphertext_or_password_never_returns_partial_data() {
    let data = seal_inner(&[plain()], None, "Public backup passphrase", 2000).unwrap();
    assert!(open(&data, "Wrong public password").is_err());
    for field in [
        "format",
        "schemaVersion",
        "backupID",
        "alg",
        "iterations",
        "salt",
        "envelope",
        "payload",
    ] {
        let mut value: serde_json::Value = serde_json::from_slice(&data).unwrap();
        match field {
            "format" => value[field] = "public-other-format".into(),
            "schemaVersion" => value[field] = 2.into(),
            "backupID" => value[field] = "public-other-backup".into(),
            "alg" => value["wrappedKey"][field] = "public-unsupported-kdf".into(),
            "iterations" => value["wrappedKey"][field] = 2001.into(),
            "salt" => value["wrappedKey"][field] = crypto::b64(&[0x12; 16]).into(),
            "envelope" => value["wrappedKey"][field] = value["payload"].clone(),
            _ => value[field] = value["wrappedKey"]["envelope"].clone(),
        }
        assert!(
            open(
                &serde_json::to_vec(&value).unwrap(),
                "Public backup passphrase"
            )
            .is_err()
        );
    }
}
#[test]
fn export_copies_secure_ciphertext_without_opening_it_but_import_authenticates_all_records() {
    let mut damaged = document();
    damaged.records[0].content_hash = "00".repeat(16);
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let sealed = seal_inner(
        &[plain()],
        Some((&damaged, &key)),
        "Public backup passphrase",
        2000,
    )
    .unwrap();
    assert!(open(&sealed, "Public backup passphrase").is_err());
    let wrong = RootKey::from_bytes(&[0x33; 32]).unwrap();
    let sealed = seal_inner(
        &[],
        Some((&document(), &wrong)),
        "Public backup passphrase",
        2000,
    )
    .unwrap();
    assert!(open(&sealed, "Public backup passphrase").is_err());
}
#[test]
fn duplicate_identifiers_keywords_and_empty_vaults_are_refused_before_encryption() {
    let mut plain = plain();
    let mut vault = document();
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    plain.id = vault.records[0].metadata.id;
    assert!(seal(&[plain.clone()], Some((&vault, &key)), "Public passphrase").is_err());
    plain.id = uuid::Uuid::from_u128(3);
    plain.keyword = "INTEROP".into();
    assert!(seal(&[plain], Some((&vault, &key)), "Public passphrase").is_err());
    vault.records.clear();
    assert!(seal(&[], Some((&vault, &key)), "Public passphrase").is_err());
}
#[test]
fn large_ordinary_payloads_use_backup_limits_and_unsupported_parameters_fail_before_kdf() {
    let mut first = plain();
    first.content = "a".repeat(200_000);
    let mut second = first.clone();
    second.id = uuid::Uuid::from_u128(3);
    second.keyword = "public-other".into();
    let data = seal_inner(
        &[first.clone(), second.clone()],
        None,
        "Public backup passphrase",
        2000,
    )
    .unwrap();
    assert!(data.len() > model::MAX_BODY_BYTES);
    assert!(open(&data, "Public backup passphrase").unwrap().snippets == vec![first, second]);
    for rounds in [0_u64, 20_000_001, u64::MAX] {
        let mut container: serde_json::Value = serde_json::from_slice(&data).unwrap();
        container["wrappedKey"]["iterations"] = rounds.into();
        assert!(
            open(
                &serde_json::to_vec(&container).unwrap(),
                "Public backup passphrase"
            )
            .is_err()
        );
    }
    assert!(
        open(
            &vec![b' '; model::MAX_FILE_BYTES + 1],
            "Public backup passphrase"
        )
        .is_err()
    );
}
#[test]
#[ignore = "writes only a public fictional encrypted artifact for the independent OpenSSL decoder"]
fn public_rust_export_for_openssl_decoder() {
    let output = tempfile::Builder::new()
        .prefix("snippets-backup-public-")
        .tempdir()
        .unwrap();
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let data = seal(
        &[plain()],
        Some((&document(), &key)),
        "Café public backup fixture",
    )
    .unwrap();
    let root = output.keep();
    model::atomic_write(&root.join("public.snippetsbackup"), &data).unwrap();
    println!(
        "Public encrypted artifact: {}",
        root.join("public.snippetsbackup").display()
    );
}
