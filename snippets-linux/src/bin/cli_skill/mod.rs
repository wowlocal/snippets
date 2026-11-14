//! `snippets-cli skill`: the command-line face of `snippets_linux::agent_skill`, which the
//! Settings window shares. Mirrors the Mac CLI's `skill` commands and output.

use clap::{Args, Subcommand};
use serde_json::json;
use snippets_linux::agent_skill::{self, Change, Environment, Outcome, Place, SkillFile, Target};
use std::{
    io::{self, IsTerminal},
    process::Command,
};

#[derive(Subcommand)]
pub enum SkillOperation {
    /// Where the skill is installed, and the state of your guide and rules, as JSON.
    Status,
    /// Install the skill. With no options: update where it is installed, else Claude Code
    /// (if set up) and ~/.agents/skills.
    Install(Places),
    /// Remove the skill (everywhere by default). --dir also forgets that folder.
    Uninstall(Places),
    /// Edit your copy of the rules (with the skill's description) or of the guide, made
    /// from the defaults in ~/.config/snippets/agent-skill.
    Edit {
        #[arg(value_enum, default_value = "rules")]
        file: EditFile,
    },
    /// Put the default guide and rules back; your versions are kept as .bak.
    Reset,
}

#[derive(Clone, Copy, clap::ValueEnum)]
pub enum EditFile {
    Rules,
    Guide,
}

#[derive(Args)]
pub struct Places {
    /// A built-in agent folder: claude, agents (Codex and others) or codex. Repeatable.
    #[arg(long = "for", value_enum)]
    targets: Vec<Target>,
    /// Your own skills folder, such as a project's .claude/skills. Repeatable; remembered.
    #[arg(long = "dir")]
    folders: Vec<String>,
}

impl Places {
    /// Nil when neither option was given.
    fn resolve(
        self,
        environment: &Environment,
        must_exist: bool,
    ) -> Result<Option<Vec<Place>>, String> {
        let current = std::env::current_dir().map_err(|e| e.to_string())?;
        let mut places: Vec<Place> = self.targets.into_iter().map(Place::Target).collect();
        for folder in &self.folders {
            places.push(
                agent_skill::resolve_folder(folder, &current, environment, must_exist)
                    .map_err(|e| e.to_string())?,
            );
        }
        let mut unique = Vec::new();
        for place in places {
            if !unique.contains(&place) {
                unique.push(place);
            }
        }
        Ok((!unique.is_empty()).then_some(unique))
    }
}

fn print_changes(environment: &Environment, changes: &[Change]) {
    let paths: Vec<String> = changes
        .iter()
        .map(|c| environment.display(&c.path))
        .collect();
    let width = paths.iter().map(|p| p.chars().count()).max().unwrap_or(0);
    for (change, path) in changes.iter().zip(paths) {
        let note = match change.outcome {
            Outcome::Skipped => "another skill named snippets-cli is already here; left alone",
            Outcome::Missing => "folder not found; `skill uninstall --dir` forgets it",
            _ => change.place.display_name(),
        };
        // Uninstalling a custom folder also forgets it, even when nothing was there.
        let label = match (&change.place, change.outcome) {
            (Place::Folder(_), Outcome::Absent) => "forgot",
            (_, outcome) => outcome.as_str(),
        };
        println!("  {label:<9} {path:<width$}  ({note})");
    }
}

/// Runs `snippets-cli skill …` and returns the exit code.
pub fn run(command: Option<SkillOperation>) -> u8 {
    let Some(environment) = Environment::current() else {
        eprintln!("HOME is not set.");
        return 1;
    };
    match execute(&environment, command) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}

