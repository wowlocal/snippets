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
- Single-writer provider selection. Switching to Snippets Cloud performs pull, shared
  three-way merge, encrypted offer generation, CAS push, pull-to-confirm, and only then
  advances the local base. Device-only mode never deletes either cloud.
- A Foundation-only `SnippetsCloudTransport` implementing the existing shared
  `SyncTransport`. This is the Apple-side integration seam; the CloudKit transport and
  its paths are unchanged.

## Security boundaries

- The HTTP service receives the existing wire fields `id`, `rev`, `deleted`, and
  encrypted `blob`. It never receives snippet plaintext or the library key.
- A newly installed Android client creates a random `sync-v1` key locally. To open an
  existing Apple library it must import the same portable key bundle through an
  approved pairing/recovery flow. The current screen accepts that bundle; automating
  the pairing UX is the next increment.
- OIDC token entry is available for development and self-hosted integration. Production
  must replace manual token entry with Authorization Code + PKCE and issuer discovery.
- Diagnostic errors are closed codes. HTTP bodies, tokens, keys, snippet text, UUIDs,
  paths, and server exception strings are not logged.

## Build

Prerequisites are Swift 6.3.3 release, the matching official Android SDK bundle, NDK
r27d or newer, Android SDK 36, and JDK 25 for publishing swift-java's Java runtime.

```sh
./scripts/bootstrap-android.sh

JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
  ./gradlew :app:assembleDebug
```

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

Before production rollout, complete PKCE/pairing UI, add WorkManager scheduling,
run the existing instrumentation boundary suite on the supported phone/tablet matrix,
complete size optimization and release signing. macOS and iOS settings already select
between unchanged CloudKit and `SnippetsCloudTransport`; production authentication UX
remains tracked in the implementation plan rather than hidden behind placeholder behavior.
