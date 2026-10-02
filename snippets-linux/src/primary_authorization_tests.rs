//! Revocation across the common lock and both-image WAL, using public fixtures.
use super::*;
use std::{
    cell::Cell,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::Duration,
};

#[test]
fn cancellation_while_waiting_for_the_common_lock_never_publishes_a_marker_or_wal() {
    let temporary = tempfile::tempdir().unwrap();
    let library = Library::open(temporary.path().into()).unwrap();
    model::atomic_write(&library.path(), &model::encode_library(&[], false).unwrap()).unwrap();
    let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
    let incoming = envelope(&snippet(1, "Public guarded incoming record"), 10);
    let prepared = prepare(
        &library,
        &checkpoint.journal,
        "11111111",
        &[outcome(incoming.clone())],
        &BTreeMap::from([(incoming.id, None)]),
    )
    .unwrap();
    let before = fs::read(library.path()).unwrap();
    let held = library.lock().unwrap();
    let cancelled = AtomicBool::new(false);
    let (entered, observer) = mpsc::sync_channel(1);
    let result = std::thread::scope(|threads| {
        let waiting = threads.spawn(|| {
            let first = Cell::new(true);
            commit_checked(&library, &mut checkpoint, &key(), &SALT, prepared, &|| {
                if first.replace(false) {
                    entered.send(()).unwrap();
                }
                if cancelled.load(Ordering::Acquire) {
                    Err(Failure::AuthorizationExpired)
                } else {
                    Ok(())
                }
            })
        });
        let observed = observer.recv_timeout(Duration::from_secs(3));
        cancelled.store(true, Ordering::Release);
        drop(held);
        observed.unwrap();
        waiting.join().unwrap()
    });
    assert_eq!(result, Err(Failure::AuthorizationExpired));
    assert_eq!(fs::read(library.path()).unwrap(), before);
    assert!(marker(temporary.path()).unwrap().is_none());
    assert!(!temporary.path().join("Sync").exists());
}

#[test]
fn revocation_at_each_publication_boundary_keeps_authenticated_before_or_after_images() {
    // The first five boundaries precede the WAL; later boundaries must retain
    // enough encrypted redo to finish the original authenticated transaction.
    for revoke_at in 1..=9 {
        let temporary = tempfile::tempdir().unwrap();
        let library = Library::open(temporary.path().into()).unwrap();
        model::atomic_write(&library.path(), &model::encode_library(&[], false).unwrap()).unwrap();
        let document = vault_fixture();
        install_vault(temporary.path(), &document);
        let mut checkpoint = Checkpoint::load(&library, &key(), &SALT, scope()).unwrap();
        let (merged, expected, copy_id) =
            secure_to_plain_conflict(&library, &checkpoint.journal, &document);
        let source_id = merged.survivor.as_ref().unwrap().id;
        let root = RootKey::from_bytes(&[0x11; 32]).unwrap();
        let prepared = prepare_authenticated(
            &library,
            &checkpoint.journal,
            "11111111",
            &[merged],
            &expected,
            &Keyring::new(&root, &document).unwrap(),
        )
        .unwrap();
        drop(root);
        let before_plain = fs::read(library.path()).unwrap();
        let before_vault = fs::read(temporary.path().join("Vault/vault.json")).unwrap();
        let after_plain = prepared.intent.after_plain.clone().unwrap();
        let after_vault = prepared.intent.after_vault.clone().unwrap();
        let calls = Cell::new(0);
        let result = commit_checked(&library, &mut checkpoint, &key(), &SALT, prepared, &|| {
            calls.set(calls.get() + 1);
            if calls.get() >= revoke_at {
                Err(Failure::AuthorizationExpired)
            } else {
                Ok(())
            }
        });
        assert_eq!(calls.get(), revoke_at);
        assert_eq!(
            result,
            Err(if revoke_at < 5 {
                Failure::AuthorizationExpired
            } else {
                Failure::RecoveryRequired
            })
        );
        if revoke_at < 5 {
            assert!(marker(temporary.path()).unwrap().is_none());
        } else {
            assert!(marker(temporary.path()).unwrap().is_some());
            assert!(library.read().is_err());
        }
        // Recovery uses only the checkpoint key: no current-vault RootKey,
        // credential, desktop grant or newly generated conflict seal.
        let recovered = recover(temporary.path(), &key(), &SALT, scope()).unwrap();
        assert!(marker(temporary.path()).unwrap().is_none());
        assert!(recovered.journal.primary_intent.is_none());
        if revoke_at <= 5 {
            assert_eq!(fs::read(library.path()).unwrap(), before_plain);
            assert_eq!(
                fs::read(temporary.path().join("Vault/vault.json")).unwrap(),
                before_vault
            );
            assert!(actual(&library, &recovered.journal)[&source_id].secure);
        } else {
            assert_eq!(
                fs::read(library.path()).unwrap().as_slice(),
                after_plain.as_slice()
            );
            assert_eq!(
                fs::read(temporary.path().join("Vault/vault.json"))
                    .unwrap()
                    .as_slice(),
                after_vault.as_slice()
            );
            let current = actual(&library, &recovered.journal);
            assert!(!current[&source_id].secure && current[&copy_id].secure);
            assert!(current[&copy_id] == recovered.journal.conflict_snapshots()[&copy_id]);
        }
    }
}
