# Screens: Snippets Cloud (flagged builds only)

Covers inventory IDs CLOUD, CLOUD-SIGNIN, CLOUD-KEY-REVEAL, CLOUD-UNLOCK, CLOUD-PAIR-WAIT, CLOUD-SCAN, CLOUD-APPROVE, CLOUD-KIT, CLOUD-KIT-ENTRY, CLOUD-LIBRARY-CHOICE, CLOUD-DISCONNECT and inventory §9. Components: `components.md` (C§n).

Copy source (D43): the iOS strings for screens and dialogs; the old Android mapping for problem cards (§12).

---

## 1. Availability

| Build | Behaviour |
|---|---|
| Cloud flag off (default) | Nothing in this file exists in the UI: no chooser sheet, no `Snippets Cloud…` option, no settings-search entry `Cloud Account`, no route can be opened (deep navigation to `settings/sync/cloud` falls back to `settings/sync`). Strings may ship in resources but are never shown (D42) |
| Flag on, endpoint pinned | Everything below |
| Flag on, no pinned endpoint | `settings/sync/cloud` shows one problem card: title `Snippets Cloud Isn’t Configured`, message `This build has no verified cloud endpoint. A self-hosted build must pin its server address at build time.`, no actions |

All screens that show a key, a QR code or a comparison code set `FLAG_SECURE` (`DESIGN.md` §11).

---

## 2. CLOUD — `settings/sync/cloud`

Title `Snippets Cloud`. Reached from the provider chooser.

```
┌──────────────────────────────────────────────┐
│ [←]  Snippets Cloud                          │
│ Account connected. Unlock the encrypted      │  stage line (bodyLarge)              cloud.stage
│ library to continue.                         │
│ (problem card, when any)                     │  cloud.error.<code>
│ Account                                      │  section header
│   Account connected                          │  cloud.row.account
│   Account ID 4F7K…                           │
│   Selected library                           │  cloud.row.library
│   Library ID 9QXD… · Used for support        │
│ Sync                                         │
│   Active storage                             │  cloud.row.active-storage
│   Snippets Cloud                             │
│   Up to date                                 │  cloud.row.sync
│   On. Last synced at 9:04 PM.                │
│   On this device                             │  cloud.row.on-device
│   128 snippets                               │
│ Security                                     │
│   Library access                             │  cloud.row.library-access
│   Unlocked on this device                    │
│   Recovery kit                               │  cloud.row.recovery-kit
│   Verified against the current cloud …       │
│ Account Actions                              │
│   Sync now                                   │  cloud.action.<key>
│   Scan a new device invitation               │
│   …                                          │
│   Disconnect this device                     │  destructive
└──────────────────────────────────────────────┘
```

### 2.1 Stage line

One sentence at the top that says where setup stands (two visible stages: sign in, then unlock the library).

| Stage | Text |
|---|---|
| Not signed in | `Sign in to connect your encrypted library.` |
| Signed in, library setup not finished | `Account connected. Library setup is not complete yet.` |
| Signed in, library key missing | `Account connected. Unlock the encrypted library to continue.` |
| Pairing pending | `Waiting for an approved device to unlock this library.` |
| Recovery kit pending | `The recovery kit still needs to be saved and checked.` |
| First sync running | `Syncing your library…` (iOS title `Syncing Your Library…` / `Account connected. Snippets is downloading and verifying your encrypted library.` shown as headline + supporting text of the stage block) |
| Up to date | `Connected and up to date.` After the first verified sync, once: headline `Snippets Cloud Is Up to Date`, supporting `%d snippets are available on this device. The first verified sync completed successfully.` |
| Needs attention | `Setup needs attention. Your local snippets are safe.` After a failed first sync: headline `Account Connected — Sync Needs Attention`, supporting `Your local snippets are safe. Setup will remain incomplete until a sync finishes. %s` (status sentence) |

The first-sync results are inline (no alert, no celebration screen).

### 2.2 Rows

