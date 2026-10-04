//! Production encrypted history, public fictional vault and temporary roots only.
use super::*;
use crate::model::Library;

struct Setup {
    temp: tempfile::TempDir,
    library: Library,
    vault: Vault,
    draft: EncryptedDraft,
    history: History,
    selection: Selection,
}
fn fixture() -> Setup {
    let (temp, library, vault, draft) = crate::protected_edit::tests::vault_fixture();
    Setup {
        temp,
        library,
        vault,
        draft,
        history: History::default(),
        selection: Selection::default(),
    }
}
impl Setup {
    fn edit(&mut self, edit: Edit, insertion: &str, extend: bool) -> Result<DraftOutcome> {
        let outcome = self.history.edit(
            &mut self.vault,
            &mut self.draft,
            self.selection,
            edit,
            insertion,
            extend,
        )?;
        self.selection = outcome.selection;
        Ok(outcome)
    }
    fn replace(&mut self, text: &str) {
        self.edit(Edit::SelectAll, "", false).unwrap();
        self.edit(Edit::Insert, text, false).unwrap();
    }
    fn step(&mut self, redo: bool) -> Result<bool> {
        let selected = self
            .history
            .step(&mut self.vault, &mut self.draft, self.selection, redo)?;
        if let Some(selection) = selected {
            self.selection = selection;
        }
        Ok(selected.is_some())
    }
    fn body_is(&mut self, text: &str) {
        assert!(
            self.vault
                .draft_body(&self.draft, false)
                .unwrap()
                .as_slice()
                == text.as_bytes()
        );
    }
    fn save(&mut self) {
        let body = self.vault.draft_body(&self.draft, true).unwrap();
        self.vault
            .save(
                &self.library,
                self.draft.metadata.clone(),
                &body,
                self.draft.expected.as_ref(),
            )
            .unwrap();
        let record = self.vault.record(self.draft.metadata.id).unwrap();
        self.draft.metadata = record.metadata.clone();
        self.draft.expected = Some(record);
        self.history.mark_saved();
    }
    fn state(&self) -> (usize, usize, u64, u64, Option<u64>, Option<[u8; 32]>) {
        (
            self.history.undo.len(),
            self.history.redo.len(),
            self.history.current,
            self.history.next,
            self.history.saved,
            self.history.image,
        )
    }
}

#[test]
fn encrypted_undo_redo_restores_bodies_and_selection_without_primary_writes() {
    let mut s = fixture();
    let file = std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap();
    s.edit(Edit::Insert, "α", false).unwrap();
    s.edit(Edit::Insert, "👩🏽‍💻", false).unwrap();
    s.body_is("α👩🏽‍💻Fictional secret 🦀\n");
    assert!(s.step(false).unwrap());
    s.body_is("αFictional secret 🦀\n");
    assert_eq!(s.selection.head(), 2);
    assert!(s.history.is_dirty());
    assert!(s.step(false).unwrap());
    s.body_is("Fictional secret 🦀\n");
    assert!(!s.history.is_dirty());
    assert!(!s.step(false).unwrap());
    assert!(s.step(true).unwrap());
    assert!(s.step(true).unwrap());
    s.body_is("α👩🏽‍💻Fictional secret 🦀\n");
    assert!(s.history.is_dirty());
    assert!(!s.step(true).unwrap());
    assert_eq!(
        std::fs::read(s.temp.path().join("Vault/vault.json")).unwrap(),
        file
    );
    assert!(!s.library.path().exists());
}

#[test]
fn undo_restores_the_exact_replaced_selection_and_redo_restores_its_caret() {
    let mut s = fixture();
    s.edit(Edit::Right, "", true).unwrap();
    s.edit(Edit::Right, "", true).unwrap();
    s.edit(Edit::Right, "", true).unwrap();
    assert_eq!(s.selection.range(), 0..3);
    s.edit(Edit::Insert, "🦀", false).unwrap();
    assert_eq!(s.selection.head(), 4);
    s.step(false).unwrap();
    assert_eq!(s.selection.range(), 0..3);
    s.body_is("Fictional secret 🦀\n");
    s.step(true).unwrap();
    assert_eq!(s.selection.range(), 4..4);
    s.body_is("🦀tional secret 🦀\n");
}

#[test]
fn undo_across_save_keeps_current_metadata_and_the_latest_record_cas() {
    let mut s = fixture();
    s.replace("Saved public replacement");
    s.draft.metadata.name = "Current public metadata".into();
    s.draft.metadata.tags = vec!["current".into()];
    s.save();
    let expected = s.draft.expected.clone();
    let metadata = s.draft.metadata.clone();
    assert!(!s.history.is_dirty());
    s.step(false).unwrap();
    assert!(s.history.is_dirty() && s.draft.expected == expected && s.draft.metadata == metadata);
    s.body_is("Fictional secret 🦀\n");
    s.step(true).unwrap();
    assert!(!s.history.is_dirty() && s.draft.expected == expected && s.draft.metadata == metadata);
    s.step(false).unwrap();
    s.save();
    assert!(!s.history.is_dirty());
    assert!(
        s.vault.body(s.draft.metadata.id).unwrap().as_slice() == "Fictional secret 🦀\n".as_bytes()
    );
    s.step(true).unwrap();
    assert!(s.history.is_dirty());
}

