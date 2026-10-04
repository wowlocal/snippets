//! Real loopback HTTP tests with public fictional credentials/identifiers only.
//! The release constructor still requires HTTPS and normal certificate validation.
use super::*;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    thread::{self, JoinHandle},
    time::Instant,
};

struct Step {
    status: u16,
    content_type: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    chunked: bool,
}
impl Step {
    fn lost_response() -> Self {
        let mut step = Self::json(json!({}));
        step.status = 0;
        step
    }
    fn json(body: Value) -> Self {
        Self {
            status: 200,
            content_type: "application/json".into(),
            headers: vec![],
            body: serde_json::to_vec(&body).unwrap(),
            chunked: false,
        }
    }
    fn problem(code: &str) -> Self {
        let mut step = Self::json(
            json!({"type":format!("urn:snippets:error:{code}"),"status":409,"code":code,"requestId":Uuid::from_u128(99)}),
        );
        step.status = 409;
        step.content_type = "application/problem+json".into();
        step
    }
}
struct Capture {
    method: String,
    target: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}
impl Capture {
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap()
    }
}
fn capture(stream: &mut TcpStream) -> Capture {
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut bytes = Vec::new();
    while !bytes.ends_with(b"\r\n\r\n") {
        let mut byte = [0];
        stream.read_exact(&mut byte).unwrap();
        bytes.push(byte[0]);
        assert!(bytes.len() < 16 * 1024);
    }
    let text = String::from_utf8(bytes).unwrap();
    let mut lines = text.split("\r\n");
    let mut request = lines.next().unwrap().split_whitespace();
    let method = request.next().unwrap().into();
    let target = request.next().unwrap().into();
    let headers: BTreeMap<String, String> = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.to_ascii_lowercase(), v.trim().into()))
        .collect();
    let length = headers
        .get("content-length")
        .map_or(0, |s| s.parse::<usize>().unwrap());
    assert!(length <= MAX_MESSAGE);
    let mut body = vec![0; length];
    stream.read_exact(&mut body).unwrap();
    Capture {
        method,
        target,
        headers,
        body,
    }
}
fn fixture(steps: Vec<Step>) -> (CloudClient, JoinHandle<Vec<Capture>>) {
    fixture_with(|_| steps)
}
fn fixture_with(
    steps: impl FnOnce(&CloudClient) -> Vec<Step>,
) -> (CloudClient, JoinHandle<Vec<Capture>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let server = ServerURL {
        canonical: format!("http://{}", listener.local_addr().unwrap()),
    };
    let client = CloudClient {
        server,
        agent: agent(false),
        instance: Uuid::from_u128(1),
    };
    let steps = steps(&client);
    let worker = thread::spawn(move || {
        let mut captures = Vec::new();
        for step in steps {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(
                            Instant::now() < deadline,
                            "loopback fixture request timed out"
                        );
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => panic!("loopback fixture failed"),
                }
            };
            captures.push(capture(&mut stream));
            if step.status == 0 {
                continue;
            }
            let mut headers = format!(
                "HTTP/1.1 {} Fixture\r\nConnection: close\r\nContent-Type: {}\r\n",
                step.status, step.content_type
            );
            for (name, value) in step.headers {
                headers.push_str(&format!("{name}: {value}\r\n"));
            }
            if step.chunked {
                headers.push_str("Transfer-Encoding: chunked\r\n\r\n");
            } else {
                headers.push_str(&format!("Content-Length: {}\r\n\r\n", step.body.len()));
            }
            stream.write_all(headers.as_bytes()).unwrap();
            // Refusal can close the socket before a hostile body is sent.
            if step.chunked {
                let _ = write!(stream, "{:x}\r\n", step.body.len());
                let _ = stream.write_all(&step.body);
                let _ = stream.write_all(b"\r\n0\r\n\r\n");
            } else {
                let _ = stream.write_all(&step.body);
            }
        }
        captures
    });
    (client, worker)
}

