//! Temporary roots, fictional peers and fault-injected Secret Service values.
use super::*;
use crate::{
    cloud::{Pairing, PairingState},
    key_store::tests::{FakeRemote, Memory},
};
use std::sync::{Arc, Mutex};

#[derive(Clone)]
struct Faults {
    memory: Memory,
    state: Arc<Mutex<FaultState>>,
}
#[derive(Default)]
struct FaultState {
    writes: usize,
    fail: Option<(usize, bool)>,
}
impl Faults {
    fn arm(&self, n: usize, after: bool) {
        *self.state.lock().unwrap() = FaultState {
            writes: 0,
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
        let fault = if slot == Slot::PairingCandidate {
            let mut state = self.state.lock().unwrap();
            state.writes += 1;
            state
                .fail
                .filter(|(n, _)| *n == state.writes)
                .map(|(_, after)| after)
        } else {
            None
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
    bundle: Bundle,
    invitation: Option<Invitation>,
    cipher: Option<Vec<u8>>,
    creates: usize,
    polls: usize,
    claims: usize,
    cancels: usize,
    lose_create: bool,
    change_claim: bool,
    expired: bool,
}
fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
impl Peer {
    fn approve(&mut self) {
        self.cipher = Some(
            bootstrap::seal_pairing(&self.bundle, self.invitation.as_ref().unwrap(), now())
                .unwrap(),
        );
    }
}
impl super::super::Remote for Peer {
    fn preflight(&mut self) -> super::super::Result<()> {
        self.core.preflight()
    }
    fn binding(&self) -> super::super::Result<KeyBinding> {
        self.core.binding()
    }
    fn role(&self) -> Role {
        self.core.role()
    }
    fn authority(&mut self) -> super::super::Result<Option<[u8; 32]>> {
        self.core.authority()
    }
    fn recovery(&mut self) -> super::super::Result<Option<Evidence>> {
        self.core.recovery()
    }
    fn has_records(&mut self) -> super::super::Result<bool> {
        self.core.has_records()
    }
    fn bootstrap(&mut self, _: &[u8; 32], _: &[u8]) -> super::super::Result<Evidence> {
        panic!("candidate pairing cannot bootstrap")
    }
}
impl Remote for Peer {
    fn create(&mut self, draft: &PairingDraft) -> super::super::Result<Pairing> {
        self.creates += 1;
        assert!(self.memory.slot(Slot::LibraryKey).is_some());
        let bytes = self.memory.slot(Slot::PairingCandidate).unwrap();
        let value = canonical::parse(&bytes).unwrap();
        let entry = value.as_object().unwrap()["entries"]
            .as_array()
            .unwrap()
            .last()
            .unwrap();
        let phase = &entry.as_object().unwrap()["phase"];
        let Phase::Creating {
            draft: saved,
            sent: true,
        } = Phase::parse(phase).unwrap()
        else {
            panic!("draft must be retained before POST");
        };
        assert!(saved.public_key() == draft.public_key() && saved.nonce() == draft.nonce());
        let invitation = Invitation::new(
            self.core.pin.server.clone(),
            self.core.pin.space,
            Uuid::from_u128(100 + self.creates as u128),
            *draft.nonce(),
            *draft.public_key(),
            now() + 300,
            now(),
        )
        .unwrap();
        self.invitation = Some(invitation.clone());
        self.cipher = None;
        if self.lose_create {
            self.lose_create = false;
            return Err(Failure::Cloud(cloud::Failure::Network));
        }
        Ok(Pairing::test(invitation, PairingState::Pending))
    }
    fn poll(&mut self, invitation: &Invitation) -> super::super::Result<Pairing> {
        self.polls += 1;
        if self.expired {
            return Err(Failure::Cloud(cloud::Failure::Network));
        }
        assert!(self.invitation.as_ref() == Some(invitation));
        Ok(Pairing::test(
            invitation.clone(),
            if self.cipher.is_some() {
                PairingState::Approved
            } else {
                PairingState::Pending
            },
        ))
    }
    fn claim(&mut self, _: &Pairing) -> super::super::Result<Vec<u8>> {
        self.claims += 1;
        if self.change_claim {
            self.core.pin.dataset = Binding::from_checkpoint([99; 32]);
        }
        Ok(self.cipher.clone().unwrap())
    }
    fn cancel(&mut self, _: &Invitation) -> super::super::Result<()> {
        self.cancels += 1;
        Ok(())
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
        panic!("candidate never fetches data")
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
    let bundle = Bundle::generate().unwrap();
    core.public = Some(Authority::new(&bundle, &core.pin.context().unwrap()).public_key());
    let peer = Peer {
        core,
        memory,
        bundle,
        invitation: None,
        cipher: None,
        creates: 0,
        polls: 0,
        claims: 0,
        cancels: 0,
        lose_create: false,
        change_claim: false,
        expired: false,
    };
    (temp, store, backend, peer)
}
fn operate(store: &mut Store<Faults>, peer: &mut Peer, action: Action) -> Result<Status> {
    store.transaction_with(|owner| operate_locked(owner, peer, action, &|_| Ok(())))
}
#[test]
fn catalogue_authenticates_claimed_keys_without_polling_or_exposing_invitations() {
    use crate::key_store::history::{self, PairingPhase};
    for kind in 0..4 {
        let (temp, mut store, backend, mut peer) = setup();
        let old = backend.memory.slot(Slot::LibraryKey);
        operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
        let expected = match kind {
            0 => PairingPhase::Waiting,
            1 => {
                peer.approve();
                peer.change_claim = true;
                assert!(operate(&mut store, &mut peer, Action::Check).is_err());
                PairingPhase::Claimed
            }
            2 => {
                peer.approve();
                operate(&mut store, &mut peer, Action::Check).ok().unwrap();
                PairingPhase::Ready
            }
            3 => {
                operate(&mut store, &mut peer, Action::Cancel).ok().unwrap();
                PairingPhase::Cancelled
            }
            _ => unreachable!(),
        };
        peer.expired = true;
        let frame = backend.memory.slot(Slot::PairingCandidate).unwrap();
        let traffic = (peer.creates, peer.polls, peer.claims, peer.cancels);
        let catalog = history::inspect(&mut store).unwrap();
        assert_eq!(catalog.pairing.len(), 1);
        assert_eq!(catalog.pairing[0].phase, expected);
        assert_eq!(catalog.usage.pairing, frame.len());
        assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&frame));
        assert!(backend.memory.slot(Slot::LibraryKey) == old);
        assert!(!temp.path().join("Sync").exists());
        assert_eq!(
            (peer.creates, peer.polls, peer.claims, peer.cancels),
            traffic
        );
    }
}
fn ready(store: &mut Store<Faults>, peer: &mut Peer) {
    assert!(matches!(
        operate(store, peer, Action::Begin),
        Ok(Status::Waiting {
            received: false,
            ..
        })
    ));
    peer.approve();
    assert!(matches!(
        operate(store, peer, Action::Check),
        Ok(Status::Ready)
    ));
}
fn reviewed_activation(store: &mut Store<Faults>, peer: &mut Peer) {
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, peer, None, &|_| Ok(())))
        .unwrap();
    assert!(review.reuses_local_key());
    let mut gate = crate::local_auth::Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(
            review.authorization_target().unwrap(),
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )
        .unwrap();
    let permit = gate
        .accept(crate::local_auth::authenticate_fixture(request).unwrap())
        .unwrap();
    assert!(
        store
            .transaction_with(|owner| handover::commit_authorized_locked(
                owner,
                peer,
                review,
                permit,
                &|_| Ok(())
            ))
            .unwrap()
            == Outcome::Ready {
                kit: KitStatus::None
            }
    );
}
#[test]
fn received_candidate_after_pin_epoch_or_account_changes_requires_fresh_review_and_keeps_original_proof()
 {
    use crate::auth_store::{Deployment, creation::tests::install};
    for mode in 0..4 {
        let (_temp, mut store, backend, mut peer) = setup();
        let deployment =
            Deployment::from_discovery(peer.core.pin.server.clone(), peer.core.pin.instance);
        let _first = install(
            &mut store,
            deployment.clone(),
            "review-pair-old",
            "public-old-pair-account",
        );
        if mode % 2 == 0 {
            ready(&mut store, &mut peer);
        } else {
            assert!(operate(&mut store, &mut peer, Action::Begin).is_ok());
            peer.approve();
            peer.change_claim = true;
            assert!(operate(&mut store, &mut peer, Action::Check).is_err());
        }
        let original = backend.memory.slot(Slot::PairingCandidate).unwrap();
        if mode >= 2 {
            let _next = install(
                &mut store,
                deployment,
                "review-pair-new",
                "public-new-pair-account",
            );
            peer.core.pin.epoch += 1;
        }
        peer.core.pin.membership = Binding::from_checkpoint([67; 32]);
        peer.core.pin.dataset = Binding::from_checkpoint([68; 32]);
        peer.expired = true;
        assert!(!matches!(
            inspect(&mut store, &peer.core.pin),
            Ok(Some(Status::Ready))
        ));
        assert!(operate(&mut store, &mut peer, Action::Check).is_err());
        assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&original));
        reviewed_activation(&mut store, &mut peer);
        let original = canonical::parse(&original).unwrap();
        let current =
            canonical::parse(&backend.memory.slot(Slot::PairingCandidate).unwrap()).unwrap();
        let original = original.as_object().unwrap()["entries"].as_array().unwrap()[0]
            .as_object()
            .unwrap();
        let current = current.as_object().unwrap()["entries"].as_array().unwrap()[0]
            .as_object()
            .unwrap();
        for field in ["binding", "account", "phase", "cancelled"] {
            assert!(original[field].encode().unwrap() == current[field].encode().unwrap());
        }
        assert!(current["ready"].as_bool().unwrap());
        assert!(!handover::inspect(&mut store).unwrap().pending);
        assert_eq!((peer.creates, peer.polls, peer.claims), (1, 1, 1));
    }
}
#[test]
fn unclaimed_pairing_drafts_never_supply_keys_to_a_changed_target_review() {
    for lose_creation in [false, true] {
        let (temp, mut store, backend, mut peer) = setup();
        peer.lose_create = lose_creation;
        let _ = operate(&mut store, &mut peer, Action::Begin);
        let original = backend.memory.slot(Slot::PairingCandidate).unwrap();
        peer.core.pin.dataset = Binding::from_checkpoint([69; 32]);
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
        assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&original));
        assert!(
            backend.memory.slot(Slot::AccountReview).is_none()
                && !temp.path().join("Sync").exists()
        );
        assert_eq!(peer.claims, 0);
    }
}
#[test]
fn claimed_candidate_completion_failures_keep_activation_pending_and_resume_without_reclaiming() {
    for after in [false, true] {
        let (temp, mut store, backend, mut peer) = setup();
        assert!(operate(&mut store, &mut peer, Action::Begin).is_ok());
        peer.approve();
        peer.change_claim = true;
        assert!(operate(&mut store, &mut peer, Action::Check).is_err());
        let review = store
            .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())))
            .unwrap();
        let mut gate = crate::local_auth::Gate::new();
        gate.set_foreground(true);
        let request = gate
            .begin(
                review.authorization_target().unwrap(),
                crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
            )
            .unwrap();
        let permit = gate
            .accept(crate::local_auth::authenticate_fixture(request).unwrap())
            .unwrap();
        backend.arm(1, after);
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
        assert!(store.transaction_with(handover::require_idle).is_err());
        let published = std::fs::read(temp.path().join("Sync/journal.bin")).unwrap();
        let mut reopened = Store::load(temp.path(), backend.clone()).unwrap();
        let target = handover::prepare_resume_authorization(&mut reopened).unwrap();
        let request = gate
            .begin(
                target,
                crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
            )
            .unwrap();
        let permit = gate
            .accept(crate::local_auth::authenticate_fixture(request).unwrap())
            .unwrap();
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
                    kit: KitStatus::None
                }
        );
        assert!(!handover::inspect(&mut reopened).unwrap().pending);
        assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == published);
        assert_eq!((peer.creates, peer.polls, peer.claims), (1, 1, 1));
    }
}
#[test]
fn changing_pairing_history_revokes_prepared_consent_without_changing_old_active_keys() {
    let (temp, mut store, backend, mut peer) = setup();
    ready(&mut store, &mut peer);
    peer.core.pin.dataset = Binding::from_checkpoint([70; 32]);
    let old_key = backend.memory.slot(Slot::LibraryKey).unwrap();
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())))
        .unwrap();
    let original = backend.memory.slot(Slot::PairingCandidate).unwrap();
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
        .transaction(|owner| owner.replace(Slot::PairingCandidate, Some(&original), Some(&changed)))
        .unwrap();
    let mut gate = crate::local_auth::Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(
            review.authorization_target().unwrap(),
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )
        .unwrap();
    let permit = gate
        .accept(crate::local_auth::authenticate_fixture(request).unwrap())
        .unwrap();
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
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old_key));
    assert!(
        backend.memory.slot(Slot::AccountReview).is_none()
            && !temp.path().join("Sync/Reviews").exists()
    );
    reviewed_activation(&mut store, &mut peer);
}
#[test]
fn changed_authority_keeps_a_claimed_candidate_unfinished_for_a_later_explicit_review() {
    let (temp, mut store, backend, mut peer) = setup();
    assert!(operate(&mut store, &mut peer, Action::Begin).is_ok());
    peer.approve();
    peer.change_claim = true;
    assert!(operate(&mut store, &mut peer, Action::Check).is_err());
    let original = backend.memory.slot(Slot::PairingCandidate).unwrap();
    peer.core.public = Some([88; 32]);
    assert!(
        store
            .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())))
            .is_err()
    );
    assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&original));
    assert!(
        backend.memory.slot(Slot::AccountReview).is_none() && !temp.path().join("Sync").exists()
    );
    assert_eq!(peer.claims, 1);
}
#[test]
fn candidate_is_retained_without_installing_keys_or_creating_sync_and_enters_review() {
    let (temp, mut store, backend, mut peer) = setup();
    let old_key = backend.memory.slot(Slot::LibraryKey).unwrap();
    let old_bootstrap = backend.memory.slot(Slot::Bootstrap).unwrap();
    ready(&mut store, &mut peer);
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old_key));
    assert!(backend.memory.slot(Slot::Bootstrap).as_deref() == Some(&old_bootstrap));
    assert!(backend.memory.slot(Slot::CheckpointKey).is_none());
    assert!(!temp.path().join("Sync").exists() && !temp.path().join("Vault").exists());
    let bundle = store
        .transaction_with(|owner| retained_bundle(owner, &peer.core.pin))
        .unwrap()
        .unwrap();
    assert!(bundle.for_secure_storage() == peer.bundle.for_secure_storage());
    let review = store
        .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())))
        .unwrap();
    assert!(review.summary().local_records == 0);
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old_key));
    assert_eq!(peer.creates, 1);
    assert_eq!(peer.claims, 1);
    // Receiving the key alone granted no switch. Only this exact fresh local
    // authorization lets the normal handover owner publish and activate it.
    let target = review.authorization_target().unwrap();
    let mut gate = crate::local_auth::Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(
            target,
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )
        .unwrap();
    let permit = gate
        .accept(crate::local_auth::authenticate_fixture(request).unwrap())
        .unwrap();
    store
        .transaction_with(|owner| {
            handover::commit_authorized_locked(owner, &mut peer, review, permit, &|_| Ok(()))
        })
        .unwrap();
    let installed = Installed::decode(&backend.memory.slot(Slot::LibraryKey).unwrap()).unwrap();
    assert!(
        installed.binding == peer.core.pin
            && installed.bundle.for_secure_storage() == peer.bundle.for_secure_storage()
    );
    assert!(backend.memory.slot(Slot::PairingCandidate).is_some());
    assert!(!handover::inspect(&mut store).unwrap().pending);
}

