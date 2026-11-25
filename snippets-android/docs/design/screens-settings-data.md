# Screens: settings, sync status, review, backup, diagnostics, about

Covers inventory IDs SET, SET-SEARCH, SET-SYNC, SHEET-PROVIDER, ALERT-SWITCH, ALERT-SWITCH-PROGRESS, ALERT-SWITCH-ATTENTION, ALERT-RECOVERY-CONFIRM, SET-BACKUP, IMPORT-RAYCAST, IMPORT-QUARANTINE-JSON / -BACKUP, ALERT-BACKUP-NEW-PW / -OPEN-PW, SET-DIAG, SET-ABOUT, and inventory §7 and §10. `settings/secure` is in `screens-secure.md`; Git and Cloud are in their own files. Components: `components.md` (C§n).

---

## 1. SET — `settings`

Full-screen destination (D26). Reached from More ▸ `Settings` and Ctrl+,.

### 1.1 Phone layout

```
┌──────────────────────────────────────────────┐
│ [←]  Settings                                │  TopAppBar                          topbar.title
│ ┌──────────────────────────────────────────┐ │
│ │ [search] Search Settings            [×]  │ │  always visible                     settings.search
│ └──────────────────────────────────────────┘ │
│ Library                                      │  section header (C§5)
│ [sync]   Sync                                │  settings.row.sync
│          On. Last synced at 9:04 PM.         │
│ [lock]   Secure Snippets                     │  settings.row.secure
│          Locked                              │
│ [hard_drive] Backup                          │  settings.row.backup
│          Import, export, encrypted backup    │
│ General                                      │
│ [palette] Appearance                         │  settings.row.appearance
│          System theme · Snippets colors      │
│ Support                                      │
│ [troubleshoot] Diagnostics                   │  settings.row.diagnostics
│          37 files, 1.2 MB                    │
│ [info]   About                               │  settings.row.about
│          Version 2.0.0 (210)                 │
└──────────────────────────────────────────────┘
```

Rows are navigation `SettingsRow`s (C§12) with live supporting text:

| Row | Supporting text | Opens |
|---|---|---|
| `Sync` | The status sentence (§4), up to two lines. When sync needs the user the row uses the Attention variant (leading `warning`, headline in `warning`) | `settings/sync` |
| `Secure Snippets` | `Not set up` / `Locked` / `Unlocked` *(Android)* | `settings/secure` |
| `Backup` | `Import, export, encrypted backup` *(Android)* | `settings/backup` |
| `Appearance` *(Android)* | `%1$s theme · %2$s`: `System` / `Light` / `Dark`; `Snippets colors` / `Wallpaper colors` | `settings/appearance` |
| `Diagnostics` | `%1$d file(s), %2$s` (plural), or `The diagnostics folder is unavailable.` | `settings/diagnostics` |
| `About` | `Version %1$s (%2$s)` | `settings/about` |

Section headers: `Library`, `General` *(Android)*, `Support`.

### 1.2 Two-pane layout (expanded and larger)

```
┌───────────────────────────┬─────────────────────────────────────────────────┐
│ [←]  Settings             │  Sync                                           │  pane title, titleLarge
│ [search] Search Settings  │ ─────────────────────────────────────────────── │
│ Library                   │  (settings/sync content, max width 640 dp)      │
│ ╭───────────────────────╮ │                                                 │
│ │ [sync] Sync           │ │  selected row: secondaryContainer, shape medium │
│ ╰───────────────────────╯ │                                                 │
│ [lock] Secure Snippets    │                                                 │
│ …                         │                                                 │
└───────────────────────────┴─────────────────────────────────────────────────┘
   list pane 320 / 360 dp
```

- `Sync` is preselected. The Up arrow in the list pane returns to the library.
- Deeper screens (`settings/sync/git`, `settings/sync/cloud`, `settings/about/notices`) replace the detail pane's content and show an Up arrow in the detail pane's top bar.
- Supporting texts stay visible in the list pane.

---

## 2. SET-SEARCH

- Field: `SearchBar`-styled field (C§4.1 visuals, no More button), placeholder `Search Settings`, always visible at the top of the settings list.
- Searches a fixed vocabulary only, never user content. Every whitespace-separated token must appear in the entry's title, its pane title or its keywords (case- and diacritic-insensitive). Ranking per token: exact title 100, title prefix 60, title contains 35, pane prefix 20, keyword prefix 12, otherwise 1; ties by pane order, then title.
- With a non-empty query the sections are replaced by the header `Search Results` and one `ListItem` per entry: headline = title, supporting = pane name.
- No match: `No settings match “%s”.` *(Android)* (`bodyMedium`, centred, 24 dp top).
- Choosing a result opens its pane (phone: push; two-pane: select), scrolls the target row into view and flashes it for 700 ms (C§12). The query is kept; back returns to the results.

