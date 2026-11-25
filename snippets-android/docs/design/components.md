# Components

Reusable building blocks. Tokens, routes and conventions come from `DESIGN.md`. Each component lists anatomy, states, the Compose / Material 3 pieces to build it from, accessibility and test tags. Composable names are suggestions; behaviour and measurements are the contract.

Contents: 1 Library row · 2 Keyword token · 3 Tags (pill, filter row, filter sheet) · 4 Search bar and highlights · 5 Section header and list footer · 6 Empty state · 7 Sync status (row, sheet facts, problem card, Review card) · 8 Secure body panel · 9 Secret display block · 10 Countdown row · 11 Form fields and validation · 12 Settings rows · 13 Progress step list · 14 Secret screen template · 15 Review template · 16 Dialog templates · 17 Snackbar rules · 18 Buttons and menus

---

## 1. Library row (`SnippetRow`)

One component for phone, tablet and the Insert Snippet activity.

### 1.1 Anatomy

```
 16dp                                                         4dp
 ├───────────────────────────────────────────────┬──────────┤
 │ Meeting notes            [lock][pin][pause]  9:04 PM │ [edit] │  line 1
 │ ┌──────┐                                             │  48dp  │
 │ │\notes│ Meeting notes — {date:yyyy-MM-dd}           │ button │  line 2
 │ └──────┘                                             │        │
 │ (work) (notes) (links) +2                            │        │  line 3 (only with tags)
 └──────────────────────────────────────────────────────┴────────┘
   12 dp top and bottom padding · 1 dp divider, inset 16 dp, outlineVariant
```

| Part | Spec |
|---|---|
| Container | `Box` with `combinedClickable` inside `SwipeToDismissBox`; colour `surface`; min height 72 dp (two lines), 96 dp (three lines); grows with font scale |
| Name | `titleMedium`, `onSurface`, one line, ellipsis, `weight(1f)`. Display name rule: name, else first non-blank content line cut to 50 characters + `…`, else `Untitled Snippet`; secure entries without a name show `Untitled Snippet` |
| Status glyphs | 16 dp, 4 dp apart, 8 dp after the name: `lock` (`secure`) when secure; `push_pin` filled (`primary`) when pinned; `pause_circle` (`onSurfaceVariant`) when disabled. None → no gap |
| Time | `labelMedium`, `onSurfaceVariant`, 8 dp start padding, never wraps. Today: time of day (`DateFormat.getTimeFormat`); yesterday: `Yesterday`; 2–6 days ago: abbreviated weekday (`EEE`); otherwise `MMM d` |
| Line 2 | Keyword token (§2) when a keyword exists, 8 dp gap, then preview: `bodyMedium`, `onSurfaceVariant`, one line, ellipsis (two lines at font scale ≥ 1.3) |
| Line 3 | Up to 3 tag pills (§3.1) on one line, 6 dp apart, then `+N` (`labelSmall`, `onSurfaceVariant`) for the rest. Pills that do not fit are counted into `+N`. Hidden when the entry has no tags |
| Trailing button | Compact / medium: `IconButton` `edit`, opens the editor. Two-pane: `IconButton` `content_copy` (secure: same icon), copies. Vertically centred. Hidden in `process-text` |
| Divider | `HorizontalDivider`, 1 dp, `outlineVariant`, start inset 16 dp; not drawn under the last row of a section or next to a selected row |

### 1.2 Line 2 text rules

| Entry | Token | Preview text |
|---|---|---|
| Ordinary, keyword and content | `\keyword` | first non-blank content line, whitespace collapsed |
| Ordinary, keyword only | `\keyword` | (none) |
| Ordinary, content only | — | first non-blank content line |
| Ordinary, neither | — | `No content` |
| Secure, with keyword | `\keyword` | `Secure snippet` |
| Secure, no keyword | — | `Secure snippet` |
| Disabled (any of the above) | token struck through (§2) | `Disabled · ` + the text above (for "keyword only": `Disabled`) |
| Search hit inside the content, not on the first line | as above | `…` + excerpt starting up to 16 characters before the match, match highlighted (§4.2) |

A secure body is never passed to this component.

### 1.3 States

| State | Visual |
|---|---|
| Default | As drawn |
| Pressed / hovered / focused | M3 state layer on the whole row (`onSurface` 10 % / 8 % / 10 %); keyboard focus adds a 2 dp `primary` inner outline, shape medium |
| Pinned | Filled `push_pin` glyph. The row sits under the `Pinned` header |
| Secure | `lock` glyph in `secure`; preview `Secure snippet` |
| Disabled keyword | Name in `onSurfaceVariant` (not alpha); `pause_circle` glyph; token struck through; `Disabled · ` prefix. The row stays fully interactive |
| Conflict copy | No special row chrome; its `conflict` tag pill uses the warning style (§3.1); it is also disabled, so the disabled style applies |
| Selected (two-pane) | Container `secondaryContainer`, shape medium, inset 8 dp from the pane edges (row content keeps its 16 dp inset by reducing inner padding to 8 dp); name stays `onSurface`; token background becomes `surface`; no dividers above or below |
| Copied | For 1500 ms line 2 is replaced by `check` (16 dp, `primary`) + `Copied` (`labelLarge`, `primary`); the container flashes `secondaryContainer` (see `DESIGN.md` §9). Lines 1 and 3 do not change. A second tap during the state copies again and restarts it |
| Nothing to copy | No row change; snackbar (§17) |
| Authenticating (secure copy) | No row change while `BiometricPrompt` is up |
| Swiping | Background revealed, see §1.4 |

### 1.4 Gestures (compact and medium only; disabled in two-pane and while touch exploration is on)

`SwipeToDismissBox` with `positionalThreshold = 40 %` of the row width and `confirmValueChange = { act(it); false }` so the row always springs back.

