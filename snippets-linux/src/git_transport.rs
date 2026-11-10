//! Serverless sync through an ordinary hosted git repository, for the
//! existing bounded sync owner (`receiver`/`sender`). The host stores only
//! the opaque wire records the engine hands over, in the repository layout
//! shared with the Apple apps (see `git_layout`).
//!
//! How the engine contract maps onto git:
//! - **Record version** (per-record CAS token): the git blob id of the record
//!   file. A record whose file vanished is remote data loss, never a delete.
//! - **Cursor**: the dataset id plus the commit last fetched. A fetch diffs
//!   that commit's tree against the head locally, returning exactly the changed
//!   records in bounded pages toward one fixed target commit.
//! - **Batch atomicity**: one commit per submission, pushed with a lease on the
//!   head it was built on. A lost race re-reads the head and re-checks every
//!   record's CAS against it.
//! - **Dataset identity**: the manifest's random dataset id. A branch recreated
//!   with a new manifest is a reviewed reset, never silently merged.
//! - **Plain-text libraries** (`snippets-plain-v1`): ordinary snippets are
//!   Markdown files under `snippets/` (see `git_plain`). The transport opens
//!   what the engine submits with the library key and renders it, and seals
//!   what it reads back, so the engine sees ordinary sealed records. A
//!   record's version is its current file's blob id, whichever directory it is
//!   in, and a ciphertext record wins over a Markdown file with the same id.
use crate::{
    cloud::{self, Cursor, ErrorCode, Offer, Outcome, RecordVersion, Role, ServerRecord},
    crypto::RootKey,
    git_layout::{self, LayoutError, Mode, Position},
    git_location::{HttpCredential, Remote},
    git_plain,
    git_repo::{self, Cache, Endpoint, PushOutcome, TreeEntry},
    inbound::{Feed, PAGE_LIMIT},
    merge,
    receiver::{self, FetchedPage, Observation, RemoteResult},
    sender::{self, SendObservation},
    wire::{self, Envelope, WireRecord},
};
use std::{
    collections::{BTreeMap, HashSet},
    path::PathBuf,
    sync::Mutex,
    time::{Duration, Instant},
};
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

pub const MAXIMUM_PUSH_ATTEMPTS: usize = 5;
/// The engine never sends more than `PAGE_LIMIT` offers; this bounds one
/// commit's ciphertext the way the Apple transport does.
pub const MAXIMUM_COMMIT_BLOB_BYTES: usize = 24 * 1024 * 1024;
/// Several scope checks in one bounded cycle reuse one remote observation.
const OBSERVATION_REUSE: Duration = Duration::from_secs(3);

/// Closed vocabulary; codes match the Apple transport's failure details.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Git(git_repo::Failure),
    NotInitialized,
    NotALibrary,
    SchemaUnsupported,
    LibraryReplaced,
    DatasetReset,
    RecordRemoved,
    RecordMalformed,
    SnapshotIncomplete,
    PushRejected,
    /// Five lost races in a row; retry shortly.
    Contended,
    InvalidPath,
    CursorInvalid,
    /// A plain-text library needs the library key to read and write files.
    KeyRequired,
    /// The manifest names another storage mode than the one this device
    /// agreed to (for example an encrypted library turned into plain text).
    ModeChanged,
    /// A Markdown file in a plain-text library cannot be read (a mistake in
    /// its front matter, invalid UTF-8, too large). Apple quarantines that one
    /// snippet; this engine has no per-record quarantine and stops instead.
    FileUnreadable,
}
impl From<git_repo::Failure> for Failure {
    fn from(value: git_repo::Failure) -> Self {
        Self::Git(value)
    }
}
impl From<LayoutError> for Failure {
    fn from(value: LayoutError) -> Self {
        match value {
            LayoutError::NotALibrary => Self::NotALibrary,
            LayoutError::IncompatibleSchema => Self::SchemaUnsupported,
            LayoutError::MalformedRecord => Self::RecordMalformed,
        }
    }
}
impl Failure {
    pub fn code(self) -> &'static str {
        match self {
            Self::Git(failure) => failure.code(),
            Self::NotInitialized => "git_repository_not_initialized",
            Self::NotALibrary => "git_branch_not_snippets_library",
            Self::SchemaUnsupported => "git_sync_schema_unsupported",
            Self::LibraryReplaced => "git_library_replaced",
            Self::DatasetReset => "dataset_reset",
            Self::RecordRemoved => "git_record_removed",
            Self::RecordMalformed => "git_record_malformed",
            Self::SnapshotIncomplete => "git_snapshot_incomplete",
            Self::PushRejected => "git_push_rejected",
            Self::Contended => "git_contended",
            Self::InvalidPath => "git_invalid_path",
            Self::CursorInvalid => "git_cursor_invalid",
            Self::KeyRequired => "git_key_required",
            Self::ModeChanged => "git_library_mode_changed",
            Self::FileUnreadable => "git_plain_file_unreadable",
        }
    }
    /// The engine's closed transport vocabulary. The precise failure stays
    /// available through `GitTransport::last_failure`.
    pub fn to_cloud(self) -> cloud::Failure {
        use git_repo::Failure as G;
        match self {
            Self::Git(G::Authentication | G::RepositoryNotFound | G::HostKeyUnverified) => {
                cloud::Failure::InvalidCredential
            }
            Self::Git(G::RateLimited) | Self::Contended => cloud::Failure::Server {
                code: ErrorCode::RateLimited,
                retry_after: Some(5),
            },
            Self::Git(G::PushTooLarge) => cloud::Failure::MessageTooLarge,
            Self::Git(G::ResponseTooLarge) | Self::RecordMalformed | Self::FileUnreadable => {
                cloud::Failure::InvalidResponse
            }
            Self::Git(G::Unsupported | G::GitTooOld | G::SshTooOld)
            | Self::NotInitialized
            | Self::NotALibrary
            | Self::SchemaUnsupported
            | Self::InvalidPath
            | Self::KeyRequired => cloud::Failure::IncompatibleServer,
            Self::Git(G::Unreachable | G::GitUnavailable | G::LocalStorage | G::Cancelled)
            | Self::SnapshotIncomplete => cloud::Failure::Network,
            Self::LibraryReplaced
            | Self::DatasetReset
            | Self::RecordRemoved
            | Self::ModeChanged => cloud::Failure::DatasetReview,
            Self::PushRejected | Self::Git(G::PushRefused) => cloud::Failure::ReadOnly,
            Self::CursorInvalid => cloud::Failure::Server {
                code: ErrorCode::CursorInvalid,
                retry_after: None,
            },
        }
    }
}
pub type Result<T> = std::result::Result<T, Failure>;

/// What a branch currently holds, for setup.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RepositoryState {
    /// The branch does not exist yet; `initialize` may create it.
    Empty,
    Library {
        dataset: Uuid,
        mode: Mode,
    },
    /// The branch exists but is not a Snippets library. It is never overwritten.
    Foreign,
}

pub struct Configuration {
    pub remote: Remote,
    /// HTTPS only. SSH authenticates through the user's agent and config.
    pub credential: Option<HttpCredential>,
    /// Transport-private snapshot cache; safe to delete at any time.
    pub cache: PathBuf,
    /// The library this device holds the key for. Any other dataset on the
    /// branch stops the data plane instead of being encrypted to.
    pub expected_dataset: Option<Uuid>,
    pub options: git_repo::Options,
    /// Seconds since the epoch for commit timestamps.
    pub now: fn() -> i64,
    /// The library key. A plain-text library's data plane needs it to open
    /// and render records; without it that library fails `git_key_required`.
    /// Only given when the agreed mode is plain text; setup-only transports
    /// leave it out.
    pub plain_key: Option<PlainKey>,
    /// The storage mode this device agreed to. A manifest naming another mode
    /// stops sync (`git_library_mode_changed`) until the user reconnects and
    /// consents again. Setup-only transports leave it out.
    pub expected_mode: Option<Mode>,
}
/// The sync-v1 library key and salt, as the engine uses them.
pub struct PlainKey {
    root: RootKey,
    salt: [u8; 32],
}
impl PlainKey {
    pub fn from_material(material: &[u8; 64]) -> Self {
        Self {
            root: RootKey::from_bytes(&material[..32]).expect("32-byte key"),
            salt: material[32..].try_into().expect("32-byte salt"),
        }
    }
}
pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[derive(Clone)]
struct Snapshot {
    commit: String,
    tree: String,
    root: Vec<TreeEntry>,
    dataset: Uuid,
    mode: Mode,
    records_tree: Option<String>,
    /// Two-hex-digit directory name under `records/` → its tree.
    fanout: BTreeMap<String, String>,
    /// `snippets/` in a plain-text library.
    snippets_tree: Option<String>,
}

