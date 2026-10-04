use chrono::{Local, TimeZone};
use serde_json::{Value, json};
use snippets_linux::{
    desktop::{APP_ID, PasteTarget, theme_css},
    model::{self, Library, Snippet},
    placeholders::resolve_at,
};
use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    process::Command,
};
use tempfile::TempDir;

fn store() -> (TempDir, Library) {
    let directory = tempfile::tempdir().unwrap();
    let library = Library::open(directory.path().into()).unwrap();
    (directory, library)
}
fn add(library: &mut Library, keyword: &str, body: &str) -> Snippet {
    let mut snippet = Snippet::new("Fixture", body);
    snippet.keyword = keyword.into();
    let id = snippet.id;
    library.save(snippet, None).unwrap();
    library.get(id).unwrap()
}
#[test]
fn fresh_library_is_empty_and_does_not_author_data() {
    let (_directory, library) = store();
    assert!(library.snippets.is_empty());
    assert!(!library.path().exists());
    assert_eq!(
        fs::metadata(&library.root).unwrap().permissions().mode() & 0o777,
        0o700
    );
}
#[test]
fn interrupted_backup_import_fences_cli_before_parsing_mixed_primary_files() {
    let directory = tempfile::tempdir().unwrap();
    let backups = directory.path().join("Backups");
    fs::create_dir(&backups).unwrap();
    fs::set_permissions(&backups, fs::Permissions::from_mode(0o700)).unwrap();
    model::atomic_write(
        &backups.join("restore.pending"),
        b"Public opaque pending backup fixture",
    )
    .unwrap();
    model::atomic_write(
        &directory.path().join("snippets.json"),
        b"Public mixed invalid library fixture",
    )
    .unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
        .env("SNIPPETS_SUPPORT_DIR", directory.path())
        .arg("list")
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(result.stdout.is_empty());
    let error = String::from_utf8(result.stderr).unwrap();
    assert!(error.contains("backup import") && !error.contains("Public mixed"));
    assert!(
        fs::read(backups.join("restore.pending")).unwrap()
            == b"Public opaque pending backup fixture"
    );
    assert!(
        fs::read(directory.path().join("snippets.json")).unwrap()
            == b"Public mixed invalid library fixture"
    );
    assert!(!directory.path().join("Sync").exists());
}
#[test]
fn swift_json_round_trip_preserves_dates_flags_tags_and_ids() {
    let record = json!({"id":"32e82e1e-dc55-46ba-a3e5-6cde63eae0b2","name":"Link","keyword":"\\meet", "content":"Привет 🌱\n  spaces  \n",
        "tags":[" work ","WORK","Café","cafe"],"isEnabled":false,"isPinned":true,"createdAt":800000000.125,"updatedAt":800000001.5});
    let values =
        model::decode_library(&serde_json::to_vec(&vec![record.clone()]).unwrap(), false).unwrap();
    let encoded = model::encode_library(&values, true).unwrap();
    assert!(values == model::decode_library(&encoded, false).unwrap());
    let decoded: Value = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded["snippets"][0]["createdAt"], record["createdAt"]);
    assert_eq!(decoded["snippets"][0]["updatedAt"], record["updatedAt"]);
    assert_eq!(decoded["snippets"][0]["tags"], json!(["work", "Café"]));
    assert_eq!(decoded["snippets"][0]["keyword"], "meet");
    assert_eq!(
        decoded["snippets"][0].as_object().unwrap().len(),
        record.as_object().unwrap().len()
    );
}
#[test]
fn legacy_defaults_keep_created_and_updated_in_same_epoch() {
    let snippet = Snippet::decode(json!({"id":"00000000-0000-4000-8000-000000000001","name":"Legacy","keyword":"","content":"Text"})).unwrap();
    assert!(snippet.is_enabled);
    assert!(!snippet.is_pinned);
    assert_eq!(snippet.created_at, snippet.updated_at);
    assert!(snippet.created_at < chrono::Utc::now().timestamp() as f64 - 900_000_000.0);
}
#[test]
fn disk_roundtrip_permissions_and_no_temporary_residue() {
    let (_directory, mut library) = store();
    let snippet = add(&mut library, "unicode", "Привет 🌱\n  Spaces remain  \n");
    let reopened = Library::open(library.root.clone()).unwrap();
    assert!(reopened.snippets == vec![snippet]);
    for name in ["snippets.json", "library.lock"] {
        assert_eq!(
            fs::metadata(library.root.join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    assert!(!fs::read_dir(&library.root).unwrap().any(|entry| {
        entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".snippets-")
    }));
}
#[test]
fn concurrent_instances_merge_unrelated_records_and_refuse_stale_edits() {
    let (_directory, mut library) = store();
    let first = add(&mut library, "first", "Initial");
    let mut other = Library::open(library.root.clone()).unwrap();
    add(&mut other, "other", "Keep this");
    let mut changed = first.clone();
    changed.content = "Updated".into();
    library.save(changed, Some(&first)).unwrap();
    assert_eq!(library.snippets.len(), 2);
    let before = fs::read(library.path()).unwrap();
    assert!(other.save(first.clone(), Some(&first)).is_err());
    assert!(other.delete(&first).is_err());
    assert_eq!(fs::read(library.path()).unwrap(), before);
}
#[test]
fn deleted_record_cannot_be_resurrected_by_stale_editor() {
    let (_directory, mut library) = store();
    let snippet = add(&mut library, "first", "Body");
    library.delete(&snippet).unwrap();
    assert!(library.save(snippet.clone(), Some(&snippet)).is_err());
    assert!(library.snippets.is_empty());
}
#[test]
fn duplicate_keywords_are_folded_and_never_overwrite() {
    let (_directory, mut library) = store();
    add(&mut library, "Café", "One");
    let before = fs::read(library.path()).unwrap();
    let mut snippet = Snippet::new("Other", "Two");
    snippet.keyword = "cafe".into();
    assert!(library.save(snippet, None).is_err());
    assert_eq!(fs::read(library.path()).unwrap(), before);
    assert_eq!(model::folded("Straße"), "strasse");
}
#[test]
fn import_is_atomic_and_skips_duplicate_ids_and_keywords() {
    let (_directory, mut library) = store();
    let first = add(&mut library, "meet", "Original");
    let mut incoming = Snippet::new("New", "New body");
    incoming.keyword = "new".into();
    let mut conflicting = Snippet::new("Conflict", "Must not replace");
    conflicting.keyword = "MEET".into();
    assert_eq!(
        library
            .import(&model::encode_library(&[first, incoming, conflicting], true).unwrap())
            .unwrap(),
        (1, 2)
    );
    let before = fs::read(library.path()).unwrap();
    assert!(library.import(br#"[{"name":"invalid"}]"#).is_err());
    assert_eq!(fs::read(library.path()).unwrap(), before);
}
#[test]
fn raycast_is_only_accepted_in_import_and_converts_grammar() {
    let data = br#"[{"name":"Date","text":"{date \"yyyy-MM-dd\"}","keyword":"!today"}]"#;
    assert!(model::decode_library(data, false).is_err());
    let imported = model::decode_library(data, true).unwrap();
    assert_eq!(imported[0].keyword, "today");
    assert_eq!(imported[0].content, "{date format=\"yyyy-MM-dd\"}");
}
#[test]
fn malformed_file_never_becomes_an_empty_overwrite() {
    let (_directory, mut library) = store();
    add(&mut library, "first", "Body");
    fs::write(library.path(), b"{truncated").unwrap();
    assert!(library.reload().is_err());
    assert!(library.save(Snippet::new("Other", "Body"), None).is_err());
    assert_eq!(fs::read(library.path()).unwrap(), b"{truncated");
}
#[test]
fn strict_types_secure_records_duplicate_ids_and_oversized_bodies_fail_closed() {
    let original = serde_json::to_value(Snippet::new("Name", "Body")).unwrap();
    for (field, value) in [
        ("createdAt", json!(true)),
        ("tags", json!("tag")),
        ("isPinned", json!("yes")),
        ("content", Value::Null),
        ("secure", json!(true)),
        ("content", json!("\0")),
    ] {
        let mut record = original.clone();
        record[field] = value;
        assert!(model::decode_library(&serde_json::to_vec(&vec![record]).unwrap(), false).is_err());
    }
    assert!(
        model::decode_library(
            &serde_json::to_vec(&vec![original.clone(), original]).unwrap(),
            false
        )
        .is_err()
    );
    assert!(
        Snippet::new("Too large", "x".repeat(model::MAX_BODY_BYTES + 1))
            .validate()
            .is_err()
    );
    assert!(model::decode_library(&vec![b' '; model::MAX_FILE_BYTES + 1], false).is_err());
}
#[test]
fn linked_library_lock_and_root_are_refused() {
    let (directory, mut library) = store();
    let outside = directory.path().join("outside");
    fs::write(&outside, b"[]").unwrap();
    symlink(&outside, library.path()).unwrap();
    assert!(library.reload().is_err());
    assert!(library.save(Snippet::new("Name", "Body"), None).is_err());
    assert_eq!(fs::read(&outside).unwrap(), b"[]");
    fs::remove_file(library.path()).unwrap();
    fs::remove_file(library.root.join("library.lock")).unwrap();
    symlink(&outside, library.root.join("library.lock")).unwrap();
    assert!(library.save(Snippet::new("Name", "Body"), None).is_err());
    let root_link = directory.path().join("linked-root");
    symlink(directory.path(), &root_link).unwrap();
    assert!(Library::open(root_link).is_err());
}
#[test]
fn undo_redo_refuse_unrelated_external_changes() {
    let (_directory, mut library) = store();
    let snippet = add(&mut library, "first", "Body");
    library.delete(&snippet).unwrap();
    library.undo(false).unwrap();
    assert!(library.snippets == vec![snippet]);
    library.undo(true).unwrap();
    assert!(library.snippets.is_empty());
    let mut other = Library::open(library.root.clone()).unwrap();
    add(&mut other, "external", "Keep");
    let before = fs::read(library.path()).unwrap();
    assert!(library.undo(false).is_err());
    assert_eq!(fs::read(library.path()).unwrap(), before);
}
#[test]
fn locked_vault_metadata_reserves_keywords_and_ids_even_for_undo() {
    let (_directory, mut library) = store();
    let existing = add(&mut library, "reserved", "Ordinary");
    library.delete(&existing).unwrap();
    let mut vault = snippets_linux::vault::Vault::open(&library).unwrap();
    let generation = vault.generation();
    let prepared =
        snippets_linux::vault::Vault::prepare_create("Public fixture passphrase").unwrap();
    let _recovery = vault.finish_create(&library, prepared, generation).unwrap();
    let mut secure = snippets_linux::vault::Metadata::new();
    secure.id = existing.id;
    secure.keyword = existing.keyword.clone();
    vault
        .save(&library, secure, b"Fictional secret", None)
        .unwrap();
    vault.lock();
    assert!(library.save(existing.clone(), None).is_err());
    let mut duplicate = Snippet::new("Other", "Body");
    duplicate.keyword = "RESERVED".into();
    assert!(library.save(duplicate, None).is_err());
    assert_eq!(
        library
            .import(&model::encode_library(&[existing], false).unwrap())
            .unwrap(),
        (0, 1)
    );
    assert!(library.undo(false).is_err());
}
#[test]
fn search_matches_fuzzy_metadata_contiguous_body_and_all_tags() {
    let mut one = Snippet::new("Project Alpha", "literal-body");
    one.keyword = "alpha".into();
    one.tags = vec!["Work".into(), "Café".into()];
    let mut two = Snippet::new("Second", "other");
    two.tags = vec!["work".into()];
    two.is_pinned = true;
    two.is_enabled = false;
    let values = [one.clone(), two.clone()];
    for query in ["prjal", "teral-b"] {
        assert!(model::search(&values, query, &[], false, false) == vec![one.clone()]);
    }
    assert!(model::search(&values, "ltrlb", &[], false, false).is_empty());
    assert!(
        model::search(&values, "", &["WORK".into(), "cafe".into()], false, false)
            == vec![one.clone()]
    );
    assert!(model::search(&values, "", &[], false, false) == vec![two.clone(), one.clone()]);
    assert!(model::search(&values, "", &[], false, true) == vec![one]);
    assert!(model::search(&values, "", &[], true, false) == vec![two]);
}
#[test]
fn keyword_and_tag_normalization() {
    assert_eq!(model::keyword(" \\hello world "), "hello-world");
    assert_eq!(
        model::normalize_tags(vec!["  two   words ".into(), "TWO WORDS".into(), "".into()]),
        vec!["two words"]
    );
}
#[test]
fn icu_patterns_offsets_and_clipboard_are_one_pass() {
    let now = Local
        .with_ymd_and_hms(2026, 1, 31, 12, 34, 56)
        .single()
        .unwrap();
    assert_eq!(
        resolve_at("{date:yyyy-MM-dd} {time:HH:mm:ss}", "", now),
        "2026-01-31 12:34:56"
    );
    assert_eq!(
        resolve_at("{date offset=\"+1M\" format=\"yyyy-MM-dd\"}", "", now),
        "2026-02-28"
    );
    assert_eq!(
        resolve_at(
            "{date offset=\"+1d -2h\" format=\"yyyy-MM-dd HH:mm\"}",
            "",
            now
        ),
        "2026-02-01 10:34"
    );
    assert_eq!(resolve_at("{clipboard}", "{date}", now), "{date}");
}
#[test]
fn malformed_placeholders_remain_literal() {
    let now = Local::now();
    for value in [
        "{unknown}",
        "{date:path/to.file}",
        "{date format=\"\"}",
        "{date offset=\"1d\"}",
        "{date locale=\"../../file\"}",
        "{date format=\"yyyy\" locale=\"en\"}",
        "{date format=\"yyyy\" format=\"dd\"}",
        "{date bad=\"value\"}",
    ] {
        assert_eq!(resolve_at(value, "", now), value);
    }
}
#[test]
fn theme_parser_rejects_css_injection_and_honors_mode() {
    let (css, dark) =
        theme_css("mode='dark'\naccent='#7aa2f7'\nforeground='red; } window { opacity: 0;'");
    assert_eq!(dark, Some(true));
    assert!(css.contains("@define-color accent_color #7aa2f7;"));
    assert!(!css.contains("opacity"));
    assert_eq!(theme_css("not TOML!"), (String::new(), None));
}
#[test]
fn target_validation_rejects_own_window_invalid_pid_and_lua_injection() {
    for window in [
        json!({"address":"0x123","pid":10,"class":APP_ID}),
        json!({"address":"0x123; malicious","pid":10}),
        json!({}),
        json!({"address":"0x123","pid":-1}),
    ] {
        assert!(PasteTarget::from_window(&window).is_none());
    }
    assert!(
        PasteTarget::from_window(&json!({"address":"0x123","pid":10,"tags":["terminal*"]}))
            .is_some()
    );
}
#[test]
fn cli_writers_in_separate_processes_keep_all_records() {
    let (directory, mut library) = store();
    let mut children: Vec<_> = (0..8)
        .map(|index| {
            Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
                .env("SNIPPETS_SUPPORT_DIR", directory.path())
                .args([
                    "add",
                    "--keyword",
                    &format!("record-{index}"),
                    "--content",
                    "Fixture",
                ])
                .stdout(std::process::Stdio::null())
                .spawn()
                .unwrap()
        })
        .collect();
    for child in &mut children {
        assert!(child.wait().unwrap().success());
    }
    library.reload().unwrap();
    assert_eq!(library.snippets.len(), 8);
    let result = Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
        .env("SNIPPETS_SUPPORT_DIR", directory.path())
        .args(["search", "record-3"])
        .output()
        .unwrap();
    assert!(result.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&result.stdout)
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn cli_exposes_only_secure_metadata_and_refuses_secure_mutations() {
    let (directory, mut library) = store();
    add(&mut library, "ordinary", "Public fixture");
    let fixture: Value = serde_json::from_str(include_str!("fixtures/crypto-v1.json")).unwrap();
    let document = &fixture["document"];
    let vault_dir = directory.path().join("Vault");
    fs::create_dir(&vault_dir).unwrap();
    let path = vault_dir.join("vault.json");
    model::atomic_write(&path, &serde_json::to_vec(document).unwrap()).unwrap();
    let keyword = document["records"][0]["keyword"].as_str().unwrap();
    let run = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
            .env("SNIPPETS_SUPPORT_DIR", directory.path())
            .args(args)
            .output()
            .unwrap()
    };
    let result = run(&["list"]);
    assert!(result.status.success());
    let list: Value = serde_json::from_slice(&result.stdout).unwrap();
    let secure = list
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["keyword"] == keyword)
        .unwrap();
    assert!(secure["content"] == "" && secure.as_object().unwrap().len() == 9);
    let result = run(&["search", keyword]);
    assert!(result.status.success());
    let search: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert!(search[0]["secure"] == true && search[0]["snippet"]["content"] == "");
    assert!(run(&["tags"]).status.success());
    let before_vault = fs::read(&path).unwrap();
    let before_library = fs::read(library.path()).unwrap();
    for args in [
        vec!["get", keyword],
        vec!["delete", keyword],
        vec!["update", keyword, "--content", "Must not replace"],
        vec!["add", "--keyword", keyword, "--content", "Must not collide"],
    ] {
        let result = run(&args);
        assert!(!result.status.success() && result.stdout.is_empty());
        assert!(fs::read(&path).unwrap() == before_vault);
        assert!(fs::read(library.path()).unwrap() == before_library);
    }
    fs::write(&path, b"{truncated").unwrap();
    assert!(!run(&["add", "--keyword", "another"]).status.success());
    assert!(fs::read(library.path()).unwrap() == before_library);
    assert!(fs::read(&path).unwrap() == b"{truncated");
}

#[test]
fn secure_cli_checks_app_before_private_input_and_does_not_seed_state_without_it() {
    let temporary = tempfile::tempdir().unwrap();
    let runtime = temporary.path().join("runtime");
    fs::create_dir(&runtime).unwrap();
    fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
    let support = temporary.path().join("absent-support");
    for args in [
        vec!["reveal", "public-absent"],
        vec![
            "add",
            "--secure",
            "--keyword",
            "public",
            "--content-file",
            "/public/absent-file",
        ],
        vec![
            "add",
            "--secure",
            "--keyword",
            "public",
            "--content-fd",
            "99",
        ],
        vec!["add", "--secure", "--keyword", "public", "--content", "-"],
        vec!["add", "--secure", "--keyword", "public", "--prompt"],
    ] {
        let result = Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
            .env("SNIPPETS_SUPPORT_DIR", &support)
            .env("XDG_RUNTIME_DIR", &runtime)
            .args(args)
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        assert_eq!(result.status.code(), Some(3));
        assert!(result.stdout.is_empty());
        assert!(!support.exists());
        assert!(!runtime.join("snippets-control").exists());
    }
    let result = Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
        .env("SNIPPETS_SUPPORT_DIR", &support)
        .env("XDG_RUNTIME_DIR", &runtime)
        .arg("secure-status")
        .output()
        .unwrap();
    assert!(result.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&result.stdout).unwrap(),
        json!({"secureCount":0,"appAvailable":false,"unlocked":null})
    );
    assert!(!support.exists());
}

#[test]
fn secure_cli_rejects_body_arguments_and_updates_without_echoing_or_authoring_them() {
    let temporary = tempfile::tempdir().unwrap();
    let support = temporary.path().join("absent-support");
    for args in [
        vec![
            "add",
            "--secure",
            "--keyword",
            "public",
            "--content",
            "Public fictional argument body",
        ],
        vec!["add", "--secure", "--keyword", "public"],
        vec![
            "update",
            "public",
            "--secure",
            "--content",
            "Public fictional argument body",
        ],
    ] {
        let result = Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
            .env("SNIPPETS_SUPPORT_DIR", &support)
            .args(args)
            .output()
            .unwrap();
        assert_eq!(result.status.code(), Some(2));
        assert!(result.stdout.is_empty());
        assert!(
            !String::from_utf8_lossy(&result.stderr).contains("Public fictional argument body")
        );
        assert!(!support.exists());
    }
}

#[test]
fn offline_secure_status_returns_only_metadata_and_never_claims_an_app_unlock() {
    let (directory, _library) = store();
    let runtime = tempfile::tempdir().unwrap();
    fs::set_permissions(runtime.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let fixture: Value = serde_json::from_str(include_str!("fixtures/crypto-v1.json")).unwrap();
    fs::create_dir(directory.path().join("Vault")).unwrap();
    let path = directory.path().join("Vault/vault.json");
    let bytes = serde_json::to_vec(&fixture["document"]).unwrap();
    model::atomic_write(&path, &bytes).unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
        .env("SNIPPETS_SUPPORT_DIR", directory.path())
        .env("XDG_RUNTIME_DIR", runtime.path())
        .arg("secure-status")
        .output()
        .unwrap();
    assert!(result.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&result.stdout).unwrap(),
        json!({"secureCount":1,"appAvailable":false,"unlocked":null})
    );
    assert_eq!(fs::read(path).unwrap(), bytes);
    assert!(!directory.path().join("Sync").exists());
    assert!(!directory.path().join("Usage").exists());
    let linked = runtime.path().join("public-linked-root");
    symlink(directory.path(), &linked).unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_snippets-cli"))
        .env("SNIPPETS_SUPPORT_DIR", &linked)
        .env("XDG_RUNTIME_DIR", runtime.path())
        .arg("secure-status")
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(1));
    assert!(result.stdout.is_empty());
}
