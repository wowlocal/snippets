use super::*;
fn snippet(keyword: &str, body: &str) -> Snippet {
    let mut snippet = Snippet::new("Public inline fixture", body);
    snippet.keyword = keyword.into();
    snippet
}
fn frame(text: &str, serial: u32, cause: u32) -> Frame {
    Frame::from_protocol(
        Context { field: 1, serial },
        true,
        Some(Zeroizing::new(text.into())),
        (text.len() as u32, text.len() as u32),
        Some((0, 0)),
        cause,
    )
}
fn plan(ordinary: &[Snippet], query: &str) -> Plan {
    let mut engine = Engine::default();
    assert!(engine.observe(frame("\\", 1, 1), ordinary).is_none());
    engine
        .observe(frame(&format!("\\{query}"), 2, 1), ordinary)
        .expect("public confirmed query")
}

#[test]
fn shifted_utf8_windows_preserve_a_literal_trigger_and_reject_changed_context() {
    let ordinary = [snippet("café", "Public body")];
    let prefix = "Public context 🙂中é ".repeat(400);
    for changed in 0..6 {
        let mut field = Field::new("caf");
        field.text.insert_str(0, &prefix);
        field.cursor += prefix.len();
        field.text.push_str(&"Public tail ".repeat(150));
        let mut engine = Engine::default();
        let old = field.observation(1);
        assert!(engine.observe(old, &ordinary).is_none());
        field.text.insert(field.cursor, 'é');
        field.cursor += 'é'.len_utf8();
        field.serial += 1;
        match changed {
            0 => (),
            1 => {
                field
                    .text
                    .replace_range(field.cursor - 5..field.cursor, "CAFÉ");
            }
            2 => {
                let mut at = field.cursor - 100;
                while !field.text.is_char_boundary(at) {
                    at += 1;
                }
                field.text.insert(at, '!');
                field.cursor += 1;
            }
            3 => {
                field.text.insert(field.cursor + 100, '!');
            }
            4 => {
                field.cursor -= 2;
            }
            5 => (),
            _ => unreachable!(),
        }
        let mut new = field.observation(1);
        if changed == 5 {
            // An aggressively clipped, short prefix cannot prove continuation.
            let text = new.text.as_mut().unwrap();
            let start = new.cursor - 10;
            let mut start = start;
            while !text.is_char_boundary(start) {
                start += 1;
            }
            text.drain(..start);
            new.cursor -= start;
            new.anchor = new.cursor;
        }
        assert_eq!(engine.observe(new, &ordinary).is_some(), changed == 0);
    }
}

#[test]
fn exact_match_folds_unicode_and_refuses_duplicates_or_enabled_longer_prefixes() {
    for (keywords, enabled, allowed) in [
        (vec!["café"], vec![true], true),
        (vec!["café", "CAFÉ"], vec![true, true], false),
        (vec!["café", "cafe-more"], vec![true, true], false),
        (vec!["café", "cafe-more"], vec![true, false], true),
        (vec!["café"], vec![false], false),
        (vec!["cafe-more"], vec![true], false),
    ] {
        let ordinary: Vec<_> = keywords
            .into_iter()
            .zip(enabled)
            .map(|(keyword, enabled)| {
                let mut value = snippet(keyword, "Public body");
                value.is_enabled = enabled;
                value
            })
            .collect();
        let mut engine = Engine::default();
        assert!(engine.observe(frame("中 \\CAF", 1, 1), &ordinary).is_none());
        assert_eq!(
            engine
                .observe(frame("中 \\CAFÉ", 2, 1), &ordinary)
                .is_some(),
            allowed,
        );
    }
}