/// Where one record lives in a plain-text library.
#[derive(Clone, PartialEq, Eq)]
enum Location {
    Record {
        blob: String,
    },
    /// `readable` is false for a file that cannot be read (broken front
    /// matter, not UTF-8, too large): it is skipped, never deleted, and never
    /// overwritten until it is fixed.
    Plain {
        name: String,
        blob: String,
        readable: bool,
    },
}
impl Location {
    fn blob(&self) -> &str {
        match self {
            Self::Record { blob } | Self::Plain { blob, .. } => blob,
        }
    }
    /// The CAS token: Markdown and ciphertext versions are tagged by kind.
    fn version(&self) -> String {
        match self {
            Self::Record { blob } => git_layout::record_version(blob),
            Self::Plain { blob, .. } => git_layout::markdown_version(blob),
        }
    }
    fn path(&self, id: Uuid) -> Vec<String> {
        match self {
            Self::Record { .. } => {
                let (prefix, name) = git_layout::record_path(id);
                vec![git_layout::RECORDS.into(), prefix, name]
            }
            Self::Plain { name, .. } => vec![git_plain::DIRECTORY.into(), name.clone()],
        }
    }
}
/// A plain-text fetch's items, and the locations the target holds by id.
type Changes = (Vec<(Uuid, Item)>, BTreeMap<Uuid, Location>);
/// A hand deletion not yet recorded under `records/`: the deleted file's blob
/// and the tombstone every device derives for it.
#[derive(Clone)]
struct Pending {
    blob: String,
    tombstone: Envelope,
}
/// One entry of a plain-text fetch, in id order.
#[derive(Clone)]
enum Item {
    /// The record's current file.
    Current(Location),
    /// A Markdown file deleted by hand since the base snapshot, delivered as
    /// a tombstone one tick after it.
    Deleted(Pending),
}

