use super::*;
use crate::key_store::recipient::retirement_terminal;
use crate::{
    bootstrap::{Invitation, PairingDraft},
    cloud::{Pairing, PairingState},
    key_store::recipient::{self, Outcome as PairingOutcome, Rejected},
};
use std::time::{SystemTime, UNIX_EPOCH};

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
struct Server {
    core: FakeRemote,
    bundle: Bundle,
    invitation: Option<Invitation>,
    ciphertext: Option<Vec<u8>>,
    creates: usize,
    polls: usize,
    claims: usize,
    cancels: usize,
    lose_create: bool,
    lose_claim: bool,
    lose_cancel: bool,
    change_after_claim: bool,
    expired: bool,
}
impl Server {
    fn new(mut core: FakeRemote) -> Self {
        let (bundle, _) = remote_library(&mut core);
        Self {
            core,
            bundle,
            invitation: None,
            ciphertext: None,
            creates: 0,
            polls: 0,
            claims: 0,
            cancels: 0,
            lose_create: false,
            lose_claim: false,
            lose_cancel: false,
            change_after_claim: false,
            expired: false,
        }
    }
    fn approve(&mut self) {
        self.ciphertext = Some(
            bootstrap::seal_pairing(&self.bundle, self.invitation.as_ref().unwrap(), now())
                .unwrap(),
        );
    }
    fn network() -> Failure {
        Failure::Cloud(cloud::Failure::Network)
    }
}
impl Remote for Server {
    fn preflight(&mut self) -> Result<()> {
        self.core.preflight()
    }
    fn binding(&self) -> Result<KeyBinding> {
        self.core.binding()
    }
    fn role(&self) -> Role {
        self.core.role()
    }
    fn authority(&mut self) -> Result<Option<[u8; 32]>> {
        self.core.authority()
    }
    fn recovery(&mut self) -> Result<Option<Evidence>> {
        self.core.recovery()
    }
    fn has_records(&mut self) -> Result<bool> {
        self.core.has_records()
    }
    fn bootstrap(&mut self, _: &[u8; 32], _: &[u8]) -> Result<Evidence> {
        panic!("recipient must never bootstrap a different library key")
    }
}
impl recipient::Remote for Server {
    fn create(&mut self, draft: &PairingDraft) -> Result<Pairing> {
        self.core.call();
        self.creates += 1;
        assert!(self.core.memory.slot(Slot::LibraryKey).is_none());
        let bytes = self.core.memory.slot(Slot::PairingRecipient).unwrap();
        let v = canonical::parse(&bytes).unwrap();
        let p = &v.as_object().unwrap()["phase"];
        let p = p.as_object().unwrap();
        assert!(p["kind"].as_text().unwrap() == "creating" && p["sent"] == Value::Bool(true));
        let saved = PairingDraft::decode_secret(&p["secret"].encode().unwrap()).unwrap();
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
        self.ciphertext = None;
        if self.lose_create {
            self.lose_create = false;
            return Err(Self::network());
        }
        Ok(Pairing::test(invitation, PairingState::Pending))
    }
    fn poll(&mut self, invitation: &Invitation) -> Result<Pairing> {
        self.core.call();
        self.polls += 1;
        if self.expired {
            return Err(Failure::Cloud(cloud::Failure::Server {
                code: cloud::ErrorCode::PairingExpired,
                retry_after: None,
            }));
        }
        assert!(self.invitation.as_ref() == Some(invitation));
        Ok(Pairing::test(
            invitation.clone(),
            if self.ciphertext.is_some() {
                PairingState::Approved
            } else {
                PairingState::Pending
            },
        ))
    }
    fn claim(&mut self, expected: &Pairing) -> Result<Vec<u8>> {
        self.core.call();
        self.claims += 1;
        assert!(expected.state() == PairingState::Approved);
        assert!(self.invitation.as_ref() == Some(expected.invitation()));
        assert!(self.core.memory.slot(Slot::PairingRecipient).is_some());
        if self.lose_claim {
            self.lose_claim = false;
            return Err(Self::network());
        }
        if self.change_after_claim {
            self.core.pin.dataset = Binding::from_checkpoint([9; 32]);
        }
        Ok(self.ciphertext.clone().unwrap())
    }
    fn cancel(&mut self, invitation: &Invitation) -> Result<()> {
        self.core.call();
        self.cancels += 1;
        let v = canonical::parse(&self.core.memory.slot(Slot::PairingRecipient).unwrap()).unwrap();
        assert!(
            v.as_object().unwrap()["phase"].as_object().unwrap()["kind"]
                .as_text()
                .unwrap()
                == "cancelling"
        );
        assert!(self.invitation.as_ref().is_none_or(|v| v == invitation));
        self.invitation = None;
        self.ciphertext = None;
        if self.lose_cancel {
            self.lose_cancel = false;
            return Err(Self::network());
        }
        Ok(())
    }
}
fn setup_pairing() -> (tempfile::TempDir, Store<Memory>, Server, Memory) {
    let memory = Memory::default();
    let (temp, store, core) = setup(memory.clone());
    (temp, store, Server::new(core), memory)
}
fn begin(store: &mut Store<Memory>, server: &mut Server) -> recipient::Result<PairingOutcome> {
    store.transaction_with(|owner| recipient::begin_locked(owner, server))
}
fn check(store: &mut Store<Memory>, server: &mut Server) -> recipient::Result<PairingOutcome> {
    store.transaction_with(|owner| recipient::check_locked(owner, server))
}
fn cancel(store: &mut Store<Memory>, server: &mut Server) -> recipient::Result<PairingOutcome> {
    store.transaction_with(|owner| recipient::cancel_locked(owner, server))
}
fn good<T>(result: recipient::Result<T>) -> T {
    match result {
        Ok(value) => value,
        Err(rejected) => panic!("closed pairing failure: {:?}", rejected.failure),
    }
}
fn rejected<T>(result: recipient::Result<T>) -> Rejected {
    match result {
        Ok(_) => panic!("expected a closed pairing refusal"),
        Err(rejected) => rejected,
    }
}
fn waiting(outcome: PairingOutcome) -> Invitation {
    match outcome {
        PairingOutcome::Waiting(invitation) => invitation,
        _ => panic!("expected a persisted invitation"),
    }
}
fn assert_ready(outcome: PairingOutcome) {
    assert!(matches!(
        outcome,
        PairingOutcome::Ready {
            kit: KitStatus::None
        }
    ));
}

