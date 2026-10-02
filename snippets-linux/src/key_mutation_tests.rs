//! Fictional remote, real cryptography, temporary roots, synthetic local
//! authorization and injected Secret Service faults. No network or native PAM.
use super::*;
use crate::{
    bootstrap::{Invitation, PairingDraft},
    cloud::{ActionChallenge, Mutation, Pairing, PairingState, Scope, SignedAction},
    desktop::{SessionState, SessionWitness},
    key_store::{disclosure, mutations as actions},
    local_auth::{self, Gate, Purpose, Target},
};
use serde_json::{Value as JSON, json};

fn scope() -> Scope {
    serde_json::from_value(json!({
        "serverInstanceId": Uuid::from_u128(1), "spaceId": Uuid::from_u128(2),
        "scopeBinding": "public-fictional-membership-binding",
        "datasetGeneration": Uuid::from_u128(3), "feedEpoch": Uuid::from_u128(4)
    }))
    .unwrap()
}
struct Server {
    core: FakeRemote,
    scope: Scope,
    draft: PairingDraft,
    invitation: Invitation,
    approval: Option<Vec<u8>>,
    challenges: usize,
    sent: Vec<Zeroizing<Vec<u8>>>,
    lose_reply: bool,
    cancel_challenge: Option<Gate>,
    cancel_send: Option<Gate>,
    wrong_challenge: bool,
    change_after_send: bool,
}
impl Server {
    fn network() -> Failure {
        Failure::Cloud(cloud::Failure::Network)
    }
    fn sent(
        &mut self,
        signed: &SignedAction,
        guard: &mut dyn FnMut() -> std::result::Result<(), cloud::Failure>,
    ) -> Result<()> {
        // Model the transport's awaited preflight before its final send guard.
        self.core.preflight()?;
        if let Some(mut gate) = self.cancel_send.take() {
            gate.cancel();
        }
        guard()?;
        let proof = signed.encode_secret()?;
        let saved = self.core.memory.slot(Slot::KeyMutation).unwrap();
        let value = canonical::parse(&saved).unwrap();
        let phase = value.as_object().unwrap()["phase"].as_object().unwrap();
        assert!(phase["kind"].as_text().unwrap() == "signed");
        let retained = SignedAction::decode_secret(&phase["proof"].encode().unwrap())?;
        assert!(retained.encode_secret()?.as_slice() == proof.as_slice());
        self.sent.push(proof);
        Ok(())
    }
    fn reply(&mut self) -> Result<()> {
        if self.change_after_send {
            self.core.pin.dataset = Binding::from_checkpoint([99; 32]);
        }
        if self.lose_reply {
            self.lose_reply = false;
            return Err(Self::network());
        }
        Ok(())
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
        panic!("key mutation must not inspect record data")
    }
    fn bootstrap(&mut self, _: &[u8; 32], _: &[u8]) -> Result<Evidence> {
        panic!("key mutation must not bootstrap a replacement root")
    }
}
impl actions::Remote for Server {
    fn pairing(&mut self, invitation: &Invitation) -> Result<Pairing> {
        self.core.call();
        assert!(invitation == &self.invitation);
        Ok(Pairing::test(
            invitation.clone(),
            if self.approval.is_some() {
                PairingState::Approved
            } else {
                PairingState::Pending
            },
        ))
    }
    fn challenge(&mut self, mutation: Mutation, public: &[u8; 32]) -> Result<ActionChallenge> {
        self.challenges += 1;
        let saved = self.core.memory.slot(Slot::KeyMutation).unwrap();
        let value = canonical::parse(&saved).unwrap();
        let phase = value.as_object().unwrap()["phase"].as_object().unwrap();
        assert!(phase["kind"].as_text().unwrap() == "prepared");
        assert!(matches!(phase["proof"], Value::Null));
        if let Some(mut gate) = self.cancel_challenge.take() {
            gate.cancel();
        }
        let scope = if self.wrong_challenge {
            let mut value = serde_json::to_value(&self.scope).unwrap();
            value["datasetGeneration"] = json!(Uuid::from_u128(99));
            serde_json::from_value(value).unwrap()
        } else {
            self.scope.clone()
        };
        Ok(ActionChallenge::fixture(
            self.core.pin.server.clone(),
            scope,
            mutation,
            *public,
        ))
    }
    fn replace(
        &mut self,
        signed: &SignedAction,
        guard: &mut dyn FnMut() -> std::result::Result<(), cloud::Failure>,
    ) -> Result<Evidence> {
        self.sent(signed, guard)?;
        let (epoch, prior, ciphertext) = signed.expected_recovery().unwrap();
        assert!(epoch == self.core.pin.epoch);
        let version = prior.unwrap_or(0) + 1;
        if self.sent.len() > 1 {
            assert!(self.sent[0].as_slice() == self.sent.last().unwrap().as_slice());
        }
        self.core.recovery = Some(Evidence {
            version,
            ciphertext: ciphertext.into(),
        });
        self.reply()?;
        Ok(Evidence {
            version,
            ciphertext: ciphertext.into(),
        })
    }
    fn approve(
        &mut self,
        signed: &SignedAction,
        guard: &mut dyn FnMut() -> std::result::Result<(), cloud::Failure>,
    ) -> Result<Pairing> {
        self.sent(signed, guard)?;
        assert!(signed.expected_pairing() == Some(&self.invitation));
        let value: JSON = serde_json::from_slice(&signed.encode_secret()?).unwrap();
        let ciphertext = STANDARD
            .decode(value["mutation"]["ciphertext"].as_str().unwrap())
            .unwrap();
        if let Some(original) = &self.approval {
            assert!(original == &ciphertext);
        }
        self.approval = Some(ciphertext);
        self.reply()?;
        Ok(Pairing::test(
            self.invitation.clone(),
            PairingState::Approved,
        ))
    }
}
fn fixture() -> (tempfile::TempDir, Store<Memory>, Server, Memory) {
    let memory = Memory::default();
    let (temp, mut store, mut core) = setup(memory.clone());
    let scope = scope();
    core.pin = KeyBinding::new(
        core.pin.server.clone(),
        Uuid::from_u128(1),
        Uuid::from_u128(2),
        scope.identities(&core.pin.server),
        1,
    )
    .unwrap();
    initialize(&mut store, &mut core).unwrap();
    let draft = PairingDraft::generate().unwrap();
    let now = chrono::Utc::now().timestamp();
    let invitation = Invitation::new(
        core.pin.server.clone(),
        core.pin.space,
        Uuid::new_v4(),
        *draft.nonce(),
        *draft.public_key(),
        now + 300,
        now,
    )
    .unwrap();
    let server = Server {
        core,
        scope,
        draft,
        invitation,
        approval: None,
        challenges: 0,
        sent: vec![],
        lose_reply: false,
        cancel_challenge: None,
        cancel_send: None,
        wrong_challenge: false,
        change_after_send: false,
    };
    (temp, store, server, memory)
}
fn prepare(store: &mut Store<Memory>, server: &mut Server, approval: bool) -> Result<Target> {
    let invitation = approval.then(|| server.invitation.clone());
    store.transaction_with(|o| actions::prepare_locked(o, server, invitation))
}
fn authorize(target: Target) -> (Gate, local_auth::Permit) {
    let mut gate = Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(target, SessionWitness::test(SessionState::Unlocked, 1))
        .unwrap();
    let authenticated = local_auth::authenticate_fixture(request).unwrap();
    let permit = gate.accept(authenticated).unwrap();
    (gate, permit)
}
fn execute(
    store: &mut Store<Memory>,
    server: &mut Server,
    permit: local_auth::Permit,
) -> Result<actions::Outcome> {
    store.transaction_with(|o| actions::execute_locked(o, server, permit))
}
fn reconcile(store: &mut Store<Memory>, server: &mut Server) -> Result<actions::Outcome> {
    store.transaction_with(|o| actions::reconcile_locked(o, server))
}
fn phase(memory: &Memory) -> String {
    let value = canonical::parse(&memory.slot(Slot::KeyMutation).unwrap()).unwrap();
    value.as_object().unwrap()["phase"].as_object().unwrap()["kind"]
        .as_text()
        .unwrap()
        .into()
}
fn inactive(memory: &Memory) {
    let value = canonical::parse(&memory.slot(Slot::KeyMutation).unwrap()).unwrap();
    assert!(
        phase(memory) == "inactive" && matches!(value.as_object().unwrap()["intent"], Value::Null)
    );
    let p = value.as_object().unwrap()["phase"].as_object().unwrap();
    assert!(matches!(p["proof"], Value::Null) && matches!(p["version"], Value::Null));
}
fn intent(memory: &Memory) -> Zeroizing<Vec<u8>> {
    canonical::parse(&memory.slot(Slot::KeyMutation).unwrap())
        .unwrap()
        .as_object()
        .unwrap()["intent"]
        .encode()
        .unwrap()
}
fn fault(memory: &Memory, offset: usize, after: bool) {
    let mut state = memory.0.lock().unwrap();
    state.fail_write = Some((state.writes + offset, after));
}
fn shown(
    store: &mut Store<Memory>,
    server: &mut Server,
) -> (Gate, disclosure::Disclosure, Zeroizing<String>) {
    let target = store
        .transaction_with::<_, Failure>(|o| Ok(disclosure::prepare_locked(o, server)?.1))
        .unwrap();
    let (gate, permit) = authorize(target);
    let shown = store
        .transaction_with(|o| disclosure::reveal_locked(o, server, permit))
        .ok()
        .unwrap();
    let suffix = Zeroizing::new(
        shown
            .long_code()
            .unwrap()
            .chars()
            .filter(|c| c.is_alphanumeric())
            .rev()
            .take(8)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<String>(),
    );
    (gate, shown, suffix)
}
fn expire(store: &mut Store<Memory>, memory: &Memory) {
    let before = memory.slot(Slot::KeyMutation).unwrap();
    let mut v: JSON = serde_json::from_slice(&before).unwrap();
    v["phase"]["proof"]["expiresAt"] =
        json!((chrono::Utc::now() - chrono::Duration::seconds(600)).to_rfc3339());
    let bytes = serde_json::to_vec(&v).unwrap();
    store
        .transaction(|o| o.replace(Slot::KeyMutation, Some(&before), Some(&bytes)))
        .unwrap();
}