#[test]
fn activation_edits_selection_sensitive_unknown_and_malformed_frames_cannot_authorize() {
    let ordinary = vec![snippet("cafe", "Public body")];
    for changed in 0..13 {
        let mut engine = Engine::default();
        assert!(engine.observe(frame("\\caf", 1, 1), &ordinary).is_none());
        let mut next = frame("\\cafe", 2, 1);
        match changed {
            0 => next.active = false,
            1 => next.context.field = 2,
            2 => next.anchor = 0,
            3 => next.content_type = None,
            4 => next.content_type = Some((0x40, 0)),
            5 => next.content_type = Some((0x80, 0)),
            6 => next.content_type = Some((0, 8)),
            7 => next.content_type = Some((0, 9)),
            8 => next.content_type = Some((0x8000, 0)),
            9 => next.content_type = Some((0, 14)),
            10 => next.change_cause = 2,
            11 => next.context.serial = 1,
            12 => next.content_type = Some((0x1000, 0)),
            _ => unreachable!(),
        }
        assert!(engine.observe(next, &ordinary).is_none());
    }
    for value in ["\\cafe ", "\\ca fe", "\\ca\nfe", "\\cafe\0"] {
        let mut engine = Engine::default();
        engine.observe(frame("\\", 1, 1), &ordinary);
        assert!(engine.observe(frame(value, 2, 1), &ordinary).is_none());
    }
    for (text, cursor) in [("é\\cafe", 1), ("\\cafe", 500)] {
        let mut engine = Engine::default();
        let mut invalid = frame(text, 1, 1);
        invalid.cursor = cursor;
        invalid.anchor = cursor;
        assert!(engine.observe(invalid, &ordinary).is_none());
        assert!(engine.observe(frame("\\cafe", 2, 1), &ordinary).is_none());
    }
    let mut engine = Engine::default();
    engine.observe(frame("\\cafe", 1, 1), &ordinary);
    assert!(engine.observe(frame("\\cafe", 2, 1), &ordinary).is_none());
    engine.reset();
    assert!(engine.observe(frame("\\cafe", 3, 1), &ordinary).is_none());
}

#[test]
fn committed_keyboard_appends_support_both_known_causes_and_reset_makes_echo_a_baseline() {
    let ordinary = vec![
        snippet("cafe", "\\cafe \\other"),
        snippet("other", "Public body"),
    ];
    for cause in [0, 1] {
        let mut engine = Engine::default();
        engine.observe(frame("\\caf", 1, 1), &ordinary);
        let mut appended = frame("\\cafe", 2, 1);
        appended.change_cause = cause;
        assert!(engine.observe(appended, &ordinary).is_some());
        engine.reset();
        let mut echo = frame("\\cafe \\other", 3, 1);
        echo.change_cause = 0;
        assert!(engine.observe(echo, &ordinary).is_none());
    }
}

struct Field {
    text: String,
    cursor: usize,
    serial: u32,
    calls: usize,
    deletes: Vec<u32>,
}
impl Field {
    fn new(query: &str) -> Self {
        Self {
            text: format!("\\{query}"),
            cursor: query.len() + 1,
            serial: 2,
            calls: 0,
            deletes: vec![],
        }
    }
    fn observation(&self, cause: u32) -> Frame {
        // A fictional field clips long surrounding text like a real protocol
        // client, while keeping byte indices and cursor boundaries valid.
        let mut start = self.cursor.saturating_sub(3000);
        while !self.text.is_char_boundary(start) {
            start += 1;
        }
        let mut end = (self.cursor + 1000).min(self.text.len());
        while !self.text.is_char_boundary(end) {
            end -= 1;
        }
        Frame::from_protocol(
            Context {
                field: 1,
                serial: self.serial,
            },
            true,
            Some(Zeroizing::new(self.text[start..end].into())),
            ((self.cursor - start) as u32, (self.cursor - start) as u32),
            Some((0, 0)),
            cause,
        )
    }
}
impl Backend for Field {
    fn replace(
        &mut self,
        expected: &Frame,
        delete: u32,
        text: &str,
        check: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        check()?;
        assert!(expected.context == self.observation(0).context);
        assert!(text.len() <= MAX_SURROUNDING_BYTES);
        let start = self.cursor - delete as usize;
        assert!(self.text.is_char_boundary(start));
        self.text.replace_range(start..self.cursor, text);
        self.cursor = start + text.len();
        self.serial = self.serial.wrapping_add(1);
        self.calls += 1;
        self.deletes.push(delete);
        Ok(())
    }
}
fn saved(body: &str) -> (tempfile::TempDir, Library, Snippet) {
    let temporary = tempfile::tempdir().unwrap();
    let mut library = Library::open(temporary.path().join("data")).unwrap();
    let value = snippet("café", body);
    library.save(value.clone(), None).unwrap();
    let saved = library.get(value.id).unwrap();
    (temporary, library, saved)
}

