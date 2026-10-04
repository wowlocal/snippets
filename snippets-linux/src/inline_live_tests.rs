use super::*;
use crate::{
    desktop::{PasteTarget, SessionMonitor},
    secure_insertion::{Backend, wayland::Native},
};
use gtk::glib;
use std::{
    process::{Child, Command, Stdio},
    time::Instant,
};

struct Receiver(Child);
impl Drop for Receiver {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}
#[track_caller]
fn settle_until(finished: impl Fn() -> bool) {
    let started = Instant::now();
    let context = glib::MainContext::default();
    while !finished() {
        assert!(
            started.elapsed() < Duration::from_secs(8),
            "live inline state timed out"
        );
        while context.pending() {
            context.iteration(false);
        }
        thread::sleep(Duration::from_millis(10));
    }
}
fn receiving_window(pid: u32) -> Option<PasteTarget> {
    let output = Command::new("hyprctl")
        .args(["-j", "clients"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let clients: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    clients
        .as_array()
        .unwrap()
        .iter()
        .find(|client| {
            client["title"].as_str() == Some("Snippets Smoke Paste Target")
                && client["pid"].as_u64() == Some(u64::from(pid))
        })
        .and_then(PasteTarget::from_window)
}
fn send_text(target: PasteTarget, witness: &SessionWitness, text: &str) {
    let checked = witness.snapshot();
    let guard = || {
        if checked.0 == SessionState::Unlocked
            && witness.snapshot() == checked
            && target.is_fresh()
            && target.is_active_unlocked()
        {
            Ok(())
        } else {
            Err(STOPPED)
        }
    };
    let mut scalars = Vec::new();
    for scalar in text.chars() {
        if !scalars.contains(&scalar) {
            scalars.push(scalar);
        }
    }
    let mut map = String::from("xkb_keymap { xkb_keycodes { minimum = 9; maximum = 255; ");
    for index in 0..scalars.len() {
        map.push_str(&format!("<K{index:03}> = {}; ", index + 9));
    }
    map.push_str("}; xkb_types { type \"ONE_LEVEL\" { modifiers = None; level_name[Level1] = \"Any\"; }; }; xkb_compatibility {}; xkb_symbols { ");
    for (index, scalar) in scalars.iter().enumerate() {
        map.push_str(&format!(
            "key <K{index:03}> {{ type = \"ONE_LEVEL\", [ 0x{:08x} ] }}; ",
            if *scalar == '\n' {
                0xff0d
            } else {
                *scalar as u32
            }
        ));
    }
    map.push_str("}; };\0");
    let mut native = Native::new(target.clone());
    native.begin(&guard).unwrap();
    native.install(map.as_bytes(), &guard).unwrap();
    for scalar in text.chars() {
        native
            .key(
                scalars.iter().position(|s| *s == scalar).unwrap() as u32 + 1,
                &guard,
            )
            .unwrap();
        // Let GTK publish confirmed text-input frames between public test keys.
        let context = glib::MainContext::default();
        while context.pending() {
            context.iteration(false);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

enum Mode {
    Exact,
    Suggestions,
    Echo,
}
fn exercise(mode: Mode) {
    assert!(
        crate::desktop::session_state() == SessionState::Unlocked,
        "Unlock the desktop before attempting live input."
    );
    adw::init().expect("graphical display");
    let directory = tempfile::tempdir().unwrap();
    let mut library = Library::prepare(directory.path().join("library")).unwrap();
    let content = if matches!(mode, Mode::Echo) {
        "\\nativeinline \\anotherinline"
    } else {
        "fictional snippet fictional clipboard fixture"
    };
    let mut snippet = Snippet::new("Public inline fixture", content);
    snippet.keyword = "nativeinline".into();
    library.save(snippet, None).unwrap();
    if matches!(mode, Mode::Echo) {
        let mut other = Snippet::new(
            "Public echo guard fixture",
            "Public forbidden recursive result",
        );
        other.keyword = "anotherinline".into();
        library.save(other, None).unwrap();
    }
    let before = fs::read(library.path()).unwrap();
    let receiver_binary = directory.path().join("paste-receiver");
    let receiver_result = directory.path().join("paste-result");
    let observation = directory.path().join("input-observation");
    let flags = Command::new("pkg-config")
        .args(["--cflags", "--libs", "gtk4"])
        .output()
        .unwrap();
    assert!(flags.status.success());
    assert!(
        Command::new("cc")
            .args(["-Wall", "-Wextra", "-Werror"])
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/paste-receiver.c"))
            .args(String::from_utf8(flags.stdout).unwrap().split_whitespace())
            .arg("-o")
            .arg(&receiver_binary)
            .status()
            .unwrap()
            .success()
    );
    let receiver = Receiver(
        Command::new(receiver_binary)
            .env("SNIPPETS_TEST_PASTE_RESULT", &receiver_result)
            .env("SNIPPETS_TEST_INPUT_OBSERVATION", &observation)
            .env(
                "SNIPPETS_TEST_RECEIVER_MODE",
                if matches!(mode, Mode::Echo) {
                    "echo-guard"
                } else {
                    "ordinary"
                },
            )
            .env("G_DEBUG", "fatal-warnings")
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    );
    settle_until(|| receiving_window(receiver.0.id()).is_some());
    let target = receiving_window(receiver.0.id()).unwrap();
    assert!(target.focus());
    let monitor = SessionMonitor::new().unwrap();
    settle_until(|| monitor.snapshot().0 == SessionState::Unlocked);
    Preference::write(&library.root, true).unwrap();
    if matches!(mode, Mode::Suggestions) {
        Preference::write_suggestions(&library.root, true).unwrap();
    }
    let handle = Handle::start(library.root.clone(), monitor.witness()).unwrap();
    settle_until(|| {
        let mut listening = false;
        while let Ok(status) = handle.receiver.try_recv() {
            assert!(
                status != Status::Unavailable,
                "Native inline method could not register."
            );
            listening |= status == Status::Listening;
        }
        listening
    });
    if matches!(mode, Mode::Suggestions) {
        send_text(target.clone(), &monitor.witness(), "\\nat");
        assert!(
            !receiver_result.exists(),
            "A partial suggestion was inserted without acceptance."
        );
        send_text(target, &monitor.witness(), "\n");
    } else {
        send_text(target, &monitor.witness(), "\\nativeinline");
    }
    settle_until(|| receiver_result.exists());
    // A confirmed replacement is a baseline even when it ends in another
    // exact keyword. Observe a quiet interval before revoking the listener.
    let started = Instant::now();
    while started.elapsed() < Duration::from_millis(750) {
        assert!(
            receiver_result.exists(),
            "The replacement echo caused another edit."
        );
        while let Ok(status) = handle.receiver.try_recv() {
            assert!(
                !matches!(status, Status::Stopped | Status::Unavailable),
                "Native inline delivery stopped before confirming its echo."
            );
        }
        thread::sleep(Duration::from_millis(10));
    }
    Preference::write(&library.root, false).unwrap();
    handle.stop();
    settle_until(|| handle.finished());
    let delivered = fs::read(receiver_result).ok().as_deref() == Some(b"matched\n");
    let unchanged = fs::read(library.path()).unwrap() == before;
    drop(receiver);
    assert!(
        delivered && unchanged,
        "Inline replacement did not reach the owned receiving field."
    );
    assert!(!library.root.join("Vault").exists() && !library.root.join("Sync").exists());
}

#[test]
#[ignore = "live Hyprland inline keyword replacement; private consent/library and a separate owned GTK target"]
fn live_inline_expansion() {
    exercise(Mode::Exact);
}

#[test]
#[ignore = "live Hyprland fuzzy suggestion acceptance with native Return and a separate owned GTK target"]
fn live_inline_suggestions() {
    exercise(Mode::Suggestions);
}

#[test]
#[ignore = "live Hyprland insertion echo must not expand a keyword introduced by the replacement"]
fn live_inline_echo_guard() {
    exercise(Mode::Echo);
}
