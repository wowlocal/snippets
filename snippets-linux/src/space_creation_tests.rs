//! Public fictional account/grant fixtures and temporary roots only. This
//! scripted protocol owner does not contact a server, keyring or PAM service.
use super::*;
use crate::auth_store::{CleanupReceipt, Replacement};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

#[derive(Clone, Default)]
struct Memory(Arc<Mutex<MemoryState>>);
#[derive(Default)]
struct MemoryState {
    values: BTreeMap<([u8; 16], Slot), Zeroizing<Vec<u8>>>,
    writes: usize,
    fault: Option<(usize, bool)>,
    locked: bool,
}
impl Backend for Memory {
    fn read(
        &mut self,
        ns: &[u8; 16],
        slot: Slot,
    ) -> secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
        let state = self.0.lock().unwrap();
        if state.locked {
            return Err(secret_store::Failure::Locked);
        }
        Ok(state.values.get(&(*ns, slot)).cloned())
    }
    fn write(&mut self, ns: &[u8; 16], slot: Slot, bytes: &[u8]) -> secret_store::Result<()> {
        let mut state = self.0.lock().unwrap();
        state.writes += 1;
        let fault = state.fault.filter(|(at, _)| *at == state.writes);
        if fault != Some((state.writes, false)) {
            state
                .values
                .insert((*ns, slot), Zeroizing::new(bytes.into()));
        }
        if fault.is_some() {
            Err(secret_store::Failure::Unavailable)
        } else {
            Ok(())
        }
    }
    fn delete(&mut self, ns: &[u8; 16], slot: Slot) -> secret_store::Result<()> {
        self.0.lock().unwrap().values.remove(&(*ns, slot));
        Ok(())
    }
}
impl Memory {
    fn slot(&self, slot: Slot) -> Option<Zeroizing<Vec<u8>>> {
        self.0
            .lock()
            .unwrap()
            .values
            .iter()
            .find(|((_, s), _)| *s == slot)
            .map(|(_, v)| v.clone())
    }
    fn fault_after(&self, writes: usize, after: bool) {
        let mut state = self.0.lock().unwrap();
        state.fault = Some((state.writes + writes, after));
    }
}
fn deployment() -> Deployment {
    Deployment::from_discovery(
        cloud::ServerURL::parse("https://creation.example.test").unwrap(),
        Uuid::from_u128(11),
    )
}
fn descriptor(dataset: u128, feed: u128, scope: u8, epoch: u64, role: &str) -> Space {
    descriptor_at(22, dataset, feed, scope, epoch, role)
}
fn descriptor_at(id: u128, dataset: u128, feed: u128, scope: u8, epoch: u64, role: &str) -> Space {
    serde_json::from_value(serde_json::json!({"scope":{"serverInstanceId":Uuid::from_u128(11),"spaceId":Uuid::from_u128(id),"scopeBinding":URL_SAFE_NO_PAD.encode([scope;32]),"datasetGeneration":Uuid::from_u128(dataset),"feedEpoch":Uuid::from_u128(feed)},"role":role,"keyEpoch":epoch})).unwrap()
}
pub(crate) fn install<B: Backend>(
    store: &mut Store<B>,
    deployment: Deployment,
    label: &str,
    identity: &str,
) -> LiveSession {
    store.transaction_with::<_,super::super::Failure>(|owner| {
        let mut archive=Archive::load(owner)?;
        let lease=archive.begin(Replacement::Interactive,deployment.clone())?;archive.save(owner)?;
        let grant=cloud::IssuedGrant::fixture(&serde_json::to_vec(&serde_json::json!({"access_token":format!("public-{label}-access"),"refresh_token":format!("public-{label}-refresh"),"expires_in":300,"token_type":"Bearer","account":{"id":identity,"email":"creator@example.test"}})).unwrap())?;
        let session=grant.accept(|credentials| {
            archive.stage_issued(&lease,credentials).map_err(|_|cloud::Failure::CredentialCommit)?;
            archive.save(owner).map_err(|_|cloud::Failure::CredentialCommit)
        },None,None).map_err(|e|super::super::Failure::Cloud(e.failure))?;
        archive.publish(&lease,&session,1000)?;archive.save(owner)?;
        archive.begin_cleanup(&lease)?;
        for action in archive.cleanup_actions(&lease)? {
            archive.acknowledge(CleanupReceipt {generation:action.generation,index:action.index,deployment:action.deployment,token:action.token,refresh:action.refresh})?;
        }
        archive.finish_cleanup(&lease)?;archive.save(owner)?;
        Ok(LiveSession {deployment,session,monotonic_deadline:crate::clock::uptime().unwrap()+Duration::from_secs(300),wall_deadline:SystemTime::now()+Duration::from_secs(300)})
    }).unwrap()
}
struct FakeRemote {
    deployment: Deployment,
    actual: Uuid,
    memory: Memory,
    requests: Vec<Uuid>,
    creations: usize,
    lose_reply: bool,
    fail_observe: bool,
    change_after_post: bool,
    preflights: usize,
    observed: Space,
    post_role: &'static str,
    wait_until: Option<SystemTime>,
    wait_preflight: Option<SystemTime>,
    next_id: u128,
    mutate_preflight: Option<(usize, Slot)>,
    mutate_post: Option<Slot>,
    mutate_observe: Option<Slot>,
}
impl FakeRemote {
    fn new(memory: Memory) -> Self {
        Self {
            deployment: deployment(),
            actual: Uuid::from_u128(11),
            memory,
            requests: vec![],
            creations: 0,
            lose_reply: false,
            fail_observe: false,
            change_after_post: false,
            preflights: 0,
            observed: descriptor(33, 44, 5, 1, "owner"),
            post_role: "owner",
            wait_until: None,
            wait_preflight: None,
            next_id: 22,
            mutate_preflight: None,
            mutate_post: None,
            mutate_observe: None,
        }
    }
    fn mutate(&self, slot: Slot) {
        let mut state = self.memory.0.lock().unwrap();
        let value = state
            .values
            .iter_mut()
            .find(|((_, s), _)| *s == slot)
            .unwrap()
            .1;
        if slot == Slot::SpaceCreation {
            let mut parsed = serde_json::from_slice::<serde_json::Value>(value).unwrap();
            let generation = parsed["generation"].as_i64().unwrap();
            parsed["generation"] = serde_json::json!(generation + 1);
            *value = Zeroizing::new(serde_json::to_vec(&parsed).unwrap());
        } else {
            value.push(0);
        }
    }
}
impl Remote for FakeRemote {
    fn deployment(&self) -> Deployment {
        self.deployment.clone()
    }
    fn preflight(&mut self) -> Result<()> {
        self.preflights += 1;
        if let Some(until) = self.wait_preflight.take() {
            while SystemTime::now() < until {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        if let Some((at, slot)) = self
            .mutate_preflight
            .filter(|(at, _)| *at == self.preflights)
        {
            assert_eq!(at, self.preflights);
            self.mutate(slot);
        }
        if self.actual != self.deployment.instance
            || (self.change_after_post && !self.requests.is_empty())
        {
            return Err(cloud::Failure::AccountReview.into());
        }
        Ok(())
    }
    fn create(&mut self, _: &Credential, request: Uuid) -> Result<Space> {
        // The request identity must already be retained before the server sees it.
        let bytes = self.memory.slot(Slot::SpaceCreation).unwrap();
        let value = canonical::parse(&bytes).unwrap();
        let journal = if value.as_object().unwrap()["schema"].as_int().unwrap() == 1 {
            &value
        } else {
            value.as_object().unwrap()["entries"]
                .as_array()
                .unwrap()
                .iter()
                .find(|entry| {
                    entry.as_object().unwrap()["request"].as_text().unwrap() == request.to_string()
                })
                .unwrap()
        };
        assert!(journal.as_object().unwrap()["request"].as_text().unwrap() == request.to_string());
        assert!(matches!(
            journal.as_object().unwrap()["created"],
            Value::Null
        ));
        if !self.requests.contains(&request) {
            self.creations += 1;
        }
        self.requests.push(request);
        if self.lose_reply {
            self.lose_reply = false;
            return Err(cloud::Failure::Network.into());
        }
        if let Some(until) = self.wait_until.take() {
            while SystemTime::now() < until {
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        if let Some(slot) = self.mutate_post.take() {
            self.mutate(slot);
        }
        Ok(descriptor_at(self.next_id, 33, 44, 5, 1, self.post_role))
    }
    fn observe(&mut self, _: &Credential, id: Uuid) -> Result<Space> {
        assert_eq!(id, self.observed.id());
        if self.fail_observe {
            return Err(cloud::Failure::Network.into());
        }
        if let Some(slot) = self.mutate_observe.take() {
            self.mutate(slot);
        }
        Ok(self.observed.clone())
    }
}
fn fixture() -> (
    tempfile::TempDir,
    Store<Memory>,
    Memory,
    LiveSession,
    FakeRemote,
) {
    let temp = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let live = install(&mut store, deployment(), "first", "public-creator");
    let remote = FakeRemote::new(memory.clone());
    (temp, store, memory, live, remote)
}
struct Seed {
    deployment: Deployment,
    space: Space,
}
impl Remote for Seed {
    fn deployment(&self) -> Deployment {
        self.deployment.clone()
    }
    fn preflight(&mut self) -> Result<()> {
        Ok(())
    }
    fn create(&mut self, _: &Credential, _: Uuid) -> Result<Space> {
        Ok(self.space.clone())
    }
    fn observe(&mut self, _: &Credential, id: Uuid) -> Result<Space> {
        assert_eq!(id, self.space.id());
        Ok(self.space.clone())
    }
}
pub(crate) fn completed<B: Backend>(
    store: &mut Store<B>,
    deployment: Deployment,
    space: Space,
) -> LiveSession {
    let live = install(
        store,
        deployment.clone(),
        "bootstrap-integration",
        "public-creator",
    );
    let mut remote = Seed { deployment, space };
    store
        .transaction_with::<_, Failure>(|owner| create_locked(owner, &mut remote, &live))
        .unwrap();
    live
}
pub(crate) fn created_beside<B: Backend>(
    store: &mut Store<B>,
    deployment: Deployment,
    space: Space,
    live: &LiveSession,
) {
    let proposal = store
        .transaction_with(|owner| prepare_new_locked(owner, &deployment, live))
        .unwrap();
    let mut remote = Seed { deployment, space };
    store
        .transaction_with::<_, Failure>(|owner| {
            create_mode(owner, &mut remote, live, Some(proposal))
        })
        .unwrap();
}
fn create(store: &mut Store<Memory>, remote: &mut FakeRemote, live: &LiveSession) -> Result<Space> {
    store.transaction_with(|owner| create_locked(owner, remote, live))
}
fn status(store: &mut Store<Memory>, live: &LiveSession) -> Result<State> {
    store.transaction_with(|owner| status_locked(owner, &deployment(), live))
}

#[test]
fn offline_status_does_not_start_creation_or_write_primary_records() {
    let (temp, mut store, memory, live, remote) = fixture();
    let writes = memory.0.lock().unwrap().writes;
    assert!(status(&mut store, &live) == Ok(State::Available));
    assert!(memory.slot(Slot::SpaceCreation).is_none());
    assert_eq!(memory.0.lock().unwrap().writes, writes);
    assert!(remote.requests.is_empty());
    assert!(!temp.path().join("snippets.json").exists() && !temp.path().join("Sync").exists());
}
#[test]
fn lost_reply_and_fresh_session_after_restart_reuse_one_original_request() {
    let (temp, mut store, memory, live, mut remote) = fixture();
    remote.lose_reply = true;
    assert!(
        create(&mut store, &mut remote, &live).err()
            == Some(Failure::Cloud(cloud::Failure::Network))
    );
    let request = remote.requests[0];
    assert!(status(&mut store, &live) == Ok(State::Requested));
    let binding = descriptor(33, 44, 5, 1, "owner")
        .key_binding(&deployment())
        .unwrap();
    assert!(key_store::check_admission(&mut store, &binding) == Err(key_store::Failure::Busy));
    drop(live);
    drop(store);
    let mut restarted = Store::load(temp.path(), memory.clone()).unwrap();
    let renewed = install(&mut restarted, deployment(), "renewed", "public-creator");
    assert!(create(&mut restarted, &mut remote, &renewed).unwrap().id() == binding.space());
    assert_eq!(remote.requests, vec![request, request]);
    assert_eq!(remote.creations, 1);
    assert!(status(&mut restarted, &renewed) == Ok(State::Created));
    assert!(
        memory.slot(Slot::LibraryKey).is_none()
            && memory.slot(Slot::CheckpointKey).is_none()
            && memory.slot(Slot::Bootstrap).is_none()
    );
    create(&mut restarted, &mut remote, &renewed).unwrap();
    assert_eq!(remote.requests.len(), 2);
}
#[test]
fn both_sides_of_each_secret_write_resume_without_duplicate_creation() {
    for write in 1..=2 {
        for after in [false, true] {
            let (temp, mut store, memory, live, mut remote) = fixture();
            memory.fault_after(write, after);
            assert!(
                create(&mut store, &mut remote, &live).err()
                    == Some(Failure::Secret(secret_store::Failure::Unavailable))
            );
            assert_eq!(remote.requests.len(), usize::from(write == 2));
            let retained = memory.slot(Slot::SpaceCreation);
            let original = retained.as_ref().map(|b| {
                canonical::parse(b).unwrap().as_object().unwrap()["request"]
                    .as_text()
                    .unwrap()
                    .to_owned()
            });
            drop(store);
            let mut restarted = Store::load(temp.path(), memory.clone()).unwrap();
            create(&mut restarted, &mut remote, &live).unwrap();
            assert_eq!(remote.creations, 1);
            assert!(
                remote
                    .requests
                    .iter()
                    .all(|id| original.as_ref().is_none_or(|old| *old == id.to_string()))
            );
            assert_eq!(
                remote.requests.len(),
                if write == 2 && !after { 2 } else { 1 }
            );
        }
    }
}
#[test]
fn retained_receipt_never_reposts_after_observation_or_post_preflight_failure() {
    for changed in [false, true] {
        let (_temp, mut store, _memory, live, mut remote) = fixture();
        remote.fail_observe = !changed;
        remote.change_after_post = changed;
        assert!(create(&mut store, &mut remote, &live).is_err());
        assert_eq!(remote.requests.len(), 1);
        assert!(status(&mut store, &live) == Ok(State::Created));
        remote.fail_observe = false;
        remote.change_after_post = false;
        create(&mut store, &mut remote, &live).unwrap();
        assert_eq!(remote.requests.len(), 1);
    }
}
#[test]
fn account_server_instance_stale_session_and_pending_lineage_stop_before_http() {
    let (_temp, mut store, memory, live, mut remote) = fixture();
    remote.lose_reply = true;
    create(&mut store, &mut remote, &live).err().unwrap();
    let before = memory.slot(Slot::SpaceCreation).unwrap();
    let calls = remote.preflights;
    let other = install(&mut store, deployment(), "other", "public-other-account");
    assert!(create(&mut store, &mut remote, &other).err() == Some(Failure::ReviewRequired));
    assert_eq!(remote.preflights, calls);
    assert!(memory.slot(Slot::SpaceCreation).unwrap().as_slice() == before.as_slice());
    let renewed = install(&mut store, deployment(), "correct-again", "public-creator");
    assert!(
        create(&mut store, &mut remote, &live).err()
            == Some(Failure::Account(super::super::Failure::Stale))
    );
    for changed in 0..2 {
        let saved = remote.deployment.clone();
        if changed == 0 {
            remote.deployment.server =
                cloud::ServerURL::parse("https://foreign.example.test").unwrap();
        } else {
            remote.deployment.instance = Uuid::from_u128(99);
        }
        assert!(create(&mut store, &mut remote, &renewed).err() == Some(Failure::ReviewRequired));
        remote.deployment = saved;
    }
    store
        .transaction_with::<_, super::super::Failure>(|owner| {
            let mut a = Archive::load(owner)?;
            a.begin(Replacement::Refresh, deployment())?;
            a.save(owner)
        })
        .unwrap();
    assert!(
        create(&mut store, &mut remote, &renewed).err()
            == Some(Failure::Account(super::super::Failure::Busy))
    );
    assert_eq!(remote.preflights, calls);
}
#[test]
fn receipt_pins_dataset_membership_and_key_epoch_but_allows_feed_and_role_changes() {
    let (_temp, mut store, memory, live, mut remote) = fixture();
    create(&mut store, &mut remote, &live).unwrap();
    let original = memory.slot(Slot::SpaceCreation).unwrap();
    for space in [
        descriptor(55, 44, 5, 1, "owner"),
        descriptor(33, 44, 9, 1, "owner"),
        descriptor(33, 44, 5, 2, "owner"),
    ] {
        remote.observed = space;
        assert!(create(&mut store, &mut remote, &live).err() == Some(Failure::ReviewRequired));
        let binding = remote.observed.key_binding(&deployment()).unwrap();
        assert!(
            key_store::check_admission(&mut store, &binding)
                == Err(key_store::Failure::ReviewRequired)
        );
        assert!(memory.slot(Slot::SpaceCreation).unwrap().as_slice() == original.as_slice());
    }
    remote.observed = descriptor(33, 66, 5, 1, "reader");
    let observed = create(&mut store, &mut remote, &live).unwrap();
    assert!(observed.role == Role::Reader);
    assert_eq!(remote.requests.len(), 1);
}
#[test]
fn existing_key_recipient_bootstrap_checkpoint_and_primary_intent_are_preserved() {
    for slot in [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::PairingRecipient,
        Slot::CheckpointKey,
        Slot::KeyMutation,
    ] {
        let (_temp, mut store, memory, live, mut remote) = fixture();
        store
            .transaction(|o| o.replace(slot, None, Some(b"public retained state")))
            .unwrap();
        assert!(status(&mut store, &live) == Ok(State::ExistingLibrary));
        assert!(create(&mut store, &mut remote, &live).err() == Some(Failure::ExistingLibrary));
        assert!(
            memory.slot(slot).unwrap().as_slice() == b"public retained state"
                && memory.slot(Slot::SpaceCreation).is_none()
        );
        assert_eq!(remote.preflights, 0);
    }
    for file in ["Sync/journal.bin", "Sync/primary.pending"] {
        let (temp, mut store, memory, live, mut remote) = fixture();
        let path = temp.path().join(file);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"public retained encrypted intent").unwrap();
        assert!(create(&mut store, &mut remote, &live).err() == Some(Failure::ExistingLibrary));
        assert!(
            std::fs::read(&path).unwrap() == b"public retained encrypted intent"
                && memory.slot(Slot::SpaceCreation).is_none()
        );
        assert_eq!(remote.preflights, 0);
    }
}
#[test]
fn unowned_creation_reply_or_changed_deployment_cannot_publish_a_receipt() {
    for role in ["writer", "reader"] {
        let (_temp, mut store, memory, live, mut remote) = fixture();
        remote.post_role = role;
        assert!(create(&mut store, &mut remote, &live).err() == Some(Failure::ReviewRequired));
        let bytes = memory.slot(Slot::SpaceCreation).unwrap();
        assert!(matches!(
            canonical::parse(&bytes).unwrap().as_object().unwrap()["created"],
            Value::Null
        ));
    }
    let (_temp, mut store, memory, live, mut remote) = fixture();
    remote.actual = Uuid::from_u128(99);
    assert!(
        create(&mut store, &mut remote, &live).err()
            == Some(Failure::Cloud(cloud::Failure::AccountReview))
    );
    assert!(remote.requests.is_empty() && memory.slot(Slot::SpaceCreation).is_some());
}
#[test]
fn locked_storage_and_both_expiry_clocks_stop_before_intent_or_http() {
    for clock in 0..3 {
        let (_temp, mut store, memory, mut live, mut remote) = fixture();
        let expected = match clock {
            0 => {
                memory.0.lock().unwrap().locked = true;
                Failure::Secret(secret_store::Failure::Locked)
            }
            1 => {
                live.monotonic_deadline = Duration::ZERO;
                Failure::Account(super::super::Failure::Expired)
            }
            _ => {
                live.wall_deadline = SystemTime::UNIX_EPOCH;
                Failure::Account(super::super::Failure::Expired)
            }
        };
        assert!(create(&mut store, &mut remote, &live).err() == Some(expected));
        assert!(memory.slot(Slot::SpaceCreation).is_none() && remote.requests.is_empty());
    }
}
#[test]
fn expiration_during_post_retains_the_created_space_for_reconnect_without_reposting() {
    let (_temp, mut store, memory, mut live, mut remote) = fixture();
    live.wall_deadline = SystemTime::now() + Duration::from_secs(1);
    remote.wait_until = Some(live.wall_deadline);
    assert!(
        create(&mut store, &mut remote, &live).err()
            == Some(Failure::Account(super::super::Failure::Expired))
    );
    let bytes = memory.slot(Slot::SpaceCreation).unwrap();
    assert!(!matches!(
        canonical::parse(&bytes).unwrap().as_object().unwrap()["created"],
        Value::Null
    ));
    let renewed = install(&mut store, deployment(), "after-expiry", "public-creator");
    create(&mut store, &mut remote, &renewed).unwrap();
    assert_eq!(remote.requests.len(), 1);
}
#[test]
fn nil_idempotency_is_rejected_without_using_the_http_agent() {
    let client = CloudClient::test_with_agent(
        deployment().server.clone(),
        ureq::Agent::new_with_defaults(),
        deployment().instance,
    );
    let token = Credential::new("public-fixture-credential".into()).unwrap();
    assert!(
        client.create_space(&token, Uuid::nil()).err() == Some(cloud::Failure::InvalidResponse)
    );
}

#[test]
fn journal_schema_refuses_unknown_mixed_and_foreign_receipts_before_http() {
    let (_temp, mut store, memory, live, mut remote) = fixture();
    create(&mut store, &mut remote, &live).unwrap();
    let original = memory.slot(Slot::SpaceCreation).unwrap();
    let saved = serde_json::from_slice::<serde_json::Value>(&original).unwrap();
    let calls = remote.preflights;
    for change in 0..12 {
        let mut value = saved.clone();
        match change {
            0 => value["schema"] = serde_json::json!(2),
            1 => value["extra"] = serde_json::json!(true),
            2 => value["request"] = serde_json::json!(Uuid::nil().to_string()),
            3 => value["request"] = serde_json::json!("7B28D156-77FD-4F7F-BDF3-234F7D97AC91"),
            4 => value["account"]["identity"] = serde_json::json!(""),
            5 => {
                value["account"]["deployment"]["server"] =
                    serde_json::json!("https://creation.example.test/")
            }
            6 => value["created"]["instance"] = serde_json::json!(Uuid::from_u128(99).to_string()),
            7 => value["created"]["server"] = serde_json::json!("https://foreign.example.test"),
            8 => value["created"]["membership"] = serde_json::json!("AA=="),
            9 => value["created"]["epoch"] = serde_json::json!(0),
            10 => value["created"]["space"] = serde_json::json!(Uuid::nil().to_string()),
            _ => value["created"]["unexpected"] = serde_json::json!("public mixed fixture"),
        }
        let corrupt = serde_json::to_vec(&value).unwrap();
        store
            .transaction(|o| o.replace(Slot::SpaceCreation, Some(&original), Some(&corrupt)))
            .unwrap();
        assert!(create(&mut store, &mut remote, &live).is_err());
        assert_eq!(remote.preflights, calls);
        assert!(memory.slot(Slot::SpaceCreation).unwrap().as_slice() == corrupt.as_slice());
        store
            .transaction(|o| o.replace(Slot::SpaceCreation, Some(&corrupt), Some(&original)))
            .unwrap();
    }
}
#[test]
fn live_deployment_stamp_and_completed_receipt_guard_all_later_key_admission() {
    let (_temp, mut store, memory, mut live, mut remote) = fixture();
    live.deployment.instance = Uuid::from_u128(99);
    assert!(
        create(&mut store, &mut remote, &live).err()
            == Some(Failure::Account(super::super::Failure::Stale))
    );
    assert!(memory.slot(Slot::SpaceCreation).is_none() && remote.requests.is_empty());
    live.deployment = deployment();
    let space = create(&mut store, &mut remote, &live).unwrap();
    let pin = space.key_binding(&deployment()).unwrap();
    key_store::check_admission(&mut store, &pin).unwrap();
    let renewed = install(
        &mut store,
        deployment(),
        "different-account",
        "public-other-account",
    );
    assert!(
        key_store::check_admission(&mut store, &pin) == Err(key_store::Failure::ReviewRequired)
    );
    assert!(status(&mut store, &renewed) == Err(Failure::ReviewRequired));
    assert!(memory.slot(Slot::LibraryKey).is_none());
}
#[test]
fn linked_sync_directory_cannot_be_used_as_an_empty_library() {
    let (temp, mut store, memory, live, mut remote) = fixture();
    let outside = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), temp.path().join("Sync")).unwrap();
    assert!(create(&mut store, &mut remote, &live).is_err());
    assert!(memory.slot(Slot::SpaceCreation).is_none() && remote.requests.is_empty());
    assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 0);
}