| Section | Row (headline) | Supporting text |
|---|---|---|
| `Account` | `Not connected` / `Account connected` / `Account needs review` | `Account ID %s` or `Not signed in` |
| | `Selected library` (when one is selected) | `Library ID %s · Used for support` |
| `Sync` | `Active storage` | `Snippets Cloud` / `Git` / `On device` |
| | `Snippets Cloud is not the active storage` / `Up to date` / `Syncing your library…` / `Sync needs attention` | The status sentence (`screens-settings-data.md` §4) |
| | `On this device` | `%d snippets` (plural) |
| `Security` | `Library access` | `Unlocked on this device` / `Use an approved device or recovery kit` / `Library setup needs to be completed` |
| | `Recovery kit` | `Verified against the current cloud recovery envelope` / `The previously saved recovery kit was replaced and no longer works` / `Saved verification has not yet been confirmed against the current cloud envelope` / `Not saved on this device. Sync is available; save a kit before losing access to your devices.` / `Replacement still needs to be saved and checked` |

Account ID and Library ID values can be selected by long-press (they are support identifiers, not secrets).

### 2.3 Account actions

Action `SettingsRow`s under `Account Actions`; only the ones valid for the current state are listed, in this order.

| Action | Tag key | When | Leads to |
|---|---|---|---|
| `Create account or sign in` | `sign-in` | not signed in | `cloud/sign-in` |
| `Resume library setup` | `resume-setup` | setup interrupted | resumes; may show §10.2 |
| `Retry setup verification` | `retry-verification` | setup state unverified | retries |
| `Return to device approval` | `return-to-approval` | pairing pending | `cloud/pair-wait` |
| `Save and check recovery kit` | `save-kit` | a kit is pending | `BiometricPrompt` (§11), `cloud/kit` |
| `Continue setup` | `continue-setup` | library key missing | `cloud/unlock` |
| `Save recovery kit — recommended` | `save-kit-recommended` | unlocked, no kit saved | `cloud/kit` |
| `Use Snippets Cloud for sync` | `use-cloud` | connected, not the active provider | `dialog/switch` |
| `Sync now` | `sync-now` | active | manual round |
| `Scan a new device invitation` | `scan-invitation` | unlocked | `cloud/scan?purpose=device` → `cloud/approve` |
| `Paste invitation` | `paste-invitation` | unlocked | `cloud/paste` → `cloud/approve` |
| `Replace recovery kit` | `replace-kit` | unlocked, kit saved | `BiometricPrompt`, `cloud/kit` |
| `Show account key` | `show-account-key` | signed in | `BiometricPrompt`, `cloud/account-key` (§10.3) |
| `Change account` | `change-account` | signed in | §10.4 |
| `Change library` | `change-library` | more than one library | `cloud/library-choice` |
| `Disconnect this device` (destructive) | `disconnect` | signed in | §10.6 |

Tags: `cloud.screen`, `cloud.stage`, rows as drawn, `cloud.action.<key>`.

---

## 3. CLOUD-SIGNIN — `cloud/sign-in?step=choose|key|save-key|device`

Full-screen dialog, top-bar title `Snippets Cloud`. `X` closes from `choose`; other steps have `Back`.

### 3.1 `choose`

| Element | Copy |
|---|---|
| Heading | `Snippets Cloud Account` |
| Text | `Create a new account, or sign in with the account key you saved when you created it.` |
| Buttons (stacked, full width) | `Create Account` (filled; `Creating Account…` while working) · `Sign In with Account Key` (tonal) · `Sign In with Another Device` (tonal; only when the server supports it) |

### 3.2 `key`

```
│ [←]  Snippets Cloud                          │
│ Sign In with Account Key                     │  heading
│ Enter or paste the account key you saved.    │
│ Spaces and hyphens are optional.             │
│ Account key                                  │
│ ┌──────────────────────────────────────────┐ │
│ │ ••••-••••-••••-…            [eye][paste] │ │  cloud.signin.key-field
│ └──────────────────────────────────────────┘ │
│ Try again in 12 seconds.                     │  cloud.signin.rate-limit (when limited)
│ [ Back ]                       [ Sign In ]   │  cloud.signin.back / .submit
```

