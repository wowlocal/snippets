//! Independent public-only pairing/challenge peer for two native installations.
use super::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

#[derive(Default)]
pub(in super::super) struct State {
    access: BTreeSet<String>,
    refresh: BTreeSet<String>,
    invitations: BTreeMap<uuid::Uuid, Invitation>,
    challenges: BTreeMap<uuid::Uuid, Challenge>,
    creates: usize,
    cancels: usize,
    claims: usize,
    approvals: usize,
    accepted: usize,
    recovery_posts: usize,
    recovery_accepted: usize,
    lose_approval: bool,
    lose_recovery: bool,
    lost_reply: bool,
}
struct Invitation {
    scope: Value,
    public: [u8; 65],
    nonce: [u8; 32],
    expires: i64,
    ciphertext: Option<String>,
}
struct Challenge {
    scope: Value,
    action: Action,
    hash: String,
    nonce: [u8; 32],
    expires: i64,
    receipt: Option<Value>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Action {
    Approval,
    Recovery,
}
impl State {
    pub fn recovery_counts(&self) -> (usize, usize, usize) {
        (
            self.challenges
                .values()
                .filter(|challenge| challenge.action == Action::Recovery)
                .count(),
            self.recovery_posts,
            self.recovery_accepted,
        )
    }
    pub fn lose_next_recovery_reply(&mut self) {
        self.lose_recovery = true;
    }
    pub fn counts(&self) -> (usize, usize, usize, usize, usize, usize) {
        (
            self.creates,
            self.cancels,
            self.claims,
            self.challenges.len(),
            self.approvals,
            self.accepted,
        )
    }
    pub fn lose_next_approval_reply(&mut self) {
        self.lose_approval = true;
    }
    pub(super) fn take_lost_reply(&mut self) -> bool {
        std::mem::take(&mut self.lost_reply)
    }
    pub(super) fn grant(&mut self, n: usize) {
        assert!(
            self.access
                .insert(format!("Bearer public-native-access-{n}"))
        );
        assert!(self.refresh.insert(format!("public-native-refresh-{n}")));
    }
    pub(super) fn refresh(&mut self, token: &str) {
        assert!(self.refresh.remove(token));
    }
    pub(super) fn revoke(&mut self, token: &str) {
        self.refresh.remove(token);
        self.access.remove(&format!("Bearer {token}"));
    }
    pub(super) fn authorized(&self, token: &str) -> bool {
        self.access.contains(token)
    }
}
fn bytes<const N: usize>(v: &Value) -> [u8; N] {
    STANDARD
        .decode(v.as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap()
}
fn reply(id: uuid::Uuid, v: &Invitation) -> Value {
    let mut digest = Sha256::new();
    digest.update(b"snippets-pairing-confirm-v1");
    digest.update(v.nonce);
    digest.update(v.public);
    let alphabet = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let tag: String = digest.finalize()[..8]
        .iter()
        .map(|b| alphabet[(b & 31) as usize] as char)
        .collect();
    json!({"scope":v.scope,"pairing":{"pairingId":id,"recipientPublicKey":STANDARD.encode(v.public),
        "nonce":STANDARD.encode(v.nonce),"authenticationTag":tag,
        "state":if v.ciphertext.is_some(){"approved"}else{"pending"},
        "expiresAt":chrono::DateTime::from_timestamp(v.expires,0).unwrap().to_rfc3339()}})
}
fn verified(
    state: &mut State,
    body: &Value,
    public: &Value,
    action: Action,
    hash: &str,
    response_scope: &Value,
    now: i64,
) -> bool {
    let proof = &body["proof"];
    assert!(proof.as_object().unwrap().len() == 2);
    let id = uuid::Uuid::parse_str(proof["challengeId"].as_str().unwrap()).unwrap();
    let challenge = state.challenges.get_mut(&id).unwrap();
    assert!(challenge.scope == *response_scope);
    assert!(challenge.action == action && challenge.hash == hash && challenge.expires > now);
    let public = bytes(public);
    let signature = ed25519_dalek::Signature::from_bytes(&bytes(&proof["signature"]));
    let mut message = b"snippets-library-action-proof-v1\n".to_vec();
    message.extend_from_slice(&challenge.nonce);
    ed25519_dalek::VerifyingKey::from_bytes(&public)
        .unwrap()
        .verify_strict(&message, &signature)
        .unwrap();
    if let Some(receipt) = &challenge.receipt {
        assert!(receipt == body);
        true
    } else {
        challenge.receipt = Some(body.clone());
        false
    }
}
pub(super) fn respond(
    request: Request,
    owner: &mut super::State,
    base: &str,
    response_scope: &Value,
) -> (u16, Value) {
    let state = owner.pairing.as_mut().unwrap();
    let now = chrono::Utc::now().timestamp();
    if request.path == format!("{base}/pairings") {
        assert!(request.method == "POST");
        assert!(
            request.body.as_object().unwrap().len() == 3 && request.body["expiresInSeconds"] == 300
        );
        let public = bytes(&request.body["recipientPublicKey"]);
        p256::PublicKey::from_sec1_bytes(&public).unwrap();
        state.creates += 1;
        let id = uuid::Uuid::from_u128(600 + state.creates as u128);
        let invitation = Invitation {
            scope: response_scope.clone(),
            public,
            nonce: bytes(&request.body["nonce"]),
            expires: now + 300,
            ciphertext: None,
        };
        let response = reply(id, &invitation);
        assert!(state.invitations.insert(id, invitation).is_none());
        return (201, response);
    }
    if request.path == format!("{base}/key-challenges") {
        assert!(request.method == "POST" && request.body.as_object().unwrap().len() == 4);
        assert!(request.body["expectedScope"] == *response_scope && request.body["keyEpoch"] == 1);
        assert!(owner.public.is_some());
        let action = match request.body["action"].as_str().unwrap() {
            "approve_pairing" => Action::Approval,
            "replace_recovery" => Action::Recovery,
            _ => panic!("unexpected native fixture signed action"),
        };
        let _: [u8; 32] = bytes(&request.body["requestHash"]);
        let id = uuid::Uuid::from_u128(700 + state.challenges.len() as u128);
        let nonce: [u8; 32] =
            Sha256::digest(format!("public-native-pairing-challenge-{id}").as_bytes()).into();
        let expires = now + 300;
        let hash = request.body["requestHash"].as_str().unwrap().to_owned();
        let response = json!({"scope":response_scope,"challenge":{"challengeId":id,"action":request.body["action"],
            "keyEpoch":1,"requestHash":hash,"nonce":STANDARD.encode(nonce),
            "expiresAt":chrono::DateTime::from_timestamp(expires,0).unwrap().to_rfc3339()}});
        assert!(
            state
                .challenges
                .insert(
                    id,
                    Challenge {
                        scope: response_scope.clone(),
                        action,
                        hash,
                        nonce,
                        expires,
                        receipt: None
                    }
                )
                .is_none()
        );
        return (200, response);
    }
    if request.path == format!("{base}/recovery-envelope") {
        assert!(request.method == "PUT" && request.body.as_object().unwrap().len() == 5);
        assert!(
            request.body["keyEpoch"] == 1
                && request.body["algorithm"] == "snippets-recovery-hkdf-sha256-aes256gcm-v1"
        );
        let prior = request.body["expectedVersion"].as_u64().unwrap();
        let cipher = request.body["ciphertext"].as_str().unwrap();
        let decoded = STANDARD.decode(cipher).unwrap();
        assert!((28..=4096).contains(&decoded.len()));
        let input = [
            "snippets-recovery-action-v1",
            "1",
            &prior.to_string(),
            "snippets-recovery-hkdf-sha256-aes256gcm-v1",
            cipher,
        ]
        .join("\n");
        let hash = STANDARD.encode(Sha256::digest(input.as_bytes()));
        let replay = verified(
            state,
            &request.body,
            owner.public.as_ref().unwrap(),
            Action::Recovery,
            &hash,
            response_scope,
            now,
        );
        if replay {
            assert!(
                owner.recovery_version == prior + 1
                    && owner.ciphertext.as_ref() == Some(&request.body["ciphertext"])
            );
        } else {
            assert!(
                owner.recovery_version == prior
                    && owner.ciphertext.as_ref() != Some(&request.body["ciphertext"])
            );
            owner.ciphertext = Some(request.body["ciphertext"].clone());
            owner.recovery_version += 1;
            state.recovery_accepted += 1;
        }
        state.recovery_posts += 1;
        state.lost_reply = std::mem::take(&mut state.lose_recovery);
        return (200, recovery(owner, response_scope));
    }
    let path = request
        .path
        .strip_prefix(&format!("{base}/pairings/"))
        .unwrap();
    let mut parts = path.split('/');
    let id = uuid::Uuid::parse_str(parts.next().unwrap()).unwrap();
    let operation = parts.next();
    assert!(parts.next().is_none());
    assert!(state.invitations.get(&id).unwrap().scope == *response_scope);
    if request.method == "DELETE" {
        assert!(operation.is_none() && request.body.is_null());
        assert!(state.invitations.remove(&id).is_some());
        state.cancels += 1;
        return (204, Value::Null);
    }
    let invitation = state.invitations.get(&id).unwrap();
    assert!(invitation.expires > now);
    match operation {
        None => {
            assert!(request.method == "GET" && request.body.is_null());
            (200, reply(id, invitation))
        }
        Some("claim") => {
            assert!(request.method == "POST" && request.body.is_null());
            let ciphertext = invitation.ciphertext.as_ref().unwrap();
            state.claims += 1;
            (
                200,
                json!({"scope":response_scope,"pairingId":id,"algorithm":bootstrap::PAIRING_ALGORITHM,"ciphertext":ciphertext}),
            )
        }
        Some("approval") => {
            assert!(request.method == "PUT" && request.body.as_object().unwrap().len() == 4);
            assert!(request.body["algorithm"] == "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1");
            let recipient_hash = STANDARD.encode(Sha256::digest(invitation.public));
            assert!(request.body["recipientKeyHash"] == recipient_hash);
            let cipher = request.body["ciphertext"].as_str().unwrap();
            let decoded = STANDARD.decode(cipher).unwrap();
            assert!((28..=4096).contains(&decoded.len()));
            let input = [
                "snippets-pairing-action-v1",
                &id.to_string(),
                &recipient_hash,
                "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1",
                cipher,
            ]
            .join("\n");
            let hash = STANDARD.encode(Sha256::digest(input.as_bytes()));
            let replay = verified(
                state,
                &request.body,
                owner.public.as_ref().unwrap(),
                Action::Approval,
                &hash,
                response_scope,
                now,
            );
            let invitation = state.invitations.get_mut(&id).unwrap();
            if replay {
                assert!(invitation.ciphertext.as_deref() == Some(cipher));
            } else {
                assert!(invitation.ciphertext.is_none());
                invitation.ciphertext = Some(cipher.to_owned());
                state.accepted += 1;
            }
            state.approvals += 1;
            state.lost_reply = std::mem::take(&mut state.lose_approval);
            (200, reply(id, invitation))
        }
        _ => panic!("unexpected native pairing fixture route"),
    }
}
