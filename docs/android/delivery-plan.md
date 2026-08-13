# Delivery plan: Android app and sync service

## Definition of the first public release

The first public Android release is not complete until a user can:

1. install a native Android app and use a durable offline library;
2. create or authenticate to Snippets Cloud or a conforming Custom Server;
3. pair/recover end-to-end encryption keys without the service learning them;
4. sync ordinary and secure snippets with an Apple device using the HTTP provider;
5. keep using iCloud instead on Apple devices, with no forced account or migration;
6. switch between fully compatible iCloud and HTTP transports with automatic merge,
   backup, no feature conversion and no source-cloud deletion;
7. use snippets in other apps through explicit copy/share or Android Process Text,
   without a custom keyboard or Accessibility service;
8. export/delete local and service data under documented privacy/retention behavior.

A local-only Android demo or a server that only stores test records is an intermediate
milestone, not delivery of the requested product.

## Planning assumptions and estimate

The ranges below assume two engineers able to work across Swift/Android client code, one
backend/infra engineer, and part-time product design, security review, and QA. With that
staffing, the current planning range is roughly 26-38 calendar weeks to a responsible
public beta. It is not a release promise: Phase 0 exists specifically to replace the
largest Swift-on-Android unknowns with measurements.

With one engineer, elapsed time will be materially longer because app, bridge, server,
operations, and security work cannot safely collapse into one sequential MVP. Adding
people before the protocol/key design is stable does not shorten the critical path.

The shared Swift core removes a large domain rewrite, but it does not remove native UI,
JNI/build tooling, HTTP protocol, authentication, key bootstrap, tenant isolation,
operations, provider UX, and cross-platform testing.

## Phase 0 — feasibility and ADRs (2-3 weeks)

Goal: prove the risky foundation before modifying shipping persistence or promising an
Android minimum version.

Deliverables:

- `AndroidCorePackage` spike with exact toolchain/SDK/NDK/Gradle/JDK/dependency lock;
- generated `swift-java` AAR loaded on arm64 device and x86_64 emulator;
- narrow facade call, callback, async cancellation, cross-language error, and shutdown;
- shared canonical JSON, wire, crypto, merge and journal tests on Android;
- Apple <-> Android golden ciphertext and file-format exchange;
- atomic file/lock/fsync spike under Android process death;
- Kotlin/OkHttp executor called by Swift `HTTPTransport` prototype and measured
  `FoundationNetworking` fallback;
- AAR/AAB size, cold start, RSS, JNI overhead and native symbolication baseline;
- source-reuse report and list of every failed Foundation/POSIX API;
- written ADRs for bridge, networking, package layout, minimum API/ABI, and persistence.

Exit gate:

- mandatory core components compile from the same source files;
- crypto/wire bytes match;
- crash injection does not lose acknowledged/journaled intent;
- native lifecycle/cancellation is controllable;
- packaged runtime libraries are complete and reproducible;
- measured size/performance has an agreed product budget.

If generated interop fails, spend at most the phase's explicit fallback budget proving a
C ABI/JNI facade over the same Swift core. If both fail a mandatory gate, stop and write
an architecture decision before building UI or server features around an unproven path.

## Phase 1 — production shared-core boundary (4-6 weeks)

Goal: turn the spike into a maintained cross-platform product library without changing
shipping Apple behavior.

Work:

- add conditional `CryptoKit`/`Crypto` portability and pin `swift-crypto`;
- extract/implement portable PBKDF2 behind the existing format and test vectors;
- replace direct Darwin file operations with a closed portability seam;
- add Android store configuration with no seed or external observer;
- inject storage/protocol locations instead of global paths;
- separate provider-neutral sync lifecycle from current CloudKit-only construction;
- implement versioned Android facade/DTOs and Kotlin Flow wrapper;
- add shared-source manifest, generated-binding diff, ABI library-set check, fuzz and
  crash-injection jobs;
- keep `CloudKitTransport`, Apple Keychain, UIKit/AppKit and Apple diagnostics at their
  current app boundary;
- run CorePackage tests and both Apple builds on every shared change.

Exit gate:

- Apple unit/build behavior is unchanged, including absent iCloud preference behavior;
- Android can CRUD/search/import/export a synthetic local library after process death;
- Android opens production-compatible encrypted exports and secure wire fixtures;
- no platform code or duplicated domain implementation appears in the wrong target.

## Phase 2A — Android offline application (5-7 weeks, overlaps 2B)

Goal: a usable, durable native app before network complexity obscures client defects.

Work:

- Compose phone and adaptive tablet/foldable library/editor;
- navigation, drafts, validation, search/filter/tag/pin and conflict UI;
- Storage Access Framework import/export and encrypted backup flows;
- process recreation, accessibility, keyboard navigation and large-content behavior;
- Keystore/BiometricPrompt adapter and local secure-snippet create/reveal/edit/lock;
- Settings skeleton with Local Only active and unavailable network providers clearly
  marked as pre-release;
- macrobenchmarks and leak/plaintext assertions;
- initial writable/read-only `ACTION_PROCESS_TEXT` and sensitive-clipboard proof.

Exit gate:

- offline app passes phone/tablet instrumentation and storage fault tests;
- secure plaintext is absent from saved state, logs and crash attachments; explicit
  secure Copy is sensitive-marked and conditionally cleared;
- Process Text returns only for a writable caller and the app declares no input method,
  Accessibility service, or overlay permission;
- measured UI/search/startup budgets hold with a realistic synthetic library.

## Phase 2B — protocol and service foundation (6-8 weeks, overlaps 2A)

Goal: a self-hostable ciphertext/CAS service with real tenant isolation, initially
against test clients and synthetic keys.

Work:

- review/freeze OpenAPI v1 outer records, discovery, errors and limits;
- bootstrap Hummingbird/PostgresNIO service and reproducible container;
- SQL migrations, separate owner/runtime roles, `FORCE RLS`, transaction context;
- spaces/memberships, record CAS, immutable change feed, cursor/full snapshot;
- authoritative conflict records, partial batches, quota/rate limiting;
- OIDC validation and native-app staging client configuration;
- dataset/feed generations and restore/reset runbook;
- sanitized metrics/traces/logs with no body/resource/token leakage;
- hosted staging deployment and clean Docker Compose self-host deployment;
- concurrency/property, two-tenant isolation, fuzz, load and conformance tests.

Exit gate:

- CAS/feed invariants hold under concurrent/fault-injected integration tests;
- cross-tenant application and direct-runtime-role probes all fail closed;
- a backup restore triggers the required dataset-reset review signal;
- hosted and self-hosted deployments pass the same data-plane suite;
- no server component imports plaintext envelope parsing or keys.

## Phase 3 — end-to-end HTTP vertical slice (5-7 weeks)

Goal: Android, macOS/iOS, and the Swift service sync ordinary synthetic libraries through
the existing shared engine.

Work:

- implement `HTTPTransport: SyncTransport` and OpenAPI mapping in shared Swift;
- implement Kotlin OkHttp executor, PKCE/OIDC token owner, offline/auth mapping;
- add Apple HTTP executor/token adapter without changing CloudKit transport;
- implement HTTP account/scope/dataset binding and sticky review states;
- provider-specific base/journal/quarantine paths;
- manual/start/foreground/local-change/background polling on Android;
- content-free optional FCM hint and missed-push health check;
- server export/delete skeleton for opaque data;
- full Android <-> server <-> Apple ordinary-record interoperability suite.

At this phase HTTP provider UI remains behind an internal feature flag. iCloud continues
to be driven by `SnippetsICloudSyncEnabled` for ordinary users.

Exit gate:

- duplicates, partial batches, conflict, auth expiry, cursor invalidation, offline retry,
  process death and server restore have the specified result;
- server inspection proves only opaque outer data is present;
- an iCloud-only run makes no HTTP request and an HTTP run constructs no CloudKit
  transport;
- Apple CloudKit regression suite and signed-environment safety remain green.

## Phase 4 — key bootstrap, secure records and provider switching (6-8 weeks)

Goal: make the vertical slice safe for real libraries and preserve iCloud as a user
choice.

