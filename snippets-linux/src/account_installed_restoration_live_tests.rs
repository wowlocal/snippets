//! Existing restoration gates exercised in an unchanged installed Release process.
//! The production PAM helper sees only a private mount's public PAM configuration.
use super::*;
use gtk::{gio, glib::variant::ToVariant};
use std::{collections::HashMap, os::unix::fs::OpenOptionsExt, process::Stdio};

const APP: &str = "com.khm.snippets.linux";
const APP_PATH: &str = "/com/khm/snippets/linux";
const RESTORED: &str = "Saved changes restored. Current versions and previous keys are kept. Reconnect and select a library before syncing.";

pub(super) fn enabled() -> bool {
    std::env::var_os("SNIPPETS_INSTALLED_APP").is_some()
}
fn call(
    destination: &str,
    path: &str,
    interface: &str,
    method: &str,
    parameters: &glib::Variant,
) -> std::result::Result<glib::Variant, glib::Error> {
    gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)?.call_sync(
        Some(destination),
        path,
        interface,
        method,
        Some(parameters),
        None,
        gio::DBusCallFlags::NO_AUTO_START,
        5000,
        None::<&gio::Cancellable>,
    )
}
fn pid() -> Option<u32> {
    call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "GetConnectionUnixProcessID",
        &(APP,).to_variant(),
    )
    .ok()?
    .get::<(u32,)>()
    .map(|p| p.0)
}
fn activate(action: &str) {
    call(
        APP,
        APP_PATH,
        "org.gtk.Actions",
        "Activate",
        &(
            action,
            Vec::<glib::Variant>::new(),
            HashMap::<String, glib::Variant>::new(),
        )
            .to_variant(),
    )
    .unwrap();
}
struct Owned {
    child: RefCell<std::process::Child>,
    pid: u32,
    controller: PathBuf,
    last_missing: Cell<Option<[u32; 12]>>,
    _portal: super::super::portal::InstalledClient,
}
impl Owned {
    fn start(root: &Path, pam: &Pam) -> Self {
        assert!(super::super::portal::enabled() && pid().is_none());
        assert_ne!(
            std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
            std::env::var_os("SNIPPETS_SECRET_HOST_BUS")
        );
        let app = fs::canonicalize(std::env::var_os("SNIPPETS_INSTALLED_APP").unwrap()).unwrap();
        let controller =
            fs::canonicalize(std::env::var_os("SNIPPETS_INSTALLED_ATSPI").unwrap()).unwrap();
        let log = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(root.parent().unwrap().join("installed-restoration.log"))
            .unwrap();
        let mut command = Process::new("bwrap");
        command.args([
            "--die-with-parent",
            "--ro-bind",
            "/",
            "/",
            "--proc",
            "/proc",
            "--dev",
            "/dev",
        ]);
        for name in ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"] {
            let path = std::env::var_os(name).unwrap();
            command.arg("--bind").arg(&path).arg(&path);
        }
        // The binary/helper remain exact installation artifacts. Only this
        // process's mount namespace has the public, independently compiled PAM.
        command
            .arg("--ro-bind")
            .arg(pam.directory.path())
            .arg("/etc/pam.d")
            .arg(&app)
            // The private user namespace cannot access the host render node.
            // Keep fatal warnings; only this fixture uses GTK's CPU renderer.
            .env("GSK_RENDERER", "cairo")
            .env("GDK_DISABLE", "gl,vulkan")
            .env("GTK_A11Y", "atspi")
            .stdout(log.try_clone().unwrap())
            .stderr(Stdio::from(log));
        let child = RefCell::new(command.spawn().unwrap());
        until(
            "installed Release process did not register its private bus name",
            || {
                assert!(child.borrow_mut().try_wait().unwrap().is_none());
                pid().is_some()
            },
        );
        let pid = pid().unwrap();
        assert_eq!(fs::read_link(format!("/proc/{pid}/exe")).unwrap(), app);
        let result = Self {
            child,
            pid,
            controller,
            last_missing: Cell::new(None),
            _portal: super::super::portal::installed_client(pid),
        };
        activate("account");
        // A bus name and an accessible button do not prove that the account
        // window has focus or that its initial profile inspection has finished.
        result.wait("has", "Account saved. Reconnect to choose a library.", None);
        result.wait("has", "Reconnect Saved Account", None);
        result.wait("has", "Library Recovery History…", None);
        result
    }
    fn focused(&self) -> bool {
        let result = Process::new("hyprctl")
            .args(["-j", "activewindow"])
            .output()
            .unwrap();
        assert!(result.status.success());
        let window = serde_json::from_slice::<serde_json::Value>(&result.stdout).unwrap();
        window["pid"].as_u64() == Some(u64::from(self.pid))
            && window["title"].as_str() == Some("Account & Recovery")
    }
    fn key(&self, key: &str) {
        assert!(matches!(key, "Tab" | "Return" | "space"));
        assert!(self.focused());
        assert!(crate::desktop::session_state() == SessionState::Unlocked);
        let active = Process::new("hyprctl")
            .args(["-j", "activewindow"])
            .output()
            .unwrap();
        assert!(active.status.success());
        let window: serde_json::Value = serde_json::from_slice(&active.stdout).unwrap();
        assert_eq!(window["pid"].as_u64(), Some(u64::from(self.pid)));
        assert_eq!(window["title"].as_str(), Some("Account & Recovery"));
        let address = window["address"].as_str().unwrap();
        assert!(address.starts_with("0x") && address[2..].chars().all(|c| c.is_ascii_hexdigit()));
        let fields = format!("mods = \"\", key = \"{key}\", window = \"address:{address}\"");
        // Use the same key press/release delivery as the successful host-portal
        // fixture. The timer releases a pressed key; it does not defer Cancel.
        let expression = format!(
            "assert(hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"down\" }})).ok) hl.timer(function() hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"up\" }})) end, {{ timeout = 50, type = \"oneshot\" }})"
        );
        let sent = Process::new("hyprctl")
            .args(["eval", &expression])
            .output()
            .unwrap();
        assert!(sent.status.success() && sent.stdout.trim_ascii() == b"ok");
    }
    fn control(&self, operation: &str, label: &str, value: Option<&str>) -> bool {
        assert!(crate::desktop::session_state() == SessionState::Unlocked);
        assert!(self.child.borrow_mut().try_wait().unwrap().is_none());
        if !self.focused() {
            return false;
        }
        let mut command = Process::new(&self.controller);
        command.args([self.pid.to_string().as_str(), operation, label]);
        if let Some(value) = value {
            command.env("SNIPPETS_INSTALLED_PUBLIC_INPUT", value);
        } else {
            command.env_remove("SNIPPETS_INSTALLED_PUBLIC_INPUT");
        }
        let result = command.output().unwrap();
        assert!(
            matches!(result.status.code(), Some(0 | 5))
                || (operation == "enable" && result.status.code() == Some(6)),
            "Owned accessibility controller failed"
        );
        let checked = operation == "enable" && result.status.code() == Some(6);
        if result.status.success() || checked {
            assert!(result.stdout.is_empty());
            if matches!(operation, "press" | "switch3") {
                self.key("Return");
            } else if operation == "enable" && !checked {
                self.key("space");
                return false;
            }
        } else {
            let counts: [u32; 12] = serde_json::from_slice(&result.stdout).unwrap();
            assert!(counts.iter().all(|v| *v <= 8192));
            if self.last_missing.replace(Some(counts)) != Some(counts) {
                println!(
                    "Owned AT-SPI missing control counts: headers={}, selected_headers={}, reviews={}, selected_reviews={}, nodes={}, history={}, empty_history={}, storage_changed={}, keyring_failed={}, operation_failed={}, history_controls={}, matches={}",
                    counts[0],
                    counts[1],
                    counts[2],
                    counts[3],
                    counts[4],
                    counts[5],
                    counts[6],
                    counts[7],
                    counts[8],
                    counts[9],
                    counts[10],
                    counts[11]
                );
            }
            // GTK's Component.GrabFocus is unsupported. Traverse using actual
            // keys, and observe the exact control's native FOCUSED state before
            // activation. Never navigate an absent or ambiguous target.
            if counts[11] == 1 && matches!(operation, "press" | "switch3" | "enable") {
                self.key("Tab");
            }
        }
        result.status.success() || checked
    }
    fn wait(&self, operation: &str, label: &str, value: Option<&str>) {
        let description =
            format!("Exact public installed control unavailable: {operation}, {label}");
        until(&description, || self.control(operation, label, value));
    }
    fn review(&self) {
        self.wait("press", "Library Recovery History…", None);
        self.wait("switch3", "Review…", None);
    }
    fn choose(&self, paths: &[(&Path, &str)], multiple: bool, retained: bool) {
        self.review();
        let expected = paths.iter().map(|p| p.0.to_owned()).collect::<Vec<_>>();
        super::super::portal::expect(multiple, Some(&expected));
        self.wait(
            "press",
            if multiple {
                "Choose Several Vault Files…"
            } else {
                "Choose Previous Vault File…"
            },
            None,
        );
        let portal = crate::portal_live_tests::chooser("Choose Previous Vault File");
        if multiple {
            if paths.len() == 1 {
                portal.select(paths[0].0);
            } else {
                portal.key("CTRL", "A");
                portal.key("", "Return");
            }
        } else {
            portal.select(paths[0].0);
        }
        self.wait(
            "fill",
            "Current vault passphrase or recovery key",
            Some("Café public current vault fixture"),
        );
        if multiple {
            if retained {
                self.wait(
                    "enable",
                    "Also unlock the vault retained in recovery history",
                    None,
                );
                self.wait(
                    "fill",
                    "Previous vault passphrase or recovery key",
                    Some("Café public fixture"),
                );
            }
            for (index, (path, password)) in paths.iter().enumerate() {
                let kind = if path.extension().and_then(|p| p.to_str()) == Some("snippetsbackup") {
                    "backup password"
                } else {
                    "passphrase or recovery key"
                };
                let label = format!(
                    "Vault file {}: {} — {kind}",
                    index + 1,
                    path.file_name().unwrap().to_str().unwrap()
                );
                self.wait("fill", &label, Some(password));
            }
        } else {
            let label = if paths[0].0.extension().and_then(|p| p.to_str()) == Some("snippetsbackup")
            {
                "Previous vault backup password"
            } else {
                "Previous vault passphrase or recovery key"
            };
            self.wait("fill", label, Some(paths[0].1));
        }
        self.wait(
            "press",
            if multiple {
                "Verify All Saved Changes"
            } else {
                "Verify Saved Changes"
            },
            None,
        );
        self.wait("press", "Restore Changes", None);
        self.wait("has", "Computer login password", None);
    }
    fn finish(&self) {
        activate("quit");
        until("installed Release process did not terminate", || {
            self.child.borrow_mut().try_wait().unwrap().is_some()
        });
        assert!(self.child.borrow_mut().wait().unwrap().success());
        until(
            "installed application bus owner survived process termination",
            || pid().is_none(),
        );
        assert!(!Path::new(&format!("/proc/{}/exe", self.pid)).exists());
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        if self.child.get_mut().try_wait().ok().flatten().is_none() {
            let _ = self.child.get_mut().kill();
            let _ = self.child.get_mut().wait();
        }
    }
}

