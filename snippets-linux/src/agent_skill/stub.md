---
name: snippets-cli
description: {{description}}
allowed-tools: Bash(snippets-cli skill), Bash(snippets-cli search:*), Bash(snippets-cli get:*), Bash(snippets-cli list:*), Bash(snippets-cli tags), Bash(snippets-cli secure-status)
metadata:
  snippets-cli-stub: "1"
---
<!-- Installed by "snippets-cli skill install". Remove it with "snippets-cli skill uninstall".
     Change the rules and description with "snippets-cli skill edit", not here:
     install rewrites this file. -->

Run `snippets-cli skill` and follow the guide it prints. It comes from the
installed snippets-cli, so it matches the commands this version has, and it
ends with the user's own rules.

Always, even before reading the guide: never print, log or repeat a value from
`snippets-cli reveal`. Use `$(snippets-cli reveal KEYWORD)` inside the command
that needs it.

If `snippets-cli skill` fails, this snippets-cli predates the guide: use
`snippets-cli help`.
