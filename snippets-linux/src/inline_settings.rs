//! Persistent opt-in settings shared by GUI and CLI. Reading defaults creates nothing.
use crate::model::{self, Error, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

#[derive(Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preference {
    schema: u32,
    pub enabled: bool,
    #[serde(default)]
    pub suggestions: bool,
}

impl Preference {
    pub fn read(root: &Path) -> Result<Self> {
        let path = root.join("inline-expansion.json");
        let file = match fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self {
                    schema: 1,
                    enabled: false,
                    suggestions: false,
                });
            }
            Err(_) => return Err(Error("Inline expansion settings are unreadable.")),
        };
        let metadata = file
            .metadata()
            .map_err(|_| Error("Inline expansion settings are unreadable."))?;
        if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > 1024 {
            return Err(Error(
                "Inline expansion settings must be a small, unlinked regular file.",
            ));
        }
        let mut bytes = Vec::new();
        file.take(1025)
            .read_to_end(&mut bytes)
            .map_err(|_| Error("Inline expansion settings are unreadable."))?;
        if bytes.len() > 1024 {
            return Err(Error("Inline expansion settings exceed their size limit."));
        }
        let value: Self = serde_json::from_slice(&bytes)
            .map_err(|_| Error("Inline expansion settings are unreadable."))?;
        if value.schema != 1 {
            return Err(Error(
                "Inline expansion settings have an unsupported version.",
            ));
        }
        Ok(value)
    }
    pub fn write(root: &Path, enabled: bool) -> Result<()> {
        let suggestions = Self::read(root)?.suggestions;
        Self::write_value(root, enabled, suggestions)
    }
    pub fn write_suggestions(root: &Path, suggestions: bool) -> Result<()> {
        let enabled = Self::read(root)?.enabled;
        Self::write_value(root, enabled, suggestions)
    }
    fn write_value(root: &Path, enabled: bool, suggestions: bool) -> Result<()> {
        let value = Self {
            schema: 1,
            enabled,
            suggestions,
        };
        let bytes = serde_json::to_vec(&value)
            .map_err(|_| Error("Inline expansion settings could not be saved."))?;
        model::atomic_write(&root.join("inline-expansion.json"), &bytes)
    }
    pub fn enable_with_suggestions(root: &Path) -> Result<()> {
        Self::read(root)?;
        Self::write_value(root, true, true)
    }
}
