use clap::{Args, Parser, Subcommand};
use serde_json::{Value, json};
use snippets_linux::{
    control::{self, Addition, Client, Outcome, Status},
    model::{self, Error, Library, Result, Snippet},
    secure_input::Source,
};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    path::PathBuf,
};

#[derive(Parser)]
#[command(
    name = "snippets-cli",
    version,
    about = "Manage the native Linux Snippets library"
)]
struct Options {
    #[command(subcommand)]
    command: Operation,
}
#[derive(Subcommand)]
enum Operation {
    List(Filter),
    Search {
        query: String,
        #[command(flatten)]
        filter: Filter,
    },
    Get {
        identifier: String,
    },
    /// Reveal secure UTF-8 bytes after native approval and fresh vault authentication.
    Reveal {
        identifier: String,
    },
    /// Inspect secure metadata and the running app's session state.
    SecureStatus,
    Delete {
        identifier: String,
    },
    Tags,
    Add(Edit),
    Update {
        identifier: String,
        #[command(flatten)]
        edit: Edit,
    },
    Import {
        file: PathBuf,
    },
}
#[derive(Args, Default)]
struct Filter {
    #[arg(long)]
    tag: Vec<String>,
    #[arg(long)]
    pinned: bool,
    #[arg(long)]
    enabled: bool,
}
#[derive(Args)]
struct Edit {
    #[arg(long)]
    name: Option<String>,
    #[arg(long)]
    keyword: Option<String>,
    #[arg(long, help = "Ordinary text, or - to read bounded UTF-8 stdin")]
    content: Option<String>,
    #[arg(
        long,
        help = "Create encrypted text through approval in the running desktop app"
    )]
    secure: bool,
    #[arg(long, requires = "secure", conflicts_with_all = ["content", "content_fd", "prompt"])]
    content_file: Option<PathBuf>,
    #[arg(long, requires = "secure", conflicts_with_all = ["content", "content_file", "prompt"])]
    content_fd: Option<i32>,
    #[arg(long, requires = "secure", conflicts_with_all = ["content", "content_file", "content_fd"], help = "Read one hidden line from the controlling terminal")]
    prompt: bool,
    #[arg(long)]
    tags: Option<String>,
    #[arg(long, conflicts_with = "no_pinned")]
    pinned: bool,
    #[arg(long)]
    no_pinned: bool,
    #[arg(long, conflicts_with = "no_enabled")]
    enabled: bool,
    #[arg(long)]
    no_enabled: bool,
}
fn find(library: &Library, identifier: &str) -> Result<Snippet> {
    let (ordinary, secure) = library.catalogue()?;
    if secure.iter().any(|m| {
        m.id.to_string().eq_ignore_ascii_case(identifier)
            || !m.keyword.is_empty()
                && model::folded(&m.keyword) == model::folded(&model::keyword(identifier))
    }) {
        return Err(Error(
            "This is a secure snippet. Use the desktop app to authenticate; the CLI cannot read or change its body.",
        ));
    }
    let matches: Vec<_> = ordinary
        .iter()
        .filter(|s| {
            s.id.to_string().eq_ignore_ascii_case(identifier)
                || !s.keyword.is_empty()
                    && model::folded(&s.keyword) == model::folded(&model::keyword(identifier))
        })
        .collect();
    if matches.len() != 1 {
        return Err(Error(
            "No unique ordinary snippet matches that keyword or identifier.",
        ));
    }
    Ok(matches[0].clone())
}
fn edit(
    library: &mut Library,
    mut snippet: Snippet,
    expected: Option<&Snippet>,
    values: Edit,
) -> Result<Value> {
    if let Some(name) = values.name {
        snippet.name = name;
    }
    if let Some(keyword) = values.keyword {
        snippet.keyword = keyword;
    }
    if let Some(content) = values.content {
        snippet.content = if content == "-" {
            let mut data = Vec::new();
            std::io::stdin()
                .take(model::MAX_BODY_BYTES as u64 + 1)
                .read_to_end(&mut data)
                .map_err(|_| Error("The input could not be read."))?;
            if data.len() > model::MAX_BODY_BYTES {
                return Err(Error("Snippet content exceeds the 256 KiB limit."));
            }
            String::from_utf8(data).map_err(|_| Error("Snippet content must be UTF-8 text."))?
        } else {
            content
        };
    }
    if let Some(tags) = values.tags {
        snippet.tags = tags.split(',').map(String::from).collect();
    }
    if values.pinned || values.no_pinned {
        snippet.is_pinned = values.pinned;
    }
    if values.enabled || values.no_enabled {
        snippet.is_enabled = values.enabled;
    }
    let id = snippet.id;
    library.save(snippet, expected)?;
    Ok(json!(library.get(id)))
}
fn execute(command: Operation, library: &mut Library) -> Result<Value> {
    let (ordinary, secure) = library.catalogue()?;
    let secure_ids: std::collections::HashSet<_> = secure.iter().map(|m| m.id).collect();
    let catalogue: Vec<_> = ordinary
        .into_iter()
        .chain(secure.iter().map(|m| m.shell()))
        .collect();
    match command {
        Operation::List(filter) => Ok(json!(model::search(
            &catalogue,
            "",
            &filter.tag,
            filter.pinned,
            filter.enabled
        ))),
        Operation::Search { query, filter } => Ok(json!(
            model::search(
                &catalogue,
                &query,
                &filter.tag,
                filter.pinned,
                filter.enabled
            )
            .into_iter()
            .map(|snippet| json!({"secure":secure_ids.contains(&snippet.id),"snippet":snippet}))
            .collect::<Vec<_>>()
        )),
        Operation::Get { identifier } => Ok(json!(find(library, &identifier)?)),
        Operation::Delete { identifier } => {
            let snippet = find(library, &identifier)?;
            library.delete(&snippet)?;
            Ok(json!({"deleted": true, "id": snippet.id.to_string().to_uppercase()}))
        }
        Operation::Tags => {
            let mut counts: BTreeMap<String, (String, usize)> = BTreeMap::new();
            for snippet in &catalogue {
                for tag in &snippet.tags {
                    counts
                        .entry(model::folded(tag))
                        .or_insert((tag.clone(), 0))
                        .1 += 1;
                }
            }
            Ok(json!(
                counts
                    .values()
                    .map(|(tag, count)| json!({"tag": tag, "count": count}))
                    .collect::<Vec<_>>()
            ))
        }
        Operation::Add(values) => edit(library, Snippet::new("", ""), None, values),
        Operation::Update {
            identifier,
            edit: values,
        } => {
            let expected = find(library, &identifier)?;
            edit(library, expected.clone(), Some(&expected), values)
        }
        Operation::Import { file } => {
            let data =
                model::read_regular(&file)?.ok_or(Error("The input file is unavailable."))?;
            let (added, skipped) = library.import(&data)?;
            Ok(json!({"imported": added, "skipped": skipped}))
        }
        Operation::Reveal { .. } | Operation::SecureStatus => {
            Err(Error("Secure commands require the running desktop app."))
        }
    }
}
fn private_add(values: &Edit) -> Result<(Addition, Source)> {
    if !values.secure {
        return Err(Error("Private input flags require add --secure."));
    }
    let source = match (
        &values.content,
        &values.content_file,
        values.content_fd,
        values.prompt,
    ) {
        (Some(content), None, None, false) if content == "-" => Source::Stdin,
        (None, Some(path), None, false) => Source::File(path.clone()),
        (None, None, Some(fd), false) if fd >= 0 => Source::Descriptor(fd),
        (None, None, None, true) => Source::Prompt,
        _ => {
            return Err(Error(
                "Use exactly one private source: --content -, --content-file, --content-fd or --prompt. Secure body text must not be an argument.",
            ));
        }
    };
    let addition = Addition {
        name: values.name.clone().unwrap_or_default(),
        keyword: values.keyword.clone().unwrap_or_default(),
        tags: values
            .tags
            .as_deref()
            .map(|s| s.split(',').map(String::from).collect())
            .unwrap_or_default(),
        is_enabled: !values.no_enabled,
        is_pinned: values.pinned,
    };
    addition.validate()?;
    Ok((addition, source))
}
fn print_json(value: &Value) -> Result<()> {
    let data = serde_json::to_vec_pretty(value)
        .map_err(|_| Error("The response could not be encoded."))?;
    let mut stdout = std::io::stdout().lock();
    stdout
        .write_all(&data)
        .and_then(|_| stdout.write_all(b"\n"))
        .map_err(|_| Error("The response could not be written."))
}
fn offline_secure_count(root: &std::path::Path) -> Result<usize> {
    match std::fs::symlink_metadata(root) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Ok(metadata) if metadata.is_dir() => snippets_linux::vault::read_document(root)
            .map(|document| document.map_or(0, |d| d.records.len())),
        _ => Err(Error("The local library metadata could not be verified.")),
    }
}
fn secure_command(root: PathBuf, command: Operation) -> u8 {
    let addition = if let Operation::Add(ref values) = command {
        match private_add(values) {
            Ok(value) => Some(value),
            Err(error) => {
                eprintln!("{error}");
                return 2;
            }
        }
    } else {
        None
    };
    if let Operation::Reveal { ref identifier } = command
        && (identifier.is_empty() || identifier.len() > 256 || identifier.contains('\0'))
    {
        eprintln!("Supply a secure keyword or UUID within the 256-byte limit.");
        return 2;
    }
    let client = match Client::connect(&root) {
        Ok(client) => client,
        Err(error) => {
            if matches!(command, Operation::SecureStatus) && control::unavailable(&error) {
                let count = offline_secure_count(&root);
                return match count.and_then(|count| {
                    print_json(&json!({"secureCount":count,"appAvailable":false,"unlocked":null}))
                }) {
                    Ok(()) => 0,
                    Err(error) => {
                        eprintln!("{error}");
                        1
                    }
                };
            }
            eprintln!("{error}");
            return if control::unavailable(&error) { 3 } else { 1 };
        }
    };
    let receipt_keyword = addition
        .as_ref()
        .map(|(metadata, _)| model::keyword(&metadata.keyword));
    let outcome = match command {
        Operation::Reveal { identifier } => client.reveal(identifier),
        Operation::SecureStatus => client.status(),
        Operation::Add(_) => {
            let (addition, source) = addition.expect("validated secure source");
            // Verify the app before opening a file, consuming stdin or disabling terminal echo.
            match source.read(&|| client.check()) {
                Ok(body) => client.add(addition, body),
                Err(error) => {
                    eprintln!("{error}");
                    return 1;
                }
            }
        }
        _ => unreachable!("secure command routing"),
    };
    let result = match outcome {
        Ok(Outcome::Revealed(body)) => std::io::stdout()
            .lock()
            .write_all(&body)
            .map_err(|_| Error("The plaintext response could not be written.")),
        Ok(Outcome::Created(id)) => print_json(
            &json!({"id":id.to_string().to_uppercase(),"secure":true,"keyword":receipt_keyword}),
        ),
        Ok(Outcome::State { count, unlocked }) => {
            print_json(&json!({"secureCount":count,"appAvailable":true,"unlocked":unlocked}))
        }
        Ok(Outcome::Rejected(status)) => {
            eprintln!("{}", status.message());
            return status.exit_code();
        }
        Err(_) => {
            eprintln!("{}", Status::Error.message());
            return 1;
        }
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("{error}");
            1
        }
    }
}
fn main() -> std::process::ExitCode {
    let options = Options::parse();
    if matches!(&options.command, Operation::Update { edit, .. } if edit.secure) {
        eprintln!(
            "Secure updates require the desktop editor; add --secure only creates new entries."
        );
        return std::process::ExitCode::from(2);
    }
    let root = match model::default_root() {
        Ok(root) => root,
        Err(error) => {
            eprintln!("{error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    if matches!(
        &options.command,
        Operation::Reveal { .. } | Operation::SecureStatus
    ) || matches!(&options.command, Operation::Add(edit) if edit.secure)
    {
        return std::process::ExitCode::from(secure_command(root, options.command));
    }
    match Library::open(root).and_then(|mut library| execute(options.command, &mut library)) {
        Ok(value) => match print_json(&value) {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("{error}");
                std::process::ExitCode::FAILURE
            }
        },
        Err(error) => {
            eprintln!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}
