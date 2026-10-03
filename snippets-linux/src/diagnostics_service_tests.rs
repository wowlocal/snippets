use super::*;
use crate::diagnostics::{Area, Lifecycle, Milliseconds, Outcome, StorageOperation};
use std::os::unix::fs::PermissionsExt;

fn root() -> (tempfile::TempDir, PathBuf) {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("library");
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    (temp, root)
}
fn event() -> Event {
    Event::Storage {
        area: Area::Library,
        operation: StorageOperation::Save,
        outcome: Outcome::Succeeded,
        duration_ms: Milliseconds::new(Duration::from_millis(4)),
        count: Count::new(1),
        failure: None,
    }
}
fn write_private(path: &Path, bytes: &[u8]) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn settle(service: &Service) {
    service.stop();
    let start = Instant::now();
    while !service.finished() {
        assert!(start.elapsed() < Duration::from_secs(4));
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn worker_exports_portable_validated_records_and_does_not_touch_the_library() {
    let (temp, root) = root();
    write_private(&root.join("snippets.json"), b"PRIVATE library sentinel");
    let service = Service::start(root.clone(), false).unwrap();
    service.record(Event::Lifecycle {
        state: Lifecycle::Started,
    });
    service.record(event());
    service.flush().unwrap();
    let summary = service.summary().unwrap();
    assert_eq!(summary.files, 1);
    assert!(summary.bytes > 0);
    let output = temp.path().join("logs.jsonl");
    let result = service.export(output.clone()).unwrap();
    assert_eq!(result.records, 2);
    assert_eq!(result.skipped, 0);
    let bytes = fs::read(&output).unwrap();
    assert_eq!(bytes.len(), result.bytes);
    let lines: Vec<_> = bytes
        .split(|b| *b == b'\n')
        .filter(|b| !b.is_empty())
        .collect();
    let manifest: serde_json::Value = serde_json::from_slice(lines[0]).unwrap();
    assert_eq!(manifest["event"], "diagnostics_manifest");
    assert_eq!(manifest["fields"]["platform"], "linux");
    assert_eq!(manifest["fields"]["record_count"], 2);
    for raw in &lines[1..] {
        validate(raw).unwrap();
    }
    assert!(!String::from_utf8(bytes).unwrap().contains("PRIVATE"));
    fs::set_permissions(&output, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(service.export(output.clone()).unwrap().records, 2);
    assert_eq!(fs::metadata(output).unwrap().mode() & 0o777, 0o600);
    for path in [root.join("Diagnostics"), root.join("Diagnostics/Logs")] {
        assert_eq!(fs::metadata(path).unwrap().mode() & 0o777, 0o700);
    }
    assert_eq!(
        fs::read(root.join("snippets.json")).unwrap(),
        b"PRIVATE library sentinel"
    );
    assert!(!root.join("Vault").exists());
    assert!(!root.join("Sync").exists());
    settle(&service);
}
#[test]
fn retention_rotation_size_and_count_limits_remove_only_owned_regular_logs() {
    let (_temp, root) = root();
    let mut driver = Driver::open(root.clone(), false).unwrap();
    driver.file_limit = 900;
    driver.file_count = 3;
    driver.quota = 1800;
    let sentinel = root.join("Diagnostics/Logs/unrelated.txt");
    write_private(&sentinel, b"unrelated");
    for _ in 0..20 {
        driver.write(event()).unwrap();
    }
    let summary = driver.summary().unwrap();
    assert!(summary.files <= 3);
    assert!(summary.bytes <= 1800);
    let name = driver.active.as_ref().unwrap().name.clone();
    driver.active.as_mut().unwrap().started = Instant::now() - ROLL_AGE;
    driver.write(event()).unwrap();
    assert_ne!(driver.active.as_ref().unwrap().name, name);
    let active = driver.active.as_ref().unwrap();
    active
        .file
        .set_times(
            fs::FileTimes::new()
                .set_modified(std::time::SystemTime::now() - RETENTION - Duration::from_secs(1)),
        )
        .unwrap();
    let expired = active.name.clone();
    driver.maintain().unwrap();
    assert!(!root.join("Diagnostics/Logs").join(expired).exists());
    assert_eq!(fs::read(sentinel).unwrap(), b"unrelated");
}
#[test]
fn export_rejects_unexpected_fields_types_versions_and_duplicates_without_replacing_output() {
    let (temp, root) = root();
    let mut driver = Driver::open(root.clone(), false).unwrap();
    let name = format!("snippets-{}.jsonl", uuid::Uuid::new_v4());
    let log = root.join("Diagnostics/Logs").join(name);
    let output = temp.path().join("export.jsonl");
    write_private(&output, b"previous export");
    let good =
        serde_json::from_slice::<serde_json::Value>(&line(event(), &driver.session, 1, 0).unwrap())
            .unwrap();
    let mut cases = Vec::new();
    for (pointer, value) in [
        ("/schema", serde_json::json!(2)),
        ("/elapsed_ms", serde_json::json!(true)),
        ("/sequence", serde_json::json!(0)),
        ("/level", serde_json::json!("fault")),
        ("/category", serde_json::json!("vault")),
        ("/fields/count", serde_json::json!(1_000_001)),
        (
            "/fields/failure",
            serde_json::json!({"family":"arbitrary","code":1}),
        ),
    ] {
        let mut bad = good.clone();
        *bad.pointer_mut(pointer).unwrap() = value;
        cases.push(bad.to_string());
    }
    let mut bad = good.clone();
    bad["fields"]["message"] = serde_json::json!("PRIVATE token");
    cases.push(bad.to_string());
    let mut bad = good.clone();
    bad["fields"].as_object_mut().unwrap().remove("failure");
    cases.push(bad.to_string());
    cases.push(good.to_string().replacen("{", "{\"schema\":1,", 1));
    cases.push(
        good.to_string()
            .replace("\"count\":1", "\"count\":\"PRIVATE\",\"count\":1"),
    );
    for bad in cases {
        write_private(&log, format!("{bad}\n").as_bytes());
        assert_eq!(driver.export(&output).unwrap_err(), Error::Corrupt);
        assert_eq!(fs::read(&output).unwrap(), b"previous export");
    }
}
#[test]
fn export_skips_only_a_torn_final_line_and_reencodes_valid_unterminated_records() {
    let (temp, root) = root();
    let mut driver = Driver::open(root.clone(), false).unwrap();
    let log = root
        .join("Diagnostics/Logs")
        .join(format!("snippets-{}.jsonl", uuid::Uuid::new_v4()));
    let output = temp.path().join("export.jsonl");
    let valid = line(event(), &driver.session, 1, 0).unwrap();
    let mut bytes = valid.clone();
    bytes.extend_from_slice(b"{\"event\":");
    write_private(&log, &bytes);
    let exported = driver.export(&output).unwrap();
    assert_eq!(exported.records, 1);
    assert_eq!(exported.skipped, 1);
    write_private(&log, &valid[..valid.len() - 1]);
    let exported = driver.export(&output).unwrap();
    assert_eq!(exported.records, 1);
    assert_eq!(exported.skipped, 0);
    for tail in [b"not JSON".as_slice(), b"{\"message\":\"PRIVATE\"}", b"\n"] {
        let mut bad = valid.clone();
        bad.extend_from_slice(tail);
        write_private(&log, &bad);
        assert_eq!(driver.export(&output).unwrap_err(), Error::Corrupt);
    }
}
#[test]
fn linked_hardlinked_and_fifo_inputs_are_refused_and_foreign_bytes_survive() {
    for kind in 0..3 {
        let (temp, root) = root();
        let mut driver = Driver::open(root.clone(), false).unwrap();
        let foreign = temp.path().join("foreign");
        write_private(&foreign, b"PRIVATE foreign data");
        let log = root
            .join("Diagnostics/Logs")
            .join(format!("snippets-{}.jsonl", uuid::Uuid::new_v4()));
        match kind {
            0 => std::os::unix::fs::symlink(&foreign, &log).unwrap(),
            1 => fs::hard_link(&foreign, &log).unwrap(),
            _ => {
                let path = cstring(log.as_os_str()).unwrap();
                assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
            }
        }
        let start = Instant::now();
        assert!(driver.export(&temp.path().join("export")).is_err());
        assert!(driver.delete().is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(fs::read(foreign).unwrap(), b"PRIVATE foreign data");
        assert!(fs::symlink_metadata(log).is_ok());
    }
}
#[test]
fn directory_replacement_and_a_second_owner_cannot_adopt_the_current_logger() {
    let (temp, root) = root();
    let mut driver = Driver::open(root.clone(), false).unwrap();
    assert!(matches!(
        Driver::open(root.clone(), false),
        Err(Error::Unavailable)
    ));
    let foreign = temp.path().join("foreign");
    fs::create_dir(&foreign).unwrap();
    fs::rename(root.join("Diagnostics"), root.join("retained-diagnostics")).unwrap();
    std::os::unix::fs::symlink(&foreign, root.join("Diagnostics")).unwrap();
    assert_eq!(driver.write(event()).unwrap_err(), Error::UnsafeInput);
    assert!(Driver::open(root, false).is_err());
    assert_eq!(fs::read_dir(foreign).unwrap().count(), 0);
}
#[test]
fn changed_or_linked_export_destinations_and_app_data_are_preserved() {
    let (temp, root) = root();
    let destination = temp.path().join("out.jsonl");
    write_private(&destination, b"before");
    let target = Target::capture(&destination, &root).unwrap();
    write_private(&destination, b"new external edit");
    assert_eq!(target.publish(b"export").unwrap_err(), Error::Changed);
    assert_eq!(fs::read(&destination).unwrap(), b"new external edit");
    let linked = temp.path().join("linked");
    std::os::unix::fs::symlink(&destination, &linked).unwrap();
    assert!(Target::capture(&linked, &root).is_err());
    assert!(Target::capture(&root.join("snippets.json"), &root).is_err());
    let hard = temp.path().join("hard");
    fs::hard_link(&destination, &hard).unwrap();
    assert!(Target::capture(&destination, &root).is_err());
    assert!(!root.join("snippets.json").exists());
    assert_eq!(fs::read(hard).unwrap(), b"new external edit");
}
#[test]
fn delete_removes_corrupt_owned_logs_and_new_events_resume_without_touching_other_files() {
    let (_temp, root) = root();
    let service = Service::start(root.clone(), false).unwrap();
    service.record(event());
    service.flush().unwrap();
    let other = root.join("Diagnostics/Logs/keep.txt");
    write_private(&other, b"preserved");
    let corrupt = root
        .join("Diagnostics/Logs")
        .join(format!("snippets-{}.jsonl", uuid::Uuid::new_v4()));
    write_private(&corrupt, b"invalid\n");
    assert_eq!(service.delete().unwrap().files, 2);
    assert_eq!(service.summary().unwrap().files, 0);
    service.record(event());
    service.flush().unwrap();
    assert_eq!(service.summary().unwrap().files, 1);
    assert_eq!(fs::read(other).unwrap(), b"preserved");
    settle(&service);
}
#[test]
fn shutdown_drains_accepted_events_and_fences_new_control_requests() {
    let (_temp, root) = root();
    let service = Service::start(root.clone(), false).unwrap();
    for _ in 0..12 {
        service.record(event());
    }
    settle(&service);
    assert_eq!(service.summary().unwrap_err(), Error::Stopped);
    let mut count = 0;
    for entry in fs::read_dir(root.join("Diagnostics/Logs")).unwrap() {
        let bytes = fs::read(entry.unwrap().path()).unwrap();
        for raw in bytes.split(|b| *b == b'\n').filter(|b| !b.is_empty()) {
            validate(raw).unwrap();
            count += 1;
        }
    }
    assert_eq!(count, 12);
}
#[test]
fn bounded_queue_reports_loss_without_accepting_private_payloads() {
    let (sender, receiver) = mpsc::sync_channel(1);
    let service = Service {
        root: PathBuf::new(),
        sender,
        stopping: Arc::new(AtomicBool::new(false)),
        finished: Arc::new(AtomicBool::new(false)),
        lost: Arc::new(AtomicU64::new(0)),
    };
    service.record(event());
    service.record(event());
    assert_eq!(service.lost.load(Ordering::Relaxed), 1);
    assert!(matches!(
        receiver.try_recv().unwrap(),
        Command::Record(_, None)
    ));
    assert!(receiver.try_recv().is_err());
}
#[test]
fn total_and_individual_export_limits_preserve_destination() {
    let (temp, root) = root();
    let mut driver = Driver::open(root.clone(), false).unwrap();
    let output = temp.path().join("output");
    write_private(&output, b"previous");
    for _ in 0..26 {
        let name = format!("snippets-{}.jsonl", uuid::Uuid::new_v4());
        let file = open_at(
            &driver.logs,
            OsStr::new(&name),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            0o600,
        )
        .unwrap();
        file.set_len(FILE_LIMIT).unwrap();
    }
    assert_eq!(driver.export(&output).unwrap_err(), Error::TooLarge);
    assert_eq!(fs::read(&output).unwrap(), b"previous");
    driver.delete().unwrap();
    let path = root
        .join("Diagnostics/Logs")
        .join(format!("snippets-{}.jsonl", uuid::Uuid::new_v4()));
    write_private(&path, b"");
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_len(FILE_LIMIT + 1)
        .unwrap();
    assert_eq!(driver.export(&output).unwrap_err(), Error::TooLarge);
    assert_eq!(fs::read(output).unwrap(), b"previous");
}
#[test]
fn repeated_process_sequences_are_rejected_without_publishing_an_ambiguous_export() {
    let (temp, root) = root();
    let mut driver = Driver::open(root.clone(), false).unwrap();
    let bytes = line(event(), &driver.session, 1, 0).unwrap();
    for _ in 0..2 {
        write_private(
            &root
                .join("Diagnostics/Logs")
                .join(format!("snippets-{}.jsonl", uuid::Uuid::new_v4())),
            &bytes,
        );
    }
    let output = temp.path().join("logs");
    assert_eq!(driver.export(&output).unwrap_err(), Error::Corrupt);
    assert!(!output.exists());
}
#[test]
fn replaced_owner_lock_and_concurrently_edited_cleanup_inputs_revoke_write_authority() {
    let (_temp, root) = root();
    let mut driver = Driver::open(root.clone(), false).unwrap();
    driver.write(event()).unwrap();
    let (name, before) = driver.entries().unwrap().pop().unwrap();
    let path = root.join("Diagnostics/Logs").join(&name);
    write_private(&path, b"external edit");
    assert_eq!(driver.unlink(&name, &before).unwrap_err(), Error::Changed);
    assert_eq!(fs::read(path).unwrap(), b"external edit");
    fs::rename(
        root.join("Diagnostics/.owner.lock"),
        root.join("Diagnostics/old-owner.lock"),
    )
    .unwrap();
    write_private(&root.join("Diagnostics/.owner.lock"), b"");
    assert_eq!(driver.write(event()).unwrap_err(), Error::Changed);
    assert!(driver.delete().is_err());
}
