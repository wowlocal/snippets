# Screens: library and editor

Covers inventory IDs LIB, LIB-MORE, LIB-FILTER, LIB-ROW-MENU, LIB-EMPTY-*, LIB-SYNC-BANNER, EDIT, EDIT-MORE, ALERT-DELETE-SECURE, ALERT-CLIP-EMPTY, ALERT-SYNC-OPT-IN, SHORTCUTS, TOAST-*. Secure flows inside the editor are in `screens-secure.md`. Components are in `components.md` (cited as C§n); tokens and rules in `DESIGN.md`.

Strings in backticks are final Android copy. `%s`, `%d` are format arguments. *(Android)* marks strings without an iOS counterpart. §9 lists every string changed from iOS.

---

## 1. LIB — `library`

Purpose: find an entry and copy it with one tap; reach everything else.

### 1.1 Phone layout (compact and medium)

```
┌────────────────────────────────────────────────┐
│ status bar (transparent)                       │
│ ┌────────────────────────────────────────────┐ │
│ │ [search] Search snippets            [⋮]    │ │  LibrarySearchBar (C§4.1)            library.search
│ └────────────────────────────────────────────┘ │
│ [≡] (• work 12) (• links 7) (• personal 5) →   │  TagFilterRow (C§3.2), only with tags library.filter
│ ┌ countdown row, only after a secure copy ───┐ │  C§10                                 countdown.row
│ ├────────────────────────────────────────────┤ │  ── everything below scrolls ──
│ [cloud_done] Synced at 9:04 PM                 │  SyncStatusRow / Review card (C§7)   library.sync-row
│ Pinned                                         │  header (C§5)                        library.header.pinned
│ Meeting room                    [pin] 9:02 PM ✎│  SnippetRow (C§1)                    library.row.<id>
│ \meet  https://meet.example.com/design-rev…    │
│ (work) (links)                                 │
│ ────────────────────────────────────────────── │  group divider
│ Atlas API token                [lock] Yesterday✎│
│ \atlas-token  Secure snippet                   │
│ (work) (tokens)                                │
│ Quick reply                           Mon     ✎│
│ \reply  Thanks for reaching out. I will take…  │
│                 42 snippets                    │  footer (C§5)                        library.count
│                                 [+ New Snippet]│  FAB (C§18)                          library.fab
│ navigation bar inset (list scrolls underneath) │
└────────────────────────────────────────────────┘
```

- Root: `Scaffold` (snackbar host, FAB) → `PullToRefreshBox` → `LazyColumn` (`library.list`). Pane title `Snippets`.
- Medium width: search bar, filter row and list are centred at max width 640 dp.

### 1.2 Two-pane layout (expanded and larger)

```
┌──────────────────────────────┬──────────────────────────────────────────────────────┐
│ ┌──────────────────────────┐ │  Project brief                          [copy] [⋮]   │
│ │ [search] Search snippets⋮│ │ ──────────────────────────────────────────────────── │
│ └──────────────────────────┘ │  (editor form, §6.9)                                 │
│ [≡] (work 12) (links 7) →    │                                                      │
│ [cloud_done] Synced at 9:04  │                                                      │
│ Pinned                       │                                                      │
│ ╭──────────────────────────╮ │                                                      │
│ │ Project brief   8:23 PM ⧉│ │  selected row: secondaryContainer                    │
│ │ \brief  PROJECT ATLAS    │ │                                                      │
│ ╰──────────────────────────╯ │                                                      │
│ Meeting notes     9:04 PM  ⧉ │                                                      │
│ \notes  Meeting notes — {d…  │                                                      │
│               [+ New Snippet]│                                                      │
└──────────────────────────────┴──────────────────────────────────────────────────────┘
   list pane 360 / 400 dp                         detail pane
```

Differences from the phone layout:

| Aspect | Two-pane behaviour |
|---|---|
| Row tap | Selects the entry and shows it in the detail pane. A secure entry opens locked; it does not authenticate on selection |
| Copy | Row trailing `content_copy` button, Enter with a row focused, or the detail top bar's Copy |
| Swipes | Off |
| Row menu | Tablet set (§4) |
| List | Same row component, same `Pinned` header and footer |
| FAB | Inside the list pane, bottom-end of the pane |
| Nothing selected | Detail pane shows the empty state `editor.empty`: glyph `description`, title `Select a snippet`, message `Choose a snippet from the list or create a new one.` |
| First launch on a large window | Nothing is selected; no auto-selection |
| Selection after delete | The next row (or the previous one when the last was deleted); none when the list is empty |
| Keyboard | §8 |

---

## 2. Library behaviour

### 2.1 Order, sections, search, filters

- Order: pinned first, then newest created first, then id. Editing does not move an entry; pinning does. Ordinary and secure entries are interleaved. Search and filters keep this order; there is no relevance ranking.
- `Pinned` header above pinned matches when any visible entry is pinned; no header otherwise.
- Search (`Search snippets`): names, keywords, tags and ordinary content; case- and diacritic-insensitive; fuzzy subsequence on name, keyword and tags; contiguous substring on content; secure bodies are never searched, also while a secure editor is revealed. Results update as typed, computed off the main thread, stale results dropped. Matches are highlighted (C§4.2).
- Tag filters: AND; tag identity folds case and diacritics with a fixed locale (`Locale.ROOT` rules as in the core); filters for tags that no longer exist drop silently on reload; filters and query are not persisted across cold starts.
- Search and filters combine with AND.
- Accepting an incoming link clears the query and filters before the new entry opens.

