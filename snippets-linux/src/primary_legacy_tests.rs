//! Temporary libraries and public crypto fixtures; no desktop/keyring access.
use super::*;
use crate::canonical::Value;

fn setup(
    empty: bool,
    missing_hash: bool,
) -> (tempfile::TempDir, Library, Document, Checkpoint, Envelope) {
    let temporary = tempfile::tempdir().unwrap();
    let library = Library::open(temporary.path().into()).unwrap();
    let mut document = vault_fixture();
    document.records[0].hlc = Some(Hlc::parse("100000000000-0000-11111111").unwrap());
    if missing_hash {
        document.records[0].content_hash.clear();
    }
    let source = projection::current(
        &[],
        Some(&document),
        "11111111",
        &BTreeMap::new(),
        &BTreeMap::new(),
    )
    .unwrap()
    .into_values()
    .next()
    .unwrap();
    if empty {
        document.records.clear();
    }
    install_vault(temporary.path(), &document);
    let checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    (temporary, library, document, checkpoint, source)
}
fn unstamped(mut source: Envelope) -> Envelope {
    source.extensions.remove("vaultKID");
    source
}
fn changed(mut source: Envelope, document: &Document) -> Envelope {
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let salt = document.salt().unwrap();
    let body = b"Public changed legacy wire body";
    source.hlc = Hlc::foreign(0xffff_0000_0000);
    source.fields.as_mut().unwrap().updated_at += 1.0;
    source.fields.as_mut().unwrap().content = Zeroizing::new(
        crate::crypto::seal_record(body, &root, &salt, &document.kid, source.id, false)
            .unwrap()
            .text()
            .as_bytes()
            .to_vec(),
    );
    source.extensions.insert(
        "vaultContentHash".into(),
        Value::text(crate::crypto::content_hash(body, &root, &salt)),
    );
    unstamped(source)
}
fn expected(library: &Library, checkpoint: &Checkpoint, id: Uuid) -> ReadSet {
    BTreeMap::from([(id, actual(library, &checkpoint.journal).get(&id).cloned())])
}

#[test]
fn stamped_exact_own_echo_with_no_hash_also_passes_the_authenticated_path() {
    let (_temporary, library, document, mut checkpoint, incoming) = setup(false, true);
    let expected = expected(&library, &checkpoint, incoming.id);
    let before = fs::read(library.root.join("Vault/vault.json")).unwrap();
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let prepared = prepare_authenticated(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(incoming.clone())],
        &expected,
        &Keyring::new(&root, &document).unwrap(),
    )
    .unwrap();
    assert!(prepared.deferred_ids.is_empty() && prepared.incompatible_ids.is_empty());
    assert!(prepared.projected[&incoming.id].encode().unwrap() == incoming.encode().unwrap());
    commit(&library, &mut checkpoint, &key(), &SALT, prepared).unwrap();
    assert_eq!(
        fs::read(library.root.join("Vault/vault.json")).unwrap(),
        before
    );
}

#[test]
fn legacy_exact_own_echo_needs_no_key_even_when_both_hashes_are_absent() {
    for missing_hash in [false, true] {
        for with_key in [false, true] {
            let (_temporary, library, document, mut checkpoint, source) =
                setup(false, missing_hash);
            let incoming = unstamped(source);
            let encoded = incoming.encode().unwrap();
            let before = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let outcomes = [outcome(incoming.clone())];
            let expected = expected(&library, &checkpoint, incoming.id);
            let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
            let prepared = if with_key {
                prepare_authenticated(
                    &library,
                    &checkpoint.journal,
                    "11111111",
                    &outcomes,
                    &expected,
                    &Keyring::new(&root, &document).unwrap(),
                )
            } else {
                prepare(
                    &library,
                    &checkpoint.journal,
                    "11111111",
                    &outcomes,
                    &expected,
                )
            }
            .unwrap();
            assert_eq!(prepared.changed_ids, BTreeSet::from([incoming.id]));
            assert!(prepared.deferred_ids.is_empty() && prepared.incompatible_ids.is_empty());
            assert!(prepared.projected[&incoming.id].encode().unwrap() == encoded);
            commit(&library, &mut checkpoint, &key(), &SALT, prepared).unwrap();
            assert_eq!(
                fs::read(library.root.join("Vault/vault.json")).unwrap(),
                before
            );
            assert!(
                checkpoint.journal.projected()[&incoming.id]
                    .encode()
                    .unwrap()
                    == encoded
            );
        }
    }
}