fn seed_existing(store: &mut Store<Memory>) -> KeyBinding {
    let binding = descriptor_at(90, 91, 92, 8, 1, "owner")
        .key_binding(&deployment())
        .unwrap();
    let bundle = crate::bootstrap::Bundle::from_material(&[71; 64]).unwrap();
    let bytes = object([
        ("schema", Value::Int(1)),
        ("binding", binding.value()),
        (
            "bundle",
            canonical::parse(&bundle.encode_secret().unwrap()).unwrap(),
        ),
    ])
    .encode()
    .unwrap();
    store
        .transaction(|owner| {
            owner.replace(Slot::LibraryKey, None, Some(&bytes))?;
            owner.replace(Slot::CheckpointKey, None, Some(&[74; 64]))
        })
        .unwrap();
    binding
}
fn prepare(store: &mut Store<Memory>, live: &LiveSession) -> Result<NewIntent> {
    store.transaction_with(|owner| prepare_new_locked(owner, &deployment(), live))
}
fn begin(
    store: &mut Store<Memory>,
    remote: &mut FakeRemote,
    live: &LiveSession,
    intent: NewIntent,
) -> Result<Space> {
    store.transaction_with(|owner| create_mode(owner, remote, live, Some(intent)))
}
fn advance(remote: &mut FakeRemote, id: u128) {
    remote.next_id = id;
    remote.observed = descriptor_at(id, 33, 44, 5, 1, "owner");
}
fn entries(memory: &Memory) -> Vec<serde_json::Value> {
    let value: serde_json::Value =
        serde_json::from_slice(&memory.slot(Slot::SpaceCreation).unwrap()).unwrap();
    if value["schema"] == 1 {
        vec![value]
    } else {
        value["entries"].as_array().unwrap().clone()
    }
}

