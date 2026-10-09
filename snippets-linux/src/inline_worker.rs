//! One background owner per enabled library; no host text crosses to GTK.
use super::*;
use crate::desktop::{SessionState, SessionWitness};
#[cfg(any(test, feature = "fcitx"))]
use std::path::Path;
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, SystemTime},
};

const STOPPED: Error = Error("Inline expansion stopped. Check the text field before trying again.");
const CLIPBOARD: Error =
    Error("The clipboard placeholder could not be read safely within its size and time limits.");
#[cfg(feature = "fcitx")]
#[path = "inline_fcitx.rs"]
mod fcitx;
#[cfg(test)]
#[path = "inline_live_tests.rs"]
mod live_tests;
#[path = "inline_selection_worker.rs"]
mod selection;
pub(crate) use crate::inline_settings::Preference;

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{fs::PermissionsExt, fs::symlink};
    #[test]
    fn absent_or_disabled_preference_starts_no_worker_and_creates_no_file() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().join("Public absent library");
        assert!(!Preference::read(&root).unwrap().enabled);
        let witness = SessionWitness::test(SessionState::Unlocked, 1);
        assert!(Handle::start(root.clone(), witness.clone()).is_err());
        assert!(!root.exists());
        let library = Library::prepare(root).unwrap();
        Preference::write(&library.root, false).unwrap();
        assert!(Handle::start(library.root.clone(), witness).is_err());
        assert!(!library.path().exists());
        assert_eq!(
            fs::metadata(library.root.join("inline-expansion.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn preference_rejects_unknown_fields_versions_oversize_and_linked_sources() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        let path = root.join("inline-expansion.json");
        for bytes in [
            br#"{"schema":2,"enabled":true}"#.to_vec(),
            br#"{"schema":1,"enabled":true,"extra":0}"#.to_vec(),
            br#"{"schema":1,"enabled":"true"}"#.to_vec(),
            vec![b' '; 1025],
        ] {
            fs::write(&path, bytes).unwrap();
            assert!(Preference::read(root).is_err());
        }
        fs::remove_file(&path).unwrap();
        let outside = root.join("Public linked preference");
        fs::write(&outside, br#"{"schema":1,"enabled":true}"#).unwrap();
        symlink(&outside, &path).unwrap();
        assert!(Preference::read(root).is_err());
        fs::remove_file(&path).unwrap();
        fs::hard_link(&outside, &path).unwrap();
        assert!(Preference::read(root).is_err());
    }
    #[test]
    fn legacy_exact_only_consent_never_enables_keyboard_suggestions() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        fs::write(
            root.join("inline-expansion.json"),
            br#"{"schema":1,"enabled":true}"#,
        )
        .unwrap();
        let old = Preference::read(root).unwrap();
        assert!(old.enabled && !old.suggestions);
        Preference::write_suggestions(root, true).unwrap();
        assert!(Preference::read(root).unwrap().suggestions);
        Preference::write(root, false).unwrap();
        let disabled = Preference::read(root).unwrap();
        assert!(!disabled.enabled && disabled.suggestions);
        Preference::write_suggestions(root, false).unwrap();
        assert!(!Preference::read(root).unwrap().suggestions);
    }
    #[test]
    fn explicit_new_consent_enables_the_panel_without_migrating_legacy_consent() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        assert!(!Preference::read(root).unwrap().enabled);
        Preference::enable_with_suggestions(root).unwrap();
        let enabled = Preference::read(root).unwrap();
        assert!(enabled.enabled && enabled.suggestions);
        Preference::write(root, false).unwrap();
        assert!(!Preference::read(root).unwrap().enabled);
    }
    #[test]
    fn locked_worker_never_connects_and_explicit_stop_or_revocation_joins() {
        let expected = if crate::desktop::environment() == crate::desktop::Environment::Gnome {
            Status::UnsupportedDesktop
        } else {
            Status::WaitingForUnlock
        };
        for explicit in [true, false] {
            let temporary = tempfile::tempdir().unwrap();
            let library = Library::prepare(temporary.path().join("Public library")).unwrap();
            Preference::write(&library.root, true).unwrap();
            let witness = SessionWitness::test(SessionState::Locked, 1);
            let handle = Handle::start(library.root.clone(), witness).unwrap();
            assert!(
                handle
                    .receiver
                    .recv_timeout(Duration::from_secs(2))
                    .unwrap()
                    == expected
            );
            if explicit {
                handle.stop();
            } else {
                Preference::write(&library.root, false).unwrap();
            }
            let start = std::time::Instant::now();
            while !handle.finished() {
                assert!(start.elapsed() < Duration::from_secs(2));
                thread::sleep(Duration::from_millis(5));
            }
            assert!(!library.path().exists());
            assert!(handle.receiver.try_iter().all(|status| status == expected));
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Status {
    WaitingForUnlock,
    WaitingForField,
    Listening,
    Stopped,
    Unavailable,
    #[cfg(feature = "fcitx")]
    WaitingForFcitx,
    UnsupportedDesktop,
}
impl Status {
    pub fn text(self) -> &'static str {
        match self {
            Self::WaitingForUnlock => "Enabled; waiting for an observable unlocked desktop.",
            Self::WaitingForField => "Enabled; waiting for a compatible text field.",
            Self::Listening => "Expanding enabled ordinary keywords in this text field.",
            Self::Stopped => "Expansion stopped; check the text field before trying again.",
            Self::Unavailable => {
                "Inline expansion could not connect. Check that Fcitx and the Snippets addon are installed, then retry."
            }
            #[cfg(feature = "fcitx")]
            Self::WaitingForFcitx => {
                "Enabled; waiting for the Snippets Fcitx addon. Restart Fcitx after installing Snippets."
            }
            Self::UnsupportedDesktop => {
                "Inline expansion is not available on this desktop yet. Your saved snippets remain available in the app."
            }
        }
    }
}
pub(crate) struct Handle {
    stop: Arc<AtomicBool>,
    pub receiver: mpsc::Receiver<Status>,
    thread: thread::JoinHandle<()>,
}
impl Handle {
    #[cfg(test)]
    pub fn start(root: PathBuf, witness: SessionWitness) -> Result<Self> {
        Self::start_with_usage(root, witness, None)
    }
    pub fn start_with_usage(
        root: PathBuf,
        witness: SessionWitness,
        usage: Option<crate::usage_store::Handle>,
    ) -> Result<Self> {
        if !Preference::read(&root)?.enabled {
            return Err(STOPPED);
        }
        let stop = Arc::new(AtomicBool::new(false));
        let ending = stop.clone();
        let (sender, receiver) = mpsc::sync_channel(16);
        let thread = thread::Builder::new()
            .name("snippets-inline".into())
            .spawn(move || run(root, witness, ending, sender, usage))
            .map_err(|_| Error("Inline expansion could not start."))?;
        Ok(Self {
            stop,
            receiver,
            thread,
        })
    }
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
        self.thread.thread().unpark();
    }
    pub fn finished(&self) -> bool {
        self.thread.is_finished()
    }
}
impl Drop for Handle {
    fn drop(&mut self) {
        self.stop();
    }
}

fn clipboard(
    connection: &wayland::Connection,
    context: Context,
    guard: &dyn Fn() -> Result<()>,
) -> Result<Zeroizing<String>> {
    let start = crate::clock::uptime().ok_or(CLIPBOARD)?;
    let wall = SystemTime::now();
    let checked = || {
        guard()?;
        let now = crate::clock::uptime().ok_or(CLIPBOARD)?;
        if now < start
            || now - start >= Duration::from_secs(2)
            || wall
                .elapsed()
                .map_or(true, |elapsed| elapsed >= Duration::from_secs(2))
        {
            return Err(CLIPBOARD);
        }
        connection.poll(0, guard)?;
        if connection
            .frame()?
            .is_none_or(|frame| frame.context() != context)
        {
            return Err(STOPPED);
        }
        Ok(())
    };
    let mut reader =
        crate::clipboard_history::wayland::Reader::open(&checked).map_err(|_| CLIPBOARD)?;
    if !crate::desktop::wayland_peer_matches(reader.peer_process()) {
        return Err(CLIPBOARD);
    }
    checked()?;
    let mut generation = reader.generation();
    while generation == 0 {
        reader.next(0, &checked).map_err(|_| CLIPBOARD)?;
        generation = reader.generation();
    }
    let formats = reader.formats().map_err(|_| CLIPBOARD)?;
    if formats.is_empty() {
        return Ok(Zeroizing::new(String::new()));
    }
    let mime = ["text/plain;charset=utf-8", "text/plain"]
        .into_iter()
        .find(|mime| formats.iter().any(|format| format == mime))
        .ok_or(CLIPBOARD)?;
    reader
        .receive_text(generation, mime, &checked)
        .map_err(|_| CLIPBOARD)
}
fn deliver(
    plan: Plan,
    library: &Library,
    connection: &mut wayland::Connection,
    witness: SessionWitness,
    guard: &dyn Fn() -> Result<()>,
) -> Result<()> {
    // Capture also excludes Snippets itself. No focus is moved by this path.
    let target = crate::desktop::PasteTarget::capture().ok_or(STOPPED)?;
    let authorization = crate::secure_insertion::Authorization::new(witness)?;
    let checked = || {
        guard()?;
        authorization.validate()
    };
    let clipboard = if plan.needs_clipboard() {
        clipboard(connection, plan.frame.context(), &checked)?
    } else {
        Zeroizing::new(String::new())
    };
    checked()?;
    let mut delivery = plan.prepare(&clipboard)?;
    drop(clipboard);
    let mut after = None;
    let mut waiting = crate::clock::uptime().ok_or(STOPPED)?;
    loop {
        checked()?;
        connection.poll(25, &checked)?;
        let now = crate::clock::uptime().ok_or(STOPPED)?;
        if now < waiting || now - waiting >= Duration::from_secs(2) {
            return Err(STOPPED);
        }
        let Some(frame) = connection.frame()? else {
            continue;
        };
        if after == Some(frame.context()) {
            continue;
        }
        let context = frame.context();
        if !target.is_fresh() || !target.is_active_unlocked() {
            return Err(STOPPED);
        }
        checked()?;
        match delivery.step(library, frame, connection, &checked)? {
            Step::Complete { .. } => return Ok(()),
            Step::AwaitingEcho(next) => {
                delivery = *next;
                after = Some(context);
                waiting = crate::clock::uptime().ok_or(STOPPED)?;
            }
        }
    }
}
fn run(
    root: PathBuf,
    witness: SessionWitness,
    stop: Arc<AtomicBool>,
    sender: mpsc::SyncSender<Status>,
    usage: Option<crate::usage_store::Handle>,
) {
    // Native GNOME input is owned by IBus. Do not claim its seat with the
    // wlroots fallback or select Fcitx merely because its executable exists.
    if crate::desktop::environment() == crate::desktop::Environment::Gnome {
        let _ = sender.try_send(Status::UnsupportedDesktop);
        return;
    }
    #[cfg(feature = "fcitx")]
    if Path::new("/usr/bin/fcitx5").is_file() {
        fcitx::run(root, witness, stop, sender, usage);
        return;
    }
    let library = match Library::prepare(root.clone()) {
        Ok(library) => library,
        Err(_) => {
            let _ = sender.try_send(Status::Unavailable);
            return;
        }
    };
    let signature = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE");
    let display = std::env::var_os("WAYLAND_DISPLAY");
    let runtime = std::env::var_os("XDG_RUNTIME_DIR");
    let mut last = None;
    let mut report = |status| {
        if last != Some(status) {
            let _ = sender.try_send(status);
            last = Some(status);
        }
    };
    loop {
        if stop.load(Ordering::Acquire) || !Preference::read(&root).is_ok_and(|value| value.enabled)
        {
            return;
        }
        let (state, epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            report(Status::WaitingForUnlock);
            thread::park_timeout(Duration::from_millis(100));
            continue;
        }
        let show_suggestions = Preference::read(&root).is_ok_and(|value| value.suggestions);
        let guard = || {
            if stop.load(Ordering::Acquire)
                || witness.snapshot() != (SessionState::Unlocked, epoch)
                || std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") != signature
                || std::env::var_os("WAYLAND_DISPLAY") != display
                || std::env::var_os("XDG_RUNTIME_DIR") != runtime
                || !Preference::read(&root)
                    .is_ok_and(|value| value.enabled && value.suggestions == show_suggestions)
            {
                return Err(STOPPED);
            }
            Ok(())
        };
        let mut connection = match wayland::Connection::open(&guard) {
            Ok(connection) => connection,
            Err(_) if guard().is_err() => continue,
            Err(_) => {
                report(Status::Unavailable);
                return;
            }
        };
        let mut engine = Engine::default();
        let mut popup = selection::Popup::default();
        let mut previous = None;
        while guard().is_ok() {
            if connection
                .poll(if popup.active() { 10 } else { 50 }, &guard)
                .is_err()
            {
                if guard().is_err() {
                    break;
                }
                report(Status::Unavailable);
                return;
            }
            let frame = match connection.frame() {
                Ok(frame) => frame,
                Err(_) => {
                    report(Status::Unavailable);
                    return;
                }
            };
            let Some(frame) = frame else {
                if popup.clear(&connection, &guard).is_err() {
                    break;
                }
                report(Status::WaitingForField);
                continue;
            };
            if previous == Some(frame.context()) && !show_suggestions {
                continue;
            }
            let changed = previous != Some(frame.context());
            previous = Some(frame.context());
            if frame.admitted_text().is_none() {
                engine.reset();
                if popup.clear(&connection, &guard).is_err() {
                    break;
                }
                report(Status::WaitingForField);
                continue;
            }
            let ordinary = if changed {
                (|| {
                    let _lock = library.try_lock()?;
                    library.read_locked().map(|(ordinary, _)| ordinary)
                })()
            } else {
                Ok(vec![])
            };
            let Ok(ordinary) = ordinary else {
                engine.reset();
                if popup.clear(&connection, &guard).is_err() {
                    break;
                }
                report(Status::Stopped);
                continue;
            };
            report(Status::Listening);
            let plan = if show_suggestions {
                let current = frame.copy();
                if changed {
                    let ranking = usage
                        .as_ref()
                        .map_or_else(crate::usage::Snapshot::default, |handle| handle.snapshot());
                    popup.observe(frame, &ordinary, &ranking);
                }
                match popup.process(&library, &current, &connection, &guard) {
                    Ok(plan) => plan,
                    Err(_) => {
                        let _ = popup.clear(&connection, &guard);
                        report(Status::Stopped);
                        previous = None;
                        continue;
                    }
                }
            } else {
                engine.observe(frame, &ordinary)
            };
            if let Some(plan) = plan {
                let id = plan.snippet.id;
                let query = plan.selected_query.clone();
                // GTK commits keyboard characters with the input-method cause
                // too. Reset both matchers before owning the replacement echo;
                // its first subsequent frame is a baseline, never another trigger.
                engine.reset();
                if popup.clear(&connection, &guard).is_err() {
                    report(Status::Stopped);
                    previous = None;
                    continue;
                }
                if deliver(plan, &library, &mut connection, witness.clone(), &guard).is_err() {
                    report(Status::Stopped);
                } else if let Some(usage) = &usage {
                    usage.record(
                        id,
                        crate::usage::Event::Expansion,
                        query.as_deref().map(|q| q.as_str()),
                    );
                }
                previous = None;
            }
        }
        // Lock/unavailable observation drops the native owner and all host text.
        drop(connection);
    }
}
