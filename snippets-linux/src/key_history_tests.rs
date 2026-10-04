//! Real saved switches, temporary encrypted images and fictional key-store data.
use super::*;
use crate::{
    account_review::{ActiveImage, RetainedImages},
    key_store::history::{self, SwitchPhase},
};

fn slots(s: &Setup) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::Credentials,
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::CheckpointKey,
        Slot::AccountReview,
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
fn published(s: &mut Setup) {
    let review = prepare(s).unwrap();
    s.backend.arm(2, false);
    assert!(commit(s, review).is_err());
    s.backend.arm(usize::MAX, false);
}
#[test]
fn catalog_authenticates_saved_states_without_writing_or_reading_credentials() {
    for phase in 0..3 {
        let mut s = setup();
        if phase == 0 {
            pending_before_publication(&mut s);
        } else {
            let review = prepare(&mut s).unwrap();
            commit(&mut s, review).unwrap();
        }
        if phase == 2 {
            let library = Library::open(s.temp.path().into()).unwrap();
            crate::snapshot_review::tests::write_primary(
                &library,
                &[crate::snapshot_review::tests::envelope(
                    1,
                    "Public later catalogue edit",
                    9,
                )],
            );
            s.primary = std::fs::read(library.path()).unwrap();
        }
        s.store
            .transaction(|o| {
                o.replace(
                    Slot::Credentials,
                    None,
                    Some(b"Public invalid credential fixture"),
                )
            })
            .unwrap();
        let before = slots(&s);
        let checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
        s.backend.arm(1, false); // Any protected write during inspection fails.
        let catalog = history::inspect(&mut s.store).unwrap();
        assert_eq!(s.backend.state.lock().unwrap().calls, 0);
        assert!(slots(&s) == before);
        assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
        assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == s.primary);
        assert_eq!(catalog.switches.len(), 1);
        let row = &catalog.switches[0];
        assert_eq!(
            row.phase,
            if phase == 0 {
                SwitchPhase::Pending
            } else {
                SwitchPhase::Completed
            }
        );
        assert_eq!(
            row.images,
            RetainedImages::Verified {
                active: if phase == 0 {
                    ActiveImage::Source
                } else {
                    ActiveImage::Target
                }
            }
        );
        assert_eq!(row.summary.local_records, 1);
        assert!(row.previous.pairing && row.previous.creation && row.previous.signed_action);
        assert_eq!(row.source.library.epoch(), 1);
        assert_eq!(row.target.library.epoch(), 2);
        assert_eq!(row.source.active, phase == 0);
        assert_eq!(row.target.active, phase != 0);
        assert_eq!(
            catalog.usage.switches,
            s.backend.memory.slot(Slot::AccountReview).unwrap().len()
        );
        assert!(catalog.pairing.is_empty() && catalog.first_keys.is_empty());
    }
}

#[test]
fn mixed_activation_slots_and_primary_recovery_marker_still_allow_read_only_history() {
    for step in 2..=6 {
        let mut s = setup();
        published(&mut s);
        let (target, _) = handover::prepare_local_authorization(&mut s.store).unwrap();
        let (_gate, permit) = authorize(target);
        s.backend.arm(step, false);
        assert!(handover::finish_local(&mut s.store, permit).is_err());
        let mut marker = b"SPT1".to_vec();
        marker.extend_from_slice(&[0x44; 16]);
        std::fs::write(s.temp.path().join("Sync/primary.pending"), &marker).unwrap();
        let before = slots(&s);
        let catalog = history::inspect(&mut s.store).unwrap();
        assert_eq!(catalog.switches[0].phase, SwitchPhase::Pending);
        assert_eq!(
            catalog.switches[0].images,
            RetainedImages::Verified {
                active: ActiveImage::Target
            }
        );
        assert!(catalog.switches[0].target.active && !catalog.switches[0].source.active);
        assert!(slots(&s) == before);
        assert!(std::fs::read(s.temp.path().join("Sync/primary.pending")).unwrap() == marker);
    }
}

#[test]
fn a_corrupt_or_missing_image_is_never_described_as_verified() {
    for kind in 0..5 {
        let mut s = setup();
        published(&mut s);
        let mut files = std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
            .unwrap()
            .map(|v| v.unwrap().path())
            .collect::<Vec<_>>();
        files.sort();
        let expected = match kind {
            0 => {
                std::fs::remove_file(&files[1]).unwrap();
                RetainedImages::Missing
            }
            1 => {
                let mut bytes = std::fs::read(&files[0]).unwrap();
                bytes[100] ^= 1;
                std::fs::write(&files[0], bytes).unwrap();
                RetainedImages::Invalid
            }
            2 => {
                let target = s.temp.path().join("public-linked-image");
                std::fs::rename(&files[0], &target).unwrap();
                std::os::unix::fs::symlink(target, &files[0]).unwrap();
                RetainedImages::Unreadable
            }
            3 => {
                let mut bytes = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
                bytes[100] ^= 1;
                std::fs::write(s.temp.path().join("Sync/journal.bin"), bytes).unwrap();
                RetainedImages::Verified {
                    active: ActiveImage::Other,
                }
            }
            4 => {
                let path = s.temp.path().join("Sync/journal.bin");
                let target = s.temp.path().join("public-linked-current");
                std::fs::rename(&path, &target).unwrap();
                std::os::unix::fs::symlink(target, path).unwrap();
                RetainedImages::Verified {
                    active: ActiveImage::Unreadable,
                }
            }
            _ => unreachable!(),
        };
        let before = slots(&s);
        let catalog = history::inspect(&mut s.store).unwrap();
        assert_eq!(catalog.switches[0].images, expected);
        assert!(slots(&s) == before);
    }
}

