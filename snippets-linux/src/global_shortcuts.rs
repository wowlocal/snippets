//! Explicit local consent and closed native Omarchy action vocabulary.
//! No compositor configuration is written. Registration conveys public labels only.
use crate::model::{Error, Library, Result, atomic_write};
use serde::{Deserialize, Serialize};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

const FILE: &str = "global-shortcuts.json";
const UNREADABLE: Error = Error("Global shortcut settings could not be read safely.");
#[derive(Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preference {
    schema: u32,
    pub enabled: bool,
}
impl Preference {
    pub fn read(root: &Path) -> Result<Self> {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(root.join(FILE))
        {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self {
                    schema: 1,
                    enabled: false,
                });
            }
            Err(_) => return Err(UNREADABLE),
        };
        let metadata = file.metadata().map_err(|_| UNREADABLE)?;
        if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > 1024 {
            return Err(UNREADABLE);
        }
        let mut bytes = Vec::new();
        file.take(1025)
            .read_to_end(&mut bytes)
            .map_err(|_| UNREADABLE)?;
        if bytes.len() > 1024 {
            return Err(UNREADABLE);
        }
        let value: Self = serde_json::from_slice(&bytes).map_err(|_| UNREADABLE)?;
        if value.schema != 1 {
            return Err(UNREADABLE);
        }
        Ok(value)
    }
    pub fn write(root: &Path, enabled: bool) -> Result<()> {
        let _guard = Library::lock_root(root)?;
        Self::read(root)?;
        atomic_write(
            &root.join(FILE),
            &serde_json::to_vec_pretty(&Self { schema: 1, enabled }).map_err(|_| UNREADABLE)?,
        )
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action {
    Open,
    Picker,
    Capture,
}
impl Action {
    #[cfg(any(test, feature = "desktop"))]
    pub(crate) fn from_id(id: u32) -> Option<Self> {
        match id {
            1 => Some(Self::Open),
            2 => Some(Self::Picker),
            3 => Some(Self::Capture),
            _ => None,
        }
    }
}
/// Examples only: physical keys remain the user's compositor configuration.
pub const BINDINGS: &str = "o.bind(\"SUPER + ALT + N\", \"Snippets\", hl.dsp.global(\"com.khm.snippets.linux:open\"))\no.bind(\"SUPER + ALT + P\", \"Snippets paste picker\", hl.dsp.global(\"com.khm.snippets.linux:picker\"))\no.bind(\"SUPER + ALT + C\", \"Snippets capture\", hl.dsp.global(\"com.khm.snippets.linux:capture\"))";

#[cfg(feature = "desktop")]
#[path = "shortcuts_worker.rs"]
mod worker;
#[cfg(feature = "desktop")]
pub(crate) use worker::{Handle, Status};

#[cfg(test)]
#[path = "global_shortcuts_tests.rs"]
mod tests;
