use super::*;
use crate::{
    cloud::CloudClient,
    model,
    secret_store::{Native, Slot, Store},
};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command as Process,
    thread,
    time::Instant,
};

#[path = "account_live_server.rs"]
mod server;

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
        assert!(started.elapsed() < Duration::from_secs(15), "{label}");
        pump();
    }
}
fn button(root: &gtk::Widget, label: &str) -> gtk::Button {
    let mut widgets = vec![root.clone()];
    while let Some(widget) = widgets.pop() {
        if let Some(button) = widget.downcast_ref::<gtk::Button>()
            && button.label().as_deref() == Some(label)
        {
            return button.clone();
        }
        let mut child = widget.first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            widgets.push(widget);
        }
    }
    panic!("native account response missing");
}
fn press(root: &gtk::Widget, label: &str) {
    let button = button(root, label);
    until("native account button was not ready", || {
        button.is_mapped() && button.is_sensitive()
    });
    button.emit_clicked();
}
struct Pam {
    directory: tempfile::TempDir,
    helper: PathBuf,
}
impl Pam {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
        let module = directory.path().join("pam-fixture.so");
        let helper = directory.path().join("owner-fixture");
        assert!(
            Process::new("cc")
                .args(["-shared", "-fPIC", "-Wall", "-Wextra", "-Werror"])
                .arg(manifest.join("tests/fixtures/pam-module.c"))
                .arg("-o")
                .arg(&module)
                .arg("-lpam")
                .status()
                .unwrap()
                .success()
        );
        assert!(
            Process::new("cc")
                .args(["-Wall", "-Wextra", "-Werror"])
                .arg(format!(
                    "-DSNIP_OWNER_FIXTURE_MAIN=\"{}\"",
                    directory.path().display()
                ))
                .arg(manifest.join("src/owner_auth.c"))
                .arg("-o")
                .arg(&helper)
                .arg("-lpam")
                .status()
                .unwrap()
                .success()
        );
        fs::write(
            directory.path().join("system-auth"),
            format!(
                "auth required {} password\naccount required {} valid\n",
                module.display(),
                module.display()
            ),
        )
        .unwrap();
        Self { directory, helper }
    }
}
struct Stop(Rc<AccountWindow>);
impl Drop for Stop {
    fn drop(&mut self) {
        let started = Instant::now();
        while !self.0.prepare_quit() && started.elapsed() < Duration::from_secs(10) {
            pump();
        }
        self.0.window.destroy();
    }
}
fn slot(root: &Path, slot: Slot) -> Option<Zeroizing<Vec<u8>>> {
    let root = root.to_owned();
    let (sender, receiver) = mpsc::channel();
    let worker = thread::spawn(move || {
        let mut store = Store::load(&root, Native::new().unwrap()).unwrap();
        let result = store
            .transaction_with::<_, crate::secret_store::Failure>(|owner| owner.read(slot))
            .unwrap();
        sender.send(result).unwrap();
    });
    until("native keyring read did not finish", || {
        worker.is_finished()
    });
    worker.join().unwrap();
    receiver.recv().unwrap()
}
fn wait_work(window: &AccountWindow) {
    until("native account operation did not finish", || {
        !window.busy.get()
    });
}
fn authorize(window: &Rc<AccountWindow>, password: &str, response: &str) {
    press(window.window.upcast_ref(), "Show Pending Recovery Code…");
    until("native password dialog did not map", || {
        window
            .password_dialog
            .borrow()
            .as_ref()
            .is_some_and(|(dialog, entry)| dialog.is_mapped() && entry.is_mapped())
    });
    let (dialog, entry) = window.password_dialog.borrow().clone().unwrap();
    assert!(
        dialog.default_response().as_deref() == Some("cancel")
            && dialog.close_response() == "cancel"
    );
    entry.set_text(password);
    press(dialog.upcast_ref(), response);
    wait_work(window);
    assert!(entry.text().is_empty() && window.password_dialog.borrow().is_none());
}
fn make_window(
    app: &adw::Application,
    parent: &adw::ApplicationWindow,
    root: &Path,
    fixture: &server::Fixture,
    pam: &Pam,
) -> Rc<AccountWindow> {
    let worker = Rc::new(
        Handle::live_fixture(
            root.into(),
            fixture.server.clone(),
            fixture.agent(),
            pam.helper.clone(),
        )
        .unwrap(),
    );
    let window = AccountWindow::new(app, parent, worker).unwrap();
    window.present();
    until("native account window did not acquire focus", || {
        window.window.is_active()
    });
    until("native account session observation was unavailable", || {
        window
            .desktop
            .as_ref()
            .is_some_and(|monitor| monitor.snapshot().0 == SessionState::Unlocked)
    });
    wait_work(&window);
    window
}

