# Snippets Android rebuild: UX and feature inventory

Reference for the design lead and Android engineers. Describes what the iPhone/iPad app does today (the parity target), what the old Android app did, and what the new Kotlin/Compose app must ship. Written 2026-11-25 from the sources at `66e7c7f`.

Strings in backticks are copied verbatim from code. `\(x)` is a Swift interpolation, `${x}` a Kotlin one. Apostrophes in the iOS copy are typographic (`’`), quotes are `“ ”`, ellipses are `…`.

File aliases used in pointers:

| Alias | File |
|---|---|
| PL | `snippets-ios/PhoneLibraryViewController.swift` |
| PR | `snippets-ios/PhoneRootViewController.swift` |
| PE | `snippets-ios/PhoneSnippetEditorViewController.swift` |
| PS | `snippets-ios/PhoneSwipeSupport.swift` |
| MS | `snippets-ios/MainSplitViewController.swift` (iPad root) |
| SL | `snippets-ios/SnippetListViewController.swift` (iPad sidebar list) |
| IE | `snippets-ios/SnippetEditorViewController.swift` (iPad editor) |
| SV | `snippets-ios/SettingsViewController.swift` |
| GV | `snippets-ios/GitSyncSettingsViewController.swift` |
| CK | `snippets-ios/CloudAccountKeySignInViewController.swift` |
| GS | `snippets/Sync/GitSyncSetup.swift` |
| SC | `snippets/Sync/SyncCoordinator.swift` |
| SF | `snippets/Core/SyncStateFile.swift` |
| BS | `snippets/Sync/SyncBackendSelectionStore.swift` |
| OA | `app/src/main/java/com/khm/snippets/android/MainActivity.kt` (old Android) |

---

## 1. Product model in one page

**What it is.** A personal library of short texts (links, passwords, API tokens, addresses, replies, notes). The Mac expands them by keyword in other apps; iPhone and iPad are lookup, copy and edit companions (`README.md:7-17`). Android is a companion of the iPhone kind, plus one Android-only route into other apps (the **Insert Snippet** text action).

**A snippet, as the user sees it** (`snippets/Core/Snippet.swift:12-21`):

| Field | What the user sees | Rules |
|---|---|---|
| Name | Title of the row and editor | Optional. When blank the first non-blank line of the content is shown, cut to 50 characters plus `…`; when that is empty too, `Untitled Snippet` (`Snippet.swift:53-59`, `491-499`). |
| Keyword | `\keyword` (backslash prefix is display only) | Optional. Sanitized as typed: trimmed, leading `\` removed, runs of whitespace become `-` (`Snippet.swift:65-77`). Compared case- and diacritic-insensitively. |
| Content | The body | Plain text, any length. May contain placeholders. |
| Tags | Coloured pills | Ordered list. Trimmed, inner whitespace collapsed to one space, deduplicated case/diacritic-insensitively keeping the first spelling (`Snippet.swift:395-413`). |
| Pinned | Pin glyph, `Pinned` section | Boolean. |
| Enabled | Dimmed row, `Disabled · ` prefix | Boolean. Controls keyword expansion on Mac only; a disabled snippet can still be copied on mobile. |
| Secure | Lock glyph, hidden body | Whether the body lives in the encrypted vault. |
| Updated | Time/date at the row's right edge, `Saved …` in the editor | Read-only. |

Created date exists but is only used for ordering.

**Ordinary vs secure.** An ordinary entry is readable local data. A secure entry keeps its name, keyword, tags, pin and enabled state readable ("the shell") and its body encrypted in the vault. Secure bodies never appear in list previews, search, placeholder preview, share links, plain export, duplication, or the accessibility tree (`README.md:181-208`, `docs/ios-secure-accessibility-protection.md`).

**Tap and copy.**
- iPhone: tapping a row copies it. Ordinary: placeholders are resolved, the result goes to the clipboard, a toast confirms. Secure: device-owner authentication on every copy, then a local-only clipboard item that expires after 60 seconds (`snippets-ios/SnippetActionService.swift:53`, `84-111`).
- iPad: tapping a row selects it and shows it in the editor; Return or the copy button copies.
- An entry whose resolved text is empty is not copied; the user is told so.

**Placeholders** (resolved on copy, `README.md:432-461`): `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{date:yyyy-MM-dd}`, `{date format="EEEE, MMMM d"}`, `{date locale="fr-FR"}`, `{date offset=+1d}`, `{datetime offset="+1d -2h"}`. Offset units `m h d M y`. `format` and `locale` are mutually exclusive; an offset may accompany either. Unknown placeholders stay literal. The editor shows a resolved preview for ordinary entries, with `{clipboard}` shown as `[Clipboard content]`.

**Sync providers** (one writable provider at a time; sync is opt-in and off by default):

| Provider | Apple apps | New Android app |
|---|---|---|
| Local only | Default | Default |
| iCloud | Opt-in | Not available (`snippets-android/docs/PLAN.md:16-17`) |
| Git repository (HTTPS token or SSH, encrypted or plain-text Markdown) | Opt-in | Yes |
| Snippets Cloud | Internal build flag | Internal build flag, off by default |

**Deliberately absent on mobile** (`README.md:480-482`, `SV:113-114`, `docs/android/app-plan.md:229-233`): system-wide `\keyword` expansion, the global paste picker, Secure Paste into other apps, clipboard history, the CLI and agent skill, usage ranking, launch-at-login, Sparkle updates, the Mac-only settings panes (General, Expansion, Clipboard History, Integrations). No custom keyboard, Accessibility service, overlay or background typed-text observer on Android. Third-party keyboards are blocked app-wide on iOS because of secure bodies (`snippets-ios/AppDelegate.swift:85-91`).

---

## 2. Information architecture

### 2.1 iPhone navigation tree

```
LIB  Library (root, large title "Snippets")
├─ LIB-MORE        "More" menu (ellipsis button beside the title)
│  ├─ New from Clipboard            → EDIT (new entry) or ALERT-CLIP-EMPTY
│  ├─ Transfer ▸ Import             → system file picker → IMPORT flow
│  │           ▸ Export for Sharing → system save picker
│  │           ▸ Encrypted Backup   → ALERT-BACKUP-NEW-PW → system save picker
│  ├─ <sync action>                 → Sync Now / Connect <provider> / Open Sync Settings / recovery
│  └─ Settings                      → SET (page sheet)
├─ LIB-FILTER      Tag filter sheet (bottom-left toolbar button; medium/large detents)
├─ LIB-SEARCH      Search field (bottom toolbar, centre)
├─ "+"             New snippet → EDIT (bottom-right toolbar button)
├─ Row tap         copy → TOAST-COPIED (secure: system auth prompt first)
├─ Row swipe right Edit → EDIT        Row swipe left: Pin/Unpin, Delete
├─ Row long-press  LIB-ROW-MENU (Copy, Edit, Pin/Unpin, Duplicate, Delete)
├─ Pull to refresh sync round, or ALERT-SYNC-OPT-IN, or recovery action
├─ LIB-SYNC-BANNER status pill at the top of the list (tappable when a recovery action exists)
└─ EDIT  Editor (pushed; bottom toolbar hidden)
   ├─ Segmented control "Content" | "Details" (floats above the keyboard)
   ├─ Copy button, EDIT-MORE menu (Pin/Unpin, Share, Duplicate, Delete)
   └─ Secure flows: SEC-RECOVERY-KEY, ALERT-MAKE-ORDINARY, system auth prompt

SET  Settings (sheet; "Done" closes)
├─ SET-SEARCH   "Search Settings"
├─ Library ▸ Sync             → SET-SYNC
│  │                            ├─ Cloud Provider → SHEET-PROVIDER → GIT / CLOUD
│  │                            └─ recovery row → ALERT-RECOVERY-CONFIRM
│  ├─ Secure Snippets          → SET-VAULT
│  └─ Backup                   → SET-BACKUP (closes Settings, then runs the file flow)
└─ Support ▸ Diagnostics       → SET-DIAG
            ▸ About            → SET-ABOUT
```

### 2.2 iPad layout

Two-column split view (`MS:80-85`): sidebar 28 % of the width, min 280 pt, max 500 pt, tiled beside the editor; collapses to a stack in compact width. Sidebar toggles with the system button or ⌘B.

- **Sidebar (`SL`)**: toolbar with `…` More menu and `+` add menu; search field (`Search`); wrapping tag chips with a `+N` / `Less` disclosure and a clear button; snippet list in one flat list (pinned first, no section header); floating toast.
- **Detail (`IE`)**: the editor for the selected snippet, or an empty state `Select a snippet` / `Choose a snippet from the sidebar or create a new one.` (`IE:341-342`). Navigation title is the snippet name; right side has the copy button and a `…` menu.
- **Shortcut panel (`SHORTCUTS`)**: overlay titled `Shortcuts`, toggled with ⌘K or More ▸ `Keyboard Shortcuts`.
- **Settings**: form sheet 900 × 700 with its own two-column split (sidebar 250–340 pt), `Sync` preselected (`SV:25-26`, `57-82`).

### 2.3 Screen, sheet, alert and toast IDs

| ID | Kind | Reached from | Leaves to |
|---|---|---|---|
| LIB | Screen | App launch | EDIT, SET, sheets below |
| LIB-MORE | Menu | LIB title-row button | see tree |
| LIB-FILTER | Sheet | LIB toolbar filter button | LIB (`Done`) |
| LIB-ROW-MENU | Context menu | Long-press on a row | action |
| LIB-EMPTY-* | Empty states | LIB with no rows | see 3.1 |
| LIB-SYNC-BANNER | Inline pill | LIB when sync is on or recovery is pending | recovery flow |
| EDIT | Screen | Row swipe/menu, `+`, links, duplicate | LIB (back) |
| EDIT-MORE | Menu | EDIT `…` | action |
| SEC-RECOVERY-KEY | Alert | First time a snippet is made secure; SET-VAULT `Add Recovery Key` | EDIT / SET-VAULT |
| SEC-RESTORE-KEY | Alert with field | SET-VAULT `Restore with Recovery Key` | SET-VAULT |
| ALERT-MAKE-ORDINARY | Alert | EDIT Secure switch off | EDIT |
| ALERT-DELETE-SECURE | Alert | Delete on a secure entry | LIB |
| ALERT-CLIP-EMPTY | Alert | New from Clipboard with nothing copied | LIB |
| ALERT-SYNC-OPT-IN | Alert | Pull to refresh with sync off | LIB |
| ALERT-RECOVERY-CONFIRM | Alert | Any recovery action that needs confirmation | LIB / SET-SYNC |
| LINK-REVIEW | Alert | Incoming `snippets://` link | EDIT or dismissed |
| IMPORT-RAYCAST | Alert | Import of a file with `!` keywords | import |
| IMPORT-QUARANTINE-JSON / -BACKUP | Alert | Import while the library is quarantined | LIB |
| ALERT-BACKUP-NEW-PW / ALERT-BACKUP-OPEN-PW | Alert with fields | Encrypted Backup / importing a backup | save picker / import |
| SET, SET-SEARCH | Sheet | LIB-MORE ▸ Settings | panes |
| SET-SYNC, SET-VAULT, SET-BACKUP, SET-DIAG, SET-ABOUT | Panes | SET | — |
| SHEET-PROVIDER | Action sheet | SET-SYNC `Cloud Provider` | GIT, CLOUD, switch alerts |
| ALERT-SWITCH, ALERT-SWITCH-PROGRESS, ALERT-SWITCH-ATTENTION | Alerts | Provider switch | SET-SYNC |
| GIT | Screen | SHEET-PROVIDER `Git Repository…` | SET-SYNC |
| GIT-MODE, GIT-PLAIN-CONFIRM, GIT-PUBLIC, GIT-VISIBILITY-UNKNOWN, GIT-FOREIGN-BRANCH, GIT-HOSTKEY-NEW / -PUBLISHED / -CHANGED, GIT-JOIN-PLAIN, GIT-REPLACEMENT, GIT-CODE-ENTRY, GIT-CODE-SHOW, GIT-NEW-CODE, GIT-REPLACE-KEYS, GIT-REMOVE | Alerts / sheet | GIT | GIT |
| CLOUD | Screen | SHEET-PROVIDER `Snippets Cloud…` | SET-SYNC |
| CLOUD-SIGNIN (choose / key entry / save key / other device), CLOUD-KEY-REVEAL, CLOUD-UNLOCK, CLOUD-PAIR-WAIT, CLOUD-SCAN, CLOUD-APPROVE, CLOUD-KIT, CLOUD-KIT-ENTRY, CLOUD-LIBRARY-CHOICE, CLOUD-DISCONNECT | Sheets / alerts | CLOUD | CLOUD |
| SHORTCUTS | Overlay (iPad) | ⌘K | — |
| PROCESS-TEXT | Dialog activity (Android only) | Text selection menu `Insert Snippet` | calling app |
| TOAST-* | Toast | many | auto-dismiss |

---

## 3. Screen-by-screen spec

### 3.1 LIB — iPhone library

**Purpose.** Find an entry and copy it with one tap; reach everything else.

**Chrome** (`PL:82-108`, `233-245`, `349-390`; screenshot `docs/images/iphone-library-dark.png`)
- Large title `Snippets` (`PL:84`); collapses to a compact title on scroll.
- One navigation action, a circular ellipsis button on the title row: accessibility label `More` (`PL:53`). It follows the lower edge of the navigation bar as the title collapses.
- Floating bottom toolbar, left to right: tag filter button, search field, `+`.
  - Filter: outlined funnel icon; filled icon plus a visible count when filters are active (`PL:511-527`). Label `Filter by tags`, hint `Shows the available tag filters`, value `No active filters` / `\(count) active filter(s)` (`PL:361-362`, `524-525`).
  - Search placeholder `Search snippets` (`PL:236`).
  - `+` creates a blank entry and opens the editor with the body focused (`PR:77-92`). A blank draft is reused instead of creating a second one, and is discarded when the editor is left still blank (`PE` `viewDidDisappear`, `discardBlankDraft`).
- List: inset rows with hairline separators drawn by the row, 18 pt side inset, estimated row height 96 pt, keyboard dismisses on drag (`PL:392-415`).

**More menu, in order** (`PL:247-303`)
1. `New from Clipboard`
2. `Transfer` submenu: `Import`, `Export for Sharing`, `Encrypted Backup`
3. Sync action, title depends on state: the recovery action's title (see section 10) / `Open Sync Settings` / `Sync Now` / `Connect \(providerName)`
4. `Settings`

**Row** (`PL:1281-1338`)
- Line 1: name (17 pt semibold, one line) and, right-aligned, the updated time: time of day today, `Yesterday`, abbreviated weekday within six days, otherwise abbreviated month and day (`PL:1750-1763`).
- Status glyphs on the title line: lock (secure, orange), pin (pinned, indigo), pause circle (disabled). Hidden when none apply (`PL:977-979`, `1093-1094`).
- Line 2 (15 pt, secondary, up to two lines), `PL:1297-1305`:
  - secure with keyword: `Secure · \keyword`; secure without: `Secure snippet`
  - ordinary with keyword and content: `\keyword · <first line>`
  - ordinary with only one of them: that one; neither: `No content`
  - disabled entries prefix everything with `Disabled · ` and use dimmer text colours.
- Line 3: up to three tag pills (11 pt medium, coloured text on a 13 % fill of the same colour), then `+N` for the rest (`PL:987`, `1320`). At accessibility text sizes the layout stacks.

**Sections** (`PL:183-193`): `Pinned` header over pinned matches, then the rest with no header. No header at all when nothing is pinned.

**States**

| State | What shows | Source |
|---|---|---|
| Empty, sync off | Title `Bring Your Library to iPhone`; message `Connect \(providerName) to fetch the library from your other devices.`; prominent button `Connect \(providerName)` | `PL:1916-1921` |
| Empty, sync on and has synced | Title `Your Library Is Empty`; message `\(syncStatus) You can also create a snippet on this device.`; no button | `PL:1916-1919` |
| Empty, first fetch running | Title `Fetching Your Library`; message `Checking \(providerName) for the library from your other devices.` or `Preparing the first \(providerName) fetch. Your local library will stay empty until it finishes.`; no button | `PL:601-603`, `1935` |
| Empty, first fetch stalled | Title `Library Hasn’t Been Fetched`; message `The first fetch has not finished. \(statusDescription)`; button = recovery title, `Open Sync Settings`, or `Try Again` | `PL:556`, `605`, `1935` |
| Library quarantined | Title `Library Recovery Required`; message `The ordinary snippet library could not be read and remains preserved. Import a complete Snippets JSON export, then review Sync and choose Check Again. \(syncStatus)`; no button | `PL:1947-1950` |
| Search, no match | Title `No Results`; message `Try a different search.` or, with filters, `Try changing the search or clearing a tag filter.` plus button `Clear Filters` | `PL:570-575`, `1849` |
| Filters, no match | Title `No Snippets Match`; message `Clear a tag filter to see more snippets.`; button `Clear Filters` | `PL:578-581` |
| Sync on | LIB-SYNC-BANNER at the top of the list (section 10.2) | `PL:611-627` |

