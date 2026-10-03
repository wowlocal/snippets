use super::*;
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

fn menu(enabled: Rc<Cell<bool>>, actions: Rc<RefCell<Vec<Action>>>) -> Menu {
    Menu {
        enabled: Box::new(move |action| action == Action::Open || enabled.get()),
        activate: Box::new(move |action| actions.borrow_mut().push(action)),
        revision: Cell::new(1),
        last_enabled: RefCell::new(vec![true; ENTRIES.len()]),
        recovery: Cell::new(false),
        pixmaps: icon_pixmaps().unwrap(),
    }
}
type Enabled = Rc<Cell<bool>>;
type Actions = Rc<RefCell<Vec<Action>>>;
fn fixture() -> (Menu, Enabled, Actions) {
    let enabled = Rc::new(Cell::new(true));
    let actions = Rc::new(RefCell::new(Vec::new()));
    (menu(enabled.clone(), actions.clone()), enabled, actions)
}

#[test]
fn public_menu_wire_shapes_match_native_introspection() {
    let (menu, _, _) = fixture();
    let info = gio::DBusNodeInfo::for_xml(include_str!("../data/dbus-menu.xml")).unwrap();
    assert!(info.lookup_interface(MENU_INTERFACE).is_some());
    for (name, request, signature) in [
        (
            "GetLayout",
            (0i32, -1i32, Vec::<String>::new()).to_variant(),
            "(u(ia{sv}av))",
        ),
        (
            "GetGroupProperties",
            (Vec::<i32>::new(), Vec::<String>::new()).to_variant(),
            "(a(ia{sv}))",
        ),
        ("GetProperty", (1i32, "enabled").to_variant(), "(v)"),
        (
            "Event",
            (1i32, "opened", 0i32.to_variant(), 0u32).to_variant(),
            "()",
        ),
        (
            "EventGroup",
            (Vec::<(i32, String, glib::Variant, u32)>::new(),).to_variant(),
            "(ai)",
        ),
        ("AboutToShow", (0i32,).to_variant(), "(b)"),
        (
            "AboutToShowGroup",
            (vec![0i32, 999],).to_variant(),
            "(aiai)",
        ),
    ] {
        let result = menu.request(name, &request, false).unwrap();
        assert_eq!(result.type_().as_str(), signature, "{name}");
        assert!(result.is_normal_form());
    }
}

#[test]
fn layout_is_bounded_public_and_preserves_depth_and_property_filters() {
    let (menu, _, actions) = fixture();
    let (id, properties, children) = menu.layout(0, -1, &[]).unwrap();
    assert_eq!(id, 0);
    assert_eq!(
        properties["children-display"].get::<String>().as_deref(),
        Some("submenu")
    );
    assert_eq!(children.len(), 9);
    for (child, entry) in children.iter().zip(ENTRIES) {
        let (id, properties, children) = child.get::<Layout>().unwrap();
        assert_eq!(id, entry.id);
        assert!(children.is_empty());
        assert!(properties.keys().all(|key| matches!(
            key.as_str(),
            "label" | "icon-name" | "enabled" | "visible" | "type"
        )));
    }
    assert!(menu.layout(0, 0, &[]).unwrap().2.is_empty());
    assert_eq!(menu.layout(0, 1, &[]).unwrap().2.len(), 9);
    assert_eq!(menu.layout(1, -1, &["label".into()]).unwrap().1.len(), 1);
    assert!(
        menu.layout(1, 0, &["private-unknown".into()])
            .unwrap()
            .1
            .is_empty()
    );
    assert!(actions.borrow().is_empty());
}

#[test]
fn clicks_admit_only_closed_enabled_actions_and_ignore_navigation_events() {
    let (menu, enabled, actions) = fixture();
    for event in ["opened", "closed", "hovered", "unknown"] {
        menu.event(2, event).unwrap();
    }
    assert!(actions.borrow().is_empty());
    menu.event(2, "clicked").unwrap();
    assert_eq!(*actions.borrow(), [Action::Picker]);
    enabled.set(false);
    assert!(menu.event(2, "clicked").is_err());
    menu.event(1, "clicked").unwrap();
    assert_eq!(*actions.borrow(), [Action::Picker, Action::Open]);
    for id in [0, 8, 999, -1] {
        assert!(menu.event(id, "clicked").is_err());
    }
}

