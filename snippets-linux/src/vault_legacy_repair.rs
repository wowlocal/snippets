//! Fresh authentication repairs only an exact live legacy record's missing MAC.
//! Record seals and opaque conflict originals are never rewritten or guessed.
use super::*;
use crate::{
    desktop::{SessionState, SessionWitness},
    secure_insertion::Source,
};
use std::io::Write;
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::SystemTime,
};
const STOPPED: Error = Error(
    "Secure metadata repair expired or was cancelled. Re-read the saved entry before trying again.",
);
const CHANGED: Error =
    Error("The saved library or vault changed. Re-read it before repairing secure metadata.");
const COMPLETE: Error = Error("This saved secure entry already has a content hash.");

#[derive(Clone)]
pub(crate) struct Authorization {
    cancelled: Arc<AtomicBool>,
    witness: SessionWitness,
    epoch: u64,
    started: Duration,
    wall: SystemTime,
}
impl Authorization {
    pub fn new(witness: SessionWitness) -> Result<Self> {
        let (state, epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            return Err(STOPPED);
        }
        Ok(Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            witness,
            epoch,
            started: clock::uptime().ok_or(STOPPED)?,
            wall: SystemTime::now(),
        })
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn validate(&self) -> Result<()> {
        self.validate_at(clock::uptime().ok_or(STOPPED)?, SystemTime::now())
    }
    fn validate_at(&self, now: Duration, wall: SystemTime) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire)
            || now < self.started
            || now - self.started >= Duration::from_secs(120)
            || wall
                .duration_since(self.wall)
                .map_or(true, |elapsed| elapsed >= Duration::from_secs(120))
            || self.witness.snapshot() != (SessionState::Unlocked, self.epoch)
        {
            return Err(STOPPED);
        }
        Ok(())
    }
}
/// Captured before credentials; no keys, host text or generic serialization.
pub(crate) struct Request {
    root: PathBuf,
    source: Source,
    document: Document,
    before_bytes: Zeroizing<Vec<u8>>,
    index: usize,
    authorization: Authorization,
}
pub(crate) struct Prepared {
    request: Request,
    hash: String,
}
pub(crate) struct Receipt {
    root: PathBuf,
    identity: Identity,
    before: Record,
    after: Record,
}
fn legacy(record: &Record, document: &Document) -> Result<crate::wire::Envelope> {
    if !record.content_hash.is_empty() {
        return Err(COMPLETE);
    }
    if record
        .extra
        .get("vaultKID")
        .is_some_and(|value| value.as_str() != Some(document.kid.as_str()))
    {
        return Err(Error(
            "The saved secure entry carries a different or invalid vault stamp.",
        ));
    }
    // Only own absent metadata is repairable. The frozen projection validates
    // all reserved v1 carriers and copy identities without changing originals.
    let one = Document {
        schema_version: document.schema_version,
        kid: document.kid.clone(),
        vault_salt: document.vault_salt.clone(),
        kdf: document.kdf.clone(),
        wrap_pass: document.wrap_pass.clone(),
        wrap_recovery: document.wrap_recovery.clone(),
        wrap_cli: document.wrap_cli.clone(),
        records: vec![record.clone()],
        extra: document.extra.clone(),
    };
    // A valid syntax-only preview origin is never stored or offered to sync.
    let mut view = crate::projection::current(
        &[],
        Some(&one),
        "11111111",
        &BTreeMap::new(),
        &BTreeMap::new(),
    )?;
    if crate::merge::has_unknown_version(&view[&record.metadata.id]) {
        return Err(Error(
            "This secure entry has conflict metadata that requires a newer implementation. It cannot be repaired here.",
        ));
    }
    view.remove(&record.metadata.id).ok_or(CHANGED)
}
impl Request {
    pub fn capture(
        root: PathBuf,
        document: Document,
        expected: Record,
        authorization: Authorization,
    ) -> Result<Self> {
        authorization.validate()?;
        legacy(&expected, &document)?;
        let library = Library::prepare(root.clone())?;
        let _guard = library.try_lock()?;
        authorization.validate()?;
        let current = read_document_locked(&root)?.ok_or(CHANGED)?;
        if current != document {
            return Err(CHANGED);
        }
        let index = document
            .records
            .iter()
            .position(|record| *record == expected)
            .ok_or(CHANGED)?;
        if library
            .read_locked()?
            .0
            .iter()
            .any(|record| record.id == expected.metadata.id)
        {
            return Err(CHANGED);
        }
        let (source, bytes) = Source::prove(&root).map_err(|_| CHANGED)?;
        if Document::decode(&bytes)? != document {
            return Err(CHANGED);
        }
        authorization.validate()?;
        Ok(Self {
            root,
            source,
            document,
            before_bytes: bytes,
            index,
            authorization,
        })
    }
    pub fn authenticate(self, credential: &str, recovery: bool) -> Result<Prepared> {
        self.authorization.validate()?;
        if !(1..=4096).contains(&credential.len()) {
            return Err(Error("Vault credentials must be within the 4 KiB limit."));
        }
        let authentication = self.document.authenticate(credential, recovery)?;
        self.prepare(authentication)
    }
    fn prepare(self, authentication: Authentication) -> Result<Prepared> {
        self.authorization.validate()?;
        if authentication.identity != self.document.identity() {
            return Err(CHANGED);
        }
        self.source.authenticate_current().map_err(|_| CHANGED)?;
        let record = &self.document.records[self.index];
        let preview = legacy(record, &self.document)?;
        let keyring = crate::materializer::Keyring::new(&authentication.key, &self.document)
            .map_err(|_| CHANGED)?;
        crate::materializer::authenticate_carriers(&preview, &keyring, &|| {
            self.authorization.validate()
        })
        .map_err(|_| CHANGED)?;
        let salt = self.document.salt()?;
        let body = crypto::open_record(
            &record.sealed,
            &authentication.key,
            &salt,
            &self.document.kid,
            record.metadata.id,
            false,
        )?;
        if std::str::from_utf8(&body).is_err() || body.contains(&0) {
            return Err(Error("The secure body is not supported UTF-8 text."));
        }
        if let Some(hash) = record.extra.get("vaultContentHash") {
            crypto::verify_hash(
                hash.as_str().ok_or(CHANGED)?,
                &body,
                &authentication.key,
                &salt,
            )?;
        }
        let hash = crypto::content_hash(&body, &authentication.key, &salt);
        // All plaintext/key owners are destroyed before the worker can reply.
        drop(body);
        drop(authentication);
        self.authorization.validate()?;
        self.source.authenticate_current().map_err(|_| CHANGED)?;
        Ok(Prepared {
            request: self,
            hash,
        })
    }
}
impl Prepared {
    /// Consumes the owner even on refusal. No cached reveal/session key is used.
    pub fn commit(self) -> Result<Receipt> {
        self.commit_checked(&|| Ok(()))
    }
    fn commit_checked(self, before_publish: &dyn Fn() -> Result<()>) -> Result<Receipt> {
        let request = self.request;
        request.authorization.validate()?;
        let library = Library::prepare(request.root.clone())?;
        let _guard = library.try_lock()?;
        request.authorization.validate()?;
        if read_document_locked(&request.root)?.as_ref() != Some(&request.document)
            || library
                .read_locked()?
                .0
                .iter()
                .any(|record| record.id == request.document.records[request.index].metadata.id)
        {
            return Err(CHANGED);
        }
        request.source.authenticate_current().map_err(|_| CHANGED)?;
        let before = request.document.records[request.index].clone();
        let mut after = before.clone();
        after.content_hash = self.hash;
        // Validate size and all preserved encrypted record extensions before
        // reserving a clock. An unused clock after cancellation is only a gap.
        repaired_bytes(&request.before_bytes, request.index, &after)?;
        request.authorization.validate()?;
        after.hlc = Some(clock::stamp(
            &request.root,
            before.hlc.as_ref(),
            Utc::now().timestamp_millis().max(0) as u64,
        )?);
        let bytes = repaired_bytes(&request.before_bytes, request.index, &after)?;
        request.source.authenticate_current().map_err(|_| CHANGED)?;
        request.authorization.validate()?;
        let directory = request.root.join("Vault");
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| Error("The repaired vault could not be saved."))?;
        let mut temporary = tempfile::Builder::new()
            .prefix(".snippets-vault-repair-")
            .tempfile_in(&directory)
            .map_err(|_| Error("The repaired vault could not be saved."))?;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|_| Error("The repaired vault could not be saved."))?;
        temporary
            .write_all(&bytes)
            .and_then(|_| temporary.as_file().sync_all())
            .map_err(|_| Error("The repaired vault could not be saved."))?;
        before_publish()?;
        crate::primary::require_ready(&request.root)?;
        request.source.authenticate_current().map_err(|_| CHANGED)?;
        request.authorization.validate()?;
        temporary
            .persist(directory.join("vault.json"))
            .map_err(|_| Error("The repaired vault could not be saved."))?;
        fs::File::open(&directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| {
                Error(
                    "Repair publication is uncertain. Re-read the saved entry before trying again.",
                )
            })?;
        Ok(Receipt {
            root: request.root,
            identity: request.document.identity(),
            before,
            after,
        })
    }
}
fn repaired_bytes(before: &[u8], index: usize, after: &Record) -> Result<Zeroizing<Vec<u8>>> {
    let mut raw: Value = serde_json::from_slice(before).map_err(|_| CHANGED)?;
    let record = raw
        .get_mut("records")
        .and_then(Value::as_array_mut)
        .and_then(|records| records.get_mut(index))
        .and_then(Value::as_object_mut)
        .ok_or(CHANGED)?;
    record.insert(
        "contentHash".into(),
        Value::String(after.content_hash.clone()),
    );
    record.insert(
        "hlc".into(),
        Value::String(after.hlc.as_ref().ok_or(CHANGED)?.text()),
    );
    let bytes = Zeroizing::new(serde_json::to_vec(&raw).map_err(|_| CHANGED)?);
    Document::decode(&bytes)?;
    Ok(bytes)
}
impl Receipt {
    pub fn id(&self) -> Uuid {
        self.after.metadata.id
    }
    /// Update a clean encrypted draft's saved ancestor without opening its body
    /// or extending the live owner's idle/reveal capability.
    pub(crate) fn adopt(&self, vault: &mut Vault, draft: &mut EncryptedDraft) -> Result<()> {
        if vault.root != self.root {
            return Err(CHANGED);
        }
        vault.reload()?;
        if vault.document.as_ref().map(Document::identity).as_ref() != Some(&self.identity)
            || vault.record(self.id()).as_ref() != Some(&self.after)
            || draft.identity != self.identity
            || draft.expected.as_ref() != Some(&self.before)
            || draft.metadata != self.before.metadata
        {
            return Err(CHANGED);
        }
        draft.expected = Some(self.after.clone());
        Ok(())
    }
}

#[cfg(test)]
#[path = "vault_legacy_repair_tests.rs"]
mod tests;
