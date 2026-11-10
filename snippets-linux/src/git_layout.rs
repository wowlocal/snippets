//! The repository layout shared with the Apple apps, byte for byte:
//!
//! ```text
//! snippets-sync.json            manifest: format, schema, random dataset id
//! README.md                     explains the repository to a human browsing it
//! keys/recovery.json            library key sealed under the recovery code
//! records/<2 hex>/<uuid>.json   {"blob","deleted","id","rev"}: one wire record
//! snippets/<slug>-<8 hex>.md    plain-text libraries only: one ordinary snippet
//! ```
//!
//! Anything else in the tree is preserved on every commit. Record versions are
//! git blob ids; cursors name the dataset and the commit last fetched. The
//! manifest's `recordProfile` names the library's mode, fixed at creation.
use crate::{
    cloud::Binding,
    git_location::Remote,
    wire::{self, WireRecord},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub const MANIFEST: &str = "snippets-sync.json";
pub const README: &str = "README.md";
pub const RECORDS: &str = "records";
pub const KEYS: &str = "keys";
pub const RECOVERY_PATH: &str = "keys/recovery.json";
pub const FORMAT: &str = "snippets-git-sync";
pub const SCHEMA_VERSION: i64 = 1;
pub const RECORD_PROFILE: &str = "snippets-wire-v1";
pub const PLAIN_RECORD_PROFILE: &str = "snippets-plain-v1";
pub const MAX_REVISION_BYTES: usize = 256;
pub const MAX_MANIFEST_BYTES: usize = 16_384;
pub const MAX_RECORD_FILE_BYTES: usize = wire::MAX_BLOB_BYTES * 2;
pub const AUTHOR_NAME: &str = "Snippets Sync";
pub const AUTHOR_EMAIL: &str = "sync@snippets.invalid";
pub const CREATE_MESSAGE: &str = "Create Snippets library";
pub const RECOVERY_MESSAGE: &str = "Replace recovery envelope";

pub const README_TEXT: &str = "# Snippets library\n\nThis repository holds an end-to-end encrypted Snippets library. The Snippets apps read and write it directly over git; there is no Snippets server.\n\nEvery file under `records/` is ciphertext. Names, keywords, tags and bodies can be decrypted only on your own devices. `keys/recovery.json` holds the library key sealed under your offline recovery code; without that code it is useless.\n\nDo not edit, rebase, or force-push this branch by hand. Snippets treats a removed record or a replaced `snippets-sync.json` as a reset of the remote library and stops syncing until you review it on one of your devices.\n";

pub const PLAIN_README_TEXT: &str = "# Snippets library (plain text)\n\nThis repository holds a Snippets library. The Snippets apps read and write it directly over git; there is no Snippets server.\n\nOrdinary snippets are readable Markdown files directly in `snippets/`: a few lines of front matter (name, keyword, tags, enabled, pinned), then the snippet text. Edit them in any editor or on the web and the apps pick the change up on their next sync. Leave the `id` and `sync` lines alone. A copied file becomes a new snippet, a new Markdown file becomes a new snippet, and deleting a file deletes the snippet on every device. Files in subfolders are ignored, and restoring a deleted snippet's file from history does not bring it back; recreate it in the app.\n\nEverything stays in git history. A snippet that was ordinary once remains readable in old commits even after it is made secure or deleted.\n\nSecure snippets, deletions and snippets carrying sync bookkeeping (such as conflict copies) are encrypted under `records/`; only your own devices can open them. `keys/recovery.json` holds the library key sealed under your offline recovery code.\n\nDo not rebase or force-push this branch. Snippets treats a removed encrypted record or a replaced `snippets-sync.json` as a reset of the remote library and stops syncing until you review it on one of your devices.\n";

/// How a library stores its records, named by the manifest's `recordProfile`.
/// A profile this build does not know is refused, never misread.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    /// Every record is ciphertext under `records/`.
    #[default]
    Encrypted,
    /// Ordinary snippets are readable Markdown under `snippets/`; secure
    /// snippets and deletions stay ciphertext under `records/`.
    PlainText,
}
impl Mode {
    pub fn profile(self) -> &'static str {
        match self {
            Self::Encrypted => RECORD_PROFILE,
            Self::PlainText => PLAIN_RECORD_PROFILE,
        }
    }
    pub fn from_profile(profile: &str) -> Option<Self> {
        match profile {
            RECORD_PROFILE => Some(Self::Encrypted),
            PLAIN_RECORD_PROFILE => Some(Self::PlainText),
            _ => None,
        }
    }
    pub fn readme(self) -> &'static str {
        match self {
            Self::Encrypted => README_TEXT,
            Self::PlainText => PLAIN_README_TEXT,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LayoutError {
    /// The branch has no Snippets format marker: someone else's data.
    NotALibrary,
    /// The marker is present but the schema is not one this build writes.
    IncompatibleSchema,
    MalformedRecord,
}

pub fn sync_message(accepted: usize) -> String {
    if accepted == 1 {
        "Sync 1 record".into()
    } else {
        format!("Sync {accepted} records")
    }
}

/// Foundation's `[.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]`, plus "\n".
pub fn encode_manifest(dataset: Uuid, mode: Mode) -> Vec<u8> {
    format!(
        "{{\n  \"datasetID\" : \"{}\",\n  \"format\" : \"{FORMAT}\",\n  \"recordProfile\" : \"{}\",\n  \"schemaVersion\" : {SCHEMA_VERSION}\n}}\n",
        dataset.hyphenated(),
        mode.profile()
    )
    .into_bytes()
}
pub fn decode_manifest(bytes: &[u8]) -> Result<(Uuid, Mode), LayoutError> {
    let value: Option<serde_json::Value> = (bytes.len() <= MAX_MANIFEST_BYTES)
        .then(|| serde_json::from_slice(bytes).ok())
        .flatten();
    let Some(serde_json::Value::Object(object)) = value else {
        return Err(LayoutError::NotALibrary);
    };
    if object.get("format").and_then(|v| v.as_str()) != Some(FORMAT) {
        return Err(LayoutError::NotALibrary);
    }
    let keys = ["datasetID", "format", "recordProfile", "schemaVersion"];
    if object.len() != keys.len() || !keys.iter().all(|k| object.contains_key(*k)) {
        return Err(LayoutError::IncompatibleSchema);
    }
    let dataset = object["datasetID"].as_str();
    let id = dataset.and_then(|text| Uuid::parse_str(text).ok());
    let mode = object["recordProfile"]
        .as_str()
        .and_then(Mode::from_profile);
    match (id, dataset, mode) {
        (Some(id), Some(text), Some(mode))
            if object["schemaVersion"].as_i64() == Some(SCHEMA_VERSION)
                && object["schemaVersion"].is_i64()
                && id.hyphenated().to_string() == text =>
        {
            Ok((id, mode))
        }
        _ => Err(LayoutError::IncompatibleSchema),
    }
}

#[derive(serde::Serialize)]
struct RecordFile<'a> {
    blob: String,
    deleted: bool,
    id: String,
    rev: &'a str,
}
/// Canonical JSON with sorted keys and unescaped slashes, plus "\n", so an
/// identical record hashes to the same blob on every platform.
pub fn encode_record(record: &WireRecord) -> Vec<u8> {
    let mut bytes = serde_json::to_vec(&RecordFile {
        blob: STANDARD.encode(&record.blob),
        deleted: record.deleted,
        id: record.id.hyphenated().to_string(),
        rev: &record.rev,
    })
    .expect("string/bool fields always serialize");
    bytes.push(b'\n');
    bytes
}
pub fn decode_record(bytes: &[u8], id: Uuid) -> Result<WireRecord, LayoutError> {
    if bytes.len() > MAX_RECORD_FILE_BYTES {
        return Err(LayoutError::MalformedRecord);
    }
    let Ok(serde_json::Value::Object(object)) = serde_json::from_slice(bytes) else {
        return Err(LayoutError::MalformedRecord);
    };
    let keys = ["blob", "deleted", "id", "rev"];
    if object.len() != keys.len() || !keys.iter().all(|k| object.contains_key(*k)) {
        return Err(LayoutError::MalformedRecord);
    }
    let (Some(text), Some(deleted), Some(file_id), Some(rev)) = (
        object["blob"].as_str(),
        object["deleted"].as_bool(),
        object["id"].as_str(),
        object["rev"].as_str(),
    ) else {
        return Err(LayoutError::MalformedRecord);
    };
    if file_id != id.hyphenated().to_string()
        || !(1..=MAX_REVISION_BYTES).contains(&rev.len())
        || text.len() > wire::MAX_BLOB_BYTES.div_ceil(3) * 4
    {
        return Err(LayoutError::MalformedRecord);
    }
    let blob = STANDARD
        .decode(text)
        .map_err(|_| LayoutError::MalformedRecord)?;
    if STANDARD.encode(&blob) != text || blob.is_empty() || blob.len() > wire::MAX_BLOB_BYTES {
        return Err(LayoutError::MalformedRecord);
    }
    Ok(WireRecord {
        id,
        rev: rev.to_owned(),
        deleted,
        blob,
    })
}