| Element | Copy and behaviour |
|---|---|
| Heading | `Sign In with Account Key` |
| Text | `Enter or paste the account key you saved. Spaces and hyphens are optional.` |
| Field | Caption `Account key`; code field (C§11.4) with visibility toggle (`Show key` / `Hide key`), hidden by default |
| `Sign In` | `Signing In…` while working; disabled while rate limited |
| Rate limit | `Try again in %d seconds.` (counts down; polite announcement once) |
| `Back` | Returns to `choose` |

Inline errors under the field:

| Cause | Text |
|---|---|
| Malformed | `This isn’t a valid account key. Check it for typos.` |
| Not accepted | `That account key wasn’t accepted. Check it and try again.` |
| Rate limited | `Please wait before trying again.` |
| Unreachable | `Couldn’t reach Snippets Cloud. Check your connection and try again.` |
| Server cannot complete native sign-in | `This server could not complete native sign-in. Try again later.` |

### 3.3 `save-key` (after `Create Account`)

Secret screen template (C§14), no close button.

| Element | Copy |
|---|---|
| Heading | `Save Your Account Key` |
| Body | `This key is the only way to sign in to this account on another device. Snippets can’t recover it or send it to you. Store it in your password manager.` |
| Code | `SecretBlock` `code` |
| `Copy` | Sensitive, cleared after 2 minutes; line `Copied. The clipboard clears in 2 minutes.` |
| Primary | `I’ve Saved It` (the only way forward) |
| Back | Leave dialog (C§16.3): `Have You Saved It?` / `Snippets can’t show this account key again from here, and can’t recover it. Without it you can’t sign in on another device.` / `Go Back` · `I’ve Saved It` |

### 3.4 `device`

```
│ [←]  Snippets Cloud                          │
│ Sign In with Another Device                  │
│ On a device that already has your library,   │
│ open Snippets Cloud, choose to scan a new    │
│ device invitation, and scan this code or     │
│ paste the copied text. Continue there only   │
│ if it shows the same confirmation code.      │
│          ┌────────────────┐                  │
│          │    [ QR ]      │                  │  white card, 240 dp, both themes   cloud.signin.qr
│          └────────────────┘                  │
│ Confirmation code: 4F7K-2QXM                 │  monoCodeLarge                      cloud.signin.code
│ [timer] Waiting for approval… 09:41          │  + LinearProgressIndicator          cloud.signin.countdown
│ [ Copy Request Text ]              [ Back ]  │  cloud.signin.copy-request
```

| Element | Copy and behaviour |
|---|---|
| Heading | `Sign In with Another Device` |
| Text | `On a device that already has your library, open Snippets Cloud, choose to scan a new device invitation, and scan this code or paste the copied text. Continue there only if it shows the same confirmation code.` |
| QR | Description `Sign-in request QR code` |
| Code | `Confirmation code: %s` |
| Countdown | `Waiting for approval… %s` (MM:SS) with a draining bar |
| `Copy Request Text` | Sensitive copy, cleared after 2 minutes; announces `Request text copied.` |
| Expired | The QR is replaced by `This sign-in request expired. Start again to show a new code.` with `Start Again` *(Android)* |
| No longer valid | `This sign-in request is no longer valid. Start again to show a new code.` with `Start Again` |
| Server lacks the feature | `This server doesn’t support signing in with another device. Use your account key instead.` with `Sign In with Account Key` |

On medium and larger windows the QR and code sit to the left, the instructions to the right.

Tags: `cloud.signin` (root, `stateDescription` = step), `.create`, `.use-key`, `.use-device`, `.key-field`, `.key-visibility`, `.submit`, `.back`, `.rate-limit`, `.error`, `.qr`, `.code`, `.countdown`, `.copy-request`, `.restart`, + `secret.*` on `save-key`.

