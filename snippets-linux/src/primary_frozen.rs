//! Exact owned redo. Only an authenticated protected receipt may retain or
//! replay these journals. Decryption alone never proves transaction ownership.
use super::*;

pub(crate) fn marker_matches(root: &Path, nonce: [u8; 16]) -> bool {
    marker(root).is_ok_and(|marker| marker == Some(nonce))
}

pub(crate) struct Transaction {
    pub source: Journal,
    pub wal: Journal,
}
impl Transaction {
    pub fn prepare(source: &Journal, next: Journal, prepared: &Prepared) -> Result<Self> {
        if source.primary_intent.is_some()
            || next.primary_intent.is_some()
            || next.scope() != source.scope()
            || next.key_epoch != source.key_epoch
            || next.primary_epoch != source.primary_epoch
            || prepared.changed_ids.is_empty()
            || !prepared.retry_ids.is_empty()
            || !prepared.deferred_ids.is_empty()
            || !prepared.incompatible_ids.is_empty()
        {
            return Err(Failure::InvalidState);
        }
        Self::from_retained(source.clone(), stage_prepared(next, prepared)?)
    }
    pub fn from_retained(source: Journal, wal: Journal) -> Result<Self> {
        let intent = wal.primary_intent.as_ref().ok_or(Failure::InvalidState)?;
        intent.validate()?;
        if source.primary_intent.is_some()
            || source.scope() != wal.scope()
            || source.key_epoch != wal.key_epoch
            || intent.nonce == [0; 16]
            || wal.primary_epoch != Some(intent.nonce)
            || source.primary_epoch == wal.primary_epoch
            || !source.preserves_transport_state(&wal)
        {
            return Err(Failure::InvalidState);
        }
        Ok(Self { source, wal })
    }
    pub fn nonce(&self) -> [u8; 16] {
        self.wal.primary_intent.as_ref().expect("validated").nonce
    }
    fn baseline(&self) -> Journal {
        let mut baseline = self.source.clone();
        baseline.primary_epoch = Some(self.nonce());
        baseline
    }
    fn completed(&self) -> Journal {
        let mut completed = self.wal.clone();
        completed.primary_intent = None;
        completed
    }
    fn before_matches(&self, library: &Library) -> Result<()> {
        let current = read_contents(&library.root)?;
        let intent = self.wal.primary_intent.as_ref().expect("validated");
        if current.plain_bytes != intent.before_plain || current.vault_bytes != intent.before_vault
        {
            return Err(Failure::StalePrimary);
        }
        Ok(())
    }
    fn after_matches(&self, library: &Library) -> Result<()> {
        let current = read_contents(&library.root)?;
        let intent = self.wal.primary_intent.as_ref().expect("validated");
        if current.plain_bytes != intent.after_plain || current.vault_bytes != intent.after_vault {
            return Err(Failure::StalePrimary);
        }
        Ok(())
    }
    /// Caller holds the common library lock and owns a fresh local lease.
    /// Each complete journal generation is compared, including offers/CAS/feed.
    /// Random re-sealing during ordinary recovery cannot erase that proof.
    pub fn resume_locked(
        &self,
        library: &Library,
        checkpoint: &mut Checkpoint,
        key: &RootKey,
        salt: &[u8; 32],
        validate: &dyn Fn() -> Result<()>,
        fault: Option<u8>,
    ) -> Result<()> {
        crate::backup::import::require_clear(&library.root)?;
        validate()?;
        if checkpoint.journal == self.completed() {
            self.after_matches(library)?;
            match marker(&library.root)? {
                None => return Ok(()),
                Some(nonce) if nonce == self.nonce() => return Ok(()),
                _ => return Err(Failure::RecoveryRequired),
            }
        }
        if checkpoint.journal == self.source || checkpoint.journal == self.baseline() {
            self.before_matches(library)?;
            let active_marker = marker(&library.root)?;
            if active_marker.is_some()
                && (active_marker != Some(self.nonce()) || checkpoint.journal != self.baseline())
            {
                return Err(Failure::RecoveryRequired);
            }
            validate()?;
            self.before_matches(library)?;
            checkpoint.journal = self.baseline();
            checkpoint.save_locked(library, key, salt)?;
            validate()?;
            write_marker(library, &self.nonce())?;
            if fault == Some(0) {
                return Err(Failure::RecoveryRequired);
            }
            validate()?;
            self.before_matches(library)?;
            checkpoint.journal = self.wal.clone();
            checkpoint.save_locked(library, key, salt)?;
            if fault == Some(1) {
                return Err(Failure::RecoveryRequired);
            }
        } else if checkpoint.journal != self.wal {
            return Err(Failure::RecoveryRequired);
        }
        finish_checked_locked(library, checkpoint, key, salt, fault, validate, false)?;
        self.after_matches(library)?;
        validate()
    }
    /// Cancellation cannot roll back a published WAL. Later local edits are
    /// allowed because a source/baseline has made no restore primary writes.
    /// Keeping the unique baseline epoch makes a lost marker-clear receipt safe.
    pub fn cancel_locked(&self, library: &Library, checkpoint: &Checkpoint) -> Result<()> {
        crate::backup::import::require_clear(&library.root)?;
        if checkpoint.journal != self.source && checkpoint.journal != self.baseline() {
            return Err(Failure::RecoveryRequired);
        }
        match marker(&library.root)? {
            None => Ok(()),
            Some(nonce) if nonce == self.nonce() && checkpoint.journal == self.baseline() => {
                remove_marker(&library.root)
            }
            _ => Err(Failure::RecoveryRequired),
        }
    }
    pub fn release_locked(&self, library: &Library, checkpoint: &Checkpoint) -> Result<()> {
        crate::backup::import::require_clear(&library.root)?;
        if checkpoint.journal != self.completed() {
            return Err(Failure::RecoveryRequired);
        }
        self.after_matches(library)?;
        match marker(&library.root)? {
            None => Ok(()),
            Some(nonce) if nonce == self.nonce() => remove_marker(&library.root),
            _ => Err(Failure::RecoveryRequired),
        }
    }
    pub fn inspect_locked(
        &self,
        library: &Library,
        checkpoint: &Checkpoint,
        cancel: bool,
    ) -> Result<()> {
        crate::backup::import::require_clear(&library.root)?;
        if cancel {
            if checkpoint.journal != self.source && checkpoint.journal != self.baseline() {
                return Err(Failure::RecoveryRequired);
            }
            return match marker(&library.root)? {
                None => Ok(()),
                Some(nonce) if nonce == self.nonce() && checkpoint.journal == self.baseline() => {
                    Ok(())
                }
                _ => Err(Failure::RecoveryRequired),
            };
        }
        if checkpoint.journal == self.completed() {
            self.after_matches(library)?;
            return match marker(&library.root)? {
                None => Ok(()),
                Some(nonce) if nonce == self.nonce() => Ok(()),
                _ => Err(Failure::RecoveryRequired),
            };
        }
        if checkpoint.journal == self.source || checkpoint.journal == self.baseline() {
            self.before_matches(library)?;
            return match marker(&library.root)? {
                None => Ok(()),
                Some(nonce) if nonce == self.nonce() && checkpoint.journal == self.baseline() => {
                    Ok(())
                }
                _ => Err(Failure::RecoveryRequired),
            };
        }
        if checkpoint.journal != self.wal || marker(&library.root)? != Some(self.nonce()) {
            return Err(Failure::RecoveryRequired);
        }
        let current = read_contents(&library.root)?;
        let intent = self.wal.primary_intent.as_ref().expect("validated");
        if current.plain_bytes != intent.before_plain && current.plain_bytes != intent.after_plain
            || current.vault_bytes != intent.before_vault
                && current.vault_bytes != intent.after_vault
        {
            return Err(Failure::StalePrimary);
        }
        Ok(())
    }
}
