---
description: Look up, save and update the user's personal Snippets library (saved links, reference text, addresses, secure tokens) with snippets-cli. Not for code snippets in the current project.
---
<!-- Your rules for agents that use snippets-cli. Updates never overwrite your
     changes; Reset to Defaults (Settings or `snippets-cli skill reset`) puts the
     defaults back and keeps your version as rules.md.bak. The description above
     is what agents see before they load the skill; Settings and `skill install`
     copy it into the installed skills. -->

- Search the library before asking the user for a link, address or value they
  may have saved.
- Pass a revealed value straight into the command that needs it, as
  `$(snippets-cli reveal KEYWORD)`. Never print, log, save to a file or repeat
  a revealed value in a reply.
- Reveal only what the current task needs, one keyword at a time, and tell the
  user which keyword you are about to request.
- If `reveal` exits 4 (denied), don't retry; ask the user. If it exits 3, ask
  the user to open Snippets.
- Never store a secret in an ordinary snippet. Create secure entries with
  `--secure` and `--content-file`, `--prompt` or stdin, never as an argument.
- Add snippets only when the user asks.
- Before `delete`, make sure exactly one snippet matches; confirm which one
  unless the user named it. Confirm before `update --content` replaces
  existing text.
