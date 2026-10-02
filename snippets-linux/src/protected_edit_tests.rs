use super::*;

fn selection(anchor: usize, head: usize) -> Selection {
    Selection {
        anchor,
        head,
        column: None,
    }
}
fn body(outcome: Outcome) -> Zeroizing<Vec<u8>> {
    outcome.replacement.expect("changed fictional body")
}

#[test]
fn replacement_and_deletion_use_the_same_forward_or_backward_range() {
    let text = "α public 👩🏽‍💻 τέλος";
    let start = "α ".len();
    let end = "α public 👩🏽‍💻".len();
    for selected in [selection(start, end), selection(end, start)] {
        let outcome = apply(
            text.as_bytes(),
            selected,
            Edit::Insert,
            "replacement",
            false,
        )
        .unwrap();
        assert_eq!(
            outcome.selection.range(),
            (start + "replacement".len())..(start + "replacement".len())
        );
        assert!(body(outcome).as_slice() == "α replacement τέλος".as_bytes());
        for command in [
            Edit::Delete,
            Edit::Backspace,
            Edit::WordDelete,
            Edit::WordBackspace,
        ] {
            assert!(
                body(apply(text.as_bytes(), selected, command, "", false).unwrap()).as_slice()
                    == "α  τέλος".as_bytes()
            );
        }
    }
}

#[test]
fn movement_and_removal_keep_combining_emoji_flags_and_crlf_whole() {
    let clusters = ["a\u{301}", "👩🏽‍💻", "🇧🇾", "\r\n", "Z"];
    let text = clusters.concat();
    let mut cursor = Selection::default();
    let mut expected = 0;
    for cluster in clusters {
        let outcome = apply(text.as_bytes(), cursor, Edit::Right, "", false).unwrap();
        expected += cluster.len();
        assert_eq!(outcome.selection.head(), expected);
        assert!(outcome.replacement.is_none());
        let deleted = body(apply(text.as_bytes(), cursor, Edit::Delete, "", false).unwrap());
        assert!(
            deleted.as_slice()
                == format!("{}{}", &text[..cursor.head()], &text[expected..]).as_bytes()
        );
        cursor = outcome.selection;
    }
    for cluster in clusters.into_iter().rev() {
        let deleted = body(apply(text.as_bytes(), cursor, Edit::Backspace, "", false).unwrap());
        let next = apply(text.as_bytes(), cursor, Edit::Left, "", false)
            .unwrap()
            .selection;
        expected -= cluster.len();
        assert_eq!(next.head(), expected);
        assert!(
            deleted.as_slice()
                == format!("{}{}", &text[..expected], &text[cursor.head()..]).as_bytes()
        );
        cursor = next;
    }
}

#[test]
fn shift_reverses_selection_and_plain_arrows_collapse_to_its_edge() {
    let text = "α👩🏽‍💻Z".as_bytes();
    let end = apply(text, Selection::default(), Edit::Right, "", true)
        .unwrap()
        .selection;
    assert_eq!(end.range(), 0..2);
    let all = apply(text, end, Edit::Finish, "", true).unwrap().selection;
    assert_eq!(all.range(), 0..text.len());
    assert_eq!(
        apply(text, all, Edit::Left, "", false)
            .unwrap()
            .selection
            .head(),
        0
    );
    assert_eq!(
        apply(text, all, Edit::Right, "", false)
            .unwrap()
            .selection
            .head(),
        text.len()
    );
    let zero = apply(text, end, Edit::Left, "", true).unwrap().selection;
    assert!(zero.range().is_empty());
    let backward = apply(text, Selection::caret(text.len()), Edit::Start, "", true)
        .unwrap()
        .selection;
    assert_eq!(backward.range(), 0..text.len());
    assert!(
        body(apply(text, backward, Edit::Insert, "safe", false).unwrap()).as_slice() == b"safe"
    );
}

#[test]
fn vertical_movement_keeps_the_preferred_grapheme_column_across_short_lines() {
    let text = "a\u{301}👩🏽‍💻XYZ\r\nx\nαβγδε\r";
    let original = "a\u{301}👩🏽‍💻XY".len();
    let short = apply(
        text.as_bytes(),
        Selection::caret(original),
        Edit::Down,
        "",
        false,
    )
    .unwrap()
    .selection;
    assert_eq!(short.head(), "a\u{301}👩🏽‍💻XYZ\r\nx".len());
    let lower = apply(text.as_bytes(), short, Edit::Down, "", true)
        .unwrap()
        .selection;
    assert_eq!(lower.head(), "a\u{301}👩🏽‍💻XYZ\r\nx\nαβγδ".len());
    assert_eq!(lower.range().start, short.head());
    let short = apply(text.as_bytes(), lower, Edit::Up, "", false)
        .unwrap()
        .selection;
    let upper = apply(text.as_bytes(), short, Edit::Up, "", false)
        .unwrap()
        .selection;
    assert_eq!(upper.head(), original);
}

