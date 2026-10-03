//! Ephemeral UTF-8 editing with offset-only selection. No widget, clipboard,
//! serialization, retained plaintext or body-bearing debug interface.
use crate::model::{Error, MAX_BODY_BYTES, Result};
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroizing;
#[path = "protected_edit_history.rs"]
mod history;
#[cfg(feature = "desktop")]
pub(crate) use history::History;
#[path = "protected_edit_paste.rs"]
mod paste;
#[cfg(feature = "desktop")]
pub(crate) use paste::Request as PasteRequest;

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct Selection {
    anchor: usize,
    head: usize,
    column: Option<usize>,
}
impl Selection {
    pub(crate) fn caret(head: usize) -> Self {
        Self {
            anchor: head,
            head,
            column: None,
        }
    }
    pub(crate) fn head(self) -> usize {
        self.head
    }
    pub(crate) fn range(self) -> Range<usize> {
        self.anchor.min(self.head)..self.anchor.max(self.head)
    }
    pub(crate) fn place(
        self,
        bytes: &[u8],
        index: usize,
        trailing: usize,
        extend: bool,
    ) -> Result<Self> {
        let text = checked(bytes, self)?;
        if index > text.len()
            || !text.is_char_boundary(index)
            || trailing > text[index..].chars().count()
        {
            return Err(Error("The secure cursor is invalid."));
        }
        let end = text[index..]
            .char_indices()
            .nth(trailing)
            .map_or(text.len(), |(offset, _)| index + offset);
        let head = if trailing == 0 {
            floor(text, end)
        } else {
            ceiling(text, end)
        };
        Ok(Self {
            anchor: if extend { self.anchor } else { head },
            head,
            column: None,
        })
    }
}
#[derive(Clone, Copy)]
pub(crate) enum Edit {
    Insert,
    Backspace,
    Delete,
    Left,
    Right,
    WordLeft,
    WordRight,
    WordBackspace,
    WordDelete,
    Home,
    End,
    Start,
    Finish,
    Up,
    Down,
    SelectAll,
}
pub(crate) struct Outcome {
    pub selection: Selection,
    pub replacement: Option<Zeroizing<Vec<u8>>>,
}
pub(crate) struct DraftOutcome {
    pub selection: Selection,
    pub changed: bool,
}
/// The production editor's encryption boundary. Only ciphertext and offsets
/// survive this call; a failed edit leaves the retained draft unchanged.
pub(crate) fn apply_draft(
    vault: &mut crate::vault::Vault,
    draft: &mut crate::vault::EncryptedDraft,
    selection: Selection,
    edit: Edit,
    insertion: &str,
    extend: bool,
) -> Result<DraftOutcome> {
    let body = vault.draft_body(draft, true)?;
    let outcome = apply(&body, selection, edit, insertion, extend)?;
    let changed = outcome.replacement.is_some();
    if let Some(replacement) = outcome.replacement {
        *draft =
            vault.protect_draft(draft.metadata.clone(), &replacement, draft.expected.clone())?;
    }
    Ok(DraftOutcome {
        selection: outcome.selection,
        changed,
    })
}
fn boundary(text: &str, position: usize) -> bool {
    position == text.len()
        || text
            .grapheme_indices(true)
            .any(|(index, _)| index == position)
}
fn checked(bytes: &[u8], selection: Selection) -> Result<&str> {
    let text = std::str::from_utf8(bytes)
        .map_err(|_| Error("The secure body is not supported UTF-8 text."))?;
    if bytes.len() > MAX_BODY_BYTES
        || bytes.contains(&0)
        || !boundary(text, selection.anchor)
        || !boundary(text, selection.head)
    {
        return Err(Error("The secure cursor or body is invalid."));
    }
    Ok(text)
}
fn floor(text: &str, position: usize) -> usize {
    if position == text.len() {
        return position;
    }
    text.grapheme_indices(true)
        .take_while(|(index, _)| *index <= position)
        .last()
        .map_or(0, |(index, _)| index)
}
fn ceiling(text: &str, position: usize) -> usize {
    text.grapheme_indices(true)
        .find(|(index, _)| *index >= position)
        .map_or(text.len(), |(index, _)| index)
}
fn previous(text: &str, head: usize) -> usize {
    text.grapheme_indices(true)
        .take_while(|(index, _)| *index < head)
        .last()
        .map_or(0, |(index, _)| index)
}
fn next(text: &str, head: usize) -> usize {
    text.grapheme_indices(true)
        .find(|(index, _)| *index > head)
        .map_or(text.len(), |(index, _)| index)
}
fn word_left(text: &str, head: usize) -> usize {
    text.unicode_word_indices()
        .take_while(|(index, _)| *index < head)
        .last()
        .map_or(0, |(index, _)| floor(text, index))
}
fn word_right(text: &str, head: usize) -> usize {
    text.unicode_word_indices()
        .find(|(index, word)| index + word.len() > head)
        .map_or(text.len(), |(index, word)| {
            ceiling(text, index + word.len())
        })
}
fn lines(text: &str) -> Vec<Range<usize>> {
    let mut lines = Vec::new();
    let mut start = 0;
    for (index, grapheme) in text.grapheme_indices(true) {
        if matches!(grapheme, "\n" | "\r" | "\r\n") {
            lines.push(start..index);
            start = index + grapheme.len();
        }
    }
    lines.push(start..text.len());
    lines
}
pub(crate) fn apply(
    bytes: &[u8],
    selection: Selection,
    edit: Edit,
    insertion: &str,
    extend: bool,
) -> Result<Outcome> {
    let text = checked(bytes, selection)?;
    let range = selection.range();
    let head = selection.head;
    let changed = matches!(
        edit,
        Edit::Insert | Edit::Backspace | Edit::Delete | Edit::WordBackspace | Edit::WordDelete
    );
    if changed {
        let range = if range.is_empty() {
            match edit {
                Edit::Backspace => previous(text, head)..head,
                Edit::Delete => head..next(text, head),
                Edit::WordBackspace => word_left(text, head)..head,
                Edit::WordDelete => head..word_right(text, head),
                _ => range,
            }
        } else {
            range
        };
        let insertion = if matches!(edit, Edit::Insert) {
            insertion
        } else {
            ""
        };
        let length = bytes.len() - range.len();
        let length = length
            .checked_add(insertion.len())
            .filter(|length| *length <= MAX_BODY_BYTES)
            .ok_or(Error("Secure content exceeds the 256 KiB limit."))?;
        if insertion.contains('\0') {
            return Err(Error("Secure content contains an unsupported character."));
        }
        let mut output = Zeroizing::new(Vec::with_capacity(length));
        output.extend_from_slice(&bytes[..range.start]);
        output.extend_from_slice(insertion.as_bytes());
        output.extend_from_slice(&bytes[range.end..]);
        let text = std::str::from_utf8(&output)
            .map_err(|_| Error("The secure body is not supported UTF-8 text."))?;
        let selection = Selection::caret(ceiling(text, range.start + insertion.len()));
        return Ok(Outcome {
            selection,
            replacement: (output.as_slice() != bytes).then_some(output),
        });
    }
    if matches!(edit, Edit::SelectAll) {
        return Ok(Outcome {
            selection: Selection {
                anchor: 0,
                head: text.len(),
                column: None,
            },
            replacement: None,
        });
    }
    let mut column = None;
    let head = match edit {
        Edit::Left | Edit::WordLeft if !extend && !range.is_empty() => range.start,
        Edit::Right | Edit::WordRight if !extend && !range.is_empty() => range.end,
        Edit::Left => previous(text, head),
        Edit::Right => next(text, head),
        Edit::WordLeft => word_left(text, head),
        Edit::WordRight => word_right(text, head),
        Edit::Start => 0,
        Edit::Finish => text.len(),
        Edit::Home | Edit::End | Edit::Up | Edit::Down => {
            let lines = lines(text);
            let current = lines
                .iter()
                .position(|line| head <= line.end)
                .ok_or(Error("The secure cursor is invalid."))?;
            let line = &lines[current];
            match edit {
                Edit::Home => line.start,
                Edit::End => line.end,
                _ => {
                    let desired = selection
                        .column
                        .unwrap_or_else(|| text[line.start..head].graphemes(true).count());
                    column = Some(desired);
                    let index = if matches!(edit, Edit::Up) {
                        current.saturating_sub(1)
                    } else {
                        (current + 1).min(lines.len() - 1)
                    };
                    let line = &lines[index];
                    text[line.clone()]
                        .grapheme_indices(true)
                        .nth(desired)
                        .map_or(line.end, |(offset, _)| line.start + offset)
                }
            }
        }
        _ => unreachable!(),
    };
    Ok(Outcome {
        selection: Selection {
            anchor: if extend { selection.anchor } else { head },
            head,
            column,
        },
        replacement: None,
    })
}

#[cfg(test)]
#[path = "protected_edit_tests.rs"]
mod tests;
