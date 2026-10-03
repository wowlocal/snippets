//! Local suggestion learning. This data never belongs to a snippet or sync payload.
use crate::model::{self, Error, Result, Snippet};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const HALF_LIFE_DAYS: f64 = 14.0;
const DAY: f64 = 86_400.0;
const MAX_TIME: f64 = 4_102_444_800.0;
const MAX_WEIGHT: f64 = 1e12;
const MAX_RECORDS: usize = 5000;
const MAX_PREFIXES: usize = 400;
const MAX_CHOICES: usize = 4;

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub enum Event {
    Expansion,
    Paste,
    Copy,
}
impl Event {
    fn weight(self) -> f64 {
        if self == Self::Copy { 0.25 } else { 1.0 }
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Record {
    s: f64,
    n: u64,
    l: f64,
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Document {
    v: u32,
    epoch: f64,
    h: f64,
    w: BTreeMap<Uuid, Record>,
    b: BTreeMap<String, BTreeMap<Uuid, f64>>,
    #[serde(default)]
    rc: f64,
    #[serde(default)]
    bc: f64,
}

pub fn prefix(query: &str) -> Option<String> {
    // Reject a long query as a whole: truncating would alias unrelated selections.
    let folded = model::folded(query);
    let length = folded.graphemes(true).take(9).count();
    (length > 0 && length <= 8 && folded.len() <= 128 && !folded.chars().any(char::is_control))
        .then_some(folded)
}

fn time(now: f64) -> f64 {
    if now.is_finite() {
        now.clamp(0.0, MAX_TIME)
    } else {
        0.0
    }
}
fn growth(epoch: f64, now: f64, h: f64) -> f64 {
    ((time(now) - epoch).clamp(0.0, 400.0 * DAY) / (h * DAY)).exp2()
}

impl Document {
    pub(crate) fn new(now: f64) -> Self {
        Self {
            v: 1,
            epoch: time(now),
            h: HALF_LIFE_DAYS,
            w: BTreeMap::new(),
            b: BTreeMap::new(),
            rc: 0.0,
            bc: 0.0,
        }
    }
    pub(crate) fn decode(bytes: &[u8]) -> Result<Self> {
        // Probe first, so a newer schema remains protected even if v1 cannot decode it.
        let probe: serde_json::Value = serde_json::from_slice(bytes)
            .map_err(|_| Error("Usage data is unreadable; the original file was preserved."))?;
        if probe.get("v").and_then(serde_json::Value::as_u64) != Some(1) {
            return Err(Error(
                "Usage data has an unsupported version; the original file was preserved.",
            ));
        }
        let doc: Self = serde_json::from_value(probe)
            .map_err(|_| Error("Usage data is unreadable; the original file was preserved."))?;
        if ![doc.epoch, doc.rc, doc.bc]
            .into_iter()
            .all(|v| v.is_finite() && (0.0..=MAX_TIME).contains(&v))
            || !doc.h.is_finite()
            || !(1.0..=400.0).contains(&doc.h)
            || doc.w.len() > MAX_RECORDS
            || doc.b.len() > MAX_PREFIXES
            || doc.w.values().any(|r| {
                !r.s.is_finite()
                    || !(0.0..=MAX_WEIGHT).contains(&r.s)
                    || !r.l.is_finite()
                    || !(0.0..=MAX_TIME).contains(&r.l)
            })
            || doc.b.iter().any(|(p, table)| {
                prefix(p).as_ref() != Some(p)
                    || table.len() > MAX_CHOICES
                    || table
                        .values()
                        .any(|v| !v.is_finite() || !(0.0..=MAX_WEIGHT).contains(v))
            })
        {
            return Err(Error(
                "Usage data contains invalid values; the original file was preserved.",
            ));
        }
        Ok(doc)
    }
    pub(crate) fn record(&mut self, id: Uuid, kind: Event, query: Option<&str>, now: f64) {
        self.rebase_if_needed(now);
        let growth = growth(self.epoch, now, self.h);
        let r = self.w.entry(id).or_insert(Record {
            s: 0.0,
            n: 0,
            l: 0.0,
        });
        r.s = (r.s + kind.weight() * growth).min(MAX_WEIGHT);
        r.n = r.n.saturating_add(1);
        r.l = r.l.max(time(now));
        if let Some(p) = query.and_then(prefix) {
            let table = self.b.entry(p).or_default();
            for (competitor, weight) in table.iter_mut() {
                if *competitor != id {
                    *weight *= 0.7;
                }
            }
            let w = table.entry(id).or_default();
            *w = (*w + growth).min(growth).min(MAX_WEIGHT);
        }
    }
    pub(crate) fn reset(&mut self, records: bool, bindings: bool, now: f64) {
        if records {
            self.w.clear();
            self.rc = time(now).max(self.rc + 0.000_001).min(MAX_TIME);
        }
        if bindings {
            self.b.clear();
            self.bc = time(now).max(self.bc + 0.000_001).min(MAX_TIME);
        }
    }
    fn rescale(&mut self, epoch: f64) {
        let factor =
            (-(epoch - self.epoch).clamp(-400.0 * DAY, 400.0 * DAY) / (self.h * DAY)).exp2();
        for r in self.w.values_mut() {
            r.s = (r.s * factor).min(MAX_WEIGHT);
        }
        for table in self.b.values_mut() {
            for w in table.values_mut() {
                *w = (*w * factor).min(MAX_WEIGHT);
            }
        }
        self.epoch = epoch;
        self.h = HALF_LIFE_DAYS;
    }
    fn rebase_if_needed(&mut self, now: f64) {
        if time(now) - self.epoch >= 30.0 * DAY || self.w.values().any(|r| r.s >= 1e9) {
            self.rescale(time(now));
        }
    }
    pub(crate) fn join(mut self, mut disk: Self) -> Self {
        let epoch = self.epoch.max(disk.epoch);
        self.rescale(epoch);
        disk.rescale(epoch);
        if disk.rc > self.rc {
            self.w = disk.w;
        } else if disk.rc == self.rc {
            for (id, r) in disk.w {
                self.w
                    .entry(id)
                    .and_modify(|old| {
                        old.s = old.s.max(r.s);
                        old.n = old.n.max(r.n);
                        old.l = old.l.max(r.l);
                    })
                    .or_insert(r);
            }
        }
        if disk.bc > self.bc {
            self.b = disk.b;
        } else if disk.bc == self.bc {
            for (p, table) in disk.b {
                let combined = self.b.entry(p).or_default();
                for (id, w) in table {
                    combined
                        .entry(id)
                        .and_modify(|old| *old = old.max(w))
                        .or_insert(w);
                }
            }
        }
        self.rc = self.rc.max(disk.rc);
        self.bc = self.bc.max(disk.bc);
        self
    }
    pub(crate) fn prune(&mut self, now: f64, live: Option<&HashSet<Uuid>>) {
        let floor = 0.001 * growth(self.epoch, now, self.h);
        self.w.retain(|_, r| r.s >= floor);
        for table in self.b.values_mut() {
            table.retain(|_, w| *w >= floor);
            trim(table, MAX_CHOICES, live, |w| *w);
        }
        self.b.retain(|_, table| !table.is_empty());
        trim(&mut self.w, MAX_RECORDS, live, |r| r.s);
        if self.b.len() > MAX_PREFIXES {
            let mut order: Vec<_> = self
                .b
                .iter()
                .map(|(p, t)| (p.clone(), t.values().copied().fold(0.0, f64::max)))
                .collect();
            order.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
            let keep: HashSet<_> = order.into_iter().take(MAX_PREFIXES).map(|v| v.0).collect();
            self.b.retain(|p, _| keep.contains(p));
        }
    }
    pub(crate) fn snapshot(&self, ranking: bool, memory: bool, now: f64) -> Snapshot {
        let cutoff = 0.5 * growth(self.epoch, now, self.h);
        Snapshot {
            weights: if ranking {
                self.w
                    .iter()
                    .filter(|(_, r)| r.s >= cutoff)
                    .map(|(id, r)| (*id, r.s))
                    .collect()
            } else {
                BTreeMap::new()
            },
            bindings: if memory {
                self.b.clone()
            } else {
                BTreeMap::new()
            },
        }
    }
    pub(crate) fn counts(&self) -> (usize, usize) {
        (self.w.len(), self.b.len())
    }
}

fn trim<T>(
    table: &mut BTreeMap<Uuid, T>,
    limit: usize,
    live: Option<&HashSet<Uuid>>,
    weight: impl Fn(&T) -> f64,
) {
    if table.len() <= limit {
        return;
    }
    let mut order: Vec<_> = table
        .iter()
        .map(|(id, v)| (*id, live.is_none_or(|ids| ids.contains(id)), weight(v)))
        .collect();
    order.sort_by(|a, b| b.1.cmp(&a.1).then(b.2.total_cmp(&a.2)).then(a.0.cmp(&b.0)));
    let keep: HashSet<_> = order.into_iter().take(limit).map(|v| v.0).collect();
    table.retain(|id, _| keep.contains(id));
}

#[derive(Clone, Default)]
pub struct Snapshot {
    weights: BTreeMap<Uuid, f64>,
    bindings: BTreeMap<String, BTreeMap<Uuid, f64>>,
}
impl Snapshot {
    /// Only the picker uses this ordering. The library list retains model::search.
    pub fn rank(&self, snippets: &mut [Snippet], query: &str) {
        let folded = model::folded(query);
        // Very long free-text searches retain their existing deterministic display order.
        if folded.graphemes(true).take(129).count() > 128 {
            return;
        }
        let binding = prefix(query).and_then(|p| self.bindings.get(&p));
        let keys: BTreeMap<_, _> = snippets
            .iter()
            .map(|s| {
                let keyword = model::folded(&s.keyword);
                let score = folded
                    .split_whitespace()
                    .map(|word| {
                        fuzzy_score(word, &keyword).max(fuzzy_score(word, &model::folded(&s.name)))
                    })
                    .sum::<usize>();
                let keyword_rank = if folded.is_empty() {
                    0
                } else if keyword == folded {
                    3
                } else if keyword.starts_with(&folded) {
                    2
                } else if fuzzy_score(&folded, &keyword) > 0 {
                    1
                } else {
                    0
                };
                (
                    s.id,
                    (
                        score,
                        keyword_rank,
                        binding.and_then(|b| b.get(&s.id)).copied().unwrap_or(0.0),
                        self.weights.get(&s.id).copied().unwrap_or(0.0),
                    ),
                )
            })
            .collect();
        snippets.sort_by(|a, b| {
            let a_key = keys[&a.id];
            let b_key = keys[&b.id];
            b_key
                .0
                .cmp(&a_key.0)
                .then(b_key.1.cmp(&a_key.1))
                .then(b.is_pinned.cmp(&a.is_pinned))
                .then(b_key.2.total_cmp(&a_key.2))
                .then(b_key.3.total_cmp(&a_key.3))
                .then(b.created_at.total_cmp(&a.created_at))
                .then(a.id.cmp(&b.id))
        });
    }
}

// The Mac score-only fuzzy contract: word-start/start-of-target and growing streak bonuses.
// Keep each adjacent streak, since a lower intermediate score can win later.
fn fuzzy_score(query: &str, target: &str) -> usize {
    let pattern: Vec<_> = query.graphemes(true).collect();
    if pattern.is_empty() {
        return 0;
    }
    let text: Vec<_> = target.graphemes(true).collect();
    let base = |i: usize| {
        1 + if i == 0 || text[i - 1].chars().all(|c| !c.is_alphanumeric()) {
            3
        } else {
            0
        }
    };
    let mut previous: Vec<(usize, usize, usize)> = text
        .iter()
        .enumerate()
        .filter(|(_, c)| **c == pattern[0])
        .map(|(i, _)| (i, 0, base(i) + if i == 0 { 5 } else { 0 }))
        .collect();
    for letter in pattern.into_iter().skip(1) {
        let mut next = Vec::new();
        let mut cursor = 0;
        let mut gap = 0;
        for (i, _) in text.iter().enumerate().filter(|(_, c)| **c == letter) {
            while cursor < previous.len() && previous[cursor].0 + 1 < i {
                gap = gap.max(previous[cursor].2);
                cursor += 1;
            }
            if gap > 0 {
                next.push((i, 0, gap + base(i)));
            }
            for p in previous[cursor..].iter().take_while(|p| p.0 + 1 == i) {
                next.push((i, p.1 + 1, p.2 + base(i) + (p.1 + 1) * 2));
            }
        }
        previous = next;
        if previous.is_empty() {
            return 0;
        }
    }
    previous.into_iter().map(|p| p.2).max().unwrap_or(0)
}

#[cfg(test)]
#[path = "usage_tests.rs"]
mod tests;
