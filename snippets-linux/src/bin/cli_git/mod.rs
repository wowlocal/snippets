//! `snippets-cli git …`: headless Git sync setup and cycles. Tokens and
//! recovery codes are read only from stdin (never argv or the environment),
//! and a new recovery code is printed exactly once, on stdout.
use clap::{Args, Subcommand};
use serde_json::{Value, json};
use snippets_linux::{
    deletion_review::{Choice, Kind},
    git_layout::Mode,
    git_setup::{self, Environment, Failure, Form, Settings, State, SyncState},
};
use std::{io::Read, path::PathBuf};
use zeroize::Zeroizing;

#[derive(Subcommand)]
pub enum GitOperation {
    /// Show whether Git sync is connected, and to which repository.
    Status,
    /// Check a repository: empty, an existing library, or someone else's data.
    Inspect(Target),
    /// Create a new library on an empty branch and print its recovery code once.
    Create(Create),
    /// Join the library on this branch; a recovery code is read from stdin
    /// unless this device already holds the key.
    Join(Join),
    /// Run bounded sync cycles until the library settles or needs a decision.
    Sync {
        #[arg(long, default_value_t = 8)]
        max_cycles: usize,
    },
    /// Show, or decide, the pending deletion review.
    DeletionReview {
        #[arg(long, conflicts_with = "keep")]
        delete: bool,
        #[arg(long)]
        keep: bool,
    },
    /// Show, or confirm, the missing-records review after a full snapshot.
    SnapshotReview {
        #[arg(long)]
        confirm: bool,
    },
    /// New recovery code: seal the library key under a new code and print it
    /// once. Your old code stops working in Snippets. Someone who already has
    /// it and can read the repository's history could still decrypt the
    /// library. To fully revoke a code, create a new library.
    ReplaceRecoveryCode,
    /// Turn automatic background sync in the desktop app on or off.
    Automatic {
        #[arg(value_parser = ["on", "off"])]
        state: String,
    },
    /// Remove from this computer: forget the repository and its token here.
    /// Snippets and the library key are kept, so reconnecting needs no code.
    Disconnect,
}
#[derive(Args)]
pub struct Target {
    /// https://host/owner/repo, git@host:owner/repo.git or ssh://host/path.
    #[arg(long)]
    repository: String,
    #[arg(long, default_value = "main")]
    branch: String,
    /// HTTPS only: the user name for the access token. Optional for
    /// github.com and gitlab.com.
    #[arg(long, default_value = "")]
    username: String,
    /// HTTPS only: read the access token from the first stdin line.
    #[arg(long)]
    token_stdin: bool,
}
#[derive(Args)]
pub struct Connect {
    #[command(flatten)]
    target: Target,
    /// Read the recovery code from stdin (after the token line, if any).
    #[arg(long)]
    recovery_code_stdin: bool,
    /// Consent to replacing this device's sync state for another library.
    /// Local snippets are kept and merged into the Git library.
    #[arg(long)]
    confirm_switch: bool,
}

#[derive(Args)]
pub struct Create {
    #[command(flatten)]
    connect: Connect,
    /// Plain text: ordinary snippets become Markdown files that the host and
    /// anyone with access can read, and they stay in the repository's history
    /// even after you delete them. Secure snippets are always encrypted. Without
    /// it (recommended), the host sees only unreadable files. You can't change
    /// this later; a repository anyone can read is refused.
    #[arg(long)]
    plain_text: bool,
    /// With --plain-text: the repository is private, when Snippets could not
    /// check it. Anyone who can read the repository can read your ordinary
    /// snippets.
    #[arg(long, requires = "plain_text")]
    confirm_private: bool,
}
#[derive(Args)]
pub struct Join {
    #[command(flatten)]
    connect: Connect,
    /// Consent to joining a plain-text library: this device's ordinary
    /// snippets become readable in the repository and its history.
    #[arg(long)]
    accept_plain_text: bool,
}

