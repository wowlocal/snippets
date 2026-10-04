//! Already listed local-absence source review through the native owning controls.
//! Receive/Send produce the real journal; only a public primary record is removed.
use super::*;

const STAGE: &str = "SNIPPETS_LOCAL_ABSENCE_STAGE";

fn no_worker() -> bool {
    !fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|item| item.ok())
        .any(|item| {
            fs::read_to_string(item.path().join("comm"))
                .is_ok_and(|name| name.trim() == "snippets-accoun")
        })
}

pub(super) fn entrypoint(delete: bool) -> bool {
    if std::env::var_os(STAGE).is_none() {
        return false;
    }
    assert_eq!(std::env::var(STAGE).as_deref(), Ok("local-source"));
    run(delete);
    true
}

pub(super) fn process(delete: bool) {
    let _root = isolated_root();
    assert!(no_worker());
    let owned = tempfile::tempdir_in(std::env::var_os("XDG_DATA_HOME").unwrap()).unwrap();
    for name in ["data", "config", "cache"] {
        fs::create_dir(owned.path().join(name)).unwrap();
        fs::set_permissions(owned.path().join(name), fs::Permissions::from_mode(0o700)).unwrap();
    }
    let name = if delete {
        "account_ui::live_tests::vault::review::current::live_current_carrier_delete"
    } else {
        "account_ui::live_tests::vault::review::current::live_current_carrier_keep"
    };
    assert!(
        Process::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                name,
                "--ignored",
                "--test-threads=1",
                "--nocapture"
            ])
            .env(STAGE, "local-source")
            .env("XDG_DATA_HOME", owned.path().join("data"))
            .env("XDG_CONFIG_HOME", owned.path().join("config"))
            .env("XDG_CACHE_HOME", owned.path().join("cache"))
            .env(
                "SNIPPETS_SECRET_TEST_ROOT",
                owned.path().join("data/snippets")
            )
            .status()
            .unwrap()
            .success()
    );
    assert!(no_worker());
}

fn local_review(window: &Rc<AccountWindow>) -> adw::AlertDialog {
    let dialog = review(window);
    assert_eq!(
        dialog.heading().as_deref(),
        Some("Review Secure Snippet Deletion")
    );
    assert!(dialog.body().contains("This snippet is missing locally."));
    assert!(dialog.body().contains("Conflict originals to preserve: 1."));
    assert!(
        dialog
            .body()
            .contains("Restore 1 missing conflict originals")
    );
    assert!(!dialog.body().contains("The cloud deleted this snippet."));
    assert!(
        !dialog
            .body()
            .contains("Your choice applies only to this snippet.")
    );
    assert!(dialog.is_response_enabled("keep"));
    dialog
}

