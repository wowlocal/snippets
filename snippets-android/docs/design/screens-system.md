# Screens: system integration

Covers inventory IDs PROCESS-TEXT and LINK-REVIEW, inventory §11 and §12.3, and the Android-only entry points: share-in, document open, launcher shortcuts, first run, lifecycle and the test launch mode. Components: `components.md` (C§n).

---

## 1. PROCESS-TEXT — `process-text` (Insert Snippet)

The one Android-only route into other apps. The user selects text in another app and picks `Insert Snippet` from the selection menu.

### 1.1 Platform contract

| Item | Value |
|---|---|
| Activity | Separate `ProcessTextActivity`; label `Insert Snippet`; intent filter `ACTION_PROCESS_TEXT`, `text/plain`; `excludeFromRecents`, `noHistory`, empty task affinity; translucent theme |
| Input | `EXTRA_PROCESS_TEXT` (the selection) and `EXTRA_PROCESS_TEXT_READONLY`. Only the first 100 characters of the selection are ever read; the selection is never logged, stored or put in saved state |
| Output, editable selection | `setResult(RESULT_OK, Intent().putExtra(EXTRA_PROCESS_TEXT, text))`, then finish. The calling app replaces the selection |
| Output, read-only selection | The text goes to the clipboard, `RESULT_CANCELED`, finish, and a `Toast` says so |

### 1.2 Layout

Compact and medium: a sheet-styled surface anchored to the bottom, 90 % of the window height, top corners extraLarge, scrim above (tap on the scrim = close). Expanded: a centred 560 × 640 dp dialog surface.

```
┌──────────────────────────────────────────────┐
│                    ───                       │
│ Insert Snippet                          [X]  │  titleLarge                    process-text.title / .close
│ ┌──────────────────────────────────────────┐ │
│ │ [search] Search                     [×]  │ │  process-text.search
│ └──────────────────────────────────────────┘ │
│ [info] This text can’t be replaced here. The │  note, only for a read-only selection   process-text.note
│ snippet will be copied instead.              │
│ Meeting room                          [pin]  │  SnippetRow, two lines, no trailing     process-text.row.<id>
│ \meet  https://meet.example.com/design-rev…  │  button, no swipe, no tags line
│ Atlas API token                      [lock]  │
│ \atlas-token  Secure snippet                 │
│ …                                            │
└──────────────────────────────────────────────┘
```

| Element | Spec |
|---|---|
| Search field | Placeholder `Search`. Prefilled with the selection when it is one line of at most 100 characters; otherwise empty. Takes focus on open only when prefilled text is empty (so results are visible first when a query exists) |
| Results | Blank query: every entry. Otherwise the library search (same matching, same order: pinned first, newest first). Disabled entries are included with their disabled styling (D30). Highlights as in the library |
| Rows | Name, status glyphs, keyword token, preview (secure: `Secure snippet`). No time, no tags, no trailing button, no menu |
| Empty library | `EmptyState`: `No snippets` |
| No match | `No Results` / `Try a different search.` |
| Library unreadable | `Library Recovery Required` / `Open Snippets to recover the library.` *(Android)* |
| Note (read-only selection) | `This text can’t be replaced here. The snippet will be copied instead.` *(Android)* |

### 1.3 Choosing a result

| Entry | Selection | Behaviour |
|---|---|---|
| Ordinary | editable | Resolve placeholders (`{clipboard}` is read now), return the text, finish. No toast |
| Ordinary | read-only | Resolve, copy (ordinary clip), finish, `Toast` `Copied “%s”. This text can’t be replaced here.` *(Android)* |
| Secure | editable | `BiometricPrompt` title `Insert “%s”` *(Android)*, subtitle `Replaces the selected text`. On success the decrypted, resolved text is returned directly; it never touches the clipboard. `FLAG_SECURE` is set from the moment of success |
| Secure | read-only | `BiometricPrompt` `Copy “%s”` / `Clears from the clipboard after 60 seconds`; then the secure-copy rules (`screens-secure.md` §6: sensitive clip, 60 s clear); finish; `Toast` `Copied “%s”. Clears from the clipboard in 60 seconds.` *(Android)* |
| Any, resolved text empty | — | In-sheet snackbar `“%s” has no content to copy.`; the sheet stays open |
| Secure, authentication cancelled | — | Silent; the sheet stays open |
| Secure, no screen lock | — | `dialog/screen-lock-required` |
| Secure, this device cannot open the vault | — | In-sheet snackbar `This device can’t open this secure snippet yet. Open Snippets to set it up.` *(Android)* |
| Failure | — | `dialog/error` `Couldn’t Copy Snippet` with the error sentence |

