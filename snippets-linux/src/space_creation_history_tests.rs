//! Real creation lifecycle and protected retirement, with fictional accounts,
//! bounded canonical records, temporary files and the fixture auth gate only.
use super::*;
use crate::{
    key_store::{capacity, history},
    local_auth::{self, Gate},
};

fn retained(
    count: usize,
) -> (
    tempfile::TempDir,
    Store<Memory>,
    Memory,
    LiveSession,
    FakeRemote,
    KeyBinding,
) {
    let (temp, mut store, memory, live, mut remote) = fixture();
    let active = seed_existing(&mut store);
    for id in 22..22 + count as u128 {
        advance(&mut remote, id);
        let intent = prepare(&mut store, &live).unwrap();
        begin(&mut store, &mut remote, &live, intent).unwrap();
    }
    (temp, store, memory, live, remote, active)
}
fn review<B: Backend>(store: &mut Store<B>, index: usize) -> capacity::Review {
    let selection = history::inspect(store).unwrap().creations[index]
        .removal
        .clone()
        .unwrap();
    capacity::prepare(store, selection).unwrap()
}
fn authorize(target: local_auth::Target) -> (Gate, local_auth::Permit) {
    let mut gate = Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(
            target,
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )
        .unwrap();
    let proof = local_auth::authenticate_fixture(request).unwrap();
    let permit = gate.accept(proof).unwrap();
    (gate, permit)
}
fn remove<B: Backend>(
    store: &mut Store<B>,
    review: capacity::Review,
    fault: Option<u8>,
) -> key_store::Result<()> {
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    capacity::apply_with_fault(store, review, permit, fault)
}
fn generation(memory: &Memory) -> i64 {
    serde_json::from_slice::<serde_json::Value>(&memory.slot(Slot::SpaceCreation).unwrap()).unwrap()
        ["generation"]
        .as_i64()
        .unwrap()
}
fn kept(memory: &Memory) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::CheckpointKey,
        Slot::Credentials,
        Slot::PairingRecipient,
        Slot::KeyMutation,
        Slot::BootstrapCandidate,
        Slot::PairingCandidate,
    ]
    .into_iter()
    .map(|slot| memory.slot(slot))
    .collect()
}

#[test]
fn full_creation_history_retirement_preserves_every_other_receipt_and_current_library() {
    let (temp, mut store, memory, live, mut remote, active) = retained(MAX_ENTRIES);
    let before = entries(&memory);
    let old_generation = generation(&memory);
    let current = kept(&memory);
    assert_eq!(
        prepare(&mut store, &live).err(),
        Some(Failure::RetentionFull)
    );
    let library = crate::model::Library::prepare(temp.path().into()).unwrap();
    std::fs::write(library.root.join("snippets.json"), b"[]\n").unwrap();
    std::fs::create_dir_all(library.root.join("Vault")).unwrap();
    std::fs::write(
        library.root.join("Vault/vault.json"),
        b"Public untouched vault fixture",
    )
    .unwrap();
    let proposal = review(&mut store, 3);
    let summary = proposal.summary();
    assert_eq!(summary.section, capacity::Section::Creations);
    assert_eq!(summary.entry, 4);
    assert_eq!(summary.encrypted_images, 0);
    assert_eq!(summary.libraries.len(), 1);
    assert_eq!(summary.libraries[0].id(), Uuid::from_u128(25));
    remove(&mut store, proposal, None).unwrap();
    let mut expected = before;
    expected.remove(3);
    assert_eq!(entries(&memory), expected);
    assert_eq!(generation(&memory), old_generation + 1);
    assert!(kept(&memory) == current);
    assert_eq!(
        std::fs::read(library.root.join("snippets.json")).unwrap(),
        b"[]\n"
    );
    assert_eq!(
        std::fs::read(library.root.join("Vault/vault.json")).unwrap(),
        b"Public untouched vault fixture"
    );
    assert!(!library.root.join("Sync/Reviews").exists());
    assert!(memory.slot(Slot::HistoryMaintenance).is_none());
    key_store::check_admission(&mut store, &active).unwrap();
    assert_eq!(remote.requests.len(), MAX_ENTRIES);
    advance(&mut remote, 123);
    let intent = prepare(&mut store, &live).unwrap();
    begin(&mut store, &mut remote, &live, intent).unwrap();
    assert_eq!(entries(&memory).len(), MAX_ENTRIES);
    assert_eq!(remote.requests.len(), MAX_ENTRIES + 1);
    assert_eq!(generation(&memory), old_generation + 3);
}

