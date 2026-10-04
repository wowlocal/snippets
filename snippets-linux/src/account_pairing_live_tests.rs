//! Two independent native installations; only public invitation crosses between them.
use super::*;

fn focus(window: &AccountWindow) {
    window.window.present();
    until("native pairing window did not acquire focus", || {
        window.window.is_active()
    });
}
fn sign_in(window: &Rc<AccountWindow>, fixture: &server::Fixture) {
    sign_in_saved_key(window, fixture);
    assert!(window.libraries.selected() == 0 && !window.library_panel.is_sensitive());
    window.libraries.set_selected(1);
    wait_work(window);
}
fn counts(fixture: &server::Fixture) -> (usize, usize, usize, usize, usize, usize) {
    fixture
        .state
        .lock()
        .unwrap()
        .pairing
        .as_ref()
        .unwrap()
        .counts()
}
fn invitation(window: &AccountWindow) -> Invitation {
    until("native public invitation did not map", || {
        window.pairing_view.area.is_mapped() && window.pairing_view.value.borrow().is_some()
    });
    // The view holds only the public payload it draws, for pairing invitations
    // and device sign-in requests alike; decode exactly what it shows.
    let payload = window
        .pairing_view
        .value
        .borrow()
        .as_ref()
        .unwrap()
        .payload
        .clone();
    Invitation::decode_retained_qr(&payload).unwrap()
}
fn prepared(window: &AccountWindow, invitation: &Invitation) {
    assert!(
        window.mutation_state.get() == Some((mutations::Kind::Approval, mutations::Step::Prepared))
    );
    assert!(
        window.mutation_code.label()
            == format!("Confirmation code: {}", invitation.confirmation_code())
    );
    assert!(!window.mutation_matched.is_active() && !window.mutation_authorize.is_sensitive());
}
fn resume(window: &Rc<AccountWindow>, invitation: &Invitation) {
    press(
        window.window.upcast_ref(),
        "Review and Authorize Retained Operation",
    );
    wait_work(window);
    assert!(
        window.mutation_code.label()
            == format!("Confirmation code: {}", invitation.confirmation_code())
    );
    assert!(!window.mutation_matched.is_active() && !window.mutation_authorize.is_sensitive());
    window.mutation_matched.set_active(true);
    assert!(window.mutation_authorize.is_sensitive());
}
fn password(window: &Rc<AccountWindow>) -> (adw::AlertDialog, gtk::PasswordEntry) {
    press(window.window.upcast_ref(), "Authorize Device Approval…");
    until("native device-approval password did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Authorize Device Approval"));
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
fn finished(window: &AccountWindow, entry: &gtk::PasswordEntry) {
    wait_work(window);
    assert!(window.password_dialog.borrow().is_none() && entry.text().is_empty());
    assert!(!window.mutation_authorize.is_sensitive() && !window.mutation_matched.is_active());
}
fn reconnect(window: &Rc<AccountWindow>) {
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(window);
    assert!(window.libraries.selected() == 0);
    window.libraries.set_selected(1);
    wait_work(window);
}

