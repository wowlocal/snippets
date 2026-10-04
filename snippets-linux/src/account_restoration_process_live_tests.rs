//! Owned SIGSTOP/SIGKILL boundary and fresh native offline continuation.
use super::*;
use gtk::gio;

pub(crate) fn stop_at_ordinary_write(root: &Path) {
    let Some(control) = std::env::var_os("SNIPPETS_RESTORATION_KILL_CONTROL") else {
        return;
    };
    assert_eq!(
        std::env::var("SNIPPETS_RESTORATION_PROCESS_STAGE").as_deref(),
        Ok("start")
    );
    assert_eq!(
        root,
        Path::new(&std::env::var_os("SNIPPETS_SECRET_TEST_ROOT").unwrap())
    );
    assert_ne!(
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
        std::env::var_os("SNIPPETS_SECRET_HOST_BUS")
    );
    let control = PathBuf::from(control);
    assert!(
        control.starts_with(Path::new(&std::env::var_os("XDG_DATA_HOME").unwrap()))
            && control.is_dir()
    );
    assert!(root.join("Sync/primary.pending").is_file());
    model::atomic_write(
        &control.join("ready"),
        b"ordinary-written-before-vault-or-unwind\n",
    )
    .unwrap();
    // Stop all threads before returning the injected I/O failure. The exclusive
    // parent observes this stopped child, sends SIGKILL and reaps it before resume.
    assert_eq!(unsafe { libc::raise(libc::SIGSTOP) }, 0);
    panic!("The stopped restoration child must be killed, never continued.");
}