#[test]
fn new_metadata_preserves_existing_keys_checkpoint_and_unread_primary_intent() {
    let (temp, mut store, memory, live, mut remote) = fixture();
    let source = seed_existing(&mut store);
    std::fs::create_dir(temp.path().join("Sync")).unwrap();
    std::fs::write(
        temp.path().join("snippets.json"),
        b"Public primary beforeimage",
    )
    .unwrap();
    std::fs::write(
        temp.path().join("Sync/journal.bin"),
        b"Public encrypted journal beforeimage",
    )
    .unwrap();
    let old: Vec<_> = PRESERVED.iter().map(|slot| memory.slot(*slot)).collect();
    let writes = memory.0.lock().unwrap().writes;
    let proposal = prepare(&mut store, &live).unwrap();
    assert_eq!(proposal.retained(), 0);
    assert_eq!(memory.0.lock().unwrap().writes, writes);
    assert!(memory.slot(Slot::SpaceCreation).is_none() && remote.requests.is_empty());
    remote.lose_reply = true;
    assert!(begin(&mut store, &mut remote, &live, proposal).is_err());
    assert!(status(&mut store, &live) == Ok(State::Requested));
    key_store::check_admission(&mut store, &source).unwrap();
    assert!(prepare(&mut store, &live).err() == Some(Failure::RetentionFull));
    let created = create(&mut store, &mut remote, &live)
        .unwrap()
        .key_binding(&deployment())
        .unwrap();
    assert!(status(&mut store, &live) == Ok(State::Created));
    key_store::check_admission(&mut store, &source).unwrap();
    assert!(
        key_store::check_admission(&mut store, &created) == Err(key_store::Failure::ReviewRequired)
    );
    for (slot, before) in PRESERVED.iter().zip(old) {
        assert!(memory.slot(*slot) == before);
    }
    assert_eq!(
        std::fs::read(temp.path().join("snippets.json")).unwrap(),
        b"Public primary beforeimage"
    );
    assert_eq!(
        std::fs::read(temp.path().join("Sync/journal.bin")).unwrap(),
        b"Public encrypted journal beforeimage"
    );
    assert_eq!(remote.requests[0], remote.requests[1]);
}

