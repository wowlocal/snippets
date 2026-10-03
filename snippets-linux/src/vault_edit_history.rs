//! Volatile body-only edit snapshots. No metadata, record CAS, keys, plaintext,
//! Debug or serialization is retained in a history frame.
use super::*;

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct EditBinding {
    identity: Identity,
    id: Uuid,
    root: PathBuf,
}
impl EditBinding {
    pub(crate) fn matches(&self, draft: &EncryptedDraft) -> bool {
        self.id == draft.metadata.id && self.identity == draft.identity
    }
}
pub(crate) struct EncryptedEdit {
    sealed: Sealed,
}
impl EncryptedEdit {
    pub(crate) fn bytes(&self) -> usize {
        self.sealed.text().len()
    }
}
impl EncryptedDraft {
    pub(crate) fn edit_image(&self) -> [u8; 32] {
        use sha2::{Digest, Sha256};
        Sha256::digest(self.sealed.text().as_bytes()).into()
    }
}
impl Vault {
    pub(crate) fn edit_binding(&mut self, draft: &EncryptedDraft) -> Result<EditBinding> {
        if !self.is_unlocked() || self.draft_is_foreign(draft) {
            return Err(Error(
                "Unlock this draft's current vault before using edit history.",
            ));
        }
        Ok(EditBinding {
            identity: draft.identity.clone(),
            id: draft.metadata.id,
            root: self.root.clone(),
        })
    }
    pub(crate) fn capture_edit(
        &mut self,
        draft: &EncryptedDraft,
        binding: &EditBinding,
    ) -> Result<EncryptedEdit> {
        if !self.is_unlocked()
            || !binding.matches(draft)
            || binding.root != self.root
            || self.draft_is_foreign(draft)
        {
            return Err(Error(
                "The encrypted edit history belongs to another draft or vault.",
            ));
        }
        Ok(EncryptedEdit {
            sealed: draft.sealed.clone(),
        })
    }
    pub(crate) fn restore_edit(
        &mut self,
        draft: &mut EncryptedDraft,
        binding: &EditBinding,
        snapshot: &EncryptedEdit,
        validate: impl FnOnce(&[u8], &[u8]) -> Result<()>,
    ) -> Result<()> {
        if !binding.matches(draft) || binding.root != self.root {
            return Err(Error(
                "The encrypted edit history belongs to another draft or vault.",
            ));
        }
        // Authenticate the current draft as well as the selected history image.
        // Metadata and the latest saved-record CAS remain current facts.
        let current = self.draft_body(draft, true)?;
        let document = self.document.as_ref().ok_or(UNREADABLE)?;
        let body = crypto::open_draft(
            &snapshot.sealed,
            &self.session.as_ref().ok_or(EXPIRED)?.key,
            &document.salt()?,
            &document.kid,
            draft.metadata.id,
        )?;
        if body.len() > model::MAX_BODY_BYTES
            || body.contains(&0)
            || std::str::from_utf8(&body).is_err()
        {
            return Err(UNREADABLE);
        }
        validate(&current, &body)?;
        draft.sealed = snapshot.sealed.clone();
        Ok(())
    }
    pub(crate) fn rebind_edit_binding(
        &mut self,
        binding: &mut EditBinding,
        transition: &DraftRewrap,
    ) -> Result<()> {
        self.touch()?;
        if binding.identity != transition.old
            || binding.root != self.root
            || self.document.as_ref().map(Document::identity).as_ref() != Some(&transition.new)
        {
            return Err(Error(
                "The encrypted edit history cannot follow this passphrase change.",
            ));
        }
        binding.identity = transition.new.clone();
        Ok(())
    }
}

#[cfg(test)]
#[path = "vault_edit_history_tests.rs"]
mod tests;