### 2.2 Creating

| Trigger | Result |
|---|---|
| FAB `New Snippet` (tag `library.fab`; description `New snippet`), Ctrl+N, launcher shortcut | Creates a blank entry (reusing an existing blank draft) and opens `editor/{id}` on the `Content` tab with the body focused and the IME shown |
| More ▸ `New from Clipboard`, Ctrl+Shift+N | Reads the clipboard now. Text present: creates an entry with that content and opens the editor, body focused. Empty or whitespace only: `dialog/clipboard-empty` |
| Leaving the editor with name, keyword, content and tags all blank | The draft is discarded silently |

The FAB is hidden while the IME is visible, while the library shows the first-run empty state, and on `process-text`.

### 2.3 Row actions

| Action | Ordinary entry | Secure entry |
|---|---|---|
| Copy | Resolve placeholders (`{clipboard}` is read at this moment), write the clip, row `Copied` state, haptic `Confirm`. Resolved text empty: snackbar `“%s” has no content to copy.`, haptic `Reject`, nothing written | `BiometricPrompt` every time (`screens-secure.md` §2). On success: placeholders resolved, clip written with the sensitive flag, row `Copied` state, countdown row, haptic `Confirm`. Cancel: silent. Body empty: same snackbar |
| Edit | Open `editor/{id}` | Same; the body opens locked |
| Pin / Unpin | Toggle; the row animates to its place; haptic `ToggleOn` / `ToggleOff` | Same (no authentication) |
| Duplicate | Name gets the suffix ` Copy` (a blank name stays blank); keyword, content, tags and pin are copied; the copy is created disabled when the source was enabled and has a keyword; it is inserted directly after the source and opens in the editor | Not offered |
| Delete | Removed at once; snackbar `Deleted “%s”.` with `Undo`; haptic `Confirm`. Undo restores exactly that entry at its original position, once, without reverting anything done in between | `dialog/delete-secure` (§7.1); then snackbar `Secure snippet deleted.` No undo |
| Disable / Enable (two-pane menu) | Toggle `Enabled` | Same |
| Make Secure / Make Ordinary (two-pane menu) | Same flows as the editor's `Secure` switch (`screens-secure.md` §4) | Same |
| Copy Share Link (two-pane menu) | Puts the `snippets://share?data=…` link on the clipboard; snackbar `Copied share link.` on API 28–32 | Not offered |

Disabled entries can be copied. An entry that no longer exists when the action runs: `dialog/error` `Couldn’t Copy Snippet` / `The snippet no longer exists.`

### 2.4 States

| State | Glyph | Title | Message | Actions | FAB |
|---|---|---|---|---|---|
| Empty, sync off (first run) | `description` | `Your Library Is Empty` | `Create a snippet, import a library, or set up sync to fetch the library from your other devices.` | `New Snippet` (Button) · `Import…` · `Set Up Sync` (or `Turn On %s Sync` when a provider is already set up) · note `Sync is optional. Everything works on this device without an account.` | hidden |
| Empty, sync on and has synced | `description` | `Your Library Is Empty` | `%s You can also create a snippet on this device.` (`%s` = status sentence) | none | shown |
| Empty, first fetch running | spinner | `Fetching Your Library` | `Checking %s for the library from your other devices.` or, before the first round starts, `Preparing the first %s fetch. Your local library will stay empty until it finishes.` | none | shown |
| Empty, first fetch stalled | `cloud_off` | `Library Hasn’t Been Fetched` | `The first fetch has not finished. %s` (`%s` = status sentence) | One button: the recovery action title, else `Open Sync Settings` when sync needs attention, else `Try Again` | shown |
| Library quarantined | `error` (`error` tint) | `Library Recovery Required` | `The ordinary snippet library could not be read and remains preserved. Import a complete Snippets JSON export, then review Sync and choose Check Again. %s` | `Import…` | hidden |
| Search, no match | `search_off` | `No Results` | `Try a different search.` · with filters: `Try changing the search or clearing a tag filter.` · note `Secure snippet bodies are not searched.` | with filters: `Clear Filters` | shown |
| Filters, no match | `filter_list` | `No Snippets Match` | `Clear a tag filter to see more snippets.` | `Clear Filters` | shown |
| Loading (store not ready, < 300 ms typical) | — | — | Nothing is drawn for the first 300 ms; after that a centred 24 dp spinner with description `Loading library` | — | hidden |

`%s` provider names: `Git`, `Snippets Cloud`. `Clear Filters` announces `Tag filters cleared`. The search bar, filter row and (when applicable) the sync row stay visible above every empty state except first run with sync off, where only the search bar shows.

### 2.5 Gestures and input

