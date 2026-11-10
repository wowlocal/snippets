//! Where a Git library lives and as whom to reach it. Parsing and the
//! scheme-independent repository identity match the Apple implementation byte
//! for byte: the identity feeds key scopes and account/dataset digests.
//!
//! No type here implements `Debug` or `Display` with a token; locations are
//! user configuration, never diagnostics.
use url::Url;
use zeroize::Zeroizing;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    InvalidLocation,
    InvalidBranch,
    InvalidUsername,
    InvalidToken,
}

/// One SSH destination, as git understands it. `scp` keeps `user@host:path`
/// (relative to the server account) distinct from `ssh://host/path`.
#[derive(Clone, PartialEq, Eq)]
pub struct SshLocation {
    user: Option<String>,
    host: String,
    port: Option<u16>,
    path: String,
    scp: bool,
}
impl SshLocation {
    /// The HTTPS host of a well-known forge this SSH address points at, if it
    /// does (Apple `publicForgeHost`).
    fn public_forge_host(&self) -> Option<&'static str> {
        match (
            self.host.to_ascii_lowercase().as_str(),
            self.port.unwrap_or(22),
        ) {
            ("github.com", 22) | ("ssh.github.com", 22 | 443) => Some("github.com"),
            ("gitlab.com", 22) | ("altssh.gitlab.com", 443) => Some("gitlab.com"),
            ("codeberg.org", 22) => Some("codeberg.org"),
            ("bitbucket.org", 22) => Some("bitbucket.org"),
            _ => None,
        }
    }
    /// Conservative character sets: these values reach an ssh command line and
    /// a remote shell, so nothing that could become an option or a
    /// metacharacter passes.
    fn new(
        user: Option<String>,
        host: String,
        port: Option<u16>,
        path: String,
        scp: bool,
    ) -> Result<Self, Failure> {
        let allowed = |text: &str, extra: &[u8]| {
            !text.is_empty()
                && text
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || extra.contains(&b))
        };
        let user_ok = user
            .as_deref()
            .is_none_or(|u| allowed(u, b"._-") && !u.starts_with('-'));
        let host_ok = allowed(&host, b".-_:") && !host.starts_with('-') && !host.starts_with('.');
        let port_ok = port.is_none_or(|p| p != 0);
        // '%' too: the path is already percent-decoded once, exactly as on Apple.
        const FORBIDDEN: &str = "'\\\"`$;&|<>(){}*?[]!#%";
        let path_ok = (1..=1024).contains(&path.len())
            && !path.starts_with('-')
            && path
                .chars()
                .all(|c| c as u32 > 0x20 && c as u32 != 0x7f && !FORBIDDEN.contains(c))
            && !path.split('/').any(|segment| segment == "..");
        if !(user_ok && host_ok && port_ok && path_ok) {
            return Err(Failure::InvalidLocation);
        }
        Ok(Self {
            user,
            host,
            port,
            path,
            scp,
        })
    }
    fn destination(&self) -> String {
        match &self.user {
            Some(user) => format!("{user}@{}", self.host),
            None => self.host.clone(),
        }
    }
    /// The normalized text stored in configuration and handed to git.
    pub fn spec(&self) -> String {
        if self.scp {
            return format!("{}:{}", self.destination(), self.path);
        }
        let host = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        let user = self
            .user
            .as_ref()
            .map(|u| format!("{u}@"))
            .unwrap_or_default();
        let port = self.port.map(|p| format!(":{p}")).unwrap_or_default();
        format!("ssh://{user}{host}{port}{}", self.path)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct HttpsLocation {
    /// Lowercase scheme and host; no credentials, query, fragment or trailing slash.
    url: String,
    host: String,
    /// Percent-decoded path, as Foundation's `URL.path` reports it.
    path: String,
}
impl HttpsLocation {
    /// The port, 443 when the address names none (as Apple compares them).
    fn port(&self) -> u16 {
        Url::parse(&self.url)
            .ok()
            .and_then(|url| url.port())
            .unwrap_or(443)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub enum Location {
    Https(HttpsLocation),
    Ssh(SshLocation),
}
impl Location {
    pub fn is_ssh(&self) -> bool {
        matches!(self, Self::Ssh(_))
    }
    /// `ssh -T [-p port] [user@]host`, the command that checks (and on first
    /// use records) the host key in a terminal, as Apple's `testCommand`.
    pub fn ssh_test_command(&self) -> Option<String> {
        let Self::Ssh(ssh) = self else {
            return None;
        };
        let port = ssh
            .port
            .filter(|port| *port != 22)
            .map(|port| format!("-p {port} "))
            .unwrap_or_default();
        let user = ssh
            .user
            .as_ref()
            .map(|u| format!("{u}@"))
            .unwrap_or_default();
        Some(format!("ssh -T {port}{user}{}", ssh.host))
    }
    /// Where to ask whether anyone can clone the repository without signing
    /// in (Apple `visibility(of:)`): the HTTPS address itself, or for an SSH
    /// address at a well-known forge (`public_forge_host`) that forge's HTTPS
    /// address with the same path. Any other SSH host is never guessed.
    pub fn public_probe_base(&self) -> Option<String> {
        match self {
            Self::Https(https) => Some(https.url.clone()),
            Self::Ssh(ssh) => Some(format!(
                "https://{}/{}",
                ssh.public_forge_host()?,
                ssh.path.trim_matches('/')
            )),
        }
    }
    /// One repository reached two ways (Apple `sameEndpoint`): the same
    /// canonical identity, so a device may move between HTTPS and SSH; between
    /// two SSH addresses also the same account and port (they can select
    /// another home directory or daemon); between two HTTPS addresses the same
    /// port.
    pub fn same_endpoint(&self, other: &Self) -> bool {
        if self.canonical_identity() != other.canonical_identity() {
            return false;
        }
        match (self, other) {
            (Self::Ssh(a), Self::Ssh(b)) => {
                a.user.as_deref().unwrap_or("") == b.user.as_deref().unwrap_or("")
                    && a.port.unwrap_or(22) == b.port.unwrap_or(22)
            }
            (Self::Https(a), Self::Https(b)) => a.port() == b.port(),
            _ => true,
        }
    }
    /// The normalized text stored in configuration and handed to git.
    pub fn spec(&self) -> String {
        match self {
            Self::Https(https) => https.url.clone(),
            Self::Ssh(ssh) => ssh.spec(),
        }
    }
    /// `host/path`: lowercase host, no scheme, user, port, leading `/` or
    /// `.git`. `git@github.com:me/lib.git` and `https://github.com/me/lib/`
    /// are one repository, so one library key and sync state serve both.
    pub fn canonical_identity(&self) -> String {
        let (host, path) = match self {
            Self::Https(https) => (https.host.as_str(), https.path.as_str()),
            Self::Ssh(ssh) => (ssh.host.as_str(), ssh.path.as_str()),
        };
        let mut path = path.trim_start_matches('/');
        if let Some(stripped) = path.strip_suffix(".git") {
            path = stripped;
        }
        let path = path.trim_end_matches('/');
        format!("{}/{path}", host.to_lowercase())
    }
    /// Accepts `https://…`, `ssh://[user@]host[:port]/path` (also `git+ssh://`)
    /// and scp-like `[user@]host:path`. A bare `host/path` is read as HTTPS.
    /// Plain HTTP is accepted only for loopback hosts when a test opts in.
    pub fn parse(raw: &str, insecure_loopback: bool) -> Result<Self, Failure> {
        let text = raw.trim();
        if text.is_empty()
            || text.len() > 2048
            || text.chars().any(|c| c as u32 <= 0x20 || c as u32 == 0x7f)
        {
            return Err(Failure::InvalidLocation);
        }
        let lower = text.to_ascii_lowercase();
        for scheme in ["ssh://", "git+ssh://"] {
            if lower.starts_with(scheme) {
                return parse_ssh_url(&text[scheme.len()..]).map(Self::Ssh);
            }
        }
        if text.contains("://") {
            return normalized_https(text, insecure_loopback).map(Self::Https);
        }
        // scp-like: the first ':' comes before any '/'.
        if let Some(colon) = text.find(':')
            && !text[..colon].contains('/')
        {
            let destination = &text[..colon];
            let path = &text[colon + 1..];
            let (user, host) = match destination.rfind('@') {
                Some(at) => (Some(destination[..at].to_owned()), &destination[at + 1..]),
                None => (None, destination),
            };
            return SshLocation::new(user, host.to_owned(), None, path.to_owned(), true)
                .map(Self::Ssh);
        }
        normalized_https(&format!("https://{text}"), insecure_loopback).map(Self::Https)
    }
}

fn parse_ssh_url(tail: &str) -> Result<SshLocation, Failure> {
    if tail.contains(['?', '#']) {
        return Err(Failure::InvalidLocation);
    }
    let slash = tail.find('/').ok_or(Failure::InvalidLocation)?;
    let (authority, encoded_path) = tail.split_at(slash);
    let (user, host_port) = match authority.rfind('@') {
        Some(at) => {
            let info = &authority[..at];
            if info.contains(':') {
                return Err(Failure::InvalidLocation);
            }
            (Some(percent_decoded(info)), &authority[at + 1..])
        }
        None => (None, authority),
    };
    let (host, port) = if let Some(rest) = host_port.strip_prefix('[') {
        let close = rest.find(']').ok_or(Failure::InvalidLocation)?;
        let port = &rest[close + 1..];
        (
            rest[..close].to_owned(),
            match port {
                "" => None,
                port => Some(parse_port(
                    port.strip_prefix(':').ok_or(Failure::InvalidLocation)?,
                )?),
            },
        )
    } else {
        match host_port.rsplit_once(':') {
            Some((host, port)) => (host.to_owned(), Some(parse_port(port)?)),
            None => (host_port.to_owned(), None),
        }
    };
    let host = percent_decoded(&host);
    let path = percent_decoded(encoded_path);
    if !path.starts_with('/') {
        return Err(Failure::InvalidLocation);
    }
    SshLocation::new(user, host, port, path, false)
}
fn parse_port(text: &str) -> Result<u16, Failure> {
    if text.is_empty() || text.len() > 5 || !text.bytes().all(|b| b.is_ascii_digit()) {
        return Err(Failure::InvalidLocation);
    }
    match text.parse::<u32>() {
        Ok(port @ 1..=65535) => Ok(port as u16),
        _ => Err(Failure::InvalidLocation),
    }
}
/// Foundation's `removingPercentEncoding`, falling back to the original text
/// for malformed escapes or non-UTF-8 results, exactly as the Apple code does.
fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = |b: u8| (b as char).to_digit(16);
            match (
                bytes.get(index + 1).copied().and_then(hex),
                bytes.get(index + 2).copied().and_then(hex),
            ) {
                (Some(high), Some(low)) => {
                    out.push((high * 16 + low) as u8);
                    index += 3;
                    continue;
                }
                _ => return text.to_owned(),
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}
fn normalized_https(text: &str, insecure_loopback: bool) -> Result<HttpsLocation, Failure> {
    if text.contains('\\') {
        return Err(Failure::InvalidLocation);
    }
    let url = Url::parse(text).map_err(|_| Failure::InvalidLocation)?;
    let host = url
        .host_str()
        .filter(|h| !h.is_empty())
        .ok_or(Failure::InvalidLocation)?
        .to_ascii_lowercase();
    let bare = host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_owned();
    // Only literal loopback addresses: a name (even `localhost`) could be
    // made to resolve elsewhere.
    let loopback = bare
        .parse::<std::net::IpAddr>()
        .is_ok_and(|address| address.is_loopback());
    if !(url.scheme() == "https" || url.scheme() == "http" && insecure_loopback && loopback)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(Failure::InvalidLocation);
    }
    let encoded = url.path().trim_end_matches('/');
    if encoded.is_empty() {
        return Err(Failure::InvalidLocation);
    }
    let port = url.port().map(|p| format!(":{p}")).unwrap_or_default();
    Ok(HttpsLocation {
        url: format!("{}://{host}{port}{encoded}", url.scheme()),
        host: bare,
        path: percent_decoded(encoded),
    })
}

/// A conservative subset of `git check-ref-format`, identical to the Apple rule.
pub fn valid_branch(branch: &str) -> bool {
    (1..=200).contains(&branch.len())
        && branch
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_./".contains(&b))
        && !branch.starts_with('-')
        && !branch.starts_with('/')
        && !branch.ends_with('/')
        && !branch.ends_with('.')
        && !branch.ends_with(".lock")
        && !branch.contains("..")
        && !branch.contains("//")
        && branch != "HEAD"
        && !branch.split('/').any(|c| c.starts_with('.'))
}
pub fn valid_username(username: &str) -> bool {
    (1..=256).contains(&username.len())
        && !username.contains(':')
        && username
            .chars()
            .all(|c| c as u32 >= 0x20 && c as u32 != 0x7f)
}
pub fn valid_token(token: &str) -> bool {
    (1..=4096).contains(&token.len()) && token.chars().all(|c| c as u32 >= 0x20 && c as u32 != 0x7f)
}

/// HTTPS Basic pair: every mainstream host accepts a personal access token as
/// the password for its smart-HTTP endpoint. No Debug, Display or Clone.
pub struct HttpCredential {
    username: String,
    token: Zeroizing<String>,
}
impl HttpCredential {
    pub fn new(username: &str, token: Zeroizing<String>) -> Result<Self, Failure> {
        if !valid_username(username) {
            return Err(Failure::InvalidUsername);
        }
        if !valid_token(&token) {
            return Err(Failure::InvalidToken);
        }
        Ok(Self {
            username: username.to_owned(),
            token,
        })
    }
    /// An independent zeroizing copy for another owner (a transport, the keyring).
    pub(crate) fn duplicate(&self) -> Self {
        Self {
            username: self.username.clone(),
            token: Zeroizing::new(self.token.as_str().to_owned()),
        }
    }
    pub fn username(&self) -> &str {
        &self.username
    }
    pub(crate) fn token(&self) -> &str {
        &self.token
    }
    /// `Authorization: Basic …`, for an environment-only git config value.
    pub(crate) fn header(&self) -> Zeroizing<String> {
        use base64::{Engine, engine::general_purpose::STANDARD};
        let pair = Zeroizing::new(format!("{}:{}", self.username, self.token.as_str()));
        Zeroizing::new(format!(
            "Authorization: Basic {}",
            STANDARD.encode(pair.as_bytes())
        ))
    }
}

/// A repository location plus the one branch that holds the library.
#[derive(Clone, PartialEq, Eq)]
pub struct Remote {
    pub location: Location,
    pub branch: String,
}
impl Remote {
    pub fn new(location: Location, branch: &str) -> Result<Self, Failure> {
        if !valid_branch(branch) {
            return Err(Failure::InvalidBranch);
        }
        Ok(Self {
            location,
            branch: branch.to_owned(),
        })
    }
    pub fn ref_name(&self) -> String {
        format!("refs/heads/{}", self.branch)
    }
    pub fn canonical_location(&self) -> String {
        self.location.canonical_identity()
    }
}
