//! First-key protocol and recovery use fictional peers and temporary roots only.
use super::*;
use crate::{
    key_store::tests::{FakeRemote, Memory},
    local_auth::{self, Gate},
};
use std::sync::{Arc, Mutex};
#[derive(Clone)]
struct Faults {
    memory: Memory,
    state: Arc<Mutex<FaultState>>,
}
#[derive(Default)]
struct FaultState {
    slot: Option<Slot>,
    calls: usize,
    fail: Option<(usize, bool)>,
}
impl Faults {
    fn arm(&self, slot: Slot, n: usize, after: bool) {
        *self.state.lock().unwrap() = FaultState {
            slot: Some(slot),
            calls: 0,
            fail: Some((n, after)),
        };
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
    fn write(&mut self, ns: &[u8; 16], slot: Slot, bytes: &[u8]) -> secret_store::Result<()> {
        let fault = {
            let mut state = self.state.lock().unwrap();
            if state.slot == Some(slot) {
                state.calls += 1;
                state
                    .fail
                    .filter(|(n, _)| *n == state.calls)
                    .map(|(_, after)| after)
            } else {
                None
            }
        };
        if fault != Some(false) {
            self.memory.write(ns, slot, bytes)?;
        }
        if fault.is_some() {
            return Err(secret_store::Failure::Unavailable);
        }
        Ok(())
    }
    fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
        self.memory.delete(ns, slot)
    }
}
struct Peer {
    core: FakeRemote,
    memory: Memory,
    role: Role,
    records: bool,
    posts: usize,
    lose_post: bool,
    race_key: bool,
    race_records: bool,
    change_post: bool,
    payloads: Vec<Vec<u8>>,
}
impl Remote for Peer {
    fn preflight(&mut self) -> Result<()> {
        self.core.preflight()
    }
    fn binding(&self) -> Result<KeyBinding> {
        self.core.binding()
    }
    fn role(&self) -> Role {
        self.role
    }
    fn authority(&mut self) -> Result<Option<[u8; 32]>> {
        self.core.authority()
    }
    fn recovery(&mut self) -> Result<Option<Evidence>> {
        self.core.recovery()
    }
    fn has_records(&mut self) -> Result<bool> {
        Ok(self.records)
    }
    fn bootstrap(&mut self, public: &[u8; 32], ciphertext: &[u8]) -> Result<Evidence> {
        assert!(self.memory.slot(Slot::LibraryKey).is_some());
        let bytes = self.memory.slot(Slot::BootstrapCandidate).unwrap();
        let value = canonical::parse(&bytes).unwrap();
        let entries = value.as_object().unwrap()["entries"].as_array().unwrap();
        let entry = Entry::parse(entries.last().unwrap()).unwrap();
        assert!(entry.phase == Status::Sent);
        assert!(
            Authority::new(
                &entry.installed.bundle,
                &entry.installed.binding.context().unwrap()
            )
            .public_key()
                == *public
        );
        assert!(entry.presentation.retained().unwrap().1 == ciphertext);
        self.posts += 1;
        self.payloads.push(ciphertext.into());
        if self.race_key {
            self.core.public = Some([88; 32]);
            return Err(Failure::KeyConflict);
        }
        if self.race_records {
            self.records = true;
            return Err(Failure::KeyConflict);
        }
        self.core.public = Some(*public);
        self.core.recovery = Some(Evidence {
            version: 1,
            ciphertext: ciphertext.into(),
        });
        if self.change_post {
            self.core.pin.dataset = Binding::from_checkpoint([99; 32]);
        }
        if self.lose_post {
            self.lose_post = false;
            return Err(Failure::Cloud(cloud::Failure::Network));
        }
        Ok(Evidence {
            version: 1,
            ciphertext: ciphertext.into(),
        })
    }
}
impl crate::receiver::Remote for Peer {
    fn preflight(&mut self) -> crate::receiver::RemoteResult<crate::receiver::Observation> {
        Ok(crate::receiver::Observation {
            scope: self.core.pin.checkpoint_scope(),
            feed: crate::inbound::Feed::new(Uuid::from_u128(9), self.core.pin.epoch).unwrap(),
        })
    }
    fn fetch(
        &mut self,
        _: Option<&cloud::Cursor>,
    ) -> crate::receiver::RemoteResult<crate::receiver::FetchedPage> {
        panic!("initial key setup and handover must not fetch records")
    }
}
fn setup() -> (tempfile::TempDir, Store<Faults>, Faults, Peer) {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let backend = Faults {
        memory: memory.clone(),
        state: Arc::new(Mutex::new(FaultState::default())),
    };
    let mut store = Store::initialize(temp.path(), backend.clone()).unwrap();
    let mut core = FakeRemote::new(memory.clone());
    store
        .transaction_with(|owner| initialize_locked(owner, &mut core))
        .unwrap();
    core.pin.space = Uuid::from_u128(44);
    core.pin.dataset = Binding::from_checkpoint([44; 32]);
    core.public = None;
    core.recovery = None;
    let peer = Peer {
        core,
        memory,
        role: Role::Owner,
        records: false,
        posts: 0,
        lose_post: false,
        race_key: false,
        race_records: false,
        change_post: false,
        payloads: Vec::new(),
    };
    (temp, store, backend, peer)
}

