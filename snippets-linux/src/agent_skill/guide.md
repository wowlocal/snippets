# snippets-cli

`snippets-cli` reads and edits the user's personal Snippets library: saved text,
links, addresses, commands, templates and secure entries such as tokens. It is
their text-expansion library, not a store of code snippets for the project you
are working in. Every command prints JSON; errors go to stderr with a non-zero
exit code.

## When to use it

- The user mentions something they saved: a link, dashboard, address, template,
  account name or token.
- Before asking the user for a value they may already have saved.
- The user asks you to save, tag, change or remove a snippet.

## Commands

```sh
snippets-cli search grafana               # name, keyword, content and tags
snippets-cli get gh-dash                  # one snippet by exact keyword
snippets-cli list --tag work              # also --enabled, --pinned; --tag repeats (AND)
snippets-cli tags                         # every tag with its count
snippets-cli add --keyword addr --name "Home address" --content "1 Main St" --tags personal
snippets-cli update addr --tags personal,travel
snippets-cli delete addr                  # removes exactly one snippet
snippets-cli secure-status                # secure entry count, vault locked or not
```

`update` and `delete` take a keyword or a UUID. When two snippets share a
keyword, use the `id` from `search`. `--content -` reads the text from stdin.
`update` also takes `--enabled`/`--disabled` and `--pinned`/`--unpinned`.

## Secure entries

Secure snippets are encrypted. `search`, `list` and `get` never print their
content. To use one, put `reveal` inside the command that needs the value:

```sh
curl -H "Authorization: Bearer $(snippets-cli reveal api-token)" https://example.com/api
```

`reveal` asks the running Snippets app. The user approves the request in the
app's native prompt and authenticates. The bare value goes to stdout.
Exit codes: 3 the app is not running, 4 denied or cancelled, 5 the vault is
locked or not set up, 6 no such secure entry.

To create one without the value ever appearing in a command line:

```sh
snippets-cli add --secure --keyword api-token --name "API token" --content-file token.txt
snippets-cli add --secure --keyword api-token --name "API token" --prompt
```

`--content -` reads it from stdin instead. The user approves creation in the
app as well. If `reveal` or `add --secure` cannot reach the app from a sandbox,
ask the user to let you run it outside the sandbox.

## Linux only

```sh
snippets-cli expansion status             # also enable, disable, retry
snippets-cli suggestions status           # also enable, disable
snippets-cli import backup.json
snippets-cli git status                   # sync through a git repository
```

Run `git create`, `git join`, `git disconnect` and the other `git` commands
that change sync only when the user asks for them.

Full flags: `snippets-cli help`.

## The user's rules

The user's own rules follow. Where they differ from the guide above, follow
them. They are guidance: Snippets' own approval is what protects secure entries.
