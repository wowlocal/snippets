# Parity checklist

The 202 items of `../ux-inventory.md` §13, same numbering. File keys: `D` = `DESIGN.md`, `C` = `components.md`, `LE` = `screens-library-editor.md`, `SE` = `screens-secure.md`, `SD` = `screens-settings-data.md`, `G` = `screens-git.md`, `CL` = `screens-cloud.md`, `SY` = `screens-system.md`. "D12" style references are rows of the Decisions table in `DESIGN.md` §2.

Status: `specified` = same behaviour and presentation intent; `adapted` = capability and safety kept, presentation changed (how is stated); `not applicable` = reason stated. Every P0 and P1 item is `specified` or `adapted`.

## Library

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 1 | P0 | Library screen titled `Snippets`, ordinary and secure together | LE §1, §2.1 | One interleaved list; the search bar is the top bar and `Snippets` is the pane title (D3) | adapted: no drawn title |
| 2 | P0 | Order: pinned, newest created, id | LE §2.1 | Same order, also under search and filters | specified |
| 3 | P0 | `Pinned` header when any match is pinned | LE §2.1, C §5 | Non-sticky `Pinned` header; divider before the rest | specified |
| 4 | P0 | Row name with fallbacks | C §1.1 | Name, else first content line (50 + `…`), else `Untitled Snippet` | specified |
| 5 | P0 | Row second line rules | C §1.2 | Keyword token + first line; `No content` | adapted: keyword drawn as a token instead of `\kw · ` text; one line |
| 6 | P0 | Secure rows never show the body | C §1.2 | Lock glyph, token, fixed preview `Secure snippet` | adapted: one fixed preview for both cases |
| 7 | P0 | Disabled rows: `Disabled · ` prefix, dimmed | C §1.2, §1.3 | Prefix, struck-through token, name in `onSurfaceVariant`, pause glyph | adapted: role colour instead of alpha (D32) |
| 8 | P0 | Row glyphs for secure, pinned, disabled | C §1.1 | `lock`, `push_pin`, `pause_circle` at 16 dp after the name | specified |
| 9 | P1 | Up to three tag pills and `+N` | C §1.1, §3.1 | Opaque text pills, `+N` | specified |
| 10 | P1 | Relative updated time | C §1.1 | Time, `Yesterday`, weekday, month-day at the end of line 1 | specified |
| 11 | P0 | Tap row copies with placeholders resolved | LE §2.3, §2.5 | Tap copies on compact and medium; in two-pane the tap selects and the row's copy button copies | specified |
| 12 | P0 | Copy toast `Copied “name”.` | LE §2.7, C §1.3 | Inline `Copied` state on the row; snackbar only on API 28–32 | adapted: no duplicate of the Android 13+ clipboard overlay (D7) |
| 13 | P0 | `“name” has no content to copy.` | LE §2.3, §2.7 | Snackbar | specified |
| 14 | P1 | Haptic on copy; lighter when nothing copied | D §10 | `Confirm` / `Reject` | specified |
| 15 | P0 | Swipe reveals Edit; full swipe opens the editor | C §1.4 | Swipe right past 40 % opens the editor on release; trailing pencil button as the visible route | adapted: one committed action, no intermediate reveal (D5) |
| 16 | P0 | Other swipe reveals Pin/Unpin and Delete; Delete needs a tap | C §1.4, LE §4 | Swipe left toggles pin; Delete is only in the row menu, editor menu and custom actions | adapted: delete is never on a swipe, so it always needs a tap (D5) |
| 17 | P1 | One row open at a time; scroll or tap closes | C §1.4 | Rows always spring back; one row mid-swipe; scroll cancels | adapted: nothing stays open |
| 18 | P1 | Haptic when the swipe arms and disarms | D §10, C §1.4 | `GestureThresholdActivate` / `SegmentTick` | specified |
| 19 | P0 | Long-press menu: Copy, Edit, Pin/Unpin, Duplicate, Delete | LE §4 | `DropdownMenu` at the touch point; also right-click and Menu key | specified |
| 20 | P0 | New snippet opens a blank editor, body focused | LE §2.2 | Extended FAB `New Snippet`; Ctrl+N; launcher shortcut | specified |
| 21 | P0 | Blank new entry discarded | LE §2.2, §6.7 | Silent discard on leaving | specified |
| 22 | P0 | More menu: New from Clipboard, Transfer, sync action, Settings | LE §3 | `⋮` in the search bar | adapted: Transfer's three items are flat (D28) |
| 23 | P0 | New from Clipboard | LE §2.2 | Menu item, Ctrl+Shift+N, launcher shortcut; clipboard read only then | specified |
| 24 | P0 | `Clipboard Is Empty` alert | LE §7.2 | `AlertDialog` | specified |
| 25 | P0 | Pin and unpin from swipe, menu, editor; ordinary and secure | C §1.4, LE §4, §6.8 | All three, no authentication | specified |
| 26 | P0 | Delete ordinary immediately with `Undo` | LE §2.3 | Snackbar with `Undo`, on every window size (D9) | specified |
| 27 | P0 | Undo restores only that entry, in place, once | LE §2.3 | Same | specified |
| 28 | P0 | Delete secure asks; no undo | LE §7.1 | `dialog/delete-secure`, then snackbar | specified |
| 29 | P0 | Duplicate: ` Copy`, disabled with an active keyword, opens | LE §2.3 | Same | specified |
| 30 | P1 | One-time gesture tip after the first copy | LE §2.7 | One-time snackbar, 2.4 s after the first copy | adapted: wording matches the Android gestures |
| 31 | P1 | Pull to refresh runs a round, follows its duration | LE §2.8 | `PullToRefreshBox` | specified |
| 32 | P1 | Pull to refresh with sync off asks first | LE §2.8, §7.3 | `dialog/sync-opt-in`, plus a set-up variant | specified |
| 33 | P2 | Large collapsing title; static empty screens do not scroll | C §6, LE §2.4 | No large title (D3); the list does not scroll under an empty state | adapted: title part not ported |