#[path = "cloud_action_tests.rs"]
mod key_actions;
fn scope() -> Scope {
    Scope {
        server_instance_id: Uuid::from_u128(1),
        space_id: Uuid::from_u128(2),
        scope_binding: "public-fictional-membership-binding".into(),
        dataset_generation: Uuid::from_u128(3),
        feed_epoch: Uuid::from_u128(4),
    }
}
fn space(scope: &Scope) -> Step {
    Step::json(json!({"scope":scope,"role":"owner","keyEpoch":1}))
}
fn token() -> Credential {
    Credential::new("fixture-access".into()).unwrap()
}
fn bound(client: CloudClient) -> BoundTransport {
    let scope = scope();
    let (membership, dataset) = scope.identities(&client.server);
    client
        .admit(
            token(),
            Space {
                scope,
                role: Role::Owner,
                key_epoch: 1,
            },
            &membership,
            &dataset,
        )
        .unwrap()
}
fn record(id: u128) -> WireRecord {
    WireRecord {
        id: Uuid::from_u128(id),
        rev: "a".repeat(32),
        deleted: false,
        blob: b"public fictional ciphertext".to_vec(),
    }
}
fn server_record(id: u128) -> ServerRecord {
    let wire = record(id);
    ServerRecord {
        id: wire.id,
        rev: wire.rev,
        deleted: wire.deleted,
        blob: wire.blob,
        record_version: RecordVersion("fixture-version-a".repeat(2)),
    }
}
fn accepted() -> Value {
    json!({"kind":"accepted","recordVersion":"fixture-version-bfixture-version-b","revision":"a".repeat(32)})
}
fn batch(scope: &Scope, outcomes: Vec<Value>, partial: bool) -> Step {
    Step::json(json!({"scope":scope,"outcomes":outcomes,"partial":partial}))
}
fn page(scope: &Scope, full_snapshot: bool) -> Step {
    Step::json(
        json!({"scope":scope,"records":[server_record(10)],"cursor":"fixture-cursor","hasMore":false,"fullSnapshot":full_snapshot}),
    )
}
fn offer(id: u128) -> Offer {
    Offer {
        record: record(id),
        expected_record_version: None,
    }
}

#[test]
fn configuration_and_discovery_refuse_insecure_or_foreign_authorities() {
    for text in [
        "http://example.invalid",
        "https:example.invalid",
        "https:/example.invalid",
        "https://@example.invalid",
        "https://user@example.invalid",
        "https://example.invalid?x=1",
        "https://example.invalid#x",
        "https://example.invalid\\evil",
        " https://example.invalid",
    ] {
        assert!(ServerURL::parse(text).is_err());
    }
    assert!(Credential::new("x\r\nAuthorization: bad".into()).is_err());
    assert!(Credential::new("secret with spaces".into()).is_err());
    let server = ServerURL::parse("https://example.invalid/snippets///").unwrap();
    assert!(server.canonical == "https://example.invalid/snippets");
    let discovery = json!({"protocolMajor":2,"protocolMinor":1,"serverVersion":"fixture","serverInstanceId":Uuid::from_u128(1),"apiBase":"https://example.invalid/snippets/v2","recordProfile":"snippets-wire-v1","capabilities":["native-email-code-v1","library-action-proof-v1","pairing-v2","offline-recovery-v1","resource-session-revocation"],"limits":{"maxBlobBytes":900000,"maxRevisionBytes":256,"maxBatchRecords":50,"maxPageRecords":50,"maxRequestBytes":16777216,"maxResponseBytes":67108864,"maxKeyEnvelopeBytes":4096,"maxPairingSeconds":600},"nativeAuth":{"flow":"email_code","startEndpoint":"https://example.invalid/snippets/v2/auth/email/start","verifyEndpoint":"https://example.invalid/snippets/v2/auth/email/verify","refreshEndpoint":"https://example.invalid/snippets/v2/auth/refresh","revokeEndpoint":"https://example.invalid/snippets/v2/auth/revoke"}});
    let parsed: Discovery = decode(&serde_json::to_vec(&discovery).unwrap()).unwrap();
    parsed.validate(&server).unwrap();
    let mut null_oidc = discovery.clone();
    null_oidc["oidc"] = Value::Null;
    assert!(decode::<Discovery>(&serde_json::to_vec(&null_oidc).unwrap()).is_err());
    for mutation in 0..6 {
        let mut changed = discovery.clone();
        match mutation {
            0 => {
                changed["nativeAuth"]["startEndpoint"] =
                    json!("https://evil.invalid/v2/auth/email/start")
            }
            1 => changed["capabilities"] = json!(["native-email-code-v1"]),
            2 => changed["limits"]["maxBlobBytes"] = json!(900001),
            3 => changed["apiBase"] = json!("https://example.invalid/v2"),
            4 => changed["protocolMajor"] = json!(1),
            _ => changed["serverInstanceId"] = json!(Uuid::nil()),
        }
        let parsed: Discovery = decode(&serde_json::to_vec(&changed).unwrap()).unwrap();
        assert!(parsed.validate(&server).is_err());
    }
    let (mut client, worker) = fixture(vec![Step::json(discovery)]);
    assert_eq!(
        client.load_discovery().err(),
        Some(Failure::InvalidResponse)
    );
    let requests = worker.join().unwrap();
    assert!(
        requests[0].target == "/.well-known/snippets-sync"
            && !requests[0].headers.contains_key("authorization")
    );
}

