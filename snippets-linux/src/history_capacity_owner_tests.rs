//! Actual terminal archives, encrypted files and production removal owners.
use super::*;
use crate::key_store::{capacity, history, restoration as restore};
#[path = "history_cleanup_owner_tests.rs"]
mod cleanup;

fn finished_switch() -> Setup {
    let mut s = setup();
    s.store
        .transaction(|owner| {
            for slot in [
                Slot::PairingRecipient,
                Slot::SpaceCreation,
                Slot::KeyMutation,
            ] {
                let old = owner.read(slot)?;
                owner.replace(slot, old.as_deref().map(Vec::as_slice), None)?;
            }
            Ok(())
        })
        .unwrap();
    let review = prepare(&mut s).unwrap();
    commit(&mut s, review).unwrap();
    s
}
fn fixture(restoration: bool) -> Setup {
    let mut s = finished_switch();
    if restoration {
        let library = Library::open(s.temp.path().into()).unwrap();
        crate::snapshot_review::tests::write_primary(
            &library,
            &[crate::snapshot_review::tests::envelope(
                1,
                "Public current history cleanup version",
                8,
            )],
        );
        let selection = history::inspect(&mut s.store).unwrap().switches[0]
            .selection
            .clone();
        let review = restore::prepare(&mut s.store, selection, None).unwrap();
        let (_gate, permit) = authorize(review.authorization_target().unwrap());
        restore::apply(&mut s.store, review, permit).unwrap();
    }
    s
}
fn selected(s: &mut Setup, restoration: bool) -> capacity::Review {
    let catalog = history::inspect(&mut s.store).unwrap();
    let selection = if restoration {
        catalog.restorations[0].removal.clone()
    } else {
        catalog.switches[0].removal.clone()
    }
    .unwrap();
    capacity::prepare(&mut s.store, selection).unwrap()
}
fn confirm(s: &mut Setup, review: capacity::Review, fault: Option<u8>) -> KeyResult<()> {
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    capacity::apply_with_fault(&mut s.store, review, permit, fault)
}
fn current(s: &Setup) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::CheckpointKey,
        Slot::Credentials,
        Slot::PairingRecipient,
        Slot::SpaceCreation,
        Slot::KeyMutation,
        Slot::PairingCandidate,
        Slot::BootstrapCandidate,
    ]
    .into_iter()
    .map(|slot| s.backend.memory.slot(slot))
    .collect()
}
fn images(s: &Setup) -> Vec<std::path::PathBuf> {
    let mut paths = std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect::<Vec<_>>();
    paths.sort();
    paths
}
fn settled(
    s: &mut Setup,
    restoration: bool,
    primary: &[u8],
    checkpoint: &[u8],
    keys: &[Option<Zeroizing<Vec<u8>>>],
) {
    assert!(current(s) == keys);
    assert_eq!(
        std::fs::read(s.temp.path().join("snippets.json")).unwrap(),
        primary
    );
    assert_eq!(
        std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap(),
        checkpoint
    );
    assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
    let catalog = history::inspect(&mut s.store).unwrap();
    assert!(catalog.maintenance.is_none());
    assert_eq!(images(s).len(), if restoration { 2 } else { 0 });
    if restoration {
        assert!(catalog.restorations.is_empty() && catalog.switches.len() == 1);
    } else {
        assert!(catalog.switches.is_empty());
    }
    assert!(crate::key_store::check_admission(&mut s.store, &s.remote.pin).is_ok());
}
#[test]
fn terminal_removal_and_every_durable_interruption_preserve_current_library() {
    for restoration in [false, true] {
        for fault in [None, Some(1), Some(2), Some(3), Some(4), Some(5)] {
            let mut s = fixture(restoration);
            let review = selected(&mut s, restoration);
            assert_eq!(review.summary().encrypted_images, 2);
            let keys = current(&s);
            let primary = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
            let checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
            let slot = if restoration {
                Slot::HistoryRestore
            } else {
                Slot::AccountReview
            };
            let before = s.backend.memory.slot(slot).unwrap();
            if fault.is_some() {
                assert!(confirm(&mut s, review, fault).is_err());
                assert!(matches!(
                    s.store.transaction(|_| Ok(())),
                    Err(secret_store::Failure::HistoryMaintenanceRequired)
                ));
                assert!(
                    history::inspect(&mut s.store)
                        .unwrap()
                        .maintenance
                        .is_some()
                );
                s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
                let review = capacity::prepare_resume(&mut s.store).unwrap();
                assert_eq!(
                    review.authorization_target().unwrap().purpose(),
                    Purpose::ResumeHistoryRemoval
                );
                confirm(&mut s, review, None).unwrap();
            } else {
                confirm(&mut s, review, None).unwrap();
            }
            let after = s.backend.memory.slot(slot).unwrap();
            let generation = |bytes: &[u8]| {
                canonical::parse(bytes).unwrap().as_object().unwrap()["generation"]
                    .as_int()
                    .unwrap()
            };
            assert_eq!(generation(&after), generation(&before) + 1);
            settled(&mut s, restoration, &primary, &checkpoint, &keys);
        }
    }
}
#[test]
fn ambiguous_protected_writes_are_resumed_without_repeating_removal() {
    for restoration in [false, true] {
        for step in 1..=3 {
            for after in [false, true] {
                let mut s = fixture(restoration);
                let review = selected(&mut s, restoration);
                let keys = current(&s);
                let primary = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
                let checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
                s.backend.arm(step, after);
                assert!(confirm(&mut s, review, None).is_err());
                s.backend.arm(usize::MAX, false);
                let review = if s.backend.memory.slot(Slot::HistoryMaintenance).is_some() {
                    Some(capacity::prepare_resume(&mut s.store).unwrap())
                } else if step == 1 {
                    Some(selected(&mut s, restoration))
                } else {
                    None
                };
                if let Some(review) = review {
                    confirm(&mut s, review, None).unwrap();
                }
                settled(&mut s, restoration, &primary, &checkpoint, &keys);
            }
        }
    }
}
#[test]
fn file_replacement_symlinks_and_stale_history_cannot_authorize_cleanup() {
    for kind in 0..6 {
        let mut s = fixture(false);
        let review = selected(&mut s, false);
        let archive = s.backend.memory.slot(Slot::AccountReview).unwrap();
        let paths = images(&s);
        let path = &paths[kind % 2];
        match kind {
            0 => {
                let data = std::fs::read(path).unwrap();
                std::fs::remove_file(path).unwrap();
                std::fs::write(path, data).unwrap();
            }
            1 => {
                std::fs::write(path, b"Public invalid ciphertext replacement").unwrap();
            }
            2 => {
                let other = s.temp.path().join("public-side-file");
                std::fs::rename(path, &other).unwrap();
                std::os::unix::fs::symlink(other, path).unwrap();
            }
            3 => {
                std::fs::remove_file(path).unwrap();
            }
            4 => {
                std::fs::hard_link(path, s.temp.path().join("public-linked-ciphertext")).unwrap();
            }
            5 => {
                s.store
                    .transaction(|owner| {
                        let mut value = canonical::parse(&archive).unwrap();
                        let Value::Object(ref mut fields) = value else {
                            unreachable!()
                        };
                        fields.insert("generation".into(), Value::Int(99));
                        owner.replace(
                            Slot::AccountReview,
                            Some(&archive),
                            Some(&value.encode().unwrap()),
                        )
                    })
                    .unwrap();
            }
            _ => unreachable!(),
        }
        let before = s.backend.memory.slot(Slot::AccountReview);
        assert!(confirm(&mut s, review, None).is_err());
        assert!(s.backend.memory.slot(Slot::AccountReview) == before);
        assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        assert!(paths.iter().filter(|p| p.exists()).count() >= 1);
    }
}
#[test]
fn old_capabilities_and_unfinished_primary_remain_protected() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    commit(&mut s, review).unwrap();
    assert!(
        history::inspect(&mut s.store).unwrap().switches[0]
            .removal
            .is_none()
    );
    let mut s = fixture(false);
    let review = selected(&mut s, false);
    let mut marker = b"SPT1".to_vec();
    marker.extend_from_slice(&[77; 16]);
    std::fs::write(s.temp.path().join("Sync/primary.pending"), marker).unwrap();
    assert!(confirm(&mut s, review, None).is_err());
    assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
    assert_eq!(images(&s).len(), 2);
}