---

## 4. CLOUD-UNLOCK — `cloud/unlock`

`ModalBottomSheet`.

| Element | Copy |
|---|---|
| Title | `Unlock Your Encrypted Library` |
| Text | `Use a device that already has this library, or your offline recovery kit. Snippets Cloud cannot read or recover the library key.` |
| Options (list items) | `Use an Approved Device` (`devices`) → `cloud/pair-wait` · `Scan Recovery QR` (`qr_code_scanner`) → `cloud/scan?purpose=kit` · `Enter Recovery Code` (`key`) → `cloud/kit-entry` · `I Have Neither` (`error`) → dialog below |

`dialog/cloud-neither`: title `Old Data Cannot Be Recovered`; message `Your account can still be used, but without any approved device or the recovery kit, the old encrypted snippets are mathematically unrecoverable. Snippets Cloud has no decryption key.`; button `I Understand`.

Tags: `cloud.unlock` (root), `.approved-device`, `.scan`, `.enter-code`, `.neither`, `dialog.cloud-neither`.

---

## 5. CLOUD-PAIR-WAIT — `cloud/pair-wait`

Full-screen dialog. Title `Add This Device`; top-end `TextButton` `Cancel Pairing` (back equals it).

| Element | Copy and behaviour |
|---|---|
| Text | `On a device that already opens this library, open Snippets Cloud, choose Scan a new device invitation, and scan this QR. Confirm that both devices show the same code.` |
| QR | White card, 240 dp; description `Device invitation QR code` *(Android)* |
| Code | `Check code: %s` (`monoCodeLarge`) |
| Countdown | `Waiting for approval… %s` (MM:SS) with a draining bar |
| `Check Again` | Polls now; spinner while polling |
| Expired | QR replaced by `Invitation expired. Create a new invitation to continue.` with `Create New Invitation` |
| Poll error | Inline, `warning`: `Couldn’t check approval. Your invitation is still safe; Snippets will keep trying.` |
| Approved | Closes; the account screen shows the first-sync stage |

This device never shows a control that could approve itself. Tags: `cloud.pair` (root), `.qr`, `.code`, `.countdown`, `.check`, `.cancel`, `.expired`, `.new-invitation`, `.poll-error`.

---

## 6. CLOUD-KIT-ENTRY — `cloud/kit-entry`

Full-screen dialog. Title `Recovery Kit`.

| Element | Copy and behaviour |
|---|---|
| Text | `Paste or enter the long code from your offline recovery kit. Spaces and hyphens are handled automatically.` |
| Field | Placeholder `XXXX-XXXX-…`; accepts A–Z and 2–7, 52 characters; hidden by default; code field (C§11.4) |
| Progress (supporting text) | `Code is incomplete · %d/52 characters` / `Code is complete` |
| Buttons under the field | `Paste` · `Show Code` / `Hide Code` · `Scan Recovery QR` |
| Primary | `Restore Encrypted Library` (enabled when the code is complete) |
| Failure | Problem card `secure_setup_failed` (§12) above the primary button; the text is kept |

Tags: `cloud.kit-entry` (root), `.field`, `.progress`, `.paste`, `.visibility`, `.scan`, `.submit`.

---

## 7. CLOUD-SCAN — `cloud/scan?purpose=device|kit`

| Case | Behaviour |
|---|---|
| Google Play services code scanner available | The system scanner UI opens (no camera permission in the manifest). Its result returns to the calling flow |
| Not available, purpose `kit` | `dialog/error`: title `Camera Scanning Is Unavailable`, message `Use Enter Recovery Code instead.`, buttons `OK` · `Enter Recovery Code` |
| Not available, purpose `device` | `dialog/error`: title `Camera Scanning Is Unavailable`, message `Use Paste invitation with the request text copied on the new device.` *(Android)*, buttons `OK` · `Paste invitation` |
| Scanned content is not a Snippets request | Problem card `pairing_missing` or the fallback card (§12) on the account screen |