#[test]
fn delivery_chunks_full_size_unicode_and_deletes_exact_utf8_bytes_once() {
    let mut body = "🙂中é\n\t".repeat(20_000);
    body.push_str(&"X".repeat(model::MAX_BODY_BYTES - body.len()));
    assert_eq!(body.len(), model::MAX_BODY_BYTES);
    let (_temporary, library, _) = saved(&body);
    let mut field = Field::new("CAFÉ");
    field.text.push_str(" Public tail");
    // The reviewed suffix must be present in both original observations.
    let ordinary = library.read().unwrap().0;
    let mut engine = Engine::default();
    let mut initial = frame("\\ Public tail", 1, 1);
    initial.cursor = 1;
    initial.anchor = 1;
    engine.observe(initial, &ordinary);
    let mut delivery = engine
        .observe(field.observation(1), &ordinary)
        .unwrap()
        .prepare("")
        .unwrap();
    loop {
        let cause = if field.calls == 0 { 1 } else { 0 };
        match delivery
            .step(&library, field.observation(cause), &mut field, &|| Ok(()))
            .unwrap()
        {
            Step::AwaitingEcho(next) => delivery = *next,
            Step::Complete { inserted_bytes } => {
                assert_eq!(inserted_bytes, body.len());
                break;
            }
        }
    }
    assert_eq!(field.text, body + " Public tail");
    assert!(field.calls > 200);
    assert_eq!(field.deletes[0], "\\CAFÉ".len() as u32);
    assert!(field.deletes[1..].iter().all(|count| *count == 0));
}

#[test]
fn fresh_saved_state_busy_lock_and_cancellation_refuse_before_any_input() {
    for changed in 0..4 {
        let (_temporary, mut library, value) = saved("Public body");
        let delivery = plan(std::slice::from_ref(&value), "cafe")
            .prepare("")
            .unwrap();
        let mut guard = None;
        match changed {
            0 => {
                let mut edited = value.clone();
                edited.content = "Public changed body".into();
                library.save(edited, Some(&value)).unwrap();
            }
            1 => {
                library.save(snippet("cafe-more", "Other"), None).unwrap();
            }
            2 => guard = Some(library.lock().unwrap()),
            3 => (),
            _ => unreachable!(),
        }
        let mut field = Field::new("cafe");
        assert!(
            delivery
                .step(&library, field.observation(1), &mut field, &|| {
                    if changed == 3 { Err(CHANGED) } else { Ok(()) }
                })
                .is_err()
        );
        assert_eq!(field.calls, 0);
        assert_eq!(field.text, "\\cafe");
        drop(guard);
    }
}

#[test]
fn no_next_chunk_without_exact_fresh_echo_or_after_host_edits_and_focus_change() {
    for changed in 0..6 {
        let (_temporary, library, value) = saved(&"X".repeat(4000));
        let delivery = plan(&[value], "cafe").prepare("").unwrap();
        let mut field = Field::new("cafe");
        let Step::AwaitingEcho(delivery) = delivery
            .step(&library, field.observation(1), &mut field, &|| Ok(()))
            .unwrap()
        else {
            panic!("first public chunk requires acceptance");
        };
        let mut echo = field.observation(0);
        match changed {
            0 => echo.context.field += 1,
            1 => echo.context.serial = 2,
            2 => echo.change_cause = 1,
            3 => echo.text = Some(Zeroizing::new("Wrong".into())),
            4 => echo.anchor = 0,
            5 => echo.content_type = Some((0, 8)),
            _ => unreachable!(),
        }
        assert!(
            delivery
                .step(&library, echo, &mut field, &|| Ok(()))
                .is_err()
        );
        assert_eq!(field.calls, 1);
        assert_eq!(field.text.len(), CHUNK_BYTES);
    }
}

