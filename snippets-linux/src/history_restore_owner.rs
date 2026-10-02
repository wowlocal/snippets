//! Offline owner boundary. Protected receipts and exact full primary images
//! precede every data change. It never installs keys or returns sync authority.
use super::*;
use crate::{
    account_review,
    journal::Checkpoint,
    local_auth::{Permit, Purpose, Target},
    model::Library,
    vault::Vault,
};
use archive::{Archive, Entry, Phase};
use std::cell::RefCell;

const INPUTS: [Slot; 9] = [
    Slot::LibraryKey,
    Slot::Bootstrap,
    Slot::CheckpointKey,
    Slot::PairingRecipient,
    Slot::SpaceCreation,
    Slot::KeyMutation,
    Slot::AccountReview,
    Slot::PairingCandidate,
    Slot::BootstrapCandidate,
];

pub struct Review {
    entry: Entry,
    source: Checkpoint,
    snapshot: primary::Snapshot,
    transaction: primary::frozen::Transaction,
    archive_snapshot: Option<Zeroizing<Vec<u8>>>,
    generation: i64,
    device: String,
    source_image: Vec<u8>,
    target_image: Vec<u8>,
    external: Option<source_file::Proof>,
}
impl Review {
    pub fn saved_library(&self) -> history::SavedLibrary {
        history::SavedLibrary::new(&self.entry.saved_binding)
    }
    pub fn current_library(&self) -> history::SavedLibrary {
        history::SavedLibrary::new(&self.entry.binding)
    }
    pub fn summary(&self) -> Summary {
        self.entry.summary
    }
    pub fn authorization_target(&self) -> Result<Target> {
        self.entry
            .target(Purpose::RestoreSavedChanges, self.generation)
    }
}
fn inputs<B: Backend>(owner: &mut Locked<'_, B>) -> Result<[u8; 32]> {
    let mut hash = Sha256::new();
    hash.update(b"Snippets saved changes protected inputs v1\0");
    for (index, slot) in INPUTS.into_iter().enumerate() {
        hash.update([index as u8]);
        let bytes = owner.read(slot)?;
        hash.update([u8::from(bytes.is_some())]);
        if let Some(bytes) = bytes {
            hash.update((bytes.len() as u64).to_be_bytes());
            hash.update(bytes.as_slice());
        }
    }
    Ok(hash.finalize().into())
}
fn material<B: Backend>(owner: &mut Locked<'_, B>) -> Result<Zeroizing<Vec<u8>>> {
    let value = owner
        .read(Slot::CheckpointKey)?
        .ok_or(Failure::Unavailable)?;
    if value.len() != 64 {
        return Err(super::super::Failure::InvalidState.into());
    }
    Ok(value)
}
fn checkpoint(library: &Library, entry: &Entry, bytes: &[u8]) -> Result<Checkpoint> {
    let key = RootKey::from_bytes(&bytes[..32]).map_err(|_| super::super::Failure::InvalidState)?;
    let salt = bytes[32..]
        .try_into()
        .map_err(|_| super::super::Failure::InvalidState)?;
    let checkpoint =
        Checkpoint::load_locked(library, &key, &salt, entry.binding.checkpoint_scope())?;
    if checkpoint.journal.key_epoch != Some(entry.binding.epoch) {
        return Err(Failure::Changed);
    }
    Ok(checkpoint)
}
fn require_inputs<B: Backend>(
    owner: &mut Locked<'_, B>,
    entry: &Entry,
    archive: Option<&[u8]>,
) -> Result<()> {
    if inputs(owner)? != entry.inputs_hash
        || owner
            .read(Slot::HistoryRestore)?
            .as_deref()
            .map(Vec::as_slice)
            != archive
    {
        return Err(Failure::Changed);
    }
    Ok(())
}

