#![cfg(feature = "desktop")]
use std::{
    fs,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const APP_ID: &str = "com.khm.snippets.linux";

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}
fn bus(method: &str, arguments: &[&str]) -> String {
    let output = Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.freedesktop.DBus",
            "--object-path",
            "/org/freedesktop/DBus",
            "--method",
            &format!("org.freedesktop.DBus.{method}"),
        ])
        .args(arguments)
        .output()
        .expect("session bus");
    assert!(output.status.success(), "session bus call failed");
    String::from_utf8(output.stdout).unwrap().trim().into()
}
fn expansion(
    installed: &std::path::Path,
    root: &std::path::Path,
    command: &str,
) -> serde_json::Value {
    let output = Command::new(installed.join("snippets-cli"))
        .args(["expansion", command])
        .env("SNIPPETS_SUPPORT_DIR", root)
        .output()
        .unwrap();
    assert!(output.status.success(), "expansion control failed");
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
#[ignore = "requires SNIPPETS_GNOME_LIVE=read-only, a live GNOME session and no existing Snippets primary"]
fn gnome_background_control_and_single_quit() {
    assert_eq!(
        std::env::var("SNIPPETS_GNOME_LIVE").as_deref(),
        Ok("read-only")
    );
    use snippets_linux::desktop::{
        Environment, SessionMonitor, SessionState, environment, session_state,
    };
    assert_eq!(environment(), Environment::Gnome);
    let expected = session_state();
    assert!(expected != SessionState::Unavailable);
    let monitor = SessionMonitor::new().unwrap();
    let started = Instant::now();
    while monitor.snapshot().0 == SessionState::Unavailable {
        assert!(
            started.elapsed() < Duration::from_secs(8),
            "GNOME lock state unavailable"
        );
        thread::sleep(Duration::from_millis(50));
    }
    assert!(monitor.snapshot().0 == expected);
    drop(monitor);
    assert_eq!(bus("NameHasOwner", &[APP_ID]), "(false,)");
    let directory = tempfile::tempdir().unwrap();
    let installed = directory.path().join("installed");
    let root = directory.path().join("library");
    fs::create_dir(&installed).unwrap();
    fs::create_dir(&root).unwrap();
    // Cargo can hard-link its output. Installation copies give peer checks the
    // same single-link executable layout as the supported installer.
    for (name, source) in [
        ("snippets", env!("CARGO_BIN_EXE_snippets")),
        ("snippets-cli", env!("CARGO_BIN_EXE_snippets-cli")),
        (
            "snippets-owner-auth",
            env!("CARGO_BIN_EXE_snippets-owner-auth"),
        ),
    ] {
        fs::copy(source, installed.join(name)).unwrap();
    }
    fs::write(
        root.join("global-shortcuts.json"),
        b"{\"schema\":1,\"enabled\":false}",
    )
    .unwrap();
    let log = fs::File::create(directory.path().join("desktop.log")).unwrap();
    let binary = installed.join("snippets");
    let mut primary = OwnedChild(
        Command::new(&binary)
            .arg("--background")
            .env("SNIPPETS_SUPPORT_DIR", &root)
            .env("G_DEBUG", "fatal-warnings")
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .unwrap(),
    );
    let started = Instant::now();
    while bus("NameHasOwner", &[APP_ID]) != "(true,)" {
        assert!(primary.0.try_wait().unwrap().is_none());
        assert!(started.elapsed() < Duration::from_secs(8));
        thread::sleep(Duration::from_millis(50));
    }
    let owner_reply = bus("GetNameOwner", &[APP_ID]);
    let owner = owner_reply.split('\'').nth(1).unwrap();
    assert_eq!(
        bus("GetConnectionUnixProcessID", &[owner]),
        format!("(uint32 {},)", primary.0.id())
    );
    assert_eq!(expansion(&installed, &root, "status")["state"], "disabled");
    expansion(&installed, &root, "enable");
    let started = Instant::now();
    loop {
        let status = expansion(&installed, &root, "status");
        if status["state"] == "unsupportedDesktop" {
            break;
        }
        assert!(
            started.elapsed() < Duration::from_secs(8),
            "incorrect GNOME expansion state: {status}"
        );
        thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(expansion(&installed, &root, "disable")["state"], "disabled");
    let mut request = OwnedChild(
        Command::new(binary)
            .arg("--quit")
            .env("SNIPPETS_SUPPORT_DIR", &root)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let started = Instant::now();
    for child in [&mut request.0, &mut primary.0] {
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            assert!(
                started.elapsed() < Duration::from_secs(8),
                "single Quit did not finish"
            );
            thread::sleep(Duration::from_millis(50));
        }
    }
    assert_eq!(bus("NameHasOwner", &[APP_ID]), "(false,)");
    for path in ["snippets.json", "Vault", "Sync/base.json"] {
        assert!(!root.join(path).exists());
    }
}
