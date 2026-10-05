//! Ordinary-only Fcitx bridge. The addon owns a backslash-started preedit;
//! no surrounding text, key stream, vault bodies or query is persisted.
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

const MAGIC: &[u8; 4] = b"SNI1";
const QUERY_LIMIT: usize = 480;
const FAILED: Error = Error("The inline input context is no longer available.");

struct Socket {
    listener: UnixListener,
    path: PathBuf,
    identity: (u64, u64),
}
impl Socket {
    fn bind() -> Result<Self> {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").ok_or(FAILED)?;
        let root = PathBuf::from(runtime);
        let metadata = fs::symlink_metadata(&root).map_err(|_| FAILED)?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            return Err(FAILED);
        }
        let path = root.join("snippets-inline.sock");
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
fn trusted_peer(stream: &UnixStream) -> bool {
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
    let expected = fs::metadata("/usr/bin/fcitx5");
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
fn rows(entries: &[Snippet]) -> Vec<u8> {
    let mut bytes = vec![entries.len() as u8];
    for entry in entries {
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
        }
    }
    bytes
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
    let target = crate::desktop::PasteTarget::capture().ok_or(FAILED)?;
    let checked = || {
        guard()?;
        if target.is_fresh() && target.is_active_unlocked() {
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
                    let metadata = if suggestions { rows(&entries) } else { vec![0] };
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
        let Ok(socket) = Socket::bind() else {
            report(Status::Unavailable);
            return;
        };
        report(Status::WaitingForFcitx);
        while guard().is_ok() {
            match socket.listener.accept() {
                Ok((mut stream, _)) => {
                    if !trusted_peer(&stream) {
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
                    if serve(&mut stream, &library, suggestions, &guard, usage.as_ref()).is_ok() {
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
        let bytes = rows(&[entry]);
        assert!(!bytes.windows(4).any(|w| w == b"BODY"));
        assert_eq!(bytes[0], 1);
    }
    #[test]
    fn bridge_authenticates_the_fcitx_process_and_refuses_large_frames() {
        let (mut client, mut server) = UnixStream::pair().unwrap();
        assert!(!trusted_peer(&server));
        client.write_all(b"SNI1\x01\xff\xff\xff\xff").unwrap();
        assert!(request(&mut server, &|| Ok(())).is_err());
    }
}
