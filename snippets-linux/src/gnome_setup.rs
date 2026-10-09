//! Explicit per-user GNOME setup. Preparing a plan performs no writes.
use crate::model::{self, Error, Result};
use std::{
    fs::{self, OpenOptions},
    io::Read,
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

pub(crate) const UUID: &str = "snippets@wowlocal.github.io";
pub(crate) const UNIT: &str = "org.freedesktop.IBus.session.GNOME.service";
#[path = "gnome_setup_runtime.rs"]
mod runtime;
pub(crate) use runtime::{activate, prepare};
const HEADER: &str = "# Snippets GNOME integration v1\n# ";
const CHANGED: Error = Error("GNOME configuration changed. Reopen setup and try again.");
const FOREIGN: Error =
    Error("An existing GNOME integration file could not be updated safely. It was preserved.");
const INSTALLED: Error =
    Error("Install the GNOME build of Snippets before setting up integration.");

struct Change {
    path: PathBuf,
    before: Option<Vec<u8>>,
    after: Vec<u8>,
}
pub(crate) struct Plan {
    changes: Vec<Change>,
    lock_directory: PathBuf,
}

fn path_text(path: &Path) -> Result<&str> {
    let text = path.to_str().ok_or(INSTALLED)?;
    if !path.is_absolute()
        || text.len() > 4096
        || text.contains(':')
        || text.chars().any(char::is_control)
    {
        return Err(Error(
            "This installation path cannot be used for GNOME input integration.",
        ));
    }
    Ok(text)
}
fn directory(path: &Path) -> Result<()> {
    // Inspect every existing ancestor. A linked output directory must not
    // redirect this explicit operation into another installation/configuration.
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(m) if m.is_dir() => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            _ => return Err(FOREIGN),
        }
    }
    Ok(())
}
fn read(path: &Path) -> Result<Option<Vec<u8>>> {
    directory(path.parent().ok_or(FOREIGN)?)?;
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(FOREIGN),
    };
    let meta = file.metadata().map_err(|_| FOREIGN)?;
    if !meta.is_file()
        || meta.nlink() != 1
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.len() > 65536
    {
        return Err(FOREIGN);
    }
    let mut data = vec![];
    file.take(65537)
        .read_to_end(&mut data)
        .map_err(|_| FOREIGN)?;
    if data.len() > 65536 {
        return Err(FOREIGN);
    }
    Ok(Some(data))
}
fn unit_bytes(paths: &[String]) -> Result<Vec<u8>> {
    if paths.is_empty() || paths.len() > 64 {
        return Err(FOREIGN);
    }
    for path in paths {
        path_text(Path::new(path))?;
    }
    let joined = paths.join(":");
    if joined.len() > 16384 {
        return Err(FOREIGN);
    }
    // systemd expands percent specifiers, but not dollar variables, in
    // Environment=. Quote backslashes and quotes using its C-string rules.
    let escaped = joined
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%");
    let receipt = serde_json::to_string(paths).map_err(|_| FOREIGN)?;
    Ok(
        format!("{HEADER}{receipt}\n[Service]\nEnvironment=\"IBUS_COMPONENT_PATH={escaped}\"\n")
            .into_bytes(),
    )
}
fn previous_paths(bytes: &[u8]) -> Result<Vec<String>> {
    let text = std::str::from_utf8(bytes).map_err(|_| FOREIGN)?;
    let receipt = text
        .strip_prefix(HEADER)
        .and_then(|v| v.split_once('\n'))
        .ok_or(FOREIGN)?
        .0;
    let paths: Vec<String> = serde_json::from_str(receipt).map_err(|_| FOREIGN)?;
    if unit_bytes(&paths)? != bytes {
        return Err(FOREIGN);
    }
    Ok(paths)
}

