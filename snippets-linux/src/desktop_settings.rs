//! App-owned desktop preferences and explicit XDG login registration.
//! Reading defaults creates nothing. No compositor configuration is modified.
use crate::model::{self, Error, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
const SETTINGS: &str = "desktop-settings.json";
const ENTRY: &str = "com.khm.snippets.linux.desktop";
const LIMIT: usize = 16 * 1024;
const UNREADABLE: Error = Error("Desktop settings could not be read safely.");
const CHANGED: Error =
    Error("Launch-at-login settings changed. Reopen Settings before trying again.");
const FOREIGN: Error =
    Error("The existing login entry is not managed by Snippets. It was preserved.");
#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloseAction {
    #[default]
    Hide,
    Quit,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preferences {
    schema: u32,
    pub close_action: CloseAction,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            schema: 1,
            close_action: CloseAction::Hide,
        }
    }
}
fn read_small(path: &Path) -> Result<Option<Vec<u8>>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(UNREADABLE),
    };
    let metadata = file.metadata().map_err(|_| UNREADABLE)?;
    if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > LIMIT as u64 {
        return Err(UNREADABLE);
    }
    let mut bytes = vec![];
    file.take(LIMIT as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| UNREADABLE)?;
    if bytes.len() > LIMIT {
        return Err(UNREADABLE);
    }
    Ok(Some(bytes))
}
impl Preferences {
    pub fn read(root: &Path) -> Result<Self> {
        let Some(bytes) = read_small(&root.join(SETTINGS))? else {
            return Ok(Self {
                schema: 1,
                close_action: CloseAction::Hide,
            });
        };
        let value: Self = serde_json::from_slice(&bytes).map_err(|_| UNREADABLE)?;
        if value.schema != 1 {
            return Err(Error("Desktop settings have an unsupported version."));
        }
        Ok(value)
    }
    pub fn write(root: &Path, close_action: CloseAction) -> Result<()> {
        let _guard = crate::model::Library::lock_root(root)?;
        Self::read(root)?; // Preserve unreadable and future preferences.
        let bytes = serde_json::to_vec_pretty(&Self {
            schema: 1,
            close_action,
        })
        .map_err(|_| UNREADABLE)?;
        model::atomic_write(&root.join(SETTINGS), &bytes)
    }
}
pub fn config_home(
    config: Option<&std::ffi::OsStr>,
    home: Option<&std::ffi::OsStr>,
) -> Result<PathBuf> {
    let path = config
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            home.filter(|p| !p.is_empty())
                .map(|p| PathBuf::from(p).join(".config"))
        })
        .ok_or(Error("A desktop configuration directory is required."))?;
    if !path.is_absolute() {
        return Err(Error(
            "The desktop configuration directory must be absolute.",
        ));
    }
    Ok(path)
}
fn argument(path: &Path) -> Result<String> {
    let text = path
        .to_str()
        .ok_or(Error("The application path is not valid UTF-8."))?;
    if !path.is_absolute()
        || text.len() > 4096
        || text.contains('=')
        || text.chars().any(char::is_control)
    {
        return Err(Error(
            "The application path cannot be used for launch at login.",
        ));
    }
    let mut value = String::from("\"");
    for c in text.chars() {
        match c {
            '\\' => value.push_str(r"\\\\"),
            '"' | '$' | '`' => {
                value.push_str(r"\\");
                value.push(c)
            }
            '%' => value.push_str("%%"),
            _ => value.push(c),
        }
    }
    value.push('"');
    Ok(value)
}
// A fixed native executable lets GLib validate argv[0] before expanding %% in
// the application argument. env execs the absolute app path without a shell.
const HEADER: &str = "[Desktop Entry]\nType=Application\nName=Snippets\nComment=Your personal snippet library\nExec=/usr/bin/env -- ";
fn entry(executable: &Path, enabled: bool) -> Result<Vec<u8>> {
    Ok(format!("{HEADER}{} --background\nIcon=com.khm.snippets.linux\nTerminal=false\nHidden={}\nX-Snippets-Autostart-Version=1\n",argument(executable)?,!enabled).into_bytes())
}
fn decoded_argument(value: &str) -> Result<PathBuf> {
    let value = value
        .strip_prefix('"')
        .and_then(|v| v.strip_suffix('"'))
        .ok_or(FOREIGN)?;
    let mut chars = value.chars();
    let mut path = String::new();
    while let Some(c) = chars.next() {
        match c {
            '%' => {
                if chars.next() != Some('%') {
                    return Err(FOREIGN);
                }
                path.push('%')
            }
            '\\' => {
                if chars.next() != Some('\\') {
                    return Err(FOREIGN);
                }
                match chars.next() {
                    Some('\\') => {
                        if chars.next() != Some('\\') {
                            return Err(FOREIGN);
                        }
                        path.push('\\')
                    }
                    Some(c @ ('"' | '$' | '`')) => path.push(c),
                    _ => return Err(FOREIGN),
                }
            }
            '"' | '$' | '`' => return Err(FOREIGN),
            _ => path.push(c),
        }
    }
    let path = PathBuf::from(path);
    argument(&path).map_err(|_| FOREIGN)?;
    Ok(path)
}
#[derive(Clone)]
pub struct Registration {
    directory: PathBuf,
}
#[derive(Clone)]
pub struct Snapshot {
    bytes: Option<Vec<u8>>,
    pub enabled: bool,
    pub executable: Option<PathBuf>,
}
impl Registration {
    pub fn new(config_home: PathBuf) -> Result<Self> {
        if !config_home.is_absolute() {
            return Err(UNREADABLE);
        }
        Ok(Self {
            directory: config_home.join("autostart"),
        })
    }
    pub fn from_environment() -> Result<Self> {
        Self::new(config_home(
            std::env::var_os("XDG_CONFIG_HOME").as_deref(),
            std::env::var_os("HOME").as_deref(),
        )?)
    }
    fn directory_safe(&self) -> Result<()> {
        match fs::symlink_metadata(&self.directory) {
            Ok(m) if m.is_dir() => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            _ => Err(UNREADABLE),
        }
    }
    pub fn read(&self) -> Result<Snapshot> {
        self.directory_safe()?;
        let bytes = read_small(&self.directory.join(ENTRY))?;
        let Some(data) = &bytes else {
            return Ok(Snapshot {
                bytes,
                enabled: false,
                executable: None,
            });
        };
        let text = std::str::from_utf8(data).map_err(|_| FOREIGN)?;
        let command = text
            .strip_prefix(HEADER)
            .and_then(|v| v.split_once(" --background\n"))
            .ok_or(FOREIGN)?
            .0;
        let executable = decoded_argument(command)?;
        let enabled = if entry(&executable, true)? == *data {
            true
        } else if entry(&executable, false)? == *data {
            false
        } else {
            return Err(FOREIGN);
        };
        Ok(Snapshot {
            bytes,
            enabled,
            executable: Some(executable),
        })
    }
    pub fn write(&self, before: &Snapshot, executable: &Path, enabled: bool) -> Result<Snapshot> {
        let bytes = entry(executable, enabled)?;
        if enabled {
            // The installed systemd generator applies an extra C unescape after
            // the desktop-entry/quote rules and cannot preserve a literal \.
            // Refuse before publication instead of saving an entry it skips.
            if executable.to_str().is_some_and(|p| p.contains('\\')) {
                return Err(Error(
                    "Launch at login cannot use an application path containing a backslash. Move this installation to a standard directory first.",
                ));
            }
            let m = fs::metadata(executable)
                .map_err(|_| Error("The application executable is unavailable."))?;
            if !m.is_file() || m.permissions().mode() & 0o111 == 0 {
                return Err(Error("Launch at login requires an executable application."));
            }
        }
        self.directory_safe()?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.directory)
            .map_err(|_| Error("The login directory could not be created."))?;
        self.directory_safe()?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.directory.join(".snippets-login.lock"))
            .map_err(|_| UNREADABLE)?;
        let metadata = lock.metadata().map_err(|_| UNREADABLE)?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(UNREADABLE);
        }
        lock.try_lock()
            .map_err(|_| Error("Login settings are busy. Try again shortly."))?;
        if self.read()?.bytes != before.bytes {
            return Err(CHANGED);
        }
        // Hidden=true overrides any lower-priority system entry on disable.
        model::atomic_write(&self.directory.join(ENTRY), &bytes)?;
        // Keep the exact result; a following outside edit is detected on the next action.
        Ok(Snapshot {
            bytes: Some(bytes),
            enabled,
            executable: Some(executable.into()),
        })
    }
    pub fn entry_path(&self) -> PathBuf {
        self.directory.join(ENTRY)
    }
}
#[cfg(test)]
#[path = "desktop_settings_tests.rs"]
mod tests;