#[test]
fn empty_body_still_requires_a_confirmed_deletion_echo_and_placeholders_are_one_pass() {
    for (template, clipboard, expected) in [
        ("", "", ""),
        ("{clipboard}", "Public {date:yyyy}", "Public {date:yyyy}"),
    ] {
        let (_temporary, library, value) = saved(template);
        let plan = plan(&[value], "cafe");
        assert_eq!(plan.needs_clipboard(), template.contains("{clipboard}"));
        let delivery = plan.prepare(clipboard).unwrap();
        let mut field = Field::new("cafe");
        let Step::AwaitingEcho(delivery) = delivery
            .step(&library, field.observation(1), &mut field, &|| Ok(()))
            .unwrap()
        else {
            panic!("replacement needs echo");
        };
        assert_eq!(field.text, expected);
        assert!(matches!(
            delivery
                .step(&library, field.observation(0), &mut field, &|| Ok(()))
                .unwrap(),
            Step::Complete { .. }
        ));
        assert_eq!(field.calls, 1);
    }
}

#[test]
fn protocol_and_render_limits_refuse_oversize_input_without_a_backend() {
    let too_long = snippet("cafe", &"X".repeat(model::MAX_BODY_BYTES + 1));
    assert!(plan(&[too_long], "cafe").prepare("").is_err());
    assert!(
        plan(&[snippet("cafe", "{clipboard}")], "cafe")
            .prepare(&"X".repeat(model::MAX_BODY_BYTES + 1))
            .is_err()
    );
    let mut engine = Engine::default();
    let ordinary = [snippet("cafe", "Public")];
    engine.observe(frame("\\caf", 1, 1), &ordinary);
    assert!(
        engine
            .observe(
                frame(
                    &format!("{}\\cafe", "X".repeat(MAX_SURROUNDING_BYTES)),
                    2,
                    1
                ),
                &ordinary,
            )
            .is_none()
    );
    let query = "X".repeat(121);
    let ordinary = [snippet(&query, "Public")];
    let mut engine = Engine::default();
    engine.observe(frame("\\", 1, 1), &ordinary);
    assert!(
        engine
            .observe(frame(&format!("\\{query}"), 2, 1), &ordinary)
            .is_none()
    );
    // Folding is only for keyword matching; it cannot authenticate a host edit.
    let mut engine = Engine::default();
    let ordinary = [snippet("cafe", "Public")];
    engine.observe(frame("\\caf", 1, 1), &ordinary);
    assert!(engine.observe(frame("\\CAFÉ", 2, 1), &ordinary).is_none());
}

#[test]
fn saved_file_changes_and_aliases_stop_delivery_beside_an_unchanged_host_echo() {
    for changed in 0..4 {
        let (temporary, mut library, value) = saved(&"X".repeat(4000));
        let delivery = plan(std::slice::from_ref(&value), "cafe")
            .prepare("")
            .unwrap();
        let mut field = Field::new("cafe");
        if changed == 0 {
            std::fs::hard_link(library.path(), temporary.path().join("Public alias")).unwrap();
            assert!(
                delivery
                    .step(&library, field.observation(1), &mut field, &|| Ok(()))
                    .is_err()
            );
            assert_eq!(field.calls, 0);
            continue;
        }
        let Step::AwaitingEcho(delivery) = delivery
            .step(&library, field.observation(1), &mut field, &|| Ok(()))
            .unwrap()
        else {
            panic!("public first chunk requires echo");
        };
        match changed {
            1 => {
                library
                    .save(snippet("other", "Public other body"), None)
                    .unwrap();
            }
            2 => {
                let bytes = std::fs::read(library.path()).unwrap();
                let replacement = temporary.path().join("Public replacement");
                std::fs::write(&replacement, bytes).unwrap();
                std::fs::rename(replacement, library.path()).unwrap();
            }
            3 => {
                std::fs::remove_file(library.path()).unwrap();
            }
            _ => unreachable!(),
        }
        assert!(
            delivery
                .step(&library, field.observation(0), &mut field, &|| Ok(()))
                .is_err()
        );
        assert_eq!(field.calls, 1);
        assert_eq!(field.text.len(), CHUNK_BYTES);
    }
}
