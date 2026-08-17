import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// A complete backend that lives in a dictionary, and can be told to misbehave.
///
/// ## Why this ships in `Core/` rather than in the test target
///
/// It is not a mock. It implements the whole `SyncTransport` contract — cursors,
/// paging, revisions, tombstones, conflict detection — and the engine is meant to be
/// developed against it exclusively until it is boring. The interesting failures in a
/// sync engine are not "the network was down"; they are the ones nobody can reproduce
/// on demand against a real backend:
///
/// - a batch half accepted, then a crash before the rest is retried
/// - a cursor invalidated between two pages of a resync
/// - the same page delivered twice, so every record arrives twice
/// - a rejection that is retryable arriving next to one that is not
///
/// Every one of those is a switch below. Reproducing them on iCloud means waiting for
/// Apple to have a bad day; reproducing them here means setting a `Bool`.
///
/// It also lives here because `snippets-cli doctor` can use it as a self-test: run the
/// whole engine against a fake backend, in-process, and confirm the merge and the
/// deletion guard behave, without touching the user's account.
///
/// ## Concurrency
///
/// A `final class` with a lock rather than an `actor`, because `SyncTransport` is a
/// `nonisolated` protocol and `events` is a synchronous property requirement — an
/// actor's stored property would be isolated and could not satisfy it. The lock is
/// held only around dictionary mutation and never across the `await`s, so a slow
/// injected latency cannot deadlock a test.
nonisolated final class InMemoryTransport: SyncTransport, @unchecked Sendable {

    // MARK: - Fault injection

    /// Every way this transport can be told to behave badly.
    ///
    /// All of them default to "behave", so a test opts into exactly the one failure it
    /// is about and the rest of the transport stays honest. A fake with several faults
    /// on at once proves nothing, because the failure cannot be attributed.
    struct Faults: Sendable, Equatable {

        /// Refuse *every* record in every submission with this rejection.
        var rejectEverything: SyncRejection?

        /// Refuse these specific records. Survives across submissions until cleared, so
        /// a test can prove the engine gives up on a `.permanent` rejection instead of
        /// retrying forever.
        var rejectRecords: [UUID: SyncRejection] = [:]

        /// Fail the next N fetches outright, as if the network were down. Counts down.
        var failFetches = 0

        /// Fail the next N submissions outright. Counts down.
        var failSubmits = 0

        /// Fail the next N local full-resync checkpoint replacements. This models a
        /// crash/network failure after recovery intent was made durable but before the
        /// transport reset completed.
        var failLocalFullResets = 0

        /// Fail *everything* until cleared. The "aeroplane mode" switch, as distinct
        /// from the counted flakiness above.
        var unreachable = false

        /// Delay applied to every call, through the injected sleeper. A test that wants
        /// to assert ordering under latency sets this and injects a sleeper that records
        /// instead of sleeping, so the suite stays fast and deterministic.
        var latency: Duration = .zero

        /// Accept at most this many records per submission and reject the remainder
        /// with `partialBatchRejection`. The single most valuable fault here: an engine
        /// that assumes a submission is all-or-nothing loses the unaccepted tail
        /// silently, and no real backend will reproduce that on request.
        var acceptAtMostPerBatch: Int?

        var partialBatchRejection: SyncRejection = .rateLimited(retryAfter: 1)

        /// The next fetch ignores the cursor it was given, emits
        /// `.cursorInvalidated`, and returns the whole store as a full resync. Cleared
        /// once it fires.
        var invalidateCursorOnNextFetch = false

        /// Deliver every fetched page this many times over. `1` is honest delivery;
        /// `2` is a backend that redelivered a page after a retry. The page repeats as
        /// a block (r1,r2,r1,r2), which is what a retried request actually looks like —
        /// not interleaved, which nothing produces.
        var deliverPagesTimes = 1

        /// Return `nil` for the cursor on the next fetch, as a backend that lost its
        /// place does. The engine must not read this as "start over".
        var dropCursorOnNextFetch = false

        /// Hand back a different rev than the one submitted, as a backend that assigns
        /// its own revisions does. Catches an engine that assumes its rev survives.
        var rewriteAcceptedRevs = false

        static let none = Faults()
    }

    // MARK: - Stored state

    private struct Stored {
        var record: WireRecord
        /// Monotonic; the cursor is this number. Reassigned on every write, which is
        /// what makes "changes since" a simple comparison and makes a record that is
        /// written twice appear twice in the stream — exactly like a real log-shaped
        /// backend.
        var sequence: Int
    }

    private let lock = NSLock()
    private var stored: [UUID: Stored] = [:]
    private var nextSequence = 1
    private var faultsStorage = Faults.none
    private var submissionLog: [[WireRecord]] = []
    private var fetchCount = 0
    private var localFullResetCount = 0

    /// Injected so latency costs no wall-clock time in the suite. Nothing in this type
    /// reads a real clock or sleeps directly.
    private let sleeper: @Sendable (Duration) async throws -> Void

    let identifier: String
    let supportsPush: Bool
    let pollInterval: TimeInterval
    let pageSize: Int

    let events: AsyncStream<SyncTransportEvent>
    private let eventContinuation: AsyncStream<SyncTransportEvent>.Continuation

    init(
        identifier: String = "memory",
        supportsPush: Bool = true,
        pollInterval: TimeInterval = 30,
        pageSize: Int = 100,
        sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.identifier = identifier
        self.supportsPush = supportsPush
        self.pollInterval = pollInterval
        self.pageSize = pageSize
        self.sleeper = sleeper

        // `.unbounded` on purpose: dropping an event would make a dropped notification
        // indistinguishable from a fake that quietly discards them, and the tests that
        // assert on event order would be flaky rather than wrong.
        var continuation: AsyncStream<SyncTransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        eventContinuation = continuation
    }

    deinit { eventContinuation.finish() }

    // MARK: - Test control surface

    var faults: Faults {
        lock.lock(); defer { lock.unlock() }
        return faultsStorage
    }

    func configure(_ mutate: (inout Faults) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&faultsStorage)
    }

    /// Puts records in as if another device had written them, bypassing every fault.
    func seed(_ records: [WireRecord]) {
        lock.lock(); defer { lock.unlock() }
        for record in records { _ = store(record) }
    }

    /// Everything the backend holds, in sequence order.
    var snapshot: [WireRecord] {
        lock.lock(); defer { lock.unlock() }
        return stored.values.sorted { $0.sequence < $1.sequence }.map(\.record)
    }

    /// Every batch handed to `submit`, in order, including ones that were rejected.
    /// A test asserting "the engine did not resubmit a permanently rejected record"
    /// needs the rejected attempts too.
    var submittedBatches: [[WireRecord]] {
        lock.lock(); defer { lock.unlock() }
        return submissionLog
    }

    var fetchAttempts: Int {
        lock.lock(); defer { lock.unlock() }
        return fetchCount
    }

    var localFullResetAttempts: Int {
        lock.lock(); defer { lock.unlock() }
        return localFullResetCount
    }

    var currentCursor: SyncCursor? {
        lock.lock(); defer { lock.unlock() }
        return cursorLocked()
    }

    /// Emits a push hint, as a backend notification would.
    func notify(_ event: SyncTransportEvent = .changesAvailable) {
        eventContinuation.yield(event)
    }

    // No `finishEvents()`. `deinit` already finishes the continuation, and nothing ever
    // called the explicit version — a `for await` loop that needs a deterministic end
    // can have it back in one line, at which point it will also have a test.

    // MARK: - SyncTransport

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        let latency = faults.latency
        if latency != .zero { try await sleeper(latency) }

        // The event is yielded outside the lock: a continuation can run an awaiting
        // consumer synchronously, and doing that under our own lock is how a fake
        // deadlocks a test suite at 3am.
        var invalidationReason: String?
        let fetch = try performFetch(since: cursor, invalidationReason: &invalidationReason)

        if let invalidationReason {
            eventContinuation.yield(.cursorInvalidated(reason: invalidationReason))
        }
        return fetch
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        let latency = faults.latency
        if latency != .zero { try await sleeper(latency) }
        // The body is synchronous so the lock is never held across a suspension point;
        // `NSLock` is not async-safe and holding one over an `await` is a deadlock
        // waiting for a slow enough backend.
        return try performSubmit(records, at: cursor)
    }

    /// This backend has no transport-private scheduler, account binding, or remote
    /// zone lifecycle. Explicitly opting in documents why Core's reviewed reset is a
    /// safe no-op here; stateful transports inherit the fail-closed default instead.
    func resetAfterRemoteDataResetReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        guard expectedIdentity == nil else { throw SyncTransportFailure.accountChanged }
        guard expectedDatasetIdentity == nil else {
            throw SyncTransportFailure.remoteDataReset(detail: "unexpected dataset scope")
        }
    }

    func resetForLocalFullResync(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        guard expectedIdentity == nil else { throw SyncTransportFailure.accountChanged }
        guard expectedDatasetIdentity == nil else {
            throw SyncTransportFailure.remoteDataReset(detail: "unexpected dataset scope")
        }
        try performLocalFullReset()
    }

    private func performLocalFullReset() throws {
        lock.lock()
        defer { lock.unlock() }
        localFullResetCount += 1
        if faultsStorage.failLocalFullResets > 0 {
            faultsStorage.failLocalFullResets -= 1
            throw SyncTransportFailure.unreachable(detail: "injected full-resync failure")
        }
    }

    // MARK: - Internals

    private func performFetch(
        since cursor: SyncCursor?, invalidationReason: inout String?
    ) throws -> SyncFetch {
        lock.lock(); defer { lock.unlock() }
        fetchCount += 1

        if faultsStorage.unreachable {
            throw SyncTransportFailure.unreachable(detail: "InMemoryTransport.faults.unreachable")
        }
        if faultsStorage.failFetches > 0 {
            faultsStorage.failFetches -= 1
            throw SyncTransportFailure.unreachable(detail: "injected fetch failure")
        }

        var effectiveCursor = cursor
        var isFullResync = false
        if faultsStorage.invalidateCursorOnNextFetch {
            faultsStorage.invalidateCursorOnNextFetch = false
            effectiveCursor = nil
            isFullResync = true
            invalidationReason = "injected cursor invalidation"
        }
        // A cursor minted before the backend was rewound points past the end of the
        // store. Serving it as-is returns an empty page forever, which the engine reads
        // as "nothing has changed" while the whole library sits there unfetched.
        if let position = Self.position(of: effectiveCursor), position > highWaterMarkLocked() {
            effectiveCursor = nil
            isFullResync = true
            invalidationReason = "cursor is ahead of the backend"
        }

        let after = Self.position(of: effectiveCursor) ?? 0
        let pending = stored.values
            .filter { $0.sequence > after }
            .sorted { $0.sequence < $1.sequence }

        let page = Array(pending.prefix(pageSize))
        let hasMore = pending.count > page.count

        var records = page.map(\.record)
        // Duplicate delivery repeats the page as a block, which is what a retried
        // request actually looks like — not interleaved, which nothing produces.
        if faultsStorage.deliverPagesTimes > 1 {
            let once = records
            for _ in 1..<faultsStorage.deliverPagesTimes { records.append(contentsOf: once) }
        }

        var nextCursor = page.last.map { SyncCursor(String($0.sequence)) } ?? effectiveCursor
        if faultsStorage.dropCursorOnNextFetch {
            faultsStorage.dropCursorOnNextFetch = false
            nextCursor = nil
        }

        return SyncFetch(
            records: records,
            cursor: nextCursor,
            hasMore: hasMore,
            isFullResync: isFullResync,
            replacesPriorPages: isFullResync && cursor != nil)
    }

    private func performSubmit(_ records: [WireRecord], at cursor: SyncCursor?) throws -> SyncSubmission {
        lock.lock(); defer { lock.unlock() }
        submissionLog.append(records)

        guard supportsPush else { throw SyncTransportFailure.pushUnsupported }
        if faultsStorage.unreachable {
            throw SyncTransportFailure.unreachable(detail: "InMemoryTransport.faults.unreachable")
        }
        if faultsStorage.failSubmits > 0 {
            faultsStorage.failSubmits -= 1
            throw SyncTransportFailure.unreachable(detail: "injected submit failure")
        }

        var results: [SyncSubmitResult] = []
        var accepted = 0

        for record in records {
            if let rejection = faultsStorage.rejectEverything {
                results.append(SyncSubmitResult(id: record.id, outcome: .rejected(rejection)))
                continue
            }
            if let rejection = faultsStorage.rejectRecords[record.id] {
                results.append(SyncSubmitResult(id: record.id, outcome: .rejected(rejection)))
                continue
            }
            if let limit = faultsStorage.acceptAtMostPerBatch, accepted >= limit {
                results.append(SyncSubmitResult(
                    id: record.id, outcome: .rejected(faultsStorage.partialBatchRejection)))
                continue
            }
            // Real per-record optimistic concurrency. A feed cursor cannot protect an
            // individual record: it may already point past a value whose system fields
            // a legacy client never stored. The submitted generation must be the exact
            // one returned by the last fetch/save. A create carries nil and conflicts if
            // the id already exists, which is how a lost create acknowledgement becomes
            // a merge instead of an unconditional overwrite.
            if let existing = stored[record.id],
               existing.record.recordVersion != record.recordVersion {
                results.append(SyncSubmitResult(
                    id: record.id,
                    outcome: .rejected(.conflict(remote: existing.record))))
                continue
            }
            if stored[record.id] == nil, record.recordVersion != nil {
                results.append(SyncSubmitResult(
                    id: record.id,
                    outcome: .rejected(.conflict(remote: nil))))
                continue
            }

            var toStore = record
            if faultsStorage.rewriteAcceptedRevs { toStore.rev = "srv-\(nextSequence)-\(record.rev)" }
            let stored = store(toStore)
            accepted += 1
            results.append(SyncSubmitResult(
                id: record.id,
                outcome: .accepted(
                    rev: stored.record.rev,
                    recordVersion: stored.version)))
        }

        return SyncSubmission(results: results, cursor: cursorLocked())
    }

    /// Caller holds `lock`.
    @discardableResult
    private func store(
        _ record: WireRecord
    ) -> (record: WireRecord, version: SyncRecordVersion) {
        var versioned = record
        let version = SyncRecordVersion(Data("memory-\(nextSequence)".utf8))
        versioned.recordVersion = version
        stored[record.id] = Stored(record: versioned, sequence: nextSequence)
        nextSequence += 1
        return (versioned, version)
    }

    /// Caller holds `lock`.
    private func cursorLocked() -> SyncCursor? {
        guard let highest = stored.values.map(\.sequence).max() else { return nil }
        return SyncCursor(String(highest))
    }

    /// Caller holds `lock`.
    private func highWaterMarkLocked() -> Int {
        stored.values.map(\.sequence).max() ?? 0
    }

    /// A cursor this transport did not mint parses to `nil` and is treated as "from the
    /// beginning" rather than as an error, because that is the safe direction: sending
    /// too much costs bandwidth, sending too little looks like deletions.
    private static func position(of cursor: SyncCursor?) -> Int? {
        guard let cursor, let value = Int(cursor.rawValue) else { return nil }
        return value
    }
}