#[test]
fn legacy_migration_retains_all_receipts_and_open_does_not_create_another_library() {
    let (_temp, mut store, memory, live, mut remote) = fixture();
    create(&mut store, &mut remote, &live).unwrap();
    let original = entries(&memory).remove(0);
    for id in 23..=25 {
        advance(&mut remote, id);
        let proposal = prepare(&mut store, &live).unwrap();
        assert_eq!(proposal.retained(), (id - 22) as usize);
        begin(&mut store, &mut remote, &live, proposal).unwrap();
        create(&mut store, &mut remote, &live).unwrap();
    }
    let history = entries(&memory);
    assert_eq!(history.len(), 4);
    assert_eq!(history[0]["request"], original["request"]);
    assert_eq!(history[0]["account"], original["account"]);
    assert_eq!(history[0]["created"], original["created"]);
    assert_eq!(remote.requests.len(), 4);
    assert_eq!(remote.creations, 4);
    for space in history {
        let pin = KeyBinding::parse(
            &canonical::parse(&serde_json::to_vec(&space["created"]).unwrap()).unwrap(),
        )
        .unwrap();
        key_store::check_admission(&mut store, &pin).unwrap();
    }
}

#[test]
fn modern_request_and_receipt_faults_resume_after_restart_with_original_request() {
    for write in 1..=2 {
        for after in [false, true] {
            let (temp, mut store, memory, live, mut remote) = fixture();
            create(&mut store, &mut remote, &live).unwrap();
            let original = entries(&memory).remove(0);
            advance(&mut remote, 23);
            let proposal = prepare(&mut store, &live).unwrap();
            let request = proposal.request;
            memory.fault_after(write, after);
            assert!(
                begin(&mut store, &mut remote, &live, proposal).err()
                    == Some(Failure::Secret(secret_store::Failure::Unavailable))
            );
            drop(store);
            let mut restarted = Store::load(temp.path(), memory.clone()).unwrap();
            if write == 1 && !after {
                assert_eq!(entries(&memory).len(), 1);
                let retry = prepare(&mut restarted, &live).unwrap();
                begin(&mut restarted, &mut remote, &live, retry).unwrap();
            } else {
                create(&mut restarted, &mut remote, &live).unwrap();
                assert!(remote.requests[1..].iter().all(|id| *id == request));
            }
            assert_eq!(entries(&memory).len(), 2);
            assert_eq!(entries(&memory)[0]["request"], original["request"]);
            assert_eq!(remote.creations, 2);
        }
    }
}

