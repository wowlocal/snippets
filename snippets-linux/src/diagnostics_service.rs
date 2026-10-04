//! Desktop-only persistence. One primary-process owner; no keyring or library reads.
use crate::diagnostics::{self, Count, Event, Sink};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::{CString, OsStr},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            ffi::OsStrExt,
            fs::{MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
pub(crate) const FILE_LIMIT: u64 = 1024 * 1024;
pub(crate) const FILE_COUNT: usize = 64;
pub(crate) const QUOTA: u64 = 24 * 1024 * 1024;
pub(crate) const EXPORT_LIMIT: usize = 25 * 1024 * 1024;
const RETENTION: Duration = Duration::from_secs(14 * 24 * 60 * 60);
const ROLL_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const LINE_LIMIT: usize = 4096;
const ELAPSED_LIMIT: u64 = 365 * 24 * 60 * 60 * 1000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Error {
    Unavailable,
    UnsafeInput,
    Corrupt,
    TooLarge,
    Destination,
    Changed,
    Stopped,
}
impl Error {
    pub(crate) fn message(self) -> &'static str {
        match self {
            Self::Unavailable => "Diagnostic storage is unavailable.",
            Self::UnsafeInput => "A diagnostic file could not be accessed safely.",
            Self::Corrupt => "A diagnostic record has an invalid schema; no export was written.",
            Self::TooLarge => "Diagnostics exceed the export size limit.",
            Self::Destination => "Choose a regular destination outside Snippets app data.",
            Self::Changed => "Diagnostic files or the destination changed. Try exporting again.",
            Self::Stopped => "Diagnostics are stopping or unavailable.",
        }
    }
}
type Result<T> = std::result::Result<T, Error>;
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Summary {
    pub files: usize,
    pub bytes: u64,
    pub dropped: u64,
}
#[derive(Clone, Copy, Debug)]
pub(crate) struct Exported {
    pub records: usize,
    pub bytes: usize,
    pub skipped: usize,
}
enum Command {
    Record(Event, Option<mpsc::SyncSender<Result<()>>>),
    Summary(mpsc::SyncSender<Result<Summary>>),
    Export(PathBuf, mpsc::SyncSender<Result<Exported>>),
    Delete(mpsc::SyncSender<Result<Summary>>),
    #[cfg(test)]
    Flush(mpsc::SyncSender<Result<()>>),
}
pub(crate) struct Service {
    root: PathBuf,
    sender: mpsc::SyncSender<Command>,
    stopping: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
    lost: Arc<AtomicU64>,
}
static SHARED: OnceLock<Arc<Service>> = OnceLock::new();
static INITIALIZE: Mutex<()> = Mutex::new(());
impl Service {
    pub(crate) fn shared(root: PathBuf) -> Result<Arc<Self>> {
        let _guard = INITIALIZE.lock().map_err(|_| Error::Unavailable)?;
        if let Some(service) = SHARED.get() {
            return if service.root == root && !service.stopping.load(Ordering::Acquire) {
                Ok(service.clone())
            } else {
                Err(Error::Unavailable)
            };
        }
        let service = Self::start(root, true)?;
        if !diagnostics::install(service.clone()) {
            service.stop();
            return Err(Error::Unavailable);
        }
        SHARED
            .set(service.clone())
            .map_err(|_| Error::Unavailable)?;
        Ok(service)
    }
    /// Tests pass mirror=false and never install their instance in the facade.
    pub(crate) fn start(root: PathBuf, mirror: bool) -> Result<Arc<Self>> {
        let (sender, receiver) = mpsc::sync_channel(256);
        let stopping = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(AtomicBool::new(false));
        let lost = Arc::new(AtomicU64::new(0));
        let service = Arc::new(Self {
            root: root.clone(),
            sender,
            stopping: stopping.clone(),
            finished: finished.clone(),
            lost: lost.clone(),
        });
        std::thread::Builder::new()
            .name("snippets-diagnostics".into())
            .spawn(move || {
                let mut driver = Driver::open(root, mirror);
                let mut reported_loss = 0;
                loop {
                    let command = match receiver.recv_timeout(Duration::from_millis(100)) {
                        Ok(command) => command,
                        Err(mpsc::RecvTimeoutError::Timeout)
                            if !stopping.load(Ordering::Acquire) =>
                        {
                            if let Ok(driver) = &mut driver {
                                let _ = driver.maintain_if_due();
                            }
                            continue;
                        }
                        Err(_) => break,
                    };
                    if let Ok(driver) = &mut driver {
                        let loss = lost.load(Ordering::Relaxed);
                        if loss != reported_loss {
                            let count = Count::new(
                                loss.saturating_sub(reported_loss).min(usize::MAX as u64) as usize,
                            );
                            if driver.write(Event::QueueLoss { count }).is_ok() {
                                reported_loss = loss;
                            }
                        }
                    }
                    match command {
                        Command::Record(event, reply) => {
                            let result =
                                driver.as_mut().map_err(|e| *e).and_then(|d| d.write(event));
                            if let Some(reply) = reply {
                                let _ = reply.send(result);
                            }
                        }
                        Command::Summary(reply) => {
                            let _ = reply.send(
                                driver
                                    .as_mut()
                                    .map_err(|e| *e)
                                    .and_then(|d| d.summary())
                                    .map(|mut s| {
                                        s.dropped = lost.load(Ordering::Relaxed);
                                        s
                                    }),
                            );
                        }
                        Command::Export(path, reply) => {
                            let _ = reply.send(
                                driver
                                    .as_mut()
                                    .map_err(|e| *e)
                                    .and_then(|d| d.export(&path)),
                            );
                        }
                        Command::Delete(reply) => {
                            let _ = reply
                                .send(driver.as_mut().map_err(|e| *e).and_then(|d| d.delete()));
                        }
                        #[cfg(test)]
                        Command::Flush(reply) => {
                            let _ =
                                reply.send(driver.as_mut().map_err(|e| *e).and_then(|d| d.flush()));
                        }
                    }
                }
                if let Ok(driver) = &mut driver {
                    let _ = driver.flush();
                }
                finished.store(true, Ordering::Release);
            })
            .map_err(|_| Error::Unavailable)?;
        Ok(service)
    }
    fn request<T>(
        &self,
        command: impl FnOnce(mpsc::SyncSender<Result<T>>) -> Command,
    ) -> Result<T> {
        if self.stopping.load(Ordering::Acquire) {
            return Err(Error::Stopped);
        }
        let (sender, receiver) = mpsc::sync_channel(1);
        self.sender
            .send(command(sender))
            .map_err(|_| Error::Stopped)?;
        receiver.recv().map_err(|_| Error::Stopped)?
    }
    pub(crate) fn summary(&self) -> Result<Summary> {
        self.request(Command::Summary)
    }
    pub(crate) fn export(&self, path: PathBuf) -> Result<Exported> {
        self.request(|reply| Command::Export(path, reply))
    }
    pub(crate) fn delete(&self) -> Result<Summary> {
        self.request(Command::Delete)
    }
    #[cfg(test)]
    pub(crate) fn flush(&self) -> Result<()> {
        self.request(Command::Flush)
    }
    pub(crate) fn stop(&self) {
        self.stopping.store(true, Ordering::Release);
    }
    pub(crate) fn finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }
}
impl Sink for Service {
    fn record(&self, event: Event) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        if !event.synchronous() {
            if self.sender.try_send(Command::Record(event, None)).is_err() {
                self.lost.fetch_add(1, Ordering::Relaxed);
            }
            return;
        }
        // Terminal facts wait for fsync, but a broken disk cannot block a caller forever.
        let deadline = Instant::now() + Duration::from_secs(2);
        let (sender, receiver) = mpsc::sync_channel(1);
        let mut command = Command::Record(event, Some(sender));
        loop {
            match self.sender.try_send(command) {
                Ok(()) => {
                    let _ =
                        receiver.recv_timeout(deadline.saturating_duration_since(Instant::now()));
                    return;
                }
                Err(mpsc::TrySendError::Full(returned)) if Instant::now() < deadline => {
                    command = returned;
                    std::thread::sleep(Duration::from_millis(2));
                }
                Err(_) => {
                    self.lost.fetch_add(1, Ordering::Relaxed);
                    return;
                }
            }
        }
    }
}

