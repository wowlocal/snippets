//! Explicit, bounded clipboard acquisition through the primary-app-only companion.
//! No background collection, plaintext persistence or clipboard writes.
use crate::model::{Error, MAX_BODY_BYTES, Result};
use gtk::{gio, glib, prelude::*};
use zeroize::Zeroizing;
const UNAVAILABLE: Error = Error(
    "GNOME clipboard text is unavailable. Enable the Snippets companion and use an ordinary text field.",
);
pub(crate) fn read(guard: &dyn Fn() -> Result<()>) -> Result<Zeroizing<String>> {
    guard()?;
    let deadline = crate::sensitive_clipboard::Deadline::new()?;
    let bus = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .map_err(|_| UNAVAILABLE)?;
    let owner = shell_owner(&bus)?;
    guard()?;
    let reply = bus
        .call_sync(
            Some(&owner),
            "/com/khm/Snippets/Gnome",
            "com.khm.Snippets.Gnome1",
            "ReadClipboard",
            None,
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            1700,
            None::<&gio::Cancellable>,
        )
        .map_err(|_| UNAVAILABLE)?;
    if shell_owner(&bus)? != owner {
        return Err(UNAVAILABLE);
    }
    deadline.validate()?;
    guard()?;
    decode(reply)
}
fn shell_owner(bus: &gio::DBusConnection) -> Result<String> {
    let reply = bus
        .call_sync(
            Some("org.freedesktop.DBus"),
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "GetNameOwner",
            Some(&("org.gnome.Shell",).to_variant()),
            None,
            gio::DBusCallFlags::NO_AUTO_START,
            150,
            None::<&gio::Cancellable>,
        )
        .map_err(|_| UNAVAILABLE)?;
    let (owner,) = reply.get::<(String,)>().ok_or(UNAVAILABLE)?;
    if !owner.starts_with(':') || owner.len() > 256 {
        return Err(UNAVAILABLE);
    }
    Ok(owner)
}
fn decode(reply: glib::Variant) -> Result<Zeroizing<String>> {
    if reply.size() > MAX_BODY_BYTES + 32 {
        return Err(UNAVAILABLE);
    }
    let (ok, bytes) = reply.get::<(bool, Vec<u8>)>().ok_or(UNAVAILABLE)?;
    let bytes = Zeroizing::new(bytes);
    if !ok || bytes.len() > MAX_BODY_BYTES || bytes.contains(&0) {
        return Err(UNAVAILABLE);
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| UNAVAILABLE)?;
    Ok(Zeroizing::new(text.into()))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_reply_rejects_prefixes_invalid_utf8_nul_and_oversized_payloads() {
        for (ok, bytes) in [
            (false, b"public prefix".to_vec()),
            (true, vec![0xff]),
            (true, b"a\0b".to_vec()),
            (true, vec![b'a'; MAX_BODY_BYTES + 1]),
        ] {
            assert!(decode((ok, bytes).to_variant()).is_err());
        }
        assert!(decode(("wrong signature",).to_variant()).is_err());
        for text in ["", "Public\nПривет ✓"] {
            assert_eq!(
                decode((true, text.as_bytes()).to_variant())
                    .unwrap()
                    .as_str(),
                text
            );
        }
    }
    #[test]
    fn revoked_read_never_connects_to_the_session_bus() {
        assert!(read(&|| Err(UNAVAILABLE)).is_err());
    }
}
