# Android and cross-cloud implementation plan

Status: design proposal, 2026-08-13. This directory is an implementation plan, not a
claim that the Android app or HTTP service already ships. The existing Apple apps and
their CloudKit implementation remain the code authority until each phase below lands.

## Product decision

Adding Android does **not** mean migrating the product away from iCloud.

Snippets will support one active writable sync provider for a local library at a time:

| Provider | macOS/iOS/iPadOS | Android | Operator |
| --- | --- | --- | --- |
| Local only | Yes | Yes | None |
| iCloud | Yes | No | Apple/private CloudKit database |
| Snippets Cloud | Yes | Yes | Snippets-hosted HTTP service |
| Custom Server | Yes | Yes | User or organization, same open HTTP protocol |

iCloud remains a first-class option on Apple devices, with the existing private
database, CloudKit zone, wire format, and synchronizable Keychain bootstrap. It is not
renamed to "legacy", automatically copied, or silently dual-written to another service.
Android cannot select iCloud because it has neither the CloudKit app entitlement nor the
iCloud Keychain bootstrap used by the current implementation.

To use an existing iCloud library on Android, a user selects **Switch to Snippets Cloud**
or **Switch to Custom Server** on an Apple device and pairs Android. The normal switch is
an automatic, loss-preserving sync, not a migration wizard: both transports use the same
`WireRecord`, portable library key, vault identity, merge rules, tombstones, and feature
set. The original iCloud library is retained, and switching back uses its saved cursor and
base to merge changes normally. Human review appears only for an exceptional safety halt
such as a changed account, incompatible key/vault, remote reset, too-new schema, or the
deletion guard. The transaction is specified in
[provider-switching.md](provider-switching.md).

Permanent live mirroring between iCloud and HTTP is out of scope. Two writable backends
would create ambiguous conflict ancestry, deletion propagation, key rotation, and partial
failure semantics. A future explicit one-way backup/export feature may read from the
active provider, but it must not masquerade as sync.

## Architecture decision

The Android application is native Android at the operating-system boundary and shared
Swift at the product/domain boundary:

```text
Android UI and OS services (Kotlin, Compose, WorkManager, FCM, PROCESS_TEXT,
Credential Manager, Android Keystore, BiometricPrompt, OkHttp)
                              |
                    narrow generated JNI bridge
                              |
Shared Swift core (model, file formats, crypto, vault projection, journal,
merge, deletion guard, SyncEngine, HTTP SyncTransport)
                              |
                   Snippets HTTP protocol v1
                              |
Swift service (Hummingbird + OpenAPI + PostgreSQL)
```

This is deliberately not a SwiftUI wrapper and not a line-for-line port of the UIKit
application. Kotlin owns lifecycle and Android APIs. Swift owns the behavior whose
byte-for-byte compatibility matters across devices. The official Swift SDK for Android
builds that code as Android shared libraries; `swift-java` generates the Java/JNI
surface, which Gradle packages into an AAR.

The service stores opaque `WireRecord` values and server-owned concurrency metadata. It
does not receive plaintext snippets, merge user content, or possess the library keys.
It uses OIDC for account authentication, PostgreSQL transactions and compare-and-swap
for consistency, and defense-in-depth row-level security for tenant separation.

## Planned repository layout

The implementation phases add these roots without moving CloudKit into the shared core:

```text
AndroidCorePackage/          # SwiftPM Android build overlay over canonical shared files
snippets-android/            # Gradle project, Kotlin/Compose app and Android adapters
api/snippets-sync-v1.yaml    # protocol source of truth, generated client/server models
server/                      # Swift HTTP service, migrations, container and tests
docs/android/                # this design and its ADRs
```

Canonical domain sources continue to live under `snippets/Core/`, `snippets/Sync/`,
`snippets/Vault/`, and `snippets/SnippetStore.swift`. `AndroidCorePackage/` follows the
existing `CorePackage/` overlay pattern so Android and Apple compile the same source
files rather than copies. Platform-only code remains in its app target. In particular,
`CloudKitTransport`, CKSyncEngine checkpointing, Apple Keychain, and Apple authentication
UI do not enter the Android package.

## Fixed decisions versus early gates

Fixed now:

- Keep iCloud fully supported and opt-in on Apple platforms.
- Allow exactly one active writable provider per local library.
- Make the logical library and its encryption identity provider-neutral: iCloud and HTTP
  carry the same encrypted records; only transport cursors, CAS tokens, account binding,
  subscriptions, and scheduling are provider-specific.
- Make ordinary switching a one-action automatic sync. Reserve a review workflow for
  safety anomalies, not every provider change.
- Use the existing encrypted wire envelope, merge rules, journal, deletion guard, and
  sync engine on Android from their Swift sources.
- Use a native Kotlin/Compose shell and native Android security/lifecycle APIs.
- Build an open, self-hostable HTTP protocol and a Snippets-hosted deployment of the
  same server.