#[test]
fn unfinished_first_key_keeps_its_creation_receipt_until_the_response_is_retained() {
    use crate::{
        auth_store::{Deployment, creation},
        key_store::{capacity, history},
    };
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let (_temp, mut store, backend, mut peer) = setup();
    let deployment =
        Deployment::from_discovery(peer.core.pin.server.clone(), peer.core.pin.instance);
    let live = creation::tests::install(
        &mut store,
        deployment.clone(),
        "public-key-setup",
        "public-creator",
    );
    let space: crate::cloud::Space = serde_json::from_value(serde_json::json!({
        "scope": {"serverInstanceId":peer.core.pin.instance, "spaceId":Uuid::from_u128(1234),
        "scopeBinding":URL_SAFE_NO_PAD.encode([45;32]), "datasetGeneration":Uuid::from_u128(1235), "feedEpoch":Uuid::from_u128(1236)},
        "role":"owner", "keyEpoch":1
    })).unwrap();
    creation::tests::created_beside(&mut store, deployment.clone(), space.clone(), &live);
    peer.core.pin = space.key_binding(&deployment).unwrap();
    peer.lose_post = true;
    let receipt = backend.memory.slot(Slot::SpaceCreation).unwrap();
    assert!(matches!(
        create(&mut store, &mut peer),
        Err(Failure::Cloud(cloud::Failure::Network))
    ));
    assert!(
        history::inspect(&mut store).unwrap().creations[0]
            .removal
            .is_none()
    );
    let selection = capacity::Selection::new(capacity::Section::Creations, 0, &receipt);
    assert!(capacity::prepare(&mut store, selection).is_err());
    assert!(backend.memory.slot(Slot::SpaceCreation).unwrap() == receipt);
    assert_eq!(peer.posts, 1);
    assert!(matches!(
        create(&mut store, &mut peer).unwrap(),
        Status::Ready { .. }
    ));
    let candidate = backend.memory.slot(Slot::BootstrapCandidate);
    let catalog = history::inspect(&mut store).unwrap();
    let review =
        capacity::prepare(&mut store, catalog.creations[0].removal.clone().unwrap()).unwrap();
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    capacity::apply(&mut store, review, permit).unwrap();
    assert!(backend.memory.slot(Slot::BootstrapCandidate) == candidate);
    assert!(history::inspect(&mut store).unwrap().creations.is_empty());
    assert_eq!(peer.posts, 1);
}