#[test]
fn legacy_changed_or_absent_body_defers_locked_and_authenticates_before_redo() {
    for empty in [false, true] {
        for fault in [None, Some(0), Some(1), Some(2), Some(3), Some(4)] {
            let (temporary, library, document, mut checkpoint, source) = setup(empty, false);
            let incoming = changed(source, &document);
            let encoded = incoming.encode().unwrap();
            let expected = expected(&library, &checkpoint, incoming.id);
            let outcomes = [outcome(incoming.clone())];
            let before = fs::read(library.root.join("Vault/vault.json")).unwrap();
            let locked = prepare(
                &library,
                &checkpoint.journal,
                "11111111",
                &outcomes,
                &expected,
            )
            .unwrap();
            assert!(locked.changed_ids.is_empty() && locked.deferred_ids.contains(&incoming.id));
            assert_eq!(
                fs::read(library.root.join("Vault/vault.json")).unwrap(),
                before
            );
            assert!(!temporary.path().join("Sync").exists());
            let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
            let prepared = prepare_authenticated(
                &library,
                &checkpoint.journal,
                "11111111",
                &outcomes,
                &expected,
                &Keyring::new(&root, &document).unwrap(),
            )
            .unwrap();
            assert!(
                prepared.changed_ids.contains(&incoming.id) && prepared.deferred_ids.is_empty()
            );
            assert!(prepared.projected[&incoming.id].encode().unwrap() == encoded);
            let committed =
                commit_with_fault(&library, &mut checkpoint, &key(), &SALT, prepared, fault);
            let recovered = if fault.is_some() {
                assert_eq!(committed, Err(Failure::RecoveryRequired));
                recover(temporary.path(), &key(), &SALT, scope()).unwrap()
            } else {
                committed.unwrap();
                checkpoint
            };
            // Before WAL publication there is no authorized target to replay.
            if fault == Some(0) {
                assert_eq!(
                    fs::read(library.root.join("Vault/vault.json")).unwrap(),
                    before
                );
                continue;
            }
            assert!(
                recovered.journal.projected()[&incoming.id]
                    .encode()
                    .unwrap()
                    == encoded
            );
            let saved = vault::read_document(temporary.path()).unwrap().unwrap();
            let record = saved
                .records
                .iter()
                .find(|record| record.metadata.id == incoming.id)
                .unwrap();
            assert_eq!(
                record.sealed.text().as_bytes(),
                incoming.fields.as_ref().unwrap().content.as_slice()
            );
            assert_eq!(
                record.content_hash,
                incoming.extensions["vaultContentHash"].as_text().unwrap()
            );
            let body = crate::crypto::open_record(
                &record.sealed,
                &root,
                &saved.salt().unwrap(),
                &saved.kid,
                record.metadata.id,
                false,
            )
            .unwrap();
            assert_eq!(body.as_slice(), b"Public changed legacy wire body");
            let projected = actual(&library, &recovered.journal);
            let stamped = &projected[&incoming.id];
            assert_eq!(
                stamped.extensions["vaultKID"].as_text().unwrap(),
                document.kid
            );
            assert!(stamped.hlc > incoming.hlc);
            assert_eq!(
                stamped.fields.as_ref().unwrap().content,
                incoming.fields.as_ref().unwrap().content
            );
            assert!(actual(&library, &recovered.journal)[&incoming.id] == *stamped);
        }
    }
}