#[test]
fn ready_flag_write_failure_reopens_retained_claim_without_new_network_claim() {
    for after in [false, true] {
        let (temp, mut store, backend, mut peer) = setup();
        operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
        peer.approve();
        backend.arm(2, after);
        let error = operate(&mut store, &mut peer, Action::Check).err().unwrap();
        assert!(error.unrecorded.is_none());
        peer.expired = true;
        let mut reopened = Store::load(temp.path(), backend).unwrap();
        assert!(matches!(
            operate(&mut reopened, &mut peer, Action::Check),
            Ok(Status::Ready)
        ));
        assert_eq!(peer.polls, 1);
        assert_eq!(peer.claims, 1);
    }
}
#[test]
fn invitation_and_claim_receipts_keep_ownership_before_and_after_lost_secret_write() {
    for claim in [false, true] {
        for after in [false, true] {
            let (_temp, mut store, backend, mut peer) = setup();
            if claim {
                operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
                peer.approve();
                backend.arm(1, after);
            } else {
                backend.arm(3, after);
            }
            let rejected = operate(
                &mut store,
                &mut peer,
                if claim { Action::Check } else { Action::Begin },
            )
            .err()
            .unwrap();
            assert!(rejected.failure == Failure::Secret(secret_store::Failure::Unavailable));
            let calls = (peer.creates, peer.polls, peer.claims);
            rejected
                .unrecorded
                .unwrap()
                .retain(&mut store)
                .ok()
                .unwrap();
            assert!((peer.creates, peer.polls, peer.claims) == calls);
            let state = inspect(&mut store, &peer.core.pin).unwrap().unwrap();
            assert!(matches!(state, Status::Waiting {received,..} if received == claim));
            if claim {
                peer.expired = true;
                assert!(matches!(
                    operate(&mut store, &mut peer, Action::Check),
                    Ok(Status::Ready)
                ));
                assert_eq!(peer.claims, 1);
            }
        }
    }
}
#[test]
fn retained_claim_survives_scope_halt_and_restarts_without_polling_expired_invitation() {
    let (temp, mut store, backend, mut peer) = setup();
    operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
    peer.approve();
    let pin = peer.core.pin.clone();
    peer.change_claim = true;
    assert!(
        operate(&mut store, &mut peer, Action::Check)
            .err()
            .unwrap()
            .unrecorded
            .is_none()
    );
    peer.core.pin = pin;
    peer.expired = true;
    let mut reopened = Store::load(temp.path(), backend).unwrap();
    assert!(matches!(
        inspect(&mut reopened, &peer.core.pin),
        Ok(Some(Status::Waiting { received: true, .. }))
    ));
    assert!(
        operate(&mut reopened, &mut peer, Action::Cancel)
            .err()
            .unwrap()
            .failure
            == Failure::Busy
    );
    assert!(matches!(
        operate(&mut reopened, &mut peer, Action::Check),
        Ok(Status::Ready)
    ));
    assert_eq!(peer.polls, 1);
    assert_eq!(peer.claims, 1);
}
#[test]
fn lost_create_never_replays_and_explicit_cancellation_preserves_history() {
    let (_temp, mut store, backend, mut peer) = setup();
    peer.lose_create = true;
    assert!(operate(&mut store, &mut peer, Action::Begin).is_err());
    assert!(matches!(
        operate(&mut store, &mut peer, Action::Begin),
        Ok(Status::Creating)
    ));
    assert_eq!(peer.creates, 1);
    assert!(matches!(
        operate(&mut store, &mut peer, Action::Cancel),
        Ok(Status::Cancelled)
    ));
    assert!(matches!(
        operate(&mut store, &mut peer, Action::Begin),
        Ok(Status::Waiting { .. })
    ));
    let bytes = backend.memory.slot(Slot::PairingCandidate).unwrap();
    let value = canonical::parse(&bytes).unwrap();
    assert_eq!(
        value.as_object().unwrap()["entries"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(peer.creates, 2);
}
#[test]
fn wrong_authority_keeps_claim_for_review_and_never_replaces_active_keys() {
    let (_temp, mut store, backend, mut peer) = setup();
    let old = backend.memory.slot(Slot::LibraryKey).unwrap();
    operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
    peer.approve();
    let public = peer.core.public;
    peer.core.public = Some([88; 32]);
    assert!(
        operate(&mut store, &mut peer, Action::Check)
            .err()
            .unwrap()
            .failure
            == Failure::KeyConflict
    );
    assert!(matches!(
        inspect(&mut store, &peer.core.pin),
        Ok(Some(Status::Waiting { received: true, .. }))
    ));
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&old));
    peer.core.public = public;
    assert!(matches!(
        operate(&mut store, &mut peer, Action::Check),
        Ok(Status::Ready)
    ));
    assert_eq!(peer.claims, 1);
}
#[test]
fn changed_pending_target_refuses_new_invitation_without_replacing_history() {
    let (_temp, mut store, backend, mut peer) = setup();
    operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
    let before = backend.memory.slot(Slot::PairingCandidate).unwrap();
    peer.core.pin.space = Uuid::from_u128(55);
    assert!(
        operate(&mut store, &mut peer, Action::Begin)
            .err()
            .unwrap()
            .failure
            == Failure::ReviewRequired
    );
    assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&before));
    assert_eq!(peer.creates, 1);
}
#[test]
fn full_history_refuses_new_pairing_without_evicting_any_received_key() {
    let (_temp, mut store, backend, mut peer) = setup();
    for index in 0..MAX_ENTRIES {
        peer.core.pin.space = Uuid::from_u128(1000 + index as u128);
        peer.core.public =
            Some(Authority::new(&peer.bundle, &peer.core.pin.context().unwrap()).public_key());
        ready(&mut store, &mut peer);
    }
    let before = backend.memory.slot(Slot::PairingCandidate).unwrap();
    peer.core.pin.space = Uuid::from_u128(2000);
    assert!(
        operate(&mut store, &mut peer, Action::Begin)
            .err()
            .unwrap()
            .failure
            == Failure::Busy
    );
    assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&before));
    assert_eq!(peer.creates, MAX_ENTRIES);
}
#[test]
fn fresh_review_rechecks_authority_of_ready_candidate_and_preserves_old_slots() {
    let (_temp, mut store, backend, mut peer) = setup();
    ready(&mut store, &mut peer);
    let key = backend.memory.slot(Slot::LibraryKey).unwrap();
    let saved = backend.memory.slot(Slot::PairingCandidate).unwrap();
    peer.core.public = Some([77; 32]);
    let result = store
        .transaction_with(|owner| handover::prepare_locked(owner, &mut peer, None, &|_| Ok(())));
    assert!(result.err() == Some(handover::Failure::Key(Failure::KeyConflict)));
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&key));
    assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&saved));
}