#[test]
fn native_auth_uses_camel_case_and_journals_issued_credentials_before_metadata() {
    let grant = json!({"access_token":"fixture-issued-access","refresh_token":"fixture-issued-refresh","expires_in":300,"token_type":"Bearer","account":{"id":"fictional-account","email":"fixture@example.invalid"}});
    let challenge =
        json!({"challengeId":"fixture-challenge","expiresIn":600,"resendAfter":60,"codeLength":6});
    let mut empty = Step::json(Value::Null);
    empty.status = 204;
    empty.body.clear();
    let (client, worker) = fixture(vec![
        Step::json(challenge),
        Step::json(grant.clone()),
        Step::json(grant.clone()),
        empty,
    ]);
    let challenge = client.start_email("fixture@example.invalid").unwrap();
    let issued = client.verify_email(&challenge, "123456").unwrap();
    let journaled = std::cell::Cell::new(false);
    let session = issued
        .accept(
            |credentials| {
                assert!(credentials.access.for_secure_storage() == b"fixture-issued-access");
                journaled.set(true);
                Ok(())
            },
            None,
            None,
        )
        .ok()
        .unwrap();
    assert!(journaled.get() && session.expires_in() == Duration::from_secs(300));
    let previous = Credential::new("fixture-old-refresh".into()).unwrap();
    let rotated = client.refresh(&previous).unwrap();
    assert!(
        rotated
            .accept(|_| Ok(()), Some("fictional-account"), Some(&previous))
            .is_ok()
    );
    client.revoke(&session.credentials.refresh, true).unwrap();
    let requests = worker.join().unwrap();
    assert!(
        requests
            .iter()
            .all(|r| r.method == "POST" && !r.headers.contains_key("authorization"))
    );
    assert!(requests[1].json() == json!({"challengeId":"fixture-challenge","code":"123456"}));
    assert!(requests[2].json() == json!({"refreshToken":"fixture-old-refresh"}));
    assert!(
        requests[3].json()
            == json!({"token":"fixture-issued-refresh","tokenTypeHint":"refresh_token"})
    );
    let mut bad = grant.clone();
    bad["expires_in"] = json!(0);
    let issued = IssuedGrant::parse(&serde_json::to_vec(&bad).unwrap()).unwrap();
    journaled.set(false);
    let rejected = issued
        .accept(
            |_| {
                journaled.set(true);
                Ok(())
            },
            None,
            None,
        )
        .err()
        .unwrap();
    assert!(
        journaled.get()
            && rejected.failure == Failure::InvalidResponse
            && rejected.credentials.refresh.for_secure_storage() == b"fixture-issued-refresh"
    );
    let issued = IssuedGrant::parse(&serde_json::to_vec(&grant).unwrap()).unwrap();
    assert!(
        issued
            .accept(|_| Err(Failure::Network), None, None)
            .err()
            .unwrap()
            .failure
            == Failure::CredentialCommit
    );
    let issued = IssuedGrant::parse(&serde_json::to_vec(&grant).unwrap()).unwrap();
    assert!(
        issued
            .accept(|_| Ok(()), Some("another-fictional-account"), None)
            .is_err()
    );
    let issued = IssuedGrant::parse(&serde_json::to_vec(&grant).unwrap()).unwrap();
    let old = Credential::new("fixture-issued-refresh".into()).unwrap();
    assert!(issued.accept(|_| Ok(()), None, Some(&old)).is_err());
}

