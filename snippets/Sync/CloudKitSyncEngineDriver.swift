import CloudKit
import Foundation

// App target only — CloudKit never crosses into CorePackage or snippets-cli.

/// Transfers cancellation ownership out of the live driver state. Each scheduler epoch
/// belongs to one cancellation drain, so later shutdown/recovery passes cannot re-enter
/// CloudKit with the same instance.
nonisolated enum CloudKitEngineCancellationDrain {
    static func take<Engine: AnyObject>(
        active: inout Engine?,
        retired: inout [Engine]
    ) -> [Engine] {
        if let current = active {
            retired.append(current)
            active = nil
        }

        var seen: Set<ObjectIdentifier> = []
        let drained = retired.filter { seen.insert(ObjectIdentifier($0)).inserted }
        retired.removeAll(keepingCapacity: false)
        return drained
    }

}

/// Thin CKSyncEngine delegate/driver. It translates Apple callback values into neutral
/// DTOs; durable ordering, inbox replay, journal ownership, and account policy live in
/// `CloudKitSyncTransportAdapter` and Core's existing `SyncEngine`.
nonisolated final class CloudKitSyncEngineDriver: NSObject,
    CloudKitSyncDriving, CKSyncEngineDelegate, @unchecked Sendable
{
    let automaticallySync = true
    let events: AsyncStream<CloudKitSyncDriverEvent>

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let initialSerialization: Data?
    private let allowInitialZoneCreation: Bool
    private let zonePreparation = CloudKitZonePreparation()
    private let eventContinuation: AsyncStream<CloudKitSyncDriverEvent>.Continuation
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private var started = false
    private var pendingUntrackedBeforeStart = false
    private var configuredBatchProvider: (@Sendable (
        CloudKitSyncSendScope, Int
    ) async -> CloudKitRecordZoneChangeBatch?)?
    private var activeBatchProvider: (@Sendable (
        CloudKitSyncSendScope, Int
    ) async -> CloudKitRecordZoneChangeBatch?)?
    private var eventHandler: (@Sendable (CloudKitSyncDriverEvent) async -> Void)?
    private var eventHandlerDepth = 0
    private var eventHandlerReturnWaiters: [CheckedContinuation<Void, Never>] = []
    private var issuedRecords: [UUID: WireRecord] = [:]
    private var retiredEngines: [CKSyncEngine] = []
    private let cancellationBarrier = CloudKitSingleFlightCancellationBarrier()

    init(
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        stateSerialization: Data?,
        allowInitialZoneCreation: Bool
    ) {
        self.database = database
        self.zoneID = zoneID
        initialSerialization = stateSerialization
        self.allowInitialZoneCreation = allowInitialZoneCreation

        var continuation: AsyncStream<CloudKitSyncDriverEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventContinuation = continuation
        super.init()
    }

    deinit {
        eventContinuation.finish()
    }

    var hasPendingUntrackedChanges: Bool {
        get {
            let snapshot = lock.withLock { (engine, pendingUntrackedBeforeStart) }
            return snapshot.0?.state.hasPendingUntrackedChanges ?? snapshot.1
        }
        set {
            let running = lock.withLock { () -> CKSyncEngine? in
                pendingUntrackedBeforeStart = newValue
                return engine
            }
            running?.state.hasPendingUntrackedChanges = newValue
        }
    }

    func installBatchProvider(
        _ provider: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncSendScope, Int
        ) async -> CloudKitRecordZoneChangeBatch?
    ) {
        lock.withLock {
            configuredBatchProvider = provider
            if engine != nil { activeBatchProvider = provider }
        }
    }

    func installEventHandler(
        _ handler: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncDriverEvent
        ) async -> Void
    ) {
        lock.withLock { eventHandler = handler }
    }

    func start() throws {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        // A genuinely fresh scheduler must not exist until its custom zone is durably
        // saved. With automatic scheduling enabled, constructing it any earlier allows
        // its first fetch to race zone creation.
        guard !(initialSerialization == nil && allowInitialZoneCreation) else { return }
        try installEngine(from: initialSerialization)
    }

    func completeFirstFetchPreparation() throws {
        try installEngine(from: initialSerialization)
    }

    func prepareForFirstFetch() async throws {
        let needsZoneBootstrap = initialSerialization == nil && allowInitialZoneCreation
        if needsZoneBootstrap {
            try await zonePreparation.run { [database, zoneID] in
                do {
                    let result = try await database.modifyRecordZones(
                        saving: [CKRecordZone(zoneID: zoneID)],
                        deleting: [])
                    guard let save = result.saveResults[zoneID] else {
                        throw SyncTransportFailure.rejected(.permanent(
                            detail: "CloudKit did not confirm creation of the snippet zone"))
                    }
                    do {
                        _ = try save.get()
                    } catch {
                        throw CloudKitErrorMapping.failure(for: error)
                    }
                } catch let failure as SyncTransportFailure {
                    throw failure
                } catch {
                    throw CloudKitErrorMapping.failure(for: error)
                }
            }
        }
    }

    func restart(from stateSerialization: Data?) throws {
        try installEngine(from: stateSerialization, replacingExisting: true)
    }

    func invalidate() {
        lock.withLock {
            if let engine {
                retiredEngines.append(engine)
            }
            engine = nil
            activeBatchProvider = nil
            issuedRecords.removeAll(keepingCapacity: false)
        }
    }

    func waitForEventHandlerReturn() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                guard eventHandlerDepth > 0 else { return true }
                eventHandlerReturnWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func sendChanges() async throws {
        guard let engine = lock.withLock({ self.engine }) else {
            throw SyncTransportFailure.unreachable(
                detail: "the CloudKit scheduler did not start")
        }
        do {
            try await engine.sendChanges()
        } catch {
            if CloudKitErrorMapping.containsZoneInvalidation(error, for: zoneID) {
                poison(engine)
                await deliver(.remoteDataLoss(.zoneDeleted))
                return
            }
            // CKSyncEngine has already awaited and delivered the per-record outcomes.
            // Let the adapter consume them; any item absent from those callbacks remains
            // retryable in `finishSubmit()` and is never mistaken for an acceptance.
            if CloudKitErrorMapping.isIncompleteOperationResult(error) { return }
            Diagnostics.record(.cloudKitFailure(
                operation: .modifyRecords,
                failure: DiagnosticFailure(error)))
            throw CloudKitErrorMapping.failure(for: error)
        }
    }

    func fetchChanges() async throws {
        guard let engine = lock.withLock({ self.engine }) else {
            throw SyncTransportFailure.unreachable(
                detail: "the CloudKit scheduler did not start")
        }
        do {
            var options = CKSyncEngine.FetchChangesOptions()
            options.scope = .zoneIDs([zoneID])
            try await engine.fetchChanges(options)
        } catch {
            if CloudKitErrorMapping.containsZoneInvalidation(error, for: zoneID) {
                poison(engine)
                await deliver(.remoteDataLoss(.zoneDeleted))
                return
            }
            let scopedError = CloudKitErrorMapping.zoneError(in: error, for: zoneID)
                ?? error
            Diagnostics.record(.cloudKitFailure(
                operation: .fetchChanges,
                failure: DiagnosticFailure(scopedError)))
            throw CloudKitErrorMapping.failure(for: scopedError)
        }
    }

    func cancelOperations() async {
        // A terminal delegate callback schedules cancellation after it unwinds, while
        // transport shutdown may arrive concurrently. Serialize the whole drain + await
        // operation: a later shutdown must join the in-flight cancellation instead of
        // observing an already-drained retiredEngines array and returning too early.
        // Taking the active engine also detaches it, which makes a second cancellation
        // drain a no-op instead of re-entering CloudKit with the same scheduler epoch.
        await cancellationBarrier.perform { [self] in
            let toCancel = lock.withLock { () -> [CKSyncEngine] in
                let engines = CloudKitEngineCancellationDrain.take(
                    active: &engine,
                    retired: &retiredEngines)
                activeBatchProvider = nil
                issuedRecords.removeAll(keepingCapacity: false)
                return engines
            }
            for engine in toCancel {
                await engine.cancelOperations()
            }
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard lock.withLock({ engine === syncEngine }) else { return }

        switch event {
        case .stateUpdate(let update):
            do {
                let data = try PropertyListEncoder().encode(update.stateSerialization)
                await deliver(.stateUpdate(data))
            } catch {
                await deliver(.operationFailed(.rejected(.permanent(
                    detail: "CloudKit scheduler state could not be persisted"))))
            }

        case .accountChange(let change):
            let mapped = Self.accountChange(for: change.changeType)
            if mapped != .signIn { poison(syncEngine) }
            await deliver(.accountChange(mapped))

        case .willFetchChanges:
            await deliver(.willFetch)

        case .fetchedRecordZoneChanges(let fetched):
            guard fetched.modifications.allSatisfy({ $0.record.recordID.zoneID == zoneID }),
                  fetched.deletions.allSatisfy({ $0.recordID.zoneID == zoneID }) else {
                await deliver(.operationFailed(.rejected(.permanent(
                    detail: "CloudKit returned records outside the snippet zone"))))
                return
            }
            if !fetched.deletions.isEmpty {
                poison(syncEngine)
                await deliver(.remoteDataLoss(.physicalRecordDeletion))
                return
            }
            do {
                let records = try fetched.modifications.map {
                    try CloudKitRecordMapping.makeWireRecord(
                        from: $0.record,
                        expectedZoneID: zoneID)
                }
                await deliver(.fetchedRecords(
                    records,
                    physicalDeletionCount: 0))
            } catch {
                await deliver(.operationFailed(.rejected(.permanent(
                    detail: "CloudKit returned a snippet record this build cannot map"))))
            }

        case .fetchedDatabaseChanges(let fetched):
            if let deletion = fetched.deletions.first(where: { $0.zoneID == zoneID }) {
                poison(syncEngine)
                await deliver(.remoteDataLoss(Self.remoteDataLoss(for: deletion.reason)))
            }

        case .didFetchRecordZoneChanges(let finished):
            guard finished.zoneID == zoneID else {
                await deliver(.operationFailed(.rejected(.permanent(
                    detail: "CloudKit completed a fetch outside the snippet zone"))))
                return
            }
            if let error = finished.error {
                Diagnostics.record(.cloudKitFailure(
                    operation: .fetchChanges,
                    failure: DiagnosticFailure(error)))
                if CloudKitErrorMapping.containsZoneInvalidation(error, for: zoneID) {
                    poison(syncEngine)
                    await deliver(.remoteDataLoss(.zoneDeleted))
                } else {
                    let scopedError = CloudKitErrorMapping.zoneError(
                        in: error,
                        for: zoneID) ?? error
                    await deliver(.operationFailed(
                        CloudKitErrorMapping.failure(for: scopedError)))
                }
            }

        case .didFetchChanges:
            await deliver(.didFetch)

        case .willSendChanges:
            lock.withLock { issuedRecords.removeAll(keepingCapacity: true) }

        case .sentRecordZoneChanges(let sent):
            if !sent.deletedRecordIDs.isEmpty || !sent.failedRecordDeletes.isEmpty {
                poison(syncEngine)
                await deliver(.remoteDataLoss(.physicalRecordDeletion))
                return
            }
            if sent.failedRecordSaves.contains(where: {
                Self.failedSaveInvalidatesZone(
                    failedRecord: $0.record,
                    error: $0.error,
                    zoneID: zoneID)
            }) {
                poison(syncEngine)
                await deliver(.remoteDataLoss(.zoneDeleted))
                return
            }
            let issued = lock.withLock({ issuedRecords })
            var results: [CloudKitSentResult] = []
            for saved in sent.savedRecords {
                guard let result = Self.savedSentResult(
                    savedRecord: saved,
                    issued: issued,
                    zoneID: zoneID) else { continue }
                results.append(result)
            }
            for failed in sent.failedRecordSaves {
                guard let result = Self.failedSentResult(
                    failedRecord: failed.record,
                    error: failed.error,
                    issued: issued,
                    zoneID: zoneID) else { continue }
                results.append(result)
            }
            if !results.isEmpty { await deliver(.sentRecords(results)) }

        case .sentDatabaseChanges(let sent):
            if let failed = sent.failedZoneSaves.first(where: { $0.zone.zoneID == zoneID }) {
                if CloudKitErrorMapping.containsZoneInvalidation(
                    failed.error,
                    for: zoneID
                ) {
                    poison(syncEngine)
                    await deliver(.remoteDataLoss(.zoneDeleted))
                    return
                } else {
                    let scopedError = CloudKitErrorMapping.zoneError(
                        in: failed.error,
                        for: zoneID) ?? failed.error
                    await deliver(.operationFailed(
                        CloudKitErrorMapping.failure(for: scopedError)))
                }
            }
            if sent.deletedZoneIDs.contains(zoneID) || sent.failedZoneDeletes[zoneID] != nil {
                poison(syncEngine)
                await deliver(.remoteDataLoss(.zoneDeleted))
            }

        case .didSendChanges:
            await deliver(.didSend)

        case .willFetchRecordZoneChanges:
            break

        @unknown default:
            await deliver(.operationFailed(.rejected(.permanent(
                detail: "this build does not understand a CloudKit scheduler event"))))
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard lock.withLock({ engine === syncEngine }),
              let provider = lock.withLock({ activeBatchProvider }) else { return nil }

        // Ask for the complete immutable journal lease, then apply both CKSyncEngine's
        // requested scope and our own already-issued set. This avoids an engine paging
        // call receiving the same first 200 records forever.
        guard let proposed = await provider(.all, Int.max) else { return nil }
        let alreadyIssued = lock.withLock { Set(issuedRecords.keys) }
        let eligible = proposed.recordsToSave.filter { wire in
            guard !alreadyIssued.contains(wire.id) else { return false }
            let recordID = CloudKitRecordMapping.recordID(for: wire.id, in: zoneID)
            return context.options.scope.contains(recordID)
        }
        guard !eligible.isEmpty else { return nil }
        let chunk = CloudKitTransport.chunk(eligible).first ?? []

        var mapped: [CKRecord] = []
        var localRejections: [CloudKitSentResult] = []
        for wire in chunk {
            do {
                mapped.append(try CloudKitRecordMapping.makeRecord(from: wire, in: zoneID))
            } catch {
                localRejections.append(.rejected(
                    id: wire.id,
                    rejection: .permanent(detail: "the snippet exceeds CloudKit limits")))
            }
        }
        lock.withLock {
            for wire in chunk { issuedRecords[wire.id] = wire }
        }
        if !localRejections.isEmpty {
            await deliver(.sentRecords(localRejections))
        }
        guard !mapped.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(
            recordsToSave: mapped,
            recordIDsToDelete: [],
            atomicByZone: false)
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zoneID])
        return options
    }

    private func poison(_ syncEngine: CKSyncEngine) {
        lock.withLock {
            guard engine === syncEngine else { return }
            retiredEngines.append(syncEngine)
            engine = nil
            activeBatchProvider = nil
            issuedRecords.removeAll()
        }
    }

    static func accountChange(
        for change: CKSyncEngine.Event.AccountChange.ChangeType
    ) -> CloudKitSyncAccountChange {
        switch change {
        case .signIn:
            return .signIn
        case .signOut:
            return .signOut
        case .switchAccounts:
            return .switchAccounts
        @unknown default:
            return .switchAccounts
        }
    }

    static func remoteDataLoss(
        for reason: CKDatabase.DatabaseChange.Deletion.Reason
    ) -> CloudKitRemoteDataLoss {
        switch reason {
        case .deleted:
            return .zoneDeleted
        case .purged:
            return .zonePurged
        case .encryptedDataReset:
            return .encryptedDataReset
        @unknown default:
            return .zoneDeleted
        }
    }

    private func installEngine(
        from stateSerialization: Data?,
        replacingExisting: Bool = false
    ) throws {
        let restored: CKSyncEngine.State.Serialization?
        if let stateSerialization {
            do {
                restored = try PropertyListDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: stateSerialization)
            } catch {
                throw SyncTransportFailure.checkpointUnreadable(
                    detail: "the saved CloudKit scheduler state is incompatible")
            }
        } else {
            restored = nil
        }

        let installed = lock.withLock { () -> CKSyncEngine? in
            if !replacingExisting, engine != nil { return nil }
            if replacingExisting, let engine {
                retiredEngines.append(engine)
            }
            var configuration = CKSyncEngine.Configuration(
                database: database,
                stateSerialization: restored,
                delegate: self)
            configuration.automaticallySync = true
            configuration.subscriptionID = "com.khm.snippets.cksync.v1"
            let created = CKSyncEngine(configuration)
            engine = created
            activeBatchProvider = configuredBatchProvider
            issuedRecords.removeAll(keepingCapacity: false)
            return created
        }
        installed?.state.hasPendingUntrackedChanges = lock.withLock {
            pendingUntrackedBeforeStart
        }
    }

    static func failedSentResult(
        failedRecord: CKRecord,
        error: any Error,
        issued: [UUID: WireRecord],
        zoneID: CKRecordZone.ID
    ) -> CloudKitSentResult? {
        guard let offered = issuedRecord(
            matching: failedRecord.recordID,
            issued: issued,
            zoneID: zoneID) else { return nil }
        guard let recordError = CloudKitErrorMapping.recordError(
            in: error,
            for: failedRecord.recordID) else {
            return .rejected(
                id: offered.id,
                rejection: .rateLimited(retryAfter: 5))
        }
        let outcome = CloudKitTransport.submissionOutcome(
            for: offered,
            result: .failure(recordError),
            expectedZoneID: zoneID)
        switch outcome {
        case .accepted(let rev, let version):
            return .accepted(id: offered.id, rev: rev, recordVersion: version)
        case .rejected(let rejection):
            return .rejected(id: offered.id, rejection: rejection)
        }
    }

    static func failedSaveInvalidatesZone(
        failedRecord: CKRecord,
        error: any Error,
        zoneID: CKRecordZone.ID
    ) -> Bool {
        guard failedRecord.recordID.zoneID == zoneID,
              let recordError = CloudKitErrorMapping.recordError(
                in: error,
                for: failedRecord.recordID) else { return false }
        return CloudKitErrorMapping.isZoneInvalidated(recordError)
    }

    static func savedSentResult(
        savedRecord: CKRecord,
        issued: [UUID: WireRecord],
        zoneID: CKRecordZone.ID
    ) -> CloudKitSentResult? {
        guard let offered = issuedRecord(
            matching: savedRecord.recordID,
            issued: issued,
            zoneID: zoneID) else { return nil }
        let outcome = CloudKitTransport.submissionOutcome(
            for: offered,
            result: .success(savedRecord),
            expectedZoneID: zoneID)
        switch outcome {
        case .accepted(let rev, let version):
            return .accepted(id: offered.id, rev: rev, recordVersion: version)
        case .rejected(let rejection):
            return .rejected(id: offered.id, rejection: rejection)
        }
    }

    private static func issuedRecord(
        matching recordID: CKRecord.ID,
        issued: [UUID: WireRecord],
        zoneID: CKRecordZone.ID
    ) -> WireRecord? {
        let recordName = recordID.recordName
        guard recordID.zoneID == zoneID,
              let id = UUID(uuidString: recordName),
              id.uuidString.lowercased() == recordName else { return nil }
        return issued[id]
    }

    private func deliver(_ event: CloudKitSyncDriverEvent) async {
        let handler = lock.withLock { () -> (
            @Sendable (CloudKitSyncDriverEvent) async -> Void
        )? in
            guard let eventHandler else { return nil }
            eventHandlerDepth += 1
            return eventHandler
        }
        if let handler {
            await handler(event)
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                eventHandlerDepth -= 1
                guard eventHandlerDepth == 0 else { return [] }
                defer { eventHandlerReturnWaiters.removeAll(keepingCapacity: false) }
                return eventHandlerReturnWaiters
            }
            for waiter in waiters { waiter.resume() }
        } else {
            eventContinuation.yield(event)
        }
    }
}

