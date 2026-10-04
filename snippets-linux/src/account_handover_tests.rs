//! Fictional peers, temporary primary files and a Secret Service fault backend.
use super::*;
use crate::key_store::handover;
use crate::key_store::{
    Failure as KeyFailure, Result as KeyResult,
    tests::{FakeRemote, Memory},
};
use crate::{inbound::Feed, journal::Checkpoint, model::Library, receiver};
use std::sync::{Arc, Mutex};

#[path = "review_keys_tests.rs"]
mod rebinding;

#[path = "local_completion_tests.rs"]
mod offline;

#[path = "key_history_tests.rs"]
mod history_inspection;

#[path = "history_restore_owner_tests.rs"]
mod restoration;

#[path = "account_vault_header_tests.rs"]
mod vault_headers;

#[path = "history_capacity_owner_tests.rs"]
mod history_capacity;

impl receiver::Remote for FakeRemote {
    fn preflight(&mut self) -> receiver::RemoteResult<receiver::Observation> {
        crate::key_store::Remote::preflight(self).map_err(|_| cloud::Failure::InvalidResponse)?;
        Ok(receiver::Observation {
            scope: self.pin.checkpoint_scope(),
            feed: Feed::new(Uuid::from_u128(9), self.pin.epoch).unwrap(),
        })
    }
    fn fetch(
        &mut self,
        _: Option<&cloud::Cursor>,
    ) -> receiver::RemoteResult<receiver::FetchedPage> {
        panic!("Account handover must not fetch records")
    }
}
#[derive(Clone)]
struct Faults {
    memory: Memory,
    state: Arc<Mutex<FaultState>>,
}
#[derive(Default)]
struct FaultState {
    calls: usize,
    fail: Option<(usize, bool)>,
}
impl Faults {
    fn arm(&self, call: usize, after: bool) {
        let mut state = self.state.lock().unwrap();
        state.calls = 0;
        state.fail = Some((call, after));
    }
    fn step(&self) -> Option<bool> {
        let mut state = self.state.lock().unwrap();
        state.calls += 1;
        state
            .fail
            .filter(|(n, _)| *n == state.calls)
            .map(|(_, after)| after)
    }
}
impl Backend for Faults {
    fn read(
        &mut self,
        ns: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        self.memory.read(ns, slot)
    }
    fn write(&mut self, ns: &[u8; 16], slot: Slot, value: &[u8]) -> secret_store::Result<()> {
        let fail = self.step();
        if fail != Some(false) {
            self.memory.write(ns, slot, value)?;
        }
        if fail.is_some() {
            return Err(secret_store::Failure::Unavailable);
        }
        Ok(())
    }
    fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
        let fail = self.step();
        if fail != Some(false) {
            self.memory.delete(ns, slot)?;
        }
        if fail.is_some() {
            return Err(secret_store::Failure::Unavailable);
        }
        Ok(())
    }
}
struct Setup {
    temp: tempfile::TempDir,
    store: Store<Faults>,
    backend: Faults,
    remote: FakeRemote,
    kit: RecoveryKit,
    old: [Option<Zeroizing<Vec<u8>>>; 5],
    primary: Vec<u8>,
    old_checkpoint: Vec<u8>,
}
fn setup() -> Setup {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let backend = Faults {
        memory: memory.clone(),
        state: Arc::new(Mutex::new(FaultState::default())),
    };
    let mut store = Store::initialize(temp.path(), backend.clone()).unwrap();
    let mut remote = FakeRemote::new(memory);
    store
        .transaction_with(|o| initialize_locked(o, &mut remote))
        .unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let record = crate::snapshot_review::tests::envelope(1, "Public handover local entry", 4);
    crate::snapshot_review::tests::write_primary(&library, std::slice::from_ref(&record));
    let material = store
        .transaction(|o| o.checkpoint_material(true))
        .unwrap()
        .unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let mut checkpoint =
        Checkpoint::load(&library, &key, &salt, remote.pin.checkpoint_scope()).unwrap();
    checkpoint.journal.key_epoch = Some(1);
    checkpoint
        .journal
        .projected
        .insert(record.id, record.clone());
    checkpoint
        .journal
        .record_confirmed(
            record,
            crate::snapshot_review::tests::version("public-old-version"),
        )
        .unwrap();
    checkpoint.save(&library, &key, &salt).unwrap();
    // These opaque previous capabilities are archived byte-for-byte, never
    // interpreted or replayed against the new peer during handover.
    store
        .transaction(|o| {
            o.replace(
                Slot::PairingRecipient,
                None,
                Some(b"Public retained pairing capability"),
            )?;
            o.replace(
                Slot::SpaceCreation,
                None,
                Some(b"Public retained creation capability"),
            )?;
            o.replace(
                Slot::KeyMutation,
                None,
                Some(b"Public retained signed capability"),
            )?;
            Ok(())
        })
        .unwrap();
    let old = std::array::from_fn(|index| backend.memory.slot(handover::SLOTS[index].0));
    remote.pin.membership = Binding::from_checkpoint([0x77; 32]);
    remote.pin.dataset = Binding::from_checkpoint([0x88; 32]);
    remote.pin.epoch = 2;
    let bundle = Bundle::from_material(&[0x33; 64]).unwrap();
    let recovery =
        bootstrap::create_recovery(&bundle, remote.pin.server.clone(), remote.pin.space, 2)
            .unwrap();
    remote.public = Some(Authority::new(&bundle, &remote.pin.context().unwrap()).public_key());
    remote.recovery = Some(Evidence {
        version: 1,
        ciphertext: recovery.ciphertext,
    });
    let primary = std::fs::read(library.path()).unwrap();
    let old_checkpoint = std::fs::read(temp.path().join("Sync/journal.bin")).unwrap();
    Setup {
        temp,
        store,
        backend,
        remote,
        kit: recovery.kit,
        old,
        primary,
        old_checkpoint,
    }
}
fn prepare(s: &mut Setup) -> handover::Result<handover::Review> {
    let kit = RecoveryKit::decode_secret_qr(&s.kit.encode_secret_qr().unwrap()).unwrap();
    s.store
        .transaction_with(|o| handover::prepare_locked(o, &mut s.remote, Some(kit), &|_| Ok(())))
}
fn commit(s: &mut Setup, review: handover::Review) -> handover::Result<Outcome> {
    s.store
        .transaction_with(|o| handover::commit_locked(o, &mut s.remote, review, &|_| Ok(())))
}
fn resume(s: &mut Setup) -> handover::Result<Outcome> {
    s.store.transaction_with(|o| {
        let archive = handover::Archive::load(o)?;
        handover::resume_archive(o, &mut s.remote, archive, &|_| Ok(()))
    })
}
fn install_account(s: &mut Setup) {
    use crate::auth_store::{self, Deployment, Replacement};
    let deployment = Deployment::from_discovery(s.remote.pin.server.clone(), s.remote.pin.instance);
    let result: auth_store::Result<()> = s.store.transaction_with(|o| {
        let mut archive = auth_store::Archive::load(o)?;
        let lease = archive.begin(Replacement::Interactive, deployment)?;
        archive.save(o)?;
        let grant = cloud::IssuedGrant::fixture_signed_in(br#"{"access_token":"public-handover-access","refresh_token":"public-handover-refresh","expires_in":300,"token_type":"Bearer","account":{"id":"5e1f0c2a-7b3d-4e8f-9a6b-c4d2e0f1a3b5"}}"#, "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7").unwrap();
        let session = grant.accept(|credentials| {
            archive.stage_issued(&lease, credentials).map_err(|_| cloud::Failure::CredentialCommit)?;
            archive.save(o).map_err(|_| cloud::Failure::CredentialCommit)
        }, None, None).map_err(|e| auth_store::Failure::Cloud(e.failure))?;
        archive.publish(&lease, &session, 1000)?;
        archive.save(o)?;
        archive.begin_cleanup(&lease)?;
        archive.finish_cleanup(&lease)?;
        archive.save(o)
    });
    result.unwrap();
}
fn refreshed_credentials(s: &mut Setup, change_account: bool) {
    s.store
        .transaction(|o| {
            let old = o.read(Slot::Credentials)?.unwrap();
            let mut value = canonical::parse(&old).unwrap();
            let Value::Object(ref mut fields) = value else {
                unreachable!()
            };
            let generation = fields["generation"].as_int().unwrap() + 1;
            fields.insert("generation".into(), Value::Int(generation));
            let Value::Object(ref mut session) = *fields.get_mut("current").unwrap() else {
                unreachable!()
            };
            session.insert(
                "pair".into(),
                object([
                    ("access", Value::text("public-refreshed-access")),
                    ("refresh", Value::text("public-refreshed-refresh")),
                ]),
            );
            session.insert("expiresAt".into(), Value::Int(2500));
            if change_account {
                // Another fictional native account (UUID identities only).
                session.insert(
                    "account".into(),
                    Value::text("6a7b8c9d-0e1f-4a2b-8c3d-4e5f6a7b8c9d"),
                );
            }
            o.replace(
                Slot::Credentials,
                Some(&old),
                Some(&value.encode().unwrap()),
            )
        })
        .unwrap();
}
fn assert_old_slots(s: &Setup) {
    for (index, (slot, _)) in handover::SLOTS.iter().enumerate() {
        assert!(s.backend.memory.slot(*slot) == s.old[index]);
    }
}
fn assert_complete(s: &mut Setup) {
    let status = handover::inspect(&mut s.store).unwrap();
    assert!(!status.pending);
    assert_eq!(status.retained_libraries, 1);
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    let entry = &archive.entries[0];
    assert!(entry.completed);
    for (index, (slot, _)) in handover::SLOTS.iter().enumerate() {
        assert!(entry.source[index] == s.old[index]);
        let current = s.backend.memory.slot(*slot);
        if index == 1 && current.as_deref().map(Vec::as_slice) != entry.target(index) {
            let changed = super::super::Archive::from_snapshot(current).unwrap();
            assert!(changed.generation > 1);
            assert!(matches!(
                changed.outcome(),
                Outcome::Ready {
                    kit: KitStatus::Replaced
                }
            ));
            let target =
                super::super::Archive::from_snapshot(Some(entry.target_bootstrap.clone())).unwrap();
            assert!(
                !target
                    .presentation
                    .unwrap()
                    .matches_evidence(s.remote.recovery.as_ref().unwrap())
            );
        } else {
            assert!(current.as_deref().map(Vec::as_slice) == entry.target(index));
        }
    }
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == s.primary);
    let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
    let key = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let library = Library::prepare(s.temp.path().into()).unwrap();
    let checkpoint =
        Checkpoint::load(&library, &key, &salt, s.remote.pin.checkpoint_scope()).unwrap();
    assert!(checkpoint.journal.agreed_envelopes().is_empty());
    assert_eq!(checkpoint.journal.key_epoch, Some(2));
    assert_eq!(checkpoint.journal.pending().unwrap().len(), 1);
    s.store
        .transaction_with(|o| load_locked(o, &mut s.remote))
        .unwrap()
        .unwrap();
    assert_eq!(
        s.remote.posts, 1,
        "Only the original fixture bootstrap may POST"
    );
}
#[test]
fn confirmation_retains_all_capabilities_before_journal_and_key_activation() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    assert_eq!(review.summary().local_records, 1);
    assert_old_slots(&s);
    assert!(!s.temp.path().join("Sync/Reviews").exists());
    assert!(!handover::inspect(&mut s.store).unwrap().pending);
    assert!(matches!(
        commit(&mut s, review).unwrap(),
        Outcome::Ready {
            kit: KitStatus::VerifiedCurrent
        }
    ));
    assert_complete(&mut s);
}
#[test]
fn every_lost_keyring_write_and_delete_resumes_from_the_same_receipt() {
    // Pending review, new key, new bootstrap, three retired active capabilities,
    // completed review. Test both an unwritten operation and a lost success reply.
    for call in 1..=7 {
        for after in [false, true] {
            let mut s = setup();
            let review = prepare(&mut s).unwrap();
            s.backend.arm(call, after);
            assert!(commit(&mut s, review).is_err());
            let status = handover::inspect(&mut s.store).unwrap();
            if call == 1 {
                assert_old_slots(&s);
                assert!(
                    std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap()
                        == s.old_checkpoint
                );
            }
            s.backend.arm(usize::MAX, false);
            if status.pending {
                s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
                resume(&mut s).unwrap();
            } else if call == 1 && !after {
                let review = prepare(&mut s).unwrap();
                commit(&mut s, review).unwrap();
            }
            assert_complete(&mut s);
        }
    }
}
#[test]
fn pending_transition_fences_normal_key_use_and_mutation_cancellation() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    s.backend.arm(1, true);
    assert!(commit(&mut s, review).is_err());
    assert!(handover::inspect(&mut s.store).unwrap().pending);
    for action in 0..5 {
        let result: KeyResult<()> = s.store.transaction_with(|o| match action {
            0 => check_admission_locked(o, &s.remote.pin),
            1 => load_locked(o, &mut s.remote).map(|_| ()),
            2 => initialize_locked(o, &mut s.remote).map(|_| ()),
            3 => mutations::cancel_locked(o, &s.remote.pin),
            _ => recipient::check_admission(o, &s.remote.pin),
        });
        assert!(matches!(result, Err(KeyFailure::Busy)));
    }
    assert_old_slots(&s);
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
}
#[test]
fn changed_primary_or_source_secret_invalidates_prepared_consent() {
    for kind in 0..5 {
        let mut s = setup();
        let review = prepare(&mut s).unwrap();
        if kind == 0 {
            let mut bytes = s.primary.clone();
            bytes.push(b'\n');
            std::fs::write(s.temp.path().join("snippets.json"), bytes).unwrap();
        } else {
            let slot = [
                Slot::Bootstrap,
                Slot::Credentials,
                Slot::PairingRecipient,
                Slot::CheckpointKey,
            ][kind - 1];
            s.store
                .transaction(|o| {
                    let old = o.read(slot)?;
                    let replacement = if slot == Slot::CheckpointKey {
                        vec![0x11; 64]
                    } else {
                        b"Public changed secret generation".to_vec()
                    };
                    o.replace(slot, old.as_deref().map(Vec::as_slice), Some(&replacement))
                })
                .unwrap();
        }
        assert!(commit(&mut s, review).is_err());
        assert!(s.backend.memory.slot(Slot::AccountReview).is_none());
        assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
    }
}
#[test]
fn changed_remote_or_wrong_recovery_cannot_stage_a_handover() {
    for kind in 0..4 {
        let mut s = setup();
        if kind == 0 {
            s.remote.public = Some([0xaa; 32]);
        }
        if kind == 1 {
            s.remote.recovery.as_mut().unwrap().ciphertext[30] ^= 1;
        }
        if kind == 2 {
            s.remote.pin.epoch = 3;
        }
        if kind == 3 {
            s.remote.change_on = Some(s.remote.calls + 3);
        }
        assert!(prepare(&mut s).is_err());
        assert_old_slots(&s);
        assert!(s.backend.memory.slot(Slot::AccountReview).is_none());
        assert!(!s.temp.path().join("Sync/Reviews").exists());
    }
}
#[test]
fn pending_before_publication_refuses_later_primary_edits() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    s.backend.arm(1, true);
    assert!(commit(&mut s, review).is_err());
    let mut edited = s.primary.clone();
    edited.push(b'\n');
    std::fs::write(s.temp.path().join("snippets.json"), &edited).unwrap();
    s.backend.arm(usize::MAX, false);
    assert!(resume(&mut s).is_err());
    assert_old_slots(&s);
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == edited);
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
    assert!(handover::inspect(&mut s.store).unwrap().pending);
}
#[test]
fn after_publication_local_edits_survive_key_activation() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    s.backend.arm(2, false);
    assert!(commit(&mut s, review).is_err());
    let mut edited = s.primary.clone();
    edited.push(b'\n');
    std::fs::write(s.temp.path().join("snippets.json"), &edited).unwrap();
    s.backend.arm(usize::MAX, false);
    resume(&mut s).unwrap();
    s.primary = edited;
    assert_complete(&mut s);
}
#[test]
fn changed_credentials_or_foreign_pending_slot_cannot_be_overwritten_on_restart() {
    for slot in [
        Slot::Credentials,
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::KeyMutation,
        Slot::CheckpointKey,
    ] {
        let mut s = setup();
        let review = prepare(&mut s).unwrap();
        s.backend.arm(1, true);
        assert!(commit(&mut s, review).is_err());
        s.backend.arm(usize::MAX, false);
        s.store
            .transaction(|o| {
                let old = o.read(slot)?;
                o.replace(
                    slot,
                    old.as_deref().map(Vec::as_slice),
                    Some(b"Public foreign pending generation"),
                )
            })
            .unwrap();
        let bytes = s.backend.memory.slot(slot).unwrap();
        assert!(resume(&mut s).is_err());
        assert!(s.backend.memory.slot(slot).as_deref() == Some(&bytes));
        assert!(handover::inspect(&mut s.store).unwrap().pending);
        assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
    }
}