pub(super) fn restore(
    root: &Path,
    pam: &Pam,
    paths: &[(&Path, &str)],
    multiple: bool,
    retained: bool,
) {
    let before = creation::images(root);
    let protected = restoration_live::protected(root);
    let app = Owned::start(root, pam);
    app.review();
    super::super::portal::expect(multiple, None);
    app.wait(
        "press",
        if multiple {
            "Choose Several Vault Files…"
        } else {
            "Choose Previous Vault File…"
        },
        None,
    );
    crate::portal_live_tests::chooser("Choose Previous Vault File").key("", "Escape");
    app.wait("has", "Library Recovery History…", None);
    assert!(
        creation::images(root) == before
            && restoration_live::protected(root) == protected
            && slot(root, Slot::HistoryRestore).is_none()
    );
    app.choose(paths, multiple, retained);
    app.wait(
        "fill",
        "Computer login password",
        Some("Public fictional password"),
    );
    app.wait("press", "Cancel", None);
    until("installed cancelled PAM dialog did not close", || {
        !app.control("has", "Computer login password", None)
    });
    assert!(
        creation::images(root) == before
            && restoration_live::protected(root) == protected
            && slot(root, Slot::HistoryRestore).is_none()
    );
    app.choose(paths, multiple, retained);
    app.wait(
        "fill",
        "Computer login password",
        Some("Public fictional password"),
    );
    app.wait("press", "Authorize", None);
    app.wait("has", RESTORED, None);
    for label in ["Send Local Changes", "Receive Cloud Changes", "Sync Now"] {
        app.wait("unavailable", label, None);
    }
    assert!(
        restoration_live::protected(root) == protected
            && slot(root, Slot::HistoryRestore).is_some()
    );
    app.finish();
    println!(
        "Installed unchanged Release GUI/helper: actual host file choices, separate vault credentials, filled PAM Cancel, fresh native PAM restoration, unavailable data plane and terminal process passed; public fixtures only."
    );
}