#[test]
fn exact_proposal_refuses_changed_protected_slots_account_session_and_clocks_before_post() {
    for change in 0..12 {
        let (_temp, mut store, memory, mut live, mut remote) = fixture();
        seed_existing(&mut store);
        let mut proposal = prepare(&mut store, &live).unwrap();
        match change {
            0..=4 => {
                let slot = *PRESERVED.get(change).unwrap();
                let old = memory.slot(slot);
                store
                    .transaction(|owner| {
                        owner.replace(
                            slot,
                            old.as_deref().map(Vec::as_slice),
                            Some(b"Public changed capability"),
                        )
                    })
                    .unwrap();
            }
            5 => {
                live = install(
                    &mut store,
                    deployment(),
                    "different-account",
                    "public-another",
                );
            }
            6 => {
                live = install(
                    &mut store,
                    deployment(),
                    "different-session",
                    "public-creator",
                );
            }
            7 => {
                proposal.wall = SystemTime::now() - Duration::from_secs(121);
            }
            8 => {
                proposal.wall = SystemTime::now() + Duration::from_secs(1);
            }
            9 => {
                proposal.started = crate::clock::uptime().unwrap() + Duration::from_secs(1);
            }
            11 => {
                let _renewed = install(
                    &mut store,
                    deployment(),
                    "replaced-old-session",
                    "public-creator",
                );
            }
            _ => {
                let other = prepare(&mut store, &live).unwrap();
                begin(&mut store, &mut remote, &live, other).unwrap();
            }
        }
        let before = memory.slot(Slot::SpaceCreation);
        let writes = memory.0.lock().unwrap().writes;
        let calls = remote.requests.len();
        assert!(begin(&mut store, &mut remote, &live, proposal).is_err());
        assert_eq!(remote.requests.len(), calls);
        assert_eq!(memory.0.lock().unwrap().writes, writes);
        assert!(memory.slot(Slot::SpaceCreation) == before);
    }
}

