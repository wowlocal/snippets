use super::*;
use crate::bootstrap::{Authority, AuthorityContext, Bundle};
use serde_json::json;

fn server() -> ServerURL {
    ServerURL::parse("https://sync.example").unwrap()
}
fn scope() -> Scope {
    Scope {
        server_instance_id: Uuid::from_u128(1),
        space_id: Uuid::from_u128(2),
        scope_binding: "public-fictional-membership-binding".into(),
        dataset_generation: Uuid::from_u128(3),
        feed_epoch: Uuid::from_u128(4),
    }
}
fn authority() -> Authority {
    let material: Vec<_> = (0..64).collect();
    Authority::new(
        &Bundle::from_material(&material).unwrap(),
        &AuthorityContext::new(server(), scope().server_instance_id, scope().space_id).unwrap(),
    )
}
fn challenge(mutation: Mutation) -> ActionChallenge {
    let expires = (chrono::Utc::now() + chrono::Duration::seconds(300)).to_rfc3339();
    ActionChallenge {
        server: server(),
        scope: scope(),
        mutation,
        public: authority().public_key(),
        id: Uuid::from_u128(5),
        nonce: [9; 32],
        deadline: Deadline::admit(&expires, SystemTime::now(), crate::clock::uptime().unwrap())
            .unwrap(),
        expires,
    }
}
fn sign(c: ActionChallenge) -> SignedAction {
    let proof = authority().sign(c.id(), c.nonce()).unwrap();
    c.authorize(proof).unwrap()
}
#[test]
fn recovery_journal_round_trip_keeps_exact_cas_ciphertext_nonce_signature_and_scope() {
    for version in [None, Some(5)] {
        let signed = sign(challenge(Mutation::recovery(1, version, &[7; 40]).unwrap()));
        let bytes = signed.encode_secret().unwrap();
        let restored = SignedAction::decode_secret(&bytes).unwrap();
        assert!(signed.challenge.scope == restored.challenge.scope);
        assert!(signed.challenge.server == restored.challenge.server);
        assert!(
            signed.signature == restored.signature
                && signed.challenge.nonce == restored.challenge.nonce
        );
        assert!(
            signed.challenge.mutation.body(&signed.proof()).unwrap()
                == restored.challenge.mutation.body(&restored.proof()).unwrap()
        );
        assert!(bytes == restored.encode_secret().unwrap());
        let body: serde_json::Value =
            serde_json::from_slice(&restored.challenge.mutation.body(&restored.proof()).unwrap())
                .unwrap();
        assert!(body["expectedVersion"] == json!(version));
    }
}
#[test]
fn approval_journal_round_trip_keeps_recipient_nonce_invitation_and_exact_body() {
    let draft = PairingDraft::generate().unwrap();
    let invitation = Invitation::new(
        server(),
        scope().space_id,
        Uuid::from_u128(6),
        *draft.nonce(),
        *draft.public_key(),
        unix_now().unwrap() + 300,
        unix_now().unwrap(),
    )
    .unwrap();
    let signed = sign(challenge(
        Mutation::approval(1, invitation, &[7; 40]).unwrap(),
    ));
    let bytes = signed.encode_secret().unwrap();
    let restored = SignedAction::decode_secret(&bytes).unwrap();
    assert!(bytes == restored.encode_secret().unwrap());
    assert!(
        signed.challenge.mutation.body(&signed.proof()).unwrap()
            == restored.challenge.mutation.body(&restored.proof()).unwrap()
    );
}
#[test]
fn journal_rejects_tampered_proofs_payloads_bindings_expiry_and_open_shapes() {
    let signed = sign(challenge(Mutation::recovery(1, Some(5), &[7; 40]).unwrap()));
    let value: serde_json::Value =
        serde_json::from_slice(&signed.encode_secret().unwrap()).unwrap();
    for index in 0..19 {
        let mut v = value.clone();
        match index {
            0 => v["schemaVersion"] = json!(2),
            1 => v["challengeId"] = json!(Uuid::nil()),
            2 => v["nonce"] = json!(STANDARD.encode([8; 32])),
            3 => v["signature"] = json!(STANDARD.encode([0; 64])),
            4 => v["publicKey"] = json!(STANDARD.encode([0; 32])),
            5 => v["requestHash"] = json!(STANDARD.encode([0; 32])),
            6 => v["mutation"]["ciphertext"] = json!(STANDARD.encode([8; 40])),
            7 => v["mutation"]["expectedVersion"] = json!(0),
            8 => v["keyEpoch"] = json!(0),
            9 => v["keyEpoch"] = json!(u64::MAX),
            10 => v["scope"]["datasetGeneration"] = json!(Uuid::nil()),
            11 => v["expiresAt"] = json!("not-a-date"),
            12 => {
                v["expiresAt"] =
                    json!((chrono::Utc::now() + chrono::Duration::seconds(400)).to_rfc3339())
            }
            13 => v["server"] = json!("http://sync.example"),
            14 => v["server"] = json!("https://SYNC.example/"),
            15 => v["unexpected"] = json!(true),
            16 => v["mutation"]["unexpected"] = json!(true),
            17 => {
                v["mutation"]
                    .as_object_mut()
                    .unwrap()
                    .remove("expectedVersion");
            }
            _ => v["nonce"] = json!(format!("{}=", STANDARD.encode([9; 32]))),
        }
        assert!(
            SignedAction::decode_secret(&serde_json::to_vec(&v).unwrap()).is_err(),
            "mutation {index}"
        );
    }
    assert!(
        SignedAction::decode_secret(&vec![0; MAX_AUTH + 1]).err() == Some(Failure::MessageTooLarge)
    );
    assert!(SignedAction::decode_secret(b"{\"schemaVersion\":1,\"schemaVersion\":1}").is_err());
}