Catalog (title → pane; keywords):

| Title | Pane | Keywords | Lands on |
|---|---|---|---|
| `Sync Provider` | Sync | backend, git, github, gitlab, gitea, gitverse, repository (+ `snippets cloud` in Cloud builds) | provider row |
| `Git Repository` *(Android)* | Sync | token, access token, ssh, deploy key, branch, recovery code | provider row |
| `Cloud Account` (Cloud builds only) | Sync | sign in, sign out, account, create account, account key | provider row |
| `Sync This Library` | Sync | enable, turn on, local only | switch row |
| `Sync Status` | Sync | last sync, state, health | status row |
| `Sync Now` | Sync | refresh, upload, download | `Sync Now` row, else status row |
| `Sync Recovery` | Sync | review, resume, reset, account | recovery row, else status row |
| `Secure Snippets Status` | Secure Snippets | vault, protected, locked | status row |
| `Key Storage` | Secure Snippets | keystore, device, key | key storage row |
| `Set Up Secure Snippets` | Secure Snippets | vault, create, password | its row when shown, else status row |
| `Lock Now` | Secure Snippets | vault, secure | its row, else status row |
| `Add Recovery Key` | Secure Snippets | backup, offline, vault | its row, else status row |
| `Restore with Recovery Key` | Secure Snippets | recover, vault, key | its row, else status row |
| `Remove Secure Snippets from This Device` | Secure Snippets | forget, delete local, vault | its row, else status row |
| `Import Library` | Backup | json, restore, file, raycast | row |
| `Export for Sharing` | Backup | json, plain text, file | row |
| `Export Encrypted Backup` | Backup | archive, password, restore | row |
| `Theme` *(Android)* | Appearance | dark, light, system | row |
| `Use Wallpaper Colors` *(Android)* | Appearance | dynamic color, material you | row (Android 12+ only) |
| `Persistent Logs` | Diagnostics | diagnostics, storage, retention | row |
| `Export Logs` | Diagnostics | diagnostics, support, jsonl | row |
| `Delete Logs` | Diagnostics | clear, privacy, diagnostics | row |
| `Version and Build` | About | about, app, release | header |
| `Project and License` | About | github, source, mit | GitHub row |
| `Open-Source Notices` *(Android)* | About | licenses, third party, fonts | row |

Tags: `settings.search`, `settings.search.clear`, `settings.search.header`, `settings.search.result.<key>` (key = lower-case title with hyphens), `settings.search.empty`.

---

## 3. SET-SYNC — `settings/sync`

```
┌──────────────────────────────────────────────┐
│ [←]  Sync                                    │
│ [commit] Sync Provider                       │  settings.row.provider
│          Git · github.com/me/library         │
│ Sync This Library                    [●  ]   │  settings.row.sync-enabled (switch row)
│   Encrypted before it is sent to your Git    │
│   repository.                                │
│ Status                                       │  settings.row.status
│   On. Last synced at 9:04 PM.                │
│ Sync Now                                     │  settings.row.sync-now (action)  — or —
│ [warning] Confirm Deletions                  │  settings.row.recovery (attention)
│   These deletions did not include proof …    │
│ Background Sync                              │  settings.row.background (static fact)
│   Snippets syncs when you open it and after  │
│   changes. Android may delay sync in the     │
│   background to save battery.                │
└──────────────────────────────────────────────┘
```

| # | Row | Supporting text | Behaviour |
|---|---|---|---|
| 1 | `Sync Provider` (always shown) | `Not set up` *(Android)* / `Git · %s` (host/path) / `Snippets Cloud` | Standard builds: opens `settings/sync/git`. Cloud builds: opens the chooser (§3.1) |
| 2 | `Sync This Library` (switch) | Plain-text Git library: `Ordinary snippets are saved as readable Markdown files in your Git repository. Secure snippets stay encrypted.` · Cloud builds: `Encrypted before it is sent. Only one provider is writable at a time.` · Standard builds, Git set up: `Encrypted before it is sent to your Git repository.` · Nothing set up: `Sync is optional. Everything works on this device without an account.` *(Android)* | On → §3.2. Off → sync stops at once; status becomes `Off. Your snippets stay on this device.` Nothing is deleted anywhere |
| 3 | `Status` | The status sentence (§4); polite live region while this screen is visible | Not clickable. Long-press selects the text |
| 4a | Recovery row (Attention variant): title = the recovery action title | The action's explanation (§6) | Opens `sync/review` when the action needs confirmation; otherwise runs it (spinner in the row) |
| 4b | `Sync Now` (action) | — | Manual round; the row shows a spinner until it ends |
| 4c | (neither) | | When sync needs attention without a recovery action, or sync is off |
| 5 | `Background Sync` *(Android, static)* | `Snippets syncs when you open it and after changes. Android may delay sync in the background to save battery.` | Not clickable |

