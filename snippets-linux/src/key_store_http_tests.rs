//! Real certificate-verified loopback TLS with fictional server/account data.
use super::*;
use crate::{
    bootstrap::{Invitation, PairingDraft},
    cloud::{CloudClient, Credential},
    key_store::recipient,
};
use serde_json::{Value as Json, json};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::atomic::{AtomicBool, Ordering},
    thread::{self, JoinHandle},
    time::Duration,
};

const CA: &[u8] = include_bytes!("../tests/fixtures/loopback-ca.der");
const CERT: &[u8] = include_bytes!("../tests/fixtures/loopback-server.der");
const KEY: &[u8] = include_bytes!("../tests/fixtures/loopback-public-test-key.der");
#[derive(Default)]
struct State {
    public: Option<String>,
    ciphertext: Option<String>,
    posts: usize,
    requests: usize,
    lose_reply: bool,
    reset_after_post: bool,
    dataset: u128,
    pairing: Option<Invitation>,
    pairing_cipher: Option<Vec<u8>>,
    pairing_creates: usize,
    pairing_claims: usize,
    lose_claim: bool,
    reset_after_claim: bool,
    pairing_expired: bool,
}
struct Fixture {
    server: ServerURL,
    state: Arc<Mutex<State>>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
impl Fixture {
    fn new(memory: Memory, lose_reply: bool, reset_after_post: bool) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let server =
            ServerURL::parse(&format!("https://{}", listener.local_addr().unwrap())).unwrap();
        let state = Arc::new(Mutex::new(State {
            lose_reply,
            reset_after_post,
            dataset: 3,
            ..State::default()
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let thread_state = state.clone();
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![rustls::pki_types::CertificateDer::from(CERT.to_vec())],
            rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
                KEY.to_vec(),
            )),
        )
        .unwrap();
        let config = Arc::new(config);
        let thread_server = server.clone();
        let worker = thread::spawn(move || {
            while !thread_stop.load(Ordering::SeqCst) {
                let tcp = match listener.accept() {
                    Ok((tcp, _)) => tcp,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(_) => panic!("loopback TLS accept failed"),
                };
                tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
                tcp.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
                let mut stream = rustls::StreamOwned::new(
                    rustls::ServerConnection::new(config.clone()).unwrap(),
                    tcp,
                );
                let Ok((method, path, body)) = request(&mut stream) else {
                    continue;
                };
                let mut state = thread_state.lock().unwrap();
                state.requests += 1;
                let mut status = 200;
                let response = if path.ends_with("/pairings") {
                    assert!(method == "POST");
                    state.pairing_creates += 1;
                    let bytes = memory.slot(Slot::PairingRecipient).unwrap();
                    let v = canonical::parse(&bytes).unwrap();
                    let phase = v.as_object().unwrap()["phase"].as_object().unwrap();
                    assert!(
                        phase["kind"].as_text().unwrap() == "creating"
                            && phase["sent"] == Value::Bool(true)
                    );
                    let draft =
                        PairingDraft::decode_secret(&phase["secret"].encode().unwrap()).unwrap();
                    assert!(body["recipientPublicKey"] == STANDARD.encode(draft.public_key()));
                    assert!(body["nonce"] == STANDARD.encode(draft.nonce()));
                    assert!(body["expiresInSeconds"] == 300);
                    let now = chrono::Utc::now().timestamp();
                    state.pairing = Some(
                        Invitation::new(
                            thread_server.clone(),
                            Uuid::from_u128(2),
                            Uuid::from_u128(100),
                            *draft.nonce(),
                            *draft.public_key(),
                            now + 300,
                            now,
                        )
                        .unwrap(),
                    );
                    status = 201;
                    pairing(&state)
                } else if path.contains("/pairings/") {
                    let invitation = state.pairing.as_ref().unwrap();
                    let base = format!(
                        "/v2/spaces/{}/pairings/{}",
                        Uuid::from_u128(2),
                        invitation.pairing()
                    );
                    assert!(path == base || path == format!("{base}/claim"));
                    if state.pairing_expired {
                        status = 410;
                        json!({"type":"urn:snippets:error:pairing_expired","status":410,"code":"pairing_expired","requestId":Uuid::from_u128(99)})
                    } else if path.ends_with("/claim") {
                        assert!(method == "POST");
                        state.pairing_claims += 1;
                        let bytes = memory.slot(Slot::PairingRecipient).unwrap();
                        let v = canonical::parse(&bytes).unwrap();
                        assert!(
                            v.as_object().unwrap()["phase"].as_object().unwrap()["kind"]
                                .as_text()
                                .unwrap()
                                == "waiting"
                        );
                        if state.reset_after_claim {
                            state.dataset = 99;
                        }
                        if state.lose_claim {
                            state.lose_claim = false;
                            continue;
                        }
                        json!({"scope":scope(&state),"pairingId":Uuid::from_u128(100),"algorithm":bootstrap::PAIRING_ALGORITHM,"ciphertext":STANDARD.encode(state.pairing_cipher.as_ref().unwrap())})
                    } else {
                        assert!(method == "GET");
                        pairing(&state)
                    }
                } else if path.ends_with("/key-bootstrap") {
                    assert!(method == "POST");
                    state.posts += 1;
                    assert!(memory.slot(Slot::LibraryKey).is_none());
                    let bytes = memory.slot(Slot::Bootstrap).unwrap();
                    let v = canonical::parse(&bytes).unwrap();
                    let pending = Pending::parse(&v.as_object().unwrap()["pending"]).unwrap();
                    assert!(
                        body["publicKey"]
                            == STANDARD.encode(
                                Authority::new(
                                    &pending.bundle,
                                    &pending.binding.context().unwrap()
                                )
                                .public_key()
                            )
                    );
                    assert!(body["recovery"]["ciphertext"] == STANDARD.encode(&pending.ciphertext));
                    assert!(body["expectedScope"] == scope(&state));
                    assert!(body["recovery"]["expectedVersion"].is_null());
                    assert!(body.get("bundle").is_none() && body.get("key").is_none());
                    if state.public.is_some() {
                        status = 409;
                        json!({"type":"urn:snippets:error:conflict","status":409,"code":"conflict","requestId":Uuid::from_u128(99)})
                    } else {
                        state.public = Some(body["publicKey"].as_str().unwrap().into());
                        state.ciphertext =
                            Some(body["recovery"]["ciphertext"].as_str().unwrap().into());
                        if state.reset_after_post {
                            state.dataset = 99;
                        }
                        if state.lose_reply {
                            state.lose_reply = false;
                            continue;
                        }
                        recovery(&state)
                    }
                } else if path.ends_with("/key-authority") {
                    assert!(method == "GET");
                    json!({"scope":scope(&state),"keyEpoch":1,"publicKey":state.public})
                } else if path.ends_with("/recovery-envelope") {
                    assert!(method == "GET");
                    recovery(&state)
                } else if path.contains("/changes?") {
                    assert!(method == "GET");
                    json!({"scope":scope(&state),"records":[],"cursor":"fixture-cursor","fullSnapshot":true,"hasMore":false})
                } else {
                    assert!(
                        method == "GET" && path == format!("/v2/spaces/{}", Uuid::from_u128(2))
                    );
                    json!({"scope":scope(&state),"role":"owner","keyEpoch":1})
                };
                let bytes = serde_json::to_vec(&response).unwrap();
                let media = if (200..300).contains(&status) {
                    "application/json"
                } else {
                    "application/problem+json"
                };
                write!(stream,"HTTP/1.1 {status} Fixture\r\nConnection: close\r\nContent-Type: {media}\r\nContent-Length: {}\r\n\r\n",bytes.len()).unwrap();
                stream.write_all(&bytes).unwrap();
                stream.flush().unwrap();
            }
        });
        Self {
            server,
            state,
            stop,
            worker: Some(worker),
        }
    }
    fn transport(&self, trusted: bool) -> BoundTransport {
        let mut config = ureq::Agent::config_builder()
            .https_only(true)
            .max_redirects(0)
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(5)));
        if trusted {
            config = config.tls_config(
                ureq::tls::TlsConfig::builder()
                    .root_certs(ureq::tls::RootCerts::new_with_certs(&[
                        ureq::tls::Certificate::from_der(CA),
                    ]))
                    .build(),
            );
        }
        let client = CloudClient::test_with_agent(
            self.server.clone(),
            config.build().into(),
            Uuid::from_u128(1),
        );
        let observed: cloud::Space = serde_json::from_value(
            json!({"scope":scope(&self.state.lock().unwrap()),"role":"owner","keyEpoch":1}),
        )
        .unwrap();
        let (membership, dataset) = observed.scope.identities(&self.server);
        client
            .admit(
                Credential::new("fictional-access".into()).unwrap(),
                observed,
                &membership,
                &dataset,
            )
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let result = worker.join();
            if !thread::panicking() {
                assert!(result.is_ok());
            }
        }
    }
}
fn scope(state: &State) -> Json {
    json!({"serverInstanceId":Uuid::from_u128(1),"spaceId":Uuid::from_u128(2),"scopeBinding":"public-fictional-membership-binding","datasetGeneration":Uuid::from_u128(state.dataset),"feedEpoch":Uuid::from_u128(4)})
}
fn recovery(state: &State) -> Json {
    let envelope=state.ciphertext.as_ref().map(|cipher|json!({"purpose":"recovery","version":1,"keyEpoch":1,"algorithm":bootstrap::RECOVERY_ALGORITHM,"ciphertext":cipher,"createdAt":"2026-09-30T12:00:00.123456789Z"}));
    json!({"scope":scope(state),"keyEpoch":1,"recovery":envelope})
}
fn pairing(state: &State) -> Json {
    let invitation = state.pairing.as_ref().unwrap();
    let expiry = chrono::DateTime::from_timestamp(invitation.expires_at(), 0)
        .unwrap()
        .to_rfc3339();
    json!({"scope":scope(state),"pairing":{"pairingId":invitation.pairing(),"recipientPublicKey":STANDARD.encode(invitation.public_key()),"nonce":STANDARD.encode(invitation.nonce()),"authenticationTag":invitation.confirmation_code(),"state":if state.pairing_cipher.is_some(){"approved"}else{"pending"},"expiresAt":expiry}})
}
fn request(
    stream: &mut rustls::StreamOwned<rustls::ServerConnection, TcpStream>,
) -> std::io::Result<(String, String, Json)> {
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        let mut byte = [0];
        stream.read_exact(&mut byte)?;
        header.push(byte[0]);
        assert!(header.len() < 16 * 1024);
    }
    let header = String::from_utf8(header).unwrap();
    let mut lines = header.split("\r\n");
    let mut first = lines.next().unwrap().split_whitespace();
    let method = first.next().unwrap().to_owned();
    let path = first.next().unwrap().to_owned();
    let fields: BTreeMap<_, _> = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(k, v)| (k.to_ascii_lowercase(), v.trim()))
        .collect();
    assert!(fields.get("authorization") == Some(&"Bearer fictional-access"));
    let len = fields
        .get("content-length")
        .map_or(0, |v| v.parse::<usize>().unwrap());
    assert!(len < 32 * 1024);
    let mut body = vec![0; len];
    stream.read_exact(&mut body)?;
    Ok((
        method,
        path,
        if body.is_empty() {
            Json::Null
        } else {
            serde_json::from_slice(&body).unwrap()
        },
    ))
}
#[test]
fn verified_https_onboarding_recovers_a_lost_receipt_and_restores_another_installation() {
    let memory = Memory::default();
    let temp = tempfile::tempdir().unwrap();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let fixture = Fixture::new(memory.clone(), true, false);
    let mut remote = fixture.transport(true);
    assert!(
        super::super::initialize(&mut store, &mut remote).err()
            == Some(Failure::Cloud(cloud::Failure::Network))
    );
    let candidate = memory.slot(Slot::Bootstrap).unwrap();
    assert!(memory.slot(Slot::LibraryKey).is_none());
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    assert!(
        super::super::initialize(&mut store, &mut remote).unwrap()
            == Outcome::Ready {
                kit: KitStatus::AwaitingPresentation
            }
    );
    let first = super::super::load_verified(&mut store, &mut remote)
        .unwrap()
        .unwrap();
    let v = canonical::parse(&candidate).unwrap();
    let p = Pending::parse(&v.as_object().unwrap()["pending"]).unwrap();
    assert!(p.bundle.for_secure_storage() == first.bundle.for_secure_storage());
    let target = super::super::disclosure::prepare(&mut store, &mut remote).unwrap();
    let mut gate = crate::local_auth::Gate::new();
    gate.set_foreground(true);
    let request = gate
        .begin(
            target,
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )
        .unwrap();
    // This explicitly synthetic proof is separate from the private PAM fixtures;
    // neither test attempts authentication against a real user account.
    let authenticated = crate::local_auth::authenticate_fixture(request).unwrap();
    let permit = gate.accept(authenticated).unwrap();
    let shown = super::super::disclosure::reveal(&mut store, &mut remote, permit)
        .ok()
        .unwrap();
    assert!(shown.qr_payload().unwrap() == p.kit.encode_secret_qr().unwrap().as_slice());
    gate.set_foreground(false);
    assert!(shown.qr_payload().is_err());
    drop(shown);
    gate.set_foreground(true);
    let request = gate
        .begin(
            super::super::disclosure::prepare(&mut store, &mut remote).unwrap(),
            crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
        )
        .unwrap();
    let permit = gate
        .accept(crate::local_auth::authenticate_fixture(request).unwrap())
        .unwrap();
    let shown = super::super::disclosure::reveal(&mut store, &mut remote, permit)
        .ok()
        .unwrap();
    let mut suffix = Zeroizing::new(
        shown
            .long_code()
            .unwrap()
            .chars()
            .filter(|c| c.is_alphanumeric())
            .rev()
            .take(8)
            .collect::<Vec<_>>(),
    );
    suffix.reverse();
    let suffix = Zeroizing::new(suffix.iter().collect());
    assert!(
        super::super::disclosure::confirm_saved(&mut store, &mut remote, shown, suffix).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    assert!(
        super::super::disclosure::prepare(&mut store, &mut remote).err()
            == Some(Failure::RecoveryUnavailable)
    );
    let archive = store.transaction_with(Archive::load).unwrap();
    assert!(archive.presentation.unwrap().retained().is_err());
    let temp2 = tempfile::tempdir().unwrap();
    let mut second_store = Store::initialize(temp2.path(), Memory::default()).unwrap();
    let mut second_remote = fixture.transport(true);
    assert!(
        super::super::recover(&mut second_store, &mut second_remote, p.kit).unwrap()
            == Outcome::Ready {
                kit: KitStatus::VerifiedCurrent
            }
    );
    let second = super::super::load_verified(&mut second_store, &mut second_remote)
        .unwrap()
        .unwrap();
    assert!(first.bundle.for_secure_storage() == second.bundle.for_secure_storage());
    assert_eq!(fixture.state.lock().unwrap().posts, 1);
}
#[test]
fn normal_tls_trust_rejects_the_fixture_certificate_before_any_http_or_key_creation() {
    let memory = Memory::default();
    let temp = tempfile::tempdir().unwrap();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let fixture = Fixture::new(memory.clone(), false, false);
    let mut remote = fixture.transport(false);
    assert!(
        super::super::initialize(&mut store, &mut remote).err()
            == Some(Failure::Cloud(cloud::Failure::Network))
    );
    assert!(memory.slot(Slot::LibraryKey).is_none() && memory.slot(Slot::Bootstrap).is_none());
    assert_eq!(fixture.state.lock().unwrap().requests, 0);
}
#[test]
fn scope_reset_in_the_bootstrap_receipt_halts_without_activating_or_losing_the_candidate() {
    let memory = Memory::default();
    let temp = tempfile::tempdir().unwrap();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let fixture = Fixture::new(memory.clone(), false, true);
    let mut remote = fixture.transport(true);
    assert!(
        super::super::initialize(&mut store, &mut remote).err()
            == Some(Failure::Cloud(cloud::Failure::DatasetReview))
    );
    let candidate = memory.slot(Slot::Bootstrap).unwrap();
    let requests = fixture.state.lock().unwrap().requests;
    assert!(
        super::super::initialize(&mut store, &mut remote).err()
            == Some(Failure::Cloud(cloud::Failure::DatasetReview))
    );
    assert!(
        memory.slot(Slot::Bootstrap).unwrap() == candidate
            && memory.slot(Slot::LibraryKey).is_none()
    );
    assert_eq!(fixture.state.lock().unwrap().requests, requests);
}

fn recipient_ok<T>(result: recipient::Result<T>) -> T {
    match result {
        Ok(value) => value,
        Err(rejected) => panic!("closed recipient failure: {:?}", rejected.failure),
    }
}
fn recipient_error<T>(result: recipient::Result<T>) -> recipient::Rejected {
    match result {
        Ok(_) => panic!("expected a closed recipient refusal"),
        Err(rejected) => rejected,
    }
}
fn seed_authority(fixture: &Fixture) -> Bundle {
    // This is the fictional trusted client's bundle, outside the server thread.
    // The HTTP fixture receives only its public authority and sealed envelope.
    let bundle = Bundle::from_material(&[7; 64]).unwrap();
    let context = AuthorityContext::new(
        fixture.server.clone(),
        Uuid::from_u128(1),
        Uuid::from_u128(2),
    )
    .unwrap();
    fixture.state.lock().unwrap().public =
        Some(STANDARD.encode(Authority::new(&bundle, &context).public_key()));
    bundle
}
fn approve_recipient(fixture: &Fixture, bundle: &Bundle) {
    let mut state = fixture.state.lock().unwrap();
    let ciphertext = bootstrap::seal_pairing(
        bundle,
        state.pairing.as_ref().unwrap(),
        chrono::Utc::now().timestamp(),
    )
    .unwrap();
    state.pairing_cipher = Some(ciphertext);
}
#[test]
fn verified_https_recipient_retries_lost_claim_and_retains_failed_secret_receipt_past_expiry() {
    let memory = Memory::default();
    let temp = tempfile::tempdir().unwrap();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let fixture = Fixture::new(memory.clone(), false, false);
    let bundle = seed_authority(&fixture);
    let mut remote = fixture.transport(true);
    let invitation = match recipient_ok(recipient::begin(&mut store, &mut remote)) {
        recipient::Outcome::Waiting(invitation) => invitation,
        _ => panic!("expected a durable invitation"),
    };
    let saved = memory.slot(Slot::PairingRecipient).unwrap();
    let requests = fixture.state.lock().unwrap().requests;
    let status = recipient::inspect_retained(&mut store, &remote)
        .unwrap()
        .unwrap();
    assert!(
        matches!(status, recipient::RetainedStatus::Waiting { invitation: ref v, received: false } if v == &invitation)
    );
    assert_eq!(fixture.state.lock().unwrap().requests, requests);
    approve_recipient(&fixture, &bundle);
    fixture.state.lock().unwrap().lose_claim = true;
    assert!(
        recipient_error(recipient::check(&mut store, &mut remote)).failure
            == Failure::Cloud(cloud::Failure::Network)
    );
    assert!(memory.slot(Slot::PairingRecipient).unwrap() == saved);
    drop(store);
    let mut store = Store::load(temp.path(), memory.clone()).unwrap();
    memory.0.lock().unwrap().fail_write = Some((4, false));
    let rejected = recipient_error(recipient::check(&mut store, &mut remote));
    assert!(rejected.failure == Failure::Secret(secret_store::Failure::Unavailable));
    fixture.state.lock().unwrap().pairing_expired = true;
    recipient_ok(rejected.unrecorded.unwrap().retain(&mut store));
    assert!(matches!(
        recipient_ok(recipient::check(&mut store, &mut remote)),
        recipient::Outcome::Ready {
            kit: KitStatus::None
        }
    ));
    let verified = super::super::load_verified(&mut store, &mut remote)
        .unwrap()
        .unwrap();
    assert!(verified.bundle.for_secure_storage() == bundle.for_secure_storage());
    let state = fixture.state.lock().unwrap();
    assert!(state.pairing.as_ref() == Some(&invitation));
    assert!(state.pairing_creates == 1 && state.pairing_claims == 2);
    assert!(state.posts == 0);
}
#[test]
fn verified_https_scope_reset_during_claim_halts_before_key_installation_and_preserves_pairing() {
    let memory = Memory::default();
    let temp = tempfile::tempdir().unwrap();
    let mut store = Store::initialize(temp.path(), memory.clone()).unwrap();
    let fixture = Fixture::new(memory.clone(), false, false);
    let bundle = seed_authority(&fixture);
    let mut remote = fixture.transport(true);
    recipient_ok(recipient::begin(&mut store, &mut remote));
    let saved = memory.slot(Slot::PairingRecipient).unwrap();
    approve_recipient(&fixture, &bundle);
    fixture.state.lock().unwrap().reset_after_claim = true;
    assert!(
        recipient_error(recipient::check(&mut store, &mut remote)).failure
            == Failure::Cloud(cloud::Failure::DatasetReview)
    );
    assert!(
        memory.slot(Slot::PairingRecipient).unwrap() == saved
            && memory.slot(Slot::LibraryKey).is_none()
    );
    let requests = fixture.state.lock().unwrap().requests;
    assert!(
        recipient_error(recipient::check(&mut store, &mut remote)).failure
            == Failure::Cloud(cloud::Failure::DatasetReview)
    );
    assert_eq!(fixture.state.lock().unwrap().requests, requests);
}