fn cstring(name: &OsStr) -> Result<CString> {
    CString::new(name.as_bytes()).map_err(|_| Error::UnsafeInput)
}
fn open_at(parent: &File, name: &OsStr, flags: i32, mode: u32) -> Result<File> {
    let name = cstring(name)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            mode,
        )
    };
    if fd < 0 {
        Err(Error::UnsafeInput)
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}
fn identity(info: &fs::Metadata) -> (u64, u64) {
    (info.dev(), info.ino())
}
fn regular(file: &File, private: bool) -> Result<fs::Metadata> {
    let info = file.metadata().map_err(|_| Error::UnsafeInput)?;
    if !info.is_file()
        || info.nlink() != 1
        || info.uid() != unsafe { libc::geteuid() }
        || (private && info.mode() & 0o077 != 0)
    {
        return Err(Error::UnsafeInput);
    }
    Ok(info)
}
fn private_regular(file: &File) -> Result<fs::Metadata> {
    regular(file, true)
}
fn directory(parent: &File, name: &str) -> Result<File> {
    let name_c = CString::new(name).unwrap();
    if unsafe { libc::mkdirat(parent.as_raw_fd(), name_c.as_ptr(), 0o700) } != 0
        && std::io::Error::last_os_error().kind() != std::io::ErrorKind::AlreadyExists
    {
        return Err(Error::Unavailable);
    }
    let file = open_at(
        parent,
        OsStr::new(name),
        libc::O_RDONLY | libc::O_DIRECTORY,
        0,
    )?;
    let info = file.metadata().map_err(|_| Error::Unavailable)?;
    if info.uid() != unsafe { libc::geteuid() } {
        return Err(Error::UnsafeInput);
    }
    if unsafe { libc::fchmod(file.as_raw_fd(), 0o700) } != 0 {
        return Err(Error::Unavailable);
    }
    Ok(file)
}
fn owned_name(name: &str) -> bool {
    name.strip_prefix("snippets-")
        .and_then(|s| s.strip_suffix(".jsonl"))
        .and_then(|s| {
            uuid::Uuid::parse_str(s)
                .ok()
                .map(|id| id.to_string() == s && id.get_version() == Some(uuid::Version::Random))
        })
        .unwrap_or(false)
}
fn timestamp() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Record {
    schema: u8,
    timestamp: String,
    elapsed_ms: u64,
    session_id: String,
    sequence: u64,
    level: String,
    category: String,
    event: String,
    fields: serde_json::Value,
}
fn line(event: Event, session: &str, sequence: u64, elapsed_ms: u64) -> Result<Vec<u8>> {
    let value = serde_json::to_value(event).map_err(|_| Error::Corrupt)?;
    let record = Record {
        schema: 1,
        timestamp: timestamp(),
        elapsed_ms: elapsed_ms.min(ELAPSED_LIMIT),
        session_id: session.into(),
        sequence,
        level: event.level().into(),
        category: event.category().into(),
        event: value["event"].as_str().ok_or(Error::Corrupt)?.into(),
        fields: value["fields"].clone(),
    };
    let mut bytes = serde_json::to_vec(&record).map_err(|_| Error::Corrupt)?;
    if bytes.len() > LINE_LIMIT {
        return Err(Error::TooLarge);
    }
    bytes.push(b'\n');
    Ok(bytes)
}
fn validate(bytes: &[u8]) -> Result<Record> {
    if bytes.is_empty() || bytes.len() > LINE_LIMIT {
        return Err(Error::Corrupt);
    }
    // The wire parser rejects duplicate keys before serde can discard a shadowed field.
    crate::canonical::parse(bytes).map_err(|_| Error::Corrupt)?;
    let record: Record = serde_json::from_slice(bytes).map_err(|_| Error::Corrupt)?;
    let time = DateTime::parse_from_rfc3339(&record.timestamp).map_err(|_| Error::Corrupt)?;
    let session = uuid::Uuid::parse_str(&record.session_id).map_err(|_| Error::Corrupt)?;
    if record.schema != 1
        || record.timestamp.len() != 24
        || time.offset().local_minus_utc() != 0
        || time.to_rfc3339_opts(SecondsFormat::Millis, true) != record.timestamp
        || record.elapsed_ms > ELAPSED_LIMIT
        || session.get_version() != Some(uuid::Version::Random)
        || session.to_string() != record.session_id
        || record.sequence == 0
    {
        return Err(Error::Corrupt);
    }
    let value = serde_json::json!({"event":record.event,"fields":record.fields});
    let event: Event = serde_json::from_value(value.clone()).map_err(|_| Error::Corrupt)?;
    if event.category() != record.category
        || event.level() != record.level
        || serde_json::to_value(event).map_err(|_| Error::Corrupt)? != value
    {
        return Err(Error::Corrupt);
    }
    Ok(record)
}
struct Active {
    name: String,
    file: File,
    bytes: u64,
    started: Instant,
}
struct Driver {
    root_path: PathBuf,
    root: File,
    diagnostics: File,
    logs: File,
    _lock: File,
    active: Option<Active>,
    session: String,
    started: Instant,
    sequence: u64,
    maintained: Instant,
    mirror: bool,
    file_limit: u64,
    file_count: usize,
    quota: u64,
}
impl Driver {
    fn open(root_path: PathBuf, mirror: bool) -> Result<Self> {
        let root = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&root_path)
            .map_err(|_| Error::Unavailable)?;
        if root.metadata().map_err(|_| Error::Unavailable)?.uid() != unsafe { libc::geteuid() } {
            return Err(Error::UnsafeInput);
        }
        let diagnostics = directory(&root, "Diagnostics")?;
        let lock = open_at(
            &diagnostics,
            OsStr::new(".owner.lock"),
            libc::O_RDWR | libc::O_CREAT,
            0o600,
        )?;
        private_regular(&lock)?;
        lock.try_lock().map_err(|_| Error::Unavailable)?;
        let logs = directory(&diagnostics, "Logs")?;
        let mut driver = Self {
            root_path,
            root,
            diagnostics,
            logs,
            _lock: lock,
            active: None,
            session: uuid::Uuid::new_v4().to_string(),
            started: Instant::now(),
            sequence: 0,
            maintained: Instant::now(),
            mirror,
            file_limit: FILE_LIMIT,
            file_count: FILE_COUNT,
            quota: QUOTA,
        };
        driver.maintain()?;
        Ok(driver)
    }
    fn bound(&self) -> Result<()> {
        let root = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(&self.root_path)
            .map_err(|_| Error::UnsafeInput)?;
        let diagnostics = open_at(
            &self.root,
            OsStr::new("Diagnostics"),
            libc::O_RDONLY | libc::O_DIRECTORY,
            0,
        )?;
        let logs = open_at(
            &self.diagnostics,
            OsStr::new("Logs"),
            libc::O_RDONLY | libc::O_DIRECTORY,
            0,
        )?;
        for (current, held) in [
            (&root, &self.root),
            (&diagnostics, &self.diagnostics),
            (&logs, &self.logs),
        ] {
            let info = current.metadata().map_err(|_| Error::UnsafeInput)?;
            if identity(&info) != identity(&held.metadata().map_err(|_| Error::UnsafeInput)?)
                || info.mode() & 0o077 != 0
            {
                return Err(Error::UnsafeInput);
            }
        }
        let current_lock = open_at(
            &self.diagnostics,
            OsStr::new(".owner.lock"),
            libc::O_RDONLY,
            0,
        )?;
        if identity(&private_regular(&current_lock)?) != identity(&private_regular(&self._lock)?) {
            return Err(Error::Changed);
        }
        Ok(())
    }
    fn entries(&self) -> Result<Vec<(String, fs::Metadata)>> {
        self.bound()?;
        let mut entries: Vec<(String, fs::Metadata)> = Vec::new();
        for (index, item) in fs::read_dir(format!("/proc/self/fd/{}", self.logs.as_raw_fd()))
            .map_err(|_| Error::Unavailable)?
            .enumerate()
        {
            if index >= 4096 {
                return Err(Error::TooLarge);
            }
            let name = item.map_err(|_| Error::UnsafeInput)?.file_name();
            let Some(name) = name.to_str().filter(|n| owned_name(n)) else {
                continue;
            };
            let file = open_at(&self.logs, OsStr::new(name), libc::O_RDONLY, 0)?;
            entries.push((name.into(), private_regular(&file)?));
        }
        entries.sort_by_key(|(name, m)| (m.mtime(), m.mtime_nsec(), name.clone()));
        Ok(entries)
    }
    fn unlink(&self, name: &str, before: &fs::Metadata) -> Result<()> {
        self.bound()?;
        let current = open_at(&self.logs, OsStr::new(name), libc::O_RDONLY, 0)?;
        if !unchanged(&private_regular(&current)?, before) {
            return Err(Error::Changed);
        }
        let name = CString::new(name).map_err(|_| Error::UnsafeInput)?;
        if unsafe { libc::unlinkat(self.logs.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            return Err(Error::Unavailable);
        }
        Ok(())
    }
    fn maintain(&mut self) -> Result<()> {
        let entries = self.entries()?;
        let mut count = entries.len();
        let mut total = entries.iter().try_fold(0u64, |n, (_, m)| {
            n.checked_add(m.len()).ok_or(Error::TooLarge)
        })?;
        let now = std::time::SystemTime::now();
        for (name, info) in &entries {
            let expired = info
                .modified()
                .ok()
                .and_then(|at| now.duration_since(at).ok())
                .is_some_and(|age| age >= RETENTION);
            if expired
                || count > self.file_count
                || total > self.quota
                || info.len() > self.file_limit
            {
                self.unlink(name, info)?;
                if self.active.as_ref().is_some_and(|a| &a.name == name) {
                    self.active.take();
                }
                count -= 1;
                total -= info.len();
            }
        }
        self.logs.sync_all().map_err(|_| Error::Unavailable)?;
        self.maintained = Instant::now();
        Ok(())
    }
    fn maintain_if_due(&mut self) -> Result<()> {
        if self.maintained.elapsed() >= Duration::from_secs(60) {
            self.maintain()?;
        }
        Ok(())
    }
    fn flush(&mut self) -> Result<()> {
        self.bound()?;
        if let Some(active) = &self.active {
            active.file.sync_all().map_err(|_| Error::Unavailable)?;
        }
        Ok(())
    }
    fn write(&mut self, event: Event) -> Result<()> {
        self.bound()?;
        self.sequence = self.sequence.checked_add(1).ok_or(Error::Unavailable)?;
        let bytes = line(
            event,
            &self.session,
            self.sequence,
            self.started
                .elapsed()
                .as_millis()
                .min(ELAPSED_LIMIT as u128) as u64,
        )?;
        if self.active.as_ref().is_some_and(|a| {
            a.bytes + bytes.len() as u64 > self.file_limit || a.started.elapsed() >= ROLL_AGE
        }) {
            self.flush()?;
            self.active.take();
        }
        if self.active.is_none() {
            let name = format!("snippets-{}.jsonl", uuid::Uuid::new_v4());
            let file = open_at(
                &self.logs,
                OsStr::new(&name),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
                0o600,
            )?;
            self.active = Some(Active {
                name,
                file,
                bytes: 0,
                started: Instant::now(),
            });
        }
        let active = self.active.as_mut().unwrap();
        let info = private_regular(&active.file)?;
        let current = open_at(&self.logs, OsStr::new(&active.name), libc::O_RDONLY, 0)?;
        if identity(&private_regular(&current)?) != identity(&info) || info.len() != active.bytes {
            return Err(Error::Changed);
        }
        if active.file.write_all(&bytes).is_err() {
            self.active.take();
            return Err(Error::Unavailable);
        }
        active.bytes += bytes.len() as u64;
        if event.synchronous() {
            self.flush()?;
        }
        // Mirror exactly the already sanitized JSON; never send an original error.
        if self.mirror {
            let bytes = CString::new(&bytes[..bytes.len() - 1]).map_err(|_| Error::Corrupt)?;
            let priority = if event.level() == "error" {
                libc::LOG_ERR
            } else if event.level() == "warning" {
                libc::LOG_WARNING
            } else {
                libc::LOG_INFO
            };
            unsafe {
                libc::syslog(priority, c"%s".as_ptr(), bytes.as_ptr());
            }
        }
        self.maintain()?;
        Ok(())
    }
    fn summary(&mut self) -> Result<Summary> {
        self.maintain()?;
        let entries = self.entries()?;
        Ok(Summary {
            files: entries.len(),
            bytes: entries.iter().map(|(_, m)| m.len()).sum(),
            dropped: 0,
        })
    }
    fn read(&self, name: &str) -> Result<(fs::Metadata, Vec<u8>)> {
        let mut file = open_at(&self.logs, OsStr::new(name), libc::O_RDONLY, 0)?;
        let before = private_regular(&file)?;
        if before.len() > FILE_LIMIT {
            return Err(Error::TooLarge);
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(FILE_LIMIT + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Unavailable)?;
        if bytes.len() > FILE_LIMIT as usize {
            return Err(Error::TooLarge);
        }
        let after = private_regular(&file)?;
        if !unchanged(&before, &after) {
            return Err(Error::Changed);
        }
        let current = open_at(&self.logs, OsStr::new(name), libc::O_RDONLY, 0)?;
        if !unchanged(&after, &private_regular(&current)?) {
            return Err(Error::Changed);
        }
        Ok((after, bytes))
    }
    fn export(&mut self, path: &Path) -> Result<Exported> {
        self.flush()?;
        let target = Target::capture(path, &self.root_path)?;
        let entries = self.entries()?;
        if entries.len() > FILE_COUNT
            || entries.iter().try_fold(0usize, |n, (_, m)| {
                n.checked_add(m.len().try_into().map_err(|_| Error::TooLarge)?)
                    .ok_or(Error::TooLarge)
            })? > EXPORT_LIMIT
        {
            return Err(Error::TooLarge);
        }
        let mut records = Vec::new();
        let mut source_bytes = 0usize;
        let mut skipped = 0usize;
        let mut sources = Vec::new();
        for (name, _) in &entries {
            let (info, bytes) = self.read(name)?;
            source_bytes = source_bytes
                .checked_add(bytes.len())
                .filter(|n| *n <= EXPORT_LIMIT)
                .ok_or(Error::TooLarge)?;
            sources.push((name, info, Sha256::digest(&bytes)));
            let mut complete = bytes.as_slice();
            if !complete.is_empty() && complete.last() != Some(&b'\n') {
                let cut = complete
                    .iter()
                    .rposition(|b| *b == b'\n')
                    .map_or(0, |i| i + 1);
                let trailing = &complete[cut..];
                // A valid last JSON object with no newline is not a torn record.
                if let Ok(record) = validate(trailing) {
                    records.push(record);
                } else if serde_json::from_slice::<serde_json::Value>(trailing)
                    .is_err_and(|e| e.is_eof())
                {
                    skipped += 1;
                } else {
                    return Err(Error::Corrupt);
                }
                complete = &complete[..cut];
            }
            if !complete.is_empty() {
                for raw in complete[..complete.len() - 1].split(|b| *b == b'\n') {
                    records.push(validate(raw)?);
                }
            }
        }
        let mut seen = std::collections::HashSet::new();
        for record in &records {
            if !seen.insert((&record.session_id, record.sequence)) {
                return Err(Error::Corrupt);
            }
        }
        records.sort_by(|a, b| {
            (&a.timestamp, &a.session_id, a.sequence).cmp(&(
                &b.timestamp,
                &b.session_id,
                b.sequence,
            ))
        });
        let mut output = serde_json::to_vec(&serde_json::json!({
            "schema":1,"timestamp":timestamp(),"elapsed_ms":0,"session_id":"export","sequence":0,
            "level":"info","category":"diagnostics","event":"diagnostics_manifest",
            "fields":{"platform":"linux","app_version":env!("CARGO_PKG_VERSION"),"file_count":entries.len(),"record_count":records.len(),"byte_count":source_bytes,"skipped_trailing_lines":skipped}
        })).map_err(|_| Error::Corrupt)?;
        output.push(b'\n');
        for record in &records {
            serde_json::to_writer(&mut output, record).map_err(|_| Error::Corrupt)?;
            output.push(b'\n');
            if output.len() > EXPORT_LIMIT {
                return Err(Error::TooLarge);
            }
        }
        self.bound()?;
        for (name, info, digest) in sources {
            let (current, bytes) = self.read(name)?;
            if !unchanged(&info, &current) || Sha256::digest(bytes) != digest {
                return Err(Error::Changed);
            }
        }
        target.publish(&output)?;
        Ok(Exported {
            records: records.len(),
            bytes: output.len(),
            skipped,
        })
    }
    fn delete(&mut self) -> Result<Summary> {
        self.flush()?;
        let entries = self.entries()?;
        let summary = Summary {
            files: entries.len(),
            bytes: entries.iter().map(|(_, m)| m.len()).sum(),
            dropped: 0,
        };
        self.active.take();
        for (name, info) in entries {
            self.unlink(&name, &info)?;
        }
        self.logs.sync_all().map_err(|_| Error::Unavailable)?;
        Ok(summary)
    }
}
fn unchanged(a: &fs::Metadata, b: &fs::Metadata) -> bool {
    identity(a) == identity(b)
        && (
            a.len(),
            a.mtime(),
            a.mtime_nsec(),
            a.ctime(),
            a.ctime_nsec(),
        ) == (
            b.len(),
            b.mtime(),
            b.mtime_nsec(),
            b.ctime(),
            b.ctime_nsec(),
        )
}
struct Target {
    parent_path: PathBuf,
    parent: File,
    name: CString,
    before: Option<(fs::Metadata, [u8; 32])>,
}
impl Target {
    fn capture(path: &Path, root: &Path) -> Result<Self> {
        let parent_path = path
            .parent()
            .filter(|p| p.is_absolute())
            .ok_or(Error::Destination)?
            .to_path_buf();
        let resolved = parent_path.canonicalize().map_err(|_| Error::Destination)?;
        let root = root.canonicalize().map_err(|_| Error::Destination)?;
        if resolved.starts_with(&root) {
            return Err(Error::Destination);
        }
        let name = path.file_name().ok_or(Error::Destination)?;
        let parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&parent_path)
            .map_err(|_| Error::Destination)?;
        let before = Self::snapshot(&parent, name)?;
        Ok(Self {
            parent_path,
            parent,
            name: cstring(name)?,
            before,
        })
    }
    fn snapshot(parent: &File, name: &OsStr) -> Result<Option<(fs::Metadata, [u8; 32])>> {
        let name_c = cstring(name)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name_c.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return if std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound {
                Ok(None)
            } else {
                Err(Error::Destination)
            };
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        let before = regular(&file, false).map_err(|_| Error::Destination)?;
        if before.len() > EXPORT_LIMIT as u64 {
            return Err(Error::Destination);
        }
        let mut hash = Sha256::new();
        let mut buffer = [0u8; 8192];
        let mut length = 0;
        loop {
            let n = file.read(&mut buffer).map_err(|_| Error::Destination)?;
            if n == 0 {
                break;
            }
            length += n;
            if length > EXPORT_LIMIT {
                return Err(Error::Destination);
            }
            hash.update(&buffer[..n]);
        }
        if !unchanged(&before, &regular(&file, false)?) {
            return Err(Error::Changed);
        }
        Ok(Some((before, hash.finalize().into())))
    }
    fn publish(self, bytes: &[u8]) -> Result<()> {
        let temporary =
            CString::new(format!(".snippets-diagnostics-{}", uuid::Uuid::new_v4())).unwrap();
        let mut file = open_at(
            &self.parent,
            OsStr::from_bytes(temporary.to_bytes()),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
            0o600,
        )
        .map_err(|_| Error::Destination)?;
        let result = (|| {
            file.write_all(bytes)
                .and_then(|_| file.sync_all())
                .map_err(|_| Error::Destination)?;
            let current_parent = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
                .open(&self.parent_path)
                .map_err(|_| Error::Changed)?;
            if identity(&current_parent.metadata().map_err(|_| Error::Changed)?)
                != identity(&self.parent.metadata().map_err(|_| Error::Changed)?)
            {
                return Err(Error::Changed);
            }
            let current = Self::snapshot(&self.parent, OsStr::from_bytes(self.name.to_bytes()))?;
            let same = match (&self.before, &current) {
                (None, None) => true,
                (Some((a, x)), Some((b, y))) => unchanged(a, b) && x == y,
                _ => false,
            };
            if !same || private_regular(&file).is_err() {
                return Err(Error::Changed);
            }
            let flags = if self.before.is_none() {
                libc::RENAME_NOREPLACE
            } else {
                0
            };
            if unsafe {
                libc::renameat2(
                    self.parent.as_raw_fd(),
                    temporary.as_ptr(),
                    self.parent.as_raw_fd(),
                    self.name.as_ptr(),
                    flags,
                )
            } != 0
            {
                return Err(Error::Destination);
            }
            self.parent.sync_all().map_err(|_| Error::Destination)
        })();
        if result.is_err() {
            unsafe {
                libc::unlinkat(self.parent.as_raw_fd(), temporary.as_ptr(), 0);
            }
        }
        result
    }
}

#[cfg(test)]
#[path = "diagnostics_service_tests.rs"]
mod tests;
