use super::*;
use crate::desktop::{PasteTarget, SessionMonitor, SessionState, SessionWitness};
use std::{
    ffi::{c_int, c_void},
    path::PathBuf,
    ptr::NonNull,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};
const UNAVAILABLE: Error = Error("Global shortcuts could not be registered with the desktop.");
const STOPPED: Error = Error("Global shortcuts were stopped.");
#[path = "shortcuts_gnome.rs"]
mod gnome;
unsafe extern "C" {
    fn snip_shortcuts_connect(
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
    fn snip_shortcuts_close(owner: *mut c_void);
    fn snip_shortcuts_peer(owner: *mut c_void) -> u64;
    fn snip_shortcuts_start(
        owner: *mut c_void,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_shortcuts_next(
        owner: *mut c_void,
        id: *mut u32,
        age: *mut u32,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
}
struct Check<'a>(&'a dyn Fn() -> Result<()>);
unsafe extern "C" fn check(context: *mut c_void) -> c_int {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        unsafe { (*(context.cast::<Check<'_>>())).0() }.is_ok()
    }))
    .unwrap_or(false)
    .into()
}
struct Native(NonNull<c_void>);
impl Drop for Native {
    fn drop(&mut self) {
        unsafe { snip_shortcuts_close(self.0.as_ptr()) }
    }
}
trait Backend {
    fn can_configure(&self) -> bool {
        false
    }
    fn next(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<Option<(Action, Duration)>>;
    fn activation_token(&mut self) -> Option<String> {
        None
    }
    fn configure(&mut self, _guard: &dyn Fn() -> Result<()>) -> Result<()> {
        Ok(())
    }
}
impl Native {
    fn open(guard: &dyn Fn() -> Result<()>) -> Result<Self> {
        guard()?;
        let mut context = Check(guard);
        let mut status = 3;
        let pointer = unsafe {
            snip_shortcuts_connect(check, (&mut context as *mut Check<'_>).cast(), &mut status)
        };
        let native = Self(NonNull::new(pointer).ok_or(UNAVAILABLE)?);
        if !crate::desktop::wayland_peer_matches(unsafe { snip_shortcuts_peer(native.0.as_ptr()) })
        {
            return Err(UNAVAILABLE);
        }
        guard()?;
        let status = unsafe {
            snip_shortcuts_start(
                native.0.as_ptr(),
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        if status != 0 {
            return Err(UNAVAILABLE);
        }
        guard()?;
        Ok(native)
    }
}
impl Backend for Native {
    fn next(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<Option<(Action, Duration)>> {
        guard()?;
        let mut context = Check(guard);
        let (mut id, mut age) = (0, 0);
        let status = unsafe {
            snip_shortcuts_next(
                self.0.as_ptr(),
                &mut id,
                &mut age,
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        guard()?;
        match status {
            0 if age <= 1500 => Action::from_id(id)
                .map(|a| Some((a, Duration::from_millis(age.into()))))
                .ok_or(UNAVAILABLE),
            1 => Ok(None),
            2 => Err(STOPPED),
            _ => Err(UNAVAILABLE),
        }
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Status {
    Off,
    Starting,
    Registered,
    Unavailable,
    Stopping,
}
pub(crate) struct Event {
    pub action: Action,
    pub target: Option<PasteTarget>,
    pub activation_token: Option<String>,
    session: SessionWitness,
    epoch: u64,
    deadline: Duration,
}
impl Event {
    fn new(action: Action, age: Duration, session: SessionWitness) -> Option<Self> {
        let (state, epoch) = session.snapshot();
        if state != SessionState::Unlocked {
            return None;
        }
        Some(Self {
            action,
            target: None,
            activation_token: None,
            epoch,
            session,
            deadline: crate::clock::uptime()?
                .checked_add(Duration::from_millis(1500).checked_sub(age)?)?,
        })
    }
    pub fn valid(&self) -> bool {
        self.session.snapshot() == (SessionState::Unlocked, self.epoch)
            && crate::clock::uptime().is_some_and(|now| now < self.deadline)
    }
}
pub(crate) struct Handle {
    stop: Arc<AtomicBool>,
    thread: thread::JoinHandle<()>,
    events: mpsc::Receiver<Event>,
    status: Arc<Mutex<Status>>,
    configure: Arc<AtomicBool>,
    configurable: Arc<AtomicBool>,
}
impl Handle {
    pub fn start(root: PathBuf) -> Result<Self> {
        if !Preference::read(&root)?.enabled {
            return Err(STOPPED);
        }
        let session = SessionMonitor::new().ok_or(UNAVAILABLE)?;
        Self::start_with(root, session.witness(), Some(session), |guard| {
            match crate::desktop::environment() {
                crate::desktop::Environment::Gnome => Ok(Box::new(gnome::Portal::open(guard)?)),
                _ => Ok(Box::new(Native::open(guard)?)),
            }
        })
    }
    fn start_with(
        root: PathBuf,
        session: SessionWitness,
        monitor: Option<SessionMonitor>,
        open: impl FnOnce(&dyn Fn() -> Result<()>) -> Result<Box<dyn Backend>> + Send + 'static,
    ) -> Result<Self> {
        if !Preference::read(&root)?.enabled {
            return Err(STOPPED);
        }
        let stop = Arc::new(AtomicBool::new(false));
        let ending = stop.clone();
        let status = Arc::new(Mutex::new(Status::Starting));
        let state = status.clone();
        let (sender, events) = mpsc::sync_channel(3);
        let configure = Arc::new(AtomicBool::new(false));
        let configuring = configure.clone();
        let configurable = Arc::new(AtomicBool::new(false));
        let configuration_capability = configurable.clone();
        let signature = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE");
        let display = std::env::var_os("WAYLAND_DISPLAY");
        let thread = thread::Builder::new()
            .name("snippets-shortcuts".into())
            .spawn(move || {
                let _monitor = monitor;
                let guard = || {
                    if ending.load(Ordering::Acquire)
                        || !Preference::read(&root)?.enabled
                        || std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") != signature
                        || std::env::var_os("WAYLAND_DISPLAY") != display
                    {
                        Err(STOPPED)
                    } else {
                        Ok(())
                    }
                };
                let result: Result<()> = (|| {
                    guard()?;
                    let mut backend = open(&guard)?;
                    configuration_capability.store(backend.can_configure(), Ordering::Release);
                    *state.lock().map_err(|_| UNAVAILABLE)? = Status::Registered;
                    loop {
                        guard()?;
                        if configuring.swap(false, Ordering::AcqRel) {
                            backend.configure(&guard)?;
                        }
                        if let Some((action, age)) = backend.next(&guard)?
                            && let Some(mut event) = Event::new(action, age, session.clone())
                        {
                            event.activation_token = backend.activation_token();
                            if action == Action::Picker {
                                event.target = PasteTarget::capture();
                            }
                            guard()?;
                            if event.valid() {
                                // Full queues refuse new work rather than accumulating delayed activations.
                                match sender.try_send(event) {
                                    Ok(()) | Err(mpsc::TrySendError::Full(_)) => (),
                                    Err(_) => return Err(STOPPED),
                                }
                            }
                        }
                    }
                })();
                if let Ok(mut status) = state.lock() {
                    *status = if ending.load(Ordering::Acquire)
                        || result == Err(STOPPED)
                        || Preference::read(&root).is_ok_and(|p| !p.enabled)
                    {
                        Status::Off
                    } else {
                        Status::Unavailable
                    };
                }
            })
            .map_err(|_| UNAVAILABLE)?;
        Ok(Self {
            stop,
            thread,
            events,
            status,
            configure,
            configurable,
        })
    }
    pub fn status(&self) -> Status {
        self.status.lock().map_or(Status::Unavailable, |s| *s)
    }
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }
    pub fn configure(&self) {
        if self.can_configure() {
            self.configure.store(true, Ordering::Release);
        }
    }
    pub fn can_configure(&self) -> bool {
        self.status() == Status::Registered && self.configurable.load(Ordering::Acquire)
    }
    pub fn is_finished(&self) -> bool {
        self.thread.is_finished()
    }
    pub fn next(&self) -> Option<Event> {
        if self.stop.load(Ordering::Acquire) || self.status() != Status::Registered {
            return None;
        }
        self.events.try_iter().find(Event::valid)
    }
}
impl Drop for Handle {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
#[path = "shortcuts_wayland_tests.rs"]
mod protocol_tests;
#[cfg(test)]
#[path = "shortcuts_worker_tests.rs"]
mod tests;
