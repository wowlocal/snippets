//! Real installed Release app and CLI, native consent and fresh credentials.
//! The wrapper owns a private bus/registry; all library/input material is public fiction.
use super::*;
use crate::{crypto, desktop, model, vault::Document};
use gtk::gio;
use std::{
    fs,
    io::Write,
    os::unix::fs::{DirBuilderExt, FileTypeExt, PermissionsExt},
    path::Path,
    process::{Child, Command as ProcessCommand, Output, Stdio},
    time::Instant,
};

struct Process(Option<Child>);
impl Process {
    fn start(command: &mut ProcessCommand) -> Self {
        Self(Some(
            command
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap(),
        ))
    }
    fn id(&self) -> u32 {
        self.0.as_ref().unwrap().id()
    }
    fn finished(&mut self) -> bool {
        self.0.as_mut().unwrap().try_wait().unwrap().is_some()
    }
    fn output(&mut self) -> Output {
        self.0.take().unwrap().wait_with_output().unwrap()
    }
    fn disconnect(&mut self) {
        self.0.as_mut().unwrap().kill().unwrap();
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        if let Some(child) = self.0.as_mut() {
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
    }
}
fn settle(duration: Duration) {
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}
#[track_caller]
fn until(label: &str, seconds: u64, mut predicate: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while !predicate() {
        assert!(
            Instant::now() < deadline,
            "Native control fixture timed out at {label}."
        );
        settle(Duration::from_millis(10));
    }
}
fn query(name: &str) -> serde_json::Value {
    let output = ProcessCommand::new("hyprctl")
        .args(["-j", name])
        .output()
        .unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}
fn prompt(pid: u32) -> bool {
    query("clients").as_array().unwrap().iter().any(|c| {
        c["title"].as_str() == Some("Snippets CLI Request")
            && c["pid"].as_u64() == Some(u64::from(pid))
    })
}
fn active(pid: u32) -> bool {
    active_window(pid, "Snippets CLI Request")
}
fn active_window(pid: u32, title: &str) -> bool {
    let window = query("activewindow");
    window["title"].as_str() == Some(title) && window["pid"].as_u64() == Some(u64::from(pid))
}
struct Fixture {
    _directory: tempfile::TempDir,
    root: PathBuf,
    binaries: PathBuf,
    actor: PathBuf,
    input: PathBuf,
    keyword: String,
    password: Zeroizing<String>,
    body: Zeroizing<Vec<u8>>,
}
impl Fixture {
    fn new() -> Self {
        let directory = tempfile::Builder::new()
            .prefix("snippets-control-live.")
            .tempdir()
            .unwrap();
        let root = directory.path().join("data/snippets");
        let library = model::Library::open(root.clone()).unwrap();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join("Vault"))
            .unwrap();
        model::atomic_write(
            &root.join("Vault/vault.json"),
            &serde_json::to_vec(&fixture["document"]).unwrap(),
        )
        .unwrap();
        let source = Path::new(env!("CARGO_MANIFEST_DIR"));
        let release = PathBuf::from(std::env::var_os("SNIPPETS_CONTROL_TEST_RELEASE").unwrap());
        assert!(release.is_absolute() && release.file_name().unwrap() == "release");
        let prefix = directory.path().join("prefix");
        let installation = ProcessCommand::new("bash")
            .arg(source.parent().unwrap().join("scripts/install-linux.sh"))
            .arg("--prefix")
            .arg(&prefix)
            .arg("--no-build")
            .env("CARGO_TARGET_DIR", release.parent().unwrap())
            .output()
            .unwrap();
        assert!(
            installation.status.success(),
            "Private installation of the real Release binaries must succeed."
        );
        let binaries = prefix.join("share/snippets-linux");
        for name in ["snippets", "snippets-cli", "snippets-owner-auth"] {
            assert!(
                fs::read(binaries.join(name)).unwrap() == fs::read(release.join(name)).unwrap()
            );
        }
        let flags = ProcessCommand::new("pkg-config")
            .args(["--cflags", "--libs", "atspi-2", "gobject-2.0"])
            .output()
            .unwrap();
        assert!(flags.status.success());
        let actor = directory.path().join("control-atspi");
        let compiled = ProcessCommand::new("cc")
            .args(["-Wall", "-Wextra", "-Werror"])
            .arg(source.join("tests/reference/control-atspi.c"))
            .args(
                std::str::from_utf8(&flags.stdout)
                    .unwrap()
                    .split_whitespace(),
            )
            .arg("-o")
            .arg(&actor)
            .output()
            .unwrap();
        assert!(
            compiled.status.success(),
            "The native private-bus actor must compile."
        );
        let input = directory.path().join("submitted.txt");
        model::atomic_write(
            &input,
            "Public CLI creation body 🦀\nwith two lines\n".as_bytes(),
        )
        .unwrap();
        assert!(fs::metadata(&input).unwrap().permissions().mode() & 0o777 == 0o600);
        drop(library);
        Self {
            _directory: directory,
            root,
            binaries,
            actor,
            input,
            keyword: fixture["document"]["records"][0]["keyword"]
                .as_str()
                .unwrap()
                .into(),
            password: Zeroizing::new(fixture["passphrase"].as_str().unwrap().into()),
            body: Zeroizing::new(fixture["plaintext"].as_str().unwrap().as_bytes().into()),
        }
    }
    fn command(&self, name: &str) -> ProcessCommand {
        let mut command = ProcessCommand::new(self.binaries.join(name));
        command.env("XDG_DATA_HOME", self.root.parent().unwrap());
        command.env_remove("SNIPPETS_SUPPORT_DIR");
        command
    }
    fn start(&self, count: usize) -> Process {
        let mut app = Process::start(self.command("snippets").arg("--background"));
        until("real primary control socket", 10, || {
            self.root.exists()
                && fs::symlink_metadata(crate::control::endpoint(&self.root).unwrap())
                    .is_ok_and(|m| m.file_type().is_socket())
        });
        assert!(!app.finished());
        self.status(count);
        app
    }
    fn status(&self, count: usize) {
        self.status_state(count, false);
    }
    fn status_state(&self, count: usize, unlocked: bool) {
        assert!(self.state(count) == unlocked);
    }
    fn state(&self, count: usize) -> bool {
        let mut value = None;
        // The status worker's common file lock is nonblocking; native editor
        // polling/authentication can briefly own it. Only this read-only probe
        // may repeat a transport refusal. Secure requests are never retried.
        until("read-only CLI status admission", 5, || {
            value = self.try_state(count);
            value.is_some()
        });
        value.unwrap()
    }
    fn try_state(&self, count: usize) -> Option<bool> {
        let output = self
            .command("snippets-cli")
            .arg("secure-status")
            .output()
            .unwrap();
        let failure = [
            ("peer", control::REFUSED.0),
            ("closed", control::CLOSED.0),
            ("refused", Status::Refused.message()),
            ("unconfirmed", Status::Error.message()),
        ]
        .into_iter()
        .find(|(_, message)| output.stderr == format!("{message}\n").as_bytes())
        .map_or("other", |(label, _)| label);
        if output.status.code() == Some(1) && output.stdout.is_empty() && failure == "unconfirmed" {
            return None;
        }
        assert!(
            output.status.success() && output.stderr.is_empty(),
            "Read-only CLI status failed: code={:?}, stdout_empty={}, stderr_empty={}, family={failure}",
            output.status.code(),
            output.stdout.is_empty(),
            output.stderr.is_empty()
        );
        let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert!(value["appAvailable"] == true && value["secureCount"] == count);
        Some(value["unlocked"].as_bool().unwrap())
    }
    fn unlock_editor(&self, app: &Process, count: usize) {
        let activated = ProcessCommand::new("gdbus")
            .args([
                "call",
                "--session",
                "--dest",
                "com.khm.snippets.linux",
                "--object-path",
                "/com/khm/snippets/linux",
                "--method",
                "org.gtk.Actions.Activate",
                "secure",
                "[]",
                "{}",
            ])
            .output()
            .unwrap();
        assert!(activated.status.success() && activated.stderr.is_empty());
        until("actual secure editor activation", 10, || {
            active_window(app.id(), "Secure Snippets")
        });
        self.status(count);
        assert!(self.action_in(app, "Secure Snippets", "editor-unlock", None) == 0);
        assert!(self.action_in(app, "Secure Snippets", "input", Some(&self.password)) == 0);
        assert!(self.action_in(app, "Secure Snippets", "editor-authenticate", None) == 0);
        println!("The actual native editor credential was submitted; awaiting unlocked status.");
        until("actual editor session unlocked", 30, || self.state(count));
        assert!(active_window(app.id(), "Secure Snippets"));
        self.status_state(count, true);
        println!("The installed CLI observed the actual unlocked editor session.");
    }
    fn reveal(&self, keyword: &str) -> Process {
        Process::start(self.command("snippets-cli").args(["reveal", keyword]))
    }
    fn create(&self) -> Process {
        Process::start(
            self.command("snippets-cli")
                .args([
                    "add",
                    "--secure",
                    "--name",
                    "Public CLI created entry",
                    "--keyword",
                    "public-cli-created",
                    "--tags",
                    "PublicControl",
                    "--content-file",
                ])
                .arg(&self.input),
        )
    }
    fn wait_prompt(&self, app: &Process) {
        until("real CLI consent window", 10, || {
            prompt(app.id()) && active(app.id())
        });
        assert!(desktop::session_state() == SessionState::Unlocked);
    }
    fn action(&self, app: &Process, mode: &str, secret: Option<&str>) -> i32 {
        self.action_in(app, "Snippets CLI Request", mode, secret)
    }
    fn action_in(&self, app: &Process, title: &str, mode: &str, secret: Option<&str>) -> i32 {
        assert!(matches!(title, "Snippets CLI Request" | "Secure Snippets"));
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            assert!(
                desktop::session_state() == SessionState::Unlocked
                    && active_window(app.id(), title),
                "Only the exact active owned CLI window may receive an action."
            );
            let mut child = ProcessCommand::new(&self.actor)
                .arg(mode)
                .env("SNIPPETS_CONTROL_TEST_PID", app.id().to_string())
                .env("SNIPPETS_CONTROL_TEST_WINDOW", title)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            if let Some(secret) = secret {
                child
                    .stdin
                    .take()
                    .unwrap()
                    .write_all(secret.as_bytes())
                    .unwrap();
            } else {
                drop(child.stdin.take());
            }
            let output = child.wait_with_output().unwrap();
            assert!(
                output.stderr.is_empty(),
                "The native actor must emit no warnings."
            );
            let code = output.status.code().unwrap_or(-1);
            if code == 5 && Instant::now() < deadline {
                settle(Duration::from_millis(100));
                continue;
            }
            assert!(
                code == 0 || code == 6 || code == 11,
                "The native owned control must be unique and available; action={mode}, status={code}, flags={}.",
                String::from_utf8_lossy(&output.stdout)
            );
            settle(Duration::from_millis(150));
            return code;
        }
    }
    fn approve(&self, app: &Process, secret: &str, recovery: bool) {
        assert!(self.action(app, "approve", None) == 0);
        assert!(
            self.action(app, "authenticate", None) == 6,
            "An empty credential must leave Authenticate insensitive."
        );
        if recovery {
            for _ in 0..16 {
                if self.action(app, "recovery", None) == 0 {
                    break;
                }
                self.press(app, "tab");
            }
            assert!(self.action(app, "recovery", None) == 0);
            self.press(app, "space");
            assert!(self.action(app, "recovery-selected", None) == 0);
        }
        assert!(self.action(app, "input", Some(secret)) == 0);
        assert!(self.action(app, "authenticate", None) == 0);
    }
    fn press(&self, app: &Process, key: &str) {
        assert!(matches!(key, "tab" | "space"));
        let window = query("activewindow");
        assert!(active(app.id()) && desktop::session_state() == SessionState::Unlocked);
        let address = window["address"].as_str().unwrap();
        assert!(address.starts_with("0x") && address[2..].bytes().all(|c| c.is_ascii_hexdigit()));
        let fields = format!("mods = \"\", key = \"{key}\", window = \"address:{address}\"");
        let expression = format!(
            "assert(hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"down\" }})).ok) hl.timer(function() hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"up\" }})) end, {{ timeout = 50, type = \"oneshot\" }})"
        );
        let sent = ProcessCommand::new("hyprctl")
            .args(["eval", &expression])
            .output()
            .unwrap();
        assert!(sent.status.success() && sent.stdout.trim_ascii() == b"ok");
        settle(Duration::from_millis(150));
    }
    fn finish(&self, app: &Process, cli: &mut Process, code: i32, body: Option<&[u8]>) {
        self.finish_within(app, cli, code, body, 30);
    }
    fn finish_within(
        &self,
        app: &Process,
        cli: &mut Process,
        code: i32,
        body: Option<&[u8]>,
        seconds: u64,
    ) {
        until("real CLI completion", seconds, || {
            cli.0.as_mut().unwrap().try_wait().unwrap().is_some()
        });
        let output = cli.output();
        assert!(
            output.status.code() == Some(code),
            "Unexpected real CLI outcome."
        );
        if let Some(body) = body {
            assert!(output.stdout.as_slice() == body && output.stderr.is_empty());
        } else {
            assert!(output.stdout.is_empty());
        }
        until("owned consent window removed", 5, || !prompt(app.id()));
    }
    fn stop(&self, app: &mut Process) {
        let quit = self.command("snippets").arg("--quit").output().unwrap();
        assert!(quit.status.success());
        until("real primary graceful quit", 10, || {
            app.0.as_mut().unwrap().try_wait().unwrap().is_some()
        });
        let output = app.output();
        assert!(
            output.status.success() && output.stderr.is_empty(),
            "The real primary must quit without GTK warnings."
        );
    }
    fn images(&self) -> (Option<Vec<u8>>, Option<Vec<u8>>) {
        (
            model::read_regular(&self.root.join("snippets.json")).unwrap(),
            model::read_regular(&self.root.join("Vault/vault.json")).unwrap(),
        )
    }
    fn assert_diagnostics(&self, id: uuid::Uuid) {
        let mut retained_events = 0;
        for path in self.root.join("Diagnostics/Logs").read_dir().unwrap() {
            let path = path.unwrap().path();
            if !path.is_file() {
                continue;
            }
            let bytes = fs::read(path).unwrap();
            let text = std::str::from_utf8(&bytes).unwrap();
            for line in text.lines() {
                let event: serde_json::Value = serde_json::from_str(line).unwrap();
                retained_events += 1;
                fn check(value: &serde_json::Value, forbidden: &[&str]) {
                    match value {
                        serde_json::Value::String(value) => {
                            assert!(
                                forbidden.iter().all(|text| !value
                                    .to_lowercase()
                                    .contains(&text.to_lowercase())),
                                "Retained diagnostics must contain no body, credential, name, caller path or record ID."
                            );
                        }
                        serde_json::Value::Array(values) => {
                            values.iter().for_each(|value| check(value, forbidden))
                        }
                        serde_json::Value::Object(values) => {
                            values.values().for_each(|value| check(value, forbidden))
                        }
                        _ => {}
                    }
                }
                check(
                    &event,
                    &[
                        std::str::from_utf8(&self.body).unwrap().trim(),
                        "Public CLI creation body",
                        &self.password,
                        "Public CLI created entry",
                        "Public concurrent metadata edit",
                        &id.to_string(),
                        self.binaries.to_str().unwrap(),
                        self.root.to_str().unwrap(),
                    ],
                );
            }
        }
        assert!(retained_events > 0);
    }
}