pub struct GitTransport {
    configuration: Configuration,
    cache: Cache,
    url: String,
    /// The dataset admitted for data-plane use. Only a reviewed reset moves it.
    pinned: Option<Uuid>,
    halt: Option<Failure>,
    last_failure: Option<Failure>,
    observed: Option<(Instant, Uuid)>,
    /// Plain-text libraries: unreadable Markdown files in the head last
    /// fetched, and offers refused because their file is one of them.
    unreadable_files: std::cell::Cell<usize>,
    refused_unreadable: std::cell::Cell<usize>,
}
impl GitTransport {
    pub fn new(configuration: Configuration) -> Result<Self> {
        let cache = Cache::open(configuration.cache.clone(), configuration.options.clone())?;
        let url = configuration.remote.location.spec();
        Ok(Self {
            configuration,
            cache,
            url,
            pinned: None,
            halt: None,
            last_failure: None,
            observed: None,
            unreadable_files: std::cell::Cell::new(0),
            refused_unreadable: std::cell::Cell::new(0),
        })
    }
    pub fn remote(&self) -> &Remote {
        &self.configuration.remote
    }
    /// The precise failure behind the last engine-facing error.
    pub fn last_failure(&self) -> Option<Failure> {
        self.last_failure
    }
    /// Non-fatal plain-text warnings, counts only: unreadable Markdown files
    /// in the head last fetched, and offers refused because their snippet's
    /// file is unreadable (`git_plain_file_unreadable` for that record).
    pub fn plain_warnings(&self) -> (usize, usize) {
        (self.unreadable_files.get(), self.refused_unreadable.get())
    }
    pub fn checkpoint_scope(&self, dataset: Uuid) -> crate::journal::Scope {
        git_layout::checkpoint_scope(&self.configuration.remote, dataset)
    }
    pub fn feed(dataset: Uuid) -> crate::journal::Result<Feed> {
        Feed::new(dataset, 1)
    }
    fn endpoint(&self) -> Endpoint<'_> {
        Endpoint {
            url: &self.url,
            credential: self.configuration.credential.as_ref(),
        }
    }
    fn remember<T>(&mut self, result: Result<T>) -> Result<T> {
        if let Err(failure) = &result {
            self.last_failure = Some(*failure);
            if matches!(
                failure,
                Failure::DatasetReset
                    | Failure::LibraryReplaced
                    | Failure::RecordRemoved
                    | Failure::ModeChanged
            ) {
                self.halt = Some(*failure);
            }
        }
        result
    }
    fn check_halt(&self) -> Result<()> {
        match self.halt {
            Some(failure) => Err(failure),
            None => Ok(()),
        }
    }

    // MARK: - Snapshots

    fn remote_head(&self) -> Result<Option<String>> {
        Ok(self
            .cache
            .remote_head(&self.endpoint(), &self.configuration.remote.ref_name())?)
    }
    /// A complete local snapshot of `commit`, fetching the branch if needed.
    fn snapshot_at(&self, commit: &str) -> Result<Snapshot> {
        if !self.cache.has_commit(commit) {
            self.cache
                .fetch(&self.endpoint(), &self.configuration.remote.ref_name())?;
            if !self.cache.has_commit(commit) {
                // The branch moved past a rewritten head between the two
                // requests; the caller re-reads it on its next attempt.
                return Err(Failure::SnapshotIncomplete);
            }
        }
        self.cached_snapshot(commit)
    }
    fn cached_snapshot(&self, commit: &str) -> Result<Snapshot> {
        let tree = self.cache.commit_tree(commit)?;
        let root = self.cache.tree_entries(&tree)?;
        let manifest = root
            .iter()
            .find(|e| e.name == git_layout::MANIFEST.as_bytes() && e.is_regular_file())
            .ok_or(Failure::NotALibrary)?;
        let blob = self
            .cache
            .blobs(std::slice::from_ref(&manifest.id))?
            .remove(&manifest.id)
            .ok_or(Failure::SnapshotIncomplete)?;
        let (dataset, mode) = git_layout::decode_manifest(&blob)?;
        let records_tree = root
            .iter()
            .find(|e| e.name == git_layout::RECORDS.as_bytes() && e.is_tree())
            .map(|e| e.id.clone());
        let snippets_tree = root
            .iter()
            .find(|e| e.name == git_plain::DIRECTORY.as_bytes() && e.is_tree())
            .map(|e| e.id.clone());
        let mut fanout = BTreeMap::new();
        if let Some(records) = &records_tree {
            for entry in self.cache.tree_entries(records)? {
                if entry.is_tree() && git_layout::is_fanout_name(&entry.name) {
                    fanout.insert(
                        String::from_utf8(entry.name).expect("validated hex name"),
                        entry.id,
                    );
                }
            }
        }
        Ok(Snapshot {
            commit: commit.to_owned(),
            tree,
            root,
            dataset,
            mode,
            records_tree,
            fanout,
            snippets_tree,
        })
    }
    fn current_snapshot(&self) -> Result<Snapshot> {
        let head = self.remote_head()?.ok_or(Failure::NotInitialized)?;
        let snapshot = self.snapshot_at(&head)?;
        if self
            .configuration
            .expected_dataset
            .is_some_and(|expected| expected != snapshot.dataset)
        {
            return Err(Failure::LibraryReplaced);
        }
        self.validate_mode(snapshot.mode)?;
        Ok(snapshot)
    }
    fn validate_mode(&self, mode: Mode) -> Result<()> {
        match self.configuration.expected_mode {
            Some(expected) if expected != mode => Err(Failure::ModeChanged),
            _ => Ok(()),
        }
    }
    /// A library other than the connected one stops sync for reconnection; a
    /// change of the pinned dataset is a reviewed reset.
    fn validate_snapshot(&self, snapshot: &Snapshot) -> Result<()> {
        self.validate_dataset_only(snapshot.dataset)?;
        self.validate_mode(snapshot.mode)
    }
    fn validate_dataset_only(&self, dataset: Uuid) -> Result<()> {
        if self
            .configuration
            .expected_dataset
            .is_some_and(|expected| expected != dataset)
        {
            return Err(Failure::LibraryReplaced);
        }
        if self.pinned.is_some_and(|pinned| pinned != dataset) {
            return Err(Failure::DatasetReset);
        }
        Ok(())
    }
    /// Record files keyed by id. Other names, modes and depths are ignored.
    fn records(&self, snapshot: &Snapshot) -> Result<BTreeMap<Uuid, String>> {
        let mut result = BTreeMap::new();
        let Some(tree) = &snapshot.records_tree else {
            return Ok(result);
        };
        for (path, entry) in self.cache.tree_recursive(tree)? {
            let [prefix, name] = path.as_slice() else {
                continue;
            };
            let Ok(prefix_text) = std::str::from_utf8(prefix) else {
                continue;
            };
            if !entry.is_regular_file() || !snapshot.fanout.contains_key(prefix_text) {
                continue;
            }
            if let Some(id) = git_layout::record_id(name, prefix) {
                result.insert(id, entry.id);
            }
        }
        Ok(result)
    }
    /// Records whose file changed between two snapshots, in id order.
    fn changed(&self, base: &Snapshot, head: &Snapshot) -> Result<Vec<(Uuid, String)>> {
        if base.records_tree == head.records_tree {
            return Ok(vec![]);
        }
        let old = self.records(base)?;
        let new = self.records(head)?;
        if old.keys().any(|id| !new.contains_key(id)) {
            // The engine never deletes physically; tombstones are saves.
            return Err(Failure::RecordRemoved);
        }
        Ok(new
            .into_iter()
            .filter(|(id, blob)| old.get(id) != Some(blob))
            .collect())
    }
    fn read_records(&self, entries: &[(Uuid, String)]) -> Result<Vec<ServerRecord>> {
        let ids: Vec<String> = entries.iter().map(|(_, blob)| blob.clone()).collect();
        let blobs = self.cache.blobs(&ids)?;
        entries
            .iter()
            .map(|(id, blob)| {
                let bytes = blobs.get(blob).ok_or(Failure::SnapshotIncomplete)?;
                server_record(git_layout::decode_record(bytes, *id)?, blob)
            })
            .collect()
    }

    // MARK: - Setup

    pub fn inspect(&mut self) -> Result<RepositoryState> {
        let result = self.inspect_inner();
        self.remember(result)
    }
    fn inspect_inner(&self) -> Result<RepositoryState> {
        let Some(head) = self.remote_head()? else {
            return Ok(RepositoryState::Empty);
        };
        match self.snapshot_at(&head) {
            Ok(snapshot) => Ok(RepositoryState::Library {
                dataset: snapshot.dataset,
                mode: snapshot.mode,
            }),
            Err(Failure::NotALibrary) => Ok(RepositoryState::Foreign),
            Err(failure) => Err(failure),
        }
    }
    /// Creates the library branch if it does not exist and returns its dataset
    /// id. An existing library is adopted, never replaced; a foreign branch is
    /// refused. The result differs from `dataset` exactly when another device
    /// created a library first. `files` are extra paths under `keys/`. The
    /// mode is fixed for the library's lifetime.
    pub fn initialize(
        &mut self,
        dataset: Uuid,
        files: &[(&str, &[u8])],
        mode: Mode,
    ) -> Result<Uuid> {
        let result = self.initialize_inner(dataset, files, mode);
        self.remember(result)
    }
    fn initialize_inner(&self, dataset: Uuid, files: &[(&str, &[u8])], mode: Mode) -> Result<Uuid> {
        let files = auxiliary_paths(files)?;
        for _ in 0..MAXIMUM_PUSH_ATTEMPTS {
            if let Some(head) = self.remote_head()? {
                return match self.snapshot_at(&head) {
                    Ok(snapshot) => Ok(snapshot.dataset),
                    Err(Failure::NotALibrary) => Err(Failure::NotALibrary),
                    Err(failure) => Err(failure),
                };
            }
            let mut blobs: Vec<(Vec<String>, String)> = vec![
                (
                    vec![git_layout::MANIFEST.into()],
                    self.cache
                        .write_blob(&git_layout::encode_manifest(dataset, mode))?,
                ),
                (
                    vec![git_layout::README.into()],
                    self.cache.write_blob(mode.readme().as_bytes())?,
                ),
            ];
            for (path, bytes) in &files {
                blobs.push((path.clone(), self.cache.write_blob(bytes)?));
            }
            let root = self.rewrite_tree(None, &blobs)?;
            let commit = self.cache.write_commit(
                &root,
                None,
                git_layout::CREATE_MESSAGE,
                (self.configuration.now)(),
            )?;
            match self.cache.push(
                &self.endpoint(),
                &self.configuration.remote.ref_name(),
                None,
                &commit,
            )? {
                PushOutcome::Updated => {
                    let _ = self.cache.keep(&commit);
                    return Ok(dataset);
                }
                PushOutcome::Rejected => {
                    // Another device created the branch first; adopt it on the
                    // next pass. If it still does not exist, the host refused.
                    if self.remote_head()?.is_none() {
                        return Err(Failure::PushRejected);
                    }
                }
            }
        }
        Err(Failure::Contended)
    }
    /// Fails unless the credential may push to the existing branch.
    pub fn verify_write_access(&mut self) -> Result<()> {
        let result = (|| {
            let snapshot = self.current_snapshot()?;
            self.cache.verify_write(
                &self.endpoint(),
                &self.configuration.remote.ref_name(),
                &snapshot.commit,
            )?;
            Ok(())
        })();
        self.remember(result)
    }
    /// The bytes at `path` (under `keys/`) in the current head, or None.
    pub fn read_file(&mut self, path: &str) -> Result<Option<Vec<u8>>> {
        let result = (|| {
            let components = auxiliary_path(path)?;
            let snapshot = self.current_snapshot()?;
            let mut entries = snapshot.root.clone();
            for (index, component) in components.iter().enumerate() {
                let Some(entry) = entries.iter().find(|e| e.name == component.as_bytes()) else {
                    return Ok(None);
                };
                if index == components.len() - 1 {
                    if !entry.is_regular_file() {
                        return Ok(None);
                    }
                    return Ok(self
                        .cache
                        .blobs(std::slice::from_ref(&entry.id))?
                        .remove(&entry.id));
                }
                if !entry.is_tree() {
                    return Ok(None);
                }
                entries = self.cache.tree_entries(&entry.id)?;
            }
            Ok(None)
        })();
        self.remember(result)
    }
    /// Replaces files under `keys/` in one compare-and-swap commit on top of
    /// the current head. Records and the manifest are never touched.
    pub fn write_files(&mut self, files: &[(&str, &[u8])], message: &str) -> Result<()> {
        let result = self.write_files_inner(files, message);
        self.remember(result)
    }
    fn write_files_inner(&self, files: &[(&str, &[u8])], message: &str) -> Result<()> {
        let files = auxiliary_paths(files)?;
        if files.is_empty() {
            return Ok(());
        }
        let mut rejected: Option<String> = None;
        for _ in 0..MAXIMUM_PUSH_ATTEMPTS {
            let head = self.remote_head()?.ok_or(Failure::NotInitialized)?;
            if rejected.as_deref() == Some(head.as_str()) {
                return Err(Failure::PushRejected);
            }
            let snapshot = self.snapshot_at(&head)?;
            self.validate_snapshot(&snapshot)?;
            let mut blobs = Vec::new();
            for (path, bytes) in &files {
                blobs.push((path.clone(), self.cache.write_blob(bytes)?));
            }
            let root = self.rewrite_tree(Some(&snapshot.tree), &blobs)?;
            if root == snapshot.tree {
                return Ok(());
            }
            let commit =
                self.cache
                    .write_commit(&root, Some(&head), message, (self.configuration.now)())?;
            match self.cache.push(
                &self.endpoint(),
                &self.configuration.remote.ref_name(),
                Some(&head),
                &commit,
            )? {
                PushOutcome::Updated => {
                    let _ = self.cache.keep(&commit);
                    return Ok(());
                }
                PushOutcome::Rejected => rejected = Some(head),
            }
        }
        Err(Failure::Contended)
    }
    /// The id of `tree` (None: empty) with each path set to its blob.
    /// Unrelated entries are kept byte-for-byte.
    fn rewrite_tree(&self, tree: Option<&str>, files: &[(Vec<String>, String)]) -> Result<String> {
        let mut entries = match tree {
            Some(tree) => self.cache.tree_entries(tree)?,
            None => vec![],
        };
        let mut children: BTreeMap<String, Vec<(Vec<String>, String)>> = BTreeMap::new();
        for (components, blob) in files {
            if components.len() == 1 {
                entries.retain(|e| e.name != components[0].as_bytes());
                entries.push(blob_entry(components[0].as_bytes(), blob));
            } else {
                children
                    .entry(components[0].clone())
                    .or_default()
                    .push((components[1..].to_vec(), blob.clone()));
            }
        }
        for (name, nested) in children {
            let existing = entries
                .iter()
                .find(|e| e.name == name.as_bytes() && e.is_tree())
                .map(|e| e.id.clone());
            let subtree = self.rewrite_tree(existing.as_deref(), &nested)?;
            entries.retain(|e| e.name != name.as_bytes());
            entries.push(tree_entry(name.as_bytes(), &subtree));
        }
        Ok(self.cache.write_tree(&entries)?)
    }

    // MARK: - Data plane

    fn observe(&mut self) -> Result<Uuid> {
        self.check_halt()?;
        if let Some((at, dataset)) = self.observed
            && at.elapsed() < OBSERVATION_REUSE
        {
            return Ok(dataset);
        }
        let snapshot = self.current_snapshot()?;
        self.validate_snapshot(&snapshot)?;
        self.pinned.get_or_insert(snapshot.dataset);
        let _ = self.cache.keep(&snapshot.commit);
        self.observed = Some((Instant::now(), snapshot.dataset));
        Ok(snapshot.dataset)
    }
    fn observation(&self, dataset: Uuid) -> Result<Observation> {
        Ok(Observation {
            scope: self.checkpoint_scope(dataset),
            feed: Self::feed(dataset).map_err(|_| Failure::SchemaUnsupported)?,
        })
    }
    fn fetch_inner(&mut self, cursor: Option<&Cursor>) -> Result<FetchedPage> {
        self.check_halt()?;
        let head = self.current_snapshot()?;
        self.validate_snapshot(&head)?;
        let dataset = *self.pinned.get_or_insert(head.dataset);
        let position = match cursor {
            None => None,
            Some(cursor) => {
                Some(Position::decode(cursor.for_checkpoint()).ok_or(Failure::CursorInvalid)?)
            }
        };
        let head_mode = head.mode;
        let snapshot_of = |commit: &str| -> Result<Snapshot> {
            if !self.cache.has_commit(commit) {
                return Err(Failure::CursorInvalid);
            }
            let snapshot = self
                .cached_snapshot(commit)
                .map_err(|failure| match failure {
                    Failure::Git(_) => failure,
                    _ => Failure::CursorInvalid,
                })?;
            // The head's mode was checked against the agreed one. A cursor
            // commit written in another mode (before a mode change the user
            // has since consented to) is not diffed across modes: refetch in
            // full.
            if snapshot.dataset != dataset || snapshot.mode != head_mode {
                return Err(Failure::CursorInvalid);
            }
            Ok(snapshot)
        };
        let (target, base, offset) = match position {
            None => (head, None, 0),
            Some(Position::Complete {
                dataset: cursor_dataset,
                commit,
            }) => {
                if cursor_dataset != dataset {
                    return Err(Failure::CursorInvalid);
                }
                // A plain-text library may still have hand deletions to record.
                if commit == head.commit
                    && !(head.mode == Mode::PlainText && self.has_pending(dataset))
                {
                    if head.mode == Mode::PlainText {
                        self.unreadable_files
                            .set(count_unreadable(&self.locations(&head)?));
                    }
                    let _ = self.cache.keep(&head.commit);
                    return Ok(FetchedPage {
                        observation: self.observation(dataset)?,
                        records: vec![],
                        cursor: cursor.expect("decoded from a cursor").clone(),
                        full_snapshot: false,
                        has_more: false,
                    });
                }
                let base = snapshot_of(&commit)?;
                (head, Some(base), 0)
            }
            Some(Position::Partial {
                dataset: cursor_dataset,
                target,
                base,
                offset,
            }) => {
                if cursor_dataset != dataset {
                    return Err(Failure::CursorInvalid);
                }
                let target = snapshot_of(&target)?;
                let base = base.as_deref().map(snapshot_of).transpose()?;
                (target, base, offset)
            }
        };
        if target.mode == Mode::PlainText {
            return self.plain_page(dataset, target, base, offset);
        }
        let list: Vec<(Uuid, String)> = match &base {
            None => self.records(&target)?.into_iter().collect(),
            Some(base) => self.changed(base, &target)?,
        };
        if offset > list.len() || offset > 0 && offset == list.len() {
            return Err(Failure::CursorInvalid);
        }
        let end = (offset + PAGE_LIMIT).min(list.len());
        let records = self.read_records(&list[offset..end])?;
        let has_more = end < list.len();
        let next = if has_more {
            Position::Partial {
                dataset,
                target: target.commit.clone(),
                base: base.as_ref().map(|b| b.commit.clone()),
                offset: end,
            }
        } else {
            Position::Complete {
                dataset,
                commit: target.commit.clone(),
            }
        };
        let _ = self.cache.keep(&target.commit);
        Ok(FetchedPage {
            observation: self.observation(dataset)?,
            records,
            cursor: Cursor::from_checkpoint(next.encode()).map_err(|_| Failure::CursorInvalid)?,
            full_snapshot: base.is_none(),
            has_more,
        })
    }

    fn submit_inner(&mut self, offers: &[Offer]) -> Result<Vec<Outcome>> {
        self.check_halt()?;
        if offers.is_empty() || offers.len() > PAGE_LIMIT {
            return Err(Failure::InvalidPath);
        }
        let mut ids = HashSet::new();
        for offer in offers {
            if !ids.insert(offer.record.id) {
                return Err(Failure::InvalidPath);
            }
        }
        let dataset = self.observe()?;
        let mut outcomes: Vec<Option<Outcome>> = (0..offers.len()).map(|_| None).collect();
        let mut queue: Vec<(usize, usize)> = chunks(offers);
        queue.reverse();
        let mut landed = false;
        while let Some((start, end)) = queue.pop() {
            match self.submit_chunk(&offers[start..end], dataset) {
                Ok(chunk) => {
                    landed |= chunk.iter().any(|o| matches!(o, Outcome::Accepted { .. }));
                    for (slot, outcome) in outcomes[start..end].iter_mut().zip(chunk) {
                        *slot = Some(outcome);
                    }
                }
                Err(Failure::Git(git_repo::Failure::PushTooLarge)) => {
                    // The host (or a proxy) refused the request body. Halve the
                    // commit; one record that still does not fit is refused alone.
                    if end - start > 1 {
                        let middle = start + (end - start) / 2;
                        queue.push((middle, end));
                        queue.push((start, middle));
                    } else {
                        outcomes[start] = Some(Outcome::Rejected {
                            error_code: ErrorCode::PayloadTooLarge,
                            retry_after_seconds: None,
                        });
                    }
                }
                Err(failure) => {
                    // Once anything landed, report it: the rest gets a retryable
                    // rejection instead of a whole-call failure that would
                    // discard acknowledgements for pushed commits.
                    if !landed {
                        return Err(failure);
                    }
                    self.last_failure = Some(failure);
                    for slot in outcomes.iter_mut().filter(|o| o.is_none()) {
                        *slot = Some(Outcome::Rejected {
                            error_code: ErrorCode::RateLimited,
                            retry_after_seconds: Some(5),
                        });
                    }
                    break;
                }
            }
        }
        Ok(outcomes
            .into_iter()
            .map(|o| o.expect("every offer has an outcome"))
            .collect())
    }
    fn submit_chunk(&mut self, offers: &[Offer], dataset: Uuid) -> Result<Vec<Outcome>> {
        let mut rejected: Option<String> = None;
        for _ in 0..MAXIMUM_PUSH_ATTEMPTS {
            let head_id = self.remote_head()?.ok_or(Failure::NotInitialized)?;
            // A rejection that did not move the branch is not a race: a
            // protected branch, a hook, or missing permission.
            if rejected.as_deref() == Some(head_id.as_str()) {
                return Err(Failure::PushRejected);
            }
            let head = self.snapshot_at(&head_id)?;
            self.validate_snapshot(&head)?;
            if head.dataset != dataset {
                return Err(Failure::DatasetReset);
            }
            let (outcomes, commit) = self.plan(offers, &head)?;
            let Some(commit) = commit else {
                return Ok(outcomes);
            };
            match self.cache.push(
                &self.endpoint(),
                &self.configuration.remote.ref_name(),
                Some(&head_id),
                &commit,
            )? {
                PushOutcome::Updated => {
                    let _ = self.cache.keep(&commit);
                    self.observed = None;
                    return Ok(outcomes);
                }
                PushOutcome::Rejected => rejected = Some(head_id),
            }
        }
        Err(Failure::Contended)
    }
    /// Applies records in order, each CAS-checked against the head plus the
    /// records accepted earlier in this batch, like a sequential backend.
    fn plan(&self, offers: &[Offer], head: &Snapshot) -> Result<(Vec<Outcome>, Option<String>)> {
        if head.mode == Mode::PlainText {
            return self.plan_plain(offers, head);
        }
        let mut outcomes = Vec::with_capacity(offers.len());
        let mut fanouts: BTreeMap<String, Vec<TreeEntry>> = BTreeMap::new();
        let mut touched = std::collections::BTreeSet::new();
        let mut accepted = 0usize;
        for offer in offers {
            let record = &offer.record;
            if oversized(record) {
                // Refused on its own; the rest of the batch still syncs.
                outcomes.push(Outcome::Rejected {
                    error_code: ErrorCode::PayloadTooLarge,
                    retry_after_seconds: None,
                });
                continue;
            }
            let (prefix, name) = git_layout::record_path(record.id);
            if !fanouts.contains_key(&prefix) {
                let loaded = match head.fanout.get(&prefix) {
                    Some(tree) => self.cache.tree_entries(tree)?,
                    None => vec![],
                };
                fanouts.insert(prefix.clone(), loaded);
            }
            let entries = fanouts.get_mut(&prefix).expect("loaded above");
            let current = entries
                .iter()
                .find(|e| e.name == name.as_bytes() && e.is_regular_file())
                .map(|e| e.id.clone());
            let expected = offer
                .expected_record_version
                .as_ref()
                .map(|v| v.for_checkpoint().to_owned());
            match &current {
                Some(current)
                    if expected.as_deref()
                        != Some(git_layout::record_version(current).as_str()) =>
                {
                    let bytes = self
                        .cache
                        .blobs(std::slice::from_ref(current))?
                        .remove(current)
                        .ok_or(Failure::SnapshotIncomplete)?;
                    let remote = git_layout::decode_record(&bytes, record.id)?;
                    outcomes.push(Outcome::Conflict {
                        authoritative_record: server_record(remote, current)?,
                    });
                    continue;
                }
                Some(_) => (),
                None if expected.is_some() => {
                    // Tombstones are saves, so a version with no file was removed
                    // by hand: remote data loss that goes to review.
                    return Err(Failure::RecordRemoved);
                }
                None => (),
            }
            let blob = self.cache.write_blob(&git_layout::encode_record(record))?;
            entries.retain(|e| e.name != name.as_bytes());
            entries.push(blob_entry(name.as_bytes(), &blob));
            touched.insert(prefix);
            accepted += 1;
            outcomes.push(Outcome::Accepted {
                record_version: RecordVersion::from_checkpoint(git_layout::record_version(&blob))
                    .map_err(|_| Failure::RecordMalformed)?,
                revision: record.rev.clone(),
            });
        }
        if accepted == 0 {
            return Ok((outcomes, None));
        }
        let mut records = match &head.records_tree {
            Some(tree) => self.cache.tree_entries(tree)?,
            None => vec![],
        };
        for prefix in &touched {
            let tree = self.cache.write_tree(&fanouts[prefix])?;
            records.retain(|e| e.name != prefix.as_bytes());
            records.push(tree_entry(prefix.as_bytes(), &tree));
        }
        let records_tree = self.cache.write_tree(&records)?;
        let mut root = head.root.clone();
        root.retain(|e| e.name != git_layout::RECORDS.as_bytes());
        root.push(tree_entry(git_layout::RECORDS.as_bytes(), &records_tree));
        let root = self.cache.write_tree(&root)?;
        if root == head.tree {
            // Every accepted record already held identical bytes.
            return Ok((outcomes, None));
        }
        let commit = self.cache.write_commit(
            &root,
            Some(&head.commit),
            &git_layout::sync_message(accepted),
            (self.configuration.now)(),
        )?;
        Ok((outcomes, Some(commit)))
    }
}