#[test]
fn history_capacity_frees_a_full_candidate_archive_without_resetting_generation() {
    use crate::key_store::{capacity, history};
    let (_temp, mut store, backend, mut peer) = setup();
    let active = backend.memory.slot(Slot::LibraryKey);
    for index in 0..MAX_ENTRIES {
        peer.core.pin.space = Uuid::from_u128(400 + index as u128);
        peer.core.pin.dataset = Binding::from_checkpoint([40 + index as u8; 32]);
        peer.core.public = None;
        peer.core.recovery = None;
        assert!(matches!(
            create(&mut store, &mut peer).unwrap(),
            Status::Ready { .. }
        ));
    }
    let before = History::load_for_test(&mut store);
    let selection = history::inspect(&mut store).unwrap().first_keys[3]
        .removal
        .clone()
        .unwrap();
    let review = capacity::prepare(&mut store, selection).unwrap();
    assert_eq!(review.summary().encrypted_images, 0);
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    capacity::apply(&mut store, review, permit).unwrap();
    let saved = store.transaction_with(History::load).unwrap();
    assert_eq!(saved.entries.len(), 7);
    assert_eq!(saved.generation, before.0 + 1);
    for (entry, old) in saved.entries.iter().zip(
        before
            .1
            .iter()
            .enumerate()
            .filter(|(index, _)| *index != 3)
            .map(|(_, v)| v),
    ) {
        assert!(entry.value().unwrap() == *old);
    }
    assert!(backend.memory.slot(Slot::LibraryKey) == active);
    peer.core.pin.space = Uuid::from_u128(500);
    peer.core.public = None;
    peer.core.recovery = None;
    create(&mut store, &mut peer).unwrap();
    assert_eq!(history::inspect(&mut store).unwrap().first_keys.len(), 8);
}
impl History {
    fn load_for_test(store: &mut Store<Faults>) -> (i64, Vec<Value>) {
        store
            .transaction_with(|owner| {
                let saved = Self::load(owner)?;
                Ok::<_, Failure>((
                    saved.generation,
                    saved
                        .entries
                        .iter()
                        .map(Entry::value)
                        .collect::<super::Result<_>>()?,
                ))
            })
            .unwrap()
    }
}
fn create(store: &mut Store<Faults>, peer: &mut Peer) -> Result<Status> {
    store.transaction_with(|owner| create_locked(owner, peer, &|_| Ok(())))
}
#[test]
fn created_library_beside_old_keys_requires_fresh_keys_and_reviewed_handover() {
    use crate::auth_store::{Deployment, creation::tests};
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let (temp, mut store, backend, mut peer) = setup();
    let old_key = backend.memory.slot(Slot::LibraryKey).unwrap();
    let old_presentation = backend.memory.slot(Slot::Bootstrap).unwrap();
    let old_pin = Installed::decode(&old_key).unwrap().binding;
    let deployment = Deployment::from_discovery(old_pin.server.clone(), old_pin.instance);
    let live = tests::install(
        &mut store,
        deployment.clone(),
        "creation-switch",
        "public-creator",
    );
    let library = crate::model::Library::open(temp.path().into()).unwrap();
    let record = crate::snapshot_review::tests::envelope(1, "Public creation local intent", 4);
    crate::snapshot_review::tests::write_primary(&library, std::slice::from_ref(&record));
    let primary = std::fs::read(library.path()).unwrap();
    let material = store
        .transaction(|owner| owner.checkpoint_material(true))
        .unwrap()
        .unwrap();
    let key = crate::crypto::RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let mut checkpoint =
        crate::journal::Checkpoint::load(&library, &key, &salt, old_pin.checkpoint_scope())
            .unwrap();
    checkpoint.journal.key_epoch = Some(old_pin.epoch);
    checkpoint
        .journal
        .projected
        .insert(record.id, record.clone());
    checkpoint.save(&library, &key, &salt).unwrap();
    let journal = std::fs::read(temp.path().join("Sync/journal.bin")).unwrap();
    let space: crate::cloud::Space = serde_json::from_value(serde_json::json!({
        "scope":{"serverInstanceId":old_pin.instance,"spaceId":Uuid::from_u128(44),
        "scopeBinding":URL_SAFE_NO_PAD.encode([88;32]),"datasetGeneration":Uuid::from_u128(77),
        "feedEpoch":Uuid::from_u128(78)},"role":"owner","keyEpoch":1
    }))
    .unwrap();
    tests::created_beside(&mut store, deployment.clone(), space.clone(), &live);
    peer.core.pin = space.key_binding(&deployment).unwrap();
    assert!(backend.memory.slot(Slot::Bootstrap).as_deref() == Some(&old_presentation));
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old_key));
    assert_eq!(std::fs::read(library.path()).unwrap(), primary);
    assert_eq!(
        std::fs::read(temp.path().join("Sync/journal.bin")).unwrap(),
        journal
    );
    crate::key_store::check_admission(&mut store, &old_pin).unwrap();
    assert!(
        crate::key_store::check_admission(&mut store, &peer.core.pin)
            == Err(Failure::ReviewRequired)
    );
    create(&mut store, &mut peer).unwrap();
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old_key));
    assert_eq!(
        std::fs::read(temp.path().join("Sync/journal.bin")).unwrap(),
        journal
    );
    activate(&mut store, &mut peer);
    assert!(
        Installed::decode(&backend.memory.slot(Slot::LibraryKey).unwrap())
            .unwrap()
            .binding
            == peer.core.pin
    );
    assert!(backend.memory.slot(Slot::SpaceCreation).is_none());
    assert!(backend.memory.slot(Slot::AccountReview).is_some());
    assert_eq!(std::fs::read(library.path()).unwrap(), primary);
    assert_eq!(peer.posts, 1);
}
#[test]
fn catalogue_keeps_first_key_phases_visible_without_replaying_or_installing_them() {
    use crate::key_store::history;
    for kind in 0..4 {
        let (temp, mut store, backend, mut peer) = setup();
        let old = backend.memory.slot(Slot::LibraryKey);
        let expected = match kind {
            0 => {
                create(&mut store, &mut peer).unwrap();
                Status::Ready {
                    kit: KitStatus::AwaitingPresentation,
                }
            }
            1 => {
                peer.change_post = true;
                assert!(create(&mut store, &mut peer).is_err());
                Status::Sent
            }
            2 => {
                peer.race_key = true;
                assert!(create(&mut store, &mut peer).is_err());
                assert!(create(&mut store, &mut peer) == Ok(Status::Lost));
                Status::Lost
            }
            3 => {
                backend.arm(Slot::BootstrapCandidate, 2, false);
                assert!(create(&mut store, &mut peer).is_err());
                Status::Prepared
            }
            _ => unreachable!(),
        };
        let frame = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
        let calls = peer.core.calls;
        let posts = peer.posts;
        let catalog = history::inspect(&mut store).unwrap();
        assert_eq!(catalog.first_keys.len(), 1);
        assert_eq!(catalog.first_keys[0].phase, expected);
        assert!(!catalog.first_keys[0].key.active);
        assert_eq!(catalog.usage.first_keys, frame.len());
        assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&frame));
        assert!(backend.memory.slot(Slot::LibraryKey) == old);
        assert!(!temp.path().join("Sync").exists());
        assert_eq!(peer.core.calls, calls);
        assert_eq!(peer.posts, posts);
    }
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
fn activate(store: &mut Store<Faults>, peer: &mut Peer) {
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, peer, None, &|_| Ok(())))
        .unwrap();
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    let outcome = store
        .transaction_with(|owner| {
            handover::commit_authorized_locked(owner, peer, review, permit, &|_| Ok(()))
        })
        .unwrap();
    assert!(
        outcome
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
}
fn reviewed_activation(store: &mut Store<Faults>, peer: &mut Peer) -> Outcome {
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, peer, None, &|_| Ok(())))
        .unwrap();
    assert!(review.reuses_local_key());
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    store
        .transaction_with(|owner| {
            handover::commit_authorized_locked(owner, peer, review, permit, &|_| Ok(()))
        })
        .unwrap()
}
#[test]
fn changed_dataset_and_membership_keep_first_key_caps_until_review_and_retire_exact_promoted_code()
{
    let (temp, mut store, backend, mut peer) = setup();
    let library = crate::model::Library::open(temp.path().into()).unwrap();
    let record = crate::snapshot_review::tests::envelope(1, "Public retained first-key intent", 4);
    crate::snapshot_review::tests::write_primary(&library, std::slice::from_ref(&record));
    let primary = std::fs::read(library.path()).unwrap();
    let old_key = backend.memory.slot(Slot::LibraryKey).unwrap();
    create(&mut store, &mut peer).unwrap();
    let original = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    peer.core.pin.dataset = Binding::from_checkpoint([61; 32]);
    peer.core.pin.membership = Binding::from_checkpoint([62; 32]);
    assert!(inspect(&mut store, &peer.core.pin) == Ok(None));
    assert!(create(&mut store, &mut peer).is_err());
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())))
        .unwrap();
    assert!(review.reuses_local_key() && review.summary().local_records == 1);
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old_key));
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&original));
    assert!(!temp.path().join("Sync/Reviews").exists());
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    assert!(
        store
            .transaction_with(|owner| handover::commit_authorized_locked(
                owner,
                &mut peer,
                review,
                permit,
                &|_| Ok(())
            ))
            .unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
    let active = Installed::decode(&backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
    assert!(active.binding == peer.core.pin);
    let (_gate, value) = shown(&mut store, &mut peer);
    let entered = suffix(&value);
    store
        .transaction_with(|owner| {
            disclosure::confirm_saved_locked(owner, &mut peer, value, entered)
        })
        .unwrap();
    metadata_only(&backend);
    assert!(std::fs::read(library.path()).unwrap() == primary);
    assert_eq!(peer.posts, 1);
}
#[test]
fn sent_first_key_after_scope_halt_can_be_freshly_reviewed_without_another_post() {
    let (_temp, mut store, backend, mut peer) = setup();
    peer.change_post = true;
    assert!(create(&mut store, &mut peer).is_err());
    let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    assert!(inspect(&mut store, &peer.core.pin) == Ok(None));
    assert!(
        reviewed_activation(&mut store, &mut peer)
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
    let current = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let before = canonical::parse(&before).unwrap();
    let current = canonical::parse(&current).unwrap();
    let before = before.as_object().unwrap()["entries"].as_array().unwrap()[0]
        .as_object()
        .unwrap();
    let current = current.as_object().unwrap()["entries"].as_array().unwrap()[0]
        .as_object()
        .unwrap();
    assert!(
        before["phase"].as_text().unwrap() == "sent"
            && current["phase"].as_text().unwrap() == "ready"
    );
    for field in ["installed", "account", "presentation"] {
        assert!(before[field].encode().unwrap() == current[field].encode().unwrap());
    }
    assert_eq!(peer.posts, 1);
    let (_gate, value) = shown(&mut store, &mut peer);
    let entered = suffix(&value);
    store
        .transaction_with(|owner| {
            disclosure::confirm_saved_locked(owner, &mut peer, value, entered)
        })
        .unwrap();
    metadata_only(&backend);
}
#[test]
fn changed_epoch_reuses_verified_key_without_promoting_an_old_epoch_recovery_code() {
    let (_temp, mut store, backend, mut peer) = setup();
    create(&mut store, &mut peer).unwrap();
    let original = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let (_, presentation) = store
        .transaction_with(|owner| retained_target(owner, &peer.core.pin))
        .unwrap()
        .unwrap();
    let old_kit = RecoveryKit::decode_secret_qr(
        &presentation
            .retained()
            .unwrap()
            .0
            .encode_secret_qr()
            .unwrap(),
    )
    .unwrap();
    peer.core.pin.epoch += 1;
    peer.core.pin.dataset = Binding::from_checkpoint([63; 32]);
    assert!(
        reviewed_activation(&mut store, &mut peer)
            == Outcome::Ready {
                kit: KitStatus::None
            }
    );
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&original));
    let active =
        super::super::Archive::from_snapshot(backend.memory.slot(Slot::Bootstrap)).unwrap();
    assert!(active.presentation.is_none());
    assert!(
        store
            .transaction_with(|owner| disclosure::prepare_locked(owner, &mut peer))
            .is_err()
    );
    assert!(
        store
            .transaction_with(|owner| recover_locked(owner, &mut peer, old_kit))
            .is_err()
    );
    assert_eq!(peer.posts, 1);
}
#[test]
fn another_account_must_review_the_owned_first_key_instead_of_resuming_original_consent() {
    use crate::auth_store::{Deployment, creation::tests::install};
    let (_temp, mut store, backend, mut peer) = setup();
    let deployment =
        Deployment::from_discovery(peer.core.pin.server.clone(), peer.core.pin.instance);
    let _first = install(
        &mut store,
        deployment.clone(),
        "review-first",
        "public-old-review-account",
    );
    create(&mut store, &mut peer).unwrap();
    let original = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let old_key = backend.memory.slot(Slot::LibraryKey).unwrap();
    let _next = install(
        &mut store,
        deployment,
        "review-next",
        "public-new-review-account",
    );
    peer.core.pin.membership = Binding::from_checkpoint([64; 32]);
    assert!(inspect(&mut store, &peer.core.pin) == Ok(None));
    assert!(create(&mut store, &mut peer).is_err());
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())))
        .unwrap();
    assert!(review.reuses_local_key());
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old_key));
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&original));
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    store
        .transaction_with(|owner| {
            handover::commit_authorized_locked(owner, &mut peer, review, permit, &|_| Ok(()))
        })
        .unwrap();
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&original));
    assert!(!handover::inspect(&mut store).unwrap().pending);
    assert_eq!(peer.posts, 1);
}
#[test]
fn changed_first_key_history_invalidates_a_prepared_review_before_journal_publication() {
    let (temp, mut store, backend, mut peer) = setup();
    create(&mut store, &mut peer).unwrap();
    peer.core.pin.dataset = Binding::from_checkpoint([65; 32]);
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())))
        .unwrap();
    let original = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let mut value = canonical::parse(&original).unwrap();
    let Value::Object(fields) = &mut value else {
        unreachable!()
    };
    fields.insert(
        "generation".into(),
        Value::Int(fields["generation"].as_int().unwrap() + 1),
    );
    let changed = value.encode().unwrap();
    store
        .transaction(|owner| {
            owner.replace(Slot::BootstrapCandidate, Some(&original), Some(&changed))
        })
        .unwrap();
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    assert!(
        store
            .transaction_with(|owner| handover::commit_authorized_locked(
                owner,
                &mut peer,
                review,
                permit,
                &|_| Ok(())
            ))
            .is_err()
    );
    assert!(backend.memory.slot(Slot::AccountReview).is_none());
    assert!(!temp.path().join("Sync/Reviews").exists());
    assert!(
        reviewed_activation(&mut store, &mut peer)
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
}
#[test]
fn different_server_instance_library_or_authority_cannot_borrow_a_first_key_candidate() {
    for kind in 0..4 {
        let (temp, mut store, backend, mut peer) = setup();
        create(&mut store, &mut peer).unwrap();
        let original = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
        let (bundle, _) = store
            .transaction_with(|owner| retained_target(owner, &peer.core.pin))
            .unwrap()
            .unwrap();
        match kind {
            0 => peer.core.pin.server = ServerURL::parse("https://other-review.example").unwrap(),
            1 => peer.core.pin.instance = Uuid::from_u128(81),
            2 => peer.core.pin.space = Uuid::from_u128(82),
            _ => (),
        }
        peer.core.public = Some(if kind == 3 {
            [88; 32]
        } else {
            Authority::new(&bundle, &peer.core.pin.context().unwrap()).public_key()
        });
        assert!(
            store
                .transaction_with(|owner| handover::prepare_locked(
                    owner,
                    &mut peer,
                    None,
                    &|_| Ok(())
                ))
                .is_err()
        );
        assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&original));
        assert!(
            backend.memory.slot(Slot::AccountReview).is_none()
                && backend.memory.slot(Slot::CheckpointKey).is_none()
        );
        assert!(!temp.path().join("Sync").exists());
        assert_eq!(peer.posts, 1);
    }
}
#[test]
fn rebound_first_key_review_marks_a_replaced_recovery_envelope_without_disclosing_old_code() {
    let (_temp, mut store, backend, mut peer) = setup();
    create(&mut store, &mut peer).unwrap();
    let original = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    peer.core.pin.dataset = Binding::from_checkpoint([66; 32]);
    peer.core.recovery = Some(Evidence {
        version: 2,
        ciphertext: vec![0; 100],
    });
    assert!(
        reviewed_activation(&mut store, &mut peer)
            == Outcome::Ready {
                kit: KitStatus::Replaced
            }
    );
    assert!(
        store
            .transaction_with(|owner| disclosure::prepare_locked(owner, &mut peer))
            .is_err()
    );
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&original));
    assert_eq!(peer.posts, 1);
}
#[test]
fn initial_candidate_preserves_active_keys_and_starts_no_checkpoint_until_reviewed_activation() {
    let (temp, mut store, backend, mut peer) = setup();
    let old = backend.memory.slot(Slot::LibraryKey).unwrap();
    let archive = backend.memory.slot(Slot::Bootstrap).unwrap();
    assert!(
        create(&mut store, &mut peer)
            == Ok(Status::Ready {
                kit: KitStatus::AwaitingPresentation
            })
    );
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old));
    assert!(backend.memory.slot(Slot::Bootstrap).as_deref() == Some(&archive));
    assert!(
        backend.memory.slot(Slot::CheckpointKey).is_none() && !temp.path().join("Sync").exists()
    );
    activate(&mut store, &mut peer);
    let installed = Installed::decode(&backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
    assert!(installed.binding == peer.core.pin);
    assert!(!handover::inspect(&mut store).unwrap().pending);
    assert_eq!(peer.posts, 1);
}
#[test]
fn every_secret_write_failure_reopens_without_regenerating_or_reposting_a_winning_key() {
    for call in 1..=3 {
        for after in [false, true] {
            let (temp, mut store, backend, mut peer) = setup();
            let old = backend.memory.slot(Slot::LibraryKey).unwrap();
            backend.arm(Slot::BootstrapCandidate, call, after);
            assert!(create(&mut store, &mut peer).is_err());
            let before = backend.memory.slot(Slot::BootstrapCandidate);
            let old_material = if let Some(bytes) = before {
                let value = canonical::parse(&bytes).unwrap();
                let entry =
                    Entry::parse(&value.as_object().unwrap()["entries"].as_array().unwrap()[0])
                        .unwrap();
                Some(Zeroizing::new(
                    entry.installed.bundle.for_secure_storage().to_vec(),
                ))
            } else {
                None
            };
            let mut reopened = Store::load(temp.path(), backend.clone()).unwrap();
            assert!(
                create(&mut reopened, &mut peer)
                    == Ok(Status::Ready {
                        kit: KitStatus::AwaitingPresentation
                    })
            );
            let target = reopened
                .transaction_with(|owner| retained_target(owner, &peer.core.pin))
                .unwrap()
                .unwrap();
            if let Some(material) = old_material {
                assert!(target.0.for_secure_storage().as_slice() == material.as_slice());
            }
            assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old));
            assert_eq!(peer.posts, 1);
        }
    }
}
#[test]
fn lost_post_reply_is_reconciled_without_replay_and_keeps_exact_recovery_capability() {
    let (temp, mut store, backend, mut peer) = setup();
    peer.lose_post = true;
    assert!(create(&mut store, &mut peer).is_err());
    let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let mut reopened = Store::load(temp.path(), backend).unwrap();
    assert!(
        create(&mut reopened, &mut peer)
            == Ok(Status::Ready {
                kit: KitStatus::AwaitingPresentation
            })
    );
    let saved = reopened
        .transaction_with(|owner| retained_target(owner, &peer.core.pin))
        .unwrap()
        .unwrap();
    let value = canonical::parse(&before).unwrap();
    let old = Entry::parse(&value.as_object().unwrap()["entries"].as_array().unwrap()[0]).unwrap();
    assert!(saved.0.for_secure_storage() == old.installed.bundle.for_secure_storage());
    assert_eq!(peer.posts, 1);
}
#[test]
fn known_empty_target_retries_same_post_if_server_did_not_observe_original_request() {
    let (_temp, mut store, _backend, mut peer) = setup();
    peer.lose_post = true;
    assert!(create(&mut store, &mut peer).is_err());
    peer.core.public = None;
    peer.core.recovery = None;
    assert!(
        create(&mut store, &mut peer)
            == Ok(Status::Ready {
                kit: KitStatus::AwaitingPresentation
            })
    );
    assert_eq!(peer.posts, 2);
    assert!(peer.payloads[0] == peer.payloads[1]);
}
#[test]
fn authority_recovery_records_and_non_owner_admission_never_create_a_candidate() {
    for mode in 0..5 {
        let (_temp, mut store, backend, mut peer) = setup();
        match mode {
            0 => peer.core.public = Some([88; 32]),
            1 => {
                peer.core.recovery = Some(Evidence {
                    version: 1,
                    ciphertext: vec![1; 32],
                })
            }
            2 => peer.records = true,
            3 => peer.role = Role::Reader,
            _ => peer.role = Role::Writer,
        }
        assert!(create(&mut store, &mut peer).is_err());
        assert!(backend.memory.slot(Slot::BootstrapCandidate).is_none());
        assert_eq!(peer.posts, 0);
    }
}
#[test]
fn server_atomic_races_preserve_unused_candidate_and_never_install_over_old_key() {
    for records in [false, true] {
        let (_temp, mut store, backend, mut peer) = setup();
        let old = backend.memory.slot(Slot::LibraryKey).unwrap();
        peer.race_key = !records;
        peer.race_records = records;
        assert!(create(&mut store, &mut peer).is_err());
        let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
        if records {
            assert!(create(&mut store, &mut peer).is_err());
        } else {
            assert!(create(&mut store, &mut peer) == Ok(Status::Lost));
        }
        assert!(backend.memory.slot(Slot::BootstrapCandidate).is_some());
        assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old));
        assert_eq!(peer.posts, 1);
        let value = canonical::parse(&before).unwrap();
        assert!(
            Entry::parse(&value.as_object().unwrap()["entries"].as_array().unwrap()[0])
                .unwrap()
                .presentation
                .retained()
                .is_ok()
        );
    }
}
#[test]
fn post_scope_halt_preserves_winning_candidate_and_resumes_only_matching_target() {
    let (_temp, mut store, backend, mut peer) = setup();
    let pin = peer.core.pin.clone();
    peer.change_post = true;
    assert!(create(&mut store, &mut peer).is_err());
    let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    peer.core.pin = pin;
    assert!(
        create(&mut store, &mut peer)
            == Ok(Status::Ready {
                kit: KitStatus::AwaitingPresentation
            })
    );
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() != Some(&before));
    assert_eq!(peer.posts, 1);
}
#[test]
fn eight_target_capacity_never_evicts_a_previous_candidate() {
    let (_temp, mut store, backend, mut peer) = setup();
    for i in 0..MAX_ENTRIES {
        peer.core.pin.space = Uuid::from_u128(100 + i as u128);
        peer.core.public = None;
        peer.core.recovery = None;
        assert!(matches!(
            create(&mut store, &mut peer),
            Ok(Status::Ready { .. })
        ));
    }
    let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    peer.core.pin.space = Uuid::from_u128(200);
    peer.core.public = None;
    peer.core.recovery = None;
    assert!(create(&mut store, &mut peer) == Err(Failure::Busy));
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&before));
    assert_eq!(peer.posts, MAX_ENTRIES);
}
#[test]
fn server_recovery_replacement_is_reported_and_retained_key_remains_verified() {
    let (_temp, mut store, _backend, mut peer) = setup();
    create(&mut store, &mut peer).unwrap();
    peer.core.recovery.as_mut().unwrap().version = 2;
    assert!(
        create(&mut store, &mut peer)
            == Ok(Status::Ready {
                kit: KitStatus::Replaced
            })
    );
    let target = store
        .transaction_with(|owner| retained_target(owner, &peer.core.pin))
        .unwrap()
        .unwrap();
    assert!(target.1.status == KitStatus::Replaced);
}

