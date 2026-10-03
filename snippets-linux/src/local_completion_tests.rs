//! Offline recovery uses only fictional protected capabilities and temporary roots.
use super::*;

fn published(s: &mut Setup) {
    let review = prepare(s).unwrap();
    s.backend.arm(2, false);
    assert!(commit(s, review).is_err());
    s.backend.arm(usize::MAX, false);
    assert!(handover::inspect(&mut s.store).unwrap().pending);
    assert!(journal(s) != s.old_checkpoint);
    assert_old_slots(s);
}
fn journal(s: &Setup) -> Vec<u8> {
    std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap()
}
fn images(s: &Setup) -> Vec<Vec<u8>> {
    let mut paths = std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect::<Vec<_>>();
    paths.sort();
    paths
        .iter()
        .map(|path| std::fs::read(path).unwrap())
        .collect()
}
fn finish(s: &mut Setup) {
    let (target, summary) = handover::prepare_local_authorization(&mut s.store).unwrap();
    assert_eq!(summary.local_records, 1);
    assert_eq!(target.purpose(), Purpose::FinishLocalLibrarySwitch);
    let (_gate, permit) = authorize(target);
    handover::finish_local(&mut s.store, permit).unwrap();
}
fn assert_finished(s: &mut Setup, expected_journal: &[u8], expected_images: &[Vec<u8>]) {
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    assert!(archive.pending().is_none() && archive.entries.len() == 1);
    let entry = &archive.entries[0];
    assert!(entry.completed && !entry.cancelled && entry.source == s.old);
    for (index, (slot, _)) in handover::SLOTS.iter().enumerate() {
        assert!(s.backend.memory.slot(*slot).as_deref().map(Vec::as_slice) == entry.target(index));
    }
    assert!(journal(s) == expected_journal && images(s) == expected_images);
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == s.primary);
}

#[test]
fn account_and_scope_change_can_finish_locally_then_require_a_fresh_online_review() {
    let mut s = setup();
    install_account(&mut s);
    published(&mut s);
    let old_hash = s
        .store
        .transaction_with(handover::Archive::load)
        .unwrap()
        .entries[0]
        .account_hash;
    let checkpoint = journal(&s);
    let retained = images(&s);
    refreshed_credentials(&mut s, true);
    let credentials = s.backend.memory.slot(Slot::Credentials);
    s.remote.pin.membership = Binding::from_checkpoint([0xa1; 32]);
    s.remote.pin.dataset = Binding::from_checkpoint([0xa2; 32]);
    s.remote.pin.epoch += 1;
    assert!(resume(&mut s).is_err());
    let (target, _) = handover::prepare_local_authorization(&mut s.store).unwrap();
    let library = Library::open(s.temp.path().into()).unwrap();
    crate::snapshot_review::tests::write_primary(
        &library,
        &[crate::snapshot_review::tests::envelope(
            1,
            "Public later local edit",
            9,
        )],
    );
    s.primary = std::fs::read(library.path()).unwrap();
    let cancel = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_cancel_gate, cancel_permit) = authorize(cancel);
    assert!(handover::cancel(&mut s.store, cancel_permit).is_err());
    let (_gate, permit) = authorize(target);
    let calls = s.remote.calls;
    handover::finish_local(&mut s.store, permit).unwrap();
    assert_eq!(s.remote.calls, calls);
    assert!(s.backend.memory.slot(Slot::Credentials) == credentials);
    assert_finished(&mut s, &checkpoint, &retained);
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    assert!(archive.entries[0].account_hash == old_hash);
    assert!(
        s.store
            .transaction_with(|o| load_locked(o, &mut s.remote))
            .is_err()
    );
    let current = Installed::decode(&s.backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
    s.remote.public =
        Some(Authority::new(&current.bundle, &s.remote.pin.context().unwrap()).public_key());
    let review = s
        .store
        .transaction_with(|o| handover::prepare_locked(o, &mut s.remote, None, &|_| Ok(())))
        .unwrap();
    assert!(review.reuses_local_key());
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    s.store
        .transaction_with(|o| {
            handover::commit_authorized_locked(o, &mut s.remote, review, permit, &|_| Ok(()))
        })
        .unwrap();
    assert!(std::fs::read(library.path()).unwrap() == s.primary);
}

