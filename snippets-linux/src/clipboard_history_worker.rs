//! One bounded serial owner. Disabled startup performs no native service call;
//! preferences, keyring and encrypted history work stay off the GTK thread.
use super::*;
use crate::desktop::{ClipboardSource, SessionState, SessionWitness};
use std::{
    sync::atomic::AtomicBool,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    time::{Duration, SystemTime},
};
pub(crate) const PREFERENCE_CHANGED: Error =
    Error("History settings changed. Collection stopped; reset settings before enabling it again.");
#[derive(Default)]
struct State {
    epoch: u64,
    view_epoch: u64,
    enabled: bool,
    paused: bool,
    viewing: bool,
    quitting: bool,
}
#[derive(Clone)]
pub(crate) struct Control(Arc<Mutex<State>>);
impl Control {
    fn new(enabled: bool) -> Self {
        Self(Arc::new(Mutex::new(State {
            enabled,
            ..State::default()
        })))
    }
    pub fn viewing(&self, value: bool) {
        if let Ok(mut state) = self.0.lock() {
            state.view_epoch = state.view_epoch.wrapping_add(1);
            state.viewing = value;
        }
    }
    pub fn has_view(&self) -> bool {
        self.0.lock().is_ok_and(|state| state.viewing)
    }
    pub fn capture_epoch(&self) -> Option<u64> {
        self.0.lock().ok().and_then(|state| {
            (state.enabled && !state.paused && !state.quitting).then_some(state.epoch)
        })
    }
    pub fn pause(&self) -> u64 {
        let mut state = self.0.lock().expect("history control");
        state.epoch = state.epoch.wrapping_add(1);
        state.view_epoch = state.view_epoch.wrapping_add(1);
        state.paused = true;
        state.epoch
    }
    fn apply(&self, epoch: u64, enabled: bool) {
        if let Ok(mut state) = self.0.lock()
            && state.epoch == epoch
            && !state.quitting
        {
            state.enabled = enabled;
            state.paused = false;
        }
    }
    pub fn prepare_quit(&self) {
        if let Ok(mut state) = self.0.lock() {
            state.epoch = state.epoch.wrapping_add(1);
            state.view_epoch = state.view_epoch.wrapping_add(1);
            state.quitting = true;
        }
    }
    pub fn cancel_quit(&self) {
        if let Ok(mut state) = self.0.lock() {
            state.quitting = false;
        }
    }
    pub fn resume(&self, enabled: bool) {
        let epoch = self.pause();
        self.apply(epoch, enabled);
    }
    pub fn ticket(&self, witness: SessionWitness, view: bool) -> Result<Ticket> {
        let (session, desktop_epoch) = witness.snapshot();
        let state = self.0.lock().map_err(|_| CANCELLED)?;
        if session != SessionState::Unlocked
            || state.quitting
            || if view {
                !state.viewing
            } else {
                !state.enabled || state.paused
            }
        {
            return Err(CANCELLED);
        }
        Ok(Ticket {
            control: self.clone(),
            witness,
            desktop_epoch,
            epoch: state.epoch,
            view_epoch: view.then_some(state.view_epoch),
            started: crate::clock::uptime().ok_or(CANCELLED)?,
            wall: SystemTime::now(),
        })
    }
}
#[derive(Clone)]
pub(crate) struct Ticket {
    control: Control,
    witness: SessionWitness,
    desktop_epoch: u64,
    epoch: u64,
    view_epoch: Option<u64>,
    started: Duration,
    wall: SystemTime,
}
impl Ticket {
    pub fn check(&self) -> Result<()> {
        let now = crate::clock::uptime().ok_or(CANCELLED)?;
        self.check_at(now, SystemTime::now())
    }
    fn check_at(&self, now: Duration, wall: SystemTime) -> Result<()> {
        let wall = wall.duration_since(self.wall).map_err(|_| CANCELLED)?;
        let state = self.control.0.lock().map_err(|_| CANCELLED)?;
        if now < self.started
            || now - self.started >= Duration::from_secs(30)
            || wall >= Duration::from_secs(30)
            || state.quitting
            || state.epoch != self.epoch
            || self.witness.snapshot() != (SessionState::Unlocked, self.desktop_epoch)
            || match self.view_epoch {
                Some(epoch) => !state.viewing || state.view_epoch != epoch,
                None => !state.enabled || state.paused,
            }
        {
            return Err(CANCELLED);
        }
        Ok(())
    }
}
pub(crate) enum Command {
    Monitor {
        epoch: u64,
        result: Result<()>,
    },
    Preference {
        epoch: u64,
        enabled: bool,
        apps: Vec<String>,
    },
    ResetPreference {
        epoch: u64,
    },
    Record {
        ticket: Ticket,
        preference: Preference,
        text: Zeroizing<String>,
    },
    View {
        sequence: u64,
        ticket: Ticket,
    },
    Delete {
        sequence: u64,
        ticket: Ticket,
        id: Uuid,
    },
    Clear {
        epoch: u64,
    },
    Maintain(Ticket),
}
pub(crate) enum Reply {
    Preference {
        epoch: u64,
        result: Result<Preference>,
    },
    Monitor {
        epoch: u64,
        result: Result<()>,
    },
    Recorded(Result<usize>),
    View {
        sequence: u64,
        result: Result<Vec<Entry>>,
    },
    Cleared {
        epoch: u64,
        result: Result<()>,
    },
}
pub(crate) struct Handle {
    sender: mpsc::SyncSender<Command>,
    pub receiver: mpsc::Receiver<Reply>,
    pub control: Control,
    pending: Arc<AtomicUsize>,
}
pub(crate) struct CaptureHandle {
    stop: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
}
impl CaptureHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }
    pub fn finished(&self) -> bool {
        self.done.load(Ordering::Acquire)
    }
}
impl Drop for CaptureHandle {
    fn drop(&mut self) {
        self.stop();
    }
}
struct CaptureDone(Arc<AtomicBool>);
impl Drop for CaptureDone {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
impl Handle {
    pub fn start_capture(
        &self,
        root: PathBuf,
        preference: Preference,
        witness: SessionWitness,
    ) -> Result<CaptureHandle> {
        // Isolated UI/process tests must never access the user's real clipboard.
        if std::env::var_os("SNIPPETS_SUPPORT_DIR").is_some()
            || !model::default_root().is_ok_and(|actual| actual == root)
        {
            return Err(Error(
                "Clipboard monitoring is disabled for isolated test storage.",
            ));
        }
        let epoch = self.control.capture_epoch().ok_or(CANCELLED)?;
        let control = self.control.clone();
        let sender = self.sender.clone();
        let pending = self.pending.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let done = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        let finished = done.clone();
        std::thread::Builder::new()
            .name("snippets-clipboard".into())
            .spawn(move || {
                let _completion = CaptureDone(finished);
                let mut reader = None;
                let mut seen = 0;
                let mut reported = false;
                let scope = || -> Result<()> {
                    if stopping.load(Ordering::Acquire)
                        || control.capture_epoch() != Some(epoch)
                        || Preference::read(&root)? != preference
                    {
                        return Err(CANCELLED);
                    }
                    Ok(())
                };
                while scope().is_ok() {
                    let Ok(ticket) = control.ticket(witness.clone(), false) else {
                        reader.take();
                        std::thread::sleep(Duration::from_millis(100));
                        continue;
                    };
                    let guard = || {
                        scope()?;
                        ticket.check()
                    };
                    if reader.is_none() {
                        match super::wayland::Reader::open(&guard) {
                            Ok(opened) => {
                                // The first offer is always a pre-existing baseline.
                                seen = opened.generation();
                                reader = Some(opened);
                                reported = false;
                                let _ = enqueue(
                                    &sender,
                                    &pending,
                                    Command::Monitor {
                                        epoch,
                                        result: Ok(()),
                                    },
                                );
                            }
                            Err(error) => {
                                if error != CANCELLED && !reported {
                                    let _ = enqueue(
                                        &sender,
                                        &pending,
                                        Command::Monitor {
                                            epoch,
                                            result: Err(error),
                                        },
                                    );
                                    reported = true;
                                }
                                std::thread::sleep(Duration::from_millis(100));
                                continue;
                            }
                        }
                    }
                    let connection = reader.as_mut().expect("clipboard reader");
                    match connection.next(seen, &guard) {
                        Ok(false) => continue,
                        Err(_) => {
                            reader.take();
                            continue;
                        }
                        Ok(true) => (),
                    }
                    seen = connection.generation();
                    let Ok(formats) = connection.formats() else {
                        continue;
                    };
                    let formats: Vec<_> = formats.iter().map(String::as_str).collect();
                    if !permits(&formats, false) {
                        continue;
                    }
                    let Some(mime) = formats
                        .iter()
                        .find(|mime| mime.eq_ignore_ascii_case("text/plain;charset=utf-8"))
                        .or_else(|| {
                            formats
                                .iter()
                                .find(|mime| mime.eq_ignore_ascii_case("text/plain"))
                        })
                    else {
                        continue;
                    };
                    let Some(source) = ClipboardSource::observe(&preference.excluded_apps) else {
                        continue;
                    };
                    let Ok(text) = connection.receive(seen, mime, &guard) else {
                        continue;
                    };
                    if guard().is_err() || !source.validate() {
                        continue;
                    }
                    let _ = enqueue(
                        &sender,
                        &pending,
                        Command::Record {
                            ticket: ticket.clone(),
                            preference: preference.clone(),
                            text,
                        },
                    );
                }
                reader.take();
                if !stopping.load(Ordering::Acquire) && control.capture_epoch() == Some(epoch) {
                    let _ = enqueue(
                        &sender,
                        &pending,
                        Command::Monitor {
                            epoch,
                            result: Err(PREFERENCE_CHANGED),
                        },
                    );
                }
            })
            .map_err(|_| UNAVAILABLE)?;
        Ok(CaptureHandle { stop, done })
    }
    pub fn new(root: PathBuf, preference: Preference) -> Result<Self> {
        Self::spawn(root, preference, crate::secret_store::Native::new)
    }
    fn spawn<B: Backend + Send + 'static>(
        root: PathBuf,
        mut preference: Preference,
        factory: impl Fn() -> crate::secret_store::Result<B> + Send + 'static,
    ) -> Result<Self> {
        let (sender, commands) = mpsc::sync_channel(8);
        let (replies, receiver) = mpsc::sync_channel(2);
        let control = Control::new(preference.enabled);
        let worker_control = control.clone();
        let pending = Arc::new(AtomicUsize::new(0));
        let working = pending.clone();
        std::thread::Builder::new()
            .name("snippets-history".into())
            .spawn(move || {
                while let Ok(command) = commands.recv() {
                    let reply = match command {
                        Command::Monitor { epoch, result } => {
                            Some(Reply::Monitor { epoch, result })
                        }
                        Command::Preference {
                            epoch,
                            enabled,
                            apps,
                        } => {
                            let result = preference
                                .save(&root, enabled, apps)
                                .map(|_| preference.clone());
                            if result.is_ok() {
                                worker_control.apply(epoch, preference.enabled);
                            }
                            Some(Reply::Preference { epoch, result })
                        }
                        Command::ResetPreference { epoch } => {
                            let result = Preference::reset(&root);
                            if let Ok(updated) = &result {
                                preference = updated.clone();
                                worker_control.apply(epoch, preference.enabled);
                            }
                            Some(Reply::Preference { epoch, result })
                        }
                        Command::Record {
                            ticket,
                            preference,
                            text,
                        } => {
                            let result = ticket
                                .check()
                                .and_then(|_| factory().map_err(|_| KEY))
                                .and_then(|backend| {
                                    record(&root, backend, &preference, text, now_ms(), &|| {
                                        ticket.check()
                                    })
                                });
                            Some(Reply::Recorded(result))
                        }
                        Command::View { sequence, ticket } => {
                            let result = ticket.check().and_then(|_| {
                                if read_image(&root)?.is_none() {
                                    ticket.check()?;
                                    return Ok(Vec::new());
                                }
                                load(&root, factory().map_err(|_| KEY)?, now_ms(), &|| {
                                    ticket.check()
                                })
                            });
                            Some(Reply::View { sequence, result })
                        }
                        Command::Delete {
                            sequence,
                            ticket,
                            id,
                        } => {
                            let result = ticket.check().and_then(|_| {
                                if read_image(&root)?.is_none() {
                                    ticket.check()?;
                                    return Ok(Vec::new());
                                }
                                delete(&root, factory().map_err(|_| KEY)?, id, now_ms(), &|| {
                                    ticket.check()
                                })
                            });
                            Some(Reply::View { sequence, result })
                        }
                        Command::Clear { epoch } => {
                            let result = clear(&root, &|| Ok(()));
                            if result.is_ok() {
                                worker_control.apply(epoch, preference.enabled);
                            }
                            Some(Reply::Cleared { epoch, result })
                        }
                        Command::Maintain(ticket) => {
                            // No body reply or persistent cache. Empty storage does not
                            // access a keyring even when a keyring factory is available.
                            if ticket.check().is_ok()
                                && read_image(&root).is_ok_and(|image| image.is_some())
                                && let Ok(backend) = factory()
                            {
                                let _ = load(&root, backend, now_ms(), &|| ticket.check());
                            }
                            None
                        }
                    };
                    let sent = reply.is_none_or(|reply| replies.send(reply).is_ok());
                    working.fetch_sub(1, Ordering::SeqCst);
                    if !sent {
                        break;
                    }
                }
            })
            .map_err(|_| UNAVAILABLE)?;
        Ok(Self {
            sender,
            receiver,
            control,
            pending,
        })
    }
    pub fn send(&self, command: Command) -> Result<()> {
        enqueue(&self.sender, &self.pending, command)
    }
    pub fn prepare_quit(&self) -> bool {
        self.control.prepare_quit();
        self.pending.load(Ordering::SeqCst) == 0
    }
}
fn enqueue(
    sender: &mpsc::SyncSender<Command>,
    pending: &AtomicUsize,
    command: Command,
) -> Result<()> {
    pending.fetch_add(1, Ordering::SeqCst);
    if sender.try_send(command).is_err() {
        pending.fetch_sub(1, Ordering::SeqCst);
        return Err(Error("Clipboard history is busy. Try again shortly."));
    }
    Ok(())
}
impl Drop for Handle {
    fn drop(&mut self) {
        self.control.prepare_quit();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn isolated_capture_refuses_before_any_desktop_connection_or_backend_call() {
        let root = tempfile::tempdir().unwrap();
        let handle = Handle::spawn(
            root.path().into(),
            Preference::default(),
            || -> crate::secret_store::Result<Never> { panic!("backend") },
        )
        .unwrap();
        assert!(
            handle
                .start_capture(
                    root.path().into(),
                    Preference::default(),
                    SessionWitness::test(SessionState::Unlocked, 1)
                )
                .is_err()
        );
        assert!(handle.prepare_quit());
        assert!(fs::read_dir(root.path()).unwrap().next().is_none());
    }
    struct Never;
    impl Backend for Never {
        fn read(
            &mut self,
            _: &[u8; 16],
            _: Slot,
        ) -> crate::secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
            panic!("native read")
        }
        fn write(&mut self, _: &[u8; 16], _: Slot, _: &[u8]) -> crate::secret_store::Result<()> {
            panic!("native write")
        }
        fn delete(&mut self, _: &[u8; 16], _: Slot) -> crate::secret_store::Result<()> {
            panic!("native delete")
        }
    }
    #[test]
    fn view_deadlines_reject_elapsed_wall_suspend_and_backwards_clocks() {
        let control = Control::new(false);
        control.viewing(true);
        let ticket = control
            .ticket(SessionWitness::test(SessionState::Unlocked, 1), true)
            .unwrap();
        assert!(
            ticket
                .check_at(ticket.started + Duration::from_secs(30), ticket.wall)
                .is_err()
        );
        assert!(
            ticket
                .check_at(ticket.started, ticket.wall + Duration::from_secs(30))
                .is_err()
        );
        assert!(
            ticket
                .check_at(ticket.started, ticket.wall - Duration::from_secs(1))
                .is_err()
        );
        let mut backwards = ticket.clone();
        backwards.started += Duration::from_secs(1);
        assert!(backwards.check_at(ticket.started, ticket.wall).is_err());
    }
    #[test]
    fn stale_views_never_construct_a_backend_even_with_present_unreadable_ciphertext() {
        let root = tempfile::tempdir().unwrap();
        fs::create_dir(root.path().join("ClipboardHistory")).unwrap();
        fs::set_permissions(
            root.path().join("ClipboardHistory"),
            fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        model::atomic_write(
            &root.path().join("ClipboardHistory/history.bin"),
            b"Public damaged ciphertext",
        )
        .unwrap();
        let handle = Handle::spawn(
            root.path().into(),
            Preference::default(),
            || -> crate::secret_store::Result<Never> { panic!("backend") },
        )
        .unwrap();
        handle.control.viewing(true);
        let ticket = handle
            .control
            .ticket(SessionWitness::test(SessionState::Unlocked, 1), true)
            .unwrap();
        handle.control.viewing(false);
        handle
            .send(Command::View {
                sequence: 1,
                ticket,
            })
            .unwrap();
        assert!(matches!(
            handle
                .receiver
                .recv_timeout(Duration::from_secs(2))
                .unwrap(),
            Reply::View {
                result: Err(CANCELLED),
                ..
            }
        ));
        let epoch = handle.control.pause();
        handle.send(Command::Clear { epoch }).unwrap();
        assert!(matches!(
            handle
                .receiver
                .recv_timeout(Duration::from_secs(2))
                .unwrap(),
            Reply::Cleared { result: Ok(()), .. }
        ));
        assert!(
            !root.path().join("ClipboardHistory/history.bin").exists()
                && !root.path().join("secret-owner.bin").exists()
        );
    }
    #[test]
    fn the_serial_queue_refuses_overflow_and_quit_waits_for_real_pending_work() {
        let root = tempfile::tempdir().unwrap();
        let library = Library::prepare(root.path().into()).unwrap();
        let lock = library.lock().unwrap();
        let handle = Handle::spawn(
            root.path().into(),
            Preference::default(),
            || -> crate::secret_store::Result<Never> { panic!("backend") },
        )
        .unwrap();
        let epoch = handle.control.pause();
        let mut accepted = 0;
        let mut refused = 0;
        for _ in 0..64 {
            match handle.send(Command::Clear { epoch }) {
                Ok(()) => accepted += 1,
                Err(_) => refused += 1,
            }
        }
        assert!(accepted > 0 && accepted <= 9 && refused > 0);
        assert!(!handle.prepare_quit());
        drop(lock);
        for _ in 0..accepted {
            assert!(matches!(
                handle
                    .receiver
                    .recv_timeout(Duration::from_secs(2))
                    .unwrap(),
                Reply::Cleared { result: Ok(()), .. }
            ));
        }
        // The reply is queued before the worker drops its admission count.
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            if handle.prepare_quit() {
                return;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(handle.prepare_quit());
    }
    #[test]
    fn capture_and_view_tickets_are_distinct_and_revoked_by_focus_preferences_quit_or_lock() {
        let control = Control::new(false);
        let witness = SessionWitness::test(SessionState::Unlocked, 1);
        assert!(control.ticket(witness.clone(), false).is_err());
        assert!(control.ticket(witness.clone(), true).is_err());
        control.viewing(true);
        let view = control.ticket(witness.clone(), true).unwrap();
        view.check().unwrap();
        control.viewing(false);
        assert!(view.check().is_err());
        let epoch = control.pause();
        control.apply(epoch, true);
        let capture = control.ticket(witness.clone(), false).unwrap();
        let old = control.pause();
        let new = control.pause();
        control.apply(old, true);
        assert!(control.ticket(witness.clone(), false).is_err());
        control.apply(new, true);
        assert!(capture.check().is_err());
        let capture = control.ticket(witness.clone(), false).unwrap();
        control.prepare_quit();
        control.cancel_quit();
        assert!(capture.check().is_err());
        let capture = control.ticket(witness.clone(), false).unwrap();
        witness.test_observe(SessionState::Locked);
        witness.test_observe(SessionState::Unlocked);
        assert!(capture.check().is_err());
    }
    #[test]
    fn disabled_owner_clear_and_preference_changes_never_construct_a_backend() {
        struct Never;
        impl Backend for Never {
            fn read(
                &mut self,
                _: &[u8; 16],
                _: Slot,
            ) -> crate::secret_store::Result<Option<Zeroizing<Vec<u8>>>> {
                panic!("native read")
            }
            fn write(
                &mut self,
                _: &[u8; 16],
                _: Slot,
                _: &[u8],
            ) -> crate::secret_store::Result<()> {
                panic!("native write")
            }
            fn delete(&mut self, _: &[u8; 16], _: Slot) -> crate::secret_store::Result<()> {
                panic!("native delete")
            }
        }
        let root = tempfile::tempdir().unwrap();
        let owner = Handle::spawn(
            root.path().into(),
            Preference::default(),
            || -> crate::secret_store::Result<Never> { panic!("backend") },
        )
        .unwrap();
        let epoch = owner.control.pause();
        owner
            .send(Command::Preference {
                epoch,
                enabled: false,
                apps: vec![],
            })
            .unwrap();
        assert!(matches!(
            owner.receiver.recv_timeout(Duration::from_secs(2)).unwrap(),
            Reply::Preference { result: Ok(_), .. }
        ));
        let epoch = owner.control.pause();
        owner.send(Command::Clear { epoch }).unwrap();
        assert!(matches!(
            owner.receiver.recv_timeout(Duration::from_secs(2)).unwrap(),
            Reply::Cleared { result: Ok(()), .. }
        ));
        assert!(
            !root.path().join("secret-owner.bin").exists()
                && !root.path().join("ClipboardHistory").exists()
        );
    }
}
