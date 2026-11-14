//! The `snippets-cli` skill for AI coding agents. Mirrors `snippets/Core/AgentSkill.swift`:
//! the same stub, places, folder rules, states and outcomes on both platforms. Used by
//! `snippets-cli skill` and by the Settings window.
//!
//! The guide is built into the binary, generated with the stub and the default rules from
//! `agent-skill/` by `scripts/agent-skill.py`. `install` writes a stub that tells the agent
//! to run `snippets-cli skill`. The user's do/don't rules and the skill description live in
//! `$XDG_CONFIG_HOME/snippets/agent-rules.md`, which updates never touch. Custom skills
//! folders are remembered in `agent-skill.json` beside it; owned stubs on disk are the
//! record of the built-in places. The rules are advice to an agent; secure reveals stay
//! gated by the app's own approval.
//!
//! Unlike the Mac, Linux follows `XDG_CONFIG_HOME`: the desktop session gives the app and
//! the terminal the same environment.

use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    io::{self, Write},
    os::unix::fs::PermissionsExt,
    path::{Component, Path, PathBuf},
};

pub const GUIDE: &str = include_str!("agent_skill/guide.md");
pub const DEFAULT_RULES: &str = include_str!("agent_skill/rules.md");
const STUB_TEMPLATE: &str = include_str!("agent_skill/stub.md");
const SKILL_NAME: &str = "snippets-cli";
const STUB_MARKER: &str = "snippets-cli-stub:";
/// Agents truncate or reject longer descriptions.
pub const MAX_DESCRIPTION_CHARS: usize = 1024;

/// A built-in place an agent looks for skills.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, clap::ValueEnum)]
pub enum Target {
    Claude,
    Agents,
    Codex,
}

impl Target {
    pub const ALL: [Target; 3] = [Target::Claude, Target::Agents, Target::Codex];

    pub fn name(self) -> &'static str {
        match self {
            Target::Claude => "claude",
            Target::Agents => "agents",
            Target::Codex => "codex",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Target::Claude => "Claude Code",
            Target::Agents => "Codex and other agents",
            Target::Codex => "Codex (older folder)",
        }
    }
}

/// Where a stub can go: a built-in target or a skills folder the user chose.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Place {
    Target(Target),
    /// An absolute, normalised skills folder; the stub goes in `snippets-cli/SKILL.md`.
    Folder(PathBuf),
}

impl Place {
    pub fn display_name(&self) -> &'static str {
        match self {
            Place::Target(target) => target.display_name(),
            Place::Folder(_) => "Custom folder",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Wrote,
    Unchanged,
    /// A `SKILL.md` that `install` did not write. Never touched.
    Skipped,
    /// The custom folder no longer exists. Never recreated.
    Missing,
    Removed,
    Absent,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Wrote => "wrote",
            Outcome::Unchanged => "unchanged",
            Outcome::Skipped => "skipped",
            Outcome::Missing => "missing",
            Outcome::Removed => "removed",
            Outcome::Absent => "absent",
        }
    }
}

#[derive(Debug)]
pub struct Change {
    pub place: Place,
    pub path: PathBuf,
    pub outcome: Outcome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaceState {
    Installed,
    NotInstalled,
    Foreign,
    Missing,
}

impl PlaceState {
    pub fn as_str(self) -> &'static str {
        match self {
            PlaceState::Installed => "installed",
            PlaceState::NotInstalled => "notInstalled",
            PlaceState::Foreign => "foreign",
            PlaceState::Missing => "missing",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlaceStatus {
    pub place: Place,
    pub skills_folder: PathBuf,
    pub stub_path: PathBuf,
    /// For a built-in target: whether that agent's folder exists here.
    pub detected: bool,
    pub state: PlaceState,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Status {
    pub rules_path: PathBuf,
    pub rules_are_custom: bool,
    /// Every built-in target, then every remembered folder.
    pub places: Vec<PlaceStatus>,
}

#[derive(Debug, PartialEq)]
pub struct Rules {
    pub description: String,
    pub body: String,
    pub is_custom: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FolderError {
    NotFound(PathBuf),
    LooksLikeProject(PathBuf),
}

impl std::fmt::Display for FolderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FolderError::NotFound(path) => write!(f, "{} does not exist.", path.display()),
            FolderError::LooksLikeProject(path) => write!(
                f,
                "{0} looks like a project folder. Use {0}/.claude/skills or {0}/.agents/skills.",
                path.display()
            ),
        }
    }
}

impl std::error::Error for FolderError {}

/// The parts of the process environment this module reads, so tests never touch the
/// real home directory.
pub struct Environment {
    pub home: PathBuf,
    pub variables: HashMap<String, String>,
}

impl Environment {
    pub fn current() -> Option<Self> {
        let variables: HashMap<_, _> = std::env::vars().collect();
        let home = variables.get("HOME").filter(|v| !v.is_empty())?.into();
        Some(Environment { home, variables })
    }

