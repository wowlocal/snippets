# Screens: Git sync

Covers inventory IDs GIT, GIT-MODE, GIT-PLAIN-CONFIRM, GIT-PUBLIC, GIT-VISIBILITY-UNKNOWN, GIT-FOREIGN-BRANCH, GIT-HOSTKEY-NEW / -PUBLISHED / -CHANGED, GIT-JOIN-PLAIN, GIT-REPLACEMENT, GIT-CODE-ENTRY, GIT-CODE-SHOW, GIT-NEW-CODE, GIT-REPLACE-KEYS, GIT-REMOVE and inventory §8. Components: `components.md` (C§n). The provider switch dialogs and the status sentence are in `screens-settings-data.md`.

Design (D22): one screen with two states (form, connected summary); a real progress step list; decisions as dialogs; trust, code entry and code display as full-screen dialogs; failures as persistent problem cards.

---

## 1. GIT — `settings/sync/git`

Title `Git Repository`. Reached from `settings/sync` ▸ `Sync Provider` (standard builds) or the provider chooser (Cloud builds), from Review cards (`Open Sync Settings` lands on `settings/sync`; `Reconnect…` rows live here), and from the secure panel's `Open Git Repository`.

While a step runs: the Up arrow and back are disabled, the form and rows are disabled, and the current step is announced (C§13). In two-pane Settings the list pane is also disabled.

Screen states:

| State | Content |
|---|---|
| Not connected | Intro, form (§2), SSH key section when the address is SSH (§3), `Connect`, status area (§4) |
| Connected | Summary and management rows (§8); the form is folded under `Change Address or Token…` |

The status area sits under the primary button (not connected) or under the summary (connected). It holds, top to bottom: the progress step list while working, the outcome status line, and at most one problem card.

---

## 2. Not connected: the form

```
┌──────────────────────────────────────────────┐
│ [←]  Git Repository                          │
│ Create a new private repository without a    │  git.intro (bodyMedium, onSurfaceVariant)
│ README, then paste its address.              │
│ Repository                                   │
│ ┌──────────────────────────────────────────┐ │
│ │ https://… or git@…                       │ │  git.repository
│ └──────────────────────────────────────────┘ │
│ Branch                                       │
│ ┌──────────────────────────────────────────┐ │
│ │ main                                     │ │  git.branch
│ └──────────────────────────────────────────┘ │
│ User Name                                    │  (only when needed)
│ ┌──────────────────────────────────────────┐ │
│ │ Your account name                        │ │  git.username
│ └──────────────────────────────────────────┘ │
│ Access Token                                 │
│ ┌──────────────────────────────────────────┐ │
│ │ Personal access token       [eye][paste] │ │  git.token
│ └──────────────────────────────────────────┘ │
│ Use a fine-grained token limited to this     │  git.token-help
│ repository, with Contents: Read and write.   │
│ Stored only on this device.                  │
│ Create a Token on github.com…          [↗]   │  git.token-link
│ ┌──────────────────────────────────────────┐ │
│ │                 Connect                  │ │  git.connect
│ └──────────────────────────────────────────┘ │
│ (status area)                                │  git.status, progress.step.<n>, git.error.<code>
└──────────────────────────────────────────────┘
```

| Field | Placeholder | Notes |
|---|---|---|
| `Repository` | `https://… or git@…` | URI keyboard. A missing `https://` is added when the field loses focus. Plain `http://` is refused in release builds (field error = the `invalid_url` message) |
| `Branch` | `main` | Prefilled `main` |
| `User Name` | `Your account name` | HTTPS only; hidden for `github.com` and `gitlab.com` unless one was entered before |
| `Access Token` | `Personal access token`, or `Saved. Leave empty to keep it.` when a token is stored | HTTPS only. Password field with visibility toggle (`Show token` / `Hide token` *(Android)*) and `Paste` button (reads the clipboard on tap only). Autofill target. IME `Go` connects |

- An SSH address (`git@…`, `ssh://…`, `host:path`) hides `User Name` and `Access Token` and shows the SSH key section (§3). The transport is derived from the address; there is no separate control.
- Token help under the field, by host:

| Host | Text |
|---|---|
| GitHub | `Use a fine-grained token limited to this repository, with Contents: Read and write.` |
| GitLab | `Use a project access token with read_repository and write_repository (Developer role; Maintainer for a protected branch).` |
| Other | `Use a token that can read and write this repository. On Gitea and Forgejo: write:repository.` |

- Below the help, always: `Stored only on this device.` *(Android)*
- Link row `Create a Token on %s…` (GitHub, GitLab) opens the host's token page in a Custom Tab. The form draft (address, branch, user name; never the token) survives leaving the app and process death.
- Primary button: `Connect`; `Update` when changing an existing connection; `Working…` with a spinner while busy.
- IME `Next` moves through the visible fields; on the last one `Go` connects.
- Field validation errors (`invalid_url`, `invalid_branch`, `invalid_username`, `missing_token`): §9.

---

## 3. SSH key section

Shown instead of the token fields when the address is SSH.

```
│ This Device’s SSH Key                        │  section header                     git.ssh.section
│ Add this key to the repository as a deploy   │  bodyMedium
│ key with write access, then tap Connect.     │
│ ┌──────────────────────────────────────────┐ │
│ │ ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTIt │ │  SecretBlock `publicKey` (C§9)      git.ssh.public-key
│ │ bmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBB…9f3Q=  │ │  whole key, wrapped
│ │ snippets-android                         │ │
│ └──────────────────────────────────────────┘ │
│ Suggested title: snippets-android            │  bodySmall *(Android)*
│ Copy Public Key                              │  action row                         git.ssh.copy
│ Add Deploy Key on github.com…          [↗]   │  link row (GitHub, GitLab)          git.ssh.deploy-link
│ Share Public Key…                            │  action row → Sharesheet            git.ssh.share
│ Each device has its own key. The private     │  footer, bodySmall
│ half never leaves this device.               │
```

