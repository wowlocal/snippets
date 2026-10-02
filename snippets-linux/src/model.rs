//! Portable ordinary-library format and durable transactions, independent of GTK.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashSet,
    env, fmt,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::{UnicodeNormalization, char::is_combining_mark};
use uuid::Uuid;

pub const MAX_FILE_BYTES: usize = 32 * 1024 * 1024;
pub const MAX_BODY_BYTES: usize = 256 * 1024;
pub const MAX_SNIPPETS: usize = 100_000;
pub(crate) const SWIFT_EPOCH: f64 = 978_307_200.0;

/// Only product-owned static messages can cross the UI/logging boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(pub &'static str);
impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}
impl std::error::Error for Error {}
pub type Result<T> = std::result::Result<T, Error>;

pub fn timestamp() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        - SWIFT_EPOCH
}
pub fn folded(value: &str) -> String {
    value
        .case_fold()
        .nfkd()
        .filter(|c| !is_combining_mark(*c))
        .collect()
}
pub fn keyword(value: &str) -> String {
    value
        .trim()
        .trim_start_matches('\\')
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
}
pub fn normalize_tags(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut seen = HashSet::new();
    values
        .into_iter()
        .map(|value| value.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|value| !value.is_empty() && seen.insert(folded(value)))
        .collect()
}
fn enabled_default() -> bool {
    true
}
pub(crate) fn serialize_id<S: serde::Serializer>(
    id: &Uuid,
    serializer: S,
) -> std::result::Result<S::Ok, S::Error> {
    serializer.serialize_str(&id.to_string().to_uppercase())
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snippet {
    #[serde(serialize_with = "serialize_id")]
    pub id: Uuid,
    pub name: String,
    pub keyword: String,
    pub content: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default = "enabled_default")]
    pub is_enabled: bool,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default = "timestamp")]
    pub created_at: f64,
    #[serde(default)]
    pub updated_at: f64,
}
impl Snippet {
    pub fn new(name: impl Into<String>, content: impl Into<String>) -> Self {
        let now = timestamp();
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            keyword: String::new(),
            content: content.into(),
            tags: Vec::new(),
            is_enabled: true,
            is_pinned: false,
            created_at: now,
            updated_at: now,
        }
    }
    pub fn validate(mut self) -> Result<Self> {
        if self.content.len() > MAX_BODY_BYTES
            || !self.created_at.is_finite()
            || !self.updated_at.is_finite()
            || [&self.name, &self.keyword, &self.content]
                .iter()
                .any(|s| s.contains('\0'))
            || self.tags.iter().any(|s| s.contains('\0'))
        {
            return Err(Error("The file contains an invalid or oversized snippet."));
        }
        self.keyword = keyword(&self.keyword);
        self.tags = normalize_tags(self.tags);
        Ok(self)
    }
    pub fn decode(value: Value) -> Result<Self> {
        if value
            .get("secure")
            .is_some_and(|v| v != &Value::Bool(false) && !v.is_null())
            || value
                .get("isSecure")
                .is_some_and(|v| v != &Value::Bool(false) && !v.is_null())
        {
            return Err(Error("Secure entries cannot be imported as ordinary text."));
        }
        let has_updated = value.get("updatedAt").is_some();
        let mut snippet: Self = serde_json::from_value(value)
            .map_err(|_| Error("The file contains an invalid or unsupported snippet."))?;
        if !has_updated {
            snippet.updated_at = snippet.created_at;
        }
        snippet.validate()
    }
    pub fn display_name(&self) -> String {
        if !self.name.trim().is_empty() {
            return self.name.clone();
        }
        self.content
            .lines()
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("Untitled Snippet")
            .chars()
            .take(100)
            .collect()
    }
}
pub fn decode_library(data: &[u8], importing: bool) -> Result<Vec<Snippet>> {
    if data.len() > MAX_FILE_BYTES {
        return Err(Error("The library exceeds the 32 MiB size limit."));
    }
    let mut document: Value =
        serde_json::from_slice(data).map_err(|_| Error("The file is not valid Snippets JSON."))?;
    if document.is_object() {
        document = document.get("snippets").cloned().unwrap_or(Value::Null);
    }
    let values = document
        .as_array()
        .filter(|v| v.len() <= MAX_SNIPPETS)
        .ok_or(Error("Choose a Snippets or Raycast JSON export."))?;
    let raycast = importing
        && !values.is_empty()
        && values
            .iter()
            .all(|v| v.get("text").is_some() && v.get("id").is_none());
    let mut seen = HashSet::new();
    let pattern =
        regex::Regex::new(r#"\{(date|time|datetime) "([^"{}]+)"\}"#).expect("static pattern");
    values
        .iter()
        .map(|v| {
            let snippet = if raycast {
                let name = v
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or(Error("The Raycast export contains an invalid snippet."))?;
                let text = v
                    .get("text")
                    .and_then(Value::as_str)
                    .ok_or(Error("The Raycast export contains an invalid snippet."))?;
                let raw_keyword = match v.get("keyword") {
                    Some(value) => value
                        .as_str()
                        .ok_or(Error("The Raycast export contains an invalid keyword."))?,
                    None => "",
                };
                let mut snippet =
                    Snippet::new(name, pattern.replace_all(text, r#"{$1 format="$2"}"#));
                snippet.keyword = keyword(raw_keyword).trim_start_matches('!').into();
                snippet.validate()?
            } else {
                Snippet::decode(v.clone())?
            };
            if !seen.insert(snippet.id) {
                return Err(Error("The file contains duplicate snippet identifiers."));
            }
            Ok(snippet)
        })
        .collect()
}
pub fn encode_library(snippets: &[Snippet], wrapped: bool) -> Result<Vec<u8>> {
    if snippets.len() > MAX_SNIPPETS {
        return Err(Error("The library exceeds the snippet count limit."));
    }
    let value =
        serde_json::to_value(snippets).map_err(|_| Error("The library contains invalid data."))?;
    let data = serde_json::to_vec_pretty(&if wrapped {
        serde_json::json!({"snippets": value})
    } else {
        value
    })
    .map_err(|_| Error("The library contains invalid data."))?;
    if data.len() > MAX_FILE_BYTES {
        return Err(Error("The library exceeds the 32 MiB size limit."));
    }
    Ok(data)
}
fn subsequence(query: &str, text: &str) -> bool {
    let mut letters = text.chars();
    query
        .chars()
        .all(|letter| letters.by_ref().any(|candidate| candidate == letter))
}
pub fn search(
    snippets: &[Snippet],
    query: &str,
    tags: &[String],
    pinned: bool,
    enabled_only: bool,
) -> Vec<Snippet> {
    let query = folded(query);
    let tags: Vec<_> = tags.iter().map(|t| folded(t)).collect();
    let mut result: Vec<_> = snippets
        .iter()
        .filter(|s| {
            if pinned && !s.is_pinned || enabled_only && !s.is_enabled {
                return false;
            }
            if !tags
                .iter()
                .all(|t| s.tags.iter().any(|candidate| folded(candidate) == *t))
            {
                return false;
            }
            let mut metadata = vec![folded(&s.name), folded(&s.keyword)];
            metadata.extend(s.tags.iter().map(|t| folded(t)));
            let body = folded(&s.content);
            query.split_whitespace().all(|word| {
                body.contains(word) || metadata.iter().any(|text| subsequence(word, text))
            })
        })
        .cloned()
        .collect();
    result.sort_by(|a, b| {
        b.is_pinned
            .cmp(&a.is_pinned)
            .then(b.created_at.total_cmp(&a.created_at))
            .then(a.id.cmp(&b.id))
    });
    result
}
pub fn default_root() -> Result<PathBuf> {
    if let Some(path) = env::var_os("SNIPPETS_SUPPORT_DIR").filter(|v| !v.is_empty()) {
        return Ok(path.into());
    }
    let data = env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|v| PathBuf::from(v).join(".local/share")))
        .ok_or(Error("The Snippets data directory is unavailable."))?;
    Ok(data.join("snippets"))
}
pub fn read_regular(path: &Path) -> Result<Option<Vec<u8>>> {
    read_regular_bounded(path, MAX_FILE_BYTES)
}
pub(crate) fn read_regular_bounded(path: &Path, limit: usize) -> Result<Option<Vec<u8>>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Error("The file could not be read safely.")),
    };
    let info = file
        .metadata()
        .map_err(|_| Error("The file could not be read safely."))?;
    if !info.is_file() || info.len() > limit as u64 {
        return Err(Error("Choose a regular file smaller than 32 MiB."));
    }
    let mut data = Vec::new();
    file.take(limit as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|_| Error("The file could not be read safely."))?;
    if data.len() > limit {
        return Err(Error("The library exceeds the 32 MiB size limit."));
    }
    Ok(Some(data))
}
pub fn atomic_write(path: &Path, data: &[u8]) -> Result<()> {
    if fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(Error("Linked library files are not supported."));
    }
    let write = || -> std::io::Result<()> {
        let parent = path
            .parent()
            .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        let mut temporary = tempfile::Builder::new()
            .prefix(".snippets-")
            .tempfile_in(parent)?;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))?;
        temporary.write_all(data)?;
        temporary.as_file().sync_all()?;
        temporary.persist(path).map_err(|e| e.error)?;
        File::open(parent)?.sync_all()
    };
    write().map_err(|_| Error("The library could not be durably saved. Reload it before retrying."))
}

