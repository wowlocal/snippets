use super::*;
fn frame(text: &str, serial: u32) -> Frame {
    Frame::from_protocol(
        Context { field: 1, serial },
        true,
        Some(Zeroizing::new(text.into())),
        (text.len() as u32, text.len() as u32),
        Some((0, 0)),
        1,
    )
}
fn snippet(name: &str, keyword: &str) -> Snippet {
    let mut s = Snippet::new(name, "Public fictional body excluded from presentation");
    s.keyword = keyword.into();
    s
}
fn choices(ordinary: &[Snippet], query: &str) -> Choice {
    let mut engine = Suggestions::default();
    assert!(matches!(
        engine.observe(frame("Public ", 1), ordinary, &Snapshot::default()),
        Observation::Hidden
    ));
    let Observation::Choices(choice) = engine.observe(
        frame(&format!("Public \\{query}"), 2),
        ordinary,
        &Snapshot::default(),
    ) else {
        panic!("public choices");
    };
    choice
}
#[test]
fn prefixes_fuzzy_names_and_empty_triggers_present_metadata_only_and_bound_eight_rows() {
    let values: Vec<_> = (0..12)
        .map(|i| snippet(&format!("Public meeting {i}"), &format!("meeting-{i}")))
        .collect();
    for query in ["meet", "pbm", ""] {
        let choice = choices(&values, query);
        let rows = choice.rows();
        assert_eq!(rows.len(), 8);
        assert!(
            rows.iter()
                .all(|r| !r.name.contains("body") && !r.keyword.contains("body"))
        );
    }
    assert!(!matches(&values[0], "fictional"));
    assert!(!matches(&values[0], "excluded"));
    let mut disabled = values[0].clone();
    disabled.is_enabled = false;
    assert!(!matches(&disabled, ""));
    disabled.is_enabled = true;
    disabled.keyword.clear();
    assert!(!matches(&disabled, ""));
}
#[test]
fn ambiguous_exact_names_require_selection_and_selection_wraps_without_losing_identity() {
    let values = [
        snippet("Public reply", "reply"),
        snippet("Public refund", "refund"),
    ];
    let mut choice = choices(&values, "re");
    let first = choice.selected_id();
    choice.move_selection(false);
    assert_ne!(choice.selected_id(), first);
    choice.move_selection(true);
    assert_eq!(choice.selected_id(), first);
    let row = choice.rows().remove(0);
    assert!(!row.keyword_matches.is_empty());
    let plan = choice.choose(&frame("Public \\re", 2), &values).unwrap();
    assert_eq!(plan.snippet.id, first);
    assert_eq!(
        plan.selected_query.as_deref().map(|s| s.as_str()),
        Some("re")
    );
    let values = [
        snippet("Public reply", "reply"),
        snippet("Public replies", "reply-more"),
    ];
    let choice = choices(&values, "reply");
    assert_eq!(choice.rows().len(), 2);
}
#[test]
fn only_confirmed_appends_automatically_expand_and_confirmed_query_backspace_keeps_choices() {
    let values = [snippet("Public meeting", "meet")];
    let mut engine = Suggestions::default();
    assert!(matches!(
        engine.observe(frame("\\mee", 1), &values, &Snapshot::default()),
        Observation::Hidden
    ));
    assert!(matches!(
        engine.observe(frame("\\meet", 2), &values, &Snapshot::default()),
        Observation::Automatic(_)
    ));
    let mut engine = Suggestions::default();
    engine.observe(frame("\\meets", 1), &values, &Snapshot::default());
    assert!(matches!(
        engine.observe(frame("\\meet", 2), &values, &Snapshot::default()),
        Observation::Choices(_)
    ));
}
#[test]
fn stale_private_selected_edited_and_changed_snippet_snapshots_refuse_selection() {
    let values = [
        snippet("Public reply", "reply"),
        snippet("Public refund", "refund"),
    ];
    for case in 0..8 {
        let choice = choices(&values, "re");
        let mut current = frame("Public \\re", 2);
        let mut ordinary = values.to_vec();
        match case {
            0 => current.context.field += 1,
            1 => current.context.serial += 1,
            2 => current.content_type = Some((0, 8)),
            3 => current.anchor = 0,
            4 => current.text = Some(Zeroizing::new("Other! \\re".into())),
            5 => current.active = false,
            6 => ordinary
                .iter_mut()
                .find(|s| s.id == choice.selected_id())
                .unwrap()
                .content
                .push('!'),
            _ => ordinary.clear(),
        }
        assert!(choice.choose(&current, &ordinary).is_err());
    }
}
#[test]
fn foreign_or_unconfirmed_host_edits_drop_choices_and_reset_frozen_ranking() {
    let values = [
        snippet("Public reply", "reply"),
        snippet("Public refund", "refund"),
    ];
    for case in 0..6 {
        let mut engine = Suggestions::default();
        engine.observe(frame("Public ", 1), &values, &Snapshot::default());
        assert!(matches!(
            engine.observe(frame("Public \\re", 2), &values, &Snapshot::default()),
            Observation::Choices(_)
        ));
        let mut next = frame("Public \\ref", 3);
        match case {
            0 => next.context.field += 1,
            1 => next.change_cause = 0,
            2 => next.context.serial = 2,
            3 => next.content_type = Some((0x80, 0)),
            4 => next.text = Some(Zeroizing::new("Other! \\ref".into())),
            _ => next.anchor = 0,
        }
        assert!(matches!(
            engine.observe(next, &values, &Snapshot::default()),
            Observation::Hidden
        ));
        assert!(engine.ranking.is_none());
    }
}
#[test]
fn unicode_highlights_use_complete_grapheme_byte_ranges_and_labels_strip_controls() {
    let values = [snippet(
        "Public 🙂 Cafe\u{301}\n\u{202e} Label",
        "café-more",
    )];
    let rows = choices(&values, "CAFE").rows();
    let row = &rows[0];
    assert!(!row.name.contains('\n') && !row.name.contains('\u{202e}'));
    assert!(!row.name_matches.is_empty());
    for (start, end) in &row.name_matches {
        assert!(
            row.name.is_char_boundary(*start as usize) && row.name.is_char_boundary(*end as usize)
        );
    }
    assert_eq!(
        highlights("Cafe\u{301}", "café"),
        vec![(0, 1), (1, 2), (2, 3), (3, 6)]
    );
    assert!(highlights("Public", "z").is_empty());
    assert!(bounded(&"🙂".repeat(1000), 512).len() <= 512);
}
#[test]
fn keyboard_commands_accept_only_deliberate_bindings_with_current_presentation() {
    for (symbol, modifiers, expected) in [
        (0xff54, 0, Command::Next),
        (0x6e, 2, Command::Next),
        (0xff52, 0, Command::Previous),
        (0x70, 2, Command::Previous),
        (0xfe20, 1, Command::Previous),
        (0xff09, 1, Command::Previous),
        (0xff09, 0, Command::Accept),
        (0xff0d, 0, Command::Accept),
        (0xff8d, 0, Command::Accept),
        (0xff1b, 0, Command::Dismiss),
    ] {
        assert!(command(symbol, modifiers) == Some(expected));
        assert!(command(symbol, modifiers | 256).is_none());
        assert!(command(symbol, modifiers | 4).is_none());
        assert!(command(symbol, modifiers | 8).is_none());
        assert!(command(symbol, modifiers | 16).is_none());
    }
    assert!(command(0x61, 0).is_none());
    assert!(command(0xff0d, 2).is_none());
}
#[test]
fn escape_suppresses_the_same_trigger_until_it_is_removed_or_the_field_changes() {
    let values = [
        snippet("Public reply", "reply"),
        snippet("Public refund", "refund"),
    ];
    let mut engine = Suggestions::default();
    engine.observe(frame("Public ", 1), &values, &Snapshot::default());
    assert!(matches!(
        engine.observe(frame("Public \\re", 2), &values, &Snapshot::default()),
        Observation::Choices(_)
    ));
    engine.dismiss();
    for (text, serial) in [
        ("Public \\ref", 3),
        ("Public \\refund", 4),
        ("Public \\re", 5),
    ] {
        assert!(matches!(
            engine.observe(frame(text, serial), &values, &Snapshot::default()),
            Observation::Hidden
        ));
    }
    engine.observe(frame("Public ", 6), &values, &Snapshot::default());
    assert!(matches!(
        engine.observe(frame("Public \\re", 7), &values, &Snapshot::default()),
        Observation::Choices(_)
    ));
    engine.dismiss();
    let mut next = frame("Public ", 8);
    next.context.field = 2;
    engine.observe(next, &values, &Snapshot::default());
    let mut next = frame("Public \\re", 9);
    next.context.field = 2;
    assert!(matches!(
        engine.observe(next, &values, &Snapshot::default()),
        Observation::Choices(_)
    ));
}
#[test]
fn ranking_is_frozen_while_editing_and_new_triggers_use_current_usage() {
    let values = [
        snippet("Public alpha", "ready-a"),
        snippet("Public beta", "ready-b"),
    ];
    let mut document = crate::usage::Document::new(1.0);
    document.record(values[0].id, crate::usage::Event::Expansion, None, 1.0);
    let first = document.snapshot(true, false, 1.0);
    let mut engine = Suggestions::default();
    engine.observe(frame("", 1), &values, &first);
    let Observation::Choices(choice) = engine.observe(frame("\\r", 2), &values, &first) else {
        panic!("choices")
    };
    assert_eq!(choice.selected_id(), values[0].id);
    for _ in 0..20 {
        document.record(values[1].id, crate::usage::Event::Expansion, None, 1.0);
    }
    let latest = document.snapshot(true, false, 1.0);
    let Observation::Choices(choice) = engine.observe(frame("\\re", 3), &values, &latest) else {
        panic!("choices")
    };
    assert_eq!(choice.selected_id(), values[0].id);
    engine.observe(frame("", 4), &values, &latest);
    let Observation::Choices(choice) = engine.observe(frame("\\r", 5), &values, &latest) else {
        panic!("choices")
    };
    assert_eq!(choice.selected_id(), values[1].id);
}
#[test]
fn user_selection_reuses_literal_trigger_deletion_and_full_delivery_echo_guards() {
    let temporary = tempfile::tempdir().unwrap();
    let mut library = Library::open(temporary.path().into()).unwrap();
    let mut first = snippet("Public reply", "reply");
    first.content = "Public result 🙂".into();
    library.save(first.clone(), None).unwrap();
    let mut second = snippet("Public refund", "refund");
    second.content = "Other public result".into();
    library.save(second, None).unwrap();
    let ordinary = library.read().unwrap().0;
    let choice = choices(&ordinary, "re");
    let selected = choice.selected_id();
    let plan = choice.choose(&frame("Public \\re", 2), &ordinary).unwrap();
    struct Native {
        called: bool,
        text: String,
    }
    impl Backend for Native {
        fn replace(
            &mut self,
            _: &Frame,
            before: u32,
            text: &str,
            check: &dyn Fn() -> Result<()>,
        ) -> Result<()> {
            check()?;
            assert_eq!(before, 3);
            self.called = true;
            self.text = text.into();
            Ok(())
        }
    }
    let mut backend = Native {
        called: false,
        text: String::new(),
    };
    let next = plan
        .prepare("")
        .unwrap()
        .step(&library, frame("Public \\re", 2), &mut backend, &|| Ok(()))
        .unwrap();
    assert!(backend.called);
    assert_eq!(
        backend.text,
        ordinary.iter().find(|s| s.id == selected).unwrap().content
    );
    let Step::AwaitingEcho(next) = next else {
        panic!("exact echo required");
    };
    let mut echoed = frame(&format!("Public {}", backend.text), 3);
    echoed.change_cause = 0;
    assert!(matches!(
        next.step(&library, echoed, &mut backend, &|| Ok(()))
            .unwrap(),
        Step::Complete { .. }
    ));
}

