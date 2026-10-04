//! Mapped same-vault history restoration with independently wrapped public data.
use super::*;
use crate::{
    crypto::{self, RootKey},
    key_store::history::SwitchPhase,
    vault::{Document, Record},
};

const CURRENT: &str =
    "Synchronization complete. Cloud changes received and local changes confirmed.";
const LATER: &[u8] = b"Public current secure restoration body";
const NEWER: &[u8] = b"Public newer secure restoration body after review";

fn document(root: &Path) -> Document {
    crate::vault::read_document(root).unwrap().unwrap()
}
fn write(root: &Path, doc: &Document) {
    model::atomic_write(&root.join("Vault/vault.json"), &doc.encode().unwrap()).unwrap();
}
fn reconnect(window: &Rc<AccountWindow>, index: u32) {
    press(window.window.upcast_ref(), "Reconnect Saved Account");
    wait_work(window);
    assert!(window.libraries.selected() == 0 && !window.sync.is_sensitive());
    window.libraries.set_selected(index);
    wait_work(window);
    assert!(window.sync.is_sensitive());
}
fn sync(window: &Rc<AccountWindow>, credential: &str, recovery: bool) {
    let (dialog, entry) = vault::vault_dialog(window);
    vault::mode(&dialog).set_active(recovery);
    entry.set_text(credential);
    press(dialog.upcast_ref(), "Verify and Sync");
    until_for(
        "native secure restoration sync did not finish",
        Duration::from_secs(60),
        || !window.busy.get(),
    );
    assert!(entry.text().is_empty() && window.vault_sync_dialog.borrow().is_none());
    assert!(window.vault_sync_authorization.borrow().is_none() && window.status.label() == CURRENT);
}
fn finished(window: &AccountWindow, entries: &[gtk::PasswordEntry]) {
    until("native secure restoration operation did not finish", || {
        !window.busy.get()
    });
    assert!(
        window.restoration_dialog.borrow().is_none() && window.snapshot_dialog.borrow().is_none()
    );
    assert!(
        window.password_dialog.borrow().is_none()
            && window.restoration_preparation.borrow().is_none()
    );
    assert!(entries.iter().all(|entry| entry.text().is_empty()));
}
fn toggles(dialog: &adw::AlertDialog, label: &str) -> Vec<gtk::CheckButton> {
    let mut stack = vec![dialog.extra_child().unwrap()];
    let mut found = Vec::new();
    while let Some(widget) = stack.pop() {
        if let Some(toggle) = widget.downcast_ref::<gtk::CheckButton>()
            && toggle.label().as_deref() == Some(label)
        {
            found.push(toggle.clone());
        }
        let mut children = Vec::new();
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            children.push(widget);
        }
        stack.extend(children.into_iter().rev());
    }
    found
}
fn credentials(window: &Rc<AccountWindow>) -> (adw::AlertDialog, Vec<gtk::PasswordEntry>) {
    press(window.window.upcast_ref(), "Library Recovery History…");
    until("native secure restoration history did not map", || {
        window
            .history_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    let history = window.history_dialog.borrow().clone().unwrap();
    let selected = restoration_live::selected_review(&history, "Switch 3 · finished locally");
    until("selected native secure history row did not map", || {
        selected.is_mapped() && selected.is_sensitive()
    });
    selected.emit_clicked();
    until("native secure restoration credentials did not map", || {
        window
            .restoration_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e[0].is_mapped())
    });
    let (dialog, entries) = window.restoration_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Unlock the Vaults for Restoration"));
    assert!(
        dialog.default_response().as_deref() == Some("back") && dialog.close_response() == "back"
    );
    assert!(!dialog.is_response_enabled("unlock") && entries.iter().all(|e| !e.shows_peek_icon()));
    let previous = toggles(&dialog, "Saved changes use a previous vault");
    assert!(previous.len() == 1 && !previous[0].is_active());
    let modes = toggles(&dialog, "Use recovery key");
    assert!(
        modes.len() == 2
            && modes[0].is_visible()
            && modes[0].is_sensitive()
            && !modes[0].is_active()
    );
    (dialog, entries)
}
fn reviewed(window: &Rc<AccountWindow>, value: &str, recovery: bool) -> adw::AlertDialog {
    let (dialog, entries) = credentials(window);
    toggles(&dialog, "Use recovery key")[0].set_active(recovery);
    entries[0].set_text(value);
    press(dialog.upcast_ref(), "Verify Saved Changes");
    until("native secure restoration review did not map", || {
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    assert!(
        window.restoration_dialog.borrow().is_none() && entries.iter().all(|e| e.text().is_empty())
    );
    let review = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(review.heading().as_deref() == Some("Restore the Saved Changes?"));
    assert!(
        review.default_response().as_deref() == Some("back") && review.close_response() == "back"
    );
    assert!(
        review
            .body()
            .contains("2 saved records · 2 preserved current versions · 1 secure records")
    );
    assert!(
        review
            .body()
            .matches(&uuid::Uuid::from_u128(201).to_string())
            .count()
            == 2
    );
    review
}
fn password(
    window: &Rc<AccountWindow>,
    value: &str,
    recovery: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let review = reviewed(window, value, recovery);
    press(review.upcast_ref(), "Restore Changes");
    until(
        "native secure restoration computer password did not map",
        || {
            window
                .password_dialog
                .borrow()
                .as_ref()
                .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
        },
    );
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Authorize Saved Changes Restoration"));
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
fn refocus(window: &AccountWindow) {
    window.window.present();
    until("native secure restoration did not regain focus", || {
        window.window.is_active()
    });
}
fn preserved(
    root: &Path,
    archived: &Record,
    current: &Record,
    extra: &Record,
    key: &RootKey,
    original_body: &[u8],
) -> Record {
    let doc = document(root);
    assert!(doc.records.len() == 3);
    let restored = doc
        .records
        .iter()
        .find(|r| r.metadata.id == archived.metadata.id)
        .unwrap();
    assert!(
        restored.metadata.name == archived.metadata.name
            && restored.metadata.keyword == archived.metadata.keyword
            && restored.metadata.tags == archived.metadata.tags
    );
    assert!(vault::body(&doc, restored.metadata.id, key).as_slice() == original_body);
    let retained = doc
        .records
        .iter()
        .find(|r| r.metadata.id == extra.metadata.id)
        .unwrap();
    assert!(
        retained == extra,
        "unrelated secure record: metadata={}, seal={}, hash={}, clock={}, extensions={}",
        retained.metadata == extra.metadata,
        retained.sealed == extra.sealed,
        retained.content_hash == extra.content_hash,
        retained.hlc == extra.hlc,
        retained.extra == extra.extra
    );
    let copy = doc
        .records
        .iter()
        .find(|r| r.metadata.id != archived.metadata.id && r.metadata.id != extra.metadata.id)
        .unwrap();
    assert!(vault::body(&doc, copy.metadata.id, key).as_slice() == NEWER);
    assert!(
        copy.metadata.name.contains(&current.metadata.name)
            && copy
                .metadata
                .tags
                .iter()
                .any(|tag| current.metadata.tags.contains(tag))
    );
    assert!(
        !copy.metadata.is_enabled && !copy.metadata.is_pinned && copy.metadata.keyword.is_empty()
    );
    assert!(copy.sealed != current.sealed);
    copy.clone()
}
fn ordinary_preserved(
    root: &Path,
    archived: &model::Snippet,
    current: &model::Snippet,
    extra: &model::Snippet,
) -> model::Snippet {
    let library = model::Library::open(root.into()).unwrap();
    assert!(library.snippets.len() == 3 && library.snippets.iter().any(|s| s == extra));
    let restored = library
        .snippets
        .iter()
        .find(|s| s.id == archived.id)
        .unwrap();
    assert!(
        restored.content == archived.content
            && restored.name == archived.name
            && restored.tags == archived.tags
            && restored.keyword == archived.keyword
    );
    let copy = library
        .snippets
        .iter()
        .find(|s| s.id != archived.id && s.id != extra.id)
        .unwrap();
    assert!(
        copy.content == current.content
            && copy.name.contains(&current.name)
            && copy.tags.iter().any(|tag| current.tags.contains(tag))
    );
    assert!(!copy.is_enabled && !copy.is_pinned && copy.keyword.is_empty());
    copy.clone()
}
#[test]
#[ignore = "explicit native same-vault history GTK/HTTPS/private-keyring/private-PAM acceptance; invoke tests/account-live.sh with --secure-restoration"]
fn live_secure_saved_history_restoration() {
    creation::run(creation::Followup::SecureRestoration);
}
pub(super) fn run(
    window: &Rc<AccountWindow>,
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
    ordinary: &model::Snippet,
) {
    reconnect(window, 1);
    let fixture_data: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let passphrase = fixture_data["passphrase"].as_str().unwrap();
    let original_body = fixture_data["plaintext"].as_str().unwrap().as_bytes();
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let recovery = crypto::format_recovery(&[0x66; 16]);
    let initial =
        Document::decode(&serde_json::to_vec(&fixture_data["document"]).unwrap()).unwrap();
    fs::create_dir(root.join("Vault")).unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    write(root, &initial);
    let secure_id = initial.records[0].metadata.id;
    sync(window, passphrase, false);
    vault::no_session_key(root, secure_id);
    let source_key = slot(root, Slot::LibraryKey).unwrap();
    let source_wire = fixture
        .state
        .lock()
        .unwrap()
        .record_in(uuid::Uuid::from_u128(200), secure_id)
        .unwrap();
    window.libraries.set_selected(2);
    wait_work(window);
    press(window.window.upcast_ref(), "Review Library Switch…");
    until("native protected library switch review did not map", || {
        window
            .snapshot_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    let dialog = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(dialog.heading().as_deref() == Some("Switch to the Selected Library?"));
    assert!(
        dialog
            .body()
            .contains("Keep 2 local records and 0 saved conflict copies")
    );
    assert!(dialog.body().contains("Use a key saved on this computer"));
    press(dialog.upcast_ref(), "Switch Library");
    until("native protected switch password did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    wait_work(window);
    assert!(entry.text().is_empty() && window.sync.is_sensitive());
    assert!(slot(root, Slot::LibraryKey).is_some_and(|bytes| bytes != source_key));
    sync(window, passphrase, false);
    let (checkpoint, catalog) = switching::checkpoint_and_history(root);
    assert!(catalog.switches.len() == 3 && catalog.restorations.is_empty());
    assert!(
        checkpoint.journal.confirmed(secure_id).is_some()
            && checkpoint.journal.inbox.cursor().is_some()
    );
    let archived = document(root)
        .records
        .into_iter()
        .find(|r| r.metadata.id == secure_id)
        .unwrap();
    let mut edited = document(root);
    vault::edit(&mut edited, secure_id, LATER, &key);
    let metadata = &mut edited
        .records
        .iter_mut()
        .find(|r| r.metadata.id == secure_id)
        .unwrap()
        .metadata;
    metadata.name = "Public current secure title".into();
    metadata.keyword = "public-current-secure".into();
    metadata.tags = vec!["public-current-secure-tag".into()];
    metadata.is_pinned = true;
    let mut extra = archived.clone();
    extra.metadata = crate::vault::Metadata::new();
    extra.metadata.name = "Public unrelated secure record".into();
    extra.sealed = crypto::seal_record(
        b"Public unrelated secure retained body",
        &key,
        &edited.salt().unwrap(),
        &edited.kid,
        extra.metadata.id,
        false,
    )
    .unwrap();
    extra.content_hash = crypto::content_hash(
        b"Public unrelated secure retained body",
        &key,
        &edited.salt().unwrap(),
    );
    // Match a new local record written by Vault::save, which always reserves
    // an installation clock. Foreign clocks describe imported legacy data.
    extra.hlc = Some(
        crate::clock::stamp(
            root,
            None,
            extra.metadata.updated_at.timestamp_millis().max(0) as u64,
        )
        .unwrap(),
    );
    let extra_id = extra.metadata.id;
    edited.records.push(extra);
    write(root, &Document::decode(&edited.encode().unwrap()).unwrap());
    let extra = document(root)
        .records
        .into_iter()
        .find(|r| r.metadata.id == extra_id)
        .unwrap();
    let unrelated = model::Snippet::new(
        "Public unrelated ordinary record",
        "Public unrelated ordinary retained body",
    );
    model::Library::open(root.into())
        .unwrap()
        .save(unrelated.clone(), None)
        .unwrap();
    let unrelated = model::Library::open(root.into())
        .unwrap()
        .snippets
        .into_iter()
        .find(|s| s.id == unrelated.id)
        .unwrap();
    let mut library = model::Library::open(root.into()).unwrap();
    let current_plain = library
        .snippets
        .iter()
        .find(|s| s.id == ordinary.id)
        .unwrap()
        .clone();
    let mut changed = current_plain.clone();
    changed.content = "Public current ordinary restoration body".into();
    changed.name = "Public current ordinary restoration title".into();
    changed.keyword = "public-current-ordinary".into();
    changed.tags = vec!["public-current-ordinary-tag".into()];
    changed.is_pinned = true;
    library.save(changed, Some(&current_plain)).unwrap();
    let current_plain = model::Library::open(root.into())
        .unwrap()
        .snippets
        .into_iter()
        .find(|s| s.id == ordinary.id)
        .unwrap();
    let before = creation::images(root);
    let protected = restoration_live::protected(root);
    let counts = {
        let s = fixture.state.lock().unwrap();
        (s.fetches, s.batches, s.accepted)
    };
    let unchanged = || {
        assert!(creation::images(root) == before && restoration_live::protected(root) == protected);
        assert!(slot(root, Slot::HistoryRestore).is_none());
        let s = fixture.state.lock().unwrap();
        assert!((s.fetches, s.batches, s.accepted) == counts);
        drop(s);
        vault::no_session_key(root, secure_id);
    };
    let (dialog, entries) = credentials(window);
    entries[0].set_text(passphrase);
    press(dialog.upcast_ref(), "Cancel");
    finished(window, &entries);
    unchanged();
    let (dialog, entries) = credentials(window);
    entries[0].set_text("Public incorrect vault password");
    press(dialog.upcast_ref(), "Verify Saved Changes");
    finished(window, &entries);
    unchanged();
    let (_dialog, entries) = credentials(window);
    entries[0].set_text(passphrase);
    parent.present();
    until("secure vault credential focus loss did not cancel", || {
        parent.is_active() && !window.busy.get()
    });
    finished(window, &entries);
    unchanged();
    refocus(window);
    let review = reviewed(window, &recovery, true);
    press(review.upcast_ref(), "Keep Current State");
    finished(window, &[]);
    unchanged();
    let _review = reviewed(window, passphrase, false);
    parent.present();
    until(
        "secure restoration review focus loss did not cancel",
        || parent.is_active() && !window.busy.get(),
    );
    finished(window, &[]);
    unchanged();
    refocus(window);
    for (value, response) in [
        ("Public fictional password", "Cancel"),
        ("Public incorrect password", "Authorize"),
    ] {
        let (dialog, entry) = password(window, passphrase, false);
        entry.set_text(value);
        press(dialog.upcast_ref(), response);
        finished(window, std::slice::from_ref(&entry));
        unchanged();
    }
    let (_dialog, entry) = password(window, passphrase, false);
    entry.set_text("Public fictional password");
    parent.present();
    until("secure restoration PAM focus loss did not cancel", || {
        parent.is_active() && !window.busy.get()
    });
    finished(window, std::slice::from_ref(&entry));
    unchanged();
    refocus(window);
    println!(
        "Native secure restoration: vault passphrase/recovery review, Cancel/wrong credential and vault/review/PAM focus revocation preserved primary images, keys and data plane."
    );
    let (dialog, entry) = password(window, passphrase, false);
    let mut newer = document(root);
    vault::edit(&mut newer, secure_id, NEWER, &key);
    write(root, &Document::decode(&newer.encode().unwrap()).unwrap());
    let newer = document(root)
        .records
        .into_iter()
        .find(|r| r.metadata.id == secure_id)
        .unwrap();
    let stale = creation::images(root);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(window, std::slice::from_ref(&entry));
    assert!(
        creation::images(root) == stale
            && restoration_live::protected(root) == protected
            && slot(root, Slot::HistoryRestore).is_none()
    );
    assert!(!window.sync.is_sensitive() && window.libraries.selected() == 0);
    reconnect(window, 2);
    let (dialog, entry) = password(window, &recovery, true);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(window, std::slice::from_ref(&entry));
    assert!(
        window.status.label()
            == "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing."
    );
    assert!(
        !window.sync.is_sensitive()
            && !window.receive.is_sensitive()
            && !window.send.is_sensitive()
            && window.libraries.selected() == 0
    );
    assert!(
        restoration_live::protected(root) == protected
            && slot(root, Slot::HistoryRestore).is_some()
    );
    let copy = preserved(root, &archived, &newer, &extra, &key, original_body);
    let plain_copy = ordinary_preserved(root, ordinary, &current_plain, &unrelated);
    let mut header = document(root);
    header.records.clear();
    let mut original_header = initial;
    original_header.records.clear();
    assert!(header == original_header);
    let (restored, catalog) = switching::checkpoint_and_history(root);
    assert!(
        checkpoint
            .journal
            .preserves_transport_state(&restored.journal)
    );
    assert!(catalog.switches.len() == 3 && catalog.restorations.len() == 1);
    let receipt = &catalog.restorations[0];
    assert!(
        receipt.phase == SwitchPhase::Completed
            && !receipt.needs_completion
            && receipt.summary.restored_records == 2
            && receipt.summary.preserved_versions == 2
            && receipt.summary.secure_records == 1
    );
    let submissions = {
        let s = fixture.state.lock().unwrap();
        assert!((s.fetches, s.batches, s.accepted) == counts);
        assert!(
            s.record_in(uuid::Uuid::from_u128(200), secure_id)
                .is_some_and(|w| w == source_wire)
        );
        s.submitted.len()
    };
    let completed = creation::images(root);
    vault::no_session_key(root, secure_id);
    until("completed secure restoration worker did not drain", || {
        window.prepare_quit()
    });
    window.window.destroy();
    let reopened = make_window(app, parent, root, fixture, pam);
    let stop = Stop(reopened.clone());
    reconnect(&reopened, 2);
    assert!(creation::images(root) == completed && restoration_live::protected(root) == protected);
    assert!(preserved(root, &archived, &newer, &extra, &key, original_body) == copy);
    assert!(ordinary_preserved(root, ordinary, &current_plain, &unrelated) == plain_copy);
    sync(&reopened, passphrase, false);
    assert!(preserved(root, &archived, &newer, &extra, &key, original_body) == copy);
    assert!(ordinary_preserved(root, ordinary, &current_plain, &unrelated) == plain_copy);
    let (wire_key, wire_salt) = wire_material(root);
    let doc = document(root);
    let s = fixture.state.lock().unwrap();
    for record in &doc.records {
        let wire = s
            .record_in(uuid::Uuid::from_u128(201), record.metadata.id)
            .unwrap();
        let decoded = wire.open(&wire_key, &wire_salt).unwrap();
        assert!(
            decoded.secure
                && !decoded.deleted
                && decoded.fields.as_ref().unwrap().content.as_slice()
                    == record.sealed.text().as_bytes()
        );
        assert!(decoded.extensions["vaultContentHash"].as_text().unwrap() == record.content_hash);
    }
    let sent = s.submitted[submissions..]
        .iter()
        .flat_map(|batch| batch.iter().map(|(wire, _)| wire.id))
        .collect::<Vec<_>>();
    assert!(
        sent.iter().position(|id| *id == copy.metadata.id).unwrap()
            < sent.iter().position(|id| *id == secure_id).unwrap()
    );
    assert!(
        sent.iter().position(|id| *id == plain_copy.id).unwrap()
            < sent.iter().position(|id| *id == ordinary.id).unwrap()
    );
    for expected in [ordinary, &plain_copy, &unrelated] {
        let decoded = s
            .record_in(uuid::Uuid::from_u128(201), expected.id)
            .unwrap()
            .open(&wire_key, &wire_salt)
            .unwrap();
        assert!(
            !decoded.secure
                && !decoded.deleted
                && decoded.fields.as_ref().unwrap().content.as_slice()
                    == expected.content.as_bytes()
        );
    }
    assert!(
        s.record_in(uuid::Uuid::from_u128(200), secure_id)
            .is_some_and(|w| w == source_wire)
    );
    assert!(s.creation_counts() == (3, 2) && s.bootstrap_posts == 2);
    drop(s);
    vault::no_session_key(root, secure_id);
    assert!(
        !root.join("automatic-sync.json").exists()
            && CloudClient::discover(fixture.server.clone()).is_err()
    );
    until("final secure restoration worker did not drain", || {
        reopened.prepare_quit()
    });
    drop(stop);
    println!(
        "Native secure history restoration: independently wrapped same-vault credentials, whole ordinary/secure review, stale ciphertext refusal, fresh PAM, disabled sealed current-version preservation, unrelated ordinary/secure retention, exact current CAS/feed, completed history, new-worker reconnect and authenticated encrypted copy-before-source synchronization passed."
    );
}