Work:

- freeze/version `PortableLibraryKeyBundle`, pairing and recovery envelope formats;
- independent cryptography review and HPKE/recovery test-vector suite;
- pairing offer/approval/one-use/expiry service and client flows;
- Android/Apple platform key storage and vault identity adoption;
- secure records synchronized while locked and revealed only after user authentication;
- `SyncProviderSelection`, compatibility preference mirroring, shutdown barrier;
- one-action Switch and Sync, target staging, encrypted backup, automatic merge and
  anomaly-only review transaction;
- byte-identical cross-provider wire fixtures plus same/rival library key/vault flows;
- Local/iCloud/Snippets Cloud/Custom Server settings on Apple; Local/HTTP on Android;
- provider downgrade, crash recovery, deletion guard, account/dataset reset and return-to-
  stale-provider tests;
- complete encrypted space export and reviewed remote deletion.

Exit gate:

- iCloud-only users undergo no file/key/account migration and all Apple regression tests
  pass;
- source remote is untouched by switch/cancel/failure;
- all unchanged wire blobs and secure inner ciphertext remain byte-identical across an
  iCloud/HTTP/iCloud round trip;
- service and identity-provider compromise alone cannot open a space fixture;
- every switch crash point recovers to an identified source or target with a verified
  backup, never an ambiguous dual writer;
- lost key material halts for pairing/recovery rather than minting over ciphertext.

## Phase 5 — explicit Android text actions and product completeness (2-4 weeks)

Goal: deliver the Android product behavior, not just a database browser.

Work:

- production Copy/Share and writable/read-only `ACTION_PROCESS_TEXT` flows;
- search, selection and placeholder resolution through the same Swift facade;
- bounded untrusted Process Text input, caller cancellation and exact result handling;
- authenticated secure Process Text plus explicit sensitive-marked clipboard copy with
  conditional expiry/clearing;
- provider/account/recovery/sync status polish and actionable halt UI;
- notifications, offline/background/battery messaging and no-GMS behavior;
- Android diagnostics backend only if it meets the existing schema/privacy/export bar;
- accessibility, localization and tablet/foldable refinement;
- privacy disclosures, Play Data Safety draft and support documentation.

Exit gate:

- Process Text instrumentation passes writable, read-only, cancelled, malformed,
  oversized and non-supporting target cases;
- the manifest contains no IME, Accessibility service or overlay permission, and Process
  Text input never leaves the device;
- end-to-end ordinary/secure explicit use works after process death and sync;
- public-facing privacy text matches network, backup, logs, metadata and deletion tests.

## Phase 6 — hardening and staged beta (4-6 weeks)

Goal: prove operational and privacy behavior under production-like failure before broad
release.

Work:

- external security review of protocol, pairing/recovery, platform storage and RLS;
- dependency/SBOM/license review and reproducible signed server/app artifacts;
- load/soak/chaos tests, database failover/restore and dataset-reset drill;
- backup/deletion/export/incident/support runbooks and on-call alarms;
- native crash symbolication, performance/battery/AAB-size final budgets;
- self-host upgrade/rollback/conformance from the oldest supported v1 release;
- migration exercises using synthetic copies of large/old/conflicted libraries;
- internal alpha, hosted dogfood, clean self-host dogfood, closed Play testing, then
  staged HTTP provider enablement on Apple;
- beta telemetry limited to pre-approved aggregate typed events, or no telemetry where
  the privacy-safe vocabulary does not cover the question.

Release gate:

- all exit criteria in `README.md`, `app-plan.md`, `provider-switching.md`, and
  `sync-server.md` are evidenced in CI/runbooks/review;
- no open critical/high security finding and no unexplained cross-platform fixture diff;
- restore, account switch, provider switch, lost-device, lost-key, server unavailable,
  quota and deletion support paths have been rehearsed;
- iCloud remains independently selectable, supported, and regression-tested;
- rollout has a kill switch for HTTP scheduling that does not disable local use or
  iCloud and does not discard journaled intent.

## Continuous verification matrix