#[test]
fn new_current_account_can_create_without_reusing_or_discarding_foreign_intents() {
    let (_temp, mut store, memory, live, mut remote) = fixture();
    remote.lose_reply = true;
    create(&mut store, &mut remote, &live).err().unwrap();
    let original = entries(&memory).remove(0);
    let other = install(&mut store, deployment(), "new-account", "public-other");
    assert!(status(&mut store, &other) == Err(Failure::ReviewRequired));
    assert!(create(&mut store, &mut remote, &other).err() == Some(Failure::ReviewRequired));
    advance(&mut remote, 23);
    let proposal = prepare(&mut store, &other).unwrap();
    begin(&mut store, &mut remote, &other, proposal).unwrap();
    assert_eq!(entries(&memory)[0]["request"], original["request"]);
    assert!(entries(&memory)[0]["created"].is_null());
    assert_eq!(remote.creations, 2);
    let renewed = install(
        &mut store,
        deployment(),
        "original-returned",
        "public-creator",
    );
    advance(&mut remote, 22);
    create(&mut store, &mut remote, &renewed).unwrap();
    assert_eq!(remote.requests[0], remote.requests[2]);
    assert_eq!(entries(&memory).len(), 2);
}

#[test]
fn capacity_and_generation_refuse_new_requests_without_discarding_history() {
    let (_temp, mut store, memory, live, mut remote) = fixture();
    for id in 22..22 + MAX_ENTRIES as u128 {
        advance(&mut remote, id);
        let proposal = prepare(&mut store, &live).unwrap();
        begin(&mut store, &mut remote, &live, proposal).unwrap();
    }
    let old = memory.slot(Slot::SpaceCreation).unwrap();
    assert!(prepare(&mut store, &live).err() == Some(Failure::RetentionFull));
    create(&mut store, &mut remote, &live).unwrap();
    assert!(memory.slot(Slot::SpaceCreation).unwrap() == old);
    assert_eq!(remote.requests.len(), MAX_ENTRIES);
    let mut value: serde_json::Value = serde_json::from_slice(&old).unwrap();
    value["entries"].as_array_mut().unwrap().truncate(1);
    for generation in [i64::MAX - 1, i64::MAX] {
        value["generation"] = serde_json::json!(generation);
        let changed = serde_json::to_vec(&value).unwrap();
        let current = memory.slot(Slot::SpaceCreation).unwrap();
        store
            .transaction(|owner| owner.replace(Slot::SpaceCreation, Some(&current), Some(&changed)))
            .unwrap();
        assert!(prepare(&mut store, &live).err() == Some(Failure::RetentionFull));
        assert!(memory.slot(Slot::SpaceCreation).unwrap().as_slice() == changed.as_slice());
    }
}

