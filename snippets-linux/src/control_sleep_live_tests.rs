//! Actual installed Release app, real authenticated D-Bus transport and GTK.
//! Only the sleep-notification service is fictional; the host is never suspended.
use super::*;
const LOGIN: &str = "org.freedesktop.login1";
const MANAGER: &str = "org.freedesktop.login1.Manager";
const PATH: &str = "/org/freedesktop/login1";

struct SleepPeer {
    connection: gio::DBusConnection,
    stranger: gio::DBusConnection,
    registration: Option<gio::RegistrationId>,
    preparing: Rc<Cell<bool>>,
    reads: Rc<Cell<usize>>,
}
impl SleepPeer {
    fn new() -> Self {
        let address = std::env::var("DBUS_SYSTEM_BUS_ADDRESS").unwrap();
        assert!(Some(&address) != std::env::var("DBUS_SESSION_BUS_ADDRESS").ok().as_ref());
        let connect = || {
            let connection = gio::DBusConnection::for_address_sync(
                &address,
                gio::DBusConnectionFlags::AUTHENTICATION_CLIENT
                    | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
                None,
                None::<&gio::Cancellable>,
            )
            .unwrap();
            connection.set_exit_on_close(false);
            connection
        };
        let connection = connect();
        let stranger = connect();
        let reply = connection
            .call_sync(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "RequestName",
                Some(&(LOGIN, 4u32).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                2000,
                None::<&gio::Cancellable>,
            )
            .unwrap();
        assert!(reply.get::<(u32,)>() == Some((1,)));
        let preparing = Rc::new(Cell::new(false));
        let reads = Rc::new(Cell::new(0));
        let current = preparing.clone();
        let observed = reads.clone();
        let info = gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.login1.Manager'><property name='PreparingForSleep' type='b' access='read'/><signal name='PrepareForSleep'><arg type='b'/></signal></interface></node>").unwrap();
        let registration = connection
            .register_object(PATH, &info.lookup_interface(MANAGER).unwrap())
            .property(move |_, _, _, _, property| {
                assert!(property == "PreparingForSleep");
                observed.set(observed.get() + 1);
                current.get().to_variant()
            })
            .build()
            .unwrap();
        Self {
            connection,
            stranger,
            registration: Some(registration),
            preparing,
            reads,
        }
    }
    fn emit(&self, preparing: bool) {
        self.preparing.set(preparing);
        self.connection
            .emit_signal(
                None,
                PATH,
                MANAGER,
                "PrepareForSleep",
                Some(&(preparing,).to_variant()),
            )
            .unwrap();
        self.connection
            .flush_sync(None::<&gio::Cancellable>)
            .unwrap();
    }
    fn cycle(&self) {
        assert!(desktop::session_state() == SessionState::Unlocked);
        self.emit(true);
        self.emit(false);
    }
}
impl Drop for SleepPeer {
    fn drop(&mut self) {
        if let Some(registration) = self.registration.take() {
            self.connection.unregister_object(registration).unwrap();
        }
        let _ = self.stranger.close_sync(None::<&gio::Cancellable>);
        let _ = self.connection.close_sync(None::<&gio::Cancellable>);
    }
}

#[test]
#[ignore = "unlocked Omarchy; real installed Release sleep-notification GTK/CLI workflow on two private buses; never suspends host"]
fn live_installed_sleep_events_revoke_secure_work() {
    assert!(
        std::env::var_os("SNIPPETS_CONTROL_LIVE").as_deref()
            == Some(std::ffi::OsStr::new("public-private-roots"))
    );
    assert!(
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS")
            != std::env::var_os("SNIPPETS_CONTROL_HOST_BUS")
    );
    assert!(desktop::session_state() == SessionState::Unlocked);
    adw::init().unwrap();
    let mut peer = SleepPeer::new();
    let fixture = Fixture::new();
    let mut app = fixture.start(1);
    fixture.unlock_editor(&app, 1);
    let original = fixture.images();
    peer.stranger
        .emit_signal(
            None,
            PATH,
            MANAGER,
            "PrepareForSleep",
            Some(&(true,).to_variant()),
        )
        .unwrap();
    peer.stranger.flush_sync(None::<&gio::Cancellable>).unwrap();
    settle(Duration::from_millis(800));
    fixture.status_state(1, true);
    assert!(active_window(app.id(), "Secure Snippets"));
    peer.cycle();
    until(
        "actual sleep/resume notifications must lock the vault without a focus lapse",
        4,
        || !fixture.state(1),
    );
    assert!(active_window(app.id(), "Secure Snippets"));
    settle(Duration::from_secs(2));
    fixture.status(1);
    assert!(fixture.images() == original);
    assert!(
        peer.reads.get() > 0,
        "The actual application must inspect initial logind sleep state."
    );
    let action = |mode, value: Option<&str>| {
        assert!(
            fixture.action_in(&app, "Secure Snippets", mode, value) == 0,
            "Native sleep revocation action {mode} must succeed."
        );
    };
    let completed_locked = || {
        until("sleep-revoked native worker completed", 30, || {
            fixture.action_in(&app, "Secure Snippets", "editor-idle", None) == 0
        });
        settle(Duration::from_secs(2));
        fixture.status(1);
        assert!(fixture.images() == original);
        assert!(active_window(app.id(), "Secure Snippets"));
    };
    action("editor-unlock", None);
    action("input-empty", None);
    action("input", Some(&fixture.password));
    peer.cycle();
    settle(Duration::from_secs(2));
    action("editor-authenticate", None);
    completed_locked();
    action("editor-unlock", None);
    action("input-empty", None);
    action("input", Some(&fixture.password));
    action("editor-authenticate-start", None);
    action("auth-busy", None);
    peer.cycle();
    completed_locked();
    fixture.unlock_editor(&app, 1);
    // A malformed notification from the authenticated owner fails closed.
    peer.connection
        .emit_signal(
            None,
            PATH,
            MANAGER,
            "PrepareForSleep",
            Some(&("public malformed sleep boolean",).to_variant()),
        )
        .unwrap();
    peer.connection
        .flush_sync(None::<&gio::Cancellable>)
        .unwrap();
    completed_locked();
    fixture.unlock_editor(&app, 1);
    drop(peer);
    completed_locked();
    // Rebind to a genuinely different unique owner. No keys return merely
    // because the service reappears with PreparingForSleep=false.
    peer = SleepPeer::new();
    until("new logind owner initial property inspected", 5, || {
        peer.reads.get() > 0
    });
    completed_locked();
    fixture.unlock_editor(&app, 1);
    let mut cli = fixture.reveal(&fixture.keyword);
    until("real sleep-bound CLI review appeared", 5, || {
        prompt(app.id())
    });
    assert!(fixture.action(&app, "approve", None) == 0);
    assert!(fixture.action(&app, "input-empty", None) == 0);
    assert!(fixture.action(&app, "input", Some(&fixture.password)) == 0);
    assert!(active(app.id()));
    peer.cycle();
    fixture.finish(&app, &mut cli, Status::Denied.exit_code().into(), None);
    completed_locked();
    fixture.unlock_editor(&app, 1);
    assert!(fixture.images() == original);
    let document = Document::decode(original.1.as_ref().unwrap()).unwrap();
    fixture.assert_diagnostics(document.records[0].metadata.id);
    assert!(!fixture.root.join("Sync").exists());
    fixture.stop(&mut app);
    let empty = Fixture::empty();
    let mut app = empty.start(0);
    empty.open_editor(&app);
    let unpublished = empty.images();
    for (mode, value) in [
        ("setup-open", None),
        ("setup-passphrase", Some(empty.password.as_str())),
        ("setup-confirm", Some(empty.password.as_str())),
        ("setup-submit-start", None),
        ("auth-busy", None),
    ] {
        assert!(empty.action_in(&app, "Secure Snippets", mode, value) == 0);
    }
    peer.cycle();
    until(
        "sleep-revoked setup completed without publication",
        30,
        || empty.action_in(&app, "Secure Snippets", "setup-idle", None) == 0,
    );
    settle(Duration::from_secs(2));
    empty.status(0);
    assert!(empty.images() == unpublished);
    empty.assert_diagnostics(uuid::Uuid::nil());
    assert!(!empty.root.join("Sync").exists());
    empty.stop(&mut app);
    let disconnected = Fixture::new();
    let mut app = disconnected.start(1);
    disconnected.unlock_editor(&app, 1);
    let original = disconnected.images();
    // Kill only the wrapper's dedicated fictional system bus, after the bus
    // itself confirms that exact daemon PID and UID. The real system/session
    // buses are not addressed by this operation.
    let daemon: u32 = std::env::var("SNIPPETS_CONTROL_SYSTEM_BUS_PID")
        .unwrap()
        .parse()
        .unwrap();
    let checked = |method| {
        peer.connection
            .call_sync(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                method,
                Some(&("org.freedesktop.DBus",).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                500,
                None::<&gio::Cancellable>,
            )
            .unwrap()
            .get::<(u32,)>()
            .unwrap()
            .0
    };
    assert!(checked("GetConnectionUnixProcessID") == daemon);
    assert!(checked("GetConnectionUnixUser") == unsafe { libc::geteuid() });
    assert!(
        ProcessCommand::new("kill")
            .args(["-TERM", "--", &daemon.to_string()])
            .status()
            .unwrap()
            .success()
    );
    until("dedicated fictional system bus disconnected", 5, || {
        peer.connection.is_closed()
    });
    until("system-bus disconnection revoked live vault", 5, || {
        !disconnected.state(1)
    });
    settle(Duration::from_secs(2));
    disconnected.status(1);
    assert!(active_window(app.id(), "Secure Snippets"));
    assert!(disconnected.images() == original);
    disconnected.assert_diagnostics(
        Document::decode(original.1.as_ref().unwrap())
            .unwrap()
            .records[0]
            .metadata
            .id,
    );
    disconnected.stop(&mut app);
    println!(
        "Actual installed Release ignored a foreign sleep sender, inspected/rebound logind properties, revoked an unlocked key and pending/observed credential/setup workers and CLI disclosure after authenticated sleep/resume without primary writes; fresh credentials remained required. Host was never suspended."
    );
}
