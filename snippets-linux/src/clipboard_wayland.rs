//! Owned read-only Wayland connection. C retains no Rust pointers or buffers.
use super::*;
use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    ptr::NonNull,
};
unsafe extern "C" {
    fn snip_control_open(
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
    fn snip_control_close(owner: *mut c_void);
    fn snip_control_generation(owner: *mut c_void) -> u64;
    fn snip_control_peer_process(owner: *mut c_void) -> u64;
    fn snip_control_next(
        owner: *mut c_void,
        previous: u64,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_control_formats(owner: *mut c_void) -> u32;
    fn snip_control_format(owner: *mut c_void, index: u32) -> *const c_char;
    fn snip_control_receive(
        owner: *mut c_void,
        generation: u64,
        mime: *const c_char,
        bytes: *mut u8,
        capacity: usize,
        length: *mut usize,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
}
pub(crate) const UNAVAILABLE: Error = Error(
    "Background clipboard monitoring is unavailable. Wayland ext-data-control-v1 support is required.",
);
struct Check<'a>(&'a dyn Fn() -> Result<()>);
unsafe extern "C" fn check(context: *mut c_void) -> c_int {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // Context is borrowed for one synchronous call and never retained by C.
        unsafe { (*(context.cast::<Check<'_>>())).0() }.is_ok()
    }))
    .unwrap_or(false)
    .into()
}
pub(crate) struct Reader(NonNull<c_void>);
impl Reader {
    pub fn open(guard: &dyn Fn() -> Result<()>) -> Result<Self> {
        guard()?;
        let mut context = Check(guard);
        let mut status = 3;
        let pointer = unsafe {
            snip_control_open(check, (&mut context as *mut Check<'_>).cast(), &mut status)
        };
        NonNull::new(pointer)
            .map(Self)
            .ok_or(if status == 2 { CANCELLED } else { UNAVAILABLE })
    }
    pub fn generation(&self) -> u64 {
        unsafe { snip_control_generation(self.0.as_ptr()) }
    }
    pub fn peer_process(&self) -> u64 {
        unsafe { snip_control_peer_process(self.0.as_ptr()) }
    }
    pub fn next(&mut self, previous: u64, guard: &dyn Fn() -> Result<()>) -> Result<bool> {
        let mut context = Check(guard);
        let status = unsafe {
            snip_control_next(
                self.0.as_ptr(),
                previous,
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        match status {
            0 => Ok(true),
            1 => Ok(false),
            2 => Err(CANCELLED),
            _ => Err(UNAVAILABLE),
        }
    }
    pub fn formats(&self) -> Result<Vec<String>> {
        let count = unsafe { snip_control_formats(self.0.as_ptr()) };
        if count > 256 {
            return Err(UNAVAILABLE);
        }
        let mut formats = Vec::new();
        for index in 0..count {
            let pointer = unsafe { snip_control_format(self.0.as_ptr(), index) };
            if pointer.is_null() {
                return Err(UNAVAILABLE);
            }
            let format = unsafe { CStr::from_ptr(pointer) }
                .to_str()
                .map_err(|_| UNAVAILABLE)?;
            if format.len() > 256 {
                return Err(UNAVAILABLE);
            }
            formats.push(format.into());
        }
        Ok(formats)
    }
    pub fn receive(
        &mut self,
        generation: u64,
        mime: &str,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<Zeroizing<String>> {
        self.receive_inner(generation, mime, guard, false)
    }
    /// Explicit placeholder acquisition permits a valid empty text selection.
    /// Background history continues rejecting empty entries.
    pub fn receive_text(
        &mut self,
        generation: u64,
        mime: &str,
        guard: &dyn Fn() -> Result<()>,
    ) -> Result<Zeroizing<String>> {
        self.receive_inner(generation, mime, guard, true)
    }
    fn receive_inner(
        &mut self,
        generation: u64,
        mime: &str,
        guard: &dyn Fn() -> Result<()>,
        allow_empty: bool,
    ) -> Result<Zeroizing<String>> {
        guard()?;
        let mime = CString::new(mime).map_err(|_| UNAVAILABLE)?;
        let mut bytes = Zeroizing::new(vec![0u8; MAX_ENTRY_BYTES + 1]);
        let mut length = 0;
        let mut context = Check(guard);
        let status = unsafe {
            snip_control_receive(
                self.0.as_ptr(),
                generation,
                mime.as_ptr(),
                bytes.as_mut_ptr(),
                bytes.len(),
                &mut length,
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        if status != 0 || length > MAX_ENTRY_BYTES {
            return Err(CANCELLED);
        }
        guard()?;
        bytes.truncate(length);
        let text = std::str::from_utf8(&bytes).map_err(|_| CANCELLED)?;
        if !(accepts(text) || allow_empty && text.is_empty()) {
            return Err(CANCELLED);
        }
        Ok(Zeroizing::new(text.into()))
    }
}
impl Drop for Reader {
    fn drop(&mut self) {
        unsafe { snip_control_close(self.0.as_ptr()) };
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn revoked_connection_does_not_open_or_read_the_real_wayland_display() {
        assert!(Reader::open(&|| Err(CANCELLED)).is_err());
    }
}
#[cfg(test)]
#[path = "clipboard_wayland_tests.rs"]
mod protocol_tests;
