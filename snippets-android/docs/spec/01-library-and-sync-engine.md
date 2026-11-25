# 01 — Library model, local persistence and sync engine (porting brief)

Scope: what a pure-Kotlin `:core` must reproduce from the Swift reference for the snippet model, local files, the provider-neutral sync engine (transport protocol, journal, base, merge, projection), the store/coordinator layer as the iOS app wires it, and the product utilities (search, placeholders, import, deep links, keyword suggestions). Crypto, vault, Git and Snippets Cloud transports are in the sibling briefs.

Conventions:
- The Swift code at commit `66e7c7f` is the authority; `docs/cloud-sync.md` supplies rationale but its status table is stale. Android behaves like `SnippetStore(configuration: .iOS)`.
- Pointers are `path:line` relative to the repository root. A bare file name such as `SyncEngine.swift:1149` means `snippets/Core/SyncEngine.swift`; `:NNN` alone continues the file named just before it.
- "Byte-exact" marks bytes another device hashes, verifies or compares. "Local" marks files only this device reads: the bar is "parses the same and round-trips its own output".
- "Observed" marks behaviour measured by running Foundation on macOS 27.2 for this brief (whitespace sets, `String.folding`, number spelling, placeholder date failures), not read from the repository. Each such fact should be re-pinned by vectors from the wave-1 Swift emitter.
- Ready-made cross-client vectors already exist in `snippets-linux/tests/fixtures/`: `swift-double-v1.tsv`, `sync-wire-v1.json`, `merge-v1.json`, `conflict-copy-v1.json` (provenance in that folder's `README.md`).

Size of the reference, for planning: engine 3,310 lines, journal 2,747 (about 1,150 of them the conflict copy-before-source dependency graph), merge 1,170, base 649, transport 704; app layer: store 2,043, coordinator 2,196, bridge 1,992 (about 1,400 of them secure conflict-copy validation), provider selection 3,642 (half of it the Snippets Cloud auth client, out of scope here).

## 1. Component map

Verdicts: PORT, PORT PARTIALLY, SKIP. Files are grouped by area; the order inside a group is roughly bottom-up.

### Model, codec, wire

#### `snippets/Core/Snippet.swift` (541 lines) — PORT
- Purpose: the nine-field `Snippet` value, keyword/tag normalisation, the canonical display order, and every storage path (`SnippetStorageLocations`, `SyncProtocolLocations`).
- Surface: `Snippet` (`:12`), `Snippet.sanitizedKeyword` (`:65`), `normalizedKeyword` (`:61`), `displayName` (`:53`), `contentFirstLine[Untruncated]` (`:445`, `:491`), `SnippetDisplayOrder.ranks/sorted` (`:88`), `SnippetTagging.normalizedTags/filterKey` (`:395`, `:426`), `Snippet.hasTag(withKey:)` (`:434`), `SnippetStorageLocations.*` (`:172`), `createAllDirectories` (`:356`), `SyncProtocolLocations.legacyICloud/http(opaqueProviderKey:)` (`:127`, `:139`), Codable with defaults (`:515`).
- Depends on: Foundation only (`CharacterSet`, `String.folding`, `Locale("en_US_POSIX")`, `UUID`, `Date`).
- Android: port all of it except `SnippetStorageSync.distributedChangeNotification` (`:108`, macOS cross-process), `usage*` paths, `AgentSkill` folder, `cloudKitSyncCheckpointFileURL`, `legacyICloud` locations (kept only as the naming reference; Android has no iCloud). Root = app-private `filesDir/SnippetsClone` (same relative layout).
- Tests: `Tests/Core/LibraryWriterTests.swift` (codec bytes), `WireTests.swift` (tag/device spellings), `ReviewRegressionTests.swift:180` (locale independence), `SnippetDisplayOrderTests.swift`, `SnippetContentPreviewTests.swift`.
#### `snippets/Core/SnippetLibraryCodec.swift` (106 lines) — PORT
- Purpose: the single encoder/decoder for `snippets.json` and the `{"snippets":[…]}` export dialect, plus the byte digest used as the local compare-and-swap token.
- Surface: `encode` (`:56`), `encodeCollection` (`:60`), `decode` (`:70`, bare array first, then collection; never Raycast), `digest(of:)` = lowercase hex SHA-256 of the file bytes (`:83`), `read(from:)` -> `(snippets, data, digest)?`, `nil` only for file-not-found (`:92`), `Failure.unreadable` (`:32`).
- Depends on: `Snippet`, SHA-256.
- Android: port. Byte-exact output is NOT required on Android (single writer, local file) but keep the same shape so a file copied between platforms decodes; see section 2.
- Tests: `LibraryWriterTests.swift:604-700` (byte identity, nine keys, both dialects, digest over bytes), `ReviewRegressionTests.swift:37,79` (missing vs unreadable).
#### `snippets/Core/SyncEnvelope.swift` (1413 lines) — PORT (plaintext half here; sealing belongs to the crypto brief)
- Purpose: `CanonicalJSON` (deterministic emitter + strict parser), `SyncEnvelope` (the ten-key record that is hashed, sealed and merged), `WireRecord` (what a transport carries), `WireCodec.seal/open`.
- Surface: `CanonicalJSON.Value/data/value` (`:75`, `:121`, `:251`), `WireIdentity` (`:592`), `SyncBlobSealing` (`:625`, default `revisionToken` = first 32 hex of the envelope hash `:651`), `WireRecord{id,rev,deleted,blob,recordVersion?}` (`:732`), `SyncEnvelope` (`:777`), `SyncEnvelope.Fields` (`:832`), `envelopeHash()` (`:1132`), `contentHash` (`:1088`), `parse` (`:1152`), `plain/secureRecord/tombstone/tombstoned` (`:1273-1350`), `plainSnippet` (`:1355`), `WireCodec` (`:1380`).
- Depends on: `HLC` (string form, `normalizedDevice`, `isCanonicalDeviceID`), `SnippetTagging`, SHA-256, `SnippetCrypto` (sealer only), `SyncRecordVersion` (SyncTransport).
- Android: port in full; this is the most interop-critical file in the area (every byte is hashed). Not on the caller's file list but the engine, merge, journal and base all store or compare envelopes.
- Tests: `Tests/Core/WireTests.swift` (suites Canonical JSON, Envelope shape, Conversions, Sealing); fixtures `snippets-linux/tests/fixtures/sync-wire-v1.json`, `swift-double-v1.tsv`.

### Clock, files, state, journal

#### `snippets/Core/HybridLogicalClock.swift` (267 lines) — PORT
- Purpose: `HLC` value (48-bit wall ms, 16-bit counter, 8-hex device) whose 26-char string form is the wire clock inside every `SyncEnvelope`; `HLCGenerator` issues strictly increasing clocks for one device.
- Surface: `HLC` `:29` (`init` `:51`, `string` `:76`, `<` `:80`, `init?(parsing:)` `:108`, `foreign(updatedAt:)` `:70`, `isCanonicalDeviceID` `:131`, `normalizedDevice` `:148`, `makeDeviceID` `:160`, `foreignDevice` `:49`); `HLCGenerator` `:173` (`send()` `:212`, `send(atLeast:)` `:217`, `stamp(updatedAt:baseHLC:)` `:242`, `observe` `:248`, `maxDriftMs` `:185`); `Date.millisecondsSince1970` `:261`.
- Depends on: Foundation only.
- Android: port all of `HLC` byte-exactly (it is hashed/encrypted wire data). Port `HLCGenerator.send/stamp`; `observe` has no production caller (only tests), port for parity. Production users: `SyncJournal.clock(after:)` (`SyncJournal.swift:2026`) and `SecureSnippetStore` (`snippets/Vault/SecureSnippetStore.swift:291`).
- Tests: `Tests/Core/ClockAndStateTests.swift:131-563`.
#### `snippets/Core/Tombstones.swift` (254 lines) — SKIP
- Purpose: `TombstoneLedger` (id -> `{hlc, deletedAt}`, 90-day horizon, `collectedThrough` floor, `recognize` verdicts) and `TombstoneFile` for `Sync/tombstones.json`.
- Surface: `Tombstone` `:13`, `TombstoneLedger` `:50`, `TombstoneFile.load/write` `:218`/`:244`.
- Depends on: `HLC`, `SyncEnvelope`, `AtomicFileWriter`, `SchemaVersionProbe`.
- Android: skip. No production code references `TombstoneLedger`/`TombstoneFile` (only `Tombstones.swift` itself and `Tests/Core/WireTests.swift`); `Sync/tombstones.json` is never written. Live tombstones are `SyncEnvelope`s with `deleted=true` kept in `SyncBase` and `SyncJournal` (`SyncEnvelope.tombstoned`, `snippets/Core/SyncEnvelope.swift:1342`). Semantics recorded in section 3 for reference only.
- Tests: `Tests/Core/WireTests.swift` (ledger cases only).
#### `snippets/Core/AtomicFileWriter.swift` (170 lines) — PORT
- Purpose: durable atomic replace: temp file in `Tmp/`, write-all, `fsync`, `rename`, `fsync` parent dir; durable unlink.
- Surface: `AtomicFileWriter.write(_:to:temporaryDirectory:permissions:directorySync:)` `:54`, `removeDurablyIfPresent` `:130`, `Failure` `:25`.
- Depends on: POSIX (`mkstemp`, `fchmod`, `fsync`, `rename`, `unlink`), `SnippetStorageLocations.tmpFolderURL` (`snippets/Core/Snippet.swift:339`).
- Android: port. Both fsyncs are protocol fences (journal-before-network, base-before-ack). The "stage outside the watched folder" reason is macOS-only, but keep `Tmp/` on the same filesystem and keep the `directorySync` test seam.
- Tests: `Tests/Core/LibraryWriterTests.swift:24-226`.
#### `snippets/Core/SyncStateFile.swift` (443 lines) — PORT PARTIALLY
- Purpose: `Sync/state.json` (device id, sticky halt, library generation, promote/demote crash marker), the halt/recovery vocabulary shown in UI, the schema probe, and the `Sync/library-quarantine` marker.
- Surface: `SyncRecoveryAction` `:9` (titles/explanations `:24-106`), `SyncState` `:121` (`currentSchemaVersion=5` `:126`, `HaltReason` `:135`, `Halt` `:243`, `RecoveryClaim` `:249`, `RecoveryContext` `:258`, `Backend` `:283`, `fresh` `:314`), `SchemaVersionProbe` `:341`, `LibraryQuarantineMarker` `:350`, `SyncStateFile.load/write` `:404`/`:431`.
- Depends on: `HLC`, `AtomicFileWriter`, storage locations.
- Android: port types, file format, probe, marker and every `HaltReason` case (legacy cases must stay decodable). `RecoveryClaim.hostName/processID/processGeneration*` exist for Mac app + CLI + second Mac; on Android fill with own pid and treat a claim from a dead process as abandoned. UI strings (`title`, `guidance`, button titles) belong in `:app` resources.
- Tests: `Tests/Core/ClockAndStateTests.swift:565-913`.
#### `snippets/Core/LibraryGeneration.swift` (388 lines) — PORT PARTIALLY
- Purpose: `LibraryWriter`, the single locked read-modify-write funnel for `snippets.json` with re-read-inside-lock CAS, no-op suppression, quarantine replacement and generation bookkeeping.
- Surface: `NSError.isFileNotFound` `:8`, `LibraryWriter.Snapshot` `:44` (`fileExisted` `:63`, `.missing` `:65`), `Outcome` `:68`, `Failure` `:86`, `read(from:)` `:106`, `update(...)` `:140`, `replaceQuarantinedPrimary(...)` `:249`, `maxAttempts=24` `:367`, `bumpGeneration` `:374`.
- Depends on: `FileGuard`, `SnippetLibraryCodec` (encode/decode/digest), `AtomicFileWriter`, `SyncStateFile`.
- Android: port `read` (missing vs unreadable vs decoded), `update` (transform receives on-disk snapshot; byte-identical result writes nothing), `replaceQuarantinedPrimary`. The recheck/confirm retry loop and `wroteWithoutLock` only defend against a second process or a replaced lock inode; with one process and an in-process mutex they never fire but are cheap to keep. Generation bump is diagnostics-only (`:369-373`).
- Tests: `Tests/Core/LibraryWriterTests.swift:439-910`.
#### `snippets/Core/LibraryTransaction.swift` (333 lines) — PORT
- Purpose: one critical section over `snippets.json` + `Vault/vault.json` for promote/demote and sync apply; orders the two writes so a crash can only duplicate a record, never lose it; leaves a crash marker in `state.json`.
- Surface: `CrashMarker` `:38`, `Contents` `:44`, `Outcome<T>` `:56`, `Failure` `:67`, `perform(...)` `:101`, `pendingMarker` `:327`, `maxAttempts=12` `:83`.
- Depends on: `FileGuard`, `LibraryWriter.read`, `VaultFile`/`VaultDocument`, `SnippetLibraryCodec`, `SyncStateFile`.
- Android: port fully; crash windows between two renames exist on any OS. Callers: `SnippetLibraryBridge` (5 sites), `SecureSnippetStore`.
- Tests: `Tests/Core/LibraryTransactionTests.swift`.
#### `snippets/Core/LibraryLock.swift` (491 lines) — SKIP (replace)
- Purpose: cross-process mutual exclusion: `flock(2)` on `Sync/library.lock` with inode revalidation, `link(2)` sentinel fallback, `FileGuard` choosing the best available.
- Surface: `LibraryLock.acquire(at:timeout:)` `:86`, `withExclusiveLock` `:197`, `SentinelLock` `:240` (`processIsAlive` `:281`, `staleAfter=30` `:248`), `FileGuard.acquire` `:454` / `Held` `:433`, `LibraryLockPolicy.isFatal` `:485`.
- Depends on: Darwin (`flock`, `link`, `proc_pidinfo`, `kill`).
- Android: skip the implementation; one process, no CLI, app-private storage. Provide `LibraryGuard.acquire(timeoutMs)` backed by a process-wide non-reentrant lock with the same contract: timeout -> `busy` (caller retries, never drops the write), never run the body unlocked. Keep it one lock for library + vault + state (`:426-430`). Revisit only if a component is given its own `android:process`.
- Tests: `Tests/Core/LibraryWriterTests.swift:227-437` (n/a on Android).
#### `snippets/Core/SyncJournal.swift` (2747 lines) — PORT
- Purpose: durable `desired`/`offered` intent per record plus the conflict copy-before-source dependency graph; decides what is pending for the transport and survives lost ACKs. About 1,150 lines are the conflict-dependency machinery, 650 lines strict Codable.
- Surface: `SyncJournal` `:19`, `Offered` `:34`, `Entry` `:56`, `ConflictRequirement` `:98`, `ConflictDependency` `:121`, `ConflictCarrierResolution` `:133`, `ConflictPrerequisiteRecovery` `:143`, API listed in section 4, `SyncJournalFile.load/write` `:2707`/`:2736`.
- Depends on: `SyncEnvelope` (`canonicalData`, `parse`, `envelopeHash`, `tombstoned`, `x`), `CanonicalJSON.Value`, `SyncBase`, `SyncRecordVersion`, `SyncPrimaryState`, `SyncMerge` conflict helpers, `HLCGenerator`.
- Android: port everything; it is provider-neutral and Git uses it unchanged. The file is local-only, so the JSON layout need not match Swift, but the embedded envelopes must be canonical bytes.
- Tests: `Tests/Core/SyncJournalTests.swift`; dependency paths in `SyncConflictDependencyTests`, `SyncEngineJournalSafetyTests` (other forks).

### Engine, transport, base

#### `snippets/Core/SyncEngine.swift` (3310 lines) — PORT
- Purpose: the one provider-neutral round reducer. Owns `base` + `journal` in memory, drives preflight → journal → push → fetch → merge → guard → apply → confirm → cursor, persists every step in a crash-safe order, and owns sticky safety halts and their typed recovery. No file or network access of its own except base/journal/state/quarantine writes.
- Surface: `SyncEngine` (`SyncEngine.swift:289`, `@MainActor final class`): `init(transport:library:sealer:device:baseURL:journalURL:stateURL:libraryQuarantineMarkerURL:quarantineFolderURL:lockURL:temporaryDirectory:stateLockTimeout:)` (`:425`), `sync(bypassingBackoff:) -> State` (`:1149`), `State` (`:308`), `state`/`onStateChange` (`:332`), `recoveryAction` (`:592`), `performRecovery(_:)` (`:654`), `halt(_:detail:)` (`:557`), `reassertPrimaryLibraryQuarantine()` (`:565`), `noteUserInitiatedDeletions`/`cancelUserInitiatedDeletions` (`:548`,`:552`), `onUserDeletionIntentsConsumed` (`:334`), `onSafetyHaltPersistenceFailure` (`:417`), `requiresTransportRestart` (`:412`), `recoveryClaimNeedsTakeover` (`:610`), `followUpRoundsAfterSettledOffers` / `productionFollowUpRounds = 2` (`:1146`,`:1141`), `now` clock injection (`:337`), `agreedBase` test seam (`:3302`), `offMainActor` (`:3063`). Library boundary: `SyncLibraryAccess` protocol (`:114`) + defaults (`:194`), `ApplyOutcome` (`:40`), `SyncPrimaryState` (`:72`), `SyncLibrarySnapshot` (`:86`), `RemoteClassification` (`:100`), `SyncEngineFailure` (`:3306`). Also `VaultDocument.recordLocalConflictInstallReceipts(for:)` (`:9`).
- Depends on: `SyncTransport`, `SyncBase`/`SyncBaseFile`, `SyncJournal`/`SyncJournalFile`, `SyncState`/`SyncStateFile`/`LibraryQuarantineMarker`/`SyncRecoveryAction` (`SyncStateFile.swift:9,135,243,350`), `FileGuard`/`SentinelLock`, `AtomicFileWriter`, `SyncMerge`/`SyncDeletionSafety` (`SyncMerge.swift:14`), `DeletionGuard`, `WireCodec`/`WireRecord`/`SyncEnvelope`/`SyncBlobSealing` (parent, `SyncEnvelope.swift:625,732,1380`), `Diagnostics` facade, `VaultDocument`/`VaultRecord` (types only).
- Android: port in full. Every provider (Git, Snippets Cloud) runs through this reducer; the conflict-dependency/secure-carrier calls cannot be dropped because Git libraries carry secure snippets. The CloudKit-flavoured strings ("iCloud …") are detail text only.
- Tests: SyncEngineTests, SyncEngineFaultInjectionTests, SyncEngineJournalSafetyTests, SyncRecordCASTests, SyncOpaqueGenerationOrderingTests, SyncAccountBindingTests, SyncRecoveryFollowUpTests, SyncConflict*Tests, `snippets-ios-tests/SyncLifecycleTests.swift`.
#### `snippets/Core/SyncTransport.swift` (704 lines) — PORT
- Purpose: the backend seam. Value types for cursors, account/dataset scope, per-record CAS tokens, fetch pages, submit results, the rejection/failure taxonomy, and the `SyncTransport` protocol with fail-closed defaults.
- Surface: `SyncCursor` (`:12`), `SyncCursorKind` (`:35`), `SyncAccountIdentity` (`:47`), `SyncDatasetIdentity` (`:128`), `SyncScopePreflight` (`:205`), `SyncRecordVersion` (`:244`), `SyncTransportEvent` (`:322`), `SyncRejection` (`:349`), `SyncTransportFailure` (`:393`), `SyncFetch` (`:428`), `SyncSubmitOutcome`/`SyncSubmitResult`/`SyncSubmission` (`:481`,`:490`,`:501`), `protocol SyncTransport` (`:546`), `SyncRoundPacing` (`:647`), protocol defaults (`:657`).
- Depends on: `WireRecord` only.
- Android: port; Git and Snippets Cloud transports implement it. `SyncCursorKind.cloudKitSyncEngine` must stay decodable-or-rejected consistently (never produced on Android).
- Tests: SyncRecordCASTests (strict codable), SyncAccountBindingTests, SyncEngineTests (custom transports inline).
#### `snippets/Core/SyncBase.swift` (649 lines) — PORT
- Purpose: the confirmed merge ancestor (`Sync/base.json`): last agreed envelope + backend record version per id, fetch cursor, scope binding, and crash fences (journal established, transport full resync, non-destructive library merge). Strict versioned codec, schemas 1…7.
- Surface: `SyncBase` (`:20`), `currentSchemaVersion = 7` (`:38`), `NonDestructiveMergeMode` (`:40`), `key(_:)` lowercase uuid (`:133`), `envelope(_:)`/`recordVersion(_:)` (`:135`,`:137`), `nonDestructiveReviewFingerprint()` (`:145`), `upgradeToCurrentSchema()` (`:166`), `record`/`recordConfirmed`/`removeRecordVersion`/`adoptCursor` (`:179`–`:203`), `pendingChanges(from:)` (`:210`), `SyncBaseFile.load/read/decode/write/encode` (`:600`–`:648`), `Outcome` (`:584`), `Bytes` (`:594`).
- Depends on: `SyncEnvelope.canonicalData()/parse/envelopeHash/tombstoned`, `SyncMerge.hasUnresolvedContentConflict`, `AtomicFileWriter`, SHA-256.
- Android: port. Schema-1…6 decode paths are needed only if an existing install's files can reach the new app (see Open questions); writers always emit schema 7.
- Tests: SyncEngineJournalSafetyTests, SyncRecordCASTests, SyncAccountBindingTests (`damagedExplicitAccountBinding…`), SyncEngineTests (`theAgreedBaseSurvivesARestart`).
#### `snippets/Core/InMemoryTransport.swift` (432 lines) — PORT (into `:core` test fixtures, optionally main)
- Purpose: complete dictionary-backed backend with sequence cursors, paging, real per-record CAS and switchable faults. It is the reference the engine is proven against.
- Surface: `InMemoryTransport` (`:34`), `Faults` (`:43`), `configure` (`:164`), `seed` (`:170`), `snapshot` (`:176`), `submittedBatches` (`:184`), `fetchAttempts` (`:189`), `localFullResetAttempts` (`:194`), `currentCursor` (`:199`), `notify` (`:205`).
- Depends on: `SyncTransport` types only.
- Android: port first; it is the precondition for porting every engine test.
- Tests: used by all engine suites; no suite of its own.
#### `snippets/Core/DeletionGuard.swift` (121 lines) — PORT
- Purpose: pure circuit breaker for unexplained remote deletions; wraps `SyncDeletionSafety` (`SyncMerge.swift:14`).
- Surface: `allowedDeletions(liveCount:)` (`:50`), `floor` (`:55`), `Refusal` (`:59`), `Decision` (`:80`), `evaluate(liveCount:deletions:)` (`:96`), `evaluate(live:deleting:)` (`:112`), `evaluate(live:incoming:)` (`:118`).
- Depends on: `SyncDeletionSafety`, `SyncEnvelope` (`deleted`, `id`).
- Android: port verbatim (about 40 lines of Kotlin).
- Tests: SyncEngineTests circuit-breaker group (`:552`–`:1103`); `SyncMergeTests` for `SyncDeletionSafety`.

### Merge, projection, secure conflicts

#### `snippets/Core/SyncMerge.swift` (1170 lines) — PORT
- Purpose: pure functions (no I/O, no wall clock). Three parts: (a) `SyncDeletionSafety`, the mass-deletion threshold and batch fingerprint; (b) the local-file three-way merge over `[Snippet]` (memory vs. `snippets.json` on disk), undo-snapshot rebase and the keyword-collision pass; (c) the cross-device three-way merge over `SyncEnvelope`, which mints plain conflict copies and secure conflict variants and owns every validator for the reserved `x` keys.
- Surface: `SyncDeletionSafety.{floor,allowedDeletions,review,facts,fingerprint}` `:14-61`; `SyncMerge.Outcome` `:93`, `payloadEquals` `:118`, `mergeLocal` `:138`, `rebaseSnapshot` `:197`, `mergeRecord` `:242`, `localOutranksRemote` `:294`, `payloadDigest` `:301`, `mergeScalar` `:345`, `mergeTags` `:363`, `mergeContent` `:419`, `deterministicUUID` `:468`, `resolveKeywordCollisions` `:523`; envelope side: `EnvelopeOutcome` `:577`, `EnvelopeFailure` `:582`, constants `:591-606`, `SecureContentConflictVariant` `:608`, `mergeEnvelopeOutcome` `:648` (strict; `mergeEnvelope` `:631` is a test-only wrapper, do not port), `makePlainContentConflictCopy` `:864`, `secureContentConflictVariants` `:947`, `hasUnknownContentConflictVersion` `:1017`, `hasUnresolvedContentConflict` `:1024`, `validateContentConflictExtensions` `:1032`, `isMatchingPlainConflictCopy` `:1073`, `conflictCopyProvenance` `:1083`/`:1105`, `matchesConflictCopyProvenance` `:1093`, `hasValidConflictCopyIdentity` `:1124`, `resolvingContentConflicts` `:1133`, `isContentConflictExtension` `:1156`. Callers: `SnippetStore.swift:202,1556,1972,2024`, `DeletionGuard.swift:51`, `SyncEngine.swift:1988,2023,3158`, `SyncJournal.swift` (13 sites), `SnippetLibraryBridge.swift`.
- Depends on: `Snippet`, `SnippetTagging.normalizedTags`/`filterKey` (`Snippet.swift:395,426`), `Snippet.displayName` (`Snippet.swift:53`), `Date.millisecondsSince1970` (`HybridLogicalClock.swift:262`), `HLC` (order, `string`, `init(parsing:)`, `isCanonicalDeviceID`), `SyncEnvelope` (`Fields`, `canonicalData`, `envelopeHash`, `contentHash`, `plainSnippet`, `.plain`), `CanonicalJSON`, SHA-256, SHA-1.
- Android: port all of it. (c) is a wire contract shared with Apple and Linux. (b) is used by the shared store's save and reload paths, so it runs on iOS too; whether a single-writer Android store still needs the memory-vs-disk merge is the store owner's call, but `rebaseSnapshot` and `payloadEquals` are needed by undo either way.
- Tests: `SyncMergeTests`, `SyncConflictCopyTests`, `SyncConflictCopyVectorTests`, `SyncConflictOrderingTests`, `SyncConflictPayloadBudgetTests`, `SyncConflictDependencyTests`, `SyncRestoredConflictCopyTests`; Rust twin `snippets-linux/src/merge.rs` + `merge_tests.rs`, `sync_conflict_tests.rs`.
#### `snippets/Core/SyncLibraryProjection.swift` (588 lines) — PORT
- Purpose: lossless translation between primary storage (`[Snippet]`, `[VaultRecord]`) and `SyncEnvelope`s. Reuses the stored envelope (HLC, origin, `x`) while every persisted field still matches, and mints a deterministic local clock only for a real edit, so apply -> project -> diff is a fixed point.
- Surface: `Failure` `:16`, `currentEnvelopes(snippets:records:deviceID:metadata:agreedBase:vaultKID:)` `:39`, `maximumRetainedCopyIdentities` `:190`, `projectionSidecar(for:replacing:)` `:205`, `vaultRecord(from:preserving:)` `:245`, `matchesExactSecurePrimary` `:433`, `matchesExactLegacyUnstampedSecurePrimary` `:445`. Callers: `SnippetLibraryBridge.swift:247,272,649,823,1599,1942`, `SecureSnippetStore.swift:418,1671,1801,1987`.
- Depends on: `SyncBase` (`envelope(_:)`, `record(_:)`, `envelopes`), `SyncEnvelope`, `VaultRecord` + `JSONValue` (vault brief), `SyncMerge` reserved-key helpers, `HLC.normalizedDevice`.
- Android: port. Required for any provider, since `snippets.json` cannot hold HLC, origin or `x`.
- Tests: `SyncLibraryProjectionTests`, `SyncRestoredConflictCopyTests` (sidecar half), `SyncSecureConflictVariantDurabilityTests`; Rust twin `projection.rs` + `projection_tests.rs`.
#### `snippets/Core/SyncSecureConflictMaterializer.swift` (254 lines) — PORT
- Purpose: with the vault key in hand, turns each secure conflict variant carried in a source envelope's `x` into an ordinary disabled `VaultRecord` under the deterministic copy id (open under source id, verify keyed hash, reseal under copy id). Pure: the caller commits the returned record array in one library transaction.
- Surface: `Failure` `:11`, `Result{records,materializedIDs,evidenceRecords}` `:18`, `provenanceExtensionKey` `:26`, `materialize` `:28`, `prepareEvidenceRecords` `:128`, `validateIncomingSecureCopy` `:156`, `validatePreparedEvidence` `:184`. Callers: `SnippetLibraryBridge.swift:787-1852`.
- Depends on: `SnippetCrypto.open/seal/contentHash`, `RecordContext(scopeID:recordID:)`, `Keyring` (crypto brief), `VaultRecord`, `SyncMerge.secureContentConflictVariants`. `import Darwin` is only for `memset_s`.
- Android: port, after the crypto and vault layers exist. Without it a locked or key-less device still syncs: variants stay opaque in `x`.
- Tests: `SyncSecureConflictMaterializationContractTests`, `SyncSecureConflictVariantDurabilityTests`, `SyncConflictPayloadBudgetTests` (last case); Rust twin `materializer*.rs`.

### Store, coordinator, bridge, provider selection

#### `snippets/SnippetStore.swift` (2043 lines) — PORT PARTIALLY
- Purpose: main-actor owner of the in-memory plaintext library (`snippets`, file order), its undo/redo, import/export, quarantine of an unreadable primary, and debounced persistence through a serial worker that does a locked read/merge/write (`LibraryWriter`). Secure snippets are never in `snippets`; only display/uniqueness views merge shells from `secureProvider`.
- Surface: `SnippetStore.Configuration.iOS` (`:272`), `ChangeSource {local, external, remoteSync}` (`:282`), `Change{source, changedIDs?}` (`:295`), `onChange` single slot (`:317`), `SnippetStoreSyncDelegate` (`:241`), `deviceID` (`:357`), `isLibraryQuarantined` (`:315`), `librarySeq` (`:375`), `WriteHealth` (`:387`), mutators `addSnippet/update/delete/deleteForUndo/restoreDeletedSnippet/duplicate/togglePinned/toggleEnabled/toggleTag/discardBlankDraft/undo/redo/begin+commitEditTransaction` (`:553`–`:873`, `:1780`–`:1860`), import/export (`:919`–`:1071`), `ImportExportError` (`:431`), sync hooks `flushPendingWrites` (`:1695`), `flushPendingWritesForSync` (`:1753`), `reloadAfterExternalWrite` (`:1662`), `coordinatedReloadDidFinish` (`:1670`), `adoptRecoveredLibraryIfPresent` (`:1115`), `finalizeRecoveredLibraryReview` (`:1130`); worker types `SnippetPersistenceRequest/Operation/Worker` (`:10`–`:231`).
- Depends on: `Snippet`, `SnippetTagging`, `SnippetStorageLocations`, `SnippetDisplayOrder` (`snippets/Core/Snippet.swift:88,172,392`), `SnippetLibraryCodec`, `SnippetImportParser`, `LibraryWriter`, `FileGuard`, `SyncMerge.mergeLocal/rebaseSnapshot`, `SyncStateFile`, `LibraryQuarantineMarker`, `AtomicFileWriter`, `SnippetLibraryProjection` (display snapshot, `snippets/Core/SnippetSearchIndex.swift:5`), `SecureSnippetProviding`, `Diagnostics`.
- Android: port everything under `Configuration.iOS` (no starter snippet, no observer). Skip `startObservingExternalChanges`, `DistributedNotificationCenter`, `DispatchSource` monitor, `begin/finishAuxiliaryStorageDirectoryCreation`, `scheduleExternalReload` (`:1862`–`:1928`). Keep `reloadFromDiskIfNeeded` (`:1941`): the bridge and secure transitions call it via `reloadAfterExternalWrite`. `WriteHealth.unlocked/contended` can only arise with another process; keep the type, expect `.healthy`.
- Tests: `snippets-ios-tests/SnippetStorePersistenceTests.swift`, `DeletionUndoTests.swift`, `SnippetDisplayOrderTests.swift`, `SyncSnapshotDurabilityTests.swift`, parts of `SnippetsIOSTests.swift` (`:113`, `:130`, `:1228`); writer-level behaviour in `Tests/Core/LibraryWriterTests.swift` (no Core test constructs the store).
#### `snippets/Sync/SyncCoordinator.swift` (2196 lines) — PORT PARTIALLY
- Purpose: owns whether sync runs: builds transport + `SyncEngine` for the selected provider, validates protocol files, handles wire-key change, serialises rounds (one at a time, coalesced replay), debounces local changes, polls, retries offline, exposes state/readiness/recovery and all user-facing status text. Off means no engine, no transport, no `base.json` (`:144`–`:162`).
- Surface: `SyncCoordinator` (`:182`); `isEnabled` (`:511`), `setEnabled` (`:614`), `startIfEnabled/start/stop` (`:634`,`:639`,`:802`), `requestSync` async (`:1024`), `syncNow` (`:1036`), `syncAfterActivation` (`:992`), `flushPendingLibraryChangeSync` (`:1009`), `pollIntervalElapsed` (`:1891`), `performRecovery` (`:1143`), `recoveryAction` (`:1230`), `withQuiescedCloudTransport` (`:852`), `reloadProviderSelection` (`:881`), `switchProvider(to:)` (`:890`), `libraryStructureChanged` (`:940`), delegate methods (`:948`–`:971`), `addStateObserver/removeStateObserver` (`:599`), `state`, `readiness` (`:542`), `canRequestManualSync` (`:582`), `requiresSyncSettingsAttention` (`:594`), `isQuiescent` (`:575`), `statusDescription` (`:1958`); enums `Readiness` (`:254`), `RequestDisposition` (`:265`), `RequestResult` (`:274`); helpers `SyncRoundRequestCoalescer` (`:8`), `SyncTriggerDebouncer` (`:41`), `SyncOfflineRetryScheduler` (`:93`).
- Depends on: `SyncEngine` (+ `State`, `productionFollowUpRounds`, `noteUserInitiatedDeletions`, `performRecovery`, `requiresTransportRestart`), `SyncTransport`/`SyncRoundPacing`/`SyncTransportEvent`, `SyncLibraryAccess`, `SyncKeyStore`, `SnippetCryptoSealer`, `SyncBackendSelectionStore`, `SyncBaseFile`, `SyncJournalFile`, `SyncStateFile`, `LibraryQuarantineMarker`, `SyncProtocolLocations`, `Diagnostics`, CryptoKit SHA-256.
- Android: port all of it except iCloud wording and `iCloudUnavailable`. `preparesKeyInBackground: true` is the iOS mode (`snippets-ios/AppEnvironment.swift:169`): keystore reads happen off the main thread before a round. DEBUG seams (`runtimeEnabledOverride`, `roundPacingOverride`, `protocolRepairBoundaryHook`) become test injection.
- Tests: `snippets-ios-tests/SyncLifecycleTests.swift` (2674 lines), `SyncSnapshotDurabilityTests.swift`, `SnippetsIOSTests.swift:707`; pacing also `snippets-cross-platform-tests/GitSyncSettingsMacTests.swift:1622`.
#### `snippets/Sync/SnippetLibraryBridge.swift` (1992 lines) — PORT (secure-conflict half with the vault wave)
- Purpose: `SyncLibraryAccess` implementation presenting `SnippetStore` + `SecureSnippetStore` to the engine as one envelope library; owns the projection sidecar `Sync/library-metadata.json`; applies merged remote envelopes to `snippets.json`/`vault.json` in one `LibraryTransaction`; classifies secure records by vault `kid`; materialises secure conflict copies.
- Surface: `currentSnapshot`/`currentSnapshotForRound` (`:80`,`:98`), `reviewRecoveredLibrary` (`:341`), `finalizeRecoveredLibraryReview` (`:354`), `classifyRemote` (`:468`), `prepareRemote` (`:535`), `applyRemote` overloads (`:723`,`:731`,`:837`), `prepareConflictCopyEvidence` (`:757`), `resolveConflictCarriers` (`:1576`), `materializeConflictPrerequisites` (`:1668`,`:1679`), `retainConflictPrerequisiteInstallReceipts` (`:375`), `liveIDs` (`:458`), `forgetSecureProjectionMetadata` (`:1974`), `libraryVault` (`:28`).
- Depends on: `SnippetStore`, `SecureSnippetStore`, `VaultDocument`, `VaultSession`, `LibraryTransaction`, `SyncLibraryProjection`, `SyncMerge` (conflict-variant helpers), `SyncSecureConflictMaterializer`, `SyncBaseFile` (sidecar codec), `SyncEnvelope`, `SyncEngine.offMainActor`, `AtomicFileWriter`.
- Android: port. Roughly 300 lines are the plain path (projection, apply, sidecar); about 1,400 lines are secure conflict-copy validation that needs the vault and crypto ports. `flushPendingEditorEdits` is a macOS editor seam; iOS passes the default no-op (`:60`).
- Tests: `snippets-ios-tests/SyncSecureConflictBridgeIntegrationTests.swift`, `SyncSecureConflictDependencyIntegrationTests.swift`, `SyncLifecycleTests.swift:183,253`, `SyncSnapshotDurabilityTests.swift`.
#### `snippets/Sync/SyncBackendSelectionStore.swift` (3642 lines) — PORT PARTIALLY (lines 353–1806 minus iCloud; 1808–3609 belong to the Snippets Cloud brief)
- Purpose: persists which provider is the one active writer and its non-secret coordinates, vends the transport and the provider's `SyncProtocolLocations`, and runs the crash-safe provider-switch receipt. The same file also holds the whole Snippets Cloud native-auth client (`SnippetsCloudNativeAuthClient`, `:1809`–`:3568`).
- Surface: `Provider` (`:354`), `GitCoordinates` (`:372`), `CloudCoordinates` (`:400`), `Failure` (`:408`), defaults keys (`:467`–`:491`), `provider` (`:650`), `syncEnabled/setSyncEnabled` (`:657`,`:664`), `availableProviders` (`:678`), `gitCoordinates` (`:701`), `storedGitToken` (`:742`), `configureGit` (`:770`), `removeGitConfiguration` (`:817`), `gitRemote` (`:833`), `gitIsReady` (`:847`), `makeTransport` (`:1402`), `protocolLocations(for:)` (`:1555`), `gitProtocolLocations` (`:1592`), `gitCacheDirectory` (`:1613`), `ProviderSwitchReceipt` (`:494`), `prepareProviderSwitch/commitPreparedProviderSwitch/completeProviderSwitch` (`:1628`,`:1648`,`:1666`), `interruptedProviderSwitch` (`:1623`), `switchConfirmation` (`:3622`), `syncsPlainText` (`:3616`).
- Depends on: `UserDefaults`, `KeychainSecretStore`, `GitSyncKeyStore`, `GitRepositoryLocation`, `GitRemote`, `GitSyncTransport`, `GitPlainCodec`, `GitSSHSupport`, `SnippetsCloudTransport`, `SnippetsCloudKeyStore`, `SyncProtocolLocations`, `AtomicFileWriter`.
- Android: provider-neutral = `Provider`, on/off, `protocolLocations`, switch receipt, `Failure`. Git-specific = `:699`–`:854`, `:1405`–`:1436`, `:1592`–`:1621`. Snippets Cloud = `:856`–`:1400`, `:1447`–`:1538`, `:1808`+. iCloud-only (skip) = `legacyICloudEnabledDefaultsKey` mirroring, `iCloudSyncAvailable`, `CloudKitTransport`, `SyncProtocolLocations.legacyICloud`.
- Tests: `snippets-ios-tests/SyncLifecycleTests.swift:73,119,151`, `SnippetsCloudSafetyTests.swift`, `SnippetsCloudNativeAuthTests.swift`, `SecureVaultProviderIsolationTests.swift`.

### Search, placeholders, import, links, settings

#### `snippets/Core/FuzzyMatch.swift` (265 lines) — PORT PARTIALLY
- Purpose: subsequence matcher over case/diacritic-folded grapheme arrays; optional optimal-alignment score with UTF-16 highlight ranges.
- Surface: `FuzzyMatch.PreparedQuery` `:15` (`isEmpty`, `extends`), `PreparedTarget` `:31`, `Workspace` `:54`, `Result{score,matched,matchedRanges:[NSRange]}` `:7`, `score(query:target:)` `:87`, `score(query:target:includingRanges:workspace:)` `:94`, `matches(query:target:)` `:176`, `matches(query:foldedTarget:)` `:190`.
- Depends on: Foundation `String.folding(options:locale:)` `:253`, `Locale.current` / `locale.language.languageCode` `:229`, `Character.isLetter` `:261`, grapheme iteration.
- Android: iOS target member (`Snippets.xcodeproj/project.pbxproj:781`) but snippets-ios only reaches `matches(query:foldedTarget:)` through the search index; no iOS call site of `score`. Must port `PreparedQuery` + both `matches`; port `score` only if the text-action picker ranks or highlights (Mac suggestion panel is its only user).
- Tests: `Tests/Core/FuzzyMatchTests.swift`; indirectly `Tests/Core/SnippetSearchIndexTests.swift:232`.
#### `snippets/Core/SnippetSearchIndex.swift` (570 lines) — PORT PARTIALLY
- Purpose: three types: `SnippetLibraryProjection` (cached display order + tag usage for the store), `SnippetSearchSnapshot`/`SnippetSearchIndex` (folded-field cache + match predicate + tag filter), `SnippetSearchPipeline` (latest-wins background worker).
- Surface: `SnippetLibraryProjection.snapshot(ordinary:secure:locale:)` `:19` → `Snapshot{sorted,tagUsage,tags,tagKeys}` `:6`; `SnippetSearchSnapshot.normalizedQuery` `:244`, `.resultsForEmptySearch(in:activeTagKeys:)` `:250`, `.evaluate` `:197` → `Evaluation{searchMatches,snippets}` `:52`; `SnippetSearchIndex.results(in:searchText:activeTagKeys:locale:)` `:359`, `.evaluate` `:368`, `.statistics` `:446`; `SnippetSearchPipeline.submit` `:501`, `.cancelPending` `:535`, `.isCurrent` `:542`.
- Depends on: `Snippet` (`displayName`, `normalizedKeyword`, `content`, `tags`, `hasTag(withKey:)`), `SnippetTagging.filterKey`, `SnippetDisplayOrder`, `FuzzyMatch`, `PreparedSubstringSearch`, `NSLock`, `DispatchQueue`.
- Android: used by both iOS list controllers (`snippets-ios/SnippetListViewController.swift:19`, `PhoneLibraryViewController.swift:66`) and by `SnippetStore` (`snippets/SnippetStore.swift:310`). Port the semantics (query normalisation, match predicate, AND tag filter, empty-query bypass, tag-usage projection). The 16 MiB byte budget, entry reuse, prefix narrowing and sequence counters are performance mechanics: replace with an immutable snapshot + conflated coroutine. Name clash warning: this `SnippetLibraryProjection` is unrelated to `SyncLibraryProjection.swift`.
- Tests: `Tests/Core/SnippetSearchIndexTests.swift`; `snippets-ios-tests/SnippetsIOSTests.swift:256`.
#### `snippets/Core/PreparedSubstringSearch.swift` (74 lines) — PORT
- Purpose: literal "contains" over already folded text with exactly Swift `String.contains` semantics (canonical equivalence, grapheme-aligned); ASCII byte fast path with a CRLF guard.
- Surface: `PreparedSubstringSearch.Query(_ foldedText:)` `:24`, `.Field(_ foldedText:)` `:37`, `Field.contains(_:)` `:52` (empty query → `false` `:53`).
- Depends on: Foundation `decomposedStringWithCanonicalMapping` `:32`, `Data.range(of:in:)` `:58`.
- Android: needed by the search predicate (iOS uses it via the index). Port the behaviour, not the storage trick: NFC both sides, substring search, accept a hit only when both ends fall on grapheme boundaries of the field.
- Tests: `Tests/Core/PreparedSubstringSearchTests.swift` (matrix asserts equality with `String.contains`).
#### `snippets/Core/PlaceholderResolver.swift` (570 lines) — PORT
- Purpose: one-pass `{…}` placeholder expansion (`clipboard`, `date`, `time`, `datetime` with format/locale/offset) for copy/expansion and a truncated preview variant; also the validity oracle used by the importer.
- Surface: `resolve(template:clipboard:now:)` `:118`, `resolveForPreview` `:126`, `containsResolvablePlaceholder(in:)` `:139`, `containsClipboardPlaceholder(in:)` `:143`, `isResolvablePlaceholder(_:)` `:158`, `completionTokens` `:102`, `completionTokensAllResolve()` `:112`.
- Depends on: `NSRegularExpression`, `DateFormatter`, `Calendar.current`, `Locale`, `Locale.availableIdentifiers`; clipboard and clock are injected closures.
- Android: iOS uses it for Copy (`snippets-ios/SnippetActionService.swift:89`, `:116`) and the editor preview (`PhoneSnippetEditorViewController.swift:858-869`, `SnippetEditorViewController.swift:967-970`). Port the parser in `:core`; inject the date renderer (android.icu in `:app`, see hazards).
- Tests: `Tests/Core/PlaceholderResolverTests.swift`.
#### `snippets/Core/RaycastPlaceholders.swift` (55 lines) — PORT
- Purpose: import-only rewrite of legacy Raycast `{date "…"}` into `{date format="…"}`, applied only when the rewritten token fully resolves.
- Surface: `RaycastPlaceholders.converted(_:)` `:30`.
- Depends on: `PlaceholderResolver.isResolvablePlaceholder` `:49`, `NSRegularExpression`.
- Android: reached on iOS through `SnippetImportParser` only (`SnippetImportParser.swift:50`, `:57`); never by `SnippetLibraryCodec`. Port with the importer.
- Tests: `Tests/Core/PlaceholderResolverTests.swift:69-189`.
#### `snippets/Core/KeywordSuggestions.swift` (241 lines) — PORT
- Purpose: `KeywordRelation` (duplicate / prefix-blocking between two folded keywords) and editor assistance: derived keyword candidates, existing-keyword references, Tab completion.
- Surface: `KeywordRelation.between(_:_:)` `:20`; `KeywordSuggestions.existingMatches(query:among:)` `:55`, `.tabCompletion(query:among:)` `:86`, `.candidates(name:contentFirstLine:)` `:119`.
- Depends on: `Snippet.sanitizedKeyword`, `SnippetTagging.filterKey` (fixed `en_US_POSIX` fold), Swift `Character`/`String` ordering.
- Android: used by both iOS editors (`PhoneSnippetEditorViewController.swift:168`, `:891`, `:938`, `:953`; `SnippetEditorViewController.swift:286`, `:995`, `:1053`, `:1067`). Port all four entry points.
- Tests: `Tests/Core/TextReplacementTests.swift:1632-1847` (suite "Keyword suggestions"; the rest of that file is Mac expansion).
#### `snippets/Core/SnippetImportParser.swift` (88 lines) — PORT
- Purpose: decode an import document off the main thread into a `PreparedSnippetImport` before the store is touched.
- Surface: `PreparedSnippetImport{snippets,snippetsPreservingExclamationPrefix,hasRaycastExclamationKeywords}` `:6`, `.snippets(preservingExclamationPrefix:)` `:11`; `SnippetImportParser.parse(_:)` `:33`; `Failure.invalidFormat` `:20`.
- Depends on: `Snippet` Decodable (default `JSONDecoder`, i.e. dates as seconds since 2001-01-01), `RaycastPlaceholders`, `Snippet.sanitizedKeyword`.
- Android: iOS path is `snippets-ios/IncomingDocumentLoader.swift:58` → review UI → `SnippetStore.importSnippets(_:options:)` (`snippets/SnippetStore.swift:951`). Port parser, loader bounds and the store preflight/upsert rules.
- Tests: `Tests/Core/SnippetImportParserTests.swift`; `snippets-ios-tests/IncomingDocumentLoaderTests.swift`.
#### `snippets/Core/SnippetDeepLink.swift` (211 lines) — PORT
- Purpose: build and parse `snippets://share?data=…` (machine-written record) and parse `snippets://new?…` (hand-written creation link).
- Surface: `SnippetDeepLink.scheme` `:34`, `canHandle(_:)` `:51`, `isCreationLink(_:)` `:65`, `url(for:isSecure:)` `:78`, `snippet(from:)` `:114`; `SnippetDeepLinkError` `:7` (6 cases with user-facing text).
- Depends on: `URLComponents`/`URLQueryItem`, `JSONEncoder(.sortedKeys)` `:93`, Base64, `Snippet.sanitizedKeyword`, `SnippetTagging.normalizedTags`.
- Android: iOS registers the scheme (`snippets-ios/Info-iOS.plist:12-14`), routes every opened URL to `IncomingSnippetLinkCoordinator` (`snippets-ios/AppDelegate.swift:170`), and builds share links in the editors/list (`SnippetListViewController.swift:446`, `SnippetEditorViewController.swift:1600`). Port parser, builder and the review-before-mutate coordinator rules.
- Tests: `Tests/Core/ReviewRegressionTests.swift:446-475`; `snippets-ios-tests/IncomingSnippetLinkCoordinatorTests.swift`. No direct round-trip/vector test exists.
#### `snippets/Core/SettingsCatalog.swift` (252 lines) — PORT PARTIALLY
- Purpose: static, UI-agnostic settings navigation model and a search over fixed product vocabulary (never user content).
- Surface: `SettingsPlatform` `:5`, `SettingsDestination` `:10`, `SettingsRowID` `:50`, `SettingsCatalog.navigationSections(for:)` `:106`, `.entries(for:)` `:137`, `.search(_:platform:)` `:143`.
- Depends on: `String.folding(…, locale: .current)` `:179` only.
- Android: iOS uses it (`snippets-ios/SettingsViewController.swift:122`, `:166`). Port the scoring/search and the iOS row set as the starting Android catalog; SF Symbol names (`:35-47`) and iCloud/Sparkle vocabulary need Android replacements.
- Tests: `Tests/Core/SettingsCatalogTests.swift`.
#### `snippets/Core/SnippetContentExposurePolicy.swift` (86 lines) — SKIP
- Purpose: closed list of ambient AppKit output surfaces and responder selectors denied while a secure body is in the editor.
- Surface: `SnippetContentExposurePolicy.permits(_:whileSecure:)` `:27`, `.permitsResponderAction(named:whileSecure:)` `:39`, `.dynamicPreviewTemplate` `:71`, `.namePlaceholderSource` `:80`.
- Depends on: nothing (pure).
- Android: not in the iOS target (no `project.pbxproj` entry; lives in the Mac-only synchronized `snippets/` group) and no snippets-ios call site. iOS enforces the same two rules inline: no preview for secure (`PhoneSnippetEditorViewController.swift:848-856`) and no body-derived keyword candidates (`:955`). Carry the rule ("secure plaintext never reaches preview, name placeholder, share, or unflagged clipboard"), not the file.
- Tests: `Tests/Core/SnippetContentExposurePolicyTests.swift`.
#### `snippets/Core/SnippetFrecency.swift` (214 lines) — SKIP
- Purpose: decay constants and comparator for usage-ranked Mac suggestion rows.
- Surface: `SnippetFrecency` constants `:14-55`, `ranks(_:before:)` `:125`, `keywordRank` `:113`, `FrecencySnapshot` `:194`.
- Depends on: `String.folding(…, .current)` `:107`, `localizedCaseInsensitiveCompare` `:132`.
- Android: not in the iOS target (no `project.pbxproj` entry) and no reference in `snippets-ios/*.swift`; iOS has no usage ranking. Skip unless the text-action picker later wants frecency.
- Tests: `Tests/Core/FrecencyRankingTests.swift`.
#### `snippets/Core/SnippetUsageDocument.swift` (421 lines) — SKIP
- Purpose: `Usage/usage.json` document (abbreviated keys, epoch-framed weights), sanitiser, join-semilattice merge and locked writer for the Mac usage store.
- Surface: `SnippetUsageRecord` `:3`, `SnippetUsageDocument` `:34` (`currentVersion = 1` `:35`).
- Depends on: `SnippetFrecency`, `SnippetStorageLocations.usageFolderURL` (`snippets/Core/Snippet.swift:206`).
- Android: Mac-only, same evidence as `SnippetFrecency.swift`. The file is device-local and never synced, so nothing on Android has to read it.
- Tests: `Tests/Core/UsageRecordingTests.swift`, `Tests/Core/FrecencyRankingTests.swift:293-345`.
#### `snippets-ios/SnippetLibraryQuery.swift` (37 lines) — PORT
- Purpose: pure "search text + active tag keys → pinned / unpinned result lists" helper.
- Surface: `SnippetLibraryQuery.results(in:searchText:activeTagKeys:)` `:12` → `Results{pinned,snippets,all,isEmpty}` `:4`.
- Depends on: `SnippetSearchSnapshot.normalizedQuery`, `.resultsForEmptySearch`, a private shared `SnippetSearchIndex` `:36`.
- Android: only the iOS unit test calls it (`snippets-ios-tests/SnippetsIOSTests.swift:256`); both list controllers inline the same steps (`PhoneLibraryViewController.swift:137-192`, `SnippetListViewController.swift:73-100`). Port it as the single ViewModel query function.
- Tests: `snippets-ios-tests/SnippetsIOSTests.swift:256-270`.

## 2. On-disk formats

### Directory layout and which files matter to other devices

Root on Apple: `<Application Support>/SnippetsClone` (`snippets/Core/Snippet.swift:187-195`); `SNIPPETS_SUPPORT_DIR` is a test-only override (`:185`). Android: same relative tree under app-private storage.

| Path (relative to root) | Owner | Byte-exact needed? | Pointer |
|---|---|---|---|
| `snippets.json` | store / `SnippetLibraryCodec` | No (local). Must parse the same; digest is over whatever bytes this device wrote | `Snippet.swift:197` |
| `Vault/vault.json` | vault (other brief) | see crypto+vault brief | `:311` |
| `Sync/state.json` | `SyncStateFile` (device HLC, generation) | No (local) | `:240` |
| `Sync/library-quarantine` | marker: primary library was quarantined | No (local) | `:249` |
| `Sync/base.json`, `Sync/journal.json`, `Sync/Quarantine/` | iCloud-era provider files | n/a on Android (no iCloud); HTTP/Git providers use the per-provider folder below | `:255`, `:262`, `:302` |
| `Sync/Providers/<32 lowercase hex>/{base.json,journal.json,Quarantine/,switch-receipt.json}` | per-provider protocol state; key must be exactly 32 chars of `[0-9a-f]` after lowercasing or `http()` returns nil | No (local), but contents embed hashed envelopes | `:139-156` |
| `Sync/provider-switch.json` | provider switch transaction | No (local) | `:268` |
| `Sync/library-metadata.json` | projection sidecar (clocks/origins/`x` that `snippets.json` cannot hold) | No (local) | `:284` |
| `Sync/tombstones.json` | dead format: `TombstoneLedger` has no production reader or writer; skip | n/a | `:288` |
| `Sync/library.lock` | zero-byte flock target, never unlinked | No | `:297` |
| `Backups/`, `Tmp/`, `Diagnostics/Logs/` | backups, mkstemp staging, logs | No | `:323-341` |
| `Usage/`, `AgentSkill/`, `Sync/cksync-checkpoint.bin` | macOS / CloudKit only | skip | `:206`, `:275`, `:352` |

`createAllDirectories` (`Snippet.swift:356-378`) creates root, `Usage`, `Sync`, `Sync/Quarantine`, `Sync/Providers`, `Vault`, `Diagnostics`, `Diagnostics/Logs`, `Backups`, `Tmp` (+`AgentSkill` on macOS only). Provider folders are created by `SyncProtocolLocations.createDirectories` with mode `0700` and iOS protection `completeUntilFirstUserAuthentication` (`:158-169`).

The only bytes in this area that other devices must reproduce exactly are (a) the canonical envelope JSON and everything derived from it (`hash`, `contentHash`, `rev`, conflict-copy fingerprints/ids, deletion-authority hashes) and (b) values other clients parse (`HLC.string`, lowercase UUIDs, origin ids). All `Sync/*.json` files are device-local: "parses the same after upgrade" is the bar, not byte equality. They still embed envelopes, so the envelope canonical form must round-trip losslessly through them.

### `snippets.json` (frozen, nine keys)

- Shape: bare JSON array of objects. Reader also accepts `{"snippets":[…]}` (`SnippetLibraryCodec.swift:70-75`: try array, then collection, else `Failure.unreadable`). Raycast dialect is deliberately not accepted here.
- Keys (all written, exactly nine, `Snippet.swift:503-540`):

| Key | JSON type | On decode | Notes |
|---|---|---|---|
| `id` | string | required | Foundation writes `UUID.uuidString` = UPPERCASE hyphenated; decoder accepts either case |
| `name` | string | required | may be empty |
| `keyword` | string | required | stored as typed; store normalises on save (`SnippetStore.swift:664`) |
| `content` | string | required | |
| `tags` | array of string | optional -> `[]` | run through `SnippetTagging.normalizedTags` on decode (`:522`) |
| `isEnabled` | bool | optional -> `true` | `:523` |
| `isPinned` | bool | optional -> `false` | `:524` |
| `createdAt` | number | optional -> now | Double, seconds since 2001-01-01T00:00:00Z (JSONEncoder default date strategy; Unix = value + 978307200) |
| `updatedAt` | number | optional -> `createdAt` | same representation (`:526`) |

- Unknown keys are ignored on decode and dropped on the next write (the reason the format is frozen, `SnippetLibraryCodec.swift:12-29`). One element missing a required key fails the whole array. Note the store itself loads through `SnippetImportParser.parse` (`snippets/SnippetStore.swift:1256-1268`), a superset that also accepts the Raycast shape; the strict codec decodes the merge ancestor (`:163`, `:1968`) and everything `LibraryWriter` reads. A file neither accepts is quarantined, never treated as empty.
- Encoder: `JSONEncoder` with `[.prettyPrinted, .sortedKeys]`, nothing else (`SnippetLibraryCodec.swift:50-54`). Observed Foundation output (pinned by `LibraryWriterTests.swift:650-667`, plus a probe on macOS 27.2): two-space indent; `"key" : value` (space on both sides of the colon); keys in ascending order; no trailing newline; `/` escaped as `\/`; `"`, `\`, `\n`, `\t` escaped, other C0 controls as `\u00XX`; non-ASCII raw UTF-8; an empty array prints as `[`, blank line, `]`; numbers use the shortest round-trip spelling with no forced fraction (`700000000`, `700000000.25`, `1e+16`).
- Pinned example (`LibraryWriterTests.swift:644-666`):
```
[
  {
    "content" : "line1\nline2\ttab\\slash",
    "createdAt" : 700000000.25,
    "id" : "00000000-0000-4000-8000-000000000001",
    "isEnabled" : true,
    "isPinned" : false,
    "keyword" : "sig",
    "name" : "Sig \"quoted\"",
    "tags" : [
      "Work"
    ],
    "updatedAt" : 700000123.5
  }
]
```
- Digest: lowercase hex SHA-256 of the exact file bytes (`SnippetLibraryCodec.swift:83`); it is the local CAS token, taken over bytes so a reformat counts as a change (`LibraryWriterTests.swift:693`).
- Missing file = empty library (`read` returns nil, `:100`); any other read error or undecodable content throws; it must never present as "no snippets" (`ReviewRegressionTests.swift:37,79`).
- Android: the Linux port does not reproduce Foundation's layout either (`serde_json::to_vec_pretty`, `snippets-linux/src/model.rs:207-223`, uppercase ids kept at `:66-71`), so matching bytes is optional. Required: same keys, Double timestamps written with a round-trip-exact printer, uppercase or lowercase UUID accepted on read, both dialects accepted, export written as `{"snippets":[…]}`.

### Canonical envelope JSON (hashed, sealed, synced: byte-exact)

Emitter rules (`snippets/Core/SyncEnvelope.swift:137-201`), all pinned by `Tests/Core/WireTests.swift:159-345`:

1. No whitespace.
2. Object keys sorted by UTF-8 bytes = Unicode code point order, NOT UTF-16 code unit order (`:166-168`; `WireTests.swift:200-208`: U+FFFD sorts before U+10000). Kotlin's `String.compareTo`/`sorted()` is UTF-16 order and is wrong for supplementary-plane keys.
3. Strings: escape only `"` -> `\"`, `\` -> `\\`, 0x08 `\b`, 0x09 `\t`, 0x0A `\n`, 0x0C `\f`, 0x0D `\r`, other bytes below 0x20 as `\u00xx` lowercase hex; `/`, DEL and all non-ASCII verbatim (`:183-198`). Input must be valid UTF-8 (overlongs and surrogates rejected, `:209-241`).
4. Integers: `Int64` decimal. Doubles: Swift `Double.description`, i.e. shortest round-trip digits; always contains `.` or `e`; fixed notation while the decimal exponent is >= -4 and |v| <= 2^53, otherwise scientific with a sign and at least two exponent digits. Examples: `0.0`, `-0.0`, `1.0`, `0.0001`, `1e-05`, `1000000000000000.0`, `9007199254740992.0`, `9.007199254740994e+15`, `1e+16`, `5e-324`. NaN/inf are an error (`:146`). The Rust port re-implements this on top of Ryu (`snippets-linux/src/canonical.rs:162-216`) and checks 11,903 reference values in `snippets-linux/tests/fixtures/swift-double-v1.tsv` (hex bit pattern, tab, expected text); reuse that file.
5. Parser (`:251-474`): strings come back as bytes; strict JSON numbers (no `+`, no leading zeros, no bare `.5`); a token with `.`/`e`/`E` is a double, otherwise Int64, falling back to double on overflow (`:469-472`; `-0` is Int 0); duplicate keys are an error (`:315`) and, because Swift `String ==` is canonical equivalence, `é` precomposed vs decomposed also counts as a duplicate (`WireTests.swift:289`; Rust mirrors it with an NFC set, `canonical.rs:114-119,320`); raw control bytes inside strings rejected (`:368`); lone surrogate escapes rejected (`:389-404`); trailing bytes rejected (`:255`); depth limit 32 (`:117`, checked as `depth <= 32` at `:275`).

Envelope object: exactly ten top-level keys (`:823-826`), `fields` exactly eight (`:834-837`):

| Key | Type | Rule |
|---|---|---|
| `schemaVersion` | int | `1` (`:779`); greater -> `Failure.tooNew` before any other check (`:1161-1166`) |
| `id` | string | lowercase UUID (`:1102`) |
| `hlc` | string | `HLC.string`, e.g. `0000000003e8-0002-aabbccdd` (`WireTests.swift:449`) |
| `origin` | string | 8 lowercase hex chars; normalised on local construction (`:1033`), rejected (not normalised) on parse (`:1194`) |
| `secure` | bool | record belongs in the vault |
| `deleted` | bool | tombstone; then `fields` and `contentHash` are `null` (`:1040`, `:1110-1115`) |
| `contentHash` | string or null | lowercase hex SHA-256 of `fields.content` bytes (`:1088`) |
| `fields` | object or null | `name`, `keyword`, `content` (strings), `tags` (array of strings), `isEnabled`, `isPinned` (bool), `createdAt`, `updatedAt` (DOUBLE seconds since 2001, always with `.`/`e`) (`:906-927`) |
| `x` | object | extension bag, preserved verbatim; known keys `vaultContentHash` (`:789`), `vaultKID` (`:806`), `userDeletion.v1` (`:819`), and `conflictCopy.v1` (merge, section 4) |
| `hash` | string | lowercase hex SHA-256 of the canonical bytes of the other nine keys (`:1132`) |

- `rev` (clear text beside the blob) = first 32 hex chars of `hash` unless the sealer overrides it (`:651`). `WireCodec.open` re-derives and compares id, deleted and rev (`:1396-1411`).
- Parse rejects: unknown top-level or `fields` key (`:1168`, `:934`), live record without `fields`, tombstone with `fields` or non-null `contentHash` (`:1230-1239`), wrong `hash`/`contentHash` (`:1245-1248`), `userDeletion.v1` unless it is an array of 1...8 unique 64-char lowercase hex strings on a tombstone (`:1208-1222`).
- Local construction normalises tags (`:876`) and origin (`:1033`) and strips `userDeletion.v1` from live records (`:1042`); parsing must bypass both normalisers so old spellings re-emit byte-for-byte (`:886-904`, `:1050-1068`; `WireTests.swift:458-474`).
- `tombstoned(hlc:origin:)` drops `x` except `vaultKID` on secure records (`:1342-1350`).
- Gold vector (`WireTests.swift:442-453`; dates are `Date(timeIntervalSince1970: 1_785_312_000)` = 807004800 s after 2001, `WireTests.swift:14`). Tags input `["  Team\n Notes  ","TEAM NOTES","Café","CAFE"," \t "]` -> `["Team Notes","Café"]`; HLC `(1000, 2, "AA-BB-CC-DD")`; origin `AB-CD-EF-01` -> `abcdef01`. The nine-key hash preimage, re-derived independently while writing this brief (SHA-256 of these UTF-8 bytes, `\n` being the two characters backslash-n, gives the pinned hash):
```
{"contentHash":"98f638839878a42acf8b855dd8284baed0029fe70963ae013a959e6341292073","deleted":false,"fields":{"content":"Best,\nMike","createdAt":807004800.0,"isEnabled":true,"isPinned":false,"keyword":"sig","name":"Signature","tags":["Team Notes","Café"],"updatedAt":807004800.0},"hlc":"0000000003e8-0002-aabbccdd","id":"00000000-0000-4000-8000-000000000000","origin":"abcdef01","schemaVersion":1,"secure":false,"x":{}}
```
  `envelopeHash` = `dbc644e2963dccd24f99ff4919e1a61b03216d80bf0459b01977c2855560ec4c`. More vectors: `snippets-linux/tests/fixtures/sync-wire-v1.json` (canonical + wire + hash for a plain and a secure record).

### Store, coordinator and selection-store files
Directory layout, created by `SnippetStorageLocations.createAllDirectories()` from `SnippetStore.init` (`snippets/SnippetStore.swift:482`, `snippets/Core/Snippet.swift:356`): `<root>/`, `Usage/`, `Sync/`, `Sync/Quarantine/`, `Sync/Providers/`, `Vault/`, `Diagnostics/`, `Diagnostics/Logs/`, `Backups/`, `Tmp/`; `AgentSkill/` is macOS only (`Snippet.swift:383`). `<root>` is `Application Support/SnippetsClone`, or `SNIPPETS_SUPPORT_DIR` in tests (`Snippet.swift:185`). Nothing but `snippets.json` (and a quarantined `snippets.json.corrupt-*`) lives directly in `<root>`. A non-iCloud provider owns `Sync/Providers/<32 lowercase hex>/` with `base.json`, `journal.json`, `Quarantine/`, `switch-receipt.json`, plus Git's `GitCache/`; folders are mode `0700` (`Snippet.swift:139`–`169`, `snippets/Sync/SyncBackendSelectionStore.swift:1613`). `Sync/state.json`, `Sync/library.lock`, `Sync/library-quarantine`, `Sync/library-metadata.json` and `Sync/provider-switch.json` are shared by all providers.

| File | Read/written by | Content and rules | Interop |
|---|---|---|---|
| `snippets.json` | Load: `SnippetStore.load` (`SnippetStore.swift:1073`) decodes through `SnippetImportParser.parse(data).snippets(preservingExclamationPrefix: false)` (`:1256`–`1268`), not through `SnippetLibraryCodec.decode`; the merge ancestor is decoded with `SnippetLibraryCodec.decode` and falls back to `[]` (`:162`, `:1968`). Save: worker → `LibraryWriter.update(libraryURL, stateURL, lockURL, temporaryDirectory: Tmp, lockTimeout, expectedDigest)` (`:182`). | Inside the lock: digest unchanged → write memory; file missing → write memory (`recreatedMissingFile` when a digest was expected); otherwise write `SyncMerge.mergeLocal(base: ancestor, local: memory, remote: onDisk)` (`:189`–`210`). Missing file at launch on iOS → empty library, nothing written (`:1086`). | Local on Android; parse-compatible is enough, but keep the codec's bytes so the digest/ancestor logic and vectors match. |
| Export file (user-chosen) | `exportSnippets(to:)` (`:1059`) | `{"snippets":[…]}`, `JSONEncoder` `[.prettyPrinted, .sortedKeys]` (`:475`), plaintext snippets only, `Data.write(.atomic)`. | Must import on Mac/iOS/Linux: parse-compatible with `SnippetImportParser`. |
| `Backups/pre-sync-<yyyyMMdd-HHmmss>.json` | `seedFirstRunBackupIfNeeded` (`:523`) | Byte copy of `snippets.json`, once, if no `pre-sync-*` exists and the library exists. Timestamp: `en_US_POSIX`, local time zone. | Local. |
| `Backups/unsaved-<ts>.json` | `flushPendingWrites` (`:1720`–`1740`) | `SnippetLibraryCodec.encode` (bare array) via `AtomicFileWriter`, only after 3 failed locked writes at background/terminate. Never read back by code. | Local. |
| `<root>/snippets.json.corrupt-<ts>` | `quarantineUnreadableLibrary` (`:1139`–`1234`) | The unreadable primary, moved (not copied) after the marker and halt are durable. | Local. |
| `Sync/library-quarantine` | Written by the store (`:1176`), removed by the engine's recovery | Lowercase UUID + `\n`; existing valid marker is kept (`snippets/Core/SyncStateFile.swift:361`–`384`). | Local. |
| `Sync/state.json` | Store reads `deviceID` (`:499`–`515`; `.fresh` is written back, `.tooNew` → random id for the session, no write) and writes `halt = {reason: localLibraryQuarantined, detail, at: now floored to whole seconds, recoveryContext: localLibraryQuarantine}` (`:1199`–`1206`) | Format owned by `SyncStateFile`. | Local. |
| `Sync/library-metadata.json` | `SnippetLibraryBridge` (`snippets/Sync/SnippetLibraryBridge.swift:58`, `:1912`–`1967`) | The local projection: `SyncBase` file encoding with a nil cursor. Re-read on every projection; rewritten only when changed; best effort (`:322`–`335`) except strict in `resolveConflictCarriers` (`:1642`). `tooNew` → halt `schemaTooNew`; unreadable → halt `localLibraryQuarantined` (`:217`–`227`). | Local, derived. |
| `Sync/provider-switch.json` and `<provider folder>/switch-receipt.json` | `SyncBackendSelectionStore` (`:1791`–`1804`, `:1659`) | Exactly the keys `schemaVersion` (Int, 1), `id` (UUID string), `source`, `target` (`"icloud"`/`"snippets-cloud"`/`"git"`), `sourceLocationID`, `targetLocationID` (non-empty), `phase` (`"prepared"`/`"targetSelected"`); pretty-printed, sorted keys, `AtomicFileWriter`. Any other key set, version, or `source == target` → unreadable (`:1774`–`1789`). | Local. |
| Git token (Keychain; Android Keystore-backed store) | `configureGit`/`storedGitToken` (`:727`–`813`) | JSON, exact keys `schemaVersion` (1), `location` (= `repository.spec`), `username`, `token`; ≤ 8192 bytes; returned only when `location` and `username` equal the configured coordinates. Service `com.khm.snippets.git-sync.credentials`, account `git-access-token-v1`, device-only (`:486`, `:545`). Deleted when SSH is configured (`:790`). | Local. |

Unreadable-library rule (`SnippetStore.swift:1091`–`1107`, `:1139`–`1234`): decode failure at launch → memory becomes `[]`, `isLibraryQuarantined = true`; then, under `Sync/library.lock` (0.25 s): re-read (a repaired file is adopted), write the marker, write the halt into `state.json`, move the file aside. Each step that fails stops the sequence with the in-memory quarantine still set. With no primary file, the library is treated as quarantined when the marker exists, the persisted halt has `recoveryContext == localLibraryQuarantine`, or `state.json` is `tooNew` (`:1074`–`1080`, `:1236`–`1247`). While quarantined every mutator is a no-op or throws `libraryRecoveryRequired`, and `persist` refuses to write (`:1391`).

Preferences (`UserDefaults.standard`; Android: one `SharedPreferences`, written with `commit()` where Swift checks `synchronize()`). All are local; none is synced.

| Key | Type | Absent means | Meaning / pointer |
|---|---|---|---|
| `SnippetsSyncEnabled` | Bool | falls back to `SnippetsICloudSyncEnabled` | Provider-independent on/off (`SyncBackendSelectionStore.swift:470`, `:657`; `SyncCoordinator.swift:511`). Migrated from the legacy key at init (`:1681`). |
| `SnippetsICloudSyncEnabled` | Bool | false | Legacy downgrade mirror, true only for enabled iCloud (`:471`, `:664`–`676`, `:1714`). Not needed on Android. |
| `SnippetsSyncProvider` | String | `icloud` (`:650`) | `icloud`, `snippets-cloud`, `git`. An unrecognised value sets `invalidProviderSelection` and no transport starts (`:1727`). |
| `SnippetsSyncProviderSwitchPending` | — | — | Removed at every init (`:474`, `:571`). |
| `SnippetsGitSyncRepositoryURL`, `…Branch`, `…Username`, `…DatasetID`, `SnippetsGitSyncMode` | String | Git not configured | Repository spec must re-parse to the same string; username absent for SSH; dataset id lowercase UUID; mode raw value, absent → encrypted (`:481`–`485`, `:701`–`722`, `:803`–`812`). |
| `SnippetsCloudServerURL`, `SnippetsCloudAPIBaseURL`, `SnippetsCloudSpaceID`, `SnippetsCloudServerInstanceID`, `SnippetsCloudProtocolMajor` | String ×4, Int | Cloud not configured | API base must equal server + `/v2`, protocol must be 2 (`:475`–`479`, `:973`–`982`, `:1477`–`1486`). |
| `SnippetsSyncWireKeyFingerprint` (iCloud) / `SnippetsSyncWireKeyFingerprint.<locations.identifier>` | String | first run or pre-fingerprint install | 16 hex chars = first 8 bytes of SHA-256 over the wire key material; a mismatch resets the agreed base (`SyncCoordinator.swift:1295`, `:1494`–`1697`). |
| Info.plist `SnippetsCloudEnabled`, `SnippetsCloudBaseURL` | build setting | off | Snippets Cloud dark-launch gate and pinned server (`SyncBackendSelectionStore.swift:108`, `:1389`). Android: build flag. |

The UI deletion intents (`pendingUserDeletionIDs`, `SyncCoordinator.swift:296`), deletion-undo tokens and undo stacks are process memory only.

### Local encoder conventions (state, journal)
- All three writers use `JSONEncoder` with `[.prettyPrinted, .sortedKeys]` and `.iso8601` dates (`SyncStateFile.swift:438-441`, `SyncJournal.swift:2741-2745`, `Tombstones.swift:249-252`): keys sorted, two-space indent, `"key" : value`, `/` escaped as `\/` (no `.withoutEscapingSlashes`), `nil` optionals omitted, `Date` = `yyyy-MM-dd'T'HH:mm:ss'Z'` UTC whole seconds (pinned at `Tests/Core/ClockAndStateTests.swift:604-605`), `UUID` = uppercase string, `Data` = standard padded base64, `UInt64` = JSON integer.
- Interop: none of these files leaves the device. A Kotlin port needs "parses the same and round-trips its own output", not byte equality. The exception is content inside them: journal strings are base64 of canonical `SyncEnvelope` bytes, and `hlc` strings are wire values.
- Every load probes `{"schemaVersion": Int?}` first with a lenient decoder (`SyncStateFile.swift:341`); a version above the build's maximum returns `tooNew` and the file must never be rewritten.

### AtomicFileWriter algorithm (`snippets/Core/AtomicFileWriter.swift:54-122`)
1. `mkdir -p temporaryDirectory` (errors ignored). 2. `mkstemp("<tmp>/<destination file name>.XXXXXX")`; failure -> `cannotCreateTemporary`. 3. `fchmod(fd, 0o600)` (default `permissions`). 4. Write all bytes, looping on short writes, retrying `EINTR` (`:156-169`). 5. `fsync(fd)`; failure -> `writeFailed`; close. 6. `rename(tmp, dest)`. On `EXDEV` with a staging dir different from the parent: retry the whole write staged in the destination's parent (`:100-110`); other errors -> `renameFailed`. Any failure after step 2 unlinks the temp file (`:76-77`). 7. `open(parent, O_RDONLY|O_CLOEXEC)` + `fsync` (`:143-152`); failure -> `directorySyncFailed` thrown after the rename already landed (pinned `Tests/Core/LibraryWriterTests.swift:158`).
- `removeDurablyIfPresent` (`:130-139`): `unlink`; `ENOENT` is success; always fsync the parent afterwards.
- Result file mode is 0600 even over an existing wider file (`LibraryWriterTests.swift:111`). Directories are created by `SnippetStorageLocations.createAllDirectories` (`snippets/Core/Snippet.swift:356`); provider dirs get 0700 (`Snippet.swift:157-160`).

### `Sync/state.json` (`SyncState`, schema 5, `snippets/Core/SyncStateFile.swift:121-330`)
| key | type | req | notes |
|---|---|---|---|
| `schemaVersion` | int | yes | always rewritten as 5 (`:437`). 4 added the quarantine marker, 5 the recovery claim (`:123-126`) |
| `deviceID` | string | yes | 8 lowercase hex, minted once (`HLC.makeDeviceID`) |
| `hlc` | string | yes | HLC string form |
| `generation` | uint64 | yes | library write counter |
| `librarySHA256` | string | no | digest of the `snippets.json` bytes that produced `generation` |
| `scopeID` | string | yes | lowercase UUID; protocol scope, never crypto scope (`:297-304`) |
| `backend` | string | yes | `none` / `icloud` / `s3` / `http` (`:283`) |
| `cursor` | string | no | |
| `lastSyncAt` | ISO date | no | |
| `halt` | object | no | `reason` (string enum), `detail` (string), `at` (ISO date), optional `recoveryContext`, optional `recoveryClaim` |
| `promoting`, `demoting` | UUID string | no | crash marker written by `LibraryTransaction` |
- `halt.reason` raw values (`:135-173`): `massDeletion`, `backendRefused` (legacy sticky), `accountChanged`, `checkpointUnreadable`, `remoteDataReset`, `manifestIntegrityFailed` (never raised, decode-only), `localLibraryQuarantined`, `vaultUnreadable`, `schemaTooNew`.
- `halt.recoveryContext` is a synthesized enum-with-payload: `{"massDeletion":{"liveCount":Int,"requestedDeletions":Int,"batchFingerprint":String}}` or `{"localLibraryQuarantine":{}}` (`:258-266`).
- `halt.recoveryClaim`: `id`, `ownerID` (UUID), `hostName` (string), `processID` (int32), optional `processGenerationSeconds`, `processGenerationMicroseconds` (uint64) (`:249-256`).
- Load (`:404-422`): unreadable or undecodable file -> `fresh` (new random device id, `generation 0`, `backend none`, no halt); newer schema -> `tooNew`; no migration code, older schemas decode because every added key is optional. Consequence: an unknown `reason` string makes the file undecodable and silently clears a sticky halt, so no case may be dropped (`:158-164`).
- Writers: `SnippetStore.adoptDeviceIdentity` (persists a fresh state, `snippets/SnippetStore.swift:500-505`), `SnippetStore.quarantineUnreadableLibrary` (marker first, then a `localLibraryQuarantined` halt with `at` floored to whole seconds, under the lock, `snippets/SnippetStore.swift:1139-1206`), `LibraryWriter.bumpGeneration`, `LibraryTransaction.writeMarker`, `SyncEngine.updatePersistedHalt` (under the library lock, CAS on the previous halt, refuses when unlocked, `snippets/Core/SyncEngine.swift:3225-3293`). All are load-modify-write of the whole file; best-effort except the halt write.

### `Sync/library-quarantine` (`snippets/Core/SyncStateFile.swift:350-391`)
- Plain text: lowercase UUID + `\n`. Existence is the fact "an unreadable `snippets.json` was moved aside"; the UUID is the review id. `write` is idempotent and returns the existing id if the file parses (`:366`); a file whose content is not a canonical UUID reads as `nil` id but still "exists". Written atomically before the bad library is moved; removed with `removeDurablyIfPresent` only after `base.json` carries the same review id (`:345-349`).

### `<protocol folder>/journal.json` (`SyncJournal`, schema 5, `snippets/Core/SyncJournal.swift:2057-2747`)
- Path: `Sync/journal.json` for the legacy iCloud locations, `Sync/Providers/<32 lowercase hex>/journal.json` for every other provider (`snippets/Core/Snippet.swift:127-152`, `:262`).
- Top level (unknown keys rejected, `:2214-2221`): `schemaVersion` int 1...5 required; `entries` object required (missing or `null` is unreadable, never empty, `:2230-2233`); `conflictDependencies` object required for schema >= 2, forbidden in schema 1; `reviewedRecoveryFingerprint` optional 64 lowercase hex, schema >= 5 only.
- `entries[<lowercase uuid>]` (`StoredEntry` `:2092`): `desired` base64(canonical envelope), required, its id must equal the key; `generation` uint64 > 0; `modifiedAt` JSON double = seconds since 2001-01-01 UTC (`timeIntervalSinceReferenceDate`, `:2103`, `:2582`); `offered` optional `{envelope: base64, generation: uint64 (>0, <= entry generation), recordVersion?: SyncRecordVersion}` (`:2062`); `reviewedLocalExistence` bool, required when schema >= 4 and must equal `reviewedLocalSnapshotKnown && reviewedLocalAncestor != nil` (`:2337-2345`, `:2367`); `reviewedLocalAncestor` optional base64 live envelope with the same id; `reviewedLocalSnapshotKnown` bool required when schema >= 5; `preReviewMergeAncestor` optional base64 envelope, schema >= 5.
- `conflictDependencies[<source uuid lc>]` (`StoredDependency` `:2184`): `sourceSnapshot` base64 envelope (id == key), `requirements` non-empty object, optional `sourceOffered` (must carry no unresolved content-conflict extension, `:2410-2417`).
- `requirements[<fingerprint 64 lc hex>]` (`StoredRequirement` `:2143`): `copyID` lowercase UUID that must equal `SyncMerge.deterministicUUID(namespace: source.id, name: "sync-content-conflict-v1|<fingerprint>")` and be unique across the file (`:2423-2428`); `fingerprint` == key; `carrierKey` + `carrierValue` both present or both absent, key must be `"contentConflict.v1." + fingerprint`, value = base64(canonical JSON) equal to `source.x[carrierKey]` (`:2449-2463`); `snapshot` optional base64 envelope; `offered` optional; `acceptedRecordVersion` optional (schema >= 3).
- Cross-field invariants enforced at decode (`:2483-2514`): snapshot/offered are live and match copy provenance; `offered` requires `snapshot` and equal hash; a requirement has a snapshot or a carrier; `acceptedRecordVersion` requires `snapshot`; the set of `contentConflict.v1.*` keys in the source snapshot equals the set of active carrier keys.
- Migration: any schema < 5 loads with `needsDependencyMigration = true` and in-memory `schemaVersion = 5` (`:2375-2388`, `:2521-2524`); `encode` throws until `reconcileDependencies` has run (`:2528-2534`), so the first engine round rewrites it as 5 and that write is the downgrade fence.
- Load outcomes (`:2707-2734`): no file -> `missing(empty journal)`; read error -> `unreadable`; future schema -> `tooNew`; any decode or invariant failure -> `unreadable`. No quarantine or regeneration: the engine halts (journal missing while `base.json` says one was established also halts, `snippets/Core/SyncEngine.swift:520-525`).
- Write: whole document through `AtomicFileWriter`; the engine writes only when the candidate differs from the in-memory journal or the file is absent, and publishes the in-memory value after durability (`SyncEngine.swift:3070-3078`). Output is deterministic regardless of dictionary order (`Tests/Core/SyncJournalTests.swift:986`).

### `snippets.json` writers owned by this area
- `LibraryWriter.update` and `LibraryTransaction.perform` both write `SnippetLibraryCodec.encode` bytes through `AtomicFileWriter` (0600). Digest = `SnippetLibraryCodec.digest(of: bytes)` (over bytes, so a reformat counts as a change; `LibraryWriterTests.swift:693`). Missing file digest is `""` (`LibraryGeneration.swift:65`).
- `snippets.json.recovery-preserved-<lowercase uuid>` beside the library: byte copy of an unreadable primary, written and read back for equality before the replacement is published (`LibraryGeneration.swift:290-307`). Never deleted by this code.

### `Sync/library.lock`, `Sync/library.lock.sentinel`, `.lock-<pid>-<u32>`
- Zero-byte `flock` target created `O_RDONLY|O_CREAT`, 0600, never truncated or replaced (`LibraryLock.swift:103`). Sentinel fallback: unique file `.lock-<pid>-<random u32>` hard-linked to `library.lock.sentinel`; content `hostName\npid\n[startSec\nstartUsec\n]` (`:316-343`, `:466`). Android does not create these.

### `Sync/tombstones.json` (dead format, `snippets/Core/Tombstones.swift:50-254`)
- `{schemaVersion: 1, entries: {<lowercase uuid>: {hlc: string, deletedAt: ISO date}}, collectedThrough?: ISO date}`. Missing -> empty ledger; unreadable/undecodable -> `unreadable` (halt, never start over); newer -> `tooNew`. Not written by any production path.

### `Sync/base.json` (confirmed ancestor; one per provider)
- Path: iCloud legacy `Sync/base.json` (`Snippet.swift:255`); every other provider `Sync/Providers/<32 lowercase hex>/base.json`, beside `journal.json` and `Quarantine/` (`Snippet.swift:138-155`). Folders 0700 (`Snippet.swift:157-161`). The engine derives `journal.json` as a sibling of `baseURL` when not given (`SyncEngine.swift:444`).
- Interop: purely device-local. Never uploaded, hashed across devices or compared with another client: "parses the same" is sufficient. Byte-exact parts are only the embedded canonical envelope bytes (owned by `SyncEnvelope.canonicalData()`), because their hash is the merge identity.
- Encoder (`SyncBase.swift:643-648`): `JSONEncoder`, `outputFormatting = [.prettyPrinted, .sortedKeys]`, `dateEncodingStrategy = .iso8601` (no `Date` field exists today). No `.withoutEscapingSlashes`, so `/` inside base64 is written `\/`; Apple pretty-printing writes `"key" : value`. A Kotlin reader must accept both; a Kotlin writer may use any valid JSON.
- Write: `AtomicFileWriter.write` (temp file in `Tmp/`, fsync, rename, directory fsync; mode 0600) (`SyncBase.swift:634-640`, `AtomicFileWriter.swift:54-58`).
- Top-level object is a closed key set: any unknown key makes the file unreadable (`SyncBase.swift:257-264`).

| Key | Type | Presence rules (decode) | Pointer |
|---|---|---|---|
| `schemaVersion` | int 1…7 | required; `> 7` → `tooNew` (probed first, `:621-624`); outside 1…7 → unreadable | `:266-272` |
| `envelopes` | object: lowercase-uuid → base64 (standard, padded) of canonical envelope bytes | required; every value must base64-decode, `SyncEnvelope.parse`, and its id must equal the key, else whole file unreadable | `:381-397`, `:565-569` |
| `recordVersions` | object: lowercase-uuid → `{"schemaVersion":1,"data":"<base64>"}` | optional (absent = `{}`); explicit `null` fails; key must be a canonical lowercase UUID; an entry may exist without an envelope | `:458-472` |
| `cursor` | string (opaque) | optional (`decodeIfPresent`) | `:273` |
| `cursorKind` | `"legacy"` \| `"cloudKitSyncEngine"` | schema ≥ 3: present iff `cursor` present; schema < 3: must be absent (implied `legacy`) | `:274-291` |
| `journalEstablished` | bool | optional → `false`; `null` fails; always written | `:295-299`, `:544` |
| `accountIdentity` | `{"schemaVersion":1,"data":"<base64, 1…1024 bytes>"}` | optional; `null` fails; forbidden when schema < 2; omitted when nil | `:304-314` |
| `datasetIdentity` | same shape | optional; forbidden when schema < 4; written only when schema ≥ 4 | `:315-325`, `:546-548` |
| `requiresTransportFullResync` | bool | optional → `false`; `true` forbidden when schema < 3; written when schema ≥ 3 | `:326-336` |
| `requiresNonDestructiveLibraryMerge` | bool | REQUIRED when schema ≥ 4; `true` forbidden when schema < 4 | `:337-356` |
| `nonDestructiveMergeMode` | `"incompletePrimary"` \| `"reviewedLocalSnapshot"` | schema ≥ 5: present iff the fence is `true`; schema < 5: must be absent (fence implies `incompletePrimary`) | `:357-379` |
| `preRecoveryConfirmedEnvelopes` | object like `envelopes` | schema ≥ 6 only, and only with fence + `reviewedLocalSnapshot`; absent = nil (unknown), `{}` = known-empty | `:399-431` |
| `nonDestructiveReviewID` | UUID string (Foundation writes uppercase) | schema ≥ 7: present iff fence + `reviewedLocalSnapshot`; schema < 7: must be absent | `:433-452` |

- Nested `SyncAccountIdentity`, `SyncDatasetIdentity`, `SyncRecordVersion`: exactly the keys `schemaVersion` and `data`, `schemaVersion == 1`, `data` base64 via `JSONEncoder`'s default `Data` strategy; identity data 1…1024 bytes, record-version data 0…1 048 576 bytes; extra key, wrong type, `null` or bad base64 fails (`SyncTransport.swift:48-118`, `:245-313`; pinned by `SyncRecordCASTests.swift:37-75`).
- Encode-side invariants throw rather than write an inconsistent file (`SyncBase.swift:491-537`). `init` normalises: `cursorKind = nil` when cursor nil else default `legacy`; mode defaults to `incompletePrimary` when the fence is set; a review id is minted (`UUID()`) for schema ≥ 7 + fence + `reviewedLocalSnapshot` (`:114-130`).
- Migration: no rewrite on load. `upgradeToCurrentSchema()` (`:166`) sets schema 7 and mints a review id if a reviewed fence lacks one; the engine calls it before the first network operation (`SyncEngine.swift:1446-1455`), in `reconcileScope` (`:2350`, `:2363`, `:2510`) and in Check Again (`:728`). `adoptCursor` also bumps the schema (`SyncBase.swift:200`).
- Load outcomes (`SyncBase.swift:584-632`): `missing` (file absent), `unreadable` (I/O error or any decode failure), `tooNew(version)`, `loaded`. There is NO quarantine or regeneration of an unreadable base: the engine starts halted (`SyncEngine.swift:462-478`) and the file is left untouched for repair or deliberate removal of both protocol files.
- Derived values never stored: `pendingChanges(from:)` order = ascending uppercase `uuidString` (`SyncBase.swift:237`); `nonDestructiveReviewFingerprint()` = lowercase hex SHA-256 of `"review-id:<lowercase uuid>|reviewed:<c(envelopes)>|prior:<c(pre)|"unknown">"` where `c` joins, for keys sorted ascending, `"<utf8 len>:<key><utf8 len>:<envelopeHash or "invalid">"` with `|` (`:145-161`). Local only, but journal entries are bound to it, so Kotlin must be self-consistent, not Swift-compatible.

### `Sync/…/Quarantine/<UUID>.blob` (undecryptable or version-less fetched records)
- Written by `SyncEngine.quarantine(_:)` (`SyncEngine.swift:2974-2987`): file name is `record.id.uuidString` (uppercase) + `.blob`, content is the raw sealed `WireRecord.blob`, atomic write, 0600; folder created on demand; a write failure is only a diagnostic. Overwritten per id; never read back, never applied, never pruned by the engine. Local diagnosis only.

### Files the engine writes but does not own
- `Sync/state.json`: only the `halt` field, by read-modify-write under the library lock (`updatePersistedHalt`, `SyncEngine.swift:3225-3293`); format under `Sync/state.json` above. `Halt.at` is floored to whole seconds before writing so the value compares equal after an ISO-8601 round trip (`:3176`).
- `Sync/library-quarantine`: `<lowercase uuid>\n`, written/removed through `LibraryQuarantineMarker` during Check Again (`SyncEngine.swift:749-752`, `:793`; `SyncStateFile.swift:350-390`).
- `journal.json`: through `SyncJournalFile.write` only (`SyncEngine.swift:3070-3095`).

### Derived values defined by the merge layer (hashed or synced: byte-exact)

These are not files, but other devices derive the same values independently, so every byte matters. All JSON below is `CanonicalJSON` (sorted keys, no whitespace, int and double kept distinct; see the wire section).

- **Conflict snapshot and fingerprint** (`SyncMerge.swift:921-944`, `:915`). `fingerprint = lowercase hex SHA-256(CanonicalJSON(snapshot))`, where snapshot is exactly `{"fields":<Fields.canonicalValue>,"secure":<bool>,"sourceHLC":"<hlc.string>","sourceID":"<lowercase uuid>","sourceOrigin":"<origin>","version":1,"x":{<only vaultContentHash and vaultKID, if present>}}`. `fields` uses the envelope's own spelling: `content` as a UTF-8 string, `createdAt`/`updatedAt` as doubles of seconds since 2001 (`SyncEnvelope.swift:906`). `version` is an int. The snapshot never contains `copyID`, other `x` members or earlier conflict variants.
- **Copy id** (`:871`, `:900`, `:468`). `UUIDv5(namespace = source id, name = "sync-content-conflict-v1|" + fingerprint)`: SHA-1 over the 16 namespace bytes in RFC order followed by the UTF-8 name, first 16 digest bytes, `b[6] = (b[6] & 0x0F) | 0x50`, `b[8] = (b[8] & 0x3F) | 0x80`.
- **Provenance marker** (`:886`, `:1083`). `x["conflictCopy.v1"] = {"fingerprint":"<64 hex>","sourceID":"<lowercase uuid>","version":1}`. A parser accepts exactly these three keys, `version` int 1, canonical lowercase UUID text, 64 lowercase hex (`:1105-1118`).
- **Secure variant member** (`:894-907`). Key `"contentConflict.v1." + fingerprint`; value = the snapshot object plus `"copyID":"<lowercase uuid>"` (8 keys). The fingerprint is computed before `copyID` is added.
- **Plain copy envelope** (`:864-892`): see "Conflict copies". Its canonical bytes must equal the Linux vectors below.
- **Vault carrier for a variant** (`SyncLibraryProjection.swift:284-289`). In `VaultRecord.x`: key `"contentConflictOpaque.v1." + <wire key minus "contentConflict.">` (so `contentConflictOpaque.v1.v1.<fingerprint>`), value = JSON string holding standard padded base64 of the variant's canonical bytes. Decoded strictly (`Data(base64Encoded:)`, `:121`). Stored in `vault.json`; it must at least parse identically, and byte-exact if the vault document is shared (vault brief).
- **Conflict name** (`:454-464`, `SyncSecureConflictMaterializer.swift:238-245`). `"<display> (conflict " + format(updatedAt, "yyyy-MM-dd HH:mm 'UTC'", en_US_POSIX, UTC) + ")"`. It is a synced field of the copy, so two devices that format it differently publish different bytes for the same copy id.

Local-only derivations (only this device reads them back; determinism matters, cross-device byte equality does not):

- **Local-file copy id** (`SyncMerge.swift:437-439`): `UUIDv5(record id, "conflict|" + loser.content + "|" + loser.updatedAt.millisecondsSince1970)` (decimal). Pinned by `SyncMergeTests.swift:430`.
- **Payload digest** (`:301-311`): SHA-256 hex of the UTF-8 of `"<utf8 byte count>:<field>\u{2}"` for name, keyword, content, `tags.joined("\u{1}")` in that order, then `"1"|"0"` for isEnabled and for isPinned.
- **Deletion batch fingerprint** (`:55-60`): SHA-256 hex of the UPPERCASE UUID strings, sorted, joined with `"\n"`. Linux matches (`snippets-linux/src/merge.rs:696`).

### Formats owned by the utilities

- `Usage/usage.json` + `Usage/usage.lock` (`snippets/Core/Snippet.swift:206-217`, `snippets/Core/SnippetUsageDocument.swift:34`): Mac-only, device-local, never synced, not compiled into iOS. **None needed on Android.** Search snapshots, fuzzy state and settings search persist nothing.
- Share-link payload (`snippets/Core/SnippetDeepLink.swift:42-49`) and import documents are interchange formats, described in section 6. Only "parses the same" matters: no hash, signature or comparison covers their bytes.

## 3. Model semantics

### Snippet

| Field | Swift type | Default (`Snippet.swift:23-33`) | Notes |
|---|---|---|---|
| `id` | `UUID` | random v4 | uppercase in `snippets.json`, lowercase inside envelopes (`SyncEnvelope.swift:1102`) |
| `name` | `String` | required | no trimming or length limit in the model |
| `keyword` | `String` | required | store saves `sanitizedKeyword(keyword)`; empty = no trigger |
| `content` | `String` | required | body; `Data` inside envelopes (`SyncEnvelope.swift:855`) |
| `tags` | `[String]` | `[]` | normalised on decode and on envelope construction |
| `isEnabled` | `Bool` | `true` | |
| `isPinned` | `Bool` | `false` | |
| `createdAt` | `Date` | now | Double seconds since 2001; never changes after creation (drives display order) |
| `updatedAt` | `Date` | now | bumped by the store on edits |

- There is no name/keyword/content length constant in `Snippet.swift`. The only size ceilings in this area are the merge payload budget (`SyncMerge.maximumWireCanonicalBytes`, section 4) and import limits (section 6). The Linux port adds its own (`MAX_BODY_BYTES` 256 KiB, `MAX_SNIPPETS` 100,000, `MAX_FILE_BYTES` 32 MiB, NUL rejected: `snippets-linux/src/model.rs:17-19,107-117`); see Open questions.
- `starterSnippet` (`:45`): name `Temporary Password`, keyword `tp`, content `TP-{date:yyyyMMdd}-{clipboard}`. macOS seeds it; the iOS configuration must not seed anything (repository `AGENTS.md`), and Android follows iOS.
- `displayName` (`:53-59`): `name` trimmed of `whitespacesAndNewlines` if non-empty; else `contentFirstLine`; else the literal `Untitled Snippet`.
- `contentFirstLineUntruncated` (`:445-482`): scan Unicode scalars, split on `CharacterSet.newlines`, return the first line that is non-empty after trimming `whitespacesAndNewlines` from both ends; else `""`. `contentFirstLine` (`:491-499`): if longer than 50 `Character`s (extended grapheme clusters), first 50 + `…` (U+2026).
- `sanitizedKeyword` (`:65-77`): (1) trim `whitespacesAndNewlines`; (2) while the string `hasPrefix("\\")`, drop the first `Character` and trim again; (3) split on `whitespacesAndNewlines`, drop empty pieces, join with `-`. Case is preserved. `hasPrefix` is grapheme-aware: a backslash followed by a combining mark is one `Character` and is not stripped.
- Foundation character sets, measured on macOS 27.2 for this brief (do not use `Char.isWhitespace` or `String.trim()` on the JVM; they differ on U+001C-U+001F, U+0085, U+200B):
  - `whitespacesAndNewlines` = U+0009-000D, 0020, 0085, 00A0, 1680, 2000-200A, 200B, 2028, 2029, 202F, 205F, 3000.
  - `newlines` = U+000A-000D, 0085, 2028, 2029.

### Tags

- `normalizedTags` (`Snippet.swift:395-413`): per tag, trim, split on `whitespacesAndNewlines`, drop empties, join with a single space; drop if empty; keep the first spelling for each distinct `filterKey`; input order preserved.
- `filterKey` (`:426-430`) = `tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))`. It decides tag identity, tag filtering, keyword collision (`SnippetStore.swift:1042`, `SyncMerge.swift:364,539`) and tag colour hashing. The locale is fixed on purpose (`ReviewRegressionTests.swift:180`): with a Turkish locale `I` folds to `ı`.
- What that Foundation call actually does (probe on macOS 27.2 over every scalar; 1,943 scalars change). It is NOT `casefold + NFKD + strip marks`:
  - Case: lowercase-style mapping with full-fold expansions: `ß`/`ẞ` -> `ss`, `ﬁ` -> `fi`, `ŉ` -> `ʼn`, `İ` -> `i`, `Σ`/`ς` -> `σ`, `Ω`/U+2126 -> `ω`, `ǅ`/`Ǆ` -> `ǆ`; `ı` stays `ı`; Cherokee folds to the lowercase block (U+13A0 -> U+AB70), the reverse of Unicode `CaseFolding.txt`.
  - Diacritics: precomposed Latin/Greek/Cyrillic letters lose their marks (`é` -> `e`, `Å`/U+212B -> `a`, `й` -> `и`, `ё` -> `е`, `ΐ` -> `ι`); `ø`, `đ`, `ł` and similar stroke letters are unchanged (no decomposition). Precomposed Arabic, Hebrew, Indic and kana letters are unchanged (`が` stays U+304C, `آ` stays U+0622).
  - Sequences: a mark after a base is usually dropped (`a` + U+0301 + U+0301 -> `a`, `x` + U+20DD -> `x`, `a` + U+FE0F -> `a`, Hangul syllable + U+0301 -> syllable). Probing U+0301 after every base below U+30000 gives 437 alternating strip/keep ranges: stripped after Latin, Greek, most Cyrillic, Arabic, Hebrew, Indic, CJK; kept after a scattered set that includes U+023A, U+023E, the even code points U+0510-U+052E, Armenian capitals U+0531-U+0558, Georgian U+10A0-U+10CF, Cherokee U+13A0-U+13F7, Roman numerals U+2160-U+216F. Pairs with a precomposed form Foundation leaves alone are also kept (U+0627 U+0654, U+304B U+3099, U+0915 U+093C, U+05D0 U+05B8). A mark at the start of the string is kept. No closed-form rule was found.
  - No width or compatibility folding: fullwidth `Ａ` -> fullwidth `ａ`, not `a`.
  - The Linux port uses `case_fold().nfkd()` minus combining marks (`snippets-linux/src/model.rs:40-46`), which agrees for ordinary Latin, Greek and Cyrillic text and already diverges on the cases above (fullwidth, kana dakuten, Arabic/Indic precomposed, Cherokee).
  - Port guidance: have the wave-1 Swift vector emitter produce (a) the per-scalar table and (b) a base+mark and multi-cluster corpus, ship the table in `:core`, and gate the Kotlin `filterKey` on the corpus. Do not approximate with `java.text.Normalizer` or an ICU `Transliterator`. Whether exact Foundation parity outside Latin/Greek/Cyrillic is required at all: Open questions.
- `hasTag(withKey:)` (`:434`) compares `filterKey`s.

### Display order (the only presentation order)

`SnippetDisplayOrder.ranks` (`Snippet.swift:88-101`): pinned first; then `createdAt` descending (exact Double comparison); then `id.uuidString` ascending (uppercase hyphenated string compare, which for hex digits equals bytewise order). File order in `snippets.json`/`vault.json` is never presentation state and is not synced. `java.util.UUID.compareTo` is a signed 64-bit comparison and gives a different order; compare the string forms. Linux mirrors this at `snippets-linux/src/model.rs:260-265`.

### IDs

- Snippet id: random UUID v4 at creation; stable for life; the wire record id, the per-record key derivation input (crypto brief) and the vault record id.
- Device id / envelope `origin`: 8 lowercase hex chars (`HLC.normalizedDevice`, `HLC.isCanonicalDeviceID`, next subsection).
- Conflict-copy id: UUIDv5 derived from the losing envelope (section 4, merge).
- Provider folder key: 32 lowercase hex chars (`Snippet.swift:139-144`).

### Hybrid logical clock
- Fields (`snippets/Core/HybridLogicalClock.swift:29-37`): `wallMs: UInt64` (Unix ms, clamped to `0xFFFF_FFFF_FFFF` in `init`, `:52`), `counter: UInt16`, `device: String` (8 lowercase hex).
- String form (`:76-78`): `String(format: "%012llx-%04hx-%@")` = 12 lowercase hex, `-`, 4 lowercase hex, `-`, device; always 26 ASCII bytes. Codable as that single JSON string (`:93-106`).
- Parse (`:108-126`): exactly 26 UTF-8 bytes, `-` at offsets 12 and 17, every other byte in `0-9a-f` (ASCII byte test, uppercase and non-ASCII digits rejected, never normalised); the device substring is taken verbatim. Anything else is `nil` / a decoding error (`Tests/Core/ClockAndStateTests.swift:210-262`).
- Order (`:80-86`): `wallMs`, then `counter`, then `device` string compare; identical to lexicographic order of the string form (`ClockAndStateTests.swift:141`). Equality/hash over all three fields.
- Device ids: `makeDeviceID` = random `UInt32`, 0 replaced by 1, `%08x` (`:160-165`). `foreignDevice = "00000000"` is reserved for clockless records (`:49`); `HLC.foreign(updatedAt:)` = `(updatedAt ms, 0, "00000000")` (`:70`). `SyncMerge` does not use the foreign id to break ties (`:44-48`).
- `normalizedDevice(raw)` (`:148-155`): lowercase, keep hex digits, take first 8 or left-pad with `0` to 8; if the result is `00000000` and `raw` was not literally that, return `00000001`. Vectors: `"ABCDEF01"->"abcdef01"`, `"abcdef0123456789"->"abcdef01"`, `"1"->"00000001"`, `"ab-cd-ef-01"->"abcdef01"`, `"not hex at all"->"00000eaa"`, `""->"00000001"` (`ClockAndStateTests.swift:296-306`). `isCanonicalDeviceID` = exactly 8 bytes of `0-9a-f` (`:131-134`), independent of the normaliser.
- `Date.millisecondsSince1970` (`:261-267`): non-finite or <= 0 seconds -> 0; else `UInt64(min(seconds * 1000, 0xFFFFFFFFFFFF))` (truncation toward zero).
- `HLCGenerator` (`:173-259`), not thread-safe, clock injected as `physicalNowMs`:
  - init: `last = max(persisted, HLC(now, 0, device))` (`:198-203`).
  - `send(atLeast floor)`: `wall = max(now, floor)`; if `wall > last.wallMs` -> `(wall, 0)`; else if `last.counter == 65535` -> `(last.wallMs &+ 1, 0)`; else `(last.wallMs, last.counter + 1)`; always own device (`:217-233`). `send()` = `send(atLeast: now)`.
  - `stamp(updatedAt, baseHLC)`: `floor = max(updatedAt ms, (baseHLC?.wallMs ?? 0) &+ 1)`, then `send(atLeast: floor)`; result is strictly above the ancestor, which is what makes undo win (`:242-245`, `ClockAndStateTests.swift:368-418`).
  - `observe(remote)`: ignore (and count in `rejectedSkewCount`) when `remote.wallMs > now &+ maxDriftMs`; `maxDriftMs = 86_400_000` (`:185`), limit inclusive (`ClockAndStateTests.swift:475`); otherwise if `remote > last`, `last = (remote.wallMs, remote.counter &+ 1, own device)` (`:248-258`).
- Journal clocks do not use a long-lived generator: `SyncJournal.clock(after:deviceID:now:)` builds one with `persisted = max(evidence clocks)` and calls `send()` once (`snippets/Core/SyncJournal.swift:2026-2032`), i.e. `(now, 1)` when `now` is ahead of all evidence (init seeds `(now, 0)`, `send` then bumps the counter), else evidence max with counter + 1 (carry into `wallMs` at 65535).

### Tombstones
- Live protocol: a deletion is a `SyncEnvelope` with `deleted = true`, `fields = nil`, extensions dropped except `vaultKID` on secure records (`snippets/Core/SyncEnvelope.swift:1342-1350`); it is a record save, never a physical delete. The journal creates one only when a live confirmed, offered, reviewed or dependency-proved value shows the record existed (`SyncJournal.swift:1065-1083`); a create removed before it was ever offered produces nothing (`:1089-1093`). The tombstone HLC is `clock(after: [previous desired, offered, confirmed])`, origin = this device.
- User-initiated deletes add `x["userDeletion.v1"]` = sorted array of up to 8 `envelopeHash` strings of the live ancestors (previous desired, offered, confirmed, reviewed ancestor, dependency proof) (`SyncJournal.swift:1106-1123`, key at `SyncEnvelope.swift:819`).
- A recreation after a confirmed tombstone is restamped above it (`SyncJournal.restampedIfNeeded`, `:1972-2013`; `Tests/Core/SyncJournalTests.swift:828`). Retention of tombstone envelopes in `base.json` belongs to `SyncBase` (other section); the journal never garbage-collects by age.
- `TombstoneLedger` (unused in production, `snippets/Core/Tombstones.swift`): `defaultHorizon = 90 days` (`:58`); `record` keeps the higher HLC (`:104-108`); `collect(now)` drops `deletedAt < now - horizon` and advances `collectedThrough` only on an actual drop (`:129-149`); `recognize(id, hlc)` = `deleted` / `unseen` / `indeterminate` when `hlc.wallMs <= collectedThrough ms` (`:184-193`).

## 4. Sync engine

Reading order: transport protocol, round state machine, base, deletion guard, halts, threading, the reference fake; then the journal and the library write protocol; then merge, conflict copies, projection and secure records.

### Transport protocol
`protocol SyncTransport: Sendable` (`SyncTransport.swift:546-643`); defaults `:657-704`. A transport sees only `WireRecord {id, rev, deleted, blob, recordVersion?}` (`SyncEnvelope.swift:732`).

| Member | Contract | Default |
|---|---|---|
| `identifier: String` | stable name stored/logged (`"git"`, `"snippets-cloud"`, `"memory"`); never change | — |
| `supportsPush: Bool` | may `submit`; a non-empty pending set on `false` throws `.pushUnsupported` (`SyncEngine.swift:1557`) | — |
| `pollInterval: TimeInterval` | idle poll period, used by the coordinator (Git 60 s `GitSyncTransport.swift:114`, Snippets Cloud 60 s `SnippetsCloudTransport.swift:60`) | — |
| `roundPacing: SyncRoundPacing?` | `{localChangeDelay, localChangeMaximumWait, activationRefreshInterval}` (`:647`); read by the coordinator only, never by the engine; Git = 30/120/30 s (`GitSyncTransport.swift:120-130`) | `nil` |
| `events: AsyncStream<SyncTransportEvent>` | hints only, single consumer: `changesAvailable`, `cursorInvalidated(reason)`, `authenticationRequired` (`:322`) | — |
| `resolveAccountIdentity()` | opaque account scope or `nil` for accountless | `nil` |
| `preflightScope() -> SyncScopePreflight` | `{identity?, datasetIdentity?, legacyAccountIdentities[], checkpointIssue?: accountChanged \| unreadable}` (`:205`); called before any library read | wraps `resolveAccountIdentity` |
| `fetchChanges(since: SyncCursor?) -> SyncFetch` | `nil` cursor = everything | — |
| `submit(_:[WireRecord], at: SyncCursor?) -> SyncSubmission` | each record carries the `recordVersion` it was built on (`nil` = create); backend must CAS on it and answer `.conflict` instead of overwriting; throw = whole call failed | — |
| `resetAfterAccountReview / resetAfterCheckpointReview / resetForLocalFullResync(expectedIdentity:expectedDatasetIdentity:)` | one-shot transport-private reset after Core journaled all local intent | throws `.accountChanged` / `.remoteDataReset` unless both expected values are `nil` |
| `resetAfterRemoteDataResetReview(…)` | authority to repopulate a reset remote | always throws `.remoteDataReset` (must opt in) |
| `acknowledgeFetched(through:)` | called after the cursor is durable in `base.json` | no-op |
| `shutdown()` | barrier: returns when the transport can no longer mutate state | no-op |

- `SyncCursor` (`:12`): opaque string, JSON single value; the engine never parses it. `SyncCursorKind` (`:35`): `legacy`, `cloudKitSyncEngine`; a `SyncFetch` with a cursor and no kind is `legacy` (`:471`).
- `SyncFetch` (`:428`): `records` in backend order, duplicates allowed (at-least-once); `cursor`; `cursorKind`; `hasMore` (engine loops immediately, no page cap); `isFullResync` (page is a snapshot: absence proves nothing); `replacesPriorPages` (discard pages accumulated so far in this fetch; must come with `isFullResync`); `accountIdentity`, `datasetIdentity` (must equal the preflight values).
- `SyncSubmission` (`:501`): `results: [SyncSubmitResult{id, outcome}]` (ordered, engine matches by id, never by position `SyncEngine.swift:1598-1609`), `cursor` (never adopted as fetch position, `:1727-1733`), `accountIdentity`, `datasetIdentity`. Outcome: `.accepted(rev:, recordVersion:)` (version mandatory) or `.rejected(SyncRejection)`.
- `SyncRecordVersion` (`:244`): opaque backend generation (Git: record blob id; memory: `"memory-<seq>"`), stored in `base.recordVersions` and in each journal offer.

Error taxonomy and engine policy:

| Signal | Where | Engine reaction | Pointer |
|---|---|---|---|
| `SyncRejection.conflict(remote: WireRecord?)` per record | submit | offer stays; `remote` (same id) is merged ahead of the fetch feed; `nil` → id is "unresolved": cursor held, round ends `unreachable` → backoff until a fetch delivers that id | `SyncEngine.swift:1651-1665`, `:1903`, `:2262`, `:2315` |
| `.rateLimited(retryAfter)` per record | submit | offer stays, `retryableRejections += 1`, round still succeeds (no backoff; `retryAfter` is not used), follow-up rounds suppressed | `:1666-1681`, `:1232` |
| `.authenticationRequired(detail)` per record | submit | accepted prefix is persisted first, then round ends `.needsAuthentication(detail)` | `:1629-1636`, `:1725`, `:2943` |
| `.permanent(detail)` per record | submit | offer resolved by the following fetch, then round ends `.needsAttention(detail)`; never a persisted halt | `:1637-1650`, `:1902`, `:2313`, `:1318` |
| `SyncTransportFailure.unreachable`, `.rejected(.conflict/.rateLimited)`, any untyped error | any call | `.offline(retryAfter: now + min(2^n, 300) s)`, n = consecutive failures | `:2967-2970`, `:1326-1334` |
| `.rejected(.authenticationRequired)` / `.rejected(.permanent)` / `.pushUnsupported` | any call | `.needsAuthentication` / `.needsAttention` (not sticky, no backoff) | `:2943-2957` |
| `.accountChanged` / `.checkpointUnreadable` / `.remoteDataReset` | any call | persisted sticky halt of the same name | `:2958-2966` |
| response identity ≠ preflight identity | submit, fetch | `SyncEngineFailure(.accountChanged)` or `(.remoteDataReset)` → sticky halt; nothing trusted | `:1585-1596`, `:1755-1766` |
| `CancellationError` | anywhere | `.disabled` (or back to the reviewed deletion halt); no backoff | `:1270-1278` |

### Round state machine
`sync(bypassingBackoff:)` (`SyncEngine.swift:1149`) gates, then runs `performRound()` (`:1343`) one or more times.

Gates, in order: `requiresTransportRestart` → return; halted with a `recoveryClaim` → re-read the halt by CAS (peer-completion watch) and return (`:1151-1178`); halted → return; already `.syncing` → return (no re-entrancy); `.offline` and `now() < retryAfter` and not bypassing → return (`:1179-1183`). Then `.syncing`.

`performRound()`; "P:" marks a durable write, each published in memory only after it succeeded (`persistBase` `:2994`, `persistJournal` `:3070`):
1. `Task.checkCancellation`; `transport.preflightScope()`; a `checkpointIssue` throws unless the matching reviewed reset is approved (`:1361-1373`); `reconcileScope` (see Halts). Any error here clears `approvedTransportReset` (`:1380`).
2. If `base.requiresNonDestructiveLibraryMerge`: `resetForNonDestructiveLibraryMerge` (`:1389`, `:2522`): P: journal reconciled against the reviewed snapshot; journal-only live values re-applied to primary with `expectedPrimary = .absent`; then `resetTransportCheckpoint` (step list under Halts). Returns early if anything deferred/retried.
3. If `base.requiresTransportFullResync`: recover conflict prerequisites, `transport.resetForLocalFullResync`, P: base with the flag cleared (`:1409-1435`).
4. Establish protocol files: P: `base.json` if absent, then P: `journal.json` if absent, then P: base with `journalEstablished = true` and schema 7 (`:1440-1455`). Always base before journal.
5. `recoverFrozenConflictPrerequisitesInPrimary()` (`:1462`, `:2905`); deferred → return round (waiting for vault).
6. Local read 1: snapshot `userInitiatedDeletionIDs` first, then `library.currentEnvelopesForRound(agreedBase: journal.projectionKnowledge(over: base))`; journal copy: `rebaseIdenticalSourceOffers`, `recoverAcceptedPrerequisiteOffers`, `reconcileDependencies(current:confirmed:discoverSecureCarriers:)`, `reconcile(current:confirmed:deviceID:now:userInitiatedDeletionIDs:)` (off main); P: journal; consume deletion intents (`:1485-1513`).
7. Carrier resolutions if any: P: journal `beginCarrierResolutions` BEFORE `library.resolveConflictCarriers`; re-read; reconcile; P: journal (`:1515-1553`).
8. Push. `pending = journal.pending(confirmed: base)`. If non-empty: `markOffered(pending, confirmed:)`, P: journal (before any network use); seal each with `WireCodec.seal(envelope, using: sealer)` and attach `journal.offeredSnapshot(for:).recordVersion` (the offer's own generation, not the base's current one, `:1569-1581`); `transport.submit(records, at: base.cursor)`; verify identities; fold results by id. If anything accepted: P: base (`recordConfirmed(offeredEnvelope, recordVersion)`) THEN `journal.acknowledge(accepted, confirmed: base)` P: journal; re-read library, `reconcileDependencies(…acceptedSourceIDs:)`, `reconcile`, P: journal (`:1685-1721`). Then throw a recorded authentication failure.
9. Fetch loop from `base.cursor` (`:1737-1801`): per page check cancellation and identities; `replacesPriorPages` without `isFullResync` → `checkpointUnreadable` halt, otherwise drop all pages fetched so far (conflict records from step 8 are kept); snapshot/delta mode flip between pages → `checkpointUnreadable` halt; append; `cursor = fetch.cursor`; continue while `hasMore`.
10. Open in order [conflict records from step 8] + [pages]. A record without `recordVersion`, or one `WireCodec.open` rejects, is written to Quarantine and its id is "opaque". The LAST occurrence of an id decides: decodable → that envelope, opaque → nothing for that id (`:1806-1852`). `incoming` is ordered by last position.
11. Local read 2: `library.currentSnapshotForRound(...)`; `reconcileDependencies` + `reconcile`; P: journal. This captures edits and deletes made during the network awaits before anything remote is applied (`:1857-1874`).
12. Empty path (`incoming` empty and not a full resync, `:1876-1908`): `journal.reject(rejectedThisRound − opaque − unresolved)`, P: journal; if no opaque and no unresolved ids: P: base with the new cursor, then `transport.acknowledgeFetched(through:)`; throw the deferred permanent failure, or `unreachable` for unresolved conflicts; return.
13. Merge (`:1914-2053`): `journal.validateDependencyOccupants`; reserved conflict-copy ids must match; overlay `localNow[id] = journal.entry(id).desired` for incoming ids; ancestor per record = the offered envelope when the remote equals it by `envelopeHash` (own echo, `:1960`), else for a reviewed-snapshot journal entry `preReviewMergeAncestor ?? (changed after review ? reviewedLocalAncestor : nil)` (`:1968-1980`), else `base.envelope(id)`; `SyncMerge.mergeEnvelopeOutcome(base:local:remote:)` gives survivor + conflict copies; copies are checked against fetched and local occupants (`isMatchingPlainConflictCopy`), an existing edited copy is never replaced. `merged` sorted by uppercase `uuidString`.
14. P: journal with `stageConflictDependency(source:conflictCopies:)` for every survivor with copies or secure variants (`:2055-2063`).
15. `library.prepareRemote(merged)` → `RemoteClassification {applicable, deferredIDs, incompatibleVaultIDs}` (`:2067`).
16. Deletion guard (next section); a refusal throws before any apply.
17. `expectedPrimary[id] = localSnapshot.primaryState(for: id)` for every applicable id and every secure-variant copy id; `library.prepareConflictCopyEvidence(from:)`; if non-empty: `recordConflictCopyEvidence` + `holdPostPrerequisiteCopyIntents`, P: journal; then `library.applyRemote(applicable, expectedPrimary:, heldConflictCopyIntents:, preparedConflictCopyEvidence:)` → `ApplyOutcome {changedIDs, deferredIDs, incompatibleVaultIDs, retryIDs, conflictCopyEvidence}` (`:2141-2200`).
18. `unapplied = deferred ∪ incompatible ∪ retry`. P: journal (`holdPostPrerequisiteCopyIntents`); P: base with `recordConfirmed(remoteEnvelope, recordVersion)` for every incoming id not unapplied, cursor unchanged. The base records what the backend said, never the merged value (`:2211-2251`).
19. `journal.acknowledge(confirmedIDs, confirmed: base)`; `journal.reject(…)`: full resync → `rejectedThisRound ∩ confirmedIDs`; delta → `rejectedThisRound − unapplied − opaque − unresolved`; local read 3 (`currentEnvelopesForRound`), `reconcileDependencies`, `reconcile`; P: journal (`:2256-2299`).
20. Only if `unapplied`, opaque and unresolved are all empty: P: base with `adoptCursor(cursor, kind:)`, then `transport.acknowledgeFetched(through: cursor)` (`:2304-2311`).
21. Throw, in order: deferred permanent rejection, `unreachable` for unresolved conflicts, `vaultUnreadable` halt for incompatible ids (`:2313-2326`). Else return counts.

After the first `performRound` (`:1204-1269`): `retryNeeded` (primary CAS miss) → exactly one immediate replay; then follow-up rounds while `settledOffers > 0` (accepted or authoritatively rejected, and zero retryable rejections), `deferred == 0`, `!retryNeeded`, fewer than `followUpRoundsAfterSettledOffers` done, and `journal.pending(confirmed: base)` non-empty. Final state: `.waitingForVault("<n> secure snippet(s) …")` when `deferred > 0`, else `.idle(lastSync: now())`; `consecutiveFailures = 0`.

Crash-safety rules a port must keep: (a) offer durable before submit, retried byte-identically with its own record version; (b) acceptance: base before journal acknowledge; (c) fetch: local intent journaled → apply → base envelopes with old cursor → journal resolve → cursor → transport ack; (d) an id that was not applied is neither confirmed nor allowed to advance the cursor; (e) any base/journal write failure becomes a `localLibraryQuarantined` halt (`:3024-3034`, `:3090-3093`); (f) `persistJournal` skips the write when the candidate equals the published journal and the file exists, and always calls `library.retainConflictPrerequisiteInstallReceipts(for: journal.activeConflictPrerequisiteCopyIDs)` afterwards (`:3070-3084`).

### Base and checkpointing
- `SyncBase.pendingChanges(from:)` (`SyncBase.swift:210-238`) is the base-only diff: changed by `envelopeHash`, plus a tombstone `known.tombstoned(hlc: known.hlc, origin: known.origin)` for every live base id missing locally, except ids with an unresolved content conflict. The engine itself pushes `journal.pending(confirmed:)`, not this.
- `recordConfirmed(envelope, recordVersion:)` replaces or removes the version atomically with the envelope (`:186-193`); `record(_:)` updates ancestry only (`:179`).
- Engine start (`SyncEngine.swift:453-543`): base `tooNew` → `.halted(.schemaTooNew)`; base unreadable → `.halted(.localLibraryQuarantined)`; same for journal; base missing while journal exists → halted; base loaded with `journalEstablished` while journal missing → halted; then a `halt` stored in `state.json` overrides the displayed state, and a too-new `state.json` → `.schemaTooNew`. These start-up halts are in memory only (not written).
- Every recovery re-reads the pair (`reloadProtocolPairAfterReview`, `:1033-1118`): both missing = explicit reset to empty; base loaded + journal missing is allowed only when `journalEstablished == false`.

### Deletion guard
- Threshold: `allowed = max(5, (2·max(0,n) + 9) / 10)` in integer arithmetic = `max(5, ceil(n/5))`; refuse iff `deletions > allowed`; zero deletions always pass (`SyncMerge.swift:15-25`, `DeletionGuard.swift:96-103`). Set form dedupes and intersects with live ids (`DeletionGuard.swift:112-115`).
- Engine use (`SyncEngine.swift:2070-2138`), on the classified, merged batch: `live = library.liveIDs()`; `approved` = applicable envelopes whose `userInitiatedDeletionAncestorHashes` contain the `envelopeHash` of the live local projection or of the merge ancestor (`:3138-3148`), ∩ live; `guardedLive = live − approved`; `effective` = applicable deleted ids not approved, ∩ `guardedLive`; `evaluate(liveCount: |guardedLive|, deletions: |effective|)`.
- While a review is in progress (legacy refresh, approved or in-flight reviewed deletion) any non-empty `effective` set is treated as a refusal, even below the threshold (`:2089-2103`).
- Fingerprint: lowercase hex SHA-256 of the effective ids' `uuidString` (UPPERCASE) sorted ascending and joined with `\n` (`SyncMerge.swift:55-60`; Rust uppercases explicitly, `snippets-linux/src/merge.rs:696-703`).
- Refusal throws `SyncEngineFailure(.massDeletion, recoveryContext: .massDeletion(liveCount, requestedDeletions, batchFingerprint))` (`:2126-2132`); nothing is applied, base and cursor do not move, so the next round re-fetches and re-evaluates the same batch.
- Review: `performRecovery(.applyRemoteDeletions)` copies the durable context into a one-round `approvedMassDeletion`, rewrites the halt with a `RecoveryClaim` (it stays on disk), sets `.idle` (`:822-836`, `:938-985`). The next round proceeds only if live count, deletion count and fingerprint all match (`:2110`); the halt is cleared by CAS only after the whole round committed (`finalizeReviewedMassDeletionHalt`, `:2726`). The approval is dropped at the end of every `sync()` (`:1188-1192`). A halt without context (legacy) offers only `.refreshDeletionReview`: one inspection round that applies no deletion (`:604-606`, `:851-891`, `:2689`).

### Halts and account/binding review
- `SyncEngine.State` (`:308-330`): `disabled`, `idle(lastSync: Date?)`, `syncing`, `offline(retryAfter: Date)`, `needsAuthentication(String)`, `needsAttention(String)`, `waitingForVault(String)`, `halted(SyncState.HaltReason, detail: String)`. Only `halted` is sticky/persisted; `needsAttention("transport_restart_required")` is the signal to rebuild engine + transport (`requiresTransportRestart`, `:412`).
- `SyncState.HaltReason` → `SyncRecoveryAction` (`SyncStateFile.swift:135`, `:229-240`): `massDeletion` → `applyRemoteDeletions` (or `refreshDeletionReview` without context); `accountChanged` → `useCurrentAccount`; `checkpointUnreadable` → `repairCheckpoint`; `remoteDataReset` → `restoreCloudFromThisDevice`; `backendRefused` (legacy only) → `retrySync`; `manifestIntegrityFailed`, `localLibraryQuarantined`, `vaultUnreadable` → `checkAgain`; `schemaTooNew` → none. A claim owned by an unknown process → `reclaimRecovery`; by a live engine in this process → no action (`SyncEngine.swift:592-608`).
- Persistence: `enterHalt` (`:3168`) writes `SyncState.Halt {reason, detail, at, recoveryContext?, recoveryClaim?}` through `updatePersistedHalt(new, expecting: old)` (`:3225`): takes `FileGuard` on the library lock (timeout 2 s; an unlocked/degraded guard counts as failure), loads `state.json`, compares the stored halt with `expecting`, results `written | superseded(newer) | cleared | tooNew | failed`. `failed` keeps the in-memory halt and calls `onSafetyHaltPersistenceFailure` (the app turns the sync preference off).
- `performRecovery(action)` (`:654`): the action must equal the current `recoveryAction`; reload the protocol pair; then per action set a process-local one-shot (`approvedTransportReset = account | checkpoint | remoteData`, or `approvedMassDeletion`), CAS a `RecoveryClaim {id, ownerID, hostName, processID, processGeneration…}` into the durable halt (`:615-627`), and go `.idle`. `retrySync`/`checkAgain` clear the halt by CAS directly (`:987`). Check Again with a `localLibraryQuarantine` context or marker runs the primary-library recovery transaction (`:696-819`): `library.reviewRecoveredLibrary`, P: base = reviewed envelopes, no versions, no cursor, fence `reviewedLocalSnapshot` with the marker's review id, clear halt, remove marker, `library.finalizeRecoveredLibraryReview()`.
- Scope binding, `reconcileScope` (`:2334-2516`), all before any library read: (1) stored identity found in `legacyAccountIdentities` and base lacks a dataset fence → rebind silently; (2) no meaningful checkpoint (no cursor, envelopes, versions, journal entries or dependencies) and no stored identities → bind directly; (3) approved account reset → `resetTransportCheckpoint` with `resetAfterAccountReview`; (4) `base.accountIdentity != resolved` → `accountChanged` halt; (5) dataset differs, or a meaningful checkpoint has none while the transport reports one → `remoteDataReset` halt unless an approved remote-data reset runs; (6) approved checkpoint reset; (7) schema upgrade. Git and Snippets Cloud both return an account and a dataset identity (`GitSyncTransport.swift:531-541`, `SnippetsCloudTransport.swift:88-91`), so these halts are live on Android.
- `resetTransportCheckpoint` (`:2594-2669`): recover conflict prerequisites (locked vault → `vaultUnreadable`) → `library.currentEnvelopes` → `journal.prepareForAccountChange(…)` (or `prepareForNonDestructiveLibraryRecovery` + `markReviewedLocalSnapshot`) → P: journal → transport reset → P: `SyncBase(journalEstablished: true, accountIdentity:, datasetIdentity:)` → clear the exact halt by CAS. A failure after the approval was consumed re-enters the halt and needs a new review (`checkpointResetRequiresReview`, `remoteResetRequiresReview`, `:402-403`).

### Pacing and threading
- The engine is `@MainActor` (`:288`); all state and every file publish happen there. The `.syncing` check is the only re-entrancy guard, so `sync()` must be entered on one confined context.
- Off the main actor (`offMainActor`, `:3063`, a detached task at the caller's priority): `SyncJournal.reconcile` (`:3039`) and base encode + write (`persistBaseOffMainActor`, `:3011`). Both are pure functions of their arguments and are awaited before the next step, so write order is unchanged.
- `currentEnvelopesForRound` / `currentSnapshotForRound` must take their read of the library before first suspending (`:138-144`); the engine snapshots deletion intents before that read and consumes only those (`:1485`, `:3117-3132`).
- Cancellation is checked before and after every awaited transport call and before apply and before each confirming base write (`:1344`, `:1364`, `:1582-1584`, `:1752-1754`, `:1877`, `:2140`, `:2221`).
- Backoff is the engine's; debounce, poll and `roundPacing` are the coordinator's (section 5). `now` is injected (`:337`); nothing reads the wall clock directly.

### InMemoryTransport as the reference fake
- State: `id → (record, sequence)`, `nextSequence` from 1; every store reassigns the sequence and sets `recordVersion = "memory-<sequence>"` (UTF-8) (`InMemoryTransport.swift:403-412`). Cursor = decimal string of the highest sequence delivered; a foreign cursor parses to "from the beginning" (`:428`).
- Fetch (`:276-335`): records with `sequence > cursor` ascending, first `pageSize` (default 100), `hasMore`; a cursor ahead of the high-water mark → full resync from nil with `cursorInvalidated`; `replacesPriorPages = isFullResync && cursor != nil`; an empty page returns the incoming cursor.
- Submit (`:337-399`): logs every batch; per record: existing id with a different `recordVersion` → `.conflict(remote: stored)`; unknown id submitted with a version → `.conflict(remote: nil)`; else store and `.accepted(rev, recordVersion)`. Returns the high-water cursor. No account or dataset identity.
- Faults (`:43-101`): `rejectEverything`, `rejectRecords[id]`, `failFetches`, `failSubmits`, `failLocalFullResets` (count down), `unreachable`, `latency` via injected sleeper, `acceptAtMostPerBatch` + `partialBatchRejection` (default `.rateLimited(1)`), `invalidateCursorOnNextFetch`, `deliverPagesTimes` (page repeated as a block), `dropCursorOnNextFetch`, `rewriteAcceptedRevs` (`"srv-<seq>-<rev>"`). Defaults: `identifier "memory"`, `supportsPush true`, `pollInterval 30`.

| Constant | Value | Pointer |
|---|---|---|
| `SyncBase.currentSchemaVersion` | 7 | `SyncBase.swift:38` |
| identity / record-version schema | 1 | `SyncTransport.swift:48`, `:129`, `:245` |
| identity max bytes / record-version max bytes | 1 024 / 1 048 576 | `SyncTransport.swift:49`, `:246` |
| `maxBackoff`; delay | 300 s; `min(2^failures, 300)` (2, 4, 8 …) | `SyncEngine.swift:423`, `:2969` |
| `productionFollowUpRounds` (default 0 in tests) | 2 | `SyncEngine.swift:1141`, `:1146`; set at `SyncCoordinator.swift:727` |
| CAS-miss replay per `sync()` | 1 | `SyncEngine.swift:1210` |
| `stateLockTimeout` | 2.0 s | `SyncEngine.swift:437` |
| deletion floor / fraction | 5 / 20 % (ceil) | `SyncMerge.swift:15`, `:24` |

### Journal
- Model (`snippets/Core/SyncJournal.swift:19-171`). There are no intent "kinds": an entry holds whole envelopes, and create/update/delete is implied by `desired` vs the confirmed base. `entries: [lowercase uuid: Entry]`; `Entry = { desired, offered?, generation, modifiedAt, reviewedLocalAncestor?, reviewedLocalSnapshotKnown, preReviewMergeAncestor? }`; `Offered = { envelope, generation, recordVersion? }`. `desired` = latest local state (a tombstone envelope for a delete). `offered` = the exact immutable snapshot handed to the transport plus the exact CAS token it was sent with; it is never replaced by a newer `desired`, only confirmed, rejected or resent (`:5-18`, `:34-54`).
- Version identity everywhere is `sameVersion` = equal `envelopeHash()`; structural equality only if hashing throws (`:2039-2049`).
- Local edits do not write the journal directly. Each round the engine projects the library to `[UUID: SyncEnvelope]` (Projection, below) and calls `reconcile`.
- `reconcile(current:confirmed:deviceID:now:userInitiatedDeletionIDs:)` (`:1008-1150`), per id in ascending `uuidString` order over current + confirmed + entries + dependency source and copy ids:
  1. Drop `offered` if it is the same version as the confirmed envelope (finishes a base-first crash, `:1031-1035`).
  2. Choose `desired`: (a) id present locally -> `restampedIfNeeded(local)`; (b) absent and previous desired is a tombstone -> reuse it (no new clock per round); (c) absent, no dependency on this id, and previous desired / offered / confirmed still carries an unresolved content-conflict extension -> keep the newest such live envelope (deletion is held, `:1055-1064`); (d) absent and an existence proof exists = newest live of offered, confirmed, previous desired (only if the id is dependency-owned or `reviewedLocalExistence`), dependency proof -> tombstone the newest live of (previous desired, proof) with `clock(after: evidence)` and `origin = deviceID` (`:1065-1083`); (e) absent and offered is a tombstone -> keep it; (f) otherwise no entry (a never-offered create that vanished costs nothing remotely, `:1089-1093`).
  3. If the tombstone's id is in `userInitiatedDeletionIDs` and has no marker yet, add `x["userDeletion.v1"]` (section 3) (`:1106-1123`). These ids are the UI delete intents captured before the library was read for this round; a crash before the journal is durable loses only the marker, not the delete.
  4. If `offered == nil`, desired is the same version as confirmed and no dependency needs the intent retained -> remove the entry (`:1125-1130`).
  5. Otherwise store it: `generation` and `modifiedAt` change only when `desired`'s version changed (`generation` = previous + 1 saturating, first = 1, `:2034-2037`); review fields carried over (`:1132-1148`).
- `restampedIfNeeded` (`:1972-2013`): unchanged if local equals previous desired, offered or confirmed. If `local.hlc <= previousDesired.hlc` and schema/id/secure/deleted/fields/x are equal -> return previous desired (fixed point, because the library files cannot store HLC/origin; `Tests/Core/SyncJournalTests.swift:863`). If `local.hlc` is not above every prior evidence clock -> same payload with `hlc = clock(after: local + evidence)`, `origin = deviceID`. Else local as is.
- `pending(confirmed:) -> [SyncEnvelope]` sorted by id (`:1157-1218`): for an ordinary entry, the unresolved `offered` envelope wins over `desired`; otherwise `desired` if it differs from confirmed. Ids owned by a conflict dependency are blocked from the ordinary path: while any requirement is unconfirmed only copy snapshots/offers are emitted; once all are confirmed the source is emitted (existing `sourceOffered`, else carrier-free `desired`, else `dependencySourceRelease`, `:1893-1925`) and copy edits/deletes stay held until the edge is pruned.
- `markOffered(_:confirmed:)` (`:1222-1271`), persisted before the transport call: sets `offered = {desired, entry.generation, confirmed.recordVersion(id)}` only when no offer exists and the envelope is the current desired version; dependency-owned ids set `sourceOffered` / `requirement.offered` instead (generation 1).
- `acknowledge(ids, confirmed:)` (`:1275-1320`), called after the base containing the accepted records is durable: clears an offer only if it is the same version as the confirmed envelope; removes the entry if desired also matches, otherwise the newer desired stays pending. For a requirement it records `acceptedRecordVersion`. Never prunes dependencies.
- `reject(ids)` (`:1325-1345`): a fetch proved the offer was not accepted; clear the offer (entry, `sourceOffered`, requirement), keep desired.
- `offeredSnapshot(for:)` (`:989-1001`) returns the exact offer (with its CAS token) for a pending envelope; `projectionKnowledge(over:)` (`:1784-1812`) overlays `offered ?? desired` and dependency snapshots on the base as projection input (tentative ancestor).
- Compaction is implicit: entries disappear at reconcile step 4 or on acknowledge; there are no size or count limits and no age-based GC.
- Scope resets (all leave `desired` intact, clear offers and CAS tokens): `prepareForAccountChange` (`:1464-1529`; also clears review ancestry and adds an entry for every live local record because the new base is empty), `prepareForNonDestructiveLibraryRecovery` (`:1540-1597`; reconciles against an empty base so absences never become tombstones, keeps journal-only entries), `prepareForTransportRekey` / `stageConfirmedForTransportRekey` (`:1350-1455`; every confirmed envelope becomes an exact offer to reseal), `forgetSecureIntent(forgottenIDs:)` (`:1742-1780`; drops secure desired, secure offers, v1 carriers and secure dependencies).
- Reviewed recovery (`:1609-1736`): `reconcileAfterReviewedLocalSnapshot(current:reviewedSnapshot:deviceID:now:)` binds `reviewedRecoveryFingerprint` to the base's review fingerprint; on a new fingerprint it resets as above, then records per entry the reviewed envelope (`reviewedLocalAncestor`, or known absence) and `preReviewMergeAncestor`; afterwards a later local absence of a reviewed-present id is a real deletion, while journal-only entries not in the review are restored. `markReviewedLocalSnapshot` never overwrites an existing review fact; `replaceReviewedLocalSnapshot` does.
- Conflict dependencies (`:98-148`, `:185-1001`), needed for conflict copies (below): `conflictDependencies[source id] = { sourceSnapshot, requirements[fingerprint] = { copyID, carrierKey?/carrierValue? (secure losing body still carried in `source.x`), snapshot? (frozen copy C0), offered?, acceptedRecordVersion? }, sourceOffered? }`. Order enforced: every copy accepted by the backend (exact snapshot + returned version) -> carriers removed from primary storage (`carrierResolutions` `:789`, `beginCarrierResolutions` `:820`, journal first) -> carrier-free source offered and confirmed -> edge pruned by `reconcileDependencies(current:confirmed:acceptedSourceIDs:discoverSecureCarriers:)` only (`:566-784`, `:1927-1953`). Other entry points: `stageConflictDependency` `:427` (before merged records reach the library), `validateDependencyOccupants` `:185`, `recordConflictCopyEvidence` `:899`, `holdPostPrerequisiteCopyIntents` `:937`, `frozenConflictCopyEvidence` `:974`, `heldConflictCopyIntents` `:882`, `conflictPrerequisiteRecovery` `:251`, `reconcileInstalledConflictPrerequisiteAbsence` `:308`, `rebaseIdenticalSourceOffers` `:379`, `recoverAcceptedPrerequisiteOffers` `:401`, `carrierSourcesAwaitingMaterialization` `:207`, `activeConflictPrerequisiteCopyIDs` `:240`. Any inconsistency throws `SyncMerge.EnvelopeFailure.malformedContentConflict` and the round stops.
- Crash safety: all mutators work on a copy; the engine persists the candidate (`persistJournal`, `snippets/Core/SyncEngine.swift:3070`) and only then publishes it. Orders that matter: journal with offers durable before any transport call; base durable before `acknowledge`; dependency staged before merged records are applied; journal durable before install receipts are trimmed (`SyncEngine.swift:3079-3083`). Every step is idempotent on restart (steps 1 and 2b above, `recoverAcceptedPrerequisiteOffers`).

### Library transaction, lock and generation
- `LibraryWriter.update` (`snippets/Core/LibraryGeneration.swift:140-241`): acquire guard (timeout -> `busy`); loop up to 24 times: read on-disk snapshot -> `transform(snapshot)` -> encode -> if bytes equal on-disk bytes return without writing (`foldedInForeignWrite = expectedDigest != nil && expectedDigest != current.digest`) -> re-read, digest must be unchanged -> atomic write -> re-read, digest must be ours -> `bumpGeneration` -> return. A missing file is `Snapshot.missing` (`fileExisted = false`), which callers must not treat as "peer deleted everything" (`:49-63`); a present but undecodable or unreadable file throws `unreadable` and is never treated as empty (`:111-129`).
- `bumpGeneration` (`:374-387`): only if `state.json` loads; `+1`, plus another `+1` (a visible gap) when the previously recorded digest differs from the non-empty digest observed before writing; stores the new digest. No-op updates do not bump (`Tests/Core/LibraryWriterTests.swift:810-886`).
- `replaceQuarantinedPrimary` (`:249-342`): same loop without decoding the current file; preserves existing bytes as `recovery-preserved-<uuid>` first.
- `LibraryTransaction.perform` (`snippets/Core/LibraryTransaction.swift:101-245`): acquire guard; up to 12 attempts: read library (`libraryUnreadable` on failure) and vault (`tooNew`/`unreadable`/`corrupt` -> `vaultUnreadable`, missing -> `nil`); run `body(&contents)`; nothing changed -> return, no writes; raw-byte CAS on both files else retry; encode the library before any write; choose the plan (`:251-277`) from actual id movement: ids leaving the library and present in the new vault = promotion -> write library + retained plaintext sources of the promoted ids, marker, vault, final library; ids leaving the vault into the library = demotion -> library, marker, vault; otherwise the marker decides (`demoting` -> library first, else vault first); finally clear the marker. A `nil` vault after the body removes `vault.json`.
- Marker = `state.json` `promoting` / `demoting`, best effort (`:309-324`). Recovery at next launch: `pendingMarker()` (`:327-332`) is read by `SecureSnippetStore.reconcileAfterCrash` (`snippets/Vault/SecureSnippetStore.swift:2213`); default rule "vault copy wins" completes a promotion, a `demoting` marker flips it to "plaintext copy wins" (`:31-42`). Failure injection pinned in `Tests/Core/LibraryTransactionTests.swift:87-262`.
- Multi-process only (Mac app + `snippets-cli` + shared debug/release directory): `flock` and inode revalidation, the `link(2)` sentinel with pid/start-time liveness, `SNIPPETS_DISABLE_FLOCK`, `wroteWithoutLock`, the recheck/confirm retries, the generation gap, lock timeouts (0.25 s store, 2.0 s bridge and engine state lock: `snippets/SnippetStore.swift:369`, `snippets/Sync/SnippetLibraryBridge.swift:57`, `snippets/Core/SyncEngine.swift:437`). Still required with one process: one mutex spanning library, vault and state; read-inside-lock before transform; no-op suppression; write ordering and marker; missing/unreadable/empty distinction; `updatePersistedHalt` CAS on the previous halt.

### Three-way merge

Two merges share the per-field rules. Both are pure and take no device identity. Invariants (`SyncMerge.swift:82-90`): absence is never a delete without proof; an edit always beats a delete; a body both sides changed is never discarded.

**Shared field rules**

| Field | Rule | Pointer |
|---|---|---|
| name, keyword, isEnabled, isPinned | `mergeScalar`: `local == remote` -> local; else `local == base` -> remote; else `remote == base` -> local; else the ranked winner. With no base the last branch decides. | `:345` |
| tags | `mergeTags`, identity = `SnippetTagging.filterKey`. With base: kept = base keys present on both sides, in base order, spelled as the winner spells them (else the other side, else base); added = keys new on either side, appended in ascending key order, winner's spelling first; then `normalizedTags`. Without base: winner's list verbatim + the other side's tags whose key the winner lacks, then `normalizedTags`. | `:363-412` |
| createdAt / updatedAt | `min(local, remote)` / `max(local, remote)`, always. | `:330`, `:729` |
| content | See each merge below. | |
| id | Never changes. | |

Pinned examples (`SyncMergeTests.swift:525-575`): `mergeTags(["work"], ["Work","extra"], ["work"], localWins: true) == ["Work","extra"]`; `(["café"], ["Cafe"], ["café","x"], true) == ["Cafe","x"]`; `(["work"], ["Work"], ["WORK"], false) == ["WORK"]`; `(nil, ["a"], ["b"], true) == ["a","b"]`; base `["work"]`, local `["Work","urgent"]`, remote `["work","draft"]`, remote wins -> `["work","draft","urgent"]`.

**Local-file merge `mergeLocal(base:local:remote:)`** (`:138`): `local` = in-memory array, `remote` = array now on disk, `base` = last bytes this process saw. Duplicated ids keep the first occurrence (`:143`).

| local | remote | Result (`mergeRecord` `:242`) |
|---|---|---|
| absent | absent | nothing |
| absent | R | deleted only if base exists and `payloadEquals(base, R)`; otherwise R survives |
| L | absent | deleted only if base exists and `payloadEquals(base, L)`; otherwise L survives |
| L | R, `payloadEquals` | L with `createdAt = min`, `updatedAt = max` |
| L | R, different | per-field merge; `localWins = localOutranksRemote` |

- `payloadEquals` compares name, keyword, content, tags, isEnabled, isPinned only (`:118`). A re-save that only moved `updatedAt` is not an edit and does not outrank a delete (`SyncMergeTests.swift:177`).
- Rank (`:294`): later `updatedAt` wins; exact tie -> the side whose `payloadDigest` hex string is smaller. The tie-break comes from the data, so mirrored inputs agree.
- Content (`:419`): equal -> keep; one side equals base -> other side; both changed -> winner's body stays and the loser becomes a conflict copy: id = local-file copy id, name = `"<loser.displayName> (conflict <UTC stamp>)"`, `keyword = ""`, `isEnabled = false`, `isPinned = false`, `tags = normalizedTags(loser.tags + ["conflict"])`, loser's content and dates.
- Output order (`:485`): survivors in local order, then remote-only records in remote order, then anything left (conflict copies) by ascending `uuidString`. `Outcome.conflictCopies` is sorted the same way (`:161`).
- Keyword collisions (`:523`), local-file merge only; the envelope merge never disables anything. Candidates are "touched" records: conflict copies plus every output record that is new or not `payloadEquals` to its local version (`:172-176`). Walk untouched records first, then touched, each in array order; consider only enabled records with a non-empty `filterKey(normalizedKeyword)`. The first holder of a key is the incumbent. If neither record is touched, leave both alone. Otherwise later `updatedAt` wins, tie -> smaller `uuidString` wins; the loser gets `isEnabled = false` and keeps its keyword. `Outcome.needsUserAttention` = any copy or any disabled record (`:108`).
- `rebaseSnapshot(snapshot, from: capturedAgainst, onto: merged)` (`:197`) is not a merge. `deleted` = ids in `capturedAgainst` missing from the snapshot; `changed` = snapshot records absent from `capturedAgainst` or not `payloadEquals` to it. Result: `merged` in order, minus `deleted`, with `changed` substituted; then snapshot records that are in `changed` and not yet emitted. Records the snapshot merely carries are never re-added (that would restore a snippet that was moved into the vault).

**Envelope merge `mergeEnvelopeOutcome(base:local:remote:)`** (`:648`) returns `EnvelopeOutcome{survivor, conflictCopies}` or throws `EnvelopeFailure.malformedContentConflict` / `.unresolvedContentConflictDeletion`. Every non-nil input is first run through `validateContentConflictExtensions`.

| local | remote | Survivor |
|---|---|---|
| nil | nil | none |
| nil | R | R, whatever base says (absence is never a delete here; deletions arrive as tombstones from the journal) |
| L | nil | L |
| tombstone | tombstone | the higher-ranked one; throws `unresolvedContentConflictDeletion` if base carries any `contentConflict.*` key |
| tombstone T | live V (either order) | V if base is nil or `V.envelopeHash() != base.envelopeHash()`; else T. If T survives and `(base ?? V)` carries `contentConflict.*`, throw. |
| live | live, `fields` equal and `secure` equal | winner's id, hlc, origin, secure, fields; `x` = union of both bags, winner's value on a shared key. Secure: `vaultContentHash` and `vaultKID` = winner's, else the other side's (legacy backfill). Plain: both keys removed. No copy. |
| live | live, otherwise | field merge below |

- Rank (`:826-859`): identical envelopes -> local; else higher `HLC`; equal HLC -> the envelope whose full canonical bytes, computed with all `contentConflict.*` members removed from `x`, sort first as unsigned bytes; equal -> remote.
- Field merge: scalars and tags as above with base `fields`. Survivor `id = local.id`, `hlc = max(local.hlc, remote.hlc)`, `origin = winner.origin`, `deleted = false`, `x` = union with winner preference (`:772`). The survivor and each copy are validated again; an output over budget throws.
- Content is compared by content key, never by bytes (`:814`): secure with `x.vaultContentHash` text -> `"secure:<x.vaultKID or "legacy">:<hash>"`; secure without -> `"secure:legacy:<sha256(content)>"`; plain -> `"plain:<sha256(content)>"`. Representation is part of identity, so promotion-versus-edit is a conflict.
- Body selection (`:745-765`): keys equal -> winner's body; `base == remote` -> local's; `base == local` -> remote's; otherwise winner's body and the loser is preserved (plain loser -> conflict copy, secure loser -> variant member added to the survivor's `x`).
- `secure`, `vaultContentHash` and `vaultKID` follow the selected body, not the HLC winner; a plain result removes both keys (`:775-786`, `SyncLibraryProjectionTests.swift:195,238`).
- `SyncEnvelope.init` strips `userDeletion.v1` from any live envelope and normalises `origin` (`SyncEnvelope.swift:1025-1044`), so a merged survivor never carries a deletion proof.

### Conflict copies

**Plain loser** -> `makePlainContentConflictCopy(from: loser)` (`:864`), a function of the exact losing envelope only:
- `id` = copy id; `hlc` and `origin` = the loser's; `secure = false`.
- Fields = the loser's, except `name` = conflict name, `keyword = ""`, `isEnabled = false`, `isPinned = false`, `tags = normalizedTags(tags + ["conflict"])`. Body, `createdAt`, `updatedAt` unchanged.
- `x` = the loser's `x` minus `contentConflict.*`, `vaultContentHash`, `vaultKID`, plus the provenance marker.
- Display name for the conflict name: `name` trimmed of whitespace and newlines if non-empty; else the first non-blank line of the body, trimmed, cut to 50 Characters plus `"…"` when longer; else `"Untitled Snippet"` (`Snippet.swift:53-58`, `:445-498`). English, never localised.
- A loser whose body is not valid UTF-8 throws `malformedContentConflict` (`:867`).

**Secure loser** -> no record is created (the seal is AEAD-bound to the source id). The survivor gains `x["contentConflict.v1.<fingerprint>"]`. Members are independent keys so a shallow dictionary union by an unaware client keeps all of them; a later conflict adds a member and never embeds earlier ones (`SyncConflictCopyTests.swift:688,761`). A secure loser lacking `vaultContentHash` or `vaultKID` fails the survivor's own validation, so the merge throws.

**Gold vectors** (`snippets-linux/tests/fixtures/conflict-copy-v1.json`, checked by `SyncConflictCopyVectorTests.swift:35`; source id `a11ce002-0000-4000-8000-000000000001`, name and keyword `race`, tags `["audit"]`, `createdAt` 808272000.0):

| Source hlc / origin | content | updatedAt | fingerprint | copy id | copy envelope hash |
|---|---|---|---|---|---|
| `01a102dd652b-0000-64578a60` / `64578a60` | `audit-concurrent-macos` | 812742226.219845 | `ce1a2145e0e38826d82447c8372b559edcd3d42f11c11d7f5acb35c27c28f451` | `5d85adc5-ec1a-50ac-a9eb-0d5ea53fcf39` | `6cfa9a242c379e5206a241f2ed52bac2fa2c01573979f72ea4dc3aec162de006` |
| `01a102dd76b4-0000-a11d1701` / `a11d1701` | `audit-concurrent-linux` | 812742230.7082067 | `1b1fad829f53ae6118d243e33b83db0a0dd0de6eaba597a0c9187b92d4498d69` | `4e4e8edf-0082-5883-9b4f-52d464306c04` | `56ce21baff287dc1ffa8fff482a81ac2e5728046e506f892ff59166e512e20c6` |

Both copies are named `race (conflict 2026-10-03 17:43 UTC)`, tagged `["audit","conflict"]`, with `x = {"conflictCopy.v1":{"fingerprint":…,"sourceID":"a11ce002-…","version":1}}`. The Kotlin port must reproduce each `copy` string in the fixture byte for byte from its `source`. Merging the first vector as local or as remote yields the same copy bytes (`:49`).

**Validation of reserved keys** (`validateContentConflictExtensions` `:1032`, `secureContentConflictVariants` `:947`):
- Whole envelope canonical bytes <= 674,815; a tombstone carries no `contentConflict.*` key; at most 128 `contentConflict.*` members; sum of key bytes + canonical value bytes <= 524,288.
- Key grammar: `contentConflict.v<1-3 ASCII digits>.<64 lowercase hex>`. Anything else, including the sentinel `contentConflict.invalid`, is malformed.
- A `v1` member must be an object with exactly `version, copyID, sourceID, sourceHLC, sourceOrigin, secure, fields, x`; `version` int 1; `secure` true; both ids canonical lowercase; `sourceID == envelope.id`; `sourceHLC` parses; `sourceOrigin` is a canonical device id; `fields` parses; inner `x` has exactly `vaultContentHash` and `vaultKID`, both text of <= 256 UTF-8 bytes; the recomputed fingerprint and copy id match. Variants are returned sorted by key.
- Other versions are opaque: preserved, count toward the limits, keep the record "unresolved" and block its deletion (`hasUnknownContentConflictVersion` `:1017`).
- `hasValidConflictCopyIdentity` (`:1124`): provenance parses and `id == UUIDv5(sourceID, "sync-content-conflict-v1|" + fingerprint)`. `isMatchingPlainConflictCopy(e, candidate:)` (`:1073`): same id and equal `conflictCopy.v1` value; fields may differ, so a user-edited copy still matches.
- `resolvingContentConflicts(in:expected:)` (`:1133`) removes the given `v1` members only if the envelope is live and each key still holds exactly the expected value; otherwise nil.

**Ordering and dependency rules** (enforced by the engine and journal; pinned by `SyncConflictOrderingTests`, `SyncConflictDependencyTests`):
1. Copy before source. The journal records a copy -> source edge before the merged records reach primary storage (`SyncJournal.swift:427`). The copy is submitted alone first; the source is offered only after the backend accepted that exact copy, and carries no dependency state on the wire (`SyncConflictDependencyTests.swift:217,657`). Survives restart.
2. The first offer of a copy is the frozen generated snapshot (C0). A user edit or delete of the copy before its first ACK stays later intent (`:233`); deleting source and copy uploads the copy live first, then the tombstones (`:726`).
3. A later version with matching provenance (C1) or a copy tombstone never proves C0 was accepted; only an acceptance receipt (the returned record version for C0) does (`:2584,2830`). Account reset or wire re-key clears receipts and re-orders copy first (`:2850,2957`).
4. A copy id is reserved. A live record at that id, local or fetched, that is not `isMatchingPlainConflictCopy` halts with `localLibraryQuarantined` before anything is applied, in either arrival order, and even after the dependency was pruned or the copy was deleted but its tombstone not yet acknowledged (`SyncEngine.swift:1916-1941,2008-2044`; tests `:265,321,425,524`).
5. A fetched record at the copy id that matches is merged with the pristine generated copy as its base, so a user-edited copy is not a second conflict; if that merge would itself produce a copy, halt (`SyncEngine.swift:2011-2031`, `SyncConflictOrderingTests.swift:249`). An existing local matching copy is kept as is, never overwritten by redelivery.
6. Only the last generation of an id in a fetched batch is merged (`SyncConflictOrderingTests.swift:217`). Idempotence: re-fetching everything and redelivering pages three times changes nothing and uploads nothing (`SyncConflictCopyTests.swift:550`). Equal-HLC conflicts converge to the same library in either submit order (`:518`).
7. A merged output over the payload budget halts with `localLibraryQuarantined` before the primary write; the cursor is not acknowledged and base is unchanged (`SyncConflictPayloadBudgetTests.swift:129`).

**Restored copies** (`SyncLibraryProjection.swift:205-241`). A tombstone carries no `x`, so a deleted plain copy would lose its provenance. `projectionSidecar(for: current, replacing: previous)` = every current envelope, plus, for each id in `previous` that is gone from `current`, a body-free tombstone `{same id, hlc, origin, secure: false, x: {conflictCopy.v1}}` if the previous entry was a non-secure envelope with a valid copy identity (a previous tombstone is carried forward only if it already has exactly that shape). Keep the 256 newest by HLC descending, then `uuidString` ascending. It never leaves the device. When the copy returns (undo, restored file), projection merges this memory in as weaker knowledge and the copy is re-published with its provenance, a clock above the tombstone, and this device as origin (`SyncRestoredConflictCopyTests.swift:244,436`).

### Projection

`currentEnvelopes` (`:39`) maps every snippet and vault record to one live envelope. Tombstones are never produced here. Inputs: `metadata` = the projection sidecar, `agreedBase` = the confirmed base.

- No field is local-only: all eight non-id fields travel. Not stored in `snippets.json`: HLC, origin, `x` (kept in the sidecar). There is no position field; array order is local and presentation order is computed.
- Plain fields: `name`, `keyword = snippet.normalizedKeyword`, `content` = UTF-8 bytes, `tags`, flags, both dates (`:50-54`).
- "Exact" (`exactPlain` `:374`): candidate is live, not secure, and equals primary on name, sanitized keyword, body bytes, `normalizedTags` of both tag lists, flags, and both dates (exact double equality).
- Knowledge merge (`mergedKnowledge` `:521`): take the envelope with the higher HLC (sidecar on a tie), then union both `x` bags; on a shared key with different values the agreed base wins, except `contentConflict.*` and `conflictCopy.v1`, where a disagreement adds the sentinel `x["contentConflict.invalid"] = null` so validation fails closed.
- If the sidecar and/or base candidates are exact: reuse the merged knowledge unchanged (same HLC and origin), with `vaultContentHash`/`vaultKID` removed for a plain record (`:60-68`).
- Otherwise it is a local edit: new envelope with `origin = deviceID`, `x` = merged knowledge of the non-exact candidates (minus the two vault keys), `hlc = localClock` (`:557`): `wall = max(updatedAt ms, ancestor.wallMs + 1)` capped at `0xFFFF_FFFF_FFFF`; `counter = 0`, or `ancestor.counter + 1` (saturating at 65535) only when `wall == ancestor.wallMs`; device = normalised device id. No ancestor: `wall = updatedAt ms`. Deterministic, so reading twice mints one revision (`SyncLibraryProjectionTests.swift:136`).

### Secure records

- The engine and merge never see plaintext. A secure envelope's `content` is the UTF-8 of the vault's `sealed` string; `x.vaultContentHash` carries the vault's keyed hash and `x.vaultKID` the vault id (`:89-95`, `:166-171`). Sync works while the vault is locked.
- Projection of a `VaultRecord`: keyword taken as stored. Exact (`exactSecure` `:397`) additionally requires `x.vaultContentHash == record.contentHash` (absent when empty), `x.vaultKID == vaultKID`, the candidate's `contentConflict.*` members equal to those decoded from `record.x`, and equal provenance. An unstamped legacy envelope is therefore re-projected once with the stamp (`SyncLibraryProjectionTests.swift:84`).
- Non-exact secure projection (`:109-181`): start from merged knowledge `x` minus `contentConflict.*` and `conflictCopy.v1`; restore each carrier from `record.x` (base64 -> canonical value under `contentConflict.<suffix>`); legacy direct `contentConflict.*` members are converted; an undecodable carrier, a clash between two encodings, or unparsable provenance adds the invalid sentinel; set or remove the two vault keys. Clock: keep `record.hlc` when its device is this device and it is above the ancestor, else `localClock`.
- `vaultRecord(from:preserving:)` (`:245`): nil for plain; a tombstone is only validated; non-UTF-8 body throws `invalidSecureBody`; a variant whose `vaultKID` differs from the envelope's throws `incompatibleSecureConflictVault`. `contentHash = x.vaultContentHash ?? (existing hash if sealed is unchanged) ?? ""`, never the wire SHA-256. `x` = the existing record's unrelated keys + one carrier per current `contentConflict.*` member + provenance if valid. Stale carriers are dropped, so applying a resolved envelope removes them (`SyncSecureConflictVariantDurabilityTests.swift:339`).
- `matchesExactSecurePrimary` (`:433`) = exact and `envelope.hlc == record.hlc`; the legacy form first adds this vault's `vaultKID`. These let an already-filed secure record pass while locked.
- Materializer contract (`SyncSecureConflictMaterializer.swift:28`). For each `v1` variant, in key order: variant `vaultKID` must equal the local vault id, else `incompatibleVault`; a plain snippet at the copy id, more than one record at it, or a record there without the exact provenance -> `identifierCollision`; an existing matching copy is authenticated (open under its own id, keyed hash equals its `contentHash`) and left untouched, including user edits; open the losing seal under `(vaultKID, sourceID)`, require keyed hash == variant `vaultContentHash` (`contentHashMismatch`), reseal under `(vaultKID, copyID)`.
- The new record: `id = copyID`, `name = "<name, or "Untitled" if empty> (conflict <UTC stamp>)"` (name not trimmed, body never previewed), `keyword = ""`, tags + `conflict`, disabled, unpinned, source dates, `hlc = sourceHLC`, `contentHash` = variant hash, `x = {conflictCopy.v1}`. Its projected envelope has exactly `vaultContentHash`, `vaultKID`, `conflictCopy.v1` in `x` and must fit the wire budget.
- Result: `records` (existing + new copies), `materializedIDs` (sorted), `evidenceRecords` (one freshly sealed C0 per variant, sorted by id). Any reserved-key validation failure maps to `malformedVariant`. `validatePreparedEvidence` (`:184`) accepts evidence only if it authenticates and equals the derived C0 in hlc, origin, keyed hash, name, empty keyword, tags, flags, dates and the exact three `x` keys; ciphertext is not compared (random nonce).
- Durability: the source keeps its variant member after materialisation; the journal removes it (`resolvingContentConflicts`) only once the copy is confirmed by the backend (`SyncSecureConflictMaterializationContractTests.swift:43`). The variant is mirrored into `vault.json` as a carrier so losing both sync sidecars cannot drop the only copy of the losing body. A record with an unresolved variant is never turned into a tombstone by local absence (`SyncSecureConflictVariantDurabilityTests.swift:505,548`). Plaintext is wiped after use (`:247`).

### Constants (merge layer)

| Name | Value | Pointer |
|---|---|---|
| `SyncDeletionSafety.floor` | 5 | `SyncMerge.swift:15` |
| `allowedDeletions(liveCount)` | `max(5, (max(0, n) * 2 + 9) / 10)` (20 % rounded up); review when deletions exceed it | `:23`, `:34` |
| `contentConflictExtensionPrefix` / `V1` | `"contentConflict."` / `"contentConflict.v1."` | `:591-592` |
| `contentConflictOpaqueCarrierPrefix` | `"contentConflictOpaque.v1."` | `:593` |
| `plainConflictCopyExtensionKey` (= materializer `provenanceExtensionKey`) | `"conflictCopy.v1"` | `:594`, `SyncSecureConflictMaterializer.swift:26` |
| `maximumContentConflictVariantCount` | 128 | `:595` |
| `maximumContentConflictVariantBytes` | 524,288 | `:599` |
| `maximumWireCanonicalBytes` | 674,815 (seals to 899,796 bytes; one more byte seals to 900,138) | `:606`, `SyncConflictPayloadBudgetTests.swift:98` |
| `maximumRetainedCopyIdentities` | 256 | `SyncLibraryProjection.swift:190` |

## 5. Coordinator and store layer (as wired on iOS)

### Object graph on iOS
Built once, on the main actor, in `AppEnvironment.init` (`snippets-ios/AppEnvironment.swift:79`–`188`), in this order: `DiagnosticsService.shared` → `SnippetStore(configuration: .iOS)` → `KeychainSecretStore` → `SyncBackendSelectionStore(defersCredentialRecovery: true, gitSSH: …)` → `SnippetsCloudAccountBootstrap` → `VaultSession` → `SecureSnippetStore(deviceID: store.deviceID)` → `SnippetLibraryBridge(store:, secureStore:)` → `SyncCoordinator(library: bridge, keys: SyncKeyStore(…), device: store.deviceID, preparesKeyInBackground: true, backendSelection:)` → `SnippetActionService`.

- Wiring (`:180`–`188`): `store.secureProvider = secureStore`; `store.syncDelegate = syncCoordinator`; `secureStore.onChange` forwards to `store.onChange` (`.local` inside `performLocalSecureChange`, else `.external`) and calls `syncCoordinator.libraryStructureChanged()`; then `secureStore.reconcileInterruptedMove()`. `SyncKeyStore` reads the selection through closures (`usesSnippetsCloud`, `gitScope`), so one key store serves whichever provider is selected at call time (`:158`–`166`).
- Isolation: store, bridge, coordinator, selection store and engine are all `@MainActor`. Off-main work: the persistence worker (serial utility queue, `snippets/SnippetStore.swift:128`), projection CPU (`SyncEngine.offMainActor`, `snippets/Sync/SnippetLibraryBridge.swift:100`), key preparation (`snippets/Sync/SyncCoordinator.swift:1753`), transport I/O.
- Observers: `store.onChange` is one slot, set by the root controller (`snippets-ios/PhoneRootViewController.swift:34`, `MainSplitViewController.swift:101`); sync state has many observers via `addStateObserver`, each called immediately with the current state (`SyncCoordinator.swift:599`). The coordinator's initialiser activates the provider's protocol locations and restores a local-recovery engine if the library is quarantined (`:492`–`496`); it does not start sync.

### Store API and mutation flow
Every mutator first checks `isLibraryQuarantined` (no-op/`false`/`nil`, or throws `libraryRecoveryRequired`). "Immediate" = synchronous locked write before returning; "debounced" = 0.3 s trailing.

| Operation | In-memory change | Undo | Persist | Sync delegate |
|---|---|---|---|---|
| `addSnippet(name:content:tags:)` (`SnippetStore.swift:553`) | New `Snippet` (keyword `""`, tags normalised) inserted at index 0; remembered as blank draft if name, keyword, content, tags are all empty | push | immediate | `libraryDidChange(.local)` |
| `discardBlankDraft(id:)` (`:598`) | Removes the remembered draft only if still blank; pops its creation undo entry if it is still on top; erases the id from every undo/redo level and drops levels that became identical to their successor | none pushed | immediate | same |
| `update(_:)` (`:656`) | keyword := `sanitizedKeyword`, tags normalised; no-op unless name/keyword/content/tags/isEnabled/isPinned differ; `updatedAt = now`; `createdAt` and id untouched | push, unless an edit transaction is open (then only redo is cleared) | debounced | same |
| `delete(snippetID:)` (`:690`) | remove | push | immediate | `userDidDeleteSnippets([id])` before the write, then `libraryDidChange` |
| `deleteForUndo(snippetID:)` → token (`:708`) | remove; remembers (snippet, original index); older tokens for the same id are invalidated; at most 50 tokens, oldest dropped | push | immediate | as `delete` |
| `restoreDeletedSnippet(using:)` (`:736`) | Token consumed first; no-op if the id exists again; insert at `min(originalIndex, count)`; other edits made since are kept | push | immediate | `userDidRestoreSnippets([id])` |
| `duplicate(snippetID:)` (`:782`) | Copy inserted at `index + 1`; name = trimmed name + `" Copy"` (empty stays empty); same keyword, content, tags, pin; disabled when the source is enabled and has a keyword; new id and dates | push | immediate | change only |
| `togglePinned`, `toggleEnabled` (`:808`, `:819`) | flip; `updatedAt = now` | push | immediate | change only |
| `toggleTag(_:snippetID:)` (`:856`) | Remove the tag whose `SnippetTagging.filterKey` matches, else append; normalise; `updatedAt = now` | push | immediate | change only |
| `undo()` / `redo()` (`:1836`, `:1849`) | Whole-library snapshot swap (50 levels, `:403`) | — | immediate | `userDidDeleteSnippets(before − after)`, `userDidRestoreSnippets(after − before)` |
| `importSnippets(_:options:)`, `importSharedSnippet(_:)` (`:951`, `:999`) | Preflight, normalise, upsert (below) | one push | immediate | change only |
| `replaceQuarantinedLibrary(with:)` (`:981`) | Only while quarantined; replaces the whole library through `LibraryWriter.replaceQuarantinedPrimary`; clears undo; rolls back memory on write failure | cleared | immediate | change only |

- Edit transaction (`:1780`–`1834`): `beginEditTransaction` snapshots the library; `commitEditTransaction` pushes that snapshot once if anything changed. A discrete action during a transaction pushes the transaction baseline first, then the pre-action state, and the transaction restarts from the post-action state. The store does not reject a duplicate keyword on `update`; uniqueness is enforced only on import and by merge (`disabledByKeywordCollision`). The editor warns (`snippets-ios-tests/SnippetsIOSTests.swift:457`).
- Import (`:1270`–`1386`, `:1036`–`1056`): (1) file-level conflicts: duplicate id, duplicate non-empty keyword compared by `SnippetTagging.filterKey(normalizedKeyword)`; (2) normalise: keyword sanitised, tags normalised, a repeated id gets a new UUID, `updatedAt := max(updatedAt, createdAt)`; (3) merge conflicts against plaintext + secure shells: same id as a secure snippet, keyword owned by a secure snippet, or id matches one record while the keyword belongs to another; at most 8 messages are reported (`:1361`), and any conflict aborts the whole import; (4) upsert each: same id → replace in place; else same keyword → replace in place keeping the existing id and `createdAt`; else insert at index 0. Empty import throws `emptyImport`. Return value is the number of incoming records.
- Reads: `snippets` (file order, plaintext only); `snippetsSortedForDisplay()` (`:880`) = plaintext + secure shells ordered by `SnippetDisplayOrder`: pinned first, then `createdAt` descending, then `id.uuidString` ascending (`snippets/Core/Snippet.swift:88`–`101`); `enabledSnippetsSorted()` (`:900`) = enabled plaintext with a keyword, longest keyword (Character count) first, then `updatedAt` descending; `snippetForDisplay(id:)`, `isSecure`, `allTags`, `tagUsage`, `allTagKeys`.
- `persist` (`:1388`–`1418`): bump `persistenceStateVersion`, set `needsPersistence`, cancel the pending timer, then write (immediate) or schedule (debounced), and only then publish `notifyChanged(.local)` (`librarySeq += 1`, `onChange`, `syncDelegate.libraryDidChange`, `:1683`). Observers run synchronously and may re-enter the store.
- Applying a worker result (`:1542`–`1639`): if memory still equals the request and the worker merged a foreign write, adopt that merge; else if memory differs from what was written, reconcile with `SyncMerge.mergeLocal(base: request.local, local: memory, remote: written)`. `needsPersistence` clears only when the state version is unchanged, no newer disk observation happened and memory equals the written list. Undo/redo/transaction snapshots are rebased with `SyncMerge.rebaseSnapshot` when `(undo + redo levels) × max(count, 1) ≤ 20 000`, otherwise cleared (`:2011`–`2029`).
- Failure: retry after `min(0.25 s × consecutive failures, 2 s)` (`:1643`); from the second failure the delegate is told. `flushPendingWrites()` (background, `AppEnvironment.swift:245`): drain, then 3 synchronous attempts with a 5 s lock timeout and 0.1 s pauses, then the `unsaved-*` rescue file (`:1695`–`1741`). `flushPendingWritesForSync()` (bridge): 3 attempts at 0.25 s, then throws `primaryLibraryWriteFailed` and sync stops before journaling (`:1753`–`1776`).

### Round triggers and pacing
All requests go through `enqueueSyncRequest` (`SyncCoordinator.swift:1043`), which first cancels the pending local-change debounce. One round runs at a time; requests during a round set one coalesced replay (`SyncRoundRequestCoalescer`, `:8`); `requestSync` completes after the round that covers it. Only `.manual` bypasses engine backoff (`:1050`), and a queued manual request keeps that right for its replay (`:1136`).

| Trigger (`DiagnosticSyncTrigger`) | Source | Unpaced provider | Paced provider (Git: `roundPacing`) |
|---|---|---|---|
| `.startup` | `AppEnvironment.start()` → `startIfEnabled()` (`AppEnvironment.swift:191`–`214`), end of every successful `start` (`SyncCoordinator.swift:772`) | immediate | immediate |
| `.localLibraryChange` | `libraryDidChange(.local/.external)`, `libraryStructureChanged()` (`:940`–`955`); `.remoteSync` is ignored | 1 s trailing debounce (`:234`) | `localChangeDelay` 30 s, at most `localChangeMaximumWait` 120 s after the first change of a burst (`:978`; `snippets/Core/Git/GitSyncTransport.swift:121`,`:123`) |
| `.becameActive` | `AppEnvironment.becameActive()` (`:220`–`240`): reloads the vault; a changed vault publishes one library change instead | runs | skipped while a local change waits, or within `activationRefreshInterval` 30 s of a successful round (`:992`–`1001`; `GitSyncTransport.swift:126`) |
| `.poll` | repeating timer every `transport.pollInterval`, tolerance interval/4 (`:1876`); transport events `changesAvailable`/`cursorInvalidated` (`:1903`) | runs (Snippets Cloud 60 s, CloudKit 6 h) | timer tick skipped while a local change waits (`:1891`); Git 60 s (`GitSyncTransport.swift:114`) |
| `.retry` | offline deadline from `SyncEngine.State.offline(retryAfter:)` (`SyncOfflineRetryScheduler`, `:93`, `:1917`); event `authenticationRequired`; after `performRecovery`; replay round | at the deadline | same |
| `.manual` | Sync Now, pull-to-refresh, provider switch, Git setup | immediate, bypasses backoff | same; never paced |
| background flush | `enteredBackground()` → `flushPendingLibraryChangeSync` under a background task (`AppEnvironment.swift:242`–`261`, `SyncCoordinator.swift:1009`) | nothing (1 s debounce left alone) | the waiting change's round starts at once |
| start retry | 60 s repeating timer, tolerance 15 s, only for `retryablePrerequisite` start failures (`:789`) | — | — |

- The debounce measures the burst from system uptime (`:63`). The engine is created with `followUpRoundsAfterSettledOffers = SyncEngine.productionFollowUpRounds` (2) (`:727`; `snippets/Core/SyncEngine.swift:1141`).
- `start` (`:649`–`774`), in order: resolve `protocolLocations`, create directories, `library.activateProtocolLocations`, validate base/journal/state (`:1347`), obtain key material, build the sealer, `discardAgreedBaseIfWireKeyChanged`, build the transport, build the engine, seed pending deletion ids, publish a restored halt, start poll timer and event pump, request the startup round. Any failure maps to a `StartIssue` and no engine exists.
- `stop` (`:802`–`845`) bumps `lifecycleGeneration`, cancels timers and the round task, drops the engine, completes all waiting requests with `.completed(.disabled)`, and keeps a shutdown task that awaits key preparation, the old round, then `transport.shutdown()`; `start` refuses to run until it finishes, then restarts if still enabled.
- After a round (`:1793`–`1865`): complete the provider switch if this was its first successful round; if the preference was turned off inside the round → `stop`; if `engine.requiresTransportRestart` → `reloadProviderSelection`; else start the replay if one was requested. Before each round on iOS the key is re-read off the main thread; if it differs from the active one the coordinator stops and restarts (`:1719`, `:1740`).

### Status model
`SyncEngine.State` (`snippets/Core/SyncEngine.swift:308`) is the only state the UI observes; `SyncCoordinator.statusDescription` (`:1958`–`2047`) is the one sentence shown in Settings.

| State | Settings sentence | Phone banner (`snippets-ios/PhoneLibraryViewController.swift:2189`) |
|---|---|---|
| preference off | "Off. Your snippets stay on this device." | hidden unless a local recovery is pending (`:611`) |
| `.disabled` (enabled, before first state) | "Starting…" | "Preparing cloud sync…" / first fetch: "Preparing the first cloud fetch…" |
| `.idle(nil)` | "On. Nothing synced yet." | "Waiting to fetch your cloud library…" / "<Provider> on · Not synced yet" |
| `.idle(date)` | "On. Last synced at <short time>." (today) or "On. Last synced <medium date, short time>." | "Synced at <short time>" |
| `.syncing` | "Syncing…" | spinner, "Syncing changes…" / "Fetching your cloud library…" |
| `.offline(retryAfter)` | "Cannot reach <Provider>. Trying again at <short time>." | "<Provider> unavailable" / "First sync paused" |
| `.needsAuthentication(code)` | "<Provider> needs attention: <mapped>." (`:2065`) | status sentence |
| `.needsAttention(code)` | "Sync needs attention: <mapped>." + " Fix the reported condition, then try again." unless the code starts with `git_` (`:2024`, `:2097`) | status sentence |
| `.waitingForVault(detail)` | "Waiting: <detail>." with Git-specific guidance (`:2030`) | status sentence |
| `.halted(reason, detail)` | "Stopped because <reason.title>: <closed detail>. <reason.guidance>" (`:2049`, `:2168`) | status sentence; `schemaTooNew` → "Update Snippets to resume sync" |

- The `code` strings (`git_http_401`, `git_key_required`, `record_too_large`, `quota_exceeded`, …) are a closed vocabulary mapped at `:2065`–`2166`; unknown codes fall back to "Sign in again to continue" / "The cloud service rejected a change". Port the tables verbatim. `Readiness` (`:254`): `off`, `cannotStart(String)`, `ready`. `StartIssue` (`:370`) → state: `schemaTooNew`/`checkpointUnreadable` → `.halted`; `authenticationRequired`, `gitCredentialRequired` → `.needsAuthentication`; `cloudKeyRequired`, `gitKeyRequired`, `gitConfigurationRequired`, `syncKeyUnreadable`, `cloudCredentialsUnreadable`, `providerSwitchUnreadable`, `retryablePrerequisite`, `iCloudUnavailable` → `.needsAttention(<code>)` (`:413`–`444`). Error → issue mapping at `:1307`–`1341`.
- UI action selection, identical in the phone menu, banner, empty state and Settings (`PhoneLibraryViewController.swift:248`–`296`, `snippets-ios/SettingsViewController.swift:668`): `recoveryAction != nil` → the recovery button; else `canRequestManualSync` (`:582`: enabled, no maintenance, state in disabled/idle/syncing/offline) → "Sync Now"; else `requiresSyncSettingsAttention` → "Open Sync Settings"; sync off → "Connect <Provider>".
- `SyncRecoveryAction` (`snippets/Core/SyncStateFile.swift:9`): `applyRemoteDeletions` ("Confirm Deletions"; alert "Apply These Deletions?", destructive "Apply Deletions"), `refreshDeletionReview` ("Refresh Deletion Details"), `useCurrentAccount` ("Review Account Change"; alert, "Use This Account"), `repairCheckpoint` ("Repair Sync"; no alert), `restoreCloudFromThisDevice` ("Restore Cloud Library"; alert, "Restore from This Device"), `reclaimRecovery` ("Take Over Recovery"; alert, "Take Over"), `retrySync` ("Try Again"), `checkAgain` ("Check Again"). An action with a `confirmationTitle` shows an alert whose message is `statusDescription + "\n\n" + explanation` (`snippets-ios/SyncResumeConfirmation.swift:5`); the others run directly. `recoveryAction` comes from the engine, else the local-recovery engine, else the start issue (`repairCheckpoint`, `checkAgain`, `retrySync`) (`SyncCoordinator.swift:1230`, `:446`).
- `performRecovery` (`:1143`–`1225`): a start issue is handled by the coordinator (checkpoint repair rewrites base then journal, `:1386`–`1473`); otherwise forwarded to the engine and followed by a `.retry` round.
- First-fetch UI: until one `.idle(lastSync != nil)` is observed, an empty library shows the fetch status instead of the empty state (`PhoneLibraryViewController.swift:95`–`103`, `:594`–`609`). A quarantined library shows the recovery empty state and offers only import. Local recovery without sync: when the library is quarantined and sync is off or cannot start, the coordinator builds an engine over an inert transport and sealer that fail every data-plane call, used only for "Check Again" (`SyncCoordinator.swift:184`–`224`, `:1240`–`1285`).

### Provider selection
- `Provider` raw values `icloud`, `snippets-cloud`, `git` (`snippets/Sync/SyncBackendSelectionStore.swift:354`); `availableProviders` = iCloud if available + Snippets Cloud if the build flag is on + Git (`:678`). Exactly one provider is the active writer.
- `protocolLocations(for:)` (`:1555`): iCloud → legacy `Sync/base.json`, `Sync/journal.json`; Git → `Sync/Providers/<key>/` with key = first 16 bytes, lowercase hex, of SHA-256 over `"snippets.sync.provider.v1" NUL "git" NUL canonicalLocation NUL "refs/heads/<branch>" NUL lowercase datasetID` (`:1592`); Snippets Cloud → same with `"http" NUL lowercased server URL NUL lowercase serverInstanceID NUL lowercase spaceID NUL protocolMajor` (`:1577`). A different repository, branch or dataset therefore gets a fresh base and journal.
- `makeTransport` (`:1402`): Git requires coordinates (`gitConfigurationRequired`), a token for HTTPS or an SSH connector (`gitCredentialRequired`), and passes `expectedDatasetID`, `expectedMode`, the cache directory and, for a plain-text library, a `GitPlainCodec` sealed with the library key. Snippets Cloud checks pending erase/revocation/post-authorization journals, the pinned server URL and protocol 2 first.
- Switching (`SyncCoordinator.switchProvider`, `:890`–`935`): `prepareProviderSwitch` writes a `prepared` receipt → `stop()` and await shutdown → `commitPreparedProviderSwitch` rewrites the receipt as `targetSelected`, copies it into the target folder, then commits the provider preference (`:1648`) → activate the target's locations, turn sync on → `start()` → manual round. The receipt is deleted only after the target's first successful round (`:1800`–`1808`, `:1666`). Neither provider's remote or local data is deleted; the target's first round is an ordinary loss-preserving merge.
- Crash recovery at init (`:1725`–`1772`): `prepared` + provider still source → drop the receipt; `prepared` + provider already target → mark `targetSelected`; `targetSelected` → re-commit the target; unreadable receipt or mismatched location ids → `switchStateUnreadable`, nothing starts.
- `withQuiescedCloudTransport(_:)` (`SyncCoordinator.swift:852`): rejects a second concurrent call; sets `cloudMutationInProgress` (readiness becomes `cannotStart`, library changes are not debounced, `start` is refused); `stop()`; awaits the shutdown task; runs the operation; clears the flag and restarts if enabled, on success and on error. Required for any change to the active provider's coordinates, credentials or keys. `isQuiescent` (`:575`) is the precondition for destructive local maintenance. `reloadProviderSelection()` (`:881`): stop and restart on the current selection; never clears a halt.

### Bridge
- Round read, `currentSnapshotForRound(agreedBase:)` (`SnippetLibraryBridge.swift:98`): on the main actor and before the first suspension: refuse while quarantined (`localLibraryQuarantined`, recovery context `localLibraryQuarantine`); `store.flushPendingWritesForSync()` (failure → `localLibraryQuarantined`); read the sidecar bytes; read `snippets.json` and `vault.json` under one `LibraryTransaction` with a 2 s lock timeout (failure → `vaultUnreadable`); capture vault readability, `deviceID` and the cache generation (`:149`–`206`). Off the main actor: decode the sidecar (missing → cached metadata, else the agreed base), refuse to project an unreadable or vanished vault (`:421`), call `SyncLibraryProjection.currentEnvelopes(snippets:records:deviceID:metadata:agreedBase:vaultKID:)`, validate conflict extensions, encode the next sidecar, build `primaryStates` (`.plain`/`.secure`/`.duplicate`) (`:210`–`306`). Back on the main actor: if the sidecar file or cache changed meanwhile, discard and redo synchronously; else write the sidecar (best effort) and return (`:311`–`339`).
- `liveIDs()` = plaintext ids ∪ secure shell ids, for the deletion guard (`:458`).
- `classifyRemote`/`prepareRemote` (`:468`, `:535`) partition incoming envelopes into `applicable`, `deferredIDs` (secure record with no local vault, or a locked vault where a key is needed) and `incompatibleVaultIDs` (sealed under another vault `kid`, or a secure tombstone without a `kid` aimed at a live record). Output id lists are sorted by `uuidString`.
- `applyRemote` (`:851`–`1545`): flush the store; one `LibraryTransaction`; if `expectedPrimary` no longer matches any id → write nothing and return every id as `retryIDs`; tombstone → remove from both files; secure → upsert the vault record and remove a plaintext twin; plaintext → replace in place or insert at index 0 and remove a vault twin. Then fold the applied envelopes into the sidecar, reload both stores with notifications suppressed and publish one `coordinatedReloadDidFinish(.remoteSync, changedIDs:)`, which the coordinator does not turn into another round.
- Deletion intent: the store reports user deletes/restores synchronously; the coordinator keeps `pendingUserDeletionIDs` across engine rebuilds, passes them to `engine.noteUserInitiatedDeletions` / `cancelUserInitiatedDeletions`, and drops them when the engine reports them consumed (`SyncCoordinator.swift:296`, `:728`, `:737`, `:959`–`971`). iOS secure deletes call `userDidDeleteSnippets` directly (`PhoneRootViewController.swift:176`).
- Quarantine review: `reviewRecoveredLibrary` re-reads a restored primary and projects it without unlocking edits; `finalizeRecoveredLibraryReview` unlocks only after the marker file is gone (`:341`–`360`).

### macOS-only, skip on Android
External-change observer and distributed notification (`SnippetStore.swift:1862`–`1928`); starter snippet seed (`:1086`); `flushPendingEditorEdits` seam; CLI socket and `AgentSkill/`; `iCloudUnavailable` and all `legacyICloud*` handling; `onStateChange` single callback (`SyncCoordinator.swift:299`); ssh-agent wording in status text (`:2077`, `:2085`).

| Constant | Value | Pointer |
|---|---|---|
| persist debounce / retry base / retry cap | 0.3 s / 0.25 s × failures / 2 s | `SnippetStore.swift:468`, `:469`, `:1645` |
| library lock timeout: edit / terminate flush / bridge | 0.25 s / 5 s / 2 s | `SnippetStore.swift:369`, `:371`; `SnippetLibraryBridge.swift:57` |
| undo levels / deletion-undo tokens / undo rebase budget / import conflict messages | 50 / 50 / 20 000 / 8 | `SnippetStore.swift:403`, `:411`, `:2013`, `:1361` |
| local-change debounce (unpaced) | 1 s | `SyncCoordinator.swift:234` |
| Git pacing: delay / maximum wait / activation interval / poll | 30 s / 120 s / 30 s / 60 s | `snippets/Core/Git/GitSyncTransport.swift:121`, `:123`, `:126`, `:114` |
| start retry / follow-up rounds per request | 60 s (tolerance 15 s) / 2 | `SyncCoordinator.swift:791`, `:797`; `snippets/Core/SyncEngine.swift:1141` |

## 6. Search, placeholders, import, deep links, keyword suggestions

### Fuzzy match
- Fold, both sides (`snippets/Core/FuzzyMatch.swift:225-264`), locale defaults to `Locale.current` (`:24`, `:38`, `:88`). Fast path `:230-245` when language is not `tr`/`az`, the text is pure ASCII and has no `\r\n`: one entry per byte, `A-Z` lowercased, `wordStart = !previousWasLetter` (letter = folded `a-z`). Otherwise `:248-262`: per source grapheme `g`, `String(g).folding(options: [.caseInsensitive, .diacriticInsensitive], locale:)`; each grapheme of the fold is one entry carrying the source grapheme's UTF-16 `NSRange`; only the first is a `wordStart`, and only when the previous source grapheme is not `Character.isLetter`. A fold may expand (`ß` gives `s`,`s`).
- Score `:94-172` = maximum over strictly increasing alignments of the per-character sum: `1`, `+3` at a `wordStart`, `+5` when the first pattern character sits at target index 0 (`:110`), `+2 × streak` (`:151`; streak = count of immediately preceding adjacent matches, 0 after a gap). Empty pattern: matched, score 0 (`:101`). Pinned: `aaaaaa` on 256 × `a` scores 44, ranges 0..5 (`Tests/Core/FuzzyMatchTests.swift:126-127`).
- Tie-breaks: final state `:209-214` higher score, then smaller last matched index, then smaller start (UTF-16 location of the first match), then longer final streak; among non-adjacent predecessors `:127-128` higher score, then smaller start. Fully tied middle paths may highlight differently (the test oracle accepts any).
- Membership: `matches(query:target:)` `:176` greedy leftmost subsequence; `matches(query:foldedTarget:)` `:190` subsequence over the graphemes of a pre-folded string, empty query true. Element equality is Swift `Character ==` (canonical equivalence).

### Search index
- Fields per snippet (`snippets/Core/SnippetSearchIndex.swift:124-131`): `[displayName, normalizedKeyword, content] + tags`, each folded (case + diacritics) with the **user locale** (`:84-87`); tag keys separately via `SnippetTagging.filterKey` (fixed POSIX) `:136`. Fuzzy metadata `:134-135`: folded name only when the raw name is non-blank (never the first-body-line fallback), folded keyword, folded tags.
- Query `:260-267`: trim `.whitespacesAndNewlines`, then the same fold. No tokenisation: the whole query, inner spaces included, is one needle.
- Predicate `:210-221`: literal substring in display name, or keyword, or any tag; or subsequence (`FuzzyMatch.matches(query:foldedTarget:)`) in any fuzzy-metadata field; or literal substring in content. The body is never fuzzy-matched: `prjal` finds a name, keyword or tag "Project Alpha" but not a body or an unnamed snippet (`Tests/Core/SnippetSearchIndexTests.swift:232-246`).
- No score and no re-ranking: results keep input order (`:225-226`); callers pass `store.snippetsSortedForDisplay()`.
- Tag filter `:229-242`: AND, every active key must be one of the snippet's tag keys. `Evaluation.searchMatches` is before the tag filter, `.snippets` after.
- Empty query: callers skip the index and call `resultsForEmptySearch` `:250` (tag filter only). Secure snippets enter as shells with `content == ""`: name, keyword and tags are searchable, the body never is, and the vault is never asked (`:46-50`, test `:171`).
- Mechanics that need not be reproduced: 16 MiB folded-byte budget `:336` with a per-entry uncached fallback of identical semantics `:280-298`; entry reuse keyed on (name, keyword, content, tags) `:57-69`; prefix-extension narrowing `:379-387`; `SnippetSearchPipeline` single pending slot with a generation check before and after each scan `:548-568` (the UI re-checks `isCurrent` on the main thread).

### Prepared substring search
- Contract: `Field(folded).contains(Query(needle)) == folded.contains(needle)` in Swift semantics, except an empty needle is `false` (`snippets/Core/PreparedSubstringSearch.swift:53`). Swift semantics: canonical equivalence (`é` equals `e`+U+0301, U+212A equals `K`) and a hit must cover whole graphemes: U+1F469 alone is not in the sequence U+1F469 U+1F3FD U+200D U+1F4BB; `\r` and `\n` are not in `a\r\nb` but `\r\n` is (`:58-66`, `Tests/Core/PreparedSubstringSearchTests.swift:7-10`).

### Display order and library query
- Canonical order (`snippets/Core/Snippet.swift:89-101`): pinned first; then `createdAt` descending; then `id.uuidString` ascending (uppercase string compare). `updatedAt` never participates. Applied to ordinary snippets and secure shells together (`SnippetSearchIndex.swift:35`, `snippets/SnippetStore.swift:880-886`); array order in the files is storage-only.
- iPhone: section "Pinned", then one untitled section, each only when non-empty (`snippets-ios/PhoneLibraryViewController.swift:183-192`). iPad: one flat list in the same order (`snippets-ios/SnippetListViewController.swift:149`).
- Tag list (`SnippetSearchIndex.swift:22-36`): key = `filterKey`; shown spelling = first seen walking ordinary then secure in array order; count per key; sorted with `String.compare(_:options: [.caseInsensitive], locale:)` (literal compare; not `localizedStandardCompare`, no numeric or collation rules). Active filters are intersected with the existing keys on every reload (`PhoneLibraryViewController.swift:139-140`).
- Fallback name (`Snippet.swift:53-59`, `:445-499`): first line containing non-whitespace, trimmed, cut at 50 Characters + `…`; `Untitled Snippet` when none. Line breaks are all `CharacterSet.newlines` scalars (LF, VT, FF, CR, U+0085, U+2028, U+2029); trimming uses `.whitespacesAndNewlines` (covers U+00A0, U+2003).

### Placeholders
- Candidate scan (`snippets/Core/PlaceholderResolver.swift:80-82`): regex `\{([^{}\r\n]*)\}`. Matches are found on the original template and replaced back to front (`:186`), so inserted text is never rescanned (a clipboard holding `{date}` stays literal). A body that fails the grammar is left byte for byte (`:196-203`). Names are case-sensitive (`{DATE}` is literal).
- Body grammar (`:301-341`), `kind` = `date` | `time` | `datetime`:
  - `clipboard`: closure result, `nil` gives `""`; the closure runs once per clipboard token and never otherwise (`:218-219`).
  - `kind`: default style. `kind:FORMAT` (compact): FORMAT fully matches `^[a-zA-Z0-9:_\-]+$` (`:86-88`), no length cap; `{date:}` is literal.
  - `kind "FORMAT"` (legacy Raycast, `:322-331`): FORMAT passes the explicit-format check below.
  - `kind ATTRS` (`:343-393`): ATTRS ≤ 1024 Characters, 1 to 3 attributes separated by U+0020 runs; each is `key=value` with value `"…"` (no escapes, spaces allowed) or a non-empty run without spaces, followed by a space or the end (`:395-441`); keys unique; an unknown key rejects the token.
  - `format="…"` must be quoted; explicit-format check `:483-510`: 1 to 512 Characters, none of `"` `{` `}` CR LF, apostrophes balanced (ICU literal quoting; `''` is a literal apostrophe).
  - `locale="…"` must be quoted (`:512-536`): 1 to 64 Characters, no `_`, matches `^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$`, and its core (lowercased, cut at `@` or `-u-`) equals, or is a `-`-terminated prefix of, a core from `Locale.availableIdentifiers`. `format` and `locale` exclude each other (`:386`).
  - `offset=…` quoted or bare (`:443-472`): 1 to 8 space-separated terms; term = `+` or `-`, ASCII digits, unit `m` minute, `h` hour, `d` day, `M` month, `y` year; magnitude ≤ 100 000.
- Evaluation: the clock is sampled once per call (`:123`). Offsets apply in written order with `Calendar.current.date(byAdding:value:to:)` (`:253-274`): month and year clamp the day of month, day keeps wall-clock time across DST, hour and minute are exact. Then a fresh `DateFormatter()` (`:229-249`): the `locale` attribute if present, else the user's; `dateFormat = FORMAT` verbatim, else styles date = medium/none, time = none/medium, datetime = medium/medium.
- Preview (`:126-137`, `:551-569`): clipboard value cut to 1000 Characters + `"\n... [clipboard preview truncated]"`; whole rendering cut to 2000 Characters + `"\n... [preview truncated]"`. iOS previews with the literal clipboard `[Clipboard content]`, only when `containsResolvablePlaceholder` is true, never for a secure snippet (`snippets-ios/PhoneSnippetEditorViewController.swift:848-869`).
- iOS use: Copy resolves against the live pasteboard; an empty result reports "empty"; a secure copy goes to a local-only pasteboard item expiring after 60 s (`snippets-ios/SnippetActionService.swift:53`, `:88-128`). Editor completion tokens (`:102-108`): `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{date:yyyy-MM-dd}`.
- Raycast compatibility (`snippets/Core/RaycastPlaceholders.swift:12-14`, `:30-54`): import rewrites `\{(date|time|datetime) "([^"]+)"\}` to `{kind format="…"}` only when `isResolvablePlaceholder` accepts the result; otherwise the legacy text stays. Current Raycast `format=`/`offset=`/`locale=` spellings pass through untouched. No other Raycast placeholder (`{cursor}`, `{argument}`, `{uuid}`, `{selection}` …) exists in the code: they stay literal.
- Foundation/ICU dependencies and how `snippets-linux/src/placeholders.rs` handled each:

| Swift dependency | Android/JVM equivalent | Rust port |
|---|---|---|
| `DateFormatter()` defaults `:229`: user locale (incl. 12/24 h preference), `TimeZone.current`, locale calendar; `.medium` styles `:236-246` | `android.icu.text.DateFormat`/`SimpleDateFormat` with the default `ULocale` and zone; text depends on OS CLDR | `udat_open(style, style, locale=NULL, tz=NULL)`, `UDAT_MEDIUM`/`UDAT_NONE` (`snippets-linux/src/icu.c:8-10`) |
| `dateFormat = FORMAT` `:234`: ICU (UTS 35) pattern, verbatim | ICU `SimpleDateFormat(pattern)`; `java.text` and `java.time` use different letter sets (`Y u e c L Q q V x O B b A g r U`) | `UDAT_PATTERN` (`icu.c:8-9`) |
| `Locale(identifier:)` with `-u-hc-…` `:231` | `ULocale.forLanguageTag` | locale C string passed to ICU |
| `Locale.availableIdentifiers` allow-list `:94-96` | `ULocale.getAvailableLocales()` (set differs per OS) | omitted, syntax regex only (`placeholders.rs:121-129`) |
| `Calendar.current` arithmetic `:257-272` | `ZonedDateTime.plus(n, MINUTES/HOURS/DAYS/MONTHS/YEARS)` in the default zone | chrono: fixed `Duration` for m/h/d, `checked_add_months` for M/y (`placeholders.rs:63-75`) |
| `NSRegularExpression` × 3 `:80-92` | same patterns in `kotlin.text.Regex` | `regex` crate (`placeholders.rs:89`, `:99`, `:141`) |
- Rust divergences from Swift (do not copy): bare `format=`/`locale=` accepted and no apostrophe check (`placeholders.rs:99-120`); legacy `{date "…"}` not resolved at expansion; `d` offsets are fixed 24 h; limits in bytes; a failed ICU format leaves the token where Swift emits `""`.

### Keyword suggestions
- Fold everywhere: `filterKey(sanitizedKeyword(x))` (`snippets/Core/KeywordSuggestions.swift:169-171`). `KeywordRelation.between(k, other)` `:20-25` on folded inputs: equal is `duplicate`; `other` starts with `k` is `blockedByLonger`; `k` starts with `other` is `blocksShorter`; else `unrelated`.
- `candidates(name:contentFirstLine:)` `:119-139`: words = fold, `lowercased()`, split on anything that is not an ASCII letter or digit (`:162-167`). Order: abbreviations of the first name word; if the name has more than one word, the initials of its first 5 words; abbreviations of the first content word not in {`http`, `https`, `www`}. Abbreviation `:141-150`: a word of ≤ 6 characters is offered whole, a longer one as its 4- then 3-character prefixes. Entries shorter than 2 or repeated are dropped `:152-155`. `("Signature Block", "Best regards")` gives `sign, sig, sb, best`; `("Café Order", "")` gives `cafe, co` (`Tests/Core/TextReplacementTests.swift:1664-1681`).
- iOS offers the first 3 candidates that are `unrelated` to every enabled ordinary and secure keyword, only while the keyword is empty; a secure snippet contributes no content line (`PhoneSnippetEditorViewController.swift:949-958`). Enabled-keyword order: longer keyword first, then newer `updatedAt` (`snippets/SnippetStore.swift:900-909`).
- `existingMatches(query:among:)` `:55-71` (shown while the keyword is non-empty): dedupe by folded keyword, first wins; rank `:209-222`: 0 equal, 1 prefix, 2 a dot-part equals the query, 3 a dot-part starts with it, 4 substring, 5 (query has several dot-parts) every query part is a substring of a distinct candidate part, longest query part placed first `:231-240`; sort by rank, folded, original (Swift `String <`).
- `tabCompletion(query:among:)` `:86-114`: for each deduped candidate whose fold starts with the folded query and is longer, target = typed query + the candidate's continuation up to and including the next `.`, `-` or whitespace; result = longest common folded prefix of the targets, spelled from the first, only if longer than the query, else `nil`. `do` with `doc.frontend`, `doc.backend` gives `doc.`; `CAF` with `café.docs` gives `CAFé.`; `doc.` with both gives `nil` (`TextReplacementTests.swift:1780-1838`).
- Editor warnings from `KeywordRelation` plus "keyword has a multi-scalar grapheme": `PhoneSnippetEditorViewController.swift:872-906`.

### Import
- Detection order on the raw bytes (`snippets/Core/SnippetImportParser.swift:33-45`), default `JSONDecoder`: (1) top-level array of native snippets; (2) object whose `snippets` key holds that array; (3) non-empty array of Raycast items `{name: String, text: String, keyword?: String}`; else `invalidFormat`. `[]` parses as an empty native import and is rejected later as `emptyImport`.
- Native item = `Snippet` Decodable (`Snippet.swift:515-527`): `id`, `name`, `keyword`, `content` required; `tags` optional (normalised); `isEnabled` default true; `isPinned` default false; `createdAt` default now; `updatedAt` default `createdAt`; dates are JSON numbers, seconds since 2001-01-01T00:00:00Z; unknown keys ignored; one bad element fails that whole format.
- Raycast item: new `Snippet` (fresh UUID, enabled, unpinned, dates now), `content = RaycastPlaceholders.converted(text)`, keyword = `sanitizedKeyword(keyword ?? "")`. Two variants are prepared (`:46-66`): leading `!` kept, and one leading `!` removed then re-sanitised (`:77-87`). When any kept keyword starts with `!`, iOS asks "Remove !" / "Keep !" (`snippets-ios/PhoneRootViewController.swift:380-392`).
- iOS loader bounds (`snippets-ios/IncomingDocumentLoader.swift:7-8`, `:36-62`): over 32 MiB is rejected from metadata and again while reading in 1 MiB chunks; extension `snippetsbackup` (case-insensitive) or an encrypted-backup signature routes to the backup importer; otherwise the JSON must be ≤ 16 MiB.
- Apply (`snippets/SnippetStore.swift:951-962`, `:1270-1386`): (a) inside the file, duplicate ids or duplicate folded non-empty keywords are conflicts; (b) normalise: keyword sanitised, tags normalised, `updatedAt` raised to `createdAt`; (c) against the library: id equal to a secure snippet's, keyword equal to a secure snippet's, or id matches one record while the keyword belongs to another, are conflicts; any conflict throws `importConflicts` with the first 8 messages (`:1361`) and applies nothing; (d) nothing left is `emptyImport`; (e) one undo step, then per item (`:1036-1056`): same id replaces the whole record; else same folded non-empty keyword replaces that record but keeps its `id` and `createdAt`; else insert at array index 0; persist immediately; return the item count.

### Deep links
- Accepted (`snippets/Core/SnippetDeepLink.swift:51-58`): scheme `snippets` and host `share` or `new`, both compared lowercased; path and fragment are ignored.
- `snippets://share?data=<b64url>` (`:83-112`): `data` (exact name, first occurrence) = Base64 of UTF-8 JSON with `+` to `-`, `/` to `_`, padding stripped (`:192-197`). JSON from `JSONEncoder` with `.sortedKeys` only: `{"content":String,"keyword":String,"name":String,"tags":[String],"version":1}`; `keyword` is the normalised keyword; `tags` is omitted when empty (`:89`); no id, dates or flags travel. A secure snippet is refused before any encoding (`secureSnippetNotShareable`, `:78-81`).
- Parse (`:114-153`): not accepted is `unsupportedURL`; no `data` is `missingPayload`; the decoder re-pads to a multiple of 4 and uses strict Base64 (`:199-210`); that or the JSON failing is `invalidPayload`; `version != 1` is `unsupportedVersion`. Result: new `Snippet` (fresh UUID, enabled, dates now), `sanitizedKeyword(keyword)`, `normalizedTags(tags ?? [])`.
- `snippets://new?name=&keyword=&content=&tags=a,b` (`:163-184`): names compared lowercased, first occurrence, values percent-decoded by `URLComponents` (`+` stays `+`); `tags` is split on `,` then normalised; name, keyword and content all empty is `missingPayload`.
- Limits: none in `SnippetDeepLink` (no URL, payload or field cap). The review alert shows at most 280 Characters of trimmed content + `…` (`snippets-ios/IncomingSnippetLinkCoordinator.swift:206-211`).
- iOS handling (`IncomingSnippetLinkCoordinator.swift:92-178`): parsing has no side effects; an alert shows name, `\keyword`, tags, preview and, for a share link, the record it would replace (same id, else same folded non-empty keyword among ordinary snippets). On accept: a creation link calls `addSnippet(name, content, tags)`, then sets keyword and `isEnabled = false` in one update and flushes; a share link re-derives the replacement target, requires it to equal the reviewed record exactly (else `libraryChanged`), then calls `importSharedSnippet` with `isEnabled = false` (a keyword match keeps the old `id` and `createdAt`). Then search and filters are cleared and the editor opens (`snippets-ios/PhoneRootViewController.swift:43-57`).

### Settings catalog, content exposure policy, frecency and usage
- Catalog search (`snippets/Core/SettingsCatalog.swift:143-176`): fold query and vocabulary (case + diacritics, user locale), split the query on whitespace; every token must be a substring of `title + destination title + keywords`; per token 100 title equals, 60 title prefix, 35 title contains, 20 destination-title prefix, 12 a keyword prefix, else 1; sort by score descending, destination title, title. iOS sections `:123-133`: Library = sync, secureSnippets, backup; Support = diagnostics, about. Rows per platform `:186-234`.
- Exposure rule to keep (`snippets/Core/SnippetContentExposurePolicy.swift:27-33`, `:71-85`): while a snippet is secure every ambient surface is denied, and the preview template and name-placeholder source are `nil`, so the resolver is never called with secure text.
- Frecency and usage: not used by iOS. Neither `SnippetFrecency.swift` nor `SnippetUsageDocument.swift` is in the iOS Sources phase (`Snippets.xcodeproj/project.pbxproj:758-835`) and `snippets-ios/` never references them. Skip both.

### Constants
| Name | Value | Pointer |
|---|---|---|
| Fuzzy: per char / word start / target start / streak | 1 / +3 / +5 / +2 × streak | `FuzzyMatch.swift:110`, `:133`, `:151` |
| Search folded-byte budget (performance only) | 16 × 1024 × 1024 | `SnippetSearchIndex.swift:336` |
| Preview Characters: clipboard / rendered | 1000 / 2000 | `PlaceholderResolver.swift:12-13` |
| Parser: attribute text / format / locale Characters; offset terms / magnitude; attributes | 1024 / 512 / 64; 8 / 100 000; 3 | `PlaceholderResolver.swift:17-21`, `:350` |
| Keyword: whole-word max / abbreviations / min length / initials; shown on iOS | 6 / [4, 3] / 2 / 5; 3 | `KeywordSuggestions.swift:34-39`, `PhoneSnippetEditorViewController.swift:958` |
| Fallback name length | 50 Characters + `…` | `Snippet.swift:492` |
| Import: max file / max JSON; conflicts reported | 32 MiB / 16 MiB; 8 | `IncomingDocumentLoader.swift:7-8`, `SnippetStore.swift:1361` |
| Link: scheme / hosts / query item / version; review preview | `snippets` / `share`, `new` / `data` / 1; 280 Characters | `SnippetDeepLink.swift:34-40`, `IncomingSnippetLinkCoordinator.swift:207` |
| Secure clipboard lifetime (iOS Copy) | 60 s | `SnippetActionService.swift:53` |
| Settings search scores | 100 / 60 / 35 / 20 / 12 / 1 | `SettingsCatalog.swift:159-164` |

## 7. Porting hazards

Numbered across groups. Pointers are relative to the repository root; `Core/` = `snippets/Core/`.

### Text and Unicode

1. **Swift `String ==` is canonical equivalence** — `"é" == "e\u{301}"` in Swift (also `hasPrefix`, `Set`, `Dictionary` keys); Kotlin compares UTF-16 units. Affects duplicate-key rejection in the canonical parser, `Snippet`/`Fields` equality on `name`/`keyword`/`tags`, and every "did this field change" test in the merge; bodies and `x` values are compared as bytes. Rule for the port: NFC-compare wherever Swift compares `String`, byte-compare wherever Swift compares `Data` (Rust does exactly this, `snippets-linux/src/merge.rs:472`). `Core/SyncEnvelope.swift:315`, `Core/SyncMerge.swift:346`, `:688`, `Core/SyncLibraryProjection.swift:379`
2. **Swift `String <` is scalar order** — `"Z" < "a"`, no locale; Kotlin `compareTo` is UTF-16 code-unit order and differs above U+FFFF (tag keys, `x` keys). Canonical JSON keys sort by UTF-8 bytes, which is the same scalar order. `ByteArray` elements are signed: the equal-HLC rank needs an unsigned lexicographic compare. `Core/SyncEnvelope.swift:166-168`, `Core/SyncMerge.swift:406`, `:557`, `:840`
3. **`String.folding` has no JVM equivalent** — `filterKey` is a Foundation table (lowercasing with `ß`->`ss`, script-dependent mark stripping, no width folding; section 3). `lowercase()`, `Normalizer` NFD/NFKD and ICU transliterators all diverge; ship a table generated from Foundation. It feeds tag identity, keyword uniqueness in the store and keyword-collision handling in the local merge. `Core/Snippet.swift:426-430`, `Core/SyncMerge.swift:364`, `:539`, `snippets/SnippetStore.swift:1042`
4. **Whitespace sets differ** — Kotlin `trim()`/`isWhitespace()` treat U+001C-U+001F as whitespace and do not treat U+0085 or U+200B as whitespace; Foundation is the opposite. Implement the two sets from section 3 explicitly; they shape keywords, tags, display names and the synced conflict-copy name. `Core/Snippet.swift:66`, `:74`, `:401-403`, `:446-447`
5. **Grapheme clusters** — `Character` counting (first-line cut at 50, keyword length for expansion ordering, `removeFirst`, `hasPrefix`) is extended grapheme clusters; Kotlin `length`/`take` are UTF-16 units and `java.text.BreakIterator` on older runtimes splits emoji ZWJ sequences. Use one grapheme iterator in `:core` and test it with emoji, flags and combining marks. `Core/Snippet.swift:68-70`, `:492-498`, `snippets/SnippetStore.swift:904`
6. **Two display-name rules** — a plain conflict copy uses the trimmed name, else the first non-blank body line cut to 50 clusters plus `…`, else `Untitled Snippet`; a secure copy uses the raw name or `Untitled`. The result is a synced field. `Core/Snippet.swift:53`, `Core/SyncSecureConflictMaterializer.swift:243`
7. **Locale-sensitive defaults** — `lowercase()`/`uppercase()` without `Locale.ROOT`, `String.format` without a locale (non-ASCII digits in hex and decimal output), `Collator` and `DateTimeFormatter` defaults all read the device locale; the Swift code never does for anything stored or synced. The conflict-name timestamp is `yyyy-MM-dd HH:mm 'UTC'` in `en_US_POSIX`/UTC, truncated to the minute; backup file names use `en_US_POSIX` `yyyyMMdd-HHmmss`. `Core/Snippet.swift:417-430`, `Core/SyncMerge.swift:454`, `snippets/SnippetStore.swift:530`
8. **Invalid UTF-8 and lone surrogates** — Swift refuses a body that is not UTF-8 and a Swift `String` cannot hold a lone surrogate; Kotlin `String(bytes)` substitutes U+FFFD and `encodeToByteArray()` substitutes `?` silently. Decode with a reporting `CharsetDecoder`; reject or repair lone surrogates at the UI/clipboard boundary. Length limits count UTF-8 bytes. `Core/SyncEnvelope.swift:209-241`, `:1360`, `Core/SyncMerge.swift:306`, `:867`, `:990`

### Numbers, dates and identifiers

9. **Double spelling in hashed JSON** — Kotlin/Java `Double.toString` prints `807004800.0` as `8.070048E8` and is not shortest-round-trip before JDK 19; envelope timestamps, conflict fingerprints and copy ids all hash Swift's `Double.description` (fixed while exponent >= -4 and |v| <= 2^53, else `d.ddde+XX`). Port the Ryu-based formatter (`snippets-linux/src/canonical.rs:162-216`) and test it against `snippets-linux/tests/fixtures/swift-double-v1.tsv`. `Core/SyncEnvelope.swift:150`, `Core/SyncMerge.swift:918`
10. **Int and double are different canonical values** — `"version":1` vs `"createdAt":808272000.0`; a JSON library that collapses `1.0` to `1` changes every hash. `Core/SyncEnvelope.swift:433-473`, `:906`
11. **Timestamps are Doubles since 2001, not instants** — keep `createdAt`/`updatedAt` as the raw Double end to end; equality, `min`/`max`, persistence change detection and the bridge's CAS compare them bit for bit. Converting through `Instant`, epoch milliseconds or ISO-8601 makes every record look edited and re-upload forever. `Core/SyncEnvelope.swift:914-926`, `Core/SyncMerge.swift:729`, `Core/SyncLibraryProjection.swift:386`, `snippets/SnippetStore.swift:1579`, `snippets/Sync/SnippetLibraryBridge.swift:1113`
12. **Date to HLC milliseconds** — truncation of `seconds * 1000`, non-positive or non-finite -> 0, capped at `0xFFFFFFFFFFFF`; `Instant.toEpochMilli()` floors and throws; Rust floors before adding the epoch (`snippets-linux/src/projection.rs:136`). One helper, used everywhere. `Core/HybridLogicalClock.swift:261-267`, `Core/SyncMerge.swift:439`
13. **HLC is unsigned and strict** — `wallMs` 48 bits in a `UInt64`, `counter` `UInt16` with carry at 65535, wrapping adds in the generator and saturating adds in `localClock`; parse accepts exactly 26 ASCII bytes of `0-9a-f` with dashes at 12 and 17 (`toLong(16)` accepts uppercase, signs and non-ASCII digits). `Core/HybridLogicalClock.swift:52`, `:77`, `:108-126`, `:221-226`, `Core/SyncLibraryProjection.swift:570-585`
14. **First `send()` after construction is counter 1** — the generator seeds `(now, 0)` and `send` increments, so journal tombstone and restamp clocks at a fresh `now` are `(now, 1, device)`; returning `(now, 0)` changes merge outcomes against Swift devices. `Core/HybridLogicalClock.swift:198-231`, `Core/SyncJournal.swift:2026-2032`
15. **UUID spelling** — Foundation `uuidString` is UPPERCASE (`snippets.json`, deletion fingerprint, quarantine file names, review ids written by `JSONEncoder`); envelopes, AAD, base and journal keys are lowercase; `java.util.UUID.toString()` is lowercase. Choose the case per use, and validate canonical form with a regex before `UUID.fromString`, which accepts `1-1-1-1-1`. `Core/SyncEnvelope.swift:606`, `:1102`, `Core/SyncBase.swift:133`, `Core/SyncMerge.swift:56`, `Core/SyncEngine.swift:2977`, `Core/SyncJournal.swift:2423-2424`
16. **UUID ordering** — every sorted id list and the display tie-break compare `uuidString` as text; `java.util.UUID.compareTo` compares two signed longs. Always sort the string form. `Core/Snippet.swift:100`, `Core/SyncBase.swift:237`, `Core/SyncEngine.swift:2053`, `:2552`, `snippets/Sync/SnippetLibraryBridge.swift:619`, `:1293`
17. **UUIDv5 is hand-written** — `UUID.nameUUIDFromBytes` is MD5/v3; conflict-copy ids are SHA-1 over namespace bytes + name with the version and variant bits set. `Core/SyncMerge.swift:468`, `:888`
18. **Integer overflow** — Swift traps, Kotlin wraps. Backoff `min(2^n, 300)` must clamp the exponent before shifting; the deletion threshold should use the Rust form `n / 5 + (n % 5 != 0)`. `Core/SyncEngine.swift:2969`, `Core/SyncMerge.swift:24`, `snippets-linux/src/merge.rs:692`
19. **Seconds vs milliseconds** — `retryAfter`, `pollInterval`, pacing values and lock timeouts are `TimeInterval` seconds. `Core/SyncTransport.swift:358`, `:559`, `:647-655`

### JSON and serialization

20. **Generic JSON libraries are unusable for the canonical form** — `org.json`/kotlinx `JsonElement` accept duplicate keys last-one-wins, escape `/` or non-ASCII, reorder keys and turn the secure body into a `String`. Hand-write emitter and parser over `ByteArray`. `Core/SyncEnvelope.swift:137-201`, `:315`
21. **Normalise on construction, never on parse** — tags and origin are normalised and `userDeletion.v1` stripped when a local envelope is built, but parsed bytes must be taken verbatim or old spellings fail hash verification; keep two constructors, and remember the merge relies on the constructor side effects. `Core/SyncEnvelope.swift:876`, `:886-904`, `:1025-1068`
22. **Strict local decoders; null is not absent** — base and journal have closed key sets, "present iff" pairs, version-gated fields and a dozen cross-field invariants; explicit `null` is rejected for several keys. `ignoreUnknownKeys`, defaults or `coerceInputValues` turn a truncated file into an authoritative empty one. Hand-write the decoders over a JSON tree. `Core/SyncBase.swift:257-264`, `:304-308`, `:458-464`, `Core/SyncJournal.swift:2083`, `:2214-2253`, `:2483-2514`
23. **Closed enums in `state.json`** — an unknown `HaltReason` or `Backend` string fails the whole decode, which yields a fresh state and silently clears a sticky halt and the device id. Keep every legacy case; never add a lenient default for the halt. `Core/SyncStateFile.swift:135-173`, `:258-266`, `:418-420`
24. **Halt is a compare-and-swap token** — the whole `Halt` value is compared with what is on disk, and `.iso8601` drops sub-seconds, so `at` is floored to whole seconds before a halt is built. Store whole seconds and compare structurally. `Core/SyncEngine.swift:3176`, `:3268-3279`, `Core/SyncStateFile.swift:439-440`
25. **Base64 strictness** — `Data(base64Encoded:)` rejects whitespace, the URL alphabet and missing padding; `android.util.Base64.DEFAULT` and `java.util.Base64` decoders are lenient in different ways. A lenient decoder turns a damaged base, journal or vault carrier into a loaded one. `Core/SyncBase.swift:387`, `:411`, `Core/SyncJournal.swift:2259`, `Core/SyncLibraryProjection.swift:121`
26. **Foundation JSON quirks in files a Swift build wrote** — `\/` for slashes (inside base64), `"key" : value`, whole doubles without `.0`. A Kotlin reader must accept them; a Kotlin writer need not reproduce them. `Core/SyncBase.swift:643-647`, `Core/SnippetLibraryCodec.swift:50-54`
27. **Decoder leniency of `snippets.json`** — Foundation accepts an integer where a Double is expected, ignores unknown keys, defaults five keys and fails the whole array if one element lacks `id`/`name`/`keyword`/`content`. The store loads through `SnippetImportParser` (also accepts the wrapped and Raycast shapes) while the merge ancestor uses the strict codec; using one decoder for both changes which files quarantine. `Core/Snippet.swift:515-527`, `snippets/SnippetStore.swift:162`, `:1256-1268`
28. **Detail strings are data** — `.needsAttention(detail)` carries closed transport codes (`git_key_required`, `transport_restart_required`, …) that the coordinator switches on; keep them byte-identical and unlocalised in `:core`. `Core/SyncEngine.swift:669`, `:2955`, `snippets/Sync/SyncCoordinator.swift:2100-2114`

### Value semantics, collections, equality

29. **Journal and base are values** — the engine copies the struct, mutates the copy, writes it, then publishes; `persistJournal` skips the write when candidate == published. Shared mutable Kotlin maps make a real change look unchanged and never reach disk. Immutable data classes, persistent collections, deep `equals`. `Core/SyncEngine.swift:3070-3078`, `:2534-2538`, `Core/SyncJournal.swift:315-372`
30. **Version equality is a hash of canonical bytes** — `sameVersion` drives acknowledge, reject, pending and entry removal; any drift in canonical encoding means offers never acknowledge (infinite resend) or acknowledge wrongly. `Core/SyncJournal.swift:2039-2049`
31. **`ByteArray` in data classes** — `Fields.content`, record versions and identities are `Data` with value equality; Kotlin data classes compare arrays by reference. Wrap bytes in a value type. `Core/SyncEnvelope.swift:832-861`, `Core/SyncTransport.swift:244`
32. **Hash-container order** — Swift randomises `Set`/`Dictionary` iteration per process, so every order that reaches output is sorted explicitly (pending, merged batch, copies, variants, `userDeletion.v1` hashes sorted then first 8). Keep every sort; do not let `LinkedHashMap` insertion order make tests pass by accident. `Core/SyncEngine.swift:1846-1849`, `Core/SyncJournal.swift:1023`, `:1118-1121`, `Core/SyncMerge.swift:150-161`, `:502`, `:1014`
33. **`Dictionary(uniqueKeysWithValues:)` traps on duplicates** — Kotlin `associate` keeps the last value silently; assert where Swift relies on the trap. `Core/SyncEngine.swift:729`, `:1915`, `:2141`, `:2559`
34. **Whole-snippet equality decides persistence** — `needsPersistence`, transaction change detection and the bridge's `expectedPrimary` check compare complete snippets including exact timestamps; a value stamped in memory at a precision the file does not keep never equals its decoded form. `snippets/SnippetStore.swift:1553`, `:1579`, `Core/LibraryTransaction.swift:129-130`

### Concurrency and lifecycle

35. **Main-actor confinement** — the engine has no lock; `.syncing` is its only re-entrancy guard and the library may change at every suspension. Run engine, store and coordinator on one confined dispatcher, keep local reads 1/2/3 and the `expectedPrimary` CAS, never hold a blocking lock across a suspension. `Core/SyncEngine.swift:288`, `:1180`, `:1857`, `:2141`
36. **Read before first suspend** — `currentEnvelopesForRound`/`currentSnapshotForRound` must capture the library synchronously and only then move CPU work off the main dispatcher; deletion intents are snapshotted before that call. `withContext(Default) { store.read() }` breaks both. `Core/SyncEngine.swift:138-144`, `:1485`
37. **Cancellation is not a failure** — Swift catches `CancellationError` before the generic catch that turns everything else into offline backoff; Kotlin `catch (e: Exception)` swallows `CancellationException`. Handle it first and call `ensureActive()` at each Swift `Task.checkCancellation()`. `Core/SyncEngine.swift:1270`, `:1326`, `:1582-1584`
38. **Catch order is policy** — `SyncTransportFailure` -> state mapping, `SyncEngineFailure` -> sticky halt (or `needsAttention`), anything untyped -> backoff. A sealed hierarchy with the wrong supertype changes which failures stick. `Core/SyncEngine.swift:1279-1335`
39. **Cancelling a round does not stop it** — `stop()` awaits the old round and `transport.shutdown()` before any new engine exists; late callbacks are discarded by a lifecycle generation. `cancel()` is equally advisory with coroutines: `join` before rebuilding, resume every `requestSync` waiter exactly once. `snippets/Sync/SyncCoordinator.swift:811-845`, `:1820`, `:1867`
40. **Store observers are synchronous and re-entrant** — the dirty bit is set before observers fire because an observer may start a round or edit again at once; a `Flow` collector that runs later breaks "durable before journal". Call the sync delegate synchronously, derive Flows afterwards. `snippets/SnippetStore.swift:1397-1401`, `:1572-1583` (pinned by `snippets-ios-tests/SyncSnapshotDurabilityTests.swift:124`)
41. **Applied remote data must not trigger a round** — the bridge reloads silently and publishes one `.remoteSync` change the coordinator ignores; a file or database observer that reports it as a local change creates a fetch/push loop. `snippets/Sync/SnippetLibraryBridge.swift:1514-1530`, `snippets/Sync/SyncCoordinator.swift:948-955`
42. **Single-consumer event stream** — `AsyncStream` with an unbounded buffer; `SharedFlow(replay = 0)` drops events emitted before collection and a rendezvous channel blocks the fake. Use `Channel(UNLIMITED)`. `Core/InMemoryTransport.swift:147-152`
43. **Weak recovery-claim registry** — a static map of weak engine references decides "active in this process" vs "abandoned"; the JVM frees at GC, so a discarded engine can block the recovery button. Deregister explicitly on close. `Core/SyncEngine.swift:302`, `:640-650`
44. **Timers do not survive suspension** — debounce, poll, offline retry and start retry are in-process timers; iOS pushes a paced pending change under a background task when backgrounded. Android needs the same flush in `onStop` and scheduled work for anything later. `snippets/Sync/SyncCoordinator.swift:63`, `:1876`, `snippets-ios/AppEnvironment.swift:254`
45. **Main thread blocks on the persistence worker** — immediate writes and flushes wait with lock timeouts of 0.25 s to 5 s, up to three times; that is ANR territory if the lock is ever contended. Keep the ordering guarantee, bound the waits. `snippets/SnippetStore.swift:155`, `:1478`, `:1708`, `:1768`

### Files, durability, platform

46. **Missing vs unreadable** — `java.io.FileNotFoundException` covers both a missing file and permission denied; Swift treats only ENOENT as "empty library" and everything else as unreadable (never saved over). Use `java.nio.file.Files` and `NoSuchFileException`. Quarantine order is marker, halt, then move. `Core/LibraryGeneration.swift:8-15`, `:106-119`, `snippets/SnippetStore.swift:1074-1080`, `:1175-1220`
47. **Durability calls** — `FileOutputStream.close()` does not fsync and `File.renameTo` reports failure as `false`; use `FileChannel.force(true)`, `Files.move(ATOMIC_MOVE)` and an explicit directory fsync, surfacing a directory-sync failure after the rename. `Core/AtomicFileWriter.swift:83-121`, `:143-152`
48. **Whole-file read-modify-write of `state.json`** — four writers (device identity, generation, crash marker, halt) rewrite the document; all must hold the same library mutex or a halt or marker is lost. `Core/LibraryGeneration.swift:377-386`, `Core/LibraryTransaction.swift:309-324`, `Core/SyncEngine.swift:3225-3293`
49. **`synchronize()` is a commit boundary** — the provider switch and Git configuration order their writes around a checked `UserDefaults.synchronize()`; `SharedPreferences.apply()` returns before the write. Use `commit()` and map `false` to `preferenceStoreUnavailable`. `snippets/Sync/SyncBackendSelectionStore.swift:812`, `:1694-1710`
50. **The implicit provider is iCloud** — an absent provider key, the legacy enabled key and the Snippets Cloud local erase all resolve to `.iCloud`; Android needs an explicit "no provider" state. `snippets/Sync/SyncBackendSelectionStore.swift:650`, `:1327`, `snippets/Sync/SyncCoordinator.swift:511-520`
51. **Process identity in recovery claims** — `hostName`, `processID` and a process start time are written into `state.json`; Android has no meaningful host name and reuses pids. Use a per-launch random owner id as the incarnation token. `Core/SyncEngine.swift:615-627`, `Core/LibraryLock.swift:281-294`

### Search, placeholders, import, links

52. **Two fold locales** — search, fuzzy match and settings search fold with the user locale (Turkish/Azeri `I` -> `ı`), while `filterKey` is fixed `en_US_POSIX`; mixing them changes which tags and keywords collide. `Core/SnippetSearchIndex.swift:84-87` vs `Core/Snippet.swift:430`
53. **JVM and device grapheme rules differ** — the host JDK's `java.text.BreakIterator` (before JDK 20) splits emoji ZWJ and modifier sequences while Android's is ICU-backed, so a `:core` unit test can pass on the JVM and differ on a device. The 1024/512/64 parser limits, 1000/2000 preview cuts and 4/3-character abbreviations all count clusters. `Core/PlaceholderResolver.swift:347`
54. **Substring hits must be grapheme-aligned and canonically equivalent** — `indexOf` finds U+1F469 inside the ZWJ sequence U+1F469 U+1F3FD U+200D U+1F4BB and `\n` inside `\r\n`; Swift `contains` does not, and it matches NFC against NFD. Normalise to NFC at the fold boundary and compare clusters. `Core/PreparedSubstringSearch.swift:58-66`, `Core/FuzzyMatch.swift:193`
55. **`Character.isLetter`** — Swift's is the Alphabetic property of the first scalar (true for `ⅷ`), i.e. `Character.isAlphabetic(codePoint)`, not `isLetter`; it decides fuzzy word starts. `Core/FuzzyMatch.swift:248-262`
56. **Date patterns are ICU and failure is an empty string** — `java.text.SimpleDateFormat` and `java.time` accept a different letter set and throw on unknown letters; Foundation returns `""` for an invalid pattern (observed: `{date:foo}` expands to nothing). `android.icu` is unavailable to plain-JVM `:core` tests, so inject the renderer. `Core/PlaceholderResolver.swift:229-249`
57. **Style output and the locale allow-list are host data** — medium time in `en_US` contains U+202F before `PM`; `Locale.availableIdentifiers` is not Android's set. Tests must compare against the platform formatter (as `Tests/Core/PlaceholderResolverTests.swift:18-44` does), never literals. `Core/PlaceholderResolver.swift:94-96`
58. **Do not port the reference crash** — a placeholder body of exactly `date "` (template `{date "}`, same for `time`/`datetime`) builds a reversed range and traps the Swift resolver (confirmed with a scratch build). Kotlin must treat it as literal text. `Core/PlaceholderResolver.swift:322-326`
59. **Android URL helpers decode differently** — `Uri.getQueryParameter` turns `+` into a space, `URLComponents` does not; the Swift share-link decoder accepts both Base64 alphabets with or without padding and nothing else, while `java.util.Base64.getUrlDecoder` rejects `+` and `/`. Parse the query by hand in `:core`. `Core/SnippetDeepLink.swift:51-57`, `:166`, `:199-210`
60. **Import decoding is all-or-nothing per format** — a type mismatch in one element fails that format and falls through to the next; dates are numbers from 2001; `UUID.fromString` accepts short forms Foundation rejects. `Core/SnippetImportParser.swift:35-41`

## 8. Test inventory to port

Priority: must port / nice to have / n/a on Android. `Tests/Core` runs under `xcrun swift test --package-path CorePackage`; `snippets-ios-tests` under the `Snippets iOS` scheme.

| Test file | What it pins | Priority |
|---|---|---|
| Tests/Core/WireTests.swift (Canonical JSON, `:151-345`) | Insertion-order independence; literal `{"A":null,"a":"x","b":2,"ä":true}`; UTF-8 key order (U+FFFD before U+10000); exact escape set; `.string` == `.utf8`; bit-exact double round trip; `1` vs `1.0`; NaN/inf refused; duplicate and canonically-equivalent keys refused; trailing bytes; depth 32; strict numbers; surrogate pairs; invalid UTF-8 | must port |
| Tests/Core/WireTests.swift (Envelope shape, `:347-588`) | Exactly ten top-level and eight `fields` keys; `userDeletion.v1` validation (1...8 unique lowercase SHA-256, tombstone only); pinned tag/device spellings and hash `dbc644e2…`; parsed tags bypass normalisation; non-canonical origin rejected; tombstone has null `fields`/`contentHash`; unknown key refused; `tooNew` before malformed; `x` round-trips byte-for-byte; hash catches edited plaintext; contentHash follows body only | must port |
| Tests/Core/WireTests.swift (Conversions, `:589-730`) | Snippet <-> envelope lossless; timestamps bit-exact; secure record refuses `plainSnippet`; tombstone never carries fields or `x` (secure keeps `vaultKID`) | must port |
| Tests/Core/WireTests.swift (Sealing, `:732-873`) | seal/open lossless; only id/rev/deleted readable; moved blob, flipped flag, wrong key fail; rev deterministic; shipping sealer contract; padded length | must port (with crypto brief) |
| Tests/Core/WireTests.swift (Deletion guard `:875`, In-memory transport `:1112`) | Guard floor 5 / 20 percent boundaries, dedupe of duplicated and unknown ids; fake transport paging, rejection, flakiness, cursor invalidation, conflict on stale push, event stream | must port |
| Tests/Core/WireTests.swift (Tombstone ledger `:958`) | Ledger idempotence, 90-day GC horizon and floor, file round trip | n/a (ledger is dead code in production) |
| Tests/Core/ReviewRegressionTests.swift (`:12-258`) | Missing library != empty; unreadable library throws; emptied remote deletes everything only with ancestor proof; undo-snapshot rebase never mints a conflict copy and keeps untouched records; pre-existing keyword collision left alone, merge-created one resolved; tag folding independent of process locale; identical merges give identical output incl. conflict order; racing write retries and folds the peer in | must port |
| Tests/Core/ReviewRegressionTests.swift (`:260-576`) | Vault independence/write safety, share-link refusal for secure snippets, IPC addressing/exit codes, undo cannot resurrect an encrypted secret | vault and share-link cases: port with the vault brief; IPC: n/a on Android |
| snippets-linux/tests/fixtures/swift-double-v1.tsv | 11,903 `bits<TAB>text` rows from the Swift runtime for the double printer | must port (data file, reuse as is) |
| snippets-linux/tests/fixtures/sync-wire-v1.json, merge-v1.json, conflict-copy-v1.json | Cross-client vectors: canonical bytes + wire + hash; canonical conflict snapshot, fingerprint, copy id, deletion fingerprint | must port (data files, reuse as is) |
| Tests/Core/ClockAndStateTests.swift | HLC string form 12-4-8 lowercase hex, string order == Comparable order, strict parse (malformed and non-canonical rejected), device normalisation vectors, foreign id sorts lowest; generator monotonic under frozen/backward/jumping clocks, `stamp` above ancestor (undo wins), drift limit 24 h inclusive, restart never reissues; `state.json` round trip with ISO whole-second dates, too-new probe before decode, legacy halt decodes, recovery action per halt reason, missing/unreadable -> fresh with new device id, quarantine marker keeps one review id across retries; storage layout (nothing directly in the support root, provider path isolation) | must port (HLC, state, marker); layout cases nice to have |
| Tests/Core/SyncJournalTests.swift | offer frozen across newer edits and restart; generation/modifiedAt change only with desired; delete after lost create/update ACK derived from the offer; fresh install invents no tombstones; unoffered create+delete collapses to nothing; exact-version acknowledge and reject; transport rekey staging; reviewed-ancestor epochs, account change drops them; `forgetSecureIntent`; `userDeletion.v1` marker only on the durable tombstone; recreate after tombstone gets a higher clock and restamp is a fixed point; file load missing/corrupt/future, valid truncations unreadable, deterministic bytes independent of map order | must port |
| Tests/Core/LibraryTransactionTests.swift | promotion writes both files and clears the marker; injected failure at each write leaves source intact or duplicate + marker; mixed batch stages duplicates before the vault changes; no-op writes nothing; concurrent library/vault write forces retry and is folded in; unreadable vault aborts untouched; vanished library reported as missing; marker distinguishes promote from demote | must port (drive concurrency through an injected write hook instead of a second process) |
| Tests/Core/LibraryWriterTests.swift | atomic writer: no partial reads, 0600, staging dir honoured and left empty, directory-sync failure propagates after rename, failed write keeps old bytes; funnel: foreign write folded in, reformat counts as foreign, no-op leaves file and generation untouched, canonicalise once; undecodable library throws (never empty), explicit recovery preserves bytes, missing = empty; generation +1 / +2 gap; codec cases (nine frozen keys, byte-exact re-encode, digest over bytes) belong to the codec section; cross-process `flock`, sentinel and PID-reuse cases | must port writer, funnel, unreadable and generation cases; cross-process lock cases n/a on Android |
| Tests/Core/SyncEngineTests.swift | Happy path (push once, then no re-push `:137`), push-before-apply (`:382`), delete = tombstone (`:302`), delete during in-flight create (`:325`), cancellation after acceptance (`:244`), rejection policy (retryable `:400`, permanent `:417`/`:461`, auth `:444`), backoff + `bypassingBackoff` (`:505`), whole deletion-guard and review flow incl. user-deletion marker, fingerprint change, restart fence, legacy refresh (`:552`–`:1103`), sticky halt (`:1104`), primary-quarantine Check Again and reviewed-snapshot recovery (`:1119`–`:1653`), undecryptable quarantine (`:1654`), deferred/incompatible vault (`:1677`, `:1714`), too-new state (`:1806`), unwritable halt (`:1840`), cursor invalidation, feed restart between pages, mode flip (`:1862`–`:2053`), outcome matched by id (`:2054`), base survives restart (`:2093`). Contains the `FakeLibrary` to port (`:20-90`). | must port |
| Tests/Core/SyncEngineFaultInjectionTests.swift | Lost-acknowledgement matrix (create/update × edit/delete, survives restart `:234`–`:383`), rekey retry keeps CAS and drops cursor (`:384`), permanent rejection does not pin an old offer (`:471`), journal failure keeps old cursor (`:523`), disjoint-field conflict merges both (`:665`), same-scalar deterministic winner (`:731`), create+delete uploads one tombstone (`:756`), partial batch resubmits only the tail (`:792`). | must port |
| Tests/Core/SyncEngineJournalSafetyTests.swift | Strict base decoding (truncations, unknown field, required fence, mode pairing `:179`–`:287`), schema-1 migration on first round (`:288`), downgrade-safe schema bump (`:327`), `journalEstablished` on first round (`:352`), missing/corrupt/future journal and base halts and the only ways out (`:380`–`:671`), sub-second `modifiedAt` bit-exact round trip (`:679`). | must port (legacy-schema cases: nice to have unless old files are migrated) |
| Tests/Core/SyncRecordCASTests.swift | `SyncRecordVersion` strict codec incl. 11 invalid documents and size cap (`:37`), additive `recordVersions` (`:76`, `:104`), `recordConfirmed` atomicity (`:141`), version outside sealed identity (`:170`), offer carries ancestor version and base-before-ack (`:454`), fetched version durable before cursor (`:524`), nil-remote conflict with and without a following fetch (`:624`, `:704`), authoritative conflict record rebases (`:764`). | must port |
| Tests/Core/SyncOpaqueGenerationOrderingTests.swift | Opaque then valid generation of one id in one inbox: latest decodable applies, cursor durable before `acknowledgeFetched` (`:103`). | must port |
| Tests/Core/SyncAccountBindingTests.swift | Provider-neutral (fake scoped transport): bind before first fetch (`:23`), restart keeps checkpoint (`:49`), legacy checkpoint rules (`:100`, `:121`, `:162`), account switch halts before any library read (`:213`, `:270`), reviewed reset ordering, one-shot authority, crash windows (`:304`–`:916`), remote-data reset, claims and takeover (`:974`–`:1276`), dataset generation fence (`:1277`–`:1429`), signed-out/unavailable account is retryable (`:1467`, `:1499`), foreign-scope replies ignored (`:1535`, `:1582`), binding write failure (`:1627`), damaged binding unreadable (`:1653`). | must port (legacy-digest migration `:162`: nice to have) |
| Tests/Core/SyncRecoveryFollowUpTests.swift | Follow-up rounds: reseal recovery uploads the newer edit in the same `sync()` (`:160`), lost-ack recovery plus newer edit finish in one `sync()` (`:222`). | must port |
| Tests/Core/SyncMergeTests.swift | Local-file merge: absence vs. proven delete, edit beats delete, per-field independence, no clock when one side moved, tag set merge incl. case/diacritic identity and spelling, conflict-copy recipe (`conflict\|body\|ms`, version nibble 5), no breeding, keyword-collision loser and tie by id, timestamp monotonicity, output order, fixed point, mirrored convergence incl. randomized histories | must port |
| Tests/Core/SyncConflictCopyVectorTests.swift | Byte-exact plain conflict copy, copy id and fingerprint from the two Linux fixture vectors; same copy from either merge side | must port (first test to write) |
| Tests/Core/SyncConflictCopyTests.swift | Two engines + backend: both bodies preserved at once, copy id independent of submit order, equal-HLC convergence, redelivery fixed point with no extra upload, field-only merges without a copy, delete vs. update, secure variants unioned by a shallow merge and never nested | must port |
| Tests/Core/SyncConflictOrderingTests.swift | Last generation per id wins without a copy; an edited remote copy merges against its generated ancestor; an unrelated record at a copy id halts before apply in either order | must port |
| Tests/Core/SyncConflictPayloadBudgetTests.swift | 674,815-byte canonical ceiling against the shipping sealer (899,796 vs. 900,138); oversized merged output halts before the primary write with cursor and base unchanged; generated and materialized copies fit | must port (sealer boundary case needs the crypto layer) |
| Tests/Core/SyncConflictDependencyTests.swift | Copy-before-source sequencing, frozen C0 offer, acceptance receipts, reserved copy ids after prune and delete, restart and re-key recovery, journal schema migration and strict decoding of dependency state | must port the behavioural cases; legacy v1/v2 journal migration cases n/a on Android (no old journals) |
| Tests/Core/SyncRestoredConflictCopyTests.swift | A deleted then restored copy is re-published with its provenance and accepted by peers; sidecar keeps only verified plain identities, bounded to the 256 newest | must port |
| Tests/Core/SyncLibraryProjectionTests.swift | Apply -> project is a fixed point for plain and secure; one-time `vaultKID` stamp; stable local clock above the ancestor; keyed hash never replaced by the wire digest; invalid UTF-8 rejected; vault keys follow the selected body; promotion and demotion | must port |
| Tests/Core/SyncSecureConflictMaterializationContractTests.swift | Exact shape of the materialized secure copy, reseal under the copy id, idempotent retry preserving user edits, collision, wrong vault, wrong hash and malformed variant failures | must port (with vault) |
| Tests/Core/SyncSecureConflictVariantDurabilityTests.swift | Variant survives the `vault.json` round trip without sidecars, number kinds preserved, malformed or rival-vault carriers fail closed, future versions stay opaque and block deletion, resolved envelope removes the carrier, no tombstone while a variant is unresolved | must port (with vault) |
| `snippets-ios-tests/SnippetStorePersistenceTests.swift` | Debounced write runs off the main thread; flush drains an in-flight write and keeps a newer edit plus a foreign edit and delete; immediate write neither deadlocks nor applies twice; re-entrant edit from a completion callback stays dirty and reaches disk; stale completion cannot replace a newer disk observation; busy retry; rescue file after three busy attempts; unreadable primary is quarantined durably; marker alone fails closed when `state.json` is lost; quarantine blocks import except explicit full-file recovery (also to an empty library) | must port |
| `snippets-ios-tests/DeletionUndoTests.swift` | Scoped restore keeps intervening edits and original position; token is one-shot; does not replace a record restored by global undo; delete and restore report intent to the sync delegate | must port |
| `snippets-ios-tests/SnippetDisplayOrderTests.swift` | Store sorts plaintext and secure records together regardless of file order | must port |
| `snippets-ios-tests/SyncSnapshotDurabilityTests.swift` | A pending edit is in `snippets.json` before the journal offers it and survives a restart; a failed primary write stops before journal, sidecar or transport and writes no rescue file; a synchronous change observer cannot project before the dirty bit is published | must port |
| `snippets-ios-tests/SyncLifecycleTests.swift` (2674 lines) | Request results while off; coalescer; offline retry scheduler; debouncer burst and maximum wait; unpaced vs paced triggers; background flush only for a paced change; `.remoteSync` writes do not trigger; manual bypasses backoff; provider-switch receipt at each crash point; rekey guards on base/journal pairing; checkpoint repair crash-safe at each boundary and keeps post-review deletes; local review with sync off; unreadable key offers Check Again; cached library usable while the key store blocks; rapid disable/enable waits for the old transport | must port, except the CloudKit-only cases (`:1424`, `:1500`, `:1745`): n/a |
| `snippets-ios-tests/SyncSecureConflictBridgeIntegrationTests.swift` | Bridge defers on a locked or absent vault, rejects rival-vault and colliding copy ids before any write, applies copy and survivor only inside `applyRemote`, in either arrival order | must port (with the vault wave) |
| `snippets-ios-tests/SyncSecureConflictDependencyIntegrationTests.swift` (7692 lines, 82 tests) | Bridge + journal dependency ordering for secure conflict copies (names only were read) | must port (with the vault wave) |
| `snippets-ios-tests/SnippetsIOSTests.swift` (`:113`, `:130`, `:707`, `:1228`) | Export excludes secure shells; importing the same export twice creates no duplicates; state observers do not replace each other; leaving a blank draft discards it | must port |
| `snippets-cross-platform-tests/GitSyncSettingsMacTests.swift:1622` | Main thread stays responsive during a Git round against a slow host | nice to have (as an Android benchmark) |
| `Tests/Core/FuzzyMatchTests.swift` | Exhaustive oracle over targets `{a,b,space}` ≤ 5 and queries ≤ 3: score, every tie-break tier, `matches` agreeing with `score`, score-only mode; Unicode and `tr`/`az`/`lt` folding with UTF-16 ranges; 256 × `a` scores 44 | must port the `matches` assertions; scorer part nice to have (only if `score` is ported) |
| `Tests/Core/SnippetSearchIndexTests.swift` | Order preserved and every field searched (`:8`); case/diacritic folding and query trim (`:53`); AND tag filter on canonical keys (`:71`); secure shell never needs a body (`:171`); fuzzy metadata versus literal body incl. the uncached path (`:232`); tag projection (`:269`) | must port those six; cache-count, byte-budget, prefix-narrowing and pipeline tests (`:99-149`, `:194`, `:248`, `:289`, `:334`) nice to have |
| `Tests/Core/PreparedSubstringSearchTests.swift` | 16 texts × 25 needles equal Swift `String.contains` (NUL, CRLF, Kelvin sign, NFC/NFD, emoji ZWJ and modifiers, Hangul jamo) | must port (expected values must be emitted from Swift, the test computes them at run time) |
| `Tests/Core/PlaceholderResolverTests.swift` | Legacy and current Raycast spellings, offsets, locale, 29 literal pass-through cases, clipboard read only on demand, clock sampled once, completion tokens resolve, preview truncation | must port (expected dates via the platform formatter) |
| `Tests/Core/SnippetImportParserTests.swift` | Native array round trip, Raycast `!` variants decoded once, malformed input rejected, `[]` valid | must port |
| `Tests/Core/SnippetDisplayOrderTests.swift` | Pinned, newest `createdAt`, UUID string; input order irrelevant; edits do not move rows; comparator irreflexive | must port |
| `Tests/Core/SnippetContentPreviewTests.swift` | Fallback-name line: blank lines skipped, all 8 Foundation newline forms, U+00A0/U+2003 trimmed, stops before a 1 MB tail | must port |
| `Tests/Core/TextReplacementTests.swift` (`:1632-1847` only) | `KeywordRelation` both directions; `candidates` examples; `existingMatches` ranks; `tabCompletion` part-by-part, common prefix, case-preserving | must port that suite; the rest of the file is Mac expansion, n/a on Android |
| `Tests/Core/ReviewRegressionTests.swift` (`:446-475`) | Share link refuses a secure snippet before encoding and the error carries no content; an ordinary snippet still shares | must port |
| `Tests/Core/SettingsCatalogTests.swift` | iOS navigation sections, row routing, multi-token keyword search, Mac-only rows hidden on iOS, static copy only | nice to have |
| `Tests/Core/SnippetContentExposurePolicyTests.swift`, `Tests/Core/FrecencyRankingTests.swift`, `Tests/Core/UsageRecordingTests.swift` | AppKit responder selectors; Mac usage ranking and `usage.json` merge | n/a on Android (keep one test: secure snippet yields no preview template) |
| `snippets-ios-tests/IncomingDocumentLoaderTests.swift` | Ordinary JSON is loaded and prepared; a file over the limit is rejected before it is read | must port |
| `snippets-ios-tests/IncomingSnippetLinkCoordinatorTests.swift` | No mutation before acceptance; replacement lands disabled; review invalidated when the target appears or changes; creation link makes a unique disabled snippet | must port |
| `snippets-ios-tests/SnippetDisplayOrderTests.swift`, `snippets-ios-tests/SnippetsIOSTests.swift` (`:256-270` and the copy test that follows) | Store sorts ordinary and secure records together regardless of file order; `SnippetLibraryQuery` pinned/unpinned split, search + AND tags; ordinary Copy resolves `{clipboard}` and never clears the clipboard for empty content | must port |

## 9. Suggested Kotlin decomposition

Packages under `com.khm.snippets.core`. Layers are a dependency order: everything in a layer can be built in parallel once the layers above it expose their interfaces. Everything is plain Kotlin/JVM; anything needing `android.icu`, `SharedPreferences`, Keystore or lifecycle is an interface implemented in `:app`.

| Layer | Package | Contents | Needs |
|---|---|---|---|
| 0 | `core.text` | `FoundationText`: whitespace/newline predicates, trim/split, grapheme iterate/count/prefix, NFC equality, scalar-order comparator, `fold(text, locale)`, `filterKey` (generated table); `SwiftDouble.format/parse`; `StrictUtf8`, `StrictBase64`, `Hex` | nothing; vector files from the Swift emitter |
| 0 | `core.ids` | `UuidText` (strict canonical parse, upper/lower spelling, string-order comparator), `NameBasedUuid.v5` | nothing |
| 0 | `core.clock` | `Hlc`, `HlcGenerator`, `Timestamps.toHlcMillis`, 2001-epoch helpers | nothing |
| 0 | `core.io` | `AtomicFileWriter`, `StorageLocations`, `ProtocolLocations`, `FileReads` (missing / bytes / unreadable), `LibraryGuard` (one mutex per root) | nothing |
| 0 | `core.sync.transport` | `SyncTransport` and all value types, `SyncRejection`, `SyncTransportFailure`, `SyncRoundPacing` | `WireRecord` shape only |
| 1 | `core.model` | `Snippet`, `sanitizedKeyword`, `SnippetTagging`, `SnippetDisplayOrder`, display name | `core.text` |
| 1 | `core.json` | small strict JSON tree reader/writer for local files (not the canonical codec) | `core.text` |
| 1 | `core.wire` | `CanonicalJson`, `SyncEnvelope`, `Fields`, `WireRecord`, `WireIdentity`, `WireCodec`, `interface BlobSealer` | text, ids, clock, model |
| 1 | `core.merge.DeletionSafety`; `core.sync.testing` (`InMemoryTransport`, faults, `FakeLibrary`) | pure threshold/fingerprint; reference fake | ids; transport |
| 1 | `core.search`, `core.placeholders`, `core.assist`, `core.settings`, `core.interchange` (import parser, deep links) | section 6; `interface DateRenderer` for ICU formatting and calendar arithmetic | model, text |
| 2 | `core.codec` | `SnippetLibraryCodec` (encode, decode, digest, read) | model, json |
| 2 | `core.state` | `SyncState`, `Halt`, `HaltReason`, `RecoveryContext`, `RecoveryClaim`, `SyncStateFile`, `LibraryQuarantineMarker` | clock, io, json |
| 2 | `core.sync.base` | `SyncBase`, strict codec, file | wire, io, json |
| 2 | `core.merge` | `LocalMerge` (incl. `rebaseSnapshot`), `ConflictExtensions`, `EnvelopeMerge` | wire, model |
| 3 | `core.library` | `LibraryWriter`, `LibraryTransaction`, crash marker | codec, state, io; `VaultFile` from the vault brief |
| 3 | `core.sync.journal` | `SyncJournal` (ordinary path first, `ConflictDependencies` second), strict codec, file | wire, base, merge conflict helpers |
| 3 | `core.projection` | `LibraryProjection`, sidecar, `SecureConflictMaterializer` | base, merge; `RecordCrypto` from the crypto brief |
| 4 | `core.sync.engine` | `SyncLibraryAccess` + value types, `SyncEngine` (`RoundRunner`, `ScopeReconciler`, `HaltStore`, `RecoveryController`) | transport, base, journal, merge, state, wire |
| 5 | `core.store` | `LibraryStore`, `PersistenceWorker`, `UndoHistory`, `DeletionUndo`, `ImportPlanner`, `IncomingLinkReview` | library, merge, state, model |
| 5 | `core.sync.app` | `LibraryBridge : SyncLibraryAccess` (plain path, then secure path), `SyncCoordinator` (+ `RoundRequestCoalescer`, `TriggerDebouncer`, `OfflineRetryScheduler`), `SyncStatusText`, `ProviderSelectionStore` | engine, store, projection; `KeyValueStore`, `SecretStore` from `:app` |

Interfaces to freeze before parallel work starts (signatures only):

1. `FoundationText` and `SwiftDouble`: every other package calls them; getting them wrong is invisible until interop.
2. `SyncEnvelope` API: `canonicalBytes()`, `envelopeHash()`, `contentHash`, `parse(bytes)`, `plain/secureRecord/tombstone/tombstoned`, `x: Map<String, CanonicalJson>`, two constructors (normalising and verbatim).
3. `BlobSealer { seal(plaintext, identity); open(blob, identity); revisionToken(envelopeHash) }` (crypto brief implements it; tests use an AES-GCM stub as `WireTests.swift:53-74` does).
4. `SyncTransport` (section 4) including the fail-closed defaults of the reset methods.
5. `SyncJournal` facade as the engine calls it: `reconcile`, `reconcileDependencies`, `pending`, `markOffered`, `offeredSnapshot`, `acknowledge`, `reject`, `projectionKnowledge`, `stageConflictDependency`, `recordConflictCopyEvidence`, `holdPostPrerequisiteCopyIntents`, `heldConflictCopyIntents`, `carrierResolutions`, `beginCarrierResolutions`, `prepareForAccountChange`, `prepareForNonDestructiveLibraryRecovery`. Pure functions returning a new immutable journal.
6. `EnvelopeMerge.merge(base, local, remote): EnvelopeOutcome` and the conflict helpers the journal needs (`hasUnresolvedContentConflict`, `conflictCopyProvenance`, `hasValidConflictCopyIdentity`, `deterministicUUID`).
7. `SyncLibraryAccess` (engine <-> bridge): `currentEnvelopesForRound`, `currentSnapshotForRound`, `prepareRemote`, `applyRemote(expectedPrimary, …)`, `liveIDs`, carrier and evidence methods; with the "read before first suspend" rule written into its contract.
8. `StoreSyncDelegate` (`libraryDidChange(origin)`, `userDidDeleteSnippets`, `userDidRestoreSnippets`), called synchronously.
9. Injected environment: clock (`now(): Double` seconds since 2001 and `nowMs()`), a dispatcher for pure CPU work, a process-incarnation id, `DateRenderer`, `KeyValueStore` with a synchronous checked commit.

Suggested tracks (one engineer or agent each): A text + ids + wire (critical path; start first); B clock + io + state + library; C transport + fake + base, then engine against interfaces 5-7; D merge, then projection; E journal ordinary path, then dependency graph; F search, placeholders, import, links; G store + undo, then coordinator and bridge. The engine's own tests need B, C, D and E's ordinary path; the conflict-dependency tests need all of E.

Port order for tests mirrors this: vectors and `WireTests` first, then `ClockAndStateTests`/`LibraryWriterTests`, `SyncMergeTests` + conflict-copy vectors, `SyncJournalTests`, then `SyncEngineTests` and the fault-injection suites against `InMemoryTransport`.

## 10. Open questions

### Model, codec and wire

- Size limits: `Snippet.swift` defines no name, keyword, body or count limit; the Linux port adds 256 KiB per body, 100,000 snippets, 32 MiB per file and rejects NUL (`snippets-linux/src/model.rs:17-19,107-117`). Should Android adopt those, and what should the editor do with a body that exceeds the merge payload ceiling (`SyncMerge.maximumWireCanonicalBytes`, 674,815 bytes)?
- `filterKey` parity: Foundation's fold could not be reduced to a rule (section 3) and Linux already differs from Apple outside Latin, Greek and Cyrillic. Decide whether Android (a) matches Foundation through a generated table and corpus, or (b) all platforms move to one specified fold. This brief assumes (a).
- The Foundation observations (whitespace sets incl. U+200B, fold table, `Double.description` thresholds) were measured on macOS 27.2 only. They are assumed identical on iOS 26; the vector emitter should record the OS it ran on.
- Which decoder loads Android's own `snippets.json`: the lenient `SnippetImportParser` path the Swift store uses (also accepts a Raycast-shaped file in place of the library) or the strict codec? This brief assumes the Swift behaviour.
- Byte-identical `snippets.json` (Foundation's pretty-printing) is treated as unnecessary on Android. That holds only while no feature copies the raw library file between platforms; export/import uses the wrapped dialect and is parse-compatible either way.

### Clock, files, state, journal

- `SyncState.hlc`, `cursor`, `backend`, `lastSyncAt` and `scopeID` (`snippets/Core/SyncStateFile.swift:287-307`): a grep of `snippets/`, `snippets-ios/` and `snippets-cli/` found no writer after `SyncState.fresh` and no reader besides tests (cursor and last-sync live in `SyncBase`, the journal derives clocks from evidence). They look vestigial but are required keys for decoding. Confirm before deciding whether Android writes placeholder values or drops them from its own schema.
- `TombstoneLedger` / `Sync/tombstones.json` are unreferenced in production; `docs/cloud-sync.md:307` still lists the file. Treated as dead here. Confirm nobody plans to revive the 90-day horizon, since without it tombstone envelopes are retained by whatever `SyncBase` does (section 2, `Sync/base.json`).
- `HLCGenerator.observe` and `maxDriftMs` have no production caller, so nothing rejects or adopts a remote clock at fold-in time today; drift protection may live elsewhere (merge/engine) or not exist. No `.observe(` call exists under `snippets/` or `snippets-ios/`, so a far-future remote clock is not rejected anywhere today; confirm that is intended before porting the drift code.
- The journal's `modifiedAt` is persisted but has no reader anywhere in `snippets/` or `snippets-ios/` (grep). Keep it for format parity or drop it from the Android journal schema; either is safe because the file is local.
- Android process model: this brief assumes one process. If the text-action activity, a sync worker or a content provider is ever declared with its own `android:process`, the in-process `LibraryGuard` is insufficient and a file lock (`FileChannel.lock`) plus the recheck/confirm loop become load-bearing again.
- `RecoveryClaim` liveness on Android: Swift treats a claim as abandoned when its pid (and on macOS its start time) is gone (`snippets/Core/LibraryLock.swift:281-294`). A killed-and-restarted Android app can be given the same pid; without a process start time the port needs another incarnation token (for example a per-launch random `ownerID`, which the struct already has). The exact rule the engine applies is under Halts in section 4.
- `LibraryTransaction` removes `vault.json` with a non-durable `removeItem` when the body returns a `nil` vault (`snippets/Core/LibraryTransaction.swift:185-194`); whether any iOS path does this is for the vault brief.

### Engine and transport

- Existing Android installs: `SyncMerge.swift:10-13` says a Swift core is embedded in the current Android app. If the new app replaces it in place, can it meet a Swift-written `base.json`/`journal.json`/`state.json` (old schemas, `\/` escapes, uppercase review ids)? If not, the schema 1…6 decode paths and their tests can be dropped and Kotlin only needs to read what it writes.
- The Rust port is not a structural port of `SyncEngine`: it splits the round into `sender.rs`/`receiver.rs`/`inbound.rs`/`outbound.rs` with its own checkpoint (`journal::Checkpoint`), and has no `base.json`. It confirms only the deletion threshold and fingerprint (`merge.rs:692-703`). Round ordering cannot be cross-checked against it.
- `SyncRejection.rateLimited(retryAfter:)`: the engine never reads `retryAfter` (per-record: round succeeds; call-level: generic exponential backoff, `SyncEngine.swift:2967`). Intended, or should a transport's own number bound the next attempt? No test pins either.
- Recovery-claim identity on Android: what stands in for `hostName`, `processID` and the process start time (`SyncEngine.swift:615-627`), given one app process and no CLI peer? A constant host plus PID and `/proc/self/stat` start time would keep the takeover semantics; confirm.
- Halt detail sentences mention iCloud even on Git/Snippets Cloud rounds (for example `SyncEngine.swift:1588`, `:2961`, `:3205`). Tests assert only a few substrings (`SyncEngineTests.swift:1743`). Should `:core` keep the Swift text verbatim or expose typed detail codes for the app to phrase?
- Step 16 refusal happens after `library.prepareRemote` and after conflict dependencies were staged in the journal (`SyncEngine.swift:2055-2067`), so a refused batch has already produced durable side effects (journal stage, possibly vault writes inside `prepareRemote`). The bridge's `prepareRemote` contract (section 5, Bridge) should confirm these are idempotent across the repeated rounds a mass-deletion halt implies.
- Fetch has no page cap (`SyncEngine.swift:1751-1801`): a transport that always returns `hasMore == true` spins the round, and all pages are held in memory. Confirm per transport (Git, Snippets Cloud) that paging terminates and that a full snapshot fits in memory on low-end devices.

### Merge and projection

- Conflict-name inputs outside the common case: which code points Foundation's `whitespacesAndNewlines` trims, how `Character` counts the 50-cluster cut for emoji sequences, and dates before 1582 or beyond year 9999 (Rust returns an error, Swift formats something). A differing name does not change the copy id but makes two devices publish different bytes for it. Needs Swift-emitted vectors (`snippets/Core/SyncMerge.swift:454`, `snippets/Core/Snippet.swift:445-498`).
- Swift does not check that base, local and remote share one id; Rust rejects a mismatch (`snippets-linux/src/merge.rs:560`). Kotlin should probably follow Rust; confirm.
- A secure loser without `vaultContentHash` or `vaultKID` in a content conflict cannot form a valid variant, so the merge throws and the engine halts with `localLibraryQuarantined` (`snippets/Core/SyncMerge.swift:932`, `:984`). Read from the code, no test pins it; confirm it is intended for legacy unstamped records.
- `docs/cloud-sync.md:232` records a known divergence: the old Android bridge picks the surviving body by `updatedAt`. This spec assumes the Kotlin port follows Apple and Linux (HLC, then canonical rank).
- `materialize` opens and reseals every variant even when the copy already exists, so `evidenceRecords` always consumes a nonce; the retry test asserts only that `records` is unchanged (`snippets/Core/SyncSecureConflictMaterializer.swift:83-116`). Unclear whether a port may skip the reseal on retry.
- Whether Android needs `mergeLocal` at all depends on the store design (single writer, no external file observer); `rebaseSnapshot` is needed if undo is kept.

### Store, coordinator, provider selection

- Android has no iCloud, but the Swift selection has no "no provider" value and defaults to iCloud (`snippets/Sync/SyncBackendSelectionStore.swift:650`). What `SnippetsSyncProvider` holds before Git is connected, and what the sync toggle does then, is a product decision; the nearest Swift behaviour is Git selected without coordinates → `git_configuration_required`.
- Is the Android library ever written by a second process (text action, share target, background worker in another process)? If not, the cross-process lock and the foreign-write branches of `applyPersistenceResult` are unreachable; they are specified above as written, but the answer decides whether `WriteHealth` and the 5 s lock waits need a UI.
- `Backups/unsaved-*.json` is written on a failed flush, and the comment says the next launch can offer it back (`snippets/SnippetStore.swift:1716`), but no reader exists in `snippets/`, `snippets-ios/` or `snippets-cli/`. Port the write only, or add a recovery prompt?
- `snippets-ios-tests/SyncSecureConflictDependencyIntegrationTests.swift` (7692 lines) and the Snippets Cloud half of `SyncBackendSelectionStore.swift` (`:945`–`1400`, `:1808`–`3609`) were only skimmed; the bridge's secure-conflict rules above are from the bridge source, not cross-checked against those tests.

### Search, placeholders, import, links

- Fold parity: the Foundation folding rule in the hazards list was observed by running Foundation, not read from the repo, and the Rust port's `folded` (`snippets-linux/src/model.rs:40-46`) already differs from it for kana, full-width and compatibility characters. Which is canonical for `filterKey` (tag identity, keyword collisions, import dedupe) across Mac, iOS, Linux and Android, and is disagreement outside Latin/Greek/Cyrillic acceptable?
- Search fold locale: Swift folds search text with the user locale (`snippets/Core/SnippetSearchIndex.swift:84-87`), which only changes results for `tr`/`az`/`lt`. Should Android reproduce that, or use the fixed fold everywhere?
- `FuzzyMatch.score` has no iOS caller. Does the Android text-action picker rank or highlight matches (port the scorer and its oracle test) or only filter (skip it)?
- `{date "}` traps the Swift resolver (`snippets/Core/PlaceholderResolver.swift:322-326`). The Kotlin port treats it as literal text; the Swift source probably wants the same fix, and that is outside this brief.
- Unsettled by the Swift code: share and creation links have no size cap (`snippets/Core/SnippetDeepLink.swift`), and locale validation depends on the host's locale list (Rust dropped it, `snippets-linux/src/placeholders.rs:121-129`). Should Android add a URL cap, and which locale rule should it follow?
