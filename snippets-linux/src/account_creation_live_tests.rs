//! Native library creation with a real private keyring and verified HTTPS.
//! The peer independently owns idempotency receipts; all data is public fiction.
use super::*;
use crate::auth_store::creation::State as CreationState;
use std::os::unix::fs::PermissionsExt;

pub(super) fn images(root: &Path) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    ["snippets.json", "Vault/vault.json", "Sync/journal.bin"]
        .into_iter()
        .map(|name| match fs::read(root.join(name)) {
            Ok(bytes) => Some(Zeroizing::new(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(_) => panic!("Public creation fixture image was unreadable"),
        })
        .collect()
}
fn protected(root: &Path) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::PairingRecipient,
        Slot::CheckpointKey,
        Slot::KeyMutation,
        Slot::AccountReview,
        Slot::PairingCandidate,
        Slot::BootstrapCandidate,
    ]
    .into_iter()
    .map(|name| slot(root, name))
    .collect()
}
#[track_caller]
fn review(window: &Rc<AccountWindow>, label: &str) -> adw::AlertDialog {
    press(window.window.upcast_ref(), label);
    until("native library-creation confirmation did not map", || {
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|dialog| dialog.is_mapped())
    });
    let dialog = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(
        dialog.heading().as_deref() == Some("Create New Cloud Library?")
            && dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
            && dialog.body().contains("fixture@example.invalid")
            && dialog.body().contains("https://127.0.0.1:")
    );
    dialog
}
fn finish(window: &Rc<AccountWindow>) {
    wait_work(window);
    assert!(window.snapshot_dialog.borrow().is_none());
    assert!(window.worker.can_quit());
}
fn creation_entries(root: &Path) -> usize {
    let bytes = slot(root, Slot::SpaceCreation).unwrap();
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(value["schema"] == 3);
    value["entries"].as_array().unwrap().len()
}

