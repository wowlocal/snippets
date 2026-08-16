import CloudKit
import Foundation
import Synchronization

// App target only. This adapter lets CKSyncEngine own CloudKit scheduling while the
// durable SyncJournal remains the sole source of outbound user intent.

nonisolated enum CloudKitSyncSendScope: Equatable, Sendable {
    case all
    case recordIDs(Set<UUID>)

    func contains(_ id: UUID) -> Bool {
        switch self {
        case .all: true
        case .recordIDs(let ids): ids.contains(id)
        }
    }
}

nonisolated struct CloudKitRecordZoneChangeBatch: Equatable, Sendable {
    var recordsToSave: [WireRecord]
    var recordIDsToDelete: [UUID]
}

nonisolated enum CloudKitSentResult: Equatable, Sendable {
    case accepted(id: UUID, rev: String, recordVersion: SyncRecordVersion)
    case rejected(id: UUID, rejection: SyncRejection)

    var id: UUID {
        switch self {
        case .accepted(let id, _, _), .rejected(let id, _): id
        }
    }
}

nonisolated enum CloudKitSyncAccountChange: Equatable, Sendable {
    case signIn
    case signOut
    case switchAccounts
}

nonisolated enum CloudKitRemoteDataLoss: Equatable, Sendable {
    case physicalRecordDeletion
    case zoneDeleted
    case zonePurged
    case encryptedDataReset

    var failureDetail: String {
        switch self {
        case .physicalRecordDeletion:
            return "CloudKit physically deleted a snippet record"
        case .zoneDeleted:
            return "the CloudKit record zone was deleted"
        case .zonePurged:
            return "CloudKit purged the record zone"
        case .encryptedDataReset:
            return "CloudKit reset encrypted data in the record zone"
        }
    }
}

nonisolated enum CloudKitSyncDriverEvent: Sendable {
    case stateUpdate(Data)
    case accountChange(CloudKitSyncAccountChange)
    case willFetch
    case fetchedRecords([WireRecord], physicalDeletionCount: Int)
    case didFetch
    case sentRecords([CloudKitSentResult])
    case didSend
    case operationFailed(SyncTransportFailure)
    case remoteDataLoss(CloudKitRemoteDataLoss)
}

nonisolated protocol CloudKitSyncDriving: AnyObject, Sendable {
    var automaticallySync: Bool { get }
    var events: AsyncStream<CloudKitSyncDriverEvent> { get }
    var hasPendingUntrackedChanges: Bool { get set }

    func prepareForFirstFetch() async throws
    /// Starts the scheduler only after fresh-zone creation has been recorded in the
    /// encrypted checkpoint. Established/repaired scopes may already be running.
    func completeFirstFetchPreparation() throws
    func restart(from stateSerialization: Data?) throws
    func invalidate()
    /// Returns only after an awaited delegate event handler has fully returned to the
    /// driver. Fakes use it to model the same reentrancy fence deterministically.
    func waitForEventHandlerReturn() async
    func sendChanges() async throws
    func fetchChanges() async throws
    /// Deterministic concurrency seam after the adapter freezes a fetch reply snapshot.
    /// Production drivers use the no-op default; strict fakes can deliver an automatic
    /// callback here to prove that a later generation cannot leak into the frozen reply.
    func fetchReplySnapshotValidated() async
    func cancelOperations() async
    func installBatchProvider(
        _ provider: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncSendScope, Int
        ) async -> CloudKitRecordZoneChangeBatch?
    )
    func installEventHandler(
        _ handler: nonisolated(nonsending) @escaping @Sendable (
            CloudKitSyncDriverEvent
        ) async -> Void
    )
    func start() throws
}

nonisolated extension CloudKitSyncDriving {
    /// Stream-only test drivers have no awaited callback to unwind. Production and the
    /// strict orchestration fake override this with an explicit callback-return fence.
    func waitForEventHandlerReturn() async {}
    func completeFirstFetchPreparation() throws {}
    func fetchReplySnapshotValidated() async {}
}