#[test]
fn browsing_cancelled_history_never_admits_the_candidate_key() {
    let mut s = setup();
    pending_before_publication(&mut s);
    let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    handover::cancel(&mut s.store, permit).unwrap();
    let catalog = history::inspect(&mut s.store).unwrap();
    assert_eq!(catalog.switches[0].phase, SwitchPhase::Cancelled);
    assert!(catalog.switches[0].source.active && !catalog.switches[0].target.active);
    assert_old_slots(&s);
    assert!(
        s.store
            .transaction_with(|o| load_locked(o, &mut s.remote))
            .is_err()
    );
}

#[test]
fn exact_scope_changes_are_distinct_while_old_entries_and_keys_remain_visible() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    commit(&mut s, review).unwrap();
    s.remote.pin.dataset = Binding::from_checkpoint([0x91; 32]);
    let review = s
        .store
        .transaction_with(|o| handover::prepare_locked(o, &mut s.remote, None, &|_| Ok(())))
        .unwrap();
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    s.store
        .transaction_with(|o| {
            handover::commit_authorized_locked(o, &mut s.remote, review, permit, &|_| Ok(()))
        })
        .unwrap();
    let before = slots(&s);
    let catalog = history::inspect(&mut s.store).unwrap();
    assert_eq!(catalog.switches.len(), 2);
    assert_eq!(
        catalog.switches[0].images,
        RetainedImages::Verified {
            active: ActiveImage::Other
        }
    );
    assert_eq!(
        catalog.switches[1].images,
        RetainedImages::Verified {
            active: ActiveImage::Target
        }
    );
    assert!(!catalog.switches[0].target.active && catalog.switches[1].target.active);
    assert!(slots(&s) == before);
}

#[test]
fn malformed_protected_history_fails_closed_without_modification() {
    for slot in [
        Slot::AccountReview,
        Slot::PairingCandidate,
        Slot::BootstrapCandidate,
        Slot::LibraryKey,
    ] {
        let mut s = setup();
        published(&mut s);
        let previous = s.backend.memory.slot(slot);
        s.store
            .transaction(|o| {
                o.replace(
                    slot,
                    previous.as_deref().map(Vec::as_slice),
                    Some(b"Public malformed protected history"),
                )
            })
            .unwrap();
        let before = slots(&s);
        assert!(history::inspect(&mut s.store).is_err());
        assert!(slots(&s) == before);
    }
}

#[test]
fn linked_archive_directory_is_unreadable_and_does_not_trigger_recovery() {
    for parent in ["Sync/Reviews", "Sync"] {
        let mut s = setup();
        published(&mut s);
        let target = s.temp.path().join("public-linked-directory");
        let path = s.temp.path().join(parent);
        std::fs::rename(&path, &target).unwrap();
        std::os::unix::fs::symlink(&target, path).unwrap();
        let before = slots(&s);
        let catalog = history::inspect(&mut s.store).unwrap();
        assert_eq!(catalog.switches[0].images, RetainedImages::Unreadable);
        assert!(slots(&s) == before);
        assert!(target.is_dir());
    }
}

#[test]
fn full_or_generation_exhausted_history_remains_browsable_without_eviction() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    commit(&mut s, review).unwrap();
    for index in 1..history::MAX_ENTRIES {
        s.remote.pin.dataset = Binding::from_checkpoint([index as u8; 32]);
        let review = s
            .store
            .transaction_with(|o| handover::prepare_locked(o, &mut s.remote, None, &|_| Ok(())))
            .unwrap();
        let (_gate, permit) = authorize(review.authorization_target().unwrap());
        s.store
            .transaction_with(|o| {
                handover::commit_authorized_locked(o, &mut s.remote, review, permit, &|_| Ok(()))
            })
            .unwrap();
    }
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
    let before = slots(&s);
    let catalog = history::inspect(&mut s.store).unwrap();
    assert_eq!(catalog.switches.len(), history::MAX_ENTRIES);
    assert!(
        catalog
            .switches
            .iter()
            .all(|saved| matches!(saved.images, RetainedImages::Verified { .. }))
    );
    assert!(slots(&s) == before);
}

#[cfg(feature = "desktop")]
#[test]
fn window_dismissal_during_history_inspection_preserves_pending_work_and_quit_ownership() {
    use crate::account_worker::{Command, Handle, Reply};
    let mut s = setup();
    published(&mut s);
    let before = slots(&s);
    let root = s.temp.path().to_owned();
    let backend = s.backend.clone();
    let worker = Handle::controlled(move |command| {
        let mut store = Store::load(&root, backend.clone()).unwrap();
        (
            match command {
                Command::InspectHistory => {
                    Ok(Reply::History(history::inspect(&mut store).unwrap()))
                }
                Command::Inspect => Ok(Reply::Profile {
                    email: None,
                    server: None,
                    interrupted: false,
                    switching: handover::inspect(&mut store).unwrap(),
                }),
                _ => panic!("History inspection must not request network or activation"),
            },
            false,
        )
    });
    drop(worker.request(Command::InspectHistory).unwrap());
    let reply = worker
        .request(Command::Inspect)
        .unwrap()
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap()
        .unwrap();
    assert!(matches!(
        reply,
        Reply::Profile {
            switching: handover::Status {
                pending: true,
                retained_libraries: 1,
                ..
            },
            ..
        }
    ));
    assert!(worker.can_quit() && !worker.retention_required());
    assert!(slots(&s) == before);
}
