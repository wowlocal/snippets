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
- Native email and six-digit-code sign-in. The email screen opens before discovery;
  resend cooldown, email editing, cancellation and errors stay in Compose. Discovery
  requires `native-email-code-v1` and validates every authentication endpoint against
  the build-pinned HTTPS origin. Redirects are disabled. The app stores opaque access
  and rotating refresh tokens, the immutable account ID, verified email and expiry in
  device-bound encrypted storage; refresh must preserve the account ID. Old browser
  sessions are not imported. A self-hosted distribution pins its own service origin;
  an unconfigured build keeps cloud sign-in disabled.
- Approved-device or offline-recovery onboarding. A new device displays a five-minute
  QR invitation for approval by a trusted device, or restores from an offline recovery
  QR/52-character random code. Pairing uses ephemeral P-256 ECDH, HKDF-SHA-256 and
  AES-256-GCM with an eight-character comparison code; recovery uses a separate
  HKDF/AES-GCM domain. Invitations never contain the plaintext library key. The server's
  approved envelope is redacted from polling and atomically taken once.
- Device-owner authentication and a proof derived from the existing library key protect
  pairing approval and recovery replacement. Email-code sign-in alone cannot unlock an
  existing library or grant its key. Each installation has a distinct refresh family.
  Sign-out and interactive replacement use encrypted credential journals; cleanup revokes
  exact access tokens and superseded refresh families without revoking the committed
  family's earlier rotated tokens. Local erase removes the cloud root before credentials;
  interrupted cleanup resumes on launch. Disconnect explains the key-removal consequence
  and locally known recovery status. Pending recovery kits are encrypted at rest and use
  a resumable save flow with QR, clipboard expiry, Save/Share, and an eight-character
  saved-copy challenge. Later disclosure requires device-owner authentication.
- A dedicated Snippets Cloud account screen separates account identity, library-key
  access, active storage, and sync status. It shows the verified email and a cross-device Library ID,
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
an arbitrary origin. The server must advertise the native flow and have email delivery
configured before sign-in can succeed.

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
complete size optimization and release signing, and configure the production email sender,
native-auth secrets and canonical HTTPS service URL. macOS and iOS keep unchanged CloudKit
while sharing the native Snippets Cloud email-code flow and automatic token refresh.
