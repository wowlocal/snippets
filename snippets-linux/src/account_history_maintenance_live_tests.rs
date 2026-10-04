//! Existing history-panel gate, completed through the actual owning UI/worker.
use super::*;
use std::collections::BTreeMap;

const NAME: &str = "account_ui::history_view::tests::native_history_cleanup_controls_respect_saved_consent_and_empty_key_state";
const SEED: &str = "key_store::handover::tests::restoration::foreign::desktop_workflow::prepare_installed_chooser_cancel_fixture";
const PROTECTED: [Slot; 12] = [
    Slot::Credentials,
    Slot::LibraryKey,
    Slot::CheckpointKey,
    Slot::Bootstrap,
    Slot::PairingRecipient,
    Slot::SpaceCreation,
    Slot::KeyMutation,
    Slot::PairingCandidate,
    Slot::BootstrapCandidate,
    Slot::HistoryRestore,
    Slot::AutomaticSync,
    Slot::ClipboardHistory,
];

fn protected(root: &Path) -> Vec<Option<Zeroizing<Vec<u8>>>> {
    PROTECTED.into_iter().map(|s| slot(root, s)).collect()
}
fn primary(root: &Path) -> Vec<Vec<u8>> {
    ["snippets.json", "Vault/vault.json", "Sync/journal.bin"]
        .into_iter()
        .map(|p| fs::read(root.join(p)).unwrap())
        .collect()
}
fn images(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    fs::read_dir(root.join("Sync/Reviews"))
        .unwrap()
        .map(|item| {
            let item = item.unwrap();
            assert!(item.file_type().unwrap().is_file());
            (
                PathBuf::from(item.file_name()),
                fs::read(item.path()).unwrap(),
            )
        })
        .collect()
}
fn orphan(root: &Path, nonce: [u8; 16]) -> BTreeMap<PathBuf, Vec<u8>> {
    let library = model::Library::prepare(root.into()).unwrap();
    let bytes = fs::read(root.join("Sync/journal.bin")).unwrap();
    let before = images(root);
    let _guard = library.lock().unwrap();
    crate::account_review::retain_pair_locked(&library, &nonce, &bytes, &bytes, None).unwrap();
    images(root)
        .into_iter()
        .filter(|(p, _)| !before.contains_key(p))
        .collect()
}
fn catalogue(root: &Path) -> crate::key_store::history::Catalog {
    switching::checkpoint_and_history(root).1
}
fn history(window: &Rc<AccountWindow>) -> adw::Dialog {
    press(window.window.upcast_ref(), "Library Recovery History…");
    until("native maintenance history did not map", || {
        window
            .history_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    window.history_dialog.borrow().clone().unwrap()
}
fn review(window: &Rc<AccountWindow>, removal: bool) -> adw::AlertDialog {
    let panel = history(window);
    press(
        panel.upcast_ref(),
        if removal {
            "Review Removal…"
        } else {
            "Review Cleanup…"
        },
    );
    until("native maintenance destructive review did not map", || {
        window
            .restoration_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_empty())
    });
    let (dialog, entries) = window.restoration_dialog.borrow().clone().unwrap();
    assert!(entries.is_empty() && window.history_dialog.borrow().is_none());
    assert_eq!(
        dialog.heading().as_deref(),
        Some(if removal {
            "Remove This Saved Copy?"
        } else {
            "Discard Unused Recovery Files?"
        })
    );
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    assert_eq!(dialog.close_response(), "cancel");
    assert_eq!(
        dialog.response_appearance("remove"),
        adw::ResponseAppearance::Destructive
    );
    assert!(!dialog.is_body_use_markup());
    if removal {
        assert!(dialog.body().contains("This removes one history entry, its saved keys and recovery capabilities, and 2 encrypted recovery files"));
        assert!(
            dialog
                .body()
                .contains("Historical changes and keys in this entry may have no other copy.")
        );
    } else {
        assert!(dialog.body().contains("Discard 2 encrypted recovery files"));
        assert!(
            dialog
                .body()
                .contains("Their previous changes may have no other copy")
        );
        assert!(
            dialog
                .body()
                .contains("Newly created files are not part of this review.")
        );
    }
    dialog
}
fn password(window: &Rc<AccountWindow>, removal: bool) -> (adw::AlertDialog, gtk::PasswordEntry) {
    until("native maintenance PAM prompt did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert_eq!(
        dialog.heading().as_deref(),
        Some(if removal {
            "Authorize History Removal"
        } else {
            "Authorize Recovery File Cleanup"
        })
    );
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    assert_eq!(dialog.close_response(), "cancel");
    assert!(!entry.shows_peek_icon());
    (dialog, entry)
}
fn finished(window: &Rc<AccountWindow>, entry: Option<&gtk::PasswordEntry>) {
    wait_work(window);
    assert!(
        window.restoration_dialog.borrow().is_none() && window.password_dialog.borrow().is_none()
    );
    if let Some(entry) = entry {
        assert!(entry.text().is_empty());
    }
    until("native maintenance focus did not return", || {
        window.window.is_active()
    });
}
fn preserved(root: &Path, ordinary: &[Vec<u8>], keys: &[Option<Zeroizing<Vec<u8>>>]) {
    assert!(primary(root) == ordinary && protected(root) == keys);
    assert!(slot(root, Slot::HistoryMaintenance).is_none());
    assert!(crate::primary::require_ready(root).is_ok());
}
fn no_worker() -> bool {
    !fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|item| item.ok())
        .any(|item| {
            fs::read_to_string(item.path().join("comm"))
                // Linux task comm stores at most 15 bytes of the Rust name.
                .is_ok_and(|name| name.trim() == "snippets-accoun")
        })
}

