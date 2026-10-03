//! Native desktop status item and public, closed DBusMenu action vocabulary.
//! The bus carries no library metadata, clipboard previews, credentials or bodies.
//! GApplication owns the authenticated session connection; this owner never
//! starts a bus, changes its environment or creates another application instance.
use crate::model::{Error, Result};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    rc::Rc,
};

const ITEM_PATH: &str = "/StatusNotifierItem";
const MENU_PATH: &str = "/com/khm/snippets/Menu";
const ITEM_INTERFACE: &str = "org.kde.StatusNotifierItem";
const MENU_INTERFACE: &str = "com.canonical.dbusmenu";
const WATCHER: &str = "org.kde.StatusNotifierWatcher";
const UNAVAILABLE: Error =
    Error("The desktop tray is unavailable. Open Snippets from the application launcher.");
const INVALID: Error = Error("Invalid desktop menu request.");
const UNKNOWN: Error = Error("Unknown desktop menu item or property.");
const DISABLED: Error = Error("This desktop action is currently unavailable.");

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Action {
    Open,
    Picker,
    Capture,
    History,
    Settings,
    Secure,
    Account,
    Quit,
}
impl Action {
    pub(crate) fn name(self) -> Option<&'static str> {
        match self {
            Self::Open => None,
            Self::Picker => Some("picker"),
            Self::Capture => Some("capture"),
            Self::History => Some("history"),
            Self::Settings => Some("settings"),
            Self::Secure => Some("secure"),
            Self::Account => Some("account"),
            Self::Quit => Some("quit"),
        }
    }
}
#[derive(Clone, Copy)]
struct Entry {
    id: i32,
    label: &'static str,
    icon: &'static str,
    action: Option<Action>,
}
const ENTRIES: [Entry; 9] = [
    Entry {
        id: 1,
        label: "Open Snippets",
        icon: "window-new-symbolic",
        action: Some(Action::Open),
    },
    Entry {
        id: 2,
        label: "Find a Snippet…",
        icon: "edit-find-symbolic",
        action: Some(Action::Picker),
    },
    Entry {
        id: 3,
        label: "Capture Clipboard",
        icon: "edit-paste-symbolic",
        action: Some(Action::Capture),
    },
    Entry {
        id: 4,
        label: "Clipboard History…",
        icon: "document-open-recent-symbolic",
        action: Some(Action::History),
    },
    Entry {
        id: 5,
        label: "Settings…",
        icon: "preferences-system-symbolic",
        action: Some(Action::Settings),
    },
    Entry {
        id: 6,
        label: "Secure Snippets…",
        icon: "changes-prevent-symbolic",
        action: Some(Action::Secure),
    },
    Entry {
        id: 7,
        label: "Account & Recovery…",
        icon: "avatar-default-symbolic",
        action: Some(Action::Account),
    },
    Entry {
        id: 8,
        label: "",
        icon: "",
        action: None,
    },
    Entry {
        id: 9,
        label: "Quit Snippets",
        icon: "application-exit-symbolic",
        action: Some(Action::Quit),
    },
];
type Properties = BTreeMap<String, glib::Variant>;
type Layout = (i32, Properties, Vec<glib::Variant>);
type Pixmaps = Vec<(i32, i32, Vec<u8>)>;