fn mode_name(mode: Mode) -> &'static str {
    match mode {
        Mode::Encrypted => "encrypted",
        Mode::PlainText => "plain_text",
    }
}

struct Input {
    token: Zeroizing<String>,
    code: Option<Zeroizing<String>>,
}
fn read_input(token: bool, code: bool) -> Result<Input, Failure> {
    if !token && !code {
        return Ok(Input {
            token: Zeroizing::new(String::new()),
            code: None,
        });
    }
    let mut bytes = Zeroizing::new(Vec::new());
    std::io::stdin()
        .take(16 * 1024)
        .read_to_end(&mut bytes)
        .map_err(|_| Failure::MissingToken)?;
    let text = std::str::from_utf8(&bytes).map_err(|_| Failure::MissingToken)?;
    let mut lines = text.lines();
    let token = if token {
        Zeroizing::new(lines.next().unwrap_or_default().trim().to_owned())
    } else {
        Zeroizing::new(String::new())
    };
    let code = code.then(|| Zeroizing::new(lines.next().unwrap_or_default().trim().to_owned()));
    Ok(Input { token, code })
}
fn form(target: &Target, token: Zeroizing<String>) -> Form {
    Form {
        repository: target.repository.clone(),
        branch: target.branch.clone(),
        username: target.username.clone(),
        token,
    }
}
fn state_name(state: SyncState) -> &'static str {
    match state {
        SyncState::Current => "current",
        SyncState::MoreWork => "more_work",
        SyncState::DeletionReview => "deletion_review",
        SyncState::SnapshotReview => "snapshot_review",
        SyncState::ConflictReview => "conflict_review",
        SyncState::VaultLocked => "vault_locked",
        SyncState::IncompatibleVault => "incompatible_vault",
        SyncState::PrimaryChanged => "primary_changed",
        SyncState::PreservationRequired => "preservation_required",
        SyncState::Deferred { .. } => "deferred",
        SyncState::ReadOnly => "read_only",
    }
}
fn kind_name(kind: Kind) -> &'static str {
    match kind {
        Kind::LocalAbsence => "local_absence",
        Kind::CloudDeletion => "remote_deletion",
        Kind::PendingDeletion => "pending_deletion",
    }
}

#[cfg(feature = "secret-service")]
fn store(
    root: &std::path::Path,
) -> Result<snippets_linux::secret_store::Store<snippets_linux::secret_store::Native>, Failure> {
    use snippets_linux::secret_store::{Native, Store};
    Ok(Store::initialize(root, Native::new()?)?)
}

/// A hint printed after a failure, as the window shows it: a branch of its own
/// for a branch that already has files, and how to make a token.
pub fn hint(failure: Failure, repository: Option<&str>) -> Option<String> {
    use snippets_linux::{git_repo::Failure as G, git_transport::Failure as T};
    match failure {
        Failure::ForeignBranch | Failure::Transport(T::NotALibrary) => {
            Some("Try again with --branch snippets.".into())
        }
        Failure::VisibilityUnknown => {
            Some("Only if the repository is private, try again with --confirm-private.".into())
        }
        Failure::MissingToken
        | Failure::InvalidUsername
        | Failure::Transport(T::Git(G::Authentication | G::RepositoryNotFound)) => {
            let repository = repository?;
            let (text, link) = git_setup::token_help(repository);
            Some(match link {
                Some(link) => format!("{text} {link}"),
                None => text,
            })
        }
        _ => None,
    }
}
pub enum Outcome {
    Value(Value),
    /// A failure that still carries a recovery code the user must keep.
    FailureWithCode(Failure, Zeroizing<String>),
    /// A failure with what to try next (never a secret).
    FailureWithHint(Failure, String),
    Failure(Failure),
}
impl From<Failure> for Outcome {
    fn from(value: Failure) -> Self {
        Self::Failure(value)
    }
}