pub fn prepare<B: Backend>(
    store: &mut Store<B>,
    selection: Selection,
    vault: Option<&mut Vault>,
) -> Result<Review> {
    prepare_inner(store, selection, vault, None)
}
pub fn prepare_foreign<B: Backend>(
    store: &mut Store<B>,
    selection: Selection,
    vault: &mut Vault,
    source: Source,
) -> Result<Review> {
    prepare_inner(store, selection, Some(vault), Some(source))
}
fn prepare_inner<B: Backend>(
    store: &mut Store<B>,
    selection: Selection,
    mut vault: Option<&mut Vault>,
    source_vault: Option<Source>,
) -> Result<Review> {
    if source_vault.as_ref().is_some_and(|source| {
        source.selection.history_hash != selection.history_hash
            || source.selection.transition != selection.transition
    }) {
        return Err(Failure::Changed);
    }
    let external = source_vault
        .as_ref()
        .and_then(|source| source.external.clone());
    if let Some(file) = &external {
        file.validate()?;
    }
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        archive.ensure_capacity()?;
        handover::require_idle(owner)?;
        let installed = owner.read(Slot::LibraryKey)?.ok_or(Failure::Unavailable)?;
        let installed = Installed::decode(&installed)?;
        check_admission_locked(owner, &installed.binding)?;
        if super::super::Archive::load(owner)?.pending.is_some() {
            return Err(super::super::Failure::Busy.into());
        }
        let frames = inputs(owner)?;
        let bytes = material(owner)?;
        let key =
            RootKey::from_bytes(&bytes[..32]).map_err(|_| super::super::Failure::InvalidState)?;
        let salt = bytes[32..]
            .try_into()
            .map_err(|_| super::super::Failure::InvalidState)?;
        let library = Library::prepare(owner.root().into())?;
        let (source, snapshot, plan, device, saved_binding) = {
            let _guard = library.lock()?;
            let (saved, saved_binding) = handover::saved_local_state_locked(
                owner, &library, &selection,
            )
            .map_err(|e| match e {
                handover::Failure::Key(e) => Failure::Key(e),
                handover::Failure::Journal(e) => Failure::History(e),
                _ => Failure::Changed,
            })?;
            let source = Checkpoint::load_locked(
                &library,
                &key,
                &salt,
                installed.binding.checkpoint_scope(),
            )?;
            if source.journal.key_epoch != Some(installed.binding.epoch) {
                return Err(Failure::Changed);
            }
            let wall = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| Failure::Changed)?;
            let now = u64::try_from(wall.as_millis()).map_err(|_| Failure::Changed)?;
            let first = crate::clock::stamp(owner.root(), None, now)?;
            let device = first.device().to_string();
            let snapshot = primary::snapshot_locked(&library, &source.journal, &device)?;
            account_review::require_complete_primary(&source.journal, &snapshot)?;
            let saved_knowledge = saved.projection_knowledge();
            let saved_generations = saved.restoration_generations()?;
            let current_knowledge = source.journal.projection_knowledge();
            let envelopes = saved
                .projected()
                .values()
                .chain(saved_knowledge.values())
                .chain(snapshot.records.values())
                .chain(current_knowledge.values())
                .chain(saved_generations.iter().flat_map(|g| g.targets.values()))
                .chain(
                    saved_generations
                        .iter()
                        .flat_map(|g| &g.sources)
                        .map(|(e, _)| e),
                )
                .chain(
                    saved_generations
                        .iter()
                        .flat_map(|g| &g.sources)
                        .flat_map(|(_, copies)| copies),
                )
                .collect::<Vec<_>>();
            let mut floor = None;
            for e in envelopes {
                floor = floor.max(Some(e.hlc.clone()));
                for variant in merge::secure_variants(e)? {
                    floor = floor.max(Some(variant.source_hlc));
                }
            }
            let stamp = crate::clock::stamp(owner.root(), floor.as_ref(), now)?;
            let updated_at = wall.as_secs_f64() - 978_307_200.0;
            let plan = if vault.as_deref_mut().is_some_and(Vault::is_unlocked) {
                vault
                    .as_deref_mut()
                    .expect("unlocked")
                    .with_restoration_keys_locked(&library, |keys| {
                        if let Some(foreign) = &source_vault {
                            foreign.vault.with_keys(|old| {
                                planning::prepare_foreign(
                                    &saved,
                                    &source.journal,
                                    &snapshot.records,
                                    stamp,
                                    updated_at,
                                    old,
                                    keys,
                                )
                            })?
                        } else {
                            planning::prepare_with_keys(
                                &saved,
                                &source.journal,
                                &snapshot.records,
                                stamp,
                                updated_at,
                                Some(keys),
                            )
                        }
                    })??
            } else {
                planning::prepare_with_keys(
                    &saved,
                    &source.journal,
                    &snapshot.records,
                    stamp,
                    updated_at,
                    None,
                )?
            };
            (source, snapshot, plan, device, saved_binding)
        };
        let secure = plan.outcomes.iter().any(|o| {
            o.survivor
                .iter()
                .chain(&o.conflict_copies)
                .any(|e| e.secure || merge::secure_variants(e).is_ok_and(|v| !v.is_empty()))
        }) || plan.history.iter().any(|g| {
            g.targets
                .values()
                .chain(g.sources.iter().map(|(e, _)| e))
                .chain(g.sources.iter().flat_map(|(_, copies)| copies))
                .any(|e| e.secure || merge::secure_variants(e).is_ok_and(|v| !v.is_empty()))
        });
        let prepared = if secure {
            vault
                .ok_or(primary::Failure::VaultLocked)?
                .prepare_restoration_apply(
                    &library,
                    &source.journal,
                    &device,
                    &plan.outcomes,
                    &plan.expected,
                    &plan.history,
                )?
        } else {
            primary::prepare_restoration(
                &library,
                &source.journal,
                &device,
                &plan.outcomes,
                &plan.expected,
                None,
                &plan.history,
            )?
        };
        if !prepared.matches_snapshot(&snapshot) {
            return Err(Failure::Changed);
        }
        if !prepared.incompatible_ids.is_empty() {
            return Err(primary::Failure::IncompatibleVault.into());
        }
        if !prepared.deferred_ids.is_empty() {
            return Err(primary::Failure::VaultLocked.into());
        }
        if !prepared.retry_ids.is_empty() {
            return Err(Failure::Changed);
        }
        let transaction =
            primary::frozen::Transaction::prepare(&source.journal, plan.next, &prepared)?;
        let source_image = source.encrypted_image(&key, &salt)?;
        let target_image = Checkpoint::seal_journal(&transaction.wal, &key, &salt)?;
        let entry = Entry {
            saved_binding,
            selection,
            phase: Phase::Pending,
            binding: installed.binding,
            nonce: transaction.nonce(),
            source_hash: Sha256::digest(&source_image).into(),
            target_hash: Sha256::digest(&target_image).into(),
            inputs_hash: frames,
            summary: plan.summary,
        };
        // Reserve pending and both terminal receipts before offering consent.
        archive.encoded(Some(&entry), None, 1)?;
        archive.encoded(Some(&entry), Some(Phase::Completed), 2)?;
        archive.encoded(Some(&entry), Some(Phase::Cancelled), 2)?;
        require_inputs(
            owner,
            &entry,
            archive.snapshot.as_deref().map(Vec::as_slice),
        )?;
        let _guard = library.lock()?;
        let current = checkpoint(&library, &entry, &bytes)?;
        if !source.same_snapshot(&current)
            || primary::snapshot_locked(&library, &current.journal, &device)? != snapshot
        {
            return Err(Failure::Changed);
        }
        if let Some(file) = &external {
            file.validate()?;
        }
        Ok(Review {
            entry,
            source,
            snapshot,
            transaction,
            archive_snapshot: archive.snapshot,
            generation: archive.generation + 1,
            device,
            source_image,
            target_image,
            external,
        })
    })
}

