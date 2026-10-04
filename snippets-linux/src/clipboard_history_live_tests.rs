use super::*;
use std::{
    fs,
    io::Write,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Child, Command as Process, Stdio},
    thread,
    time::Instant,
};

struct Source(Child);
impl Drop for Source {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}
struct StopService(Rc<Service>);
impl Drop for StopService {
    fn drop(&mut self) {
        let started = Instant::now();
        while !self.0.prepare_quit() && started.elapsed() < Duration::from_secs(10) {
            pump();
        }
        if let Some(window) = self.0.window.borrow().as_ref() {
            window.window.set_visible(false);
        }
    }
}
// Restore only an admitted text selection, kept in memory. wl-copy takes over
// ownership before this short-lived GTK test/independent producer terminate.
struct RestoreClipboard(Option<Zeroizing<String>>);
impl Drop for RestoreClipboard {
    fn drop(&mut self) {
        let mut command = Process::new("wl-copy");
        command.stdout(Stdio::null()).stderr(Stdio::null());
        if self.0.is_none() {
            command.arg("--clear");
        }
        command.stdin(Stdio::piped());
        if let Ok(mut child) = command.spawn() {
            if let Some(mut input) = child.stdin.take()
                && let Some(text) = &self.0
            {
                let _ = input.write_all(text.as_bytes());
            }
            let started = Instant::now();
            while child.try_wait().ok().flatten().is_none()
                && started.elapsed() < Duration::from_secs(3)
            {
                thread::sleep(Duration::from_millis(10));
            }
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
    }
}
fn pump() {
    let context = glib::MainContext::default();
    while context.pending() {
        context.iteration(false);
    }
    thread::sleep(Duration::from_millis(10));
}
#[track_caller]
fn until(label: &str, finished: impl Fn() -> bool) {
    let started = Instant::now();
    while !finished() {
        assert!(started.elapsed() < Duration::from_secs(8), "{label}");
        pump();
    }
}
fn quiet() {
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(750) {
        pump();
    }
}
fn source_target(pid: u32) -> Option<PasteTarget> {
    let output = Process::new("hyprctl")
        .args(["-j", "clients"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let clients: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    clients
        .as_array()
        .unwrap()
        .iter()
        .find(|client| {
            client["title"].as_str() == Some("Snippets Public Clipboard Source")
                && client["pid"].as_u64() == Some(u64::from(pid))
        })
        .and_then(PasteTarget::from_window)
}
fn publish(control: &Path, ack: &Path, selected: u8) {
    fs::write(control, [b'0' + selected]).unwrap();
    until("independent clipboard owner did not acknowledge", || {
        fs::read(ack).is_ok_and(|value| value == [b'0' + selected])
    });
    quiet();
}
fn focus_history(service: &Rc<Service>) -> Rc<HistoryWindow> {
    let window = service.window.borrow().clone().unwrap();
    window.window.present();
    until("history window did not obtain unlocked focus", || {
        service.view_allowed()
    });
    window
}
fn answer(service: &Rc<Service>, response: &str) {
    until("confirmation did not map", || {
        service
            .dialog
            .borrow()
            .as_ref()
            .is_some_and(|dialog| dialog.is_mapped())
    });
    let dialog = service.dialog.borrow().clone().unwrap();
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    assert_eq!(dialog.close_response(), "cancel");
    let label = dialog.response_label(response);
    press(dialog.upcast_ref(), &label);
    until("confirmation did not finish", || {
        service.dialog.borrow().is_none()
    });
}
fn press(root: &gtk::Widget, label: &str) {
    let mut widgets = vec![root.clone()];
    while let Some(widget) = widgets.pop() {
        if let Some(button) = widget.downcast_ref::<gtk::Button>()
            && button.label().as_deref() == Some(label)
        {
            until("confirmation response was not ready", || {
                button.is_sensitive() && button.is_mapped()
            });
            button.emit_clicked();
            return;
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    panic!("native response button was missing");
}

#[test]
#[ignore = "explicit live clipboard acceptance; run only through clipboard-history-live.sh with a private bus/keyring/data root"]
fn live_clipboard_collection() {
    let bus = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap();
    assert_eq!(std::env::var("SNIPPETS_SECRET_TEST_BUS").unwrap(), bus);
    assert_ne!(std::env::var("SNIPPETS_SECRET_HOST_BUS").unwrap(), bus);
    assert!(std::env::var_os("SNIPPETS_SUPPORT_DIR").is_none());
    let root = model::default_root().unwrap();
    assert_eq!(
        root,
        Path::new(&std::env::var("SNIPPETS_SECRET_TEST_ROOT").unwrap())
    );
    assert_eq!(
        root,
        Path::new(&std::env::var("XDG_DATA_HOME").unwrap()).join("snippets")
    );
    assert!(root.parent().unwrap().starts_with("/tmp") && !root.exists());
    assert!(desktop::session_state() == SessionState::Unlocked);
    adw::init().expect("graphical display");
    let monitor = SessionMonitor::new().unwrap();
    until("unlocked session observation was unavailable", || {
        monitor.snapshot().0 == SessionState::Unlocked
    });
    let witness = monitor.witness();
    let admitted = witness.snapshot();
    let guard = || {
        if admitted.0 == SessionState::Unlocked && witness.snapshot() == admitted {
            Ok(())
        } else {
            Err(history::CANCELLED)
        }
    };
    let mut reader = history::wayland::Reader::open(&guard).unwrap();
    assert!(desktop::wayland_peer_matches(reader.peer_process()));
    let formats = reader.formats().unwrap();
    assert!(
        formats.iter().all(|mime| {
            mime.starts_with("text/plain")
                || matches!(mime.as_str(), "UTF8_STRING" | "TEXT" | "STRING")
        }),
        "Only an ordinary text selection may be replaced by this live fixture."
    );
    let previous = if formats.is_empty() {
        None
    } else {
        let mime = formats
            .iter()
            .find(|mime| mime.eq_ignore_ascii_case("text/plain;charset=utf-8"))
            .or_else(|| {
                formats
                    .iter()
                    .find(|mime| mime.eq_ignore_ascii_case("text/plain"))
            })
            .expect("An ordinary UTF-8 text selection is required.");
        Some(reader.receive(reader.generation(), mime, &guard).unwrap())
    };
    drop(reader);
    let restore = RestoreClipboard(previous);
    let directory = tempfile::tempdir().unwrap();
    let binary = directory.path().join("clipboard-source");
    let control = directory.path().join("command");
    let ack = directory.path().join("ack");
    let flags = Process::new("pkg-config")
        .args(["--cflags", "--libs", "gtk4"])
        .output()
        .unwrap();
    assert!(flags.status.success());
    assert!(
        Process::new("cc")
            .args(["-Wall", "-Wextra", "-Werror"])
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/clipboard-source.c"))
            .args(String::from_utf8(flags.stdout).unwrap().split_whitespace())
            .arg("-o")
            .arg(&binary)
            .status()
            .unwrap()
            .success()
    );
    let source = Source(
        Process::new(binary)
            .env("SNIPPETS_TEST_CLIPBOARD_COMMAND", &control)
            .env("SNIPPETS_TEST_CLIPBOARD_ACK", &ack)
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    until("independent GTK source did not map", || {
        source_target(source.0.id()).is_some()
    });
    let target = source_target(source.0.id()).unwrap();
    assert!(target.focus());
    publish(&control, &ack, 1);
    let service = Service::new(root.clone(), |_| panic!("unexpected snippet creation")).unwrap();
    let stop = StopService(service.clone());
    let app = adw::Application::builder()
        .application_id(desktop::APP_ID)
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.register(None::<&gio::Cancellable>).unwrap();
    service.present(&app);
    let window = focus_history(&service);
    window.enable.emit_clicked();
    answer(&service, "cancel");
    assert!(!service.preference.borrow().enabled && service.collectors.borrow().is_empty());
    assert!(!root.join("secret-owner.bin").exists() && !root.join("ClipboardHistory").exists());
    window.enable.emit_clicked();
    answer(&service, "confirm");
    until("native clipboard collection did not become ready", || {
        service.preference.borrow().enabled
            && service.monitor_ready.get()
            && !service.settings_busy.get()
    });
    quiet();
    let image = root.join("ClipboardHistory/history.bin");
    assert!(
        !image.exists() && !root.join("secret-owner.bin").exists(),
        "Pre-existing selection was collected."
    );
    // Closing the history window scrubs plaintext; opted-in collection continues.
    window.window.close();
    until("history window did not hide", || {
        !window.window.is_visible()
    });
    assert!(target.focus());
    until("independent source did not gain focus", || {
        target.is_active_unlocked()
    });
    publish(&control, &ack, 2);
    until("background copy was not retained", || image.exists());
    assert!(window.entries.borrow().is_empty() && !service.worker.control.has_view());
    let encrypted = fs::read(&image).unwrap();
    assert!(
        !encrypted
            .windows(b"Public background clipboard fixture".len())
            .any(|bytes| bytes == b"Public background clipboard fixture")
    );
    assert_eq!(
        fs::metadata(&image).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(image.parent().unwrap())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    publish(&control, &ack, 3);
    assert!(
        fs::read(&image).unwrap() == encrypted,
        "Sensitivity hint was ignored."
    );
    publish(&control, &ack, 4);
    assert!(
        fs::read(&image).unwrap() == encrypted,
        "Internal copy marker was ignored."
    );
    focus_history(&service);
    until(
        "real keyring-backed view did not decrypt the background copy",
        || {
            let entries = window.entries.borrow();
            entries.len() == 1 && entries[0].text() == "Public background clipboard fixture"
        },
    );
    window.query.set_text("absent public fixture");
    until("history search did not filter the rows", || {
        window.visible.borrow().is_empty()
    });
    window.query.set_text("background fixture");
    until("history search did not restore its matching row", || {
        window.visible.borrow().len() == 1
    });
    window.rows.select_row(window.rows.row_at_index(0).as_ref());
    assert!(window.copy.is_sensitive());
    window.copy.emit_clicked();
    quiet();
    assert!(
        fs::read(&image).unwrap() == encrypted,
        "History copied itself."
    );
    window.enable.emit_clicked();
    until("disabled collector did not drain", || {
        !service.preference.borrow().enabled
            && !service.settings_busy.get()
            && service.collectors.borrow().is_empty()
    });
    assert!(target.focus());
    until("independent source did not regain focus", || {
        target.is_active_unlocked()
    });
    publish(&control, &ack, 5);
    assert!(
        fs::read(&image).unwrap() == encrypted,
        "Collection continued after opt-out."
    );
    assert!(!Preference::read(&root).unwrap().enabled);
    focus_history(&service);
    until("disabled history did not retain its view", || {
        window.entries.borrow().len() == 1
    });
    window.rows.select_row(window.rows.row_at_index(0).as_ref());
    window.delete.emit_clicked();
    answer(&service, "cancel");
    assert!(window.entries.borrow().len() == 1 && fs::read(&image).unwrap() == encrypted);
    window.delete.emit_clicked();
    answer(&service, "confirm");
    until("confirmed history deletion did not complete", || {
        window.entries.borrow().is_empty()
    });
    assert!(image.exists() && fs::read(&image).unwrap() != encrypted);
    press(window.window.upcast_ref(), "Clear History…");
    answer(&service, "cancel");
    assert!(image.exists());
    press(window.window.upcast_ref(), "Clear History…");
    answer(&service, "confirm");
    until("confirmed history clear did not complete", || {
        !image.exists() && !service.settings_busy.get()
    });
    let mut reader = history::wayland::Reader::open(&guard).unwrap();
    let current = reader
        .receive(reader.generation(), "text/plain;charset=utf-8", &guard)
        .unwrap();
    assert!(
        current.as_str() == "Public collection-disabled clipboard fixture",
        "Deleting retained history changed the current clipboard."
    );
    drop(reader);
    assert!(!root.join("Vault").exists() && !root.join("Sync").exists());
    until("history workers did not stop", || service.prepare_quit());
    drop(stop);
    drop(source);
    drop(restore);
    app.quit();
}
