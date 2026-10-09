//! Fictional deployment, tokens and identities; every document lives in an
//! isolated in-memory backend. No server, keyring or network is used.
use super::*;
use crate::{
    auth_store::{CleanupAction, CleanupReceipt},
    cloud::{DeviceRequestReceipt, ServerURL},
    secret_store::{Store, tests::Memory},
};
use std::cell::Cell;

const POLL: &str = "sn_d_PUBLICfictionalPollTokenOnly0123456789abcde";
const SPACE: &str = "11111111-2222-4333-8444-555555555555";
const PAIRING: &str = "66666666-7777-4888-9999-aaaaaaaaaaaa";
const ACCOUNT: &str = "0f1e2d3c-4b5a-4968-8776-655443322110";

fn client() -> CloudClient {
    CloudClient::test_with_agent(
        ServerURL::parse("https://cloud.example.test").unwrap(),
        ureq::Agent::new_with_defaults(),
        Uuid::from_u128(1),
    )
}
fn fixture() -> (tempfile::TempDir, Store<Memory>, Memory) {
    let root = tempfile::tempdir().unwrap();
    let memory = Memory::default();
    let store = Store::initialize(root.path(), memory.clone()).unwrap();
    (root, store, memory)
}
fn saved(store: &mut Store<Memory>) -> Option<Vec<u8>> {
    store
        .transaction(|o| o.read(Slot::DeviceSignIn))
        .unwrap()
        .map(|v| v.to_vec())
}
fn receipt(expires_in: i64) -> DeviceRequestReceipt {
    DeviceRequestReceipt {
        request: Uuid::from_u128(0x7a6b5c4d_3e2f_4a1b_8c9d_0e1f2a3b4c5d),
        poll_token: PollToken::new(Zeroizing::new(POLL.into())).unwrap(),
        expires_at: chrono::Utc::now().timestamp() + expires_in,
    }
}
fn begin(
    store: &mut Store<Memory>,
    client: &CloudClient,
    created: &Cell<usize>,
) -> Result<DeviceSignIn> {
    store.transaction_with(|owner| {
        begin_locked(owner, client, &|| Ok(()), &|_| {
            created.set(created.get() + 1);
            Ok(receipt(600))
        })
    })
}
fn approved_claim() -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({
        "state":"approved",
        "expiresAt":(chrono::Utc::now() + chrono::Duration::seconds(500)).to_rfc3339(),
        "spaceId":SPACE,"pairingId":PAIRING,
        "session":{"access_token":"public-device-access","refresh_token":"public-device-refresh",
            "expires_in":300,"token_type":"Bearer","account":{"id":ACCOUNT}}
    }))
    .unwrap()
}
fn claim(store: &mut Store<Memory>, client: &CloudClient, approved: bool) -> Result<Claim> {
    store.transaction_with(|owner| {
        // The fictional server retains the expiry it issued at creation.
        // Recomputing now + 600 made a pending reply invalid whenever this
        // helper crossed a wall-clock second after begin().
        let expires_at = Document::load(owner)?
            .and_then(|document| document.request.map(|request| request.expires_at));
        claim_locked(owner, client, &|| Ok(()), &|id, poll| {
            assert!(id == receipt(0).request && poll.for_secure_storage() == POLL);
            if approved {
                Ok(DeviceClaim::Approved(Box::new(
                    cloud::IssuedGrant::fixture_device(&approved_claim()).unwrap(),
                )))
            } else {
                Ok(DeviceClaim::Pending {
                    expires_at: expires_at.expect("pending fixture request"),
                })
            }
        })
    })
}
fn acknowledge(action: CleanupAction) -> CleanupReceipt {
    CleanupReceipt {
        generation: action.generation,
        index: action.index,
        deployment: action.deployment,
        token: action.token,
        refresh: action.refresh,
    }
}

