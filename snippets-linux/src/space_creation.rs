//! Bounded explicit library-creation intents, retained before POST. A lost reply
//! reuses its original idempotency key; completed receipts need no further POST.
//! Nothing here generates library/checkpoint keys or reads primary record data.
use super::{Archive, Deployment, LiveSession};
use crate::{
    canonical::{self, Value},
    cloud::{self, CloudClient, Credential, Role, Space},
    key_store::{self, KeyBinding},
    secret_store::{self, Backend, Locked, Slot, Store},
};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::time::{Duration, SystemTime};
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Secret(secret_store::Failure),
    Account(super::Failure),
    Cloud(cloud::Failure),
    Key(key_store::Failure),
    InvalidState,
    ReviewRequired,
    ExistingLibrary,
    RetentionFull,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<secret_store::Failure> for Failure {
    fn from(e: secret_store::Failure) -> Self {
        Self::Secret(e)
    }
}
impl From<super::Failure> for Failure {
    fn from(e: super::Failure) -> Self {
        match e {
            super::Failure::Secret(e) => Self::Secret(e),
            super::Failure::Cloud(e) => Self::Cloud(e),
            other => Self::Account(other),
        }
    }
}
impl From<cloud::Failure> for Failure {
    fn from(e: cloud::Failure) -> Self {
        Self::Cloud(e)
    }
}
impl From<key_store::Failure> for Failure {
    fn from(e: key_store::Failure) -> Self {
        Self::Key(e)
    }
}
impl From<crate::model::Error> for Failure {
    fn from(_: crate::model::Error) -> Self {
        Self::InvalidState
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Available,
    Requested,
    Created,
    ExistingLibrary,
}
#[derive(PartialEq, Eq)]
struct Account {
    deployment: Deployment,
    identity: Zeroizing<String>,
}
impl Account {
    fn value(&self) -> Value {
        object([
            ("deployment", self.deployment.value()),
            ("identity", Value::text(self.identity.as_str())),
        ])
    }
    fn parse(value: &Value) -> Result<Self> {
        let fields = exact(value, &["deployment", "identity"])?;
        let identity = fields["identity"].as_text()?;
        if !(1..=256).contains(&identity.len()) || identity.chars().any(char::is_control) {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            deployment: Deployment::parse(&fields["deployment"])?,
            identity: Zeroizing::new(identity.into()),
        })
    }
}
struct Journal {
    account: Account,
    request: Uuid,
    created: Option<KeyBinding>,
    source: Option<KeyBinding>,
}
impl Journal {
    fn parse(value: &Value, legacy: bool) -> Result<Self> {
        let fields = exact(
            value,
            if legacy {
                &["schema", "account", "request", "created"]
            } else {
                &["account", "request", "created", "source"]
            },
        )?;
        let account = Account::parse(&fields["account"])?;
        let text = fields["request"].as_text()?;
        let request = Uuid::parse_str(text).map_err(|_| Failure::InvalidState)?;
        if request.is_nil() || request.get_version_num() != 4 || request.to_string() != text {
            return Err(Failure::InvalidState);
        }
        let created = if matches!(fields["created"], Value::Null) {
            None
        } else {
            Some(KeyBinding::parse(&fields["created"])?)
        };
        if created
            .as_ref()
            .is_some_and(|b| !b.matches_deployment(&account.deployment))
        {
            return Err(Failure::InvalidState);
        }
        let source = if legacy || matches!(fields["source"], Value::Null) {
            None
        } else {
            Some(KeyBinding::parse(&fields["source"])?)
        };
        if source
            .as_ref()
            .zip(created.as_ref())
            .is_some_and(|(source, created)| source.same_library(created))
        {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            account,
            request,
            created,
            source,
        })
    }
    fn value(&self, legacy: bool) -> Value {
        let mut fields = BTreeMap::from([
            ("account", self.account.value()),
            ("request", Value::text(self.request.to_string())),
            (
                "created",
                self.created
                    .as_ref()
                    .map(KeyBinding::value)
                    .unwrap_or(Value::Null),
            ),
        ]);
        fields.insert(
            if legacy { "schema" } else { "source" },
            if legacy {
                Value::Int(1)
            } else {
                self.source
                    .as_ref()
                    .map(KeyBinding::value)
                    .unwrap_or(Value::Null)
            },
        );
        Value::Object(
            fields
                .into_iter()
                .map(|(name, value)| (name.into(), value))
                .collect(),
        )
    }
}
const MAX_ENTRIES: usize = 8;
pub(crate) const MAX_BYTES: usize = 64 * 1024;
struct History {
    entries: Vec<Journal>,
    generation: i64,
    legacy: bool,
    snapshot: Option<Zeroizing<Vec<u8>>>,
}
impl History {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Self> {
        Self::from_snapshot(owner.read(Slot::SpaceCreation)?)
    }
    fn from_snapshot(snapshot: Option<Zeroizing<Vec<u8>>>) -> Result<Self> {
        let mut history = Self {
            entries: Vec::new(),
            generation: 0,
            legacy: true,
            snapshot,
        };
        if let Some(bytes) = &history.snapshot {
            if bytes.len() > MAX_BYTES {
                return Err(Failure::InvalidState);
            }
            let value = canonical::parse(bytes)?;
            let schema = value
                .as_object()?
                .get("schema")
                .ok_or(Failure::InvalidState)?
                .as_int()?;
            match schema {
                1 => {
                    if bytes.len() > 16 * 1024 {
                        return Err(Failure::InvalidState);
                    }
                    history.entries.push(Journal::parse(&value, true)?);
                }
                2 | 3 => {
                    let fields = exact(&value, &["schema", "generation", "entries"])?;
                    history.legacy = false;
                    history.generation = fields["generation"].as_int()?;
                    if history.generation < 1 {
                        return Err(Failure::InvalidState);
                    }
                    for entry in fields["entries"].as_array()? {
                        history.entries.push(Journal::parse(entry, false)?);
                    }
                    if schema == 2 && history.entries.is_empty() {
                        return Err(Failure::InvalidState);
                    }
                }
                _ => return Err(Failure::InvalidState),
            }
            history.validate()?;
        }
        Ok(history)
    }
    fn validate(&self) -> Result<()> {
        if self.entries.len() > MAX_ENTRIES {
            return Err(Failure::InvalidState);
        }
        for (index, entry) in self.entries.iter().enumerate() {
            for earlier in &self.entries[..index] {
                if earlier.request == entry.request
                    || earlier
                        .created
                        .as_ref()
                        .zip(entry.created.as_ref())
                        .is_some_and(|(a, b)| a.same_library(b))
                    || earlier.account == entry.account && earlier.created.is_none()
                {
                    return Err(Failure::InvalidState);
                }
            }
        }
        Ok(())
    }
    fn matching(&self, account: &Account) -> Option<usize> {
        self.entries
            .iter()
            .rposition(|entry| entry.account == *account)
    }
    fn check<B: Backend>(&self, owner: &mut Locked<'_, B>) -> Result<()> {
        if owner.read(Slot::SpaceCreation)? != self.snapshot {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> Result<()> {
        self.validate()?;
        let next = self
            .generation
            .checked_add(1)
            .ok_or(Failure::RetentionFull)?;
        let bytes = if self.legacy && self.entries.len() == 1 && self.entries[0].source.is_none() {
            self.entries[0].value(true).encode()?
        } else {
            self.legacy = false;
            object([
                ("schema", Value::Int(3)),
                ("generation", Value::Int(next)),
                (
                    "entries",
                    Value::Array(
                        self.entries
                            .iter()
                            .map(|entry| entry.value(false))
                            .collect(),
                    ),
                ),
            ])
            .encode()?
        };
        if bytes.len() > MAX_BYTES {
            return Err(Failure::RetentionFull);
        }
        owner.replace(
            Slot::SpaceCreation,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        self.generation = next;
        Ok(())
    }
}

pub(crate) fn retirement_terminal(snapshot: Option<Zeroizing<Vec<u8>>>) -> Result<bool> {
    Ok(History::from_snapshot(snapshot)?
        .entries
        .iter()
        .all(|entry| entry.created.is_some()))
}
fn account<B: Backend>(
    owner: &mut Locked<'_, B>,
    deployment: &Deployment,
    live: Option<&LiveSession>,
) -> Result<Account> {
    let archive = Archive::load(owner)?;
    if archive.pending.is_some() {
        return Err(super::Failure::Busy.into());
    }
    let current = archive
        .current
        .as_ref()
        .ok_or(super::Failure::InvalidState)?;
    if current.deployment != *deployment {
        return Err(Failure::ReviewRequired);
    }
    if let Some(live) = live {
        live.validate_current(&archive, deployment)?;
    }
    Ok(Account {
        deployment: deployment.clone(),
        identity: Zeroizing::new(current.account.as_str().into()),
    })
}
fn source<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Option<KeyBinding>> {
    match key_store::creation_source_locked(owner) {
        Ok(source) => Ok(source),
        Err(key_store::Failure::Busy) => Err(Failure::Key(key_store::Failure::Busy)),
        Err(key_store::Failure::Secret(secret_store::Failure::MissingOwner)) => {
            Err(Failure::ExistingLibrary)
        }
        Err(
            key_store::Failure::InvalidState
            | key_store::Failure::ReviewRequired
            | key_store::Failure::KeyConflict,
        ) => Err(Failure::ExistingLibrary),
        Err(error) => Err(error.into()),
    }
}
const PRESERVED: [Slot; 5] = [
    Slot::LibraryKey,
    Slot::Bootstrap,
    Slot::PairingRecipient,
    Slot::CheckpointKey,
    Slot::KeyMutation,
];
struct Captured {
    binding: Option<KeyBinding>,
    values: Vec<Option<Zeroizing<Vec<u8>>>>,
    credentials: Option<Zeroizing<Vec<u8>>>,
}
impl Captured {
    fn new<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Self> {
        let binding = source(owner)?;
        let values = PRESERVED
            .iter()
            .map(|slot| owner.read(*slot))
            .collect::<secret_store::Result<_>>()?;
        let credentials = owner.read(Slot::Credentials)?;
        Ok(Self {
            binding,
            values,
            credentials,
        })
    }
    fn check<B: Backend>(&self, owner: &mut Locked<'_, B>) -> Result<()> {
        if owner.read(Slot::Credentials)? != self.credentials {
            return Err(Failure::ReviewRequired);
        }
        for (slot, before) in PRESERVED.iter().zip(&self.values) {
            if owner.read(*slot)? != *before {
                return Err(Failure::ReviewRequired);
            }
        }
        if source(owner)? != self.binding {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    }
    fn fingerprint(&self, snapshot: Option<&[u8]>) -> Zeroizing<[u8; 32]> {
        let mut hash = Sha256::new();
        hash.update(b"Snippets new library consent v1\0");
        for value in std::iter::once(snapshot)
            .chain(std::iter::once(
                self.credentials.as_deref().map(Vec::as_slice),
            ))
            .chain(
                self.values
                    .iter()
                    .map(|value| value.as_deref().map(Vec::as_slice)),
            )
        {
            match value {
                None => hash.update([0]),
                Some(value) => {
                    hash.update([1]);
                    hash.update((value.len() as u64).to_be_bytes());
                    hash.update(value);
                }
            }
        }
        Zeroizing::new(hash.finalize().into())
    }
}
/// One-use metadata creation proposal. Only aggregate counts leave its owner.
/// The opaque fingerprint is memory-only and is never logged or persisted.
pub struct NewIntent {
    account: Account,
    request: Uuid,
    fingerprint: Zeroizing<[u8; 32]>,
    retained: usize,
    started: Duration,
    wall: SystemTime,
}
impl NewIntent {
    pub fn retained(&self) -> usize {
        self.retained
    }
    fn fresh(&self) -> Result<()> {
        let now = crate::clock::uptime().ok_or(Failure::ReviewRequired)?;
        if now < self.started
            || now - self.started >= Duration::from_secs(120)
            || SystemTime::now()
                .duration_since(self.wall)
                .map_or(true, |elapsed| elapsed >= Duration::from_secs(120))
        {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    }
}
fn can_new(history: &History, current: &Account) -> bool {
    history.entries.len() < MAX_ENTRIES
        && history.generation.checked_add(2).is_some()
        && history
            .matching(current)
            .is_none_or(|index| history.entries[index].created.is_some())
}
pub fn can_begin_new<B: Backend>(
    store: &mut Store<B>,
    client: &CloudClient,
    live: &LiveSession,
) -> Result<bool> {
    store.transaction_with(|owner| {
        let current = account(owner, &client.credential_deployment(), Some(live))?;
        let history = History::load(owner)?;
        Captured::new(owner)?;
        Ok(can_new(&history, &current))
    })
}
pub fn prepare_new<B: Backend>(
    store: &mut Store<B>,
    client: &CloudClient,
    live: &LiveSession,
) -> Result<NewIntent> {
    store.transaction_with(|owner| prepare_new_locked(owner, &client.credential_deployment(), live))
}
fn prepare_new_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    deployment: &Deployment,
    live: &LiveSession,
) -> Result<NewIntent> {
    let current = account(owner, deployment, Some(live))?;
    let history = History::load(owner)?;
    let captured = Captured::new(owner)?;
    if !can_new(&history, &current) {
        return Err(Failure::RetentionFull);
    }
    if account(owner, deployment, Some(live))? != current {
        return Err(Failure::ReviewRequired);
    }
    Ok(NewIntent {
        account: current,
        request: Uuid::new_v4(),
        fingerprint: captured.fingerprint(history.snapshot.as_deref().map(Vec::as_slice)),
        retained: history.entries.len(),
        started: crate::clock::uptime().ok_or(Failure::ReviewRequired)?,
        wall: SystemTime::now(),
    })
}
fn status_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    deployment: &Deployment,
    live: &LiveSession,
) -> Result<State> {
    let current = account(owner, deployment, Some(live))?;
    let history = History::load(owner)?;
    if let Some(index) = history.matching(&current) {
        let journal = &history.entries[index];
        return if let Some(binding) = &journal.created {
            if history.legacy {
                key_store::check_admission_locked(owner, binding)?;
            } else {
                check_target(owner, binding)?;
            }
            Ok(State::Created)
        } else {
            if source(owner)? != journal.source {
                return Err(Failure::ReviewRequired);
            }
            Ok(State::Requested)
        };
    }
    if !history.entries.is_empty() {
        return Err(Failure::ReviewRequired);
    }
    match source(owner) {
        Ok(_) => Ok(State::Available),
        Err(Failure::ExistingLibrary) => Ok(State::ExistingLibrary),
        Err(e) => Err(e),
    }
}
/// Offline inspection only: no secret namespace, request, key or HTTP is created.
pub fn status<B: Backend>(
    store: &mut Store<B>,
    client: &CloudClient,
    live: &LiveSession,
) -> Result<State> {
    store.transaction_with(|owner| status_locked(owner, &client.credential_deployment(), live))
}
/// The retained creation receipt binds later key setup, pairing and disclosure.
/// It must not disappear from admission merely because no key is installed yet.
pub(crate) fn check_target<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> key_store::Result<()> {
    key_store::handover::require_idle(owner)?;
    let result: Result<()> = (|| {
        let history = History::load(owner)?;
        check_history_target(owner, &history, binding, None)
    })();
    result.map_err(key_failure)
}
/// The same admission predicate evaluates the real document and its proposed
/// remainder. Do not approximate this with a binding hash or matching account.
fn check_history_target<B: Backend>(
    owner: &mut Locked<'_, B>,
    history: &History,
    binding: &KeyBinding,
    excluded: Option<usize>,
) -> Result<()> {
    let retained = || {
        history
            .entries
            .iter()
            .enumerate()
            .filter_map(|(index, entry)| (Some(index) != excluded).then_some(entry))
    };
    if retained().next().is_none() {
        return Ok(());
    }
    // A retained creation pins its complete library identity. A changed
    // account, membership, dataset or epoch requires the separate review.
    if let Some(journal) = retained().find(|entry| {
        entry
            .created
            .as_ref()
            .is_some_and(|created| created.same_library(binding))
    }) {
        if journal.created.as_ref() != Some(binding)
            || account(owner, &journal.account.deployment, None)? != journal.account
        {
            return Err(Failure::ReviewRequired);
        }
        return Ok(());
    }
    // Creation beside an existing library must leave its original admission
    // available while new keys are prepared and reviewed separately.
    if key_store::installed_binding_locked(owner)?.as_ref() == Some(binding) {
        for journal in retained() {
            if journal.source.as_ref() == Some(binding) {
                match account(owner, &journal.account.deployment, None) {
                    Ok(current) if current == journal.account => return Ok(()),
                    Ok(_) | Err(Failure::ReviewRequired) => (),
                    Err(error) => return Err(error),
                }
            }
        }
    }
    if retained().any(|entry| entry.created.is_none()) {
        Err(Failure::Account(super::Failure::Busy))
    } else {
        Err(Failure::ReviewRequired)
    }
}
fn key_failure(e: Failure) -> key_store::Failure {
    match e {
        Failure::Secret(e) => key_store::Failure::Secret(e),
        Failure::Account(super::Failure::Busy) => key_store::Failure::Busy,
        Failure::InvalidState | Failure::Key(key_store::Failure::InvalidState) => {
            key_store::Failure::InvalidState
        }
        _ => key_store::Failure::ReviewRequired,
    }
}

pub(crate) fn verify_retirement_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    retired: &KeyBinding,
) -> key_store::Result<()> {
    let active = key_store::installed_binding_locked(owner)?
        .ok_or(key_store::Failure::RecoveryUnavailable)?;
    // The receipt for an installed target remains its account/admission guard.
    // It can be retired with the old library's switch archive after switching.
    if active.same_library(retired) {
        return Err(key_store::Failure::Busy);
    }
    let history = History::load(owner).map_err(key_failure)?;
    check_history_target(owner, &history, &active, None).map_err(key_failure)?;
    if key_store::capacity::creation_candidate_pending_locked(owner, retired)? {
        return Err(key_store::Failure::Busy);
    }
    Ok(())
}
fn removable<B: Backend>(
    owner: &mut Locked<'_, B>,
    history: &History,
    index: usize,
) -> key_store::Result<bool> {
    if !locally_removable(owner, history, index)? {
        return Ok(false);
    }
    let Some(created) = history.entries[index].created.as_ref() else {
        return Ok(false);
    };
    match verify_retirement_locked(owner, created) {
        Ok(()) => (),
        Err(
            key_store::Failure::Busy
            | key_store::Failure::ReviewRequired
            | key_store::Failure::RecoveryUnavailable,
        ) => return Ok(false),
        Err(error) => return Err(error),
    }
    let active = key_store::installed_binding_locked(owner)?
        .ok_or(key_store::Failure::RecoveryUnavailable)?;
    match check_history_target(owner, history, &active, Some(index)).map_err(key_failure) {
        Ok(()) => Ok(true),
        Err(key_store::Failure::Busy | key_store::Failure::ReviewRequired) => Ok(false),
        Err(error) => Err(error),
    }
}
/// Catalogue inspection is credential-free. These structural checks only offer
/// a review action; the complete account/admission predicate runs on prepare,
/// after fresh authorization and when resuming durable consent.
fn locally_removable<B: Backend>(
    owner: &mut Locked<'_, B>,
    history: &History,
    index: usize,
) -> key_store::Result<bool> {
    let Some(created) = history.entries[index].created.as_ref() else {
        return Ok(false);
    };
    if history.legacy || history.generation.checked_add(1).is_none() {
        return Ok(false);
    }
    let Some(active) = key_store::installed_binding_locked(owner)? else {
        return Ok(false);
    };
    if active.same_library(created)
        || key_store::capacity::creation_candidate_pending_locked(owner, created)?
    {
        return Ok(false);
    }
    let witness = |entry: &Journal| {
        entry.created.as_ref() == Some(&active) || entry.source.as_ref() == Some(&active)
    };
    Ok(history.entries.iter().any(witness)
        && (history.entries.len() == 1
            || history
                .entries
                .iter()
                .enumerate()
                .any(|(other, entry)| other != index && witness(entry))))
}
pub(crate) fn history_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> key_store::Result<Vec<key_store::history::SavedCreation>> {
    use key_store::{
        capacity,
        history::{CreationPhase, SavedCreation, SavedLibrary},
    };
    let history = History::load(owner).map_err(key_failure)?;
    history
        .entries
        .iter()
        .enumerate()
        .map(|(index, entry)| {
            Ok(SavedCreation {
                removal: locally_removable(owner, &history, index)?.then(|| {
                    capacity::Selection::new(
                        capacity::Section::Creations,
                        index,
                        history
                            .snapshot
                            .as_ref()
                            .expect("validated creation history"),
                    )
                }),
                library: entry.created.as_ref().map(SavedLibrary::new),
                source: entry.source.as_ref().map(SavedLibrary::new),
                phase: if entry.created.is_some() {
                    CreationPhase::Created
                } else {
                    CreationPhase::Requested
                },
            })
        })
        .collect()
}
pub(crate) fn removal_document_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> key_store::Result<key_store::capacity::Document> {
    use key_store::capacity::{Document, Row};
    let history = History::load(owner).map_err(key_failure)?;
    if history.legacy {
        return Err(key_store::Failure::Busy);
    }
    let rows = history
        .entries
        .iter()
        .enumerate()
        .map(|(index, entry)| {
            Ok(Row {
                libraries: entry.created.iter().cloned().collect(),
                eligible: removable(owner, &history, index)?,
                images: None,
            })
        })
        .collect::<key_store::Result<Vec<_>>>()?;
    Document::validated(history.snapshot, history.generation, rows)
}
trait Remote {
    fn deployment(&self) -> Deployment;
    fn preflight(&mut self) -> Result<()>;
    fn create(&mut self, token: &Credential, request: Uuid) -> Result<Space>;
    fn observe(&mut self, token: &Credential, id: Uuid) -> Result<Space>;
}
struct Client<'a>(&'a CloudClient);
impl Remote for Client<'_> {
    fn deployment(&self) -> Deployment {
        self.0.credential_deployment()
    }
    fn preflight(&mut self) -> Result<()> {
        Ok(self.0.preflight_credentials()?)
    }
    fn create(&mut self, token: &Credential, request: Uuid) -> Result<Space> {
        Ok(self.0.create_space(token, request)?)
    }
    fn observe(&mut self, token: &Credential, id: Uuid) -> Result<Space> {
        Ok(self.0.observe_space(token, id)?)
    }
}
/// Explicit user action. The serialized secure-store owner spans the HTTP work.
pub fn create_or_resume<B: Backend>(
    store: &mut Store<B>,
    client: &CloudClient,
    live: &LiveSession,
) -> Result<Space> {
    store.transaction_with(|owner| create_locked(owner, &mut Client(client), live))
}
pub fn begin_new<B: Backend>(
    store: &mut Store<B>,
    client: &CloudClient,
    live: &LiveSession,
    intent: NewIntent,
) -> Result<Space> {
    store.transaction_with(|owner| create_mode(owner, &mut Client(client), live, Some(intent)))
}
fn create_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    live: &LiveSession,
) -> Result<Space> {
    create_mode(owner, remote, live, None)
}
fn create_mode<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    live: &LiveSession,
    intent: Option<NewIntent>,
) -> Result<Space> {
    key_store::handover::require_idle(owner).map_err(|failure| match failure {
        key_store::Failure::Secret(failure) => Failure::Secret(failure),
        failure => Failure::Key(failure),
    })?;
    let deployment = remote.deployment();
    let current = account(owner, &deployment, Some(live))?;
    let mut history = History::load(owner)?;
    let captured = Captured::new(owner)?;
    let index = if let Some(intent) = intent.as_ref() {
        intent.fresh()?;
        if intent.account != current
            || intent.fingerprint
                != captured.fingerprint(history.snapshot.as_deref().map(Vec::as_slice))
        {
            return Err(Failure::ReviewRequired);
        }
        if !can_new(&history, &current) {
            return Err(Failure::RetentionFull);
        }
        history.legacy = false;
        history.entries.push(Journal {
            account: current,
            request: intent.request,
            created: None,
            source: captured.binding.clone(),
        });
        history.save(owner)?;
        history.entries.len() - 1
    } else if let Some(index) = history.matching(&current) {
        index
    } else {
        if !history.entries.is_empty() {
            return Err(Failure::ReviewRequired);
        }
        if !can_new(&history, &current) {
            return Err(Failure::RetentionFull);
        }
        history.entries.push(Journal {
            account: current,
            request: Uuid::new_v4(),
            created: None,
            source: captured.binding.clone(),
        });
        history.save(owner)?;
        0
    };
    if history.entries[index].created.is_none() {
        if captured.binding != history.entries[index].source {
            return Err(Failure::ReviewRequired);
        }
        history
            .generation
            .checked_add(1)
            .ok_or(Failure::RetentionFull)?;
        remote.preflight()?;
        if let Some(intent) = intent.as_ref() {
            intent.fresh()?;
        }
        history.check(owner)?;
        captured.check(owner)?;
        if account(owner, &deployment, Some(live))? != history.entries[index].account {
            return Err(Failure::ReviewRequired);
        }
        let space = remote.create(live.access()?, history.entries[index].request)?;
        let binding = space.key_binding(&deployment)?;
        if space.role != Role::Owner {
            return Err(Failure::ReviewRequired);
        }
        // Retain validated metadata before checking the post-request deadline.
        // Expired UI publication still leaves the original space owned durably.
        if captured
            .binding
            .as_ref()
            .is_some_and(|source| source.same_library(&binding))
            || history.entries.iter().any(|entry| {
                entry
                    .created
                    .as_ref()
                    .is_some_and(|created| created.same_library(&binding))
            })
        {
            return Err(Failure::ReviewRequired);
        }
        history.entries[index].created = Some(binding);
        history.save(owner)?;
    }
    let binding = history.entries[index]
        .created
        .as_ref()
        .ok_or(Failure::InvalidState)?;
    if let Some(intent) = intent.as_ref() {
        intent.fresh()?;
    }
    history.check(owner)?;
    captured.check(owner)?;
    if history.legacy {
        key_store::check_admission_locked(owner, binding)?;
    } else {
        check_target(owner, binding)?;
    }
    if account(owner, &deployment, Some(live))? != history.entries[index].account {
        return Err(Failure::ReviewRequired);
    }
    remote.preflight()?;
    if let Some(intent) = intent.as_ref() {
        intent.fresh()?;
    }
    history.check(owner)?;
    captured.check(owner)?;
    let space = remote.observe(live.access()?, binding.space())?;
    if space.key_binding(&deployment)? != *binding {
        return Err(Failure::ReviewRequired);
    }
    remote.preflight()?;
    history.check(owner)?;
    captured.check(owner)?;
    if let Some(intent) = intent.as_ref() {
        intent.fresh()?;
    }
    if account(owner, &deployment, Some(live))? != history.entries[index].account {
        return Err(Failure::ReviewRequired);
    }
    if history.legacy {
        key_store::check_admission_locked(owner, binding)?;
    } else {
        check_target(owner, binding)?;
    }
    Ok(space)
}
fn object<const N: usize>(fields: [(&str, Value); N]) -> Value {
    Value::Object(fields.into_iter().map(|(k, v)| (k.into(), v)).collect())
}
fn exact<'a>(value: &'a Value, names: &[&str]) -> Result<&'a BTreeMap<String, Value>> {
    let fields = value.as_object()?;
    if fields.len() != names.len() || !names.iter().all(|name| fields.contains_key(*name)) {
        return Err(Failure::InvalidState);
    }
    Ok(fields)
}

#[cfg(test)]
#[path = "space_creation_tests.rs"]
pub(crate) mod tests;