#[test]
fn replacement_retains_candidate_before_nonce_and_promotes_the_same_kit_without_changing_root() {
    let (temp, mut store, mut server, memory) = fixture();
    let root = memory.slot(Slot::LibraryKey).unwrap();
    let old = server.core.recovery.as_ref().unwrap().ciphertext.clone();
    let target = prepare(&mut store, &mut server, false).unwrap();
    assert!(target.purpose() == Purpose::ReplaceRecovery && phase(&memory) == "prepared");
    assert!(server.challenges == 0 && server.sent.is_empty());
    let candidate = intent(&memory);
    let saved: JSON = serde_json::from_slice(&candidate).unwrap();
    let kit = RecoveryKit::decode_secret_qr(&serde_json::to_vec(&saved["kit"]).unwrap()).unwrap();
    let code = kit.encode_secret_code();
    let (_gate, permit) = authorize(target);
    assert!(execute(&mut store, &mut server, permit).unwrap() == actions::Outcome::RecoveryReady);
    let target = store
        .transaction_with::<_, Failure>(|o| Ok(disclosure::prepare_locked(o, &mut server)?.1))
        .unwrap();
    let (_gate, permit) = authorize(target);
    let shown = store
        .transaction_with(|o| disclosure::reveal_locked(o, &mut server, permit))
        .ok()
        .unwrap();
    assert!(shown.long_code().unwrap() == code.as_str());
    assert!(
        server.core.recovery.as_ref().unwrap().version == 2
            && server.core.recovery.as_ref().unwrap().ciphertext != old
    );
    assert!(memory.slot(Slot::LibraryKey).unwrap().as_slice() == root.as_slice());
    assert!(memory.slot(Slot::CheckpointKey).is_none() && !temp.path().join("Sync").exists());
    inactive(&memory);
}

