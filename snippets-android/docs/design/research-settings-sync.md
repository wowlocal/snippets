# Design research: settings, sync, onboarding, data transfer, adaptive layout

Research for the Snippets Android rebuild (Kotlin, Compose, Material 3). Date: 2026-11-25.
Scope: settings, sync setup and status, first run, import/export/backup, diagnostics, tablets.
The library, editor and secure-snippet screens are covered by the sibling research documents.

## 1. Method

All references come from Mobbin's MCP search (`search_screens`, `search_flows`). Mobbin offers only
`ios` and `web`, so every Android statement below is a translation, not an observed Android screen.
Tablet behaviour is inferred from `web` captures; Mobbin returned no iPad screens. I ran 40 searches
(37 screen searches, 3 flow searches) and read every returned image.

| # | Query (platform) | What came back |
|---|---|---|
| 1 | password manager settings with grouped rows (ios) | Dead end: bank and social "Security" pages, no password manager. |
| 2 | notes app settings with sync status row (ios) | Good: MD Vinyl, Crouton, timespent, ABY Journal status rows; Evernote flat list. |
| 3 | 1Password settings screen (ios) | Settings home, Security page with unlock tiles and footers. |
| 4 | Obsidian settings screen (ios) | Settings home, General (account optional), explanation-per-setting pages. |
| 5 | Proton Pass settings screen (ios) | Dead end: app not in Mobbin; unrelated settings lists. |
| 6 | settings screen with search bar (ios) | Google, bunq, Coinbase Wallet, WhatsApp: search field above grouped rows. |
| 7 | self-hosted server URL entry on login (ios) | Bluesky hosting-provider sheet, Brave inline URL error, Discord link formats, Slack. |
| 8 | developer tool clone git repository (ios) | Thin: v0 "Create Repository" sheet, Cursor "Connect Source Control". No clone form. |
| 9 | enter API key or token with paste button (ios) | Phantom and Glow paste fields, Obsidian "Add secret", Todoist and Wise copy-code steps. |
| 10 | save your recovery key, shown once (ios) | Finch, Fuse, Family, Wealthsimple, Uniswap, Brave key reveal screens. |
| 11 | SSH key screen with public key and copy (ios) | Dead end for SSH: same wallet key screens again. |
| 12 | sync failed error banner with retry (ios) | Mostly weak full-screen "something went wrong" pages; Crouton inline retry card. |
| 13 | offline mode indicator banner (ios) | AllTrails strip, Alta inline banner, Qantas and Sesame as counter-examples. |
| 14 | sync conflict resolution, which version to keep (ios) | Dead end for two-version pickers (code diffs). Found Google Photos review and Zocdoc. |
| 15 | link a device by scanning a QR code (ios) | Brave Sync Chain, Comet, X, WhatsApp, Alexa, TikTok. |
| 16 | VPN account number without email (ios) | Dead end: phone-number sign-ups. No Mullvad or IVPN style screens. |
| 17 | approve sign-in by comparing a number (ios) | Dead end: only SMS and email code entry (Netflix error banner was useful). |
| 18 | flow: browser sync setup with a sync code (ios) | Brave "Adding a device" (9 screens), Comet "Adding a device" and "Setting up browser sync". |
| 19 | flow: password manager importing from a file (ios) | Wallet imports instead (Phantom, Uniswap, Trust Wallet): create/import forks. |
| 20 | import data, choose source or format (ios) | Google Photos, Beli, Notion, Fabric source lists. |
| 21 | import summary with imported and skipped counts (ios) | Expensify, Phantom, CVS, Neuecast results. Nobody shows a skipped count. |
| 22 | encrypted backup, set a backup password (ios) | Binance, OKX, WhatsApp, Uniswap, World App. |
| 23 | sign out, what happens to local data (ios) | Solflare, Family, Klook, Toggl, Headspace, Scoot, SmartThings. |
| 24 | type a word to confirm deleting data (ios) | Kit, Quo and four near-identical "type DELETE" dialogs. |
| 25 | diagnostics settings, export logs (ios) | XChat, Craft, Phantom, Structured, Bluesky, Expensify, FotMob. |
| 26 | Bitwarden self-hosted server settings (ios) | Dead end: app not in Mobbin. |
| 27 | Termius add host or SSH key (ios) | Dead end: app not in Mobbin. Cursor integrations list was a useful stray. |
| 28 | first launch: start new or restore (ios) | ABY Journal, Apple Watch, WhatsApp, Coinbase Wallet, Trust Wallet, Family. |
| 29 | verify security code or fingerprint (ios) | Dead end: passcode and SMS code screens. No host-key or safety-number screen. |
| 30 | Craft sync status in settings (ios) | Craft "Diagnostics Settings" and its sync-history list. |
| 31 | GitHub mobile settings (ios) | Settings rows with trailing state, cache row, version footer. |
| 32 | settings with sidebar and detail pane (web) | X, Slite, Mercury, Google Drive, Superlist. |
| 33 | add SSH or deploy key form (web) | GitLab, Railway, Klaviyo: the form our user must fill in on the host. |
| 34 | access token created, copy it now (web) | Mailchimp, Cloudflare, Coinbase, Snowflake, AutoSend. |
| 35 | flow: notes onboarding without an account (ios) | Granola (sign-in wall, counter-example), IHG "Continue as guest". |
| 36 | connection progress with a checklist (ios) | Tempo status rows, Calm Sleep fake checklist; the rest were onboarding trackers. |
| 37 | turn off sync: keep or remove data (ios) | Dropbox, Mesh, MacroFactor, Rocket Money. |
| 38 | action-required card on a home screen (ios) | Freenow, GoHenry, Amazon. |
| 39 | export data with format options (ios) | 5 Minute Journal, Meta AI, Satispay, Notion, bunq. |
| 40 | about screen with version and licences (ios) | Docusign, Google, OKX. |

Not available or not found: Bitwarden, Proton Pass and Termius (searched by name), and anything
resembling Working Copy, Blink, Mullvad or IVPN (searched by description). No SSH host-fingerprint
prompt, no comparison-code approval, no two-version conflict picker and no import result with a
"skipped" count exist in the results. Recommendations for those are reasoned from the product's
rules and the nearest analogues, and are marked as such.

## 2. Pattern findings

### 2.1 Settings home for power-user tools

- **Few rows, grouped by intent, with state on the row.** The useful homes have five to ten rows and show a value or summary so the user rarely needs to drill in.
  - [Coinbase Wallet settings][cbw-settings]: search field, then rows with a second line listing contents ("Passcode, backup, Face ID").
  - [GitHub settings][gh-settings]: trailing values per row ("Automatic", "English", "Setup Needed" on Notifications).
  - [N26 settings][n26-settings]: "Security" with the supporting line "Authentication, PIN, and more".
  - [1Password settings][1p-home]: ten icon rows in four groups (Accounts, Collections / General … Notifications / Advanced / Help).
  - [Obsidian settings][obs-home]: "Options" group of nine rows, plugins in separate groups below.
- **Search inside settings.** A field at the top of the list: [Google][google-settings] ("Search"), [bunq][bunq-settings] ("Search for a Setting"), [WhatsApp][wa-settings], and on desktop [X][x-web] ("Search Settings" inside the list pane).
- **Explain under the control.** [1Password Security][1p-security] puts one sentence under Clear Clipboard ("…after 90 seconds") and shows unlock methods as three selectable tiles; [Obsidian Editor][obs-editor] gives every setting a one-line description.
- **Say that the account is optional.** [Obsidian General][obs-general]: "You're not logged in right now. An account is only needed for Obsidian Sync, Obsidian Publish, and early access versions."
- **What fails.** [Evernote][evernote-settings] is a flat list of twelve equal rows with Sync in eleventh place and no state. 1Password's rows carry no state at all, so every question costs a tap. Obsidian renders a full-width button under many settings, which makes pages long; "Rebuild vault cache" ([red description, red button label][obs-advanced]) sits in the same card as ordinary options.

