//! Ordinary-only input-method bridge. The authenticated helper owns preedit;
//! The transport retains no surrounding text, key stream or vault bodies.
//! Successful choices follow the existing bounded local prefix-learning policy.
use super::*;
use std::{
    io::{Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    time::Instant,
};

const MAGIC: &[u8; 4] = b"SNI3";
const QUERY_LIMIT: usize = 480;
const FAILED: Error = Error("The inline input context is no longer available.");

#[derive(Clone, Copy)]
pub(super) enum Backend {
    #[cfg(feature = "fcitx")]
    Fcitx,
    #[cfg(feature = "ibus")]
    IBus,
}
impl Backend {
    fn socket_name(self) -> &'static str {
        match self {
            #[cfg(feature = "fcitx")]
            Self::Fcitx => "snippets-inline.sock",
            #[cfg(feature = "ibus")]
            Self::IBus => "snippets-ibus.sock",
        }
    }
    fn executable(self) -> Option<PathBuf> {
        match self {
            #[cfg(feature = "fcitx")]
            Self::Fcitx => Some("/usr/bin/fcitx5".into()),
            #[cfg(feature = "ibus")]
            Self::IBus => Some(
                std::env::current_exe()
                    .ok()?
                    .parent()?
                    .join("snippets-ibus"),
            ),
        }
    }
    fn waiting(self) -> Status {
        match self {
            #[cfg(feature = "fcitx")]
            Self::Fcitx => Status::WaitingForFcitx,
            #[cfg(feature = "ibus")]
            Self::IBus => Status::WaitingForIBus,
        }
    }
}