#[test]
fn same_account_refresh_resumes_durable_consent_but_foreign_account_cannot() {
    for change_account in [false, true] {
        let mut s = setup();
        install_account(&mut s);
        let review = prepare(&mut s).unwrap();
        s.backend.arm(1, true);
        assert!(commit(&mut s, review).is_err());
        s.backend.arm(usize::MAX, false);
        refreshed_credentials(&mut s, change_account);
        s.store = Store::load(s.temp.path(), s.backend.clone()).unwrap();
        if change_account {
            assert!(resume(&mut s).is_err());
            assert_old_slots(&s);
            assert!(handover::inspect(&mut s.store).unwrap().pending);
        } else {
            resume(&mut s).unwrap();
            assert_complete(&mut s);
        }
    }
}

#[test]
fn refreshing_a_process_local_review_requires_fresh_consent() {
    let mut s = setup();
    install_account(&mut s);
    let review = prepare(&mut s).unwrap();
    refreshed_credentials(&mut s, false);
    assert!(matches!(
        commit(&mut s, review),
        Err(handover::Failure::Changed)
    ));
    assert_old_slots(&s);
    assert!(s.backend.memory.slot(Slot::AccountReview).is_none());
}

#[test]
fn existing_verified_key_can_be_retained_for_a_new_dataset_without_recovery_input() {
    let mut s = setup();
    let previous = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
    s.remote.public =
        Some(Authority::new(&previous.bundle, &s.remote.pin.context().unwrap()).public_key());
    let review = s
        .store
        .transaction_with(|o| handover::prepare_locked(o, &mut s.remote, None, &|_| Ok(())))
        .unwrap();
    assert!(matches!(
        commit(&mut s, review).unwrap(),
        Outcome::Ready {
            kit: KitStatus::None
        }
    ));
    let installed = Installed::decode(&s.backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
    assert!(installed.bundle.for_secure_storage() == previous.bundle.for_secure_storage());
    assert_complete(&mut s);
}

#[test]
fn same_scope_epoch_key_replacement_is_verified_and_reviewed() {
    let mut s = setup();
    let previous = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
    s.remote.pin = previous.binding;
    let bundle = Bundle::from_material(&[0x44; 64]).unwrap();
    let recovery =
        bootstrap::create_recovery(&bundle, s.remote.pin.server.clone(), s.remote.pin.space, 1)
            .unwrap();
    s.kit = recovery.kit;
    s.remote.public = Some(Authority::new(&bundle, &s.remote.pin.context().unwrap()).public_key());
    s.remote.recovery = Some(Evidence {
        version: 1,
        ciphertext: recovery.ciphertext,
    });
    let review = prepare(&mut s).unwrap();
    assert!(review.entry.receipt.previous().key_material_changed);
    commit(&mut s, review).unwrap();
    let installed = Installed::decode(&s.backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
    assert!(installed.bundle.for_secure_storage() == bundle.for_secure_storage());
    assert!(!handover::inspect(&mut s.store).unwrap().pending);
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == s.primary);
}

#[test]
fn unchanged_authority_is_not_a_reset_request() {
    let mut s = setup();
    let previous = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
    s.remote.pin = previous.binding;
    s.remote.public =
        Some(Authority::new(&previous.bundle, &s.remote.pin.context().unwrap()).public_key());
    let result = s
        .store
        .transaction_with(|o| handover::prepare_locked(o, &mut s.remote, None, &|_| Ok(())));
    assert!(matches!(result, Err(handover::Failure::Unavailable)));
    assert_old_slots(&s);
    assert!(!s.temp.path().join("Sync/Reviews").exists());
}

#[test]
fn completed_lost_reply_is_idempotent_and_does_not_republish_the_journal() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    s.backend.arm(7, true);
    assert!(commit(&mut s, review).is_err());
    assert!(!handover::inspect(&mut s.store).unwrap().pending);
    let journal = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
    s.backend.arm(usize::MAX, false);
    resume(&mut s).unwrap();
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == journal);
    assert_complete(&mut s);
}