#[test]
fn recipient_retains_private_draft_before_post_and_claim_before_key_activation() {
    let (temp, mut store, mut server, memory) = setup_pairing();
    let invitation = waiting(good(begin(&mut store, &mut server)));
    assert!(server.creates == 1 && server.claims == 0);
    assert!(memory.slot(Slot::LibraryKey).is_none());
    let saved = memory.slot(Slot::PairingRecipient).unwrap();
    assert!(!retirement_terminal(Some(saved.clone())).unwrap());
    let v = canonical::parse(&saved).unwrap();
    assert!(v.as_object().unwrap()["generation"] == Value::Int(3));
    let qr = invitation.encode_qr().unwrap();
    let qr = canonical::parse(&qr).unwrap();
    assert!(!qr.as_object().unwrap().contains_key("privateKey"));
    assert!(waiting(good(check(&mut store, &mut server))) == invitation);
    assert!(memory.slot(Slot::PairingRecipient).unwrap() == saved);
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    server.approve();
    assert_ready(good(check(&mut store, &mut server)));
    assert!(retirement_terminal(memory.slot(Slot::PairingRecipient)).unwrap());
    assert!(server.claims == 1 && memory.0.lock().unwrap().writes == 6);
    let key = store
        .transaction_with(|o| load_locked(o, &mut server))
        .unwrap()
        .unwrap();
    assert!(key.bundle.for_secure_storage() == server.bundle.for_secure_storage());
    assert_ready(good(begin(&mut store, &mut server)));
    assert!(server.creates == 1 && server.claims == 1);
    for name in ["secret-owner.bin", "secrets.lock", "library.lock"] {
        let bytes = std::fs::read(temp.path().join(name)).unwrap();
        assert!(
            !bytes
                .windows(32)
                .any(|v| v == &server.bundle.for_secure_storage()[..32])
        );
    }
    assert!(!temp.path().join("Sync").exists());
}
#[test]
fn lost_nonidempotent_create_is_never_retried_or_shown_without_a_durable_invitation() {
    let (_temp, mut store, mut server, memory) = setup_pairing();
    server.lose_create = true;
    assert!(rejected(begin(&mut store, &mut server)).failure == Server::network());
    let original = memory.slot(Slot::PairingRecipient).unwrap();
    let old = server.invitation.clone().unwrap();
    for _ in 0..3 {
        assert!(matches!(
            good(begin(&mut store, &mut server)),
            PairingOutcome::CreationUnconfirmed
        ));
        assert!(matches!(
            good(check(&mut store, &mut server)),
            PairingOutcome::CreationUnconfirmed
        ));
    }
    assert!(memory.slot(Slot::PairingRecipient).unwrap() == original && server.creates == 1);
    assert!(matches!(
        good(cancel(&mut store, &mut server)),
        PairingOutcome::Cancelled
    ));
    let next = waiting(good(begin(&mut store, &mut server)));
    assert!(next != old && next.public_key() != old.public_key() && next.nonce() != old.nonce());
    assert!(server.creates == 2 && server.cancels == 0);
    assert!(memory.slot(Slot::LibraryKey).is_none());
}
#[test]
fn lost_claim_retries_the_same_invitation_without_rotating_private_material() {
    let (temp, mut store, mut server, memory) = setup_pairing();
    let invitation = waiting(good(begin(&mut store, &mut server)));
    let saved = memory.slot(Slot::PairingRecipient).unwrap();
    server.approve();
    server.lose_claim = true;
    assert!(rejected(check(&mut store, &mut server)).failure == Server::network());
    assert!(memory.slot(Slot::PairingRecipient).unwrap() == saved);
    assert!(memory.slot(Slot::LibraryKey).is_none());
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    assert_ready(good(check(&mut store, &mut server)));
    assert!(
        server.invitation.as_ref() == Some(&invitation)
            && server.creates == 1
            && server.claims == 2
    );
}
#[test]
fn all_six_secret_write_failures_keep_a_safe_resume_or_explicit_new_invitation_path() {
    for phase in 1..=6 {
        for after in [false, true] {
            let (temp, mut store, mut server, memory) = setup_pairing();
            memory.0.lock().unwrap().fail_write = Some((phase, after));
            let first = begin(&mut store, &mut server);
            let failure = if phase <= 3 {
                rejected(first)
            } else {
                waiting(good(first));
                server.approve();
                rejected(check(&mut store, &mut server))
            };
            if let Some(receipt) = failure.unrecorded {
                good(receipt.retain(&mut store));
            }
            if phase >= 5 && !(phase == 6 && after) {
                assert!(
                    store
                        .transaction_with(|o| load_locked(o, &mut server))
                        .err()
                        == Some(Failure::Busy)
                );
            }
            drop(store);
            let mut store = Store::load(temp.path(), memory.clone()).unwrap();
            let outcome = good(begin(&mut store, &mut server));
            if matches!(outcome, PairingOutcome::CreationUnconfirmed) {
                assert!(phase == 2 && after && server.creates == 0);
                good(cancel(&mut store, &mut server));
                waiting(good(begin(&mut store, &mut server)));
            }
            if memory.slot(Slot::LibraryKey).is_none() {
                server.approve();
                assert_ready(good(check(&mut store, &mut server)));
            } else {
                assert_ready(good(check(&mut store, &mut server)));
            }
            assert!(server.creates == 1);
            let key = store
                .transaction_with(|o| load_locked(o, &mut server))
                .unwrap()
                .unwrap();
            assert!(key.bundle.for_secure_storage() == server.bundle.for_secure_storage());
        }
    }
}
#[test]
fn unrecorded_claim_keeps_ownership_when_locked_and_can_finish_after_server_expiry() {
    for after in [false, true] {
        let (_temp, mut store, mut server, memory) = setup_pairing();
        waiting(good(begin(&mut store, &mut server)));
        server.approve();
        memory.0.lock().unwrap().fail_write = Some((4, after));
        let receipt = rejected(check(&mut store, &mut server)).unrecorded.unwrap();
        memory.0.lock().unwrap().fail_read = true;
        let failure = rejected(receipt.retain(&mut store));
        assert!(failure.failure == Failure::Secret(secret_store::Failure::Locked));
        let receipt = failure.unrecorded.unwrap();
        memory.0.lock().unwrap().fail_read = false;
        server.expired = true;
        good(receipt.retain(&mut store));
        assert_ready(good(check(&mut store, &mut server)));
        assert!(server.claims == 1 && server.polls == 1);
    }
}
#[cfg(feature = "desktop")]
#[test]
fn native_account_owner_keeps_a_lost_ui_claim_and_retries_locked_retention_before_other_work() {
    use crate::account_worker::{Command, Failure as AccountFailure, Handle, Pending, Reply};
    use std::time::Duration;
    for after in [false, true] {
        let (_temp, mut store, mut server, memory) = setup_pairing();
        waiting(good(begin(&mut store, &mut server)));
        server.approve();
        memory.0.lock().unwrap().fail_write = Some((4, after));
        let mut pending: Option<Pending> = None;
        let worker = Handle::controlled(move |command| {
            let result =
                if pending.is_some() && !matches!(&command, Command::Inspect | Command::Retain) {
                    Err(AccountFailure::RetentionRequired)
                } else {
                    match command {
                        Command::CheckPairing => match check(&mut store, &mut server) {
                            Ok(PairingOutcome::Ready { kit }) => {
                                assert!(server.claims == 1 && server.polls == 1);
                                Ok(Reply::Library(Ok(Outcome::Ready { kit })))
                            }
                            Ok(_) => panic!("expected a retained claim or completed activation"),
                            Err(error) => {
                                pending = error.unrecorded.map(Pending::Pairing);
                                assert!(pending.is_some());
                                server.expired = true;
                                Err(AccountFailure::RetentionRequired)
                            }
                        },
                        Command::Retain => match pending.take().unwrap().retain(&mut store) {
                            Ok(()) => Ok(Reply::Pairing {
                                state: store.transaction_with(|o| {
                                    recipient::inspect_locked(o, &server.core.pin)
                                }),
                                failure: None,
                            }),
                            Err((_, owner)) => {
                                pending = owner;
                                Err(AccountFailure::RetentionRequired)
                            }
                        },
                        Command::Inspect => Ok(Reply::Profile {
                            email: None,
                            server: None,
                            interrupted: pending.is_some(),
                            switching: crate::key_store::handover::Status::default(),
                        }),
                        _ => Err(AccountFailure::InvalidState),
                    }
                };
            (result, pending.is_some())
        });
        // Losing the consumer does not drop the received envelope from the owner.
        drop(worker.request(Command::CheckPairing).unwrap());
        let inspected = worker
            .request(Command::Inspect)
            .unwrap()
            .recv_timeout(Duration::from_secs(3))
            .unwrap();
        assert!(matches!(
            inspected,
            Ok(Reply::Profile {
                interrupted: true,
                ..
            })
        ));
        assert!(worker.retention_required() && !worker.can_quit());
        assert!(memory.slot(Slot::LibraryKey).is_none());
        memory.0.lock().unwrap().fail_read = true;
        let retry = worker
            .request(Command::Retain)
            .unwrap()
            .recv_timeout(Duration::from_secs(3))
            .unwrap();
        assert!(matches!(retry, Err(AccountFailure::RetentionRequired)));
        assert!(worker.retention_required() && !worker.can_quit());
        assert!(matches!(
            worker
                .request(Command::SignOut)
                .unwrap()
                .recv_timeout(Duration::from_secs(3))
                .unwrap(),
            Err(AccountFailure::RetentionRequired)
        ));
        memory.0.lock().unwrap().fail_read = false;
        assert!(matches!(
            worker
                .request(Command::Retain)
                .unwrap()
                .recv_timeout(Duration::from_secs(3))
                .unwrap(),
            Ok(Reply::Pairing {
                state: Ok(Some(recipient::RetainedStatus::Waiting {
                    received: true,
                    ..
                })),
                failure: None
            })
        ));
        assert!(!worker.retention_required() && worker.can_quit());
        assert!(memory.slot(Slot::LibraryKey).is_none());
        assert!(matches!(
            worker
                .request(Command::CheckPairing)
                .unwrap()
                .recv_timeout(Duration::from_secs(3))
                .unwrap(),
            Ok(Reply::Library(Ok(Outcome::Ready { .. })))
        ));
        assert!(memory.slot(Slot::LibraryKey).is_some());
    }
}
#[test]
fn retained_claim_authenticates_after_invitation_expiry_without_another_poll_or_claim() {
    let (temp, mut store, mut server, memory) = setup_pairing();
    waiting(good(begin(&mut store, &mut server)));
    server.approve();
    memory.0.lock().unwrap().fail_write = Some((5, false));
    assert!(
        rejected(check(&mut store, &mut server)).failure
            == Failure::Secret(secret_store::Failure::Unavailable)
    );
    let old = memory.slot(Slot::PairingRecipient).unwrap();
    let mut v: serde_json::Value = serde_json::from_slice(&old).unwrap();
    let payload = &mut v["phase"]["secret"]["invitationPayload"];
    let mut invitation: serde_json::Value =
        serde_json::from_str(payload.as_str().unwrap()).unwrap();
    invitation["expiresAt"] = serde_json::json!(1700000300);
    *payload = serde_json::json!(serde_json::to_string(&invitation).unwrap());
    let changed = canonical::parse(&serde_json::to_vec(&v).unwrap())
        .unwrap()
        .encode()
        .unwrap();
    store
        .transaction(|o| o.replace(Slot::PairingRecipient, Some(&old), Some(&changed)))
        .unwrap();
    drop(store);
    server.expired = true;
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    assert_ready(good(check(&mut store, &mut server)));
    assert!(server.claims == 1 && server.polls == 1);
}
#[test]
fn cancelled_or_newer_generation_cannot_be_overwritten_by_an_old_unrecorded_receipt() {
    for claim in [false, true] {
        let (_temp, mut store, mut server, memory) = setup_pairing();
        memory.0.lock().unwrap().fail_write = Some((if claim { 4 } else { 3 }, false));
        let failure = if claim {
            waiting(good(begin(&mut store, &mut server)));
            server.approve();
            rejected(check(&mut store, &mut server))
        } else {
            rejected(begin(&mut store, &mut server))
        };
        let receipt = failure.unrecorded.unwrap();
        good(cancel(&mut store, &mut server));
        let next = waiting(good(begin(&mut store, &mut server)));
        let saved = memory.slot(Slot::PairingRecipient).unwrap();
        let failure = rejected(receipt.retain(&mut store));
        assert!(failure.failure == Failure::Secret(secret_store::Failure::Stale));
        assert!(failure.unrecorded.is_some());
        assert!(memory.slot(Slot::PairingRecipient).unwrap() == saved);
        assert!(
            server.invitation.as_ref() == Some(&next) && memory.slot(Slot::LibraryKey).is_none()
        );
    }
}
#[test]
fn cancellation_is_durable_idempotent_and_never_discards_a_received_library_key() {
    let (temp, mut store, mut server, memory) = setup_pairing();
    waiting(good(begin(&mut store, &mut server)));
    server.lose_cancel = true;
    assert!(rejected(cancel(&mut store, &mut server)).failure == Server::network());
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    assert!(matches!(
        good(check(&mut store, &mut server)),
        PairingOutcome::Cancelled
    ));
    assert!(server.cancels == 2 && memory.slot(Slot::LibraryKey).is_none());
    waiting(good(begin(&mut store, &mut server)));
    server.approve();
    let writes = memory.0.lock().unwrap().writes;
    memory.0.lock().unwrap().fail_write = Some((writes + 2, false));
    rejected(check(&mut store, &mut server));
    let retained = memory.slot(Slot::PairingRecipient).unwrap();
    assert!(rejected(cancel(&mut store, &mut server)).failure == Failure::Busy);
    assert!(memory.slot(Slot::PairingRecipient).unwrap() == retained);
    assert_ready(good(check(&mut store, &mut server)));
}
#[test]
fn recipient_blocks_other_key_owners_and_refuses_wrong_authority_or_tampered_envelopes() {
    for tamper in [false, true] {
        let (_temp, mut store, mut server, memory) = setup_pairing();
        waiting(good(begin(&mut store, &mut server)));
        assert!(initialize(&mut store, &mut server.core).err() == Some(Failure::Busy));
        let (_, kit) = remote_library(&mut server.core);
        assert!(recover(&mut store, &mut server.core, kit).err() == Some(Failure::Busy));
        server.approve();
        if tamper {
            server.ciphertext.as_mut().unwrap()[20] ^= 1;
        } else {
            let other = Bundle::from_material(&[8; 64]).unwrap();
            server.core.public =
                Some(Authority::new(&other, &binding().context().unwrap()).public_key());
        }
        assert!(check(&mut store, &mut server).is_err());
        assert!(memory.slot(Slot::LibraryKey).is_none());
        assert!(memory.slot(Slot::PairingRecipient).is_some());
    }
}
#[test]
fn reader_can_finish_an_existing_approval_but_never_create_a_new_pairing() {
    let (_temp, mut store, mut server, memory) = setup_pairing();
    server.core.role = Role::Reader;
    assert!(
        rejected(begin(&mut store, &mut server)).failure
            == Failure::Cloud(cloud::Failure::ReadOnly)
    );
    assert!(memory.slot(Slot::PairingRecipient).is_none() && server.creates == 0);
    server.core.role = Role::Writer;
    waiting(good(begin(&mut store, &mut server)));
    server.approve();
    server.core.role = Role::Reader;
    assert_ready(good(check(&mut store, &mut server)));
}
#[test]
fn paired_recovery_preserves_checkpoint_and_marker_and_refuses_foreign_checkpoint_scope() {
    for foreign in [false, true] {
        let (temp, mut store, mut server, memory) = setup_pairing();
        let mut scope = binding().checkpoint_scope();
        if foreign {
            scope.dataset = Binding::from_checkpoint([9; 32]);
        }
        let original = checkpoint(&temp, &mut store, scope);
        let marker = temp.path().join("Sync/primary.pending");
        std::fs::write(&marker, b"fictional pending marker").unwrap();
        if foreign {
            assert!(begin(&mut store, &mut server).is_err());
            assert!(memory.slot(Slot::PairingRecipient).is_none() && server.creates == 0);
        } else {
            waiting(good(begin(&mut store, &mut server)));
            server.approve();
            assert_ready(good(check(&mut store, &mut server)));
        }
        assert!(std::fs::read(temp.path().join("Sync/journal.bin")).unwrap() == original);
        assert!(std::fs::read(marker).unwrap() == b"fictional pending marker");
    }
}