| Direction | Background | Icon and label (appear at 24 dp from the edge) | On release past the threshold |
|---|---|---|---|
| Start → end (right) | `primaryContainer` | `edit` + `Edit`, `onPrimaryContainer` | Open the editor |
| End → start (left) | `secondaryContainer` | `push_pin` + `Pin` or `Unpin`, `onSecondaryContainer` | Toggle pin; row animates to its new position |

Crossing the threshold arms the action: icon scales to 1.15 and haptic `GestureThresholdActivate`; moving back disarms with `SegmentTick`. Only one row can be mid-swipe; starting a scroll cancels it.

| Input | Result |
|---|---|
| Tap (compact / medium) | Copy (secure: authenticate, then copy) |
| Tap (two-pane) | Select and show in the detail pane |
| Long-press, right-click, Menu key, Shift+F10 | Row menu at the touch point (`screens-library-editor.md` §4) |
| Enter (two-pane, row focused) | Copy |
| Trailing button | Edit (compact / medium) or Copy (two-pane) |

### 1.5 Accessibility

- The row is one node: `Role.Button`; `contentDescription` = display name; `stateDescription` = comma-joined `Secure` or `Standard`, `Pinned` (if pinned), `Enabled` or `Disabled`, `Keyword \keyword` (if any), `Tags: a, b` (if any).
- Click label: `copy` (ordinary), `authenticate and copy` (secure), `open` (two-pane). TalkBack reads "Double-tap to copy".
- `customActions`, in order: `Copy`, `Edit`, `Pin` / `Unpin`, `Duplicate` (ordinary), `Delete`.
- The trailing button and the pills are `clearAndSetSemantics {}` (covered by the row).
- The `Copied` state announces `Copied “name”.` (polite); secure: `Copied “name”. Clears from the clipboard in 60 seconds.`

### 1.6 Test tags

`library.row.<id>` (row), `library.row.<id>.name`, `.preview`, `.keyword`, `.time`, `.tags`, `.copied` (present only in the Copied state), `.edit` or `.copy` (trailing button), `.glyph.secure`, `.glyph.pinned`, `.glyph.disabled`.

---

## 2. Keyword token (`KeywordToken`)

```
┌────────┐
│ \notes │   monoToken · 6 dp horizontal, 1 dp vertical padding · shape extraSmall
└────────┘
```

| Variant | Text | Background | Notes |
|---|---|---|---|
| Enabled | `onSurface` | `surfaceContainerHighest` | The backslash is display only |
| Disabled | `onSurfaceVariant`, `TextDecoration.LineThrough` | `surfaceContainerHighest` | |
| On a selected row | as above | `surface` | |
| With search highlight | matched characters use the highlight span (§4.2) | | |

`Text` with `Modifier.background(color, shape)`. Not a chip, not clickable. Max width 45 % of the row; ellipsis at the end. Semantics are merged into the row (`Keyword \notes`).

---

## 3. Tags

### 3.1 Tag pill (`TagPill`)

```
( work )     height 20 dp · 8 dp horizontal padding · labelSmall · shape small
```

Text colour and opaque fill from the tag palette (`DESIGN.md` §5.3) by `fnv1a64(foldedTag) % 12`. Tag `conflict` (folded): `warning` icon 12 dp + text in `onWarningContainer` on `warningContainer`. Read-only in rows and review dialogs. In the editor a tag is an `InputChip` (§11.4).

### 3.2 Tag filter row (`TagFilterRow`)

Shown under the search bar when the library has at least one tag or a filter is active. Height 48 dp. Does not scroll with the list.

```
 [≡ 2]  (✓ work 12) (✓ links 7) (• personal 5) (• travel 3) (• notes 2) →
  ^ filter button with badge       ^ LazyRow of FilterChip, 8 dp gaps, 16 dp content padding
```

| Part | Spec |
|---|---|
| Filter button | `IconButton` `filter_list`; with active filters `FilledTonalIconButton` plus `Badge` showing the count. Opens `library/tags`. Content description `Filter by tags`; state description `No active filters` / `%d active filter(s)` (plural) |
| Chip | `FilterChip`. Label = tag display name (`labelLarge`) + count (`labelMedium`, `onSurfaceVariant`). Unselected leading icon: 8 dp dot in the tag's text colour. Selected: `check` 18 dp, container `secondaryContainer` |
| Order | Selected chips first, in the order they were selected; then the rest alphabetically, case-insensitively |
| Counts | Entries carrying the tag over the whole library, secure entries included |
| Behaviour | Tap toggles; filters combine with AND; the list updates immediately; haptic `SegmentTick`. Selecting scrolls the row to the start |

Accessibility: each chip `Role.Checkbox`; label `Filter by tag %1$s`; state `on` / `off`; value `%d snippet(s)`. Tags: `library.filter`, `library.filter.badge`, `library.tag-chip.<foldedTag>`.

### 3.3 Tag filter sheet (`library/tags`)

`ModalBottomSheet` (`skipPartiallyExpanded = false`: opens at half height, drags to full), drag handle, max width 640 dp.

```
┌──────────────────────────────────────────────┐
│                    ───                       │
│ Filter by Tags (2)                    Clear  │  titleLarge · TextButton (disabled with no filters)
│ ┌──────────────────────────────────────────┐ │
│ │ 🔍 Search tags                           │ │  shown when the library has more than 12 tags
│ └──────────────────────────────────────────┘ │
│ [label] links                        7   [✓] │  ListItem · leading `label` in the tag colour
│ [label] messages                     1   [ ] │  trailing: count (labelMedium) + Checkbox
│ [label] work                        12   [✓] │
│ …                                            │
│ A snippet must match every selected tag.     │  bodySmall, onSurfaceVariant, 16 dp padding
└──────────────────────────────────────────────┘
```