#[test]
fn terminal_old_capability_receipts_can_be_retired_with_the_selected_switch() {
    let mut s = setup();
    let binding = Installed::decode(&s.backend.memory.slot(Slot::LibraryKey).unwrap())
        .unwrap()
        .binding;
    let pairing = object([
        ("schema", Value::Int(1)),
        ("generation", Value::Int(1)),
        ("binding", binding.value()),
        ("phase", Value::Null),
    ])
    .encode()
    .unwrap();
    let signed = object([
        ("schema", Value::Int(1)),
        ("generation", Value::Int(1)),
        ("binding", binding.value()),
        ("authority", Value::text(STANDARD.encode([42; 32]))),
        ("intent", Value::Null),
        (
            "phase",
            object([
                ("kind", Value::text("inactive")),
                ("proof", Value::Null),
                ("version", Value::Null),
            ]),
        ),
    ])
    .encode()
    .unwrap();
    s.store
        .transaction(|owner| {
            for (slot, bytes) in [
                (Slot::PairingRecipient, Some(pairing.as_slice())),
                (Slot::SpaceCreation, None),
                (Slot::KeyMutation, Some(signed.as_slice())),
            ] {
                let before = owner.read(slot)?;
                owner.replace(slot, before.as_deref().map(Vec::as_slice), bytes)?;
            }
            Ok(())
        })
        .unwrap();
    let review = prepare(&mut s).unwrap();
    commit(&mut s, review).unwrap();
    let review = selected(&mut s, false);
    confirm(&mut s, review, None).unwrap();
    assert!(history::inspect(&mut s.store).unwrap().switches.is_empty());
    assert!(crate::key_store::check_admission(&mut s.store, &s.remote.pin).is_ok());
    assert!(images(&s).is_empty());
}

