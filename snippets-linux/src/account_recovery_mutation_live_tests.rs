//! Fresh native recovery replacement, retained signed restart and offline recovery.
use super::*;
use crate::bootstrap::{self, RecoveryKit};

fn counts(fixture: &server::Fixture) -> (usize, usize, usize) {
    fixture
        .state
        .lock()
        .unwrap()
        .pairing
        .as_ref()
        .unwrap()
        .recovery_counts()
}
fn evidence(fixture: &server::Fixture) -> (u64, Vec<u8>) {
    fixture.state.lock().unwrap().recovery_evidence()
}
fn focus(window: &AccountWindow) {
    window.window.present();
    until("native recovery replacement did not regain focus", || {
        window.window.is_active()
    });
}
fn reconnect(window: &Rc<AccountWindow>) {
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(window);
    assert!(window.libraries.selected() == 0);
    window.libraries.set_selected(1);
    wait_work(window);
}
fn resume(window: &Rc<AccountWindow>) {
    press(
        window.window.upcast_ref(),
        "Review and Authorize Retained Operation",
    );
    wait_work(window);
    assert!(window.mutation_authorize.is_sensitive() && !window.mutation_matched.is_visible());
}
fn password(window: &Rc<AccountWindow>) -> (adw::AlertDialog, gtk::PasswordEntry) {
    press(
        window.window.upcast_ref(),
        "Authorize Recovery Replacement…",
    );
    until("native recovery replacement password did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Authorize Recovery Replacement"));
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(
        dialog
            .body()
            .contains("previous copy no longer opens the current recovery envelope")
    );
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
fn finished(window: &AccountWindow, entry: &gtk::PasswordEntry) {
    wait_work(window);
    assert!(window.password_dialog.borrow().is_none() && entry.text().is_empty());
    assert!(!window.mutation_authorize.is_sensitive());
}
fn show(window: &Rc<AccountWindow>) -> (RecoveryKit, Zeroizing<String>) {
    authorize(window, "Public fictional password", "Authorize");
    until("native replacement recovery visual did not map", || {
        window.view.area.is_mapped() && window.view.value.borrow().is_some()
    });
    let view = window.view.value.borrow();
    let disclosure = &view.as_ref().unwrap().disclosure;
    (
        RecoveryKit::decode_secret_qr(disclosure.qr_payload().unwrap()).unwrap(),
        Zeroizing::new(disclosure.long_code().unwrap().to_owned()),
    )
}
fn confirm(window: &Rc<AccountWindow>, code: &str) {
    let normalized = Zeroizing::new(
        code.chars()
            .filter(|c| c.is_alphanumeric())
            .collect::<String>(),
    );
    let suffix = Zeroizing::new(normalized[normalized.len() - 8..].to_owned());
    window.suffix.set_text(&suffix);
    window.recorded.set_active(true);
    press(window.window.upcast_ref(), "Confirm Saved Code");
    wait_work(window);
    assert!(window.view.value.borrow().is_none() && window.suffix.text().is_empty());
    assert!(
        window.status.label()
            == "Recovery code confirmed. The retained presentation has been retired. Keep your offline copy."
    );
}
#[test]
#[ignore = "explicit native recovery replacement with read-only reconciliation; invoke tests/account-live.sh with --recovery-reconcile"]
fn live_recovery_replacement_reconciles_lost_reply() {
    run(true);
}
#[test]
#[ignore = "explicit native recovery replacement with fresh-authorized original-proof replay; invoke tests/account-live.sh with --recovery-retry"]
fn live_recovery_replacement_replays_original_proof() {
    run(false);
}
fn run(reconcile: bool) {
    let root = isolated_root();
    let other_root = root.with_file_name("public-recovery-recipient");
    assert!(other_root.parent() == root.parent() && !other_root.exists());
    let fixture = server::Fixture::new();
    fixture.state.lock().unwrap().enable_pairing();
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    connect_keys(&window, &fixture);
    let local = model::Snippet::new(
        "Public recovery replacement",
        "Public replacement preserved body",
    );
    model::Library::open(root.clone())
        .unwrap()
        .save(local.clone(), None)
        .unwrap();
    press(window.window.upcast_ref(), "Sync Now");
    wait_work(&window);
    let (old_kit, old_code) = show(&window);
    confirm(&window, &old_code);
    let old_remote = evidence(&fixture);
    assert!(old_remote.0 == 1);
    let old_bundle = bootstrap::open_recovery(&old_remote.1, &old_kit).unwrap();
    let key = slot(&root, Slot::LibraryKey).unwrap();
    let bootstrap = slot(&root, Slot::Bootstrap).unwrap();
    let checkpoint_key = slot(&root, Slot::CheckpointKey).unwrap();
    let images = creation::images(&root);
    let remote_record = fixture.state.lock().unwrap().record(local.id).unwrap();
    let data_counts = {
        let state = fixture.state.lock().unwrap();
        (state.fetches, state.batches)
    };
    press(window.window.upcast_ref(), "Replace Recovery Code…");
    wait_work(&window);
    assert!(
        window.mutation_state.get() == Some((mutations::Kind::Recovery, mutations::Step::Prepared))
    );
    assert!(window.mutation_authorize.is_sensitive() && !window.mutation_matched.is_visible());
    press(window.window.upcast_ref(), "Cancel Unsent Operation");
    wait_work(&window);
    assert!(window.mutation_state.get().is_none() && counts(&fixture) == (0, 0, 0));
    assert!(evidence(&fixture) == old_remote);
    press(window.window.upcast_ref(), "Replace Recovery Code…");
    wait_work(&window);
    let prepared = slot(&root, Slot::KeyMutation).unwrap();
    let unchanged = || {
        assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v == key));
        assert!(slot(&root, Slot::Bootstrap).is_some_and(|v| v == bootstrap));
        assert!(slot(&root, Slot::CheckpointKey).is_some_and(|v| v == checkpoint_key));
        assert!(slot(&root, Slot::KeyMutation).is_some_and(|v| v == prepared));
        assert!(creation::images(&root) == images && evidence(&fixture) == old_remote);
        assert!(counts(&fixture) == (0, 0, 0));
        let state = fixture.state.lock().unwrap();
        assert!(
            (state.fetches, state.batches) == data_counts
                && state.record(local.id).is_some_and(|v| v == remote_record)
        );
    };
    for (value, response) in [
        ("Public fictional password", "Cancel"),
        ("Public incorrect password", "Authorize"),
    ] {
        if window.mutation_target.borrow().is_none() {
            resume(&window);
        }
        let (dialog, entry) = password(&window);
        entry.set_text(value);
        press(dialog.upcast_ref(), response);
        finished(&window, &entry);
        unchanged();
    }
    resume(&window);
    let (_dialog, entry) = password(&window);
    entry.set_text("Public fictional password");
    parent.present();
    until(
        "native replacement credential focus loss did not cancel",
        || parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get(),
    );
    finished(&window, &entry);
    unchanged();
    focus(&window);
    resume(&window);
    fixture
        .state
        .lock()
        .unwrap()
        .pairing
        .as_mut()
        .unwrap()
        .lose_next_recovery_reply();
    let (dialog, entry) = password(&window);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(&window, &entry);
    assert!(
        window.mutation_state.get() == Some((mutations::Kind::Recovery, mutations::Step::Signed))
    );
    assert!(counts(&fixture) == (1, 1, 1));
    let signed = slot(&root, Slot::KeyMutation).unwrap();
    let new_remote = evidence(&fixture);
    assert!(new_remote.0 == 2 && new_remote.1 != old_remote.1);
    assert!(bootstrap::open_recovery(&new_remote.1, &old_kit).is_err());
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v == key));
    assert!(slot(&root, Slot::Bootstrap).is_some_and(|v| v == bootstrap));
    assert!(creation::images(&root) == images);
    until("signed recovery worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    drop(window);
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    reconnect(&window);
    assert!(slot(&root, Slot::KeyMutation).is_some_and(|v| v == signed));
    assert!(
        window.mutation_state.get() == Some((mutations::Kind::Recovery, mutations::Step::Signed))
    );
    if reconcile {
        press(window.window.upcast_ref(), "Check Saved Result");
        wait_work(&window);
    } else {
        resume(&window);
        let (dialog, entry) = password(&window);
        entry.set_text("Public fictional password");
        press(dialog.upcast_ref(), "Authorize");
        finished(&window, &entry);
    }
    assert!(window.mutation_state.get().is_none());
    assert!(
        window.status.label()
            == "Recovery code replaced. Show the pending recovery code and save a new offline copy; the previous copy no longer opens the current recovery envelope."
    );
    let expected = (1, if reconcile { 1 } else { 2 }, 1);
    assert!(counts(&fixture) == expected && evidence(&fixture) == new_remote);
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v == key));
    assert!(slot(&root, Slot::CheckpointKey).is_some_and(|v| v == checkpoint_key));
    assert!(creation::images(&root) == images);
    let (new_kit, new_code) = show(&window);
    assert!(*new_code != *old_code);
    let recovered = bootstrap::open_recovery(&new_remote.1, &new_kit).unwrap();
    assert!(recovered.for_secure_storage() == old_bundle.for_secure_storage());
    assert!(bootstrap::open_recovery(&old_remote.1, &new_kit).is_err());
    confirm(&window, &new_code);
    assert!(slot(&root, Slot::Bootstrap).is_some_and(|v| v != bootstrap));
    window.window.set_visible(false);
    let other = make_window(&app, &parent, &other_root, &fixture, &pam);
    let other_stop = Stop(other.clone());
    other.server.set_text(fixture.server.for_secure_storage());
    other.email.set_text("fixture@example.invalid");
    press(other.window.upcast_ref(), "Send Sign-in Code");
    wait_work(&other);
    other.code.set_text("123456");
    press(other.window.upcast_ref(), "Sign In");
    wait_work(&other);
    assert!(other.libraries.selected() == 0);
    other.libraries.set_selected(1);
    wait_work(&other);
    let before = creation::images(&other_root);
    other.recovery_input.set_text(&old_code);
    press(other.window.upcast_ref(), "Recover Library Key");
    wait_work(&other);
    assert!(other.recovery_input.text().is_empty() && !other.sync.is_sensitive());
    assert!(
        slot(&other_root, Slot::LibraryKey).is_none()
            && slot(&other_root, Slot::Bootstrap).is_none()
    );
    assert!(creation::images(&other_root) == before);
    other.recovery_input.set_text(&new_code);
    press(other.window.upcast_ref(), "Recover Library Key");
    wait_work(&other);
    assert!(other.recovery_input.text().is_empty() && other.sync.is_sensitive());
    assert!(slot(&other_root, Slot::LibraryKey).is_some_and(|v| v == key));
    assert!(creation::images(&other_root) == before);
    assert!(fixture.state.lock().unwrap().bootstrap_posts == 1 && counts(&fixture) == expected);
    {
        let state = fixture.state.lock().unwrap();
        assert!(
            (state.fetches, state.batches) == data_counts
                && state.record(local.id).is_some_and(|v| v == remote_record)
        );
    }
    press(other.window.upcast_ref(), "Sync Now");
    wait_work(&other);
    assert!(local_has(&other_root, &local));
    assert!(
        other.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    assert!(
        fixture
            .state
            .lock()
            .unwrap()
            .record(local.id)
            .is_some_and(|v| v == remote_record)
    );
    assert!(creation::images(&root) == images && local_has(&root, &local));
    until("recovery recipient worker did not drain", || {
        other.prepare_quit()
    });
    drop(other_stop);
    until("completed replacement worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    reconnect(&window);
    assert!(window.sync.is_sensitive() && window.mutation_state.get().is_none());
    assert!(
        window.status.label()
            == "Library key ready. Recovery code already confirmed; keep your offline copy."
    );
    assert!(counts(&fixture) == expected && evidence(&fixture) == new_remote);
    assert!(
        slot(&root, Slot::LibraryKey).is_some_and(|v| v == key)
            && creation::images(&root) == images
    );
    assert!(
        !root.join("automatic-sync.json").exists()
            && !other_root.join("automatic-sync.json").exists()
    );
    assert!(CloudClient::discover(fixture.server.clone()).is_err());
    until("final recovery worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    parent.destroy();
    app.quit();
    println!(
        "Native recovery replacement: fresh private-policy PAM Cancel/denial/focus refusal, committed-but-lost HTTPS acknowledgement, original Signed restart, exact-envelope reconciliation or original-proof authorized replay, new confirmed offline copy, same-key recovery with old-code refusal, encrypted sync and confirmed reconnect passed."
    );
}