- Title `Filter by Tags`, or `Filter by Tags (%d)` with active filters.
- Rows alphabetical (case-insensitive); tapping anywhere on a row toggles and applies immediately; the library behind updates live. There is no Done or Apply button: handle, scrim and back dismiss.
- `Clear` removes every filter, keeps the sheet open, announces `Tag filters cleared`.
- `Search tags` filters the rows by folded substring; no match: `No tags match “%s”.` (bodyMedium, centred).
- Empty library of tags: `label` glyph 40 dp, `No Tags Yet`, `Add tags to a snippet, then return here to filter your library.` (empty-state component, §6).
- Row accessibility: `Role.Checkbox`; label = tag; value `%d snippet(s), selected` / `not selected`; click label `remove this filter` / `apply this filter`.
- Tags: `tags.sheet`, `tags.title`, `tags.clear`, `tags.search`, `tags.row.<foldedTag>`, `tags.footer`, `tags.empty`.

---

## 4. Search bar and highlighted matches

### 4.1 Search bar (`LibrarySearchBar`)

```
┌──────────────────────────────────────────────────────────┐
│ [search]  Search snippets                    [×]   [⋮]   │  56 dp · shape full · surfaceContainerHigh
└──────────────────────────────────────────────────────────┘
```

M3 `SearchBar` with `SearchBarDefaults.InputField`, `expanded = false` at all times (the list below is the result set; the full-screen search view is never opened). If the 1.4.0 API cannot keep a focused field collapsed, build the same visuals from a `Surface(shape = CircleShape, color = surfaceContainerHigh)` and a `BasicTextField`.

| Part | Spec |
|---|---|
| Leading | `search` icon (decorative). While the field has focus or a query: `IconButton` `arrow_back`, description `Clear search`, clears the query and focus |
| Field | `bodyLarge`; placeholder `Search snippets` (`onSurfaceVariant`); single line; IME action `Search` (hides the keyboard, keeps the query); autocorrect off, no capitalisation |
| Clear | `IconButton` `close`, shown only with a non-empty query; description `Clear text`; clears the text and keeps focus |
| More | `IconButton` `more_vert`, description `More`; opens `library/more` |
| Position | Pinned at the top, 16 dp side margins (centred, max 640 dp at medium; fills the list pane minus 16 dp margins in two-pane), 8 dp below the status-bar inset, 4 dp above the filter row. It never collapses on scroll |
| Scrolled state | When the list is scrolled, the area behind the bar and filter row takes `surfaceContainer` (same as a scrolled top app bar) |

Search runs on every change, off the main thread; stale results are dropped. Ctrl+F focuses the field. Tags: `library.search`, `library.search.clear`, `library.search.back`, `library.more`.

### 4.2 Highlighted matches

`AnnotatedString` with `SpanStyle(background = tertiaryContainer, color = onTertiaryContainer)` on every matched character range in the name, keyword token, tag pills and the content preview. Fuzzy (subsequence) matches in name, keyword and tags highlight each matched character; content matches highlight the contiguous run. Matching and ranges come from the same folding as the search index (case- and diacritic-insensitive). Secure entries never highlight in the preview (their preview is the fixed text). Highlights are visual only; TalkBack reads the plain text.

---

## 5. Section header and list footer

```
 Pinned                         titleSmall · onSurfaceVariant · 16 dp start · 16 dp top, 8 dp bottom · heading()
```

- `Pinned` appears above pinned matches when at least one visible entry is pinned. It is not sticky. The rest of the list has no header; a full-width `HorizontalDivider` (`outlineVariant`) with 8 dp space above and below separates the two groups.
- Settings sections (`Library`, `General`, `Support`, `Search Results`) and form sections use the same header style.
- List footer (`library.count`): centred `bodySmall`, `onSurfaceVariant`, 16 dp above and below. Unfiltered: `%d snippet(s)` (plural). With a query or filters: `%1$d of %2$d snippets`. *(Android)*

---

## 6. Empty state (`EmptyState`)

```
                 [glyph 40 dp, onSurfaceVariant]            or CircularProgressIndicator 24 dp
                                16 dp
                     Title (titleLarge, centred)
                                 8 dp
        Message (bodyMedium, onSurfaceVariant, centred, max width 360 dp)
                                24 dp
                      [   Primary action   ]                 Button (filled), optional
                                 8 dp
                 Text action        Text action              TextButtons, optional
                                16 dp
                 Note (bodySmall, onSurfaceVariant)          optional
```

Centred in the available area; the block is inside its own `verticalScroll` so it never clips at large font scales or small heights. While an empty state shows, the list itself does not scroll and pull-to-refresh stays available. Title sets `heading()`. Tags: `<area>.empty`, `<area>.empty.title`, `<area>.empty.message`, `<area>.empty.action`, `<area>.empty.action-2`, `<area>.empty.action-3`.

---

## 7. Sync status

### 7.1 Status glyph and sentence

One mapping, used by the library row, the sync sheet, Settings rows and the Git / Cloud screens.

| State | Glyph | Tint |
|---|---|---|
| Off | (no glyph in the library) / `sync` in Settings | `onSurfaceVariant` |
| Starting, preparing | `cloud` | `onSurfaceVariant` |
| Syncing | `CircularProgressIndicator` 16 dp, 2 dp stroke | `primary` |
| Idle, waiting for the first fetch | `cloud_download` | `onSurfaceVariant` |
| Idle, synced / on, not synced yet | `cloud_done` | `onSurfaceVariant` |
| Offline / host unreachable | `cloud_off` | `onSurfaceVariant` |
| Needs authentication | `person_alert` | `warning` |
| Needs attention | `warning` | `warning` |
| Waiting for the vault | `lock_clock` | `secure` |
| Halted, newer schema | `system_update` | `warning` |
| Halted, other | `sync_problem` | `error` for mass deletion, remote reset and integrity failure; `warning` otherwise |

The full status sentence (one generator, `screens-settings-data.md` §4) is the text everywhere except the library row's short forms (`screens-library-editor.md` §2.6).

