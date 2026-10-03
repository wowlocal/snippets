//! Process-local, single-use authority for sensitive library-key operations.
//! Native PAM runs in a bounded unprivileged helper. Nothing is cached or persisted.
use crate::{
    desktop::{SessionState, SessionWitness},
    key_store::KeyBinding,
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, SystemTime},
};
#[cfg(any(test, feature = "local-auth"))]
use zeroize::Zeroizing;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Unavailable,
    Denied,
    AccountRestricted,
    WrongIdentity,
    UnsupportedConversation,
    InvalidCredential,
    InvalidState,
    WrongTarget,
    Cancelled,
    DesktopUnavailable,
    Expired,
    Timeout,
    Protocol,
}
pub type Result<T> = std::result::Result<T, Failure>;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    RevealRecovery,
    ReplaceRecovery,
    ApprovePairing,
    SwitchLibrary,
    CancelLibrarySwitch,
    FinishLocalLibrarySwitch,
    RestoreSavedChanges,
    ResumeSavedChanges,
    CancelSavedChanges,
    RemoveSavedHistory,
    ResumeHistoryRemoval,
    RemoveUnusedRecoveryFiles,
    ResumeRecoveryFileCleanup,
}
/// A closed owning-boundary target, including exact saved intent/version bytes.
/// Fingerprints/bindings never enter logs or serialization.
#[derive(Clone, PartialEq, Eq)]
pub struct Target {
    binding: KeyBinding,
    purpose: Purpose,
    generation: i64,
    digest: [u8; 32],
}
impl Target {
    pub(crate) fn new(
        binding: KeyBinding,
        purpose: Purpose,
        generation: i64,
        digest: [u8; 32],
    ) -> Result<Self> {
        if generation < 1 {
            return Err(Failure::InvalidState);
        }
        Ok(Self {
            binding,
            purpose,
            generation,
            digest,
        })
    }
    pub fn purpose(&self) -> Purpose {
        self.purpose
    }
}
const REQUEST_LIFETIME: Duration = Duration::from_secs(60);
#[cfg(feature = "local-auth")]
const NATIVE_LIFETIME: Duration = Duration::from_secs(20);
struct Context {
    epoch: Arc<AtomicU64>,
    generation: u64,
    witness: SessionWitness,
    desktop_epoch: u64,
    wall: SystemTime,
    uptime: Duration,
}
impl Context {
    fn check(&self) -> Result<()> {
        self.check_at(
            SystemTime::now(),
            crate::clock::uptime().ok_or(Failure::Unavailable)?,
        )
    }
    fn check_at(&self, wall: SystemTime, uptime: Duration) -> Result<()> {
        if self.epoch.load(Ordering::Acquire) != self.generation {
            return Err(Failure::Cancelled);
        }
        if self.witness.snapshot() != (SessionState::Unlocked, self.desktop_epoch) {
            return Err(Failure::DesktopUnavailable);
        }
        if wall >= self.wall || uptime >= self.uptime {
            return Err(Failure::Expired);
        }
        Ok(())
    }
}
pub struct Request {
    context: Context,
    nonce: [u8; 16],
    target: Target,
}
impl Request {
    /// A pending native dialog may close promptly when its exact authority ends.
    pub fn check(&self) -> Result<()> {
        self.context.check()
    }
}
pub struct Authenticated {
    request: Request,
}
pub struct Permit {
    context: Context,
    target: Target,
}
/// Authority for one already consumed target. The owning operation must recheck
/// it after waits and before disclosure or a signed send. It closes on
/// backgrounding, desktop lock, cancellation and either deadline.
pub(crate) struct AuthorizationLease(Context);
impl AuthorizationLease {
    pub(crate) fn check(&self) -> Result<()> {
        self.0.check()
    }
}
impl Permit {
    pub(crate) fn consume(self, expected: &Target) -> Result<AuthorizationLease> {
        self.context.check()?;
        if &self.target != expected {
            return Err(Failure::WrongTarget);
        }
        Ok(AuthorizationLease(self.context))
    }
}
pub struct Gate {
    epoch: Arc<AtomicU64>,
    foreground: bool,
    pending: Option<[u8; 16]>,
}
impl Default for Gate {
    fn default() -> Self {
        Self::new()
    }
}
impl Gate {
    pub fn new() -> Self {
        Self {
            epoch: Arc::new(AtomicU64::new(0)),
            foreground: false,
            pending: None,
        }
    }
    /// The owning GTK scene calls this synchronously on every focus/background edge.
    pub fn set_foreground(&mut self, foreground: bool) {
        if !foreground {
            self.cancel();
        }
        self.foreground = foreground;
    }
    pub fn cancel(&mut self) {
        self.pending = None;
        if self
            .epoch
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| {
                v.checked_add(1).filter(|next| *next < u64::MAX)
            })
            .is_err()
        {
            self.epoch.store(u64::MAX, Ordering::Release);
        }
    }
    pub fn begin(&mut self, target: Target, witness: SessionWitness) -> Result<Request> {
        self.cancel();
        if !self.foreground {
            return Err(Failure::Cancelled);
        }
        let generation = self.epoch.load(Ordering::Acquire);
        if generation == u64::MAX {
            return Err(Failure::InvalidState);
        }
        let (state, desktop_epoch) = witness.snapshot();
        if state != SessionState::Unlocked {
            return Err(Failure::DesktopUnavailable);
        }
        let nonce = crate::crypto::random().map_err(|_| Failure::Unavailable)?;
        let request = Request {
            context: Context {
                epoch: self.epoch.clone(),
                generation,
                witness,
                desktop_epoch,
                wall: SystemTime::now()
                    .checked_add(REQUEST_LIFETIME)
                    .ok_or(Failure::Unavailable)?,
                uptime: crate::clock::uptime()
                    .ok_or(Failure::Unavailable)?
                    .checked_add(REQUEST_LIFETIME)
                    .ok_or(Failure::Unavailable)?,
            },
            nonce,
            target,
        };
        request.context.check()?;
        self.pending = Some(nonce);
        Ok(request)
    }
    pub fn accept(&mut self, authenticated: Authenticated) -> Result<Permit> {
        let request = authenticated.request;
        request.context.check()?;
        if !self.foreground
            || self.pending != Some(request.nonce)
            || !Arc::ptr_eq(&self.epoch, &request.context.epoch)
        {
            return Err(Failure::Cancelled);
        }
        self.pending = None;
        Ok(Permit {
            context: request.context,
            target: request.target,
        })
    }
}
impl Drop for Gate {
    fn drop(&mut self) {
        self.cancel();
    }
}
#[cfg(any(test, feature = "local-auth"))]
fn validate_credential(password: &[u8]) -> Result<()> {
    if password.is_empty() || password.len() > 4096 || password.contains(&0) {
        return Err(Failure::InvalidCredential);
    }
    Ok(())
}
#[cfg(any(test, feature = "local-auth"))]
fn authenticate_with(
    request: Request,
    password: Zeroizing<Vec<u8>>,
    action: impl FnOnce(&Request, &[u8]) -> Result<()>,
) -> Result<Authenticated> {
    request.context.check()?;
    validate_credential(&password)?;
    action(&request, &password)?;
    request.context.check()?;
    Ok(Authenticated { request })
}