#[test]
fn rotated_recovery_state_is_reported_as_replaced_after_activation() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    s.remote.recovery.as_mut().unwrap().version = 2;
    assert!(matches!(
        commit(&mut s, review).unwrap(),
        Outcome::Ready {
            kit: KitStatus::Replaced
        }
    ));
    assert_complete(&mut s);
}

#[test]
fn complete_history_limits_are_checked_before_staging_or_overwriting_any_capability() {
    for byte_limit in [false, true] {
        let mut s = setup();
        let review = prepare(&mut s).unwrap();
        let mut value = review.entry.value().unwrap();
        let Value::Object(ref mut fields) = value else {
            unreachable!()
        };
        fields.insert("phase".into(), Value::text("completed"));
        let entries = if byte_limit {
            let Value::Object(ref mut source) = *fields.get_mut("source").unwrap() else {
                unreachable!()
            };
            source.insert("pairingRecipient".into(), Value::Null);
            let empty = object([
                ("schema", Value::Int(3)),
                ("generation", Value::Int(1)),
                ("entries", Value::Array(vec![value.clone()])),
            ])
            .encode()
            .unwrap();
            let capacity = secret_store::MAX_SECRET_BYTES - empty.len() - 512;
            let Value::Object(ref mut fields) = value else {
                unreachable!()
            };
            let Value::Object(ref mut source) = *fields.get_mut("source").unwrap() else {
                unreachable!()
            };
            source.insert(
                "pairingRecipient".into(),
                Value::text(STANDARD.encode(vec![b'p'; capacity / 4 * 3])),
            );
            vec![value]
        } else {
            (1..=MAX_ENTRIES)
                .map(|index| {
                    let mut entry = value.clone();
                    let Value::Object(ref mut fields) = entry else {
                        unreachable!()
                    };
                    let mut receipt = review.entry.receipt.encode_secret().unwrap();
                    receipt[165..181].copy_from_slice(&(index as u128).to_be_bytes());
                    fields.insert("receipt".into(), Value::text(STANDARD.encode(receipt)));
                    entry
                })
                .collect()
        };
        let bytes = object([
            ("schema", Value::Int(3)),
            ("generation", Value::Int(1)),
            ("entries", Value::Array(entries)),
        ])
        .encode()
        .unwrap();
        assert!(bytes.len() <= secret_store::MAX_SECRET_BYTES);
        s.store
            .transaction(|o| o.replace(Slot::AccountReview, None, Some(&bytes)))
            .unwrap();
        assert!(matches!(
            prepare(&mut s),
            Err(handover::Failure::RetentionFull)
        ));
        assert_old_slots(&s);
        assert!(s.backend.memory.slot(Slot::AccountReview).as_deref() == Some(&bytes));
        assert!(!s.temp.path().join("Sync/Reviews").exists());
    }
}