| Element | Behaviour |
|---|---|
| Public key | One P-256 key per device in Android Keystore (StrongBox when available), created on first display, never synced. Comment `snippets-android`. Description `SSH public key, ending in %s. Use Copy Public Key to add it.` |
| Key unavailable | The block is replaced by `The device key is unavailable. Unlock the device and try again.` (`error` icon) |
| `Copy Public Key` | Ordinary copy (C§17): on API 28–32 snackbar `Public key copied.`; on 33+ the system overlay confirms |
| `Add Deploy Key on %s…` | Opens the host's deploy-key page |
| `Share Public Key…` | Sharesheet, `text/plain`, the key line |

---

## 4. Connect sequence

`Connect` validates the form, then runs the sequence. The status area shows only the steps that apply to this run:

| # | Step label (running form ends with `…`) | When |
|---|---|---|
| 1 | `Checking the repository` | always |
| 2 | `Checking that the repository is private` | plain-text creation only |
| 3 | `Creating the library` / `Connecting` | new library / existing library |
| 4 | `Opening the library` | always |

Decisions raised during the sequence (the step list stays visible behind dialogs). The trust and branch prompts retry the connection automatically, up to three attempts.

| Situation | Presentation | Title | Message | Buttons |
|---|---|---|---|---|
| First SSH contact | `git/host-key` (§5) | | | |
| Host key differs from the trusted one | `git/host-key?kind=changed` (§5) | | | |
| Branch has other files (GIT-FOREIGN-BRANCH) | dialog `dialog/git-foreign-branch` | `This Branch Has Other Files` | `This branch already has files, such as a README. Snippets can use its own branch in this repository instead.` | `Cancel` · `Use Branch “snippets”` |
| Branch is empty (GIT-MODE) | dialog `dialog/git-mode`, three stacked buttons | `Create a Snippets Library Here?` | `This branch is empty. Snippets will create an encrypted library here and show you a recovery code to save.` | `Create Library` · `Plain Text Instead…` · `Cancel` |
| Plain text chosen (GIT-PLAIN-CONFIRM) | dialog `dialog/git-plain-confirm` | `Create a Plain-Text Library?` | `Ordinary snippets become Markdown files that the host and anyone with access to the repository can read. They stay in its history even after you delete them, and you can’t change this later. Secure snippets stay encrypted.` | `Back` · `Create Plain-Text Library` |
| Plain text, repository is public (GIT-PUBLIC) | dialog `dialog/git-public` | `This Repository Is Public` | `This repository is public. Anyone on the internet could read plain-text snippets. Make it private, or create an encrypted library.` | `OK` (returns to GIT-MODE) |
| Plain text, visibility unknown (GIT-VISIBILITY-UNKNOWN) | dialog `dialog/git-visibility-unknown` | `Couldn’t Check the Repository` | `Snippets couldn’t check whether this repository is private. Create a plain-text library only if it is private: anyone who can read the repository can read your ordinary snippets.` | `Cancel` · `It’s Private` (`error`) |
| Existing plain-text library (GIT-JOIN-PLAIN) | dialog `dialog/git-join-plain` | `Join a Plain-Text Library?` | `This device’s ordinary snippets will be readable by anyone with access to the repository, and stay in its history. Secure snippets stay encrypted.` | `Cancel` · `Join` |
| Branch now holds a different library (GIT-REPLACEMENT) | dialog `dialog/git-replacement` | `Reconnect to This Repository?` | `This library’s keys were replaced on another device, or a new library was created in this repository. Reconnecting merges this device’s snippets into it. Nothing on this device is deleted.` | `Cancel` · `Reconnect and Merge` |
| Device lacks the library key (GIT-CODE-ENTRY) | `git/code-entry` (§6) | | | |
| Library created (GIT-CODE-SHOW) | `git/code-show` (§7) | | | |
| A vault with secure snippets exists when creating a library | `BiometricPrompt` `Create the library’s recovery code` | | | |

Outcome status line (`git.status`, `bodyMedium`, polite live region), shown under the step list when the sequence ends:

| Outcome | Line |
|---|---|
| Connected | `Connected.` |
| Connected, vault still needs the code | `Connected. Secure snippets still need the recovery code: tap Set Up Secure Snippets.` |
| Cancelled at a decision before anything was written | `Not connected.` |
| Cancelled at GIT-MODE or GIT-PLAIN-CONFIRM | `Nothing was created.` |
| Cancelled at code entry | `Not connected. This device needs the library’s recovery code.` |
| Failure | The failed step shows `error`; a problem card from §9 appears below |

After a successful connect, if Git is not yet the active provider, `dialog/switch` (`screens-settings-data.md` §5) opens on top of this screen. Declining leaves the library connected with the summary line `Not syncing with it yet: tap Switch and Sync.`

---

## 5. Host key trust — `git/host-key?kind=published|new|changed`

Full-screen dialog (560 dp dialog on larger windows). It cannot be dismissed by an outside tap; back and `X` equal `Cancel`.

