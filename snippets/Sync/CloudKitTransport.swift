import CloudKit
import Foundation

// App target only — see the note at the top of `CloudKitRecordMapping.swift`.

/// `SyncTransport` over CloudKit's private database.
///
/// ## Why this is hand-rolled rather than `CKSyncEngine`
///
/// `CKSyncEngineState` is an outbox: you tell it what changed by calling
/// `add(pendingRecordZoneChanges:)`. `SyncBase` is deliberately **not** an outbox — its
/// own comment says the pending set is derived as `diff(base, current)` "because plenty
/// of changes never pass through code that could record them: a stale CLI, an old app
/// build, `vim`, a Time Machine restore." Adopting `CKSyncEngine` therefore means either
/// keeping two sources of truth about what needs pushing, or giving up the property that
/// an edit made in `vim` still syncs. The second undoes Phase 1; the first is the bug
/// Phase 1 was about.
///
/// What is left to hand-roll is small, because the macOS 12+ async wrappers already
/// return very nearly the shape this protocol wants:
/// `recordZoneChanges(inZoneWith:since:)` hands back
/// `(modificationResultsByID:, deletions:, changeToken:, moreComing:)`, which is
/// `SyncFetch` after a sort. This is a translation layer, not a reimplementation.
///
/// ## Concurrency
///
/// A `final class` with an `NSLock` rather than an `actor`, for the same reason
/// `InMemoryTransport` is: `SyncTransport` is a `nonisolated` protocol and `events` is a
/// synchronous property requirement, which an actor's isolated stored property cannot
/// satisfy. The lock is never held across an `await` — holding one over a slow CloudKit
/// call is a deadlock waiting for Apple to have a bad day.
nonisolated final class CloudKitTransport: SyncTransport, @unchecked Sendable {

    let identifier: String

    /// **This reads as "accepts writes", not "delivers notifications".**
    ///
    /// `SyncEngine` uses it at exactly one place — `guard transport.supportsPush else {
    /// throw .pushUnsupported }`, immediately before submitting — so returning `false`
    /// here would not disable notifications, it would refuse to upload anything at all
    /// while reporting a "this backend does not accept pushes" authentication error.
    /// CloudKit accepts writes, so this is `true`.
    ///
    /// Whether anything *notifies* us is a separate question, and today the answer is
    /// no: the entitlements file does not request `com.apple.developer.aps-environment`,
    /// so there are no CloudKit push subscriptions and nothing will ever yield
    /// `.changesAvailable` from a server nudge. That makes `pollInterval` load-bearing
    /// rather than a backstop — see below.
    let supportsPush = true

    /// Load-bearing, not a fallback.
    ///
    /// With no APNs entitlement this is the *only* thing that makes a remote change
    /// arrive. Two minutes is chosen against that: it is the longest delay that still
    /// feels like sync rather than like a scheduled job, and CloudKit's rate limits are
    /// nowhere near it for a library of this size. Once `aps-environment` and a
    /// `CKDatabaseSubscription` exist, this becomes the missed-notification safety net it
    /// is described as in the protocol and can grow considerably.
    let pollInterval: TimeInterval = 120

    let events: AsyncStream<SyncTransportEvent>
    private let eventContinuation: AsyncStream<SyncTransportEvent>.Continuation

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    private let lock = NSLock()
    private var hasEnsuredZone = false
    private var accountObserver: (any NSObjectProtocol)?

    /// CloudKit documents 400 records and 2 MB per request as prose, not as API — there
    /// is no constant to read and no call that reports the current value. So the
    /// transport chunks well inside both and *also* handles `limitExceeded` by halving,
    /// because a documented limit that cannot be queried is a limit that will change.
    private static let maxRecordsPerRequest = 200
    private static let maxBytesPerRequest = 1_500_000

    init(
        containerIdentifier: String = CloudKitSchema.containerIdentifier,
        zoneName: String = CloudKitSchema.zoneName,
        identifier: String = "icloud"
    ) {
        self.identifier = identifier
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

        // `.unbounded` for the same reason the fake uses it: a dropped event would be
        // indistinguishable from a transport that quietly discards them.
        var continuation: AsyncStream<SyncTransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventContinuation = continuation

        observeAccountChanges()
    }

    deinit {
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
        eventContinuation.finish()
    }

    // MARK: - Account

    /// The user signed out, signed in, or switched Apple ID.
    ///
    /// Yielded as `.changesAvailable` rather than as a considered verdict, deliberately.
    /// An event is documented as "a *hint* that costs nothing to be wrong about", and the
    /// engine reacts to this one by scheduling a fetch — which begins with
    /// `preflightAccount()`, which is where the account state is actually established. So
    /// the nudge needs no opinion of its own, and cannot be wrong in a direction that
    /// matters.
    ///
    /// **What this does not do**, and must not be mistaken for: a switched Apple ID makes
    /// `Sync/base.json` describe a different account's records. The library survives
    /// (absence is never a delete) but every local envelope compares equal to the stale
    /// base, so `pendingChanges` returns nothing and sync becomes a permanent silent
    /// no-op that reports `.idle`. Fixing that means recording the container's user
    /// record name in `SyncBase` and discarding it on mismatch — engine state, not
    /// transport state, and not done here.
    private func observeAccountChanges() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: nil
        ) { [eventContinuation] _ in
            eventContinuation.yield(.changesAvailable)
        }
    }

    private func preflightAccount() async throws {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .accountStatus,
                failure: DiagnosticFailure(error)))
            throw CloudKitErrorMapping.failure(for: error)
        }
        if let failure = status.syncBlockingFailure {
            throw failure
        }
    }

    // MARK: - Zone

    /// Creates the custom zone if it is not there, and is safe to call concurrently.
    ///
    /// Saving a zone that already exists succeeds, so two callers racing here cost one
    /// redundant request and nothing else. That is why there is no single-flight `Task`
    /// and no lock held across the `await`: the cheap wrong thing is genuinely harmless
    /// and the expensive right thing could deadlock.
    private func ensureZone() async throws {
        let alreadyDone = lock.withLock { hasEnsuredZone }
        if alreadyDone { return }

        do {
            _ = try await database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .ensureZone,
                failure: DiagnosticFailure(error)))
            throw CloudKitErrorMapping.failure(for: error)
        }

        lock.withLock { hasEnsuredZone = true }
    }

    private func forgetZone() {
        lock.withLock { hasEnsuredZone = false }
    }

    // MARK: - Fetch

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        try await preflightAccount()
        try await ensureZone()

        let token = CloudKitCursor.decode(cursor)

        // A cursor that was stored but will not decode is a cursor we cannot honour. Say
        // so, rather than starting from the beginning while claiming to be a delta — the
        // difference is the whole reason `isFullResync` exists, because the engine must
        // not infer deletions from a snapshot's absences.
        let cursorWasUnreadable = cursor != nil && token == nil
        if cursorWasUnreadable {
            eventContinuation.yield(.cursorInvalidated(
                reason: "the stored iCloud change token could not be read"))
        }

        do {
            return try await page(since: token, isFullResync: cursorWasUnreadable)
        } catch let error where CloudKitErrorMapping.isCursorLost(error) {
            // `changeTokenExpired` means the server pruned our place in the feed.
            // `zoneNotFound` / `userDeletedZone` mean the zone itself is gone — which is
            // exactly what "Reset Development Environment" in the CloudKit Dashboard
            // does, so this path runs often while iterating, not only in disasters.
            Diagnostics.record(.cloudKitFailure(
                operation: .fetchChanges,
                failure: DiagnosticFailure(error)))
            forgetZone()
            eventContinuation.yield(.cursorInvalidated(reason: describe(error)))
            try await ensureZone()
            return try await page(since: nil, isFullResync: true)
        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .fetchChanges,
                failure: DiagnosticFailure(error)))
            throw CloudKitErrorMapping.failure(for: error)
        }
    }

    private func page(since token: CKServerChangeToken?, isFullResync: Bool) async throws -> SyncFetch {
        let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)

        // CloudKit hands back a *dictionary*, so there is no backend order to forward.
        // The protocol requires an order because the engine applies a page in sequence
        // and a page may legitimately contain the same id twice. Sorting by modification
        // date, then by record name to break ties, gives the one property that actually
        // matters: it is deterministic, so two devices applying the same page reach the
        // same state and a test can assert on it.
        let modifications = result.modificationResultsByID
            .sorted { left, right in
                let leftRecord = try? left.value.get().record
                let rightRecord = try? right.value.get().record
                let leftDate = leftRecord?.modificationDate ?? .distantPast
                let rightDate = rightRecord?.modificationDate ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return left.key.recordName < right.key.recordName
            }

        var records: [WireRecord] = []
        var ignoredRecords = 0
        var firstIgnoredFailure: DiagnosticFailure?
        for (_, outcome) in modifications {
            switch outcome {
            case .success(let modification):
                do {
                    records.append(try CloudKitRecordMapping.makeWireRecord(from: modification.record))
                } catch {
                    // A record whose shape this build does not understand. Dropped from
                    // the page rather than thrown, because throwing would stall the whole
                    // feed behind one bad record forever. The engine's own quarantine
                    // handles the undecryptable case; this is the un-*mappable* one,
                    // which means the CloudKit schema is not what this build expects.
                    ignoredRecords += 1
                    if firstIgnoredFailure == nil {
                        firstIgnoredFailure = DiagnosticFailure(error)
                    }
                }
            case .failure(let error):
                // Per-record failure inside a fetch. Logged, not thrown, for the same
                // reason — and not treated as a deletion, which is the one reading that
                // could lose data.
                ignoredRecords += 1
                if firstIgnoredFailure == nil {
                    firstIgnoredFailure = DiagnosticFailure(error)
                }
            }
        }

        // Deletions are logged and dropped, on purpose.
        //
        // This transport never issues a CloudKit delete: a removed snippet is a *save*
        // with `deleted = true`, because a tombstone has to survive in the feed for other
        // devices to learn about it. So a deletion arriving here was not produced by us —
        // it is a zone reset, a Dashboard action, or another client — and inferring
        // "remove this snippet" from it is the fastest known way to wipe a library.
        if !result.deletions.isEmpty {
            ignoredRecords += result.deletions.count
        }
        if ignoredRecords > 0 {
            Diagnostics.record(.cloudKitRecordsIgnored(count: ignoredRecords))
        }
        if let firstIgnoredFailure {
            Diagnostics.record(.cloudKitFailure(
                operation: .fetchChanges,
                failure: firstIgnoredFailure))
        }

        return SyncFetch(
            records: records,
            cursor: CloudKitCursor.encode(result.changeToken),
            hasMore: result.moreComing,
            isFullResync: isFullResync)
    }

    // MARK: - Submit

    /// - Parameter cursor: ignored, and it has to be.
    ///
    /// The parameter exists so a backend can detect "you wrote this from a stale view"
    /// for a record it has never seen before. CloudKit has no such concept: writes are
    /// addressed per record and arbitrated by `recordChangeTag`, with nothing that means
    /// "apply this batch as of feed position N". Pretending otherwise would be worse than
    /// ignoring it, so it is ignored explicitly and the returned cursor is the one that
    /// came in — this call learned nothing about the feed position, and the engine is in
    /// any case documented never to adopt a submit's cursor as a fetch position.
    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        guard !records.isEmpty else { return SyncSubmission(results: [], cursor: cursor) }

        try await preflightAccount()
        try await ensureZone()

        var outcomes: [UUID: SyncSubmitOutcome] = [:]
        for chunk in Self.chunk(records) {
            let chunkOutcomes = try await submit(chunk: chunk)
            outcomes.merge(chunkOutcomes) { _, newer in newer }
        }

        // Re-projected onto the submitted array, in the submitted order.
        //
        // `SyncSubmission.results` is documented as parallel to the batch, and the engine
        // is entitled to rely on it. Anything the backend did not mention becomes a
        // *retryable* rejection rather than an acceptance: an unreported record must not
        // be recorded in the base, or it is never pushed again, and it must not be fatal,
        // because "CloudKit did not mention it" is not evidence of anything permanent.
        let results = records.map { wire in
            SyncSubmitResult(
                id: wire.id,
                outcome: outcomes[wire.id] ?? .rejected(.rateLimited(
                    retryAfter: 5)))
        }
        return SyncSubmission(results: results, cursor: cursor)
    }

    private func submit(chunk: [WireRecord]) async throws -> [UUID: SyncSubmitOutcome] {
        var outcomes: [UUID: SyncSubmitOutcome] = [:]
        var toSave: [CKRecord] = []
        var byRecordName: [String: UUID] = [:]

        for wire in chunk {
            do {
                let record = try CloudKitRecordMapping.makeRecord(from: wire, in: zoneID)
                toSave.append(record)
                byRecordName[record.recordID.recordName] = wire.id
            } catch {
                // Refused before it ever reaches the network — currently only the
                // oversized-blob case. Permanent because retrying an 800 KB snippet
                // produces the same 800 KB snippet.
                outcomes[wire.id] = .rejected(.permanent(detail: describe(error)))
                Diagnostics.record(.cloudKitFailure(
                    operation: .mapRecord,
                    failure: DiagnosticFailure(error)))
            }
        }

        guard !toSave.isEmpty else { return outcomes }

        do {
            // `atomically: false` matters, and the default is `true`.
            //
            // A custom zone is atomic-capable, so with the default a single bad record
            // makes CloudKit refuse every sibling in the request with
            // `batchRequestFailed` — turning one unsyncable snippet into a library that
            // never syncs. Partial acceptance is not an error here; it is the common case
            // under a rate limit, and `SyncSubmission` exists to express it.
            //
            // `savePolicy: .allKeys` is the other half. It does not compare change tags,
            // so the transport needs no cached per-record system fields — no sidecar file
            // to keep, corrupt, or migrate. Conflicts are not lost by this: the engine
            // resolves them with a three-way merge on the *fetch* leg, and never reads
            // `SyncRejection.conflict`'s `remoteRev`.
            let (saveResults, _) = try await database.modifyRecords(
                saving: toSave, deleting: [], savePolicy: .allKeys, atomically: false)

            var firstItemFailure: DiagnosticFailure?
            for (recordID, outcome) in saveResults {
                guard let id = byRecordName[recordID.recordName] else { continue }
                switch outcome {
                case .success(let saved):
                    // The rev we sent, read back from the stored record — not
                    // CloudKit's `recordChangeTag`.
                    //
                    // `WireCodec.open` recomputes `rev` from the envelope and quarantines
                    // a mismatch, so substituting a server-assigned revision here would
                    // make every record this device pushes come back undecryptable. The
                    // symptom would be "nothing ever arrives", which is the hardest
                    // possible thing to attribute to this line.
                    let rev = saved[CloudKitSchema.Field.rev] as? String
                    outcomes[id] = .accepted(rev: rev ?? revision(of: id, in: chunk))
                case .failure(let error):
                    outcomes[id] = .rejected(CloudKitErrorMapping.rejection(for: error))
                    if firstItemFailure == nil {
                        firstItemFailure = DiagnosticFailure(error)
                    }
                }
            }
            if let firstItemFailure {
                Diagnostics.record(.cloudKitFailure(
                    operation: .modifyRecords,
                    failure: firstItemFailure))
            }
            return outcomes

        } catch let error where CloudKitErrorMapping.isBatchTooLarge(error) && chunk.count > 1 {
            // The documented limits are prose; this is the empirical one. Halve and
            // recurse, so a request that was too big becomes two that are not.
            let middle = chunk.count / 2
            Diagnostics.record(.cloudKitBatchSplit(recordCount: chunk.count))
            let first = try await submit(chunk: Array(chunk[..<middle]))
            let second = try await submit(chunk: Array(chunk[middle...]))
            return outcomes
                .merging(first) { _, newer in newer }
                .merging(second) { _, newer in newer }

        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .modifyRecords,
                failure: DiagnosticFailure(error)))
            // A partial failure arrives as a thrown `CKError` carrying per-item errors.
            // Unwrapping it is what keeps a half-accepted batch from being reported as a
            // total loss.
            if let partial = CloudKitErrorMapping.partialErrors(in: error) {
                for (recordID, itemError) in partial {
                    guard let id = byRecordName[recordID.recordName] else { continue }
                    outcomes[id] = .rejected(CloudKitErrorMapping.rejection(for: itemError))
                }
                // Anything not named in the partial error succeeded.
                for wire in chunk where outcomes[wire.id] == nil {
                    outcomes[wire.id] = .accepted(rev: wire.rev)
                }
                return outcomes
            }
            throw CloudKitErrorMapping.failure(for: error)
        }
    }

    private func revision(of id: UUID, in chunk: [WireRecord]) -> String {
        chunk.first { $0.id == id }?.rev ?? ""
    }

    /// Splits a batch to stay inside both of CloudKit's undocumented-as-API limits.
    static func chunk(_ records: [WireRecord]) -> [[WireRecord]] {
        var chunks: [[WireRecord]] = []
        var current: [WireRecord] = []
        var currentBytes = 0

        for record in records {
            let size = record.blob.count + record.rev.utf8.count + 64
            let wouldExceed = current.count >= maxRecordsPerRequest
                || (!current.isEmpty && currentBytes + size > maxBytesPerRequest)
            if wouldExceed {
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            current.append(record)
            currentBytes += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}