While an empty state shows, the list does not scroll (so the large title cannot collapse over a static screen); the empty view has its own scroller for large text (`PL:535-540`). Clearing filters announces `Tag filters cleared` (`PL:507`).

**Gestures and actions**

| Gesture | Result | Source |
|---|---|---|
| Tap row | Copy. With a swipe open elsewhere, the first tap only closes that swipe. | `PL:850-859` |
| Swipe right (leading) | Reveals `Edit` (indigo). A long or fast swipe past `max(52 % of row width, action width + 44 pt)` arms the action (button grows 6 %, rigid haptic 0.8; 0.45 when disarmed) and releasing opens the editor immediately, without waiting for the row animation. | `PL:1049`, `1586-1612`, `1658-1667`; `PS:18-24`, `49-73` |
| Swipe left (trailing) | Reveals `Pin`/`Unpin` (indigo) and `Delete` (red). No full-swipe action: Delete always needs a tap. | `PL:1056-1063`, `1285` |
| Swipe mechanics | Custom, not the system swipe: rubber-band resistance 0.55 beyond the limits, 0.18 s velocity projection, opens when the projected offset passes half the action width, one open row at a time, closes on scroll or on any tap. Buttons fade in and slide 12 pt as they appear. Reduce Motion removes the arming animation. | `PS:16-17`, `26-73`; `PL:717-721`, `1626-1656` |
| Long-press | Menu in this order: `Copy` (Face ID glyph when secure), `Edit`, `Pin`/`Unpin`, `Duplicate` (ordinary only), `Delete` (destructive). | `PL:737-767` |
| Pull to refresh | Recovery action pending: runs it (with confirmation when required). Sync off: ALERT-SYNC-OPT-IN. Otherwise a manual sync round; the spinner ends when the round ends. | `PL:650-673` |
| Tap sync banner | Runs the recovery action when one exists; otherwise not interactive. | `PL:2262-2274` |

iPhone has no multi-select, no drag reordering and no keyboard shortcuts.

**ALERT-SYNC-OPT-IN** (`PL:683-688`): title `Turn On \(providerName) Sync?`; message `Pull to refresh uses \(providerName). Snippets encrypts records before uploading them, and you can turn sync off later in Settings.`; buttons `Not Now`, `Turn On`.

**Feedback**
- Copy: toast `Copied “\(name)”.`, for secure entries `Copied “\(name)”. Secure clipboard expires in 60 seconds.`; soft haptic 0.75 (`PL:213-216`).
- Nothing to copy: toast `“\(name)” has no content to copy.`; soft haptic 0.5 (`PL:218-220`).
- First successful copy ever: 2.4 s later a one-time 5 s toast `Tip: swipe right to edit. Swipe left to pin or delete.` (`PL:723-734`).
- Pin toggle: soft haptic 0.5 (`PR:136`). Delete: warning notification haptic (`PR:156`).
- Background sync state changes never produce haptics (`PL:625-626`).

**Accessibility** (`PL:813-846`, `1326-1337`)
- Each row is one button. Label = name. Value = comma-joined `Secure`/`Standard`, `Pinned`, `Enabled`/`Disabled`, `Keyword \keyword`, `Tags: a, b`. Hint `Double tap to copy` or `Double tap to authenticate and copy`.
- Custom actions on every row: `Copy`, `Edit`, `Pin`/`Unpin`, `Delete` (the swipe actions must stay reachable without gestures).
- Sync banner: label `Sync`, value = status text, with `Action: \(buttonTitle).` when a recovery action exists; hint `Double-tap to \(buttonTitle)` or `Details are available in Settings` (`PL:2236-2248`).

### 3.2 LIB-FILTER — tag filter sheet

(`PL:2003-2089`) Bottom sheet with medium and large detents and a grabber.
- Title `Filter by Tags`, or `Filter by Tags (\(count))` when filters are active.
- Leading `Clear` (disabled with no filters; hint `Removes every active tag filter`), trailing `Done`.
- One row per tag: coloured tag icon, tag name, usage count at the right, checkmark when active. Tapping toggles and applies immediately; the library behind updates live.
- Footer `A snippet must match every selected tag.`
- No tags: icon, `No Tags Yet`, `Add tags to a snippet, then return here to filter your library.`
- Row accessibility: value `\(count) snippet(s), selected|not selected`, hint `Double tap to remove|apply this filter`.

### 3.3 EDIT — iPhone editor

**Purpose.** View and change one entry. There is no Save button: every change is stored as it is typed.

**Chrome** (`PE:92-100`, `797-829`; screenshot `docs/images/iphone-editor-dark.png`)
- Compact title = the entry's display name. Back returns to the library.
- Right side: copy button (two-documents glyph; open-lock glyph when secure; label `Copy` or `Authenticate and Copy`) and `…` menu: `Pin`/`Unpin`, `Share` and `Duplicate` (ordinary only), `Delete` (destructive).
- A two-segment control `Content` | `Details` (`PE:14`) is pinned 8 pt above the keyboard, or above the bottom edge when there is no keyboard; 70 % of the width, at most 320 pt. Switching slides the panes horizontally (0.32 s spring); Reduce Motion swaps them instantly (`PE:658-705`).
- Grouped background; each field is a rounded surface under a small grey caption.

**Content pane** (`PE:283-286`)
- `Name`: single line. Placeholder `First line is used when blank`; when the name is blank the placeholder becomes the first line of the content, or `Untitled Snippet` (`PE:837-843`). Return moves focus to the body.
- `Snippet`: multi-line monospaced body, placeholder `Paste or type` (`PE:408`). Smart quotes and smart dashes are off.
- `Preview Placeholders`: a disclosure row shown only when the body contains a resolvable placeholder and the entry is ordinary. Collapsed by default; expanded it shows the resolved text in a muted monospaced box, with `{clipboard}` rendered as `[Clipboard content]` (`PE:499-527`, `846-869`).
- Footer status line (12 pt): `Saved \(date, abbreviated) at \(time)` for ordinary entries; secure states in section 6.4 (`PE:786-793`).

**Details pane** (`PE:295-311`)
- `Keyword`: field with a fixed `\` prefix, placeholder `sig`, no autocapitalisation, autocorrect or spell check. Return moves to Tags.
- `Tags`: token field, placeholder `work, email` (section 5.3).
- `Enabled` switch with detail `Allow this keyword to expand on Mac.` (hint `Controls whether this keyword can expand on Mac.`)
- `Secure` switch with detail `Encrypt the body and require device-owner authentication to reveal or copy it.` (hint `Moves the content between the encrypted vault and the ordinary library.`)

**Keyword warnings** (`PE:872-906`). One at a time, evaluated in this order:

| Condition | Message |
|---|---|
| No keyword | `Add a keyword to make this available for expansion on Mac.` |
| Disabled | `Disabled — \keyword won’t expand.` |
| Keyword contains a multi-scalar character (emoji, combined glyph) | `\keyword needs letters, digits, or hyphens.` |
| Same keyword on another enabled entry (ordinary or secure) | `\keyword is already used by \(other name).` |
| Another enabled keyword starts with this one | `\keyword is blocked by \other.` |
| This keyword starts with another enabled keyword | `This prevents \other from expanding.` |

The warning shows as an orange triangle inside the keyword field, hidden while the field has focus. Tapping it opens an alert titled `Keyword Warning` with the message and `OK` (`PE:920-930`). The button's label is `Keyword warning: \(message)`. Warnings never block saving.

**Keyword help while typing** (`PE:932-1003`), shown in a floating strip under the field only while it has focus:
- Keyword empty: up to three suggestion chips `\abc`, derived from the name and first content line and filtered to those that do not collide with an enabled keyword. Tapping one fills the field.
- Keyword non-empty: one read-only line `Existing · \a  ·  \b  ·  +N more` listing up to eight existing keywords that match what is typed (label `Existing keywords: …`, hint `Space or Tab completes the next unambiguous keyword part.`).
- The Space key in the keyword field never inserts a space. At the end of the field it completes the common continuation of matching keywords up to the next `.` or `-`; otherwise it does nothing (`PE:1760-1778`). A hardware Tab does the same (`PE:126-155`).

**Saving** (`PE:1005-1041`, `1368-1400`)
- Ordinary: each keystroke updates the store. Edits between focus and blur form one undo step.
- Secure metadata (name, keyword, tags, enabled) saves the same way; the secure body saves 0.3 s after the last keystroke and again on blur, on leaving the screen and when the vault locks.
- Failure: the footer turns red with `Couldn’t save: \(error)` or `Secure edit wasn’t saved: \(error)`, is scrolled into view above the keyboard and announced.
- Remote changes to the entry on screen are applied field by field without moving the caret (`PE:176-210`).

**Menu actions**
- `Share`: system share sheet with the `snippets://share?data=…` link (`PE:1480-1487`).
- `Duplicate`: opens the copy in a new editor (rules in 4.6).
- `Delete`: ordinary entries are deleted at once, the editor closes and the library shows the Undo toast; secure entries ask first (ALERT-DELETE-SECURE).
- Copy feedback appears in the footer, not as a toast: `Copied “\(name)”.`, `Copied “\(name)”. Secure clipboard expires in 60 seconds.`, `“\(name)” has no content to copy.` (`PE:1448-1452`).

### 3.4 iPad sidebar list (`SL`)

Differences from the iPhone library that matter for the Android tablet layout:

- **Selection model.** Tap selects and shows the entry in the editor. Return copies the selected entry (authenticating when secure). The selected row has a tinted highlight (indigo at 13 % in light, white at 14 % in dark); pointer hover has a fainter one.
- **Row** (`SL:716-747`): status dot at the left (yellow pin when pinned; hollow orange circle when enabled with no keyword; filled green when enabled; grey when disabled); name; second line = first content line, shown only when the entry has a name, or `••••••••` for secure entries; at the right up to six coloured tag dots with `+N`, and the keyword `\keyword` or `No keyword` (orange when enabled without a keyword).
- **Tag chips** above the list instead of a sheet: one chip per tag, tap toggles, AND semantics, collapsed to a few rows with `+N` / `Less`, plus a clear button (label `Clear tag filters`). Chip label: `Filter by tag \(tag), on|off, \(count) snippet(s)` (`snippets-ios/SidebarPresentationViews.swift:35`, `67`, `199`).
- **No sections**: pinned entries sort first in one flat list.
- **Toolbar** (`SL:216-270`): `+` menu with `New Snippet`, `New from Clipboard`; `…` menu with `Import`, `Export for Sharing`, `Encrypted Backup (Includes Secure Snippets)`, the sync action (subtitle = the full status sentence), `Keyboard Shortcuts`, `Settings`.
- **Context menu** (`SL:453-488`): `Pin`/`Unpin`, `Disable`/`Enable`, `Make Secure`/`Make Ordinary`, `Copy`, `Copy Share Link` and `Duplicate` (ordinary only), `Delete`.
- **Swipe**: system trailing swipe with `Delete` only (`SL:584-592`).
- **Delete always confirms** on iPad (`MS:523-532`): title `Delete “\(name)” ?`; message `You can undo deletion of an ordinary snippet until the app closes.` (ordinary) or the secure message; buttons `Cancel`, `Delete`. Undo is ⌘Z rather than a toast.
- **Empty states** (`SL:379-405`): `Your snippet library is empty` / `Create a snippet, start from the clipboard, or import an existing library.` with buttons `New Snippet`, `New from Clipboard`, `Import…`; `No results for “\(query)”` / `Try a different search.` or `Try clearing a tag filter.`; `No snippets match these tags` / `Clear a filter to see more snippets.`; quarantine: `Library Recovery Required` with an import button only.
- **Toasts**: `Copied share link.`, `Couldn’t copy link: \(error)`, `Couldn’t update pin: \(error)`, `Couldn’t update snippet: \(error)`, `Syncing…`, `Connecting…` (`SL:253-256`, `422-449`).
- Duplicating a secure entry by shortcut shows an alert `Secure Snippet` / `Secure snippets cannot be duplicated because that would create another plaintext disclosure path.` (`MS:554`).

### 3.5 iPad editor (`IE`)

One scrolling form, no Content/Details split. Order (`IE:368-382`): `Snippet` (body, with a lock toggle button at the right of the caption), `Keyword`, `Name`, `Tags`, an `Enabled` checkbox, a `Preview` section when placeholders exist, then the footer date. The `…` menu adds `Copy Share Link` to the iPhone's list (`IE:813-823`). Lock button label `Make Secure` / `Make Ordinary`, value `Ordinary` / `Secure`. The keyword warning also has a tooltip on hover (`IE:686`). Secure footer copy differs by one word: `Content is encrypted and hidden. Metadata remains searchable.` (`IE:938`).

### 3.6 SHORTCUTS — iPad shortcut panel and key commands

Panel title `Shortcuts`; footer `Hold ⌥ for all shortcuts.` / `Release ⌥ for essentials.`; backdrop label `Dismiss Shortcuts` (`snippets-ios/ShortcutPanelView.swift:128-178`).

| Shortcut | Panel title | Essential |
|---|---|---|
| `\keyword` | `Expand a Snippet` (informational: Mac) | yes |
| `{` | `Insert a Placeholder` (informational) | yes |
| ↩ | `Copy Snippet` | yes |
| ⌘F | `Search` | yes |
| ⌘B | `Toggle Sidebar` | yes |
| ⌘N | `Create New Snippet` | yes |
| ⇧⌘N | `New from Clipboard` | yes |
| ⌘E | `Edit Snippet` | yes |
| ⌘⌫ | `Delete Snippet` | yes |
| ⇥ / ⇧⇥ | `Next Field` / `Previous Field` | yes |
| esc | `Return to Snippet List` | yes |
| ⇧⌘I / ⇧⌘E | `Import` / `Export` | no |
| ⌘Z / ⇧⌘Z | `Undo` / `Redo` | no |
| ↓ or ⌃N / ↑ or ⌃P | `Next Snippet` / `Previous Snippet` | no |
| ⌘K | `Toggle Shortcuts` | no |

Escape in the search field keeps the query and moves focus to the list (`snippets-ios-uitests/SnippetsIOSUITests.swift`, `testEscapeKeepsSearchQueryWhileMovingFocusToSnippetList`).

### 3.7 Shared alerts

**ALERT-DELETE-SECURE** (`PR:165-170`): title `Delete “\(name)”?`; message `This permanently removes the encrypted snippet from this device and, when sync is on, from your other devices.`; `Cancel`, `Delete` (destructive). Afterwards toast `Secure snippet deleted.` No undo.

**ALERT-CLIP-EMPTY** (`PR:95`): `Clipboard Is Empty` / `Copy some text, then try again.` / `OK`.

**Error alerts** all use one `OK` button and the error's own description. Titles: `Couldn’t Copy Snippet`, `Couldn’t Update Pin`, `Couldn’t Delete Snippet`, `Couldn’t Open Link`, `Couldn’t Export Snippets`, `Couldn’t Create Encrypted Backup`, `Couldn’t Import Snippets`, `Couldn’t Import Encrypted Backup`, `Couldn’t Recover Library`, `Library Recovery Required` (`PR:54-444`); editor: `Couldn’t Set Up Secure Snippets`, `Couldn’t Make Snippet Secure`, `Couldn’t Make Snippet Ordinary`, `Couldn’t Reveal Secure Content` (`PE:1074-1198`). Copy errors: `The snippet no longer exists.`, `The secure snippet does not contain valid text.` (`SnippetActionService.swift:46-48`).

### 3.8 Toast (shared component)

(`snippets-ios/AppToastPresenter.swift`) A rounded, lightly tinted floating pill centred 12 pt above the bottom safe area, at most the screen width minus 32 pt. Multi-line 14 pt medium text with an optional action button underneath (at least 44 pt tall).
- Default duration 3.5 s. With an action: at least 8 s, or 20 s when a screen reader is running.
- A new toast replaces the current one.
- The action runs at most once; it is cleared before the callback runs.
- Announced to assistive technology as `\(message)` or `\(message) \(action) available.`
- Does not take focus and does not block touches outside itself.