/// Bridges the project transport contract to CKSyncEngine without creating a second
/// outbox. A submit is an immutable in-memory lease over the exact `WireRecord`s already
/// frozen in SyncJournal; `hasPendingUntrackedChanges` is only CKSyncEngine's wake hint.
nonisolated final class CloudKitSyncTransportAdapter: SyncTransport, @unchecked Sendable {
    static let antiEntropyInterval: TimeInterval = 24 * 60 * 60

    let identifier = "icloud"
    let supportsPush = true
    let pollInterval: TimeInterval = 6 * 60 * 60
    let events: AsyncStream<SyncTransportEvent>

    private let accountIdentity: SyncAccountIdentity
    private let checkpointStore: CloudKitSyncCheckpointStore
    private let driver: any CloudKitSyncDriving
    private let retrySleeper: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let fullResyncInterval: TimeInterval
    private let state: State
    private let eventReceiver: CloudKitSyncAdapterEventReceiver
    private let eventContinuation: AsyncStream<SyncTransportEvent>.Continuation
    private let wakeLock = NSLock()
    private var wakeGeneration: UInt64 = 0
    private var eventTask: Task<Void, Never>?
    private let retryLock = NSLock()
    private var retryTask: Task<Void, Never>?
    private var retryGeneration: UInt64 = 0
    private let preparation = CloudKitSyncDriverPreparation()
    private let maintenance = CloudKitAdapterMaintenanceQueue()
    private let terminalInvalidationLock = NSLock()
    private var terminalDriverInvalidated = false
    private let lifecycle = CloudKitAdapterLifecycleGate()

    init(
        accountIdentity: SyncAccountIdentity,
        checkpointStore: CloudKitSyncCheckpointStore,
        driver: any CloudKitSyncDriving,
        now: @escaping @Sendable () -> Date = Date.init,
        fullResyncInterval: TimeInterval = CloudKitSyncTransportAdapter.antiEntropyInterval,
        retrySleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            let bounded = min(max(delay.isFinite ? delay : 5, 0.1), 6 * 60 * 60)
            try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
        }
    ) throws {
        self.accountIdentity = accountIdentity
        self.checkpointStore = checkpointStore
        self.driver = driver
        self.now = now
        self.fullResyncInterval = fullResyncInterval
        self.retrySleeper = retrySleeper
        let eventReceiver = CloudKitSyncAdapterEventReceiver()
        self.eventReceiver = eventReceiver

        switch checkpointStore.load(for: accountIdentity) {
        case .missing:
            // Direct adapter construction is a test seam and the transport's genuinely
            // fresh path. Reviewed/local resets always create their own checkpoint
            // before reaching this initializer and can therefore disable bootstrap.
            try checkpointStore.reset(
                for: accountIdentity,
                allowsZoneBootstrap: true)
        case .loaded:
            break
        case .scopeMismatch:
            throw SyncTransportFailure.accountChanged
        case .unreadable:
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the encrypted CloudKit scheduler checkpoint is unreadable")
        }
        guard case .loaded(let initialCheckpoint) = checkpointStore.load(
            for: accountIdentity) else {
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the encrypted CloudKit scheduler checkpoint disappeared")
        }
        state = State(
            accountIdentity: accountIdentity,
            checkpointStore: checkpointStore,
            durableSerialization: initialCheckpoint.serialization,
            schedulerFetchIsFullResync: initialCheckpoint.fullResyncInProgress)

        var continuation: AsyncStream<SyncTransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventContinuation = continuation
        eventTask = nil

        driver.installBatchProvider { [weak self] scope, limit in
            guard let self else { return nil }
            return self.nextRecordZoneChangeBatch(scope: scope, limit: limit)
        }
        // Production callbacks are awaited by CKSyncEngine's serial delegate. Handling
        // them inline makes `sendChanges()`/`fetchChanges()` return only after the
        // corresponding durable checkpoint transition. The stream remains as a fallback
        // seam for simple test drivers and non-CKSyncEngine implementations.
        driver.installEventHandler { [weak eventReceiver] event in
            await eventReceiver?.consume(event)
        }
        let stream = driver.events
        eventTask = Task { [weak eventReceiver] in
            for await event in stream {
                guard let eventReceiver else { return }
                await eventReceiver.consume(event)
            }
        }
        // Capturing `self` weakly in a closure formed before an initializer returns can
        // permanently produce nil. Install it into a separately initialized weak box
        // only after every stored property is valid, and before CKSyncEngine can emit.
        eventReceiver.install(self)
        Diagnostics.record(.cloudKitSchedulerTransition(
            action: .initialized,
            reason: initialCheckpoint.fullResyncInProgress ? .initial : nil,
            fullResync: initialCheckpoint.fullResyncInProgress,
            pendingGenerationCount: initialCheckpoint.generations.count,
            unreadyGenerationCount: initialCheckpoint.unreadyGenerationCount))
        try driver.start()
    }

    deinit {
        eventTask?.cancel()
        retryTask?.cancel()
        eventContinuation.finish()
    }

    /// Permanently detaches this adapter and waits until its CKSyncEngine can no longer
    /// deliver a callback or own an operation for the private database. The coordinator
    /// uses this as the replacement-engine barrier; `invalidate()` alone is deliberately
    /// fire-and-forget for callback-safe internal error paths.
    func shutdown() async {
        lifecycle.stop()
        maintenance.stopAccepting()
        preparation.stopAccepting()
        cancelRetry()
        eventTask?.cancel()
        eventTask = nil
        eventContinuation.finish()
        driver.invalidate()
        await driver.waitForEventHandlerReturn()
        // Fresh-zone preparation and callback maintenance can both outlive the call
        // that started them. Drain their synchronously registered tasks before the
        // final cancellation barrier, so no checkpoint write, restart, or late cancel
        // can begin after shutdown returns.
        await preparation.waitUntilIdle()
        await maintenance.waitUntilIdle()
        await driver.cancelOperations()
    }

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        try state.consumeOperationFailure()
        return accountIdentity
    }

    func acknowledgeFetched(through cursor: SyncCursor?) throws {
        guard let cursor else { return }
        guard let acknowledged = CloudKitSyncCursor.decode(cursor) else {
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the durable CloudKit inbox cursor is incompatible")
        }
        try checkpointStore.acknowledge(
            through: acknowledged.throughSequence,
            epoch: acknowledged.epoch,
            for: accountIdentity)
    }

    /// Detaches a transport instance that its owner has removed from the account scope.
    /// This is deliberately synchronous: no CKSyncEngine API is entered until the
    /// asynchronously scheduled cancellation runs after the caller's current callback.
    func invalidate() {
        invalidateTerminalDriverAfterCallback()
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        try state.requireUsable()

        var checkpoint = try checkpoint()
        var cursorRequiresFullResync = cursor == nil
        if let cursor {
            if let acknowledged = CloudKitSyncCursor.decode(cursor),
               acknowledged.epoch == checkpoint.epoch {
                try checkpointStore.acknowledge(
                    through: acknowledged.throughSequence,
                    epoch: acknowledged.epoch,
                    for: accountIdentity)
                checkpoint = try self.checkpoint()
            } else {
                guard checkpoint.serialization == nil
                        || checkpoint.fullResyncInProgress
                        || !checkpoint.generations.isEmpty else {
                    throw SyncTransportFailure.checkpointUnreadable(
                        detail: "the Core cursor is incompatible with restored CloudKit state")
                }
                cursorRequiresFullResync = true
            }
        }

        if !checkpoint.generations.isEmpty,
           checkpoint.generations.allSatisfy(\.isReadyForCore) {
            return makeFetch(
                checkpoint,
                isFullResync: cursorRequiresFullResync
                    || checkpoint.generations.contains(where: \.isFullResync))
        }

        // This reset repairs a suspicious standalone state update and provides a
        // bounded daily anti-entropy pass independent of pushes and change tokens. Core
        // separately fences a missing/lost base through its journal-first reset path.
        let fullResyncReason: DiagnosticCloudSchedulerReason? = if checkpoint.requiresFullResync {
            .checkpointRepair
        } else if checkpoint.needsFullResync(at: now(), interval: fullResyncInterval) {
            .antiEntropy
        } else {
            nil
        }
        if let fullResyncReason {
            checkpoint = try await resetSchedulerForFullResync(reason: fullResyncReason)
            if !checkpoint.generations.isEmpty,
               checkpoint.generations.allSatisfy(\.isReadyForCore) {
                return makeFetch(
                    checkpoint,
                    isFullResync: checkpoint.generations.contains(where: \.isFullResync))
            }
        }

        let isFullResync = checkpoint.fullResyncInProgress

        var replyCheckpoint: CloudKitSyncCheckpoint?
        state.beginManualFetch()
        do {
            try await prepareDriver()
            try await driver.fetchChanges()
            try await performPendingDriverRestartIfNeeded()
            try state.finishManualFetch()
            try state.consumeOperationFailure()
            let settled = try self.checkpoint()
            guard !state.hasIncompleteFetch,
                  settled.generations.allSatisfy(\.isReadyForCore) else {
                throw SyncTransportFailure.unreachable(
                    detail: "CloudKit fetch pages are durable but the fetch boundary is incomplete")
            }
            replyCheckpoint = settled
        } catch {
            // CKSyncEngine can both deliver a retryable delegate failure and make the
            // enclosing fetchChanges() throw. Complete the rollback after the callback
            // has unwound even on that throwing path.
            do {
                try await performPendingDriverRestartIfNeeded()
            } catch {
                _ = state.abortManualFetch()
                throw error
            }
            if let rollback = state.abortManualFetch() {
                driver.invalidate()
                await driver.cancelOperations()
                do {
                    _ = try restartDriverIfActive(
                        from: rollback.serialization,
                        isFullResync: rollback.isFullResync)
                } catch {
                    let failure = error as? SyncTransportFailure
                        ?? .checkpointUnreadable(
                            detail: "the durable CloudKit scheduler state is incompatible")
                    _ = state.recordCallbackFailure(failure)
                    invalidateTerminalDriverAfterCallback()
                    throw failure
                }
            }
            if state.hasTerminalFailure {
                invalidateTerminalDriverAfterCallback()
                try state.requireUsable()
            }
            throw error
        }
        try state.requireUsable()
        guard let replyCheckpoint else {
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the verified CloudKit fetch reply snapshot disappeared")
        }
        await driver.fetchReplySnapshotValidated()
        try state.requireUsable()
        // Return exactly the snapshot whose ready prefix was checked above. An
        // automatic callback may atomically append another sealed generation after
        // that check, but it belongs to the next reply and cannot advance this cursor.
        return makeFetch(replyCheckpoint, isFullResync: isFullResync)
    }

    /// Retires the old scheduler epoch before clearing its watermark. A callback that
    /// completed while cancellation was draining wins atomically: its durable inbox is
    /// returned first and the repair remains sticky for the following round.
    private func resetSchedulerForFullResync(
        reason: DiagnosticCloudSchedulerReason
    ) async throws -> CloudKitSyncCheckpoint {
        driver.invalidate()
        await driver.waitForEventHandlerReturn()
        await driver.cancelOperations()
        await driver.waitForEventHandlerReturn()
        try state.retireSchedulerForFullResync()

        var settled = try checkpoint()
        if !settled.generations.isEmpty {
            try restartDriverIfActive(
                from: settled.serialization,
                isFullResync: settled.fullResyncInProgress)
            Diagnostics.record(.cloudKitSchedulerTransition(
                action: .durableInboxPreserved,
                reason: reason,
                fullResync: settled.fullResyncInProgress,
                pendingGenerationCount: settled.generations.count,
                unreadyGenerationCount: settled.unreadyGenerationCount))
            return settled
        }

        try checkpointStore.reset(
            for: accountIdentity,
            allowsZoneBootstrap: false)
        do {
            try restartDriverIfActive(from: nil, isFullResync: true)
        } catch {
            let failure = error as? SyncTransportFailure
                ?? .checkpointUnreadable(
                    detail: "the CloudKit scheduler could not start a full reconciliation")
            _ = state.recordCallbackFailure(failure)
            throw failure
        }
        settled = try checkpoint()
        Diagnostics.record(.cloudKitSchedulerTransition(
            action: .fullResyncStarted,
            reason: reason,
            fullResync: true,
            pendingGenerationCount: settled.generations.count,
            unreadyGenerationCount: settled.unreadyGenerationCount))
        return settled
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        try state.requireUsable()
        guard !records.isEmpty else {
            return SyncSubmission(
                results: [], cursor: cursor, accountIdentity: accountIdentity)
        }

        try state.beginSubmit(records)
        let wakeAtStart = wakeLock.withLock { wakeGeneration }
        driver.hasPendingUntrackedChanges = true
        do {
            try await prepareDriver()
            try await driver.sendChanges()
            try state.consumeOperationFailure()
            try state.requireUsable()
            let results = try state.finishSubmit()
            settleWake(after: wakeAtStart)
            scheduleRetryIfNeeded(for: results)
            return SyncSubmission(
                results: results,
                cursor: cursor,
                accountIdentity: accountIdentity)
        } catch {
            state.abortSubmit()
            settleWake(after: wakeAtStart)
            if state.hasTerminalFailure {
                invalidateTerminalDriverAfterCallback()
                try state.requireUsable()
            }
            throw error
        }
    }

    /// Coalesced wake only. The journal, never CKSyncEngine.State, owns the records.
    func localChangesAvailable() {
        wakeLock.withLock { wakeGeneration &+= 1 }
        driver.hasPendingUntrackedChanges = true
    }

    /// User-facing Sync Now asks CKSyncEngine to push before fetching, matching the
    /// domain engine's no-lost-local-edit ordering.
    func syncNow() async throws {
        try state.requireUsable()
        try await prepareDriver()
        do {
            try await driver.sendChanges()
            try state.consumeOperationFailure()
        } catch {
            if state.hasTerminalFailure { try state.requireUsable() }
            throw error
        }

        state.beginManualFetch()
        do {
            try await driver.fetchChanges()
            try await performPendingDriverRestartIfNeeded()
            try state.finishManualFetch()
            try state.consumeOperationFailure()
        } catch {
            do {
                try await performPendingDriverRestartIfNeeded()
            } catch {
                _ = state.abortManualFetch()
                throw error
            }
            if let rollback = state.abortManualFetch() {
                driver.invalidate()
                await driver.cancelOperations()
                _ = try restartDriverIfActive(
                    from: rollback.serialization,
                    isFullResync: rollback.isFullResync)
            }
            if state.hasTerminalFailure { try state.requireUsable() }
            throw error
        }
    }

    func nextRecordZoneChangeBatch(
        scope: CloudKitSyncSendScope,
        limit: Int
    ) -> CloudKitRecordZoneChangeBatch? {
        state.nextBatch(scope: scope, limit: limit)
    }

    func handle(_ event: CloudKitSyncDriverEvent) async throws {
        let outcome = try state.handle(event)
        if let diagnosticEvent = outcome.diagnosticEvent {
            Diagnostics.record(diagnosticEvent)
        }
        if outcome.cancelAfterCallback {
            invalidateTerminalDriverAfterCallback()
        } else if outcome.invalidateDriver {
            cancelRetry()
            driver.invalidate()
        }
        if outcome.restartAfterCallback {
            scheduleRestartAfterCallback()
        }
        if outcome.notifyCore {
            eventContinuation.yield(.changesAvailable)
        }
    }

    private func checkpoint() throws -> CloudKitSyncCheckpoint {
        switch checkpointStore.load(for: accountIdentity) {
        case .loaded(let checkpoint):
            return checkpoint
        case .missing:
            throw SyncTransportFailure.rejected(.permanent(
                detail: "the CloudKit scheduler checkpoint disappeared"))
        case .scopeMismatch:
            throw SyncTransportFailure.accountChanged
        case .unreadable:
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the encrypted CloudKit scheduler checkpoint is unreadable")
        }
    }

    fileprivate func consumeDriverEvent(_ event: CloudKitSyncDriverEvent) async {
        guard lifecycle.acceptsEvents else { return }
        do {
            try await handle(event)
        } catch {
            let failure = error as? SyncTransportFailure
                ?? .rejected(.permanent(
                    detail: "the CloudKit scheduler checkpoint could not be persisted"))
            let outcome = state.recordCallbackFailure(failure)
            if outcome.cancelAfterCallback {
                invalidateTerminalDriverAfterCallback()
            } else if outcome.invalidateDriver {
                cancelRetry()
                driver.invalidate()
            }
            if outcome.restartAfterCallback {
                scheduleRestartAfterCallback()
            }
            eventContinuation.yield(.changesAvailable)
        }
    }

    private func prepareDriver() async throws {
        try await preparation.run { [driver, checkpointStore, accountIdentity, lifecycle] in
            try await driver.prepareForFirstFetch()
            // The zone save must become durable before constructing an automatically
            // scheduling CKSyncEngine. If this write fails, no fetch can race ahead and
            // a retry may safely repeat the idempotent zone save.
            let completed = try lifecycle.restartIfActive {
                try checkpointStore.markZoneEstablished(for: accountIdentity)
                try driver.completeFirstFetchPreparation()
            }
            guard completed else { throw CancellationError() }
        }
    }

    /// A delegate callback may only detach local driver state. CKSyncEngine calls are
    /// deferred until the production driver explicitly observes that callback unwind,
    /// avoiding reentrancy into Apple's serial delegate machinery.
    private func scheduleCancellationAfterCallback() {
        maintenance.schedule { [driver] in
            await driver.waitForEventHandlerReturn()
            await driver.cancelOperations()
        }
    }

    private func scheduleRestartAfterCallback() {
        maintenance.schedule { [weak self] in
            guard let self else { return }
            await self.driver.waitForEventHandlerReturn()
            do {
                try await self.performPendingDriverRestartIfNeeded()
            } catch {
                self.recordDriverMaintenanceFailure(error)
            }
        }
    }

    private func performPendingDriverRestartIfNeeded() async throws {
        guard let request = state.takePendingRestart() else { return }
        await driver.cancelOperations()
        do {
            // `shutdown()` may have queued its own cancellation while this recovery
            // task awaited the earlier drain. The active check and synchronous restart
            // are one lifecycle critical section: either restart wins first and
            // shutdown subsequently retires it, or shutdown wins and no engine can be
            // created after retirement.
            let restarted = try restartDriverIfActive(
                from: request.serialization,
                isFullResync: request.isFullResync)
            if restarted {
                let restartedCheckpoint = try? checkpoint()
                Diagnostics.record(.cloudKitSchedulerTransition(
                    action: .retryRestarted,
                    reason: .retryableFailure,
                    fullResync: request.isFullResync,
                    pendingGenerationCount: restartedCheckpoint?.generations.count ?? 0,
                    unreadyGenerationCount: restartedCheckpoint?.unreadyGenerationCount ?? 0))
            }
        } catch {
            let failure = error as? SyncTransportFailure
                ?? .checkpointUnreadable(
                    detail: "the durable CloudKit scheduler state is incompatible")
            _ = state.recordCallbackFailure(failure)
            throw failure
        }
    }

    @discardableResult
    private func restartDriverIfActive(
        from serialization: Data?,
        isFullResync: Bool
    ) throws -> Bool {
        try lifecycle.restartIfActive {
            // Publish scheduler mode before CKSyncEngine(configuration:) can start an
            // automatic callback. A callback can therefore never inherit the old mode.
            state.prepareSchedulerRestart(
                serialization: serialization,
                isFullResync: isFullResync)
            try driver.restart(from: serialization)
        }
    }

    private func recordDriverMaintenanceFailure(_ error: any Error) {
        let failure = error as? SyncTransportFailure
            ?? .checkpointUnreadable(
                detail: "the durable CloudKit scheduler state is incompatible")
        let outcome = state.recordCallbackFailure(failure)
        if outcome.cancelAfterCallback {
            invalidateTerminalDriverAfterCallback()
        } else if outcome.invalidateDriver {
            driver.invalidate()
        }
        eventContinuation.yield(.changesAvailable)
    }

    private func invalidateTerminalDriverAfterCallback() {
        let shouldInvalidate = terminalInvalidationLock.withLock { () -> Bool in
            guard !terminalDriverInvalidated else { return false }
            terminalDriverInvalidated = true
            return true
        }
        guard shouldInvalidate else { return }
        cancelRetry()
        driver.invalidate()
        scheduleCancellationAfterCallback()
    }

    private func makeFetch(
        _ checkpoint: CloudKitSyncCheckpoint,
        isFullResync: Bool
    ) -> SyncFetch {
        let visibleGenerations = Array(
            checkpoint.generations.prefix(while: \.isReadyForCore))
        let records = visibleGenerations.flatMap(\.records)
        let throughSequence = checkpoint.readyThroughSequence
        // Once Core durably returns an inbox cursor, retain that watermark even after
        // its generation is compacted. Returning nil on a no-change fetch would make
        // Core erase the ACK, classify every later round as a full resync, and repeatedly
        // replay the whole remote library.
        let cursor = throughSequence.map {
            CloudKitSyncCursor(
                epoch: checkpoint.epoch,
                throughSequence: $0).syncCursor
        }
        return SyncFetch(
            records: records,
            cursor: cursor,
            cursorKind: cursor == nil ? nil : .cloudKitSyncEngine,
            hasMore: false,
            isFullResync: isFullResync
                || visibleGenerations.contains(where: \.isFullResync),
            accountIdentity: accountIdentity)
    }

    private func settleWake(after generation: UInt64) {
        let stillPending = wakeLock.withLock { wakeGeneration != generation }
        driver.hasPendingUntrackedChanges = stillPending
    }

    private func scheduleRetryIfNeeded(for results: [SyncSubmitResult]) {
        let delays = results.compactMap { result -> TimeInterval? in
            guard case .rejected(let rejection) = result.outcome else { return nil }
            switch rejection {
            case .rateLimited(let retryAfter): return max(0.1, retryAfter)
            case .conflict: return 1
            case .authenticationRequired, .permanent: return nil
            }
        }
        guard let delay = delays.min() else {
            cancelRetry()
            return
        }
        scheduleRetry(after: delay)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        let bounded = min(max(delay.isFinite ? delay : 5, 0.1), pollInterval)
        let generation = retryLock.withLock { () -> UInt64 in
            retryGeneration &+= 1
            retryTask?.cancel()
            retryTask = nil
            return retryGeneration
        }
        let task = Task { [weak self, retrySleeper] in
            do {
                try await retrySleeper(bounded)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            self.retryLock.withLock {
                guard self.retryGeneration == generation, !Task.isCancelled else { return }
                self.eventContinuation.yield(.changesAvailable)
            }
        }
        retryLock.withLock {
            guard retryGeneration == generation else {
                task.cancel()
                return
            }
            retryTask = task
        }
    }

    private func cancelRetry() {
        retryLock.withLock {
            retryGeneration &+= 1
            retryTask?.cancel()
            retryTask = nil
        }
    }
}