`cloud/paste` *(Android)*: full-screen dialog titled `Paste Invitation`; text `Paste the request text copied on the new device.`; one multi-line field (`Paste` button, no learning); primary `Continue`. Tags: `cloud.paste`, `.field`, `.submit`.

---

## 8. CLOUD-APPROVE — `cloud/approve` (on the trusted device)

`AlertDialog` (C§16.1) with the comparison code drawn as a `SecretBlock` `comparison` between title and message. `FLAG_SECURE`.

| Kind | Title | Message | Buttons | Then |
|---|---|---|---|---|
| Pairing | `Approve This Device?` | `Confirmation code: %s` then `Confirm that the same code is shown on the new device. Fingerprint, face or screen lock is required before this device releases the encrypted library key.` | `Cancel` · `Approve %s` | `BiometricPrompt` (§11) |
| Device sign-in | `Sign In a New Device?` | `Confirmation code: %s` then `Sign in a new device to this account? It will also receive this library’s key. Continue only if this code matches the code on the new device.` | `Cancel` · `Approve %s` | `BiometricPrompt` (§11) |

- Success (sign-in): snackbar `The new device is signed in.` Success (pairing): snackbar `The new device was approved.` *(Android)*
- Failure: problem card on the account screen; fallback title `Approval Failed`.
- Cancelled authentication: silent; nothing is released.

Tags: `dialog.cloud-approve` (+ `dialog.*`), `cloud.approve.code`.

---

## 9. CLOUD-KIT — `cloud/kit`

Secret screen template (C§14) with two steps. Top-start `TextButton` `Save Later` replaces the close icon.

### 9.1 Step `save`

```
│ Save Later    Save Your Recovery Kit         │
│ Keep this QR or long code offline. It is the │
│ only fallback if every approved device is    │
│ lost.                                        │
│          ┌────────────────┐                  │
│          │    [ QR ]      │                  │  cloud.kit.qr
│          └────────────────┘                  │
│ Recovery code                                │
│ ┌──────────────────────────────────────────┐ │
│ │ ABCD-EFGH-…  (52 symbols, grouped)       │ │  secret.code
│ └──────────────────────────────────────────┘ │
│ [ Copy Code ]   [ Share (May Use Cloud) ]    │  secret.copy · cloud.kit.share
│ Anyone with this kit and access to your      │  warning note (warningContainer)
│ account can unlock the library. …            │
│ ┌──────────────────────────────────────────┐ │
│ │           Verify Recovery Kit            │ │  secret.done
│ └──────────────────────────────────────────┘ │
```

| Element | Copy and behaviour |
|---|---|
| Title | `Save Your Recovery Kit` |
| Text | `Keep this QR or long code offline. It is the only fallback if every approved device is lost.` |
| Code caption | `Recovery code` |
| `Copy Code` | Sensitive, cleared after 2 minutes; line `Copied. The clipboard clears in 2 minutes.` |
| `Share (May Use Cloud)` | Sharesheet, `text/plain`: `Snippets Cloud Recovery Kit`, blank line, the code, blank line, `Keep this offline. Anyone with this kit and access to your account can unlock your library.` |
| Warning | `Anyone with this kit and access to your account can unlock the library. Keep it offline and private. The system share menu may offer mail, messages, or cloud storage; writing the code down is the safer offline option.` |
| Primary | `Verify Recovery Kit` → step `check` |
| `Save Later` | Closes; the kit stays pending (`Save and check recovery kit` remains on the account screen). Revealing a pending kit again needs `BiometricPrompt` |

### 9.2 Step `check`

| Element | Copy and behaviour |
|---|---|
| Text | `Use the copy you saved and enter its final 8 characters. This checks the copy on this device; it cannot prove where it was stored.` |
| Field | Caption `Final 8 characters` |
| Error | `Those characters do not match the recovery kit.` |
| Primary | `Complete Recovery Check` |
| Secondary | `Show Recovery Kit Again` → step `save` |