#[test]
fn writer_approval_wraps_the_existing_key_for_the_exact_recipient() {
    let (_temp, mut store, mut server, memory) = fixture();
    server.core.role = Role::Writer;
    let root = memory.slot(Slot::LibraryKey).unwrap();
    let archive = memory.slot(Slot::Bootstrap).unwrap();
    let target = prepare(&mut store, &mut server, true).unwrap();
    assert!(target.purpose() == Purpose::ApprovePairing);
    let (_gate, permit) = authorize(target);
    assert!(
        execute(&mut store, &mut server, permit).unwrap() == actions::Outcome::ApprovalAcknowledged
    );
    let installed = Installed::decode(&root).unwrap();
    let pending = bootstrap::PendingPairing::new(server.draft, server.invitation).unwrap();
    let bundle = bootstrap::open_pairing(
        server.approval.as_ref().unwrap(),
        &pending,
        chrono::Utc::now().timestamp(),
    )
    .unwrap();
    assert!(bundle.for_secure_storage() == installed.bundle.for_secure_storage());
    assert!(
        memory.slot(Slot::LibraryKey).unwrap().as_slice() == root.as_slice()
            && memory.slot(Slot::Bootstrap).unwrap().as_slice() == archive.as_slice()
    );
    inactive(&memory);
}