#[test]
#[ignore = "unlocked Omarchy; actual installed Release editor and CLI, public private-root fixture only"]
fn live_installed_cli_does_not_borrow_unlocked_editor() {
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
    let fixture = Fixture::new();
    let mut app = fixture.start(1);
    let before = fixture.images();
    for outcome in 0..4 {
        fixture.unlock_editor(&app, 1);
        assert!(fixture.images() == before);
        let mut cli = fixture.reveal(&fixture.keyword);
        fixture.wait_prompt(&app);
        fixture.status(1);
        assert!(
            !cli.finished(),
            "An unlocked editor must not disclose before consent."
        );
        match outcome {
            0 => {
                assert!(fixture.action(&app, "deny", None) == 0);
                fixture.finish(&app, &mut cli, 4, None);
            }
            1 => {
                fixture.approve(&app, "Wrong public control credential", false);
                fixture.finish(&app, &mut cli, 5, None);
            }
            2 => {
                assert!(fixture.action(&app, "approve", None) == 0);
                assert!(fixture.action(&app, "authenticate", None) == 6);
                assert!(fixture.action(&app, "input", Some(&fixture.password)) == 0);
                assert!(fixture.action(&app, "cancel", None) == 0);
                fixture.finish(&app, &mut cli, 4, None);
            }
            _ => {
                fixture.approve(&app, &fixture.password, false);
                fixture.finish(&app, &mut cli, 0, Some(&fixture.body));
            }
        }
        fixture.status(1);
        assert!(fixture.images() == before);
    }
    println!(
        "Actual native editor unlock preceded every reveal; Deny, wrong fresh credentials and Cancel refused, and only a fresh authenticated reveal returned exact bytes. The prior editor session stayed locked."
    );

    fixture.unlock_editor(&app, 1);
    let mut cli = fixture.create();
    fixture.wait_prompt(&app);
    fixture.status(1);
    assert!(!cli.finished());
    fixture.approve(&app, &fixture.password, false);
    until(
        "secure creation from an initially unlocked editor",
        30,
        || cli.finished(),
    );
    let output = cli.output();
    assert!(output.status.success() && output.stderr.is_empty());
    let receipt: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(
        receipt.as_object().unwrap().len() == 3
            && receipt["keyword"] == "public-cli-created"
            && receipt["secure"] == true
    );
    let id = uuid::Uuid::parse_str(receipt["id"].as_str().unwrap()).unwrap();
    assert!(!id.is_nil());
    until("creation consent removed", 5, || !prompt(app.id()));
    fixture.status(2);
    let created = fixture.images();
    assert!(created.0 == before.0 && created.1 != before.1);
    let document = Document::decode(created.1.as_ref().unwrap()).unwrap();
    assert!(document.records.len() == 2 && document.records.iter().any(|r| r.metadata.id == id));
    let reference = ProcessCommand::new("python3")
        .arg("-B")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/control-vault.py"))
        .arg(fixture.root.join("Vault/vault.json"))
        .arg(&fixture.input)
        .output()
        .unwrap();
    assert!(reference.status.success());
    fixture.stop(&mut app);
    fixture.assert_diagnostics(id);
    assert!(!fixture.root.join("Sync").exists());
    println!(
        "Actual native secure creation from an initially unlocked editor still required fresh consent/authentication; OpenSSL authenticated the new seal, ordinary data stayed unchanged and the editor stayed locked."
    );
}

