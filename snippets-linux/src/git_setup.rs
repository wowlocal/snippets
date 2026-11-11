//! Git sync ownership on this device: the non-secret configuration, the
//! Secret Service key/token slots, create/join/recovery flows, the reviewed
//! journal switch into a Git library, and bounded sync cycles.
//!
//! Every function is blocking and runs off the GTK thread (a worker or the
//! CLI). Nothing here logs: failures are closed codes, and repository
//! locations, tokens, recovery codes and snippet data never reach diagnostics.
use crate::{
    account_review, auto_sync,
    bootstrap::Bundle,
    crypto::RootKey,
    deletion_review,
    git_layout::{self, Mode},
    git_location::{self, HttpCredential, Location, Remote},
    git_recovery::{self, Kit},
    git_repo,
    git_transport::{self, Configuration, GitTransport, PlainKey, RepositoryState},
    journal::{self, Checkpoint},
    model::{self, Library},
    receiver, secret_store,
    secret_store::{Backend, Locked, Slot, Store},
    snapshot_review,
    sync::{self, Direction, Limits},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use uuid::Uuid;
use zeroize::Zeroizing;

pub const CONFIG_FILE: &str = "git-sync.json";
pub const CACHE_DIRECTORY: &str = "GitSync";
const MAX_CONFIG_BYTES: usize = 8 * 1024;
const MAX_KEYS: usize = 32;
pub const KEY_EPOCH: u64 = 1;
/// Test harnesses may allow plain HTTP to literal loopback addresses in debug
/// builds, like the Apple `gitAllowsInsecureLoopback`. Release builds ignore
/// it, and nothing else is relaxed by it.
pub const INSECURE_LOOPBACK_ENV: &str = "SNIPPETS_GIT_ALLOW_INSECURE_LOOPBACK";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    InvalidLocation,
    InvalidBranch,
    InvalidUsername,
    MissingToken,
    /// The branch holds files that are not a Snippets library.
    ForeignBranch,
    NotALibrary,
    /// Another device created a library on this branch a moment ago.
    LibraryExists,
    LibraryChanged,
    RecoveryCodeRequired,
    InvalidRecoveryCode,
    IncorrectRecoveryCode,
    RecoveryUnavailable,
    KeyUnavailable,
    KeyStoreFull,
    NotConfigured,
    /// Git is connected to a different repository or branch on this device.
    OtherLibraryActive,
    Transport(git_transport::Failure),
    Secret(secret_store::Failure),
    Storage,
    /// Known snippets are missing from the local library without a recorded
    /// deletion; switching libraries would lose that intent.
    LocalAbsence,
    /// The library changed during a reviewed switch. Try again.
    Changed,
    RetentionFull,
    /// The local sync state is unreadable or needs recovery.
    Journal,
    /// The local sync state belongs to another library.
    ScopeReview,
    /// The configuration changed or the operation was cancelled mid-cycle.
    Interrupted,
    NoReview,
    /// Joining a plain-text library needs explicit consent: this device's
    /// ordinary snippets become readable in the repository and its history.
    PlainTextConsentRequired,
    /// Another part of Snippets is changing the library or recovering it;
    /// sync tries again.
    LibraryBusy,
    /// Plain text was chosen for a repository anyone can read over HTTPS.
    PublicRepository,
    /// Plain text was chosen where Snippets could not check the repository's
    /// visibility, without the user's word that it is private.
    VisibilityUnknown,
    /// The library publishes its secure-snippet key under the recovery code
    /// (`keys/vault.json`). Linux cannot rewrap it yet, and a code that opened
    /// the library without its secure snippets would be worse than none.
    VaultRecoveryCode,
}
pub type Result<T> = std::result::Result<T, Failure>;
impl From<secret_store::Failure> for Failure {
    fn from(value: secret_store::Failure) -> Self {
        Self::Secret(value)
    }
}
impl From<git_transport::Failure> for Failure {
    fn from(value: git_transport::Failure) -> Self {
        Self::Transport(value)
    }
}
impl From<git_location::Failure> for Failure {
    fn from(value: git_location::Failure) -> Self {
        match value {
            git_location::Failure::InvalidLocation => Self::InvalidLocation,
            git_location::Failure::InvalidBranch => Self::InvalidBranch,
            git_location::Failure::InvalidUsername => Self::InvalidUsername,
            git_location::Failure::InvalidToken => Self::MissingToken,
        }
    }
}
impl Failure {
    /// A stable closed code for the CLI and tests. Never includes user data.
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidLocation => "invalid_location",
            Self::InvalidBranch => "invalid_branch",
            Self::InvalidUsername => "invalid_username",
            Self::MissingToken => "missing_token",
            Self::ForeignBranch => "foreign_branch",
            Self::NotALibrary => "not_a_library",
            Self::LibraryExists => "library_exists",
            Self::LibraryChanged => "library_changed",
            Self::RecoveryCodeRequired => "recovery_code_required",
            Self::InvalidRecoveryCode => "invalid_recovery_code",
            Self::IncorrectRecoveryCode => "incorrect_recovery_code",
            Self::RecoveryUnavailable => "recovery_unavailable",
            Self::KeyUnavailable => "key_unavailable",
            Self::KeyStoreFull => "key_store_full",
            Self::NotConfigured => "not_configured",
            Self::OtherLibraryActive => "other_library_active",
            Self::Transport(failure) => failure.code(),
            Self::Secret(_) => "secret_service",
            Self::Storage => "local_storage",
            Self::LocalAbsence => "local_absence",
            Self::Changed => "changed",
            Self::RetentionFull => "retention_full",
            Self::Journal => "sync_state",
            Self::ScopeReview => "scope_review",
            Self::Interrupted => "interrupted",
            Self::NoReview => "no_review",
            Self::PlainTextConsentRequired => "plain_text_consent_required",
            Self::LibraryBusy => "library_busy",
            Self::PublicRepository => "public_repository",
            Self::VisibilityUnknown => "visibility_unknown",
            Self::VaultRecoveryCode => "vault_recovery_code",
        }
    }
    pub fn message(self) -> &'static str {
        use git_repo::Failure as G;
        use git_transport::Failure as T;
        match self {
            Self::InvalidLocation => {
                "Enter the repository address, such as https://github.com/you/snippets-library or git@github.com:you/snippets-library.git."
            }
            Self::InvalidBranch => "Enter a valid branch name, such as main.",
            Self::InvalidUsername => {
                "Enter the user name for the access token. It is optional for GitHub and GitLab."
            }
            Self::MissingToken => {
                "Enter an access token with read and write access to the repository’s contents."
            }
            Self::ForeignBranch | Self::Transport(T::NotALibrary) => {
                "This branch already has files, such as a README. Snippets can use its own branch in this repository instead."
            }
            Self::NotALibrary | Self::Transport(T::NotInitialized) => {
                "This branch does not hold a Snippets library."
            }
            Self::LibraryExists => {
                "Another device created a Snippets library in this repository a moment ago. Connect to it instead."
            }
            Self::LibraryChanged | Self::Transport(T::LibraryReplaced) => {
                "The repository now holds a different Snippets library, or its keys were replaced on another device. Check it again and reconnect with the newest recovery code."
            }
            Self::RecoveryCodeRequired => {
                "Enter this library’s recovery code. It was shown when the library was created."
            }
            Self::InvalidRecoveryCode => "That is not a valid recovery code. Check it for typos.",
            Self::IncorrectRecoveryCode => "That recovery code does not open this library.",
            Self::RecoveryUnavailable => {
                "This library has no usable recovery code in the repository. Connect from a device that already has its key."
            }
            Self::KeyUnavailable => "This device does not have the library’s key.",
            Self::KeyStoreFull => "This device holds too many Git library keys.",
            Self::NotConfigured => "No Git repository is connected on this device.",
            Self::OtherLibraryActive => {
                "Git is syncing with another repository or branch. Remove it from this computer before connecting a different one."
            }
            Self::Transport(T::Git(G::Authentication)) => {
                "The Git host did not accept the access token or SSH key, or it cannot write to this repository."
            }
            Self::Transport(T::Git(G::RepositoryNotFound)) => {
                "Repository not found. Check the address, and that your token or SSH key can see this private repository."
            }
            Self::Transport(T::Git(G::HostKeyUnverified)) => {
                "The Git host’s SSH key isn’t in known_hosts. Connect once with ssh -T in a terminal to verify it, then try again."
            }
            Self::Transport(T::Git(G::RateLimited) | T::Contended) => {
                "The Git host is limiting requests. Try again shortly."
            }
            Self::Transport(T::Git(G::Unreachable)) => {
                "Couldn’t reach the Git host. Check the address and your connection, then try again."
            }
            Self::Transport(T::Git(G::Unsupported)) => {
                "This address isn’t a git repository Snippets can use. Check you copied the clone address."
            }
            Self::Transport(T::SchemaUnsupported) => {
                "This library was written by a newer version of Snippets. Update Snippets to use it."
            }
            Self::Transport(T::Git(G::GitTooOld)) => {
                "Git sync needs git 2.32 or later. Update git, then try again."
            }
            Self::Transport(T::Git(G::SshTooOld)) => {
                "Git sync over SSH needs OpenSSH 8.7 or later. Update ssh, or use the HTTPS address with a token."
            }
            Self::Transport(T::Git(G::PushTooLarge)) => {
                "The Git host refused the upload as too large. If a proxy sits in front of it, raise its request size limit."
            }
            Self::Transport(T::Git(G::GitUnavailable)) => "Install git to use Git sync.",
            Self::Transport(T::Git(G::Cancelled)) | Self::Interrupted => {
                "The Git operation was interrupted."
            }
            Self::Transport(T::PushRejected | T::Git(G::PushRefused)) => {
                "The Git host refused the change. Check that the branch is not protected and that you can write to it."
            }
            Self::Transport(T::DatasetReset | T::RecordRemoved) => {
                "The remote library was reset or a record was removed by hand. Sync stopped; reconnect to review it."
            }
            Self::Transport(T::RecordMalformed) => {
                "A record in the repository is damaged. Sync stopped to protect your library."
            }
            Self::Transport(T::FileUnreadable) => {
                "A snippet file in the repository cannot be read: check its front matter (the lines between ---), or that it is UTF-8 text under 1 MB. Fix it in the repository; sync stopped to protect your library."
            }
            Self::Transport(T::KeyRequired) => "This device does not have the library’s key.",
            Self::Transport(T::ModeChanged) => {
                "The repository now stores this library differently (encrypted or plain text) than you agreed to. Sync stopped; connect again to review it."
            }
            Self::Transport(_) => "The Git repository could not be used.",
            Self::Secret(_) => "The login keyring is unavailable or locked.",
            Self::Storage => "This device could not save the Git settings.",
            Self::LocalAbsence => {
                "Some synchronized snippets are missing locally without a recorded deletion. Review them with the previous sync provider first."
            }
            Self::Changed => "The library changed while connecting. Try again.",
            Self::RetentionFull => {
                "Too many retained sync-state reviews. Finish or remove them first."
            }
            Self::Journal => "The local sync state needs recovery before Git can sync.",
            Self::ScopeReview => {
                "This device’s sync state belongs to another library. Reconnect the repository to review the switch."
            }
            Self::NoReview => "Nothing needs review.",
            Self::LibraryBusy => "The library is busy. Sync will try again.",
            Self::PublicRepository => {
                "This repository is public. Anyone on the internet could read plain-text snippets. Make it private, or create an encrypted library."
            }
            Self::VisibilityUnknown => VISIBILITY_UNKNOWN_MESSAGE,
            Self::VaultRecoveryCode => {
                "This library’s recovery code also opens its secure snippets, which Snippets for Linux cannot do yet. Create the new recovery code in Snippets on a Mac, iPhone or iPad."
            }
            Self::PlainTextConsentRequired => {
                "This library stores ordinary snippets as readable Markdown files. Confirm joining it: this device’s ordinary snippets will be readable by anyone with access to the repository, and stay in its history."
            }
        }
    }
}