/// Atomic lifecycle fence around the only driver operation that can construct a new
/// CKSyncEngine. Once stop wins the lock, every delayed recovery task becomes a no-op;
/// if restart wins, stop follows it and retires the engine before shutdown returns.
nonisolated final class CloudKitAdapterLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private let active = Atomic(true)

    // Driver construction may synchronously trigger an automatic CKSyncEngine
    // callback. That callback must be able to observe the published lifecycle state
    // without waiting on the restart critical section that is constructing its engine.
    var acceptsEvents: Bool { active.load(ordering: .acquiring) }

    func stop() {
        lock.withLock { active.store(false, ordering: .releasing) }
    }

    @discardableResult
    func restartIfActive(_ restart: () throws -> Void) rethrows -> Bool {
        try lock.withLock {
            guard active.load(ordering: .relaxed) else { return false }
            try restart()
            return true
        }
    }
}

/// Single-flight fresh-zone preparation with a synchronous close/register boundary.
/// Actor isolation alone is insufficient here: an old caller can be scheduled only
/// after shutdown has inspected actor state. Closing under this lock guarantees that
/// such a caller is rejected before its operation can touch CloudKit, while shutdown
/// can drain every preparation that registered first.
nonisolated final class CloudKitSyncDriverPreparation: @unchecked Sendable {
    private enum Registration {
        case completed
        case stopped
        case task(generation: UInt64, Task<Void, Error>)
    }

    private let lock = NSLock()
    private var completed = false
    private var accepting = true
    private var inFlight: Task<Void, Error>?
    private var generation: UInt64 = 0

    func run(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let registration = lock.withLock { () -> Registration in
            guard accepting else { return .stopped }
            if completed { return .completed }
            if let inFlight { return .task(generation: generation, inFlight) }
            generation &+= 1
            let created = Task { try await operation() }
            inFlight = created
            return .task(generation: generation, created)
        }

        switch registration {
        case .completed:
            return
        case .stopped:
            throw CancellationError()
        case .task(let generation, let task):
            try await awaitTask(task, generation: generation)
        }
    }

    func stopAccepting() {
        lock.withLock { accepting = false }
    }

    func waitUntilIdle() async {
        while let snapshot = lock.withLock({ () -> (UInt64, Task<Void, Error>)? in
            inFlight.map { (generation, $0) }
        }) {
            _ = try? await awaitTask(snapshot.1, generation: snapshot.0)
        }
    }

    private func awaitTask(_ task: Task<Void, Error>, generation: UInt64) async throws {
        do {
            try await task.value
            lock.withLock {
                guard self.generation == generation else { return }
                completed = true
                inFlight = nil
            }
        } catch {
            lock.withLock {
                guard self.generation == generation else { return }
                inFlight = nil
            }
            throw error
        }
    }
}

