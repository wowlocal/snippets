//! Recipient pairing for a reviewed library switch. Received keys remain in a
//! separate protected history; this owner never installs a key or edits a journal.
use super::*;
use crate::bootstrap::{Invitation, PairingDraft, PendingPairing};
use recipient::{Phase, Remote};

const MAX_ENTRIES: usize = 8;
pub enum Status {
    Creating,
    Waiting {
        invitation: Invitation,
        received: bool,
    },
    Cancelling,
    Ready,
    Cancelled,
}
pub struct Rejected {
    pub failure: Failure,
    pub unrecorded: Option<Unrecorded>,
}
pub type Result<T> = std::result::Result<T, Rejected>;
impl From<Failure> for Rejected {
    fn from(failure: Failure) -> Self {
        Self {
            failure,
            unrecorded: None,
        }
    }
}
impl From<secret_store::Failure> for Rejected {
    fn from(value: secret_store::Failure) -> Self {
        Failure::from(value).into()
    }
}
impl From<bootstrap::Failure> for Rejected {
    fn from(value: bootstrap::Failure) -> Self {
        Failure::from(value).into()
    }
}
pub struct Unrecorded {
    archive: Box<Archive>,
    target: Zeroizing<Vec<u8>>,
}
impl Unrecorded {
    /// Retain an already received response without network, active-key admission
    /// or a fresh token. This grants no permission to activate the candidate.
    pub fn retain<B: Backend>(mut self, store: &mut Store<B>) -> Result<()> {
        let result: super::Result<()> = store.transaction_with(|owner| {
            let current = owner.read(Slot::PairingCandidate)?;
            if current.as_deref() == Some(&self.target) {
                Archive::load(owner)?;
                return Ok(());
            }
            if current != self.archive.snapshot {
                return Err(Failure::Secret(secret_store::Failure::Stale));
            }
            self.archive.save(owner)
        });
        result.map_err(|failure| Rejected {
            failure,
            unrecorded: Some(self),
        })
    }
}
struct Entry {
    binding: KeyBinding,
    account: Option<[u8; 32]>,
    phase: Phase,
    ready: bool,
    cancelled: bool,
}
impl Entry {
    fn validate(&self) -> super::Result<()> {
        self.phase.validate(&self.binding)?;
        if self.ready && (self.cancelled || !matches!(self.phase, Phase::Claimed { .. }))
            || self.cancelled
                && !matches!(self.phase, Phase::Creating { .. } | Phase::Cancelling(_))
        {
            return Err(Failure::InvalidState);
        }
        Ok(())
    }
    fn value(&self) -> super::Result<Value> {
        self.validate()?;
        Ok(object([
            ("binding", self.binding.value()),
            (
                "account",
                self.account
                    .map_or(Value::Null, |v| Value::text(STANDARD.encode(v))),
            ),
            ("phase", self.phase.value()?),
            ("ready", Value::Bool(self.ready)),
            ("cancelled", Value::Bool(self.cancelled)),
        ]))
    }
    fn parse(value: &Value) -> super::Result<Self> {
        let fields = exact(
            value,
            &["binding", "account", "phase", "ready", "cancelled"],
        )?;
        let Value::Bool(ready) = fields["ready"] else {
            return Err(Failure::InvalidState);
        };
        let Value::Bool(cancelled) = fields["cancelled"] else {
            return Err(Failure::InvalidState);
        };
        let entry = Self {
            binding: KeyBinding::parse(&fields["binding"])?,
            account: optional(&fields["account"], |v| {
                decode64(v.as_text()?, 32)?
                    .as_slice()
                    .try_into()
                    .map_err(|_| Failure::InvalidState)
            })?,
            phase: Phase::parse(&fields["phase"])?,
            ready,
            cancelled,
        };
        entry.validate()?;
        Ok(entry)
    }
    fn status(&self) -> Status {
        if self.cancelled {
            return Status::Cancelled;
        }
        if self.ready {
            return Status::Ready;
        }
        match &self.phase {
            Phase::Creating { .. } => Status::Creating,
            Phase::Waiting(p) => Status::Waiting {
                invitation: p.invitation().clone(),
                received: false,
            },
            Phase::Claimed { pending, .. } => Status::Waiting {
                invitation: pending.invitation().clone(),
                received: true,
            },
            Phase::Cancelling(_) => Status::Cancelling,
        }
    }
}
struct Archive {
    generation: i64,
    entries: Vec<Entry>,
    snapshot: Option<Zeroizing<Vec<u8>>>,
}
impl Archive {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> super::Result<Self> {
        let snapshot = owner.read(Slot::PairingCandidate)?;
        let mut result = Self {
            generation: 0,
            entries: Vec::new(),
            snapshot,
        };
        if let Some(bytes) = &result.snapshot {
            let value = canonical::parse(bytes)?;
            let fields = exact(&value, &["schema", "generation", "entries"])?;
            result.generation = fields["generation"].as_int()?;
            let entries = fields["entries"].as_array()?;
            let schema = fields["schema"].as_int()?;
            if !matches!(schema, 1..=2)
                || result.generation < 1
                || entries.is_empty() && schema < 2
                || entries.len() > MAX_ENTRIES
            {
                return Err(Failure::InvalidState);
            }
            for (index, value) in entries.iter().enumerate() {
                let entry = Entry::parse(value)?;
                if !entry.ready && !entry.cancelled && index + 1 != entries.len() {
                    return Err(Failure::InvalidState);
                }
                result.entries.push(entry);
            }
        }
        Ok(result)
    }
    fn pending(&self) -> Option<&Entry> {
        self.entries.last().filter(|e| !e.ready && !e.cancelled)
    }
    fn matching(&self, binding: &KeyBinding, account: Option<[u8; 32]>) -> Option<&Entry> {
        self.entries
            .iter()
            .rev()
            .find(|e| e.binding == *binding && e.account == account)
    }
    fn next_bytes(&self) -> super::Result<Zeroizing<Vec<u8>>> {
        if self.entries.is_empty() || self.entries.len() > MAX_ENTRIES {
            return Err(Failure::InvalidState);
        }
        let bytes = object([
            ("schema", Value::Int(2)),
            (
                "generation",
                Value::Int(
                    self.generation
                        .checked_add(1)
                        .ok_or(Failure::InvalidState)?,
                ),
            ),
            (
                "entries",
                Value::Array(
                    self.entries
                        .iter()
                        .map(Entry::value)
                        .collect::<super::Result<_>>()?,
                ),
            ),
        ])
        .encode()?;
        if bytes.len() > secret_store::MAX_SECRET_BYTES {
            return Err(Failure::Busy);
        }
        Ok(bytes)
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> super::Result<()> {
        let bytes = self.next_bytes()?;
        owner.replace(
            Slot::PairingCandidate,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        self.generation += 1;
        Ok(())
    }
    fn reserve_response(&self) -> super::Result<()> {
        // A valid response must always fit a durable receipt and its final
        // verification write, including after reopening a bounded archive.
        self.generation
            .checked_add(2)
            .ok_or(Failure::InvalidState)?;
        if self.next_bytes()?.len() + 2 * bootstrap::MAX_ENVELOPE_BYTES + 4096
            > secret_store::MAX_SECRET_BYTES
        {
            return Err(Failure::Busy);
        }
        Ok(())
    }
    fn save_receipt<B: Backend>(mut self, owner: &mut Locked<'_, B>) -> Result<Self> {
        let target = self.next_bytes()?;
        match self.save(owner) {
            Ok(()) => Ok(self),
            Err(failure) => Err(Rejected {
                failure,
                unrecorded: Some(Unrecorded {
                    archive: Box::new(self),
                    target,
                }),
            }),
        }
    }
}
fn account<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> super::Result<Option<[u8; 32]>> {
    handover::account_hash(owner, binding).map_err(|e| match e {
        handover::Failure::Key(e) => e,
        _ => Failure::ReviewRequired,
    })
}
pub fn inspect<B: Backend>(
    store: &mut Store<B>,
    binding: &KeyBinding,
) -> super::Result<Option<Status>> {
    store.transaction_with(|owner| {
        let saved = Archive::load(owner)?;
        let account = account(owner, binding)?;
        if let Some(entry) = saved.pending()
            && (entry.binding != *binding || entry.account != account)
        {
            return Err(Failure::ReviewRequired);
        }
        Ok(saved.matching(binding, account).map(Entry::status))
    })
}
pub(super) fn history_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> super::Result<Vec<super::history::SavedPairing>> {
    use super::history::{PairingPhase, SavedLibrary, SavedPairing};
    let saved = Archive::load(owner)?;
    Ok(saved
        .entries
        .iter()
        .enumerate()
        .map(|(index, entry)| SavedPairing {
            removal: (entry.ready || entry.cancelled).then(|| {
                capacity::Selection::new(
                    capacity::Section::Pairing,
                    index,
                    saved.snapshot.as_ref().expect("validated archive"),
                )
            }),
            library: SavedLibrary::new(&entry.binding),
            phase: if entry.cancelled {
                PairingPhase::Cancelled
            } else if entry.ready {
                PairingPhase::Ready
            } else {
                match &entry.phase {
                    Phase::Creating { .. } => PairingPhase::Creating,
                    Phase::Waiting(_) => PairingPhase::Waiting,
                    Phase::Claimed { .. } => PairingPhase::Claimed,
                    Phase::Cancelling(_) => PairingPhase::Cancelling,
                }
            },
        })
        .collect())
}
pub(super) fn removal_document_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> super::Result<capacity::Document> {
    let saved = Archive::load(owner)?;
    let rows = saved
        .entries
        .iter()
        .map(|entry| capacity::Row {
            libraries: vec![entry.binding.clone()],
            eligible: entry.ready || entry.cancelled,
            images: None,
        })
        .collect();
    capacity::Document::validated(saved.snapshot, saved.generation, rows)
}
pub(super) fn retained_bundle<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> super::Result<Option<Bundle>> {
    let saved = Archive::load(owner)?;
    let account = account(owner, binding)?;
    let Some(entry) = saved
        .entries
        .iter()
        .rev()
        .find(|e| e.ready && e.binding == *binding && e.account == account)
    else {
        return Ok(None);
    };
    let Phase::Claimed {
        pending,
        ciphertext,
    } = &entry.phase
    else {
        return Err(Failure::InvalidState);
    };
    Ok(Some(bootstrap::open_retained_pairing(ciphertext, pending)?))
}
/// Claimed material remains locally owned after scope/account changes, even if
/// final verification was interrupted. Only explicit fresh review can reuse it.
pub(super) fn review_keys<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> super::Result<Vec<ReviewKey>> {
    let account = account(owner, binding)?;
    let mut keys = Vec::new();
    if let Some(bundle) = retained_bundle(owner, binding)? {
        keys.push((
            Installed {
                binding: binding.clone(),
                bundle,
            },
            None,
        ));
    }
    let saved = Archive::load(owner)?;
    for entry in saved.entries.into_iter().rev() {
        if entry.cancelled
            || !entry.binding.same_library(binding)
            || entry.ready && entry.binding == *binding && entry.account == account
        {
            continue;
        }
        if let Phase::Claimed {
            pending,
            ciphertext,
        } = entry.phase
        {
            let bundle = bootstrap::open_retained_pairing(&ciphertext, &pending)?;
            keys.push((
                Installed {
                    binding: entry.binding,
                    bundle,
                },
                None,
            ));
        }
    }
    Ok(keys)
}
/// Finish only a durably owned claim whose key has just been activated through
/// exact authorized review. Preserve its original pin/account and private proof.
pub(super) fn complete_reviewed<B: Backend>(
    owner: &mut Locked<'_, B>,
    target: &Installed,
) -> super::Result<()> {
    let mut saved = Archive::load(owner)?;
    let mut changed = false;
    for entry in &mut saved.entries {
        if entry.ready || entry.cancelled || !entry.binding.same_library(&target.binding) {
            continue;
        }
        if let Phase::Claimed {
            pending,
            ciphertext,
        } = &entry.phase
        {
            let bundle = bootstrap::open_retained_pairing(ciphertext, pending)?;
            if bundle.for_secure_storage() == target.bundle.for_secure_storage() {
                entry.ready = true;
                changed = true;
            }
        }
    }
    if changed {
        saved.save(owner)?;
    }
    Ok(())
}
#[derive(Clone, Copy)]
pub enum Action {
    Begin,
    Check,
    Cancel,
}
pub fn operate<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    action: Action,
    validate: impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Status> {
    store.transaction_with(|owner| operate_locked(owner, remote, action, &validate))
}
pub(super) fn operate_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    action: Action,
    validate: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Status> {
    validate(owner)?;
    handover::require_idle(owner)?;
    remote.preflight()?;
    validate(owner)?;
    let binding = remote.binding()?;
    initial_candidate::require_pairing_idle(owner, &binding)?;
    // Control-plane pairing beside old keys never reads mixed primary files or
    // initializes checkpoint material. It grants no data-plane admission.
    let old = owner
        .read(Slot::LibraryKey)?
        .ok_or(Failure::ReviewRequired)?;
    Installed::decode(&old)?;
    let credentials = owner.read(Slot::Credentials)?;
    let account = account(owner, &binding)?;
    let guard = |owner: &mut Locked<'_, B>| -> super::Result<()> {
        validate(owner)?;
        if owner.read(Slot::Credentials)? != credentials
            || owner.read(Slot::LibraryKey)?.as_deref() != Some(&old)
        {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    };
    let mut saved = Archive::load(owner)?;
    if let Some(entry) = saved.pending()
        && (entry.binding != binding || entry.account != account)
    {
        return Err(Failure::ReviewRequired.into());
    }
    let matching = saved.matching(&binding, account);
    if matching.is_some_and(|e| e.ready) {
        let entry = matching.unwrap();
        let Phase::Claimed {
            pending,
            ciphertext,
        } = &entry.phase
        else {
            return Err(Failure::InvalidState.into());
        };
        let bundle = bootstrap::open_retained_pairing(ciphertext, pending)?;
        verify_remote(remote, &binding, &bundle)?;
        guard(owner)?;
        return Ok(Status::Ready);
    }
    if matches!(action, Action::Begin) && saved.pending().is_none() {
        if remote.role() == Role::Reader {
            return Err(Failure::Cloud(cloud::Failure::ReadOnly).into());
        }
        if saved.entries.len() >= MAX_ENTRIES {
            return Err(Failure::Busy.into());
        }
        if remote.authority()?.is_none() {
            return Err(Failure::KeyConflict.into());
        }
        check_remote(remote, &binding)?;
        guard(owner)?;
        saved.entries.push(Entry {
            binding: binding.clone(),
            account,
            phase: Phase::Creating {
                draft: PairingDraft::generate()?,
                sent: false,
            },
            ready: false,
            cancelled: false,
        });
        // Reserve space for the maximum claim before sending a non-idempotent
        // create request. Old candidates never get evicted to make room.
        saved.reserve_response()?;
        saved.save(owner)?;
    }
    if saved.pending().is_none() {
        return Err(Failure::InvalidState.into());
    }
    if matches!(action, Action::Cancel) {
        let entry = saved.entries.last_mut().ok_or(Failure::InvalidState)?;
        match &entry.phase {
            Phase::Claimed { .. } => return Err(Failure::Busy.into()),
            Phase::Creating { .. } => {
                entry.cancelled = true;
                guard(owner)?;
                saved.save(owner)?;
                return Ok(Status::Cancelled);
            }
            Phase::Waiting(p) => {
                entry.phase =
                    Phase::Cancelling(PendingPairing::decode_retained_secret(&p.encode_secret()?)?)
            }
            Phase::Cancelling(_) => (),
        }
        guard(owner)?;
        saved.save(owner)?;
    }
    advance(owner, remote, saved, &guard)
}
fn advance<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    mut saved: Archive,
    guard: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Status> {
    let binding = saved
        .entries
        .last()
        .ok_or(Failure::InvalidState)?
        .binding
        .clone();
    check_remote(remote, &binding)?;
    guard(owner)?;
    let entry = saved.entries.last_mut().ok_or(Failure::InvalidState)?;
    match &mut entry.phase {
        Phase::Creating { sent: true, .. } => Ok(Status::Creating),
        Phase::Creating { sent, .. } => {
            *sent = true;
            saved.save(owner)?;
            saved.reserve_response()?;
            guard(owner)?;
            check_remote(remote, &binding)?;
            let Phase::Creating { draft, .. } =
                &saved.entries.last().ok_or(Failure::InvalidState)?.phase
            else {
                return Err(Failure::InvalidState.into());
            };
            let result = remote.create(draft)?;
            if result.state() != cloud::PairingState::Pending {
                return Err(Failure::InvalidState.into());
            }
            let draft = PairingDraft::decode_secret(&draft.encode_secret()?)?;
            let pending = PendingPairing::new(draft, result.invitation().clone())?;
            let invitation = pending.invitation().clone();
            saved.entries.last_mut().ok_or(Failure::InvalidState)?.phase = Phase::Waiting(pending);
            saved.save_receipt(owner)?;
            check_remote(remote, &binding)?;
            guard(owner)?;
            Ok(Status::Waiting {
                invitation,
                received: false,
            })
        }
        Phase::Waiting(pending) => {
            let result = remote.poll(pending.invitation())?;
            check_remote(remote, &binding)?;
            guard(owner)?;
            let pending = match &saved.entries.last().ok_or(Failure::InvalidState)?.phase {
                Phase::Waiting(p) => p,
                _ => return Err(Failure::InvalidState.into()),
            };
            if result.invitation() != pending.invitation() {
                return Err(Failure::InvalidState.into());
            }
            if result.state() == cloud::PairingState::Pending {
                return Ok(saved.entries.last().ok_or(Failure::InvalidState)?.status());
            }
            saved.reserve_response()?;
            let ciphertext = remote.claim(&result)?;
            let pending = PendingPairing::decode_retained_secret(&pending.encode_secret()?)?;
            saved.entries.last_mut().ok_or(Failure::InvalidState)?.phase = Phase::Claimed {
                pending,
                ciphertext,
            };
            let saved = saved.save_receipt(owner)?;
            check_remote(remote, &binding)?;
            guard(owner)?;
            advance(owner, remote, saved, guard)
        }
        Phase::Claimed {
            pending,
            ciphertext,
        } => {
            let bundle = bootstrap::open_retained_pairing(ciphertext, pending)?;
            verify_remote(remote, &binding, &bundle)?;
            guard(owner)?;
            saved.entries.last_mut().ok_or(Failure::InvalidState)?.ready = true;
            saved.save(owner)?;
            guard(owner)?;
            Ok(Status::Ready)
        }
        Phase::Cancelling(pending) => {
            remote.cancel(pending.invitation())?;
            check_remote(remote, &binding)?;
            guard(owner)?;
            saved
                .entries
                .last_mut()
                .ok_or(Failure::InvalidState)?
                .cancelled = true;
            saved.save(owner)?;
            Ok(Status::Cancelled)
        }
    }
}

#[cfg(test)]
#[path = "pairing_candidate_tests.rs"]
mod tests;