pub fn apply<B: Backend>(store: &mut Store<B>, review: Review, permit: Permit) -> Result<()> {
    apply_inner(store, review, permit, None)
}
pub(crate) fn apply_inner<B: Backend>(
    store: &mut Store<B>,
    review: Review,
    permit: Permit,
    fault: Option<u8>,
) -> Result<()> {
    store.transaction_with(|owner| {
        if let Some(file) = &review.external {
            file.validate()?;
        }
        let lease = permit.consume(&review.authorization_target()?)?;
        let archive = Archive::load(owner)?;
        if archive.snapshot != review.archive_snapshot || archive.pending().is_some() {
            return Err(Failure::Changed);
        }
        handover::require_idle(owner)?;
        let pending = archive.encoded(Some(&review.entry), None, 1)?;
        archive.encoded(Some(&review.entry), Some(Phase::Completed), 2)?;
        archive.encoded(Some(&review.entry), Some(Phase::Cancelled), 2)?;
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        require_inputs(
            owner,
            &review.entry,
            archive.snapshot.as_deref().map(Vec::as_slice),
        )?;
        let bytes = material(owner)?;
        let mut current = checkpoint(&library, &review.entry, &bytes)?;
        if !review.source.same_snapshot(&current)
            || primary::snapshot_locked(&library, &current.journal, &review.device)?
                != review.snapshot
        {
            return Err(Failure::Changed);
        }
        lease.check()?;
        account_review::retain_pair_locked(
            &library,
            &review.entry.nonce,
            &review.source_image,
            &review.target_image,
            None,
        )?;
        lease.check()?;
        require_inputs(
            owner,
            &review.entry,
            archive.snapshot.as_deref().map(Vec::as_slice),
        )?;
        if primary::snapshot_locked(&library, &current.journal, &review.device)? != review.snapshot
        {
            return Err(Failure::Changed);
        }
        if fault == Some(6) {
            return Err(primary::Failure::Storage.into());
        }
        if let Some(file) = &review.external {
            file.validate()?;
        }
        owner.replace(
            Slot::HistoryRestore,
            archive.snapshot.as_deref().map(Vec::as_slice),
            Some(&pending),
        )?;
        if fault == Some(7) {
            return Err(primary::Failure::RecoveryRequired.into());
        }
        finish(
            owner,
            &library,
            &review.entry,
            &pending,
            &review.transaction,
            &mut current,
            &bytes,
            &lease,
            fault,
        )?;
        Ok(())
    })
}