#[test]
fn accepting_an_empty_trigger_deletes_only_the_backslash_and_requires_fresh_echo() {
    let temporary = tempfile::tempdir().unwrap();
    let mut library = Library::open(temporary.path().into()).unwrap();
    let value = snippet("Public reply", "reply");
    library.save(value.clone(), None).unwrap();
    let ordinary = library.read().unwrap().0;
    let choice = choices(&ordinary, "");
    let delivery = choice
        .choose(&frame(r"Public \", 2), &ordinary)
        .unwrap()
        .prepare("")
        .unwrap();
    struct Receiver;
    impl Backend for Receiver {
        fn replace(
            &mut self,
            _: &Frame,
            before: u32,
            text: &str,
            check: &dyn Fn() -> Result<()>,
        ) -> Result<()> {
            check()?;
            assert_eq!(before, 1);
            assert_eq!(text, "Public fictional body excluded from presentation");
            Ok(())
        }
    }
    let Step::AwaitingEcho(next) = delivery
        .step(&library, frame(r"Public \", 2), &mut Receiver, &|| Ok(()))
        .unwrap()
    else {
        panic!("echo required")
    };
    let mut echo = frame("Public Public fictional body excluded from presentation", 3);
    echo.change_cause = 0;
    assert!(matches!(
        next.step(&library, echo, &mut Receiver, &|| Ok(()))
            .unwrap(),
        Step::Complete { .. }
    ));
}