#[test]
fn a_concurrent_saved_record_still_refuses_cas_after_undo() {
    let mut s = fixture();
    s.replace("First saved public edit");
    s.save();
    let mut other = Vault::open(&s.library).unwrap();
    let auth = other
        .document
        .as_ref()
        .unwrap()
        .authenticate("Café public fixture", false)
        .unwrap();
    other
        .finish_authentication(auth, other.generation())
        .unwrap();
    let expected = other.record(s.draft.metadata.id).unwrap();
    other
        .save(
            &s.library,
            expected.metadata.clone(),
            b"External public change",
            Some(&expected),
        )
        .unwrap();
    s.step(false).unwrap();
    let body = s.vault.draft_body(&s.draft, true).unwrap();
    assert!(
        s.vault
            .save(
                &s.library,
                s.draft.metadata.clone(),
                &body,
                s.draft.expected.as_ref()
            )
            .is_err()
    );
    assert!(other.body(s.draft.metadata.id).unwrap().as_slice() == b"External public change");
    s.body_is("Fictional secret 🦀\n");
}

#[test]
fn redo_survives_navigation_noops_and_failed_edits_but_a_changed_branch_discards_it() {
    let mut s = fixture();
    s.edit(Edit::Insert, "α", false).unwrap();
    s.step(false).unwrap();
    let state = s.state();
    s.edit(Edit::Right, "", false).unwrap();
    s.edit(Edit::Left, "", false).unwrap();
    s.edit(Edit::Insert, "", false).unwrap();
    assert!(s.state() == state && s.history.can_step(true));
    let draft = s.draft.clone();
    assert!(s.edit(Edit::Insert, "\0", false).is_err());
    assert!(s.state() == state && s.draft == draft);
    s.edit(Edit::Insert, "β", false).unwrap();
    assert!(!s.history.can_step(true));
    assert!(!s.step(true).unwrap());
    s.body_is("βFictional secret 🦀\n");
    s.step(false).unwrap();
    assert!(!s.history.is_dirty());
}

#[test]
fn locked_history_retains_its_exact_frames_until_the_same_vault_is_unlocked_again() {
    for redo in [false, true] {
        let mut s = fixture();
        s.edit(Edit::Insert, "α", false).unwrap();
        if redo {
            s.step(false).unwrap();
        }
        let state = s.state();
        let draft = s.draft.clone();
        s.vault.lock();
        assert!(s.step(redo).is_err());
        assert!(s.state() == state && s.draft == draft);
        let auth = s
            .vault
            .document
            .as_ref()
            .unwrap()
            .authenticate("Café public fixture", false)
            .unwrap();
        s.vault
            .finish_authentication(auth, s.vault.generation())
            .unwrap();
        assert!(s.step(redo).unwrap());
    }
}

#[test]
fn another_record_root_or_untracked_body_never_inherits_the_history() {
    for damage in 0..3 {
        let mut s = fixture();
        s.edit(Edit::Insert, "α", false).unwrap();
        match damage {
            0 => s.draft.metadata.id = uuid::Uuid::from_u128(999),
            1 => {
                let other = fixture();
                s.vault = other.vault;
                // Keep the other fictional root alive for this scope check.
                s.temp = other.temp;
            }
            2 => {
                apply_draft(
                    &mut s.vault,
                    &mut s.draft,
                    s.selection,
                    Edit::Insert,
                    "Untracked public change",
                    false,
                )
                .unwrap();
            }
            _ => unreachable!(),
        }
        let state = s.state();
        let draft = s.draft.clone();
        assert!(s.step(false).is_err());
        assert!(
            s.edit(Edit::Insert, "Refused public change", false)
                .is_err()
        );
        assert!(s.state() == state && s.draft == draft);
    }
}

#[test]
fn invalid_current_or_saved_selection_is_rejected_before_any_queue_or_body_change() {
    for saved in [false, true] {
        let mut s = fixture();
        s.edit(Edit::Insert, "α", false).unwrap();
        if saved {
            s.history.undo.back_mut().unwrap().selection = Selection::caret(18);
        } else {
            s.selection = Selection::caret(1);
        }
        let state = s.state();
        let draft = s.draft.clone();
        assert!(s.step(false).is_err());
        assert!(s.state() == state && s.draft == draft);
    }
}