#[test]
#[ignore = "explicit native GTK/HTTPS/Secret Service/PAM acceptance; invoke only via tests/account-live.sh"]
fn live_account_onboarding_and_recovery() {
    let bus = std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap();
    assert!(
        std::env::var("SNIPPETS_SECRET_TEST_BUS").unwrap() == bus
            && std::env::var("SNIPPETS_SECRET_HOST_BUS").unwrap() != bus
    );
    assert!(std::env::var_os("SNIPPETS_SUPPORT_DIR").is_none());
    let root = model::default_root().unwrap();
    assert!(root == Path::new(&std::env::var("SNIPPETS_SECRET_TEST_ROOT").unwrap()));
    assert!(
        root == Path::new(&std::env::var("XDG_DATA_HOME").unwrap()).join("snippets")
            && root.starts_with("/tmp")
            && !root.exists()
    );
    assert!(crate::desktop::session_state() == SessionState::Unlocked);
    let fixture = server::Fixture::new();
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network)
    );
    assert!(fixture.state.lock().unwrap().requests == 0 && !root.exists());
    let pam = Pam::new();
    assert!(pam.directory.path().join("system-auth").exists());
    adw::init().expect("graphical display");
    let app = adw::Application::builder()
        .application_id("com.khm.snippets.linux.NativeAccountAcceptance")
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.register(None::<&gtk::gio::Cancellable>).unwrap();
    let parent = adw::ApplicationWindow::builder()
        .application(&app)
        .title("Public Native Account Acceptance")
        .build();
    parent.present();
    until("native account parent did not acquire focus", || {
        parent.is_active()
    });
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    assert!(
        window.pages.visible_child_name().as_deref() == Some("login")
            && !window.sync.is_sensitive()
            && !root.join("secret-owner.bin").exists()
            && !root.join("Vault").exists()
            && !root.join("Sync").exists()
    );
    window.server.set_text(fixture.server.for_secure_storage());
    window.email.set_text("fixture@example.invalid");
    press(window.window.upcast_ref(), "Send Sign-in Code");
    wait_work(&window);
    assert!(window.pages.visible_child_name().as_deref() == Some("code"));
    window.code.set_text("000000");
    press(window.window.upcast_ref(), "Sign In");
    wait_work(&window);
    assert!(window.code.text().is_empty() && fixture.state.lock().unwrap().grants == 0);
    window.code.set_text("123456");
    press(window.window.upcast_ref(), "Sign In");
    wait_work(&window);
    assert!(
        window.code.text().is_empty()
            && window.pages.visible_child_name().as_deref() == Some("libraries")
    );
    assert!(slot(&root, Slot::LibraryKey).is_none() && slot(&root, Slot::Bootstrap).is_none());
    assert!(window.libraries.selected() == 0 && !window.library_panel.is_sensitive());
    window.libraries.set_selected(1);
    wait_work(&window);
    assert!(
        window.library_panel.is_sensitive() && !window.sync.is_sensitive(),
        "Native selection outcome: {}",
        window.status.label()
    );
    assert!(slot(&root, Slot::LibraryKey).is_none());
    press(window.window.upcast_ref(), "Set Up / Resume Library Keys");
    wait_work(&window);
    assert!(window.sync.is_sensitive() && fixture.state.lock().unwrap().bootstrap_posts == 1);
    let key = slot(&root, Slot::LibraryKey).unwrap();
    authorize(&window, "Public fictional password", "Cancel");
    assert!(window.view.value.borrow().is_none());
    authorize(&window, "Public incorrect password", "Authorize");
    assert!(window.view.value.borrow().is_none());
    authorize(&window, "Public fictional password", "Authorize");
    until("authorized recovery visual did not map", || {
        window.view.area.is_mapped()
            && window.recovery_panel.is_visible()
            && window.view.value.borrow().is_some()
    });
    // Hold the real lease only to prove that actual focus loss revokes it.
    let held = window.view.value.borrow_mut().take().unwrap();
    parent.present();
    until("account did not lose focus", || !window.window.is_active());
    until("recovery lease survived focus loss", || {
        held.disclosure.long_code().is_err()
    });
    drop(held);
    assert!(window.view.value.borrow().is_none() && window.suffix.text().is_empty());
    window.window.present();
    until("account did not regain focus", || window.window.is_active());
    authorize(&window, "Public fictional password", "Authorize");
    let suffix = {
        let view = window.view.value.borrow();
        let code = view.as_ref().unwrap().disclosure.long_code().unwrap();
        let filtered = zeroize::Zeroizing::new(
            code.chars()
                .filter(|c| c.is_alphanumeric())
                .collect::<String>(),
        );
        let mut suffix = Zeroizing::new(filtered.chars().rev().take(8).collect::<Vec<_>>());
        suffix.reverse();
        Zeroizing::new(suffix.iter().collect::<String>())
    };
    window.suffix.set_text(&suffix);
    window.recorded.set_active(true);
    window.confirm.emit_clicked();
    wait_work(&window);
    assert!(window.view.value.borrow().is_none() && window.suffix.text().is_empty());
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|value| value.as_slice() == key.as_slice()));
    window.libraries.set_selected(0);
    assert!(
        !window.library_panel.is_sensitive()
            && !window.sync.is_sensitive()
            && !window.send.is_sensitive()
            && !window.receive.is_sensitive()
            && !window.pairing_poll.get()
            && !window.candidate_poll.get()
    );
    window.libraries.set_selected(1);
    wait_work(&window);
    assert!(window.sync.is_sensitive() && fixture.state.lock().unwrap().bootstrap_posts == 1);
    assert!(
        !root.join("automatic-sync.json").exists()
            && !root.join("Vault").exists()
            && !root.join("Sync").exists()
    );
    until("first native account worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    drop(window);
    // A fresh worker must load the actual private keyring and reconnect with
    // fresh discovery/rotation, retaining the same library key and saved kit.
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    assert!(window.reconnect.is_visible() && !window.sync.is_sensitive());
    window.reconnect.emit_clicked();
    wait_work(&window);
    assert!(window.pages.visible_child_name().as_deref() == Some("libraries"));
    assert!(window.libraries.selected() == 0 && !window.library_panel.is_sensitive());
    window.libraries.set_selected(1);
    wait_work(&window);
    assert!(
        window.sync.is_sensitive()
            && window.status.label()
                == "Library key ready. Recovery code already confirmed; keep your offline copy."
    );
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|value| value.as_slice() == key.as_slice()));
    window.sign_out.emit_clicked();
    wait_work(&window);
    assert!(
        window.pages.visible_child_name().as_deref() == Some("login")
            && !window.reconnect.is_visible()
            && !window.sync.is_sensitive()
    );
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|value| value.as_slice() == key.as_slice()));
    {
        let state = fixture.state.lock().unwrap();
        assert!(state.grants == 2 && state.bootstrap_posts == 1 && state.revokes >= 2);
    }
    assert!(
        CloudClient::discover(fixture.server.clone()).err() == Some(crate::cloud::Failure::Network),
        "Fixture TLS trust escaped its account worker thread."
    );
    until("second native account worker did not drain", || {
        window.prepare_quit()
    });
    drop(stop);
    parent.destroy();
    app.quit();
}
