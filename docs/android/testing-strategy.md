# Cross-platform sync testing strategy

This document is the executable verification contract for Snippets Cloud across the
server, Android, iOS, and macOS. It complements the product design in
`provider-switching.md`: that document defines the required behavior; this one defines
where it is proved, how often it runs, and what evidence is required to release.

The strategy deliberately separates the always-disposable HTTP lane from live CloudKit.
Normal tests never contact a developer's or user's iCloud library. Live iCloud switching
is a signed, dedicated-account release lane, not something simulated by renaming a scheme
or inferred from a source entitlement.

## Objectives

The suite must prove all of the following independently:

1. Every client implements the same logical record, crypto, merge, tombstone, conflict,
   and record-size contract.
2. macOS, iOS, and Android converge through a real HTTPS service and PostgreSQL, including
   after process/local-state loss and offline edits.
3. Provider selection is single-writer, crash-safe, and reversible. Inactive iCloud or
   HTTP data remains untouched until an explicit Switch and Sync.
4. Authentication, account/space binding, application authorization, and PostgreSQL RLS
   all fail closed and cannot be bypassed by malformed or replayed requests.
5. The service and retained diagnostics never contain snippet plaintext, keys, tokens,
   recovery material, or unapproved stable identifiers.
6. A failure produces a typed retry, authentication request, or sticky review halt. It
   must never be misclassified as an empty library or successful sync.

Passing a UI smoke test or a transport mock is not sufficient evidence for these
objectives. Each safety property is assigned to the lowest deterministic layer that can
prove it, and critical boundaries are repeated in the real cross-process lane.

## Test levels and ownership

| Level | Scope | Runs | Primary evidence |
| --- | --- | --- | --- |
| L0 — static contract | OpenAPI generation diff, project/scheme validity, manifest permissions, ABI/native library inventory, migration lexer, dependency locks | Every relevant PR | No accidental protocol drift, IME/Accessibility/overlay component, missing ABI, or destructive migration |
| L1 — shared core | Canonical JSON, crypto vectors, envelopes, merge, HLC, journal, CAS, tombstones, deletion guard, account binding, fault injection and property tests | Every shared-core PR | `CorePackage` and Android shared-core tests use the canonical Swift sources |
| L2 — platform integration | Apple stores/keychains/lifecycle/UI; Android encrypted store/Keystore/JNI/Compose/Process Text; app test hosts | Every platform PR | Real platform APIs with isolated storage and no live user data |
| L3 — service integration | HTTP handlers, strict OIDC, real PostgreSQL migrations/transactions/runtime role/RLS, OpenAPI conformance | Every server PR; real-DB lane when PostgreSQL is available | Server response and database state agree under the restricted runtime role |
| L4 — disposable cross-platform E2E | Compiled macOS and iOS production object graphs, Android instrumentation, real server, OIDC, HTTPS, PostgreSQL | Sync/protocol PRs and nightly | Cross-process encrypted convergence and tenant/privacy assertions |
| L5 — provider compatibility | Signed CloudKit Development canary and pre-release Production canary with a dedicated synthetic Apple ID, plus disposable HTTP | Nightly/weekly and release candidate | iCloud -> HTTP -> iCloud logical and ciphertext compatibility without touching real libraries |
| L6 — operational resilience | Load/soak, network chaos, database backup/restore, migration upgrade/rollback, key loss, account revocation, deletion/export drill | Nightly/weekly/release | Recovery objectives, alerts, runbooks, and fail-closed client behavior |

L0-L3 should be deterministic and parallelizable. L4 owns disposable external processes
and therefore runs serially per host. L5 and L6 are credentialed or destructive within a
dedicated test environment and never run from an untrusted pull request.

## Required invariant matrix

The following table records current automated coverage. `Required lane` is the release
owner even when a cheaper layer also tests the behavior.

