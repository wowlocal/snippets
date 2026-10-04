//! Real retained image writer, typed histories, memory provider and public data.
use super::*;
use crate::local_auth::Purpose;

fn unused(s: &mut Setup, nonce: [u8; 16], partial: bool) -> Vec<std::path::PathBuf> {
    let bytes = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
    let library = Library::prepare(s.temp.path().into()).unwrap();
    let _guard = library.lock().unwrap();
    let result = crate::account_review::retain_pair_locked(
        &library,
        &nonce,
        &bytes,
        &bytes,
        partial.then_some(1),
    );
    assert_eq!(result.is_err(), partial);
    let directory = s.temp.path().join("Sync/Reviews");
    ["source", "target"]
        .into_iter()
        .map(|kind| crate::account_review::image_path(&directory, &nonce, kind))
        .filter(|path| path.exists())
        .collect()
}
fn selected_cleanup(s: &mut Setup) -> capacity::Review {
    capacity::prepare_cleanup(&mut s.store).unwrap().unwrap()
}
fn preserved(
    s: &mut Setup,
    keys: &[Option<Zeroizing<Vec<u8>>>],
    primary: &[u8],
    checkpoint: &[u8],
    referenced: &[std::path::PathBuf],
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
    assert!(referenced.iter().all(|path| path.exists()));
    assert_eq!(history::inspect(&mut s.store).unwrap().switches.len(), 1);
    assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
}

#[test]
fn explicit_cleanup_discards_only_unreferenced_complete_or_partial_image_sets() {
    for partial in [false, true] {
        let mut s = fixture(true);
        let referenced = images(&s);
        assert!(capacity::prepare_cleanup(&mut s.store).unwrap().is_none());
        let orphan = unused(&mut s, [0x77; 16], partial);
        let keys = current(&s);
        let primary = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
        let checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
        let review = selected_cleanup(&mut s);
        assert_eq!(review.summary().section, capacity::Section::UnusedImages);
        assert_eq!(review.summary().encrypted_images, orphan.len());
        assert_eq!(
            review.authorization_target().unwrap().purpose(),
            Purpose::RemoveUnusedRecoveryFiles
        );
        assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        assert!(orphan.iter().all(|path| path.exists()));
        confirm(&mut s, review, None).unwrap();
        assert!(orphan.iter().all(|path| !path.exists()));
        assert_eq!(
            history::inspect(&mut s.store).unwrap().restorations.len(),
            1
        );
        preserved(&mut s, &keys, &primary, &checkpoint, &referenced);
        assert!(capacity::prepare_cleanup(&mut s.store).unwrap().is_none());
    }
}

#[test]
fn every_cleanup_publication_boundary_resumes_exact_frozen_files_after_restart() {
    for fault in [1, 2, 3, 34, 35] {
        let mut s = fixture(false);
        let referenced = images(&s);
        let orphan = unused(&mut s, [0x77; 16], false);
        let keys = current(&s);
        let primary = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
        let checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
        let review = selected_cleanup(&mut s);
        assert!(confirm(&mut s, review, Some(fault)).is_err());
        let pending = s.backend.memory.slot(Slot::HistoryMaintenance).is_some();
        assert_eq!(pending, fault != 35);
        s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
        if pending {
            assert!(s.store.transaction(|_| Ok(())).is_err());
            let catalog = history::inspect(&mut s.store).unwrap();
            assert_eq!(
                catalog.maintenance.unwrap().section,
                capacity::Section::UnusedImages
            );
            let review = capacity::prepare_resume(&mut s.store).unwrap();
            assert_eq!(
                review.authorization_target().unwrap().purpose(),
                Purpose::ResumeRecoveryFileCleanup
            );
            confirm(&mut s, review, None).unwrap();
        }
        assert!(orphan.iter().all(|path| !path.exists()));
        preserved(&mut s, &keys, &primary, &checkpoint, &referenced);
    }
}

