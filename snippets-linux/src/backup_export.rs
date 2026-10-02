//! Exact two-file snapshot and revocable encrypted-only publication.
use super::*;
use crate::{
    desktop::{SessionState, SessionWitness},
    model::Library,
    vault,
};
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

const CHANGED: Error =
    Error("The saved library changed while preparing the backup. Export it again.");
const EXPIRED: Error = Error("Backup authorization expired or was cancelled. No backup was saved.");
/// A focus, lock or quit cancellation revokes the same capability observed by
/// the owner worker, including after a file-lock wait and before atomic rename.
#[derive(Clone)]
pub struct Authorization {
    cancelled: Arc<AtomicBool>,
    witness: SessionWitness,
    epoch: u64,
    deadline: Duration,
}
impl Authorization {
    pub fn new(witness: SessionWitness) -> Result<Self> {
        let (state, epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            return Err(EXPIRED);
        }
        let now = crate::clock::uptime().ok_or(EXPIRED)?;
        Ok(Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            witness,
            epoch,
            deadline: now.saturating_add(Duration::from_secs(120)),
        })
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn validate(&self) -> Result<()> {
        self.validate_at(crate::clock::uptime().ok_or(EXPIRED)?)
    }
    fn validate_at(&self, now: Duration) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire)
            || now >= self.deadline
            || self.witness.snapshot() != (SessionState::Unlocked, self.epoch)
        {
            return Err(EXPIRED);
        }
        Ok(())
    }
}
pub struct Snapshot {
    root: PathBuf,
    plain_before: Option<Vec<u8>>,
    vault_before: Option<Vec<u8>>,
    snippets: Vec<Snippet>,
    vault: Option<Document>,
}
impl Snapshot {
    pub fn read(library: &Library) -> Result<Self> {
        let _guard = library.lock()?;
        crate::primary::require_ready(&library.root)?;
        let plain_before = model::read_regular(&library.path())?;
        let vault = vault::read_document_locked(&library.root)?;
        let vault_before = model::read_regular(&library.root.join("Vault/vault.json"))?;
        if vault_before.as_deref().map(Document::decode).transpose()? != vault {
            return Err(CHANGED);
        }
        let snippets = model::decode_library(plain_before.as_deref().unwrap_or(b"[]"), false)?;
        let exported = vault.as_ref().filter(|v| !v.records.is_empty());
        validate(&snippets, exported)?;
        Ok(Self {
            root: library.root.clone(),
            plain_before,
            vault_before,
            snippets,
            vault: exported.cloned(),
        })
    }
    pub fn counts(&self) -> (usize, usize) {
        (
            self.snippets.len(),
            self.vault.as_ref().map_or(0, |v| v.records.len()),
        )
    }
    pub fn needs_vault(&self) -> bool {
        self.vault.is_some()
    }
    pub fn has_passphrase(&self) -> bool {
        self.vault.as_ref().is_some_and(|v| v.wrap_pass.is_some())
    }
    /// Entire worker operation: fresh authentication, encryption and exact
    /// snapshot publication. No raw key or decrypted secure body is returned.
    pub fn write_backup(
        &self,
        library: &Library,
        destination: &Path,
        password: &str,
        credential: Option<(&str, bool)>,
        check: &dyn Fn() -> Result<()>,
    ) -> Result<(usize, usize)> {
        self.write_inner(
            library,
            destination,
            password,
            credential,
            check,
            crypto::PASSPHRASE_ITERATIONS,
        )
    }
    fn write_inner(
        &self,
        library: &Library,
        destination: &Path,
        password: &str,
        credential: Option<(&str, bool)>,
        check: &dyn Fn() -> Result<()>,
        iterations: u32,
    ) -> Result<(usize, usize)> {
        check()?;
        let data = if let Some(vault) = &self.vault {
            let (text, recovery) = credential.ok_or(Error(
                "Authenticate this vault to include its secure snippets.",
            ))?;
            vault.with_backup_key(text, recovery, |key| {
                check()?;
                let data = seal_inner(&self.snippets, Some((vault, key)), password, iterations)?;
                check()?;
                Ok(data)
            })?
        } else {
            seal_inner(&self.snippets, None, password, iterations)?
        };
        check()?;
        self.publish(library, destination, &data, check)?;
        Ok(self.counts())
    }
    fn publish(
        &self,
        library: &Library,
        destination: &Path,
        data: &[u8],
        check: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        if self.root != library.root {
            return Err(CHANGED);
        }
        let _guard = library.lock()?;
        crate::primary::require_ready(&library.root)?;
        check()?;
        if model::read_regular(&library.path())? != self.plain_before
            || model::read_regular(&library.root.join("Vault/vault.json"))? != self.vault_before
        {
            return Err(CHANGED);
        }
        let parent = destination
            .parent()
            .ok_or(Error("Choose a local backup destination."))?;
        let resolved_parent = fs::canonicalize(parent)
            .map_err(|_| Error("The backup destination is unavailable."))?;
        let resolved_root = fs::canonicalize(&library.root).map_err(|_| CHANGED)?;
        if resolved_parent.starts_with(resolved_root) {
            return Err(Error(
                "Save the backup outside the app's library directory.",
            ));
        }
        if let Ok(metadata) = fs::symlink_metadata(destination)
            && (!metadata.is_file() || metadata.file_type().is_symlink())
        {
            return Err(Error("Choose a regular backup destination, without links."));
        }
        let mut temporary = tempfile::Builder::new()
            .prefix(".snippets-backup-")
            .tempfile_in(parent)
            .map_err(|_| Error("The backup could not be saved."))?;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|_| Error("The backup could not be saved."))?;
        temporary
            .write_all(data)
            .and_then(|_| temporary.as_file().sync_all())
            .map_err(|_| Error("The backup could not be saved."))?;
        check()?;
        temporary
            .persist(destination)
            .map_err(|_| Error("The backup could not be saved."))?;
        fs::File::open(parent)
            .and_then(|file| file.sync_all())
            .map_err(|_| {
                Error("Backup publication is uncertain. Check the destination before trying again.")
            })?;
        Ok(())
    }
}
#[cfg(test)]
#[path = "backup_export_tests.rs"]
mod tests;