Exactly one of 4a / 4b / 4c shows.

### 3.1 SHEET-PROVIDER — `settings/sync/provider` (Cloud builds only)

`ModalBottomSheet`.

```
│ Sync Provider                                │  titleLarge                              provider.title
│ Switching keeps your snippets and the other  │  bodyMedium                              provider.message
│ provider’s copy.                             │
│ [commit] Git Repository…               [✓]   │  ListItem                                provider.option.git
│          github.com/me/library (main)        │
│ [cloud]  Snippets Cloud…                     │                                          provider.option.cloud
│          Not connected                       │
│ ──────────────────────────────────────────── │
│ Sign Out of Snippets Cloud on This Device    │  destructive ListItem, at most one       provider.maintenance
```

| Option | Supporting text | Tap |
|---|---|---|
| `Git Repository…` | `%1$s (%2$s)` (host/path, branch) / `Not connected` | Not connected: `settings/sync/git`. Connected and not current: `dialog/switch`. Current: `settings/sync/git` |
| `Snippets Cloud…` | `Library ID %s` / `Not connected` | Not connected: `settings/sync/cloud`. Connected and not current: `dialog/switch`. Current: `settings/sync/cloud` |
| Maintenance (one of) | `Reset Unreadable Cloud Sign-In` / `Retry Sign Out` / `Sign Out of Snippets Cloud on This Device` | `screens-cloud.md` §10 |

The current provider shows a trailing `check` (`primary`) and `selected` semantics. There is no "this device only" option: turning sync off is the switch (D20).

### 3.2 Turning `Sync This Library` on

| Situation | Result |
|---|---|
| No provider set up, standard build | Opens `settings/sync/git`; the switch stays off until setup ends with `Switch and Sync` (D21) |
| No provider set up, Cloud build | Opens the chooser |
| Provider set up | `dialog/switch`, "sync currently off" variant (§5); the switch moves only after the user confirms and the switch-over succeeds |

---

## 4. The status sentence

One generator; shown in `Status`, on the Settings home row, in the sync sheet, in empty states and on the Git and Cloud screens.

| State | Sentence |
|---|---|
| Off | `Off. Your snippets stay on this device.` |
| Cannot start | `Cannot start: %s` |
| Starting | `Starting…` |
| Idle, never synced | `On. Nothing synced yet.` |
| Idle, synced today | `On. Last synced at %s.` |
| Idle, synced earlier | `On. Last synced %s.` (date and time) |
| Syncing | `Syncing…` |
| Offline | `Cannot reach %1$s. Trying again at %2$s.` |
| Needs authentication | `%1$s needs attention: %2$s.` |
| Needs attention | `Sync needs attention: %s.` plus ` Fix the reported condition, then try again.` for non-Git details |
| Waiting for vault (Git, key present) | `Waiting: a secure snippet was changed on two devices. Open any secure snippet to unlock them, then use Sync Now to keep both versions.` |
| Waiting for vault (Git, no vault) | `Waiting: %s. Open the Git repository in Sync settings and choose Set Up Secure Snippets.` |
| Waiting for vault (other) | `Waiting: %s.` |
| Halted | `Stopped because %1$s: %2$s. %3$s` (reason, detail, guidance; §6) |

Authentication details (`%2$s` of "needs authentication"): `Sign in to continue` · `Your sign-in expired; sign in again` · `Sign in again to continue` · and the Git details in `screens-git.md` §10.

Attention details by failure code (non-Git; Git codes are in `screens-git.md` §10):

| Code | Detail | Review card action |
|---|---|---|
| `record_too_large`, `payload_too_large` | `One snippet is too large for the cloud service` | `Open Sync Settings` |
| `quota_exceeded` | `The cloud account is out of storage` | `Open Sync Settings` |
| `forbidden` | `This account cannot update the selected cloud library` | `Open Sync Settings` |
| `incompatible_version` | `Update Snippets before syncing again` | none |
| `startup_prerequisite_unavailable` | `A local sync prerequisite is temporarily unavailable` | `Try Again` |
| `cloud_key_required` | `Approve this device or restore the Snippets Cloud recovery kit` | `Open Sync Settings` |
| `sync_key_unreadable` | `The stored sync encryption key could not be verified` | `Open Sync Settings` |
| `not_found` | `The selected cloud library is no longer available` | `Open Sync Settings` |
| `internal_error` | `The cloud service could not accept a change` | `Try Again` |
| anything else | `The cloud service rejected a change` | `Open Sync Settings` |