```
┌──────────────────────────────────────────────┐
│ [X]  Trust This SSH Host?                    │
│                                              │
│ This device hasn’t connected to github.com   │  bodyLarge
│ before. Its host key matches the one GitHub  │
│ publishes:                                   │
│ ECDSA key                                    │  labelLarge *(Android)*
│ ┌──────────────────────────────────────────┐ │
│ │ SHA256:                                  │ │  SecretBlock `fingerprint` (C§9)   git.host-key.fingerprint
│ │ p2QAMXNI C1TJYWeI OttrVc98 /R1BUFWu      │ │
│ │ 3/LiyKgU fQM                             │ │
│ └──────────────────────────────────────────┘ │
│ [✓] Matches the fingerprint GitHub publishes.│  `check` in `success` *(Android)*  git.host-key.match
│                                              │
│ [ Cancel ]                       [ Trust ]   │  OutlinedButton · Button           git.host-key.cancel / .trust
└──────────────────────────────────────────────┘
```

| Kind | Title | Text before the fingerprint | Text after | Buttons |
|---|---|---|---|---|
| `published`, GIT-HOSTKEY-PUBLISHED (GitHub, GitLab, Codeberg, Bitbucket) | `Trust This SSH Host?` | `This device hasn’t connected to %1$s before. Its host key matches the one %2$s publishes:` | `Matches the fingerprint %s publishes.` *(Android)* with a `success` check | `Cancel` · `Trust` |
| `new`, GIT-HOSTKEY-NEW | `Trust This SSH Host?` | `This device hasn’t connected to %s before. Its host key fingerprint is:` | `Trust it only if it matches the fingerprint the host publishes.` | `Cancel` · `Trust` |
| `changed`, GIT-HOSTKEY-CHANGED | `SSH Host Key Changed` (top bar and heading in `error`, `warning` icon) | `%s presented a different key than the one this device trusted:` | Second block captioned `Previously trusted` *(Android)* with the stored fingerprint (first block captioned `Presented now` *(Android)*); then `This happens when a host replaces its key, but it can also mean someone is intercepting the connection. Continue only if the host announced a new key with this fingerprint.` | `Cancel` (filled `Button`) · `Trust New Key` (`TextButton`, `error`) |

- A line above the fingerprint names the key type: `%s key` (`ECDSA`, `RSA`, `ED25519`) *(Android)*.
- The fingerprint is shown whole and is selectable. A published match is a hint; the user still confirms. A changed key is never accepted silently.
- `Trust` / `Trust New Key` stores the key for the host and retries the connection. `Cancel` ends the sequence with `Not connected.` and the problem card `ssh_host_key_unknown` or `ssh_host_key_changed` (§9), whose action reopens this screen.

Tags: `git.host-key` (root; `stateDescription` = kind), `.title`, `.message`, `.key-type`, `.fingerprint`, `.previous`, `.match`, `.note`, `.cancel`, `.trust`.

---

## 6. GIT-CODE-ENTRY — `git/code-entry?purpose=connect|secure`

Full-screen dialog. `FLAG_SECURE` while the field has input.