fn dialog(
    window: &Rc<AccountWindow>,
    restoration: bool,
) -> (adw::AlertDialog, Vec<gtk::PasswordEntry>) {
    until(
        "native process restoration credential dialog did not map",
        || {
            if restoration {
                window
                    .restoration_dialog
                    .borrow()
                    .as_ref()
                    .is_some_and(|(d, e)| d.is_mapped() && e[0].is_mapped())
            } else {
                window
                    .password_dialog
                    .borrow()
                    .as_ref()
                    .is_some_and(|(d, e)| d.is_mapped() && e.is_mapped())
            }
        },
    );
    if restoration {
        window.restoration_dialog.borrow().clone().unwrap()
    } else {
        let (d, e) = window.password_dialog.borrow().clone().unwrap();
        (d, vec![e])
    }
}
fn review(window: &Rc<AccountWindow>, heading: &str) -> adw::AlertDialog {
    until_for(
        "native process restoration review did not map",
        Duration::from_secs(45),
        || {
            window
                .snapshot_dialog
                .borrow()
                .as_ref()
                .is_some_and(|d| d.is_mapped())
        },
    );
    let dialog = window.snapshot_dialog.borrow().clone().unwrap();
    assert_eq!(dialog.heading().as_deref(), Some(heading));
    assert_eq!(dialog.default_response().as_deref(), Some("back"));
    assert_eq!(dialog.close_response(), "back");
    dialog
}
fn pending_row(history: &adw::Dialog) -> Option<adw::ActionRow> {
    let mut widgets = vec![history.clone().upcast::<gtk::Widget>()];
    let mut found = None;
    while let Some(widget) = widgets.pop() {
        if let Some(row) = widget.downcast_ref::<adw::ActionRow>()
            && row.title() == "Complete Saved Restoration"
        {
            assert!(found.is_none());
            found = Some(row.clone());
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    found
}
pub(crate) fn child(root: &Path, stage: &str) {
    assert!(matches!(stage, "start" | "resume" | "inspect"));
    assert!(crate::desktop::session_state() == SessionState::Unlocked);
    let fixture = server::Fixture::new();
    fixture.state.lock().unwrap().offline = true;
    let pam = Pam::new();
    adw::init().unwrap();
    let app = adw::Application::builder()
        .application_id("com.khm.snippets.linux.ProcessRestoration")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.register(None::<&gio::Cancellable>).unwrap();
    let parent = adw::ApplicationWindow::builder()
        .application(&app)
        .title("Public Restoration Process Fixture")
        .build();
    parent.present();
    until("process restoration parent did not focus", || {
        parent.is_active()
    });
    let window = make_window_with_interruption(
        &app,
        &parent,
        root,
        &fixture,
        &pam,
        (stage == "start").then_some(crate::account_worker::RestorationInterruption::Ordinary),
    );
    let stop = Stop(window.clone());
    press(window.window.upcast_ref(), "Library Recovery History…");
    until("process restoration history did not map", || {
        window
            .history_dialog
            .borrow()
            .as_ref()
            .is_some_and(|d| d.is_mapped())
    });
    let history = window.history_dialog.borrow().clone().unwrap();
    if stage == "inspect" {
        assert!(pending_row(&history).is_none());
        history.close();
        until("completed process history did not close", || {
            window.history_dialog.borrow().is_none()
        });
        assert!(crate::primary::require_ready(root).is_ok());
    } else {
        if stage == "start" {
            assert!(pending_row(&history).is_none());
            press(history.upcast_ref(), "Review…");
            let (credentials, entries) = dialog(&window, true);
            assert_eq!(
                credentials.heading().as_deref(),
                Some("Unlock the Vaults for Restoration")
            );
            assert_eq!(credentials.default_response().as_deref(), Some("back"));
            assert!(!entries.iter().any(|entry| entry.shows_peek_icon()));
            entries[0].set_text("Public current vault passphrase");
            let modes = secure_restoration_live::toggles(&credentials, "Use recovery key");
            assert_eq!(modes.len(), 2);
            modes[1].set_active(true);
            entries[1].set_text(&crate::crypto::format_recovery(&[0x66; 16]));
            press(credentials.upcast_ref(), "Verify Saved Changes");
            let review = review(&window, "Restore the Saved Changes?");
            assert!(entries.iter().all(|entry| entry.text().is_empty()));
            assert!(
                review
                    .body()
                    .contains("Saved secure changes will use the current vault's encryption.")
            );
            press(review.upcast_ref(), "Restore Changes");
        } else {
            press(pending_row(&history).unwrap().upcast_ref(), "Finish…");
            let review = review(&window, "Finish the Saved Restoration?");
            assert!(window.restoration_dialog.borrow().is_none());
            press(review.upcast_ref(), "Restore Changes");
        }
        let (authorize, entries) = dialog(&window, false);
        assert_eq!(authorize.default_response().as_deref(), Some("cancel"));
        assert_eq!(authorize.close_response(), "cancel");
        assert_eq!(
            authorize.heading().as_deref(),
            Some(if stage == "start" {
                "Authorize Saved Changes Restoration"
            } else {
                "Authorize Restoration Completion"
            })
        );
        assert!(!entries[0].shows_peek_icon());
        entries[0].set_text("Public fictional password");
        press(authorize.upcast_ref(), "Authorize");
        if stage == "start" {
            until_for(
                "the ordinary write boundary never stopped its owned child",
                Duration::from_secs(60),
                || {
                    assert!(
                        window.busy.get(),
                        "Restoration returned before the held ordinary write."
                    );
                    false
                },
            );
            unreachable!();
        }
        wait_work(&window);
        assert!(entries[0].text().is_empty() && window.password_dialog.borrow().is_none());
        assert!(
            window.restoration_dialog.borrow().is_none()
                && window.snapshot_dialog.borrow().is_none()
        );
        assert!(crate::primary::require_ready(root).is_ok());
        assert_eq!(
            window.status.label(),
            "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing."
        );
    }
    assert_eq!(fixture.state.lock().unwrap().requests, 0);
    assert!(
        !window.sync.is_sensitive()
            && !window.receive.is_sensitive()
            && !window.send.is_sensitive()
    );
    until("native process worker did not finish", || {
        window.prepare_quit()
    });
    drop(stop);
    parent.destroy();
    println!(
        "Fresh native offline restoration process completed its bounded public stage; no HTTP request or borrowed vault session."
    );
}