## Search and tags

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 34 | P0 | Search field `Search snippets` | C §4.1 | Always-visible M3 search bar | specified |
| 35 | P0 | Search covers name, keyword, tags, ordinary content | LE §2.1 | Same | specified |
| 36 | P0 | Case- and diacritic-insensitive | LE §2.1 | Same | specified |
| 37 | P1 | Fuzzy on name, keyword, tags; contiguous on content | LE §2.1, C §4.2 | Same, with highlighted matches | specified |
| 38 | P0 | Secure bodies never searchable | LE §2.1 | Same; note in the no-results state | specified |
| 39 | P0 | Results keep library order | LE §2.1 | Same | specified |
| 40 | P1 | Off the main thread, stale results dropped | LE §2.1, C §4.1 | Same | specified |
| 41 | P0 | Tag filter sheet with counts | C §3.3 | `ModalBottomSheet` with checkbox rows | specified |
| 42 | P0 | AND; footer says so | C §3.2, §3.3 | Footer `A snippet must match every selected tag.` | specified |
| 43 | P0 | Tag identity folds case and diacritics, fixed locale | LE §2.1 | Same (core) | specified |
| 44 | P0 | Filter button shows the active count | C §3.2 | Tonal filter button with a `Badge` | specified |
| 45 | P0 | `Clear` in the sheet, `Clear Filters` in the empty state | C §3.3, LE §2.4 | Same | specified |
| 46 | P1 | Sheet title shows the active count | C §3.3 | `Filter by Tags (%d)` | specified |
| 47 | P1 | `No Tags Yet` state | C §3.3 | Sheet empty state | adapted: the filter row is hidden while the library has no tags, so the state shows only if tags vanish while the sheet is open |
| 48 | P0 | `No Results`, `No Snippets Match` | LE §2.4 | Empty-state component | specified |
| 49 | P1 | Filters for vanished tags drop silently | LE §2.1 | Same | specified |
| 50 | P1 | Stable tag colours from the shared hash | D §5.3, C §3.1 | FNV-1a index into a 12-colour palette | specified |
| 51 | P2 | Tag search inside the filter sheet | C §3.3 | `Search tags`, shown above 12 tags | specified |