```
┌──────────────────────────────────────────────┐
│ [X]  Enter the Recovery Code                 │
│ Enter this library’s newest recovery code.   │  bodyLarge
│ It was shown when the library was created,   │  bodyMedium *(Android)*
│ or under New Recovery Code on a connected    │
│ device.                                      │
│ Recovery code                                │
│ ┌──────────────────────────────────────────┐ │
│ │ 3HVN-T7QC-9KXA-M2PD-W6RF-8Y       [paste]│ │  git.code-entry.field (C§11.4 code field)
│ └──────────────────────────────────────────┘ │
│ 22 of 27 characters                          │  git.code-entry.counter
│ ┌──────────────────────────────────────────┐ │
│ │                 Continue                 │ │  git.code-entry.submit
│ └──────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

| Element | Copy and behaviour |
|---|---|
| Title | `Enter the Recovery Code` |
| Body | `Enter this library’s newest recovery code.` then *(Android)* `It was shown when the library was created, or under New Recovery Code on a connected device.` |
| Field | Caption `Recovery code` *(Android)*; placeholder `XXXX-XXXX-XXXX-…`; upper-cased and grouped as typed; no autocorrect; accepts lower case, spaces and stray hyphens |
| `Continue` | Enabled when the field is not empty; validates on tap; shows a spinner while the code is checked |
| Wrong or malformed code | The dialog stays with the field error (the iOS "problem line") and the text kept: `That is not a valid recovery code. Check it for typos.` / `That recovery code does not open this library.` / (purpose `secure`) `That recovery code does not open this library’s secure snippets. If the code was replaced, enter the newest one.` |
| `X`, back | Cancel: `Not connected. This device needs the library’s recovery code.` (purpose `connect`) or `Secure snippets are still locked on this device.` (purpose `secure`) |

Tags: `git.code-entry` (root), `.field`, `.counter`, `.paste`, `.submit`.

---

## 7. GIT-CODE-SHOW — `git/code-show`

Secret screen template (C§14), no close button. Shown exactly once per code: after creating a library, after `New Recovery Code…`, after `Replace Keys…`.

| Element | Copy and behaviour |
|---|---|
| Top bar | `Recovery Code` *(Android)* |
| Heading | `Save Your Recovery Code` |
| Body | `This code opens your library on a new device, secure snippets included. Snippets can’t show it again. Store it in your password manager.` then *(Android)* `If you lose it, a connected device can create a new one.` |
| Code | `SecretBlock` `code`: 27 Crockford base-32 symbols with a check symbol, grouped with hyphens, groups never broken, spelled out to TalkBack |
| `Copy` | Sensitive clip cleared after 2 minutes; line `Copied. It clears from the clipboard in 2 minutes.` (announced) |
| Warning note (only when the operation's result is uncertain) | A `warningContainer` box above the primary button with the message of `created_but_not_saved`, `creation_uncertain`, `rotated_but_not_saved` or `rotation_uncertain` (§9) |
| Primary | `Done, I’ve Saved It` closes |
| Back | Leave dialog (C§16.3): `Have You Saved It?` / `Snippets can’t show this recovery code again. Without it, a new device can’t open this library.` / `Go Back` · `Done, I’ve Saved It` |
| Not resumed | Content hidden (C§14 rule 2) |
| Cannot be shown (process death, presentation failure) | Problem card on the Git screen: title `Recovery Code Not Shown` *(Android)*, message `The recovery code could not be shown. Create a new one from this screen.`, action `New Recovery Code…` |

Tags: `git.code-show` (root) + `secret.*`, `git.code-show.warning`.

---

## 8. Connected: management

```
┌──────────────────────────────────────────────┐
│ [←]  Git Repository                          │
│ Connected Library                            │  section header
│ ┌──────────────────────────────────────────┐ │
│ │ github.com/me/library · main             │ │  titleMedium                        git.summary.title
│ │ Encrypted · HTTPS                        │ │  bodyMedium                         git.summary.mode
│ │ [warning] Access token missing. Enter it │ │  attention lines, `warning`         git.summary.attention
│ │ below and tap Update.                    │ │
│ │ On. Last synced at 9:04 PM.              │ │  status sentence                    git.summary.status
│ └──────────────────────────────────────────┘ │  Card, surfaceContainerLow, shape medium
│ Reconnect…                                   │  git.row.reconnect
│ Set Up Secure Snippets…                      │  git.row.secure-setup
│ Sync Now                                     │  git.row.sync
│ New Recovery Code…                           │  git.row.new-code
│   For a lost code.                           │
│ Replace Keys…                                │  git.row.replace-keys
│   For a leaked code or a lost device.        │
│ Change Address or Token…                     │  git.row.change
│ Remove from This Device…                     │  git.row.remove (destructive)
│ (status area)                                │
└──────────────────────────────────────────────┘
```

### 8.1 Summary

| Line | Content |
|---|---|
| Title | `%1$s · %2$s` (host/path, branch) |
| Mode and transport | `Encrypted · HTTPS` / `Encrypted · SSH` / `Plain text · HTTPS` / `Plain text · SSH` |
| Attention lines (zero or more, each with a `warning` icon) | `This device can’t open the library. Tap Reconnect and enter the recovery code.` · `Access token missing. Enter it below and tap Update.` · `Secure snippets: not set up on this device.` · `Secure snippets: locked. This device needs the recovery code.` |
| Last line | The status sentence, or `Not syncing with it yet: tap Switch and Sync.` when Git is not the active provider |

### 8.2 Rows (each shown only when relevant)

| Row | Detail | Shown | Behaviour |
|---|---|---|---|
| `Reconnect…` | — | Sync stopped on something reconnecting fixes: no key for the saved scope, or `git_library_replaced`, `git_repository_not_initialized`, `git_library_mode_changed`, `git_key_required` | Runs the connect sequence (§4) with the saved address; may raise GIT-REPLACEMENT, GIT-JOIN-PLAIN, code entry |
| `Set Up Secure Snippets…` | — | Secure snippets need setup or the code | Steps `Checking the library`, `Opening secure snippets`; may open `git/code-entry?purpose=secure`; ends with `Secure snippets are ready on this device.` or `Secure snippets are still locked on this device.` |
| `Sync Now` | — | Git is the active provider | Manual round; row spinner |
| `Switch and Sync` | — | Git is connected but not active | `dialog/switch` |
| `New Recovery Code…` | `For a lost code.` | connected | §8.3 |
| `Replace Keys…` | `For a leaked code or a lost device.` | Git is the active provider | §8.4 |
| `Change Address…` (SSH) / `Change Address or Token…` (HTTPS) / `Hide Connection Details` | — | connected | Unfolds the form (§2, §3) under the header `Change Connection` with the button `Update`; an empty token keeps the saved one |
| `Remove from This Device…` (destructive) | While Git is the active provider the row is disabled with `Turn off sync first.` (Cloud builds: `Switch sync away from Git first.`) | connected | §8.5 |

### 8.3 GIT-NEW-CODE — `dialog/git-new-code`

| Part | Copy |
|---|---|
| Title | `Create a New Recovery Code?` |
| Message | Git active: `The old code stops working in Snippets. If it may have leaked, use Replace Keys instead.` Git not active: `The old code stops working in Snippets. If it may have leaked, switch sync to this library and use Replace Keys instead.` |
| Buttons | `Cancel` · `Create Code` |

Then `BiometricPrompt` (`Create a new recovery code for your Git library`; cancel is silent), step `Creating a new recovery code`, then `git/code-show`. Failure: problem card (§9); operation fallback title `Couldn’t Create a Recovery Code`.

### 8.4 GIT-REPLACE-KEYS — `dialog/git-replace-keys`

| Part | Copy |
|---|---|
| Title | `Replace This Library’s Keys?` |
| Message | `Your other devices stop syncing until you reconnect each one with the new recovery code. Sync them first if you can.` (new paragraph) `The old code still opens earlier versions in the repository’s history. If it may have leaked, also change the passwords you keep in secure snippets.` |
| Buttons | `Cancel` · `Replace Keys` (`error`) |

Then `BiometricPrompt` (`Replace the keys of your Git library`), step `Replacing the library’s keys`, `git/code-show`, and the status line `Keys replaced. Reconnect your other devices with the new recovery code.` Fallback title `Couldn’t Replace the Keys`.

### 8.5 GIT-REMOVE — `dialog/git-remove`

| Part | Copy |
|---|---|
| Title | `Remove the Repository from This Device?` |
| Message | `Nothing in the repository is deleted. You can reconnect later without the recovery code.` |
| Buttons | `Cancel` · `Remove` (`error`) |

After: the screen returns to the form with the status line `Removed from this device.` Fallback title `Couldn’t Remove the Repository`.

---

## 9. Setup failures

Every `GitSyncSetup.Failure` case. Field errors appear on the field (C§11.3). Everything else is a problem card (C§7.4) in the status area, tagged `git.error.<code>`, severity `error` unless marked `warning`. Titles are *(Android)*; messages are the iOS messages with the device noun adapted. When a failure has no card title here, the card uses the operation's fallback title: `Couldn’t Connect the Repository`, `Couldn’t Create a Recovery Code`, `Couldn’t Replace the Keys`, `Couldn’t Remove the Repository`.

| Code | Presentation / title | Message | Actions |
|---|---|---|---|
| `invalid_url` | Field error on `Repository` | `Enter the repository’s address, for example https://github.com/you/snippets-library or git@github.com:you/snippets-library.git.` | — |
| `invalid_branch` | Field error on `Branch` | `Enter a valid branch name, such as main.` | — |
| `invalid_username` | Field error on `User Name` (the field is shown) | `Enter your account name on this Git host as the user name.` | — |
| `missing_token` | Field error on `Access Token` | `Enter an access token with read and write access to the repository’s contents.` | — |
| `authentication` | `Access Token Refused`; also marks the token field | `The Git host didn’t accept the access token. It may have expired, or it can’t write to this repository. Enter a new token.` | `Enter a New Token` (focuses the field) · `Create a Token on %s…` |
| `repository_not_found` | `Repository Not Found` | `Repository not found. Check the address, and that the token or SSH key can see this private repository.` | `Edit Address` |
| `unsupported_server` | `Not a Usable Git Repository` | `This address isn’t a git repository Snippets can use. Check that you copied the clone address.` | `Edit Address` |
| `unreachable` | `Couldn’t Reach the Git Host` (`warning`) | `Couldn’t reach the Git host. Check the address and your connection, then try again.` | `Try Again` |
| `rate_limited` | `The Git Host Is Limiting Requests` (`warning`) | `The Git host is limiting requests. Try again shortly.` | `Try Again` |
| `push_rejected` | `The Git Host Refused the Change` | `The Git host refused the change. Check that the branch is not protected and that the token or SSH key can write to it.` | `Try Again` |
| `refused` | `The Git Host Refused the Request` | `The Git host refused the request.` | `Try Again` |
| `push_too_large` | `Upload Too Large` | `The Git host refused the upload as too large. If a proxy sits in front of it, raise its request size limit (for example nginx client_max_body_size).` | `Try Again` |
| `foreign_branch` | Decision dialog GIT-FOREIGN-BRANCH (§4) | `This branch already has files, such as a README. Snippets can use its own branch in this repository instead.` | dialog buttons |
| `public_repository` | Decision dialog GIT-PUBLIC (§4) | `This repository is public. Anyone on the internet could read plain-text snippets. Make it private, or create an encrypted library.` | dialog button |
| `visibility_unknown` | Decision dialog GIT-VISIBILITY-UNKNOWN (§4) | `Snippets couldn’t check whether this repository is private. Create a plain-text library only if it is private: anyone who can read the repository can read your ordinary snippets.` | dialog buttons |
| `not_a_library` | `No Snippets Library Here` | `This branch does not hold a Snippets library.` | `Edit Address` |
| `library_exists` | `A Library Was Just Created Here` (`warning`) | `Another device created a Snippets library in this repository a moment ago. Connect to it instead.` | `Connect` |
| `library_changed` | `The Repository Changed` (`warning`) | `The repository changed while connecting. Check it again.` | `Check Again` |
| `recovery_code_required` | `Recovery Code Needed` (`warning`) | `Enter this library’s recovery code. It was shown when the library was created.` | `Enter Recovery Code` → §6 |
| `invalid_recovery_code` | Field error in `git/code-entry` | `That is not a valid recovery code. Check it for typos.` | — |
| `incorrect_recovery_code` | Field error in `git/code-entry` | `That recovery code does not open this library.` | — |
| `recovery_unavailable` | `This Library Has No Recovery Code` | `This library has no recovery code. Connect from a device that already has its key.` | — |
| `key_unavailable` | `Library Key Missing` | `This device does not have the library’s key.` | `Reconnect…` |
| `not_configured` | `No Repository Connected` | `No Git repository is connected on this device.` | — |
| `created_but_not_saved` | `Library Created, Connection Not Saved`; also the warning note on `git/code-show` | `The library was created, but this device could not save the connection. Keep the recovery code, then tap Connect again.` | `Connect` |
| `creation_uncertain` | `Couldn’t Confirm the Library Was Created`; also the warning note on `git/code-show` | `Snippets couldn’t confirm whether the library was created. Keep the recovery code: if the library exists, it opens it. Then tap Connect again.` | `Connect` |
| `other_library_active` | `Git Is Syncing with Another Library` | Standard builds: `Git is syncing with %s. To use a different repository or library, turn off sync first, then connect it here.` Cloud builds: `Git is syncing with %s. To use a different repository or library, switch sync to Snippets Cloud first, then connect it here.` | `Open Sync Settings` |
| `busy` | `Sync Is Busy` (`warning`) | `Sync is busy with another account change. Try again in a moment.` | `Try Again` |
| `switch_in_progress` | `A Switch Has Not Finished` (`warning`) | `A switch to or from Git has not finished yet. Use Sync Now until it completes, then change the repository.` | `Sync Now` |
| `save_failed` | `Couldn’t Save the Repository Settings` | `This device could not save the repository settings. Try again.` | `Try Again` |
| `remove_while_active` | `Git Is in Use` | Standard builds: `Git is in use. Turn off sync before removing the repository.` Cloud builds: `Git is in use. Switch sync to another provider before removing the repository.` | `Open Sync Settings` |
| `ssh_host_key_unknown` | `SSH Host Not Trusted Yet` (`warning`), shown only after the trust screen was cancelled | `This device hasn’t connected to %s before. Confirm its host key fingerprint to continue.` | `Review Host Key` → §5 |
| `ssh_host_key_changed` | `SSH Host Key Changed`, shown only after the trust screen was cancelled | `The SSH host key for %s is different from the one this device trusted. This can mean the host changed its key, or that someone is intercepting the connection.` | `Review Host Key` → §5 |
| `ssh_permission_denied` | `SSH Key Not Accepted` | `%s didn’t accept this device’s SSH key, or the key can’t write to this repository. Add the key shown above to the repository with write access, or to your account.` | `Copy Public Key` · `Add Deploy Key on %s…` |
| `ssh_incompatible` | `SSH Settings Not Supported` | `%s offers SSH settings this device can’t use. Use the repository’s https:// address instead.` | `Edit Address` |
| `ssh_no_git` | `SSH Login Without Git` | `%s accepted the SSH login but doesn’t run git for it. Check the address, or use the repository’s https:// address.` | `Edit Address` |
| `ssh_unavailable` | `SSH Isn’t Available` | `SSH isn’t available in this version of Snippets. Use the repository’s https:// address.` | `Edit Address` |
| `different_vault` | `Secure Snippets Use a Different Key` | With secure snippets: `This device has %d secure snippet(s) protected by a different key than this library’s. Turn it/them into ordinary snippets or delete it/them, choose Remove Secure Snippets from This Device in Settings, then connect again.` (plural forms `it` / `them`). With none: `This device has synced secure snippets under a different key than this library’s. To use the library’s, choose Remove Secure Snippets from This Device in Settings, then connect again.` | `Open Secure Snippets` |
| `vault_key_unavailable` | `Secure Snippets Aren’t Open on This Device` | `This device can’t open its secure snippets yet, so a code made here wouldn’t open them either. Use Set Up Secure Snippets first, or do this on a device that can open them.` | `Set Up Secure Snippets…` |
| `vault_authentication` | `Couldn’t Confirm It’s You` (`warning`) | `Snippets couldn’t confirm it’s you, so your secure snippets were left as they are. Nothing was changed.` | `Try Again` |
| `vault_unavailable` | `Secure-Snippet Key File Unreadable` | `This library’s secure-snippet key file can’t be read. Update Snippets on this device, or create a new recovery code on a device that can open the secure snippets.` | — |
| `local_vault_unreadable` | `Secure Snippets Can’t Be Read` | `Secure snippets on this device can’t be read, so nothing was changed. Check Secure Snippets in Settings.` | `Open Secure Snippets` |
| `incorrect_vault_recovery_code` | Field error in `git/code-entry?purpose=secure` | `That recovery code does not open this library’s secure snippets. If the code was replaced, enter the newest one.` | — |
| `vault_held_elsewhere` | `Another Device Holds the Key` | `Another device holds the key to this library’s secure snippets. Update Snippets on that device, create a new recovery code there, then enter that code here.` | — |
| `sync_before_secure_setup` | `Sync with This Library First` (`warning`) | `Switch sync to this Git library and let it finish syncing, then set up secure snippets.` | `Switch and Sync` |
| `sync_before_rotation` | `Sync Before Replacing Keys` (`warning`) | `Keys can be replaced only while Git sync is on and up to date. Use Sync Now, fix anything it reports, then try again.` | `Sync Now` |
| `pending_secure_conflicts` | `A Secure Snippet Has an Unresolved Conflict` (`warning`) | `A secure snippet on this device still has an unresolved sync conflict, so its key can’t be replaced yet. Unlock your secure snippets and use Sync Now, then try again. If sync can’t run, choose Remove Secure Snippets from This Device in Settings, then connect again.` | `Sync Now` |
| `rotated_but_not_saved` | `Keys Replaced, This Device Not Updated`; also the warning note on `git/code-show` | `The repository now uses the new keys, but this device could not finish switching to them. Keep the new recovery code, then tap Reconnect.` | `Reconnect…` |
| `rotation_uncertain` | `Couldn’t Confirm the Keys Were Replaced`; also the warning note on `git/code-show` | `Snippets couldn’t confirm whether the keys were replaced. Keep the new recovery code: if the library asks for one, this is it. Use Sync Now; if it asks you to reconnect, tap Reconnect.` | `Sync Now` |
| (fallback) | Operation fallback title | `Something went wrong. Try again.` | `Try Again` |