---

## 4. Library behaviours

### 4.1 Order

`pinned first → newest created first → id` (`Snippet.swift:88-101`). Editing an entry does not move it; pinning does. Ordinary and secure entries are interleaved in one list. Search and tag filters keep this order: there is no relevance ranking (`docs/library-search-performance.md:22-26`).

### 4.2 Search

- Matches names, keywords, tags and ordinary content. Case- and diacritic-insensitive.
- Name, keyword and tags accept a fuzzy subsequence: `prjal` finds `Project Alpha`.
- Content needs a contiguous substring. The first content line of an unnamed entry is not fuzzy metadata.
- Secure entries match on name, keyword and tags only, even while a secure editor is unlocked.
- Results update as the user types, off the main thread; stale results are dropped (`PL:160-181`).
- Search and tag filters combine with AND.
- Accepting an incoming link clears the query and the filters before opening the new entry (`PL:204-209`).

### 4.3 Tag filters

- A snippet must carry every selected tag (AND).
- Tag identity ignores case and diacritics, folded with a fixed locale so Turkish `I` does not drift (`Snippet.swift:415-430`). The first spelling seen is the display name.
- Tags list alphabetically, case-insensitively, each with the number of entries carrying it, counted over the whole library including secure entries (`snippets/Core/SnippetSearchIndex.swift:22-34`).
- Filters for tags that no longer exist are dropped silently on reload (`PL:139-140`).
- The filter is not persisted across launches.
- Tag colour: FNV-1a 64-bit hash of the folded tag, modulo a 12-colour palette, so a tag has the same colour slot on every platform (`snippets-ios/AppTheme.swift:27-45`, `148-155`).

### 4.4 Copy

Section 1 and 3.1. Additional rules:
- Placeholders resolve at copy time; `{clipboard}` reads the clipboard at that moment.
- Secure copy prompt reason: `Copy \(name)` (`SnippetActionService.swift:99`). A cancelled or failed prompt throws, so the user gets the alert `Couldn’t Copy Snippet` with `authentication was cancelled` or `authentication was not approved` (`snippets/Vault/KeychainSecretStore.swift:105`, `snippets/Vault/VaultSession.swift:246`). See Open questions.
- Secure clipboard item: marked local-only (not shared to other devices) and expiring 60 s later.
- Disabled entries can be copied.

### 4.5 Delete and undo

- iPhone, ordinary: immediate delete, toast `Deleted “\(name)”.` with `Undo` (`PR:155-160`). Undo restores exactly that entry in its original position without reverting anything done in between; it works once (`snippets-ios-tests/DeletionUndoTests.swift`).
- Secure: confirmation, no undo.
- iPad: confirmation for both kinds; ordinary deletions can be undone with ⌘Z until the app closes.
- Deleting from the editor closes the editor first.

### 4.6 Duplicate

(`snippets/SnippetStore.swift:782-804`) Ordinary entries only.
- Name becomes `<name> Copy`; a blank name stays blank.
- Keyword, content, tags and pin are copied.
- The copy is created **disabled** when the source was enabled and has a keyword, so two enabled entries never share a keyword.
- It is inserted directly after the source and opens in the editor.

### 4.7 Share and share links

- `Share` (iPhone and iPad editor menus) opens the system share sheet with a `snippets://share?data=<base64url JSON>` link carrying name, keyword, content and tags (`snippets/Core/SnippetDeepLink.swift:83-112`).
- `Copy Share Link` (iPad only) puts the same link on the clipboard; toast `Copied share link.`
- Secure entries cannot be shared: `Secure snippets cannot be shared. A share link carries the snippet's text in plain sight.` (`SnippetDeepLink.swift:28`). The menu items are simply absent.

### 4.8 Receiving links (LINK-REVIEW)

Two forms (`SnippetDeepLink.swift:33-67`, `163-184`):
- `snippets://share?data=…` round-trips a whole entry.
- `snippets://new?name=…&keyword=…&content=…&tags=a,b` is hand-writable; every field is optional but at least one of name, keyword or content must be present.

Nothing is written until the user accepts a review alert (`snippets-ios/IncomingSnippetLinkCoordinator.swift:44-51`, `184-207`). Any open sheet is dismissed first.

| Case | Title | Accept button |
|---|---|---|
| Creation link | `Create Snippet From Link?` | `Create Disabled` |
| Share link, no match | `Import Shared Snippet?` | `Import Disabled` |
| Share link matching an existing entry by id, or by keyword | `Replace Existing Snippet?` | `Replace \(existing name)` (destructive) |

Message paragraphs, separated by blank lines:
1. Replacement only: `This will permanently replace “\(name)”. Review the incoming content before continuing.`
2. `Name: \(name)` / `Keyword: \keyword` or `No keyword` / `Tags: a, b` or `None` / blank line / `Preview:` / the trimmed content cut to 280 characters plus `…`, or `(empty content)`.
3. `The snippet will be created disabled. Review it in the editor before enabling expansion.` or `The imported snippet will stay disabled until you review and enable it.`

On accept the entry is stored disabled and opened in the editor. If the library changed while the alert was open, the import is refused: `Your library changed while this link was open. Review the link again before importing it.` Link errors (title `Couldn’t Open Link`): `This link is not a supported Snippets share link.`, `This share link is missing snippet data.`, `This share link is malformed or corrupted.`, `This share link was created by a newer version of Snippets.` (`SnippetDeepLink.swift:17-24`).

### 4.9 Create from clipboard

More ▸ `New from Clipboard` (⇧⌘N on iPad). Creates an entry whose content is the clipboard text and opens the editor with the body focused. Whitespace-only or empty clipboard: ALERT-CLIP-EMPTY.

### 4.10 Badges and conflict copies

| Signal | iPhone | iPad |
|---|---|---|
| Pinned | Pin glyph, `Pinned` section | Yellow pin dot, sorted first |
| Secure | Lock glyph, `Secure · …` detail | `••••••••` preview |
| Disabled | Pause glyph, `Disabled · ` prefix, dimmed text | Grey dot, dimmed text |
| No keyword | — | Hollow orange dot, orange `No keyword` |
| Conflict copy | No dedicated badge | No dedicated badge |

A conflict copy is an ordinary, disabled entry created by sync when two devices changed the same body. It is named `\(name) (conflict \(date))` and carries the tag `conflict` (`snippets/Core/SyncMerge.swift:449`, `463`). The user finds it by that tag and resolves it by hand.

---

## 5. Editor behaviours

### 5.1 Fields and focus order

iPhone: Name → (Return) body; Keyword → (Return) Tags; the tag field's Return key is `Done`. iPad: Tab and Shift-Tab walk the editor fields (form order: body, keyword, name, tags; exact loop not verified, see `MS:280-295`); Escape returns to the list. A new entry opens with the body focused; a secure entry does not take focus until it is revealed (`PE:213-217`).

### 5.2 Keyword field

Section 3.3. Summary of rules to port:
- Sanitised on every change (`PE:1009-1010`): the visible text is rewritten to the sanitised form, so a typed space cannot survive.
- Suggestions (`snippets/Core/KeywordSuggestions.swift:119-150`): from the first word of the name (whole when ≤ 6 letters, otherwise its first 4 and first 3 letters), the initials of a multi-word name (up to 5), and the first real word of the first content line (skipping `http`, `https`, `www`). Minimum length 2, lower-case ASCII letters and digits only, de-duplicated, best first; the editor shows at most 3 and hides any that collide with an enabled keyword. For a secure entry the content line is not used.
- Existing-keyword references (`KeywordSuggestions.swift:55-71`, `209-222`): ranked exact, prefix, dot-component match, component prefix, substring, then order-independent dot components.
- Completion (`KeywordSuggestions.swift:86-114`): only extends what was typed, by the common continuation of all matching keywords, stopping after the next `.` or `-`.
- Warnings: table in 3.3.

### 5.3 Tag token field

(`snippets-ios/TagTokenField.swift`)
- Tags render as coloured tokens inside the field, each with an `×` (label `Remove tag \(tag)`), followed by the text input with placeholder `work, email`. The whole strip scrolls horizontally.
- A comma or a newline commits the pending text; pasted text with commas becomes several tags. Leaving the field commits too.
- Return accepts the first completion when one exists, otherwise commits the text.
- Backspace in an empty input removes the last tag.
- While typing, up to 8 completion chips appear in the same strip: existing library tags whose folded form starts with the typed text and which are not already on the entry (label `Complete tag \(tag)`).
- Tags are normalised and de-duplicated on commit (section 1).

### 5.4 Placeholder preview

Only for ordinary entries, only when the body has a resolvable placeholder. iPhone: a collapsed `Preview Placeholders` disclosure. iPad: an always-visible `Preview` section. Uses the real date and time and the fixed text `[Clipboard content]`. For secure entries the preview is removed entirely and must never receive the body (`PE:846-858`).

### 5.5 Secure toggle, both directions

**Ordinary → secure** (`PE:1063-1110`)
1. Keyboard dismissed, pending edits flushed.
2. No vault yet: the app prepares one and shows SEC-RECOVERY-KEY (section 6.2). Cancel aborts and nothing changes.
3. System authentication prompt with reason `Make this snippet secure`.
4. The entry moves into the vault as one transaction; the editor rebinds and shows the locked overlay.
5. Errors: `Couldn’t Set Up Secure Snippets`, `Couldn’t Make Snippet Secure`.

**Secure → ordinary** (`PE:1112-1143`)
1. ALERT-MAKE-ORDINARY: title `Make This Snippet Ordinary?`; message `Its content will be decrypted into the ordinary library, where it can be copied, shared, and exported.`; `Cancel`, `Make Ordinary` (destructive).
2. One-use authentication with reason `Make this secure snippet ordinary`.
3. The body is decrypted into the ordinary library. Error title `Couldn’t Make Snippet Ordinary`.

The switch snaps back to the real state at once and only changes after the move succeeds (`PE:1053-1061`).

### 5.6 Saving, discarding, restoring

- Autosave only. No Save or Cancel, no unsaved-changes prompt.
- A blank new entry is thrown away when the editor is left (`PE:118-124`).
- Leaving the editor locks a revealed secure body and flushes pending edits (`PE:107-116`).
- The app does not restore the open editor or the search after a cold start: it opens on the library. The UI tests launch with `--ui-testing-reset`, which redirects storage to a temporary folder and disables sync (`snippets-ios/AppEnvironment.swift:53-100`); the Android app needs an equivalent test launch mode.
- Going to the background flushes writes, locks the vault and pushes a waiting Git change (`AppEnvironment.swift:242-261`).

---

## 6. Secure snippets UX

### 6.1 Concepts the user meets

| Thing | What it is | Where it is shown |
|---|---|---|
| Vault | Encrypted store for secure bodies, one key | SET-VAULT |
| Recovery key (vault) | Offline key that can restore the vault key | SEC-RECOVERY-KEY, once |
| Git recovery code | Opens a Git library, including its secure snippets, on a new device | GIT-CODE-SHOW, once |
| Snippets Cloud account key / recovery kit | Cloud-only (section 9) | CLOUD screens |

These are four different secrets with four different names; the copy never mixes them.

### 6.2 Vault setup (SEC-RECOVERY-KEY)

There is no separate setup screen. The vault is created the first time a snippet is made secure. Alert (`PE:1152-1161`): title `Save Your Recovery Key`; message `Store this somewhere safe. It is the only way to recover secure snippets if the shared Keychain key is lost.` followed by a blank line and the key; buttons `Copy & Continue`, `I’ve Saved It`, `Cancel`.
- `Copy & Continue` copies the key as a local-only clipboard item that expires after 5 minutes (`snippets-ios/SecureUIKit.swift:1236-1254`), then continues.
- `Cancel` discards the prepared vault; the snippet stays ordinary.
- While Git is the provider the vault belongs to the Git library and is never minted here; the user is sent to the Git screen: `secure snippets are not set up for your Git library on this device yet. Open Sync settings, then the Git repository, and choose Set Up Secure Snippets. If it isn’t offered there, finish connecting the repository first.` (`snippets/Vault/SecureSnippetStore.swift:61-63`).

### 6.3 Authentication prompts

System device-owner authentication (biometrics with device passcode fallback). Reasons, verbatim:

| Moment | Reason | Kind |
|---|---|---|
| Copy a secure entry | `Copy \(name)` | every time |
| Reveal in the editor | `Reveal “\(name)”` | opens a session |
| Make secure | `Make this snippet secure` | opens a session |
| Make ordinary | `Make this secure snippet ordinary` | every time |
| Add recovery key | `Create and display a recovery key` | every time |
| Encrypted backup export | `Export an encrypted backup including secure snippets` | every time |
| Encrypted backup import | `Import secure snippets from an encrypted backup` | every time |
| Git: new recovery code / replace keys | `Create a new recovery code for your Git library` / `Replace the keys of your Git library` | every time |

(`SnippetActionService.swift:99`; `PE:1082`, `1127`, `1178`; `SV:1508`; `SecureSnippetStore.swift:1483`, `1574`; `GS:459-460`.)

### 6.4 Reveal in the editor

- Locked: the body area shows a lock icon and a button `Reveal Secure Content`; while the prompt is up the button shows a spinner and `Authenticating…` (`PE:419`, `751-752`).
- Revealed: the body is visible and editable. Footer `Secure content is revealed and editable until you leave this screen.`
- Locked footer: `Content is encrypted. Metadata remains searchable.`
- Capture detected: overlay and footer `Screen recording detected. Secure content stays hidden.`
- Protected rendering unavailable: overlay `Protected display unavailable. Secure content stays hidden.`; footer `Secure content was hidden because protected display failed.` (`snippets-ios/SecureSnippetReveal.swift:334-340`; `PE:786-790`, `1427`).
- A revealed body allows only delete, paste, select and select-all. Copy, cut, share, look-up, translate, drag and Writing Tools are unavailable (`SecureUIKit.swift:101-106`).
- The body re-locks when: the editor is left, the app or scene goes inactive or to the background, the vault locks, screen capture starts, or the editor is about to copy, duplicate, delete, convert the entry or show a dialog of its own (`PE:107-112`, `1337`, `1619-1653`).

### 6.5 Session and auto-lock, as the user experiences it

- Editor sessions last 5 minutes without secure use and at most 30 minutes in total (`snippets/Vault/VaultSession.swift:64-68`).
- Going to the background locks immediately (`AppEnvironment.swift:244`).
- Copy, make-ordinary and the settings actions prompt every time regardless of the session.
- SET-VAULT `Lock Now` ends the session at once.

### 6.6 Secure copy

60-second, local-only clipboard item; toast or footer says `Secure clipboard expires in 60 seconds.` Placeholders in a secure body are resolved too. The plaintext is wiped from memory after the write (`SnippetActionService.swift:84-111`).

### 6.7 Capture and accessibility protection

- The secure body is drawn through a capture-protected layer: it is absent from screenshots, screen recordings and the app switcher snapshot.
- The secure body is excluded from the accessibility tree for the whole session, also while it is visually revealed. A sibling element stands in for it (`SecureUIKit.swift:1175-1181`): label `Protected secure snippet body`, value one of `Use Reveal Secure Content to show it visually. The text is unavailable to accessibility.`, `Authenticated secure content is being prepared. The text is unavailable to accessibility.`, `Content is shown visually. The text remains unavailable to accessibility.`
- Name, keyword and tags of secure entries stay fully accessible.
- Third-party keyboards are disabled for the whole app.

### 6.8 SET-VAULT rows

(`SV:570-604`, `674-681`) Pane title `Secure Snippets`.

| Row | Detail | Shown |
|---|---|---|
| `Secure Snippets Status` | `Not set up. Make any snippet secure to create your encrypted vault.` / `Unlocked for this session. Secure snippets still authenticate before reveal or insertion.` / `Locked. Secure snippets stay encrypted until you authenticate.` | always |
| `Key Storage` | `Secure snippets stay on this device. Syncing them needs the iCloud Keychain entitlement.` / `Secure snippets can sync to your other devices through iCloud Keychain.` (`KeychainSecretStore.swift:547-549`) | always |
| `Lock Now` | — | vault exists |
| `Add Recovery Key` | `Create the offline recovery key this vault does not have yet.` | vault exists without a recovery key |
| `Restore with Recovery Key` | — | vault exists |
| `Remove Secure Snippets from This Device` (red) | `The shared Keychain key remains available to your other devices.` / `This also removes the device-only vault key.` | vault exists |

**Add recovery key** (`SV:1523-1543`): after authentication, alert `Save Your Recovery Key` / `Store this somewhere safe.` plus the key; buttons `Copy & Save`, `I’ve Saved It`, `Cancel`. Error title `Couldn’t Add Recovery Key`.