#[test]
fn malformed_handover_schema_fences_normal_admission_without_changing_keys() {
    for kind in 0..10 {
        let mut s = setup();
        let review = prepare(&mut s).unwrap();
        let mut value = object([
            ("schema", Value::Int(3)),
            ("generation", Value::Int(1)),
            ("entries", Value::Array(vec![review.entry.value().unwrap()])),
        ]);
        let Value::Object(ref mut archive) = value else {
            unreachable!()
        };
        match kind {
            0 => {
                archive.insert("unexpected".into(), Value::Bool(true));
            }
            1 => {
                archive.insert("schema".into(), Value::Int(5));
            }
            2 => {
                archive.insert("generation".into(), Value::Int(0));
            }
            3 => {
                archive.insert("entries".into(), Value::Array(vec![]));
            }
            4 => {
                archive.insert(
                    "entries".into(),
                    Value::Array(vec![
                        review.entry.value().unwrap(),
                        review.entry.value().unwrap(),
                    ]),
                );
            }
            9 => {
                let mut entry = review.entry.value().unwrap();
                let Value::Object(ref mut fields) = entry else {
                    unreachable!()
                };
                fields.insert("phase".into(), Value::text("completed"));
                archive.insert("entries".into(), Value::Array(vec![entry.clone(), entry]));
            }
            _ => {
                let Value::Array(ref mut entries) = *archive.get_mut("entries").unwrap() else {
                    unreachable!()
                };
                let Value::Object(ref mut entry) = entries[0] else {
                    unreachable!()
                };
                match kind {
                    5 => {
                        entry.insert(
                            "accountHash".into(),
                            Value::text(STANDARD.encode([1u8; 31])),
                        );
                    }
                    6 => {
                        entry.insert("phase".into(), Value::Bool(true));
                    }
                    7 => {
                        entry.insert("checkpoint".into(), Value::text(STANDARD.encode([1u8; 63])));
                    }
                    _ => {
                        entry.insert(
                            "receipt".into(),
                            Value::text(STANDARD.encode(vec![0u8; 318])),
                        );
                    }
                }
            }
        }
        let bytes = value.encode().unwrap();
        s.store
            .transaction(|o| o.replace(Slot::AccountReview, None, Some(&bytes)))
            .unwrap();
        assert!(handover::inspect(&mut s.store).is_err());
        assert!(
            s.store
                .transaction_with(|o| check_admission_locked(o, &s.remote.pin))
                .is_err()
        );
        assert_old_slots(&s);
        assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
        assert!(!s.temp.path().join("Sync/Reviews").exists());
    }
}

