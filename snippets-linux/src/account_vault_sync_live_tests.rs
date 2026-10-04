//! Mapped manual/vault sync controls, native keyring and verified HTTPS.
//! Vault wraps/body fixtures are public and independently generated.
use super::*;
use crate::{
    crypto::{self, RootKey},
    vault::{Document, Record, Vault},
    wire::{Envelope, WireRecord},
};
use std::os::unix::fs::PermissionsExt;
#[path = "account_sync_review_live_tests.rs"]
mod review;

const CURRENT: &str =
    "Synchronization complete. Cloud changes received and local changes confirmed.";
const LOCKED: &str =
    "An encrypted record or conflict needs your vault before synchronization can continue.";

fn action(window: &Rc<AccountWindow>, label: &str) {
    press(window.window.upcast_ref(), label);
    wait_work(window);
}
pub(super) fn vault_dialog(window: &Rc<AccountWindow>) -> (adw::AlertDialog, gtk::PasswordEntry) {
    press(window.window.upcast_ref(), "Verify Vault and Sync…");
    until("native vault synchronization dialog did not map", || {
        window
            .vault_sync_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(dialog, entry)| dialog.is_mapped() && entry.is_mapped())
    });
    let (dialog, entry) = window.vault_sync_dialog.borrow().clone().unwrap();
    assert!(window.busy.get() && window.vault_sync_authorization.borrow().is_some());
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!dialog.is_response_enabled("sync") && !entry.shows_peek_icon());
    (dialog, entry)
}
fn finished(window: &Rc<AccountWindow>, entry: &gtk::PasswordEntry) {
    wait_work(window);
    assert!(entry.text().is_empty());
    assert!(
        window.vault_sync_dialog.borrow().is_none()
            && window.vault_sync_authorization.borrow().is_none()
    );
    assert!(window.worker.can_quit());
}
pub(super) fn mode(dialog: &adw::AlertDialog) -> gtk::CheckButton {
    let mut widgets = vec![dialog.extra_child().unwrap()];
    while let Some(widget) = widgets.pop() {
        if let Some(button) = widget.downcast_ref::<gtk::CheckButton>()
            && button.label().as_deref() == Some("Use recovery key")
        {
            return button.clone();
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    panic!("native recovery-method control missing");
}
fn credential(window: &Rc<AccountWindow>, text: &str, recovery: bool) {
    let (dialog, entry) = vault_dialog(window);
    let mode = mode(&dialog);
    assert!(mode.is_visible() && mode.is_sensitive() && !mode.is_active());
    mode.set_active(recovery);
    entry.set_text(text);
    press(dialog.upcast_ref(), "Verify and Sync");
    finished(window, &entry);
}
fn projected(document: &Document, id: uuid::Uuid) -> Envelope {
    crate::projection::current(
        &[],
        Some(document),
        "12345678",
        &Default::default(),
        &Default::default(),
    )
    .unwrap()
    .remove(&id)
    .unwrap()
}
pub(super) fn body(document: &Document, id: uuid::Uuid, key: &RootKey) -> Zeroizing<Vec<u8>> {
    let record = document
        .records
        .iter()
        .find(|r| r.metadata.id == id)
        .unwrap();
    crypto::open_record(
        &record.sealed,
        key,
        &document.salt().unwrap(),
        &document.kid,
        id,
        false,
    )
    .unwrap()
}
fn uploaded(fixture: &server::Fixture, id: uuid::Uuid, key: &RootKey, salt: &[u8; 32]) -> Envelope {
    let wire = fixture.state.lock().unwrap().record(id).unwrap();
    wire.open(key, salt).unwrap()
}
fn primary(root: &Path) -> Vec<Vec<u8>> {
    ["snippets.json", "Vault/vault.json", "Sync/journal.bin"]
        .into_iter()
        .map(|name| fs::read(root.join(name)).unwrap())
        .collect()
}
fn data_counts(fixture: &server::Fixture) -> (usize, usize) {
    let state = fixture.state.lock().unwrap();
    (state.fetches, state.batches)
}
pub(super) fn no_session_key(root: &Path, id: uuid::Uuid) {
    let library = model::Library::open(root.into()).unwrap();
    let mut vault = Vault::open(&library).unwrap();
    assert!(!vault.is_unlocked() && vault.body(id).is_err());
}
pub(super) fn edit(document: &mut Document, id: uuid::Uuid, body: &[u8], key: &RootKey) {
    let salt = document.salt().unwrap();
    let record = document
        .records
        .iter_mut()
        .find(|r| r.metadata.id == id)
        .unwrap();
    record.sealed = crypto::seal_record(body, key, &salt, &document.kid, id, false).unwrap();
    record.content_hash = crypto::content_hash(body, key, &salt);
    record.metadata.updated_at = chrono::Utc::now() + chrono::Duration::seconds(1);
    record.hlc = None;
}

#[test]
#[ignore = "explicit native manual/vault GTK/HTTPS/keyring acceptance; invoke tests/account-live.sh with --vault-sync"]
fn live_manual_and_vault_sync() {
    let root = isolated_root();
    let fixture = server::Fixture::new();
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    parent.set_title(Some("Public Native Manual and Vault Sync Acceptance"));
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    connect_keys(&window, &fixture);
    let installed = slot(&root, Slot::LibraryKey).unwrap();
    let (key, salt) = wire_material(&root);

    let local = model::Snippet::new("Public manual local", "Public manual local body");
    let remote = model::Snippet::new("Public manual remote", "Public manual remote body");
    model::Library::open(root.clone())
        .unwrap()
        .save(local.clone(), None)
        .unwrap();
    fixture
        .state
        .lock()
        .unwrap()
        .put(remote_record(&remote, 1, &key, &salt));
    action(&window, "Receive Cloud Changes");
    assert!(
        window.status.label() == "Cloud changes received. Local changes have not been sent."
            && local_has(&root, &remote)
            && local_has(&root, &local)
    );
    assert!(fixture.state.lock().unwrap().batches == 0);
    action(&window, "Send Local Changes");
    assert!(
        window.status.label()
            == "Local changes confirmed by the cloud. Receive Cloud Changes to check other devices."
    );
    assert!(uploaded_has(&fixture, &local, &key, &salt));
    action(&window, "Sync Now");
    assert!(window.status.label() == CURRENT);
    assert!(
        !crate::auto_sync::Preference::read(&root).unwrap().enabled()
            && !root.join("automatic-sync.json").exists()
    );
    assert!(slot(&root, Slot::AutomaticSync).is_none());

    let independent: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut incoming =
        Document::decode(&serde_json::to_vec(&independent["document"]).unwrap()).unwrap();
    let incoming_id = incoming.records[0].metadata.id;
    let vault_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let vault_salt = incoming.salt().unwrap();
    let mut current = incoming.clone();
    current.records.clear();
    let local_secure = crate::vault::Metadata::new();
    let local_body = b"Public native local secure body";
    current.records.push(Record {
        metadata: local_secure.clone(),
        sealed: crypto::seal_record(
            local_body,
            &vault_key,
            &vault_salt,
            &current.kid,
            local_secure.id,
            false,
        )
        .unwrap(),
        content_hash: crypto::content_hash(local_body, &vault_key, &vault_salt),
        hlc: None,
        extra: Default::default(),
    });
    fs::create_dir(root.join("Vault")).unwrap();
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    current = Document::decode(&current.encode().unwrap()).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &current.encode().unwrap()).unwrap();
    let original = projected(&incoming, incoming_id);
    fixture
        .state
        .lock()
        .unwrap()
        .put(WireRecord::seal(&original, &key, &salt).unwrap());
    action(&window, "Sync Now");
    // Explicit same-vault routing admits sealed exchange without opening bodies
    // or granting an editor session. Legacy unmarked changes need fresh proof.
    assert!(window.status.label() == CURRENT);
    current = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(current.records.len() == 2);
    assert!(
        body(&current, incoming_id, &vault_key).as_slice()
            == independent["plaintext"].as_str().unwrap().as_bytes()
    );
    assert!(body(&current, local_secure.id, &vault_key).as_slice() == local_body);
    assert!(uploaded(&fixture, local_secure.id, &key, &salt).secure);
    no_session_key(&root, incoming_id);
    let local_body = b"Public native local secure body after edit";
    edit(&mut current, local_secure.id, local_body, &vault_key);
    current = Document::decode(&current.encode().unwrap()).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &current.encode().unwrap()).unwrap();
    let remote_body = b"Public native legacy remote secure edit";
    edit(&mut incoming, incoming_id, remote_body, &vault_key);
    let mut legacy = projected(&incoming, incoming_id);
    legacy.extensions.remove("vaultKID");
    fixture
        .state
        .lock()
        .unwrap()
        .put(WireRecord::seal(&legacy, &key, &salt).unwrap());
    action(&window, "Sync Now");
    assert!(window.status.label() == LOCKED);
    assert!(crate::vault::read_document(&root).unwrap().unwrap() == current);
    let previous_sent = uploaded(&fixture, local_secure.id, &key, &salt)
        .encode()
        .unwrap();
    let before = primary(&root);
    let counts = data_counts(&fixture);

    let (dialog, entry) = vault_dialog(&window);
    entry.set_text("Public cancelled vault credential");
    press(dialog.upcast_ref(), "Cancel");
    finished(&window, &entry);
    assert!(window.status.label() == "Vault verification cancelled.");
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    assert!(
        uploaded(&fixture, local_secure.id, &key, &salt)
            .encode()
            .unwrap()
            == previous_sent
    );

    credential(&window, "Public incorrect vault passphrase", false);
    assert!(window.status.label() == Failure::VaultAuthentication.message());
    assert!(primary(&root) == before && data_counts(&fixture) == counts);

    let (_dialog, entry) = vault_dialog(&window);
    entry.set_text(independent["passphrase"].as_str().unwrap());
    parent.present();
    until(
        "vault-sync focus revocation did not clear credentials",
        || parent.is_active() && window.vault_sync_dialog.borrow().is_none() && !window.busy.get(),
    );
    finished(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    window.window.present();
    until("vault-sync account did not regain focus", || {
        window.window.is_active()
    });

    // Identical bytes with a new source identity cannot reuse a captured permit.
    let (dialog, entry) = vault_dialog(&window);
    model::atomic_write(&root.join("Vault/vault.json"), &before[1]).unwrap();
    entry.set_text(independent["passphrase"].as_str().unwrap());
    press(dialog.upcast_ref(), "Verify and Sync");
    finished(&window, &entry);
    assert!(window.status.label() == Failure::VaultAuthentication.message());
    assert!(primary(&root) == before && data_counts(&fixture) == counts);

    credential(&window, independent["passphrase"].as_str().unwrap(), false);
    assert!(window.status.label() == CURRENT);
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(saved.records.len() == 2);
    assert!(body(&saved, incoming_id, &vault_key).as_slice() == remote_body);
    assert!(body(&saved, local_secure.id, &vault_key).as_slice() == local_body);
    let sent = uploaded(&fixture, local_secure.id, &key, &salt);
    let local_record = current
        .records
        .iter()
        .find(|r| r.metadata.id == local_secure.id)
        .unwrap();
    assert!(
        sent.secure
            && !sent.deleted
            && sent.fields.as_ref().unwrap().content.as_slice()
                == local_record.sealed.text().as_bytes()
    );
    assert!(sent.extensions["vaultContentHash"].as_text().unwrap() == local_record.content_hash);
    no_session_key(&root, incoming_id);

    let next_body = b"Public native remote secure edit";
    edit(&mut incoming, incoming_id, next_body, &vault_key);
    let mut next = projected(&incoming, incoming_id);
    next.extensions.remove("vaultKID");
    fixture
        .state
        .lock()
        .unwrap()
        .put(WireRecord::seal(&next, &key, &salt).unwrap());
    let saved_bytes = fs::read(root.join("Vault/vault.json")).unwrap();
    action(&window, "Sync Now");
    assert!(window.status.label() == LOCKED);
    assert!(fs::read(root.join("Vault/vault.json")).unwrap() == saved_bytes);
    no_session_key(&root, incoming_id);
    let recovery = crypto::format_recovery(&[0x66; 16]);
    credential(&window, &recovery, true);
    assert!(window.status.label() == CURRENT);
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(
        saved.records.len() == 2 && body(&saved, incoming_id, &vault_key).as_slice() == next_body
    );
    assert!(body(&saved, local_secure.id, &vault_key).as_slice() == local_body);
    assert!(local_has(&root, &remote) && local_has(&root, &local));
    no_session_key(&root, incoming_id);
    for name in ["snippets.json", "Vault/vault.json", "Sync/journal.bin"] {
        let bytes = fs::read(root.join(name)).unwrap();
        for plaintext in [
            local_body.as_slice(),
            remote_body.as_slice(),
            next_body.as_slice(),
            independent["plaintext"].as_str().unwrap().as_bytes(),
        ] {
            assert!(!bytes.windows(plaintext.len()).any(|v| v == plaintext));
        }
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