### 7.2 Library sync row (`SyncStatusRow`), quiet form

First item of the list (scrolls away). Shown when sync is on or a local recovery is pending.

```
 [glyph 20dp]  Synced at 9:04 PM                                  min height 48 dp · 16 dp padding
```

`bodyMedium`, `onSurfaceVariant`, up to two lines. The whole row is a button that opens `library/sync`. Accessibility: label `Sync`, value = the text, click label `show sync status`. Tag `library.sync-row`, `.text`.

### 7.3 Review card (`SyncReviewCard`)

Replaces the quiet row when sync needs the user (any state with a recovery action, or needs authentication / attention). Not dismissable while the cause remains.

```
┌──────────────────────────────────────────────────────────┐
│ [glyph]  Sync Stopped                                    │  titleSmall
│ Stopped because an unusually large deletion arrived: …   │  bodyMedium, max 4 lines, ellipsis
│                                   [ Confirm Deletions ]  │  FilledTonalButton, end-aligned
└──────────────────────────────────────────────────────────┘
  Card · shape medium · 16 dp side margin, 8 dp vertical · 16 dp padding
```

| Variant | Container / content | Title |
|---|---|---|
| Halted | `errorContainer` / `onErrorContainer` for mass deletion, remote reset, integrity failure; otherwise `warningContainer` / `onWarningContainer` | `Sync Stopped` |
| Needs authentication or attention | `warningContainer` / `onWarningContainer` | `Sync Needs Attention` |
| Waiting for the vault | `secureContainer` / `onSecureContainer` | `Sync Is Waiting` |

- Button title: the recovery action's title (`Confirm Deletions`, `Refresh Deletion Details`, `Review Account Change`, `Repair Sync`, `Restore Cloud Library`, `Take Over Recovery`, `Try Again`, `Check Again`), or `Open Sync Settings` when there is none. `Update Snippets` state has no button.
- Button behaviour: an action with a confirmation opens `sync/review`; one without runs at once (button shows a 16 dp spinner and is disabled while it runs).
- Tapping the card body opens `sync/review` (halts) or `settings/sync` (others).
- Accessibility: label `Sync`; value = sentence + `Action: %s.`; click label = the button title in lower case. The button is a separate node.
- Tags: `library.sync-card`, `.title`, `.text`, `.action`.

### 7.4 Problem card (`ProblemCard`)

Persistent, typed error on the Git and Cloud screens and in forms. Never a toast.

```
┌──────────────────────────────────────────────────────────┐
│ [error]  Access Token Refused                            │  titleSmall
│ The Git host didn’t accept the access token. It may …    │  bodyMedium, full text
│ [ Enter a New Token ]                                    │  TextButton(s), start-aligned
│ Details ▾                                                │  disclosure
│   Code: git_http_401                           [copy]    │  monoKey + IconButton
└──────────────────────────────────────────────────────────┘
  OutlinedCard · 1 dp border `error` (or `warning`) · container surface · shape medium
```

- Severity `error` (icon `error`, border and title `error`) or `warning` (icon `warning`, border and title `warning`).
- The message is the complete sentence; never a host response, URL or token fragment.
- `Details` is collapsed by default; the code is the closed failure code. Copying it is an ordinary (non-sensitive) copy.
- It is an assertive live region when it first appears. It stays until the next attempt starts or the cause is fixed.
- Tags: `<area>.error.<code>`, `.title`, `.message`, `.action`, `.action-2`, `.details`, `.code`, `.code-copy`.

---

## 8. Secure body panel (`SecureBodyPanel`)

Occupies the body field's place in the editor (same width, shape medium, container `surfaceContainerHigh`, min height 200 dp). The plaintext exists in composition only in the `revealed` state.

```
locked                               unlocking                           revealed
┌──────────────────────────────┐     ┌──────────────────────────────┐   ┌──────────────────────────────┐
│                              │     │                              │   │ [lock_open] Revealed   Lock  │ 40 dp header
│         [lock 32dp]          │     │         [lock 32dp]          │   ├──────────────────────────────┤
│ Locked after 5 minutes       │     │                              │   │ sk-live-9f3…                 │ monoBody,
│ without use.   (reason line) │     │                              │   │                              │ editable
│ [ Reveal Secure Content ]    │     │ [ ◌ Authenticating… ]        │   │                              │
│                              │     │                              │   │                              │
└──────────────────────────────┘     └──────────────────────────────┘   └──────────────────────────────┘

protected                            unavailable (no screen lock, vault missing)
┌──────────────────────────────┐     ┌──────────────────────────────┐
│     [visibility_off 32dp]    │     │         [lock 32dp]          │
│ Screen recording detected.   │     │ Set a screen lock to use     │
│ Secure content stays hidden. │     │ secure snippets.             │
│                              │     │ [ Open Settings ]            │
└──────────────────────────────┘     └──────────────────────────────┘
```

| State | Content | Footer line under the panel (`bodySmall`) |
|---|---|---|
| `locked` | `lock` 32 dp in `secure`; optional reason line (`bodyMedium`, `onSurfaceVariant`); `FilledTonalButton` `Reveal Secure Content` | `Content is encrypted. Metadata remains searchable.` |
| `unlocking` | Same; the button is disabled and shows a 16 dp spinner + `Authenticating…` | same |
| `revealed` | Header: `lock_open` 18 dp + `Revealed` (`labelLarge`, both `secure`), `TextButton` `Lock` at the end. Below: the body `BasicTextField` in `monoBody`, placeholder `Paste or type`, min 6 lines, grows | `Secure content is revealed and editable until you leave this screen.` |
| `protected` (recording) | `visibility_off` 32 dp; `Screen recording detected. Secure content stays hidden.` | `Screen recording detected. Secure content stays hidden.` |
| `protected` (display) | `visibility_off` 32 dp; `Protected display unavailable. Secure content stays hidden.` | `Secure content was hidden because protected display failed.` |
| `unavailable` | `lock` 32 dp; message and optional button per cause (`screens-secure.md` §3.5) | — |