#[test]
fn another_archive_reference_or_changed_active_key_refuses_removal() {
    for reference in [false, true] {
        let mut s = fixture(reference);
        let catalog = history::inspect(&mut s.store).unwrap();
        let selection = catalog.switches[0].removal.clone().unwrap();
        if reference {
            let switch = s.store.transaction_with(Archive::load).unwrap();
            let bytes = s.backend.memory.slot(Slot::HistoryRestore).unwrap();
            let mut value = canonical::parse(&bytes).unwrap();
            let Value::Object(ref mut fields) = value else {
                unreachable!()
            };
            let Value::Array(entries) = fields.get_mut("entries").unwrap() else {
                unreachable!()
            };
            let Value::Object(ref mut entry) = entries[0] else {
                unreachable!()
            };
            entry.insert(
                "nonce".into(),
                Value::text(STANDARD.encode(switch.entries[0].receipt.transition_id())),
            );
            s.store
                .transaction(|owner| {
                    owner.replace(
                        Slot::HistoryRestore,
                        Some(&bytes),
                        Some(&value.encode().unwrap()),
                    )
                })
                .unwrap();
            assert!(matches!(
                capacity::prepare(&mut s.store, selection),
                Err(KeyFailure::Busy)
            ));
        } else {
            let review = capacity::prepare(&mut s.store, selection).unwrap();
            s.store
                .transaction(|owner| {
                    let old = owner.read(Slot::LibraryKey)?.unwrap();
                    let mut installed = Installed::decode(&old).unwrap();
                    installed.bundle = Bundle::from_material(&[0x61; 64]).unwrap();
                    owner.replace(
                        Slot::LibraryKey,
                        Some(&old),
                        Some(&installed.value().unwrap().encode().unwrap()),
                    )
                })
                .unwrap();
            assert!(confirm(&mut s, review, None).is_err());
        }
        assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        assert_eq!(images(&s).len(), if reference { 4 } else { 2 });
    }
}
#[cfg(feature = "desktop")]
#[test]
fn production_retention_consumes_stale_tokens_and_cancelled_reviews() {
    use crate::account_worker::{
        Command, Reply, history_removal::Retained, restoration_task::Preparation,
    };
    for kind in 0..5 {
        let mut s = fixture(false);
        let catalog = history::inspect(&mut s.store).unwrap();
        let selection = catalog.switches[0].removal.clone().unwrap();
        let guard = Preparation::new(crate::desktop::SessionWitness::test(
            crate::desktop::SessionState::Unlocked,
            1,
        ))
        .unwrap();
        let mut owner = Retained::default();
        let Reply::HistoryRemovalReview { token, target, .. } = owner
            .prepare(&mut s.store, Some(selection), guard.clone())
            .unwrap()
        else {
            panic!("expected exact removal review")
        };
        if kind == 0 {
            let review = owner.consume(token).unwrap();
            let (_gate, permit) = authorize(target);
            capacity::apply(&mut s.store, review, permit).unwrap();
            assert_eq!(images(&s).len(), 0);
        } else {
            if kind == 1 {
                guard.cancel();
            }
            if kind == 2 {
                owner.keep_for(&Command::InspectHistory);
            }
            let requested = if kind == 3 { Uuid::new_v4() } else { token };
            if kind == 4 {
                let review = owner.consume(token).unwrap();
                let (mut gate, permit) = authorize(target);
                gate.cancel();
                assert!(capacity::apply(&mut s.store, review, permit).is_err());
            } else {
                assert!(owner.consume(requested).is_err());
            }
            assert!(owner.consume(token).is_err());
            assert_eq!(images(&s).len(), 2);
            assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        }
    }
}
