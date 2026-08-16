# Shared Swift core on Android

## Objective and success measure

The Android project should reuse the behavior that already protects data compatibility,
not merely reuse a few model structs. The feasibility milestone succeeds only when the
same source files implement all of the following on Apple and Android:

- `Snippet`, HLC, canonical wire JSON, `SyncEnvelope`, and `WireCodec`;
- `SnippetCrypto` encryption/decryption and revision calculation;
- `SyncBase`, `SyncJournal`, `SyncMerge`, `DeletionGuard`, tombstones, quarantine, and
  `SyncEngine`;
- ordinary and secure library projection, including secure conflict materialization;
- vault document/recovery formats and encrypted backup formats;
- search, keyword normalization/suggestions, placeholders, and import parsing.

No copied or translated implementation counts as reuse. Platform conditionals and
narrow injected adapters do. CI will keep an explicit shared-source manifest and fail if
an Android source copy appears under the Gradle project.

A numerical line percentage is less useful than this behavioral boundary, but it will
still be reported after Phase 0: shared Swift lines compiled into the Android AAR divided
by all domain/sync/vault lines, excluding Apple transport, Apple secret storage, and UI.
The initial target is at least 70%; the named compatibility-critical components above
are mandatory even if the percentage is already met.

## Current-source audit

This is a planning audit of the repository as of 2026-08-13. The Android cross-build in
Phase 0 is the authority for exact API availability.

| Classification | Current code | Planned treatment |
| --- | --- | --- |
| Reuse directly | `Snippet`, HLC, `SyncTransport` values/protocol, `SyncBase`, `SyncJournal`, `SyncEngine`, `DeletionGuard`, tombstones, in-memory transport, vault document formats, search, suggestions, placeholders, import parser | Compile the same files in the Android SwiftPM target; add no Android branches unless the cross-build proves one is needed. |
| Reuse with crypto import seam | `SnippetCrypto`, `KeyWrap`, `SyncEnvelope`, `SyncMerge`, library codec, encrypted backup, secure store | Use Apple `CryptoKit` on Apple and the API-compatible `Crypto` product from `swift-crypto` elsewhere; preserve formats and run golden vectors on every platform. |
| Reuse with small POSIX/file seam | `AtomicFileWriter`, `LibraryLock`, `SyncSecureConflictMaterializer`, selected `SnippetStore` persistence and transaction code | Replace direct Darwin imports/calls with a closed `PlatformFileOperations` adapter or conditional platform implementation; keep atomicity, fsync, permissions, and lock semantics. |
| Refactor before reuse | `PassphraseKDF`, `SnippetStore.Configuration`, sync lifecycle/coordinator, diagnostics calls in shared paths | Replace CommonCrypto-only KDF execution with a portable implementation behind the existing format; add `.android`; separate scheduling/provider selection from CloudKit construction; retain the typed diagnostics facade with no Android sink until the app installs one. |
| Apple adapter only | `CloudKitTransport`, CKSyncEngine driver/checkpoint, CloudKit record mapping, `SyncKeyStore`, `KeychainSecretStore`, `VaultIdentityStore` transport, `VaultSession` LocalAuthentication/UI, Apple diagnostics service | Leave in Apple app targets. They are conformances/owners at the boundary, not Android dependencies. |
| Android adapter only | Compose UI, Activity/service lifecycle, WorkManager/FCM, `ACTION_PROCESS_TEXT`, clipboard/share actions, Credential Manager, Android Keystore/BiometricPrompt, OkHttp executor and notifications | Implement in Kotlin and expose only coarse commands/events to Swift. No custom keyboard or Accessibility service is planned. |
| Not portable product logic | AppKit/UIKit controllers, event taps, pasteboard/AX integration, secure capture presentation, MetricKit/CocoaLumberjack backend | Do not compile in the Android package. Implement only the corresponding Android product behavior that is actually required. |

The existing `SyncTransport` abstraction is the main leverage point. It already treats
cursors and record versions as opaque, supports HTTP as a documented backend, requires
per-record compare-and-swap, carries conflict records, models partial acceptance, and
separates push hints from authoritative fetches. The HTTP work should implement this
protocol rather than introduce a second sync engine.

The current `SyncState.Backend` enum already contains `http`, but it is not a complete
provider-selection design. Cursor/base/journal state and cryptographic scope must be
isolated per provider instance as described in `provider-switching.md`; merely setting
that enum is unsafe.

## Swift package and source ownership

Phase 0 adds `AndroidCorePackage/Package.swift` as a production cross-build overlay. Its
canonical sources remain under the existing repository paths. Symlinks or generated
source lists follow the `CorePackage/` precedent and are validated in CI so they cannot
silently omit a newly added shared file.

Start with one dynamic Swift product, `SnippetsAndroidCore`, rather than prematurely
splitting the tightly coupled internal types into public packages. It contains:

```text
SnippetsAndroidCore (dynamic library)
  canonical shared model/codec/crypto/vault/sync sources
  Android-safe storage and provider adapters written in Swift
  AndroidCoreFacade: the only public Java-facing API
```