#[test]
fn malformed_and_oversized_requests_refuse_without_activating() {
    let (menu, _, actions) = fixture();
    for request in [
        ().to_variant(),
        "wrong".to_variant(),
        (0i32, -2i32, Vec::<String>::new()).to_variant(),
        (0i32, 1i32, vec!["label".to_string(); 17]).to_variant(),
        (0i32, 1i32, vec!["x".repeat(129)]).to_variant(),
    ] {
        assert!(menu.request("GetLayout", &request, false).is_err());
    }
    assert!(
        menu.request(
            "GetGroupProperties",
            &(vec![1i32; 33], Vec::<String>::new()).to_variant(),
            false
        )
        .is_err()
    );
    assert!(
        menu.request("GetProperty", &(1i32, "body").to_variant(), false)
            .is_err()
    );
    assert!(
        menu.request(
            "Event",
            &(1i32, "clicked", "x".repeat(9000).to_variant(), 0u32).to_variant(),
            false
        )
        .is_err()
    );
    let events = vec![(1i32, "clicked".to_string(), 0i32.to_variant(), 0u32); 33];
    assert!(
        menu.request("EventGroup", &(events,).to_variant(), false)
            .is_err()
    );
    assert!(actions.borrow().is_empty());
}

#[test]
fn event_and_show_groups_report_exact_invalid_ids() {
    let (menu, _, actions) = fixture();
    let events: Vec<(i32, String, glib::Variant, u32)> = vec![
        (1i32, "clicked".into(), 0i32.to_variant(), 0u32),
        (8, "clicked".into(), 0i32.to_variant(), 0),
        (99, "opened".into(), 0i32.to_variant(), 0),
    ];
    assert_eq!(
        menu.request("EventGroup", &(events,).to_variant(), false)
            .unwrap()
            .get::<(Vec<i32>,)>()
            .unwrap()
            .0,
        [8, 99]
    );
    assert_eq!(*actions.borrow(), [Action::Open]);
    let result = menu
        .request("AboutToShowGroup", &(vec![0i32, 1, 99],).to_variant(), true)
        .unwrap()
        .get::<(Vec<i32>, Vec<i32>)>()
        .unwrap();
    assert_eq!(result, (vec![0, 1], vec![99]));
}

#[test]
fn enabled_and_recovery_changes_have_bounded_typed_updates() {
    let (menu, enabled, _) = fixture();
    // The separator is always inert, including in the enabled snapshot.
    let _ = menu.update(false);
    let revision = menu.revision.get();
    assert_eq!(menu.update(false), (Vec::new(), false, false));
    enabled.set(false);
    let (properties, changed, status) = menu.update(true);
    assert!(changed && status);
    assert_eq!(properties.len(), 7);
    assert!(menu.revision.get() > revision);
    assert!(
        properties
            .iter()
            .all(|(_, props)| props.len() == 1 && props["enabled"].get::<bool>() == Some(false))
    );
    assert_eq!(
        menu.item_property("Status").get::<String>().as_deref(),
        Some("NeedsAttention")
    );
    assert_eq!(menu.update(true), (Vec::new(), false, false));
    assert!(menu.update(false).2);
    assert_eq!(
        menu.item_property("Status").get::<String>().as_deref(),
        Some("Active")
    );
}

#[test]
fn embedded_icon_and_item_properties_have_native_public_types() {
    let (menu, _, _) = fixture();
    assert_eq!(
        menu.pixmaps.iter().map(|p| p.0).collect::<Vec<_>>(),
        [16, 32, 64]
    );
    for (width, height, bytes) in &menu.pixmaps {
        assert_eq!(bytes.len(), (*width * *height * 4) as usize);
        assert!(bytes.as_chunks::<4>().0.iter().any(|p| p[0] > 0));
    }
    for (name, signature) in [
        ("Category", "s"),
        ("Id", "s"),
        ("Title", "s"),
        ("Status", "s"),
        ("WindowId", "i"),
        ("Menu", "o"),
        ("ItemIsMenu", "b"),
        ("IconPixmap", "a(iiay)"),
        ("OverlayIconPixmap", "a(iiay)"),
        ("ToolTip", "(sa(iiay)ss)"),
    ] {
        assert_eq!(menu.item_property(name).type_().as_str(), signature);
    }
    let tooltip = menu
        .item_property("ToolTip")
        .get::<(String, Pixmaps, String, String)>()
        .unwrap();
    assert_eq!(tooltip.2, "Snippets");
    assert_eq!(tooltip.3, "Your personal library");
    assert!(tooltip.1.is_empty());
}

fn reference_client(directory: &std::path::Path) -> std::path::PathBuf {
    let flags = Command::new("pkg-config")
        .args(["--cflags", "--libs", "gio-2.0", "cairo"])
        .output()
        .unwrap();
    assert!(flags.status.success());
    let client = directory.join("client");
    assert!(
        Command::new("cc")
            .args(["-std=c11", "-Wall", "-Wextra", "-Werror"])
            .arg(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/reference/tray-client.c")
            )
            .arg("-o")
            .arg(&client)
            .args(String::from_utf8(flags.stdout).unwrap().split_whitespace())
            .status()
            .unwrap()
            .success()
    );
    client
}
#[test]
fn independent_reference_client_decodes_native_argb_icon() {
    let directory = tempfile::tempdir().unwrap();
    let client = reference_client(directory.path());
    let bytes = directory.path().join("pixmaps.bin");
    let (menu, _, _) = fixture();
    std::fs::write(&bytes, menu.item_property("IconPixmap").data()).unwrap();
    let image = directory.path().join("public-tray.png");
    assert!(
        Command::new(client)
            .arg("--pixmaps")
            .arg(bytes)
            .arg(&image)
            .status()
            .unwrap()
            .success()
    );
    let decoded =
        cairo::ImageSurface::create_from_png(&mut std::fs::File::open(&image).unwrap()).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (64, 64));
    let artifacts =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("target/tray-verification");
    std::fs::create_dir_all(&artifacts).unwrap();
    std::fs::copy(image, artifacts.join("public-tray.png")).unwrap();
}

