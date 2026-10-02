//! Ordinary inline expansion from confirmed Wayland text-input observations.
//! No vault records, keystroke guesses, clipboard writes, persisted host text,
//! or retries after an uncertain replacement. Native transport owns the frame.
use crate::model::{self, Error, Library, Result, Snippet};
use sha2::{Digest, Sha256};
use std::{fs, os::unix::fs::MetadataExt};
use unicode_segmentation::UnicodeSegmentation;
use zeroize::Zeroizing;

pub const MAX_SURROUNDING_BYTES: usize = 4000;
const CHUNK_BYTES: usize = 1024;
const CHANGED: Error = Error(
    "Inline expansion stopped because its text field or saved snippet changed. Check the field before trying again.",
);
const UNSUPPORTED: Error = Error("This inline expansion exceeds the supported text limits.");

/// Connection-local field generation and the count of applied done events.
/// The native owner must reset the engine and drop deliveries on reconnect.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Context {
    pub field: u64,
    pub serial: u32,
}

/// Ephemeral, bounded host text. Deliberately has no Debug or serialization.
pub struct Frame {
    context: Context,
    active: bool,
    text: Option<Zeroizing<String>>,
    cursor: usize,
    anchor: usize,
    content_type: Option<(u32, u32)>,
    change_cause: u32,
}
impl Frame {
    pub fn from_protocol(
        context: Context,
        active: bool,
        text: Option<Zeroizing<String>>,
        selection: (u32, u32),
        content_type: Option<(u32, u32)>,
        change_cause: u32,
    ) -> Self {
        Self {
            context,
            active,
            text,
            cursor: selection.0 as usize,
            anchor: selection.1 as usize,
            content_type,
            change_cause,
        }
    }
    pub fn context(&self) -> Context {
        self.context
    }
    fn admitted_text(&self) -> Option<&str> {
        let (hint, purpose) = self.content_type?;
        let text = self.text.as_deref()?;
        if !self.active
            || hint & !0x1fff != 0
            || hint & 0x10c0 != 0 // hidden_text, sensitive_data, or preedit_shown
            || purpose > 13
            || matches!(purpose, 8 | 9) // password or PIN
            || self.change_cause > 1
            || text.len() > MAX_SURROUNDING_BYTES
            || text.contains('\0')
            || self.cursor != self.anchor
            || !text.is_char_boundary(self.cursor)
        {
            return None;
        }
        Some(text)
    }
    fn copy(&self) -> Self {
        Self {
            context: self.context,
            active: self.active,
            text: self.text.clone(),
            cursor: self.cursor,
            anchor: self.anchor,
            content_type: self.content_type,
            change_cause: self.change_cause,
        }
    }
}

fn trailing_query(text: &str) -> Option<(&str, usize)> {
    let start = text.rfind('\\')?;
    let query = &text[start + 1..];
    if query.chars().any(|c| c.is_whitespace() || c.is_control())
        || query.graphemes(true).take(121).count() > 120
    {
        return None;
    }
    Some((query, start))
}
fn trigger(text: &str) -> Option<(&str, usize)> {
    trailing_query(text).filter(|(query, _)| !query.is_empty())
}
fn clipped_context(old: &str, new: &str, before: bool) -> bool {
    if old == new {
        return true;
    }
    let (short, long) = if old.len() < new.len() {
        (old, new)
    } else {
        (new, old)
    };
    short.len() >= 256
        && if before {
            long.ends_with(short)
        } else {
            long.starts_with(short)
        }
}
fn appended(old: &Frame, old_text: &str, frame: &Frame, text: &str) -> bool {
    if frame.cursor > old.cursor
        && text.get(..old.cursor) == Some(&old_text[..old.cursor])
        && text.get(frame.cursor..) == Some(&old_text[old.cursor..])
    {
        return true;
    }
    // A client may shift its bounded surrounding window while appending. Prove
    // a literal query extension plus retained context; never search a different
    // occurrence, fold host text, or accept a truncated short context.
    let Some((old_query, old_start)) = trailing_query(&old_text[..old.cursor]) else {
        return false;
    };
    let Some((new_query, new_start)) = trigger(&text[..frame.cursor]) else {
        return false;
    };
    new_query.len() > old_query.len()
        && new_query.starts_with(old_query)
        && clipped_context(&old_text[..old_start], &text[..new_start], true)
        && clipped_context(&old_text[old.cursor..], &text[frame.cursor..], false)
}
fn matching<'a>(snippets: &'a [Snippet], query: &str) -> Option<&'a Snippet> {
    if snippets.len() > model::MAX_SNIPPETS {
        return None;
    }
    let query = model::folded(query);
    if query.is_empty() {
        return None;
    }
    let mut prefixes = snippets.iter().filter(|snippet| {
        snippet.is_enabled && model::folded(&snippet.keyword).starts_with(&query)
    });
    let candidate = prefixes.next()?;
    if prefixes.next().is_some() || model::folded(&candidate.keyword) != query {
        return None;
    }
    Some(candidate)
}

