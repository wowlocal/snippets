//! Ordinary metadata suggestions bound to a confirmed public text-input frame.
//! No host text or snippet body leaves this move-only owner for presentation.
use super::*;
use crate::usage::Snapshot;

pub const MAX_CHOICES: usize = 8;
pub struct Row {
    pub name: String,
    pub keyword: String,
    pub pinned: bool,
    pub name_matches: Vec<(u32, u32)>,
    pub keyword_matches: Vec<(u32, u32)>,
}
pub enum Observation {
    Hidden,
    Automatic(Plan),
    Choices(Choice),
}
#[derive(Default)]
pub struct Suggestions {
    previous: Option<Frame>,
    ranking: Option<Snapshot>,
    dismissed: Option<(u64, Zeroizing<String>, Zeroizing<String>)>,
}
pub struct Choice {
    frame: Frame,
    start: usize,
    query: Zeroizing<String>,
    entries: Vec<Snippet>,
    selected: usize,
}
pub(super) fn matches(snippet: &Snippet, query: &str) -> bool {
    if !snippet.is_enabled || snippet.keyword.is_empty() {
        return false;
    }
    let query = model::folded(query);
    [&snippet.keyword, &snippet.name].into_iter().any(|target| {
        let target = model::folded(target);
        let mut letters = target.chars();
        query.chars().all(|q| letters.by_ref().any(|c| c == q))
    })
}
fn edited(old: &Frame, old_text: &str, new: &Frame, text: &str) -> bool {
    let Some((old_query, old_start)) = trailing_query(&old_text[..old.cursor]) else {
        return false;
    };
    let Some((query, start)) = trailing_query(&text[..new.cursor]) else {
        return false;
    };
    old_query != query
        && clipped_context(&old_text[..old_start], &text[..start], true)
        && clipped_context(&old_text[old.cursor..], &text[new.cursor..], false)
}
impl Suggestions {
    pub fn reset(&mut self) {
        self.previous = None;
        self.ranking = None;
        self.dismissed = None;
    }
    pub fn dismiss(&mut self) {
        self.ranking = None;
        self.dismissed = self.previous.as_ref().and_then(|frame| {
            let text = frame.admitted_text()?;
            let (_, start) = trailing_query(&text[..frame.cursor])?;
            Some((
                frame.context.field,
                Zeroizing::new(text[..start].into()),
                Zeroizing::new(text[frame.cursor..].into()),
            ))
        });
    }
    pub fn observe(
        &mut self,
        frame: Frame,
        ordinary: &[Snippet],
        ranking: &Snapshot,
    ) -> Observation {
        let previous = self.previous.take();
        let result = (|| {
            let text = frame.admitted_text()?;
            let old = previous.as_ref()?;
            let old_text = old.admitted_text()?;
            if frame.context.field != old.context.field
                || frame.context.serial == old.context.serial
                || frame.content_type != old.content_type
                || ordinary.len() > model::MAX_SNIPPETS
            {
                return None;
            }
            let append = appended(old, old_text, &frame, text);
            if !append && !edited(old, old_text, &frame, text) {
                return None;
            }
            let (query, start) = trailing_query(&text[..frame.cursor])?;
            if let Some((field, before, after)) = &self.dismissed {
                if *field == frame.context.field
                    && **before == text[..start]
                    && **after == text[frame.cursor..]
                {
                    return None;
                }
                self.dismissed = None;
            }
            if append
                && !query.is_empty()
                && let Some(snippet) = matching(ordinary, query)
            {
                return Some(Observation::Automatic(Plan {
                    frame: frame.copy(),
                    snippet: snippet.clone(),
                    start,
                    selected_query: None,
                }));
            }
            let mut entries: Vec<_> = ordinary
                .iter()
                .filter(|s| matches(s, query))
                .cloned()
                .collect();
            let frozen = self.ranking.get_or_insert_with(|| ranking.clone());
            frozen.rank(&mut entries, query);
            entries.truncate(MAX_CHOICES);
            if entries.is_empty() {
                return None;
            }
            Some(Observation::Choices(Choice {
                frame: frame.copy(),
                start,
                query: Zeroizing::new(query.into()),
                entries,
                selected: 0,
            }))
        })();
        if frame.admitted_text().is_some() {
            if frame
                .admitted_text()
                .and_then(|text| trailing_query(&text[..frame.cursor]))
                .is_none()
            {
                self.dismissed = None;
            }
            self.previous = Some(frame);
        } else {
            self.reset();
        }
        if !matches!(result, Some(Observation::Choices(_))) {
            self.ranking = None;
        }
        result.unwrap_or(Observation::Hidden)
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Next,
    Previous,
    Accept,
    Dismiss,
}
pub fn command(symbol: u32, modifiers: u32) -> Option<Command> {
    match (symbol, modifiers) {
        (0xff54, 0) | (0x6e | 0x4e, 2) => Some(Command::Next),
        (0xff52, 0) | (0x70 | 0x50, 2) | (0xff09 | 0xfe20, 1) => Some(Command::Previous),
        (0xff0d | 0xff8d | 0xff09, 0) => Some(Command::Accept),
        (0xff1b, 0) => Some(Command::Dismiss),
        _ => None,
    }
}

#[cfg(test)]
#[path = "inline_suggestions_tests.rs"]
mod tests;
fn bounded(value: &str, bytes: usize) -> String {
    let mut text = String::new();
    for g in value.graphemes(true) {
        if text.len() + g.len() > bytes {
            break;
        }
        if g.chars().any(|c| {
            c.is_control() || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        }) {
            text.push(' ');
        } else {
            text.push_str(g);
        }
    }
    text
}
fn highlights(value: &str, query: &str) -> Vec<(u32, u32)> {
    let pattern = model::folded(query);
    let mut pattern = pattern.chars().peekable();
    let mut matched = Vec::new();
    for (start, grapheme) in value.grapheme_indices(true) {
        let fold = model::folded(grapheme);
        let mut used = false;
        for character in fold.chars() {
            if pattern.peek() == Some(&character) {
                pattern.next();
                used = true;
            }
        }
        if used {
            matched.push((start as u32, (start + grapheme.len()) as u32));
        }
        if pattern.peek().is_none() {
            break;
        }
    }
    if pattern.peek().is_some() {
        vec![]
    } else {
        matched
    }
}
impl Choice {
    pub fn context(&self) -> Context {
        self.frame.context()
    }
    pub fn selected(&self) -> usize {
        self.selected
    }
    pub fn selected_id(&self) -> uuid::Uuid {
        self.entries[self.selected].id
    }
    pub fn select_id(&mut self, id: uuid::Uuid) {
        if let Some(index) = self.entries.iter().position(|s| s.id == id) {
            self.selected = index;
        }
    }
    pub fn move_selection(&mut self, next: bool) {
        self.selected = if next {
            (self.selected + 1) % self.entries.len()
        } else {
            (self.selected + self.entries.len() - 1) % self.entries.len()
        };
    }
    pub fn rows(&self) -> Vec<Row> {
        self.entries
            .iter()
            .map(|s| {
                let name = bounded(
                    if s.name.trim().is_empty() {
                        &s.keyword
                    } else {
                        &s.name
                    },
                    512,
                );
                let keyword = bounded(&s.keyword, 256);
                Row {
                    name_matches: highlights(&name, &self.query),
                    keyword_matches: highlights(&keyword, &self.query),
                    name,
                    keyword,
                    pinned: s.is_pinned,
                }
            })
            .collect()
    }
    pub fn validate(&self, current: &Frame, ordinary: &[Snippet]) -> Result<()> {
        if current.admitted_text().is_none()
            || current.context != self.frame.context
            || current.text != self.frame.text
            || current.cursor != self.frame.cursor
            || current.anchor != self.frame.anchor
            || current.content_type != self.frame.content_type
            || ordinary.iter().find(|s| s.id == self.selected_id())
                != Some(&self.entries[self.selected])
        {
            return Err(CHANGED);
        }
        Ok(())
    }
    pub fn choose(self, current: &Frame, ordinary: &[Snippet]) -> Result<Plan> {
        self.validate(current, ordinary)?;
        Ok(Plan {
            frame: self.frame,
            snippet: self.entries.into_iter().nth(self.selected).ok_or(CHANGED)?,
            start: self.start,
            selected_query: Some(self.query),
        })
    }
}
