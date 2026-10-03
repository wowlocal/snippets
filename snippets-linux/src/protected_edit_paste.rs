//! One-use encrypted-draft receipt for asynchronous clipboard input. No plaintext,
//! key, clipboard provider, serialization or body-bearing Debug implementation.
use super::{Edit, Selection, checked, history::History};
use crate::{
    desktop::SessionWitness,
    model::{Error, Result},
    secure_insertion::Authorization,
    vault::{EditBinding, EncryptedDraft, Vault},
};
use std::{
    cell::Cell,
    time::{Duration, Instant},
};

const CHANGED: Error =
    Error("Paste was cancelled because the protected editor changed. Try Paste again.");
pub(crate) struct Request {
    authorization: Authorization,
    source: EncryptedDraft,
    binding: EditBinding,
    generation: u64,
    started: Duration,
    wall: Instant,
    selection: Selection,
    used: Cell<bool>,
}
impl Request {
    pub(crate) fn new(
        vault: &mut Vault,
        draft: &EncryptedDraft,
        selection: Selection,
        witness: SessionWitness,
    ) -> Result<Self> {
        let started = crate::clock::uptime().ok_or(CHANGED)?;
        let wall = Instant::now();
        let authorization = Authorization::new(witness).map_err(|_| CHANGED)?;
        let body = vault.draft_body(draft, true)?;
        checked(&body, selection)?;
        let binding = vault.edit_binding(draft)?;
        Ok(Self {
            authorization,
            source: draft.clone(),
            binding,
            generation: vault.generation(),
            started,
            wall,
            selection,
            used: Cell::new(false),
        })
    }
    pub(crate) fn cancel(&self) {
        self.used.set(true);
        self.authorization.cancel();
    }
    fn validate_owner(
        &self,
        vault: &mut Vault,
        draft: &EncryptedDraft,
        selection: Selection,
    ) -> Result<()> {
        self.authorization.validate().map_err(|_| CHANGED)?;
        let now = crate::clock::uptime().ok_or(CHANGED)?;
        if now
            .checked_sub(self.started)
            .is_none_or(|elapsed| elapsed >= Duration::from_secs(2))
            || Instant::now()
                .checked_duration_since(self.wall)
                .is_none_or(|elapsed| elapsed >= Duration::from_secs(2))
        {
            return Err(CHANGED);
        }
        if !vault.is_unlocked()
            || vault.generation() != self.generation
            || draft != &self.source
            || selection != self.selection
            || vault.edit_binding(draft)? != self.binding
        {
            return Err(CHANGED);
        }
        Ok(())
    }
    pub(crate) fn validate(
        &self,
        vault: &mut Vault,
        draft: &EncryptedDraft,
        selection: Selection,
    ) -> Result<()> {
        if self.used.get() {
            return Err(CHANGED);
        }
        self.validate_owner(vault, draft, selection)
    }
    pub(crate) fn complete(
        &self,
        vault: &mut Vault,
        draft: &mut EncryptedDraft,
        history: &mut History,
        selection: Selection,
        text: &str,
    ) -> Result<super::DraftOutcome> {
        if self.used.replace(true) {
            return Err(CHANGED);
        }
        self.validate_owner(vault, draft, selection)?;
        // An empty clipboard must not delete a selected range.
        if text.is_empty() {
            return Ok(super::DraftOutcome {
                selection,
                changed: false,
            });
        }
        history.edit(vault, draft, selection, Edit::Insert, text, false)
    }
}

#[cfg(test)]
#[path = "protected_edit_paste_tests.rs"]
mod tests;
