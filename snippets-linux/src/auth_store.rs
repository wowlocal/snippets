//! Atomic Secret Service credential lineage. Every issued pair is durable before
//! metadata acceptance. Cleanup never revokes the committed refresh family.
use crate::{
    account_key::{self, AccountKey},
    canonical::{self, Value},
    cloud::{self, CloudClient, Credential, IssuedCredentials, NativeSession, ServerURL},
    secret_store::{self, Backend, Locked, Slot},
};
use std::collections::BTreeMap;
use uuid::Uuid;
use zeroize::Zeroizing;

#[path = "space_creation.rs"]
pub mod creation;
#[path = "device_sign_in.rs"]
pub mod device;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Secret(secret_store::Failure),
    InvalidState,
    Busy,
    Stale,
    WrongDeployment,
    InvalidClock,
    Expired,
    Cloud(cloud::Failure),
    Authentication(crate::local_auth::Failure),
    /// The saved session was approved by another device and has no account key.
    AccountKeyUnavailable,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<secret_store::Failure> for Failure {
    fn from(value: secret_store::Failure) -> Self {
        Self::Secret(value)
    }
}
impl From<crate::model::Error> for Failure {
    fn from(_: crate::model::Error) -> Self {
        Self::InvalidState
    }
}
impl From<cloud::Failure> for Failure {
    fn from(value: cloud::Failure) -> Self {
        Self::Cloud(value)
    }
}
impl From<crate::local_auth::Failure> for Failure {
    fn from(value: crate::local_auth::Failure) -> Self {
        Self::Authentication(value)
    }
}