### 2.2 Sync setup: provider, address, credentials, test

- **Provider choice is explicit and has a default.** [Bluesky's hosting-provider sheet][bsky-host] uses a two-segment control (Bluesky | Custom), reveals a "Server address" field only for Custom, and explains the choice in two sentences. [Cursor's integrations list][cursor-integrations] shows each source-control provider with its state ("Connected as …" with Manage, others with "Connect ↗"). [Slack sign-in][slack-signin] keeps alternatives as quiet links ("Continue with a QR code", "Enter a workspace URL").
- **Address fields say what they accept and why they reject.** [Brave][brave-url] shows the reason under the field ("Only secure (https) URLs are allowed…"); [Discord][discord-invite] lists three accepted forms as helper text; [v0's Create Repository sheet][v0-repo] states in one sentence that the repository is private and that changes are pushed to a branch.
- **Secret entry has an explicit Paste and a visibility toggle.** [Phantom][phantom-key] puts a "Paste" pill inside the key field; [Glow][glow-import] gives a large paste area plus a Paste chip and keeps the primary button disabled while it is empty; [Obsidian "Add secret"][obs-secret] states the allowed characters under the ID field and masks the secret with an eye toggle.
- **"Give this value to the other side" is a numbered task.** [Todoist 2FA][todoist-2fa] labels the steps "1. Copy secret code" and "2. Enter verification code"; [Wise][wise-pair] shows the code with a Copy button, a QR alternative and a "Code copied" snackbar. This is the closest analogue to showing an SSH public key.
- **Know the form on the other side.** [GitLab's "Add an SSH key"][gitlab-ssh] asks for Key, Title, usage type and expiry and lists accepted key prefixes; [Railway][railway-ssh] asks for Name and Public Key; [Klaviyo][klaviyo-ssh] opens the form in a side sheet. Our screen must hand the user a ready title as well as the key.
- **Progress shows real steps.** [Tempo][tempo-connect] lists three checks, each with its own state word (CONNECTED, SYNCED, GRANTED); [FotMob's network troubleshooting][fotmob-net] ticks through named steps with a percentage, then offers "Submit log".
- **What fails.** [Base][base-key] truncates the key to "GNEM…FBUN", so it cannot be compared by eye. [Calm Sleep][calm-progress] animates a checklist of work that is not happening. [Cursor's empty state][cursor-connect] offers "Connect" without saying what the user will need. Nothing in Mobbin shows a host-key prompt (searches 11, 27, 29).

### 2.3 One-time secrets: recovery codes and generated keys

- **State the purpose, the consequence of loss, and that it is shown once.**
  - [Bluesky app password][bsky-app-pw]: monospaced code with copy icon; "you won't be able to view this again. If you lose this app password, you'll need to generate a new one."
  - [Finch encryption key][finch-key]: what the key encrypts, "we cannot help you recover", large monospaced code.
  - [Fuse private key][fuse-key]: three icon bullets, one consequence each, then a single Done.
  - [Cloudflare (web)][cf-token]: "will not be shown again", plus a command to test the token.
  - [Coinbase (web)][coinbase-key]: the only exit is a button labelled "I've saved my key".
  - [Snowflake (web)][snowflake-token]: primary button "Copy to clipboard and close".
  - [Wealthsimple][ws-code]: says when the code will be needed, "Keep it in a safe place", code with a copy icon, Continue.
- **Reveal deliberately.** [Brave][brave-pk-gate] asks for the password before "Show Private Key", then [shows it][brave-pk] with "Tap to copy" and "Hide Private Key". (Mobbin blurs secrets in its captures, so blur in other references is not evidence of an in-app mask.)
- **What fails.** Finch colours "Copy Code" like a destructive action and lets the user continue without it. [Uber][uber-codes] tells users to "Screenshot these codes", which sends them to photo backups. [Phantom][phantom-show] asks for a checkbox and then a system "Are you sure you want to continue?" alert that adds nothing. [Family][family-backup] follows with a word-position quiz: right for money, heavy for a code that can be reissued.

### 2.4 Sync status surfaces

- **One status row: state word, one sentence, a timestamp.** [MD Vinyl][mdvinyl-sync] ("Status ● Synced", a sentence, "Last synced at …"); [timespent][timespent-sync] puts an "iCloud Sync · Last synced just now" card with a refresh icon on the settings home; [ABY Journal][aby-backup] shows "Backing up…" with a spinner and "Last successful backup: Never".
- **A health checklist shows which link is broken.** [Crouton "Sync Status"][crouton-status]: Account, iCloud Storage, Items in iCloud ("Updating…" with spinner), Items on Device, each with a tick.
- **A sync console for people who want one.** [Craft "Diagnostics Settings"][craft-diag]: "Online" with a timestamp, Sync Now, counts ("New: 0 > Uploading: 0 > Synced: 17"), history, and a separate "Danger Zone".
- **Offline is a quiet state.** [AllTrails][alltrails-offline] shows a one-line "Offline mode · Refresh" strip above normal content; [Alta][alta-offline] adds the consequence ("No messages can be received or sent for now").
- **Blocked states name the cause, what happens next, and one action.**
  - [Google Photos "Review out-of-sync changes"][gphotos-review]: "You changed these photos on another device. Google Photos needs your permission to apply these changes on this device", a "Deleted" card with thumbnails, actions "Delete all" and "Review". The best model for a mass-deletion halt.
  - [Freenow][freenow-verify]: a warning card at the top and the same problem marked on its row ("Work email · Unverified").
  - [GoHenry][gohenry-error]: what failed, "We'll try again soon", and an inline link to the fix.
  - [Amazon][amazon-clock]: cause and effect in two sentences ("The clock on your phone is out of sync. This may prevent…").
- **Conflicts.** No app showed a two-version picker. [Zocdoc][zocdoc-similar] is the nearest: it shows the existing item as a card and offers two labelled outcomes. Snippets keeps the other version as a disabled conflict copy, so it needs a label and a filter, not a picker.
- **What fails.** [Bolt Food][bolt-error] ("Sorry, something went wrong. Please try again.") and [PayPal][paypal-wait] ("Sorry About the Wait") apologise without a cause or a statement about the user's data; [Sesame][sesame-oops] heads a plain offline state with "Oops, something went wrong". [Qantas][qantas-offline] replaces the whole screen, repeats itself in a snackbar and puts "[IN01]" in the sentence. [Julienne][julienne-toast] covers the status bar with a success toast for routine sync. [Toggl][toggl-logout] shows "Synced ✓" only at the bottom of Settings and warns "All unsynced data will be lost" without a count.

### 2.5 First run without an account

- **Fork only when earlier data may exist, and label both branches equally.** [Apple Watch][watch-fork] ("Restore from Backup" / "Set Up as New Apple Watch"); [ABY Journal][aby-restore] lists detected backups with size and "Current Device" chips, offers "Start Fresh", and warns "Restoring will replace all current data"; [Coinbase Wallet][cbw-import] uses two cards with one-line descriptions; the [Uniswap import flow][uniswap-flow] confirms what it found ("One wallet found") before continuing.
- **Let people in.** The [IHG flow][ihg-flow] has "Continue as Guest" under the sign-in buttons and lands on the full home screen.
- **What fails.** The [Granola onboarding][granola-flow] puts a sign-in wall, an attribution survey and a role picker before the first note. [WhatsApp][wa-restore] makes the choice irreversible ("You will not be able to restore later if you decline") while its Restore button is disabled. [Family][family-existing] shows a dead "No Backup Found" tile.

### 2.6 Accounts without email, and joining from another device

- **Generated account numbers: no references found.** The nearest are the one-time secret screens in 2.3.
- **QR with a typed fallback, an expiry and a warning.** [Brave Sync Chain][brave-qr]: segments "QR Code | Code Words", a red line ("Treat this code like a password…"), the QR, and a validity countdown. [Comet][comet-qr] offers "View sync code"; [X][x-qr] offers "Can't scan the QR code?" and "Enter code"; [Alexa][alexa-scan] offers "Try numeric code instead?" under the viewfinder; [TikTok][tiktok-link] numbers the steps for the other device under the code.
- **Device lists mark "This device" and separate leaving from deleting.** The [Brave flow][brave-flow] lists devices on the chain with "(This Device)" and a single red "Delete Sync Account"; the [Comet flow][comet-flow] has both "Leave sync" and a red "Delete sync".
- **Comparison codes: no references found.** [Netflix][netflix-code] at least keeps the form and shows the error above it.
- **What fails.** Brave prints the countdown as "0 hour 29 min 48 seconds". Brave's per-data-type toggles carry a footnote that they "only affect this device", which most users will miss.

### 2.7 Import, export, backup

- **Choose by source name.** [Google Photos][gphotos-import] groups sources by kind; [Beli][beli-import] lists four sources including "Copy/paste a list"; [Notion][notion-source] offers "New empty data source", "Import CSV", "Link to existing".
- **Results are counted.** [Expensify][expensify-import] ("Import successful. 20 categories have been added."), [Phantom][phantom-result] ("We found 1 account with activity" with Continue and View Accounts), [CVS][cvs-added] (also says what was not found).
- **Backup passwords: two labelled fields, the rule, and who cannot help.** [Binance][binance-backup] highlights "Binance cannot access or retrieve it"; [OKX][okx-backup] labels both fields and puts the minimum in the placeholder; [WhatsApp][wa-backup] boxes the warning and offers a 64-digit key as an alternative.
- **Export states format and contents.** [5 Minute Journal][5mj-export] explains what the ZIP contains; [Satispay][satispay-export] gives each format a one-line "Best for…"; [Meta AI][meta-export] shows current values per row and warns "This file may contain private information".
- **What fails.** No app reports skipped items (search 21). [Fabric][fabric-import] ends with a toast ("Your import is processing.") and no result. [World App][world-backup] shows two unlabelled password fields. [Neuecast][neuecast-import] blocks with an alert for a success.

### 2.8 Diagnostics, help, about

- **Say what the logs contain, in the place where they are exported.** [XChat][xchat-debug]: "Message contents are not included but additional metadata about the messages is". [Phantom][phantom-logs]: what is included, and in bold what is not. [Structured][structured-diag]: "include app and device details, which may be sensitive".
- **Version details that can be copied.** [Docusign][docusign-about] lists Version, Build and Server as rows; [Bluesky][bsky-about] shows version, commit and environment and has a "System log" row; [GitHub][gh-foot] shows the cache size on the "Clear cache" row and confirms with a short toast.
- **What fails.** [Craft's sync history][craft-history] prints a long hexadecimal identifier under every event; in Snippets that would break the logging privacy contract. [Expensify][expensify-trouble] uses internal names ("Onyx state"). [Starlink][starlink-about] is a wall of identifiers.

### 2.9 Destructive actions and disconnecting

- **Say what stays and what goes.** [Dropbox][dropbox-unlink]: changes "won't be synced to unlinked devices, but your files won't be deleted". [Mesh][mesh-keep]: "Keep a Copy" / "Delete" / "Cancel", with the consequence of each. [Family][family-logout] shows the affected wallet and "It will still be backed up to your account". [MacroFactor][mf-disable] says what stops and what must be revoked elsewhere.
- **Friction in proportion to the loss.** [Solflare][solflare-logout]: red box, an "I understand" switch, button disabled until it is on. [Quo][quo-delete]: "What you should know" and "What you can do instead" before typing "Delete". [Kit][kit-delete] is the standard type-DELETE dialog.
- **What fails.** [Headspace][headspace-logout] asks "Are you sure?" with Yes/No. [Scoot][scoot-logout] opens with "Your privacy is important to us" and offers OK/Cancel. [SmartThings][st-leave] shows a wall of text and then an alert repeating it. [Klook][klook-logout] is clear but would be wrong for a local-first app: logging out there hides data.

### 2.10 Large screens (from web references)

- **List-detail with search in the list pane.** [X][x-web]: navigation column, settings list with search, detail with a back arrow that only matters when the panes collapse.
- **Sectioned sidebars for more than eight destinations.** [Slite][slite-web] and [Mercury][mercury-web] (which has "API Tokens" and "Vault" entries).
- **Secrets and short forms float; context stays visible.** [Snowflake][snowflake-token] and [Coinbase][coinbase-key] use a centred dialog roughly a third of the window wide; [Klaviyo][klaviyo-ssh] uses a right side sheet for the key form.
- **What fails.** [Superlist][superlist-web] uses chip tabs, which stop scaling after four categories. [Google Drive][gdrive-web] has four sidebar entries and one very long detail page.

## 3. Recommendations for Snippets Android

### 3.1 Principles

1. **The library never waits for sync.** No sync state replaces, blocks or dims the list.
2. **Three volumes only.** Quiet (icon), informative (status row), blocking-for-sync (one banner with one action). Routine success is never announced.
3. **State on the row.** Every top-level settings row shows its current state as supporting text.
4. **One secret screen.** Recovery code, account key and new recovery code use the same component and rules.
5. **Every stop says three things:** what happened, what happened to the data on this device, what to do next.

### 3.2 Settings information architecture

```text
Settings                         TopAppBar + search action (SearchBar; results show "Sync › Git repository")
├─ [Attention card]              only while sync needs the user: one sentence + "Review"
├─ Sync                          "Off · this device only" | "Git · me/library · synced 2 min ago" | "Stopped · review needed"
│  ├─ Status                     state, last synced, changes waiting, [Sync now]
│  ├─ Provider                   This device only / Git repository / Snippets Cloud (only in builds that enable it)
│  ├─ Git repository             connected summary, or setup
│  │  ├─ Change address or token…
│  │  ├─ SSH key for this device (public key, Copy, Share)   · Trusted hosts (fingerprints, Forget)
│  │  ├─ New recovery code…  · Replace keys…                  (device-owner authentication)
│  │  └─ Remove from this device                               (only while Git is not the active provider)
│  ├─ Snippets Cloud             account, this device, other devices, pair a device, recovery kit, sign out
│  └─ Conflict copies            count; opens the library filtered to them
├─ Secure snippets               "Locked · key on this device" | "Not set up"
│  └─ Lock now · auto-lock · recovery key (set up, restore)
├─ Library data                  "128 snippets · 14 secure"
│  ├─ Import…                    JSON, Raycast export, encrypted backup (detected from the file)
│  ├─ Export for sharing…        ordinary snippets only, readable JSON
│  └─ Encrypted backup…          everything, password-protected
├─ General                       theme, dynamic colour, copy behaviour, Insert Snippet text action
├─ Diagnostics                   "Logs kept 14 days · 1.2 MB"
│  └─ What is logged · Export logs… · Delete logs
└─ About                         version and build (long-press copies), licences, privacy policy, source
```

- Six rows. Each is a `ListItem` with leading icon, headline and supporting text; no trailing chevrons. Errors use `colorScheme.error` on the supporting text plus an icon, never colour alone.
- There is no account header. Like Obsidian, say once in Sync that no account is needed for local use.
- Search indexes titles, summaries, synonyms ("token", "PAT", "deploy key", "logs", "backup") and actions ("Sync now", "Lock now"). A result opens the screen scrolled to the row with a brief highlight.
- Destructive rows sit last in their own group with `error`-coloured text. No "Danger Zone" heading.

### 3.3 Sync status in the library and in settings

| State | Library | Settings › Sync |
|---|---|---|
| Sync off | Nothing. | "Off · this device only". |
| Synced / syncing | Top app bar icon (cloud-done; while a round runs, a 2 dp `LinearProgressIndicator` under the bar). | "Synced 2 min ago" / "Syncing…". |
| Changes waiting (Git pacing) | Icon unchanged. | "2 changes waiting · next sync in under a minute". |
| Offline or host unreachable | Icon becomes cloud-off. No banner. | "Offline · 3 changes saved on this device". |
| Needs the user (halt, token, key, host key) | Persistent card above the list: sentence + "Review". Icon gets a `Badge`. | Attention card on Settings home; error text on the Sync row. |

- Tapping the icon opens a `ModalBottomSheet`: provider, state sentence, last synced, changes waiting, `Sync now`, `Sync settings`. This is the only sync UI most users see.
- `PullToRefreshBox` on the library requests a round when sync is on. When sync is off the gesture is disabled; do not animate a refresh that does nothing.
- The review card is an `OutlinedCard` in `errorContainer` tones with one `FilledTonalButton`. It can be collapsed to a single-line `AssistChip` ("Sync stopped · Review") but not dismissed while the cause remains.
- "Last synced" means the last completed round, including background rounds. If Android restricts background work, say so in the Status section instead of showing a stale time without comment.
- A sync-activity list, if wanted, shows time, outcome and counts only (Craft's list without the identifiers).

### 3.4 Git setup, step by step

Rules for the whole flow: a full-screen destination on phones (not a bottom sheet: it has text fields and long explanations); nothing is written to the repository before the user presses a button that says so; the draft (address, branch, never the token) survives process death, because the user leaves for the browser to create a token or add a key; Back steps through the flow and never discards silently.

```text
A. Provider (Settings › Sync)              B. Repository
┌────────────────────────────────────┐     ┌────────────────────────────────────┐
│ Sync                               │     │ ←  Git repository                  │
│ (•) This device only               │     │ Repository address                 │
│     No account. Nothing is sent.   │     │ [ github.com/me/snippets-library ] │
│ ( ) Git repository                 │     │ HTTPS or SSH address. Use a new    │
│     Your own private repository on │     │ private repository without a README│
│     GitHub, GitLab, Gitea…         │     │ Branch  [ main ]                   │
│ ( ) Snippets Cloud                 │     │ ‹HTTPS · access token›  AssistChip │
│     Account key, no email.         │     │ For an SSH key, enter an address   │
│ Sync starts only after setup and   │     │ like git@github.com:me/library.git │
│ your confirmation.                 │     │                       [ Continue ] │
└────────────────────────────────────┘     └────────────────────────────────────┘
```

- **A.** `RadioButton` list items with two-line descriptions. Selecting Git or Cloud opens setup; the radio only moves when setup completes. Switching between two working providers uses the shared "Switch and sync" confirmation.
- **B.** One `OutlinedTextField` for the address (URI keyboard, no autocorrect). A missing `https://` is added on blur. The access method is derived from the address and shown as a chip; do not add a control that can disagree with the address. Errors go in `supportingText` with the reason ("Remove the user name and password from the address", "This repository uses SHA-256 objects, which Snippets cannot sync").

```text
C. Access token (HTTPS)                    D. SSH key (SSH address)
┌────────────────────────────────────┐     ┌────────────────────────────────────┐
│ ←  Access token                    │     │ ←  SSH key for this device         │
│ github.com/me/snippets-library     │     │ 1  Copy this public key            │
│ Access token                       │     │ ┌────────────────────────────────┐ │
│ [ ••••••••••••••••  ◉  Paste ]     │     │ │ ecdsa-sha2-nistp256 AAAAE2Vj…  │ │
│ Create a fine-grained token limited│     │ │ …9f3Q= snippets-android        │ │
│ to this repository, with Contents: │     │ └────────────────────────────────┘ │
│ read and write.                    │     │ [ Copy ]  [ Share ]                │
│ Create a token on GitHub ↗         │     │ 2  Add it as a deploy key with     │
│ Stored only on this device.        │     │    write access. Title: snippets-  │
│                                    │     │    android   Open deploy keys ↗    │
│                 [ Check access ]   │     │ 3  [ Check connection ]            │
└────────────────────────────────────┘     └────────────────────────────────────┘
```

- **C.** Password-type field with a visibility toggle and an explicit Paste action; never read the clipboard without that tap. Mark the field for Autofill so a password manager can fill the token. Help text and link follow the host in the address. The user-name field appears only for hosts that need one.
- **D.** Numbered like Todoist. Show the whole key, wrapped, monospaced and selectable, never truncated. `Copy` and `Share` (Sharesheet, plain text). Give the title to type on the host, because GitLab and GitHub ask for one. The key is created on first use and never leaves the device; say "This key stays on this device and is not synced."

```text
E. Host key (first SSH connection)         F. Checking
┌────────────────────────────────────┐     ┌────────────────────────────────────┐
│ ←  Confirm the host                │     │ ←  Checking repository             │
│ github.com presented this key:     │     │ ━━━━━━━━━━━━━━━━──────────────     │
│ ED25519  SHA256:                   │     │ ✓  Reached github.com              │
│   +DiY3wvv V6TuJJhb pZisF/zL       │     │ ✓  Access accepted                 │
│   DA0zPMSv HdkrA4UvC OqU           │     │ ◌  Reading branch main             │
│ ✓ Matches the fingerprint GitHub   │     │                                    │
│   publishes.                       │     │ on failure, the failed line reads: │
│ Trust it only if it matches what   │     │ ✕  Access refused                  │
│ your host shows.                   │     │    The token may have expired or   │
│ [ Cancel ]         [ Trust host ]  │     │    lacks write access. [Edit token]│
└────────────────────────────────────┘     └────────────────────────────────────┘
```

- **E.** A step in the flow, not an `AlertDialog`: it must not be dismissable by reflex. Fingerprint monospaced in groups. For the four hosts with published fingerprints show the match line; the user still confirms. A **changed** key is a different, error-styled screen with old and new fingerprints, no primary "trust" button, and "Replace trusted key…" behind a second confirmation.
- **F.** Real steps only, each ticking when it actually completes (Tempo, FotMob). A failure stays on this screen, on the line that failed, with the fix. No full-screen error page, no snackbar.

```text
G. Result: empty branch                    H. Result: library found
┌────────────────────────────────────┐     ┌────────────────────────────────────┐
│ ←  Create a library                │     │ ←  Connect to your library         │
│ Branch main is empty.              │     │ Found an encrypted Snippets library│
│ Snippets will create an encrypted  │     │ on branch main.                    │
│ library here. The host stores only │     │ Recovery code                      │
│ ciphertext.                        │     │ [ 7KQ2M-XW4ZP-…          Paste ]   │
│ You will get a recovery code to    │     │ ✕ One character looks mistyped.    │
│ connect other devices.             │     │ The code was shown when the library│
│ Expected an existing library?      │     │ was created, or under New recovery │
│ Check the address and branch.      │     │ code on a connected device.        │
│ Plain text instead…                │     │ 128 snippets on this device will be│
│               [ Create library ]   │     │ merged in.            [ Connect ]  │
└────────────────────────────────────┘     └────────────────────────────────────┘
```

- **Create versus connect is not a question we ask.** The inspection answers it (Uniswap's "One wallet found", ABY's detected backups). Each result screen names what was found and offers only the matching action. A foreign branch gets a third result: "This branch holds other data. Snippets will not write to it." with `Use branch "snippets"`.
- **G.** Encrypted is the default and the only filled button. "Plain text instead…" is a `TextButton`; people who never ask for plain text never read about it.
- **H.** Monospaced field, automatic upper case, grouping added as the user types, Paste and Autofill. The code has a check symbol, so tell typos ("One character looks mistyped") apart from a wrong code ("This code does not open this library"). A wrong code is rejected before anything is saved. State how many local snippets will be merged.

```text
I. Plain text (only after "Plain text instead…")   J. Recovery code (shown once)
┌────────────────────────────────────┐     ┌────────────────────────────────────┐
│ ←  Plain-text library              │     │ Save your recovery code            │
│ Each snippet becomes a readable    │     │   7KQ2M XW4ZP 9D3RT                │
│ Markdown file in the repository.   │     │   H6BVN 0C8YJ 5F                   │
│ • Anyone with access to the        │     │ [ Copy ]                           │
│   repository can read them.        │     │ It connects other devices and opens│
│ • They stay in its history.        │     │ secure snippets there. Snippets    │
│ • A library cannot be converted    │     │ does not store it and cannot show  │
│   back to encrypted.               │     │ it again. If you lose it, create a │
│ Repository visibility: private ✓   │     │ new one from a connected device.   │
│ [ Cancel ]                         │     │ [✓] I saved the recovery code      │
│      [ Create plain-text library ] │     │                    [ Continue ]    │
└────────────────────────────────────┘     └────────────────────────────────────┘
```

- **I.** Three consequences as bullets (Fuse). Show the visibility check result. A public repository disables the button and says why; "unknown" asks the user to confirm it is private with a `Checkbox`.
- **J.** The shared secret screen: large monospaced groups, `FLAG_SECURE` (no screenshots, blank in Recents), Back and predictive back intercepted with "Leave without saving the code?", clipboard copy marked sensitive. `Continue` is enabled by the checkbox (Coinbase's "I've saved my key"). No quiz. If the push result is uncertain the same screen carries a warning line: "The library may have been created. Keep this code."
- **K. Confirm and finish.** `AlertDialog`: "Start syncing with Git?" with one sentence on what is uploaded and "Snippets on this device are kept." Then return to Settings › Sync showing the connected summary with the first round's progress. Success is the status line; no celebration screen.

**Connected summary** (replaces the form once connected): repository and branch, one line for mode and transport ("Encrypted · HTTPS"), the status row, and at most one line for anything that needs the user. Actions below as list items; "Reconnect…" appears only when reconnecting fixes the current stop.

### 3.5 Review and halts

One screen template for every stop, opened from the card, the sheet or Settings:

```text
┌ ←  Sync stopped ───────────────────────────┐
│ What happened      42 of 128 snippets were deleted on another device.
│ What Snippets did  Stopped before applying it. Nothing was deleted here.
│ On this device     128 snippets · 3 changes waiting
│ [ Review deletions ]   primary: the safe, reversible path
│ [ Keep everything on this device ]   secondary
│ Details ▾          Code: mass_deletion_review · Copy
└────────────────────────────────────────────┘
```

- Fixed order: happened, did, on this device, actions, details. The primary action is the one that loses nothing. A destructive choice is last, `error`-coloured, behind a confirmation that repeats the count.
- The closed failure code is shown under Details and can be copied. It never appears in the sentence (Qantas).
- Stops that reconnecting fixes (`git_library_replaced`, a missing key) have "Reconnect…" as the primary action and reuse steps F to H with the saved address.
- An unsupported library version is not a review: the Sync row says "Update Snippets to sync" and the library keeps working.
- No system notification by default. A stop is visible in the app the next time it is opened.

### 3.6 Snippets Cloud account

- **Two visible stages**, because signing in does not unlock a library: "1 Sign in" and "2 Unlock your library". Show both on the first screen so stage 2 is not a surprise.
- **Sign in:** `SingleChoiceSegmentedButtonRow` "Approve from a device | Account key" (Brave's "QR Code | Code Words"). The account-key field follows the recovery-code field rules. `Create account` is a `TextButton` below.
- **Create account:** the generated key appears on the shared secret screen (3.4 J) titled "Save your account key", with "This key is your account. There is no email and no reset."
- **Approve from a device:** show the QR large on a white surface with the typed alternative under it, a validity time written as "Valid for 9 min", and "Treat this like a password". After the scan both devices show the comparison code in large type. The approving device has `Approve` and `Reject` and names the new device; the new device shows "Waiting for approval" and never a button that could approve itself.
- **Scanning:** request the camera permission only when the user taps Scan; typed entry always works without it.
- **Account screen:** account-key fingerprint (not the key), devices with "This device", `Pair a device`, `Recovery kit`, then `Sign out` with the wording in section 4.

### 3.7 Import, export, backup

- **Import:** one row. It opens the system file picker (`OpenDocument`) first; the format is detected from the file, not asked. Then a `ModalBottomSheet` preview: detected format, counts ("42 snippets: 12 new, 28 update existing, 2 cannot be read"), and only the options that apply (Raycast: a `SegmentedButton` "Keep leading ! | Remove"). An encrypted backup asks for its password here; a wrong password keeps the field and says "That password does not open this backup."
- **Result:** stays in the sheet: "Imported 40 snippets. 12 added, 28 updated, 2 skipped." with `View skipped` (reason per item, no content) and `Done`. Always add "Nothing was deleted." A snackbar is not enough for a result with skipped items.
- **Export for sharing:** state before the picker that the file is readable text and excludes secure snippets ("14 secure snippets are not included").
- **Encrypted backup:** two labelled password fields with visibility toggles, the rule in `supportingText`, and a boxed line "The password cannot be recovered. Without it this backup cannot be opened." Then `CreateDocument`. Finish with the file name, the count, and `Share`.
- Progress for anything over about a second: determinate `LinearProgressIndicator` with counts. Never ask the user to keep the app open; run the work so it completes anyway.

### 3.8 Diagnostics and About

```text
Diagnostics
  Logs on this device        Kept up to 14 days · 37 files · 1.2 MB
  What is logged             Events, counts, durations and error codes. Never snippet names, bodies, tags,
                             clipboard contents, keys or file paths. Keywords of secure snippets may appear.
  [ Export logs… ]           One plain-text file. Read it before you send it to anyone.
  [ Delete logs ]            Removes the logs kept on this device. Snippets are not affected.
About
  Version 2.0.0 (build 210) · Sync provider: Git · Android 16     long-press copies this block
```

- The privacy sentence sits on this screen, above the buttons, and again in the export confirmation (Phantom, XChat). The secure-keyword caveat is never omitted.
- `Export logs…` opens `CreateDocument`; afterwards a snackbar offers `Share`. `Delete logs` uses a plain `AlertDialog`; no typed confirmation, since nothing irreplaceable is lost.
- No toggle for logging, no "send to developer" button, no identifiers on screen.

### 3.9 First run

- Open straight into an empty library. No carousel, no account screen, no sample snippet (a fresh install must be able to fetch a remote library without looking like it authored data).
- Empty state: one sentence, `New snippet` as the filled button, and two `TextButton`s: `Import…` and `Connect an existing library…`. The second opens Settings › Sync at the provider choice.
- No sync promotion after that. Sync is reachable from the top-bar icon's sheet ("Sync is off · Set up") and Settings.
- If setup is abandoned, the app stays local and the draft is kept; the Sync row reads "Setup not finished · Continue".

### 3.10 Tablets and foldables

| Surface | Compact width | Medium and expanded |
|---|---|---|
| App navigation | No bottom bar. Library is the app; Settings is a top-bar action. | `NavigationSuiteScaffold` with a `NavigationRail`: Library, Settings, sync status at the bottom. |
| Settings | List, then pushed screens. | `ListDetailPaneScaffold`: the six rows with summaries and search in the list pane; Sync selected by default. |
| Setup forms (B, C, D, F to I) | Full-screen destinations. | In the detail pane, content capped at 600 dp. |
| Secret and trust screens (E, J, Cloud key) | Full screen. | Modal `Dialog`, about 560 dp wide, scrim, not dismissable by outside tap. |
| Sync status, import preview | `ModalBottomSheet`. | Sync status: popup anchored to the rail item. Import: dialog. |
| Review | Full screen. | Detail pane, library still visible when opened from the library card. |
| QR and comparison code | Stacked. | Two columns: code left, instructions right. |

A bottom bar needs three to five destinations; this app has one, so adding a bar to host Settings would spend permanent space on a screen opened rarely. Whether the library's own structure (tags, pins) earns rail destinations is a question for the library research.

### 3.11 iOS patterns not to copy

- Inset grouped tables with a chevron on every row, and coloured rounded-square icons. Use `ListItem` with tonal icons and no chevrons.
- "Done" at the top right of modal sheets, and stacks of page sheets. Use Back, and a close icon only on true dialogs.
- Action sheets for choices. Use `ModalBottomSheet` for short lists or a menu.
- Centred alerts with stacked full-width buttons, and red text rows acting as buttons. Use `AlertDialog` with text buttons; destructive rows remain list items.
- Search hidden until the list is pulled down. Keep it visible in the top app bar.
- Floating glass tab bars (GitHub, Crouton, timespent in the references).
- Relying on swipe-back to leave a sensitive screen. Handle Back and predictive back explicitly.
- iOS clipboard promises. Android cannot guarantee an expiring, local-only copy the same way (see section 6).

## 4. Copy guidelines for sync errors and consequences

Structure, always in this order: **what happened** (cause if known), **what happened to data on this device**, **the next action**. Two or three short sentences. The button repeats the action as a verb.

- Words: "this device", "the repository", "library", "recovery code", "access token". Not "cloud", "server" (for Git), "vault key" (outside Secure snippets), "oops", "please", "unfortunately", exclamation marks.
- Counts instead of adjectives: "3 changes waiting", "42 of 128 snippets".
- Never claim more than is known: "may have expired", "the address may be wrong".
- No host response text, URL parameters or token fragments in any message. The code goes under Details.
- Retryable problems say that nothing is needed: "Snippets will try again."

| Situation | Title | Body | Action |
|---|---|---|---|
| Offline | Offline | 3 changes are saved on this device. They sync when you are back online. | none |
| Host unreachable | Could not reach the host | Nothing was changed. Snippets will try again. | Sync now |
| `git_http_401/403` | Access token refused | The token may have expired or lost write access. Your snippets are unchanged; 3 changes are waiting. | Update token |
| `git_repository_not_found` | Repository not found | The address may be wrong, or the token cannot see this private repository. Nothing was changed. | Check address |
| `git_key_required` | Recovery code needed | This device does not have the key for this library. Your snippets stay on this device and are not uploaded until you enter the code. | Enter code |
| `git_library_replaced` | The library was replaced | The branch now holds a different library, for example because its keys were replaced. Sync is stopped and snippets on this device are kept. Reconnect with the newest recovery code to merge them. | Reconnect… |
| Remote reset | The remote library was reset | Records this device had synced are gone from the repository. Nothing was deleted on this device. | Review |
| Host key changed | The host's key changed | The host presented a different key than the one you trusted. Nothing was sent. Compare the fingerprints before you continue. | Compare |
| Mode changed | The library's mode changed | This library is now plain text; this device agreed to encrypted. Sync is stopped and nothing was uploaded. | Review |
| Newer format | Update Snippets to sync | This library was written by a newer version. Snippets on this device still work. | Update |
| Remove Git from device | Remove Git sync from this device? | Your snippets stay on this device. The repository is not changed. The address and token are forgotten; the library key is kept, so reconnecting needs no recovery code. | Remove |
| Cloud sign out | Sign out on this device? | Your snippets stay on this device and stop syncing. 2 changes have not been uploaded. | Sign out |
| Wrong recovery code | This code does not open this library | Nothing was saved. Check that it is the newest code for this repository. | none |

## 5. Anti-patterns to avoid

- **Apology without information**: [Bolt Food][bolt-error], [PayPal][paypal-wait], and the "Oops" heading in [Sesame][sesame-oops]. A sync message with no cause and no data statement is a defect.
- **Full-screen error over working local content**: [Qantas][qantas-offline]. The library is local; it is never replaced.
- **Announcing routine success**: [Julienne][julienne-toast], [Neuecast][neuecast-import]. No toast or dialog for an ordinary sync or a clean import.
- **Fake progress**: [Calm Sleep][calm-progress]. Each line corresponds to a real step or it is not shown.
- **Truncated secrets and keys**: [Base][base-key]. Public keys, fingerprints and codes are shown whole.
- **"Are you sure?"**: [Headspace][headspace-logout], [Phantom][phantom-show]. A confirmation states the consequence and names the action on its button.
- **Policy preamble and walls of text**: [Scoot][scoot-logout], [SmartThings][st-leave]. Lead with the consequence.
- **Telling users to screenshot a secret**: [Uber][uber-codes]. The secret screen blocks screenshots.
- **Onboarding walls**: [Granola][granola-flow]. No sign-in, survey or tour before the library.
- **Irreversible first-run choices**: [WhatsApp][wa-restore]. Connecting or importing later must work exactly as on first run.
- **Dead options**: [Family][family-existing]. Hide what cannot be used, or say what would enable it.
- **Identifiers in user-visible logs**: [Craft][craft-history], [Starlink][starlink-about]. Counts and outcomes only.
- **Status hidden at the bottom of Settings**: [Toggl][toggl-logout]. Sync is the first row.
- **Unlabelled or unexplained password fields**: [World App][world-backup].
- **Flat settings without state**: [Evernote][evernote-settings].
- **A setup form that stays a form**: once connected, show what is connected and fold the form away.

## 6. Open design questions

1. **Clipboard expiry.** The Apple apps clear a copied recovery code after two minutes. On Android an app in the background cannot read the clipboard and, as far as I know, cannot reliably clear it either; the system's own clearing, where it exists, is much slower. This needs checking on the minimum SDK. Do we promise nothing, clear only while in the foreground, or offer no Copy on the recovery-code screen (Autofill save and manual transcription only)?
2. **Saving the recovery code.** Checkbox only (recommended), or also require typing the last group? Should we offer "Save to a password manager" through the credential APIs?
3. **Recovery code as QR.** Do the Mac and iOS apps show the recovery code as a QR code anywhere? If so, step H should offer Scan.
4. **Cloud pairing direction.** Which device shows the QR and which scans, and where does the comparison code appear first? Section 3.6 assumes the signed-in device approves; the reference implementation decides.
5. **Halt resolutions.** The exact choices per stop (mass deletion, remote reset, account change) must come from the engine. The actions in 3.5 and section 4 are placeholders for wording, not behaviour.
6. **Explicit access-method control.** Section 3.4 derives HTTPS or SSH from the address. Is a `SegmentedButton` that rewrites the address for known hosts worth the extra rules for ports and aliases?
7. **Hosts without Ed25519 or ECDSA host keys.** If the Kotlin SSH client has the same limits as iOS, where do we say "use HTTPS for this host": at address entry or only on failure?
8. **Notifications.** Should a stop that needs review ever raise a system notification, given the app shows nothing else outside itself?
9. **Navigation rail contents.** With one main destination, does the rail on tablets carry tags and pins (library research), or only Library and Settings?
10. **Background sync truthfulness.** How do we present "Android is restricting background sync" without sending users on a battery-settings errand?
11. **Snippets Cloud visibility.** In builds without the flag, is the provider hidden (recommended) or shown as unavailable?
12. **Sync activity list.** Is an aggregate-only history worth building for v1, or is the exported log enough?

## Screen references

[1p-home]: https://mobbin.com/screens/aa249eeb-831e-44dc-a6d9-f8eff472b95e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[1p-security]: https://mobbin.com/screens/19cb9fb1-068d-442d-aaa9-0d443d3ebfde?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[obs-home]: https://mobbin.com/screens/af68c101-c480-4de2-8339-706494b4530a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[obs-general]: https://mobbin.com/screens/c03b0276-6ba0-4384-a8e9-74dcddba4528?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[obs-editor]: https://mobbin.com/screens/46a68598-bd04-4e49-b314-44dd8408f357?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[brave-pk-gate]: https://mobbin.com/screens/da1185e0-b788-4f0b-850e-0b583c3230e1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[obs-advanced]: https://mobbin.com/screens/6260ec15-913d-47a8-93f8-c4bfdffb6907?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[obs-secret]: https://mobbin.com/screens/07abea26-f358-4d6e-8d96-b3dd9ab41abd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[cbw-settings]: https://mobbin.com/screens/7b60c2bf-6b31-4d58-8711-a3483d7de071?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[bunq-settings]: https://mobbin.com/screens/b75e5826-dd63-45b3-ad6d-ee654adc4d6c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[google-settings]: https://mobbin.com/screens/57c4fabc-4942-47af-a6cf-4a835d2fdc06?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[wa-settings]: https://mobbin.com/screens/fd2ef080-a856-4e23-b194-67b162b71479?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[gh-settings]: https://mobbin.com/screens/506bcfa7-b382-4b00-bc46-fbfd22fca0fe?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[gh-foot]: https://mobbin.com/screens/f081dfde-0b25-48fb-ad9f-846670b0c5af?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[n26-settings]: https://mobbin.com/screens/a903968e-2f79-458f-ad9c-fa210690434e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[evernote-settings]: https://mobbin.com/screens/f74264ac-0593-4010-a615-a072d51d445e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[bsky-host]: https://mobbin.com/screens/62756075-d487-4274-a682-8a2ca58e838e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[cursor-integrations]: https://mobbin.com/screens/1776ef99-fa2a-45fb-b34d-62393ad3ceee?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[cursor-connect]: https://mobbin.com/screens/15cf2ccc-5802-48ae-be53-3707cecc7c1d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[slack-signin]: https://mobbin.com/screens/cf7af6c8-b450-4f66-8923-e090328cad37?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[brave-url]: https://mobbin.com/screens/93273842-f39e-4e7c-bae6-2a22191d6f81?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[discord-invite]: https://mobbin.com/screens/d8cb65c8-b4e8-4944-9281-27e41d186ad7?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[v0-repo]: https://mobbin.com/screens/f365a8c9-0f19-4b97-beb8-39fa7d065512?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[phantom-key]: https://mobbin.com/screens/b0ed65e0-8b50-446c-9f64-075636b76001?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[glow-import]: https://mobbin.com/screens/ed9f16b4-c121-44f2-a1ea-7087cbd43197?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[todoist-2fa]: https://mobbin.com/screens/c524a185-331a-4be0-a919-3c11b3095ac4?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[wise-pair]: https://mobbin.com/screens/c6fbf611-d836-49f3-96e7-9708f4f200b2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[gitlab-ssh]: https://mobbin.com/screens/64263df6-71c1-4771-94ab-367fdd747f7e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[railway-ssh]: https://mobbin.com/screens/1442266b-fb02-40ad-b031-030adcabe16e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[klaviyo-ssh]: https://mobbin.com/screens/335e5157-4e38-4897-aa24-39c814f8d8cb?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[tempo-connect]: https://mobbin.com/screens/e18d7a87-0f30-4a1f-a947-9e9e1a89cfa4?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[fotmob-net]: https://mobbin.com/screens/ea873817-50d9-4ba8-983c-0feb4f302698?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[base-key]: https://mobbin.com/screens/981324fa-205d-4081-82c2-3b29ac7b44ba?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[calm-progress]: https://mobbin.com/screens/52e0bf63-158b-49be-a8d6-fd6bab9c17af?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[bsky-app-pw]: https://mobbin.com/screens/df832a36-ac3b-4aa9-a489-708d5de55025?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[finch-key]: https://mobbin.com/screens/5323c997-b144-42ed-95aa-f23f2af0acca?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[fuse-key]: https://mobbin.com/screens/21e75dec-11b8-4296-b611-bdadc3181024?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[cf-token]: https://mobbin.com/screens/6d07bf59-cce1-4212-840f-2c208d98c41f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[coinbase-key]: https://mobbin.com/screens/73007b47-cdb2-452d-a4b4-d725d333e6c8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[snowflake-token]: https://mobbin.com/screens/83e24c5e-2b14-42d5-8d73-84922b35f722?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[ws-code]: https://mobbin.com/screens/69552a03-1d51-4cfc-9501-c10035bd1e8b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[brave-pk]: https://mobbin.com/screens/dc5ba7ff-f93d-458d-b8b7-a691b4e4ba8b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[uber-codes]: https://mobbin.com/screens/3eaf1b42-62c1-4c11-a1b7-ac954ac6f247?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[phantom-show]: https://mobbin.com/screens/972f3410-af7c-4bb4-9728-df90308a32b2?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[family-backup]: https://mobbin.com/screens/17721de6-0685-45e7-b39e-6418045ba876?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[mdvinyl-sync]: https://mobbin.com/screens/2451dc46-c58d-472e-ba63-802790b155bc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[timespent-sync]: https://mobbin.com/screens/5154780c-34a7-48f9-9c52-298bcc050c6b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[aby-backup]: https://mobbin.com/screens/64c85e8e-4bef-4aeb-b8b1-e737f6856cb3?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[crouton-status]: https://mobbin.com/screens/2ec1d29c-8a03-4e15-9022-bdbc2c9de4dd?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[craft-diag]: https://mobbin.com/screens/209d65ed-3bb0-4e91-a13a-7cae838be9a1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[craft-history]: https://mobbin.com/screens/79d9fa97-b47e-4f13-a5bf-7c8fcf27464d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[alltrails-offline]: https://mobbin.com/screens/247ad1bd-9535-4174-879f-789bd6f8863b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[alta-offline]: https://mobbin.com/screens/2b00c4b9-d2a6-4a6a-9d95-2aba49348be1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[gphotos-review]: https://mobbin.com/screens/a2d85742-27e6-48ff-838c-a017b6598bf9?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[freenow-verify]: https://mobbin.com/screens/790862ac-9958-43ad-868d-1ae91befd18f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[gohenry-error]: https://mobbin.com/screens/94c2596d-e167-41d3-81c2-4992ccda2db6?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[amazon-clock]: https://mobbin.com/screens/082e7247-6ee0-4b63-9196-414e335caa8d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[zocdoc-similar]: https://mobbin.com/screens/3ae545ce-a65f-457d-b54d-a2fc387d9952?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[sesame-oops]: https://mobbin.com/screens/2d85e6ae-5a90-44c0-9ceb-d0cff29fb561?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[bolt-error]: https://mobbin.com/screens/68295fea-b87b-4e4a-bb5a-d61d18a645de?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[paypal-wait]: https://mobbin.com/screens/305815a1-eb96-4544-bde7-c1342b7e15ce?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[qantas-offline]: https://mobbin.com/screens/18f77caf-19d5-4199-98b4-a36f34096d23?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[julienne-toast]: https://mobbin.com/screens/67eeba02-a85b-4837-9d49-1b367ceb4cec?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[toggl-logout]: https://mobbin.com/screens/1c360219-bf08-46b8-af3c-4bd04b5ea637?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[watch-fork]: https://mobbin.com/screens/d906f227-2454-4977-a327-1b01b368ff86?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[aby-restore]: https://mobbin.com/screens/3afb3ceb-70ac-419b-8242-a556c3349702?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[cbw-import]: https://mobbin.com/screens/0ab6f7de-96b4-4401-aaba-c2491c82f645?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[wa-restore]: https://mobbin.com/screens/52443d1a-819e-4b75-8ed9-9d23e92915a7?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[family-existing]: https://mobbin.com/screens/0a0d7a18-c655-4f4e-8363-c8cfa0f9d22f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[uniswap-flow]: https://mobbin.com/flows/bec217a1-12d6-4f46-afc1-4efc2cc24c5b?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[ihg-flow]: https://mobbin.com/flows/68d72ee8-ca80-4576-9760-ae046d12a000?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[granola-flow]: https://mobbin.com/flows/6af0151a-cff1-4f30-8f89-da9c13d01cb6?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[brave-qr]: https://mobbin.com/screens/53c3fdf5-a622-4484-aa67-8ed340ca85c0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[comet-qr]: https://mobbin.com/screens/3670b77f-56c3-49f6-bd8c-4befe2a80b1f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[x-qr]: https://mobbin.com/screens/ceb1bed4-2ba1-4dc8-8921-aa9e80233b2a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[alexa-scan]: https://mobbin.com/screens/7c95dd6a-5e7d-4415-9da2-7c7b38307d28?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[tiktok-link]: https://mobbin.com/screens/785dd1f6-3b18-4b09-bf80-82dcdb93ee41?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[brave-flow]: https://mobbin.com/flows/d88ac8ab-7c73-47e8-9f07-91e3d8de1901?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[comet-flow]: https://mobbin.com/flows/149a9ec2-a811-4de5-ad77-5b3a9db59c60?tab=screens&utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[netflix-code]: https://mobbin.com/screens/89030151-1f40-444c-9b54-89f46080a987?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[gphotos-import]: https://mobbin.com/screens/604613b0-a4e4-4457-b323-82f8b09e7c9a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[beli-import]: https://mobbin.com/screens/37f37fce-fd8b-4c3c-8f67-86279d513ecf?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[notion-source]: https://mobbin.com/screens/beb4a541-29ca-4203-a89e-a0f5d504e113?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[fabric-import]: https://mobbin.com/screens/82f4e227-ebd8-4d10-9c19-15636e14b069?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[expensify-import]: https://mobbin.com/screens/eb2f9630-0e5e-4b5b-8aa3-c9c67b13494f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[phantom-result]: https://mobbin.com/screens/c09c98b2-45e3-47cc-8c62-a2322163d0f5?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[cvs-added]: https://mobbin.com/screens/9fbb97a1-882e-431d-b2fe-87d8c4903b74?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[neuecast-import]: https://mobbin.com/screens/41f1da4d-edc5-4714-b8a0-545edde7d129?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[binance-backup]: https://mobbin.com/screens/f0c647c8-7bba-49c9-8128-34f43bf52222?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[okx-backup]: https://mobbin.com/screens/05bb56b3-5b93-407d-89db-eab04892f342?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[wa-backup]: https://mobbin.com/screens/8645c5cf-6cbc-4edf-af82-506913f10e34?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[world-backup]: https://mobbin.com/screens/207ae442-82e7-4c4e-9498-c9e39c7e9013?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[5mj-export]: https://mobbin.com/screens/614cfd47-b148-40d2-94db-b9552fb2e24c?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[meta-export]: https://mobbin.com/screens/357e8095-49c0-4fd0-a7db-75782613f119?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[satispay-export]: https://mobbin.com/screens/821da026-8397-43bb-b5fb-38ba1562222e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[xchat-debug]: https://mobbin.com/screens/b7125b37-7fe2-44e1-a5aa-76082bb28f8b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[phantom-logs]: https://mobbin.com/screens/f1bc69e7-88a8-4568-a791-c8f4515418e3?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[structured-diag]: https://mobbin.com/screens/f25a5ade-aef9-48b3-abe6-67469705eeb1?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[bsky-about]: https://mobbin.com/screens/a8faca7a-f780-4895-89d0-2a8518169683?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[docusign-about]: https://mobbin.com/screens/3ab57e7c-1402-4e66-a555-80231d62a7f9?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[expensify-trouble]: https://mobbin.com/screens/41d84ac4-fae8-44fc-9712-5cb700224fc4?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[starlink-about]: https://mobbin.com/screens/0e7fefdd-11f3-4f73-b8c2-67e8034f1ab0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[dropbox-unlink]: https://mobbin.com/screens/c1427e45-8dc3-4f81-86d5-4352c5d26350?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[mesh-keep]: https://mobbin.com/screens/5f4d5760-a4eb-49ee-a760-d3b193899c6a?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[family-logout]: https://mobbin.com/screens/5faa23ca-c784-4e57-8aef-87e89b4e8962?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[mf-disable]: https://mobbin.com/screens/6a585439-bf59-4394-806f-c717c769e404?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[solflare-logout]: https://mobbin.com/screens/921613c3-7a8b-4a80-820b-9b54a3528714?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[quo-delete]: https://mobbin.com/screens/96d639aa-7714-40e5-963e-c044cc5ff9ab?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[kit-delete]: https://mobbin.com/screens/52d49146-98ed-49b2-a816-7d7a07da444f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[headspace-logout]: https://mobbin.com/screens/d1b64528-0f90-4d83-8116-30d064757a56?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[scoot-logout]: https://mobbin.com/screens/935ed7aa-faa9-4d7b-beff-722017c70f03?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[st-leave]: https://mobbin.com/screens/34c94d2b-d220-4d9f-be4b-10411468385e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[klook-logout]: https://mobbin.com/screens/cdee9632-6ccf-4645-bfb0-c950757721dc?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[x-web]: https://mobbin.com/screens/b58d381d-58f1-4fd6-8012-a78bed482658?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[slite-web]: https://mobbin.com/screens/0bd65060-cd77-4ecb-a35f-1996dd957316?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[mercury-web]: https://mobbin.com/screens/56253502-64d3-43e6-a28e-49bec5ab814b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[gdrive-web]: https://mobbin.com/screens/018d0358-d0f8-43d9-9a34-490c677f273b?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp
[superlist-web]: https://mobbin.com/screens/99f1615e-cc2b-43cc-b2f1-b2a274545e0f?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp

## Mobbin notice

---

**Your Mobbin AI usage is high this month**

Usage is unlimited during beta. If your usage stays at this level, you may need to purchase more credits once limits take effect. [View usage and plan options](https://mobbin.com/settings/billing-and-usage?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)