## Editor

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 52 | P0 | Editor with Name, Snippet, Keyword, Tags, Enabled, Secure | LE §6 | Same fields | specified |
| 53 | P0 | Autosave; no Save button | LE §6.7 | Same; back never intercepted | specified |
| 54 | P0 | Title follows the display name | LE §6.3 | Top app bar title | specified |
| 55 | P0 | Name placeholder shows the first content line | LE §6.4 | Same | specified |
| 56 | P0 | Body placeholder `Paste or type`; monospaced | LE §6.4, D §6.2 | JetBrains Mono `monoBody` | specified |
| 57 | P0 | Keyword sanitised; `\` shown, never stored | LE §6.5, C §11.4 | Prefix slot | specified |
| 58 | P0 | Six keyword warnings | LE §6.5 | Supporting text, info or warning level | specified |
| 59 | P1 | Warning indicator with a `Keyword Warning` dialog | LE §6.5 | Icon in the field, text under it, dot on the `Details` tab | adapted: the message is always visible, so no dialog |
| 60 | P1 | Up to three keyword suggestions | LE §6.5 | `SuggestionChip`s under the focused field | specified |
| 61 | P1 | `Existing · …` reference line | LE §6.5 | Same line under the focused field | specified |
| 62 | P2 | Space or Tab completes the next keyword part | LE §6.5 | Same; Tab moves focus when there is nothing to complete | specified |
| 63 | P0 | Tag token field with removable tokens | LE §6.5, C §11.4 | `InputChip`s in a wrapping field | specified |
| 64 | P0 | Comma or Enter commits; paste splits | LE §6.5 | Same | specified |
| 65 | P1 | Backspace on empty input removes the last tag | LE §6.5 | Same | specified |
| 66 | P1 | Tag completion chips | LE §6.5 | Row of `SuggestionChip`s under the field | specified |
| 67 | P0 | Tags normalised and de-duplicated | LE §6.5 | Same | specified |
| 68 | P0 | Enabled switch, `Allow this keyword to expand on Mac.` | LE §6.5 | Switch row | specified |
| 69 | P0 | Placeholder preview with `[Clipboard content]` | LE §6.4 | `Preview Placeholders` disclosure | specified |
| 70 | P0 | Footer `Saved <date> at <time>` | LE §6.4 | Same | specified |
| 71 | P0 | Copy from the editor with footer feedback | LE §6.3, C §10 | Copy icon shows a check; snackbar on API 28–32; countdown row for secure | adapted: same copy-feedback rule as the list (D7, D8) |
| 72 | P0 | Editor menu: Pin/Unpin, Share, Duplicate, Delete | LE §6.8 | `⋮` menu | adapted: Share is `Share Text` and `Share Link` (D29) |
| 73 | P1 | Save failure in red, scrolled into view, announced | LE §6.7 | Pinned error banner plus red footer, assertive | adapted: pinned instead of scrolled to |
| 74 | P1 | Remote changes merge without moving the caret | LE §6.7 | Same | specified |
| 75 | P1 | Content / Details switch above the keyboard | LE §6.3 | `SecondaryTabRow` under the top app bar | adapted: tabs at the top, clear of the IME (D10) |
| 76 | P1 | Single-form editor on tablets with `Preview` | LE §6.9 | One form in the detail pane | specified |
| 77 | P2 | One undo step per focus session | LE §6.7, §8 | Platform text undo (Ctrl+Z) | adapted: per-edit granularity of the platform |

## Secure snippets

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 78 | P0 | Make an entry secure from the editor | SE §4.1 | `Secure` switch row | specified |
| 79 | P0 | First use creates the vault, shows the recovery key once | SE §4.1, §5 | Secret screen | specified |
| 80 | P0 | `Copy & Continue` / `I’ve Saved It` / `Cancel` | SE §5 | `Copy`, `I’ve Saved It`, close `X` | adapted: Copy does not advance (D12, D13) |
| 81 | P0 | Recovery-key copy sensitive, cleared after 5 minutes | SE §5, D §11 | Sensitive clip, 5-minute clear, stated on screen | specified |
| 82 | P0 | Authentication prompt with a specific reason | SE §2 | `BiometricPrompt` title + subtitle | specified |
| 83 | P0 | Locked editor state with `Reveal Secure Content` | C §8, SE §3.1 | Secure panel | specified |
| 84 | P0 | Revealed body editable; saved 0.3 s after typing and on blur | C §8, LE §6.7 | Same | specified |
| 85 | P0 | Re-lock on leaving, background, vault lock, dialogs | SE §3.2 | Same, with a reason line | specified |
| 86 | P0 | Session: 5 minutes idle, 30 maximum | SE §3.3 | Same | specified |
| 87 | P0 | Secure copy authenticates every time | SE §6 | Same | specified |
| 88 | P0 | Secure clipboard sensitive, cleared after 60 s; toast says so | SE §6, C §10 | Countdown row `Clears in m:ss` with `Clear Now` | adapted: countdown row instead of a toast (D8) |
| 89 | P0 | Make ordinary with confirmation and authentication | SE §4.2 | Dialog, then prompt | specified |
| 90 | P0 | Secure entries excluded from share, link, duplicate, plain export | LE §2.3, §4, §6.8; SD §9 | Menu items absent; export excludes them | specified |
| 91 | P0 | Secure body absent from screenshots, recents, recording | SE §3.4, D §11 | `FLAG_SECURE` per window | specified |
| 92 | P0 | Secure body absent from the accessibility tree; stand-in with three values | C §8 | `clearAndSetSemantics` + sibling node | specified |
| 93 | P0 | Secure field allows only delete, paste, select, select all | C §8 | Custom text toolbar; no drag, no Autofill | specified |
| 94 | P0 | No placeholder preview for secure entries | LE §6.4, SE §3 | Absent | specified |
| 95 | P0 | Secure Snippets status row, three states | SE §7.1 | Status row | specified |
| 96 | P1 | Key Storage row with Android copy | SE §7.1 | Android Keystore wording | specified |
| 97 | P0 | `Lock Now` | SE §7.1 | Action row | specified |
| 98 | P0 | `Add Recovery Key` when the vault has none | SE §7.1, §5 | Row, prompt, secret screen | specified |
| 99 | P0 | `Restore with Recovery Key`, typo-aware errors | SE §8.1 | Full-screen dialog with inline errors | specified |
| 100 | P0 | `Remove Secure Snippets from This Device`, blocked while sync is on | SE §8.2 | Destructive row and dialog | specified |
| 101 | P0 | Secure metadata editable without unlocking | SE §3, LE §6.7 | Same | specified |
| 102 | P1 | Capture-blocked and protected-display messages | SE §3.4, C §8 | `protected` panel state | adapted: triggered by the recording callback (API 35+) and unprotected displays; screenshots are blocked outright |
| 103 | N/A | Blocking third-party keyboards app-wide | SE §11 | Per-field hardening | not applicable: no Android API |

## Links, share, import, export

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 104 | P0 | Share an ordinary entry as a `snippets://share` link | LE §6.8 | `Share Link` through the Sharesheet | specified |
| 105 | P1 | Copy Share Link with toast `Copied share link.` | LE §2.3, §6.8 | Menu item; snackbar on API 28–32 | adapted: system overlay confirms on 33+ |
| 106 | P0 | Open `snippets://share` through a review dialog | SY §3 | `dialog/link-review` | specified |
| 107 | P0 | Open `snippets://new` through a review dialog | SY §3 | Same | specified |
| 108 | P0 | Review shows name, keyword, tags, 280-character preview | SY §3.2 | Labelled lines and a monospaced preview block | specified |
| 109 | P0 | Imported entries arrive disabled and open in the editor | SY §3.3 | Same | specified |
| 110 | P0 | Replacement called out, destructive | SY §3.2 | Warning paragraph; `Replace %s` in `error` | specified |
| 111 | P0 | Stale review refused | SY §3.3 | Error dialog | specified |
| 112 | P0 | Link error messages | SY §3.3 | `Couldn’t Open Link` dialogs | specified |
| 113 | P0 | Import JSON (array, wrapped, Raycast), merge by id then keyword | SD §8 | `ACTION_OPEN_DOCUMENT`, content detection | specified |
| 114 | P1 | Raycast `!` keyword choice | SD §8 | Three-button dialog | specified |
| 115 | P0 | Import size limits and errors | SD §8 | Error dialogs | specified |
| 116 | P0 | Export for Sharing: ordinary only, `Snippets-Export.json`, count toast | SD §9 | `ACTION_CREATE_DOCUMENT`, snackbar after writing | adapted: written straight to the document; past-tense message |
| 117 | P0 | Encrypted backup export with password rules | SD §10.1 | Full-screen dialog with two fields | specified |
| 118 | P0 | Encrypted backup import with all failure messages | SD §10.2 | Full-screen dialog; inline wrong-password error | specified |
| 119 | P0 | `.snippetsbackup` extension and MIME type | SD §10, SY §4 | Same; also opens from a file manager | specified |
| 120 | P1 | Progress toasts | SD §8, §10 | Progress snackbars | specified |
| 121 | P1 | Quarantined-library recovery with two confirmations | SD §11 | Two dialogs | specified |
| 122 | P1 | `Library Recovery Required` empty state | LE §2.4 | Empty state with `Import…` | specified |