| Invariant | Deterministic coverage | Required lane | Current state |
| --- | --- | --- | --- |
| Apple/Android crypto and wire compatibility | Golden vectors and shared Swift codec tests | L1 + L4 | Automated |
| HTTP create, update and CAS confirmation | Transport/server tests | L3 + L4 | Automated |
| Tombstone propagation with no physical delete | Core/server tests | L3 + L4 | Automated in the extended four-way scenario |
| Fresh install fetches without authoring an empty record set | Store and engine tests | L2 + L4 | Automated on iOS and Android |
| Android Local Only offline edit returns to the same HTTP scope | Repository/instrumentation | L4 | Automated for an offline deletion |
| Missing, malformed and wrong-audience bearer tokens fail | Server auth tests | L3 + L4 | Automated |
| A second OIDC subject cannot observe another space | HTTP and RLS tests | L3 + L4 | Automated |
| Space-create idempotency replay returns the original space | Server tests | L3 + L4 | Automated |
| Runtime DB role sees no tenant rows without request context | PostgreSQL integration | L3 + L4 | Automated |
| Plaintext absent from Android files and server blobs | Storage tests and byte probes | L2 + L4 | Automated with synthetic probes |
| Provider account/scope change halts before data plane | Core fault-injection tests | L1 + L5 | Deterministic coverage; live provider lane required before release |
| Secure/vault record survives Apple/Android/HTTP round trip | Opaque secure projection tests | L1 + L4 | Partial: opaque preservation is automated; unlocked Android UX/pairing remains pending |
| iCloud -> HTTP -> iCloud preserves unchanged encrypted blobs | CloudKit adapter/core tests | L5 | Dedicated signed canary pending |
| Crash after every Switch and Sync durable phase | Journal/account reset fault injection | L1 + L5 | Core phases covered; full provider transaction crash matrix pending |
| Network loss, malformed pages and stale cursors | Transport/engine fault injection | L1 + L4/L6 | Automated through the deterministic edge |
| Duplicate delivery and reordered pages | Transport/engine fault injection | L1 + L4/L6 | Duplicate request delivery supported; multi-page reordering scenario pending |
| Database restore changes dataset generation and causes review halt | Server/client reset tests | L3 + L6 | Drill pending |
| Boundary-size, pagination and partial batch interoperability | Core/server limit tests | L3 + L4 | Server covered; multi-client boundary corpus pending |

No row may be silently changed from `pending` to `automated`: link the command/job and
the assertion that proves it. A test that only checks HTTP 200 does not prove convergence.

## Disposable four-way scenario

`scripts/test-cross-platform-sync.sh` is the L4 reference scenario. It creates a temporary
PostgreSQL cluster, owner and non-bypass runtime roles, synthetic OIDC issuer/key, local
server, one ephemeral HTTPS edge, a new user/space, and isolated client installations.
It then runs this ordered state machine:

1. macOS creates and uploads record M.
2. Fresh iOS downloads M, creates I, and uploads it.
3. Fresh Android downloads M+I, creates A, uploads it, deletes its encrypted local state
   and Keystore wrapping key, imports the portable test key again, and downloads M+I+A.
4. Fresh macOS downloads all records and edits A; fresh iOS downloads them and edits M.
5. Fresh Android, macOS, and iOS independently verify the same three-record state.
6. Android switches to Local Only, deletes I offline, and returns to the same HTTP scope.
   The deterministic edge lets the server commit its tombstone but replaces the response
   with a 503. The same Android installation then confirms the authoritative echo without
   duplicating or resurrecting the record.
7. The edge truncates one macOS change page; the transport rejects it as invalid JSON,
   retries after the one-shot rule is exhausted, and completes a full fetch. It then
   replaces one Android cursor with an invalid value and proves the documented full-
   snapshot recovery path.
8. Fresh iOS and Android installations independently verify that I remains deleted.

Between phases the script asserts server live/tombstone counts. At the end it asserts
that all nine tenant tables have enabled and forced RLS, the runtime role sees zero rows
without request context, another OIDC subject receives no space, and none of the known
plaintext probes occurs in stored blobs. It also checks missing/malformed/wrong-audience
authentication and space-create idempotency replay.

The scenario is destructive only to resources it creates. It must fail rather than run
if its fixed temporary macOS credential handoff file already exists. Cleanup removes the
temporary credentials, database, keys, logs, tunnel, server, and any emulator it started.

