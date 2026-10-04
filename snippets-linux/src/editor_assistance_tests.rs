use super::*;
use chrono::{Local, TimeZone};

fn keys(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| String::from(*s)).collect()
}
fn record(keyword: &str, enabled: bool) -> Snippet {
    let mut snippet = Snippet::new("Public fixture", "");
    snippet.keyword = keyword.into();
    snippet.is_enabled = enabled;
    snippet
}

#[test]
fn frozen_mac_candidate_examples_and_secure_body_boundary() {
    let examples = [
        (
            "Signature Block",
            "Best regards",
            vec!["sign", "sig", "sb", "best"],
        ),
        ("Email", "", vec!["email"]),
        ("Café Order", "", vec!["cafe", "co"]),
        ("", "https://github.com/mike/snippets", vec!["github"]),
        ("", "Thanks so much for the update", vec!["thanks"]),
        ("", "", vec![]),
        ("日本語", "こんにちは", vec![]),
        ("A", "", vec![]),
        ("A B", "", vec!["ab"]),
        ("Invoice", "Invoice for services", vec!["invo", "inv"]),
    ];
    for (name, body, expected) in examples {
        assert_eq!(
            candidates(name, Body::OrdinaryFirstLine(body)),
            keys(&expected),
            "{name}"
        );
    }
    assert!(candidates("", Body::Secure).is_empty());
    assert_eq!(
        candidates("Signature Block", Body::Secure),
        keys(&["sign", "sig", "sb"])
    );
    assert!(candidates("", Body::OrdinaryFirstLine("\nSecond line is not a name")).is_empty());
}

#[test]
fn references_rank_components_and_deduplicate_folded_keywords() {
    for (query, library, expected) in [
        (
            "doc",
            vec!["frontend.doc", "doc.backend", "product"],
            vec!["doc.backend", "frontend.doc"],
        ),
        (
            "frontend.doc",
            vec!["other", "doc.frontend", "doc.backend"],
            vec!["doc.frontend"],
        ),
        (
            "front.do",
            vec!["doc.frontend", "doc.backend", "frontend.design"],
            vec!["doc.frontend"],
        ),
        (
            "\\CAFÉ.DOC",
            vec!["cafe.doc.extra", "Café.Doc", "cafe.doc", "other.cafe.doc"],
            vec!["Café.Doc", "cafe.doc.extra", "other.cafe.doc"],
        ),
        ("doc.doc", vec!["doc.frontend"], vec![]),
        (" ", vec!["doc.frontend"], vec![]),
    ] {
        assert_eq!(existing_matches(query, &keys(&library)), keys(&expected));
    }
}

#[test]
fn tab_completes_only_shared_next_part_and_keeps_unicode_source_boundaries() {
    for (query, library, expected) in [
        ("do", vec!["doc.frontend", "doc.backend"], Some("doc.")),
        (
            "doc.front",
            vec!["doc.frontend.controls"],
            Some("doc.frontend."),
        ),
        ("my", vec!["my-signature.work"], Some("my-")),
        (
            "doc.f",
            vec!["doc.frontend", "doc.framework"],
            Some("doc.fr"),
        ),
        ("doc.", vec!["doc.frontend", "doc.backend"], None),
        ("frontend", vec!["doc.frontend"], None),
        ("CAF", vec!["café.docs"], Some("CAFé.")),
        ("doc.frontend", vec!["doc.frontend"], None),
        ("Stra", vec!["Straße.work"], Some("Straße.")),
        ("STRAS", vec!["Straße.work"], None),
        ("CAF", vec!["cafe\u{301}.docs"], Some("CAFe\u{301}.")),
        ("", vec!["doc"], None),
    ] {
        assert_eq!(
            tab_completion(query, &keys(&library)).as_deref(),
            expected,
            "{query}"
        );
    }
}

#[test]
fn both_prefix_directions_are_visible_and_disabled_entries_reserve_duplicates() {
    assert_eq!(relation("em", "Email"), Relation::BlockedByLonger);
    assert_eq!(relation("email", "EM"), Relation::BlocksShorter);
    assert_eq!(relation("\\CAFÉ", "cafe"), Relation::Duplicate);
    assert_eq!(relation("", "email"), Relation::Unrelated);
    let id = Uuid::new_v4();
    let mut own = record("email", true);
    own.id = id;
    let library = [
        own,
        record("em", true),
        record("email-long", true),
        record("email", false),
        record("email.ignored", false),
    ];
    let summary = summarize(id, "", "EMAIL", true, Body::Secure, &library);
    assert_eq!(summary.warnings.duplicates, 1);
    assert_eq!(summary.warnings.blocked_by_longer, 1);
    assert_eq!(summary.warnings.blocks_shorter, 1);
    let disabled = summarize(id, "", "email", false, Body::Secure, &library);
    assert_eq!(disabled.warnings.duplicates, 1);
    assert_eq!(disabled.warnings.blocked_by_longer, 0);
    assert_eq!(disabled.warnings.blocks_shorter, 0);
    assert!(disabled.warnings.disabled);
}

