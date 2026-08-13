# Native Android application plan

## Product scope

The Android deliverable is a native Android application, not only a shared library and
not an embedded web view. It provides:

- an offline-first snippet library and editor;
- phone and large-screen/tablet layouts;
- local search, tags, pinning, import/export, placeholders, and conflict presentation;
- secure snippets with Android user authentication;
- Local Only, Snippets Cloud, and Custom Server providers;
- reviewed device pairing and encrypted recovery;
- explicit cross-app use through copy/share and Android `ACTION_PROCESS_TEXT` where the
  target supports replacing selected text;
- background, foreground, manual, and push-hinted HTTP sync.

iCloud is intentionally absent from the Android provider picker. Onboarding explains
that an iCloud user first switches the fully compatible library to an HTTP provider from
Snippets on a Mac, iPhone, or iPad; it does not ask for an Apple ID or imply that iCloud
was removed from those apps.

## Layer ownership

| Layer | Language | Owns |
| --- | --- | --- |
| UI | Kotlin + Jetpack Compose | Screens, adaptive layout, navigation, accessibility semantics, state rendering |
| Android platform | Kotlin | Activity lifecycle, `ACTION_PROCESS_TEXT`, clipboard/share sheet, WorkManager, FCM, notifications, document picker, Credential Manager/browser auth, Keystore, BiometricPrompt, OkHttp |
| Bridge | Generated Java/JNI + small Kotlin wrapper | Versioned commands/results, cancellation, lifecycle barrier, conversion to Kotlin flows |
| Product core | Swift | Model, validation, local files, mutation ordering, search, placeholders, crypto, vault projection, journal, merge, deletion guard, HTTP transport mapping, sync engine |
| Service | Swift/PostgreSQL | Authentication enforcement, opaque record CAS/change feed, encrypted key envelopes, quota/push hints |

Kotlin never writes `snippets.json`, `vault.json`, sync base, or journal. Swift never
constructs Android UI, starts a Worker, owns a `Context`, retains an Activity, stores an
OAuth refresh token, or calls Android authentication APIs without the injected adapter.

## Proposed Gradle modules

```text
snippets-android/
  app/                 Compose application, navigation and dependency wiring
  core-bridge/         AAR dependency and typed Kotlin facade/Flow adapter
  platform-security/   Keystore, BiometricPrompt and credential storage
  platform-sync/       OkHttp executor, auth interceptor, WorkManager and FCM
  platform-actions/    PROCESS_TEXT, explicit clipboard/share and deep-link actions
  benchmark/           startup, search, bridge and sync macrobenchmarks
```

Debug uses `com.khm.snippets.debug`; Release uses `com.khm.snippets`. A debug build uses
its own app data, OAuth redirect URI, FCM registration, and server client ID. Release and
Debug may have the same display name only if internal testing makes the active build
visually unmistakable.

The initial compatibility floor is Android API 28 pending the Phase 0 device matrix.
Release targets the current Play-required SDK and supports `arm64-v8a`; test builds also
carry `x86_64` for emulators. This is a planned floor, not a promise until the Swift AAR
and product usage data are measured.

## Application state and local storage

Kotlin supplies an app-private root such as `filesDir/SnippetsClone` to the Swift facade.
The Swift core creates the same logical structure used by Apple, with provider-specific
additions:

```text
SnippetsClone/
  snippets.json
  Vault/vault.json
  Sync/state.json
  Sync/Providers/<opaque-provider-key>/...
  Backups/
  Tmp/
```

Android uses `SnippetStore.Configuration.android`: no starter snippet and no external
desktop filesystem observer. A fresh install remains empty until the user creates local
content or completes a remote bootstrap, so it cannot look like it authored sample data.

The Swift facade emits an immutable snapshot plus `librarySeq`. The Kotlin repository
turns it into `StateFlow`, ignores stale sequences, and requests a full snapshot if a
bounded diff cannot be applied. Compose renders that state and sends typed mutation
commands back. Swift remains the only mutation serializer and disk writer.

