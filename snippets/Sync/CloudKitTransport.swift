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
    private let containerIdentifier: String
    private let accountStatusProvider: @Sendable () async throws -> CKAccountStatus
    private let userRecordIDProvider: @Sendable () async throws -> CKRecord.ID
    /// A code-signing coordinate is immutable for the lifetime of the running image.
    /// Capture it once so an in-place app update cannot make this process inspect the
    /// replacement file while its existing CloudKit connection still uses the old one.
    private let environment: CloudKitContainerEnvironment

    private let lock = NSLock()
    private var preparedAccountIdentity: SyncAccountIdentity?
    private var ensuredZoneAccountIdentity: SyncAccountIdentity?
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
        identifier: String = "icloud",
        accountStatusProvider: (@Sendable () async throws -> CKAccountStatus)? = nil,
        userRecordIDProvider: (@Sendable () async throws -> CKRecord.ID)? = nil,
        environmentProvider: (@Sendable () -> CloudKitContainerEnvironment)? = nil
    ) {
        self.identifier = identifier
        self.containerIdentifier = containerIdentifier
        let cloudContainer = CKContainer(identifier: containerIdentifier)
        container = cloudContainer
        database = cloudContainer.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.accountStatusProvider = accountStatusProvider ?? {
            try await cloudContainer.accountStatus()
        }
        self.userRecordIDProvider = userRecordIDProvider ?? {
            try await cloudContainer.userRecordID()
        }
        if let environmentProvider {
            environment = environmentProvider()
        } else {
            environment = CloudKitRuntimeEnvironment.current(
                containerIdentifier: containerIdentifier)
        }

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
    /// engine reacts to this one by scheduling a round — which begins with
    /// `resolveAccountIdentity()`, where the account state is actually established. The
    /// nudge therefore needs no opinion of its own and cannot be wrong in a direction
    /// that matters.
    ///
    /// The hint also invalidates the operation gate and zone cache immediately. A data
    /// call already in flight may still complete, but its postflight check then throws
    /// `accountChanged` and the engine trusts none of its records or acknowledgements.
    private func observeAccountChanges() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: nil
        ) { [weak self, eventContinuation] _ in
            self?.invalidateAccountScope()
            eventContinuation.yield(.changesAvailable)
        }
    }

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        let identity = try await currentAccountIdentity()
        lock.withLock {
            if preparedAccountIdentity != identity {
                ensuredZoneAccountIdentity = nil
            }
            preparedAccountIdentity = identity
        }
        return identity
    }

    private func currentAccountIdentity() async throws -> SyncAccountIdentity {
        guard environment != .unrecognized else {
            // Guessing here can make a Development change token look like Production
            // state. This is a build/signing failure, not a transient account status.
            throw SyncTransportFailure.rejected(.permanent(
                detail: "the signed app's CloudKit environment could not be verified"))
        }

        let status: CKAccountStatus
        do {
            status = try await accountStatusProvider()
        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .accountStatus,
                failure: DiagnosticFailure(error)))
            throw CloudKitErrorMapping.failure(for: error)
        }
        if let failure = status.syncBlockingFailure {
            throw failure
        }
        do {
            let userRecordID = try await userRecordIDProvider()
            return CloudKitAccountIdentity.derive(
                containerIdentifier: containerIdentifier,
                databaseScope: .private,
                environment: environment,
                userRecordID: userRecordID)
        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .accountStatus,
                failure: DiagnosticFailure(error)))
            throw CloudKitErrorMapping.failure(for: error)
        }
    }

    private func beginAccountOperation() async throws -> SyncAccountIdentity {
        guard let expected = lock.withLock({ preparedAccountIdentity }) else {
            throw SyncTransportFailure.unreachable(
                detail: "the iCloud account checkpoint has not been established")
        }
        try await verifyAccountIdentity(expected)
        return expected
    }

    private func verifyAccountIdentity(_ expected: SyncAccountIdentity) async throws {
        guard lock.withLock({ preparedAccountIdentity == expected }) else {
            throw SyncTransportFailure.accountChanged
        }
        let current = try await currentAccountIdentity()
        guard current == expected,
              lock.withLock({ preparedAccountIdentity == expected }) else {
            invalidateAccountScope()
            throw SyncTransportFailure.accountChanged
        }
    }

    private func invalidateAccountScope() {
        lock.withLock {
            preparedAccountIdentity = nil
            ensuredZoneAccountIdentity = nil
        }
    }

    // MARK: - Zone

    /// Creates the custom zone if it is not there, and is safe to call concurrently.
    ///
    /// Saving a zone that already exists succeeds, so two callers racing here cost one
    /// redundant request and nothing else. That is why there is no single-flight `Task`
    /// and no lock held across the `await`: the cheap wrong thing is genuinely harmless
    /// and the expensive right thing could deadlock.
    private func ensureZone(for accountIdentity: SyncAccountIdentity) async throws {
        let alreadyDone = lock.withLock {
            ensuredZoneAccountIdentity == accountIdentity
        }
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

        lock.withLock {
            if preparedAccountIdentity == accountIdentity {
                ensuredZoneAccountIdentity = accountIdentity
            }
        }
    }

    private func forgetZone() {
        lock.withLock { ensuredZoneAccountIdentity = nil }
    }

    // MARK: - Fetch

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        let accountIdentity = try await beginAccountOperation()
        try await ensureZone(for: accountIdentity)
        try await verifyAccountIdentity(accountIdentity)

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
            let fetched = try await page(
                since: token,
                isFullResync: cursorWasUnreadable,
                accountIdentity: accountIdentity)
            try await verifyAccountIdentity(accountIdentity)
            return fetched
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
            try await ensureZone(for: accountIdentity)
            try await verifyAccountIdentity(accountIdentity)
            let fetched = try await page(
                since: nil,
                isFullResync: true,
                accountIdentity: accountIdentity)
            try await verifyAccountIdentity(accountIdentity)
            return fetched
        } catch let failure as SyncTransportFailure {
            throw failure
        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .fetchChanges,
                failure: DiagnosticFailure(error)))
            throw CloudKitErrorMapping.failure(for: error)
        }
    }

    private func page(
        since token: CKServerChangeToken?,
        isFullResync: Bool,
        accountIdentity: SyncAccountIdentity
    ) async throws -> SyncFetch {
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
        for (_, outcome) in modifications {
            switch outcome {
            case .success(let modification):
                do {
                    records.append(try CloudKitRecordMapping.makeWireRecord(
                        from: modification.record,
                        expectedZoneID: zoneID))
                } catch {
                    // Advancing the change token past an un-mappable record permanently
                    // loses both its payload and its system fields. Fail the page closed;
                    // a schema/app mismatch needs repair or an update, not a cursor that
                    // claims the skipped value was durably applied.
                    throw SyncTransportFailure.rejected(.permanent(
                        detail: "CloudKit returned a snippet record this build cannot map"))
                }
            case .failure(let error):
                // The page is not complete, therefore its token is not a durability
                // boundary. Retain the old cursor and retry/halt according to policy.
                throw CloudKitErrorMapping.failure(for: error)
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
            Diagnostics.record(.cloudKitRecordsIgnored(count: result.deletions.count))
        }

        return SyncFetch(
            records: records,
            cursor: CloudKitCursor.encode(result.changeToken),
            hasMore: result.moreComing,
            isFullResync: isFullResync,
            accountIdentity: accountIdentity)
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
        let accountIdentity = try await beginAccountOperation()
        guard !records.isEmpty else {
            return SyncSubmission(
                results: [], cursor: cursor, accountIdentity: accountIdentity)
        }

        try await ensureZone(for: accountIdentity)
        try await verifyAccountIdentity(accountIdentity)

        var outcomes: [UUID: SyncSubmitOutcome] = [:]
        for chunk in Self.chunk(records) {
            let chunkOutcomes = try await submit(
                chunk: chunk,
                accountIdentity: accountIdentity)
            outcomes.merge(chunkOutcomes) { _, newer in newer }
        }
        try await verifyAccountIdentity(accountIdentity)

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
        return SyncSubmission(
            results: results,
            cursor: cursor,
            accountIdentity: accountIdentity)
    }

    private func submit(
        chunk: [WireRecord],
        accountIdentity: SyncAccountIdentity
    ) async throws -> [UUID: SyncSubmitOutcome] {
        try await verifyAccountIdentity(accountIdentity)
        var outcomes: [UUID: SyncSubmitOutcome] = [:]
        var toSave: [CKRecord] = []

        for wire in chunk {
            do {
                let record = try CloudKitRecordMapping.makeRecord(from: wire, in: zoneID)
                toSave.append(record)
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
            // The restored `recordChangeTag` is the per-record compare-and-swap token.
            // A create (or a legacy/corrupt cache entry) has no tag and therefore
            // conflicts rather than overwriting when the id already exists.
            let (saveResults, _) = try await database.modifyRecords(
                saving: toSave,
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false)
            try await verifyAccountIdentity(accountIdentity)

            var firstItemFailure: DiagnosticFailure?
            for wire in chunk where outcomes[wire.id] == nil {
                let recordID = CloudKitRecordMapping.recordID(for: wire.id, in: zoneID)
                let item = saveResults[recordID]
                outcomes[wire.id] = Self.submissionOutcome(
                    for: wire,
                    result: item,
                    expectedZoneID: zoneID)
                if case .failure(let error)? = item, firstItemFailure == nil {
                    firstItemFailure = DiagnosticFailure(error)
                }
            }
            if let firstItemFailure {
                Diagnostics.record(.cloudKitFailure(
                    operation: .modifyRecords,
                    failure: firstItemFailure))
            }
            return outcomes

        } catch let failure as SyncTransportFailure {
            throw failure

        } catch let error where CloudKitErrorMapping.isBatchTooLarge(error) && chunk.count > 1 {
            // The documented limits are prose; this is the empirical one. Halve and
            // recurse, so a request that was too big becomes two that are not.
            let middle = chunk.count / 2
            Diagnostics.record(.cloudKitBatchSplit(recordCount: chunk.count))
            let first = try await submit(
                chunk: Array(chunk[..<middle]),
                accountIdentity: accountIdentity)
            let second = try await submit(
                chunk: Array(chunk[middle...]),
                accountIdentity: accountIdentity)
            return outcomes
                .merging(first) { _, newer in newer }
                .merging(second) { _, newer in newer }

        } catch {
            Diagnostics.record(.cloudKitFailure(
                operation: .modifyRecords,
                failure: DiagnosticFailure(error)))
            // A partial failure arrives as a thrown `CKError` carrying per-item errors.
            // Unwrap the named failures, while retaining every unnamed item as an
            // ambiguous durable offer because this API shape returned no saved record.
            if let partial = CloudKitErrorMapping.partialErrors(in: error) {
                for wire in chunk where outcomes[wire.id] == nil {
                    let recordID = CloudKitRecordMapping.recordID(for: wire.id, in: zoneID)
                    let item = partial[recordID].map {
                        Result<CKRecord, any Error>.failure($0)
                    }
                    // CloudKit's thrown partial error does not carry returned saved
                    // CKRecords for unnamed items. They may have succeeded, but without
                    // their new system fields that is an ambiguous acknowledgement, not
                    // an acceptance. The durable offer will safely conflict/reconcile on
                    // retry.
                    outcomes[wire.id] = Self.submissionOutcome(
                        for: wire,
                        result: item,
                        expectedZoneID: zoneID)
                }
                try await verifyAccountIdentity(accountIdentity)
                return outcomes
            }
            throw CloudKitErrorMapping.failure(for: error)
        }
    }

    /// Converts exactly one returned CloudKit item into the transport contract.
    ///
    /// Kept internal and pure enough for app-target tests: correctness must not require
    /// a live signed container merely to prove that a missing returned record cannot be
    /// mistaken for acceptance.
    static func submissionOutcome(
        for wire: WireRecord,
        result: Result<CKRecord, any Error>?,
        expectedZoneID: CKRecordZone.ID? = nil
    ) -> SyncSubmitOutcome {
        guard let result else {
            return .rejected(.rateLimited(retryAfter: 5))
        }

        switch result {
        case .success(let saved):
            do {
                let returned = try CloudKitRecordMapping.makeWireRecord(
                    from: saved,
                    expectedZoneID: expectedZoneID)
                guard returned.id == wire.id,
                      returned.rev == wire.rev,
                      returned.deleted == wire.deleted,
                      returned.blob == wire.blob,
                      let recordVersion = returned.recordVersion else {
                    return .rejected(.rateLimited(retryAfter: 5))
                }
                return .accepted(
                    rev: returned.rev,
                    recordVersion: recordVersion)
            } catch {
                // The write may already have landed. Without a returned generation the
                // only honest outcome is ambiguous/retryable; reporting permanent would
                // freeze an offer that a later conflict can resolve.
                return .rejected(.rateLimited(retryAfter: 5))
            }

        case .failure(let error):
            var rejection = CloudKitErrorMapping.rejection(for: error)
            if case .conflict = rejection,
               let ckError = error as? CKError,
               let server = ckError.serverRecord,
               let remote = try? CloudKitRecordMapping.makeWireRecord(
                    from: server,
                    expectedZoneID: expectedZoneID),
               remote.id == wire.id {
                rejection = .conflict(remote: remote)
            }
            return .rejected(rejection)
        }
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