| Input | Compact / medium | Two-pane |
|---|---|---|
| Tap row | Copy | Select |
| Row trailing button | Edit | Copy |
| Swipe right | Edit (C§1.4) | — |
| Swipe left | Pin / Unpin (C§1.4) | — |
| Long-press, right-click | Row menu (§4) | Row menu (§4) |
| Pull down from the top | §2.8 | §2.8 (list pane) |
| Scroll | Closes a row mid-swipe; dismisses the IME (`imeNestedScroll` off; `keyboardController.hide()` on drag start) | Same |
| Tap sync row / card | `library/sync` sheet / card action | Same |

No multi-select and no drag reordering.

### 2.6 Sync row text (short forms)

| Sync state | Text | Form |
|---|---|---|
| Off, no recovery pending | (row hidden) | — |
| Enabled, transport not ready | `Preparing the first fetch…` (never fetched) / `Preparing sync…` | quiet |
| Syncing | `Fetching your library…` (first fetch) / `Syncing changes…` | quiet |
| Idle, first fetch not done | `Waiting to fetch your library…` | quiet |
| Idle, synced | `Synced at %s` (time today; date and time otherwise) | quiet |
| Idle, never synced | `%s on · Not synced yet` | quiet |
| Offline / unreachable | `First sync paused` (never fetched) / `%s unavailable` | quiet |
| Needs authentication, needs attention | the status sentence | Review card `Sync Needs Attention` |
| Waiting for the vault | the status sentence | Review card `Sync Is Waiting` |
| Halted, newer schema | `Update Snippets to resume sync` | Review card `Sync Stopped`, no button |
| Halted, other | the status sentence | Review card `Sync Stopped` |

Glyphs: C§7.1. Background sync changes update the row silently: no snackbar, no haptic, no announcement unless the row has accessibility focus.

### 2.7 Feedback

| Event | Feedback |
|---|---|
| Ordinary copy | Row `Copied` state + haptic. API 28–32 also snackbar `Copied “%s”.` |
| Secure copy | Row `Copied` state + countdown row `Copied “%1$s”. Clears in %2$s` + haptic |
| Nothing to copy | Snackbar `“%s” has no content to copy.` + haptic `Reject` |
| First successful copy ever on this install (compact / medium, touch exploration off) | 2.4 s later, once: snackbar `Tip: swipe right to edit, swipe left to pin. Touch and hold for more.` shown for 5 s |
| Pin / unpin | Haptic only |
| Delete | Snackbar with `Undo` (ordinary) or `Secure snippet deleted.` |
| Sync Now from the menu | Snackbar `Syncing…`; after confirming `Turn On %s Sync`: `Connecting to %s…` |
| Failures | `dialog/error` with the titles in §7.4 |

### 2.8 Pull to refresh

`PullToRefreshBox` with the M3 indicator (`PullToRefreshDefaults.Indicator`, container `surfaceContainerHigh`, colour `primary`). The indicator stays until the triggered work ends.

| Condition | Result |
|---|---|
| A recovery action is pending | Same as the Review card button: opens `sync/review` when the action needs confirmation, otherwise runs it |
| Sync on | One manual sync round (not paced) |
| Sync off, a provider is set up | `dialog/sync-opt-in` (§7.3); the indicator hides when the dialog opens |
| Sync off, no provider set up | `dialog/sync-opt-in`, set-up variant (§7.3) |

### 2.9 Accessibility

- Traversal: search field, More, filter button, chips, countdown row, sync row or card, `Pinned` heading, rows, footer, FAB.
- Rows: C§1.5. Sync row and card: C§7.2, C§7.3.
- The list announces result changes after typing stops for 1 s: `%d results` *(Android)* (polite).
- Empty-state title is a heading and receives focus when a search yields nothing while TalkBack is on.
- Swipe actions are reachable through row custom actions; pull to refresh through the More menu's sync item.

### 2.10 Test tags

`library.screen`, `library.search`, `library.search.clear`, `library.search.back`, `library.more`, `library.filter`, `library.filter.badge`, `library.tag-chip.<foldedTag>`, `library.list`, `library.header.pinned`, `library.row.<id>` (+ parts, C§1.6), `library.count`, `library.fab`, `library.sync-row`, `library.sync-card` (+ `.title`, `.text`, `.action`), `library.empty` (+ `.title`, `.message`, `.action`, `.action-2`, `.action-3`, `.note`), `library.loading`, `library.refresh` (pull indicator), `countdown.*`, `editor.empty` (two-pane placeholder).

---

## 3. LIB-MORE — `library/more`

`DropdownMenu` anchored to the search bar's `⋮`.

| # | Item | Icon | Tag | Action |
|---|---|---|---|---|
| 1 | `New from Clipboard` | `content_paste` | `menu.item.new-from-clipboard` | §2.2 |
| — | divider | | | |
| 2 | `Import` | `file_open` | `menu.item.import` | Import flow (`screens-settings-data.md` §8) |
| 3 | `Export for Sharing` | `file_save` | `menu.item.export` | Export flow (§9 there) |
| 4 | `Encrypted Backup` | `enhanced_encryption` | `menu.item.backup` | Backup flow (§10 there) |
| — | divider | | | |
| 5 | Sync action (below) | `sync` | `menu.item.sync` | below |
| 6 | `Keyboard Shortcuts` (only while a hardware keyboard is attached) | `keyboard` | `menu.item.shortcuts` | `Activity.requestShowKeyboardShortcuts()` |
| 7 | `Settings` | `settings` | `menu.item.settings` | `settings` |

