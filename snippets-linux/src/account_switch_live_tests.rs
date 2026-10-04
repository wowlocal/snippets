//! Reviewed native switch between independent public fictional HTTPS libraries.
use super::*;
use crate::{crypto::RootKey, journal::Checkpoint, key_store::history};

fn active(root: &Path) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    [
        Slot::LibraryKey,
        Slot::Bootstrap,
        Slot::PairingRecipient,
        Slot::CheckpointKey,
        Slot::SpaceCreation,
        Slot::KeyMutation,
    ]
    .into_iter()
    .map(|slot_name| slot(root, slot_name))
    .collect()
}
#[track_caller]
fn review(
    window: &Rc<AccountWindow>,
    label: &str,
    heading: &str,
    default: &str,
) -> adw::AlertDialog {
    press(window.window.upcast_ref(), label);
    until("native switch confirmation did not map", || {
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|dialog| dialog.is_mapped())
    });
    let dialog = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some(heading));
    assert!(
        dialog.default_response().as_deref() == Some(default) && dialog.close_response() == default
    );
    dialog
}
fn switch_review(window: &Rc<AccountWindow>) -> adw::AlertDialog {
    let dialog = review(
        window,
        "Review Library Switch…",
        "Switch to the Selected Library?",
        "back",
    );
    assert!(
        dialog
            .body()
            .contains("Keep 1 local records and 0 saved conflict copies")
    );
    assert!(dialog.body().contains("Use a key saved on this computer"));
    dialog
}
fn password(window: &Rc<AccountWindow>) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let dialog = switch_review(window);
    press(dialog.upcast_ref(), "Switch Library");
    until("native switch password confirmation did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(dialog, entry)| dialog.is_mapped() && entry.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Authorize Library Switch"));
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
fn finished(window: &Rc<AccountWindow>, entry: Option<&gtk::PasswordEntry>) {
    wait_work(window);
    assert!(window.snapshot_dialog.borrow().is_none() && window.password_dialog.borrow().is_none());
    if let Some(entry) = entry {
        assert!(entry.text().is_empty());
    }
    assert!(window.worker.can_quit());
}
fn local_password(window: &Rc<AccountWindow>) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let dialog = review(
        window,
        "Finish Saved Switch Offline…",
        "Finish the Saved Switch Offline?",
        "back",
    );
    assert!(dialog.body().contains("No server is contacted"));
    press(dialog.upcast_ref(), "Finish Locally");
    until("native offline completion password did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(dialog, entry)| dialog.is_mapped() && entry.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Authorize Local Switch Completion"));
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
fn finish_offline(
    owned: (Rc<AccountWindow>, Stop),
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
) -> (Rc<AccountWindow>, Stop) {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let (window, stop) = owned;
    let pending = slot(root, Slot::AccountReview).unwrap();
    let document: serde_json::Value = serde_json::from_slice(&pending).unwrap();
    let entry = &document["entries"][0];
    assert!(document["entries"].as_array().unwrap().len() == 1 && entry["phase"] == "pending");
    let target = Zeroizing::new(
        STANDARD
            .decode(entry["targetKey"].as_str().unwrap())
            .unwrap(),
    );
    let bootstrap = Zeroizing::new(
        STANDARD
            .decode(entry["targetBootstrap"].as_str().unwrap())
            .unwrap(),
    );
    let saved = creation::images(root);
    let slots = active(root);
    assert!(slots[0].as_ref().is_some_and(|key| *key != target));
    let requests = {
        let mut state = fixture.state.lock().unwrap();
        state.offline = true;
        state.requests
    };
    assert_eq!(creation::account_workers(), 1);
    until("interrupted switch worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    drop(window);
    until("interrupted switch worker did not terminate", || {
        creation::account_workers() == 0
    });
    let window = make_window(app, parent, root, fixture, pam);
    let stop = Stop(window.clone());
    assert_eq!(creation::account_workers(), 1);
    assert!(window.switch_state.get().pending && !window.sync.is_sensitive());
    let unchanged = || {
        assert!(active(root) == slots && creation::images(root) == saved);
        assert!(slot(root, Slot::AccountReview).is_some_and(|value| value == pending));
        assert!(window.switch_state.get().pending && !window.sync.is_sensitive());
        assert_eq!(fixture.state.lock().unwrap().requests, requests);
    };
    let dialog = review(
        &window,
        "Finish Saved Switch Offline…",
        "Finish the Saved Switch Offline?",
        "back",
    );
    press(dialog.upcast_ref(), "Keep Saved Switch");
    finished(&window, None);
    unchanged();
    for (value, response) in [
        ("Public fictional password", "Cancel"),
        ("Public incorrect password", "Authorize"),
    ] {
        let (dialog, entry) = local_password(&window);
        entry.set_text(value);
        press(dialog.upcast_ref(), response);
        finished(&window, Some(&entry));
        unchanged();
    }
    let (_dialog, entry) = local_password(&window);
    entry.set_text("Public fictional password");
    parent.present();
    until(
        "native offline credential focus loss did not cancel",
        || parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get(),
    );
    finished(&window, Some(&entry));
    unchanged();
    window.window.present();
    until("native offline completion did not regain focus", || {
        window.window.is_active()
    });
    let (dialog, entry) = local_password(&window);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(&window, Some(&entry));
    assert!(!window.switch_state.get().pending && !window.sync.is_sensitive());
    assert!(slot(root, Slot::LibraryKey).is_some_and(|key| key == target));
    assert!(slot(root, Slot::Bootstrap).is_some_and(|value| value == bootstrap));
    assert!(creation::images(root) == saved);
    assert_eq!(fixture.state.lock().unwrap().requests, requests);
    let (_, catalog) = checkpoint_and_history(root);
    assert!(
        catalog.switches.len() == 1 && catalog.switches[0].phase == history::SwitchPhase::Completed
    );
    fixture.state.lock().unwrap().offline = false;
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(&window);
    assert!(window.libraries.selected() == 0 && !window.sync.is_sensitive());
    window.libraries.set_selected(2);
    wait_work(&window);
    assert!(window.sync.is_sensitive() && !window.switch_candidate.get());
    assert!(creation::images(root) == saved);
    assert!(slot(root, Slot::LibraryKey).is_some_and(|key| key == target));
    println!(
        "Native published switch: before-key activation interruption, old worker termination, fresh offline worker, Cancel/PAM denial/focus refusal preserve exact intent; fresh PAM completes the saved target without HTTP, then explicit reconnect/selection admits sync."
    );
    (window, stop)
}
pub(super) fn checkpoint_and_history(root: &Path) -> (Checkpoint, history::Catalog) {
    let root = root.to_owned();
    let (sender, receiver) = mpsc::channel();
    let worker = thread::spawn(move || {
        let mut store = Store::load(&root, Native::new().unwrap()).unwrap();
        let catalog = history::inspect(&mut store).unwrap();
        let checkpoint = store
            .transaction_with::<_, crate::secret_store::Failure>(|owner| {
                let binding = crate::key_store::installed_binding_locked(owner)
                    .unwrap()
                    .unwrap();
                let material = owner.checkpoint_material(false)?.unwrap();
                let key = RootKey::from_bytes(&material[..32]).unwrap();
                let salt = material[32..].try_into().unwrap();
                // Read only the protected history and encrypted checkpoint,
                // including when a pending primary transaction fences readers.
                let library = model::Library::prepare(root.clone()).unwrap();
                Ok(Checkpoint::load(&library, &key, &salt, binding.checkpoint_scope()).unwrap())
            })
            .unwrap();
        sender.send((checkpoint, catalog)).unwrap();
    });
    until("private switch history inspection did not finish", || {
        worker.is_finished()
    });
    worker.join().unwrap();
    receiver.recv().unwrap()
}

#[test]
#[ignore = "explicit native two-library GTK/HTTPS/private-keyring/private-PAM acceptance; invoke tests/account-live.sh with --switch"]
fn live_reviewed_library_switch_keeps_source_history_and_reconnects() {
    creation::run(creation::Followup::Switch);
}
pub(super) fn run(
    owned: (Rc<AccountWindow>, Stop, bool),
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
    local: &model::Snippet,
) -> (Rc<AccountWindow>, Stop) {
    let (mut window, mut stop, interrupt) = owned;
    if interrupt {
        window.worker.interrupt_next_handover_activation();
    }
    let source_id = uuid::Uuid::from_u128(200);
    let target_id = uuid::Uuid::from_u128(201);
    let source = creation::images(root);
    let source_active = active(root);
    let source_record = fixture
        .state
        .lock()
        .unwrap()
        .record_in(source_id, local.id)
        .unwrap();
    let (old_key, old_salt) = wire_material(root);
    assert!(
        fixture
            .state
            .lock()
            .unwrap()
            .record_in(target_id, local.id)
            .is_none()
    );
    assert!(window.switch_candidate.get() && !window.sync.is_sensitive());
    assert!(slot(root, Slot::BootstrapCandidate).is_none());
    let dialog = review(
        &window,
        "Create First Keys for Empty Library…",
        "Create First Keys for the Selected Library?",
        "cancel",
    );
    press(dialog.upcast_ref(), "Cancel");
    finished(&window, None);
    assert!(fixture.state.lock().unwrap().bootstrap_posts == 1);
    assert!(active(root) == source_active && creation::images(root) == source);
    assert!(slot(root, Slot::BootstrapCandidate).is_none());
    let dialog = review(
        &window,
        "Create First Keys for Empty Library…",
        "Create First Keys for the Selected Library?",
        "cancel",
    );
    press(dialog.upcast_ref(), "Create Keys");
    finished(&window, None);
    assert!(fixture.state.lock().unwrap().bootstrap_posts == 2);
    assert!(matches!(
        window.bootstrap_state.get(),
        Some(crate::key_store::initial_candidate::Status::Ready { .. })
    ));
    assert!(slot(root, Slot::BootstrapCandidate).is_some());
    assert!(active(root) == source_active && creation::images(root) == source);
    assert!(!window.sync.is_sensitive());
    let data_counts = {
        let state = fixture.state.lock().unwrap();
        (state.fetches, state.batches)
    };
    let unchanged = || {
        assert!(active(root) == source_active && creation::images(root) == source);
        assert!(slot(root, Slot::AccountReview).is_none());
        assert!(
            window.switch_candidate.get()
                && !window.switch_state.get().pending
                && !window.sync.is_sensitive()
        );
        let state = fixture.state.lock().unwrap();
        assert!((state.fetches, state.batches) == data_counts);
        assert!(
            state
                .record_in(source_id, local.id)
                .is_some_and(|record| record == source_record)
        );
        assert!(state.record_in(target_id, local.id).is_none());
    };
    let dialog = switch_review(&window);
    press(dialog.upcast_ref(), "Cancel");
    finished(&window, None);
    unchanged();
    let _dialog = switch_review(&window);
    parent.present();
    until("native switch review focus loss did not cancel", || {
        parent.is_active() && window.snapshot_dialog.borrow().is_none() && !window.busy.get()
    });
    unchanged();
    window.window.present();
    until("native switch window did not regain focus", || {
        window.window.is_active()
    });
    for (value, response) in [
        ("Public fictional password", "Cancel"),
        ("Public incorrect password", "Authorize"),
    ] {
        let (dialog, entry) = password(&window);
        entry.set_text(value);
        press(dialog.upcast_ref(), response);
        finished(&window, Some(&entry));
        unchanged();
    }
    let (_dialog, entry) = password(&window);
    entry.set_text("Public fictional password");
    parent.present();
    until("native switch credential focus loss did not cancel", || {
        parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get()
    });
    finished(&window, Some(&entry));
    unchanged();
    window.window.present();
    until("native switch credentials did not regain focus", || {
        window.window.is_active()
    });
    let (dialog, entry) = password(&window);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(&window, Some(&entry));
    assert_eq!(window.switch_state.get().pending, interrupt);
    if interrupt {
        assert!(active(root) == source_active);
        assert!(creation::images(root)[..2] == source[..2]);
        assert!(creation::images(root)[2] != source[2]);
        (window, stop) = finish_offline((window, stop), app, parent, root, fixture, pam);
    }
    assert!(
        window.sync.is_sensitive()
            && !window.switch_state.get().pending
            && window.switch_state.get().retained_libraries == 1
    );
    assert!(slot(root, Slot::LibraryKey).is_some_and(|key| Some(key) != source_active[0]));
    assert!(creation::images(root)[..2] == source[..2]);
    assert!(creation::images(root)[2] != source[2]);
    let (checkpoint, catalog) = checkpoint_and_history(root);
    assert!(checkpoint.journal.agreed_envelopes().is_empty());
    assert!(
        checkpoint.journal.inbox.cursor().is_none() && !checkpoint.journal.inbox.has_pending_page()
    );
    assert!(checkpoint.journal.outbound.is_none() && checkpoint.journal.key_epoch == Some(1));
    assert!(
        catalog
            .active
            .as_ref()
            .is_some_and(|library| library.id() == target_id)
    );
    assert!(catalog.switches.len() == 1);
    let saved = &catalog.switches[0];
    assert!(saved.phase == history::SwitchPhase::Completed && saved.previous.creation);
    assert!(saved.source.library.id() == source_id && !saved.source.active);
    assert!(saved.target.library.id() == target_id && saved.target.active);
    assert!(saved.summary.local_records == 1 && saved.summary.previous_confirmations == 1);
    assert!(local_has(root, local));
    {
        let state = fixture.state.lock().unwrap();
        assert!((state.fetches, state.batches) == data_counts);
        assert!(
            state
                .record_in(source_id, local.id)
                .is_some_and(|record| record == source_record)
        );
        assert!(state.record_in(target_id, local.id).is_none());
    }
    let (key, salt) = wire_material(root);
    press(window.window.upcast_ref(), "Sync Now");
    wait_work(&window);
    assert!(
        window.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    let target_record = fixture
        .state
        .lock()
        .unwrap()
        .record_in(target_id, local.id)
        .unwrap();
    assert!(target_record.blob != source_record.blob);
    assert!(target_record.open(&old_key, &old_salt).is_err());
    let decoded = target_record.open(&key, &salt).unwrap();
    assert!(
        decoded
            .fields
            .as_ref()
            .is_some_and(|fields| fields.content.as_slice() == local.content.as_bytes())
    );
    assert!(local_has(root, local));
    assert!(
        fixture
            .state
            .lock()
            .unwrap()
            .record_in(source_id, local.id)
            .is_some_and(|record| record == source_record)
    );
    press(window.window.upcast_ref(), "Library Recovery History…");
    until("native completed-switch history did not map", || {
        window
            .history_dialog
            .borrow()
            .as_ref()
            .is_some_and(|dialog| dialog.is_mapped())
    });
    assert!(window.history_dialog.borrow().as_ref().unwrap().title() == "Library Recovery History");
    let history_dialog = window.history_dialog.borrow().clone().unwrap();
    assert!(history_dialog.close());
    until("native completed-switch history did not close", || {
        window.history_dialog.borrow().is_none()
    });
    let completed = creation::images(root);
    let current = slot(root, Slot::LibraryKey).unwrap();
    until("completed native switch worker did not drain", || {
        window.prepare_quit()
    });
    window.window.destroy();
    let reopened = make_window(app, parent, root, fixture, pam);
    let reopened_stop = Stop(reopened.clone());
    press(reopened.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(&reopened);
    assert!(reopened.libraries.selected() == 0 && !reopened.sync.is_sensitive());
    reopened.libraries.set_selected(2);
    wait_work(&reopened);
    assert!(
        reopened.sync.is_sensitive()
            && !reopened.switch_candidate.get()
            && !reopened.switch_state.get().pending
    );
    assert!(slot(root, Slot::LibraryKey).is_some_and(|bytes| bytes == current));
    assert!(creation::images(root) == completed && local_has(root, local));
    let (_, catalog) = checkpoint_and_history(root);
    assert!(
        catalog.switches.len() == 1 && catalog.switches[0].phase == history::SwitchPhase::Completed
    );
    assert!(fixture.state.lock().unwrap().creation_counts() == (3, 2));
    assert!(fixture.state.lock().unwrap().bootstrap_posts == 2);
    reopened.libraries.set_selected(1);
    wait_work(&reopened);
    assert!(reopened.switch_candidate.get() && !reopened.sync.is_sensitive());
    let (dialog, entry) = password(&reopened);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(&reopened, Some(&entry));
    assert!(
        reopened.sync.is_sensitive()
            && !reopened.switch_state.get().pending
            && reopened.switch_state.get().retained_libraries == 2
    );
    assert!(slot(root, Slot::LibraryKey) == source_active[0]);
    assert!(creation::images(root)[..2] == completed[..2] && local_has(root, local));
    let (checkpoint, catalog) = checkpoint_and_history(root);
    assert!(checkpoint.journal.agreed_envelopes().is_empty());
    assert!(
        checkpoint.journal.inbox.cursor().is_none() && !checkpoint.journal.inbox.has_pending_page()
    );
    assert!(checkpoint.journal.outbound.is_none());
    assert!(
        catalog
            .active
            .as_ref()
            .is_some_and(|library| library.id() == source_id)
    );
    assert!(catalog.switches.len() == 2);
    assert!(
        catalog
            .switches
            .iter()
            .all(|entry| entry.phase == history::SwitchPhase::Completed)
    );
    let saved = &catalog.switches[0];
    assert!(saved.source.library.id() == source_id && saved.source.active);
    assert!(saved.target.library.id() == target_id && !saved.target.active);
    let saved = &catalog.switches[1];
    assert!(saved.source.library.id() == target_id && !saved.source.active);
    assert!(saved.target.library.id() == source_id && saved.target.active);
    {
        let state = fixture.state.lock().unwrap();
        assert!(
            state
                .record_in(source_id, local.id)
                .is_some_and(|wire| wire == source_record)
        );
        assert!(
            state
                .record_in(target_id, local.id)
                .is_some_and(|wire| wire == target_record)
        );
    }
    press(reopened.window.upcast_ref(), "Sync Now");
    wait_work(&reopened);
    assert!(
        reopened.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    let state = fixture.state.lock().unwrap();
    let returned = state.record_in(source_id, local.id).unwrap();
    let decoded = returned.open(&old_key, &old_salt).unwrap();
    assert!(
        decoded
            .fields
            .as_ref()
            .is_some_and(|fields| fields.content.as_slice() == local.content.as_bytes())
    );
    assert!(returned.open(&key, &salt).is_err());
    assert!(
        state
            .record_in(target_id, local.id)
            .is_some_and(|wire| wire == target_record)
    );
    assert!(state.creation_counts() == (3, 2) && state.bootstrap_posts == 2);
    drop(state);
    assert!(local_has(root, local));
    until("reopened native switch worker did not drain", || {
        reopened.prepare_quit()
    });
    drop(reopened_stop);
    println!(
        "Native reviewed switch: separately retained first-key setup, review/password Cancel and focus refusal, real private-policy PAM denial/approval, exact old library preservation, target checkpoint reset, completed protected history, explicit new-key encrypted sync, fresh-worker reconnect and reverse switch using the exact saved source key passed."
    );
    (window, stop)
}