#[test]
fn candidate_write_faults_never_request_a_challenge_or_send_and_reuse_an_ambiguous_saved_candidate()
{
    for approval in [false, true] {
        for after in [false, true] {
            let (temp, mut store, mut server, memory) = fixture();
            fault(&memory, 1, after);
            assert!(
                prepare(&mut store, &mut server, approval).err()
                    == Some(Failure::Secret(secret_store::Failure::Unavailable))
            );
            assert!(server.challenges == 0 && server.sent.is_empty());
            let candidate = memory.slot(Slot::KeyMutation).map(|_| intent(&memory));
            drop(store);
            let mut store = Store::load(temp.path(), memory.clone()).unwrap();
            let target = prepare(&mut store, &mut server, approval).unwrap();
            if let Some(candidate) = candidate {
                assert!(intent(&memory).as_slice() == candidate.as_slice());
            }
            let (_gate, permit) = authorize(target);
            execute(&mut store, &mut server, permit).unwrap();
            inactive(&memory);
        }
    }
}

#[test]
fn every_replacement_write_fault_resumes_without_losing_or_replacing_the_candidate() {
    for offset in 1..=4 {
        for after in [false, true] {
            let (temp, mut store, mut server, memory) = fixture();
            let target = prepare(&mut store, &mut server, false).unwrap();
            let candidate = intent(&memory);
            let root = memory.slot(Slot::LibraryKey).unwrap();
            let (_gate, permit) = authorize(target);
            fault(&memory, offset, after);
            assert!(
                execute(&mut store, &mut server, permit).err()
                    == Some(Failure::Secret(secret_store::Failure::Unavailable)),
                "offset {offset}, after {after}"
            );
            assert!(offset != 1 || server.sent.is_empty());
            if phase(&memory) != "inactive" {
                assert!(intent(&memory).as_slice() == candidate.as_slice());
            }
            drop(store);
            let mut store = Store::load(temp.path(), memory.clone()).unwrap();
            match phase(&memory).as_str() {
                "prepared" | "signed" if server.sent.is_empty() => {
                    let target = prepare(&mut store, &mut server, false).unwrap();
                    let (_gate, permit) = authorize(target);
                    execute(&mut store, &mut server, permit).unwrap();
                }
                "signed" | "acknowledged" => {
                    assert!(
                        reconcile(&mut store, &mut server).unwrap()
                            == actions::Outcome::RecoveryReady
                    );
                }
                "inactive" => {}
                _ => panic!("unexpected mutation state"),
            }
            assert!(server.sent.len() == 1 && server.core.recovery.as_ref().unwrap().version == 2);
            assert!(memory.slot(Slot::LibraryKey).unwrap().as_slice() == root.as_slice());
            inactive(&memory);
        }
    }
}

#[test]
fn every_approval_write_fault_resumes_only_from_the_original_signature_or_saved_acknowledgement() {
    for offset in 1..=3 {
        for after in [false, true] {
            let (temp, mut store, mut server, memory) = fixture();
            let target = prepare(&mut store, &mut server, true).unwrap();
            let candidate = intent(&memory);
            let (_gate, permit) = authorize(target);
            fault(&memory, offset, after);
            assert!(
                execute(&mut store, &mut server, permit).err()
                    == Some(Failure::Secret(secret_store::Failure::Unavailable))
            );
            if phase(&memory) != "inactive" {
                assert!(intent(&memory).as_slice() == candidate.as_slice());
            }
            drop(store);
            let mut store = Store::load(temp.path(), memory.clone()).unwrap();
            match phase(&memory).as_str() {
                "prepared" | "signed" => {
                    let target = prepare(&mut store, &mut server, true).unwrap();
                    let (_gate, permit) = authorize(target);
                    execute(&mut store, &mut server, permit).unwrap();
                }
                "acknowledged" => {
                    assert!(
                        reconcile(&mut store, &mut server).unwrap()
                            == actions::Outcome::ApprovalAcknowledged
                    );
                }
                "inactive" => {}
                _ => panic!("unexpected mutation state"),
            }
            if server.sent.len() > 1 {
                assert!(server.sent[0].as_slice() == server.sent[1].as_slice());
            }
            assert!(server.challenges == if offset == 1 && !after { 2 } else { 1 });
            inactive(&memory);
        }
    }
}

