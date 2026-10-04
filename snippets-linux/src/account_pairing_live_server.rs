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
    lose_approval: bool,
    lost_reply: bool,
}
struct Invitation {
    public: [u8; 65],
    nonce: [u8; 32],
    expires: i64,
    ciphertext: Option<String>,
}
struct Challenge {
    hash: String,
    nonce: [u8; 32],
    expires: i64,
    receipt: Option<Value>,
}
impl State {
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
    json!({"scope":scope(),"pairing":{"pairingId":id,"recipientPublicKey":STANDARD.encode(v.public),
        "nonce":STANDARD.encode(v.nonce),"authenticationTag":tag,
        "state":if v.ciphertext.is_some(){"approved"}else{"pending"},
        "expiresAt":chrono::DateTime::from_timestamp(v.expires,0).unwrap().to_rfc3339()}})
}
pub(super) fn respond(
    request: Request,
    _server: &ServerURL,
    owner: &mut super::State,
) -> (u16, Value) {
    let state = owner.pairing.as_mut().unwrap();
    let base = format!("/v2/spaces/{}", uuid::Uuid::from_u128(2));
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
        assert!(request.body["expectedScope"] == scope() && request.body["keyEpoch"] == 1);
        assert!(request.body["action"] == "approve_pairing" && owner.public.is_some());
        let _: [u8; 32] = bytes(&request.body["requestHash"]);
        let id = uuid::Uuid::from_u128(700 + state.challenges.len() as u128);
        let nonce: [u8; 32] =
            Sha256::digest(format!("public-native-pairing-challenge-{id}").as_bytes()).into();
        let expires = now + 300;
        let hash = request.body["requestHash"].as_str().unwrap().to_owned();
        let response = json!({"scope":scope(),"challenge":{"challengeId":id,"action":"approve_pairing",
            "keyEpoch":1,"requestHash":hash,"nonce":STANDARD.encode(nonce),
            "expiresAt":chrono::DateTime::from_timestamp(expires,0).unwrap().to_rfc3339()}});
        assert!(
            state
                .challenges
                .insert(
                    id,
                    Challenge {
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
    let path = request
        .path
        .strip_prefix(&format!("{base}/pairings/"))
        .unwrap();
    let mut parts = path.split('/');
    let id = uuid::Uuid::parse_str(parts.next().unwrap()).unwrap();
    let operation = parts.next();
    assert!(parts.next().is_none());
    if request.method == "DELETE" {
        assert!(operation.is_none() && request.body.is_null());
        assert!(state.invitations.remove(&id).is_some());
        state.cancels += 1;
        return (204, Value::Null);
    }
    let invitation = state.invitations.get_mut(&id).unwrap();
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
                json!({"scope":scope(),"pairingId":id,"algorithm":bootstrap::PAIRING_ALGORITHM,"ciphertext":ciphertext}),
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
            let proof = &request.body["proof"];
            assert!(proof.as_object().unwrap().len() == 2);
            let challenge_id =
                uuid::Uuid::parse_str(proof["challengeId"].as_str().unwrap()).unwrap();
            let challenge = state.challenges.get_mut(&challenge_id).unwrap();
            assert!(challenge.hash == hash && challenge.expires > now);
            let public = bytes(owner.public.as_ref().unwrap());
            let signature = ed25519_dalek::Signature::from_bytes(&bytes(&proof["signature"]));
            let mut message = b"snippets-library-action-proof-v1\n".to_vec();
            message.extend_from_slice(&challenge.nonce);
            ed25519_dalek::VerifyingKey::from_bytes(&public)
                .unwrap()
                .verify_strict(&message, &signature)
                .unwrap();
            if let Some(receipt) = &challenge.receipt {
                assert!(
                    *receipt == request.body && invitation.ciphertext.as_deref() == Some(cipher)
                );
            } else {
                assert!(invitation.ciphertext.is_none());
                invitation.ciphertext = Some(cipher.to_owned());
                challenge.receipt = Some(request.body);
                state.accepted += 1;
            }
            state.approvals += 1;
            state.lost_reply = std::mem::take(&mut state.lose_approval);
            (200, reply(id, invitation))
        }
        _ => panic!("unexpected native pairing fixture route"),
    }
}