/// The connected plain-text library's status line, shared with Apple.
pub const PLAIN_TEXT_STATUS: &str = "Ordinary snippets are saved as readable Markdown files in your Git repository. Secure snippets stay encrypted.";

/// The hosts whose token pages and user names Snippets knows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Host {
    GitHub,
    GitLab,
    Other,
}
impl Host {
    pub fn of(location: &Location) -> Self {
        let identity = location.canonical_identity();
        match identity.split('/').next() {
            Some("github.com") => Self::GitHub,
            Some("gitlab.com") => Self::GitLab,
            _ => Self::Other,
        }
    }
}
/// How to make an access token for the repository the user typed: the text
/// shared with Apple and, for GitHub and GitLab, the page that creates one.
pub fn token_help(repository: &str) -> (String, Option<String>) {
    let location = Location::parse(repository, false).ok();
    match location.as_ref().map(Host::of) {
        Some(Host::GitHub) => (
            "Create a fine-grained token: Repository access “Only select repositories” → this repository; Permissions “Contents: Read and write”. When it expires, Snippets asks for a new one.".into(),
            Some("https://github.com/settings/personal-access-tokens/new".into()),
        ),
        Some(Host::GitLab) => {
            let identity = location.as_ref().map(Location::canonical_identity).unwrap_or_default();
            let path = identity.split_once('/').map_or("", |(_, path)| path);
            (
                "Create a project access token with the read_repository and write_repository scopes (Developer role, or Maintainer if the branch is protected).".into(),
                Some(format!("https://gitlab.com/{path}/-/settings/access_tokens")),
            )
        }
        _ => (
            "Create a token that can read and write this repository. On Gitea and Forgejo, give it write:repository and use your account name as the user name.".into(),
            None,
        ),
    }
}
/// Whether anyone can clone a repository without signing in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Visibility {
    Public,
    Private,
    /// Snippets could not tell; a plain-text library needs the user's word.
    Unknown,
}

/// The confirmation a plain-text library needs when the visibility is
/// unknown, shared with Apple.
pub const VISIBILITY_UNKNOWN_TITLE: &str = "Couldn’t Check the Repository";
pub const VISIBILITY_UNKNOWN_MESSAGE: &str = "Snippets couldn’t check whether this repository is private. Create a plain-text library only if it is private: anyone who can read the repository can read your ordinary snippets.";

/// Same-origin redirects followed before the answer is unknown.
const VISIBILITY_REDIRECTS: usize = 3;