pub(crate) fn run() {
    let root = PathBuf::from(std::env::var_os("SNIPPETS_SECRET_TEST_ROOT").unwrap());
    assert_eq!(root, model::default_root().unwrap());
    assert!(root.starts_with(Path::new(&std::env::var_os("XDG_DATA_HOME").unwrap())));
    assert!(std::env::var_os("SNIPPETS_SUPPORT_DIR").is_none());
    assert_ne!(
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
        std::env::var_os("SNIPPETS_SECRET_HOST_BUS")
    );
    assert!(crate::desktop::session_state() == SessionState::Unlocked && no_worker());
    let inspect = std::env::var_os("SNIPPETS_HISTORY_INSPECT_ONLY").is_some();
    if !inspect {
        assert!(!root.exists());
        assert!(
            Process::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    SEED,
                    "--ignored",
                    "--test-threads=1",
                    "--nocapture"
                ])
                .env("SNIPPETS_HISTORY_MAINTENANCE_SEED", "terminal")
                .status()
                .unwrap()
                .success()
        );
    }
    let before = primary(&root);
    let keys = protected(&root);
    let archived = slot(&root, Slot::AccountReview).unwrap();
    let referenced = images(&root);
    let initial = catalogue(&root);
    assert_eq!(initial.switches.len(), usize::from(!inspect));
    assert!(initial.maintenance.is_none() && !initial.creations_unavailable);
    if !inspect {
        assert!(initial.switches[0].removal.is_some());
    }
    let old_orphan = if inspect {
        BTreeMap::new()
    } else {
        orphan(&root, [0x77; 16])
    };
    if !inspect {
        assert_eq!(referenced.len(), 2);
        assert_eq!(old_orphan.len(), 2);
    }
    let fixture = server::Fixture::new();
    fixture.state.lock().unwrap().offline = true;
    let pam = Pam::new();
    glib::set_prgname(Some("snippets-public-history-maintenance"));
    glib::set_application_name("Snippets Public History Maintenance");
    let (app, parent) = automatic_parent();
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    assert!(
        !no_worker(),
        "The owned account worker must be observed live before terminal verification."
    );
    if inspect {
        let panel = history(&window);
        assert!(catalogue(&root).switches.is_empty());
        assert!(images(&root) == referenced && referenced.len() == 2);
        panel.close();
        until("native maintenance history did not close", || {
            window.history_dialog.borrow().is_none()
        });
    } else {
        let all = images(&root);
        let dialog = review(&window, false);
        press(dialog.upcast_ref(), "Cancel");
        finished(&window, None);
        preserved(&root, &before, &keys);
        assert!(images(&root) == all && slot(&root, Slot::AccountReview).unwrap() == archived);
        let dialog = review(&window, false);
        press(dialog.upcast_ref(), "Authorize Removal…");
        let (dialog, entry) = password(&window, false);
        entry.set_text("Public fictional password");
        press(dialog.upcast_ref(), "Cancel");
        finished(&window, Some(&entry));
        preserved(&root, &before, &keys);
        assert!(images(&root) == all && slot(&root, Slot::AccountReview).unwrap() == archived);

        let dialog = review(&window, false);
        let late = orphan(&root, [0x88; 16]);
        assert_eq!(late.len(), 2);
        press(dialog.upcast_ref(), "Authorize Removal…");
        let (dialog, entry) = password(&window, false);
        entry.set_text("Public fictional password");
        press(dialog.upcast_ref(), "Authorize");
        finished(&window, Some(&entry));
        assert_eq!(
            window.status.label(),
            "The reviewed unused recovery files were removed. Saved history, current records and keys were kept."
        );
        let expected: BTreeMap<_, _> = referenced.clone().into_iter().chain(late.clone()).collect();
        preserved(&root, &before, &keys);
        assert!(images(&root) == expected && slot(&root, Slot::AccountReview).unwrap() == archived);
        assert_eq!(catalogue(&root).switches.len(), 1);

        let dialog = review(&window, true);
        press(dialog.upcast_ref(), "Cancel");
        finished(&window, None);
        preserved(&root, &before, &keys);
        assert!(images(&root) == expected && slot(&root, Slot::AccountReview).unwrap() == archived);
        let dialog = review(&window, true);
        press(dialog.upcast_ref(), "Authorize Removal…");
        let (dialog, entry) = password(&window, true);
        entry.set_text("Public fictional password");
        press(dialog.upcast_ref(), "Authorize");
        finished(&window, Some(&entry));
        assert_eq!(
            window.status.label(),
            "The selected history entry and its encrypted recovery files were removed."
        );
        preserved(&root, &before, &keys);
        assert!(images(&root) == late && catalogue(&root).switches.is_empty());
        assert!(slot(&root, Slot::AccountReview).unwrap() != archived);
    }
    assert_eq!(fixture.state.lock().unwrap().requests, 0);
    preserved(&root, &before, &keys);
    let final_images = images(&root);
    let terminal = slot(&root, Slot::AccountReview);
    until("native maintenance worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    drop(window);
    parent.destroy();
    drop(parent);
    app.quit();
    drop(app);
    until("native maintenance worker did not terminate", no_worker);
    if !inspect {
        assert!(
            Process::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    NAME,
                    "--ignored",
                    "--test-threads=1",
                    "--nocapture"
                ])
                .env("SNIPPETS_HISTORY_INSPECT_ONLY", "1")
                .status()
                .unwrap()
                .success()
        );
        preserved(&root, &before, &keys);
        assert!(images(&root) == final_images && slot(&root, Slot::AccountReview) == terminal);
    }
    println!(
        "Mapped native history maintenance completed: exact scoped removals, default Cancel, separate private PAM, late-file retention, protected current state, fresh process and zero HTTP; public fixtures only."
    );
}