Reason line (only after an automatic lock in this editor visit; *(Android)*): `Locked after 5 minutes without use.` / `Locked after 30 minutes.` / `Locked when you left the app.`

Revealed field restrictions: the text toolbar offers only `Paste`, `Select all` (and selection handles); Copy, Cut, Share, Process-text actions, Autofill and drag-and-drop are removed (custom `LocalTextToolbar`, no `SelectionContainer`). Keyboard options: §11.2.

Accessibility: the panel's plaintext field has `clearAndSetSemantics {}` in every state. A sibling node (focusable, not editable) carries: `contentDescription` `Protected secure snippet body`; `stateDescription` one of `Use Reveal Secure Content to show it visually. The text is unavailable to accessibility.` (locked) / `Authenticated secure content is being prepared. The text is unavailable to accessibility.` (unlocking) / `Content is shown visually. The text remains unavailable to accessibility.` (revealed) / the protected message. The `Reveal Secure Content` and `Lock` buttons are normal nodes.

Tags: `editor.secure-panel` (root; `stateDescription` mirrors the state name for tests), `editor.secure.reveal`, `editor.secure.lock`, `editor.secure.body` (the field; exists only when revealed), `editor.secure.reason`, `editor.secure.standin`, `editor.secure.footer`.

---

## 9. Secret display block (`SecretBlock`)

A bordered block for a value the user must copy or compare exactly.

```
┌──────────────────────────────────────────────────────────┐
│               7K2M-9QXD-4FTR-HV3N                        │  monoCode, centred,
│               P8WC-6YJA-B5G                              │  groups never break
└──────────────────────────────────────────────────────────┘
  OutlinedCard · border outlineVariant · container surfaceContainerLow · shape medium · 20 dp padding
```

| Variant | Typography | Layout | Selectable | Sensitive |
|---|---|---|---|---|
| `code` (vault recovery key, Git recovery code, Cloud account key, recovery-kit code) | `monoCode` | Groups laid out in a centred `FlowRow`; the hyphen belongs to the end of its group so a line never starts with one | No | Yes |
| `comparison` (pairing / sign-in confirmation code) | `monoCodeLarge` | One line, centred | No | Yes (screen), not copyable |
| `fingerprint` (SSH host key) | `monoKey` | `SHA256:` on the first line, then the 43 characters in groups of 8 separated by spaces, wrapping | Yes | No |
| `publicKey` (device SSH key) | `monoKey` | Whole key, soft-wrapped at any character, never truncated | Yes | No |

Copy affordance (outside the block, directly under it): `FilledTonalButton` with `content_copy` and the label given by the screen (`Copy`, `Copy Public Key`). After a sensitive copy the screen's "copied" line appears under the button (`bodySmall`, `onSurfaceVariant`, polite live region) and stays while the screen is open, for example `Copied. It clears from the clipboard in 2 minutes.` Public values use the ordinary copy rules (§17).

Accessibility: `code` and `comparison` blocks set `contentDescription` to the characters separated by spaces with a comma between groups (`7 K 2 M, 9 Q X D, …`) so TalkBack spells them; role none. `publicKey`: `SSH public key, ending in %s. Use Copy Public Key to add it.` (last 6 characters). `fingerprint`: `Host key fingerprint` + the spelled value.

Tags: `secret.code` (text = the value), `secret.copy`, `secret.copied`.

---

## 10. Countdown row (`SecureCopyCountdown`)

Shown after every successful secure copy, on all API levels.

```
┌──────────────────────────────────────────────────────────┐
│ [timer] Copied “Atlas API token”. Clears in 0:42  Clear Now │  56 dp · secureContainer
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░            │  LinearProgressIndicator 2 dp, colour `secure`
└──────────────────────────────────────────────────────────┘
```

| Part | Spec |
|---|---|
| Container | `Surface`, `secureContainer`, content `onSecureContainer`, full width of its pane, no rounding |
| Text | `bodyMedium`, one line (name is ellipsised in the middle of the sentence if needed; `Clears in m:ss` never truncates); digits tabular (`fontFeatureSettings = "tnum"`). String: `Copied “%1$s”. Clears in %2$s` |
| Action | `TextButton` `Clear Now` (`onSecureContainer`); clears the clipboard at once |
| Bar | Drains linearly from full to empty over 60 s, driven by the real deadline (survives recomposition and rotation) |
| End | At expiry or after `Clear Now`: text becomes `Clipboard cleared.` for 3 s, bar hidden, then the row leaves. If another clip replaced ours before expiry (and that can be verified), the row leaves silently |
| Position | `library`: pinned between the filter row and the list (top of the list pane in two-pane). `editor`: pinned under the tab row (compact) or under the top app bar (detail pane). `process-text`: not shown (a Toast is used, the activity finishes) |
| Lifetime | Owned by an application-scoped holder; it shows on whichever of the two screens is visible and survives navigation between them. Leaving the app does not stop the timer |

A new secure copy restarts the row with the new name. An ordinary copy made in Snippets during the countdown replaces the clip, so the row leaves silently.

Accessibility: on appear announce `Copied “%s”. Clears from the clipboard in 60 seconds.`; the ticking text is not a live region; at the end announce `Clipboard cleared.` `Clear Now` is reachable as a button and as a custom action on the row.

Tags: `countdown.row`, `countdown.text`, `countdown.clear`, `countdown.progress`.

---

## 11. Form fields and validation

### 11.1 Labeled field (`LabeledField`)

```
 Name                                              caption: labelLarge, onSurfaceVariant, 4 dp below
┌──────────────────────────────────────────────┐
│ Meeting notes                                │   OutlinedTextField without a floating label
└──────────────────────────────────────────────┘   container surfaceContainerHigh · shape medium
 Supporting or error text                          bodySmall · 4 dp above · 16 dp start inset
```

