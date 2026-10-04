//! Mapped same-vault history restoration with independently wrapped public data.
use super::*;
use crate::{
    account_worker::RestorationInterruption,
    crypto::{self, RootKey},
    key_store::history::SwitchPhase,
    vault::{Document, Record},
};

const CURRENT: &str =
    "Synchronization complete. Cloud changes received and local changes confirmed.";
const LATER: &[u8] = b"Public current secure restoration body";
const NEWER: &[u8] = b"Public newer secure restoration body after review";

#[path = "account_restoration_file_live_tests.rs"]
pub(super) mod files;
#[path = "account_mixed_restoration_live_tests.rs"]
pub(super) mod mixed;

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
fn credentials(
    window: &Rc<AccountWindow>,
    foreign: bool,
    file: Option<&files::Input>,
) -> (adw::AlertDialog, Vec<gtk::PasswordEntry>) {
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
    assert!(previous.len() == 1 && previous[0].is_active() == foreign);
    let modes = toggles(&dialog, "Use recovery key");
    assert!(
        modes.len() == 2
            && modes[0].is_visible()
            && modes[0].is_sensitive()
            && !modes[0].is_active()
    );
    if let Some(file) = file {
        files::select(window, &dialog, &entries, file)
    } else {
        (dialog, entries)
    }
}
fn reviewed(
    window: &Rc<AccountWindow>,
    value: &str,
    recovery: bool,
    previous: Option<(&str, &str)>,
    file: Option<&files::Input>,
) -> adw::AlertDialog {
    let (dialog, entries) = credentials(window, previous.is_some(), file);
    toggles(&dialog, "Use recovery key")[0].set_active(recovery);
    entries[0].set_text(value);
    if let Some((passphrase, key)) = previous {
        let old_recovery = !recovery && file.is_none_or(|f| !f.backup());
        toggles(&dialog, "Use recovery key")[1].set_active(old_recovery);
        entries[1].set_text(if old_recovery { key } else { passphrase });
    }
    press(dialog.upcast_ref(), "Verify Saved Changes");
    until_for(
        "native secure restoration review did not map",
        Duration::from_secs(45),
        || {
            window
                .snapshot_dialog
                .borrow()
                .as_ref()
                .is_some_and(|d| d.is_mapped())
        },
    );
    assert!(
        window.restoration_dialog.borrow().is_none() && entries.iter().all(|e| e.text().is_empty())
    );
    let review = window.snapshot_dialog.borrow().clone().unwrap();
    assert!(review.heading().as_deref() == Some("Restore the Saved Changes?"));
    assert!(
        review
            .body()
            .contains("Saved secure changes will use the current vault's encryption.")
            == previous.is_some()
    );
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
    previous: Option<(&str, &str)>,
    file: Option<&files::Input>,
) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let review = reviewed(window, value, recovery, previous, file);
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
#[test]
#[ignore = "explicit native retained foreign-vault history GTK/HTTPS/private-keyring/private-PAM acceptance; invoke tests/account-live.sh with --foreign-restoration"]
fn live_retained_foreign_vault_history_restoration() {
    creation::run(creation::Followup::ForeignRestoration);
}
#[test]
#[ignore = "explicit real GTK chooser and external JSON vault restoration; invoke tests/account-live.sh with --file-restoration"]
fn live_external_json_vault_history_restoration() {
    creation::run(creation::Followup::ExternalRestoration(
        files::Kind::VaultJson,
    ));
}
#[test]
#[ignore = "explicit real GTK chooser and external independently encrypted backup restoration; invoke tests/account-live.sh with --backup-file-restoration"]
fn live_external_backup_vault_history_restoration() {
    creation::run(creation::Followup::ExternalRestoration(
        files::Kind::EncryptedBackup,
    ));
}
struct RestorationContext<'a> {
    window: &'a Rc<AccountWindow>,
    app: &'a adw::Application,
    parent: &'a adw::ApplicationWindow,
    root: &'a Path,
    fixture: &'a server::Fixture,
    pam: &'a Pam,
    ordinary: &'a model::Snippet,
}
enum Scenario {
    SameVault,
    Interrupted(RestorationInterruption),
    ForeignVault,
    ExternalVault(files::Kind),
    MixedVault(mixed::Mode),
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
    run_interrupted(window, app, parent, root, fixture, pam, ordinary, None);
}
#[allow(clippy::too_many_arguments)]
pub(super) fn run_interrupted(
    window: &Rc<AccountWindow>,
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
    ordinary: &model::Snippet,
    boundary: Option<RestorationInterruption>,
) {
    run_case(
        RestorationContext {
            window,
            app,
            parent,
            root,
            fixture,
            pam,
            ordinary,
        },
        boundary.map_or(Scenario::SameVault, Scenario::Interrupted),
    );
}
pub(super) fn run_foreign(
    window: &Rc<AccountWindow>,
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
    ordinary: &model::Snippet,
) {
    run_case(
        RestorationContext {
            window,
            app,
            parent,
            root,
            fixture,
            pam,
            ordinary,
        },
        Scenario::ForeignVault,
    );
}
#[allow(clippy::too_many_arguments)]
pub(super) fn run_external(
    window: &Rc<AccountWindow>,
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
    ordinary: &model::Snippet,
    kind: files::Kind,
) {
    run_case(
        RestorationContext {
            window,
            app,
            parent,
            root,
            fixture,
            pam,
            ordinary,
        },
        Scenario::ExternalVault(kind),
    );
}
#[allow(clippy::too_many_arguments)]
pub(super) fn run_mixed(
    window: &Rc<AccountWindow>,
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
    ordinary: &model::Snippet,
    mode: mixed::Mode,
) {
    run_case(
        RestorationContext {
            window,
            app,
            parent,
            root,
            fixture,
            pam,
            ordinary,
        },
        Scenario::MixedVault(mode),
    );
}
fn run_case(context: RestorationContext<'_>, scenario: Scenario) {
    let RestorationContext {
        window,
        app,
        parent,
        root,
        fixture,
        pam,
        ordinary,
    } = context;
    let foreign = matches!(
        scenario,
        Scenario::ForeignVault | Scenario::ExternalVault(_) | Scenario::MixedVault(_)
    );
    let boundary = if let Scenario::Interrupted(boundary) = scenario {
        Some(boundary)
    } else {
        None
    };
    reconnect(window, 1);
    let fixture_data: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let passphrase = fixture_data["passphrase"].as_str().unwrap();
    let original_body = fixture_data["plaintext"].as_str().unwrap().as_bytes();
    let key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    let recovery = crypto::format_recovery(&[0x66; 16]);
    let initial =
        Document::decode(&serde_json::to_vec(&fixture_data["document"]).unwrap()).unwrap();
    let file = if let Scenario::ExternalVault(kind) = scenario {
        Some(files::Input::new(root, kind, &initial))
    } else {
        None
    };
    let mixed = if let Scenario::MixedVault(mode) = scenario {
        Some(mixed::Inputs::new(root, mode, &initial))
    } else {
        None
    };
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
    let source_archived = document(root)
        .records
        .into_iter()
        .find(|r| r.metadata.id == secure_id)
        .unwrap();
    if let Some(mixed) = &mixed {
        mixed.install_legacy_source(root);
    }
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
    assert!(dialog.body().contains(if mixed.is_some() {
        "Keep 3 local records and 0 saved conflict copies"
    } else {
        "Keep 2 local records and 0 saved conflict copies"
    }));
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
    // The source history retains vault A. Install independent public vault B
    // before the target's first protected sync, preserving real current CAS/feed.
    let current_fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../tests/fixtures/restoration-current-vault-v1.json"
    ))
    .unwrap();
    let (key, passphrase, recovery, initial) = if foreign {
        let mut current =
            Document::decode(&serde_json::to_vec(&current_fixture["document"]).unwrap()).unwrap();
        assert!(!current.same_identity(&initial));
        if let Some(mixed) = &mixed {
            mixed.install_current(root, &mut current);
        }
        write(root, &current);
        (
            RootKey::from_bytes(&[0x44; 32]).unwrap(),
            current_fixture["passphrase"].as_str().unwrap(),
            crypto::format_recovery(&[0x99; 16]),
            current,
        )
    } else {
        (key, passphrase, recovery, initial)
    };
    sync(window, passphrase, false);
    if let Some(mixed) = mixed {
        mixed.run(mixed::Context {
            native: RestorationContext {
                window,
                app,
                parent,
                root,
                fixture,
                pam,
                ordinary,
            },
            archived: source_archived,
            source_wire,
            initial,
        });
        return;
    }
    let (checkpoint, catalog) = switching::checkpoint_and_history(root);
    assert!(catalog.switches.len() == 3 && catalog.restorations.is_empty());
    assert!(
        checkpoint.journal.confirmed(secure_id).is_some()
            && checkpoint.journal.inbox.cursor().is_some()
    );
    let current_record = document(root)
        .records
        .into_iter()
        .find(|r| r.metadata.id == secure_id)
        .unwrap();
    let archived = if foreign {
        source_archived
    } else {
        current_record
    };
    let old_recovery = crypto::format_recovery(&[0x66; 16]);
    let previous = foreign.then_some((
        file.as_ref()
            .map_or(fixture_data["passphrase"].as_str().unwrap(), |f| {
                f.passphrase(fixture_data["passphrase"].as_str().unwrap())
            }),
        old_recovery.as_str(),
    ));
    let credentials = |window: &Rc<AccountWindow>| {
        let (dialog, entries) = credentials(window, foreign, file.as_ref());
        if let Some((old_passphrase, _)) = previous {
            entries[1].set_text(old_passphrase);
        }
        (dialog, entries)
    };
    let reviewed = |window: &Rc<AccountWindow>, value: &str, recovery: bool| {
        reviewed(window, value, recovery, previous, file.as_ref())
    };
    let password = |window: &Rc<AccountWindow>, value: &str, recovery: bool| {
        password(window, value, recovery, previous, file.as_ref())
    };
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
    if foreign {
        let file = root.join("Vault/vault.json");
        let saved = Zeroizing::new(fs::read(&file).unwrap());
        fs::remove_file(&file).unwrap();
        let missing = creation::images(root);
        press(window.window.upcast_ref(), "Library Recovery History…");
        until("missing-current-vault history did not map", || {
            window
                .history_dialog
                .borrow()
                .as_ref()
                .is_some_and(|d| d.is_mapped())
        });
        let history = window.history_dialog.borrow().clone().unwrap();
        let selected = restoration_live::selected_review(&history, "Switch 3 · finished locally");
        until("missing-current-vault restoration row did not map", || {
            selected.is_mapped() && selected.is_sensitive()
        });
        selected.emit_clicked();
        finished(window, &[]);
        assert!(
            creation::images(root) == missing && restoration_live::protected(root) == protected
        );
        assert!(slot(root, Slot::HistoryRestore).is_none() && !file.exists());
        let state = fixture.state.lock().unwrap();
        assert!((state.fetches, state.batches, state.accepted) == counts);
        drop(state);
        model::atomic_write(&file, &saved).unwrap();
        unchanged();
        println!(
            "Native missing-current-vault metadata refused before credentials, review or receipt; primary images, checkpoint, protected keys and data plane remained exact."
        );
    }
    if file.is_some() {
        files::cancel(
            window,
            passphrase,
            fixture_data["passphrase"].as_str().unwrap(),
        );
        unchanged();
        println!(
            "Actual GTK chooser cancellation cleared both prefilled vault credentials and preserved primary images, keys and data plane."
        );
    }
    let (dialog, entries) = credentials(window);
    entries[0].set_text(passphrase);
    press(dialog.upcast_ref(), "Cancel");
    finished(window, &entries);
    unchanged();
    if let Some((old_passphrase, _)) = previous {
        for (current, old) in [(old_passphrase, passphrase), (passphrase, passphrase)] {
            let (dialog, entries) = credentials(window);
            entries[0].set_text(current);
            entries[1].set_text(old);
            press(dialog.upcast_ref(), "Verify Saved Changes");
            finished(window, &entries);
            unchanged();
        }
        let (dialog, entries) = credentials(window);
        entries[0].set_text(passphrase);
        toggles(&dialog, "Saved changes use a previous vault")[0].set_active(false);
        assert!(entries[1].text().is_empty());
        press(dialog.upcast_ref(), "Verify Saved Changes");
        finished(window, &entries);
        unchanged();
        println!(
            "Native foreign-vault restoration: source/current credential swaps, wrong previous password and current-only verification refused the whole ordinary/protected selection without receipt, files, keys or data-plane changes."
        );
    }
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
    if let Some(file) = &file {
        let (dialog, entry) = password(window, passphrase, false);
        file.change();
        entry.set_text("Public fictional password");
        press(dialog.upcast_ref(), "Authorize");
        finished(window, std::slice::from_ref(&entry));
        unchanged();
        file.restore();
        assert!(!window.sync.is_sensitive());
        reconnect(window, 2);
        println!(
            "Changed selected external file refused the whole reviewed restoration after fresh PAM, before receipt or primary writes; exact current library, protected keys and data plane remained unchanged."
        );
    }
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
    let interrupted_window = boundary.map(|boundary| {
        until("pre-interruption worker did not drain", || {
            window.prepare_quit()
        });
        window.window.destroy();
        make_window_with_interruption(app, parent, root, fixture, pam, Some(boundary))
    });
    let _interrupted_stop = interrupted_window.as_ref().map(|w| Stop(w.clone()));
    let window = interrupted_window.as_ref().unwrap_or(window);
    reconnect(window, 2);
    let authorized_before = creation::images(root);
    let (dialog, entry) = password(window, &recovery, true);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(window, std::slice::from_ref(&entry));
    let completion_window = boundary.and_then(|boundary| {
        finish_interrupted(
            InterruptedContext {
                window,
                app,
                parent,
                root,
                fixture,
                pam,
            },
            boundary,
            &authorized_before,
            unrelated.id,
        )
    });
    if boundary.is_some() && completion_window.is_none() {
        return;
    }
    let _completion_stop = completion_window.as_ref().map(|w| Stop(w.clone()));
    let window = completion_window.as_ref().unwrap_or(window);
    assert!(
        window.status.label()
            == "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing."
    );
    assert!(
        !window.sync.is_sensitive()
            && !window.receive.is_sensitive()
            && !window.send.is_sensitive()
    );
    // A restarted, never-connected window has an empty GTK model; the same
    // explicit reconnect gate uses its placeholder row after library listing.
    let empty = window
        .libraries
        .model()
        .is_some_and(|model| model.n_items() == 0);
    assert!(window.libraries.selected() == if empty { gtk::INVALID_LIST_POSITION } else { 0 });
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
    if foreign {
        let current = document(root);
        let restored = current
            .records
            .iter()
            .find(|r| r.metadata.id == secure_id)
            .unwrap();
        assert!(
            crypto::open_record(
                &restored.sealed,
                &RootKey::from_bytes(&[0x11; 32]).unwrap(),
                &crypto::unb64(fixture_data["document"]["vaultSalt"].as_str().unwrap())
                    .unwrap()
                    .try_into()
                    .unwrap(),
                fixture_data["document"]["kid"].as_str().unwrap(),
                secure_id,
                false
            )
            .is_err()
        );
        assert!(restored.sealed != archived.sealed);
        let reference =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/restoration-vault.py");
        assert!(
            Process::new("python3")
                .arg(reference)
                .arg("--verify")
                .arg(root.join("Vault/vault.json"))
                .status()
                .unwrap()
                .success()
        );
    }
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
    let mut final_header = document(root);
    final_header.records.clear();
    assert!(final_header == original_header);
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
        assert!(decoded.extensions["vaultKID"].as_text().unwrap() == doc.kid);
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
    if foreign {
        let reference =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/restoration-vault.py");
        assert!(
            Process::new("python3")
                .arg(reference)
                .arg("--verify")
                .arg(root.join("Vault/vault.json"))
                .status()
                .unwrap()
                .success()
        );
    }
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
        "Native {} history restoration: independent current/retained wraps, whole ordinary/secure review, stale ciphertext refusal, fresh PAM, disabled sealed current-version preservation, unrelated ordinary/secure retention, exact current CAS/feed, completed history, new-worker reconnect and authenticated encrypted copy-before-source synchronization passed.",
        if foreign {
            "foreign-vault"
        } else {
            "same-vault"
        }
    );
}

