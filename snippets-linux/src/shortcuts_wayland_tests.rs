//! Independent fictional wire peer. No compositor, bus, clipboard or input.
use super::*;
use std::{
    io::{Read, Write},
    os::{
        fd::{IntoRawFd, OwnedFd},
        unix::net::UnixStream,
    },
    sync::mpsc,
};
unsafe extern "C" {
    fn snip_shortcuts_connect_fd(
        fd: c_int,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
}
fn words(values: &[u32]) -> Vec<u8> {
    values.iter().flat_map(|v| v.to_ne_bytes()).collect()
}
fn word(bytes: &[u8], offset: usize) -> u32 {
    u32::from_ne_bytes(bytes[offset..offset + 4].try_into().unwrap())
}
fn string(value: &str) -> Vec<u8> {
    let mut data = words(&[value.len() as u32 + 1]);
    data.extend(value.as_bytes());
    data.push(0);
    while !data.len().is_multiple_of(4) {
        data.push(0);
    }
    data
}
fn decode(bytes: &[u8], position: &mut usize) -> String {
    let length = word(bytes, *position) as usize;
    *position += 4;
    assert!(length > 0 && bytes[*position + length - 1] == 0);
    let value = std::str::from_utf8(&bytes[*position..*position + length - 1])
        .unwrap()
        .to_owned();
    *position += (length + 3) & !3;
    value
}
fn send(stream: &mut std::fs::File, object: u32, opcode: u16, payload: &[u8]) -> bool {
    let mut data = words(&[
        object,
        ((payload.len() as u32 + 8) << 16) | u32::from(opcode),
    ]);
    data.extend(payload);
    stream.write_all(&data).is_ok()
}
enum Command {
    Events(Vec<(usize, u16)>),
    Remove,
}
struct Peer {
    sender: mpsc::Sender<Command>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Peer {
    fn new(mode: &'static str) -> (Self, OwnedFd) {
        let (server, client) = UnixStream::pair().unwrap();
        server.set_nonblocking(true).unwrap();
        let mut server = std::fs::File::from(OwnedFd::from(server));
        let (sender, receiver) = mpsc::channel();
        let thread = thread::spawn(move || {
            let (mut registry, mut manager) = (0, 0);
            let mut shortcuts = Vec::new();
            let mut input = Vec::new();
            loop {
                for command in receiver.try_iter() {
                    match command {
                        Command::Events(events) => {
                            for (index, opcode) in events {
                                assert_eq!(shortcuts.len(), 3);
                                if !send(
                                    &mut server,
                                    shortcuts[index],
                                    opcode,
                                    &words(&[
                                        0,
                                        1,
                                        if mode == "bad-nanoseconds" {
                                            1_000_000_000
                                        } else {
                                            0
                                        },
                                    ]),
                                ) {
                                    return;
                                }
                            }
                        }
                        Command::Remove => {
                            if !send(&mut server, registry, 1, &words(&[7])) {
                                return;
                            }
                        }
                    }
                }
                let mut buffer = [0; 4096];
                match server.read(&mut buffer) {
                    Ok(0) => return,
                    Ok(n) => input.extend_from_slice(&buffer[..n]),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => return,
                    Err(e) => panic!("fictional socket read: {}", e.kind()),
                }
                while input.len() >= 8 {
                    let object = word(&input, 0);
                    let header = word(&input, 4);
                    let length = (header >> 16) as usize;
                    let opcode = header as u16;
                    assert!((8..=4096).contains(&length));
                    if input.len() < length {
                        break;
                    }
                    let payload = input[8..length].to_vec();
                    input.drain(..length);
                    if object == 1 && opcode == 1 {
                        registry = word(&payload, 0);
                        if mode != "missing" {
                            let mut global = words(&[7]);
                            global.extend(string("hyprland_global_shortcuts_manager_v1"));
                            global.extend(words(&[1]));
                            if !send(&mut server, registry, 0, &global) {
                                return;
                            }
                            if mode == "duplicate" {
                                global[..4].copy_from_slice(&8u32.to_ne_bytes());
                                if !send(&mut server, registry, 0, &global) {
                                    return;
                                }
                            }
                        }
                    } else if object == registry && opcode == 0 {
                        assert_eq!(word(&payload, 0), 7);
                        manager = word(&payload, payload.len() - 4);
                    } else if object == 1 && opcode == 0 {
                        let callback = word(&payload, 0);
                        if mode == "stall" {
                            continue;
                        }
                        if !send(&mut server, callback, 0, &words(&[0]))
                            || !send(&mut server, 1, 1, &words(&[callback]))
                        {
                            return;
                        }
                    } else if object == manager && opcode == 0 {
                        let mut position = 4;
                        let id = decode(&payload, &mut position);
                        let app = decode(&payload, &mut position);
                        let description = decode(&payload, &mut position);
                        let trigger = decode(&payload, &mut position);
                        assert_eq!(id, ["open", "picker", "capture"][shortcuts.len()]);
                        assert_eq!(app, crate::desktop::APP_ID);
                        assert!(
                            description.starts_with("Open Snippets")
                                || description.starts_with("Snippets paste")
                                || description.starts_with("Capture clipboard")
                        );
                        assert!(trigger.is_empty());
                        assert_eq!(position, payload.len());
                        shortcuts.push(word(&payload, 0));
                    } else {
                        assert!(opcode == 0 || (object == manager && opcode == 1));
                    }
                }
            }
        });
        (
            Self {
                sender,
                thread: Some(thread),
            },
            client.into(),
        )
    }
    fn events(&self, events: Vec<(usize, u16)>) {
        self.sender.send(Command::Events(events)).unwrap();
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        if let Some(thread) = self.thread.take()
            && !thread::panicking()
        {
            thread.join().unwrap();
        }
    }
}
fn connect(fd: OwnedFd, guard: &dyn Fn() -> Result<()>) -> Result<Native> {
    let mut context = Check(guard);
    let mut status = 3;
    let pointer = unsafe {
        snip_shortcuts_connect_fd(
            fd.into_raw_fd(),
            check,
            (&mut context as *mut Check<'_>).cast(),
            &mut status,
        )
    };
    let native = Native(NonNull::new(pointer).ok_or(UNAVAILABLE)?);
    assert_eq!(status, 0);
    let result = unsafe {
        snip_shortcuts_start(
            native.0.as_ptr(),
            check,
            (&mut context as *mut Check<'_>).cast(),
        )
    };
    if result != 0 {
        return Err(UNAVAILABLE);
    }
    Ok(native)
}
fn event(native: &mut Native) -> Action {
    let start = std::time::Instant::now();
    loop {
        if let Some((action, _)) = native.next(&|| Ok(())).unwrap() {
            return action;
        }
        assert!(start.elapsed() < Duration::from_secs(2));
    }
}
#[test]
fn native_wire_registers_only_three_public_actions_and_suppresses_held_key_repeats() {
    let (peer, fd) = Peer::new("normal");
    let mut native = connect(fd, &|| Ok(())).unwrap();
    peer.events(vec![(0, 0), (0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (2, 1)]);
    assert_eq!(event(&mut native), Action::Open);
    assert_eq!(event(&mut native), Action::Picker);
    assert_eq!(event(&mut native), Action::Capture);
    assert!(native.next(&|| Ok(())).unwrap().is_none());
    peer.events(vec![(0, 0)]);
    assert_eq!(event(&mut native), Action::Open);
    assert!(native.next(&|| Err(STOPPED)).is_err());
    drop(native);
    drop(peer);
}
#[test]
fn native_wire_refuses_missing_duplicate_removed_and_malformed_protocol_state() {
    for mode in ["missing", "duplicate"] {
        let (peer, fd) = Peer::new(mode);
        assert!(connect(fd, &|| Ok(())).is_err());
        drop(peer);
    }
    let (peer, fd) = Peer::new("normal");
    let mut native = connect(fd, &|| Ok(())).unwrap();
    peer.sender.send(Command::Remove).unwrap();
    let start = std::time::Instant::now();
    while native.next(&|| Ok(())).is_ok() {
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    drop(native);
    drop(peer);
    let (peer, fd) = Peer::new("bad-nanoseconds");
    let mut native = connect(fd, &|| Ok(())).unwrap();
    peer.events(vec![(0, 0)]);
    let start = std::time::Instant::now();
    while native.next(&|| Ok(())).is_ok() {
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    drop(native);
    drop(peer);
}
#[test]
fn native_wire_burst_overflow_refuses_instead_of_replaying_partial_actions() {
    let (peer, fd) = Peer::new("normal");
    let mut native = connect(fd, &|| Ok(())).unwrap();
    peer.events((0..12).flat_map(|_| [(0, 0), (0, 1)]).collect());
    // Allow the independent writer to send the complete burst before polling.
    thread::sleep(Duration::from_millis(30));
    assert!(native.next(&|| Ok(())).is_err());
    drop(native);
    drop(peer);
}
#[test]
fn native_wire_connect_cancellation_releases_the_owned_descriptor() {
    let (peer, fd) = Peer::new("stall");
    let start = std::time::Instant::now();
    assert!(
        connect(fd, &|| if start.elapsed() < Duration::from_millis(30) {
            Ok(())
        } else {
            Err(STOPPED)
        })
        .is_err()
    );
    assert!(start.elapsed() < Duration::from_secs(1));
    drop(peer);
}
#[test]
#[ignore = "requires unrestricted native SO_PEERCRED; private socketpair only"]
fn native_shortcut_peer_credentials_match_the_independent_fixture() {
    let (peer, fd) = Peer::new("normal");
    let native = connect(fd, &|| Ok(())).unwrap();
    assert_eq!(
        unsafe { snip_shortcuts_peer(native.0.as_ptr()) },
        u64::from(std::process::id())
    );
    drop(native);
    drop(peer);
}
