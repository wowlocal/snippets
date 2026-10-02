//! Bounded encrypted body undo/redo. Each frame keeps one ciphertext and offset
//! selection; the owner's identity is retained once for the whole history.
use super::*;
use crate::vault::{DraftRewrap, EditBinding, EncryptedDraft, EncryptedEdit, Vault};
use std::collections::VecDeque;

const MAX_STEPS: usize = 64;
const MAX_BYTES: usize = 8 * 1024 * 1024;
struct Frame {
    body: EncryptedEdit,
    selection: Selection,
    revision: u64,
}
pub(crate) struct History {
    binding: Option<EditBinding>,
    image: Option<[u8; 32]>,
    undo: VecDeque<Frame>,
    redo: VecDeque<Frame>,
    current: u64,
    next: u64,
    saved: Option<u64>,
}
impl Default for History {
    fn default() -> Self {
        Self {
            binding: None,
            image: None,
            undo: VecDeque::new(),
            redo: VecDeque::new(),
            current: 0,
            next: 1,
            saved: Some(0),
        }
    }
}
impl History {
    pub(crate) fn reset(&mut self, saved: bool) {
        *self = Self {
            saved: saved.then_some(0),
            ..Self::default()
        };
    }
    pub(crate) fn is_dirty(&self) -> bool {
        self.saved != Some(self.current)
    }
    pub(crate) fn mark_saved(&mut self) {
        self.saved = Some(self.current);
    }
    pub(crate) fn can_step(&self, redo: bool) -> bool {
        !(if redo { &self.redo } else { &self.undo }).is_empty()
    }
    fn bound(&mut self) {
        while self.undo.len() + self.redo.len() > MAX_STEPS
            || self
                .undo
                .iter()
                .chain(&self.redo)
                .map(|frame| frame.body.bytes())
                .sum::<usize>()
                > MAX_BYTES
        {
            if self.undo.pop_front().is_none() {
                self.redo.pop_front();
            }
        }
    }
    pub(crate) fn edit(
        &mut self,
        vault: &mut Vault,
        draft: &mut EncryptedDraft,
        selection: Selection,
        edit: Edit,
        insertion: &str,
        extend: bool,
    ) -> Result<DraftOutcome> {
        self.require_image(draft)?;
        let new_binding = if self.binding.is_none() {
            Some(vault.edit_binding(draft)?)
        } else {
            None
        };
        let binding = self
            .binding
            .as_ref()
            .or(new_binding.as_ref())
            .ok_or(Error("The encrypted edit history is unavailable."))?;
        let before = vault.capture_edit(draft, binding)?;
        let next = self
            .next
            .checked_add(1)
            .ok_or(Error("Reload this draft before continuing to edit."))?;
        let outcome = apply_draft(vault, draft, selection, edit, insertion, extend)?;
        if outcome.changed {
            if let Some(binding) = new_binding {
                self.binding = Some(binding);
            }
            self.redo.clear();
            self.undo.push_back(Frame {
                body: before,
                selection,
                revision: self.current,
            });
            self.current = self.next;
            self.image = Some(draft.edit_image());
            self.next = next;
            self.bound();
        }
        Ok(outcome)
    }
    pub(crate) fn step(
        &mut self,
        vault: &mut Vault,
        draft: &mut EncryptedDraft,
        selection: Selection,
        redo: bool,
    ) -> Result<Option<Selection>> {
        let source = if redo { &self.redo } else { &self.undo };
        let Some(target) = source.back() else {
            return Ok(None);
        };
        self.require_image(draft)?;
        let binding = self
            .binding
            .as_ref()
            .ok_or(Error("The encrypted edit history is unavailable."))?;
        let before = vault.capture_edit(draft, binding)?;
        vault.restore_edit(draft, binding, &target.body, |current, body| {
            checked(current, selection)?;
            checked(body, target.selection).map(|_| ())
        })?;
        let selected = target.selection;
        let revision = target.revision;
        let current = Frame {
            body: before,
            selection,
            revision: self.current,
        };
        if redo {
            self.redo.pop_back();
            self.undo.push_back(current);
        } else {
            self.undo.pop_back();
            self.redo.push_back(current);
        }
        self.current = revision;
        self.image = Some(draft.edit_image());
        self.bound();
        Ok(Some(selected))
    }
    fn require_image(&self, draft: &EncryptedDraft) -> Result<()> {
        if self.image.is_some_and(|image| image != draft.edit_image()) {
            return Err(Error(
                "The encrypted draft changed outside its edit history. Reload it before continuing.",
            ));
        }
        Ok(())
    }
    pub(crate) fn rewrap(
        &mut self,
        vault: &mut Vault,
        draft: &mut EncryptedDraft,
        transition: &DraftRewrap,
    ) -> Result<()> {
        self.require_image(draft)?;
        let mut binding = self.binding.clone();
        if let Some(binding) = binding.as_mut() {
            if !binding.matches(draft) {
                return Err(Error(
                    "The encrypted edit history belongs to another draft.",
                ));
            }
            vault.rebind_edit_binding(binding, transition)?;
        }
        vault.rebind_draft(draft, transition)?;
        self.binding = binding;
        Ok(())
    }
}

#[cfg(test)]
#[path = "protected_edit_history_tests.rs"]
mod tests;