// MARK: - Plain-text libraries

/// Hand deletions not yet recorded as tombstones under `records/`, per
/// library: id → the deleted Markdown file's blob. Retried on later fetches
/// in this process until a tombstone exists or the id is back, like the Apple
/// transport's in-memory list (a transport here lasts one cycle).
static PENDING_DELETIONS: Mutex<BTreeMap<[u8; 32], BTreeMap<Uuid, Pending>>> =
    Mutex::new(BTreeMap::new());
/// Per library: when a push refused for authentication (read-only access, say)
/// lets normalize and pending-deletion pushes resume.
static NORMALIZE_PAUSED: Mutex<BTreeMap<[u8; 32], Instant>> = Mutex::new(BTreeMap::new());
const NORMALIZE_PAUSE: Duration = Duration::from_secs(3_600);

impl GitTransport {
    fn plain_key(&self) -> Result<&PlainKey> {
        self.configuration
            .plain_key
            .as_ref()
            .ok_or(Failure::KeyRequired)
    }
    fn pending_scope(&self, dataset: Uuid) -> [u8; 32] {
        git_layout::dataset_digest(&self.configuration.remote, dataset)
    }
    fn pending(&self, dataset: Uuid) -> BTreeMap<Uuid, Pending> {
        let pending = PENDING_DELETIONS.lock().unwrap_or_else(|e| e.into_inner());
        pending
            .get(&self.pending_scope(dataset))
            .cloned()
            .unwrap_or_default()
    }
    fn set_pending(&self, dataset: Uuid, deletions: BTreeMap<Uuid, Pending>) {
        let mut pending = PENDING_DELETIONS.lock().unwrap_or_else(|e| e.into_inner());
        if deletions.is_empty() {
            pending.remove(&self.pending_scope(dataset));
        } else {
            pending.insert(self.pending_scope(dataset), deletions);
        }
    }
    /// A blob written earlier in this batch, or one the cache holds.
    fn blob(&self, id: &str, written: &BTreeMap<String, Vec<u8>>) -> Result<Vec<u8>> {
        if let Some(bytes) = written.get(id) {
            return Ok(bytes.clone());
        }
        self.cache
            .blobs(&[id.to_owned()])?
            .remove(id)
            .ok_or(Failure::SnapshotIncomplete)
    }
    /// Every Markdown file directly under `snippets/`, by the id it declares
    /// (or one derived from its path). Several files claiming one id are
    /// copies: the one named for the id (`…-<id8>.md`) keeps it, else the
    /// first by name, and every other copy becomes its own snippet with an id
    /// derived from its path rather than taking the original over.
    fn plain_index(&self, snapshot: &Snapshot) -> Result<BTreeMap<Uuid, Location>> {
        let Some(tree) = &snapshot.snippets_tree else {
            return Ok(BTreeMap::new());
        };
        let files: Vec<(String, String)> = self
            .cache
            .tree_entries(tree)?
            .into_iter()
            .filter(TreeEntry::is_regular_file)
            .filter_map(|entry| {
                let name = String::from_utf8(entry.name).ok()?;
                name.to_lowercase()
                    .ends_with(git_plain::EXTENSION)
                    .then_some((name, entry.id))
            })
            .collect();
        let ids: Vec<String> = files.iter().map(|(_, blob)| blob.clone()).collect();
        let blobs = self.cache.blobs(&ids)?;
        let mut claims: BTreeMap<Uuid, Vec<(String, String)>> = BTreeMap::new();
        for (name, blob) in files {
            let bytes = blobs.get(&blob).ok_or(Failure::SnapshotIncomplete)?;
            let id = git_plain::declared_id(bytes, &plain_path(&name));
            claims.entry(id).or_default().push((name, blob));
        }
        let mut index = BTreeMap::new();
        for (id, files) in &claims {
            let mut sorted = files.clone();
            // Swift string order: code points of the canonically composed form.
            sorted.sort_by(|a, b| a.0.nfc().cmp(b.0.nfc()));
            let suffix = format!(
                "-{}{}",
                &id.hyphenated().to_string()[..8],
                git_plain::EXTENSION
            );
            let owner = sorted
                .iter()
                .find(|(name, _)| name.ends_with(&suffix))
                .unwrap_or(&sorted[0])
                .clone();
            for copy in sorted.iter().filter(|copy| copy.0 != owner.0) {
                let derived = git_plain::derived_id(&plain_path(&copy.0));
                if !claims.contains_key(&derived) && !index.contains_key(&derived) {
                    index.insert(derived, copy.clone());
                }
            }
            index.insert(*id, owner);
        }
        Ok(index
            .into_iter()
            .map(|(id, (name, blob))| {
                let readable = blobs
                    .get(&blob)
                    .is_some_and(|bytes| self.read_plain(id, &name, bytes).is_ok());
                (
                    id,
                    Location::Plain {
                        name,
                        blob,
                        readable,
                    },
                )
            })
            .collect())
    }
    /// Every record's file, by id. A ciphertext record wins over a Markdown
    /// file with the same id, so a readable file never shadows a secure
    /// snippet or a deletion.
    fn locations(&self, snapshot: &Snapshot) -> Result<BTreeMap<Uuid, Location>> {
        let mut result: BTreeMap<Uuid, Location> = self
            .records(snapshot)?
            .into_iter()
            .map(|(id, blob)| (id, Location::Record { blob }))
            .collect();
        for (id, location) in self.plain_index(snapshot)? {
            result.entry(id).or_insert(location);
        }
        Ok(result)
    }
    /// The envelope a Markdown file describes as record `id`, and its
    /// rewritten bytes when it was edited by hand. An unreadable file stops
    /// the cycle: Apple quarantines that one snippet, which this engine
    /// cannot.
    fn read_plain(
        &self,
        id: Uuid,
        name: &str,
        bytes: &[u8],
    ) -> Result<(Envelope, Option<Vec<u8>>)> {
        let (envelope, edited) = git_plain::read(bytes, &plain_path(name), Some(id))
            .map_err(|_| Failure::FileUnreadable)?;
        if merge::validate(&envelope).is_err() {
            return Err(Failure::FileUnreadable);
        }
        let normalized = if edited {
            git_plain::render(&envelope).ok()
        } else {
            None
        };
        Ok((envelope, normalized))
    }
    fn seal(&self, envelope: &Envelope) -> Result<WireRecord> {
        let key = self.plain_key()?;
        WireRecord::seal(envelope, &key.root, &key.salt).map_err(|_| Failure::FileUnreadable)
    }
    /// The engine-facing record stored at `location`.
    fn location_record(
        &self,
        id: Uuid,
        location: &Location,
        written: &BTreeMap<String, Vec<u8>>,
    ) -> Result<ServerRecord> {
        let bytes = self.blob(location.blob(), written)?;
        match location {
            Location::Record { blob } => {
                server_record(git_layout::decode_record(&bytes, id)?, blob)
            }
            Location::Plain { name, .. } => {
                let (envelope, _) = self.read_plain(id, name, &bytes)?;
                versioned(self.seal(&envelope)?, location.version())
            }
        }
    }
    /// The tombstone every device derives for a Markdown file deleted by
    /// hand: one tick after the deleted file's clock, on the foreign device,
    /// without the in-app deletion marker. With `require_file`, None when that
    /// file was unreadable and a missing object is a failure; without it (an
    /// edit naming a vanished file) the lowest-clock tombstone stands in.
    fn hand_deletion(&self, id: Uuid, blob: &str, require_file: bool) -> Result<Option<Envelope>> {
        if !self.cache.has_blob(blob) {
            return if require_file {
                Err(Failure::SnapshotIncomplete)
            } else {
                Ok(Some(git_plain::lowest_tombstone(id)))
            };
        }
        let bytes = self.blob(blob, &BTreeMap::new())?;
        let previous = git_plain::read(&bytes, &plain_path("deleted.md"), Some(id))
            .ok()
            .and_then(|(previous, _)| git_plain::tombstone(&previous).ok());
        Ok(match previous {
            Some(tombstone) => Some(tombstone),
            None if require_file => None,
            None => Some(git_plain::lowest_tombstone(id)),
        })
    }
    /// A hand deletion as the engine sees it. No file holds it yet, so its
    /// version is the local "absent" token naming the deleted file.
    fn deletion_record(&self, pending: &Pending) -> Result<ServerRecord> {
        versioned(
            self.seal(&pending.tombstone)?,
            git_layout::absent_version(&pending.blob),
        )
    }
    /// What changed between `base` and `target` (everything without a base),
    /// with hand deletions of Markdown files, in id order; and the locations
    /// `target` holds. Identity comes from each file alone.
    fn plain_items(&self, base: Option<&Snapshot>, target: &Snapshot) -> Result<Changes> {
        let head = self.locations(target)?;
        // An unreadable file is skipped: never delivered, never a deletion.
        let deliverable = |location: &Location| {
            !matches!(
                location,
                Location::Plain {
                    readable: false,
                    ..
                }
            )
        };
        let Some(base) = base else {
            let items = head
                .iter()
                .filter(|(_, location)| deliverable(location))
                .map(|(id, location)| (*id, Item::Current(location.clone())))
                .collect();
            return Ok((items, head));
        };
        if base.records_tree == target.records_tree && base.snippets_tree == target.snippets_tree {
            return Ok((vec![], head));
        }
        let old = self.locations(base)?;
        let mut items = BTreeMap::new();
        for (id, location) in &head {
            if deliverable(location) && old.get(id).map(Location::blob) != Some(location.blob()) {
                items.insert(*id, Item::Current(location.clone()));
            }
        }
        for (id, location) in old {
            if head.contains_key(&id) {
                continue;
            }
            match location {
                // Ciphertext is never removed by the apps: remote data loss.
                Location::Record { .. } => return Err(Failure::RecordRemoved),
                // A file that was unreadable when it was deleted deletes nothing.
                Location::Plain { blob, .. } => {
                    if let Some(tombstone) = self.hand_deletion(id, &blob, true)? {
                        items.insert(id, Item::Deleted(Pending { blob, tombstone }));
                    }
                }
            }
        }
        Ok((items.into_iter().collect(), head))
    }
    fn item_record(&self, id: Uuid, item: &Item) -> Result<ServerRecord> {
        match item {
            Item::Current(location) => self.location_record(id, location, &BTreeMap::new()),
            Item::Deleted(pending) => self.deletion_record(pending),
        }
    }
    /// Whether an up-to-date plain-text fetch still has deletions to record.
    fn has_pending(&self, dataset: Uuid) -> bool {
        !self.pending(dataset).is_empty()
    }
    /// One page of a plain-text fetch. A new fetch (offset 0) first tries to
    /// normalize what was edited or deleted by hand (with earlier unrecorded
    /// deletions), and then pages toward that commit, so its records carry the
    /// rewritten files' versions.
    fn plain_page(
        &mut self,
        dataset: Uuid,
        mut target: Snapshot,
        base: Option<Snapshot>,
        offset: usize,
    ) -> Result<FetchedPage> {
        self.plain_key()?;
        let (mut items, head) = self.plain_items(base.as_ref(), &target)?;
        self.unreadable_files.set(count_unreadable(&head));
        if offset == 0 {
            // Earlier deletions still unrecorded: drop the ones resolved since
            // (a tombstone landed, or the id is back), retry the rest.
            let mut pending = self.pending(dataset);
            pending.retain(|id, _| !head.contains_key(id));
            for (id, item) in &items {
                if let Item::Deleted(deleted) = item {
                    pending.insert(*id, deleted.clone());
                }
            }
            let normalized = self.normalize(&target, &items, &pending)?;
            if let Some(normalized) = normalized {
                pending.clear();
                items = self.plain_items(base.as_ref(), &normalized)?.0;
                target = normalized;
            }
            self.set_pending(dataset, pending);
        }
        if offset > items.len() || offset > 0 && offset == items.len() {
            return Err(Failure::CursorInvalid);
        }
        let end = (offset + PAGE_LIMIT).min(items.len());
        let records = items[offset..end]
            .iter()
            .map(|(id, item)| self.item_record(*id, item))
            .collect::<Result<Vec<_>>>()?;
        let has_more = end < items.len();
        let next = if has_more {
            Position::Partial {
                dataset,
                target: target.commit.clone(),
                base: base.as_ref().map(|b| b.commit.clone()),
                offset: end,
            }
        } else {
            Position::Complete {
                dataset,
                commit: target.commit.clone(),
            }
        };
        let _ = self.cache.keep(&target.commit);
        Ok(FetchedPage {
            observation: self.observation(dataset)?,
            records,
            cursor: Cursor::from_checkpoint(next.encode()).map_err(|_| Failure::CursorInvalid)?,
            full_snapshot: base.is_none(),
            has_more,
        })
    }
    /// One best-effort commit rewriting hand-edited files with fresh `sync`
    /// metadata and recording hand deletions as tombstones, so a later edit
    /// orders after this one. Every device derives the same file bytes, so
    /// racing devices converge on one commit; a device that cannot push leaves
    /// it to another. The new head's snapshot when it landed.
    fn normalize(
        &mut self,
        head: &Snapshot,
        items: &[(Uuid, Item)],
        deletions: &BTreeMap<Uuid, Pending>,
    ) -> Result<Option<Snapshot>> {
        let scope = self.pending_scope(head.dataset);
        {
            let mut paused = NORMALIZE_PAUSED.lock().unwrap_or_else(|e| e.into_inner());
            match paused.get(&scope) {
                Some(until) if Instant::now() < *until => return Ok(None),
                Some(_) => {
                    paused.remove(&scope);
                }
                None => (),
            }
        }
        let attempt = (|| -> Result<Option<String>> {
            let mut edits = BTreeMap::new();
            let mut files = 0;
            for (id, item) in items {
                if let Item::Current(Location::Plain { name, blob, .. }) = item {
                    let bytes = self.blob(blob, &BTreeMap::new())?;
                    if let Ok((_, Some(normalized))) = self.read_plain(*id, name, &bytes) {
                        edits.insert(
                            vec![git_plain::DIRECTORY.to_owned(), name.clone()],
                            Some(self.cache.write_blob(&normalized)?),
                        );
                        files += 1;
                    }
                }
            }
            for (id, pending) in deletions {
                let record = self.seal(&pending.tombstone)?;
                let (prefix, file) = git_layout::record_path(*id);
                edits.insert(
                    vec![git_layout::RECORDS.to_owned(), prefix, file],
                    Some(self.cache.write_blob(&git_layout::encode_record(&record))?),
                );
                files += 1;
            }
            if files == 0 {
                return Ok(None);
            }
            let Some(root) = self
                .edit_tree(Some(&head.tree), &edits)?
                .filter(|root| *root != head.tree)
            else {
                return Ok(None);
            };
            let commit = self.cache.write_commit(
                &root,
                Some(&head.commit),
                &git_layout::normalize_message(files),
                (self.configuration.now)(),
            )?;
            match self.cache.push(
                &self.endpoint(),
                &self.configuration.remote.ref_name(),
                Some(&head.commit),
                &commit,
            )? {
                PushOutcome::Updated => Ok(Some(commit)),
                // The branch moved (another device normalized first) or the
                // host refused; the edits still sync without the rewrite.
                PushOutcome::Rejected => Ok(None),
            }
        })();
        match attempt {
            Ok(Some(commit)) => {
                let _ = self.cache.keep(&commit);
                self.observed = None;
                Ok(Some(self.cached_snapshot(&commit)?))
            }
            Err(Failure::Git(git_repo::Failure::Authentication)) => {
                // Probably read-only access: try again in an hour, not every poll.
                NORMALIZE_PAUSED
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(scope, Instant::now() + NORMALIZE_PAUSE);
                Ok(None)
            }
            Err(Failure::Git(git_repo::Failure::Cancelled)) => {
                Err(Failure::Git(git_repo::Failure::Cancelled))
            }
            Ok(None) | Err(_) => Ok(None),
        }
    }
    /// `plan` for a plain-text library: ordinary snippets become Markdown
    /// under `snippets/`, everything else ciphertext under `records/`, and a
    /// record that changes kind moves between the two in this commit. Same
    /// CAS rule: a record's version is its current file's blob id. A file is
    /// renamed only when the snippet's name changed.
    fn plan_plain(
        &self,
        offers: &[Offer],
        head: &Snapshot,
    ) -> Result<(Vec<Outcome>, Option<String>)> {
        let key = self.plain_key()?;
        let mut current = self.locations(head)?;
        // Every Markdown file by the id it claims, including files a record
        // under `records/` shadows.
        let claims = self.plain_index(head)?;
        let mut used: HashSet<String> = match &head.snippets_tree {
            Some(tree) => self
                .cache
                .tree_entries(tree)?
                .into_iter()
                .filter_map(|entry| String::from_utf8(entry.name).ok())
                .collect(),
            None => HashSet::new(),
        };
        let mut written: BTreeMap<String, Vec<u8>> = BTreeMap::new();
        let mut edits: BTreeMap<Vec<String>, Option<String>> = BTreeMap::new();
        let mut outcomes = Vec::with_capacity(offers.len());
        let mut accepted = 0usize;
        for offer in offers {
            let record = &offer.record;
            if oversized(record) {
                outcomes.push(Outcome::Rejected {
                    error_code: ErrorCode::PayloadTooLarge,
                    retry_after_seconds: None,
                });
                continue;
            }
            let location = current.get(&record.id).cloned();
            if let Some(Location::Plain {
                readable: false, ..
            }) = location
            {
                // Never overwrite a file someone broke by hand; the edit
                // waits, pending, until the file is fixed.
                self.refused_unreadable
                    .set(self.refused_unreadable.get() + 1);
                outcomes.push(Outcome::Rejected {
                    error_code: ErrorCode::Conflict,
                    retry_after_seconds: None,
                });
                continue;
            }
            let expected = offer
                .expected_record_version
                .as_ref()
                .map(|v| v.for_checkpoint().to_owned());
            match (&location, expected.as_deref()) {
                (Some(location), expected) if expected != Some(location.version().as_str()) => {
                    outcomes.push(Outcome::Conflict {
                        authoritative_record: self
                            .location_record(record.id, location, &written)?,
                    });
                    continue;
                }
                (Some(_), _) | (None, None) => (),
                // This device saw the hand deletion before a tombstone existed.
                (None, Some(version)) if git_layout::is_absent_version(version) => (),
                (None, Some(version)) => {
                    // The edit names a Markdown file that is gone (deleted by
                    // hand): answer with the deletion every device derives and
                    // let the engine merge the two. Decided by the version's
                    // kind, never by what the disposable cache still holds.
                    if let Some(blob) = git_layout::markdown_blob(version) {
                        let tombstone = self
                            .hand_deletion(record.id, blob, false)?
                            .ok_or(Failure::FileUnreadable)?;
                        let pending = Pending {
                            blob: blob.to_owned(),
                            tombstone,
                        };
                        let authoritative_record = self.deletion_record(&pending)?;
                        let mut all = self.pending(head.dataset);
                        all.insert(record.id, pending);
                        self.set_pending(head.dataset, all);
                        outcomes.push(Outcome::Conflict {
                            authoritative_record,
                        });
                        continue;
                    }
                    // Tombstones are saves, so a ciphertext version with no
                    // file was removed by hand: remote data loss for review.
                    return Err(Failure::RecordRemoved);
                }
            }
            let rendered = record.open(&key.root, &key.salt).ok().and_then(|envelope| {
                let bytes = git_plain::render(&envelope).ok()?;
                Some((envelope, bytes))
            });
            let (target, bytes) = match rendered {
                Some((envelope, bytes)) => {
                    let new_name = envelope.fields.as_ref().map_or("", |f| f.name.as_str());
                    let kept = match &location {
                        Some(Location::Plain { name, blob, .. }) => {
                            let renamed = self
                                .blob(blob, &written)
                                .is_ok_and(|old| git_plain::renamed(&old, new_name));
                            (!renamed).then(|| name.clone())
                        }
                        _ => None,
                    };
                    // A Markdown file restored by hand while a tombstone
                    // shadowed it still claims this id. Overwrite it, or it
                    // would keep the id and this snippet's file would become
                    // a copy.
                    let shadowed = match (&kept, &location, claims.get(&record.id)) {
                        (None, Some(Location::Record { .. }), Some(Location::Plain { name, .. }))
                            if !current.values().any(|other| {
                                matches!(other, Location::Plain { name: used_name, .. } if used_name == name)
                            }) =>
                        {
                            Some(name.clone())
                        }
                        _ => None,
                    };
                    let name = match kept.or(shadowed) {
                        Some(name) => name,
                        None => {
                            if let Some(Location::Plain { name, .. }) = &location {
                                used.remove(name);
                            }
                            let mut name = git_plain::file_name(new_name, record.id);
                            let mut suffix = 2;
                            while used.contains(&name) {
                                let stem = &name[..name.len() - git_plain::EXTENSION.len()];
                                name = format!("{stem}-{suffix}{}", git_plain::EXTENSION);
                                suffix += 1;
                            }
                            name
                        }
                    };
                    used.insert(name.clone());
                    let blob = self.cache.write_blob(&bytes)?;
                    (
                        Location::Plain {
                            name,
                            blob,
                            readable: true,
                        },
                        bytes,
                    )
                }
                None => {
                    let bytes = git_layout::encode_record(record);
                    let blob = self.cache.write_blob(&bytes)?;
                    (Location::Record { blob }, bytes)
                }
            };
            written.insert(target.blob().to_owned(), bytes);
            if let Some(location) = &location
                && location.path(record.id) != target.path(record.id)
            {
                edits.insert(location.path(record.id), None);
                if let Location::Plain { name, .. } = location {
                    used.remove(name);
                }
            }
            edits.insert(target.path(record.id), Some(target.blob().to_owned()));
            accepted += 1;
            outcomes.push(Outcome::Accepted {
                record_version: RecordVersion::from_checkpoint(target.version())
                    .map_err(|_| Failure::RecordMalformed)?,
                revision: record.rev.clone(),
            });
            current.insert(record.id, target);
        }
        if edits.is_empty() {
            return Ok((outcomes, None));
        }
        let Some(root) = self
            .edit_tree(Some(&head.tree), &edits)?
            .filter(|root| *root != head.tree)
        else {
            // Every accepted record already held identical bytes.
            return Ok((outcomes, None));
        };
        let commit = self.cache.write_commit(
            &root,
            Some(&head.commit),
            &git_layout::sync_message(accepted),
            (self.configuration.now)(),
        )?;
        Ok((outcomes, Some(commit)))
    }
    /// The id of `tree` (None: empty) with each path set to its blob or, for
    /// None, removed; a directory left empty disappears with it. Unrelated
    /// entries are kept byte-for-byte.
    fn edit_tree(
        &self,
        tree: Option<&str>,
        edits: &BTreeMap<Vec<String>, Option<String>>,
    ) -> Result<Option<String>> {
        let mut entries = match tree {
            Some(tree) => self.cache.tree_entries(tree)?,
            None => vec![],
        };
        let mut children: BTreeMap<String, BTreeMap<Vec<String>, Option<String>>> = BTreeMap::new();
        for (components, blob) in edits {
            let Some((first, rest)) = components.split_first() else {
                continue;
            };
            if rest.is_empty() {
                entries.retain(|e| e.name != first.as_bytes());
                if let Some(blob) = blob {
                    entries.push(blob_entry(first.as_bytes(), blob));
                }
            } else {
                children
                    .entry(first.clone())
                    .or_default()
                    .insert(rest.to_vec(), blob.clone());
            }
        }
        for (name, nested) in children {
            let existing = entries
                .iter()
                .find(|e| e.name == name.as_bytes() && e.is_tree())
                .map(|e| e.id.clone());
            let subtree = self.edit_tree(existing.as_deref(), &nested)?;
            entries.retain(|e| e.name != name.as_bytes());
            if let Some(subtree) = subtree {
                entries.push(tree_entry(name.as_bytes(), &subtree));
            }
        }
        if entries.is_empty() {
            return Ok(None);
        }
        Ok(Some(self.cache.write_tree(&entries)?))
    }
}
fn plain_path(name: &str) -> String {
    format!("{}/{name}", git_plain::DIRECTORY)
}
fn count_unreadable(locations: &BTreeMap<Uuid, Location>) -> usize {
    locations
        .values()
        .filter(|l| {
            matches!(
                l,
                Location::Plain {
                    readable: false,
                    ..
                }
            )
        })
        .count()
}

