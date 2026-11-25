# Snippets Android: design specification

Status: final for implementation, 2026-11-25. Owner: design lead.
Scope: the from-scratch Kotlin / Jetpack Compose / Material 3 app in `snippets-android/`.

This file is the system. The screen files apply it and must not contradict it.

| File | Contents |
|---|---|
| `DESIGN.md` | Principles, decisions, navigation, adaptive rules, theme tokens, motion, haptics, insets, conventions |
| `components.md` | Reusable components: anatomy, states, Compose building blocks |
| `screens-library-editor.md` | Library, tag sheet, sync sheet, editor, shared dialogs |
| `screens-secure.md` | Secure panel, vault, recovery key, authentication prompts, Settings › Secure Snippets |
| `screens-settings-data.md` | Settings home and search, Sync, provider switch, Review, Backup, import/export, Appearance, Diagnostics, About |
| `screens-git.md` | Git repository screen, connect sequence, recovery code, management, all failure codes |
| `screens-cloud.md` | Snippets Cloud (flagged builds only) |
| `screens-system.md` | Insert Snippet text action, share-in, deep links, document open, shortcuts, first run, test mode |
| `parity.md` | The 202-item checklist mapped to this spec |
| `open-questions.md` | Unsettled points, each with a default |

Inputs: `../ux-inventory.md` (behaviour; cited as "inv §n"), `research-library-editor.md` (RL), `research-security.md` (RS), `research-settings-sync.md` (RSS).

---

## 1. Design principles

1. **One tap to the clipboard.** The library exists to find an entry and copy it. On a phone a row tap copies. Nothing on the library screen may delay, cover or animate over that path: no dialogs for success, no banners over the list, no keyboard on cold start.
2. **Metadata is ordinary; the body is special.** Name, keyword, tags, pin and enabled state of a secure entry look and behave like any other entry's. Only the body is hidden, and it is hidden everywhere: list, search, preview, share, export, accessibility tree, screenshots.
3. **The system draws authentication; the app draws the state before and after.** Every unlock goes through `BiometricPrompt` with device-credential fallback. No in-app PIN, no fingerprint glyphs, no error when the user cancels.
4. **Local first, sync second.** The library never waits for sync, is never replaced by a sync error, and works with no account. Sync has three volumes only: a quiet status row, a status sentence in Settings, and one Review card when it needs the user.
5. **Every stop says three things.** What happened, what happened to the data on this device, and the next action. The button repeats the action as a verb. No "OK" on a destructive step, no "Are you sure?".
6. **Text before chrome.** Dense rows, no cards, no avatars, no illustrations. Colour is reserved for the single brand tint, tags, and three states (secure, warning, error). Every coloured signal also has a word or an icon.
7. **Native Android, same promises.** Material 3 components, predictive back, edge-to-edge, snackbars and the system clipboard overlay replace the iOS presentation. A capability or a safety property from the iPhone/iPad app is never dropped to get there.

---

## 2. Decisions

Source keys: `inv` = inventory section or checklist number, `RL`/`RS`/`RSS` = research document and section, link = Mobbin reference the decision leans on.

