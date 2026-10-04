use super::*;
use std::{cell::Cell, os::unix::fs::symlink};
const PASSWORD: &str = "Public backup passphrase";
const LOCAL_PASSPHRASE: &str = "Public restored vault passphrase";
fn document() -> Document {
    super::super::tests::document()
}
fn plain() -> Snippet {
    super::super::tests::plain()
}
fn credential() -> Zeroizing<String> {
    crypto::format_recovery(&[0x66; 16])
}
fn opened(secure: bool) -> Opened {
    let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let vault = document();
    let bytes = seal_inner(
        &[plain()],
        secure.then_some((&vault, &root)),
        PASSWORD,
        2000,
    )
    .unwrap();
    open(&bytes, PASSWORD).unwrap()
}
fn setup(secure: bool, existing: bool) -> (tempfile::TempDir, Library) {
    let directory = tempfile::tempdir().unwrap();
    let mut library = Library::open(directory.path().into()).unwrap();
    if existing {
        let mut old = plain();
        old.content = "Public old ordinary body".into();
        library.save(old, None).unwrap();
    }
    if secure {
        fs::DirBuilder::new()
            .mode(0o700)
            .create(directory.path().join("Vault"))
            .unwrap();
        let mut old = document();
        old.records[0].metadata.name = "Public old secure name".into();
        old.extra
            .insert("publicLocalOnly".into(), serde_json::json!(true));
        model::atomic_write(
            &directory.path().join("Vault/vault.json"),
            &old.encode().unwrap(),
        )
        .unwrap();
    }
    (directory, library)
}
fn commit(review: Review, library: &Library, fault: Option<u8>) -> Result<(usize, usize)> {
    let new_passphrase = review.needs_new_passphrase().then_some(LOCAL_PASSPHRASE);
    review.commit_inner(
        library,
        PASSWORD,
        Some((&credential(), true)),
        new_passphrase,
        &|| Ok(()),
        2000,
        fault,
    )
}
#[test]
fn restores_new_and_matching_vaults_and_keeps_current_doors_exact() {
    for existing_vault in [false, true] {
        let (_directory, mut library) = setup(existing_vault, true);
        let before = Images::read(&library.root).unwrap();
        let review = Review::prepare(&library, opened(true)).unwrap();
        assert_eq!(review.counts(), (1, 1));
        assert_eq!(review.needs_vault(), existing_vault);
        assert_eq!(commit(review, &library, None).unwrap(), (1, 1));
        library.reload_catalogue().unwrap();
        assert!(library.snippets == vec![plain()]);
        let vault = crate::vault::read_document(&library.root).unwrap().unwrap();
        assert!(vault.records[0].sealed == document().records[0].sealed);
        assert!(vault.records[0].metadata.name == document().records[0].metadata.name);
        if existing_vault {
            let old = Document::decode(before.vault.as_ref().unwrap()).unwrap();
            assert!(
                vault.kdf == old.kdf
                    && vault.wrap_pass == old.wrap_pass
                    && vault.wrap_cli == old.wrap_cli
                    && vault.wrap_recovery == old.wrap_recovery
            );
            assert!(vault.extra["publicLocalOnly"] == serde_json::json!(true));
            assert!(vault.extra.contains_key("local.syncConflictC0Receipts.v1"));
            assert!(vault.records[0].hlc > old.records[0].hlc);
        } else {
            assert!(!vault.extra.contains_key("local.syncConflictC0Receipts.v1"));
            vault
                .with_backup_key(LOCAL_PASSPHRASE, false, |key| {
                    assert!(key.same_key(&RootKey::from_bytes(&[0x11; 32]).unwrap()));
                    Ok(())
                })
                .unwrap();
            vault
                .with_backup_key(&credential(), true, |key| {
                    assert!(key.same_key(&RootKey::from_bytes(&[0x11; 32]).unwrap()));
                    Ok(())
                })
                .unwrap();
        }
        assert!(!library.root.join("Sync").exists());
        assert!(!pending(&library.root).unwrap());
        for path in [
            library.path(),
            library.root.join("Vault/vault.json"),
            library.root.join("Backups/identity.bin"),
        ] {
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        assert_eq!(
            fs::metadata(library.root.join("Backups"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        let after = Images::read(&library.root).unwrap();
        let clock = model::read_regular(&library.root.join("device.json")).unwrap();
        commit(
            Review::prepare(&library, opened(true)).unwrap(),
            &library,
            None,
        )
        .unwrap();
        assert!(Images::read(&library.root).unwrap() == after);
        assert!(model::read_regular(&library.root.join("device.json")).unwrap() == clock);
    }
}
#[test]
fn ordinary_upsert_matches_id_then_keyword_without_reassigning_local_identity() {
    let (_directory, mut library) = setup(false, false);
    let mut old = plain();
    old.id = Uuid::from_u128(9);
    old.created_at = 111.5;
    old.keyword = "PUBLIC-BACKUP".into();
    library.save(old.clone(), None).unwrap();
    commit(
        Review::prepare(&library, opened(false)).unwrap(),
        &library,
        None,
    )
    .unwrap();
    library.reload().unwrap();
    assert_eq!(library.snippets.len(), 1);
    let merged = &library.snippets[0];
    assert!(merged.id == old.id && merged.created_at == old.created_at);
    assert!(merged.content == plain().content && merged.updated_at == plain().updated_at);
    // The same-ID match cannot steal a keyword held by another original row.
    let mut other = Snippet::new("Public other", "Public other body");
    other.keyword = "other".into();
    library.save(other.clone(), None).unwrap();
    let mut incoming = opened(false);
    incoming.snippets[0].id = old.id;
    incoming.snippets[0].keyword = other.keyword;
    let before = Images::read(&library.root).unwrap();
    assert!(Review::prepare(&library, incoming).is_err());
    assert!(Images::read(&library.root).unwrap() == before);
}
#[test]
fn all_cross_kind_collisions_refuse_before_any_primary_write() {
    for case in 0..2 {
        let (_directory, library) = setup(true, true);
        let mut incoming = opened(true);
        let secure = &document().records[0].metadata;
        match case {
            0 => incoming.snippets[0].id = secure.id,
            1 => incoming.snippets[0].keyword = secure.keyword.to_uppercase(),
            _ => unreachable!(),
        }
        let before = Images::read(&library.root).unwrap();
        assert!(Review::prepare(&library, incoming).is_err());
        assert!(Images::read(&library.root).unwrap() == before);
        assert!(!library.root.join("Backups").exists());
    }
    // Incoming secure records cannot replace an ordinary record even without
    // any existing vault.
    for by_keyword in [false, true] {
        let (_directory, mut library) = setup(false, false);
        let secure = document().records[0].metadata.clone();
        let mut row = Snippet::new("Public reserved ordinary", "Public body");
        if by_keyword {
            row.keyword = secure.keyword;
        } else {
            row.id = secure.id;
        }
        library.save(row, None).unwrap();
        let before = Images::read(&library.root).unwrap();
        assert!(Review::prepare(&library, opened(true)).is_err());
        assert!(Images::read(&library.root).unwrap() == before);
    }
}
#[test]
fn incompatible_identity_wrong_key_and_missing_fresh_auth_keep_both_files() {
    for case in 0..5 {
        let (_directory, library) = setup(true, true);
        if case < 2 {
            let mut current = document();
            if case == 0 {
                current.kid = "v-public-other".into();
            } else {
                current.vault_salt = crypto::b64(&[0x44; 32]);
            }
            model::atomic_write(
                &library.root.join("Vault/vault.json"),
                &current.encode().unwrap(),
            )
            .unwrap();
            let before = Images::read(&library.root).unwrap();
            assert!(Review::prepare(&library, opened(true)).is_err());
            assert!(Images::read(&library.root).unwrap() == before);
            continue;
        }
        if case == 2 {
            let mut current = document();
            let root = RootKey::from_bytes(&[0x22; 32]).unwrap();
            current.wrap_recovery = Some(
                crypto::wrap_recovery(&root, &[0x66; 16], &current.salt().unwrap(), &current.kid)
                    .unwrap(),
            );
            model::atomic_write(
                &library.root.join("Vault/vault.json"),
                &current.encode().unwrap(),
            )
            .unwrap();
        }
        let before = Images::read(&library.root).unwrap();
        let review = Review::prepare(&library, opened(true)).unwrap();
        let text = if case == 4 {
            crypto::format_recovery(&[0x77; 16])
        } else {
            credential()
        };
        assert!(
            review
                .commit_inner(
                    &library,
                    PASSWORD,
                    (case != 3).then_some((&text, true)),
                    None,
                    &|| Ok(()),
                    2000,
                    None
                )
                .is_err()
        );
        assert!(Images::read(&library.root).unwrap() == before);
        assert!(!library.root.join("Backups").exists());
    }
}
#[test]
fn ordinary_only_import_keeps_vault_and_requires_no_vault_authentication() {
    let (_directory, library) = setup(true, true);
    let vault = Images::read(&library.root).unwrap().vault;
    Review::prepare(&library, opened(false))
        .unwrap()
        .commit_inner(&library, PASSWORD, None, None, &|| Ok(()), 2000, None)
        .unwrap();
    assert!(Images::read(&library.root).unwrap().vault == vault);
}
#[test]
fn each_durable_interruption_gates_readers_and_recovers_exact_two_file_images() {
    for fault in 0..4 {
        for existing_vault in [false, true] {
            let (_directory, library) = setup(existing_vault, true);
            let review = Review::prepare(&library, opened(true)).unwrap();
            assert!(commit(review, &library, Some(fault)).is_err());
            assert!(pending(&library.root).unwrap());
            let before_recovery = Images::read(&library.root).unwrap();
            let redo = fs::read(library.root.join("Backups/restore.pending")).unwrap();
            for text in [
                PASSWORD,
                "Public old ordinary body",
                &plain().content,
                &plain().name,
                &document().records[0].metadata.name,
            ] {
                assert!(!redo.windows(text.len()).any(|v| v == text.as_bytes()));
            }
            assert_eq!(
                fs::metadata(library.root.join("Backups/restore.pending"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
            assert!(Library::open(library.root.clone()).is_err());
            assert!(crate::vault::read_document(&library.root).is_err());
            let (gated, readiness) = Library::open_recoverable(library.root.clone()).unwrap();
            assert_eq!(readiness, crate::primary::Readiness::RecoveryRequired);
            assert!(gated.snippets.is_empty());
            assert!(recover(&gated, "Wrong public password", &|| Ok(())).is_err());
            assert!(Images::read(&library.root).unwrap() == before_recovery);
            assert!(fs::read(library.root.join("Backups/restore.pending")).unwrap() == redo);
            recover(&gated, PASSWORD, &|| Ok(())).unwrap();
            let reopened = Library::open(library.root.clone()).unwrap();
            assert!(reopened.snippets == vec![plain()]);
            let vault = crate::vault::read_document(&library.root).unwrap().unwrap();
            assert!(vault.records[0].sealed == document().records[0].sealed);
            assert!(!pending(&library.root).unwrap());
            assert!(!library.root.join("Sync").exists());
        }
    }
}
#[test]
fn cancellation_before_and_after_publication_never_drops_recovery_ownership() {
    for stop in 1..=13 {
        let (_directory, library) = setup(true, true);
        let before = Images::read(&library.root).unwrap();
        let calls = Cell::new(0);
        let result = Review::prepare(&library, opened(true))
            .unwrap()
            .commit_inner(
                &library,
                PASSWORD,
                Some((&credential(), true)),
                None,
                &|| {
                    calls.set(calls.get() + 1);
                    if calls.get() == stop {
                        Err(Error("Public cancelled fixture"))
                    } else {
                        Ok(())
                    }
                },
                2000,
                None,
            );
        assert!(
            result.is_err(),
            "cancellation boundary {stop} was not reached"
        );
        if stop <= 7 {
            assert!(!pending(&library.root).unwrap());
            assert!(Images::read(&library.root).unwrap() == before);
        } else {
            assert!(pending(&library.root).unwrap());
            recover(&library, PASSWORD, &|| Ok(())).unwrap();
            assert!(Library::open(library.root.clone()).unwrap().snippets == vec![plain()]);
        }
    }
}
#[test]
fn stale_review_and_unexpected_recovery_images_refuse_without_overwrite() {
    for changed_vault in [false, true] {
        let (_directory, library) = setup(true, true);
        let review = Review::prepare(&library, opened(true)).unwrap();
        if changed_vault {
            let mut vault = document();
            vault.records[0].metadata.name = "Public outside secure edit".into();
            model::atomic_write(
                &library.root.join("Vault/vault.json"),
                &vault.encode().unwrap(),
            )
            .unwrap();
        } else {
            model::atomic_write(&library.path(), b"[]").unwrap();
        }
        let after_edit = Images::read(&library.root).unwrap();
        assert!(commit(review, &library, None).is_err());
        assert!(Images::read(&library.root).unwrap() == after_edit);
        assert!(!pending(&library.root).unwrap());
    }
    let (_directory, library) = setup(true, true);
    assert!(
        commit(
            Review::prepare(&library, opened(true)).unwrap(),
            &library,
            Some(1)
        )
        .is_err()
    );
    model::atomic_write(&library.path(), b"[]").unwrap();
    let changed = Images::read(&library.root).unwrap();
    assert!(recover(&library, PASSWORD, &|| Ok(())).is_err());
    assert!(Images::read(&library.root).unwrap() == changed);
    assert!(pending(&library.root).unwrap());
}
#[test]
fn tampered_redo_wrong_root_and_wrong_password_refuse_before_primary_reads() {
    for case in 0..4 {
        let (_directory, library) = setup(true, true);
        assert!(
            commit(
                Review::prepare(&library, opened(true)).unwrap(),
                &library,
                Some(0)
            )
            .is_err()
        );
        let path = library.root.join("Backups/restore.pending");
        if case == 0 {
            let mut bytes = fs::read(&path).unwrap();
            *bytes.last_mut().unwrap() ^= 1;
            model::atomic_write(&path, &bytes).unwrap();
        } else if case == 1 {
            model::atomic_write(&library.root.join("Backups/identity.bin"), &[0x77; 32]).unwrap();
        }
        let other = tempfile::tempdir().unwrap();
        let target = if case == 2 {
            let foreign = Library::prepare(other.path().into()).unwrap();
            identity(&foreign.root, true).unwrap();
            model::atomic_write(
                &foreign.root.join("Backups/restore.pending"),
                &fs::read(&path).unwrap(),
            )
            .unwrap();
            foreign
        } else {
            Library::prepare(library.root.clone()).unwrap()
        };
        fs::remove_file(target.path()).ok();
        symlink("/public-never-read-by-backup-recovery", target.path()).unwrap();
        let result = recover(
            &target,
            if case == 3 {
                "Wrong public password"
            } else {
                PASSWORD
            },
            &|| Ok(()),
        );
        assert!(result.is_err());
        let error = result.unwrap_err();
        assert!(error == INVALID_REDO || error.0.contains("password"));
        assert!(pending(&target.root).unwrap());
        assert!(
            fs::symlink_metadata(target.path())
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
}
#[test]
fn backup_fence_refuses_cloud_recovery_and_unsafe_storage_without_touching_sync() {
    let (_directory, library) = setup(true, true);
    assert!(
        commit(
            Review::prepare(&library, opened(true)).unwrap(),
            &library,
            Some(0)
        )
        .is_err()
    );
    let root = RootKey::from_bytes(&[0x33; 32]).unwrap();
    let scope = crate::journal::Scope {
        membership: crate::cloud::Binding::from_checkpoint([0x33; 32]),
        dataset: crate::cloud::Binding::from_checkpoint([0x44; 32]),
    };
    assert!(crate::primary::recover(&library.root, &root, &[0x44; 32], scope).is_err());
    assert!(!library.root.join("Sync").exists());
    let redo = library.root.join("Backups/restore.pending");
    let bytes = fs::read(&redo).unwrap();
    fs::remove_file(&redo).unwrap();
    let public = library.root.join("public-ciphertext");
    model::atomic_write(&public, &bytes).unwrap();
    symlink(&public, &redo).unwrap();
    assert!(pending(&library.root).is_err());
    assert!(recover(&library, PASSWORD, &|| Ok(())).is_err());
    fs::remove_file(&redo).unwrap();
    fs::hard_link(&public, &redo).unwrap();
    assert!(pending(&library.root).is_err());
    assert!(recover(&library, PASSWORD, &|| Ok(())).is_err());
}
#[test]
fn good_backup_repairs_a_damaged_live_secure_seal_without_changing_other_records() {
    let (_directory, library) = setup(true, true);
    let mut current = document();
    // A structurally valid seal made with a foreign key is a damaged local
    // record. Fresh door authentication still succeeds with the real root.
    current.records[0].sealed = crypto::seal_record(
        b"Public damaged replacement",
        &RootKey::from_bytes(&[0x22; 32]).unwrap(),
        &current.salt().unwrap(),
        &current.kid,
        current.records[0].metadata.id,
        false,
    )
    .unwrap();
    model::atomic_write(
        &library.root.join("Vault/vault.json"),
        &current.encode().unwrap(),
    )
    .unwrap();
    commit(
        Review::prepare(&library, opened(true)).unwrap(),
        &library,
        None,
    )
    .unwrap();
    let restored = crate::vault::read_document(&library.root).unwrap().unwrap();
    assert!(restored.records[0].sealed == document().records[0].sealed);
    let body = crypto::open_record(
        &restored.records[0].sealed,
        &RootKey::from_bytes(&[0x11; 32]).unwrap(),
        &restored.salt().unwrap(),
        &restored.kid,
        restored.records[0].metadata.id,
        false,
    )
    .unwrap();
    crypto::verify_hash(
        &restored.records[0].content_hash,
        &body,
        &RootKey::from_bytes(&[0x11; 32]).unwrap(),
        &restored.salt().unwrap(),
    )
    .unwrap();
}
#[test]
fn empty_backup_is_a_true_noop_and_foreign_review_root_refuses_both_files() {
    let (_directory, library) = setup(false, false);
    let empty = Opened {
        snippets: Vec::new(),
        vault: None,
        vault_key: None,
    };
    assert_eq!(
        commit(Review::prepare(&library, empty).unwrap(), &library, None).unwrap(),
        (0, 0)
    );
    assert!(!library.path().exists());
    assert!(!library.root.join("Backups").exists());
    assert!(!library.root.join("Sync").exists());
    let (_other_directory, other) = setup(true, true);
    let before = Images::read(&other.root).unwrap();
    let review = Review::prepare(&library, opened(true)).unwrap();
    assert!(commit(review, &other, None).is_err());
    assert!(Images::read(&other.root).unwrap() == before);
    assert!(!pending(&other.root).unwrap());
    assert!(!library.root.join("Backups").exists());
}
#[test]
fn edited_authenticated_owner_and_header_kdf_bounds_cannot_publish_or_recover() {
    let (_directory, library) = setup(false, false);
    let mut input = opened(true);
    input.vault.as_mut().unwrap().records[0].content_hash = "0".repeat(32);
    assert!(Review::prepare(&library, input).is_err());
    assert!(!library.root.join("Backups").exists());
    assert!(
        commit(
            Review::prepare(&library, opened(true)).unwrap(),
            &library,
            Some(0)
        )
        .is_err()
    );
    let path = library.root.join("Backups/restore.pending");
    let bytes = fs::read(&path).unwrap();
    let header_size = u32::from_be_bytes(bytes[4..8].try_into().unwrap()) as usize;
    let before = Images::read(&library.root).unwrap();
    for iterations in [0, 20_000_001, u32::MAX] {
        let mut header: Header = serde_json::from_slice(&bytes[8..8 + header_size]).unwrap();
        header.kdf.iterations = iterations;
        let encoded = serde_json::to_vec(&header).unwrap();
        let mut changed = b"SBR1".to_vec();
        changed.extend_from_slice(&(encoded.len() as u32).to_be_bytes());
        changed.extend_from_slice(&encoded);
        changed.extend_from_slice(&bytes[8 + header_size..]);
        model::atomic_write(&path, &changed).unwrap();
        assert!(recover(&library, PASSWORD, &|| Ok(())).is_err());
        assert!(Images::read(&library.root).unwrap() == before);
        assert!(pending(&library.root).unwrap());
    }
}
#[test]
fn indexed_batch_preserves_id_keyword_precedence_creation_dates_and_front_order() {
    let (_directory, library) = setup(false, false);
    let mut before = Vec::new();
    let mut incoming = Vec::new();
    for index in 0..2000 {
        let mut row = Snippet::new("Public batch row", "Public old batch body");
        row.id = Uuid::from_u128(index + 100);
        row.keyword = format!("public-batch-{index}");
        row.created_at = 1.0;
        row.updated_at = 2.0;
        let mut replacement = row.clone();
        replacement.content = "Public restored batch body".into();
        replacement.created_at = 3.0;
        replacement.updated_at = 4.0;
        if index % 2 == 0 {
            replacement.keyword = format!("public-replaced-{index}");
        } else {
            replacement.id = Uuid::from_u128(index + 100_000);
        }
        before.push(row);
        incoming.push(replacement);
    }
    for index in 0..20 {
        let mut row = Snippet::new("Public new batch row", "Public new batch body");
        row.id = Uuid::from_u128(index + 200_000);
        row.keyword = format!("public-new-{index}");
        incoming.push(row);
    }
    model::atomic_write(
        &library.path(),
        &model::encode_library(&before, false).unwrap(),
    )
    .unwrap();
    let input = Opened {
        snippets: incoming,
        vault: None,
        vault_key: None,
    };
    assert_eq!(
        commit(Review::prepare(&library, input).unwrap(), &library, None).unwrap(),
        (2020, 0)
    );
    let restored = Library::open(library.root.clone()).unwrap();
    assert_eq!(restored.snippets.len(), 2020);
    for (index, row) in restored.snippets[..20].iter().enumerate() {
        assert!(row.id == Uuid::from_u128(200_019 - index as u128));
    }
    for (index, row) in restored.snippets[20..].iter().enumerate() {
        assert!(row.id == before[index].id);
        assert_eq!(row.created_at, if index % 2 == 0 { 3.0 } else { 1.0 });
        assert!(row.content == "Public restored batch body");
    }
}
#[test]
fn new_vault_requires_a_valid_local_door_and_existing_vault_rejects_door_replacement() {
    for passphrase in [None, Some("short"), Some("Public valid passphrase")] {
        let (_directory, library) = setup(false, false);
        let review = Review::prepare(&library, opened(true)).unwrap();
        assert!(review.needs_new_passphrase());
        let result =
            review.commit_inner(&library, PASSWORD, None, passphrase, &|| Ok(()), 2000, None);
        if passphrase.is_some_and(|text| text.chars().count() >= 12) {
            result.unwrap();
            let vault = crate::vault::read_document(&library.root).unwrap().unwrap();
            vault
                .with_backup_key(passphrase.unwrap(), false, |key| {
                    assert!(key.same_key(&RootKey::from_bytes(&[0x11; 32]).unwrap()));
                    Ok(())
                })
                .unwrap();
        } else {
            assert!(result.is_err());
            assert!(!library.path().exists());
            assert!(!library.root.join("Vault").exists());
            assert!(!library.root.join("Backups").exists());
        }
    }
    let (_directory, library) = setup(true, true);
    let before = Images::read(&library.root).unwrap();
    let review = Review::prepare(&library, opened(true)).unwrap();
    assert!(!review.needs_new_passphrase());
    assert!(
        review
            .commit_inner(
                &library,
                PASSWORD,
                Some((&credential(), true)),
                Some("Public unwanted replacement"),
                &|| Ok(()),
                2000,
                None
            )
            .is_err()
    );
    assert!(Images::read(&library.root).unwrap() == before);
    assert!(!library.root.join("Backups").exists());
}