    fn directory(&self, variable: &str, relative: &str) -> PathBuf {
        match self.variables.get(variable).filter(|v| !v.is_empty()) {
            Some(value) => PathBuf::from(value),
            None => self.home.join(relative),
        }
    }

    pub fn skills_folder(&self, place: &Place) -> PathBuf {
        match place {
            Place::Target(Target::Claude) => self
                .directory("CLAUDE_CONFIG_DIR", ".claude")
                .join("skills"),
            Place::Target(Target::Agents) => self.home.join(".agents/skills"),
            Place::Target(Target::Codex) => self.directory("CODEX_HOME", ".codex").join("skills"),
            Place::Folder(path) => path.clone(),
        }
    }

    pub fn stub_path(&self, place: &Place) -> PathBuf {
        self.skills_folder(place).join(SKILL_NAME).join("SKILL.md")
    }

    fn config_folder(&self) -> PathBuf {
        self.directory("XDG_CONFIG_HOME", ".config")
            .join("snippets")
    }

    pub fn rules_path(&self) -> PathBuf {
        self.config_folder().join("agent-rules.md")
    }

    fn folders_path(&self) -> PathBuf {
        self.config_folder().join("agent-skill.json")
    }

    /// The root folder of a built-in target's agent.
    fn agent_home(&self, target: Target) -> PathBuf {
        let folder = self.skills_folder(&Place::Target(target));
        folder.parent().map(Path::to_path_buf).unwrap_or(folder)
    }

    /// Claude Code when it is set up here, and always `~/.agents/skills`, which Codex and
    /// other agents read. Not `~/.codex/skills` as well: it would list the skill twice.
    pub fn default_targets(&self) -> Vec<Target> {
        if self.agent_home(Target::Claude).is_dir() {
            vec![Target::Claude, Target::Agents]
        } else {
            vec![Target::Agents]
        }
    }

    /// `~/…` for paths under the home directory.
    pub fn display(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(relative) => format!("~/{}", relative.display()),
            Err(_) => path.display().to_string(),
        }
    }
}

// MARK: Custom folders

/// Removes `.` and `..` without touching the disk, so symlinks stay as typed.
fn normalized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other),
        }
    }
    out
}

/// Resolves symlinks through the deepest part of the path that exists, then appends the
/// rest, so a vanished folder still compares equal to how it was saved.
fn canonical(path: &Path) -> PathBuf {
    let mut existing = normalized(path);
    let mut rest = Vec::new();
    while !existing.exists() {
        match (
            existing.file_name().map(|n| n.to_os_string()),
            existing.parent(),
        ) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                existing = parent.to_path_buf();
            }
            _ => break,
        }
    }
    let mut out = fs::canonicalize(&existing).unwrap_or(existing);
    out.extend(rest.into_iter().rev());
    normalized(&out)
}

/// Same folder by path, or once symlinks in the existing part are resolved.
fn same_folder(a: &Path, b: &Path) -> bool {
    normalized(a) == normalized(b) || canonical(a) == canonical(b)
}

fn file_name(path: &Path) -> &str {
    path.file_name().and_then(|n| n.to_str()).unwrap_or("")
}

/// A short name for a custom skills folder in Settings: the project for
/// `app/.claude/skills`, otherwise the folder's own name.
pub fn folder_title(path: &Path) -> String {
    let parts: Vec<&str> = path
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .collect();
    let n = parts.len();
    if n >= 3
        && parts[n - 1] == "skills"
        && [".claude", ".agents", ".codex"].contains(&parts[n - 2])
    {
        return parts[n - 3].to_string();
    }
    file_name(path).to_string()
}