#[test]
fn home_end_and_empty_lines_respect_crlf_and_bare_return_boundaries() {
    let text = "αβ\r\n\nγδ\rZ\n";
    for (position, start, end) in [(2, 0, 4), (6, 6, 6), (9, 7, 11), (12, 12, 13), (14, 14, 14)] {
        assert_eq!(
            apply(
                text.as_bytes(),
                Selection::caret(position),
                Edit::Home,
                "",
                false
            )
            .unwrap()
            .selection
            .head(),
            start
        );
        assert_eq!(
            apply(
                text.as_bytes(),
                Selection::caret(position),
                Edit::End,
                "",
                false
            )
            .unwrap()
            .selection
            .head(),
            end
        );
    }
}

#[test]
fn unicode_words_move_and_delete_without_splitting_surrounding_clusters() {
    let text = "αβ public-token  👩🏽‍💻 fin";
    let first = apply(
        text.as_bytes(),
        Selection::default(),
        Edit::WordRight,
        "",
        false,
    )
    .unwrap()
    .selection;
    assert_eq!(first.head(), "αβ".len());
    let next = apply(text.as_bytes(), first, Edit::WordRight, "", false)
        .unwrap()
        .selection;
    assert_eq!(next.head(), "αβ public".len());
    let previous = apply(text.as_bytes(), next, Edit::WordLeft, "", false)
        .unwrap()
        .selection;
    assert_eq!(previous.head(), "αβ ".len());
    assert!(
        body(apply(text.as_bytes(), next, Edit::WordBackspace, "", false).unwrap()).as_slice()
            == "αβ -token  👩🏽‍💻 fin".as_bytes()
    );
    assert!(
        body(apply(text.as_bytes(), first, Edit::WordDelete, "", false).unwrap()).as_slice()
            == "αβ-token  👩🏽‍💻 fin".as_bytes()
    );
}

#[test]
fn selection_replacement_accounts_for_removed_bytes_at_the_exact_body_limit() {
    let text = vec![b'x'; MAX_BODY_BYTES];
    let selected = selection(0, 4);
    let changed = body(apply(&text, selected, Edit::Insert, "🦀", false).unwrap());
    assert_eq!(changed.len(), MAX_BODY_BYTES);
    assert!(changed.starts_with("🦀".as_bytes()));
    assert!(apply(&text, selected, Edit::Insert, "🦀x", false).is_err());
    assert!(apply(&text, Selection::default(), Edit::Insert, "x", false).is_err());
    assert!(apply(&text, selected, Edit::Insert, "\0", false).is_err());
    let all = apply(&text, Selection::default(), Edit::SelectAll, "", false).unwrap();
    assert!(all.replacement.is_none());
    assert!(body(apply(&text, all.selection, Edit::Delete, "", false).unwrap()).is_empty());
}

#[test]
fn unchanged_edits_and_selection_never_request_reencryption_or_dirty_state() {
    for command in [
        Edit::Left,
        Edit::Right,
        Edit::Up,
        Edit::Down,
        Edit::Home,
        Edit::End,
        Edit::SelectAll,
        Edit::Start,
        Edit::Finish,
    ] {
        assert!(
            apply(b"public", Selection::default(), command, "", true)
                .unwrap()
                .replacement
                .is_none()
        );
    }
    assert!(
        apply(b"public", Selection::default(), Edit::Backspace, "", false)
            .unwrap()
            .replacement
            .is_none()
    );
    assert!(
        apply(b"public", Selection::caret(6), Edit::Delete, "", false)
            .unwrap()
            .replacement
            .is_none()
    );
    assert!(
        apply(b"public", selection(0, 6), Edit::Insert, "public", false)
            .unwrap()
            .replacement
            .is_none()
    );
}

#[test]
fn invalid_utf8_offsets_and_partial_grapheme_positions_refuse_the_whole_edit() {
    let text = "a\u{301}👩🏽‍💻\r\n";
    for position in [1, 2, 4, 7, text.len() - 1, text.len() + 1] {
        assert!(
            apply(
                text.as_bytes(),
                Selection::caret(position),
                Edit::Insert,
                "replacement",
                false
            )
            .is_err()
        );
    }
    assert!(apply(b"\xff", Selection::default(), Edit::Delete, "", false).is_err());
    assert!(apply(b"\0", Selection::default(), Edit::Delete, "", false).is_err());
    assert!(
        apply(
            &vec![b'x'; MAX_BODY_BYTES + 1],
            Selection::default(),
            Edit::Delete,
            "",
            false
        )
        .is_err()
    );
}

#[test]
fn pointer_trailing_counts_scalars_and_snaps_to_complete_grapheme_edges() {
    let text = "a\u{301}👩🏽‍💻Z".as_bytes();
    assert_eq!(
        Selection::default()
            .place(text, 1, 0, false)
            .unwrap()
            .head(),
        0
    );
    assert_eq!(
        Selection::default()
            .place(text, 0, 2, false)
            .unwrap()
            .head(),
        3
    );
    assert_eq!(
        Selection::default()
            .place(text, 3, 4, false)
            .unwrap()
            .head(),
        text.len() - 1
    );
    let selected = Selection::default().place(text, 3, 4, true).unwrap();
    assert_eq!(selected.range(), 0..text.len() - 1);
    assert!(Selection::default().place(text, 2, 0, false).is_err());
    assert!(Selection::default().place(text, 3, 99, false).is_err());
}

