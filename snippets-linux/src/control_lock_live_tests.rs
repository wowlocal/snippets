//! Actual temporary compositor locks; all app data is isolated public fiction.
use super::*;

#[test]
#[ignore = "unlocked Omarchy; actual temporary Wayland session locks with independently verified graceful owner/deadman"]
fn live_installed_compositor_lock_revokes_secure_work() {
    assert_eq!(
        std::env::var_os("SNIPPETS_CONTROL_LIVE").as_deref(),
        Some(std::ffi::OsStr::new("public-private-roots"))
    );
    assert_ne!(
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
        std::env::var_os("SNIPPETS_CONTROL_HOST_BUS")
    );
    assert!(desktop::session_state() == SessionState::Unlocked);
    let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap();
    let instances = query("instances");
    let selected: Vec<_> = instances
        .as_array()
        .unwrap()
        .iter()
        .filter(|value| value["instance"].as_str() == Some(&signature))
        .collect();
    assert_eq!(selected.len(), 1);
    let compositor = selected[0]["pid"].as_u64().unwrap();
    assert!(desktop::wayland_peer_matches(compositor));
    let directory = tempfile::tempdir().unwrap();
    let (binary, _) = lock_fixture::compile(directory.path());
    let fixture = Fixture::new();
    let mut app = fixture.start(1);
    fixture.unlock_editor(&app, 1);
    let original = fixture.images();
    let prepare = || {
        assert!(desktop::session_state() == SessionState::Unlocked);
        let mut owner = lock_fixture::Locker::live(&binary, compositor);
        owner.arm();
        owner
    };
    let cycle = |mut owner: lock_fixture::Locker| {
        owner.lock();
        until("actual compositor locked state", 3, || {
            desktop::session_state() == SessionState::Locked
        });
        until("actual compositor lock revoked the vault", 3, || {
            !fixture.state(1)
        });
        owner.release();
        until(
            "actual compositor unlocked after acknowledged release",
            5,
            || desktop::session_state() == SessionState::Unlocked,
        );
    };
    let completed_locked = || {
        fixture.open_editor(&app);
        until("compositor-revoked native work completed", 30, || {
            fixture.action_in(&app, "Secure Snippets", "editor-idle", None) == 0
        });
        settle(Duration::from_secs(2));
        fixture.status(1);
        assert!(fixture.images() == original);
    };
    let action = |mode, value: Option<&str>| {
        assert!(fixture.action_in(&app, "Secure Snippets", mode, value) == 0);
    };
    assert!(active_window(app.id(), "Secure Snippets"));
    cycle(prepare());
    completed_locked();
    let owner = prepare();
    action("editor-unlock", None);
    action("input-empty", None);
    action("input", Some(&fixture.password));
    cycle(owner);
    fixture.open_editor(&app);
    action("editor-authenticate", None);
    completed_locked();
    let owner = prepare();
    action("editor-unlock", None);
    action("input-empty", None);
    action("input", Some(&fixture.password));
    action("editor-authenticate-start", None);
    action("auth-busy", None);
    cycle(owner);
    completed_locked();
    fixture.unlock_editor(&app, 1);
    let owner = prepare();
    let new_password = Zeroizing::new("Public compositor change passphrase".to_owned());
    action("editor-passphrase", None);
    for mode in ["pw-current-empty", "pw-new-empty", "pw-confirm-empty"] {
        action(mode, None);
    }
    for (mode, value) in [
        ("pw-current", fixture.password.as_str()),
        ("pw-new", new_password.as_str()),
        ("pw-confirm", new_password.as_str()),
    ] {
        action(mode, Some(value));
    }
    action("editor-change-start", None);
    action("pw-busy", None);
    cycle(owner);
    completed_locked();
    fixture.unlock_editor(&app, 1);
    let owner = prepare();
    let mut cli = fixture.reveal(&fixture.keyword);
    until("real pending compositor-bound CLI prompt", 5, || {
        prompt(app.id())
    });
    assert!(fixture.action(&app, "approve", None) == 0);
    assert!(fixture.action(&app, "input-empty", None) == 0);
    assert!(fixture.action(&app, "input", Some(&fixture.password)) == 0);
    cycle(owner);
    fixture.finish(&app, &mut cli, Status::Denied.exit_code().into(), None);
    completed_locked();
    fixture.unlock_editor(&app, 1);
    let document = Document::decode(original.1.as_ref().unwrap()).unwrap();
    fixture.assert_diagnostics_extra(document.records[0].metadata.id, &[&new_password]);
    assert!(!fixture.root.join("Sync").exists());
    fixture.stop(&mut app);

    let empty = Fixture::empty();
    let mut app = empty.start(0);
    empty.open_editor(&app);
    let original = empty.images();
    let mut owner = prepare();
    for (mode, value) in [
        ("setup-open", None),
        ("setup-passphrase", Some(empty.password.as_str())),
        ("setup-confirm", Some(empty.password.as_str())),
        ("setup-submit-start", None),
        ("auth-busy", None),
    ] {
        assert!(empty.action_in(&app, "Secure Snippets", mode, value) == 0);
    }
    owner.lock();
    until("actual compositor lock during setup worker", 3, || {
        desktop::session_state() == SessionState::Locked
    });
    owner.release();
    until("acknowledged setup compositor unlock", 5, || {
        desktop::session_state() == SessionState::Unlocked
    });
    empty.open_editor(&app);
    until("actual locked setup leaves vault absent", 30, || {
        empty.action_in(&app, "Secure Snippets", "setup-idle", None) == 0
    });
    empty.status(0);
    assert!(empty.images() == original);
    empty.assert_diagnostics(uuid::Uuid::nil());
    assert!(!empty.root.join("Sync").exists());
    empty.stop(&mut app);
    println!(
        "Actual compositor locks revoked an unlocked key, a filled credential dialog, observed authentication/passphrase/setup workers and CLI disclosure. Exact files, absent setup publication, fresh credentials, acknowledged unlock and diagnostics privacy passed; host PAM and lock configuration were unchanged."
    );
}
