# Android implementation status

This branch contains the first end-to-end Android client slice. It is intentionally an
ordinary application, not a keyboard, Accessibility service, or overlay.

## Implemented

- A native Android app (`app/`) for phone and tablet layouts with library, editor,
  search, copy, share, settings, and explicit `ACTION_PROCESS_TEXT` insertion.
- Device-bound AES-256-GCM storage under `noBackupFilesDir`. The wrapping key is
  non-exportable Android Keystore material; Android backup and device transfer are
  disabled for every application data domain. The HLC installation identifier is
  generated once and retained inside the same encrypted store.
- A Swift Android package (`AndroidCorePackage/`) built with the official Swift 6.3.3
  Android SDK and swift-java 0.5.1. The package compiles the repository's existing
  `Snippet`, `HLC`, `SyncMerge`, `SyncEnvelope`, `WireRecord`, and `SnippetCrypto`
  sources rather than translating their behavior into Kotlin.
- A narrow generated JNI boundary accepting JSON and opaque key bytes. Tests cover
  frozen-library CRUD, exact encrypted-record preservation across a provider
  round-trip, and opaque preservation of secure vault records Android cannot yet open.
- Snippets Cloud pull/push with paged cursors, per-record CAS generations, batch
  outcomes, response limits, TLS-only URLs, bearer authentication, and sticky scope
  coordinates. A binding/dataset/feed mismatch stops instead of applying data.