#[test]
fn credential_preflight_pins_deployment_without_sending_account_credentials() {
    for instance in [1, 2] {
        let (client, worker) = fixture_with(|client| {
            let base = &client.server.canonical;
            vec![Step::json(json!({
                "protocolMajor":2,"protocolMinor":1,"serverVersion":"fixture",
                "serverInstanceId":Uuid::from_u128(instance),"apiBase":format!("{base}/v2"),
                "recordProfile":"snippets-wire-v1",
                "capabilities":["native-email-code-v1","library-action-proof-v1","pairing-v2","offline-recovery-v1","resource-session-revocation"],
                "limits":{"maxBlobBytes":900000,"maxRevisionBytes":256,"maxBatchRecords":50,"maxPageRecords":50,"maxRequestBytes":16777216,"maxResponseBytes":67108864,"maxKeyEnvelopeBytes":4096,"maxPairingSeconds":600},
                "nativeAuth":{"flow":"email_code","startEndpoint":format!("{base}/v2/auth/email/start"),
                    "verifyEndpoint":format!("{base}/v2/auth/email/verify"),
                    "refreshEndpoint":format!("{base}/v2/auth/refresh"),
                    "revokeEndpoint":format!("{base}/v2/auth/revoke")}
            }))]
        });
        assert_eq!(
            client.preflight_credentials(),
            if instance == 1 {
                Ok(())
            } else {
                Err(Failure::AccountReview)
            }
        );
        let requests = worker.join().unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].method == "GET" && requests[0].target == "/.well-known/snippets-sync");
        assert!(!requests[0].headers.contains_key("authorization") && requests[0].body.is_empty());
        // A manually decoded or foreign challenge cannot send a code.
        let challenge: EmailChallenge = decode(
            br#"{"challengeId":"fictional","expiresIn":600,"resendAfter":60,"codeLength":6}"#,
        )
        .unwrap();
        assert!(client.verify_email(&challenge, "123456").err() == Some(Failure::AccountReview));
    }
}

#[test]
fn account_or_dataset_changes_stop_before_records_and_remain_sticky() {
    for kind in 0..3 {
        let mut changed = scope();
        match kind {
            0 => changed.scope_binding = "a-different-public-membership-binding".into(),
            1 => changed.dataset_generation = Uuid::from_u128(100),
            _ => changed.server_instance_id = Uuid::from_u128(100),
        };
        let expected = if kind == 1 {
            Failure::DatasetReview
        } else {
            Failure::AccountReview
        };
        let (client, worker) = fixture(vec![space(&changed)]);
        let mut transport = bound(client);
        assert_eq!(transport.fetch_page(None).err(), Some(expected));
        assert_eq!(transport.preflight().err(), Some(expected));
        assert_eq!(transport.submit_chunk(&[offer(10)]).err(), Some(expected));
        let requests = worker.join().unwrap();
        assert!(requests.len() == 1 && !requests[0].target.contains("changes"));
    }
}

#[test]
fn snapshot_page_checks_are_strict_and_cursor_query_is_encoded() {
    let (client, worker) = fixture(vec![space(&scope()), page(&scope(), true)]);
    let mut transport = bound(client);
    let fetched = transport.fetch_page(None).unwrap();
    assert!(fetched.records.len() == 1 && fetched.full_snapshot);
    let requests = worker.join().unwrap();
    assert!(requests[1].target.ends_with("/changes?limit=10"));
    assert!(requests.iter().all(|r| {
        r.headers
            .get("authorization")
            .is_some_and(|h| h == "Bearer fixture-access")
    }));
    for kind in 0..5 {
        let mut body: Value = serde_json::from_slice(&page(&scope(), true).body).unwrap();
        let cursor = Cursor("fixture-cursor".into());
        match kind {
            0 => body["fullSnapshot"] = json!(false),
            1 => body["records"][0]
                .as_object_mut()
                .unwrap()
                .remove("recordVersion")
                .map(|_| ())
                .unwrap(),
            2 => body["records"][0]["unexpected"] = json!(true),
            3 => body["records"][0]["blob"] = json!("YQ"), // noncanonical unpadded standard Base64
            _ => body["hasMore"] = json!(true),
        }
        let (client, worker) = fixture(vec![space(&scope()), Step::json(body)]);
        let mut transport = bound(client);
        assert_eq!(
            transport
                .fetch_page(if kind == 4 { Some(&cursor) } else { None })
                .err(),
            Some(Failure::InvalidResponse)
        );
        worker.join().unwrap();
    }
    let cursor = Cursor("fixture/&?cursor=other".into());
    let (client, worker) = fixture(vec![space(&scope()), page(&scope(), false)]);
    let mut transport = bound(client);
    transport.fetch_page(Some(&cursor)).unwrap();
    let requests = worker.join().unwrap();
    let target = &requests[1].target;
    assert!(
        target.contains("cursor=fixture%2F%26%3Fcursor%3Dother")
            && target.matches("cursor=").count() == 1
    );
}