fn execute(environment: &Environment, command: Option<SkillOperation>) -> Result<u8, String> {
    let io = |e: io::Error| e.to_string();
    let folder_path = environment.display(&environment.files_folder());
    match command {
        None => print!("{}", agent_skill::guide(environment).map_err(io)?),
        Some(SkillOperation::Status) => {
            let status = agent_skill::status(environment).map_err(io)?;
            let places: Vec<_> = status
                .places
                .iter()
                .map(|p| {
                    json!({
                        "target": match p.place {
                            Place::Target(target) => target.name(),
                            Place::Folder(_) => "folder",
                        },
                        "folder": p.skills_folder,
                        "path": p.stub_path,
                        "detected": p.detected,
                        "state": p.state.as_str(),
                    })
                })
                .collect();
            let output = json!({
                "files": {
                    "folder": status.files.folder,
                    "originals": status.files.originals_folder,
                    "guide": status.files.guide.as_str(),
                    "rules": status.files.rules.as_str(),
                },
                "places": places,
            });
            println!(
                "{}",
                serde_json::to_string_pretty(&output).map_err(|e| e.to_string())?
            );
        }
        Some(SkillOperation::Install(places)) => {
            let places = match places.resolve(environment, true)? {
                Some(places) => places,
                None => agent_skill::refresh_places(environment).map_err(io)?,
            };
            let changes = agent_skill::install(environment, &places).map_err(io)?;
            let installed: Vec<_> = changes
                .iter()
                .filter(|c| matches!(c.outcome, Outcome::Wrote | Outcome::Unchanged))
                .collect();
            println!(
                "{}",
                if installed.is_empty() {
                    "Did not install the snippets-cli skill:"
                } else {
                    "Installed the snippets-cli skill:"
                }
            );
            print_changes(environment, &changes);
            if installed
                .iter()
                .any(|c| c.place == Place::Target(Target::Claude))
            {
                println!(
                    "Pre-approved in Claude Code: skill, search, get, list, tags and secure-status (read-only)."
                );
            }
            if agent_skill::sync_files(environment)
                .map_err(io)?
                .are_defaults()
            {
                println!(
                    "Guide and rules: the defaults. `snippets-cli skill edit` puts copies to edit in {folder_path}."
                );
            } else {
                println!("Your guide and rules: {folder_path}");
            }
            println!(
                "Rules guide agents; Snippets still asks you before revealing a secure snippet."
            );
            if installed.is_empty() {
                return Ok(1);
            }
            println!("Restart running agent sessions to pick up the skill.");
        }
        Some(SkillOperation::Uninstall(places)) => {
            let places = match places.resolve(environment, false)? {
                Some(places) => places,
                None => agent_skill::status(environment)
                    .map_err(io)?
                    .places
                    .into_iter()
                    .map(|p| p.place)
                    .collect(),
            };
            let changes: Vec<_> = agent_skill::uninstall(environment, &places)
                .map_err(io)?
                .into_iter()
                .filter(|c| matches!(c.place, Place::Folder(_)) || c.outcome != Outcome::Absent)
                .collect();
            if changes.is_empty() {
                println!("The snippets-cli skill is not installed there.");
            } else {
                println!("Uninstalled the snippets-cli skill:");
                print_changes(environment, &changes);
            }
            if !agent_skill::sync_files(environment)
                .map_err(io)?
                .are_defaults()
            {
                println!("Your guide and rules stay in {folder_path}.");
            }
        }
        Some(SkillOperation::Edit { file }) => {
            let file = match file {
                EditFile::Rules => SkillFile::Rules,
                EditFile::Guide => SkillFile::Guide,
            };
            return edit(environment, file).map_err(io);
        }
        Some(SkillOperation::Reset) => {
            let backups = agent_skill::reset_files(environment).map_err(io)?;
            if backups.is_empty() {
                println!("The guide and rules are already the defaults.");
            } else {
                println!("Put the default guide and rules back. Your versions are kept as:");
                for backup in &backups {
                    println!("  {}", environment.display(backup));
                }
            }
            refresh_descriptions(environment).map_err(io)?;
        }
    }
    Ok(0)
}

/// Rewrites installed stubs whose description no longer matches the rules.
fn refresh_descriptions(environment: &Environment) -> io::Result<()> {
    let places = agent_skill::installed_places(environment)?;
    let updated: Vec<_> = agent_skill::install(environment, &places)?
        .into_iter()
        .filter(|c| c.outcome == Outcome::Wrote)
        .collect();
    if !updated.is_empty() {
        println!("Updated the skill description:");
        print_changes(environment, &updated);
    }
    Ok(())
}

/// Opens one of the editable files in the user's editor, creating the copies from the
/// defaults first, or prints their paths for an agent.
fn edit(environment: &Environment, file: SkillFile) -> io::Result<u8> {
    let created = agent_skill::create_editable_files(environment)?;
    let path = environment.file_path(file);
    if !(io::stdin().is_terminal() && io::stdout().is_terminal()) {
        // No terminal: an agent or a script. Hand it the files instead of an editor.
        for each in SkillFile::ALL {
            println!("{}", environment.file_path(each).display());
        }
        if !created.is_empty() {
            eprintln!("Created from the defaults.");
        }
        eprintln!("After changing the description in rules.md, run `snippets-cli skill install`.");
        return Ok(0);
    }
    let editor = ["VISUAL", "EDITOR"]
        .iter()
        .filter_map(|v| environment.variables.get(*v))
        .find(|v| !v.is_empty())
        .map(String::as_str)
        .unwrap_or("vi");
    // The editor setting may carry its own arguments (`code -w`); the path stays one word.
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("{editor} \"$1\""))
        .arg("sh")
        .arg(&path)
        .status()?;
    if !status.success() {
        eprintln!("The editor exited with {status}.");
        return Ok(1);
    }
    // The description lives in the installed stubs too; bring them up to date.
    refresh_descriptions(environment)?;
    Ok(0)
}
