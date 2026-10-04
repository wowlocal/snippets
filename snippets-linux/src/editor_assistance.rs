//! Deterministic editor assistance, using the same keyword fold as insertion.
//! Secure body text is excluded by construction. Existing keywords are references,
//! never collision-safe suggestions.
use crate::model::{self, Snippet};
use std::collections::HashSet;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Relation {
    Unrelated,
    Duplicate,
    BlockedByLonger,
    BlocksShorter,
}
pub fn relation(keyword: &str, other: &str) -> Relation {
    let keyword = folded_keyword(keyword);
    let other = folded_keyword(other);
    if keyword.is_empty() || other.is_empty() {
        Relation::Unrelated
    } else if keyword == other {
        Relation::Duplicate
    } else if other.starts_with(&keyword) {
        Relation::BlockedByLonger
    } else if keyword.starts_with(&other) {
        Relation::BlocksShorter
    } else {
        Relation::Unrelated
    }
}
fn folded_keyword(value: &str) -> String {
    model::folded(&model::keyword(value))
}
pub enum Body<'a> {
    OrdinaryFirstLine(&'a str),
    Secure,
}
fn words(value: &str) -> Vec<String> {
    // Assistance only needs the opening words, not an arbitrarily large body.
    let bounded: String = value.chars().take(4096).collect();
    model::folded(&bounded)
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .take(32)
        .map(String::from)
        .collect()
}
pub fn candidates(name: &str, body: Body<'_>) -> Vec<String> {
    let mut result = Vec::new();
    let mut append = |value: String| {
        if value.len() >= 2 && !result.contains(&value) {
            result.push(value);
        }
    };
    let abbreviations = |word: &str| -> Vec<String> {
        if word.len() <= 6 {
            vec![word.into()]
        } else {
            vec![word[..4].into(), word[..3].into()]
        }
    };
    let name_words = words(name);
    if let Some(first) = name_words.first() {
        for value in abbreviations(first) {
            append(value);
        }
    }
    if name_words.len() > 1 {
        append(
            name_words
                .iter()
                .take(5)
                .filter_map(|word| word.chars().next())
                .collect(),
        );
    }
    if let Body::OrdinaryFirstLine(body) = body
        && let Some(first) = words(body.lines().next().unwrap_or(""))
            .iter()
            .find(|word| !matches!(word.as_str(), "http" | "https" | "www"))
    {
        for value in abbreviations(first) {
            append(value);
        }
    }
    result
}
fn existing_rank(query: &str, candidate: &str) -> Option<u8> {
    if query == candidate {
        return Some(0);
    }
    if candidate.starts_with(query) {
        return Some(1);
    }
    let parts: Vec<_> = candidate.split('.').filter(|p| !p.is_empty()).collect();
    if parts.contains(&query) {
        return Some(2);
    }
    if parts.iter().any(|part| part.starts_with(query)) {
        return Some(3);
    }
    if candidate.contains(query) {
        return Some(4);
    }
    let mut query_parts: Vec<_> = query.split('.').filter(|p| !p.is_empty()).collect();
    if query_parts.len() <= 1 || parts.len() < query_parts.len() {
        return None;
    }
    query_parts.sort_by_key(|part| std::cmp::Reverse(part.len()));
    let mut available = parts;
    for part in query_parts {
        let index = available
            .iter()
            .position(|candidate| candidate.contains(part))?;
        available.remove(index);
    }
    Some(5)
}
pub fn existing_matches(query: &str, keywords: &[String]) -> Vec<String> {
    let query = folded_keyword(query);
    if query.is_empty() {
        return Vec::new();
    }
    let mut seen = HashSet::new();
    let mut matches: Vec<_> = keywords
        .iter()
        .filter_map(|raw| {
            let keyword = model::keyword(raw);
            let folded = folded_keyword(&keyword);
            if folded.is_empty() || !seen.insert(folded.clone()) {
                return None;
            }
            Some((existing_rank(&query, &folded)?, folded, keyword))
        })
        .collect();
    matches.sort();
    matches.into_iter().map(|(_, _, keyword)| keyword).collect()
}
fn folded_end(source: &str, query: &str) -> Option<usize> {
    for (start, grapheme) in source.grapheme_indices(true) {
        let end = start + grapheme.len();
        let folded = folded_keyword(&source[..end]);
        if folded == query {
            return Some(end);
        }
        if !query.starts_with(&folded) {
            return None;
        }
    }
    None
}
pub fn tab_completion(query: &str, keywords: &[String]) -> Option<String> {
    let query = model::keyword(query);
    let folded = folded_keyword(&query);
    if folded.is_empty() {
        return None;
    }
    let mut seen = HashSet::new();
    let targets: Vec<_> = keywords
        .iter()
        .filter_map(|raw| {
            let candidate = model::keyword(raw);
            let key = folded_keyword(&candidate);
            if key.is_empty() || !seen.insert(key) {
                return None;
            }
            let start = folded_end(&candidate, &folded)?;
            if start == candidate.len() {
                return None;
            }
            let suffix = &candidate[start..];
            let length = suffix
                .char_indices()
                .find(|(_, c)| matches!(c, '.' | '-') || c.is_whitespace())
                .map_or(suffix.len(), |(index, c)| index + c.len_utf8());
            Some(format!("{query}{}", &suffix[..length]))
        })
        .collect();
    let first = targets.first()?;
    let mut common = folded_keyword(first);
    for target in targets.iter().skip(1) {
        common = common
            .chars()
            .zip(folded_keyword(target).chars())
            .take_while(|(a, b)| a == b)
            .map(|(a, _)| a)
            .collect();
    }
    if common.chars().count() <= folded.chars().count() {
        return None;
    }
    let end = folded_end(first, &common)?;
    Some(first[..end].into())
}