- Native generated-account-key sign-in (server ADR 0006). Signed out, the account screen
  offers **Create Account** and **Sign In with Account Key**; dialogs, cancellation,
  errors and rate-limit waits stay in Compose and never use a browser or WebView.
  Discovery requires `native-account-key-v1` and `flow=account_key`, and pins the create,
  sign-in, refresh and revoke endpoints to `/v2/auth/accounts`, `/v2/auth/sign-in`,
  `/v2/auth/refresh` and `/v2/auth/revoke` on the build-pinned HTTPS origin. Redirects
  are disabled. Typed keys are normalized locally (separators, ASCII whitespace, case,
  O/I/L look-alikes, a 64-byte limit and the ten-bit check); a locally invalid key is
  never sent. Account creation sends an empty body and shows **Save Your Account Key**
  (monospaced selectable display form, **Copy** with the recovery-kit clipboard rules, and
  an explicit **I've Saved It**). Create and sign-in grants share one repository path:
  mutex, journal-first replacement grant, library selection and commit. The app stores
  opaque access and rotating refresh tokens, the immutable account UUID, the canonical
  account key and expiry in device-bound encrypted storage (session schema 2); refresh
  must preserve the account ID, and an older schema reads as signed out. Old browser
  sessions are not imported.
- Device-approved sign-in (server ADR 0007), offered as **Sign In with Another Device**
  only when discovery advertises `native-device-sign-in-v1`. The new device generates
  ordinary pairing recipient material, opens `POST /v2/auth/device-requests`, keeps the
  recipient key, request ID and poll token in the encrypted store, and shows the
  `snippets-device-sign-in` QR/copyable payload (sorted keys, unescaped slashes, unpadded
  Base64url) with the pairing confirmation code and a countdown. It polls the claim
  endpoint about every two seconds with Retry-After and backoff. An approved claim takes
  the account-key grant path (journal, pending session without an account key, commit),
  selects the returned library only if `GET /v2/spaces` lists it, requires the server's
  pairing to carry this device's own recipient key and nonce, and claims the library key
  through the existing recipient pairing claim. Such a device's **Show Account Key**
  explains that the key lives on another device. On an approving device, scan or paste
  accepts the payload, shows the code and consequence before any network call, requires
  the pairing approval's device-owner authentication, creates a pairing clamped to the
  request lifetime, checks its tag, approves it through the library-challenge proof and
  envelope path, and binds the request with a retried, idempotent approval. A self-hosted distribution pins its own service origin;
  an unconfigured build keeps cloud sign-in disabled.
- Approved-device or offline-recovery onboarding. A new device displays a five-minute
  QR invitation for approval by a trusted device, or restores from an offline recovery
  QR/52-character random code. Pairing uses ephemeral P-256 ECDH, HKDF-SHA-256 and
  AES-256-GCM with an eight-character comparison code; recovery uses a separate
  HKDF/AES-GCM domain. Invitations never contain the plaintext library key. The server's
  approved envelope is redacted from polling and atomically taken once.
- Device-owner authentication and a proof derived from the existing library key protect
  pairing approval and recovery replacement. An account key alone cannot unlock an
  existing library or grant its key. Each installation has a distinct refresh family.
  Sign-out and interactive replacement use encrypted credential journals; cleanup revokes
  exact access tokens and superseded refresh families without revoking the committed
  family's earlier rotated tokens. Local erase removes the cloud root before credentials;
  interrupted cleanup resumes on launch. Disconnect explains the key-removal consequence
  and locally known recovery status. Pending recovery kits are encrypted at rest and use
  a resumable save flow with QR, clipboard expiry, Save/Share, and an eight-character
  saved-copy challenge. Later disclosure requires device-owner authentication.
- A dedicated Snippets Cloud account screen separates account identity, library-key
  access, active storage, and sync status. It shows the **Account ID** (`XXXX-XXXX`, the
  first eight hex digits of the account UUID), **Show Account Key** behind the same
  device-owner authentication as recovery-kit disclosure, a cross-device Library ID,
  local snippet count, recovery status, and explicit account actions. Provider changes
  have a destination/account/library preflight instead of behaving like an immediate
  radio-button change.
- Device pairing displays step-by-step instructions, a live five-minute countdown, and
  polls automatically with a manual **Check Again** fallback. Account onboarding does
  not claim readiness when sign-in or key bootstrap finishes: **Up to date** is published
  only after the first pull/merge/push verification round succeeds.
- Single-writer provider selection. Switching to Snippets Cloud performs pull, shared
  three-way merge, encrypted offer generation, CAS push, pull-to-confirm, and only then
  advances the local base. Device-only mode never deletes either cloud.
- A Foundation-only `SnippetsCloudTransport` implementing the existing shared
  `SyncTransport`. This is the Apple-side integration seam; the CloudKit transport and
  its paths are unchanged.

## Security boundaries

- The HTTP service receives the existing wire fields `id`, `rev`, `deleted`, and
  encrypted `blob`. It never receives snippet plaintext or the library key.
- A new installation never mints a key merely because sync starts. Only a truly empty
  personal space may create a provisional random `sync-v1` bundle, and it is installed
  only after its nil-CAS recovery envelope wins. Existing spaces require approved
  pairing or recovery. Lost-response recovery compares the stored opaque envelope
  byte-for-byte, closing the first-device crash window without accepting a rival key.
- Manual bearer-token configuration remains only as a test seam for the disposable E2E
  harness; the shipping settings UI never asks for a token or space UUID.
- Diagnostic errors are closed codes. HTTP bodies, tokens, keys, snippet text, UUIDs,
  paths, and server exception strings are not logged.
- Machine error codes stay out of the account UI. Every surfaced account/sync error says
  what happened, confirms the local-data outcome, and offers the relevant sign-in,
  recovery, pairing, or retry action. Codes remain available only to diagnostics.
- The v2 service can revoke exact access tokens and refresh families but does not expose durable device
  inventory or remote library/account deletion. The account screen does not fake those actions;
  they remain blocked on an additive, authorization-reviewed server contract shared by all clients.

## Build

Prerequisites are Swift 6.3.3 release, the matching official Android SDK bundle, NDK
r27d or newer, Android SDK 36, and JDK 25 for publishing swift-java's Java runtime.

```sh
./scripts/bootstrap-android.sh

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  ./gradlew :app:assembleDebug \
  -PSNIPPETS_CLOUD_ENABLED=true \
  -PSNIPPETS_CLOUD_URL=https://sync.example.com
```

Apple builds use the equivalent public build settings `SNIPPETS_CLOUD_ENABLED=YES` and
`SNIPPETS_CLOUD_BASE_URL=https://sync.example.com`. The feature flag defaults to off on
every platform. The native flow needs no OAuth client ID, client secret, callback host,
App Links, associated-domain callback or Account Center. Omitting the flag or pinned
origin disables sign-in; there is no runtime textbox that can redirect credentials to
an arbitrary origin. The server must advertise the native account-key flow before
sign-in can succeed.

The APK is written to `app/build/outputs/apk/debug/app-debug.apk`. The Gradle module
builds `arm64-v8a` and `x86_64`, generates the Java JNI wrapper, and packages the Swift,
Foundation, Dispatch, ICU, swift-java, and C++ runtimes.

## Verification

The maintained coverage levels, platform/provider matrix, live CloudKit lane, chaos
catalogue, and release evidence are defined in
[testing-strategy.md](testing-strategy.md). The disposable four-way reference lane is
`scripts/test-cross-platform-sync.sh`.

```sh
swift test --package-path AndroidCorePackage
swift build --package-path AndroidCorePackage \
  --swift-sdk aarch64-unknown-linux-android28 --build-system native
swift test --package-path CorePackage
./gradlew :app:assembleDebug
./gradlew :app:connectedDebugAndroidTest
```

Before production rollout, add WorkManager scheduling,
run the existing instrumentation boundary suite on the supported phone/tablet matrix,
complete size optimization and release signing, and configure the native-auth secrets,
identity pepper and canonical HTTPS service URL. macOS and iOS keep unchanged CloudKit
while sharing the native Snippets Cloud account-key flow and automatic token refresh.