Sync action by state, first match:

| State | Title | Action |
|---|---|---|
| Recovery action pending | The action title (`Confirm Deletions`, `Repair Sync`, …) | Same as the Review card button |
| Needs attention without an action | `Open Sync Settings` | `settings/sync` |
| Sync on | `Sync Now` | Manual round; snackbar `Syncing…` |
| Sync off, provider set up | `Turn On %s Sync` | `dialog/switch`, "sync currently off" variant (`screens-settings-data.md` §5); after confirming, snackbar `Connecting to %s…` |
| Sync off, nothing set up | `Set Up Sync` | `settings/sync` |

While the library is quarantined, items 3 and 4 stay available; `Encrypted Backup` then fails with the quarantine message (`screens-settings-data.md` §11).

---

## 4. LIB-ROW-MENU — `library/row-menu/{id}`

`DropdownMenu` at the touch point; haptic `LongPress`; the row keeps its pressed state while the menu is open.

| Compact / medium | Two-pane | Icon | Tag | Shown for |
|---|---|---|---|---|
| `Copy` | `Copy` | `content_copy` (secure: `lock`) | `menu.item.copy` | all |
| `Edit` | — | `edit` | `menu.item.edit` | all |
| `Pin` / `Unpin` | `Pin` / `Unpin` | `push_pin` | `menu.item.pin` | all |
| — | `Disable` / `Enable` | `pause_circle` | `menu.item.enabled` | all |
| — | `Make Secure` / `Make Ordinary` | `lock` / `lock_open` | `menu.item.secure` | all |
| `Duplicate` | `Duplicate` | `file_copy` | `menu.item.duplicate` | ordinary |
| — | `Copy Share Link` | `link` | `menu.item.copy-link` | ordinary |
| `Delete` | `Delete` | `delete` (`error`) | `menu.item.delete` | all |

Items that do not apply are absent. TalkBack: the same actions are row custom actions, so the menu is not needed.

---

## 5. Sync status sheet — `library/sync` *(Android)*

`ModalBottomSheet`, opened from the quiet sync row.

```
┌──────────────────────────────────────────────┐
│                    ───                       │
│ Sync                                         │  titleLarge                               sync-sheet.title
│ [commit] Git · github.com/me/library (main)  │  bodyLarge; Cloud: `Snippets Cloud · Library ID %s`   .provider
│ [glyph]  On. Last synced at 9:04 PM.         │  status sentence, bodyMedium              sync-sheet.status
│ ──────────────────────────────────────────── │
│ [ Sync Now ]                 Sync Settings   │  FilledTonalButton · TextButton           .sync-now · .settings
│ [warning] Review 2 Conflict Copies           │  ListItem, only when any entry has the tag `conflict`  .conflicts
└──────────────────────────────────────────────┘
```

| Element | Behaviour |
|---|---|
| `Sync Now` | Manual round; the button shows a spinner and reads `Syncing…` until it ends; the status line updates in place |
| `Sync Settings` | Closes the sheet, opens `settings/sync` |
| `Review %d Conflict Copies` (plural; `Review Conflict Copy` for one) | Closes the sheet, clears the query, sets the tag filter to `conflict` |

Accessibility: the status line is a polite live region while the sheet is open.

---

## 6. EDIT — `editor/{id}`

Purpose: view and change one entry. Every change is stored as it is made; there is no Save.

### 6.1 Phone layout (compact and medium): Content tab

```
┌────────────────────────────────────────────────┐
│ [←]  Meeting notes                 [copy] [⋮]  │  TopAppBar (small); title = display name    topbar.title
│ ┌───────────────────┬──────────────────────┐   │  SecondaryTabRow                             editor.tab.content
│ │      Content      │      Details  •      │   │  • = warning dot (6 dp, `warning`)           editor.tab.details
│ └━━━━━━━━━━━━━━━━━━━┴──────────────────────┘   │
│ ┌ countdown row / save-error banner ─────────┐ │  only when active
│ Name                                           │
│ ┌────────────────────────────────────────────┐ │
│ │ Meeting notes                              │ │  editor.name
│ └────────────────────────────────────────────┘ │
│ Snippet                                        │
│ ┌────────────────────────────────────────────┐ │
│ │ Meeting notes — {date:yyyy-MM-dd}          │ │  editor.body (monoBody, min height 200 dp,
│ │                                            │ │  grows with content; the tab scrolls)
│ │ Agenda                                     │ │
│ └────────────────────────────────────────────┘ │
│ [▸] Preview Placeholders                       │  editor.preview.toggle (only with placeholders)
│ ┌────────────────────────────────────────────┐ │
│ │ Meeting notes — 2026-11-25                 │ │  editor.preview.text (when expanded)
│ └────────────────────────────────────────────┘ │
│ Saved Nov 25, 2026 at 9:04 PM                  │  editor.footer (bodySmall, onSurfaceVariant)
└────────────────────────────────────────────────┘
```

### 6.2 Phone layout: Details tab