/// Whether a custom skills folder exists or may be created (only its last part).
fn can_hold(folder: &Path) -> bool {
    folder.is_dir() || (file_name(folder) == "skills" && folder.parent().is_some_and(Path::is_dir))
}

/// Turns what the user typed or picked into a place; see `AgentSkill.resolveFolder`.
///
/// | Input ends in                         | Means                         |
/// |---------------------------------------|-------------------------------|
/// | `snippets-cli`                        | its parent (the skill folder) |
/// | `.claude`, `.agents`, `.codex`        | that folder's `skills`        |
/// | a folder holding `.claude`/`.agents`  | refused: a project root       |
/// | anything else                         | the skills folder itself      |
///
/// With `must_exist`, the folder must exist, except that a final `skills` may be created
/// later. To forget a folder only the path is normalised: it may be long gone.
pub fn resolve_folder(
    input: &str,
    current_directory: &Path,
    environment: &Environment,
    must_exist: bool,
) -> Result<Place, FolderError> {
    let expanded = if input == "~" {
        environment.home.clone()
    } else if let Some(rest) = input.strip_prefix("~/") {
        environment.home.join(rest)
    } else {
        PathBuf::from(input)
    };
    let mut path = normalized(&current_directory.join(expanded));
    if file_name(&path) == SKILL_NAME {
        path.pop();
    }
    if [".claude", ".agents", ".codex"].contains(&file_name(&path)) {
        path.push("skills");
    }
    for target in Target::ALL {
        if same_folder(&environment.skills_folder(&Place::Target(target)), &path) {
            return Ok(Place::Target(target));
        }
    }
    if !must_exist {
        return Ok(Place::Folder(path));
    }
    if file_name(&path) != "skills"
        && path.is_dir()
        && (path.join(".claude").is_dir() || path.join(".agents").is_dir())
    {
        return Err(FolderError::LooksLikeProject(path));
    }
    if !can_hold(&path) {
        return Err(FolderError::NotFound(path));
    }
    Ok(Place::Folder(path))
}

#[derive(Serialize, Deserialize)]
struct FoldersFile {
    version: u32,
    folders: Vec<String>,
}

pub fn remembered_folders(environment: &Environment) -> Vec<PathBuf> {
    fs::read(environment.folders_path())
        .ok()
        .and_then(|data| serde_json::from_slice::<FoldersFile>(&data).ok())
        .map(|file| {
            file.folders
                .into_iter()
                .filter(|f| f.starts_with('/'))
                .map(|f| normalized(Path::new(&f)))
                .collect()
        })
        .unwrap_or_default()
}

fn save_folders(environment: &Environment, folders: &[PathBuf]) -> io::Result<()> {
    let path = environment.folders_path();
    if folders.is_empty() {
        return match fs::remove_file(&path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        };
    }
    let file = FoldersFile {
        version: 1,
        folders: folders.iter().map(|f| f.display().to_string()).collect(),
    };
    let text = serde_json::to_string_pretty(&file).map_err(io::Error::other)? + "\n";
    write_atomically(&path, text.as_bytes())
}

fn remember(environment: &Environment, folder: &Path) -> io::Result<()> {
    let mut folders = remembered_folders(environment);
    if folders.iter().any(|f| same_folder(f, folder)) {
        return Ok(());
    }
    folders.push(folder.to_path_buf());
    save_folders(environment, &folders)
}

fn forget(environment: &Environment, folder: &Path) -> io::Result<()> {
    let folders = remembered_folders(environment);
    let kept: Vec<_> = folders
        .iter()
        .filter(|f| !same_folder(f, folder))
        .cloned()
        .collect();
    if kept.len() == folders.len() {
        return Ok(());
    }
    save_folders(environment, &kept)
}

// MARK: Status

pub fn status(environment: &Environment) -> io::Result<Status> {
    let places = Target::ALL.into_iter().map(Place::Target).chain(
        remembered_folders(environment)
            .into_iter()
            .map(Place::Folder),
    );
    Ok(Status {
        rules_path: environment.rules_path(),
        rules_are_custom: current_rules(environment)?.is_custom,
        places: places.map(|p| place_status(environment, p)).collect(),
    })
}