The first release excludes the whole support root from Android cloud/Auto Backup. This
avoids silently uploading plaintext ordinary snippets, wrapped keys, diagnostic files,
or protocol checkpoints to a second cloud with different guarantees. HTTP sync and the
existing encrypted export are the supported recovery paths. Re-enabling selected Android
backup classes requires a separate privacy and restore-consistency design.

## Screens and flows

### Onboarding

1. Choose Local Only, Snippets Cloud, or Custom Server.
2. For HTTP, authenticate with the provider using OIDC Authorization Code + PKCE in a
   system browser/Credential Manager flow.
3. Choose an existing sync space or create one.
4. Obtain its encryption bundle by scanning/approving a pairing code on a trusted
   device or entering the high-entropy recovery key.
5. Show a metadata-leak disclosure: the service sees account, record count, opaque outer
   IDs/revisions, deletion state, sizes and timing, but not snippet fields or keys.
6. Fetch into an empty library before enabling editing. A partial bootstrap is visibly
   incomplete and resumes; it never presents an empty library as successfully synced.

If the user says the source is iCloud, show instructions/deep-link guidance for the
Apple app's provider flow. Never accept iCloud credentials in Android.

### Library and editor

- Phone: touch-first library, search/filter, editor, conflict/recovery banners.
- Tablet/foldable: adaptive list/detail layout with keyboard navigation and shortcuts.
- Draft edits stay local and recover after process death; committing invokes one Swift
  mutation command.
- Import uses Android's Storage Access Framework and passes bounded bytes to the shared
  parser. Export writes only through a user-selected document URI.
- Provider/auth/sync errors are persistent state, not transient toasts. Manual **Sync
  Now** reports whether it started, queued, completed, halted, or needs authentication.

### Settings

- Active provider and endpoint/server identity.
- Account/space status and device pairing/revocation.
- Sync Now, background-sync preference, last successful round, and typed halt recovery.
- One-action Switch and Sync through `provider-switching.md`, with review only for a
  typed safety anomaly.
- Vault timeout, recovery status, and explicit lock.
- Cross-app copy/Process Text behavior and clipboard privacy disclosure.
- Encrypted export/import and local-data deletion.
- Diagnostics export/delete once the Android sink satisfies the existing privacy
  contract; no ad-hoc plaintext log is added meanwhile.

## HTTP authentication and endpoint handling

The app discovers OIDC and protocol capabilities from a canonical HTTPS origin. It uses
Authorization Code + PKCE and validates authorization responses against the initiated
state/nonce and exact redirect URI. Passkeys can be offered by the chosen identity
provider through Android Credential Manager; they do not replace protocol encryption.

Kotlin stores refresh/access credentials under an Android Keystore-backed credential
store and injects short-lived access tokens through OkHttp. Swift receives only HTTP
status, allow-listed headers, and body bytes. It maps 401/403 to typed authentication or
authorization state without seeing or logging token contents.

Custom Server rules:

- HTTPS is mandatory outside explicitly marked local developer builds.
- Canonical origin changes create a different provider identity and require review.
- Redirects may not cross origins; credentials are never forwarded to a new host.
- Discovery is size/time bounded and cannot override client wire/crypto safety limits.
- Certificate errors fail closed. Certificate pinning is not enabled without a rotation
  and emergency-recovery design.
- A server can advertise fewer optional capabilities, never weaker record validation,
  plaintext upload, or a request for raw encryption keys.

## Sync scheduling

Android scheduling is a platform adapter around the shared `SyncEngine`:

- a local committed mutation enqueues a unique one-time Worker after the journal write;
- foreground/start and pull-to-refresh request a round;
- **Sync Now** requests a round and waits for the shared coalesced result;
- a periodic Worker is a missed-push health check, not a promise of an exact interval;
- an FCM data message contains only an opaque provider/space routing token and means
  "changes may exist"; it never carries a record ID, revision, ciphertext, or snippet;