#[test]
fn lost_approval_response_requires_new_local_authorization_but_replays_the_original_signature() {
    let (temp, mut store, mut server, memory) = fixture();
    let target = prepare(&mut store, &mut server, true).unwrap();
    let (_gate, permit) = authorize(target);
    server.lose_reply = true;
    assert!(execute(&mut store, &mut server, permit).err() == Some(Server::network()));
    let original = memory.slot(Slot::KeyMutation).unwrap();
    assert!(reconcile(&mut store, &mut server).unwrap() == actions::Outcome::ReviewRequired);
    assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    let target = prepare(&mut store, &mut server, true).unwrap();
    let (_gate, permit) = authorize(target);
    assert!(
        execute(&mut store, &mut server, permit).unwrap() == actions::Outcome::ApprovalAcknowledged
    );
    assert!(
        server.challenges == 1
            && server.sent.len() == 2
            && server.sent[0].as_slice() == server.sent[1].as_slice()
    );
    inactive(&memory);
}

#[test]
fn expired_recovery_proof_is_reconciled_by_exact_envelope_without_a_new_nonce_or_send() {
    let (_temp, mut store, mut server, memory) = fixture();
    let target = prepare(&mut store, &mut server, false).unwrap();
    let (_gate, permit) = authorize(target);
    server.lose_reply = true;
    assert!(execute(&mut store, &mut server, permit).err() == Some(Server::network()));
    expire(&mut store, &memory);
    let target = prepare(&mut store, &mut server, false).unwrap();
    let (_gate, permit) = authorize(target);
    assert!(execute(&mut store, &mut server, permit).unwrap() == actions::Outcome::ReviewRequired);
    assert!(reconcile(&mut store, &mut server).unwrap() == actions::Outcome::RecoveryReady);
    assert!(server.challenges == 1 && server.sent.len() == 1);
    inactive(&memory);
}

#[test]
fn expired_unacknowledged_approval_is_not_confirmed_from_a_redacted_approved_status() {
    let (_temp, mut store, mut server, memory) = fixture();
    let target = prepare(&mut store, &mut server, true).unwrap();
    let (_gate, permit) = authorize(target);
    server.lose_reply = true;
    assert!(execute(&mut store, &mut server, permit).err() == Some(Server::network()));
    expire(&mut store, &memory);
    let original = memory.slot(Slot::KeyMutation).unwrap();
    let target = prepare(&mut store, &mut server, true).unwrap();
    let (_gate, permit) = authorize(target);
    assert!(execute(&mut store, &mut server, permit).unwrap() == actions::Outcome::ReviewRequired);
    assert!(reconcile(&mut store, &mut server).unwrap() == actions::Outcome::ReviewRequired);
    assert!(server.challenges == 1 && server.sent.len() == 1 && phase(&memory) == "signed");
    assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
}

#[test]
fn recovery_reconciliation_refuses_a_different_ciphertext_or_version() {
    for changed_version in [false, true] {
        let (_temp, mut store, mut server, memory) = fixture();
        let target = prepare(&mut store, &mut server, false).unwrap();
        let (_gate, permit) = authorize(target);
        server.lose_reply = true;
        assert!(execute(&mut store, &mut server, permit).err() == Some(Server::network()));
        if changed_version {
            server.core.recovery.as_mut().unwrap().version += 1;
        } else {
            server.core.recovery.as_mut().unwrap().ciphertext[0] ^= 1;
        }
        let original = memory.slot(Slot::KeyMutation).unwrap();
        assert!(reconcile(&mut store, &mut server).unwrap() == actions::Outcome::ReviewRequired);
        assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
    }
}

#[test]
fn confirming_a_promoted_kit_retires_both_owners_and_an_older_journal_cannot_resurrect_it() {
    let (_temp, mut store, mut server, memory) = fixture();
    let target = prepare(&mut store, &mut server, false).unwrap();
    let (_gate, permit) = authorize(target);
    fault(&memory, 4, false);
    assert!(
        execute(&mut store, &mut server, permit).err()
            == Some(Failure::Secret(secret_store::Failure::Unavailable))
    );
    assert!(phase(&memory) == "acknowledged");
    let old_acknowledgement = memory.slot(Slot::KeyMutation).unwrap();
    let target = store
        .transaction_with::<_, Failure>(|o| Ok(disclosure::prepare_locked(o, &mut server)?.1))
        .unwrap();
    let (_gate, permit) = authorize(target);
    let shown = store
        .transaction_with(|o| disclosure::reveal_locked(o, &mut server, permit))
        .ok()
        .unwrap();
    let suffix = Zeroizing::new(
        shown
            .long_code()
            .unwrap()
            .chars()
            .filter(|c| c.is_alphanumeric())
            .rev()
            .take(8)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<String>(),
    );
    store
        .transaction_with(|o| disclosure::confirm_saved_locked(o, &mut server, shown, suffix))
        .unwrap();
    let retired = memory.slot(Slot::Bootstrap).unwrap();
    inactive(&memory);
    let inactive_item = memory.slot(Slot::KeyMutation).unwrap();
    // A synthetic restore of an older, valid item must not reconstruct the
    // capability in a presentation whose successful confirmation retired it.
    store
        .transaction(|o| {
            o.replace(
                Slot::KeyMutation,
                Some(&inactive_item),
                Some(&old_acknowledgement),
            )
        })
        .unwrap();
    assert!(reconcile(&mut store, &mut server).unwrap() == actions::Outcome::RecoveryReady);
    assert!(memory.slot(Slot::Bootstrap).unwrap().as_slice() == retired.as_slice());
    let v = canonical::parse(&retired).unwrap();
    assert!(
        v.as_object().unwrap()["presentation"].as_object().unwrap()["kind"]
            .as_text()
            .unwrap()
            == "verification"
    );
    inactive(&memory);
}