#[test]
fn another_root_cannot_borrow_a_prepared_review_even_with_identical_active_slots() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    let other = tempfile::tempdir().unwrap();
    let mut other_store = Store::initialize(other.path(), s.backend.clone()).unwrap();
    other_store
        .transaction(|o| {
            for (index, (slot, _)) in handover::SLOTS.iter().enumerate() {
                o.replace(*slot, None, s.old[index].as_deref().map(Vec::as_slice))?;
            }
            o.replace(Slot::CheckpointKey, None, Some(&review.entry.checkpoint))
        })
        .unwrap();
    let result = other_store
        .transaction_with(|o| handover::commit_locked(o, &mut s.remote, review, &|_| Ok(())));
    assert!(result.is_err());
    assert!(!other.path().join("Sync").exists());
    assert!(!handover::inspect(&mut other_store).unwrap().pending);
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
}

#[test]
fn staged_history_and_receipts_never_write_plaintext_key_or_recovery_material() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    let secret = review.entry.value().unwrap().encode().unwrap();
    s.backend.arm(1, true);
    assert!(commit(&mut s, review).is_err());
    let directory = s.temp.path().join("Sync/Reviews");
    assert_eq!(std::fs::read_dir(&directory).unwrap().count(), 2);
    for entry in std::fs::read_dir(directory).unwrap() {
        let bytes = std::fs::read(entry.unwrap().path()).unwrap();
        assert!(bytes.starts_with(b"SCJ1"));
        assert!(!bytes.windows(secret.len()).any(|v| v == secret.as_slice()));
        for public_secret in [
            b"Public retained pairing capability".as_slice(),
            b"Public retained signed capability".as_slice(),
            b"Public handover local entry".as_slice(),
        ] {
            assert!(
                !bytes
                    .windows(public_secret.len())
                    .any(|v| v == public_secret)
            );
        }
    }
    assert!(s.backend.memory.slot(Slot::AccountReview).is_some());
    assert_old_slots(&s);
}

