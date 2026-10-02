//! Offline completion of an exact, already-published library switch. This never
//! contacts a server, resets a journal or returns a verified data-plane key.
use super::*;

pub fn prepare_local_authorization<B: Backend>(
    store: &mut Store<B>,
) -> Result<(Target, account_review::Summary)> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        let entry = archive.pending().ok_or(Failure::Unavailable)?;
        archive.completed_bytes()?;
        let library = Library::prepare(owner.root().into()).map_err(super::super::Failure::from)?;
        let _guard = library.lock().map_err(super::super::Failure::from)?;
        prove_locked(
            owner,
            &library,
            entry,
            archive.snapshot.as_deref().map(Vec::as_slice),
            &|| Ok(()),
        )?;
        Ok((
            entry.authorization_target(Purpose::FinishLocalLibrarySwitch, archive.generation)?,
            entry.receipt.summary(),
        ))
    })
}

pub fn finish_local<B: Backend>(store: &mut Store<B>, permit: Permit) -> Result<()> {
    store.transaction_with(|owner| {
        let archive = Archive::load(owner)?;
        let entry = archive.pending().ok_or(Failure::Unavailable)?;
        let target =
            entry.authorization_target(Purpose::FinishLocalLibrarySwitch, archive.generation)?;
        let lease = permit.consume(&target)?;
        let validate = || Ok(lease.check()?);
        // Reserve the exact completed document before any slot changes. Its
        // longer phase name must fit even at the generation/size limits.
        let completed = archive.completed_bytes()?;
        let library = Library::prepare(owner.root().into()).map_err(super::super::Failure::from)?;
        let _guard = library.lock().map_err(super::super::Failure::from)?;
        let previous = archive.snapshot.as_deref().map(Vec::as_slice);
        prove_locked(owner, &library, entry, previous, &validate)?;
        for (index, (slot, _)) in SLOTS.iter().enumerate() {
            require_inputs(owner, entry, previous, &validate)?;
            let current = owner.read(*slot)?;
            if current.as_deref().map(Vec::as_slice) != entry.target(index) {
                owner.replace(
                    *slot,
                    current.as_deref().map(Vec::as_slice),
                    entry.target(index),
                )?;
            }
        }
        require_inputs(owner, entry, previous, &validate)?;
        require_target(owner, entry)?;
        let installed = entry.installed()?;
        super::super::candidate::complete_reviewed(owner, &installed)?;
        require_inputs(owner, entry, previous, &validate)?;
        super::super::initial_candidate::complete_reviewed(owner, &installed)?;
        require_inputs(owner, entry, previous, &validate)?;
        let bootstrap = super::super::Archive::from_snapshot(Some(entry.target_bootstrap.clone()))?;
        if let Some(presentation) = &bootstrap.presentation
            && presentation.status == KitStatus::VerifiedCurrent
        {
            super::super::initial_candidate::retire_promoted(owner, presentation)?;
            require_inputs(owner, entry, previous, &validate)?;
        }
        prove_locked(owner, &library, entry, previous, &validate)?;
        require_target(owner, entry)?;
        validate()?;
        owner.replace(Slot::AccountReview, previous, Some(&completed))?;
        prove_locked(owner, &library, entry, Some(&completed), &validate)?;
        require_target(owner, entry)?;
        Ok(())
    })
}

fn require_target<B: Backend>(owner: &mut Locked<'_, B>, entry: &Entry) -> Result<()> {
    for (index, (slot, _)) in SLOTS.iter().enumerate() {
        if owner.read(*slot)?.as_deref().map(Vec::as_slice) != entry.target(index) {
            return Err(Failure::Changed);
        }
    }
    Ok(())
}

fn require_inputs<B: Backend>(
    owner: &mut Locked<'_, B>,
    entry: &Entry,
    archive: Option<&[u8]>,
    validate: &impl Fn() -> Result<()>,
) -> Result<()> {
    validate()?;
    if owner.read(Slot::CheckpointKey)?.as_deref() != Some(&entry.checkpoint)
        || owner
            .read(Slot::AccountReview)?
            .as_deref()
            .map(Vec::as_slice)
            != archive
    {
        return Err(Failure::Changed);
    }
    entry.check_slots(owner, true)
}

fn prove_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
    library: &Library,
    entry: &Entry,
    archive: Option<&[u8]>,
    validate: &impl Fn() -> Result<()>,
) -> Result<()> {
    let installed = entry.installed()?;
    let scope = installed.binding.checkpoint_scope();
    let key = RootKey::from_bytes(&entry.checkpoint[..32])
        .map_err(|_| super::super::Failure::InvalidState)?;
    let salt = entry.checkpoint[32..]
        .try_into()
        .map_err(|_| super::super::Failure::InvalidState)?;
    let cell = RefCell::new(owner);
    let guard = || {
        require_inputs(&mut cell.borrow_mut(), entry, archive, validate)
            .map_err(|_| receiver::Failure::SessionChanged)
    };
    let journal = receiver::Owner {
        library,
        scope: &scope,
        key_epoch: installed.binding.epoch,
        checkpoint_key: &key,
        checkpoint_salt: &salt,
        wire_key: &key,
        wire_salt: &salt,
        device: None,
        validate_session: &guard,
    };
    if !journal.account_review_published_local_locked(&entry.receipt)? {
        return Err(Failure::Unpublished);
    }
    validate()?;
    Ok(())
}
