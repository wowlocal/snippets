//! Already listed Unknown pending raw-child decisions, before the parent.
//! The native owner captures the raw primary graph. Only the retained pending
//! deletion is seeded with Journal::desire; no original, offer or receipt is made up.
use super::*;

const STAGE: &str = "SNIPPETS_RAW_CHILD_STAGE";

fn no_worker() -> bool {
    !fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|item| item.ok())
        .any(|item| {
            fs::read_to_string(item.path().join("comm"))
                // Linux task comm retains at most fifteen bytes.
                .is_ok_and(|name| name.trim() == "snippets-accoun")
        })
}

pub(super) fn entrypoint(delete: bool) -> bool {
    if std::env::var_os(STAGE).is_none() {
        return false;
    }
    assert_eq!(std::env::var(STAGE).as_deref(), Ok("retained-unknown"));
    run(delete);
    true
}

pub(super) fn process(delete: bool) {
    assert!(no_worker());
    let owned = tempfile::tempdir_in(std::env::var_os("XDG_DATA_HOME").unwrap()).unwrap();
    for name in ["data", "config", "cache"] {
        fs::create_dir(owned.path().join(name)).unwrap();
        fs::set_permissions(owned.path().join(name), fs::Permissions::from_mode(0o700)).unwrap();
    }
    let name = if delete {
        "account_ui::live_tests::vault::review::current::prior_child::live_prior_child_delete_parent_keep"
    } else {
        "account_ui::live_tests::vault::review::current::prior_child::live_prior_child_keep_parent_keep"
    };
    assert!(
        Process::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                name,
                "--ignored",
                "--test-threads=1",
                "--nocapture"
            ])
            .env(STAGE, "retained-unknown")
            .env("XDG_DATA_HOME", owned.path().join("data"))
            .env("XDG_CONFIG_HOME", owned.path().join("config"))
            .env("XDG_CACHE_HOME", owned.path().join("cache"))
            .env(
                "SNIPPETS_SECRET_TEST_ROOT",
                owned.path().join("data/snippets")
            )
            .status()
            .unwrap()
            .success()
    );
    assert!(no_worker());
}

fn retain_pending(root: &Path, deleted: &Envelope) {
    let root = root.to_owned();
    let deleted = deleted.clone();
    let (sender, receiver) = mpsc::channel();
    let worker = thread::spawn(move || {
        let mut store = Store::load(&root, Native::new().unwrap()).unwrap();
        store
            .transaction_with::<_, crate::secret_store::Failure>(|owner| {
                let binding = crate::key_store::installed_binding_locked(owner)
                    .unwrap()
                    .unwrap();
                let material = owner.checkpoint_material(false)?.unwrap();
                let key = RootKey::from_bytes(&material[..32]).unwrap();
                let salt = material[32..].try_into().unwrap();
                let library = model::Library::open(root.clone()).unwrap();
                let _guard = library.lock().unwrap();
                let mut checkpoint = crate::journal::Checkpoint::load_locked(
                    &library,
                    &key,
                    &salt,
                    binding.checkpoint_scope(),
                )
                .unwrap();
                assert!(checkpoint.journal.confirmed(deleted.id).is_none());
                assert!(
                    checkpoint
                        .journal
                        .preservation_original(deleted.id)
                        .is_none()
                );
                checkpoint.journal.desire(deleted).unwrap();
                checkpoint.save_locked(&library, &key, &salt).unwrap();
                Ok(())
            })
            .unwrap();
        sender.send(()).unwrap();
    });
    until(
        "native pending raw-child preparation did not finish",
        || worker.is_finished(),
    );
    worker.join().unwrap();
    receiver.recv().unwrap();
}

