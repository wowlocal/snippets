//! One serialized account owner. GTK never owns a token or calls a blocking
//! secret/network API. Unrecorded grants remain here across window dismissal.
use crate::{
    account_key::AccountKey,
    auth_store::{self, LiveSession, creation},
    auto_sync::{self, Control, Preference, Schedule, Target, Ticket, Wake},
    bootstrap::{Invitation, RecoveryKit},
    cloud::{self, BoundTransport, CloudClient, ServerURL, Space},
    deletion_review,
    key_store::{
        self, candidate, capacity, disclosure, handover, initial_candidate, mutations, recipient,
        restoration,
    },
    local_auth, receiver,
    secret_store::{self, Native, Store},
    sender, snapshot_review, sync as data_sync,
};
use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering},
        mpsc,
    },
    time::Duration,
};
use zeroize::Zeroizing;
#[path = "account_diagnostics.rs"]
mod diagnostic;

#[path = "account_restoration.rs"]
pub(crate) mod restoration_task;

#[path = "account_history_removal.rs"]
pub(crate) mod history_removal;
#[path = "account_vault_sync.rs"]
pub(crate) mod vault_sync;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Failure {
    Secret(secret_store::Failure),
    Account(auth_store::Failure),
    Cloud(cloud::Failure),
    Key(key_store::Failure),
    HistoryRemoval(key_store::Failure),
    Authentication(local_auth::Failure),
    Receive(receiver::Failure),
    SnapshotReview(snapshot_review::Failure),
    DeletionReview(deletion_review::Failure),
    Handover(handover::Failure),
    Restoration(restoration::Failure),
    VaultAuthentication,
    PreviousVaultAuthentication,
    InvalidState,
    RetentionRequired,
    WorkerStopped,
    ExistingLibrary,
    CreationRetentionFull,
    Automatic(auto_sync::Failure),
    /// A local typing error. Such a key is never sent to a server.
    InvalidAccountKey,
    /// The pasted or scanned device request is malformed, expired or foreign.
    InvalidDeviceRequest,
    /// The library an approving device named is not in this account's list.
    DeviceLibraryUnavailable,
    /// Discovery does not advertise `native-device-sign-in-v1`.
    DeviceSignInUnsupported,
}
pub(crate) type Result<T> = std::result::Result<T, Failure>;
impl From<auto_sync::Failure> for Failure {
    fn from(value: auto_sync::Failure) -> Self {
        match value {
            auto_sync::Failure::Account(value) => value.into(),
            auto_sync::Failure::Secret(value) => value.into(),
            other => Self::Automatic(other),
        }
    }
}
impl From<secret_store::Failure> for Failure {
    fn from(v: secret_store::Failure) -> Self {
        Self::Secret(v)
    }
}
impl From<auth_store::Failure> for Failure {
    fn from(v: auth_store::Failure) -> Self {
        match v {
            auth_store::Failure::Cloud(e) => Self::Cloud(e),
            auth_store::Failure::Secret(e) => Self::Secret(e),
            auth_store::Failure::Authentication(e) => Self::Authentication(e),
            other => Self::Account(other),
        }
    }
}
impl From<cloud::Failure> for Failure {
    fn from(v: cloud::Failure) -> Self {
        Self::Cloud(v)
    }
}
impl From<key_store::Failure> for Failure {
    fn from(v: key_store::Failure) -> Self {
        match v {
            key_store::Failure::Cloud(e) => Self::Cloud(e),
            key_store::Failure::Secret(e) => Self::Secret(e),
            key_store::Failure::Authentication(e) => Self::Authentication(e),
            other => Self::Key(other),
        }
    }
}
impl From<local_auth::Failure> for Failure {
    fn from(v: local_auth::Failure) -> Self {
        Self::Authentication(v)
    }
}
impl From<receiver::Failure> for Failure {
    fn from(value: receiver::Failure) -> Self {
        match value {
            receiver::Failure::Remote(failure) => Self::Cloud(failure),
            other => Self::Receive(other),
        }
    }
}
impl From<snapshot_review::Failure> for Failure {
    fn from(value: snapshot_review::Failure) -> Self {
        match value {
            snapshot_review::Failure::Data(failure) => failure.into(),
            other => Self::SnapshotReview(other),
        }
    }
}
impl From<deletion_review::Failure> for Failure {
    fn from(value: deletion_review::Failure) -> Self {
        match value {
            deletion_review::Failure::Data(failure) => failure.into(),
            other => Self::DeletionReview(other),
        }
    }
}
impl From<creation::Failure> for Failure {
    fn from(e: creation::Failure) -> Self {
        match e {
            creation::Failure::Secret(e) => e.into(),
            creation::Failure::Account(e) => e.into(),
            creation::Failure::Cloud(e) => e.into(),
            creation::Failure::Key(e) => e.into(),
            creation::Failure::ReviewRequired => key_store::Failure::ReviewRequired.into(),
            creation::Failure::ExistingLibrary => Self::ExistingLibrary,
            creation::Failure::RetentionFull => Self::CreationRetentionFull,
            creation::Failure::InvalidState => Self::InvalidState,
        }
    }
}
impl From<handover::Failure> for Failure {
    fn from(value: handover::Failure) -> Self {
        match value {
            handover::Failure::Key(value) => value.into(),
            handover::Failure::Journal(crate::account_review::Failure::Data(value)) => value.into(),
            other => Self::Handover(other),
        }
    }
}
impl From<restoration::Failure> for Failure {
    fn from(value: restoration::Failure) -> Self {
        Self::Restoration(value)
    }
}
impl Failure {
    pub(crate) fn message(self) -> &'static str {
        match self {
            Self::HistoryRemoval(_) => {
                "The saved recovery data changed, its format is unavailable, or an operation is still unfinished. Open Library Recovery History to review or finish removal."
            }
            Self::Secret(secret_store::Failure::HistoryMaintenanceRequired) => {
                "Finish the saved history removal or file cleanup in Library Recovery History before continuing."
            }
            Self::Automatic(auto_sync::Failure::ScopeChanged) => {
                "The saved automatic-sync account or library changed. Reconnect and review it before enabling automatic sync again."
            }
            Self::Automatic(auto_sync::Failure::Cancelled) => "Automatic synchronization stopped.",
            Self::Automatic(_) => {
                "Automatic-sync settings could not be verified or saved. Reconnect and try again."
            }
            Self::VaultAuthentication => {
                "The vault could not be unlocked. Check its passphrase or recovery key and try again."
            }
            Self::PreviousVaultAuthentication => {
                "The previous vault could not be unlocked. Check its passphrase or recovery key and review the saved changes again."
            }
            Self::Restoration(restoration::Failure::Primary(
                crate::primary::Failure::VaultLocked,
            )) => "Unlock the matching vault before restoring saved secure changes.",
            Self::Restoration(restoration::Failure::Primary(
                crate::primary::Failure::IncompatibleVault,
            )) => {
                "These changes belong to a different vault. Review them using the previous vault's passphrase or recovery key. Older saved states may require its matching vault backup."
            }
            Self::Restoration(
                restoration::Failure::RetentionFull
                | restoration::Failure::History(crate::account_review::Failure::RetentionFull),
            ) => "Recovery history is full. Previous states were kept; no restoration was started.",
            Self::Restoration(restoration::Failure::PreservationRequired) => {
                "Finish preserving the pending conflict versions before restoring this saved state."
            }
            Self::Restoration(restoration::Failure::Unavailable) => {
                "No saved changes are available for this action."
            }
            Self::Restoration(restoration::Failure::SourceFile) => {
                "Choose a regular previous vault.json file or a Snippets encrypted backup containing its vault. Changed or unreadable files need a new selection."
            }
            Self::Restoration(restoration::Failure::BackupAuthentication) => {
                "The previous vault backup could not be authenticated. Check its backup password and choose the file again."
            }
            Self::Restoration(_) => {
                "The saved state or current library changed, or restoration needs recovery. Open Library Recovery History to review it again."
            }
            Self::Handover(
                handover::Failure::Changed
                | handover::Failure::Journal(crate::account_review::Failure::Changed),
            ) => {
                "The saved switch or local library changed. Cancel an unpublished switch, then review it again."
            }
            Self::Handover(
                handover::Failure::RetentionFull
                | handover::Failure::Journal(crate::account_review::Failure::RetentionFull),
            ) => {
                "Library-switch recovery history is full. Previous keys were kept; no switch was started."
            }
            Self::Handover(handover::Failure::Unavailable) => {
                "This switch cannot be cancelled or resumed here. Select its library to finish an already started switch."
            }
            Self::Handover(handover::Failure::Unpublished) => {
                "The saved switch has not changed the local library yet. Resume it while connected or cancel it instead."
            }
            Self::Handover(handover::Failure::Journal(
                crate::account_review::Failure::LocalAbsence,
            )) => {
                "Part of the local library is missing. Restore its backup before switching libraries."
            }
            Self::DeletionReview(failure) => match failure {
                deletion_review::Failure::Unavailable => "No saved deletion needs review.",
                deletion_review::Failure::MissingFile => {
                    "Part of the local library is missing. Restore its backup before reviewing deletions."
                }
                deletion_review::Failure::Changed => {
                    "The local or cloud library changed. Review this deletion again."
                }
                deletion_review::Failure::PreservationRequired => {
                    "Preserve the pending conflict copies before deciding this deletion."
                }
                deletion_review::Failure::VaultLocked => {
                    "This saved record needs its vault before it can be restored."
                }
                deletion_review::Failure::IncompatibleVault => {
                    "This saved record belongs to a different vault. Restore the matching vault first."
                }
                deletion_review::Failure::RestoreUnavailable => {
                    "No compatible retained version is available to restore."
                }
                deletion_review::Failure::SendPending => {
                    "Finish the saved send before reviewing this incoming deletion."
                }
                _ => "This deletion could not be applied safely. Review it again.",
            },
            Self::SnapshotReview(snapshot_review::Failure::Unavailable) => {
                "No missing cloud records need this review. Receive Cloud Changes to continue."
            }
            Self::SnapshotReview(snapshot_review::Failure::LocalAbsence) => {
                "A local record is also missing. Review that deletion before resuming the cloud snapshot."
            }
            Self::SnapshotReview(snapshot_review::Failure::Changed) => {
                "The local or cloud library changed. Review the missing records again."
            }
            Self::Receive(
                receiver::Failure::ScopeReview
                | receiver::Failure::Journal(crate::journal::Failure::ScopeReview)
                | receiver::Failure::Primary(crate::primary::Failure::RecoveryRequired),
            ) => "The saved library needs review or recovery before receiving changes.",
            Self::Receive(receiver::Failure::SessionChanged) => {
                "The account session or library key changed. Reconnect before receiving changes."
            }
            Self::Receive(receiver::Failure::Journal(_)) => {
                "Cloud changes could not be saved safely. Retry to recover the retained page."
            }
            Self::Receive(receiver::Failure::InvalidPage | receiver::Failure::Primary(_)) => {
                "Cloud changes could not be applied safely. The retained page needs review."
            }
            Self::Cloud(cloud::Failure::InvalidServer) => "Enter a valid HTTPS server address.",
            Self::Cloud(cloud::Failure::InvalidCredential) => {
                "Sign in again with your account key."
            }
            Self::InvalidAccountKey => "This isn't a valid account key. Check it for typos.",
            Self::Account(auth_store::Failure::AccountKeyUnavailable) => {
                "This device was signed in by another device. View the account key on a device that has it."
            }
            Self::InvalidDeviceRequest => {
                "This sign-in request is invalid, expired or for another server. Start again on the new device."
            }
            Self::DeviceSignInUnsupported => {
                "This server doesn't support signing in with another device. Sign in with your account key instead."
            }
            Self::DeviceLibraryUnavailable => {
                "The library this device was approved for isn't available to this account. Cancel and sign in again."
            }
            Self::Cloud(cloud::Failure::Server {
                code: cloud::ErrorCode::InvalidAccountKey,
                ..
            }) => "That account key wasn't accepted. Check it and try again.",
            Self::Cloud(cloud::Failure::IncompatibleServer) => {
                "This server does not support the required Snippets Cloud protocol."
            }
            Self::Cloud(cloud::Failure::ReadOnly) => {
                "This account cannot perform the requested library-key operation."
            }
            Self::Account(auth_store::Failure::Expired) => {
                "Reconnect your saved account before continuing."
            }
            Self::Account(auth_store::Failure::Stale | auth_store::Failure::WrongDeployment) => {
                "The saved account changed. Reconnect before continuing."
            }
            Self::Cloud(cloud::Failure::Network) => "The server could not be reached. Try again.",
            Self::Cloud(cloud::Failure::AccountReview | cloud::Failure::DatasetReview)
            | Self::Key(key_store::Failure::ReviewRequired | key_store::Failure::KeyConflict) => {
                "The account or library changed. Review is required before continuing."
            }
            Self::Secret(
                secret_store::Failure::InvalidValue
                | secret_store::Failure::Duplicate
                | secret_store::Failure::InvalidType
                | secret_store::Failure::Stale
                | secret_store::Failure::MissingOwner,
            ) => {
                "Secure account storage is missing or changed. Review is required before continuing."
            }
            Self::Secret(_) | Self::Account(auth_store::Failure::Secret(_)) => {
                "Unlock your system keyring and try again."
            }
            Self::RetentionRequired => {
                "A received account session or pairing response must be saved before continuing. Unlock your keyring, then retry secure storage."
            }
            Self::Key(key_store::Failure::Busy) => {
                "Resume or cancel the retained library-key operation before continuing."
            }
            Self::Cloud(cloud::Failure::Server {
                code: cloud::ErrorCode::PairingExpired,
                ..
            }) => "The pairing invitation expired. Cancel it before creating another invitation.",
            Self::Key(key_store::Failure::VerificationMismatch) => {
                "The last eight characters do not match the recovery code."
            }
            Self::Key(key_store::Failure::RecoveryUnavailable) => {
                "This recovery code is no longer available for display."
            }
            Self::Authentication(
                local_auth::Failure::Denied | local_auth::Failure::AccountRestricted,
            ) => "Your login password could not authorize this action.",
            Self::Authentication(local_auth::Failure::DesktopUnavailable) => {
                "Unlock the desktop before authorizing this action."
            }
            Self::Authentication(
                local_auth::Failure::Cancelled
                | local_auth::Failure::Expired
                | local_auth::Failure::WrongTarget,
            )
            | Self::Key(key_store::Failure::Authentication(
                local_auth::Failure::Cancelled
                | local_auth::Failure::Expired
                | local_auth::Failure::WrongTarget,
            )) => "Authorization expired. Try again.",
            Self::Authentication(_) => "System authentication is unavailable.",
            Self::WorkerStopped => "The account worker is unavailable. Restart Snippets.",
            Self::ExistingLibrary => {
                "This installation already uses a library. Continue with its saved keys or review the account."
            }
            Self::CreationRetentionFull => {
                "Library-creation history is full or an earlier request needs resuming. Previous receipts were kept; no new library was requested."
            }
            _ => "The account operation could not be completed. Try again.",
        }
    }
}
pub(crate) enum Command {
    Automatic(bool),
    Inspect,
    InspectHistory,
    PrepareHistoryRemoval {
        selection: Option<capacity::Selection>,
        preparation: restoration_task::Preparation,
    },
    PrepareRecoveryFileCleanup(restoration_task::Preparation),
    CommitHistoryRemoval {
        token: uuid::Uuid,
        permit: local_auth::Permit,
    },
    PrepareRestoration {
        selection: restoration::Selection,
        credentials: Option<restoration_task::Credentials>,
        preparation: restoration_task::Preparation,
        source_file: Option<uuid::Uuid>,
    },
    InspectRestorationFile {
        selection: restoration::Selection,
        path: PathBuf,
        preparation: restoration_task::Preparation,
    },
    InspectRestorationFiles {
        selection: restoration::Selection,
        paths: Vec<PathBuf>,
        preparation: restoration_task::Preparation,
    },
    PrepareMultipleRestoration {
        selection: restoration::Selection,
        credentials: restoration_task::MultipleCredentials,
        preparation: restoration_task::Preparation,
        source_files: uuid::Uuid,
    },
    CommitRestoration {
        token: uuid::Uuid,
        permit: local_auth::Permit,
    },
    PrepareRestorationResume(bool),
    FinishRestoration {
        cancel: bool,
        permit: local_auth::Permit,
    },
    Resume,
    CreateAccount {
        server: Zeroizing<String>,
    },
    SignIn {
        server: Zeroizing<String>,
        key: AccountKey,
    },
    PrepareAccountKeyDisclosure,
    RevealAccountKey(local_auth::Permit),
    BeginDeviceSignIn {
        server: Zeroizing<String>,
    },
    CheckDeviceSignIn,
    CancelDeviceSignIn,
    PrepareDeviceApproval(Zeroizing<String>),
    ApproveDevice(local_auth::Permit),
    Refresh,
    SignOut,
    Retain,
    Select(usize),
    PrepareHandover(Option<Zeroizing<String>>),
    CommitHandover {
        token: uuid::Uuid,
        permit: local_auth::Permit,
    },
    PrepareHandoverResume,
    ResumeHandover(local_auth::Permit),
    PrepareHandoverCancel,
    CancelHandover(local_auth::Permit),
    PrepareLocalHandover,
    FinishLocalHandover(local_auth::Permit),
    CreateLibrary,
    PrepareNewLibrary,
    CreateNewLibrary(uuid::Uuid),
    BeginPairing,
    CheckPairing,
    CancelPairing,
    CandidatePairing(candidate::Action),
    BootstrapCandidate,
    Setup,
    Receive,
    Send,
    Sync,
    PrepareVaultSync(vault_sync::Authorization),
    CancelVaultSync,
    ContinueVaultSync {
        token: uuid::Uuid,
        credential: Zeroizing<String>,
        recovery: bool,
    },
    PrepareSnapshotReview,
    ResumeSnapshotReview(uuid::Uuid),
    PrepareDeletionReview,
    DecideDeletionReview {
        token: uuid::Uuid,
        choice: deletion_review::Choice,
        credential: Option<(Zeroizing<String>, bool)>,
    },
    Recover(Zeroizing<String>),
    PrepareDisclosure,
    PrepareRecoveryMutation,
    PrepareApproval(Zeroizing<String>),
    PrepareMutationResume,
    Mutate(local_auth::Permit),
    ReconcileMutation,
    CancelMutation,
    Authenticate {
        request: local_auth::Request,
        password: Zeroizing<Vec<u8>>,
    },
    Reveal(local_auth::Permit),
    Confirm {
        disclosure: disclosure::Disclosure,
        suffix: Zeroizing<String>,
    },
}
impl Command {
    fn keeps_automatic(&self) -> bool {
        matches!(
            self,
            Self::Inspect
                | Self::InspectHistory
                | Self::Sync
                | Self::PrepareVaultSync(_)
                | Self::CancelVaultSync
                | Self::ContinueVaultSync { .. }
                | Self::Receive
                | Self::Send
                | Self::PrepareDisclosure
                | Self::PrepareAccountKeyDisclosure
                | Self::RevealAccountKey(_)
                | Self::Authenticate { .. }
                | Self::Reveal(_)
                | Self::Confirm { .. }
                | Self::Automatic(_)
        )
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AutomaticStatus {
    Off,
    Scheduled,
    Current,
    ReceivedCurrent,
    MoreWork,
    Retry,
    Attention,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Automatic {
    pub(crate) enabled: bool,
    pub(crate) status: AutomaticStatus,
    pub(crate) failure: Option<Failure>,
}
impl Automatic {
    const OFF: Self = Self {
        enabled: false,
        status: AutomaticStatus::Off,
        failure: None,
    };
}
pub(crate) enum Reply {
    Automatic(Automatic),
    History(key_store::history::Catalog),
    HistoryRemovalReview {
        token: uuid::Uuid,
        summary: capacity::Summary,
        target: local_auth::Target,
    },
    HistoryRemoved,
    RecoveryFilesCleaned,
    NoUnusedRecoveryFiles,
    RestorationAuthentication(restoration_task::Authentication),
    RestorationFile {
        token: uuid::Uuid,
        methods: restoration_task::Authentication,
    },
    RestorationFiles {
        token: uuid::Uuid,
        methods: restoration_task::MultipleAuthentication,
    },
    RestorationReview {
        saved: key_store::history::SavedLibrary,
        current: key_store::history::SavedLibrary,
        token: Option<uuid::Uuid>,
        summary: restoration::Summary,
        target: local_auth::Target,
        rekeyed: bool,
    },
    Restored {
        failure: Option<Failure>,
        cancelled: bool,
    },
    /// `account` is only the short public account ID shown to the owner.
    Profile {
        account: Option<String>,
        server: Option<ServerURL>,
        interrupted: bool,
        switching: handover::Status,
        device: Option<auth_store::device::Status>,
    },
    /// A signed-out device's request: displayable state, a server-requested
    /// delay, and any failure of this poll (the request itself is kept).
    DeviceSignIn {
        state: Option<auth_store::device::Status>,
        retry_after: Option<u32>,
        failure: Option<Failure>,
    },
    /// Approved and committed: the library list, the selection of the approved
    /// library and the claimed key, each applied in this order.
    DeviceSignedIn {
        libraries: Box<Reply>,
        /// The approved library, already selected by the worker.
        library: Option<uuid::Uuid>,
        selected: Option<Box<Reply>>,
        keys: Option<key_store::Result<key_store::Outcome>>,
        failure: Option<Failure>,
    },
    /// The new account's key, shown once for saving before `next` is applied.
    AccountCreated {
        key: AccountKey,
        next: Option<Box<Reply>>,
        failure: Option<Failure>,
    },
    AccountKey(auth_store::AccountKeyDisclosure),
    Libraries {
        account: String,
        server: ServerURL,
        spaces: Vec<Space>,
        creation: creation::Result<creation::State>,
        can_create_new: creation::Result<bool>,
        created: Option<uuid::Uuid>,
        switching: handover::Status,
    },
    Library {
        outcome: key_store::Result<key_store::Outcome>,
        can_create_new: creation::Result<bool>,
    },
    Received(receiver::Progress),
    Sent(sender::Progress),
    Synchronized(data_sync::Progress),
    VaultSync {
        token: uuid::Uuid,
        methods: vault_sync::Methods,
    },
    SnapshotReview {
        token: uuid::Uuid,
        summary: snapshot_review::Summary,
    },
    SnapshotResumed(snapshot_review::Summary),
    DeletionReview {
        token: uuid::Uuid,
        summary: deletion_review::Summary,
    },
    DeletionDecided {
        kind: deletion_review::Kind,
        choice: deletion_review::Choice,
    },
    Selected {
        role: cloud::Role,
        can_create_new: creation::Result<bool>,
        keys: key_store::Result<key_store::Outcome>,
        pairing: key_store::Result<Option<recipient::RetainedStatus>>,
        mutation: key_store::Result<Option<mutations::Retained>>,
        switching: handover::Status,
        pending_matches: bool,
        candidate: key_store::Result<Option<candidate::Status>>,
        bootstrap: key_store::Result<Option<initial_candidate::Status>>,
    },
    HandoverReview {
        token: uuid::Uuid,
        summary: crate::account_review::Summary,
        target: local_auth::Target,
        reused_local_key: bool,
    },
    LocalHandoverReview {
        target: local_auth::Target,
        summary: crate::account_review::Summary,
    },
    LocalHandover {
        switching: handover::Status,
        failure: Option<Failure>,
    },
    Handover {
        switching: handover::Status,
        keys: Option<key_store::Outcome>,
        role: Option<cloud::Role>,
        cancelled: bool,
        failure: Option<Failure>,
        pending_matches: bool,
    },
    Pairing {
        state: key_store::Result<Option<recipient::RetainedStatus>>,
        failure: Option<Failure>,
    },
    CandidatePairing {
        state: key_store::Result<Option<candidate::Status>>,
        failure: Option<Failure>,
    },
    BootstrapCandidate {
        state: key_store::Result<Option<initial_candidate::Status>>,
        candidate: key_store::Result<Option<candidate::Status>>,
        failure: Option<Failure>,
    },
    CreationFailed {
        state: creation::Result<creation::State>,
        can_create_new: creation::Result<bool>,
        failure: Failure,
    },
    NewLibrary {
        token: uuid::Uuid,
        retained: usize,
    },
    Target(local_auth::Target),
    MutationTarget {
        target: local_auth::Target,
        retained: mutations::Retained,
    },
    Mutation {
        state: key_store::Result<Option<mutations::Retained>>,
        outcome: Option<mutations::Outcome>,
        failure: Option<Failure>,
    },
    Authenticated(local_auth::Authenticated),
    Disclosure(disclosure::Disclosure),
    Saved,
}
struct Task {
    command: Command,
    response: mpsc::SyncSender<Result<Reply>>,
}
/// Volatile response ownership belongs to the serialized worker, never a GTK
/// reply. A failed retention attempt returns this same owner for the next retry.
pub(crate) enum Pending {
    Account(auth_store::Unrecorded),
    Pairing(recipient::Unrecorded),
    Candidate(candidate::Unrecorded),
}
impl Pending {
    pub(crate) fn retain<B: secret_store::Backend>(
        self,
        store: &mut Store<B>,
    ) -> std::result::Result<(), (Failure, Option<Self>)> {
        match self {
            Self::Account(value) => value
                .retain(store)
                .map_err(|e| (e.failure.into(), e.unrecorded.map(Self::Account))),
            Self::Pairing(value) => value
                .retain(store)
                .map_err(|e| (e.failure.into(), e.unrecorded.map(Self::Pairing))),
            Self::Candidate(value) => value
                .retain(store)
                .map_err(|e| (e.failure.into(), e.unrecorded.map(Self::Candidate))),
        }
    }
}
pub(crate) struct Handle {
    sender: mpsc::Sender<Task>,
    pending: Arc<AtomicBool>,
    in_flight: Arc<AtomicUsize>,
    control: Arc<Control>,
    automatic: Arc<Mutex<Automatic>>,
    wake: Arc<AtomicU8>,
    #[cfg(test)]
    interrupt_handover: Arc<AtomicU8>,
}
enum Event {
    Command(Box<Command>),
    Tick,
    Wake(Wake),
}
fn automatic_outcome(
    result: Result<Reply>,
) -> (auto_sync::Outcome, AutomaticStatus, Option<Failure>) {
    use auto_sync::Outcome;
    let receive_only = matches!(&result, Ok(Reply::Received(_)));
    let progress = match result {
        Ok(Reply::Synchronized(progress)) => match progress.status {
            data_sync::Status::Current => Some(Outcome::Current),
            data_sync::Status::MoreWork(_) => Some(Outcome::MoreWork),
            data_sync::Status::Receiving(receiver::Status::PrimaryChanged)
            | data_sync::Status::Sending(
                sender::Status::PrimaryChanged
                | sender::Status::ServerDeferred {
                    code:
                        cloud::ErrorCode::RateLimited
                        | cloud::ErrorCode::DependencyUnavailable
                        | cloud::ErrorCode::InternalError,
                    ..
                },
            ) => Some(Outcome::Retry),
            _ => Some(Outcome::Attention),
        },
        Ok(Reply::Received(progress)) => Some(match progress.status {
            receiver::Status::Current => Outcome::Current,
            receiver::Status::MorePages => Outcome::MoreWork,
            receiver::Status::PrimaryChanged => Outcome::Retry,
            _ => Outcome::Attention,
        }),
        Ok(_) => Some(Outcome::Attention),
        Err(_) => None,
    };
    if let Some(outcome) = progress {
        let status = match outcome {
            Outcome::Current if receive_only => AutomaticStatus::ReceivedCurrent,
            Outcome::Current => AutomaticStatus::Current,
            Outcome::MoreWork => AutomaticStatus::MoreWork,
            Outcome::Retry => AutomaticStatus::Retry,
            Outcome::Attention => AutomaticStatus::Attention,
        };
        return (outcome, status, None);
    }
    let failure = result.err().unwrap_or(Failure::InvalidState);
    let retry = matches!(
        failure,
        Failure::Cloud(
            cloud::Failure::Network
                | cloud::Failure::Server {
                    code: cloud::ErrorCode::RateLimited
                        | cloud::ErrorCode::DependencyUnavailable
                        | cloud::ErrorCode::InternalError,
                    ..
                }
        ) | Failure::Secret(secret_store::Failure::Locked | secret_store::Failure::Unavailable)
            | Failure::Receive(receiver::Failure::Primary(
                crate::primary::Failure::RecoveryRequired | crate::primary::Failure::StalePrimary
            ))
            | Failure::Automatic(auto_sync::Failure::Cancelled)
    );
    if retry {
        (Outcome::Retry, AutomaticStatus::Retry, Some(failure))
    } else {
        (
            Outcome::Attention,
            AutomaticStatus::Attention,
            Some(failure),
        )
    }
}
#[cfg(test)]
#[derive(Clone, Copy)]
pub(crate) enum RestorationInterruption {
    Consent,
    Baseline,
    Ordinary,
    Vault,
}
#[cfg(test)]
impl RestorationInterruption {
    fn fault(self) -> u8 {
        match self {
            Self::Consent => 7,
            Self::Baseline => 0,
            Self::Ordinary => 2,
            Self::Vault => 3,
        }
    }
}
impl Handle {
    pub(crate) fn new(root: PathBuf) -> Result<Self> {
        let control = Control::new();
        let mut owner = Owner::new(root, control.clone());
        Self::spawn_events(control, move |event| Self::owner_event(&mut owner, event))
    }
    fn owner_event(owner: &mut Owner, event: Event) -> (Option<Result<Reply>>, bool, Automatic) {
        let reply = match event {
            Event::Command(command) => Some(owner.handle_scheduled(*command)),
            Event::Tick => {
                owner.tick();
                None
            }
            Event::Wake(reason) => {
                if let Some(schedule) = owner.schedule.as_mut() {
                    schedule.wake(reason, Self::now());
                }
                None
            }
        };
        (reply, owner.pending.is_some(), owner.automatic)
    }
    #[cfg(test)]
    pub(crate) fn live_fixture(
        root: PathBuf,
        server: ServerURL,
        agent: ureq::Agent,
        pam_helper: PathBuf,
    ) -> Result<Self> {
        Self::live_fixture_with_restoration_interruption(root, server, agent, pam_helper, None)
    }
    #[cfg(test)]
    pub(crate) fn live_fixture_with_restoration_interruption(
        root: PathBuf,
        server: ServerURL,
        agent: ureq::Agent,
        pam_helper: PathBuf,
        mut interruption: Option<RestorationInterruption>,
    ) -> Result<Self> {
        let control = Control::new();
        let mut owner = Owner::new(root, control.clone());
        Self::spawn_events(control, move |event| {
            cloud::with_live_fixture_agent(&server, &agent, || {
                local_auth::with_live_fixture_helper(&pam_helper, || {
                    // Interpose the existing core I/O fault only after real native
                    // preparation and PAM consent. All restart commands use the
                    // ordinary production owner, scheduler and keyring paths.
                    let event = match event {
                        Event::Command(command) if interruption.is_some() => match *command {
                            Command::CommitRestoration { token, permit } => {
                                let fault = interruption.take().unwrap().fault();
                                let reply = (|| {
                                    let review = owner.restoration.consume(token)?;
                                    owner.transport = None;
                                    owner.selected = None;
                                    let failure = restoration::apply_with_fault(
                                        owner.store.as_mut().ok_or(Failure::InvalidState)?,
                                        review,
                                        permit,
                                        Some(fault),
                                    )
                                    .err()
                                    .map(Failure::from);
                                    Ok(Reply::Restored {
                                        failure,
                                        cancelled: false,
                                    })
                                })();
                                return (Some(reply), owner.pending.is_some(), owner.automatic);
                            }
                            command => Event::Command(Box::new(command)),
                        },
                        event => event,
                    };
                    Self::owner_event(&mut owner, event)
                })
            })
        })
    }
    fn now() -> Duration {
        crate::clock::uptime().unwrap_or(Duration::ZERO)
    }
    #[cfg(test)]
    fn spawn(
        mut operate: impl FnMut(Command) -> (Result<Reply>, bool) + Send + 'static,
    ) -> Result<Self> {
        let mut retained = false;
        let mut state = Automatic::OFF;
        Self::spawn_events(Control::new(), move |event| match event {
            Event::Command(command) => {
                let (reply, pending) = operate(*command);
                retained = pending;
                if let Ok(Reply::Automatic(value)) = &reply {
                    state = *value;
                }
                (Some(reply), pending, state)
            }
            _ => (None, retained, state),
        })
    }
    fn spawn_events(
        control: Arc<Control>,
        mut operate: impl FnMut(Event) -> (Option<Result<Reply>>, bool, Automatic) + Send + 'static,
    ) -> Result<Self> {
        let (sender, receiver) = mpsc::channel::<Task>();
        let pending = Arc::new(AtomicBool::new(false));
        let in_flight = Arc::new(AtomicUsize::new(0));
        let automatic = Arc::new(Mutex::new(Automatic::OFF));
        let wake = Arc::new(AtomicU8::new(0));
        let p = pending.clone();
        let count = in_flight.clone();
        let state = automatic.clone();
        let waking = wake.clone();
        let cancellation = control.clone();
        #[cfg(test)]
        let interrupt_handover = Arc::new(AtomicU8::new(0));
        #[cfg(test)]
        let interruption = interrupt_handover.clone();
        std::thread::Builder::new()
            .name("snippets-account".into())
            .spawn(move || {
                loop {
                    let task = match receiver.recv_timeout(Duration::from_millis(250)) {
                        Ok(task) => Some(task),
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => None,
                    };
                    if task.is_none() {
                        // Admission and quit use sequentially consistent atomics:
                        // quit either sees this cycle or fences it before I/O.
                        let waiting = count.fetch_add(1, Ordering::SeqCst);
                        if waiting != 0 || cancellation.quitting() || cancellation.is_paused() {
                            count.fetch_sub(1, Ordering::SeqCst);
                            continue;
                        }
                        let flags = waking.swap(0, Ordering::AcqRel);
                        if flags != 0 {
                            let reason = if flags & 1 != 0 {
                                Wake::Foreground
                            } else {
                                Wake::LocalEdit
                            };
                            let _ = operate(Event::Wake(reason));
                        }
                    }
                    let (reply, retained, automatic) = match task {
                        Some(task) => {
                            #[cfg(test)]
                            let interrupt =
                                if matches!(&task.command, Command::CommitHandover { .. }) {
                                    match interruption.swap(0, Ordering::SeqCst) {
                                        0 => None,
                                        1 => Some(handover::Interruption::BeforePublication),
                                        2 => Some(handover::Interruption::BeforeActivation),
                                        _ => unreachable!("invalid native handover interruption"),
                                    }
                                } else {
                                    None
                                };
                            #[cfg(test)]
                            let (reply, retained, automatic) = if let Some(point) = interrupt {
                                handover::with_interruption(point, || {
                                    operate(Event::Command(Box::new(task.command)))
                                })
                            } else {
                                operate(Event::Command(Box::new(task.command)))
                            };
                            #[cfg(not(test))]
                            let (reply, retained, automatic) =
                                operate(Event::Command(Box::new(task.command)));
                            p.store(retained, Ordering::Release);
                            *state.lock().unwrap_or_else(|p| p.into_inner()) = automatic;
                            count.fetch_sub(1, Ordering::SeqCst);
                            if let Some(reply) = reply {
                                let _ = task.response.send(reply);
                            }
                            continue;
                        }
                        None => operate(Event::Tick),
                    };
                    // Publication precedes the count decrement: quit cannot slip
                    // between a completed issuance and retained in-memory ownership.
                    p.store(retained, Ordering::Release);
                    *state.lock().unwrap_or_else(|p| p.into_inner()) = automatic;
                    count.fetch_sub(1, Ordering::SeqCst);
                    debug_assert!(reply.is_none());
                }
            })
            .map_err(|_| Failure::WorkerStopped)?;
        Ok(Self {
            sender,
            pending,
            in_flight,
            control,
            automatic,
            wake,
            #[cfg(test)]
            interrupt_handover,
        })
    }
    #[cfg(test)]
    pub(crate) fn interrupt_next_handover(&self, point: handover::Interruption) {
        assert_eq!(
            self.interrupt_handover.swap(point as u8, Ordering::SeqCst),
            0
        );
    }
    pub(crate) fn request(&self, command: Command) -> Result<mpsc::Receiver<Result<Reply>>> {
        let (response, receiver) = mpsc::sync_channel(1);
        self.in_flight.fetch_add(1, Ordering::SeqCst);
        // Async cancellation cleanup is not a new foreground continuation.
        if !matches!(&command, Command::CancelVaultSync) {
            self.control.cancel_quit();
        }
        self.control.pause();
        if self.sender.send(Task { command, response }).is_err() {
            self.in_flight.fetch_sub(1, Ordering::SeqCst);
            return Err(Failure::WorkerStopped);
        }
        Ok(receiver)
    }
    pub(crate) fn can_quit(&self) -> bool {
        self.in_flight.load(Ordering::SeqCst) == 0 && !self.pending.load(Ordering::Acquire)
    }
    pub(crate) fn prepare_quit(&self) -> bool {
        self.control.prepare_quit();
        self.can_quit()
    }
    pub(crate) fn cancel_quit(&self) {
        self.control.cancel_quit();
    }
    pub(crate) fn automatic(&self) -> Automatic {
        *self.automatic.lock().unwrap_or_else(|p| p.into_inner())
    }
    pub(crate) fn wake(&self, reason: Wake) {
        self.wake.fetch_or(
            if reason == Wake::Foreground { 1 } else { 2 },
            Ordering::Release,
        );
    }
    pub(crate) fn retention_required(&self) -> bool {
        self.pending.load(Ordering::Acquire)
    }
    #[cfg(test)]
    pub(crate) fn controlled(
        operate: impl FnMut(Command) -> (Result<Reply>, bool) + Send + 'static,
    ) -> Self {
        Self::spawn(operate).unwrap()
    }
    #[cfg(test)]
    pub(crate) fn fixture() -> Self {
        Self::spawn(|command| {
            (
                match command {
                    Command::InspectHistory => {
                        Ok(Reply::History(key_store::history::Catalog::default()))
                    }
                    Command::Inspect => Ok(Reply::Profile {
                        account: None,
                        server: None,
                        interrupted: false,
                        switching: handover::Status::default(),
                        device: None,
                    }),
                    Command::PrepareDeletionReview => Ok(Reply::DeletionReview {
                        token: uuid::Uuid::from_u128(900),
                        summary: deletion_review::Summary {
                            kind: deletion_review::Kind::LocalAbsence,
                            name: "Public protected copy fixture".into(),
                            keyword: "publiccopy".into(),
                            secure: true,
                            can_keep: true,
                            keep_requires_vault: true,
                            delete_requires_vault: true,
                            preserved_source_versions: 0,
                            restored_conflict_copies: 0,
                            preserved_conflict_copies: 0,
                            prerequisite: false,
                        },
                    }),
                    Command::DecideDeletionReview {
                        token,
                        choice,
                        credential,
                    } if token == uuid::Uuid::from_u128(900)
                        && credential.as_ref().is_some_and(|(value, recovery)| {
                            value.as_str() == "Public vault passphrase fixture" && !recovery
                        }) =>
                    {
                        Ok(Reply::DeletionDecided {
                            kind: deletion_review::Kind::LocalAbsence,
                            choice,
                        })
                    }
                    _ => Err(Failure::InvalidState),
                },
                false,
            )
        })
        .unwrap()
    }
}
struct Owner {
    root: PathBuf,
    store: Option<Store<Native>>,
    client: Option<CloudClient>,
    live: Option<LiveSession>,
    /// The decoded request between its owner authorization and the approval.
    device_approval: Option<crate::bootstrap::DeviceSignIn>,
    spaces: Vec<Space>,
    selected: Option<Space>,
    transport: Option<BoundTransport>,
    pending: Option<Pending>,
    snapshot_review: Option<(uuid::Uuid, Box<snapshot_review::Review>)>,
    deletion_review: Option<(uuid::Uuid, Box<deletion_review::Review>)>,
    vault_sync: Option<vault_sync::Request>,
    handover_review: Option<(uuid::Uuid, Box<handover::Review>)>,
    creation_review: Option<(uuid::Uuid, creation::NewIntent)>,
    restoration: restoration_task::Retained,
    history_removal: history_removal::Retained,
    control: Arc<Control>,
    preference: Option<Preference>,
    schedule: Option<Schedule>,
    automatic: Automatic,
}
enum DataAction {
    Receive,
    Send,
    Sync,
    PrepareVaultSync(vault_sync::Authorization),
    PrepareSnapshotReview,
    ResumeSnapshotReview(Box<snapshot_review::Review>),
    PrepareDeletionReview,
    DecideDeletionReview(
        Box<deletion_review::Review>,
        deletion_review::Choice,
        Option<Box<crate::vault::Vault>>,
    ),
}
enum DataReply {
    Reply(Box<Reply>),
    Review(Box<snapshot_review::Review>),
    DeletionReview(Box<deletion_review::Review>),
    VaultSync(Box<vault_sync::Request>),
}
enum PairingAction {
    Begin,
    Check,
    Cancel,
}
impl Owner {
    fn new(root: PathBuf, control: Arc<Control>) -> Self {
        Self {
            root,
            store: None,
            client: None,
            live: None,
            device_approval: None,
            spaces: vec![],
            selected: None,
            transport: None,
            pending: None,
            snapshot_review: None,
            deletion_review: None,
            vault_sync: None,
            handover_review: None,
            creation_review: None,
            restoration: restoration_task::Retained::default(),
            history_removal: history_removal::Retained::default(),
            control,
            preference: None,
            schedule: None,
            automatic: Automatic::OFF,
        }
    }
    fn ensure_store(&mut self, initialize: bool) -> Result<()> {
        if self.store.is_none() {
            let backend = Native::new()?;
            self.store = Some(if initialize {
                Store::initialize(&self.root, backend)?
            } else {
                Store::load(&self.root, backend)?
            });
        }
        Ok(())
    }
    fn disable_automatic(&mut self) -> Result<()> {
        self.control.pause();
        // An absent default preference stays absent. Disable never needs a
        // keyring or the primary documents, including during local recovery.
        match Preference::read(&self.root) {
            Ok(preference) if !preference.enabled() => (),
            _ => Preference::off(&self.root)?,
        }
        self.preference = Some(Preference::read(&self.root)?);
        self.schedule = None;
        self.automatic = Automatic::OFF;
        Ok(())
    }
    fn handle_scheduled(&mut self, command: Command) -> Result<Reply> {
        let operation = diagnostic::operation(&command);
        let started = std::time::Instant::now();
        let result = self.handle_scheduled_inner(command);
        if let Some(operation) = operation
            && !diagnostic::quiet(operation, &result)
        {
            crate::diagnostics::record(diagnostic::event(operation, started, &result));
        }
        result
    }
    fn handle_scheduled_inner(&mut self, command: Command) -> Result<Reply> {
        let keep = command.keeps_automatic() && !matches!(command, Command::Automatic(false));
        if !command.keeps_automatic() || matches!(command, Command::Automatic(false)) {
            self.disable_automatic()?;
        }
        let result = self.handle(command);
        if keep && self.pending.is_none() && self.vault_sync.is_none() {
            self.control.resume();
        }
        result
    }
    fn enable_automatic(&mut self) -> Result<Reply> {
        crate::backup::import::require_clear(&self.root).map_err(|_| Failure::InvalidState)?;
        self.check_owner()?;
        let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
        let transport = self.transport.as_mut().ok_or(Failure::InvalidState)?;
        let binding = transport.key_binding()?;
        key_store::check_admission(store, &binding)?;
        let key = key_store::load_verified(store, transport)?
            .ok_or(Failure::Key(key_store::Failure::KeyConflict))?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let deployment = self
            .client
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .credential_deployment();
        let target = store.transaction_with::<_, Failure>(|owner| {
            live.validate_owner(owner, &deployment)?;
            key.validate_owner(owner)?;
            let archive = auth_store::Archive::load(owner)?;
            let target = Target::new(
                key.binding().clone(),
                &deployment,
                archive.account_for_refresh(&deployment)?,
            )?;
            target.save(owner)?;
            Ok(target)
        })?;
        Preference::on(&self.root, &target)?;
        self.preference = Some(Preference::read(&self.root)?);
        self.schedule = Some(Schedule::new(Handle::now()));
        self.automatic = Automatic {
            enabled: true,
            status: AutomaticStatus::Scheduled,
            failure: None,
        };
        self.control.resume();
        Ok(Reply::Automatic(self.automatic))
    }
    fn tick(&mut self) {
        let preference = match Preference::read(&self.root) {
            Ok(value) => value,
            Err(failure) => {
                self.schedule = None;
                self.automatic = Automatic {
                    enabled: false,
                    status: AutomaticStatus::Attention,
                    failure: Some(failure.into()),
                };
                return;
            }
        };
        if self.preference != Some(preference) {
            self.preference = Some(preference);
            self.schedule = preference.enabled().then(|| Schedule::new(Handle::now()));
            self.automatic = if preference.enabled() {
                Automatic {
                    enabled: true,
                    status: AutomaticStatus::Scheduled,
                    failure: None,
                }
            } else {
                Automatic::OFF
            };
        }
        if !preference.enabled() || self.control.is_paused() || self.pending.is_some() {
            return;
        }
        let Some(schedule) = self.schedule.as_mut() else {
            return;
        };
        if !schedule.begin(Handle::now()) {
            return;
        }
        let result = self
            .control
            .ticket(&self.root, preference)
            .map_err(Failure::from)
            .and_then(|ticket| {
                let result = self.automatic_cycle(&ticket, preference);
                if ticket.validate().is_err() {
                    Err(auto_sync::Failure::Cancelled.into())
                } else {
                    result
                }
            });
        let retry_after = match &result {
            Err(Failure::Cloud(cloud::Failure::Server { retry_after, .. })) => *retry_after,
            Ok(Reply::Synchronized(data_sync::Progress {
                status:
                    data_sync::Status::Sending(sender::Status::ServerDeferred { retry_after, .. }),
                ..
            })) => *retry_after,
            _ => None,
        };
        let (outcome, status, failure) = automatic_outcome(result);
        if let Some(schedule) = self.schedule.as_mut() {
            let now = Handle::now();
            schedule.finish(outcome, now);
            if outcome == auto_sync::Outcome::Retry
                && let Some(delay) = retry_after
            {
                schedule.defer(now, Duration::from_secs(u64::from(delay)));
            }
        }
        self.automatic = Automatic {
            enabled: true,
            status,
            failure,
        };
    }
    fn automatic_cycle(&mut self, ticket: &Ticket, preference: Preference) -> Result<Reply> {
        ticket.validate()?;
        // Check only the recovery marker before contacting the service. No
        // primary content is read until exact remote scope/key admission.
        crate::backup::import::require_clear(&self.root).map_err(|_| {
            Failure::Receive(receiver::Failure::Primary(
                crate::primary::Failure::RecoveryRequired,
            ))
        })?;
        self.ensure_store(false)?;
        let (target, deployment) = self
            .store
            .as_mut()
            .ok_or(Failure::InvalidState)?
            .transaction_with::<_, Failure>(|owner| {
                ticket.validate()?;
                let target = Target::load(owner, preference)?;
                let archive = auth_store::Archive::load(owner)?;
                let deployment = archive.saved_deployment()?.ok_or(Failure::InvalidState)?;
                target.validate_account(&deployment, archive.account_for_refresh(&deployment)?)?;
                key_store::check_admission_locked(owner, target.binding())?;
                Ok((target, deployment))
            })?;
        ticket.validate()?;
        let refresh = match self.live.as_ref() {
            None => true,
            Some(live) => match live.access() {
                Ok(_) => {
                    self.check_owner()?;
                    false
                }
                Err(auth_store::Failure::Expired) => true,
                Err(failure) => return Err(failure.into()),
            },
        };
        if refresh {
            self.live = None;
            self.disconnect_transport();
            ticket.validate()?;
            let client = deployment.discover()?;
            ticket.validate()?;
            let result = auth_store::refresh_bound(
                self.store.as_mut().ok_or(Failure::InvalidState)?,
                &client,
                &|| ticket.validate().map_err(|_| auth_store::Failure::Stale),
                &|deployment, account| {
                    target
                        .validate_account(deployment, account)
                        .map_err(|_| auth_store::Failure::WrongDeployment)
                },
            );
            // Retain an already issued grant even when cancellation arrives
            // while the blocking HTTP request is in flight.
            let live = result.map_err(|failure| self.rejected(failure))?;
            self.client = Some(client);
            self.live = Some(live);
            ticket.validate()?;
        }
        self.check_owner()?;
        let client = self.client.as_ref().ok_or(Failure::InvalidState)?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        ticket.validate()?;
        client.preflight_credentials()?;
        ticket.validate()?;
        // Never list/select the first library and never run key setup here.
        let space = client.observe_space(live.access()?, target.binding().space())?;
        ticket.validate()?;
        let binding = client.key_binding_for_observation(&space)?;
        target.validate_binding(&binding)?;
        let identities = binding.checkpoint_scope();
        let token = cloud::Credential::new(
            std::str::from_utf8(live.access()?.for_secure_storage())
                .map_err(|_| Failure::InvalidState)?
                .into(),
        )?;
        let transport = client.clone().admit(
            token,
            space.clone(),
            &identities.membership,
            &identities.dataset,
        )?;
        self.check_owner()?;
        ticket.validate()?;
        self.transport = Some(transport);
        let action = if space.role == cloud::Role::Reader {
            DataAction::Receive
        } else {
            DataAction::Sync
        };
        self.selected = Some(space);
        self.data_action_checked(action, Some(ticket))
    }
    fn profile(&mut self) -> Result<Reply> {
        match self.ensure_store(false) {
            Err(Failure::Secret(secret_store::Failure::MissingOwner)) => {
                return Ok(Reply::Profile {
                    account: None,
                    server: None,
                    interrupted: false,
                    switching: handover::Status::default(),
                    device: None,
                });
            }
            result => result?,
        }
        let switching = handover::inspect(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
        let device =
            auth_store::device::inspect(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
        self.store
            .as_mut()
            .ok_or(Failure::InvalidState)?
            .transaction_with(|o| {
                let archive = auth_store::Archive::load(o)?;
                match archive.saved_deployment() {
                    Ok(deployment) => Ok(Reply::Profile {
                        account: archive.profile_account()?,
                        server: deployment.map(|d| d.server().clone()),
                        interrupted: false,
                        switching,
                        device,
                    }),
                    Err(auth_store::Failure::Busy) => Ok(Reply::Profile {
                        account: None,
                        server: None,
                        interrupted: true,
                        switching,
                        device,
                    }),
                    Err(failure) => Err(failure.into()),
                }
            })
    }
    fn connected(&mut self, created: Option<uuid::Uuid>) -> Result<Reply> {
        self.check_owner()?;
        let client = self.client.as_ref().ok_or(Failure::InvalidState)?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let creation = creation::status(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            client,
            live,
        );
        if let Err(e @ (creation::Failure::Account(_) | creation::Failure::Secret(_))) = creation {
            return Err(e.into());
        }
        client.preflight_credentials()?;
        self.spaces = client.list_spaces(live.access()?)?;
        client.preflight_credentials()?;
        live.access()?;
        let reply = Reply::Libraries {
            account: live.account_display()?,
            server: client.credential_deployment().server().clone(),
            spaces: self.spaces.clone(),
            creation,
            can_create_new: creation::can_begin_new(
                self.store.as_mut().ok_or(Failure::InvalidState)?,
                client,
                live,
            ),
            created,
            switching: handover::inspect(self.store.as_mut().ok_or(Failure::InvalidState)?)?,
        };
        self.check_owner()?;
        Ok(reply)
    }
    /// Create and sign-in share one interactive issuance path: they drop any live
    /// session, finish retained credential cleanup and pin a freshly discovered
    /// deployment before the serialized credential owner journals the grant.
    fn begin_interactive(&mut self, server: &str) -> Result<CloudClient> {
        let server = ServerURL::parse(server)?;
        self.live = None;
        self.disconnect_transport();
        self.client = None;
        self.ensure_store(true)?;
        auth_store::recover(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
        Ok(CloudClient::discover(server)?)
    }
    /// One poll of a signed-out device's request, or the continuation of an
    /// already approved one. Polling failures keep the request and its display.
    fn check_device_sign_in(&mut self) -> Result<Reply> {
        use auth_store::device::{self, Claim, Status};
        self.ensure_store(false)?;
        let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
        let Some(status) = device::inspect(store)? else {
            return self.profile();
        };
        if matches!(status, Status::Approved) {
            if self.live.is_none() {
                self.reconnect()?;
            }
            return self.finish_device_sign_in();
        }
        // Like account-key sign-in, a retry after a rejected commit first finishes
        // that attempt's journaled cleanup, so the next issuance is not refused
        // as busy; the server revokes the earlier family on the next claim.
        if let Err(failure) = auth_store::recover(store) {
            return Ok(Self::device_waiting(status, failure.into()));
        }
        let deployment = device::saved_deployment(store)?.ok_or(Failure::InvalidState)?;
        let client = match &self.client {
            Some(client) if client.credential_deployment() == deployment => client.clone(),
            _ => match deployment.discover() {
                Ok(client) => client,
                Err(failure) => return Ok(Self::device_waiting(status, failure.into())),
            },
        };
        self.client = Some(client.clone());
        let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
        let grant = match device::claim(store, &client) {
            Ok(Claim::Pending(payload)) => {
                return Ok(Reply::DeviceSignIn {
                    state: Some(Status::Waiting(payload)),
                    retry_after: None,
                    failure: None,
                });
            }
            Ok(Claim::Approved(grant)) => grant,
            Err(failure) => return Ok(Self::device_waiting(status, failure.into())),
        };
        let result = auth_store::sign_in_with_device(store, &client, *grant);
        let (live, approval) = result.map_err(|e| self.rejected(e))?;
        self.live = Some(live);
        device::record_approval(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            &deployment,
            approval,
        )?;
        self.finish_device_sign_in()
    }
    fn device_waiting(status: auth_store::device::Status, failure: Failure) -> Reply {
        let retry_after = match failure {
            Failure::Cloud(cloud::Failure::Server { retry_after, .. }) => retry_after,
            _ => None,
        };
        Reply::DeviceSignIn {
            state: Some(status),
            retry_after,
            failure: Some(failure),
        }
    }
    /// Lists libraries, selects exactly the approved one without a chooser
    /// (failing closed when it is absent), then claims its key with this
    /// device's retained recipient material through the recipient journal.
    fn finish_device_sign_in(&mut self) -> Result<Reply> {
        let approval =
            auth_store::device::saved_approval(self.store.as_mut().ok_or(Failure::InvalidState)?)?
                .ok_or(Failure::InvalidState)?;
        let libraries = Box::new(self.connected(None)?);
        let Some(index) = self.spaces.iter().position(|s| s.id() == approval.space) else {
            return Ok(Reply::DeviceSignedIn {
                libraries,
                library: None,
                selected: None,
                keys: None,
                failure: Some(Failure::DeviceLibraryUnavailable),
            });
        };
        let selected = match self.select(index) {
            Ok(reply) => reply,
            Err(failure) => {
                return Ok(Reply::DeviceSignedIn {
                    libraries,
                    library: None,
                    selected: None,
                    keys: None,
                    failure: Some(failure),
                });
            }
        };
        let (store, transport) = self.parts()?;
        let (keys, failure) = match recipient::adopt_device_sign_in(store, transport) {
            Ok(recipient::Outcome::Ready { kit }) => {
                (Some(Ok(key_store::Outcome::Ready { kit })), None)
            }
            Ok(_) => (None, Some(Failure::InvalidState)),
            Err(error) => {
                let failure = if let Some(owner) = error.unrecorded {
                    self.pending = Some(Pending::Pairing(owner));
                    Failure::RetentionRequired
                } else {
                    error.failure.into()
                };
                (None, Some(failure))
            }
        };
        self.check_owner()?;
        Ok(Reply::DeviceSignedIn {
            libraries,
            library: Some(approval.space),
            selected: Some(Box::new(selected)),
            keys,
            failure,
        })
    }
    /// The saved-session refresh behind Reconnect Saved Account.
    fn reconnect(&mut self) -> Result<()> {
        self.live = None;
        self.disconnect_transport();
        self.ensure_store(false)?;
        let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
        auth_store::recover(store)?;
        let deployment = store.transaction_with::<_, auth_store::Failure>(|o| {
            auth_store::Archive::load(o)?
                .saved_deployment()?
                .ok_or(auth_store::Failure::InvalidState)
        })?;
        let client = deployment.discover()?;
        let result = auth_store::refresh(store, &client);
        let live = result.map_err(|e| self.rejected(e))?;
        self.disconnect_transport();
        self.client = Some(client);
        self.live = Some(live);
        Ok(())
    }
    fn select(&mut self, index: usize) -> Result<Reply> {
        self.check_owner()?;
        let space = self
            .spaces
            .get(index)
            .cloned()
            .ok_or(Failure::InvalidState)?;
        self.transport = None;
        self.selected = None;
        let client = self.client.as_ref().ok_or(Failure::InvalidState)?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let space = client.observe_space(live.access()?, space.id())?;
        let binding = client.key_binding_for_observation(&space)?;
        let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
        let admission = key_store::check_admission(store, &binding);
        if let Err(failure) = admission
            && !matches!(
                failure,
                key_store::Failure::ReviewRequired
                    | key_store::Failure::KeyConflict
                    | key_store::Failure::Busy
            )
        {
            return Err(failure.into());
        }
        let token = cloud::Credential::new(
            std::str::from_utf8(live.access()?.for_secure_storage())
                .map_err(|_| Failure::InvalidState)?
                .into(),
        )?;
        let identities = space
            .scope
            .identities(client.credential_deployment().server());
        let mut transport =
            client
                .clone()
                .admit(token, space.clone(), &identities.0, &identities.1)?;
        // Selection itself does not generate a library key. Setup is a
        // separate explicit action, even for an empty remote library.
        let key = admission.and_then(|_| key_store::load_verified(store, &mut transport));
        self.transport = Some(transport);
        self.selected = Some(space);
        let outcome = match key {
            Ok(Some(_)) => {
                key_store::initialize(store, self.transport.as_mut().ok_or(Failure::InvalidState)?)
            }
            Ok(None) => Ok(key_store::Outcome::NeedsTrustedDeviceOrRecovery),
            Err(failure) => Err(failure),
        };
        let pairing = recipient::inspect_retained(
            store,
            self.transport.as_ref().ok_or(Failure::InvalidState)?,
        );
        let mutation = mutations::inspect_retained(
            store,
            self.transport.as_ref().ok_or(Failure::InvalidState)?,
        );
        let switching = handover::inspect(store)?;
        let pending_matches = handover::matches_pending(store, &binding)?;
        let candidate = candidate::inspect(store, &binding);
        let bootstrap = initial_candidate::inspect(store, &binding);
        let can_create_new = creation::can_begin_new(
            store,
            self.client.as_ref().ok_or(Failure::InvalidState)?,
            self.live.as_ref().ok_or(Failure::InvalidState)?,
        );
        self.check_owner()?;
        Ok(Reply::Selected {
            role: self.selected.as_ref().ok_or(Failure::InvalidState)?.role,
            can_create_new,
            keys: outcome,
            pairing,
            mutation,
            switching,
            pending_matches,
            candidate,
            bootstrap,
        })
    }
    fn disconnect_transport(&mut self) {
        self.creation_review = None;
        self.transport = None;
        self.selected = None;
        self.spaces.clear();
    }
    fn check_live(&self) -> Result<()> {
        self.live.as_ref().ok_or(Failure::InvalidState)?.access()?;
        Ok(())
    }
    fn check_owner(&mut self) -> Result<()> {
        self.check_live()?;
        auth_store::validate_session(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.client.as_ref().ok_or(Failure::InvalidState)?,
            self.live.as_ref().ok_or(Failure::InvalidState)?,
        )?;
        Ok(())
    }
    fn parts(&mut self) -> Result<(&mut Store<Native>, &mut BoundTransport)> {
        self.check_owner()?;
        Ok((
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.transport.as_mut().ok_or(Failure::InvalidState)?,
        ))
    }
    fn data_action(&mut self, action: DataAction) -> Result<Reply> {
        self.data_action_checked(action, None)
    }
    fn data_action_checked(
        &mut self,
        action: DataAction,
        ticket: Option<&Ticket>,
    ) -> Result<Reply> {
        self.data_action_with_vault(action, ticket, None)
    }
    fn data_action_with_vault(
        &mut self,
        action: DataAction,
        ticket: Option<&Ticket>,
        authenticated: Option<&vault_sync::Authenticated>,
    ) -> Result<Reply> {
        let check = || -> Result<()> {
            ticket.map_or(Ok(()), Ticket::validate)?;
            authenticated.map_or(Ok(()), vault_sync::Authenticated::validate)
        };
        check()?;
        self.check_owner()?;
        let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
        let transport = self.transport.as_mut().ok_or(Failure::InvalidState)?;
        let key = key_store::load_verified_checked(store, transport, &|| {
            check().map_err(|_| key_store::Failure::Busy)
        })?
        .ok_or(Failure::Key(key_store::Failure::KeyConflict))?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let deployment = self
            .client
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .credential_deployment();
        let library =
            crate::model::Library::prepare(self.root.clone()).map_err(|_| Failure::InvalidState)?;
        let reply = store.transaction_with::<_, Failure>(|locked| {
            check()?;
            live.validate_owner(locked, &deployment)?;
            key.validate_owner(locked)?;
            // Explicit sync or saved, verified opt-in may create material.
            // Lost material beside existing ciphertext or a marker fails closed.
            let material = locked
                .checkpoint_material(true)?
                .ok_or(Failure::InvalidState)?;
            let checkpoint_key = crate::crypto::RootKey::from_bytes(&material[..32])
                .map_err(|_| Failure::InvalidState)?;
            let checkpoint_salt = material[32..]
                .try_into()
                .map_err(|_| Failure::InvalidState)?;
            let scope = key.binding().checkpoint_scope();
            let epoch = key.binding().key_epoch();
            if let Some(authenticated) = authenticated {
                authenticated.bind(&scope, epoch)?;
            }
            let locked = std::cell::RefCell::new(locked);
            let guard = || {
                check().map_err(|_| receiver::Failure::SessionChanged)?;
                let mut owner = locked.borrow_mut();
                live.validate_owner(&mut owner, &deployment)
                    .map_err(|_| receiver::Failure::SessionChanged)?;
                key.validate_owner(&mut owner)
                    .map_err(|_| receiver::Failure::SessionChanged)
            };
            // Hold the credential owner lock for the whole bounded cycle;
            // primary's common file lock is held only for local transactions.
            key.with_wire_key(|wire_key, wire_salt| {
                let vault_keys = authenticated
                    .map(vault_sync::Authenticated::keys)
                    .transpose()?;
                let owner = receiver::Owner {
                    library: &library,
                    scope: &scope,
                    key_epoch: epoch,
                    checkpoint_key: &checkpoint_key,
                    checkpoint_salt: &checkpoint_salt,
                    wire_key,
                    wire_salt,
                    device: None,
                    vault_keys: vault_keys.as_ref(),
                    validate_session: &guard,
                };
                match action {
                    DataAction::PrepareVaultSync(authorization) => {
                        check()?;
                        vault_sync::Request::capture(&self.root, &scope, epoch, authorization)
                            .map(Box::new)
                            .map(DataReply::VaultSync)
                    }
                    DataAction::Sync => owner
                        .synchronize(transport, data_sync::Limits::DEFAULT)
                        .map(Reply::Synchronized)
                        .map(Box::new)
                        .map(DataReply::Reply)
                        .map_err(Failure::from),
                    DataAction::Send => owner
                        .send(transport, 4)
                        .map(Reply::Sent)
                        .map(Box::new)
                        .map(DataReply::Reply)
                        .map_err(Failure::from),
                    DataAction::Receive => owner
                        .receive(transport, 4)
                        .map(Reply::Received)
                        .map(Box::new)
                        .map(DataReply::Reply)
                        .map_err(Failure::from),
                    DataAction::PrepareSnapshotReview => owner
                        .prepare_missing_snapshot_review(transport)
                        .map(Box::new)
                        .map(DataReply::Review)
                        .map_err(Failure::from),
                    DataAction::ResumeSnapshotReview(review) => owner
                        .resume_missing_snapshot_review(transport, *review)
                        .map(Reply::SnapshotResumed)
                        .map(Box::new)
                        .map(DataReply::Reply)
                        .map_err(Failure::from),
                    DataAction::PrepareDeletionReview => owner
                        .prepare_deletion_review(transport)
                        .map(Box::new)
                        .map(DataReply::DeletionReview)
                        .map_err(Failure::from),
                    DataAction::DecideDeletionReview(review, choice, mut vault) => owner
                        .decide_deletion_review_with_vault(
                            transport,
                            *review,
                            choice,
                            vault.as_deref_mut(),
                        )
                        .map(|kind| Box::new(Reply::DeletionDecided { kind, choice }))
                        .map(DataReply::Reply)
                        .map_err(Failure::from),
                }
            })
        })?;
        check()?;
        self.check_owner()?;
        match reply {
            DataReply::Reply(reply) => Ok(*reply),
            DataReply::Review(review) => {
                let token = uuid::Uuid::new_v4();
                let summary = review.summary();
                self.snapshot_review = Some((token, review));
                Ok(Reply::SnapshotReview { token, summary })
            }
            DataReply::DeletionReview(review) => {
                let token = uuid::Uuid::new_v4();
                let summary = review.summary();
                self.deletion_review = Some((token, review));
                Ok(Reply::DeletionReview { token, summary })
            }
            DataReply::VaultSync(request) => {
                let (token, methods) = request.presentation();
                self.vault_sync = Some(*request);
                Ok(Reply::VaultSync { token, methods })
            }
        }
    }
    fn rejected(&mut self, error: auth_store::Rejected) -> Failure {
        self.pending = error.unrecorded.map(Pending::Account);
        if self.pending.is_some() {
            Failure::RetentionRequired
        } else {
            error.failure.into()
        }
    }
    fn mutation_target(&mut self, target: local_auth::Target) -> Result<Reply> {
        self.check_owner()?;
        let retained = mutations::inspect_retained(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.transport.as_ref().ok_or(Failure::InvalidState)?,
        )?
        .ok_or(Failure::InvalidState)?;
        Ok(Reply::MutationTarget { target, retained })
    }
    fn mutation_prepared(
        &mut self,
        result: key_store::Result<local_auth::Target>,
    ) -> Result<Reply> {
        match result
            .map_err(Failure::from)
            .and_then(|target| self.mutation_target(target))
        {
            Ok(reply) => Ok(reply),
            Err(failure) => Ok(self.mutation_status(None, Some(failure))),
        }
    }
    fn mutation_status(
        &mut self,
        outcome: Option<mutations::Outcome>,
        failure: Option<Failure>,
    ) -> Reply {
        let state = match (self.store.as_mut(), self.transport.as_ref()) {
            (Some(store), Some(transport)) => mutations::inspect_retained(store, transport),
            _ => Err(key_store::Failure::InvalidState),
        };
        Reply::Mutation {
            state,
            outcome,
            failure,
        }
    }
    fn review_vault(
        &self,
        credential: Option<(Zeroizing<String>, bool)>,
    ) -> Result<Option<crate::vault::Vault>> {
        let Some((credential, recovery)) = credential else {
            return Ok(None);
        };
        restoration_task::unlock_current(
            &self.root,
            &restoration_task::Credential {
                value: credential,
                recovery,
            },
            &|| Ok(()),
        )
        .map(Some)
    }
    fn handle(&mut self, command: Command) -> Result<Reply> {
        if !matches!(&command, Command::ContinueVaultSync { .. }) {
            self.vault_sync = None;
        }
        if matches!(&command, Command::CancelVaultSync) {
            return Ok(Reply::Saved);
        }
        if !matches!(&command, Command::CreateNewLibrary(_)) {
            self.creation_review = None;
        }
        if matches!(command, Command::Automatic(false)) {
            return Ok(Reply::Automatic(Automatic::OFF));
        }
        if self.pending.is_some() && !matches!(&command, Command::Retain | Command::Inspect) {
            return Err(Failure::RetentionRequired);
        }
        if !matches!(&command, Command::ResumeSnapshotReview(_)) {
            self.snapshot_review = None;
        }
        if !matches!(&command, Command::DecideDeletionReview { .. }) {
            self.deletion_review = None;
        }
        if !matches!(
            &command,
            Command::CommitHandover { .. } | Command::Authenticate { .. }
        ) {
            self.handover_review = None;
        }
        if !matches!(
            &command,
            Command::ApproveDevice(_) | Command::Authenticate { .. }
        ) {
            self.device_approval = None;
        }
        self.restoration.keep_for(&command);
        self.history_removal.keep_for(&command);
        match command {
            Command::PrepareRecoveryFileCleanup(preparation) => {
                preparation.validate()?;
                self.ensure_store(false)?;
                self.history_removal.prepare_cleanup(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    preparation,
                )
            }
            Command::PrepareHistoryRemoval {
                selection,
                preparation,
            } => {
                preparation.validate()?;
                self.ensure_store(false)?;
                self.history_removal.prepare(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    selection,
                    preparation,
                )
            }
            Command::CommitHistoryRemoval { token, permit } => {
                let review = self.history_removal.consume(token)?;
                let cleanup = review.summary().section == capacity::Section::UnusedImages;
                capacity::apply(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    review,
                    permit,
                )
                .map_err(Failure::HistoryRemoval)?;
                Ok(if cleanup {
                    Reply::RecoveryFilesCleaned
                } else {
                    Reply::HistoryRemoved
                })
            }
            Command::Automatic(true) => self.enable_automatic(),
            Command::Automatic(false) => unreachable!(),
            Command::PrepareRestoration {
                selection,
                credentials,
                preparation,
                source_file,
            } => {
                preparation.validate()?;
                self.ensure_store(false)?;
                self.restoration.prepare(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    selection,
                    credentials,
                    preparation,
                    source_file,
                )
            }
            Command::InspectRestorationFile {
                selection,
                path,
                preparation,
            } => {
                preparation.validate()?;
                self.ensure_store(false)?;
                self.restoration.inspect(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    &selection,
                    &path,
                    preparation,
                )
            }
            Command::CommitRestoration { token, permit } => {
                let review = self.restoration.consume(token)?;
                self.transport = None;
                self.selected = None;
                let failure = restoration::apply(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    review,
                    permit,
                )
                .err()
                .map(Failure::from);
                Ok(Reply::Restored {
                    failure,
                    cancelled: false,
                })
            }
            Command::InspectRestorationFiles {
                selection,
                paths,
                preparation,
            } => {
                preparation.validate()?;
                self.ensure_store(false)?;
                self.restoration.inspect_multiple(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    &selection,
                    &paths,
                    preparation,
                )
            }
            Command::PrepareMultipleRestoration {
                selection,
                credentials,
                preparation,
                source_files,
            } => {
                preparation.validate()?;
                self.ensure_store(false)?;
                self.restoration.prepare_multiple(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    selection,
                    credentials,
                    preparation,
                    source_files,
                )
            }
            Command::PrepareRestorationResume(cancel) => {
                self.ensure_store(false)?;
                let review = restoration::prepare_resume_review(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    cancel,
                )?;
                Ok(Reply::RestorationReview {
                    token: None,
                    summary: review.summary,
                    target: review.target,
                    saved: review.saved,
                    current: review.current,
                    rekeyed: false,
                })
            }
            Command::FinishRestoration { cancel, permit } => {
                self.ensure_store(false)?;
                self.transport = None;
                self.selected = None;
                let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
                let failure = if cancel {
                    restoration::cancel(store, permit)
                } else {
                    restoration::resume(store, permit)
                }
                .err()
                .map(Failure::from);
                Ok(Reply::Restored {
                    failure,
                    cancelled: cancel,
                })
            }
            Command::Inspect => self.profile(),
            Command::InspectHistory => {
                match self.ensure_store(false) {
                    Err(Failure::Secret(secret_store::Failure::MissingOwner)) => {
                        return Ok(Reply::History(key_store::history::Catalog::default()));
                    }
                    result => result?,
                }
                Ok(Reply::History(key_store::history::inspect(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                )?))
            }
            Command::Resume => {
                self.ensure_store(false)?;
                auth_store::recover(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
                self.profile()
            }
            Command::CreateAccount { server } => {
                let client = self.begin_interactive(&server)?;
                let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
                let result = auth_store::create_account(store, &client);
                let (live, key) = result.map_err(|e| self.rejected(e))?;
                self.client = Some(client);
                self.live = Some(live);
                // The account and its key are committed. A failed library listing
                // must not hide the only presentation of the new key.
                let (next, failure) = match self.connected(None) {
                    Ok(reply) => (Some(Box::new(reply)), None),
                    Err(failure) => (self.profile().ok().map(Box::new), Some(failure)),
                };
                Ok(Reply::AccountCreated { key, next, failure })
            }
            Command::SignIn { server, key } => {
                let client = self.begin_interactive(&server)?;
                let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
                let result = auth_store::sign_in(store, &client, &key);
                drop(key);
                let live = result.map_err(|e| self.rejected(e))?;
                self.client = Some(client);
                self.live = Some(live);
                self.connected(None)
            }
            Command::BeginDeviceSignIn { server } => {
                let client = self.begin_interactive(&server)?;
                // Offered only when discovery advertises the capability.
                if !client.supports_device_sign_in() {
                    return Err(Failure::DeviceSignInUnsupported);
                }
                let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
                let payload = auth_store::device::begin(store, &client)?;
                self.client = Some(client);
                Ok(Reply::DeviceSignIn {
                    state: Some(auth_store::device::Status::Waiting(payload)),
                    retry_after: None,
                    failure: None,
                })
            }
            Command::CheckDeviceSignIn => self.check_device_sign_in(),
            Command::CancelDeviceSignIn => {
                self.ensure_store(false)?;
                auth_store::device::cancel(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
                self.profile()
            }
            Command::PrepareDeviceApproval(payload) => {
                let request = crate::bootstrap::DeviceSignIn::decode_qr(
                    payload.as_bytes(),
                    chrono::Utc::now().timestamp(),
                )
                .map_err(|_| Failure::InvalidDeviceRequest)?;
                drop(payload);
                if !self
                    .client
                    .as_ref()
                    .ok_or(Failure::InvalidState)?
                    .supports_device_sign_in()
                {
                    return Err(Failure::DeviceSignInUnsupported);
                }
                // The request's server is compared with the pinned origin before
                // the key owner makes any network call.
                let (store, transport) = self.parts()?;
                let target = mutations::prepare_device_approval(store, transport, &request)?;
                self.check_owner()?;
                self.device_approval = Some(request);
                Ok(Reply::Target(target))
            }
            Command::ApproveDevice(permit) => {
                let request = self.device_approval.take().ok_or(Failure::InvalidState)?;
                let (store, transport) = self.parts()?;
                let result = mutations::approve_device(store, transport, &request, permit)
                    .map_err(Failure::from);
                let check = self.check_owner();
                let outcome = result.as_ref().ok().copied();
                let failure = check.err().or_else(|| result.err());
                Ok(self.mutation_status(outcome, failure))
            }
            Command::PrepareAccountKeyDisclosure => {
                self.ensure_store(false)?;
                Ok(Reply::Target(auth_store::prepare_account_key_disclosure(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                )?))
            }
            Command::RevealAccountKey(permit) => {
                self.ensure_store(false)?;
                Ok(Reply::AccountKey(auth_store::reveal_account_key(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    permit,
                )?))
            }
            Command::Refresh => {
                self.reconnect()?;
                self.connected(None)
            }
            Command::SignOut => {
                self.ensure_store(false)?;
                self.live = None;
                self.disconnect_transport();
                auth_store::recover(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
                auth_store::sign_out(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
                // An approved device sign-in belongs to the signed-out session.
                auth_store::device::cancel(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
                self.client = None;
                self.profile()
            }
            Command::Retain => {
                if self.store.is_none() {
                    return Err(Failure::InvalidState);
                }
                let pending = self.pending.take().ok_or(Failure::InvalidState)?;
                let pairing = matches!(&pending, Pending::Pairing(_));
                let candidate = matches!(&pending, Pending::Candidate(_));
                if let Err((failure, owner)) =
                    pending.retain(self.store.as_mut().ok_or(Failure::InvalidState)?)
                {
                    self.pending = owner;
                    return Err(if self.pending.is_some() {
                        Failure::RetentionRequired
                    } else {
                        failure
                    });
                }
                if pairing {
                    // Persistence needs no token or HTTP. Reconnect/select can
                    // later resume activation, including an expired invitation.
                    return Ok(self.pairing_status(None));
                }
                if candidate {
                    return Ok(self.candidate_status(None));
                }
                auth_store::recover(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
                self.live = None;
                self.disconnect_transport();
                self.profile()
            }
            Command::Select(index) => self.select(index),
            Command::PrepareHandover(code) => self.prepare_handover(code),
            Command::CommitHandover { token, permit } => {
                let (expected, review) =
                    self.handover_review.take().ok_or(Failure::InvalidState)?;
                if token != expected {
                    return Err(Failure::InvalidState);
                }
                self.finish_handover(*review, permit)
            }
            Command::PrepareHandoverResume => {
                self.check_owner()?;
                let binding = self
                    .transport
                    .as_ref()
                    .ok_or(Failure::InvalidState)?
                    .key_binding()?;
                let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
                if !handover::matches_pending(store, &binding)? {
                    return Err(Failure::InvalidState);
                }
                Ok(Reply::Target(handover::prepare_resume_authorization(
                    store,
                )?))
            }
            Command::ResumeHandover(permit) => self.resume_handover(permit),
            Command::PrepareHandoverCancel => {
                self.ensure_store(false)?;
                Ok(Reply::Target(handover::prepare_cancel_authorization(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                )?))
            }
            Command::CancelHandover(permit) => {
                self.ensure_store(false)?;
                let result =
                    handover::cancel(self.store.as_mut().ok_or(Failure::InvalidState)?, permit)
                        .map_err(Failure::from);
                self.handover_status(None, result.is_ok(), result.err())
            }
            Command::PrepareLocalHandover => {
                self.ensure_store(false)?;
                let (target, summary) = handover::prepare_local_authorization(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                )?;
                Ok(Reply::LocalHandoverReview { target, summary })
            }
            Command::FinishLocalHandover(permit) => {
                self.ensure_store(false)?;
                self.handover_review = None;
                self.transport = None;
                self.selected = None;
                let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
                let failure = handover::finish_local(store, permit)
                    .err()
                    .map(Failure::from);
                // Never use handover_status here: its completed-target fallback
                // contacts the server. Fresh selection owns later data admission.
                let switching = handover::inspect(store)?;
                Ok(Reply::LocalHandover { switching, failure })
            }
            Command::BeginPairing => self.pairing_operation(PairingAction::Begin),
            Command::CandidatePairing(action) => self.candidate_operation(action),
            Command::BootstrapCandidate => self.bootstrap_candidate(),
            Command::CheckPairing => self.pairing_operation(PairingAction::Check),
            Command::CancelPairing => self.pairing_operation(PairingAction::Cancel),
            Command::PrepareNewLibrary => {
                self.check_owner()?;
                self.creation_review = None;
                let intent = creation::prepare_new(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    self.client.as_ref().ok_or(Failure::InvalidState)?,
                    self.live.as_ref().ok_or(Failure::InvalidState)?,
                )?;
                let retained = intent.retained();
                let token = uuid::Uuid::new_v4();
                self.creation_review = Some((token, intent));
                Ok(Reply::NewLibrary { token, retained })
            }
            command @ (Command::CreateLibrary | Command::CreateNewLibrary(_)) => {
                self.check_owner()?;
                self.transport = None;
                self.selected = None;
                let intent = if let Command::CreateNewLibrary(token) = command {
                    let (expected_token, intent) =
                        self.creation_review.take().ok_or(Failure::InvalidState)?;
                    if token != expected_token {
                        return Err(Failure::InvalidState);
                    }
                    Some(intent)
                } else {
                    self.creation_review = None;
                    None
                };
                let result = if let Some(intent) = intent {
                    creation::begin_new(
                        self.store.as_mut().ok_or(Failure::InvalidState)?,
                        self.client.as_ref().ok_or(Failure::InvalidState)?,
                        self.live.as_ref().ok_or(Failure::InvalidState)?,
                        intent,
                    )
                } else {
                    creation::create_or_resume(
                        self.store.as_mut().ok_or(Failure::InvalidState)?,
                        self.client.as_ref().ok_or(Failure::InvalidState)?,
                        self.live.as_ref().ok_or(Failure::InvalidState)?,
                    )
                }
                .map_err(Failure::from)
                .and_then(|space| self.connected(Some(space.id())));
                match result {
                    Ok(reply) => Ok(reply),
                    Err(failure) => Ok(Reply::CreationFailed {
                        state: creation::status(
                            self.store.as_mut().ok_or(Failure::InvalidState)?,
                            self.client.as_ref().ok_or(Failure::InvalidState)?,
                            self.live.as_ref().ok_or(Failure::InvalidState)?,
                        ),
                        can_create_new: creation::can_begin_new(
                            self.store.as_mut().ok_or(Failure::InvalidState)?,
                            self.client.as_ref().ok_or(Failure::InvalidState)?,
                            self.live.as_ref().ok_or(Failure::InvalidState)?,
                        ),
                        failure,
                    }),
                }
            }
            Command::Setup => {
                let (store, transport) = self.parts()?;
                let outcome = key_store::initialize(store, transport)?;
                self.library_ready(outcome)
            }
            Command::Receive => self.data_action(DataAction::Receive),
            Command::Send => self.data_action(DataAction::Send),
            Command::Sync => self.data_action(DataAction::Sync),
            Command::PrepareVaultSync(authorization) => {
                self.data_action(DataAction::PrepareVaultSync(authorization))
            }
            Command::CancelVaultSync => Ok(Reply::Saved),
            Command::ContinueVaultSync {
                token,
                credential,
                recovery,
            } => {
                let request = self.vault_sync.take().ok_or(Failure::InvalidState)?;
                let authenticated = request.authenticate(token, credential, recovery)?;
                self.data_action_with_vault(DataAction::Sync, None, Some(&authenticated))
            }
            Command::PrepareSnapshotReview => self.data_action(DataAction::PrepareSnapshotReview),
            Command::ResumeSnapshotReview(token) => {
                let (retained, review) =
                    self.snapshot_review.take().ok_or(Failure::InvalidState)?;
                if token != retained {
                    return Err(Failure::InvalidState);
                }
                self.data_action(DataAction::ResumeSnapshotReview(review))
            }
            Command::PrepareDeletionReview => self.data_action(DataAction::PrepareDeletionReview),
            Command::DecideDeletionReview {
                token,
                choice,
                credential,
            } => {
                let (retained, review) =
                    self.deletion_review.take().ok_or(Failure::InvalidState)?;
                if token != retained {
                    return Err(Failure::InvalidState);
                }
                let vault = self.review_vault(credential)?.map(Box::new);
                self.data_action(DataAction::DecideDeletionReview(review, choice, vault))
            }
            Command::Recover(code) => {
                self.check_owner()?;
                let space = self.selected.as_ref().ok_or(Failure::InvalidState)?;
                let server = self
                    .client
                    .as_ref()
                    .ok_or(Failure::InvalidState)?
                    .credential_deployment()
                    .server()
                    .clone();
                let kit = if code.trim_start().starts_with('{') {
                    RecoveryKit::decode_secret_qr(code.as_bytes())
                } else {
                    RecoveryKit::decode_secret_code(
                        &code,
                        server,
                        space.id(),
                        space.key_epoch() as i64,
                    )
                }
                .map_err(|_| Failure::Key(key_store::Failure::RecoveryUnavailable))?;
                let (store, transport) = self.parts()?;
                let outcome = key_store::recover(store, transport, kit)?;
                self.library_ready(outcome)
            }
            Command::PrepareDisclosure => {
                let (store, transport) = self.parts()?;
                let target = disclosure::prepare(store, transport)?;
                self.check_owner()?;
                Ok(Reply::Target(target))
            }
            Command::PrepareRecoveryMutation => {
                let (store, transport) = self.parts()?;
                let result = mutations::prepare_recovery(store, transport);
                self.mutation_prepared(result)
            }
            Command::PrepareApproval(payload) => {
                let invitation =
                    Invitation::decode_qr(payload.as_bytes(), chrono::Utc::now().timestamp())
                        .map_err(|_| Failure::Cloud(cloud::Failure::InvalidResponse))?;
                let (store, transport) = self.parts()?;
                let result = mutations::prepare_approval(store, transport, invitation);
                self.mutation_prepared(result)
            }
            Command::PrepareMutationResume => {
                let (store, transport) = self.parts()?;
                let result = mutations::prepare_resume(store, transport);
                self.mutation_prepared(result)
            }
            Command::Mutate(permit) => {
                let (store, transport) = self.parts()?;
                let result = mutations::execute(store, transport, permit).map_err(Failure::from);
                let check = self.check_owner();
                let outcome = result.as_ref().ok().copied();
                let failure = check.err().or_else(|| result.err());
                Ok(self.mutation_status(outcome, failure))
            }
            Command::ReconcileMutation => {
                let (store, transport) = self.parts()?;
                let result = mutations::reconcile(store, transport).map_err(Failure::from);
                let check = self.check_owner();
                let outcome = result.as_ref().ok().copied();
                let failure = check.err().or_else(|| result.err());
                Ok(self.mutation_status(outcome, failure))
            }
            Command::CancelMutation => {
                self.check_owner()?;
                let result = mutations::cancel_draft(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    self.transport.as_ref().ok_or(Failure::InvalidState)?,
                )
                .map_err(Failure::from);
                self.check_owner()?;
                Ok(self.mutation_status(None, result.err()))
            }
            Command::Authenticate { request, password } => Ok(Reply::Authenticated(
                local_auth::Native::new()?.authenticate(request, password)?,
            )),
            Command::Reveal(permit) => {
                let (store, transport) = self.parts()?;
                let value = disclosure::reveal(store, transport, permit)?;
                self.check_owner()?;
                Ok(Reply::Disclosure(value))
            }
            Command::Confirm { disclosure, suffix } => {
                let (store, transport) = self.parts()?;
                disclosure::confirm_saved(store, transport, disclosure, suffix)?;
                self.check_owner()?;
                Ok(Reply::Saved)
            }
        }
    }
    fn pairing_status(&mut self, failure: Option<Failure>) -> Reply {
        let state = match (self.store.as_mut(), self.transport.as_ref()) {
            (Some(store), Some(transport)) => recipient::inspect_retained(store, transport),
            _ => Err(key_store::Failure::InvalidState),
        };
        Reply::Pairing { state, failure }
    }
    fn candidate_status(&mut self, failure: Option<Failure>) -> Reply {
        let state = match (self.store.as_mut(), self.transport.as_ref()) {
            (Some(store), Some(transport)) => transport
                .key_binding()
                .map_err(key_store::Failure::from)
                .and_then(|binding| candidate::inspect(store, &binding)),
            _ => Err(key_store::Failure::InvalidState),
        };
        Reply::CandidatePairing { state, failure }
    }
    fn candidate_operation(&mut self, action: candidate::Action) -> Result<Reply> {
        self.check_owner()?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let deployment = self
            .client
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .credential_deployment();
        let result = candidate::operate(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.transport.as_mut().ok_or(Failure::InvalidState)?,
            action,
            |owner| {
                live.validate_owner(owner, &deployment)
                    .map_err(key_session_failure)
            },
        );
        let failure = match result {
            Ok(_) => self.check_owner().err(),
            Err(error) => {
                if let Some(owner) = error.unrecorded {
                    self.pending = Some(Pending::Candidate(owner));
                    Some(Failure::RetentionRequired)
                } else {
                    Some(error.failure.into())
                }
            }
        };
        Ok(self.candidate_status(failure))
    }
    fn bootstrap_candidate(&mut self) -> Result<Reply> {
        self.check_owner()?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let deployment = self
            .client
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .credential_deployment();
        let result = initial_candidate::create_or_resume(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.transport.as_mut().ok_or(Failure::InvalidState)?,
            |owner| {
                live.validate_owner(owner, &deployment)
                    .map_err(key_session_failure)
            },
        );
        let failure = self
            .check_owner()
            .err()
            .or_else(|| result.err().map(Failure::from));
        let binding = self
            .transport
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .key_binding()?;
        let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
        let state = initial_candidate::inspect(store, &binding);
        let candidate = candidate::inspect(store, &binding);
        Ok(Reply::BootstrapCandidate {
            state,
            candidate,
            failure,
        })
    }
    fn prepare_handover(&mut self, code: Option<Zeroizing<String>>) -> Result<Reply> {
        self.check_owner()?;
        let space = self.selected.as_ref().ok_or(Failure::InvalidState)?;
        let client = self.client.as_ref().ok_or(Failure::InvalidState)?;
        let kit = code
            .map(|code| {
                if code.trim_start().starts_with('{') {
                    RecoveryKit::decode_secret_qr(code.as_bytes())
                } else {
                    RecoveryKit::decode_secret_code(
                        &code,
                        client.credential_deployment().server().clone(),
                        space.id(),
                        space.key_epoch() as i64,
                    )
                }
                .map_err(|_| Failure::Key(key_store::Failure::RecoveryUnavailable))
            })
            .transpose()?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let deployment = client.credential_deployment();
        let review = handover::prepare(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.transport.as_mut().ok_or(Failure::InvalidState)?,
            kit,
            |owner| {
                live.validate_owner(owner, &deployment)
                    .map_err(key_session_failure)
            },
        )?;
        self.check_owner()?;
        let token = uuid::Uuid::new_v4();
        let summary = review.summary();
        let target = review.authorization_target()?;
        let reused_local_key = review.reuses_local_key();
        self.handover_review = Some((token, Box::new(review)));
        Ok(Reply::HandoverReview {
            token,
            summary,
            target,
            reused_local_key,
        })
    }
    fn finish_handover(
        &mut self,
        review: handover::Review,
        permit: local_auth::Permit,
    ) -> Result<Reply> {
        self.check_owner()?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let deployment = self
            .client
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .credential_deployment();
        let result = handover::commit(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.transport.as_mut().ok_or(Failure::InvalidState)?,
            review,
            permit,
            |owner| {
                live.validate_owner(owner, &deployment)
                    .map_err(key_session_failure)
            },
        )
        .map_err(Failure::from);
        let failure = self
            .check_owner()
            .err()
            .or_else(|| result.as_ref().err().copied());
        self.handover_status(result.ok(), false, failure)
    }
    fn resume_handover(&mut self, permit: local_auth::Permit) -> Result<Reply> {
        self.check_owner()?;
        let live = self.live.as_ref().ok_or(Failure::InvalidState)?;
        let deployment = self
            .client
            .as_ref()
            .ok_or(Failure::InvalidState)?
            .credential_deployment();
        let result = handover::resume(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.transport.as_mut().ok_or(Failure::InvalidState)?,
            permit,
            |owner| {
                live.validate_owner(owner, &deployment)
                    .map_err(key_session_failure)
            },
        )
        .map_err(Failure::from);
        let failure = self
            .check_owner()
            .err()
            .or_else(|| result.as_ref().err().copied());
        self.handover_status(result.ok(), false, failure)
    }
    fn handover_status(
        &mut self,
        keys: Option<key_store::Outcome>,
        cancelled: bool,
        failure: Option<Failure>,
    ) -> Result<Reply> {
        let switching = handover::inspect(self.store.as_mut().ok_or(Failure::InvalidState)?)?;
        let pending_matches = if let Some(transport) = self.transport.as_ref() {
            match transport.key_binding() {
                Ok(binding) => handover::matches_pending(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    &binding,
                )?,
                Err(_) => false,
            }
        } else {
            false
        };
        let mut keys = if failure.is_none() { keys } else { None };
        // A lost final receipt or revoked foreground lease may arrive after the
        // durable completion. Restore usable-key controls only through normal
        // fresh verification of that completed target, never by resetting it.
        if !switching.pending && keys.is_none() && !cancelled {
            let completed = match self.transport.as_ref().and_then(|t| t.key_binding().ok()) {
                Some(binding) => handover::completed_for(
                    self.store.as_mut().ok_or(Failure::InvalidState)?,
                    &binding,
                )?,
                None => false,
            };
            if completed && self.check_owner().is_ok() {
                let store = self.store.as_mut().ok_or(Failure::InvalidState)?;
                let transport = self.transport.as_mut().ok_or(Failure::InvalidState)?;
                if matches!(key_store::load_verified(store, transport), Ok(Some(_))) {
                    keys = key_store::initialize(store, transport).ok();
                }
                if self.check_owner().is_err() {
                    keys = None;
                }
            }
        }
        let role = self.transport.as_ref().map(BoundTransport::key_role);
        Ok(Reply::Handover {
            switching,
            keys,
            role,
            cancelled,
            failure,
            pending_matches,
        })
    }
    fn library_ready(&mut self, outcome: key_store::Outcome) -> Result<Reply> {
        self.check_owner()?;
        let can_create_new = creation::can_begin_new(
            self.store.as_mut().ok_or(Failure::InvalidState)?,
            self.client.as_ref().ok_or(Failure::InvalidState)?,
            self.live.as_ref().ok_or(Failure::InvalidState)?,
        );
        Ok(Reply::Library {
            outcome: Ok(outcome),
            can_create_new,
        })
    }
    fn pairing_operation(&mut self, operation: PairingAction) -> Result<Reply> {
        let (store, transport) = self.parts()?;
        let result = match operation {
            PairingAction::Begin => recipient::begin(store, transport),
            PairingAction::Check => recipient::check(store, transport),
            PairingAction::Cancel => recipient::cancel(store, transport),
        };
        match result {
            Ok(recipient::Outcome::Ready { kit }) => {
                self.library_ready(key_store::Outcome::Ready { kit })
            }
            Ok(_) => {
                self.check_owner()?;
                Ok(self.pairing_status(None))
            }
            Err(error) => {
                let failure = if let Some(owner) = error.unrecorded {
                    self.pending = Some(Pending::Pairing(owner));
                    Failure::RetentionRequired
                } else {
                    error.failure.into()
                };
                Ok(self.pairing_status(Some(failure)))
            }
        }
    }
}
fn key_session_failure(value: auth_store::Failure) -> key_store::Failure {
    match value {
        auth_store::Failure::Secret(value) => value.into(),
        auth_store::Failure::Cloud(value) => value.into(),
        _ => key_store::Failure::ReviewRequired,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const DEADLINE: std::time::Duration = std::time::Duration::from_secs(3);

    #[test]
    fn vault_sync_cleanup_preserves_the_quit_fence_until_an_explicit_foreground_action() {
        let worker = Handle::spawn(|_| (Ok(Reply::Saved), false)).unwrap();
        worker.prepare_quit();
        assert!(worker.control.quitting());
        let cleaned = worker.request(Command::CancelVaultSync).unwrap();
        assert!(matches!(
            cleaned.recv_timeout(DEADLINE).unwrap(),
            Ok(Reply::Saved)
        ));
        assert!(worker.control.quitting() && worker.control.is_paused());
        let explicit = worker.request(Command::Sync).unwrap();
        assert!(matches!(
            explicit.recv_timeout(DEADLINE).unwrap(),
            Ok(Reply::Saved)
        ));
        assert!(!worker.control.quitting());
    }

    #[test]
    fn cancelled_or_mismatched_vault_sync_requests_are_consumed_before_automatic_admission_resumes()
    {
        for cancel in [false, true] {
            let temporary = tempfile::tempdir().unwrap();
            let target = public_target();
            Preference::on(temporary.path(), &target).unwrap();
            let preference = Preference::read(temporary.path()).unwrap();
            let fixture: serde_json::Value =
                serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
            let document =
                crate::vault::Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap())
                    .unwrap();
            std::fs::create_dir(temporary.path().join("Vault")).unwrap();
            crate::model::atomic_write(
                &temporary.path().join("Vault/vault.json"),
                &document.encode().unwrap(),
            )
            .unwrap();
            let authorization = vault_sync::Authorization::new(
                crate::desktop::SessionWitness::test(crate::desktop::SessionState::Unlocked, 1),
            )
            .unwrap();
            assert!(Command::PrepareVaultSync(authorization.clone()).keeps_automatic());
            let request = vault_sync::Request::capture(
                temporary.path(),
                &target.binding().checkpoint_scope(),
                1,
                authorization,
            )
            .unwrap();
            let control = Control::new();
            let mut owner = Owner::new(temporary.path().into(), control.clone());
            owner.vault_sync = Some(request);
            control.pause();
            assert!(control.is_paused());
            let command = if cancel {
                Command::CancelVaultSync
            } else {
                Command::ContinueVaultSync {
                    token: uuid::Uuid::new_v4(),
                    credential: Zeroizing::new("Public mismatched token fixture".into()),
                    recovery: false,
                }
            };
            let reply = owner.handle_scheduled(command);
            assert_eq!(reply.is_ok(), cancel);
            assert!(owner.vault_sync.is_none() && !control.is_paused());
            assert!(owner.store.is_none() && owner.transport.is_none() && owner.client.is_none());
            assert!(Preference::read(temporary.path()).unwrap() == preference);
            assert!(!temporary.path().join("Sync").exists());
            // Cancellation is idempotent and does not initialize a native owner.
            assert!(matches!(
                owner.handle_scheduled(Command::CancelVaultSync),
                Ok(Reply::Saved)
            ));
            assert!(matches!(
                owner.handle_scheduled(Command::ContinueVaultSync {
                    token: uuid::Uuid::new_v4(),
                    credential: Zeroizing::new("Public replay fixture".into()),
                    recovery: false
                }),
                Err(Failure::InvalidState)
            ));
            assert!(owner.store.is_none());
        }
    }

    #[test]
    fn queued_work_prevents_quit_until_every_operation_finishes() {
        let (entered, observer) = mpsc::channel();
        let (resume, paused) = mpsc::channel();
        let mut calls = 0;
        let worker = Handle::spawn(move |_| {
            calls += 1;
            entered.send(calls).unwrap();
            paused.recv_timeout(DEADLINE).unwrap();
            (Ok(Reply::Saved), false)
        })
        .unwrap();
        let first = worker.request(Command::Sync).unwrap();
        let second = worker.request(Command::Inspect).unwrap();
        assert_eq!(observer.recv_timeout(DEADLINE).unwrap(), 1);
        assert!(!worker.can_quit());
        resume.send(()).unwrap();
        assert!(matches!(
            first.recv_timeout(DEADLINE).unwrap(),
            Ok(Reply::Saved)
        ));
        assert_eq!(observer.recv_timeout(DEADLINE).unwrap(), 2);
        assert!(!worker.can_quit());
        resume.send(()).unwrap();
        assert!(matches!(
            second.recv_timeout(DEADLINE).unwrap(),
            Ok(Reply::Saved)
        ));
        assert!(worker.can_quit());
    }
    #[test]
    fn lost_ui_reply_preserves_pending_ownership_and_quit_barrier() {
        // Script the backend's ownership outcome without contacting a keyring,
        // authenticating an account or issuing real credentials.
        let mut pending = false;
        let worker = Handle::spawn(move |command| {
            let reply = match command {
                Command::SignIn { .. } => {
                    pending = true;
                    Err(Failure::RetentionRequired)
                }
                Command::Retain => {
                    pending = false;
                    Ok(Reply::Saved)
                }
                _ => Ok(Reply::Profile {
                    account: None,
                    server: None,
                    interrupted: pending,
                    switching: handover::Status::default(),
                    device: None,
                }),
            };
            (reply, pending)
        })
        .unwrap();
        drop(
            worker
                .request(Command::SignIn {
                    server: Zeroizing::new("https://public.example.test".into()),
                    key: AccountKey::parse_input("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7").unwrap(),
                })
                .unwrap(),
        );
        let inspected = worker.request(Command::Inspect).unwrap();
        assert!(matches!(
            inspected.recv_timeout(DEADLINE).unwrap(),
            Ok(Reply::Profile {
                interrupted: true,
                ..
            })
        ));
        assert!(worker.retention_required());
        assert!(!worker.can_quit());
        drop(
            worker
                .request(Command::Automatic(false))
                .unwrap()
                .recv_timeout(DEADLINE)
                .unwrap(),
        );
        assert!(worker.retention_required());
        assert!(!worker.prepare_quit());
        let retained = worker.request(Command::Retain).unwrap();
        assert!(matches!(
            retained.recv_timeout(DEADLINE).unwrap(),
            Ok(Reply::Saved)
        ));
        assert!(!worker.retention_required());
        assert!(worker.can_quit());
    }
    fn public_target() -> Target {
        let deployment = auth_store::Deployment::from_discovery(
            ServerURL::parse("https://sync.example").unwrap(),
            uuid::Uuid::from_u128(1),
        );
        let binding = key_store::KeyBinding::new(
            deployment.server().clone(),
            uuid::Uuid::from_u128(1),
            uuid::Uuid::from_u128(2),
            (
                cloud::Binding::from_checkpoint([3; 32]),
                cloud::Binding::from_checkpoint([4; 32]),
            ),
            1,
        )
        .unwrap();
        Target::new(binding, &deployment, "fictional-account").unwrap()
    }
    #[test]
    fn startup_with_absent_consent_never_initializes_any_local_or_secret_owner() {
        let root = tempfile::tempdir().unwrap();
        let absent = root.path().join("empty");
        let mut owner = Owner::new(absent.clone(), Control::new());
        for _ in 0..3 {
            owner.tick();
        }
        assert!(owner.store.is_none() && owner.client.is_none() && owner.live.is_none());
        assert_eq!(owner.automatic, Automatic::OFF);
        assert!(!absent.exists());
    }
    #[test]
    fn automatic_startup_obeys_backup_fence_before_keyring_or_network() {
        let root = tempfile::tempdir().unwrap();
        Preference::on(root.path(), &public_target()).unwrap();
        std::fs::create_dir(root.path().join("Backups")).unwrap();
        std::fs::write(
            root.path().join("Backups/restore.pending"),
            b"fictional incomplete redo",
        )
        .unwrap();
        let mut owner = Owner::new(root.path().into(), Control::new());
        owner.tick();
        assert!(owner.store.is_none() && owner.client.is_none() && owner.transport.is_none());
        assert!(owner.automatic.enabled);
        assert_eq!(owner.automatic.status, AutomaticStatus::Retry);
        assert!(!root.path().join("Sync").exists());
        assert!(!root.path().join("snippets.json").exists());
    }
    #[test]
    fn foreground_scope_change_disables_saved_consent_before_operation() {
        let root = tempfile::tempdir().unwrap();
        Preference::on(root.path(), &public_target()).unwrap();
        let mut owner = Owner::new(root.path().into(), Control::new());
        let result = owner.handle_scheduled(Command::Select(0));
        assert!(matches!(result, Err(Failure::InvalidState)));
        assert!(!Preference::read(root.path()).unwrap().enabled());
        assert!(owner.store.is_none() && owner.client.is_none());
        assert_eq!(owner.automatic, Automatic::OFF);
        assert!(!root.path().join("Sync").exists());
    }
    #[test]
    fn native_owner_can_disable_automatic_mode_during_local_recovery() {
        let root = tempfile::tempdir().unwrap();
        Preference::on(root.path(), &public_target()).unwrap();
        std::fs::write(
            root.path().join("snippets.json"),
            b"mixed fictional primary",
        )
        .unwrap();
        let mut owner = Owner::new(root.path().into(), Control::new());
        assert!(matches!(
            owner.handle_scheduled(Command::Automatic(false)),
            Ok(Reply::Automatic(Automatic { enabled: false, .. }))
        ));
        assert_eq!(
            std::fs::read(root.path().join("snippets.json")).unwrap(),
            b"mixed fictional primary"
        );
        assert!(owner.store.is_none());
    }
    #[test]
    fn automatic_and_foreground_work_share_cancellation_and_quit_barriers() {
        let root = tempfile::tempdir().unwrap();
        Preference::on(root.path(), &public_target()).unwrap();
        let preference = Preference::read(root.path()).unwrap();
        let control = Control::new();
        let ticket = control.ticket(root.path(), preference).unwrap();
        let (entered_tx, entered_rx) = mpsc::sync_channel(1);
        let (release_tx, release_rx) = mpsc::sync_channel(1);
        let mut first = true;
        let worker = Handle::spawn_events(control.clone(), move |event| match event {
            Event::Tick if first => {
                first = false;
                entered_tx.send(()).unwrap();
                release_rx.recv_timeout(DEADLINE).unwrap();
                assert_eq!(ticket.validate(), Err(auto_sync::Failure::Cancelled));
                (None, false, Automatic::OFF)
            }
            Event::Command(command) if matches!(*command, Command::Automatic(false)) => {
                (Some(Ok(Reply::Saved)), false, Automatic::OFF)
            }
            _ => (None, false, Automatic::OFF),
        })
        .unwrap();
        entered_rx.recv_timeout(DEADLINE).unwrap();
        assert!(!worker.prepare_quit());
        let disabled = worker.request(Command::Automatic(false)).unwrap();
        assert!(!worker.can_quit());
        assert!(control.is_paused());
        release_tx.send(()).unwrap();
        assert!(matches!(
            disabled.recv_timeout(DEADLINE).unwrap(),
            Ok(Reply::Saved)
        ));
        assert!(worker.prepare_quit());
        assert!(control.quitting());
    }
    #[test]
    fn admitted_foreground_work_has_priority_before_its_queue_message_arrives() {
        let control = Control::new();
        control.pause();
        let (entered_tx, entered_rx) = mpsc::channel();
        let worker = Handle::spawn_events(control.clone(), move |event| {
            if matches!(event, Event::Tick) {
                let _ = entered_tx.send(());
            }
            (None, false, Automatic::OFF)
        })
        .unwrap();
        // Interleave between request admission and message publication.
        worker.in_flight.fetch_add(1, Ordering::SeqCst);
        control.resume();
        assert!(matches!(
            entered_rx.recv_timeout(Duration::from_millis(500)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        worker.in_flight.fetch_sub(1, Ordering::SeqCst);
        entered_rx.recv_timeout(DEADLINE).unwrap();
        worker.prepare_quit();
    }
    #[test]
    fn retryable_failures_and_all_review_states_have_separate_scheduling_policy() {
        let received = Reply::Received(receiver::Progress {
            status: receiver::Status::Current,
            received_records: 0,
            applied_records: 0,
            completed_pages: 0,
        });
        assert_eq!(
            automatic_outcome(Ok(received)).1,
            AutomaticStatus::ReceivedCurrent
        );
        for failure in [
            Failure::Cloud(cloud::Failure::Network),
            Failure::Secret(secret_store::Failure::Locked),
            Failure::Cloud(cloud::Failure::Server {
                code: cloud::ErrorCode::RateLimited,
                retry_after: Some(60),
            }),
        ] {
            assert_eq!(automatic_outcome(Err(failure)).0, auto_sync::Outcome::Retry);
        }
        for failure in [
            Failure::Cloud(cloud::Failure::AccountReview),
            Failure::Cloud(cloud::Failure::DatasetReview),
            Failure::Account(auth_store::Failure::Expired),
            Failure::RetentionRequired,
            Failure::Key(key_store::Failure::Busy),
            Failure::Automatic(auto_sync::Failure::ScopeChanged),
        ] {
            assert_eq!(
                automatic_outcome(Err(failure)).0,
                auto_sync::Outcome::Attention
            );
        }
        for status in [
            receiver::Status::LocalReview,
            receiver::Status::ConflictReview,
            receiver::Status::VaultLocked,
            receiver::Status::IncompatibleVault,
            receiver::Status::SnapshotReview,
            receiver::Status::DeletionReview,
            receiver::Status::SendFirst,
        ] {
            let reply = Reply::Received(receiver::Progress {
                status,
                received_records: 0,
                applied_records: 0,
                completed_pages: 0,
            });
            assert_eq!(
                automatic_outcome(Ok(reply)).0,
                auto_sync::Outcome::Attention
            );
        }
    }
}