#[test]
fn last_schema_two_receipt_becomes_monotonic_empty_history_and_can_append_again() {
    let (temp, mut store, memory, live, mut remote, active) = retained(1);
    let old = memory.slot(Slot::SpaceCreation).unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&old).unwrap();
    value["schema"] = serde_json::json!(2);
    let legacy = serde_json::to_vec(&value).unwrap();
    store
        .transaction(|owner| owner.replace(Slot::SpaceCreation, Some(&old), Some(&legacy)))
        .unwrap();
    let old_generation = generation(&memory);
    let proposal = review(&mut store, 0);
    remove(&mut store, proposal, None).unwrap();
    assert!(entries(&memory).is_empty());
    let bytes = memory.slot(Slot::SpaceCreation).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["schema"],
        3
    );
    assert_eq!(generation(&memory), old_generation + 1);
    let mut restarted = Store::load(temp.path(), memory.clone()).unwrap();
    key_store::check_admission(&mut restarted, &active).unwrap();
    assert_eq!(status(&mut restarted, &live), Ok(State::Available));
    advance(&mut remote, 124);
    let intent = prepare(&mut restarted, &live).unwrap();
    begin(&mut restarted, &mut remote, &live, intent).unwrap();
    assert_eq!(generation(&memory), old_generation + 3);
    assert_eq!(entries(&memory).len(), 1);
    assert_eq!(remote.requests.len(), 2);
    assert!(retirement_terminal(Some(bytes)).unwrap());
}

#[test]
fn durable_creation_removal_reopens_with_exact_original_consent_at_each_boundary() {
    for step in [1, 2] {
        let (temp, mut store, memory, live, remote, active) = retained(2);
        let before = entries(&memory);
        let old_generation = generation(&memory);
        let current = kept(&memory);
        let proposal = review(&mut store, 0);
        let initial_target = proposal.authorization_target().unwrap();
        assert!(remove(&mut store, proposal, Some(step)).is_err());
        assert!(memory.slot(Slot::HistoryMaintenance).is_some());
        assert!(matches!(
            status(&mut store, &live),
            Err(Failure::Secret(
                secret_store::Failure::HistoryMaintenanceRequired
            ))
        ));
        let mut reopened = Store::load(temp.path(), memory.clone()).unwrap();
        let pending = history::inspect(&mut reopened)
            .unwrap()
            .maintenance
            .unwrap();
        assert_eq!(pending.section, capacity::Section::Creations);
        let proposal = capacity::prepare_resume(&mut reopened).unwrap();
        assert!(proposal.authorization_target().unwrap() != initial_target);
        remove(&mut reopened, proposal, None).unwrap();
        assert_eq!(entries(&memory), before[1..]);
        assert_eq!(generation(&memory), old_generation + 1);
        assert!(kept(&memory) == current);
        key_store::check_admission(&mut reopened, &active).unwrap();
        assert!(memory.slot(Slot::HistoryMaintenance).is_none());
        assert_eq!(remote.requests.len(), 2);
    }
}