#[test]
fn count_and_ciphertext_byte_limits_prune_only_old_steps_and_keep_current_body() {
    let mut s = fixture();
    for _ in 0..70 {
        s.edit(Edit::Insert, "x", false).unwrap();
    }
    assert_eq!(s.history.undo.len(), MAX_STEPS);
    let expected = format!("{}Fictional secret 🦀\n", "x".repeat(70));
    s.body_is(&expected);
    for _ in 0..MAX_STEPS {
        assert!(s.step(false).unwrap());
    }
    s.body_is("xxxxxxFictional secret 🦀\n");
    assert!(!s.step(false).unwrap() && s.history.is_dirty());
    for _ in 0..MAX_STEPS {
        assert!(s.step(true).unwrap());
    }
    s.body_is(&expected);
    let mut large = vec![b'x'; MAX_BODY_BYTES];
    for revision in 0..35 {
        large[0] = b'a' + revision % 26;
        s.replace(std::str::from_utf8(&large).unwrap());
        let bytes: usize = s
            .history
            .undo
            .iter()
            .chain(&s.history.redo)
            .map(|f| f.body.bytes())
            .sum();
        assert!(bytes <= MAX_BYTES && s.history.undo.len() + s.history.redo.len() <= MAX_STEPS);
    }
    assert!(s.history.undo.len() < MAX_STEPS && s.history.undo.len() > 1);
    let current = s.draft.clone();
    let steps = s.history.undo.len();
    for _ in 0..steps {
        assert!(s.step(false).unwrap());
    }
    for _ in 0..steps {
        assert!(s.step(true).unwrap());
    }
    assert!(s.draft == current);
}

#[test]
fn passphrase_change_requires_its_exact_typed_rewrap_and_preserves_body_history() {
    let mut s = fixture();
    s.replace("Saved public body after edit");
    s.save();
    let document = s.vault.document.clone().unwrap();
    let (auth, prepared) = document
        .prepare_passphrase_change(
            "Café public fixture",
            false,
            "New public history passphrase",
        )
        .unwrap();
    s.vault
        .finish_authentication(auth, s.vault.generation())
        .unwrap();
    let transition = s
        .vault
        .finish_passphrase(&s.library, prepared, s.vault.generation())
        .unwrap();
    let state = s.state();
    let draft = s.draft.clone();
    assert!(s.step(false).is_err());
    assert!(s.state() == state && s.draft == draft);
    s.history
        .rewrap(&mut s.vault, &mut s.draft, &transition)
        .unwrap();
    assert!(s.state() == state);
    s.step(false).unwrap();
    s.body_is("Fictional secret 🦀\n");
    assert!(s.history.is_dirty());
    s.step(true).unwrap();
    s.body_is("Saved public body after edit");
    assert!(!s.history.is_dirty());
    assert!(
        s.history
            .rewrap(&mut s.vault, &mut s.draft, &transition)
            .is_err()
    );
}

#[test]
fn reset_discards_old_authority_and_can_start_a_clean_or_unsaved_draft() {
    for saved in [false, true] {
        let mut s = fixture();
        s.edit(Edit::Insert, "α", false).unwrap();
        s.step(false).unwrap();
        s.draft = s
            .vault
            .protect_draft(crate::vault::Metadata::new(), b"", None)
            .unwrap();
        s.history.reset(saved);
        s.selection = Selection::default();
        assert!(!s.step(false).unwrap() && !s.step(true).unwrap());
        assert_eq!(s.history.is_dirty(), !saved);
        assert!(s.history.binding.is_none() && s.history.image.is_none());
        s.edit(Edit::Insert, "New public draft", false).unwrap();
        assert!(s.history.is_dirty());
        s.step(false).unwrap();
        s.body_is("");
        assert_eq!(s.history.is_dirty(), !saved);
    }
}

#[test]
fn rejected_size_or_revision_limits_leave_body_queues_and_saved_marker_unchanged() {
    for overflow in [false, true] {
        let mut s = fixture();
        s.edit(Edit::Insert, "α", false).unwrap();
        s.step(false).unwrap();
        if overflow {
            s.history.next = u64::MAX;
        }
        let state = s.state();
        let draft = s.draft.clone();
        let text = if overflow {
            "Refused public edit".into()
        } else {
            "x".repeat(MAX_BODY_BYTES)
        };
        assert!(s.edit(Edit::Insert, &text, false).is_err());
        assert!(s.state() == state && s.draft == draft && s.history.can_step(true));
        assert!(s.step(true).unwrap());
        s.body_is("αFictional secret 🦀\n");
    }
}

#[test]
fn externally_changed_wraps_halt_without_losing_encrypted_history_or_current_body() {
    let mut s = fixture();
    s.edit(Edit::Insert, "α", false).unwrap();
    let state = s.state();
    let draft = s.draft.clone();
    let document = s.vault.document.clone().unwrap();
    let mut changed = document.clone();
    changed.wrap_pass = changed.wrap_recovery.clone();
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &changed.encode().unwrap(),
    )
    .unwrap();
    s.vault.reload().unwrap();
    assert!(s.step(false).is_err());
    assert!(s.state() == state && s.draft == draft);
    crate::model::atomic_write(
        &s.temp.path().join("Vault/vault.json"),
        &document.encode().unwrap(),
    )
    .unwrap();
    let auth = document.authenticate("Café public fixture", false).unwrap();
    s.vault
        .finish_authentication(auth, s.vault.generation())
        .unwrap();
    assert!(s.step(false).unwrap());
    s.body_is("Fictional secret 🦀\n");
}