#[test]
fn batch_carries_explicit_create_null_original_cas_and_validates_positional_results() {
    let conflict = json!({"kind":"conflict","authoritativeRecord":server_record(11)});
    let (client, worker) = fixture(vec![
        space(&scope()),
        batch(&scope(), vec![accepted(), conflict], true),
    ]);
    let mut transport = bound(client);
    let mut update = offer(11);
    update.expected_record_version =
        Some(RecordVersion("fixture-version-afixture-version-a".into()));
    let result = transport.submit_chunk(&[offer(10), update]).unwrap();
    assert!(result.outcomes.len() == 2 && result.partial);
    let requests = worker.join().unwrap();
    let body = requests[1].json();
    assert!(body["expectedScope"] == serde_json::to_value(scope()).unwrap());
    assert!(
        body["items"][0]
            .as_object()
            .unwrap()
            .contains_key("expectedRecordVersion")
            && body["items"][0]["expectedRecordVersion"].is_null()
    );
    assert!(body["items"][1]["expectedRecordVersion"] == "fixture-version-afixture-version-a");
    assert!(body["items"][0]["record"].as_object().unwrap().len() == 4);
    for kind in 0..5 {
        let mut body: Value =
            serde_json::from_slice(&batch(&scope(), vec![accepted()], false).body).unwrap();
        match kind {
            0 => body["outcomes"] = json!([]),
            1 => body["outcomes"][0]["revision"] = json!("wrong"),
            2 => {
                body["outcomes"][0] =
                    json!({"kind":"conflict","authoritativeRecord":server_record(99)})
            }
            3 => body["outcomes"][0] = json!({"kind":"accepted","revision":"a".repeat(32)}),
            _ => body["partial"] = json!(true),
        };
        let (client, worker) = fixture(vec![space(&scope()), Step::json(body)]);
        let mut transport = bound(client);
        assert_eq!(
            transport.submit_chunk(&[offer(10)]).err(),
            Some(Failure::InvalidResponse)
        );
        worker.join().unwrap();
    }
}

#[test]
fn feed_retry_preserves_the_immutable_offer_and_adopts_only_same_dataset() {
    let mut rotated = scope();
    rotated.feed_epoch = Uuid::from_u128(5);
    let mut after = rotated.clone();
    after.feed_epoch = Uuid::from_u128(6);
    let (client, worker) = fixture(vec![
        space(&scope()),
        Step::problem("cursor_invalid"),
        space(&rotated),
        batch(&after, vec![accepted()], false),
        space(&after),
        batch(&after, vec![accepted()], false),
    ]);
    let mut transport = bound(client);
    let mut offer = offer(10);
    offer.expected_record_version =
        Some(RecordVersion("fixture-version-afixture-version-a".into()));
    transport.submit_chunk(&[offer.clone()]).unwrap();
    transport.submit_chunk(&[offer]).unwrap();
    let requests = worker.join().unwrap();
    assert!(requests[1].json()["items"] == requests[3].json()["items"]);
    assert!(requests[3].json()["expectedScope"] == serde_json::to_value(rotated).unwrap());
    assert!(requests[5].json()["expectedScope"] == serde_json::to_value(after).unwrap());
    let (client, worker) = fixture(vec![
        space(&scope()),
        Step::problem("cursor_invalid"),
        space(&scope()),
        Step::problem("cursor_invalid"),
    ]);
    let mut transport = bound(client);
    assert!(matches!(
        transport.submit_chunk(&[crate::cloud::tests::offer(10)]),
        Err(Failure::Server {
            code: ErrorCode::CursorInvalid,
            ..
        })
    ));
    assert!(worker.join().unwrap().len() == 4);
    let mut foreign = scope();
    foreign.dataset_generation = Uuid::from_u128(77);
    let (client, worker) = fixture(vec![
        space(&scope()),
        batch(&foreign, vec![accepted()], false),
    ]);
    let mut transport = bound(client);
    assert_eq!(
        transport
            .submit_chunk(&[crate::cloud::tests::offer(10)])
            .err(),
        Some(Failure::DatasetReview)
    );
    assert_eq!(transport.preflight().err(), Some(Failure::DatasetReview));
    worker.join().unwrap();
}

