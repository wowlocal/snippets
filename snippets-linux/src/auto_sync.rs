//! Opt-in scheduling policy. A public flag contains no account/library identity;
//! the exact consent target lives only in the protected credential owner.
use crate::{
    auth_store::{self, Deployment},
    canonical::{self, Value},
    cloud::Binding,
    key_store::KeyBinding,
    model,
    secret_store::{Backend, Locked, Slot},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use uuid::Uuid;

const PREFERENCE: &str = "automatic-sync.json";
const MAX_PREFERENCE: usize = 1024;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Storage,
    InvalidState,
    ScopeChanged,
    Cancelled,
    Account(auth_store::Failure),
    Secret(crate::secret_store::Failure),
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<crate::secret_store::Failure> for Failure {
    fn from(value: crate::secret_store::Failure) -> Self {
        Self::Secret(value)
    }
}
impl From<auth_store::Failure> for Failure {
    fn from(value: auth_store::Failure) -> Self {
        Self::Account(value)
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Preference {
    consent: Option<Uuid>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredPreference {
    schema_version: u8,
    automatic: bool,
    consent: Option<Uuid>,
}
impl Preference {
    pub fn read(root: &Path) -> Result<Self> {
        let path = root.join(PREFERENCE);
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path)
        {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self { consent: None });
            }
            Ok(file) => file,
            _ => return Err(Failure::Storage),
        };
        let metadata = file.metadata().map_err(|_| Failure::Storage)?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o077 != 0
            || metadata.len() > MAX_PREFERENCE as u64
        {
            return Err(Failure::Storage);
        }
        let mut bytes = Vec::new();
        file.take(MAX_PREFERENCE as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Failure::Storage)?;
        if bytes.len() > MAX_PREFERENCE {
            return Err(Failure::Storage);
        }
        let stored: StoredPreference =
            serde_json::from_slice(&bytes).map_err(|_| Failure::InvalidState)?;
        if stored.schema_version != 1
            || stored.automatic != stored.consent.is_some()
            || stored.consent.is_some_and(|id| id.is_nil())
        {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            consent: stored.consent,
        })
    }
    pub fn enabled(self) -> bool {
        self.consent.is_some()
    }
    pub fn off(root: &Path) -> Result<()> {
        Self { consent: None }.save(root)
    }
    pub fn on(root: &Path, target: &Target) -> Result<()> {
        Self {
            consent: Some(target.consent),
        }
        .save(root)
    }
    fn save(self, root: &Path) -> Result<()> {
        let library = model::Library::prepare(root.into()).map_err(|_| Failure::Storage)?;
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        let bytes = serde_json::to_vec(&StoredPreference {
            schema_version: 1,
            automatic: self.enabled(),
            consent: self.consent,
        })
        .map_err(|_| Failure::InvalidState)?;
        model::atomic_write(&root.join(PREFERENCE), &bytes).map_err(|_| Failure::Storage)
    }
}
/// No Debug/Serialize: the protected target cannot become a UI/logging payload.
pub struct Target {
    consent: Uuid,
    binding: KeyBinding,
    credential: Binding,
}
impl Target {
    pub fn new(binding: KeyBinding, deployment: &Deployment, account: &str) -> Result<Self> {
        if !binding.matches_deployment(deployment) || account.is_empty() {
            return Err(Failure::ScopeChanged);
        }
        Ok(Self {
            consent: Uuid::new_v4(),
            binding,
            credential: credential(deployment, account),
        })
    }
    pub fn binding(&self) -> &KeyBinding {
        &self.binding
    }
    pub fn validate_binding(&self, binding: &KeyBinding) -> Result<()> {
        if binding != &self.binding {
            return Err(Failure::ScopeChanged);
        }
        Ok(())
    }
    pub fn save<B: Backend>(&self, owner: &mut Locked<'_, B>) -> Result<()> {
        let previous = owner.read(Slot::AutomaticSync)?;
        let encoded = Value::Object(
            [
                ("schema".into(), Value::Int(1)),
                ("consent".into(), Value::text(self.consent.to_string())),
                ("binding".into(), self.binding.value()),
                (
                    "credential".into(),
                    Value::text(crate::crypto::b64(self.credential.bytes_for_checkpoint())),
                ),
            ]
            .into_iter()
            .collect(),
        )
        .encode()
        .map_err(|_| Failure::InvalidState)?;
        owner.replace(
            Slot::AutomaticSync,
            previous.as_deref().map(Vec::as_slice),
            Some(&encoded),
        )?;
        Ok(())
    }
    pub fn load<B: Backend>(owner: &mut Locked<'_, B>, preference: Preference) -> Result<Self> {
        let bytes = owner
            .read(Slot::AutomaticSync)?
            .ok_or(Failure::ScopeChanged)?;
        if bytes.len() > 16 * 1024 {
            return Err(Failure::InvalidState);
        }
        let value = canonical::parse(&bytes).map_err(|_| Failure::InvalidState)?;
        let fields = value.as_object().map_err(|_| Failure::InvalidState)?;
        if fields.len() != 4
            || ["schema", "consent", "binding", "credential"]
                .iter()
                .any(|key| !fields.contains_key(*key))
            || fields["schema"]
                .as_int()
                .map_err(|_| Failure::InvalidState)?
                != 1
        {
            return Err(Failure::InvalidState);
        }
        let text = fields["consent"]
            .as_text()
            .map_err(|_| Failure::InvalidState)?;
        let consent = Uuid::parse_str(text).map_err(|_| Failure::InvalidState)?;
        if consent.is_nil() || consent.to_string() != text || preference.consent != Some(consent) {
            return Err(Failure::ScopeChanged);
        }
        let binding = KeyBinding::parse(&fields["binding"]).map_err(|_| Failure::InvalidState)?;
        let credential = Binding::from_checkpoint(
            crate::crypto::unb64(
                fields["credential"]
                    .as_text()
                    .map_err(|_| Failure::InvalidState)?,
            )
            .map_err(|_| Failure::InvalidState)?
            .try_into()
            .map_err(|_| Failure::InvalidState)?,
        );
        Ok(Self {
            consent,
            binding,
            credential,
        })
    }
    pub fn validate_account(&self, deployment: &Deployment, account: &str) -> Result<()> {
        if !self.binding.matches_deployment(deployment)
            || credential(deployment, account) != self.credential
        {
            return Err(Failure::ScopeChanged);
        }
        Ok(())
    }
}
fn credential(deployment: &Deployment, account: &str) -> Binding {
    let mut hash = Sha256::new();
    let instance = deployment.instance();
    for value in [
        b"snip.automatic.account.v1".as_slice(),
        deployment.server().for_secure_storage().as_bytes(),
        instance.as_bytes(),
        account.as_bytes(),
    ] {
        hash.update((value.len() as u64).to_be_bytes());
        hash.update(value);
    }
    Binding::from_checkpoint(hash.finalize().into())
}

