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

struct CandidateContext<'a> {
    app: &'a adw::Application,
    parent: &'a adw::ApplicationWindow,
    fixture: &'a server::Fixture,
    pam: &'a Pam,
    trusted_root: &'a Path,
    seed_root: &'a Path,
    local: &'a model::Snippet,
}
fn candidate_invitation(window: &AccountWindow) -> Invitation {
    until("native candidate invitation did not map", || {
        window.candidate_view.area.is_mapped() && window.candidate_view.value.borrow().is_some()
    });
    Invitation::decode_retained_qr(
        &window
            .candidate_view
            .value
            .borrow()
            .as_ref()
            .unwrap()
            .payload,
    )
    .unwrap()
}
fn candidate_switch(
    owned: (Rc<AccountWindow>, Stop),
    trusted: &Rc<AccountWindow>,
    c: CandidateContext<'_>,
) -> (Rc<AccountWindow>, Stop) {
    let (seed, seed_stop) = owned;
    let source_id = uuid::Uuid::from_u128(201);
    let target_id = uuid::Uuid::from_u128(2);
    let root = c
        .seed_root
        .with_file_name("public-switch-pairing-recipient");
    assert!(!root.exists() && root.parent() == c.seed_root.parent());
    // Establish A through real creation/key setup, then recover it into a fresh
    // installation. This recipient has never held B, including in history.
    focus(&seed);
    let dialog = switching::review(
        &seed,
        "Create New Cloud Library…",
        "Create New Cloud Library?",
        "cancel",
    );
    press(dialog.upcast_ref(), "Create Library");
    wait_work(&seed);
    assert!(c.fixture.state.lock().unwrap().creation_counts() == (1, 2));
    assert!(seed.libraries.selected() == 2 && seed.switch_candidate.get());
    let dialog = switching::review(
        &seed,
        "Create First Keys for Empty Library…",
        "Create First Keys for the Selected Library?",
        "cancel",
    );
    press(dialog.upcast_ref(), "Create Keys");
    wait_work(&seed);
    let (dialog, entry) = switching::password(&seed);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    switching::finished(&seed, Some(&entry));
    assert!(seed.sync.is_sensitive());
    press(seed.window.upcast_ref(), "Sync Now");
    wait_work(&seed);
    assert!(
        seed.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    let source_key = slot(c.seed_root, Slot::LibraryKey).unwrap();
    authorize(&seed, "Public fictional password", "Authorize");
    until("native A recovery visual did not map", || {
        seed.view.area.is_mapped() && seed.view.value.borrow().is_some()
    });
    let code = Zeroizing::new(
        seed.view
            .value
            .borrow()
            .as_ref()
            .unwrap()
            .disclosure
            .long_code()
            .unwrap()
            .to_owned(),
    );
    until("A seed worker did not drain", || seed.prepare_quit());
    drop(seed_stop);
    drop(seed);
    until("A seed worker did not terminate", || {
        creation::account_workers() == 1
    });
    let recipient = make_window(c.app, c.parent, &root, c.fixture, c.pam);
    let stop = Stop(recipient.clone());
    sign_in_saved_key(&recipient, c.fixture);
    recipient.libraries.set_selected(2);
    wait_work(&recipient);
    recipient.recovery_input.set_text(&code);
    press(recipient.window.upcast_ref(), "Recover Library Key");
    wait_work(&recipient);
    assert!(recipient.recovery_input.text().is_empty() && recipient.sync.is_sensitive());
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|value| value == source_key));
    drop(code);
    press(recipient.window.upcast_ref(), "Sync Now");
    wait_work(&recipient);
    assert!(local_has(&root, c.local));
    assert!(slot(&root, Slot::AccountReview).is_none());
    assert!(slot(&root, Slot::PairingCandidate).is_none());
    assert!(slot(&root, Slot::PairingRecipient).is_none());
    let active = switching::active(&root);
    let images = creation::images(&root);
    let target_key = slot(c.trusted_root, Slot::LibraryKey).unwrap();
    let trusted_images = creation::images(c.trusted_root);
    assert!(active[0].as_ref().is_some_and(|value| *value != target_key));
    let (source_wire, data_counts) = {
        let state = c.fixture.state.lock().unwrap();
        assert!(state.bootstrap_posts == 2);
        (
            state.record_in(source_id, c.local.id).unwrap(),
            (state.fetches, state.batches),
        )
    };
    let unchanged = || {
        assert!(switching::active(&root) == active && creation::images(&root) == images);
        assert!(slot(&root, Slot::AccountReview).is_none());
        assert!(creation::images(c.trusted_root) == trusted_images);
        assert!(slot(c.trusted_root, Slot::LibraryKey).is_some_and(|value| value == target_key));
        let state = c.fixture.state.lock().unwrap();
        assert!((state.fetches, state.batches) == data_counts && state.bootstrap_posts == 2);
        assert!(
            state
                .record_in(source_id, c.local.id)
                .is_some_and(|record| record == source_wire)
        );
    };
    recipient.libraries.set_selected(1);
    wait_work(&recipient);
    assert!(recipient.switch_candidate.get() && !recipient.sync.is_sensitive());
    press(recipient.window.upcast_ref(), "Get Selected Library Key…");
    wait_work(&recipient);
    let cancelled = candidate_invitation(&recipient);
    assert!(cancelled.space() == target_id);
    unchanged();
    press(recipient.candidate_panel.upcast_ref(), "Check Approval");
    wait_work(&recipient);
    unchanged();
    press(recipient.candidate_panel.upcast_ref(), "Cancel Key Request");
    wait_work(&recipient);
    assert!(recipient.candidate_view.value.borrow().is_none());
    unchanged();
    press(recipient.window.upcast_ref(), "Get Selected Library Key…");
    wait_work(&recipient);
    let public = candidate_invitation(&recipient);
    assert!(public.space() == target_id && public.pairing() != cancelled.pairing());
    let pending = slot(&root, Slot::PairingCandidate).unwrap();
    unchanged();
    assert_eq!(creation::account_workers(), 2);
    until("candidate recipient worker did not drain", || {
        recipient.prepare_quit()
    });
    drop(stop);
    drop(recipient);
    until("candidate recipient worker did not terminate", || {
        creation::account_workers() == 1
    });
    let recipient = make_window(c.app, c.parent, &root, c.fixture, c.pam);
    let stop = Stop(recipient.clone());
    reconnect(&recipient);
    assert!(candidate_invitation(&recipient) == public);
    assert!(slot(&root, Slot::PairingCandidate).is_some_and(|value| value == pending));
    assert!(recipient.switch_candidate.get() && !recipient.sync.is_sensitive());
    unchanged();
    recipient.window.set_visible(false);
    focus(trusted);
    trusted
        .approval_input
        .set_text(std::str::from_utf8(&public.encode_qr().unwrap()).unwrap());
    press(trusted.window.upcast_ref(), "Review Device Invitation");
    wait_work(trusted);
    prepared(trusted, &public);
    trusted.mutation_matched.set_active(true);
    let (dialog, entry) = password(trusted);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(trusted, &entry);
    assert!(trusted.mutation_state.get().is_none());
    unchanged();
    trusted.window.set_visible(false);
    focus(&recipient);
    press(recipient.candidate_panel.upcast_ref(), "Check Approval");
    wait_work(&recipient);
    assert!(recipient.switch_candidate.get() && !recipient.sync.is_sensitive());
    assert!(recipient.candidate_view.value.borrow().is_none());
    let ready = slot(&root, Slot::PairingCandidate).unwrap();
    let candidate: serde_json::Value = serde_json::from_slice(&ready).unwrap();
    assert!(candidate["entries"].as_array().unwrap().last().unwrap()["ready"] == true);
    unchanged();
    let dialog = switching::review(
        &recipient,
        "Review Library Switch…",
        "Switch to the Selected Library?",
        "back",
    );
    press(dialog.upcast_ref(), "Cancel");
    switching::finished(&recipient, None);
    assert!(slot(&root, Slot::PairingCandidate).is_some_and(|value| value == ready));
    unchanged();
    let (dialog, entry) = switching::password(&recipient);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    switching::finished(&recipient, Some(&entry));
    assert!(recipient.sync.is_sensitive() && !recipient.switch_state.get().pending);
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|value| value == target_key));
    assert!(creation::images(&root)[..2] == images[..2]);
    let (checkpoint, catalog) = switching::checkpoint_and_history(&root);
    assert!(checkpoint.journal.agreed_envelopes().is_empty());
    assert!(checkpoint.journal.inbox.cursor().is_none() && checkpoint.journal.outbound.is_none());
    assert!(catalog.switches.len() == 1);
    assert!(
        catalog.switches[0].source.library.id() == source_id
            && catalog.switches[0].target.library.id() == target_id
    );
    {
        let state = c.fixture.state.lock().unwrap();
        assert!((state.fetches, state.batches) == data_counts && state.bootstrap_posts == 2);
    }
    press(recipient.window.upcast_ref(), "Sync Now");
    wait_work(&recipient);
    assert!(
        recipient.status.label()
            == "Synchronization complete. Cloud changes received and local changes confirmed."
    );
    assert!(local_has(&root, c.local));
    let (key, salt) = wire_material(&root);
    let target_wire = c
        .fixture
        .state
        .lock()
        .unwrap()
        .record_in(target_id, c.local.id)
        .unwrap();
    assert!(
        target_wire
            .open(&key, &salt)
            .unwrap()
            .fields
            .is_some_and(|fields| fields.content.as_slice() == c.local.content.as_bytes())
    );
    assert!(
        c.fixture
            .state
            .lock()
            .unwrap()
            .record_in(source_id, c.local.id)
            .is_some_and(|record| record == source_wire)
    );
    assert!(slot(c.trusted_root, Slot::LibraryKey).is_some_and(|value| value == target_key));
    println!(
        "Native candidate pairing: A created and recovered into a fresh installation with no B key/history; public B invitation Cancel/restart, independent trusted B proof/PAM approval, claim retained separately without data-plane writes, switch Cancel preservation, fresh PAM activation of exact B key, source history/checkpoint reset and explicit encrypted sync passed."
    );
    (recipient, stop)
}

