use super::*;
use std::os::unix::fs::{PermissionsExt, symlink};

fn fixture() -> (tempfile::TempDir, PathBuf) {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("Public isolated library");
    fs::create_dir(&root).unwrap();
    (temp, root)
}
fn ready(handle: &Handle) {
    let start = Instant::now();
    while !handle.status().ready {
        assert!(start.elapsed() < Duration::from_secs(3));
        thread::sleep(Duration::from_millis(5));
    }
}
fn flush(handle: &Handle) -> Result<()> {
    handle.flush().recv_timeout(Duration::from_secs(3)).unwrap()
}
fn wait_edit(handle: &Handle) {
    let start = Instant::now();
    while handle.status().busy {
        assert!(start.elapsed() < Duration::from_secs(3));
        thread::sleep(Duration::from_millis(5));
    }
}
fn private(path: &Path, bytes: &[u8]) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}

#[test]
fn disabled_usage_makes_no_filesystem_access_even_for_invalid_root_or_commands() {
    let (temp, root) = fixture();
    let link = temp.path().join("Public linked root");
    symlink(&root, &link).unwrap();
    let handle = Handle::start_with_disabled(link, true);
    assert!(!handle.status().writable);
    handle.record(Uuid::from_u128(1), Event::Copy, Some("re"));
    assert!(handle.preferences(false, false).is_err());
    assert!(handle.reset(true, true).is_err());
    flush(&handle).unwrap();
    assert!(!root.join("Usage").exists());
}