/// Apple `visibility(of:)`: one anonymous smart-HTTP advertisement request
/// (no credentials, cookies or cache), at the address itself or, for SSH,
/// only at a well-known forge (`Location::public_probe_base`). A 200 with the
/// upload-pack advertisement is public; 401, 403 or 404 private; anything
/// else (an error, a timeout, another status, a redirect leaving the scheme,
/// host and port) unknown. Plain HTTP only for the loopback test seam.
pub fn visibility(location: &Location, insecure_loopback: bool) -> Visibility {
    let Some(base) = location.public_probe_base() else {
        return Visibility::Unknown;
    };
    let Ok(origin) = url::Url::parse(&format!(
        "{}/info/refs?service=git-upload-pack",
        base.trim_end_matches('/')
    )) else {
        return Visibility::Unknown;
    };
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .https_only(!insecure_loopback)
        .max_redirects(0)
        .http_status_as_error(false)
        .max_response_header_size(16 * 1024)
        .timeout_global(Some(std::time::Duration::from_secs(10)))
        .user_agent("git/2.0 (Snippets)")
        .build()
        .into();
    let same_origin = |url: &url::Url| {
        url.scheme() == origin.scheme()
            && url.host_str().map(str::to_ascii_lowercase)
                == origin.host_str().map(str::to_ascii_lowercase)
            && url.port_or_known_default() == origin.port_or_known_default()
            && url.username().is_empty()
            && url.password().is_none()
    };
    let mut url = origin.clone();
    for _ in 0..=VISIBILITY_REDIRECTS {
        let Ok(response) = agent.get(url.as_str()).call() else {
            return Visibility::Unknown;
        };
        let header = |name: &str| {
            response
                .headers()
                .get(name)
                .and_then(|value| value.to_str().ok())
                .map(str::to_owned)
        };
        match response.status().as_u16() {
            200 => {
                let mime = header("content-type").map(|value| {
                    value
                        .split(';')
                        .next()
                        .unwrap_or("")
                        .trim()
                        .to_ascii_lowercase()
                });
                return if mime.as_deref() == Some("application/x-git-upload-pack-advertisement") {
                    Visibility::Public
                } else {
                    Visibility::Unknown
                };
            }
            401 | 403 | 404 => return Visibility::Private,
            301 | 302 | 303 | 307 | 308 => {
                match header("location").and_then(|target| url.join(&target).ok()) {
                    Some(next) if same_origin(&next) => url = next,
                    _ => return Visibility::Unknown,
                }
            }
            _ => return Visibility::Unknown,
        }
    }
    Visibility::Unknown
}

/// What the user typed. The token is blank for SSH, or to reuse a saved one.
#[derive(Clone)]
pub struct Form {
    pub repository: String,
    pub branch: String,
    pub username: String,
    pub token: Zeroizing<String>,
}

/// The saved, non-secret configuration.
#[derive(Clone, PartialEq, Eq)]
pub struct Settings {
    pub repository: String,
    pub branch: String,
    pub username: Option<String>,
    pub dataset: Uuid,
    pub automatic: bool,
    /// How the library stores records, as its manifest said at connection.
    /// Display only: the transport always follows the manifest itself.
    pub mode: Mode,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredSettings {
    schema_version: u8,
    repository: String,
    branch: String,
    username: Option<String>,
    #[serde(rename = "datasetID")]
    dataset_id: Uuid,
    automatic: bool,
    /// Absent for an encrypted library, so those files stay readable by
    /// builds that predate plain-text libraries (which refuse such a library).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    record_profile: Option<String>,
}
impl Settings {
    pub fn read(root: &Path) -> Result<Option<Self>> {
        Ok(read_config(root)?.map(|(settings, _)| settings))
    }
    fn write(&self, root: &Path) -> Result<()> {
        let bytes = serde_json::to_vec(&StoredSettings {
            schema_version: 1,
            repository: self.repository.clone(),
            branch: self.branch.clone(),
            username: self.username.clone(),
            dataset_id: self.dataset,
            automatic: self.automatic,
            record_profile: (self.mode != Mode::Encrypted).then(|| self.mode.profile().to_owned()),
        })
        .map_err(|_| Failure::Storage)?;
        let library = Library::prepare(root.into()).map_err(|_| Failure::Storage)?;
        let _guard = library.lock().map_err(|_| Failure::Storage)?;
        model::atomic_write(&root.join(CONFIG_FILE), &bytes).map_err(|_| Failure::Storage)
    }
    pub fn remote(&self, environment: &Environment) -> Result<Remote> {
        let location = Location::parse(&self.repository, environment.insecure_loopback)?;
        Ok(Remote::new(location, &self.branch)?)
    }
    /// `host/path` for display; never a token or a user name.
    pub fn display_location(&self, environment: &Environment) -> String {
        self.remote(environment)
            .map(|r| r.canonical_location())
            .unwrap_or_default()
    }
}
fn read_config(root: &Path) -> Result<Option<(Settings, Vec<u8>)>> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(root.join(CONFIG_FILE))
    {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Ok(file) => file,
        Err(_) => return Err(Failure::Storage),
    };
    let metadata = file.metadata().map_err(|_| Failure::Storage)?;
    if !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.len() > MAX_CONFIG_BYTES as u64
    {
        return Err(Failure::Storage);
    }
    let mut bytes = Vec::new();
    file.take(MAX_CONFIG_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure::Storage)?;
    let stored: StoredSettings = serde_json::from_slice(&bytes).map_err(|_| Failure::Storage)?;
    let mode = match stored.record_profile.as_deref() {
        None => Mode::Encrypted,
        Some(profile) => Mode::from_profile(profile).ok_or(Failure::Storage)?,
    };
    if stored.schema_version != 1
        || stored.dataset_id.is_nil()
        || !git_location::valid_branch(&stored.branch)
        || stored
            .username
            .as_deref()
            .is_some_and(|u| !git_location::valid_username(u))
    {
        return Err(Failure::Storage);
    }
    Ok(Some((
        Settings {
            repository: stored.repository,
            branch: stored.branch,
            username: stored.username,
            dataset: stored.dataset_id,
            automatic: stored.automatic,
            mode,
        },
        bytes,
    )))
}

/// Where and how this device runs Git. Production uses `Environment::new`.
#[derive(Clone)]
pub struct Environment {
    pub root: PathBuf,
    pub git: git_repo::Options,
    pub insecure_loopback: bool,
}
impl Environment {
    pub fn new(root: PathBuf) -> Self {
        // A test seam only: release builds ignore it.
        let insecure_loopback = cfg!(debug_assertions)
            && std::env::var_os(INSECURE_LOOPBACK_ENV).is_some_and(|v| v == "1");
        Self {
            root,
            git: git_repo::Options {
                allow_insecure_loopback: insecure_loopback,
                ..Default::default()
            },
            insecure_loopback,
        }
    }
    pub fn with_cancel(mut self, cancel: Arc<AtomicBool>) -> Self {
        self.git.cancel = Some(cancel);
        self
    }
    fn cancelled(&self) -> bool {
        self.git
            .cancel
            .as_ref()
            .is_some_and(|c| c.load(Ordering::SeqCst))
    }
    fn cache(&self, remote: &Remote) -> PathBuf {
        let digest = git_layout::account_digest(remote);
        let name: String = digest[..16].iter().map(|b| format!("{b:02x}")).collect();
        self.root.join(CACHE_DIRECTORY).join(format!("{name}.git"))
    }
    /// A setup transport: no library, mode or key pinned.
    fn setup_transport(
        &self,
        remote: &Remote,
        credential: Option<HttpCredential>,
    ) -> Result<GitTransport> {
        self.transport(remote, credential, None)
    }
    /// `agreed` is the data plane's library, the storage mode this device
    /// agreed to, and the library key. The key reaches the transport only for
    /// a plain-text library, which needs it to read and write Markdown files.
    fn transport(
        &self,
        remote: &Remote,
        credential: Option<HttpCredential>,
        agreed: Option<(Uuid, Mode, &Bundle)>,
    ) -> Result<GitTransport> {
        Ok(GitTransport::new(Configuration {
            remote: remote.clone(),
            credential,
            cache: self.cache(remote),
            expected_dataset: agreed.map(|(dataset, _, _)| dataset),
            options: self.git.clone(),
            now: git_transport::now,
            plain_key: agreed
                .filter(|(_, mode, _)| *mode == Mode::PlainText)
                .map(|(_, _, bundle)| PlainKey::from_material(bundle.for_secure_storage())),
            expected_mode: agreed.map(|(_, mode, _)| mode),
        })?)
    }
}

