//! Exercises the production FFI reader with a private protocol peer.
use super::*;
use std::{
    io::{Read, Write},
    os::{
        fd::{AsRawFd, IntoRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

unsafe extern "C" {
    fn snip_control_open_fd(
        fd: c_int,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
}
fn connect(fd: OwnedFd, guard: &dyn Fn() -> Result<()>) -> Result<Reader> {
    let mut context = Check(guard);
    let mut status = 3;
    let pointer = unsafe {
        snip_control_open_fd(
            fd.into_raw_fd(),
            check,
            (&mut context as *mut Check<'_>).cast(),
            &mut status,
        )
    };
    NonNull::new(pointer)
        .map(Reader)
        .ok_or(if status == 2 { CANCELLED } else { UNAVAILABLE })
}
fn output(command: &mut Command) -> Vec<u8> {
    let output = command.output().expect("fixture tool");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
}
fn compile(root: &Path) -> PathBuf {
    let directory =
        output(Command::new("pkg-config").args(["--variable=pkgdatadir", "wayland-protocols"]));
    let xml = Path::new(std::str::from_utf8(&directory).unwrap().trim())
        .join("staging/ext-data-control/ext-data-control-v1.xml");
    for (mode, file) in [
        ("server-header", "snippets-data-control-server.h"),
        ("private-code", "protocol.c"),
    ] {
        output(
            Command::new("wayland-scanner")
                .arg(mode)
                .arg(&xml)
                .arg(root.join(file)),
        );
    }
    let binary = root.join("clipboard-fixture");
    let flags = output(Command::new("pkg-config").args(["--cflags", "--libs", "wayland-server"]));
    output(
        Command::new("cc")
            .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
            .arg("-I")
            .arg(root)
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/clipboard-wayland.c"))
            .arg(root.join("protocol.c"))
            .args(std::str::from_utf8(&flags).unwrap().split_whitespace())
            .arg("-o")
            .arg(&binary),
    );
    binary
}
struct Server {
    child: Child,
    commands: UnixStream,
}
fn read_reply(stream: &mut UnixStream) -> u8 {
    let mut descriptor = libc::pollfd {
        fd: stream.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    assert_eq!(
        unsafe { libc::poll(&mut descriptor, 1, 3000) },
        1,
        "fixture response deadline"
    );
    let mut reply = [0];
    stream.read_exact(&mut reply).unwrap();
    reply[0]
}
impl Server {
    fn start(binary: &Path, mode: &str) -> (Self, OwnedFd) {
        let (display, remote) = UnixStream::pair().unwrap();
        let (mut commands, control) = UnixStream::pair().unwrap();
        let mut child = Command::new(binary)
            .arg(mode)
            .stdin(Stdio::from(OwnedFd::from(remote)))
            .stderr(Stdio::from(OwnedFd::from(control)))
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let first = read_reply(&mut commands);
        if first != b'!' {
            let _ = child.kill();
            let _ = child.wait();
            let mut error = vec![first];
            commands.read_to_end(&mut error).unwrap();
            panic!(
                "private compositor initialization: {}",
                String::from_utf8_lossy(&error)
            );
        }
        (Self { child, commands }, display.into())
    }
    fn command(&mut self, command: u8) -> u8 {
        self.commands.write_all(&[command]).unwrap();
        let reply = read_reply(&mut self.commands);
        if command != b'K' {
            assert_eq!(reply, command);
        }
        reply
    }
    fn offer(&mut self, reader: &mut Reader, kind: u8) {
        let before = reader.generation();
        self.command(kind);
        let deadline = Instant::now() + Duration::from_secs(2);
        while !reader.next(before, &|| Ok(())).unwrap() {
            assert!(Instant::now() < deadline);
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.commands.write_all(b"Q");
        let deadline = Instant::now() + Duration::from_secs(2);
        while self.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
#[test]
#[ignore = "requires unrestricted libwayland-server peer credentials; private socket pairs only"]
fn private_libwayland_server_protocol_preserves_bounds_and_cancellation() {
    let root = tempfile::tempdir().unwrap();
    let binary = compile(root.path());
    verify_protocol(&binary);
}
fn verify_protocol(binary: &Path) {
    for mode in ["missing", "two-seats"] {
        let (_server, fd) = Server::start(binary, mode);
        assert!(connect(fd, &|| Ok(())).is_err());
    }
    let (mut server, fd) = Server::start(binary, "normal");
    let mut reader = connect(fd, &|| Ok(())).unwrap();
    let baseline = reader.generation();
    assert!(baseline > 0);
    assert_eq!(server.command(b'K'), 0); /* no pre-existing or primary body */
    assert!(!reader.next(baseline, &|| Ok(())).unwrap());
    server.command(b'P');
    assert!(!reader.next(baseline, &|| Ok(())).unwrap());
    assert_eq!(reader.generation(), baseline);
    for kind in *b"HIFL" {
        server.offer(&mut reader, kind);
        let formats = reader.formats().unwrap();
        let formats: Vec<_> = formats.iter().map(String::as_str).collect();
        assert!(!permits(&formats, false));
    }
    assert_eq!(server.command(b'K'), 0);
    server.offer(&mut reader, b'T');
    assert!(
        reader
            .receive(reader.generation(), "unsupported", &|| Ok(()))
            .is_err()
    );
    assert_eq!(server.command(b'K'), 0);
    let text = reader
        .receive(reader.generation(), "text/plain;charset=utf-8", &|| Ok(()))
        .unwrap();
    assert_eq!(text.as_str(), "Public cafeé 🦀 {clipboard}\n ");
    server.offer(&mut reader, b'M');
    let text = reader
        .receive(reader.generation(), "text/plain;charset=utf-8", &|| Ok(()))
        .unwrap();
    assert_eq!(text.len(), MAX_ENTRY_BYTES);
    assert!(text.bytes().all(|byte| byte == b'x'));
    for kind in *b"OBNER" {
        server.offer(&mut reader, kind);
        assert!(
            reader
                .receive(reader.generation(), "text/plain;charset=utf-8", &|| Ok(()))
                .is_err()
        );
    }
    server.offer(&mut reader, b'S');
    let calls = std::cell::Cell::new(0);
    let guard = || {
        calls.set(calls.get() + 1);
        if calls.get() > 8 {
            Err(CANCELLED)
        } else {
            Ok(())
        }
    };
    let start = Instant::now();
    assert!(
        reader
            .receive(reader.generation(), "text/plain;charset=utf-8", &guard)
            .is_err()
    );
    assert!(start.elapsed() < Duration::from_secs(2));
    server.offer(&mut reader, b'S');
    let start = Instant::now();
    assert!(
        reader
            .receive(reader.generation(), "text/plain;charset=utf-8", &|| Ok(()))
            .is_err()
    );
    assert!(start.elapsed() >= Duration::from_secs(4) && start.elapsed() < Duration::from_secs(7));
    server.command(b'D');
    assert!(reader.next(reader.generation(), &|| Ok(())).is_err());
    drop(reader);
}
#[test]
fn revoked_native_fd_is_closed_before_protocol_handshake() {
    let (client, mut server) = UnixStream::pair().unwrap();
    let fd: OwnedFd = client.into();
    assert!(connect(fd, &|| Err(CANCELLED)).is_err());
    let mut byte = [0];
    assert_eq!(server.read(&mut byte).unwrap(), 0);
}
