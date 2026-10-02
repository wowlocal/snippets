//! Native input stays in-process; plaintext never enters argv, an external
//! helper, the clipboard or a disk file. Only anonymous sealed XKB maps cross FFI.
use super::*;
use std::{
    ffi::{c_int, c_void},
    fs::File,
    io::Write,
    os::fd::{AsRawFd, FromRawFd},
    ptr::NonNull,
};
const UNAVAILABLE: Error = Error(
    "Native secure input is unavailable or was interrupted. No clipboard fallback or automatic retry was performed.",
);
unsafe extern "C" {
    fn snip_input_open(
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
        status: *mut c_int,
    ) -> *mut c_void;
    fn snip_input_close(owner: *mut c_void);
    fn snip_input_keymap(
        owner: *mut c_void,
        fd: c_int,
        size: u32,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_input_key(
        owner: *mut c_void,
        code: u32,
        check: unsafe extern "C" fn(*mut c_void) -> c_int,
        context: *mut c_void,
    ) -> c_int;
    fn snip_input_peer_process(owner: *mut c_void) -> u64;
    fn snip_input_validate_keymap(map: *const libc::c_char) -> c_int;
}
struct Check<'a>(&'a dyn Fn() -> Result<()>);
unsafe extern "C" fn check(context: *mut c_void) -> c_int {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        unsafe { (*(context.cast::<Check<'_>>())).0() }.is_ok()
    }))
    .unwrap_or(false)
    .into()
}
struct Connection(NonNull<c_void>);
impl Drop for Connection {
    fn drop(&mut self) {
        unsafe { snip_input_close(self.0.as_ptr()) };
    }
}
pub(crate) struct Native {
    target: crate::desktop::PasteTarget,
    connection: Option<Connection>,
    signature: Option<std::ffi::OsString>,
    display: Option<std::ffi::OsString>,
}
impl Native {
    pub(crate) fn new(target: crate::desktop::PasteTarget) -> Self {
        Self {
            target,
            connection: None,
            signature: std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE"),
            display: std::env::var_os("WAYLAND_DISPLAY"),
        }
    }
    fn validate(&self, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        guard()?;
        if !self.target.is_fresh()
            || !self.target.is_active_unlocked()
            || std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") != self.signature
            || std::env::var_os("WAYLAND_DISPLAY") != self.display
        {
            return Err(CANCELLED);
        }
        Ok(())
    }
}
fn outcome(code: c_int) -> Result<()> {
    match code {
        0 => Ok(()),
        2 => Err(CANCELLED),
        _ => Err(UNAVAILABLE),
    }
}
impl Backend for Native {
    fn begin(&mut self, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        self.validate(guard)?;
        if self.connection.is_some() {
            return Err(UNAVAILABLE);
        }
        let pointer = {
            let checked = || self.validate(guard);
            let mut context = Check(&checked);
            let mut status = 3;
            let pointer = unsafe {
                snip_input_open(check, (&mut context as *mut Check<'_>).cast(), &mut status)
            };
            NonNull::new(pointer).ok_or(if status == 2 { CANCELLED } else { UNAVAILABLE })?
        };
        let owner = Connection(pointer);
        let pid = unsafe { snip_input_peer_process(owner.0.as_ptr()) };
        if !crate::desktop::wayland_peer_matches(pid) {
            return Err(UNAVAILABLE);
        }
        self.validate(guard)?;
        self.connection = Some(owner);
        Ok(())
    }
    fn install(&mut self, map: &[u8], guard: &dyn Fn() -> Result<()>) -> Result<()> {
        self.validate(guard)?;
        if !valid_keymap(map) {
            return Err(UNAVAILABLE);
        }
        let fd = unsafe {
            libc::memfd_create(
                c"snippets-input-map".as_ptr(),
                libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING,
            )
        };
        if fd < 0 {
            return Err(UNAVAILABLE);
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        file.write_all(map).map_err(|_| UNAVAILABLE)?;
        let seals =
            libc::F_SEAL_GROW | libc::F_SEAL_SHRINK | libc::F_SEAL_WRITE | libc::F_SEAL_SEAL;
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_ADD_SEALS, seals) } < 0 {
            return Err(UNAVAILABLE);
        }
        let owner = self.connection.as_ref().ok_or(UNAVAILABLE)?;
        let checked = || self.validate(guard);
        let mut context = Check(&checked);
        let status = unsafe {
            snip_input_keymap(
                owner.0.as_ptr(),
                file.as_raw_fd(),
                map.len() as u32,
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        outcome(status)?;
        self.validate(guard)
    }
    fn key(&mut self, code: u32, guard: &dyn Fn() -> Result<()>) -> Result<()> {
        self.validate(guard)?;
        let owner = self.connection.as_ref().ok_or(UNAVAILABLE)?;
        let checked = || self.validate(guard);
        let mut context = Check(&checked);
        let status = unsafe {
            snip_input_key(
                owner.0.as_ptr(),
                code,
                check,
                (&mut context as *mut Check<'_>).cast(),
            )
        };
        outcome(status)?;
        self.validate(guard)
    }
}
pub(super) fn valid_keymap(map: &[u8]) -> bool {
    map.len() <= 65536
        && map.last() == Some(&0)
        && !map[..map.len().saturating_sub(1)].contains(&0)
        && unsafe { snip_input_validate_keymap(map.as_ptr().cast()) } != 0
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generated_unicode_maps_are_accepted_by_native_xkb_without_a_display() {
        let values = "aAZя中🙂\t\n\u{301}"
            .chars()
            .map(|c| c as u32)
            .collect::<Vec<_>>();
        let map = Keymap::new(&values).unwrap();
        assert!(valid_keymap(&map.bytes));
        assert!(!valid_keymap(b"Public invalid XKB map\0"));
        assert!(!valid_keymap(b"Public unterminated map"));
    }
    #[test]
    fn revoked_native_owner_never_connects_to_a_real_display() {
        let target = crate::desktop::PasteTarget::from_window(
            &serde_json::json!({"address":"0x123","pid":1}),
        )
        .unwrap();
        let mut native = Native::new(target);
        assert!(native.begin(&|| Err(CANCELLED)).is_err());
        assert!(native.connection.is_none());
    }
}