#[test]
fn same_account_reconnect_can_finish_but_another_account_cannot_use_retained_candidate() {
    use crate::auth_store::{Deployment, creation::tests::install};
    let (_temp, mut store, backend, mut peer) = setup();
    let deployment =
        Deployment::from_discovery(peer.core.pin.server.clone(), peer.core.pin.instance);
    let _first = install(
        &mut store,
        deployment.clone(),
        "candidate-first",
        "public-candidate-account",
    );
    operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
    peer.approve();
    let _refreshed = install(
        &mut store,
        deployment.clone(),
        "candidate-refreshed",
        "public-candidate-account",
    );
    assert!(matches!(
        operate(&mut store, &mut peer, Action::Check),
        Ok(Status::Ready)
    ));
    let saved = backend.memory.slot(Slot::PairingCandidate).unwrap();
    let _other = install(
        &mut store,
        deployment,
        "candidate-other",
        "public-other-account",
    );
    assert!(
        store
            .transaction_with(|owner| retained_bundle(owner, &peer.core.pin))
            .unwrap()
            .is_none()
    );
    assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&saved));
    assert_eq!(peer.creates, 1);
    assert_eq!(peer.claims, 1);
}

#[test]
fn live_owner_revocation_stops_create_before_post_and_never_overwrites_old_keys() {
    use std::cell::Cell;
    let (_temp, mut store, backend, mut peer) = setup();
    let key = backend.memory.slot(Slot::LibraryKey).unwrap();
    let checks = Cell::new(0);
    let result = store.transaction_with(|owner| {
        operate_locked(owner, &mut peer, Action::Begin, &|_| {
            checks.set(checks.get() + 1);
            if checks.get() >= 5 {
                Err(Failure::ReviewRequired)
            } else {
                Ok(())
            }
        })
    });
    assert!(result.err().unwrap().failure == Failure::ReviewRequired);
    assert_eq!(peer.creates, 0);
    assert!(backend.memory.slot(Slot::LibraryKey).as_deref() == Some(&key));
    assert!(matches!(
        inspect(&mut store, &peer.core.pin),
        Ok(Some(Status::Creating))
    ));
}

