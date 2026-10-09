//! GNOME Shell's read-only screen shield API. This does not request unlocking,
//! enable Shell Eval, inspect windows or change input methods.
use super::{ObservedSession, SessionState};
use gtk::{gio, glib, prelude::*};
use std::{
    cell::RefCell,
    rc::Rc,
    sync::{Arc, Mutex},
    time::Duration,
};

const BUS: &str = "org.freedesktop.DBus";
const BUS_PATH: &str = "/org/freedesktop/DBus";
const SHELL: &str = "org.gnome.Shell";
const SAVER: &str = "org.gnome.ScreenSaver";
const PATH: &str = "/org/gnome/ScreenSaver";

fn owner(connection: &gio::DBusConnection, name: &str) -> Option<String> {
    connection
        .call_sync(
            Some(BUS),
            BUS_PATH,
            BUS,
            "GetNameOwner",
            Some(&(name,).to_variant()),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            150,
            None::<&gio::Cancellable>,
        )
        .ok()?
        .get::<(String,)>()
        .map(|(name,)| name)
        .filter(|name| name.starts_with(':') && name.len() <= 256)
}

fn read(connection: &gio::DBusConnection) -> Option<(String, SessionState)> {
    if connection.is_closed() {
        return None;
    }
    // Shell exports this interface itself. The public ScreenSaver bus name
    // can belong to GNOME's separate forwarding service, so address Shell's
    // unique owner directly and authenticate signals against the same owner.
    let expected = owner(connection, SHELL)?;
    let active = connection
        .call_sync(
            Some(&expected),
            PATH,
            SAVER,
            "GetActive",
            None,
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            150,
            None::<&gio::Cancellable>,
        )
        .ok()?
        .get::<(bool,)>()?
        .0;
    if connection.is_closed() || owner(connection, SHELL).as_deref() != Some(expected.as_str()) {
        return None;
    }
    Some((
        expected,
        if active {
            SessionState::Locked
        } else {
            SessionState::Unlocked
        },
    ))
}

pub(super) fn state() -> SessionState {
    gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .ok()
        .and_then(|connection| read(&connection))
        .map_or(SessionState::Unavailable, |(_, state)| state)
}

fn invalidate(shared: &Arc<Mutex<ObservedSession>>, state: SessionState) {
    if let Ok(mut value) = shared.lock() {
        value.epoch = value.epoch.wrapping_add(1);
        value.observe(state);
        // A lock/unlock pair queued between two GTK ticks must still revoke
        // an open vault and in-flight work, just like a sleep/resume pair.
        value.revoked_until = crate::clock::uptime()
            .unwrap_or(Duration::MAX)
            .saturating_add(Duration::from_millis(1500));
    }
}

pub(super) struct Monitor {
    shared: Arc<Mutex<ObservedSession>>,
    connection: Option<gio::DBusConnection>,
    current: Rc<RefCell<Option<String>>>,
    subscriptions: Vec<gio::SignalSubscription>,
    closed: Option<glib::SignalHandlerId>,
}
impl Monitor {
    pub(super) fn new(shared: Arc<Mutex<ObservedSession>>) -> Self {
        Self {
            shared,
            connection: None,
            current: Rc::new(RefCell::new(None)),
            subscriptions: Vec::new(),
            closed: None,
        }
    }
    fn disconnect(&mut self) {
        self.subscriptions.clear();
        self.current.borrow_mut().take();
        if let Some(connection) = self.connection.take()
            && let Some(handler) = self.closed.take()
        {
            connection.disconnect(handler);
        }
    }
    fn connect(&mut self) -> Option<()> {
        let connection =
            gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>).ok()?;
        self.connect_on(connection)
    }
    fn connect_on(&mut self, connection: gio::DBusConnection) -> Option<()> {
        connection.set_exit_on_close(false);
        if connection.is_closed() {
            return None;
        }
        let shared = self.shared.clone();
        self.closed = Some(connection.connect_closed(move |_, _, _| {
            invalidate(&shared, SessionState::Unavailable);
        }));
        {
            let name = SHELL;
            let shared = self.shared.clone();
            let current = self.current.clone();
            self.subscriptions.push(connection.subscribe_to_signal(
                Some(BUS),
                Some(BUS),
                Some("NameOwnerChanged"),
                Some(BUS_PATH),
                Some(name),
                gio::DBusSignalFlags::NONE,
                move |signal| {
                    if signal.sender_name != BUS {
                        return;
                    }
                    if signal
                        .parameters
                        .get::<(String, String, String)>()
                        .is_some_and(|(changed, previous, next)| {
                            changed == name && previous != next
                        })
                    {
                        current.borrow_mut().take();
                        invalidate(&shared, SessionState::Unavailable);
                    }
                },
            ));
        }
        let shared = self.shared.clone();
        let current = self.current.clone();
        self.subscriptions.push(connection.subscribe_to_signal(
            Some(SHELL),
            Some(SAVER),
            Some("ActiveChanged"),
            Some(PATH),
            None,
            gio::DBusSignalFlags::NONE,
            move |signal| {
                if current.borrow().as_deref() != Some(signal.sender_name) {
                    return;
                }
                match signal.parameters.get::<(bool,)>() {
                    Some((false,)) => {
                        if let Ok(mut value) = shared.lock() {
                            value.observe(SessionState::Unlocked);
                        }
                    }
                    Some((true,)) => invalidate(&shared, SessionState::Locked),
                    None => invalidate(&shared, SessionState::Unavailable),
                }
            },
        ));
        self.connection = Some(connection);
        Some(())
    }
    pub(super) fn refresh(&mut self) {
        if self.connection.as_ref().is_some_and(|v| v.is_closed()) {
            self.disconnect();
        }
        if self.connection.is_none() && self.connect().is_none() {
            invalidate(&self.shared, SessionState::Unavailable);
            return;
        }
        match read(self.connection.as_ref().unwrap()) {
            Some((owner, state)) => {
                let changed = self.current.borrow().as_deref() != Some(owner.as_str());
                if changed && self.current.borrow().is_some() {
                    invalidate(&self.shared, SessionState::Unavailable);
                }
                *self.current.borrow_mut() = Some(owner);
                if let Ok(mut value) = self.shared.lock() {
                    value.observe(state);
                }
            }
            None => {
                self.current.borrow_mut().take();
                invalidate(&self.shared, SessionState::Unavailable);
            }
        }
    }
}
impl Drop for Monitor {
    fn drop(&mut self) {
        self.disconnect();
    }
}

#[cfg(test)]
#[path = "desktop_gnome_tests.rs"]
mod tests;