/// `(fanout, file name)` for a record id.
pub fn record_path(id: Uuid) -> (String, String) {
    let text = id.hyphenated().to_string();
    (text[..2].to_owned(), format!("{text}.json"))
}
pub fn is_fanout_name(name: &[u8]) -> bool {
    name.len() == 2
        && name
            .iter()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
}
/// The id of `records/<prefix>/<name>`, or None for any other file name.
pub fn record_id(name: &[u8], prefix: &[u8]) -> Option<Uuid> {
    let text = std::str::from_utf8(name).ok()?.strip_suffix(".json")?;
    let id = Uuid::parse_str(text).ok()?;
    (id.hyphenated().to_string() == text && text.as_bytes().starts_with(prefix)).then_some(id)
}

/// `git-blob-sha1:<hex>`, the per-record CAS token.
pub fn record_version(blob: &str) -> String {
    format!("git-blob-sha1:{blob}")
}
/// `git-md-blob-sha1:<hex>`, the CAS token of a plain-text library's Markdown
/// file. The kind is in the token, so a version whose file is gone can be told
/// apart from a removed ciphertext record without the disposable cache.
pub fn markdown_version(blob: &str) -> String {
    format!("git-md-blob-sha1:{blob}")
}
/// The Markdown blob a version names, if it names one.
pub fn markdown_blob(version: &str) -> Option<&str> {
    version
        .strip_prefix("git-md-blob-sha1:")
        .filter(|blob| is_object_id(blob))
}
/// A Linux-only local token for a plain-text snippet whose Markdown file was
/// deleted by hand and whose tombstone is not in the repository yet (this
/// device could not record it). It names the deleted file's blob, never
/// leaves this device, and is treated like "no file" when writing.
pub fn absent_version(blob: &str) -> String {
    format!("git-absent-sha1:{blob}")
}
pub fn is_absent_version(version: &str) -> bool {
    version
        .strip_prefix("git-absent-sha1:")
        .is_some_and(is_object_id)
}
pub fn normalize_message(files: usize) -> String {
    format!("Normalize {files} file(s) edited outside Snippets")
}
pub fn is_object_id(text: &str) -> bool {
    text.len() == 40
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Where the engine stands in the remote history. `Complete` is the Apple
/// cursor format; `Partial` continues one bounded page sequence toward a
/// fixed target commit, from a base commit or from nothing (a full snapshot).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Position {
    Complete {
        dataset: Uuid,
        commit: String,
    },
    Partial {
        dataset: Uuid,
        target: String,
        base: Option<String>,
        offset: usize,
    },
}
impl Position {
    pub fn encode(&self) -> String {
        match self {
            Self::Complete { dataset, commit } => format!("git1.{}.{commit}", dataset.hyphenated()),
            Self::Partial {
                dataset,
                target,
                base,
                offset,
            } => format!(
                "git1p.{}.{target}.{}.{offset}",
                dataset.hyphenated(),
                base.as_deref().unwrap_or("full")
            ),
        }
    }
    pub fn decode(text: &str) -> Option<Self> {
        let parts: Vec<_> = text.split('.').collect();
        let dataset = |part: &str| {
            Uuid::parse_str(part)
                .ok()
                .filter(|id| id.hyphenated().to_string() == part)
        };
        match parts.as_slice() {
            ["git1", id, commit] if is_object_id(commit) => Some(Self::Complete {
                dataset: dataset(id)?,
                commit: (*commit).to_owned(),
            }),
            ["git1p", id, target, base, offset]
                if is_object_id(target)
                    && (is_object_id(base) || *base == "full")
                    && !offset.is_empty()
                    && offset.len() <= 6
                    && offset.bytes().all(|b| b.is_ascii_digit()) =>
            {
                let offset = offset.parse().ok().filter(|o| *o > 0)?;
                Some(Self::Partial {
                    dataset: dataset(id)?,
                    target: (*target).to_owned(),
                    base: (*base != "full").then(|| (*base).to_owned()),
                    offset,
                })
            }
            _ => None,
        }
    }
}