/// Revocation is immediate, including while an automatic request owns the
/// actor. Persisted consent also invalidates tickets across independent owners.
pub struct Control {
    epoch: AtomicU64,
    paused: AtomicBool,
    quitting: AtomicBool,
}
impl Control {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            epoch: AtomicU64::new(1),
            paused: AtomicBool::new(false),
            quitting: AtomicBool::new(false),
        })
    }
    pub fn interrupt(&self) {
        self.epoch.fetch_add(1, Ordering::SeqCst);
    }
    pub fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
        self.interrupt();
    }
    pub fn resume(&self) {
        self.interrupt();
        self.paused.store(false, Ordering::SeqCst);
    }
    pub fn prepare_quit(&self) {
        self.quitting.store(true, Ordering::SeqCst);
        self.interrupt();
    }
    /// Only an explicit foreground continuation may withdraw a pending quit.
    pub fn cancel_quit(&self) {
        self.interrupt();
        self.quitting.store(false, Ordering::SeqCst);
    }
    pub fn quitting(&self) -> bool {
        self.quitting.load(Ordering::SeqCst)
    }
    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst) || self.quitting.load(Ordering::SeqCst)
    }
    pub fn ticket(self: &Arc<Self>, root: &Path, preference: Preference) -> Result<Ticket> {
        let ticket = Ticket {
            control: self.clone(),
            epoch: self.epoch.load(Ordering::SeqCst),
            root: root.into(),
            preference,
        };
        ticket.validate()?;
        Ok(ticket)
    }
}
pub struct Ticket {
    control: Arc<Control>,
    epoch: u64,
    root: PathBuf,
    preference: Preference,
}
impl Ticket {
    pub fn validate(&self) -> Result<()> {
        if self.control.is_paused()
            || self.epoch != self.control.epoch.load(Ordering::SeqCst)
            || !self.preference.enabled()
            || Preference::read(&self.root)? != self.preference
        {
            return Err(Failure::Cancelled);
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Current,
    MoreWork,
    Retry,
    Attention,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wake {
    Foreground,
    LocalEdit,
}
pub struct Schedule {
    due: Duration,
    retry: u8,
    running: bool,
    halted: bool,
    dirty: Option<Duration>,
}
impl Schedule {
    pub fn new(now: Duration) -> Self {
        Self {
            due: now,
            retry: 0,
            running: false,
            halted: false,
            dirty: None,
        }
    }
    pub fn wake(&mut self, reason: Wake, now: Duration) {
        if self.halted || self.running || self.retry != 0 {
            return;
        }
        let due = match reason {
            Wake::Foreground => now,
            Wake::LocalEdit => {
                let first = *self.dirty.get_or_insert(now);
                now.saturating_add(Duration::from_secs(2))
                    .min(first.saturating_add(Duration::from_secs(10)))
            }
        };
        self.due = self.due.min(due);
    }
    pub fn begin(&mut self, now: Duration) -> bool {
        if self.halted || self.running || now < self.due {
            return false;
        }
        self.running = true;
        self.dirty = None;
        true
    }
    pub fn finish(&mut self, outcome: Outcome, now: Duration) {
        self.running = false;
        let delay = match outcome {
            Outcome::Current => {
                self.retry = 0;
                30
            }
            Outcome::MoreWork => {
                self.retry = 0;
                2
            }
            Outcome::Retry => {
                self.retry = self.retry.saturating_add(1).min(7);
                (5u64 << (self.retry - 1)).min(300)
            }
            Outcome::Attention => {
                self.halted = true;
                0
            }
        };
        self.due = now.saturating_add(Duration::from_secs(delay));
    }
    pub fn halted(&self) -> bool {
        self.halted
    }
    pub fn defer(&mut self, now: Duration, minimum: Duration) {
        self.due = self
            .due
            .max(now.saturating_add(minimum.min(Duration::from_secs(86400))));
    }
}
#[cfg(test)]
#[path = "auto_sync_tests.rs"]
mod tests;