**SEC-RESTORE-KEY** (`SV:1549-1569`): title `Restore Vault Key`; message `Enter the recovery key created when Secure Snippets was set up.`; field placeholder `Recovery key`; `Cancel`, `Restore`. Error title `Couldn’t Restore Vault Key`, with messages such as `that recovery key has a typo in it`, `"\(character)" is not part of a recovery key`, `a recovery key is \(n) characters, got \(count)`, `this vault has no recovery key` (`snippets/Core/RecoveryKey.swift:76-84`; `SecureSnippetStore.swift:53`).

**Remove** (`SV:1575-1603`): title `Remove Secure Snippets?`.
- Sync on: message `Turn off cloud sync first.`, only `Cancel`.
- Sync off: message `This removes every secure snippet stored on this device. This action cannot be undone.`, `Cancel`, `Remove` (destructive). Error title `Couldn’t Remove Secure Snippets`.

### 6.9 Other secure errors the user can see

- `your other device's secure-snippets key has not reached this one yet. Check that iCloud Keychain is on in Settings, or restore the key with your recovery key under Secure Snippets.`
- `the vault is locked`, `no vault key is available on this device`
- `this secure snippet contains metadata from a newer build; update Snippets before making it non-secure`
- `keyword already exists` (`SecureSnippetStore.swift:57-59`, `1401`, `1703-1704`; `VaultSession.swift:51-52`.) These are lower-case sentence fragments shown as alert bodies; see Open questions.

---

## 7. Settings

### 7.1 Structure

Sheet titled `Settings` with `Done`. Search field `Search Settings`, always visible. Sections and destinations in order (`snippets/Core/SettingsCatalog.swift:123-133`):

```
Library
  Sync              (icon: circular arrows)
  Secure Snippets   (lock)
  Backup            (drive)
Support
  Diagnostics       (waveform)
  About             (info)
```

iPhone pushes each pane; iPad shows them beside the list with `Sync` open.

### 7.2 Settings search

(`SettingsCatalog.swift:143-176`, `186-234`; `SV:163-208`) Fixed vocabulary only, never user content. Every whitespace-separated token must appear in the entry's title, its pane title or its keywords (case/diacritic-insensitive). Ranking per token: exact title 100, title prefix 60, title contains 35, pane prefix 20, keyword prefix 12, else 1; ties by pane then title. Results appear under `Search Results` with the pane name as subtitle. Choosing one opens the pane, scrolls to the row and flashes it for 0.7 s.

Entries available on mobile (title → pane; keywords):

| Title | Pane | Keywords |
|---|---|---|
| `Cloud Provider` | Sync | icloud, snippets cloud, backend, git, github, gitlab, gitea, gitverse, repository |
| `Cloud Account` | Sync | sign in, sign out, account, create account, account key |
| `Sync This Library` | Sync | enable, icloud, cloud |
| `Sync Status` | Sync | last sync, state, health |
| `Sync Now` | Sync | refresh, upload, download |
| `Sync Recovery` | Sync | review, resume, reset, account |
| `Secure Snippets Status` | Secure Snippets | vault, protected, locked |
| `Key Storage` | Secure Snippets | keychain, device, icloud |
| `Set Up Secure Snippets` | Secure Snippets | vault, create, password |
| `Lock Now` | Secure Snippets | vault, secure |
| `Add Recovery Key` | Secure Snippets | backup, offline, vault |
| `Restore with Recovery Key` | Secure Snippets | recover, vault, key |
| `Remove Secure Snippets from This Device` | Secure Snippets | forget, delete local, vault |
| `Import Library` | Backup | json, restore, file |
| `Export for Sharing` | Backup | json, plain text, file |
| `Export Encrypted Backup` | Backup | archive, password, restore |
| `Persistent Logs` | Diagnostics | diagnostics, storage, retention |
| `Export Logs` | Diagnostics | diagnostics, support, jsonl |
| `Delete Logs` | Diagnostics | clear, privacy, diagnostics |
| `Version and Build` | About | about, app, release |
| `Project and License` | About | github, source, mit |

Entries without a row of their own fall back: `Cloud Account` → the provider or sync row; `Set Up Secure Snippets` → the status row; a recovery row that is hidden → the status row (`SV:692-697`).

### 7.3 SET-SYNC

(`SV:527-569`, `662-673`) Rows in order:

1. `Cloud Provider` (only when more than one provider is available) — detail = provider name, or `Git · \(host/path)` for Git; chevron; opens SHEET-PROVIDER.
2. `Sync this library` — switch. Detail: plain-text Git library: `Ordinary snippets are saved as readable Markdown files in your Git repository. Secure snippets stay encrypted.`; several providers: `Encrypted before it is sent. Only one cloud provider is writable at a time.`; one provider: `Encrypted before it is sent to iCloud.`
3. `Status` — the status sentence (section 10.1).
4. Either the recovery row (orange, title = recovery action title, detail = its explanation) or `Sync Now` (indigo), or neither when sync needs attention without a recovery action.

**SHEET-PROVIDER** (`SV:744-790`): title `Cloud Provider`; message `Switching keeps your snippets and the other provider’s copy.` Options: `iCloud` (with ` ✓` when current), `Snippets Cloud…` / `Snippets Cloud ✓` (flag), `Git Repository…` / `Git Repository ✓`, then at most one destructive Snippets Cloud maintenance item (`Reset Unreadable Cloud Sign-In`, `Retry Sign Out`, or `Sign Out of Snippets Cloud on This Device`), then `Cancel`.

**ALERT-SWITCH** (`BS:3622-3641`), buttons `Cancel`, `Switch and Sync` (preferred):
- Sync currently off: title `Start Syncing with \(provider)?`; message `The \(count) on this \(device) will be merged with \(destination), and sync will turn on.`
- Sync on: title `Switch Sync to \(provider)?`; message `Snippets merges the \(count) on this \(device) with \(destination), then syncs only with \(provider). Your \(old provider) copy is kept.`
- `\(count)` is `1 snippet` or `N snippets`; `\(destination)` is `host/path (branch)` for Git, `Snippets Cloud (Library ID …)`, or `iCloud`.
- Plain-text Git library adds a paragraph: `This is a plain-text library: ordinary snippets will be readable in the repository.`

**ALERT-SWITCH-PROGRESS** (`SV:884-885`): `Switching to \(provider)…` / `Checking destination · comparing libraries · uploading changes · verifying sync`, no buttons. Success is silent (status row updates; announcement `\(provider) is active and up to date.`). Failure: **ALERT-SWITCH-ATTENTION** `Switch Needs Attention` / `Your libraries were not deleted. \(statusDescription)` / `OK`.

### 7.4 SET-BACKUP

(`SV:252-272`) Footer `Exports for sharing are readable JSON. Use an encrypted backup for safekeeping.`

| Row | Detail |
|---|---|
| `Import Library` | `Add snippets from a JSON library or restore an encrypted archive.` |
| `Export for Sharing` | `Create a readable JSON copy of the library.` |
| `Export Encrypted Backup` | `Create a password-protected archive.` |

Each closes Settings and then runs the same flow as the library's Transfer menu.

**Import** (`PR:224-235`, `311-394`; `snippets-ios/IncomingDocumentLoader.swift`)
1. System picker limited to JSON and `.snippetsbackup`.
2. Toast `Reading import…`. Limits: 16 MiB JSON, 32 MiB backup.
3. Format accepted: a raw array, `{"snippets": […]}`, or a Raycast export. Merge by id first, then by case-insensitive keyword, so re-importing updates instead of duplicating.
4. **IMPORT-RAYCAST** when keywords start with `!`: `Raycast Keywords` / `Some imported keywords begin with !. Keep it as part of each keyword?` / `Remove !`, `Keep !`, `Cancel`.
5. Toast `Imported \(count) snippet(s).`
6. Errors (title `Couldn’t Import Snippets`): `The selected file could not be read.`, `Unsupported file format. Expected JSON exported from Snippets or Raycast.`, `The selected file is too large. The maximum supported size is \(limit).`

**Export for Sharing** (`PR:242-262`): writes `Snippets-Export.json` to a private temporary folder, opens the system save picker, toast `Exporting \(count) ordinary snippet(s). Secure snippets are excluded.` The temporary file is removed when the picker closes; leftovers older than 24 h are purged at launch (`snippets-ios/TemporaryExportFiles.swift`).

**Encrypted backup export** (`PR:265-308`, `449-482`)
1. **ALERT-BACKUP-NEW-PW**: `Protect Encrypted Backup` / `Use a unique password of at least 12 characters and save it in a password manager. Snippets cannot recover it.`; fields `Backup password`, `Confirm password`; `Cancel`, `Create Backup`. The button enables only when the password has ≥ 12 characters, is not all whitespace and both fields match. (iPad wording: `This private backup includes secure snippets. Use a unique password of at least 12 characters and save it in a password manager; Snippets cannot recover it.`, `MS:782`.)
2. Authentication when a vault exists; toast `Preparing encrypted backup…`.
3. Save picker for `Snippets-Backup.snippetsbackup` (MIME `application/vnd.khm.snippets.encrypted-backup`); toast `Backup contains \(n) ordinary and \(m) secure snippets.`
4. Error title `Couldn’t Create Encrypted Backup`.

**Encrypted backup import** (`PR:396-447`, `485-509`)
1. **ALERT-BACKUP-OPEN-PW**: `Open Encrypted Backup` / `Enter the password used when this backup was created.`; field `Backup password`; `Cancel`, `Open Backup` (enabled when non-empty). Toast `Opening encrypted backup…`.
2. Toast `Imported \(n) ordinary and \(m) secure snippet(s).`
3. Errors (title `Couldn’t Import Encrypted Backup`, `snippets/Core/EncryptedSnippetBackup.swift:34-44`; `SecureSnippetStore.swift:82-92`): `That password does not unlock this backup.`, `The backup is damaged or has been modified. Nothing was imported.`, `This is not a Snippets encrypted backup.`, `This backup uses format version \(version), which this version of Snippets cannot read.`, `This backup belongs to a different secure-snippet vault. Import it into a fresh Snippets library or a device already using the same vault.`, `The backup and this device have different keys for the same secure-snippet vault. Nothing was imported.`, `Import conflict: \(detail)` / `Import conflicts:` plus a bulleted list.

**Quarantine recovery** (library file unreadable)
- **IMPORT-QUARANTINE-JSON** (`PR:349-362`): `Replace the Quarantined Library?` / `The selected file contains \(count) ordinary snippet(s). It will completely replace the unreadable ordinary-snippet library. Use only a complete Snippets JSON export—a partial or Raycast export can omit data. Secure snippets are unchanged, and the unreadable file is preserved. Sync stays paused until you review it and choose Check Again.` / `Cancel`, `Use Complete Export` (destructive). Toast `Installed \(n) snippet(s) as the recovery candidate. Review Sync and choose Check Again.`
- **IMPORT-QUARANTINE-BACKUP** (`PR:410-415`): `Restore the Quarantined Library from This Backup?` / `The authenticated backup contains \(n) ordinary and \(m) secure snippet(s). Its ordinary library will completely replace the quarantined recovery candidate; compatible secure snippets will be restored in the same transaction. The unreadable original remains preserved, and Sync stays paused until you choose Check Again.` / `Cancel`, `Restore Encrypted Backup` (destructive). Toast `Installed encrypted recovery with \(n) ordinary and \(m) secure snippet(s). Review Sync and choose Check Again.`
- A new backup cannot be made while quarantined: `A new all-library backup cannot be created while the ordinary snippet library is unreadable. You can still restore an existing encrypted backup, or use a complete Snippets JSON export.`

### 7.5 SET-DIAG

(`SV:605-629`, `1428-1464`; `docs/diagnostics.md`)

| Row | Detail |
|---|---|
| `Persistent Logs` | `\(n) file(s), \(size). Kept for up to 14 days.` or `The diagnostics folder is unavailable.`; appends ` Legacy audit cleanup still needs attention.` in red when applicable |
| `Export Diagnostic Logs` | Long privacy notice, starts `Plaintext JSON Lines. Operation counts, …` and ends `…secure-snippet keywords may be included; bodies, clipboard contents, names, tags, IDs, paths, account keys, account IDs, tokens, keys and ciphertext are excluded.` (`SV:622-624`) |
| `Delete Diagnostic Logs` (destructive) | — |

- Export builds one validated `.jsonl` file (limit 25 MiB) and opens the save picker. Error title `Couldn’t Export Diagnostics`.
- Delete confirmation: `Delete Diagnostic Logs?` / `This permanently removes retained diagnostics and any legacy reveal-audit file from this device.` / `Cancel`, `Delete Logs`.
- Retention: 14 days, 64 files, 24 MiB, rotation at 1 MiB or 24 h (`README.md:519-521`).
- The Android notice must list what the Android logs actually contain; the iOS sentence enumerates Mac paste and CloudKit fields.

### 7.6 SET-ABOUT

(`SV:319-377`) Header: app icon, `Snippets`, `Version \(version) (\(build))`. Rows: `View on GitHub` / `Source code, releases, and issue tracker` → `https://github.com/wowlocal/snippets`; `MIT License` / `Open-source license` → `https://github.com/wowlocal/snippets/blob/main/LICENSE`.

---

## 8. Git sync UX

Screen title `Git Repository` (`GV:256`). Reached from SHEET-PROVIDER. While a step runs the back button and swipe-back are disabled and the sheet cannot be dismissed (`GV:1009-1024`). Status lines appear as the footer under the action section and are announced.

### 8.1 Not connected: the form

- Intro footer: `Create a new private repository without a README, then paste its address.` (`GS:49-50`).
- Fields (`GV:17-22`, `516-545`):

| Label | Placeholder | Notes |
|---|---|---|
| `Repository` | `https://… or git@…` | URL keyboard. A missing `https://` is added. |
| `Branch` | `main` | Prefilled `main`. |
| `User Name` | `Your account name` | HTTPS only; hidden for github.com and gitlab.com unless one was entered before. |
| `Access Token` | `Personal access token`, or `Saved. Leave empty to keep it.` | HTTPS only; secure entry; Return key `Go` connects. |

- Typing an SSH address (`git@…`, `ssh://…`, `host:path`) hides User Name and Access Token and shows the SSH key section (`GS:192-200`; `GV:123-128`).
- Token help footer under the form, following the host (`GS:93-104`):
  - GitHub: `Use a fine-grained token limited to this repository, with Contents: Read and write.`
  - GitLab: `Use a project access token with read_repository and write_repository (Developer role; Maintainer for a protected branch).`
  - Other: `Use a token that can read and write this repository. On Gitea and Forgejo: write:repository.`
- Link row `Create a Token on \(host)…` (GitHub, GitLab).
- Action row `Connect` (or `Update` when changing a connection); `Working…` with a spinner while busy.
- Return moves through the visible fields; on the last one it connects.

### 8.2 SSH key section

(`GV:342`, `356`, `382-414`) Header `This iPhone’s SSH Key`; footer `Each device has its own key. The private half never leaves this iPhone.`
1. `Add this key to the repository as a deploy key with write access, then tap Connect.`
2. The public key on one middle-truncated monospaced line (label `SSH public key, ending in \(last 6). Use Copy Public Key to add it.`); when unavailable `The device key is unavailable. Unlock the device and try again.`
3. `Copy Public Key` → status `Public key copied.`
4. `Add Deploy Key on \(host)…` (GitHub, GitLab) opens the host's deploy-key page.
5. `Share Public Key…` opens the share sheet.

One P-256 key per device, hardware-backed when possible, never synced.

### 8.3 Connect sequence and its dialogs

Status while working: `Checking the repository…`, `Checking that the repository is private…`, `Creating the library…`, `Connecting…`, `Opening the library…`.