#[test]
#[ignore = "explicit native interrupted-restoration consent cancellation; invoke tests/account-live.sh with --restore-cancel-consent"]
fn live_restoration_cancel_after_consent() {
    creation::run(creation::Followup::SecureRestorationInterrupted(
        RestorationInterruption::Consent,
    ));
}
#[test]
#[ignore = "explicit native interrupted-restoration baseline cancellation; invoke tests/account-live.sh with --restore-cancel-baseline"]
fn live_restoration_cancel_after_baseline() {
    creation::run(creation::Followup::SecureRestorationInterrupted(
        RestorationInterruption::Baseline,
    ));
}
#[test]
#[ignore = "explicit native partial ordinary/vault restoration completion; invoke tests/account-live.sh with --restore-finish-ordinary"]
fn live_restoration_finish_after_ordinary() {
    creation::run(creation::Followup::SecureRestorationInterrupted(
        RestorationInterruption::Ordinary,
    ));
}
#[test]
#[ignore = "explicit native pending-receipt restoration completion; invoke tests/account-live.sh with --restore-finish-vault"]
fn live_restoration_finish_after_vault() {
    creation::run(creation::Followup::SecureRestorationInterrupted(
        RestorationInterruption::Vault,
    ));
}
struct InterruptedContext<'a> {
    window: &'a Rc<AccountWindow>,
    app: &'a adw::Application,
    parent: &'a adw::ApplicationWindow,
    root: &'a Path,
    fixture: &'a server::Fixture,
    pam: &'a Pam,
}
fn retained_images(root: &Path) -> Vec<(PathBuf, Zeroizing<Vec<u8>>)> {
    let mut paths = fs::read_dir(root.join("Sync/Reviews"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .collect::<Vec<_>>();
    paths.sort();
    paths
        .into_iter()
        .map(|path| {
            assert!(path.symlink_metadata().unwrap().file_type().is_file());
            let bytes = Zeroizing::new(fs::read(&path).unwrap());
            (path, bytes)
        })
        .collect()
}
fn continuation_review(window: &Rc<AccountWindow>, cancel: bool) -> Option<adw::AlertDialog> {
    press(window.window.upcast_ref(), "Library Recovery History…");
    until("interrupted restoration history did not map", || {
        window
            .history_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    let history = window.history_dialog.borrow().clone().unwrap();
    let mut widgets = vec![history.clone().upcast::<gtk::Widget>()];
    let mut row = None;
    while let Some(widget) = widgets.pop() {
        if let Some(candidate) = widget.downcast_ref::<adw::ActionRow>()
            && candidate.title() == "Complete Saved Restoration"
        {
            assert!(row.is_none());
            row = Some(candidate.clone());
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    press(
        row.unwrap().upcast_ref(),
        if cancel { "Cancel…" } else { "Finish…" },
    );
    until("interrupted restoration preparation did not finish", || {
        !window.busy.get()
            || window
                .snapshot_dialog
                .borrow()
                .as_ref()
                .is_some_and(|d| d.is_mapped())
    });
    let review = window.snapshot_dialog.borrow().clone();
    if let Some(review) = &review {
        assert!(
            review.heading().as_deref()
                == Some(if cancel {
                    "Cancel the Saved Restoration?"
                } else {
                    "Finish the Saved Restoration?"
                })
        );
        assert!(
            review.default_response().as_deref() == Some("back")
                && review.close_response() == "back"
        );
        assert!(
            review
                .body()
                .contains("2 saved records · 2 preserved current versions · 1 secure records")
        );
    }
    assert!(window.restoration_dialog.borrow().is_none());
    review
}
fn continuation_password(
    window: &Rc<AccountWindow>,
    cancel: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let review = continuation_review(window, cancel).unwrap();
    press(
        review.upcast_ref(),
        if cancel {
            "Cancel Restoration"
        } else {
            "Restore Changes"
        },
    );
    until("interrupted restoration PAM dialog did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(
        dialog.heading().as_deref()
            == Some(if cancel {
                "Authorize Restoration Cancellation"
            } else {
                "Authorize Restoration Completion"
            })
    );
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    assert!(!entry.shows_peek_icon() && window.restoration_dialog.borrow().is_none());
    (dialog, entry)
}
fn finish_interrupted(
    context: InterruptedContext<'_>,
    boundary: RestorationInterruption,
    before: &[Option<Zeroizing<Vec<u8>>>],
    unrelated: uuid::Uuid,
) -> Option<Rc<AccountWindow>> {
    let InterruptedContext {
        window,
        app,
        parent,
        root,
        fixture,
        pam,
    } = context;
    let cancel = matches!(
        boundary,
        RestorationInterruption::Consent | RestorationInterruption::Baseline
    );
    let (frozen, catalog) = switching::checkpoint_and_history(root);
    assert!(catalog.switches.len() == 3 && catalog.restorations.len() == 1);
    let pending = &catalog.restorations[0];
    assert!(pending.phase == SwitchPhase::Pending && pending.needs_completion);
    let actual = creation::images(root);
    match boundary {
        RestorationInterruption::Consent => {
            assert!(actual == before && !root.join("Sync/primary.pending").exists())
        }
        RestorationInterruption::Baseline => {
            assert!(actual[..2] == before[..2] && actual[2] != before[2])
        }
        RestorationInterruption::Ordinary => {
            assert!(actual[0] != before[0] && actual[1] == before[1])
        }
        RestorationInterruption::Vault => {
            assert!(actual[0] != before[0] && actual[1] != before[1])
        }
    }
    if !matches!(boundary, RestorationInterruption::Consent) {
        assert!(root.join("Sync/primary.pending").is_file());
    }
    let expected = frozen
        .journal
        .primary_intent
        .as_ref()
        .map(|intent| (intent.after_plain.clone(), intent.after_vault.clone()));
    assert!(expected.is_some() != cancel);
    if matches!(boundary, RestorationInterruption::Baseline) {
        // A noncooperative external writer after the baseline: cancellation
        // may preserve this edit but must never start the approved redo.
        let mut records = model::decode_library(actual[0].as_deref().unwrap(), false).unwrap();
        records
            .iter_mut()
            .find(|record| record.id == unrelated)
            .unwrap()
            .content = "Public later external edit preserved by baseline cancellation".into();
        model::atomic_write(
            &root.join("snippets.json"),
            &model::encode_library(&records, false).unwrap(),
        )
        .unwrap();
    }
    let primary = creation::images(root);
    let protected = restoration_live::protected(root);
    let receipt = slot(root, Slot::HistoryRestore).unwrap();
    let retained = retained_images(root);
    let marker = model::read_regular(&root.join("Sync/primary.pending")).unwrap();
    let requests = {
        let mut state = fixture.state.lock().unwrap();
        state.offline = true;
        state.requests
    };
    let unchanged = || {
        assert!(creation::images(root) == primary);
        assert!(restoration_live::protected(root) == protected);
        assert!(slot(root, Slot::HistoryRestore).as_ref() == Some(&receipt));
        assert!(retained_images(root) == retained);
        assert!(model::read_regular(&root.join("Sync/primary.pending")).unwrap() == marker);
        assert!(fixture.state.lock().unwrap().requests == requests);
    };
    assert!(!window.sync.is_sensitive() && window.libraries.selected() == 0);
    until(
        "interrupted native worker did not release durable operation",
        || window.prepare_quit(),
    );
    window.window.destroy();
    let reopened = make_window(app, parent, root, fixture, pam);
    let stop = cancel.then(|| Stop(reopened.clone()));
    unchanged();
    if !cancel {
        assert!(continuation_review(&reopened, true).is_none());
        finished(&reopened, &[]);
        unchanged();
    }
    let review = continuation_review(&reopened, cancel).unwrap();
    press(review.upcast_ref(), "Keep Current State");
    finished(&reopened, &[]);
    unchanged();
    let _review = continuation_review(&reopened, cancel).unwrap();
    parent.present();
    until("continuation review focus loss did not revoke", || {
        parent.is_active() && !reopened.busy.get()
    });
    finished(&reopened, &[]);
    unchanged();
    refocus(&reopened);
    for (value, response) in [
        ("Public fictional password", "Cancel"),
        ("Public incorrect password", "Authorize"),
    ] {
        let (dialog, entry) = continuation_password(&reopened, cancel);
        entry.set_text(value);
        press(dialog.upcast_ref(), response);
        finished(&reopened, std::slice::from_ref(&entry));
        unchanged();
    }
    let (_dialog, entry) = continuation_password(&reopened, cancel);
    entry.set_text("Public fictional password");
    parent.present();
    until("continuation PAM focus loss did not revoke", || {
        parent.is_active() && !reopened.busy.get()
    });
    finished(&reopened, std::slice::from_ref(&entry));
    unchanged();
    refocus(&reopened);
    let (dialog, entry) = continuation_password(&reopened, cancel);
    entry.set_text("Public fictional password");
    press(dialog.upcast_ref(), "Authorize");
    finished(&reopened, std::slice::from_ref(&entry));
    assert!(fixture.state.lock().unwrap().requests == requests);
    assert!(restoration_live::protected(root) == protected && retained_images(root) == retained);
    assert!(!root.join("Sync/primary.pending").exists());
    let (completed, catalog) = switching::checkpoint_and_history(root);
    assert!(frozen.journal.preserves_transport_state(&completed.journal));
    let saved = &catalog.restorations[0];
    assert!(
        saved.phase
            == if cancel {
                SwitchPhase::Cancelled
            } else {
                SwitchPhase::Completed
            }
    );
    assert!(
        !saved.needs_completion && catalog.switches.len() == 3 && catalog.restorations.len() == 1
    );
    assert!(
        saved.summary.restored_records == 2
            && saved.summary.preserved_versions == 2
            && saved.summary.secure_records == 1
    );
    if cancel {
        assert!(creation::images(root) == primary && frozen.journal == completed.journal);
        assert!(
            reopened.status.label()
                == "Saved restoration cancelled. Current changes and previous states are kept. Reconnect and select a library before syncing."
        );
        let terminal = slot(root, Slot::HistoryRestore).unwrap();
        until("cancelled restoration worker did not drain", || {
            reopened.prepare_quit()
        });
        reopened.window.destroy();
        let again = make_window(app, parent, root, fixture, pam);
        let again_stop = Stop(again.clone());
        assert!(
            creation::images(root) == primary && restoration_live::protected(root) == protected
        );
        assert!(
            slot(root, Slot::HistoryRestore).as_ref() == Some(&terminal)
                && retained_images(root) == retained
        );
        let (_, catalog) = switching::checkpoint_and_history(root);
        assert!(
            catalog.restorations[0].phase == SwitchPhase::Cancelled
                && !catalog.restorations[0].needs_completion
        );
        assert!(fixture.state.lock().unwrap().requests == requests);
        until("fresh cancelled restoration worker did not drain", || {
            again.prepare_quit()
        });
        drop(again_stop);
        fixture.state.lock().unwrap().offline = false;
        drop(stop);
        println!(
            "Native interrupted restoration: durable consent/baseline cancellation, fresh-worker offline history, default/review/PAM/focus refusal, exact current files including later external intent, all protected keys, retained encrypted pair, terminal receipt and second restart passed."
        );
        None
    } else {
        let expected = expected.unwrap();
        let final_images = creation::images(root);
        assert!(final_images[0] == expected.0 && final_images[1] == expected.1);
        if matches!(boundary, RestorationInterruption::Vault) {
            assert!(final_images[..2] == primary[..2]);
        }
        fixture.state.lock().unwrap().offline = false;
        // Keep this completed window alive for the independent preservation,
        // second-worker reconnect and encrypted exchange assertions in run.
        drop(stop);
        println!(
            "Native interrupted restoration: partial ordinary/vault write, cancellation refusal after WAL, fresh-worker offline ciphertext-only finish, default/review/PAM/focus refusal, exact approved images/nonces, all keys, retained encrypted pair and terminal receipt passed."
        );
        Some(reopened)
    }
}
