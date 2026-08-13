# Snippets test strategy

This document is the gate policy for the complete Snippets system: the sync server and
PostgreSQL, the shared Swift core, the native macOS and iOS applications, and the Android
application. Component READMEs retain exact setup details; this file defines which
layers must be combined before a change may merge or ship.

The strategy protects four product promises:

1. iCloud remains an unchanged, independently selectable Apple provider.
2. Snippets Cloud carries the same encrypted wire records and portable library key on
   macOS, iOS, and Android; the server never receives plaintext.
3. Switching providers preserves local intent and requires an explicit review on any
   account, scope, dataset, or server binding mismatch.
4. One authenticated user cannot observe, join, overwrite, or infer another user's
   space, including through direct runtime-role SQL.

## Gate levels

| Gate | Trigger | Required environment | Purpose |
|---|---|---|---|
| Fast | Every pull request | Hermetic local/CI process | Contract, core semantics, parsing, crypto vectors, HTTP behavior, and platform compilation. |
| Database | Any server persistence, migration, auth-context, cursor/CAS, or deployment change | Disposable PostgreSQL database ending in `_test`, separate owner/runtime roles | Transactions, concurrent CAS, migrations, runtime grants, and `FORCE ROW LEVEL SECURITY`. |
| Platform | Shared model, persistence, crypto, merge, sync, vault, or UI boundary change | macOS runner, iPhone and iPad simulators, Android emulator | Proves that shared behavior still compiles and executes at each native boundary. |
| Live compatibility | Protocol, provider switching, portable key, HTTP transport, CloudKit adapter, or release candidate | Disposable HTTPS/OIDC/API/PostgreSQL stack and empty test space | Cross-client encrypted record exchange and clean-install recovery. |
| Release | Every release candidate | Signed staging artifacts plus physical Apple and Android devices | Entitlements, device keystores/keychain, backgrounding, networking, upgrade, restore, and operator drills. |

A required gate is not replaced by a later gate. For example, a successful live test
does not replace deterministic unit tests, and an in-memory HTTP test does not replace
the PostgreSQL/RLS gate. Failed gates are investigated; automatic retries may collect
evidence but must not turn a nondeterministic result green.

## Change-to-gate matrix

| Changed area | Fast | Database | Platform | Live compatibility | Release |
|---|---:|---:|---:|---:|---:|
| Server docs only | required | — | — | — | — |
| OpenAPI or HTTP mapping | required | required | required | required | required |
| Migration, SQL, RLS, roles, cursor, CAS | required | required | conditional if contract unchanged | required | required |
| OIDC/JWKS validation or identity binding | required | required | conditional | required with two subjects | required |
| Shared Swift model/codec/crypto/merge/vault | required | conditional if HTTP persistence is affected | required | required | required |
| macOS/iOS CloudKit adapter | required | — | required | required iCloud regression plus provider switching | required |
| Android storage/bridge/HTTP client | required | conditional if protocol behavior changes | required | required | required |
| Provider switching or account binding | required | conditional | required | required in both directions | required |
| Packaging, signing, entitlements, container | required | required for server image | required | required | required plus artifact inspection |

“Conditional” means the author must record why the gate is unrelated when omitting it.
Changes to a shared DTO, wire codec, portable key, cursor, or provider state are always
cross-platform even if the diff is located under one platform directory.

## Canonical commands

### Server fast gate

Run from the repository root:

```sh
cd server
./Scripts/check-openapi.sh
swift build
swift test
```

`check-openapi.sh` and `SyncHTTPTests.testNormativeOpenAPIAndPluginInputAreIdentical`
both require the generator input to remain byte-for-byte identical to
`api/snippets-sync-v1.yaml`. The normal test run builds the PostgreSQL integration target
but skips its destructive test methods unless their explicit gate is enabled. The fast
OIDC test signs a current ES256 token, serves its JWKS through an intercepted HTTPS
request, verifies stable issuer/subject pseudonyms, and rejects wrong issuer/audience
claims without contacting an external identity provider.

### PostgreSQL gate

```sh
cd server
./Scripts/test-integration.sh
```

The helper owns a dedicated Compose project and volume and removes both on exit. An
already-provisioned database may be used only when its name ends in `_test`:

```sh
cd server
SNIPPETS_INTEGRATION_TESTS=1 \
DATABASE_HOST=127.0.0.1 \
DATABASE_PORT=55432 \
DATABASE_NAME=snippets_sync_test \
DATABASE_OWNER_USER=snippets_owner \
DATABASE_OWNER_PASSWORD='<ephemeral-owner-password>' \
DATABASE_RUNTIME_USER=snippets_runtime \
DATABASE_RUNTIME_PASSWORD='<ephemeral-runtime-password>' \
DATABASE_TLS_MODE=disable \
swift test --filter PostgresIntegrationTests
```

This gate must cover both store-level concurrency and the HTTP-to-database identity
boundary. Its minimum assertions are:

- migrations are checksum-pinned and can be applied concurrently under the advisory
  lock;
- two identities can use the same record UUID while retrieving only their own exact
  blob bytes;
- create-only concurrent CAS has exactly one accepted result and one conflict;
- a response discarded after an update commit can be retried with the original CAS
  token: the retry returns the committed authoritative record and appends no change;
- a mixed stale/new batch commits the independent item, preserves positional outcomes
  even when database lock order differs, and remains convergent when delivered again;
- repeating a delta request with the same cursor returns the same ordered records and
  next cursor, while advancing that cursor does not expose a duplicate retry;
- a request token becomes only an internal keyed principal, and the transaction-local
  `app.user_id` reaches RLS without leaking back into the pool;
- a wrong identity receives `not_found`, cannot attach itself to a known foreign space,
  and a connection with no identity sees zero protected rows;
- the runtime role is not a superuser, cannot bypass RLS, and owns no protected table;
- a restore-generation rotation invalidates old cursors and record versions.

### Deterministic network-chaos boundary

The fast in-memory check can be run on its own:

```sh
cd server
swift test --filter \
  MemorySyncStoreTests.testLostResponseRetryAndDeltaReplayConvergeWithoutDuplicateChange
```

With the disposable PostgreSQL environment from the previous section, run the full HTTP
boundary check directly:

```sh
cd server
SNIPPETS_INTEGRATION_TESTS=1 \
DATABASE_HOST=127.0.0.1 \
DATABASE_PORT=55432 \
DATABASE_NAME=snippets_sync_test \
DATABASE_OWNER_USER=snippets_owner \
DATABASE_OWNER_PASSWORD='<ephemeral-owner-password>' \
DATABASE_RUNTIME_USER=snippets_runtime \
DATABASE_RUNTIME_PASSWORD='<ephemeral-runtime-password>' \
DATABASE_TLS_MODE=disable \
swift test --filter \
  PostgresIntegrationTests.testHTTPNetworkChaosRetriesPartialBatchAndDeltaReplayStayConvergent
```

These tests inject failure at a deterministic durability boundary rather than using
random delays. The update request is allowed to reach the router and complete its
PostgreSQL transaction, then its entire response is ignored. The exact request with its
pre-commit CAS token is delivered again. The tests require an authoritative conflict,
one durable update, and no extra sequence. They also replay one delta cursor and require
the serialized response to be identical.

The PostgreSQL case additionally sends `[stale update, independent create]` with UUIDs
chosen so internal lock ordering is the reverse of request ordering. It requires
`[conflict, accepted]`, redelivers the batch, requires `[conflict, conflict]`, and checks
the database aggregate is exactly two current records, three changes, and
`next_sequence = 3`. A runtime connection without request context must still see zero
records.

This boundary does not emulate a kernel socket reset, partial request-body delivery,
task cancellation while a database transaction is running, a database disconnect
mid-commit, TLS/proxy faults, HTTP/2 stream resets, or client timeout scheduling. Those
belong in a separate live fault-proxy/connection-kill gate. Random packet loss is not
added to the merge gate because it would make correctness evidence timing-dependent.

### Shared Swift and Apple platform gate

```sh
swift test --package-path CorePackage

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme Snippets \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/snippets-macos-derived \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iOS' \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/snippets-ios-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the `Snippets iOS` unit and UI suites on both an available iPhone simulator and an
iPad simulator using the commands in `AGENTS.md`. UI tests must retain
`--ui-testing-reset`; no test may point `SNIPPETS_SUPPORT_DIR` at the user's live support
directory. A shared-core change is not green when only one Apple target builds.

### Android platform gate

Use Android Studio's bundled JBR and the repository's supported emulator API:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:testDebugUnitTest :app:connectedDebugAndroidTest
```