struct Menu {
    enabled: Box<dyn Fn(Action) -> bool>,
    activate: Box<dyn Fn(Action)>,
    revision: Cell<u32>,
    last_enabled: RefCell<Vec<bool>>,
    recovery: Cell<bool>,
    pixmaps: Pixmaps,
}
struct State {
    connection: gio::DBusConnection,
    menu: Rc<Menu>,
    owner: RefCell<Option<String>>,
    generation: Cell<u64>,
    registration: RefCell<Option<glib::JoinHandle<()>>>,
    registered: Cell<bool>,
}
pub(crate) struct Tray {
    state: Rc<State>,
    registrations: Vec<gio::RegistrationId>,
    unwatch: Option<Box<dyn FnOnce()>>,
}
fn ids() -> Vec<i32> {
    std::iter::once(0)
        .chain(ENTRIES.iter().map(|e| e.id))
        .collect()
}
fn valid_id(id: i32) -> bool {
    id == 0 || ENTRIES.iter().any(|e| e.id == id)
}
fn filter(properties: Properties, names: &[String]) -> Properties {
    properties
        .into_iter()
        .filter(|(name, _)| names.is_empty() || names.contains(name))
        .collect()
}
fn bounded_names(names: &[String]) -> Result<()> {
    if names.len() > 16 || names.iter().any(|s| s.len() > 128) {
        Err(INVALID)
    } else {
        Ok(())
    }
}
fn icon_pixmaps() -> Result<Pixmaps> {
    let icon = cairo::ImageSurface::create_from_png(&mut std::io::Cursor::new(include_bytes!(
        "../data/snippets-icon.png"
    )))
    .map_err(|_| UNAVAILABLE)?;
    [16, 32, 64]
        .into_iter()
        .map(|size| {
            let mut scaled = cairo::ImageSurface::create(cairo::Format::ARgb32, size, size)
                .map_err(|_| UNAVAILABLE)?;
            let context = cairo::Context::new(&scaled).map_err(|_| UNAVAILABLE)?;
            context.scale(
                f64::from(size) / f64::from(icon.width()),
                f64::from(size) / f64::from(icon.height()),
            );
            context
                .set_source_surface(&icon, 0.0, 0.0)
                .map_err(|_| UNAVAILABLE)?;
            context.paint().map_err(|_| UNAVAILABLE)?;
            drop(context);
            scaled.flush();
            let stride = scaled.stride() as usize;
            let bytes = scaled.data().map_err(|_| UNAVAILABLE)?;
            let mut argb = Vec::with_capacity(size as usize * size as usize * 4);
            for y in 0..size as usize {
                for x in 0..size as usize {
                    let start = y * stride + x * 4;
                    let pixel = u32::from_ne_bytes(
                        bytes
                            .get(start..start + 4)
                            .ok_or(UNAVAILABLE)?
                            .try_into()
                            .map_err(|_| UNAVAILABLE)?,
                    );
                    let alpha = pixel >> 24;
                    // Cairo stores native-endian premultiplied ARGB. The tray
                    // wire uses straight-alpha bytes in A,R,G,B network order.
                    let straight = |shift: u32| {
                        (((pixel >> shift) & 255) * 255 + alpha / 2)
                            .checked_div(alpha)
                            .unwrap_or(0)
                            .min(255) as u8
                    };
                    argb.extend_from_slice(&[alpha as u8, straight(16), straight(8), straight(0)]);
                }
            }
            Ok((size, size, argb))
        })
        .collect()
}
impl Menu {
    fn properties(&self, id: i32) -> Result<Properties> {
        let mut properties = Properties::new();
        if id == 0 {
            properties.insert("children-display".into(), "submenu".to_variant());
        } else {
            let entry = ENTRIES.iter().find(|e| e.id == id).ok_or(UNKNOWN)?;
            if let Some(action) = entry.action {
                properties.insert("label".into(), entry.label.to_variant());
                properties.insert("icon-name".into(), entry.icon.to_variant());
                properties.insert("enabled".into(), (self.enabled)(action).to_variant());
                properties.insert("visible".into(), true.to_variant());
            } else {
                properties.insert("type".into(), "separator".to_variant());
            }
        }
        Ok(properties)
    }
    fn layout(&self, id: i32, depth: i32, names: &[String]) -> Result<Layout> {
        bounded_names(names)?;
        if depth < -1 {
            return Err(INVALID);
        }
        let children = if id == 0 && depth != 0 {
            ENTRIES
                .iter()
                .map(|e| self.layout(e.id, 0, names).map(|l| l.to_variant()))
                .collect::<Result<_>>()?
        } else {
            Vec::new()
        };
        Ok((id, filter(self.properties(id)?, names), children))
    }
    fn event(&self, id: i32, event: &str) -> Result<()> {
        if !valid_id(id) {
            return Err(UNKNOWN);
        }
        if event.len() > 32 {
            return Err(INVALID);
        }
        if event == "clicked" {
            let action = ENTRIES
                .iter()
                .find(|e| e.id == id)
                .and_then(|e| e.action)
                .ok_or(DISABLED)?;
            if !(self.enabled)(action) {
                return Err(DISABLED);
            }
            (self.activate)(action);
        }
        Ok(())
    }
    fn request(
        &self,
        method: &str,
        parameters: &glib::Variant,
        changed: bool,
    ) -> Result<glib::Variant> {
        if parameters.size() > 8192 {
            return Err(INVALID);
        }
        match method {
            "GetLayout" => {
                let (id, depth, names) =
                    parameters.get::<(i32, i32, Vec<String>)>().ok_or(INVALID)?;
                Ok((self.revision.get(), self.layout(id, depth, &names)?).to_variant())
            }
            "GetGroupProperties" => {
                let (mut requested, names) =
                    parameters.get::<(Vec<i32>, Vec<String>)>().ok_or(INVALID)?;
                bounded_names(&names)?;
                if requested.len() > 32 {
                    return Err(INVALID);
                }
                if requested.is_empty() {
                    requested = ids();
                }
                let properties = requested
                    .into_iter()
                    .filter_map(|id| self.properties(id).ok().map(|p| (id, filter(p, &names))))
                    .collect::<Vec<_>>();
                Ok((properties,).to_variant())
            }
            "GetProperty" => {
                let (id, name) = parameters.get::<(i32, String)>().ok_or(INVALID)?;
                if name.len() > 128 {
                    return Err(INVALID);
                }
                let property = self.properties(id)?.remove(&name).ok_or(UNKNOWN)?;
                Ok((property,).to_variant())
            }
            "Event" => {
                let (id, event, _, _) = parameters
                    .get::<(i32, String, glib::Variant, u32)>()
                    .ok_or(INVALID)?;
                self.event(id, &event)?;
                Ok(().to_variant())
            }
            "EventGroup" => {
                let (events,) = parameters
                    .get::<(Vec<(i32, String, glib::Variant, u32)>,)>()
                    .ok_or(INVALID)?;
                if events.len() > 32 {
                    return Err(INVALID);
                }
                let errors = events
                    .into_iter()
                    .filter_map(|(id, event, _, _)| self.event(id, &event).err().map(|_| id))
                    .collect::<Vec<_>>();
                Ok((errors,).to_variant())
            }
            "AboutToShow" => {
                let (id,) = parameters.get::<(i32,)>().ok_or(INVALID)?;
                if !valid_id(id) {
                    return Err(UNKNOWN);
                }
                Ok((changed,).to_variant())
            }
            "AboutToShowGroup" => {
                let (requested,) = parameters.get::<(Vec<i32>,)>().ok_or(INVALID)?;
                if requested.len() > 32 {
                    return Err(INVALID);
                }
                let updates = requested
                    .iter()
                    .copied()
                    .filter(|id| changed && valid_id(*id))
                    .collect::<Vec<_>>();
                let errors = requested
                    .into_iter()
                    .filter(|id| !valid_id(*id))
                    .collect::<Vec<_>>();
                Ok((updates, errors).to_variant())
            }
            _ => Err(UNKNOWN),
        }
    }
    fn item_property(&self, name: &str) -> glib::Variant {
        match name {
            "Category" => "ApplicationStatus".to_variant(),
            "Id" => crate::desktop::APP_ID.to_variant(),
            "Title" => "Snippets".to_variant(),
            "Status" => if self.recovery.get() {
                "NeedsAttention"
            } else {
                "Active"
            }
            .to_variant(),
            "WindowId" => 0i32.to_variant(),
            "Menu" => glib::variant::ObjectPath::try_from(MENU_PATH)
                .expect("constant path")
                .to_variant(),
            "ItemIsMenu" => false.to_variant(),
            "IconPixmap" => self.pixmaps.to_variant(),
            "AttentionIconPixmap" => self.pixmaps.to_variant(),
            "OverlayIconPixmap" => Pixmaps::new().to_variant(),
            "ToolTip" => (
                "",
                Pixmaps::new(),
                "Snippets",
                if self.recovery.get() {
                    "Library recovery required"
                } else {
                    "Your personal library"
                },
            )
                .to_variant(),
            _ => "".to_variant(),
        }
    }
    fn update(&self, recovery: bool) -> (Vec<(i32, Properties)>, bool, bool) {
        let enabled = ENTRIES
            .iter()
            .map(|e| e.action.is_some_and(|a| (self.enabled)(a)))
            .collect::<Vec<_>>();
        let changed = *self.last_enabled.borrow() != enabled;
        let updated = if changed {
            let updated = ENTRIES
                .iter()
                .zip(&enabled)
                .zip(self.last_enabled.borrow().iter())
                .filter(|((_, new), old)| new != old)
                .map(|((e, enabled), _)| {
                    (
                        e.id,
                        BTreeMap::from([("enabled".into(), enabled.to_variant())]),
                    )
                })
                .collect::<Vec<(i32, Properties)>>();
            *self.last_enabled.borrow_mut() = enabled;
            self.revision
                .set(self.revision.get().wrapping_add(1).max(1));
            updated
        } else {
            Vec::new()
        };
        (
            updated,
            changed,
            self.recovery.replace(recovery) != recovery,
        )
    }
}
impl State {
    fn emit(&self, path: &str, interface: &str, name: &str, parameters: glib::Variant) {
        let _ = self
            .connection
            .emit_signal(None, path, interface, name, Some(&parameters));
    }
    fn refresh(&self, recovery: bool) -> bool {
        let (updated, changed, status_changed) = self.menu.update(recovery);
        if changed {
            self.emit(
                MENU_PATH,
                MENU_INTERFACE,
                "ItemsPropertiesUpdated",
                (updated, Vec::<(i32, Vec<String>)>::new()).to_variant(),
            );
            self.emit(
                MENU_PATH,
                MENU_INTERFACE,
                "LayoutUpdated",
                (self.menu.revision.get(), 0i32).to_variant(),
            );
        }
        if status_changed {
            self.emit(
                ITEM_PATH,
                ITEM_INTERFACE,
                "NewStatus",
                (if recovery { "NeedsAttention" } else { "Active" },).to_variant(),
            );
            self.emit(ITEM_PATH, ITEM_INTERFACE, "NewToolTip", ().to_variant());
        }
        changed
    }
    fn cancel_registration(&self) {
        self.generation.set(self.generation.get().wrapping_add(1));
        self.registered.set(false);
        self.owner.borrow_mut().take();
        if let Some(task) = self.registration.borrow_mut().take() {
            task.abort();
        }
    }
    fn register(self: &Rc<Self>, owner: &str) {
        self.cancel_registration();
        *self.owner.borrow_mut() = Some(owner.into());
        let generation = self.generation.get();
        let weak = Rc::downgrade(self);
        let owner = owner.to_owned();
        let task = glib::MainContext::default().spawn_local(async move {
            for retry in 0..3 {
                let Some(state) = weak.upgrade() else {
                    return;
                };
                if state.generation.get() != generation
                    || state.owner.borrow().as_deref() != Some(&owner)
                {
                    return;
                }
                let reply = state
                    .connection
                    .call_future(
                        Some(&owner),
                        "/StatusNotifierWatcher",
                        WATCHER,
                        "RegisterStatusNotifierItem",
                        Some(&(ITEM_PATH,).to_variant()),
                        None,
                        gio::DBusCallFlags::NO_AUTO_START,
                        2000,
                    )
                    .await;
                if state.generation.get() != generation {
                    return;
                }
                if reply.is_ok() {
                    state.registered.set(true);
                    state.registration.borrow_mut().take();
                    return;
                }
                drop(state);
                if retry != 2 {
                    glib::timeout_future(std::time::Duration::from_millis(500)).await;
                }
            }
            if let Some(state) = weak.upgrade()
                && state.generation.get() == generation
            {
                state.registration.borrow_mut().take();
            }
        });
        *self.registration.borrow_mut() = Some(task);
    }
}
fn reply(invocation: gio::DBusMethodInvocation, result: Result<glib::Variant>) {
    match result {
        Ok(value) => invocation.return_value(Some(&value)),
        Err(error) => invocation.return_dbus_error("com.khm.snippets.DesktopMenuError", error.0),
    }
}
impl Tray {
    pub(crate) fn new(
        connection: gio::DBusConnection,
        enabled: impl Fn(Action) -> bool + 'static,
        activate: impl Fn(Action) + 'static,
    ) -> Result<Rc<Self>> {
        if connection.is_closed() || connection.unique_name().is_none() {
            return Err(UNAVAILABLE);
        }
        let pixmaps = icon_pixmaps()?;
        let enabled = Box::new(enabled);
        let last_enabled = ENTRIES
            .iter()
            .map(|e| e.action.is_some_and(&enabled))
            .collect();
        let menu = Rc::new(Menu {
            enabled,
            activate: Box::new(activate),
            revision: Cell::new(1),
            last_enabled: RefCell::new(last_enabled),
            recovery: Cell::new(false),
            pixmaps,
        });
        let state = Rc::new(State {
            connection,
            menu,
            owner: RefCell::new(None),
            generation: Cell::new(0),
            registration: RefCell::new(None),
            registered: Cell::new(false),
        });
        let item_info = gio::DBusNodeInfo::for_xml(include_str!("../data/status-notifier.xml"))
            .map_err(|_| UNAVAILABLE)?;
        let menu_info = gio::DBusNodeInfo::for_xml(include_str!("../data/dbus-menu.xml"))
            .map_err(|_| UNAVAILABLE)?;
        let property_state = state.menu.clone();
        let method_state = state.menu.clone();
        let item = state
            .connection
            .register_object(
                ITEM_PATH,
                &item_info
                    .lookup_interface(ITEM_INTERFACE)
                    .ok_or(UNAVAILABLE)?,
            )
            .property(move |_, _, _, _, name| property_state.item_property(name))
            .method_call(move |_, _, _, _, method, parameters, invocation| {
                let result = match method {
                    "Activate" | "SecondaryActivate" | "ContextMenu" => {
                        if parameters.get::<(i32, i32)>().is_none() {
                            Err(INVALID)
                        } else {
                            let action = if method == "SecondaryActivate" {
                                Action::Picker
                            } else {
                                Action::Open
                            };
                            if (method_state.enabled)(action) {
                                (method_state.activate)(action);
                                Ok(().to_variant())
                            } else {
                                Err(DISABLED)
                            }
                        }
                    }
                    "Scroll" => {
                        if parameters.size() <= 128
                            && parameters
                                .get::<(i32, String)>()
                                .is_some_and(|(_, direction)| {
                                    matches!(direction.as_str(), "vertical" | "horizontal")
                                })
                        {
                            Ok(().to_variant())
                        } else {
                            Err(INVALID)
                        }
                    }
                    _ => Err(UNKNOWN),
                };
                reply(invocation, result);
            })
            .build()
            .map_err(|_| UNAVAILABLE)?;
        let menu_state = state.clone();
        let menu = state
            .connection
            .register_object(
                MENU_PATH,
                &menu_info
                    .lookup_interface(MENU_INTERFACE)
                    .ok_or(UNAVAILABLE)?,
            )
            .property(|_, _, _, _, name| match name {
                "Version" => 3u32.to_variant(),
                "TextDirection" => "ltr".to_variant(),
                "Status" => "normal".to_variant(),
                "IconThemePath" => Vec::<String>::new().to_variant(),
                _ => "".to_variant(),
            })
            .method_call(move |_, _, _, _, method, parameters, invocation| {
                let changed = menu_state.refresh(menu_state.menu.recovery.get());
                reply(
                    invocation,
                    menu_state.menu.request(method, &parameters, changed),
                );
            })
            .build();
        let menu = match menu {
            Ok(menu) => menu,
            Err(_) => {
                let _ = state.connection.unregister_object(item);
                return Err(UNAVAILABLE);
            }
        };
        let weak = Rc::downgrade(&state);
        let vanished = Rc::downgrade(&state);
        let watcher = gio::bus_watch_name_on_connection(
            &state.connection,
            WATCHER,
            gio::BusNameWatcherFlags::NONE,
            move |_, _, owner| {
                if let Some(state) = weak.upgrade() {
                    state.register(owner);
                }
            },
            move |_, _| {
                if let Some(state) = vanished.upgrade() {
                    state.cancel_registration();
                }
            },
        );
        Ok(Rc::new(Self {
            state,
            registrations: vec![item, menu],
            unwatch: Some(Box::new(move || gio::bus_unwatch_name(watcher))),
        }))
    }
    pub(crate) fn refresh(&self, recovery: bool) {
        self.state.refresh(recovery);
    }
}
impl Drop for Tray {
    fn drop(&mut self) {
        self.state.cancel_registration();
        if let Some(unwatch) = self.unwatch.take() {
            unwatch();
        }
        for registration in self.registrations.drain(..) {
            let _ = self.state.connection.unregister_object(registration);
        }
    }
}

#[cfg(test)]
#[path = "tray_tests.rs"]
mod tests;
