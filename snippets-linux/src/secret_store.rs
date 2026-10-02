//! Opt-in native secret ownership. Disk stores only a random lookup namespace
//! and a private process lock; values go exclusively to Secret Service.
use crate::{
    crypto,
    model::{self, Library},
};
use std::{
    fs::{self, File, OpenOptions},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use zeroize::Zeroizing;

pub const MAX_SECRET_BYTES: usize = 128 * 1024;
const OWNER_FILE: &str = "secret-owner.bin";
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Unavailable,
    Locked,
    InvalidValue,
    Duplicate,
    Timeout,
    UnsupportedProvider,
    InvalidType,
    Stale,
    MissingOwner,
    Storage,
    IsolatedRoot,
}
pub type Result<T> = std::result::Result<T, Failure>;
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Slot {
    Credentials,
    LibraryKey,
    CheckpointKey,
    Bootstrap,
    PairingRecipient,
    SpaceCreation,
    KeyMutation,
    AccountReview,
    PairingCandidate,
    BootstrapCandidate,
    HistoryRestore,
    AutomaticSync,
    ClipboardHistory,
}
impl Slot {
    #[cfg(feature = "secret-service")]
    fn native_name(self) -> &'static std::ffi::CStr {
        match self {
            Self::Credentials => c"credentials-v1",
            Self::LibraryKey => c"library-key-v1",
            Self::CheckpointKey => c"checkpoint-key-v1",
            Self::Bootstrap => c"bootstrap-v1",
            Self::PairingRecipient => c"pairing-recipient-v1",
            Self::SpaceCreation => c"space-creation-v1",
            Self::KeyMutation => c"key-mutation-v1",
            Self::AccountReview => c"account-review-v1",
            Self::PairingCandidate => c"pairing-candidate-v1",
            Self::BootstrapCandidate => c"bootstrap-candidate-v1",
            Self::HistoryRestore => c"history-restore-v1",
            Self::AutomaticSync => c"automatic-sync-v1",
            Self::ClipboardHistory => c"clipboard-history-key-v1",
        }
    }
}
/// All implementors return closed errors and owned, zeroizing values. A backend
/// cannot write files or silently replace locked/corrupt/duplicated secrets.
pub trait Backend {
    fn read(&mut self, namespace: &[u8; 16], slot: Slot) -> Result<Option<Zeroizing<Vec<u8>>>>;
    fn write(&mut self, namespace: &[u8; 16], slot: Slot, value: &[u8]) -> Result<()>;
    fn delete(&mut self, namespace: &[u8; 16], slot: Slot) -> Result<()>;
}
pub struct Store<B: Backend> {
    root: PathBuf,
    namespace: [u8; 16],
    backend: B,
}
impl<B: Backend> Store<B> {
    /// Loading never creates a lookup namespace or a secret. Initialization is a
    /// separate, explicit sign-in/key-setup operation.
    pub fn load(root: &Path, backend: B) -> Result<Self> {
        let library = Library::prepare(root.into()).map_err(|_| Failure::Storage)?;
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        let namespace = read_owner(root)?.ok_or(Failure::MissingOwner)?;
        Ok(Self {
            root: root.into(),
            namespace,
            backend,
        })
    }
    pub fn initialize(root: &Path, backend: B) -> Result<Self> {
        let library = Library::prepare(root.into()).map_err(|_| Failure::Storage)?;
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        let namespace = match read_owner(root)? {
            Some(value) => value,
            None => {
                crate::primary::require_ready(root).map_err(|_| Failure::MissingOwner)?;
                // A checkpoint with a lost owner must never acquire replacement
                // keys under a newly minted namespace.
                match fs::symlink_metadata(root.join("Sync/journal.bin")) {
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                    _ => return Err(Failure::MissingOwner),
                }
                let value = crypto::random().map_err(|_| Failure::Unavailable)?;
                let mut encoded = b"SKO1".to_vec();
                encoded.extend_from_slice(&value);
                model::atomic_write(&root.join(OWNER_FILE), &encoded)
                    .map_err(|_| Failure::Storage)?;
                value
            }
        };
        Ok(Self {
            root: root.into(),
            namespace,
            backend,
        })
    }
    /// Serializes a complete credential transition across processes, independently
    /// of library writers. Callers may retain this guard across blocking HTTP.
    pub fn transaction<T>(
        &mut self,
        action: impl FnOnce(&mut Locked<'_, B>) -> Result<T>,
    ) -> Result<T> {
        self.transaction_with(action)
    }
    pub fn transaction_with<T, E: From<Failure>>(
        &mut self,
        action: impl FnOnce(&mut Locked<'_, B>) -> std::result::Result<T, E>,
    ) -> std::result::Result<T, E> {
        let guard = owner_lock(&self.root)?;
        if read_owner(&self.root)? != Some(self.namespace) {
            return Err(Failure::MissingOwner.into());
        }
        action(&mut Locked {
            store: self,
            _guard: guard,
        })
    }
}
fn read_owner(root: &Path) -> Result<Option<[u8; 16]>> {
    let Some(bytes) =
        model::read_regular_bounded(&root.join(OWNER_FILE), 20).map_err(|_| Failure::Storage)?
    else {
        return Ok(None);
    };
    if bytes.len() != 20 || &bytes[..4] != b"SKO1" {
        return Err(Failure::InvalidValue);
    }
    Ok(Some(
        bytes[4..].try_into().map_err(|_| Failure::InvalidValue)?,
    ))
}
fn owner_lock(root: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(root.join("secrets.lock"))
        .map_err(|_| Failure::Storage)?;
    if !file.metadata().is_ok_and(|m| m.is_file()) {
        return Err(Failure::Storage);
    }
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .and_then(|_| file.lock())
        .map_err(|_| Failure::Storage)?;
    Ok(file)
}
pub struct Locked<'a, B: Backend> {
    store: &'a mut Store<B>,
    _guard: File,
}
impl<B: Backend> Locked<'_, B> {
    pub(crate) fn root(&self) -> &Path {
        &self.store.root
    }
    /// Creating a different remote library cannot discard a checkpoint or an
    /// interrupted primary update. No checkpoint material is generated here.
    pub(crate) fn require_checkpoint_absent(&mut self) -> Result<()> {
        let library = Library::prepare(self.store.root.clone()).map_err(|_| Failure::Storage)?;
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        crate::primary::require_ready(&self.store.root).map_err(|_| Failure::MissingOwner)?;
        let directory = self.store.root.join("Sync");
        match fs::symlink_metadata(&directory) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            _ => return Err(Failure::Storage),
        }
        match fs::symlink_metadata(directory.join("journal.bin")) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            _ => Err(Failure::MissingOwner),
        }
    }
    /// Authenticate existing checkpoint scope before adopting a recovered library
    /// key. Initial creation instead requires absence. This never mints checkpoint
    /// material or changes primary files, markers, cursors or journal generations.
    pub(crate) fn check_checkpoint_scope(
        &mut self,
        scope: crate::journal::Scope,
        allow_existing: bool,
    ) -> Result<()> {
        let library = Library::prepare(self.store.root.clone()).map_err(|_| Failure::Storage)?;
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        let directory = self.store.root.join("Sync");
        match fs::symlink_metadata(&directory) {
            Ok(m) if m.is_dir() && !m.file_type().is_symlink() => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            _ => return Err(Failure::Storage),
        }
        match fs::symlink_metadata(directory.join("journal.bin")) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return crate::primary::require_ready(&self.store.root)
                    .map_err(|_| Failure::MissingOwner);
            }
            Ok(m) if allow_existing && m.is_file() && !m.file_type().is_symlink() => (),
            _ => return Err(Failure::MissingOwner),
        }
        let material = self
            .checkpoint_material(false)?
            .ok_or(Failure::MissingOwner)?;
        let root = crate::crypto::RootKey::from_bytes(&material[..32])
            .map_err(|_| Failure::InvalidValue)?;
        let salt = material[32..]
            .try_into()
            .map_err(|_| Failure::InvalidValue)?;
        crate::journal::Checkpoint::load_locked(&library, &root, &salt, scope)
            .map_err(|_| Failure::InvalidValue)?;
        Ok(())
    }
    pub fn read(&mut self, slot: Slot) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let value = self.store.backend.read(&self.store.namespace, slot)?;
        if value
            .as_ref()
            .is_some_and(|v| v.is_empty() || v.len() > MAX_SECRET_BYTES)
        {
            return Err(Failure::InvalidValue);
        }
        Ok(value)
    }
    /// Secret Service has no external-writer CAS primitive. The process lock
    /// serializes native owners; before/after reads also detect external changes
    /// or an ambiguous failed write. A failure requires reread, never key minting.
    pub fn replace(
        &mut self,
        slot: Slot,
        expected: Option<&[u8]>,
        value: Option<&[u8]>,
    ) -> Result<()> {
        if value.is_some_and(|v| v.is_empty() || v.len() > MAX_SECRET_BYTES) {
            return Err(Failure::InvalidValue);
        }
        let current = self.read(slot)?;
        if current.as_deref().map(Vec::as_slice) != expected {
            return Err(Failure::Stale);
        }
        match value {
            Some(value) => self
                .store
                .backend
                .write(&self.store.namespace, slot, value)?,
            None if current.is_some() => self.store.backend.delete(&self.store.namespace, slot)?,
            None => return Ok(()),
        }
        if self.read(slot)?.as_deref().map(Vec::as_slice) != value {
            return Err(Failure::Stale);
        }
        Ok(())
    }
    /// Per-install, non-portable checkpoint key. Existing ciphertext with a lost
    /// key halts recovery instead of generating a key that cannot open it.
    pub fn checkpoint_material(&mut self, create: bool) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let current = self.read(Slot::CheckpointKey)?;
        if let Some(value) = current {
            if value.len() != 64 {
                return Err(Failure::InvalidValue);
            }
            return Ok(Some(value));
        }
        crate::primary::require_ready(&self.store.root).map_err(|_| Failure::MissingOwner)?;
        match fs::symlink_metadata(self.store.root.join("Sync/journal.bin")) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            _ => return Err(Failure::MissingOwner),
        }
        if !create {
            return Ok(None);
        }
        let value = Zeroizing::new(
            crypto::random::<64>()
                .map_err(|_| Failure::Unavailable)?
                .to_vec(),
        );
        self.replace(Slot::CheckpointKey, None, Some(&value))?;
        Ok(Some(value))
    }
}