#[test]
fn malformed_candidate_schema_and_forged_ready_phase_fail_before_post() {
    for change in 0..4 {
        let (_temp, mut store, backend, mut peer) = setup();
        operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
        let original = backend.memory.slot(Slot::PairingCandidate).unwrap();
        let mut value = canonical::parse(&original).unwrap();
        let Value::Object(fields) = &mut value else {
            unreachable!()
        };
        match change {
            0 => {
                fields.insert("schema".into(), Value::Int(2));
            }
            1 => {
                fields.insert("extra".into(), Value::Bool(true));
            }
            2 => {
                fields.insert("generation".into(), Value::Int(0));
            }
            _ => {
                let Value::Array(entries) = fields.get_mut("entries").unwrap() else {
                    unreachable!()
                };
                let Value::Object(entry) = &mut entries[0] else {
                    unreachable!()
                };
                entry.insert("ready".into(), Value::Bool(true));
            }
        }
        let bytes = value.encode().unwrap();
        store
            .transaction(|owner| {
                owner.replace(Slot::PairingCandidate, Some(&original), Some(&bytes))
            })
            .unwrap();
        assert!(operate(&mut store, &mut peer, Action::Begin).is_err());
        assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&bytes));
        assert_eq!(peer.creates, 1);
    }
}

