import CloudKit
import Foundation

// App target only — CloudKit implementation stays outside CorePackage/snippets-cli.

/// Account-scoped CloudKit transport whose scheduling and server-token lifecycle are
/// owned by CKSyncEngine.
///
/// Core's `SyncEngine` remains the domain reducer and `SyncJournal` remains the only
/// durable outbound source. CKSyncEngine receives exact immutable journal offers via
/// `hasPendingUntrackedChanges`; its own pending-record list is never a second outbox.
nonisolated final class CloudKitTransport: SyncTransport, @unchecked Sendable {
    let identifier: String
    let supportsPush = true

    /// Remote notifications are primary. This is only a very infrequent missed-push
    /// safety check; the old two-minute polling loop is intentionally gone.
    let pollInterval: TimeInterval = 6 * 60 * 60

    let events: AsyncStream<SyncTransportEvent>
    private let eventContinuation: AsyncStream<SyncTransportEvent>.Continuation

    private let containerIdentifier: String
    private let accountStatusProvider: @Sendable () async throws -> CKAccountStatus
    private let userRecordIDProvider: @Sendable () async throws -> CKRecord.ID
    private let environment: CloudKitContainerEnvironment
    private let checkpointStore: CloudKitSyncCheckpointStore
    private let driverFactory: @Sendable (Data?, Bool) -> any CloudKitSyncDriving

    private let lock = NSLock()
    private let adapterCreationLock = NSLock()
    private let adapterRetirement = CloudKitAdapterRetirementGate()
    private var preparedAccountIdentity: SyncAccountIdentity?
    private var adapter: CloudKitSyncTransportAdapter?
    private var adapterAccountIdentity: SyncAccountIdentity?
    private var adapterEventTask: Task<Void, Never>?
    private var accountObserver: (any NSObjectProtocol)?
    private var isShutDown = false

    /// Kept comfortably inside CloudKit's request ceilings; the driver also asks for a
    /// new batch after each chunk and preserves the exact journal lease across retries.
    private static let maxRecordsPerRequest = 200
    private static let maxBytesPerRequest = 1_500_000

    init(
        containerIdentifier: String = CloudKitSchema.containerIdentifier,
        zoneName: String = CloudKitSchema.zoneName,
        identifier: String = "icloud",
        accountStatusProvider: (@Sendable () async throws -> CKAccountStatus)? = nil,
        userRecordIDProvider: (@Sendable () async throws -> CKRecord.ID)? = nil,
        environmentProvider: (@Sendable () -> CloudKitContainerEnvironment)? = nil,
        checkpointStore: CloudKitSyncCheckpointStore = CloudKitSyncCheckpointStore(),
        driverProvider: (@Sendable (Data?, Bool) -> any CloudKitSyncDriving)? = nil
    ) {
        self.identifier = identifier
        self.containerIdentifier = containerIdentifier
        // CKContainer initialization traps in an unsigned XCTest host. Keep the one
        // explicit production container lazy so account-only tests that inject their
        // provider boundary never touch CloudKit's entitlement-checked initializer.
        // The same lazy instance is shared by the default account and data-plane paths.
        let lazyContainer = CloudKitLazyContainer(identifier: containerIdentifier)
        self.accountStatusProvider = accountStatusProvider ?? {
            try await lazyContainer.value.accountStatus()
        }
        self.userRecordIDProvider = userRecordIDProvider ?? {
            try await lazyContainer.value.userRecordID()
        }
        environment = environmentProvider?() ?? CloudKitRuntimeEnvironment.current(
            containerIdentifier: containerIdentifier)
        self.checkpointStore = checkpointStore
        if let driverProvider {
            driverFactory = driverProvider
        } else {
            driverFactory = { serialization, allowCreate in
                CloudKitSyncEngineDriver(
                    database: lazyContainer.value.privateCloudDatabase,
                    zoneID: CKRecordZone.ID(
                        zoneName: zoneName,
                        ownerName: CKCurrentUserDefaultName),
                    stateSerialization: serialization,
                    allowInitialZoneCreation: allowCreate)
            }
        }

        var continuation: AsyncStream<SyncTransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventContinuation = continuation
        observeAccountChanges()
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        adapterEventTask?.cancel()
        eventContinuation.finish()
    }

    func shutdown() async {
        let detached = adapterCreationLock.withLock { () -> (
            Task<Void, Never>?, Task<Void, Never>?, (any NSObjectProtocol)?
        ) in
            let values = lock.withLock { () -> (
                CloudKitSyncTransportAdapter?, Task<Void, Never>?, (any NSObjectProtocol)?
            ) in
                isShutDown = true
                let values = (adapter, adapterEventTask, accountObserver)
                adapter = nil
                adapterAccountIdentity = nil
                preparedAccountIdentity = nil
                adapterEventTask = nil
                accountObserver = nil
                return values
            }
            // Register retirement before releasing the creation lock. A racing data
            // plane call can therefore never pass the idle check and construct another
            // engine while this one is still draining.
            return (values.0.map(adapterRetirement.retire), values.1, values.2)
        }
        if let observer = detached.2 {
            NotificationCenter.default.removeObserver(observer)
        }
        detached.1?.cancel()
        eventContinuation.finish()
        if let retirement = detached.0 { await retirement.value }
        await adapterRetirement.waitUntilIdle()
    }

    // MARK: - Account scope

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        let preflight = try await preflightScope()
        switch preflight.checkpointIssue {
        case .accountChanged: throw SyncTransportFailure.accountChanged
        case .unreadable:
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the authenticated local CloudKit scheduler checkpoint is unreadable")
        case nil: return preflight.identity
        }
    }

    func preflightScope() async throws -> SyncScopePreflight {
        let identity = try await currentAccountIdentity()
        let retirement = adapterCreationLock.withLock { () -> Task<Void, Never>? in
            let stale = lock.withLock { () -> CloudKitSyncTransportAdapter? in
                guard !isShutDown else { return nil }
                let changed = preparedAccountIdentity != nil
                    && preparedAccountIdentity != identity
                preparedAccountIdentity = identity
                guard changed else { return nil }
                let stale = adapter
                adapter = nil
                adapterAccountIdentity = nil
                adapterEventTask?.cancel()
                adapterEventTask = nil
                return stale
            }
            return stale.map(adapterRetirement.retire)
        }
        if lock.withLock({ isShutDown }) {
            throw SyncTransportFailure.unreachable(
                detail: "the CloudKit transport has stopped")
        }
        if let retirement { await retirement.value }
        // An account notification may have registered the retirement immediately
        // before this preflight began, leaving no adapter for the block above to detach.
        // Still wait before reading the checkpoint: an old delegate callback must not
        // race the new scope's binding decision or encrypted scheduler bytes.
        await adapterRetirement.waitUntilIdle()

        // Scope/decryption is part of account preflight, not lazy adapter creation.
        // It must fail before Core projects local user data or marks an outbound offer.
        let issue: SyncScopePreflight.CheckpointIssue?
        switch checkpointStore.load(for: identity) {
        case .missing, .loaded:
            issue = nil
        case .scopeMismatch:
            issue = .accountChanged
        case .unreadable:
            issue = .unreadable
        }
        return SyncScopePreflight(identity: identity, checkpointIssue: issue)
    }

    /// Called by Core only after it durably captured local intent in the old account's
    /// journal. That ordering makes replacing account-scoped CKSyncEngine state safe.
    func resetAfterAccountReview() async throws {
        let identity = try await beginAccountOperation()
        let allowsZoneBootstrap: Bool
        switch checkpointStore.load(for: identity) {
        case .loaded:
            // Same-account account events still require a fresh scheduler epoch, but
            // they do not grant authority to recreate an established remote zone.
            allowsZoneBootstrap = false
        case .missing, .scopeMismatch:
            allowsZoneBootstrap = true
        case .unreadable:
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the authenticated local CloudKit scheduler checkpoint is unreadable")
        }
        if let retirement = retireAdapter() { await retirement.value }
        await adapterRetirement.waitUntilIdle()
        try checkpointStore.reset(
            for: identity,
            allowsZoneBootstrap: allowsZoneBootstrap)
        try await verifyAccountIdentity(identity)
    }

    func resetAfterCheckpointReview() async throws {
        let identity = try await beginAccountOperation()
        if let retirement = retireAdapter() { await retirement.value }
        await adapterRetirement.waitUntilIdle()
        try checkpointStore.reset(for: identity, allowsZoneBootstrap: false)
        try await verifyAccountIdentity(identity)
    }

    func resetForLocalFullResync() async throws {
        let identity = try await beginAccountOperation()
        if let retirement = retireAdapter() { await retirement.value }
        await adapterRetirement.waitUntilIdle()
        // Replace the old encrypted inbox atomically, but retain the durable fact that
        // this scope's zone was already established. A rekey/full fetch is not authority
        // to recreate a remotely purged zone and upload the local cache into it.
        try checkpointStore.reset(for: identity, allowsZoneBootstrap: false)
        try await verifyAccountIdentity(identity)
    }

    private func retireAdapter(
        clearingPreparedIdentity: Bool = false
    ) -> Task<Void, Never>? {
        adapterCreationLock.withLock {
            let stale = lock.withLock { () -> CloudKitSyncTransportAdapter? in
                if clearingPreparedIdentity { preparedAccountIdentity = nil }
                let stale = adapter
                adapter = nil
                adapterAccountIdentity = nil
                adapterEventTask?.cancel()
                adapterEventTask = nil
                return stale
            }
            return stale.map(adapterRetirement.retire)
        }
    }

    private func observeAccountChanges() {
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: nil
        ) { [weak self, eventContinuation] _ in
            self?.invalidateAccountScope()
            eventContinuation.yield(.changesAvailable)
        }
    }

    private func currentAccountIdentity() async throws -> SyncAccountIdentity {
        guard environment != .unrecognized else {
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
        if let failure = status.syncBlockingFailure { throw failure }

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
        _ = retireAdapter(clearingPreparedIdentity: true)
    }

    // MARK: - Data plane

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        let identity = try await beginAccountOperation()
        let active = try await adapter(for: identity)
        let fetched = try await active.fetchChanges(since: cursor)
        try await verifyAccountIdentity(identity)
        guard fetched.accountIdentity == identity else {
            throw SyncTransportFailure.accountChanged
        }
        return fetched
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        let identity = try await beginAccountOperation()
        guard !records.isEmpty else {
            return SyncSubmission(
                results: [], cursor: cursor, accountIdentity: identity)
        }
        let active = try await adapter(for: identity)
        let submitted = try await active.submit(records, at: cursor)
        try await verifyAccountIdentity(identity)
        guard submitted.accountIdentity == identity else {
            throw SyncTransportFailure.accountChanged
        }
        return submitted
    }

    func acknowledgeFetched(through cursor: SyncCursor?) async throws {
        let identity = try await beginAccountOperation()
        guard let active = lock.withLock({
            adapterAccountIdentity == identity ? adapter : nil
        }) else {
            // No adapter means there is no in-memory inbox to compact. A later adapter
            // will consume the durable cursor before reaching the data plane.
            return
        }
        try await active.acknowledgeFetched(through: cursor)
        try await verifyAccountIdentity(identity)
    }

    private func adapter(
        for identity: SyncAccountIdentity
    ) async throws -> CloudKitSyncTransportAdapter {
        while true {
            await adapterRetirement.waitUntilIdle()
            let attempt = try adapterCreationLock.withLock {
                try makeAdapterIfRetirementIsIdle(for: identity)
            }
            if let attempt { return attempt }
        }
    }

    /// Called only while `adapterCreationLock` is held. `nil` asks the async caller to
    /// wait again because a retirement registered between its previous await and this
    /// critical section. Detach paths take the same lock, closing that check/create gap.
    private func makeAdapterIfRetirementIsIdle(
        for identity: SyncAccountIdentity
    ) throws -> CloudKitSyncTransportAdapter? {
        guard adapterRetirement.isIdle else { return nil }
        guard !lock.withLock({ isShutDown }) else {
            throw SyncTransportFailure.unreachable(
                detail: "the CloudKit transport has stopped")
        }
        // Every path that changes the prepared scope takes adapterCreationLock. Check
        // the scope before constructing the driver: CloudKitSyncTransportAdapter starts
        // CKSyncEngine in its initializer, so rejecting it afterwards would briefly
        // leave an unregistered engine draining beside its replacement.
        guard lock.withLock({ preparedAccountIdentity == identity }) else {
            throw SyncTransportFailure.accountChanged
        }

        if let existing = lock.withLock({
            adapterAccountIdentity == identity ? adapter : nil
        }) {
            return existing
        }

        let checkpoint: CloudKitSyncCheckpoint
        switch checkpointStore.load(for: identity) {
        case .missing:
            try checkpointStore.reset(
                for: identity,
                allowsZoneBootstrap: Self.localBaseAllowsZoneBootstrap())
            guard case .loaded(let created) = checkpointStore.load(for: identity) else {
                throw SyncTransportFailure.rejected(.permanent(
                    detail: "the encrypted CloudKit scheduler checkpoint could not be created"))
            }
            checkpoint = created
        case .loaded(let loaded):
            checkpoint = loaded
        case .scopeMismatch:
            throw SyncTransportFailure.accountChanged
        case .unreadable:
            throw SyncTransportFailure.checkpointUnreadable(
                detail: "the authenticated local CloudKit scheduler checkpoint is unreadable")
        }

        let driver = driverFactory(
            checkpoint.serialization,
            checkpoint.serialization == nil && checkpoint.allowsZoneBootstrap)
        let created = try CloudKitSyncTransportAdapter(
            accountIdentity: identity,
            checkpointStore: checkpointStore,
            driver: driver)

        // Scope invalidation and competing creation are both excluded by
        // adapterCreationLock, so a successfully started adapter is installed exactly
        // once and never needs a fire-and-forget rejection path.
        lock.withLock {
            adapter = created
            adapterAccountIdentity = identity
            let stream = created.events
            adapterEventTask = Task { [weak self] in
                for await event in stream {
                    self?.eventContinuation.yield(event)
                }
            }
        }
        return created
    }

    private static func localBaseAllowsZoneBootstrap() -> Bool {
        switch SyncBaseFile.load(from: SnippetStorageLocations.syncBaseFileURL) {
        case .missing:
            return true
        case .loaded(let base):
            return base.cursor == nil
                && base.envelopes.isEmpty
                && base.recordVersions.isEmpty
        case .tooNew, .unreadable:
            return false
        }
    }

    // MARK: - Pure record helpers retained for deterministic app-target tests

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
                return .accepted(rev: returned.rev, recordVersion: recordVersion)
            } catch {
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
}