Start-up problems (`%s` of "Cannot start"): `A newer Snippets version wrote the local sync state. Update Snippets.` · `The local sync checkpoint could not be read.` · `This device does not have the Git library’s key yet. Open Git in Sync settings and enter the library’s recovery code.` · `The Git access token is missing on this device. Open Git in Sync settings and enter it again.` · `Git is selected, but no repository is connected on this device. Open Git in Sync settings to connect it, or choose another provider.` (standard builds end with `…to connect it, or turn off sync.` *(Android)*) · `The Git library key saved on this device could not be verified. Reconnect the repository in Sync settings with its recovery code. Check Again only rechecks the key; it does not repair it.`

Triggers for a round: launch, return to the foreground, a local change (debounced 1 s; Git pacing in `screens-git.md` §11), pull to refresh, `Sync Now`, a provider switch, and a periodic WorkManager job every 6 hours (network required) while sync is on. There is no push-triggered sync.

---

## 5. Provider switch

### 5.1 ALERT-SWITCH — `dialog/switch`

| Variant | Title | Message |
|---|---|---|
| Sync currently off | `Start Syncing with %s?` | `The %1$s on this device will be merged with %2$s, and sync will turn on.` |
| Sync on (changing provider) | `Switch Sync to %s?` | `Snippets merges the %1$s on this device with %2$s, then syncs only with %3$s. Your %4$s copy is kept.` |

- `%1$s` count: `1 snippet` / `%d snippets`. Destination: `%1$s (%2$s)` (host/path and branch) for Git, `Snippets Cloud (Library ID %s)` for Cloud.
- A plain-text Git library adds the paragraph `This is a plain-text library: ordinary snippets will be readable in the repository.`
- Buttons: `Cancel` · `Switch and Sync`.

### 5.2 ALERT-SWITCH-PROGRESS — `dialog/switch-progress`

Not dismissable (no buttons, back blocked). Title `Switching to %s…`. Body: a progress step list (C§13) with `Checking destination`, `Comparing libraries`, `Uploading changes`, `Verifying sync`, ticked as the switch reports each phase. If the switch operation exposes no phases, the body is the single line `Checking destination · comparing libraries · uploading changes · verifying sync` under an indeterminate `LinearProgressIndicator`.

Success is silent: the dialog closes, the status row updates, and `%s is active and up to date.` is announced.

### 5.3 ALERT-SWITCH-ATTENTION — `dialog/switch-attention`

Title `Switch Needs Attention` · message `Your libraries were not deleted. %s` (status sentence) · button `OK`.

Tags: `dialog.switch`, `dialog.switch-progress`, `dialog.switch-attention` (+ shared dialog tags, `progress.step.<n>`).

---

## 6. Review — `sync/review` (ALERT-RECOVERY-CONFIRM)

Template: C§15. Opened from the Review card, the More menu's sync item, pull to refresh, the first-fetch empty state and the `settings/sync` recovery row. The screen is the confirmation (D23).

| Part | Content |
|---|---|
| Top bar title | `Sync Stopped` (halts) / `Sync Needs Attention` |
| Heading | The confirmation title, or the action title when there is none |
| `What happened` | The status sentence |
| `What this does` | The action's explanation |
| `On this device` | `%1$d snippets, %2$d of them secure. Nothing on this device changes until you choose an action.` *(Android)* |
| `Details` | `Code: %s` (halt code) with a copy button |
| Buttons | `Not Now` · primary |

Halts:

| Halt code | Reason (in the sentence) | Guidance (in the sentence) | Action title | Review heading | Primary button |
|---|---|---|---|---|---|
| `mass_deletion` | `an unusually large deletion arrived` | `Updated Snippets devices normally approve their own explicit delete actions at the source. This batch has no such proof, so review its count before applying it on this device.` | `Confirm Deletions` | `Apply These Deletions?` | `Apply Deletions` (destructive) |
| `mass_deletion` without exact details | same | — | `Refresh Deletion Details` | `Refresh Deletion Details` | `Refresh Deletion Details` (runs without Review from cards and rows) |
| `account_changed` | `the cloud account changed` | `If you intended to switch accounts, review the account change. Snippets can keep this device's current library and merge it into the newly signed-in account from a fresh checkpoint.` | `Review Account Change` | `Use the Current Cloud Account?` | `Use This Account` |
| `checkpoint_unreadable` | `the local sync checkpoint could not be read` | `Repair keeps this device's current library, replaces only the unreadable local scheduler checkpoint, and performs a full merge.` | `Repair Sync` | `Repair Sync` | `Repair Sync` (no confirmation needed; runs directly from cards) |
| `remote_data_reset` | `the remote cloud library was reset` (Git: `the remote library was reset` *(Android)*) | `No local data was deleted or re-uploaded. Choose Restore only on the device whose current library should repopulate the cloud.` | `Restore Cloud Library` | `Restore Cloud from This Device?` | `Restore from This Device` |
| `backend_refused` | `the cloud service refused a snippet` | `Usually the cloud service is not configured for this app, the account is out of space, or one snippet is too large. None of them is fixed by waiting.` | `Try Again` | `Try Again` | `Try Again` (runs directly) |
| `local_library_quarantined` | `the snippet library could not be read` | `Restore a valid exported library or quarantined backup, reopen Snippets, then choose Check Again. Snippets will not treat the missing library as an empty one.` | `Check Again` | `Check Again` | `Check Again` (runs directly) |
| `vault_unreadable` | `the secure vault could not be read` | `Restore or repair the secure vault, then choose Check Again.` | `Check Again` | `Check Again` | `Check Again` |
| `manifest_integrity_failed` | `the backend failed an integrity check` | — | `Check Again` | `Check Again` | `Check Again` |
| `schema_too_new` | `a newer version of Snippets wrote this library` | `Update Snippets on this device.` | none | `Update Snippets` | none (`Close`) |
| recovery claimed elsewhere | (any of the above) | — | `Take Over Recovery` | `Take Over Interrupted Recovery?` | `Take Over` |

Explanations (`What this does`):

| Action | Text |
|---|---|
| `Confirm Deletions` | `These deletions did not include proof of an explicit delete action from an updated Snippets device. This authorizes the exact batch described above and lets sync finish it. If an earlier confirmed attempt was interrupted, some records may already have been applied. Continue only if the deletion was intentional.` |
| `Refresh Deletion Details` | `Fetch this deletion batch again so Snippets can bind a later confirmation to the exact records. This check does not delete anything.` |
| `Review Account Change` | `This keeps the library on this device, replaces the old account checkpoint, and merges it into the cloud account signed in now. If you did not intend to switch accounts, cancel and sign back in to the previous account.` |
| `Repair Sync` | `This keeps every local snippet, replaces only the unreadable sync scheduler checkpoint, and performs a full merge with the cloud library.` |
| `Restore Cloud Library` | `The remote library was reset. This makes the current library on this device the recovery source and uploads it through a fresh cloud checkpoint. Use the device with the most complete library.` |
| `Take Over Recovery` | `This clears only the ownership claim left by an interrupted recovery on another process or device. It does not apply deletions, change accounts, or restore cloud data. Close Snippets on the other device first. After takeover, review and confirm the original action again.` |
| `Try Again` | `Try syncing again after correcting the condition described above.` |
| `Check Again` | `Check the local files again. Sync remains stopped if the condition is still present.` |

Deletion guard: more than `max(5, 20 % of the library)` remote deletions without proof of an explicit delete stop sync. Detail sentence: `cloud sync reported a batch deleting %1$d of %2$d snippets. Sync paused before completing this batch. Applied in full to the reviewed library state, it keeps at least %3$d snippets; up to %4$d deletions may be applied without confirmation` (Git: starts with `Git sync reported…` *(Android)*).

Conflict copies are not a review: sync creates an ordinary, disabled entry named `%1$s (conflict %2$s)` with the tag `conflict`; the user finds it through the tag (D33) and resolves it by hand. The secure-conflict wait is the "Waiting for vault" sentence in §4.

---

## 7. SET-BACKUP — `settings/backup`

```
│ [←]  Backup                                  │
│ [file_open]  Import Library                  │  settings.row.import
│              Add snippets from a JSON library or restore an encrypted archive.
│ [file_save]  Export for Sharing              │  settings.row.export
│              Create a readable JSON copy of the library.
│ [enhanced_encryption] Export Encrypted Backup│  settings.row.encrypted-backup
│              Create a password-protected archive.
│ Exports for sharing are readable JSON. Use an encrypted backup for safekeeping.   (footer, bodySmall)
```

Each row runs the same flow as the library's More menu (§8–§10). The flow runs in place, on top of Settings; results appear as snackbars on the current screen.

---

## 8. Import

| Step | Behaviour |
|---|---|
| 1 | `ACTION_OPEN_DOCUMENT` with MIME types `application/json`, `application/vnd.khm.snippets.encrypted-backup`, `application/octet-stream`. The file is identified by its content, not its name. Cancelling the picker is silent |
| 2 | Snackbar `Reading import…` (stays until the result). Limits: 16 MiB for JSON, 32 MiB for a backup |
| 3 | An encrypted backup continues at §10.2 |
| 4 | JSON accepted: a raw array, `{"snippets": […]}`, or a Raycast export. Merge by id first, then by case-insensitive keyword, so re-importing updates instead of duplicating |
| 5 | Keywords starting with `!`: IMPORT-RAYCAST — `import/raycast`: title `Raycast Keywords`; message `Some imported keywords begin with !. Keep it as part of each keyword?`; buttons (stacked) `Remove !` · `Keep !` · `Cancel` |
| 6 | Snackbar `Imported %d snippet(s).` (plural). The list scrolls to the top |
| Library quarantined | §11 instead of step 6 |

