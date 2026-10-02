//! Explicit restoration of archived local intent. Old cloud cursors, offers,
//! versions, permissions and acknowledgements never become current facts.
use super::*;
use crate::{journal, merge, primary};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Key(super::Failure),
    Journal(journal::Failure),
    Primary(primary::Failure),
    History(crate::account_review::Failure),
    Changed,
    Unavailable,
    PreservationRequired,
    RetentionFull,
    SourceFile,
    BackupAuthentication,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<super::Failure> for Failure {
    fn from(value: super::Failure) -> Self {
        Self::Key(value)
    }
}
impl From<journal::Failure> for Failure {
    fn from(value: journal::Failure) -> Self {
        Self::Journal(value)
    }
}
impl From<primary::Failure> for Failure {
    fn from(value: primary::Failure) -> Self {
        Self::Primary(value)
    }
}
impl From<crate::merge::Failure> for Failure {
    fn from(_: crate::merge::Failure) -> Self {
        Self::PreservationRequired
    }
}
impl From<crate::secret_store::Failure> for Failure {
    fn from(value: crate::secret_store::Failure) -> Self {
        Self::Key(value.into())
    }
}
impl From<crate::local_auth::Failure> for Failure {
    fn from(value: crate::local_auth::Failure) -> Self {
        Self::Key(value.into())
    }
}
impl From<crate::model::Error> for Failure {
    fn from(value: crate::model::Error) -> Self {
        Self::Key(value.into())
    }
}
impl From<crate::account_review::Failure> for Failure {
    fn from(value: crate::account_review::Failure) -> Self {
        Self::History(value)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Summary {
    pub restored_records: usize,
    pub preserved_versions: usize,
    pub added_records: usize,
    pub secure_records: usize,
}

#[path = "history_restore_plan.rs"]
mod planning;

#[derive(Clone)]
pub struct Selection {
    pub(super) history_hash: [u8; 32],
    pub(super) transition: [u8; 16],
}
impl Selection {
    pub(super) fn new(history: &[u8], transition: [u8; 16]) -> Self {
        Self {
            history_hash: Sha256::digest(history).into(),
            transition,
        }
    }
}

/// One-use source vault authority bound to the exact selected protected history.
/// Only ciphertext plans leave preparation; keys never enter the review or WAL.
pub struct Source {
    selection: Selection,
    vault: crate::vault::RecoveryOwner,
    external: Option<source_file::Proof>,
}
pub fn authenticate_source<B: Backend>(
    store: &mut Store<B>,
    selection: &Selection,
    credential: &str,
    recovery: bool,
) -> Result<Source> {
    let header = saved_vault_header(store, selection)?.ok_or(Failure::Unavailable)?;
    let vault = header.authenticate_for_restoration(credential, recovery)?;
    // A KDF can outlive a history change. Revalidate its complete selection.
    if saved_vault_header(store, selection)?.as_ref() != Some(&header) {
        return Err(Failure::Changed);
    }
    Ok(Source {
        selection: selection.clone(),
        vault,
        external: None,
    })
}

#[path = "history_restore_source_file.rs"]
mod source_file;
pub use source_file::{SourceFile, inspect_additional_source_file, inspect_source_file};

/// Retained wraps from the exact reviewed primary snapshot. Legacy history
/// returns None; the current vault must never stand in for a missing old header.
pub fn saved_vault_header<B: Backend>(
    store: &mut Store<B>,
    selection: &Selection,
) -> Result<Option<crate::vault::RecoveryHeader>> {
    store.transaction_with(|owner| {
        handover::require_idle(owner)?;
        handover::saved_vault_header_locked(owner, selection).map_err(|error| match error {
            handover::Failure::Key(error) => Failure::Key(error),
            handover::Failure::Journal(error) => Failure::History(error),
            handover::Failure::Unavailable => Failure::Unavailable,
            _ => Failure::Changed,
        })
    })
}

#[path = "history_restore_archive.rs"]
mod archive;
#[path = "history_restore_owner.rs"]
mod owner;
#[cfg(test)]
pub(crate) use owner::apply_inner as apply_with_fault;
pub use owner::{
    ResumeReview, Review, apply, cancel, prepare, prepare_foreign, prepare_multiple,
    prepare_resume_authorization, prepare_resume_review, resume,
};

pub(super) fn history_locked<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> Result<Vec<history::SavedRestoration>> {
    let archive = archive::Archive::load(owner)?;
    let mut rows = Vec::new();
    for entry in &archive.entries {
        rows.push(history::SavedRestoration {
            library: history::SavedLibrary::new(&entry.binding),
            phase: match entry.phase {
                archive::Phase::Pending => history::SwitchPhase::Pending,
                archive::Phase::Completed => history::SwitchPhase::Completed,
                archive::Phase::Cancelled => history::SwitchPhase::Cancelled,
            },
            summary: entry.summary,
            needs_completion: entry.phase == archive::Phase::Pending
                || entry.phase == archive::Phase::Completed
                    && primary::frozen::marker_matches(owner.root(), entry.nonce),
        });
    }
    Ok(rows)
}
pub(crate) fn require_idle<B: Backend>(owner: &mut Locked<'_, B>) -> super::Result<()> {
    match archive::Archive::load(owner) {
        Ok(archive) if archive.pending().is_none() => Ok(()),
        Ok(_) => Err(super::Failure::Busy),
        Err(Failure::Key(error)) => Err(error),
        Err(_) => Err(super::Failure::InvalidState),
    }
}