#[derive(Clone)]
struct Ambiguous {
    memory: Memory,
    fault: Arc<Mutex<Option<(usize, bool)>>>,
}
impl Ambiguous {
    fn fail(&self) -> Option<bool> {
        let mut fault = self.fault.lock().unwrap();
        let (remaining, after) = fault.as_mut()?;
        *remaining -= 1;
        if *remaining == 0 {
            let after = *after;
            *fault = None;
            Some(after)
        } else {
            None
        }
    }
}
impl Backend for Ambiguous {
    fn read(
        &mut self,
        ns: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        self.memory.read(ns, slot)
    }
    fn write(&mut self, ns: &[u8; 16], slot: Slot, bytes: &[u8]) -> secret_store::Result<()> {
        let fail = self.fail();
        if fail != Some(false) {
            self.memory.write(ns, slot, bytes)?;
        }
        if fail.is_some() {
            Err(secret_store::Failure::Unavailable)
        } else {
            Ok(())
        }
    }
    fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
        let fail = self.fail();
        if fail != Some(false) {
            self.memory.delete(ns, slot)?;
        }
        if fail.is_some() {
            Err(secret_store::Failure::Unavailable)
        } else {
            Ok(())
        }
    }
}
#[test]
fn ambiguous_creation_retirement_writes_and_final_delete_reconcile_from_protected_state() {
    for write in 1..=3 {
        for after in [false, true] {
            let (temp, _store, memory, _live, remote, active) = retained(2);
            let old_generation = generation(&memory);
            let before = entries(&memory);
            let current = kept(&memory);
            let backend = Ambiguous {
                memory: memory.clone(),
                fault: Arc::new(Mutex::new(None)),
            };
            let mut store = Store::load(temp.path(), backend.clone()).unwrap();
            let proposal = review(&mut store, 0);
            *backend.fault.lock().unwrap() = Some((write, after));
            assert!(remove(&mut store, proposal, None).is_err());
            let mut reopened = Store::load(temp.path(), backend).unwrap();
            if memory.slot(Slot::HistoryMaintenance).is_some() {
                let proposal = capacity::prepare_resume(&mut reopened).unwrap();
                remove(&mut reopened, proposal, None).unwrap();
            } else if entries(&memory) == before {
                let proposal = review(&mut reopened, 0);
                remove(&mut reopened, proposal, None).unwrap();
            }
            assert_eq!(entries(&memory), before[1..]);
            assert_eq!(generation(&memory), old_generation + 1);
            assert!(kept(&memory) == current);
            key_store::check_admission(&mut reopened, &active).unwrap();
            assert!(memory.slot(Slot::HistoryMaintenance).is_none());
            assert_eq!(remote.requests.len(), 2);
        }
    }
}

fn pending_pairing<B: Backend>(store: &mut Store<B>, binding: &KeyBinding) {
    let draft = crate::bootstrap::PairingDraft::generate().unwrap();
    let bytes = object([
        ("schema", Value::Int(2)),
        ("generation", Value::Int(1)),
        (
            "entries",
            Value::Array(vec![object([
                ("binding", binding.value()),
                ("account", Value::Null),
                (
                    "phase",
                    object([
                        ("kind", Value::text("creating")),
                        (
                            "secret",
                            canonical::parse(&draft.encode_secret().unwrap()).unwrap(),
                        ),
                        ("ciphertext", Value::Null),
                        ("sent", Value::Bool(true)),
                    ]),
                ),
                ("ready", Value::Bool(false)),
                ("cancelled", Value::Bool(false)),
            ])]),
        ),
    ])
    .encode()
    .unwrap();
    store
        .transaction(|owner| owner.replace(Slot::PairingCandidate, None, Some(&bytes)))
        .unwrap();
}
#[test]
fn creation_removal_refuses_changed_generation_account_active_target_and_new_pending_pairing() {
    for change in 0..4 {
        let (_temp, mut store, memory, _live, _remote, _active) = retained(2);
        let proposal = review(&mut store, 0);
        let target = descriptor_at(22, 33, 44, 5, 1, "owner")
            .key_binding(&deployment())
            .unwrap();
        match change {
            0 => {
                let old = memory.slot(Slot::SpaceCreation).unwrap();
                let mut value: serde_json::Value = serde_json::from_slice(&old).unwrap();
                value["generation"] = serde_json::json!(generation(&memory) + 1);
                store
                    .transaction(|owner| {
                        owner.replace(
                            Slot::SpaceCreation,
                            Some(&old),
                            Some(&serde_json::to_vec(&value).unwrap()),
                        )
                    })
                    .unwrap();
            }
            1 => {
                install(
                    &mut store,
                    deployment(),
                    "public-other",
                    "public-other-account",
                );
            }
            2 => {
                let old = memory.slot(Slot::LibraryKey).unwrap();
                let mut value: serde_json::Value = serde_json::from_slice(&old).unwrap();
                value["binding"] =
                    serde_json::from_slice(&target.value().encode().unwrap()).unwrap();
                store
                    .transaction(|owner| {
                        owner.replace(
                            Slot::LibraryKey,
                            Some(&old),
                            Some(&serde_json::to_vec(&value).unwrap()),
                        )
                    })
                    .unwrap();
            }
            3 => pending_pairing(&mut store, &target),
            _ => unreachable!(),
        }
        let before = memory.slot(Slot::SpaceCreation);
        let current = kept(&memory);
        assert!(remove(&mut store, proposal, None).is_err());
        assert!(memory.slot(Slot::SpaceCreation) == before);
        assert!(kept(&memory) == current);
        assert!(memory.slot(Slot::HistoryMaintenance).is_none());
        if change == 2 || change == 3 {
            assert!(
                history::inspect(&mut store).unwrap().creations[0]
                    .removal
                    .is_none()
            );
        }
    }
}