#[test]
fn request_persists_recipient_material_and_token_before_display_and_resumes_without_reissue() {
    let (_root, mut store, _) = fixture();
    let client = client();
    let created = Cell::new(0);
    let payload = begin(&mut store, &client, &created).unwrap();
    assert_eq!(created.get(), 1);
    let document = saved(&mut store).unwrap();
    let text = String::from_utf8(document.clone()).unwrap();
    // The token is stored only here; the public payload never contains it.
    assert!(text.contains(POLL) && text.contains("privateKey"));
    let shown = String::from_utf8(payload.encode_qr().unwrap().to_vec()).unwrap();
    assert!(!shown.contains("sn_d_") && !shown.contains("privateKey"));
    assert!(payload.server() == client.credential_deployment().server());
    store
        .transaction_with::<_, Failure>(|owner| {
            let saved = Document::load(owner)?.unwrap();
            assert!(saved.draft.public_key() == payload.public_key());
            assert!(saved.draft.nonce() == payload.nonce());
            Ok(())
        })
        .unwrap();
    // Reopening shows the same unexpired request; no second request is opened.
    let again = begin(&mut store, &client, &created).unwrap();
    assert!(again == payload && created.get() == 1);
    assert!(matches!(inspect(&mut store).unwrap(), Some(Status::Waiting(p)) if p == payload));
    // Pending polls change nothing durable.
    assert!(
        matches!(claim(&mut store, &client, false).unwrap(), Claim::Pending(p) if p == payload)
    );
    assert!(saved(&mut store).unwrap() == document);
    // A server that changes the original expiry is still refused. Correcting
    // the fixture must not weaken the production response check.
    assert!(matches!(
        store.transaction_with(|owner| {
            let expires_at = Document::load(owner)?.unwrap().request.unwrap().expires_at;
            claim_locked(owner, &client, &|| Ok(()), &|_, _| {
                Ok(DeviceClaim::Pending {
                    expires_at: expires_at + 1,
                })
            })
        }),
        Err(Failure::Cloud(cloud::Failure::InvalidResponse))
    ));
    assert!(saved(&mut store).unwrap() == document);
    // Another deployment never receives this token.
    let foreign = CloudClient::test_with_agent(
        client.credential_deployment().server().clone(),
        ureq::Agent::new_with_defaults(),
        Uuid::from_u128(2),
    );
    assert!(matches!(
        store.transaction_with(|owner| claim_locked(
            owner,
            &foreign,
            &|| panic!("no preflight"),
            &|_, _| panic!("no claim")
        )),
        Err(Failure::WrongDeployment)
    ));
    cancel(&mut store).unwrap();
    assert!(saved(&mut store).is_none() && inspect(&mut store).unwrap().is_none());
}