/// `SHA256("snippets-git-account-v1\n<location>\n<ref>")`, as on Apple.
pub fn account_digest(remote: &Remote) -> [u8; 32] {
    Sha256::digest(format!(
        "snippets-git-account-v1\n{}\n{}",
        remote.canonical_location(),
        remote.ref_name()
    ))
    .into()
}
/// `SHA256("snippets-git-dataset-v1\n<location>\n<ref>\n<dataset>")`, as on Apple.
pub fn dataset_digest(remote: &Remote, dataset: Uuid) -> [u8; 32] {
    Sha256::digest(format!(
        "snippets-git-dataset-v1\n{}\n{}\n{}",
        remote.canonical_location(),
        remote.ref_name(),
        dataset.hyphenated()
    ))
    .into()
}
/// The local checkpoint scope for one Git library.
pub fn checkpoint_scope(remote: &Remote, dataset: Uuid) -> crate::journal::Scope {
    crate::journal::Scope {
        membership: Binding::from_checkpoint(account_digest(remote)),
        dataset: Binding::from_checkpoint(dataset_digest(remote, dataset)),
    }
}
/// `git-library-v1-<first 16 bytes hex of SHA256("snippets-git-key-v1\n…")>`,
/// the Apple key-store account for this library's key.
pub fn key_scope(remote: &Remote, dataset: Uuid) -> String {
    let digest = Sha256::digest(format!(
        "snippets-git-key-v1\n{}\n{}\n{}",
        remote.canonical_location(),
        remote.ref_name(),
        dataset.hyphenated()
    ));
    let hex: String = digest[..16].iter().map(|b| format!("{b:02x}")).collect();
    format!("git-library-v1-{hex}")
}