fn child_credentials(
    window: &Rc<AccountWindow>,
    delete: bool,
) -> (adw::AlertDialog, gtk::PasswordEntry) {
    let dialog = review(window);
    assert_eq!(
        dialog.heading().as_deref(),
        Some("Review Secure Snippet Deletion")
    );
    assert!(
        dialog
            .body()
            .contains("A saved deletion is waiting to finish.")
    );
    assert!(
        dialog
            .body()
            .contains("Your choice applies only to this snippet.")
    );
    assert!(dialog.is_response_enabled("keep"));
    press(
        dialog.upcast_ref(),
        if delete {
            "Confirm Deletion"
        } else {
            "Restore Retained Version"
        },
    );
    until("native raw-child vault credentials did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    assert_eq!(dialog.close_response(), "cancel");
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}

fn decide_child(window: &Rc<AccountWindow>, delete: bool, password: &str) {
    let (dialog, entry) = child_credentials(window, delete);
    recovery_mode(&dialog).set_active(true);
    entry.set_text(password);
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
    assert!(no_worker());
    let root = isolated_root();
    let fixture = server::Fixture::new();
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    parent.set_title(Some("Public Native Unknown Raw Child Acceptance"));
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    assert!(!no_worker());
    connect_keys(&window, &fixture);
    let installed = slot(&root, Slot::LibraryKey).unwrap();
    let (key, salt) = wire_material(&root);
    let independent: serde_json::Value =
        serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
    let mut document =
        Document::decode(&serde_json::to_vec(&independent["document"]).unwrap()).unwrap();
    let source = document.records[0].metadata.id;
    let losing = projected(&document, source);
    let vault_key = RootKey::from_bytes(&[0x11; 32]).unwrap();
    edit(
        &mut document,
        source,
        b"Public raw-child parent winner",
        &vault_key,
    );
    let winner = projected(&document, source);
    let raw = crate::merge::merge(None, Some(&losing), Some(&winner))
        .unwrap()
        .survivor
        .unwrap();
    let child_id = crate::merge::secure_variants(&raw)
        .unwrap()
        .remove(0)
        .copy_id;
    document.records[0] = crate::projection::vault_record(&raw, None, &document.kid)
        .unwrap()
        .unwrap();
    let source_seal = document.records[0].sealed.clone();
    let unrelated = model::Snippet::new(
        "Public raw-child unrelated",
        "Public raw-child unrelated ordinary body",
    );
    model::Library::open(root.clone())
        .unwrap()
        .save(unrelated.clone(), None)
        .unwrap();
    fs::create_dir(root.join("Vault")).unwrap();
    fs::set_permissions(root.join("Vault"), fs::Permissions::from_mode(0o700)).unwrap();
    model::atomic_write(&root.join("Vault/vault.json"), &document.encode().unwrap()).unwrap();
    action(&window, "Receive Cloud Changes");
    action(&window, "Send Local Changes");
    assert_eq!(
        window.status.label(),
        "An encrypted conflict needs preservation before its source or later edits can be sent."
    );
    let captured = snapshot::checkpoint(&root);
    assert!(captured.journal.has_preservation_work());
    assert!(captured.journal.preservation_original(child_id).is_none());
    assert!(captured.journal.confirmed(child_id).is_none());
    assert!(uploaded_has(&fixture, &unrelated, &key, &salt));
    assert!(fixture.state.lock().unwrap().record(child_id).is_none());
    // Retained unreviewed intent carries routing identity only. It cannot borrow
    // the raw parent's userDeletion permission or delete an unresolved source.
    let deleted = Envelope {
        id: child_id,
        hlc: Hlc::foreign(0xffff_ff20_0000),
        origin: "22222222".into(),
        secure: true,
        deleted: true,
        fields: None,
        extensions: std::collections::BTreeMap::from([(
            "vaultKID".into(),
            crate::canonical::Value::text(document.kid.clone()),
        )]),
    };
    retain_pending(&root, &deleted);
    let pending = snapshot::checkpoint(&root);
    let entry = pending.journal.entry(child_id).unwrap();
    assert!(entry.desired == deleted && entry.offered.is_none());
    assert!(matches!(
        entry.review,
        crate::journal::ReviewAncestor::Unknown
    ));
    assert!(!pending.journal.deletion_approved(&deleted).unwrap());
    let parent_marker = winner
        .tombstone(Hlc::foreign(0xffff_ff80_0000), "22222222".into(), true)
        .unwrap();
    let parent_version = {
        let mut state = fixture.state.lock().unwrap();
        state.put(WireRecord::seal(&parent_marker, &key, &salt).unwrap());
        state.version(source).unwrap()
    };
    action(&window, "Receive Cloud Changes");
    assert_eq!(
        window.status.label(),
        "A cloud deletion needs review. The saved page is retained and your local snippet is preserved."
    );
    let before = primary(&root);
    let counts = data_counts(&fixture);
    let packets = fixture.state.lock().unwrap().submitted.clone();
    let held = snapshot::checkpoint(&root);
    choice(&window, "Cancel");
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (dialog, entry) = child_credentials(&window, delete);
    entry.set_text("Public cancelled raw-child credential");
    press(dialog.upcast_ref(), "Cancel");
    password_done(&window, &entry);
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    let (_dialog, entry) = child_credentials(&window, delete);
    entry.set_text("Public focus-revoked raw-child credential");
    parent.present();
    until("native raw-child focus cancellation did not finish", || {
        parent.is_active() && window.password_dialog.borrow().is_none() && !window.busy.get()
    });
    assert!(entry.text().is_empty());
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    window.window.present();
    until("native raw-child window did not regain focus", || {
        window.window.is_active()
    });
    decide_child(&window, delete, "Public incorrect raw-child recovery key");
    assert!(primary(&root) == before && data_counts(&fixture) == counts);
    assert!(fixture.state.lock().unwrap().submitted == packets);
    decide_child(&window, delete, &crypto::format_recovery(&[0x66; 16]));
    assert!(window.status.label().starts_with(if delete {
        "Deletion saved."
    } else {
        "Retained version restored."
    }));
    assert!(data_counts(&fixture) == counts);
    let decided = snapshot::checkpoint(&root);
    assert!(
        decided.journal.inbox == held.journal.inbox
            && decided.journal.outbound == held.journal.outbound
    );
    assert!(decided.journal.confirmed(child_id).is_none());
    assert!(decided.journal.deletion_approved(&deleted).unwrap() == delete);
    assert!(!decided.journal.deletion_approvals.contains_key(&source));
    let original = decided
        .journal
        .preservation_original(child_id)
        .unwrap()
        .clone();
    let saved = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(
        saved
            .records
            .iter()
            .find(|r| r.metadata.id == source)
            .unwrap()
            .sealed
            == source_seal
    );
    assert!(saved.records.iter().any(|r| r.metadata.id == child_id) != delete);
    if !delete {
        assert!(
            body(&saved, child_id, &vault_key).as_slice()
                == independent["plaintext"].as_str().unwrap().as_bytes()
        );
        assert!(
            saved
                .records
                .iter()
                .find(|r| r.metadata.id == child_id)
                .unwrap()
                .sealed
                .text()
                .as_bytes()
                == original.fields.as_ref().unwrap().content.as_slice()
        );
    }
    no_session_key(&root, child_id);
    let parent_dialog = review(&window);
    assert!(
        parent_dialog
            .body()
            .contains("The cloud deleted this snippet.")
    );
    assert!(
        !parent_dialog
            .body()
            .contains("Your choice applies only to this snippet.")
    );
    press(parent_dialog.upcast_ref(), "Cancel");
    wait_work(&window);
    let before_parent = primary(&root);
    verify(
        &window,
        false,
        "Public incorrect raw-parent credential",
        false,
        false,
    );
    assert!(primary(&root) == before_parent && data_counts(&fixture) == counts);
    verify(
        &window,
        false,
        &crypto::format_recovery(&[0x66; 16]),
        false,
        true,
    );
    assert!(window.status.label().starts_with("Local version kept."));
    assert!(data_counts(&fixture) == counts);
    assert!(
        snapshot::checkpoint(&root)
            .journal
            .preservation_original(child_id)
            == Some(&original)
    );
    action(&window, "Receive Cloud Changes");
    action(&window, "Send Local Changes");
    action(&window, "Sync Now");
    if window.status.label() == LOCKED {
        super::super::super::super::credential(
            &window,
            &crypto::format_recovery(&[0x66; 16]),
            true,
        );
    }
    assert_eq!(window.status.label(), CURRENT);
    assert!(slot(&root, Slot::LibraryKey).unwrap() == installed);
    assert!(local_has(&root, &unrelated));
    assert!(uploaded_has(&fixture, &unrelated, &key, &salt));
    assert!(!uploaded(&fixture, source, &key, &salt).deleted);
    assert!(uploaded(&fixture, child_id, &key, &salt).deleted == delete);
    let final_document = crate::vault::read_document(&root).unwrap().unwrap();
    assert!(
        body(&final_document, source, &vault_key).as_slice() == b"Public raw-child parent winner"
    );
    assert!(
        final_document
            .records
            .iter()
            .any(|r| r.metadata.id == child_id)
            != delete
    );
    if !delete {
        assert!(
            body(&final_document, child_id, &vault_key).as_slice()
                == independent["plaintext"].as_str().unwrap().as_bytes()
        );
    }
    {
        let state = fixture.state.lock().unwrap();
        let offers: Vec<_> = state.submitted.iter().flatten().collect();
        let copy_position = offers
            .iter()
            .position(|(wire, expected)| {
                wire.id == child_id
                    && expected.is_none()
                    && wire.open(&key, &salt).unwrap() == original
            })
            .unwrap();
        let parent_position = offers
            .iter()
            .position(|(wire, expected)| {
                wire.id == source && expected.as_deref() == Some(parent_version.as_str())
            })
            .unwrap();
        assert!(copy_position < parent_position);
        if delete {
            let deletion_position = offers
                .iter()
                .rposition(|(wire, expected)| {
                    wire.id == child_id
                        && expected.is_some()
                        && wire.open(&key, &salt).unwrap().deleted
                })
                .unwrap();
            assert!(copy_position < deletion_position);
        }
    }
    let final_checkpoint = snapshot::checkpoint(&root);
    assert!(!final_checkpoint.journal.has_preservation_work());
    assert!(final_checkpoint.journal.deletion_approvals.is_empty());
    assert!(!root.join("Sync/primary.pending").exists());
    assert!(slot(&root, Slot::AutomaticSync).is_none());
    pause_quit(&window);
    drop(stop);
    drop(window);
    parent.destroy();
    drop(parent);
    app.quit();
    drop(app);
    until("native raw-child worker did not terminate", no_worker);
    println!(
        "Native Unknown pending raw-child decision completed: separate child/parent credentials, exact immutable original, retained source receipt, copy-before-source CAS and no leftover intent; public fixtures only."
    );
}
