use super::*;

const NOW: f64 = 1_700_000_000.0;
fn snippet(id: u128, keyword: &str, created: f64) -> Snippet {
    Snippet {
        id: Uuid::from_u128(id),
        name: String::new(),
        keyword: keyword.into(),
        content: String::new(),
        tags: vec![],
        is_enabled: true,
        is_pinned: false,
        created_at: created,
        updated_at: created,
    }
}
fn order(snapshot: &Snapshot, query: &str, snippets: &[Snippet]) -> Vec<Uuid> {
    let mut values = snippets.to_vec();
    snapshot.rank(&mut values, query);
    values.iter().map(|s| s.id).collect()
}

#[test]
fn weights_decay_rebase_and_single_copy_floor_match_native_contract() {
    let a = Uuid::from_u128(1);
    let b = Uuid::from_u128(2);
    let mut doc = Document::new(NOW);
    doc.record(a, Event::Copy, None, NOW);
    assert!(doc.snapshot(true, true, NOW).weights.is_empty());
    doc.record(a, Event::Copy, None, NOW);
    assert_eq!(doc.snapshot(true, true, NOW).weights[&a], 0.5);
    assert!(
        doc.snapshot(true, true, NOW + 14.0 * DAY)
            .weights
            .is_empty()
    );
    doc.record(b, Event::Expansion, None, NOW);
    let mut rebased = doc.clone();
    rebased.rescale(NOW + 14.0 * DAY);
    assert_eq!(rebased.w[&a].s, 0.25);
    assert_eq!(rebased.w[&b].s, 0.5);
    assert_eq!(rebased.w[&a].n, 2);
    assert_eq!(rebased.w[&b].l, NOW);
    assert_eq!(growth(NOW, NOW - DAY, HALF_LIFE_DAYS), 1.0);
    assert_eq!(
        growth(NOW, NOW + 800.0 * DAY, HALF_LIFE_DAYS),
        growth(NOW, NOW + 400.0 * DAY, HALF_LIFE_DAYS)
    );
}

#[test]
fn selection_correction_beats_saturated_competitor_without_changing_match_or_pin_priority() {
    let a = snippet(1, "reply", 1.0);
    let b = snippet(2, "refund", 2.0);
    let mut exact = snippet(3, "re", 3.0);
    exact.is_pinned = false;
    let mut pinned = snippet(4, "request", 4.0);
    pinned.is_pinned = true;
    let mut doc = Document::new(NOW);
    for _ in 0..50 {
        doc.record(a.id, Event::Paste, Some("re"), NOW);
    }
    let frozen = doc.snapshot(true, true, NOW);
    assert_eq!(
        order(&frozen, "re", &[a.clone(), b.clone()]),
        vec![a.id, b.id]
    );
    doc.record(b.id, Event::Paste, Some("re"), NOW);
    let corrected = doc.snapshot(true, true, NOW);
    assert_eq!(
        order(&corrected, "re", &[a.clone(), b.clone()]),
        vec![b.id, a.id]
    );
    assert_eq!(
        order(&frozen, "re", &[a.clone(), b.clone()]),
        vec![a.id, b.id]
    );
    assert_eq!(
        order(
            &corrected,
            "re",
            &[a.clone(), b.clone(), exact.clone(), pinned.clone()]
        ),
        vec![exact.id, pinned.id, b.id, a.id]
    );
    assert_eq!(
        order(&corrected, "", &[a.clone(), pinned.clone()]),
        vec![pinned.id, a.id]
    );
    assert_eq!(
        order(
            &doc.snapshot(false, false, NOW),
            "re",
            &[a.clone(), b.clone()]
        ),
        vec![b.id, a.id]
    );
}

#[test]
fn fuzzy_score_preserves_prefix_ties_and_best_adjacent_streak() {
    assert_eq!(fuzzy_score("r", "reply"), 9);
    assert_eq!(fuzzy_score("re", "reply"), 12);
    assert_eq!(fuzzy_score("ref", "refund"), 17);
    assert_eq!(fuzzy_score("re", "refund"), fuzzy_score("re", "request"));
    assert_eq!(fuzzy_score("xyz", "reply"), 0);
    // Exhaustive small reference scorer catches incorrect greedy gap/streak pruning.
    fn reference(
        q: &[char],
        text: &[char],
        start: usize,
        last: Option<usize>,
        streak: usize,
    ) -> usize {
        if q.is_empty() {
            return 1;
        }
        let mut best = 0;
        for i in start..text.len() {
            if text[i] != q[0] {
                continue;
            }
            let next_streak = if last.is_some_and(|p| p + 1 == i) {
                streak + 1
            } else {
                0
            };
            let tail = reference(&q[1..], text, i + 1, Some(i), next_streak);
            if tail > 0 {
                best = best.max(
                    tail + 1
                        + if i == 0 { 3 } else { 0 }
                        + if last.is_none() && i == 0 { 5 } else { 0 }
                        + 2 * next_streak,
                );
            }
        }
        best
    }
    for n in 1..=8 {
        for mask in 0..(1 << n) {
            let text: String = (0..n)
                .map(|i| if mask & (1 << i) == 0 { 'a' } else { 'b' })
                .collect();
            for query in ["a", "b", "aa", "ab", "ba", "aba", "aaa", "aaba"] {
                let r = reference(
                    &query.chars().collect::<Vec<_>>(),
                    &text.chars().collect::<Vec<_>>(),
                    0,
                    None,
                    0,
                );
                assert_eq!(
                    fuzzy_score(query, &text),
                    r.saturating_sub(1),
                    "{query}: {text}"
                );
            }
        }
    }
}