#[test]
fn approved_claim_commits_a_keyless_session_through_the_credential_journal() {
    let (_root, mut store, _) = fixture();
    let client = client();
    let created = Cell::new(0);
    begin(&mut store, &client, &created).unwrap();
    let Claim::Approved(grant) = claim(&mut store, &client, true).unwrap() else {
        panic!("expected an approved claim");
    };
    let live = issue(
        &mut store,
        Replacement::Interactive,
        client.credential_deployment(),
        |_| Ok(*grant),
        &mut |a| Ok(acknowledge(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    let approval = live.session.device_approval().unwrap();
    assert!(approval.space.to_string() == SPACE && approval.pairing.to_string() == PAIRING);
    assert!(live.account_display().unwrap() == "0F1E-2D3C");
    let credentials = store
        .transaction(|o| o.read(Slot::Credentials))
        .unwrap()
        .unwrap();
    assert!(
        String::from_utf8(credentials.to_vec())
            .unwrap()
            .contains("\"accountKey\":null")
    );
    // Show Account Key has nothing to disclose on this device.
    assert!(
        prepare_account_key_disclosure(&mut store).err() == Some(Failure::AccountKeyUnavailable)
    );
    // A rotation keeps the device's keyless session keyless.
    issue(
        &mut store,
        Replacement::Refresh,
        client.credential_deployment(),
        |_| {
            Ok(cloud::IssuedGrant::fixture(
                br#"{"access_token":"public-rotated-access","refresh_token":"public-rotated-refresh","expires_in":300,"token_type":"Bearer","account":{"id":"0f1e2d3c-4b5a-4968-8776-655443322110"}}"#,
            )?)
        },
        &mut |a| Ok(acknowledge(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    assert!(
        prepare_account_key_disclosure(&mut store).err() == Some(Failure::AccountKeyUnavailable)
    );
    record_approval(&mut store, &client.credential_deployment(), approval).unwrap();
    let document = String::from_utf8(saved(&mut store).unwrap()).unwrap();
    assert!(!document.contains(POLL) && document.contains(PAIRING));
    assert!(matches!(
        inspect(&mut store).unwrap(),
        Some(Status::Approved)
    ));
    // Recording again is idempotent; the request can no longer be claimed.
    record_approval(&mut store, &client.credential_deployment(), approval).unwrap();
    assert!(matches!(
        claim(&mut store, &client, true),
        Err(Failure::Busy)
    ));
    store
        .transaction_with::<_, Failure>(|owner| {
            let (deployment, draft, saved_approval, _) = approved_draft(owner)?.unwrap();
            assert!(deployment == client.credential_deployment() && saved_approval == approval);
            assert!(draft.public_key().len() == 65);
            Ok(())
        })
        .unwrap();
    // A new request cannot replace an approved one before its key is claimed.
    sign_out_with(&mut store, &mut |a| Ok(acknowledge(a))).unwrap();
    assert!(matches!(
        begin(&mut store, &client, &created),
        Err(Failure::Busy)
    ));
}

#[test]
fn approved_claim_metadata_is_validated_only_after_the_pair_is_journaled() {
    let base: serde_json::Value = serde_json::from_slice(&approved_claim()).unwrap();
    for mutation in 0..7 {
        let mut value = base.clone();
        match mutation {
            0 => value["pairingId"] = serde_json::json!(PAIRING.to_uppercase()),
            1 => value["pairingId"] = serde_json::json!(Uuid::nil()),
            2 => value["extra"] = serde_json::json!(true),
            3 => {
                value.as_object_mut().unwrap().remove("pairingId");
            }
            4 => value["expiresAt"] = serde_json::json!("2001-01-01T00:00:00Z"),
            5 => value["session"]["account"]["email"] = serde_json::json!("x@example.test"),
            _ => value["session"]["account"]["id"] = serde_json::json!("fictional-account"),
        }
        let grant =
            cloud::IssuedGrant::fixture_device(&serde_json::to_vec(&value).unwrap()).unwrap();
        let journaled = Cell::new(false);
        let rejected = grant
            .accept(
                |_| {
                    journaled.set(true);
                    Ok(())
                },
                None,
                None,
            )
            .err()
            .unwrap_or_else(|| panic!("accepted mutation {mutation}"));
        assert!(
            journaled.get() && rejected.failure == cloud::Failure::InvalidResponse,
            "{mutation}"
        );
    }
    // Without its session member an approved claim carries no pair to own.
    let mut value = base.clone();
    value.as_object_mut().unwrap().remove("session");
    assert!(cloud::IssuedGrant::fixture_device(&serde_json::to_vec(&value).unwrap()).is_err());
    // An account key never arrives with a device-approved session.
    let (_root, mut store, _) = fixture();
    let keyed = cloud::IssuedGrant::fixture_signed_in(
        &serde_json::to_vec(&base["session"]).unwrap(),
        "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7",
    )
    .unwrap();
    let live = issue(
        &mut store,
        Replacement::Interactive,
        client().credential_deployment(),
        |_| Ok(keyed),
        &mut |a| Ok(acknowledge(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    assert!(live.session.device_approval().is_none());
}

#[test]
fn device_document_is_strict_and_refuses_signed_in_or_mixed_phases() {
    let (_root, mut store, _) = fixture();
    let client = client();
    let created = Cell::new(0);
    begin(&mut store, &client, &created).unwrap();
    let original = saved(&mut store).unwrap();
    let mut value: serde_json::Value = serde_json::from_slice(&original).unwrap();
    for mutation in 0..5 {
        let mut changed = value.clone();
        match mutation {
            0 => changed["schema"] = serde_json::json!(2),
            1 => changed["approval"] = serde_json::json!({"spaceId":SPACE,"pairingId":PAIRING}),
            2 => changed["request"] = serde_json::Value::Null,
            3 => changed["request"]["pollToken"] = serde_json::json!("not-a-poll-token"),
            _ => changed["extra"] = serde_json::json!(1),
        }
        let bytes = serde_json::to_vec(&changed).unwrap();
        store
            .transaction(|o| {
                let before = o.read(Slot::DeviceSignIn)?.unwrap();
                o.replace(Slot::DeviceSignIn, Some(&before), Some(&bytes))
            })
            .unwrap();
        assert!(
            inspect(&mut store).err() == Some(Failure::InvalidState),
            "{mutation}"
        );
        store
            .transaction(|o| o.replace(Slot::DeviceSignIn, Some(&bytes), Some(&original)))
            .unwrap();
    }
    value["request"]["expiresAt"] = serde_json::json!(chrono::Utc::now().timestamp() - 1000);
    let expired = serde_json::to_vec(&value).unwrap();
    store
        .transaction(|o| o.replace(Slot::DeviceSignIn, Some(&original), Some(&expired)))
        .unwrap();
    // An expired request stays displayable; begin replaces it with a fresh one.
    assert!(matches!(
        inspect(&mut store).unwrap(),
        Some(Status::Waiting(_))
    ));
    begin(&mut store, &client, &created).unwrap();
    assert_eq!(created.get(), 2);
    // A signed-in device never opens a request.
    let (_root, mut signed_in, _) = fixture();
    issue(
        &mut signed_in,
        Replacement::Interactive,
        client.credential_deployment(),
        |_| Ok(cloud::IssuedGrant::fixture_device(&approved_claim())?),
        &mut |a| Ok(acknowledge(a)),
    )
    .unwrap_or_else(|e| panic!("{:?}", e.failure));
    assert!(matches!(
        begin(&mut signed_in, &client, &created),
        Err(Failure::InvalidState)
    ));
    assert_eq!(created.get(), 2);
}