#[test]
fn uncertain_creation_and_the_only_current_admission_receipt_are_never_retired() {
    let (_temp, mut store, memory, live, mut remote, active) = retained(1);
    advance(&mut remote, 125);
    remote.lose_reply = true;
    let intent = prepare(&mut store, &live).unwrap();
    assert!(begin(&mut store, &mut remote, &live, intent).is_err());
    let catalog = history::inspect(&mut store).unwrap();
    assert_eq!(
        catalog.creations[1].phase,
        history::CreationPhase::Requested
    );
    assert!(catalog.creations[1].library.is_none());
    assert!(catalog.creations[1].removal.is_none());
    let before = memory.slot(Slot::SpaceCreation).unwrap();
    let selected = capacity::Selection::new(capacity::Section::Creations, 1, &before);
    assert!(capacity::prepare(&mut store, selected).is_err());
    assert!(memory.slot(Slot::SpaceCreation).unwrap() == before);
    // The first completed receipt is the only source-admission witness for the
    // current account; the remaining uncertain receipt belongs to another one.
    let mut value: serde_json::Value = serde_json::from_slice(&before).unwrap();
    value["entries"][1]["account"]["identity"] = serde_json::json!("public-other-account");
    let changed = serde_json::to_vec(&value).unwrap();
    store
        .transaction(|owner| owner.replace(Slot::SpaceCreation, Some(&before), Some(&changed)))
        .unwrap();
    key_store::check_admission(&mut store, &active).unwrap();
    // Inspection does not read account credentials; the offered review must
    // still refuse the exact hypothetical remainder at its owning boundary.
    assert!(
        history::inspect(&mut store).unwrap().creations[0]
            .removal
            .is_some()
    );
    let selected = capacity::Selection::new(capacity::Section::Creations, 0, &changed);
    assert!(capacity::prepare(&mut store, selected).is_err());
    assert_eq!(remote.requests.len(), 2);
    assert!(memory.slot(Slot::HistoryMaintenance).is_none());
}

struct ReadOnly(Memory);
impl Backend for ReadOnly {
    fn read(
        &mut self,
        ns: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        assert!(
            slot != Slot::Credentials,
            "catalogue must not read credentials"
        );
        self.0.read(ns, slot)
    }
    fn write(&mut self, _: &[u8; 16], _: Slot, _: &[u8]) -> secret_store::Result<()> {
        panic!("catalogue must not write a protected slot")
    }
    fn delete(&mut self, _: &[u8; 16], _: Slot) -> secret_store::Result<()> {
        panic!("catalogue must not delete a protected slot")
    }
}
#[test]
fn creation_catalogue_is_credential_free_and_marks_unknown_history_as_retained() {
    let (temp, mut store, memory, live, _remote, _active) = retained(1);
    let before = memory.slot(Slot::SpaceCreation).unwrap();
    let current = kept(&memory);
    let mut read_only = Store::load(temp.path(), ReadOnly(memory.clone())).unwrap();
    let catalog = history::inspect(&mut read_only).unwrap();
    assert_eq!(catalog.creations.len(), 1);
    assert!(!catalog.creations_unavailable);
    assert!(catalog.creations[0].removal.is_some());
    assert!(kept(&memory) == current);
    assert!(memory.slot(Slot::SpaceCreation).unwrap() == before);
    let unknown = b"Public unknown retained creation capability";
    store
        .transaction(|owner| owner.replace(Slot::SpaceCreation, Some(&before), Some(unknown)))
        .unwrap();
    let catalog = history::inspect(&mut read_only).unwrap();
    assert!(catalog.creations_unavailable);
    assert!(catalog.creations.is_empty());
    assert_eq!(catalog.usage.creations, unknown.len());
    assert_eq!(
        memory.slot(Slot::SpaceCreation).unwrap().as_slice(),
        unknown
    );
    assert!(prepare(&mut store, &live).is_err());
}
