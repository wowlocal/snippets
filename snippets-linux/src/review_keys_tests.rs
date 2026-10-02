//! Actual review/activation against fictional peers and isolated retained history.
use super::*;

#[test]
fn old_history_key_can_be_reviewed_after_another_library_and_new_dataset_or_epoch() {
    for changed_epoch in [false, true] {
        let mut s = setup();
        let review = prepare(&mut s).unwrap();
        commit(&mut s, review).unwrap();
        let original_pin = s.remote.pin.clone();
        let original_key =
            Installed::decode(&s.backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
        let original_evidence = s.remote.recovery.as_ref().map(|e| Evidence {
            version: e.version,
            ciphertext: e.ciphertext.clone(),
        });

        s.remote.pin.space = Uuid::from_u128(91);
        s.remote.pin.membership = Binding::from_checkpoint([91; 32]);
        s.remote.pin.dataset = Binding::from_checkpoint([92; 32]);
        let other = Bundle::from_material(&[93; 64]).unwrap();
        let recovery = bootstrap::create_recovery(
            &other,
            s.remote.pin.server.clone(),
            s.remote.pin.space,
            s.remote.pin.epoch as i64,
        )
        .unwrap();
        s.kit = recovery.kit;
        s.remote.recovery = Some(Evidence {
            version: 1,
            ciphertext: recovery.ciphertext,
        });
        s.remote.public =
            Some(Authority::new(&other, &s.remote.pin.context().unwrap()).public_key());
        let review = prepare(&mut s).unwrap();
        commit(&mut s, review).unwrap();
        let history =
            canonical::parse(&s.backend.memory.slot(Slot::AccountReview).unwrap()).unwrap();
        let retained_entries = history.as_object().unwrap()["entries"].encode().unwrap();
        let previous_checkpoint = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();

        s.remote.pin = original_pin;
        s.remote.pin.membership = Binding::from_checkpoint([94; 32]);
        s.remote.pin.dataset = Binding::from_checkpoint([95; 32]);
        s.remote.pin.epoch += u64::from(changed_epoch);
        s.remote.public = Some(
            Authority::new(&original_key.bundle, &s.remote.pin.context().unwrap()).public_key(),
        );
        s.remote.recovery = original_evidence;
        assert!(
            s.store
                .transaction_with(|owner| load_locked(owner, &mut s.remote))
                .is_err()
        );
        let review = s
            .store
            .transaction_with(|owner| {
                handover::prepare_locked(owner, &mut s.remote, None, &|_| Ok(()))
            })
            .unwrap();
        assert!(review.reuses_local_key() && review.summary().local_records == 1);
        assert!(
            std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == previous_checkpoint
        );
        let (_gate, permit) = authorize(review.authorization_target().unwrap());
        let outcome = s
            .store
            .transaction_with(|owner| {
                handover::commit_authorized_locked(
                    owner,
                    &mut s.remote,
                    review,
                    permit,
                    &|_| Ok(()),
                )
            })
            .unwrap();
        assert!(
            outcome
                == Outcome::Ready {
                    kit: if changed_epoch {
                        KitStatus::None
                    } else {
                        KitStatus::VerifiedCurrent
                    }
                }
        );
        let current = Installed::decode(&s.backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
        assert!(
            current.binding == s.remote.pin
                && current.bundle.for_secure_storage() == original_key.bundle.for_secure_storage()
        );
        let history =
            canonical::parse(&s.backend.memory.slot(Slot::AccountReview).unwrap()).unwrap();
        let entries = history.as_object().unwrap()["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 3);
        assert!(Value::Array(entries[..2].to_vec()).encode().unwrap() == retained_entries);
        assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == s.primary);
        assert!(!handover::inspect(&mut s.store).unwrap().pending);
    }
}

#[test]
fn active_recovery_presentation_survives_reviewed_scope_change_only_with_current_evidence() {
    for replaced in [false, true] {
        let mut s = setup();
        let previous = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
        let old_bootstrap = super::super::super::Archive::from_snapshot(s.old[1].clone()).unwrap();
        let old_presentation = old_bootstrap.presentation.unwrap();
        let (kit, ciphertext) = old_presentation.retained().unwrap();
        let code = kit.encode_secret_qr().unwrap();
        s.remote.pin.epoch = previous.binding.epoch;
        s.remote.public =
            Some(Authority::new(&previous.bundle, &s.remote.pin.context().unwrap()).public_key());
        s.remote.recovery = Some(Evidence {
            version: if replaced {
                2
            } else {
                old_presentation.version
            },
            ciphertext: if replaced {
                vec![0; 100]
            } else {
                ciphertext.to_vec()
            },
        });
        let review = s
            .store
            .transaction_with(|owner| {
                handover::prepare_locked(owner, &mut s.remote, None, &|_| Ok(()))
            })
            .unwrap();
        let (_gate, permit) = authorize(review.authorization_target().unwrap());
        let outcome = s
            .store
            .transaction_with(|owner| {
                handover::commit_authorized_locked(
                    owner,
                    &mut s.remote,
                    review,
                    permit,
                    &|_| Ok(()),
                )
            })
            .unwrap();
        assert!(
            outcome
                == Outcome::Ready {
                    kit: if replaced {
                        KitStatus::Replaced
                    } else {
                        KitStatus::AwaitingPresentation
                    }
                }
        );
        let current =
            super::super::super::Archive::from_snapshot(s.backend.memory.slot(Slot::Bootstrap))
                .unwrap();
        let presentation = current.presentation.unwrap();
        assert!(
            presentation.binding == s.remote.pin
                && presentation
                    .retained()
                    .unwrap()
                    .0
                    .encode_secret_qr()
                    .unwrap()
                    == code
        );
        let target = s
            .store
            .transaction_with(|owner| disclosure::prepare_locked(owner, &mut s.remote));
        assert_eq!(target.is_ok(), !replaced);
        let history = s.store.transaction_with(handover::Archive::load).unwrap();
        assert!(history.entries[0].source[1] == s.old[1]);
        assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == s.primary);
    }
}