Errors: `dialog/error` titled `Couldn’t Import Snippets` with one of `The selected file could not be read.` · `Unsupported file format. Expected JSON exported from Snippets or Raycast.` · `The selected file is too large. The maximum supported size is %s.` (`16 MB` / `32 MB`).

Tags: `dialog.import-raycast`, `dialog.error`.

---

## 9. Export for Sharing

| Step | Behaviour |
|---|---|
| 1 | `ACTION_CREATE_DOCUMENT`, suggested name `Snippets-Export.json`, MIME `application/json`. Cancelling is silent |
| 2 | The JSON is written straight to the chosen document (no temporary file) |
| 3 | Snackbar `Exported %d ordinary snippet(s). Secure snippets are excluded.` (plural) |

Error title `Couldn’t Export Snippets`. Secure entries are never part of this export.

---

## 10. Encrypted backup

### 10.1 Export — `backup/new-password` (ALERT-BACKUP-NEW-PW)

Full-screen dialog (D14), `FLAG_SECURE`.

```
┌──────────────────────────────────────────────┐
│ [X]  Protect Encrypted Backup                │
│ This private backup includes secure          │
│ snippets. Use a unique password of at least  │
│ 12 characters and save it in a password      │
│ manager; Snippets cannot recover it.         │
│ Backup password                              │
│ ┌──────────────────────────────────────────┐ │
│ │ ••••••••••••••                    [eye]  │ │  backup.password
│ └──────────────────────────────────────────┘ │
│ At least 12 characters.                      │
│ Confirm password                             │
│ ┌──────────────────────────────────────────┐ │
│ │ ••••••••••••••                    [eye]  │ │  backup.confirm
│ └──────────────────────────────────────────┘ │
│ ┌──────────────────────────────────────────┐ │
│ │              Create Backup               │ │  backup.submit
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

| Element | Copy and behaviour |
|---|---|
| Title | `Protect Encrypted Backup` |
| Body | With a vault: `This private backup includes secure snippets. Use a unique password of at least 12 characters and save it in a password manager; Snippets cannot recover it.` Without a vault: `Use a unique password of at least 12 characters and save it in a password manager. Snippets cannot recover it.` |
| Fields | `Backup password`, `Confirm password` (C§11.2, C§11.4 password field) |
| Supporting text | First field: `At least 12 characters.` *(Android)*. Second field, when both are non-empty and differ: error `The passwords do not match.` *(Android)* |
| `Create Backup` | Enabled only when the password has ≥ 12 characters, is not all whitespace and both fields match |
| `X`, back | Cancel; the passwords are wiped |

Then:

| Step | Behaviour |
|---|---|
| 2 | When a vault exists: `BiometricPrompt` `Export an encrypted backup`. Cancel aborts silently. Snackbar `Preparing encrypted backup…` |
| 3 | `ACTION_CREATE_DOCUMENT`, name `Snippets-Backup.snippetsbackup`, MIME `application/vnd.khm.snippets.encrypted-backup` |
| 4 | Snackbar `Backup contains %1$d ordinary and %2$d secure snippets.` |

Error title `Couldn’t Create Encrypted Backup`. While the library is quarantined the body is `A new all-library backup cannot be created while the ordinary snippet library is unreadable. You can still restore an existing encrypted backup, or use a complete Snippets JSON export.`

### 10.2 Import — `backup/open-password` (ALERT-BACKUP-OPEN-PW)

Full-screen dialog, `FLAG_SECURE`.

| Element | Copy and behaviour |
|---|---|
| Title | `Open Encrypted Backup` |
| Body | `Enter the password used when this backup was created.` |
| Field | `Backup password` (tag `backup.open.password`), visibility toggle, IME `Done` = submit |
| `Open Backup` (`backup.open.submit`) | Enabled when the field is not empty. Snackbar `Opening encrypted backup…` while it works (the button shows a spinner) |
| Wrong password | Field error `That password does not unlock this backup.`; the dialog stays, the text is kept and selected |
| Secure records present | `BiometricPrompt` `Import an encrypted backup` before anything is written |
| Success | Closes; snackbar `Imported %1$d ordinary and %2$d secure snippet(s).` |

Other failures: `dialog/error` titled `Couldn’t Import Encrypted Backup` with one of:

| Message |
|---|
| `The backup is damaged or has been modified. Nothing was imported.` |
| `This is not a Snippets encrypted backup.` |
| `This backup uses format version %d, which this version of Snippets cannot read.` |
| `This backup belongs to a different secure-snippet vault. Import it into a fresh Snippets library or a device already using the same vault.` |
| `The backup and this device have different keys for the same secure-snippet vault. Nothing was imported.` |
| `Import conflict: %s` (one) / `Import conflicts:` followed by a bulleted list (several) |

File type: extension `.snippetsbackup`, MIME `application/vnd.khm.snippets.encrypted-backup`.

---

## 11. Quarantine recovery (library file unreadable)

| Dialog | Title | Message | Buttons | After |
|---|---|---|---|---|
| IMPORT-QUARANTINE-JSON — `import/quarantine-json` | `Replace the Quarantined Library?` | `The selected file contains %d ordinary snippet(s). It will completely replace the unreadable ordinary-snippet library. Use only a complete Snippets JSON export—a partial or Raycast export can omit data. Secure snippets are unchanged, and the unreadable file is preserved. Sync stays paused until you review it and choose Check Again.` | `Cancel` · `Use Complete Export` (`error`) | Snackbar `Installed %d snippet(s) as the recovery candidate. Review Sync and choose Check Again.` |
| IMPORT-QUARANTINE-BACKUP — `import/quarantine-backup` | `Restore the Quarantined Library from This Backup?` | `The authenticated backup contains %1$d ordinary and %2$d secure snippet(s). Its ordinary library will completely replace the quarantined recovery candidate; compatible secure snippets will be restored in the same transaction. The unreadable original remains preserved, and Sync stays paused until you choose Check Again.` | `Cancel` · `Restore Encrypted Backup` (`error`) | Snackbar `Installed encrypted recovery with %1$d ordinary and %2$d secure snippet(s). Review Sync and choose Check Again.` |

Errors use the titles `Couldn’t Recover Library` and `Library Recovery Required`. The library shows the `Library Recovery Required` empty state (`screens-library-editor.md` §2.4) until `Check Again` succeeds.

---

## 12. Appearance — `settings/appearance` *(Android)*

```
│ [←]  Appearance                              │
│ Theme                                        │
│ ┌──────────┬──────────┬──────────┐           │  SingleChoiceSegmentedButtonRow
│ │ ✓ System │  Light   │   Dark   │           │  settings.theme.system | .light | .dark
│ └──────────┴──────────┴──────────┘           │
│ Use Wallpaper Colors                 [●  ]   │  settings.row.dynamic-color (Android 12+ only)
│   Use this device’s Material You palette     │
│   instead of the Snippets colors. Tag,       │
│   secure and warning colors do not change.   │
```

| Setting | Values | Default |
|---|---|---|
| `Theme` | `System` · `Light` · `Dark` | `System` |
| `Use Wallpaper Colors` | on / off; the row is absent below Android 12 | off (D2) |

Changes apply at once without restarting the activity (theme cross-fade 200 ms; cut under reduced motion).

---

## 13. SET-DIAG — `settings/diagnostics`

```
│ [←]  Diagnostics                             │
│ Persistent Logs                              │  settings.row.logs (status)
│   37 files, 1.2 MB. Kept for up to 14 days.  │
│ [file_save] Export Diagnostic Logs           │  settings.row.export-logs (action)
│   Plaintext JSON Lines. Operation counts and │
│   durations, … are excluded.                 │
│ [delete] Delete Diagnostic Logs              │  settings.row.delete-logs (destructive)
```

| Row | Detail | Behaviour |
|---|---|---|
| `Persistent Logs` | `%1$d file(s), %2$s. Kept for up to 14 days.` (plural) or `The diagnostics folder is unavailable.` (`error` colour with icon) | Not clickable |
| `Export Diagnostic Logs` | The privacy notice below | `dialog/export-logs`, then `ACTION_CREATE_DOCUMENT` (`Snippets-Diagnostics.jsonl`, MIME `application/x-ndjson`); one validated file, limit 25 MiB; snackbar `Diagnostic logs exported.` *(Android)* with action `Share` (Sharesheet with the saved document). Error title `Couldn’t Export Diagnostics` |
| `Delete Diagnostic Logs` | — | `dialog/delete-logs` |

Privacy notice (the Android field list; it must match what the Android logger writes and be reviewed with the logging schema, see `open-questions.md`):

`Plaintext JSON Lines. Operation counts and durations, sync states and failure codes, Git round and key-replacement outcomes, sign-in stages and HTTP status codes, authentication and copy outcomes, text-action outcomes, and secure-snippet keywords may be included; bodies, clipboard contents, selected text, names, tags, IDs, paths, repository addresses, account keys, account IDs, tokens, recovery codes, keys and ciphertext are excluded.`

| Dialog | Title | Message | Buttons |
|---|---|---|---|
| `dialog/export-logs` *(Android)* | `Export Diagnostic Logs?` | The privacy notice, then `Read the file before you send it to anyone.` | `Cancel` · `Export` |
| `dialog/delete-logs` | `Delete Diagnostic Logs?` | `This permanently removes retained diagnostics from this device.` | `Cancel` · `Delete Logs` (`error`) |

After deleting: snackbar `Diagnostic logs deleted.` *(Android)*. Retention: 14 days, 64 files, 24 MiB, rotation at 1 MiB or 24 h. There is no logging switch, no "send to developer" button and no identifier on screen.

---

## 14. SET-ABOUT — `settings/about`

```
│ [←]  About                                   │
│              [app icon 72 dp]                │
│                 Snippets                     │  titleLarge                         about.name
│            Version 2.0.0 (210)               │  bodyMedium, onSurfaceVariant       about.version
│ View on GitHub                         [↗]   │  settings.row.github (link)
│   Source code, releases, and issue tracker   │
│ MIT License                            [↗]   │  settings.row.license (link)
│   Open-source license                        │
│ Open-Source Notices                          │  settings.row.notices (navigation)
│   Licenses of the libraries and fonts in this app
```

| Element | Behaviour |
|---|---|
| `Version %1$s (%2$s)` | Long-press copies `Snippets %1$s (%2$s) · Android %3$s` *(Android)* (ordinary copy rules, C§17) |
| `View on GitHub` | `https://github.com/wowlocal/snippets` in a Custom Tab |
| `MIT License` | `https://github.com/wowlocal/snippets/blob/main/LICENSE` |
| `Open-Source Notices` *(Android)* | `settings/about/notices`: a list of components (JetBrains Mono — OFL-1.1, the SSH library, AndroidX and Compose — Apache-2.0, others as bundled), each expanding to its licence text |