```
│ Keyword                                        │
│ ┌────────────────────────────────────────────┐ │
│ │ \ notes                              [⚠]   │ │  editor.keyword
│ └────────────────────────────────────────────┘ │
│ \notes is already used by Meeting room.        │  editor.keyword.message (supporting text)
│ Tags                                           │
│ ┌────────────────────────────────────────────┐ │
│ │ (work ×) (notes ×) |                       │ │  editor.tags
│ └────────────────────────────────────────────┘ │
│ ────────────────────────────────────────────── │
│ Enabled                               [  ●]    │  editor.enabled (switch row)
│ Allow this keyword to expand on Mac.           │
│ Secure                                [●  ]    │  editor.secure (switch row)
│ Encrypt the body and require fingerprint, face │
│ or screen lock to reveal or copy it.           │
```

### 6.3 Chrome

| Element | Spec |
|---|---|
| Top bar | `TopAppBar`; navigation `arrow_back` (description `Back`); title = display name, `titleMedium`, one line; scrolled container `surfaceContainer` |
| Copy | `IconButton` `content_copy`, description `Copy`; secure: icon `lock_open`, description `Authenticate and Copy`. After an ordinary copy the icon shows `check` for 1.5 s. Tag `editor.copy` |
| More | `IconButton` `more_vert`, description `More`, opens §6.8. Tag `editor.more` |
| Tabs | `SecondaryTabRow` with `Tab` `Content` and `Tab` `Details`; `labelLarge`; content switches with shared-axis X (`DESIGN.md` §9); no swipe paging. The selected tab is saved state. A new entry and every entry opened from the library start on `Content` |
| Warning dot | On the `Details` tab label while a warning-level keyword message applies (§6.5). Tab description then `Details, keyword warning` |
| Field style | C§11.1: caption above, `surfaceContainerHigh` surface |
| Scrolling | Each tab is one `verticalScroll` column with `imePadding()`; 16 dp margins; 16 dp between fields; 24 dp bottom |

### 6.4 Content tab fields

| Field | Spec |
|---|---|
| `Name` | Single line. Placeholder `First line is used when blank`; when the name is blank and the content is not, the placeholder is the first content line (cut to 50 characters + `…`); when both are blank, `Untitled Snippet`. For secure entries the content is never used for the placeholder. IME `Next` moves focus to the body |
| `Snippet` | Multi-line `monoBody`, placeholder `Paste or type`, soft wrap, no line numbers. Placeholders that the resolver recognises (`{date…}`, `{time…}`, `{datetime…}`, `{clipboard}`) are tinted `primary` (visual only). Secure entries show the secure panel (C§8) here instead |
| `Preview Placeholders` | Disclosure row (`expand_more` / `expand_less` + label in `primary`, `labelLarge`), shown only for ordinary entries whose body contains a resolvable placeholder. Collapsed by default. Expanded: the resolved text in `monoBody`, `onSurfaceVariant`, on `surfaceContainerLow` with a 1 dp `outlineVariant` border, shape medium; resolved with the real date and time; `{clipboard}` rendered as `[Clipboard content]` (the clipboard is not read). Never shown and never fed for secure entries |
| Footer | Ordinary: `Saved %1$s at %2$s` (medium date, short time). Secure: the panel footer (C§8). Errors: §6.7 |

### 6.5 Details tab fields

