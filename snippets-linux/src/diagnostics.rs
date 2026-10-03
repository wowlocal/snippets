//! Closed diagnostic vocabulary. No backend is installed by the CLI or headless core.
//! Values cannot carry text, identifiers, paths, reflected errors or secret material.
use serde::{Deserialize, Serialize};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Family {
    Posix,
    Storage,
    Cloud,
    SecretService,
    Authentication,
    Vault,
    Sync,
    Other,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Failure {
    family: Family,
    code: i32,
}
impl Failure {
    pub fn classified(family: Family) -> Self {
        Self { family, code: 0 }
    }
    pub fn from_io(error: &std::io::Error) -> Self {
        Self {
            family: Family::Posix,
            code: error.raw_os_error().unwrap_or(0),
        }
    }
    /// Stable diagnostic codes, independent of enum declaration order. No response text.
    pub fn from_cloud(failure: crate::cloud::Failure) -> Self {
        use crate::cloud::{ErrorCode as C, Failure as F};
        let code = match failure {
            F::InvalidServer => 1,
            F::IncompatibleServer => 2,
            F::InvalidCredential => 3,
            F::InvalidResponse => 4,
            F::MessageTooLarge => 5,
            F::Network => 6,
            F::AccountReview => 7,
            F::DatasetReview => 8,
            F::ReadOnly => 9,
            F::CredentialCommit => 10,
            // 101-104 belonged to the retired email/code sign-in; never reuse them.
            F::Server { code, .. } => match code {
                C::InvalidRequest => 105,
                C::AuthenticationRequired => 106,
                C::ReauthenticationRequired => 107,
                C::Forbidden => 108,
                C::NotFound => 109,
                C::Conflict => 110,
                C::CursorInvalid => 111,
                C::DatasetReset => 112,
                C::IncompatibleVersion => 113,
                C::PayloadTooLarge => 114,
                C::QuotaExceeded => 115,
                C::RateLimited => 116,
                C::PairingExpired => 117,
                C::DependencyUnavailable => 118,
                C::InternalError => 119,
                C::InvalidAccountKey => 120,
            },
        };
        Self {
            family: Family::Cloud,
            code,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct Count(u32);
impl Count {
    pub fn new(value: usize) -> Self {
        Self(value.min(1_000_000) as u32)
    }
}
impl From<Count> for u64 {
    fn from(value: Count) -> Self {
        value.0 as u64
    }
}
impl TryFrom<u64> for Count {
    type Error = &'static str;
    fn try_from(value: u64) -> Result<Self, Self::Error> {
        if value > 1_000_000 {
            Err("invalid diagnostic count")
        } else {
            Ok(Self(value as u32))
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "u64", into = "u64")]
pub struct Milliseconds(u64);
impl Milliseconds {
    pub fn new(value: Duration) -> Self {
        Self(value.as_millis().min(86_400_000) as u64)
    }
}
impl From<Milliseconds> for u64 {
    fn from(value: Milliseconds) -> Self {
        value.0
    }
}
impl TryFrom<u64> for Milliseconds {
    type Error = &'static str;
    fn try_from(value: u64) -> Result<Self, Self::Error> {
        if value > 86_400_000 {
            Err("invalid diagnostic duration")
        } else {
            Ok(Self(value))
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lifecycle {
    Started,
    WillTerminate,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Area {
    Library,
    Vault,
    Usage,
    DesktopSettings,
    ClipboardHistory,
    Tray,
    GlobalShortcuts,
    ControlSocket,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StorageOperation {
    Open,
    Save,
    Import,
    Export,
    Recover,
    Start,
    Register,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Succeeded,
    Failed,
    Cancelled,
    MoreWork,
    Attention,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountOperation {
    AccountCreate,
    AccountSignIn,
    Reconnect,
    SignOut,
    CreateLibrary,
    SelectLibrary,
    KeySetup,
    KeyRecovery,
    Pairing,
    RecoveryMutation,
    Handover,
    HistoryRestore,
    HistoryRemoval,
    Receive,
    Send,
    Sync,
    VaultSync,
    SnapshotReview,
    DeletionReview,
    Authenticate,
    RecoveryDisclosure,
    Automatic,
    DeviceRequest,
    DeviceApproval,
    DeviceClaim,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Prepare,
    Perform,
    Resume,
    Cancel,
    Confirm,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountState {
    NotApplicable,
    Current,
    MorePages,
    MoreBatches,
    ReceiveFirst,
    SendFirst,
    LocalReview,
    ConflictReview,
    SnapshotReview,
    DeletionReview,
    VaultLocked,
    IncompatibleVault,
    PrimaryChanged,
    PreservationRequired,
    ReadOnly,
    ServerDeferred,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VaultOperation {
    Save,
    Lock,
}

/// Each field set is closed. Adding an event also changes the export vocabulary.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", content = "fields", deny_unknown_fields)]
pub enum Event {
    #[serde(rename = "linux_app_lifecycle")]
    Lifecycle { state: Lifecycle },
    #[serde(rename = "linux_library_readiness")]
    Readiness {
        recovery_required: bool,
        ordinary_count: Count,
    },
    #[serde(rename = "linux_storage_operation")]
    Storage {
        area: Area,
        operation: StorageOperation,
        outcome: Outcome,
        duration_ms: Milliseconds,
        count: Count,
        failure: Option<Failure>,
    },
    #[serde(rename = "linux_account_operation")]
    Account {
        operation: AccountOperation,
        stage: Stage,
        state: AccountState,
        outcome: Outcome,
        duration_ms: Milliseconds,
        received_count: Count,
        accepted_count: Count,
        conflict_count: Count,
        rejected_count: Count,
        failure: Option<Failure>,
    },
    #[serde(rename = "linux_vault_operation")]
    Vault {
        operation: VaultOperation,
        outcome: Outcome,
        duration_ms: Milliseconds,
        failure: Option<Failure>,
    },
    #[serde(rename = "linux_diagnostics_queue_loss")]
    QueueLoss { count: Count },
}
impl Event {
    #[cfg(any(feature = "desktop", test))]
    pub(crate) fn category(self) -> &'static str {
        match self {
            Self::Lifecycle { .. } | Self::Readiness { .. } => "app",
            Self::Storage { .. } => "persistence",
            Self::Account { .. } => "sync",
            Self::Vault { .. } => "vault",
            Self::QueueLoss { .. } => "diagnostics",
        }
    }
    #[cfg(any(feature = "desktop", test))]
    pub(crate) fn level(self) -> &'static str {
        match self {
            Self::Storage {
                outcome: Outcome::Failed,
                ..
            }
            | Self::Account {
                outcome: Outcome::Failed,
                ..
            }
            | Self::Vault {
                outcome: Outcome::Failed,
                ..
            } => "error",
            Self::Storage {
                outcome: Outcome::Attention,
                ..
            }
            | Self::Account {
                outcome: Outcome::Attention,
                ..
            }
            | Self::Vault {
                outcome: Outcome::Attention,
                ..
            }
            | Self::QueueLoss { .. } => "warning",
            _ => "info",
        }
    }
    #[cfg(any(feature = "desktop", test))]
    pub(crate) fn synchronous(self) -> bool {
        self.level() == "error"
            || matches!(
                self,
                Self::Lifecycle {
                    state: Lifecycle::WillTerminate
                } | Self::Account {
                    outcome: Outcome::Attention,
                    ..
                } | Self::Account {
                    operation: AccountOperation::RecoveryDisclosure,
                    ..
                }
            )
    }
}
pub trait Sink: Send + Sync {
    fn record(&self, event: Event);
}
static SINK: OnceLock<Arc<dyn Sink>> = OnceLock::new();
/// Called once by the primary desktop process, after installing its app backend.
#[cfg(feature = "desktop")]
pub(crate) fn install(sink: Arc<dyn Sink>) -> bool {
    SINK.set(sink).is_ok()
}
pub fn record(event: Event) {
    if let Some(sink) = SINK.get() {
        sink.record(event);
    }
}

#[cfg(test)]
#[path = "diagnostics_tests.rs"]
mod tests;
