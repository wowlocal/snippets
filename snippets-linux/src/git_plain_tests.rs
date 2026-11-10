//! Plain-text library vectors generated from the Apple reference
//! (`tests/reference/git-plain-vectors.swift`, `GitPlainSnippetFile` through
//! `CorePackage`): every rendered file, every envelope read back from an
//! edited or hand-made file, derived ids, file names, tag normalization, and
//! the README and manifest bytes must be identical here.
use crate::{
    git_layout::{self, Mode},
    git_plain,
    wire::Envelope,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::Value;
use uuid::Uuid;

fn vectors() -> Value {
    serde_json::from_str(include_str!("../tests/fixtures/git-plain-v1.json")).unwrap()
}
fn bytes(value: &Value) -> Vec<u8> {
    STANDARD.decode(value.as_str().unwrap()).unwrap()
}
fn text(value: &Value) -> &str {
    value.as_str().unwrap()
}
fn canonical(envelope: &Envelope) -> String {
    String::from_utf8(envelope.encode().unwrap().to_vec()).unwrap()
}

#[test]
fn rendered_files_are_the_apple_bytes() {
    let vectors = vectors();
    let cases = vectors["render"].as_array().unwrap();
    assert!(cases.len() >= 15);
    for case in cases {
        let label = text(&case["label"]);
        let envelope = Envelope::parse(text(&case["envelope"]).as_bytes()).unwrap();
        match &case["markdown"] {
            Value::Null => {
                assert!(git_plain::render(&envelope).is_err(), "{label}");
                assert!(!git_plain::can_render(&envelope), "{label}");
            }
            markdown => {
                let rendered = git_plain::render(&envelope).unwrap();
                assert_eq!(rendered, bytes(markdown), "{label}");
                let (back, edited) = git_plain::read(&rendered, "snippets/x.md", None).unwrap();
                assert!(!edited, "{label}");
                assert_eq!(canonical(&back), text(&case["envelope"]), "{label}");
            }
        }
        let fields = envelope.fields.as_ref().unwrap();
        if fields.name.is_ascii() {
            assert_eq!(
                git_plain::file_name(&fields.name, envelope.id),
                text(&case["fileName"]),
                "{label}"
            );
        }
    }
}

#[test]
fn edited_and_hand_made_files_read_as_the_apple_envelopes() {
    let vectors = vectors();
    let cases = vectors["read"].as_array().unwrap();
    assert!(cases.len() >= 90);
    let mut edited_cases = 0;
    let mut unreadable = 0;
    for case in cases {
        let label = text(&case["label"]);
        let path = text(&case["path"]);
        let file = bytes(&case["file"]);
        assert_eq!(
            git_plain::declared_id(&file, path).to_string(),
            text(&case["declaredID"]),
            "{label}"
        );
        assert_eq!(
            git_plain::has_front_matter(&file),
            case["hasFrontMatter"].as_bool().unwrap(),
            "{label}"
        );
        let Ok((envelope, edited)) = git_plain::read(&file, path, None) else {
            assert!(case["envelope"].is_null(), "{label} should be readable");
            unreadable += 1;
            continue;
        };
        assert_eq!(canonical(&envelope), text(&case["envelope"]), "{label}");
        assert_eq!(edited, case["edited"].as_bool().unwrap(), "{label}");
        if edited {
            edited_cases += 1;
            // The normalized rewrite every device commits is byte-identical.
            match &case["normalized"] {
                Value::Null => assert!(git_plain::render(&envelope).is_err(), "{label}"),
                normalized => {
                    assert_eq!(
                        git_plain::render(&envelope).unwrap(),
                        bytes(normalized),
                        "{label}"
                    )
                }
            }
        }
        assert_eq!(
            canonical(&git_plain::tombstone(&envelope).unwrap()),
            text(&case["tombstone"]),
            "{label}"
        );
        assert_eq!(
            git_plain::parse(&file).and_then(|parsed| parsed.name),
            case["renamedFrom"].as_str().map(str::to_owned),
            "{label}"
        );
    }
    assert!(edited_cases >= 50 && unreadable >= 8);
}

#[test]
fn a_file_is_exact_only_under_the_id_it_declares() {
    let vectors = vectors();
    let cases = vectors["readAssigned"].as_array().unwrap();
    assert_eq!(cases.len(), 13);
    let mut exact = 0;
    for case in cases {
        let label = text(&case["label"]);
        let assigned = Uuid::parse_str(text(&case["assigned"])).unwrap();
        let (envelope, edited) =
            git_plain::read(&bytes(&case["file"]), text(&case["path"]), Some(assigned)).unwrap();
        assert_eq!(
            edited,
            case["edited"].as_bool().unwrap(),
            "{label} as {assigned}"
        );
        exact += usize::from(!edited);
        assert_eq!(envelope.id, assigned, "{label}");
        assert_eq!(canonical(&envelope), text(&case["envelope"]), "{label}");
    }
    assert_eq!(
        exact, 2,
        "only the `sync` id, with an `id` line saying the same, reads as exact"
    );
}

#[test]
fn newer_formats_are_unreadable_never_hand_edits() {
    let vectors = vectors();
    let reads = vectors["read"].as_array().unwrap();
    let read = |label: &str| {
        let case = reads.iter().find(|c| text(&c["label"]) == label).unwrap();
        git_plain::read(&bytes(&case["file"]), text(&case["path"]), None)
    };
    for label in [
        "sync-schema-2",
        "sync-extra-key",
        "sync-newer-schema-partial",
        "sync-newer-superset",
        "sync-newer-superset-bad-types",
        "sync-current-then-newer",
        "sync-newer-crlf",
    ] {
        assert!(read(label).is_err(), "{label} is from a newer Snippets");
    }
    // Short of a newer format it is still a hand edit.
    for label in [
        "sync-schema-float-2",
        "sync-schema-huge",
        "sync-schema-0",
        "sync-extra-key-missing-one",
        "sync-newer-array",
    ] {
        assert!(read(label).unwrap().1, "{label} is a hand edit");
    }
    assert!(!read("sync-newer-then-current").unwrap().1);
}

#[test]
fn identity_comes_from_the_file_alone() {
    let vectors = vectors();
    let reads = vectors["read"].as_array().unwrap();
    let declared = |label: &str| {
        let case = reads.iter().find(|c| text(&c["label"]) == label).unwrap();
        git_plain::declared_id(&bytes(&case["file"]), text(&case["path"])).to_string()
    };
    let original = "617a0002-0000-4000-8000-000000000002";
    let other = "617a0bbb-0000-4000-8000-000000000bbb";
    // The `sync` id wins over the `id` line, parsed or scanned.
    assert_eq!(declared("id-changed"), original);
    assert_eq!(
        declared("sync-id-differs-from-line"),
        "617a0ccc-0000-4000-8000-000000000ccc"
    );
    assert_eq!(declared("unclosed-id-changed"), original);
    assert_eq!(declared("unclosed-crlf-id-changed"), original);
    assert_eq!(declared("unclosed-sync-uppercase-key"), original);
    // An unusable `sync` falls back to the first valid `id` line.
    assert_eq!(declared("unclosed-sync-corrupt"), other);
    assert_eq!(declared("unclosed-invalid-then-valid-id"), other);
    assert_eq!(declared("sync-id-uppercase"), original);
}

#[test]
fn path_derived_ids_and_ascii_file_names_match() {
    let vectors = vectors();
    for case in vectors["derivedID"].as_array().unwrap() {
        assert_eq!(
            git_plain::derived_id(text(&case["path"])).to_string(),
            text(&case["id"])
        );
    }
    let id = Uuid::parse_str("617a0002-0000-4000-8000-000000000002").unwrap();
    let mut ascii = 0;
    for case in vectors["fileName"].as_array().unwrap() {
        let name = text(&case["name"]);
        let ours = git_plain::file_name(name, id);
        if case["ascii"].as_bool().unwrap() {
            ascii += 1;
            assert_eq!(ours, text(&case["fileName"]), "{name:?}");
        } else {
            // Transliteration is cosmetic and may differ; the shape may not.
            assert!(
                ours.ends_with("-617a0002.md") && ours.is_ascii(),
                "{name:?}"
            );
        }
    }
    assert!(ascii >= 12);
    // Apple strips diacritics too; only other scripts' transliteration differs.
    assert_eq!(
        git_plain::file_name("naïve résumé", id),
        "naive-resume-617a0002.md"
    );
}

#[test]
fn hand_typed_tags_normalize_as_on_apple() {
    let vectors = vectors();
    for case in vectors["normalizedTags"].as_array().unwrap() {
        let input: Vec<String> = case["input"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| text(t).to_owned())
            .collect();
        let expected: Vec<&str> = case["normalized"]
            .as_array()
            .unwrap()
            .iter()
            .map(text)
            .collect();
        assert_eq!(git_plain::normalized_tags(&input), expected, "{input:?}");
    }
}

#[test]
fn plain_libraries_have_the_apple_readme_and_manifest() {
    let vectors = vectors();
    assert_eq!(git_layout::PLAIN_README_TEXT, text(&vectors["plainReadme"]));
    assert_eq!(git_layout::README_TEXT, text(&vectors["encryptedReadme"]));
    let dataset = Uuid::parse_str(text(&vectors["manifestDataset"])).unwrap();
    let manifest = git_layout::encode_manifest(dataset, Mode::PlainText);
    assert_eq!(manifest, text(&vectors["plainManifest"]).as_bytes());
    assert_eq!(
        git_layout::decode_manifest(&manifest),
        Ok((dataset, Mode::PlainText))
    );
    // A profile this build does not know is a newer format, never misread.
    let future = String::from_utf8(manifest)
        .unwrap()
        .replace("snippets-plain-v1", "snippets-plain-v9");
    assert_eq!(
        git_layout::decode_manifest(future.as_bytes()),
        Err(git_layout::LayoutError::IncompatibleSchema)
    );
}