impl Plan {
    pub(crate) fn prepare(
        executable: &Path,
        config: &Path,
        data: &Path,
        inherited: &[String],
    ) -> Result<Self> {
        path_text(config)?;
        path_text(data)?;
        let install = executable.parent().ok_or(INSTALLED)?;
        let share = install.parent().ok_or(INSTALLED)?;
        let engine = install.join("snippets-ibus");
        let meta = fs::symlink_metadata(&engine).map_err(|_| INSTALLED)?;
        if !meta.is_file() || meta.nlink() != 1 || meta.permissions().mode() & 0o111 == 0 {
            return Err(INSTALLED);
        }
        let component = share.join("ibus/component");
        let xml = fs::symlink_metadata(component.join("snippets.xml")).map_err(|_| INSTALLED)?;
        if !xml.is_file() {
            return Err(INSTALLED);
        }
        let own = path_text(&component)?.to_owned();
        let unit = config
            .join("systemd/user")
            .join(format!("{UNIT}.d/90-snippets.conf"));
        let before = read(&unit)?;
        let old = before
            .as_deref()
            .map(previous_paths)
            .transpose()?
            .unwrap_or_default();
        let mut paths = vec![own];
        // Drop only the former installation's own component path when moving.
        // Preserve previously recorded custom paths and the live service paths.
        for value in inherited
            .iter()
            .map(String::as_str)
            .chain(old.iter().skip(1).map(String::as_str))
            .chain(std::iter::once(env!("SNIPPETS_IBUS_COMPONENT_DIR")))
        {
            for path in value.split(':') {
                path_text(Path::new(path))?;
                if old.first().is_some_and(|old| old == path) {
                    continue;
                }
                if !paths.iter().any(|v| v == path) {
                    paths.push(path.to_owned());
                }
            }
        }
        let mut changes = vec![Change {
            path: unit,
            before,
            after: unit_bytes(&paths)?,
        }];
        let extension = data.join("gnome-shell/extensions").join(UUID);
        let metadata = read(&extension.join("metadata.json"))?;
        if let Some(bytes) = &metadata {
            let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| FOREIGN)?;
            if value.get("uuid").and_then(|v| v.as_str()) != Some(UUID)
                || value
                    .get("version")
                    .and_then(|v| v.as_u64())
                    .is_none_or(|v| v > 1)
            {
                return Err(FOREIGN);
            }
        } else if read(&extension.join("extension.js"))?.is_some() {
            return Err(FOREIGN);
        }
        for (name, source) in [
            (
                "metadata.json",
                include_bytes!("../gnome/snippets@wowlocal.github.io/metadata.json").as_slice(),
            ),
            (
                "extension.js",
                include_bytes!("../gnome/snippets@wowlocal.github.io/extension.js").as_slice(),
            ),
        ] {
            let path = extension.join(name);
            changes.push(Change {
                before: read(&path)?,
                path,
                after: source.to_vec(),
            });
        }
        Ok(Self {
            changes,
            lock_directory: config.join("snippets"),
        })
    }
    pub(crate) fn apply(&self) -> Result<()> {
        directory(&self.lock_directory)?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.lock_directory)
            .map_err(|_| FOREIGN)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.lock_directory.join(".gnome-setup.lock"))
            .map_err(|_| FOREIGN)?;
        let meta = lock.metadata().map_err(|_| FOREIGN)?;
        if !meta.is_file() || meta.nlink() != 1 || meta.uid() != unsafe { libc::geteuid() } {
            return Err(FOREIGN);
        }
        lock.try_lock()
            .map_err(|_| Error("GNOME setup is busy. Try again shortly."))?;
        for change in &self.changes {
            if read(&change.path)? != change.before {
                return Err(CHANGED);
            }
        }
        for change in &self.changes {
            if change.before.as_deref() == Some(change.after.as_slice()) {
                continue;
            }
            let parent = change.path.parent().ok_or(FOREIGN)?;
            directory(parent)?;
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .map_err(|_| FOREIGN)?;
            directory(parent)?;
            if read(&change.path)? != change.before {
                return Err(CHANGED);
            }
            model::atomic_write(&change.path, &change.after)?;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "gnome_setup_tests.rs"]
mod tests;
