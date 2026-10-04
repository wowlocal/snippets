//! Fictional wraps/bodies and isolated temporary files only; no native services.
use super::*;
use std::cell::Cell;
const OLD: &str = "Old public vault passphrase";
const CURRENT: &str = "Current public vault passphrase";
const BODY: &[u8] = b"Public retained draft \xf0\x9f\xa6\x80\n";
fn document(kid: &str, byte: u8, pass: &str) -> Document {
    let key = RootKey::from_bytes(&[byte; 32]).unwrap();
    let salt = [byte + 1; 32];
    let (kdf, wrap) = crypto::wrap_passphrase_cost(&key, pass, kid, 2000).unwrap();
    let mut metadata = Metadata::new();
    metadata.id = Uuid::from_u128(7);
    metadata.name = "Public saved fixture".into();
    metadata.keyword = "publicfixture".into();
    let record = Record {
        sealed: crypto::seal_record(
            b"Public existing record",
            &key,
            &salt,
            kid,
            metadata.id,
            false,
        )
        .unwrap(),
        content_hash: crypto::content_hash(b"Public existing record", &key, &salt),
        metadata,
        hlc: None,
        extra: BTreeMap::new(),
    };
    Document {
        schema_version: 1,
        kid: kid.into(),
        vault_salt: crypto::b64(&salt),
        kdf,
        wrap_pass: Some(wrap),
        wrap_recovery: Some(crypto::wrap_recovery(&key, &[byte; 16], &salt, kid).unwrap()),
        wrap_cli: None,
        records: vec![record],
        extra: BTreeMap::new(),
    }
}
fn fixture() -> (tempfile::TempDir, Library, Vault, EncryptedDraft) {
    let root = tempfile::tempdir().unwrap();
    let library = Library::open(root.path().into()).unwrap();
    fs::create_dir(root.path().join("Vault")).unwrap();
    let old = document("public-old", 0x11, OLD);
    model::atomic_write(
        &root.path().join("Vault/vault.json"),
        &old.encode().unwrap(),
    )
    .unwrap();
    let mut vault = Vault::open(&library).unwrap();
    vault
        .finish_authentication(old.authenticate(OLD, false).unwrap(), vault.generation())
        .unwrap();
    let source = vault.record(Uuid::from_u128(7)).unwrap();
    let draft = vault
        .protect_draft(source.metadata.clone(), BODY, Some(source))
        .unwrap();
    let current = document("public-current", 0x22, CURRENT);
    model::atomic_write(
        &root.path().join("Vault/vault.json"),
        &current.encode().unwrap(),
    )
    .unwrap();
    vault.reload().unwrap();
    assert!(!vault.is_unlocked());
    vault
        .finish_authentication(
            current.authenticate(CURRENT, false).unwrap(),
            vault.generation(),
        )
        .unwrap();
    assert!(vault.draft_is_foreign(&draft));
    (root, library, vault, draft)
}
fn prepare(vault: &mut Vault, draft: &EncryptedDraft) -> PreparedDraftRecovery {
    vault
        .prepare_draft_recovery(draft, draft.metadata.clone())
        .unwrap()
        .authenticate(OLD, false, CURRENT, false, &|| Ok(()))
        .unwrap()
}
fn unchanged(root: &Path, before: &[u8]) {
    assert_eq!(fs::read(root.join("Vault/vault.json")).unwrap(), before);
    assert!(!root.join("device.json").exists());
    assert!(!root.join("Sync").exists());
}
#[test]
fn old_and_current_credentials_recover_only_a_new_encrypted_draft_until_explicit_save() {
    for old_recovery in [false, true] {
        for current_recovery in [false, true] {
            let (root, library, mut vault, mut draft) = fixture();
            let before = fs::read(root.path().join("Vault/vault.json")).unwrap();
            let original = draft.clone();
            let source = if old_recovery {
                crypto::format_recovery(&[0x11; 16])
            } else {
                Zeroizing::new(OLD.into())
            };
            let target = if current_recovery {
                crypto::format_recovery(&[0x22; 16])
            } else {
                Zeroizing::new(CURRENT.into())
            };
            let prepared = vault
                .prepare_draft_recovery(&draft, draft.metadata.clone())
                .unwrap()
                .authenticate(&source, old_recovery, &target, current_recovery, &|| Ok(()))
                .unwrap();
            assert!(draft == original);
            vault.finish_draft_recovery(&mut draft, prepared).unwrap();
            assert!(!vault.draft_is_foreign(&draft));
            assert!(draft.metadata.id != original.metadata.id && draft.expected.is_none());
            assert_eq!(vault.draft_body(&draft, false).unwrap().as_slice(), BODY);
            assert!(
                crypto::open_draft(
                    &draft.sealed,
                    &RootKey::from_bytes(&[0x11; 32]).unwrap(),
                    &[0x12; 32],
                    "public-old",
                    draft.metadata.id
                )
                .is_err()
            );
            unchanged(root.path(), &before);
            // The saved current UUID/keyword occupant survives; Save requires a
            // distinct keyword and then appends the explicitly recovered record.
            assert!(
                vault
                    .save(&library, draft.metadata.clone(), BODY, None)
                    .is_err()
            );
            unchanged(root.path(), &before);
            draft.metadata.keyword = "recoveredfixture".into();
            vault
                .save(&library, draft.metadata.clone(), BODY, None)
                .unwrap();
            assert_eq!(
                vault.body(Uuid::from_u128(7)).unwrap().as_slice(),
                b"Public existing record"
            );
            assert_eq!(vault.body(draft.metadata.id).unwrap().as_slice(), BODY);
        }
    }
}
#[test]
fn wrong_old_or_current_credentials_leave_the_original_draft_and_files_intact() {
    let (root, _, mut vault, draft) = fixture();
    let before = fs::read(root.path().join("Vault/vault.json")).unwrap();
    let original = draft.clone();
    for (source, target) in [("wrong public old", CURRENT), (OLD, "wrong public current")] {
        assert!(
            vault
                .prepare_draft_recovery(&draft, draft.metadata.clone())
                .unwrap()
                .authenticate(source, false, target, false, &|| Ok(()))
                .is_err()
        );
        assert!(draft == original && vault.is_unlocked());
        unchanged(root.path(), &before);
    }
}
#[test]
fn every_authentication_and_reseal_boundary_checks_cancellation() {
    let (root, _, mut vault, draft) = fixture();
    let before = fs::read(root.path().join("Vault/vault.json")).unwrap();
    for stop in 1..=4 {
        let checks = Cell::new(0);
        let result = vault
            .prepare_draft_recovery(&draft, draft.metadata.clone())
            .unwrap()
            .authenticate(OLD, false, CURRENT, false, &|| {
                checks.set(checks.get() + 1);
                if checks.get() == stop {
                    Err(Error("Public cancellation"))
                } else {
                    Ok(())
                }
            });
        assert!(result.is_err());
        assert_eq!(checks.get(), stop);
        assert!(vault.draft_is_foreign(&draft));
        unchanged(root.path(), &before);
    }
}
#[test]
fn source_ciphertext_id_and_invalid_text_cannot_be_recovered() {
    let (root, _, mut vault, draft) = fixture();
    let before = fs::read(root.path().join("Vault/vault.json")).unwrap();
    let mut changed = draft.clone();
    changed.metadata.id = Uuid::from_u128(8);
    assert!(
        vault
            .prepare_draft_recovery(&changed, changed.metadata.clone())
            .unwrap()
            .authenticate(OLD, false, CURRENT, false, &|| Ok(()))
            .is_err()
    );
    for body in [b"bad\0text".as_slice(), b"\xff"] {
        let mut changed = draft.clone();
        changed.sealed = crypto::seal_draft(
            body,
            &RootKey::from_bytes(&[0x11; 32]).unwrap(),
            &[0x12; 32],
            "public-old",
            changed.metadata.id,
        )
        .unwrap();
        assert!(
            vault
                .prepare_draft_recovery(&changed, changed.metadata.clone())
                .unwrap()
                .authenticate(OLD, false, CURRENT, false, &|| Ok(()))
                .is_err()
        );
    }
    assert!(
        crypto::seal_draft(
            &vec![b'x'; model::MAX_BODY_BYTES + 1],
            &RootKey::from_bytes(&[0x11; 32]).unwrap(),
            &[0x12; 32],
            "public-old",
            draft.metadata.id
        )
        .is_err()
    );
    unchanged(root.path(), &before);
}
#[test]
fn publication_refuses_lock_expiry_source_changes_and_target_changes() {
    for fault in 0..5 {
        let (root, _, mut vault, mut draft) = fixture();
        let original = draft.clone();
        let prepared = prepare(&mut vault, &draft);
        match fault {
            0 => vault.lock(),
            1 => vault.test_now = Some(vault.session.as_ref().unwrap().used + IDLE_TIMEOUT),
            2 => draft.metadata.name = "Later public metadata".into(),
            3 => {
                let replacement = document("public-replacement", 0x33, "Other public password");
                model::atomic_write(
                    &root.path().join("Vault/vault.json"),
                    &replacement.encode().unwrap(),
                )
                .unwrap();
            }
            _ => {
                fs::create_dir(root.path().join("Backups")).unwrap();
                model::atomic_write(
                    &root.path().join("Backups/restore.pending"),
                    b"fictional backup fence",
                )
                .unwrap();
            }
        }
        let before = fs::read(root.path().join("Vault/vault.json")).unwrap();
        let expected = draft.clone();
        assert!(vault.finish_draft_recovery(&mut draft, prepared).is_err());
        assert!(draft == expected && draft.sealed == original.sealed);
        unchanged(root.path(), &before);
    }
}
#[test]
fn recovery_neither_extends_idle_nor_restores_an_old_session() {
    let (root, _, mut vault, mut draft) = fixture();
    vault.test_now = Some(Duration::ZERO);
    vault
        .install(
            vault
                .document
                .as_ref()
                .unwrap()
                .authenticate(CURRENT, false)
                .unwrap(),
        )
        .unwrap();
    let original = draft.clone();
    let prepared = prepare(&mut vault, &draft);
    vault.test_now = Some(Duration::from_secs(299));
    vault.finish_draft_recovery(&mut draft, prepared).unwrap();
    assert_eq!(vault.session.as_ref().unwrap().used, Duration::ZERO);
    vault.test_now = Some(IDLE_TIMEOUT);
    assert!(!vault.is_unlocked() && vault.draft_body(&draft, false).is_err());
    assert!(draft.identity != original.identity);
    assert!(!root.path().join("device.json").exists());
}
#[test]
fn stale_source_body_expected_record_and_tampered_result_never_replace_the_retained_draft() {
    for fault in 0..3 {
        let (root, _, mut vault, mut draft) = fixture();
        let mut prepared = prepare(&mut vault, &draft);
        match fault {
            0 => {
                draft.sealed = crypto::seal_draft(
                    b"Later public edit",
                    &RootKey::from_bytes(&[0x11; 32]).unwrap(),
                    &[0x12; 32],
                    "public-old",
                    draft.metadata.id,
                )
                .unwrap()
            }
            1 => {
                draft
                    .expected
                    .as_mut()
                    .unwrap()
                    .extra
                    .insert("publicFutureField".into(), Value::Bool(true));
            }
            _ => prepared.recovered.metadata.id = Uuid::from_u128(999),
        }
        let original = draft.clone();
        let before = fs::read(root.path().join("Vault/vault.json")).unwrap();
        assert!(vault.finish_draft_recovery(&mut draft, prepared).is_err());
        assert!(draft == original);
        unchanged(root.path(), &before);
    }
}
#[test]
fn current_wrap_salt_kid_and_kdf_changes_invalidate_publication_but_unrelated_records_survive() {
    for fault in 0..7 {
        let (root, _, mut vault, mut draft) = fixture();
        let prepared = prepare(&mut vault, &draft);
        let mut document = vault.document.clone().unwrap();
        match fault {
            0 => document.kid = "public-changed-kid".into(),
            1 => document.vault_salt = crypto::b64(&[0x44; 32]),
            2 => document.kdf.iterations += 1,
            3 => document.wrap_pass = None,
            4 => document.wrap_recovery = None,
            5 => document.wrap_cli = document.wrap_recovery.clone(),
            _ => document.records[0].metadata.name = "Later unrelated public edit".into(),
        }
        model::atomic_write(
            &root.path().join("Vault/vault.json"),
            &document.encode().unwrap(),
        )
        .unwrap();
        let before = fs::read(root.path().join("Vault/vault.json")).unwrap();
        let result = vault.finish_draft_recovery(&mut draft, prepared);
        assert_eq!(result.is_ok(), fault == 6);
        unchanged(root.path(), &before);
    }
}
#[test]
fn recovery_only_doors_and_credential_bounds_are_enforced() {
    let (root, _, mut vault, mut draft) = fixture();
    draft.identity.pass = None;
    let mut document = vault.document.clone().unwrap();
    document.wrap_pass = None;
    model::atomic_write(
        &root.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    vault.reload().unwrap();
    let target_code = crypto::format_recovery(&[0x22; 16]);
    vault
        .finish_authentication(
            document.authenticate(&target_code, true).unwrap(),
            vault.generation(),
        )
        .unwrap();
    let request = vault
        .prepare_draft_recovery(&draft, draft.metadata.clone())
        .unwrap();
    assert!(!request.source_has_passphrase() && request.source_has_recovery());
    assert!(!request.target_has_passphrase() && request.target_has_recovery());
    let source_code = crypto::format_recovery(&[0x11; 16]);
    let recovered = request
        .authenticate(&source_code, true, &target_code, true, &|| Ok(()))
        .unwrap();
    vault.finish_draft_recovery(&mut draft, recovered).unwrap();
    assert_eq!(vault.draft_body(&draft, false).unwrap().as_slice(), BODY);
    let (_other_root, _, mut other, foreign) = fixture();
    let before = fs::read(other.root.join("Vault/vault.json")).unwrap();
    assert!(
        other
            .prepare_draft_recovery(&foreign, foreign.metadata.clone())
            .unwrap()
            .authenticate(&"x".repeat(4097), false, CURRENT, false, &|| Ok(()))
            .is_err()
    );
    unchanged(&other.root, &before);
}