#[test]
fn expired_retained_proofs_stay_inspectable_without_authorizing_replay() {
    let signed = sign(challenge(Mutation::recovery(1, Some(5), &[7; 40]).unwrap()));
    let mut value: serde_json::Value =
        serde_json::from_slice(&signed.encode_secret().unwrap()).unwrap();
    value["expiresAt"] = json!((chrono::Utc::now() - chrono::Duration::seconds(600)).to_rfc3339());
    let restored = SignedAction::decode_secret(&serde_json::to_vec(&value).unwrap()).unwrap();
    assert!(!restored.replay_allowed());
    let (epoch, version, ciphertext) = restored.expected_recovery().unwrap();
    assert!(epoch == 1 && version == Some(5) && ciphertext == [7; 40]);
    assert!(restored.challenge.deadline.check().is_err());
    assert!(SignedAction::decode_secret(&restored.encode_secret().unwrap()).is_ok());
    let draft = PairingDraft::generate().unwrap();
    let invitation = Invitation::new(
        server(),
        scope().space_id,
        Uuid::from_u128(6),
        *draft.nonce(),
        *draft.public_key(),
        unix_now().unwrap() + 300,
        unix_now().unwrap(),
    )
    .unwrap();
    let signed = sign(challenge(
        Mutation::approval(1, invitation, &[7; 40]).unwrap(),
    ));
    let mut value: serde_json::Value =
        serde_json::from_slice(&signed.encode_secret().unwrap()).unwrap();
    let mut qr: serde_json::Value =
        serde_json::from_str(value["mutation"]["invitation"].as_str().unwrap()).unwrap();
    qr["expiresAt"] = json!(unix_now().unwrap() - 600);
    value["mutation"]["invitation"] = json!(serde_json::to_string(&qr).unwrap());
    value["expiresAt"] = json!((chrono::Utc::now() - chrono::Duration::seconds(600)).to_rfc3339());
    let restored = SignedAction::decode_secret(&serde_json::to_vec(&value).unwrap()).unwrap();
    assert!(!restored.replay_allowed() && restored.expected_pairing().is_some());
}
#[test]
fn proof_authorization_refuses_another_challenge_or_another_private_key() {
    let c = challenge(Mutation::recovery(1, None, &[7; 40]).unwrap());
    let wrong_id = authority().sign(Uuid::from_u128(9), c.nonce()).unwrap();
    assert!(c.authorize(wrong_id).is_err());
    let c = challenge(Mutation::recovery(1, None, &[7; 40]).unwrap());
    let wrong_authority = Authority::new(
        &Bundle::from_material(&[3; 64]).unwrap(),
        &AuthorityContext::new(server(), Uuid::from_u128(1), Uuid::from_u128(2)).unwrap(),
    );
    let proof = wrong_authority.sign(c.id(), c.nonce()).unwrap();
    assert!(c.authorize(proof).is_err());
}
#[test]
fn live_proofs_expire_on_either_clock_and_long_or_invalid_server_dates_fail_closed() {
    let uptime = crate::clock::uptime().unwrap();
    let now = SystemTime::now();
    let future = (chrono::Utc::now() + chrono::Duration::seconds(300)).to_rfc3339();
    assert!(
        Deadline::admit(&future, now, uptime)
            .unwrap()
            .check()
            .is_ok()
    );
    assert!(
        Deadline {
            wall: now + Duration::from_secs(300),
            monotonic: Duration::ZERO
        }
        .check()
        .is_err()
    );
    assert!(
        Deadline {
            wall: now - Duration::from_secs(1),
            monotonic: uptime + Duration::from_secs(300)
        }
        .check()
        .is_err()
    );
    let future = (chrono::Utc::now() + chrono::Duration::seconds(331)).to_rfc3339();
    assert!(Deadline::admit(&future, now, uptime).is_err());
    for text in [
        "2026-09-30",
        "2026-09-30T12:00:60Z",
        "not-a-date",
        "1969-12-31T23:59:59Z",
    ] {
        assert!(parse_date(text).is_err());
    }
}