#[test]
fn safe_suggestions_include_secure_metadata_and_respect_save_reservations() {
    let id = Uuid::new_v4();
    let library = [
        record("sign", false),
        record("signature", true),
        record("s", true),
    ];
    let summary = summarize(
        id,
        "Signature Block",
        "",
        true,
        Body::OrdinaryFirstLine("Best regards"),
        &library,
    );
    assert_eq!(summary.suggestions, keys(&["best"]));
    assert!(summary.references.is_empty());
    let library = [record("sign", false), record("signature", false)];
    assert_eq!(
        summarize(id, "Signature Block", "", true, Body::Secure, &library).suggestions,
        keys(&["sig", "sb"])
    );
    let many = (0..30)
        .map(|i| record(&format!("doc.{i}"), true))
        .collect::<Vec<_>>();
    assert_eq!(
        summarize(id, "", "doc", true, Body::Secure, &many)
            .references
            .len(),
        8
    );
    assert!(
        summarize(
            id,
            "A B C D E F",
            "",
            true,
            Body::OrdinaryFirstLine("Different"),
            &[]
        )
        .suggestions
        .len()
            <= 3
    );
}

#[test]
fn invalid_trigger_warning_matches_insertion_grapheme_limits() {
    let id = Uuid::new_v4();
    for value in ["cafe\u{301}", "👨‍👩‍👧", "bad\u{1b}", &"a".repeat(121)] {
        assert!(
            summarize(id, "", value, true, Body::Secure, &[])
                .warnings
                .unsupported_trigger
        );
    }
    assert!(
        !summarize(id, "", "café-123", true, Body::Secure, &[])
            .warnings
            .unsupported_trigger
    );
}

#[test]
fn preview_reuses_native_grammar_one_pass_and_calendar_offsets() {
    let now = Local.with_ymd_and_hms(2025, 1, 31, 12, 34, 56).unwrap();
    let preview = crate::placeholders::preview_at(
        "{date:yyyy-MM-dd} {time:HH:mm} {clipboard} {date offset=+1M format=yyyy-MM-dd} {unknown}",
        "{date}",
        now,
    );
    assert_eq!(preview.text, "2025-01-31 12:34 {date} 2025-02-28 {unknown}");
    assert!(preview.has_placeholder && !preview.truncated);
    let invalid = crate::placeholders::preview_at(
        "{date format=yyyy locale=en} {date offset=+100001d} {unknown}",
        "",
        now,
    );
    assert!(!invalid.has_placeholder && !invalid.truncated);
    assert_eq!(
        invalid.text,
        "{date format=yyyy locale=en} {date offset=+100001d} {unknown}"
    );
}

#[test]
fn preview_caps_clipboard_and_rendered_text_without_splitting_graphemes() {
    let now = Local::now();
    let value = "👩🏽‍💻".repeat(1001);
    let preview = crate::placeholders::preview_at("{clipboard}", &value, now);
    assert!(preview.has_placeholder);
    assert!(preview.text.contains("[clipboard truncated]"));
    assert!(preview.text.len() < 16410);
    assert!(!preview.text.contains('\u{fffd}'));
    let preview =
        crate::placeholders::preview_at(&format!("{}{{date}}", "x".repeat(2001)), "", now);
    assert!(preview.has_placeholder && preview.truncated);
    assert_eq!(
        preview.text,
        format!("{}[preview truncated]", "x".repeat(2000))
    );
    let pathological = format!("a{}{{time}}", "\u{301}".repeat(100000));
    let preview = crate::placeholders::preview_at(&pathological, "", now);
    assert!(preview.has_placeholder && preview.truncated);
    assert_eq!(preview.text, "[preview truncated]");
}

#[test]
fn view_catalogue_is_fresh_and_refuses_busy_or_unknown_primary_state() {
    let directory = tempfile::tempdir().unwrap();
    let mut library = model::Library::open(directory.path().into()).unwrap();
    let mut first = record("old", true);
    library.save(first.clone(), None).unwrap();
    first = library.get(first.id).unwrap();
    let mut external = model::Library::open(directory.path().into()).unwrap();
    let old = first.clone();
    first.keyword = "changed".into();
    external.save(first, Some(&old)).unwrap();
    assert_eq!(library.try_catalogue().unwrap().0[0].keyword, "changed");
    let guard = external.lock().unwrap();
    let start = std::time::Instant::now();
    assert!(library.try_catalogue().is_err());
    assert!(start.elapsed() < std::time::Duration::from_millis(500));
    drop(guard);
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    std::fs::create_dir(directory.path().join("Vault")).unwrap();
    model::atomic_write(
        &directory.path().join("Vault/vault.json"),
        &serde_json::to_vec(&fixture["document"]).unwrap(),
    )
    .unwrap();
    let (_, secure) = library.try_catalogue().unwrap();
    assert_eq!(secure.len(), 1);
    assert!(secure[0].shell().content.is_empty());
    model::atomic_write(
        &directory.path().join("Vault/vault.json"),
        b"unknown version or malformed data",
    )
    .unwrap();
    assert!(library.try_catalogue().is_err());
}