// MARK: - Secret Service slots

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredKeys {
    schema_version: u8,
    entries: Vec<StoredKey>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredKey {
    scope: String,
    key: String,
}
impl Drop for StoredKey {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.key.zeroize();
    }
}
fn read_keys<B: Backend>(
    owner: &mut Locked<'_, B>,
) -> Result<(Option<Zeroizing<Vec<u8>>>, StoredKeys)> {
    let raw = owner.read(Slot::GitLibraryKeys)?;
    let keys = match &raw {
        None => StoredKeys {
            schema_version: 1,
            entries: vec![],
        },
        Some(bytes) => {
            let keys: StoredKeys = serde_json::from_slice(bytes)
                .map_err(|_| Failure::Secret(secret_store::Failure::InvalidValue))?;
            if keys.schema_version != 1 || keys.entries.len() > MAX_KEYS {
                return Err(Failure::Secret(secret_store::Failure::InvalidValue));
            }
            keys
        }
    };
    Ok((raw, keys))
}
fn library_key<B: Backend>(owner: &mut Locked<'_, B>, scope: &str) -> Result<Option<Bundle>> {
    let (_, keys) = read_keys(owner)?;
    let Some(entry) = keys.entries.iter().find(|e| e.scope == scope) else {
        return Ok(None);
    };
    let material = Zeroizing::new(
        STANDARD
            .decode(&entry.key)
            .map_err(|_| Failure::Secret(secret_store::Failure::InvalidValue))?,
    );
    Ok(Some(Bundle::from_material(&material).map_err(|_| {
        Failure::Secret(secret_store::Failure::InvalidValue)
    })?))
}
fn install_key<B: Backend>(owner: &mut Locked<'_, B>, scope: &str, bundle: &Bundle) -> Result<()> {
    let (raw, mut keys) = read_keys(owner)?;
    let encoded = STANDARD.encode(bundle.for_secure_storage());
    if let Some(entry) = keys.entries.iter().find(|e| e.scope == scope) {
        // One scope holds exactly one library's key; never replace it silently.
        return if entry.key == encoded {
            Ok(())
        } else {
            Err(Failure::KeyUnavailable)
        };
    }
    if keys.entries.len() >= MAX_KEYS {
        return Err(Failure::KeyStoreFull);
    }
    keys.entries.push(StoredKey {
        scope: scope.to_owned(),
        key: encoded,
    });
    let bytes = Zeroizing::new(serde_json::to_vec(&keys).map_err(|_| Failure::Storage)?);
    owner.replace(
        Slot::GitLibraryKeys,
        raw.as_deref().map(Vec::as_slice),
        Some(&bytes),
    )?;
    Ok(())
}
fn forget_key<B: Backend>(owner: &mut Locked<'_, B>, scope: &str) -> Result<()> {
    let (raw, mut keys) = read_keys(owner)?;
    let before = keys.entries.len();
    keys.entries.retain(|e| e.scope != scope);
    if keys.entries.len() == before {
        return Ok(());
    }
    let bytes = Zeroizing::new(serde_json::to_vec(&keys).map_err(|_| Failure::Storage)?);
    let value = (!keys.entries.is_empty()).then_some(bytes.as_slice());
    owner.replace(
        Slot::GitLibraryKeys,
        raw.as_deref().map(Vec::as_slice),
        value,
    )?;
    Ok(())
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredCredential {
    schema_version: u8,
    location: String,
    username: String,
    token: String,
}
impl Drop for StoredCredential {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.token.zeroize();
    }
}
/// The saved token, only for the exact normalized address (scheme, host, port,
/// path) and user name it was saved for, like the Apple binding.
fn stored_token<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &Remote,
    username: &str,
) -> Result<Option<Zeroizing<String>>> {
    let Some(bytes) = owner.read(Slot::GitCredential)? else {
        return Ok(None);
    };
    let stored: StoredCredential = serde_json::from_slice(&bytes)
        .map_err(|_| Failure::Secret(secret_store::Failure::InvalidValue))?;
    if stored.schema_version != 1 {
        return Err(Failure::Secret(secret_store::Failure::InvalidValue));
    }
    Ok(
        (stored.location == remote.location.spec() && stored.username == username)
            .then(|| Zeroizing::new(stored.token.clone())),
    )
}
fn save_credential<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &Remote,
    credential: Option<&HttpCredential>,
) -> Result<()> {
    let current = owner.read(Slot::GitCredential)?;
    let value = credential
        .map(|c| {
            serde_json::to_vec(&StoredCredential {
                schema_version: 1,
                location: remote.location.spec(),
                username: c.username().to_owned(),
                token: c.token().to_owned(),
            })
            .map(Zeroizing::new)
        })
        .transpose()
        .map_err(|_| Failure::Storage)?;
    if current.as_deref() == value.as_deref() {
        return Ok(());
    }
    owner.replace(
        Slot::GitCredential,
        current.as_deref().map(Vec::as_slice),
        value.as_deref().map(Vec::as_slice),
    )?;
    Ok(())
}

// MARK: - Validation

struct Validated {
    remote: Remote,
    credential: Option<HttpCredential>,
}
/// A blank token reuses the saved one only for the same location and user.
fn validate<B: Backend>(
    environment: &Environment,
    owner: &mut Locked<'_, B>,
    form: &Form,
) -> Result<Validated> {
    let location = Location::parse(&form.repository, environment.insecure_loopback)?;
    let remote = Remote::new(location, form.branch.trim())?;
    if remote.location.is_ssh() {
        return Ok(Validated {
            remote,
            credential: None,
        });
    }
    // GitHub and GitLab ignore the user name for tokens; it stays optional
    // there, as on Apple.
    let username = match (form.username.trim(), Host::of(&remote.location)) {
        ("", Host::GitHub) => "x-access-token",
        ("", Host::GitLab) => "oauth2",
        (name, _) => name,
    };
    if !git_location::valid_username(username) {
        return Err(Failure::InvalidUsername);
    }
    let mut token = Zeroizing::new(form.token.trim().to_owned());
    if token.is_empty()
        && let Some(saved) = stored_token(owner, &remote, username)?
    {
        token = saved;
    }
    if token.is_empty() {
        return Err(Failure::MissingToken);
    }
    let credential = HttpCredential::new(username, token)?;
    Ok(Validated {
        remote,
        credential: Some(credential),
    })
}
/// While Git is connected, only its own repository and branch may be
/// reconnected (a new token, a recovered key, or the library that replaced
/// the old one there). Another destination needs Disconnect first.
fn require_reconnectable(environment: &Environment, remote: &Remote) -> Result<()> {
    let Some(active) = Settings::read(&environment.root)? else {
        return Ok(());
    };
    let active = active.remote(environment)?;
    if !active.location.same_endpoint(&remote.location) || active.branch != remote.branch {
        return Err(Failure::OtherLibraryActive);
    }
    Ok(())
}

