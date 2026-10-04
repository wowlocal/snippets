//! Live owned portal input for public fixtures; no configuration mutation.
use crate::desktop;
use gtk::glib;
use std::{
    cell::RefCell,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant},
};
fn host_bus() -> String {
    std::env::var("SNIPPETS_SECRET_HOST_BUS")
        .unwrap_or_else(|_| std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap())
}
fn settle(duration: Duration) {
    let end = Instant::now() + duration;
    while Instant::now() < end {
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn until(seconds: u64, predicate: impl Fn() -> bool) {
    let end = Instant::now() + Duration::from_secs(seconds);
    while !predicate() {
        assert!(Instant::now() < end, "The actual host chooser did not map.");
        settle(Duration::from_millis(10));
    }
}
fn query(name: &str) -> serde_json::Value {
    let result = Command::new("hyprctl").args(["-j", name]).output().unwrap();
    assert!(result.status.success());
    serde_json::from_slice(&result.stdout).unwrap()
}
pub(crate) struct Portal {
    address: String,
    pid: u64,
}
impl Portal {
    fn find(title: &str) -> Option<Self> {
        let clients = query("clients");
        let mut matches = clients
            .as_array()
            .unwrap()
            .iter()
            .filter(|c| c["title"].as_str() == Some(title));
        let client = matches.next()?;
        assert!(
            matches.next().is_none(),
            "The fixture chooser must be unique."
        );
        let address = client["address"].as_str().unwrap().to_owned();
        assert!(address.starts_with("0x") && address[2..].bytes().all(|c| c.is_ascii_hexdigit()));
        let pid = client["pid"].as_u64().unwrap();
        let owned = ["gtk", "kde", "gnome", "hyprland"]
            .iter()
            .any(|implementation| {
                let result = Command::new("gdbus")
                    .args([
                        "call",
                        "--address",
                        &host_bus(),
                        "--dest",
                        "org.freedesktop.DBus",
                        "--object-path",
                        "/org/freedesktop/DBus",
                        "--method",
                        "org.freedesktop.DBus.GetConnectionUnixProcessID",
                        &format!("org.freedesktop.impl.portal.desktop.{implementation}"),
                    ])
                    .output()
                    .unwrap();
                result.status.success()
                    && String::from_utf8(result.stdout)
                        .unwrap()
                        .split(|c: char| !c.is_ascii_digit())
                        .rfind(|s| !s.is_empty())
                        .and_then(|s| s.parse::<u64>().ok())
                        == Some(pid)
            });
        assert!(
            owned,
            "The chooser must belong to the actual desktop portal implementation."
        );
        Some(Self { address, pid })
    }
    pub(crate) fn key(&self, mods: &str, key: &str) {
        assert!(desktop::session_state() == desktop::SessionState::Unlocked);
        let active = query("activewindow");
        assert!(
            active["address"].as_str() == Some(&self.address)
                && active["pid"].as_u64() == Some(self.pid),
            "No input is sent unless the owned portal is active."
        );
        assert!(
            mods.bytes().all(|c| c.is_ascii_uppercase())
                && key.bytes().all(|c| c.is_ascii_alphanumeric())
        );
        let fields = format!(
            "mods = \"{mods}\", key = \"{key}\", window = \"address:{}\"",
            self.address
        );
        let expression = format!(
            "assert(hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"down\" }})).ok) hl.timer(function() hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"up\" }})) end, {{ timeout = 50, type = \"oneshot\" }})"
        );
        let result = Command::new("hyprctl")
            .args(["eval", &expression])
            .output()
            .unwrap();
        assert!(result.status.success() && result.stdout.trim_ascii() == b"ok");
        settle(Duration::from_millis(80));
    }
    fn type_location(&self, path: &Path) {
        // Only the public fixture path is sent to the portal. Credentials are
        // entered directly into real PasswordEntry widgets in this process.
        self.key("CTRL", "L");
        self.key("CTRL", "A");
        for c in path.to_str().unwrap().chars() {
            let (mods, key) = match c {
                ' ' => ("", "space".to_owned()),
                '/' => ("", "slash".to_owned()),
                '.' => ("", "period".to_owned()),
                '-' => ("", "minus".to_owned()),
                '_' => ("SHIFT", "minus".to_owned()),
                c if c.is_ascii_uppercase() => ("SHIFT", c.to_ascii_lowercase().to_string()),
                c if c.is_ascii_lowercase() || c.is_ascii_digit() => ("", c.to_string()),
                _ => panic!("Only a public ASCII fixture path may be typed."),
            };
            self.key(mods, &key);
        }
    }
    fn location(&self, path: &Path) {
        self.type_location(path);
        self.key("", "Return");
    }
    pub(crate) fn select(&self, path: &Path) {
        self.location(path);
        // Open first resolves the typed location, then confirms its selected
        // file. Save can already have returned after the first Return.
        settle(Duration::from_millis(150));
        if query("clients").as_array().unwrap().iter().any(|c| {
            c["address"].as_str() == Some(&self.address) && c["pid"].as_u64() == Some(self.pid)
        }) {
            self.key("", "Return");
        }
    }
    pub(crate) fn select_multiple(&self, paths: &[PathBuf]) {
        assert!(!paths.is_empty());
        if paths.len() == 1 {
            self.select(&paths[0]);
            return;
        }
        let directory = paths[0].parent().unwrap();
        let owned = paths
            .iter()
            .cloned()
            .collect::<std::collections::BTreeSet<_>>();
        assert!(paths.iter().all(|p| p.parent() == Some(directory)));
        assert!(
            std::fs::read_dir(directory)
                .unwrap()
                .map(|e| e.unwrap().path())
                .collect::<std::collections::BTreeSet<_>>()
                == owned
        );
        // The account relay gives the real host portal only an initial-folder
        // hint for this exclusive public directory. It returns actual selected
        // URIs unchanged and checks the exact set before credentials.
        settle(Duration::from_millis(250));
        self.key("CTRL", "A");
        // Activate Open without activating the tree view's current row.
        self.key("ALT", "O");
    }
}
pub(crate) fn chooser(title: &str) -> Portal {
    let portal = RefCell::new(None);
    until(10, || {
        *portal.borrow_mut() = Portal::find(title);
        portal.borrow().is_some()
    });
    settle(Duration::from_millis(200));
    portal.into_inner().unwrap()
}
