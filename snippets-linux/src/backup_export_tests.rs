use super::*;
use std::{cell::Cell, os::unix::fs::symlink};
fn setup(secure: bool) -> (tempfile::TempDir, tempfile::TempDir, Library) {
    let root = tempfile::tempdir().unwrap();
    let destination = tempfile::tempdir().unwrap();
    let mut library = Library::open(root.path().into()).unwrap();
    library.save(super::super::tests::plain(), None).unwrap();
    if secure {
        fs::create_dir(root.path().join("Vault")).unwrap();
        model::atomic_write(
            &root.path().join("Vault/vault.json"),
            &super::super::tests::document().encode().unwrap(),
        )
        .unwrap();
    }
    (root, destination, library)
}
fn credential() -> Zeroizing<String> {
    crypto::format_recovery(&[0x66; 16])
}
#[test]
fn encrypted_only_export_preserves_live_files_and_publishes_private_modes() {
    for secure in [false, true] {
        let (_root, out, library) = setup(secure);
        let before = fs::read(library.path()).unwrap();
        let vault_before = model::read_regular(&library.root.join("Vault/vault.json")).unwrap();
        let snapshot = Snapshot::read(&library).unwrap();
        let path = out.path().join("public.snippetsbackup");
        assert_eq!(
            snapshot
                .write_inner(
                    &library,
                    &path,
                    "Public backup passphrase",
                    secure.then_some((credential().as_str(), true)),
                    &|| Ok(()),
                    2000
                )
                .unwrap(),
            (1, usize::from(secure))
        );
        assert!(fs::read(library.path()).unwrap() == before);
        assert!(
            model::read_regular(&library.root.join("Vault/vault.json")).unwrap() == vault_before
        );
        assert!(!library.root.join("Sync").exists());
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let opened = open(&fs::read(&path).unwrap(), "Public backup passphrase").unwrap();
        assert_eq!(opened.counts(), snapshot.counts());
    }
}
#[test]
fn cancellation_at_every_boundary_keeps_both_library_files_and_the_previous_export() {
    for stop in 1..=6 {
        let (_root, out, library) = setup(true);
        let snapshot = Snapshot::read(&library).unwrap();
        let path = out.path().join("public.snippetsbackup");
        fs::write(&path, b"public-existing-sentinel").unwrap();
        let calls = Cell::new(0);
        assert!(
            snapshot
                .write_inner(
                    &library,
                    &path,
                    "Public backup passphrase",
                    Some((&credential(), true)),
                    &|| {
                        calls.set(calls.get() + 1);
                        if calls.get() == stop {
                            Err(EXPIRED)
                        } else {
                            Ok(())
                        }
                    },
                    2000
                )
                .is_err()
        );
        assert!(fs::read(&path).unwrap() == b"public-existing-sentinel");
        assert_eq!(fs::read_dir(out.path()).unwrap().count(), 1);
        assert!(Snapshot::read(&library).unwrap().plain_before == snapshot.plain_before);
        assert!(Snapshot::read(&library).unwrap().vault_before == snapshot.vault_before);
    }
}
#[test]
fn changed_primary_or_vault_and_pending_redo_refuse_publication() {
    for change in 0..3 {
        let (_root, out, library) = setup(true);
        let snapshot = Snapshot::read(&library).unwrap();
        let path = out.path().join("public.snippetsbackup");
        let calls = Cell::new(0);
        assert!(
            snapshot
                .write_inner(
                    &library,
                    &path,
                    "Public backup passphrase",
                    Some((&credential(), true)),
                    &|| {
                        calls.set(calls.get() + 1);
                        if calls.get() == 4 {
                            match change {
                                0 => model::atomic_write(&library.path(), b"[]").unwrap(),
                                1 => {
                                    let mut vault = snapshot.vault.clone().unwrap();
                                    vault.records[0].metadata.name =
                                        "Public changed metadata".into();
                                    model::atomic_write(
                                        &library.root.join("Vault/vault.json"),
                                        &vault.encode().unwrap(),
                                    )
                                    .unwrap();
                                }
                                _ => {
                                    fs::create_dir(library.root.join("Sync")).unwrap();
                                    fs::write(
                                        library.root.join("Sync/primary.pending"),
                                        b"public-incomplete-marker",
                                    )
                                    .unwrap();
                                }
                            }
                        }
                        Ok(())
                    },
                    2000
                )
                .is_err()
        );
        assert!(!path.exists());
    }
}
#[test]
fn unauthenticated_and_unsafe_destinations_never_overwrite_live_data_or_links() {
    let (_root, out, library) = setup(true);
    let snapshot = Snapshot::read(&library).unwrap();
    let path = out.path().join("public.snippetsbackup");
    assert!(
        snapshot
            .write_inner(
                &library,
                &path,
                "Public backup passphrase",
                None,
                &|| Ok(()),
                2000
            )
            .is_err()
    );
    assert!(
        snapshot
            .write_inner(
                &library,
                &path,
                "Public backup passphrase",
                Some(("wrong public credential", true)),
                &|| Ok(()),
                2000
            )
            .is_err()
    );
    assert!(!path.exists());
    let before = fs::read(library.path()).unwrap();
    let linked = out.path().join("public-link");
    symlink(library.path(), &linked).unwrap();
    for path in [linked, library.path(), out.path().to_owned()] {
        assert!(
            snapshot
                .write_inner(
                    &library,
                    &path,
                    "Public backup passphrase",
                    Some((&credential(), true)),
                    &|| Ok(()),
                    2000
                )
                .is_err()
        );
    }
    assert!(fs::read(library.path()).unwrap() == before);
}
#[test]
fn authorization_cannot_survive_cancel_expiry_stale_observation_or_lock_then_unlock() {
    let witness = SessionWitness::test(SessionState::Unlocked, 11);
    let token = Authorization::new(witness.clone()).unwrap();
    assert!(token.validate().is_ok());
    assert!(token.validate_at(token.deadline).is_err());
    witness.test_observe(SessionState::Locked);
    witness.test_observe(SessionState::Unlocked);
    assert!(token.validate().is_err());
    let token = Authorization::new(witness.clone()).unwrap();
    token.clone().cancel();
    assert!(token.validate().is_err());
    witness.test_observe(SessionState::Unavailable);
    assert!(Authorization::new(witness).is_err());
}

