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
unsafe extern "C" {
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
mod protocol_tests;
