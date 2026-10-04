//! logind's authenticated system-bus sleep boundary, owned by the desktop
//! monitor's private GLib context. No D-Bus callbacks run on the GTK thread.
use super::ObservedSession;
use gtk::{gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::{Arc, Mutex},
    time::Duration,
};

const LOGIN: &str = "org.freedesktop.login1";
const MANAGER: &str = "org.freedesktop.login1.Manager";
const PATH: &str = "/org/freedesktop/login1";
const BUS: &str = "org.freedesktop.DBus";
const BUS_PATH: &str = "/org/freedesktop/DBus";

#[derive(Default)]
pub(super) struct Observation {
    connected: bool,
    ready: bool,
    preparing: bool,
    revoked_until: Duration,
}
impl Observation {
    #[cfg(test)]
    pub(super) fn ready() -> Self {
        Self {
            connected: true,
            ready: true,
            ..Self::default()
        }
    }
    pub(super) fn blocked(&self) -> bool {
        !self.connected
            || !self.ready
            || self.preparing
            || crate::clock::uptime().is_none_or(|now| now < self.revoked_until)
    }
    fn observe(&mut self, value: Option<bool>, event: bool) {
        self.ready = value.is_some();
        self.preparing = value.unwrap_or(true);
        // A queued true/false pair must remain visible to the 500 ms GTK
        // revocation tick. BOOTTIME also includes time spent suspended.
        if event || value != Some(false) {
            self.revoked_until = crate::clock::uptime()
                .unwrap_or(Duration::MAX)
                .saturating_add(Duration::from_millis(1500));
        }
    }
}
fn observe(shared: &Arc<Mutex<ObservedSession>>, value: Option<bool>, event: bool) {
    if let Ok(mut observed) = shared.lock() {
        observed.epoch = observed.epoch.wrapping_add(1);
        observed.sleep.observe(value, event);
    }
}

pub(super) struct Monitor {
    shared: Arc<Mutex<ObservedSession>>,
    connection: Option<gio::DBusConnection>,
    owner: Rc<RefCell<Option<String>>>,
    refresh_needed: Rc<Cell<bool>>,
    owner_subscription: Option<gio::SignalSubscription>,
    sleep_subscription: Option<gio::SignalSubscription>,
    closed: Option<glib::SignalHandlerId>,
}
impl Monitor {
    pub(super) fn new(shared: Arc<Mutex<ObservedSession>>) -> Self {
        Self {
            shared,
            connection: None,
            owner: Rc::new(RefCell::new(None)),
            refresh_needed: Rc::new(Cell::new(true)),
            owner_subscription: None,
            sleep_subscription: None,
            closed: None,
        }
    }
    fn disconnect(&mut self) {
        self.sleep_subscription.take();
        self.owner_subscription.take();
        if let Some(connection) = self.connection.take()
            && let Some(handler) = self.closed.take()
        {
            connection.disconnect(handler);
        }
        self.owner.borrow_mut().take();
        self.refresh_needed.set(true);
    }
    fn connect(&mut self) -> Option<()> {
        let connection = gio::bus_get_sync(gio::BusType::System, None::<&gio::Cancellable>).ok()?;
        connection.set_exit_on_close(false);
        if connection.is_closed() {
            return None;
        }
        let shared = self.shared.clone();
        self.closed = Some(connection.connect_closed(move |_, _, _| {
            if let Ok(mut observed) = shared.lock() {
                observed.sleep.connected = false;
                observed.epoch = observed.epoch.wrapping_add(1);
                observed.sleep.observe(None, true);
            }
        }));
        // A close racing bootstrap cannot be overwritten by a successful
        // property reply. The close handler shares this same mutex.
        if let Ok(mut observed) = self.shared.lock() {
            observed.sleep.connected = !connection.is_closed();
        }
        let shared = self.shared.clone();
        let owner = self.owner.clone();
        let needed = self.refresh_needed.clone();
        self.owner_subscription = Some(connection.subscribe_to_signal(
            Some(BUS),
            Some(BUS),
            Some("NameOwnerChanged"),
            Some(BUS_PATH),
            Some(LOGIN),
            gio::DBusSignalFlags::NONE,
            move |signal| {
                if signal.sender_name != BUS {
                    return;
                }
                let valid = signal.parameters.get::<(String, String, String)>();
                if valid.as_ref().is_none_or(|(name, _, _)| name != LOGIN) {
                    observe(&shared, None, true);
                    owner.borrow_mut().take();
                    needed.set(true);
                    return;
                }
                let (_, previous, current) = valid.unwrap();
                // Ignore an already superseded transition after bootstrap.
                if owner.borrow().as_deref() == Some(current.as_str()) {
                    return;
                }
                if owner.borrow().is_none() || owner.borrow().as_deref() == Some(previous.as_str())
                {
                    observe(&shared, None, true);
                    owner.borrow_mut().take();
                    needed.set(true);
                }
            },
        ));
        self.connection = Some(connection);
        Some(())
    }
    pub(super) fn refresh(&mut self) {
        if self.connection.as_ref().is_some_and(|v| v.is_closed()) {
            self.disconnect();
            observe(&self.shared, None, true);
        }
        if self.connection.is_none() && self.connect().is_none() {
            return;
        }
        if !self.refresh_needed.get() {
            return;
        }
        self.sleep_subscription.take();
        self.owner.borrow_mut().take();
        let connection = self.connection.as_ref().unwrap();
        let Some(owner) = current_owner(connection) else {
            observe(&self.shared, None, true);
            return;
        };
        *self.owner.borrow_mut() = Some(owner.clone());
        let expected = owner.clone();
        let current = self.owner.clone();
        let shared = self.shared.clone();
        let needed = self.refresh_needed.clone();
        self.sleep_subscription = Some(connection.subscribe_to_signal(
            Some(&owner),
            Some(MANAGER),
            Some("PrepareForSleep"),
            Some(PATH),
            None,
            gio::DBusSignalFlags::NONE,
            move |signal| {
                if signal.sender_name != expected
                    || current.borrow().as_deref() != Some(expected.as_str())
                {
                    return;
                }
                let value = signal.parameters.get::<(bool,)>().map(|(v,)| v);
                observe(&shared, value, true);
                if value.is_none() {
                    needed.set(true);
                }
            },
        ));
        let value = connection
            .call_sync(
                Some(&owner),
                PATH,
                "org.freedesktop.DBus.Properties",
                "Get",
                Some(&(MANAGER, "PreparingForSleep").to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                500,
                None::<&gio::Cancellable>,
            )
            .ok()
            .and_then(|v| v.get::<(glib::Variant,)>())
            .and_then(|(v,)| v.get::<bool>());
        if value.is_none()
            || connection.is_closed()
            || current_owner(connection).as_deref() != Some(owner.as_str())
        {
            self.owner.borrow_mut().take();
            self.sleep_subscription.take();
            observe(&self.shared, None, true);
            return;
        }
        self.refresh_needed.set(false);
        observe(&self.shared, value, false);
    }
}
impl Drop for Monitor {
    fn drop(&mut self) {
        self.disconnect();
    }
}
fn current_owner(connection: &gio::DBusConnection) -> Option<String> {
    connection
        .call_sync(
            Some(BUS),
            BUS_PATH,
            BUS,
            "GetNameOwner",
            Some(&(LOGIN,).to_variant()),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            500,
            None::<&gio::Cancellable>,
        )
        .ok()?
        .get::<(String,)>()
        .map(|(v,)| v)
        .filter(|v| v.starts_with(':') && v.len() <= 256)
}