#[derive(Default)]
pub struct Engine {
    previous: Option<Frame>,
}
impl Engine {
    pub fn reset(&mut self) {
        self.previous = None;
    }
    /// First activation is only a baseline. A new confirmed append in the same
    /// field may authorize replacement; moving a caret or editing never does.
    pub fn observe(&mut self, frame: Frame, ordinary: &[Snippet]) -> Option<Plan> {
        let previous = self.previous.take();
        let text = frame.admitted_text()?;
        let result = (|| {
            let old = previous.as_ref()?;
            let old_text = old.admitted_text()?;
            if frame.context.field != old.context.field
                || frame.context.serial == old.context.serial
                || frame.change_cause != 1
                || !appended(old, old_text, &frame, text)
            {
                return None;
            }
            let (query, start) = trigger(&text[..frame.cursor])?;
            let snippet = matching(ordinary, query)?.clone();
            Some(Plan {
                frame: frame.copy(),
                snippet,
                start,
            })
        })();
        self.previous = Some(frame);
        result
    }
}

pub struct Plan {
    frame: Frame,
    snippet: Snippet,
    start: usize,
}
impl Plan {
    pub fn needs_clipboard(&self) -> bool {
        self.snippet.content.contains("{clipboard}")
    }
    pub fn prepare(self, clipboard: &str) -> Result<Delivery> {
        if clipboard.len() > model::MAX_BODY_BYTES {
            return Err(UNSUPPORTED);
        }
        let text = crate::placeholders::resolve_sensitive_at(
            &self.snippet.content,
            clipboard,
            chrono::Local::now(),
        )
        .map_err(|_| UNSUPPORTED)?;
        if text.contains('\0') {
            return Err(UNSUPPORTED);
        }
        let original = self.frame.admitted_text().ok_or(CHANGED)?;
        let before = Zeroizing::new(original[..self.start].to_owned());
        let after = Zeroizing::new(original[self.frame.cursor..].to_owned());
        let delete = (self.frame.cursor - self.start) as u32;
        Ok(Delivery {
            frame: self.frame,
            snippet: self.snippet,
            before,
            after,
            text,
            offset: 0,
            first: true,
            delete,
            source: None,
        })
    }
}

/// Each operation must check its native current frame before marshaling and
/// cancellation while flushing/waiting. Acknowledgement alone is not acceptance.
pub trait Backend {
    fn replace(
        &mut self,
        expected: &Frame,
        delete_before_bytes: u32,
        text: &str,
        check: &dyn Fn() -> Result<()>,
    ) -> Result<()>;
}