- servers without FCM degrade to periodic/manual sync;
- retry/backoff and permanent/auth failures come from typed shared policy, while
  WorkManager supplies OS constraints and process resurrection.

Use unique work per provider instance. The Worker opens the Swift facade, resolves the
current provider/account binding before reading library state, runs or joins one round,
flushes, and awaits `close()`. Provider switch/delete first cancels unique work and then
awaits the Swift shutdown barrier. A killed Worker is safe because journal/base/cursor
commit order remains owned by the shared engine.

Android does not promise immediate background delivery: Doze, battery restrictions,
missing Google Play services, or user policy can delay work. Foreground and manual sync
must always remain available.

## Secure snippets on Android

The portable library key bundle and Android secret-store adapter bootstrap the same
library identity that iCloud Keychain holds on Apple. Enabling Snippets Cloud does not
remove or replace the Apple Keychain copy.

- The provider-neutral wire key is available after device unlock so either transport can
  move opaque secure bodies without a biometric prompt.
- The vault library key is wrapped by a non-exportable Keystore key requiring user
  authentication according to the vault timeout policy.
- Reveal/edit/cross-app use invokes `BiometricPrompt`, unwraps `K_lib`, and creates a
  bounded Swift vault session. Background sync never asks for `K_lib`.
- Secure plaintext is passed as bytes only for the immediate UI or explicit cross-app
  operation and never persisted in Kotlin state, saved-state bundles, notifications,
  analytics, crash reports, or logs. If the user explicitly chooses **Copy**, mark the
  clip sensitive, disclose that the system clipboard is a wider trust boundary, and
  clear it after a short interval only if Snippets still owns the unchanged clip.
- Secure screens set the platform secure-window policy and clear/redact on background,
  screen lock, timeout, task switch, and process recreation.
- Keystore invalidation enters a recovery-required state. It never creates a new vault
  identity over ciphertext it cannot open.

Recovery can restore the encrypted portable library key bundle but cannot bypass the
user-visible vault recovery policy. Revoking a device removes server access and push
delivery; it cannot erase keys already extracted by a compromised device. A true
cryptographic revocation requires a reviewed space/vault key rotation and full
re-encryption, which is a post-v1 feature with its own migration protocol.

## Cross-app use without a custom keyboard

Snippets does not ship an `InputMethodService`, custom keyboard, Accessibility service,
screen overlay, or background typed-text observer. Consequently Android does not promise
automatic global keyword expansion. Cross-app actions are always initiated by the user.

Supported paths:

- **Copy** from the library/search result, followed by the user's normal system paste.
- **Share** an ordinary resolved snippet through the Android Sharesheet when the target
  accepts text.
- Register an Activity for `Intent.ACTION_PROCESS_TEXT` (`text/plain`). A user selects a
  keyword or other text in a cooperating editor, chooses Snippets from the selection
  menu, picks/resolves a snippet, and Snippets returns the result in
  `Intent.EXTRA_PROCESS_TEXT` when `EXTRA_PROCESS_TEXT_READONLY` is false.
- If Process Text is read-only or the caller cannot accept a result, do not claim that
  replacement succeeded; offer an explicit copy action instead.

Rules for these paths:

- Read/search through the same Swift facade; do not maintain another snippet database.
- Resolve placeholders in shared Swift from a closed set of platform values. Clipboard
  placeholders require an explicit action and current Android clipboard permission.
- Process Text input is untrusted and size-bounded. It may be used as an exact keyword
  lookup but is never logged, synced, or retained after the Activity finishes.
- A secure result requires `BiometricPrompt`. Prefer direct Process Text return because
  it avoids the global clipboard. Explicit secure Copy remains possible only with the
  sensitive flag and warning described above.
- Honor the read-only extra, Activity cancellation, caller change, process recreation,
  and result-size limit. On ambiguity return no replacement.
