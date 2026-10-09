//! GNOME global-shortcuts portal. Only public action labels cross this bus.
//! A private D-Bus connection owns the portal session and dies with this backend.
use super::*;
use glib::variant::ObjectPath;
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, HashSet, VecDeque},
    rc::Rc,
    time::Instant,
};

const PORTAL: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const API: &str = "org.freedesktop.portal.GlobalShortcuts";
const BUS: &str = "org.freedesktop.DBus";
type Options = HashMap<String, glib::Variant>;

fn action(id: &str) -> Option<Action> {
    match id {
        "open" => Some(Action::Open),
        "picker" => Some(Action::Picker),
        "capture" => Some(Action::Capture),
        _ => None,
    }
}
fn bindings(value: &glib::Variant) -> Option<HashSet<String>> {
    if value.size() > 16384 {
        return None;
    }
    let rows = value.get::<Vec<(String, Options)>>()?;
    if rows.len() > 3 {
        return None;
    }
    let mut result = HashSet::new();
    for (id, _) in rows {
        action(&id)?;
        if !result.insert(id) {
            return None;
        }
    }
    Some(result)
}
fn activation(
    parameters: &glib::Variant,
    session: &str,
    bound: &HashSet<String>,
    now_ms: u32,
) -> Option<(Action, Duration, Option<String>)> {
    if parameters.size() > 16384 {
        return None;
    }
    let (path, id, timestamp, options) = parameters.get::<(ObjectPath, String, u64, Options)>()?;
    if path.as_str() != session || !bound.contains(&id) {
        return None;
    }
    // GNOME forwards Mutter's uint32 monotonic event time (milliseconds), not
    // wall-clock time. Wrapping subtraction covers its roughly 49-day rollover.
    // Unknown/future clocks fail closed instead of reviving a delayed action.
    let age = now_ms.wrapping_sub(u32::try_from(timestamp).ok()?);
    if age > 1500 {
        return None;
    }
    let token = match options.get("activation_token") {
        None => None,
        Some(value) => {
            let text = value.get::<String>()?;
            if text.is_empty() || text.len() > 4096 || text.chars().any(char::is_control) {
                return None;
            }
            Some(text)
        }
    };
    Some((action(&id)?, Duration::from_millis(age.into()), token))
}