#[test]
fn schema_two_refuses_duplicate_mixed_and_oversize_intents_before_http() {
    let (_temp, mut store, memory, live, mut remote) = fixture();
    let proposal = prepare(&mut store, &live).unwrap();
    begin(&mut store, &mut remote, &live, proposal).unwrap();
    let old = memory.slot(Slot::SpaceCreation).unwrap();
    let saved: serde_json::Value = serde_json::from_slice(&old).unwrap();
    for change in 0..10 {
        let mut value = saved.clone();
        match change {
            0 => value["generation"] = serde_json::json!(0),
            1 => value["extra"] = serde_json::json!(true),
            2 => value["entries"] = serde_json::json!([]),
            3 => value["entries"][0]["extra"] = serde_json::json!(true),
            4 => {
                let entry = value["entries"][0].clone();
                value["entries"].as_array_mut().unwrap().push(entry);
            }
            5 => value["entries"][0]["source"] = value["entries"][0]["created"].clone(),
            6 => {
                value["entries"][0]["account"]["identity"] =
                    serde_json::json!("X".repeat(MAX_BYTES))
            }
            7 => {
                let mut entry = value["entries"][0].clone();
                entry["request"] = serde_json::json!(Uuid::new_v4().to_string());
                value["entries"].as_array_mut().unwrap().push(entry);
            }
            8 => {
                value["entries"][0]["created"] = serde_json::Value::Null;
                let mut entry = value["entries"][0].clone();
                entry["request"] = serde_json::json!(Uuid::new_v4().to_string());
                value["entries"].as_array_mut().unwrap().push(entry);
            }
            _ => value["schema"] = serde_json::json!(3),
        }
        let changed = serde_json::to_vec(&value).unwrap();
        store
            .transaction(|owner| owner.replace(Slot::SpaceCreation, Some(&old), Some(&changed)))
            .unwrap();
        let calls = remote.preflights;
        assert!(create(&mut store, &mut remote, &live).is_err());
        assert!(prepare(&mut store, &live).is_err());
        assert_eq!(remote.preflights, calls);
        store
            .transaction(|owner| owner.replace(Slot::SpaceCreation, Some(&changed), Some(&old)))
            .unwrap();
    }
}