struct PrivateBus(Child);
impl Drop for PrivateBus {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn pump_until(context: &glib::MainContext, mut condition: impl FnMut() -> bool) {
    let start = Instant::now();
    while !condition() {
        assert!(
            start.elapsed() < Duration::from_secs(8),
            "isolated native fixture deadline"
        );
        while context.pending() {
            context.iteration(false);
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
#[test]
#[ignore = "requires a private authenticated D-Bus daemon; public fixture, no GTK/user bus/keyring/clipboard/input"]
fn isolated_native_tray_registration_restart_and_reference_client() {
    let directory = tempfile::tempdir().unwrap();
    let address = format!("unix:path={}", directory.path().join("bus").display());
    let daemon = Command::new("dbus-daemon")
        .args(["--session", "--nofork", "--print-address=1"])
        .arg(format!("--address={address}"))
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut daemon = PrivateBus(daemon);
    let mut announced = String::new();
    BufReader::new(daemon.0.stdout.take().unwrap())
        .read_line(&mut announced)
        .unwrap();
    assert!(announced.starts_with(&address));
    let client = reference_client(directory.path());
    let context = glib::MainContext::default();
    let _guard = context.acquire().unwrap();
    let connection = gio::DBusConnection::for_address_sync(
        announced.trim(),
        gio::DBusConnectionFlags::AUTHENTICATION_CLIENT
            | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
        None,
        None::<&gio::Cancellable>,
    )
    .expect("private authenticated bus");
    connection.set_exit_on_close(false);
    let received = Rc::new(RefCell::new(Vec::new()));
    let registrations = received.clone();
    let info = gio::DBusNodeInfo::for_xml("<node><interface name='org.kde.StatusNotifierWatcher'><method name='RegisterStatusNotifierItem'><arg type='s' direction='in'/></method></interface></node>").unwrap();
    let registration = connection
        .register_object(
            "/StatusNotifierWatcher",
            &info.lookup_interface(WATCHER).unwrap(),
        )
        .method_call(move |_, sender, _, _, _, parameters, invocation| {
            let (path,) = parameters.get::<(String,)>().unwrap();
            assert_eq!(path, ITEM_PATH);
            registrations.borrow_mut().push(sender.unwrap().to_owned());
            invocation.return_value(Some(&().to_variant()));
        })
        .build()
        .unwrap();
    let actions = Rc::new(RefCell::new(Vec::new()));
    let selected = actions.clone();
    let tray = Tray::new(
        connection.clone(),
        |action| action != Action::Capture,
        move |action| selected.borrow_mut().push(action),
    )
    .unwrap();
    tray.refresh(true);
    let request_name = |method: &str, parameters: glib::Variant| {
        context
            .block_on(connection.call_future(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                method,
                Some(&parameters),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                2000,
            ))
            .unwrap()
    };
    request_name("RequestName", (WATCHER, 0u32).to_variant());
    pump_until(&context, || {
        received.borrow().len() == 1 && tray.state.registered.get()
    });
    assert_eq!(received.borrow()[0], connection.unique_name().unwrap());
    request_name("ReleaseName", (WATCHER,).to_variant());
    pump_until(&context, || !tray.state.registered.get());
    request_name("RequestName", (WATCHER, 0u32).to_variant());
    pump_until(&context, || {
        received.borrow().len() == 2 && tray.state.registered.get()
    });
    let image = directory.path().join("public-tray.png");
    let mut child = Command::new(&client)
        .arg(announced.trim())
        .arg(connection.unique_name().unwrap())
        .arg(&image)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pump_until(&context, || child.try_wait().unwrap().is_some());
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "reference client exit {:?}",
        output.status.code()
    );
    assert_eq!(
        *actions.borrow(),
        [Action::Open, Action::Settings, Action::Open]
    );
    assert!(std::fs::metadata(&image).unwrap().len() > 0);
    let artifacts =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("target/tray-verification");
    std::fs::create_dir_all(&artifacts).unwrap();
    std::fs::copy(&image, artifacts.join("public-tray.png")).unwrap();
    drop(tray);
    assert!(connection.unregister_object(registration).is_ok());
    connection.close_sync(None::<&gio::Cancellable>).unwrap();
}
