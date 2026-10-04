use super::*;
use std::sync::{Arc, Mutex};

#[path = "key_store_http_tests.rs"]
mod http;

#[path = "pairing_store_tests.rs"]
mod recipient;

#[path = "recovery_disclosure_tests.rs"]
mod disclosure;

#[path = "key_mutation_tests.rs"]
mod mutations;

#[derive(Clone, Default)]
pub(super) struct Memory(Arc<Mutex<MemoryState>>);
#[derive(Default)]
struct MemoryState {
    values: BTreeMap<([u8; 16], Slot), Zeroizing<Vec<u8>>>,
    writes: usize,
    fail_write: Option<(usize, bool)>,
    fail_read: bool,
}
impl Backend for Memory {
    fn read(
        &mut self,
        ns: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        let state = self.0.lock().unwrap();
        if state.fail_read {
            return Err(secret_store::Failure::Locked);
        }
        Ok(state.values.get(&(*ns, slot)).cloned())
    }
    fn write(&mut self, ns: &[u8; 16], slot: Slot, value: &[u8]) -> secret_store::Result<()> {
        let mut state = self.0.lock().unwrap();
        state.writes += 1;
        let fail = state.fail_write.filter(|(n, _)| *n == state.writes);
        if !matches!(fail, Some((_, false))) {
            state
                .values
                .insert((*ns, slot), Zeroizing::new(value.into()));
        }
        if fail.is_some() {
            return Err(secret_store::Failure::Unavailable);
        }
        Ok(())
    }
    fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
        self.0.lock().unwrap().values.remove(&(*ns, slot));
        Ok(())
    }
}
impl Memory {
    pub(super) fn slot(&self, slot: Slot) -> Option<Zeroizing<Vec<u8>>> {
        self.0
            .lock()
            .unwrap()
            .values
            .iter()
            .find(|((_, s), _)| *s == slot)
            .map(|(_, v)| v.clone())
    }
}
fn binding() -> KeyBinding {
    KeyBinding::new(
        ServerURL::parse("https://sync.example").unwrap(),
        Uuid::from_u128(1),
        Uuid::from_u128(2),
        (
            Binding::from_checkpoint([3; 32]),
            Binding::from_checkpoint([4; 32]),
        ),
        1,
    )
    .unwrap()
}
pub(super) struct FakeRemote {
    pub(super) pin: KeyBinding,
    role: Role,
    pub(super) public: Option<[u8; 32]>,
    pub(super) recovery: Option<Evidence>,
    records: bool,
    pub(super) posts: usize,
    memory: Memory,
    lose_post: bool,
    hide_after_post: bool,
    pub(super) calls: usize,
    pub(super) change_on: Option<usize>,
    cancel_on_recovery: Option<crate::local_auth::Gate>,
}
impl FakeRemote {
    pub(super) fn new(memory: Memory) -> Self {
        Self {
            pin: binding(),
            role: Role::Owner,
            public: None,
            recovery: None,
            records: false,
            posts: 0,
            memory,
            lose_post: false,
            hide_after_post: false,
            calls: 0,
            change_on: None,
            cancel_on_recovery: None,
        }
    }
    fn call(&mut self) {
        self.calls += 1;
        if self.change_on == Some(self.calls) {
            self.pin.dataset = Binding::from_checkpoint([8; 32]);
        }
    }
}
impl Remote for FakeRemote {
    fn preflight(&mut self) -> Result<()> {
        self.call();
        Ok(())
    }
    fn binding(&self) -> Result<KeyBinding> {
        Ok(self.pin.clone())
    }
    fn role(&self) -> Role {
        self.role
    }
    fn authority(&mut self) -> Result<Option<[u8; 32]>> {
        self.call();
        Ok(if self.hide_after_post && self.posts > 0 {
            None
        } else {
            self.public
        })
    }
    fn recovery(&mut self) -> Result<Option<Evidence>> {
        self.call();
        if let Some(mut gate) = self.cancel_on_recovery.take() {
            gate.cancel();
        }
        Ok(self.recovery.as_ref().map(|v| Evidence {
            version: v.version,
            ciphertext: v.ciphertext.clone(),
        }))
    }
    fn has_records(&mut self) -> Result<bool> {
        self.call();
        Ok(self.records)
    }
    fn bootstrap(&mut self, public: &[u8; 32], ciphertext: &[u8]) -> Result<Evidence> {
        self.call();
        self.posts += 1;
        assert!(self.memory.slot(Slot::LibraryKey).is_none());
        let bytes = self.memory.slot(Slot::Bootstrap).unwrap();
        let value = canonical::parse(&bytes).unwrap();
        let pending = Pending::parse(&value.as_object().unwrap()["pending"]).unwrap();
        assert!(
            pending.ciphertext == ciphertext
                && Authority::new(&pending.bundle, &pending.binding.context().unwrap())
                    .public_key()
                    == *public
        );
        assert!(pending.kind == Kind::Initial);
        if self.public.is_some() {
            return Err(Failure::Cloud(cloud::Failure::Server {
                code: cloud::ErrorCode::Conflict,
                retry_after: None,
            }));
        }
        self.public = Some(*public);
        self.recovery = Some(Evidence {
            version: 1,
            ciphertext: ciphertext.into(),
        });
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
fn setup(memory: Memory) -> (tempfile::TempDir, Store<Memory>, FakeRemote) {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let remote = FakeRemote::new(memory);
    (temp, store, remote)
}
fn initialize(store: &mut Store<Memory>, remote: &mut FakeRemote) -> Result<Outcome> {
    store.transaction_with(|o| initialize_locked(o, remote))
}
fn load(store: &mut Store<Memory>, remote: &mut FakeRemote) -> Result<Option<VerifiedKey>> {
    store.transaction_with(|o| load_locked(o, remote))
}

#[test]
fn created_library_receipt_fences_bootstrap_and_verification_before_any_key_is_generated() {
    use crate::auth_store::{Deployment, creation::tests};
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    let space: crate::cloud::Space = serde_json::from_value(serde_json::json!({
        "scope":{"serverInstanceId":Uuid::from_u128(1),"spaceId":Uuid::from_u128(2),
        "scopeBinding":base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([5;32]),
        "datasetGeneration":Uuid::from_u128(3),"feedEpoch":Uuid::from_u128(4)},
        "role":"owner","keyEpoch":1
    }))
    .unwrap();
    let deployment = Deployment::from_discovery(
        ServerURL::parse("https://sync.example").unwrap(),
        Uuid::from_u128(1),
    );
    let _live = tests::completed(&mut store, deployment.clone(), space.clone());
    let pin = space.key_binding(&deployment).unwrap();
    remote.pin = pin.clone();
    remote.pin.dataset = Binding::from_checkpoint([99; 32]);
    assert!(initialize(&mut store, &mut remote).err() == Some(Failure::ReviewRequired));
    assert!(memory.slot(Slot::LibraryKey).is_none() && memory.slot(Slot::Bootstrap).is_none());
    assert_eq!(remote.posts, 0);
    remote.pin = pin;
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
    let original = memory.slot(Slot::LibraryKey).unwrap();
    let _other = tests::install(
        &mut store,
        deployment,
        "other-integration",
        "public-other-account",
    );
    assert!(load(&mut store, &mut remote).err() == Some(Failure::ReviewRequired));
    assert!(memory.slot(Slot::LibraryKey).unwrap().as_slice() == original.as_slice());
    assert_eq!(remote.posts, 1);
}

#[test]
fn control_plane_admission_keeps_checkpoint_review_separate_and_refuses_foreign_key_scope() {
    let memory = Memory::default();
    let (temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let key = memory.slot(Slot::LibraryKey).unwrap();
    let presentation = memory.slot(Slot::Bootstrap).unwrap();
    let pin = remote.pin.clone();
    let mut scope = pin.checkpoint_scope();
    scope.dataset = Binding::from_checkpoint([99; 32]);
    let bytes = checkpoint(&temp, &mut store, scope);
    assert!(load(&mut store, &mut remote).is_err());
    let calls = remote.calls;
    check_admission(&mut store, &pin).unwrap();
    for changed in 0..6 {
        let mut foreign = pin.clone();
        match changed {
            0 => foreign.server = ServerURL::parse("https://foreign.example.test").unwrap(),
            1 => foreign.instance = Uuid::from_u128(19),
            2 => foreign.space = Uuid::from_u128(29),
            3 => foreign.membership = Binding::from_checkpoint([39; 32]),
            4 => foreign.dataset = Binding::from_checkpoint([49; 32]),
            _ => foreign.epoch += 1,
        }
        assert!(check_admission(&mut store, &foreign) == Err(Failure::ReviewRequired));
    }
    assert_eq!(remote.calls, calls);
    assert!(memory.slot(Slot::LibraryKey).unwrap().as_slice() == key.as_slice());
    assert!(memory.slot(Slot::Bootstrap).unwrap().as_slice() == presentation.as_slice());
    assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == bytes);
}
fn recover(
    store: &mut Store<Memory>,
    remote: &mut FakeRemote,
    kit: RecoveryKit,
) -> Result<Outcome> {
    store.transaction_with(|o| recover_locked(o, remote, kit))
}
fn remote_library(remote: &mut FakeRemote) -> (Bundle, RecoveryKit) {
    let bundle = Bundle::from_material(&[7; 64]).unwrap();
    let recovery = bootstrap::create_recovery(
        &bundle,
        remote.pin.server.clone(),
        remote.pin.space,
        remote.pin.epoch as i64,
    )
    .unwrap();
    remote.public = Some(Authority::new(&bundle, &remote.pin.context().unwrap()).public_key());
    remote.recovery = Some(Evidence {
        version: 3,
        ciphertext: recovery.ciphertext,
    });
    (bundle, recovery.kit)
}

#[test]
fn cancellation_fences_every_key_verification_request_without_minting_or_replacing() {
    let memory = Memory::default();
    let (root, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let key_before = memory.slot(Slot::LibraryKey).unwrap();
    let archive_before = memory.slot(Slot::Bootstrap).unwrap();
    let checks = std::cell::Cell::new(0usize);
    store
        .transaction_with::<_, Failure>(|owner| {
            load_locked_checked(owner, &mut remote, &|| {
                checks.set(checks.get() + 1);
                Ok(())
            })
        })
        .unwrap();
    let total = checks.get();
    assert!(total > 5);
    let posts = remote.posts;
    for stop in 1..=total {
        checks.set(0);
        let result = store.transaction_with::<_, Failure>(|owner| {
            load_locked_checked(owner, &mut remote, &|| {
                checks.set(checks.get() + 1);
                if checks.get() == stop {
                    Err(Failure::Busy)
                } else {
                    Ok(())
                }
            })
        });
        assert!(matches!(result, Err(Failure::Busy)), "fence {stop}");
        assert_eq!(checks.get(), stop);
        assert_eq!(remote.posts, posts);
        assert_eq!(
            memory.slot(Slot::LibraryKey).unwrap().as_slice(),
            key_before.as_slice()
        );
        assert_eq!(
            memory.slot(Slot::Bootstrap).unwrap().as_slice(),
            archive_before.as_slice()
        );
        assert!(memory.slot(Slot::CheckpointKey).is_none());
        assert!(!root.path().join("Sync").exists());
        assert!(!root.path().join("device.json").exists());
    }
}
#[test]
fn first_key_is_journaled_before_upload_and_presentation_before_retiring_pending() {
    let memory = Memory::default();
    let (temp, mut store, mut remote) = setup(memory.clone());
    assert!(
        load(&mut store, &mut remote).unwrap().is_none() && memory.slot(Slot::Bootstrap).is_none()
    );
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
    assert_eq!(remote.posts, 1);
    let key = load(&mut store, &mut remote).unwrap().unwrap();
    assert!(key.binding() == &binding());
    let archive = store.transaction_with(Archive::load).unwrap();
    assert!(archive.pending.is_none() && archive.presentation.is_some() && archive.generation == 3);
    let (kit, ciphertext) = archive.presentation.as_ref().unwrap().retained().unwrap();
    let opened = bootstrap::open_recovery(ciphertext, kit).unwrap();
    assert!(opened.for_secure_storage() == key.bundle.for_secure_storage());
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
            && remote.posts == 1
    );
    for entry in std::fs::read_dir(temp.path()).unwrap() {
        let bytes = std::fs::read(entry.unwrap().path()).unwrap();
        assert!(
            !bytes
                .windows(32)
                .any(|v| v == &key.bundle.for_secure_storage()[..32])
        );
    }
}
#[test]
fn lost_post_response_resumes_the_same_bundle_kit_and_cipher_without_another_post() {
    let memory = Memory::default();
    let (temp, mut store, mut remote) = setup(memory.clone());
    remote.lose_post = true;
    assert!(
        initialize(&mut store, &mut remote).err() == Some(Failure::Cloud(cloud::Failure::Network))
    );
    let candidate = memory.slot(Slot::Bootstrap).unwrap();
    assert!(
        memory.slot(Slot::LibraryKey).is_none()
            && load(&mut store, &mut remote).err() == Some(Failure::Busy)
    );
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
    let value = canonical::parse(&candidate).unwrap();
    let pending = Pending::parse(&value.as_object().unwrap()["pending"]).unwrap();
    let key = load(&mut store, &mut remote).unwrap().unwrap();
    assert!(
        pending.bundle.for_secure_storage() == key.bundle.for_secure_storage() && remote.posts == 1
    );
    let archive = store.transaction_with(Archive::load).unwrap();
    assert!(archive.presentation.as_ref().unwrap().retained().unwrap().1 == pending.ciphertext);
}
#[test]
fn pending_first_keys_allow_only_read_only_open_of_the_exact_created_target() {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    remote.lose_post = true;
    assert!(initialize(&mut store, &mut remote).is_err());
    let before = memory.0.lock().unwrap().values.clone();
    let writes = memory.0.lock().unwrap().writes;
    let calls = remote.calls;
    assert!(
        store
            .transaction_with(|owner| creation_open_source_locked(owner, &remote.pin))
            .unwrap()
            .is_none()
    );
    assert!(store.transaction_with(creation_source_locked).err() == Some(Failure::ReviewRequired));
    assert!(load(&mut store, &mut remote).err() == Some(Failure::Busy));
    // Read-only metadata admission does not grant usable key material or alter
    // the draft. Every complete target-identity component remains required.
    for changed in 0..6 {
        let mut target = remote.pin.clone();
        match changed {
            0 => target.server = ServerURL::parse("https://other.example").unwrap(),
            1 => target.instance = Uuid::from_u128(9),
            2 => target.space = Uuid::from_u128(10),
            3 => target.membership = Binding::from_checkpoint([9; 32]),
            4 => target.dataset = Binding::from_checkpoint([10; 32]),
            _ => target.epoch += 1,
        }
        assert!(
            store
                .transaction_with(|owner| creation_open_source_locked(owner, &target))
                .is_err()
        );
    }
    assert!(memory.0.lock().unwrap().values == before);
    assert_eq!(memory.0.lock().unwrap().writes, writes);
    assert_eq!(remote.posts, 1);
    // Only load() performed its normal preflight; the metadata checks made no
    // HTTP request and did not expose the unfinished bundle to the data plane.
    assert_eq!(remote.calls, calls + 1);
    store
        .transaction_with::<_, Failure>(|owner| {
            let mut archive = Archive::load(owner)?;
            archive.pending.as_mut().unwrap().kind = Kind::Recovery;
            archive.save(owner)
        })
        .unwrap();
    let recovery = memory.0.lock().unwrap().values.clone();
    assert!(
        store
            .transaction_with(|owner| creation_open_source_locked(owner, &remote.pin))
            .err()
            == Some(Failure::ReviewRequired)
    );
    assert!(memory.0.lock().unwrap().values == recovery);
}

#[test]
fn every_ambiguous_or_failed_secret_write_preserves_a_restart_path_without_key_rotation() {
    for nth in 1..=4 {
        for after in [false, true] {
            let memory = Memory::default();
            let (temp, mut store, mut remote) = setup(memory.clone());
            memory.0.lock().unwrap().fail_write = Some((nth, after));
            assert!(initialize(&mut store, &mut remote).is_err());
            let before = remote.public;
            let posts = remote.posts;
            memory.0.lock().unwrap().fail_write = None;
            drop(store);
            let mut store = Store::load(temp.path(), memory.clone()).unwrap();
            assert!(
                initialize(&mut store, &mut remote).unwrap()
                    == Outcome::Ready {
                        kit: KitStatus::AwaitingPresentation
                    }
            );
            let key = load(&mut store, &mut remote).unwrap().unwrap();
            if let Some(public) = before {
                assert!(
                    Authority::new(&key.bundle, &key.binding.context().unwrap()).public_key()
                        == public
                        && remote.posts == posts
                );
            }
            assert!(
                store
                    .transaction_with(Archive::load)
                    .unwrap()
                    .pending
                    .is_none()
            );
        }
    }
}
#[test]
fn a_missing_authority_after_success_never_discards_the_durable_candidate() {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    remote.hide_after_post = true;
    assert!(initialize(&mut store, &mut remote).err() == Some(Failure::KeyConflict));
    assert!(
        memory.slot(Slot::LibraryKey).is_none()
            && store
                .transaction_with(Archive::load)
                .unwrap()
                .pending
                .is_some()
    );
    remote.hide_after_post = false;
    assert!(initialize(&mut store, &mut remote).is_ok() && remote.posts == 1);
}
#[test]
fn remote_records_recovery_authority_or_nonowner_role_prevent_local_key_creation() {
    for index in 0..4 {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        match index {
            0 => remote.records = true,
            1 => {
                remote_library(&mut remote);
            }
            2 => remote.public = Some([8; 32]),
            _ => remote.role = Role::Writer,
        }
        assert!(
            initialize(&mut store, &mut remote).unwrap() == Outcome::NeedsTrustedDeviceOrRecovery
        );
        assert!(
            memory.slot(Slot::LibraryKey).is_none()
                && memory.slot(Slot::Bootstrap).is_none()
                && remote.posts == 0
        );
    }
}
#[test]
fn recovery_authenticates_scope_cipher_and_remote_authority_before_installing_and_restores_lost_slots()
 {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    let (bundle, kit) = remote_library(&mut remote);
    let kit_bytes = kit.encode_secret_qr().unwrap();
    assert!(
        recover(&mut store, &mut remote, kit).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    assert!(
        load(&mut store, &mut remote)
            .unwrap()
            .unwrap()
            .bundle
            .for_secure_storage()
            == bundle.for_secure_storage()
    );
    store
        .transaction(|owner| {
            let old = owner.read(Slot::LibraryKey)?.unwrap();
            owner.replace(Slot::LibraryKey, Some(&old), None)
        })
        .unwrap();
    assert!(initialize(&mut store, &mut remote).err() == Some(Failure::KeyConflict));
    assert!(
        recover(
            &mut store,
            &mut remote,
            RecoveryKit::decode_secret_qr(&kit_bytes).unwrap()
        )
        .unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    assert!(load(&mut store, &mut remote).unwrap().is_some() && remote.posts == 0);
}
#[test]
fn foreign_bad_or_replaced_recovery_never_changes_secret_slots() {
    for index in 0..4 {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        let (_bundle, kit) = remote_library(&mut remote);
        let kit = if index == 0 {
            RecoveryKit::generate(
                ServerURL::parse("https://other.example").unwrap(),
                remote.pin.space,
                1,
            )
            .unwrap()
        } else if index == 1 {
            RecoveryKit::generate(remote.pin.server.clone(), remote.pin.space, 1).unwrap()
        } else {
            kit
        };
        if index == 2 {
            remote.public = Some([8; 32]);
        }
        if index == 3 {
            remote.recovery.as_mut().unwrap().ciphertext[12] ^= 1;
        }
        assert!(recover(&mut store, &mut remote, kit).is_err());
        assert!(memory.slot(Slot::LibraryKey).is_none() && memory.slot(Slot::Bootstrap).is_none());
    }
}
#[test]
fn competing_initial_authority_retires_only_an_uninstalled_candidate_then_allows_recovery() {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    remote.lose_post = true;
    assert!(initialize(&mut store, &mut remote).is_err());
    let (_, kit) = remote_library(&mut remote);
    assert!(initialize(&mut store, &mut remote).unwrap() == Outcome::NeedsTrustedDeviceOrRecovery);
    assert!(
        memory.slot(Slot::LibraryKey).is_none()
            && store
                .transaction_with(Archive::load)
                .unwrap()
                .pending
                .is_none()
    );
    assert!(
        recover(&mut store, &mut remote, kit).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
}
#[test]
fn recovery_replacement_after_lost_initial_reply_keeps_the_key_but_never_calls_the_old_kit_current()
{
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    remote.lose_post = true;
    assert!(initialize(&mut store, &mut remote).is_err());
    let archive = store.transaction_with(Archive::load).unwrap();
    let candidate = archive.pending.unwrap();
    let changed = bootstrap::create_recovery(
        &candidate.bundle,
        remote.pin.server.clone(),
        remote.pin.space,
        1,
    )
    .unwrap();
    remote.recovery = Some(Evidence {
        version: 2,
        ciphertext: changed.ciphertext,
    });
    assert!(
        initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::Replaced
            }
    );
    assert!(
        load(&mut store, &mut remote)
            .unwrap()
            .unwrap()
            .bundle
            .for_secure_storage()
            == candidate.bundle.for_secure_storage()
    );
    assert!(
        recover(&mut store, &mut remote, changed.kit).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
}
#[test]
fn binding_changes_mid_operation_and_foreign_installed_keys_fail_closed_without_overwrite() {
    for call in 2..=10 {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        remote.change_on = Some(call);
        let result = initialize(&mut store, &mut remote);
        if call <= remote.calls {
            assert!(result.is_err());
            assert!(memory.slot(Slot::LibraryKey).is_none());
        }
    }
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    initialize(&mut store, &mut remote).unwrap();
    let before = memory.slot(Slot::LibraryKey).unwrap();
    remote.pin.membership = Binding::from_checkpoint([8; 32]);
    assert!(initialize(&mut store, &mut remote).err() == Some(Failure::ReviewRequired));
    assert!(load(&mut store, &mut remote).err() == Some(Failure::ReviewRequired));
    assert!(memory.slot(Slot::LibraryKey).unwrap() == before);
}

#[test]
fn locked_and_corrupt_secret_backends_do_not_masquerade_as_missing_keys() {
    let memory = Memory::default();
    let (_temp, mut store, mut remote) = setup(memory.clone());
    memory.0.lock().unwrap().fail_read = true;
    assert!(
        initialize(&mut store, &mut remote).err()
            == Some(Failure::Secret(secret_store::Failure::Locked))
    );
    memory.0.lock().unwrap().fail_read = false;
    store
        .transaction(|o| o.replace(Slot::Bootstrap, None, Some(b"{\"schema\":1,\"schema\":1}")))
        .unwrap();
    let snapshot = memory.slot(Slot::Bootstrap).unwrap();
    assert!(initialize(&mut store, &mut remote).is_err());
    assert!(
        memory.slot(Slot::Bootstrap).unwrap() == snapshot
            && memory.slot(Slot::LibraryKey).is_none()
            && remote.posts == 0
    );
}

fn checkpoint(
    temp: &tempfile::TempDir,
    store: &mut Store<Memory>,
    scope: crate::journal::Scope,
) -> Vec<u8> {
    let material = store
        .transaction(|o| o.checkpoint_material(true))
        .unwrap()
        .unwrap();
    let root = RootKey::from_bytes(&material[..32]).unwrap();
    let salt = material[32..].try_into().unwrap();
    let library = crate::model::Library::prepare(temp.path().into()).unwrap();
    let mut cp = crate::journal::Checkpoint::load(&library, &root, &salt, scope).unwrap();
    cp.save(&library, &root, &salt).unwrap();
    std::fs::read(temp.path().join("Sync/journal.bin")).unwrap()
}
#[test]
fn a_checkpoint_prevents_new_key_creation_but_bound_recovery_keeps_its_exact_bytes_and_marker() {
    let memory = Memory::default();
    let (temp, mut store, mut remote) = setup(memory.clone());
    let original = checkpoint(&temp, &mut store, binding().checkpoint_scope());
    assert!(initialize(&mut store, &mut remote).is_err());
    assert!(
        memory.slot(Slot::Bootstrap).is_none()
            && memory.slot(Slot::LibraryKey).is_none()
            && remote.posts == 0
    );
    let marker = temp.path().join("Sync/primary.pending");
    std::fs::write(&marker, b"fictional pending marker").unwrap();
    let (_, kit) = remote_library(&mut remote);
    assert!(
        recover(&mut store, &mut remote, kit).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == original);
    assert!(std::fs::read(marker).unwrap() == b"fictional pending marker");
}
#[test]
fn wrong_checkpoint_scope_or_missing_checkpoint_material_cannot_install_a_recovered_key() {
    for lost_key in [false, true] {
        let memory = Memory::default();
        let (temp, mut store, mut remote) = setup(memory.clone());
        let mut scope = binding().checkpoint_scope();
        if !lost_key {
            scope.dataset = Binding::from_checkpoint([8; 32]);
        }
        let original = checkpoint(&temp, &mut store, scope);
        if lost_key {
            store
                .transaction(|o| {
                    let old = o.read(Slot::CheckpointKey)?.unwrap();
                    o.replace(Slot::CheckpointKey, Some(&old), None)
                })
                .unwrap();
        }
        let (_, kit) = remote_library(&mut remote);
        assert!(recover(&mut store, &mut remote, kit).is_err());
        assert!(memory.slot(Slot::LibraryKey).is_none() && memory.slot(Slot::Bootstrap).is_none());
        assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == original);
        if lost_key {
            assert!(memory.slot(Slot::CheckpointKey).is_none());
        }
    }
}
#[test]
fn unsafe_checkpoint_links_preserve_their_targets_and_never_become_empty_state() {
    use std::os::unix::fs::symlink;
    for directory_link in [false, true] {
        let memory = Memory::default();
        let (temp, mut store, mut remote) = setup(memory.clone());
        let outside = tempfile::tempdir().unwrap();
        let target = outside.path().join("journal.bin");
        std::fs::write(&target, b"public untouched target").unwrap();
        if directory_link {
            symlink(outside.path(), temp.path().join("Sync")).unwrap();
        } else {
            std::fs::create_dir(temp.path().join("Sync")).unwrap();
            symlink(&target, temp.path().join("Sync/journal.bin")).unwrap();
        }
        assert!(initialize(&mut store, &mut remote).is_err());
        let (_, kit) = remote_library(&mut remote);
        assert!(recover(&mut store, &mut remote, kit).is_err());
        assert!(memory.slot(Slot::LibraryKey).is_none() && memory.slot(Slot::Bootstrap).is_none());
        assert!(std::fs::read(target).unwrap() == b"public untouched target");
    }
}
#[test]
fn malformed_installed_records_and_journal_bindings_are_never_overwritten() {
    for index in 0..6 {
        let memory = Memory::default();
        let (_temp, mut store, mut remote) = setup(memory.clone());
        initialize(&mut store, &mut remote).unwrap();
        let old = memory.slot(Slot::LibraryKey).unwrap();
        let mut value = canonical::parse(&old).unwrap();
        let v = match &mut value {
            Value::Object(v) => v,
            _ => unreachable!(),
        };
        match index {
            0 => {
                v.insert("schema".into(), Value::Int(2));
            }
            1 => {
                v.insert("unexpected".into(), Value::Bool(true));
            }
            2 => {
                v.insert("bundle".into(), Value::Null);
            }
            _ => {
                let binding = match v.get_mut("binding").unwrap() {
                    Value::Object(v) => v,
                    _ => unreachable!(),
                };
                match index {
                    3 => {
                        binding.insert("epoch".into(), Value::Int(0));
                    }
                    4 => {
                        binding.insert("instance".into(), Value::text(Uuid::nil().to_string()));
                    }
                    _ => {
                        binding.insert("membership".into(), Value::text("invalid"));
                    }
                }
            }
        }
        let changed = value.encode().unwrap();
        store
            .transaction(|o| o.replace(Slot::LibraryKey, Some(&old), Some(&changed)))
            .unwrap();
        assert!(
            initialize(&mut store, &mut remote).is_err() && load(&mut store, &mut remote).is_err()
        );
        assert!(memory.slot(Slot::LibraryKey).unwrap() == changed && remote.posts == 1);
    }
}