Print is not offered in v1 (D41). Tags: `cloud.kit` (root, `stateDescription` = step), `.qr`, `.share`, `.save-later`, `.check-field`, `.check-submit`, `.show-again`, + `secret.*`.

---

## 10. Account changes

### 10.1 Sign-in recovery buttons

Error dialogs and problem cards may carry one recovery button: `Continue Sign-In` → `cloud/sign-in`; `Choose Recovery Method` → `cloud/unlock`; `Create New Invitation` → `cloud/pair-wait`. Generic body: `The request could not be completed. Your local snippets are unchanged; try again.`

### 10.2 Interrupted setup

| Dialog | Title | Message | Buttons |
|---|---|---|---|
| `dialog/cloud-interrupted` | `Library Setup Was Interrupted` | `Snippets was preparing this cloud library but could not determine whether it is new or already contains encrypted data. Local snippets remain available while cloud setup is paused.` | `Not Now` · `Resume Setup` |
| `dialog/cloud-unverified` | `Cloud Setup State Could Not Be Verified` | `Snippets could not read the saved cloud setup transaction. Local snippets remain available and cloud sync is paused.` | `Not Now` · `Retry` |

### 10.3 CLOUD-KEY-REVEAL — `cloud/account-key`

After `BiometricPrompt` (§11): secret screen (C§14) with top bar `Account Key`, heading `Your Account Key`, body `This key signs in to your account on another device. Keep it in your password manager.` *(Android)*, `Copy` (line `Copied. The clipboard clears in 2 minutes.`), primary `Done`, close `X` allowed (no leave dialog: the key can be shown again).

On a device that was signed in by another device: `dialog/error` titled `Account Key`, message `This device was signed in by another device. View the account key on a device that has it.`, button `OK`.

### 10.4 Change account — `dialog/cloud-change-account`

Title `Change Snippets Cloud Account?` · message `Current library: Library ID %s` (new paragraph) `Your current cloud library and local snippets will not be deleted. After sign-in, Snippets will show the new Library ID and ask before switching.` · buttons `Cancel` · `Choose Another Account` (→ `cloud/sign-in`).

### 10.5 CLOUD-LIBRARY-CHOICE — `cloud/library-choice`

Dialog with a single-choice list.

| Variant | Title | Message |
|---|---|---|
| Switching | `Switch Snippets Library?` | `Current: Library ID %1$s` / `New: Library ID %2$s` (two lines) then `The current cloud library will not be deleted. The new library may require an approved device or recovery kit.` |
| Choosing | `Choose a Snippets Library` | `This account can open more than one encrypted library. Choose which one to use on this device.` |

Options: `Library ID %1$s · %2$s` (role: owner, writer, reader); read-only libraries are listed disabled with the supporting text `Read-only` *(Android)*. Buttons: `Cancel` · `Use This Library` *(Android)* (enabled after a selection).

### 10.6 CLOUD-DISCONNECT — `dialog/cloud-disconnect`

Title `Disconnect Snippets Cloud from This Device?` · message `This removes this device’s cloud connection and its access to open the library. Your cloud library is not deleted. You will need another approved device or the recovery kit to reconnect. You’ll need your account key to sign in again.` (new paragraph) `Recovery check: %s` (the `Recovery kit` row text) · buttons `Cancel` · `Disconnect This Device` (`error`).

### 10.7 Maintenance (from the provider chooser)

| Item | Dialog |
|---|---|
| `Reset Unreadable Cloud Sign-In` | `dialog/cloud-reset`: title `Reset Unreadable Cloud Sign-In?`; message `Snippets cannot verify the saved sign-in history or confirm that every older sign-in was disconnected. Unreadable sessions cannot be signed out remotely and may remain active until they expire. Reset removes this device’s cloud connection and its access to open the library; local snippets and the cloud library are not deleted.`; buttons `Cancel` · `Reset This Device` (`error`). Error title `Couldn’t Reset Cloud Sign-In` |
| `Retry Sign Out` | Runs at once; failure → problem card `credential_cleanup_required` |
| `Sign Out of Snippets Cloud on This Device` | §10.6 |