#[test]
fn every_slot_and_final_receipt_failure_keeps_the_same_published_recovery() {
    for after in [false, true] {
        for step in 1..=6 {
            let mut s = setup();
            published(&mut s);
            let checkpoint = journal(&s);
            let retained = images(&s);
            let (target, _) = handover::prepare_local_authorization(&mut s.store).unwrap();
            let (_gate, permit) = authorize(target);
            s.backend.arm(step, after);
            assert!(handover::finish_local(&mut s.store, permit).is_err());
            let archive = s.store.transaction_with(handover::Archive::load).unwrap();
            assert!(archive.entries[0].source == s.old);
            for (index, (slot, _)) in handover::SLOTS.iter().enumerate() {
                let current = s.backend.memory.slot(*slot);
                assert!(
                    current == s.old[index]
                        || current.as_deref().map(Vec::as_slice)
                            == archive.entries[0].target(index)
                );
            }
            s.backend.arm(usize::MAX, false);
            s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
            if handover::inspect(&mut s.store).unwrap().pending {
                finish(&mut s);
            }
            assert_finished(&mut s, &checkpoint, &retained);
        }
    }
}

#[test]
fn unpublished_switch_has_no_local_finish_and_remains_cancellable() {
    let mut s = setup();
    pending_before_publication(&mut s);
    assert!(matches!(
        handover::prepare_local_authorization(&mut s.store),
        Err(handover::Failure::Unpublished)
    ));
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    let target = archive
        .pending()
        .unwrap()
        .authorization_target(Purpose::FinishLocalLibrarySwitch, archive.generation)
        .unwrap();
    let (_gate, permit) = authorize(target);
    assert!(matches!(
        handover::finish_local(&mut s.store, permit),
        Err(handover::Failure::Unpublished)
    ));
    assert_old_slots(&s);
    assert!(journal(&s) == s.old_checkpoint);
    let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    handover::cancel(&mut s.store, permit).unwrap();
    assert!(!handover::inspect(&mut s.store).unwrap().pending);
}

#[test]
fn offline_completion_needs_its_own_exact_unrevoked_authorization() {
    for kind in 0..4 {
        let mut s = setup();
        published(&mut s);
        let archive = s.store.transaction_with(handover::Archive::load).unwrap();
        let (mut target, _) = handover::prepare_local_authorization(&mut s.store).unwrap();
        if kind < 2 {
            target = archive
                .pending()
                .unwrap()
                .authorization_target(
                    if kind == 0 {
                        Purpose::SwitchLibrary
                    } else {
                        Purpose::CancelLibrarySwitch
                    },
                    archive.generation,
                )
                .unwrap();
        } else if kind == 2 {
            let mut other = setup();
            published(&mut other);
            target = handover::prepare_local_authorization(&mut other.store)
                .unwrap()
                .0;
        }
        let (mut gate, permit) = authorize(target);
        if kind == 3 {
            gate.cancel();
        }
        let before = s.backend.memory.slot(Slot::AccountReview);
        let checkpoint = journal(&s);
        assert!(handover::finish_local(&mut s.store, permit).is_err());
        assert!(s.backend.memory.slot(Slot::AccountReview) == before);
        assert_old_slots(&s);
        assert!(journal(&s) == checkpoint);
    }
}