The vault session is not used here: a secure result authenticates every time. Back, `X`, the scrim and swipe-down close with `RESULT_CANCELED`.

### 1.4 Accessibility and tags

- Pane title `Insert Snippet`. Rows: label = name; state as C§1.5; click label `insert`, `copy`, `authenticate and insert` or `authenticate and copy` to match the table above.
- Tags: `process-text.screen`, `.title`, `.close`, `.search`, `.search.clear`, `.note`, `.list`, `.row.<id>`, `.empty`.

---

## 2. Share-in — `ACTION_SEND` text *(Android)*

| Item | Spec |
|---|---|
| Intent filter | On the main activity: `ACTION_SEND`, `text/plain`. Sharesheet label `Save to Snippets` |
| Input | `EXTRA_TEXT` → content; `EXTRA_SUBJECT` (when present and not blank) → name |
| Result | Any open sheet or dialog is dismissed (secret screens and working steps finish first; the share is queued behind them). A new entry is created (ordinary, enabled, no keyword, no tags), the query and filters are cleared, and `editor/{id}` opens on `Content` without focusing a field |
| Feedback | Snackbar `Snippet created from shared text.` with action `Discard` (10 s). `Discard` deletes the entry and returns to the previous screen |
| Empty or whitespace-only text | `dialog/error`: title `Nothing to Save`, message `The shared item has no text.`, `OK` |
| Text larger than 900,000 bytes (UTF-8) | `dialog/error`: title `Couldn’t Create Snippet`, message `The shared text is too large for one snippet.`, `OK` |
| Library quarantined | `dialog/error`: title `Library Recovery Required`, message `The library must be recovered before new snippets can be saved.`, `OK` |

The shared text is never logged. Nothing is created for non-text shares (the filter does not match them). Tags: `snackbar`, `snackbar.action`, editor tags.

---

## 3. Deep links — LINK-REVIEW (`dialog/link-review`)

### 3.1 Platform contract

- Intent filter on the main activity: `ACTION_VIEW`, categories `DEFAULT` and `BROWSABLE`, scheme `snippets`, hosts `share` and `new`. No `https` App Links.
- `snippets://share?data=<base64url JSON>` round-trips a whole entry (name, keyword, content, tags). `snippets://new?name=…&keyword=…&content=…&tags=a,b` is hand-writable; every field is optional but at least one of name, keyword or content must be present.
- Delivered at launch or while running, always through the review dialog. Nothing is written until the user accepts. Open sheets and dialogs are dismissed first; a secret screen or a working step finishes first.

### 3.2 Dialog

`AlertDialog` (C§16.1) with structured, scrollable content.

```
┌────────────────────────────────────────────┐
│ Import Shared Snippet?                     │  dialog.title
│                                            │
│ Name: Meeting room                         │  link.name
│ Keyword: \meet                             │  link.keyword
│ Tags: work, links                          │  link.tags
│                                            │
│ Preview:                                   │
│ ┌────────────────────────────────────────┐ │
│ │ https://meet.example.com/design-review │ │  link.preview (monoBody, surfaceContainerLow)
│ └────────────────────────────────────────┘ │
│ The imported snippet will stay disabled    │  link.note
│ until you review and enable it.            │
│                 Cancel    Import Disabled  │
└────────────────────────────────────────────┘
```

| Case | Title | Accept button |
|---|---|---|
| Creation link (`snippets://new`) | `Create Snippet From Link?` | `Create Disabled` |
| Share link, no match | `Import Shared Snippet?` | `Import Disabled` |
| Share link matching an existing entry by id, or by keyword | `Replace Existing Snippet?` | `Replace %s` (existing name; `error` colour) |

Content, in order:

| Paragraph | Text |
|---|---|
| 1 (replacement only) | `This will permanently replace “%s”. Review the incoming content before continuing.` |
| 2 | `Name: %s` · `Keyword: \%s` or `Keyword: No keyword` · `Tags: %s` (comma-separated) or `Tags: None` · blank line · `Preview:` · the trimmed content cut to 280 characters plus `…`, or `(empty content)` |
| 3 | Creation link: `The snippet will be created disabled. Review it in the editor before enabling expansion.` Share link: `The imported snippet will stay disabled until you review and enable it.` |