#[test]
fn faults_during_two_document_confirmation_keep_an_unconfirmed_capability_or_retire_every_copy() {
    for offset in 1..=2 {
        for after in [false, true] {
            let (temp, mut store, mut server, memory) = fixture();
            let root = memory.slot(Slot::LibraryKey).unwrap();
            let target = prepare(&mut store, &mut server, false).unwrap();
            let (_gate, permit) = authorize(target);
            fault(&memory, 4, false);
            assert!(
                execute(&mut store, &mut server, permit).err()
                    == Some(Failure::Secret(secret_store::Failure::Unavailable))
            );
            let (_gate, presentation, suffix) = shown(&mut store, &mut server);
            fault(&memory, offset, after);
            assert!(
                store
                    .transaction_with(|o| disclosure::confirm_saved_locked(
                        o,
                        &mut server,
                        presentation,
                        suffix
                    ))
                    .err()
                    == Some(Failure::Secret(secret_store::Failure::Unavailable))
            );
            drop(store);
            let mut store = Store::load(temp.path(), memory.clone()).unwrap();
            let bytes = memory.slot(Slot::Bootstrap).unwrap();
            let value = canonical::parse(&bytes).unwrap();
            let p = value.as_object().unwrap()["presentation"]
                .as_object()
                .unwrap();
            if p["kind"].as_text().unwrap() == "retained" {
                let (_gate, presentation, suffix) = shown(&mut store, &mut server);
                store
                    .transaction_with(|o| {
                        disclosure::confirm_saved_locked(o, &mut server, presentation, suffix)
                    })
                    .unwrap();
            }
            let bytes = memory.slot(Slot::Bootstrap).unwrap();
            let value = canonical::parse(&bytes).unwrap();
            assert!(
                value.as_object().unwrap()["presentation"]
                    .as_object()
                    .unwrap()["kind"]
                    .as_text()
                    .unwrap()
                    == "verification"
            );
            inactive(&memory);
            assert!(
                memory.slot(Slot::LibraryKey).unwrap().as_slice() == root.as_slice()
                    && server.challenges == 1
                    && server.sent.len() == 1
            );
        }
    }
}

#[test]
fn confirming_the_current_code_does_not_discard_an_unrelated_future_replacement() {
    for signed in [false, true] {
        let (_temp, mut store, mut server, memory) = fixture();
        let target = prepare(&mut store, &mut server, false).unwrap();
        if signed {
            let (gate, permit) = authorize(target);
            server.cancel_send = Some(gate);
            assert!(
                execute(&mut store, &mut server, permit).err()
                    == Some(Failure::Authentication(local_auth::Failure::Cancelled))
            );
        }
        let candidate = memory.slot(Slot::KeyMutation).unwrap();
        let (_gate, presentation, suffix) = shown(&mut store, &mut server);
        store
            .transaction_with(|o| {
                disclosure::confirm_saved_locked(o, &mut server, presentation, suffix)
            })
            .unwrap();
        assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == candidate.as_slice());
        let target = prepare(&mut store, &mut server, false).unwrap();
        let (_gate, permit) = authorize(target);
        assert!(
            execute(&mut store, &mut server, permit).unwrap() == actions::Outcome::RecoveryReady
        );
        inactive(&memory);
    }
}