#[test]
fn missing_changed_advanced_or_linked_inputs_never_allow_slot_activation() {
    for kind in 0..10 {
        let mut s = setup();
        published(&mut s);
        let (target, _) = handover::prepare_local_authorization(&mut s.store).unwrap();
        let (_gate, permit) = authorize(target);
        match kind {
            0..=2 => {
                let mut files = std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
                    .unwrap()
                    .map(|e| e.unwrap().path())
                    .collect::<Vec<_>>();
                files.sort();
                if kind == 2 {
                    let copy = s.temp.path().join("public-linked-image");
                    std::fs::rename(&files[0], &copy).unwrap();
                    std::os::unix::fs::symlink(copy, &files[0]).unwrap();
                } else if kind == 0 {
                    std::fs::remove_file(&files[0]).unwrap();
                } else {
                    let mut bytes = std::fs::read(&files[1]).unwrap();
                    bytes[100] ^= 1;
                    std::fs::write(&files[1], bytes).unwrap();
                }
            }
            3 => {
                let mut bytes = journal(&s);
                bytes[100] ^= 1;
                std::fs::write(s.temp.path().join("Sync/journal.bin"), bytes).unwrap();
            }
            4 => {
                let archive = s.store.transaction_with(handover::Archive::load).unwrap();
                let entry = archive.pending().unwrap();
                let key = RootKey::from_bytes(&entry.checkpoint[..32]).unwrap();
                let salt = entry.checkpoint[32..].try_into().unwrap();
                let library = Library::prepare(s.temp.path().into()).unwrap();
                let mut current = Checkpoint::load(
                    &library,
                    &key,
                    &salt,
                    entry.installed().unwrap().binding.checkpoint_scope(),
                )
                .unwrap();
                current
                    .journal
                    .desire(crate::snapshot_review::tests::envelope(
                        2,
                        "Public later journal intent",
                        8,
                    ))
                    .unwrap();
                current.save(&library, &key, &salt).unwrap();
            }
            5..=7 => {
                let slot = [Slot::CheckpointKey, Slot::SpaceCreation, Slot::LibraryKey][kind - 5];
                let old = s.backend.memory.slot(slot);
                s.store
                    .transaction(|o| {
                        o.replace(slot, old.as_deref().map(Vec::as_slice), Some(&[0x44; 64]))
                    })
                    .unwrap();
            }
            8 => {
                let mut marker = b"SPT1".to_vec();
                marker.extend_from_slice(&[0x44; 16]);
                std::fs::write(s.temp.path().join("Sync/primary.pending"), marker).unwrap();
            }
            9 => {
                let path = s.temp.path().join("Sync/journal.bin");
                let copy = s.temp.path().join("public-linked-journal");
                std::fs::rename(&path, &copy).unwrap();
                std::os::unix::fs::symlink(copy, path).unwrap();
            }
            _ => unreachable!(),
        }
        let before = handover::SLOTS
            .iter()
            .map(|(slot, _)| s.backend.memory.slot(*slot))
            .collect::<Vec<_>>();
        let frame = s.backend.memory.slot(Slot::AccountReview);
        assert!(handover::finish_local(&mut s.store, permit).is_err());
        assert!(s.backend.memory.slot(Slot::AccountReview) == frame);
        assert!(
            handover::SLOTS
                .iter()
                .enumerate()
                .all(|(i, (slot, _))| s.backend.memory.slot(*slot) == before[i])
        );
        assert!(handover::inspect(&mut s.store).unwrap().pending);
    }
}

#[test]
fn exhausted_generation_refuses_completion_before_touching_active_slots() {
    let mut s = setup();
    published(&mut s);
    s.store
        .transaction(|o| {
            let previous = o.read(Slot::AccountReview)?.unwrap();
            let Value::Object(mut fields) = canonical::parse(&previous).unwrap() else {
                unreachable!()
            };
            fields.insert("generation".into(), Value::Int(i64::MAX));
            o.replace(
                Slot::AccountReview,
                Some(&previous),
                Some(&Value::Object(fields).encode().unwrap()),
            )
        })
        .unwrap();
    assert!(handover::prepare_local_authorization(&mut s.store).is_err());
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    let target = archive
        .pending()
        .unwrap()
        .authorization_target(Purpose::FinishLocalLibrarySwitch, archive.generation)
        .unwrap();
    let (_gate, permit) = authorize(target);
    let frame = s.backend.memory.slot(Slot::AccountReview);
    let checkpoint = journal(&s);
    assert!(handover::finish_local(&mut s.store, permit).is_err());
    assert_old_slots(&s);
    assert!(s.backend.memory.slot(Slot::AccountReview) == frame && journal(&s) == checkpoint);
}