#[test]
#[ignore = "explicit two-installation native pairing/approval GTK/HTTPS/private-keyring/private-PAM acceptance; invoke tests/account-live.sh with --pairing"]
fn live_device_pairing_and_signed_approval_restart() {
    let root = isolated_root();
    let recipient_root = root.with_file_name("public-pairing-recipient");
    assert!(!recipient_root.exists() && recipient_root.parent() == root.parent());
    let fixture = server::Fixture::new();
    fixture.state.lock().unwrap().enable_pairing();
    fixture
        .state
        .lock()
        .unwrap()
        .enable_creation_with_existing_library();
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
    // Foreground polling may already own or finish this same approved claim.
    // Observe that operation before requesting another check; no fixed delay.
    let polling = recipient.busy.get();
    wait_work(&recipient);
    let claimed = recipient.sync.is_sensitive();
    println!("Native claim readiness: polling={polling}, already_claimed={claimed}");
    if !claimed {
        press(recipient.window.upcast_ref(), "Check Approval");
        wait_work(&recipient);
    }
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
    let (recipient, recipient_stop) = candidate_switch(
        (recipient, recipient_stop),
        &trusted,
        CandidateContext {
            app: &app,
            parent: &parent,
            fixture: &fixture,
            pam: &pam,
            trusted_root: &root,
            seed_root: &recipient_root,
            local: &local,
        },
    );
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
