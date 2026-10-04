//! Private, debounced usage persistence. The desktop owner alone starts this worker.
use crate::{
    model::{self, Error, Result},
    usage::{Document, Event, Snapshot, prefix},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

const UNSAFE: Error =
    Error("Usage storage is unavailable or unsafe; existing files were preserved.");
const BUSY: Error = Error("Usage storage is busy. Try again shortly.");
const LIMIT: usize = 2 * 1024 * 1024;
const DELAY: Duration = Duration::from_secs(5);
const CEILING: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Preferences {
    schema: u32,
    #[serde(default = "enabled")]
    ranking: bool,
    #[serde(default = "enabled")]
    memory: bool,
}
fn enabled() -> bool {
    true
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            schema: 1,
            ranking: true,
            memory: true,
        }
    }
}

struct State {
    document: Document,
    preferences: Preferences,
    ready: bool,
    writable: bool,
    pending: usize,
    error: Option<Error>,
}
#[derive(Clone)]
pub struct Status {
    pub ready: bool,
    pub writable: bool,
    pub busy: bool,
    pub ranking: bool,
    pub memory: bool,
    pub records: usize,
    pub prefixes: usize,
    pub error: Option<Error>,
}
enum Command {
    Record(Uuid, Event, Option<String>),
    Preferences(Preferences),
    Reset(bool, bool),
    Live(HashSet<Uuid>),
    Flush(mpsc::SyncSender<Result<()>>),
    Stop,
}
struct Owner {
    sender: Option<mpsc::SyncSender<Command>>,
    state: Arc<Mutex<State>>,
}
impl Drop for Owner {
    fn drop(&mut self) {
        if let Some(sender) = &self.sender {
            let _ = sender.try_send(Command::Stop);
        }
    }
}
#[derive(Clone)]
pub struct Handle {
    owner: Arc<Owner>,
}
impl Handle {
    pub fn start(root: PathBuf) -> Self {
        Self::start_with_disabled(
            root,
            std::env::var_os("SNIPPETS_USAGE_DISABLED").is_some_and(|v| v == "1"),
        )
    }
    fn start_with_disabled(root: PathBuf, disabled: bool) -> Self {
        let state = Arc::new(Mutex::new(State {
            document: Document::new(now()), preferences: Preferences::default(),
            ready: disabled, writable: false, pending: 0,
            error: disabled.then_some(Error("Usage learning is disabled by SNIPPETS_USAGE_DISABLED. No usage files are accessed.")),
        }));
        if disabled {
            return Self {
                owner: Arc::new(Owner {
                    sender: None,
                    state,
                }),
            };
        }
        let (sender, receiver) = mpsc::sync_channel(256);
        let shared = state.clone();
        if thread::Builder::new()
            .name("snippets-usage".into())
            .spawn(move || run(root, receiver, shared))
            .is_err()
        {
            let mut state = state.lock().expect("usage state");
            state.ready = true;
            state.error = Some(Error("Usage learning could not start."));
        }
        Self {
            owner: Arc::new(Owner {
                sender: Some(sender),
                state,
            }),
        }
    }
    pub fn status(&self) -> Status {
        let state = self.owner.state.lock().expect("usage state");
        let (records, prefixes) = state.document.counts();
        Status {
            ready: state.ready,
            writable: state.writable,
            busy: state.pending != 0,
            ranking: state.preferences.ranking,
            memory: state.preferences.memory,
            records,
            prefixes,
            error: state.error.clone(),
        }
    }
    pub fn snapshot(&self) -> Snapshot {
        let state = self.owner.state.lock().expect("usage state");
        if !state.ready || !state.writable {
            return Snapshot::default();
        }
        state
            .document
            .snapshot(state.preferences.ranking, state.preferences.memory, now())
    }
    /// Best effort and bounded: usage never stalls or changes an insertion result.
    pub fn record(&self, id: Uuid, event: Event, query: Option<&str>) {
        if let Some(sender) = &self.owner.sender {
            let _ = sender.try_send(Command::Record(id, event, query.and_then(prefix)));
        }
    }
    pub fn live_ids(&self, ids: HashSet<Uuid>) {
        if let Some(sender) = &self.owner.sender {
            let _ = sender.try_send(Command::Live(ids));
        }
    }
    fn edit(&self, command: Command) -> Result<()> {
        let mut state = self.owner.state.lock().expect("usage state");
        if !state.ready || !state.writable {
            return Err(state.error.clone().unwrap_or(BUSY));
        }
        self.owner
            .sender
            .as_ref()
            .ok_or(UNSAFE)?
            .try_send(command)
            .map_err(|_| BUSY)?;
        state.pending += 1;
        Ok(())
    }
    pub fn preferences(&self, ranking: bool, memory: bool) -> Result<()> {
        self.edit(Command::Preferences(Preferences {
            schema: 1,
            ranking,
            memory,
        }))
    }
    pub fn reset(&self, records: bool, bindings: bool) -> Result<()> {
        self.edit(Command::Reset(records, bindings))
    }
    pub fn flush(&self) -> mpsc::Receiver<Result<()>> {
        let (sender, receiver) = mpsc::sync_channel(1);
        if let Some(queue) = &self.owner.sender {
            if let Err(
                mpsc::TrySendError::Full(Command::Flush(reply))
                | mpsc::TrySendError::Disconnected(Command::Flush(reply)),
            ) = queue.try_send(Command::Flush(sender))
            {
                let _ = reply.send(Err(BUSY));
            }
        } else {
            let _ = sender.send(Ok(()));
        }
        receiver
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn private_directory(root: &Path) -> Result<PathBuf> {
    let directory = root.join("Usage");
    match fs::DirBuilder::new().mode(0o700).create(&directory) {
        Ok(()) => (),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(_) => return Err(UNSAFE),
    }
    let metadata = fs::symlink_metadata(&directory).map_err(|_| UNSAFE)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(UNSAFE);
    }
    Ok(directory)
}
fn private_file(file: &File, limit: usize) -> Result<()> {
    let metadata = file.metadata().map_err(|_| UNSAFE)?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > limit as u64
    {
        return Err(UNSAFE);
    }
    Ok(())
}
fn read(path: &Path, limit: usize) -> Result<Option<Vec<u8>>> {
    use std::io::Read;
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(UNSAFE),
    };
    private_file(&file, limit)?;
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| UNSAFE)?;
    if bytes.len() > limit {
        return Err(UNSAFE);
    }
    Ok(Some(bytes))
}
fn lock(directory: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(directory.join("usage.lock"))
        .map_err(|_| UNSAFE)?;
    private_file(&file, 0)?;
    let start = Instant::now();
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(file),
            Err(std::fs::TryLockError::WouldBlock)
                if start.elapsed() < Duration::from_millis(250) =>
            {
                thread::sleep(Duration::from_millis(5))
            }
            Err(_) => return Err(BUSY),
        }
    }
}
fn load(directory: &Path) -> Result<(Document, Preferences)> {
    let doc = read(&directory.join("usage.json"), LIMIT)?
        .map(|b| Document::decode(&b))
        .transpose()?
        .unwrap_or_else(|| Document::new(now()));
    let preferences = read(&directory.join("preferences.json"), 1024)?
        .map(|b| serde_json::from_slice::<Preferences>(&b).map_err(|_| UNSAFE))
        .transpose()?
        .unwrap_or_default();
    if preferences.schema != 1 {
        return Err(UNSAFE);
    }
    Ok((doc, preferences))
}
fn save(
    directory: &Path,
    document: &Document,
    baseline: Option<&Document>,
    preferences: Option<Preferences>,
    live: Option<&HashSet<Uuid>>,
) -> Result<(Document, Preferences)> {
    let _lock = lock(directory)?;
    // Recheck under the usage lock: a newer/corrupt file must not be overwritten after launch.
    let (disk, disk_preferences) = load(directory)?;
    // When our ancestor is unchanged, preserve intentional competitor decay.
    // A max join against that same ancestor would undo every learned correction.
    let mut merged = if baseline == Some(&disk) {
        document.clone()
    } else {
        document.clone().join(disk)
    };
    let next_preferences = preferences.unwrap_or(disk_preferences);
    if !next_preferences.memory && (merged.counts().1 != 0 || disk_preferences.memory) {
        merged.reset(false, true, now());
    }
    merged.prune(now(), live);
    let bytes = serde_json::to_vec(&merged).map_err(|_| UNSAFE)?;
    if bytes.len() > LIMIT {
        return Err(UNSAFE);
    }
    model::atomic_write(&directory.join("usage.json"), &bytes)?;
    if preferences.is_some() {
        // Erase prefixes durably before the disabled preference; interruption cannot retain them.
        let bytes = serde_json::to_vec(&next_preferences).map_err(|_| UNSAFE)?;
        model::atomic_write(&directory.join("preferences.json"), &bytes)?;
    }
    Ok((merged, next_preferences))
}
fn run(root: PathBuf, receiver: mpsc::Receiver<Command>, state: Arc<Mutex<State>>) {
    let loaded = private_directory(&root).and_then(|directory| {
        let _lock = lock(&directory)?;
        load(&directory).map(|(d, p)| (directory, d, p))
    });
    let (directory, mut document, mut preferences) = match loaded {
        Ok(value) => value,
        Err(error) => {
            let mut s = state.lock().expect("usage state");
            s.ready = true;
            s.error = Some(error);
            return;
        }
    };
    let mut baseline = document.clone();
    // If another process crashed during disabling, never expose persisted prefixes while disabled.
    let cleanup = !preferences.memory && document.counts().1 != 0;
    if cleanup {
        document.reset(false, true, now());
    }
    let publish = |document: &Document,
                   preferences: Preferences,
                   error: Option<Error>,
                   edit: bool,
                   clear_error: bool| {
        let mut s = state.lock().expect("usage state");
        s.document = document.clone();
        s.preferences = preferences;
        s.ready = true;
        s.writable = true;
        if error.is_some() || clear_error {
            s.error = error;
        }
        if edit {
            s.pending = s.pending.saturating_sub(1);
        }
    };
    publish(&document, preferences, None, false, true);
    let mut live = None;
    let mut last_recorded: Option<(Uuid, Event, Instant)> = None;
    let mut first_dirty: Option<Instant> = cleanup.then(Instant::now);
    let mut last_dirty = Instant::now();
    let mut pending_preferences = false;
    let mut unavailable: Option<Error> = None;
    loop {
        let timeout = first_dirty.map_or(Duration::from_secs(60), |first| {
            (last_dirty + DELAY)
                .min(first + CEILING)
                .saturating_duration_since(Instant::now())
        });
        let command = receiver.recv_timeout(timeout);
        if let Some(error) = &unavailable {
            match command {
                Ok(Command::Flush(reply)) => {
                    let _ = reply.send(Err(error.clone()));
                }
                Ok(Command::Preferences(_) | Command::Reset(_, _)) => {
                    let mut s = state.lock().expect("usage state");
                    s.pending = s.pending.saturating_sub(1);
                }
                Ok(Command::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => return,
                _ => (),
            }
            continue;
        }
        let mut immediate = false;
        let mut edit = false;
        let mut reply = None;
        let mut stop = false;
        match command {
            Ok(Command::Record(id, event, query)) => {
                let t = Instant::now();
                if last_recorded.is_some_and(|(old_id, old_event, old_time)| {
                    old_id == id
                        && old_event == event
                        && t.duration_since(old_time) < Duration::from_secs(1)
                }) {
                    continue;
                }
                last_recorded = Some((id, event, t));
                document.record(
                    id,
                    event,
                    preferences.memory.then_some(query.as_deref()).flatten(),
                    now(),
                );
                document.prune(now(), live.as_ref());
                first_dirty.get_or_insert(t);
                last_dirty = t;
            }
            Ok(Command::Preferences(next)) => {
                if preferences.memory && !next.memory {
                    document.reset(false, true, now());
                }
                preferences = next;
                pending_preferences = true;
                first_dirty.get_or_insert(Instant::now());
                immediate = true;
                edit = true;
            }
            Ok(Command::Reset(records, bindings)) => {
                document.reset(records, bindings, now());
                last_recorded = None;
                first_dirty.get_or_insert(Instant::now());
                immediate = true;
                edit = true;
            }
            Ok(Command::Live(ids)) => live = Some(ids),
            Ok(Command::Flush(sender)) => {
                immediate = true;
                reply = Some(sender);
            }
            Ok(Command::Stop) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                immediate = true;
                stop = true;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => immediate = first_dirty.is_some(),
        }
        // Publish toggles before I/O; disabling memory remains effective for this session on failure.
        publish(&document, preferences, None, false, false);
        let saving = immediate && first_dirty.is_some();
        let result = if saving {
            match save(
                &directory,
                &document,
                Some(&baseline),
                pending_preferences.then_some(preferences),
                live.as_ref(),
            ) {
                Ok((merged, p)) => {
                    baseline = merged.clone();
                    document = merged;
                    preferences = p;
                    pending_preferences = false;
                    first_dirty = None;
                    Ok(())
                }
                Err(error) => {
                    last_dirty = Instant::now();
                    first_dirty = Some(last_dirty);
                    Err(error)
                }
            }
        } else {
            Ok(())
        };
        publish(
            &document,
            preferences,
            result.clone().err(),
            edit,
            saving && result.is_ok(),
        );
        if let Err(error) = &result
            && (error == &UNSAFE || error.0.starts_with("Usage data"))
        {
            unavailable = Some(error.clone());
            first_dirty = None;
            state.lock().expect("usage state").writable = false;
        }
        if let Some(reply) = reply {
            let _ = reply.send(result);
        }
        if stop {
            return;
        }
    }
}

#[cfg(test)]
#[path = "usage_store_tests.rs"]
mod tests;
