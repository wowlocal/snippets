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
fn registrations() -> Vec<serde_json::Value> {
    let output = Command::new("hyprctl")
        .args(["-j", "globalshortcuts"])
        .output()
        .expect("Hyprland session");
    assert!(output.status.success());
    serde_json::from_slice::<Vec<serde_json::Value>>(&output.stdout)
        .unwrap()
        .into_iter()
        .filter(|item| {
            item["name"]
                .as_str()
                .is_some_and(|name| name.starts_with(&format!("{APP_ID}:")))
        })
        .collect()
}

#[test]
#[ignore = "requires a live Hyprland session and no existing Snippets primary; temporary storage, no keys or clipboard sent"]
fn native_single_quit_stops_registered_shortcuts_and_exits() {
    assert_eq!(bus("NameHasOwner", &[APP_ID]), "(false,)");
    assert!(registrations().is_empty());
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
        b"{\"schema\":1,\"enabled\":true}",
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
    let started = Instant::now();
    while registrations().len() != 3 {
        assert!(primary.0.try_wait().unwrap().is_none());
        assert!(started.elapsed() < Duration::from_secs(8));
        thread::sleep(Duration::from_millis(50));
    }
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
    assert!(registrations().is_empty());
    assert_eq!(bus("NameHasOwner", &[APP_ID]), "(false,)");
    for path in ["snippets.json", "Vault", "Sync/base.json"] {
        assert!(!root.join(path).exists());
    }
}