fn authorize(target: Target) -> (crate::local_auth::Gate, Permit) {
    let mut gate = crate::local_auth::Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(
            target,
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )
        .unwrap();
    let proof = crate::local_auth::authenticate_fixture(request).unwrap();
    let permit = gate.accept(proof).unwrap();
    (gate, permit)
}
fn pending_before_publication(s: &mut Setup) {
    let review = prepare(s).unwrap();
    s.backend.arm(1, true);
    assert!(commit(s, review).is_err());
    s.backend.arm(usize::MAX, false);
    assert!(handover::inspect(&mut s.store).unwrap().pending);
}

#[test]
fn fresh_authorization_is_bound_to_the_exact_review_and_cancellation_purpose() {
    for kind in 0..4 {
        let mut s = setup();
        let first = prepare(&mut s).unwrap();
        let mut target = first.authorization_target().unwrap();
        if kind == 0 {
            target = Target::new(
                s.remote.pin.clone(),
                Purpose::CancelLibrarySwitch,
                1,
                [0x11; 32],
            )
            .unwrap();
        }
        let (mut gate, permit) = authorize(target);
        let review = if kind == 1 {
            prepare(&mut s).unwrap()
        } else {
            first
        };
        if kind == 2 {
            gate.cancel();
        }
        let result = s.store.transaction_with(|o| {
            handover::commit_authorized_locked(o, &mut s.remote, review, permit, &|_| Ok(()))
        });
        if kind == 3 {
            result.unwrap();
            assert_complete(&mut s);
        } else {
            assert!(matches!(
                result,
                Err(handover::Failure::Key(KeyFailure::Authentication(_)))
            ));
            assert_old_slots(&s);
            assert!(s.backend.memory.slot(Slot::AccountReview).is_none());
            assert!(!s.temp.path().join("Sync/Reviews").exists());
        }
    }
}

#[test]
fn offline_cancellation_preserves_later_local_changes_and_all_candidate_history() {
    let mut s = setup();
    install_account(&mut s);
    pending_before_publication(&mut s);
    let mut edited = s.primary.clone();
    edited.push(b'\n');
    std::fs::write(s.temp.path().join("snippets.json"), &edited).unwrap();
    // Changing/signing out the remote account cannot prevent fresh local owner
    // authorization from cancelling an unpublished local switch.
    refreshed_credentials(&mut s, true);
    let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    handover::cancel(&mut s.store, permit).unwrap();
    assert!(!handover::inspect(&mut s.store).unwrap().pending);
    assert_old_slots(&s);
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == edited);
    assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == s.old_checkpoint);
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    assert!(archive.entries[0].cancelled && !archive.entries[0].completed);
    assert!(archive.entries[0].source == s.old);
    assert!(handover::prepare_resume_authorization(&mut s.store).is_err());
}