| Step | Dialog | Copy |
|---|---|---|
| First SSH contact, host is a known forge | GIT-HOSTKEY-PUBLISHED | `Trust This SSH Host?` / `This device hasn’t connected to \(host) before. Its host key matches the one \(publisher) publishes:` + fingerprint / `Cancel`, `Trust` |
| First SSH contact, other host | GIT-HOSTKEY-NEW | `Trust This SSH Host?` / `This device hasn’t connected to \(host) before. Its host key fingerprint is:` + fingerprint + `Trust it only if it matches the fingerprint the host publishes.` / `Cancel`, `Trust` |
| Host key differs from the trusted one | GIT-HOSTKEY-CHANGED | `SSH Host Key Changed` / `\(host) presented a different key than the one this device trusted:` + fingerprint + `This happens when a host replaces its key, but it can also mean someone is intercepting the connection. Continue only if the host announced a new key with this fingerprint.` / `Cancel`, `Trust New Key` (destructive) |
| Branch has other files | GIT-FOREIGN-BRANCH | `This Branch Has Other Files` / `This branch already has files, such as a README. Snippets can use its own branch in this repository instead.` / `Cancel`, `Use Branch “snippets”` |
| Branch is empty | GIT-MODE | `Create a Snippets Library Here?` / `This branch is empty. Snippets will create an encrypted library here and show you a recovery code to save.` / `Create Library` (preferred), `Plain Text Instead…`, `Cancel` |
| Plain text chosen | GIT-PLAIN-CONFIRM | `Create a Plain-Text Library?` / `Ordinary snippets become Markdown files that the host and anyone with access to the repository can read. They stay in its history even after you delete them, and you can’t change this later. Secure snippets stay encrypted.` / `Back`, `Create Plain-Text Library` |
| Plain text, repository is public | GIT-PUBLIC | `This Repository Is Public` / `This repository is public. Anyone on the internet could read plain-text snippets. Make it private, or create an encrypted library.` / `OK`, then back to GIT-MODE |
| Plain text, visibility unknown | GIT-VISIBILITY-UNKNOWN | `Couldn’t Check the Repository` / `Snippets couldn’t check whether this repository is private. Create a plain-text library only if it is private: anyone who can read the repository can read your ordinary snippets.` / `Cancel`, `It’s Private` (destructive) |
| Existing plain-text library | GIT-JOIN-PLAIN | `Join a Plain-Text Library?` / `This iPhone’s ordinary snippets will be readable by anyone with access to the repository, and stay in its history. Secure snippets stay encrypted.` / `Cancel`, `Join` |
| Branch now holds a different library | GIT-REPLACEMENT | `Reconnect to This Repository?` / `This library’s keys were replaced on another device, or a new library was created in this repository. Reconnecting merges this iPhone’s snippets into it. Nothing on this iPhone is deleted.` / `Cancel`, `Reconnect and Merge` |
| Device lacks the library key | GIT-CODE-ENTRY | `Enter the Recovery Code` / optional problem line, then `Enter this library’s newest recovery code.` / field `XXXX-XXXX-XXXX-…` (all caps, no autocorrect) / `Cancel`, `Continue`; repeats with the problem on a wrong code |
| Library created | GIT-CODE-SHOW | section 8.4 |

(`GV:693-737`, `747-869`, `1083-1133`; `GS:121-153`, `1385-1388`.) The trust and branch prompts retry the connection automatically, up to three attempts.

Outcome status lines: `Connected.`, `Connected. Secure snippets still need the recovery code: tap Set Up Secure Snippets.`, `Not connected.`, `Nothing was created.`, `Not connected. This device needs the library’s recovery code.` After connecting, if Git is not yet the active provider the screen pops and ALERT-SWITCH appears.

### 8.4 GIT-CODE-SHOW — recovery code sheet

(`GV:1181-1312`; `GS:136-141`) Form sheet that cannot be swiped away.
- Title `Save Your Recovery Code`.
- Body: `This code opens your library on a new device, secure snippets included. Snippets can’t show it again. Store it in your password manager.` (Apple adds ` Your other Apple devices with iCloud Keychain connect without it.` when the key syncs; not applicable on Android.)
- The code, 24 pt semibold monospaced, centred in a rounded box, wrapping at hyphens; read out character by character.
- `Copy` → local-only clipboard item expiring in 2 minutes; label `Copied. It clears from the clipboard in 2 minutes.` appears and is announced.
- `Done, I’ve Saved It` (prominent) closes.
- The content is hidden whenever the app is not active, so it never reaches the app switcher.
- Shown exactly once per code. If it cannot be presented: `The recovery code could not be shown. Create a new one from this screen.`
- The code is 27 Crockford base-32 symbols with a check symbol, grouped with hyphens; typos are reported as typos.

### 8.5 Connected: management

Section header `Connected Library` (`GV:298-318`, `446-497`). Rows, each shown only when relevant:

| Row | Detail / behaviour |
|---|---|
| Summary: `\(host/path) · \(branch)` (headline) | Lines: `Encrypted · HTTPS` (or `Plain text`, `SSH`); then anything needing the user: `This iPhone can’t open the library. tap Reconnect and enter the recovery code.`, `Access token missing. Enter it below and tap Update.`, `Secure snippets: not set up on this iPhone.`, `Secure snippets: locked. This iPhone needs the recovery code.`; then the sync status sentence, or `Not syncing with it yet: tap Switch and Sync.` (`GS:1070-1088`) |
| `Reconnect…` | When sync stopped on something reconnecting fixes |
| `Set Up Secure Snippets…` | When secure snippets need setup or the code; statuses `Checking the library…`, `Opening secure snippets…`, `Secure snippets are ready on this iPhone.`, `Secure snippets are still locked on this iPhone.` |
| `Sync Now` or `Switch and Sync` | Depending on whether Git is the active provider |
| `New Recovery Code…` | Detail `For a lost code.` |
| `Replace Keys…` | Detail `For a leaked code or a lost device.` Only while Git is active |
| `Change Address…` / `Change Address or Token…` / `Hide Connection Details` | Unfolds the form under header `Change Connection` |
| `Remove from This iPhone…` (destructive) | Disabled with detail `Switch sync away from Git first.` while Git is active |

**GIT-NEW-CODE** (`GV:877-890`; `GS:160-168`): `Create a New Recovery Code?` / `The old code stops working in Snippets. If it may have leaked, use Replace Keys instead.` (or `…switch sync to this library and use Replace Keys instead.`) / `Cancel`, `Create Code`. Then authentication, status `Creating a new recovery code…`, GIT-CODE-SHOW. Error title `Couldn’t Create a Recovery Code`. A cancelled authentication is silent.

**GIT-REPLACE-KEYS** (`GV:897-926`; `GS:463-467`): `Replace This Library’s Keys?` / `Your other devices stop syncing until you reconnect each one with the new recovery code. Sync them first if you can.` + blank line + `The old code still opens earlier versions in the repository’s history. If it may have leaked, also change the passwords you keep in secure snippets.` / `Cancel`, `Replace Keys` (destructive). Then authentication, status `Replacing the library’s keys…`, GIT-CODE-SHOW, status `Keys replaced. Reconnect your other devices with the new recovery code.` Error title `Couldn’t Replace the Keys`.

**GIT-REMOVE** (`GV:972-987`; `GS:154-155`): `Remove the Repository from This iPhone?` / `Nothing in the repository is deleted. You can reconnect later without the recovery code.` / `Cancel`, `Remove` (destructive). Status `Removed from this iPhone.` Error title `Couldn’t Remove the Repository`.

### 8.6 Setup failure messages

Alert title `Couldn’t Connect the Repository` unless noted; body from `GS:341-507`. Fallback `Something went wrong. Try again.`

| Situation | Message |
|---|---|
| Bad address | `Enter the repository’s address, for example https://github.com/you/snippets-library or git@github.com:you/snippets-library.git.` |
| Bad branch | `Enter a valid branch name, such as main.` |
| Missing user name | `Enter your account name on this Git host as the user name.` |
| Missing token | `Enter an access token with read and write access to the repository’s contents.` |
| Token refused | `The Git host didn’t accept the access token. It may have expired, or it can’t write to this repository. Enter a new token.` |
| Not found | `Repository not found. Check the address, and that the token or SSH key can see this private repository.` |
| Not a usable git server | `This address isn’t a git repository Snippets can use. Check that you copied the clone address.` |
| Unreachable | `Couldn’t reach the Git host. Check the address and your connection, then try again.` |
| Rate limited | `The Git host is limiting requests. Try again shortly.` |
| Push refused | `The Git host refused the change. Check that the branch is not protected and that the token or SSH key can write to it.` |
| Other refusal | `The Git host refused the request.` |
| Upload too large | `The Git host refused the upload as too large. If a proxy sits in front of it, raise its request size limit (for example nginx client_max_body_size).` |
| Not a library | `This branch does not hold a Snippets library.` |
| Created elsewhere just now | `Another device created a Snippets library in this repository a moment ago. Connect to it instead.` |
| Changed while connecting | `The repository changed while connecting. Check it again.` |
| Code needed | `Enter this library’s recovery code. It was shown when the library was created.` |
| Code malformed | `That is not a valid recovery code. Check it for typos.` |
| Code wrong | `That recovery code does not open this library.` |
| No recovery envelope | `This library has no recovery code. Connect from a device that already has its key.` |
| Created but not saved | `The library was created, but this device could not save the connection. Keep the recovery code, then tap Connect again.` |
| Creation uncertain | `Snippets couldn’t confirm whether the library was created. Keep the recovery code: if the library exists, it opens it. Then tap Connect again.` |
| Git active, other repository | `Git is syncing with \(location). To use a different repository or library, switch sync to iCloud first, then connect it here.` |
| Busy | `Sync is busy with another account change. Try again in a moment.` |
| Switch unfinished | `A switch to or from Git has not finished yet. Use Sync Now until it completes, then change the repository.` |
| Cannot save settings | `This device could not save the repository settings. Try again.` |
| Remove while active | `Git is in use. Switch sync to another provider before removing the repository.` |
| SSH host unknown (mobile) | `This device hasn’t connected to \(host) before. Confirm its host key fingerprint to continue.` |
| SSH host key changed | `The SSH host key for \(host) is different from the one this device trusted. This can mean the host changed its key, or that someone is intercepting the connection.` |
| SSH key refused | `\(host) didn’t accept this device’s SSH key, or the key can’t write to this repository. Add the key shown below to the repository with write access, or to your account.` |
| SSH algorithms | `\(host) offers SSH settings this device can’t use, for example only RSA host keys. Use the repository’s https:// address instead.` |
| SSH without git | `\(host) accepted the SSH login but doesn’t run git for it. Check the address, or use the repository’s https:// address.` |
| SSH unavailable | `SSH isn’t available in this version of Snippets. Use the repository’s https:// address.` |
| Secure snippets, different vault | `This device has \(n) secure snippet(s) protected by a different key than this library’s. Turn it/them into ordinary snippets or delete it/them, choose Remove Secure Snippets from This Device in Settings, then connect again.` |
| Secure snippets, wrong code | `That recovery code does not open this library’s secure snippets. If the code was replaced, enter the newest one.` |
| Secure snippets, key elsewhere | `Another device holds the key to this library’s secure snippets. Update Snippets on that device, create a new recovery code there, then enter that code here.` |
| Secure snippets, needs active Git | `Switch sync to this Git library and let it finish syncing, then set up secure snippets.` |
| Owner check failed | `Snippets couldn’t confirm it’s you, so your secure snippets were left as they are. Nothing was changed.` |
| Replace keys, not in sync | `Keys can be replaced only while Git sync is on and up to date. Use Sync Now, fix anything it reports, then try again.` |
| Replaced but not saved | `The repository now uses the new keys, but this device could not finish switching to them. Keep the new recovery code, then tap Reconnect.` |
| Replacement uncertain | `Snippets couldn’t confirm whether the keys were replaced. Keep the new recovery code: if the library asks for one, this is it. Use Sync Now; if it asks you to reconnect, tap Reconnect.` |

### 8.7 Runtime behaviour the user notices

(`docs/git-sync.md:324-347`, `401-411`) Automatic Git rounds are paced: 30 s after the last local change, at most 120 s after the first; a poll every 60 s; a waiting change is pushed when the app goes to the background. `Sync Now`, setup, recovery and provider switches are immediate. One record is limited to 900,000 bytes. Plain `http://` addresses are refused in release builds.

---

## 9. Snippets Cloud UX (internal build flag)

Hidden unless the build enables it. Without a pinned endpoint: `Snippets Cloud Isn’t Configured` / `This build has no verified cloud endpoint. A self-hosted build must pin its server address at build time.` (`SV:928-929`).

### 9.1 CLOUD — account screen (iOS)

Title `Snippets Cloud` (`SV:1705-1923`). Sections:

| Section | Rows |
|---|---|
| `Account` | Status title `Not connected` / `Account connected` / `Account needs review`, detail `Account ID \(id)` or `Not signed in`; `Selected library` — `Library ID \(id) · Used for support` |
| `Sync` | `Active storage` — provider name; sync title `Snippets Cloud is not the active storage` / `Up to date` / `Syncing your library…` / `Sync needs attention`, detail = status sentence; `On this device` — `\(n) snippets` |
| `Security` | `Library access` — `Unlocked on this device` / `Use an approved device or recovery kit` / `Library setup needs to be completed`; `Recovery kit` — `Verified against the current cloud recovery envelope` / `The previously saved recovery kit was replaced and no longer works` / `Saved verification has not yet been confirmed against the current cloud envelope` / `Not saved on this device. Sync is available; save a kit before losing access to your devices.` / `Replacement still needs to be saved and checked` |
| `Account Actions` | By state: `Create account or sign in`, `Resume library setup`, `Retry setup verification`, `Return to device approval`, `Save and check recovery kit`, `Continue setup`, `Save recovery kit — recommended`, `Use Snippets Cloud for sync`, `Sync now`, `Scan a new device invitation`, `Replace recovery kit`, `Show account key`, `Change account`, `Change library`, `Disconnect this device` (red) |

### 9.2 CLOUD-SIGNIN sheet

(`CK:141`, `520-549`) Title `Snippets Cloud`.
- **Choose**: heading `Snippets Cloud Account`; text `Create a new account, or sign in with the account key you saved when you created it.`; buttons `Create Account` (`Creating Account…`), `Sign In with Account Key`, and, when the server supports it, `Sign In with Another Device`.
- **Key entry**: heading `Sign In with Account Key`; text `Enter or paste the account key you saved. Spaces and hyphens are optional.`; field labelled `Account key`; `Sign In` (`Signing In…`), `Back`. Rate limit line `Try again in \(n) seconds.`
- **Save key** (after creation): `Save Your Account Key` / `This key is the only way to sign in to this account on another device. Snippets can’t recover it or send it to you. Store it in your password manager.`; the key in large monospaced text; `Copy` → `Copied. The clipboard clears in 2 minutes.`; `I’ve Saved It` is the only way forward.
- **Another device**: heading `Sign In with Another Device`; text `On a device that already has your library, open Snippets Cloud, choose to scan a new device invitation, and scan this code or paste the copied text. Continue there only if it shows the same confirmation code.`; QR (label `Sign-in request QR code`); `Confirmation code: \(code)`; `Waiting for approval… MM:SS`; `Copy Request Text` (announces `Request text copied.`); `Back`.
- Errors (`snippets/Sync/SnippetsCloudAccountKeySignInFlow.swift:26-34`): `This isn’t a valid account key. Check it for typos.`, `That account key wasn’t accepted. Check it and try again.`, `Please wait before trying again.`, `Couldn’t reach Snippets Cloud. Check your connection and try again.`, `This server could not complete native sign-in. Try again later.`, `This server doesn’t support signing in with another device. Use your account key instead.`, `This sign-in request expired. Start again to show a new code.`, `This sign-in request is no longer valid. Start again to show a new code.`

### 9.3 Unlocking the library on a new device

- **CLOUD-UNLOCK** (`SV:1173-1192`): `Unlock Your Encrypted Library` / `Use a device that already has this library, or your offline recovery kit. Snippets Cloud cannot read or recover the library key.`; options `Use an Approved Device`, `Scan Recovery QR`, `Enter Recovery Code`, `I Have Neither` (destructive), `Cancel`.
- `I Have Neither`: `Old Data Cannot Be Recovered` / `Your account can still be used, but without any approved device or the recovery kit, the old encrypted snippets are mathematically unrecoverable. Snippets Cloud has no decryption key.` / `I Understand`.
- **CLOUD-PAIR-WAIT** (`SV:2145-2258`): title `Add This Device`; `Cancel Pairing`; text `On a device that already opens this library, open Snippets Cloud, choose Add device, and scan this QR. Confirm that both devices show the same code.`; QR; `Check code: \(code)`; `Waiting for approval… MM:SS`; `Check Again`. Expired: `Invitation expired. Create a new invitation to continue.` Poll error: `Couldn’t check approval. Your invitation is still safe; Snippets will keep trying.`
- **CLOUD-KIT-ENTRY** (`SV:2505-2621`): title `Recovery Kit`; text `Paste or enter the long code from your offline recovery kit. Spaces and hyphens are handled automatically.`; field `XXXX-XXXX-…` (accepts A–Z and 2–7, 52 characters); progress `Code is incomplete · \(n)/52 characters` / `Code is complete`; `Paste`, `Show Code` / `Hide Code`, `Scan Recovery QR`, primary `Restore Encrypted Library`.
- **CLOUD-SCAN**: title `Scan New Device` or `Scan Recovery Kit`. No camera: `Camera Scanning Is Unavailable` / `Use Enter Recovery Code instead.` or `Open this screen on an iPhone or iPad with an available camera.`