// Private payload types have no Debug, Display or general serialization escape.
#[derive(Clone, PartialEq, Eq)]
pub struct Deployment {
    server: ServerURL,
    instance: Uuid,
}
impl Deployment {
    pub(crate) fn instance(&self) -> Uuid {
        self.instance
    }
    pub fn server(&self) -> &ServerURL {
        &self.server
    }
    /// Rediscover before sending credentials; a changed deployment never receives
    /// a token from the old installation, including during delayed cleanup.
    pub fn discover(&self) -> Result<CloudClient> {
        let client = CloudClient::discover(self.server.clone())?;
        if client.credential_deployment() != *self {
            return Err(Failure::WrongDeployment);
        }
        Ok(client)
    }
    pub(crate) fn from_discovery(server: ServerURL, instance: Uuid) -> Self {
        Self { server, instance }
    }
    fn value(&self) -> Value {
        object([
            ("server", Value::text(self.server.for_secure_storage())),
            ("instance", Value::text(self.instance.to_string())),
        ])
    }
    fn parse(value: &Value) -> Result<Self> {
        let v = exact(value, &["server", "instance"])?;
        let server = ServerURL::parse(v["server"].as_text()?).map_err(|_| Failure::InvalidState)?;
        if server.for_secure_storage() != v["server"].as_text()? {
            return Err(Failure::InvalidState);
        }
        let instance =
            Uuid::parse_str(v["instance"].as_text()?).map_err(|_| Failure::InvalidState)?;
        if instance.is_nil() || instance.to_string() != v["instance"].as_text()? {
            return Err(Failure::InvalidState);
        }
        Ok(Self { server, instance })
    }
}
#[derive(Clone, PartialEq, Eq)]
struct Pair {
    access: Zeroizing<String>,
    refresh: Zeroizing<String>,
}
impl Pair {
    fn overlaps(&self, other: &Self) -> bool {
        self.access == other.access
            || self.access == other.refresh
            || self.refresh == other.access
            || self.refresh == other.refresh
    }
    fn issued(value: &IssuedCredentials) -> Result<Self> {
        Ok(Self {
            access: text_token(value.access.for_secure_storage())?,
            refresh: text_token(value.refresh.for_secure_storage())?,
        })
    }
    fn value(&self) -> Value {
        object([
            ("access", Value::text(self.access.as_str())),
            ("refresh", Value::text(self.refresh.as_str())),
        ])
    }
    fn parse(value: &Value) -> Result<Self> {
        let v = exact(value, &["access", "refresh"])?;
        Ok(Self {
            access: text_token(v["access"].as_text()?.as_bytes())?,
            refresh: text_token(v["refresh"].as_text()?.as_bytes())?,
        })
    }
}
fn text_token(bytes: &[u8]) -> Result<Zeroizing<String>> {
    let text = std::str::from_utf8(bytes).map_err(|_| Failure::InvalidState)?;
    Credential::new(text.into()).map_err(|_| Failure::InvalidState)?;
    Ok(Zeroizing::new(text.into()))
}
/// The account key is stored beside the session it signed in, in the same
/// device-only Secret Service document, and is removed with it on sign-out.
/// A session approved by another device (ADR 0007) has none.
#[derive(Clone, PartialEq)]
struct Session {
    deployment: Deployment,
    pair: Pair,
    account: Zeroizing<String>,
    account_key: Option<AccountKey>,
    expires_at: i64,
}
impl Session {
    fn value(&self) -> Value {
        object([
            ("deployment", self.deployment.value()),
            ("pair", self.pair.value()),
            ("account", Value::text(self.account.as_str())),
            (
                "accountKey",
                optional(
                    self.account_key
                        .as_ref()
                        .map(|key| Value::text(key.canonical())),
                ),
            ),
            ("expiresAt", Value::Int(self.expires_at)),
        ])
    }
    fn parse(value: &Value) -> Result<Self> {
        let v = exact(
            value,
            &["deployment", "pair", "account", "accountKey", "expiresAt"],
        )?;
        let pair = Pair::parse(&v["pair"])?;
        let account = v["account"].as_text()?;
        let account_key = parse_optional(&v["accountKey"], |value| {
            AccountKey::from_canonical(value.as_text()?).ok_or(Failure::InvalidState)
        })?;
        let expires_at = v["expiresAt"].as_int()?;
        if pair.access == pair.refresh || !account_key::valid_account_id(account) || expires_at < 0
        {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            deployment: Deployment::parse(&v["deployment"])?,
            pair,
            account: Zeroizing::new(account.into()),
            account_key,
            expires_at,
        })
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Replacement {
    Interactive,
    Refresh,
    Logout,
}
impl Replacement {
    fn name(self) -> &'static str {
        match self {
            Self::Interactive => "interactive",
            Self::Refresh => "refresh",
            Self::Logout => "logout",
        }
    }
    fn parse(value: &Value) -> Result<Self> {
        match value.as_text()? {
            "interactive" => Ok(Self::Interactive),
            "refresh" => Ok(Self::Refresh),
            "logout" => Ok(Self::Logout),
            _ => Err(Failure::InvalidState),
        }
    }
}
#[derive(Clone, PartialEq)]
struct Pending {
    kind: Replacement,
    deployment: Deployment,
    previous: Option<Session>,
    issued: Option<Pair>,
    published: bool,
    cleaning: bool,
    acknowledged: u8,
}
impl Pending {
    fn value(&self) -> Value {
        object([
            ("kind", Value::text(self.kind.name())),
            ("deployment", self.deployment.value()),
            (
                "previous",
                optional(self.previous.as_ref().map(Session::value)),
            ),
            ("issued", optional(self.issued.as_ref().map(Pair::value))),
            ("published", Value::Bool(self.published)),
            ("cleaning", Value::Bool(self.cleaning)),
            ("acknowledged", Value::Int(self.acknowledged.into())),
        ])
    }
    fn parse(value: &Value) -> Result<Self> {
        let v = exact(
            value,
            &[
                "kind",
                "deployment",
                "previous",
                "issued",
                "published",
                "cleaning",
                "acknowledged",
            ],
        )?;
        Ok(Self {
            kind: Replacement::parse(&v["kind"])?,
            deployment: Deployment::parse(&v["deployment"])?,
            previous: parse_optional(&v["previous"], Session::parse)?,
            issued: parse_optional(&v["issued"], Pair::parse)?,
            published: v["published"].as_bool()?,
            cleaning: v["cleaning"].as_bool()?,
            acknowledged: u8::try_from(v["acknowledged"].as_int()?)
                .map_err(|_| Failure::InvalidState)?,
        })
    }
    fn cleanup(&self) -> Vec<(Deployment, Zeroizing<String>, bool)> {
        let mut actions = Vec::new();
        let mut append = |deployment: &Deployment, pair: &Pair, include_refresh: bool| {
            actions.push((deployment.clone(), pair.access.clone(), false));
            if include_refresh {
                actions.push((deployment.clone(), pair.refresh.clone(), true));
            }
        };
        if (self.kind == Replacement::Logout || self.published || self.kind == Replacement::Refresh)
            && let Some(previous) = &self.previous
        {
            append(
                &previous.deployment,
                &previous.pair,
                !(self.published && self.kind == Replacement::Refresh),
            );
        }
        if !self.published
            && let Some(issued) = &self.issued
        {
            append(&self.deployment, issued, true);
        }
        actions
    }
}
pub struct Lease {
    generation: u64,
}
pub struct CleanupAction {
    generation: u64,
    index: u8,
    deployment: Deployment,
    token: Zeroizing<String>,
    refresh: bool,
}
pub struct CleanupReceipt {
    generation: u64,
    index: u8,
    deployment: Deployment,
    token: Zeroizing<String>,
    refresh: bool,
}
impl CleanupAction {
    /// Only the exact pinned deployment may retire this token. A receipt cannot
    /// be constructed by production callers without a successful HTTP response.
    pub fn execute(self, client: &CloudClient) -> Result<CleanupReceipt> {
        if self.deployment != client.credential_deployment() {
            return Err(Failure::WrongDeployment);
        }
        client.preflight_credentials()?;
        client.revoke(&Credential::new(self.token.as_str().into())?, self.refresh)?;
        Ok(CleanupReceipt {
            generation: self.generation,
            index: self.index,
            deployment: self.deployment,
            token: self.token,
            refresh: self.refresh,
        })
    }
}
/// Schema 2 stores the account key with each session. Schema 1 belonged to the
/// retired email/code sign-in, which no deployment ever served.
const SCHEMA: i64 = 2;
const RETIRED_EMAIL_SCHEMA: i64 = 1;
pub struct Archive {
    generation: u64,
    current: Option<Session>,
    pending: Option<Pending>,
    snapshot: Option<Zeroizing<Vec<u8>>>,
    retired: bool,
}
impl Archive {
    pub fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Self> {
        let snapshot = owner.read(Slot::Credentials)?;
        let (generation, current, pending, retired) = if let Some(bytes) = &snapshot {
            let value = canonical::parse(bytes)?;
            let v = exact(&value, &["schema", "generation", "current", "pending"])?;
            let generation =
                u64::try_from(v["generation"].as_int()?).map_err(|_| Failure::InvalidState)?;
            match v["schema"].as_int()? {
                SCHEMA => (
                    generation,
                    parse_optional(&v["current"], Session::parse)?,
                    parse_optional(&v["pending"], Pending::parse)?,
                    false,
                ),
                // Like any session that can no longer be used, a retired email
                // session is never read or sent: the owner signs in again. Only
                // its generation survives, so stale leases stay fenced; recovery
                // replaces the document so no account email remains stored.
                RETIRED_EMAIL_SCHEMA => (generation, None, None, true),
                _ => return Err(Failure::InvalidState),
            }
        } else {
            (0, None, None, false)
        };
        let archive = Self {
            generation,
            current,
            pending,
            snapshot,
            retired,
        };
        archive.validate()?;
        Ok(archive)
    }
    fn validate(&self) -> Result<()> {
        if let Some(current) = &self.current {
            if self.generation == 0 {
                return Err(Failure::InvalidState);
            }
            Session::parse(&current.value())?;
        }
        if let Some(p) = &self.pending {
            Deployment::parse(&p.deployment.value())?;
            if let Some(previous) = &p.previous {
                Session::parse(&previous.value())?;
            }
            if self.generation == 0
                || (!p.cleaning && p.acknowledged != 0)
                || p.acknowledged as usize >= (1usize << p.cleanup().len())
                || (p.kind == Replacement::Refresh
                    && (p.previous.is_none()
                        || p.previous
                            .as_ref()
                            .is_some_and(|s| s.deployment != p.deployment)))
                || (p.kind == Replacement::Logout
                    && (!p.published
                        || p.previous.is_none()
                        || p.previous
                            .as_ref()
                            .is_some_and(|s| s.deployment != p.deployment)
                        || p.issued.is_some()
                        || self.current.is_some()))
            {
                return Err(Failure::InvalidState);
            }
            if p.published && p.kind != Replacement::Logout {
                let current = self.current.as_ref().ok_or(Failure::InvalidState)?;
                if Some(&current.pair) != p.issued.as_ref() || current.deployment != p.deployment {
                    return Err(Failure::InvalidState);
                }
                if p.previous.as_ref().is_some_and(|previous| {
                    (previous.deployment == current.deployment
                        && previous.pair.overlaps(&current.pair))
                        || (p.kind == Replacement::Refresh
                            && (previous.account != current.account
                                || previous.account_key != current.account_key))
                }) {
                    return Err(Failure::InvalidState);
                }
            } else if p.kind != Replacement::Logout && self.current != p.previous {
                return Err(Failure::InvalidState);
            }
        }
        Ok(())
    }
    pub fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> Result<()> {
        self.validate()?;
        let value = object([
            ("schema", Value::Int(SCHEMA)),
            (
                "generation",
                Value::Int(i64::try_from(self.generation).map_err(|_| Failure::InvalidState)?),
            ),
            (
                "current",
                optional(self.current.as_ref().map(Session::value)),
            ),
            (
                "pending",
                optional(self.pending.as_ref().map(Pending::value)),
            ),
        ]);
        let bytes = value.encode()?;
        owner.replace(
            Slot::Credentials,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        self.retired = false;
        Ok(())
    }
    pub fn begin(&mut self, kind: Replacement, deployment: Deployment) -> Result<Lease> {
        if self.pending.is_some() {
            return Err(Failure::Busy);
        }
        Deployment::parse(&deployment.value())?;
        if matches!(kind, Replacement::Refresh | Replacement::Logout)
            && self
                .current
                .as_ref()
                .is_none_or(|s| s.deployment != deployment)
        {
            return Err(Failure::WrongDeployment);
        }
        self.generation = self
            .generation
            .checked_add(1)
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or(Failure::InvalidState)?;
        let previous = self.current.clone();
        if kind == Replacement::Logout {
            self.current = None;
        }
        self.pending = Some(Pending {
            kind,
            deployment,
            previous,
            issued: None,
            published: kind == Replacement::Logout,
            cleaning: false,
            acknowledged: 0,
        });
        Ok(Lease {
            generation: self.generation,
        })
    }
    pub fn resume(&self) -> Option<Lease> {
        self.pending.as_ref().map(|_| Lease {
            generation: self.generation,
        })
    }
    fn pending_mut(&mut self, lease: &Lease) -> Result<&mut Pending> {
        if lease.generation != self.generation {
            return Err(Failure::Stale);
        }
        self.pending.as_mut().ok_or(Failure::Stale)
    }
    pub fn stage_issued(&mut self, lease: &Lease, issued: &IssuedCredentials) -> Result<()> {
        let pair = Pair::issued(issued)?;
        let pending = self.pending_mut(lease)?;
        if pending.published || pending.cleaning || pending.kind == Replacement::Logout {
            return Err(Failure::Busy);
        }
        if pending.issued.as_ref().is_some_and(|p| p != &pair) {
            return Err(Failure::Stale);
        }
        pending.issued = Some(pair);
        Ok(())
    }
    pub fn publish(&mut self, lease: &Lease, session: &NativeSession, now: i64) -> Result<()> {
        let pair = Pair::issued(&session.credentials)?;
        let pending = self.pending_mut(lease)?;
        if pending.cleaning || pending.published || pending.kind == Replacement::Logout {
            return Err(Failure::Busy);
        }
        if pending.issued.as_ref() != Some(&pair) || pair.access == pair.refresh || now < 0 {
            return Err(Failure::InvalidState);
        }
        if pending.previous.as_ref().is_some_and(|p| {
            (p.deployment == pending.deployment && p.pair.overlaps(&pair))
                || (pending.kind == Replacement::Refresh
                    && p.account.as_str() != session.account_for_secure_storage())
        }) {
            return Err(Failure::InvalidState);
        }
        // An interactive grant carries the key it was issued or signed in with,
        // except a device-approved grant, which has none on this device. A
        // rotation keeps the same account's key; it never introduces another.
        let account_key = match (
            pending.kind,
            session.issued_account_key(),
            session.device_approval(),
        ) {
            (Replacement::Interactive, Some(key), None) => Some(key.clone()),
            (Replacement::Interactive, None, Some(_)) => None,
            (Replacement::Refresh, issued, None) => {
                let previous = pending.previous.as_ref().ok_or(Failure::InvalidState)?;
                if issued.is_some_and(|key| Some(key) != previous.account_key.as_ref()) {
                    return Err(Failure::InvalidState);
                }
                previous.account_key.clone()
            }
            _ => return Err(Failure::InvalidState),
        };
        let expires_at = now
            .checked_add(
                i64::try_from(session.expires_in().as_secs()).map_err(|_| Failure::InvalidState)?,
            )
            .ok_or(Failure::InvalidState)?;
        let current = Session {
            deployment: pending.deployment.clone(),
            pair,
            account: Zeroizing::new(session.account_for_secure_storage().into()),
            account_key,
            expires_at,
        };
        Session::parse(&current.value())?;
        pending.published = true;
        self.current = Some(current);
        Ok(())
    }
    pub fn begin_cleanup(&mut self, lease: &Lease) -> Result<()> {
        self.pending_mut(lease)?.cleaning = true;
        Ok(())
    }
    pub fn cleanup_actions(&self, lease: &Lease) -> Result<Vec<CleanupAction>> {
        if lease.generation != self.generation {
            return Err(Failure::Stale);
        }
        let pending = self
            .pending
            .as_ref()
            .filter(|p| p.cleaning)
            .ok_or(Failure::Busy)?;
        Ok(pending
            .cleanup()
            .into_iter()
            .enumerate()
            .filter(|(i, _)| pending.acknowledged & (1 << i) == 0)
            .map(|(index, (deployment, token, refresh))| CleanupAction {
                generation: self.generation,
                index: index as u8,
                deployment,
                token,
                refresh,
            })
            .collect())
    }
    pub fn acknowledge(&mut self, receipt: CleanupReceipt) -> Result<()> {
        let pending = self.pending_mut(&Lease {
            generation: receipt.generation,
        })?;
        if !pending.cleaning {
            return Err(Failure::Busy);
        }
        let actions = pending.cleanup();
        let expected = actions.get(receipt.index as usize).ok_or(Failure::Stale)?;
        if expected.0 != receipt.deployment
            || expected.1 != receipt.token
            || expected.2 != receipt.refresh
        {
            return Err(Failure::Stale);
        }
        pending.acknowledged |= 1 << receipt.index;
        Ok(())
    }
    pub fn finish_cleanup(&mut self, lease: &Lease) -> Result<()> {
        let pending = self.pending_mut(lease)?;
        if !pending.cleaning
            || pending.acknowledged as usize != (1usize << pending.cleanup().len()) - 1
        {
            return Err(Failure::Busy);
        }
        if !pending.published
            && (pending.kind == Replacement::Refresh
                || pending.previous.as_ref().is_some_and(|previous| {
                    previous.deployment == pending.deployment
                        && pending
                            .issued
                            .as_ref()
                            .is_some_and(|issued| previous.pair.overlaps(issued))
                }))
        {
            self.current = None;
        }
        self.pending = None;
        Ok(())
    }
    /// Stored access tokens are never handed out after restart. The owner must
    /// refresh, validating wall/monotonic lifetime in its live request context.
    /// The profile exposes only the short public account ID for display.
    pub fn profile_account(&self) -> Result<Option<String>> {
        if self.pending.is_some() {
            return Err(Failure::Busy);
        }
        self.current
            .as_ref()
            .map(|s| account_key::account_id_display(&s.account).ok_or(Failure::InvalidState))
            .transpose()
    }
    /// Exact saved session whose key an owner-authenticated disclosure may show.
    /// The digest binds deployment, account and generation, never the key itself.
    pub(crate) fn account_key_target(&self) -> Result<([u8; 32], i64)> {
        use sha2::{Digest, Sha256};
        if self.pending.is_some() {
            return Err(Failure::Busy);
        }
        let current = self.current.as_ref().ok_or(Failure::InvalidState)?;
        if current.account_key.is_none() {
            return Err(Failure::AccountKeyUnavailable);
        }
        let mut digest = Sha256::new();
        digest.update(b"snippets-account-key-disclosure-v1\0");
        for field in [
            current.deployment.server.for_secure_storage(),
            &current.deployment.instance.to_string(),
            current.account.as_str(),
        ] {
            digest.update((field.len() as u32).to_be_bytes());
            digest.update(field.as_bytes());
        }
        Ok((
            digest.finalize().into(),
            i64::try_from(self.generation).map_err(|_| Failure::InvalidState)?,
        ))
    }
    /// Only for a disclosure whose permit was consumed against account_key_target().
    pub(crate) fn account_key_for_disclosure(&self) -> Result<&AccountKey> {
        if self.pending.is_some() {
            return Err(Failure::Busy);
        }
        self.current
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .account_key
            .as_ref()
            .ok_or(Failure::AccountKeyUnavailable)
    }
    pub fn saved_deployment(&self) -> Result<Option<Deployment>> {
        if self.pending.is_some() {
            return Err(Failure::Busy);
        }
        Ok(self.current.as_ref().map(|s| s.deployment.clone()))
    }
    pub fn refresh_credential(&self, deployment: &Deployment) -> Result<Credential> {
        if self.pending.is_some() {
            return Err(Failure::Busy);
        }
        let current = self
            .current
            .as_ref()
            .filter(|s| s.deployment == *deployment)
            .ok_or(Failure::WrongDeployment)?;
        Ok(Credential::new(current.pair.refresh.as_str().into())?)
    }
    pub fn account_for_refresh(&self, deployment: &Deployment) -> Result<&str> {
        if self.pending.is_some() {
            return Err(Failure::Busy);
        }
        self.current
            .as_ref()
            .filter(|s| s.deployment == *deployment)
            .map(|s| s.account.as_str())
            .ok_or(Failure::WrongDeployment)
    }
}

/// If secure persistence fails after the server issues a pair, the caller keeps
/// ownership of that pair. Never drop this value into a generic error/log path.
pub struct Rejected {
    pub failure: Failure,
    pub unrecorded: Option<Unrecorded>,
}
pub struct Unrecorded {
    credentials: IssuedCredentials,
    lease: Lease,
    deployment: Deployment,
}
impl Unrecorded {
    /// Retry before cleanup or another issuance. The sealed generation and
    /// deployment prevent an old error from overwriting a later pending grant.
    pub fn retain<B: Backend>(
        self,
        store: &mut secret_store::Store<B>,
    ) -> std::result::Result<(), Rejected> {
        let result: Result<()> = store.transaction_with(|owner| {
            let mut archive = Archive::load(owner)?;
            if archive
                .pending
                .as_ref()
                .is_none_or(|p| p.deployment != self.deployment)
            {
                return Err(Failure::Stale);
            }
            archive.stage_issued(&self.lease, &self.credentials)?;
            archive.save(owner)
        });
        result.map_err(|failure| Rejected {
            failure,
            unrecorded: Some(self),
        })
    }
}
impl From<Failure> for Rejected {
    fn from(failure: Failure) -> Self {
        Self {
            failure,
            unrecorded: None,
        }
    }
}
impl From<secret_store::Failure> for Rejected {
    fn from(failure: secret_store::Failure) -> Self {
        Failure::Secret(failure).into()
    }
}
/// A live access token is bounded by both wall time and suspend-aware monotonic
/// time, anchored before the issuance request. It is never restored from disk.
pub struct LiveSession {
    deployment: Deployment,
    session: NativeSession,
    monotonic_deadline: std::time::Duration,
    wall_deadline: std::time::SystemTime,
}
impl LiveSession {
    #[cfg(feature = "desktop")]
    pub(crate) fn validate_owner<B: Backend>(
        &self,
        owner: &mut Locked<'_, B>,
        deployment: &Deployment,
    ) -> Result<()> {
        self.validate_current(&Archive::load(owner)?, deployment)
    }
    pub fn access(&self) -> Result<&Credential> {
        let now = crate::clock::uptime().ok_or(Failure::InvalidClock)?;
        if now >= self.monotonic_deadline || std::time::SystemTime::now() >= self.wall_deadline {
            return Err(Failure::Expired);
        }
        Ok(&self.session.credentials.access)
    }
    /// Short public account ID for the signed-in screen; never logged.
    pub fn account_display(&self) -> Result<String> {
        account_key::account_id_display(self.session.account_for_secure_storage())
            .ok_or(Failure::InvalidState)
    }
    fn validate_current(&self, archive: &Archive, deployment: &Deployment) -> Result<()> {
        self.access()?;
        if archive.pending.is_some() {
            return Err(Failure::Busy);
        }
        let current = archive.current.as_ref().ok_or(Failure::InvalidState)?;
        if self.deployment != *deployment
            || current.deployment != *deployment
            || current.account.as_str() != self.session.account_for_secure_storage()
            || current.pair != Pair::issued(&self.session.credentials)?
        {
            return Err(Failure::Stale);
        }
        Ok(())
    }
}
/// Offline check of the committed credential lineage. A bounded live token may
/// not outlive replacement/logout in another owner of the same secure namespace.
pub fn validate_session<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
    live: &LiveSession,
) -> Result<()> {
    let deployment = client.credential_deployment();
    store.transaction_with(|owner| live.validate_current(&Archive::load(owner)?, &deployment))
}
struct Previous {
    refresh: Credential,
    account: Zeroizing<String>,
}