#[test]
#[ignore = "explicit two-installation native pairing/approval GTK/HTTPS/private-keyring/private-PAM acceptance; invoke tests/account-live.sh with --pairing"]
fn live_device_pairing_and_signed_approval_restart() {
    let root = isolated_root();
    let recipient_root = root.with_file_name("public-pairing-recipient");
    assert!(!recipient_root.exists() && recipient_root.parent() == root.parent());
    let fixture = server::Fixture::new();
    fixture.state.lock().unwrap().enable_pairing();
    assert!(CloudClient::discover(fixture.server.clone()).is_err());
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    let trusted = make_window(&app, &parent, &root, &fixture, &pam);
    let trusted_stop = Stop(trusted.clone());
    connect_keys(&trusted, &fixture);
    let local = model::Snippet::new("Public pairing local", "Public pairing preserved body");
    model::Library::open(root.clone())
        .unwrap()
        .save(local.clone(), None)
        .unwrap();
    press(trusted.window.upcast_ref(), "Sync Now");
    wait_work(&trusted);
    let original_key = slot(&root, Slot::LibraryKey).unwrap();
    let original_bootstrap = slot(&root, Slot::Bootstrap).unwrap();
    let original_images = creation::images(&root);
    let original_wire = fixture.state.lock().unwrap().record(local.id).unwrap();
    trusted.window.set_visible(false);
    let recipient = make_window(&app, &parent, &recipient_root, &fixture, &pam);
    let recipient_stop = Stop(recipient.clone());
    sign_in(&recipient, &fixture);
    assert!(!recipient.sync.is_sensitive() && slot(&recipient_root, Slot::LibraryKey).is_none());
    let recipient_images = creation::images(&recipient_root);
    press(
        recipient.window.upcast_ref(),
        "Pair This Computer with a Trusted Device",
    );
    wait_work(&recipient);
    let cancelled = invitation(&recipient);
    assert!(
        recipient.pairing_code.label()
            == format!("Confirmation code: {}", cancelled.confirmation_code())
    );
    assert!(slot(&recipient_root, Slot::PairingRecipient).is_some());
    press(recipient.window.upcast_ref(), "Check Approval");
    wait_work(&recipient);
    assert!(slot(&recipient_root, Slot::LibraryKey).is_none() && !recipient.sync.is_sensitive());
    press(recipient.window.upcast_ref(), "Cancel Invitation");
    wait_work(&recipient);
    assert!(
        recipient.pairing_view.value.borrow().is_none()
            && recipient.pairing_code.label().is_empty()
    );
    assert!(creation::images(&recipient_root) == recipient_images);
    assert!(counts(&fixture) == (1, 1, 0, 0, 0, 0));
    press(
        recipient.window.upcast_ref(),
        "Pair This Computer with a Trusted Device",
    );
    wait_work(&recipient);
    let public = invitation(&recipient);
    assert!(public.pairing() != cancelled.pairing());
    let payload = public.encode_qr().unwrap();
    let pending = slot(&recipient_root, Slot::PairingRecipient).unwrap();
    until("first recipient worker did not drain", || {
        recipient.prepare_quit()
    });
    drop(recipient_stop);
    drop(recipient);
    let recipient = make_window(&app, &parent, &recipient_root, &fixture, &pam);
    let recipient_stop = Stop(recipient.clone());
    reconnect(&recipient);
    assert!(
        invitation(&recipient) == public
            && slot(&recipient_root, Slot::PairingRecipient).is_some_and(|v| v == pending)
    );
    assert!(
        counts(&fixture) == (2, 1, 0, 0, 0, 0) && slot(&recipient_root, Slot::LibraryKey).is_none()
    );
    recipient.window.set_visible(false);
    focus(&trusted);
    trusted.approval_input.set_text("Public invalid invitation");
    press(trusted.window.upcast_ref(), "Review Device Invitation");
    wait_work(&trusted);
    assert!(trusted.approval_input.text().is_empty() && slot(&root, Slot::KeyMutation).is_none());
    trusted
        .approval_input
        .set_text(std::str::from_utf8(&payload).unwrap());
    press(trusted.window.upcast_ref(), "Review Device Invitation");
    wait_work(&trusted);
    prepared(&trusted, &public);
    trusted.mutation_authorize.emit_clicked();
    assert!(!trusted.busy.get() && counts(&fixture) == (2, 1, 0, 0, 0, 0));
    press(trusted.window.upcast_ref(), "Cancel Unsent Operation");
    wait_work(&trusted);
    assert!(trusted.mutation_state.get().is_none());
    trusted
        .approval_input
        .set_text(std::str::from_utf8(&payload).unwrap());
    press(trusted.window.upcast_ref(), "Review Device Invitation");
    wait_work(&trusted);
    prepared(&trusted, &public);
    let prepared_secret = slot(&root, Slot::KeyMutation).unwrap();
    let unchanged = || {
        assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v == original_key));
        assert!(slot(&root, Slot::Bootstrap).is_some_and(|v| v == original_bootstrap));
        assert!(creation::images(&root) == original_images);
        assert!(slot(&root, Slot::KeyMutation).is_some_and(|v| v == prepared_secret));
        assert!(slot(&recipient_root, Slot::LibraryKey).is_none());
        assert!(creation::images(&recipient_root) == recipient_images);
        assert!(counts(&fixture) == (2, 1, 0, 0, 0, 0));
    };
    trusted.mutation_matched.set_active(true);
    for (value, response) in [
        ("Public fictional password", "Cancel"),
        ("Public incorrect password", "Authorize"),
    ] {
        if trusted.mutation_target.borrow().is_none() {
            resume(&trusted, &public);
        }
        let (dialog, entry) = password(&trusted);
        entry.set_text(value);
        press(dialog.upcast_ref(), response);
        finished(&trusted, &entry);
        unchanged();
    }
    resume(&trusted, &public);
    let (_dialog, entry) = password(&trusted);
    entry.set_text("Public fictional password");
    parent.present();
    until("approval focus loss did not cancel", || {
        parent.is_active() && trusted.password_dialog.borrow().is_none() && !trusted.busy.get()
    });
    finished(&trusted, &entry);
    unchanged();
    focus(&trusted);
    resume(&trusted, &public);
    fixture
        .state
        .lock()
        .unwrap()
        .pairing
        .as_mut()
        .unwrap()
        .lose_next_approval_reply();
    let (dialog, entry) = password(&trusted);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(&trusted, &entry);
    assert!(
        trusted.mutation_state.get() == Some((mutations::Kind::Approval, mutations::Step::Signed))
    );
    assert!(counts(&fixture) == (2, 1, 0, 1, 1, 1));
    let signed = slot(&root, Slot::KeyMutation).unwrap();
    assert!(
        slot(&root, Slot::LibraryKey).is_some_and(|v| v == original_key)
            && creation::images(&root) == original_images
    );
    assert!(slot(&recipient_root, Slot::PairingRecipient).is_some_and(|v| v == pending));
    assert!(slot(&recipient_root, Slot::LibraryKey).is_none());
    press(trusted.window.upcast_ref(), "Check Saved Result");
    wait_work(&trusted);
    assert!(
        trusted.mutation_state.get() == Some((mutations::Kind::Approval, mutations::Step::Signed))
    );
    assert!(
        slot(&root, Slot::KeyMutation).is_some_and(|v| v == signed)
            && counts(&fixture) == (2, 1, 0, 1, 1, 1)
    );
    until("signed trusted-device worker did not drain", || {
        trusted.prepare_quit()
    });
    drop(trusted_stop);
    drop(trusted);
    let trusted = make_window(&app, &parent, &root, &fixture, &pam);
    let trusted_stop = Stop(trusted.clone());
    reconnect(&trusted);
    assert!(slot(&root, Slot::KeyMutation).is_some_and(|v| v == signed));
    resume(&trusted, &public);
    let (dialog, entry) = password(&trusted);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(&trusted, &entry);
    assert!(trusted.mutation_state.get().is_none());
    assert!(
        trusted.status.label() == "Device approved. Finish key installation on the new device."
    );
    assert!(counts(&fixture) == (2, 1, 0, 1, 2, 1));
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v == original_key));
    assert!(slot(&root, Slot::Bootstrap).is_some_and(|v| v == original_bootstrap));
    assert!(creation::images(&root) == original_images);
    assert!(slot(&recipient_root, Slot::LibraryKey).is_none());
    trusted.window.set_visible(false);
    focus(&recipient);
    press(recipient.window.upcast_ref(), "Check Approval");
    wait_work(&recipient);
    assert!(recipient.sync.is_sensitive() && recipient.pairing_view.value.borrow().is_none());
    assert!(slot(&recipient_root, Slot::LibraryKey).is_some_and(|v| v == original_key));
    assert!(creation::images(&recipient_root) == recipient_images);
    assert!(counts(&fixture) == (2, 1, 1, 1, 2, 1));
    assert!(fixture.state.lock().unwrap().bootstrap_posts == 1);
    assert!(
        fs::read(root.join("secret-owner.bin")).unwrap()
            != fs::read(recipient_root.join("secret-owner.bin")).unwrap()
    );
    press(recipient.window.upcast_ref(), "Sync Now");
    wait_work(&recipient);
    assert!(local_has(&recipient_root, &local));
    assert!(
        recipient.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    assert!(
        fixture
            .state
            .lock()
            .unwrap()
            .record(local.id)
            .is_some_and(|v| v == original_wire)
    );
    until("paired recipient worker did not drain", || {
        recipient.prepare_quit()
    });
    drop(recipient_stop);
    drop(recipient);
    let recipient = make_window(&app, &parent, &recipient_root, &fixture, &pam);
    let recipient_stop = Stop(recipient.clone());
    reconnect(&recipient);
    assert!(recipient.sync.is_sensitive() && !recipient.pairing_panel.is_visible());
    assert!(
        slot(&recipient_root, Slot::LibraryKey).is_some_and(|v| v == original_key)
            && local_has(&recipient_root, &local)
    );
    assert!(counts(&fixture) == (2, 1, 1, 1, 2, 1));
    assert!(
        !root.join("automatic-sync.json").exists()
            && !recipient_root.join("automatic-sync.json").exists()
    );
    assert!(CloudClient::discover(fixture.server.clone()).is_err());
    until("final recipient worker did not drain", || {
        recipient.prepare_quit()
    });
    drop(recipient_stop);
    until("final trusted worker did not drain", || {
        trusted.prepare_quit()
    });
    drop(trusted_stop);
    parent.destroy();
    app.quit();
    println!(
        "Native two-installation pairing: public invitation and cancellation, recipient restart, compare-code gate, Cancel/wrong PAM/focus refusal, independent signed challenge/hash verification, committed-but-lost approval receipt, original-proof authorized replay after trusted restart, claimed key installation, encrypted sync and paired reconnect passed."
    );
}