fn shown(store: &mut Store<Faults>, peer: &mut Peer) -> (Gate, disclosure::Disclosure) {
    let target = store
        .transaction_with::<_, Failure>(|owner| Ok(disclosure::prepare_locked(owner, peer)?.1))
        .unwrap();
    let (gate, permit) = authorize(target);
    let value = store
        .transaction_with(|owner| disclosure::reveal_locked(owner, peer, permit))
        .unwrap();
    (gate, value)
}
fn suffix(value: &disclosure::Disclosure) -> Zeroizing<String> {
    let mut chars = Zeroizing::new(
        value
            .long_code()
            .unwrap()
            .chars()
            .filter(|c| c.is_alphanumeric())
            .rev()
            .take(8)
            .collect::<Vec<_>>(),
    );
    chars.reverse();
    Zeroizing::new(chars.iter().collect())
}
fn metadata_only(backend: &Faults) {
    let active =
        super::super::Archive::from_snapshot(backend.memory.slot(Slot::Bootstrap)).unwrap();
    assert!(active.presentation.unwrap().retained().is_err());
    let bytes = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let value = canonical::parse(&bytes).unwrap();
    let entry =
        Entry::parse(&value.as_object().unwrap()["entries"].as_array().unwrap()[0]).unwrap();
    assert!(
        entry.presentation.retained().is_err()
            && entry.presentation.status == KitStatus::VerifiedCurrent
    );
    let bytes = backend.memory.slot(Slot::AccountReview).unwrap();
    let value = canonical::parse(&bytes).unwrap();
    let target = &value.as_object().unwrap()["entries"].as_array().unwrap()[0]
        .as_object()
        .unwrap()["targetBootstrap"];
    let bytes = decode64(target.as_text().unwrap(), secret_store::MAX_SECRET_BYTES).unwrap();
    let target = super::super::Archive::from_snapshot(Some(bytes)).unwrap();
    assert!(target.presentation.unwrap().retained().is_err());
}
#[test]
fn saved_code_confirmation_retires_candidate_and_handover_promoted_copies_before_receipt() {
    let (_temp, mut store, backend, mut peer) = setup();
    create(&mut store, &mut peer).unwrap();
    activate(&mut store, &mut peer);
    let history_before =
        canonical::parse(&backend.memory.slot(Slot::AccountReview).unwrap()).unwrap();
    let original_source = history_before.as_object().unwrap()["entries"]
        .as_array()
        .unwrap()[0]
        .as_object()
        .unwrap()["source"]
        .encode()
        .unwrap();
    let (_gate, value) = shown(&mut store, &mut peer);
    let suffix = suffix(&value);
    assert!(
        store
            .transaction_with(|owner| disclosure::confirm_saved_locked(
                owner, &mut peer, value, suffix
            ))
            .unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    metadata_only(&backend);
    let history_after =
        canonical::parse(&backend.memory.slot(Slot::AccountReview).unwrap()).unwrap();
    assert!(
        history_after.as_object().unwrap()["entries"]
            .as_array()
            .unwrap()[0]
            .as_object()
            .unwrap()["source"]
            .encode()
            .unwrap()
            == original_source
    );
    assert!(
        store
            .transaction_with(|owner| disclosure::prepare_locked(owner, &mut peer))
            .is_err()
    );
}

#[test]
fn verified_recovery_input_after_scope_change_retires_the_original_first_key_copy() {
    let (_temp, mut store, backend, mut peer) = setup();
    create(&mut store, &mut peer).unwrap();
    let (_, presentation) = store
        .transaction_with(|owner| retained_target(owner, &peer.core.pin))
        .unwrap()
        .unwrap();
    let kit = RecoveryKit::decode_secret_qr(
        &presentation
            .retained()
            .unwrap()
            .0
            .encode_secret_qr()
            .unwrap(),
    )
    .unwrap();
    peer.core.pin.dataset = Binding::from_checkpoint([72; 32]);
    peer.core.pin.membership = Binding::from_checkpoint([73; 32]);
    let review = store
        .transaction_with(|owner| {
            handover::prepare_locked(owner, &mut peer, Some(kit), &|_| Ok(()))
        })
        .unwrap();
    let (_gate, permit) = authorize(review.authorization_target().unwrap());
    let outcome = store
        .transaction_with(|owner| {
            handover::commit_authorized_locked(owner, &mut peer, review, permit, &|_| Ok(()))
        })
        .unwrap();
    assert!(
        outcome
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    metadata_only(&backend);
}
#[test]
fn sent_candidate_completion_and_retirement_failures_resume_the_same_published_review() {
    for step in 1..=2 {
        for after in [false, true] {
            let (temp, mut store, backend, mut peer) = setup();
            let original_binding = peer.core.pin.clone();
            peer.change_post = true;
            assert!(create(&mut store, &mut peer).is_err());
            let keys = store
                .transaction_with(|owner| review_keys(owner, &original_binding))
                .unwrap();
            let presentation = keys.into_iter().next().unwrap().1.unwrap();
            let kit = RecoveryKit::decode_secret_qr(
                &presentation
                    .retained()
                    .unwrap()
                    .0
                    .encode_secret_qr()
                    .unwrap(),
            )
            .unwrap();
            let review = store
                .transaction_with(|owner| {
                    handover::prepare_locked(owner, &mut peer, Some(kit), &|_| Ok(()))
                })
                .unwrap();
            let (_gate, permit) = authorize(review.authorization_target().unwrap());
            backend.arm(Slot::BootstrapCandidate, step, after);
            assert!(
                store
                    .transaction_with(|owner| handover::commit_authorized_locked(
                        owner,
                        &mut peer,
                        review,
                        permit,
                        &|_| Ok(())
                    ))
                    .is_err()
            );
            assert!(handover::inspect(&mut store).unwrap().pending);
            let published = std::fs::read(temp.path().join("Sync/journal.bin")).unwrap();
            let mut reopened = Store::load(temp.path(), backend.clone()).unwrap();
            let target = handover::prepare_resume_authorization(&mut reopened).unwrap();
            let (_gate, permit) = authorize(target);
            assert!(
                reopened
                    .transaction_with(|owner| handover::resume_authorized_locked(
                        owner,
                        &mut peer,
                        permit,
                        &|_| Ok(())
                    ))
                    .unwrap()
                    == Outcome::Ready {
                        kit: KitStatus::VerifiedCurrent
                    }
            );
            metadata_only(&backend);
            assert!(!handover::inspect(&mut reopened).unwrap().pending);
            assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == published);
            assert_eq!(peer.posts, 1);
        }
    }
}

#[test]
fn offline_finish_completes_owned_sent_candidate_and_retries_interrupted_retirement() {
    for typed in [false, true] {
        for step in 1..=if typed { 2 } else { 1 } {
            for after in [false, true] {
                let (temp, mut store, backend, mut peer) = setup();
                let original_binding = peer.core.pin.clone();
                peer.change_post = true;
                assert!(create(&mut store, &mut peer).is_err());
                let candidate = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
                let kit = if typed {
                    let (_, presentation) = store
                        .transaction_with(|owner| review_keys(owner, &original_binding))
                        .unwrap()
                        .into_iter()
                        .next()
                        .unwrap();
                    Some(
                        RecoveryKit::decode_secret_qr(
                            &presentation
                                .unwrap()
                                .retained()
                                .unwrap()
                                .0
                                .encode_secret_qr()
                                .unwrap(),
                        )
                        .unwrap(),
                    )
                } else {
                    None
                };
                let review = store
                    .transaction_with(|owner| {
                        handover::prepare_locked(owner, &mut peer, kit, &|_| Ok(()))
                    })
                    .unwrap();
                let (_gate, permit) = authorize(review.authorization_target().unwrap());
                backend.arm(Slot::LibraryKey, 1, false);
                assert!(
                    store
                        .transaction_with(|owner| handover::commit_authorized_locked(
                            owner,
                            &mut peer,
                            review,
                            permit,
                            &|_| Ok(())
                        ))
                        .is_err()
                );
                assert!(handover::inspect(&mut store).unwrap().pending);
                assert!(
                    backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&candidate)
                );
                let checkpoint = std::fs::read(temp.path().join("Sync/journal.bin")).unwrap();
                peer.core.pin.dataset = Binding::from_checkpoint([0x91; 32]);
                peer.core.pin.epoch += 1;
                let calls = peer.core.calls;
                backend.arm(Slot::BootstrapCandidate, step, after);
                let (target, _) = handover::prepare_local_authorization(&mut store).unwrap();
                let (_gate, permit) = authorize(target);
                assert!(handover::finish_local(&mut store, permit).is_err());
                assert!(handover::inspect(&mut store).unwrap().pending);
                let mut reopened = Store::load(temp.path(), backend.clone()).unwrap();
                let (target, _) = handover::prepare_local_authorization(&mut reopened).unwrap();
                let (_gate, permit) = authorize(target);
                handover::finish_local(&mut reopened, permit).unwrap();
                assert!(!handover::inspect(&mut reopened).unwrap().pending);
                assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == checkpoint);
                assert_eq!(peer.core.calls, calls);
                assert_eq!(peer.posts, 1);
                if typed {
                    metadata_only(&backend);
                } else {
                    let before = canonical::parse(&candidate).unwrap();
                    let current =
                        canonical::parse(&backend.memory.slot(Slot::BootstrapCandidate).unwrap())
                            .unwrap();
                    let before = before.as_object().unwrap()["entries"].as_array().unwrap()[0]
                        .as_object()
                        .unwrap();
                    let current = current.as_object().unwrap()["entries"].as_array().unwrap()[0]
                        .as_object()
                        .unwrap();
                    assert_eq!(current["phase"].as_text().unwrap(), "ready");
                    for field in ["installed", "account", "presentation"] {
                        assert!(
                            before[field].encode().unwrap() == current[field].encode().unwrap()
                        );
                    }
                }
            }
        }
    }
}
#[test]
fn verified_input_adoption_interrupted_retirement_keeps_activation_pending_until_fresh_resume() {
    for after in [false, true] {
        let (temp, mut store, backend, mut peer) = setup();
        create(&mut store, &mut peer).unwrap();
        let (_, presentation) = store
            .transaction_with(|owner| retained_target(owner, &peer.core.pin))
            .unwrap()
            .unwrap();
        let kit = RecoveryKit::decode_secret_qr(
            &presentation
                .retained()
                .unwrap()
                .0
                .encode_secret_qr()
                .unwrap(),
        )
        .unwrap();
        let review = store
            .transaction_with(|owner| {
                handover::prepare_locked(owner, &mut peer, Some(kit), &|_| Ok(()))
            })
            .unwrap();
        let (_gate, permit) = authorize(review.authorization_target().unwrap());
        backend.arm(Slot::BootstrapCandidate, 1, after);
        assert!(
            store
                .transaction_with(|owner| {
                    handover::commit_authorized_locked(
                        owner,
                        &mut peer,
                        review,
                        permit,
                        &|_| Ok(()),
                    )
                })
                .is_err()
        );
        assert!(handover::inspect(&mut store).unwrap().pending);
        assert!(store.transaction_with(handover::require_idle).is_err());
        let published = std::fs::read(temp.path().join("Sync/journal.bin")).unwrap();
        let mut reopened = Store::load(temp.path(), backend.clone()).unwrap();
        let target = handover::prepare_resume_authorization(&mut reopened).unwrap();
        let (_gate, permit) = authorize(target);
        assert!(
            reopened
                .transaction_with(|owner| {
                    handover::resume_authorized_locked(owner, &mut peer, permit, &|_| Ok(()))
                })
                .unwrap()
                == Outcome::Ready {
                    kit: KitStatus::VerifiedCurrent
                }
        );
        assert!(!handover::inspect(&mut reopened).unwrap().pending);
        assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == published);
        assert_eq!(peer.posts, 1);
        metadata_only(&backend);
    }
}
#[test]
fn every_confirmation_copy_failure_keeps_a_redo_source_and_resolves_lost_receipts() {
    for slot in [
        Slot::BootstrapCandidate,
        Slot::AccountReview,
        Slot::Bootstrap,
    ] {
        for after in [false, true] {
            let (temp, mut store, backend, mut peer) = setup();
            create(&mut store, &mut peer).unwrap();
            activate(&mut store, &mut peer);
            let (_gate, value) = shown(&mut store, &mut peer);
            let entered = suffix(&value);
            backend.arm(slot, 1, after);
            assert!(
                store
                    .transaction_with(|owner| disclosure::confirm_saved_locked(
                        owner, &mut peer, value, entered
                    ))
                    .is_err()
            );
            let mut reopened = Store::load(temp.path(), backend.clone()).unwrap();
            let active = reopened
                .transaction_with(super::super::Archive::load)
                .unwrap();
            if active.presentation.as_ref().unwrap().status == KitStatus::AwaitingPresentation {
                let (_gate, value) = shown(&mut reopened, &mut peer);
                let entered = suffix(&value);
                assert!(
                    reopened
                        .transaction_with(|owner| disclosure::confirm_saved_locked(
                            owner, &mut peer, value, entered
                        ))
                        .is_ok()
                );
            }
            metadata_only(&backend);
            assert!(
                reopened
                    .transaction_with(|owner| disclosure::prepare_locked(owner, &mut peer))
                    .is_err()
            );
        }
    }
}
#[test]
fn same_account_refresh_reconciles_but_another_account_cannot_reuse_candidate() {
    use crate::auth_store::{Deployment, creation::tests::install};
    let (_temp, mut store, backend, mut peer) = setup();
    let deployment =
        Deployment::from_discovery(peer.core.pin.server.clone(), peer.core.pin.instance);
    let _first = install(
        &mut store,
        deployment.clone(),
        "initial-first",
        "public-initial-account",
    );
    peer.lose_post = true;
    assert!(create(&mut store, &mut peer).is_err());
    let _refresh = install(
        &mut store,
        deployment.clone(),
        "initial-refreshed",
        "public-initial-account",
    );
    assert!(matches!(
        create(&mut store, &mut peer),
        Ok(Status::Ready { .. })
    ));
    let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let _other = install(
        &mut store,
        deployment,
        "initial-other",
        "public-other-account",
    );
    assert!(
        store
            .transaction_with(|owner| retained_target(owner, &peer.core.pin))
            .unwrap()
            .is_none()
    );
    assert!(create(&mut store, &mut peer).is_err());
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&before));
    assert_eq!(peer.posts, 1);
}
#[test]
fn closed_schema_and_forged_ready_without_matching_key_are_refused_before_network_post() {
    for mode in 0..3 {
        let (_temp, mut store, backend, mut peer) = setup();
        create(&mut store, &mut peer).unwrap();
        let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
        let mut value = canonical::parse(&before).unwrap();
        let Value::Object(fields) = &mut value else {
            unreachable!()
        };
        match mode {
            0 => {
                fields.insert("schema".into(), Value::Int(3));
            }
            1 => {
                fields.insert("extra".into(), Value::Bool(true));
            }
            _ => {
                let Value::Array(entries) = fields.get_mut("entries").unwrap() else {
                    unreachable!()
                };
                let Value::Object(entry) = &mut entries[0] else {
                    unreachable!()
                };
                let other = Bundle::generate().unwrap();
                let installed = Installed {
                    binding: peer.core.pin.clone(),
                    bundle: other,
                };
                entry.insert("installed".into(), installed.value().unwrap());
            }
        }
        let bytes = value.encode().unwrap();
        store
            .transaction(|owner| {
                owner.replace(Slot::BootstrapCandidate, Some(&before), Some(&bytes))
            })
            .unwrap();
        assert!(create(&mut store, &mut peer).is_err());
        assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&bytes));
        assert_eq!(peer.posts, 1);
    }
}
#[test]
fn exhausted_generation_stops_before_post_and_retains_the_original_intent() {
    let (_temp, mut store, backend, mut peer) = setup();
    backend.arm(Slot::BootstrapCandidate, 2, false);
    assert!(create(&mut store, &mut peer).is_err());
    let before = backend.memory.slot(Slot::BootstrapCandidate).unwrap();
    let mut value = canonical::parse(&before).unwrap();
    let Value::Object(fields) = &mut value else {
        unreachable!()
    };
    fields.insert("generation".into(), Value::Int(i64::MAX - 1));
    let bytes = value.encode().unwrap();
    store
        .transaction(|owner| owner.replace(Slot::BootstrapCandidate, Some(&before), Some(&bytes)))
        .unwrap();
    assert!(create(&mut store, &mut peer) == Err(Failure::InvalidState));
    assert_eq!(peer.posts, 0);
    assert!(backend.memory.slot(Slot::BootstrapCandidate).as_deref() == Some(&bytes));
}