The executable coverage and cadence contract is maintained in
[testing-strategy.md](testing-strategy.md); this section describes the delivery streams
that supply those lanes.

Shared changes run the repository's existing required checks:

```sh
swift test --package-path CorePackage

xcodebuild -project Snippets.xcodeproj -scheme Snippets \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/snippets-macos-derived CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Snippets.xcodeproj -scheme 'Snippets iOS' \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/snippets-ios-derived CODE_SIGNING_ALLOWED=NO build
```

The implementation adds, with exact locked target names determined in Phase 0:

```text
Android SwiftPM cross-build for arm64 and x86_64
Android shared-core/golden/fuzz tests on emulator and physical device
Gradle unit, lint, Compose/Process Text instrumentation and macrobenchmarks
Server Swift tests and PostgreSQL integration/RLS/property tests
OpenAPI generation-diff and hosted/self-hosted conformance tests
End-to-end Apple/Android/provider switching and encrypted fixture exchange
Container/SBOM/dependency/image/migration/backup-restore checks
```

No test writes to the user's live Apple support directory or a developer's real cloud
space. iOS UI reset safeguards remain intact. CloudKit Production diagnostics continue
to use the signed artifact's actual entitlements, never a scheme name.

## Work that may proceed in parallel

After Phase 0 and the core DTO/protocol decisions, these streams can run concurrently:

- Android offline UI and explicit Process Text/copy proof;
- server CAS/feed/RLS and self-host packaging;
- shared portability and HTTP transport;
- product design for onboarding, one-action switching, anomaly review and recovery;
- security modeling and test-vector/conformance harness.

They rejoin at the Phase 3 vertical slice. Provider switching cannot be finalized before
provider state paths/account binding and portable key bundle formats are stable. Secure UI cannot
be declared complete before pairing/recovery and rival-vault behavior exist. Hosted
release cannot outrun self-host conformance because they share the protocol promise.

## Required ADRs

Create short, reviewable ADRs as decisions become evidenced:

1. Swift/Android toolchain, ABIs, minimum API and reproducible AAR.
2. `swift-java` versus C ABI fallback and the versioned bridge schema.
3. Kotlin OkHttp executor versus `FoundationNetworking` fallback.
4. Shared storage/POSIX and Android backup policy.
5. Portable PBKDF2 dependency/implementation and crypto vector ownership.
6. HTTP v1 OpenAPI, limits, cursor/CAS and compatibility policy.
7. Hosted OIDC provider and self-host issuer configuration.
8. `PortableLibraryKeyBundle`, HPKE suite, recovery format and key epochs.
9. Provider state locations, full iCloud/HTTP compatibility, account binding, downgrade
   and Switch and Sync transaction.
10. Server retention, tombstone policy, database restore generation and deletion.
11. Android Process Text, clipboard sensitivity/expiry and explicit sharing behavior.
12. Diagnostics/crash reporting and the exact approved Android/server data boundary.

## Open product/operational decisions

These do not block writing the Phase 0 spike, but they must be decided before the named
phase exits:

- hosted identity provider, sign-in methods, region/subprocessor requirements;
- free/paid quotas, abuse thresholds and support/deletion cooling period;
- final Android minimum API and whether any non-Google push path is offered;
- whether the server and conformance suite are open-source and under which license;
- encrypted export retention and Auto Backup policy disclosure;
- public v1 self-host support/upgrade window;
- localization set and accessibility acceptance owners;
- exact secure-clipboard timeout and whether secure Share is disabled entirely.

## Immediate next implementation slice

After this plan is approved, the next branch should contain only the Phase 0 spike:

1. add the locked Android toolchain manifest and Gradle sample;
2. expose one versioned Swift facade over `Snippet` plus canonical wire/crypto fixtures;
3. package/load it on arm64 and x86_64;
4. prove Kotlin callback/cancellation and the HTTP executor;
5. run Apple/Android byte-exchange and storage crash tests;
6. publish the measured ADR and go/no-go result.

Do not begin by scaffolding every screen or deploying a production account. That would
create parallel commitments before the one dependency unique to this strategy—running
the existing Swift safety core reliably inside an Android app—has passed its gate.