#[test]
fn redirects_encodings_and_streaming_size_cannot_forward_or_expand_credentials() {
    let destination = TcpListener::bind("127.0.0.1:0").unwrap();
    destination.set_nonblocking(true).unwrap();
    let mut redirect = Step::json(Value::Null);
    redirect.status = 307;
    redirect.headers.push((
        "Location".into(),
        format!("http://{}/sink", destination.local_addr().unwrap()),
    ));
    let (client, worker) = fixture(vec![redirect]);
    assert_eq!(
        client.list_spaces(&token()).err(),
        Some(Failure::InvalidResponse)
    );
    worker.join().unwrap();
    assert!(destination.accept().is_err());
    for mode in 0..4 {
        let mut step = Step::json(json!({"fixture":"x".repeat(64)}));
        match mode {
            0 => step
                .headers
                .push(("Content-Encoding".into(), "gzip".into())),
            1 => step.chunked = true,
            2 => step.content_type = "text/html".into(),
            _ => step
                .headers
                .push(("Content-Type".into(), "application/json".into())),
        };
        let (client, worker) = fixture(vec![step]);
        let result = client.exchange(
            Method::GET,
            client.server.endpoint("/fixture").unwrap(),
            Some(&token()),
            None,
            Reply::new(200, if mode == 1 { 32 } else { MAX_AUTH }),
        );
        assert_eq!(
            result.err(),
            Some(if mode == 1 {
                Failure::MessageTooLarge
            } else {
                Failure::InvalidResponse
            })
        );
        worker.join().unwrap();
    }
    let (client, worker) = fixture(vec![Step::json(json!({"fixture":"x".repeat(64)}))]);
    assert_eq!(
        client
            .exchange(
                Method::GET,
                client.server.endpoint("/fixture").unwrap(),
                None,
                None,
                Reply::new(200, 32)
            )
            .err(),
        Some(Failure::MessageTooLarge)
    );
    worker.join().unwrap();
}

#[test]
fn server_failure_types_status_and_vocabulary_are_closed() {
    let (client, worker) = fixture(vec![Step::problem("rate_limited")]);
    let failure = client.list_spaces(&token()).err().unwrap();
    assert!(matches!(
        failure,
        Failure::Server {
            code: ErrorCode::RateLimited,
            ..
        }
    ));
    assert!(!format!("{failure:?} {failure}").contains("00000000"));
    worker.join().unwrap();
    for mode in 0..5 {
        let mut step = Step::problem("rate_limited");
        let mut body: Value = serde_json::from_slice(&step.body).unwrap();
        match mode {
            0 => body["type"] = json!("urn:snippets:error:conflict"),
            1 => body["status"] = json!(400),
            2 => body["code"] = json!("arbitrary-private-error"),
            3 => body["message"] = json!("arbitrary-private-error"),
            _ => body["retryAfterSeconds"] = Value::Null,
        };
        step.body = serde_json::to_vec(&body).unwrap();
        let (client, worker) = fixture(vec![step]);
        assert_eq!(
            client.list_spaces(&token()).err(),
            Some(Failure::InvalidResponse)
        );
        worker.join().unwrap();
    }
    let mut readonly = space(&scope());
    let mut body: Value = serde_json::from_slice(&readonly.body).unwrap();
    body["role"] = json!("reader");
    readonly.body = serde_json::to_vec(&body).unwrap();
    let (client, worker) = fixture(vec![readonly]);
    let mut transport = bound(client);
    assert_eq!(
        transport.submit_chunk(&[offer(10)]).err(),
        Some(Failure::ReadOnly)
    );
    assert!(worker.join().unwrap().len() == 1);
}

#[test]
fn scope_identity_matches_independent_length_framed_digest_fixture() {
    let fixture: Value =
        serde_json::from_str(include_str!("../tests/fixtures/sync-wire-v1.json")).unwrap();
    let scope: Scope = serde_json::from_value(fixture["scope"].clone()).unwrap();
    let server = ServerURL::parse(fixture["baseURL"].as_str().unwrap()).unwrap();
    let (membership, dataset) = scope.identities(&server);
    let hex = |bytes: &[u8]| bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    assert!(
        hex(membership.bytes_for_checkpoint())
            == fixture["bindings"]["membership"].as_str().unwrap()
    );
    assert!(
        hex(dataset.bytes_for_checkpoint()) == fixture["bindings"]["dataset"].as_str().unwrap()
    );
    let mut rotated = scope.clone();
    rotated.feed_epoch = Uuid::from_u128(100);
    assert!(scope.identities(&server) == rotated.identities(&server));
    rotated.dataset_generation = Uuid::from_u128(200);
    assert!(
        rotated.identities(&server).0 == membership && rotated.identities(&server).1 != dataset
    );
}

fn bootstrap_public() -> [u8; 32] {
    use base64::{Engine, engine::general_purpose::STANDARD};
    STANDARD
        .decode("BpJCgx4cUQSQFyZtp9NGBSH/vu8g+LUff0Gzc60K4kc=")
        .unwrap()
        .try_into()
        .unwrap()
}
fn recovery_response(scope: &Scope, version: u64, ciphertext: &[u8]) -> Value {
    use base64::{Engine, engine::general_purpose::STANDARD};
    json!({"scope":scope,"keyEpoch":1,"recovery":{"purpose":"recovery","version":version,"keyEpoch":1,"algorithm":crate::bootstrap::RECOVERY_ALGORITHM,"ciphertext":STANDARD.encode(ciphertext),"createdAt":"2026-09-30T12:00:00.123456789Z"}})
}