struct Pending<'a> {
    connection: &'a gio::DBusConnection,
    owner: &'a str,
    path: String,
}
impl Drop for Pending<'_> {
    fn drop(&mut self) {
        let _ = self.connection.call_sync(
            Some(self.owner),
            &self.path,
            "org.freedesktop.portal.Request",
            "Close",
            None,
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            250,
            None::<&gio::Cancellable>,
        );
    }
}
struct Queued {
    action: Action,
    age: Duration,
    token: Option<String>,
    received: Instant,
}
pub(super) struct Portal {
    context: glib::MainContext,
    connection: gio::DBusConnection,
    owner: String,
    session: Option<ObjectPath>,
    version: u32,
    subscriptions: Vec<gio::SignalSubscription>,
    revoked: Rc<Cell<bool>>,
    bound: Rc<RefCell<HashSet<String>>>,
    queue: Rc<RefCell<VecDeque<Queued>>>,
    token: Option<String>,
}
impl Portal {
    pub(super) fn open(guard: &dyn Fn() -> Result<()>) -> Result<Self> {
        let context = glib::MainContext::new();
        context
            .with_thread_default(|| Self::connect(context.clone(), guard))
            .map_err(|_| UNAVAILABLE)?
    }
    fn call(
        &self,
        path: &str,
        interface: &str,
        method: &str,
        parameters: Option<&glib::Variant>,
    ) -> Result<glib::Variant> {
        self.connection
            .call_sync(
                Some(&self.owner),
                path,
                interface,
                method,
                parameters,
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                2000,
                None::<&gio::Cancellable>,
            )
            .map_err(|_| UNAVAILABLE)
    }
    fn live(&self) -> Result<()> {
        if self.revoked.get() || self.connection.is_closed() {
            Err(UNAVAILABLE)
        } else {
            Ok(())
        }
    }
    fn drain(&self) {
        // Bound each pump so a busy or hostile peer cannot starve cancellation.
        for _ in 0..64 {
            if !self.context.pending() {
                break;
            }
            self.context.iteration(false);
        }
    }
    fn request(
        &self,
        method: &str,
        token: &str,
        parameters: glib::Variant,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<Options> {
        guard()?;
        self.live()?;
        let sender = self.connection.unique_name().ok_or(UNAVAILABLE)?;
        let path = format!(
            "{PATH}/request/{}/{}",
            sender.trim_start_matches(':').replace('.', "_"),
            token
        );
        let pending = Pending {
            connection: &self.connection,
            owner: &self.owner,
            path,
        };
        let response = Rc::new(RefCell::new(None));
        let result = response.clone();
        let owner = self.owner.clone();
        let subscription = self.connection.subscribe_to_signal(
            Some(&self.owner),
            Some("org.freedesktop.portal.Request"),
            Some("Response"),
            Some(&pending.path),
            None,
            gio::DBusSignalFlags::NONE,
            move |signal| {
                if signal.sender_name == owner && signal.parameters.size() <= 65536 {
                    *result.borrow_mut() = Some(signal.parameters.get::<(u32, Options)>());
                }
            },
        );
        let (returned,) = self
            .call(PATH, API, method, Some(&parameters))?
            .get::<(ObjectPath,)>()
            .ok_or(UNAVAILABLE)?;
        if returned.as_str() != pending.path {
            return Err(UNAVAILABLE);
        }
        let deadline = Instant::now() + Duration::from_secs(180);
        loop {
            guard()?;
            self.drain();
            self.live()?;
            if let Some(value) = response.borrow_mut().take() {
                drop(subscription);
                let (code, options) = value.ok_or(UNAVAILABLE)?;
                return if code == 0 {
                    Ok(options)
                } else {
                    Err(UNAVAILABLE)
                };
            }
            if Instant::now() >= deadline {
                return Err(UNAVAILABLE);
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
    fn connect(context: glib::MainContext, guard: &dyn Fn() -> Result<()>) -> Result<Self> {
        guard()?;
        let address =
            gio::dbus_address_get_for_bus_sync(gio::BusType::Session, None::<&gio::Cancellable>)
                .map_err(|_| UNAVAILABLE)?;
        let connection = gio::DBusConnection::for_address_sync(
            &address,
            gio::DBusConnectionFlags::AUTHENTICATION_CLIENT
                | gio::DBusConnectionFlags::MESSAGE_BUS_CONNECTION,
            None,
            None::<&gio::Cancellable>,
        )
        .map_err(|_| UNAVAILABLE)?;
        connection.set_exit_on_close(false);
        // Native, unsandboxed application identity must be registered before
        // this connection makes any other portal request.
        connection
            .call_sync(
                Some(PORTAL),
                PATH,
                "org.freedesktop.host.portal.Registry",
                "Register",
                Some(&(crate::desktop::APP_ID, Options::new()).to_variant()),
                None,
                gio::DBusCallFlags::NONE,
                3000,
                None::<&gio::Cancellable>,
            )
            .map_err(|_| UNAVAILABLE)?;
        let (owner,) = connection
            .call_sync(
                Some(BUS),
                "/org/freedesktop/DBus",
                BUS,
                "GetNameOwner",
                Some(&(PORTAL,).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                1000,
                None::<&gio::Cancellable>,
            )
            .map_err(|_| UNAVAILABLE)?
            .get::<(String,)>()
            .ok_or(UNAVAILABLE)?;
        if !owner.starts_with(':') || owner.len() > 256 {
            return Err(UNAVAILABLE);
        }
        let mut this = Self {
            context,
            connection,
            owner,
            session: None,
            version: 0,
            subscriptions: vec![],
            revoked: Rc::new(Cell::new(false)),
            bound: Rc::new(RefCell::new(HashSet::new())),
            queue: Rc::new(RefCell::new(VecDeque::new())),
            token: None,
        };
        let revoked = this.revoked.clone();
        this.subscriptions.push(this.connection.subscribe_to_signal(
            Some(BUS),
            Some(BUS),
            Some("NameOwnerChanged"),
            Some("/org/freedesktop/DBus"),
            Some(PORTAL),
            gio::DBusSignalFlags::NONE,
            move |_| revoked.set(true),
        ));
        let version = this.call(
            PATH,
            "org.freedesktop.DBus.Properties",
            "Get",
            Some(&(API, "version").to_variant()),
        )?;
        this.version = version
            .get::<(glib::Variant,)>()
            .and_then(|(v,)| v.get::<u32>())
            .ok_or(UNAVAILABLE)?;
        if this.version < 1 {
            return Err(UNAVAILABLE);
        }
        let token = format!("snippets_{}", uuid::Uuid::new_v4().simple());
        let options = Options::from([
            ("handle_token".into(), token.to_variant()),
            ("session_handle_token".into(), token.to_variant()),
        ]);
        let response = this.request("CreateSession", &token, (options,).to_variant(), guard)?;
        let session = response
            .get("session_handle")
            .and_then(|v| v.get::<String>())
            .ok_or(UNAVAILABLE)?;
        let sender = this.connection.unique_name().ok_or(UNAVAILABLE)?;
        let expected = format!(
            "{PATH}/session/{}/{}",
            sender.trim_start_matches(':').replace('.', "_"),
            token
        );
        if session != expected {
            return Err(UNAVAILABLE);
        }
        this.session = Some(ObjectPath::try_from(session.as_str()).map_err(|_| UNAVAILABLE)?);
        let revoked = this.revoked.clone();
        this.subscriptions.push(this.connection.subscribe_to_signal(
            Some(&this.owner),
            Some("org.freedesktop.portal.Session"),
            Some("Closed"),
            Some(&session),
            None,
            gio::DBusSignalFlags::NONE,
            move |_| revoked.set(true),
        ));
        let bound = this.bound.clone();
        let queue = this.queue.clone();
        let owner = this.owner.clone();
        let expected = session.clone();
        this.subscriptions.push(this.connection.subscribe_to_signal(
            Some(&this.owner),
            Some(API),
            Some("Activated"),
            Some(PATH),
            None,
            gio::DBusSignalFlags::NONE,
            move |signal| {
                if signal.sender_name != owner {
                    return;
                }
                let now_ms = (glib::monotonic_time() / 1000) as u32;
                if let Some((action, age, token)) =
                    activation(signal.parameters, &expected, &bound.borrow(), now_ms)
                {
                    let mut queue = queue.borrow_mut();
                    if queue.len() < 3 {
                        queue.push_back(Queued {
                            action,
                            age,
                            token,
                            received: Instant::now(),
                        });
                    }
                }
            },
        ));
        let bound = this.bound.clone();
        let revoked = this.revoked.clone();
        this.subscriptions.push(this.connection.subscribe_to_signal(
            Some(&this.owner),
            Some(API),
            Some("ShortcutsChanged"),
            Some(PATH),
            None,
            gio::DBusSignalFlags::NONE,
            move |signal| {
                if signal.parameters.size() > 65536 {
                    revoked.set(true);
                    return;
                }
                if let Some((path, rows)) = signal
                    .parameters
                    .get::<(ObjectPath, Vec<(String, Options)>)>()
                    && path.as_str() == session
                {
                    if let Some(value) = bindings(&rows.to_variant()) {
                        *bound.borrow_mut() = value;
                    } else {
                        revoked.set(true);
                    }
                }
            },
        ));
        let requested: Vec<_> = [
            ("open", "Open Snippets", "LOGO+ALT+n"),
            ("picker", "Snippets paste picker", "LOGO+ALT+p"),
            ("capture", "Capture clipboard text", "LOGO+ALT+c"),
        ]
        .into_iter()
        .map(|(id, label, trigger)| {
            (
                id,
                Options::from([
                    ("description".into(), label.to_variant()),
                    ("preferred_trigger".into(), trigger.to_variant()),
                ]),
            )
        })
        .collect();
        let token = format!("snippets_{}", uuid::Uuid::new_v4().simple());
        let options = Options::from([("handle_token".into(), token.to_variant())]);
        let reply = this.request(
            "BindShortcuts",
            &token,
            (this.session.as_ref().unwrap(), requested, "", options).to_variant(),
            guard,
        )?;
        let registered = reply
            .get("shortcuts")
            .and_then(bindings)
            .ok_or(UNAVAILABLE)?;
        if registered.is_empty() {
            return Err(UNAVAILABLE);
        }
        *this.bound.borrow_mut() = registered;
        // Close the startup race between resolving the owner and subscribing
        // to NameOwnerChanged. A replacement must never inherit this session.
        let (current_owner,) = this
            .connection
            .call_sync(
                Some(BUS),
                "/org/freedesktop/DBus",
                BUS,
                "GetNameOwner",
                Some(&(PORTAL,).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                1000,
                None::<&gio::Cancellable>,
            )
            .map_err(|_| UNAVAILABLE)?
            .get::<(String,)>()
            .ok_or(UNAVAILABLE)?;
        if current_owner != this.owner {
            return Err(UNAVAILABLE);
        }
        guard()?;
        this.drain();
        this.live()?;
        Ok(this)
    }
}
impl Backend for Portal {
    fn can_configure(&self) -> bool {
        self.version >= 2
    }
    fn next(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<Option<(Action, Duration)>> {
        guard()?;
        self.drain();
        self.live()?;
        while let Some(event) = self.queue.borrow_mut().pop_front() {
            let age = event.age.saturating_add(event.received.elapsed());
            if age <= Duration::from_millis(1500) {
                self.token = event.token;
                return Ok(Some((event.action, age)));
            }
        }
        thread::sleep(Duration::from_millis(20));
        Ok(None)
    }
    fn activation_token(&mut self) -> Option<String> {
        self.token.take()
    }
    fn configure(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()?;
        self.live()?;
        if self.version < 2 {
            return Err(UNAVAILABLE);
        }
        self.call(
            PATH,
            API,
            "ConfigureShortcuts",
            Some(
                &(
                    self.session.as_ref().ok_or(UNAVAILABLE)?,
                    "",
                    Options::new(),
                )
                    .to_variant(),
            ),
        )?;
        guard()
    }
}
impl Drop for Portal {
    fn drop(&mut self) {
        self.subscriptions.clear();
        if let Some(session) = &self.session {
            let _ = self.call(
                session.as_str(),
                "org.freedesktop.portal.Session",
                "Close",
                None,
            );
        }
        let _ = self.connection.close_sync(None::<&gio::Cancellable>);
    }
}

#[cfg(test)]
#[path = "shortcuts_gnome_tests.rs"]
mod tests;
