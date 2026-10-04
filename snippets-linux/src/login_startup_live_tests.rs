//! Real GTK registration, installed release and generated systemd service.
//! Only private app data/config and unique user runtime units are written.
use super::*;
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{MetadataExt, OpenOptionsExt, symlink},
    path::Path,
    process::{Command, Output, Stdio},
    thread,
    time::Instant,
};

fn command(program: &str, arguments: &[&str]) -> Output {
    Command::new("timeout")
        .args(["15s", program])
        .args(arguments)
        .stdin(Stdio::null())
        .output()
        .expect("native acceptance command")
}
fn systemd(arguments: &[&str]) -> Output {
    let mut args = vec!["--user", "--no-pager"];
    args.extend_from_slice(arguments);
    command("systemctl", &args)
}
fn property(unit: &str, name: &str) -> String {
    let output = systemd(&["show", unit, "--property", name, "--value"]);
    assert!(output.status.success(), "owned unit property unavailable");
    String::from_utf8(output.stdout).unwrap().trim().into()
}
fn bus(method: &str, arguments: &[&str]) -> String {
    let method = format!("org.freedesktop.DBus.{method}");
    let mut args = vec![
        "call",
        "--session",
        "--dest",
        "org.freedesktop.DBus",
        "--object-path",
        "/org/freedesktop/DBus",
        "--method",
        &method,
    ];
    args.extend_from_slice(arguments);
    let output = command("gdbus", &args);
    assert!(output.status.success(), "desktop bus unavailable");
    String::from_utf8(output.stdout).unwrap().trim().into()
}
fn primary_pid() -> Option<u32> {
    if bus("NameHasOwner", &[desktop::APP_ID]) != "(true,)" {
        return None;
    }
    let reply = bus("GetNameOwner", &[desktop::APP_ID]);
    let owner = reply.split('\'').nth(1).unwrap();
    bus("GetConnectionUnixProcessID", &[owner])
        .strip_prefix("(uint32 ")
        .unwrap()
        .strip_suffix(",)")
        .unwrap()
        .parse()
        .ok()
}
fn clients(pid: u32) -> Vec<serde_json::Value> {
    let output = command("hyprctl", &["-j", "clients"]);
    assert!(output.status.success(), "live compositor unavailable");
    serde_json::from_slice::<Vec<serde_json::Value>>(&output.stdout)
        .unwrap()
        .into_iter()
        .filter(|value| value["pid"].as_u64() == Some(u64::from(pid)))
        .collect()
}
fn pump() {
    let context = glib::MainContext::default();
    while context.pending() {
        context.iteration(false);
    }
    thread::sleep(Duration::from_millis(20));
}
#[track_caller]
fn until(label: &str, finished: impl Fn() -> bool) {
    let started = Instant::now();
    while !finished() {
        assert!(started.elapsed() < Duration::from_secs(15), "{label}");
        pump();
    }
}
fn generated(config: &Path, empty: &Path, root: &Path) -> Vec<PathBuf> {
    let dirs: Vec<_> = ["normal", "early", "late"]
        .into_iter()
        .map(|name| root.join(name))
        .collect();
    for dir in &dirs {
        fs::create_dir_all(dir).unwrap();
    }
    let output = Command::new("timeout")
        .args([
            "15s",
            "/usr/lib/systemd/user-generators/systemd-xdg-autostart-generator",
        ])
        .args(&dirs)
        .env("XDG_CONFIG_HOME", config)
        .env("XDG_CONFIG_DIRS", empty)
        .env("XDG_DATA_DIRS", empty)
        .env("SYSTEMD_SCOPE", "user")
        .env("SYSTEMD_LOG_LEVEL", "warning")
        .output()
        .unwrap();
    assert!(output.status.success(), "private XDG generation failed");
    dirs.iter()
        .flat_map(|dir| fs::read_dir(dir).unwrap())
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "service")
        })
        .collect()
}
struct Runtime {
    service: String,
    target: String,
    files: Vec<(PathBuf, Vec<u8>)>,
    wants: PathBuf,
    link: PathBuf,
    cleaned: bool,
}
impl Runtime {
    fn new(name: &str, unit: &[u8], config: &Path, root: &Path) -> Self {
        let directory =
            PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap()).join("systemd/user");
        fs::create_dir_all(&directory).unwrap();
        assert!(
            !fs::symlink_metadata(&directory)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        let service = format!("{name}.service");
        let target = format!("{name}.target");
        assert!(property(&service, "LoadState") == "not-found");
        assert!(property(&target, "LoadState") == "not-found");
        let wants = directory.join(format!("{target}.wants"));
        let link = wants.join(&service);
        let mut this = Self {
            service,
            target,
            files: Vec::new(),
            wants,
            link,
            cleaned: false,
        };
        let mut bytes = unit.to_vec();
        // The generated ExecStart, service type, slice and graphical-session
        // ordering are unchanged. Only the private test data/config are added.
        bytes.extend_from_slice(format!("\n[Service]\nEnvironment=SNIPPETS_SUPPORT_DIR={}\nEnvironment=XDG_CONFIG_HOME={}\nEnvironment=G_DEBUG=fatal-warnings\n", root.display(), config.display()).as_bytes());
        this.write(directory.join(&this.service), bytes);
        this.write(directory.join(&this.target), b"[Unit]\nDescription=Public Snippets native login acceptance\nAfter=graphical-session.target\n".to_vec());
        fs::create_dir(&this.wants).unwrap();
        symlink(PathBuf::from("..").join(&this.service), &this.link).unwrap();
        assert!(systemd(&["daemon-reload"]).status.success());
        this
    }
    fn write(&mut self, path: PathBuf, bytes: Vec<u8>) {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        file.write_all(&bytes).unwrap();
        file.sync_all().unwrap();
        self.files.push((path, bytes));
    }
    fn start(&self) {
        assert!(
            systemd(&["start", "--no-block", &self.target])
                .status
                .success()
        );
    }
    fn disable_link(&self) {
        assert!(fs::read_link(&self.link).unwrap() == PathBuf::from("..").join(&self.service));
        fs::remove_file(&self.link).unwrap();
        assert!(systemd(&["daemon-reload"]).status.success());
    }
    fn cleanup(&mut self) -> bool {
        if self.cleaned {
            return true;
        }
        let mut ok = systemd(&["stop", &self.target, &self.service])
            .status
            .success();
        if self.link.exists() {
            if fs::read_link(&self.link).ok() == Some(PathBuf::from("..").join(&self.service)) {
                ok &= fs::remove_file(&self.link).is_ok();
            } else {
                ok = false;
            }
        }
        ok &= fs::remove_dir(&self.wants).is_ok();
        for (path, bytes) in &self.files {
            if fs::read(path).ok().as_ref() == Some(bytes) {
                ok &= fs::remove_file(path).is_ok();
            } else {
                ok = false;
            }
        }
        ok &= systemd(&["daemon-reload"]).status.success();
        self.cleaned = ok;
        ok
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}
fn secondary(binary: &Path, root: &Path, config: &Path, args: &[&str]) -> Output {
    Command::new("timeout")
        .arg("15s")
        .arg(binary)
        .args(args)
        .env("SNIPPETS_SUPPORT_DIR", root)
        .env("XDG_CONFIG_HOME", config)
        .env("G_DEBUG", "fatal-warnings")
        .output()
        .unwrap()
}

#[test]
#[ignore = "explicit live installed-release/systemd/GTK login acceptance; invoke tests/login-startup-live.sh"]
fn live_native_login_launch() {
    assert!(crate::desktop::session_state() == crate::desktop::SessionState::Unlocked);
    assert!(
        primary_pid().is_none(),
        "existing Snippets primary must be preserved"
    );
    assert!(property("graphical-session.target", "ActiveState") == "active");
    assert!(property("xdg-desktop-autostart.target", "ActiveState") == "active");
    let environment = systemd(&["show-environment"]);
    assert!(environment.status.success());
    let environment = String::from_utf8(environment.stdout).unwrap();
    for key in [
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
        "WAYLAND_DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
    ] {
        let value = std::env::var(key).unwrap();
        assert!(
            environment
                .lines()
                .any(|line| line == format!("{key}={value}")),
            "live user-manager environment differs"
        );
    }
    let user_config = crate::desktop_settings::config_home(
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
    )
    .unwrap();
    let user_entry = user_config.join("autostart/com.khm.snippets.linux.desktop");
    let original_entry = fs::read(&user_entry).ok();
    let release = PathBuf::from(
        std::env::var_os("SNIPPETS_STARTUP_TEST_RELEASE").expect("explicit native wrapper"),
    );
    let temp = tempfile::Builder::new()
        .prefix("snippets-login-")
        .tempdir()
        .unwrap();
    let config = temp.path().join("config");
    let root = temp.path().join("library");
    let empty = temp.path().join("empty");
    fs::create_dir(&empty).unwrap();
    let installed = temp.path().join("installed with spaces");
    fs::create_dir(&installed).unwrap();
    for name in ["snippets", "snippets-cli", "snippets-owner-auth"] {
        fs::copy(release.join(name), installed.join(name)).unwrap();
        assert!(fs::metadata(installed.join(name)).unwrap().nlink() == 1);
        assert!(fs::read(release.join(name)).unwrap() == fs::read(installed.join(name)).unwrap());
    }
    let binary = installed.join("snippets");
    adw::init().expect("graphical display");
    let app = adw::Application::builder()
        .application_id("com.khm.snippets.linux.NativeLoginAcceptance")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.register(None::<&gio::Cancellable>).unwrap();
    let settings = Settings::with_registration(
        &app,
        root.clone(),
        Registration::new(config.clone()),
        Some(binary.clone()),
        None,
    );
    settings
        .window
        .set_title(Some("Public Native Login Settings Acceptance"));
    settings.present();
    until("native login settings did not map", || {
        settings.window.is_active() && settings.startup.is_mapped()
    });
    assert!(!settings.startup.is_active());
    settings.startup.set_active(true);
    until("native login registration did not save", || {
        settings.can_quit()
    });
    assert!(settings.error.get().is_none() && settings.startup.is_active());
    let registration = Registration::new(config.clone()).unwrap();
    let snapshot = registration.read().unwrap();
    assert!(snapshot.enabled && snapshot.executable == Some(binary.clone()));
    assert!(
        command(
            "desktop-file-validate",
            &[registration.entry_path().to_str().unwrap()]
        )
        .status
        .success()
    );
    let outputs = temp.path().join("enabled");
    let services = generated(&config, &empty, &outputs);
    assert!(services.len() == 1);
    let filename = services[0].file_name().unwrap();
    assert!(["normal", "early", "late"].iter().any(|name| {
        outputs
            .join(name)
            .join("xdg-desktop-autostart.target.wants")
            .join(filename)
            .exists()
    }));
    let unit = fs::read(&services[0]).unwrap();
    let name = temp.path().file_name().unwrap().to_str().unwrap();
    let mut runtime = Runtime::new(name, &unit, &config, &root);
    runtime.start();
    until("generated native login service did not start", || {
        property(&runtime.service, "ActiveState") == "active" && primary_pid().is_some()
    });
    let pid: u32 = property(&runtime.service, "MainPID").parse().unwrap();
    assert!(primary_pid() == Some(pid));
    assert!(fs::read_link(format!("/proc/{pid}/exe")).unwrap() == binary);
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(750) {
        pump();
    }
    assert!(
        clients(pid).is_empty(),
        "background login unexpectedly mapped a window"
    );
    let status = secondary(
        &installed.join("snippets-cli"),
        &root,
        &config,
        &["secure-status"],
    );
    assert!(
        status.status.success(),
        "installed CLI peer admission failed"
    );
    assert!(
        serde_json::from_slice::<serde_json::Value>(&status.stdout).unwrap()
            == serde_json::json!({"secureCount":0,"appAvailable":true,"unlocked":false})
    );
    assert!(
        secondary(&binary, &root, &config, &["--background"])
            .status
            .success()
    );
    assert!(primary_pid() == Some(pid) && clients(pid).is_empty());
    assert!(secondary(&binary, &root, &config, &[]).status.success());
    until(
        "secondary activation did not map the same owned primary",
        || clients(pid).len() == 1,
    );
    assert!(primary_pid() == Some(pid));
    assert!(
        secondary(&binary, &root, &config, &["--background"])
            .status
            .success()
    );
    assert!(primary_pid() == Some(pid) && clients(pid).len() == 1);
    settings.window.present();
    until("native login settings did not regain focus", || {
        settings.window.is_active()
    });
    settings.startup.set_active(false);
    until("native login opt-out did not save", || settings.can_quit());
    assert!(settings.error.get().is_none() && !registration.read().unwrap().enabled);
    assert!(generated(&config, &empty, &temp.path().join("disabled")).is_empty());
    assert!(
        primary_pid() == Some(pid),
        "login opt-out must preserve the running app"
    );
    assert!(
        secondary(&binary, &root, &config, &["--quit"])
            .status
            .success()
    );
    until(
        "one Quit did not release the generated native login service",
        || primary_pid().is_none() && property(&runtime.service, "ActiveState") == "inactive",
    );
    assert!(property(&runtime.service, "Result") == "success");
    runtime.disable_link();
    assert!(systemd(&["stop", &runtime.target]).status.success());
    runtime.start();
    until("disabled native login target did not start", || {
        property(&runtime.target, "ActiveState") == "active"
    });
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(750) {
        pump();
    }
    assert!(primary_pid().is_none() && property(&runtime.service, "ActiveState") == "inactive");
    for path in [
        "snippets.json",
        "Vault",
        "Sync",
        "automatic-sync.json",
        "ClipboardHistory",
        "Usage/usage.json",
        "Usage/preferences.json",
    ] {
        assert!(!root.join(path).exists(), "unexpected fixture data: {path}");
    }
    // The normal primary starts local learning and takes its private lock even
    // when no snippets were used. That empty lock is not learned user data.
    let usage = fs::symlink_metadata(root.join("Usage")).unwrap();
    assert!(usage.is_dir() && usage.mode() & 0o777 == 0o700);
    let lock = fs::symlink_metadata(root.join("Usage/usage.lock")).unwrap();
    assert!(lock.is_file() && lock.nlink() == 1 && lock.len() == 0);
    assert!(lock.mode() & 0o777 == 0o600);
    assert!(runtime.cleanup());
    assert!(
        fs::read(&user_entry).ok() == original_entry,
        "user login entry changed"
    );
    settings.window.destroy();
    app.quit();
}