- Compatibility is best-effort because target applications choose whether to expose and
  honor Process Text. Copy remains the universal explicit fallback.

Removing the keyboard also removes every permission, privacy disclosure, service
lifecycle, and Play-policy obligation associated with an enabled input method.

## Android-specific privacy and diagnostics

The existing typed Foundation-only diagnostics vocabulary remains the gate for shared
events. An Android backend may later persist the same closed schema after it implements
the same retention, permissions, export validation, and privacy tests. Until then,
shared diagnostics can remain a no-op or feed bounded, privacy-safe in-memory state.

Never log or send analytics containing snippet bodies, names, tags, Process Text input,
ciphertext, keys, OAuth tokens, recovery material, record/space/device IDs, server paths,
document URIs, or arbitrary exceptions. User-visible errors use closed family/code
mappings. Crash reporting must strip bridge payloads and attach no local files by
default.

## Test plan

### Swift/AAR

- All shared core tests and cross-platform golden fixtures.
- JNI schema, handle lifecycle, callback ordering, cancellation, process death, and
  malformed-buffer fuzzing.
- Atomic storage and sync crash injection on emulator and physical device.
- Native library packaging for every ABI and deliberate crash symbolication.

### Kotlin/instrumentation

- Compose state and accessibility tests for phone, tablet, foldable, font scaling,
  screen reader, dark mode, rotation, and process recreation.
- Provider onboarding, OAuth cancellation/expiry, pairing/recovery, offline edits,
  conflict/halt review, and account switch.
- Keystore/BiometricPrompt success, timeout, lockout, invalidation, and no-auth paths.
- WorkManager unique-work/coalescing, retry, provider cancellation, and reboot paths.
- Process Text writable/read-only/cancelled/malformed/oversized caller flows, clipboard
  sensitive marking/conditional clearing, Sharesheet behavior, and secure plaintext
  leakage assertions.
- Import/export URI denial, large/malformed data, and backup exclusion.

### End-to-end

- Android <-> Snippets Cloud <-> macOS/iOS HTTP provider round trips.
- Android <-> self-hosted conformance deployment.
- Apple iCloud remains untouched while HTTP is active elsewhere.
- Byte-compatible iCloud -> HTTP switch, independent divergence, and automatic
  loss-preserving switch back to iCloud.
- Network adversary cases: replay, duplicate pages, stale CAS, partial batch, reordered
  events, dropped FCM, cursor invalidation, auth revocation, oversized response, and
  server restore to an older database snapshot.

## Android application exit criteria

The application is ready for public beta only when:

- the mandatory shared Swift core passes on all supported ABIs;
- local CRUD/search/import/export survive process death and storage fault injection;
- HTTP sync interoperates with Apple clients without plaintext at the service;
- iCloud remains selectable and regression-tested on Apple builds;
- secure snippets can be paired, synced locked, revealed only after authentication, and
  recovered without minting a rival vault;
- provider switching and account mismatch halt safely;
- no custom keyboard or Accessibility/overlay permission is present, and explicit
  Process Text/copy/share paths satisfy their privacy and failure contracts;
- release AAB size, startup, memory, battery, crash symbolication, and native library
  packaging meet the budgets established in Phase 0;
- privacy copy, server policy, Play Data Safety answers, and deletion/export flows match
  measured behavior.

Relevant Android primary documentation is rechecked during implementation:
[offline-first data](https://developer.android.com/topic/architecture/data-layer/offline-first),
[WorkManager](https://developer.android.com/develop/background-work/background-tasks/persistent),
[Process Text](https://developer.android.com/reference/android/content/Intent#ACTION_PROCESS_TEXT),
[copy and paste](https://developer.android.com/develop/ui/views/touch-and-input/copy-paste),
[Android Keystore](https://developer.android.com/privacy-and-security/keystore), and
[Credential Manager](https://developer.android.com/identity/sign-in/credential-manager).
