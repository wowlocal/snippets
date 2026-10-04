//! Real installed Release app and CLI, native consent and fresh credentials.
//! The wrapper owns a private bus/registry; all library/input material is public fiction.
use super::*;
use crate::{crypto, desktop, model, vault::Document};
use gtk::gio;
#[path = "control_lock_fixture.rs"]
mod lock_fixture;
#[path = "control_lock_live_tests.rs"]
mod session_lock;
#[path = "control_sleep_live_tests.rs"]
mod sleep;
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
        Self::build(true)
    }
    fn empty() -> Self {
        Self::build(false)
    }
    fn build(seeded: bool) -> Self {
        let directory = tempfile::Builder::new()
            .prefix("snippets-control-live.")
            .tempdir()
            .unwrap();
        let root = directory.path().join("data/snippets");
        let library = model::Library::open(root.clone()).unwrap();
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/crypto-v1.json")).unwrap();
        if seeded {
            fs::DirBuilder::new()
                .mode(0o700)
                .create(root.join("Vault"))
                .unwrap();
            model::atomic_write(
                &root.join("Vault/vault.json"),
                &serde_json::to_vec(&fixture["document"]).unwrap(),
            )
            .unwrap();
        }
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
        self.unlock_editor_with(app, count, &self.password);
    }
    fn open_editor(&self, app: &Process) {
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
    }
    fn unlock_editor_with(&self, app: &Process, count: usize, password: &str) {
        self.open_editor(app);
        self.status(count);
        assert!(self.action_in(app, "Secure Snippets", "editor-unlock", None) == 0);
        assert!(self.action_in(app, "Secure Snippets", "input", Some(password)) == 0);
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
            if mode == "editor-body" && code != 0 {
                println!(
                    "Protected body state: status={code}, {}",
                    String::from_utf8_lossy(&output.stdout)
                );
            }
            // GtkButton::activate animates for 250 ms before emitting clicked.
            // Do not inspect focus, issue keys or assert cancellation before it runs.
            if !matches!(
                mode,
                "editor-change-start"
                    | "editor-authenticate-start"
                    | "setup-submit-start"
                    | "pw-busy"
                    | "auth-busy"
                    | "editor-idle"
                    | "input-empty"
                    | "pw-current-empty"
                    | "pw-new-empty"
                    | "pw-confirm-empty"
                    | "pw-recovery"
                    | "pw-recovery-selected"
                    | "setup-idle"
                    | "setup-passphrase-empty"
                    | "setup-confirm-empty"
                    | "recovery-focused"
                    | "sheet-hidden"
                    | "sheet-recorded"
                    | "sheet-recorded-selected"
            ) {
                settle(Duration::from_millis(350));
            }
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
        self.key_in(app, "Snippets CLI Request", "", key);
    }
    fn key_in(&self, app: &Process, title: &str, mods: &str, key: &str) {
        assert!(matches!(title, "Snippets CLI Request" | "Secure Snippets"));
        assert!(matches!(mods, "" | "SHIFT" | "CTRL" | "CTRL SHIFT"));
        assert!(
            matches!(key, "tab" | "space" | "return" | "backspace" | "escape")
                || key.len() == 1 && key.bytes().all(|v| v.is_ascii_alphanumeric())
        );
        let window = query("activewindow");
        assert!(
            active_window(app.id(), title) && desktop::session_state() == SessionState::Unlocked
        );
        let address = window["address"].as_str().unwrap();
        assert!(address.starts_with("0x") && address[2..].bytes().all(|c| c.is_ascii_hexdigit()));
        let fields = format!("mods = \"{mods}\", key = \"{key}\", window = \"address:{address}\"");
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
    #[track_caller]
    fn reference_editor(&self, expected: &str, password: &str) {
        self.reference_vault(expected.as_bytes(), password, "editor");
    }
    #[track_caller]
    fn reference_vault(&self, expected: &[u8], password: &str, mode: &str) {
        assert!(matches!(mode, "editor" | "recovery"));
        model::atomic_write(&self.input, expected).unwrap();
        let mut child = ProcessCommand::new("python3")
            .arg("-B")
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/control-vault.py"))
            .arg(self.root.join("Vault/vault.json"))
            .arg(&self.input)
            .arg(mode)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(password.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success() && output.stderr.is_empty(),
            "OpenSSL must authenticate the actual editor-created seal, hash and passphrase wrap; static result={}",
            String::from_utf8_lossy(&output.stdout)
        );
    }
    fn displayed_recovery(&self, app: &Process) -> Option<Zeroizing<String>> {
        assert!(desktop::session_state() == SessionState::Unlocked);
        let before = query("activewindow");
        assert!(active_window(app.id(), "Secure Snippets"));
        let region = ProcessCommand::new(&self.actor)
            .arg("recovery-region")
            .env("SNIPPETS_CONTROL_TEST_PID", app.id().to_string())
            .env("SNIPPETS_CONTROL_TEST_WINDOW", "Secure Snippets")
            .output()
            .unwrap();
        assert!(region.status.success() && region.stderr.is_empty());
        let line = std::str::from_utf8(&region.stdout)
            .unwrap()
            .lines()
            .find_map(|v| v.strip_prefix("recovery_bounds="))
            .unwrap();
        let rect: Vec<i64> = line.split(',').map(|v| v.parse().unwrap()).collect();
        assert!(rect.len() == 4);
        assert!(rect[3] >= 104);
        let x = before["at"][0].as_i64().unwrap();
        let y = before["at"][1].as_i64().unwrap();
        let width = before["size"][0].as_i64().unwrap();
        let height = before["size"][1].as_i64().unwrap();
        let root_rect: Vec<i64> = std::str::from_utf8(&region.stdout)
            .unwrap()
            .lines()
            .find_map(|v| v.strip_prefix("recovery_window_bounds="))
            .unwrap()
            .split(',')
            .map(|v| v.parse().unwrap())
            .collect();
        assert!(root_rect == [0, 0, width, height]);
        assert!(rect[0] + rect[2] <= width && rect[1] + rect[3] <= height);
        // Only the owned protected field, inset past its border; no desktop,
        // clipboard, image file or OCR output is retained or printed.
        let geometry = format!(
            "{},{} {}x{}",
            x + rect[0] + 4,
            y + rect[1] + 4,
            rect[2] - 8,
            104
        );
        let capture = ProcessCommand::new("grim")
            .args(["-g", &geometry, "-s", "3", "-t", "ppm", "-"])
            .output()
            .unwrap();
        assert!(capture.status.success() && capture.stderr.is_empty());
        let pixels = Zeroizing::new(capture.stdout);
        assert!(pixels.len() < 16 * 1024 * 1024);
        let after = query("activewindow");
        assert!(
            before["address"] == after["address"]
                && before["at"] == after["at"]
                && before["size"] == after["size"]
                && active_window(app.id(), "Secure Snippets")
                && desktop::session_state() == SessionState::Unlocked
        );
        for (segmentation, alphabet) in [("6", false), ("11", false), ("6", true), ("11", true)] {
            let mut command = ProcessCommand::new("tesseract");
            command.args([
                "stdin",
                "stdout",
                "--psm",
                segmentation,
                "-c",
                "load_system_dawg=0",
                "-c",
                "load_freq_dawg=0",
            ]);
            if alphabet {
                command.args([
                    "-c",
                    "tessedit_char_whitelist=0123456789ABCDEFGHJKMNPQRSTVWXYZILO-",
                ]);
            }
            let mut reader = command
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            reader.stdin.take().unwrap().write_all(&pixels).unwrap();
            let output = reader.wait_with_output().unwrap();
            assert!(output.status.success());
            let bytes = Zeroizing::new(output.stdout);
            let text = Zeroizing::new(std::str::from_utf8(&bytes).unwrap().trim().to_owned());
            // Both wrapped glyph rows must fit in this bounded field crop.
            // No guessed/corrected symbols: checksum and independent unwrap follow.
            let lines: Vec<_> = text
                .lines()
                .filter(|line| !line.trim().is_empty())
                .collect();
            for start in 0..lines.len() {
                for count in 1..=3 {
                    let candidate = Zeroizing::new(
                        lines
                            .iter()
                            .skip(start)
                            .take(count)
                            .copied()
                            .collect::<Vec<_>>()
                            .join("\n"),
                    );
                    if crypto::decode_recovery(&candidate).is_ok() {
                        return Some(candidate);
                    }
                }
            }
            if crypto::decode_recovery(&text).is_ok() {
                return Some(text);
            } else {
                println!(
                    "Bounded recovery OCR did not yield a valid key: characters={}, lines={}, field={}x{}, raster_bytes={}, placeholder={}, reveal_label={}, recorded_label={}, origin={},{}.",
                    text.chars().count(),
                    text.lines().count(),
                    rect[2],
                    rect[3],
                    pixels.len(),
                    text.contains("Content hidden"),
                    text.contains("Reveal Recovery"),
                    text.contains("recorded"),
                    rect[0],
                    rect[1]
                );
            }
        }
        None
    }
    fn reference_setup(&self, recovery: &str, expected: Option<&str>) {
        let request = Zeroizing::new(
            serde_json::to_vec(&serde_json::json!({
                "passphrase": &*self.password, "recovery": recovery, "body": expected
            }))
            .unwrap(),
        );
        let mut child = ProcessCommand::new("python3")
            .arg("-B")
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/setup-vault.py"))
            .arg(self.root.join("Vault/vault.json"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&request).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success() && output.stderr.is_empty(),
            "OpenSSL must independently authenticate setup's displayed recovery key, passphrase root and first record."
        );
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
            "Unexpected real CLI outcome: expected={code}, actual={:?}, stdout_empty={}.",
            output.status.code(),
            output.stdout.is_empty()
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
        self.assert_diagnostics_extra(id, &[]);
    }
    fn assert_diagnostics_extra(&self, id: uuid::Uuid, extra: &[&str]) {
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
                check(&event, extra);
            }
        }
        assert!(retained_events > 0);
    }
}