/// Synchronously registers callback maintenance before spawning it, then provides a
/// close-and-drain barrier to shutdown. A plain fire-and-forget Task has a start race:
/// shutdown can finish its own cancellation before that Task ever begins.
nonisolated final class CloudKitAdapterMaintenanceQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var activeCount = 0
    private var accepting = true

    func schedule(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        let prior = tail
        activeCount += 1
        // This queue is registered from inside CKSyncEngine's delegate callback. A plain
        // Task inherits CloudKit's private callback task-local marker even if it waits for
        // the handler to return; calling back into CKSyncEngine from that task then traps.
        let task = Task.detached { [self] in
            if let prior { await prior.value }
            await operation()
            finishCurrentTask()
        }
        tail = task
        lock.unlock()
    }

    func stopAccepting() {
        lock.withLock { accepting = false }
    }

    func waitUntilIdle() async {
        while let task = lock.withLock({ tail }) {
            await task.value
        }
    }

    private func finishCurrentTask() {
        lock.withLock {
            activeCount -= 1
            if activeCount == 0 { tail = nil }
        }
    }
}

private nonisolated final class CloudKitSyncAdapterEventReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private weak var adapter: CloudKitSyncTransportAdapter?

    func install(_ adapter: CloudKitSyncTransportAdapter) {
        lock.withLock { self.adapter = adapter }
    }

    func consume(_ event: CloudKitSyncDriverEvent) async {
        guard let adapter = lock.withLock({ self.adapter }) else { return }
        await adapter.consumeDriverEvent(event)
    }
}