/// FIFO single-flight barrier for CKSyncEngine cancellation maintenance. Calls that
/// arrive after a drain has begun await that complete drain before taking their own
/// snapshot, so an empty retired-engine array never means an earlier cancellation is
/// already finished.
actor CloudKitSingleFlightCancellationBarrier {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    func perform(_ operation: @escaping @Sendable () async -> Void) async {
        generation &+= 1
        let ownGeneration = generation
        let prior = tail
        // CKSyncEngine marks its delegate callback task with private task-local state and
        // traps if a callback-capable API inherits that context. The barrier may itself be
        // entered by callback maintenance, so this boundary must be detached rather than
        // merely delayed until `handleEvent` returns.
        let task = Task.detached {
            if let prior { await prior.value }
            await operation()
        }
        tail = task
        await task.value
        if generation == ownGeneration { tail = nil }
    }
}

private actor CloudKitZonePreparation {
    private var completed = false
    private var inFlight: Task<Void, Error>?

    func run(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        if completed { return }
        let task: Task<Void, Error>
        if let inFlight {
            task = inFlight
        } else {
            let created = Task { try await operation() }
            inFlight = created
            task = created
        }
        do {
            try await task.value
            completed = true
            inFlight = nil
        } catch {
            inFlight = nil
            throw error
        }
    }
}