pub fn place_status(environment: &Environment, place: Place) -> PlaceStatus {
    let skills_folder = environment.skills_folder(&place);
    let stub_path = environment.stub_path(&place);
    let detected = match place {
        Place::Target(Target::Agents) | Place::Folder(_) => true,
        Place::Target(target) => environment.agent_home(target).is_dir(),
    };
    let state = if matches!(place, Place::Folder(_)) && !can_hold(&skills_folder) {
        PlaceState::Missing
    } else {
        match fs::read_to_string(&stub_path) {
            Ok(text) if is_stub(&text) => PlaceState::Installed,
            Ok(_) => PlaceState::Foreign,
            Err(error) if error.kind() == io::ErrorKind::NotFound => PlaceState::NotInstalled,
            Err(_) => PlaceState::Foreign,
        }
    };
    PlaceStatus {
        place,
        skills_folder,
        stub_path,
        detected,
        state,
    }
}

/// Places holding our stub, without falling back to defaults.
pub fn installed_places(environment: &Environment) -> io::Result<Vec<Place>> {
    Ok(status(environment)?
        .places
        .into_iter()
        .filter(|p| p.state == PlaceState::Installed)
        .map(|p| p.place)
        .collect())
}

/// What a plain `install` rewrites: every built-in target holding our stub and every
/// remembered folder (a vanished one is reported, not recreated). Only when the user has
/// chosen nothing yet does it fall back to the default targets.
pub fn refresh_places(environment: &Environment) -> io::Result<Vec<Place>> {
    let installed: Vec<Place> = status(environment)?
        .places
        .into_iter()
        .filter(|p| matches!(p.place, Place::Folder(_)) || p.state == PlaceState::Installed)
        .map(|p| p.place)
        .collect();
    Ok(if installed.is_empty() {
        environment
            .default_targets()
            .into_iter()
            .map(Place::Target)
            .collect()
    } else {
        installed
    })
}

// MARK: Rules

pub fn default_rules() -> Rules {
    let (description, body) = parse_rules(DEFAULT_RULES);
    Rules {
        description: description.unwrap_or_default(),
        body,
        is_custom: false,
    }
}

pub fn current_rules(environment: &Environment) -> io::Result<Rules> {
    let text = match fs::read_to_string(environment.rules_path()) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(default_rules()),
        Err(error) => return Err(error),
    };
    let (description, body) = parse_rules(&text);
    let description = description
        .map(|d| sanitized_description(&d))
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| default_rules().description);
    Ok(Rules {
        description,
        body,
        is_custom: true,
    })
}

/// Splits an optional `---` front matter holding `description:` from the body.
pub fn parse_rules(text: &str) -> (Option<String>, String) {
    let normalized = text.replace("\r\n", "\n");
    let lines: Vec<&str> = normalized.split('\n').collect();
    let end = (lines.first().map(|l| l.trim()) == Some("---"))
        .then(|| {
            lines
                .iter()
                .skip(1)
                .position(|l| l.trim() == "---")
                .map(|i| i + 1)
        })
        .flatten();
    let Some(end) = end else {
        return (None, normalized.trim().to_string());
    };
    let description = lines[1..end]
        .iter()
        .filter_map(|l| l.trim().strip_prefix("description:"))
        .next_back()
        .map(unquoted);
    (description, lines[end + 1..].join("\n").trim().to_string())
}

/// One line, bounded, so it cannot break the stub's front matter.
pub fn sanitized_description(description: &str) -> String {
    description
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MAX_DESCRIPTION_CHARS)
        .collect()
}

fn unquoted(raw: &str) -> String {
    let value = raw.trim();
    if value.starts_with('"')
        && let Ok(decoded) = serde_json::from_str::<String>(value)
    {
        return decoded;
    }
    if value.len() >= 2 && value.starts_with('\'') && value.ends_with('\'') {
        return value[1..value.len() - 1].replace("''", "'");
    }
    value.to_string()
}