/// One owner-authenticated presentation of the saved account key. It is readable
/// only while its single-use authorization lease remains valid: backgrounding,
/// desktop lock, cancellation or either deadline closes it.
pub struct AccountKeyDisclosure {
    key: AccountKey,
    lease: crate::local_auth::AuthorizationLease,
}
impl AccountKeyDisclosure {
    pub fn display(&self) -> Result<Zeroizing<String>> {
        self.lease.check()?;
        Ok(self.key.display())
    }
    pub fn valid(&self) -> bool {
        self.lease.check().is_ok()
    }
    #[cfg(all(test, feature = "desktop"))]
    pub(crate) fn fixture(
        permit: crate::local_auth::Permit,
        target: &crate::local_auth::Target,
        key: &str,
    ) -> Self {
        // Synthetic UI fixture: exact lease semantics, no keyring/account/PAM.
        Self {
            key: AccountKey::from_canonical(key).unwrap(),
            lease: permit.consume(target).unwrap(),
        }
    }
}
fn account_key_target(archive: &Archive) -> Result<crate::local_auth::Target> {
    let (digest, generation) = archive.account_key_target()?;
    Ok(crate::local_auth::Target::account_key(generation, digest)?)
}
/// Offline: identifies the exact saved session whose key the owner may reveal.
/// No key, token or network request is involved in preparing the target.
pub fn prepare_account_key_disclosure<B: Backend>(
    store: &mut secret_store::Store<B>,
) -> Result<crate::local_auth::Target> {
    store.transaction_with(|owner| account_key_target(&Archive::load(owner)?))
}
/// Consumes fresh owner authority only after rereading the saved credentials.
/// A permit for a replaced, refreshed or signed-out session discloses nothing.
pub fn reveal_account_key<B: Backend>(
    store: &mut secret_store::Store<B>,
    permit: crate::local_auth::Permit,
) -> Result<AccountKeyDisclosure> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        let lease = permit.consume(&account_key_target(&archive)?)?;
        let disclosure = AccountKeyDisclosure {
            key: archive.account_key_for_disclosure()?.clone(),
            lease,
        };
        disclosure.lease.check()?;
        Ok(disclosure)
    })
}