#[test]
#[ignore = "unlocked Omarchy; actual installed Release app/CLI on a private D-Bus/AT-SPI bus, public fixture only"]
fn live_installed_cli_secure_create_and_reveal() {
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
    let fixture = Fixture::new();
    let mut app = fixture.start(1);
    let before = fixture.images();
    for refusal in 0..5 {
        let mut cli = fixture.reveal(&fixture.keyword);
        fixture.wait_prompt(&app);
        if refusal == 0 {
            assert!(fixture.action(&app, "deny", None) == 0);
        } else {
            assert!(fixture.action(&app, "approve", None) == 0);
            assert!(fixture.action(&app, "input", Some("Wrong public control credential")) == 0);
            match refusal {
                1 => assert!(fixture.action(&app, "cancel", None) == 0),
                2 => assert!(fixture.action(&app, "authenticate", None) == 0),
                3 => {
                    let application = adw::Application::builder()
                        .application_id("com.khm.snippets.linux.ControlFocusFixture")
                        .flags(gio::ApplicationFlags::NON_UNIQUE)
                        .build();
                    application.register(None::<&gio::Cancellable>).unwrap();
                    let companion = adw::ApplicationWindow::builder()
                        .application(&application)
                        .title("Public CLI Focus Receiver")
                        .build();
                    companion.present();
                    until("owned focus receiver", 5, || companion.is_active());
                    fixture.finish(&app, &mut cli, 4, None);
                    assert!(companion.is_active());
                    companion.destroy();
                    settle(Duration::from_millis(150));
                }
                _ => {
                    cli.disconnect();
                    until("disconnected CLI prompt cleared", 5, || !prompt(app.id()));
                    drop(cli.output());
                }
            }
        }
        if refusal < 3 {
            fixture.finish(&app, &mut cli, if refusal == 2 { 5 } else { 4 }, None);
        }
        assert!(fixture.images() == before);
        fixture.status(1);
    }
    let mut limited = fixture.reveal(&fixture.keyword);
    fixture.finish(&app, &mut limited, 1, None);
    assert!(fixture.images() == before);
    println!(
        "Real native Deny, credential Cancel, wrong authentication, focus loss, disconnect and the unmodified five-per-minute limit refused disclosure."
    );
    fixture.stop(&mut app);

    let mut app = fixture.start(1);
    for recovery in [false, true] {
        let mut cli = fixture.reveal(&fixture.keyword);
        fixture.wait_prompt(&app);
        let credential = if recovery {
            crypto::format_recovery(&[0x66; 16])
        } else {
            Zeroizing::new(fixture.password.to_string())
        };
        fixture.approve(&app, &credential, recovery);
        fixture.finish(&app, &mut cli, 0, Some(&fixture.body));
        assert!(fixture.images() == before);
        fixture.status(1);
    }
    let mut cli = fixture.create();
    fixture.wait_prompt(&app);
    fixture.approve(&app, &fixture.password, false);
    until("secure creation receipt", 30, || {
        cli.0.as_mut().unwrap().try_wait().unwrap().is_some()
    });
    let output = cli.output();
    assert!(output.status.success() && output.stderr.is_empty());
    let receipt: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(
        receipt.as_object().unwrap().len() == 3
            && receipt["secure"] == true
            && receipt["keyword"] == "public-cli-created"
    );
    let id = uuid::Uuid::parse_str(receipt["id"].as_str().unwrap()).unwrap();
    assert!(!id.is_nil());
    until("creation prompt removed", 5, || !prompt(app.id()));
    fixture.status(2);
    let created = fixture.images();
    assert!(created.0 == before.0 && created.1 != before.1);
    let vault = Document::decode(created.1.as_ref().unwrap()).unwrap();
    assert!(vault.records.len() == 2);
    let record = vault.records.iter().find(|r| r.metadata.id == id).unwrap();
    assert!(record.metadata.keyword == "public-cli-created");
    assert!(
        !String::from_utf8_lossy(created.1.as_ref().unwrap()).contains("Public CLI creation body")
    );
    let reference = ProcessCommand::new("python3")
        .arg("-B")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/control-vault.py"))
        .arg(fixture.root.join("Vault/vault.json"))
        .arg(&fixture.input)
        .output()
        .unwrap();
    assert!(
        reference.status.success(),
        "OpenSSL must independently authenticate the actual CLI-created seal and content hash."
    );
    let mut cli = fixture.reveal("public-cli-created");
    fixture.wait_prompt(&app);
    fixture.approve(&app, &crypto::format_recovery(&[0x66; 16]), true);
    fixture.finish(&app, &mut cli, 0, Some(&fs::read(&fixture.input).unwrap()));
    fixture.status(2);
    assert!(fixture.images() == created);
    let mut duplicate = fixture.create();
    fixture.wait_prompt(&app);
    fixture.approve(&app, &fixture.password, false);
    fixture.finish(&app, &mut duplicate, 1, None);
    assert!(fixture.images() == created);
    println!(
        "Real fresh passphrase/recovery disclosure and native secure creation passed; OpenSSL verified the created seal, duplicate creation refused and the editor stayed locked."
    );
    fixture.stop(&mut app);

    let mut app = fixture.start(2);
    // A different installed image cannot borrow the verified server identity.
    let alien = fixture._directory.path().join("alien");
    fs::create_dir(&alien).unwrap();
    fs::copy(
        fixture.binaries.join("snippets-cli"),
        alien.join("snippets-cli"),
    )
    .unwrap();
    fs::write(alien.join("snippets"), b"Public untrusted image identity").unwrap();
    fs::set_permissions(alien.join("snippets"), fs::Permissions::from_mode(0o700)).unwrap();
    let refused = ProcessCommand::new(alien.join("snippets-cli"))
        .args(["reveal", &fixture.keyword])
        .env("XDG_DATA_HOME", fixture.root.parent().unwrap())
        .output()
        .unwrap();
    assert!(!refused.status.success() && refused.stdout.is_empty() && !prompt(app.id()));

    // Keep both production deadlines unchanged, and let the real mapped dialogs expire.
    let mut cli = fixture.reveal(&fixture.keyword);
    fixture.wait_prompt(&app);
    let started = Instant::now();
    fixture.finish_within(&app, &mut cli, 4, None, 40);
    assert!(started.elapsed() >= Duration::from_secs(28));
    assert!(fixture.images() == created);
    println!("The real unmodified 30-second native consent deadline refused disclosure.");

    let mut cli = fixture.reveal(&fixture.keyword);
    fixture.wait_prompt(&app);
    assert!(fixture.action(&app, "approve", None) == 0);
    assert!(fixture.action(&app, "input", Some(&fixture.password)) == 0);
    let started = Instant::now();
    fixture.finish_within(&app, &mut cli, 4, None, 70);
    assert!(started.elapsed() >= Duration::from_secs(58));
    assert!(fixture.images() == created);
    fixture.status(2);
    println!(
        "The real unmodified 60-second native credential deadline cleared the request without disclosure."
    );

    let mut cli = fixture.reveal(&fixture.keyword);
    fixture.wait_prompt(&app);
    assert!(fixture.action(&app, "approve", None) == 0);
    assert!(fixture.action(&app, "input", Some(&fixture.password)) == 0);
    let mut changed = Document::decode(created.1.as_ref().unwrap()).unwrap();
    changed.records[0].metadata.name = "Public concurrent metadata edit".into();
    model::atomic_write(
        &fixture.root.join("Vault/vault.json"),
        &changed.encode().unwrap(),
    )
    .unwrap();
    let edited = fixture.images();
    assert!(fixture.action(&app, "authenticate", None) == 0);
    fixture.finish(&app, &mut cli, 1, None);
    assert!(fixture.images() == edited);
    fixture.status(2);
    fixture.stop(&mut app);
    fixture.assert_diagnostics(id);
    assert!(!fixture.root.join("Sync").exists());
    println!(
        "Real executable mismatch and changed-source fences refused delivery; retained diagnostics contained no body, credential or created record ID."
    );
}
