//! Metadata-only vault catalogue, durable encrypted edits, and bounded sessions.
use crate::{
    clock::{self, Hlc},
    crypto::{self, KdfParameters, RootKey, Sealed},
    model::{self, Error, Library, Result, Snippet},
};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;
use zeroize::Zeroizing;

const UNREADABLE: Error = Error("The encrypted vault could not be read safely.");
const EXPIRED: Error = Error("The authentication request expired. Unlock Secure Snippets again.");
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(300);
pub const SESSION_TIMEOUT: Duration = Duration::from_secs(1800);
fn enabled() -> bool {
    true
}
fn distant_past() -> DateTime<Utc> {
    DateTime::from_timestamp(-62_135_596_800, 0).expect("year one")
}
mod iso_date {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        value: &DateTime<Utc>,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Millis, true))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<DateTime<Utc>, D::Error> {
        DateTime::parse_from_rfc3339(&String::deserialize(deserializer)?)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|_| serde::de::Error::custom("Invalid vault timestamp"))
    }
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    #[serde(serialize_with = "model::serialize_id")]
    pub id: Uuid,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub keyword: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default = "enabled")]
    pub is_enabled: bool,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default = "distant_past", with = "iso_date")]
    pub created_at: DateTime<Utc>,
    #[serde(default = "distant_past", with = "iso_date")]
    pub updated_at: DateTime<Utc>,
}
impl Metadata {
    pub fn new() -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4(),
            name: String::new(),
            keyword: String::new(),
            tags: vec![],
            is_enabled: true,
            is_pinned: false,
            created_at: now,
            updated_at: now,
        }
    }
    pub fn shell(&self) -> Snippet {
        Snippet {
            id: self.id,
            name: self.name.clone(),
            keyword: self.keyword.clone(),
            content: String::new(),
            tags: self.tags.clone(),
            is_enabled: self.is_enabled,
            is_pinned: self.is_pinned,
            created_at: self.created_at.timestamp_millis() as f64 / 1000.0 - model::SWIFT_EPOCH,
            updated_at: self.updated_at.timestamp_millis() as f64 / 1000.0 - model::SWIFT_EPOCH,
        }
    }
    pub fn validate(mut self) -> Result<Self> {
        let normalized = self.shell().validate()?;
        self.keyword = normalized.keyword;
        self.tags = normalized.tags;
        Ok(self)
    }
}
impl Default for Metadata {
    fn default() -> Self {
        Self::new()
    }
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    #[serde(flatten)]
    pub metadata: Metadata,
    pub sealed: Sealed,
    #[serde(default)]
    pub content_hash: String,
    #[serde(default)]
    pub hlc: Option<Hlc>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Document {
    pub schema_version: u8,
    pub kid: String,
    pub vault_salt: String,
    pub kdf: KdfParameters,
    pub wrap_pass: Option<Sealed>,
    pub wrap_recovery: Option<Sealed>,
    #[serde(rename = "wrapCLI")]
    pub wrap_cli: Option<Sealed>,
    pub records: Vec<Record>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}
#[path = "vault_recovery_header.rs"]
mod recovery_header;
pub(crate) use recovery_header::MAX_HEADER_BYTES;
pub use recovery_header::{RecoveryHeader, RecoveryOwner};
#[cfg(any(test, feature = "desktop"))]
#[path = "vault_control.rs"]
pub(crate) mod control;
#[path = "vault_insertion.rs"]
#[cfg(any(test, feature = "desktop"))]
mod insertion;
#[path = "vault_legacy_repair.rs"]
#[cfg(any(test, feature = "desktop"))]
pub(crate) mod legacy_repair;
impl Document {
    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.len() > model::MAX_FILE_BYTES {
            return Err(UNREADABLE);
        }
        let raw: Value = serde_json::from_slice(data).map_err(|_| UNREADABLE)?;
        let records = raw
            .get("records")
            .and_then(Value::as_array)
            .filter(|r| r.len() <= model::MAX_SNIPPETS)
            .ok_or(UNREADABLE)?;
        if records.iter().any(|r| r.get("content").is_some()) {
            return Err(UNREADABLE);
        }
        let mut document: Self = serde_json::from_value(raw).map_err(|_| UNREADABLE)?;
        if document.schema_version != 1
            || document.kid.is_empty()
            || document.kid.len() > 256
            || document.kid.contains('\0')
        {
            return Err(UNREADABLE);
        }
        document.salt()?;
        for envelope in [
            &document.wrap_pass,
            &document.wrap_recovery,
            &document.wrap_cli,
        ]
        .into_iter()
        .flatten()
        {
            envelope.validate()?;
        }
        let mut ids = HashSet::new();
        for record in &mut document.records {
            if !ids.insert(record.metadata.id) {
                return Err(UNREADABLE);
            }
            record.metadata = record.metadata.clone().validate()?;
            record.sealed.validate()?;
            if !record.content_hash.is_empty()
                && (record.content_hash.len() != 32
                    || !record
                        .content_hash
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
            {
                return Err(UNREADABLE);
            }
            if record.hlc.is_none() {
                record.hlc = Some(Hlc::foreign(
                    record.metadata.updated_at.timestamp_millis().max(0) as u64,
                ));
            }
        }
        Ok(document)
    }
    pub fn encode(&self) -> Result<Vec<u8>> {
        let data = serde_json::to_vec_pretty(self).map_err(|_| UNREADABLE)?;
        Self::decode(&data)?;
        Ok(data)
    }
    pub fn salt(&self) -> Result<[u8; 32]> {
        crypto::unb64(&self.vault_salt)?
            .try_into()
            .map_err(|_| UNREADABLE)
    }
    pub fn metadata(&self) -> Vec<Metadata> {
        self.records.iter().map(|r| r.metadata.clone()).collect()
    }
    fn identity(&self) -> Identity {
        Identity {
            kid: self.kid.clone(),
            salt: self.vault_salt.clone(),
            kdf: self.kdf.clone(),
            pass: self.wrap_pass.clone(),
            recovery: self.wrap_recovery.clone(),
            cli: self.wrap_cli.clone(),
        }
    }
    pub(crate) fn same_identity(&self, other: &Self) -> bool {
        self.identity() == other.identity()
    }
    pub fn authenticate(&self, text: &str, recovery: bool) -> Result<Authentication> {
        self.identity().authenticate(text, recovery)
    }
    /// Fresh, one-use export authentication. The key is borrowed only during
    /// encryption and is never installed into or taken from an editor session.
    pub(crate) fn with_backup_key<T>(
        &self,
        text: &str,
        recovery: bool,
        operation: impl FnOnce(&RootKey) -> Result<T>,
    ) -> Result<T> {
        let authentication = self.authenticate(text, recovery)?;
        operation(&authentication.key)
    }
    /// Workers reauthenticate rather than copying the live owner's root key.
    /// The owner installs both results only after validating the same request.
    pub fn prepare_passphrase_change(
        &self,
        credential: &str,
        recovery: bool,
        passphrase: &str,
    ) -> Result<(Authentication, PreparedPassphrase)> {
        if passphrase.chars().count() < 12 {
            return Err(Error("Choose a passphrase of at least 12 characters."));
        }
        let authentication = self.authenticate(credential, recovery)?;
        let (parameters, wrap) =
            crypto::wrap_passphrase(&authentication.key, passphrase, &self.kid)?;
        Ok((
            authentication,
            PreparedPassphrase {
                identity: self.identity(),
                parameters,
                wrap,
            },
        ))
    }
}
#[derive(Clone, PartialEq, Eq)]
struct Identity {
    kid: String,
    salt: String,
    kdf: KdfParameters,
    pass: Option<Sealed>,
    recovery: Option<Sealed>,
    cli: Option<Sealed>,
}
impl Identity {
    fn salt(&self) -> Result<[u8; 32]> {
        crypto::unb64(&self.salt)?
            .try_into()
            .map_err(|_| UNREADABLE)
    }
    fn authenticate(&self, text: &str, recovery: bool) -> Result<Authentication> {
        let key = if recovery {
            let material = crypto::decode_recovery(text)?;
            crypto::unwrap_recovery(
                self.recovery
                    .as_ref()
                    .ok_or(Error("This vault has no recovery wrap."))?,
                &material,
                &self.salt()?,
                &self.kid,
            )?
        } else {
            crypto::unwrap_passphrase(
                &self.kdf,
                self.pass.as_ref().ok_or(Error(
                    "This vault needs its recovery key; it has no passphrase wrap.",
                ))?,
                text,
                &self.kid,
            )?
        };
        Ok(Authentication {
            key,
            identity: self.clone(),
        })
    }
}
pub struct Authentication {
    key: RootKey,
    identity: Identity,
}
#[cfg(feature = "desktop")]
impl Authentication {
    /// Borrow a verified current-vault key for one worker-owned data cycle.
    /// This does not create, install or touch a reveal/editor session.
    pub(crate) fn sync_keyring<'a>(
        &'a self,
        document: &'a Document,
    ) -> Result<crate::materializer::Keyring<'a>> {
        if self.identity != document.identity() {
            return Err(Error(
                "The current vault changed during synchronization authentication.",
            ));
        }
        crate::materializer::Keyring::new(&self.key, document)
            .map_err(|_| Error("The current vault could not authorize synchronization."))
    }
}
pub struct PreparedVault {
    document: Document,
    key: RootKey,
    recovery: Zeroizing<String>,
}
pub struct PreparedPassphrase {
    identity: Identity,
    parameters: KdfParameters,
    wrap: Sealed,
}
/// Proof that an owner-authorized rewrap kept the same root key and scope.
pub struct DraftRewrap {
    old: Identity,
    new: Identity,
}
/// Protected editor state: the retained body is ciphertext, even before Save.
/// Its distinct AAD prevents copying an unsaved draft into an on-disk record.
#[derive(Clone, PartialEq)]
pub struct EncryptedDraft {
    pub metadata: Metadata,
    pub expected: Option<Record>,
    identity: Identity,
    sealed: Sealed,
}
#[cfg(any(test, feature = "desktop"))]
#[path = "vault_edit_history.rs"]
mod edit_history;
#[cfg(any(test, feature = "desktop"))]
pub(crate) use edit_history::{EditBinding, EncryptedEdit};
/// Worker inputs and outputs contain only encrypted bodies and key wraps.
/// They intentionally have no Debug or general serialization implementation.
pub struct DraftRecoveryRequest {
    source: EncryptedDraft,
    target: Identity,
    metadata: Metadata,
    generation: u64,
}
pub struct PreparedDraftRecovery {
    source: EncryptedDraft,
    recovered: EncryptedDraft,
    generation: u64,
}
impl DraftRecoveryRequest {
    pub fn source_has_passphrase(&self) -> bool {
        self.source.identity.pass.is_some()
    }
    pub fn source_has_recovery(&self) -> bool {
        self.source.identity.recovery.is_some()
    }
    pub fn target_has_passphrase(&self) -> bool {
        self.target.pass.is_some()
    }
    pub fn target_has_recovery(&self) -> bool {
        self.target.recovery.is_some()
    }
    pub fn authenticate(
        self,
        source: &str,
        source_recovery: bool,
        target: &str,
        target_recovery: bool,
        check: &dyn Fn() -> Result<()>,
    ) -> Result<PreparedDraftRecovery> {
        check()?;
        if source.len() > 4096 || target.len() > 4096 {
            return Err(Error("Vault credentials must be within the 4 KiB limit."));
        }
        let old = self.source.identity.authenticate(source, source_recovery)?;
        check()?;
        let current = self.target.authenticate(target, target_recovery)?;
        check()?;
        let body = crypto::open_draft(
            &self.source.sealed,
            &old.key,
            &self.source.identity.salt()?,
            &self.source.identity.kid,
            self.source.metadata.id,
        )?;
        if body.len() > model::MAX_BODY_BYTES
            || std::str::from_utf8(&body).is_err()
            || body.contains(&0)
        {
            return Err(Error(
                "The recovered secure draft is not supported UTF-8 text.",
            ));
        }
        let mut metadata = self.metadata;
        metadata.id = Uuid::new_v4();
        metadata.created_at = Utc::now();
        metadata.updated_at = metadata.created_at;
        let recovered = EncryptedDraft {
            sealed: crypto::seal_draft(
                &body,
                &current.key,
                &self.target.salt()?,
                &self.target.kid,
                metadata.id,
            )?,
            metadata,
            expected: None,
            identity: self.target,
        };
        check()?;
        // The two keys and plaintext are dropped before the ciphertext reply.
        Ok(PreparedDraftRecovery {
            source: self.source,
            recovered,
            generation: self.generation,
        })
    }
}

