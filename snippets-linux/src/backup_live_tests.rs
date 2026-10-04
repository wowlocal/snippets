//! Actual desktop portal and backup workers; only public fictional material.
use super::*;
use crate::{backup, crypto, desktop, model, vault::Document};
use std::{
    fs,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::Path,
    process::Command,
    time::Instant,
};
const PASSWORD: &str = "Café public backup fixture";
thread_local! {
    static EXPECTED: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    static SELECTED: Cell<bool> = const { Cell::new(false) };
}
pub(super) fn assert_selection(path: &Path) {
    EXPECTED.with(|expected| {
        if let Some(expected) = expected.borrow().as_ref() {
            assert!(path == expected, "The real chooser must select the private fixture path before credentials or writes.");
            SELECTED.with(|value| value.set(true));
        }
    });
}
fn pump() {
    while glib::MainContext::default().pending() {
        glib::MainContext::default().iteration(false);
    }
}
fn settle(duration: Duration) {
    let end = Instant::now() + duration;
    while Instant::now() < end {
        pump();
        std::thread::sleep(Duration::from_millis(5));
    }
    pump();
}
#[track_caller]
fn until(seconds: u64, predicate: impl Fn() -> bool) {
    let end = Instant::now() + Duration::from_secs(seconds);
    while !predicate() {
        assert!(
            Instant::now() < end,
            "The real native backup flow timed out."
        );
        settle(Duration::from_millis(10));
    }
}
use crate::portal_live_tests::chooser;
fn expect(path: &Path) {
    EXPECTED.with(|value| *value.borrow_mut() = Some(path.into()));
    SELECTED.with(|value| value.set(false));
}
fn fields(export: &Export, heading: &str) -> (adw::AlertDialog, Vec<gtk::PasswordEntry>) {
    until(120, || {
        assert!(
            export.busy.get(),
            "The backup stopped before its credential request: selected={}, chooser_pending={}, parent_active={}.",
            SELECTED.with(Cell::get),
            export.file.borrow().is_some(),
            export.parent.is_active()
        );
        export
            .passwords
            .borrow()
            .as_ref()
            .is_some_and(|(dialog, _)| dialog.heading().as_deref() == Some(heading))
    });
    assert!(
        SELECTED.with(Cell::get),
        "The credential request must follow the actual private file selection."
    );
    export.passwords.borrow().as_ref().unwrap().clone()
}
fn recovery(dialog: &adw::AlertDialog) {
    let mut pending = vec![dialog.clone().upcast::<gtk::Widget>()];
    while let Some(widget) = pending.pop() {
        if let Ok(check) = widget.clone().downcast::<gtk::CheckButton>()
            && check.label().as_deref() == Some("Use the vault recovery key")
        {
            check.set_active(true);
            return;
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            pending.push(widget);
        }
    }
    panic!("The real recovery credential control must be present.");
}
fn source(root: &Path) -> Library {
    let mut library = Library::open(root.into()).unwrap();
    let mut plain = model::Snippet::new("Public backup name", "Public ordinary backup body 🦀");
    plain.id = uuid::Uuid::from_u128(2);
    plain.keyword = "public-backup".into();
    library.save(plain, None).unwrap();
    fs::DirBuilder::new()
        .mode(0o700)
        .create(root.join("Vault"))
        .unwrap();
    let fixture: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&fixture["document"]).unwrap()).unwrap();
    document.extra.insert(
        "local.syncConflictC0Receipts.v1".into(),
        serde_json::json!({"public-receipt": true}),
    );
    document.extra.insert(
        "futurePublicBackupField".into(),
        serde_json::json!({"enabled": true}),
    );
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    library
}
#[test]
#[ignore = "requires the unlocked real Omarchy desktop portal; isolated public library, no keyring/PAM/clipboard/network"]
fn live_portal_backup_export_and_restore() {
    assert!(
        std::env::var_os("SNIPPETS_BACKUP_LIVE").as_deref()
            == Some(std::ffi::OsStr::new("public-private-roots"))
    );
    assert!(desktop::session_state() == desktop::SessionState::Unlocked);
    adw::init().unwrap();
    let application = adw::Application::builder()
        .application_id("com.khm.snippets.linux.BackupLive")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    application.register(None::<&gio::Cancellable>).unwrap();
    let parent = adw::ApplicationWindow::builder()
        .application(&application)
        .title("Public Snippets Backup Fixture")
        .default_width(700)
        .default_height(500)
        .build();
    parent.present();
    until(5, || parent.is_active());
    let directory = tempfile::Builder::new()
        .prefix("snippets-backup-live.")
        .tempdir()
        .unwrap();
    let mut library = source(&directory.path().join("library"));
    let export = Export::new(&parent, &library);
    until(5, || {
        export
            .monitor
            .as_ref()
            .is_some_and(|m| m.snapshot().0 == SessionState::Unlocked)
    });
    let output = directory.path().join("public.snippetsbackup");
    let original_plain = fs::read(library.path()).unwrap();
    let original_vault = fs::read(library.root.join("Vault/vault.json")).unwrap();
    for refusal in 0..4 {
        let refused = directory
            .path()
            .join(format!("refused-{refusal}.snippetsbackup"));
        expect(&refused);
        let outcome = Rc::new(RefCell::new(None));
        let notify = outcome.clone();
        export.start(move |value| *notify.borrow_mut() = Some(value));
        let portal = chooser("Export Encrypted Backup");
        if refusal == 0 {
            portal.key("", "Escape");
        } else {
            portal.select(&refused);
            let (dialog, entries) = fields(&export, "Protect Your Encrypted Backup");
            entries[0].set_text(PASSWORD);
            entries[1].set_text(PASSWORD);
            entries[2].set_text(&crypto::format_recovery(&[0x77; 16]));
            recovery(&dialog);
            if refusal == 1 {
                tests::respond(&dialog, "Cancel");
            } else if refusal == 2 {
                assert!(entries[0].grab_focus());
                let companion = adw::ApplicationWindow::builder()
                    .application(&application)
                    .title("Public Backup Focus Receiver")
                    .build();
                companion.present();
                until(5, || companion.is_active());
                until(5, || !export.busy.get());
                assert!(
                    !glib::MainContext::default()
                        .block_on(export.file_dialog_returned(export.generation.get()))
                );
                assert!(companion.is_active() && !parent.is_active());
                companion.destroy();
                parent.present();
                until(5, || parent.is_active());
            } else {
                tests::respond(&dialog, "Export Encrypted Backup");
            }
            until(120, || !export.busy.get());
            assert!(entries.iter().all(|entry| entry.text().is_empty()));
        }
        until(120, || !export.busy.get());
        if refusal == 3 {
            assert!(matches!(outcome.borrow().as_ref(), Some(Err(_))));
        } else {
            assert!(outcome.borrow().is_none());
        }
        assert!(!refused.exists());
        assert!(fs::read(library.path()).unwrap() == original_plain);
        assert!(fs::read(library.root.join("Vault/vault.json")).unwrap() == original_vault);
        assert!(export.prepare_quit());
        until(5, || parent.is_active());
    }
    println!(
        "Actual chooser, credential cancellation, focus loss and wrong vault authentication refused publication."
    );
    expect(&output);
    let result = Rc::new(RefCell::new(None));
    let notify = result.clone();
    export.start(move |value| *notify.borrow_mut() = Some(value));
    chooser("Export Encrypted Backup").select(&output);
    let (dialog, entries) = fields(&export, "Protect Your Encrypted Backup");
    entries[0].set_text(PASSWORD);
    entries[1].set_text(PASSWORD);
    entries[2].set_text(&crypto::format_recovery(&[0x66; 16]));
    recovery(&dialog);
    tests::respond(&dialog, "Export Encrypted Backup");
    until(120, || !export.busy.get());
    assert!(matches!(result.borrow().as_ref(), Some(Ok((1, 1)))));
    assert!(entries.iter().all(|entry| entry.text().is_empty()));
    assert!(fs::metadata(&output).unwrap().permissions().mode() & 0o777 == 0o600);
    let reference = Command::new("python3")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/backup.py"))
        .arg("--verify")
        .arg(&output)
        .output()
        .unwrap();
    assert!(
        reference.status.success(),
        "Independent OpenSSL verification must authenticate the actual native export."
    );
    let opened = backup::open(&fs::read(&output).unwrap(), PASSWORD).unwrap();
    assert!(opened.counts() == (1, 1));
    assert!(fs::read(library.path()).unwrap() == original_plain);
    assert!(fs::read(library.root.join("Vault/vault.json")).unwrap() == original_vault);
    println!("Actual portal export and independent OpenSSL verification passed.");
    let old = library.snippets[0].clone();
    let mut changed = old.clone();
    changed.content = "Public local body before restore".into();
    library.save(changed, Some(&old)).unwrap();
    let mut unrelated = model::Snippet::new("Public unrelated entry", "Public unrelated body");
    unrelated.keyword = "public-unrelated".into();
    library.save(unrelated.clone(), None).unwrap();
    let unrelated = library
        .snippets
        .iter()
        .find(|s| s.id == unrelated.id)
        .unwrap()
        .clone();
    let mut changed = Document::decode(&original_vault).unwrap();
    changed.records[0].metadata.name = "Public local name before restore".into();
    model::atomic_write(
        &library.root.join("Vault/vault.json"),
        &changed.encode().unwrap(),
    )
    .unwrap();
    let before = fs::read(library.path()).unwrap();
    let vault_before = fs::read(library.root.join("Vault/vault.json")).unwrap();
    for refusal in 0..3 {
        expect(&output);
        let outcome = Rc::new(RefCell::new(None));
        let notify = outcome.clone();
        export.start_import(false, move |value| *notify.borrow_mut() = Some(value));
        let portal = chooser("Restore Encrypted Backup");
        if refusal == 0 {
            portal.key("", "Escape");
        } else {
            portal.select(&output);
            let (dialog, entries) = fields(&export, "Open Encrypted Backup");
            entries[0].set_text(if refusal == 1 {
                "Wrong public backup password"
            } else {
                PASSWORD
            });
            tests::respond(&dialog, "Open Backup");
            if refusal == 2 {
                let (review, credentials) = fields(&export, "Restore This Backup?");
                assert!(review.default_response().as_deref() == Some("cancel"));
                credentials[0].set_text(&crypto::format_recovery(&[0x66; 16]));
                recovery(&review);
                tests::respond(&review, "Cancel");
                until(120, || !export.busy.get());
                assert!(credentials.iter().all(|entry| entry.text().is_empty()));
            }
            until(120, || !export.busy.get());
            assert!(entries.iter().all(|entry| entry.text().is_empty()));
        }
        until(120, || !export.busy.get());
        if refusal == 1 {
            assert!(matches!(outcome.borrow().as_ref(), Some(Err(_))));
        } else {
            assert!(outcome.borrow().is_none());
        }
        assert!(fs::read(library.path()).unwrap() == before);
        assert!(fs::read(library.root.join("Vault/vault.json")).unwrap() == vault_before);
        assert!(!backup::import::pending(&library.root).unwrap());
        until(5, || parent.is_active());
    }
    expect(&output);
    let restored = Rc::new(RefCell::new(None));
    let notify = restored.clone();
    export.start_import(false, move |value| *notify.borrow_mut() = Some(value));
    chooser("Restore Encrypted Backup").select(&output);
    let (dialog, entries) = fields(&export, "Open Encrypted Backup");
    entries[0].set_text(PASSWORD);
    tests::respond(&dialog, "Open Backup");
    let (review, credentials) = fields(&export, "Restore This Backup?");
    assert!(review.default_response().as_deref() == Some("cancel"));
    credentials[0].set_text(&crypto::format_recovery(&[0x66; 16]));
    recovery(&review);
    tests::respond(&review, "Restore Backup");
    until(120, || !export.busy.get());
    assert!(matches!(restored.borrow().as_ref(), Some(Ok(Some((1, 1))))));
    assert!(
        entries
            .iter()
            .chain(credentials.iter())
            .all(|entry| entry.text().is_empty())
    );
    library.reload_catalogue().unwrap();
    assert!(library.snippets.len() == 2 && library.snippets.contains(&unrelated));
    assert!(library.snippets.iter().find(|s| s.id == old.id).unwrap() == &old);
    let after =
        Document::decode(&fs::read(library.root.join("Vault/vault.json")).unwrap()).unwrap();
    let before = Document::decode(&vault_before).unwrap();
    assert!(
        after.records[0].sealed == before.records[0].sealed
            && after.records[0].metadata.name
                == Document::decode(&original_vault).unwrap().records[0]
                    .metadata
                    .name
            && after.wrap_recovery == before.wrap_recovery
            && after.wrap_pass == before.wrap_pass
    );
    assert!(!backup::import::pending(&library.root).unwrap());
    assert!(!library.root.join("Sync").exists());
    println!(
        "Actual matching-vault restore replaced both primary records and preserved unrelated entries and unlock methods."
    );
    let mut fresh = Library::open(directory.path().join("fresh-library")).unwrap();
    let importer = Export::new(&parent, &fresh);
    until(5, || {
        importer
            .monitor
            .as_ref()
            .is_some_and(|m| m.snapshot().0 == SessionState::Unlocked)
    });
    expect(&output);
    let restored = Rc::new(RefCell::new(None));
    let notify = restored.clone();
    importer.start_import(false, move |value| *notify.borrow_mut() = Some(value));
    chooser("Restore Encrypted Backup").select(&output);
    let (dialog, entries) = fields(&importer, "Open Encrypted Backup");
    entries[0].set_text(PASSWORD);
    tests::respond(&dialog, "Open Backup");
    let (review, credentials) = fields(&importer, "Restore This Backup?");
    credentials[1].set_text("Public new local vault passphrase");
    credentials[2].set_text("Public mismatched local passphrase");
    assert!(!review.is_response_enabled("restore"));
    credentials[2].set_text("Public new local vault passphrase");
    assert!(review.is_response_enabled("restore"));
    tests::respond(&review, "Restore Backup");
    until(120, || !importer.busy.get());
    assert!(matches!(restored.borrow().as_ref(), Some(Ok(Some((1, 1))))));
    assert!(
        entries
            .iter()
            .chain(credentials.iter())
            .all(|entry| entry.text().is_empty())
    );
    fresh.reload_catalogue().unwrap();
    assert!(fresh.snippets == vec![old]);
    let document =
        Document::decode(&fs::read(fresh.root.join("Vault/vault.json")).unwrap()).unwrap();
    assert!(document.records[0].sealed == after.records[0].sealed);
    for (secret, is_recovery) in [
        ("Public new local vault passphrase".to_owned(), false),
        (crypto::format_recovery(&[0x66; 16]).to_string(), true),
    ] {
        document
            .with_backup_key(&secret, is_recovery, |key| {
                assert!(key.same_key(&crypto::RootKey::from_bytes(&[0x11; 32]).unwrap()));
                Ok(())
            })
            .unwrap();
    }
    assert!(
        !document
            .extra
            .keys()
            .any(|key| key.starts_with("local.syncConflictC0Receipts."))
    );
    assert!(!backup::import::pending(&fresh.root).unwrap() && !fresh.root.join("Sync").exists());
    assert!(importer.prepare_quit());
    println!(
        "Actual fresh-vault restore accepted matching local passwords and retained the original recovery key."
    );
    export.prepare_quit();
    parent.destroy();
    settle(Duration::from_millis(250));
}