// MARK: - Setup steps

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Empty,
    Library {
        dataset: Uuid,
        mode: Mode,
        key_available: bool,
        recovery_available: bool,
    },
    Foreign,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Inspection {
    pub state: State,
    /// Connecting replaces this device's sync state for another library. Its
    /// local snippets are kept and merged into the Git library after review.
    pub replaces_sync_state: bool,
}

pub fn inspect<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
    form: &Form,
) -> Result<Inspection> {
    store.transaction_with(|owner| {
        let validated = validate(environment, owner, form)?;
        let mut transport = environment.setup_transport(&validated.remote, validated.credential)?;
        let state = match transport.inspect()? {
            RepositoryState::Empty => State::Empty,
            RepositoryState::Foreign => State::Foreign,
            RepositoryState::Library { dataset, mode } => {
                let scope = git_layout::key_scope(&validated.remote, dataset);
                let key_available = library_key(owner, &scope)?.is_some();
                let recovery_available =
                    key_available || transport.read_file(git_layout::RECOVERY_PATH)?.is_some();
                State::Library {
                    dataset,
                    mode,
                    key_available,
                    recovery_available,
                }
            }
        };
        let replaces_sync_state = match state {
            State::Library { dataset, .. } => {
                replaces_sync_state(owner, &validated.remote, Some(dataset))?
            }
            State::Empty => replaces_sync_state(owner, &validated.remote, None)?,
            State::Foreign => false,
        };
        Ok(Inspection {
            state,
            replaces_sync_state,
        })
    })
}
fn replaces_sync_state<B: Backend>(
    owner: &mut Locked<'_, B>,
    remote: &Remote,
    dataset: Option<Uuid>,
) -> Result<bool> {
    let Some(material) = owner.checkpoint_material(false)? else {
        return Ok(false);
    };
    let (key, salt) = checkpoint_key(&material)?;
    let library = Library::prepare(owner.root().into()).map_err(|_| Failure::Storage)?;
    match Checkpoint::stored_scope(&library, &key, &salt).map_err(|_| Failure::Journal)? {
        None => Ok(false),
        Some((scope, _)) => {
            Ok(dataset.is_none_or(|d| scope != git_layout::checkpoint_scope(remote, d)))
        }
    }
}

/// Creates a new library on an empty branch and returns its one-time
/// recovery code. On some failures the code is still returned with the
/// failure: the library may exist, and the code opens it. `mode` is fixed
/// for the library's lifetime: encrypted (every record ciphertext) or plain
/// text (ordinary snippets as readable Markdown, secure snippets encrypted).
/// `confirmed_private` is the user's word that a plain-text library's
/// repository is private when Snippets could not check it
/// (`visibility_unknown`).
pub fn create<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
    form: &Form,
    mode: Mode,
    confirmed_private: bool,
) -> std::result::Result<Zeroizing<String>, (Failure, Option<Zeroizing<String>>)> {
    store
        .transaction_with(|owner| {
            Ok(create_locked(
                environment,
                owner,
                form,
                mode,
                confirmed_private,
            ))
        })
        .map_err(|failure: Failure| (failure, None))?
}
fn create_locked<B: Backend>(
    environment: &Environment,
    owner: &mut Locked<'_, B>,
    form: &Form,
    mode: Mode,
    confirmed_private: bool,
) -> std::result::Result<Zeroizing<String>, (Failure, Option<Zeroizing<String>>)> {
    let plain = |failure: Failure| (failure, None);
    let validated = validate(environment, owner, form).map_err(plain)?;
    // Plain text in a repository anyone can read would publish the snippets;
    // when Snippets cannot tell, the user must say the repository is private.
    if mode == Mode::PlainText {
        match visibility(&validated.remote.location, environment.insecure_loopback) {
            Visibility::Public => return Err(plain(Failure::PublicRepository)),
            Visibility::Unknown if !confirmed_private => {
                return Err(plain(Failure::VisibilityUnknown));
            }
            _ => (),
        }
    }
    require_reconnectable(environment, &validated.remote).map_err(plain)?;
    let mut transport = environment
        .setup_transport(
            &validated.remote,
            validated.credential.as_ref().map(HttpCredential::duplicate),
        )
        .map_err(plain)?;
    let dataset = Uuid::new_v4();
    let bundle = Bundle::generate().map_err(|_| plain(Failure::Storage))?;
    let kit = Kit::generate(dataset).map_err(|_| plain(Failure::Storage))?;
    let envelope = kit.seal(&bundle).map_err(|_| plain(Failure::Storage))?;
    let scope = git_layout::key_scope(&validated.remote, dataset);
    // The key exists before the library does: a crash after the push leaves
    // a library this device can still open.
    install_key(owner, &scope, &bundle).map_err(plain)?;
    let code = kit.code();
    let created =
        match transport.initialize(dataset, &[(git_layout::RECOVERY_PATH, &envelope)], mode) {
            Ok(created) => created,
            Err(failure) => {
                // A lost response can hide a push that landed. Forget the key only
                // once the repository proves this library does not exist.
                return match transport.inspect() {
                    // Pin the mode the user chose, never the one found: a
                    // library in another mode is not the one agreed to.
                    Ok(RepositoryState::Library {
                        dataset: existing,
                        mode: found,
                    }) if existing == dataset => {
                        if found != mode {
                            return Err((
                                Failure::Transport(git_transport::Failure::ModeChanged),
                                Some(code),
                            ));
                        }
                        activate_created(
                            environment,
                            owner,
                            &validated,
                            dataset,
                            mode,
                            &bundle,
                            code,
                        )
                    }
                    Ok(_) => {
                        let _ = forget_key(owner, &scope);
                        Err((failure.into(), None))
                    }
                    Err(_) => Err((failure.into(), Some(code))),
                };
            }
        };
    if created != dataset {
        let _ = forget_key(owner, &scope);
        return Err((Failure::LibraryExists, None));
    }
    activate_created(environment, owner, &validated, dataset, mode, &bundle, code)
}
fn activate_created<B: Backend>(
    environment: &Environment,
    owner: &mut Locked<'_, B>,
    validated: &Validated,
    dataset: Uuid,
    mode: Mode,
    bundle: &Bundle,
    code: Zeroizing<String>,
) -> std::result::Result<Zeroizing<String>, (Failure, Option<Zeroizing<String>>)> {
    match activate(environment, owner, validated, dataset, mode, bundle) {
        Ok(()) => Ok(code),
        Err(failure) => Err((failure, Some(code))),
    }
}