| # | Decision | Rationale | Source |
|---|---|---|---|
| D1 | Brand seed `#6D5EF5`; primary `#5544DC` light, `#C5C0FF` dark; custom static scheme is the default. | The README badge, the iOS indigo tint and the launcher icon agree on indigo-violet; terracotta was never the brand. | inv §14.1, Open q. 1 |
| D2 | Material You dynamic colour is offered in Settings › Appearance on Android 12+, **off by default**. Extended colours and tag colours stay fixed when it is on. | Keeps "must not regress" item 12.4-9 without letting a wallpaper turn primary orange and collide with the secure and warning colours. | inv §12.4, RS §6 q.10 |
| D3 | Phone library top = always-visible M3 `SearchBar` (never expands), tag chip row under it, FAB bottom-end. No bottom toolbar, no large title. | The bottom edge belongs to the gesture bar and IME on Android; a lookup tool never hides its lookup. The screen keeps the pane title `Snippets` for TalkBack and Recents. | RL §3.1, §3.11; [1Password list](https://mobbin.com/screens/d5304d9e-2e1d-4bbf-bdb0-40cdb34c6d2e?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D4 | Phone row tap copies; a trailing pencil `IconButton` opens the editor. In two-pane layouts the tap selects and the trailing button is Copy. | Product-owner decision; the visible button replaces the iOS one-time discovery of a hidden swipe. | Owner; RL §3.2; [Phantom rows](https://mobbin.com/screens/4d9778ed-2ba4-48d6-be47-e52696a05d14?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D5 | Swipe uses one committed action per direction: right = Edit, left = Pin/Unpin. Delete is never on a swipe. | Keeps the iOS safety property "Delete always needs a tap" with the native `SwipeToDismissBox` instead of a multi-button reveal. Pin is reversible, so it may commit. | inv §3.1 (15–18); RL §3.6 |
| D6 | Long-press (and right-click, Menu key) opens a `DropdownMenu` with Copy, Edit, Pin/Unpin, Duplicate, Delete. No multi-select mode in v1. | Parity item 19 is P0; iPhone has no multi-select, and a selection mode would be new scope. | inv §3.1 (19); RL §3.6 (declined) |
| D7 | Ordinary copy feedback: inline `Copied` state on the row for 1.5 s plus haptic. A snackbar `Copied “name”.` only on API 28–32. | Android 13+ shows the system clipboard overlay; a second confirmation is a platform anti-pattern and a "must not regress" item. | inv §12.4-6; RL §3.5; [Phantom](https://mobbin.com/screens/4d9778ed-2ba4-48d6-be47-e52696a05d14?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D8 | Secure copy shows a pinned countdown row `Copied “name”. Clears in 0:58` with `Clear Now` and a draining bar, on every API level. No snackbar. | Owner: the UI must say "clears in 60 s". The row carries the one fact the system overlay does not know. | Owner; RS §3.5; [Riot code timer](https://mobbin.com/screens/9c452965-105f-49b4-8b92-53258452e72d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D9 | Ordinary delete is immediate with an `Undo` snackbar on every window size. Secure delete confirms and has no undo. | One rule for phone and tablet; the iPad's confirm-then-⌘Z split is an iPad convention, not a safety property. | inv §4.5, Open q. 8; [1Password undo](https://mobbin.com/screens/e28306d2-8e5e-4ea4-94a5-bd0e1c3d5d5d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D10 | Phone editor has two tabs under the top app bar, `Content` and `Details` (`SecondaryTabRow`). Tablets show one form. | Keeps the iPhone capability (reach keyword, tags and switches without scrolling past a long body) but moves the switch from the bottom edge, where it collides with the IME, to the M3 tab position. | inv §3.3 (75, 76); RL §3.8 (single form declined for compact) |
| D11 | Autosave everywhere; back is never intercepted in the editor; no discard dialog exists. | Parity, and it lets predictive back animate without a handler. | inv §5.6; RL §3.8 |
| D12 | Secrets (vault recovery key, Git recovery code, Cloud account key, recovery kit) use one full-screen "secret screen" template, never an alert. | An alert cannot group a 27-symbol code, show a copy state or block screenshots per window. | RS §2.7, §3.7; RSS §3.4 J; [Aave backup code](https://mobbin.com/screens/af913d3b-ffe6-4a5a-acce-101f0abb15d0?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D13 | Acknowledgement on secret screens is one verb button (`I’ve Saved It`, `Done, I’ve Saved It`). No quiz, no checkbox, no typed characters. Back asks once. | Parity with iOS; every secret here can be reissued from a connected device, so the remedy is stated instead of adding gates. | inv §8.4; RS §5-2; [Coinbase key](https://mobbin.com/screens/73007b47-cdb2-452d-a4b4-d725d333e6c8?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D14 | Fields that take a recovery key or code are single monospaced fields with live grouping, a paste button and per-cause errors, in a full-screen dialog. | No text fields inside alerts; 27 boxes are wrong for long codes. | RS §3.9; [Meta Quest code](https://mobbin.com/screens/8451ca13-4a88-4e1a-b3b4-a1154553e67d?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D15 | A cancelled authentication prompt is silent everywhere. Lockout and hardware errors show the system's message in a snackbar. | Owner decision; iOS shows a lower-case error alert, which is a defect. | Owner; inv Open q. 11 |
| D16 | Vault and recovery error fragments (`the vault is locked`) are rewritten as sentences. | They are shown as dialog bodies. Table in `screens-secure.md` §9. | inv §6.9, Open q. 12 |
| D17 | `FLAG_SECURE` is set per window only while secret material can be on screen (list in §11). The library and ordinary editors stay capturable. | Names and keywords are not secret; users file bug reports with screenshots. | Owner; RS §3.12 |
| D18 | A revealed secure body is removed from the semantics tree; a describing sibling stands in. | Owner decision, parity with iOS. | Owner; inv §6.7 |
| D19 | Device noun is `this device` in every string. Authentication is `fingerprint, face or screen lock`. `Android Keystore` appears only in Key Storage. | One noun for phones, tablets and foldables. | Owner; inv Open q. 2 |
| D20 | "Local only" is the off state of `Sync This Library`, not an entry in the provider chooser. The provider row is always shown and reads `Not set up` on a fresh install. | Matches the engine (selected provider plus an on/off preference) and keeps parity item 126. Android has no default provider, so the row cannot be hidden as on iOS. | inv §7.3; Owner |
| D21 | Turning `Sync This Library` on with no provider set up opens setup (the Git screen, or the provider chooser in Cloud builds) instead of failing. | Avoids the dead-end status "no repository is connected". | inv Open q. 23 |
| D22 | Git setup stays one screen (form, then connected summary) with a real progress step list; decisions are dialogs; host-key trust, code entry and code display are full-screen. Failures are persistent inline problem cards, not alerts. | Follows the iOS state machine one-to-one (prompts drive retries) while meeting "typed error cards, not toasts". A multi-route wizard was declined: it would fork the flow from the reference implementation. | inv §8, §12.4-11; RSS §3.4 (wizard declined); [Tempo checks](https://mobbin.com/screens/e18d7a87-0f30-4a1f-a947-9e9e1a89cfa4?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D23 | Sync halts open a Review screen (what happened, what the action does, on this device, action). The Review screen is the confirmation; its primary button carries the iOS confirmation button title. | The iOS alert body is 80–150 words; a dialog would be a wall of text. | inv §10.3 (167); RSS §3.5; [Google Photos review](https://mobbin.com/screens/a2d85742-27e6-48ff-838c-a017b6598bf9?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D24 | The library's sync status is a list row (first item, scrolls away). It opens a status sheet. It becomes a Review card that cannot be dismissed while the cause remains. | Parity items 163–164 plus the "three volumes" rule. | inv §10.2; RSS §3.3 |
| D25 | Banner strings drop the word "cloud" (`Fetching your library…`). | The default Android provider is a Git repository. | inv §10.2 |
| D26 | Settings is a full-screen destination (list-detail on large windows), not a sheet with `Done`. | Android convention; back leaves. | inv §7.1; RSS §3.11 |
| D27 | Settings gains one Android-only pane, `Appearance` (theme, dynamic colour), and About gains `Open-Source Notices`. | Needed for D2 and for bundled-font and SSH-library licences. | — |
| D28 | The More menu is flat: the iOS `Transfer` submenu becomes three items behind a divider. | Nested `DropdownMenu`s are awkward on touch. | inv §3.1 (22) |
| D29 | Share offers `Share Text` (resolved text) and `Share Link` (`snippets://share`), plus `Copy Share Link`. | iOS shares the link, the old Android app shared the text; most chat apps do not linkify a custom scheme. | inv §4.7, §11.3, Open q. 10 |
| D30 | `Insert Snippet` lists every entry, disabled ones included, and returns secure text directly after authentication. | `Enabled` governs Mac expansion only; disabled entries can be copied on mobile, so they can be inserted. | inv §12.3, Open q. 7 |
| D31 | Tag pills always carry text; no colour-only dots. The pill fill is opaque (13 % of the tag colour composited over `surface`). | Colour-only signals fail for colour-blind users; an opaque fill keeps ≥ 4.5:1 on selected rows. | RL §3.2, §4-16 |
| D32 | Disabled entries are not dimmed with alpha. The name uses `onSurfaceVariant`, the keyword token is struck through, and the preview is prefixed `Disabled · `. | The row still copies; body text must stay ≥ 4.5:1. | inv §3.1 (7); RL §3.2 |
| D33 | A tag whose folded form is `conflict` renders in warning colours with a warning icon, and the sync sheet offers `Review Conflict Copies`. No resolution UI. | Makes conflict copies findable without new behaviour. | inv §4.10, Open q. 24; RSS §2.4 |
| D34 | Two panes at width ≥ 840 dp and height ≥ 480 dp. Medium width stays single-pane with phone behaviour. | Parity item 189 and the old app's rule; a 600 dp window cannot hold a 360 dp list and a usable editor. | inv §12.1; RL §5 q.12 |
| D35 | Tablet list keeps the `Pinned` header and the same three-line row as the phone. | One row component and one list model; the iPad's dots and flat list are not ported. | inv §3.4 (190); RL §3.2 |
| D36 | Hardware-keyboard shortcuts use Ctrl; the shortcut panel is the system Keyboard Shortcuts Helper. | Native; no custom overlay to maintain. | inv §3.6 (192) |
| D37 | Monospace is bundled JetBrains Mono (variable, OFL-1.1) with `FontFamily.Monospace` fallback; sans is the device default. | Secrets need unambiguous `0 O 1 l I`; the system monospace differs by vendor; screenshot tests need stable metrics. | RL §5 q.10 |
| D38 | No onboarding. First run opens the empty library with `New Snippet`, `Import…`, `Set Up Sync` and the line "Sync is optional". | Local-first; a fresh install must not look like it authored data. | RL §3.10; [Obsidian sync prompt](https://mobbin.com/screens/c464d280-72a1-4984-b7b9-02bed72b99db?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp) |
| D39 | The clipboard is read only on an explicit user action (`New from Clipboard`, a Paste button, copy with `{clipboard}`). | Android 12+ shows a toast on every read; unprompted reads look like spying in a secrets app. | RL §3.7 |
| D40 | Secure-copy clearing runs from an application-scoped timer with a one-shot `AlarmManager` backstop; if the app cannot read the clipboard to verify ownership, it clears anyway. | Owner decision. | Owner; inv Open q. 14 |
| D41 | No Print, no "Save as file" for secrets in v1; Copy and transcription only. | Parity with iOS; a file picker invites saving a key into a synced folder. | RS §6 q.7 |
| D42 | Snippets Cloud UI is absent (not disabled) when the build flag is off: no chooser row, no search entries, no strings shown. | Owner decision. | Owner; RSS §6 q.11 |
| D43 | Cloud copy follows the iOS strings; problem cards follow the old Android mapping. | Each is the richer source for its part. | inv §9, Open q. 21 |
| D44 | QR scanning uses the Google code scanner when Play services are present, otherwise `Paste Request Text` / typed code. No camera permission is declared. | Typed and pasted paths always work; de-Googled devices are not blocked. | inv §11.1; RS §6 q.11 |

---

## 3. Information architecture and navigation

Navigation 3: every route below is a `NavKey` (`@Serializable data object` or `data class`). Route names are stable identifiers used in tests and deep links inside the app; they are not user-visible. `{id}` is a snippet UUID.

Presentation kinds:

| Kind | Compact | Medium and expanded | Back |
|---|---|---|---|
| **screen** | Full window, `TopAppBar` with Up arrow | Same, or a pane when noted | Pops |
| **pane** | — | Slot of a list-detail scaffold | Scaffold default (`PopUntilScaffoldValueChange`) |
| **sheet** | `ModalBottomSheet`, drag handle | Same, max width 640 dp, centred | Dismisses |
| **dialog** | `AlertDialog` (`BasicAlertDialog` when it has fields) | Same | Dismisses = the dismiss button |
| **full-screen dialog** | Full window, close `X` at top start, title, optional top-end action | Centred `Dialog`, 560 dp wide, max height 90 %, scrim, no outside-tap dismiss | Same as `X` unless the route says "back asks" or "back blocked while working" |
| **menu** | `DropdownMenu` anchored to its trigger or touch point | Same | Dismisses |
| **system** | `BiometricPrompt`, document pickers, Sharesheet, Keyboard Shortcuts Helper | Same | System |

### 3.1 Phone (compact width) map

```
library                                  screen (start)
├─ library/more                          menu      (⋮ in the search bar)
├─ library/tags                          sheet     LIB-FILTER
├─ library/sync                          sheet     sync status
├─ library/row-menu/{id}                 menu      LIB-ROW-MENU
├─ editor/{id}                           screen    EDIT
│  ├─ editor/{id}/menu                   menu      EDIT-MORE
│  ├─ secure/recovery-key?mode=setup     full-screen dialog  SEC-RECOVERY-KEY
│  └─ dialog/make-ordinary               dialog    ALERT-MAKE-ORDINARY
├─ dialog/delete-secure                  dialog    ALERT-DELETE-SECURE
├─ dialog/clipboard-empty                dialog    ALERT-CLIP-EMPTY
├─ dialog/sync-opt-in                    dialog    ALERT-SYNC-OPT-IN
├─ dialog/screen-lock-required           dialog    (Android only)
├─ dialog/error                          dialog    all `Couldn’t …` alerts
├─ dialog/link-review                    dialog    LINK-REVIEW
├─ dialog/document-open                  dialog    (Android only)
├─ sync/review                           full-screen dialog  ALERT-RECOVERY-CONFIRM
├─ import/raycast                        dialog    IMPORT-RAYCAST
├─ import/quarantine-json | -backup      dialog    IMPORT-QUARANTINE-*
├─ backup/new-password                   full-screen dialog  ALERT-BACKUP-NEW-PW
├─ backup/open-password                  full-screen dialog  ALERT-BACKUP-OPEN-PW
└─ settings                              screen    SET (+ SET-SEARCH)
   ├─ settings/sync                      screen    SET-SYNC
   │  ├─ settings/sync/provider          sheet     SHEET-PROVIDER
   │  ├─ dialog/switch                   dialog    ALERT-SWITCH
   │  ├─ dialog/switch-progress          dialog    ALERT-SWITCH-PROGRESS (not dismissable)
   │  ├─ dialog/switch-attention         dialog    ALERT-SWITCH-ATTENTION
   │  ├─ settings/sync/git               screen    GIT
   │  │  ├─ git/host-key?kind=new|published|changed   full-screen dialog
   │  │  ├─ git/code-entry?purpose=connect|secure     full-screen dialog  GIT-CODE-ENTRY
   │  │  ├─ git/code-show                full-screen dialog  GIT-CODE-SHOW (secret screen)
   │  │  └─ dialog/git-*                 dialogs   GIT-MODE, -PLAIN-CONFIRM, -PUBLIC, -VISIBILITY-UNKNOWN,
   │  │                                            -FOREIGN-BRANCH, -JOIN-PLAIN, -REPLACEMENT, -NEW-CODE,
   │  │                                            -REPLACE-KEYS, -REMOVE
   │  └─ settings/sync/cloud             screen    CLOUD (flagged builds)
   │     ├─ cloud/sign-in?step=choose|key|save-key|device   full-screen dialog  CLOUD-SIGNIN
   │     ├─ cloud/account-key            full-screen dialog  CLOUD-KEY-REVEAL (secret screen)
   │     ├─ cloud/unlock                 sheet     CLOUD-UNLOCK
   │     ├─ cloud/pair-wait              full-screen dialog  CLOUD-PAIR-WAIT
   │     ├─ cloud/scan?purpose=device|kit  system scanner, or cloud/paste full-screen dialog
   │     ├─ cloud/approve                dialog    CLOUD-APPROVE
   │     ├─ cloud/kit                    full-screen dialog  CLOUD-KIT (secret screen + verify)
   │     ├─ cloud/kit-entry              full-screen dialog  CLOUD-KIT-ENTRY
   │     ├─ cloud/library-choice         dialog    CLOUD-LIBRARY-CHOICE
   │     └─ dialog/cloud-*               dialogs   disconnect, change-account, reset, neither, interrupted, unverified
   ├─ settings/secure                    screen    SET-VAULT
   │  ├─ secure/recovery-key?mode=add    full-screen dialog
   │  ├─ secure/restore                  full-screen dialog  SEC-RESTORE-KEY
   │  └─ dialog/remove-vault             dialog
   ├─ settings/backup                    screen    SET-BACKUP
   ├─ settings/appearance                screen    (Android only)
   ├─ settings/diagnostics               screen    SET-DIAG
   │  ├─ dialog/export-logs              dialog    (Android only)
   │  └─ dialog/delete-logs              dialog
   └─ settings/about                     screen    SET-ABOUT
      └─ settings/about/notices          screen    (Android only)

process-text                             separate activity, sheet-styled   PROCESS-TEXT
```

Entry points from outside the app: launcher (`library`), `snippets://share` and `snippets://new` (`library` + `dialog/link-review`), `ACTION_SEND text/plain` (`editor/{newId}`), `ACTION_VIEW` of a backup or JSON file (`library` + `dialog/document-open` or `backup/open-password`), `ACTION_PROCESS_TEXT` (`process-text`), launcher shortcuts (`library?focus=search`, `editor/{newId}`, new from clipboard).

### 3.2 Tablet and large window (two-pane) map

```
[ library (list pane) | editor/{id} (detail pane) or editor/empty ]     start
[ settings (list pane) | settings/<pane> (detail pane) ]                 replaces the library; Sync preselected
   └─ settings/sync/git, settings/sync/cloud, settings/about/notices     pushed inside the detail pane (Up arrow in the pane's bar)
```

- Sheets stay sheets. Full-screen dialogs become centred 560 dp dialogs. `process-text` becomes a centred 560 × 640 dp dialog-styled activity.
- `sync/review` opened from the library is a centred dialog; the library stays visible behind the scrim.
- There is no navigation rail and no bottom bar: the app has one destination; Settings is an action.

### 3.3 Back behaviour

Back is handled by the app only while one of these transient states is active; otherwise the system's predictive back (back-to-home preview from `library`, cross-activity/back-stack animation elsewhere) runs untouched. Order, first match wins:

1. An open menu, dialog or sheet: dismiss it (rules per route).
2. A full-screen dialog that is **working** (Git step running, switch in progress, pairing submit): back is blocked; the `X` is disabled; `BackHandler(enabled = true) {}`.
3. A secret screen before acknowledgement: back opens its "have you saved it" dialog.
4. Library with a non-empty search query: clear the query and focus. (The IME, when visible, is closed by the system first.)
5. Compact width, `editor/{id}`: pop to `library` (autosave has already written; a blank draft is discarded).
6. Two-pane: back from `library` + editor leaves the app; the selection is not a back-stack entry.
7. `settings/*`: pop one level; from `settings` return to `library`.

Tag filters are not cleared by back. Up (the arrow in a top app bar) always equals back.

### 3.4 State that survives

| State | Rotation / resize / fold | Process death | Cold start |
|---|---|---|---|
| Back stack, selected snippet, scroll positions, editor tab | kept | kept (`rememberSaveable`, Nav3 saved state) | reset to `library` |
| Search query, tag filters | kept | kept | cleared |
| Git form draft: address, branch, user name | kept | kept | kept until connected or removed |
| Access token, recovery key/code, account key, revealed secure body, backup passwords | kept in memory only | **never saved**; the screen returns to its entry state | — |
| Vault session | kept | locked | locked |

A secret screen that cannot come back after process death shows its replacement message (see `components.md` §14).

---

## 4. Adaptive rules

Window size classes from `currentWindowAdaptiveInfo()` (material3-adaptive 1.2.0).

| Class | Width | Layout |
|---|---|---|
| Compact | < 600 dp | Single pane. Horizontal margin 16 dp. Editor uses tabs. |
| Medium | 600–839 dp | Single pane, phone behaviour (tap copies). Library list and forms are centred with max width 640 dp; margin 24 dp. Editor uses tabs. |
| Expanded | 840–1199 dp, height ≥ 480 dp | Two panes. List pane 360 dp, detail fills the rest. Row tap selects. Editor is one form, max width 720 dp, centred in the pane. |
| Large / extra-large | ≥ 1200 dp, height ≥ 480 dp | Two panes. List pane 400 dp. Detail content max width 720 dp, start-aligned with a 48 dp start margin. |
| Any width, height < 480 dp | — | Single pane regardless of width. FAB is the small variant; empty states scroll. |

- Scaffold: `NavigableListDetailPaneScaffold` (or `ListDetailSceneStrategy` from `adaptive-navigation3`; the behaviour here is the contract). Directive: default `calculatePaneScaffoldDirective(currentWindowAdaptiveInfo())` with `maxHorizontalPartitions` forced to 1 below 840 dp or below 480 dp height, `horizontalPartitionSpacerSize = 0.dp`, hinge bounds excluded as the default directive does. No drag handle; pane widths are fixed.
- Panes are separated by a 1 dp `VerticalDivider` in `outlineVariant`. Both panes use `surface`.
- Settings uses the same scaffold with a 320 dp list pane (360 dp at ≥ 1200 dp).
- Moving between classes (rotation, fold, resize) keeps the selected snippet: expanded → compact shows `editor/{id}` on top of `library`; compact `editor/{id}` → expanded shows both panes. A blank draft follows the same rule.
- Pointer: rows and buttons show the M3 hover state layer (8 % `onSurface`); right-click opens the row menu.
- Font scale up to 2.0: single-line texts may wrap to two lines where the component says so; no fixed heights on text containers; buttons wrap their labels. Verified sizes: 1.0, 1.3, 2.0.

---

## 5. Theme tokens: colour

Seed `#6D5EF5` (HCT hue 289.7, chroma 71.3). Palettes: primary = seed hue at seed chroma; secondary = seed hue, chroma 18; tertiary = hue 335, chroma 44 (the icon's magenta); neutral = seed hue, chroma 4; neutral-variant = seed hue, chroma 9; error = M3 baseline. Tones follow the M3 role mapping. Implement as `lightColorScheme(…)` / `darkColorScheme(…)` literals; do not generate at run time.

### 5.1 Material 3 roles

| Role | Light | Dark |
|---|---|---|
| primary | `#5544DC` | `#C5C0FF` |
| onPrimary | `#FFFFFF` | `#2600A1` |
| primaryContainer | `#E4DFFF` | `#3C24C5` |
| onPrimaryContainer | `#3C24C5` | `#E4DFFF` |
| inversePrimary | `#C5C0FF` | `#5544DC` |
| secondary | `#5E5C74` | `#C7C3E0` |
| onSecondary | `#FFFFFF` | `#302E44` |
| secondaryContainer | `#E4DFFC` | `#46445C` |
| onSecondaryContainer | `#46445C` | `#E4DFFC` |
| tertiary | `#874780` | `#FBADEE` |
| onTertiary | `#FFFFFF` | `#52184F` |
| tertiaryContainer | `#FFD7F5` | `#6C2F67` |
| onTertiaryContainer | `#6C2F67` | `#FFD7F5` |
| error | `#BA1A1A` | `#FFB4AB` |
| onError | `#FFFFFF` | `#690005` |
| errorContainer | `#FFDAD6` | `#93000A` |
| onErrorContainer | `#93000A` | `#FFDAD6` |
| background | `#FCF8FD` | `#141316` |
| onBackground | `#1C1B1F` | `#E5E1E6` |
| surface | `#FCF8FD` | `#141316` |
| onSurface | `#1C1B1F` | `#E5E1E6` |
| surfaceVariant | `#E5E0ED` | `#474550` |
| onSurfaceVariant | `#474550` | `#C8C5D1` |
| surfaceTint | `#5544DC` | `#C5C0FF` |
| inverseSurface | `#313034` | `#E5E1E6` |
| inverseOnSurface | `#F4EFF4` | `#313034` |
| outline | `#787681` | `#928F9B` |
| outlineVariant | `#C8C5D1` | `#474550` |
| scrim | `#000000` | `#000000` |
| surfaceDim | `#DDD9DD` | `#141316` |
| surfaceBright | `#FCF8FD` | `#3A393C` |
| surfaceContainerLowest | `#FFFFFF` | `#0E0E11` |
| surfaceContainerLow | `#F6F2F7` | `#1C1B1F` |
| surfaceContainer | `#F1ECF1` | `#201F23` |
| surfaceContainerHigh | `#EBE7EC` | `#2A292D` |
| surfaceContainerHighest | `#E5E1E6` | `#353438` |

### 5.2 Extended semantic colours

Exposed through `LocalSnippetsColors` (a `staticCompositionLocalOf<SnippetsColors>`), four roles each.

| Role | Light | Dark | Used for |
|---|---|---|---|
| secure | `#7D5700` | `#FFBA30` | Lock glyphs, secure panel accents, `Lock` action. Never used without a lock icon or the word "Secure". |
| onSecure | `#FFFFFF` | `#422C00` | |
| secureContainer | `#FFDEAB` | `#5F4100` | Countdown row, secure panel badge |
| onSecureContainer | `#5F4100` | `#FFDEAB` | |
| warning | `#9B4500` | `#FFB68E` | Keyword warnings, Review card, conflict tag, non-destructive attention. Never used without a warning icon or a title. |
| onWarning | `#FFFFFF` | `#532200` | |
| warningContainer | `#FFDBC9` | `#763300` | Review card container, conflict pill |
| onWarningContainer | `#763300` | `#FFDBC9` | |
| success | `#216C2E` | `#8BD88D` | Completed progress steps, "matches published fingerprint", verified states |
| onSuccess | `#FFFFFF` | `#00390F` | |
| successContainer | `#A7F5A7` | `#00531A` | (reserved) |
| onSuccessContainer | `#00531A` | `#A7F5A7` | |

`error` roles are for destructive actions, failed steps, validation errors and halts that risk data (changed host key, mass deletion). `warning` is for attention without loss.

Dynamic colour on (D2): the 36 M3 roles come from `dynamicLightColorScheme` / `dynamicDarkColorScheme`; the 12 extended roles and all tag colours stay as specified here.

### 5.3 Tag palette

Index = FNV-1a 64 (folded tag) mod 12, same order as the Apple apps (red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown).

| # | Light text | Light fill | Dark text | Dark fill |
|---|---|---|---|---|
| 0 red | `#BA1A1A` | `#F3DBDF` | `#FFB4AB` | `#332829` |
| 1 orange | `#A63C00` | `#F1E0DC` | `#FFB691` | `#332826` |
| 2 yellow | `#785900` | `#EBE3DC` | `#F5C344` | `#312A1C` |
| 3 green | `#2D6A35` | `#E1E6E3` | `#91D69A` | `#242C27` |
| 4 mint | `#006B5B` | `#DBE6E8` | `#76D9C3` | `#212D2C` |
| 5 teal | `#006A6A` | `#DBE6EA` | `#80D5D5` | `#222C2F` |
| 6 cyan | `#00677A` | `#DBE5EC` | `#5DD5EF` | `#1D2C32` |
| 7 blue | `#005AC1` | `#DBE3F5` | `#A9C7FF` | `#272A34` |
| 8 indigo | `#4F56A9` | `#E6E3F2` | `#BEC2FF` | `#2A2A34` |
| 9 purple | `#7B4E9D` | `#EBE2F1` | `#E9B7FF` | `#302834` |
| 10 pink | `#A43A69` | `#F1DFEA` | `#FFB0CD` | `#33272E` |
| 11 brown | `#765847` | `#EBE3E5` | `#E5BFA9` | `#2F2929` |

Fills are opaque literals (13 % of the text colour over `surface`). Exception: the `conflict` tag uses `onWarningContainer` on `warningContainer` (D33).

### 5.4 Contrast (WCAG 2.x ratios, computed)

| Pair | Light | Dark |
|---|---|---|
| onSurface on surface | 16.30 | 14.32 |
| onSurface on surfaceContainerHigh (field surfaces) | 14.01 | 11.18 |
| onSurface on surfaceContainerHighest | 13.25 | 9.56 |
| onSurface on secondaryContainer (selected row) | 13.26 | 7.25 |
| onSurfaceVariant on surface | 8.94 | 10.90 |
| onSurfaceVariant on surfaceContainer | 8.06 | 9.65 |
| onSurfaceVariant on surfaceContainerHigh | 7.68 | 8.51 |
| onSurfaceVariant on surfaceContainerHighest | 7.27 | 7.27 |
| onSurfaceVariant on secondaryContainer | 7.27 | 5.51 |
| primary on surface | 6.16 | 10.89 |
| primary on surfaceContainerHighest | 5.00 | 7.27 |
| primary on secondaryContainer | 5.01 | 5.51 |
| onPrimary on primary | 6.47 | 7.74 |
| onPrimaryContainer on primaryContainer | 7.24 | 7.24 |
| onSecondaryContainer on secondaryContainer | 7.25 | 7.25 |
| onTertiaryContainer on tertiaryContainer (search highlight) | 7.27 | 7.27 |
| error on surface | 6.15 | 10.90 |
| error on surfaceContainerHigh | 5.28 | 8.51 |
| onError on error | 6.46 | 7.72 |
| onErrorContainer on errorContainer | 7.24 | 7.24 |
| inverseOnSurface on inverseSurface (snackbar text) | 11.54 | 10.13 |
| inversePrimary on inverseSurface (snackbar action) | 7.71 | 5.00 |
| secure on surface / on surfaceContainerHighest | 6.18 / 5.02 | 10.86 / 7.25 |
| secure on secondaryContainer | 5.03 | 5.49 |
| onSecureContainer on secureContainer | 7.26 | 7.26 |
| warning on surface / on surfaceContainerHighest | 6.16 / 5.01 | 10.87 / 7.26 |
| onWarningContainer on warningContainer | 7.23 | 7.23 |
| success on surface / on surfaceContainerHighest | 6.15 / 5.00 | 10.85 / 7.24 |
| Tag text on its fill (worst of 12) | 4.87 | 8.35 |
| outline on surface (non-text, needs 3.0) | 4.25 | 5.84 |
| outline on surfaceContainerHigh (field border) | 3.65 | 4.56 |

All text pairs used by this spec are ≥ 4.5:1. `outlineVariant` (1.62 / 1.97) is decorative only: dividers and unfocused borders that also have a fill difference; it never carries meaning alone. M3 disabled content (`onSurface` at 38 %) is used only for controls that are really disabled, never for entries.

### 5.5 Splash and launcher

- Launcher: adaptive icon; foreground = the existing artwork (`app/src/main/res/drawable-nodpi/snippets_app_icon.png`, redrawn to fit the 66 dp safe zone), background `#080711`, monochrome layer from `ic_launcher_monochrome.xml`.
- Splash (`Theme.Snippets.Starting`, `androidx.core:core-splashscreen`): background `#FCF8FD` light, `#141316` dark; icon = launcher foreground on its `#080711` disc; no branding image; exit = default fade, 200 ms. (The old `#FFF8F4` / `#101114` splash colours are retired with the terracotta scheme.)
- Status and navigation bars: transparent; icon appearance follows the theme (`enableEdgeToEdge()` with `SystemBarStyle.auto`).

---

## 6. Typography

Sans: `FontFamily.Default` (device font, no bundling). Monospace: JetBrains Mono variable font bundled as `res/font/jetbrains_mono.ttf` (weights 400–600 through `FontVariation`), fallback `FontFamily.Monospace`. Ligatures off (`fontFeatureSettings = "liga 0, calt 0"`). All sizes are `sp` and follow the system font scale.

### 6.1 M3 roles (sizes are M3 defaults; only the listed weights differ)

| Role | Size / line | Weight | Used for |
|---|---|---|---|
| headlineSmall | 24 / 32 | 400 | Secret-screen headings, Review heading |
| titleLarge | 22 / 28 | 400 | Top app bar titles of screens, empty-state titles |
| titleMedium | 16 / 24 | 500 | Row name, dialog section labels, settings pane titles in two-pane mode |
| titleSmall | 14 / 20 | 500 | Section headers (`Pinned`, `Library`, `Support`) |
| bodyLarge | 16 / 24 | 400 | Text-field input (sans fields), settings row headline, dialog body in full-screen dialogs |
| bodyMedium | 14 / 20 | 400 | Row preview, supporting text, `AlertDialog` body, empty-state message, snackbar |
| bodySmall | 12 / 16 | 400 | Footers, status lines, helper text, counters |
| labelLarge | 14 / 20 | 500 | Buttons, tabs, field captions above fields, `Copied` state |
| labelMedium | 12 / 16 | 500 | Row time, chip counts, badges |
| labelSmall | 11 / 16 | 500 | Tag pills, `+N` |

Top app bar title in the editor uses titleMedium (one line, ellipsis) so long names fit beside two actions.

### 6.2 Monospace styles (extended, `LocalSnippetsTypography`)

| Style | Size / line | Weight | Letter spacing | Used for |
|---|---|---|---|---|
| monoBody | 14 / 20 | 400 | 0 | Snippet body field, placeholder preview, link-review preview |
| monoToken | 13 / 20 | 500 | 0 | Keyword token in rows, keyword field input and prefix, `Existing ·` line, suggestion chips |
| monoKey | 13 / 20 | 400 | 0 | SSH public key, fingerprints, confirmation-code captions |
| monoCode | 22 / 32 | 600 | 0.5 sp | Recovery key, recovery code, account key, comparison codes |
| monoCodeLarge | 28 / 36 | 600 | 1 sp | Pairing confirmation code (short codes only) |

`monoCode` is capped at font scale 1.3 (`fontSize` computed with `min(fontScale, 1.3f)`) so a four-symbol group never breaks; the text is also announced character by character (see `components.md` §9).

---

## 7. Shape, spacing, elevation

**Shape** (M3 defaults, set explicitly in `Shapes`): extraSmall 4 dp, small 8 dp, medium 12 dp, large 16 dp, extraLarge 28 dp, full = `CircleShape`.

| Element | Shape |
|---|---|
| Keyword token, search highlight span | extraSmall (4 dp) |
| Tag pill, chips | small (8 dp) |
| Field surfaces, secure panel, secret block, selected row, problem and Review cards, preview block | medium (12 dp) |
| FAB | large (16 dp) |
| Dialogs, bottom sheet top corners | extraLarge (28 dp) |
| Search bar, buttons | full |

**Spacing** (4 dp grid): `xs` 4, `s` 8, `m` 12, `l` 16, `xl` 24, `xxl` 32, `xxxl` 48.

| Use | Value |
|---|---|
| Screen horizontal margin | 16 dp compact; 24 dp medium and in panes |
| Between a caption and its field | 4 dp |
| Between fields in a form | 16 dp |
| Between form sections | 24 dp |
| Row padding | 16 dp start, 4 dp end (before the 48 dp trailing button), 12 dp vertical |
| Between row lines | 2 dp (line 1 → 2), 6 dp (line 2 → tags) |
| Chip gap | 8 dp horizontal, 8 dp vertical when wrapping |
| Dialog content padding | 24 dp (M3 default) |
| List bottom padding | navigation-bar inset + 88 dp when a FAB is present, else inset + 16 dp |

**Elevation**: tonal, no shadows on content. Rows, cards and field surfaces: level 0, distinguished by container colour and a 1 dp `outlineVariant` border where stated. Scrolled top app bar: container `surfaceContainer` (no shadow). Menus: level 2. FAB: level 3. Dialogs and sheets: M3 defaults (`surfaceContainerHigh` dialog, `surfaceContainerLow` sheet). Snackbar: level 3, `inverseSurface`.

---

## 8. Icons

Material Symbols **Outlined**, weight 400, grade 0, optical size 24, imported as vector drawables named `ic_<symbol>` (do not depend on `material-icons-extended`). Filled variant (`FILL 1`) only for the on-state of a toggle. Default size 24 dp; inline status glyphs 16 dp; empty-state glyph 40 dp. Tint `onSurfaceVariant` unless stated.

| Symbol | Used for |
|---|---|
| `search` | Search bar leading, settings search |
| `arrow_back` | Up; search bar leading while searching |
| `close` | Clear query, full-screen dialog close, remove tag (18 dp) |
| `more_vert` | Library More, editor More |
| `filter_list` | Tag filter button |
| `add` | FAB |
| `edit` | Row trailing (phone), swipe-right background, menu Edit |
| `content_copy` | Copy actions, row trailing (two-pane), secret-block Copy |
| `check` | `Copied` state, selected chip, selected provider, done step |
| `push_pin` | Pin glyph (filled, `primary`), menu Pin / Unpin, swipe-left background |
| `lock` | Secure glyph (`secure`), locked panel, Secure Snippets settings row |
| `lock_open` | Revealed panel header |
| `pause_circle` | Disabled glyph |
| `delete` | Delete (menu), Remove rows (`error`) |
| `share` | Share Text, share public key |
| `link` | Share Link, Copy Share Link |
| `file_copy` | Duplicate |
| `content_paste` | New from Clipboard, Paste buttons |
| `file_open` | Import |
| `file_save` | Export for Sharing, Export Logs |
| `enhanced_encryption` | Encrypted Backup |
| `settings` | Settings |
| `sync` | Sync row in Settings, Sync Now |
| `cloud` | Snippets Cloud provider; "preparing" sync state |
| `cloud_download` | Waiting for the first fetch |
| `cloud_done` | Synced |
| `cloud_off` | Offline / host unreachable |
| `sync_problem` | Halted |
| `person_alert` | Needs authentication |
| `lock_clock` | Waiting for the vault |
| `system_update` | Newer schema: update needed |
| `warning` | Warning states, keyword warning, conflict pill (12 dp) |
| `error` | Failed step, error cards |
| `info` | About, informational notes |
| `commit` | Git repository provider |
| `smartphone` | "On this device" facts |
| `key` | Recovery key / code rows, SSH key section, account key |
| `hard_drive` | Backup settings row |
| `troubleshoot` | Diagnostics settings row |
| `palette` | Appearance settings row |
| `label` | Tag icon in the filter sheet, `No Tags Yet` |
| `visibility` / `visibility_off` | Show / hide password and code fields |
| `open_in_new` | External links (token page, deploy keys, GitHub) |
| `expand_more` / `expand_less` | Disclosures (`Preview Placeholders`, `Details`) |
| `qr_code_scanner` | Scan actions |
| `timer` | Countdown row, expiry lines |
| `keyboard` | Keyboard Shortcuts |
| `radio_button_unchecked` | Pending step |
| `swap_horiz` | Switch and Sync |
| `devices` | Approve a device, other-device sign-in |
| `refresh` | Check Again, Try Again |
| `description` | Empty-library glyph, snippet glyph in Insert Snippet header |
| `search_off` | No-results glyph |

---

## 9. Motion

Scheme: `MotionScheme.standard()` (not expressive). Tokens named below are the M3 motion tokens.

| Where | Transition | Duration / easing |
|---|---|---|
| Forward / back between screens (`library` ↔ `editor`, settings levels) | Shared axis X: 30 dp slide plus fade | `DurationMedium2` 300 ms, `EasingEmphasizedDecelerate` in / `EasingEmphasizedAccelerate` out |
| Predictive back | Nav3 `predictivePopTransitionSpec` default (scale to 90 %, 8 dp inset corners) | System-driven |
| Full-screen dialog open / close (compact) | Slide up 100 % + fade / reverse | 400 ms `EasingEmphasized` / 200 ms `EasingEmphasizedAccelerate` |
| Detail pane content change (two-pane) | Fade through | 200 ms `EasingStandard` |
| Editor tab change | Shared axis X, 30 dp, direction follows tab order | `DurationMedium2` |
| Row `Copied` state | Cross-fade of line 2; container colour to `secondaryContainer` and back | 100 ms in, hold 1500 ms, 300 ms out, `EasingStandard` |
| Row insert / remove / reorder (delete, undo, pin) | `Modifier.animateItem()` | `fadeIn/Out` 200 ms, placement spring `defaultSpatialSpec()` |
| Swipe background reveal | Icon scales 1.0 → 1.15 when armed | 100 ms `EasingStandard` |
| FAB extend / collapse on scroll | `ExtendedFloatingActionButton(expanded = …)` default | default |
| Countdown bar | Linear, real time | 60 s linear (or the secret's lifetime) |
| Disclosure (`Preview Placeholders`, `Details`) | `expandVertically` + fade | `DurationShort4` 200 ms |
| Settings search-result highlight | Row container `primaryContainer` → transparent | hold 400 ms, fade 300 ms (700 ms total) |
| Progress steps | Icon cross-fade pending → running → done | `DurationShort2` 100 ms |

**Reduced motion** (`Settings.Global.ANIMATOR_DURATION_SCALE == 0f`, exposed as `LocalReducedMotion`): slides and scales become 100 ms fades or cuts; `animateItem` uses fade only; the swipe icon does not scale; the countdown bar still drains (it is information) but the row does not animate in; the `Copied` container flash is skipped (the text swap stays). Nothing loops.

---

## 10. Haptics

Through `LocalHapticFeedback` (Compose UI 1.8+ constants). Haptics follow the system touch-feedback setting. Background sync state changes never produce haptics.

| Event | `HapticFeedbackType` |
|---|---|
| Copy succeeded (ordinary or secure) | `Confirm` |
| Nothing to copy; authentication failed or locked out | `Reject` |
| Authentication cancelled | none |
| Long-press opens the row menu | `LongPress` |
| Swipe crosses the commit threshold (arm) | `GestureThresholdActivate` |
| Swipe falls back under the threshold (disarm) | `SegmentTick` |
| Pin / unpin | `ToggleOn` / `ToggleOff` |
| `Enabled`, `Secure`, sync and appearance switches | `ToggleOn` / `ToggleOff` |
| Delete (ordinary or after confirming secure) | `Confirm` |
| Tag filter chip toggled | `SegmentTick` |
| Secret copied (`Copy` on a secret block) | `Confirm` |
| Clipboard cleared by timer | none |
| Validation error on submit (wrong code, password mismatch) | `Reject` |

On API levels where a constant is unavailable Compose falls back to `ContextClick` or to no effect; do not add `Vibrator` calls.

---

## 11. Platform rules

**Touch targets.** Every interactive element ≥ 48 × 48 dp (`minimumInteractiveComponentSize`), including chip close icons (the visual is 18 dp inside a 48 dp target that may overlap the chip, not a neighbour). Rows ≥ 56 dp high. Adjacent targets ≥ 8 dp apart or sharing a row-wide ripple.

**Edge-to-edge** (mandatory at target 36).
- `enableEdgeToEdge()`; every `Scaffold` uses `contentWindowInsets = WindowInsets.safeDrawing`.
- Top bars and the search bar apply `statusBars` + `displayCutout` (horizontal) insets as padding; the bar's container colour extends under the status bar.
- Lists scroll under the navigation bar: `contentPadding` bottom = `navigationBars` inset + the value from §7. No scrim behind gesture navigation; with three-button navigation the system's translucent scrim is kept (`isNavigationBarContrastEnforced = true`).
- FAB, snackbar host, bottom buttons of full-screen dialogs and the countdown row apply `navigationBars` (and `ime`) insets as padding.
- Horizontal `displayCutout` insets apply to content in landscape; list row backgrounds extend to the edge, their content does not.
- Never register system gesture exclusion rects. Row swipes start inside the 16 dp content inset.

**IME.**
- `android:windowSoftInputMode="adjustResize"`; containers that scroll use `imePadding()`; a focused field is brought into view (`BringIntoViewRequester`) with 16 dp clearance.
- No keyboard on cold start. The search field takes focus only on tap, Ctrl+F, or the `Search` launcher shortcut.
- IME actions: search field `Search` (hides the keyboard, keeps the query); Name `Next` (→ body); Keyword `Next` (→ Tags); Tags `Done`; single-field dialogs `Done` = primary action; Git form `Next` through visible fields, `Go` on the last one (= `Connect`).
- Keyboard options by field are listed in `components.md` §11.
- FAB hides while the IME is visible. Snackbars sit above the IME.

**FLAG_SECURE.** Set on the activity window (and through `SecureFlagPolicy.SecureOn` on every `Dialog`, `ModalBottomSheet` and `Popup` that belongs to it) while any of these is composed: a secure body in the `revealed` or `unlocking` state; `secure/recovery-key`; `secure/restore` with input; `git/code-show`; `git/code-entry` with input; `cloud/account-key`; `cloud/sign-in` steps `key`, `save-key`, `device`; `cloud/pair-wait`; `cloud/approve`; `cloud/kit`; `cloud/kit-entry`; `backup/new-password` and `backup/open-password`; `process-text` after a secure result is authenticated. Cleared when none is. On API 35+ the same composables also set `contentSensitivity = Sensitive`.

**Leaving the foreground** (`ProcessLifecycleOwner` `onStop`): flush pending writes, lock the vault (revealed bodies leave composition), push a waiting Git change (WorkManager one-time request; expedited on API 31+). Secret screens stay on the back stack but render their "hidden while away" state until resumed; codes are never visible in Recents (FLAG_SECURE already blanks the preview).

**Clipboard.** Every clip the app writes that is secure or is recovery material sets `ClipDescription.EXTRA_IS_SENSITIVE` (`"android.content.extra.IS_SENSITIVE"` before API 33). Lifetimes: secure body 60 s; vault recovery key 5 min; Git recovery code, Cloud account key and recovery-kit code 2 min. At expiry: if the primary clip is readable and is not ours, leave it; otherwise call `clearPrimaryClip()`.

**Accessibility defaults.**
- Every screen sets a pane title (`Modifier.semantics { paneTitle = … }`) equal to its visible title (`library`: `Snippets`).
- Headings: section headers and dialog titles set `heading()`.
- Status lines that change while the user waits are polite live regions; errors are assertive.
- Icon-only buttons have a content description equal to their tooltip (`TooltipBox` + `PlainTooltip`, shown on long-press and hover).
- Decorative icons have `contentDescription = null`.
- Traversal order follows reading order; in the library: search bar, filter row, countdown row, sync row, list, FAB.

---

## 12. Copy and string conventions

- English only; every string is a resource. Plurals use `<plurals>` (`N snippet(s)` in the iOS copy becomes a proper plural). Names are inserted with `“%1$s”` (typographic quotes).
- Typographic apostrophes (`’`) and ellipses (`…`). No exclamation marks. Title Case for screen titles, dialog titles, buttons and menu items; sentence case for bodies, supporting text and status lines.
- A menu item or row that opens a further step ends with `…`.
- Fixed terms: `Secure` (adjective on an entry), `vault`, `recovery key` (vault), `recovery code` (Git library), `account key` and `recovery kit` (Snippets Cloud), `screen lock`, `this device`, `library`, `repository`, `access token`. The four secrets are never called by each other's names.
- Errors start with `Couldn’t …` as dialog titles; the body is a full sentence that says what was not changed where that is known, then the next step.
- Strings in the screen files are final. Where a string differs from the iOS string, the file's "Changed strings" table lists it with the reason. Strings marked *(Android)* have no iOS counterpart.
- Resource ids: `<area>_<element>[_<variant>]`, for example `library_search_placeholder`, `git_error_token_refused_message`.

## 13. Test tags

`Modifier.testTag` on every interactive element and key text. Format: `area.element[.qualifier]`, lower-case, dots between levels, hyphens inside a level. Dynamic parts are appended: `library.row.<id>`, `library.tag-chip.<foldedTag>`, `git.error.<code>`. `testTagsAsResourceId = true` is set on the root so UI Automator sees them. Shared tags:

| Tag | Element |
|---|---|
| `snackbar` / `snackbar.action` | Current snackbar text / its action |
| `dialog.title` / `dialog.message` / `dialog.confirm` / `dialog.dismiss` / `dialog.neutral` | Any `AlertDialog` built from the confirmation template; the dialog root is tagged with its route, for example `dialog.delete-secure` |
| `topbar.title` / `topbar.back` / `topbar.close` | Top app bar parts |
| `menu.item.<action>` | Any `DropdownMenu` item, for example `menu.item.pin` |
| `secret.code` / `secret.copy` / `secret.copied` / `secret.done` | Secret screen template |
| `countdown.row` / `countdown.text` / `countdown.clear` | Secure-copy countdown row |
| `progress.step.<n>` | Progress step list items; state in `stateDescription` |

Screen-specific tags are listed per screen.

---

## Mobbin notice

The research documents this specification relies on were produced with Mobbin's MCP tools; their responses carried the following notice, reproduced verbatim:

---

**Your Mobbin AI usage is high this month**

Usage is unlimited during beta. If your usage stays at this level, you may need to purchase more credits once limits take effect. [View usage and plan options](https://mobbin.com/settings/billing-and-usage?utm_source=claude-code&utm_medium=ai-assistant&utm_source_platform=mcp)
