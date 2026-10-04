//! Actual HTTP exchanges; all keys, scopes and tokens are fictional. The crypto
//! derivation's canonical HTTPS origin is covered separately by public vectors.
use super::*;
use crate::bootstrap::{self, Authority, AuthorityContext, Bundle, Invitation, PairingDraft};
use base64::{Engine, engine::general_purpose::STANDARD};

fn authority() -> Authority {
    Authority::new(
        &Bundle::from_material(&[7; 64]).unwrap(),
        &AuthorityContext::new(
            ServerURL::parse("https://sync.example").unwrap(),
            scope().server_instance_id,
            scope().space_id,
        )
        .unwrap(),
    )
}
fn authority_step() -> Step {
    Step::json(
        json!({"scope":scope(),"keyEpoch":1,"publicKey":STANDARD.encode(authority().public_key())}),
    )
}
fn challenge_response(action: &str, hash: &[u8; 32]) -> Value {
    json!({"scope":scope(),"challenge":{"challengeId":Uuid::from_u128(55),"action":action,"keyEpoch":1,"requestHash":STANDARD.encode(hash),"nonce":STANDARD.encode([9;32]),"expiresAt":(chrono::Utc::now()+chrono::Duration::seconds(300)).to_rfc3339()}})
}
fn authorize(c: ActionChallenge) -> SignedAction {
    let proof = authority().sign(c.id(), c.nonce()).unwrap();
    c.authorize(proof).unwrap()
}
fn invitation(client: &CloudClient, draft: &PairingDraft) -> Invitation {
    let now = chrono::Utc::now().timestamp();
    Invitation::new(
        client.server.clone(),
        scope().space_id,
        Uuid::from_u128(56),
        *draft.nonce(),
        *draft.public_key(),
        now + 300,
        now,
    )
    .unwrap()
}
fn pairing_response(invitation: &Invitation, state: &str) -> Value {
    json!({"scope":scope(),"pairing":{"pairingId":invitation.pairing(),"recipientPublicKey":STANDARD.encode(invitation.public_key()),"nonce":STANDARD.encode(invitation.nonce()),"authenticationTag":invitation.confirmation_code(),"state":state,"expiresAt":chrono::DateTime::from_timestamp(invitation.expires_at(),0).unwrap().to_rfc3339()}})
}

#[test]
fn pairing_create_poll_claim_and_cancel_keep_recipient_binding_and_release_only_at_claim() {
    let draft = PairingDraft::generate().unwrap();
    let ciphertext = [7; 40];
    let (client, worker) = fixture_with(|client| {
        let inv = invitation(client, &draft);
        let mut created = Step::json(pairing_response(&inv, "pending"));
        created.status = 201;
        let mut cancelled = Step::json(json!({}));
        cancelled.status = 204;
        cancelled.body.clear();
        vec![
            space(&scope()),
            created,
            space(&scope()),
            Step::json(pairing_response(&inv, "approved")),
            space(&scope()),
            Step::json(
                json!({"scope":scope(),"pairingId":inv.pairing(),"algorithm":bootstrap::PAIRING_ALGORITHM,"ciphertext":STANDARD.encode(ciphertext)}),
            ),
            space(&scope()),
            cancelled,
        ]
    });
    let mut transport = bound(client);
    let pending = transport.create_pairing(&draft).unwrap();
    assert!(pending.state() == PairingState::Pending);
    assert!(transport.claim_pairing(&pending).err() == Some(Failure::InvalidResponse));
    let approved = transport.pairing(pending.invitation()).unwrap();
    assert!(
        approved.state() == PairingState::Approved && approved.invitation() == pending.invitation()
    );
    assert!(transport.claim_pairing(&approved).unwrap() == ciphertext);
    transport.cancel_pairing(approved.invitation()).unwrap();
    let requests = worker.join().unwrap();
    assert_eq!(requests.len(), 8);
    assert!(requests[1].method == "POST" && requests[1].target.ends_with("/pairings"));
    assert!(
        requests[1].json()
            == json!({"recipientPublicKey":STANDARD.encode(draft.public_key()),"nonce":STANDARD.encode(draft.nonce()),"expiresInSeconds":300})
    );
    assert!(
        requests[3].method == "GET"
            && requests[5].method == "POST"
            && requests[5].target.ends_with("/claim")
            && requests[7].method == "DELETE"
    );
    assert!(
        requests[3].body.is_empty() && requests[5].body.is_empty() && requests[7].body.is_empty()
    );
}