A cancelled authentication inside any of these operations is silent (no card).

---

## 10. Runtime failure codes

What the sync engine reports while Git is the active provider. The **detail** is the fragment the status sentence embeds (`Git needs attention: <detail>.` or `Sync needs attention: <detail>.`); it is also the message of the problem card on the Git screen, written as a sentence. The **title** *(Android)* is the problem card's title on the Git screen. The library shows the Review card `Sync Needs Attention` with the status sentence and the action `Open Sync Settings` for all of them.

| Code | Class | Title | Detail | Action on the Git screen |
|---|---|---|---|---|
| `git_http_401`, `git_http_403` | authentication | `Access Token Refused` | `The Git host didn’t accept the access token. It may have expired; enter a new one in Sync settings` | `Change Address or Token…` |
| `git_credential_required` | authentication | `Access Token Missing` | `The Git access token is missing on this device. Enter it in Sync settings` | `Change Address or Token…` |
| `git_ssh_host_key_unknown` | authentication | `SSH Host Not Trusted` | `The Git host’s SSH key isn’t trusted on this device. Reconnect in Sync settings` | `Reconnect…` |
| `git_ssh_host_key_changed` | authentication | `SSH Host Key Changed` | `The Git host’s SSH key changed. Check it before reconnecting in Sync settings` | `Reconnect…` |
| `git_ssh_permission_denied` | authentication | `SSH Key Not Accepted` | `The Git host didn’t accept this device’s SSH key, or the key can’t write` | `Change Address…` (shows the key) |
| `git_repository_not_found` | authentication | `Repository Not Found` | `The Git repository was not found, or the token or SSH key can’t see it` | `Change Address or Token…` |
| `git_key_required` | attention | `Recovery Code Needed` | `Enter the Git library’s recovery code in Sync settings` | `Reconnect…` |
| `git_configuration_required` | attention | `No Repository Connected` | Cloud builds: `Connect the Git repository in Sync settings, or choose another provider`. Standard builds: `Connect the Git repository in Sync settings, or turn off sync` | (form) |
| `git_library_replaced` | attention | `The Library Was Replaced` | `This library’s keys were replaced on another device, or the repository holds a different library. Reconnect it in Sync settings with the newest recovery code` | `Reconnect…` |
| `git_repository_not_initialized` | attention | `The Branch Has No Library` | `The Git branch no longer holds a Snippets library. Reconnect it in Sync settings` | `Reconnect…` |
| `git_branch_not_snippets_library` | attention | `Not a Snippets Library` | `The Git branch contains files that are not a Snippets library` | `Change Address or Token…` |
| `git_sync_schema_unsupported` | attention | `Update Snippets to Sync` | `A newer Snippets version wrote this Git library; update Snippets` | none |
| `git_push_rejected` | attention | `The Git Host Refused the Update` | `The Git host refused the update. Check that the branch is not protected and that the token or SSH key can write to it` | `Sync Now` |
| `git_response_too_large` | attention | `Repository Too Large` | `The Git repository is larger than Snippets accepts` | none |
| `git_library_mode_changed` | attention | `The Library’s Storage Mode Changed` | `The Git library’s storage mode changed in the repository. Reconnect in Sync settings to review it` | `Reconnect…` |
| `git_push_too_large` | attention | `Upload Too Large` | `The Git host refused an upload as too large. Raise its request size limit` | `Sync Now` |
| `git_unsupported_ssh_algorithms`, `git_unsupported_ssh_handshake` | attention | `SSH Settings Not Supported` | `The Git host’s SSH server offers no settings this device supports. Use its HTTPS address` | `Change Address…` |
| `git_unsupported_ssh_no_git`, `git_unsupported_ssh_exec` | attention | `SSH Login Without Git` | `The Git host accepted the SSH login but runs no git for it` | `Change Address…` |
| `git_unsupported_ssh_unavailable`, `git_unsupported_ssh` | attention | `SSH Isn’t Available` | `SSH isn’t available here. Use the repository’s HTTPS address in Sync settings` | `Change Address…` |
| `git_unsupported_not_smart_http`, `git_unsupported_object_format`, `git_unsupported_report_status`, `git_unsupported_delete_refs`, any other `git_unsupported_*` | attention | `Not a Usable Git Repository` | `This address isn’t a git repository Snippets can use` | `Change Address or Token…` |
| `record_too_large` | attention | `One Snippet Is Too Large` | `One snippet is larger than 900,000 bytes, the limit for one record` *(Android wording for Git)* | none |
| `git_invalid_path`, `git_record_malformed`, `invalid_batch_size`, anything else | attention | `Sync Couldn’t Apply a Change` | `The repository rejected a change` *(Android wording for Git)* | `Sync Now` |
| `dataset_reset`, `git_record_removed` | halt `remote_data_reset` | Review (`screens-settings-data.md` §6) | | `Restore Cloud Library` via Review |
| `git_network*`, `git_http_5xx`, `git_protocol_*`, `git_pack_invalid`, `git_snapshot_incomplete`, `git_format_*`, `git_ssh_connection`, `git_ssh_timeout`, `git_ssh_failed`, `git_ssh_remote_failed`, `git_ssh_remote_temporary`, `git_ssh_channel`, `git_ssh_device_key_unavailable`, `git_ref_moved`, `git_local_storage`, `git_transport_shut_down` | unreachable (retried with backoff) | no card | Status sentence `Cannot reach Git. Trying again at %s.`; library row `Git unavailable` | `Sync Now` |

