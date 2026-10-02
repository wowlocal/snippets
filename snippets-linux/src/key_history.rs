//! Read-only protected-history catalogue. No bodies, key material, capabilities,
//! bindings/hashes or recovery codes leave the owning boundary. No serialization.
use super::*;
use crate::{account_review, model::Library};

#[derive(Clone)]
pub struct SavedLibrary {
    server: ServerURL,
    id: Uuid,
    epoch: u64,
}
impl SavedLibrary {
    pub(crate) fn new(binding: &KeyBinding) -> Self {
        Self {
            server: binding.server.clone(),
            id: binding.space,
            epoch: binding.epoch,
        }
    }
    pub fn server(&self) -> &ServerURL {
        &self.server
    }
    pub fn id(&self) -> Uuid {
        self.id
    }
    pub fn epoch(&self) -> u64 {
        self.epoch
    }
}
pub struct SavedKey {
    pub library: SavedLibrary,
    pub recovery: KitStatus,
    pub active: bool,
}
impl SavedKey {
    pub(super) fn new(
        installed: &Installed,
        recovery: KitStatus,
        active: Option<&Installed>,
    ) -> Self {
        Self {
            library: SavedLibrary::new(&installed.binding),
            recovery,
            active: active.is_some_and(|key| {
                key.binding == installed.binding
                    && key.bundle.for_secure_storage() == installed.bundle.for_secure_storage()
            }),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SwitchPhase {
    Pending,
    Completed,
    Cancelled,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PreviousCapabilities {
    pub pairing: bool,
    pub creation: bool,
    pub signed_action: bool,
}
pub struct SavedSwitch {
    pub removal: Option<super::capacity::Selection>,
    pub selection: super::restoration::Selection,
    pub phase: SwitchPhase,
    pub source: SavedKey,
    pub target: SavedKey,
    pub previous: PreviousCapabilities,
    pub summary: account_review::Summary,
    pub images: account_review::RetainedImages,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PairingPhase {
    Creating,
    Waiting,
    Claimed,
    Ready,
    Cancelling,
    Cancelled,
}
pub struct SavedPairing {
    pub removal: Option<super::capacity::Selection>,
    pub library: SavedLibrary,
    pub phase: PairingPhase,
}
pub struct SavedFirstKey {
    pub removal: Option<super::capacity::Selection>,
    pub key: SavedKey,
    pub phase: initial_candidate::Status,
}
pub struct SavedRestoration {
    pub removal: Option<super::capacity::Selection>,
    pub library: SavedLibrary,
    pub phase: SwitchPhase,
    pub summary: super::restoration::Summary,
    pub needs_completion: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CreationPhase {
    Requested,
    Created,
}
/// Creation receipts contain metadata only. Request identifiers, account names
/// and credentials stay inside the protected owner.
pub struct SavedCreation {
    pub removal: Option<super::capacity::Selection>,
    pub library: Option<SavedLibrary>,
    pub source: Option<SavedLibrary>,
    pub phase: CreationPhase,
}
/// Exact protected document sizes, rather than estimated free slot capacity.
#[derive(Default)]
pub struct Usage {
    pub switches: usize,
    pub pairing: usize,
    pub first_keys: usize,
    pub restorations: usize,
    pub creations: usize,
}
#[derive(Default)]
pub struct Catalog {
    pub maintenance: Option<super::capacity::Summary>,
    pub active: Option<SavedLibrary>,
    pub switches: Vec<SavedSwitch>,
    pub pairing: Vec<SavedPairing>,
    pub first_keys: Vec<SavedFirstKey>,
    pub restorations: Vec<SavedRestoration>,
    pub creations: Vec<SavedCreation>,
    pub creations_unavailable: bool,
    pub usage: Usage,
}
pub const MAX_ENTRIES: usize = 8;

pub(super) fn recovery(
    snapshot: Option<Zeroizing<Vec<u8>>>,
    installed: &Installed,
) -> Result<KitStatus> {
    let archive = Archive::from_snapshot(snapshot)?;
    archive.check_binding(&installed.binding)?;
    validate_presentation(&archive, installed)?;
    Ok(archive.presentation.map_or(KitStatus::None, |p| p.status))
}
pub fn inspect<B: Backend>(store: &mut Store<B>) -> handover::Result<Catalog> {
    store.history_transaction_with(|owner| {
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        // History inspection never initializes a slot, reads credentials, repairs
        // primary/journal files, or admits a key into a remote data plane.
        let active = owner
            .read(Slot::LibraryKey)?
            .map(|v| Installed::decode(&v))
            .transpose()?;
        // A pending switch can legitimately have mixed source/target slots.
        // Identify the current key without treating Bootstrap as ready/admitted.
        let active_info = active.as_ref().map(|key| SavedLibrary::new(&key.binding));
        let active_image = match std::fs::symlink_metadata(owner.root().join("Sync")) {
            Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {
                crate::model::read_regular_bounded(
                    &owner.root().join("Sync/journal.bin"),
                    crate::crypto::MAX_CHECKPOINT_BYTES + 32,
                )
                .map(|bytes| bytes.map(|bytes| Sha256::digest(bytes).into()))
                .map_err(|_| ())
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            _ => Err(()),
        };
        let switches = handover::history_locked(owner, &library, active.as_ref(), active_image)?;
        let pairing = candidate::history_locked(owner)?;
        let first_keys = initial_candidate::history_locked(owner, active.as_ref())?;
        let restorations =
            super::restoration::history_locked(owner).map_err(|error| match error {
                super::restoration::Failure::Key(error) => handover::Failure::Key(error),
                _ => handover::Failure::Key(super::Failure::InvalidState),
            })?;
        let (creations, creations_unavailable) =
            match crate::auth_store::creation::history_locked(owner) {
                Ok(rows) => (rows, false),
                // Unknown old capability bytes stay protected. A read-only catalogue
                // can still show other archives, but must not call this empty history.
                Err(Failure::InvalidState) => (Vec::new(), true),
                Err(error) => return Err(error.into()),
            };
        let size = |value: Option<Zeroizing<Vec<u8>>>| value.map_or(0, |v| v.len());
        let usage = Usage {
            switches: size(owner.read(Slot::AccountReview)?),
            pairing: size(owner.read(Slot::PairingCandidate)?),
            first_keys: size(owner.read(Slot::BootstrapCandidate)?),
            restorations: size(owner.read(Slot::HistoryRestore)?),
            creations: size(owner.read(Slot::SpaceCreation)?),
        };
        let maintenance = super::capacity::pending_locked(owner)?;
        Ok(Catalog {
            maintenance,
            active: active_info,
            switches,
            pairing,
            first_keys,
            restorations,
            creations,
            creations_unavailable,
            usage,
        })
    })
}
