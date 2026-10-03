//! Native current v1 carrier decisions, real keyring, HTTPS receipts and vault.
use super::*;
#[path = "account_nested_review_live_tests.rs"]
mod nested;
#[path = "account_prerequisite_live_tests.rs"]
mod prerequisite;
#[path = "account_prior_child_live_tests.rs"]
mod prior_child;

fn credentials(
    window: &Rc<AccountWindow>,
    delete: bool,
    originals: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let dialog = review(window);
    assert!(dialog.heading().as_deref() == Some("Review Secure Snippet Deletion"));
    if originals {
        assert!(dialog.body().contains("Conflict originals to preserve: 1."));
        assert!(
            dialog
                .body()
                .contains("Restore 1 missing conflict originals")
        );
    }
    credentials_from(window, delete, dialog)
}
fn credentials_from(
    window: &Rc<AccountWindow>,
    delete: bool,
    dialog: adw::AlertDialog,
) -> (adw::AlertDialog, gtk::PasswordEntry) {
    press(
        dialog.upcast_ref(),
        if delete {
            "Confirm Deletion"
        } else {
            "Keep Local Version"
        },
    );
    until(
        "native current-carrier credential dialog did not map",
        || {
            window
                .password_dialog
                .borrow()
                .as_ref()
                .is_some_and(|(dialog, entry)| dialog.is_mapped() && entry.is_mapped())
        },
    );
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(window.busy.get() && !entry.shows_peek_icon());
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    (dialog, entry)
}
fn recovery_mode(dialog: &adw::AlertDialog) -> gtk::CheckButton {
    let mut widgets = vec![dialog.extra_child().unwrap()];
    while let Some(widget) = widgets.pop() {
        if let Some(button) = widget.downcast_ref::<gtk::CheckButton>()
            && button.label().as_deref() == Some("Use the vault recovery key")
        {
            assert!(button.is_mapped() && button.is_sensitive() && !button.is_active());
            return button.clone();
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    panic!("native deletion recovery-method control missing");
}
fn verify(window: &Rc<AccountWindow>, delete: bool, text: &str, originals: bool, recovery: bool) {
    let (dialog, entry) = credentials(window, delete, originals);
    recovery_mode(&dialog).set_active(recovery);
    entry.set_text(text);
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
    let root = isolated_root();
    let fixture = server::Fixture::new();
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    parent.set_title(Some("Public Native Current Carrier Acceptance"));
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    connect_keys(&window, &fixture);
    let installed = slot(&root, Slot::LibraryKey).unwrap();
    let (key, salt) = wire_material(&root);
    let independent: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&independent["document"]).unwrap()).unwrap();
    document.records[0].hlc = Some(Hlc::parse("100000000000-0000-11111111").unwrap());
    let source = document.records[0].metadata.id;
    let losing = projected(&document, source);
    let vault_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let winner_body = b"Public current secure source winner";
    edit(&mut document, source, winner_body, &vault_key);
    document.records[0].hlc = Some(Hlc::foreign(0xffff_0000_0000));
    let winner = projected(&document, source);
    let raw = crate::merge::merge(None, Some(&losing), Some(&winner))
        .unwrap()
        .survivor
        .unwrap();
    assert!(crate::merge::has_unresolved(Some(&raw)));
    let variants = crate::merge::secure_variants(&raw).unwrap();
    assert!(variants.len() == 1);
    let copy_id = variants[0].copy_id;
    document.records[0] = crate::projection::vault_record(&raw, None, &document.kid)
        .unwrap()
        .unwrap();
    document = Document::decode(&document.encode().unwrap()).unwrap();
    let unrelated =
        model::Snippet::new("Public current unrelated", "Public current unrelated body");
    model::Library::open(root.clone())
        .unwrap()
        .save(unrelated.clone(), None)
        .unwrap();
    fs::create_dir(root.join("Vault")).unwrap();
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    // The actual native owner captures the raw primary graph; no journal is seeded.
    action(&window, "Receive Cloud Changes");
    action(&window, "Send Local Changes");
    assert!(
        window.status.label()
            == "An encrypted conflict needs preservation before its source or later edits can be sent."
    );
    let captured = snapshot::checkpoint(&root);
    assert!(captured.journal.has_preservation_work());
    assert!(captured.journal.preservation_original(copy_id).is_none());
    assert!(crate::merge::has_unresolved(
        captured.journal.projected().get(&source)
    ));
    assert!(uploaded_has(&fixture, &unrelated, &key, &salt));
    assert!(fixture.state.lock().unwrap().record(source).is_none());
    let remote_delete = winner
        .tombstone(Hlc::foreign(0xffff_ff00_0000), "22222222".into(), true)
        .unwrap();
    let remote_version = {
        let mut state = fixture.state.lock().unwrap();
        state.put(WireRecord::seal(&remote_delete, &key, &salt).unwrap());
        state.version(source).unwrap()
    };
    action(&window, "Receive Cloud Changes");
    assert!(
        window.status.label()
            == "A cloud deletion needs review. The saved page is retained and your local snippet is preserved.",
        "vault_locked={}, local_review={}, current={}, apply_refused={}",
        window.status.label()
            == "An encrypted record or conflict needs your vault before this saved page can continue.",
        window.status.label()
            == "A local deletion needs review. The incoming page is saved; it has not restored the deleted snippet.",
        window.status.label() == "Cloud changes received. Local changes have not been sent.",
        window.status.label()
            == "Cloud changes could not be applied safely. The retained page needs review."
    );
    let before = primary(&root);
    let counts = data_counts(&fixture);
    let packets = fixture.state.lock().unwrap().submitted.clone();
    choice(&window, "Cancel");
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (dialog, entry) = credentials(&window, delete, true);
    entry.set_text("Public cancelled current-carrier credential");
    press(dialog.upcast_ref(), "Cancel");
    password_done(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (_dialog, entry) = credentials(&window, delete, true);
    entry.set_text("Public focus-revoked current-carrier credential");
    parent.present();
    until(
        "native current-carrier focus cancellation did not finish",
        || parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get(),
    );
    assert!(entry.text().is_empty());
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    window.window.present();
    until("native current-carrier window did not regain focus", || {
        window.window.is_active()
    });
    verify(
        &window,
        delete,
        "Public incorrect current-carrier passphrase",
        true,
        false,
    );
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    assert!(fixture.state.lock().unwrap().submitted == packets);
    let recovery = crypto::format_recovery(&[0x66; 16]);
    verify(
        &window,
        delete,
        if delete {
            &recovery
        } else {
            independent["passphrase"].as_str().unwrap()
        },
        true,
        delete,
    );
    assert!(window.status.label().starts_with(if delete {
        "Cloud deletion applied locally."
    } else {
        "Local version kept."
    }));
    assert!(data_counts(&fixture) == counts);
    let decided = snapshot::checkpoint(&root);
    let original = decided
        .journal
        .preservation_original(copy_id)
        .unwrap()
        .clone();
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(saved.records.len() == if delete { 1 } else { 2 });
    let copy = saved
        .records
        .iter()
        .find(|record| record.metadata.id == copy_id)
        .unwrap();
    assert!(!copy.metadata.is_enabled);
    assert!(
        body(&saved, copy_id, &vault_key).as_slice()
            == independent["plaintext"].as_str().unwrap().as_bytes()
    );
    assert!(original.fields.as_ref().unwrap().content.as_slice() == copy.sealed.text().as_bytes());
    if !delete {
        assert!(body(&saved, source, &vault_key).as_slice() == winner_body);
        assert!(
            saved
                .records
                .iter()
                .find(|record| record.metadata.id == source)
                .unwrap()
                .sealed
                == document.records[0].sealed
        );
    }
    no_session_key(&root, copy_id);
    action(&window, "Receive Cloud Changes");
    let (copy_deleted, copy_version) =
        prerequisite::run(&window, &root, &fixture, &key, &salt, source, &original);
    action(&window, "Send Local Changes");
    action(&window, "Sync Now");
    assert!(window.status.label() == CURRENT);
    assert!(local_has(&root, &unrelated));
    let final_source = uploaded(&fixture, source, &key, &salt);
    assert!(final_source.deleted == delete);
    if !delete {
        assert!(
            final_source.fields.as_ref().unwrap().content
                == winner.fields.as_ref().unwrap().content
        );
    }
    let final_copy = uploaded(&fixture, copy_id, &key, &salt);
    assert!(final_copy.deleted == copy_deleted);
    if !copy_deleted {
        assert!(
            final_copy.fields.as_ref().unwrap().content
                == original.fields.as_ref().unwrap().content
        );
        assert!(!final_copy.fields.as_ref().unwrap().is_enabled);
    }
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.submitted[..packets.len()] == packets);
        let copy_packet = state
            .submitted
            .iter()
            .position(|packet| {
                packet.iter().any(|(wire, expected)| {
                    wire.id == copy_id && expected.as_deref() == Some(copy_version.as_str())
                })
            })
            .unwrap();
        let source_packet = state
            .submitted
            .iter()
            .rposition(|packet| {
                packet
                    .iter()
                    .any(|(wire, expected)| wire.id == source && expected.is_some())
            })
            .unwrap();
        assert!(copy_packet >= packets.len() && copy_packet < source_packet);
        let source_acks = state
            .acknowledgements
            .iter()
            .filter(|(id, _)| *id == source)
            .map(|(_, version)| version)
            .collect::<Vec<_>>();
        assert!(source_acks.len() >= 2);
        let source_offer = state.submitted[source_packet]
            .iter()
            .find(|(wire, _)| wire.id == source)
            .unwrap();
        assert!(source_offer.1.as_ref() == Some(source_acks[source_acks.len() - 2]));
        assert!(state.submitted.iter().any(|packet| {
            packet.iter().any(|(wire, expected)| {
                wire.id == source && expected.as_deref() == Some(remote_version.as_str())
            })
        }));
        let offer = state.submitted[copy_packet]
            .iter()
            .find(|(wire, _)| wire.id == copy_id)
            .unwrap();
        assert!(
            offer.1.as_deref() == Some(copy_version.as_str())
                && offer.0.open(&key, &salt).unwrap() == original
        );
    }
    let after = snapshot::checkpoint(&root);
    assert!(!after.journal.has_preservation_work() && after.journal.deletion_approvals.is_empty());
    assert!(
        slot(&root, Slot::LibraryKey).is_some_and(|value| value.as_slice() == installed.as_slice())
    );
    assert!(
        slot(&root, Slot::AutomaticSync).is_none() && !root.join("automatic-sync.json").exists()
    );
    for name in ["snippets.json", "Vault/vault.json", "Sync/journal.bin"] {
        let bytes = fs::read(root.join(name)).unwrap();
        for plaintext in [
            winner_body.as_slice(),
            independent["plaintext"].as_str().unwrap().as_bytes(),
        ] {
            assert!(!bytes.windows(plaintext.len()).any(|part| part == plaintext));
        }
    }
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    pause_quit(&window);
    drop(stop);
    parent.destroy();
    app.quit();
}

#[test]
#[ignore = "explicit native current-carrier Keep GTK/HTTPS/keyring acceptance; invoke tests/account-live.sh with --current-review-keep"]
fn live_current_carrier_keep() {
    run(false);
}

#[test]
#[ignore = "explicit native current-carrier Delete GTK/HTTPS/keyring acceptance; invoke tests/account-live.sh with --current-review-delete"]
fn live_current_carrier_delete() {
    run(true);
}
