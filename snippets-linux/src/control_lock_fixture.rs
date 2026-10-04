//! Test-only lock owner and independent socket-pair protocol verifier.
use std::{
    io::{Read, Write},
    os::{
        fd::{AsRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

fn output(command: &mut Command) -> Vec<u8> {
    let result = command.output().unwrap();
    assert!(
        result.status.success(),
        "Owned lock fixture tool failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    result.stdout
}
pub(super) fn compile(root: &Path) -> (PathBuf, PathBuf) {
    let protocols =
        output(Command::new("pkg-config").args(["--variable=pkgdatadir", "wayland-protocols"]));
    let xml = Path::new(std::str::from_utf8(&protocols).unwrap().trim())
        .join("staging/ext-session-lock/ext-session-lock-v1.xml");
    for (mode, name) in [
        ("client-header", "snippets-session-lock.h"),
        ("server-header", "snippets-session-lock-server.h"),
        ("private-code", "session-lock-protocol.c"),
    ] {
        output(
            Command::new("wayland-scanner")
                .arg(mode)
                .arg(&xml)
                .arg(root.join(name)),
        );
    }
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference");
    let mut binaries = Vec::new();
    for (kind, library) in [("client", "wayland-client"), ("server", "wayland-server")] {
        let binary = root.join(format!("session-lock-{kind}"));
        let flags = output(Command::new("pkg-config").args(["--cflags", "--libs", library]));
        output(
            Command::new("cc")
                .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
                .arg("-I")
                .arg(root)
                .arg(source.join(format!("session-lock-{kind}.c")))
                .arg(root.join("session-lock-protocol.c"))
                .args(std::str::from_utf8(&flags).unwrap().split_whitespace())
                .arg("-o")
                .arg(&binary),
        );
        binaries.push(binary);
    }
    (binaries.remove(0), binaries.remove(0))
}

fn read_byte(stream: &mut impl Read, descriptor: i32, milliseconds: i32) -> u8 {
    let mut wait = libc::pollfd {
        fd: descriptor,
        events: libc::POLLIN,
        revents: 0,
    };
    assert_eq!(
        unsafe { libc::poll(&mut wait, 1, milliseconds) },
        1,
        "Owned lock reply deadline"
    );
    let mut byte = [0];
    stream.read_exact(&mut byte).unwrap();
    byte[0]
}
pub(super) struct Locker {
    child: Child,
    input: Option<ChildStdin>,
    output: ChildStdout,
    completed: bool,
}
impl Locker {
    fn start(command: &mut Command) -> Self {
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let input = child.stdin.take();
        let output = child.stdout.take().unwrap();
        Self {
            child,
            input,
            output,
            completed: false,
        }
    }
    pub(super) fn live(binary: &Path, compositor: u64) -> Self {
        Self::start(
            Command::new(binary)
                .arg("--live")
                .env("SNIPPETS_CONTROL_LOCK_PEER_PID", compositor.to_string())
                .stderr(Stdio::piped()),
        )
    }
    fn private(binary: &Path, display: OwnedFd) -> Self {
        Self::start(
            Command::new(binary)
                .arg("--private-socket")
                .env("WAYLAND_DISPLAY", "/nonexistent/private-lock-only")
                .env("XDG_RUNTIME_DIR", "/nonexistent/private-lock-only")
                .stderr(Stdio::from(display)),
        )
    }
    pub(super) fn reply(&mut self) -> u8 {
        let fd = self.output.as_raw_fd();
        read_byte(&mut self.output, fd, 15_000)
    }
    pub(super) fn arm(&mut self) {
        assert_eq!(
            self.reply(),
            b'R',
            "The independent owner must be prepared before requesting a lock"
        );
    }
    pub(super) fn lock(&mut self) {
        self.input.as_mut().unwrap().write_all(b"L").unwrap();
    }
    pub(super) fn release(&mut self) {
        if let Some(input) = self.input.as_mut() {
            let _ = input.write_all(b"U");
        }
        loop {
            match self.reply() {
                b'L' => (),
                b'U' => break,
                other => panic!("Owned lock release refused, phase={other}"),
            }
        }
        let status = self.child.wait().unwrap();
        self.completed = true;
        assert!(status.success());
        if let Some(mut errors) = self.child.stderr.take() {
            let mut bytes = Vec::new();
            errors.read_to_end(&mut bytes).unwrap();
            assert!(
                bytes.is_empty(),
                "The live lock owner must emit no warnings"
            );
        }
    }
    fn exit(&mut self, code: i32) {
        let status = self.child.wait().unwrap();
        self.completed = true;
        assert_eq!(status.code(), Some(code));
    }
}
impl Drop for Locker {
    fn drop(&mut self) {
        if self.completed {
            return;
        }
        if let Some(mut input) = self.input.take() {
            let _ = input.write_all(b"U");
        }
        // EOF and the owner's independent timer request a graceful unlock.
        // Never call kill(): only this Wayland connection can release its lock.
        let _ = self.child.wait();
    }
}
struct Peer {
    child: Child,
    commands: UnixStream,
}
impl Peer {
    fn start(binary: &Path, mode: &str) -> (Self, OwnedFd) {
        let (display, remote) = UnixStream::pair().unwrap();
        let (mut commands, control) = UnixStream::pair().unwrap();
        let child = Command::new(binary)
            .arg(mode)
            .stdin(Stdio::from(OwnedFd::from(remote)))
            .stderr(Stdio::from(OwnedFd::from(control)))
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let fd = commands.as_raw_fd();
        assert_eq!(read_byte(&mut commands, fd, 3000), b'!');
        (Self { child, commands }, display.into())
    }
    fn command(&mut self, byte: u8) -> u8 {
        self.commands.write_all(&[byte]).unwrap();
        let fd = self.commands.as_raw_fd();
        read_byte(&mut self.commands, fd, 3000)
    }
    fn pending(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while self.command(b'K') != b'P' {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.commands.write_all(b"Q");
        let deadline = Instant::now() + Duration::from_secs(2);
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        // This is a private socket-pair server, never the host compositor.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
#[test]
fn private_session_lock_owner_obeys_graceful_release_and_deadman() {
    let directory = tempfile::tempdir().unwrap();
    let (client, server) = compile(directory.path());
    for mode in ["missing", "duplicate"] {
        let (mut peer, display) = Peer::start(&server, mode);
        let mut owner = Locker::private(&client, display);
        owner.exit(2);
        assert_eq!(peer.command(b'K'), b'N');
    }
    for mode in [
        "denied",
        "immediate",
        "automatic",
        "eof",
        "signal",
        "delayed",
        "delayed-eof",
        "delayed-signal",
        "cancel-before-request",
    ] {
        let delayed = mode.starts_with("delayed");
        let (mut peer, display) = Peer::start(&server, if delayed { "delayed" } else { mode });
        let mut owner = Locker::private(&client, display);
        owner.arm();
        if mode == "cancel-before-request" {
            owner.input.take();
            owner.exit(2);
            assert_eq!(peer.command(b'K'), b'N');
            continue;
        }
        owner.lock();
        if mode == "denied" {
            assert_eq!(owner.reply(), b'F');
            owner.exit(3);
            assert_eq!(peer.command(b'K'), b'F');
            continue;
        }
        if delayed {
            peer.pending();
        } else {
            assert_eq!(owner.reply(), b'L');
        }
        if mode.ends_with("eof") {
            owner.input.take();
        } else if mode.ends_with("signal") {
            assert_eq!(
                unsafe { libc::kill(owner.child.id() as i32, libc::SIGTERM) },
                0
            );
        } else if delayed {
            owner.input.as_mut().unwrap().write_all(b"U").unwrap();
        }
        if delayed {
            std::thread::sleep(Duration::from_millis(50));
            assert_eq!(
                peer.command(b'K'),
                b'P',
                "Cancellation must not destroy a lock before the locked event"
            );
            assert_eq!(peer.command(b'L'), b'L');
            assert_eq!(owner.reply(), b'L');
        }
        if mode == "immediate" {
            owner.release();
        } else {
            assert_eq!(owner.reply(), b'U');
            owner.exit(0);
        }
        assert_eq!(
            peer.command(b'K'),
            b'U',
            "Release must reach the independent server before owner exit"
        );
    }
    let (mut peer, display) = Peer::start(&server, "delayed");
    let mut owner = Locker::private(&client, display);
    owner.arm();
    owner.lock();
    peer.pending();
    let mut delayed = peer.commands.try_clone().unwrap();
    let release = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        delayed.write_all(b"L").unwrap();
        let fd = delayed.as_raw_fd();
        assert_eq!(read_byte(&mut delayed, fd, 3000), b'L');
    });
    let unwind = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
        let _owner = owner;
        panic!("Public fixture intentionally unwinds its lock controller");
    }));
    assert!(unwind.is_err());
    release.join().unwrap();
    assert_eq!(peer.command(b'K'), b'U');
}