/// Move-only delivery permits another chunk only after a fresh matching echo.
/// A failed step consumes the owner; previously entered text is never retried.
pub struct Delivery {
    frame: Frame,
    snippet: Snippet,
    before: Zeroizing<String>,
    after: Zeroizing<String>,
    text: Zeroizing<String>,
    offset: usize,
    first: bool,
    delete: u32,
    source: Option<LibraryProof>,
}
pub enum Step {
    AwaitingEcho(Box<Delivery>),
    Complete { inserted_bytes: usize },
}
/// Reuse the admitted catalogue between chunks. Each chunk checks identity
/// under the process lock; final acceptance also authenticates the full bytes.
/// No host text, identifiers, filesystem paths or hashes leave this owner.
struct LibraryProof {
    identity: [u64; 7],
    hash: [u8; 32],
}
fn library_identity(library: &Library) -> Result<[u64; 7]> {
    let metadata = fs::symlink_metadata(library.path()).map_err(|_| CHANGED)?;
    if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > model::MAX_FILE_BYTES as u64
    {
        return Err(CHANGED);
    }
    Ok([
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime() as u64,
        metadata.mtime_nsec() as u64,
        metadata.ctime() as u64,
        metadata.ctime_nsec() as u64,
    ])
}
impl LibraryProof {
    fn capture(library: &Library) -> Result<(Self, Vec<Snippet>)> {
        let identity = library_identity(library)?;
        let (ordinary, bytes) = library.read_locked()?;
        let proof = Self {
            identity,
            hash: Sha256::digest(&bytes).into(),
        };
        proof.validate(library)?;
        Ok((proof, ordinary))
    }
    fn validate(&self, library: &Library) -> Result<()> {
        crate::primary::require_ready(&library.root)?;
        if library_identity(library)? != self.identity {
            return Err(CHANGED);
        }
        Ok(())
    }
    fn authenticate_current(&self, library: &Library) -> Result<()> {
        self.validate(library)?;
        let bytes = Zeroizing::new(model::read_regular(&library.path())?.ok_or(CHANGED)?);
        if Sha256::digest(&bytes).as_slice() != self.hash {
            return Err(CHANGED);
        }
        self.validate(library)
    }
}
fn echoed(observed: &str, expected: &str, before: bool) -> bool {
    observed.len() >= expected.len().min(256)
        && if before {
            expected.ends_with(observed)
        } else {
            expected.starts_with(observed)
        }
}
impl Delivery {
    /// Call once per new applied native frame. The transport supplies a bounded
    /// echo wait and drops the owner when no confirming frame arrives.
    pub fn step<B: Backend>(
        mut self,
        library: &Library,
        current: Frame,
        backend: &mut B,
        check: &dyn Fn() -> Result<()>,
    ) -> Result<Step> {
        check()?;
        let text = current.admitted_text().ok_or(CHANGED)?;
        if current.context.field != self.frame.context.field {
            return Err(CHANGED);
        }
        if self.first {
            if current.context != self.frame.context
                || current.text != self.frame.text
                || current.cursor != self.frame.cursor
                || current.content_type != self.frame.content_type
            {
                return Err(CHANGED);
            }
        } else if current.context.serial == self.frame.context.serial
            || current.change_cause != 0
            || !echoed(&text[..current.cursor], &self.before, true)
            || !echoed(&text[current.cursor..], &self.after, false)
        {
            return Err(CHANGED);
        }
        let _guard = library.try_lock()?;
        check()?;
        if self.first {
            let (source, ordinary) = LibraryProof::capture(library)?;
            let saved = ordinary.iter().find(|s| s.id == self.snippet.id);
            let (query, _) = trigger(&text[..current.cursor]).ok_or(CHANGED)?;
            if saved != Some(&self.snippet) || matching(&ordinary, query) != saved {
                return Err(CHANGED);
            }
            self.source = Some(source);
        } else {
            let source = self.source.as_ref().ok_or(CHANGED)?;
            source.validate(library)?;
            if self.offset == self.text.len() {
                source.authenticate_current(library)?;
                check()?;
                return Ok(Step::Complete {
                    inserted_bytes: self.offset,
                });
            }
        }
        let mut end = (self.offset + CHUNK_BYTES).min(self.text.len());
        while !self.text.is_char_boundary(end) {
            end -= 1;
        }
        let chunk = &self.text[self.offset..end];
        check()?;
        backend.replace(
            &current,
            if self.first { self.delete } else { 0 },
            chunk,
            check,
        )?;
        self.before.push_str(chunk);
        self.frame = current;
        self.offset = end;
        self.first = false;
        Ok(Step::AwaitingEcho(Box::new(self)))
    }
}

#[cfg(test)]
#[path = "inline_expansion_tests.rs"]
mod tests;
#[cfg(feature = "desktop")]
#[path = "inline_wayland.rs"]
mod wayland;
#[cfg(feature = "desktop")]
#[path = "inline_worker.rs"]
pub(crate) mod worker;
