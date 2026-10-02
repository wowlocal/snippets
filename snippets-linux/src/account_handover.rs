//! Durable ownership of an explicitly confirmed account/library/key handover.
//! All old capabilities stay in Secret Service history. A pending transition
//! fences ordinary key/data operations until the exact journal receipt and all
//! new active slots are confirmed. No secret is written to a plaintext file.
use super::*;
use crate::local_auth::{Permit, Purpose, Target};
use crate::{account_review, model::Library, receiver};
use std::{cell::RefCell, path::Path};

#[path = "account_local_finish.rs"]
mod local_completion;
pub use local_completion::{finish_local, prepare_local_authorization};

const MAX_ENTRIES: usize = 8;
const SLOTS: [(Slot, &str); 5] = [
    (Slot::LibraryKey, "libraryKey"),
    (Slot::Bootstrap, "bootstrap"),
    (Slot::PairingRecipient, "pairingRecipient"),
    (Slot::SpaceCreation, "spaceCreation"),
    (Slot::KeyMutation, "keyMutation"),
];
const CANDIDATE_SLOTS: [Slot; 2] = [Slot::BootstrapCandidate, Slot::PairingCandidate];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Key(super::Failure),
    Journal(account_review::Failure),
    Unavailable,
    Changed,
    RetentionFull,
    Unpublished,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<super::Failure> for Failure {
    fn from(value: super::Failure) -> Self {
        Self::Key(value)
    }
}
impl From<secret_store::Failure> for Failure {
    fn from(value: secret_store::Failure) -> Self {
        Self::Key(value.into())
    }
}
impl From<bootstrap::Failure> for Failure {
    fn from(value: bootstrap::Failure) -> Self {
        Self::Key(value.into())
    }
}
impl From<crate::model::Error> for Failure {
    fn from(value: crate::model::Error) -> Self {
        Self::Key(value.into())
    }
}
impl From<crate::local_auth::Failure> for Failure {
    fn from(value: crate::local_auth::Failure) -> Self {
        Self::Key(value.into())
    }
}
impl From<account_review::Failure> for Failure {
    fn from(value: account_review::Failure) -> Self {
        Self::Journal(value)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub pending: bool,
    pub retained_libraries: usize,
    pub summary: Option<account_review::Summary>,
}
/// Opaque, process-local consent target. Only its aggregate summary leaves the
/// account worker; closing a review does not authorize any slot replacement.
pub struct Review {
    entry: Entry,
    journal: account_review::Review,
    archive_snapshot: Option<Zeroizing<Vec<u8>>>,
    credentials_snapshot: Option<Zeroizing<Vec<u8>>>,
    candidate_snapshots: [Option<Zeroizing<Vec<u8>>>; 2],
    reused_local_key: bool,
    generation: i64,
}
impl Review {
    pub fn summary(&self) -> account_review::Summary {
        self.journal.summary()
    }
    pub fn reuses_local_key(&self) -> bool {
        self.reused_local_key
    }
    pub fn authorization_target(&self) -> Result<Target> {
        self.entry
            .authorization_target(Purpose::SwitchLibrary, self.generation)
    }
}
struct Entry {
    completed: bool,
    cancelled: bool,
    receipt: account_review::Receipt,
    source: [Option<Zeroizing<Vec<u8>>>; 5],
    target_key: Zeroizing<Vec<u8>>,
    target_bootstrap: Zeroizing<Vec<u8>>,
    checkpoint: Zeroizing<Vec<u8>>,
    account_hash: Option<[u8; 32]>,
}
impl Entry {
    fn installed(&self) -> Result<Installed> {
        Ok(Installed::decode(&self.target_key)?)
    }
    fn validate(&self) -> Result<()> {
        if self.checkpoint.len() != 64 || self.completed && self.cancelled {
            return Err(super::Failure::InvalidState.into());
        }
        let previous = Installed::decode(
            self.source[0]
                .as_deref()
                .ok_or(super::Failure::InvalidState)?,
        )?;
        let target = self.installed()?;
        let (scope, epoch) = self.receipt.target();
        if previous.binding.checkpoint_scope() != self.receipt.previous().scope
            || previous.binding.epoch != self.receipt.previous().key_epoch
            || target.binding.checkpoint_scope() != *scope
            || target.binding.epoch != epoch
            || self.receipt.previous().key_material_changed
                != (previous.bundle.for_secure_storage() != target.bundle.for_secure_storage()
                    || previous.binding != target.binding
                        && previous.binding.checkpoint_scope() == *scope
                        && previous.binding.epoch == epoch)
        {
            return Err(super::Failure::InvalidState.into());
        }
        let source = super::Archive::from_snapshot(self.source[1].clone())?;
        source.check_binding(&previous.binding)?;
        validate_presentation(&source, &previous)?;
        let target_archive = super::Archive::from_snapshot(Some(self.target_bootstrap.clone()))?;
        target_archive.check_binding(&target.binding)?;
        validate_presentation(&target_archive, &target)?;
        if target_archive.pending.is_some() {
            return Err(super::Failure::InvalidState.into());
        }
        Ok(())
    }
    fn value(&self) -> Result<Value> {
        self.validate()?;
        let source = Value::Object(
            SLOTS
                .iter()
                .zip(&self.source)
                .map(|((_, name), bytes)| {
                    (
                        (*name).into(),
                        bytes
                            .as_ref()
                            .map_or(Value::Null, |v| Value::text(STANDARD.encode(v))),
                    )
                })
                .collect(),
        );
        Ok(object([
            (
                "phase",
                Value::text(if self.completed {
                    "completed"
                } else if self.cancelled {
                    "cancelled"
                } else {
                    "pending"
                }),
            ),
            (
                "receipt",
                Value::text(STANDARD.encode(self.receipt.encode_secret()?)),
            ),
            ("source", source),
            ("targetKey", Value::text(STANDARD.encode(&self.target_key))),
            (
                "targetBootstrap",
                Value::text(STANDARD.encode(&self.target_bootstrap)),
            ),
            ("checkpoint", Value::text(STANDARD.encode(&self.checkpoint))),
            (
                "accountHash",
                self.account_hash
                    .map_or(Value::Null, |v| Value::text(STANDARD.encode(v))),
            ),
        ]))
    }
    fn parse(root: &Path, value: &Value, schema: i64) -> Result<Self> {
        let fields = exact(
            value,
            &[
                if schema == 1 { "completed" } else { "phase" },
                "receipt",
                "source",
                "targetKey",
                "targetBootstrap",
                "checkpoint",
                "accountHash",
            ],
        )?;
        let source_values = exact(
            &fields["source"],
            &[
                "libraryKey",
                "bootstrap",
                "pairingRecipient",
                "spaceCreation",
                "keyMutation",
            ],
        )?;
        let mut source = std::array::from_fn(|_| None);
        for (index, (_, name)) in SLOTS.iter().enumerate() {
            source[index] = optional(&source_values[*name], |v| {
                decode64(v.as_text()?, secret_store::MAX_SECRET_BYTES)
            })?;
        }
        let (completed, cancelled) = if schema == 1 {
            (fields["completed"].as_bool()?, false)
        } else {
            match fields["phase"].as_text()? {
                "pending" => (false, false),
                "completed" => (true, false),
                "cancelled" => (false, true),
                _ => return Err(super::Failure::InvalidState.into()),
            }
        };
        let entry = Self {
            completed,
            cancelled,
            receipt: account_review::Receipt::decode_secret(
                root.into(),
                &decode64(fields["receipt"].as_text()?, 318)?,
            )?,
            source,
            target_key: decode64(
                fields["targetKey"].as_text()?,
                secret_store::MAX_SECRET_BYTES,
            )?,
            target_bootstrap: decode64(
                fields["targetBootstrap"].as_text()?,
                secret_store::MAX_SECRET_BYTES,
            )?,
            checkpoint: decode64(fields["checkpoint"].as_text()?, 64)?,
            account_hash: optional(&fields["accountHash"], |v| array(v.as_text()?))?,
        };
        entry.validate()?;
        Ok(entry)
    }
    fn target(&self, index: usize) -> Option<&[u8]> {
        match index {
            0 => Some(&self.target_key),
            1 => Some(&self.target_bootstrap),
            _ => None,
        }
    }
    fn authorization_target(&self, purpose: Purpose, generation: i64) -> Result<Target> {
        let mut hash = Sha256::new();
        hash.update(b"Snippets library switch authorization v1\0");
        hash.update(self.value()?.encode()?.as_slice());
        Ok(Target::new(
            self.installed()?.binding,
            purpose,
            generation,
            hash.finalize().into(),
        )?)
    }
    fn check_slots<B: Backend>(&self, owner: &mut Locked<'_, B>, allow_target: bool) -> Result<()> {
        for (index, (slot, _)) in SLOTS.iter().enumerate() {
            let current = owner.read(*slot)?;
            let current = current.as_deref().map(Vec::as_slice);
            if current != self.source[index].as_deref().map(Vec::as_slice)
                && !(allow_target && current == self.target(index))
            {
                return Err(Failure::Changed);
            }
        }
        Ok(())
    }
    fn check_session<B: Backend>(&self, owner: &mut Locked<'_, B>) -> Result<()> {
        if account_hash(owner, &self.installed()?.binding)? != self.account_hash
            || owner
                .read(Slot::CheckpointKey)?
                .as_deref()
                .map(Vec::as_slice)
                != Some(self.checkpoint.as_slice())
        {
            return Err(Failure::Changed);
        }
        Ok(())
    }
}
struct Archive {
    generation: i64,
    entries: Vec<Entry>,
    snapshot: Option<Zeroizing<Vec<u8>>>,
}
impl Archive {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Self> {
        let snapshot = owner.read(Slot::AccountReview)?;
        let mut archive = Self {
            generation: 0,
            entries: Vec::new(),
            snapshot,
        };
        if let Some(bytes) = &archive.snapshot {
            let value = canonical::parse(bytes)?;
            let fields = exact(&value, &["schema", "generation", "entries"])?;
            let entries = fields["entries"].as_array()?;
            archive.generation = fields["generation"].as_int()?;
            let schema = fields["schema"].as_int()?;
            if !matches!(schema, 1 | 2)
                || archive.generation < 1
                || entries.is_empty()
                || entries.len() > MAX_ENTRIES
            {
                return Err(super::Failure::InvalidState.into());
            }
            let mut seen = std::collections::BTreeSet::new();
            for (index, value) in entries.iter().enumerate() {
                let entry = Entry::parse(owner.root(), value, schema)?;
                if !seen.insert(entry.receipt.transition_id())
                    || !entry.completed && !entry.cancelled && index + 1 != entries.len()
                {
                    return Err(super::Failure::InvalidState.into());
                }
                archive.entries.push(entry);
            }
        }
        Ok(archive)
    }
    fn pending(&self) -> Option<&Entry> {
        self.entries.last().filter(|e| !e.completed && !e.cancelled)
    }
    fn encoded(&self, append: Option<&Entry>) -> Result<Zeroizing<Vec<u8>>> {
        self.encoded_with_completion(append, false)
    }
    fn completed_bytes(&self) -> Result<Zeroizing<Vec<u8>>> {
        if self.pending().is_none() {
            return Err(Failure::Unavailable);
        }
        self.encoded_with_completion(None, true)
    }
    fn encoded_with_completion(
        &self,
        append: Option<&Entry>,
        complete: bool,
    ) -> Result<Zeroizing<Vec<u8>>> {
        if self.entries.len() + usize::from(append.is_some()) > MAX_ENTRIES {
            return Err(Failure::RetentionFull);
        }
        let generation = self
            .generation
            .checked_add(1)
            .ok_or(super::Failure::InvalidState)?;
        let mut values = self
            .entries
            .iter()
            .chain(append)
            .map(Entry::value)
            .collect::<Result<Vec<_>>>()?;
        if complete {
            let Some(Value::Object(fields)) = values.last_mut() else {
                return Err(super::Failure::InvalidState.into());
            };
            fields.insert("phase".into(), Value::text("completed"));
        }
        let bytes = object([
            ("schema", Value::Int(2)),
            ("generation", Value::Int(generation)),
            ("entries", Value::Array(values)),
        ])
        .encode()?;
        if bytes.len() > secret_store::MAX_SECRET_BYTES {
            return Err(Failure::RetentionFull);
        }
        Ok(bytes)
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> Result<()> {
        let bytes = self.encoded(None)?;
        owner.replace(
            Slot::AccountReview,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        self.generation += 1;
        Ok(())
    }
}
pub(crate) fn require_idle<B: Backend>(owner: &mut Locked<'_, B>) -> super::Result<()> {
    match Archive::load(owner) {
        Ok(archive) if archive.pending().is_none() => super::restoration::require_idle(owner),
        Ok(_) => Err(super::Failure::Busy),
        Err(Failure::Key(failure)) => Err(failure),
        Err(_) => Err(super::Failure::InvalidState),
    }
}
pub fn inspect<B: Backend>(store: &mut Store<B>) -> Result<Status> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        Ok(Status {
            pending: archive.pending().is_some(),
            retained_libraries: archive.entries.len(),
            summary: archive.pending().map(|e| e.receipt.summary()),
        })
    })
}
pub(super) fn history_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    library: &Library,
    active: Option<&Installed>,
    active_image: std::result::Result<Option<[u8; 32]>, ()>,
) -> Result<Vec<super::history::SavedSwitch>> {
    use super::history::{PreviousCapabilities, SavedKey, SavedSwitch, SwitchPhase, recovery};
    let archive = Archive::load(owner)?;
    let mut rows = Vec::with_capacity(archive.entries.len());
    for entry in archive.entries {
        let installed = entry.installed()?;
        let scope = installed.binding.checkpoint_scope();
        let key = RootKey::from_bytes(&entry.checkpoint[..32])
            .map_err(|_| super::Failure::InvalidState)?;
        let salt = entry.checkpoint[32..]
            .try_into()
            .map_err(|_| super::Failure::InvalidState)?;
        let journal = receiver::Owner {
            library,
            scope: &scope,
            key_epoch: installed.binding.epoch,
            checkpoint_key: &key,
            checkpoint_salt: &salt,
            wire_key: &key,
            wire_salt: &salt,
            device: None,
            validate_session: &|| Ok(()),
        };
        let source = Installed::decode(
            entry.source[0]
                .as_deref()
                .ok_or(super::Failure::InvalidState)?,
        )?;
        rows.push(SavedSwitch {
            selection: super::restoration::Selection::new(
                archive
                    .snapshot
                    .as_deref()
                    .ok_or(super::Failure::InvalidState)?,
                entry.receipt.transition_id(),
            ),
            phase: if entry.completed {
                SwitchPhase::Completed
            } else if entry.cancelled {
                SwitchPhase::Cancelled
            } else {
                SwitchPhase::Pending
            },
            source: SavedKey::new(&source, recovery(entry.source[1].clone(), &source)?, active),
            target: SavedKey::new(
                &installed,
                recovery(Some(entry.target_bootstrap.clone()), &installed)?,
                active,
            ),
            previous: PreviousCapabilities {
                pairing: entry.source[2].is_some(),
                creation: entry.source[3].is_some(),
                signed_action: entry.source[4].is_some(),
            },
            summary: entry.receipt.summary(),
            images: journal.inspect_retained_history_locked(&entry.receipt, active_image)?,
        });
    }
    Ok(rows)
}
pub(super) fn saved_local_state_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    library: &Library,
    selection: &super::restoration::Selection,
) -> Result<(crate::journal::Journal, KeyBinding)> {
    let archive = Archive::load(owner)?;
    let snapshot = archive.snapshot.as_deref().ok_or(Failure::Unavailable)?;
    if Sha256::digest(snapshot).as_slice() != selection.history_hash {
        return Err(Failure::Changed);
    }
    let entry = archive
        .entries
        .iter()
        .find(|e| e.receipt.transition_id() == selection.transition)
        .ok_or(Failure::Unavailable)?;
    if !entry.completed && !entry.cancelled {
        return Err(super::Failure::Busy.into());
    }
    let installed = entry.installed()?;
    let scope = installed.binding.checkpoint_scope();
    let key =
        RootKey::from_bytes(&entry.checkpoint[..32]).map_err(|_| super::Failure::InvalidState)?;
    let salt = entry.checkpoint[32..]
        .try_into()
        .map_err(|_| super::Failure::InvalidState)?;
    let journal = receiver::Owner {
        library,
        scope: &scope,
        key_epoch: installed.binding.epoch,
        checkpoint_key: &key,
        checkpoint_salt: &salt,
        wire_key: &key,
        wire_salt: &salt,
        device: None,
        validate_session: &|| Ok(()),
    };
    Ok((
        journal.retained_local_state_locked(&entry.receipt)?,
        installed.binding,
    ))
}
/// Remove exact promoted recovery-code copies before the active presentation's
/// saved-code receipt. Original source capabilities and encrypted images stay.
pub(super) fn retire_promoted<B: Backend>(
    owner: &mut Locked<'_, B>,
    shown: &Presentation,
) -> super::Result<()> {
    let narrow = |error| match error {
        Failure::Key(error) => error,
        _ => super::Failure::InvalidState,
    };
    let mut archive = Archive::load(owner).map_err(narrow)?;
    if archive.pending().is_some() {
        return Err(super::Failure::Busy);
    }
    let mut changed = false;
    for entry in &mut archive.entries {
        let mut target = super::Archive::from_snapshot(Some(entry.target_bootstrap.clone()))?;
        let Some(presentation) = target.presentation.as_mut() else {
            continue;
        };
        if presentation.retire_matching(shown)? {
            entry.target_bootstrap = object([
                ("schema", Value::Int(2)),
                (
                    "generation",
                    Value::Int(
                        target
                            .generation
                            .checked_add(1)
                            .ok_or(super::Failure::InvalidState)?,
                    ),
                ),
                ("pending", Value::Null),
                ("presentation", presentation.value()?),
            ])
            .encode()?;
            changed = true;
        }
    }
    if changed {
        archive.save(owner).map_err(narrow)?;
    }
    Ok(())
}
pub fn matches_pending<B: Backend>(store: &mut Store<B>, binding: &KeyBinding) -> Result<bool> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        Ok(archive
            .pending()
            .map(Entry::installed)
            .transpose()?
            .is_some_and(|i| i.binding == *binding))
    })
}
pub fn completed_for<B: Backend>(store: &mut Store<B>, binding: &KeyBinding) -> Result<bool> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        Ok(archive
            .entries
            .last()
            .filter(|e| e.completed)
            .map(Entry::installed)
            .transpose()?
            .is_some_and(|i| i.binding == *binding))
    })
}
pub fn prepare_resume_authorization<B: Backend>(store: &mut Store<B>) -> Result<Target> {
    prepare_authorization(store, Purpose::SwitchLibrary)
}
pub fn prepare_cancel_authorization<B: Backend>(store: &mut Store<B>) -> Result<Target> {
    prepare_authorization(store, Purpose::CancelLibrarySwitch)
}
fn prepare_authorization<B: Backend>(store: &mut Store<B>, purpose: Purpose) -> Result<Target> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        archive
            .pending()
            .ok_or(Failure::Unavailable)?
            .authorization_target(purpose, archive.generation)
    })
}
/// Fresh local authorization can cancel an unpublished switch while offline.
/// Keep both candidates and old capabilities in history; change no active slot,
/// checkpoint or primary file. A published target must instead finish activation.
pub fn cancel<B: Backend>(store: &mut Store<B>, permit: Permit) -> Result<()> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        let target = archive
            .pending()
            .ok_or(Failure::Unavailable)?
            .authorization_target(Purpose::CancelLibrarySwitch, archive.generation)?;
        let lease = permit.consume(&target)?;
        cancel_archive(owner, archive, &|| Ok(lease.check()?))
    })
}
fn cancel_archive<B: Backend>(
    owner: &mut Locked<'_, B>,
    mut archive: Archive,
    validate_authorization: &impl Fn() -> Result<()>,
) -> Result<()> {
    validate_authorization()?;
    let entry = archive.pending().ok_or(Failure::Unavailable)?;
    entry.check_slots(owner, false)?;
    let installed = entry.installed()?;
    let scope = installed.binding.checkpoint_scope();
    let library = Library::prepare(owner.root().into()).map_err(super::Failure::from)?;
    let key =
        RootKey::from_bytes(&entry.checkpoint[..32]).map_err(|_| super::Failure::InvalidState)?;
    let salt = entry.checkpoint[32..]
        .try_into()
        .map_err(|_| super::Failure::InvalidState)?;
    let cell = RefCell::new(&mut *owner);
    let guard = || {
        validate_authorization().map_err(|_| receiver::Failure::SessionChanged)?;
        let mut owner = cell.borrow_mut();
        if owner
            .read(Slot::CheckpointKey)
            .map_err(|_| receiver::Failure::SessionChanged)?
            .as_deref()
            != Some(&entry.checkpoint)
            || owner
                .read(Slot::AccountReview)
                .map_err(|_| receiver::Failure::SessionChanged)?
                != archive.snapshot
        {
            return Err(receiver::Failure::SessionChanged);
        }
        entry
            .check_slots(&mut owner, false)
            .map_err(|_| receiver::Failure::SessionChanged)
    };
    let journal = receiver::Owner {
        library: &library,
        scope: &scope,
        key_epoch: installed.binding.epoch,
        checkpoint_key: &key,
        checkpoint_salt: &salt,
        wire_key: &key,
        wire_salt: &salt,
        device: None,
        validate_session: &guard,
    };
    if !journal.account_review_unpublished(&entry.receipt)? {
        return Err(Failure::Unavailable);
    }
    validate_authorization()?;
    archive
        .entries
        .last_mut()
        .ok_or(Failure::Unavailable)?
        .cancelled = true;
    archive.save(owner)?;
    validate_authorization()?;
    Ok(())
}
pub(super) fn account_hash<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<Option<[u8; 32]>> {
    // Credentials are refreshed on reconnect. Bind durable consent to the
    // account/deployment, while the caller separately validates the live token
    // generation around every request. This digest stays in Secret Service.
    if owner.read(Slot::Credentials)?.is_none() {
        return Ok(None);
    }
    let archive =
        crate::auth_store::Archive::load(owner).map_err(|_| super::Failure::ReviewRequired)?;
    let deployment = archive
        .saved_deployment()
        .map_err(|_| super::Failure::ReviewRequired)?
        .ok_or(super::Failure::ReviewRequired)?;
    if !binding.matches_deployment(&deployment) {
        return Err(super::Failure::ReviewRequired.into());
    }
    let account = archive
        .account_for_refresh(&deployment)
        .map_err(|_| super::Failure::ReviewRequired)?;
    let server = deployment.server().for_secure_storage();
    let mut hash = Sha256::new();
    hash.update(b"Snippets account handover owner v1\0");
    hash.update((server.len() as u64).to_be_bytes());
    hash.update(server.as_bytes());
    hash.update(deployment.instance().as_bytes());
    hash.update((account.len() as u64).to_be_bytes());
    hash.update(account.as_bytes());
    Ok(Some(hash.finalize().into()))
}
fn verify_target(remote: &mut impl super::Remote, entry: &Entry) -> Result<()> {
    let installed = entry.installed()?;
    remote.preflight()?;
    check_remote(remote, &installed.binding)?;
    verify_remote(remote, &installed.binding, &installed.bundle)?;
    Ok(())
}
pub fn prepare<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    kit: Option<RecoveryKit>,
    validate_session: impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Review> {
    store.transaction_with(|owner| prepare_locked(owner, remote, kit, &validate_session))
}
pub(super) fn prepare_locked<B: Backend, R: super::Remote + receiver::Remote>(
    owner: &mut Locked<'_, B>,
    remote: &mut R,
    kit: Option<RecoveryKit>,
    validate_session: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Review> {
    validate_session(owner)?;
    let archive = Archive::load(owner)?;
    if archive.pending().is_some() {
        return Err(super::Failure::Busy.into());
    }
    super::Remote::preflight(remote)?;
    validate_session(owner)?;
    let binding = super::Remote::binding(remote)?;
    let mut source = std::array::from_fn(|_| None);
    for (index, (slot, _)) in SLOTS.iter().enumerate() {
        source[index] = owner.read(*slot)?;
    }
    let previous = Installed::decode(source[0].as_deref().ok_or(Failure::Unavailable)?)?;
    let old_archive = super::Archive::from_snapshot(source[1].clone())?;
    old_archive.check_binding(&previous.binding)?;
    validate_presentation(&old_archive, &previous)?;
    let candidate_snapshots = [
        owner.read(CANDIDATE_SLOTS[0])?,
        owner.read(CANDIDATE_SLOTS[1])?,
    ];
    let reused_local_key = kit.is_none();
    let (bundle, presentation) = if let Some(kit) = kit {
        validate_kit(&kit, &binding)?;
        let evidence =
            super::Remote::recovery(remote)?.ok_or(super::Failure::RecoveryUnavailable)?;
        check_remote(remote, &binding)?;
        let bundle = bootstrap::open_recovery(&evidence.ciphertext, &kit)?;
        verify_remote(remote, &binding, &bundle)?;
        let material =
            Presentation::verification_material(&binding, &kit, &evidence.ciphertext, &bundle)?;
        (
            bundle,
            Some(Presentation {
                binding: binding.clone(),
                version: evidence.version,
                status: KitStatus::VerifiedCurrent,
                material,
            }),
        )
    } else {
        let actual = super::Remote::authority(remote)?.ok_or(super::Failure::KeyConflict)?;
        check_remote(remote, &binding)?;
        let context = binding.context()?;
        let mut candidates = super::initial_candidate::review_keys(owner, &binding)?;
        if previous.binding.same_library(&binding) {
            candidates.push((
                Installed {
                    binding: previous.binding.clone(),
                    bundle: Bundle::from_material(previous.bundle.for_secure_storage())?,
                },
                old_archive
                    .presentation
                    .as_ref()
                    .map(|p| p.for_review(&binding))
                    .transpose()?
                    .flatten(),
            ));
        }
        candidates.extend(super::candidate::review_keys(owner, &binding)?);
        for entry in archive.entries.iter().rev() {
            let target = entry.installed()?;
            if target.binding.same_library(&binding) {
                let bootstrap =
                    super::Archive::from_snapshot(Some(entry.target_bootstrap.clone()))?;
                let presentation = bootstrap
                    .presentation
                    .as_ref()
                    .map(|p| p.for_review(&binding))
                    .transpose()?
                    .flatten();
                candidates.push((target, presentation));
            }
            if let Some(bytes) = &entry.source[0] {
                let source = Installed::decode(bytes)?;
                if source.binding.same_library(&binding) {
                    let bootstrap = super::Archive::from_snapshot(entry.source[1].clone())?;
                    let presentation = bootstrap
                        .presentation
                        .as_ref()
                        .map(|p| p.for_review(&binding))
                        .transpose()?
                        .flatten();
                    candidates.push((source, presentation));
                }
            }
        }
        let (installed, mut presentation) = candidates
            .into_iter()
            .find(|(key, _)| Authority::new(&key.bundle, &context).public_key() == actual)
            .ok_or(super::Failure::KeyConflict)?;
        let current = super::Remote::recovery(remote)?;
        check_remote(remote, &binding)?;
        validate_session(owner)?;
        if let Some(presentation) = &mut presentation
            && !current
                .as_ref()
                .is_some_and(|e| presentation.matches_evidence(e))
        {
            presentation.status = KitStatus::Replaced;
        }
        (installed.bundle, presentation)
    };
    validate_session(owner)?;
    if previous.binding == binding
        && previous.bundle.for_secure_storage() == bundle.for_secure_storage()
    {
        return Err(Failure::Unavailable);
    }
    let target_key = Installed {
        binding: binding.clone(),
        bundle,
    }
    .value()?
    .encode()?;
    let target_bootstrap = object([
        ("schema", Value::Int(2)),
        ("generation", Value::Int(1)),
        ("pending", Value::Null),
        (
            "presentation",
            presentation
                .as_ref()
                .map(Presentation::value)
                .transpose()?
                .unwrap_or(Value::Null),
        ),
    ])
    .encode()?;
    let checkpoint = owner
        .checkpoint_material(true)?
        .ok_or(super::Failure::InvalidState)?;
    let checkpoint_key =
        RootKey::from_bytes(&checkpoint[..32]).map_err(|_| super::Failure::InvalidState)?;
    let checkpoint_salt = checkpoint[32..]
        .try_into()
        .map_err(|_| super::Failure::InvalidState)?;
    let library = Library::prepare(owner.root().into()).map_err(super::Failure::from)?;
    let account_hash = account_hash(owner, &binding)?;
    let credentials_snapshot = owner.read(Slot::Credentials)?;
    let installed = Installed::decode(&target_key)?;
    let previous_scope = previous.binding.checkpoint_scope();
    let scope = binding.checkpoint_scope();
    let key_material_changed = previous.bundle.for_secure_storage()
        != installed.bundle.for_secure_storage()
        || previous.binding != binding
            && previous_scope == scope
            && previous.binding.epoch == binding.epoch;
    let previous = account_review::Previous {
        scope: previous_scope,
        key_epoch: previous.binding.epoch,
        key_material_changed,
    };
    let owner_cell = RefCell::new(&mut *owner);
    let guard = || {
        let mut owner = owner_cell.borrow_mut();
        validate_session(&mut owner).map_err(|_| receiver::Failure::SessionChanged)?;
        if owner
            .read(Slot::Credentials)
            .map_err(|_| receiver::Failure::SessionChanged)?
            != credentials_snapshot
        {
            return Err(receiver::Failure::SessionChanged);
        }
        if owner
            .read(Slot::CheckpointKey)
            .map_err(|_| receiver::Failure::SessionChanged)?
            .as_deref()
            != Some(&checkpoint)
            || owner
                .read(Slot::AccountReview)
                .map_err(|_| receiver::Failure::SessionChanged)?
                != archive.snapshot
        {
            return Err(receiver::Failure::SessionChanged);
        }
        for (index, (slot, _)) in SLOTS.iter().enumerate() {
            if owner
                .read(*slot)
                .map_err(|_| receiver::Failure::SessionChanged)?
                != source[index]
            {
                return Err(receiver::Failure::SessionChanged);
            }
        }
        for (slot, snapshot) in CANDIDATE_SLOTS.iter().zip(&candidate_snapshots) {
            if owner
                .read(*slot)
                .map_err(|_| receiver::Failure::SessionChanged)?
                != *snapshot
            {
                return Err(receiver::Failure::SessionChanged);
            }
        }
        Ok(())
    };
    let wire = VerifiedKey {
        binding: binding.clone(),
        bundle: installed.bundle,
    };
    let journal = wire.with_wire_key(|wire_key, wire_salt| {
        receiver::Owner {
            library: &library,
            scope: &scope,
            key_epoch: binding.epoch,
            checkpoint_key: &checkpoint_key,
            checkpoint_salt: &checkpoint_salt,
            wire_key,
            wire_salt,
            device: None,
            validate_session: &guard,
        }
        .prepare_account_review(remote, previous)
    })?;
    let entry = Entry {
        completed: false,
        cancelled: false,
        receipt: journal.receipt(),
        source,
        target_key,
        target_bootstrap,
        checkpoint,
        account_hash,
    };
    entry.validate()?;
    archive.encoded(Some(&entry))?;
    entry.check_session(&mut owner_cell.borrow_mut())?;
    entry.check_slots(&mut owner_cell.borrow_mut(), false)?;
    Ok(Review {
        entry,
        journal,
        archive_snapshot: archive.snapshot,
        credentials_snapshot,
        candidate_snapshots,
        reused_local_key,
        generation: archive
            .generation
            .checked_add(1)
            .ok_or(super::Failure::InvalidState)?,
    })
}
enum Action<'a> {
    Stage(&'a account_review::Review),
    Applied,
    Continue,
}
fn journal_action<B: Backend, R: receiver::Remote>(
    owner: &mut Locked<'_, B>,
    remote: &mut R,
    entry: &Entry,
    archive_snapshot: Option<&[u8]>,
    action: Action<'_>,
    validate_session: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<bool> {
    let installed = entry.installed()?;
    let scope = installed.binding.checkpoint_scope();
    let library = Library::prepare(owner.root().into()).map_err(super::Failure::from)?;
    let checkpoint_key =
        RootKey::from_bytes(&entry.checkpoint[..32]).map_err(|_| super::Failure::InvalidState)?;
    let checkpoint_salt = entry.checkpoint[32..]
        .try_into()
        .map_err(|_| super::Failure::InvalidState)?;
    let cell = RefCell::new(owner);
    let guard = || {
        let mut owner = cell.borrow_mut();
        validate_session(&mut owner).map_err(|_| receiver::Failure::SessionChanged)?;
        entry
            .check_session(&mut owner)
            .map_err(|_| receiver::Failure::SessionChanged)?;
        let saved = owner
            .read(Slot::AccountReview)
            .map_err(|_| receiver::Failure::SessionChanged)?;
        if saved.as_deref().map(Vec::as_slice) != archive_snapshot {
            return Err(receiver::Failure::SessionChanged);
        }
        entry
            .check_slots(&mut owner, matches!(action, Action::Applied))
            .map_err(|_| receiver::Failure::SessionChanged)?;
        Ok(())
    };
    VerifiedKey {
        binding: installed.binding.clone(),
        bundle: installed.bundle,
    }
    .with_wire_key(|wire_key, wire_salt| {
        let journal = receiver::Owner {
            library: &library,
            scope: &scope,
            key_epoch: installed.binding.epoch,
            checkpoint_key: &checkpoint_key,
            checkpoint_salt: &checkpoint_salt,
            wire_key,
            wire_salt,
            device: None,
            validate_session: &guard,
        };
        match action {
            Action::Stage(review) => journal.stage_account_review(remote, review).map(|_| false),
            Action::Applied => journal.account_review_applied(remote, &entry.receipt),
            Action::Continue => journal
                .continue_account_review(remote, &entry.receipt)
                .map(|_| true),
        }
        .map_err(Failure::from)
    })
}
pub fn commit<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    review: Review,
    permit: Permit,
    validate_session: impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Outcome> {
    store.transaction_with(|owner| {
        commit_authorized_locked(owner, remote, review, permit, &validate_session)
    })
}
pub(super) fn commit_authorized_locked<B: Backend, R: super::Remote + receiver::Remote>(
    owner: &mut Locked<'_, B>,
    remote: &mut R,
    review: Review,
    permit: Permit,
    validate_session: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Outcome> {
    let lease = permit.consume(&review.authorization_target()?)?;
    commit_locked(owner, remote, review, &|owner| {
        lease.check()?;
        validate_session(owner)
    })
}
fn commit_locked<B: Backend, R: super::Remote + receiver::Remote>(
    owner: &mut Locked<'_, B>,
    remote: &mut R,
    review: Review,
    validate_session: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Outcome> {
    validate_session(owner)?;
    let mut archive = Archive::load(owner)?;
    if archive.snapshot != review.archive_snapshot || archive.pending().is_some() {
        return Err(Failure::Changed);
    }
    if owner.read(Slot::Credentials)? != review.credentials_snapshot {
        return Err(Failure::Changed);
    }
    let validate_proposal = |owner: &mut Locked<'_, B>| -> super::Result<()> {
        validate_session(owner)?;
        if owner.read(Slot::Credentials)? != review.credentials_snapshot {
            return Err(super::Failure::ReviewRequired);
        }
        for (slot, snapshot) in CANDIDATE_SLOTS.iter().zip(&review.candidate_snapshots) {
            if owner.read(*slot)? != *snapshot {
                return Err(super::Failure::ReviewRequired);
            }
        }
        Ok(())
    };
    validate_proposal(owner)?;
    review.entry.check_session(owner)?;
    review.entry.check_slots(owner, false)?;
    verify_target(remote, &review.entry)?;
    archive.encoded(Some(&review.entry))?;
    journal_action(
        owner,
        remote,
        &review.entry,
        archive.snapshot.as_deref().map(Vec::as_slice),
        Action::Stage(&review.journal),
        &validate_proposal,
    )?;
    validate_proposal(owner)?;
    review.entry.check_session(owner)?;
    review.entry.check_slots(owner, false)?;
    archive.entries.push(review.entry);
    archive.save(owner)?;
    resume_archive(owner, remote, archive, validate_session)
}
pub fn resume<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    permit: Permit,
    validate_session: impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Outcome> {
    store.transaction_with(|owner| {
        resume_authorized_locked(owner, remote, permit, &validate_session)
    })
}
pub(super) fn resume_authorized_locked<B: Backend, R: super::Remote + receiver::Remote>(
    owner: &mut Locked<'_, B>,
    remote: &mut R,
    permit: Permit,
    validate_session: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Outcome> {
    let archive = Archive::load(owner)?;
    let entry = archive.pending().ok_or(Failure::Unavailable)?;
    let lease =
        permit.consume(&entry.authorization_target(Purpose::SwitchLibrary, archive.generation)?)?;
    resume_archive(owner, remote, archive, &|owner| {
        lease.check()?;
        validate_session(owner)
    })
}
fn resume_archive<B: Backend, R: super::Remote + receiver::Remote>(
    owner: &mut Locked<'_, B>,
    remote: &mut R,
    mut archive: Archive,
    validate_session: &impl Fn(&mut Locked<'_, B>) -> super::Result<()>,
) -> Result<Outcome> {
    validate_session(owner)?;
    let Some(entry) = archive.pending() else {
        let last = archive.entries.last().ok_or(Failure::Unavailable)?;
        if last.cancelled {
            return Err(Failure::Unavailable);
        }
        let expected = last.installed()?;
        let key = super::load_locked(owner, remote)?.ok_or(Failure::Unavailable)?;
        if key.binding != expected.binding
            || key.bundle.for_secure_storage() != expected.bundle.for_secure_storage()
        {
            return Err(Failure::Changed);
        }
        validate_session(owner)?;
        let outcome = super::initialize_locked(owner, remote)?;
        validate_session(owner)?;
        return Ok(outcome);
    };
    entry.check_session(owner)?;
    entry.check_slots(owner, true)?;
    verify_target(remote, entry)?;
    let applied = journal_action(
        owner,
        remote,
        entry,
        archive.snapshot.as_deref().map(Vec::as_slice),
        Action::Applied,
        validate_session,
    )?;
    if !applied {
        entry.check_slots(owner, false)?;
        journal_action(
            owner,
            remote,
            entry,
            archive.snapshot.as_deref().map(Vec::as_slice),
            Action::Continue,
            validate_session,
        )?;
    }
    // The exact checkpoint must be proved even after a successful local write.
    if !journal_action(
        owner,
        remote,
        entry,
        archive.snapshot.as_deref().map(Vec::as_slice),
        Action::Applied,
        validate_session,
    )? {
        return Err(Failure::Changed);
    }
    verify_target(remote, entry)?;
    for (index, (slot, _)) in SLOTS.iter().enumerate() {
        validate_session(owner)?;
        entry.check_session(owner)?;
        entry.check_slots(owner, true)?;
        let saved_archive = owner.read(Slot::AccountReview)?;
        if saved_archive != archive.snapshot {
            return Err(Failure::Changed);
        }
        let current = owner.read(*slot)?;
        if current.as_deref().map(Vec::as_slice) != entry.target(index) {
            owner.replace(
                *slot,
                current.as_deref().map(Vec::as_slice),
                entry.target(index),
            )?;
        }
    }
    validate_session(owner)?;
    entry.check_session(owner)?;
    for (index, (slot, _)) in SLOTS.iter().enumerate() {
        if owner.read(*slot)?.as_deref().map(Vec::as_slice) != entry.target(index) {
            return Err(Failure::Changed);
        }
    }
    let installed = entry.installed()?;
    super::candidate::complete_reviewed(owner, &installed)?;
    validate_session(owner)?;
    entry.check_session(owner)?;
    super::initial_candidate::complete_reviewed(owner, &installed)?;
    validate_session(owner)?;
    entry.check_session(owner)?;
    let target_bootstrap = super::Archive::from_snapshot(Some(entry.target_bootstrap.clone()))?;
    if let Some(presentation) = &target_bootstrap.presentation
        && presentation.status == KitStatus::VerifiedCurrent
    {
        super::initial_candidate::retire_promoted(owner, presentation)?;
        validate_session(owner)?;
        entry.check_session(owner)?;
    }
    archive
        .entries
        .last_mut()
        .ok_or(Failure::Unavailable)?
        .completed = true;
    archive.save(owner)?;
    validate_session(owner)?;
    let outcome = super::initialize_locked(owner, remote)?;
    validate_session(owner)?;
    Ok(outcome)
}

#[cfg(test)]
#[path = "account_handover_tests.rs"]
mod tests;
