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

#[path = "account_creation_live_tests.rs"]
mod creation;
#[path = "account_live_server.rs"]
mod server;
#[path = "account_switch_live_tests.rs"]
mod switching;
#[path = "account_vault_sync_live_tests.rs"]
mod vault;

fn pump() {
    let context = glib::MainContext::default();
    while context.pending() {
        context.iteration(false);
    }
    thread::sleep(Duration::from_millis(10));
}
#[track_caller]
fn until(label: &str, finished: impl Fn() -> bool) {
    until_for(label, Duration::from_secs(15), finished);
}
#[track_caller]
fn until_for(label: &str, limit: Duration, finished: impl Fn() -> bool) {
    let started = Instant::now();
    while !finished() {
        assert!(started.elapsed() < limit, "{label}");
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
#[track_caller]
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

fn isolated_root() -> PathBuf {
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
    root
}

#[test]
#[ignore = "explicit native GTK/HTTPS/Secret Service/PAM acceptance; invoke only via tests/account-live.sh"]
fn live_account_onboarding_and_recovery() {
    let root = isolated_root();
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

fn automatic_parent() -> (adw::Application, adw::ApplicationWindow) {
    adw::init().expect("graphical display");
    let app = adw::Application::builder()
        .application_id("com.khm.snippets.linux.NativeAutomaticAcceptance")
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.register(None::<&gtk::gio::Cancellable>).unwrap();
    let parent = adw::ApplicationWindow::builder()
        .application(&app)
        .title("Public Native Automatic Acceptance")
        .build();
    parent.present();
    until("native automatic parent did not acquire focus", || {
        parent.is_active()
    });
    (app, parent)
}
fn connect_keys(window: &Rc<AccountWindow>, fixture: &server::Fixture) {
    window.server.set_text(fixture.server.for_secure_storage());
    window.email.set_text("fixture@example.invalid");
    assert!(window.email.grab_focus());
    until("native email delegate did not acquire focus", || {
        gtk::prelude::GtkWindowExt::focus(&window.window)
            .is_some_and(|focus| focus.is_ancestor(&window.email))
    });
    press(window.window.upcast_ref(), "Send Sign-in Code");
    assert!(window.busy.get() && gtk::prelude::GtkWindowExt::focus(&window.window).is_none());
    wait_work(window);
    window.code.set_text("123456");
    assert!(window.code.grab_focus());
    until("native sign-in code delegate did not acquire focus", || {
        gtk::prelude::GtkWindowExt::focus(&window.window)
            .is_some_and(|focus| focus.is_ancestor(&window.code))
    });
    press(window.window.upcast_ref(), "Sign In");
    assert!(window.busy.get() && gtk::prelude::GtkWindowExt::focus(&window.window).is_none());
    wait_work(window);
    assert!(window.libraries.selected() == 0 && !window.library_panel.is_sensitive());
    window.libraries.set_selected(1);
    wait_work(window);
    press(window.window.upcast_ref(), "Set Up / Resume Library Keys");
    wait_work(window);
    assert!(window.sync.is_sensitive() && fixture.state.lock().unwrap().bootstrap_posts == 1);
}
fn wire_material(root: &Path) -> (crate::crypto::RootKey, Zeroizing<[u8; 32]>) {
    let installed = slot(root, Slot::LibraryKey).unwrap();
    let value = crate::canonical::parse(&installed).unwrap();
    let bundle =
        crate::bootstrap::Bundle::decode(&value.as_object().unwrap()["bundle"].encode().unwrap())
            .unwrap();
    let material = bundle.for_secure_storage();
    (
        crate::crypto::RootKey::from_bytes(&material[..32]).unwrap(),
        Zeroizing::new(material[32..].try_into().unwrap()),
    )
}
fn remote_record(
    snippet: &model::Snippet,
    counter: u16,
    key: &crate::crypto::RootKey,
    salt: &[u8; 32],
) -> crate::wire::WireRecord {
    let envelope = crate::wire::Envelope {
        id: snippet.id,
        hlc: crate::clock::Hlc::parse(&format!("000000000001-{counter:04x}-12345678")).unwrap(),
        origin: "12345678".into(),
        secure: false,
        deleted: false,
        fields: Some(crate::wire::Fields::from_snippet(snippet)),
        extensions: Default::default(),
    };
    crate::wire::WireRecord::seal(&envelope, key, salt).unwrap()
}
fn local_has(root: &Path, snippet: &model::Snippet) -> bool {
    model::Library::open(root.into()).is_ok_and(|library| {
        library.snippets.iter().any(|record| {
            record.id == snippet.id
                && record.content == snippet.content
                && record.tags == snippet.tags
        })
    })
}
fn uploaded_has(
    fixture: &server::Fixture,
    snippet: &model::Snippet,
    key: &crate::crypto::RootKey,
    salt: &[u8; 32],
) -> bool {
    fixture
        .state
        .lock()
        .unwrap()
        .record(snippet.id)
        .is_some_and(|wire| {
            assert!(
                !wire
                    .blob
                    .windows(snippet.content.len())
                    .any(|v| v == snippet.content.as_bytes())
            );
            let envelope = wire.open(key, salt).unwrap();
            envelope.fields.is_some_and(|fields| {
                fields.content.as_slice() == snippet.content.as_bytes()
                    && fields.tags == snippet.tags
            })
        })
}
fn toggle(window: &Rc<AccountWindow>, enabled: bool) {
    press(
        window.window.upcast_ref(),
        if enabled {
            "Enable Automatic Sync for This Library"
        } else {
            "Turn Off Automatic Sync"
        },
    );
    until("native automatic preference did not finish", || {
        !window.automatic_pending.get()
    });
    assert!(window.worker.automatic().enabled == enabled);
}
fn pause_quit(window: &Rc<AccountWindow>) {
    until("native automatic worker did not drain", || {
        window.prepare_quit()
    });
}
#[track_caller]
fn until_automatic(
    window: &AccountWindow,
    fixture: &server::Fixture,
    label: &str,
    limit: Duration,
    finished: impl Fn() -> bool,
) {
    let started = Instant::now();
    while !finished() {
        if started.elapsed() >= limit {
            let automatic = window.worker.automatic();
            let state = fixture.state.lock().unwrap();
            panic!(
                "{label}; status={:?}; failure={:?}; reason={}; fetches={}; batches={}; accepted={}",
                automatic.status,
                automatic.failure,
                automatic.failure.map_or("none", Failure::message),
                state.fetches,
                state.batches,
                state.accepted,
            );
        }
        pump();
    }
}

#[test]
#[ignore = "explicit native automatic GTK/HTTPS/keyring acceptance; invoke tests/account-live.sh with --automatic-sync"]
fn live_automatic_sync() {
    use crate::{account_worker::AutomaticStatus, auto_sync::Preference};
    use std::os::unix::fs::PermissionsExt;
    let root = isolated_root();
    let fixture = server::Fixture::new();
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    assert!(!Preference::read(&root).unwrap().enabled() && !root.join("Sync").exists());
    connect_keys(&window, &fixture);
    let installed = slot(&root, Slot::LibraryKey).unwrap();
    let (key, salt) = wire_material(&root);
    let mut local = model::Snippet::new("Public automatic local", "Public automatic local body");
    let mut remote = model::Snippet::new("Public automatic remote", "Public automatic remote body");
    model::Library::open(root.clone())
        .unwrap()
        .save(local.clone(), None)
        .unwrap();
    let before_fetches = {
        let mut state = fixture.state.lock().unwrap();
        state.put(remote_record(&remote, 1, &key, &salt));
        state.defer_fetch = true;
        state.fetches
    };
    toggle(&window, true);
    until(
        "native automatic HTTP refusal did not enter backoff",
        || window.worker.automatic().status == AutomaticStatus::Retry,
    );
    assert_eq!(
        fixture.state.lock().unwrap().fetches,
        before_fetches + 1,
        "First native refusal: {:?}",
        window.worker.automatic()
    );
    assert!(
        window.worker.automatic().failure
            == Some(Failure::Cloud(crate::cloud::Failure::Server {
                code: crate::cloud::ErrorCode::DependencyUnavailable,
                retry_after: Some(1),
            }))
    );
    assert!(Preference::read(&root).unwrap().enabled());
    until_automatic(
        &window,
        &fixture,
        "native automatic retry did not complete real exchange",
        Duration::from_secs(15),
        || {
            window.worker.automatic().status == AutomaticStatus::Current
                && window.worker.can_quit()
                && local_has(&root, &remote)
                && uploaded_has(&fixture, &local, &key, &salt)
        },
    );
    let preference_path = root.join("automatic-sync.json");
    assert!(fs::metadata(&preference_path).unwrap().permissions().mode() & 0o777 == 0o600);
    let preference = fs::read(&preference_path).unwrap();
    let public: serde_json::Value = serde_json::from_slice(&preference).unwrap();
    assert!(public.as_object().unwrap().len() == 3 && public["automatic"] == true);
    assert!(
        !preference
            .windows("fixture@example.invalid".len())
            .any(|v| v == b"fixture@example.invalid")
    );
    assert!(slot(&root, Slot::AutomaticSync).is_some());
    assert!(root.join("Sync").exists() && !root.join("Vault").exists());
    // No wake/tick injection: the real thirty-second scheduler exchanges edits
    // in both directions while the account window is hidden.
    window.window.close();
    assert!(!window.window.is_visible());
    remote.content = "Public automatic remote background body".into();
    remote.tags.push("public-remote-background".into());
    fixture
        .state
        .lock()
        .unwrap()
        .put(remote_record(&remote, 2, &key, &salt));
    let mut library = model::Library::open(root.clone()).unwrap();
    let previous = library
        .snippets
        .iter()
        .find(|s| s.id == local.id)
        .unwrap()
        .clone();
    local.content = "Public automatic local background body".into();
    local.tags.push("public-local-background".into());
    library.save(local.clone(), Some(&previous)).unwrap();
    until_automatic(
        &window,
        &fixture,
        "hidden native automatic scheduler did not exchange edits",
        Duration::from_secs(45),
        || {
            window.worker.automatic().status == AutomaticStatus::Current
                && window.worker.can_quit()
                && local_has(&root, &remote)
                && uploaded_has(&fixture, &local, &key, &salt)
        },
    );
    assert!(fs::read(&preference_path).unwrap() == preference);
    pause_quit(&window);
    drop(stop);
    drop(window);
    remote.content = "Public automatic remote after restart".into();
    fixture
        .state
        .lock()
        .unwrap()
        .put(remote_record(&remote, 3, &key, &salt));
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    // The new owner must reconnect solely from the protected consent target;
    // no Reconnect, library-selection or Enable button is activated here.
    until_automatic(
        &window,
        &fixture,
        "native saved automatic startup did not reconnect",
        Duration::from_secs(15),
        || {
            window.worker.automatic().status == AutomaticStatus::Current
                && window.worker.can_quit()
                && local_has(&root, &remote)
        },
    );
    assert!(fixture.state.lock().unwrap().grants == 2);
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v.as_slice() == installed.as_slice()));
    let before = fs::read(root.join("snippets.json")).unwrap();
    let checkpoint = fs::read(root.join("Sync/journal.bin")).unwrap();
    remote.content = "Public automatic remote cancelled response".into();
    fixture
        .state
        .lock()
        .unwrap()
        .put(remote_record(&remote, 4, &key, &salt));
    let hold = fixture.hold_next_changes();
    window.worker.wake(crate::auto_sync::Wake::Foreground);
    until(
        "native automatic request did not reach independent HTTP hold",
        || hold.entered(),
    );
    assert!(!window.worker.can_quit());
    // Disable is a real mapped GTK action while the serial owner is blocked on
    // HTTP. Its request immediately revokes the ticket, then waits to save off.
    press(window.window.upcast_ref(), "Turn Off Automatic Sync");
    assert!(window.automatic_pending.get());
    hold.release();
    until("native in-flight automatic disable did not finish", || {
        !window.automatic_pending.get()
    });
    assert!(!window.worker.automatic().enabled && !Preference::read(&root).unwrap().enabled());
    assert!(fs::read(root.join("snippets.json")).unwrap() == before);
    assert!(fs::read(root.join("Sync/journal.bin")).unwrap() == checkpoint);
    let requests = fixture.state.lock().unwrap().requests;
    window.worker.wake(crate::auto_sync::Wake::Foreground);
    window.worker.wake(crate::auto_sync::Wake::LocalEdit);
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(750) {
        pump();
    }
    assert!(fixture.state.lock().unwrap().requests == requests);
    pause_quit(&window);
    drop(stop);
    drop(window);
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(750) {
        pump();
    }
    assert!(
        !window.worker.automatic().enabled && fixture.state.lock().unwrap().requests == requests
    );
    assert!(slot(&root, Slot::LibraryKey).is_some_and(|v| v.as_slice() == installed.as_slice()));
    assert!(fs::read(root.join("snippets.json")).unwrap() == before);
    pause_quit(&window);
    drop(stop);
    parent.destroy();
    app.quit();
}

#[test]
#[ignore = "explicit native read-only automatic GTK/HTTPS/keyring acceptance; invoke tests/account-live.sh with --automatic-reader"]
fn live_automatic_reader() {
    use crate::{account_worker::AutomaticStatus, auto_sync::Preference};
    let root = isolated_root();
    let fixture = server::Fixture::new();
    let pam = Pam::new();
    let (app, parent) = automatic_parent();
    let window = make_window(&app, &parent, &root, &fixture, &pam);
    let stop = Stop(window.clone());
    connect_keys(&window, &fixture);
    let (key, salt) = wire_material(&root);
    let local = model::Snippet::new("Public reader local", "Public reader local body");
    let remote = model::Snippet::new("Public reader remote", "Public reader remote body");
    model::Library::open(root.clone())
        .unwrap()
        .save(local.clone(), None)
        .unwrap();
    {
        let mut state = fixture.state.lock().unwrap();
        state.reader = true;
        state.put(remote_record(&remote, 1, &key, &salt));
    }
    window.libraries.set_selected(0);
    window.libraries.set_selected(1);
    wait_work(&window);
    assert!(window.selected_role.get() == Some(Role::Reader) && window.sync.is_sensitive());
    toggle(&window, true);
    until_automatic(
        &window,
        &fixture,
        "native automatic reader did not receive",
        Duration::from_secs(15),
        || {
            window.worker.automatic().status == AutomaticStatus::ReceivedCurrent
                && window.worker.can_quit()
                && local_has(&root, &remote)
        },
    );
    assert!(local_has(&root, &local));
    assert!(fixture.state.lock().unwrap().batches == 0);
    let before = fs::read(root.join("snippets.json")).unwrap();
    let requests = fixture.state.lock().unwrap().requests;
    fixture.state.lock().unwrap().changed_scope = true;
    window.window.close();
    until_automatic(
        &window,
        &fixture,
        "native automatic reader did not halt on changed membership",
        Duration::from_secs(45),
        || {
            window.worker.automatic().status == AutomaticStatus::Attention
                && window.worker.can_quit()
        },
    );
    assert!(fs::read(root.join("snippets.json")).unwrap() == before);
    let state = fixture.state.lock().unwrap();
    assert!(state.requests > requests && state.batches == 0);
    let requests = state.requests;
    drop(state);
    window.worker.wake(crate::auto_sync::Wake::Foreground);
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(750) {
        pump();
    }
    assert!(fixture.state.lock().unwrap().requests == requests);
    window.window.present();
    until("native reader window did not return to focus", || {
        window.window.is_active()
    });
    toggle(&window, false);
    assert!(!Preference::read(&root).unwrap().enabled());
    pause_quit(&window);
    drop(stop);
    parent.destroy();
    app.quit();
}
