//! Actual HTTPS CAS conflicts, protected originals and mapped deletion reviews.
use super::*;
use crate::clock::Hlc;
#[path = "account_current_review_live_tests.rs"]
mod current;
#[path = "account_snapshot_live_tests.rs"]
mod snapshot;

fn review(window: &Rc<AccountWindow>) -> adw::AlertDialog {
    press(window.window.upcast_ref(), "Review Deletions…");
    until("native deletion review did not map", || {
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
            || !window.busy.get()
    });
    assert!(
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped()),
        "preservation_required={}, send_pending={}, unavailable={}, changed={}, apply_refused={}",
        window.status.label()
            == "Preserve the pending conflict copies before deciding this deletion.",
        window.status.label() == "Finish the saved send before reviewing this incoming deletion.",
        window.status.label() == "No saved deletion needs review.",
        window.status.label() == "The local or cloud library changed. Review this deletion again.",
        window.status.label() == "This deletion could not be applied safely. Review it again."
    );
    let dialog = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(window.busy.get());
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    dialog
}
fn choice(window: &Rc<AccountWindow>, label: &str) {
    let dialog = review(window);
    press(dialog.upcast_ref(), label);
    wait_work(window);
    assert!(window.snapshot_dialog.borrow().is_none());
}
fn password(window: &Rc<AccountWindow>) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let dialog = review(window);
    press(dialog.upcast_ref(), "Restore Retained Version");
    until(
        "native protected-copy credential dialog did not map",
        || {
            window
                .password_dialog
                .borrow()
                .as_ref()
                .is_some_and(|(d, entry)| d.is_mapped() && entry.is_mapped())
        },
    );
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
fn password_done(window: &Rc<AccountWindow>, entry: &gtk::PasswordEntry) {
    wait_work(window);
    assert!(entry.text().is_empty() && window.password_dialog.borrow().is_none());
}
fn tombstone(
    fixture: &server::Fixture,
    id: uuid::Uuid,
    wall: u64,
    key: &RootKey,
    salt: &[u8; 32],
) -> Envelope {
    let current = uploaded(fixture, id, key, salt);
    let deleted = current
        .tombstone(Hlc::foreign(wall), "22222222".into(), true)
        .unwrap();
    fixture
        .state
        .lock()
        .unwrap()
        .put(WireRecord::seal(&deleted, key, salt).unwrap());
    deleted
}

