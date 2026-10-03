//! Snippets Cloud v2 transport. This module never sees snippets or library keys.
//! Run blocking HTTP on an owner worker. Callers must journal credentials/offers
//! before adopting them; no network, session or checkpoint is created by default.
use crate::{
    canonical,
    wire::{self, WireRecord},
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{fmt, io::Read, time::Duration};
use ureq::{
    Agent,
    http::{HeaderValue, Method, Request},
};
use url::Url;
use uuid::Uuid;
use zeroize::Zeroizing;

const MAX_MESSAGE: usize = 16 * 1024 * 1024;
const MAX_AUTH: usize = 32 * 1024;
const MAX_CONTROL: usize = 256 * 1024;
pub const RECORDS_PER_MESSAGE: usize = 10;
type Result<T> = std::result::Result<T, Failure>;
fn non_null<'de, D: serde::Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> std::result::Result<Option<T>, D::Error> {
    T::deserialize(deserializer).map(Some)
}

/// All failures are closed vocabulary. HTTP/library errors and request identifiers
/// are deliberately discarded instead of being reflected into a UI or log.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    InvalidServer,
    IncompatibleServer,
    InvalidCredential,
    InvalidResponse,
    MessageTooLarge,
    Network,
    AccountReview,
    DatasetReview,
    ReadOnly,
    CredentialCommit,
    Server {
        code: ErrorCode,
        retry_after: Option<u32>,
    },
}
impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidServer => "Enter a valid HTTPS server address.",
            Self::IncompatibleServer => {
                "The server does not support this synchronization protocol."
            }
            Self::InvalidCredential => "Sign in again to synchronize this library.",
            Self::InvalidResponse => "The server returned an invalid response.",
            Self::MessageTooLarge => "The synchronization message exceeds its size limit.",
            Self::Network => "The synchronization server could not be reached.",
            Self::AccountReview => "The synchronization account changed. Review is required.",
            Self::DatasetReview => "The remote library was reset or restored. Review is required.",
            Self::ReadOnly => "This account can read this library but cannot change it.",
            Self::CredentialCommit => "The issued session could not be saved.",
            Self::Server { .. } => "The synchronization server declined the request.",
        })
    }
}
impl std::error::Error for Failure {}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidEmail,
    InvalidCode,
    CodeExpired,
    TooManyAttempts,
    InvalidRequest,
    AuthenticationRequired,
    ReauthenticationRequired,
    Forbidden,
    NotFound,
    Conflict,
    CursorInvalid,
    DatasetReset,
    IncompatibleVersion,
    PayloadTooLarge,
    QuotaExceeded,
    RateLimited,
    PairingExpired,
    DependencyUnavailable,
    InternalError,
}
impl ErrorCode {
    fn name(self) -> &'static str {
        match self {
            Self::InvalidEmail => "invalid_email",
            Self::InvalidCode => "invalid_code",
            Self::CodeExpired => "code_expired",
            Self::TooManyAttempts => "too_many_attempts",
            Self::InvalidRequest => "invalid_request",
            Self::AuthenticationRequired => "authentication_required",
            Self::ReauthenticationRequired => "reauthentication_required",
            Self::Forbidden => "forbidden",
            Self::NotFound => "not_found",
            Self::Conflict => "conflict",
            Self::CursorInvalid => "cursor_invalid",
            Self::DatasetReset => "dataset_reset",
            Self::IncompatibleVersion => "incompatible_version",
            Self::PayloadTooLarge => "payload_too_large",
            Self::QuotaExceeded => "quota_exceeded",
            Self::RateLimited => "rate_limited",
            Self::PairingExpired => "pairing_expired",
            Self::DependencyUnavailable => "dependency_unavailable",
            Self::InternalError => "internal_error",
        }
    }
}
fn bounded(text: &str, min: usize, max: usize) -> bool {
    (min..=max).contains(&text.len()) && !text.chars().any(char::is_control)
}
pub(crate) fn email_valid(email: &str) -> bool {
    bounded(email, 3, 254) && email.contains('@') && !email.chars().any(char::is_whitespace)
}