## Settings

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 123 | P0 | Settings with `Library` and `Support` sections | SD §1 | Full-screen Settings; rows show live state | adapted: screen instead of sheet (D26); extra `General` section with Appearance (D27) |
| 124 | P1 | Settings search over the fixed catalog, ranking rules | SD §2 | Search field at the top | specified |
| 125 | P1 | Search result opens the pane and highlights the row | SD §2, C §12 | 700 ms highlight | specified |
| 126 | P0 | Sync pane: provider row, switch, Status, Sync Now or recovery row | SD §3 | Same rows plus a Background Sync fact | specified |
| 127 | P0 | Provider chooser with the current provider marked | SD §3.1 | Bottom sheet with a check on the current provider | adapted: shown in Cloud builds only; with one provider the row opens the Git screen |
| 128 | P0 | `Switch and Sync` confirmation with counts and destination | SD §5.1 | Dialog | specified |
| 129 | P0 | Switch progress and `Switch Needs Attention` | SD §5.2, §5.3 | Non-dismissable progress dialog with real steps | specified |
| 130 | P0 | Backup pane with three rows and footer | SD §7 | Same | specified |
| 131 | P1 | Diagnostics pane with three rows | SD §13 | Same | specified |
| 132 | P1 | Plaintext warning before export, Android field list | SD §13 | Notice on the row and in the export dialog | specified |
| 133 | P1 | Delete logs confirmation | SD §13 | Dialog | specified |
| 134 | P1 | Log retention limits | SD §13 | Same limits | specified |
| 135 | P0 | About: icon, name, version, GitHub and licence links | SD §14 | Same plus Open-Source Notices | specified |
| 136 | P1 | Two-column settings on tablets | SD §1.2 | List-detail scaffold, Sync preselected | specified |

