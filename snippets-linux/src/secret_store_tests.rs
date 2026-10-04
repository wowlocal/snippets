//! Only fictional bytes and temporary roots; native tests use an isolated bus.
use super::*;
use std::{
    collections::BTreeMap,
    os::unix::fs::symlink,
    sync::{Arc, Mutex},
};
#[derive(Clone, Default)]
pub(crate) struct Memory(pub(crate) Arc<Mutex<MemoryState>>);
#[derive(Default)]
pub(crate) struct MemoryState {
    values: BTreeMap<([u8; 16], Slot), Zeroizing<Vec<u8>>>,
    pub(crate) fail_read: Option<Failure>,
    pub(crate) fail_write_after: bool,
}
impl Backend for Memory {
    fn read(&mut self, namespace: &[u8; 16], slot: Slot) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let state = self.0.lock().unwrap();
        if let Some(error) = state.fail_read {
            return Err(error);
        }
        Ok(state.values.get(&(*namespace, slot)).cloned())
    }
    fn write(&mut self, namespace: &[u8; 16], slot: Slot, value: &[u8]) -> Result<()> {
        let mut state = self.0.lock().unwrap();
        state
            .values
            .insert((*namespace, slot), Zeroizing::new(value.to_vec()));
        if state.fail_write_after {
            return Err(Failure::Unavailable);
        }
        Ok(())
    }
    fn delete(&mut self, namespace: &[u8; 16], slot: Slot) -> Result<()> {
        self.0.lock().unwrap().values.remove(&(*namespace, slot));
        Ok(())
    }
}
#[test]
fn namespace_is_opt_in_private_and_never_contains_secret_bytes() {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    assert!(matches!(
        Store::load(temp.path(), memory.clone()),
        Err(Failure::MissingOwner)
    ));
    assert!(!temp.path().join(OWNER_FILE).exists());
    let mut first = Store::initialize(temp.path(), memory.clone()).unwrap();
    let second = Store::initialize(temp.path(), memory.clone()).unwrap();
    assert!(first.namespace == second.namespace && memory.0.lock().unwrap().values.is_empty());
    first
        .transaction(|owner| {
            owner.replace(
                Slot::Credentials,
                None,
                Some(b"Public fictional credential never on disk"),
            )
        })
        .unwrap();
    for entry in fs::read_dir(temp.path()).unwrap() {
        let path = entry.unwrap().path();
        let bytes = fs::read(&path).unwrap();
        assert!(!bytes.windows(15).any(|v| v == b"Public fictiona"));
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
#[test]
fn competing_snapshots_and_ambiguous_promotion_require_reread() {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let mut first = Store::initialize(temp.path(), memory.clone()).unwrap();
    let mut second = Store::load(temp.path(), memory.clone()).unwrap();
    first
        .transaction(|owner| owner.replace(Slot::Credentials, None, Some(b"Public A")))
        .unwrap();
    let snapshot = second
        .transaction(|owner| owner.read(Slot::Credentials))
        .unwrap()
        .unwrap();
    first
        .transaction(|owner| owner.replace(Slot::Credentials, Some(b"Public A"), Some(b"Public B")))
        .unwrap();
    assert!(
        second.transaction(|owner| owner.replace(
            Slot::Credentials,
            Some(&snapshot),
            Some(b"Public C")
        )) == Err(Failure::Stale)
    );
    memory.0.lock().unwrap().fail_write_after = true;
    assert!(
        first.transaction(|owner| owner.replace(
            Slot::Credentials,
            Some(b"Public B"),
            Some(b"Public C")
        )) == Err(Failure::Unavailable)
    );
    memory.0.lock().unwrap().fail_write_after = false;
    let current = first
        .transaction(|owner| owner.read(Slot::Credentials))
        .unwrap()
        .unwrap();
    assert!(*current == b"Public C");
    first
        .transaction(|owner| owner.replace(Slot::Credentials, Some(&current), None))
        .unwrap();
    assert!(
        second
            .transaction(|owner| owner.read(Slot::Credentials))
            .unwrap()
            .is_none()
    );
}
#[test]
fn locked_missing_duplicate_and_corrupt_backends_never_become_empty_credentials() {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    for error in [
        Failure::Locked,
        Failure::Unavailable,
        Failure::Duplicate,
        Failure::InvalidValue,
        Failure::Timeout,
    ] {
        memory.0.lock().unwrap().fail_read = Some(error);
        assert!(
            store
                .transaction(|owner| owner.read(Slot::Credentials))
                .err()
                == Some(error)
        );
        assert!(
            store
                .transaction(|owner| owner.replace(Slot::Credentials, None, Some(b"New")))
                .err()
                == Some(error)
        );
    }
    assert!(memory.0.lock().unwrap().values.is_empty());
}
#[test]
fn lost_owner_or_checkpoint_key_never_mints_replacement_material() {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    fs::create_dir(temp.path().join("Sync")).unwrap();
    model::atomic_write(
        &temp.path().join("Sync/journal.bin"),
        b"Public ciphertext placeholder",
    )
    .unwrap();
    assert!(matches!(
        Store::initialize(temp.path(), memory.clone()),
        Err(Failure::MissingOwner)
    ));
    fs::remove_file(temp.path().join("Sync/journal.bin")).unwrap();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    assert!(
        store
            .transaction(|owner| owner.checkpoint_material(false))
            .unwrap()
            .is_none()
    );
    let material = store
        .transaction(|owner| owner.checkpoint_material(true))
        .unwrap()
        .unwrap();
    assert_eq!(material.len(), 64);
    assert!(
        *store
            .transaction(|owner| owner.checkpoint_material(true))
            .unwrap()
            .unwrap()
            == *material
    );
    store
        .transaction(|owner| owner.replace(Slot::CheckpointKey, Some(&material), None))
        .unwrap();
    model::atomic_write(
        &temp.path().join("Sync/journal.bin"),
        b"Public ciphertext placeholder",
    )
    .unwrap();
    assert!(
        store
            .transaction(|owner| owner.checkpoint_material(true))
            .err()
            == Some(Failure::MissingOwner)
    );
    assert!(memory.0.lock().unwrap().values.is_empty());
    fs::remove_file(temp.path().join(OWNER_FILE)).unwrap();
    assert!(
        store
            .transaction(|owner| owner.read(Slot::Credentials))
            .err()
            == Some(Failure::MissingOwner)
    );
}
#[test]
fn linked_owner_lock_and_sync_directories_fail_closed() {
    let temp = tempfile::tempdir().unwrap();
    let target = tempfile::tempdir().unwrap();
    symlink(target.path().join("missing"), temp.path().join(OWNER_FILE)).unwrap();
    assert!(Store::initialize(temp.path(), Memory::default()).is_err());
    fs::remove_file(temp.path().join(OWNER_FILE)).unwrap();
    let mut store = Store::initialize(temp.path(), Memory::default()).unwrap();
    symlink(target.path().join("lock"), temp.path().join("secrets.lock")).unwrap();
    assert!(
        store
            .transaction(|owner| owner.read(Slot::Credentials))
            .is_err()
    );
    fs::remove_file(temp.path().join("secrets.lock")).unwrap();
    symlink(target.path(), temp.path().join("Sync")).unwrap();
    assert!(
        store
            .transaction(|owner| owner.checkpoint_material(true))
            .is_err()
    );
}
#[test]
fn private_mutex_serializes_transitions_without_blocking_library_writers() {
    use std::{sync::mpsc, thread, time::Duration};
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let mut first = Store::initialize(temp.path(), memory.clone()).unwrap();
    let mut second = Store::load(temp.path(), memory).unwrap();
    let (start_tx, start_rx) = mpsc::channel();
    let (finish_tx, finish_rx) = mpsc::channel();
    first
        .transaction(|owner| {
            owner.replace(Slot::Credentials, None, Some(b"Public original"))?;
            let task = thread::spawn(move || {
                start_tx.send(()).unwrap();
                second
                    .transaction(|owner| {
                        owner.replace(
                            Slot::Credentials,
                            Some(b"Public finished"),
                            Some(b"Public later"),
                        )
                    })
                    .unwrap();
                finish_tx.send(()).unwrap();
            });
            start_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(finish_rx.recv_timeout(Duration::from_millis(100)).is_err());
            let library = Library::open(temp.path().into()).unwrap();
            let _library_guard = library.lock().unwrap();
            owner.replace(
                Slot::Credentials,
                Some(b"Public original"),
                Some(b"Public finished"),
            )?;
            Ok(task)
        })
        .unwrap()
        .join()
        .unwrap();
    finish_rx.recv_timeout(Duration::from_secs(5)).unwrap();
}

#[cfg(feature = "secret-service")]
#[test]
#[ignore = "invoke only through tests/secret-service.sh with a private keyring and bus"]
fn native_backend_fixture() {
    let root = std::env::var_os("SNIPPETS_SECRET_TEST_ROOT").expect("isolated root required");
    assert!(
        std::env::var("SNIPPETS_SECRET_TEST_BUS").unwrap()
            == std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap()
    );
    let mut store = Store::initialize(Path::new(&root), Native::new().unwrap()).unwrap();
    store
        .transaction(|owner| {
            assert!(
                owner
                    .read(Slot::Credentials)
                    .expect("isolated initial read")
                    .is_none()
            );
            let value = b"Public binary fixture\0with embedded zero";
            owner
                .replace(Slot::Credentials, None, Some(value))
                .expect("isolated binary create");
            assert!(*owner.read(Slot::Credentials)?.unwrap() == value);
            assert!(
                owner.replace(Slot::Credentials, Some(b"Wrong"), Some(b"No"))
                    == Err(Failure::Stale)
            );
            owner.replace(Slot::Credentials, Some(value), Some(b"Public replacement"))?;
            owner.replace(Slot::Credentials, Some(b"Public replacement"), None)?;
            assert!(owner.read(Slot::Credentials)?.is_none());
            owner.replace(Slot::PairingRecipient, None, Some(value))?;
            assert!(*owner.read(Slot::PairingRecipient)?.unwrap() == value);
            owner.replace(Slot::PairingRecipient, Some(value), None)?;
            assert!(owner.read(Slot::PairingRecipient)?.is_none());
            owner.replace(Slot::SpaceCreation, None, Some(value))?;
            assert!(*owner.read(Slot::SpaceCreation)?.unwrap() == value);
            owner.replace(Slot::SpaceCreation, Some(value), None)?;
            assert!(owner.read(Slot::SpaceCreation)?.is_none());
            owner.replace(Slot::KeyMutation, None, Some(value))?;
            assert!(*owner.read(Slot::KeyMutation)?.unwrap() == value);
            owner.replace(Slot::KeyMutation, Some(value), None)?;
            assert!(owner.read(Slot::KeyMutation)?.is_none());
            owner.replace(Slot::AccountReview, None, Some(value))?;
            assert!(*owner.read(Slot::AccountReview)?.unwrap() == value);
            owner.replace(Slot::AccountReview, Some(value), None)?;
            assert!(owner.read(Slot::AccountReview)?.is_none());
            owner.replace(Slot::PairingCandidate, None, Some(value))?;
            assert!(*owner.read(Slot::PairingCandidate)?.unwrap() == value);
            owner.replace(Slot::PairingCandidate, Some(value), None)?;
            assert!(owner.read(Slot::PairingCandidate)?.is_none());
            owner.replace(Slot::BootstrapCandidate, None, Some(value))?;
            assert!(*owner.read(Slot::BootstrapCandidate)?.unwrap() == value);
            owner.replace(Slot::BootstrapCandidate, Some(value), None)?;
            assert!(owner.read(Slot::BootstrapCandidate)?.is_none());
            owner.replace(Slot::LibraryKey, None, Some(b"Public key fixture"))?;
            // Only this private daemon owns the conventional test collection.
            // Capture output: native service paths never enter diagnostics.
            let status = std::process::Command::new("gdbus")
                .args([
                    "call",
                    "--session",
                    "--dest",
                    "org.freedesktop.secrets",
                    "--object-path",
                    "/org/freedesktop/secrets",
                    "--method",
                    "org.freedesktop.Secret.Service.Lock",
                    "['/org/freedesktop/secrets/collection/login']",
                ])
                .output()
                .expect("isolated collection lock");
            assert!(status.status.success());
            assert!(owner.read(Slot::LibraryKey).err() == Some(Failure::Locked));
            assert!(
                owner.replace(Slot::LibraryKey, Some(b"Public key fixture"), None)
                    == Err(Failure::Locked)
            );
            assert!(
                owner.replace(Slot::Bootstrap, None, Some(b"Public new fixture"))
                    == Err(Failure::Locked)
            );
            assert!(
                owner.replace(
                    Slot::PairingRecipient,
                    None,
                    Some(b"Public pairing fixture")
                ) == Err(Failure::Locked)
            );
            assert!(
                owner.replace(Slot::SpaceCreation, None, Some(b"Public creation fixture"))
                    == Err(Failure::Locked)
            );
            assert!(
                owner.replace(Slot::KeyMutation, None, Some(b"Public mutation fixture"))
                    == Err(Failure::Locked)
            );
            assert!(
                owner.replace(Slot::AccountReview, None, Some(b"Public review fixture"))
                    == Err(Failure::Locked)
            );
            Ok(())
        })
        .unwrap();
}
