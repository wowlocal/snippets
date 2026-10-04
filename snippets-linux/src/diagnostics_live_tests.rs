//! Existing diagnostics acceptance through real controls and the host SaveFile portal.
use super::*;
use crate::diagnostics::{
    Area, Count, Event, Lifecycle, Milliseconds, Outcome, Sink, StorageOperation,
};
use crate::portal_live_tests::chooser;
use std::{
    collections::BTreeSet,
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::Instant,
};

thread_local! {
    static EXPECTED: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    static SELECTED: Cell<bool> = const { Cell::new(false) };
}
pub(super) fn assert_selection(path: &Path) {
    EXPECTED.with(|expected| {
        if let Some(expected) = expected.borrow().as_ref() {
            assert!(
                path == expected,
                "The actual portal must return the owned destination before publication."
            );
            SELECTED.with(|selected| selected.set(true));
        }
    });
}
fn until(done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(
            Instant::now() < deadline,
            "The native diagnostic operation timed out."
        );
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn respond(controls: &Controls, heading: &str, label: &str) {
    until(|| {
        controls
            .dialog
            .borrow()
            .as_ref()
            .is_some_and(|dialog| dialog.is_mapped())
    });
    let dialog = controls.dialog.borrow().as_ref().unwrap().clone();
    assert_eq!(dialog.heading().as_deref(), Some(heading));
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    assert_eq!(dialog.close_response(), "cancel");
    assert!(dialog.body().contains(if heading.starts_with("Export") {
        "Snippet text, names, keywords, clipboard contents, identities, paths and keys are excluded."
    } else {
        "library data and encrypted recovery history remain intact."
    }));
    let mut pending = vec![dialog.upcast::<gtk::Widget>()];
    let mut matches = Vec::new();
    while let Some(widget) = pending.pop() {
        if let Ok(button) = widget.clone().downcast::<gtk::Button>()
            && button.label().as_deref() == Some(label)
        {
            matches.push(button);
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            pending.push(widget);
        }
    }
    assert_eq!(
        matches.len(),
        1,
        "The actual response button must be unique."
    );
    let button = &matches[0];
    until(|| button.is_mapped());
    assert!(button.is_sensitive());
    button.emit_clicked();
}
fn keys(value: &serde_json::Value) -> BTreeSet<&str> {
    value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect()
}
fn record_keys() -> BTreeSet<&'static str> {
    [
        "schema",
        "timestamp",
        "elapsed_ms",
        "session_id",
        "sequence",
        "level",
        "category",
        "event",
        "fields",
    ]
    .into()
}
#[test]
#[ignore = "requires the unlocked actual host portal; public private roots, no global logger/keyring/PAM/clipboard/network"]
fn live_portal_diagnostic_export_and_delete() {
    assert!(
        std::env::var_os("SNIPPETS_DIAGNOSTICS_LIVE").as_deref()
            == Some(std::ffi::OsStr::new("public-private-roots"))
    );
    assert!(crate::desktop::session_state() == crate::desktop::SessionState::Unlocked);
    adw::init().unwrap();
    let application = adw::Application::builder()
        .application_id("com.khm.snippets.linux.DiagnosticsLive")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    application.register(None::<&gio::Cancellable>).unwrap();
    let temp = tempfile::Builder::new()
        .prefix("snippets-diagnostics-live.")
        .tempdir()
        .unwrap();
    let root = temp.path().join("library");
    let mut library = Library::open(root.clone()).unwrap();
    library
        .save(
            crate::model::Snippet::new("Public diagnostics fixture", "Public preservation fixture"),
            None,
        )
        .unwrap();
    let protected = [
        library.path().to_path_buf(),
        root.join("Vault/vault.json"),
        root.join("Sync/cksync-checkpoint.bin"),
        root.join("History/public-retained.bin"),
    ];
    for path in &protected[1..] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        crate::model::atomic_write(path, b"public diagnostic non-log preservation sentinel")
            .unwrap();
    }
    let originals: Vec<_> = protected
        .iter()
        .map(|path| fs::read(path).unwrap())
        .collect();
    let service = Service::start(root.clone(), false).unwrap();
    service.record(Event::Lifecycle {
        state: Lifecycle::Started,
    });
    service.record(Event::Storage {
        area: Area::Library,
        operation: StorageOperation::Save,
        outcome: Outcome::Succeeded,
        duration_ms: Milliseconds::new(Duration::from_millis(4)),
        count: Count::new(1),
        failure: None,
    });
    service.flush().unwrap();
    let initial = service.summary().unwrap();
    assert_eq!(initial.files, 1);
    let window = adw::PreferencesWindow::builder()
        .title("Public Snippets Diagnostics Fixture")
        .search_enabled(true)
        .build();
    window.set_application(Some(&application));
    let controls = Controls::new(&window, Some(service.clone()));
    window.add(&controls.page);
    window.present();
    until(|| window.is_active() && controls.export.is_mapped() && controls.delete.is_mapped());
    controls.refresh();
    until(|| controls.can_quit());
    assert!(controls.status.subtitle().unwrap().contains("1 files"));
    let output = temp.path().join("public diagnostic export.jsonl");
    EXPECTED.with(|expected| *expected.borrow_mut() = Some(output.clone()));

    // Exercise the existing refusal paths before completing export/delete.
    controls.delete.emit_clicked();
    respond(&controls, "Delete Retained Diagnostic Logs?", "Cancel");
    until(|| controls.can_quit());
    assert_eq!(service.summary().unwrap().bytes, initial.bytes);
    controls.export.emit_clicked();
    respond(&controls, "Export Plaintext Diagnostic Logs?", "Cancel");
    until(|| controls.can_quit());
    assert!(controls.chooser.borrow().is_none());
    controls.export.emit_clicked();
    respond(
        &controls,
        "Export Plaintext Diagnostic Logs?",
        "Choose Destination…",
    );
    chooser("Export Diagnostic Logs").key("", "Escape");
    until(|| controls.can_quit());
    assert_eq!(service.summary().unwrap().bytes, initial.bytes);
    assert!(controls.chooser.borrow().is_none());
    assert!(!SELECTED.with(Cell::get) && !output.exists());
    println!(
        "Actual privacy/delete cancellation and authenticated host SaveFile cancellation preserved logs."
    );

    controls.export.emit_clicked();
    respond(
        &controls,
        "Export Plaintext Diagnostic Logs?",
        "Choose Destination…",
    );
    chooser("Export Diagnostic Logs").select(&output);
    until(|| controls.can_quit());
    assert!(SELECTED.with(Cell::get));
    assert!(
        controls
            .status
            .subtitle()
            .unwrap()
            .starts_with("Exported 2 records (")
            && controls
                .status
                .subtitle()
                .unwrap()
                .ends_with("skipped 0 torn final lines.")
    );
    assert!(controls.export.is_sensitive() && controls.delete.is_sensitive());
    until(|| window.is_active());
    let exported = fs::read(&output).unwrap();
    assert_eq!(
        fs::metadata(&output).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(exported.last(), Some(&b'\n'));
    let records: Vec<serde_json::Value> = exported
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_slice(line).unwrap())
        .collect();
    assert_eq!(records.len(), 3);
    for record in &records {
        assert_eq!(keys(record), record_keys());
        assert_eq!(record["schema"], 1);
        assert_eq!(record["level"], "info");
    }
    assert_eq!(records[0]["event"], "diagnostics_manifest");
    assert_eq!(
        records[0]["fields"],
        serde_json::json!({"platform":"linux", "app_version":env!("CARGO_PKG_VERSION"), "file_count":1, "record_count":2, "byte_count":initial.bytes, "skipped_trailing_lines":0})
    );
    assert_eq!(records[1]["event"], "linux_app_lifecycle");
    assert_eq!(records[1]["category"], "app");
    assert_eq!(records[1]["fields"], serde_json::json!({"state":"started"}));
    assert_eq!(records[2]["event"], "linux_storage_operation");
    assert_eq!(records[2]["category"], "persistence");
    assert_eq!(
        records[2]["fields"],
        serde_json::json!({"area":"library", "operation":"save", "outcome":"succeeded", "duration_ms":4, "count":1, "failure":null})
    );
    assert_eq!(service.summary().unwrap().bytes, initial.bytes);
    println!(
        "Actual host SaveFile returned the exact public destination; exported manifest, closed fields, counts, private permissions and focus passed."
    );

    controls.delete.emit_clicked();
    respond(&controls, "Delete Retained Diagnostic Logs?", "Delete Logs");
    until(|| controls.can_quit());
    assert_eq!(
        controls.status.subtitle().as_deref(),
        Some(format!("Deleted 1 log files ({} bytes).", initial.bytes).as_str())
    );
    assert_eq!(service.summary().unwrap().files, 0);
    assert_eq!(service.summary().unwrap().bytes, 0);
    assert!(controls.export.is_sensitive() && controls.delete.is_sensitive());
    assert!(fs::read(&output).unwrap() == exported);
    for (path, original) in protected.iter().zip(&originals) {
        assert!(fs::read(path).unwrap() == *original);
    }
    service.record(Event::Lifecycle {
        state: Lifecycle::Started,
    });
    service.flush().unwrap();
    controls.refresh();
    until(|| controls.can_quit());
    assert_eq!(service.summary().unwrap().files, 1);
    assert!(controls.status.subtitle().unwrap().contains("1 files"));
    for relative in ["Diagnostics", "Diagnostics/Logs"] {
        assert_eq!(
            fs::metadata(root.join(relative))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }
    println!(
        "Actual destructive confirmation deleted retained logs only, preserved export/library/vault/checkpoint/history bytes, and subsequent recording resumed."
    );
    EXPECTED.with(|expected| expected.borrow_mut().take());
    window.destroy();
    service.stop();
    until(|| service.finished());
}