## Git sync

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 137 | P0 | Git screen with intro and four fields | G §2 | Same form | specified |
| 138 | P0 | SSH address hides token fields, shows the key section | G §2, §3 | Same | specified |
| 139 | P0 | Host-specific token help and token link | G §2 | Same | specified |
| 140 | P0 | Device SSH public key with Copy, Share, deploy-key link | G §3 | Whole key shown, wrapped | specified |
| 141 | P0 | Host key confirmation, "matches published" variant | G §5 | Full-screen trust dialog | specified |
| 142 | P0 | Changed host key warning, never silent | G §5 | Error-styled screen with both fingerprints | specified |
| 143 | P0 | `Use Branch “snippets”` | G §4 | Dialog | specified |
| 144 | P0 | Create encrypted library; `Plain Text Instead…` with second confirmation | G §4 | Dialogs | specified |
| 145 | P0 | Public refusal; unknown-visibility confirmation | G §4 | Dialogs | specified |
| 146 | P0 | Recovery code shown once, monospaced, timed copy, hidden from recents, not dismissable by gesture | G §7, C §14 | Secret screen; back asks | specified |
| 147 | P0 | Join with the stored key or the code; wrong code re-prompts | G §4, §6 | Code-entry dialog keeps the text and shows the error | specified |
| 148 | P0 | Join plain-text consent | G §4 | Dialog | specified |
| 149 | P0 | Connected summary | G §8.1 | Summary card | specified |
| 150 | P0 | `Sync Now` / `Switch and Sync` | G §8.2 | Rows | specified |
| 151 | P0 | `Reconnect…`, `Reconnect and Merge` | G §8.2, §4 | Row and dialog | specified |
| 152 | P0 | `Set Up Secure Snippets…` with code entry | G §8.2, §6 | Row, steps, code entry | specified |
| 153 | P0 | `New Recovery Code…` with owner authentication | G §8.3 | Dialog, prompt, secret screen | specified |
| 154 | P0 | `Replace Keys…` with authentication and destructive confirmation | G §8.4 | Same | specified |
| 155 | P0 | `Change Address or Token…`; empty token keeps the saved one | G §8.2 | Unfolding form | specified |
| 156 | P0 | `Remove from This <device>…`, disabled while Git is active | G §8.2, §8.5 | `Remove from This Device…` | specified |
| 157 | P0 | Navigation locked while a step runs; status announced | G §1, C §13 | Back blocked; live step list | specified |
| 158 | P0 | Every setup failure message | G §9 | Field errors and problem cards for all 49 cases | specified |
| 159 | P0 | Round pacing 30 s / 120 s, push on background | G §11, SY §7 | Same | specified |
| 160 | P0 | Plain-text mode pinned; a changed mode stops sync | G §10, §11 | `git_library_mode_changed` card and `Reconnect…` | specified |
| 161 | N/A | macOS ssh-agent and known_hosts copy | — | — | not applicable: Mac only |