/// No Debug, Display or Serialize: tokens only leave via authenticated headers,
/// native auth bodies, or the caller's encrypted credential store.
pub struct Credential(Zeroizing<String>);
impl Credential {
    pub fn new(text: String) -> Result<Self> {
        let text = Zeroizing::new(text);
        if !(1..=512).contains(&text.len())
            || !text.is_ascii()
            || text
                .bytes()
                .any(|b| b.is_ascii_whitespace() || b.is_ascii_control())
        {
            return Err(Failure::InvalidCredential);
        }
        Ok(Self(text))
    }
    pub fn for_secure_storage(&self) -> &[u8] {
        self.0.as_bytes()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Cursor(String);
impl Cursor {
    pub(crate) fn from_checkpoint(text: String) -> Result<Self> {
        let cursor = Self(text);
        cursor.validate()?;
        Ok(cursor)
    }
    pub(crate) fn for_checkpoint(&self) -> &str {
        &self.0
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if bounded(&self.0, 1, 4096) {
            Ok(())
        } else {
            Err(Failure::InvalidResponse)
        }
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RecordVersion(String);
impl RecordVersion {
    pub(crate) fn from_checkpoint(text: String) -> Result<Self> {
        let version = Self(text);
        version.validate()?;
        Ok(version)
    }
    pub(crate) fn for_checkpoint(&self) -> &str {
        &self.0
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if bounded(&self.0, 32, 2048) {
            Ok(())
        } else {
            Err(Failure::InvalidResponse)
        }
    }
}
/// Persistable opaque scope identity, never for diagnostics.
#[derive(Clone, PartialEq, Eq)]
pub struct Binding([u8; 32]);
impl Binding {
    pub fn bytes_for_checkpoint(&self) -> &[u8; 32] {
        &self.0
    }
    pub fn from_checkpoint(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ServerURL {
    canonical: String,
}
impl ServerURL {
    pub fn parse(text: &str) -> Result<Self> {
        let authority = text
            .split_once("://")
            .and_then(|(_, tail)| tail.split(['/', '?', '#']).next())
            .ok_or(Failure::InvalidServer)?;
        if text.len() > 2048
            || authority.is_empty()
            || authority.contains('@')
            || text.contains('\\')
            || text.chars().any(|c| c.is_control() || c.is_whitespace())
        {
            return Err(Failure::InvalidServer);
        }
        let url = Url::parse(text).map_err(|_| Failure::InvalidServer)?;
        if url.scheme() != "https"
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(Failure::InvalidServer);
        }
        Ok(Self {
            canonical: url.as_str().trim_end_matches('/').into(),
        })
    }
    fn endpoint(&self, path: &str) -> Result<Url> {
        Url::parse(&format!("{}{path}", self.canonical)).map_err(|_| Failure::InvalidServer)
    }
    pub(crate) fn for_secure_storage(&self) -> &str {
        &self.canonical
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Scope {
    server_instance_id: Uuid,
    space_id: Uuid,
    scope_binding: String,
    dataset_generation: Uuid,
    feed_epoch: Uuid,
}
impl Scope {
    fn validate(&self, instance: Uuid) -> Result<()> {
        if self.server_instance_id != instance {
            return Err(Failure::AccountReview);
        }
        if self.space_id.is_nil()
            || self.dataset_generation.is_nil()
            || self.feed_epoch.is_nil()
            || !bounded(&self.scope_binding, 32, 256)
        {
            return Err(Failure::InvalidResponse);
        }
        Ok(())
    }
    pub fn identities(&self, server: &ServerURL) -> (Binding, Binding) {
        let instance = self.server_instance_id.to_string();
        let space = self.space_id.to_string();
        let dataset = self.dataset_generation.to_string();
        let fields = [
            server.canonical.as_str(),
            "2",
            &instance,
            &space,
            &self.scope_binding,
        ];
        let digest = |domain: &str, include_dataset: bool| {
            let mut hash = Sha256::new();
            for field in std::iter::once(domain)
                .chain(fields)
                .chain(include_dataset.then_some(dataset.as_str()))
            {
                hash.update((field.len() as u32).to_be_bytes());
                hash.update(field.as_bytes());
            }
            Binding(hash.finalize().into())
        };
        (
            digest("snippets-cloud-membership-v2", false),
            digest("snippets-cloud-dataset-v2", true),
        )
    }
}
#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Owner,
    Writer,
    Reader,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Space {
    pub scope: Scope,
    pub role: Role,
    key_epoch: u64,
}
impl Space {
    pub(crate) fn key_binding(
        &self,
        deployment: &crate::auth_store::Deployment,
    ) -> Result<crate::key_store::KeyBinding> {
        self.validate(deployment.instance())?;
        crate::key_store::KeyBinding::new(
            deployment.server().clone(),
            deployment.instance(),
            self.id(),
            self.scope.identities(deployment.server()),
            self.key_epoch(),
        )
        .map_err(|_| Failure::InvalidResponse)
    }
    pub fn id(&self) -> Uuid {
        self.scope.space_id
    }
    pub fn key_epoch(&self) -> u64 {
        self.key_epoch
    }
    fn validate(&self, instance: Uuid) -> Result<()> {
        self.scope.validate(instance)?;
        if self.key_epoch == 0 || self.key_epoch > i64::MAX as u64 {
            return Err(Failure::InvalidResponse);
        }
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Limits {
    max_blob_bytes: usize,
    max_revision_bytes: usize,
    max_batch_records: usize,
    max_page_records: usize,
    max_request_bytes: usize,
    max_response_bytes: usize,
    max_key_envelope_bytes: usize,
    max_pairing_seconds: usize,
}
impl Limits {
    fn supported(&self) -> bool {
        self.max_blob_bytes == 900_000
            && self.max_revision_bytes == 256
            && self.max_batch_records == 50
            && self.max_page_records == 50
            && self.max_request_bytes == MAX_MESSAGE
            && self.max_response_bytes == 64 * 1024 * 1024
            && self.max_key_envelope_bytes == 4096
            && self.max_pairing_seconds == 600
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NativeAuth {
    flow: String,
    start_endpoint: String,
    verify_endpoint: String,
    refresh_endpoint: String,
    revoke_endpoint: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Oidc {
    issuer: String,
    resource: String,
    client_id: String,
    scopes: Vec<String>,
    authorization_flow: String,
    max_access_token_age_seconds: u32,
}
impl Oidc {
    fn validate(&self) -> bool {
        [&self.issuer, &self.resource]
            .into_iter()
            .all(|s| s.len() <= 2048 && Url::parse(s).is_ok())
            && bounded(&self.client_id, 1, 256)
            && (1..=16).contains(&self.scopes.len())
            && self.scopes.iter().all(|s| bounded(s, 1, 64))
            && self.authorization_flow == "authorization_code_pkce"
            && (60..=86400).contains(&self.max_access_token_age_seconds)
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Discovery {
    protocol_major: u32,
    protocol_minor: u32,
    server_version: String,
    server_instance_id: Uuid,
    api_base: String,
    limits: Limits,
    record_profile: String,
    capabilities: Vec<String>,
    native_auth: NativeAuth,
    #[serde(default, deserialize_with = "non_null")]
    oidc: Option<Oidc>,
}
impl Discovery {
    fn validate(&self, server: &ServerURL) -> Result<()> {
        if self.protocol_major != 2
            || self.protocol_minor != 1
            || self.record_profile != "snippets-wire-v1"
            || !self.limits.supported()
        {
            return Err(Failure::IncompatibleServer);
        }
        if self.server_instance_id.is_nil()
            || !bounded(&self.server_version, 1, 64)
            || self.api_base != format!("{}/v2", server.canonical)
            || self.capabilities.len() > 16
            || !self.capabilities.iter().all(|s| bounded(s, 1, 64))
            || self.oidc.as_ref().is_some_and(|o| !o.validate())
        {
            return Err(Failure::InvalidResponse);
        }
        if [
            "native-email-code-v1",
            "library-action-proof-v1",
            "pairing-v2",
            "offline-recovery-v1",
            "resource-session-revocation",
        ]
        .iter()
        .any(|name| !self.capabilities.iter().any(|c| c == name))
            || self.native_auth.flow != "email_code"
        {
            return Err(Failure::IncompatibleServer);
        }
        for (actual, path) in [
            (&self.native_auth.start_endpoint, "/v2/auth/email/start"),
            (&self.native_auth.verify_endpoint, "/v2/auth/email/verify"),
            (&self.native_auth.refresh_endpoint, "/v2/auth/refresh"),
            (&self.native_auth.revoke_endpoint, "/v2/auth/revoke"),
        ] {
            if *actual != format!("{}{path}", server.canonical) {
                return Err(Failure::InvalidResponse);
            }
        }
        Ok(())
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Problem {
    #[serde(rename = "type")]
    kind: String,
    status: u16,
    code: ErrorCode,
    request_id: Uuid,
    #[serde(default, deserialize_with = "non_null")]
    retry_after_seconds: Option<u32>,
    #[serde(default, deserialize_with = "non_null")]
    limit: Option<u64>,
}
impl Problem {
    fn failure(self, status: u16) -> Result<Failure> {
        if self.status != status
            || !(400..600).contains(&status)
            || self.kind != format!("urn:snippets:error:{}", self.code.name())
            || self
                .retry_after_seconds
                .is_some_and(|s| !(1..=86400).contains(&s))
        {
            return Err(Failure::InvalidResponse);
        }
        // IDs and quotas are validated by their typed decode, then discarded.
        let _ = (self.request_id, self.limit);
        Ok(if self.code == ErrorCode::DatasetReset {
            Failure::DatasetReview
        } else {
            Failure::Server {
                code: self.code,
                retry_after: self.retry_after_seconds,
            }
        })
    }
}

// Only compiled for explicit native acceptance. This scoped, thread-local CA
// applies to one exact fixture server; discovery and every deployment admission
// still run normally, including authentication-journal cleanup rediscovery.
#[cfg(all(test, feature = "desktop"))]
thread_local! {
    static LIVE_FIXTURE_AGENT: std::cell::RefCell<Option<(ServerURL, Agent)>> =
        const { std::cell::RefCell::new(None) };
}
#[cfg(all(test, feature = "desktop"))]
pub(crate) fn with_live_fixture_agent<T>(
    server: &ServerURL,
    agent: &Agent,
    action: impl FnOnce() -> T,
) -> T {
    struct Restore(Option<(ServerURL, Agent)>);
    impl Drop for Restore {
        fn drop(&mut self) {
            LIVE_FIXTURE_AGENT.with(|fixture| *fixture.borrow_mut() = self.0.take());
        }
    }
    let _restore = Restore(LIVE_FIXTURE_AGENT.with(|fixture| {
        fixture
            .borrow_mut()
            .replace((server.clone(), agent.clone()))
    }));
    action()
}

fn agent(https_only: bool) -> Agent {
    Agent::config_builder()
        .https_only(https_only)
        .max_redirects(0)
        .http_status_as_error(false)
        .max_response_header_size(16 * 1024)
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into()
}
#[derive(Clone)]
pub struct CloudClient {
    server: ServerURL,
    agent: Agent,
    instance: Uuid,
}
struct Reply {
    status: u16,
    limit: usize,
    idempotency: Option<Uuid>,
}
impl Reply {
    fn new(status: u16, limit: usize) -> Self {
        Self {
            status,
            limit,
            idempotency: None,
        }
    }
}
impl CloudClient {
    pub fn key_binding_for_observation(
        &self,
        space: &Space,
    ) -> Result<crate::key_store::KeyBinding> {
        space.key_binding(&self.credential_deployment())
    }
    #[cfg(test)]
    pub(crate) fn test_with_agent(server: ServerURL, agent: Agent, instance: Uuid) -> Self {
        assert!(!instance.is_nil());
        Self {
            server,
            agent,
            instance,
        }
    }
    pub fn credential_deployment(&self) -> crate::auth_store::Deployment {
        crate::auth_store::Deployment::from_discovery(self.server.clone(), self.instance)
    }
    /// Discovery pins a deployment. No account, key or local library is read here.
    pub fn discover(server: ServerURL) -> Result<Self> {
        let mut client = Self {
            server,
            agent: agent(true),
            instance: Uuid::nil(),
        };
        #[cfg(all(test, feature = "desktop"))]
        LIVE_FIXTURE_AGENT.with(|fixture| {
            if let Some((server, agent)) = fixture.borrow().as_ref()
                && *server == client.server
            {
                client.agent = agent.clone();
            }
        });
        client.load_discovery()?;
        Ok(client)
    }
    /// Revalidate a possibly long-lived client before transmitting credentials.
    /// Discovery carries no account credentials and cannot change this pin.
    pub fn preflight_credentials(&self) -> Result<()> {
        let discovery: Discovery = self.json(
            Method::GET,
            "/.well-known/snippets-sync",
            None,
            None,
            200,
            MAX_AUTH,
        )?;
        discovery.validate(&self.server)?;
        if discovery.server_instance_id != self.instance {
            return Err(Failure::AccountReview);
        }
        Ok(())
    }
    fn load_discovery(&mut self) -> Result<()> {
        let discovery: Discovery = self.json(
            Method::GET,
            "/.well-known/snippets-sync",
            None,
            None,
            200,
            MAX_AUTH,
        )?;
        discovery.validate(&self.server)?;
        self.instance = discovery.server_instance_id;
        Ok(())
    }
    fn exchange(
        &self,
        method: Method,
        url: Url,
        token: Option<&Credential>,
        body: Option<&[u8]>,
        reply: Reply,
    ) -> Result<Zeroizing<Vec<u8>>> {
        let Reply {
            status: expected,
            limit,
            idempotency,
        } = reply;
        if body.is_some_and(|b| b.len() > MAX_MESSAGE) {
            return Err(Failure::MessageTooLarge);
        }
        let mut builder = Request::builder()
            .method(method)
            .uri(url.as_str())
            .header("Accept", "application/json, application/problem+json")
            .header("Accept-Encoding", "identity");
        if let Some(token) = token {
            let authorization = Zeroizing::new(format!("Bearer {}", token.0.as_str()));
            let mut header = HeaderValue::from_bytes(authorization.as_bytes())
                .map_err(|_| Failure::InvalidCredential)?;
            header.set_sensitive(true);
            builder = builder.header("Authorization", header);
        }
        if let Some(id) = idempotency {
            builder = builder.header("Idempotency-Key", id.to_string());
        }
        if body.is_some() {
            builder = builder.header("Content-Type", "application/json");
        }
        let request = builder
            .body(body.unwrap_or_default())
            .map_err(|_| Failure::InvalidResponse)?;
        let mut response = self.agent.run(request).map_err(|_| Failure::Network)?;
        let status = response.status().as_u16();
        if (300..400).contains(&status) {
            return Err(Failure::InvalidResponse);
        }
        if response
            .headers()
            .get_all("Content-Encoding")
            .iter()
            .any(|v| v.to_str().ok() != Some("identity"))
        {
            return Err(Failure::InvalidResponse);
        }
        // HTTP clients may suppress a body for 204 before our reader sees it.
        // Reject framing that announces content rather than accepting that as ACK.
        if status == 204
            && expected == 204
            && (response.headers().contains_key("Transfer-Encoding")
                || response.headers().get("Content-Length").is_some_and(|v| {
                    v.to_str().ok().and_then(|s| s.parse::<u64>().ok()) != Some(0)
                }))
        {
            return Err(Failure::InvalidResponse);
        }
        if response.headers().get("Content-Length").is_some_and(|v| {
            v.to_str()
                .ok()
                .and_then(|s| s.parse::<u64>().ok())
                .is_none_or(|n| n > limit as u64)
        }) {
            return Err(Failure::MessageTooLarge);
        }
        // Allocate once so secret auth responses cannot be left in old Vec buffers.
        let mut bytes = Zeroizing::new(Vec::with_capacity(limit));
        let mut reader = response.body_mut().as_reader().take(limit as u64 + 1);
        let mut chunk = Zeroizing::new([0u8; 8192]);
        loop {
            let read = reader.read(chunk.as_mut()).map_err(|_| Failure::Network)?;
            if read == 0 {
                break;
            }
            if read > limit.saturating_sub(bytes.len()) {
                return Err(Failure::MessageTooLarge);
            }
            bytes.extend_from_slice(&chunk[..read]);
        }
        if status == 204 && expected == 204 {
            return if bytes.is_empty() {
                Ok(bytes)
            } else {
                Err(Failure::InvalidResponse)
            };
        }
        if response.headers().get_all("Content-Type").iter().count() != 1 {
            return Err(Failure::InvalidResponse);
        }
        let media = response
            .headers()
            .get("Content-Type")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.split(';').next())
            .map(str::trim);
        if (400..600).contains(&status) {
            if media != Some("application/problem+json") {
                return Err(Failure::InvalidResponse);
            }
            let problem: Problem = decode(&bytes)?;
            return Err(problem.failure(status)?);
        }
        if status != expected || media != Some("application/json") {
            return Err(Failure::InvalidResponse);
        }
        Ok(bytes)
    }
    fn json<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        token: Option<&Credential>,
        body: Option<&[u8]>,
        status: u16,
        limit: usize,
    ) -> Result<T> {
        let bytes = self.exchange(
            method,
            self.server.endpoint(path)?,
            token,
            body,
            Reply::new(status, limit),
        )?;
        decode(&bytes)
    }
    pub fn list_spaces(&self, token: &Credential) -> Result<Vec<Space>> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Spaces {
            spaces: Vec<Space>,
        }
        let response: Spaces = self.json(
            Method::GET,
            "/v2/spaces",
            Some(token),
            None,
            200,
            MAX_CONTROL,
        )?;
        if response.spaces.len() > 100 {
            return Err(Failure::InvalidResponse);
        }
        let mut ids = std::collections::HashSet::new();
        for space in &response.spaces {
            space.validate(self.instance)?;
            if !ids.insert(space.id()) {
                return Err(Failure::InvalidResponse);
            }
        }
        Ok(response.spaces)
    }
    pub fn create_space(&self, token: &Credential, idempotency: Uuid) -> Result<Space> {
        if idempotency.is_nil() {
            return Err(Failure::InvalidResponse);
        }
        let bytes = self.exchange(
            Method::POST,
            self.server.endpoint("/v2/spaces")?,
            Some(token),
            None,
            Reply {
                status: 201,
                limit: MAX_AUTH,
                idempotency: Some(idempotency),
            },
        )?;
        let space: Space = decode(&bytes)?;
        space.validate(self.instance)?;
        Ok(space)
    }
    pub fn observe_space(&self, token: &Credential, id: Uuid) -> Result<Space> {
        let space: Space = self.json(
            Method::GET,
            &format!("/v2/spaces/{id}"),
            Some(token),
            None,
            200,
            MAX_AUTH,
        )?;
        space.validate(self.instance)?;
        if space.id() != id {
            return Err(Failure::AccountReview);
        }
        Ok(space)
    }
    /// An engine must compare durable identities before this admission. Neither an
    /// automatic preflight nor a later response silently adopts another dataset.
    pub fn admit(
        self,
        token: Credential,
        observation: Space,
        membership: &Binding,
        dataset: &Binding,
    ) -> Result<BoundTransport> {
        observation.validate(self.instance)?;
        let (actual_membership, actual_dataset) = observation.scope.identities(&self.server);
        if actual_membership != *membership {
            return Err(Failure::AccountReview);
        }
        if actual_dataset != *dataset {
            return Err(Failure::DatasetReview);
        }
        Ok(BoundTransport {
            client: self,
            token,
            scope: observation.scope,
            role: observation.role,
            key_epoch: observation.key_epoch,
            halt: None,
        })
    }
    pub fn start_email(&self, email: &str) -> Result<EmailChallenge> {
        if !email_valid(email) {
            return Err(Failure::Server {
                code: ErrorCode::InvalidEmail,
                retry_after: None,
            });
        }
        let body = encode(&serde_json::json!({"email":email}))?;
        let mut challenge: EmailChallenge = self.json(
            Method::POST,
            "/v2/auth/email/start",
            None,
            Some(&body),
            200,
            MAX_AUTH,
        )?;
        challenge.validate()?;
        challenge.deployment = Some(self.credential_deployment());
        Ok(challenge)
    }
    /// Returned credentials are not yet a usable session: journal the issued
    /// generation before validating account/lifetime fields with accept().
    pub fn verify_email(&self, challenge: &EmailChallenge, code: &str) -> Result<IssuedGrant> {
        challenge.validate()?;
        if challenge.deployment.as_ref() != Some(&self.credential_deployment()) {
            return Err(Failure::AccountReview);
        }
        if code.len() != 6 || !code.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Failure::Server {
                code: ErrorCode::InvalidCode,
                retry_after: None,
            });
        }
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Body<'a> {
            challenge_id: &'a str,
            code: &'a str,
        }
        let body = encode(&Body {
            challenge_id: &challenge.challenge_id,
            code,
        })?;
        let bytes = self.exchange(
            Method::POST,
            self.server.endpoint("/v2/auth/email/verify")?,
            None,
            Some(&body),
            Reply::new(200, MAX_AUTH),
        )?;
        IssuedGrant::parse(&bytes)
    }
    pub fn refresh(&self, refresh: &Credential) -> Result<IssuedGrant> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Body<'a> {
            refresh_token: &'a str,
        }
        let body = encode(&Body {
            refresh_token: &refresh.0,
        })?;
        let bytes = self.exchange(
            Method::POST,
            self.server.endpoint("/v2/auth/refresh")?,
            None,
            Some(&body),
            Reply::new(200, MAX_AUTH),
        )?;
        IssuedGrant::parse(&bytes)
    }
    pub fn revoke(&self, token: &Credential, refresh: bool) -> Result<()> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Body<'a> {
            token: &'a str,
            token_type_hint: &'a str,
        }
        let body = encode(&Body {
            token: &token.0,
            token_type_hint: if refresh {
                "refresh_token"
            } else {
                "access_token"
            },
        })?;
        self.exchange(
            Method::POST,
            self.server.endpoint("/v2/auth/revoke")?,
            None,
            Some(&body),
            Reply::new(204, MAX_AUTH),
        )?;
        Ok(())
    }
    pub fn revoke_session(&self, access: &Credential) -> Result<()> {
        self.exchange(
            Method::DELETE,
            self.server.endpoint("/v2/session")?,
            Some(access),
            None,
            Reply::new(204, MAX_AUTH),
        )?;
        Ok(())
    }
}
fn encode<T: Serialize>(value: &T) -> Result<Zeroizing<Vec<u8>>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_MESSAGE));
    struct BoundedWriter<'a>(&'a mut Vec<u8>);
    impl std::io::Write for BoundedWriter<'_> {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > MAX_MESSAGE.saturating_sub(self.0.len()) {
                return Err(std::io::ErrorKind::FileTooLarge.into());
            }
            self.0.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    serde_json::to_writer(BoundedWriter(&mut bytes), value).map_err(|e| {
        if e.io_error_kind() == Some(std::io::ErrorKind::FileTooLarge) {
            Failure::MessageTooLarge
        } else {
            Failure::InvalidResponse
        }
    })?;
    Ok(bytes)
}
fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T> {
    // Typed structs reject duplicates/unknown members. Nested decoding is bounded
    // by serde_json's recursion limit, in addition to the HTTP byte ceiling.
    serde_json::from_slice(bytes).map_err(|_| Failure::InvalidResponse)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EmailChallenge {
    #[serde(skip)]
    deployment: Option<crate::auth_store::Deployment>,
    challenge_id: String,
    pub expires_in: u32,
    pub resend_after: u32,
    pub code_length: u8,
}
impl EmailChallenge {
    fn validate(&self) -> Result<()> {
        if !bounded(&self.challenge_id, 1, 256)
            || self.expires_in != 600
            || self.resend_after != 60
            || self.code_length != 6
        {
            return Err(Failure::InvalidResponse);
        }
        Ok(())
    }
}
pub struct IssuedCredentials {
    pub access: Credential,
    pub refresh: Credential,
}
pub struct IssuedGrant {
    pub credentials: IssuedCredentials,
    metadata: canonical::Value,
}
pub struct InvalidGrant {
    pub failure: Failure,
    pub credentials: IssuedCredentials,
}
pub struct NativeSession {
    pub credentials: IssuedCredentials,
    account_id: String,
    email: String,
    expires_in: Duration,
}
impl NativeSession {
    pub fn account_for_secure_storage(&self) -> &str {
        &self.account_id
    }
    pub fn email_for_sign_in_ui(&self) -> &str {
        &self.email
    }
    pub fn expires_in(&self) -> Duration {
        self.expires_in
    }
}
impl IssuedGrant {
    #[cfg(test)]
    pub(crate) fn fixture(bytes: &[u8]) -> Result<Self> {
        Self::parse(bytes)
    }
    fn parse(bytes: &[u8]) -> Result<Self> {
        let metadata = canonical::parse(bytes).map_err(|_| Failure::InvalidResponse)?;
        let object = metadata.as_object().map_err(|_| Failure::InvalidResponse)?;
        let token = |name: &str| {
            Credential::new(
                object
                    .get(name)
                    .ok_or(Failure::InvalidResponse)?
                    .as_text()
                    .map_err(|_| Failure::InvalidResponse)?
                    .into(),
            )
        };
        let credentials = IssuedCredentials {
            access: token("access_token")?,
            refresh: token("refresh_token")?,
        };
        Ok(Self {
            credentials,
            metadata,
        })
    }
    /// On every error the issued credentials are returned for durable revocation.
    /// A refresh family must not be revoked after a newer rotation is committed.
    pub fn accept(
        self,
        journal: impl FnOnce(&IssuedCredentials) -> Result<()>,
        expected_account: Option<&str>,
        previous_refresh: Option<&Credential>,
    ) -> std::result::Result<NativeSession, InvalidGrant> {
        let result = journal(&self.credentials)
            .map_err(|_| Failure::CredentialCommit)
            .and_then(|()| self.validate(expected_account, previous_refresh));
        match result {
            Ok((account_id, email, expires_in)) => Ok(NativeSession {
                credentials: self.credentials,
                account_id,
                email,
                expires_in: Duration::from_secs(expires_in),
            }),
            Err(failure) => Err(InvalidGrant {
                failure,
                credentials: self.credentials,
            }),
        }
    }
    fn validate(
        &self,
        expected_account: Option<&str>,
        previous_refresh: Option<&Credential>,
    ) -> Result<(String, String, u64)> {
        let check = || -> crate::model::Result<(String, String, u64)> {
            let object = self.metadata.as_object()?;
            let invalid = crate::model::Error("Invalid native session.");
            let keys = [
                "access_token",
                "refresh_token",
                "expires_in",
                "token_type",
                "account",
            ];
            if object.len() != keys.len() || !keys.iter().all(|k| object.contains_key(*k)) {
                return Err(invalid);
            }
            if object["token_type"].as_text()? != "Bearer" {
                return Err(invalid);
            }
            let expires = object["expires_in"].as_int()?;
            if !(1..=300).contains(&expires) {
                return Err(invalid);
            }
            let account = object["account"].as_object()?;
            if account.len() != 2 || !account.contains_key("id") || !account.contains_key("email") {
                return Err(invalid);
            }
            let id = account["id"].as_text()?;
            let email = account["email"].as_text()?;
            if !bounded(id, 1, 256)
                || !email_valid(email)
                || expected_account.is_some_and(|e| e != id)
                || previous_refresh
                    .is_some_and(|p| p.0.as_str() == self.credentials.refresh.0.as_str())
            {
                return Err(invalid);
            }
            Ok((id.into(), email.into(), expires as u64))
        };
        check().map_err(|_| Failure::InvalidResponse)
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServerRecord {
    id: Uuid,
    rev: String,
    deleted: bool,
    #[serde(with = "wire::blob_base64")]
    blob: Vec<u8>,
    record_version: RecordVersion,
}
impl ServerRecord {
    fn validate(&self) -> Result<()> {
        self.record_version.validate()?;
        if !bounded(&self.rev, 1, 256)
            || self.blob.is_empty()
            || self.blob.len() > wire::MAX_BLOB_BYTES
        {
            return Err(Failure::InvalidResponse);
        }
        Ok(())
    }
    pub fn into_parts(self) -> (WireRecord, RecordVersion) {
        (
            WireRecord {
                id: self.id,
                rev: self.rev,
                deleted: self.deleted,
                blob: self.blob,
            },
            self.record_version,
        )
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChangesPage {
    scope: Scope,
    pub records: Vec<ServerRecord>,
    pub cursor: Cursor,
    pub has_more: bool,
    pub full_snapshot: bool,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Offer {
    pub record: WireRecord,
    pub expected_record_version: Option<RecordVersion>,
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum Outcome {
    Accepted {
        #[serde(rename = "recordVersion")]
        record_version: RecordVersion,
        revision: String,
    },
    Conflict {
        #[serde(rename = "authoritativeRecord")]
        authoritative_record: ServerRecord,
    },
    Rejected {
        #[serde(rename = "errorCode")]
        error_code: ErrorCode,
        #[serde(rename = "retryAfterSeconds", default, deserialize_with = "non_null")]
        retry_after_seconds: Option<u32>,
    },
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Batch {
    scope: Scope,
    pub outcomes: Vec<Outcome>,
    pub partial: bool,
}

pub struct BoundTransport {
    client: CloudClient,
    token: Credential,
    scope: Scope,
    role: Role,
    key_epoch: u64,
    halt: Option<Failure>,
}
impl BoundTransport {
    pub(crate) fn checkpoint_scope(&self) -> crate::journal::Scope {
        let (membership, dataset) = self.scope.identities(&self.client.server);
        crate::journal::Scope {
            membership,
            dataset,
        }
    }
    pub(crate) fn feed(&self) -> crate::journal::Result<crate::inbound::Feed> {
        crate::inbound::Feed::new(self.scope.feed_epoch, self.key_epoch)
    }
    pub(crate) fn current_role(&self) -> Role {
        self.role
    }
    fn remember<T>(&mut self, result: Result<T>) -> Result<T> {
        if let Err(failure @ (Failure::AccountReview | Failure::DatasetReview)) = &result {
            self.halt = Some(*failure);
        }
        result
    }
    fn adopt_feed(&mut self, scope: Scope) -> Result<()> {
        let result = self.validate_feed(&scope);
        self.remember(result)?;
        self.scope = scope;
        Ok(())
    }
    fn validate_feed(&self, scope: &Scope) -> Result<()> {
        scope.validate(self.client.instance)?;
        let (old_owner, old_dataset) = self.scope.identities(&self.client.server);
        let (owner, dataset) = scope.identities(&self.client.server);
        if owner != old_owner {
            return Err(Failure::AccountReview);
        }
        if dataset != old_dataset {
            return Err(Failure::DatasetReview);
        }
        Ok(())
    }
    pub fn preflight(&mut self) -> Result<()> {
        if let Some(halt) = self.halt {
            return Err(halt);
        }
        let result = self.client.observe_space(&self.token, self.scope.space_id);
        let observed = self.remember(result)?;
        if observed.key_epoch != self.key_epoch {
            return self.remember(Err(Failure::DatasetReview));
        }
        self.adopt_feed(observed.scope)?;
        self.role = observed.role;
        Ok(())
    }
    pub fn fetch_page(&mut self, cursor: Option<&Cursor>) -> Result<ChangesPage> {
        let result = self.fetch_page_inner(cursor);
        self.remember(result)
    }
    fn fetch_page_inner(&mut self, cursor: Option<&Cursor>) -> Result<ChangesPage> {
        self.preflight()?;
        let mut url = self
            .client
            .server
            .endpoint(&format!("/v2/spaces/{}/changes", self.scope.space_id))?;
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("limit", &RECORDS_PER_MESSAGE.to_string());
            if let Some(cursor) = cursor {
                cursor.validate()?;
                query.append_pair("cursor", &cursor.0);
            }
        }
        let bytes = self.client.exchange(
            Method::GET,
            url,
            Some(&self.token),
            None,
            Reply::new(200, MAX_MESSAGE),
        )?;
        let page: ChangesPage = decode(&bytes)?;
        self.adopt_feed(page.scope.clone())?;
        page.cursor.validate()?;
        if page.records.len() > RECORDS_PER_MESSAGE
            || (cursor.is_none() && !page.full_snapshot)
            || (page.has_more && cursor == Some(&page.cursor))
        {
            return Err(Failure::InvalidResponse);
        }
        for record in &page.records {
            record.validate()?;
        }
        Ok(page)
    }
    /// Submit at most ten *durably journaled immutable* offers. The caller records
    /// acknowledgements before sending the next chunk, preserving partial success.
    /// Lost responses are retried with the original bytes and original CAS version.
    pub fn submit_chunk(&mut self, offers: &[Offer]) -> Result<Batch> {
        let result = self.submit_chunk_inner(offers);
        self.remember(result)
    }
    fn submit_chunk_inner(&mut self, offers: &[Offer]) -> Result<Batch> {
        if offers.is_empty() || offers.len() > RECORDS_PER_MESSAGE {
            return Err(Failure::MessageTooLarge);
        }
        let mut ids = std::collections::HashSet::new();
        for offer in offers {
            offer
                .record
                .validate()
                .map_err(|_| Failure::InvalidResponse)?;
            if let Some(version) = &offer.expected_record_version {
                version.validate()?;
            }
            if !ids.insert(offer.record.id) {
                return Err(Failure::InvalidResponse);
            }
        }
        self.preflight()?;
        if self.role == Role::Reader {
            return Err(Failure::ReadOnly);
        }
        let first = self.submit(offers);
        let batch = match first {
            Err(Failure::Server {
                code: ErrorCode::CursorInvalid,
                ..
            }) => {
                self.preflight()?;
                if self.role == Role::Reader {
                    return Err(Failure::ReadOnly);
                }
                self.submit(offers)?
            }
            Err(Failure::Server {
                code: ErrorCode::Forbidden,
                ..
            }) => {
                self.preflight()?;
                return first;
            }
            other => other?,
        };
        if batch.outcomes.len() != offers.len() {
            return Err(Failure::InvalidResponse);
        }
        for (outcome, offer) in batch.outcomes.iter().zip(offers) {
            match outcome {
                Outcome::Accepted {
                    record_version,
                    revision,
                } => {
                    record_version.validate()?;
                    if revision != &offer.record.rev {
                        return Err(Failure::InvalidResponse);
                    }
                }
                Outcome::Conflict {
                    authoritative_record,
                } => {
                    authoritative_record.validate()?;
                    if authoritative_record.id != offer.record.id {
                        return Err(Failure::InvalidResponse);
                    }
                }
                Outcome::Rejected {
                    retry_after_seconds,
                    ..
                } => {
                    if retry_after_seconds.is_some_and(|s| !(1..=86400).contains(&s)) {
                        return Err(Failure::InvalidResponse);
                    }
                }
            }
        }
        if batch.partial
            != batch
                .outcomes
                .iter()
                .any(|o| !matches!(o, Outcome::Accepted { .. }))
        {
            return Err(Failure::InvalidResponse);
        }
        self.adopt_feed(batch.scope.clone())?;
        Ok(batch)
    }
    fn submit(&self, offers: &[Offer]) -> Result<Batch> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Body<'a> {
            expected_scope: &'a Scope,
            items: &'a [Offer],
        }
        let body = encode(&Body {
            expected_scope: &self.scope,
            items: offers,
        })?;
        self.client.json(
            Method::POST,
            &format!("/v2/spaces/{}/records/batch", self.scope.space_id),
            Some(&self.token),
            Some(&body),
            200,
            MAX_MESSAGE,
        )
    }
}

#[path = "cloud_bootstrap.rs"]
mod bootstrap_transport;
pub use bootstrap_transport::{
    ActionChallenge, AuthorityState, Mutation, Pairing, PairingState, RecoveryState,
    RemoteRecovery, SignedAction,
};

#[cfg(test)]
#[path = "cloud_tests.rs"]
mod tests;