Tags: `about.icon`, `about.name`, `about.version`, rows as drawn, `notices.item.<id>`.

---

## 15. Changed strings

| iOS string | Android string | Why |
|---|---|---|
| Settings sheet with `Done` | Full-screen `Settings` with Up | D26 |
| `Cloud Provider` | `Sync Provider` | The default provider is a Git repository; the row is always shown (D20) |
| Row hidden with one provider; value `iCloud` | Row always shown; value `Not set up` on a fresh install | No default provider |
| `Sync this library` | `Sync This Library` | Title Case for row titles, matching the settings catalog title |
| `Encrypted before it is sent. Only one cloud provider is writable at a time.` | `Encrypted before it is sent. Only one provider is writable at a time.` | Git is not a cloud |
| `Encrypted before it is sent to iCloud.` | `Encrypted before it is sent to your Git repository.` | No iCloud |
| SHEET-PROVIDER options `iCloud`, `… ✓`, `Cancel` | `Git Repository…`, `Snippets Cloud…`, trailing check icon, no Cancel | No iCloud; sheet conventions |
| `…on this \(device)…` | `…on this device…` | D19 |
| `Switching to \(provider)…` with one static line | Step list when phases are reported | C§13: only real steps |
| ALERT-RECOVERY-CONFIRM alert | `sync/review` screen | D23 |
| `…on another process or Mac.` | `…on another process or device.` | Platform |
| `the remote cloud library was reset`, `cloud sync reported a batch…` (when Git is the provider) | `the remote library was reset`, `Git sync reported a batch…` | Git is not a cloud |
| Start-up problem `…or choose another provider.` | Standard builds: `…or turn off sync.` | Only one provider exists without the Cloud flag |
| Backup rows close Settings first | Flows run in place | Android pickers return to the calling screen |
| `Exporting \(count) ordinary snippet(s). Secure snippets are excluded.` | `Exported %d ordinary snippet(s). Secure snippets are excluded.` | The file is already written when the snackbar shows |
| Password alerts with fields | Full-screen dialogs with visibility toggles, rule text and inline mismatch error | D14 |
| `Persistent Logs` suffix ` Legacy audit cleanup still needs attention.` | (dropped) | Android has no legacy reveal-audit file |
| `This permanently removes retained diagnostics and any legacy reveal-audit file from this device.` | `This permanently removes retained diagnostics from this device.` | Same |
| Export notice listing CloudKit, paste, Accessibility and Secure Paste fields | The Android notice in §13 | Must list what Android logs contain |
| Settings search keywords `icloud`, `keychain` | removed; `keystore`, `local only`, `raycast`, `material you` added | Platform |
| `(N) file(s)` and other `(s)` forms | Android plurals | Resource plurals |
