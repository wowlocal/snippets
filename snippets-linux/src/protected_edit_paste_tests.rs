//! Public fictional encrypted fixture, memory providers and temporary roots only.
use super::*;
use crate::desktop::{SessionState, SessionWitness};
use crate::model::MAX_BODY_BYTES;

fn witness() -> SessionWitness {
    SessionWitness::test(SessionState::Unlocked, 1)
}
fn all(vault: &mut Vault, draft: &EncryptedDraft) -> Selection {
    Selection {
        anchor: 0,
        head: vault.draft_body(draft, false).unwrap().len(),
        column: None,
    }
}
#[test]
fn paste_is_one_encrypted_undo_step_and_never_saves_the_record() {
    let (temp, library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
    let before = draft.clone();
    let file = temp.path().join("Vault/vault.json");
    let persisted = std::fs::read(&file).unwrap();
    let mut history = History::default();
    let selection = all(&mut vault, &draft);
    let request = Request::new(&mut vault, &draft, selection, witness()).unwrap();
    let outcome = request
        .complete(
            &mut vault,
            &mut draft,
            &mut history,
            selection,
            "Public paste 👩🏽‍💻\r\n\t",
        )
        .unwrap();
    assert!(outcome.changed && history.is_dirty() && history.can_step(false));
    assert!(
        draft != before && draft.metadata == before.metadata && draft.expected == before.expected
    );
    assert!(
        vault.draft_body(&draft, false).unwrap().as_slice() == "Public paste 👩🏽‍💻\r\n\t".as_bytes()
    );
    assert!(std::fs::read(&file).unwrap() == persisted && !library.path().exists());
    let pasted = draft.clone();
    assert!(
        request
            .complete(&mut vault, &mut draft, &mut history, selection, "Replay")
            .is_err()
    );
    assert!(draft == pasted);
    let restored = history
        .step(&mut vault, &mut draft, outcome.selection, false)
        .unwrap()
        .unwrap();
    assert!(
        restored == selection && draft == before && !history.is_dirty() && !history.can_step(false)
    );
    assert!(std::fs::read(file).unwrap() == persisted);
}
#[test]
fn empty_paste_preserves_selection_ciphertext_and_clean_history() {
    let (_temp, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
    let before = draft.clone();
    let selection = all(&mut vault, &draft);
    let request = Request::new(&mut vault, &draft, selection, witness()).unwrap();
    let mut history = History::default();
    let outcome = request
        .complete(&mut vault, &mut draft, &mut history, selection, "")
        .unwrap();
    assert!(!outcome.changed && outcome.selection == selection && draft == before);
    assert!(!history.is_dirty() && !history.can_step(false) && !history.can_step(true));
    assert!(request.validate(&mut vault, &draft, selection).is_err());
}
#[test]
fn expired_queued_paste_is_refused_before_reading_or_editing() {
    let (_temp, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
    for boot in [true, false] {
        let mut request =
            Request::new(&mut vault, &draft, Selection::default(), witness()).unwrap();
        if boot {
            request.started -= Duration::from_secs(3);
        } else {
            request.wall -= Duration::from_secs(3);
        }
        assert!(
            request
                .validate(&mut vault, &draft, Selection::default())
                .is_err()
        );
        let before = draft.clone();
        let mut history = History::default();
        assert!(
            request
                .complete(
                    &mut vault,
                    &mut draft,
                    &mut history,
                    Selection::default(),
                    "Delayed"
                )
                .is_err()
        );
        assert!(draft == before && !history.can_step(false));
    }
}
#[test]
fn changed_body_metadata_or_saved_record_refuses_the_reply_without_editing() {
    for change in 0..3 {
        let (_temp, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
        let selection = Selection::default();
        let request = Request::new(&mut vault, &draft, selection, witness()).unwrap();
        match change {
            0 => {
                super::super::apply_draft(
                    &mut vault,
                    &mut draft,
                    selection,
                    Edit::Insert,
                    "Changed",
                    false,
                )
                .unwrap();
            }
            1 => draft.metadata.name = "Changed public metadata".into(),
            _ => draft.expected.as_mut().unwrap().metadata.name = "Changed public CAS".into(),
        }
        let before = draft.clone();
        let mut history = History::default();
        assert!(request.validate(&mut vault, &draft, selection).is_err());
        assert!(
            request
                .complete(&mut vault, &mut draft, &mut history, selection, "Delayed")
                .is_err()
        );
        assert!(draft == before && !history.can_step(false) && !history.is_dirty());
    }
}
#[test]
fn changed_selection_direction_or_preferred_column_refuses_the_reply() {
    let (_temp, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
    let selected = all(&mut vault, &draft);
    for selection in [
        Selection::caret(0),
        Selection {
            anchor: selected.head,
            head: selected.anchor,
            column: None,
        },
        Selection {
            column: Some(0),
            ..selected
        },
    ] {
        let request = Request::new(&mut vault, &draft, selected, witness()).unwrap();
        let before = draft.clone();
        let mut history = History::default();
        assert!(
            request
                .complete(&mut vault, &mut draft, &mut history, selection, "Delayed")
                .is_err()
        );
        assert!(draft == before && !history.can_step(false));
    }
}
#[test]
fn explicit_cancel_or_observed_desktop_lock_cannot_reattach_after_unlock() {
    let (_temp, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
    for cancel in [true, false] {
        let desktop = witness();
        let request =
            Request::new(&mut vault, &draft, Selection::default(), desktop.clone()).unwrap();
        if cancel {
            request.cancel();
        } else {
            desktop.test_observe(SessionState::Locked);
            desktop.test_observe(SessionState::Unlocked);
        }
        let before = draft.clone();
        let mut history = History::default();
        assert!(
            request
                .complete(
                    &mut vault,
                    &mut draft,
                    &mut history,
                    Selection::default(),
                    "Delayed"
                )
                .is_err()
        );
        assert!(draft == before && !history.can_step(false));
    }
}
#[test]
fn vault_lock_and_reauthentication_revoke_the_old_session_receipt() {
    let (temp, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
    let request = Request::new(&mut vault, &draft, Selection::default(), witness()).unwrap();
    vault.lock();
    let document = crate::vault::Document::decode(
        &std::fs::read(temp.path().join("Vault/vault.json")).unwrap(),
    )
    .unwrap();
    vault
        .finish_authentication(
            document.authenticate("Café public fixture", false).unwrap(),
            vault.generation(),
        )
        .unwrap();
    let before = draft.clone();
    let mut history = History::default();
    assert!(
        request
            .complete(
                &mut vault,
                &mut draft,
                &mut history,
                Selection::default(),
                "Delayed"
            )
            .is_err()
    );
    assert!(draft == before && !history.can_step(false));
}
#[test]
fn identical_vault_copied_to_another_root_cannot_admit_the_receipt() {
    let (_first, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
    let request = Request::new(&mut vault, &draft, Selection::default(), witness()).unwrap();
    let (_second, _other_library, mut other, _other_draft) =
        crate::protected_edit::tests::vault_fixture();
    let before = draft.clone();
    let mut history = History::default();
    assert!(
        request
            .complete(
                &mut other,
                &mut draft,
                &mut history,
                Selection::default(),
                "Delayed"
            )
            .is_err()
    );
    assert!(draft == before && !history.can_step(false));
}
#[test]
fn full_size_paste_uses_the_removed_selection_budget_and_is_undoable() {
    let (_temp, _library, mut vault, original) = crate::protected_edit::tests::vault_fixture();
    let mut draft = vault
        .protect_draft(
            original.metadata,
            &vec![b'A'; MAX_BODY_BYTES],
            original.expected,
        )
        .unwrap();
    let before = draft.clone();
    let selection = all(&mut vault, &draft);
    let request = Request::new(&mut vault, &draft, selection, witness()).unwrap();
    let mut history = History::default();
    let outcome = request
        .complete(
            &mut vault,
            &mut draft,
            &mut history,
            selection,
            &"B".repeat(MAX_BODY_BYTES),
        )
        .unwrap();
    assert!(outcome.changed && vault.draft_body(&draft, false).unwrap().len() == MAX_BODY_BYTES);
    assert!(
        history
            .step(&mut vault, &mut draft, outcome.selection, false)
            .unwrap()
            .is_some()
    );
    assert!(draft == before);
}
#[test]
fn nul_or_over_budget_reply_is_consumed_without_a_partial_edit() {
    for text in ["Public\0fixture".to_owned(), "A".repeat(MAX_BODY_BYTES + 1)] {
        let (_temp, _library, mut vault, mut draft) = crate::protected_edit::tests::vault_fixture();
        let before = draft.clone();
        let request = Request::new(&mut vault, &draft, Selection::default(), witness()).unwrap();
        let mut history = History::default();
        assert!(
            request
                .complete(
                    &mut vault,
                    &mut draft,
                    &mut history,
                    Selection::default(),
                    &text
                )
                .is_err()
        );
        assert!(draft == before && !history.can_step(false));
        assert!(
            request
                .validate(&mut vault, &draft, Selection::default())
                .is_err()
        );
    }
}
#[test]
fn locked_unavailable_desktop_or_invalid_cursor_cannot_mint_a_receipt() {
    let (_temp, _library, mut vault, draft) = crate::protected_edit::tests::vault_fixture();
    for state in [SessionState::Locked, SessionState::Unavailable] {
        assert!(
            Request::new(
                &mut vault,
                &draft,
                Selection::default(),
                SessionWitness::test(state, 1)
            )
            .is_err()
        );
    }
    assert!(Request::new(&mut vault, &draft, Selection::caret(usize::MAX), witness()).is_err());
    vault.lock();
    assert!(Request::new(&mut vault, &draft, Selection::default(), witness()).is_err());
}
