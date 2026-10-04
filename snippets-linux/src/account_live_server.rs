//! Certificate-verified loopback account server; public fictional account only.
use crate::{bootstrap, cloud::ServerURL, wire::WireRecord};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

#[derive(Default)]
pub(super) struct State {
    pub requests: usize,
    pub grants: usize,
    pub bootstrap_posts: usize,
    pub revokes: usize,
    pub fetches: usize,
    pub batches: usize,
    pub accepted: usize,
    pub reader: bool,
    pub changed_scope: bool,
    pub defer_fetch: bool,
    pub invalidate_cursor: bool,
    pub reject_once: Option<uuid::Uuid>,
    pub fetched: Vec<Option<String>>,
    pub submitted: Vec<Vec<(WireRecord, Option<String>)>>,
    pub acknowledgements: Vec<(uuid::Uuid, String)>,
    public: Option<Value>,
    ciphertext: Option<Value>,
    records: BTreeMap<uuid::Uuid, (WireRecord, String)>,
    positions: BTreeMap<String, BTreeMap<uuid::Uuid, String>>,
    generation: usize,
    hold_changes: Option<Arc<Hold>>,
    creation: Option<Creation>,
}
#[derive(Default)]
struct Creation {
    requests: Vec<uuid::Uuid>,
    // Server-owned idempotency receipts, distinct from the client's journal.
    spaces: Vec<(uuid::Uuid, Value)>,
    lose_reply: bool,
}
impl State {
    pub fn enable_creation(&mut self) {
        assert!(self.requests == 0 && self.creation.is_none());
        self.creation = Some(Creation::default());
    }
    pub fn lose_next_creation_reply(&mut self) {
        self.creation.as_mut().unwrap().lose_reply = true;
    }
    pub fn creation_counts(&self) -> (usize, usize) {
        let creation = self.creation.as_ref().unwrap();
        (creation.requests.len(), creation.spaces.len())
    }
    pub fn creation_requests(&self) -> Vec<uuid::Uuid> {
        self.creation.as_ref().unwrap().requests.clone()
    }
    pub fn put(&mut self, record: WireRecord) {
        record.validate().unwrap();
        self.generation += 1;
        let version = format!("public-native-record-version-{:016x}", self.generation);
        crate::cloud::RecordVersion::from_checkpoint(version.clone()).unwrap();
        self.records.insert(record.id, (record, version));
    }
    pub fn record(&self, id: uuid::Uuid) -> Option<WireRecord> {
        self.records.get(&id).map(|(record, _)| record.clone())
    }
    pub fn version(&self, id: uuid::Uuid) -> Option<String> {
        self.records.get(&id).map(|(_, version)| version.clone())
    }
    pub fn omit(&mut self, id: uuid::Uuid) {
        assert!(self.records.remove(&id).is_some());
    }
    fn known(&self) -> BTreeMap<uuid::Uuid, String> {
        self.records
            .iter()
            .map(|(id, (_, version))| (*id, version.clone()))
            .collect()
    }
}
#[derive(Default)]
pub(super) struct Hold {
    entered: AtomicBool,
    released: AtomicBool,
}
impl Hold {
    pub fn entered(&self) -> bool {
        self.entered.load(Ordering::Acquire)
    }
    pub fn release(&self) {
        self.released.store(true, Ordering::Release);
    }
}
pub(super) struct Fixture {
    pub server: ServerURL,
    pub state: Arc<Mutex<State>>,
    stop: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}