#[cfg(feature = "desktop")]
#[test]
fn lost_ui_reply_needs_no_volatile_quit_barrier_and_resumes_the_durable_key_setup() {
    use crate::account_worker::{Command, Failure as AccountFailure, Handle, Reply};
    for failure in [None, Some(false), Some(true)] {
        let (_temp, mut store, backend, mut peer) = setup();
        if let Some(after) = failure {
            backend.arm(Slot::BootstrapCandidate, 3, after);
        }
        let worker = Handle::controlled(move |command| {
            let result = match command {
                Command::BootstrapCandidate => {
                    let failure = create(&mut store, &mut peer)
                        .err()
                        .map(AccountFailure::from);
                    Ok(Reply::BootstrapCandidate {
                        state: inspect(&mut store, &peer.core.pin),
                        candidate: Ok(None),
                        failure,
                    })
                }
                Command::Inspect => Ok(Reply::BootstrapCandidate {
                    state: inspect(&mut store, &peer.core.pin),
                    candidate: Ok(None),
                    failure: None,
                }),
                _ => Err(AccountFailure::InvalidState),
            };
            (result, false)
        });
        drop(worker.request(Command::BootstrapCandidate).unwrap());
        let Reply::BootstrapCandidate { state, .. } = worker
            .request(Command::Inspect)
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .unwrap()
        else {
            panic!("Expected safe durable setup metadata");
        };
        assert!(matches!(
            state,
            Ok(Some(Status::Sent | Status::Ready { .. }))
        ));
        assert!(worker.can_quit() && !worker.retention_required());
        let Reply::BootstrapCandidate { state, failure, .. } = worker
            .request(Command::BootstrapCandidate)
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .unwrap()
        else {
            panic!("Expected resumed setup metadata");
        };
        assert!(matches!(state, Ok(Some(Status::Ready { .. }))) && failure.is_none());
    }
}