## Sync status

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 162 | P0 | Status sentence for every state | SD §4 | One generator | specified |
| 163 | P0 | Library sync banner with text and icon | LE §2.6, C §7.2 | First list row | specified |
| 164 | P0 | Banner becomes a button with a recovery action | C §7.3 | Review card with the action button | specified |
| 165 | P0 | First-fetch empty states | LE §2.4 | Same | specified |
| 166 | P0 | Halts with reason, guidance, typed action | SD §6 | Review card and Review screen | specified |
| 167 | P0 | Confirmation dialogs for deletions, account change, restore, take over | SD §6, C §15 | Review screen whose primary button is the confirmation | adapted: screen instead of alert (D23) |
| 168 | P0 | Deletion guard review | SD §6 | Same thresholds and sentence | specified |
| 169 | P0 | `Open Sync Settings` where there is no recovery action | C §7.3, LE §3 | Card button and menu item | specified |
| 170 | P0 | Conflict copies as disabled entries tagged `conflict` | SD §6, C §3.1, LE §5 | Same, plus a warning-styled pill and a filter shortcut (D33) | specified |
| 171 | P1 | Secure conflict waiting message | SD §4, C §7.3 | `Sync Is Waiting` card | specified |
| 172 | P1 | Background sync scheduling for Android | SY §7, SD §3 | WorkManager: push on background, 6-hour periodic | specified |
| 173 | N/A | iCloud provider, CloudKit halts, push-triggered sync | — | — | not applicable: Apple services |