impl receiver::Remote for GitTransport {
    fn preflight(&mut self) -> RemoteResult<Observation> {
        let result = self.observe().and_then(|dataset| self.observation(dataset));
        self.remember(result).map_err(Failure::to_cloud)
    }
    fn fetch(&mut self, cursor: Option<&Cursor>) -> RemoteResult<FetchedPage> {
        let result = self.fetch_inner(cursor);
        self.remember(result).map_err(Failure::to_cloud)
    }
}
impl sender::Remote for GitTransport {
    fn preflight(&mut self) -> RemoteResult<SendObservation> {
        Ok(SendObservation {
            observation: receiver::Remote::preflight(self)?,
            role: Role::Writer,
        })
    }
    fn submit(&mut self, offers: &[Offer]) -> RemoteResult<sender::Reply> {
        let result = self.submit_inner(offers);
        let outcomes = self.remember(result).map_err(Failure::to_cloud)?;
        let dataset = self
            .pinned
            .ok_or(Failure::NotInitialized)
            .map_err(Failure::to_cloud)?;
        let partial = outcomes
            .iter()
            .any(|o| !matches!(o, Outcome::Accepted { .. }));
        Ok(sender::Reply {
            observation: self.observation(dataset).map_err(Failure::to_cloud)?,
            outcomes,
            partial,
        })
    }
}

