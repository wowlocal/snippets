use clap::{Args, Parser, Subcommand};
use serde_json::{Value, json};
use snippets_linux::model::{self, Error, Library, Result, Snippet};
use std::{collections::BTreeMap, io::Read, path::PathBuf};

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
    }
}
fn main() -> std::process::ExitCode {
    let options = Options::parse();
    match model::default_root()
        .and_then(Library::open)
        .and_then(|mut library| execute(options.command, &mut library))
    {
        Ok(value) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&value).expect("JSON value")
            );
            std::process::ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::ExitCode::FAILURE
        }
    }
}