#[test]
#[ignore = "unlocked Omarchy; actual installed Release setup, bounded owned-field OCR, public private-root fixture only"]
fn live_installed_secure_setup_and_recovery_sheet() {
    assert!(
        std::env::var_os("SNIPPETS_CONTROL_LIVE").as_deref()
            == Some(std::ffi::OsStr::new("public-private-roots"))
    );
    assert!(
        std::env::var_os("DBUS_SESSION_BUS_ADDRESS")
            != std::env::var_os("SNIPPETS_CONTROL_HOST_BUS")
    );
    assert!(desktop::session_state() == SessionState::Unlocked);
    let fixture = Fixture::empty();
    let mut app = fixture.start(0);
    let original = fixture.images();
    assert!(original.1.is_none());
    fixture.open_editor(&app);
    let action = |mode, value: Option<&str>| {
        assert!(
            fixture.action_in(&app, "Secure Snippets", mode, value) == 0,
            "Native setup action {mode} must succeed."
        );
    };
    let focus_application = adw::Application::builder()
        .application_id("com.khm.snippets.linux.ControlFocusFixture")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    focus_application
        .register(None::<&gio::Cancellable>)
        .unwrap();
    let focus_cycle = || {
        let companion = adw::ApplicationWindow::builder()
            .application(&focus_application)
            .title("Public CLI Focus Receiver")
            .build();
        companion.present();
        until("independent setup focus receiver", 5, || {
            companion.is_active() && !active_window(app.id(), "Secure Snippets")
        });
        settle(Duration::from_millis(200));
        companion.destroy();
        until("owned setup regained actual focus", 5, || {
            active_window(app.id(), "Secure Snippets")
        });
    };
    let setup = |password: &str, confirmation: &str| {
        action("setup-open", None);
        action("setup-passphrase-empty", None);
        action("setup-confirm-empty", None);
        action("setup-passphrase", Some(password));
        action("setup-confirm", Some(confirmation));
    };
    let unpublished = || {
        until("setup work completed without publication", 30, || {
            fixture.action_in(&app, "Secure Snippets", "setup-idle", None) == 0
        });
        fixture.status(0);
        assert!(fixture.images() == original);
    };
    for variant in 0..5 {
        setup(
            if variant == 1 {
                "short"
            } else {
                &fixture.password
            },
            if variant == 1 {
                "short"
            } else if variant == 2 {
                "Public mismatched setup passphrase"
            } else {
                &fixture.password
            },
        );
        if variant == 3 {
            focus_cycle();
        }
        if variant == 4 {
            fixture.key_in(&app, "Secure Snippets", "CTRL", "l");
        }
        action(
            if variant == 0 {
                "cancel"
            } else {
                "setup-submit"
            },
            None,
        );
        unpublished();
    }
    setup(&fixture.password, &fixture.password);
    action("setup-submit-start", None);
    action("auth-busy", None);
    focus_cycle();
    unpublished();
    println!(
        "Actual setup Cancel, short/mismatched credentials, pending focus/Lock and observed worker focus revocation left vault absent."
    );
    setup(&fixture.password, &fixture.password);
    action("setup-submit", None);
    until("setup published the empty encrypted vault", 30, || {
        fixture.state(0)
    });
    assert!(fixture.action_in(&app, "Secure Snippets", "sheet-continue", None) == 6);
    action("sheet-hidden", None);
    assert!(fixture.displayed_recovery(&app).is_none());
    action("sheet-reveal", None);
    if fixture.action_in(&app, "Secure Snippets", "recovery-focused", None) == 0 {
        fixture.key_in(&app, "Secure Snippets", "SHIFT", "tab");
        println!("Moved native focus off the read-only recovery field before transcription.");
    }
    let recovery = fixture
        .displayed_recovery(&app)
        .expect("The actual displayed setup key must be readable and have a valid checksum.");
    fixture.reference_setup(&recovery, None);
    println!(
        "Actual rendered setup key passed its checksum and independent OpenSSL passphrase/recovery-root equality."
    );
    for _ in 0..16 {
        if fixture.action_in(&app, "Secure Snippets", "recovery-focused", None) == 0 {
            break;
        }
        fixture.key_in(&app, "Secure Snippets", "", "tab");
    }
    action("recovery-focused", None);
    fixture.key_in(&app, "Secure Snippets", "", "escape");
    let escape_hidden = fixture.action_in(&app, "Secure Snippets", "sheet-hidden", None);
    assert!(fixture.displayed_recovery(&app).is_none());
    fixture.key_in(&app, "Secure Snippets", "SHIFT", "tab");
    let focus_left = fixture.action_in(&app, "Secure Snippets", "recovery-focused", None);
    action("sheet-reveal", None);
    let first_click_shown = fixture.displayed_recovery(&app).is_some();
    println!(
        "Native recovery-sheet observation: escape_toggle_hidden={}, hidden_shift_tab_left={}, first_reveal_click_visible={}.",
        escape_hidden == 0,
        focus_left == 11,
        first_click_shown
    );
    assert!(
        escape_hidden == 0 && focus_left == 11 && first_click_shown,
        "Escape must clear the native recovery toggle; Shift+Tab must leave the hidden field; one click must reveal again."
    );
    let shown = fixture
        .displayed_recovery(&app)
        .expect("A single native click after Escape must show the same valid recovery key.");
    assert!(
        *crypto::decode_recovery(&shown).unwrap() == *crypto::decode_recovery(&recovery).unwrap()
    );
    drop(shown);
    focus_cycle();
    action("sheet-hidden", None);
    assert!(fixture.displayed_recovery(&app).is_none());
    action("sheet-reveal", None);
    fixture.key_in(&app, "Secure Snippets", "CTRL", "l");
    settle(Duration::from_millis(600));
    fixture.status(0);
    action("sheet-hidden", None);
    assert!(fixture.displayed_recovery(&app).is_none());
    if fixture.action_in(&app, "Secure Snippets", "recovery-focused", None) == 0 {
        fixture.key_in(&app, "Secure Snippets", "SHIFT", "tab");
    }
    // Outside the protected field, Escape invokes the dialog's native close
    // response. Inside the field the same key only hides its content.
    fixture.key_in(&app, "Secure Snippets", "", "escape");
    action("editor-recovery", None);
    action("input", Some(&recovery));
    action("editor-authenticate", None);
    until("actual displayed setup recovery key unlocks", 30, || {
        fixture.state(0)
    });
    fixture.key_in(&app, "Secure Snippets", "CTRL", "n");
    for (mode, value) in [
        ("editor-name", "Public setup created entry"),
        ("editor-keyword", "public-setup-created"),
        ("editor-tags", "Public, Setup"),
    ] {
        action(mode, Some(value));
    }
    action("editor-reveal", None);
    action("editor-body", None);
    let body = "publicsetupbody";
    for c in body.chars() {
        fixture.key_in(&app, "Secure Snippets", "", &c.to_string());
    }
    fixture.key_in(&app, "Secure Snippets", "CTRL", "s");
    fixture.status_state(1, true);
    fixture.reference_setup(&recovery, Some(body));
    let document = Document::decode(fixture.images().1.as_ref().unwrap()).unwrap();
    let record = &document.records[0];
    assert!(record.metadata.keyword == "public-setup-created");
    assert!(fixture.images().0 == original.0);
    assert!(
        fs::metadata(fixture.root.join("Vault/vault.json"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777
            == 0o600
    );
    fixture.assert_diagnostics_extra(
        record.metadata.id,
        &[&recovery, body, "Public setup created entry"],
    );
    assert!(!fixture.root.join("Sync").exists());
    fixture.stop(&mut app);
    // A separate truly empty installation also exercises the affirmative
    // recording gate and the exact minimum-length passphrase through real fields.
    let mut minimum = Fixture::empty();
    minimum.password = Zeroizing::new("publicvault1".to_owned());
    assert!(minimum.password.chars().count() == 12);
    let mut app = minimum.start(0);
    minimum.open_editor(&app);
    let action = |mode, value: Option<&str>| {
        assert!(
            minimum.action_in(&app, "Secure Snippets", mode, value) == 0,
            "Native minimum-length setup action {mode} must succeed."
        );
    };
    action("setup-open", None);
    action("setup-passphrase", Some(&minimum.password));
    action("setup-confirm", Some(&minimum.password));
    action("setup-submit", None);
    until("minimum-length native setup unlocked", 30, || {
        minimum.state(0)
    });
    assert!(minimum.action_in(&app, "Secure Snippets", "sheet-continue", None) == 6);
    for _ in 0..16 {
        if minimum.action_in(&app, "Secure Snippets", "sheet-recorded", None) == 0 {
            break;
        }
        minimum.key_in(&app, "Secure Snippets", "", "tab");
    }
    action("sheet-recorded", None);
    minimum.key_in(&app, "Secure Snippets", "", "space");
    action("sheet-recorded-selected", None);
    action("sheet-continue", None);
    minimum.status_state(0, true);
    let published = minimum.images();
    action("editor-lock", None);
    minimum.status(0);
    minimum.unlock_editor_with(&app, 0, &minimum.password);
    assert!(minimum.images() == published);
    assert!(
        fs::metadata(minimum.root.join("Vault"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777
            == 0o700
    );
    minimum.assert_diagnostics_extra(uuid::Uuid::nil(), &[]);
    assert!(!minimum.root.join("Sync").exists());
    minimum.stop(&mut app);
    println!(
        "Actual new-vault setup, recovery pixels/checksum, native Close and affirmative Continue, exact minimum passphrase, Escape/focus/Lock hiding, fresh recovery unlock and first encrypted save passed with independent OpenSSL and privacy checks."
    );
}

#[test]
#[ignore = "unlocked Omarchy; actual installed Release recovery/credential dialogs, public private-root fixture only"]
fn live_installed_secure_recovery_and_revocation() {
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
    let original = fixture.images();
    let recovery = crypto::format_recovery(&[0x66; 16]);
    let wrong_recovery = crypto::format_recovery(&[0x67; 16]);
    let new_password = Zeroizing::new("Public recovery changed passphrase".to_owned());
    fixture.open_editor(&app);
    let action = |mode, value: Option<&str>| {
        assert!(fixture.action_in(&app, "Secure Snippets", mode, value) == 0);
    };
    let await_locked = || {
        assert!(
            !fixture.state(1),
            "Native rejected/cancelled credential work must leave the editor locked."
        );
        until("native credential worker finished while locked", 30, || {
            fixture.action_in(&app, "Secure Snippets", "editor-idle", None) == 0
        });
        fixture.status(1);
    };
    let focus_application = adw::Application::builder()
        .application_id("com.khm.snippets.linux.ControlFocusFixture")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    focus_application
        .register(None::<&gio::Cancellable>)
        .unwrap();
    let focus_cycle = || {
        let companion = adw::ApplicationWindow::builder()
            .application(&focus_application)
            .title("Public CLI Focus Receiver")
            .build();
        companion.present();
        until(
            "independent owned window took secure-editor focus",
            5,
            || companion.is_active() && !active_window(app.id(), "Secure Snippets"),
        );
        settle(Duration::from_millis(200));
        companion.destroy();
        until(
            "owned secure dialog regained actual compositor focus",
            5,
            || active_window(app.id(), "Secure Snippets"),
        );
    };
    // Cancellation and a structurally valid wrong recovery key must never unlock.
    for cancelled in [true, false] {
        println!("Native recovery refusal: cancelled={cancelled}.");
        action("editor-recovery", None);
        action("input-empty", None);
        action(
            "input",
            Some(if cancelled {
                &recovery
            } else {
                &wrong_recovery
            }),
        );
        action(
            if cancelled {
                "cancel"
            } else {
                "editor-authenticate"
            },
            None,
        );
        await_locked();
        assert!(fixture.images() == original);
    }
    // Actual loss of focus and an actual Lock key each revoke the pending prompt.
    for lose_focus in [true, false] {
        println!("Native pending recovery revocation: focus_loss={lose_focus}.");
        action("editor-recovery", None);
        action("input-empty", None);
        action("input", Some(&recovery));
        if lose_focus {
            focus_cycle();
        } else {
            fixture.key_in(&app, "Secure Snippets", "CTRL", "l");
        }
        action("editor-authenticate", None);
        await_locked();
        assert!(fixture.images() == original);
    }
    // Observe a real passphrase derivation and revoke it with actual focus loss.
    action("editor-unlock", None);
    action("input-empty", None);
    action("input", Some(&fixture.password));
    action("editor-authenticate-start", None);
    action("auth-busy", None);
    focus_cycle();
    await_locked();
    assert!(fixture.images() == original);
    action("editor-recovery", None);
    action("input-empty", None);
    action("input", Some(&recovery));
    action("editor-authenticate", None);
    until(
        "fresh native recovery credential unlocked the editor",
        30,
        || fixture.state(1),
    );
    assert!(fixture.images() == original);
    action("editor-lock", None);
    await_locked();
    println!(
        "Actual native recovery Cancel/wrong-key refusal, focus/Lock revocation, observed passphrase-derivation focus revocation and fresh recovery unlock passed without primary writes."
    );

    let change_prompt = |key: &str, confirmation: &str| {
        action("editor-passphrase", None);
        for mode in ["pw-current-empty", "pw-new-empty", "pw-confirm-empty"] {
            action(mode, None);
        }
        for _ in 0..16 {
            if fixture.action_in(&app, "Secure Snippets", "pw-recovery", None) == 0 {
                break;
            }
            fixture.key_in(&app, "Secure Snippets", "", "tab");
        }
        action("pw-recovery", None);
        fixture.key_in(&app, "Secure Snippets", "", "space");
        action("pw-recovery-selected", None);
        for (mode, value) in [
            ("pw-current", key),
            ("pw-new", &*new_password),
            ("pw-confirm", confirmation),
        ] {
            action(mode, Some(value));
        }
    };
    // Native cancellation, wrong key and mismatched confirmation preserve the vault.
    for refusal in 0..3 {
        change_prompt(
            if refusal == 1 {
                &wrong_recovery
            } else {
                &recovery
            },
            if refusal == 2 {
                "Public mismatched confirmation"
            } else {
                &new_password
            },
        );
        action(
            if refusal == 0 {
                "cancel"
            } else {
                "editor-change"
            },
            None,
        );
        await_locked();
        assert!(fixture.images() == original);
    }
    // A focus lapse before submission invalidates even correct native fields.
    change_prompt(&recovery, &new_password);
    focus_cycle();
    action("editor-change", None);
    await_locked();
    assert!(fixture.images() == original);
    // Observe the real native work label before revoking the running derivation.
    change_prompt(&recovery, &new_password);
    action("editor-change-start", None);
    action("pw-busy", None);
    assert!(fixture.images() == original);
    focus_cycle();
    await_locked();
    assert!(fixture.images() == original);
    println!(
        "Actual recovery-based passphrase Cancel/wrong-key/mismatch refusal and focus revocation before submission and during observed native derivation passed."
    );

    change_prompt(&recovery, &new_password);
    action("editor-change", None);
    until("native recovery-based passphrase publication", 30, || {
        fixture.images().1 != original.1
    });
    fixture.status_state(1, true);
    fixture.reference_vault(&fixture.body, &new_password, "recovery");
    let changed = fixture.images();
    let before = Document::decode(original.1.as_ref().unwrap()).unwrap();
    let after = Document::decode(changed.1.as_ref().unwrap()).unwrap();
    assert!(
        before.records == after.records
            && before.wrap_recovery == after.wrap_recovery
            && before.vault_salt == after.vault_salt
            && before.wrap_pass != after.wrap_pass
            && before.kdf != after.kdf
            && changed.0 == original.0
    );
    action("editor-lock", None);
    await_locked();
    action("editor-unlock", None);
    action("input-empty", None);
    action("input", Some(&fixture.password));
    action("editor-authenticate", None);
    await_locked();
    assert!(fixture.images() == changed);
    fixture.unlock_editor_with(&app, 1, &new_password);
    action("editor-lock", None);
    await_locked();
    action("editor-recovery", None);
    action("input-empty", None);
    action("input", Some(&recovery));
    action("editor-authenticate", None);
    until(
        "unchanged recovery door still unlocks after passphrase change",
        30,
        || fixture.state(1),
    );
    assert!(fixture.images() == changed);
    fixture.stop(&mut app);
    fixture.assert_diagnostics_extra(
        before.records[0].metadata.id,
        &[
            &recovery,
            &wrong_recovery,
            &new_password,
            "Public mismatched confirmation",
        ],
    );
    assert!(!fixture.root.join("Sync").exists());
    println!(
        "Actual recovery-based passphrase change, preserved records/recovery wrap, independent OpenSSL body/hash/new wrap, old/new password and continued recovery admission passed; diagnostics contain no credentials or bodies."
    );
}

#[test]
#[ignore = "unlocked Omarchy; actual installed Release secure editor, public private-root fixture only"]
fn live_installed_secure_editor_edit_and_passphrase() {
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
    let original = fixture.images();
    fixture.unlock_editor(&app, 1);
    fixture.key_in(&app, "Secure Snippets", "CTRL", "n");
    for (mode, value) in [
        ("editor-name", "Public editor created entry"),
        ("editor-keyword", "public-editor-created"),
        ("editor-tags", "Public, Editor"),
    ] {
        assert!(fixture.action_in(&app, "Secure Snippets", mode, Some(value)) == 0);
    }
    assert!(
        fixture.images() == original,
        "An unsaved encrypted draft must not publish a record."
    );
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-reveal", None) == 0);
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-body", None) == 0);
    let expected = "public\tbody\ntext";
    for character in expected.chars() {
        let key = match character {
            '\t' => "tab".into(),
            '\n' => "return".into(),
            value => value.to_string(),
        };
        fixture.key_in(&app, "Secure Snippets", "", &key);
    }
    fixture.key_in(&app, "Secure Snippets", "CTRL", "s");
    fixture.status_state(2, true);
    fixture.reference_editor(expected, &fixture.password);
    let document = Document::decode(fixture.images().1.as_ref().unwrap()).unwrap();
    let record = document
        .records
        .iter()
        .find(|r| r.metadata.keyword == "public-editor-created")
        .unwrap();
    let id = record.metadata.id;
    assert!(
        record.metadata.name == "Public editor created entry"
            && record.metadata.tags == ["Public", "Editor"]
    );
    assert!(fixture.images().0 == original.0);

    fixture.key_in(&app, "Secure Snippets", "", "backspace");
    fixture.key_in(&app, "Secure Snippets", "CTRL", "s");
    fixture.reference_editor("public\tbody\ntex", &fixture.password);
    for (mode, body) in [
        ("editor-undo", expected),
        ("editor-redo", "public\tbody\ntex"),
        ("editor-undo", expected),
    ] {
        assert!(fixture.action_in(&app, "Secure Snippets", mode, None) == 0);
        fixture.key_in(&app, "Secure Snippets", "CTRL", "s");
        fixture.reference_editor(body, &fixture.password);
    }
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-body", None) == 0);
    fixture.key_in(&app, "Secure Snippets", "", "escape");
    fixture.key_in(&app, "Secure Snippets", "", "z");
    fixture.key_in(&app, "Secure Snippets", "CTRL", "s");
    fixture.reference_editor(expected, &fixture.password);
    // One click must reveal again after Escape; typing then proves actual body input.
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-reveal", None) == 0);
    fixture.key_in(&app, "Secure Snippets", "", "z");
    fixture.key_in(&app, "Secure Snippets", "CTRL", "s");
    fixture.reference_editor("public\tbody\ntextz", &fixture.password);
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-undo", None) == 0);
    fixture.key_in(&app, "Secure Snippets", "CTRL", "s");
    fixture.reference_editor(expected, &fixture.password);
    println!(
        "Actual protected native keyboard input, saved metadata, OpenSSL-authenticated body/hash, Undo/Redo and Escape/reveal passed without an accessible text interface."
    );

    let before_change = fixture.images();
    let new_password = Zeroizing::new("Public changed vault passphrase".to_owned());
    for confirm in [false, true] {
        assert!(fixture.action_in(&app, "Secure Snippets", "editor-passphrase", None) == 0);
        for (mode, value) in [
            ("pw-current", &*fixture.password),
            ("pw-new", &*new_password),
            ("pw-confirm", &*new_password),
        ] {
            assert!(fixture.action_in(&app, "Secure Snippets", mode, Some(value)) == 0);
        }
        assert!(
            fixture.action_in(
                &app,
                "Secure Snippets",
                if confirm { "editor-change" } else { "cancel" },
                None
            ) == 0
        );
        if confirm {
            until("actual native passphrase publication", 30, || {
                fixture.images().1 != before_change.1
            });
        } else {
            assert!(fixture.images() == before_change);
        }
    }
    fixture.reference_editor(expected, &new_password);
    let after_change = fixture.images();
    let before_doc = Document::decode(before_change.1.as_ref().unwrap()).unwrap();
    let after_doc = Document::decode(after_change.1.as_ref().unwrap()).unwrap();
    assert!(
        before_doc.records == after_doc.records
            && before_doc.wrap_recovery == after_doc.wrap_recovery
            && before_doc.vault_salt == after_doc.vault_salt
            && before_doc.wrap_pass != after_doc.wrap_pass
            && before_doc.kdf != after_doc.kdf
            && after_change.0 == original.0
    );
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-lock", None) == 0);
    fixture.status(2);
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-unlock", None) == 0);
    assert!(fixture.action_in(&app, "Secure Snippets", "input", Some(&fixture.password)) == 0);
    assert!(fixture.action_in(&app, "Secure Snippets", "editor-authenticate", None) == 0);
    settle(Duration::from_secs(2));
    fixture.status(2);
    assert!(fixture.images() == after_change);
    fixture.unlock_editor_with(&app, 2, &new_password);
    fixture.reference_editor(expected, &new_password);
    fixture.stop(&mut app);
    fixture.assert_diagnostics_extra(
        id,
        &[expected, &new_password, "Public editor created entry"],
    );
    assert!(!fixture.root.join("Sync").exists());
    println!(
        "Actual native passphrase cancellation/change, preserved secure seals/recovery door, explicit lock, old-password refusal and new-password unlock passed with independent OpenSSL verification."
    );
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