#[cfg(feature = "local-auth")]
mod native {
    use super::*;
    use std::{
        fs,
        io::{Read, Write},
        os::unix::{fs::MetadataExt, io::AsRawFd},
        path::PathBuf,
        process::{Child, Command, Stdio},
        thread,
        time::Instant,
    };
    use zeroize::Zeroize;
    pub struct Native {
        path: PathBuf,
        uid: u32,
    }
    #[cfg(all(test, feature = "desktop"))]
    thread_local! {
        static LIVE_FIXTURE_HELPER: std::cell::RefCell<Option<PathBuf>> =
            const { std::cell::RefCell::new(None) };
    }
    #[cfg(all(test, feature = "desktop"))]
    pub(crate) fn with_live_fixture_helper<T>(
        path: &std::path::Path,
        action: impl FnOnce() -> T,
    ) -> T {
        struct Restore(Option<PathBuf>);
        impl Drop for Restore {
            fn drop(&mut self) {
                LIVE_FIXTURE_HELPER.with(|fixture| *fixture.borrow_mut() = self.0.take());
            }
        }
        let _restore = Restore(
            LIVE_FIXTURE_HELPER.with(|fixture| fixture.borrow_mut().replace(path.to_owned())),
        );
        action()
    }
    impl Native {
        pub fn new() -> Result<Self> {
            #[cfg(all(test, feature = "desktop"))]
            if let Some(path) = LIVE_FIXTURE_HELPER.with(|fixture| fixture.borrow().clone()) {
                return Self::at(path);
            }
            let path = std::env::current_exe().map_err(|_| Failure::Unavailable)?;
            let path = path
                .parent()
                .ok_or(Failure::Unavailable)?
                .join("snippets-owner-auth");
            Self::at(path)
        }
        fn at(path: PathBuf) -> Result<Self> {
            let uid = unsafe { libc::getuid() };
            if uid != unsafe { libc::geteuid() }
                || unsafe { libc::getgid() } != unsafe { libc::getegid() }
            {
                return Err(Failure::WrongIdentity);
            }
            let m = fs::symlink_metadata(&path).map_err(|_| Failure::Unavailable)?;
            if !m.is_file()
                || m.file_type().is_symlink()
                || (m.uid() != uid && m.uid() != 0)
                || m.mode() & 0o022 != 0
                || m.mode() & 0o6000 != 0
                || m.mode() & 0o111 == 0
            {
                return Err(Failure::Unavailable);
            }
            Ok(Self { path, uid })
        }
        pub fn authenticate(
            &self,
            request: Request,
            password: Zeroizing<Vec<u8>>,
        ) -> Result<Authenticated> {
            authenticate_with(request, password, |request, password| {
                self.run(request, password)
            })
        }
        fn run(&self, request: &Request, password: &[u8]) -> Result<()> {
            self.run_limit(request, password, NATIVE_LIFETIME)
        }
        fn run_limit(&self, request: &Request, password: &[u8], limit: Duration) -> Result<()> {
            let checked = Self::at(self.path.clone())?;
            if checked.uid != self.uid {
                return Err(Failure::WrongIdentity);
            }
            if unsafe { libc::getuid() } != self.uid || unsafe { libc::geteuid() } != self.uid {
                return Err(Failure::WrongIdentity);
            }
            let child = Command::new(&self.path)
                .env_clear()
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|_| Failure::Unavailable)?;
            let mut child = Reap(child);
            let input = child.0.stdin.take().ok_or(Failure::Protocol)?;
            let mut output = child.0.stdout.take().ok_or(Failure::Protocol)?;
            nonblocking(input.as_raw_fd())?;
            nonblocking(output.as_raw_fd())?;
            let mut bytes = Zeroizing::new(Vec::with_capacity(8 + password.len()));
            bytes.extend_from_slice(&self.uid.to_be_bytes());
            bytes.extend_from_slice(&(password.len() as u32).to_be_bytes());
            bytes.extend_from_slice(password);
            let mut sent = 0;
            let mut input = Some(input);
            let mut received = Vec::with_capacity(8);
            let started = Instant::now();
            loop {
                request.context.check()?;
                if started.elapsed() >= limit {
                    return Err(Failure::Timeout);
                }
                if let Some(pipe) = &mut input {
                    match pipe.write(&bytes[sent..]) {
                        Ok(0) => return Err(Failure::Protocol),
                        Ok(n) => sent += n,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => (),
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => return Err(Failure::Protocol),
                    }
                    if sent == bytes.len() {
                        input = None;
                        bytes.zeroize();
                    }
                }
                let mut buffer = [0; 8];
                let eof = match output.read(&mut buffer) {
                    Ok(0) => true,
                    Ok(n) => {
                        received.extend_from_slice(&buffer[..n]);
                        false
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => false,
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => return Err(Failure::Protocol),
                };
                if received.len() > 1 {
                    return Err(Failure::Protocol);
                }
                let status = child.0.try_wait().map_err(|_| Failure::Protocol)?;
                if let Some(status) = status {
                    if !status.success() {
                        return Err(Failure::Protocol);
                    }
                    if eof {
                        return match received.as_slice() {
                            [0] => Ok(()),
                            [1] => Err(Failure::Unavailable),
                            [2] => Err(Failure::Denied),
                            [3] => Err(Failure::AccountRestricted),
                            [4] => Err(Failure::WrongIdentity),
                            [5] => Err(Failure::UnsupportedConversation),
                            _ => Err(Failure::Protocol),
                        };
                    }
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
        #[cfg(test)]
        pub(crate) fn fixture(path: PathBuf) -> Result<Self> {
            Self::at(path)
        }
        #[cfg(test)]
        pub(crate) fn fixture_authenticate_limit(
            &self,
            request: Request,
            password: Zeroizing<Vec<u8>>,
            limit: Duration,
        ) -> Result<Authenticated> {
            authenticate_with(request, password, |r, p| self.run_limit(r, p, limit))
        }
    }
    fn nonblocking(fd: libc::c_int) -> Result<()> {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            return Err(Failure::Protocol);
        }
        Ok(())
    }
    struct Reap(Child);
    impl Drop for Reap {
        fn drop(&mut self) {
            if !matches!(self.0.try_wait(), Ok(Some(_))) {
                let _ = self.0.kill();
            }
            let _ = self.0.wait();
        }
    }
    unsafe extern "C" {
        fn snip_owner_authenticate(uid: u32, password: *const u8, length: usize) -> libc::c_int;
    }
    /// The private installed helper accepts one bounded binary request on stdin,
    /// emits one closed status byte, and never opens a login session or changes a password.
    pub fn helper_main() -> i32 {
        let mut password = Zeroizing::new([0u8; 4096]);
        let result: Result<u8> = (|| {
            if unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0) } != 0 {
                return Err(Failure::Unavailable);
            }
            let mut input = std::io::stdin().lock();
            if std::env::args_os().len() != 1 {
                return Err(Failure::Protocol);
            }
            let mut header = [0; 8];
            input
                .read_exact(&mut header)
                .map_err(|_| Failure::Protocol)?;
            let uid = u32::from_be_bytes(header[..4].try_into().map_err(|_| Failure::Protocol)?);
            let length =
                u32::from_be_bytes(header[4..].try_into().map_err(|_| Failure::Protocol)?) as usize;
            if length == 0 || length > password.len() {
                return Err(Failure::InvalidCredential);
            }
            input
                .read_exact(&mut password[..length])
                .map_err(|_| Failure::Protocol)?;
            let mut trailing = [0; 1];
            if input.read(&mut trailing).map_err(|_| Failure::Protocol)? != 0 {
                return Err(Failure::Protocol);
            }
            validate_credential(&password[..length])?;
            let status = unsafe { snip_owner_authenticate(uid, password.as_ptr(), length) };
            u8::try_from(status)
                .ok()
                .filter(|v| *v <= 5)
                .ok_or(Failure::Protocol)
        })();
        let status = result.unwrap_or(1);
        if std::io::stdout().lock().write_all(&[status]).is_ok() {
            0
        } else {
            1
        }
    }
}
#[cfg(feature = "local-auth")]
pub use native::{Native, helper_main};

#[cfg(all(test, feature = "desktop"))]
pub(crate) use native::with_live_fixture_helper;

#[cfg(test)]
pub(crate) fn authenticate_fixture(request: Request) -> Result<Authenticated> {
    authenticate_with(
        request,
        Zeroizing::new(b"Public fictional password".to_vec()),
        |_, _| Ok(()),
    )
}

#[cfg(test)]
#[path = "local_auth_tests.rs"]
mod tests;
