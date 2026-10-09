//! Real private bus; never connects to a desktop or its portal services.
use super::*;
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
};
const SESSION: &str = "/org/freedesktop/portal/desktop/session/1_1/snippets_public_fixture";
const OTHER: &str = "/org/freedesktop/portal/desktop/session/1_2/other_fixture";
const IMPL: &str = "org.freedesktop.impl.portal.Session";
struct Bus {
    process: Child,
    address: String,
}
impl Bus {
    fn new() -> Self {
        let mut process = Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--print-address=1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("private dbus-daemon");
        let mut address = String::new();
        BufReader::new(process.stdout.take().unwrap())
            .read_line(&mut address)
            .unwrap();
        Self {
            process,
            address: address.trim().to_owned(),
        }
    }
    fn connect(&self) -> gio::DBusConnection {
        connect(&self.address)
    }
}
impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}
fn connect(address: &str) -> gio::DBusConnection {
    let connection = gio::DBusConnection::for_address_sync(
        address,
        gio::DBusConnectionFlags::AUTHENTICATION_CLIENT
            | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
        None,
        None::<&gio::Cancellable>,
    )
    .unwrap();
    connection.set_exit_on_close(false);
    connection
}
struct Peer {
    connection: gio::DBusConnection,
    calls: Arc<Mutex<Vec<String>>>,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Peer {
    fn new(bus: &Bus, interface: &'static str) -> Self {
        let address = bus.address.clone();
        let calls = Arc::new(Mutex::new(vec![]));
        let stop = Arc::new(AtomicBool::new(false));
        let ending = stop.clone();
        let received = calls.clone();
        let (send, receive) = mpsc::channel();
        let thread = thread::spawn(move || {
            let context = glib::MainContext::new();
            context.with_thread_default(|| {
                let connection = connect(&address);
                let xml = format!("<node><interface name='{interface}'><method name='Close'/></interface></node>");
                let info = gio::DBusNodeInfo::for_xml(&xml).unwrap().lookup_interface(interface).unwrap();
                let registrations: Vec<_> = [SESSION, OTHER].into_iter().map(|path| {
                    let received = received.clone();
                    connection.register_object(path, &info).method_call(move |_, _, path, _, method, _, invocation| {
                        assert_eq!(method, "Close");
                        received.lock().unwrap().push(path.into());
                        invocation.return_value(None);
                    }).build().unwrap()
                }).collect();
                send.send(connection.clone()).unwrap();
                while !ending.load(Ordering::Acquire) {
                    while context.pending() { context.iteration(false); }
                    thread::sleep(Duration::from_millis(1));
                }
                for registration in registrations { let _ = connection.unregister_object(registration); }
                let _ = connection.close_sync(None::<&gio::Cancellable>);
            }).unwrap();
        });
        Self {
            connection: receive.recv_timeout(Duration::from_secs(5)).unwrap(),
            calls,
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        self.thread.take().unwrap().join().unwrap();
    }
}
fn portal(bus: &Bus, frontend: &gio::DBusConnection, backend: &gio::DBusConnection) -> Portal {
    Portal {
        context: glib::MainContext::new(),
        connection: bus.connect(),
        owner: frontend.unique_name().unwrap().to_string(),
        backend_owner: Some(backend.unique_name().unwrap().to_string()),
        session: Some(ObjectPath::try_from(SESSION).unwrap()),
        version: 1,
        subscriptions: vec![],
        revoked: Rc::new(Cell::new(false)),
        owner_lost: Rc::new(Cell::new(false)),
        session_closed: Rc::new(Cell::new(false)),
        bound: Rc::new(RefCell::new(HashSet::new())),
        queue: Rc::new(RefCell::new(VecDeque::new())),
        token: None,
    }
}
#[test]
fn cleanup_uses_frontend_and_releases_only_its_exact_orphan_at_the_pinned_backend() {
    let bus = Bus::new();
    let frontend = Peer::new(&bus, "org.freedesktop.portal.Session");
    let backend = Peer::new(&bus, IMPL);
    drop(portal(&bus, &frontend.connection, &backend.connection));
    assert_eq!(*frontend.calls.lock().unwrap(), vec![SESSION]);
    assert!(backend.calls.lock().unwrap().is_empty());

    // Unknown/closed session on a living frontend is not permission to bypass it.
    let living_frontend = bus.connect();
    drop(portal(&bus, &living_frontend, &backend.connection));
    assert!(backend.calls.lock().unwrap().is_empty());

    let orphan = portal(&bus, &living_frontend, &backend.connection);
    living_frontend
        .close_sync(None::<&gio::Cancellable>)
        .unwrap();
    let replacement = Peer::new(&bus, IMPL);
    let public_name = replacement
        .connection
        .call_sync(
            Some(BUS),
            "/org/freedesktop/DBus",
            BUS,
            "RequestName",
            Some(&(GNOME_BACKEND, 4u32).to_variant()),
            None,
            gio::DBusCallFlags::NONE,
            1000,
            None::<&gio::Cancellable>,
        )
        .unwrap();
    assert_eq!(public_name.get::<(u32,)>(), Some((1,)));
    drop(orphan);
    assert_eq!(*backend.calls.lock().unwrap(), vec![SESSION]);
    assert!(replacement.calls.lock().unwrap().is_empty());

    // A dead pinned backend must never forward cleanup to a replacement owner.
    let departed = bus.connect();
    let orphan = portal(&bus, &departed, &backend.connection);
    departed.close_sync(None::<&gio::Cancellable>).unwrap();
    backend
        .connection
        .close_sync(None::<&gio::Cancellable>)
        .unwrap();
    drop(orphan);
    assert!(replacement.calls.lock().unwrap().is_empty());
}