pub fn run(root: PathBuf, operation: GitOperation) -> Outcome {
    let repository = match &operation {
        GitOperation::Inspect(target) => Some(target.repository.clone()),
        GitOperation::Create(create) => Some(create.connect.target.repository.clone()),
        GitOperation::Join(join) => Some(join.connect.target.repository.clone()),
        _ => None,
    };
    match run_inner(root, operation) {
        Ok(value) => Outcome::Value(value),
        Err(Outcome::Failure(failure)) => match hint(failure, repository.as_deref()) {
            Some(hint) => Outcome::FailureWithHint(failure, hint),
            None => Outcome::Failure(failure),
        },
        Err(outcome) => outcome,
    }
}
#[cfg(not(feature = "secret-service"))]
fn run_inner(_: PathBuf, _: GitOperation) -> Result<Value, Outcome> {
    Err(Failure::Secret(snippets_linux::secret_store::Failure::Unavailable).into())
}
#[cfg(feature = "secret-service")]
fn run_inner(root: PathBuf, operation: GitOperation) -> Result<Value, Outcome> {
    let environment = Environment::new(root.clone());
    match operation {
        GitOperation::Status => {
            let settings = Settings::read(&root)?;
            Ok(match settings {
                None => json!({"connected": false}),
                Some(settings) => {
                    let remote = settings.remote(&environment)?;
                    json!({
                        "connected": true,
                        "repository": remote.canonical_location(),
                        "branch": settings.branch,
                        "transport": if remote.location.is_ssh() { "ssh" } else { "https" },
                        "automatic": settings.automatic,
                        "mode": mode_name(settings.mode),
                        "modeDescription": (settings.mode == Mode::PlainText)
                            .then_some(git_setup::PLAIN_TEXT_STATUS),
                    })
                }
            })
        }
        GitOperation::Inspect(target) => {
            let input = read_input(target.token_stdin, false)?;
            let mut store = store(&root)?;
            let inspection =
                git_setup::inspect(&environment, &mut store, &form(&target, input.token))?;
            Ok(inspection_value(inspection))
        }
        GitOperation::Create(Create {
            connect,
            plain_text,
            confirm_private,
        }) => {
            let input = read_input(connect.target.token_stdin, false)?;
            let form = form(&connect.target, input.token);
            let mut store = store(&root)?;
            let inspection = git_setup::inspect(&environment, &mut store, &form)?;
            if inspection.state != State::Empty {
                return Err(match inspection.state {
                    State::Library { .. } => Failure::LibraryExists.into(),
                    _ => Failure::ForeignBranch.into(),
                });
            }
            if inspection.replaces_sync_state && !connect.confirm_switch {
                return Err(Failure::ScopeReview.into());
            }
            let mode = if plain_text {
                Mode::PlainText
            } else {
                Mode::Encrypted
            };
            match git_setup::create(&environment, &mut store, &form, mode, confirm_private) {
                Ok(code) => Ok(json!({"recoveryCode": code.as_str(), "mode": mode_name(mode)})),
                Err((failure, Some(code))) => Err(Outcome::FailureWithCode(failure, code)),
                Err((failure, None)) => Err(failure.into()),
            }
        }
        GitOperation::Join(Join {
            connect,
            accept_plain_text,
        }) => {
            let input = read_input(connect.target.token_stdin, connect.recovery_code_stdin)?;
            let form = form(&connect.target, input.token);
            let mut store = store(&root)?;
            let inspection = git_setup::inspect(&environment, &mut store, &form)?;
            let State::Library { dataset, mode, .. } = inspection.state else {
                return Err(match inspection.state {
                    State::Empty => Failure::NotALibrary.into(),
                    _ => Failure::ForeignBranch.into(),
                });
            };
            if inspection.replaces_sync_state && !connect.confirm_switch {
                return Err(Failure::ScopeReview.into());
            }
            git_setup::join(
                &environment,
                &mut store,
                &form,
                dataset,
                mode,
                input.code.as_deref().map(|c| c.as_str()),
                accept_plain_text,
            )?;
            Ok(json!({"connected": true, "mode": mode_name(mode)}))
        }
        GitOperation::Sync { max_cycles } => {
            let mut store = store(&root)?;
            let mut totals = [0usize; 5];
            let mut state = SyncState::MoreWork;
            let mut last = None;
            let mut cycles = 0;
            while cycles < max_cycles.clamp(1, 64)
                && matches!(state, SyncState::MoreWork | SyncState::PrimaryChanged)
            {
                let report = git_setup::synchronize(&environment, &mut store)?;
                for (total, value) in totals.iter_mut().zip([
                    report.received,
                    report.applied,
                    report.accepted,
                    report.conflicts,
                    report.rejected,
                ]) {
                    *total += value;
                }
                state = report.state;
                last = Some(report);
                cycles += 1;
            }
            let warning = last.and_then(|r| r.warning());
            let (unreadable, refused) =
                last.map_or((0, 0), |r| (r.unreadable_files, r.refused_unreadable));
            Ok(json!({
                "unreadableFiles": unreadable,
                "refusedEdits": refused,
                "warning": warning,
                "state": state_name(state),
                "message": state.message(),
                "cycles": cycles,
                "received": totals[0],
                "applied": totals[1],
                "accepted": totals[2],
                "conflicts": totals[3],
                "rejected": totals[4],
            }))
        }
        GitOperation::DeletionReview { delete, keep } => {
            let mut store = store(&root)?;
            let choice = if delete {
                Some(Choice::Delete)
            } else if keep {
                Some(Choice::Keep)
            } else {
                None
            };
            let summary = git_setup::deletion_review(&environment, &mut store, choice)?;
            Ok(json!({
                "kind": kind_name(summary.kind),
                "name": summary.name,
                "keyword": summary.keyword,
                "secure": summary.secure,
                "canKeep": summary.can_keep,
                "decided": choice.map(|c| if c == Choice::Delete { "delete" } else { "keep" }),
            }))
        }
        GitOperation::SnapshotReview { confirm } => {
            let mut store = store(&root)?;
            let summary = git_setup::resolve_snapshot_review(&environment, &mut store, confirm)?;
            Ok(json!({
                "localRecords": summary.local_records,
                "missingRecords": summary.missing_records,
                "preservationCopies": summary.preservation_copies,
                "confirmed": confirm,
            }))
        }
        GitOperation::ReplaceRecoveryCode => {
            let mut store = store(&root)?;
            let code = git_setup::replace_recovery_code(&environment, &mut store)?;
            Ok(json!({
                "recoveryCode": code.as_str(),
                "note": "Your old code stops working in Snippets. Someone who already has it and can read the repository’s history could still decrypt the library. To fully revoke a code, create a new library.",
            }))
        }
        GitOperation::Automatic { state } => {
            git_setup::set_automatic(&environment, state == "on")?;
            Ok(json!({"automatic": state == "on"}))
        }
        GitOperation::Disconnect => {
            let mut store = store(&root)?;
            git_setup::disconnect(&environment, &mut store)?;
            Ok(json!({"connected": false}))
        }
    }
}
fn inspection_value(inspection: git_setup::Inspection) -> Value {
    let mut value = match inspection.state {
        State::Empty => json!({"state": "empty"}),
        State::Foreign => json!({
            "state": "foreign",
            "hint": "This branch already has files, such as a README. Snippets can use its own branch in this repository instead: try --branch snippets.",
        }),
        State::Library {
            mode,
            key_available,
            recovery_available,
            ..
        } => json!({
            "state": "library",
            "mode": mode_name(mode),
            "keyAvailable": key_available,
            "recoveryAvailable": recovery_available,
        }),
    };
    value["replacesSyncState"] = inspection.replaces_sync_state.into();
    value
}