fn finish<B: Backend>(
    owner: &mut Locked<'_, B>,
    archive: &mut Archive,
    lease: &Lease,
    execute: &mut impl FnMut(CleanupAction) -> Result<CleanupReceipt>,
) -> Result<()> {
    archive.begin_cleanup(lease)?;
    archive.save(owner)?;
    for action in archive.cleanup_actions(lease)? {
        let receipt = execute(action)?;
        archive.acknowledge(receipt)?;
        archive.save(owner)?;
    }
    archive.finish_cleanup(lease)?;
    archive.save(owner)
}

fn execute_network(
    action: CleanupAction,
    current: Option<&CloudClient>,
    discovered: &mut Vec<CloudClient>,
) -> Result<CleanupReceipt> {
    if let Some(client) = current.filter(|c| c.credential_deployment() == action.deployment) {
        return action.execute(client);
    }
    if let Some(client) = discovered
        .iter()
        .find(|c| c.credential_deployment() == action.deployment)
    {
        return action.execute(client);
    }
    discovered.push(action.deployment.discover()?);
    action.execute(discovered.last().ok_or(Failure::InvalidState)?)
}

/// Owner-worker operations only. The independent process mutex spans the whole
/// durable transition and HTTP exchange; GTK and library writes remain free.
pub fn recover<B: Backend>(store: &mut secret_store::Store<B>) -> Result<()> {
    let mut discovered = Vec::new();
    recover_with(store, &mut |a| execute_network(a, None, &mut discovered))
}
fn recover_with<B: Backend>(
    store: &mut secret_store::Store<B>,
    execute: &mut impl FnMut(CleanupAction) -> Result<CleanupReceipt>,
) -> Result<()> {
    store.transaction_with(|owner| {
        let mut archive = Archive::load(owner)?;
        if archive.retired {
            // Replace the retired email-era document before any new issuance.
            archive.save(owner)?;
        }
        if let Some(lease) = archive.resume() {
            finish(owner, &mut archive, &lease, execute)?;
        }
        Ok(())
    })
}
pub fn sign_out<B: Backend>(store: &mut secret_store::Store<B>) -> Result<()> {
    let mut discovered = Vec::new();
    sign_out_with(store, &mut |a| execute_network(a, None, &mut discovered))
}
fn sign_out_with<B: Backend>(
    store: &mut secret_store::Store<B>,
    execute: &mut impl FnMut(CleanupAction) -> Result<CleanupReceipt>,
) -> Result<()> {
    store.transaction_with(|owner| {
        let mut archive = Archive::load(owner)?;
        if archive.pending.is_some() {
            return Err(Failure::Busy);
        }
        let Some(current) = &archive.current else {
            return Ok(());
        };
        let lease = archive.begin(Replacement::Logout, current.deployment.clone())?;
        archive.save(owner)?;
        finish(owner, &mut archive, &lease, execute)
    })
}
/// Interactive grants use the same journaled issuance as every other credential
/// replacement. The key is held only for publication beside the new session.
pub fn sign_in<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
    key: &AccountKey,
) -> std::result::Result<LiveSession, Rejected> {
    let mut discovered = Vec::new();
    let mut live = issue(
        store,
        Replacement::Interactive,
        client.credential_deployment(),
        |_| {
            client.preflight_credentials()?;
            Ok(client.sign_in(key)?)
        },
        &mut |a| execute_network(a, Some(client), &mut discovered),
    )?;
    drop(live.session.take_issued_account_key());
    Ok(live)
}
/// Commits an approved device claim through the same journaled issuance as an
/// account-key sign-in. The claim response was received by the caller, so the
/// live deadline is anchored when this commit starts, milliseconds later than
/// issuance. A lost or rejected commit is recovered by claiming again: the
/// server revokes the earlier family before issuing another.
pub fn sign_in_with_device<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
    grant: cloud::IssuedGrant,
) -> std::result::Result<(LiveSession, cloud::DeviceApproval), Rejected> {
    let mut discovered = Vec::new();
    let live = issue(
        store,
        Replacement::Interactive,
        client.credential_deployment(),
        |_| Ok(grant),
        &mut |a| execute_network(a, Some(client), &mut discovered),
    )?;
    let approval = live
        .session
        .device_approval()
        .ok_or(Rejected::from(Failure::InvalidState))?;
    Ok((live, approval))
}
/// A new account's key is returned exactly once, after its session is committed
/// with the key in secure storage, so the owner can be asked to save it.
pub fn create_account<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
) -> std::result::Result<(LiveSession, AccountKey), Rejected> {
    let mut discovered = Vec::new();
    create_account_with(
        store,
        client.credential_deployment(),
        |_| {
            client.preflight_credentials()?;
            Ok(client.create_account()?)
        },
        &mut |a| execute_network(a, Some(client), &mut discovered),
    )
}
fn create_account_with<B: Backend>(
    store: &mut secret_store::Store<B>,
    deployment: Deployment,
    request: impl FnOnce(Option<&Previous>) -> Result<cloud::IssuedGrant>,
    execute: &mut impl FnMut(CleanupAction) -> Result<CleanupReceipt>,
) -> std::result::Result<(LiveSession, AccountKey), Rejected> {
    let mut live = issue(
        store,
        Replacement::Interactive,
        deployment,
        request,
        execute,
    )?;
    let key = live
        .session
        .take_issued_account_key()
        .ok_or(Failure::InvalidState)?;
    Ok((live, key))
}
pub fn refresh<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
) -> std::result::Result<LiveSession, Rejected> {
    refresh_checked(store, client, &|| Ok(()))
}
/// Cancellation fences new requests. Once a refresh response exists, its grant
/// still goes through the durable credential owner, even if consent was revoked.
pub fn refresh_checked<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
    check: &dyn Fn() -> Result<()>,
) -> std::result::Result<LiveSession, Rejected> {
    refresh_bound(store, client, check, &|_, _| Ok(()))
}
/// The saved account is rechecked under the same credential lock that owns the
/// refresh request. A concurrent account replacement cannot send its token.
pub fn refresh_bound<B: Backend>(
    store: &mut secret_store::Store<B>,
    client: &CloudClient,
    check: &dyn Fn() -> Result<()>,
    validate_account: &dyn Fn(&Deployment, &str) -> Result<()>,
) -> std::result::Result<LiveSession, Rejected> {
    check().map_err(Rejected::from)?;
    let mut discovered = Vec::new();
    issue(
        store,
        Replacement::Refresh,
        client.credential_deployment(),
        |previous| {
            let previous = previous.ok_or(Failure::InvalidState)?;
            validate_account(&client.credential_deployment(), &previous.account)?;
            check()?;
            client.preflight_credentials()?;
            check()?;
            Ok(client.refresh(&previous.refresh)?)
        },
        &mut |a| execute_network(a, Some(client), &mut discovered),
    )
}
fn issue<B: Backend>(
    store: &mut secret_store::Store<B>,
    kind: Replacement,
    deployment: Deployment,
    request: impl FnOnce(Option<&Previous>) -> Result<cloud::IssuedGrant>,
    execute: &mut impl FnMut(CleanupAction) -> Result<CleanupReceipt>,
) -> std::result::Result<LiveSession, Rejected> {
    store.transaction_with(|owner| {
        let mut archive = Archive::load(owner)?;
        let previous = if kind == Replacement::Refresh {
            Some(Previous {
                refresh: archive.refresh_credential(&deployment)?,
                account: Zeroizing::new(archive.account_for_refresh(&deployment)?.into()),
            })
        } else {
            None
        };
        let monotonic = crate::clock::uptime().ok_or(Failure::InvalidClock)?;
        let wall = std::time::SystemTime::now();
        let now = i64::try_from(
            wall.duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| Failure::InvalidClock)?
                .as_secs(),
        )
        .map_err(|_| Failure::InvalidClock)?;
        let lease = archive.begin(kind, deployment.clone())?;
        archive.save(owner)?;
        let grant = request(previous.as_ref())?;
        let mut commit_failure = None;
        let session = grant
            .accept(
                |credentials| {
                    let result = archive
                        .stage_issued(&lease, credentials)
                        .and_then(|()| archive.save(owner));
                    if let Err(failure) = result {
                        commit_failure = Some(failure);
                        return Err(cloud::Failure::CredentialCommit);
                    }
                    Ok(())
                },
                previous.as_ref().map(|p| p.account.as_str()),
                previous.as_ref().map(|p| &p.refresh),
            )
            .map_err(|invalid| Rejected {
                failure: commit_failure.unwrap_or(Failure::Cloud(invalid.failure)),
                unrecorded: commit_failure.map(|_| Unrecorded {
                    credentials: invalid.credentials,
                    lease: Lease {
                        generation: lease.generation,
                    },
                    deployment: deployment.clone(),
                }),
            })?;
        archive.publish(&lease, &session, now)?;
        archive.save(owner)?;
        finish(owner, &mut archive, &lease, execute)?;
        let live = LiveSession {
            deployment,
            monotonic_deadline: monotonic
                .checked_add(session.expires_in())
                .ok_or(Failure::InvalidClock)?,
            wall_deadline: wall
                .checked_add(session.expires_in())
                .ok_or(Failure::InvalidClock)?,
            session,
        };
        live.access()?;
        Ok(live)
    })
}
fn object<const N: usize>(values: [(&str, Value); N]) -> Value {
    Value::Object(values.into_iter().map(|(k, v)| (k.into(), v)).collect())
}
fn exact<'a>(value: &'a Value, keys: &[&str]) -> Result<&'a BTreeMap<String, Value>> {
    let v = value.as_object()?;
    if v.len() != keys.len() || !keys.iter().all(|k| v.contains_key(*k)) {
        return Err(Failure::InvalidState);
    }
    Ok(v)
}
fn optional(value: Option<Value>) -> Value {
    value.unwrap_or(Value::Null)
}
fn parse_optional<T>(value: &Value, parse: impl FnOnce(&Value) -> Result<T>) -> Result<Option<T>> {
    if matches!(value, Value::Null) {
        Ok(None)
    } else {
        parse(value).map(Some)
    }
}

#[cfg(test)]
#[path = "auth_store_tests.rs"]
mod tests;