/// Writes the default rules unless a rules file exists. Returns whether it wrote.
pub fn create_rules_file(environment: &Environment) -> io::Result<bool> {
    let path = environment.rules_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(mut file) => file.write_all(DEFAULT_RULES.as_bytes()).map(|_| true),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(false),
        Err(error) => Err(error),
    }
}

/// What `snippets-cli skill` prints: the guide, the user's rules, and where they live.
pub fn guide(environment: &Environment) -> io::Result<String> {
    let rules = current_rules(environment)?;
    let path = environment.rules_path();
    let source = if rules.is_custom {
        format!(
            "Rules file: {}\nEdit it when the user asks to change these rules.",
            path.display()
        )
    } else {
        format!(
            "These are the defaults. To change them, `snippets-cli skill edit` creates {}; edit that file when the user asks.",
            path.display()
        )
    };
    Ok(format!("{GUIDE}\n{}\n\n{source}\n", rules.body))
}

// MARK: Stubs

pub fn stub(description: &str) -> String {
    let quoted = serde_json::to_string(&sanitized_description(description))
        .unwrap_or_else(|_| "\"\"".to_string());
    STUB_TEMPLATE.replace("{{description}}", &quoted)
}

/// Whether a `SKILL.md` is one `install` wrote.
pub fn is_stub(text: &str) -> bool {
    let Some(rest) = text.strip_prefix("---\n") else {
        return false;
    };
    rest.split("\n---")
        .next()
        .unwrap_or("")
        .contains(STUB_MARKER)
}

fn write_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let folder = path.parent().expect("a file path has a folder");
    fs::create_dir_all(folder)?;
    let mut file = tempfile::NamedTempFile::new_in(folder)?;
    file.write_all(bytes)?;
    file.as_file()
        .set_permissions(fs::Permissions::from_mode(0o644))?;
    file.persist(path).map_err(|e| e.error)?;
    Ok(())
}

/// Writes the current stub to each place. A custom folder is remembered once it holds
/// the stub; one that has disappeared is reported and never recreated.
pub fn install(environment: &Environment, places: &[Place]) -> io::Result<Vec<Change>> {
    let text = stub(&current_rules(environment)?.description);
    places
        .iter()
        .map(|place| {
            let path = environment.stub_path(place);
            let folder = environment.skills_folder(place);
            let change = |outcome| Change {
                place: place.clone(),
                path: path.clone(),
                outcome,
            };
            if matches!(place, Place::Folder(_)) && !can_hold(&folder) {
                return Ok(change(Outcome::Missing));
            }
            match fs::read_to_string(&path) {
                Ok(existing) if !is_stub(&existing) => return Ok(change(Outcome::Skipped)),
                Ok(existing) if existing == text => {
                    if let Place::Folder(folder) = place {
                        remember(environment, folder)?;
                    }
                    return Ok(change(Outcome::Unchanged));
                }
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                // Present but unreadable as text: not ours to replace.
                Err(_) => return Ok(change(Outcome::Skipped)),
            }
            if let Place::Folder(folder) = place
                && !folder.is_dir()
            {
                // Only the final `skills` folder may be created, never its parents.
                fs::create_dir(folder)?;
            }
            write_atomically(&path, text.as_bytes())?;
            if let Place::Folder(folder) = place {
                remember(environment, folder)?;
            }
            Ok(change(Outcome::Wrote))
        })
        .collect()
}