#[test]
fn bootstrap_reads_and_atomic_initial_post_preserve_scope_epoch_and_explicit_null_cas() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let ciphertext = [7; 40];
    let (client, worker) = fixture(vec![
        space(&scope()),
        Step::json(json!({"scope":scope(),"keyEpoch":1,"publicKey":null})),
        space(&scope()),
        Step::json(json!({"scope":scope(),"keyEpoch":1,"recovery":null})),
        space(&scope()),
        Step::json(recovery_response(&scope(), 1, &ciphertext)),
    ]);
    let mut transport = bound(client);
    let authority = transport.key_authority().unwrap();
    assert!(authority.epoch() == 1 && authority.public_key().is_none());
    let recovery = transport.recovery_state().unwrap();
    assert!(recovery.epoch() == 1 && recovery.recovery().is_none());
    let receipt = transport
        .bootstrap_library_key(&bootstrap_public(), &ciphertext)
        .unwrap();
    assert!(receipt.version() == 1 && receipt.epoch() == 1 && receipt.ciphertext() == ciphertext);
    let requests = worker.join().unwrap();
    assert_eq!(requests.len(), 6);
    assert!(
        requests[1].target.ends_with("/key-authority")
            && requests[3].target.ends_with("/recovery-envelope")
    );
    assert!(requests[5].method == "POST" && requests[5].target.ends_with("/key-bootstrap"));
    assert!(
        requests[5].json()
            == json!({"expectedScope":scope(),"publicKey":STANDARD.encode(bootstrap_public()),
        "recovery":{"expectedVersion":null,"keyEpoch":1,"algorithm":crate::bootstrap::RECOVERY_ALGORITHM,"ciphertext":STANDARD.encode(ciphertext)}})
    );
    assert!(requests.iter().all(|r| {
        r.headers
            .get("authorization")
            .is_some_and(|v| v == "Bearer fixture-access")
    }));
}

#[test]
fn bootstrap_control_responses_halt_sticky_before_another_scope_or_epoch_can_be_used() {
    for mutation in 0..4 {
        let mut changed = scope();
        let (epoch, expected) = match mutation {
            0 => {
                changed.server_instance_id = Uuid::from_u128(99);
                (1, Failure::AccountReview)
            }
            1 => {
                changed.scope_binding = "different-public-membership-binding".into();
                (1, Failure::AccountReview)
            }
            2 => {
                changed.dataset_generation = Uuid::from_u128(99);
                (1, Failure::DatasetReview)
            }
            _ => (2, Failure::DatasetReview),
        };
        let (client, worker) = fixture(vec![
            space(&scope()),
            Step::json(json!({"scope":changed,"keyEpoch":epoch,"publicKey":null})),
        ]);
        let mut transport = bound(client);
        assert!(transport.key_authority().err() == Some(expected));
        assert!(transport.recovery_state().err() == Some(expected));
        assert!(transport.fetch_page(None).err() == Some(expected));
        assert!(
            transport
                .bootstrap_library_key(&bootstrap_public(), &[1; 40])
                .err()
                == Some(expected)
        );
        assert_eq!(worker.join().unwrap().len(), 2);
    }
}

#[test]
fn changed_or_invalid_key_epoch_stops_at_preflight_and_nil_scope_coordinates_are_refused() {
    for mutation in 0..6 {
        let mut value = serde_json::from_slice::<Value>(&space(&scope()).body).unwrap();
        match mutation {
            0 => value["keyEpoch"] = json!(2),
            1 => value["keyEpoch"] = json!(0),
            2 => value["keyEpoch"] = json!(u64::MAX),
            3 => value["scope"]["spaceId"] = json!(Uuid::nil()),
            4 => value["scope"]["datasetGeneration"] = json!(Uuid::nil()),
            _ => value["scope"]["feedEpoch"] = json!(Uuid::nil()),
        }
        let (client, worker) = fixture(vec![Step::json(value)]);
        let mut transport = bound(client);
        let expected = if mutation == 0 {
            Failure::DatasetReview
        } else {
            Failure::InvalidResponse
        };
        assert!(transport.key_authority().err() == Some(expected));
        if mutation == 0 {
            assert!(transport.fetch_page(None).err() == Some(expected));
            assert!(transport.recovery_state().err() == Some(expected));
        }
        let requests = worker.join().unwrap();
        assert!(requests.len() == 1 && !requests[0].target.contains("key-authority"));
    }
}