#[test]
fn foreign_scope_before_or_during_pairing_never_activates_or_overwrites_local_secrets() {
    for stage in 0..3 {
        let (_temp, mut store, mut server, memory) = setup_pairing();
        waiting(good(begin(&mut store, &mut server)));
        let saved = memory.slot(Slot::PairingRecipient).unwrap();
        server.approve();
        if stage == 0 {
            server.core.pin.epoch = 2;
        } else {
            server.core.change_on = Some(server.core.calls + stage + 1);
        }
        assert!(rejected(check(&mut store, &mut server)).failure == Failure::ReviewRequired);
        let retained = memory.slot(Slot::PairingRecipient).unwrap();
        if server.claims == 0 {
            assert!(retained == saved);
        } else {
            // A received authenticated claim is retained in its original scope;
            // the changed scope still cannot activate or cancel it.
            assert!(server.claims == 1 && retained != saved);
            assert!(matches!(
                store
                    .transaction_with(|o| recipient::inspect_locked(o, &binding()))
                    .unwrap(),
                Some(recipient::RetainedStatus::Waiting { received: true, .. })
            ));
        }
        assert!(memory.slot(Slot::LibraryKey).is_none());
        assert!(cancel(&mut store, &mut server).is_err());
        assert!(memory.slot(Slot::PairingRecipient).unwrap() == retained);
    }
}
#[test]
fn scope_change_after_receiving_a_claim_retains_the_response_before_review_and_never_installs_a_key()
 {
    for fault in [None, Some(false), Some(true)] {
        let (_temp, mut store, mut server, memory) = setup_pairing();
        waiting(good(begin(&mut store, &mut server)));
        server.approve();
        server.change_after_claim = true;
        if let Some(after) = fault {
            memory.0.lock().unwrap().fail_write = Some((4, after));
        }
        let failure = rejected(check(&mut store, &mut server));
        if fault.is_some() {
            assert!(failure.failure == Failure::Secret(secret_store::Failure::Unavailable));
            good(failure.unrecorded.unwrap().retain(&mut store));
        } else {
            assert!(failure.failure == Failure::ReviewRequired && failure.unrecorded.is_none());
        }
        let retained = memory.slot(Slot::PairingRecipient).unwrap();
        let state = store
            .transaction_with(|o| recipient::inspect_locked(o, &binding()))
            .unwrap();
        assert!(matches!(
            state,
            Some(recipient::RetainedStatus::Waiting { received: true, .. })
        ));
        assert!(memory.slot(Slot::LibraryKey).is_none() && server.claims == 1);
        assert!(rejected(check(&mut store, &mut server)).failure == Failure::ReviewRequired);
        assert!(rejected(cancel(&mut store, &mut server)).failure == Failure::ReviewRequired);
        assert!(
            memory.slot(Slot::PairingRecipient).unwrap() == retained
                && memory.slot(Slot::LibraryKey).is_none()
        );
    }
}
#[test]
fn malformed_recipient_journals_never_become_a_missing_key_or_new_invitation() {
    for index in 0..7 {
        let (_temp, mut store, mut server, memory) = setup_pairing();
        waiting(good(begin(&mut store, &mut server)));
        let old = memory.slot(Slot::PairingRecipient).unwrap();
        let mut value: serde_json::Value = serde_json::from_slice(&old).unwrap();
        match index {
            0 => value["unexpected"] = serde_json::json!(true),
            1 => value["schema"] = serde_json::json!(2),
            2 => value["generation"] = serde_json::json!(0),
            3 => value["phase"]["sent"] = serde_json::json!(true),
            4 => value["phase"]["kind"] = serde_json::json!("unknown"),
            5 => value["phase"]["ciphertext"] = serde_json::json!("AQID"),
            _ => {
                value["phase"]["secret"]["draft"]["privateKey"] =
                    serde_json::json!(STANDARD.encode([0; 32]))
            }
        }
        let changed = canonical::parse(&serde_json::to_vec(&value).unwrap())
            .unwrap()
            .encode()
            .unwrap();
        store
            .transaction(|o| o.replace(Slot::PairingRecipient, Some(&old), Some(&changed)))
            .unwrap();
        assert!(begin(&mut store, &mut server).is_err());
        assert!(check(&mut store, &mut server).is_err());
        assert!(cancel(&mut store, &mut server).is_err());
        assert!(initialize(&mut store, &mut server.core).is_err());
        assert!(memory.slot(Slot::PairingRecipient).unwrap() == changed);
        assert!(
            memory.slot(Slot::LibraryKey).is_none() && server.creates == 1 && server.claims == 0
        );
    }
}
#[test]
fn pairing_restores_a_lost_library_slot_without_discarding_a_verified_recovery_kit() {
    let (_temp, mut store, mut server, memory) = setup_pairing();
    waiting(good(begin(&mut store, &mut server)));
    server.approve();
    assert_ready(good(check(&mut store, &mut server)));
    let envelope =
        bootstrap::create_recovery(&server.bundle, binding().server, binding().space, 1).unwrap();
    server.core.recovery = Some(Evidence {
        version: 4,
        ciphertext: envelope.ciphertext,
    });
    recover(&mut store, &mut server.core, envelope.kit).unwrap();
    let presentation = memory.slot(Slot::Bootstrap).unwrap();
    let installed = memory.slot(Slot::LibraryKey).unwrap();
    store
        .transaction(|o| o.replace(Slot::LibraryKey, Some(&installed), None))
        .unwrap();
    waiting(good(begin(&mut store, &mut server)));
    server.approve();
    assert!(matches!(
        good(check(&mut store, &mut server)),
        PairingOutcome::Ready {
            kit: KitStatus::VerifiedCurrent
        }
    ));
    assert!(memory.slot(Slot::LibraryKey).unwrap() == installed);
    assert!(memory.slot(Slot::Bootstrap).unwrap() == presentation);
}

