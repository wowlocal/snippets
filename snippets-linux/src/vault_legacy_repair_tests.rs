use super::*;
use std::os::unix::fs::{PermissionsExt, symlink};
fn authorization() -> Authorization {
    Authorization::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap()
}
fn setup() -> (tempfile::TempDir, Library, Vault) {
    let (temporary, library, mut vault) = super::super::tests::setup();
    let mut document = vault.document.clone().unwrap();
    document.records[0].content_hash.clear();
    document.records[0]
        .extra
        .insert("future-key".into(), serde_json::json!({"flag":true}));
    vault.write(&document).unwrap();
    vault.reload().unwrap();
    (temporary, library, vault)
}
fn request(library: &Library, vault: &Vault, auth: Authorization) -> Request {
    let document = vault.document.clone().unwrap();
    Request::capture(
        library.root.clone(),
        document.clone(),
        document.records[0].clone(),
        auth,
    )
    .unwrap()
}
fn prepared(request: Request) -> Result<Prepared> {
    let authentication = Authentication {
        key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
        identity: request.document.identity(),
    };
    request.prepare(authentication)
}
fn bytes(library: &Library) -> Vec<u8> {
    fs::read(library.root.join("Vault/vault.json")).unwrap()
}

#[test]
fn authenticated_repair_preserves_ciphertext_metadata_extras_and_locked_session() {
    let (_temporary, library, mut vault) = setup();
    vault.lock();
    let before = vault.document.clone().unwrap();
    let record = before.records[0].clone();
    let receipt = prepared(request(&library, &vault, authorization()))
        .unwrap()
        .commit()
        .unwrap();
    vault.reload().unwrap();
    let after = vault.document.clone().unwrap();
    let mut repaired = after.records[0].clone();
    assert_eq!(receipt.id(), record.metadata.id);
    assert!(!repaired.content_hash.is_empty());
    assert!(repaired.hlc > record.hlc);
    assert!(!vault.is_unlocked());
    crypto::verify_hash(
        &repaired.content_hash,
        "Fictional secret 🦀\n".as_bytes(),
        &RootKey::from_bytes(&[0x11; 32]).unwrap(),
        &after.salt().unwrap(),
    )
    .unwrap();
    repaired.content_hash.clear();
    repaired.hlc = record.hlc.clone();
    assert!(repaired == record);
    let mut expected = before;
    expected.records = after.records.clone();
    assert!(expected == after);
    let view = crate::projection::current(
        &[],
        Some(&after),
        "1234abcd",
        &BTreeMap::new(),
        &BTreeMap::new(),
    )
    .unwrap();
    let envelope = &view[&receipt.id()];
    assert_eq!(
        envelope.extensions["vaultKID"].as_text().unwrap(),
        after.kid
    );
    assert_eq!(
        envelope.extensions["vaultContentHash"].as_text().unwrap(),
        after.records[0].content_hash
    );
    assert_eq!(
        fs::metadata(library.root.join("Vault/vault.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert!(!library.root.join("Sync").exists());
    assert!(
        Request::capture(
            library.root.clone(),
            after.clone(),
            after.records[0].clone(),
            authorization()
        )
        .is_err()
    );
}
#[test]
fn repair_changes_only_two_selected_json_fields_in_a_legacy_file() {
    let (_temporary, library, mut vault) = setup();
    let mut before: Value = serde_json::from_slice(&bytes(&library)).unwrap();
    before["records"][0]["createdAt"] = Value::String("2026-09-30T10:00:00.123456789Z".into());
    before["records"][0]["keyword"] = Value::String(" \\interop ".into());
    before["records"][0]["tags"] = serde_json::json!(["Tag", "tag", " future "]);
    before["records"][0].as_object_mut().unwrap().remove("hlc");
    let mut other = before["records"][0].clone();
    other["id"] = Value::String(Uuid::from_u128(999).to_string());
    other["contentHash"] = Value::String("".into());
    before["records"].as_array_mut().unwrap().push(other);
    model::atomic_write(
        &library.root.join("Vault/vault.json"),
        &serde_json::to_vec(&before).unwrap(),
    )
    .unwrap();
    vault.reload().unwrap();
    prepared(request(&library, &vault, authorization()))
        .unwrap()
        .commit()
        .unwrap();
    let mut after: Value = serde_json::from_slice(&bytes(&library)).unwrap();
    assert_eq!(after["records"][1], before["records"][1]);
    assert!(after["records"][0]["contentHash"].as_str().unwrap().len() == 32);
    after["records"][0]["contentHash"] = before["records"][0]["contentHash"].clone();
    after["records"][0].as_object_mut().unwrap().remove("hlc");
    assert_eq!(after, before);
}

#[test]
fn valid_opaque_v1_originals_remain_exact_and_wrong_original_macs_stop_repair() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    for tampered in [false, true] {
        let (_temporary, library, mut vault) = setup();
        let mut document = vault.document.clone().unwrap();
        let fixture: Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        let mut source_document = document.clone();
        source_document.records[0].content_hash = fixture["document"]["records"][0]["contentHash"]
            .as_str()
            .unwrap()
            .into();
        let source_view = crate::projection::current(
            &[],
            Some(&source_document),
            "1234abcd",
            &BTreeMap::new(),
            &BTreeMap::new(),
        )
        .unwrap();
        let mut source = source_view[&document.records[0].metadata.id].clone();
        if tampered {
            source.extensions.insert(
                "vaultContentHash".into(),
                crate::canonical::Value::text("00".repeat(16)),
            );
        }
        let (key, packet) = crate::merge::secure_variant(&source).unwrap();
        let opaque = format!(
            "{}{}",
            crate::merge::OPAQUE_CARRIER_PREFIX,
            key.strip_prefix(crate::merge::CONFLICT_PREFIX).unwrap()
        );
        let encoded = STANDARD.encode(packet.encode().unwrap());
        document.records[0]
            .extra
            .insert(opaque.clone(), Value::String(encoded.clone()));
        vault.write(&document).unwrap();
        vault.reload().unwrap();
        let before = bytes(&library);
        let operation = prepared(request(&library, &vault, authorization()));
        if tampered {
            assert!(operation.is_err());
            assert_eq!(bytes(&library), before);
        } else {
            operation.unwrap().commit().unwrap();
            vault.reload().unwrap();
            assert_eq!(
                vault.document.as_ref().unwrap().records[0].extra[&opaque],
                Value::String(encoded)
            );
        }
    }
}

#[test]
fn repaired_saved_entry_passes_fresh_direct_insertion_admission() {
    let (_temporary, library, mut vault) = setup();
    vault.lock();
    prepared(request(&library, &vault, authorization()))
        .unwrap()
        .commit()
        .unwrap();
    vault.reload().unwrap();
    let document = vault.document.clone().unwrap();
    let auth = Authentication {
        key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
        identity: document.identity(),
    };
    let insertion = crate::secure_insertion::Authorization::new(SessionWitness::test(
        SessionState::Unlocked,
        1,
    ))
    .unwrap();
    assert!(
        Vault::prepare_saved_insertion(
            library.root.clone(),
            document.clone(),
            auth,
            document.records[0].clone(),
            insertion
        )
        .is_ok()
    );
    assert!(!vault.is_unlocked());
}

#[test]
fn repair_authenticates_independent_passphrase_and_recovery_wraps() {
    let fixture: Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    for recovery in [false, true] {
        let (_temporary, library, mut vault) = setup();
        vault.lock();
        let credential = if recovery {
            crypto::format_recovery(&[0x66; 16])
        } else {
            Zeroizing::new(fixture["passphrase"].as_str().unwrap().into())
        };
        let witness = SessionWitness::test(SessionState::Unlocked, 1);
        let auth = Authorization::new(witness.clone()).unwrap();
        let operation = request(&library, &vault, auth);
        let stop = AtomicBool::new(false);
        let result = std::thread::scope(|scope| {
            scope.spawn(|| {
                while !stop.load(Ordering::Acquire) {
                    witness.test_observe(SessionState::Unlocked);
                    std::thread::sleep(Duration::from_millis(25));
                }
            });
            let result = operation
                .authenticate(&credential, recovery)
                .and_then(Prepared::commit);
            stop.store(true, Ordering::Release);
            result
        });
        result.unwrap();
        assert!(!vault.is_unlocked());
    }
}
#[test]
fn present_hashes_and_wrong_or_malformed_stamps_are_not_replaced() {
    for changed in 0..5 {
        let (_temporary, library, mut vault) = setup();
        let mut document = vault.document.clone().unwrap();
        match changed {
            0 => document.records[0].content_hash = "00".repeat(16),
            1 => {
                document.records[0].extra.insert(
                    "vaultKID".into(),
                    Value::String("Public other scope".into()),
                );
            }
            2 => {
                document.records[0]
                    .extra
                    .insert("vaultKID".into(), Value::Bool(true));
            }
            3 => {
                document.records[0]
                    .extra
                    .insert("vaultContentHash".into(), Value::String("00".repeat(16)));
            }
            4 => {
                document.records[0]
                    .extra
                    .insert("vaultContentHash".into(), Value::Bool(true));
            }
            _ => unreachable!(),
        }
        vault.write(&document).unwrap();
        vault.reload().unwrap();
        let before = bytes(&library);
        let current = vault.document.clone().unwrap();
        let operation = Request::capture(
            library.root.clone(),
            current.clone(),
            current.records[0].clone(),
            authorization(),
        );
        match operation {
            Ok(request) => assert!(prepared(request).is_err()),
            Err(_) => assert!(changed < 3),
        }
        assert_eq!(bytes(&library), before);
        assert!(!library.root.join("device.json").exists());
    }
}
#[test]
fn authentication_never_accepts_changed_ciphertext_record_identity_or_credentials() {
    for changed in 0..6 {
        let (_temporary, library, mut vault) = setup();
        let mut document = vault.document.clone().unwrap();
        match changed {
            0 => document.records[0].metadata.id = Uuid::from_u128(999),
            1 => document.kid = "Public other scope".into(),
            2 => document.vault_salt = crypto::b64(&[0x33; 32]),
            3 => {
                document.records[0].sealed = crypto::seal_record(
                    b"Public foreign body",
                    &RootKey::from_bytes(&[0x22; 32]).unwrap(),
                    &document.salt().unwrap(),
                    &document.kid,
                    document.records[0].metadata.id,
                    false,
                )
                .unwrap()
            }
            4 | 5 => (),
            _ => unreachable!(),
        }
        vault.write(&document).unwrap();
        vault.reload().unwrap();
        let before = bytes(&library);
        let request = request(&library, &vault, authorization());
        if changed == 4 {
            assert!(
                request
                    .authenticate("Public wrong credential", false)
                    .is_err()
            );
        } else if changed == 5 {
            assert!(request.authenticate(&"X".repeat(4097), false).is_err());
        } else {
            assert!(prepared(request).is_err());
        }
        assert_eq!(bytes(&library), before);
        assert!(!library.root.join("device.json").exists());
    }
}
#[test]
fn busy_locks_changed_files_links_and_recovery_fences_refuse_publication() {
    for changed in 0..8 {
        let (temporary, library, vault) = setup();
        let prepared = prepared(request(&library, &vault, authorization())).unwrap();
        let mut lock = None;
        match changed {
            0 => lock = Some(library.lock().unwrap()),
            1 => {
                let data = bytes(&library);
                model::atomic_write(&library.root.join("Vault/vault.json"), &data).unwrap();
            }
            2 => {
                let mut document = vault.document.clone().unwrap();
                document.records[0].metadata.name = "Public changed name".into();
                vault.write(&document).unwrap();
            }
            3 => {
                fs::hard_link(
                    library.root.join("Vault/vault.json"),
                    temporary.path().join("Public alias"),
                )
                .unwrap();
            }
            4 => {
                let data = bytes(&library);
                let path = library.root.join("Vault/vault.json");
                fs::remove_file(&path).unwrap();
                fs::write(temporary.path().join("Public linked file"), data).unwrap();
                symlink(temporary.path().join("Public linked file"), path).unwrap();
            }
            5 => {
                fs::create_dir(library.root.join("Sync")).unwrap();
                model::atomic_write(&library.root.join("Sync/primary.pending"), b"unrecognized")
                    .unwrap();
            }
            6 => {
                let mut ordinary = crate::model::Snippet::new("Public duplicate ID", "Public body");
                ordinary.id = vault.document.as_ref().unwrap().records[0].metadata.id;
                model::atomic_write(
                    &library.path(),
                    &model::encode_library(&[ordinary], false).unwrap(),
                )
                .unwrap();
            }
            7 => {
                let path = library.root.join("Vault/vault.json");
                let mut data = bytes(&library);
                data.push(b' ');
                fs::write(path, data).unwrap();
            }
            _ => unreachable!(),
        }
        let before = bytes(&library);
        assert!(prepared.commit().is_err());
        assert_eq!(bytes(&library), before);
        assert!(!library.root.join("device.json").exists());
        drop(lock);
    }
}
#[test]
fn captured_file_replacement_before_authentication_or_final_rename_stops_repair() {
    for late in [false, true] {
        let (_temporary, library, vault) = setup();
        let request = request(&library, &vault, authorization());
        let before = bytes(&library);
        let path = library.root.join("Vault/vault.json");
        if late {
            let prepared = prepared(request).unwrap();
            assert!(
                prepared
                    .commit_checked(&|| {
                        model::atomic_write(&path, &before)?;
                        Ok(())
                    })
                    .is_err()
            );
        } else {
            model::atomic_write(&path, &before).unwrap();
            assert!(prepared(request).is_err());
            assert!(!library.root.join("device.json").exists());
        }
        assert_eq!(bytes(&library), before);
        assert_eq!(fs::read_dir(library.root.join("Vault")).unwrap().count(), 1);
    }
}

#[test]
fn late_cancellation_after_temporary_fsync_never_replaces_the_vault() {
    let (_temporary, library, vault) = setup();
    let auth = authorization();
    let before = bytes(&library);
    let prepared = prepared(request(&library, &vault, auth.clone())).unwrap();
    assert!(
        prepared
            .commit_checked(&|| {
                auth.cancel();
                Ok(())
            })
            .is_err()
    );
    assert_eq!(bytes(&library), before);
    assert_eq!(fs::read_dir(library.root.join("Vault")).unwrap().count(), 1);
}
#[test]
fn lost_replies_are_observable_and_clean_draft_adoption_never_extends_a_session() {
    let (_temporary, library, mut vault) = setup();
    let id = vault.document.as_ref().unwrap().records[0].metadata.id;
    let expected = vault.record(id).unwrap();
    let body = vault.body(id).unwrap();
    let mut draft = vault
        .protect_draft(expected.metadata.clone(), &body, Some(expected))
        .unwrap();
    let sealed = draft.sealed.clone();
    let used = vault.session.as_ref().unwrap().used;
    let receipt = prepared(request(&library, &vault, authorization()))
        .unwrap()
        .commit()
        .unwrap();
    receipt.adopt(&mut vault, &mut draft).unwrap();
    assert!(draft.sealed == sealed);
    assert_eq!(vault.session.as_ref().unwrap().used, used);
    assert!(draft.expected.as_ref() == vault.record(id).as_ref());
    assert!(receipt.adopt(&mut vault, &mut draft).is_err());
    assert_eq!(
        &*vault.draft_body(&draft, false).unwrap(),
        b"Fictional secret \xf0\x9f\xa6\x80\n"
    );
    drop(receipt);
    vault.reload().unwrap();
    assert!(!vault.record(id).unwrap().content_hash.is_empty());
}
#[test]
fn malformed_reserved_carriers_remain_strict_and_unpublished() {
    for name in [
        format!("{}v1", crate::merge::CONFLICT_PREFIX),
        format!("{}v1", crate::merge::OPAQUE_CARRIER_PREFIX),
        format!("{}v9.future", crate::merge::CONFLICT_PREFIX),
        crate::merge::COPY_PROVENANCE.into(),
    ] {
        let (_temporary, library, mut vault) = setup();
        let mut document = vault.document.clone().unwrap();
        document.records[0]
            .extra
            .insert(name, Value::String("invalid".into()));
        vault.write(&document).unwrap();
        vault.reload().unwrap();
        let before = bytes(&library);
        let current = vault.document.clone().unwrap();
        assert!(
            Request::capture(
                library.root.clone(),
                current.clone(),
                current.records[0].clone(),
                authorization()
            )
            .is_err()
        );
        assert_eq!(bytes(&library), before);
    }
}
#[test]
fn authorization_rejects_epoch_changes_cancellation_expiry_and_clock_reversal() {
    assert!(Authorization::new(SessionWitness::test(SessionState::Locked, 1)).is_err());
    let witness = SessionWitness::test(SessionState::Unlocked, 1);
    let auth = Authorization::new(witness.clone()).unwrap();
    for (elapsed, wall) in [
        (Duration::from_secs(120), auth.wall),
        (Duration::ZERO, auth.wall + Duration::from_secs(120)),
    ] {
        assert!(auth.validate_at(auth.started + elapsed, wall).is_err());
    }
    assert!(
        auth.validate_at(auth.started - Duration::from_nanos(1), auth.wall)
            .is_err()
    );
    assert!(
        auth.validate_at(auth.started, auth.wall - Duration::from_secs(1))
            .is_err()
    );
    witness.test_observe(SessionState::Locked);
    witness.test_observe(SessionState::Unlocked);
    assert!(auth.validate().is_err());
    let next = Authorization::new(witness).unwrap();
    let worker = next.clone();
    next.cancel();
    assert!(worker.validate().is_err());
}