Dismiss button `Cancel`. Back and outside tap = `Cancel`.

### 3.3 Results

| Outcome | Behaviour |
|---|---|
| Accept | The entry is stored disabled; the library query and filters are cleared; `editor/{id}` opens |
| The library changed while the dialog was open | Refused: `dialog/error` `Couldn’t Open Link` / `Your library changed while this link was open. Review the link again before importing it.` |
| Link errors (`dialog/error`, title `Couldn’t Open Link`) | `This link is not a supported Snippets share link.` · `This share link is missing snippet data.` · `This share link is malformed or corrupted.` · `This share link was created by a newer version of Snippets.` |
| Library quarantined | `dialog/error` `Library Recovery Required` / `The library must be recovered before new snippets can be saved.` *(Android)* |

A link can never create a secure entry and never carries one (secure entries have no Share actions).

Tags: `dialog.link-review` (+ `dialog.title`, `dialog.confirm`, `dialog.dismiss`), `link.replace-warning`, `link.name`, `link.keyword`, `link.tags`, `link.preview`, `link.note`.

---

## 4. Document open — `ACTION_VIEW` *(Android)*

| Item | Spec |
|---|---|
| Intent filters | On the main activity, label `Import into Snippets`: (a) MIME `application/vnd.khm.snippets.encrypted-backup`; (b) `content` and `file` URIs whose path ends in `.snippetsbackup` (any MIME); (c) MIME `application/json` |
| Reading | Same limits and detection as Import (`screens-settings-data.md` §8): 16 MiB JSON, 32 MiB backup; identified by content. Snackbar `Reading import…` while reading |
| Encrypted backup | Continues at `backup/open-password` (the password is the review) |
| Recognised JSON | `dialog/document-open`: title `Import Snippets from This File?`; message `“%1$s” contains %2$d snippet(s). They are merged into your library by ID, then by keyword. Nothing is deleted.` (`%1$s` = display name of the document); buttons `Cancel` · `Import`. `Import` continues at Import step 5 (Raycast choice), then the result snackbar |
| Unrecognised | `dialog/error` `Couldn’t Import Snippets` / `Unsupported file format. Expected JSON exported from Snippets or Raycast.` |
| Library quarantined | The quarantine dialogs (`screens-settings-data.md` §11) |

The URI permission is used once and not persisted. Tags: `dialog.document-open` (+ shared dialog tags).

Exports and backups created by the app use the Storage Access Framework (`ACTION_CREATE_DOCUMENT`) and write straight to the chosen document; no export file is kept in app storage.

---

## 5. Launcher shortcuts *(Android)*

Static shortcuts (`res/xml/shortcuts.xml`), in this order:

| Short label | Long label | Action |
|---|---|---|
| `New Snippet` | `New Snippet` | `library` → new blank entry → `editor/{id}` with the body focused |
| `From Clipboard` | `New from Clipboard` | Same as More ▸ `New from Clipboard` (the launch is the explicit user action that permits the clipboard read) |
| `Search` | `Search Snippets` | `library?focus=search`: the search field focused with the IME shown |

Icons: `add`, `content_paste`, `search` on the adaptive shortcut background (`primaryContainer` / `onPrimaryContainer`). No dynamic or pinned shortcuts, no widget and no Quick Settings tile in v1.

---

## 6. First run and launch

| Moment | Behaviour |
|---|---|
| Splash | `DESIGN.md` §5.5. Held only until the library store reports ready |
| First run | Straight into `library` with the empty state `Your Library Is Empty` (`screens-library-editor.md` §2.4). No onboarding, no account screen, no sample content, no permission request |
| Permissions | The app requests no runtime permission at any time. (No notifications are posted; QR scanning uses the Play services scanner without a camera permission.) |
| Cold start | Always `library`; the open editor and the search are not restored after the process was killed and the task removed. Process death with the task alive restores the back stack (`DESIGN.md` §3.4) |
| Keyboard | Never shown on launch, except through the `Search` shortcut |
| One-time items | The swipe tip (after the first successful copy). Nothing else is ever shown once |

