//! App-mediated CLI requests. Metadata JSON and zeroizing secret bytes have separate frames.
//! No decryption keys, arbitrary errors, bodies or caller paths enter diagnostics.
use crate::model::{self, Error, Result};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use uuid::Uuid;
use zeroize::Zeroizing;

#[path = "control_peer.rs"]
mod peer;
pub(crate) use peer::Lease;
#[cfg(feature = "desktop")]
#[path = "control_server.rs"]
pub(crate) mod server;

pub const PROTOCOL: u32 = 1;
const MAX_HEADER: usize = 24 * 1024;
pub(crate) const TIMEOUT: Duration = Duration::from_secs(120);
pub(crate) const INVALID: Error =
    Error("The app and CLI could not complete a valid control request.");
pub(crate) const REFUSED: Error = Error(
    "The control peer could not be verified. Restart Snippets with the matching installed CLI.",
);
pub(crate) const CLOSED: Error =
    Error("Snippets is unavailable or closed the request. Open the app and try again.");

/// Only an unavailable initial connection is the app-not-running exit code.
pub fn unavailable(error: &Error) -> bool {
    error.0 == CLOSED.0
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    Ok,
    Denied,
    Locked,
    NotFound,
    Refused,
    Unsupported,
    Error,
}
impl Status {
    pub fn exit_code(self) -> u8 {
        match self {
            Self::Ok => 0,
            Self::Denied => 4,
            Self::Locked => 5,
            Self::NotFound => 6,
            Self::Unsupported => 7,
            _ => 1,
        }
    }
    pub fn message(self) -> &'static str {
        match self {
            Self::Ok => "Request completed.",
            Self::Denied => "The request was not approved, expired or was cancelled.",
            Self::Locked => {
                "Set up Secure Snippets in the app, then use fresh vault credentials to approve this request."
            }
            Self::NotFound => "No unique secure snippet matches that keyword or identifier.",
            Self::Refused => {
                "The request was refused. Check the pending app prompt, duplicate keyword or changed library before retrying."
            }
            Self::Unsupported => {
                "Update the app and CLI together; the control protocol is unsupported."
            }
            Self::Error => {
                "The request could not be confirmed. Check the library before retrying; no automatic retry was made."
            }
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Addition {
    pub name: String,
    pub keyword: String,
    pub tags: Vec<String>,
    pub is_enabled: bool,
    pub is_pinned: bool,
}
impl Addition {
    pub fn validate(&self) -> Result<()> {
        if self.name.len() > 1024
            || self.keyword.len() > 256
            || model::keyword(&self.keyword).is_empty()
            || self.tags.len() > 64
            || self.tags.iter().any(|s| s.len() > 256)
            || [&self.name, &self.keyword]
                .into_iter()
                .chain(self.tags.iter())
                .any(|s| s.contains('\0'))
        {
            return Err(INVALID);
        }
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Header {
    pub v: u32,
    pub nonce: Uuid,
    pub command: String,
    pub identifier: Option<String>,
    pub addition: Option<Addition>,
    pub bytes: usize,
}
impl Header {
    pub(crate) fn validate(&self) -> Result<()> {
        if self.nonce.is_nil() || self.command.len() > 32 || self.bytes > model::MAX_BODY_BYTES {
            return Err(INVALID);
        }
        match self.command.as_str() {
            "status" if self.identifier.is_none() && self.addition.is_none() && self.bytes == 0 => {
                Ok(())
            }
            "reveal"
                if self
                    .identifier
                    .as_ref()
                    .is_some_and(|s| !s.is_empty() && s.len() <= 256 && !s.contains('\0'))
                    && self.addition.is_none()
                    && self.bytes == 0 =>
            {
                Ok(())
            }
            "add-secure" if self.identifier.is_none() && self.bytes > 0 => {
                self.addition.as_ref().ok_or(INVALID)?.validate()
            }
            _ => Err(INVALID),
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct ReplyHeader {
    pub v: u32,
    pub nonce: Uuid,
    pub status: Status,
    pub bytes: usize,
    pub secure_count: Option<usize>,
    pub unlocked: Option<bool>,
    pub created_id: Option<Uuid>,
}
#[cfg(any(test, feature = "desktop"))]
pub(crate) struct Reply {
    pub header: ReplyHeader,
    pub body: Zeroizing<Vec<u8>>,
    pub delivery: Option<crate::vault::control::Delivery>,
}
#[cfg(any(test, feature = "desktop"))]
impl Reply {
    pub(crate) fn status(nonce: Uuid, status: Status) -> Self {
        Self {
            header: ReplyHeader {
                v: PROTOCOL,
                nonce,
                status,
                bytes: 0,
                secure_count: None,
                unlocked: None,
                created_id: None,
            },
            body: Zeroizing::new(Vec::new()),
            delivery: None,
        }
    }
}

pub(crate) fn read_header<T: DeserializeOwned>(
    stream: &mut impl Read,
    guard: &dyn Fn() -> Result<()>,
) -> Result<T> {
    let mut size = [0; 4];
    read_exact(stream, &mut size, guard)?;
    let size = u32::from_be_bytes(size) as usize;
    if size == 0 || size > MAX_HEADER {
        return Err(INVALID);
    }
    let mut bytes = Zeroizing::new(vec![0; size]);
    read_exact(stream, &mut bytes, guard)?;
    serde_json::from_slice(&bytes).map_err(|_| INVALID)
}
pub(crate) fn write_header<T: Serialize>(
    stream: &mut impl Write,
    header: &T,
    guard: &dyn Fn() -> Result<()>,
) -> Result<()> {
    let bytes = serde_json::to_vec(header).map_err(|_| INVALID)?;
    if bytes.is_empty() || bytes.len() > MAX_HEADER {
        return Err(INVALID);
    }
    write_all(stream, &(bytes.len() as u32).to_be_bytes(), guard)?;
    write_all(stream, &bytes, guard)
}
pub(crate) fn read_body(
    stream: &mut impl Read,
    count: usize,
    guard: &dyn Fn() -> Result<()>,
) -> Result<Zeroizing<Vec<u8>>> {
    if count > model::MAX_BODY_BYTES {
        return Err(INVALID);
    }
    let mut bytes = Zeroizing::new(vec![0; count]);
    read_exact(stream, &mut bytes, guard)?;
    if std::str::from_utf8(&bytes).is_err() || bytes.contains(&0) {
        return Err(INVALID);
    }
    Ok(bytes)
}
fn read_exact(
    stream: &mut impl Read,
    mut bytes: &mut [u8],
    guard: &dyn Fn() -> Result<()>,
) -> Result<()> {
    while !bytes.is_empty() {
        guard()?;
        let take = bytes.len().min(4096);
        match stream.read(&mut bytes[..take]) {
            Ok(0) => return Err(CLOSED),
            Ok(n) => bytes = &mut bytes[n..],
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(_) => return Err(CLOSED),
        }
    }
    guard()
}
pub(crate) fn write_all(
    stream: &mut impl Write,
    mut bytes: &[u8],
    guard: &dyn Fn() -> Result<()>,
) -> Result<()> {
    while !bytes.is_empty() {
        guard()?;
        let take = bytes.len().min(4096);
        match stream.write(&bytes[..take]) {
            Ok(0) => return Err(CLOSED),
            Ok(n) => bytes = &bytes[n..],
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(_) => return Err(CLOSED),
        }
    }
    guard()
}

/// The CLI verifies the installed app's kernel peer identity before reading secure input.
pub struct Client {
    stream: std::fs::File,
    lease: Lease,
}
pub enum Outcome {
    Revealed(Zeroizing<Vec<u8>>),
    Created(Uuid),
    State { count: usize, unlocked: bool },
    Rejected(Status),
}
impl Client {
    pub fn check(&self) -> Result<()> {
        self.lease.check()
    }
    pub fn connect(root: &Path) -> Result<Self> {
        let path = endpoint(root)?;
        let stream = connect(&path).map_err(|_| CLOSED)?;
        stream.set_nonblocking(true).map_err(|_| CLOSED)?;
        let lease = Lease::verified(
            &stream,
            peer::Image::sibling("snippets")?,
            std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            false,
        )?;
        Ok(Self {
            stream: local_io(stream),
            lease,
        })
    }
    pub fn reveal(mut self, identifier: String) -> Result<Outcome> {
        self.exchange(
            Header {
                v: PROTOCOL,
                nonce: Uuid::new_v4(),
                command: "reveal".into(),
                identifier: Some(identifier),
                addition: None,
                bytes: 0,
            },
            &[],
        )
    }
    pub fn status(mut self) -> Result<Outcome> {
        self.exchange(
            Header {
                v: PROTOCOL,
                nonce: Uuid::new_v4(),
                command: "status".into(),
                identifier: None,
                addition: None,
                bytes: 0,
            },
            &[],
        )
    }
    pub fn add(mut self, addition: Addition, body: Zeroizing<Vec<u8>>) -> Result<Outcome> {
        self.exchange(
            Header {
                v: PROTOCOL,
                nonce: Uuid::new_v4(),
                command: "add-secure".into(),
                identifier: None,
                addition: Some(addition),
                bytes: body.len(),
            },
            &body,
        )
    }
    fn exchange(&mut self, header: Header, body: &[u8]) -> Result<Outcome> {
        header.validate()?;
        self.lease.check()?;
        write_header(&mut self.stream, &header, &|| self.lease.check())?;
        write_all(&mut self.stream, body, &|| self.lease.check())?;
        let reply: ReplyHeader = read_header(&mut self.stream, &|| self.lease.check())?;
        if reply.v != PROTOCOL {
            return Ok(Outcome::Rejected(Status::Unsupported));
        }
        if reply.nonce != header.nonce || reply.bytes > model::MAX_BODY_BYTES {
            return Err(INVALID);
        }
        if reply.status != Status::Ok {
            if reply.bytes != 0
                || reply.created_id.is_some()
                || reply.secure_count.is_some()
                || reply.unlocked.is_some()
            {
                return Err(INVALID);
            }
            return Ok(Outcome::Rejected(reply.status));
        }
        match header.command.as_str() {
            "reveal"
                if reply.created_id.is_none()
                    && reply.secure_count.is_none()
                    && reply.unlocked.is_none() =>
            {
                Ok(Outcome::Revealed(read_body(
                    &mut self.stream,
                    reply.bytes,
                    &|| self.lease.check(),
                )?))
            }
            "add-secure"
                if reply.bytes == 0 && reply.secure_count.is_none() && reply.unlocked.is_none() =>
            {
                reply
                    .created_id
                    .filter(|id| !id.is_nil())
                    .map(Outcome::Created)
                    .ok_or(INVALID)
            }
            "status" if reply.bytes == 0 && reply.created_id.is_none() => {
                match (reply.secure_count, reply.unlocked) {
                    (Some(count), Some(unlocked)) if count <= model::MAX_SNIPPETS => {
                        Ok(Outcome::State { count, unlocked })
                    }
                    _ => Err(INVALID),
                }
            }
            _ => Err(INVALID),
        }
    }
}
// Framed local IPC uses descriptor read/write, with nonblocking/deadline checks above.
// Rust executable startup ignores SIGPIPE; a disconnected pipe returns a safe IO error.
pub(crate) fn local_io(stream: std::os::unix::net::UnixStream) -> std::fs::File {
    std::fs::File::from(std::os::fd::OwnedFd::from(stream))
}
pub(crate) fn endpoint(root: &Path) -> Result<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or(CLOSED)?;
    endpoint_at(root, &runtime)
}
fn endpoint_at(root: &Path, runtime: &Path) -> Result<PathBuf> {
    if !runtime.is_absolute() {
        return Err(REFUSED);
    }
    peer::private_directory(runtime)?;
    let absolute = if root.is_absolute() {
        root.to_path_buf()
    } else {
        std::env::current_dir().map_err(|_| CLOSED)?.join(root)
    };
    use sha2::{Digest, Sha256};
    use std::os::unix::ffi::OsStrExt;
    let digest = Sha256::digest(absolute.as_os_str().as_bytes());
    let name: String = digest[..12]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let path = runtime
        .join("snippets-control")
        .join(format!("{name}.sock"));
    if path.as_os_str().as_bytes().len() >= 108 {
        return Err(CLOSED);
    }
    Ok(path)
}
pub(crate) fn deadline(start: Instant) -> Result<()> {
    if start.elapsed() >= TIMEOUT {
        Err(CLOSED)
    } else {
        Ok(())
    }
}
fn connect(path: &Path) -> std::io::Result<std::os::unix::net::UnixStream> {
    use std::os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::ffi::OsStrExt,
    };
    let bytes = path.as_os_str().as_bytes();
    let mut address = unsafe { std::mem::zeroed::<libc::sockaddr_un>() };
    if bytes.is_empty() || bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (to, from) in address.sun_path.iter_mut().zip(bytes) {
        *to = *from as libc::c_char;
    }
    let descriptor = unsafe {
        libc::socket(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            0,
        )
    };
    if descriptor < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let length =
        (std::mem::offset_of!(libc::sockaddr_un, sun_path) + bytes.len() + 1) as libc::socklen_t;
    if unsafe {
        libc::connect(
            descriptor.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            length,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(std::os::unix::net::UnixStream::from(descriptor))
}

#[cfg(test)]
#[path = "control_tests.rs"]
mod tests;
