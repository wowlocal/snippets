//! Private fictional protocol peer; never opens a compositor or text field.
use super::*;
use std::{
    io::{Read, Write},
    os::{
        fd::{IntoRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    path::Path,
    process::Command,
    sync::{Arc, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};
unsafe extern "C" {
    fn snip_ime_connect_fd(
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
        snip_ime_connect_fd(
            fd.into_raw_fd(),
            check,
            (&mut context as *mut Check<'_>).cast(),
            &mut status,
        )
    };
    let owner = Connection(NonNull::new(pointer).ok_or(CHANGED)?);
    // This test-only fd is the socketpair we just created, not an environment
    // socket. Production open() still requires compositor peer credentials.
    let status = unsafe {
        snip_ime_start(
            owner.0.as_ptr(),
            check,
            (&mut context as *mut Check<'_>).cast(),
        )
    };
    if status != 0 {
        return Err(UNAVAILABLE);
    }
    Ok(owner)
}
#[test]
#[ignore = "requires unrestricted SO_PEERCRED; private socketpair only"]
fn native_socketpair_peer_credentials_match_the_fixture_process() {
    let (_peer, fd) = Peer::new("normal");
    let connection = connect(fd, &|| Ok(())).unwrap();
    assert_eq!(
        unsafe { snip_ime_peer(connection.0.as_ptr()) },
        u64::from(std::process::id())
    );
}
fn words(values: &[u32]) -> Vec<u8> {
    values
        .iter()
        .flat_map(|value| value.to_ne_bytes())
        .collect()
}
fn string(value: &str) -> Vec<u8> {
    let mut bytes = words(&[value.len() as u32 + 1]);
    bytes.extend_from_slice(value.as_bytes());
    bytes.push(0);
    while !bytes.len().is_multiple_of(4) {
        bytes.push(0);
    }
    bytes
}
fn word(bytes: &[u8], offset: usize) -> u32 {
    u32::from_ne_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn message(
    stream: &mut std::fs::File,
    object: u32,
    opcode: u16,
    payload: &[u8],
) -> std::io::Result<()> {
    let mut bytes = words(&[
        object,
        ((payload.len() as u32 + 8) << 16) | u32::from(opcode),
    ]);
    bytes.extend_from_slice(payload);
    stream.write_all(&bytes)
}
macro_rules! send {
    ($stream:expr, $object:expr, $opcode:expr, $payload:expr $(,)?) => {
        if let Err(error) = message($stream, $object, $opcode, $payload) {
            // Refused admission closes the client before its sync callback.
            // All other wire failures still fail the fixture.
            assert!(matches!(
                error.kind(),
                std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset
            ));
            return;
        }
    };
}
fn state(text: &str, cursor: usize, hint: u32, purpose: u32, cause: u32) -> Vec<(u16, Vec<u8>)> {
    let mut text = string(text);
    text.extend(words(&[cursor as u32, cursor as u32]));
    vec![
        (2, text),
        (4, words(&[hint, purpose])),
        (3, words(&[cause])),
        (5, vec![]),
    ]
}
enum Control {
    Events(Vec<(u16, Vec<u8>)>, mpsc::SyncSender<()>),
    Stop,
}
type Requests = Arc<Mutex<Vec<(u16, Vec<u8>)>>>;
struct Peer {
    sender: mpsc::Sender<Control>,
    thread: Option<thread::JoinHandle<()>>,
    requests: Requests,
}
impl Peer {
    fn new(mode: &'static str) -> (Self, OwnedFd) {
        let (client, server) = UnixStream::pair().unwrap();
        server.set_nonblocking(true).unwrap();
        let mut server = std::fs::File::from(OwnedFd::from(server));
        let (sender, receiver) = mpsc::channel();
        let requests: Requests = Arc::new(Mutex::new(vec![]));
        let observed = requests.clone();
        let thread = thread::spawn(move || {
            let mut input = vec![];
            let (mut registry, mut seat, mut manager, mut method) = (0, 0, 0, 0);
            let mut field = String::from("Public \\café tail");
            let mut cursor = "Public \\café".len();
            let mut delete = None;
            let mut pending = None;
            loop {
                while let Ok(command) = receiver.try_recv() {
                    match command {
                        Control::Stop => return,
                        Control::Events(events, ack) => {
                            assert_ne!(method, 0);
                            for (opcode, payload) in events {
                                send!(&mut server, method, opcode, &payload);
                            }
                            ack.send(()).unwrap();
                        }
                    }
                }
                let mut bytes = [0; 8192];
                match server.read(&mut bytes) {
                    Ok(0) => return,
                    Ok(length) => input.extend_from_slice(&bytes[..length]),
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(error) => panic!("fictional peer read failed: {}", error.kind()),
                }
                while input.len() >= 8 {
                    let object = word(&input, 0);
                    let header = word(&input, 4);
                    let length = (header >> 16) as usize;
                    let opcode = header as u16;
                    assert!((8..=8192).contains(&length) && length.is_multiple_of(4));
                    if input.len() < length {
                        break;
                    }
                    let payload = input[8..length].to_vec();
                    input.drain(..length);
                    if object == 1 && opcode == 1 {
                        registry = word(&payload, 0);
                        let mut global = words(&[1]);
                        global.extend(string("wl_seat"));
                        global.extend(words(&[1]));
                        send!(&mut server, registry, 0, &global);
                        if mode == "two-seats" {
                            global[..4].copy_from_slice(&2u32.to_ne_bytes());
                            send!(&mut server, registry, 0, &global);
                        }
                        if mode != "missing" {
                            let mut global = words(&[3]);
                            global.extend(string("zwp_input_method_manager_v2"));
                            global.extend(words(&[1]));
                            send!(&mut server, registry, 0, &global);
                        }
                    } else if object == registry && opcode == 0 {
                        let name = word(&payload, 0);
                        let id = word(&payload, payload.len() - 4);
                        if name == 1 {
                            seat = id;
                            send!(
                                &mut server,
                                seat,
                                0,
                                &words(&[if mode == "no-keyboard" { 0 } else { 2 }]),
                            );
                        } else {
                            manager = id;
                        }
                    } else if object == 1 && opcode == 0 {
                        let callback = word(&payload, 0);
                        send!(&mut server, callback, 0, &words(&[0]));
                        send!(&mut server, 1, 1, &words(&[callback]));
                    } else if object == manager && opcode == 0 {
                        assert_eq!(word(&payload, 0), seat);
                        method = word(&payload, 4);
                        if mode == "occupied" {
                            send!(&mut server, method, 6, &[]);
                        } else {
                            send!(&mut server, method, 0, &[]);
                            for (opcode, payload) in state(&field, cursor, 0, 0, 1) {
                                send!(&mut server, method, opcode, &payload);
                            }
                        }
                    } else if object == method {
                        observed.lock().unwrap().push((opcode, payload.clone()));
                        match opcode {
                            2 => {
                                assert!(delete.is_none());
                                assert_eq!(word(&payload, 4), 0);
                                delete = Some(word(&payload, 0) as usize);
                            }
                            0 => {
                                assert!(pending.is_none());
                                let length = word(&payload, 0) as usize;
                                assert_eq!(payload[4 + length - 1], 0);
                                pending = Some(
                                    std::str::from_utf8(&payload[4..4 + length - 1])
                                        .unwrap()
                                        .to_owned(),
                                );
                            }
                            3 => {
                                assert_eq!(word(&payload, 0), 1);
                                let start = cursor - delete.take().unwrap();
                                let text = pending.take().unwrap();
                                assert!(field.is_char_boundary(start));
                                field.replace_range(start..cursor, &text);
                                cursor = start + text.len();
                                for (opcode, payload) in state(&field, cursor, 0, 0, 0) {
                                    send!(&mut server, method, opcode, &payload);
                                }
                            }
                            _ => {
                                panic!("unexpected input-method request, including hardware grabs")
                            }
                        }
                    } else {
                        panic!("unexpected fictional protocol object");
                    }
                }
            }
        });
        (
            Self {
                sender,
                thread: Some(thread),
                requests,
            },
            client.into(),
        )
    }
    fn send(&self, events: Vec<(u16, Vec<u8>)>) {
        let (sender, receiver) = mpsc::sync_channel(1);
        self.sender.send(Control::Events(events, sender)).unwrap();
        receiver.recv_timeout(Duration::from_secs(2)).unwrap();
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.sender.send(Control::Stop);
        if let Some(thread) = self.thread.take() {
            let result = thread.join();
            if !thread::panicking() {
                result.unwrap();
            }
        }
    }
}
fn observe(connection: &Connection, serial: u32) -> Frame {
    let start = Instant::now();
    loop {
        connection.poll(25, &|| Ok(())).unwrap();
        if let Some(frame) = connection.frame().unwrap()
            && frame.context.serial == serial
        {
            return frame;
        }
        assert!(start.elapsed() < Duration::from_secs(2));
    }
}
#[test]
fn native_socketpair_replaces_utf8_bytes_and_publishes_a_fresh_acceptance_echo() {
    let (peer, fd) = Peer::new("normal");
    let mut connection = connect(fd, &|| Ok(())).unwrap();
    let frame = observe(&connection, 1);
    assert_eq!(frame.admitted_text(), Some("Public \\café tail"));
    connection
        .replace(&frame, "\\café".len() as u32, "Public 🙂", &|| Ok(()))
        .unwrap();
    let echo = observe(&connection, 2);
    assert_eq!(echo.admitted_text(), Some("Public Public 🙂 tail"));
    assert_eq!(echo.change_cause, 0);
    assert_eq!(
        peer.requests
            .lock()
            .unwrap()
            .iter()
            .map(|(opcode, _)| *opcode)
            .collect::<Vec<_>>(),
        [2, 0, 3]
    );
    drop(connection);
    assert_eq!(peer.requests.lock().unwrap().len(), 3);
}
#[test]
fn native_socketpair_refuses_missing_ambiguous_occupied_and_non_keyboard_seats() {
    for mode in ["missing", "two-seats", "occupied", "no-keyboard"] {
        let (peer, fd) = Peer::new(mode);
        assert!(connect(fd, &|| Ok(())).is_err());
        assert!(peer.requests.lock().unwrap().is_empty());
    }
}
#[test]
fn native_socketpair_revocation_and_pending_focus_or_private_text_send_no_replacement() {
    for changed in 0..4 {
        let (peer, fd) = Peer::new("normal");
        let mut connection = connect(fd, &|| Ok(())).unwrap();
        let frame = observe(&connection, 1);
        match changed {
            0 => (),
            1 => peer.send(vec![(1, vec![]), (0, vec![])]), // no done yet
            2 => peer.send(state("Fictional private", 17, 0, 8, 1)),
            3 => peer.send(vec![(6, vec![])]),
            _ => unreachable!(),
        }
        assert!(
            connection
                .replace(&frame, 6, "Public", &|| if changed == 0 {
                    Err(CHANGED)
                } else {
                    Ok(())
                })
                .is_err()
        );
        assert!(peer.requests.lock().unwrap().is_empty());
        if changed == 2 {
            let private = observe(&connection, 2);
            assert!(private.text.is_none() && private.admitted_text().is_none());
        }
        drop(connection);
        assert!(peer.requests.lock().unwrap().is_empty());
    }
}
#[test]
fn production_callbacks_wipe_private_text_and_publish_only_at_done() {
    let temporary = tempfile::tempdir().unwrap();
    let root = temporary.path();
    let xml = Path::new(env!("CARGO_MANIFEST_DIR")).join("data/input-method-v2.xml");
    for (mode, file) in [
        ("client-header", "snippets-ime.h"),
        ("private-code", "protocol.c"),
    ] {
        assert!(
            Command::new("wayland-scanner")
                .arg(mode)
                .arg(&xml)
                .arg(root.join(file))
                .status()
                .unwrap()
                .success()
        );
    }
    let flags = Command::new("pkg-config")
        .args(["--cflags", "--libs", "wayland-client"])
        .output()
        .unwrap();
    assert!(flags.status.success());
    let binary = root.join("inline-state-fixture");
    let compile = Command::new("cc")
        .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
        .arg("-I")
        .arg(root)
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/reference/inline-state.c"))
        .arg(root.join("protocol.c"))
        .args(
            std::str::from_utf8(&flags.stdout)
                .unwrap()
                .split_whitespace(),
        )
        .arg("-o")
        .arg(&binary)
        .output()
        .unwrap();
    assert!(
        compile.status.success(),
        "{}",
        String::from_utf8_lossy(&compile.stderr)
    );
    assert!(Command::new(binary).status().unwrap().success());
}
