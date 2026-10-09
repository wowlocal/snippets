//! Optional GNOME Shell companion: ephemeral, single-use ordinary insertion.
//! Every call stays pinned to the Shell owner that issued the target ticket.
use gtk::{gio, glib, prelude::*};
const PATH: &str = "/com/khm/Snippets/Gnome";
const API: &str = "com.khm.Snippets.Gnome1";
#[derive(Clone, PartialEq, Eq)]
pub(super) struct Target {
    owner: String,
    ticket: String,
    label: String,
}
fn connection() -> Option<gio::DBusConnection> {
    // GApplication owns APP_ID on this shared connection. A private connection
    // would deliberately be refused by the companion, even in the same process.
    gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>).ok()
}
fn call(owner: &str, method: &str, arguments: Option<&glib::Variant>) -> Option<glib::Variant> {
    connection()?
        .call_sync(
            Some(owner),
            PATH,
            API,
            method,
            arguments,
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            1500,
            None::<&gio::Cancellable>,
        )
        .ok()
}
impl Target {
    pub(super) fn capture() -> Option<Self> {
        let (owner,) = connection()?
            .call_sync(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "GetNameOwner",
                Some(&("org.gnome.Shell",).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                1000,
                None::<&gio::Cancellable>,
            )
            .ok()?
            .get::<(String,)>()?;
        if !owner.starts_with(':') || owner.len() > 256 {
            return None;
        }
        let reply = call(&owner, "Capture", None)?;
        if reply.size() > 4096 {
            return None;
        }
        let (ticket, label) = reply.get::<(String, String)>()?;
        if uuid::Uuid::parse_str(&ticket).is_err()
            || ticket.len() != 36
            || label.len() > 1024
            || label.chars().any(char::is_control)
        {
            return None;
        }
        Some(Self {
            owner,
            ticket,
            label,
        })
    }
    pub(super) fn check(&self) -> (bool, bool) {
        call(
            &self.owner,
            "Check",
            Some(&(self.ticket.as_str(),).to_variant()),
        )
        .and_then(|v| v.get::<(bool, bool)>())
        .unwrap_or((false, false))
    }
    pub(super) fn label(&self) -> Option<String> {
        self.check().0.then(|| self.label.clone())
    }
    pub(super) fn focus(&self) -> bool {
        call(
            &self.owner,
            "Focus",
            Some(&(self.ticket.as_str(),).to_variant()),
        )
        .and_then(|v| v.get::<(bool,)>())
        .is_some_and(|v| v.0)
    }
    pub(super) fn commit(&self, text: &str) -> bool {
        if text.len() > crate::model::MAX_BODY_BYTES || text.contains('\0') {
            return false;
        }
        call(
            &self.owner,
            "Commit",
            Some(&(self.ticket.as_str(), text).to_variant()),
        )
        .and_then(|v| v.get::<(bool,)>())
        .is_some_and(|v| v.0)
    }
}