### 9.4 Approving another device (on the trusted device)

- **CLOUD-APPROVE, pairing** (`SV:1302-1311`): `Approve This Device?` / `Confirmation code: \(code)` + blank line + `Confirm that the same code is shown on the new device. Face ID or Touch ID is required before this device releases the encrypted library key.` / `Cancel`, `Approve \(code)`. Then authentication with reason `Approve a new device for your encrypted Snippets library`.
- **Device sign-in** (`SV:1323-1330`): `Sign In a New Device?` / `Confirmation code: \(code)` + `Sign in a new device to this account? It will also receive this library’s key. Continue only if this code matches the code on the new device.` / `Cancel`, `Approve \(code)`; reason `Sign in a new device to your Snippets Cloud account`. Result: `New Device Signed In` / `The new device is signed in.`
- Failure title `Approval Failed`.

### 9.5 CLOUD-KIT — recovery kit

(`SV:2280-2443`) Title `Save Your Recovery Kit`; leading `Save Later`.
- `Keep this QR or long code offline. It is the only fallback if every approved device is lost.`
- QR, long code (label `Recovery code`), buttons `Copy Code`, `Share (May Use Cloud)`, `Print`.
- Warning: `Anyone with this kit and access to your account can unlock the library. Keep it offline and private. The system share menu may offer mail, messages, or cloud storage; Print is the safer offline option.`
- Primary `Verify Recovery Kit` → check step: `Use the copy you saved and enter its final 8 characters. This checks the copy on this device; it cannot prove where it was stored.`; field `Final 8 characters`; error `Those characters do not match the recovery kit.`; `Complete Recovery Check`; `Show Recovery Kit Again`.
- Shared/printed text: `Snippets Cloud Recovery Kit` + blank line + code + blank line + `Keep this offline. Anyone with this kit and access to your account can unlock your library.`
- Revealing a pending kit again needs authentication (`Reveal your Snippets Cloud recovery kit`). Replacing: reason `Replace your Snippets Cloud recovery kit`.

### 9.6 First sync, account changes, sign-out

- After connecting (`SV:1198-1217`): `Syncing Your Library…` / `Account connected. Snippets is downloading and verifying your encrypted library.`; then `Snippets Cloud Is Up to Date` / `\(n) snippets are available on this device. The first verified sync completed successfully.` or `Account Connected — Sync Needs Attention` / `Your local snippets are safe. Setup will remain incomplete until a sync finishes. \(status)`.
- Interrupted setup (`SV:1130-1152`): `Library Setup Was Interrupted` / `Snippets was preparing this cloud library but could not determine whether it is new or already contains encrypted data. Local snippets remain available while cloud setup is paused.` / `Not Now`, `Resume Setup`. Unverified: `Cloud Setup State Could Not Be Verified` / `Snippets could not read the saved cloud setup transaction. Local snippets remain available and cloud sync is paused.` / `Not Now`, `Retry`.
- Show account key: authentication (`Show your Snippets Cloud account key`), then a sheet titled `Account Key`. On a device signed in by another device: `This device was signed in by another device. View the account key on a device that has it.`
- Change account (`SV:1046-1050`): `Change Snippets Cloud Account?` / `Current library: Library ID \(id)` + blank line + `Your current cloud library and local snippets will not be deleted. After sign-in, Snippets will show the new Library ID and ask before switching.` / `Cancel`, `Choose Another Account`.
- **CLOUD-LIBRARY-CHOICE** (`SV:1068-1077`): `Switch Snippets Library?` or `Choose a Snippets Library`; message `Current: Library ID \(a)` / `New: Library ID \(b)` + `The current cloud library will not be deleted. The new library may require an approved device or recovery kit.` or `This account can open more than one encrypted library. Choose which one to use on this device.`; options `Library ID \(id) · \(role)`.
- **CLOUD-DISCONNECT** (`SV:1386-1395`): `Disconnect Snippets Cloud from This Device?` / `This removes this device’s cloud connection and its access to open the library. Your cloud library is not deleted. You will need another approved device or the recovery kit to reconnect. You’ll need your account key to sign in again.` + blank line + `Recovery check: \(state sentence)` / `Cancel`, `Disconnect This Device` (destructive).
- Unreadable credentials (`SV:948-952`): `Reset Unreadable Cloud Sign-In?` / long explanation / `Cancel`, `Reset This Device`.
- Error alerts may add a recovery button: `Continue Sign-In`, `Choose Recovery Method`, `Create New Invitation` (`SV:1615-1634`). Generic body: `The request could not be completed. Your local snippets are unchanged; try again.`

### 9.7 What the old Android app showed

(`OA:1111-1941`, `2060-2251`; `app/src/main/java/com/khm/snippets/android/NativeCloudSignInDialog.kt`)
- Settings screen `Cloud & storage` (`Storage` without the flag), intro `Account, library access, active storage, and current sync status are shown separately.`
- Cards: `Active storage` (`Snippets Cloud` / `On device`, button `Use this library on device only`); `Snippets Cloud` (`Connected · Library ID …` / `Not connected`, `Open Snippets Cloud`).
- Account screen cards `Sync`, `Account`, `Security` with buttons `Use Snippets Cloud for sync`, `Sync now`, `Create Account`, `Sign In with Account Key`, `Sign In with Another Device`, `Show Account Key`, `Change library`, `Disconnect this device`, `Scan a new device invitation`, `Paste invitation`, `Replace recovery kit`, `Use an approved device`, `Scan recovery kit`, `Restore encrypted library`, `Approve with biometrics`, `Not this device`, `Reveal with biometrics`, `Finish secure setup`.
- Setup stage line: `Sign in to connect your encrypted library.`, `Account connected. Library setup is not complete yet.`, `Account connected. Unlock the encrypted library to continue.`, `Waiting for an approved device to unlock this library.`, `The recovery kit still needs to be saved and checked.`, `Syncing your library…`, `Connected and up to date.`, `Setup needs attention. Your local snippets are safe.`
- Dialogs: `Create a Snippets Cloud account` / `Snippets Cloud creates a new account and shows its account key once. You'll need that key to sign in on another device.`; `Sign In with Account Key` / `Enter the account key you saved when you created your account.` with `Show key` / `Hide key`, `Try again in ${n}s`, `Please wait…`; `Save Your Account Key` / `Your Account Key` with `Copy`, `I've Saved It` / `Done`; `Sign In with Another Device` with QR, `Code: …`, `Expires in MM:SS`, `Copy`, `Waiting for approval…`.
- Switch dialog: `Switch sync to Snippets Cloud?` / `Current storage: On device` / `New storage: Snippets Cloud · Library ID …` / `On this device: N snippets` / `Your on-device library will not be deleted. Changes are compared and merged before sync is verified.` / `Switch and sync`.
- A closed table of about 30 titled problem cards (title, body, optional action), for example `Device invitation expired` / `Nothing changed. Create a new invitation and approve it within five minutes.` / `Create new invitation` (`OA:2060-2199`). Keep this mapping: it is richer than the iOS alerts.
- Biometric prompt title `Approve encrypted library transfer`, subtitle `Confirm code $it before adding this device` (`OA:162-171`).
- QR scanning used the Google code scanner (`AndroidManifest.xml` `barcode_ui`).

---

## 10. Sync status and halts

### 10.1 The status sentence

One sentence generated in one place (`SC:1960-2046`) and shown in SET-SYNC `Status`, in the empty states, on the iPad sync menu item, and on the Git and Cloud screens.

| State | Sentence |
|---|---|
| Off | `Off. Your snippets stay on this device.` |
| Cannot start | `Cannot start: \(detail)` |
| Starting | `Starting…` |
| Idle, never synced | `On. Nothing synced yet.` |
| Idle, synced today | `On. Last synced at \(time).` |
| Idle, synced earlier | `On. Last synced \(date and time).` |
| Syncing | `Syncing…` |
| Offline | `Cannot reach \(provider). Trying again at \(time).` |
| Needs authentication | `\(provider) needs attention: \(detail).` |
| Needs attention | `Sync needs attention: \(detail).` plus ` Fix the reported condition, then try again.` for non-Git details |
| Waiting for vault (Git, key present) | `Waiting: a secure snippet was changed on two devices. Open any secure snippet to unlock them, then use Sync Now to keep both versions.` |
| Waiting for vault (Git, no vault) | `Waiting: \(detail). Open the Git repository in Sync settings and choose Set Up Secure Snippets.` |
| Waiting for vault (other) | `Waiting: \(detail).` |
| Halted | `Stopped because \(reason): \(detail). \(guidance)` |

Authentication details (`SC:2065-2094`): `Sign in to continue`; `Your sign-in expired; sign in again`; `The Git host didn’t accept the access token. It may have expired; enter a new one in Sync settings`; `The Git access token is missing on this device. Enter it in Sync settings`; `The Git host’s SSH key isn’t trusted on this device. Reconnect in Sync settings`; `The Git host’s SSH key changed. Check it before reconnecting in Sync settings`; `The Git host didn’t accept this device’s SSH key, or the key can’t write`; `The Git repository was not found, or the token or SSH key can’t see it`; `Sign in again to continue`.

Attention details by failure code (`SC:2097-2165`):

| Code | Detail |
|---|---|
| `record_too_large`, `payload_too_large` | `One snippet is too large for the cloud service` |
| `quota_exceeded` | `The cloud account is out of storage` |
| `forbidden` | `This account cannot update the selected cloud library` |
| `incompatible_version` | `Update Snippets before syncing again` |
| `startup_prerequisite_unavailable` | `A local sync prerequisite is temporarily unavailable` |
| `cloud_key_required` | `Approve this device or restore the Snippets Cloud recovery kit` |
| `git_key_required` | `Enter the Git library’s recovery code in Sync settings` |
| `git_configuration_required` | `Connect the Git repository in Sync settings, or choose another provider` |
| `git_library_replaced` | `This library’s keys were replaced on another device, or the repository holds a different library. Reconnect it in Sync settings with the newest recovery code` |
| `git_repository_not_initialized` | `The Git branch no longer holds a Snippets library. Reconnect it in Sync settings` |
| `git_branch_not_snippets_library` | `The Git branch contains files that are not a Snippets library` |
| `git_sync_schema_unsupported` | `A newer Snippets version wrote this Git library; update Snippets` |
| `git_push_rejected` | `The Git host refused the update. Check that the branch is not protected and that the token or SSH key can write to it` |
| `git_response_too_large` | `The Git repository is larger than Snippets accepts` |
| `git_library_mode_changed` | `The Git library’s storage mode changed in the repository. Reconnect in Sync settings to review it` |
| `git_push_too_large` | `The Git host refused an upload as too large. Raise its request size limit` |
| `git_unsupported_ssh_algorithms`, `…_handshake` | `The Git host’s SSH server offers no settings this device supports. Use its HTTPS address` |
| `git_unsupported_ssh_no_git`, `…_exec` | `The Git host accepted the SSH login but runs no git for it` |
| `git_unsupported_ssh_unavailable`, `git_unsupported_ssh` | `SSH isn’t available here. Use the repository’s HTTPS address in Sync settings` |
| other `git_unsupported_*` | `This address isn’t a git repository Snippets can use` |
| `sync_key_unreadable` | `The stored sync encryption key could not be verified` |
| `not_found` | `The selected cloud library is no longer available` |
| `internal_error` | `The cloud service could not accept a change` |
| anything else | `The cloud service rejected a change` |

Start-up problems (`SC:387-409`) include `A newer Snippets version wrote the local sync state. Update Snippets.`, `The local sync checkpoint could not be read.`, `This device does not have the Git library’s key yet. Open Git in Sync settings and enter the library’s recovery code.`, `The Git access token is missing on this device. Open Git in Sync settings and enter it again.`, `Git is selected, but no repository is connected on this device. Open Git in Sync settings to connect it, or choose another provider.`, `The Git library key saved on this device could not be verified. Reconnect the repository in Sync settings with its recovery code. Check Again only rechecks the key; it does not repair it.`

### 10.2 LIB-SYNC-BANNER (iPhone)

(`PL:2180-2260`) A small pill above the first row, scrolling with the list. Shown when sync is on or a local recovery is pending. Icon and a line of at most two lines; when a recovery action exists, a compact action label and chevron at the right and the whole pill is a button.

| State | Text | Icon idea |
|---|---|---|
| Disabled | `Preparing the first cloud fetch…` / `Preparing cloud sync…` | cloud |
| Syncing | `Fetching your cloud library…` / `Syncing changes…` | spinner |
| Idle before first fetch | `Waiting to fetch your cloud library…` | cloud download |
| Idle, synced | `Synced at \(time)` | cloud check |
| Idle, never | `\(provider) on · Not synced yet` | cloud check |
| Offline | `First sync paused` / `\(provider) unavailable` | cloud slash |
| Needs authentication / attention / vault | the status sentence | person-alert / triangle / lock-cloud |
| Halted, newer schema | `Update Snippets to resume sync` | download-app |
| Halted, other | the status sentence | cloud-alert |

### 10.3 Halts and their recovery actions

(`SF:24-110`, `179-240`)

| Halt reason (words in the sentence) | Guidance appended | Action title / compact | Confirmation |
|---|---|---|---|
| `an unusually large deletion arrived` | `Updated Snippets devices normally approve their own explicit delete actions at the source. This batch has no such proof, so review its count before applying it on this device.` | `Confirm Deletions` / `Confirm` | `Apply These Deletions?` → `Apply Deletions` (destructive) |
| (older halt without exact details) | — | `Refresh Deletion Details` / `Refresh` | none |
| `the cloud account changed` | `If you intended to switch accounts, review the account change. Snippets can keep this device's current library and merge it into the newly signed-in account from a fresh checkpoint.` | `Review Account Change` / `Review` | `Use the Current Cloud Account?` → `Use This Account` |
| `the local sync checkpoint could not be read` | `Repair keeps this device's current library, replaces only the unreadable local scheduler checkpoint, and performs a full merge.` | `Repair Sync` / `Repair` | none |
| `the remote cloud library was reset` | `No local data was deleted or re-uploaded. Choose Restore only on the device whose current library should repopulate the cloud.` | `Restore Cloud Library` / `Restore` | `Restore Cloud from This Device?` → `Restore from This Device` |
| `the cloud service refused a snippet` | `Usually the cloud service is not configured for this app, the account is out of space, or one snippet is too large. None of them is fixed by waiting.` | `Try Again` / `Retry` | none |
| `the snippet library could not be read` | `Restore a valid exported library or quarantined backup, reopen Snippets, then choose Check Again. Snippets will not treat the missing library as an empty one.` | `Check Again` / `Check` | none |
| `the secure vault could not be read` | `Restore or repair the secure vault, then choose Check Again.` | `Check Again` / `Check` | none |
| `the backend failed an integrity check` | — | `Check Again` / `Check` | none |
| `a newer version of Snippets wrote this library` | `Update Snippets on this device.` | none | — |
| Recovery claimed elsewhere | — | `Take Over Recovery` / `Take Over` | `Take Over Interrupted Recovery?` → `Take Over` |

Deletion guard: more than `max(5, 20 % of the library)` remote deletions without proof of an explicit delete stop sync. Detail sentence: `cloud sync reported a batch deleting \(n) of \(total) snippets. Sync paused before completing this batch. Applied in full to the reviewed library state, it keeps at least \(remaining) snippets; up to \(allowed) deletions may be applied without confirmation` (`snippets/Core/DeletionGuard.swift:39-78`).

**ALERT-RECOVERY-CONFIRM** (`snippets-ios/SyncResumeConfirmation.swift`): title = confirmation title; message = the status sentence, a blank line, then the action's explanation (`SF:74-105`); `Cancel` and the confirmation button.

Where a recovery action surfaces: LIB-SYNC-BANNER, the More menu's sync item, the first-fetch empty state button, pull to refresh, the SET-SYNC recovery row. When sync needs attention but has no recovery action, those places say `Open Sync Settings` instead (`SC:582-596`).

### 10.4 Triggers

Launch, return to foreground, a local change (debounced: 1 s, or Git pacing), pull to refresh, `Sync Now`, provider switch, and on Apple platforms push plus a six-hour health check. Android needs its own background scheduling; no parity requirement for push.

