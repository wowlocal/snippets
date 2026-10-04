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
            && dialog.body().contains("account 0F1E-2D3C")
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

fn account_workers() -> usize {
    fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            fs::read_to_string(entry.path().join("comm"))
                .is_ok_and(|name| name.trim() == "snippets-accoun")
        })
        .count()
}

fn resume_initial_keys(
    window: Rc<AccountWindow>,
    stop: Stop,
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
) -> (Rc<AccountWindow>, Stop) {
    assert!(!window.sync.is_sensitive());
    let before = images(root);
    let pending = slot(root, Slot::Bootstrap).unwrap();
    let parsed = crate::canonical::parse(&pending).unwrap();
    let draft = parsed.as_object().unwrap()["pending"].as_object().unwrap();
    assert_eq!(draft["kind"].as_text().unwrap(), "initial");
    let bundle = crate::bootstrap::Bundle::decode(&draft["bundle"].encode().unwrap()).unwrap();
    let kit =
        crate::bootstrap::RecoveryKit::decode_secret_qr(&draft["kit"].encode().unwrap()).unwrap();
    let (version, ciphertext) = fixture.state.lock().unwrap().recovery_evidence();
    assert_eq!(version, 1);
    assert!(
        crate::bootstrap::open_recovery(&ciphertext, &kit)
            .unwrap()
            .for_secure_storage()
            == bundle.for_secure_storage()
    );
    for name in [
        Slot::LibraryKey,
        Slot::CheckpointKey,
        Slot::PairingRecipient,
        Slot::KeyMutation,
        Slot::AccountReview,
        Slot::PairingCandidate,
        Slot::BootstrapCandidate,
    ] {
        assert!(slot(root, name).is_none());
    }
    let counts = {
        let state = fixture.state.lock().unwrap();
        assert!(state.bootstrap_posts == 1 && state.lost_bootstrap_replies == 1);
        (state.fetches, state.batches)
    };
    assert_eq!(account_workers(), 1);
    until("interrupted first-key worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    drop(window);
    until("interrupted first-key worker did not terminate", || {
        account_workers() == 0
    });
    let window = make_window(app, parent, root, fixture, pam);
    let stop = Stop(window.clone());
    assert_eq!(account_workers(), 1);
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(&window);
    press(window.window.upcast_ref(), "Open Created Library");
    finish(&window);
    assert!(window.libraries.selected() == 1 && !window.sync.is_sensitive());
    assert!(slot(root, Slot::Bootstrap).is_some_and(|saved| saved == pending));
    assert!(slot(root, Slot::LibraryKey).is_none() && slot(root, Slot::CheckpointKey).is_none());
    assert!(images(root) == before);
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.bootstrap_posts == 1 && state.lost_bootstrap_replies == 1);
        assert!((state.fetches, state.batches) == counts);
        assert!(state.recovery_evidence() == (version, ciphertext.clone()));
    }
    press(window.window.upcast_ref(), "Set Up / Resume Library Keys");
    wait_work(&window);
    assert!(window.sync.is_sensitive() && images(root) == before);
    let installed = slot(root, Slot::LibraryKey).unwrap();
    let installed = crate::canonical::parse(&installed).unwrap();
    let installed_bundle = crate::bootstrap::Bundle::decode(
        &installed.as_object().unwrap()["bundle"].encode().unwrap(),
    )
    .unwrap();
    assert!(installed_bundle.for_secure_storage() == bundle.for_secure_storage());
    let saved = slot(root, Slot::Bootstrap).unwrap();
    let saved = crate::canonical::parse(&saved).unwrap();
    let saved = saved.as_object().unwrap();
    assert!(matches!(saved["pending"], crate::canonical::Value::Null));
    let presentation = saved["presentation"].as_object().unwrap();
    assert!(presentation["kit"] == draft["kit"]);
    assert!(presentation["ciphertext"] == draft["ciphertext"]);
    assert!(presentation["version"] == draft["version"]);
    assert_eq!(
        presentation["status"].as_text().unwrap(),
        "awaiting_presentation"
    );
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.bootstrap_posts == 1 && state.lost_bootstrap_replies == 1);
        assert!((state.fetches, state.batches) == counts);
        assert!(state.recovery_evidence() == (version, ciphertext));
    }
    assert!(slot(root, Slot::CheckpointKey).is_none());
    println!(
        "Native first-key lost TLS response: real server acceptance, exact private pending key/recovery capability, terminal old worker, fresh reconnect gate and explicit same-key continuation without another POST or data-plane mutation passed; public fixtures only."
    );
    (window, stop)
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
    SecureRestoration,
    ForeignRestoration,
    ExternalRestoration(super::secure_restoration_live::files::Kind),
    MixedRestoration(super::secure_restoration_live::mixed::Mode),
    SecureRestorationInterrupted(crate::account_worker::RestorationInterruption),
}
pub(super) fn run(followup: Followup) {
    // Rust's test harness does not run GApplication with argv. GTK's real
    // chooser still needs application identity for the private Recent store.
    glib::set_prgname(Some("snippets-public-account-fixture"));
    glib::set_application_name("Snippets Public Account Fixture");
    let _portal = super::portal::Bridge::optional();
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
    create_account(&window, &fixture);
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
    if matches!(followup, Followup::Creation) {
        fixture.state.lock().unwrap().lose_next_bootstrap_reply = true;
    }
    press(window.window.upcast_ref(), "Set Up / Resume Library Keys");
    wait_work(&window);
    let (window, stop) = if matches!(followup, Followup::Creation) {
        assert!(images(&root) == before);
        resume_initial_keys(window, stop, &app, &parent, &root, &fixture, &pam)
    } else {
        (window, stop)
    };
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
    if matches!(
        followup,
        Followup::Switch
            | Followup::Restoration
            | Followup::SecureRestoration
            | Followup::ForeignRestoration
            | Followup::ExternalRestoration(_)
            | Followup::MixedRestoration(_)
            | Followup::SecureRestorationInterrupted(_)
    ) {
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
    if matches!(followup, Followup::SecureRestoration) {
        let restored = make_window(&app, &parent, &root, &fixture, &pam);
        let restored_stop = Stop(restored.clone());
        super::secure_restoration_live::run(
            &restored, &app, &parent, &root, &fixture, &pam, &local,
        );
        until("final secure restoration worker did not drain", || {
            restored.prepare_quit()
        });
        drop(restored_stop);
    }
    if matches!(followup, Followup::ForeignRestoration) {
        let restored = make_window(&app, &parent, &root, &fixture, &pam);
        let restored_stop = Stop(restored.clone());
        super::secure_restoration_live::run_foreign(
            &restored, &app, &parent, &root, &fixture, &pam, &local,
        );
        until(
            "final foreign-vault restoration worker did not drain",
            || restored.prepare_quit(),
        );
        drop(restored_stop);
    }
    if let Followup::SecureRestorationInterrupted(boundary) = followup {
        let restored = make_window(&app, &parent, &root, &fixture, &pam);
        let restored_stop = Stop(restored.clone());
        super::secure_restoration_live::run_interrupted(
            &restored,
            &app,
            &parent,
            &root,
            &fixture,
            &pam,
            &local,
            Some(boundary),
        );
        until("final interrupted restoration worker did not drain", || {
            restored.prepare_quit()
        });
        drop(restored_stop);
    }
    if let Followup::ExternalRestoration(kind) = followup {
        let restored = make_window(&app, &parent, &root, &fixture, &pam);
        let restored_stop = Stop(restored.clone());
        super::secure_restoration_live::run_external(
            &restored, &app, &parent, &root, &fixture, &pam, &local, kind,
        );
        until(
            "final external-vault restoration worker did not drain",
            || restored.prepare_quit(),
        );
        drop(restored_stop);
    }
    if let Followup::MixedRestoration(mode) = followup {
        let restored = make_window(&app, &parent, &root, &fixture, &pam);
        let restored_stop = Stop(restored.clone());
        super::secure_restoration_live::run_mixed(
            &restored, &app, &parent, &root, &fixture, &pam, &local, mode,
        );
        until("final mixed-vault restoration worker did not drain", || {
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