#[derive(Default, Clone, PartialEq, Eq)]
pub struct Warnings {
    pub duplicates: usize,
    pub blocked_by_longer: usize,
    pub blocks_shorter: usize,
    pub unsupported_trigger: bool,
    pub disabled: bool,
}
#[derive(Default, Clone, PartialEq, Eq)]
pub struct Summary {
    pub suggestions: Vec<String>,
    pub references: Vec<String>,
    pub warnings: Warnings,
}
pub fn summarize(
    id: Uuid,
    name: &str,
    keyword: &str,
    enabled: bool,
    body: Body<'_>,
    library: &[Snippet],
) -> Summary {
    let others: Vec<_> = library.iter().filter(|snippet| snippet.id != id).collect();
    let keys: Vec<_> = others.iter().map(|s| s.keyword.clone()).collect();
    let mut result = Summary::default();
    let sanitized = model::keyword(keyword);
    if sanitized.is_empty() {
        result.suggestions = candidates(name, body)
            .into_iter()
            .filter(|candidate| {
                others
                    .iter()
                    .all(|other| match relation(candidate, &other.keyword) {
                        Relation::Unrelated => true,
                        Relation::Duplicate => false, // Disabled records still reserve the saved keyword.
                        _ => !enabled || !other.is_enabled,
                    })
            })
            .take(3)
            .collect();
    } else {
        result.references = existing_matches(&sanitized, &keys)
            .into_iter()
            .take(8)
            .collect();
        result.warnings.disabled = !enabled;
        result.warnings.unsupported_trigger = sanitized.graphemes(true).any(|g| {
            g.chars().count() != 1 || g.chars().any(|c| c.is_whitespace() || c.is_control())
        }) || sanitized.graphemes(true).take(121).count()
            > 120;
        for other in others {
            match relation(&sanitized, &other.keyword) {
                Relation::Duplicate => result.warnings.duplicates += 1,
                Relation::BlockedByLonger if enabled && other.is_enabled => {
                    result.warnings.blocked_by_longer += 1
                }
                Relation::BlocksShorter if enabled && other.is_enabled => {
                    result.warnings.blocks_shorter += 1
                }
                _ => (),
            }
        }
    }
    result
}

#[cfg(test)]
#[path = "editor_assistance_tests.rs"]
mod tests;