Internal core declarations stay internal. Only `AndroidCoreFacade` and its deliberately
small DTO/error surface become visible to generated Java. This avoids turning an
evolving JNI generator into the source-compatibility contract for every Swift struct.

The server does not import this whole target. Protocol models are generated separately
from `api/snippets-sync-v2.yaml`, which prevents the blind Go server from gaining
convenient access to envelope plaintext parsers or keys.

## Java/JNI boundary

The preferred bridge is generated by `swift-java`. It should be coarse-grained and
versioned. A representative logical API is:

```text
open(configurationBytes) -> session handle
snapshot() -> encoded immutable library snapshot
execute(commandBytes) -> encoded command result
sync(reason) -> encoded sync result
subscribe(listener) -> cancellation handle
close() -> completion
```

The exact annotations and generated names are chosen by the Phase 0 spike because
`swift-java` is pre-1.0. The contract above is stable even if generator syntax changes.

Rules for the boundary:

- Pass bounded UTF-8 or byte buffers with an explicit schema version. Do not expose the
  graph of Swift actors, protocols, `Date`, `UUID`, `Data`, or error objects directly.
- Use closed command/result/error enums. Never pass `localizedDescription`, reflected
  Swift errors, arbitrary dictionaries, snippet plaintext in error text, or native
  pointers that outlive their documented handle.
- Batch library snapshots/diffs. Do not make one JNI call per visible row, search input
  event, or sync record.
- Swift owns mutation serialization and returns a monotonically increasing library
  sequence. Kotlin turns callbacks into `StateFlow`; it never writes the JSON library
  directly.
- All async entry points define cancellation and shutdown barriers. Android lifecycle
  cancellation must not leave a Swift task writing after the facade or Worker closes.
- The bridge validates sizes before allocating on either heap. Fuzz malformed command
  bytes and invalid handle use.
- Generated bindings are reproducible: pin the generator, regenerate in CI, and fail on
  an uncommitted diff. Whether generated sources are committed is recorded in the Phase
  0 ADR, but release builds never download an unpinned generator.

If generated Java interop cannot meet the crash, cancellation, or build reproducibility
gates, use a very small C ABI facade and conventional JNI shim. The DTO contract remains
the same and all domain logic remains Swift.

## Networking seam

`SyncEngine` remains Swift and continues to call an `HTTPTransport: SyncTransport`.
Only the low-level request executor is platform-specific:

```text
HTTPTransport (Swift: protocol JSON, cursor/CAS mapping, validation)
                  |
HttpExecutor interface (method, origin-relative path, bounded headers/body)
                  |
OkHttp + OIDC interceptor (Kotlin: TLS, connection pool, token refresh)
```

This split keeps sync policy and wire validation shared while using Android's mature
network stack and keeping refresh tokens out of Swift. The executor rejects redirects
to another origin, cleartext HTTP outside explicit local-development builds, oversized
responses, and unrequested content types. It returns status, allow-listed headers, and
body bytes; it does not parse sync records.

Phase 0 must prove Swift-to-Kotlin async interface calls and cancellation. If that path
is unreliable, `FoundationNetworking` is the contained fallback. The fallback needs a
real-device TLS/proxy/cancellation test and an AAB-size comparison before acceptance.
The choice is an ADR; it is not allowed to move `SyncEngine` or merge into Kotlin.

## Crypto portability

Existing ciphertext compatibility is non-negotiable. The Android build must open bytes
produced by the shipping Apple build, and the Apple build must open Android bytes.

For files that currently import `CryptoKit`, use the smallest conditional import:

```swift
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
```

The Android target depends on an exactly pinned `swift-crypto`. No algorithm, nonce,
padding, associated-data, base64url, HKDF label, or revision rule changes as part of
porting. The official Swift Android example already exercises `swift-crypto`, but this
repository's own vectors are the release proof.

`PassphraseKDF` currently imports CommonCrypto. Preserve the existing backup/vault
format and extract KDF execution behind a narrow implementation boundary. Select a
maintained cross-platform PBKDF2 implementation through a separate ADR and prove it
against CommonCrypto and published test vectors. A future Argon2id format needs a new
version and migration design; it must not silently reinterpret existing KDF parameters.

The test corpus includes, at minimum:

- fixed AES-GCM open/seal and authentication-failure vectors;
- HKDF-derived record and content-hash keys;
- exact AAD for ordinary, secure, and tombstone records;
- ISO-7816 padding boundary sizes, including the 900,000-byte wire ceiling;
- canonical JSON Unicode, number, duplicate-key, and depth cases;
- recovery/key-wrap purpose and scope separation;
- PBKDF2/backup import from production-compatible Apple fixtures;
- byte-identical `id`, `rev`, `deleted`, and encrypted `blob` values copied between
  iCloud and HTTP after stripping only provider-owned `recordVersion` metadata;
- secure records whose inner vault ciphertext and portable outer envelope remain
  unchanged during an ordinary provider switch.

Fixtures contain synthetic data only and never production keys or records.

## Persistence portability