## Provider switching matrix

Provider switching has more states than the four-way HTTP scenario. These transitions
must be covered explicitly; a reverse transition is not implied by a forward pass.

| Source | Target | Required assertions |
| --- | --- | --- |
| Local Only | Empty HTTP | All local intent is journaled, encrypted upload succeeds, target verifies, local files remain encrypted |
| HTTP | Local Only | Scheduling and transport stop; local projection, provider state, remote rows, and keys remain |
| Local Only after offline edits | Previous HTTP | Binding is revalidated, offline create/update/delete merges, stale cursor cannot hide changes |
| iCloud | Empty HTTP | Signed CloudKit scope is resolved, same portable key/blob is used, iCloud zone remains byte-for-byte untouched |
| iCloud | Compatible non-empty HTTP | Both sides are fetched and automatically merged; conflicts/tombstones are retained |
| HTTP | Empty iCloud | Real signed environment and private user binding are resolved before upload; HTTP remains untouched |
| HTTP | Compatible non-empty iCloud | Stale iCloud state and HTTP changes merge without resealing unchanged records |
| HTTP A | HTTP B | Origin/instance/account/space state paths are isolated; source is not deleted |
| Any remote | Incompatible key/vault/account | No target write; typed sticky review; current provider and keys remain active |
| Any remote | Physically reset target | No automatic repopulation; reviewed new-space/copy flow is required |

For each successful transition, test cancellation before commit, process death at every
durable phase, a local edit invalidating preparation, target CAS conflict, token expiry,
and switching back after independent source divergence.

## Live CloudKit lane

CloudKit cannot be faithfully replaced by an HTTP mock. The L5 lane uses dedicated test
accounts and synthetic records only:

- Build and sign the actual macOS/iOS artifact. Read entitlements from that artifact and
  require the expected container, private database, APNs, keychain group, and actual
  Development or Production environment.
- Use a dedicated Apple ID whose private `SnippetLibrary` zone contains no human data.
  Never reset the shared Production environment and never use a developer's daily account.
- Start with a unique synthetic run marker and capture only counts, sizes, environment,
  and opaque run outcome. Do not print names, bodies, ciphertext, record IDs, user record
  names, tokens, key material, or stable device identifiers.
- Seed ordinary, secure, tombstone, conflict-copy and extension-bearing records in iCloud;
  switch to a disposable HTTP space; edit one record from Android; switch back to iCloud;
  and verify logical convergence plus byte identity for every unchanged encrypted blob.
- Verify the inactive provider does not change while the other is active. Then introduce
  independent divergence and prove the next explicit switch merges it.
- Run Development canaries routinely. Run a Production canary only from protected release
  infrastructure with the signed Production entitlement and synthetic private account.

A simulator reporting `Synced` is not proof of Production access. The lane records the
signed artifact's entitlements as evidence and treats an unrecognized environment as a
failure.

## Failure and chaos catalogue

Deterministic fault injection runs before slower proxy/database chaos. Every injected
failure has a required client classification:

| Failure | Required result |
| --- | --- |
| DNS/TLS/connect timeout or HTTP 5xx | Offline/retry with bounded backoff; journal and base remain |
| Token missing/expired/revoked/wrong audience | Needs authentication; no retry loop or data-plane write |
| Scope binding, server instance, account, dataset or feed mismatch | Sticky account/review halt before applying the response |
| Invalid/old cursor | Explicit full snapshot under the same verified scope; never successful empty |
| Truncated/oversized/malformed/compressed response | Reject whole response; cursor does not advance |
| Duplicate/reordered page or response replay | Idempotent application and deterministic final state |
| Stale CAS or partial batch | Fetch authoritative record, preserve offers, merge, retry only unresolved records |
| Process death before/after remote acknowledgement | Frozen journal offer survives; no lost edit or false acknowledgement |
| Local disk full/permission/fsync failure | Halt before network or before acknowledging; primary files are not partially replaced |
| Database primary loss/restore to older snapshot | New dataset generation; clients require review and never repopulate automatically |
| Clock skew | HLC ordering remains deterministic; no wall-clock last-write-wins shortcut |
| Key/vault loss or Android Keystore invalidation | Existing ciphertext is not overwritten with a newly minted incompatible key |