#[cfg(test)]
#[path = "vault_draft_recovery_tests.rs"]
mod draft_recovery_tests;
struct Session {
    key: RootKey,
    identity: Identity,
    started: Duration,
    used: Duration,
}
enum AuthenticatedApply<'a> {
    Restoration(&'a [crate::journal::RestorationGeneration]),
    DeletionDecision(Uuid),
    DeletionRepair(&'a crate::journal::PreservationRepair),
    DeletionGroup(
        Uuid,
        &'a crate::primary::DeletionGroup,
        Option<&'a crate::journal::PreservationRepair>,
    ),
}

/// Workers can prepare creation/authentication, but only the GTK owner may
/// install a result after comparing both the request generation and file identity.
pub struct Vault {
    root: PathBuf,
    pub document: Option<Document>,
    session: Option<Session>,
    generation: u64,
    #[cfg(test)]
    test_now: Option<Duration>,
}
pub fn read_document(root: &Path) -> Result<Option<Document>> {
    let _guard = Library::lock_root(root)?;
    read_document_locked(root)
}
/// Caller holds this root's common process lock.
pub(crate) fn read_document_locked(root: &Path) -> Result<Option<Document>> {
    crate::primary::require_ready(root)?;
    let directory = root.join("Vault");
    if fs::symlink_metadata(&directory).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(Error("Linked vault directories are not supported."));
    }
    model::read_regular(&directory.join("vault.json"))?
        .map(|data| Document::decode(&data))
        .transpose()
}
impl Vault {
    pub fn open(library: &Library) -> Result<Self> {
        let _guard = library.lock()?;
        Self::open_locked(library)
    }
    /// Caller holds this root's common process lock.
    fn open_locked(library: &Library) -> Result<Self> {
        let mut vault = Self {
            root: library.root.clone(),
            document: None,
            session: None,
            generation: 0,
            #[cfg(test)]
            test_now: None,
        };
        vault.reload_locked()?;
        Ok(vault)
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    fn now(&self) -> Duration {
        #[cfg(test)]
        if let Some(now) = self.test_now {
            return now;
        }
        clock::uptime().unwrap_or(Duration::MAX)
    }
    pub fn lock(&mut self) {
        self.session = None;
        self.generation = self.generation.wrapping_add(1);
    }
    pub fn is_unlocked(&mut self) -> bool {
        let now = self.now();
        if now == Duration::MAX
            || self.session.as_ref().is_some_and(|session| {
                now.saturating_sub(session.used) >= IDLE_TIMEOUT
                    || now.saturating_sub(session.started) >= SESSION_TIMEOUT
            })
        {
            self.lock();
        }
        self.session.is_some()
    }
    fn touch(&mut self) -> Result<()> {
        if !self.is_unlocked() {
            return Err(Error("Unlock Secure Snippets to use this entry."));
        }
        let now = self.now();
        if now == Duration::MAX {
            self.lock();
            return Err(Error(
                "The session clock is unavailable. Unlock Secure Snippets again.",
            ));
        }
        self.session.as_mut().expect("unlocked").used = now;
        Ok(())
    }
    pub fn reload(&mut self) -> Result<bool> {
        let result = read_document(&self.root);
        self.accept_document(result)
    }
    fn reload_locked(&mut self) -> Result<bool> {
        let result = read_document_locked(&self.root);
        self.accept_document(result)
    }
    fn accept_document(&mut self, result: Result<Option<Document>>) -> Result<bool> {
        let document = match result {
            Ok(document) => document,
            Err(error) => {
                self.lock();
                return Err(error);
            }
        };
        let changed = document != self.document;
        if self.session.as_ref().is_some_and(|s| {
            document.as_ref().map(Document::identity).as_ref() != Some(&s.identity)
        }) {
            self.lock();
        }
        self.document = document;
        Ok(changed)
    }
    fn write(&self, document: &Document) -> Result<()> {
        let directory = self.root.join("Vault");
        if fs::symlink_metadata(&directory).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(Error("Linked vault directories are not supported."));
        }
        fs::create_dir_all(&directory)
            .and_then(|_| fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)))
            .map_err(|_| Error("The vault directory is unavailable."))?;
        model::atomic_write(&directory.join("vault.json"), &document.encode()?)
    }
    fn install(&mut self, authentication: Authentication) -> Result<()> {
        self.lock();
        let now = self.now();
        if now == Duration::MAX {
            return Err(Error(
                "The session clock is unavailable. Unlock Secure Snippets again.",
            ));
        }
        self.session = Some(Session {
            key: authentication.key,
            identity: authentication.identity,
            started: now,
            used: now,
        });
        Ok(())
    }
    pub fn prepare_create(passphrase: &str) -> Result<PreparedVault> {
        if passphrase.chars().count() < 12 {
            return Err(Error("Choose a passphrase of at least 12 characters."));
        }
        let key = RootKey::generate()?;
        let salt = crypto::random::<32>()?;
        let material = Zeroizing::new(crypto::random::<16>()?);
        let kid = format!("k-{}", Uuid::new_v4().simple());
        let (kdf, wrap) = crypto::wrap_passphrase(&key, passphrase, &kid)?;
        let document = Document {
            schema_version: 1,
            kid: kid.clone(),
            vault_salt: crypto::b64(&salt),
            kdf,
            wrap_pass: Some(wrap),
            wrap_recovery: Some(crypto::wrap_recovery(&key, &material, &salt, &kid)?),
            wrap_cli: None,
            records: vec![],
            extra: BTreeMap::new(),
        };
        Ok(PreparedVault {
            document,
            key,
            recovery: crypto::format_recovery(&material),
        })
    }
    fn same_root(&self, library: &Library) -> Result<()> {
        if self.root != library.root {
            Err(Error(
                "The vault and library belong to different data roots.",
            ))
        } else {
            Ok(())
        }
    }
    pub fn finish_create(
        &mut self,
        library: &Library,
        prepared: PreparedVault,
        generation: u64,
    ) -> Result<Zeroizing<String>> {
        self.same_root(library)?;
        let _guard = library.lock()?;
        self.reload_locked()?;
        if generation != self.generation {
            return Err(EXPIRED);
        }
        if self.document.is_some() {
            return Err(Error(
                "Secure Snippets was already set up. Unlock the existing vault.",
            ));
        }
        self.write(&prepared.document)?;
        self.reload_locked()?;
        self.install(Authentication {
            key: prepared.key,
            identity: prepared.document.identity(),
        })?;
        Ok(prepared.recovery)
    }
    pub fn finish_authentication(
        &mut self,
        authentication: Authentication,
        generation: u64,
    ) -> Result<()> {
        self.reload()?;
        if generation != self.generation
            || self.document.as_ref().map(Document::identity).as_ref()
                != Some(&authentication.identity)
        {
            return Err(EXPIRED);
        }
        self.install(authentication)
    }
    pub fn record(&self, id: Uuid) -> Option<Record> {
        self.document
            .as_ref()?
            .records
            .iter()
            .find(|r| r.metadata.id == id)
            .cloned()
    }
    /// Sync may borrow a live owner's key without copying it or extending the
    /// user's idle deadline. Returned plans contain ciphertext, never the key.
    pub fn prepare_sync_apply(
        &mut self,
        library: &Library,
        journal: &crate::journal::Journal,
        device: &str,
        outcomes: &[crate::merge::Outcome],
        expected: &crate::primary::ReadSet,
    ) -> crate::primary::Result<crate::primary::Prepared> {
        self.prepare_restoration_apply(library, journal, device, outcomes, expected, &[])
    }
    /// Caller holds the common library lock. Borrow only within bounded offline
    /// preparation; reload without re-locking, and never refresh session idle.
    pub(crate) fn with_restoration_keys_locked<T>(
        &mut self,
        library: &Library,
        prepare: impl FnOnce(&crate::materializer::Keyring<'_>) -> T,
    ) -> crate::primary::Result<T> {
        self.same_root(library)?;
        self.reload_locked()?;
        if !self.is_unlocked() {
            return Err(crate::primary::Failure::VaultLocked);
        }
        let document = self
            .document
            .as_ref()
            .ok_or(crate::primary::Failure::IncompatibleVault)?;
        let keys = crate::materializer::Keyring::new(
            &self.session.as_ref().expect("unlocked").key,
            document,
        )?;
        let result = prepare(&keys);
        if !self.is_unlocked() {
            return Err(crate::primary::Failure::VaultLocked);
        }
        Ok(result)
    }
    pub(crate) fn prepare_restoration_apply(
        &mut self,
        library: &Library,
        journal: &crate::journal::Journal,
        device: &str,
        outcomes: &[crate::merge::Outcome],
        expected: &crate::primary::ReadSet,
        history: &[crate::journal::RestorationGeneration],
    ) -> crate::primary::Result<crate::primary::Prepared> {
        self.prepare_authenticated_apply(
            library,
            journal,
            device,
            outcomes,
            expected,
            AuthenticatedApply::Restoration(history),
        )
    }
    pub(crate) fn prepare_deletion_apply(
        &mut self,
        library: &Library,
        journal: &crate::journal::Journal,
        device: &str,
        outcomes: &[crate::merge::Outcome],
        expected: &crate::primary::ReadSet,
        id: Uuid,
    ) -> crate::primary::Result<crate::primary::Prepared> {
        self.prepare_authenticated_apply(
            library,
            journal,
            device,
            outcomes,
            expected,
            AuthenticatedApply::DeletionDecision(id),
        )
    }
    pub(crate) fn prepare_deletion_repair(
        &mut self,
        library: &Library,
        journal: &crate::journal::Journal,
        device: &str,
        outcomes: &[crate::merge::Outcome],
        expected: &crate::primary::ReadSet,
        repair: &crate::journal::PreservationRepair,
    ) -> crate::primary::Result<crate::primary::Prepared> {
        self.prepare_authenticated_apply(
            library,
            journal,
            device,
            outcomes,
            expected,
            AuthenticatedApply::DeletionRepair(repair),
        )
    }
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_deletion_group(
        &mut self,
        library: &Library,
        journal: &crate::journal::Journal,
        device: &str,
        outcomes: &[crate::merge::Outcome],
        expected: &crate::primary::ReadSet,
        id: Uuid,
        group: &crate::primary::DeletionGroup,
        repair: Option<&crate::journal::PreservationRepair>,
    ) -> crate::primary::Result<crate::primary::Prepared> {
        self.prepare_authenticated_apply(
            library,
            journal,
            device,
            outcomes,
            expected,
            AuthenticatedApply::DeletionGroup(id, group, repair),
        )
    }
    fn prepare_authenticated_apply(
        &mut self,
        library: &Library,
        journal: &crate::journal::Journal,
        device: &str,
        outcomes: &[crate::merge::Outcome],
        expected: &crate::primary::ReadSet,
        purpose: AuthenticatedApply<'_>,
    ) -> crate::primary::Result<crate::primary::Prepared> {
        self.same_root(library)?;
        self.reload()?;
        if !self.is_unlocked() {
            return Err(crate::primary::Failure::VaultLocked);
        }
        let document = self
            .document
            .as_ref()
            .ok_or(crate::primary::Failure::IncompatibleVault)?;
        let keys = crate::materializer::Keyring::new(
            &self.session.as_ref().expect("unlocked").key,
            document,
        )?;
        let (history, repair, reviewed_id, group) = match purpose {
            AuthenticatedApply::Restoration(history) => (history, None, None, None),
            AuthenticatedApply::DeletionDecision(id) => (&[][..], None, Some(id), None),
            AuthenticatedApply::DeletionRepair(repair) => {
                (&[][..], Some(repair), Some(repair.id()), None)
            }
            AuthenticatedApply::DeletionGroup(id, group, repair) => {
                (&[][..], repair, Some(id), Some(group))
            }
        };
        if let Some(id) = reviewed_id {
            if group.is_some_and(|group| group.id() != id) {
                return Err(crate::primary::Failure::InvalidState);
            }
            if !journal.preservation_materialized(id)? {
                return Err(crate::primary::Failure::InvalidState);
            }
            crate::materializer::authenticate_generations(
                &journal.preservation_generations(id)?,
                &keys,
            )?;
        }
        let prepared = if let Some(group) = group {
            crate::primary::prepare_deletion_group(
                library, journal, device, outcomes, expected, group, &keys, repair,
            )
        } else if let Some(repair) = repair {
            crate::primary::prepare_deletion_repair(
                library,
                journal,
                device,
                outcomes,
                expected,
                repair,
                Some(&keys),
            )
        } else {
            crate::primary::prepare_restoration(
                library,
                journal,
                device,
                outcomes,
                expected,
                Some(&keys),
                history,
            )
        };
        // A file-lock wait or large validation can outlive the session. No plan
        // from that operation is allowed to escape the expired key owner.
        if !self.is_unlocked() {
            return Err(crate::primary::Failure::VaultLocked);
        }
        prepared
    }
    pub fn body(&mut self, id: Uuid) -> Result<Zeroizing<Vec<u8>>> {
        self.reload()?;
        self.touch()?;
        let document = self.document.as_ref().ok_or(UNREADABLE)?;
        let record = document
            .records
            .iter()
            .find(|r| r.metadata.id == id)
            .ok_or(Error("This secure entry no longer exists."))?;
        let key = &self.session.as_ref().expect("unlocked").key;
        let bytes = crypto::open_record(
            &record.sealed,
            key,
            &document.salt()?,
            &document.kid,
            id,
            false,
        )?;
        if !record.content_hash.is_empty() {
            crypto::verify_hash(&record.content_hash, &bytes, key, &document.salt()?)?;
        }
        if std::str::from_utf8(&bytes).is_err() || bytes.contains(&0) {
            return Err(Error("The secure body is not supported UTF-8 text."));
        }
        Ok(bytes)
    }
    pub fn protect_draft(
        &mut self,
        metadata: Metadata,
        body: &[u8],
        expected: Option<Record>,
    ) -> Result<EncryptedDraft> {
        if body.len() > model::MAX_BODY_BYTES
            || std::str::from_utf8(body).is_err()
            || body.contains(&0)
        {
            return Err(Error(
                "Secure content must be UTF-8 text within the 256 KiB limit.",
            ));
        }
        self.touch()?;
        let document = self.document.as_ref().ok_or(UNREADABLE)?;
        let key = &self.session.as_ref().expect("unlocked").key;
        Ok(EncryptedDraft {
            sealed: crypto::seal_draft(body, key, &document.salt()?, &document.kid, metadata.id)?,
            metadata: metadata.validate()?,
            expected,
            identity: document.identity(),
        })
    }
    pub fn draft_body(
        &mut self,
        draft: &EncryptedDraft,
        interaction: bool,
    ) -> Result<Zeroizing<Vec<u8>>> {
        if interaction {
            self.touch()?;
        } else if !self.is_unlocked() {
            return Err(Error("Unlock Secure Snippets to use this draft."));
        }
        let document = self.document.as_ref().ok_or(UNREADABLE)?;
        if document.identity() != draft.identity {
            return Err(Error(
                "This encrypted draft belongs to the previous vault. Recover it before editing.",
            ));
        }
        crypto::open_draft(
            &draft.sealed,
            &self.session.as_ref().expect("unlocked").key,
            &document.salt()?,
            &document.kid,
            draft.metadata.id,
        )
    }
    pub fn draft_is_foreign(&self, draft: &EncryptedDraft) -> bool {
        self.document.as_ref().map(Document::identity).as_ref() != Some(&draft.identity)
    }
    pub fn prepare_draft_recovery(
        &mut self,
        draft: &EncryptedDraft,
        metadata: Metadata,
    ) -> Result<DraftRecoveryRequest> {
        self.reload()?;
        if !self.is_unlocked() {
            return Err(Error(
                "Unlock the current vault before recovering the previous draft.",
            ));
        }
        if !self.draft_is_foreign(draft) || metadata.id != draft.metadata.id {
            return Err(EXPIRED);
        }
        Ok(DraftRecoveryRequest {
            source: draft.clone(),
            target: self.document.as_ref().ok_or(UNREADABLE)?.identity(),
            metadata: metadata.validate()?,
            generation: self.generation,
        })
    }
    pub fn finish_draft_recovery(
        &mut self,
        draft: &mut EncryptedDraft,
        prepared: PreparedDraftRecovery,
    ) -> Result<()> {
        self.reload()?;
        if self.generation != prepared.generation
            || !self.is_unlocked()
            || *draft != prepared.source
            || self.document.as_ref().map(Document::identity).as_ref()
                != Some(&prepared.recovered.identity)
        {
            return Err(EXPIRED);
        }
        // Confirm with the current live owner's key without extending its idle
        // deadline, then replace only the volatile draft. Explicit Save is separate.
        let _body = self.draft_body(&prepared.recovered, false)?;
        *draft = prepared.recovered;
        Ok(())
    }
    pub fn save(
        &mut self,
        library: &Library,
        metadata: Metadata,
        body: &[u8],
        expected: Option<&Record>,
    ) -> Result<()> {
        self.same_root(library)?;
        if body.len() > model::MAX_BODY_BYTES
            || std::str::from_utf8(body).is_err()
            || body.contains(&0)
        {
            return Err(Error(
                "Secure content must be UTF-8 text within the 256 KiB limit.",
            ));
        }
        let mut metadata = metadata.validate()?;
        let _guard = library.lock()?;
        self.save_locked(library, &mut metadata, body, expected, &|| Ok(()))
    }
    /// Caller holds the common lock. A fresh control owner uses the same encrypted writer.
    fn save_locked(
        &mut self,
        library: &Library,
        metadata: &mut Metadata,
        body: &[u8],
        expected: Option<&Record>,
        authorize: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        self.reload_locked()?;
        self.touch()?;
        let previous = self.record(metadata.id);
        if previous.as_ref() != expected {
            return Err(Error(
                "This secure entry changed outside the editor. Reload it before saving.",
            ));
        }
        let ordinary = library.read_locked()?.0;
        if ordinary.iter().any(|s| s.id == metadata.id) {
            return Err(Error("This identifier belongs to an ordinary entry."));
        }
        if !metadata.keyword.is_empty()
            && (ordinary
                .iter()
                .any(|s| model::folded(&s.keyword) == model::folded(&metadata.keyword))
                || self
                    .document
                    .as_ref()
                    .ok_or(UNREADABLE)?
                    .records
                    .iter()
                    .any(|r| {
                        r.metadata.id != metadata.id
                            && model::folded(&r.metadata.keyword)
                                == model::folded(&metadata.keyword)
                    }))
        {
            return Err(Error("This keyword already belongs to another snippet."));
        }
        metadata.updated_at = Utc::now();
        let hlc = clock::stamp(
            &self.root,
            previous.as_ref().and_then(|r| r.hlc.as_ref()),
            metadata.updated_at.timestamp_millis().max(0) as u64,
        )?;
        let mut document = self.document.clone().ok_or(UNREADABLE)?;
        let key = &self.session.as_ref().expect("unlocked").key;
        let record = Record {
            sealed: crypto::seal_record(
                body,
                key,
                &document.salt()?,
                &document.kid,
                metadata.id,
                false,
            )?,
            content_hash: crypto::content_hash(body, key, &document.salt()?),
            metadata: metadata.clone(),
            hlc: Some(hlc),
            extra: previous.map(|r| r.extra).unwrap_or_default(),
        };
        if let Some(existing) = document
            .records
            .iter_mut()
            .find(|r| r.metadata.id == record.metadata.id)
        {
            *existing = record;
        } else {
            document.records.push(record);
        }
        authorize()?;
        self.write(&document)?;
        self.reload_locked()?;
        Ok(())
    }
    pub fn delete(&mut self, library: &Library, id: Uuid, expected: &Record) -> Result<()> {
        self.same_root(library)?;
        let _guard = library.lock()?;
        self.reload_locked()?;
        self.touch()?;
        if self.record(id).as_ref() != Some(expected) {
            return Err(Error(
                "This secure entry changed outside the editor. Reload it before deleting.",
            ));
        }
        let mut document = self.document.clone().ok_or(UNREADABLE)?;
        document.records.retain(|r| r.metadata.id != id);
        self.write(&document)?;
        self.reload_locked()?;
        Ok(())
    }
    pub fn finish_passphrase(
        &mut self,
        library: &Library,
        prepared: PreparedPassphrase,
        generation: u64,
    ) -> Result<DraftRewrap> {
        self.same_root(library)?;
        let _guard = library.lock()?;
        self.reload_locked()?;
        self.touch()?;
        if generation != self.generation
            || self.document.as_ref().map(Document::identity).as_ref() != Some(&prepared.identity)
        {
            return Err(EXPIRED);
        }
        let mut document = self.document.clone().ok_or(UNREADABLE)?;
        let extra = document.kdf.extra;
        document.kdf = prepared.parameters;
        document.kdf.extra.extend(extra);
        document.wrap_pass = Some(prepared.wrap);
        self.write(&document)?;
        let key = self.session.take().expect("unlocked").key;
        self.reload_locked()?;
        self.install(Authentication {
            key,
            identity: document.identity(),
        })?;
        Ok(DraftRewrap {
            old: prepared.identity,
            new: document.identity(),
        })
    }
    pub fn rebind_draft(&mut self, draft: &mut EncryptedDraft, rewrap: &DraftRewrap) -> Result<()> {
        self.touch()?;
        if draft.identity != rewrap.old
            || self.document.as_ref().map(Document::identity).as_ref() != Some(&rewrap.new)
        {
            return Err(Error(
                "This draft belongs to a different vault and cannot follow this passphrase change.",
            ));
        }
        draft.identity = rewrap.new.clone();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    fn fixture() -> Document {
        let value: Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        Document::decode(&serde_json::to_vec(&value["document"]).unwrap()).unwrap()
    }
    pub(super) fn setup() -> (tempfile::TempDir, Library, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let library = Library::open(directory.path().into()).unwrap();
        let vault_dir = directory.path().join("Vault");
        fs::create_dir(&vault_dir).unwrap();
        model::atomic_write(&vault_dir.join("vault.json"), &fixture().encode().unwrap()).unwrap();
        let mut vault = Vault::open(&library).unwrap();
        // Public fictional fixture key. Authentication is separately verified.
        let authentication = Authentication {
            key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
            identity: fixture().identity(),
        };
        vault
            .finish_authentication(authentication, vault.generation())
            .unwrap();
        (directory, library, vault)
    }
    #[test]
    fn fresh_open_neither_authors_a_vault_nor_creates_an_identity() {
        let directory = tempfile::tempdir().unwrap();
        let library = Library::open(directory.path().into()).unwrap();
        let mut vault = Vault::open(&library).unwrap();
        assert!(vault.document.is_none() && !vault.is_unlocked());
        assert!(
            !directory.path().join("Vault").exists()
                && !directory.path().join("device.json").exists()
        );
    }
    #[test]
    fn sync_key_borrow_does_not_extend_idle_and_expired_owner_refuses_a_plan() {
        let (temp, library, mut vault) = setup();
        let used = vault.session.as_ref().unwrap().used;
        vault.test_now = Some(used + IDLE_TIMEOUT - Duration::from_secs(1));
        let journal = crate::journal::Journal::new(crate::journal::Scope {
            membership: crate::cloud::Binding::from_checkpoint([0x33; 32]),
            dataset: crate::cloud::Binding::from_checkpoint([0x44; 32]),
        });
        let plan = vault
            .prepare_sync_apply(&library, &journal, "11111111", &[], &BTreeMap::new())
            .unwrap();
        assert!(plan.changed_ids.is_empty());
        assert_eq!(vault.session.as_ref().unwrap().used, used);
        vault.test_now = Some(used + IDLE_TIMEOUT);
        assert!(matches!(
            vault.prepare_sync_apply(&library, &journal, "11111111", &[], &BTreeMap::new()),
            Err(crate::primary::Failure::VaultLocked)
        ));
        assert!(vault.session.is_none() && !temp.path().join("Sync").exists());
    }
    #[test]
    fn restoration_data_borrow_keeps_idle_deadline_and_rejects_expired_or_replaced_keys() {
        let (temp, library, mut vault) = setup();
        let used = vault.session.as_ref().unwrap().used;
        vault.test_now = Some(used + IDLE_TIMEOUT - Duration::from_secs(1));
        let guard = library.lock().unwrap();
        assert!(
            vault
                .with_restoration_keys_locked(&library, |_| true)
                .unwrap()
        );
        assert_eq!(vault.session.as_ref().unwrap().used, used);
        vault.test_now = Some(used + IDLE_TIMEOUT);
        assert!(matches!(
            vault.with_restoration_keys_locked(&library, |_| panic!(
                "Expired key must not be borrowed"
            )),
            Err(crate::primary::Failure::VaultLocked)
        ));
        drop(guard);
        assert!(vault.session.is_none() && !temp.path().join("Sync").exists());
        let (_temp, library, mut vault) = setup();
        let mut replacement = fixture();
        replacement.wrap_pass = replacement.wrap_recovery.clone();
        model::atomic_write(
            &library.root.join("Vault/vault.json"),
            &replacement.encode().unwrap(),
        )
        .unwrap();
        let _guard = library.lock().unwrap();
        assert!(matches!(
            vault.with_restoration_keys_locked(&library, |_| panic!(
                "Replaced key must not be borrowed"
            )),
            Err(crate::primary::Failure::VaultLocked)
        ));
        assert!(vault.session.is_none());
    }
    #[test]
    fn deletion_keep_borrow_does_not_extend_idle_and_expired_owner_refuses_the_review() {
        let (temp, library, mut vault) = setup();
        let used = vault.session.as_ref().unwrap().used;
        vault.test_now = Some(used + IDLE_TIMEOUT - Duration::from_secs(1));
        let journal = crate::journal::Journal::new(crate::journal::Scope {
            membership: crate::cloud::Binding::from_checkpoint([0x33; 32]),
            dataset: crate::cloud::Binding::from_checkpoint([0x44; 32]),
        });
        let plan = vault
            .prepare_deletion_apply(
                &library,
                &journal,
                "11111111",
                &[],
                &BTreeMap::new(),
                Uuid::from_u128(7),
            )
            .unwrap();
        assert!(plan.changed_ids.is_empty());
        assert_eq!(vault.session.as_ref().unwrap().used, used);
        vault.test_now = Some(used + IDLE_TIMEOUT);
        assert!(matches!(
            vault.prepare_deletion_apply(
                &library,
                &journal,
                "11111111",
                &[],
                &BTreeMap::new(),
                Uuid::from_u128(7)
            ),
            Err(crate::primary::Failure::VaultLocked)
        ));
        assert!(vault.session.is_none() && !temp.path().join("Sync").exists());
    }
    #[test]
    fn sync_key_borrow_refuses_replaced_vault_and_discards_the_old_session() {
        let (temp, library, mut vault) = setup();
        let mut replacement = fixture();
        replacement.wrap_pass = replacement.wrap_recovery.clone();
        model::atomic_write(
            &temp.path().join("Vault/vault.json"),
            &replacement.encode().unwrap(),
        )
        .unwrap();
        let journal = crate::journal::Journal::new(crate::journal::Scope {
            membership: crate::cloud::Binding::from_checkpoint([0x33; 32]),
            dataset: crate::cloud::Binding::from_checkpoint([0x44; 32]),
        });
        assert!(matches!(
            vault.prepare_sync_apply(&library, &journal, "11111111", &[], &BTreeMap::new()),
            Err(crate::primary::Failure::VaultLocked)
        ));
        assert!(vault.session.is_none() && !temp.path().join("Sync").exists());
    }
    #[test]
    fn ciphertext_fixture_uses_iso_dates_and_round_trips_unknown_fields() {
        let mut document = fixture();
        document
            .extra
            .insert("futureDocument".into(), serde_json::json!({"enabled":true}));
        document
            .kdf
            .extra
            .insert("futureKdf".into(), serde_json::json!(123));
        document.records[0]
            .extra
            .insert("futureRecord".into(), serde_json::json!([1, 2, 3]));
        let encoded = document.encode().unwrap();
        let decoded = Document::decode(&encoded).unwrap();
        assert!(decoded == document);
        let raw: Value = serde_json::from_slice(&encoded).unwrap();
        assert!(
            raw["records"][0]["createdAt"] == "2026-09-30T10:00:00.000Z"
                && raw["records"][0].get("content").is_none()
        );
        assert!(raw["wrapCLI"].is_null());
    }
    #[test]
    fn malformed_versions_types_duplicates_and_plaintext_escape_fail_closed() {
        let original = serde_json::to_value(fixture()).unwrap();
        for (field, value) in [
            ("schemaVersion", Value::Bool(true)),
            ("schemaVersion", serde_json::json!(2)),
            ("vaultSalt", serde_json::json!("AAAA")),
            ("records", serde_json::json!(null)),
        ] {
            let mut changed = original.clone();
            changed[field] = value;
            assert!(Document::decode(&serde_json::to_vec(&changed).unwrap()).is_err());
        }
        let mut changed = original.clone();
        changed["records"][0]["content"] = serde_json::json!("Must never be accepted");
        assert!(Document::decode(&serde_json::to_vec(&changed).unwrap()).is_err());
        let mut changed = original.clone();
        changed["records"][0]["createdAt"] = serde_json::json!(800000000.0);
        assert!(Document::decode(&serde_json::to_vec(&changed).unwrap()).is_err());
        let mut changed = original.clone();
        changed["records"] = serde_json::json!([original["records"][0], original["records"][0]]);
        assert!(Document::decode(&serde_json::to_vec(&changed).unwrap()).is_err());
        assert!(Document::decode(&vec![b' '; model::MAX_FILE_BYTES + 1]).is_err());
    }
    #[test]
    fn authenticated_body_never_enters_plaintext_library_metadata_or_exports() {
        let (directory, library, mut vault) = setup();
        let id = vault.document.as_ref().unwrap().records[0].metadata.id;
        let body = vault.body(id).unwrap();
        assert!(*body == "Fictional secret 🦀\n".as_bytes());
        assert!(
            library.secure_metadata().unwrap()[0]
                .shell()
                .content
                .is_empty()
        );
        assert!(library.snippets.is_empty() && !library.path().exists());
        let raw = fs::read(directory.path().join("Vault/vault.json")).unwrap();
        assert!(!String::from_utf8_lossy(&raw).contains("Fictional secret"));
        let export = model::encode_library(&library.snippets, true).unwrap();
        assert!(!String::from_utf8_lossy(&export).contains("Fictional secret"));
        vault.lock();
        assert!(vault.body(id).is_err());
    }
    #[test]
    fn recovery_authenticates_and_cancelled_or_replaced_requests_cannot_unlock() {
        let (_directory, _library, mut vault) = setup();
        vault.lock();
        let recovery = crypto::format_recovery(&[0x66; 16]);
        let result = vault
            .document
            .as_ref()
            .unwrap()
            .authenticate(&recovery, true)
            .unwrap();
        let generation = vault.generation();
        vault.lock();
        assert!(vault.finish_authentication(result, generation).is_err());
        assert!(!vault.is_unlocked());
        let result = vault
            .document
            .as_ref()
            .unwrap()
            .authenticate(&recovery, true)
            .unwrap();
        let generation = vault.generation();
        let mut replaced = fixture();
        replaced.kid = "replacement".into();
        model::atomic_write(
            &vault.root.join("Vault/vault.json"),
            &replaced.encode().unwrap(),
        )
        .unwrap();
        assert!(vault.finish_authentication(result, generation).is_err());
        assert!(!vault.is_unlocked());
    }
    #[test]
    fn metadata_changes_do_not_erase_a_session_but_key_changes_and_corruption_do() {
        let (_directory, _library, mut vault) = setup();
        let mut document = fixture();
        document.records[0].metadata.name = "Changed fixture".into();
        model::atomic_write(
            &vault.root.join("Vault/vault.json"),
            &document.encode().unwrap(),
        )
        .unwrap();
        vault.reload().unwrap();
        assert!(vault.is_unlocked());
        document.kdf.iterations += 1;
        model::atomic_write(
            &vault.root.join("Vault/vault.json"),
            &document.encode().unwrap(),
        )
        .unwrap();
        vault.reload().unwrap();
        assert!(!vault.is_unlocked());
        let (_directory, _library, mut vault) = setup();
        fs::write(vault.root.join("Vault/vault.json"), b"{truncated").unwrap();
        assert!(vault.reload().is_err());
        assert!(!vault.is_unlocked());
    }
    #[test]
    fn idle_and_absolute_timeouts_expire_keys_and_rendering_does_not_extend_idle() {
        let (_directory, _library, mut vault) = setup();
        vault.test_now = Some(Duration::ZERO);
        let authentication = Authentication {
            key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
            identity: fixture().identity(),
        };
        vault.install(authentication).unwrap();
        let metadata = vault.document.as_ref().unwrap().records[0].metadata.clone();
        let draft = vault
            .protect_draft(metadata, b"Unsaved fictional draft", None)
            .unwrap();
        vault.test_now = Some(Duration::from_secs(299));
        assert!(vault.draft_body(&draft, false).is_ok());
        vault.test_now = Some(Duration::from_secs(300));
        assert!(!vault.is_unlocked());
        assert!(vault.draft_body(&draft, false).is_err());
        let authentication = Authentication {
            key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
            identity: fixture().identity(),
        };
        vault.test_now = Some(Duration::ZERO);
        vault.install(authentication).unwrap();
        for tick in (100..1800).step_by(100) {
            vault.test_now = Some(Duration::from_secs(tick));
            assert!(vault.draft_body(&draft, true).is_ok());
        }
        vault.test_now = Some(Duration::from_secs(1800));
        assert!(!vault.is_unlocked());
    }
    #[test]
    fn encrypted_drafts_survive_lock_and_cannot_be_lifted_into_disk_records() {
        let (_directory, _library, mut vault) = setup();
        let record = vault.document.as_ref().unwrap().records[0].clone();
        let draft = vault
            .protect_draft(
                record.metadata.clone(),
                b"Unsaved fictional draft",
                Some(record.clone()),
            )
            .unwrap();
        assert!(!draft.sealed.text().contains("Unsaved fictional draft"));
        let document = vault.document.as_ref().unwrap();
        assert!(
            crypto::open_record(
                &draft.sealed,
                &vault.session.as_ref().unwrap().key,
                &document.salt().unwrap(),
                &document.kid,
                record.metadata.id,
                false
            )
            .is_err()
        );
        vault.lock();
        assert!(vault.draft_body(&draft, true).is_err());
        vault
            .install(Authentication {
                key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
                identity: fixture().identity(),
            })
            .unwrap();
        assert!(&*vault.draft_body(&draft, false).unwrap() == b"Unsaved fictional draft");
    }
    #[test]
    fn writers_merge_unrelated_secure_changes_and_refuse_same_record_cas_conflicts() {
        let (_directory, library, mut one) = setup();
        let mut two = Vault::open(&library).unwrap();
        two.install(Authentication {
            key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
            identity: fixture().identity(),
        })
        .unwrap();
        let original = one.document.as_ref().unwrap().records[0].clone();
        let mut unrelated = Metadata::new();
        unrelated.keyword = "unrelated".into();
        let unrelated_id = unrelated.id;
        two.save(&library, unrelated, b"Other fictional secret", None)
            .unwrap();
        one.save(
            &library,
            original.metadata.clone(),
            b"Updated fictional secret",
            Some(&original),
        )
        .unwrap();
        assert!(one.record(unrelated_id).is_some());
        let before = fs::read(one.root.join("Vault/vault.json")).unwrap();
        assert!(
            two.save(
                &library,
                original.metadata.clone(),
                b"Stale draft",
                Some(&original)
            )
            .is_err()
        );
        assert!(
            two.delete(&library, original.metadata.id, &original)
                .is_err()
        );
        assert!(fs::read(one.root.join("Vault/vault.json")).unwrap() == before);
    }
    #[test]
    fn cross_store_keywords_ids_permissions_and_keyed_hash_tampering_are_guarded() {
        let (_directory, mut library, mut vault) = setup();
        let record = vault.document.as_ref().unwrap().records[0].clone();
        let mut ordinary = Snippet::new("Ordinary fixture", "Public");
        ordinary.keyword = "public".into();
        library.save(ordinary.clone(), None).unwrap();
        let mut secure = Metadata::new();
        secure.keyword = "PUBLIC".into();
        assert!(
            vault
                .save(&library, secure, b"Fictional secret", None)
                .is_err()
        );
        let mut secure = Metadata::new();
        secure.id = ordinary.id;
        assert!(
            vault
                .save(&library, secure, b"Fictional secret", None)
                .is_err()
        );
        vault
            .save(
                &library,
                record.metadata.clone(),
                b"Replacement fictional secret",
                Some(&record),
            )
            .unwrap();
        assert!(
            fs::metadata(vault.root.join("Vault"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777
                == 0o700
        );
        assert!(
            fs::metadata(vault.root.join("Vault/vault.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777
                == 0o600
        );
        assert!(
            fs::metadata(vault.root.join("device.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777
                == 0o600
        );
        let mut changed = vault.document.clone().unwrap();
        changed.records[0].content_hash = "00000000000000000000000000000000".into();
        model::atomic_write(
            &vault.root.join("Vault/vault.json"),
            &changed.encode().unwrap(),
        )
        .unwrap();
        assert!(vault.body(record.metadata.id).is_err());
    }
    #[test]
    fn passphrase_change_retains_recovery_unknown_keys_and_bodies() {
        let (_directory, library, mut vault) = setup();
        let mut document = fixture();
        document
            .kdf
            .extra
            .insert("future".into(), serde_json::json!(true));
        document
            .extra
            .insert("future".into(), serde_json::json!([1]));
        model::atomic_write(
            &vault.root.join("Vault/vault.json"),
            &document.encode().unwrap(),
        )
        .unwrap();
        vault.reload().unwrap();
        vault
            .install(Authentication {
                key: RootKey::from_bytes(&[0x11; 32]).unwrap(),
                identity: document.identity(),
            })
            .unwrap();
        let record = document.records[0].clone();
        let mut draft = vault
            .protect_draft(
                record.metadata.clone(),
                b"Unsaved public fixture",
                Some(record),
            )
            .unwrap();
        let (authentication, prepared) = document
            .prepare_passphrase_change(
                "Café public fixture",
                false,
                "New public fixture passphrase",
            )
            .unwrap();
        vault
            .finish_authentication(authentication, vault.generation())
            .unwrap();
        let generation = vault.generation();
        let transition = vault
            .finish_passphrase(&library, prepared, generation)
            .unwrap();
        assert!(vault.draft_body(&draft, false).is_err());
        vault.rebind_draft(&mut draft, &transition).unwrap();
        assert!(*vault.draft_body(&draft, false).unwrap() == b"Unsaved public fixture");
        let document = vault.document.as_ref().unwrap();
        assert!(
            document.kdf.iterations == crypto::PASSPHRASE_ITERATIONS
                && document.kdf.extra.get("future") == Some(&Value::Bool(true))
        );
        assert!(
            document
                .authenticate("New public fixture passphrase", false)
                .is_ok()
        );
        assert!(document.authenticate("Café public fixture", false).is_err());
        assert!(
            document
                .authenticate(&crypto::format_recovery(&[0x66; 16]), true)
                .is_ok()
        );
        let id = document.records[0].metadata.id;
        assert!(*vault.body(id).unwrap() == "Fictional secret 🦀\n".as_bytes());
    }
    #[test]
    fn linked_vault_files_and_directories_never_replace_external_data() {
        let (_directory, library, mut vault) = setup();
        let outside = vault.root.join("outside.json");
        fs::write(&outside, b"[]").unwrap();
        fs::remove_file(vault.root.join("Vault/vault.json")).unwrap();
        symlink(&outside, vault.root.join("Vault/vault.json")).unwrap();
        assert!(vault.reload().is_err());
        assert!(library.secure_metadata().is_err());
        assert!(fs::read(&outside).unwrap() == b"[]");
        fs::remove_file(vault.root.join("Vault/vault.json")).unwrap();
        fs::remove_dir(vault.root.join("Vault")).unwrap();
        let outside_dir = vault.root.join("outside-dir");
        fs::create_dir(&outside_dir).unwrap();
        symlink(&outside_dir, vault.root.join("Vault")).unwrap();
        assert!(vault.reload().is_err() && library.secure_metadata().is_err());
        assert!(fs::read_dir(outside_dir).unwrap().next().is_none());
    }
}
