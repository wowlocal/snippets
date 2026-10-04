//! Production native connection, anonymous keymap FD and key requests against
//! a private libwayland peer. No connection to the user's compositor or apps.
use super::*;
use std::{
    io::{Read, Write},
    os::{
        fd::{IntoRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::Instant,
};
unsafe extern "C" {
    fn snip_input_open_fd(
        fd: c_int,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
}
fn connect(fd: OwnedFd, guard: &dyn Fn() -> Result<()>) -> Result<Connection> {
    let mut context = Check(guard);
    let mut status = 3;
    let pointer = unsafe {
        snip_input_open_fd(
            fd.into_raw_fd(),
            check,
            (&mut context as *mut Check<'_>).cast(),
            &mut status,
        )
    };
    NonNull::new(pointer)
        .map(Connection)
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
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    for (mode, file) in [
        ("server-header", "snippets-input-server.h"),
        ("private-code", "protocol.c"),
    ] {
        output(
            Command::new("wayland-scanner")
                .arg(mode)
                .arg(manifest.join("data/virtual-keyboard-v1.xml"))
                .arg(root.join(file)),
        );
    }
    let binary = root.join("input-fixture");
    let flags = output(Command::new("pkg-config").args([
        "--cflags",
        "--libs",
        "wayland-server",
        "xkbcommon",
    ]));
    output(
        Command::new("cc")
            .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
            .arg("-I")
            .arg(root)
            .arg(manifest.join("tests/reference/input-wayland.c"))
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
fn reply(stream: &mut UnixStream) -> u8 {
    let mut descriptor = libc::pollfd {
        fd: stream.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    assert_eq!(
        unsafe { libc::poll(&mut descriptor, 1, 3000) },
        1,
        "private fixture response deadline"
    );
    let mut byte = [0];
    stream.read_exact(&mut byte).unwrap();
    byte[0]
}
impl Server {
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
        let mut server = Self {
            child,
            commands: commands.try_clone().unwrap(),
        };
        let first = reply(&mut commands);
        if first != b'!' {
            let code = if first == b'?' {
                reply(&mut commands)
            } else {
                255
            };
            let _ = server.child.kill();
            let _ = server.child.wait();
            panic!(
                "private libwayland fixture could not initialize (errno {code}); no real display was accessed"
            );
        }
        (server, display.into())
    }
    fn command(&mut self, command: u8) -> u8 {
        self.commands.write_all(&[command]).unwrap();
        reply(&mut self.commands)
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
struct Sink(Option<Connection>);
impl Backend for Sink {
    fn begin(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()
    }
    fn install(&mut self, map: &[u8], guard: &dyn Fn() -> Result<()>) -> Result<()> {
        self.0.as_ref().unwrap().install(map, guard)
    }
    fn key(&mut self, code: u32, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        self.0.as_ref().unwrap().key(code, guard)
    }
}
fn prepared(body: &str) -> (tempfile::TempDir, Prepared) {
    let temp = tempfile::tempdir().unwrap();
    fs::create_dir(temp.path().join("Vault")).unwrap();
    model::atomic_write(
        &temp.path().join("Vault/vault.json"),
        b"Public encrypted source fixture",
    )
    .unwrap();
    let (source, _) = Source::prove(temp.path()).unwrap();
    let auth = Authorization::new(SessionWitness::test(SessionState::Unlocked, 1)).unwrap();
    (
        temp,
        Prepared::new(source, Zeroizing::new(body.as_bytes().to_vec()), auth).unwrap(),
    )
}
#[test]
fn revoked_input_fd_is_closed_before_any_protocol_handshake() {
    let (client, mut server) = UnixStream::pair().unwrap();
    assert!(connect(client.into(), &|| Err(CANCELLED)).is_err());
    let mut byte = [0];
    assert_eq!(server.read(&mut byte).unwrap(), 0);
}
#[test]
#[ignore = "requires unrestricted libwayland-server peer credentials; private socket pairs only"]
fn private_input_protocol_checks_unicode_sealed_maps_key_pairs_and_cancellation() {
    let root = tempfile::tempdir().unwrap();
    let binary = compile(root.path());
    for mode in [
        "missing",
        "two-seats",
        "two-managers",
        "no-keyboard",
        "silent-seat",
    ] {
        let (_server, fd) = Server::start(&binary, mode);
        assert!(connect(fd, &|| Ok(())).is_err());
    }
    for (body, command, count) in [
        ("Aя中🙂\t\r\nZ\r!".into(), b'V', 9),
        ("ABC".repeat(161)[..481].to_owned(), b'B', 481),
    ] {
        let (mut server, fd) = Server::start(&binary, "normal");
        let mut sink = Sink(Some(connect(fd, &|| Ok(())).unwrap()));
        assert!(sink.0.as_ref().unwrap().key(1, &|| Ok(())).is_err());
        let (_temp, owner) = prepared(&body);
        assert_eq!(owner.deliver(&mut sink, "").unwrap(), count);
        assert_eq!(server.command(command), command);
        drop(sink);
    }
    for revoke_before_flush in [false, true] {
        let (mut server, fd) = Server::start(&binary, "normal");
        let connection = connect(fd, &|| Ok(())).unwrap();
        let map = Keymap::new(&['A' as u32]).unwrap();
        connection.install(&map.bytes, &|| Ok(())).unwrap();
        assert!(connection.key(0, &|| Ok(())).is_err());
        assert!(connection.key(248, &|| Ok(())).is_err());
        let calls = std::cell::Cell::new(0);
        let guard = || {
            calls.set(calls.get() + 1);
            if !revoke_before_flush || calls.get() > 1 {
                Err(CANCELLED)
            } else {
                Ok(())
            }
        };
        assert!(connection.key(1, &guard).is_err());
        drop(connection); // Closing must never flush the queued pair after revocation.
        assert_eq!(server.command(b'K'), 0);
    }
    for revoke in [true, false] {
        let (_server, fd) = Server::start(&binary, "stall");
        let calls = std::cell::Cell::new(0);
        let guard = || {
            calls.set(calls.get() + 1);
            if revoke && calls.get() > 8 {
                Err(CANCELLED)
            } else {
                Ok(())
            }
        };
        let start = Instant::now();
        assert!(connect(fd, &guard).is_err());
        if revoke {
            assert!(start.elapsed() < Duration::from_secs(2));
        } else {
            assert!(
                start.elapsed() >= Duration::from_secs(2)
                    && start.elapsed() < Duration::from_secs(4)
            );
        }
    }
}
