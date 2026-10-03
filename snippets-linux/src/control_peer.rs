//! Linux kernel peer PID handles and installed executable identity. No PID reuse fallback.
use super::*;
use std::{
    fs::{self, File, OpenOptions},
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::SystemTime,
};

pub(crate) fn private_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| CLOSED)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(REFUSED);
    }
    Ok(())
}
pub(crate) struct Image {
    path: PathBuf,
    file: File,
    identity: [u64; 7],
}
fn identity(metadata: &fs::Metadata) -> Result<[u64; 7]> {
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.mode() & 0o6022 != 0
        || metadata.mode() & 0o111 == 0
        || ![0, unsafe { libc::geteuid() }].contains(&metadata.uid())
    {
        return Err(REFUSED);
    }
    Ok([
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime() as u64,
        metadata.mtime_nsec() as u64,
        metadata.ctime() as u64,
        metadata.ctime_nsec() as u64,
    ])
}
impl Image {
    pub(crate) fn sibling(name: &str) -> Result<Self> {
        let exe = std::env::current_exe().map_err(|_| REFUSED)?;
        Self::at(exe.parent().ok_or(REFUSED)?.join(name))
    }
    fn at(path: PathBuf) -> Result<Self> {
        if unsafe { libc::getuid() } != unsafe { libc::geteuid() }
            || unsafe { libc::getgid() } != unsafe { libc::getegid() }
        {
            return Err(REFUSED);
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path)
            .map_err(|_| REFUSED)?;
        let identity = identity(&file.metadata().map_err(|_| REFUSED)?)?;
        Ok(Self {
            path,
            file,
            identity,
        })
    }
    fn check(&self) -> Result<()> {
        if identity(&self.file.metadata().map_err(|_| REFUSED)?)? != self.identity
            || identity(&fs::symlink_metadata(&self.path).map_err(|_| REFUSED)?)? != self.identity
        {
            return Err(REFUSED);
        }
        Ok(())
    }
}
struct NativePeer {
    pid: i32,
    pidfd: OwnedFd,
    image: Image,
    connection: std::os::unix::net::UnixStream,
    watch_disconnect: bool,
}
impl NativePeer {
    fn check(&self) -> Result<()> {
        let mut process = libc::pollfd {
            fd: self.pidfd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        if unsafe { libc::poll(&mut process, 1, 0) } != 0 {
            return Err(CLOSED);
        }
        self.image.check()?;
        let exe = File::open(format!("/proc/{}/exe", self.pid)).map_err(|_| REFUSED)?;
        if identity(&exe.metadata().map_err(|_| REFUSED)?)? != self.image.identity {
            return Err(REFUSED);
        }
        let status =
            fs::read_to_string(format!("/proc/{}/status", self.pid)).map_err(|_| REFUSED)?;
        let uid_line = status
            .lines()
            .find(|line| line.starts_with("Uid:"))
            .ok_or(REFUSED)?;
        let uids: Vec<_> = uid_line
            .split_whitespace()
            .skip(1)
            .map(|v| v.parse::<u32>())
            .collect();
        if uids.len() != 4
            || uids
                .into_iter()
                .any(|v| v != Ok(unsafe { libc::geteuid() }))
        {
            return Err(REFUSED);
        }
        if unsafe { libc::poll(&mut process, 1, 0) } != 0 {
            return Err(CLOSED);
        }
        if self.watch_disconnect {
            let mut socket = libc::pollfd {
                fd: self.connection.as_raw_fd(),
                events: libc::POLLRDHUP,
                revents: 0,
            };
            if unsafe { libc::poll(&mut socket, 1, 0) } < 0
                || socket.revents
                    & (libc::POLLHUP | libc::POLLRDHUP | libc::POLLERR | libc::POLLNVAL)
                    != 0
            {
                return Err(CLOSED);
            }
        }
        Ok(())
    }
}
enum Proof {
    Native(NativePeer),
    #[cfg(test)]
    Fixture(Box<dyn Fn() -> Result<()> + Send + Sync>),
}
struct Context {
    proof: Proof,
    stop: Arc<AtomicBool>,
    started: Instant,
    wall: SystemTime,
    uptime: Duration,
}
#[derive(Clone)]
pub(crate) struct Lease(Arc<Context>);
impl Lease {
    pub(crate) fn verified(
        stream: &std::os::unix::net::UnixStream,
        image: Image,
        stop: Arc<AtomicBool>,
        watch_disconnect: bool,
    ) -> Result<Self> {
        let mut credentials = libc::ucred {
            pid: 0,
            uid: 0,
            gid: 0,
        };
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERCRED,
                (&mut credentials as *mut libc::ucred).cast(),
                &mut length,
            )
        } != 0
            || length as usize != std::mem::size_of::<libc::ucred>()
            || credentials.pid <= 0
            || credentials.uid != unsafe { libc::geteuid() }
        {
            return Err(REFUSED);
        }
        let mut descriptor = -1;
        length = std::mem::size_of::<i32>() as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                stream.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_PEERPIDFD,
                (&mut descriptor as *mut i32).cast(),
                &mut length,
            )
        } != 0
            || length as usize != std::mem::size_of::<i32>()
            || descriptor < 0
        {
            return Err(REFUSED);
        }
        let pidfd = unsafe { OwnedFd::from_raw_fd(descriptor) };
        if unsafe { libc::fcntl(pidfd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(REFUSED);
        }
        let fdinfo = fs::read_to_string(format!("/proc/self/fdinfo/{}", pidfd.as_raw_fd()))
            .map_err(|_| REFUSED)?;
        let reported = fdinfo.lines().find_map(|line| {
            line.strip_prefix("Pid:")
                .and_then(|v| v.trim().parse::<i32>().ok())
        });
        if reported != Some(credentials.pid) {
            return Err(REFUSED);
        }
        let proof = NativePeer {
            pid: credentials.pid,
            pidfd,
            image,
            connection: stream.try_clone().map_err(|_| CLOSED)?,
            watch_disconnect,
        };
        proof.check()?;
        Ok(Self(Arc::new(Context {
            proof: Proof::Native(proof),
            stop,
            started: Instant::now(),
            wall: SystemTime::now(),
            uptime: crate::clock::uptime().ok_or(CLOSED)?,
        })))
    }
    pub(crate) fn check(&self) -> Result<()> {
        deadline(self.0.started)?;
        if self.0.stop.load(Ordering::Acquire)
            || SystemTime::now()
                .duration_since(self.0.wall)
                .map_or(true, |elapsed| elapsed >= TIMEOUT)
            || crate::clock::uptime()
                .and_then(|now| now.checked_sub(self.0.uptime))
                .is_none_or(|elapsed| elapsed >= TIMEOUT)
        {
            return Err(CLOSED);
        }
        match &self.0.proof {
            Proof::Native(peer) => peer.check(),
            #[cfg(test)]
            Proof::Fixture(check) => check(),
        }
    }
    #[cfg(any(test, feature = "desktop"))]
    pub(crate) fn caller(&self) -> String {
        #[cfg(not(test))]
        let Proof::Native(peer) = &self.0.proof;
        #[cfg(test)]
        let peer = match &self.0.proof {
            Proof::Native(peer) => peer,
            Proof::Fixture(_) => return "Public fixture requester".into(),
        };
        let status = fs::read_to_string(format!("/proc/{}/status", peer.pid)).unwrap_or_default();
        let parent = status.lines().find_map(|line| {
            line.strip_prefix("PPid:")
                .and_then(|v| v.trim().parse::<i32>().ok())
        });
        let parent = parent.and_then(|pid| fs::read_link(format!("/proc/{pid}/exe")).ok());
        let label = parent.map_or_else(
            || "A command-line program".into(),
            |path| format!("Started by {}", path.to_string_lossy()),
        );
        format!(
            "{}\nVerified CLI: {}",
            single_line(&label),
            single_line(&peer.image.path.to_string_lossy())
        )
    }
    #[cfg(test)]
    pub(crate) fn fixture(check: impl Fn() -> Result<()> + Send + Sync + 'static) -> Self {
        Self(Arc::new(Context {
            proof: Proof::Fixture(Box::new(check)),
            stop: Arc::new(AtomicBool::new(false)),
            started: Instant::now(),
            wall: SystemTime::now(),
            uptime: crate::clock::uptime().unwrap(),
        }))
    }
}
#[cfg(any(test, feature = "desktop"))]
fn single_line(value: &str) -> String {
    value
        .chars()
        .filter(|c| {
            !c.is_control() && !matches!(*c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
        .take(2048)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{
        fs::{PermissionsExt, symlink},
        net::UnixStream,
    };
    #[test]
    fn executable_proof_rejects_links_writable_images_and_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("public-fixture-image");
        fs::write(&path, b"Public fictional executable identity").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        let image = Image::at(path.clone()).unwrap();
        image.check().unwrap();
        let link = temp.path().join("link");
        symlink(&path, &link).unwrap();
        assert!(Image::at(link).is_err());
        let hard = temp.path().join("hard");
        fs::hard_link(&path, &hard).unwrap();
        assert!(image.check().is_err());
        fs::remove_file(hard).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o722)).unwrap();
        assert!(Image::at(path.clone()).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        let image = Image::at(path.clone()).unwrap();
        let replacement = temp.path().join("replacement");
        fs::copy(&path, &replacement).unwrap();
        fs::rename(replacement, &path).unwrap();
        assert!(image.check().is_err());
        let (stream, _peer) = UnixStream::pair().unwrap();
        // Actual process cannot be this fictional image, even where kernel peer options work.
        assert!(
            Lease::verified(
                &stream,
                Image::at(path).unwrap(),
                Arc::new(AtomicBool::new(false)),
                true
            )
            .is_err()
        );
    }
    #[test]
    fn caller_labels_strip_controls_and_bidi_and_bound_untrusted_parent_metadata() {
        assert_eq!(
            single_line("public\n\r\u{202e}caller\u{2066}"),
            "publiccaller"
        );
        assert_eq!(single_line(&"🙂".repeat(3000)).chars().count(), 2048);
    }
    #[test]
    #[ignore = "requires permitted SO_PEERCRED and SO_PEERPIDFD; private socketpair only"]
    fn native_peer_pidfd_pins_the_exact_current_executable_and_revokes_on_disconnect() {
        let (stream, other) = UnixStream::pair().unwrap();
        let image = Image::at(std::env::current_exe().unwrap()).unwrap();
        let lease = Lease::verified(&stream, image, Arc::new(AtomicBool::new(false)), true)
            .expect("kernel peer credentials and pidfd");
        lease.check().unwrap();
        drop(other);
        assert!(lease.check().is_err());
    }
}