Secure-conflict wait: the "Waiting" sentences in `screens-settings-data.md` §4, shown as the Review card `Sync Is Waiting` in the library and as the summary's last line here.

---

## 11. Runtime behaviour the user notices

- Automatic Git rounds are paced: 30 s after the last local change, at most 120 s after the first; a poll every 60 s while the app is in the foreground; a waiting change is pushed when the app goes to the background (`screens-system.md` §7). `Sync Now`, setup, recovery and provider switches are immediate and never paced.
- While a change waits, the library row keeps its last text (`Synced at …`); nothing announces "waiting".
- One record is limited to 900,000 bytes.
- Each device pins the library mode (encrypted or plain text) the user agreed to; a manifest naming another mode stops sync with `git_library_mode_changed` and is never followed silently.
- Commits carry fixed authorship and a record count only; no device name appears anywhere in this UI or in the repository.

---

## 12. Accessibility and test tags

- The step list and the outcome line are polite live regions; problem cards are assertive when they appear.
- Fingerprints and codes are spelled character by character (C§9).
- While working, disabled controls keep their labels; the Up arrow's state description is `Unavailable while working` *(Android)*.
- Dialog buttons follow C§16; destructive confirms are announced with their full label.

Tags: `git.screen`, `git.intro`, `git.repository`, `git.branch`, `git.username`, `git.token`, `git.token.visibility`, `git.token.paste`, `git.token-help`, `git.token-link`, `git.connect`, `git.status`, `progress.step.<n>`, `git.error.<code>` (+ C§7.4 parts), `git.ssh.section`, `git.ssh.public-key`, `git.ssh.copy`, `git.ssh.deploy-link`, `git.ssh.share`, `git.ssh.unavailable`, `git.summary` (+ `.title`, `.mode`, `.attention`, `.status`), `git.row.reconnect`, `git.row.secure-setup`, `git.row.sync`, `git.row.switch`, `git.row.new-code`, `git.row.replace-keys`, `git.row.change`, `git.row.remove`, `git.change.header`, dialogs `dialog.git-foreign-branch`, `dialog.git-mode`, `dialog.git-plain-confirm`, `dialog.git-public`, `dialog.git-visibility-unknown`, `dialog.git-join-plain`, `dialog.git-replacement`, `dialog.git-new-code`, `dialog.git-replace-keys`, `dialog.git-remove`, and the roots in §5–§7.