private nonisolated final class State: @unchecked Sendable {
    struct HandleOutcome {
        var notifyCore = false
        var invalidateDriver = false
        var cancelAfterCallback = false
        var restartAfterCallback = false
        var diagnosticEvent: DiagnosticEvent?
    }

    struct RestartRequest {
        var serialization: Data?
        var isFullResync: Bool
    }

    private struct FetchStage {
        var activeFetchCount = 1
        var hasDurableStateAfterLatestRecords = false
        var isFullResync: Bool
    }

    private struct PendingInbound {
        var records: [WireRecord] = []
        var physicalDeletionCount = 0
        var isFullResync = false

        var isEmpty: Bool { records.isEmpty && physicalDeletionCount == 0 }
    }

    private struct SubmitLease {
        var records: [WireRecord]
        var results: [UUID: CloudKitSentResult] = [:]
    }

    private let accountIdentity: SyncAccountIdentity
    private let checkpointStore: CloudKitSyncCheckpointStore
    private let lock = NSRecursiveLock()
    private var terminalFailure: SyncTransportFailure?
    private var operationFailure: SyncTransportFailure?
    private var fetchStage: FetchStage?
    private var pendingInbound = PendingInbound()
    private var manualFetchDepth = 0
    private var submitLease: SubmitLease?
    private var pendingRestart: RestartRequest?
    private var durableSerialization: Data?
    private var schedulerFetchIsFullResync: Bool

    init(
        accountIdentity: SyncAccountIdentity,
        checkpointStore: CloudKitSyncCheckpointStore,
        durableSerialization: Data?,
        schedulerFetchIsFullResync: Bool
    ) {
        self.accountIdentity = accountIdentity
        self.checkpointStore = checkpointStore
        self.durableSerialization = durableSerialization
        self.schedulerFetchIsFullResync = schedulerFetchIsFullResync
    }

    func requireUsable() throws {
        try lock.withLock {
            if let terminalFailure { throw terminalFailure }
        }
    }

    var hasTerminalFailure: Bool {
        lock.withLock { terminalFailure != nil }
    }

    var hasIncompleteFetch: Bool {
        lock.withLock { fetchStage != nil || !pendingInbound.isEmpty }
    }

    func takePendingRestart() -> RestartRequest? {
        lock.withLock {
            defer { pendingRestart = nil }
            return pendingRestart
        }
    }

    func consumeOperationFailure() throws {
        try lock.withLock {
            if let terminalFailure { throw terminalFailure }
            if let failure = operationFailure {
                operationFailure = nil
                throw failure
            }
        }
    }

    func recordCallbackFailure(_ failure: SyncTransportFailure) -> HandleOutcome {
        lock.withLock { recordFailureUnlocked(failure) }
    }

    func beginManualFetch() {
        lock.withLock { manualFetchDepth += 1 }
    }

    func finishManualFetch() throws {
        try lock.withLock {
            guard manualFetchDepth > 0 else {
                throw SyncTransportFailure.rejected(.permanent(
                    detail: "CloudKit completed an unpaired fetch transaction"))
            }
            manualFetchDepth -= 1
            // State updates are their own durability boundaries. A late update may seal
            // records after the explicit call returns; until then the old serialization
            // guarantees at-least-once redelivery after a crash.
        }
    }

    func abortManualFetch() -> RestartRequest? {
        lock.withLock {
            manualFetchDepth = max(0, manualFetchDepth - 1)
            // Another scheduler-owned fetch may still be alive even if this stage has
            // not delivered records or state yet. Retire the whole scheduler epoch so
            // its later callbacks cannot advance the durable watermark outside a stage.
            let interrupted = fetchStage != nil || !pendingInbound.isEmpty
            let rollback = interrupted ? RestartRequest(
                serialization: durableSerialization,
                isFullResync: schedulerFetchIsFullResync) : nil
            fetchStage = nil
            pendingInbound = PendingInbound()
            return rollback
        }
    }

    /// Called only after the driver has stopped accepting the retired engine's events.
    /// Any uncommitted stage is intentionally discarded so its old-epoch watermark can
    /// neither leak into nor poison the new complete snapshot.
    func retireSchedulerForFullResync() throws {
        try lock.withLock {
            try requireUsable()
            guard manualFetchDepth == 0, submitLease == nil else {
                throw SyncTransportFailure.unreachable(
                    detail: "CloudKit reconciliation overlapped another data-plane operation")
            }
            fetchStage = nil
            pendingInbound = PendingInbound()
            pendingRestart = nil
        }
    }

    /// Must run before a replacement driver constructs an automatically-syncing engine.
    /// That ordering makes the scheduler mode immutable from its first possible callback.
    func prepareSchedulerRestart(serialization: Data?, isFullResync: Bool) {
        lock.withLock {
            durableSerialization = serialization
            schedulerFetchIsFullResync = isFullResync
            fetchStage = nil
            pendingInbound = PendingInbound()
        }
    }

    func beginSubmit(_ records: [WireRecord]) throws {
        try lock.withLock {
            try requireUsable()
            guard submitLease == nil else {
                throw SyncTransportFailure.unreachable(
                    detail: "a CloudKit submission is already in progress")
            }
            submitLease = SubmitLease(records: records)
        }
    }

    func abortSubmit() {
        lock.withLock { submitLease = nil }
    }

    func finishSubmit() throws -> [SyncSubmitResult] {
        try lock.withLock {
            try requireUsable()
            guard let lease = submitLease else {
                throw SyncTransportFailure.unreachable(
                    detail: "the CloudKit submission lease disappeared")
            }
            submitLease = nil
            return lease.records.map { offered in
                guard let result = lease.results[offered.id] else {
                    return SyncSubmitResult(
                        id: offered.id,
                        outcome: .rejected(.rateLimited(retryAfter: 5)))
                }
                switch result {
                case .accepted(let id, let rev, let version)
                    where id == offered.id && rev == offered.rev:
                    return SyncSubmitResult(
                        id: offered.id,
                        outcome: .accepted(rev: rev, recordVersion: version))
                case .rejected(let id, let rejection) where id == offered.id:
                    return SyncSubmitResult(id: offered.id, outcome: .rejected(rejection))
                default:
                    return SyncSubmitResult(
                        id: offered.id,
                        outcome: .rejected(.rateLimited(retryAfter: 5)))
                }
            }
        }
    }

    func nextBatch(
        scope: CloudKitSyncSendScope,
        limit: Int
    ) -> CloudKitRecordZoneChangeBatch? {
        lock.withLock {
            guard terminalFailure == nil, let lease = submitLease else { return nil }
            let unresolved = lease.records.filter {
                lease.results[$0.id] == nil && scope.contains($0.id)
            }
            guard !unresolved.isEmpty else { return nil }
            let bounded = Array(unresolved.prefix(max(1, limit)))
            return CloudKitRecordZoneChangeBatch(
                recordsToSave: bounded,
                recordIDsToDelete: [])
        }
    }

    func handle(_ event: CloudKitSyncDriverEvent) throws -> HandleOutcome {
        try lock.withLock {
            try handleUnlocked(event)
        }
    }

    private func handleUnlocked(_ event: CloudKitSyncDriverEvent) throws -> HandleOutcome {
        switch event {
        case .accountChange(.signIn):
            try requireUsable()
            return HandleOutcome()

        case .accountChange(.signOut), .accountChange(.switchAccounts):
            guard terminalFailure == nil else { return HandleOutcome() }
            terminalFailure = .accountChanged
            operationFailure = nil
            fetchStage = nil
            pendingInbound = PendingInbound()
            submitLease = nil
            pendingRestart = nil
            return HandleOutcome(
                notifyCore: true,
                invalidateDriver: true,
                cancelAfterCallback: true)

        case .remoteDataLoss(let reason):
            guard terminalFailure == nil else { return HandleOutcome() }
            terminalFailure = .remoteDataReset(detail: reason.failureDetail)
            operationFailure = nil
            fetchStage = nil
            pendingInbound = PendingInbound()
            submitLease = nil
            pendingRestart = nil
            return HandleOutcome(
                notifyCore: true,
                invalidateDriver: true,
                cancelAfterCallback: true)

        case .operationFailed(let failure):
            return recordFailureUnlocked(failure)

        default:
            try requireUsable()
        }

        switch event {
        case .willFetch:
            if var stage = fetchStage {
                stage.activeFetchCount += 1
                stage.isFullResync = stage.isFullResync || schedulerFetchIsFullResync
                fetchStage = stage
            } else {
                fetchStage = FetchStage(
                    hasDurableStateAfterLatestRecords: durableSerialization != nil
                        && pendingInbound.isEmpty,
                    isFullResync: schedulerFetchIsFullResync)
            }
            return observedOutcome(kind: .willFetch)

        case .fetchedRecords(let records, let deletionCount):
            guard deletionCount >= 0 else {
                throw SyncTransportFailure.rejected(.permanent(
                    detail: "CloudKit delivered an invalid physical deletion count"))
            }
            pendingInbound.records.append(contentsOf: records)
            pendingInbound.physicalDeletionCount += deletionCount
            pendingInbound.isFullResync = pendingInbound.isFullResync
                || fetchStage?.isFullResync == true
                || schedulerFetchIsFullResync
            if !records.isEmpty || deletionCount > 0 {
                fetchStage?.hasDurableStateAfterLatestRecords = false
            }
            // Apple defines stateUpdate, not will/did callbacks, as the durability
            // boundary. Accepting records outside our lifecycle bookkeeping prevents a
            // lifecycle mismatch from turning into silent watermark advancement.
            return observedOutcome(
                kind: .fetchedRecords,
                recordCount: records.count)

        case .stateUpdate(let serialization):
            let sealed = pendingInbound
            let fetchDepth = fetchStage?.activeFetchCount ?? 0
            let stateUpdateIsFullResync = sealed.isFullResync
                || fetchStage?.isFullResync == true
            let generation = try checkpointStore.sealStateUpdate(
                records: sealed.records,
                physicalDeletionCount: sealed.physicalDeletionCount,
                stateSerialization: serialization,
                isFullResync: sealed.isFullResync,
                for: accountIdentity)
            durableSerialization = serialization
            pendingInbound = PendingInbound()
            var publishedGeneration = false
            if var stage = fetchStage {
                stage.hasDurableStateAfterLatestRecords = true
                fetchStage = stage
                publishedGeneration = try completeFetchIfPossible()
            }
            return observedOutcome(
                kind: .stateUpdate,
                recordCount: sealed.records.count,
                generationSealed: generation != nil,
                notifyCore: publishedGeneration && manualFetchDepth == 0,
                fullResyncOverride: stateUpdateIsFullResync,
                fetchDepthOverride: fetchDepth)

        case .didFetch:
            guard var stage = fetchStage else {
                return observedOutcome(kind: .didFetch)
            }
            guard stage.activeFetchCount > 0 else { return observedOutcome(kind: .didFetch) }
            stage.activeFetchCount -= 1
            let didFetchWasFullResync = stage.isFullResync
            let didFetchDepth = stage.activeFetchCount
            if stage.activeFetchCount == 0,
               !stage.hasDurableStateAfterLatestRecords,
               pendingInbound.isEmpty {
                // CKSyncEngine can complete a genuinely empty fetch without publishing
                // new state. The old watermark remains valid; a nil-origin epoch stays
                // marked in progress and will be retried rather than falsely completed.
                fetchStage = nil
            } else {
                fetchStage = stage
            }
            let completedFullResync = try completeFetchIfPossible()
            return observedOutcome(
                kind: .didFetch,
                notifyCore: completedFullResync && manualFetchDepth == 0,
                fullResyncOverride: didFetchWasFullResync,
                fetchDepthOverride: didFetchDepth)

        case .sentRecords(let results):
            guard var lease = submitLease else {
                return observedOutcome(kind: .sentRecords, recordCount: results.count)
            }
            let offeredIDs = Set(lease.records.map(\.id))
            for result in results where offeredIDs.contains(result.id) {
                lease.results[result.id] = result
            }
            submitLease = lease
            return observedOutcome(kind: .sentRecords, recordCount: results.count)

        case .didSend:
            return observedOutcome(kind: .didSend)

        case .accountChange, .operationFailed, .remoteDataLoss:
            return HandleOutcome()
        }
    }

    private func observedOutcome(
        kind: DiagnosticCloudSyncEventKind,
        recordCount: Int = 0,
        generationSealed: Bool = false,
        notifyCore: Bool = false,
        fullResyncOverride: Bool? = nil,
        fetchDepthOverride: Int? = nil
    ) -> HandleOutcome {
        HandleOutcome(
            notifyCore: notifyCore,
            diagnosticEvent: .cloudKitSyncEvent(
                kind: kind,
                recordCount: recordCount,
                fetchDepth: fetchDepthOverride ?? fetchStage?.activeFetchCount ?? 0,
                submitActive: submitLease != nil,
                fullResync: fullResyncOverride
                    ?? fetchStage?.isFullResync
                    ?? schedulerFetchIsFullResync,
                generationSealed: generationSealed))
    }

    /// Returns true when this boundary published records or completed a full scan.
    private func completeFetchIfPossible() throws -> Bool {
        guard let stage = fetchStage,
              stage.activeFetchCount == 0,
              stage.hasDurableStateAfterLatestRecords,
              pendingInbound.isEmpty else { return false }
        fetchStage = nil
        let completion = try checkpointStore.completeFetch(
            isFullResync: stage.isFullResync,
            for: accountIdentity)
        if completion.completedFullResync {
            schedulerFetchIsFullResync = false
            let generationCounts: (pending: Int, unready: Int)
            switch checkpointStore.load(for: accountIdentity) {
            case .loaded(let checkpoint):
                generationCounts = (
                    checkpoint.generations.count,
                    checkpoint.unreadyGenerationCount)
            default:
                generationCounts = (0, 0)
            }
            Diagnostics.record(.cloudKitSchedulerTransition(
                action: .fullResyncCompleted,
                reason: nil,
                fullResync: true,
                pendingGenerationCount: generationCounts.pending,
                unreadyGenerationCount: generationCounts.unready))
        }
        return completion.readiedGenerationCount > 0
            || completion.completedFullResync
    }

    private func recordFailureUnlocked(_ failure: SyncTransportFailure) -> HandleOutcome {
        guard terminalFailure == nil else { return HandleOutcome() }
        let interruptedFetch = fetchStage != nil || !pendingInbound.isEmpty
        fetchStage = nil
        pendingInbound = PendingInbound()
        switch failure {
        case .accountChanged, .checkpointUnreadable, .remoteDataReset,
             .rejected(.permanent):
            terminalFailure = failure
            operationFailure = nil
            submitLease = nil
            pendingRestart = nil
            return HandleOutcome(
                notifyCore: true,
                invalidateDriver: true,
                cancelAfterCallback: true)
        case .unreachable, .pushUnsupported, .rejected:
            operationFailure = failure
            if interruptedFetch {
                pendingRestart = RestartRequest(
                    serialization: durableSerialization,
                    isFullResync: schedulerFetchIsFullResync)
                return HandleOutcome(
                    notifyCore: true,
                    invalidateDriver: true,
                    restartAfterCallback: manualFetchDepth == 0)
            }
            return HandleOutcome(notifyCore: true)
        }
    }

}
