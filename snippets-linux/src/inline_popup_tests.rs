//! Raw private Wayland fixture, including FD transfer. No display lookup or peer bypass.
use super::*;
use std::{
    collections::{BTreeMap, VecDeque},
    os::fd::{AsRawFd, FromRawFd},
};
const MAP: &str = r#"xkb_keymap {
xkb_keycodes "public" { minimum=8; maximum=255; <AC01>=38; <RTRN>=36; <DOWN>=116; <UP>=111; <ESC>=9; <TAB>=23; };
xkb_types "public" { type "ONE_LEVEL" { modifiers=None; map[None]=Level1; level_name[Level1]="Any"; }; };
xkb_compatibility "public" {};
xkb_symbols "public" { key <AC01> { [ a ] }; key <RTRN> { [ Return ] }; key <DOWN> { [ Down ] }; key <UP> { [ Up ] }; key <ESC> { [ Escape ] }; key <TAB> { [ Tab ] }; };
};"#;
fn receive(
    stream: &std::fs::File,
    bytes: &mut [u8],
    fds: &mut VecDeque<OwnedFd>,
) -> std::io::Result<usize> {
    let mut control = [0u64; 32];
    let mut iov = libc::iovec {
        iov_base: bytes.as_mut_ptr().cast(),
        iov_len: bytes.len(),
    };
    let mut header: libc::msghdr = unsafe { std::mem::zeroed() };
    header.msg_iov = &mut iov;
    header.msg_iovlen = 1;
    header.msg_control = control.as_mut_ptr().cast();
    header.msg_controllen = std::mem::size_of_val(&control);
    let received =
        unsafe { libc::recvmsg(stream.as_raw_fd(), &mut header, libc::MSG_CMSG_CLOEXEC) };
    if received < 0 {
        return Err(std::io::Error::last_os_error());
    }
    assert_eq!(header.msg_flags & libc::MSG_CTRUNC, 0);
    unsafe {
        let mut entry = libc::CMSG_FIRSTHDR(&header);
        while !entry.is_null() {
            assert_eq!((*entry).cmsg_level, libc::SOL_SOCKET);
            assert_eq!((*entry).cmsg_type, libc::SCM_RIGHTS);
            let length = (*entry).cmsg_len - libc::CMSG_LEN(0) as usize;
            assert_eq!(length % std::mem::size_of::<i32>(), 0);
            let data = libc::CMSG_DATA(entry).cast::<i32>();
            for i in 0..length / std::mem::size_of::<i32>() {
                fds.push_back(OwnedFd::from_raw_fd(*data.add(i)));
            }
            entry = libc::CMSG_NXTHDR(&header, entry);
        }
    }
    Ok(received as usize)
}
fn send_map(stream: &std::fs::File, grab: u32) {
    let mut file = tempfile::tempfile().unwrap();
    file.write_all(MAP.as_bytes()).unwrap();
    file.write_all(&[0]).unwrap();
    let payload = words(&[1, MAP.len() as u32 + 1]);
    let mut bytes = words(&[grab, ((payload.len() as u32 + 8) << 16)]);
    bytes.extend(payload);
    let mut control = [0u64; 4];
    let mut iov = libc::iovec {
        iov_base: bytes.as_mut_ptr().cast(),
        iov_len: bytes.len(),
    };
    let mut header: libc::msghdr = unsafe { std::mem::zeroed() };
    header.msg_iov = &mut iov;
    header.msg_iovlen = 1;
    header.msg_control = control.as_mut_ptr().cast();
    header.msg_controllen = unsafe { libc::CMSG_SPACE(4) } as usize;
    unsafe {
        let entry = libc::CMSG_FIRSTHDR(&header);
        (*entry).cmsg_level = libc::SOL_SOCKET;
        (*entry).cmsg_type = libc::SCM_RIGHTS;
        (*entry).cmsg_len = libc::CMSG_LEN(4) as usize;
        *libc::CMSG_DATA(entry).cast::<i32>() = file.as_raw_fd();
        assert_eq!(
            libc::sendmsg(stream.as_raw_fd(), &header, 0),
            bytes.len() as isize
        );
    }
}
#[derive(Default)]
struct Seen {
    roles: usize,
    grabs: usize,
    releases: usize,
    commits: usize,
    buffers: usize,
    maps: usize,
    forwarded: Vec<(u16, Vec<u8>)>,
}
enum Action {
    Keys(Vec<(u16, Vec<u8>)>, mpsc::SyncSender<()>),
    Field(Vec<(u16, Vec<u8>)>, mpsc::SyncSender<()>),
    Quit,
}
pub(crate) struct PopupPeer {
    commands: mpsc::Sender<Action>,
    thread: Option<thread::JoinHandle<()>>,
    seen: Arc<Mutex<Seen>>,
}
impl PopupPeer {
    pub(crate) fn new() -> (Self, OwnedFd) {
        Self::with_releases(true)
    }
    fn with_releases(release_buffers: bool) -> (Self, OwnedFd) {
        let (client, remote) = UnixStream::pair().unwrap();
        remote.set_nonblocking(true).unwrap();
        let mut stream = std::fs::File::from(OwnedFd::from(remote));
        let (commands, rx) = mpsc::channel();
        let seen = Arc::new(Mutex::new(Seen::default()));
        let observed = seen.clone();
        let thread = thread::spawn(move || {
            let mut input = vec![];
            let mut fds = VecDeque::new();
            let mut objects = BTreeMap::from([(1, "display")]);
            let (mut method, mut seat, mut grab, mut attached) = (0, 0, 0, 0);
            let mut pool: Option<std::fs::File> = None;
            loop {
                while let Ok(action) = rx.try_recv() {
                    let (object, events, ack) = match action {
                        Action::Quit => return,
                        Action::Keys(events, ack) => (grab, events, ack),
                        Action::Field(events, ack) => (method, events, ack),
                    };
                    assert_ne!(object, 0);
                    for (opcode, payload) in events {
                        send!(&mut stream, object, opcode, &payload);
                    }
                    ack.send(()).unwrap();
                }
                let mut buffer = [0; 8192];
                match receive(&stream, &mut buffer, &mut fds) {
                    Ok(0) => return,
                    Ok(n) => input.extend_from_slice(&buffer[..n]),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1));
                        continue;
                    }
                    Err(e) => panic!("public fixture read: {}", e.kind()),
                }
                while input.len() >= 8 {
                    let object = word(&input, 0);
                    let header = word(&input, 4);
                    let n = (header >> 16) as usize;
                    let opcode = header as u16;
                    assert!((8..=8192).contains(&n) && n.is_multiple_of(4));
                    if input.len() < n {
                        break;
                    }
                    let payload = input[8..n].to_vec();
                    input.drain(..n);
                    match (objects[&object], opcode) {
                        ("display", 1) => {
                            let registry = word(&payload, 0);
                            objects.insert(registry, "registry");
                            for (name, interface) in [
                                (1, "wl_seat"),
                                (3, "zwp_input_method_manager_v2"),
                                (4, "wl_compositor"),
                                (5, "wl_shm"),
                                (6, "zwp_virtual_keyboard_manager_v1"),
                            ] {
                                let mut global = words(&[name]);
                                global.extend(string(interface));
                                global.extend(words(&[1]));
                                send!(&mut stream, registry, 0, &global);
                            }
                        }
                        ("registry", 0) => {
                            let name = word(&payload, 0);
                            let id = word(&payload, payload.len() - 4);
                            let kind = match name {
                                1 => "seat",
                                3 => "ime-manager",
                                4 => "compositor",
                                5 => "shm",
                                6 => "vk-manager",
                                _ => panic!("global"),
                            };
                            objects.insert(id, kind);
                            if name == 1 {
                                seat = id;
                                send!(&mut stream, id, 0, &words(&[2]));
                            }
                            if name == 5 {
                                send!(&mut stream, id, 0, &words(&[0]));
                            }
                        }
                        ("display", 0) => {
                            let id = word(&payload, 0);
                            send!(&mut stream, id, 0, &words(&[0]));
                            send!(&mut stream, 1, 1, &words(&[id]));
                        }
                        ("ime-manager", 0) => {
                            assert_eq!(word(&payload, 0), seat);
                            method = word(&payload, 4);
                            objects.insert(method, "method");
                            send!(&mut stream, method, 0, &[]);
                            for (op, p) in state("Public \\ca", 10, 0, 0, 1) {
                                send!(&mut stream, method, op, &p);
                            }
                        }
                        ("method", 4) => {
                            let id = word(&payload, 0);
                            assert_eq!(objects[&word(&payload, 4)], "surface");
                            objects.insert(id, "role");
                            observed.lock().unwrap().roles += 1;
                            send!(&mut stream, id, 0, &words(&[0, 0, 10, 20]));
                        }
                        ("method", 5) => {
                            grab = word(&payload, 0);
                            objects.insert(grab, "grab");
                            observed.lock().unwrap().grabs += 1; /* repeat_info is legal before map */
                            send!(&mut stream, grab, 3, &words(&[25, 400]));
                            send_map(&stream, grab);
                        }
                        ("compositor", 0) => {
                            objects.insert(word(&payload, 0), "surface");
                        }
                        ("compositor", 1) => {
                            objects.insert(word(&payload, 0), "region");
                        }
                        ("region", 0) => {
                            objects.remove(&object);
                        }
                        ("shm", 0) => {
                            objects.insert(word(&payload, 0), "pool");
                            let file = std::fs::File::from(fds.pop_front().expect("pixel FD"));
                            assert_eq!(
                                file.metadata().unwrap().len(),
                                u64::from(word(&payload, 4))
                            );
                            pool = Some(file);
                        }
                        ("pool", 0) => {
                            let id = word(&payload, 0);
                            objects.insert(id, "buffer");
                            assert_eq!(word(&payload, 8), 360);
                            assert_eq!(word(&payload, 16), 1440);
                            assert_eq!(word(&payload, 20), 0);
                            let mut pixels = vec![];
                            pool.as_mut().unwrap().read_to_end(&mut pixels).unwrap();
                            assert_eq!(pixels.len(), 360 * word(&payload, 12) as usize * 4);
                            assert!(pixels.as_chunks::<4>().0.iter().all(|p| p[3] == 255));
                            assert!(pixels.as_chunks::<4>().0.iter().any(|p| p != &pixels[..4]));
                            observed.lock().unwrap().buffers += 1;
                        }
                        ("pool", 1) => {
                            objects.remove(&object);
                            pool = None;
                        }
                        ("buffer", 0) => {
                            objects.remove(&object);
                        }
                        ("surface", 1) => {
                            attached = word(&payload, 0);
                        }
                        ("surface", 2 | 5) => (),
                        ("surface", 6) => {
                            observed.lock().unwrap().commits += 1;
                            if attached != 0 && release_buffers {
                                send!(&mut stream, attached, 0, &[]);
                            }
                        }
                        ("vk-manager", 0) => {
                            assert_eq!(word(&payload, 0), seat);
                            objects.insert(word(&payload, 4), "keyboard");
                        }
                        ("keyboard", 0) => {
                            assert_eq!(word(&payload, 0), 1);
                            let file = std::fs::File::from(fds.pop_front().expect("keymap FD"));
                            let mut bytes = vec![0; word(&payload, 4) as usize];
                            std::os::unix::fs::FileExt::read_exact_at(&file, &mut bytes, 0)
                                .unwrap();
                            assert_eq!(&bytes[..bytes.len() - 1], MAP.as_bytes());
                            assert_eq!(bytes.len(), word(&payload, 4) as usize);
                            observed.lock().unwrap().maps += 1;
                        }
                        ("keyboard", 1 | 2) => {
                            observed.lock().unwrap().forwarded.push((opcode, payload));
                        }
                        ("keyboard", 3) => {
                            objects.remove(&object);
                        }
                        ("grab", 0) => {
                            observed.lock().unwrap().releases += 1;
                            objects.remove(&object);
                            grab = 0;
                        }
                        other => panic!("unexpected public fixture request {other:?}"),
                    }
                }
            }
        });
        (
            Self {
                commands,
                thread: Some(thread),
                seen,
            },
            client.into(),
        )
    }
    pub(crate) fn send(&self, keys: bool, events: Vec<(u16, Vec<u8>)>) {
        let (tx, rx) = mpsc::sync_channel(1);
        self.commands
            .send(if keys {
                Action::Keys(events, tx)
            } else {
                Action::Field(events, tx)
            })
            .unwrap();
        rx.recv_timeout(Duration::from_secs(2)).unwrap();
    }
}
#[test]
fn native_backpressure_and_keyboard_overflow_bound_memory_and_refuse_stale_selection() {
    let (peer, fd) = PopupPeer::with_releases(false);
    let connection = connect(fd, &|| Ok(())).unwrap();
    let frame = observe(&connection, 1);
    for _ in 0..4 {
        assert!(connection.popup(&choice(frame.copy()), &|| Ok(())).unwrap());
    }
    assert!(!connection.popup(&choice(frame.copy()), &|| Ok(())).unwrap());
    keys(&connection);
    peer.send(false, state("Public \\cal", 11, 0, 0, 1));
    let updated = observe(&connection, 2);
    assert!(!connection.popup(&choice(updated), &|| Ok(())).unwrap());
    peer.send(true, vec![(1, words(&[2, 10, 28, 1]))]);
    let key = keys(&connection).remove(0);
    assert_eq!(key.context().serial, 2);
    assert!(suggestions::command(key.symbol, key.modifiers).is_none());
    connection.route(&key, false, &|| Ok(())).unwrap();
    assert_eq!(peer.seen.lock().unwrap().buffers, 4);
    peer.send(true, (0..33).map(|i| (1, words(&[2, i, 30, 1]))).collect());
    let deadline = Instant::now() + Duration::from_secs(2);
    while connection.poll(25, &|| Ok(())).is_ok() {
        assert!(
            Instant::now() < deadline,
            "native overflow must stop the transport"
        );
    }
    assert!(connection.key().is_none());
    drop(connection);
}
impl Drop for PopupPeer {
    fn drop(&mut self) {
        let _ = self.commands.send(Action::Quit);
        if let Some(t) = self.thread.take() {
            let r = t.join();
            if !thread::panicking() {
                r.unwrap();
            }
        }
    }
}
fn choice(frame: Frame) -> suggestions::Choice {
    let mut snippets = vec![
        Snippet::new("Public cafeteria", "Fictional body"),
        Snippet::new("Public calendar", "Other fictional body"),
    ];
    snippets[0].keyword = "cafeteria".into();
    snippets[1].keyword = "calendar".into();
    let mut baseline = frame.copy();
    baseline.context.serial = 0;
    baseline.text = Some(Zeroizing::new("Public ".into()));
    baseline.cursor = 7;
    baseline.anchor = 7;
    let mut model = suggestions::Suggestions::default();
    model.observe(baseline, &snippets, &crate::usage::Snapshot::default());
    let suggestions::Observation::Choices(choice) =
        model.observe(frame, &snippets, &crate::usage::Snapshot::default())
    else {
        panic!("public choices")
    };
    choice
}
fn keys(connection: &Connection) -> Vec<Key> {
    connection.poll(25, &|| Ok(())).unwrap();
    let mut keys = vec![];
    while let Some(key) = connection.key() {
        keys.push(key)
    }
    keys
}
#[test]
fn native_popup_preserves_focus_renders_metadata_and_routes_exact_raw_key_pairs() {
    let (peer, fd) = PopupPeer::new();
    let connection = connect(fd, &|| Ok(())).unwrap();
    let frame = observe(&connection, 1);
    assert!(connection.popup(&choice(frame), &|| Ok(())).unwrap());
    let initial = keys(&connection);
    assert_eq!(initial.len(), 1);
    assert_eq!(initial[0].kind, 2);
    assert_eq!(initial[0].repeat(), (25, 400));
    peer.send(
        true,
        vec![
            (1, words(&[1, 10, 30, 1])),
            (1, words(&[1, 11, 30, 0])),
            (1, words(&[1, 12, 108, 1])),
            (1, words(&[1, 13, 108, 0])),
        ],
    );
    let input = keys(&connection);
    assert_eq!(input.len(), 4);
    assert_eq!(input[0].symbol, 0x61);
    assert_eq!(input[2].symbol, 0xff54);
    for event in &input {
        connection
            .route(event, event.key == 108, &|| Ok(()))
            .unwrap();
    }
    connection.hide_popup(&|| Ok(())).unwrap();
    let seen = peer.seen.lock().unwrap();
    assert_eq!(
        (
            seen.roles,
            seen.grabs,
            seen.releases,
            seen.maps,
            seen.buffers
        ),
        (1, 1, 1, 1, 1)
    );
    assert_eq!(
        seen.forwarded
            .iter()
            .filter(|r| r.0 == 1)
            .map(|r| (word(&r.1, 0), word(&r.1, 4), word(&r.1, 8)))
            .collect::<Vec<_>>(),
        [(10, 30, 1), (11, 30, 0)]
    );
    drop(seen);
    drop(connection);
}
#[test]
fn native_popup_refuses_revoked_private_changed_and_unpresented_contexts_before_key_delivery() {
    for changed in 0..4 {
        let (peer, fd) = PopupPeer::new();
        let connection = connect(fd, &|| Ok(())).unwrap();
        let frame = observe(&connection, 1);
        assert!(connection.popup(&choice(frame), &|| Ok(())).unwrap());
        keys(&connection);
        peer.send(true, vec![(1, words(&[1, 10, 30, 1]))]);
        let key = keys(&connection).remove(0);
        match changed {
            0 => (),
            1 => peer.send(false, state("Public \\cal", 11, 0, 0, 1)),
            2 => peer.send(false, state("Fictional private", 17, 0, 8, 1)),
            _ => peer.send(false, vec![(1, vec![]), (0, vec![])]),
        }
        if changed > 0 {
            connection.poll(25, &|| Ok(())).unwrap();
        }
        assert!(
            connection
                .route(&key, false, &|| if changed == 0 {
                    Err(CHANGED)
                } else {
                    Ok(())
                })
                .is_err()
        );
        assert!(peer.seen.lock().unwrap().forwarded.is_empty());
        drop(connection);
    }
}
unsafe extern "C" {
    fn snip_popup_render(
        pixels: *mut c_void,
        bytes: usize,
        rows: *const RawRow,
        count: u32,
        selected: u32,
        colors: *const u32,
    ) -> c_int;
}
#[test]
fn native_renderer_validates_utf8_ranges_sizes_and_changes_selected_row_without_markup() {
    let values = [
        suggestions::Row {
            name: "Public <b>Café</b> 🙂".into(),
            keyword: "cafeteria".into(),
            pinned: true,
            name_matches: vec![(10, 15)],
            keyword_matches: vec![(0, 2)],
        },
        suggestions::Row {
            name: "Public calendar".into(),
            keyword: "calendar".into(),
            pinned: false,
            name_matches: vec![],
            keyword_matches: vec![(0, 2)],
        },
    ];
    let mut rows = values.iter().map(row).collect::<Result<Vec<_>>>().unwrap();
    let palette = [0x202124, 0xf1f3f4, 0x8ab4f8];
    let mut pixels = vec![0u32; 360 * (2 * 56 + 36)];
    let render = |pixels: &mut Vec<u32>, rows: &[RawRow], selected: u32| unsafe {
        snip_popup_render(
            pixels.as_mut_ptr().cast(),
            pixels.len() * 4,
            rows.as_ptr(),
            rows.len() as u32,
            selected,
            palette.as_ptr(),
        )
    };
    assert_eq!(render(&mut pixels, &rows, 0), 1);
    assert!(pixels.iter().all(|p| p >> 24 == 255));
    let before = pixels.clone();
    assert_eq!(render(&mut pixels, &rows, 1), 1);
    assert_ne!(before, pixels);
    assert_eq!(render(&mut pixels, &rows, 2), 0);
    rows[0].names[0] = Span { start: 14, end: 15 };
    assert_eq!(render(&mut pixels, &rows, 0), 0); // split é
    rows[0].name[0] = 0xff;
    assert_eq!(render(&mut pixels, &rows, 0), 0);
    let mut short = vec![0u32; 1];
    assert_eq!(render(&mut short, &rows, 0), 0);
}