#[test]
fn cancelling_a_published_or_changed_checkpoint_never_reverts_keys_or_the_journal() {
    for kind in 0..5 {
        let mut s = setup();
        let review = prepare(&mut s).unwrap();
        s.backend.arm(if kind == 0 { 2 } else { 1 }, true);
        assert!(commit(&mut s, review).is_err());
        s.backend.arm(usize::MAX, false);
        match kind {
            1 => {
                let path = std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
                    .unwrap()
                    .next()
                    .unwrap()
                    .unwrap()
                    .path();
                let mut bytes = std::fs::read(&path).unwrap();
                let last = bytes.len() - 1;
                bytes[last] ^= 1;
                std::fs::write(path, bytes).unwrap();
            }
            2 => {
                let material = s.backend.memory.slot(Slot::CheckpointKey).unwrap();
                let key = RootKey::from_bytes(&material[..32]).unwrap();
                let salt = material[32..].try_into().unwrap();
                let previous = Installed::decode(s.old[0].as_deref().unwrap()).unwrap();
                let library = Library::prepare(s.temp.path().into()).unwrap();
                let mut journal =
                    Checkpoint::load(&library, &key, &salt, previous.binding.checkpoint_scope())
                        .unwrap();
                journal
                    .journal
                    .desire(crate::snapshot_review::tests::envelope(
                        2,
                        "Public new old-scope intent",
                        8,
                    ))
                    .unwrap();
                journal.save(&library, &key, &salt).unwrap();
            }
            3 => {
                let mut marker = b"SPT1".to_vec();
                marker.extend_from_slice(&[0x44; 16]);
                std::fs::write(s.temp.path().join("Sync/primary.pending"), marker).unwrap();
            }
            4 => {
                s.store
                    .transaction(|o| {
                        o.replace(
                            Slot::CheckpointKey,
                            Some(&s.backend.memory.slot(Slot::CheckpointKey).unwrap()),
                            Some(&[0x44; 64]),
                        )
                    })
                    .unwrap();
            }
            _ => (),
        }
        let before = std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap();
        let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
        let (_gate, permit) = authorize(target);
        assert!(handover::cancel(&mut s.store, permit).is_err());
        assert!(handover::inspect(&mut s.store).unwrap().pending);
        assert!(std::fs::read(s.temp.path().join("Sync/journal.bin")).unwrap() == before);
    }
}

#[test]
fn a_published_target_with_old_active_keys_cannot_be_cancelled() {
    let mut s = setup();
    let review = prepare(&mut s).unwrap();
    s.backend.arm(2, false);
    assert!(commit(&mut s, review).is_err());
    s.backend.arm(usize::MAX, false);
    assert_old_slots(&s);
    let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    assert!(matches!(
        handover::cancel(&mut s.store, permit),
        Err(handover::Failure::Unavailable)
    ));
    assert!(handover::inspect(&mut s.store).unwrap().pending);
    resume(&mut s).unwrap();
    assert_complete(&mut s);
}

#[test]
fn lost_cancellation_writes_are_recoverable_without_deleting_retained_candidates() {
    for after in [false, true] {
        let mut s = setup();
        pending_before_publication(&mut s);
        let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
        let (_gate, permit) = authorize(target);
        s.backend.arm(1, after);
        assert!(handover::cancel(&mut s.store, permit).is_err());
        s.backend.arm(usize::MAX, false);
        if handover::inspect(&mut s.store).unwrap().pending {
            let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
            let (_gate, permit) = authorize(target);
            handover::cancel(&mut s.store, permit).unwrap();
        }
        assert!(!handover::inspect(&mut s.store).unwrap().pending);
        assert_old_slots(&s);
        assert_eq!(
            std::fs::read_dir(s.temp.path().join("Sync/Reviews"))
                .unwrap()
                .count(),
            2
        );
    }
}

#[test]
fn cancelled_candidate_can_be_freshly_reviewed_without_reentering_recovery_material() {
    let mut s = setup();
    pending_before_publication(&mut s);
    let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    handover::cancel(&mut s.store, permit).unwrap();
    let mut edited = s.primary.clone();
    edited.push(b'\n');
    std::fs::write(s.temp.path().join("snippets.json"), &edited).unwrap();
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
    let status = handover::inspect(&mut s.store).unwrap();
    assert!(!status.pending);
    assert_eq!(status.retained_libraries, 2);
    let archive = s.store.transaction_with(handover::Archive::load).unwrap();
    assert!(archive.entries[0].cancelled && archive.entries[1].completed);
    assert!(std::fs::read(s.temp.path().join("snippets.json")).unwrap() == edited);
}

#[test]
fn resume_requires_its_own_fresh_target_and_revoked_authorization_cannot_activate_keys() {
    let mut s = setup();
    pending_before_publication(&mut s);
    let target = handover::prepare_cancel_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    assert!(
        s.store
            .transaction_with(|o| handover::resume_authorized_locked(
                o,
                &mut s.remote,
                permit,
                &|_| Ok(())
            ))
            .is_err()
    );
    assert_old_slots(&s);
    let target = handover::prepare_resume_authorization(&mut s.store).unwrap();
    let (mut gate, permit) = authorize(target);
    gate.cancel();
    assert!(
        s.store
            .transaction_with(|o| handover::resume_authorized_locked(
                o,
                &mut s.remote,
                permit,
                &|_| Ok(())
            ))
            .is_err()
    );
    assert_old_slots(&s);
    let target = handover::prepare_resume_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    s.store
        .transaction_with(|o| {
            handover::resume_authorized_locked(o, &mut s.remote, permit, &|_| Ok(()))
        })
        .unwrap();
    assert_complete(&mut s);
}

