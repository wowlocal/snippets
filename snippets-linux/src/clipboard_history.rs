//! Device-local, explicitly opted-in clipboard history. Bodies and keys have no
//! Debug/serialization interface; only authenticated ciphertext reaches disk.
use crate::{
    crypto,
    model::{self, Error, Library, Result},
    secret_store::{Backend, Slot, Store},
};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::AeadInOut};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};
use uuid::Uuid;
use zeroize::Zeroizing;

#[cfg(feature = "desktop")]
#[path = "clipboard_wayland.rs"]
pub(crate) mod wayland;
#[cfg(feature = "desktop")]
#[path = "clipboard_history_worker.rs"]
pub(crate) mod worker;

pub const MAX_ENTRIES: usize = 1_000;
pub const MAX_ENTRY_BYTES: usize = 256 * 1024;
pub const MAX_TOTAL_BYTES: usize = 32 * 1024 * 1024;
pub const RETENTION_MS: i64 = 7 * 24 * 60 * 60 * 1_000;
const MAX_PLAINTEXT: usize = MAX_TOTAL_BYTES + MAX_ENTRIES * 28 + 8;
const MAX_CIPHERTEXT: usize = MAX_PLAINTEXT + 32;
const AAD: &[u8] = b"snip.linux-clipboard-history.v1";
const PREFERENCE: &str = "clipboard-history.json";
const UNAVAILABLE: Error = Error("Clipboard history could not be accessed safely.");
const INVALID: Error = Error("Clipboard history is damaged or uses an unsupported format.");
const KEY: Error = Error(
    "Unlock the system keyring to use clipboard history. A missing history key cannot be replaced.",
);
pub const CANCELLED: Error = Error("Clipboard history operation was cancelled.");

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preference {
    schema_version: u8,
    pub enabled: bool,
    consent: Option<Uuid>,
    pub excluded_apps: Vec<String>,
}
impl Default for Preference {
    fn default() -> Self {
        Self {
            schema_version: 1,
            enabled: false,
            consent: None,
            excluded_apps: [
                "com.khm.snippets.linux",
                "org.keepassxc.keepassxc",
                "keepassxc",
                "bitwarden",
                "com.bitwarden.desktop",
                "1password",
                "com.1password.1password",
                "proton-pass",
                "enpass",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
        }
    }
}
impl Preference {
    /// Explicit repair disables capture, preserving every retained history byte.
    pub fn reset(root: &Path) -> Result<Self> {
        let library = Library::prepare(root.into())?;
        let _guard = library.lock()?;
        let _before = read_private(&root.join(PREFERENCE), 16 * 1024)?;
        let mut value = Self::default();
        value.excluded_apps = normalize_apps(&value.excluded_apps)?;
        value.consent = Some(Uuid::new_v4());
        model::atomic_write(
            &root.join(PREFERENCE),
            &serde_json::to_vec(&value).map_err(|_| INVALID)?,
        )?;
        Ok(value)
    }
    pub fn read(root: &Path) -> Result<Self> {
        let Some(bytes) = read_private(&root.join(PREFERENCE), 16 * 1024)? else {
            return Ok(Self::default());
        };
        let value: Self = serde_json::from_slice(&bytes).map_err(|_| INVALID)?;
        if value.schema_version != 1
            || value.consent.is_none()
            || value.consent.is_some_and(|id| id.is_nil())
            || normalize_apps(&value.excluded_apps)? != value.excluded_apps
        {
            return Err(INVALID);
        }
        Ok(value)
    }
    pub fn save(&mut self, root: &Path, enabled: bool, apps: Vec<String>) -> Result<()> {
        let library = Library::prepare(root.into())?;
        let _guard = library.lock()?;
        if Self::read(root)? != *self {
            return Err(CANCELLED);
        }
        let updated = Self {
            schema_version: 1,
            enabled,
            consent: Some(Uuid::new_v4()),
            excluded_apps: normalize_apps(&apps)?,
        };
        let bytes = serde_json::to_vec(&updated).map_err(|_| INVALID)?;
        if bytes.len() > 16 * 1024 {
            return Err(Error("App exclusions exceed the 16 KiB settings limit."));
        }
        model::atomic_write(&root.join(PREFERENCE), &bytes)?;
        *self = updated;
        Ok(())
    }
}
fn normalize_apps(apps: &[String]) -> Result<Vec<String>> {
    if apps.len() > 128 {
        return Err(INVALID);
    }
    let mut values = Vec::new();
    for app in apps {
        let app = app.trim().to_lowercase();
        if app.is_empty() {
            continue;
        }
        if app.len() > 256 || app.chars().any(char::is_control) {
            return Err(INVALID);
        }
        if !values.contains(&app) {
            values.push(app);
        }
    }
    // Always exclude our own app, including after custom exclusions.
    if !values.iter().any(|a| a == "com.khm.snippets.linux") {
        values.push("com.khm.snippets.linux".into());
    }
    values.sort();
    Ok(values)
}
/// Inspect advertised formats before requesting any bytes. Hints and source
/// classes are conventions; they cannot identify every secret or clipboard owner.
pub fn permits(formats: &[&str], local: bool) -> bool {
    if local || formats.len() > 256 {
        return false;
    }
    let mut text = false;
    for format in formats {
        if format.len() > 256 {
            return false;
        }
        let lower = format.to_ascii_lowercase();
        if matches!(
            lower.as_str(),
            "x-kde-passwordmanagerhint"
                | "application/x-kde-passwordmanagerhint"
                | "application/x-keepassxc"
                | "application/x-snippets-clipboard-history"
                | "text/uri-list"
                | "org.nspasteboard.concealedtype"
                | "org.nspasteboard.transienttype"
                | "org.nspasteboard.autogeneratedtype"
                | "org.nspasteboard.sensitivetype"
                | "com.apple.is-sensitive"
        ) {
            return false;
        }
        text |= lower == "text/plain" || lower == "text/plain;charset=utf-8";
    }
    text
}
pub fn source_permitted(class: &str, excluded: &[String]) -> bool {
    !class.trim().is_empty()
        && class.len() <= 512
        && !class.chars().any(char::is_control)
        && !excluded
            .iter()
            .any(|app| class.trim().to_lowercase() == *app)
}
#[derive(Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: Uuid,
    pub copied_at_ms: i64,
    text: Zeroizing<String>,
}
impl Entry {
    pub fn text(&self) -> &str {
        &self.text
    }
}
pub fn accepts(text: &str) -> bool {
    !text.is_empty() && text.len() <= MAX_ENTRY_BYTES && !text.contains('\0')
}
pub fn retaining(mut entries: Vec<Entry>, now: i64) -> Vec<Entry> {
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.copied_at_ms));
    let mut kept = Vec::new();
    {
        let mut texts = HashSet::new();
        let mut ids = HashSet::new();
        let mut bytes = 0;
        for (index, entry) in entries.iter().enumerate() {
            if entry.copied_at_ms <= now.saturating_sub(RETENTION_MS)
                || !accepts(entry.text())
                || texts.contains(entry.text())
                || ids.contains(&entry.id)
            {
                continue;
            }
            if kept.len() == MAX_ENTRIES || bytes + entry.text.len() > MAX_TOTAL_BYTES {
                break;
            }
            texts.insert(entry.text());
            ids.insert(entry.id);
            bytes += entry.text.len();
            kept.push(index);
        }
    }
    entries
        .into_iter()
        .enumerate()
        .filter_map(|(index, mut entry)| {
            if kept.binary_search(&index).is_err() {
                return None;
            }
            entry.copied_at_ms = entry.copied_at_ms.min(now);
            Some(entry)
        })
        .collect()
}
pub fn recording(text: Zeroizing<String>, mut entries: Vec<Entry>, now: i64) -> Vec<Entry> {
    if !accepts(&text) {
        return retaining(entries, now);
    }
    let id = entries
        .iter()
        .find(|entry| entry.text.as_bytes() == text.as_bytes())
        .map_or_else(Uuid::new_v4, |entry| entry.id);
    entries.retain(|entry| entry.id != id);
    entries.insert(
        0,
        Entry {
            id,
            copied_at_ms: now,
            text,
        },
    );
    retaining(entries, now)
}
pub fn search(query: &str, entries: &[Entry]) -> Vec<Uuid> {
    if query.len() > 4096 {
        return Vec::new();
    }
    let terms: Vec<_> = query.split_whitespace().map(model::folded).collect();
    if terms.is_empty() {
        return entries.iter().map(|entry| entry.id).collect();
    }
    entries
        .iter()
        .filter(|entry| {
            let folded = Zeroizing::new(model::folded(entry.text()));
            terms.iter().all(|term| folded.contains(term))
        })
        .map(|entry| entry.id)
        .collect()
}
pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}
fn read_private(path: &Path, limit: usize) -> Result<Option<Vec<u8>>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        _ => return Err(UNAVAILABLE),
    };
    let metadata = file.metadata().map_err(|_| UNAVAILABLE)?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.len() > limit as u64
    {
        return Err(UNAVAILABLE);
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| UNAVAILABLE)?;
    if bytes.len() > limit {
        return Err(UNAVAILABLE);
    }
    Ok(Some(bytes))
}
fn directory(root: &Path) -> Result<PathBuf> {
    let directory = root.join("ClipboardHistory");
    match fs::symlink_metadata(&directory) {
        Ok(metadata)
            if metadata.is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0 => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
        _ => return Err(UNAVAILABLE),
    }
    Ok(directory)
}
fn read_image(root: &Path) -> Result<Option<Vec<u8>>> {
    read_private(&directory(root)?.join("history.bin"), MAX_CIPHERTEXT)
}
fn encode(entries: &[Entry]) -> Result<Zeroizing<Vec<u8>>> {
    let length = entries.iter().try_fold(8usize, |length, entry| {
        length.checked_add(28 + entry.text.len()).ok_or(INVALID)
    })?;
    if length > MAX_PLAINTEXT || entries.len() > MAX_ENTRIES {
        return Err(INVALID);
    }
    // Reserve the tag too; plaintext buffers must not leave earlier allocations
    // behind when growing or sealing.
    let mut bytes = Zeroizing::new(Vec::with_capacity(length + 16));
    bytes.extend_from_slice(b"HST1");
    bytes.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for entry in entries {
        bytes.extend_from_slice(entry.id.as_bytes());
        bytes.extend_from_slice(&entry.copied_at_ms.to_be_bytes());
        bytes.extend_from_slice(&(entry.text.len() as u32).to_be_bytes());
        bytes.extend_from_slice(entry.text.as_bytes());
    }
    if bytes.len() > MAX_PLAINTEXT || entries.len() > MAX_ENTRIES {
        return Err(INVALID);
    }
    Ok(bytes)
}
fn decode(mut bytes: &[u8]) -> Result<Vec<Entry>> {
    fn take<'a>(bytes: &mut &'a [u8], size: usize) -> Result<&'a [u8]> {
        if bytes.len() < size {
            return Err(INVALID);
        }
        let (head, tail) = bytes.split_at(size);
        *bytes = tail;
        Ok(head)
    }
    if bytes.len() > MAX_PLAINTEXT || take(&mut bytes, 4)? != b"HST1" {
        return Err(INVALID);
    }
    let count = u32::from_be_bytes(take(&mut bytes, 4)?.try_into().map_err(|_| INVALID)?) as usize;
    if count > MAX_ENTRIES {
        return Err(INVALID);
    }
    let mut entries = Vec::new();
    let mut ids = HashSet::new();
    let mut total = 0;
    for _ in 0..count {
        let id = Uuid::from_slice(take(&mut bytes, 16)?).map_err(|_| INVALID)?;
        if id.is_nil() || !ids.insert(id) {
            return Err(INVALID);
        }
        let date = i64::from_be_bytes(take(&mut bytes, 8)?.try_into().map_err(|_| INVALID)?);
        let length =
            u32::from_be_bytes(take(&mut bytes, 4)?.try_into().map_err(|_| INVALID)?) as usize;
        total += length;
        if date < 0 || length > MAX_ENTRY_BYTES || total > MAX_TOTAL_BYTES {
            return Err(INVALID);
        }
        let text = std::str::from_utf8(take(&mut bytes, length)?).map_err(|_| INVALID)?;
        if !accepts(text) {
            return Err(INVALID);
        }
        entries.push(Entry {
            id,
            copied_at_ms: date,
            text: Zeroizing::new(text.into()),
        });
    }
    if !bytes.is_empty() {
        return Err(INVALID);
    }
    Ok(entries)
}
fn seal(entries: &[Entry], key: &[u8]) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| KEY)?;
    let nonce: [u8; 12] = crypto::random()?;
    let mut bytes = encode(entries)?;
    cipher
        .encrypt_in_place(&Nonce::from(nonce), AAD, &mut *bytes)
        .map_err(|_| INVALID)?;
    let mut image = b"SCH1".to_vec();
    image.extend_from_slice(&nonce);
    image.extend_from_slice(&bytes);
    Ok(image)
}
fn open(image: &[u8], key: &[u8]) -> Result<Vec<Entry>> {
    if !(32..=MAX_CIPHERTEXT).contains(&image.len()) || &image[..4] != b"SCH1" {
        return Err(INVALID);
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| KEY)?;
    let nonce: [u8; 12] = image[4..16].try_into().map_err(|_| INVALID)?;
    let mut bytes = Zeroizing::new(image[16..].to_vec());
    cipher
        .decrypt_in_place(&Nonce::from(nonce), AAD, &mut *bytes)
        .map_err(|_| INVALID)?;
    decode(&bytes)
}
fn write_image(root: &Path, before: Option<&[u8]>, image: &[u8]) -> Result<()> {
    if read_image(root)?.as_deref() != before {
        return Err(CANCELLED);
    }
    let path = directory(root)?;
    fs::create_dir_all(&path).map_err(|_| UNAVAILABLE)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).map_err(|_| UNAVAILABLE)?;
    model::atomic_write(&path.join("history.bin"), image)
}
/// Load never initializes an owner or replaces a lost key. Retention is applied
/// durably on explicit viewing and periodic opted-in maintenance.
pub fn load<B: Backend>(
    root: &Path,
    backend: B,
    now: i64,
    check: &dyn Fn() -> Result<()>,
) -> Result<Vec<Entry>> {
    change(root, backend, now, None, check)
}
enum Change {
    Record(Zeroizing<String>, Preference),
    Delete(Uuid),
}
pub fn record<B: Backend>(
    root: &Path,
    backend: B,
    preference: &Preference,
    text: Zeroizing<String>,
    now: i64,
    check: &dyn Fn() -> Result<()>,
) -> Result<usize> {
    if !accepts(&text) {
        return Err(INVALID);
    }
    change(
        root,
        backend,
        now,
        Some(Change::Record(text, preference.clone())),
        check,
    )
    .map(|entries| entries.len())
}
pub fn delete<B: Backend>(
    root: &Path,
    backend: B,
    id: Uuid,
    now: i64,
    check: &dyn Fn() -> Result<()>,
) -> Result<Vec<Entry>> {
    change(root, backend, now, Some(Change::Delete(id)), check)
}
fn change<B: Backend>(
    root: &Path,
    backend: B,
    now: i64,
    action: Option<Change>,
    check: &dyn Fn() -> Result<()>,
) -> Result<Vec<Entry>> {
    check()?;
    if now < 0 {
        return Err(INVALID);
    }
    let before = {
        let library = Library::prepare(root.into())?;
        let _guard = library.lock()?;
        if let Some(Change::Record(_, preference)) = &action
            && (!preference.enabled || Preference::read(root)? != *preference)
        {
            return Err(CANCELLED);
        }
        let before = read_image(root)?;
        if before.is_none() && !matches!(action, Some(Change::Record(..))) {
            return Ok(Vec::new());
        }
        before
    };
    check()?;
    let mut store = if before.is_none() && matches!(action, Some(Change::Record(..))) {
        Store::initialize(root, backend).map_err(|_| KEY)?
    } else {
        Store::load(root, backend).map_err(|_| KEY)?
    };
    store
        .transaction(|owner| {
            Ok((|| -> Result<Vec<Entry>> {
                let library = Library::prepare(root.into())?;
                let _guard = library.lock()?;
                check()?;
                if read_image(root)? != before {
                    return Err(CANCELLED);
                }
                let preference = match &action {
                    Some(Change::Record(_, preference)) => Some(preference),
                    _ => None,
                };
                let verify = || -> Result<()> {
                    check()?;
                    if let Some(preference) = preference
                        && (!preference.enabled || Preference::read(root)? != *preference)
                    {
                        return Err(CANCELLED);
                    }
                    Ok(())
                };
                verify()?;
                let key = match owner.read(Slot::ClipboardHistory).map_err(|_| KEY)? {
                    Some(key) if key.len() == 32 => key,
                    None if before.is_none() && preference.is_some() => {
                        verify()?;
                        let material = Zeroizing::new(crypto::random::<32>()?);
                        let key = Zeroizing::new(material.to_vec());
                        owner
                            .replace(Slot::ClipboardHistory, None, Some(&key))
                            .map_err(|_| KEY)?;
                        key
                    }
                    _ => return Err(KEY),
                };
                verify()?;
                let entries = before
                    .as_deref()
                    .map(|image| open(image, &key))
                    .transpose()?
                    .unwrap_or_default();
                let retained = retaining(entries.clone(), now);
                let original = entries;
                let entries = match &action {
                    Some(Change::Record(text, _)) => recording(text.clone(), retained, now),
                    Some(Change::Delete(id)) => retained
                        .into_iter()
                        .filter(|entry| entry.id != *id)
                        .collect(),
                    None => retained,
                };
                if entries != original {
                    let image = seal(&entries, &key)?;
                    check()?;
                    // Revalidate saved consent after encryption, before any disk write.
                    if let Some(preference) = preference
                        && Preference::read(root)? != *preference
                    {
                        return Err(CANCELLED);
                    }
                    write_image(root, before.as_deref(), &image)?;
                }
                check()?;
                Ok(entries)
            })())
        })
        .map_err(|_| KEY)?
}
/// Explicit clear needs no decryption or keyring. It never creates storage.
pub fn clear(root: &Path, check: &dyn Fn() -> Result<()>) -> Result<()> {
    let library = Library::prepare(root.into())?;
    let _guard = library.lock()?;
    check()?;
    let path = directory(root)?;
    let image = path.join("history.bin");
    // Explicit deletion also works for a damaged or oversized regular image.
    // Open without following links, and never acquire or decrypt its contents.
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&image)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        _ => return Err(UNAVAILABLE),
    };
    let metadata = file.metadata().map_err(|_| UNAVAILABLE)?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(UNAVAILABLE);
    }
    check()?;
    let current = fs::symlink_metadata(&image).map_err(|_| UNAVAILABLE)?;
    if !current.is_file()
        || current.file_type().is_symlink()
        || current.dev() != metadata.dev()
        || current.ino() != metadata.ino()
        || current.nlink() != 1
        || current.uid() != metadata.uid()
        || current.permissions().mode() & 0o077 != 0
    {
        return Err(UNAVAILABLE);
    }
    fs::remove_file(image).map_err(|_| UNAVAILABLE)?;
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(|_| UNAVAILABLE)
}
#[cfg(test)]
#[path = "clipboard_history_tests.rs"]
mod tests;