pub struct Library {
    pub root: PathBuf,
    pub snippets: Vec<Snippet>,
    snapshot: Vec<u8>,
    undo: Vec<(Vec<u8>, Vec<u8>)>,
    redo: Vec<(Vec<u8>, Vec<u8>)>,
}
impl Library {
    pub fn open(root: PathBuf) -> Result<Self> {
        let mut library = Self::prepare(root)?;
        library.reload()?;
        Ok(library)
    }
    /// Open a workspace without reading mixed primary files after an interrupted
    /// apply. RecoveryRequired is an unavailable library, not an empty one.
    pub fn open_recoverable(root: PathBuf) -> Result<(Self, crate::primary::Readiness)> {
        let mut library = Self::prepare(root)?;
        let _guard = library.lock()?;
        let readiness = crate::primary::readiness(&library.root)?;
        if readiness == crate::primary::Readiness::Ready {
            library.reload_catalogue_locked()?;
        }
        Ok((library, readiness))
    }
    pub fn readiness(&self) -> Result<crate::primary::Readiness> {
        let _guard = self.lock()?;
        crate::primary::readiness(&self.root)
    }
    /// Recovery opens the root/lock before reading any mixed primary files.
    pub(crate) fn prepare(root: PathBuf) -> Result<Self> {
        if fs::symlink_metadata(&root).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(Error("Linked data directories are not supported."));
        }
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&root)
            .and_then(|_| fs::set_permissions(&root, fs::Permissions::from_mode(0o700)))
            .map_err(|_| Error("The Snippets data directory is unavailable."))?;
        let library = Self {
            root,
            snippets: vec![],
            snapshot: vec![],
            undo: vec![],
            redo: vec![],
        };
        Ok(library)
    }
    pub fn path(&self) -> PathBuf {
        self.root.join("snippets.json")
    }
    pub fn lock(&self) -> Result<File> {
        Self::lock_root(&self.root)
    }
    pub(crate) fn lock_root(root: &Path) -> Result<File> {
        let file = Self::open_lock(root)?;
        file.lock()
            .map_err(|_| Error("The library lock is unavailable."))?;
        Ok(file)
    }
    /// Short-lived input preparation must never wait with a fresh vault key.
    #[cfg(any(test, feature = "desktop"))]
    pub(crate) fn try_lock(&self) -> Result<File> {
        let file = Self::open_lock(&self.root)?;
        file.try_lock().map_err(|error| match error {
            std::fs::TryLockError::WouldBlock => Error(
                "The library is busy. Try the action again after the current operation finishes.",
            ),
            std::fs::TryLockError::Error(_) => Error("The library lock is unavailable."),
        })?;
        Ok(file)
    }
    fn open_lock(root: &Path) -> Result<File> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(root.join("library.lock"))
            .map_err(|_| Error("The library lock is unavailable."))?;
        if !file.metadata().is_ok_and(|m| m.is_file()) {
            return Err(Error("The library lock is invalid."));
        }
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|_| Error("The library lock is unavailable."))?;
        Ok(file)
    }
    pub fn read(&self) -> Result<(Vec<Snippet>, Vec<u8>)> {
        let _guard = self.lock()?;
        self.read_locked()
    }
    /// Caller holds this root's common process lock.
    pub(crate) fn read_locked(&self) -> Result<(Vec<Snippet>, Vec<u8>)> {
        crate::primary::require_ready(&self.root)?;
        let data = read_regular(&self.path())?.unwrap_or_else(|| b"[]".to_vec());
        Ok((decode_library(&data, false)?, data))
    }
    pub fn reload(&mut self) -> Result<bool> {
        let _guard = self.lock()?;
        self.reload_locked()
    }
    fn reload_locked(&mut self) -> Result<bool> {
        let (snippets, data) = self.read_locked()?;
        Ok(self.install_snapshot(snippets, data))
    }
    /// Validate both primary files before making a recovered workspace editable.
    pub fn reload_catalogue(&mut self) -> Result<bool> {
        let _guard = self.lock()?;
        self.reload_catalogue_locked()
    }
    fn reload_catalogue_locked(&mut self) -> Result<bool> {
        let (snippets, data) = self.read_locked()?;
        self.secure_metadata_locked()?;
        Ok(self.install_snapshot(snippets, data))
    }
    fn install_snapshot(&mut self, snippets: Vec<Snippet>, data: Vec<u8>) -> bool {
        let changed = data != self.snapshot;
        self.snippets = snippets;
        self.snapshot = data;
        changed
    }
    pub fn get(&self, id: Uuid) -> Option<Snippet> {
        self.snippets.iter().find(|s| s.id == id).cloned()
    }
    /// Reserve locked-vault metadata too. Malformed vaults fail closed.
    fn reserved_locked(&self) -> Result<Vec<Snippet>> {
        Ok(self
            .secure_metadata_locked()?
            .iter()
            .map(crate::vault::Metadata::shell)
            .collect())
    }
    pub fn secure_metadata(&self) -> Result<Vec<crate::vault::Metadata>> {
        let _guard = self.lock()?;
        self.secure_metadata_locked()
    }
    fn secure_metadata_locked(&self) -> Result<Vec<crate::vault::Metadata>> {
        Ok(crate::vault::read_document_locked(&self.root)?
            .map(|d| d.metadata())
            .unwrap_or_default())
    }
    /// Fresh ordinary content and locked-vault metadata from one primary generation.
    pub fn catalogue(&self) -> Result<(Vec<Snippet>, Vec<crate::vault::Metadata>)> {
        let _guard = self.lock()?;
        Ok((self.read_locked()?.0, self.secure_metadata_locked()?))
    }
    fn transaction(
        &mut self,
        operation: impl FnOnce(&mut Vec<Snippet>, &[Snippet]) -> Result<()>,
    ) -> Result<()> {
        let _guard = self.lock()?;
        let (mut snippets, before) = self.read_locked()?;
        operation(&mut snippets, &self.reserved_locked()?)?;
        let after = encode_library(&snippets, false)?;
        if before != after {
            atomic_write(&self.path(), &after)?;
            self.undo.push((before, after));
            while self.undo.len() > 50
                || self
                    .undo
                    .iter()
                    .map(|(a, b)| a.len() + b.len())
                    .sum::<usize>()
                    > 64 * 1024 * 1024
            {
                self.undo.remove(0);
            }
            self.redo.clear();
        }
        self.reload_locked()?;
        Ok(())
    }
    pub fn save(&mut self, snippet: Snippet, expected: Option<&Snippet>) -> Result<()> {
        let mut snippet = snippet.validate()?;
        self.transaction(|current, reserved| {
            if current.iter().find(|s| s.id == snippet.id) != expected {
                return Err(Error(
                    "This entry changed outside the editor. Reload it before saving.",
                ));
            }
            if reserved.iter().any(|s| s.id == snippet.id) {
                return Err(Error("This identifier belongs to a secure entry."));
            }
            if !snippet.keyword.is_empty()
                && current
                    .iter()
                    .chain(reserved)
                    .any(|s| s.id != snippet.id && folded(&s.keyword) == folded(&snippet.keyword))
            {
                return Err(Error("This keyword already belongs to another snippet."));
            }
            snippet.updated_at = timestamp();
            if let Some(previous) = current.iter_mut().find(|s| s.id == snippet.id) {
                *previous = snippet;
            } else {
                current.push(snippet);
            }
            Ok(())
        })
    }
    pub fn delete(&mut self, snippet: &Snippet) -> Result<()> {
        self.transaction(|current, _| {
            if current.iter().find(|s| s.id == snippet.id) != Some(snippet) {
                return Err(Error(
                    "This entry changed outside the editor. Reload it before deleting.",
                ));
            }
            current.retain(|s| s.id != snippet.id);
            Ok(())
        })
    }
    pub fn import(&mut self, data: &[u8]) -> Result<(usize, usize)> {
        let incoming = decode_library(data, true)?;
        let (mut added, mut skipped) = (0, 0);
        self.transaction(|current, reserved| {
            let mut ids: HashSet<_> = current.iter().chain(reserved).map(|s| s.id).collect();
            let mut keywords: HashSet<_> = current
                .iter()
                .chain(reserved)
                .filter(|s| !s.keyword.is_empty())
                .map(|s| folded(&s.keyword))
                .collect();
            for snippet in incoming {
                if ids.contains(&snippet.id)
                    || !snippet.keyword.is_empty() && keywords.contains(&folded(&snippet.keyword))
                {
                    skipped += 1;
                    continue;
                }
                ids.insert(snippet.id);
                if !snippet.keyword.is_empty() {
                    keywords.insert(folded(&snippet.keyword));
                }
                current.push(snippet);
                added += 1;
            }
            Ok(())
        })?;
        Ok((added, skipped))
    }
    pub fn undo(&mut self, redo: bool) -> Result<()> {
        let source = if redo { &self.redo } else { &self.undo };
        let Some((before, after)) = source.last().cloned() else {
            return Ok(());
        };
        let (expected, desired) = if redo {
            (&before, &after)
        } else {
            (&after, &before)
        };
        let _guard = self.lock()?;
        if self.read_locked()?.1 != *expected {
            return Err(Error(
                "The library changed outside Snippets. Undo would overwrite those changes.",
            ));
        }
        // A vault created since the original transaction can reserve an old ID/keyword.
        let reserved = self.reserved_locked()?;
        if decode_library(desired, false)?.iter().any(|s| {
            reserved.iter().any(|r| {
                r.id == s.id || !s.keyword.is_empty() && folded(&r.keyword) == folded(&s.keyword)
            })
        }) {
            return Err(Error("Undo would conflict with a secure entry."));
        }
        atomic_write(&self.path(), desired)?;
        if redo {
            self.redo.pop();
            self.undo.push((before, after));
        } else {
            self.undo.pop();
            self.redo.push((before, after));
        }
        self.reload_locked()?;
        Ok(())
    }
}