#[test]
fn editing_that_joins_adjacent_graphemes_leaves_a_valid_complete_caret() {
    let text = "\u{301}Z";
    let outcome = apply(
        text.as_bytes(),
        Selection::default(),
        Edit::Insert,
        "a",
        false,
    )
    .unwrap();
    assert_eq!(outcome.selection.head(), 3);
    let cursor = outcome.selection;
    let text = body(outcome);
    assert!(
        apply(&text, cursor, Edit::Backspace, "", false)
            .unwrap()
            .replacement
            .unwrap()
            .as_slice()
            == b"Z"
    );
    let outcome = apply(b"\rX\n", selection(1, 2), Edit::Delete, "", false).unwrap();
    assert_eq!(outcome.selection.head(), 2);
    assert!(body(outcome).as_slice() == b"\r\n");
}

fn vault_fixture() -> (
    tempfile::TempDir,
    crate::model::Library,
    crate::vault::Vault,
    crate::vault::EncryptedDraft,
) {
    use crate::{
        model::Library,
        vault::{Document, Vault},
    };
    let temp = tempfile::tempdir().unwrap();
    let library = Library::open(temp.path().into()).unwrap();
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let bytes = serde_json::to_vec(&fixture["document"]).unwrap();
    std::fs::create_dir(temp.path().join("Vault")).unwrap();
    crate::model::atomic_write(&temp.path().join("Vault/vault.json"), &bytes).unwrap();
    let document = Document::decode(&bytes).unwrap();
    let record = document.records[0].clone();
    let mut vault = Vault::open(&library).unwrap();
    let authentication = document.authenticate("Café public fixture", false).unwrap();
    vault
        .finish_authentication(authentication, vault.generation())
        .unwrap();
    let body = vault.body(record.metadata.id).unwrap();
    let draft = vault
        .protect_draft(record.metadata.clone(), &body, Some(record))
        .unwrap();
    (temp, library, vault, draft)
}

#[test]
fn production_selection_preserves_ciphertext_and_replacement_changes_only_the_encrypted_draft() {
    let (temp, library, mut vault, mut draft) = vault_fixture();
    let original = draft.clone();
    let file = std::fs::read(temp.path().join("Vault/vault.json")).unwrap();
    let all = apply_draft(
        &mut vault,
        &mut draft,
        Selection::default(),
        Edit::SelectAll,
        "",
        false,
    )
    .unwrap();
    assert!(!all.changed && draft == original);
    let unchanged = apply_draft(
        &mut vault,
        &mut draft,
        all.selection,
        Edit::Insert,
        "Fictional secret 🦀\n",
        false,
    )
    .unwrap();
    assert!(!unchanged.changed && draft == original);
    let all = apply_draft(
        &mut vault,
        &mut draft,
        unchanged.selection,
        Edit::SelectAll,
        "",
        false,
    )
    .unwrap();
    let replaced = apply_draft(
        &mut vault,
        &mut draft,
        all.selection,
        Edit::Insert,
        "New public fixture 👩🏽‍💻\r\n",
        false,
    )
    .unwrap();
    assert!(replaced.changed && draft != original);
    assert!(draft.metadata == original.metadata && draft.expected == original.expected);
    assert!(
        vault.draft_body(&draft, false).unwrap().as_slice()
            == "New public fixture 👩🏽‍💻\r\n".as_bytes()
    );
    assert_eq!(
        std::fs::read(temp.path().join("Vault/vault.json")).unwrap(),
        file
    );
    assert!(!library.path().exists());
    let body = vault.draft_body(&draft, false).unwrap();
    vault
        .save(
            &library,
            draft.metadata.clone(),
            &body,
            draft.expected.as_ref(),
        )
        .unwrap();
    assert!(
        vault.body(draft.metadata.id).unwrap().as_slice() == "New public fixture 👩🏽‍💻\r\n".as_bytes()
    );
}

#[test]
fn failed_or_locked_production_edits_keep_the_exact_encrypted_draft() {
    let (_temp, _library, mut vault, mut draft) = vault_fixture();
    let original = draft.clone();
    for (selected, edit, text) in [
        (selection(0, 1), Edit::Insert, "\0"),
        (Selection::caret(18), Edit::Backspace, ""),
        (Selection::caret(usize::MAX), Edit::SelectAll, ""),
    ] {
        assert!(apply_draft(&mut vault, &mut draft, selected, edit, text, false).is_err());
        assert!(draft == original);
    }
    vault.lock();
    for edit in [Edit::Insert, Edit::SelectAll, Edit::Left, Edit::Delete] {
        assert!(
            apply_draft(
                &mut vault,
                &mut draft,
                Selection::default(),
                edit,
                "public",
                false
            )
            .is_err()
        );
        assert!(draft == original);
    }
}