#[test]
fn ambiguous_consent_and_completion_writes_keep_resumable_cleanup_ownership() {
    for step in [1, 2] {
        for after in [false, true] {
            let mut s = fixture(false);
            let referenced = images(&s);
            let orphan = unused(&mut s, [0x77; 16], false);
            let keys = current(&s);
            let primary = std::fs::read(s.temp.path().join("snippets.json")).unwrap();
            let checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
            let review = selected_cleanup(&mut s);
            s.backend.arm(step, after);
            assert!(confirm(&mut s, review, None).is_err());
            s.backend.arm(usize::MAX, false);
            let review = if s.backend.memory.slot(Slot::HistoryMaintenance).is_some() {
                Some(capacity::prepare_resume(&mut s.store).unwrap())
            } else {
                capacity::prepare_cleanup(&mut s.store).unwrap()
            };
            if let Some(review) = review {
                confirm(&mut s, review, None).unwrap();
            }
            assert!(orphan.iter().all(|path| !path.exists()));
            preserved(&mut s, &keys, &primary, &checkpoint, &referenced);
        }
    }
}

#[test]
fn changed_or_linked_images_and_changed_history_halt_before_any_new_removal() {
    for saved in [false, true] {
        for damage in 0..6 {
            let mut s = fixture(false);
            let orphan = unused(&mut s, [0x77; 16], false);
            let mut review = Some(selected_cleanup(&mut s));
            if saved {
                assert!(confirm(&mut s, review.take().unwrap(), Some(1)).is_err());
            }
            let path = &orphan[0];
            match damage {
                0 => {
                    let bytes = std::fs::read(path).unwrap();
                    crate::model::atomic_write(path, &bytes).unwrap();
                }
                1 => {
                    let mut bytes = std::fs::read(path).unwrap();
                    bytes[20] ^= 1;
                    std::fs::write(path, bytes).unwrap();
                }
                2 => {
                    let side = s.temp.path().join("Public protected side file");
                    std::fs::rename(path, &side).unwrap();
                    std::os::unix::fs::symlink(side, path).unwrap();
                }
                3 => {
                    std::fs::hard_link(path, s.temp.path().join("Public second link")).unwrap();
                }
                4 => {
                    s.store
                        .history_transaction_with(|owner| {
                            let before = owner.read(Slot::AccountReview)?.unwrap();
                            let Value::Object(mut fields) = canonical::parse(&before)? else {
                                unreachable!()
                            };
                            let generation = fields["generation"].as_int()?;
                            fields.insert("generation".into(), Value::Int(generation + 1));
                            owner.replace(
                                Slot::AccountReview,
                                Some(&before),
                                Some(&Value::Object(fields).encode()?),
                            )?;
                            Ok::<_, crate::key_store::Failure>(())
                        })
                        .unwrap();
                }
                5 => {
                    s.store
                        .history_transaction_with(|owner| {
                            let before = owner.read(Slot::CheckpointKey)?.unwrap();
                            owner.replace(Slot::CheckpointKey, Some(&before), Some(&[0x99; 64]))
                        })
                        .unwrap();
                }
                _ => unreachable!(),
            }
            if saved {
                assert!(capacity::prepare_resume(&mut s.store).is_err());
            } else {
                assert!(confirm(&mut s, review.unwrap(), None).is_err());
            }
            assert!(orphan.iter().all(|path| path.exists()));
            assert_eq!(
                s.backend.memory.slot(Slot::HistoryMaintenance).is_some(),
                saved
            );
        }
    }
}