struct Socket {
    listener: UnixListener,
    path: PathBuf,
    identity: (u64, u64),
}
impl Socket {
    fn bind(backend: Backend) -> Result<Self> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").ok_or(FAILED)?;
        let root = PathBuf::from(runtime);
        let metadata = fs::symlink_metadata(&root).map_err(|_| FAILED)?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            return Err(FAILED);
        }
        let path = root.join(backend.socket_name());
        if let Ok(metadata) = fs::symlink_metadata(&path) {
            if !metadata.file_type().is_socket()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.mode() & 0o777 != 0o600
                || !matches!(UnixStream::connect(&path), Err(e) if e.kind() == std::io::ErrorKind::ConnectionRefused)
            {
                return Err(FAILED);
            }
            fs::remove_file(&path).map_err(|_| FAILED)?;
        }
        let listener = UnixListener::bind(&path).map_err(|_| FAILED)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|_| FAILED)?;
        listener.set_nonblocking(true).map_err(|_| FAILED)?;
        let metadata = fs::symlink_metadata(&path).map_err(|_| FAILED)?;
        Ok(Self {
            listener,
            path,
            identity: (metadata.dev(), metadata.ino()),
        })
    }
}
impl Drop for Socket {
    fn drop(&mut self) {
        if fs::symlink_metadata(&self.path).is_ok_and(|m| (m.dev(), m.ino()) == self.identity) {
            let _ = fs::remove_file(&self.path);
        }
    }
}
fn trusted_peer(stream: &UnixStream, backend: Backend) -> bool {
    let mut peer = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut size = std::mem::size_of_val(&peer) as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut peer as *mut libc::ucred).cast(),
            &mut size,
        )
    } != 0
        || size as usize != std::mem::size_of_val(&peer)
        || peer.pid <= 0
        || peer.uid != unsafe { libc::geteuid() }
    {
        return false;
    }
    let Some(expected) = backend.executable() else {
        return false;
    };
    let expected = fs::metadata(expected);
    let actual = fs::metadata(format!("/proc/{}/exe", peer.pid));
    matches!((expected,actual), (Ok(a),Ok(b)) if a.is_file() && (a.dev(),a.ino())==(b.dev(),b.ino()))
}
fn read_exact(
    stream: &mut UnixStream,
    data: &mut [u8],
    guard: &dyn Fn() -> Result<()>,
) -> Result<()> {
    let start = Instant::now();
    let mut offset = 0;
    while offset < data.len() {
        guard()?;
        match stream.read(&mut data[offset..]) {
            Ok(0) => return Err(FAILED),
            Ok(n) => offset += n,
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if start.elapsed() > Duration::from_secs(120) {
                    return Err(FAILED);
                }
            }
            Err(_) => return Err(FAILED),
        }
    }
    guard()
}
fn request(
    stream: &mut UnixStream,
    guard: &dyn Fn() -> Result<()>,
) -> Result<(u8, Zeroizing<Vec<u8>>)> {
    let mut header = [0; 9];
    read_exact(stream, &mut header, guard)?;
    let length = u32::from_le_bytes(header[5..].try_into().map_err(|_| FAILED)?) as usize;
    if &header[..4] != MAGIC || length > QUERY_LIMIT || header[4] > 3 {
        return Err(FAILED);
    }
    let mut bytes = Zeroizing::new(vec![0; length]);
    read_exact(stream, &mut bytes, guard)?;
    Ok((header[4], bytes))
}
fn response(
    stream: &mut UnixStream,
    kind: u8,
    bytes: &[u8],
    guard: &dyn Fn() -> Result<()>,
) -> Result<()> {
    guard()?;
    stream
        .write_all(MAGIC)
        .and_then(|_| stream.write_all(&[kind]))
        .and_then(|_| stream.write_all(&(bytes.len() as u32).to_le_bytes()))
        .and_then(|_| stream.write_all(bytes))
        .map_err(|_| FAILED)?;
    guard()
}
fn query(bytes: &[u8]) -> Result<&str> {
    let text = std::str::from_utf8(bytes).map_err(|_| FAILED)?;
    if text.len() > QUERY_LIMIT
        || text.graphemes(true).take(121).count() > 120
        || text
            .chars()
            .any(|c| c == '\\' || c.is_whitespace() || c.is_control())
    {
        return Err(FAILED);
    }
    Ok(text)
}
fn rows(entries: &[Snippet], query: &str, palette: [u8; 10]) -> Vec<u8> {
    let mut bytes = vec![entries.len() as u8];
    bytes.extend_from_slice(&palette);
    for entry in entries {
        // Record identities are local to this authenticated transport; they are
        // never displayed, logged or persisted by the addon.
        bytes.extend_from_slice(entry.id.as_bytes());
        for (value, bound) in [
            (
                if entry.name.trim().is_empty() {
                    &entry.keyword
                } else {
                    &entry.name
                },
                512,
            ),
            (&entry.keyword, 256),
        ] {
            let value = crate::inline_expansion::suggestions::bounded(value, bound);
            bytes.extend_from_slice(&(value.len() as u16).to_le_bytes());
            bytes.extend_from_slice(value.as_bytes());
            let ranges = crate::inline_expansion::suggestions::highlights(&value, query);
            bytes.push(ranges.len().min(128) as u8);
            for (start, end) in ranges.into_iter().take(128) {
                bytes.extend_from_slice(&(start as u16).to_le_bytes());
                bytes.extend_from_slice(&(end as u16).to_le_bytes());
            }
        }
        bytes.push(entry.tags.len().min(2) as u8);
        bytes.extend_from_slice(&(entry.tags.len().min(999) as u16).to_le_bytes());
        for tag in entry.tags.iter().take(2) {
            let tag = crate::inline_expansion::suggestions::bounded(tag, 64);
            bytes.push(tag.len() as u8);
            bytes.extend_from_slice(tag.as_bytes());
        }
    }
    bytes
}
fn palette(data: &str) -> [u8; 10] {
    let colors = data.parse::<toml::Table>().unwrap_or_default();
    let dark = colors.get("mode").and_then(toml::Value::as_str) != Some("light");
    let color = |key: &str, fallback: [u8; 3]| {
        colors
            .get(key)
            .and_then(toml::Value::as_str)
            .filter(|s| s.len() == 7 && s.starts_with('#'))
            .and_then(|s| {
                Some([
                    u8::from_str_radix(s.get(1..3)?, 16).ok()?,
                    u8::from_str_radix(s.get(3..5)?, 16).ok()?,
                    u8::from_str_radix(s.get(5..7)?, 16).ok()?,
                ])
            })
            .unwrap_or(fallback)
    };
    let mut result = [0; 10];
    result[0] = u8::from(dark);
    result[1..4].copy_from_slice(&color(
        "background",
        if dark { [43, 43, 43] } else { [242, 242, 242] },
    ));
    result[4..7].copy_from_slice(&color(
        "foreground",
        if dark { [245, 245, 245] } else { [25, 25, 25] },
    ));
    result[7..10].copy_from_slice(&color("accent", [0, 122, 255]));
    result
}
fn current_palette() -> [u8; 10] {
    let mut data = String::new();
    let _ = crate::desktop::theme_path()
        .and_then(|p| fs::File::open(p).ok())
        .map(|f| f.take(16 * 1024).read_to_string(&mut data));
    palette(&data)
}
fn clipboard(guard: &dyn Fn() -> Result<()>) -> Result<Zeroizing<String>> {
    let start = Instant::now();
    let checked = || {
        guard()?;
        if start.elapsed() >= Duration::from_millis(350) {
            Err(CLIPBOARD)
        } else {
            Ok(())
        }
    };
    let mut reader = crate::clipboard_history::wayland::Reader::open(&checked)?;
    if !crate::desktop::wayland_peer_matches(reader.peer_process()) {
        return Err(CLIPBOARD);
    }
    while reader.generation() == 0 {
        reader.next(0, &checked)?;
    }
    let generation = reader.generation();
    let formats = reader.formats()?;
    if formats.is_empty() {
        return Ok(Zeroizing::new(String::new()));
    }
    let mime = ["text/plain;charset=utf-8", "text/plain"]
        .into_iter()
        .find(|m| formats.iter().any(|f| f == m))
        .ok_or(CLIPBOARD)?;
    reader.receive_text(generation, mime, &checked)
}
fn deliver(
    stream: &mut UnixStream,
    library: &Library,
    entry: &Snippet,
    guard: &dyn Fn() -> Result<()>,
) -> Result<()> {
    let clip = if entry.content.contains("{clipboard}") {
        clipboard(guard)?
    } else {
        Zeroizing::new(String::new())
    };
    let body =
        crate::placeholders::resolve_sensitive_at(&entry.content, &clip, chrono::Local::now())?;
    if body.contains('\0') {
        return Err(FAILED);
    }
    guard()?;
    let _lock = library.try_lock()?;
    if library.read_locked()?.0.iter().find(|s| s.id == entry.id) != Some(entry) {
        return Err(FAILED);
    }
    response(stream, 2, body.as_bytes(), guard)
}
fn serve(
    backend: Backend,
    stream: &mut UnixStream,
    library: &Library,
    suggestions: bool,
    guard: &dyn Fn() -> Result<()>,
    usage: Option<&crate::usage_store::Handle>,
) -> Result<()> {
    let (kind, bytes) = request(stream, guard)?;
    if kind == 0 && bytes.is_empty() {
        return response(stream, 3, &[], guard);
    }
    if kind != 1 {
        return Err(FAILED);
    }
    let target = match backend {
        #[cfg(feature = "fcitx")]
        Backend::Fcitx => Some(crate::desktop::PasteTarget::capture().ok_or(FAILED)?),
        // The authenticated IBus helper commits through its engine's focused
        // input context, guarded by a generation across focus/reset/content-type
        // changes. It never asks this process to type into an arbitrary window.
        #[cfg(feature = "ibus")]
        Backend::IBus => None::<crate::desktop::PasteTarget>,
    };
    let checked = || {
        guard()?;
        if target
            .as_ref()
            .is_none_or(|target| target.is_fresh() && target.is_active_unlocked())
        {
            Ok(())
        } else {
            Err(FAILED)
        }
    };
    let ranking = usage.map_or_else(crate::usage::Snapshot::default, |u| u.snapshot());
    let mut next = (kind, bytes);
    let mut entries = Vec::new();
    let mut current_query = Zeroizing::new(String::new());
    loop {
        checked()?;
        let (kind, bytes) = next;
        let (entry, selected) = match kind {
            1 => {
                current_query = Zeroizing::new(query(&bytes)?.into());
                let ordinary = {
                    let _lock = library.try_lock()?;
                    library.read_locked()?.0
                };
                let exact = matching(&ordinary, &current_query).cloned();
                if let Some(entry) = exact {
                    (entry, false)
                } else {
                    entries = ordinary
                        .into_iter()
                        .filter(|s| {
                            crate::inline_expansion::suggestions::matches(s, &current_query)
                        })
                        .collect();
                    ranking.rank(&mut entries, &current_query);
                    entries.truncate(8);
                    let metadata = rows(
                        if suggestions { &entries } else { &[] },
                        &current_query,
                        current_palette(),
                    );
                    response(stream, 1, &metadata, &checked)?;
                    // Socket fragments contain no host context. Observe consent/lock
                    // while reading, and validate the receiving window once per
                    // complete request and again at publication/commit boundaries.
                    next = request(stream, guard)?;
                    continue;
                }
            }
            2 if suggestions && bytes.len() == 1 => {
                (entries.get(bytes[0] as usize).cloned().ok_or(FAILED)?, true)
            }
            _ => return Err(FAILED),
        };
        deliver(stream, library, &entry, &checked)?;
        let (ack, bytes) = request(stream, guard)?;
        checked()?;
        if ack != 3 || !bytes.is_empty() {
            return Err(FAILED);
        }
        if let Some(usage) = usage {
            usage.record(
                entry.id,
                crate::usage::Event::Expansion,
                selected.then_some(current_query.as_str()),
            );
        }
        return Ok(());
    }
}
pub(super) fn run(
    backend: Backend,
    root: PathBuf,
    witness: SessionWitness,
    stop: Arc<AtomicBool>,
    sender: mpsc::SyncSender<Status>,
    usage: Option<crate::usage_store::Handle>,
) {
    let Ok(library) = Library::prepare(root.clone()) else {
        let _ = sender.try_send(Status::Unavailable);
        return;
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
    while !stop.load(Ordering::Acquire) && Preference::read(&root).is_ok_and(|p| p.enabled) {
        let (state, epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            report(Status::WaitingForUnlock);
            thread::park_timeout(Duration::from_millis(100));
            continue;
        }
        let suggestions = Preference::read(&root).is_ok_and(|p| p.suggestions);
        let guard = || {
            if stop.load(Ordering::Acquire)
                || witness.snapshot() != (SessionState::Unlocked, epoch)
                || std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") != signature
                || std::env::var_os("WAYLAND_DISPLAY") != display
                || std::env::var_os("XDG_RUNTIME_DIR") != runtime
                || !Preference::read(&root).is_ok_and(|p| p.enabled && p.suggestions == suggestions)
            {
                Err(STOPPED)
            } else {
                Ok(())
            }
        };
        let Ok(socket) = Socket::bind(backend) else {
            report(Status::Unavailable);
            return;
        };
        report(backend.waiting());
        while guard().is_ok() {
            match socket.listener.accept() {
                Ok((mut stream, _)) => {
                    if !trusted_peer(&stream, backend) {
                        continue;
                    }
                    if stream
                        .set_read_timeout(Some(Duration::from_millis(50)))
                        .is_err()
                        || stream
                            .set_write_timeout(Some(Duration::from_millis(350)))
                            .is_err()
                    {
                        continue;
                    }
                    if serve(
                        backend,
                        &mut stream,
                        &library,
                        suggestions,
                        &guard,
                        usage.as_ref(),
                    )
                    .is_ok()
                    {
                        report(Status::WaitingForField);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::park_timeout(Duration::from_millis(20))
                }
                Err(_) => {
                    report(Status::Unavailable);
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[cfg(feature = "fcitx")]
    fn native_fcitx_state_preserves_public_preedit_and_releases_private_fields() {
        let temporary = tempfile::tempdir().unwrap();
        let result = std::process::Command::new(env!("SNIPPETS_FCITX_STATE_FIXTURE"))
            .env("XDG_CONFIG_HOME", temporary.path().join("config"))
            .env("XDG_DATA_HOME", temporary.path().join("data"))
            .env("XDG_CACHE_HOME", temporary.path().join("cache"))
            .env("XDG_RUNTIME_DIR", temporary.path())
            .env_remove("DISPLAY")
            .env_remove("WAYLAND_DISPLAY")
            .env_remove("DBUS_SESSION_BUS_ADDRESS")
            .output()
            .unwrap();
        assert!(result.status.success(), "native Fcitx state fixture failed");
        assert_eq!(
            result.stdout,
            b"state fixture: 8 modifier, 6 capability, 6 selection/protocol and 2 panel, 4 mouse placement, 3 input method switch and 5 async IPC checks passed\n"
        );
    }
    #[test]
    fn a_changed_or_removed_choice_cannot_deliver_its_previous_body() {
        let temporary = tempfile::tempdir().unwrap();
        let library = Library::prepare(temporary.path().join("Public bridge library")).unwrap();
        let mut choice = Snippet::new("Public choice", "Public original body");
        choice.keyword = "public".into();
        for changed in [true, false] {
            let current = if changed {
                let mut current = choice.clone();
                current.content = "Public changed body".into();
                vec![current]
            } else {
                vec![]
            };
            model::atomic_write(&library.path(), &serde_json::to_vec(&current).unwrap()).unwrap();
            let (mut server, client) = UnixStream::pair().unwrap();
            assert!(deliver(&mut server, &library, &choice, &|| Ok(())).is_err());
            client.set_nonblocking(true).unwrap();
            let mut byte = [0];
            assert!(
                matches!((&client).read(&mut byte), Err(e) if e.kind()==std::io::ErrorKind::WouldBlock)
            );
        }
    }
    #[test]
    fn bridge_rejects_non_query_text_and_never_exposes_bodies_in_rows() {
        for value in ["\\x", "a b", "a\n", "\0"] {
            assert!(query(value.as_bytes()).is_err());
        }
        assert!(query("a".repeat(121).as_bytes()).is_err());
        assert!(query("тест".as_bytes()).is_ok());
        let mut entry = Snippet::new("Public name", "BODY_MUST_NOT_LEAVE_IN_METADATA");
        entry.keyword = "publickeyword".into();
        let identity = entry.id;
        entry.tags = vec!["Public tag".into(), "Second tag".into(), "Extra tag".into()];
        let bytes = rows(&[entry], "public", palette(""));
        assert!(!bytes.windows(4).any(|w| w == b"BODY"));
        assert_eq!(bytes[0], 1);
        assert_eq!(&bytes[11..27], identity.as_bytes());
        assert!(bytes.windows(10).any(|w| w == b"Public tag"));
        assert!(!bytes.windows(9).any(|w| w == b"Extra tag"));
        assert_eq!(
            palette("mode='light'\nbackground='#ffffff'")[..4],
            [0, 255, 255, 255]
        );
        assert_eq!(palette("accent='bad'")[7..], [0, 122, 255]);
    }
    #[test]
    fn bridge_authenticates_the_backend_process_and_refuses_large_frames() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        #[cfg(feature = "fcitx")]
        assert!(!trusted_peer(&server, Backend::Fcitx));
        #[cfg(feature = "ibus")]
        assert!(!trusted_peer(&server, Backend::IBus));
        client.write_all(b"SNI3\x01\xff\xff\xff\xff").unwrap();
        assert!(request(&mut server, &|| Ok(())).is_err());
    }
    #[test]
    fn bridge_rejects_the_previous_row_protocol_before_taking_input() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        client.write_all(b"SNI2\x01\0\0\0\0").unwrap();
        assert!(request(&mut server, &|| Ok(())).is_err());
    }
}
