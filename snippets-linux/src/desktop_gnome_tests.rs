//! A real private D-Bus daemon and fictional Shell. Never locks the desktop.
use super::*;
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::Instant,
};

struct Bus {
    child: Child,
    address: String,
}
impl Bus {
    fn new() -> Self {
        let mut child = Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--print-address=1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("dbus-daemon is required for the private GNOME fixture");
        let mut address = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut address)
            .unwrap();
        Self {
            child,
            address: address.trim().into(),
        }
    }
    fn connection(&self) -> gio::DBusConnection {
        connect(&self.address)
    }
}
impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn connect(address: &str) -> gio::DBusConnection {
    let value = gio::DBusConnection::for_address_sync(
        address,
        gio::DBusConnectionFlags::AUTHENTICATION_CLIENT
            | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
        None,
        None::<&gio::Cancellable>,
    )
    .unwrap();
    value.set_exit_on_close(false);
    value
}
fn name(connection: &gio::DBusConnection, name: &str, acquire: bool) {
    let args = if acquire {
        (name, 4u32).to_variant()
    } else {
        (name,).to_variant()
    };
    let result = connection
        .call_sync(
            Some(BUS),
            BUS_PATH,
            BUS,
            if acquire {
                "RequestName"
            } else {
                "ReleaseName"
            },
            Some(&args),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            1000,
            None::<&gio::Cancellable>,
        )
        .unwrap();
    assert_eq!(result.get::<(u32,)>(), Some((1,)));
}
fn signal(connection: &gio::DBusConnection, active: bool) {
    connection
        .emit_signal(
            None,
            PATH,
            SAVER,
            "ActiveChanged",
            Some(&(active,).to_variant()),
        )
        .unwrap();
    connection.flush_sync(None::<&gio::Cancellable>).unwrap();
}
struct Peer {
    connection: gio::DBusConnection,
    active: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Peer {
    fn new(bus: &Bus) -> Self {
        let address = bus.address.clone();
        let active = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let state = active.clone();
        let ending = stop.clone();
        let (sender, receiver) = mpsc::channel();
        let thread = thread::spawn(move || {
            let context = glib::MainContext::new();
            context.with_thread_default(|| {
                let connection = connect(&address);
                let info = gio::DBusNodeInfo::for_xml("<node><interface name='org.gnome.ScreenSaver'><method name='GetActive'><arg direction='out' type='b'/></method><signal name='ActiveChanged'><arg type='b'/></signal></interface></node>").unwrap();
                let registration = connection.register_object(PATH, &info.lookup_interface(SAVER).unwrap())
                    .method_call(move |_, _, _, _, method, _, invocation| {
                        assert_eq!(method, "GetActive");
                        invocation.return_value(Some(&(state.load(Ordering::Acquire),).to_variant()));
                    }).build().unwrap();
                name(&connection, SHELL, true); name(&connection, SAVER, true);
                sender.send(connection.clone()).unwrap();
                while !ending.load(Ordering::Acquire) {
                    while context.pending() { context.iteration(false); }
                    thread::sleep(Duration::from_millis(1));
                }
                connection.unregister_object(registration).unwrap();
                let _ = connection.close_sync(None::<&gio::Cancellable>);
            }).unwrap();
        });
        Self {
            connection: receiver.recv_timeout(Duration::from_secs(5)).unwrap(),
            active,
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
fn settle(context: &glib::MainContext) {
    let start = Instant::now();
    while start.elapsed() < Duration::from_millis(100) {
        while context.pending() {
            context.iteration(false);
        }
        thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn gnome_lock_monitor_tracks_cycles_ignores_strangers_and_revokes_on_owner_loss() {
    let bus = Bus::new();
    let peer = Peer::new(&bus);
    let context = glib::MainContext::new();
    context
        .with_thread_default(|| {
            let shared = super::super::SessionWitness::test(SessionState::Unavailable, 0).0;
            let mut monitor = Monitor::new(shared.clone());
            monitor.connect_on(bus.connection()).unwrap();
            monitor.refresh();
            settle(&context);
            monitor.refresh();
            assert!(shared.lock().unwrap().snapshot().0 == SessionState::Unlocked);
            let epoch = shared.lock().unwrap().epoch;
            signal(&bus.connection(), true);
            settle(&context);
            assert_eq!(shared.lock().unwrap().epoch, epoch);
            peer.active.store(true, Ordering::Release);
            signal(&peer.connection, true);
            peer.active.store(false, Ordering::Release);
            signal(&peer.connection, false);
            settle(&context);
            monitor.refresh();
            let mut value = shared.lock().unwrap();
            assert!(value.epoch > epoch);
            assert!(
                value.snapshot().0 == SessionState::Unavailable,
                "A rapid lock/unlock must remain observable to vault revocation"
            );
            value.revoked_until = Duration::ZERO;
            drop(value);
            monitor.refresh();
            assert!(shared.lock().unwrap().snapshot().0 == SessionState::Unlocked);
            name(&peer.connection, SHELL, false);
            name(&peer.connection, SAVER, false);
            settle(&context);
            monitor.refresh();
            assert!(shared.lock().unwrap().snapshot().0 == SessionState::Unavailable);
            // A different owner claiming ScreenSaver must not authorize Shell.
            let other = bus.connection();
            name(&other, SAVER, true);
            assert!(read(monitor.connection.as_ref().unwrap()).is_none());
            other.close_sync(None::<&gio::Cancellable>).unwrap();
            monitor
                .connection
                .as_ref()
                .unwrap()
                .close_sync(None::<&gio::Cancellable>)
                .unwrap();
            settle(&context);
            assert!(shared.lock().unwrap().snapshot().0 == SessionState::Unavailable);
        })
        .unwrap();
}

#[test]
fn gnome_read_handles_locked_unlocked_and_absent_services() {
    let bus = Bus::new();
    let connection = bus.connection();
    assert!(read(&connection).is_none());
    let peer = Peer::new(&bus);
    assert!(read(&connection).unwrap().1 == SessionState::Unlocked);
    // Modern GNOME uses a separate ScreenSaver proxy; its owner need not
    // equal Shell's. Only Shell's implementation and signals are trusted.
    name(&peer.connection, SAVER, false);
    let proxy = bus.connection();
    name(&proxy, SAVER, true);
    assert!(read(&connection).unwrap().1 == SessionState::Unlocked);
    peer.active.store(true, Ordering::Release);
    assert!(read(&connection).unwrap().1 == SessionState::Locked);
    drop(peer);
    assert!(read(&connection).is_none());
}