fn server_record(record: WireRecord, blob: &str) -> Result<ServerRecord> {
    versioned(record, git_layout::record_version(blob))
}
fn versioned(record: WireRecord, version: String) -> Result<ServerRecord> {
    let version = RecordVersion::from_checkpoint(version).map_err(|_| Failure::RecordMalformed)?;
    ServerRecord::from_parts(record, version).map_err(|_| Failure::RecordMalformed)
}
/// Rejected outright when it cannot be a record at all: empty, over 900,000
/// bytes, or a revision outside 1...256 bytes.
fn oversized(record: &WireRecord) -> bool {
    record.blob.is_empty()
        || record.blob.len() > wire::MAX_BLOB_BYTES
        || !(1..=git_layout::MAX_REVISION_BYTES).contains(&record.rev.len())
}
fn blob_entry(name: &[u8], id: &str) -> TreeEntry {
    TreeEntry {
        mode: "100644".into(),
        kind: "blob".into(),
        id: id.into(),
        name: name.to_vec(),
    }
}
fn tree_entry(name: &[u8], id: &str) -> TreeEntry {
    TreeEntry {
        mode: "040000".into(),
        kind: "tree".into(),
        id: id.into(),
        name: name.to_vec(),
    }
}
/// At most `MAXIMUM_COMMIT_BLOB_BYTES` of ciphertext per commit.
fn chunks(offers: &[Offer]) -> Vec<(usize, usize)> {
    let mut result = vec![];
    let mut start = 0;
    let mut bytes = 0;
    for (index, offer) in offers.iter().enumerate() {
        let size = offer.record.blob.len();
        if index > start && bytes + size > MAXIMUM_COMMIT_BLOB_BYTES {
            result.push((start, index));
            start = index;
            bytes = 0;
        }
        bytes += size;
    }
    result.push((start, offers.len()));
    result
}
/// `keys/` plus plain, non-hidden components, exactly like the Apple rule.
fn auxiliary_path(path: &str) -> Result<Vec<String>> {
    let components: Vec<&str> = path.split('/').collect();
    if !(2..=4).contains(&components.len())
        || components[0] != git_layout::KEYS
        || !components.iter().all(|c| {
            !c.is_empty()
                && !c.starts_with('.')
                && c.len() <= 128
                && c.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        })
    {
        return Err(Failure::InvalidPath);
    }
    Ok(components.into_iter().map(str::to_owned).collect())
}
fn auxiliary_paths<'a>(files: &[(&str, &'a [u8])]) -> Result<Vec<(Vec<String>, &'a [u8])>> {
    files
        .iter()
        .map(|(path, bytes)| Ok((auxiliary_path(path)?, *bytes)))
        .collect()
}
