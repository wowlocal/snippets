//! Reviewed portable-backup merge and password-owned, encrypted two-file redo.
//! No cloud checkpoint or persistent copy of a vault key is created.
use super::*;
use crate::{clock, model::Library};
use std::{
    collections::HashMap,
    fs,
    os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
};
use uuid::Uuid;

const DIRECTORY: &str = "Backups";
const PENDING: &str = "restore.pending";
const IDENTITY: &str = "identity.bin";
const INVALID_REDO: Error =
    Error("Backup recovery storage is invalid. The library remains unavailable.");
const RECOVERY: Error = Error(
    "An interrupted backup import needs recovery with its backup password before reading or editing.",
);
const CHANGED: Error = Error("The saved library changed. Review the backup import again.");
const INCOMPATIBLE: Error =
    Error("The backup's secure snippets belong to a different vault. Nothing was imported.");
const COLLISION: Error =
    Error("The backup conflicts with existing identifiers or keywords. Nothing was imported.");
const MAX_HEADER: usize = 4096;
const MAX_REDO: usize = crypto::MAX_CHECKPOINT_BYTES + MAX_HEADER + 40;

fn directory(root: &Path) -> Result<bool> {
    match fs::symlink_metadata(root.join(DIRECTORY)) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Ok(metadata)
            if metadata.is_dir()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0 =>
        {
            Ok(true)
        }
        _ => Err(INVALID_REDO),
    }
}
fn private_file(path: &Path, limit: usize) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Ok(metadata)
            if metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.nlink() == 1
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0
                && metadata.len() <= limit as u64 =>
        {
            Ok(true)
        }
        _ => Err(INVALID_REDO),
    }
}
/// Metadata-only fence, before either primary file is read.
pub(crate) fn pending(root: &Path) -> Result<bool> {
    if !directory(root)? {
        return Ok(false);
    }
    private_file(&root.join(DIRECTORY).join(PENDING), MAX_REDO)
}
pub(crate) fn require_clear(root: &Path) -> Result<()> {
    if pending(root)? {
        Err(RECOVERY)
    } else {
        Ok(())
    }
}
fn identity(root: &Path, create: bool) -> Result<[u8; 32]> {
    if !directory(root)? {
        if !create {
            return Err(INVALID_REDO);
        }
        fs::DirBuilder::new()
            .mode(0o700)
            .create(root.join(DIRECTORY))
            .map_err(|_| INVALID_REDO)?;
        fs::File::open(root)
            .and_then(|file| file.sync_all())
            .map_err(|_| INVALID_REDO)?;
    }
    let path = root.join(DIRECTORY).join(IDENTITY);
    if !private_file(&path, 32)? {
        if !create {
            return Err(INVALID_REDO);
        }
        model::atomic_write(&path, &crypto::random::<32>()?)?;
    }
    model::read_regular_bounded(&path, 32)?
        .ok_or(INVALID_REDO)?
        .try_into()
        .map_err(|_| INVALID_REDO)
}
fn check_vault_directory(root: &Path) -> Result<()> {
    match fs::symlink_metadata(root.join("Vault")) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => Ok(()),
        _ => Err(Error("The vault directory could not be accessed safely.")),
    }
}
#[derive(PartialEq)]
struct Images {
    plain: Option<Zeroizing<Vec<u8>>>,
    vault: Option<Zeroizing<Vec<u8>>>,
}
impl Images {
    fn read(root: &Path) -> Result<Self> {
        check_vault_directory(root)?;
        Ok(Self {
            plain: model::read_regular(&root.join("snippets.json"))?.map(Zeroizing::new),
            vault: model::read_regular(&root.join("Vault/vault.json"))?.map(Zeroizing::new),
        })
    }
    fn parsed(&self) -> Result<(Vec<Snippet>, Option<Document>)> {
        let snippets = model::decode_library(self.plain.as_deref().map_or(b"[]", |v| v), false)?;
        let vault = self
            .vault
            .as_deref()
            .map(|v| Document::decode(v))
            .transpose()?;
        validate(&snippets, vault.as_ref().filter(|v| !v.records.is_empty()))?;
        Ok((snippets, vault))
    }
    fn allowed(&self, before: &Self, after: &Self) -> bool {
        (self.plain == before.plain || self.plain == after.plain)
            && (self.vault == before.vault || self.vault == after.vault)
    }
}
fn key(keyword: &str) -> String {
    model::folded(&model::keyword(keyword))
}
fn same_record(first: &crate::vault::Record, second: &crate::vault::Record) -> bool {
    let mut metadata = first.metadata.clone();
    metadata.updated_at = second.metadata.updated_at;
    metadata == second.metadata
        && first.sealed == second.sealed
        && first.content_hash == second.content_hash
        && first.extra == second.extra
}
/// This owner retains the authenticated incoming vault key only until fresh
/// local-vault authentication. It cannot be serialized or cloned.
pub struct Review {
    root: PathBuf,
    before: Images,
    snippets: Vec<Snippet>,
    vault: Option<Document>,
    current_vault: Option<Document>,
    incoming_key: Option<RootKey>,
    stamp: Vec<(usize, Option<clock::Hlc>)>,
    counts: (usize, usize),
}
impl Review {
    pub fn prepare(library: &Library, mut opened: Opened) -> Result<Self> {
        validate(&opened.snippets, opened.vault.as_ref())?;
        match (&opened.vault, &opened.vault_key) {
            (Some(vault), Some(root)) => {
                for record in &vault.records {
                    let body = crypto::open_record(
                        &record.sealed,
                        root,
                        &vault.salt()?,
                        &vault.kid,
                        record.metadata.id,
                        false,
                    )?;
                    crypto::verify_hash(&record.content_hash, &body, root, &vault.salt()?)?;
                }
            }
            (None, None) => (),
            _ => return Err(INCOMPATIBLE),
        }
        let _guard = library.lock()?;
        crate::primary::require_ready(&library.root)?;
        let before = Images::read(&library.root)?;
        let (mut snippets, current) = before.parsed()?;
        let counts = opened.counts();
        let incoming = opened.vault.take().map(|v| portable(&v));
        if let (Some(existing), Some(incoming)) = (&current, &incoming)
            && (existing.schema_version != incoming.schema_version
                || existing.kid != incoming.kid
                || existing.salt()? != incoming.salt()?)
        {
            return Err(INCOMPATIBLE);
        }
        let secure = current.as_ref().map_or(&[][..], |v| v.records.as_slice());
        let mut plain_ids: HashMap<_, _> = snippets
            .iter()
            .enumerate()
            .map(|(index, row)| (row.id, index))
            .collect();
        let mut plain_keywords: HashMap<_, _> = snippets
            .iter()
            .enumerate()
            .filter(|(_, row)| !row.keyword.is_empty())
            .map(|(index, row)| (key(&row.keyword), index))
            .collect();
        let secure_ids: HashSet<_> = secure.iter().map(|row| row.metadata.id).collect();
        let secure_keywords: HashMap<_, _> = secure
            .iter()
            .filter(|row| !row.metadata.keyword.is_empty())
            .map(|row| (key(&row.metadata.keyword), row.metadata.id))
            .collect();
        // Check against the entire original view before upserting anything.
        for incoming in &opened.snippets {
            let keyword = key(&incoming.keyword);
            if secure_ids.contains(&incoming.id)
                || !keyword.is_empty() && secure_keywords.contains_key(&keyword)
                || !keyword.is_empty()
                    && plain_ids.contains_key(&incoming.id)
                    && plain_keywords
                        .get(&keyword)
                        .is_some_and(|index| snippets[*index].id != incoming.id)
            {
                return Err(COLLISION);
            }
        }
        for incoming in incoming.iter().flat_map(|v| &v.records) {
            let keyword = key(&incoming.metadata.keyword);
            if plain_ids.contains_key(&incoming.metadata.id)
                || !keyword.is_empty() && plain_keywords.contains_key(&keyword)
                || !keyword.is_empty()
                    && secure_keywords
                        .get(&keyword)
                        .is_some_and(|id| *id != incoming.metadata.id)
            {
                return Err(COLLISION);
            }
        }
        let old_length = snippets.len();
        for mut incoming in opened.snippets {
            let keyword = key(&incoming.keyword);
            let by_id = plain_ids.get(&incoming.id).copied();
            let position = by_id.or_else(|| {
                (!keyword.is_empty())
                    .then(|| plain_keywords.get(&keyword).copied())
                    .flatten()
            });
            if let Some(index) = position {
                let existing = &snippets[index];
                if by_id.is_none() {
                    incoming.id = existing.id;
                    incoming.created_at = existing.created_at;
                }
                incoming.updated_at = incoming.updated_at.max(incoming.created_at);
                plain_keywords.remove(&key(&existing.keyword));
                if !keyword.is_empty() {
                    plain_keywords.insert(keyword, index);
                }
                snippets[index] = incoming;
            } else {
                let index = snippets.len();
                plain_ids.insert(incoming.id, index);
                if !keyword.is_empty() {
                    plain_keywords.insert(keyword, index);
                }
                snippets.push(incoming);
            }
        }
        // New rows have the same order as repeated front insertion, without
        // shifting the entire current library for every incoming row.
        let added = snippets.len() - old_length;
        snippets[old_length..].reverse();
        snippets.rotate_right(added);
        let mut stamp = Vec::new();
        let vault = match (current.as_ref(), incoming) {
            (None, incoming) => incoming,
            (Some(existing), None) => Some(existing.clone()),
            (Some(existing), Some(incoming)) => {
                let mut merged = existing.clone();
                if merged.wrap_recovery.is_none() {
                    merged.wrap_recovery = incoming.wrap_recovery;
                }
                for (name, value) in incoming.extra {
                    merged.extra.entry(name).or_insert(value);
                }
                let now = chrono::Utc::now();
                let mut indices: HashMap<_, _> = merged
                    .records
                    .iter()
                    .enumerate()
                    .map(|(index, record)| (record.metadata.id, index))
                    .collect();
                for mut record in incoming.records {
                    if let Some(index) = indices.get(&record.metadata.id).copied() {
                        let existing = &mut merged.records[index];
                        if same_record(existing, &record) {
                            continue;
                        }
                        let base = existing.hlc.clone().max(record.hlc.clone());
                        record.metadata.updated_at = now.max(record.metadata.updated_at);
                        stamp.push((index, base));
                        *existing = record;
                    } else {
                        record.metadata.updated_at = now.max(record.metadata.updated_at);
                        let index = merged.records.len();
                        indices.insert(record.metadata.id, index);
                        stamp.push((index, record.hlc.clone()));
                        merged.records.push(record);
                    }
                }
                Some(merged)
            }
        };
        validate(&snippets, vault.as_ref().filter(|v| !v.records.is_empty()))?;
        Ok(Self {
            root: library.root.clone(),
            before,
            snippets,
            vault,
            current_vault: incoming_key_current(&current, opened.vault_key.as_ref()),
            incoming_key: opened.vault_key,
            stamp,
            counts,
        })
    }
    pub fn counts(&self) -> (usize, usize) {
        self.counts
    }
    pub fn needs_vault(&self) -> bool {
        self.current_vault.is_some()
    }
    pub fn has_passphrase(&self) -> bool {
        self.current_vault
            .as_ref()
            .is_some_and(|v| v.wrap_pass.is_some())
    }
    pub fn needs_new_passphrase(&self) -> bool {
        self.incoming_key.is_some() && self.current_vault.is_none()
    }
    pub fn commit(
        self,
        library: &Library,
        backup_password: &str,
        credential: Option<(&str, bool)>,
        new_passphrase: Option<&str>,
        check: &dyn Fn() -> Result<()>,
    ) -> Result<(usize, usize)> {
        self.commit_inner(
            library,
            backup_password,
            credential,
            new_passphrase,
            check,
            crypto::PASSPHRASE_ITERATIONS,
            None,
        )
    }
    #[allow(clippy::too_many_arguments)]
    fn commit_inner(
        mut self,
        library: &Library,
        backup_password: &str,
        credential: Option<(&str, bool)>,
        new_passphrase: Option<&str>,
        check: &dyn Fn() -> Result<()>,
        iterations: u32,
        fault: Option<u8>,
    ) -> Result<(usize, usize)> {
        check()?;
        if self.root != library.root {
            return Err(CHANGED);
        }
        if let Some(current) = &self.current_vault {
            let (text, recovery) = credential.ok_or(Error(
                "Authenticate the current vault before importing secure snippets.",
            ))?;
            current.with_backup_key(text, recovery, |root| {
                check()?;
                if !root.same_key(self.incoming_key.as_ref().ok_or(INCOMPATIBLE)?) {
                    return Err(INCOMPATIBLE);
                }
                Ok(())
            })?;
        }
        if self.needs_new_passphrase() {
            let text =
                new_passphrase.ok_or(Error("Choose a local passphrase for the restored vault."))?;
            if text.chars().count() < 12 || text.len() > 4096 {
                return Err(Error(
                    "Choose a vault passphrase of at least 12 characters and no more than 4 KiB.",
                ));
            }
            let vault = self.vault.as_mut().ok_or(INCOMPATIBLE)?;
            let (parameters, wrap) = crypto::wrap_passphrase_cost(
                self.incoming_key.as_ref().ok_or(INCOMPATIBLE)?,
                text,
                &vault.kid,
                iterations,
            )?;
            check()?;
            vault.kdf = parameters;
            vault.wrap_pass = Some(wrap);
        } else if new_passphrase.is_some() {
            return Err(Error(
                "Existing vault unlock methods are preserved. Change its passphrase separately.",
            ));
        }
        // No vault key survives into redo encryption or file publication.
        self.incoming_key.take();
        let (root_identity, after) = {
            let _guard = library.lock()?;
            check()?;
            crate::primary::require_ready(&library.root)?;
            if Images::read(&library.root)? != self.before {
                return Err(CHANGED);
            }
            if let Some(vault) = &mut self.vault {
                let requests = self
                    .stamp
                    .iter()
                    .map(|(index, base)| {
                        let record = vault.records.get(*index).ok_or(INVALID_REDO)?;
                        Ok((
                            base.as_ref(),
                            record.metadata.updated_at.timestamp_millis().max(0) as u64,
                        ))
                    })
                    .collect::<Result<Vec<_>>>()?;
                let clocks = clock::stamp_many(&library.root, &requests)?;
                for ((index, _), clock) in self.stamp.iter().zip(clocks) {
                    vault.records[*index].hlc = Some(clock);
                }
            }
            let (old_plain, old_vault) = self.before.parsed()?;
            let plain = if self.snippets == old_plain {
                self.before.plain.clone()
            } else {
                Some(Zeroizing::new(model::encode_library(
                    &self.snippets,
                    false,
                )?))
            };
            let vault = if self.vault == old_vault {
                self.before.vault.clone()
            } else {
                self.vault
                    .as_ref()
                    .map(|v| v.encode().map(Zeroizing::new))
                    .transpose()?
            };
            let after = Images { plain, vault };
            if after == self.before {
                return Ok(self.counts);
            }
            check()?;
            (identity(&library.root, true)?, after)
        };
        let intent = Intent {
            identity: root_identity,
            before: self.before,
            after,
        };
        let bytes = intent.seal(backup_password, iterations)?;
        check()?;
        let _guard = library.lock()?;
        check()?;
        crate::primary::require_ready(&library.root)?;
        if Images::read(&library.root)? != intent.before
            || identity(&library.root, false)? != intent.identity
        {
            return Err(CHANGED);
        }
        check()?;
        // A durable encrypted intent is the fence itself; no pre-WAL marker
        // can strand a library without the recovery material.
        model::atomic_write(&library.root.join(DIRECTORY).join(PENDING), &bytes)?;
        if fault == Some(0) {
            return Err(RECOVERY);
        }
        intent.finish(library, check, fault)?;
        Ok(self.counts)
    }
}
fn incoming_key_current(current: &Option<Document>, key: Option<&RootKey>) -> Option<Document> {
    key.and(current.as_ref()).cloned()
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u8,
    id: String,
    kdf: KdfParameters,
    wrap: String,
    salt: String,
}
struct Intent {
    identity: [u8; 32],
    before: Images,
    after: Images,
}
fn frame(out: &mut Vec<u8>, data: Option<&[u8]>) {
    out.extend_from_slice(&data.map_or(u64::MAX, |v| v.len() as u64).to_be_bytes());
    if let Some(data) = data {
        out.extend_from_slice(data);
    }
}
struct Decoder<'a>(&'a [u8]);
impl<'a> Decoder<'a> {
    fn take(&mut self, count: usize) -> Result<&'a [u8]> {
        let (first, rest) = self.0.split_at_checked(count).ok_or(INVALID_REDO)?;
        self.0 = rest;
        Ok(first)
    }
    fn frame(&mut self, limit: usize) -> Result<Option<&'a [u8]>> {
        let length = u64::from_be_bytes(self.take(8)?.try_into().map_err(|_| INVALID_REDO)?);
        if length == u64::MAX {
            return Ok(None);
        }
        if length > limit as u64 {
            return Err(INVALID_REDO);
        }
        Ok(Some(self.take(length as usize)?))
    }
    fn images(&mut self) -> Result<Images> {
        Ok(Images {
            plain: self
                .frame(model::MAX_FILE_BYTES)?
                .map(|v| Zeroizing::new(v.to_vec())),
            vault: self
                .frame(model::MAX_FILE_BYTES)?
                .map(|v| Zeroizing::new(v.to_vec())),
        })
    }
}
impl Intent {
    fn validate(&self) -> Result<()> {
        let (_, before_vault) = self.before.parsed()?;
        let (_, after_vault) = self.after.parsed()?;
        if self.before.plain.is_some() && self.after.plain.is_none()
            || self.before.vault.is_some() && self.after.vault.is_none()
        {
            return Err(INVALID_REDO);
        }
        if let (Some(mut before), Some(mut after)) = (before_vault, after_vault) {
            before.records.clear();
            after.records.clear();
            // Existing doors and local receipts remain owned by this install.
            if before.wrap_recovery.is_none() {
                after.wrap_recovery = None;
            }
            after.extra.retain(|key, _| before.extra.contains_key(key));
            if before != after {
                return Err(INVALID_REDO);
            }
        }
        Ok(())
    }
    fn seal(&self, password: &str, iterations: u32) -> Result<Vec<u8>> {
        self.validate()?;
        if password.is_empty() || password.len() > 4096 {
            return Err(Error("Enter the backup password no larger than 4 KiB."));
        }
        let root = RootKey::generate()?;
        let id = format!("r-{}", Uuid::new_v4());
        let (kdf, wrap) = crypto::wrap_passphrase_cost(&root, password, &id, iterations)?;
        let salt = crypto::random::<32>()?;
        let header = serde_json::to_vec(&Header {
            version: 1,
            id,
            kdf,
            wrap: wrap.text().into(),
            salt: crypto::b64(&salt),
        })
        .map_err(|_| INVALID_REDO)?;
        if header.len() > MAX_HEADER {
            return Err(INVALID_REDO);
        }
        let mut plain = Zeroizing::new(b"BRI1".to_vec());
        frame(&mut plain, Some(&header));
        plain.extend_from_slice(&self.identity);
        for image in [
            &self.before.plain,
            &self.before.vault,
            &self.after.plain,
            &self.after.vault,
        ] {
            frame(&mut plain, image.as_deref().map(|v| v.as_slice()));
        }
        let payload = crypto::seal_checkpoint(&plain, &root, &salt)?;
        let mut bytes = b"SBR1".to_vec();
        bytes.extend_from_slice(&(header.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&header);
        bytes.extend_from_slice(&payload);
        Ok(bytes)
    }
    fn open(bytes: &[u8], password: &str) -> Result<Self> {
        if bytes.len() > MAX_REDO || password.is_empty() || password.len() > 4096 {
            return Err(INVALID_REDO);
        }
        let mut decoder = Decoder(bytes);
        if decoder.take(4)? != b"SBR1" {
            return Err(INVALID_REDO);
        }
        let size =
            u32::from_be_bytes(decoder.take(4)?.try_into().map_err(|_| INVALID_REDO)?) as usize;
        if size > MAX_HEADER {
            return Err(INVALID_REDO);
        }
        let encoded = decoder.take(size)?;
        let header: Header = serde_json::from_slice(encoded).map_err(|_| INVALID_REDO)?;
        if header.version != 1
            || header
                .id
                .strip_prefix("r-")
                .and_then(|id| Uuid::parse_str(id).ok())
                .is_none()
            || header.kdf.alg != "pbkdf2-hmac-sha512"
            || !(1..=20_000_000).contains(&header.kdf.iterations)
            || !header.kdf.extra.is_empty()
        {
            return Err(INVALID_REDO);
        }
        let kdf_salt = crypto::unb64(&header.kdf.salt_p).map_err(|_| INVALID_REDO)?;
        if kdf_salt.is_empty() || kdf_salt.len() > 128 {
            return Err(INVALID_REDO);
        }
        let salt: [u8; 32] = crypto::unb64(&header.salt)?
            .try_into()
            .map_err(|_| INVALID_REDO)?;
        let wrap = Sealed::parse(header.wrap).map_err(|_| INVALID_REDO)?;
        let root = crypto::unwrap_passphrase(&header.kdf, &wrap, password, &header.id)
            .map_err(|_| Error("That password does not unlock the interrupted backup import."))?;
        let plain = crypto::open_checkpoint(decoder.0, &root, &salt).map_err(|_| INVALID_REDO)?;
        let mut decoder = Decoder(&plain);
        if decoder.take(4)? != b"BRI1" || decoder.frame(MAX_HEADER)? != Some(encoded) {
            return Err(INVALID_REDO);
        }
        let intent = Self {
            identity: decoder.take(32)?.try_into().map_err(|_| INVALID_REDO)?,
            before: decoder.images()?,
            after: decoder.images()?,
        };
        if !decoder.0.is_empty() {
            return Err(INVALID_REDO);
        }
        intent.validate()?;
        Ok(intent)
    }
    fn finish(
        &self,
        library: &Library,
        check: &dyn Fn() -> Result<()>,
        fault: Option<u8>,
    ) -> Result<()> {
        check()?;
        if crate::primary::sync_readiness(&library.root)? != crate::primary::Readiness::Ready
            || identity(&library.root, false)? != self.identity
        {
            return Err(INVALID_REDO);
        }
        if !Images::read(&library.root)?.allowed(&self.before, &self.after) {
            return Err(CHANGED);
        }
        if let Some(bytes) = &self.after.plain
            && Images::read(&library.root)?.plain != self.after.plain
        {
            check()?;
            if !Images::read(&library.root)?.allowed(&self.before, &self.after) {
                return Err(CHANGED);
            }
            model::atomic_write(&library.path(), bytes)?;
        }
        if fault == Some(1) {
            return Err(RECOVERY);
        }
        check()?;
        let current = Images::read(&library.root)?;
        if current.plain != self.after.plain
            || current.vault != self.before.vault && current.vault != self.after.vault
        {
            return Err(CHANGED);
        }
        if let Some(bytes) = &self.after.vault
            && current.vault != self.after.vault
        {
            check_vault_directory(&library.root)?;
            let path = library.root.join("Vault");
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&path)
                .or_else(|error| {
                    if error.kind() == std::io::ErrorKind::AlreadyExists {
                        Ok(())
                    } else {
                        Err(error)
                    }
                })
                .and_then(|_| fs::set_permissions(&path, fs::Permissions::from_mode(0o700)))
                .map_err(|_| INVALID_REDO)?;
            fs::File::open(&library.root)
                .and_then(|f| f.sync_all())
                .map_err(|_| INVALID_REDO)?;
            check()?;
            let current = Images::read(&library.root)?;
            if current.plain != self.after.plain
                || current.vault != self.before.vault && current.vault != self.after.vault
            {
                return Err(CHANGED);
            }
            model::atomic_write(&path.join("vault.json"), bytes)?;
        }
        if fault == Some(2) {
            return Err(RECOVERY);
        }
        check()?;
        if Images::read(&library.root)? != self.after {
            return Err(CHANGED);
        }
        if fault == Some(3) {
            return Err(RECOVERY);
        }
        check()?;
        fs::remove_file(library.root.join(DIRECTORY).join(PENDING)).map_err(|_| INVALID_REDO)?;
        fs::File::open(library.root.join(DIRECTORY))
            .and_then(|f| f.sync_all())
            .map_err(|_| INVALID_REDO)?;
        Ok(())
    }
}
/// Recovery starts from the root/lock and authenticates the full encrypted
/// intent before either primary file is inspected. Every resume needs a fresh
/// caller-owned desktop/focus authorization; cancellation retains the fence.
pub fn recover(library: &Library, password: &str, check: &dyn Fn() -> Result<()>) -> Result<()> {
    check()?;
    let bytes = {
        let _guard = library.lock()?;
        check()?;
        if !pending(&library.root)? {
            return Err(Error("No interrupted backup import was found."));
        }
        model::read_regular_bounded(&library.root.join(DIRECTORY).join(PENDING), MAX_REDO)?
            .ok_or(INVALID_REDO)?
    };
    let intent = Intent::open(&bytes, password)?;
    check()?;
    let _guard = library.lock()?;
    check()?;
    if !pending(&library.root)?
        || model::read_regular_bounded(&library.root.join(DIRECTORY).join(PENDING), MAX_REDO)?
            .as_deref()
            != Some(&bytes)
    {
        return Err(INVALID_REDO);
    }
    intent.finish(library, check, None)
}

#[cfg(test)]
#[path = "backup_import_tests.rs"]
mod tests;