#[test]
fn worker_debounces_coalesces_by_id_and_kind_and_never_changes_library_or_sync() {
    let (_temp, root) = fixture();
    private(&root.join("snippets.json"), b"[]");
    let handle = Handle::start_with_disabled(root.clone(), false);
    ready(&handle);
    assert!(handle.status().ranking && handle.status().memory);
    let id = Uuid::from_u128(1);
    for _ in 0..20 {
        handle.record(id, Event::Copy, Some("re"));
    }
    handle.record(id, Event::Paste, Some("re"));
    let start = Instant::now();
    while handle.status().records == 0 {
        assert!(start.elapsed() < Duration::from_secs(2));
        thread::sleep(Duration::from_millis(5));
    }
    assert!(!root.join("Usage/usage.json").exists());
    flush(&handle).unwrap();
    let directory = root.join("Usage");
    let (doc, _) = load(&directory).unwrap();
    let value = serde_json::to_value(&doc).unwrap();
    assert_eq!(value["w"][id.to_string()]["n"], 2);
    assert!((value["w"][id.to_string()]["s"].as_f64().unwrap() - 1.25).abs() < 0.00001);
    assert_eq!(fs::read(root.join("snippets.json")).unwrap(), b"[]");
    assert!(!root.join("Sync").exists());
    assert!(!root.join("Vault").exists());
    assert!(!directory.join("preferences.json").exists());
    assert_eq!(
        fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
        0o700
    );
    for path in ["usage.json", "usage.lock"] {
        assert_eq!(
            fs::metadata(directory.join(path))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    // A fresh process sees the same local history.
    let reopened = Handle::start_with_disabled(root, false);
    ready(&reopened);
    assert_eq!(reopened.status().records, 1);
}

#[test]
fn alternating_deliberate_choices_are_not_coalesced_and_the_last_correction_wins() {
    let (_temp, root) = fixture();
    let handle = Handle::start_with_disabled(root.clone(), false);
    ready(&handle);
    let a = Uuid::from_u128(1);
    let b = Uuid::from_u128(2);
    for id in [a, b, a] {
        handle.record(id, Event::Paste, Some("re"));
    }
    flush(&handle).unwrap();
    let value = serde_json::to_value(load(&root.join("Usage")).unwrap().0).unwrap();
    assert_eq!(value["w"][a.to_string()]["n"], 2);
    assert_eq!(value["w"][b.to_string()]["n"], 1);
    assert!(
        value["b"]["re"][a.to_string()].as_f64().unwrap()
            > value["b"]["re"][b.to_string()].as_f64().unwrap()
    );
}

#[test]
fn memory_disable_and_independent_resets_are_durable_and_stale_writers_cannot_resurrect_prefixes() {
    let (_temp, root) = fixture();
    let handle = Handle::start_with_disabled(root.clone(), false);
    ready(&handle);
    let id = Uuid::from_u128(1);
    handle.record(id, Event::Paste, Some("ré"));
    flush(&handle).unwrap();
    let directory = root.join("Usage");
    let stale = load(&directory).unwrap().0;
    handle.preferences(false, false).unwrap();
    wait_edit(&handle);
    flush(&handle).unwrap();
    assert!(!handle.status().ranking && !handle.status().memory);
    assert_eq!(handle.status().prefixes, 0);
    assert_eq!(handle.status().records, 1);
    save(&directory, &stale, None, None, None).unwrap();
    assert_eq!(load(&directory).unwrap().0.counts(), (1, 0));
    handle.record(Uuid::from_u128(2), Event::Copy, Some("re"));
    flush(&handle).unwrap();
    assert_eq!(handle.status().prefixes, 0);
    handle.preferences(true, true).unwrap();
    wait_edit(&handle);
    handle.record(Uuid::from_u128(3), Event::Expansion, Some("re"));
    flush(&handle).unwrap();
    handle.reset(true, false).unwrap();
    wait_edit(&handle);
    assert_eq!(handle.status().records, 0);
    assert_eq!(handle.status().prefixes, 1);
    handle.reset(false, true).unwrap();
    wait_edit(&handle);
    flush(&handle).unwrap();
    assert_eq!(load(&directory).unwrap().0.counts(), (0, 0));
    assert_eq!(
        save(&directory, &stale, None, None, None)
            .unwrap()
            .0
            .counts(),
        (0, 0)
    );
}

#[test]
fn learned_correction_survives_flush_and_reopen_instead_of_rejoining_unchanged_ancestor() {
    let (_temp, root) = fixture();
    let directory = private_directory(&root).unwrap();
    let now = now();
    let a = Uuid::from_u128(1);
    let b = Uuid::from_u128(2);
    let mut doc = Document::new(now);
    for _ in 0..50 {
        doc.record(a, Event::Paste, Some("re"), now);
    }
    let (baseline, _) = save(&directory, &doc, None, None, None).unwrap();
    let mut corrected = baseline.clone();
    corrected.record(b, Event::Paste, Some("re"), now);
    save(&directory, &corrected, Some(&baseline), None, None).unwrap();
    let reopened = load(&directory).unwrap().0;
    let a_weight = serde_json::to_value(&reopened).unwrap()["b"]["re"][a.to_string()]
        .as_f64()
        .unwrap();
    let b_weight = serde_json::to_value(&reopened).unwrap()["b"]["re"][b.to_string()]
        .as_f64()
        .unwrap();
    assert!(b_weight > a_weight);
}

#[test]
fn concurrent_writers_merge_under_separate_lock_without_summing_or_losing_new_ids() {
    let (_temp, root) = fixture();
    let directory = private_directory(&root).unwrap();
    let baseline = Document::new(now());
    let mut first = baseline.clone();
    let mut second = baseline.clone();
    first.record(Uuid::from_u128(1), Event::Copy, Some("re"), now());
    second.record(Uuid::from_u128(2), Event::Paste, Some("re"), now());
    let first_dir = directory.clone();
    let first_baseline = baseline.clone();
    let first_copy = first.clone();
    let a = thread::spawn(move || {
        save(&first_dir, &first_copy, Some(&first_baseline), None, None).unwrap()
    });
    let b = thread::spawn(move || save(&directory, &second, Some(&baseline), None, None).unwrap());
    a.join().unwrap();
    b.join().unwrap();
    let directory = root.join("Usage");
    assert_eq!(load(&directory).unwrap().0.counts(), (2, 1));
    save(&directory, &first, None, None, None).unwrap();
    let value = serde_json::to_value(load(&directory).unwrap().0).unwrap();
    assert_eq!(value["w"][Uuid::from_u128(1).to_string()]["n"], 1);
}

#[test]
fn future_corrupt_linked_oversize_or_public_files_are_preserved_at_start_and_flush() {
    let invalid = [
        br#"{"v":2,"futureShape":[]}"#.to_vec(),
        b"torn JSON".to_vec(),
        vec![b' '; LIMIT + 1],
    ];
    for bytes in invalid {
        let (_temp, root) = fixture();
        let directory = private_directory(&root).unwrap();
        private(&directory.join("usage.json"), &bytes);
        let handle = Handle::start_with_disabled(root, false);
        ready(&handle);
        assert!(!handle.status().writable);
        handle.record(Uuid::from_u128(1), Event::Copy, Some("re"));
        assert!(handle.reset(true, true).is_err());
        assert_eq!(fs::read(directory.join("usage.json")).unwrap(), bytes);
    }
    for mode in 0..4 {
        let (_temp, root) = fixture();
        let directory = private_directory(&root).unwrap();
        let outside = root.join("Public sentinel");
        let bytes = serde_json::to_vec(&Document::new(now())).unwrap();
        private(&outside, &bytes);
        let path = directory.join("usage.json");
        match mode {
            0 => symlink(&outside, &path).unwrap(),
            1 => fs::hard_link(&outside, &path).unwrap(),
            2 => {
                private(&path, &bytes);
                fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
            }
            _ => {
                fs::remove_dir(&directory).unwrap();
                symlink(&root, &directory).unwrap();
            }
        }
        assert!(private_directory(&root).and_then(|d| load(&d)).is_err());
        assert_eq!(fs::read(&outside).unwrap(), bytes);
    }
    // A file replaced by a new application after launch is protected at the last write boundary.
    let (_temp, root) = fixture();
    let handle = Handle::start_with_disabled(root.clone(), false);
    ready(&handle);
    private(
        &root.join("Usage/usage.json"),
        br#"{"v":2,"futureShape":[]}"#,
    );
    handle.record(Uuid::from_u128(1), Event::Copy, Some("re"));
    assert!(flush(&handle).is_err());
    assert!(!handle.status().writable);
    assert!(handle.reset(true, true).is_err());
    assert_eq!(
        fs::read(root.join("Usage/usage.json")).unwrap(),
        br#"{"v":2,"futureShape":[]}"#
    );
}

#[test]
fn failed_flush_remains_visible_through_new_events_until_a_successful_retry() {
    let (_temp, root) = fixture();
    let handle = Handle::start_with_disabled(root.clone(), false);
    ready(&handle);
    handle.record(Uuid::from_u128(1), Event::Copy, None);
    flush(&handle).unwrap();
    let held = lock(&root.join("Usage")).unwrap();
    handle.record(Uuid::from_u128(2), Event::Copy, None);
    assert_eq!(flush(&handle), Err(BUSY));
    assert_eq!(handle.status().error, Some(BUSY));
    handle.record(Uuid::from_u128(3), Event::Copy, None);
    let start = Instant::now();
    while handle.status().records != 3 {
        assert!(start.elapsed() < Duration::from_secs(2));
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(handle.status().error, Some(BUSY));
    drop(held);
    flush(&handle).unwrap();
    assert!(handle.status().error.is_none());
}

#[test]
fn settings_defaults_are_on_and_unrecognized_settings_are_not_replaced() {
    for bytes in [
        br#"{"schema":1}"#.as_slice(),
        br#"{"schema":1,"ranking":true,"memory":true}"#,
    ] {
        let prefs: Preferences = serde_json::from_slice(bytes).unwrap();
        assert!(prefs.ranking && prefs.memory);
    }
    for bytes in [
        br#"{"schema":2,"ranking":true,"memory":true}"#.as_slice(),
        br#"{"schema":1,"body":"forbidden"}"#,
    ] {
        let (_temp, root) = fixture();
        let directory = private_directory(&root).unwrap();
        private(&directory.join("preferences.json"), bytes);
        let handle = Handle::start_with_disabled(root, false);
        ready(&handle);
        assert!(!handle.status().writable);
        assert_eq!(fs::read(directory.join("preferences.json")).unwrap(), bytes);
    }
}
