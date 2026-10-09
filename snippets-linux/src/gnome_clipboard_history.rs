//! Opted-in history polls only new selection generations; reopening skips the baseline.
use super::*;

pub(crate) struct Reader {
    bus: gio::DBusConnection,
    owner: String,
    cursor: String,
}
impl Reader {
    pub(crate) fn open(excluded: &[String], guard: &dyn Fn() -> Result<()>) -> Result<Self> {
        guard()?;
        let bus = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
            .map_err(|_| UNAVAILABLE)?;
        let owner = shell_owner(&bus)?;
        let mut reader = Self {
            bus,
            owner,
            cursor: String::new(),
        };
        if reader.read_new(excluded, guard)?.is_some() {
            return Err(UNAVAILABLE);
        }
        Ok(reader)
    }

    pub(crate) fn read_new(
        &mut self,
        excluded: &[String],
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<Option<Zeroizing<String>>> {
        guard()?;
        let deadline = crate::sensitive_clipboard::Deadline::new()?;
        if shell_owner(&self.bus)? != self.owner {
            return Err(UNAVAILABLE);
        }
        let reply = self
            .bus
            .call_sync(
                Some(&self.owner),
                "/com/khm/Snippets/Gnome",
                "com.khm.Snippets.Gnome1",
                "ReadHistory",
                Some(&(self.cursor.as_str(), excluded).to_variant()),
                None,
                gio::DBusCallFlags::NO_AUTO_START,
                2700,
                None::<&gio::Cancellable>,
            )
            .map_err(|_| UNAVAILABLE)?;
        deadline.validate()?;
        guard()?;
        if shell_owner(&self.bus)? != self.owner {
            return Err(UNAVAILABLE);
        }
        let (cursor, text) = decode_history(reply)?;
        // A daemon must not send text during baseline establishment or repeat
        // the same selection as new. Neither case can enter encrypted storage.
        if text.is_some() && (self.cursor.is_empty() || cursor == self.cursor) {
            return Err(UNAVAILABLE);
        }
        self.cursor = cursor;
        Ok(text)
    }
}

fn decode_history(reply: glib::Variant) -> Result<(String, Option<Zeroizing<String>>)> {
    if reply.size() > MAX_BODY_BYTES + 128 {
        return Err(UNAVAILABLE);
    }
    let (cursor, ok, bytes) = reply.get::<(String, bool, Vec<u8>)>().ok_or(UNAVAILABLE)?;
    let bytes = Zeroizing::new(bytes);
    if cursor.len() != 36 || uuid::Uuid::parse_str(&cursor).is_err() {
        return Err(UNAVAILABLE);
    }
    if !ok {
        return if bytes.is_empty() {
            Ok((cursor, None))
        } else {
            Err(UNAVAILABLE)
        };
    }
    if bytes.len() > MAX_BODY_BYTES || bytes.contains(&0) {
        return Err(UNAVAILABLE);
    }
    let text = std::str::from_utf8(&bytes).map_err(|_| UNAVAILABLE)?;
    Ok((cursor, Some(Zeroizing::new(text.into()))))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn history_protocol_rejects_invalid_cursors_and_partial_or_malformed_text() {
        let cursor = uuid::Uuid::new_v4().to_string();
        assert!(
            decode_history((cursor.as_str(), false, Vec::<u8>::new()).to_variant())
                .unwrap()
                .1
                .is_none()
        );
        for (id, ok, bytes) in [
            ("", true, b"public".to_vec()),
            (cursor.as_str(), false, b"partial".to_vec()),
            (cursor.as_str(), true, vec![0xff]),
            (cursor.as_str(), true, b"a\0b".to_vec()),
            (cursor.as_str(), true, vec![b'a'; MAX_BODY_BYTES + 1]),
        ] {
            assert!(decode_history((id, ok, bytes).to_variant()).is_err());
        }
        let result =
            decode_history((cursor.as_str(), true, "Public ✓".as_bytes()).to_variant()).unwrap();
        assert_eq!(result.1.unwrap().as_str(), "Public ✓");
    }
    #[test]
    fn disabled_history_never_opens_a_desktop_connection() {
        assert!(Reader::open(&[], &|| Err(UNAVAILABLE)).is_err());
    }
}