#[test]
fn offline_inspection_returns_only_the_retained_public_step_and_never_activates_a_key() {
    let (temp, mut store, mut server, memory) = setup_pairing();
    assert!(
        store
            .transaction_with(|o| recipient::inspect_locked(o, &binding()))
            .unwrap()
            .is_none()
    );
    let invitation = waiting(good(begin(&mut store, &mut server)));
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    let saved = memory.slot(Slot::PairingRecipient).unwrap();
    let status = store
        .transaction_with(|o| recipient::inspect_locked(o, &binding()))
        .unwrap()
        .unwrap();
    assert!(
        matches!(status, recipient::RetainedStatus::Waiting { invitation: ref v, received: false } if v == &invitation)
    );
    let mut foreign = binding();
    foreign.epoch = 2;
    assert!(
        store
            .transaction_with(|o| recipient::inspect_locked(o, &foreign))
            .err()
            == Some(Failure::ReviewRequired)
    );
    assert!(memory.slot(Slot::PairingRecipient).unwrap() == saved && server.polls == 0);
    server.approve();
    memory.0.lock().unwrap().fail_write = Some((5, false));
    rejected(check(&mut store, &mut server));
    let saved = memory.slot(Slot::PairingRecipient).unwrap();
    let status = store
        .transaction_with(|o| recipient::inspect_locked(o, &binding()))
        .unwrap()
        .unwrap();
    assert!(matches!(
        status,
        recipient::RetainedStatus::Waiting { received: true, .. }
    ));
    assert!(
        memory.slot(Slot::PairingRecipient).unwrap() == saved
            && memory.slot(Slot::LibraryKey).is_none()
    );
    assert!(server.polls == 1 && server.claims == 1);
}
