//! The system `git` behind a hardened environment, operating a private bare
//! cache repository. The cache only ever holds what the remote already holds
//! (ciphertext records, the manifest, the README and key envelopes) and may be
//! deleted at any time.
//!
//! Safety rules for every invocation:
//! - The inherited environment is cleared to a short allow-list. No user or
//!   system git configuration, hooks, templates, credential helpers, replace
//!   objects, trace variables or prompts apply.
//! - Only `https` and `ssh` transports are allowed (plus explicitly opted-in
//!   loopback `http`/`file` for tests). Redirects are never followed.
//! - An HTTPS token travels only in an environment-only `http.extraHeader`:
//!   never argv, a URL, a file or a credential helper.
//! - SSH uses the system `ssh` with the user's agent, `~/.ssh/config` and
//!   `known_hosts`, in batch mode with strict host-key checking: an unknown
//!   host key fails instead of being accepted.
//! - Output is bounded; stderr is only classified into closed failure codes
//!   and is never stored, logged or shown, because it can echo URLs.
use crate::{git_layout, git_location::HttpCredential};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    io::{Read, Write},
    os::unix::{fs::DirBuilderExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

const MAX_STDERR: usize = 64 * 1024;
const MAX_STDOUT: usize = 256 * 1024 * 1024;
const LOCAL_TIMEOUT: Duration = Duration::from_secs(120);
/// A backstop only. Stalls are detected by the transports themselves: curl's
/// low-speed limit (no progress for 120 s) for HTTPS and ssh keepalives for SSH,
/// so a slow but moving transfer is never cut off.
const NETWORK_TIMEOUT: Duration = Duration::from_secs(30 * 60);
/// Ordinary, inherited variables a network git process legitimately needs.
const INHERITED: &[&str] = &[
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "TMPDIR",
    "XDG_RUNTIME_DIR",
    "SSH_AUTH_SOCK",
    "http_proxy",
    "https_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "all_proxy",
    "ALL_PROXY",
    "no_proxy",
    "NO_PROXY",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
];
/// Fixed ssh options. User configuration still supplies identities, aliases,
/// ports and jump hosts; these only forbid prompts, unknown host keys and
/// forwarding. Earlier command-line options win over `~/.ssh/config`.
/// RemoteCommand, SessionType, StdinNull and ForkAfterAuthentication are reset
/// because a user's config can set them and each one breaks git's exchange.
const SSH_OPTIONS: &str = "-T -o RequestTTY=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no -o RemoteCommand=none -o SessionType=default -o StdinNull=no -o ForkAfterAuthentication=no";

/// Closed vocabulary. Server text is never retained.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// The `git` executable is missing or could not start.
    GitUnavailable,
    /// The host refused the credential (HTTP 401/403, ssh publickey).
    Authentication,
    /// A typo and a token that cannot see a private repository look alike.
    RepositoryNotFound,
    /// The SSH host key is not in `known_hosts`, or it changed.
    HostKeyUnverified,
    RateLimited,
    Unreachable,
    /// Not a smart git endpoint this client can use, or a forbidden transport.
    Unsupported,
    /// The request body exceeded what the host or a proxy accepts (HTTP 413).
    PushTooLarge,
    ResponseTooLarge,
    /// The cache repository could not be read or written.
    LocalStorage,
    Cancelled,
    /// The host refused this push for the branch itself (a protected branch).
    PushRefused,
    /// The installed git or ssh is older than this client supports.
    GitTooOld,
    SshTooOld,
}
impl Failure {
    pub fn code(self) -> &'static str {
        match self {
            Self::GitUnavailable => "git_unavailable",
            Self::Authentication => "git_authentication",
            Self::RepositoryNotFound => "git_repository_not_found",
            Self::HostKeyUnverified => "git_ssh_host_key_unverified",
            Self::RateLimited => "git_rate_limited",
            Self::Unreachable => "git_unreachable",
            Self::Unsupported => "git_unsupported_server",
            Self::PushTooLarge => "git_push_too_large",
            Self::ResponseTooLarge => "git_response_too_large",
            Self::LocalStorage => "git_local_storage",
            Self::Cancelled => "git_cancelled",
            Self::PushRefused => "git_push_rejected",
            Self::GitTooOld => "git_unsupported_git_version",
            Self::SshTooOld => "git_unsupported_ssh_version",
        }
    }
}
pub type Result<T> = std::result::Result<T, Failure>;