#[allow(clippy::too_many_arguments)]
fn finish<B: Backend>(
    owner: &mut Locked<'_, B>,
    library: &Library,
    entry: &Entry,
    pending: &[u8],
    transaction: &primary::frozen::Transaction,
    checkpoint: &mut Checkpoint,
    bytes: &[u8],
    lease: &crate::local_auth::AuthorizationLease,
    fault: Option<u8>,
) -> Result<()> {
    let key = RootKey::from_bytes(&bytes[..32]).map_err(|_| super::super::Failure::InvalidState)?;
    let salt = bytes[32..]
        .try_into()
        .map_err(|_| super::super::Failure::InvalidState)?;
    let completed = Archive::load(owner)?.encoded(None, Some(Phase::Completed), 1)?;
    let cell = RefCell::new(owner);
    let validate = || {
        lease
            .check()
            .map_err(|_| primary::Failure::RecoveryRequired)?;
        require_inputs(&mut cell.borrow_mut(), entry, Some(pending))
            .map_err(|_| primary::Failure::RecoveryRequired)
    };
    transaction.resume_locked(library, checkpoint, &key, &salt, &validate, fault)?;
    validate()?;
    cell.borrow_mut()
        .replace(Slot::HistoryRestore, Some(pending), Some(&completed))?;
    lease.check()?;
    require_inputs(&mut cell.borrow_mut(), entry, Some(&completed))?;
    transaction.release_locked(library, checkpoint)?;
    Ok(())
}