fn scope() -> Value {
    json!({"serverInstanceId":uuid::Uuid::from_u128(1),"spaceId":uuid::Uuid::from_u128(2),
        "scopeBinding":"public-native-membership-binding","datasetGeneration":uuid::Uuid::from_u128(3),
        "feedEpoch":uuid::Uuid::from_u128(4)})
}
fn observed_scope(state: &State) -> Value {
    let mut value = scope();
    if state.changed_scope {
        value["scopeBinding"] = "public-native-changed-membership".into();
    }
    value
}
fn space(state: &State) -> Value {
    json!({"scope":observed_scope(state),"role":if state.reader {"reader"} else {"owner"},"keyEpoch":1})
}
fn discovery(server: &ServerURL) -> Value {
    let base = server.for_secure_storage();
    json!({"protocolMajor":2,"protocolMinor":1,"serverVersion":"public-native-fixture",
        "serverInstanceId":uuid::Uuid::from_u128(1),"apiBase":format!("{base}/v2"),
        "recordProfile":"snippets-wire-v1",
        "capabilities":["native-email-code-v1","library-action-proof-v1","pairing-v2","offline-recovery-v1","resource-session-revocation"],
        "limits":{"maxBlobBytes":900000,"maxRevisionBytes":256,"maxBatchRecords":50,
            "maxPageRecords":50,"maxRequestBytes":16777216,"maxResponseBytes":67108864,
            "maxKeyEnvelopeBytes":4096,"maxPairingSeconds":600},
        "nativeAuth":{"flow":"email_code","startEndpoint":format!("{base}/v2/auth/email/start"),
            "verifyEndpoint":format!("{base}/v2/auth/email/verify"),
            "refreshEndpoint":format!("{base}/v2/auth/refresh"),"revokeEndpoint":format!("{base}/v2/auth/revoke")}})
}
fn grant(state: &mut State) -> Value {
    state.grants += 1;
    json!({"access_token":format!("public-native-access-{}",state.grants),
        "refresh_token":format!("public-native-refresh-{}",state.grants),"expires_in":300,
        "token_type":"Bearer","account":{"id":"public-native-account","email":"fixture@example.invalid"}})
}
fn recovery(state: &State, scope: &Value) -> Value {
    json!({"scope":scope,"keyEpoch":1,"recovery":state.ciphertext.as_ref().map(|ciphertext|
        json!({"purpose":"recovery","version":1,"keyEpoch":1,"algorithm":bootstrap::RECOVERY_ALGORITHM,
            "ciphertext":ciphertext,"createdAt":"2026-09-30T12:00:00Z"}))})
}
struct Request {
    method: String,
    path: String,
    headers: BTreeMap<String, String>,
    body: Value,
}
fn request(
    stream: &mut rustls::StreamOwned<rustls::ServerConnection, TcpStream>,
) -> std::io::Result<Request> {
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
    let method = first.next().unwrap().into();
    let path = first.next().unwrap().into();
    let headers: BTreeMap<_, _> = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(key, value)| (key.to_ascii_lowercase(), value.trim().to_string()))
        .collect();
    let size = headers
        .get("content-length")
        .map_or(0, |value| value.parse::<usize>().unwrap());
    assert!(size < 64 * 1024);
    let mut body = zeroize::Zeroizing::new(vec![0; size]);
    stream.read_exact(&mut body)?;
    Ok(Request {
        method,
        path,
        headers,
        body: if body.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&body).unwrap()
        },
    })
}
fn respond(request: Request, server: &ServerURL, state: &mut State) -> (u16, Value) {
    state.requests += 1;
    if request.path == "/.well-known/snippets-sync" {
        assert!(request.method == "GET" && !request.headers.contains_key("authorization"));
        return (200, discovery(server));
    }
    if request.path.starts_with("/v2/auth/") {
        assert!(request.method == "POST" && !request.headers.contains_key("authorization"));
        return match request.path.as_str() {
            "/v2/auth/email/start" => {
                assert!(request.body["email"] == "fixture@example.invalid");
                (
                    200,
                    json!({"challengeId":"public-native-challenge","expiresIn":600,"resendAfter":60,"codeLength":6}),
                )
            }
            "/v2/auth/email/verify" => {
                assert!(request.body["challengeId"] == "public-native-challenge");
                if request.body["code"] != "123456" {
                    (
                        400,
                        json!({"type":"urn:snippets:error:invalid_code","status":400,"code":"invalid_code","requestId":uuid::Uuid::from_u128(99)}),
                    )
                } else {
                    (200, grant(state))
                }
            }
            "/v2/auth/refresh" => {
                assert!(
                    request.body["refreshToken"]
                        == format!("public-native-refresh-{}", state.grants)
                );
                (200, grant(state))
            }
            "/v2/auth/revoke" => {
                let token = request.body["token"].as_str().unwrap();
                assert!(
                    token.starts_with("public-native-access-")
                        || token.starts_with("public-native-refresh-")
                );
                state.revokes += 1;
                (204, Value::Null)
            }
            _ => panic!("unexpected native fixture authentication route"),
        };
    }
    assert!(
        request
            .headers
            .get("authorization")
            .is_some_and(|value| *value == format!("Bearer public-native-access-{}", state.grants))
    );
    if request.path == "/v2/spaces" {
        if let Some(creation) = state.creation.as_mut() {
            if request.method == "POST" {
                assert!(request.body.is_null());
                let key = uuid::Uuid::parse_str(&request.headers["idempotency-key"]).unwrap();
                assert!(!key.is_nil() && creation.requests.len() < 8);
                creation.requests.push(key);
                let value =
                    if let Some((_, value)) = creation.spaces.iter().find(|(id, _)| *id == key) {
                        value.clone()
                    } else {
                        let index = creation.spaces.len() as u128;
                        let value = json!({"scope":{"serverInstanceId":uuid::Uuid::from_u128(1),
                        "spaceId":uuid::Uuid::from_u128(200+index),
                        "scopeBinding":format!("public-native-created-membership-{index:04}"),
                        "datasetGeneration":uuid::Uuid::from_u128(300+index),
                        "feedEpoch":uuid::Uuid::from_u128(400+index)},"role":"owner","keyEpoch":1});
                        creation.spaces.push((key, value.clone()));
                        value
                    };
                return (201, value);
            }
            assert!(request.method == "GET");
            return (
                200,
                json!({"spaces":creation.spaces.iter().map(|(_, value)| value).collect::<Vec<_>>()}),
            );
        }
        assert!(request.method == "GET");
        return (200, json!({"spaces":[space(state)]}));
    }
    let mut base = format!("/v2/spaces/{}", uuid::Uuid::from_u128(2));
    let mut response_scope = observed_scope(state);
    if let Some(creation) = state.creation.as_ref() {
        let (index, descriptor) = creation
            .spaces
            .iter()
            .enumerate()
            .find_map(|(index, (_, value))| {
                let prefix = format!("/v2/spaces/{}", value["scope"]["spaceId"].as_str().unwrap());
                (request.path == prefix || request.path.starts_with(&format!("{prefix}/")))
                    .then_some((index, value))
            })
            .expect("A created library route must identify a server receipt");
        base = format!(
            "/v2/spaces/{}",
            descriptor["scope"]["spaceId"].as_str().unwrap()
        );
        response_scope = descriptor["scope"].clone();
        // Only the first created library is initialized in this fixture. Later
        // libraries are independent empty targets; they cannot inherit its key.
        if index > 0 {
            assert!(request.method == "GET");
            return (
                200,
                if request.path == base {
                    descriptor.clone()
                } else if request.path == format!("{base}/key-authority") {
                    json!({"scope":response_scope,"keyEpoch":1,"publicKey":null})
                } else {
                    assert!(request.path == format!("{base}/recovery-envelope"));
                    json!({"scope":response_scope,"keyEpoch":1,"recovery":null})
                },
            );
        }
    }
    if request.path == base {
        assert!(request.method == "GET");
        let mut value = space(state);
        value["scope"] = response_scope.clone();
        (200, value)
    } else if request.path == format!("{base}/key-authority") {
        assert!(request.method == "GET");
        (
            200,
            json!({"scope":response_scope,"keyEpoch":1,"publicKey":state.public}),
        )
    } else if request.path == format!("{base}/recovery-envelope") {
        assert!(request.method == "GET");
        (200, recovery(state, &response_scope))
    } else if request.path == format!("{base}/key-bootstrap") {
        assert!(request.method == "POST" && state.public.is_none());
        assert!(
            request.body["expectedScope"] == response_scope
                && request.body["recovery"]["expectedVersion"].is_null()
        );
        assert!(request.body.get("bundle").is_none() && request.body.get("key").is_none());
        state.bootstrap_posts += 1;
        state.public = Some(request.body["publicKey"].clone());
        state.ciphertext = Some(request.body["recovery"]["ciphertext"].clone());
        (200, recovery(state, &response_scope))
    } else if request.path.starts_with(&format!("{base}/changes?")) {
        assert!(request.method == "GET");
        state.fetches += 1;
        if std::mem::take(&mut state.defer_fetch) {
            return (
                503,
                json!({"type":"urn:snippets:error:dependency_unavailable","status":503,
                    "code":"dependency_unavailable","retryAfterSeconds":1,
                    "requestId":uuid::Uuid::from_u128(99)}),
            );
        }
        let url = url::Url::parse(&format!("https://127.0.0.1{}", request.path)).unwrap();
        let cursor = url
            .query_pairs()
            .find(|(key, _)| key == "cursor")
            .map(|(_, value)| value.into_owned());
        assert!(state.fetched.len() < 64);
        state.fetched.push(cursor.clone());
        if std::mem::take(&mut state.invalidate_cursor) {
            assert!(cursor.is_some());
            return (
                409,
                json!({"type":"urn:snippets:error:cursor_invalid","status":409,
                    "code":"cursor_invalid","requestId":uuid::Uuid::from_u128(99)}),
            );
        }
        let known = cursor.as_ref().map(|cursor| {
            state
                .positions
                .get(cursor)
                .expect("native fixture received an unissued cursor")
        });
        let records: Vec<_> = state
            .records
            .iter()
            .filter(|(id, (_, version))| known.is_none_or(|known| known.get(id) != Some(version)))
            .map(|(_, (record, version))| server_record(record, version))
            .collect();
        assert!(records.len() <= 50);
        let next = format!("public-native-cursor-{}", state.fetches);
        state.positions.insert(next.clone(), state.known());
        (
            200,
            json!({"scope":response_scope,"records":records,"cursor":next,
                "fullSnapshot":cursor.is_none(),"hasMore":false}),
        )
    } else if request.path == format!("{base}/records/batch") {
        assert!(request.method == "POST" && !state.reader);
        assert!(request.body["expectedScope"] == response_scope);
        let items = request.body["items"].as_array().unwrap();
        assert!(!items.is_empty() && items.len() <= 50);
        // Retain only encrypted offers and their positional CAS for explicit
        // native acceptance. No bodies, keys or credentials reach this peer.
        assert!(state.submitted.len() < 32);
        state.submitted.push(
            items
                .iter()
                .map(|item| {
                    let record: WireRecord =
                        serde_json::from_value(item["record"].clone()).unwrap();
                    record.validate().unwrap();
                    (
                        record,
                        item["expectedRecordVersion"].as_str().map(String::from),
                    )
                })
                .collect(),
        );
        state.batches += 1;
        let mut partial = false;
        let outcomes: Vec<_> = items
            .iter()
            .map(|item| {
                let record: WireRecord = serde_json::from_value(item["record"].clone()).unwrap();
                record.validate().unwrap();
                if state.reject_once == Some(record.id) {
                    state.reject_once = None;
                    partial = true;
                    return json!({"kind":"rejected","errorCode":"rate_limited","retryAfterSeconds":1});
                }
                let expected = item["expectedRecordVersion"].as_str();
                let actual = state.records.get(&record.id).map(|(_, v)| v.as_str());
                if expected != actual {
                    partial = true;
                    let (record, version) = state.records.get(&record.id).unwrap();
                    json!({"kind":"conflict","authoritativeRecord":server_record(record, version)})
                } else {
                    state.accepted += 1;
                    let id = record.id;
                    state.put(record);
                    let (record, version) = state.records.get(&id).unwrap();
                    assert!(state.acknowledgements.len() < 32 * 50);
                    state.acknowledgements.push((id, version.clone()));
                    json!({"kind":"accepted","recordVersion":version,"revision":record.rev})
                }
            })
            .collect();
        (
            200,
            json!({"scope":response_scope,"outcomes":outcomes,"partial":partial}),
        )
    } else {
        panic!("unexpected native fixture library route")
    }
}
fn server_record(record: &WireRecord, version: &str) -> Value {
    let mut value = serde_json::to_value(record).unwrap();
    value["recordVersion"] = version.into();
    value
}
impl Fixture {
    pub fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let server =
            ServerURL::parse(&format!("https://{}", listener.local_addr().unwrap())).unwrap();
        let state = Arc::new(Mutex::new(State::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_state = state.clone();
        let thread_stop = stop.clone();
        let thread_server = server.clone();
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![rustls::pki_types::CertificateDer::from(
                include_bytes!("../tests/fixtures/loopback-server.der").to_vec(),
            )],
            rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
                include_bytes!("../tests/fixtures/loopback-public-test-key.der").to_vec(),
            )),
        )
        .unwrap();
        let config = Arc::new(config);
        let worker = thread::spawn(move || {
            while !thread_stop.load(Ordering::Acquire) {
                let tcp = match listener.accept() {
                    Ok((tcp, _)) => tcp,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    }
                    Err(_) => panic!("native TLS accept failed"),
                };
                tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
                tcp.set_write_timeout(Some(Duration::from_secs(3))).unwrap();
                let mut stream = rustls::StreamOwned::new(
                    rustls::ServerConnection::new(config.clone()).unwrap(),
                    tcp,
                );
                let Ok(request) = request(&mut stream) else {
                    continue;
                };
                let (status, response, hold, lose_reply) = {
                    let mut state = thread_state.lock().unwrap();
                    let lose_reply = request.path == "/v2/spaces"
                        && request.method == "POST"
                        && state
                            .creation
                            .as_mut()
                            .is_some_and(|creation| std::mem::take(&mut creation.lose_reply));
                    let hold = request
                        .path
                        .contains("/changes?")
                        .then(|| state.hold_changes.take())
                        .flatten();
                    let (status, response) = respond(request, &thread_server, &mut state);
                    (status, response, hold, lose_reply)
                };
                // The server committed its receipt, but the client receives no
                // HTTP status or body on this deliberately closed TLS transport.
                if lose_reply {
                    continue;
                }
                if let Some(hold) = hold {
                    hold.entered.store(true, Ordering::Release);
                    let started = std::time::Instant::now();
                    while !hold.released.load(Ordering::Acquire)
                        && !thread_stop.load(Ordering::Acquire)
                        && started.elapsed() < Duration::from_secs(10)
                    {
                        thread::sleep(Duration::from_millis(2));
                    }
                }
                let body = if status == 204 {
                    vec![]
                } else {
                    serde_json::to_vec(&response).unwrap()
                };
                let media = if status >= 400 {
                    "application/problem+json"
                } else {
                    "application/json"
                };
                write!(stream,"HTTP/1.1 {status} Fixture\r\nConnection: close\r\nContent-Type: {media}\r\nContent-Length: {}\r\n\r\n",body.len()).unwrap();
                stream.write_all(&body).unwrap();
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
    pub fn agent(&self) -> ureq::Agent {
        ureq::Agent::config_builder()
            .https_only(true)
            .max_redirects(0)
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(5)))
            .tls_config(
                ureq::tls::TlsConfig::builder()
                    .root_certs(ureq::tls::RootCerts::new_with_certs(&[
                        ureq::tls::Certificate::from_der(include_bytes!(
                            "../tests/fixtures/loopback-ca.der"
                        )),
                    ]))
                    .build(),
            )
            .build()
            .into()
    }
    pub fn hold_next_changes(&self) -> Arc<Hold> {
        let hold = Arc::new(Hold::default());
        let mut state = self.state.lock().unwrap();
        assert!(state.hold_changes.replace(hold.clone()).is_none());
        hold
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let result = worker.join();
            if !thread::panicking() {
                assert!(result.is_ok());
            }
        }
    }
}