#[test]
fn cancellation_after_encryption_and_during_the_real_file_lock_wait_prevents_publication() {
    use std::sync::atomic::AtomicUsize;
    let (_root, out, library) = setup(true);
    let second = Library::open(library.root.clone()).unwrap();
    let snapshot = Snapshot::read(&library).unwrap();
    let path = out.path().join("public.snippetsbackup");
    let saved_path = path.clone();
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancellation = cancelled.clone();
    let calls = Arc::new(AtomicUsize::new(0));
    let observed = calls.clone();
    let (send, receive) = std::sync::mpsc::sync_channel(1);
    let held_lock = library.lock().unwrap();
    let thread = std::thread::spawn(move || {
        snapshot.write_inner(
            &second,
            &path,
            "Public backup passphrase",
            Some((&credential(), true)),
            &|| {
                let call = calls.fetch_add(1, Ordering::Relaxed) + 1;
                if call == 4 {
                    send.send(()).unwrap();
                    return Ok(());
                }
                if cancellation.load(Ordering::Acquire) {
                    Err(EXPIRED)
                } else {
                    Ok(())
                }
            },
            2000,
        )
    });
    receive.recv_timeout(Duration::from_secs(10)).unwrap();
    cancelled.store(true, Ordering::Release);
    drop(held_lock);
    assert!(thread.join().unwrap().is_err());
    assert_eq!(observed.load(Ordering::Relaxed), 5);
    assert!(!saved_path.exists());
    assert_eq!(fs::read_dir(out.path()).unwrap().count(), 0);
}

#[test]
fn an_empty_vault_is_omitted_and_snapshot_refuses_a_foreign_library_root() {
    let (_root, out, library) = setup(true);
    let mut document = super::super::tests::document();
    document.records.clear();
    model::atomic_write(
        &library.root.join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let snapshot = Snapshot::read(&library).unwrap();
    assert!(!snapshot.needs_vault());
    assert_eq!(snapshot.counts(), (1, 0));
    let another = tempfile::tempdir().unwrap();
    let other = Library::open(another.path().into()).unwrap();
    let path = out.path().join("public.snippetsbackup");
    assert!(
        snapshot
            .write_inner(
                &other,
                &path,
                "Public backup passphrase",
                None,
                &|| Ok(()),
                2000
            )
            .is_err()
    );
    assert!(!path.exists());
    snapshot
        .write_inner(
            &library,
            &path,
            "Public backup passphrase",
            None,
            &|| Ok(()),
            2000,
        )
        .unwrap();
    assert!(
        open(&fs::read(&path).unwrap(), "Public backup passphrase")
            .unwrap()
            .vault
            .is_none()
    );
}
