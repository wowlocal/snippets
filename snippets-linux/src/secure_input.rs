//! Explicit private CLI input sources. No secret argv/env values or temporary files.
use crate::model::{Error, MAX_BODY_BYTES, Result};
use std::{
    fs::{File, OpenOptions},
    io::Write,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::PathBuf,
    sync::atomic::{AtomicI32, Ordering},
    time::{Duration, Instant},
};
use zeroize::Zeroizing;
const INPUT: Error =
    Error("Secure input could not be read as non-empty UTF-8 within the 256 KiB limit.");
const PRIVATE: Error = Error(
    "Secure files must be regular files without links, owned by you, with no group/other access. Stdin and descriptors must be private files or pipes.",
);
const TERMINAL: Error =
    Error("Use --prompt for hidden terminal input, or a private file, descriptor or stdin pipe.");
pub enum Source {
    Stdin,
    File(PathBuf),
    Descriptor(i32),
    Prompt,
}
impl Source {
    pub fn read(self, guard: &dyn Fn() -> Result<()>) -> Result<Zeroizing<Vec<u8>>> {
        guard()?;
        let bytes = match self {
            Self::File(path) => {
                let file = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
                    .open(path)
                    .map_err(|_| PRIVATE)?;
                validate(&file, true)?;
                read(&file, guard, false)?
            }
            Self::Stdin | Self::Descriptor(_) => {
                let fd = match self {
                    Self::Descriptor(fd) => fd,
                    _ => libc::STDIN_FILENO,
                };
                if fd < 0 {
                    return Err(PRIVATE);
                }
                let fd = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
                if fd < 0 {
                    return Err(PRIVATE);
                }
                let file = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
                validate(&file, false)?;
                read(&file, guard, false)?
            }
            Self::Prompt => {
                let mut file = OpenOptions::new()
                    .read(true)
                    .write(true)
                    .custom_flags(libc::O_CLOEXEC | libc::O_NONBLOCK)
                    .open("/dev/tty")
                    .map_err(|_| TERMINAL)?;
                prompt(&mut file, guard)?
            }
        };
        if bytes.is_empty()
            || bytes.len() > MAX_BODY_BYTES
            || bytes.contains(&0)
            || std::str::from_utf8(&bytes).is_err()
        {
            return Err(INPUT);
        }
        guard()?;
        Ok(bytes)
    }
}
fn validate(file: &File, regular: bool) -> Result<()> {
    if unsafe { libc::isatty(file.as_raw_fd()) } != 0 {
        return Err(TERMINAL);
    }
    let metadata = file.metadata().map_err(|_| PRIVATE)?;
    let kind = metadata.mode() & libc::S_IFMT;
    if metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.nlink() != 1
        || (kind != libc::S_IFREG && (regular || kind != libc::S_IFIFO))
    {
        return Err(PRIVATE);
    }
    if kind == libc::S_IFREG && metadata.len() > MAX_BODY_BYTES as u64 {
        return Err(INPUT);
    }
    Ok(())
}
fn read(file: &File, guard: &dyn Fn() -> Result<()>, line: bool) -> Result<Zeroizing<Vec<u8>>> {
    // Poll does not prevent another reader from draining an inherited pipe.
    // Never leave a blocking read beyond the lease; restore the shared descriptor flags.
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        return Err(INPUT);
    }
    struct Flags<'a>(&'a File, i32);
    impl Drop for Flags<'_> {
        fn drop(&mut self) {
            unsafe {
                libc::fcntl(self.0.as_raw_fd(), libc::F_SETFL, self.1);
            }
        }
    }
    let _flags = Flags(file, flags);
    let start = Instant::now();
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_BODY_BYTES + 1));
    let mut buffer = Zeroizing::new([0u8; 4096]);
    loop {
        guard()?;
        if start.elapsed() >= Duration::from_secs(120)
            || line && SIGNAL.load(Ordering::Relaxed) != 0
        {
            return Err(INPUT);
        }
        let mut ready = libc::pollfd {
            fd: file.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut ready, 1, 25) };
        if result < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(INPUT);
        }
        if result == 0 {
            continue;
        }
        let take = buffer.len().min(MAX_BODY_BYTES + 1 - bytes.len());
        let length = unsafe { libc::read(file.as_raw_fd(), buffer.as_mut_ptr().cast(), take) };
        if length < 0 {
            if matches!(
                std::io::Error::last_os_error().kind(),
                std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
            ) {
                continue;
            }
            return Err(INPUT);
        }
        if length == 0 {
            return Ok(bytes);
        }
        for byte in &buffer[..length as usize] {
            if line {
                match *byte {
                    b'\r' | b'\n' | 4 => return Ok(bytes),
                    8 | 127 => {
                        while let Some(last) = bytes.pop() {
                            if last & 0xc0 != 0x80 {
                                break;
                            }
                        }
                        continue;
                    }
                    0..=31 if *byte != b'\t' => return Err(INPUT),
                    _ => (),
                }
            }
            bytes.push(*byte);
            if bytes.len() > MAX_BODY_BYTES {
                return Err(INPUT);
            }
        }
    }
}
static SIGNAL: AtomicI32 = AtomicI32::new(0);
extern "C" fn interrupted(signal: libc::c_int) {
    SIGNAL.store(signal, Ordering::Relaxed);
}
struct Terminal<'a> {
    file: &'a File,
    original: libc::termios,
    signals: Vec<(i32, libc::sigaction)>,
}
impl Drop for Terminal<'_> {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(self.file.as_raw_fd(), libc::TCSAFLUSH, &self.original);
        }
        for (signal, original) in &self.signals {
            unsafe {
                libc::sigaction(*signal, original, std::ptr::null_mut());
            }
        }
    }
}
fn prompt(file: &mut File, guard: &dyn Fn() -> Result<()>) -> Result<Zeroizing<Vec<u8>>> {
    let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
    if unsafe { libc::tcgetattr(file.as_raw_fd(), &mut original) } != 0 {
        return Err(TERMINAL);
    }
    file.write_all(b"Secure content (one line): ")
        .map_err(|_| TERMINAL)?;
    let mut terminal = Terminal {
        file,
        original,
        signals: Vec::new(),
    };
    SIGNAL.store(0, Ordering::Relaxed);
    for signal in [
        libc::SIGINT,
        libc::SIGTERM,
        libc::SIGHUP,
        libc::SIGQUIT,
        libc::SIGTSTP,
        libc::SIGTTIN,
        libc::SIGTTOU,
    ] {
        let mut action = unsafe { std::mem::zeroed::<libc::sigaction>() };
        action.sa_sigaction = interrupted as *const () as usize;
        unsafe {
            libc::sigemptyset(&mut action.sa_mask);
        }
        let mut prior = unsafe { std::mem::zeroed::<libc::sigaction>() };
        if unsafe { libc::sigaction(signal, &action, &mut prior) } != 0 {
            return Err(TERMINAL);
        }
        terminal.signals.push((signal, prior));
    }
    let mut hidden = original;
    hidden.c_lflag &= !(libc::ECHO | libc::ECHONL | libc::ICANON);
    hidden.c_cc[libc::VMIN] = 1;
    hidden.c_cc[libc::VTIME] = 0;
    if unsafe { libc::tcsetattr(file.as_raw_fd(), libc::TCSAFLUSH, &hidden) } != 0 {
        return Err(TERMINAL);
    }
    let body = read(terminal.file, guard, true);
    drop(terminal);
    if body.is_ok() {
        unsafe {
            libc::write(file.as_raw_fd(), b"\n".as_ptr().cast(), 1);
        }
    }
    body
}

#[cfg(test)]
#[path = "secure_input_tests.rs"]
mod tests;
