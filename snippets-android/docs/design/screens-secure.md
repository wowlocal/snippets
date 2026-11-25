# Screens: secure snippets

Covers inventory IDs SEC-RECOVERY-KEY, SEC-RESTORE-KEY, ALERT-MAKE-ORDINARY, SET-VAULT and inventory §6. Components: `components.md` (C§n). Git's recovery code and the library-owned vault are in `screens-git.md`.

---

## 1. Terms the user meets

| Thing | Name in copy | Shown where | Clipboard lifetime |
|---|---|---|---|
| Encrypted store for secure bodies | `vault` | `settings/secure` | — |
| Offline key that restores the vault key | `recovery key` | `secure/recovery-key`, once | 5 minutes |
| Code that opens a Git library and its secure snippets | `recovery code` | `git/code-show`, once | 2 minutes |
| Snippets Cloud secrets | `account key`, `recovery kit` | Cloud screens | 2 minutes |
| A copied secure body | — | countdown row | 60 seconds |

The four secrets are never called by each other's names.

---

## 2. Authentication prompts

`androidx.biometric.BiometricPrompt`. The app never draws authentication UI of its own and never starts a prompt without an explicit user action (no prompt on launch, on opening an editor, or on returning to the app).

| Setting | Value |
|---|---|
| Allowed authenticators | API 30+: `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`. API 28–29: `BIOMETRIC_WEAK or DEVICE_CREDENTIAL` |
| Negative button | None: with device credential allowed the system supplies its own "Use PIN / pattern / password". If an implementation path must be biometric-only, the negative text is `Cancel` |
| Title | The action, verbatim from the table below |
| Subtitle | The consequence, from the table |
| Description | Not used |
| `setConfirmationRequired` | `false` for copy and reveal; `true` for everything else |

| Moment | Title | Subtitle | Kind |
|---|---|---|---|
| Copy a secure entry (library, editor, Insert Snippet with a read-only selection) | `Copy “%s”` | `Clears from the clipboard after 60 seconds` | every time |
| Insert a secure entry (Insert Snippet with an editable selection) | `Insert “%s”` *(Android)* | `Replaces the selected text` | every time |
| Reveal in the editor | `Reveal “%s”` | `Locks after 5 minutes without use, or when you leave` | opens a session |
| Make secure | `Make this snippet secure` | `The body moves into the encrypted vault` | opens a session |
| Make ordinary | `Make this secure snippet ordinary` | `The body will be stored unencrypted` | every time |
| Add recovery key | `Create and display a recovery key` | `Shown once on the next screen` | every time |
| Encrypted backup export | `Export an encrypted backup` | `Includes secure snippets` | every time |
| Encrypted backup import | `Import an encrypted backup` | `Includes secure snippets` | every time |
| Git: create a library while a vault exists | `Create the library’s recovery code` | `Includes your secure snippets` | every time |
| Git: new recovery code | `Create a new recovery code for your Git library` | `The old code stops working in Snippets` | every time |
| Git: replace keys | `Replace the keys of your Git library` | `Other devices must reconnect` | every time |
| Git: move secure snippets to a replaced library's key | `Move your secure snippets to the library’s new key` | `Nothing is deleted` | every time |
| Cloud prompts | `screens-cloud.md` §11 | | every time |

Outcomes:

| Result | Behaviour |
|---|---|
| Success | Continue the action |
| User cancelled (`ERROR_USER_CANCELED`, `ERROR_NEGATIVE_BUTTON`, `ERROR_CANCELED`, back) | Silent. The control returns to its previous state. No dialog, no snackbar, no haptic |
| Lockout, timeout, hardware unavailable | Snackbar with the system's own `errString` (not paraphrased); haptic `Reject` |
| No screen lock on the device (`KeyguardManager.isDeviceSecure == false`) | `dialog/screen-lock-required` (§10) instead of a prompt |
| Owner check failed inside a Git action | The Git problem card `vaultAuthentication` (`screens-git.md` §9) |

Tag for tests: prompts are system UI; test builds inject an `Authenticator` fake whose calls are recorded with the title and subtitle.

---

## 3. Secure entry in the editor

The editor is the same screen as for ordinary entries (`screens-library-editor.md` §6). Differences:

| Area | Secure entry |
|---|---|
| Body | The secure panel (C§8) replaces the body field |
| Name, keyword, tags, enabled, pin | Editable without unlocking |
| Name placeholder, keyword suggestions | Never derived from the body |
| `Preview Placeholders` | Absent; the resolver never receives the body |
| Top-bar copy | Icon `lock_open`, description `Authenticate and Copy`; authenticates every time, also while revealed |
| More menu | `Pin` / `Unpin`, `Delete` only |
| Search | The body is never indexed, also while revealed |
| Focus | Nothing takes focus on open; after reveal the body takes focus |

### 3.1 Reveal

1. Tap `Reveal Secure Content` (`editor.secure.reveal`).
2. No open vault session: `BiometricPrompt` (`Reveal “%s”`); the button shows `Authenticating…`. An open session reveals without a prompt.
3. Success: state `revealed`; `FLAG_SECURE` on; the body is editable; footer `Secure content is revealed and editable until you leave this screen.`
4. Cancel: back to `locked`, silent. Failure: `dialog/error` `Couldn’t Reveal Secure Content` with a sentence from §9.

### 3.2 Re-lock

The body returns to `locked` (plaintext leaves composition and is wiped from the screen's holder; pending edits are saved first) when:

| Trigger | Reason line shown in the panel |
|---|---|
| `Lock` in the panel header (`editor.secure.lock`) | none |
| Leaving the editor (back, Up, selecting another row in two-pane) | — |
| The app leaves the foreground (`onStop`) | `Locked when you left the app.` |
| 5 minutes without secure use (no keystroke in the body, no reveal) | `Locked after 5 minutes without use.` |
| 30 minutes after the session opened | `Locked after 30 minutes.` |
| `Lock Now` in Settings | none |
| Copy, Share, Duplicate, Delete, the `Secure` switch, or any dialog of the editor | none |
| Screen recording or an unprotected display is detected | state `protected` (§3.4) |

Switching between the `Content` and `Details` tabs does not lock. Returning to the app shows the locked panel; there is no prompt and no interstitial.

### 3.3 Session, as the user experiences it

- A session opens on reveal or on making an entry secure. It lasts 5 minutes without secure use and 30 minutes at most, and ends at once when the app leaves the foreground.
- While a session is open, opening another secure entry and tapping `Reveal Secure Content` needs no prompt.
- Copy, make ordinary, and every Settings and Git action prompt every time regardless of the session.
- There is no countdown and no app-bar indicator; the reason line explains a lock after the fact.

### 3.4 Capture protection

| Mechanism | Effect |
|---|---|
| `FLAG_SECURE` while the state is `revealed` or `unlocking` | The body is absent from screenshots, screen recordings, casting and the Recents preview. The system tells the user a screenshot is not allowed; the app adds no message |
| API 35+: `WindowManager.addScreenRecordingCallback` reports the window is being recorded | State `protected`: `Screen recording detected. Secure content stays hidden.` Returns to `locked` when recording ends |
| The activity's display lacks `Display.FLAG_SECURE` (external or virtual display that cannot show protected content) | State `protected`: `Protected display unavailable. Secure content stays hidden.`; footer `Secure content was hidden because protected display failed.` |
| API 35+: `contentSensitivity = Sensitive` on the body composable | Hidden during screen sharing even if the flag state lags |

### 3.5 Unavailable states (panel state `unavailable`)

| Cause | Panel text | Button |
|---|---|---|
| The device has no screen lock | `Set a screen lock to use secure snippets.` *(Android)* | `Open Settings` → `Settings.ACTION_SECURITY_SETTINGS` |
| This device has no key for the entry's vault; Git is the provider | `This device can’t open this secure snippet yet. Set up secure snippets for your Git library first.` *(Android)* | `Open Git Repository` → `settings/sync/git` |
| This device has no key for the entry's vault; other cases | `This device can’t open this secure snippet yet. Restore the vault key with your recovery key.` *(Android)* | `Open Secure Snippets` → `settings/secure` |

Secure entries written by other devices stay listed and keep syncing untouched even when this device cannot open them.

### 3.6 Accessibility

C§8: the plaintext is never in the semantics tree; the stand-in node carries the three state values. Name, keyword and tags of secure entries are fully accessible. The reason line is announced politely when it appears.

---

## 4. The `Secure` switch

The switch (`editor.secure`, or the two-pane row menu's `Make Secure` / `Make Ordinary`) snaps back to the real state at once and changes only after the move succeeds.

### 4.1 Ordinary → secure

| Step | Behaviour |
|---|---|
| 1 | Hide the IME; flush pending edits |
| 2 | No screen lock: `dialog/screen-lock-required` (§10); stop |
| 3 | Git is the provider and its library vault is not set up on this device: `dialog/error` `Couldn’t Set Up Secure Snippets` / `Secure snippets are not set up for your Git library on this device yet. Open Sync settings, then the Git repository, and choose Set Up Secure Snippets. If it isn’t offered there, finish connecting the repository first.` / buttons `OK`, `Open Git Repository`; stop |
| 4 | No vault yet (and Git is not the provider): prepare a vault and show `secure/recovery-key?mode=setup` (§5). Cancel there aborts; nothing changes |
| 5 | `BiometricPrompt` `Make this snippet secure` |
| 6 | The entry moves into the vault as one transaction; the editor rebinds; the body shows the `locked` panel. Snackbar `The body is now in the encrypted vault.` *(Android)* |
| Errors | `dialog/error` `Couldn’t Set Up Secure Snippets` (steps 3–4) or `Couldn’t Make Snippet Secure` (steps 5–6) |

### 4.2 Secure → ordinary: ALERT-MAKE-ORDINARY — `dialog/make-ordinary`

| Part | Copy |
|---|---|
| Title | `Make This Snippet Ordinary?` |
| Message | `Its content will be decrypted into the ordinary library, where it can be copied, shared, and exported.` With a plain-text Git library active, a second paragraph *(Android)*: `This is a plain-text library: the content will be readable in the repository and stay in its history.` |
| Buttons | `Cancel` · `Make Ordinary` (`error`) |

Then `BiometricPrompt` `Make this secure snippet ordinary` (one use, regardless of the session). On success the body is decrypted into the ordinary library and the editor rebinds with the ordinary body field. Snackbar `The body is now in the ordinary library.` *(Android)*. Error title `Couldn’t Make Snippet Ordinary`.

Tags: `editor.secure`, `dialog.make-ordinary` (+ shared dialog tags).

---

## 5. SEC-RECOVERY-KEY — `secure/recovery-key?mode=setup|add`

Secret screen template (C§14). `FLAG_SECURE`.

```
┌──────────────────────────────────────────────┐
│ [X]  Recovery Key                            │  X description `Cancel`
│                                              │
│ Save Your Recovery Key                       │
│ Store this somewhere safe. It is the only    │
│ way to recover secure snippets if the vault  │
│ key on this device is lost. Snippets can’t   │
│ show it again.                               │
│ ┌──────────────────────────────────────────┐ │
│ │        7K2M-9QXD-4FTR-HV3N               │ │
│ │        P8WC-6YJA-B5G                     │ │
│ └──────────────────────────────────────────┘ │
│ [ ⧉ Copy ]                                   │
│ Copied. It clears from the clipboard in      │
│ 5 minutes.                                   │
│ ┌──────────────────────────────────────────┐ │
│ │              I’ve Saved It               │ │
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

| Element | Copy and behaviour |
|---|---|
| Top bar | `Recovery Key`; `X` (`secret.close`) cancels |
| Heading | `Save Your Recovery Key` |
| Body | `Store this somewhere safe. It is the only way to recover secure snippets if the vault key on this device is lost. Snippets can’t show it again.` |
| Code | `SecretBlock` variant `code` |
| `Copy` | Sensitive clip, cleared after 5 minutes; line `Copied. It clears from the clipboard in 5 minutes.`; haptic `Confirm`. Does not continue |
| `I’ve Saved It` | Continues: `setup` → step 5 of §4.1; `add` → commits the recovery key, returns to `settings/secure`, snackbar `Recovery key added.` *(Android)* |
| Cancel (`X`, back) | Immediate, no dialog: the prepared vault (`setup`) or prepared key (`add`) is discarded; nothing changes; the snippet stays ordinary |
| Not resumed | C§14 rule 2 |
| Process death | The route is not restored. `setup`: nothing was changed. `add`: `dialog/error` `Couldn’t Add Recovery Key` / `The recovery key could not be shown, so it was not added. Try again.` *(Android)* |

`mode=add` is reached from `settings/secure` ▸ `Add Recovery Key` after `BiometricPrompt` `Create and display a recovery key`. Error title `Couldn’t Add Recovery Key`.

Tags: `secure.recovery-key` (root) + `secret.*`.

---

## 6. Secure copy

| Step | Behaviour |
|---|---|
| 1 | The user taps a secure row (phone), a row's copy button or Enter (two-pane), the editor's copy button, or picks a secure result in Insert Snippet |
| 2 | `BiometricPrompt` `Copy “%s”`, every time |
| 3 | The body is decrypted, placeholders are resolved, and the result is written as a clip with `EXTRA_IS_SENSITIVE` and the label `Snippets` (never the snippet's name). The plaintext is wiped from memory after the write |
| 4 | Row `Copied` state, countdown row (C§10) `Copied “%1$s”. Clears in %2$s`, haptic `Confirm`. Android 13+ additionally shows its own (masked) clipboard overlay |
| 5 | After 60 seconds, or on `Clear Now`: if the primary clip can be read and is not this clip, leave it; otherwise `clearPrimaryClip()`. Row text `Clipboard cleared.` for 3 s |

- The 60-second deadline is owned by an application-scoped timer plus a one-shot `AlarmManager` alarm as a backstop when the process is killed (`screens-system.md` §7).
- An empty resolved body: snackbar `“%s” has no content to copy.`; nothing is written.
- Failure: `dialog/error` `Couldn’t Copy Snippet` (§9). Cancel: silent.
- Settings states the policy once (§7, `Copying`).

---

## 7. SET-VAULT — `settings/secure`

Pane title `Secure Snippets`.

```
┌──────────────────────────────────────────────┐
│ [←]  Secure Snippets                         │
│ [lock]  Secure Snippets Status               │  settings.row.vault-status
│         Locked. Secure snippets stay         │
│         encrypted until you authenticate.    │
│ [key]   Key Storage                          │  settings.row.key-storage
│         Stored on this device, protected by  │
│         Android Keystore. …                  │
│ ──────────────────────────────────────────── │
│ Lock Now                                     │  settings.row.lock-now        (action)
│ Add Recovery Key                             │  settings.row.add-recovery-key
│   Create the offline recovery key this vault │
│   does not have yet.                         │
│ Restore with Recovery Key                    │  settings.row.restore
│ ──────────────────────────────────────────── │
│ Locking  ·  Copying  ·  Screen               │  three static facts (bodyMedium), §7.2
│ ──────────────────────────────────────────── │
│ Remove Secure Snippets from This Device      │  settings.row.remove-vault    (destructive)
│   This also removes the vault key stored on  │
│   this device.                               │
└──────────────────────────────────────────────┘
```

### 7.1 Rows

| Row | Detail (supporting text) | Shown | Action |
|---|---|---|---|
| `Secure Snippets Status` | `Not set up. Make any snippet secure to create your encrypted vault.` / `Unlocked for this session. Copying a secure snippet still asks every time.` / `Locked. Secure snippets stay encrypted until you authenticate.` / no screen lock: `A screen lock is required. Set one in system settings.` *(Android)* | always | none (status) |
| `Key Storage` | Local vault: `Stored on this device, protected by Android Keystore. It is not backed up and is removed when Snippets is uninstalled. A recovery key lets you restore it.` Git library vault: `Stored on this device, protected by Android Keystore. Other devices open this vault with your Git library’s recovery code.` Not set up: `No vault key on this device yet.` | always | none (status) |
| `Set Up Secure Snippets…` *(Android row)* | `This library has its own vault. Set it up in the Git repository screen.` | Git is the provider and its vault is not set up on this device | `settings/sync/git` |
| `Lock Now` | — | vault exists and a session is open (otherwise disabled with `Already locked.` *(Android)*) | Ends the session at once; snackbar `Secure snippets locked.` *(Android)* |
| `Add Recovery Key` | `Create the offline recovery key this vault does not have yet.` | local vault exists without a recovery key | `BiometricPrompt`, then `secure/recovery-key?mode=add` |
| `Restore with Recovery Key` | — | local vault exists | `secure/restore` (§8) |
| `Remove Secure Snippets from This Device` (destructive) | `This also removes the vault key stored on this device.` | vault exists | `dialog/remove-vault` (§8.2) |

For a vault owned by a Git library, `Add Recovery Key` and `Restore with Recovery Key` are absent; a status row *(Android)* reads `Recovery` / `This vault belongs to your Git library. Its recovery code is managed in Sync.` and opens `settings/sync/git`.

### 7.2 Static facts *(Android)*

Shown as three non-interactive `ListItem`s with headline and supporting text; values the user cannot change are prose, not disabled controls.

| Headline | Text |
|---|---|
| `Locking` | `Revealed content locks after 5 minutes without use, after 30 minutes, and when you leave the app.` |
| `Copying` | `Copying a secure snippet asks every time. The clipboard entry is marked sensitive and cleared after 60 seconds.` |
| `Screen` | `Revealed content, recovery keys and recovery codes do not appear in screenshots, screen recordings or the recent-apps preview. Revealed content is not available to accessibility services.` |

Tags: `settings.secure` (screen), rows as drawn, `settings.row.fact-locking`, `.fact-copying`, `.fact-screen`.

---

## 8. Restore and remove

### 8.1 SEC-RESTORE-KEY — `secure/restore`

Full-screen dialog. `FLAG_SECURE` while the field has input.

```
┌──────────────────────────────────────────────┐
│ [X]  Restore Vault Key                       │
│                                              │
│ Enter the recovery key created when Secure   │
│ Snippets was set up. It is checked on this   │
│ device and not sent anywhere.                │
│                                              │
│ Recovery key                                 │
│ ┌──────────────────────────────────────────┐ │
│ │ 7K2M-9QXD-4FTR-HV3N-P8WC-6Y       [paste]│ │  secure.restore.field (C§11.4 code field)
│ └──────────────────────────────────────────┘ │
│ 22 of 27 characters                          │  secure.restore.counter
│                                              │
│ ┌──────────────────────────────────────────┐ │
│ │                 Restore                  │ │  secure.restore.submit
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

| Element | Copy and behaviour |
|---|---|
| Title | `Restore Vault Key` |
| Body | `Enter the recovery key created when Secure Snippets was set up. It is checked on this device and not sent anywhere.` |
| Field | Caption `Recovery key`; placeholder `XXXX-XXXX-XXXX-…`; grouped as typed; accepts lower case, spaces and stray hyphens; `Paste` reads the clipboard on tap only |
| Counter | `%1$d of %2$d characters` until complete |
| `Restore` | Enabled when the field is not empty. Validates on tap, keeps the text on failure |
| Success | Closes; snackbar `Vault key restored.` *(Android)*; the status row updates |

Inline errors (field error text):

| Cause | Text |
|---|---|
| Check symbol fails | `That recovery key has a typo in it.` |
| Character outside the alphabet | `“%s” is not part of a recovery key.` |
| Wrong length | `A recovery key is %1$d characters. This one has %2$d.` |
| The vault has no recovery key | `This vault has no recovery key.` |
| Well-formed but does not open this vault | `That recovery key does not open this vault.` *(Android)* |

Anything else: `dialog/error` `Couldn’t Restore Vault Key` with the sentence from §9.

### 8.2 Remove — `dialog/remove-vault`

| Condition | Title | Message | Buttons |
|---|---|---|---|
| Sync on | `Remove Secure Snippets?` | `Turn off sync first.` | `Cancel` |
| Sync off | `Remove Secure Snippets?` | `This removes every secure snippet stored on this device. This action cannot be undone.` | `Cancel` · `Remove` (`error`) |

After `Remove`: snackbar `Secure snippets removed from this device.` *(Android)*. Error title `Couldn’t Remove Secure Snippets`.

---

## 9. Error sentences (D16)

The iOS vault and recovery errors are lower-case fragments. Android shows them as sentences in dialog bodies and field errors.

| iOS fragment | Android sentence |
|---|---|
| `the vault is locked` | `The vault is locked.` |
| `no vault key is available on this device` | `No vault key is available on this device.` |
| `this secure snippet contains metadata from a newer build; update Snippets before making it non-secure` | `This secure snippet contains metadata from a newer version. Update Snippets before making it ordinary.` |
| `keyword already exists` | `That keyword already exists.` |
| `your other device's secure-snippets key has not reached this one yet. Check that iCloud Keychain is on in Settings, or restore the key with your recovery key under Secure Snippets.` | `The key for your secure snippets is not on this device yet. Restore it with your recovery key under Secure Snippets, or, for a Git library, choose Set Up Secure Snippets in the Git repository screen.` |
| `secure snippets are not set up for your Git library on this device yet. …` | Same text with a capital `S` (§4.1 step 3) |
| `that recovery key has a typo in it` | `That recovery key has a typo in it.` |
| `"\(character)" is not part of a recovery key` | `“%s” is not part of a recovery key.` |
| `a recovery key is \(n) characters, got \(count)` | `A recovery key is %1$d characters. This one has %2$d.` |
| `this vault has no recovery key` | `This vault has no recovery key.` |
| `authentication was cancelled` | (never shown; D15) |
| `authentication was not approved` | `Snippets couldn’t confirm it’s you. Nothing was changed.` |
| `The snippet no longer exists.`, `The secure snippet does not contain valid text.` | unchanged |
| Any other failure | `Something went wrong. Nothing was changed. Try again.` *(Android fallback)* |

---

## 10. `dialog/screen-lock-required` *(Android)*

| Part | Copy |
|---|---|
| Title | `Set a Screen Lock First` |
| Message | `Secure snippets use this device’s screen lock: fingerprint, face, PIN, pattern or password. Set one in system settings, then try again.` |
| Buttons | `Cancel` · `Open Settings` (`Settings.ACTION_SECURITY_SETTINGS`) |

Raised by any action in §2 when the device has no screen lock. Existing secure entries stay listed; their panels show the `unavailable` state.

---

## 11. Third-party keyboards

Android cannot block third-party input methods. Mitigation is per field (C§11.2): the revealed secure body, recovery key and code fields, the account key field and password fields request no personalised learning, no suggestions and visible-password input, and are excluded from Autofill (the Git access token and backup passwords are the exceptions: they are Autofill targets). No warning is shown in the editor.

---

## 12. Changed strings

| iOS string | Android string | Why |
|---|---|---|
| Recovery key shown in an alert with `Copy & Continue`, `I’ve Saved It`, `Cancel` | Secret screen with `Copy`, `I’ve Saved It`, close `X` | D12; Copy no longer advances the flow |
| `Store this somewhere safe. It is the only way to recover secure snippets if the shared Keychain key is lost.` | `Store this somewhere safe. It is the only way to recover secure snippets if the vault key on this device is lost. Snippets can’t show it again.` | No shared Keychain on Android; states the one-time display |
| Add recovery key: `Store this somewhere safe.` with `Copy & Save` | Same screen and body as setup | One screen for both modes |
| `Unlocked for this session. Secure snippets still authenticate before reveal or insertion.` | `Unlocked for this session. Copying a secure snippet still asks every time.` | Describes the Android behaviour (reveal uses the session; there is no Secure Paste) |
| `Secure snippets stay on this device. Syncing them needs the iCloud Keychain entitlement.` / `Secure snippets can sync to your other devices through iCloud Keychain.` | The Key Storage texts in §7.1 | No iCloud Keychain |
| `The shared Keychain key remains available to your other devices.` / `This also removes the device-only vault key.` | `This also removes the vault key stored on this device.` | The key is always device-only on Android |
| `Turn off cloud sync first.` | `Turn off sync first.` | Git is not a cloud |
| SEC-RESTORE-KEY alert with a field | Full-screen dialog with grouping, paste, counter and inline errors | D14 |
| Reason strings shown by Face ID / Touch ID | `BiometricPrompt` title + subtitle (§2) | Platform |
| `Export an encrypted backup including secure snippets` / `Import secure snippets from an encrypted backup` | `Export an encrypted backup` / `Import an encrypted backup` + subtitle `Includes secure snippets` | Prompt titles truncate; the rest moves to the subtitle |
| `Couldn’t Copy Snippet` with `authentication was cancelled` | (silent) | D15 |
| `Protected secure snippet body` and its three values | unchanged | — |
| `Screen recording detected…`, `Protected display unavailable…` | unchanged; triggers differ (§3.4) | `FLAG_SECURE` prevents capture instead of reacting to it |