This gate includes the Swift-for-Android cross-build/bridge verification, Kotlin unit
tests, encrypted storage, Process Text, and instrumentation smoke tests. Run the same
instrumentation suite on a physical device for a release candidate. Android does not
access CloudKit; compatibility is proved by opening the same encrypted HTTP records and
portable key material as the Apple clients.

## Provider and platform matrix

| Platform | Local-only | iCloud | Snippets Cloud | Switch coverage |
|---|---:|---:|---:|---|
| macOS | required | required | required | iCloud → Cloud → iCloud, including offline local edits |
| iPhone | required | required | required | iCloud → Cloud → iCloud; foreground/background and clean install |
| iPad | required | required | required | same provider cases plus split-view/editor UI smoke |
| Android emulator | required | not applicable | required | local → Cloud, account change, server/scope review |
| Android physical device | release | not applicable | release | clean install, Keystore loss/reimport, background/network transitions |

The Apple iCloud implementation remains its own regression surface. “Compatible” does
not mean routing Android through iCloud or replacing CloudKit. It means both providers
carry the same logical `id`, `rev`, tombstone, encrypted `blob`, merge semantics, and
portable library key, so an explicit Apple-side switch does not transform user data.

Provider tests must include ordinary and secure snippets, tombstones, tags, pin/enabled
state, conflicting edits, an offline journal, and an account/scope mismatch. Tests that
exercise switching use fake transports for deterministic failure injection; the release
gate repeats the happy path against real staging providers.

## Live four-sided compatibility gate

Use a disposable PostgreSQL database, OIDC issuer, server instance, identity subject,
and initially empty space. The public API and JWKS endpoints must use HTTPS. The local
OIDC fixture under `server/Scripts` serves HTTP only and therefore needs a trusted test
TLS edge; weakening the server's HTTPS validation or an app's cleartext policy is not a
test setup.

All clients receive the same four values through ephemeral test configuration:

```text
SNIPPETS server HTTPS origin
short-lived OIDC access token for subject A
disposable empty space UUID
portable sync-v1 test key bundle
```

Execute the gate in this order:

1. Apply migrations, start the API, verify readiness/discovery, and create one empty
   space for subject A. Prove subject B cannot resolve it.
2. Run the macOS/shared-Swift live transport test first. It asserts the space is empty,
   uploads a deterministic Apple-core encrypted record, reads it back, and confirms the
   server response does not contain its plaintext probe.
3. On a clean iPhone or iPad test sandbox, import the same portable key, download and
   open the Apple record, upload an iOS-authored record, and sync again after foreground
   and relaunch.
4. Run Android's opt-in `CloudEndToEndTest` against the same space. It downloads the
   Apple/iOS records, uploads an Android-authored record, deletes app files and the local
   Keystore wrapping key, reimports only the portable key, and opens the records again.
5. Sync the macOS and iOS app sandboxes again and open the Android-authored record. Make
   a conflicting/offline edit on one Apple client and require deterministic convergence
   on all three platforms.
6. Inspect only aggregate database facts: expected row counts and byte lengths, enabled
   and forced RLS on every protected table, the runtime role flags, and zero visible rows
   without `app.user_id`. Never print IDs, blobs, token claims, keys, or plaintext.
7. Generate a fresh short-lived token for long phases. Verify expired, wrong-audience,
   and subject-B tokens fail closed; never relax token lifetime for the test.
8. Tear down the API/OIDC edge and database volume. The gate is destructive to its app
   sandboxes and must never use a production token, space, app data container, or iCloud
   library.

The current Apple-core live seed and Android reset test are opt-in because they mutate
the remote space. Their integrated-branch commands are:

```sh
SNIPPETS_CLOUD_E2E=1 \
SNIPPETS_CLOUD_E2E_SERVER_URL='https://sync-test.example' \
SNIPPETS_CLOUD_E2E_ACCESS_TOKEN='<ephemeral-test-token>' \
SNIPPETS_CLOUD_E2E_SPACE_ID='<disposable-space-uuid>' \
swift test --package-path CorePackage --filter liveHTTPSService

./gradlew :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.khm.snippets.android.CloudEndToEndTest \
  -Pandroid.testInstrumentationRunnerArguments.snippetsServerUrl='https://sync-test.example' \
  -Pandroid.testInstrumentationRunnerArguments.snippetsAccessToken='<ephemeral-test-token>' \
  -Pandroid.testInstrumentationRunnerArguments.snippetsSpaceId='<disposable-space-uuid>'
```

Command-line arguments can be visible to local process inspection and CI diagnostics.
Use only a single-space, short-lived test token, mask it in CI, disable command tracing,
and generate a replacement immediately before each long-running platform phase.

## Failure and recovery matrix

The following scenarios are required before a release and should move into deterministic
nightly automation as harnesses become available:

| Failure | Required observation | Current automated coverage |
|---|---|---|
| Response lost after server commit | Retry does not duplicate a change; CAS resolves from the authoritative record. | Fast in-memory plus gated HTTP/PostgreSQL deterministic discard-and-redeliver tests. |
| Delta response lost after read | Reusing the old cursor reproduces the ordered page; advancing the returned cursor does not replay a rejected CAS retry. | Fast in-memory semantic equality plus gated byte-identical HTTP/PostgreSQL response replay. |
| Partial batch conflict | Independent accepted items remain durable and positional outcomes align with inputs. | Fast domain test plus gated reversed-lock-order HTTP/PostgreSQL redelivery test. |
| Tampered/foreign cursor or record version | Closed error; no row, scope, or instance information leaks. | Fast opaque-token, memory-store, and HTTP tests. |
| Database restore to older data | Operator rotation produces `dataset_reset`; clients stop for review before applying stale intent. | Gated PostgreSQL store test; client review remains a live/platform gate. |
| Server unavailable during local edit | Journaled intent remains local and later uploads exactly once. iCloud remains usable when selected. | Client fault-transport tests and live gate required; server durability tests cannot prove local journaling. |
| OIDC expiry/JWKS rotation/outage | Existing local data remains usable; network operation fails closed and recovers after reauthentication. | Signed-token fast test covers exact issuer/audience/subject; expiry, rotation, and outage recovery remain to automate. |
| OIDC subject or server instance changes | Sticky account/scope review; no silent adoption of another tenant or dataset. | Fast identity/cursor binding tests plus live client-review gate. |
| iCloud account changes | Existing CloudKit binding-review behavior remains unchanged and independent from HTTP state. | Apple platform/live gate; not a server test. |
| Provider switch interrupted at each durable step | Restart resumes or rolls back without two active providers or discarded journal intent. | Deterministic client fake-transport tests and live gate required. |
| Device loses local wrapping key | Ciphertext remains unreadable until the explicit portable key/recovery flow succeeds. | Android/Apple clean-install platform and live tests. |
| Oversized, duplicate-key, compressed, or malformed request | Request is rejected before decoding/persistence and no partial hidden write occurs. | Fast HTTP tests. |

## Release evidence

For each gate retain the commit SHA, toolchain/OS version, exact command, exit status,
test counts, and sanitized failure artifacts. Live evidence also records only an
ephemeral environment label and aggregate outcome; it must not retain bearer tokens,
OIDC subjects, space/record UUIDs, ciphertext, portable keys, support-directory paths,
or stable device identifiers.

A release candidate additionally requires:

- signed-artifact entitlement inspection for macOS and iOS, including the actual
  Production CloudKit environment when Production compatibility is claimed;
- a PostgreSQL backup/restore and dataset-rotation rehearsal;
- hosted and clean self-host conformance against the same OpenAPI contract;
- migration from the oldest supported v1 server and app state;
- physical iPhone/iPad and Android clean-install/upgrade checks;
- successful iCloud-only operation before and after Snippets Cloud tests;
- no unresolved critical/high security finding or unexplained cross-platform fixture
  difference.

Performance/load, quota, retention, deletion/export, push registration, general rate
limiting, failover, and chaos coverage remain release blockers for the hosted public
service where the corresponding production capability is not yet implemented. They are
not silently waived by passing the functional matrix above.
