//! Read-only Omarchy theme adapter and short-lived Hyprland paste destinations.
use serde_json::Value;
use std::{
    env,
    io::Read,
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
pub const APP_ID: &str = "com.khm.snippets.linux";

pub fn theme_path() -> Option<PathBuf> {
    env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|v| PathBuf::from(v).join(".local/state")))
        .map(|v| v.join("omarchy/current/theme/colors.toml"))
}
pub fn theme_css(data: &str) -> (String, Option<bool>) {
    let Ok(colors) = data.parse::<toml::Table>() else {
        return (String::new(), None);
    };
    let mut css = String::new();
    for (key, names) in [
        ("accent", &["accent_bg_color", "accent_color"][..]),
        ("background", &["window_bg_color", "view_bg_color"]),
        (
            "foreground",
            &[
                "window_fg_color",
                "view_fg_color",
                "headerbar_fg_color",
                "sidebar_fg_color",
            ],
        ),
        (
            "dark_background",
            &["headerbar_bg_color", "sidebar_bg_color", "card_bg_color"],
        ),
        ("selection", &["popover_bg_color", "dialog_bg_color"]),
    ] {
        if let Some(value) = colors.get(key).and_then(toml::Value::as_str)
            && value.len() == 7
            && value.starts_with('#')
            && value[1..].bytes().all(|c| c.is_ascii_hexdigit())
        {
            for name in names {
                css.push_str(&format!("@define-color {name} {value};\n"));
            }
        }
    }
    (
        css,
        match colors.get("mode").and_then(toml::Value::as_str) {
            Some("dark") => Some(true),
            Some("light") => Some(false),
            _ => None,
        },
    )
}
fn hypr(arguments: &[&str]) -> Option<Vec<u8>> {
    let mut child = Command::new("hyprctl")
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let output = child.stdout.take()?;
    let reader = thread::spawn(move || {
        let mut data = Vec::new();
        output
            .take(4 * 1024 * 1024 + 1)
            .read_to_end(&mut data)
            .ok()?;
        Some(data)
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < Duration::from_secs(2) => {
                thread::sleep(Duration::from_millis(10))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let data = reader.join().ok()??;
    if !status?.success() || data.len() > 4 * 1024 * 1024 {
        return None;
    }
    Some(data)
}
fn query(operation: &str) -> Option<Value> {
    serde_json::from_slice(&hypr(&["-j", operation])?).ok()
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Unlocked,
    Locked,
    Unavailable,
}
impl SessionState {
    fn decode(value: Option<Value>) -> Self {
        match value.and_then(|v| v.get("locked").and_then(Value::as_bool)) {
            Some(false) => Self::Unlocked,
            Some(true) => Self::Locked,
            None => Self::Unavailable,
        }
    }
}
pub fn session_state() -> SessionState {
    SessionState::decode(query("locked"))
}

struct ObservedSession {
    state: SessionState,
    checked: Duration,
    epoch: u64,
}
impl ObservedSession {
    fn observe(&mut self, state: SessionState) {
        if self.state != state {
            self.epoch = self.epoch.wrapping_add(1);
        }
        self.state = state;
        self.checked = crate::clock::uptime().unwrap_or(Duration::ZERO);
    }
    fn snapshot(&self) -> (SessionState, u64) {
        (
            if crate::clock::uptime()
                .is_none_or(|now| now.saturating_sub(self.checked) > Duration::from_millis(1250))
            {
                SessionState::Unavailable
            } else {
                self.state
            },
            self.epoch,
        )
    }
}
/// Read-only polling stays off the GTK thread. A missing, poisoned or stale
/// observation never authorizes a secure operation. Epochs invalidate workers
/// across an observed lock even if the desktop was unlocked again meanwhile.
pub struct SessionMonitor {
    observed: Arc<Mutex<ObservedSession>>,
    stop: Arc<AtomicBool>,
    thread: thread::JoinHandle<()>,
}
/// Borrowed observation for owner workers; cloning creates no polling thread.
#[derive(Clone)]
pub struct SessionWitness(Arc<Mutex<ObservedSession>>);
impl SessionWitness {
    pub fn snapshot(&self) -> (SessionState, u64) {
        self.0
            .lock()
            .map_or((SessionState::Unavailable, 0), |value| value.snapshot())
    }
    #[cfg(test)]
    pub(crate) fn test(state: SessionState, epoch: u64) -> Self {
        Self(Arc::new(Mutex::new(ObservedSession {
            state,
            epoch,
            checked: crate::clock::uptime().unwrap(),
        })))
    }
    #[cfg(test)]
    pub(crate) fn test_observe(&self, state: SessionState) {
        self.0.lock().unwrap().observe(state);
    }
}
impl SessionMonitor {
    pub fn new() -> Option<Self> {
        let observed = Arc::new(Mutex::new(ObservedSession {
            state: SessionState::Unavailable,
            checked: Duration::ZERO,
            epoch: 0,
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let value = observed.clone();
        let ending = stop.clone();
        let thread = thread::Builder::new()
            .name("snippets-session".into())
            .spawn(move || {
                while !ending.load(Ordering::Acquire) {
                    let current = session_state();
                    if let Ok(mut value) = value.lock() {
                        if ending.load(Ordering::Acquire) {
                            break;
                        }
                        value.observe(current);
                    }
                    thread::park_timeout(Duration::from_millis(500));
                }
            })
            .ok()?;
        Some(Self {
            observed,
            stop,
            thread,
        })
    }
    pub fn snapshot(&self) -> (SessionState, u64) {
        self.witness().snapshot()
    }
    pub fn witness(&self) -> SessionWitness {
        SessionWitness(self.observed.clone())
    }
}
impl Drop for SessionMonitor {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Ok(mut observed) = self.observed.lock() {
            observed.observe(SessionState::Unavailable);
        }
        self.thread.thread().unpark();
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct PasteTarget {
    address: String,
    process: u64,
    terminal: bool,
}
/// Only an ephemeral admission witness. Application classes, addresses and PIDs
/// are never logged, persisted or returned as history metadata.
#[cfg(feature = "desktop")]
pub(crate) struct ClipboardSource {
    target: PasteTarget,
    class: String,
}
#[cfg(feature = "desktop")]
impl ClipboardSource {
    pub(crate) fn observe(excluded: &[String]) -> Option<Self> {
        if session_state() != SessionState::Unlocked {
            return None;
        }
        let window = query("activewindow")?;
        let class = window.get("class")?.as_str()?;
        if !crate::clipboard_history::source_permitted(class, excluded) {
            return None;
        }
        Some(Self {
            target: PasteTarget::from_window(&window)?,
            class: class.into(),
        })
    }
    pub(crate) fn validate(&self) -> bool {
        session_state() == SessionState::Unlocked
            && query("activewindow").is_some_and(|window| {
                self.target.matches(&window)
                    && window.get("class").and_then(Value::as_str) == Some(self.class.as_str())
            })
    }
}
impl PasteTarget {
    pub fn from_window(window: &Value) -> Option<Self> {
        let address = window.get("address")?.as_str()?;
        let process = window.get("pid")?.as_u64()?;
        if process == 0
            || window.get("class").and_then(Value::as_str) == Some(APP_ID)
            || !address.starts_with("0x")
            || address.len() <= 2
            || !address[2..].bytes().all(|c| c.is_ascii_hexdigit())
        {
            return None;
        }
        let terminal = window
            .get("tags")
            .and_then(Value::as_array)
            .is_some_and(|tags| {
                tags.iter().any(|t| {
                    t.as_str()
                        .is_some_and(|v| v.trim_end_matches('*') == "terminal")
                })
            });
        Some(Self {
            address: address.into(),
            process,
            terminal,
        })
    }
    pub fn capture() -> Option<Self> {
        if session_state() != SessionState::Unlocked {
            return None;
        }
        Self::from_window(&query("activewindow")?)
    }
    fn matches(&self, window: &Value) -> bool {
        window.get("address").and_then(Value::as_str) == Some(&self.address)
            && window.get("pid").and_then(Value::as_u64) == Some(self.process)
    }
    pub fn exists(&self) -> bool {
        query("clients")
            .and_then(|v| v.as_array().cloned())
            .is_some_and(|clients| clients.iter().any(|w| self.matches(w)))
    }
    pub fn focus(&self) -> bool {
        if session_state() != SessionState::Unlocked || !self.exists() {
            return false;
        }
        let expression = format!(
            "assert(hl.dispatch(hl.dsp.focus({{ window = \"address:{}\" }})).ok)",
            self.address
        );
        hypr(&["eval", &expression]).is_some_and(|data| data.trim_ascii() == b"ok")
    }
    pub fn paste(&self) -> bool {
        if session_state() != SessionState::Unlocked
            || !query("activewindow").is_some_and(|w| self.matches(&w))
        {
            return false;
        }
        let (mods, key) = if self.terminal {
            ("SHIFT", "Insert")
        } else {
            ("CTRL", "V")
        };
        let fields = format!(
            "mods = \"{mods}\", key = \"{key}\", window = \"address:{}\"",
            self.address
        );
        let expression = format!(
            "assert(hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"down\" }})).ok) hl.timer(function() hl.dispatch(hl.dsp.send_key_state({{ {fields}, state = \"up\" }})) end, {{ timeout = 50, type = \"oneshot\" }})"
        );
        hypr(&["eval", &expression]).is_some_and(|data| data.trim_ascii() == b"ok")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_observations_close_the_gate_and_lock_cycles_invalidate_workers() {
        let mut value = ObservedSession {
            state: SessionState::Unlocked,
            checked: crate::clock::uptime().unwrap(),
            epoch: 3,
        };
        value.observe(SessionState::Locked);
        value.observe(SessionState::Unlocked);
        assert!(value.snapshot() == (SessionState::Unlocked, 5));
        value.checked = crate::clock::uptime()
            .unwrap()
            .saturating_sub(Duration::from_secs(2));
        assert!(value.snapshot() == (SessionState::Unavailable, 5));
    }
    #[test]
    fn missing_or_malformed_lock_state_never_authorizes_insertion() {
        for value in [
            None,
            Some(Value::Null),
            Some(serde_json::json!({})),
            Some(serde_json::json!({"locked":"false"})),
        ] {
            assert!(SessionState::decode(value) == SessionState::Unavailable);
        }
        assert!(
            SessionState::decode(Some(serde_json::json!({"locked":true}))) == SessionState::Locked
        );
        assert!(
            SessionState::decode(Some(serde_json::json!({"locked":false})))
                == SessionState::Unlocked
        );
    }
    #[test]
    fn insertion_requires_both_the_window_and_its_original_process() {
        let target =
            PasteTarget::from_window(&serde_json::json!({"address":"0x123","pid":10})).unwrap();
        assert!(!target.matches(&serde_json::json!({"address":"0x123","pid":20})));
        assert!(!target.matches(&serde_json::json!({"address":"0x456","pid":10})));
        assert!(target.matches(&serde_json::json!({"address":"0x123","pid":10})));
    }
}