---

## 13. Changed strings

| iOS string | Android string | Why |
|---|---|---|
| `This iPhone’s SSH Key` | `This Device’s SSH Key` | D19 |
| `Each device has its own key. The private half never leaves this iPhone.` | `…never leaves this device.` | D19 |
| Public key on one middle-truncated line | Whole key, wrapped | Truncated keys cannot be compared (RSS §2.2) |
| `Public key copied.` status line | Snackbar on API 28–32 only | Ordinary-copy rule (D7) |
| Host-key and code-entry alerts | Full-screen dialogs | D14, D22 |
| GIT-HOSTKEY-CHANGED shows the new fingerprint only | Shows `Presented now` and `Previously trusted` | The user needs both to compare |
| `Join a Plain-Text Library?` / `This iPhone’s ordinary snippets…` | `This device’s ordinary snippets…` | D19 |
| `Reconnecting merges this iPhone’s snippets into it. Nothing on this iPhone is deleted.` | `…this device’s snippets… Nothing on this device is deleted.` | D19 |
| `…Snippets can’t show it again. Store it in your password manager. Your other Apple devices with iCloud Keychain connect without it.` | The last sentence is omitted; `If you lose it, a connected device can create a new one.` is added | No iCloud Keychain; states the remedy |
| `This iPhone can’t open the library. tap Reconnect and enter the recovery code.` | `This device can’t open the library. Tap Reconnect and enter the recovery code.` | D19; capital after the full stop |
| `Secure snippets: not set up on this iPhone.` / `…locked. This iPhone needs the recovery code.` / `Secure snippets are ready on this iPhone.` / `…still locked on this iPhone.` | `…on this device.` / `This device needs…` | D19 |
| `Remove from This iPhone…` / `Remove the Repository from This iPhone?` / `Removed from this iPhone.` | `Remove from This Device…` / `Remove the Repository from This Device?` / `Removed from this device.` | D19 |
| `Switch sync away from Git first.` | Standard builds: `Turn off sync first.` | No other provider exists without the Cloud flag |
| `…switch sync to iCloud first, then connect it here.` | `…turn off sync first…` / `…switch sync to Snippets Cloud first…` | No iCloud |
| `Git is in use. Switch sync to another provider before removing the repository.` | Standard builds: `Git is in use. Turn off sync before removing the repository.` | Same |
| `…Add the key shown below…` | `…Add the key shown above…` | The key section is above the status area |
| `…SSH settings this device can’t use, for example only RSA host keys. …` | `…SSH settings this device can’t use. …` | The Android client's limits differ from iOS; the example would be wrong |
| Alert titles `Couldn’t Connect the Repository`, `Couldn’t Create a Recovery Code`, `Couldn’t Replace the Keys`, `Couldn’t Remove the Repository` | Problem-card titles per failure; these remain as fallback titles | Typed error cards (D22) |
| `One snippet is too large for the cloud service`, `The cloud service rejected a change` (Git active) | `One snippet is larger than 900,000 bytes, the limit for one record`, `The repository rejected a change` | Git is not a cloud service |
| `…or choose another provider` | Standard builds: `…or turn off sync` | One provider |