---

## 11. Authentication prompts (Cloud)

Rules: `screens-secure.md` §2. `setConfirmationRequired(true)` for all.

| Moment | Title | Subtitle |
|---|---|---|
| Approve pairing | `Approve a new device for your encrypted Snippets library` | `Confirmation code %s` |
| Approve device sign-in | `Sign in a new device to your Snippets Cloud account` | `Confirmation code %s` |
| Show account key | `Show your Snippets Cloud account key` | `Shown on the next screen` |
| Reveal a pending recovery kit | `Reveal your Snippets Cloud recovery kit` | `Shown on the next screen` |
| Replace the recovery kit | `Replace your Snippets Cloud recovery kit` | `The previous kit stops working` |

---

## 12. Problem cards

Persistent problem cards (C§7.4) at the top of `settings/sync/cloud`, tagged `cloud.error.<code>`. One card at a time (the most recent). `%s` = Library ID.

| Code(s) | Title | Body | Action |
|---|---|---|---|
| `cloud_feature_disabled` | `Snippets Cloud is unavailable` | `This build does not include Snippets Cloud. Your snippets remain on this device.` | — |
| `authorization_cancelled` | `Sign-in was cancelled` | `Nothing changed and your snippets are safe.` | `Sign in to Snippets Cloud` |
| `sign_in_required`, `authentication_required`, `refresh_token_missing` | `Sign-in needs to be completed again` | `Your snippets are safe. Sign in again so Snippets Cloud can keep this device connected.` | `Continue sign-in` |
| `device_sign_in_expired` | `Sign-in request expired` | `Nothing was signed in. Start again on the new device and approve it within ten minutes.` | — |
| `device_sign_in_rejected` | `Sign-in request not accepted` | `The request was already used or no longer exists. Nothing was changed. Start again on the new device.` | — |
| `device_sign_in_unavailable` | `Sign in with another device is unavailable` | `This server doesn’t offer it. Sign in with your account key instead.` | `Sign In with Account Key` |
| `device_sign_in_wrong_server` | `This request is for another server` | `The new device uses a different Snippets Cloud server. Nothing was sent.` | — |
| `device_sign_in_library_missing` | `Library unavailable` | `The approved library isn’t available to this account. Nothing was changed on this device.` | — |
| `device_sign_in_failed` | `Couldn’t start sign-in` | `Check your connection and try again, or sign in with your account key.` | — |
| `invalid_account_key` | `Account key not accepted` | `That account key wasn’t accepted. Check it and try again.` | `Sign In with Account Key` |
| `account_key_malformed` | `Check the account key` | `This isn’t a valid account key. Check it for typos.` | `Sign In with Account Key` |
| `reauthentication_required` | `Confirm this security change` | `Your snippets are safe. Sign in again to continue.` | `Re-authenticate` |
| `step_up_account_mismatch` | `Use the same cloud account` | `Sign in with the account that owns the currently connected library. The active account, library, and pending security change were not changed.` | — |
| `credential_cleanup_required`, `credential_revocation_incomplete`, `credential_revocation_failed` | `Cloud account cleanup could not be completed` | `Your local snippets are safe and remain available on this device. Cloud sync stays paused until the abandoned or superseded sign-in grant can be revoked.` | `Retry cleanup` |
| `post_authorization_incomplete` | `Library setup was interrupted` | `Your account is connected, but Snippets could not finish checking the library. Local snippets remain available and cloud sync is paused.` | `Resume setup` |
| `resume_account_mismatch` | `Use the account for this library` | `Sign in with an account that has writable access to Library ID %s. The original library setup and local snippets were not changed.` | `Sign in for this library` |
| `library_key_required` | `Unlock this library` | `The account is connected, but this device cannot decrypt the library yet. Choose an approved device, scan a QR, or enter a recovery code in Security.` | `Choose Recovery Method` |
| `pairing_expired`, `pairing_missing` | `Device invitation expired` | `Nothing changed. Create a new invitation and approve it within five minutes.` | `Create new invitation` |
| `secure_setup_failed` | `Recovery could not be verified` | `The QR or recovery code could not be verified. Your existing data is unchanged.` | `Try recovery again` |
| `space_selection_required` | `Choose a library` | `This account has access to more than one Snippets library. Select one from the secure chooser.` | `Change library` |
| `read_only_library` | `This library is read-only` | `Snippets cannot use a read-only library as active storage. Choose a library where you are an owner or writer.` | `Change library` |
| `recovery_kit_not_saved` | `Save the new recovery kit first` | `The previous kit has already been replaced. Finish saving the new kit before disconnecting this device.` | `Save and check recovery kit` |
| `recovery_kit_changed` | `Recovery kit was replaced` | `Another device replaced this library’s recovery envelope. Verify the current kit before disconnecting this device.` | — |
| `recovery_status_unconfirmed` | `Recovery kit status could not be confirmed` | `Snippets Cloud could not verify the current recovery envelope. This device was not disconnected; try again when the service is reachable.` | — |
| `server_auth_insecure` | `Secure sign-in is unavailable` | `This server does not meet Snippets Cloud’s sign-in security requirements. Your data was not sent.` | — |
| `identity_provider_unavailable`, `server_discovery_failed`, `dependency_unavailable` | `Snippets Cloud is temporarily unavailable` | `Your snippets are safe. Try sign-in again when the service is reachable.` | `Try sign-in again` |
| `scope_review_required` | `Review the connected account` | `The cloud account or library changed. Your snippets are safe; sign in again before sync resumes.` | `Review account` |
| anything else | `Snippets Cloud needs attention` | `The request could not be completed. Your local snippets are unchanged. Return to the action that failed and retry it there.` | — |