/// Read-only proof for a new local-purpose permit. Server/credential state is
/// not consulted; active key/capability frames must remain exactly owned.
pub fn prepare_resume_authorization<B: Backend>(
    store: &mut Store<B>,
    cancel: bool,
) -> Result<(Target, Summary)> {
    let review = prepare_resume_review(store, cancel)?;
    Ok((review.target, review.summary))
}
pub struct ResumeReview {
    pub target: Target,
    pub summary: Summary,
    pub saved: history::SavedLibrary,
    pub current: history::SavedLibrary,
}
pub fn prepare_resume_review<B: Backend>(
    store: &mut Store<B>,
    cancel: bool,
) -> Result<ResumeReview> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        let entry = actionable(&archive, owner.root(), cancel)?;
        if entry.phase == Phase::Pending {
            archive.encoded(
                None,
                Some(if cancel {
                    Phase::Cancelled
                } else {
                    Phase::Completed
                }),
                1,
            )?;
        }
        require_inputs(owner, entry, archive.snapshot.as_deref().map(Vec::as_slice))?;
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        let bytes = material(owner)?;
        let transaction = entry.retained(&library, &bytes)?;
        let current = checkpoint(&library, entry, &bytes)?;
        transaction.inspect_locked(&library, &current, cancel)?;
        Ok(ResumeReview {
            target: entry.target(
                if cancel {
                    Purpose::CancelSavedChanges
                } else {
                    Purpose::ResumeSavedChanges
                },
                archive.generation,
            )?,
            summary: entry.summary,
            saved: history::SavedLibrary::new(&entry.saved_binding),
            current: history::SavedLibrary::new(&entry.binding),
        })
    })
}
pub fn resume<B: Backend>(store: &mut Store<B>, permit: Permit) -> Result<()> {
    finish_pending(store, permit, false)
}
pub fn cancel<B: Backend>(store: &mut Store<B>, permit: Permit) -> Result<()> {
    finish_pending(store, permit, true)
}
fn finish_pending<B: Backend>(store: &mut Store<B>, permit: Permit, cancel: bool) -> Result<()> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        let entry = actionable(&archive, owner.root(), cancel)?;
        let lease = permit.consume(&entry.target(
            if cancel {
                Purpose::CancelSavedChanges
            } else {
                Purpose::ResumeSavedChanges
            },
            archive.generation,
        )?)?;
        let terminal = if entry.phase == Phase::Pending {
            Some(archive.encoded(
                None,
                Some(if cancel {
                    Phase::Cancelled
                } else {
                    Phase::Completed
                }),
                1,
            )?)
        } else {
            None
        };
        let pending = archive.snapshot.as_deref().ok_or(Failure::Unavailable)?;
        require_inputs(owner, entry, Some(pending))?;
        let library = Library::prepare(owner.root().into())?;
        let _guard = library.lock()?;
        let bytes = material(owner)?;
        let transaction = entry.retained(&library, &bytes)?;
        let mut current = checkpoint(&library, entry, &bytes)?;
        lease.check()?;
        require_inputs(owner, entry, Some(pending))?;
        if entry.phase == Phase::Completed {
            return Ok(transaction.release_locked(&library, &current)?);
        }
        if cancel {
            transaction.cancel_locked(&library, &current)?;
            lease.check()?;
            require_inputs(owner, entry, Some(pending))?;
            owner.replace(
                Slot::HistoryRestore,
                Some(pending),
                Some(terminal.as_ref().ok_or(Failure::Unavailable)?),
            )?;
            Ok(())
        } else {
            finish(
                owner,
                &library,
                entry,
                pending,
                &transaction,
                &mut current,
                &bytes,
                &lease,
                None,
            )
        }
    })
}
fn actionable<'a>(archive: &'a Archive, root: &std::path::Path, cancel: bool) -> Result<&'a Entry> {
    if let Some(entry) = archive.pending() {
        return Ok(entry);
    }
    if !cancel
        && primary::readiness(root)? == primary::Readiness::RecoveryRequired
        && let Some(entry) = archive
            .entries
            .last()
            .filter(|entry| entry.phase == Phase::Completed)
    {
        return Ok(entry);
    }
    Err(Failure::Unavailable)
}