#[test]
#[ignore = "explicit native creation GTK/HTTPS/keyring acceptance; invoke tests/account-live.sh with --creation"]
fn live_library_creation_retains_receipts_and_current_library() {
    run(Followup::Creation);
}
#[derive(Clone, Copy)]
pub(super) enum Followup {
    Creation,
    Switch,
    Restoration,
}
pub(super) fn run(followup: Followup) {
    let root = isolated_root();
    let fixture = server::Fixture::new();
    fixture.state.lock().unwrap().enable_creation();
    assert!(CloudClient::discover(fixture.server.clone()).is_err());
    assert!(fixture.state.lock().unwrap().requests == 0);
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    let local = model::Snippet::new("Public creation local", "Public creation preserved body");
    model::Library::open(root.clone())
        .unwrap()
        .save(local.clone(), None)
        .unwrap();
    window.server.set_text(fixture.server.for_secure_storage());
    window.email.set_text("fixture@example.invalid");
    press(window.window.upcast_ref(), "Send Sign-in Code");
    wait_work(&window);
    window.code.set_text("123456");
    press(window.window.upcast_ref(), "Sign In");
    wait_work(&window);
    assert!(window.creation_state.get() == Some(CreationState::Available));
    assert!(!window.create_another.is_visible() && !window.sync.is_sensitive());
    let before = images(&root);
    let secrets = protected(&root);
    assert!(secrets.iter().all(Option::is_none));
    let dialog = review(&window, "Create New Cloud Library…");
    press(dialog.upcast_ref(), "Cancel");
    finish(&window);
    assert!(fixture.state.lock().unwrap().creation_counts() == (0, 0));
    assert!(slot(&root, Slot::SpaceCreation).is_none());
    assert!(images(&root) == before && protected(&root) == secrets);
    let _dialog = review(&window, "Create New Cloud Library…");
    parent.present();
    until(
        "native creation focus loss did not cancel confirmation",
        || parent.is_active() && window.snapshot_dialog.borrow().is_none() && !window.busy.get(),
    );
    assert!(fixture.state.lock().unwrap().creation_counts() == (0, 0));
    assert!(slot(&root, Slot::SpaceCreation).is_none());
    assert!(images(&root) == before && protected(&root) == secrets);
    window.window.present();
    until("native creation window did not regain focus", || {
        window.window.is_active()
    });
    fixture.state.lock().unwrap().lose_next_creation_reply();
    let dialog = review(&window, "Create New Cloud Library…");
    press(dialog.upcast_ref(), "Create Library");
    finish(&window);
    assert!(fixture.state.lock().unwrap().creation_counts() == (1, 1));
    assert!(window.creation_state.get() == Some(CreationState::Requested));
    assert!(window.create.label().as_deref() == Some("Resume Library Creation"));
    assert!(!window.create_another.is_sensitive() && !window.sync.is_sensitive());
    assert!(creation_entries(&root) == 1);
    assert!(images(&root) == before && protected(&root) == secrets);
    until("ambiguous creation worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    drop(window);

    // A new worker rotates account credentials, then resumes the original
    // request from actual Secret Service, without constructing a new intent.
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(&window);
    assert!(
        window.creation_state.get() == Some(CreationState::Requested),
        "Public fixture reconnect: creation_state={:?}",
        window.creation_state.get()
    );
    press(window.window.upcast_ref(), "Resume Library Creation");
    finish(&window);
    assert!(fixture.state.lock().unwrap().creation_counts() == (2, 1));
    let requests = fixture.state.lock().unwrap().creation_requests();
    assert!(requests[0] == requests[1]);
    assert!(window.creation_state.get() == Some(CreationState::Created));
    assert!(window.libraries.selected() == 1 && !window.sync.is_sensitive());
    assert!(images(&root) == before && protected(&root) == secrets);
    assert!(fixture.state.lock().unwrap().bootstrap_posts == 0);
    press(window.window.upcast_ref(), "Open Created Library");
    finish(&window);
    assert!(fixture.state.lock().unwrap().creation_counts() == (2, 1));
    press(window.window.upcast_ref(), "Set Up / Resume Library Keys");
    wait_work(&window);
    assert!(window.sync.is_sensitive() && fixture.state.lock().unwrap().bootstrap_posts == 1);
    press(window.window.upcast_ref(), "Sync Now");
    wait_work(&window);
    assert!(
        window.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    let (key, salt) = wire_material(&root);
    assert!(uploaded_has(&fixture, &local, &key, &salt));
    assert!(root.join("Sync/journal.bin").is_file());
    let source = images(&root);
    let source_secrets = protected(&root);
    assert!(
        source_secrets[0].is_some() && source_secrets[1].is_some() && source_secrets[3].is_some()
    );
    let counts = {
        let state = fixture.state.lock().unwrap();
        (state.fetches, state.batches, state.bootstrap_posts)
    };
    let first_receipt = slot(&root, Slot::SpaceCreation).unwrap();
    let dialog = review(&window, "Create Another Cloud Library…");
    press(dialog.upcast_ref(), "Cancel");
    finish(&window);
    assert!(slot(&root, Slot::SpaceCreation).is_some_and(|bytes| bytes == first_receipt));
    assert!(images(&root) == source && protected(&root) == source_secrets);
    let dialog = review(&window, "Create Another Cloud Library…");
    press(dialog.upcast_ref(), "Create Library");
    finish(&window);
    assert!(fixture.state.lock().unwrap().creation_counts() == (3, 2));
    let requests = fixture.state.lock().unwrap().creation_requests();
    assert!(requests[0] == requests[1] && requests[2] != requests[0]);
    assert!(creation_entries(&root) == 2);
    assert!(window.creation_state.get() == Some(CreationState::Created));
    assert!(window.libraries.selected() == 2 && !window.sync.is_sensitive());
    assert!(window.switch_candidate.get());
    assert!(images(&root) == source && protected(&root) == source_secrets);
    {
        let state = fixture.state.lock().unwrap();
        assert!((state.fetches, state.batches, state.bootstrap_posts) == counts);
    }
    until("second creation worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    drop(window);

    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(&window);
    assert!(window.libraries.selected() == 0 && !window.sync.is_sensitive());
    press(window.window.upcast_ref(), "Open Created Library");
    finish(&window);
    assert!(window.libraries.selected() == 2 && window.switch_candidate.get());
    assert!(!window.sync.is_sensitive());
    assert!(fixture.state.lock().unwrap().creation_counts() == (3, 2));
    assert!(images(&root) == source && protected(&root) == source_secrets);
    assert!(creation_entries(&root) == 2);
    for name in ["snippets.json", "Sync/journal.bin", "secret-owner.bin"] {
        assert!(fs::metadata(root.join(name)).unwrap().permissions().mode() & 0o777 == 0o600);
    }
    assert!(fs::metadata(&root).unwrap().permissions().mode() & 0o777 == 0o700);
    assert!(!root.join("automatic-sync.json").exists());
    assert!(CloudClient::discover(fixture.server.clone()).is_err());
    if matches!(followup, Followup::Switch | Followup::Restoration) {
        super::switching::run(&window, &app, &parent, &root, &fixture, &pam, &local);
    }
    if matches!(followup, Followup::Restoration) {
        let restored = make_window(&app, &parent, &root, &fixture, &pam);
        let restored_stop = Stop(restored.clone());
        super::restoration_live::run(&restored, &app, &parent, &root, &fixture, &pam, &local);
        until("final restoration worker did not drain", || {
            restored.prepare_quit()
        });
        drop(restored_stop);
    }
    until("final creation worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    parent.destroy();
    println!(
        "Native library creation: Cancel/focus refusal, lost TLS reply, same-request restart, explicit key setup and encrypted sync, separate second library, exact active keys/checkpoint, retained receipts and fresh-worker review gate passed."
    );
}