Card titles keep the old Android sentence case (they are statements, not dialog titles).

---

## 13. Changed strings

| iOS string | Android string | Why |
|---|---|---|
| `…Face ID or Touch ID is required before this device releases the encrypted library key.` | `…Fingerprint, face or screen lock is required…` | D19 |
| CLOUD-UNLOCK action sheet with `Cancel` | Bottom sheet without `Cancel` | Sheet conventions |
| `…open Snippets Cloud, choose Add device, and scan this QR.` | `…choose Scan a new device invitation, and scan this QR.` | The action is named `Scan a new device invitation`; no `Add device` action exists |
| `Camera Scanning Is Unavailable` / `Open this screen on an iPhone or iPad with an available camera.` | `Use Paste invitation with the request text copied on the new device.` | Platform; the pasted path always works |
| Scanner titles `Scan New Device`, `Scan Recovery Kit` | (system scanner UI) | The Google code scanner draws its own screen |
| `Print` and `…Print is the safer offline option.` | Removed; `…writing the code down is the safer offline option.` | D41 |
| Alerts `Syncing Your Library…`, `Snippets Cloud Is Up to Date`, `Account Connected — Sync Needs Attention` | Inline stage block on the account screen | No dialogs for routine success |
| `New Device Signed In` / `The new device is signed in.` alert | Snackbar `The new device is signed in.` | Results that need no decision are snackbars |
| Account-key sheet titled `Account Key` | Secret screen `Account Key` / `Your Account Key` with `Done` | D12 |
| Library choice as an action sheet | Single-choice dialog with `Use This Library` | Dialog conventions |
| Alert errors with `OK` | Problem cards from the old Android table | inv §12.4-11 |
| Old Android `Use this library on device only`, `Cloud & storage` screen | Not ported: storage is `settings/sync` | One Sync pane |
| Old Android `Approve with biometrics`, `Reveal with biometrics`, `Not this device` | `Approve %s`, the action rows, `Cancel` | iOS copy is canonical; modality is not named (D19) |