---

## 11. System integration

### 11.1 What iOS does (parity items)

| Integration | iOS behaviour | Android counterpart |
|---|---|---|
| URL scheme | `snippets://share?data=…` and `snippets://new?…`, registered as scheme `snippets` (`snippets-ios/Info-iOS.plist:10-15`). Delivered at launch or while running, always through LINK-REVIEW. No universal (https) links exist. | Intent filter for `snippets://share` and `snippets://new` on the main activity, routed to the same review dialog. |
| Backup file type | Exported type `com.khm.snippets.encrypted-backup`, extension `snippetsbackup`, MIME `application/vnd.khm.snippets.encrypted-backup` (`Info-iOS.plist:22-43`). The app does not register as an opener; files come in through the picker only. | Storage Access Framework open/create documents with the same extension and MIME type. |
| Import | System document picker, JSON and backup files | `ACTION_OPEN_DOCUMENT` |
| Export | System save picker fed from a private temporary file | `ACTION_CREATE_DOCUMENT`, write straight to the chosen URI |
| Share out | Share sheet with the share link; Git public key; recovery kit text | Android Sharesheet |
| Clipboard | Ordinary write; secure write local-only with 60 s expiry; recovery key 5 min; Git code and account key 2 min | Android has no clipboard expiry or local-only flag: mark the clip `EXTRA_IS_SENSITIVE` and clear it after the interval only if the app's own clip is still current (the old app did this for 2 minutes, `OA:2269-2291`). |
| Authentication | Device-owner authentication with a reason string; `NSFaceIDUsageDescription`: `Snippets uses Face ID to reveal secure snippets and approve encrypted library key transfers.` | `BiometricPrompt` with device-credential fallback; reason as the prompt subtitle. |
| Camera | QR scanning for Snippets Cloud only: `Snippets uses the camera only to scan one-time device invitations and offline recovery kits.` | Code scanner without a camera permission where possible (the old app used the Google code scanner). |
| Capture protection | Protected rendering of secure bodies; recovery code sheet hidden when inactive | `FLAG_SECURE` on windows showing secure plaintext, recovery keys and codes. |
| Keyboards | Third-party keyboards blocked app-wide | Secure body field: no personalised learning, no suggestions, visible-password style input; cannot block third-party IMEs (see Open questions). |
| Background | Flush, lock, push a waiting Git change under a background task | Lifecycle `onStop`: same three steps; WorkManager for the push. |
| Print | Recovery kit `Print` | Android print framework, or drop (Cloud only). |
| Hardware keyboard | iPad shortcut set (section 3.6) | Same shortcuts on tablets and with attached keyboards (Ctrl in place of ⌘). |

### 11.2 iOS-only items

- iCloud sync, iCloud Keychain key sharing and every string that mentions them.
- Liquid-glass bars, the title-row More button geometry, pointer hover effects.
- Blocking keyboard extensions.
- Writing Tools: an Apple system text feature. It is disabled on secure bodies and otherwise left to the system; there is nothing to port.
- Push-triggered sync and the six-hour health check.

### 11.3 What the old Android app did

- `ACTION_PROCESS_TEXT` activity labelled `Insert Snippet` (section 12.3).
- Copy with the clip marked sensitive; share of the snippet's raw content as `text/plain` through a chooser titled `Share snippet` (`OA:2293-2311`). Note the difference: iOS shares a `snippets://share` link, the old Android app shared the text itself.
- No deep links, no import/export, no document types, no `ACTION_SEND` receiver.
- Splash screen, adaptive icon with monochrome layer, backups disabled (`app/src/main/AndroidManifest.xml`).

### 11.4 Android candidates (not parity; decide separately)

1. `ACTION_PROCESS_TEXT` **Insert Snippet**: in the plan as the one Android-only feature (`snippets-android/docs/PLAN.md:15-16`). Treat as P0, specified in 12.3.
2. `ACTION_SEND` (`text/plain`) receiver: "Save to Snippets" creates an entry from shared text, the natural counterpart of the Mac Services item and of New from Clipboard.
3. Share the resolved text itself in addition to the link ("Share Text" vs "Share Link").
4. Static app shortcuts: New Snippet, New from Clipboard, Search.
5. Quick Settings tile opening search or New from Clipboard.
6. `ACTION_VIEW` for `.snippetsbackup` and Snippets JSON so a file can be opened from a file manager.
7. Home-screen widget with pinned entries (ordinary only).
8. Predictive back, edge-to-edge, dynamic colour, themed icon: platform hygiene the old app partly had.
9. Autofill service or IME: explicitly out of scope (`docs/android/app-plan.md:229-233`).

---

## 12. Old Android app delta

### 12.1 What it had

| Area | Old Android behaviour | Source |
|---|---|---|
| Layout | Two panes when width ≥ 840 dp and height ≥ 480 dp; otherwise single pane with back handling | `OA:238-243`, `472-473` |
| Tablet detail placeholder | `Tap a snippet to copy` / `Open its menu to edit or share.` | `OA:451-453` |
| Titles | `Snippets`, `New snippet`, `Edit snippet`, `Snippets Cloud`, `Cloud & storage` / `Storage` | `OA:245-249` |
| Library header | `1 snippet · Tap a row to copy` / `${n} snippets · Tap a row to copy` (and `Tap to copy · …` variants); with filters `${n} tags selected` and `Clear` | `OA:509-552` |
| Search | In-list field `Search snippets` with a clear button; filter icon with a count badge | `OA:631-654` |
| Row | Card: name (`Untitled snippet` when blank), keyword chip `\keyword`, first content line, up to four tag chips and `+N`, overflow menu `Edit`, `Share`; tap copies; toast `Copied` on Android 12L and lower (newer versions show the system confirmation) | `OA:775-829`, `2293-2303` |
| Tag filter sheet | `Filter by tags`, `Matches every selected tag`, `Clear`, `Done`, plus a `Search tags` field | `OA:933-959` |
| Empty states | `Your library is empty` / `Create a snippet to copy it anywhere.`; `No snippets match these tags`; `No matches` / `Try a different search or filter.`; `Clear tag filters` | `OA:734-746` |
| Editor | `Create snippet` / `Edit snippet`; fields `Name`, `Keyword`, `Content`, `Tags, comma separated`; switches `Enabled`, `Pinned`; buttons `Delete`, `Save` (explicit save) | `OA:1031-1093` |
| Sync notice | Banner `Snippets Cloud needs attention. Open Cloud & storage for details.`; loading state `Loading library` | `OA:564-575` |
| Tag identity and colours | Same folding as Apple and the same FNV-1a palette index, with Material-toned light and dark palettes | `app/src/main/java/com/khm/snippets/android/LibraryPresentation.kt:13-124` |
| Theme | Dynamic colour on Android 12+, fallback terracotta scheme; rounded shapes 8/12/18/24/32 dp | `app/src/main/java/com/khm/snippets/android/Theme.kt` |
| Storage | Device-bound AES-256-GCM store under Android Keystore; app data excluded from backup and device transfer | `README.md:627-629`; manifest |
| Tooling | Demo seed script `scripts/seed-android-demo.sh`; baseline profile module `baselineprofile/` | `README.md:735-737` |
| Snippets Cloud | Full account, pairing and recovery-kit UI (section 9.7) | `OA:1111-1941` |

### 12.2 What it lacked (all required now)

Opening secure snippets, vault and recovery key, placeholders, import/export and encrypted backup, Git sync, deep links, settings search, diagnostics, swipe actions, undo after delete, duplicate, pinned section, keyword suggestions and warnings, autosave.

### 12.3 PROCESS_TEXT flow, as built

(`app/src/main/java/com/khm/snippets/android/ProcessTextActivity.kt:34-93`)
1. The user selects text in another app and picks `Insert Snippet` from the selection menu.
2. A dialog-styled activity opens (excluded from recents) with the title `Insert Snippet` and a `Search` field prefilled with the selected text.
3. Results: all snippets when the query is blank, otherwise the search results; only **enabled** snippets are listed. Each card shows the name (`Untitled Snippet` when blank) and two lines of content. Empty: `No snippets`.
4. Tapping a result: when the selection is editable the content replaces it (`EXTRA_PROCESS_TEXT`, `RESULT_OK`); when it is read-only the content is copied instead and the activity returns `RESULT_CANCELED`.

Gaps to close in the rebuild: resolve placeholders before returning; require authentication for a secure result and prefer returning it directly over the clipboard; tell the user when the result was copied rather than inserted; show keyword and secure state in the rows; handle the vault being locked; bound the input size; never log or keep the selected text (`docs/android/app-plan.md:241-262`).

### 12.4 Must not regress

1. Tap-to-copy as the primary row action on phones.
2. Two-pane layout on large screens, single pane with correct system back on phones.
3. AND tag filtering with counts, visible active-filter count, one-tap clear.
4. Tag search inside the filter sheet (an Android extra over iOS).
5. Tag colours stable across platforms.
6. Sensitive clipboard marking and no duplicate "Copied" toast on Android 13+.
7. `Insert Snippet` text action with read-only fallback.
8. Backups and device transfer disabled; encrypted local store; cleartext traffic off.
9. Dynamic colour, themed (monochrome) launcher icon, splash screen.
10. Baseline profile and the demo seeding path for screenshots and tests.
11. Persistent, typed error cards for account and sync problems rather than transient toasts.
12. Secure records written by other devices survive untouched even when this device cannot open them.

---

## 13. Parity checklist

Tags: `P0` core, `P1` expected for parity, `P2` polish, `N/A` iOS-only with the reason.

**Library**
1. `P0` Library screen titled `Snippets` listing ordinary and secure entries together.
2. `P0` Order: pinned first, then newest created first, stable by id.
3. `P0` `Pinned` section header when any match is pinned.
4. `P0` Row shows name with fallback to first content line, then `Untitled Snippet`.
5. `P0` Row second line follows the keyword / first-line / `No content` rules.
6. `P0` Secure rows show `Secure · \keyword` or `Secure snippet` and never the body.
7. `P0` Disabled rows show the `Disabled · ` prefix and dimmed text.
8. `P0` Row glyphs for secure, pinned, disabled.
9. `P1` Row shows up to three tag pills and `+N`.
10. `P1` Row shows relative updated time (time, `Yesterday`, weekday, month-day).
11. `P0` Tap row copies with placeholders resolved.
12. `P0` Copy toast `Copied “name”.`
13. `P0` Empty-content toast `“name” has no content to copy.`
14. `P1` Haptic on copy; lighter haptic when nothing was copied.
15. `P0` Swipe one way reveals Edit; full swipe opens the editor.
16. `P0` Swipe the other way reveals Pin/Unpin and Delete; Delete needs a tap.
17. `P1` Only one row open at a time; scroll or tap closes it.
18. `P1` Haptic when the full-swipe action arms and disarms.
19. `P0` Long-press menu: Copy, Edit, Pin/Unpin, Duplicate (ordinary), Delete.
20. `P0` New snippet button opens a blank editor with the body focused.
21. `P0` A blank new entry is discarded when left blank.
22. `P0` More menu: New from Clipboard, Transfer (Import, Export for Sharing, Encrypted Backup), sync action, Settings.
23. `P0` New from Clipboard creates an entry from clipboard text.
24. `P0` `Clipboard Is Empty` alert.
25. `P0` Pin and unpin from swipe, menu and editor, for ordinary and secure entries.
26. `P0` Delete ordinary entry immediately with an `Undo` toast.
27. `P0` Undo restores only that entry, in place, once.
28. `P0` Delete secure entry asks for confirmation; no undo.
29. `P0` Duplicate: ` Copy` suffix, disabled when the source had an active keyword, opens the copy.
30. `P1` One-time gesture tip toast after the first copy.
31. `P1` Pull to refresh runs a sync round and follows its real duration.
32. `P1` Pull to refresh with sync off asks before turning sync on.
33. `P2` Large title collapsing on scroll; static empty screens do not scroll.

**Search and tags**
34. `P0` Search field `Search snippets`.
35. `P0` Search covers name, keyword, tags and ordinary content.
36. `P0` Case- and diacritic-insensitive matching.
37. `P1` Fuzzy subsequence on name, keyword and tags; contiguous on content.
38. `P0` Secure bodies never searchable.
39. `P0` Search results keep library order.
40. `P1` Search runs off the main thread and drops stale results.
41. `P0` Tag filter sheet listing every tag with its count.
42. `P0` Multiple tags combine with AND; footer says so.
43. `P0` Tag identity folds case and diacritics with a fixed locale.
44. `P0` Filter button shows the active count.
45. `P0` `Clear` in the sheet and `Clear Filters` in the empty state.
46. `P1` Sheet title shows the active count.
47. `P1` `No Tags Yet` state.
48. `P0` Empty states `No Results` and `No Snippets Match` with their messages.
49. `P1` Filters for vanished tags drop silently.
50. `P1` Stable tag colours from the shared hash.
51. `P2` Tag search inside the filter sheet (old Android extra).

**Editor**
52. `P0` Editor with Name, Snippet (body), Keyword, Tags, Enabled, Secure.
53. `P0` Autosave on every change; no Save button.
54. `P0` Title follows the display name.
55. `P0` Name placeholder shows the first content line when the name is blank.
56. `P0` Body placeholder `Paste or type`; monospaced body.
57. `P0` Keyword sanitised as typed; `\` prefix shown, never stored.
58. `P0` Keyword warnings: missing, disabled, invalid characters, duplicate, blocked by longer, blocks shorter.
59. `P1` Warning indicator in the field with a `Keyword Warning` dialog.
60. `P1` Up to three keyword suggestions when the keyword is empty.
61. `P1` `Existing · …` reference line while typing a keyword.
62. `P2` Space or Tab completes the next unambiguous keyword part.
63. `P0` Tag token field with removable tokens.
64. `P0` Comma or Enter commits a tag; paste with commas splits.
65. `P1` Backspace on empty input removes the last tag.
66. `P1` Tag completion chips from existing tags.
67. `P0` Tags normalised and de-duplicated.
68. `P0` Enabled switch with `Allow this keyword to expand on Mac.`
69. `P0` Placeholder preview for ordinary entries, expandable, with `[Clipboard content]`.
70. `P0` Footer `Saved <date> at <time>`.
71. `P0` Copy from the editor with footer feedback.
72. `P0` Editor menu: Pin/Unpin, Share, Duplicate, Delete.
73. `P1` Save failure shown in red, scrolled into view and announced.
74. `P1` Remote changes merge into the open editor without moving the caret.
75. `P1` Content / Details switch on phones that stays above the keyboard.
76. `P1` Single-form editor on tablets with a `Preview` section.
77. `P2` One undo step per focus session (tablet Ctrl+Z).

**Secure snippets**
78. `P0` Make an entry secure from the editor.
79. `P0` First use creates the vault and shows the recovery key once.
80. `P0` `Copy & Continue` / `I’ve Saved It` / `Cancel` on the recovery key dialog.
81. `P0` Recovery key copy is sensitive and cleared after 5 minutes.
82. `P0` Authentication prompt with a specific reason for every secure action.
83. `P0` Locked editor state with `Reveal Secure Content`.
84. `P0` Revealed body editable; saved 0.3 s after typing and on blur.
85. `P0` Body re-locks on leaving the editor, on background, on vault lock and when a dialog opens.
86. `P0` Session limits: 5 minutes idle, 30 minutes maximum.
87. `P0` Secure copy authenticates every time.
88. `P0` Secure clipboard marked sensitive and cleared after 60 seconds; toast says so.
89. `P0` Make ordinary with confirmation and authentication.
90. `P0` Secure entries excluded from share, share link, duplicate and plain export.
91. `P0` Secure body absent from screenshots, recents and screen recording.
92. `P0` Secure body absent from the accessibility tree, with the stand-in element and its three values.
93. `P0` Secure body field allows only delete, paste, select, select all.
94. `P0` No placeholder preview for secure entries.
95. `P0` Settings ▸ Secure Snippets status row with its three states.
96. `P1` Key Storage row with Android-appropriate copy.
97. `P0` `Lock Now`.
98. `P0` `Add Recovery Key` when the vault has none.
99. `P0` `Restore with Recovery Key` with typo-aware errors.
100. `P0` `Remove Secure Snippets from This Device`, blocked while sync is on.
101. `P0` Secure metadata (name, keyword, tags, pin, enabled) editable without unlocking.
102. `P1` Capture-blocked and protected-display-failed messages.
103. `N/A` Blocking third-party keyboards app-wide: no Android API; mitigate per field.

**Links, share, import, export**
104. `P0` Share an ordinary entry as a `snippets://share` link through the Sharesheet.
105. `P1` Copy Share Link with toast `Copied share link.`
106. `P0` Open `snippets://share` links through a review dialog.
107. `P0` Open `snippets://new` links through a review dialog.
108. `P0` Review dialog shows name, keyword, tags and a 280-character preview.
109. `P0` Imported or created entries arrive disabled and open in the editor.
110. `P0` Replacement is called out and is a destructive action.
111. `P0` Stale review refused when the library changed.
112. `P0` Link error messages (unsupported, missing, malformed, newer version).
113. `P0` Import JSON (array, wrapped, Raycast) with merge by id then keyword.
114. `P1` Raycast `!` keyword choice.
115. `P0` Import size limits and error messages.
116. `P0` Export for Sharing: ordinary entries only, `Snippets-Export.json`, count toast.
117. `P0` Encrypted backup export with password rules (≥ 12, confirm).
118. `P0` Encrypted backup import with password prompt and all failure messages.
119. `P0` Backup file extension `.snippetsbackup` and MIME type.
120. `P1` Progress toasts (`Reading import…`, `Preparing encrypted backup…`, `Opening encrypted backup…`).
121. `P1` Quarantined-library recovery through JSON or backup, with the two confirmations.
122. `P1` `Library Recovery Required` empty state.