#[test]
fn signed_recovery_lost_response_retries_the_original_proof_cas_and_ciphertext() {
    let ciphertext = [7; 40];
    let hash = bootstrap::recovery_request_hash(1, Some(5), &ciphertext).unwrap();
    let (client, worker) = fixture(vec![
        space(&scope()),
        authority_step(),
        Step::json(challenge_response("replace_recovery", &hash)),
        space(&scope()),
        Step::lost_response(),
        space(&scope()),
        Step::json(recovery_response(&scope(), 6, &ciphertext)),
    ]);
    let mut transport = bound(client);
    let c = transport
        .request_key_challenge(
            Mutation::recovery(1, Some(5), &ciphertext).unwrap(),
            &authority().public_key(),
        )
        .unwrap();
    let signed = authorize(c);
    assert!(transport.replace_recovery(&signed).err() == Some(Failure::Network));
    let receipt = transport.replace_recovery(&signed).unwrap();
    assert!(receipt.version() == 6 && receipt.ciphertext() == ciphertext);
    let requests = worker.join().unwrap();
    assert_eq!(requests.len(), 7);
    assert!(
        requests[2].json()
            == json!({"expectedScope":scope(),"action":"replace_recovery","keyEpoch":1,"requestHash":STANDARD.encode(hash)})
    );
    assert!(requests[4].body == requests[6].body && requests[4].method == "PUT");
    let body = requests[4].json();
    assert!(body["expectedVersion"] == 5 && body["ciphertext"] == STANDARD.encode(ciphertext));
    assert!(body["proof"]["challengeId"] == Uuid::from_u128(55).to_string());
    let signature: [u8; 64] = STANDARD
        .decode(body["proof"]["signature"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    let mut message = b"snippets-library-action-proof-v1\n".to_vec();
    message.extend_from_slice(&[9; 32]);
    ed25519_dalek::VerifyingKey::from_bytes(&authority().public_key())
        .unwrap()
        .verify_strict(&message, &ed25519_dalek::Signature::from_bytes(&signature))
        .unwrap();
}

#[test]
fn signed_pairing_approval_uses_exact_recipient_hash_and_returns_only_redacted_state() {
    let draft = PairingDraft::generate().unwrap();
    let ciphertext = [7; 40];
    let mut expected_invitation = None;
    let (client, worker) = fixture_with(|client| {
        let inv = invitation(client, &draft);
        expected_invitation = Some(inv.clone());
        let hash =
            bootstrap::pairing_request_hash(inv.pairing(), inv.public_key(), &ciphertext).unwrap();
        vec![
            space(&scope()),
            authority_step(),
            Step::json(challenge_response("approve_pairing", &hash)),
            space(&scope()),
            Step::json(pairing_response(&inv, "approved")),
        ]
    });
    let inv = expected_invitation.unwrap();
    let mut transport = bound(client);
    let signed = authorize(
        transport
            .request_key_challenge(
                Mutation::approval(1, inv, &ciphertext).unwrap(),
                &authority().public_key(),
            )
            .unwrap(),
    );
    assert!(transport.replace_recovery(&signed).err() == Some(Failure::InvalidResponse));
    let receipt = transport.approve_pairing(&signed).unwrap();
    assert!(receipt.state() == PairingState::Approved);
    let requests = worker.join().unwrap();
    assert_eq!(requests.len(), 5);
    assert!(requests[2].json()["action"] == "approve_pairing");
    assert!(requests[4].method == "PUT" && requests[4].target.ends_with("/approval"));
    let body = requests[4].json();
    assert!(
        body["recipientKeyHash"]
            == STANDARD.encode(bootstrap::recipient_key_hash(draft.public_key()).unwrap())
    );
    assert!(
        body["algorithm"] == bootstrap::PAIRING_ALGORITHM
            && body["ciphertext"] == STANDARD.encode(ciphertext)
    );
}

#[test]
fn challenge_rejects_changed_action_hash_nonce_expiry_identity_epoch_and_full_scope() {
    let ciphertext = [7; 40];
    let hash = bootstrap::recovery_request_hash(1, Some(5), &ciphertext).unwrap();
    for index in 0..13 {
        let mut response = challenge_response("replace_recovery", &hash);
        let expected = match index {
            0 => {
                response["challenge"]["action"] = json!("approve_pairing");
                Failure::InvalidResponse
            }
            1 => {
                response["challenge"]["requestHash"] = json!(STANDARD.encode([0; 32]));
                Failure::InvalidResponse
            }
            2 => {
                response["challenge"]["nonce"] = json!(STANDARD.encode([0; 31]));
                Failure::InvalidResponse
            }
            3 => {
                response["challenge"]["expiresAt"] =
                    json!((chrono::Utc::now() - chrono::Duration::seconds(1)).to_rfc3339());
                Failure::InvalidResponse
            }
            4 => {
                response["challenge"]["expiresAt"] =
                    json!((chrono::Utc::now() + chrono::Duration::seconds(400)).to_rfc3339());
                Failure::InvalidResponse
            }
            5 => {
                response["challenge"]["challengeId"] = json!(Uuid::nil());
                Failure::InvalidResponse
            }
            6 => {
                response["challenge"]["keyEpoch"] = json!(2);
                Failure::DatasetReview
            }
            7 => {
                response["scope"]["serverInstanceId"] = json!(Uuid::from_u128(99));
                Failure::AccountReview
            }
            8 => {
                response["scope"]["scopeBinding"] = json!("another-fictional-membership-binding");
                Failure::AccountReview
            }
            9 => {
                response["scope"]["datasetGeneration"] = json!(Uuid::from_u128(99));
                Failure::DatasetReview
            }
            10 => {
                response["scope"]["feedEpoch"] = json!(Uuid::from_u128(99));
                Failure::InvalidResponse
            }
            11 => {
                response["challenge"]["unexpected"] = json!(true);
                Failure::InvalidResponse
            }
            _ => {
                response["challenge"]["requestHash"] = json!(format!("{}=", STANDARD.encode(hash)));
                Failure::InvalidResponse
            }
        };
        let (client, worker) = fixture(vec![
            space(&scope()),
            authority_step(),
            Step::json(response),
        ]);
        let mut transport = bound(client);
        assert!(
            transport
                .request_key_challenge(
                    Mutation::recovery(1, Some(5), &ciphertext).unwrap(),
                    &authority().public_key()
                )
                .err()
                == Some(expected),
            "mutation {index}"
        );
        if matches!(expected, Failure::AccountReview | Failure::DatasetReview) {
            assert!(transport.fetch_page(None).err() == Some(expected));
        }
        assert_eq!(worker.join().unwrap().len(), 3);
    }
}

#[test]
fn authority_mismatch_absence_and_read_only_role_stop_before_challenge_issuance() {
    for index in 0..3 {
        let mut observed = space(&scope());
        let mut authority = authority_step();
        if index == 0 {
            authority = Step::json(
                json!({"scope":scope(),"keyEpoch":1,"publicKey":STANDARD.encode(bootstrap_public())}),
            );
        }
        if index == 1 {
            authority = Step::json(json!({"scope":scope(),"keyEpoch":1,"publicKey":null}));
        }
        if index == 2 {
            observed = Step::json(json!({"scope":scope(),"keyEpoch":1,"role":"reader"}));
        }
        let (client, worker) = fixture(vec![observed, authority]);
        let expected = if index == 2 {
            Failure::ReadOnly
        } else {
            Failure::InvalidResponse
        };
        assert!(
            bound(client)
                .request_key_challenge(
                    Mutation::recovery(1, Some(5), &[7; 40]).unwrap(),
                    &self::authority().public_key()
                )
                .err()
                == Some(expected)
        );
        assert_eq!(worker.join().unwrap().len(), 2);
    }
}

#[test]
fn writer_can_approve_pairing_but_recovery_replacement_requires_the_owner_role() {
    let writer = || Step::json(json!({"scope":scope(),"keyEpoch":1,"role":"writer"}));
    let (client, worker) = fixture(vec![writer(), authority_step()]);
    assert!(
        bound(client)
            .request_key_challenge(
                Mutation::recovery(1, Some(5), &[7; 40]).unwrap(),
                &authority().public_key()
            )
            .err()
            == Some(Failure::ReadOnly)
    );
    assert_eq!(worker.join().unwrap().len(), 2);
    let draft = PairingDraft::generate().unwrap();
    let mut expected_invitation = None;
    let (client, worker) = fixture_with(|client| {
        let inv = invitation(client, &draft);
        expected_invitation = Some(inv.clone());
        let hash =
            bootstrap::pairing_request_hash(inv.pairing(), inv.public_key(), &[7; 40]).unwrap();
        vec![
            writer(),
            authority_step(),
            Step::json(challenge_response("approve_pairing", &hash)),
            writer(),
            Step::json(pairing_response(&inv, "approved")),
        ]
    });
    let mut transport = bound(client);
    let signed = authorize(
        transport
            .request_key_challenge(
                Mutation::approval(1, expected_invitation.unwrap(), &[7; 40]).unwrap(),
                &authority().public_key(),
            )
            .unwrap(),
    );
    assert!(transport.approve_pairing(&signed).unwrap().state() == PairingState::Approved);
    assert_eq!(worker.join().unwrap().len(), 5);
}

#[test]
fn role_downgrades_stop_signed_recovery_and_readers_cannot_create_or_cancel_pairings() {
    let hash = bootstrap::recovery_request_hash(1, Some(5), &[7; 40]).unwrap();
    for role in ["writer", "reader"] {
        let downgraded = Step::json(json!({"scope":scope(),"keyEpoch":1,"role":role}));
        let (client, worker) = fixture(vec![
            space(&scope()),
            authority_step(),
            Step::json(challenge_response("replace_recovery", &hash)),
            downgraded,
        ]);
        let mut transport = bound(client);
        let signed = authorize(
            transport
                .request_key_challenge(
                    Mutation::recovery(1, Some(5), &[7; 40]).unwrap(),
                    &authority().public_key(),
                )
                .unwrap(),
        );
        assert!(transport.replace_recovery(&signed).err() == Some(Failure::ReadOnly));
        assert_eq!(worker.join().unwrap().len(), 4);
    }
    let reader = || Step::json(json!({"scope":scope(),"keyEpoch":1,"role":"reader"}));
    let (client, worker) = fixture(vec![reader(), reader()]);
    let draft = PairingDraft::generate().unwrap();
    let inv = invitation(&client, &draft);
    let mut transport = bound(client);
    assert!(transport.create_pairing(&draft).err() == Some(Failure::ReadOnly));
    assert!(transport.cancel_pairing(&inv).err() == Some(Failure::ReadOnly));
    assert_eq!(worker.join().unwrap().len(), 2);
}

#[test]
fn signed_mutation_refuses_foreign_deployment_wrong_endpoint_and_feed_or_dataset_rotation() {
    let hash = bootstrap::recovery_request_hash(1, Some(5), &[7; 40]).unwrap();
    for index in 0..4 {
        let mut changed = scope();
        if index == 0 {
            changed.feed_epoch = Uuid::from_u128(99);
        }
        if index == 1 {
            changed.dataset_generation = Uuid::from_u128(99);
        }
        if index == 2 {
            changed.scope_binding = "another-fictional-membership-binding".into();
        }
        let mut steps = vec![
            space(&scope()),
            authority_step(),
            Step::json(challenge_response("replace_recovery", &hash)),
        ];
        if index != 3 {
            steps.push(space(&changed));
        }
        let (client, worker) = fixture(steps);
        let mut transport = bound(client);
        let signed = authorize(
            transport
                .request_key_challenge(
                    Mutation::recovery(1, Some(5), &[7; 40]).unwrap(),
                    &authority().public_key(),
                )
                .unwrap(),
        );
        assert!(transport.approve_pairing(&signed).err() == Some(Failure::InvalidResponse));
        if index == 3 {
            let (foreign, empty) = fixture(vec![]);
            assert!(
                bound(foreign).replace_recovery(&signed).err() == Some(Failure::InvalidResponse)
            );
            assert!(empty.join().unwrap().is_empty());
        } else {
            let expected = match index {
                0 => Failure::InvalidResponse,
                1 => Failure::DatasetReview,
                _ => Failure::AccountReview,
            };
            assert!(transport.replace_recovery(&signed).err() == Some(expected));
        }
        assert_eq!(worker.join().unwrap().len(), if index == 3 { 3 } else { 4 });
    }
}

#[test]
fn signed_recovery_receipts_require_next_cas_exact_cipher_and_complete_real_server_schema() {
    let hash = bootstrap::recovery_request_hash(1, Some(5), &[7; 40]).unwrap();
    for index in 0..8 {
        let mut response = recovery_response(&scope(), 6, &[7; 40]);
        match index {
            0 => response["recovery"]["version"] = json!(7),
            1 => response["recovery"]["ciphertext"] = json!(STANDARD.encode([8; 40])),
            2 => response["recovery"]["purpose"] = json!("other"),
            3 => response["recovery"]["createdAt"] = json!("not-a-date"),
            4 => {
                response["recovery"]
                    .as_object_mut()
                    .unwrap()
                    .remove("createdAt");
            }
            5 => {
                response["recovery"]
                    .as_object_mut()
                    .unwrap()
                    .remove("purpose");
            }
            6 => response["recovery"]["unexpected"] = json!(true),
            _ => response["scope"]["feedEpoch"] = json!(Uuid::from_u128(99)),
        }
        let (client, worker) = fixture(vec![
            space(&scope()),
            authority_step(),
            Step::json(challenge_response("replace_recovery", &hash)),
            space(&scope()),
            Step::json(response),
        ]);
        let mut transport = bound(client);
        let signed = authorize(
            transport
                .request_key_challenge(
                    Mutation::recovery(1, Some(5), &[7; 40]).unwrap(),
                    &authority().public_key(),
                )
                .unwrap(),
        );
        assert!(
            transport.replace_recovery(&signed).err() == Some(Failure::InvalidResponse),
            "mutation {index}"
        );
        assert_eq!(worker.join().unwrap().len(), 5);
    }
}

#[test]
fn pairing_metadata_rejects_wrong_recipient_nonce_tag_id_expiry_state_and_envelope_disclosure() {
    let draft = PairingDraft::generate().unwrap();
    for index in 0..9 {
        let (client, worker) = fixture_with(|client| {
            let inv = invitation(client, &draft);
            let mut response = pairing_response(&inv, "pending");
            match index {
                0 => response["pairing"]["recipientPublicKey"] = json!(STANDARD.encode([0; 65])),
                1 => response["pairing"]["nonce"] = json!(STANDARD.encode([0; 32])),
                2 => response["pairing"]["authenticationTag"] = json!("AAAAAAAA"),
                3 => response["pairing"]["pairingId"] = json!(Uuid::nil()),
                4 => {
                    response["pairing"]["expiresAt"] =
                        json!((chrono::Utc::now() - chrono::Duration::seconds(31)).to_rfc3339())
                }
                5 => response["pairing"]["state"] = json!("approved"),
                6 => response["pairing"]["algorithm"] = json!(bootstrap::PAIRING_ALGORITHM),
                7 => response["pairing"]["ciphertext"] = json!(STANDARD.encode([7; 40])),
                _ => response["pairing"]["algorithm"] = json!(null),
            }
            let mut response = Step::json(response);
            response.status = 201;
            vec![space(&scope()), response]
        });
        assert!(
            bound(client).create_pairing(&draft).err() == Some(Failure::InvalidResponse),
            "mutation {index}"
        );
        assert_eq!(worker.join().unwrap().len(), 2);
    }
}

#[test]
fn claim_refuses_wrong_pairing_algorithm_size_scope_or_unapproved_local_state() {
    let draft = PairingDraft::generate().unwrap();
    for index in 0..5 {
        let mut expected_invitation = None;
        let (client, worker) = fixture_with(|client| {
            let inv = invitation(client, &draft);
            expected_invitation = Some(inv.clone());
            let mut response = json!({"scope":scope(),"pairingId":inv.pairing(),"algorithm":bootstrap::PAIRING_ALGORITHM,"ciphertext":STANDARD.encode([7;40])});
            match index {
                0 => response["pairingId"] = json!(Uuid::from_u128(99)),
                1 => response["algorithm"] = json!("unknown"),
                2 => response["ciphertext"] = json!(STANDARD.encode([7; 4097])),
                3 => response["ciphertext"] = json!(STANDARD.encode([7; 27])),
                _ => response["scope"]["datasetGeneration"] = json!(Uuid::from_u128(99)),
            }
            vec![
                space(&scope()),
                Step::json(pairing_response(&inv, "approved")),
                space(&scope()),
                Step::json(response),
            ]
        });
        let inv = expected_invitation.unwrap();
        let mut transport = bound(client);
        let approved = transport.pairing(&inv).unwrap();
        let expected = if index == 4 {
            Failure::DatasetReview
        } else {
            Failure::InvalidResponse
        };
        assert!(transport.claim_pairing(&approved).err() == Some(expected));
        if index == 4 {
            assert!(transport.fetch_page(None).err() == Some(expected));
        }
        assert_eq!(worker.join().unwrap().len(), 4);
    }
}

#[test]
fn required_nullable_authority_and_recovery_fields_cannot_be_omitted() {
    for field in ["publicKey", "recovery"] {
        let (client, worker) = fixture(vec![
            space(&scope()),
            Step::json(json!({"scope":scope(),"keyEpoch":1})),
        ]);
        let mut transport = bound(client);
        let result = if field == "publicKey" {
            transport.key_authority().err()
        } else {
            transport.recovery_state().err()
        };
        assert!(result == Some(Failure::InvalidResponse));
        assert_eq!(worker.join().unwrap().len(), 2);
    }
}

#[test]
fn unsafe_mutations_and_foreign_invitations_stop_before_network_and_204_must_be_empty() {
    for epoch in [0, u64::MAX] {
        assert!(Mutation::recovery(epoch, None, &[7; 40]).is_err());
    }
    for version in [0, i64::MAX as u64, u64::MAX] {
        assert!(Mutation::recovery(1, Some(version), &[7; 40]).is_err());
    }
    for length in [0, 27, 4097] {
        assert!(Mutation::recovery(1, None, &vec![7; length]).is_err());
    }
    let draft = PairingDraft::generate().unwrap();
    let (foreign, empty) = fixture(vec![]);
    let foreign_inv = invitation(&foreign, &draft);
    let (client, worker) = fixture(vec![]);
    let mut transport = bound(client);
    assert!(transport.pairing(&foreign_inv).err() == Some(Failure::InvalidResponse));
    assert!(transport.cancel_pairing(&foreign_inv).err() == Some(Failure::InvalidResponse));
    assert!(
        transport
            .request_key_challenge(
                Mutation::approval(1, foreign_inv, &[7; 40]).unwrap(),
                &authority().public_key()
            )
            .err()
            == Some(Failure::InvalidResponse)
    );
    assert!(worker.join().unwrap().is_empty() && empty.join().unwrap().is_empty());
    let (client, worker) = fixture_with(|_| {
        let mut step = Step::json(json!({}));
        step.status = 204;
        vec![space(&scope()), step]
    });
    let inv = invitation(&client, &draft);
    assert!(bound(client).cancel_pairing(&inv).err() == Some(Failure::InvalidResponse));
    assert_eq!(worker.join().unwrap().len(), 2);
}