#[cfg(feature = "secret-service")]
mod native {
    use super::*;
    unsafe extern "C" {
        fn snip_secret_operation(
            install: *const std::ffi::c_char,
            slot: *const std::ffi::c_char,
            operation: std::ffi::c_int,
            input: *const u8,
            input_size: usize,
            output: *mut u8,
            capacity: usize,
            size: *mut usize,
        ) -> std::ffi::c_int;
    }
    pub struct Native;
    impl Native {
        /// Test storage overrides must never reach the real login keyring.
        pub fn new() -> Result<Self> {
            if std::env::var_os("SNIPPETS_SUPPORT_DIR").is_some() {
                return Err(Failure::IsolatedRoot);
            }
            Ok(Self)
        }
        fn operation(
            &mut self,
            namespace: &[u8; 16],
            slot: Slot,
            operation: i32,
            value: &[u8],
        ) -> Result<Option<Zeroizing<Vec<u8>>>> {
            if value.len() > MAX_SECRET_BYTES {
                return Err(Failure::InvalidValue);
            }
            let name = std::ffi::CString::new(
                namespace
                    .iter()
                    .map(|byte| format!("{byte:02x}"))
                    .collect::<String>(),
            )
            .map_err(|_| Failure::InvalidValue)?;
            let mut output =
                Zeroizing::new(vec![0u8; if operation == 0 { MAX_SECRET_BYTES } else { 0 }]);
            let mut size = 0;
            // All buffers remain owned for this bounded synchronous C call. The
            // C shim copies at most capacity bytes and never retains Rust memory.
            let status = unsafe {
                snip_secret_operation(
                    name.as_ptr(),
                    slot.native_name().as_ptr(),
                    operation,
                    value.as_ptr(),
                    value.len(),
                    output.as_mut_ptr(),
                    output.len(),
                    &mut size,
                )
            };
            match status {
                0 if operation == 0 && size <= output.len() => {
                    output.truncate(size);
                    Ok(Some(output))
                }
                0 => Ok(None),
                1 if operation != 1 => Ok(None),
                2 => Err(Failure::Locked),
                3 => Err(Failure::Unavailable),
                4 => Err(Failure::InvalidValue),
                5 => Err(Failure::Duplicate),
                6 => Err(Failure::Timeout),
                7 => Err(Failure::UnsupportedProvider),
                8 => Err(Failure::InvalidType),
                _ => Err(Failure::Unavailable),
            }
        }
    }
    impl Backend for Native {
        fn read(&mut self, namespace: &[u8; 16], slot: Slot) -> Result<Option<Zeroizing<Vec<u8>>>> {
            self.operation(namespace, slot, 0, &[])
        }
        fn write(&mut self, namespace: &[u8; 16], slot: Slot, value: &[u8]) -> Result<()> {
            self.operation(namespace, slot, 1, value).map(|_| ())
        }
        fn delete(&mut self, namespace: &[u8; 16], slot: Slot) -> Result<()> {
            self.operation(namespace, slot, 2, &[]).map(|_| ())
        }
    }
}
#[cfg(feature = "secret-service")]
pub use native::Native;

#[cfg(test)]
#[path = "secret_store_tests.rs"]
pub(crate) mod tests;
