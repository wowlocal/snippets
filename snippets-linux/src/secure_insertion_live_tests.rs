use super::*;
use std::{
    fs,
    path::Path,
    process::{Child, Command, Stdio},
    time::Instant,
};

struct Receiver(Child);
impl Drop for Receiver {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}
#[track_caller]
fn settle_until(finished: impl Fn() -> bool) {
    let started = Instant::now();
    let context = glib::MainContext::default();
    while !finished() {
        assert!(
            started.elapsed() < Duration::from_secs(30),
            "native secure paste timed out"
        );
        while context.pending() {
            context.iteration(false);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}
fn receiving_window(pid: u32) -> Option<desktop::PasteTarget> {
    let output = Command::new("hyprctl")
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
            client["title"].as_str() == Some("Snippets Smoke Paste Target")
                && client["pid"].as_u64() == Some(u64::from(pid))
        })
        .and_then(desktop::PasteTarget::from_window)
}
fn press_response(dialog: &adw::AlertDialog, label: &str) {
    let mut widgets = vec![dialog.clone().upcast::<gtk::Widget>()];
    while let Some(widget) = widgets.pop() {
        if let Some(button) = widget.downcast_ref::<gtk::Button>()
            && button.label().as_deref() == Some(label)
        {
            assert!(button.is_sensitive() && button.is_mapped());
            button.emit_clicked();
            return;
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    panic!("secure insertion response missing");
}

#[test]
#[ignore = "live Hyprland secure receiving-field test; fresh temporary vault authentication and a separate owned GTK target"]
fn live_secure_paste() {
    assert!(
        desktop::session_state() == SessionState::Unlocked,
        "An unlocked session is required before any input is attempted."
    );
    adw::init().expect("graphical display");
    let directory = tempfile::tempdir().unwrap();
    let library = Library::open(directory.path().join("library")).unwrap();
    let mut vault = Vault::open(&library).unwrap();
    let prepared = glib::MainContext::default()
        .block_on(worker(|| {
            Vault::prepare_create("Public secure paste passphrase")
        }))
        .unwrap();
    let generation = vault.generation();
    drop(vault.finish_create(&library, prepared, generation).unwrap());
    let mut metadata = Metadata::new();
    metadata.name = "Public secure insertion fixture".into();
    metadata.keyword = "publicsecurepaste".into();
    let id = metadata.id;
    vault
        .save(
            &library,
            metadata,
            b"fictional snippet fictional clipboard fixture",
            None,
        )
        .unwrap();
    vault.lock();
    drop(vault);
    let before = fs::read(library.root.join("Vault/vault.json")).unwrap();
    let receiver_binary = directory.path().join("paste-receiver");
    let receiver_result = directory.path().join("paste-result");
    let flags = Command::new("pkg-config")
        .args(["--cflags", "--libs", "gtk4"])
        .output()
        .unwrap();
    assert!(flags.status.success());
    assert!(
        Command::new("cc")
            .args(["-Wall", "-Wextra", "-Werror"])
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/paste-receiver.c"))
            .args(String::from_utf8(flags.stdout).unwrap().split_whitespace())
            .arg("-o")
            .arg(&receiver_binary)
            .status()
            .unwrap()
            .success()
    );
    let receiver = Receiver(
        Command::new(receiver_binary)
            .env("SNIPPETS_TEST_PASTE_RESULT", &receiver_result)
            .env("G_DEBUG", "fatal-warnings")
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    settle_until(|| receiving_window(receiver.0.id()).is_some());
    let target = receiving_window(receiver.0.id()).unwrap();
    assert!(
        target.focus(),
        "Owned target did not receive focus; no keys sent."
    );
    let application = adw::Application::builder()
        .application_id("com.khm.snippets.linux.SecurePasteSmoke")
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    application
        .register(None::<&gtk::gio::Cancellable>)
        .unwrap();
    let workspace = Workspace::new(&application, &library).unwrap();
    workspace.present_for_insertion(id, target);
    settle_until(|| workspace.window.is_active() && workspace.desktop_allowed());
    workspace.update();
    assert!(!workspace.vault.borrow_mut().is_unlocked() && workspace.insert.is_sensitive());
    // Use the native button and fresh-password dialog. No synthetic authorization
    // or preinstalled decrypted editor state participates in delivery.
    for (password, response) in [
        ("Public cancelled passphrase", "Cancel"),
        ("Public incorrect passphrase", "Authenticate and Insert"),
    ] {
        workspace.insert.emit_clicked();
        settle_until(|| {
            workspace
                .insertion_dialog
                .borrow()
                .as_ref()
                .is_some_and(|(dialog, entry)| dialog.is_mapped() && entry.is_mapped())
        });
        let (dialog, entry) = workspace
            .insertion_dialog
            .borrow()
            .as_ref()
            .unwrap()
            .clone();
        entry.set_text(password);
        press_response(&dialog, response);
        settle_until(|| !workspace.insertion_worker.get());
        assert!(entry.text().is_empty() && workspace.insertion_dialog.borrow().is_none());
        assert!(
            !receiver_result.exists(),
            "Refused insertion reached the receiving field."
        );
        let target = receiving_window(receiver.0.id()).unwrap();
        workspace.present_for_insertion(id, target);
        settle_until(|| workspace.window.is_active() && workspace.desktop_allowed());
        workspace.update();
        assert!(workspace.insert.is_sensitive());
    }
    workspace.insert.emit_clicked();
    settle_until(|| {
        workspace
            .insertion_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(dialog, entry)| dialog.is_mapped() && entry.is_mapped())
    });
    let (dialog, entry) = workspace
        .insertion_dialog
        .borrow()
        .as_ref()
        .unwrap()
        .clone();
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    entry.set_text("Public secure paste passphrase");
    press_response(&dialog, "Authenticate and Insert");
    settle_until(|| !workspace.insertion_worker.get());
    assert!(entry.text().is_empty() && workspace.insertion_dialog.borrow().is_none());
    let delivered = fs::read(receiver_result).ok().as_deref() == Some(b"matched\n");
    let unchanged = fs::read(library.root.join("Vault/vault.json")).unwrap() == before;
    let reported = workspace.status.label()
        == "Secure input sent to the original window; check the destination.";
    workspace.lock();
    workspace.window.destroy();
    drop(receiver);
    assert!(
        delivered && reported && unchanged,
        "Secure insertion did not reach the owned receiving field without changing its vault."
    );
}
