//! First-key setup for an explicitly selected empty target, beside old active
//! keys. Exact key/recovery intent is durable before POST; activation is separate.
use super::*;

const MAX_ENTRIES: usize = 8;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Prepared,
    Sent,
    Ready { kit: KitStatus },
    Lost,
}
struct Entry {
    installed: Installed,
    account: Option<[u8; 32]>,
    phase: Status,
    presentation: Presentation,
}
impl Entry {
    fn validate(&self) -> Result<()> {
        self.presentation.validate()?;
        if self.presentation.binding != self.installed.binding
            || self.presentation.version != 1
            || !self.presentation.matches_bundle(&self.installed.bundle)?
        {
            return Err(Failure::InvalidState);
        }
        if !matches!(self.phase, Status::Ready { .. })
            && self.presentation.status != KitStatus::AwaitingPresentation
        {
            return Err(Failure::InvalidState);
        }
        Ok(())
    }
    fn value(&self) -> Result<Value> {
        self.validate()?;
        Ok(object([
            ("installed", self.installed.value()?),
            (
                "account",
                self.account
                    .map_or(Value::Null, |v| Value::text(STANDARD.encode(v))),
            ),
            (
                "phase",
                Value::text(match self.phase {
                    Status::Prepared => "prepared",
                    Status::Sent => "sent",
                    Status::Ready { .. } => "ready",
                    Status::Lost => "lost",
                }),
            ),
            ("presentation", self.presentation.value()?),
        ]))
    }
    fn parse(value: &Value) -> Result<Self> {
        let fields = exact(value, &["installed", "account", "phase", "presentation"])?;
        let presentation = Presentation::parse(&fields["presentation"])?;
        let phase = match fields["phase"].as_text()? {
            "prepared" => Status::Prepared,
            "sent" => Status::Sent,
            "ready" => Status::Ready {
                kit: presentation.status,
            },
            "lost" => Status::Lost,
            _ => return Err(Failure::InvalidState),
        };
        let entry = Self {
            installed: Installed::decode(&fields["installed"].encode()?)?,
            account: optional(&fields["account"], |v| {
                decode64(v.as_text()?, 32)?
                    .as_slice()
                    .try_into()
                    .map_err(|_| Failure::InvalidState)
            })?,
            phase,
            presentation,
        };
        entry.validate()?;
        Ok(entry)
    }
    fn status(&self) -> Status {
        if matches!(self.phase, Status::Ready { .. }) {
            Status::Ready {
                kit: self.presentation.status,
            }
        } else {
            self.phase
        }
    }
}
struct History {
    generation: i64,
    entries: Vec<Entry>,
    snapshot: Option<Zeroizing<Vec<u8>>>,
}
pub(super) fn history_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    active: Option<&Installed>,
) -> Result<Vec<super::history::SavedFirstKey>> {
    use super::history::{SavedFirstKey, SavedKey};
    Ok(History::load(owner)?
        .entries
        .into_iter()
        .map(|entry| SavedFirstKey {
            key: SavedKey::new(&entry.installed, entry.presentation.status, active),
            phase: entry.status(),
        })
        .collect())
}
impl History {
    fn load<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Self> {
        let snapshot = owner.read(Slot::BootstrapCandidate)?;
        let mut saved = Self {
            generation: 0,
            entries: Vec::new(),
            snapshot,
        };
        if let Some(bytes) = &saved.snapshot {
            let value = canonical::parse(bytes)?;
            let fields = exact(&value, &["schema", "generation", "entries"])?;
            saved.generation = fields["generation"].as_int()?;
            let entries = fields["entries"].as_array()?;
            if fields["schema"].as_int()? != 1
                || saved.generation < 1
                || entries.is_empty()
                || entries.len() > MAX_ENTRIES
            {
                return Err(Failure::InvalidState);
            }
            for value in entries {
                saved.entries.push(Entry::parse(value)?);
            }
        }
        Ok(saved)
    }
    fn matching(&self, binding: &KeyBinding, account: Option<[u8; 32]>) -> Option<usize> {
        self.entries
            .iter()
            .rposition(|e| e.installed.binding == *binding && e.account == account)
    }
    fn next_bytes(&self) -> Result<Zeroizing<Vec<u8>>> {
        if self.entries.is_empty() || self.entries.len() > MAX_ENTRIES {
            return Err(Failure::Busy);
        }
        let bytes = object([
            ("schema", Value::Int(1)),
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
                        .collect::<Result<_>>()?,
                ),
            ),
        ])
        .encode()?;
        if bytes.len() > secret_store::MAX_SECRET_BYTES {
            return Err(Failure::Busy);
        }
        Ok(bytes)
    }
    fn save<B: Backend>(&mut self, owner: &mut Locked<'_, B>) -> Result<()> {
        let bytes = self.next_bytes()?;
        owner.replace(
            Slot::BootstrapCandidate,
            self.snapshot.as_deref().map(Vec::as_slice),
            Some(&bytes),
        )?;
        self.snapshot = Some(bytes);
        self.generation += 1;
        Ok(())
    }
}
fn account<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<Option<[u8; 32]>> {
    handover::account_hash(owner, binding).map_err(|e| match e {
        handover::Failure::Key(e) => e,
        _ => Failure::ReviewRequired,
    })
}
pub fn inspect<B: Backend>(store: &mut Store<B>, binding: &KeyBinding) -> Result<Option<Status>> {
    store.transaction_with(|owner| {
        let saved = History::load(owner)?;
        let account = account(owner, binding)?;
        Ok(saved
            .matching(binding, account)
            .map(|index| saved.entries[index].status()))
    })
}
pub(super) fn require_pairing_idle<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<()> {
    let saved = History::load(owner)?;
    let account = account(owner, binding)?;
    if saved
        .matching(binding, account)
        .is_some_and(|i| matches!(saved.entries[i].phase, Status::Prepared | Status::Sent))
    {
        return Err(Failure::Busy);
    }
    Ok(())
}
pub(super) fn retained_target<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<Option<(Bundle, Presentation)>> {
    let saved = History::load(owner)?;
    let account = account(owner, binding)?;
    let Some(index) = saved.matching(binding, account) else {
        return Ok(None);
    };
    let entry = &saved.entries[index];
    if !matches!(entry.phase, Status::Ready { .. }) {
        return Ok(None);
    }
    Ok(Some((
        Bundle::from_material(entry.installed.bundle.for_secure_storage())?,
        Presentation::parse(&entry.presentation.value()?)?,
    )))
}
pub(super) fn retire_promoted<B: Backend>(
    owner: &mut Locked<'_, B>,
    shown: &Presentation,
) -> Result<()> {
    let mut saved = History::load(owner)?;
    let mut changed = false;
    for entry in &mut saved.entries {
        if matches!(entry.phase, Status::Ready { .. })
            && entry.presentation.retire_matching(shown)?
        {
            changed = true;
            entry.phase = Status::Ready {
                kit: entry.presentation.status,
            };
        }
    }
    if changed {
        saved.save(owner)?;
    }
    Ok(())
}
/// A separate proposal path: fresh review, server verification and local consent
/// still precede activation. Never broaden inspect/create/resume admission.
pub(super) fn review_keys<B: Backend>(
    owner: &mut Locked<'_, B>,
    binding: &KeyBinding,
) -> Result<Vec<ReviewKey>> {
    let account = account(owner, binding)?;
    let mut keys = Vec::new();
    if let Some((bundle, presentation)) = retained_target(owner, binding)? {
        keys.push((
            Installed {
                binding: binding.clone(),
                bundle,
            },
            Some(presentation),
        ));
    }
    let saved = History::load(owner)?;
    for entry in saved.entries.into_iter().rev() {
        if entry.installed.binding.same_library(binding)
            && matches!(entry.phase, Status::Sent | Status::Ready { .. })
            && !(entry.installed.binding == *binding
                && entry.account == account
                && matches!(entry.phase, Status::Ready { .. }))
        {
            let presentation = entry.presentation.for_review(binding)?;
            keys.push((entry.installed, presentation));
        }
    }
    Ok(keys)
}
/// The reviewed target was already verified against fresh immutable authority.
/// Keep its original pin/account and capabilities; clear only unfinished status.
pub(super) fn complete_reviewed<B: Backend>(
    owner: &mut Locked<'_, B>,
    target: &Installed,
) -> Result<()> {
    let mut saved = History::load(owner)?;
    let mut changed = false;
    for entry in &mut saved.entries {
        if entry.phase == Status::Sent
            && entry.installed.binding.same_library(&target.binding)
            && entry.installed.bundle.for_secure_storage() == target.bundle.for_secure_storage()
        {
            entry.phase = Status::Ready {
                kit: entry.presentation.status,
            };
            changed = true;
        }
    }
    if changed {
        saved.save(owner)?;
    }
    Ok(())
}
pub fn create_or_resume<B: Backend>(
    store: &mut Store<B>,
    remote: &mut BoundTransport,
    validate: impl Fn(&mut Locked<'_, B>) -> Result<()>,
) -> Result<Status> {
    store.transaction_with(|owner| create_locked(owner, remote, &validate))
}
pub(super) fn create_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    validate: &impl Fn(&mut Locked<'_, B>) -> Result<()>,
) -> Result<Status> {
    validate(owner)?;
    handover::require_idle(owner)?;
    remote.preflight()?;
    validate(owner)?;
    let binding = remote.binding()?;
    let source = owner
        .read(Slot::LibraryKey)?
        .ok_or(Failure::ReviewRequired)?;
    let installed = Installed::decode(&source)?;
    if installed.binding == binding {
        return Err(Failure::ReviewRequired);
    }
    let credentials = owner.read(Slot::Credentials)?;
    let account = account(owner, &binding)?;
    let guard = |owner: &mut Locked<'_, B>| -> Result<()> {
        validate(owner)?;
        if owner.read(Slot::Credentials)? != credentials
            || owner.read(Slot::LibraryKey)?.as_deref() != Some(&source)
        {
            return Err(Failure::ReviewRequired);
        }
        Ok(())
    };
    let mut saved = History::load(owner)?;
    let index = if let Some(index) = saved.matching(&binding, account) {
        index
    } else {
        if saved.entries.len() >= MAX_ENTRIES {
            return Err(Failure::Busy);
        }
        if remote.role() != Role::Owner {
            return Err(Failure::Cloud(cloud::Failure::ReadOnly));
        }
        let public = remote.authority()?;
        check_remote(remote, &binding)?;
        guard(owner)?;
        let recovery = remote.recovery()?;
        check_remote(remote, &binding)?;
        guard(owner)?;
        let records = remote.has_records()?;
        check_remote(remote, &binding)?;
        guard(owner)?;
        if public.is_some() || recovery.is_some() || records {
            return Err(Failure::KeyConflict);
        }
        saved
            .generation
            .checked_add(3)
            .ok_or(Failure::InvalidState)?;
        let bundle = Bundle::generate()?;
        let envelope = bootstrap::create_recovery(
            &bundle,
            binding.server.clone(),
            binding.space,
            binding.epoch as i64,
        )?;
        saved.entries.push(Entry {
            installed: Installed {
                binding: binding.clone(),
                bundle,
            },
            account,
            phase: Status::Prepared,
            presentation: Presentation {
                binding: binding.clone(),
                version: 1,
                status: KitStatus::AwaitingPresentation,
                material: PresentationMaterial::Retained {
                    kit: envelope.kit,
                    ciphertext: envelope.ciphertext,
                },
            },
        });
        let index = saved.entries.len() - 1;
        guard(owner)?;
        saved.save(owner)?;
        index
    };
    reconcile(owner, remote, saved, index, &guard)
}
fn reconcile<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &mut impl Remote,
    mut saved: History,
    index: usize,
    guard: &impl Fn(&mut Locked<'_, B>) -> Result<()>,
) -> Result<Status> {
    let binding = saved.entries[index].installed.binding.clone();
    check_remote(remote, &binding)?;
    guard(owner)?;
    let public =
        Authority::new(&saved.entries[index].installed.bundle, &binding.context()?).public_key();
    let mut actual = remote.authority()?;
    check_remote(remote, &binding)?;
    guard(owner)?;
    if actual.is_none() {
        if matches!(
            saved.entries[index].phase,
            Status::Ready { .. } | Status::Lost
        ) {
            return Err(Failure::KeyConflict);
        }
        if remote.role() != Role::Owner {
            return Err(Failure::Cloud(cloud::Failure::ReadOnly));
        }
        let recovery = remote.recovery()?;
        check_remote(remote, &binding)?;
        guard(owner)?;
        let records = remote.has_records()?;
        check_remote(remote, &binding)?;
        guard(owner)?;
        if recovery.is_some() || records {
            return Err(Failure::KeyConflict);
        }
        saved
            .generation
            .checked_add(2)
            .ok_or(Failure::InvalidState)?;
        if saved.entries[index].phase != Status::Sent {
            saved.entries[index].phase = Status::Sent;
            guard(owner)?;
            saved.save(owner)?;
        }
        let (_, ciphertext) = saved.entries[index].presentation.retained()?;
        guard(owner)?;
        check_remote(remote, &binding)?;
        let receipt = remote.bootstrap(&public, ciphertext)?;
        check_remote(remote, &binding)?;
        guard(owner)?;
        if receipt.version != 1 || receipt.ciphertext != ciphertext {
            return Err(Failure::InvalidState);
        }
        actual = remote.authority()?;
        check_remote(remote, &binding)?;
        guard(owner)?;
    }
    if actual != Some(public) {
        if actual.is_some()
            && !matches!(
                saved.entries[index].phase,
                Status::Ready { .. } | Status::Lost
            )
        {
            saved.entries[index].phase = Status::Lost;
            saved.save(owner)?;
        }
        return if saved.entries[index].phase == Status::Lost {
            Ok(Status::Lost)
        } else {
            Err(Failure::KeyConflict)
        };
    }
    let previous_status = saved.entries[index].status();
    let current = remote.recovery()?;
    check_remote(remote, &binding)?;
    guard(owner)?;
    if !current
        .as_ref()
        .is_some_and(|e| saved.entries[index].presentation.matches_evidence(e))
    {
        saved.entries[index].presentation.status = KitStatus::Replaced;
    }
    let status = Status::Ready {
        kit: saved.entries[index].presentation.status,
    };
    if previous_status != status {
        saved.entries[index].phase = status;
        saved.save(owner)?;
    }
    guard(owner)?;
    Ok(status)
}

#[cfg(test)]
#[path = "bootstrap_candidate_tests.rs"]
mod tests;