#[test]
#[ignore = "explicit native secure-conflict/deletion GTK/HTTPS/keyring acceptance; invoke tests/account-live.sh with --sync-review"]
fn live_secure_conflict_and_deletion() {
    let root = isolated_root();
    let fixture = server::Fixture::new();
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    parent.set_title(Some("Public Native Conflict and Deletion Acceptance"));
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
    let vault_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    fs::create_dir(root.join("Vault")).unwrap();
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    let unrelated =
        model::Snippet::new("Public unaffected ordinary", "Public unrelated native body");
    model::Library::open(root.clone())
        .unwrap()
        .save(unrelated.clone(), None)
        .unwrap();
    let mut winner = model::Snippet::new(
        "Public authoritative winner",
        "Public authoritative ordinary winner",
    );
    winner.id = source;
    let winner =
        Envelope::plain(&winner, Hlc::foreign(0xffff_0000_0000), "22222222".into()).unwrap();
    let authoritative = WireRecord::seal(&winner, &key, &salt).unwrap();
    let version = {
        let mut state = fixture.state.lock().unwrap();
        state.put(authoritative.clone());
        state.version(source).unwrap()
    };
    action(&window, "Send Local Changes");
    assert!(
        window.status.label()
            == "An encrypted conflict needs your vault before sending can continue."
    );
    assert!(crate::vault::read_document(&root).unwrap().unwrap() == document);
    assert!(local_has(&root, &unrelated));
    let offers = fixture.state.lock().unwrap().submitted.clone();
    assert!(offers.len() == 1);
    let offered = offers[0]
        .iter()
        .find(|(wire, _)| wire.id == source)
        .unwrap();
    assert!(offered.1.is_none() && offered.0.open(&key, &salt).unwrap().secure);
    assert!(fixture.state.lock().unwrap().record(source).unwrap() == authoritative);
    let before = primary(&root);
    let counts = data_counts(&fixture);
    let (dialog, entry) = vault_dialog(&window);
    entry.set_text("Public cancelled conflict credential");
    press(dialog.upcast_ref(), "Cancel");
    finished(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    credential(&window, "Public wrong conflict passphrase", false);
    assert!(window.status.label() == Failure::VaultAuthentication.message());
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    assert!(fixture.state.lock().unwrap().submitted == offers);

    credential(&window, independent["passphrase"].as_str().unwrap(), false);
    assert!(window.status.label() == CURRENT);
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(saved.records.len() == 1);
    let copy = saved.records[0].clone();
    let copy_id = copy.metadata.id;
    assert!(copy_id != source && !copy.metadata.is_enabled);
    assert!(
        body(&saved, copy_id, &vault_key).as_slice()
            == independent["plaintext"].as_str().unwrap().as_bytes()
    );
    assert!(copy.sealed != document.records[0].sealed);
    let sent_copy = uploaded(&fixture, copy_id, &key, &salt);
    assert!(crate::merge::provenance(&sent_copy).is_some_and(|p| p.source_id == source));
    assert!(sent_copy.secure && !sent_copy.fields.as_ref().unwrap().is_enabled);
    assert!(sent_copy.fields.as_ref().unwrap().content.as_slice() == copy.sealed.text().as_bytes());
    let sent_source = uploaded(&fixture, source, &key, &salt);
    assert!(
        !sent_source.secure
            && !sent_source.deleted
            && sent_source.fields.as_ref().unwrap().content.as_slice()
                == b"Public authoritative ordinary winner"
    );
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.submitted[0] == offers[0]);
        let copy_packet = state
            .submitted
            .iter()
            .position(|packet| packet.iter().any(|(wire, _)| wire.id == copy_id))
            .unwrap();
        let source_packet = state
            .submitted
            .iter()
            .enumerate()
            .skip(1)
            .find(|(_, packet)| {
                packet.iter().any(|(wire, expected)| {
                    wire.id == source && expected.as_deref() == Some(version.as_str())
                })
            })
            .unwrap()
            .0;
        assert!(copy_packet > 0 && copy_packet < source_packet);
        let copy_offer = state.submitted[copy_packet]
            .iter()
            .find(|(wire, _)| wire.id == copy_id)
            .unwrap();
        assert!(copy_offer.1.is_none() && copy_offer.0 == state.record(copy_id).unwrap());
    }
    no_session_key(&root, copy_id);
    // Removing only the physical copy cannot silently become cloud deletion.
    let mut absent = saved.clone();
    absent.records.clear();
    model::atomic_write(&root.join("Vault/vault.json"), &absent.encode().unwrap()).unwrap();
    action(&window, "Send Local Changes");
    assert!(
        window.status.label()
            == "A local record is missing. Sending is paused for review; local and cloud records are preserved."
    );
    let before = primary(&root);
    let counts = data_counts(&fixture);
    let (dialog, entry) = password(&window);
    entry.set_text("Public cancelled restore credential");
    press(dialog.upcast_ref(), "Cancel");
    password_done(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (dialog, entry) = password(&window);
    entry.set_text("Public incorrect restore credential");
    press(dialog.upcast_ref(), "Verify and Restore");
    password_done(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (dialog, entry) = password(&window);
    entry.set_text(independent["passphrase"].as_str().unwrap());
    press(dialog.upcast_ref(), "Verify and Restore");
    password_done(&window, &entry);
    assert!(
        window
            .status
            .label()
            .starts_with("Retained version restored.")
    );
    let restored = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(
        restored.records.len() == 1
            && restored.records[0].metadata.id == copy_id
            && restored.records[0].sealed == copy.sealed
    );
    assert!(!restored.records[0].metadata.is_enabled);
    action(&window, "Send Local Changes");
    assert!(
        window.status.label()
            == "Local changes confirmed by the cloud. Receive Cloud Changes to check other devices."
    );
    assert!(
        uploaded(&fixture, copy_id, &key, &salt)
            .fields
            .as_ref()
            .unwrap()
            .content
            .as_slice()
            == copy.sealed.text().as_bytes()
    );
    no_session_key(&root, copy_id);

    let delete = tombstone(&fixture, unrelated.id, 0xffff_ff00_0000, &key, &salt);
    action(&window, "Receive Cloud Changes");
    assert!(
        window.status.label()
            == "A cloud deletion needs review. The saved page is retained and your local snippet is preserved."
    );
    assert!(local_has(&root, &unrelated));
    let before = primary(&root);
    let counts = data_counts(&fixture);
    choice(&window, "Cancel");
    assert!(window.status.label() == "Deletion review cancelled. The saved state is kept.");
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let _dialog = review(&window);
    parent.present();
    until("native deletion focus cancellation did not finish", || {
        parent.is_active() && window.snapshot_dialog.borrow().is_none() && !window.busy.get()
    });
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    window.window.present();
    until("native deletion window did not regain focus", || {
        window.window.is_active()
    });
    choice(&window, "Keep Local Version");
    assert!(
        window.status.label()
            == "Local version kept. Finish receiving or the retained send, then Send Local Changes to upload it."
    );
    action(&window, "Receive Cloud Changes");
    action(&window, "Send Local Changes");
    assert!(local_has(&root, &unrelated));
    let kept = uploaded(&fixture, unrelated.id, &key, &salt);
    assert!(
        !kept.deleted
            && kept.hlc > delete.hlc
            && kept.fields.as_ref().unwrap().content.as_slice() == unrelated.content.as_bytes()
    );
    let protected = fs::read(root.join("Vault/vault.json")).unwrap();
    tombstone(&fixture, unrelated.id, 0xffff_ff10_0000, &key, &salt);
    action(&window, "Receive Cloud Changes");
    assert!(local_has(&root, &unrelated));
    let batches = fixture.state.lock().unwrap().batches;
    choice(&window, "Confirm Deletion");
    assert!(
        window.status.label()
            == "Cloud deletion applied locally. Receive Cloud Changes to continue the saved page."
    );
    assert!(!local_has(&root, &unrelated));
    action(&window, "Receive Cloud Changes");
    action(&window, "Sync Now");
    assert!(window.status.label() == CURRENT && fixture.state.lock().unwrap().batches == batches);
    assert!(fs::read(root.join("Vault/vault.json")).unwrap() == protected);
    assert!(
        fixture
            .state
            .lock()
            .unwrap()
            .record(unrelated.id)
            .unwrap()
            .open(&key, &salt)
            .unwrap()
            .deleted
    );
    assert!(
        uploaded(&fixture, source, &key, &salt)
            .fields
            .as_ref()
            .unwrap()
            .content
            .as_slice()
            == b"Public authoritative ordinary winner"
    );
    let final_vault = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(final_vault.records[0].sealed == copy.sealed);
    assert!(
        body(&final_vault, copy_id, &vault_key).as_slice()
            == independent["plaintext"].as_str().unwrap().as_bytes()
    );
    snapshot::run(&window, &parent, &root, &fixture, &key, &salt);
    for name in ["snippets.json", "Vault/vault.json", "Sync/journal.bin"] {
        let bytes = fs::read(root.join(name)).unwrap();
        let plaintext = independent["plaintext"].as_str().unwrap().as_bytes();
        assert!(!bytes.windows(plaintext.len()).any(|v| v == plaintext));
    }
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v.as_slice() == installed.as_slice()));
    assert!(
        slot(&root, Slot::AutomaticSync).is_none() && !root.join("automatic-sync.json").exists()
    );
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    pause_quit(&window);
    drop(stop);
    parent.destroy();
    app.quit();
}