#[test]
fn legacy_changed_body_never_guesses_existing_metadata_or_replaces_bad_proofs() {
    for invalid in 0..8 {
        let (temporary, library, document, checkpoint, source) = setup(false, false);
        let mut incoming = changed(source, &document);
        let root = RootKey::from_bytes(&[if invalid == 7 { 0x22 } else { 0x11 }; 32]).unwrap();
        match invalid {
            0 => {
                incoming.extensions.remove("vaultContentHash");
            }
            1 => {
                incoming
                    .extensions
                    .insert("vaultContentHash".into(), Value::text("00".repeat(16)));
            }
            2 => {
                incoming
                    .extensions
                    .insert("vaultKID".into(), Value::text("Public wrong vault"));
            }
            3 => {
                incoming
                    .extensions
                    .insert("vaultKID".into(), Value::Bool(true));
            }
            4 => {
                incoming.fields.as_mut().unwrap().content = Zeroizing::new(
                    crate::crypto::seal_record(
                        b"Public changed legacy wire body",
                        &root,
                        &document.salt().unwrap(),
                        &document.kid,
                        Uuid::from_u128(999),
                        false,
                    )
                    .unwrap()
                    .text()
                    .as_bytes()
                    .to_vec(),
                );
            }
            5 => {
                incoming.fields.as_mut().unwrap().content = Zeroizing::new(
                    crate::crypto::seal_record(
                        b"Public changed legacy wire body",
                        &root,
                        &document.salt().unwrap(),
                        "Public wrong vault",
                        incoming.id,
                        false,
                    )
                    .unwrap()
                    .text()
                    .as_bytes()
                    .to_vec(),
                );
            }
            6 => {
                incoming.fields.as_mut().unwrap().content =
                    Zeroizing::new(b"invalid public seal".to_vec());
            }
            7 => (), // A key with matching public wraps must still open the seal.
            _ => unreachable!(),
        }
        let before = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
        assert!(
            prepare_authenticated(
                &library,
                &checkpoint.journal,
                "11111111",
                &[outcome(incoming.clone())],
                &expected(&library, &checkpoint, incoming.id),
                &Keyring::new(&root, &document).unwrap()
            )
            .is_err()
        );
        assert_eq!(
            fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
            before
        );
        assert!(!temporary.path().join("Sync").exists());
    }
}

#[test]
fn legacy_own_admission_does_not_repair_missing_original_copy_proofs() {
    for missing in ["vaultKID", "vaultContentHash"] {
        let (temporary, library, document, checkpoint, _) = setup(false, false);
        let (mut outcomes, expected, _, _, _) =
            nested_secure_outcomes(&library, &checkpoint.journal, &document);
        outcomes[0].conflict_copies[0].extensions.remove(missing);
        let before = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        assert!(
            prepare_authenticated(
                &library,
                &checkpoint.journal,
                "11111111",
                &outcomes,
                &expected,
                &Keyring::new(&root, &document).unwrap()
            )
            .is_err()
        );
        assert_eq!(
            fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
            before
        );
        assert!(!temporary.path().join("Sync").exists());
    }
}

#[test]
fn legacy_missing_copy_stamp_never_uses_own_record_exception() {
    let (temporary, library, mut document, checkpoint, _) = setup(false, false);
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let source = secure_to_plain_conflict(&library, &checkpoint.journal, &document)
        .0
        .survivor
        .unwrap();
    let evidence = Evidence::prepare(
        std::slice::from_ref(&source),
        &Keyring::new(&root, &document).unwrap(),
        &BTreeMap::new(),
    )
    .unwrap();
    let copy = evidence.copies().values().next().unwrap().clone();
    document.records.push(
        projection::vault_record(&copy, None, &document.kid)
            .unwrap()
            .unwrap(),
    );
    model::atomic_write(
        &temporary.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let incoming = unstamped(copy);
    let expected = expected(&library, &checkpoint, incoming.id);
    let outcomes = [outcome(incoming.clone())];
    let before = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
    let locked = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &outcomes,
        &expected,
    )
    .unwrap();
    assert!(locked.changed_ids.is_empty() && locked.deferred_ids.contains(&incoming.id));
    assert!(
        prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            &outcomes,
            &expected,
            &Keyring::new(&root, &document).unwrap()
        )
        .is_err()
    );
    assert_eq!(
        fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
        before
    );
    assert!(!temporary.path().join("Sync").exists());
}
