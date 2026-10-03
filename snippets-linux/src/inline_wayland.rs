//! Private in-process input-method connection; no Rust pointer is retained by C.
use super::*;
use std::{
    ffi::{c_int, c_void},
    ptr::NonNull,
};
use zeroize::Zeroize;
const UNAVAILABLE: Error = Error(
    "Inline expansion is unavailable. A compatible Hyprland input method and an unused IME seat are required.",
);
#[repr(C)]
struct RawFrame {
    field: u64,
    serial: u32,
    active: u32,
    cursor: u32,
    anchor: u32,
    hint: u32,
    purpose: u32,
    has_type: u32,
    has_text: u32,
    cause: u32,
    length: u32,
    text: [u8; 4001],
}
impl Zeroize for RawFrame {
    fn zeroize(&mut self) {
        self.text.zeroize();
    }
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Span {
    start: u32,
    end: u32,
}
#[repr(C)]
struct RawRow {
    name: [u8; 513],
    keyword: [u8; 257],
    pinned: u32,
    name_count: u32,
    keyword_count: u32,
    names: [Span; 120],
    keywords: [Span; 120],
}
#[repr(C)]
#[derive(Default)]
pub(super) struct Key {
    field: u64,
    serial: u32,
    pub key: u32,
    pub state: u32,
    time: u32,
    pub symbol: u32,
    pub modifiers: u32,
    pub kind: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
    map_generation: u32,
}
impl Key {
    pub fn context(&self) -> Context {
        Context {
            field: self.field,
            serial: self.serial,
        }
    }
    pub fn repeat(&self) -> (u32, u32) {
        (self.symbol, self.time)
    }
}
fn row(value: &suggestions::Row) -> Result<RawRow> {
    if value.name.len() > 512
        || value.keyword.len() > 256
        || value.name_matches.len() > 120
        || value.keyword_matches.len() > 120
        || value.name.contains('\0')
        || value.keyword.contains('\0')
    {
        return Err(UNSUPPORTED);
    }
    let mut row = RawRow {
        name: [0; 513],
        keyword: [0; 257],
        pinned: value.pinned.into(),
        name_count: value.name_matches.len() as u32,
        keyword_count: value.keyword_matches.len() as u32,
        names: [Span::default(); 120],
        keywords: [Span::default(); 120],
    };
    row.name[..value.name.len()].copy_from_slice(value.name.as_bytes());
    row.keyword[..value.keyword.len()].copy_from_slice(value.keyword.as_bytes());
    for (to, (start, end)) in row.names.iter_mut().zip(&value.name_matches) {
        *to = Span {
            start: *start,
            end: *end,
        };
    }
    for (to, (start, end)) in row.keywords.iter_mut().zip(&value.keyword_matches) {
        *to = Span {
            start: *start,
            end: *end,
        };
    }
    Ok(row)
}
fn colors() -> [u32; 3] {
    let mut values = [0x202124, 0xf1f3f4, 0x8ab4f8];
    if let Some(path) = crate::desktop::theme_path()
        && let Ok(Some(data)) = crate::model::read_regular(&path)
        && data.len() <= 64 * 1024
        && let Ok(text) = std::str::from_utf8(&data)
        && let Ok(table) = text.parse::<toml::Table>()
    {
        for (i, key) in ["background", "foreground", "accent"]
            .into_iter()
            .enumerate()
        {
            if let Some(value) = table.get(key).and_then(toml::Value::as_str)
                && value.len() == 7
                && value.starts_with('#')
                && value[1..].bytes().all(|v| v.is_ascii_hexdigit())
                && let Ok(value) = u32::from_str_radix(&value[1..], 16)
            {
                values[i] = value;
            }
        }
    }
    values
}
unsafe extern "C" {
    fn snip_ime_popup(
        owner: *mut c_void,
        field: u64,
        serial: u32,
        rows: *const RawRow,
        count: u32,
        selected: u32,
        colors: *const u32,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_ime_popup_hide(
        owner: *mut c_void,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_ime_key_next(owner: *mut c_void, event: *mut Key) -> c_int;
    fn snip_ime_key_route(
        owner: *mut c_void,
        event: *const Key,
        consume: u32,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_ime_connect(
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
    fn snip_ime_close(owner: *mut c_void);
    fn snip_ime_peer(owner: *mut c_void) -> u64;
    fn snip_ime_start(
        owner: *mut c_void,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_ime_poll(
        owner: *mut c_void,
        milliseconds: u32,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_ime_frame(owner: *mut c_void, output: *mut RawFrame) -> c_int;
    fn snip_ime_replace(
        owner: *mut c_void,
        field: u64,
        serial: u32,
        before: u32,
        text: *const libc::c_char,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
}
struct Check<'a>(&'a dyn Fn() -> Result<()>);
unsafe extern "C" fn check(context: *mut c_void) -> c_int {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        unsafe { (*(context.cast::<Check<'_>>())).0() }.is_ok()
    }))
    .unwrap_or(false)
    .into()
}
fn outcome(status: c_int) -> Result<()> {
    match status {
        0 | 1 => Ok(()),
        2 => Err(CHANGED),
        _ => Err(UNAVAILABLE),
    }
}
pub(super) struct Connection(NonNull<c_void>);
impl Connection {
    pub fn popup(
        &self,
        choice: &suggestions::Choice,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<bool> {
        guard()?;
        let rows: Vec<_> = choice.rows().iter().map(row).collect::<Result<_>>()?;
        let palette = colors();
        let mut context = Check(guard);
        let frame = choice.context();
        let status = unsafe {
            snip_ime_popup(
                self.0.as_ptr(),
                frame.field,
                frame.serial,
                rows.as_ptr(),
                rows.len() as u32,
                choice.selected() as u32,
                palette.as_ptr(),
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        if status == 4 {
            return Ok(false);
        }
        if status != 0 {
            return Err(if status == 2 { CHANGED } else { UNAVAILABLE });
        }
        guard()?;
        Ok(true)
    }
    pub fn hide_popup(&self, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()?;
        let mut context = Check(guard);
        let status = unsafe {
            snip_ime_popup_hide(
                self.0.as_ptr(),
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        if status != 0 {
            return Err(if status == 2 { CHANGED } else { UNAVAILABLE });
        }
        guard()
    }
    pub fn key(&self) -> Option<Key> {
        let mut event = Key::default();
        (unsafe { snip_ime_key_next(self.0.as_ptr(), &mut event) } != 0).then_some(event)
    }
    pub fn route(&self, key: &Key, consume: bool, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()?;
        let mut context = Check(guard);
        let status = unsafe {
            snip_ime_key_route(
                self.0.as_ptr(),
                key,
                consume.into(),
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        if status != 0 {
            return Err(if status == 2 { CHANGED } else { UNAVAILABLE });
        }
        guard()
    }
    pub fn open(guard: &dyn Fn() -> Result<()>) -> Result<Self> {
        guard()?;
        let mut context = Check(guard);
        let mut status = 3;
        let pointer = unsafe {
            snip_ime_connect(check, (&mut context as *mut Check<'_>).cast(), &mut status)
        };
        let owner =
            Self(NonNull::new(pointer).ok_or(if status == 2 { CHANGED } else { UNAVAILABLE })?);
        let peer = unsafe { snip_ime_peer(owner.0.as_ptr()) };
        if !crate::desktop::wayland_peer_matches(peer) {
            return Err(UNAVAILABLE);
        }
        guard()?;
        // Peer identity is verified before requesting an input-method object.
        let status = unsafe {
            snip_ime_start(
                owner.0.as_ptr(),
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        if status != 0 {
            return Err(if status == 2 { CHANGED } else { UNAVAILABLE });
        }
        guard()?;
        Ok(owner)
    }
    pub fn poll(&self, milliseconds: u32, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        let mut context = Check(guard);
        outcome(unsafe {
            snip_ime_poll(
                self.0.as_ptr(),
                milliseconds,
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        })
    }
    pub fn frame(&self) -> Result<Option<Frame>> {
        // Every bit pattern of these primitive C-compatible fields is valid.
        let mut raw = Zeroizing::new(unsafe { std::mem::zeroed::<RawFrame>() });
        if unsafe { snip_ime_frame(self.0.as_ptr(), &mut *raw) } == 0 {
            return Ok(None);
        }
        if raw.length > MAX_SURROUNDING_BYTES as u32 {
            return Err(UNAVAILABLE);
        }
        let text = if raw.has_text == 1 {
            let text =
                std::str::from_utf8(&raw.text[..raw.length as usize]).map_err(|_| UNAVAILABLE)?;
            Some(Zeroizing::new(text.to_owned()))
        } else {
            None
        };
        Ok(Some(Frame::from_protocol(
            Context {
                field: raw.field,
                serial: raw.serial,
            },
            raw.active == 1,
            text,
            (raw.cursor, raw.anchor),
            (raw.has_type == 1).then_some((raw.hint, raw.purpose)),
            raw.cause,
        )))
    }
}
impl Backend for Connection {
    fn replace(
        &mut self,
        expected: &Frame,
        before: u32,
        text: &str,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        guard()?;
        if text.len() > CHUNK_BYTES || text.contains('\0') {
            return Err(UNSUPPORTED);
        }
        let mut bytes = Zeroizing::new(text.as_bytes().to_vec());
        bytes.push(0);
        let mut context = Check(guard);
        let status = unsafe {
            snip_ime_replace(
                self.0.as_ptr(),
                expected.context.field,
                expected.context.serial,
                before,
                bytes.as_ptr().cast(),
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        if status != 0 {
            return Err(if status == 2 { CHANGED } else { UNAVAILABLE });
        }
        guard()
    }
}
impl Drop for Connection {
    fn drop(&mut self) {
        unsafe {
            snip_ime_close(self.0.as_ptr());
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn revoked_inline_connection_does_not_open_the_real_display() {
        assert!(Connection::open(&|| Err(CHANGED)).is_err());
    }
}
#[cfg(test)]
#[path = "inline_wayland_tests.rs"]
pub(crate) mod protocol_tests;