#[test]
fn bootstrap_receipts_require_exact_ciphertext_version_algorithm_and_full_binding() {
    for mutation in 0..8 {
        let ciphertext = [7; 40];
        let mut response = recovery_response(&scope(), 1, &ciphertext);
        let expected = match mutation {
            0 => {
                response["recovery"]["version"] = json!(2);
                Failure::InvalidResponse
            }
            1 => {
                response["recovery"]["ciphertext"] =
                    json!("BgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBg==");
                Failure::InvalidResponse
            }
            2 => {
                response["recovery"]["algorithm"] = json!("unknown-v2");
                Failure::InvalidResponse
            }
            3 => {
                response["recovery"]["extra"] = json!(true);
                Failure::InvalidResponse
            }
            4 => {
                response["recovery"]["keyEpoch"] = json!(2);
                Failure::InvalidResponse
            }
            5 => {
                response["recovery"] = Value::Null;
                Failure::InvalidResponse
            }
            6 => {
                response["scope"]["datasetGeneration"] = json!(Uuid::from_u128(100));
                Failure::DatasetReview
            }
            _ => {
                response["keyEpoch"] = json!(2);
                Failure::DatasetReview
            }
        };
        let (client, worker) = fixture(vec![space(&scope()), Step::json(response)]);
        let mut transport = bound(client);
        assert!(
            transport
                .bootstrap_library_key(&bootstrap_public(), &ciphertext)
                .err()
                == Some(expected)
        );
        assert_eq!(worker.join().unwrap().len(), 2);
    }
}

#[test]
fn bootstrap_payload_validation_and_owner_role_refuse_unsafe_posts() {
    let (client, worker) = fixture(vec![]);
    let mut transport = bound(client);
    assert!(
        transport.bootstrap_library_key(&[0; 32], &[1; 40]).err() == Some(Failure::InvalidResponse)
    );
    assert!(
        transport
            .bootstrap_library_key(&bootstrap_public(), &[1; 27])
            .err()
            == Some(Failure::InvalidResponse)
    );
    assert!(
        transport
            .bootstrap_library_key(&bootstrap_public(), &[1; 4097])
            .err()
            == Some(Failure::InvalidResponse)
    );
    assert!(worker.join().unwrap().is_empty());
    for role in ["reader", "writer"] {
        let mut value = serde_json::from_slice::<Value>(&space(&scope()).body).unwrap();
        value["role"] = json!(role);
        let (client, worker) = fixture(vec![Step::json(value)]);
        let mut transport = bound(client);
        assert!(
            transport
                .bootstrap_library_key(&bootstrap_public(), &[1; 40])
                .err()
                == Some(Failure::ReadOnly)
        );
        assert_eq!(worker.join().unwrap().len(), 1);
    }
}

#[test]
fn bootstrap_metadata_rejects_weak_noncanonical_authorities_and_malformed_recovery_envelopes() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    for public in [
        STANDARD.encode([0; 32]),
        STANDARD.encode([0; 31]),
        format!("{}=", STANDARD.encode(bootstrap_public())),
    ] {
        let (client, worker) = fixture(vec![
            space(&scope()),
            Step::json(json!({"scope":scope(),"keyEpoch":1,"publicKey":public})),
        ]);
        assert!(bound(client).key_authority().err() == Some(Failure::InvalidResponse));
        assert_eq!(worker.join().unwrap().len(), 2);
    }
    for mutation in 0..6 {
        let mut response = recovery_response(&scope(), 1, &[7; 40]);
        match mutation {
            0 => response["recovery"]["version"] = json!(0),
            1 => response["recovery"]["keyEpoch"] = json!(2),
            2 => response["recovery"]["ciphertext"] = json!(STANDARD.encode([0; 27])),
            3 => response["recovery"]["ciphertext"] = json!(STANDARD.encode([0; 4097])),
            4 => {
                response["recovery"]["ciphertext"] = json!(format!(
                    "{}=",
                    response["recovery"]["ciphertext"].as_str().unwrap()
                ))
            }
            _ => response["recovery"]["algorithm"] = json!("unknown"),
        }
        let (client, worker) = fixture(vec![space(&scope()), Step::json(response)]);
        assert!(bound(client).recovery_state().err() == Some(Failure::InvalidResponse));
        assert_eq!(worker.join().unwrap().len(), 2);
    }
}