#[test]
fn schema_one_pending_transition_is_authenticated_and_upgrades_without_losing_capabilities() {
    let mut s = setup();
    pending_before_publication(&mut s);
    s.store
        .transaction(|o| {
            let old = o.read(Slot::AccountReview)?.unwrap();
            let mut value = canonical::parse(&old).unwrap();
            let Value::Object(ref mut fields) = value else {
                unreachable!()
            };
            fields.insert("schema".into(), Value::Int(1));
            let Value::Array(ref mut entries) = *fields.get_mut("entries").unwrap() else {
                unreachable!()
            };
            for entry in entries {
                let Value::Object(entry) = entry else {
                    unreachable!()
                };
                entry.remove("phase");
                entry.remove("vaultHeader");
                entry.insert("completed".into(), Value::Bool(false));
            }
            o.replace(
                Slot::AccountReview,
                Some(&old),
                Some(&value.encode().unwrap()),
            )
        })
        .unwrap();
    assert!(handover::inspect(&mut s.store).unwrap().pending);
    let target = handover::prepare_resume_authorization(&mut s.store).unwrap();
    let (_gate, permit) = authorize(target);
    s.store
        .transaction_with(|o| {
            handover::resume_authorized_locked(o, &mut s.remote, permit, &|_| Ok(()))
        })
        .unwrap();
    assert_complete(&mut s);
    let bytes = s.backend.memory.slot(Slot::AccountReview).unwrap();
    let value = canonical::parse(&bytes).unwrap();
    assert_eq!(value.as_object().unwrap()["schema"].as_int().unwrap(), 4);
}

#[cfg(feature = "desktop")]
#[test]
fn lost_switch_ui_reply_keeps_durable_ownership_and_allows_a_fresh_worker_resume() {
    use crate::account_worker::{Command, Failure as AccountFailure, Handle, Reply};
    for interrupted in [false, true] {
        let mut s = setup();
        let review = prepare(&mut s).unwrap();
        let (_gate, permit) = authorize(review.authorization_target().unwrap());
        let token = Uuid::new_v4();
        let backend = s.backend.clone();
        if interrupted {
            s.backend.arm(2, true);
        }
        let mut review = Some(review);
        let worker = Handle::controlled(move |command| {
            let result = match command {
                Command::CommitHandover {
                    token: received,
                    permit,
                } => {
                    assert!(received == token);
                    s.store
                        .transaction_with(|o| {
                            handover::commit_authorized_locked(
                                o,
                                &mut s.remote,
                                review.take().unwrap(),
                                permit,
                                &|_| Ok(()),
                            )
                        })
                        .map(|_| Reply::Saved)
                        .map_err(AccountFailure::from)
                }
                Command::Inspect => handover::inspect(&mut s.store)
                    .map(|switching| Reply::Profile {
                        account: None,
                        server: None,
                        interrupted: false,
                        switching,
                        device: None,
                    })
                    .map_err(AccountFailure::from),
                Command::PrepareHandoverResume => {
                    handover::prepare_resume_authorization(&mut s.store)
                        .map(Reply::Target)
                        .map_err(AccountFailure::from)
                }
                Command::ResumeHandover(permit) => {
                    s.backend.arm(usize::MAX, false);
                    s.store
                        .transaction_with(|o| {
                            handover::resume_authorized_locked(
                                o,
                                &mut s.remote,
                                permit,
                                &|_| Ok(()),
                            )
                        })
                        .map(|_| Reply::Saved)
                        .map_err(AccountFailure::from)
                }
                _ => Err(AccountFailure::InvalidState),
            };
            (result, false)
        });
        drop(
            worker
                .request(Command::CommitHandover { token, permit })
                .unwrap(),
        );
        let Reply::Profile { switching, .. } = worker
            .request(Command::Inspect)
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .unwrap()
        else {
            panic!("Expected safe saved-state metadata")
        };
        assert!(switching.pending == interrupted);
        assert!(worker.can_quit() && !worker.retention_required());
        if interrupted {
            let Reply::Target(target) = worker
                .request(Command::PrepareHandoverResume)
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(10))
                .unwrap()
                .unwrap()
            else {
                panic!("Expected exact retained authorization target")
            };
            let (_gate, permit) = authorize(target);
            assert!(matches!(
                worker
                    .request(Command::ResumeHandover(permit))
                    .unwrap()
                    .recv_timeout(std::time::Duration::from_secs(10))
                    .unwrap()
                    .unwrap(),
                Reply::Saved
            ));
        }
        let bytes = backend.memory.slot(Slot::LibraryKey).unwrap();
        let installed = Installed::decode(&bytes).unwrap();
        assert_eq!(installed.binding.epoch, 2);
        let Reply::Profile { switching, .. } = worker
            .request(Command::Inspect)
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .unwrap()
        else {
            unreachable!()
        };
        assert!(!switching.pending);
    }
}