#[test]
fn unknown_names_frames_nonregular_files_and_invalid_archives_are_never_cleanup_candidates() {
    for damage in 0..7 {
        let mut s = fixture(false);
        let orphan = unused(&mut s, [0x77; 16], false);
        match damage {
            0 => {
                std::fs::write(
                    s.temp.path().join("Sync/Reviews/unknown-image"),
                    b"SCJ1 public unrelated file",
                )
                .unwrap();
            }
            1 => {
                std::fs::write(&orphan[0], b"Public non-checkpoint image").unwrap();
            }
            2 => {
                std::fs::remove_file(&orphan[0]).unwrap();
                std::fs::create_dir(&orphan[0]).unwrap();
            }
            3 => {
                let file = std::fs::OpenOptions::new()
                    .write(true)
                    .open(&orphan[0])
                    .unwrap();
                file.set_len((crate::crypto::MAX_CHECKPOINT_BYTES + 33) as u64)
                    .unwrap();
            }
            4 => {
                s.store
                    .transaction(|owner| {
                        owner.replace(
                            Slot::PairingCandidate,
                            None,
                            Some(b"Public malformed saved request"),
                        )
                    })
                    .unwrap();
            }
            5 => {
                let mut marker = b"SPT1".to_vec();
                marker.extend_from_slice(&[0x77; 16]);
                std::fs::write(s.temp.path().join("Sync/primary.pending"), marker).unwrap();
            }
            6 => {
                let mut bytes = std::fs::read(&orphan[0]).unwrap();
                bytes[..4].copy_from_slice(b"SCJ2");
                std::fs::write(&orphan[0], bytes).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(capacity::prepare_cleanup(&mut s.store).is_err());
        assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        assert!(orphan.iter().all(|path| path.exists()));
    }
}

#[test]
fn a_new_unused_file_outside_the_frozen_review_survives_the_old_cleanup() {
    let mut s = fixture(false);
    let orphan = unused(&mut s, [0x77; 16], false);
    let review = selected_cleanup(&mut s);
    let future = unused(&mut s, [0x78; 16], true);
    confirm(&mut s, review, None).unwrap();
    assert!(orphan.iter().all(|path| !path.exists()));
    assert!(future.iter().all(|path| path.exists()));
    let review = selected_cleanup(&mut s);
    assert_eq!(review.summary().encrypted_images, 1);
    confirm(&mut s, review, None).unwrap();
    assert!(future.iter().all(|path| !path.exists()));
}

#[test]
fn cancelled_and_wrong_purpose_permits_never_start_or_resume_cleanup() {
    for wrong_purpose in [false, true] {
        let mut s = fixture(false);
        let orphan = unused(&mut s, [0x77; 16], false);
        let review = selected_cleanup(&mut s);
        let target = if wrong_purpose {
            selected(&mut s, false).authorization_target().unwrap()
        } else {
            review.authorization_target().unwrap()
        };
        let (mut gate, permit) = authorize(target);
        if !wrong_purpose {
            gate.cancel();
        }
        assert!(capacity::apply(&mut s.store, review, permit).is_err());
        assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        assert!(orphan.iter().all(|path| path.exists()));
    }
    let mut s = fixture(false);
    let orphan = unused(&mut s, [0x77; 16], false);
    let review = selected_cleanup(&mut s);
    let initial = review.authorization_target().unwrap();
    assert!(confirm(&mut s, review, Some(1)).is_err());
    let resume = capacity::prepare_resume(&mut s.store).unwrap();
    let (_gate, permit) = authorize(initial);
    assert!(capacity::apply(&mut s.store, resume, permit).is_err());
    assert!(orphan.iter().all(|path| path.exists()));
    assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_some());
    let resume = capacity::prepare_resume(&mut s.store).unwrap();
    confirm(&mut s, resume, None).unwrap();
}

#[test]
fn missing_images_are_accepted_only_after_durable_cleanup_consent() {
    for saved in [false, true] {
        let mut s = fixture(false);
        let orphan = unused(&mut s, [0x77; 16], false);
        let review = selected_cleanup(&mut s);
        if saved {
            assert!(confirm(&mut s, review, Some(1)).is_err());
            std::fs::remove_file(&orphan[0]).unwrap();
            let resume = capacity::prepare_resume(&mut s.store).unwrap();
            confirm(&mut s, resume, None).unwrap();
            assert!(orphan.iter().all(|path| !path.exists()));
        } else {
            std::fs::remove_file(&orphan[0]).unwrap();
            assert!(confirm(&mut s, review, None).is_err());
            assert!(orphan[1].exists());
            assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        }
    }
}

#[cfg(feature = "desktop")]
#[test]
fn production_cleanup_owner_consumes_only_a_fresh_uncancelled_exact_review_token() {
    use crate::{
        account_worker::{
            Command, Reply, history_removal::Retained, restoration_task::Preparation,
        },
        desktop::{SessionState, SessionWitness},
    };
    let mut s = fixture(false);
    let mut retained = Retained::default();
    let preparation = || Preparation::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap();
    assert!(matches!(
        retained
            .prepare_cleanup(&mut s.store, preparation())
            .unwrap(),
        Reply::NoUnusedRecoveryFiles
    ));
    let orphan = unused(&mut s, [0x77; 16], false);
    for cancelled in [false, true] {
        let guard = preparation();
        let Reply::HistoryRemovalReview { token, .. } = retained
            .prepare_cleanup(&mut s.store, guard.clone())
            .unwrap()
        else {
            panic!("review")
        };
        if cancelled {
            guard.cancel();
        } else {
            retained.keep_for(&Command::Inspect);
        }
        assert!(retained.consume(token).is_err());
        assert!(s.backend.memory.slot(Slot::HistoryMaintenance).is_none());
        assert!(orphan.iter().all(|path| path.exists()));
    }
    let Reply::HistoryRemovalReview { token, .. } = retained
        .prepare_cleanup(&mut s.store, preparation())
        .unwrap()
    else {
        panic!("review")
    };
    assert!(retained.consume(Uuid::new_v4()).is_err());
    assert!(retained.consume(token).is_err());
    let Reply::HistoryRemovalReview { token, target, .. } = retained
        .prepare_cleanup(&mut s.store, preparation())
        .unwrap()
    else {
        panic!("review")
    };
    let review = retained.consume(token).unwrap();
    assert!(retained.consume(token).is_err());
    let (_gate, permit) = authorize(target);
    capacity::apply(&mut s.store, review, permit).unwrap();
    assert!(orphan.iter().all(|path| !path.exists()));
}

#[test]
fn explicit_cleanup_releases_full_image_capacity_without_evicting_referenced_history() {
    let mut s = fixture(false);
    let referenced = images(&s);
    let mut orphans = Vec::new();
    for byte in 0x40..0x4f {
        orphans.extend(unused(&mut s, [byte; 16], false));
    }
    assert_eq!(images(&s).len(), 32);
    let review = selected_cleanup(&mut s);
    assert_eq!(review.summary().encrypted_images, 30);
    confirm(&mut s, review, None).unwrap();
    assert_eq!(images(&s), referenced);
    assert!(orphans.iter().all(|path| !path.exists()));
    assert_eq!(unused(&mut s, [0x77; 16], false).len(), 2);
}

#[test]
fn malformed_cleanup_intents_fail_closed_in_the_read_only_catalogue() {
    use base64::{Engine as _, engine::general_purpose::STANDARD};
    let mut s = fixture(false);
    let orphan = unused(&mut s, [0x77; 16], false);
    let review = selected_cleanup(&mut s);
    assert!(confirm(&mut s, review, Some(1)).is_err());
    let original = s.backend.memory.slot(Slot::HistoryMaintenance).unwrap();
    for damage in 0..12 {
        let Value::Object(mut fields) = canonical::parse(&original).unwrap() else {
            unreachable!()
        };
        match damage {
            0 => {
                fields.insert("schema".into(), Value::Int(3));
            }
            1 => {
                fields.insert("kind".into(), Value::text("unknownCleanup"));
            }
            2 => {
                fields.insert("metadata".into(), Value::text("Public unknown field"));
            }
            3 => {
                fields.insert("nonce".into(), Value::text(STANDARD.encode([0; 16])));
            }
            4 => {
                fields.insert("images".into(), Value::Array(Vec::new()));
            }
            5 => {
                let value = fields["images"].as_array().unwrap()[0].clone();
                fields.insert("images".into(), Value::Array(vec![value.clone(), value]));
            }
            6 => {
                let mut images = fields["images"].as_array().unwrap().to_vec();
                images.reverse();
                fields.insert("images".into(), Value::Array(images));
            }
            7 => {
                let image = fields["images"].as_array().unwrap()[0].clone();
                fields.insert("images".into(), Value::Array(vec![image; 33]));
            }
            8 => {
                fields.insert("frame".into(), Value::text(STANDARD.encode([0; 31])));
            }
            9 => {
                fields.insert("binding".into(), Value::Null);
            }
            10 => {
                fields.insert("references".into(), Value::Int(0));
            }
            11 => {
                let mut images = fields["images"].as_array().unwrap().to_vec();
                let mut proof = STANDARD.decode(images[0].as_text().unwrap()).unwrap();
                proof[16] = 2;
                images[0] = Value::text(STANDARD.encode(proof));
                fields.insert("images".into(), Value::Array(images));
            }
            _ => unreachable!(),
        }
        let malformed = Value::Object(fields).encode().unwrap();
        s.store
            .history_transaction_with(|owner| {
                owner.replace(Slot::HistoryMaintenance, Some(&original), Some(&malformed))
            })
            .unwrap();
        assert!(history::inspect(&mut s.store).is_err());
        assert!(capacity::prepare_resume(&mut s.store).is_err());
        assert!(orphan.iter().all(|path| path.exists()));
        s.store
            .history_transaction_with(|owner| {
                owner.replace(Slot::HistoryMaintenance, Some(&malformed), Some(&original))
            })
            .unwrap();
    }
    let resume = capacity::prepare_resume(&mut s.store).unwrap();
    confirm(&mut s, resume, None).unwrap();
}