/// Whether joining `dataset` at the repository and branch in `form` needs
/// the user's consent first (Apple `needsPlainTextConsent`): it is a
/// plain-text library, and this device has not already agreed to exactly that
/// library, mode, endpoint (`Location::same_endpoint`) and branch.
pub fn joining_needs_consent(
    environment: &Environment,
    form: &Form,
    dataset: Uuid,
    mode: Mode,
) -> bool {
    if mode != Mode::PlainText {
        return false;
    }
    let Ok(location) = Location::parse(&form.repository, environment.insecure_loopback) else {
        return true;
    };
    let Ok(remote) = Remote::new(location, form.branch.trim()) else {
        return true;
    };
    !Settings::read(&environment.root)
        .ok()
        .flatten()
        .is_some_and(|settings| {
            settings.dataset == dataset
                && settings.mode == Mode::PlainText
                && settings.branch == remote.branch
                && settings
                    .remote(environment)
                    .is_ok_and(|saved| saved.location.same_endpoint(&remote.location))
        })
}

/// Joins the library `dataset` that `inspect` reported in `mode`, the mode the
/// user saw and agreed to. A recovery code is needed only when this device
/// does not hold the key yet. A plain-text library this device is not already
/// connected to needs `accept_plain_text`. A repository whose manifest now
/// names another mode is refused (`git_library_mode_changed`).
pub fn join<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
    form: &Form,
    dataset: Uuid,
    mode: Mode,
    recovery_code: Option<&str>,
    accept_plain_text: bool,
) -> Result<()> {
    store.transaction_with(|owner| {
        let validated = validate(environment, owner, form)?;
        let remote = validated.remote.clone();
        let mut transport = environment.setup_transport(
            &remote,
            validated.credential.as_ref().map(HttpCredential::duplicate),
        )?;
        // The manifest decides the mode; a joining device never chooses it.
        match transport.inspect()? {
            RepositoryState::Library {
                dataset: current,
                mode: current_mode,
            } if current == dataset => {
                if current_mode != mode {
                    return Err(Failure::Transport(git_transport::Failure::ModeChanged));
                }
            }
            _ => return Err(Failure::LibraryChanged),
        }
        if !accept_plain_text && joining_needs_consent(environment, form, dataset, mode) {
            return Err(Failure::PlainTextConsentRequired);
        }
        require_reconnectable(environment, &remote)?;
        transport.verify_write_access()?;
        let scope = git_layout::key_scope(&remote, dataset);
        let bundle = match library_key(owner, &scope)? {
            Some(bundle) => bundle,
            None => {
                let code = recovery_code
                    .map(str::trim)
                    .filter(|c| !c.is_empty())
                    .ok_or(Failure::RecoveryCodeRequired)?;
                let kit =
                    Kit::from_code(code, dataset).map_err(|_| Failure::InvalidRecoveryCode)?;
                let envelope = transport
                    .read_file(git_layout::RECOVERY_PATH)?
                    .ok_or(Failure::RecoveryUnavailable)?;
                let bundle = kit.open(&envelope).map_err(|failure| match failure {
                    git_recovery::Failure::IncorrectCode => Failure::IncorrectRecoveryCode,
                    _ => Failure::RecoveryUnavailable,
                })?;
                install_key(owner, &scope, &bundle)?;
                bundle
            }
        };
        drop(transport);
        activate(environment, owner, &validated, dataset, mode, &bundle)
    })
}

/// Makes `dataset` the active Git library: the reviewed journal switch when
/// this device's sync state belongs to another library, then the credential
/// and configuration. Cloud automatic sync is turned off: one provider owns
/// the journal at a time.
fn activate<B: Backend>(
    environment: &Environment,
    owner: &mut Locked<'_, B>,
    validated: &Validated,
    dataset: Uuid,
    mode: Mode,
    bundle: &Bundle,
) -> Result<()> {
    let remote = validated.remote.clone();
    let mut transport = environment.transport(
        &remote,
        validated.credential.as_ref().map(HttpCredential::duplicate),
        Some((dataset, mode, bundle)),
    )?;
    // Connect only to the mode the user agreed to.
    match transport.inspect()? {
        RepositoryState::Library {
            dataset: current,
            mode: current_mode,
        } if current == dataset => {
            if current_mode != mode {
                return Err(Failure::Transport(git_transport::Failure::ModeChanged));
            }
        }
        _ => return Err(Failure::LibraryChanged),
    }
    let material = owner.checkpoint_material(true)?.ok_or(Failure::Journal)?;
    let (checkpoint_key, checkpoint_salt) = checkpoint_key(&material)?;
    let library = Library::prepare(environment.root.clone()).map_err(|_| Failure::Storage)?;
    let scope = git_layout::checkpoint_scope(&remote, dataset);
    if let Some((previous, epoch)) =
        Checkpoint::stored_scope(&library, &checkpoint_key, &checkpoint_salt)
            .map_err(|_| Failure::Journal)?
        && previous != scope
    {
        let guard = || {
            if environment.cancelled() {
                Err(receiver::Failure::SessionChanged)
            } else {
                Ok(())
            }
        };
        with_wire_key(bundle, |wire_key, wire_salt| {
            let journal = receiver::Owner {
                library: &library,
                scope: &scope,
                key_epoch: KEY_EPOCH,
                checkpoint_key: &checkpoint_key,
                checkpoint_salt: &checkpoint_salt,
                wire_key,
                wire_salt,
                device: None,
                vault_keys: None,
                validate_session: &guard,
            };
            let previous = account_review::Previous {
                scope: previous,
                key_epoch: epoch.unwrap_or(KEY_EPOCH),
                key_material_changed: true,
            };
            let review = journal
                .prepare_account_review(&mut transport, previous)
                .map_err(|f| review_failure(f, &transport))?;
            journal
                .stage_account_review(&mut transport, &review)
                .map_err(|f| review_failure(f, &transport))?;
            journal
                .continue_account_review(&mut transport, &review.receipt())
                .map_err(|f| review_failure(f, &transport))?;
            Ok::<(), Failure>(())
        })?;
    }
    save_credential(owner, &remote, validated.credential.as_ref())?;
    let username = validated
        .credential
        .as_ref()
        .map(|c| c.username().to_owned());
    let automatic = Settings::read(&environment.root)?
        .filter(|s| s.remote(environment).ok().as_ref() == Some(&remote))
        .is_none_or(|s| s.automatic);
    Settings {
        repository: remote.location.spec(),
        branch: remote.branch.clone(),
        username,
        dataset,
        automatic,
        mode,
    }
    .write(&environment.root)?;
    if auto_sync::Preference::read(&environment.root).is_ok_and(|p| p.enabled()) {
        auto_sync::Preference::off(&environment.root).map_err(|_| Failure::Storage)?;
    }
    Ok(())
}
// MARK: - Connected operations

