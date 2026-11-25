# Open questions

Points this specification could not settle from the inventory, the research or the code. Each has a **default**: engineers implement the default and are never blocked. A different answer changes only the named section.

## Platform and engine

| # | Question | Default | Affects |
|---|---|---|---|
| 1 | **Authenticators on API 28–29.** `BIOMETRIC_STRONG or DEVICE_CREDENTIAL` is not available there. Does the vault key have to be bound to a `CryptoObject` (biometric only)? | Use `BIOMETRIC_WEAK or DEVICE_CREDENTIAL` without a `CryptoObject` on API 28–29; no negative button. If a biometric-only path is required, its negative text is `Cancel` and a `Use screen lock` path must still exist | `screens-secure.md` §2 |
| 2 | **Clearing the clipboard from the background.** Does `clearPrimaryClip()` from an alarm receiver work on every supported API level and OEM? | Clear from the application-scoped timer, with a one-shot `AlarmManager` alarm as backstop; when ownership cannot be verified, clear anyway. If a platform refuses background clears, also clear on the next return to the foreground. The UI text does not change | `components.md` §10, `screens-secure.md` §6, `screens-system.md` §7 |
| 3 | **What "Git is active" means without a second provider.** The Swift check is `provider == .git`; a standard Android build has nothing to switch to | Git is active only while it is the provider **and** `Sync This Library` is on. Turning sync off enables `Remove from This Device…`; removing sets the provider to "not set up" | `screens-git.md` §8.2, §9 (`remove_while_active`, `other_library_active`) |
| 4 | **Provider on a fresh install.** The Apple default is iCloud | No provider; the row reads `Not set up`; the switch opens setup | `screens-settings-data.md` §3 |
| 5 | **Phases of a provider switch.** Does the Kotlin switch operation report its four phases? | If not, show the single line with an indeterminate bar | `screens-settings-data.md` §5.2 |
| 6 | **SSH algorithm limits of the Kotlin client** (the brief proposes JSch without BouncyCastle: no Ed25519-only hosts) | The `ssh_incompatible` message carries no example. Once the limits are fixed, an example may be added (`…for example only Ed25519 host keys.`) | `screens-git.md` §9 |
| 7 | **Secure body keyboard type.** Does `KeyboardType.Password` with a multi-line field insert newlines on Gboard and Samsung Keyboard? | Use it; if Enter does not insert a newline on either, fall back to `KeyboardType.Text` with autocorrect off and no personalised learning | `components.md` §11.2 |
| 8 | **`SearchBar` that never expands.** Can the Material 3 1.4.0 `SearchBar` keep a focused input collapsed? | If not, build the same visuals from `Surface` + `BasicTextField` | `components.md` §4.1 |
| 9 | **List-detail with Navigation 3.** `ListDetailSceneStrategy` (adaptive-navigation3) or a `NavigableListDetailPaneScaffold` inside one entry? | Whichever is stable with Navigation 3 1.2.2; the behaviour in `DESIGN.md` §3–§4 is the contract | `DESIGN.md` §4 |
| 10 | **Search match ranges.** Does the core search return matched ranges? | If not, the UI layer computes them with the same folding | `components.md` §4.2 |
| 11 | **Screen-recording detection below API 35.** | `FLAG_SECURE` only; the `protected (recording)` state exists on API 35+ | `screens-secure.md` §3.4 |
| 12 | **Background sync interval.** | Push on leaving the foreground; one round every 6 hours; a round on every return to the foreground | `screens-system.md` §7 |

## Product

| # | Question | Default | Affects |
|---|---|---|---|
| 13 | **Diagnostics privacy notice.** Who signs off the Android field list? | The text in `screens-settings-data.md` §13 ships; whoever lands or changes a diagnostic event updates the notice in the same change, and the design lead reviews it | `screens-settings-data.md` §13 |
| 14 | **Opening JSON files from other apps.** Claiming `application/json` puts Snippets in every "Open with" list for JSON | Claim it (with the confirmation dialog). If it proves noisy, keep only the `.snippetsbackup` filter | `screens-system.md` §4 |
| 15 | **Print the Cloud recovery kit** (parity item 186, P2) | Not in v1 | `screens-cloud.md` §9 |
| 16 | **"Save as file" for recovery keys and codes** | Not offered: a file picker invites saving a key into a synced folder | `components.md` §14 |
| 17 | **QR scanning without Google Play services** | Paste and typed entry only; no bundled scanner, no camera permission | `screens-cloud.md` §7 |
| 18 | **Two panes at medium width (600–839 dp)** | Single pane | `DESIGN.md` §4 |
| 19 | **Multi-select in the library** (research recommendation) | Not in v1; long-press opens the row menu | `screens-library-editor.md` §4 |
| 20 | **Notification when sync stops** | None; the Review card shows on next open | `screens-system.md` §7 |
| 21 | **Share-in size limit** | 900,000 UTF-8 bytes (the Git record limit) | `screens-system.md` §2 |
| 22 | **https App Links for sharing** (`snippets://` is not linkified by most chat apps) | None; `Share Text` covers the common case | `screens-library-editor.md` §6.8 |
| 23 | **Draft recovery after process death** | The back stack is restored while the task is alive; autosave makes every edit durable, so there is no separate draft store | `DESIGN.md` §3.4 |
| 24 | **Tag filter row when the library has no tags** | Hidden; the editor's Tags field is where tags start | `components.md` §3.2 |
| 25 | **Harmonising extended colours under dynamic colour** | No; secure, warning, success and tag colours are fixed | `DESIGN.md` §5.2 |
| 26 | **Bundled monospace font** (about 0.3 MB) | Bundle JetBrains Mono variable; if the size budget rejects it, use `FontFamily.Monospace` with the same styles | `DESIGN.md` §6 |
| 27 | **Deploy-key title suggested to the user** | `snippets-android` (also the public key's comment) | `screens-git.md` §3 |
| 28 | **Sync opt-in copy for plain-text libraries.** The iOS dialog says "Snippets encrypts records before uploading them" for every provider | Android shows the plain-text variant in `screens-library-editor.md` §7.3 | `screens-library-editor.md` §7.3 |
| 29 | **Halt titles that say "Cloud" while Git is the provider** (`Restore Cloud Library`, `Use the Current Cloud Account?`) | Kept verbatim (shared engine vocabulary); only the reason and detail sentences have Git wording | `screens-settings-data.md` §6 |
| 30 | **Android reference check.** The research had no Android screens | Before visual QA, spot-check search bar, snackbar and context-menu behaviour against Google Keep, Bitwarden and Proton Pass on a device | whole spec |