/// Test-only and loopback opt-ins. Production uses `Options::default()`.
#[derive(Clone, Default)]
pub struct Options {
    /// Allow `file://` remotes (local fixtures only).
    pub allow_file: bool,
    /// Allow plain `http://` to loopback hosts (the location parser enforces loopback).
    pub allow_insecure_loopback: bool,
    /// An extra `ssh -F <file>` for isolated SSH fixtures. Never set in production:
    /// the user's own `~/.ssh/config` and `known_hosts` apply.
    pub ssh_config: Option<PathBuf>,
    /// A stand-in `ssh` executable for local fixtures. Never set in production.
    pub ssh_program: Option<PathBuf>,
    /// Cancels in-flight commands (kills their process group).
    pub cancel: Option<Arc<AtomicBool>>,
}

/// One remote endpoint plus its optional HTTPS credential.
pub struct Endpoint<'a> {
    pub url: &'a str,
    pub credential: Option<&'a HttpCredential>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeEntry {
    pub mode: String,
    pub kind: String,
    pub id: String,
    pub name: Vec<u8>,
}
impl TreeEntry {
    pub fn is_tree(&self) -> bool {
        self.kind == "tree" && self.mode.trim_start_matches('0') == "40000"
    }
    pub fn is_regular_file(&self) -> bool {
        self.kind == "blob" && (self.mode == "100644" || self.mode == "100755")
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum PushOutcome {
    Updated,
    /// The ref was not updated: a lost compare-and-swap, a protected branch or
    /// a hook. The caller re-reads the head to tell them apart.
    Rejected,
}

pub struct Cache {
    directory: PathBuf,
    options: Options,
}
struct Output {
    status: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}
impl Cache {
    /// Opens (creating if needed) a private bare repository at `directory`.
    pub fn open(directory: PathBuf, options: Options) -> Result<Self> {
        let cache = Self { directory, options };
        cache.ensure_git()?;
        if !cache.directory.join("HEAD").is_file() {
            if let Some(parent) = cache.directory.parent() {
                std::fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(parent)
                    .map_err(|_| Failure::LocalStorage)?;
            }
            let mut init = cache.base_command(false);
            init.arg("init")
                .arg("--bare")
                .arg("--quiet")
                .arg("--template=")
                .arg("--object-format=sha1")
                .arg("--")
                .arg(&cache.directory)
                .env_remove("GIT_DIR");
            let output = cache.run(init, None, LOCAL_TIMEOUT, MAX_STDERR)?;
            if output.status != Some(0) {
                return Err(Failure::LocalStorage);
            }
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&cache.directory, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| Failure::LocalStorage)?;
        }
        Ok(cache)
    }
    /// git 2.32 or later, checked once per process: before the cache is
    /// created (an older git may not know `--object-format`) and before any
    /// network command.
    fn ensure_git(&self) -> Result<()> {
        let git = probe_once("git".into(), || {
            let mut command = self.base_command(false);
            command.env_remove("GIT_DIR").arg("--version");
            let output = self.run(command, None, LOCAL_TIMEOUT, 4096).ok()?;
            Some(version_at_least(
                std::str::from_utf8(&output.stdout)
                    .ok()?
                    .strip_prefix("git version ")?,
                (2, 32),
            ))
        });
        match git {
            None => Err(Failure::GitUnavailable),
            Some(false) => Err(Failure::GitTooOld),
            Some(true) => Ok(()),
        }
    }
    pub fn directory(&self) -> &Path {
        &self.directory
    }
    pub fn remove(self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }

    fn base_command(&self, network: bool) -> Command {
        let mut command = Command::new("git");
        command.env_clear();
        for name in INHERITED {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        let mut config: Vec<(&str, OsString)> = vec![
            ("core.hooksPath", "/dev/null".into()),
            ("core.fsmonitor", "false".into()),
            ("core.askPass", "".into()),
            ("credential.helper", "".into()),
            ("gc.auto", "0".into()),
            ("maintenance.auto", "false".into()),
            ("fetch.fsckObjects", "true".into()),
            ("transfer.fsckObjects", "true".into()),
            ("fetch.recurseSubmodules", "false".into()),
            ("submodule.recurse", "false".into()),
            ("http.followRedirects", "false".into()),
            // Bounded pushes go out with Content-Length, never chunked: some
            // hosts and proxies refuse chunked request bodies.
            ("http.postBuffer", "33554432".into()),
            // An idle limit, not a whole-exchange limit: abort only when the
            // transfer stays below 1 byte/s for 120 s.
            ("http.lowSpeedLimit", "1".into()),
            ("http.lowSpeedTime", "120".into()),
            ("protocol.allow", "never".into()),
            ("protocol.https.allow", "always".into()),
            ("protocol.ssh.allow", "always".into()),
            ("commit.gpgSign", "false".into()),
            ("init.defaultBranch", "snippets-cache".into()),
            ("advice.detachedHead", "false".into()),
        ];
        if self.options.allow_file {
            config.push(("protocol.file.allow", "always".into()));
        }
        if self.options.allow_insecure_loopback {
            config.push(("protocol.http.allow", "always".into()));
        }
        command
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_ASKPASS", "")
            .env("SSH_ASKPASS", "")
            .env("SSH_ASKPASS_REQUIRE", "never")
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .env("GIT_PROTOCOL_FROM_USER", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("GIT_DIR", &self.directory);
        if network {
            let program = self
                .options
                .ssh_program
                .as_ref()
                .map(|p| shell_quote(&p.to_string_lossy()))
                .unwrap_or_else(|| "ssh".into());
            let mut ssh = format!("{program} {SSH_OPTIONS}");
            if let Some(file) = &self.options.ssh_config {
                ssh.push_str(&format!(" -F {}", shell_quote(&file.to_string_lossy())));
            }
            command
                .env("GIT_SSH_COMMAND", ssh)
                .env("GIT_SSH_VARIANT", "ssh");
        }
        let count = config.len();
        for (index, (key, value)) in config.into_iter().enumerate() {
            command
                .env(format!("GIT_CONFIG_KEY_{index}"), key)
                .env(format!("GIT_CONFIG_VALUE_{index}"), value);
        }
        command.env("GIT_CONFIG_COUNT", count.to_string());
        command
    }
    /// A network command; the credential, if any, is appended as one more
    /// environment-only config entry.
    fn network_command(&self, endpoint: &Endpoint<'_>) -> (Command, Option<Zeroizing<String>>) {
        let mut command = self.base_command(true);
        let header = endpoint.credential.map(HttpCredential::header);
        if let Some(header) = &header {
            // GIT_CONFIG_COUNT was set by base_command; extend it by one.
            let index = command
                .get_envs()
                .find(|(k, _)| *k == "GIT_CONFIG_COUNT")
                .and_then(|(_, v)| v?.to_str()?.parse::<usize>().ok())
                .unwrap_or(0);
            command
                .env(format!("GIT_CONFIG_KEY_{index}"), "http.extraHeader")
                .env(format!("GIT_CONFIG_VALUE_{index}"), header.as_str())
                .env("GIT_CONFIG_COUNT", (index + 1).to_string());
        }
        (command, header)
    }

    fn run(
        &self,
        mut command: Command,
        stdin: Option<&[u8]>,
        timeout: Duration,
        stdout_limit: usize,
    ) -> Result<Output> {
        command
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
        let mut child = command.spawn().map_err(|_| Failure::GitUnavailable)?;
        let writer = stdin.map(|bytes| {
            let mut pipe = child.stdin.take().expect("piped stdin");
            let bytes = bytes.to_vec();
            std::thread::spawn(move || {
                let _ = pipe.write_all(&bytes);
            })
        });
        let mut out = child.stdout.take().expect("piped stdout");
        let mut err = child.stderr.take().expect("piped stderr");
        let reader = std::thread::spawn(move || bounded_read(&mut out, stdout_limit));
        let error_reader = std::thread::spawn(move || bounded_read(&mut err, MAX_STDERR));
        let deadline = Instant::now() + timeout;
        let mut cancelled = false;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) => (),
                Err(_) => break None,
            }
            let cancel = self
                .options
                .cancel
                .as_ref()
                .is_some_and(|c| c.load(Ordering::SeqCst));
            if cancel || Instant::now() >= deadline {
                cancelled = cancel;
                // The whole group: git's ssh or remote-https helpers too.
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                let _ = child.wait();
                break None;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        if let Some(writer) = writer {
            let _ = writer.join();
        }
        let stdout = reader.join().map_err(|_| Failure::LocalStorage)?;
        let stderr = error_reader.join().map_err(|_| Failure::LocalStorage)?;
        if cancelled {
            return Err(Failure::Cancelled);
        }
        let Some(status) = status else {
            return Err(Failure::Unreachable);
        };
        let (stdout, overflow) = stdout;
        if overflow {
            return Err(Failure::ResponseTooLarge);
        }
        Ok(Output {
            status: status.code(),
            stdout,
            stderr: stderr.0,
        })
    }
    fn local(&self, args: &[&str], stdin: Option<&[u8]>) -> Result<Vec<u8>> {
        let mut command = self.base_command(false);
        command.args(args);
        let output = self.run(command, stdin, LOCAL_TIMEOUT, MAX_STDOUT)?;
        if output.status != Some(0) {
            return Err(Failure::LocalStorage);
        }
        Ok(output.stdout)
    }

    // MARK: - Remote operations

    /// Fails closed, once per process and program, when git is older than
    /// 2.32 or (for SSH) ssh older than OpenSSH 8.7: the options this client
    /// relies on would be ignored or refused.
    fn ensure_tools(&self, endpoint: &Endpoint<'_>) -> Result<()> {
        self.ensure_git()?;
        let ssh = !["https://", "http://", "file://"]
            .iter()
            .any(|scheme| endpoint.url.starts_with(scheme));
        if ssh {
            let program = self
                .options
                .ssh_program
                .clone()
                .unwrap_or_else(|| "ssh".into());
            let supported = probe_once(format!("ssh:{}", program.display()), || {
                let mut command = Command::new(&program);
                command.env_clear().arg("-V");
                if let Some(path) = std::env::var_os("PATH") {
                    command.env("PATH", path);
                }
                let output = self.run(command, None, LOCAL_TIMEOUT, 4096).ok()?;
                let text = String::from_utf8_lossy(&output.stderr).into_owned()
                    + &String::from_utf8_lossy(&output.stdout);
                let start = text.find("OpenSSH_")? + "OpenSSH_".len();
                let version = text[start..].trim_start_matches(|c: char| !c.is_ascii_digit());
                Some(version_at_least(version, (8, 7)))
            });
            if supported != Some(true) {
                return Err(Failure::SshTooOld);
            }
        }
        Ok(())
    }
    /// The commit `ref_name` points at, or None if the branch does not exist.
    pub fn remote_head(&self, endpoint: &Endpoint<'_>, ref_name: &str) -> Result<Option<String>> {
        self.ensure_tools(endpoint)?;
        let (mut command, _header) = self.network_command(endpoint);
        command.args(["ls-remote", "--refs", endpoint.url, ref_name]);
        let output = self.run(command, None, NETWORK_TIMEOUT, 16 * 1024 * 1024)?;
        if output.status != Some(0) {
            return Err(classify(&output.stderr));
        }
        let text = String::from_utf8(output.stdout).map_err(|_| Failure::Unsupported)?;
        let mut head = None;
        for line in text.lines() {
            let Some((id, name)) = line.split_once('\t') else {
                return Err(Failure::Unsupported);
            };
            if name == ref_name {
                if !git_layout::is_object_id(id) {
                    return Err(Failure::Unsupported);
                }
                head = Some(id.to_owned());
            }
        }
        Ok(head)
    }
    /// Fetches the branch tip with depth 1. Objects this cache already holds
    /// are negotiated away; nothing local is ever deleted by a fetch.
    pub fn fetch(&self, endpoint: &Endpoint<'_>, ref_name: &str) -> Result<()> {
        self.ensure_tools(endpoint)?;
        let (mut command, _header) = self.network_command(endpoint);
        command.args([
            "fetch",
            "--quiet",
            "--no-tags",
            "--no-write-fetch-head",
            "--no-recurse-submodules",
            "--no-auto-gc",
            "--no-show-forced-updates",
            "--depth=1",
            endpoint.url,
            &format!("+{ref_name}:refs/snippets/remote"),
        ]);
        let output = self.run(command, None, NETWORK_TIMEOUT, MAX_STDERR)?;
        if output.status != Some(0) {
            return Err(classify(&output.stderr));
        }
        Ok(())
    }
    /// Moves `ref_name` from `old` (None: must not exist) to `new` in one
    /// server-side compare-and-swap.
    pub fn push(
        &self,
        endpoint: &Endpoint<'_>,
        ref_name: &str,
        old: Option<&str>,
        new: &str,
    ) -> Result<PushOutcome> {
        self.ensure_tools(endpoint)?;
        let (mut command, _header) = self.network_command(endpoint);
        command.args([
            "push",
            "--porcelain",
            "--no-verify",
            "--no-signed",
            "--no-recurse-submodules",
            &format!("--force-with-lease={ref_name}:{}", old.unwrap_or("")),
            endpoint.url,
            &format!("{new}:{ref_name}"),
        ]);
        self.push_outcome(command, ref_name)
    }
    /// Succeeds only if the credential may push: hosts authorize the
    /// receive-pack advertisement only for writers. Nothing is sent.
    pub fn verify_write(&self, endpoint: &Endpoint<'_>, ref_name: &str, head: &str) -> Result<()> {
        self.ensure_tools(endpoint)?;
        let (mut command, _header) = self.network_command(endpoint);
        command.args([
            "push",
            "--porcelain",
            "--dry-run",
            "--no-verify",
            &format!("--force-with-lease={ref_name}:{head}"),
            endpoint.url,
            &format!("{head}:{ref_name}"),
        ]);
        match self.push_outcome(command, ref_name)? {
            PushOutcome::Updated => Ok(()),
            PushOutcome::Rejected => Err(Failure::Authentication),
        }
    }
    fn push_outcome(&self, command: Command, ref_name: &str) -> Result<PushOutcome> {
        let output = self.run(command, None, NETWORK_TIMEOUT, MAX_STDERR)?;
        let text = String::from_utf8_lossy(&output.stdout);
        let suffix = format!(":{ref_name}");
        let flag = text.lines().find_map(|line| {
            let mut fields = line.split('\t');
            let flag = fields.next()?;
            let refs = fields.next()?;
            (flag.len() == 1 && refs.ends_with(&suffix)).then(|| flag.as_bytes()[0])
        });
        match flag {
            Some(b' ' | b'+' | b'*' | b'=') if output.status == Some(0) => Ok(PushOutcome::Updated),
            Some(b'!') => {
                let failure = classify(&output.stderr);
                // Authorization denials and protected branches surface as
                // rejections on some hosts; neither is a race to retry.
                if matches!(
                    failure,
                    Failure::Authentication | Failure::PushTooLarge | Failure::PushRefused
                ) {
                    Err(failure)
                } else {
                    Ok(PushOutcome::Rejected)
                }
            }
            _ => Err(classify(&output.stderr)),
        }
    }

    // MARK: - Local object access

    pub fn has_commit(&self, id: &str) -> bool {
        git_layout::is_object_id(id)
            && self
                .local(&["cat-file", "-e", &format!("{id}^{{commit}}")], None)
                .is_ok()
    }
    /// Whether the cache holds `id` as a blob.
    pub fn has_blob(&self, id: &str) -> bool {
        git_layout::is_object_id(id)
            && self
                .local(&["cat-file", "-e", &format!("{id}^{{blob}}")], None)
                .is_ok()
    }
    /// The root tree of `commit`.
    pub fn commit_tree(&self, commit: &str) -> Result<String> {
        let out = self.local(
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("{commit}^{{tree}}"),
            ],
            None,
        )?;
        let id = String::from_utf8(out).map_err(|_| Failure::LocalStorage)?;
        let id = id.trim();
        if !git_layout::is_object_id(id) {
            return Err(Failure::LocalStorage);
        }
        Ok(id.to_owned())
    }
    pub fn tree_entries(&self, tree: &str) -> Result<Vec<TreeEntry>> {
        let out = self.local(&["ls-tree", "-z", "--full-tree", tree], None)?;
        parse_tree(&out)
    }
    /// Every entry below `tree`, keyed by its path components.
    pub fn tree_recursive(&self, tree: &str) -> Result<Vec<(Vec<Vec<u8>>, TreeEntry)>> {
        let out = self.local(&["ls-tree", "-r", "-t", "-z", "--full-tree", tree], None)?;
        Ok(parse_tree(&out)?
            .into_iter()
            .map(|entry| {
                let path = entry
                    .name
                    .split(|b| *b == b'/')
                    .map(<[u8]>::to_vec)
                    .collect();
                (path, entry)
            })
            .collect())
    }
    /// Blob contents for `ids`, verified to be blobs.
    pub fn blobs(&self, ids: &[String]) -> Result<BTreeMap<String, Vec<u8>>> {
        let mut result = BTreeMap::new();
        if ids.is_empty() {
            return Ok(result);
        }
        let mut input = Vec::new();
        for id in ids {
            if !git_layout::is_object_id(id) {
                return Err(Failure::LocalStorage);
            }
            input.extend_from_slice(id.as_bytes());
            input.push(b'\n');
        }
        let out = self.local(&["cat-file", "--batch"], Some(&input))?;
        let mut rest = out.as_slice();
        for id in ids {
            let newline = rest
                .iter()
                .position(|b| *b == b'\n')
                .ok_or(Failure::LocalStorage)?;
            let header =
                std::str::from_utf8(&rest[..newline]).map_err(|_| Failure::LocalStorage)?;
            let fields: Vec<_> = header.split(' ').collect();
            let [object, "blob", size] = fields.as_slice() else {
                return Err(Failure::LocalStorage);
            };
            let size: usize = size.parse().map_err(|_| Failure::LocalStorage)?;
            if object != id || rest.len() < newline + 1 + size + 1 {
                return Err(Failure::LocalStorage);
            }
            let body = &rest[newline + 1..newline + 1 + size];
            result.insert(id.clone(), body.to_vec());
            rest = &rest[newline + 1 + size + 1..];
        }
        Ok(result)
    }
    pub fn write_blob(&self, bytes: &[u8]) -> Result<String> {
        let out = self.local(&["hash-object", "-w", "-t", "blob", "--stdin"], Some(bytes))?;
        object_id(&out)
    }
    pub fn write_tree(&self, entries: &[TreeEntry]) -> Result<String> {
        let mut input = Vec::new();
        for entry in entries {
            if entry.name.is_empty() || entry.name.contains(&0) || entry.name.contains(&b'/') {
                return Err(Failure::LocalStorage);
            }
            input.extend_from_slice(
                format!("{} {} {}\t", entry.mode, entry.kind, entry.id).as_bytes(),
            );
            input.extend_from_slice(&entry.name);
            input.push(0);
        }
        let out = self.local(&["mktree", "-z"], Some(&input))?;
        object_id(&out)
    }
    /// A commit with the fixed Snippets authorship and a UTC timestamp.
    pub fn write_commit(
        &self,
        tree: &str,
        parent: Option<&str>,
        message: &str,
        seconds: i64,
    ) -> Result<String> {
        let mut command = self.base_command(false);
        let date = format!("@{seconds} +0000");
        command
            .env("GIT_AUTHOR_NAME", git_layout::AUTHOR_NAME)
            .env("GIT_AUTHOR_EMAIL", git_layout::AUTHOR_EMAIL)
            .env("GIT_AUTHOR_DATE", &date)
            .env("GIT_COMMITTER_NAME", git_layout::AUTHOR_NAME)
            .env("GIT_COMMITTER_EMAIL", git_layout::AUTHOR_EMAIL)
            .env("GIT_COMMITTER_DATE", &date)
            .args(["commit-tree", "--no-gpg-sign", tree]);
        if let Some(parent) = parent {
            command.args(["-p", parent]);
        }
        command.args(["-m", message]);
        let output = self.run(command, None, LOCAL_TIMEOUT, MAX_STDERR)?;
        if output.status != Some(0) {
            return Err(Failure::LocalStorage);
        }
        object_id(&output.stdout)
    }
    /// Retains a commit this cache may later diff from or build on. The cache
    /// never runs gc, so this only documents intent and survives a manual gc.
    pub fn keep(&self, commit: &str) -> Result<()> {
        if !git_layout::is_object_id(commit) {
            return Err(Failure::LocalStorage);
        }
        self.local(
            &[
                "update-ref",
                "--no-deref",
                &format!("refs/snippets/keep/{commit}"),
                commit,
            ],
            None,
        )
        .map(|_| ())
    }
}

/// Tool version checks, cached per process by tool (and ssh program).
static TOOL_CHECKS: std::sync::Mutex<BTreeMap<String, bool>> =
    std::sync::Mutex::new(BTreeMap::new());
fn probe_once(key: String, probe: impl FnOnce() -> Option<bool>) -> Option<bool> {
    if let Some(known) = TOOL_CHECKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&key)
    {
        return Some(*known);
    }
    // A tool that could not run is not remembered: it may be installed later.
    let result = probe()?;
    TOOL_CHECKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(key, result);
    Some(result)
}
/// `2.47.1 …` or `9.6p1, …` compared with a minimum (major, minor).
pub(crate) fn version_at_least(text: &str, minimum: (u32, u32)) -> bool {
    let number = |part: Option<&str>| -> Option<u32> {
        let digits: String = part?.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    };
    let mut parts = text.trim().split('.');
    match (number(parts.next()), number(parts.next())) {
        (Some(major), Some(minor)) => (major, minor) >= minimum,
        _ => false,
    }
}
fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}
fn bounded_read(reader: &mut impl Read, limit: usize) -> (Vec<u8>, bool) {
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    let mut overflow = false;
    loop {
        match reader.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(count) => {
                if bytes.len() + count > limit {
                    overflow = true;
                    // Keep draining so the child never blocks on a full pipe.
                    continue;
                }
                bytes.extend_from_slice(&chunk[..count]);
            }
        }
    }
    (bytes, overflow)
}
fn object_id(out: &[u8]) -> Result<String> {
    let text = std::str::from_utf8(out)
        .map_err(|_| Failure::LocalStorage)?
        .trim();
    if !git_layout::is_object_id(text) {
        return Err(Failure::LocalStorage);
    }
    Ok(text.to_owned())
}
fn parse_tree(out: &[u8]) -> Result<Vec<TreeEntry>> {
    let mut entries = Vec::new();
    for record in out.split(|b| *b == 0).filter(|r| !r.is_empty()) {
        let tab = record
            .iter()
            .position(|b| *b == b'\t')
            .ok_or(Failure::LocalStorage)?;
        let header = std::str::from_utf8(&record[..tab]).map_err(|_| Failure::LocalStorage)?;
        let fields: Vec<_> = header.split(' ').collect();
        let [mode, kind, id] = fields.as_slice() else {
            return Err(Failure::LocalStorage);
        };
        if !git_layout::is_object_id(id) {
            return Err(Failure::LocalStorage);
        }
        entries.push(TreeEntry {
            mode: (*mode).to_owned(),
            kind: (*kind).to_owned(),
            id: (*id).to_owned(),
            name: record[tab + 1..].to_vec(),
        });
    }
    Ok(entries)
}
/// Maps git's (C-locale) stderr to a closed failure. The text is dropped.
///
/// Over SSH, stderr also carries whatever the remote account's login scripts
/// print ("command not found", "permission denied" on some dotfile). Only
/// ssh's own messages, git's own messages and host replies are matched, so
/// that noise never turns into an authentication or not-found failure.
fn classify(stderr: &[u8]) -> Failure {
    let text = String::from_utf8_lossy(stderr).to_ascii_lowercase();
    let any = |needles: &[&str]| needles.iter().any(|n| text.contains(n));
    if any(&[
        "http 413",
        "returned error: 413",
        "request entity too large",
    ]) {
        Failure::PushTooLarge
    } else if any(&[
        "host key verification failed",
        "remote host identification has changed",
        "host key for ",
    ]) {
        Failure::HostKeyUnverified
    } else if any(&[
        "no matching key exchange method found",
        "no matching cipher found",
        "no matching mac found",
        "no matching host key type found",
        "dumb http transport",
        "transport '",
        "unexpected http status",
        "invalid server response",
        "protocol error: bad",
    ]) {
        Failure::Unsupported
    } else if any(&["http 429", "returned error: 429"]) {
        Failure::RateLimited
    } else if any(&[
        // GitLab: the branch is protected for this user or key.
        "not allowed to push code to protected branches",
        "protected branch hook declined",
    ]) {
        Failure::PushRefused
    } else if any(&[
        // Read-only deploy keys and tokens (GitHub, GitLab, Gitea/Forgejo),
        // as Apple's GitSSHClient.
        "marked as read only",
        "write access",
        "denied to deploy key",
        "read-only key",
        "deploy key is read",
        // ssh's own refusal; never a bare "permission denied".
        "permission denied (",
        "too many authentication failures",
        // git over HTTP(S).
        "authentication failed for",
        "could not read username",
        "could not read password",
        "returned error: 401",
        "returned error: 403",
        "http 401",
        "http 403",
        // Hosted refusals over SSH (GitHub, GitLab, Gitea/Forgejo).
        "error: permission to ",
        "you are not allowed to",
        "user permission denied",
    ]) {
        Failure::Authentication
    } else if any(&[
        "repository not found",
        "returned error: 404",
        "does not appear to be a git repository",
    ]) || text.contains("fatal: repository '") && text.contains("' not found")
    {
        Failure::RepositoryNotFound
    } else {
        // Connection, resolution and timeout failures, and anything unknown.
        Failure::Unreachable
    }
}

#[cfg(test)]
pub(crate) fn classify_for_tests(stderr: &str) -> Failure {
    classify(stderr.as_bytes())
}