#[test]
fn exact_completed_document_must_fit_before_any_active_key_is_changed() {
    let mut rejected = 0;
    for generation in [9, 99, 999, 9999] {
        let mut s = setup();
        published(&mut s);
        let mut archive = s.store.transaction_with(handover::Archive::load).unwrap();
        archive.generation = generation;
        // Real protected capabilities can approach the bounded archive limit.
        // Base64 advances by four bytes; these generations exercise all residues.
        let encode = |size: usize| {
            let mut value = archive.entries[0].value().unwrap();
            let Value::Object(ref mut entry) = value else {
                unreachable!()
            };
            let Value::Object(ref mut source) = *entry.get_mut("source").unwrap() else {
                unreachable!()
            };
            source.insert(
                "pairingRecipient".into(),
                Value::text(STANDARD.encode(vec![0x55; size])),
            );
            object([
                ("schema", Value::Int(2)),
                ("generation", Value::Int(generation)),
                ("entries", Value::Array(vec![value])),
            ])
            .encode()
            .unwrap()
        };
        let (mut low, mut high) = (0, secret_store::MAX_SECRET_BYTES);
        while low < high {
            let middle = low + (high - low).div_ceil(2);
            if encode(middle).len() <= secret_store::MAX_SECRET_BYTES {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        let frame = encode(low);
        let previous = s.backend.memory.slot(Slot::AccountReview).unwrap();
        let old = s.backend.memory.slot(Slot::PairingRecipient).unwrap();
        s.store
            .transaction(|o| {
                o.replace(Slot::PairingRecipient, Some(&old), Some(&vec![0x55; low]))?;
                o.replace(Slot::AccountReview, Some(&previous), Some(&frame))
            })
            .unwrap();
        let archive = s.store.transaction_with(handover::Archive::load).unwrap();
        if archive.completed_bytes().is_ok() {
            continue;
        }
        rejected += 1;
        assert!(matches!(
            handover::prepare_local_authorization(&mut s.store),
            Err(handover::Failure::RetentionFull)
        ));
        let target = archive
            .pending()
            .unwrap()
            .authorization_target(Purpose::FinishLocalLibrarySwitch, archive.generation)
            .unwrap();
        let (_gate, permit) = authorize(target);
        assert!(matches!(
            handover::finish_local(&mut s.store, permit),
            Err(handover::Failure::RetentionFull)
        ));
        assert!(s.backend.memory.slot(Slot::LibraryKey) == s.old[0]);
        assert!(s.backend.memory.slot(Slot::Bootstrap) == s.old[1]);
        assert!(s.backend.memory.slot(Slot::AccountReview).as_deref() == Some(&frame));
    }
    assert!(rejected > 0);
}

#[derive(Clone)]
struct RevokeOnKey {
    backend: Faults,
    gate: Arc<Mutex<crate::local_auth::Gate>>,
}
impl Backend for RevokeOnKey {
    fn read(
        &mut self,
        ns: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        self.backend.read(ns, slot)
    }
    fn write(&mut self, ns: &[u8; 16], slot: Slot, value: &[u8]) -> secret_store::Result<()> {
        self.backend.write(ns, slot, value)?;
        if slot == Slot::LibraryKey {
            self.gate.lock().unwrap().cancel();
        }
        Ok(())
    }
    fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
        self.backend.delete(ns, slot)
    }
}

#[test]
fn authorization_revoked_during_activation_keeps_pending_intent_for_fresh_local_retry() {
    let mut s = setup();
    published(&mut s);
    let checkpoint = journal(&s);
    let retained = images(&s);
    let frame = s.backend.memory.slot(Slot::AccountReview);
    let (target, _) = handover::prepare_local_authorization(&mut s.store).unwrap();
    let (gate, permit) = authorize(target);
    let backend = RevokeOnKey {
        backend: s.backend.clone(),
        gate: Arc::new(Mutex::new(gate)),
    };
    let mut store = Store::load(s.temp.path(), backend).unwrap();
    assert!(handover::finish_local(&mut store, permit).is_err());
    assert!(handover::inspect(&mut store).unwrap().pending);
    assert!(s.backend.memory.slot(Slot::AccountReview) == frame);
    assert!(s.backend.memory.slot(Slot::LibraryKey) != s.old[0]);
    assert!(s.backend.memory.slot(Slot::Bootstrap) == s.old[1]);
    finish(&mut s);
    assert_finished(&mut s, &checkpoint, &retained);
}

#[test]
fn unreadable_current_credentials_are_never_parsed_or_replaced_by_local_completion() {
    let mut s = setup();
    published(&mut s);
    let checkpoint = journal(&s);
    let retained = images(&s);
    s.store
        .transaction(|o| {
            o.replace(
                Slot::Credentials,
                None,
                Some(b"Public malformed credential fixture"),
            )
        })
        .unwrap();
    let credentials = s.backend.memory.slot(Slot::Credentials);
    finish(&mut s);
    assert!(s.backend.memory.slot(Slot::Credentials) == credentials);
    assert_finished(&mut s, &checkpoint, &retained);
}

#[derive(Clone)]
struct PauseOnKey {
    backend: Faults,
    entered: std::sync::mpsc::SyncSender<()>,
    release: Arc<Mutex<std::sync::mpsc::Receiver<()>>>,
}
impl Backend for PauseOnKey {
    fn read(
        &mut self,
        ns: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        self.backend.read(ns, slot)
    }
    fn write(&mut self, ns: &[u8; 16], slot: Slot, value: &[u8]) -> secret_store::Result<()> {
        self.backend.write(ns, slot, value)?;
        if slot == Slot::LibraryKey {
            self.entered.send(()).unwrap();
            self.release
                .lock()
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(5))
                .unwrap();
        }
        Ok(())
    }
    fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
        self.backend.delete(ns, slot)
    }
}

