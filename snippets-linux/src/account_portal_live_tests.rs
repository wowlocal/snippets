//! Test-only OpenFile relay from the isolated account bus to the real desktop.
//! Host replies and read-only GTK appearance settings are relayed unchanged.
//! No host keyring or mutable settings interface is exposed.
use super::*;
use glib::variant::ObjectPath;
use gtk::gio;
use std::collections::{BTreeSet, HashMap};

const DESKTOP: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const CHOOSER: &str = "org.freedesktop.portal.FileChooser";
const REQUEST: &str = "org.freedesktop.portal.Request";
const DBUS: &str = "org.freedesktop.DBus";
type Expected = (bool, Option<BTreeSet<PathBuf>>);
static EXPECTED: std::sync::Mutex<Option<Expected>> = std::sync::Mutex::new(None);
pub(super) fn enabled() -> bool {
    std::env::var("SNIPPETS_ACCOUNT_PORTAL").as_deref() == Ok("real-host-open-file")
}
pub(super) fn expect(multiple: bool, paths: Option<&[PathBuf]>) {
    if enabled() {
        let mut value = EXPECTED.lock().unwrap();
        assert!(value.is_none());
        *value = Some((multiple, paths.map(|p| p.iter().cloned().collect())));
    }
}
struct Pending {
    path: String,
    sender: String,
    registration: gio::RegistrationId,
    expected: Option<BTreeSet<PathBuf>>,
}
#[derive(Default)]
struct Counts {
    opened: usize,
    responses: usize,
    cancelled: usize,
    closed: usize,
    multiple: usize,
}
struct Peer {
    private: gio::DBusConnection,
    host: gio::DBusConnection,
    registration: Option<gio::RegistrationId>,
    subscription: Option<gio::SignalSubscription>,
    settings: Option<gio::RegistrationId>,
    unsupported: Vec<gio::RegistrationId>,
    pending: Rc<RefCell<HashMap<String, Pending>>>,
    counts: Rc<RefCell<Counts>>,
    check: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
fn call(
    connection: &gio::DBusConnection,
    destination: &str,
    path: &str,
    interface: &str,
    method: &str,
    parameters: &glib::Variant,
) -> glib::Variant {
    connection
        .call_sync(
            Some(destination),
            path,
            interface,
            method,
            Some(parameters),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            5000,
            None::<&gio::Cancellable>,
        )
        .unwrap()
}
fn request_path(sender: &str, token: &str) -> String {
    assert!(
        sender.starts_with(':')
            && token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_')
            && !token.is_empty()
    );
    format!("{PATH}/request/{}/{}", sender[1..].replace('.', "_"), token)
}
impl Peer {
    fn new(check: std::sync::Arc<std::sync::atomic::AtomicBool>) -> Self {
        let address = std::env::var("SNIPPETS_SECRET_HOST_BUS").unwrap();
        assert!(std::env::var("DBUS_SESSION_BUS_ADDRESS").unwrap() != address);
        let private = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>).unwrap();
        let host = gio::DBusConnection::for_address_sync(
            &address,
            gio::DBusConnectionFlags::AUTHENTICATION_CLIENT
                | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
            None,
            None::<&gio::Cancellable>,
        )
        .unwrap();
        host.set_exit_on_close(false);
        let (owner,) = call(
            &host,
            DBUS,
            "/org/freedesktop/DBus",
            DBUS,
            "GetNameOwner",
            &(DESKTOP,).to_variant(),
        )
        .get::<(String,)>()
        .unwrap();
        let version = call(
            &host,
            &owner,
            PATH,
            "org.freedesktop.DBus.Properties",
            "Get",
            &(CHOOSER, "version").to_variant(),
        )
        .child_get::<glib::Variant>(0)
        .get::<u32>()
        .unwrap();
        assert!(version >= 3);
        assert!(
            call(
                &private,
                DBUS,
                "/org/freedesktop/DBus",
                DBUS,
                "RequestName",
                &(DESKTOP, 4u32).to_variant()
            )
            .get::<(u32,)>()
                == Some((1,))
        );
        let pending = Rc::new(RefCell::new(HashMap::<String, Pending>::new()));
        let counts = Rc::new(RefCell::new(Counts::default()));
        let requests = pending.clone();
        let observed = counts.clone();
        let local = private.clone();
        let subscription = host.subscribe_to_signal(
            Some(&owner),
            Some(REQUEST),
            Some("Response"),
            None,
            None,
            gio::DBusSignalFlags::NONE,
            move |signal| {
                let path = signal.object_path;
                let parameters = signal.parameters;
                let Some(request) = requests.borrow_mut().remove(path) else {
                    return;
                };
                let (response, results) = parameters
                    .get::<(u32, HashMap<String, glib::Variant>)>()
                    .unwrap();
                if let Some(expected) = request.expected {
                    assert!(response == 0);
                    let actual = results["uris"]
                        .get::<Vec<String>>()
                        .unwrap()
                        .into_iter()
                        .map(|uri| gio::File::for_uri(&uri).path().unwrap())
                        .collect::<BTreeSet<_>>();
                    assert!(
                        actual == expected,
                        "Only actual owned public fixture selections may reach credentials: actual_count={}, expected_count={}, each_parent_owned={}.", actual.len(), expected.len(), actual.iter().all(|p| expected.iter().any(|e| p.parent() == e.parent()))
                    );
                } else {
                    assert!(
                        matches!(response, 1 | 2),
                        "The real host aborted chooser returned {response}."
                    );
                    assert!(
                        results
                            .get("uris")
                            .is_none_or(|v| v.get::<Vec<String>>().is_some_and(|p| p.is_empty()))
                    );
                    observed.borrow_mut().cancelled += 1;
                }
                // Emit the original host payload only, without constructing results.
                local
                    .emit_signal(
                        Some(&request.sender),
                        &request.path,
                        REQUEST,
                        "Response",
                        Some(parameters),
                    )
                    .unwrap();
                local.unregister_object(request.registration).unwrap();
                observed.borrow_mut().responses += 1;
            },
        );
        let requests = pending.clone();
        let observed = counts.clone();
        let remote = host.clone();
        let settings_owner = owner.clone();
        let info = gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.portal.FileChooser'><property name='version' type='u' access='read'/><method name='OpenFile'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method></interface></node>").unwrap();
        let registration = private.register_object(PATH, &info.lookup_interface(CHOOSER).unwrap()).property(move |_, _, _, _, property| { assert!(property == "version"); version.to_variant() }).method_call(move |connection, sender, _, _, method, parameters, invocation| {
            assert!(method == "OpenFile");
            let sender = sender.unwrap();
            assert!(call(&connection, DBUS, "/org/freedesktop/DBus", DBUS, "GetConnectionUnixProcessID", &(sender,).to_variant()).get::<(u32,)>() == Some((std::process::id(),)));
            let (parent, title, mut options) = parameters.get::<(String, String, HashMap<String, glib::Variant>)>().unwrap();
            assert!(parent.starts_with("wayland:") && title == "Choose Previous Vault File");
            let (multiple, expected) = EXPECTED.lock().unwrap().take().unwrap();
            assert!(options.get("multiple").and_then(|v| v.get::<bool>()).unwrap_or(false) == multiple);
            // Keep the multi-selection fixture out of the host Recent list.
            // This is only a folder suggestion; it cannot select files or
            // construct successful results. All other GTK options are retained.
            if let Some(paths) = &expected && paths.len() > 1 {
                let directory = paths.first().unwrap().parent().unwrap();
                assert!(directory.starts_with(std::env::var("XDG_DATA_HOME").unwrap()));
                assert!(paths.iter().all(|p| p.parent() == Some(directory)));
                assert!(fs::read_dir(directory).unwrap().map(|e| e.unwrap().path()).collect::<BTreeSet<_>>() == *paths);
                assert!(!options.contains_key("current_folder"));
                let mut folder = directory.as_os_str().as_encoded_bytes().to_vec(); folder.push(0);
                options.insert("current_folder".into(), folder.to_variant());
            }
            let parameters = (parent, title, options.clone()).to_variant();
            let token = options["handle_token"].get::<String>().unwrap();
            let private_path = request_path(sender, &token);
            let host_path = request_path(&remote.unique_name().unwrap(), &token);
            let closing = remote.clone();
            let close_owner = owner.clone();
            let close_path = host_path.clone();
            let closed = observed.clone();
            let close_requests = requests.clone();
            let request_info = gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.portal.Request'><method name='Close'/><signal name='Response'><arg type='u'/><arg type='a{sv}'/></signal></interface></node>").unwrap();
            let registration = connection.register_object(&private_path, &request_info.lookup_interface(REQUEST).unwrap()).method_call(move |connection, sender, _, _, method, _, invocation| {
                assert!(method == "Close");
                let request = close_requests.borrow_mut().remove(&close_path).unwrap();
                assert!(sender == Some(request.sender.as_str()));
                let remote = closing.clone(); let owner = close_owner.clone(); let path = close_path.clone();
                glib::MainContext::ref_thread_default().spawn_local(async move { remote.call_future(Some(&owner), &path, REQUEST, "Close", None, None, gio::DBusCallFlags::NO_AUTO_START, 5000).await.unwrap(); });
                connection.unregister_object(request.registration).unwrap();
                closed.borrow_mut().closed += 1;
                invocation.return_value(None);
            }).build().unwrap();
            assert!(requests.borrow_mut().insert(host_path.clone(), Pending {path: private_path.clone(), sender: sender.into(), registration, expected}).is_none());
            { let mut count = observed.borrow_mut(); count.opened += 1; count.multiple += usize::from(multiple); }
            invocation.return_value(Some(&(ObjectPath::try_from(private_path.as_str()).unwrap(),).to_variant()));
            let remote = remote.clone(); let owner = owner.clone();
            glib::MainContext::ref_thread_default().spawn_local(async move {
                let actual = remote.call_future(Some(&owner), PATH, CHOOSER, "OpenFile", Some(&parameters), None, gio::DBusCallFlags::NO_AUTO_START, 5000).await.unwrap();
                assert!(actual.child_get::<ObjectPath>(0).as_str() == host_path);
            });
        }).build().unwrap();
        let remote = host.clone();
        let settings_version = call(
            &host,
            &settings_owner,
            PATH,
            "org.freedesktop.DBus.Properties",
            "Get",
            &("org.freedesktop.portal.Settings", "version").to_variant(),
        )
        .child_get::<glib::Variant>(0)
        .get::<u32>()
        .unwrap();
        let info = gio::DBusNodeInfo::for_xml("<node><interface name='org.freedesktop.portal.Settings'><property name='version' type='u' access='read'/><method name='ReadAll'><arg type='as' direction='in'/><arg type='a{sa{sv}}' direction='out'/></method><method name='ReadOne'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method><method name='Read'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method></interface></node>").unwrap();
        let settings = private
            .register_object(
                PATH,
                &info
                    .lookup_interface("org.freedesktop.portal.Settings")
                    .unwrap(),
            )
            .property(move |_, _, _, _, property| {
                assert!(property == "version");
                settings_version.to_variant()
            })
            .method_call(move |_, _, _, _, method, parameters, invocation| {
                if method == "ReadAll" {
                    assert!(
                        parameters
                            .child_get::<Vec<String>>(0)
                            .iter()
                            .all(|v| v == "org.gnome.*" || v == "org.freedesktop.appearance")
                    );
                } else {
                    assert!(
                        matches!(method, "Read" | "ReadOne")
                            && (parameters.child_get::<String>(0) == "org.freedesktop.appearance"
                                || parameters.child_get::<String>(0).starts_with("org.gnome."))
                    );
                }
                let result = remote.call_sync(
                    Some(&settings_owner),
                    PATH,
                    "org.freedesktop.portal.Settings",
                    method,
                    Some(&parameters),
                    None,
                    gio::DBusCallFlags::NO_AUTO_START,
                    5000,
                    None::<&gio::Cancellable>,
                );
                match result {
                    Ok(value) => invocation.return_value(Some(&value)),
                    Err(error) => invocation.return_gerror(error),
                }
            })
            .build()
            .unwrap();
        // Version zero declares unsupported capabilities to GTK's normal
        // negotiation. No session monitor or registry request is forwarded.
        let unsupported = ["org.freedesktop.portal.Inhibit", "org.freedesktop.host.portal.Registry"].into_iter().map(|interface| {
            let info = gio::DBusNodeInfo::for_xml(&format!("<node><interface name='{interface}'><property name='version' type='u' access='read'/></interface></node>")).unwrap();
            private.register_object(PATH, &info.lookup_interface(interface).unwrap()).property(|_, _, _, _, property| { assert!(property == "version"); 0u32.to_variant() }).build().unwrap()
        }).collect();
        assert!(
            call(
                &private,
                DBUS,
                "/org/freedesktop/DBus",
                DBUS,
                "ListActivatableNames",
                &().to_variant()
            )
            .child_get::<Vec<String>>(0)
            .contains(&DESKTOP.to_owned())
        );
        Self {
            private,
            host,
            registration: Some(registration),
            subscription: Some(subscription),
            settings: Some(settings),
            unsupported,
            pending,
            counts,
            check,
        }
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        if !thread::panicking() && self.check.load(std::sync::atomic::Ordering::SeqCst) {
            assert!(self.pending.borrow().is_empty());
            assert!(EXPECTED.lock().unwrap().is_none());
            let counts = self.counts.borrow();
            assert!(
                counts.opened > 0
                    && counts.cancelled > 0
                    && counts.opened == counts.responses + counts.closed
            );
            println!(
                "Actual host FileChooser portal: {} OpenFile requests, {} unchanged authenticated responses, {} cancellations, {} multiple requests; no pending requests, host keyring access or fabricated selections.",
                counts.opened, counts.responses, counts.cancelled, counts.multiple
            );
        }
        self.subscription.take();
        for (_, request) in self.pending.borrow_mut().drain() {
            self.private
                .unregister_object(request.registration)
                .unwrap();
        }
        for registration in self.unsupported.drain(..) {
            self.private.unregister_object(registration).unwrap();
        }
        if let Some(settings) = self.settings.take() {
            self.private.unregister_object(settings).unwrap();
        }
        if let Some(registration) = self.registration.take() {
            self.private.unregister_object(registration).unwrap();
        }
        call(
            &self.private,
            DBUS,
            "/org/freedesktop/DBus",
            DBUS,
            "ReleaseName",
            &(DESKTOP,).to_variant(),
        );
        self.host.close_sync(None::<&gio::Cancellable>).unwrap();
    }
}