### Deterministic network edge

`scripts/cross-platform-tls-edge.rb` accepts an optional atomically replaced JSON plan
and a JSON state path. Every rule matches an exact HTTP method, a bounded Ruby regular
expression over path plus query, and the Nth matching request. A new `generation` resets
all counters, so unrelated readiness, JWKS, and prior-client traffic cannot move the
failure point. Invalid plans fail closed with 503 instead of silently disabling chaos.

The closed action vocabulary is:

- `return_before_upstream` — deterministic HTTP failure without a server write;
- `delay_before_upstream` — fixed delay, including a client timeout when desired;
- `forward_then_replace` — server receives/commits the request but the client receives a
  configured failure, modelling an ambiguous acknowledgement;
- `forward_then_truncate` — cut a real response after exactly N bytes;
- `repeat_upstream` — deliver the identical request two to five times while returning the
  first response;
- `rewrite_upstream_path` — replace one path/query, used for stale or foreign cursors.

The state file records only generation, rule IDs, match/trigger counts, and triggered
upstream-attempt counts. The E2E harness asserts exactly one trigger before disabling a
plan and deletes both files with the disposable run root. Unit coverage for every action
and invalid-plan fail-closed behavior is:

```sh
ruby scripts/cross-platform-tls-edge-tests.rb
```

This is deterministic failure injection, not random packet loss. Multi-page response
reordering and a real socket half-close remain separate follow-up scenarios; neither is
claimed by the current E2E lane.

## Cadence and release gates

| Cadence | Required jobs |
| --- | --- |
| Every PR | Relevant L0 checks; CorePackage; Android shared-core/Gradle compile; server unit/OpenAPI; macOS and iOS builds |
| Sync/protocol/security PR | All above plus real PostgreSQL integration and disposable four-way E2E |
| Nightly | Full iPhone/iPad/Android emulator suites, L4 deterministic proxy chaos, fuzz/property corpus, self-host conformance |
| Weekly | PostgreSQL backup/restore and migration drill, 8-24 hour soak, supported Android API/ABI/device matrix, CloudKit Development canary |
| Release candidate | Signed physical Apple/Android devices, CloudKit Production synthetic canary, clean self-host install/upgrade, deletion/export, dependency/SBOM, performance and battery budgets |

Required jobs are fail-closed. A flaky retry is recorded as a flake even if the retry
passes; repeated flakes in sync safety tests block release until classified. Credentialed
lanes may be unavailable on forks, but their latest green protected-branch evidence must
exist for a release candidate.

## Evidence, privacy, and triage

- Test roots use `SNIPPETS_SUPPORT_DIR` or platform test containers and never the live
  support directory. A fresh iOS install remains empty before its first fetch.
- Test records use unique synthetic probes. Artifacts may retain test names/counts but no
  bearer token, private key, portable key bundle, ciphertext, stable account/space/device
  ID, or arbitrary server exception.
- E2E secrets and databases use mode `0600`/`0700`, are excluded from the repository, and
  are deleted on success, failure, interrupt, and timeout.
- Retain sanitized JUnit/XCResult summaries, toolchain versions, commit IDs, OpenAPI hash,
  migration version, platform/OS model, durations, and failure classification. Raw server
  or database logs require the same privacy review as product diagnostics.
- A failure is triaged at the first violated boundary: client local state, wire codec,
  transport, HTTP authorization, transaction/CAS, or post-sync convergence. Never debug
  by printing payloads or resetting Production CloudKit.

## Commands

The repository-level commands remain in `AGENTS.md` and `README.md`. The cross-platform
reference lane is:

```sh
./scripts/test-cross-platform-sync.sh
```

The server worktree has its own OpenAPI, Swift, and PostgreSQL commands. CI should invoke
the version committed with the server rather than duplicating those commands here. A test
strategy change is complete only when both repositories describe the same protocol gates.