#[test]
fn cancelled_wrong_target_and_changed_archive_permits_cannot_sign_or_send() {
    for mode in 0..3 {
        for approval in [false, true] {
            let (_temp, mut store, mut server, memory) = fixture();
            let mut target = prepare(&mut store, &mut server, approval).unwrap();
            if mode == 1 {
                target = Target::new(server.core.pin.clone(), Purpose::RevealRecovery, 1, [1; 32])
                    .unwrap();
            }
            let (mut gate, permit) = authorize(target);
            if mode == 0 {
                gate.cancel();
            }
            if mode == 2 {
                store
                    .transaction_with::<_, Failure>(|o| {
                        let mut a = Archive::load(o)?;
                        a.save(o)
                    })
                    .unwrap();
            }
            let original = memory.slot(Slot::KeyMutation).unwrap();
            let expected = if mode == 0 {
                local_auth::Failure::Cancelled
            } else {
                local_auth::Failure::WrongTarget
            };
            assert!(
                execute(&mut store, &mut server, permit).err()
                    == Some(Failure::Authentication(expected))
            );
            assert!(server.challenges == 0 && server.sent.is_empty());
            assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
        }
    }
}

#[test]
fn cancellation_during_challenge_or_send_preflight_stops_the_mutation() {
    for during_send in [false, true] {
        for approval in [false, true] {
            let (_temp, mut store, mut server, memory) = fixture();
            let target = prepare(&mut store, &mut server, approval).unwrap();
            let (gate, permit) = authorize(target);
            if during_send {
                server.cancel_send = Some(gate);
            } else {
                server.cancel_challenge = Some(gate);
            }
            assert!(
                execute(&mut store, &mut server, permit).err()
                    == Some(Failure::Authentication(local_auth::Failure::Cancelled))
            );
            assert!(server.challenges == 1 && server.sent.is_empty());
            assert!(phase(&memory) == if during_send { "signed" } else { "prepared" });
        }
    }
}

#[test]
fn a_foreign_challenge_is_rejected_before_the_signature_is_persisted() {
    let (_temp, mut store, mut server, memory) = fixture();
    let target = prepare(&mut store, &mut server, true).unwrap();
    let (_gate, permit) = authorize(target);
    server.wrong_challenge = true;
    let original = memory.slot(Slot::KeyMutation).unwrap();
    assert!(execute(&mut store, &mut server, permit).err() == Some(Failure::ReviewRequired));
    assert!(server.sent.is_empty() && phase(&memory) == "prepared");
    assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
}

#[test]
fn role_downgrade_prior_recovery_change_and_scope_change_preserve_the_prepared_intent() {
    for mode in 0..3 {
        let (_temp, mut store, mut server, memory) = fixture();
        let target = prepare(&mut store, &mut server, false).unwrap();
        let (_gate, permit) = authorize(target);
        match mode {
            0 => server.core.role = Role::Writer,
            1 => server.core.recovery.as_mut().unwrap().ciphertext[0] ^= 1,
            _ => server.core.pin.dataset = Binding::from_checkpoint([99; 32]),
        }
        let original = memory.slot(Slot::KeyMutation).unwrap();
        assert!(execute(&mut store, &mut server, permit).is_err());
        assert!(server.challenges == 0 && server.sent.is_empty());
        assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
    }
}

#[test]
fn acknowledgement_is_saved_before_a_post_send_scope_mismatch_halts_completion() {
    let (_temp, mut store, mut server, memory) = fixture();
    let target = prepare(&mut store, &mut server, true).unwrap();
    let (_gate, permit) = authorize(target);
    server.change_after_send = true;
    assert!(execute(&mut store, &mut server, permit).err() == Some(Failure::ReviewRequired));
    assert!(phase(&memory) == "acknowledged" && server.sent.len() == 1);
    let original = memory.slot(Slot::KeyMutation).unwrap();
    assert!(reconcile(&mut store, &mut server).err() == Some(Failure::ReviewRequired));
    assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
}

#[test]
fn only_unsigned_drafts_can_be_cancelled_and_pending_intent_fences_key_activation() {
    let (_temp, mut store, mut server, memory) = fixture();
    prepare(&mut store, &mut server, true).unwrap();
    assert!(
        store
            .transaction_with(|o| load_locked(o, &mut server))
            .err()
            == Some(Failure::Busy)
    );
    let pin = server.core.pin.clone();
    store
        .transaction_with(|o| actions::cancel_locked(o, &pin))
        .unwrap();
    inactive(&memory);
    let target = prepare(&mut store, &mut server, false).unwrap();
    let (_gate, permit) = authorize(target);
    server.lose_reply = true;
    assert!(execute(&mut store, &mut server, permit).err() == Some(Server::network()));
    let original = memory.slot(Slot::KeyMutation).unwrap();
    assert!(
        store
            .transaction_with(|o| actions::cancel_locked(o, &pin))
            .err()
            == Some(Failure::Busy)
    );
    assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == original.as_slice());
}