// GTK reads settings synchronously during init. Export the narrow relay on a
// separate main context so its synchronous request cannot block its own service.
pub(super) struct Bridge {
    main_loop: glib::MainLoop,
    thread: Option<std::thread::JoinHandle<()>>,
    check: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
impl Bridge {
    pub(super) fn optional() -> Option<Self> {
        if !enabled() {
            return None;
        }
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let check = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let checking = check.clone();
        let thread = std::thread::spawn(move || {
            let context = glib::MainContext::new();
            context
                .with_thread_default(|| {
                    let _peer = Peer::new(checking);
                    let main_loop = glib::MainLoop::new(Some(&context), false);
                    sender.send(main_loop.clone()).unwrap();
                    main_loop.run();
                })
                .unwrap();
        });
        Some(Self {
            main_loop: receiver.recv_timeout(Duration::from_secs(10)).unwrap(),
            thread: Some(thread),
            check,
        })
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        let panicking = thread::panicking();
        if panicking {
            self.check.store(false, std::sync::atomic::Ordering::SeqCst);
        }
        self.main_loop.quit();
        let result = self.thread.take().unwrap().join();
        if !panicking {
            result.unwrap();
        }
    }
}

#[test]
#[ignore = "actual host chooser smoke test; private bus/keyring; invoke tests/account-live.sh --portal-chooser"]
fn live_host_filechooser_smoke() {
    assert!(enabled());
    glib::set_prgname(Some("snippets-public-account-fixture"));
    glib::set_application_name("Snippets Public Account Fixture");
    let _bridge = Bridge::optional().unwrap();
    let root = isolated_root();
    let directory = root.parent().unwrap().join("public-portal-sources");
    fs::create_dir(&directory).unwrap();
    let paths = [
        directory.join("public source A.json"),
        directory.join("public source C.snippetsbackup"),
    ];
    for path in &paths {
        model::atomic_write(path, b"Public fictional chooser smoke input").unwrap();
    }
    let (app, parent) = automatic_parent();
    for mode in 0..3 {
        let multiple = mode == 2;
        let expected = if mode == 0 {
            None
        } else if multiple {
            Some(paths.as_slice())
        } else {
            Some(&paths[..1])
        };
        expect(multiple, expected);
        let dialog = gtk::FileDialog::builder()
            .title("Choose Previous Vault File")
            .modal(true)
            .build();
        let outcome = Rc::new(RefCell::new(None));
        let result = outcome.clone();
        let window = parent.clone();
        glib::MainContext::default().spawn_local(async move {
            let selected = if multiple {
                dialog
                    .open_multiple_future(Some(&window))
                    .await
                    .map(|files| {
                        (0..files.n_items())
                            .map(|i| {
                                files
                                    .item(i)
                                    .and_downcast::<gio::File>()
                                    .unwrap()
                                    .path()
                                    .unwrap()
                            })
                            .collect::<BTreeSet<_>>()
                    })
            } else {
                dialog
                    .open_future(Some(&window))
                    .await
                    .map(|file| BTreeSet::from([file.path().unwrap()]))
            };
            *result.borrow_mut() = Some(selected);
        });
        let chooser = crate::portal_live_tests::chooser("Choose Previous Vault File");
        if mode == 0 {
            chooser.key("", "Escape");
        } else {
            chooser.select_multiple(expected.unwrap());
        }
        until("actual portal callback did not finish", || {
            outcome.borrow().is_some()
        });
        let result = outcome.borrow_mut().take().unwrap();
        if let Some(expected) = expected {
            assert!(result.unwrap() == expected.iter().cloned().collect());
        } else {
            assert!(result.is_err());
        }
        until("actual portal did not return parent focus", || {
            parent.is_active()
        });
        println!(
            "Actual host chooser smoke step {mode} returned its authenticated result and parent focus."
        );
    }
    parent.destroy();
    app.quit();
    fs::remove_dir_all(directory).unwrap();
    println!(
        "Actual host chooser smoke passed: Cancel, single file with spaces and exact JSON/backup multiple selection returned authenticated responses and parent focus."
    );
}