- Keep account authentication separate from end-to-end encryption keys.
- Store only ciphertext and minimum routing/concurrency metadata on the server.
- Implement the server in Swift and use PostgreSQL as the source of truth.

Must be proven in Phase 0 before product work depends on it:

- The exact compatible Swift toolchain, Android Swift SDK, NDK, Gradle plugin, and
  `swift-java` versions.
- Generated bindings, Swift concurrency, cancellation, and exception mapping on real
  arm64 Android devices and an x86_64 emulator.
- Whether the low-level HTTP executor is a Kotlin/OkHttp implementation called from a
  Swift `HTTPTransport` (preferred) or `FoundationNetworking` (fallback). This is a
  binary-size and reliability decision; it does not move merge/sync policy to Kotlin.
- Which Foundation and POSIX APIs used by persistence require small portability seams.
- A byte-for-byte `swift-crypto` compatibility proof for every existing crypto vector.

If `swift-java` itself is the blocker, the fallback is a small stable C ABI plus a JNI
shim around the same Swift facade, not a rewrite of the domain core in Kotlin.

## Documents

- [shared-swift-core.md](shared-swift-core.md) audits what can be reused and specifies
  the Swift package, JNI boundary, portability work, and feasibility gates.
- [app-plan.md](app-plan.md) specifies the native Android application, local storage,
  secure-snippet behavior, sync scheduling, and explicit cross-app text actions.
- [provider-switching.md](provider-switching.md) defines iCloud preservation, provider
  state isolation, switching/copy semantics, downgrade behavior, and recovery.
- [sync-server.md](sync-server.md) specifies the HTTP service, API resources, PostgreSQL
  isolation, authentication, key pairing, security, and operations.
- [delivery-plan.md](delivery-plan.md) breaks the work into phases with exit criteria,
  tests, rollout gates, risks, and a proposed critical path.

## Non-goals for the first public Android release

- Direct CloudKit or iCloud Keychain access from Android.
- Simultaneous iCloud and HTTP writes from one library.
- Team/shared libraries, public links, or server-side search.
- Server-side decryption, merge, content indexing, or content-derived telemetry.
- A compatibility promise for arbitrary third-party sync implementations before the v1
  conformance suite passes.
- A custom Android keyboard/IME, Accessibility service, overlay, or background
  interception of typed text. Cross-app use is explicit copy/share or Android
  `ACTION_PROCESS_TEXT`; automatic global keyword expansion is not promised on Android.

## Design invariants

Implementation is not complete if any of these cease to be true:

1. A user who stays on iCloud experiences no HTTP account creation, key upload, server
   contact, or provider-state migration.
2. An Android build never contains Apple CloudKit, Security, LocalAuthentication,
   AppKit, or UIKit dependencies.
3. A sync server can count records and see outer IDs, revisions, deletion flags, sizes,
   and timing, but cannot read names, keywords, tags, bodies, vault identity, or keys.
4. A backend/account/space binding is resolved before local data enters a sync round,
   and a mismatch causes a sticky review halt.
5. Local intent is journaled before cursors, provider checkpoints, or account bindings
   are discarded.
6. Ordinary provider switching preserves the same encrypted library, creates a
   recoverable local backup, automatically merges both sides, and never deletes the
   source cloud. Only a typed anomaly requires human review before a target write.
7. Server authorization is checked both in the application and in PostgreSQL; the
   runtime database role cannot bypass or own row-level-security tables.
8. Authentication tokens are not encryption keys. Account recovery cannot silently
   recreate a lost end-to-end encryption key.
9. Logs on clients and server exclude snippet data, ciphertext, keys, tokens, raw stable
   user/device/record identifiers, paths, and arbitrary error text.
10. Existing Apple wire/schema fields remain additive-only wherever production data
    already exists.

## Research baseline

The toolchain assumptions were checked against primary project documentation on
2026-08-13. They are intentionally revalidated and pinned in Phase 0 because this area
is changing quickly:

- [Swift SDK for Android: Getting Started](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)
- [swiftlang/swift-java](https://github.com/swiftlang/swift-java)
- [swiftlang/swift-android-examples](https://github.com/swiftlang/swift-android-examples)
- [Swift packages for server development](https://www.swift.org/packages/server.html)
- [Swift OpenAPI Generator](https://www.swift.org/blog/introducing-swift-openapi-generator/)

The official Android guide requires a matching open-source Swift toolchain and Android
Swift SDK and currently calls for Android NDK r27d or newer. The official example builds
a dynamic Swift package, uses `swift-java` binding generation, links `swift-crypto`, and
packages the resulting native libraries for Kotlin/Compose. `swift-java` is still under
active development and does not promise API stability before 1.0, so exact pins and a
small bridge are release requirements, not optional build hygiene.