#[test]
fn malformed_or_mixed_journal_shapes_fail_closed_without_replacing_saved_bytes() {
    let (_temp, mut store, mut server, memory) = fixture();
    prepare(&mut store, &mut server, false).unwrap();
    let original = memory.slot(Slot::KeyMutation).unwrap();
    for mode in 0..8 {
        let mut v: JSON = serde_json::from_slice(&original).unwrap();
        match mode {
            0 => v["schema"] = json!(2),
            1 => v["generation"] = json!(0),
            2 => v["phase"]["kind"] = json!("inactive"),
            3 => v["phase"]["version"] = json!(2),
            4 => v["intent"]["priorHash"] = JSON::Null,
            5 => v["intent"]["ciphertext"] = json!(STANDARD.encode([0; 32])),
            6 => v["intent"]["unknown"] = json!(true),
            _ => v["authority"] = json!(STANDARD.encode([0; 32])),
        }
        let bytes = serde_json::to_vec(&v).unwrap();
        store
            .transaction(|o| o.replace(Slot::KeyMutation, Some(&original), Some(&bytes)))
            .unwrap();
        assert!(prepare(&mut store, &mut server, false).is_err());
        assert!(memory.slot(Slot::KeyMutation).unwrap().as_slice() == bytes.as_slice());
        store
            .transaction(|o| o.replace(Slot::KeyMutation, Some(&bytes), Some(&original)))
            .unwrap();
    }
    assert!(server.challenges == 0 && server.sent.is_empty());
}

#[test]
fn saved_signature_must_match_the_retained_intent_and_an_inactive_authority_pin_cannot_change() {
    for active in [false, true] {
        let (_temp, mut store, mut server, memory) = fixture();
        let target = prepare(&mut store, &mut server, true).unwrap();
        let (gate, permit) = authorize(target);
        if active {
            server.cancel_send = Some(gate);
        }
        let result = execute(&mut store, &mut server, permit);
        if active {
            assert!(result.err() == Some(Failure::Authentication(local_auth::Failure::Cancelled)));
        } else {
            assert!(result.unwrap() == actions::Outcome::ApprovalAcknowledged);
        }
        let original = memory.slot(Slot::KeyMutation).unwrap();
        let mut v: JSON = serde_json::from_slice(&original).unwrap();
        if active {
            v["intent"]["ciphertext"] = json!(STANDARD.encode([0; 40]));
        } else {
            v["authority"] = json!(STANDARD.encode([0; 32]));
        }
        let corrupt = serde_json::to_vec(&v).unwrap();
        store
            .transaction(|o| o.replace(Slot::KeyMutation, Some(&original), Some(&corrupt)))
            .unwrap();
        let calls = server.challenges;
        assert!(prepare(&mut store, &mut server, true).is_err());
        assert!(
            server.challenges == calls
                && memory.slot(Slot::KeyMutation).unwrap().as_slice() == corrupt.as_slice()
        );
    }
}

#[cfg(feature = "desktop")]
#[test]
fn losing_the_native_worker_reply_keeps_the_acknowledged_mutation_durable() {
    use crate::account_worker::{Command, Failure as AccountFailure, Handle, Reply};
    let (_temp, mut store, mut server, memory) = fixture();
    let root = memory.slot(Slot::LibraryKey).unwrap();
    let target = prepare(&mut store, &mut server, true).unwrap();
    let (_gate, permit) = authorize(target);
    let worker = Handle::controlled(move |command| {
        let reply = match command {
            Command::Mutate(permit) => execute(&mut store, &mut server, permit)
                .map(|outcome| Reply::Mutation {
                    state: Ok(None),
                    outcome: Some(outcome),
                    failure: None,
                })
                .map_err(AccountFailure::from),
            Command::Inspect => {
                assert!(phase(&server.core.memory) == "inactive" && server.sent.len() == 1);
                Ok(Reply::Profile {
                    email: None,
                    server: None,
                    interrupted: false,
                    switching: crate::key_store::handover::Status::default(),
                })
            }
            _ => Err(AccountFailure::InvalidState),
        };
        (reply, false)
    });
    drop(worker.request(Command::Mutate(permit)).unwrap());
    let barrier = worker.request(Command::Inspect).unwrap();
    assert!(matches!(
        barrier
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap(),
        Ok(Reply::Profile { .. })
    ));
    assert!(worker.can_quit());
    inactive(&memory);
    assert!(memory.slot(Slot::LibraryKey).unwrap().as_slice() == root.as_slice());
}
