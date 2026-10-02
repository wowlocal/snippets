//! One-use, freshly authenticated secure text delivery. No clipboard writes,
//! plaintext persistence, transport authority or automatic retry after a prefix.
use crate::{
    desktop::{SessionState, SessionWitness},
    model::{self, Error, Result},
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime},
};
use zeroize::Zeroizing;

const CANCELLED: Error = Error(
    "Secure insertion was cancelled. Any text already entered is kept; review the destination before trying again.",
);
const CHANGED: Error = Error("The saved secure snippet changed. Select it again before inserting.");
const UNSUPPORTED: Error =
    Error("This secure text contains unsupported control characters or is too large to insert.");
#[derive(Clone)]
pub struct Authorization {
    cancelled: Arc<AtomicBool>,
    witness: SessionWitness,
    epoch: u64,
    started: Duration,
    wall: SystemTime,
}
impl Authorization {
    pub fn new(witness: SessionWitness) -> Result<Self> {
        let (state, epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            return Err(CANCELLED);
        }
        Ok(Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            witness,
            epoch,
            started: crate::clock::uptime().ok_or(CANCELLED)?,
            wall: SystemTime::now(),
        })
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn validate(&self) -> Result<()> {
        self.validate_at(crate::clock::uptime().ok_or(CANCELLED)?, SystemTime::now())
    }
    fn validate_at(&self, now: Duration, wall: SystemTime) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire)
            || now < self.started
            || now - self.started >= Duration::from_secs(120)
            || wall
                .duration_since(self.wall)
                .map_or(true, |d| d >= Duration::from_secs(120))
            || self.witness.snapshot() != (SessionState::Unlocked, self.epoch)
        {
            return Err(CANCELLED);
        }
        Ok(())
    }
}
/// Fixed vault path only. Exact before/after file identity and ciphertext hash
/// admit the prepared record. Final-component links and hard links are refused.
pub(crate) struct Source {
    path: PathBuf,
    identity: [u64; 7],
    hash: [u8; 32],
}
fn identity(m: &fs::Metadata) -> Result<[u64; 7]> {
    if !m.is_file() || m.nlink() != 1 || m.len() > model::MAX_FILE_BYTES as u64 {
        return Err(CHANGED);
    }
    Ok([
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime() as u64,
        m.mtime_nsec() as u64,
        m.ctime() as u64,
        m.ctime_nsec() as u64,
    ])
}
impl Source {
    pub(crate) fn prove(root: &Path) -> Result<(Self, Zeroizing<Vec<u8>>)> {
        let path = root.join("Vault/vault.json");
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path)
            .map_err(|_| CHANGED)?;
        let before = identity(&file.metadata().map_err(|_| CHANGED)?)?;
        let mut bytes = Zeroizing::new(Vec::new());
        Read::by_ref(&mut file)
            .take(model::MAX_FILE_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| CHANGED)?;
        let source = Self {
            path,
            identity: before,
            hash: Sha256::digest(&bytes).into(),
        };
        if identity(&file.metadata().map_err(|_| CHANGED)?)? != before {
            return Err(CHANGED);
        }
        source.validate()?;
        Ok((source, bytes))
    }
    fn validate(&self) -> Result<()> {
        let metadata = fs::symlink_metadata(&self.path).map_err(|_| CHANGED)?;
        if metadata.file_type().is_symlink() || identity(&metadata)? != self.identity {
            return Err(CHANGED);
        }
        Ok(())
    }
    fn authenticate_current(&self) -> Result<()> {
        self.validate()?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&self.path)
            .map_err(|_| CHANGED)?;
        if identity(&file.metadata().map_err(|_| CHANGED)?)? != self.identity {
            return Err(CHANGED);
        }
        let mut bytes = Zeroizing::new(Vec::new());
        Read::by_ref(&mut file)
            .take(model::MAX_FILE_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| CHANGED)?;
        if identity(&file.metadata().map_err(|_| CHANGED)?)? != self.identity
            || Sha256::digest(&bytes).as_slice() != self.hash
        {
            return Err(CHANGED);
        }
        self.validate()
    }
}
/// This type cannot be cloned, serialized, debug-printed or constructed by a UI.
/// Ownership is consumed even when delivery fails. Drop erases all owned text.
pub(crate) struct Prepared {
    source: Source,
    body: Zeroizing<Vec<u8>>,
    authorization: Authorization,
}
impl Prepared {
    pub(crate) fn new(
        source: Source,
        body: Zeroizing<Vec<u8>>,
        authorization: Authorization,
    ) -> Result<Self> {
        authorization.validate()?;
        source.authenticate_current()?;
        validate_text(std::str::from_utf8(&body).map_err(|_| UNSUPPORTED)?)?;
        Ok(Self {
            source,
            body,
            authorization,
        })
    }
    pub(crate) fn needs_clipboard(&self) -> bool {
        std::str::from_utf8(&self.body).is_ok_and(|text| text.contains("{clipboard}"))
    }
    pub(crate) fn deliver<B: Backend>(self, backend: &mut B, clipboard: &str) -> Result<usize> {
        let Self {
            source,
            body,
            authorization,
        } = self;
        authorization.validate()?;
        let text = crate::placeholders::resolve_sensitive_at(
            std::str::from_utf8(&body).map_err(|_| UNSUPPORTED)?,
            clipboard,
            chrono::Local::now(),
        )?;
        drop(body);
        validate_text(&text)?;
        let guard = || {
            authorization.validate()?;
            source.validate()
        };
        source.authenticate_current()?;
        guard()?;
        backend.begin(&guard)?;
        let mut chars = text.chars().peekable();
        let mut entered = 0;
        while chars.peek().is_some() {
            let mut scalars = Zeroizing::new(Vec::<u32>::new());
            for _ in 0..240 {
                let Some(c) = chars.next() else {
                    break;
                };
                if c == '\r' && chars.peek() == Some(&'\n') {
                    chars.next();
                }
                scalars.push(if c == '\r' { '\n' as u32 } else { c as u32 });
            }
            let map = Keymap::new(&scalars)?;
            guard()?;
            backend.install(&map.bytes, &guard)?;
            for &scalar in scalars.iter() {
                guard()?;
                let code = map
                    .scalars
                    .iter()
                    .position(|&c| c == scalar)
                    .ok_or(UNSUPPORTED)? as u32
                    + 1;
                backend.key(code, &guard)?;
                entered += 1;
                guard()?;
            }
        }
        guard()?;
        source.authenticate_current()?;
        Ok(entered)
    }
}
fn validate_text(text: &str) -> Result<()> {
    if text.len() > model::MAX_BODY_BYTES
        || text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
    {
        return Err(UNSUPPORTED);
    }
    Ok(())
}
pub(crate) trait Backend {
    fn begin(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<()>;
    fn install(&mut self, map: &[u8], guard: &dyn Fn() -> Result<()>) -> Result<()>;
    fn key(&mut self, code: u32, guard: &dyn Fn() -> Result<()>) -> Result<()>;
}
struct Keymap {
    bytes: Zeroizing<Vec<u8>>,
    scalars: Zeroizing<Vec<u32>>,
}
impl Keymap {
    fn new(input: &[u32]) -> Result<Self> {
        use std::fmt::Write;
        let mut scalars = Zeroizing::new(Vec::new());
        for &c in input {
            if !scalars.contains(&c) {
                scalars.push(c);
            }
        }
        if scalars.is_empty() || scalars.len() > 240 {
            return Err(UNSUPPORTED);
        }
        let mut map = Zeroizing::new(String::from(
            "xkb_keymap { xkb_keycodes { minimum = 9; maximum = 255; ",
        ));
        for index in 0..scalars.len() {
            write!(map, "<K{index:03}> = {}; ", index + 9).map_err(|_| UNSUPPORTED)?;
        }
        map.push_str("}; xkb_types { type \"ONE_LEVEL\" { modifiers = None; level_name[Level1] = \"Any\"; }; }; xkb_compatibility {}; xkb_symbols { ");
        for (index, &scalar) in scalars.iter().enumerate() {
            let symbol = match scalar {
                10 => 0xff0d,
                9 => 0xff09,
                n if n < 0x100 => n,
                n => 0x0100_0000 | n,
            };
            write!(
                map,
                "key <K{index:03}> {{ type = \"ONE_LEVEL\", [ 0x{symbol:08x} ] }}; "
            )
            .map_err(|_| UNSUPPORTED)?;
        }
        map.push_str("}; };\0");
        if map.len() > 65536 {
            return Err(UNSUPPORTED);
        }
        Ok(Self {
            bytes: Zeroizing::new(map.as_bytes().to_vec()),
            scalars,
        })
    }
}
#[cfg(test)]
#[path = "secure_insertion_tests.rs"]
mod tests;
#[cfg(feature = "desktop")]
#[path = "secure_insertion_wayland.rs"]
pub(crate) mod wayland;
