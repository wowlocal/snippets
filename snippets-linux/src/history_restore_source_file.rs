//! An explicitly selected old vault or portable backup. Only wraps and a
//! volatile exact-file proof survive inspection. No file data is imported here.
use super::*;
use crate::{
    model,
    vault::{Document, RecoveryHeader},
};
use std::{
    fs::{File, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::SystemTime,
};

#[derive(Clone, PartialEq, Eq)]
struct Generation {
    device: u64,
    inode: u64,
    length: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl Generation {
    fn read(file: &File) -> Result<Self> {
        let info = file.metadata().map_err(|_| Failure::SourceFile)?;
        if !info.is_file() || info.len() > model::MAX_FILE_BYTES as u64 {
            return Err(Failure::SourceFile);
        }
        Ok(Self {
            device: info.dev(),
            inode: info.ino(),
            length: info.len(),
            modified: (info.mtime(), info.mtime_nsec()),
            changed: (info.ctime(), info.ctime_nsec()),
        })
    }
}
/// No Debug/serialization. Paths, hashes and filesystem identities stay volatile.
#[derive(Clone)]
pub(super) struct Proof {
    path: PathBuf,
    generation: Generation,
    digest: [u8; 32],
}
fn read(path: &Path) -> Result<(Proof, Zeroizing<Vec<u8>>)> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Failure::SourceFile)?;
    let generation = Generation::read(&file)?;
    let mut data = Zeroizing::new(Vec::new());
    (&mut file)
        .take(model::MAX_FILE_BYTES as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|_| Failure::SourceFile)?;
    if data.len() > model::MAX_FILE_BYTES
        || data.len() as u64 != generation.length
        || Generation::read(&file)? != generation
    {
        return Err(Failure::SourceFile);
    }
    let proof = Proof {
        path: path.to_owned(),
        generation,
        digest: Sha256::digest(&data).into(),
    };
    // Reopening binds the descriptor to the selected path, including replacement
    // with identical bytes. A final symlink or a special input is not accepted.
    let named = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Failure::SourceFile)?;
    if Generation::read(&named)? != proof.generation {
        return Err(Failure::Changed);
    }
    Ok((proof, data))
}
impl Proof {
    fn bytes(&self) -> Result<Zeroizing<Vec<u8>>> {
        let (current, bytes) = read(&self.path)?;
        if current.generation != self.generation || current.digest != self.digest {
            return Err(Failure::Changed);
        }
        Ok(bytes)
    }
    pub(super) fn validate(&self) -> Result<()> {
        self.bytes().map(drop)
    }
}
enum Kind {
    Vault(RecoveryHeader),
    Backup,
}
/// Body-free selected-file owner. Authentication consumes it exactly once.
pub struct SourceFile {
    selection: Selection,
    proof: Proof,
    kind: Kind,
}
pub fn inspect_source_file<B: Backend>(
    store: &mut Store<B>,
    selection: &Selection,
    path: &Path,
) -> Result<SourceFile> {
    let retained = saved_vault_header(store, selection)?;
    let (proof, bytes) = read(path)?;
    let kind = if crate::backup::is_backup(&bytes) {
        Kind::Backup
    } else {
        let document = Document::decode(&bytes).map_err(|_| Failure::SourceFile)?;
        if retained
            .as_ref()
            .is_some_and(|header| !header.same_key_scope(&document))
        {
            return Err(Failure::Changed);
        }
        Kind::Vault(RecoveryHeader::retain(&document).map_err(|_| Failure::SourceFile)?)
    };
    // Inspection must not publish a file selected against superseded history.
    if saved_vault_header(store, selection)? != retained {
        return Err(Failure::Changed);
    }
    proof.validate()?;
    Ok(SourceFile {
        selection: selection.clone(),
        proof,
        kind,
    })
}
impl SourceFile {
    pub fn is_backup(&self) -> bool {
        matches!(self.kind, Kind::Backup)
    }
    pub fn has_passphrase(&self) -> bool {
        match &self.kind {
            Kind::Backup => true,
            Kind::Vault(header) => header.has_passphrase(),
        }
    }
    pub fn has_recovery(&self) -> bool {
        match &self.kind {
            Kind::Backup => false,
            Kind::Vault(header) => header.has_recovery(),
        }
    }
    #[cfg(feature = "desktop")]
    pub(crate) fn matches_selection(&self, selection: &Selection) -> bool {
        self.selection.history_hash == selection.history_hash
            && self.selection.transition == selection.transition
    }
    pub fn validate<B: Backend>(&self, store: &mut Store<B>) -> Result<()> {
        saved_vault_header(store, &self.selection)?;
        self.proof.validate()
    }
    pub fn authenticate<B: Backend>(
        self,
        store: &mut Store<B>,
        credential: &str,
        recovery: bool,
    ) -> Result<Source> {
        let retained = saved_vault_header(store, &self.selection)?;
        let bytes = self.proof.bytes()?;
        let vault = match self.kind {
            Kind::Vault(header) => header.authenticate_for_restoration(credential, recovery)?,
            Kind::Backup => {
                if recovery {
                    return Err(Failure::BackupAuthentication);
                }
                let started = crate::clock::uptime().ok_or(Failure::Changed)?;
                let wall = SystemTime::now();
                let opened = crate::backup::open(&bytes, credential)
                    .map_err(|_| Failure::BackupAuthentication)?;
                let (_, document, key) = opened.into_parts();
                let document = document.ok_or(Failure::SourceFile)?;
                if retained
                    .as_ref()
                    .is_some_and(|header| !header.same_key_scope(&document))
                {
                    return Err(Failure::Changed);
                }
                RecoveryHeader::retain(&document)
                    .map_err(|_| Failure::SourceFile)?
                    .backup_owner(key.ok_or(Failure::SourceFile)?, started, wall)?
            }
        };
        if saved_vault_header(store, &self.selection)? != retained {
            return Err(Failure::Changed);
        }
        self.proof.validate()?;
        Ok(Source {
            selection: self.selection,
            vault,
            external: Some(self.proof),
        })
    }
}