**Keyword** (`\` prefix shown, never stored; placeholder `sig`). Sanitised on every change: trimmed, leading `\` removed, runs of whitespace become `-`; the visible text is rewritten to the sanitised form.

Messages, one at a time, evaluated in this order. They appear as the field's supporting text whenever the field is not focused.

| # | Condition | Message | Level |
|---|---|---|---|
| 1 | No keyword | `Add a keyword to make this available for expansion on Mac.` | info |
| 2 | Entry disabled | `Disabled — \%s won’t expand.` | info |
| 3 | Keyword contains a multi-scalar character (emoji, combined glyph) | `\%s needs letters, digits, or hyphens.` | warning |
| 4 | Same keyword on another enabled entry (ordinary or secure) | `\%1$s is already used by %2$s.` | warning |
| 5 | Another enabled keyword starts with this one | `\%1$s is blocked by \%2$s.` | warning |
| 6 | This keyword starts with another enabled keyword | `This prevents \%s from expanding.` | warning |

- Info level: supporting text in `onSurfaceVariant`, no icon, no tab dot.
- Warning level: supporting text in `warning`, trailing `warning` icon in the field, dot on the `Details` tab. The icon is decorative; the text is always visible, so there is no separate warning dialog. Field description: `Keyword, warning: %s`.
- Messages never block saving.

Help while the field has focus (a strip directly under the field, replacing the message):

| Field content | Strip |
|---|---|
| Empty | Up to three `SuggestionChip`s `\abc` (`monoToken`), derived from the name and first content line (never from a secure body), excluding any that collide with an enabled keyword. Tapping one fills the field. Description `Use keyword %s` *(Android)*. Tags `editor.keyword.suggestion.<keyword>` |
| Non-empty | One read-only line `Existing · \a  ·  \b  ·  +%d more` (`monoToken`, `onSurfaceVariant`, one line, horizontally scrollable) listing up to eight existing keywords that match. Description `Existing keywords: %s`; hint `Space or Tab completes the next unambiguous keyword part.` Tag `editor.keyword.existing` |

- Space never inserts a space. At the end of the field it completes the common continuation of the matching keywords up to and including the next `.` or `-`; otherwise it does nothing. A hardware Tab does the same when a continuation exists; when none exists Tab moves focus.
- IME `Next` moves focus to Tags.

**Tags** (C§11.4 tag field; placeholder `work, email`).

| Input | Result |
|---|---|
| Comma, Enter, IME `Done`, focus leaving the field | Commits the pending text as a tag |
| Paste containing commas or newlines | Becomes several tags |
| Enter while a completion exists | Accepts the first completion |
| Backspace in an empty input | Removes the last tag |
| Tap `×` on a chip | Removes that tag (description `Remove tag %s`) |

- While typing, up to eight completion `SuggestionChip`s appear in a horizontally scrolling row under the field: existing library tags whose folded form starts with the typed text and that are not on the entry. Description `Complete tag %s`. Tags `editor.tags.completion.<foldedTag>`.
- On commit tags are trimmed, inner whitespace collapsed to one space, and de-duplicated case- and diacritic-insensitively keeping the first spelling.

**Switch rows**

| Row | Supporting text | Behaviour |
|---|---|---|
| `Enabled` | `Allow this keyword to expand on Mac.` | Toggles at once. Click label `Controls whether this keyword can expand on Mac.` |
| `Secure` | `Encrypt the body and require fingerprint, face or screen lock to reveal or copy it.` | Starts the conversion flow (`screens-secure.md` §4). The switch shows the real state and changes only after the move succeeds |

### 6.6 Focus order

Content: Name → (Next) body. Details: Keyword → (Next) Tags → (Done). Two-pane: Tab and Shift+Tab walk Name, Snippet, Keyword, Tags, Enabled, Secure. A new entry opens with the body focused. A secure entry does not take focus until it is revealed.

### 6.7 Saving

| Case | Behaviour |
|---|---|
| Ordinary fields | Each change updates the store (debounced 300 ms for the body, immediate for switches and tags); a final flush on blur, on leaving the screen and on `onStop` |
| Secure metadata (name, keyword, tags, enabled, pin) | Same, without unlocking |
| Secure body | Saved 300 ms after the last keystroke and on blur, on leaving the screen and when the vault locks |
| Failure | A banner pinned under the tab row (compact) or top bar (two-pane): `errorContainer`, `error` icon, `Couldn’t save: %s` or `Secure edit wasn’t saved: %s`; assertive announcement; the footer shows the same text in `error`. It clears on the next successful save. Tag `editor.save-error` |
| Remote change to the open entry | Applied field by field; a field with focus keeps its caret; a field being edited is not overwritten until it loses focus |
| Entry deleted elsewhere while open | Compact: pop to `library`. Two-pane: detail shows `editor.empty`. Snackbar `“%s” was deleted on another device.` *(Android)* |
| Leaving | Flush; lock a revealed secure body; discard a blank draft. Back is never intercepted |
| Undo | Text fields support Ctrl+Z / Ctrl+Shift+Z through the platform text undo |

### 6.8 EDIT-MORE — `editor/{id}/menu`

| Item | Icon | Tag | Shown for | Action |
|---|---|---|---|---|
| `Pin` / `Unpin` | `push_pin` | `menu.item.pin` | all | Toggle |
| `Share Text` *(Android)* | `share` | `menu.item.share-text` | ordinary | Android Sharesheet, `text/plain`, the resolved text (placeholders resolved as for copy); `EXTRA_TITLE` = display name. Empty result: snackbar `“%s” has no content to copy.` |
| `Share Link` | `link` | `menu.item.share-link` | ordinary | Sharesheet with the `snippets://share?data=…` link |
| `Copy Share Link` | `link` | `menu.item.copy-link` | ordinary | Clipboard; snackbar `Copied share link.` on API 28–32. Failure: `dialog/error` `Couldn’t Copy Link` |
| `Duplicate` | `file_copy` | `menu.item.duplicate` | ordinary | §2.3; the editor switches to the copy (compact: replaces the top of the back stack) |
| `Delete` | `delete` (`error`) | `menu.item.delete` | all | Ordinary: delete, leave the editor, `Undo` snackbar on the library. Secure: `dialog/delete-secure`, then leave |

Before any of these, and before Copy, a revealed secure body is locked.

### 6.9 Two-pane layout (detail pane)

```
│  Project brief                                         [copy] [⋮]  │  TopAppBar, no Up arrow
│ ────────────────────────────────────────────────────────────────── │
│  Name                                                              │  one scrolling form,
│  ┌──────────────────────────────────────────────────────────────┐  │  max width 720 dp
│  │ Project brief                                                │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  Snippet                                                           │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ PROJECT ATLAS …                                              │  │  min height 240 dp
│  └──────────────────────────────────────────────────────────────┘  │
│  Preview                                                           │  always expanded when the body
│  ┌──────────────────────────────────────────────────────────────┐  │  has placeholders (caption `Preview`)
│  └──────────────────────────────────────────────────────────────┘  │
│  Keyword                                                           │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ \ brief                                                      │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  Tags                                                              │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ (work ×) (notes ×) |                                         │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  Enabled                                                  [  ●]    │
│  Secure                                                   [●  ]    │
│  Saved Nov 25, 2026 at 8:23 PM                                     │
```

- No tabs; the same field components in the order Name, Snippet, Preview, Keyword, Tags, Enabled, Secure, footer.
- Selecting another row flushes and locks, then cross-fades the form (fade through).
- Esc moves focus back to the list.

### 6.10 Accessibility

- Pane title = display name. Tabs are `Role.Tab` with `selected` state.
- Captions label their fields; placeholders are hints, not labels.
- The preview block: description `Placeholder preview`, text readable.
- Footer changes (`Saved …`) are not announced; save failures are.
- Secure panel: C§8.

### 6.11 Test tags

`editor.screen`, `topbar.title`, `topbar.back`, `editor.copy`, `editor.more`, `editor.tab.content`, `editor.tab.details`, `editor.tab.details.dot`, `editor.name`, `editor.body`, `editor.preview.toggle`, `editor.preview.text`, `editor.footer`, `editor.save-error`, `editor.keyword`, `editor.keyword.message`, `editor.keyword.warning-icon`, `editor.keyword.suggestion.<keyword>`, `editor.keyword.existing`, `editor.tags`, `editor.tags.input`, `editor.tag.<foldedTag>`, `editor.tag.<foldedTag>.remove`, `editor.tags.completion.<foldedTag>`, `editor.enabled`, `editor.secure`, `editor.secure-panel` (+ C§8), `editor.empty`, `countdown.*`.

---

## 7. Shared dialogs

All use the confirmation template (C§16.1) unless noted.

### 7.1 ALERT-DELETE-SECURE — `dialog/delete-secure`

| Part | Copy |
|---|---|
| Title | `Delete “%s”?` |
| Message | `This permanently removes the encrypted snippet from this device and, when sync is on, from your other devices.` |
| Buttons | `Cancel` · `Delete` (`error`) |
| After | Snackbar `Secure snippet deleted.` No authentication is required to delete. |

### 7.2 ALERT-CLIP-EMPTY — `dialog/clipboard-empty`

Title `Clipboard Is Empty` · message `Copy some text, then try again.` · button `OK`.

### 7.3 ALERT-SYNC-OPT-IN — `dialog/sync-opt-in`

| Variant | Title | Message | Buttons |
|---|---|---|---|
| Provider set up, encrypted | `Turn On %s Sync?` | `Pull to refresh uses %s. Snippets encrypts records before uploading them, and you can turn sync off later in Settings.` | `Not Now` · `Turn On` |
| Provider set up, plain-text Git library *(Android)* | `Turn On Git Sync?` | `Pull to refresh uses Git. Ordinary snippets are saved as readable Markdown files in your repository; secure snippets stay encrypted. You can turn sync off later in Settings.` | `Not Now` · `Turn On` |
| Nothing set up *(Android)* | `Set Up Sync?` | `Pull to refresh syncs this library with your other devices. No sync provider is set up on this device yet.` | `Not Now` · `Set Up Sync` (opens `settings/sync`) |

### 7.4 Error dialogs — `dialog/error`

One `OK` button; the body is the error's sentence (vault sentences: `screens-secure.md` §9).

| Title | Raised by |
|---|---|
| `Couldn’t Copy Snippet` | Copy; bodies include `The snippet no longer exists.`, `The secure snippet does not contain valid text.` |
| `Couldn’t Update Pin` | Pin / unpin |
| `Couldn’t Update Snippet` *(Android)* | Enable / disable from the row menu |
| `Couldn’t Delete Snippet` | Delete |
| `Couldn’t Copy Link` *(Android)* | Copy Share Link |
| `Couldn’t Open Link` | `screens-system.md` §3 |
| `Couldn’t Set Up Secure Snippets`, `Couldn’t Make Snippet Secure`, `Couldn’t Make Snippet Ordinary`, `Couldn’t Reveal Secure Content` | `screens-secure.md` |
| `Couldn’t Export Snippets`, `Couldn’t Create Encrypted Backup`, `Couldn’t Import Snippets`, `Couldn’t Import Encrypted Backup`, `Couldn’t Recover Library`, `Library Recovery Required` | `screens-settings-data.md` |

A cancelled authentication never produces one of these (D15).

---

## 8. SHORTCUTS — hardware keyboard

Shortcuts are active on every window size when a hardware keyboard is attached. They are published through `Activity.onProvideKeyboardShortcuts` in one group titled `Snippets`, so the system Keyboard Shortcuts Helper (Meta+/) is the shortcut panel; More ▸ `Keyboard Shortcuts` opens the same helper.

| Shortcut | Label in the helper | Behaviour |
|---|---|---|
| Enter | `Copy Snippet` | List focus: copy the focused or selected row (secure: authenticate first) |
| Ctrl+F | `Search` | Focus the search field |
| Ctrl+N | `Create New Snippet` | §2.2 |
| Ctrl+Shift+N | `New from Clipboard` | §2.2 |
| Ctrl+E | `Edit Snippet` | Two-pane: focus the editor's body (Name for a secure entry). Compact: open the editor for the focused row |
| Ctrl+Backspace, Delete | `Delete Snippet` | Delete the selected or focused entry (§2.3) |
| Tab / Shift+Tab | `Next Field` / `Previous Field` | Standard focus traversal |
| Esc | `Return to Snippet List` | In the editor: two-pane moves focus to the list; compact goes back. In the search field: keeps the query and moves focus to the list |
| Ctrl+Shift+I / Ctrl+Shift+E | `Import` / `Export` | Import flow / Export for Sharing |
| Ctrl+Z / Ctrl+Shift+Z | `Undo` / `Redo` | In a text field: text undo. With list focus while the `Undo` snackbar is showing: undo the delete |
| ↓ / ↑ | `Next Snippet` / `Previous Snippet` | Move list focus; in two-pane the selection follows focus |
| Ctrl+, | `Settings` *(Android)* | Open `settings` |
| Meta+/ | (system) | Show the helper |

Not ported: `Toggle Sidebar` (panes are fixed), `Toggle Shortcuts` and the ⌥ "all shortcuts" footer (the system helper replaces the panel), and the two informational rows (`Expand a Snippet`, `Insert a Placeholder`), which describe the Mac.

Focus visuals: `DESIGN.md` §4 and C§1.3. Initial focus on a hardware-keyboard launch is the first row.

---

## 9. Changed strings

| iOS string | Android string | Why |
|---|---|---|
| Large title `Snippets` | Pane title `Snippets` (not drawn) | D3: the search bar is the top bar |
| `Bring Your Library to iPhone` / `Connect \(providerName) to fetch the library from your other devices.` / button `Connect \(providerName)` | `Your Library Is Empty` / `Create a snippet, import a library, or set up sync to fetch the library from your other devices.` / `New Snippet`, `Import…`, `Set Up Sync` | No default provider on Android; names no device model; local-first first run (D38) |
| `Secure · \keyword` | token `\keyword` + `Secure snippet` | The keyword is drawn as a token on every row; one fixed preview for secure entries |
| `Tip: swipe right to edit. Swipe left to pin or delete.` | `Tip: swipe right to edit, swipe left to pin. Touch and hold for more.` | D5: delete is not a swipe action |
| `Copied “\(name)”. Secure clipboard expires in 60 seconds.` | Countdown row `Copied “%1$s”. Clears in %2$s`; announcement `Copied “%s”. Clears from the clipboard in 60 seconds.` | Android cannot expire a clip; the app clears it (D8) |
| `Preparing the first cloud fetch…`, `Preparing cloud sync…`, `Fetching your cloud library…`, `Waiting to fetch your cloud library…` | `Preparing the first fetch…`, `Preparing sync…`, `Fetching your library…`, `Waiting to fetch your library…` | D25 |
| `Connect \(providerName)` (More menu) | `Turn On %s Sync` / `Set Up Sync` | "Connect Git" misreads as connecting a repository; two cases exist on Android |
| `Connecting to iCloud…` | `Connecting to %s…` | No iCloud |
| `Transfer` submenu | Three flat items | D28 |
| Filter sheet `Done` | (removed) | Android sheets dismiss by handle, scrim and back |
| Filter hints `Shows the available tag filters`, `Removes every active tag filter`, `Double tap to remove/apply this filter` | Click labels `show tag filters`, `remove every tag filter`, `remove this filter` / `apply this filter` | TalkBack composes "Double-tap to …" itself |
| Row hints `Double tap to copy`, `Double tap to authenticate and copy` | Click labels `copy`, `authenticate and copy` | Same |
| Banner hints `Double-tap to \(buttonTitle)`, `Details are available in Settings` | Click labels: the button title in lower case, `show sync status` | Same; the row now opens the status sheet |
| `Encrypt the body and require device-owner authentication to reveal or copy it.` | `Encrypt the body and require fingerprint, face or screen lock to reveal or copy it.` | D19 |
| Hint `Moves the content between the encrypted vault and the ordinary library.` | Click label `move the content between the encrypted vault and the ordinary library` | TalkBack convention |
| `Keyword Warning` alert with `OK`; label `Keyword warning: \(message)` | Supporting text under the field; description `Keyword, warning: %s` | The message is always visible; no dialog is needed |
| Copy feedback in the editor footer | Top-bar icon `check` state, snackbar on API 28–32, countdown row for secure | One copy-feedback rule for list and editor (D7, D8) |
| `Share` | `Share Text`, `Share Link` | D29 |
| `Select a snippet` / `Choose a snippet from the sidebar or create a new one.` | `Select a snippet` / `Choose a snippet from the list or create a new one.` | No sidebar on Android |
| iPad delete confirmation `Delete “\(name)” ?` for ordinary entries | (not used) | D9; the stray space was a typo |
| iPad toasts `Couldn’t update pin: \(error)`, `Couldn’t update snippet: \(error)`, `Couldn’t copy link: \(error)` | Error dialogs `Couldn’t Update Pin`, `Couldn’t Update Snippet`, `Couldn’t Copy Link` | One error presentation |
| `Your snippet library is empty` and the other iPad sidebar empty states | The phone empty states (§2.4) | One list component |
| `Keyboard Shortcuts` panel `Shortcuts`, `Hold ⌥ for all shortcuts.`, `Dismiss Shortcuts` | System Keyboard Shortcuts Helper | D36 |
| ⌘ shortcuts | Ctrl equivalents (§8) | Platform |