- `OutlinedTextField` with `label = null`, `shape = MaterialTheme.shapes.medium`, colours: container `surfaceContainerHigh` (all states), unfocused border `outlineVariant` 1 dp, focused border `primary` 2 dp, error border `error` 2 dp. Min height 56 dp. The caption is a separate `Text` linked through semantics (the field's `contentDescription` = caption).
- Placeholder: `bodyLarge` (or the field's mono style), `onSurfaceVariant`.
- Read-only values use the same container without a border.

### 11.2 Keyboard options by field

| Field | Capitalisation | Autocorrect | Keyboard type | IME action | Notes |
|---|---|---|---|---|---|
| Search snippets, Search tags, Search Settings | none | off | Text | Search | |
| Name | sentences | on | Text | Next | single line |
| Snippet body (ordinary) | none | off | Text, multi-line | default (newline) | `monoBody`; smart punctuation is not applied by the app |
| Snippet body (secure, revealed) | none | off | Password (visible), multi-line | default (newline) | `IME_FLAG_NO_PERSONALIZED_LEARNING`; no autofill (`ContentType` none, `importantForAutofill = no`); no suggestions strip |
| Keyword | none | off | Ascii | Next | `monoToken`; prefix `\`; input sanitised on every change |
| Tags | none | off | Text | Done | |
| Repository | none | off | Uri | Next | |
| Branch, User Name | none | off | Text | Next | User Name: `ContentType.Username` |
| Access Token | none | off | Password | Go | `ContentType.Password` (Autofill may fill it); visibility toggle; Paste button |
| Recovery key / code, account key, kit code | characters | off | Password (visible) | Done | `monoToken` at 16 sp; upper-cased and grouped as typed; no personalised learning; Paste button |
| Backup password, Confirm password | none | off | Password | Next / Done | `ContentType.NewPassword` (new) or `Password` (open); visibility toggle |
| Final 8 characters (kit check) | characters | off | Password (visible) | Done | |

### 11.3 Validation

- Validate on submit and when a field loses focus after being edited; never while the user is still typing the first time, except live counters and live grouping.
- Error state: `isError = true`, error text replaces the supporting text (`error` colour), trailing `error` icon, the field keeps its input. The first invalid field receives focus and is scrolled into view; the error text is an assertive live region. Haptic `Reject` on a failed submit.
- A primary button is disabled only when its precondition is objectively unmet and visible (empty required field, passwords differ, counter incomplete). The reason is always on screen as supporting text.
- Server- or engine-side failures that are not about one field use a problem card (§7.4) under the form, not a field error.

### 11.4 Special fields

**Keyword field**: `OutlinedTextField` with `prefix = { Text("\\", style = monoToken, color = onSurfaceVariant) }`, placeholder `sig`. Trailing `warning` icon (decorative, `warning` tint) when a warning-level message applies and the field is not focused. Details in `screens-library-editor.md` §6.5.

**Tag field**: container as §11.1 holding a `FlowRow` (8 dp gaps, 8 dp inner padding): one `InputChip` per tag (label in the tag's text colour, container = tag fill, trailing `close` 18 dp with description `Remove tag %s`), then a `BasicTextField` (min width 96 dp, placeholder `work, email` shown only when there are no tags and no input). Tapping empty space focuses the input.

**Password field**: trailing `IconButton` `visibility` / `visibility_off` (descriptions `Show password` / `Hide password`).

**Code field**: trailing `IconButton` `content_paste` (description `Paste`); a `VisualTransformation` inserts a hyphen after every group; supporting text is a live counter until complete, for example `22 of 27 characters`. The stored value is the raw symbols; lower case, spaces and stray hyphens are accepted.

**Switch row**: `ListItem(headlineContent, supportingContent, trailingContent = Switch)`; the whole row toggles (`Modifier.toggleable(role = Role.Switch)`); the `Switch` itself is `clearAndSetSemantics`.

---

## 12. Settings rows (`SettingsRow`)

```
 [icon 24]  Sync                                              headline: bodyLarge
            On. Last synced at 9:04 PM.                       supporting: bodyMedium, onSurfaceVariant (live state)
```

`ListItem` with leading icon (`onSurfaceVariant`), headline, supporting text and an optional trailing element. No chevrons. Min height 56 dp (one line) / 72 dp (two lines); supporting text wraps freely.

| Variant | Headline colour | Trailing | Behaviour |
|---|---|---|---|
| Navigation | `onSurface` | none | Opens a screen, sheet or dialog. Titles that open another step end with `…` only where the iOS title does |
| Value / status (not clickable) | `onSurface` | none | Supporting text is the live value; long values can be selected by long-press where noted |
| Switch | `onSurface` | `Switch` | §11.4 switch row |
| Action | `primary` | optional 16 dp spinner while running | Runs at once (`Sync Now`, `Lock Now`, `Copy Public Key`) |
| Attention | `warning`, leading `warning` icon | none | A recovery action; supporting text = its explanation |
| Destructive | `error`, leading icon `error`-tinted | none | Always opens a confirmation |
| Disabled | M3 disabled colours | none | Supporting text states why (`Turn off Sync This Library first.`) in `onSurfaceVariant` at full opacity |
| Link | `primary`, trailing `open_in_new` 18 dp | | Opens the browser (Custom Tabs) |

Live state: supporting texts observe their source and update in place; changes are not announced unless the row is focused. Error states use `error` colour plus a leading `error` icon on the supporting line, never colour alone.

Search-result highlight: the target row's container animates `primaryContainer` → transparent over 700 ms after the pane scrolls it into view.

Tags: `settings.row.<key>`, with `.title`, `.detail`, `.switch`.

---

## 13. Progress step list (`ProgressSteps`)

```
 [✓]  Checking the repository            done: `check`, `success`
 [◌]  Creating the library…              running: CircularProgressIndicator 18 dp, `primary`; label ends with …
 [○]  Opening the library                pending: `radio_button_unchecked`, `outline`
 [✕]  Connecting                         failed: `error`, `error`; the problem card (§7.4) is shown below the list
```

- `Column` of rows: 24 dp icon slot, 12 dp gap, label `bodyLarge` (`onSurface`; pending steps `onSurfaceVariant`), 40 dp row height.
- Only real steps, in the order the operation runs them; a step is ticked when the operation reports it complete. Steps that do not apply to this run are not listed. When the operation exposes no phases, show a single running row.
- The list is a polite live region: each transition announces the new running label (the status line that iOS announces).
- While any step is running the owning screen blocks back and disables its close and Up controls (`DESIGN.md` §3.3).
- Tags: `progress.step.<n>` (1-based), `stateDescription` = `pending` / `running` / `done` / `failed`.

---

## 14. Secret screen template (`SecretScreen`)

Full-screen dialog (compact) / 560 dp dialog (larger). `FLAG_SECURE`. Used by: vault recovery key, Git recovery code, Cloud account key, Cloud recovery kit.

```
┌──────────────────────────────────────────────┐
│ [X]  Recovery Key                            │  top bar; X only where cancelling is allowed
│                                              │
│ Save Your Recovery Key                       │  headlineSmall, heading()
│ Store this somewhere safe. It is the only    │  bodyLarge, onSurfaceVariant
│ way to recover secure snippets if this       │
│ device’s vault key is lost.                  │
│ ┌──────────────────────────────────────────┐ │
│ │        7K2M-9QXD-4FTR-HV3N               │ │  SecretBlock (§9)
│ │        P8WC-6YJA-B5G                     │ │
│ └──────────────────────────────────────────┘ │
│ [ ⧉ Copy ]                                   │  FilledTonalButton
│ Copied. It clears from the clipboard in      │  bodySmall, appears after Copy
│ 5 minutes.                                   │
│ (optional warning or note)                   │  bodyMedium
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │              I’ve Saved It               │ │  Button (filled), full width (compact),
│ └──────────────────────────────────────────┘ │  end-aligned at 560 dp; pinned to the bottom,
└──────────────────────────────────────────────┘  nav-bar inset applied
```

Rules:

1. The value is shown once. It lives in a holder scoped to this route, is never written to saved state, logs or a `ViewModel` that outlives the route, and is wiped when the route leaves.
2. While the app is not resumed, everything below the top bar is replaced by `lock` 32 dp + `Hidden while Snippets is in the background.` *(Android)*. The value returns on resume.
3. Back and `X`: where the screen allows cancelling (vault setup) they cancel. Otherwise back opens the template's leave dialog (§16.3), which is the only other way out besides the primary button.
4. After process death the route is replaced by its "could not be shown" message as an error dialog on the parent screen (per screen).
5. Copy marks the clip sensitive and schedules clearing after the screen's lifetime (5 or 2 minutes); the copied line states the lifetime. Copy never advances the flow.
6. No screenshot hint, no "Save as file", no Print (D41).
7. Content scrolls; the primary button stays pinned.
8. Tags: `secret.screen` (root, plus a route tag such as `git.code-show`), `secret.heading`, `secret.body`, `secret.code`, `secret.copy`, `secret.copied`, `secret.note`, `secret.done`, `secret.close`, `secret.hidden`.

---

## 15. Review template (`ReviewScreen`, route `sync/review`)

Full-screen dialog (compact) / 560 dp dialog (larger). One layout for every sync halt and recovery action.

```
┌──────────────────────────────────────────────┐
│ [X]  Sync Stopped                            │
│                                              │
│ Apply These Deletions?                       │  headlineSmall (confirmation title, or the action title)
│                                              │
│ What happened                                │  titleSmall, heading()
│ Stopped because an unusually large deletion  │  bodyLarge: the status sentence, complete
│ arrived: cloud sync reported a batch …       │
│                                              │
│ What this does                               │  titleSmall
│ These deletions did not include proof of …   │  bodyLarge: the action's explanation
│                                              │
│ On this device                               │  titleSmall
│ [smartphone] 128 snippets. Nothing has been  │  bodyLarge
│ changed on this device yet.                  │
│                                              │
│ Details ▾                                    │  disclosure → `Code: mass_deletion` [copy]
│                                              │
│ [ Not Now ]              [ Apply Deletions ] │  TextButton · Button (error colours if destructive)
└──────────────────────────────────────────────┘
```

- Order is fixed: heading, what happened, what this does, on this device, details, actions.
- Primary button = the confirmation button title when the action has one, otherwise the action title. Destructive (`Apply Deletions`) uses `ButtonDefaults.buttonColors(containerColor = error, contentColor = onError)`.
- `Not Now` and `X` close without changes. While the action runs, the primary button shows a spinner, both buttons are disabled and back is blocked.
- A halt without an action (`a newer version of Snippets wrote this library`) shows no primary button; the only button is `Close`.
- Success closes the screen; the library row or Settings status shows the result. Failure keeps the screen and shows a problem card above the buttons.
- Tags: `review.screen`, `review.heading`, `review.happened`, `review.explanation`, `review.device`, `review.details`, `review.code`, `review.confirm`, `review.dismiss`.

Content per halt: `screens-settings-data.md` §6.

---

## 16. Dialog templates

### 16.1 Confirmation (`ConfirmDialog`)

M3 `AlertDialog`: title (`headlineSmall`), text (`bodyMedium`, `onSurfaceVariant`, paragraphs separated by 12 dp; scrolls when long), buttons as `TextButton`s, dismiss first, confirm last (end-aligned; stacked vertically when they do not fit, confirm on top).

```
┌────────────────────────────────────────────┐
│ Delete “Atlas API token”?                  │
│                                            │
│ This permanently removes the encrypted     │
│ snippet from this device and, when sync    │
│ is on, from your other devices.            │
│                                            │
│                        Cancel     Delete   │
└────────────────────────────────────────────┘
```

| Rule | Spec |
|---|---|
| Title | Names the object and the action, as a question for a choice (`Remove Secure Snippets?`) |
| Body | Consequence, what stays, whether it can be undone |
| Confirm | The verb (`Delete`, `Remove`, `Replace Keys`, `Trust New Key`); `error` colour when the iOS action is destructive; never `Yes` |
| Dismiss | `Cancel` (or the iOS dismiss title: `Not Now`, `Back`) |
| Third action | Optional neutral `TextButton` between them (`Plain Text Instead…`); with three buttons they are always stacked |
| Dismissal | Back and outside tap = the dismiss button. Dialogs that report progress (`dialog/switch-progress`) set `dismissOnBackPress = false`, `dismissOnClickOutside = false` and have no buttons |
| Icon | None, except `warning` in `error` tint for `GIT-HOSTKEY-CHANGED`-class dialogs noted per screen |
| Secure windows | `DialogProperties(securePolicy = SecureFlagPolicy.Inherit)`; `SecureOn` where the dialog itself shows secret material |

Tags: root = route tag (`dialog.delete-secure`), `dialog.title`, `dialog.message`, `dialog.confirm`, `dialog.dismiss`, `dialog.neutral`.

### 16.2 Error (`ErrorDialog`, route `dialog/error`)

Same component with a `Couldn’t …` title, the error sentence as the body and one button `OK` (plus an optional recovery button where a screen says so). Used only for failures of an action the user just took that have no better inline place. Root tag `dialog.error`; the title text identifies the case.

### 16.3 Secret-screen leave dialog

Title `Have You Saved It?`; body = the screen's own sentence (for example `Snippets can’t show this recovery code again. Without it, a new device can’t open this library.`); dismiss `Go Back`, confirm = the screen's primary button title. *(Android)* Root tag `dialog.secret-leave`.

---

## 17. Snackbar rules

One `SnackbarHost` per window, in the root scaffold, fed by an app-level `SnackbarController`.

| Rule | Spec |
|---|---|
| Use | Results of an action that need no decision (`Deleted “name”.`, `Imported 12 snippets.`), progress notes (`Reading import…`), and system authentication messages. Never for errors that need a decision, never for routine sync |
| Not used | Ordinary copy on API 33+ (the system overlay confirms); secure copy (countdown row); anything on secret screens |
| Text | One or two sentences, ends with a full stop, `bodyMedium`; names in `“ ”` |
| Action | At most one, a verb (`Undo`, `Share`); runs at most once (the action is cleared before its callback runs) |
| Duration | No action: 4 s (`SnackbarDuration.Short`). With an action: 10 s, or `AccessibilityManager.getRecommendedTimeoutMillis(10_000, FLAG_CONTENT_TEXT or FLAG_CONTENT_CONTROLS)` with a floor of 20 s when touch exploration is on. Progress notes stay until replaced by their result |
| Queue | A new snackbar replaces the current one immediately (dismiss, then show) |
| Position | Bottom, above the navigation-bar inset, the IME and the FAB (the FAB moves up with it through the scaffold). Compact: full width minus 16 dp. Medium and larger: max width 400 dp, bottom-start of the pane that raised it, 24 dp margins |
| Colours | M3 default (`inverseSurface`, `inverseOnSurface`, action `inversePrimary`) |
| Accessibility | Polite live region: `%message%` or `%message% %action% available.`; never takes focus; does not block touches outside itself |
| Outside the app | `process-text` finishes immediately, so it uses a platform `Toast` (`Toast.LENGTH_LONG`) for its two confirmations |

Ordinary-copy rule (applies to snippet copy, `Copy Share Link`, `Copy Public Key`, copying a failure code): API 33+ no snackbar; API 28–32 a snackbar with the string given by the screen.

Tags: `snackbar`, `snackbar.action`.

---

## 18. Buttons and menus

| Level | Component | Use |
|---|---|---|
| Primary | `Button` (filled) | One per screen at most: the action that completes the screen (`Connect`, `I’ve Saved It`, `Create Backup`, `New Snippet` in the empty state) |
| Secondary | `FilledTonalButton` | Prominent actions that do not complete the screen (`Reveal Secure Content`, `Copy`, Review-card action) |
| Peer of a primary | `OutlinedButton` | A refusal with equal weight (`Deny`) |
| Tertiary | `TextButton` | Dialog buttons, inline actions, links inside cards |
| Destructive | Same level as above with `error` colours | Text in `error` for `TextButton`; `error` / `onError` container for a filled destructive primary |
| Icon | `IconButton` (48 dp), `FilledTonalIconButton` for an "on" state | Top bar actions, row trailing actions |
| FAB | `ExtendedFloatingActionButton` (`primaryContainer`), icon `add`, label `New Snippet` | Library only; `expanded` while the list is at the top, collapses on scroll; small FAB below 480 dp height |

Buttons keep the M3 40 dp height inside a 48 dp target, labels in `labelLarge`, never truncated (they wrap). A button that starts work shows a 16 dp `CircularProgressIndicator` in place of its icon, keeps its width and is disabled until the work ends; its label switches to the in-progress form where the screen gives one (`Working…`, `Signing In…`).

Menus (`DropdownMenu`): items are `DropdownMenuItem` with a 24 dp leading icon and a `bodyLarge` label; groups separated by `HorizontalDivider`; at most seven items; destructive items last with icon and text in `error`; unavailable items are omitted, not disabled. Menus opened by long-press anchor at the touch point (`DropdownMenu(offset = …)`); those opened from the keyboard anchor at the row's start. Item tags: `menu.item.<action>`.