/// Removes stubs `install` wrote, and their folder when nothing else is in it. A custom
/// folder is forgotten whatever was there. Never touches the rules file.
pub fn uninstall(environment: &Environment, places: &[Place]) -> io::Result<Vec<Change>> {
    places
        .iter()
        .map(|place| {
            let path = environment.stub_path(place);
            let outcome = match fs::read_to_string(&path) {
                Ok(existing) if is_stub(&existing) => {
                    fs::remove_file(&path)?;
                    if let Some(folder) = path.parent() {
                        // Fails, harmlessly, when the folder holds anything else.
                        let _ = fs::remove_dir(folder);
                    }
                    Outcome::Removed
                }
                Ok(_) => Outcome::Skipped,
                Err(error) if error.kind() == io::ErrorKind::NotFound => Outcome::Absent,
                Err(_) => Outcome::Skipped,
            };
            if let Place::Folder(folder) = place {
                forget(environment, folder)?;
            }
            Ok(Change {
                place: place.clone(),
                path,
                outcome,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_home(variables: &[(&str, &str)]) -> (tempfile::TempDir, Environment) {
        let directory = tempfile::tempdir().unwrap();
        let environment = Environment {
            home: fs::canonicalize(directory.path()).unwrap(),
            variables: variables
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        };
        (directory, environment)
    }

    fn write(environment: &Environment, relative: &str, text: &str) {
        let path = environment.home.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn read(environment: &Environment, relative: &str) -> String {
        fs::read_to_string(environment.home.join(relative)).unwrap()
    }

    fn make_folder(environment: &Environment, relative: &str) {
        fs::create_dir_all(environment.home.join(relative)).unwrap();
    }

    fn resolve(environment: &Environment, input: &str) -> Result<Place, FolderError> {
        resolve_folder(input, &environment.home, environment, true)
    }

    fn outcomes(changes: &[Change]) -> Vec<Outcome> {
        changes.iter().map(|c| c.outcome).collect()
    }

    const AGENTS: Place = Place::Target(Target::Agents);

    #[test]
    fn default_targets_include_claude_only_when_it_is_set_up() {
        let (_dir, environment) = temporary_home(&[]);
        assert_eq!(environment.default_targets(), vec![Target::Agents]);
        make_folder(&environment, ".claude");
        assert_eq!(
            environment.default_targets(),
            vec![Target::Claude, Target::Agents]
        );
    }

    #[test]
    fn locations_follow_their_environment_variables() {
        let (_dir, environment) = temporary_home(&[
            ("CLAUDE_CONFIG_DIR", "/tmp/claude-config"),
            ("CODEX_HOME", "/tmp/codex-home"),
            ("XDG_CONFIG_HOME", "/tmp/xdg"),
        ]);
        assert_eq!(
            environment.stub_path(&Place::Target(Target::Claude)),
            PathBuf::from("/tmp/claude-config/skills/snippets-cli/SKILL.md")
        );
        assert_eq!(
            environment.stub_path(&Place::Target(Target::Codex)),
            PathBuf::from("/tmp/codex-home/skills/snippets-cli/SKILL.md")
        );
        assert_eq!(
            environment.rules_path(),
            PathBuf::from("/tmp/xdg/snippets/agent-rules.md")
        );
    }

    #[test]
    fn install_writes_then_reports_unchanged() {
        let (_dir, environment) = temporary_home(&[]);
        let first = install(&environment, &[AGENTS]).unwrap();
        assert_eq!(outcomes(&first), vec![Outcome::Wrote]);
        let text = read(&environment, ".agents/skills/snippets-cli/SKILL.md");
        assert!(is_stub(&text));
        assert!(text.contains("description: \"Look up, save and update"));
        assert!(!text.contains("{{description}}"));
        let second = install(&environment, &[AGENTS]).unwrap();
        assert_eq!(outcomes(&second), vec![Outcome::Unchanged]);
        assert_eq!(installed_places(&environment).unwrap(), vec![AGENTS]);
    }

    #[test]
    fn install_and_uninstall_never_touch_a_foreign_skill() {
        let (_dir, environment) = temporary_home(&[]);
        let foreign = "---\nname: snippets-cli\ndescription: mine\n---\nHand-written.\n";
        write(
            &environment,
            ".agents/skills/snippets-cli/SKILL.md",
            foreign,
        );
        let changes = install(&environment, &[AGENTS]).unwrap();
        assert_eq!(outcomes(&changes), vec![Outcome::Skipped]);
        let removal = uninstall(&environment, &[AGENTS]).unwrap();
        assert_eq!(outcomes(&removal), vec![Outcome::Skipped]);
        assert_eq!(
            read(&environment, ".agents/skills/snippets-cli/SKILL.md"),
            foreign
        );
        assert_eq!(
            place_status(&environment, AGENTS).state,
            PlaceState::Foreign
        );
    }

    #[test]
    fn uninstall_removes_only_our_stub_and_leaves_the_rules() {
        let (_dir, environment) = temporary_home(&[]);
        install(&environment, &[AGENTS]).unwrap();
        create_rules_file(&environment).unwrap();
        let changes = uninstall(&environment, &[Place::Target(Target::Claude), AGENTS]).unwrap();
        assert_eq!(outcomes(&changes), vec![Outcome::Absent, Outcome::Removed]);
        assert!(
            !environment
                .home
                .join(".agents/skills/snippets-cli")
                .exists()
        );
        assert!(environment.rules_path().exists());
    }

    #[test]
    fn folder_inputs_resolve_to_the_skills_folder() {
        let (_dir, environment) = temporary_home(&[]);
        make_folder(&environment, "app/.claude");
        make_folder(&environment, "tool/skills/snippets-cli");
        make_folder(&environment, "plain");
        let skills = Place::Folder(environment.home.join("app/.claude/skills"));
        assert_eq!(resolve(&environment, "app/.claude"), Ok(skills.clone()));
        assert_eq!(
            resolve(&environment, "app/.claude/skills"),
            Ok(skills.clone())
        );
        assert_eq!(
            resolve(&environment, "./app/../app/.claude"),
            Ok(skills.clone())
        );
        assert_eq!(resolve(&environment, "~/app/.claude"), Ok(skills));
        assert_eq!(
            resolve(&environment, "tool/skills/snippets-cli"),
            Ok(Place::Folder(environment.home.join("tool/skills")))
        );
        assert_eq!(
            resolve(&environment, "plain"),
            Ok(Place::Folder(environment.home.join("plain")))
        );
    }

    #[test]
    fn a_project_root_or_a_missing_folder_is_refused() {
        let (_dir, environment) = temporary_home(&[]);
        make_folder(&environment, "app/.claude");
        assert_eq!(
            resolve(&environment, "app"),
            Err(FolderError::LooksLikeProject(environment.home.join("app")))
        );
        assert_eq!(
            resolve(&environment, "nowhere/skills"),
            Err(FolderError::NotFound(
                environment.home.join("nowhere/skills")
            ))
        );
    }

    #[test]
    fn a_built_in_folder_resolves_to_its_target() {
        let (_dir, environment) = temporary_home(&[]);
        make_folder(&environment, ".claude");
        assert_eq!(
            resolve(&environment, "~/.claude"),
            Ok(Place::Target(Target::Claude))
        );
        assert_eq!(resolve(&environment, ".agents"), Ok(AGENTS));
    }

    #[test]
    fn a_custom_folder_is_remembered_shown_and_forgotten() {
        let (_dir, environment) = temporary_home(&[]);
        make_folder(&environment, "app/.claude");
        let place = resolve(&environment, "app/.claude").unwrap();
        let changes = install(&environment, std::slice::from_ref(&place)).unwrap();
        assert_eq!(outcomes(&changes), vec![Outcome::Wrote]);
        assert_eq!(
            remembered_folders(&environment),
            vec![environment.home.join("app/.claude/skills")]
        );
        let status = status(&environment).unwrap();
        assert_eq!(status.places.len(), 4);
        assert_eq!(status.places[3].state, PlaceState::Installed);
        assert_eq!(refresh_places(&environment).unwrap(), vec![place.clone()]);
        let removal = uninstall(&environment, &[place]).unwrap();
        assert_eq!(outcomes(&removal), vec![Outcome::Removed]);
        assert!(remembered_folders(&environment).is_empty());
        assert!(
            !environment
                .home
                .join(".config/snippets/agent-skill.json")
                .exists()
        );
    }

    #[test]
    fn a_vanished_folder_is_missing_and_never_recreated() {
        let (_dir, environment) = temporary_home(&[]);
        make_folder(&environment, "app/.claude");
        let place = resolve(&environment, "app/.claude").unwrap();
        install(&environment, std::slice::from_ref(&place)).unwrap();
        fs::remove_dir_all(environment.home.join("app")).unwrap();
        assert_eq!(
            place_status(&environment, place.clone()).state,
            PlaceState::Missing
        );
        let changes = install(&environment, std::slice::from_ref(&place)).unwrap();
        assert_eq!(outcomes(&changes), vec![Outcome::Missing]);
        assert!(!environment.home.join("app").exists());
        // A plain install reports it rather than picking new places.
        assert_eq!(refresh_places(&environment).unwrap(), vec![place.clone()]);
        let typed = resolve_folder("app/.claude", &environment.home, &environment, false).unwrap();
        assert_eq!(typed, place);
        // Typed through a symlinked path, as `/tmp` is for `/private/tmp` on a Mac.
        let link = environment.home.join("link");
        std::os::unix::fs::symlink(&environment.home, &link).unwrap();
        let via_link = resolve_folder("app/.claude", &link, &environment, false).unwrap();
        assert_ne!(via_link, place);
        let removal = uninstall(&environment, &[via_link]).unwrap();
        assert_eq!(outcomes(&removal), vec![Outcome::Absent]);
        assert!(remembered_folders(&environment).is_empty());
    }

    #[test]
    fn custom_folders_are_named_after_their_project() {
        assert_eq!(folder_title(Path::new("/src/app/.claude/skills")), "app");
        assert_eq!(folder_title(Path::new("/opt/tool/prompts")), "prompts");
    }

    #[test]
    fn refresh_falls_back_to_the_defaults_only_when_nothing_is_installed() {
        let (_dir, environment) = temporary_home(&[]);
        make_folder(&environment, ".claude");
        assert_eq!(
            refresh_places(&environment).unwrap(),
            vec![Place::Target(Target::Claude), AGENTS]
        );
        install(&environment, &[Place::Target(Target::Codex)]).unwrap();
        assert_eq!(
            refresh_places(&environment).unwrap(),
            vec![Place::Target(Target::Codex)]
        );
    }

    #[test]
    fn the_rules_file_description_reaches_the_stub() {
        let (_dir, environment) = temporary_home(&[]);
        write(
            &environment,
            ".config/snippets/agent-rules.md",
            "---\ndescription: My \"saved\" stuff:\n---\n- Be brief.\n",
        );
        let rules = current_rules(&environment).unwrap();
        assert!(rules.is_custom);
        assert_eq!(rules.description, "My \"saved\" stuff:");
        assert_eq!(rules.body, "- Be brief.");
        install(&environment, &[AGENTS]).unwrap();
        let text = read(&environment, ".agents/skills/snippets-cli/SKILL.md");
        assert!(text.contains(r#"description: "My \"saved\" stuff:""#));
    }

    #[test]
    fn descriptions_are_one_bounded_line() {
        let sanitized = sanitized_description(&"word\n".repeat(400));
        assert!(!sanitized.contains('\n'));
        assert_eq!(sanitized.chars().count(), MAX_DESCRIPTION_CHARS);
        let text = stub("line one\n---\nname: evil");
        assert!(text.contains(r#"description: "line one --- name: evil""#));
        assert_eq!(text.matches("\nname: ").count(), 1);
    }

    #[test]
    fn create_rules_file_never_overwrites() {
        let (_dir, environment) = temporary_home(&[]);
        assert!(create_rules_file(&environment).unwrap());
        assert_eq!(
            read(&environment, ".config/snippets/agent-rules.md"),
            DEFAULT_RULES
        );
        write(&environment, ".config/snippets/agent-rules.md", "- mine\n");
        assert!(!create_rules_file(&environment).unwrap());
        assert_eq!(
            read(&environment, ".config/snippets/agent-rules.md"),
            "- mine\n"
        );
    }

    #[test]
    fn the_guide_ends_with_the_rules_and_where_they_live() {
        let (_dir, environment) = temporary_home(&[]);
        let defaults = guide(&environment).unwrap();
        assert!(defaults.starts_with(GUIDE));
        assert!(defaults.contains("Search the library before asking"));
        assert!(defaults.contains("These are the defaults"));
        assert!(!defaults.contains("description:"));
        write(
            &environment,
            ".config/snippets/agent-rules.md",
            "- Custom rule.\n",
        );
        let custom = guide(&environment).unwrap();
        assert!(custom.contains("- Custom rule."));
        assert!(custom.contains("Rules file: "));
    }

    #[test]
    fn the_linux_guide_has_no_mac_only_text() {
        assert!(GUIDE.contains("Linux only"));
        assert!(!GUIDE.contains("Touch ID"));
        assert!(!GUIDE.contains("<!--"));
    }
}