/// Thread-safe lazy ownership for the process transport's explicit CloudKit container.
/// Merely constructing CloudKitTransport must remain safe in entitlement-free tests;
/// production resolves this value on its first real account or database operation.
private nonisolated final class CloudKitLazyContainer: @unchecked Sendable {
    private let lock = NSLock()
    private let identifier: String
    private var stored: CKContainer?

    init(identifier: String) {
        self.identifier = identifier
    }

    var value: CKContainer {
        lock.withLock {
            if let stored { return stored }
            let created = CKContainer(identifier: identifier)
            stored = created
            return created
        }
    }
}

/// Serializes adapter retirement without holding a blocking lock across `await`.
/// Registration happens under CloudKitTransport's creation lock; the task itself owns
/// the adapter strongly until its CKSyncEngine has cancelled and all callbacks returned.
private nonisolated final class CloudKitAdapterRetirementGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var tail: Task<Void, Never>?
    private var activeCount = 0

    var isIdle: Bool {
        condition.withLock { activeCount == 0 }
    }

    func retire(_ adapter: CloudKitSyncTransportAdapter) -> Task<Void, Never> {
        condition.lock()
        let prior = tail
        // Register synchronously before the task can finish. Keeping a count rather
        // than appending the task afterwards closes a small completion-before-append
        // race that could otherwise make waitUntilIdle wait forever.
        activeCount += 1
        let task = Task { [self] in
            if let prior { await prior.value }
            await adapter.shutdown()
            finishCurrentTask()
        }
        tail = task
        condition.unlock()
        return task
    }

    func waitUntilIdle() async {
        while let task = condition.withLock({ tail }) {
            await task.value
        }
    }

    private func finishCurrentTask() {
        condition.withLock {
            activeCount -= 1
            if activeCount == 0 { tail = nil }
        }
    }
}