#[test]
fn common_library_lock_is_held_through_secret_service_activation() {
    use std::os::fd::AsRawFd;
    let mut s = setup();
    published(&mut s);
    let checkpoint = journal(&s);
    let retained = images(&s);
    let (entered, entry) = std::sync::mpsc::sync_channel(1);
    let (release, released) = std::sync::mpsc::sync_channel(1);
    let backend = PauseOnKey {
        backend: s.backend.clone(),
        entered,
        release: Arc::new(Mutex::new(released)),
    };
    let root = s.temp.path().to_owned();
    let worker = std::thread::spawn(move || {
        let mut store = Store::load(&root, backend).unwrap();
        let (target, _) = handover::prepare_local_authorization(&mut store).unwrap();
        let (_gate, permit) = authorize(target);
        handover::finish_local(&mut store, permit)
    });
    entry
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(s.temp.path().join("library.lock"))
        .unwrap();
    let acquired = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    let error = std::io::Error::last_os_error();
    release.send(()).unwrap();
    assert!(worker.join().unwrap().is_ok());
    assert_eq!(acquired, -1);
    assert_eq!(error.raw_os_error(), Some(libc::EWOULDBLOCK));
    assert_finished(&mut s, &checkpoint, &retained);
}

#[cfg(feature = "desktop")]
#[test]
fn lost_window_reply_retains_completion_without_admitting_a_data_key() {
    use crate::account_worker::{Command, Handle, Reply};
    let mut s = setup();
    published(&mut s);
    let root = s.temp.path().to_owned();
    let backend = s.backend.clone();
    let (target, _) = handover::prepare_local_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    let worker = Handle::controlled(move |command| {
        let mut store = Store::load(&root, backend.clone()).unwrap();
        let result = match command {
            Command::FinishLocalHandover(permit) => {
                handover::finish_local(&mut store, permit).unwrap();
                Ok(Reply::LocalHandover {
                    switching: handover::inspect(&mut store).unwrap(),
                    failure: None,
                })
            }
            Command::Inspect => Ok(Reply::Profile {
                account: None,
                server: None,
                interrupted: false,
                switching: handover::inspect(&mut store).unwrap(),
                device: None,
            }),
            _ => panic!("Offline completion must not request a server or data key"),
        };
        (result, false)
    });
    drop(
        worker
            .request(Command::FinishLocalHandover(permit))
            .unwrap(),
    );
    let result = worker
        .request(Command::Inspect)
        .unwrap()
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap()
        .unwrap();
    assert!(matches!(
        result,
        Reply::Profile {
            switching: handover::Status {
                pending: false,
                retained_libraries: 1,
                ..
            },
            ..
        }
    ));
    assert!(worker.can_quit() && !worker.retention_required());
    assert!(!handover::inspect(&mut s.store).unwrap().pending);
}