## Snippets Cloud (flagged)

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 174 | P1 | Account screen with four sections | CL §2 | Sectioned list with a stage line | specified |
| 175 | P1 | Create account and Save Your Account Key | CL §3.1, §3.3 | Secret screen | specified |
| 176 | P1 | Sign in with account key, validation, rate limit | CL §3.2 | Full-screen dialog step | specified |
| 177 | P1 | Sign in with another device | CL §3.4 | QR, code, countdown, copy | specified |
| 178 | P1 | Unlock choices | CL §4 | Bottom sheet | specified |
| 179 | P1 | Pairing wait screen | CL §5 | Full-screen dialog | specified |
| 180 | P1 | Approve a device with code comparison and authentication | CL §8, §11 | Dialog with the code, then prompt | specified |
| 181 | P1 | Recovery kit: QR, code, copy, share, verify final 8 | CL §9 | Secret screen with two steps | specified |
| 182 | P1 | Recovery code entry with 52-character progress | CL §6 | Full-screen dialog | specified |
| 183 | P1 | Show account key after authentication | CL §10.3 | Prompt, secret screen | specified |
| 184 | P1 | Change account, change library, disconnect | CL §10.4–§10.6 | Dialogs | specified |
| 185 | P1 | Titled problem cards | CL §12 | Problem cards | specified |
| 186 | P2 | Print recovery kit | CL §9 | — | not applicable in v1: no print path (D41); listed in `open-questions.md` |

## Platform and quality

| # | Pri | Item | Where | Android presentation | Status |
|---|---|---|---|---|---|
| 187 | P0 | `Insert Snippet` with replace and read-only copy fallback | SY §1 | Sheet-styled activity | specified |
| 188 | P0 | Text action resolves placeholders and authenticates for secure results | SY §1.3 | Secure text returned directly after the prompt | specified |
| 189 | P0 | Phone and tablet layouts (two panes ≥ 840 dp) | D §4 | List-detail scaffold | specified |
| 190 | P1 | Tablet list: selection highlight, Enter copies, flat list, tag chips | LE §1.2, C §1.3 | Selected row, Enter copies, chip row | adapted: the `Pinned` header is kept (D35) |
| 191 | P1 | Tablet context menu extras | LE §4 | Disable/Enable, Make Secure/Ordinary, Copy Share Link | specified |
| 192 | P1 | Hardware keyboard shortcuts and shortcut panel | LE §8 | Ctrl shortcuts; system Keyboard Shortcuts Helper | adapted: system helper instead of a custom panel (D36) |
| 193 | P0 | Light and dark themes | D §5 | Full schemes | specified |
| 194 | P0 | Font scaling without clipped actions | D §4, §6 | Wrapping rules, verified at 1.0 / 1.3 / 2.0 | specified |
| 195 | P0 | TalkBack: row label, state, custom actions | C §1.5 | Same | specified |
| 196 | P0 | Toast: 3.5 s, longer with action and screen reader, single-use | C §17 | M3 snackbar: 4 s; 10 s or ≥ 20 s with an action | adapted: platform durations |
| 197 | P1 | Reduce-motion behaviour | D §9 | Fades and cuts | specified |
| 198 | P0 | Flush, lock and push on leaving the foreground | SY §7, D §11 | Same three steps | specified |
| 199 | P0 | Test launch mode with temporary storage and sync off | SY §8 | `ui-testing-reset` | specified |
| 200 | P1 | Demo seed and baseline profile | SY §8 | Same | specified |
| 201 | N/A | Liquid-glass materials, pointer hover, title-row geometry | — | — | not applicable: iOS visual system |
| 202 | N/A | Mac expansion, picker, clipboard history, CLI, usage ranking | — | — | not applicable: Mac features |