The first Android implementation reuses the existing file model rather than maintaining
a second Room schema and a bidirectional database mapper. Swift is the sole source of
truth under an app-private root supplied by Kotlin. A fresh Android install starts empty,
just like iOS, and never points at an Apple or developer support directory.

Portability work must retain the guarantees, not just make the compiler green:

- atomic replace in the destination directory;
- file and directory permissions supported by the Android app sandbox;
- explicit flush/fsync at journal and checkpoint commit boundaries;
- a process lock around all cooperating writers;
- no desktop filesystem observer or starter snippet on Android;
- schema-version probes and fail-closed behavior for newer files;
- crash recovery for promotion/demotion and provider switching;
- Android backup exclusion for device-only keys, transient files, checkpoints, and
  diagnostics; user-data backup behavior is an explicit product decision.

Add `SnippetStore.Configuration.android` with no seed and no external observer. Replace
direct Darwin calls with a closed file-operations implementation selected at compile
time. Do not scatter `#if os(Android)` through merge and crypto algorithms.

Kotlin receives snapshots/events through the facade. The app does not add Room merely
to satisfy a generic Android architecture pattern. Room can later hold non-authoritative
UI caches only if profiling proves the JNI snapshot path cannot meet latency targets.

## Secrets and vault adapters

Apple keeps its existing synchronizable Keychain behavior. Android adds a secret-store
adapter with two different policies:

- The HTTP space wire key must be available to a background sync Worker after the user
  has unlocked the device. It is encrypted at rest by a non-exportable Android Keystore
  wrapping key and is not biometric-gated.
- `K_lib` remains user-presence-gated for reveal. Kotlin runs `BiometricPrompt`, asks the
  Keystore to unwrap it, and passes key bytes to the Swift vault session only for the
  bounded authenticated session. Swift keeps secure bodies as `Data` and clears owned
  buffers best-effort on lock/background/timeout.

Device pairing transfers a versioned encrypted portable-library bundle containing the
library-owned wire material and, when a vault exists, its `kid`, salt, shareable identity,
and `K_lib`. For an existing iCloud library this is the current `sync-v1` material,
exported only inside an end-to-end encrypted bundle after the user enables Snippets
Cloud. The server stores only the encrypted envelope. Details are in `sync-server.md`.

Biometric authentication is an access gate, not a source of deterministic key material.
Removing a screen lock, invalidating a Keystore key, revoking a device, and losing all
paired devices each have explicit recovery UI and tests.

## Toolchain and AAR build

Phase 0 records exact values in a machine-readable lock file rather than relying on
"latest":

- open-source Swift toolchain;
- exactly matching Swift SDK for Android;
- Android NDK (r27d or newer at this research baseline);
- Android SDK/Gradle/Android Gradle Plugin/Kotlin/JDK;
- `swift-java`, `swift-crypto`, and every transitive Swift package revision;
- target triples and minimum Android API.

Start with `arm64-v8a` for devices and `x86_64` for emulator/CI. Add another ABI only
after measuring demand, test cost, and AAB delivery behavior. The initial feasibility
floor is API 28 because the official examples use an Android 28 target; lowering or
raising it is an explicit product/compatibility decision after the device matrix runs.

Gradle invokes SwiftPM for each ABI, generates bindings, packages the product and every
required Swift/Foundation runtime library into one AAR, and strips release symbols into
a separately retained symbol artifact. CI checks that every native dependency resolves
before launch. Adding a Swift dependency can add a runtime `.so`; a missing library must
fail packaging tests rather than appear later as `UnsatisfiedLinkError` on a user device.

Release artifacts record toolchain checksums and dependency provenance. Debug symbols
are retained privately for crash symbolication and must not contain source paths in
user-visible diagnostics.

## Phase 0 feasibility suite

Run the following on a physical arm64 device and x86_64 emulator:

1. Build and load the AAR from a clean checkout with the pinned toolchain.
2. Call a sync and mutation round through generated JNI, including cancellation and an
   exception on both sides of the boundary.
3. Read and write a synthetic library with atomic crash-injection at every durable step.
4. Run all canonical JSON, wire, merge, journal, deletion, crypto, and vault vectors.
5. Exchange fixtures with the macOS CorePackage tests in both directions.
6. Execute HTTPS through the Kotlin executor and through the fallback, including token
   refresh, offline transition, TLS failure, timeout, redirect, cancellation, and an
   oversized response.
7. Run a foreground sync and a WorkManager-started sync after process death.
8. Measure cold load, snapshot/search latency, peak RSS, JNI call counts, AAR/AAB size,
   and per-ABI native size.
9. Verify release symbol stripping and symbolication of a deliberate native crash.
10. Rebuild twice and compare generated binding/API manifests and packaged library sets.

Phase 0 fails, and implementation pauses for an ADR, if any mandatory shared component
has to be rewritten in Kotlin, crypto fixtures differ, persistence loses a journaled
mutation under crash injection, or the native crash/cancellation lifecycle is not
controllable. Size and performance budgets are set from the measurements before UI work
begins; they are not guessed in this document.