---

## 7. Lifecycle and background

| Event | Behaviour |
|---|---|
| App leaves the foreground (`ProcessLifecycleOwner` `onStop`) | 1. Flush pending writes (editor, store). 2. Lock the vault; revealed bodies leave composition; secret screens hide their content. 3. Push a waiting Git change: a WorkManager one-time request with a network constraint (expedited on API 31+, ordinary below so that no notification is needed) |
| App returns | A sync round starts when sync is on. Secure editors show the locked panel with `Locked when you left the app.` |
| Periodic | A unique periodic WorkManager job every 6 hours (network required) runs one round while sync is on |
| Secure-clip deadline while the app is in the background | The application-scoped timer fires if the process is alive; otherwise a one-shot `AlarmManager` alarm (set at copy time, `setAndAllowWhileIdle`) clears the clip |
| Device restart | Scheduled work is restored by WorkManager; a pending secure-clip clear is not needed (the clipboard does not survive a restart) |
| Notifications | None. A sync stop is visible the next time the app is opened |

---

## 8. Test launch mode, demo data, profile

| Item | Spec |
|---|---|
| UI-test reset | Debug builds only. Intent extra or instrumentation argument `ui-testing-reset=true`: storage is redirected to a fresh temporary directory, sync is disabled, Git preferences are reset and Git keys and tokens are kept in memory, loopback `http://` Git addresses are allowed, one-time tips are reset, and no real Keystore-bound vault key is touched |
| Authentication in tests | `ui-testing-auth` = `approve`, `cancel` or `fail` selects the fake `Authenticator`'s answer; each call records the prompt title and subtitle for assertions |
| Timers in tests | `ui-testing-secure-clip-seconds=<n>` shortens the 60 s secure-clip lifetime; `ui-testing-recovery-clip-seconds=<n>` shortens the 2- and 5-minute lifetimes |
| Demo seed | Debug builds: `demo-seed=standard` loads the fictional library used in the README screenshots (Meeting notes, Travel checklist, Contact details, Quick reply, Home address, Team dashboard, Meeting room, Project brief, one secure `Atlas API token`); script `snippets-android/scripts/seed-demo.sh` |
| Baseline profile | Module `:baselineprofile`; journeys: cold start to `library`; scroll the list; type a query; open and close an editor; open Settings and Sync |
| Stable selectors | `testTagsAsResourceId = true`; tags in every screen file |

---

## 9. Platform hygiene (must not regress)

| Item | Value |
|---|---|
| Backup and device transfer | `android:allowBackup="false"`; data-extraction rules exclude everything |
| Network | `usesCleartextTraffic="false"`; the debug network-security config permits loopback only |
| Launcher icon | Adaptive with a monochrome (themed) layer |
| Predictive back | `android:enableOnBackInvokedCallback="true"`; handlers only as listed in `DESIGN.md` §3.3 |
| Edge-to-edge, IME | `DESIGN.md` §11 |
| Third-party keyboards | Cannot be blocked; per-field hardening (`screens-secure.md` §11) |
| Declared permissions | `INTERNET`, `ACCESS_NETWORK_STATE`, `USE_BIOMETRIC`, `DETECT_SCREEN_RECORDING` (API 35+), plus what WorkManager merges. No camera, storage, notification, overlay or accessibility-service permission |
| Excluded by design | Custom IME, Accessibility service, overlays, background typed-text observation, Autofill service |

---

## 10. Changed strings

| Old Android / iOS string | Android string | Why |
|---|---|---|
| Old: only enabled snippets listed in Insert Snippet | All snippets listed | D30 |
| Old: `No snippets` for both empty cases | `No snippets` (empty library) / `No Results` + `Try a different search.` (no match) | Matches the library's wording |
| Old: silent copy fallback for read-only selections | Note in the sheet and a toast naming what happened | inv §12.3 gap list |
| Old: `Share snippet` chooser title | System Sharesheet default title | Platform convention |
| iOS LINK-REVIEW message as one text block | Same sentences as labelled lines with a monospaced preview block | Readability; same information |
| iOS: `Preparing…` / export toasts tied to a temporary file | Direct write to the chosen document | SAF |
| iOS `NSFaceIDUsageDescription`, camera usage description | (none needed) | `BiometricPrompt` needs no rationale string; no camera permission |