#[test]
fn changing_protected_source_or_history_during_http_cannot_publish_stale_metadata() {
    for slot in [Slot::LibraryKey, Slot::CheckpointKey, Slot::SpaceCreation] {
        for phase in 0..3 {
            let (_temp, mut store, memory, live, mut remote) = fixture();
            seed_existing(&mut store);
            let proposal = prepare(&mut store, &live).unwrap();
            match phase {
                0 => remote.mutate_preflight = Some((1, slot)),
                1 => remote.mutate_post = Some(slot),
                _ => remote.mutate_observe = Some(slot),
            }
            assert!(begin(&mut store, &mut remote, &live, proposal).is_err());
            assert_eq!(remote.requests.len(), usize::from(phase != 0));
            let retained = entries(&memory);
            // A response is retained before source validation; a changed
            // creation archive itself refuses CAS instead of overwriting it.
            assert_eq!(
                retained[0]["created"].is_null(),
                phase == 0 || phase == 1 && slot == Slot::SpaceCreation
            );
        }
    }
}

#[test]
fn an_existing_source_or_retained_target_cannot_be_reported_as_a_new_creation() {
    for with_source in [false, true] {
        let (_temp, mut store, memory, live, mut remote) = fixture();
        if with_source {
            seed_existing(&mut store);
            advance(&mut remote, 90);
        } else {
            create(&mut store, &mut remote, &live).unwrap();
        }
        let proposal = prepare(&mut store, &live).unwrap();
        assert!(
            begin(&mut store, &mut remote, &live, proposal).err() == Some(Failure::ReviewRequired)
        );
        assert!(entries(&memory).last().unwrap()["created"].is_null());
    }
}

#[test]
fn creation_consent_expiring_during_preflight_stops_post_and_during_post_retains_receipt() {
    for during_post in [false, true] {
        let (_temp, mut store, memory, live, mut remote) = fixture();
        let mut proposal = prepare(&mut store, &live).unwrap();
        proposal.wall = SystemTime::now() - Duration::from_secs(119);
        let until = SystemTime::now() + Duration::from_millis(1100);
        if during_post {
            remote.wait_until = Some(until);
        } else {
            remote.wait_preflight = Some(until);
        }
        assert!(
            begin(&mut store, &mut remote, &live, proposal).err() == Some(Failure::ReviewRequired)
        );
        assert_eq!(remote.requests.len(), usize::from(during_post));
        assert_eq!(entries(&memory)[0]["created"].is_null(), !during_post);
        create(&mut store, &mut remote, &live).unwrap();
        assert_eq!(remote.requests.len(), 1);
    }
}