#[test]
fn exhausted_receipt_generation_refuses_claim_before_receiving_a_key() {
    let (_temp, mut store, backend, mut peer) = setup();
    operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
    peer.approve();
    let old = backend.memory.slot(Slot::PairingCandidate).unwrap();
    let mut value = canonical::parse(&old).unwrap();
    let Value::Object(fields) = &mut value else {
        unreachable!()
    };
    fields.insert("generation".into(), Value::Int(i64::MAX - 1));
    let bytes = value.encode().unwrap();
    store
        .transaction(|owner| owner.replace(Slot::PairingCandidate, Some(&old), Some(&bytes)))
        .unwrap();
    assert!(
        operate(&mut store, &mut peer, Action::Check)
            .err()
            .unwrap()
            .failure
            == Failure::InvalidState
    );
    assert_eq!(peer.claims, 0);
    assert!(backend.memory.slot(Slot::PairingCandidate).as_deref() == Some(&bytes));
}

#[cfg(feature = "desktop")]
#[test]
fn lost_ui_claim_reply_keeps_worker_ownership_and_quit_barrier_until_retained() {
    use crate::account_worker::{Command, Failure as AccountFailure, Handle, Pending, Reply};
    for after in [false, true] {
        let (_temp, mut store, backend, mut peer) = setup();
        operate(&mut store, &mut peer, Action::Begin).ok().unwrap();
        peer.approve();
        backend.arm(1, after);
        let mut pending: Option<Pending> = None;
        let worker = Handle::controlled(move |command| {
            let result = match command {
                Command::CandidatePairing(action) if pending.is_none() => {
                    match operate(&mut store, &mut peer, action) {
                        Ok(_) => Ok(Reply::Saved),
                        Err(error) => {
                            pending = error.unrecorded.map(Pending::Candidate);
                            Err(if pending.is_some() {
                                AccountFailure::RetentionRequired
                            } else {
                                error.failure.into()
                            })
                        }
                    }
                }
                Command::Retain => match pending.take().unwrap().retain(&mut store) {
                    Ok(()) => Ok(Reply::Saved),
                    Err((failure, owner)) => {
                        pending = owner;
                        Err(failure)
                    }
                },
                Command::Inspect => Ok(Reply::CandidatePairing {
                    state: inspect(&mut store, &peer.core.pin),
                    failure: None,
                }),
                _ => Err(AccountFailure::RetentionRequired),
            };
            (result, pending.is_some())
        });
        drop(
            worker
                .request(Command::CandidatePairing(Action::Check))
                .unwrap(),
        );
        worker
            .request(Command::Inspect)
            .unwrap()
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap()
            .unwrap();
        assert!(worker.retention_required() && !worker.can_quit());
        assert!(matches!(
            worker
                .request(Command::Retain)
                .unwrap()
                .recv_timeout(std::time::Duration::from_secs(10))
                .unwrap(),
            Ok(Reply::Saved)
        ));
        assert!(worker.can_quit() && !worker.retention_required());
    }
}