fn local_credentials(
    window: &Rc<AccountWindow>,
    delete: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let dialog = local_review(window);
    press(
        dialog.upcast_ref(),
        if delete {
            "Confirm Deletion"
        } else {
            "Restore Retained Version"
        },
    );
    until("native local-absence vault credentials did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    assert_eq!(dialog.close_response(), "cancel");
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}

fn decide(window: &Rc<AccountWindow>, delete: bool, password: &str) {
    let (dialog, entry) = local_credentials(window, delete);
    recovery_mode(&dialog).set_active(true);
    entry.set_text(password);
    press(
        dialog.upcast_ref(),
        if delete {
            "Verify and Delete"
        } else {
            "Verify and Restore"
        },
    );
    password_done(window, &entry);
}

fn run(delete: bool) {
    assert!(no_worker());
    let root = isolated_root();
    let fixture = server::Fixture::new();
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    parent.set_title(Some("Public Native Local Absence Acceptance"));
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    assert!(!no_worker());
    connect_keys(&window, &fixture);
    let installed = slot(&root, Slot::LibraryKey).unwrap();
    let (key, salt) = wire_material(&root);
    let independent: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&independent["document"]).unwrap()).unwrap();
    document.records[0].hlc = Some(Hlc::parse("100000000000-0000-11111111").unwrap());
    let source = document.records[0].metadata.id;
    let initial = projected(&document, source);
    let unrelated = model::Snippet::new(
        "Public local-absence unrelated",
        "Public local-absence unrelated ordinary body",
    );
    model::Library::open(root.clone())
        .unwrap()
        .save(unrelated.clone(), None)
        .unwrap();
    fs::create_dir(root.join("Vault")).unwrap();
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    let original_version = {
        let mut state = fixture.state.lock().unwrap();
        state.put(WireRecord::seal(&initial, &key, &salt).unwrap());
        state.version(source).unwrap()
    };
    action(&window, "Receive Cloud Changes");
    assert_eq!(
        window.status.label(),
        "Cloud changes received. Local changes have not been sent."
    );
    let confirmed = snapshot::checkpoint(&root);
    assert!(confirmed.journal.confirmed(source).unwrap().envelope == initial);
    assert!(
        confirmed.journal.confirmed(source).unwrap().record_version
            == crate::cloud::RecordVersion::from_checkpoint(original_version.clone()).unwrap()
    );
    document = crate::vault::read_document(&root).unwrap().unwrap();
    let losing = projected(&document, source);
    let vault_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let winner_body = b"Public locally missing raw source winner";
    edit(&mut document, source, winner_body, &vault_key);
    document.records[0].hlc = Some(Hlc::foreign(0xffff_0000_0000));
    let winner = projected(&document, source);
    let raw = crate::merge::merge(None, Some(&losing), Some(&winner))
        .unwrap()
        .survivor
        .unwrap();
    let copy_id = crate::merge::secure_variants(&raw)
        .unwrap()
        .remove(0)
        .copy_id;
    document.records[0] = crate::projection::vault_record(&raw, None, &document.kid)
        .unwrap()
        .unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    action(&window, "Send Local Changes");
    assert_eq!(
        window.status.label(),
        "An encrypted conflict needs preservation before its source or later edits can be sent."
    );
    let captured = snapshot::checkpoint(&root);
    assert!(captured.journal.has_preservation_work());
    assert!(captured.journal.preservation_original(copy_id).is_none());
    assert!(captured.journal.confirmed(source) == confirmed.journal.confirmed(source));
    assert!(crate::merge::has_unresolved(Some(
        &captured.journal.entry(source).unwrap().desired
    )));
    assert!(uploaded_has(&fixture, &unrelated, &key, &salt));
    assert!(uploaded(&fixture, source, &key, &salt) == initial);
    document.records.clear();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    let absent = primary(&root);
    let counts = data_counts(&fixture);
    let packets = fixture.state.lock().unwrap().submitted.clone();
    action(&window, "Send Local Changes");
    assert_eq!(
        window.status.label(),
        "A local record is missing. Sending is paused for review; local and cloud records are preserved."
    );
    assert!(primary(&root) == absent && data_counts(&fixture) == counts);
    assert!(fixture.state.lock().unwrap().submitted == packets);
    let held = snapshot::checkpoint(&root);
    assert!(!held.journal.entry(source).unwrap().desired.deleted);
    assert!(held.journal.deletion_approvals.is_empty());
    let dialog = local_review(&window);
    press(dialog.upcast_ref(), "Cancel");
    wait_work(&window);
    assert!(primary(&root) == absent && data_counts(&fixture) == counts);
    let (dialog, entry) = local_credentials(&window, delete);
    entry.set_text("Public cancelled local-absence credential");
    press(dialog.upcast_ref(), "Cancel");
    password_done(&window, &entry);
    assert!(primary(&root) == absent && data_counts(&fixture) == counts);
    let (_dialog, entry) = local_credentials(&window, delete);
    entry.set_text("Public revoked local-absence credential");
    parent.present();
    until(
        "native local-absence focus cancellation did not finish",
        || parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get(),
    );
    assert!(entry.text().is_empty());
    assert!(primary(&root) == absent && data_counts(&fixture) == counts);
    window.window.present();
    until("native local-absence window did not regain focus", || {
        window.window.is_active()
    });
    decide(
        &window,
        delete,
        "Public incorrect local-absence recovery key",
    );
    assert!(primary(&root) == absent && data_counts(&fixture) == counts);
    assert!(fixture.state.lock().unwrap().submitted == packets);
    no_session_key(&root, source);
    decide(&window, delete, &crypto::format_recovery(&[0x66; 16]));
    assert!(window.status.label().starts_with(if delete {
        "Deletion saved."
    } else {
        "Retained version restored."
    }));
    assert!(data_counts(&fixture) == counts);
    let decided = snapshot::checkpoint(&root);
    assert!(
        decided.journal.inbox == held.journal.inbox
            && decided.journal.outbound == held.journal.outbound
    );
    assert!(decided.journal.confirmed(source) == held.journal.confirmed(source));
    let target = decided.journal.entry(source).unwrap().desired.clone();
    assert!(
        target.deleted == delete && decided.journal.deletion_approved(&target).unwrap() == delete
    );
    let original = decided
        .journal
        .preservation_original(copy_id)
        .unwrap()
        .clone();
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    let copy = saved
        .records
        .iter()
        .find(|r| r.metadata.id == copy_id)
        .unwrap();
    assert!(!copy.metadata.is_enabled && copy.metadata.keyword.is_empty());
    assert!(copy.sealed.text().as_bytes() == original.fields.as_ref().unwrap().content.as_slice());
    assert!(
        body(&saved, copy_id, &vault_key).as_slice()
            == independent["plaintext"].as_str().unwrap().as_bytes()
    );
    assert!(saved.records.iter().any(|r| r.metadata.id == source) != delete);
    if !delete {
        assert!(body(&saved, source, &vault_key).as_slice() == winner_body);
    }
    no_session_key(&root, copy_id);
    assert!(local_has(&root, &unrelated));
    action(&window, "Sync Now");
    if window.status.label() == LOCKED {
        super::super::super::credential(&window, &crypto::format_recovery(&[0x66; 16]), true);
    }
    assert_eq!(window.status.label(), CURRENT);
    let final_source = uploaded(&fixture, source, &key, &salt);
    assert!(final_source.deleted == delete);
    let final_document = crate::vault::read_document(&root).unwrap().unwrap();
    if !delete {
        assert!(
            final_source.fields.as_ref().unwrap().content
                == winner.fields.as_ref().unwrap().content
        );
        assert!(body(&final_document, source, &vault_key).as_slice() == winner_body);
    }
    assert!(uploaded(&fixture, copy_id, &key, &salt) == original);
    assert!(
        body(&final_document, copy_id, &vault_key).as_slice()
            == independent["plaintext"].as_str().unwrap().as_bytes()
    );
    assert!(local_has(&root, &unrelated) && uploaded_has(&fixture, &unrelated, &key, &salt));
    assert!(slot(&root, Slot::LibraryKey).unwrap() == installed);
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.submitted[..packets.len()] == packets);
        let offers: Vec<_> = state.submitted.iter().flatten().collect();
        let copy_position = offers
            .iter()
            .position(|(wire, expected)| {
                wire.id == copy_id
                    && expected.is_none()
                    && wire.open(&key, &salt).unwrap() == original
            })
            .unwrap();
        let source_position = offers
            .iter()
            .position(|(wire, expected)| {
                wire.id == source && expected.as_deref() == Some(original_version.as_str())
            })
            .unwrap();
        assert!(copy_position < source_position);
    }
    let final_checkpoint = snapshot::checkpoint(&root);
    assert!(!final_checkpoint.journal.has_preservation_work());
    assert!(final_checkpoint.journal.deletion_approvals.is_empty());
    assert!(final_checkpoint.journal.pending().unwrap().is_empty());
    assert!(!root.join("Sync/primary.pending").exists());
    assert!(slot(&root, Slot::AutomaticSync).is_none());
    pause_quit(&window);
    drop(stop);
    drop(window);
    parent.destroy();
    drop(parent);
    app.quit();
    drop(app);
    until("native local-absence worker did not terminate", no_worker);
    println!(
        "Native local-absence source decision completed: no implicit deletion, mapped cancellation/focus/credential refusal, real original preservation before exact-CAS source update, unrelated state and terminal owned worker; public fixtures only."
    );
}
