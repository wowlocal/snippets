# Command-line interface

The requested target is complete terminal control of Snippets. A running native
background process may own Wayland, clipboard and keyring services; configuration
commands must not open windows or require pointer interaction. Sensitive commands
must retain their authentication requirements and accept credentials through a
hidden terminal prompt or bounded stdin/file descriptors, never command arguments.

## Inline expansion and suggestions

```sh
snippets --background
snippets-cli expansion status
snippets-cli expansion enable
snippets-cli suggestions disable
snippets-cli suggestions enable
snippets-cli expansion retry
snippets-cli expansion disable
```

`expansion enable` is explicit opt-in to ordinary expansion and its suggestions
panel, matching the GUI's initial enable action. Repeating it while enabled
preserves an independently disabled suggestions preference. It processes only
the query following `\` through Fcitx; password/sensitive fields and secure
snippet bodies are excluded. A `{clipboard}` placeholder reads clipboard text
only when that selected snippet requests it. These commands do not enable
Clipboard History or synchronization.

The CLI sends a closed command to the verified primary process. The primary
saves the setting, starts/stops the existing worker and refreshes any already-open
settings window without presenting it. Both sides verify their installed sibling
executables. Update GUI and CLI together; older apps report an unsupported command.

Replies contain `appAvailable`, `enabled`, `suggestions` and `state`. `enabled`
is the configured state; `waitingForField` means the handler is ready, while
`waitingForFcitx`, `unavailable` and `waitingForUnlock` identify an unmet runtime
condition. On GNOME, `waitingForIBus` means the Snippets IBus engine has not connected
yet: it connects at the first `\` typed with the Snippets input source selected, and the
state is `waitingForField` from then on. `ibusNotRunning` means no IBus daemon is running
in the session, so no field can reach the engine. `starting` is transient. A stopped app can
still report stored settings with `appAvailable: false` and `state: null`; that read
creates no library files.
Mutations require the background app. Exit code 3 means it is not running.

## Git sync

`snippets-cli git status|inspect|create|join|sync|deletion-review|snapshot-review|replace-recovery-code|automatic|disconnect`
connects and syncs a library through your own git repository, over HTTPS (token) or SSH
(your ssh-agent, `~/.ssh/config` and `known_hosts`). Tokens and recovery codes are
read only from stdin; a new recovery code is printed once on stdout. `git create
--plain-text` creates a plain-text library (ordinary snippets as readable Markdown); it
is refused for a public repository, and where Snippets cannot check the repository it
needs `--confirm-private`. Joining one needs `git join --accept-plain-text`. These commands work headless, with
no window. See [GIT_SYNC.md](GIT_SYNC.md).

## Agent skill

`snippets-cli skill` prints the guide for AI agents with the user's rules.
`skill status` (JSON), `skill install [--for claude|agents|codex]... [--dir PATH]...`,
`skill uninstall [--for …] [--dir …]`, `skill edit [rules|guide]` and `skill reset`
manage the installed `SKILL.md` stubs and the user's editable `guide.md` and `rules.md`
in `$XDG_CONFIG_HOME/snippets/agent-skill/` (remembered custom folders and the defaults
each copy came from are in its hidden `.state.json`; read-only originals are in
`~/.local/share/snippets/agent-skill/`). **Settings → General** shows the same places and
files, with Open Folder and Reset (`src/agent_skill_ui.rs`); the logic is
`src/agent_skill.rs`, shared by the CLI and the app. Both platforms share the text in
`agent-skill/`; regenerate the copies with `scripts/agent-skill.py`. `update` also accepts
the Mac spellings `--unpinned` and `--disabled`.

## Coverage and remaining work

This table keeps the full CLI request visible. Launching a GUI window from a
command is not counted as terminal completion of its workflow.

| Function | Current command-line coverage |
| --- | --- |
| Ordinary snippets | List, search, get, add, update, delete, tags and import; tags/pinned/enabled fields are editable |
| Inline expansion | Status, enable, disable, retry through the primary process |
| Suggestions | Status, enable and disable through the primary process |
| Global shortcuts and desktop settings | CLI configuration, saved bindings and login registration remain to expose |
| Clipboard History | Collection settings, list/search, literal copy, delete and clear remain to expose |
| Suggestion learning | Preferences, summary and separate count/choice resets remain to expose |
| Secure snippets | Existing `add --secure`, `reveal` and `secure-status` still require GUI approval/authentication; terminal authentication and secure editing remain |
| Vault and encrypted backups | Setup, authentication, key/recovery operations, backup export/import and reviewed recovery remain to expose |
| Diagnostics | Status, validated export and deletion remain to expose |
| Cloud account and synchronization | Existing backend actions still need terminal commands; this does not authorize a new protocol or interruption-test campaign |
| Recovery/history review | Existing selection/review/restore operations still need terminal workflows |
| App lifecycle | Existing `snippets --background` and `--quit`; a unified CLI lifecycle interface remains |

The current expansion change does not claim full CLI parity. Later commands must
reuse the owning backend and its state checks, preserve destructive-action review
and secret zeroization, and provide exact output/exit-code contracts.