/// Seals the current library key under a new code and replaces the
/// repository's envelope. Older envelopes stay in git history, so this
/// replaces a lost code; it cannot revoke a leaked one.
pub fn replace_recovery_code<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
) -> Result<Zeroizing<String>> {
    store.transaction_with(|owner| {
        let connected = Connected::load(environment, owner)?;
        let kit = Kit::generate(connected.settings.dataset).map_err(|_| Failure::Storage)?;
        let envelope = kit.seal(&connected.bundle).map_err(|_| Failure::Storage)?;
        let mut transport = connected.transport(environment)?;
        // The Apple apps wrap the vault key under the same code in the same
        // commit. Replacing only the library envelope here would leave a code
        // that opens the library without its secure snippets.
        if transport.read_file(crate::git_vault::PATH)?.is_some() {
            return Err(Failure::VaultRecoveryCode);
        }
        if let Err(failure) = transport.write_files(
            &[(git_layout::RECOVERY_PATH, &envelope)],
            git_layout::RECOVERY_MESSAGE,
        ) {
            // A lost response can hide a write that landed, after which only
            // the new code opens the stored envelope.
            if let Ok(Some(current)) = transport.read_file(git_layout::RECOVERY_PATH)
                && kit.open(&current).is_ok()
            {
                return Ok(kit.code());
            }
            return Err(failure.into());
        }
        Ok(kit.code())
    })
}
/// Forgets the repository on this device. The library key stays in the
/// keyring so reconnecting later needs no recovery code; the token is removed.
pub fn disconnect<B: Backend>(environment: &Environment, store: &mut Store<B>) -> Result<()> {
    store.transaction_with(|owner| {
        let library = Library::prepare(environment.root.clone()).map_err(|_| Failure::Storage)?;
        {
            let _guard = library.lock().map_err(|_| Failure::Storage)?;
            match std::fs::remove_file(environment.root.join(CONFIG_FILE)) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => {
                    return Err(Failure::Storage);
                }
                _ => (),
            }
        }
        let current = owner.read(Slot::GitCredential)?;
        if let Some(current) = current {
            owner.replace(Slot::GitCredential, Some(&current), None)?;
        }
        Ok(())
    })
}
pub fn set_automatic(environment: &Environment, automatic: bool) -> Result<()> {
    let mut settings = Settings::read(&environment.root)?.ok_or(Failure::NotConfigured)?;
    settings.automatic = automatic;
    settings.write(&environment.root)
}

/// The aggregate outcome of one bounded cycle. Counts only; no identities.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncState {
    Current,
    MoreWork,
    DeletionReview,
    SnapshotReview,
    ConflictReview,
    VaultLocked,
    IncompatibleVault,
    PrimaryChanged,
    PreservationRequired,
    Deferred { retry_after: Option<u32> },
    ReadOnly,
}
impl SyncState {
    pub fn message(self) -> &'static str {
        match self {
            Self::Current => "Up to date.",
            Self::MoreWork => "More changes are waiting; syncing continues.",
            Self::DeletionReview => "A deletion needs your review before syncing continues.",
            Self::SnapshotReview => {
                "Some synchronized snippets are missing from the repository. Review them before syncing continues."
            }
            Self::ConflictReview => "A conflict needs review in the library.",
            Self::VaultLocked => {
                "Secure snippets changed. Unlock them through Account & Recovery to apply."
            }
            Self::IncompatibleVault => "Secure snippets from another vault cannot be applied here.",
            Self::PrimaryChanged => "The library changed during sync; it will retry.",
            Self::PreservationRequired => "Preserved copies are waiting to be synchronized.",
            Self::Deferred { .. } => "The Git host deferred some changes; they will be retried.",
            Self::ReadOnly => "This repository is read-only for this device.",
        }
    }
    /// Whether automatic sync may continue on its own.
    pub fn automatic(self) -> auto_sync::Outcome {
        match self {
            Self::Current => auto_sync::Outcome::Current,
            Self::MoreWork | Self::PrimaryChanged => auto_sync::Outcome::MoreWork,
            Self::Deferred { .. } | Self::PreservationRequired => auto_sync::Outcome::Retry,
            _ => auto_sync::Outcome::Attention,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SyncReport {
    pub state: SyncState,
    pub received: usize,
    pub applied: usize,
    pub accepted: usize,
    pub conflicts: usize,
    pub rejected: usize,
    /// Plain-text libraries: Markdown files that cannot be read, which sync
    /// skips (never deletes, never overwrites) until they are fixed.
    pub unreadable_files: usize,
    /// Edits refused because their snippet's file is unreadable; they stay
    /// pending.
    pub refused_unreadable: usize,
}
impl SyncReport {
    /// A non-fatal warning naming only counts, never a file or snippet.
    pub fn warning(&self) -> Option<String> {
        if self.unreadable_files == 0 && self.refused_unreadable == 0 {
            return None;
        }
        let files = match self.unreadable_files.max(self.refused_unreadable) {
            1 => "1 snippet file".to_owned(),
            n => format!("{n} snippet files"),
        };
        Some(format!(
            "{files} in the repository cannot be read. Sync skips them and keeps edits to them waiting; fix their front matter (the lines between ---) in the repository."
        ))
    }
}
fn report(progress: sync::Progress) -> SyncReport {
    use crate::receiver::Status as R;
    use crate::sender::Status as S;
    let state = match progress.status {
        sync::Status::Current => SyncState::Current,
        sync::Status::MoreWork(Direction::Receive | Direction::Send) => SyncState::MoreWork,
        sync::Status::Receiving(status) => match status {
            R::Current => SyncState::Current,
            R::MorePages | R::SendFirst => SyncState::MoreWork,
            R::LocalReview | R::DeletionReview => SyncState::DeletionReview,
            R::ConflictReview => SyncState::ConflictReview,
            R::VaultLocked => SyncState::VaultLocked,
            R::IncompatibleVault => SyncState::IncompatibleVault,
            R::SnapshotReview => SyncState::SnapshotReview,
            R::PrimaryChanged => SyncState::PrimaryChanged,
        },
        sync::Status::Sending(status) => match status {
            S::Settled => SyncState::Current,
            S::MoreBatches | S::ReceiveFirst => SyncState::MoreWork,
            S::LocalReview | S::DeletionReview => SyncState::DeletionReview,
            S::SnapshotReview => SyncState::SnapshotReview,
            S::PreservationRequired => SyncState::PreservationRequired,
            S::ConflictReview => SyncState::ConflictReview,
            S::VaultLocked => SyncState::VaultLocked,
            S::IncompatibleVault => SyncState::IncompatibleVault,
            S::PrimaryChanged => SyncState::PrimaryChanged,
            S::ReadOnly => SyncState::ReadOnly,
            S::ServerDeferred { retry_after, .. } => SyncState::Deferred { retry_after },
        },
    };
    SyncReport {
        state,
        received: progress.received_records,
        applied: progress.applied_records,
        accepted: progress.accepted,
        conflicts: progress.conflicts,
        rejected: progress.rejected,
        unreadable_files: 0,
        refused_unreadable: 0,
    }
}

/// One bounded bidirectional cycle against the configured library.
pub fn synchronize<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
) -> Result<SyncReport> {
    match synchronize_once(environment, store) {
        Err(Failure::Transport(git_transport::Failure::Git(git_repo::Failure::LocalStorage))) => {
            // The cache is disposable: start over from a fresh one, once.
            if let Some(settings) = Settings::read(&environment.root)?
                && let Ok(remote) = settings.remote(environment)
            {
                let _ = std::fs::remove_dir_all(environment.cache(&remote));
            }
            synchronize_once(environment, store)
        }
        result => result,
    }
}
fn synchronize_once<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
) -> Result<SyncReport> {
    with_connected_owner(environment, store, |owner, transport| {
        let mut report = owner
            .synchronize(transport, Limits::DEFAULT)
            .map(report)
            .map_err(|f| data_failure(f, transport))?;
        (report.unreadable_files, report.refused_unreadable) = transport.plain_warnings();
        Ok(report)
    })
}