**Settings**
123. `P0` Settings sheet with sections `Library` (Sync, Secure Snippets, Backup) and `Support` (Diagnostics, About).
124. `P1` Settings search over the fixed catalog with the ranking rules.
125. `P1` Search result opens the pane and highlights the row.
126. `P0` Sync pane: provider row, `Sync this library` switch, `Status`, `Sync Now` or recovery row.
127. `P0` Provider chooser with the current provider marked.
128. `P0` `Switch and Sync` confirmation with counts and destination.
129. `P0` Switch progress and `Switch Needs Attention`.
130. `P0` Backup pane with three rows and footer.
131. `P1` Diagnostics pane: `Persistent Logs`, `Export Diagnostic Logs`, `Delete Diagnostic Logs`.
132. `P1` Plaintext warning before export, listing what Android logs contain.
133. `P1` Delete logs confirmation.
134. `P1` Log retention limits (14 days, 64 files, 24 MiB).
135. `P0` About: icon, name, `Version x (build)`, GitHub and license links.
136. `P1` Two-column settings on tablets.

**Git sync**
137. `P0` Git screen with intro line and Repository / Branch / User Name / Access Token fields.
138. `P0` SSH address hides token fields and shows the device key section.
139. `P0` Host-specific token help and `Create a Token on <host>…` link.
140. `P0` Device SSH public key with Copy, Share and deploy-key link.
141. `P0` Host key confirmation with fingerprint, including the "matches published" variant.
142. `P0` Changed host key warning; never accepted silently.
143. `P0` Foreign branch offer `Use Branch “snippets”`.
144. `P0` Create encrypted library; `Plain Text Instead…` with second confirmation.
145. `P0` Public repository refusal and unknown-visibility confirmation for plain text.
146. `P0` Recovery code shown once, monospaced, with timed sensitive copy, hidden from recents, not dismissable by gesture.
147. `P0` Join an existing library with the stored key or the recovery code; wrong code re-prompts.
148. `P0` Join plain-text consent.
149. `P0` Connected summary with mode, transport and anything needing attention.
150. `P0` `Sync Now` / `Switch and Sync`.
151. `P0` `Reconnect…` and `Reconnect and Merge`.
152. `P0` `Set Up Secure Snippets…` with recovery code entry.
153. `P0` `New Recovery Code…` with owner authentication.
154. `P0` `Replace Keys…` with owner authentication and the destructive confirmation.
155. `P0` `Change Address or Token…` / `Hide Connection Details`; empty token keeps the saved one.
156. `P0` `Remove from This <device>…`, disabled while Git is active.
157. `P0` Navigation locked while a step runs; status line announced.
158. `P0` Every setup failure message in 8.6.
159. `P0` Round pacing: 30 s / 120 s, push on background.
160. `P0` Plain-text mode pinned; a changed mode stops sync.
161. `N/A` macOS ssh-agent and known_hosts copy: Mac only.

**Sync status**
162. `P0` Status sentence for every state in 10.1.
163. `P0` Library sync banner with state text and icon.
164. `P0` Banner becomes a button when a recovery action exists.
165. `P0` First-fetch empty states (`Fetching Your Library`, `Library Hasn’t Been Fetched`).
166. `P0` Halts with reason, guidance and typed recovery action.
167. `P0` Confirmation dialogs for deletions, account change, restore, take over.
168. `P0` Deletion guard review.
169. `P0` `Open Sync Settings` wherever sync needs attention without a recovery action.
170. `P0` Conflict copies appear as disabled entries tagged `conflict`.
171. `P1` Secure conflict waiting message.
172. `P1` Background sync scheduling suitable for Android.
173. `N/A` iCloud provider, CloudKit account-change halts, push-triggered sync: Apple services.

**Snippets Cloud (flagged)**
174. `P1` Account screen with Account, Sync, Security, Account Actions.
175. `P1` Create account and Save Your Account Key acknowledgement.
176. `P1` Sign in with account key, with validation and rate-limit countdown.
177. `P1` Sign in with another device: QR, confirmation code, countdown, copy request text.
178. `P1` Unlock choices: approved device, scan recovery QR, enter recovery code, I have neither.
179. `P1` Pairing wait screen with countdown, Check Again, Cancel Pairing.
180. `P1` Approve a device with code comparison and authentication.
181. `P1` Recovery kit: QR, long code, copy, share, verify final 8 characters.
182. `P1` Recovery code entry with 52-character progress.
183. `P1` Show account key after authentication; message when signed in by another device.
184. `P1` Change account, change library, disconnect with the recovery check line.
185. `P1` Titled problem cards from the old Android mapping.
186. `P2` Print recovery kit.

**Platform and quality**
187. `P0` `Insert Snippet` text action with replace and read-only copy fallback (Android only).
188. `P0` Text action resolves placeholders and authenticates for secure results.
189. `P0` Phone and tablet layouts (two panes ≥ 840 dp).
190. `P1` Tablet list: selection highlight, Enter copies, flat list, tag chips.
191. `P1` Tablet context menu extras: Disable/Enable, Make Secure/Ordinary, Copy Share Link.
192. `P1` Hardware keyboard shortcuts and shortcut panel.
193. `P0` Light and dark themes.
194. `P0` Font scaling up to the largest sizes without clipped actions.
195. `P0` TalkBack: row label, state description, custom actions Copy, Edit, Pin, Delete.
196. `P0` Toast component: 3.5 s, longer with an action and with a screen reader, single-use action.
197. `P1` Reduce-motion behaviour for pane and swipe animations.
198. `P0` Flush, lock and push on leaving the foreground.
199. `P0` Test launch mode with temporary storage and sync off.
200. `P1` Demo seed and baseline profile.
201. `N/A` Liquid-glass materials, pointer hover, title-row button geometry: iOS visual system.
202. `N/A` Mac expansion, picker, clipboard history, CLI, usage ranking: Mac features.

---

## 14. Brand notes

### 14.1 Colour

**iOS** (`snippets-ios/AppTheme.swift:3-26`) uses system colours, not custom hex values:

| Role | iOS colour | Approximate sRGB, light / dark |
|---|---|---|
| Tint, links, primary actions, pin glyph on phone | `systemIndigo` | `#5856D6` / `#5E5CE6` |
| Pin dot (iPad) | `systemYellow` | `#FFCC00` / `#FFD60A` |
| Enabled dot | `systemGreen` | `#34C759` / `#30D158` |
| Warning, secure lock glyph | `systemOrange` | `#FF9500` / `#FF9F0A` |
| Destructive | `systemRed` | `#FF3B30` / `#FF453A` |
| Selected row | indigo at 13 % (light), white at 14 % (dark); higher contrast: indigo at 26 % / 34 % | — |
| Preview surface | secondary label at 7.5 % | — |
| Editor surface | system background (light), secondary system background (dark) | — |

The approximate values are Apple's published defaults, not constants in this repository. Screens are near-black in dark mode with dark grey rounded field surfaces (see screenshots).

Tag palette order (index from the shared hash): red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown. iOS mutes them (saturation × 0.65 and brightness × 0.72 in light; saturation × 0.5 in dark) and fills pills at 13 % alpha.

**Old Android** (`app/src/main/java/com/khm/snippets/android/Theme.kt:21-53`): dynamic colour on Android 12+, otherwise a terracotta scheme.

| Token | Light | Dark |
|---|---|---|
| primary | `#8B3A16` | `#FFB68F` |
| onPrimary | `#FFFFFF` | `#522000` |
| primaryContainer | `#FFDBCA` | `#713000` |
| secondary | `#765849` | `#E7BFAE` |
| tertiary | `#665F2A` | `#D2C96F` |
| background / surface | `#FFF8F6` | `#1B110D` |
| onSurface | `#231914` | `#F2DFD7` |
| surfaceVariant | `#F4DED5` | `#55433C` |
| outline | `#88736A` | `#A38D83` |

Tag colours, light: `#BA1A1A #A63C00 #785900 #2D6A35 #006B5B #006A6A #00677A #005AC1 #4F56A9 #7B4E9D #A43A69 #765847`; dark: `#FFB4AB #FFB691 #F5C344 #91D69A #76D9C3 #80D5D5 #5DD5EF #A9C7FF #BEC2FF #E9B7FF #FFB0CD #E5BFA9` (`LibraryPresentation.kt:96-124`).

The two platforms disagree on the brand colour (indigo vs terracotta). The icon is indigo, violet and magenta. See Open questions.

### 14.2 Icon and splash assets

| Asset | Path |
|---|---|
| Launcher foreground, 432 × 432 PNG (rounded square, blue-to-magenta gradient, stacked documents with `</>`, scissors on a dashed cut line) | `app/src/main/res/drawable-nodpi/snippets_app_icon.png` |
| Monochrome layer | `app/src/main/res/drawable/ic_launcher_monochrome.xml` |
| Adaptive icon definitions | `app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`, `mipmap-anydpi-v33/ic_launcher.xml` |
| Legacy icons | `app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` |
| Icon background | `#080711` (`app/src/main/res/values/colors.xml`) |
| Splash background | `#FFF8F4` light, `#101114` dark (`values/colors.xml`, `values-night/colors.xml`) |
| Splash theme | `Theme.Snippets.Starting` in `app/src/main/res/values/styles.xml` |
| Vector glyphs | `app/src/main/res/drawable/ic_{add,arrow_back,close,cloud,content_copy,edit,filter,more_vert,phone,refresh,search,share}.xml` |
| Apple app icon set | `snippets/Assets.xcassets` |
| Reference screenshots | `docs/images/iphone-library-dark.png`, `iphone-editor-dark.png`, `ipad-landscape-workspace-dark.png`, `ipad-landscape-placeholders-dark.png`, `ipad-landscape-shortcuts-dark.png`, `readme-hero.png` |

### 14.3 Typography and iconography

- System sans throughout; monospaced for the body, the keyword prefix, the placeholder preview, the existing-keyword line, SSH keys, recovery keys and codes.
- iOS sizes (all scale with the system text size): row name 17 semibold, row detail 15, date 13, tag pill 11 medium, toast 14 medium, footer 12, empty title 20 bold, empty message 15, recovery code 24 semibold mono (`PL:1111-1124`, `1825-1831`; `GV:1214`).
- Icons are simple outline glyphs: ellipsis-in-circle, plus, funnel, magnifier, pencil, pin, trash, lock, two documents, tag, gear, circular arrows, shield with exclamation, key.
- Feel: quiet, dense, utility-first. Content before chrome; colour is reserved for tags, state and the single tint.

### 14.4 Tone of voice

- Title Case for dialog titles and buttons (`Make This Snippet Ordinary?`, `Create Library`); sentence case for body text and row details.
- Names the object and the consequence, and says what is not affected: `Nothing in the repository is deleted.`, `Your libraries were not deleted.`, `Nothing was created.`
- Errors start with `Couldn’t …` and state the next step. Never blames the user.
- Security copy is plain and specific: `Snippets can’t show it again. Store it in your password manager.`
- Destructive buttons repeat the verb (`Delete`, `Remove`, `Replace Keys`, `Trust New Key`).
- Uses `…` for menu items that open another step and for in-progress states.
- Typographic apostrophes and quotes; snippet names in `“ ”`.
- No exclamation marks, no humour, no marketing language.

---

## Open questions

1. **Brand colour.** iOS tints with indigo, the old Android app used terracotta or dynamic colour, and the icon is blue-violet-magenta. Which is the Android brand colour, and does dynamic colour stay the default?
2. **Device words in copy.** Strings name `iPhone`/`iPad` (`Bring Your Library to iPhone`, `This iPhone’s SSH Key`, `Remove from This iPhone…`). Android wording: "this phone", "this tablet", or "this device"?
3. **Empty-library call to action.** iOS offers `Connect \(providerName)` for the selected provider, which defaults to iCloud. With no iCloud, what does a fresh Android install offer: nothing, `Connect Git`, or a link into Sync settings? And the hard-coded toast `Connecting to iCloud…` (`PR:196`) needs an Android replacement.
4. **`Sync this library` detail.** The single-provider text is `Encrypted before it is sent to iCloud.` (`SV:544`). Android text when only Git is available?
5. **Key Storage row.** Both iOS strings refer to iCloud Keychain. What should Android say, and is the row needed at all?
6. **Recovery-key copy.** `…if the shared Keychain key is lost.` (`PE:1153`) is Apple-specific.
7. **`Enabled` on Android.** The detail says `Allow this keyword to expand on Mac.` Does Enabled also govern the `Insert Snippet` text action (the old app listed only enabled snippets) and should the copy say so?
8. **Delete on tablets.** iPhone deletes with an Undo toast; iPad confirms first. Which does an Android tablet do?
9. **iPhone-only vs iPad-only actions.** Enable/Disable, Make Secure and Copy Share Link exist in the iPad context menu but not on iPhone. Should Android phones get them?
10. **Share payload.** iOS shares a `snippets://` link; the old Android app shared the text. Offer both?
11. **Cancelled authentication.** Cancelling the prompt for a secure copy currently produces a `Couldn’t Copy Snippet` alert with a lower-case fragment (`authentication was cancelled`). Git flows treat a cancel as silent (`GV:1032-1035`). Android should probably be silent everywhere.
12. **Lower-case error bodies.** Vault and recovery-key errors are sentence fragments (`the vault is locked`, `that recovery key has a typo in it`). Keep verbatim or rewrite as sentences for Android?
13. **iPad delete title** has a stray space before the question mark (`Delete “\(name)” ?`, `MS:525`). Treat as a typo.
14. **Secure clipboard expiry.** Android cannot expire a clip. Is "clear after 60 s if still ours" acceptable, and should the toast keep the wording `Secure clipboard expires in 60 seconds.`?
15. **Third-party keyboards.** iOS blocks them; Android cannot. Is per-field hardening enough, or should the secure editor warn?
16. **Accessibility of secure bodies.** iOS hides revealed secure text from all assistive technology by design. Android can keep TalkBack while blocking screenshots; follow iOS exactly or allow TalkBack?
17. **Diagnostics notice.** The iOS export notice lists Mac and CloudKit fields. Who signs off the Android field list?
18. **`Set Up Secure Snippets` search entry** has no row of its own on iOS (it lands on the status row). Add an explicit setup row on Android?
19. **Git, SSH on Android.** Which host-key and key-exchange algorithms will the Kotlin client support, and does the "only RSA host keys" message still apply?
20. **Git key syncing sentence.** The recovery-code sheet adds an iCloud Keychain sentence on Apple. Confirm it is simply omitted on Android.
21. **Snippets Cloud copy source.** iOS and old Android differ in places (for example `Scan a new device invitation` plus `Paste invitation` on Android only; `Face ID or Touch ID` in the approval text). Which set is canonical for the rebuild?
22. **State restoration.** iOS does not restore the open editor after process death. The old Android plan asked for draft recovery (`docs/android/app-plan.md:118`). Required?
23. **Sync status when Git is selected but never connected.** Turning on `Sync this library` leads to `…no repository is connected on this device…`. Should the switch instead open the Git screen?
24. **Conflict copies.** There is no dedicated badge or resolution UI on iOS, only the `conflict` tag and the name suffix. Is that enough for Android?
25. **Universal links.** None exist. Should Android claim an https App Link for sharing, given that `snippets://` links are not clickable in most chat apps?