#[test]
fn join_is_idempotent_max_based_and_reset_markers_dominate_stale_writers() {
    let a = Uuid::from_u128(1);
    let b = Uuid::from_u128(2);
    let mut first = Document::new(NOW);
    first.record(a, Event::Paste, Some("re"), NOW);
    let mut second = first.clone();
    second.record(b, Event::Paste, Some("re"), NOW + DAY);
    second.rescale(NOW + 14.0 * DAY);
    let joined = first.clone().join(second.clone());
    assert!(joined == second.clone().join(first.clone()));
    assert!(joined.clone() == joined.clone().join(joined.clone()));
    assert_eq!(joined.w[&a].n, 1);
    assert_eq!(joined.w[&a].s, 0.5);
    let mut reset = joined.clone();
    reset.reset(true, true, NOW + 14.0 * DAY);
    assert!(reset.clone().join(joined.clone()).w.is_empty());
    assert!(joined.join(reset.clone()).b.is_empty());
    reset.record(b, Event::Expansion, Some("re"), NOW + 15.0 * DAY);
    let merged = reset.join(first);
    assert!(!merged.w.contains_key(&a));
    assert!(merged.w.contains_key(&b));
    assert_eq!(merged.b["re"].len(), 1);
}

#[test]
fn prefixes_are_folded_bounded_without_truncation_and_schema_is_closed() {
    assert_eq!(prefix("RÉ"), Some("re".into()));
    assert_eq!(prefix("Straße"), Some("strasse".into()));
    assert!(prefix("").is_none());
    assert!(prefix("re\n").is_none());
    assert!(prefix("123456789").is_none());
    let mut doc = Document::new(NOW);
    let id = Uuid::from_u128(1);
    doc.record(id, Event::Copy, Some("123456789"), NOW);
    assert!(doc.b.is_empty());
    let bytes = serde_json::to_vec(&doc).unwrap();
    assert!(Document::decode(&bytes).unwrap() == doc);
    for altered in [
        serde_json::json!({"v":2,"new":"schema"}),
        serde_json::json!({"v":1,"epoch":NOW,"h":0,"w":{},"b":{}}),
        serde_json::json!({"v":1,"epoch":NOW,"h":14,"w":{},"b":{},"body":"forbidden"}),
        serde_json::json!({"v":1,"epoch":-1,"h":14,"w":{},"b":{}}),
        serde_json::json!({"v":1,"epoch":NOW,"h":14,"w":{},"b":{"longprefix":{}}}),
    ] {
        assert!(Document::decode(&serde_json::to_vec(&altered).unwrap()).is_err());
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["b", "bc", "epoch", "h", "rc", "v", "w"]
    );
    assert_eq!(
        value["w"][id.to_string()]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        vec!["l", "n", "s"]
    );
}

#[test]
fn capacity_eviction_prefers_live_ids_but_keeps_orphans_until_needed() {
    let mut doc = Document::new(NOW);
    for id in 1..=5001 {
        doc.record(Uuid::from_u128(id), Event::Paste, None, NOW);
    }
    let live = HashSet::from([Uuid::from_u128(5001)]);
    doc.prune(NOW, Some(&live));
    assert_eq!(doc.w.len(), 5000);
    assert!(doc.w.contains_key(&Uuid::from_u128(5001)));
    assert!(doc.w.contains_key(&Uuid::from_u128(1)));
    for p in 0..401 {
        for id in 1..=5 {
            doc.record(
                Uuid::from_u128(id),
                Event::Paste,
                Some(&format!("p{p}")),
                NOW,
            );
        }
    }
    doc.prune(NOW, Some(&HashSet::from([Uuid::from_u128(1)])));
    assert_eq!(doc.b.len(), 400);
    assert!(
        doc.b
            .values()
            .all(|t| t.len() == 4 && t.contains_key(&Uuid::from_u128(1)))
    );
    doc.prune(NOW + 400.0 * DAY, None);
    assert!(doc.w.is_empty());
    assert!(doc.b.is_empty());
}