/// A pending per-snippet deletion decision. Names and keywords are shown to
/// the user only; they never reach logs.
pub struct DeletionSummary {
    pub kind: deletion_review::Kind,
    pub name: String,
    pub keyword: String,
    pub secure: bool,
    pub can_keep: bool,
}
pub fn deletion_review<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
    choice: Option<deletion_review::Choice>,
) -> Result<DeletionSummary> {
    with_connected_owner(environment, store, |owner, transport| {
        let review = owner
            .prepare_deletion_review(transport)
            .map_err(|f| deletion_failure(f, transport))?;
        let summary = review.summary();
        let result = DeletionSummary {
            kind: summary.kind,
            name: summary.name.clone(),
            keyword: summary.keyword.clone(),
            secure: summary.secure,
            can_keep: summary.can_keep,
        };
        if let Some(choice) = choice {
            if summary.secure || choice == deletion_review::Choice::Keep && !summary.can_keep {
                return Err(Failure::NoReview);
            }
            owner
                .decide_deletion_review(transport, review, choice)
                .map_err(|f| deletion_failure(f, transport))?;
        }
        Ok(result)
    })
}
/// The missing-records review after a complete snapshot omitted known
/// records: keep local intent, re-baseline the journal, then sync again.
pub fn resolve_snapshot_review<B: Backend>(
    environment: &Environment,
    store: &mut Store<B>,
    confirm: bool,
) -> Result<snapshot_review::Summary> {
    with_connected_owner(environment, store, |owner, transport| {
        let review = owner
            .prepare_missing_snapshot_review(transport)
            .map_err(|f| snapshot_failure(f, transport))?;
        let summary = review.summary();
        if !confirm {
            return Ok(summary);
        }
        owner
            .resume_missing_snapshot_review(transport, review)
            .map_err(|f| snapshot_failure(f, transport))
    })
}

struct Connected {
    settings: Settings,
    remote: Remote,
    bundle: Bundle,
    credential: Option<HttpCredential>,
}
impl Connected {
    fn load<B: Backend>(environment: &Environment, owner: &mut Locked<'_, B>) -> Result<Self> {
        let settings = Settings::read(&environment.root)?.ok_or(Failure::NotConfigured)?;
        let remote = settings.remote(environment)?;
        let bundle = library_key(owner, &git_layout::key_scope(&remote, settings.dataset))?
            .ok_or(Failure::KeyUnavailable)?;
        let credential = match (&remote.location, &settings.username) {
            (Location::Ssh(_), _) => None,
            (Location::Https(_), Some(username)) => {
                let token = stored_token(owner, &remote, username)?.ok_or(Failure::MissingToken)?;
                Some(HttpCredential::new(username, token)?)
            }
            (Location::Https(_), None) => return Err(Failure::MissingToken),
        };
        Ok(Self {
            settings,
            remote,
            bundle,
            credential,
        })
    }
    fn transport(&self, environment: &Environment) -> Result<GitTransport> {
        environment.transport(
            &self.remote,
            self.credential.as_ref().map(HttpCredential::duplicate),
            Some((self.settings.dataset, self.settings.mode, &self.bundle)),
        )
    }
}
fn with_connected_owner<B: Backend, T>(
    environment: &Environment,
    store: &mut Store<B>,
    action: impl FnOnce(&receiver::Owner<'_>, &mut GitTransport) -> Result<T>,
) -> Result<T> {
    store.transaction_with(|owner| {
        let (_, config_bytes) = read_config(&environment.root)?.ok_or(Failure::NotConfigured)?;
        let connected = Connected::load(environment, owner)?;
        let mut transport = connected.transport(environment)?;
        let material = owner.checkpoint_material(true)?.ok_or(Failure::Journal)?;
        let (checkpoint_key, checkpoint_salt) = checkpoint_key(&material)?;
        let library = Library::prepare(environment.root.clone()).map_err(|_| Failure::Storage)?;
        let scope = git_layout::checkpoint_scope(&connected.remote, connected.settings.dataset);
        let root = environment.root.clone();
        let guard = || {
            // The configuration this cycle was admitted for must stay current.
            let current = read_config(&root).map_err(|_| receiver::Failure::SessionChanged)?;
            if environment.cancelled()
                || current.map(|(_, bytes)| bytes) != Some(config_bytes.clone())
            {
                return Err(receiver::Failure::SessionChanged);
            }
            Ok(())
        };
        with_wire_key(&connected.bundle, |wire_key, wire_salt| {
            let owner = receiver::Owner {
                library: &library,
                scope: &scope,
                key_epoch: KEY_EPOCH,
                checkpoint_key: &checkpoint_key,
                checkpoint_salt: &checkpoint_salt,
                wire_key,
                wire_salt,
                device: None,
                vault_keys: None,
                validate_session: &guard,
            };
            action(&owner, &mut transport)
        })
    })
}

fn checkpoint_key(material: &[u8]) -> Result<(RootKey, [u8; 32])> {
    if material.len() != 64 {
        return Err(Failure::Journal);
    }
    let key = RootKey::from_bytes(&material[..32]).map_err(|_| Failure::Journal)?;
    let salt = material[32..].try_into().map_err(|_| Failure::Journal)?;
    Ok((key, salt))
}
fn with_wire_key<T>(bundle: &Bundle, action: impl FnOnce(&RootKey, &[u8; 32]) -> T) -> T {
    let material = bundle.for_secure_storage();
    let root = RootKey::from_bytes(&material[..32]).expect("validated 64-byte bundle");
    let salt = material[32..].try_into().expect("validated 32-byte salt");
    action(&root, salt)
}
fn data_failure(failure: receiver::Failure, transport: &GitTransport) -> Failure {
    match failure {
        receiver::Failure::Remote(_) => {
            transport
                .last_failure()
                .map(Failure::Transport)
                .unwrap_or(Failure::Transport(git_transport::Failure::Git(
                    git_repo::Failure::Unreachable,
                )))
        }
        receiver::Failure::ScopeReview
        | receiver::Failure::Journal(journal::Failure::ScopeReview) => Failure::ScopeReview,
        receiver::Failure::SessionChanged => Failure::Interrupted,
        receiver::Failure::Primary(
            crate::primary::Failure::RecoveryRequired | crate::primary::Failure::StalePrimary,
        ) => Failure::LibraryBusy,
        receiver::Failure::InvalidPage
        | receiver::Failure::Journal(_)
        | receiver::Failure::Primary(_) => Failure::Journal,
    }
}
fn review_failure(failure: account_review::Failure, transport: &GitTransport) -> Failure {
    match failure {
        account_review::Failure::Data(failure) => data_failure(failure, transport),
        account_review::Failure::LocalAbsence => Failure::LocalAbsence,
        account_review::Failure::Changed | account_review::Failure::Unavailable => Failure::Changed,
        account_review::Failure::RetentionFull => Failure::RetentionFull,
        account_review::Failure::InvalidReceipt => Failure::Journal,
    }
}
fn deletion_failure(failure: deletion_review::Failure, transport: &GitTransport) -> Failure {
    match failure {
        deletion_review::Failure::Data(failure) => data_failure(failure, transport),
        deletion_review::Failure::Unavailable => Failure::NoReview,
        _ => Failure::Changed,
    }
}
fn snapshot_failure(failure: snapshot_review::Failure, transport: &GitTransport) -> Failure {
    match failure {
        snapshot_review::Failure::Data(failure) => data_failure(failure, transport),
        snapshot_review::Failure::Unavailable => Failure::NoReview,
        _ => Failure::Changed,
    }
}
