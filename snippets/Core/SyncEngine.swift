import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

/// What `applyRemote` managed to do.
///
/// `deferredIDs` exists because "this Mac cannot file this record *yet*" is a real state
/// and used to be expressed by throwing, which took the whole round down with it. A secure
/// record arriving before its vault has appeared is one record that has to wait. A record
/// from a *different* vault is permanent and is reported separately so the engine can halt
/// instead of polling the same cursor forever.
///
/// `nonisolated` like the rest of the wire model: the app target compiles this file with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a value the fake library constructs
/// from a nonisolated context must not inherit that.
nonisolated struct ApplyOutcome: Equatable {
    /// Ids whose local state actually changed.
    var changedIDs: [UUID]
    /// Ids that could not be filed and must be offered again on a later round.
    var deferredIDs: [UUID]
    /// Ids whose ciphertext is bound to a different vault and cannot become applicable
    /// without the user resolving the vault identity conflict.
    var incompatibleVaultIDs: [UUID]

    init(
        changedIDs: [UUID] = [], deferredIDs: [UUID] = [],
        incompatibleVaultIDs: [UUID] = []
    ) {
        self.changedIDs = changedIDs
        self.deferredIDs = deferredIDs
        self.incompatibleVaultIDs = incompatibleVaultIDs
    }
}

/// A preflight partition used by the deletion guard and the apply transaction.
nonisolated struct RemoteClassification: Equatable {
    var applicable: [SyncEnvelope]
    var deferredIDs: [UUID]
    var incompatibleVaultIDs: [UUID]
}

/// What the engine reads and writes. The engine never touches a file itself.
///
/// A protocol rather than direct calls into `SnippetStore` and `SecureSnippetStore` so
/// the whole loop can be exercised against plain values. Every interesting behaviour
/// here — backoff, halting, the deletion guard, a rejected batch, a cursor that goes
/// stale mid-round — is a pain to provoke through AppKit and trivial to provoke through
/// this.
@MainActor
protocol SyncLibraryAccess: AnyObject {
    /// Everything syncable, plaintext and secure, as envelopes ready to seal.
    ///
    /// The engine passes its live ancestor rather than asking the library to re-read
    /// `base.json`. A failed derived-state write must not make the projection forget
    /// secure records the running engine already knows the backend accepted.
    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope]
    /// Partitions records before the deletion guard. A deletion the library cannot file
    /// must not count toward a mass-deletion halt, and must not be passed to `applyRemote`.
    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification
    /// Applies merged remote state, reporting what changed and what had to wait.
    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome
    /// Live ids, for the deletion guard.
    func liveIDs() -> Set<UUID>
}

/// Drives one backend, whatever it is.
///
/// ## Why this exists before either real backend does
///
/// The wire format cannot change after the first production sync — every other device
/// already speaks it — so it has to be right while it is still free to be wrong. Every
/// behaviour that decides whether user data survives lives here rather than in the
/// CloudKit or object-storage adapter, and is proven against `InMemoryTransport` with
/// fault injection. What is left in an adapter is authentication and transport, which
/// are the parts a real backend can teach us and a fake cannot.
@MainActor
final class SyncEngine {

    /// Sticky by design. Every one of these means "stop and let a human look", and
    /// auto-healing each would be actively wrong: auto-healing a mass deletion means
    /// deleting, and auto-healing an integrity failure means trusting the thing that
    /// just failed.
    enum State: Equatable {
        case disabled
        case idle(lastSync: Date?)
        case syncing
        case offline(retryAfter: Date)
        case needsAuthentication(String)
        /// A secure record arrived and there is no vault here to file it in.
        ///
        /// Separate from `.offline` because that is what it used to be reported as, and
        /// it was a lie: iCloud is reachable, the round is fine, and the user's actual
        /// problem is that the vault key has not reached this Mac. Separate from
        /// `.halted` because halts are sticky by design and this one heals itself the
        /// moment the key arrives — pushes keep working throughout, and every round
        /// retries the apply.
        case waitingForVault(String)
        case halted(SyncState.HaltReason, detail: String)

        var isHalted: Bool { if case .halted = self { return true }; return false }
    }

    private(set) var state: State = .disabled
    var onStateChange: ((State) -> Void)?

    /// Injected. Nothing here reads the system clock directly.
    var now: () -> Date = { Date() }

    private let transport: any SyncTransport
    private let library: any SyncLibraryAccess
    private let sealer: any SyncBlobSealing
    private let baseURL: URL
    private let stateURL: URL
    private let lockURL: URL
    private let temporaryDirectory: URL
    private let stateLockTimeout: TimeInterval
    private let device: String
    private var base: SyncBase
    private var consecutiveFailures = 0
    /// The exact halt value read from or written to disk. It is a compare-and-swap
    /// token: Resume may clear only this halt, never a newer stop written by a peer.
    private var durableHalt: SyncState.Halt?

    /// Production sets this to turn off the persisted sync preference if a safety halt
    /// cannot be saved. The in-memory halt still stops this process; the preference is
    /// the independent fail-closed channel that stops a relaunch.
    var onSafetyHaltPersistenceFailure: (() -> Void)?

    /// Backoff: 2s, 4s, 8s … capped at five minutes.
    ///
    /// Capped because an unreachable backend is usually a closed laptop lid, and a user
    /// who opens it after an hour should not wait another hour for the next attempt.
    private static let maxBackoff: TimeInterval = 300

    init(
        transport: any SyncTransport,
        library: any SyncLibraryAccess,
        sealer: any SyncBlobSealing,
        device: String,
        baseURL: URL = SnippetStorageLocations.syncBaseFileURL,
        stateURL: URL = SnippetStorageLocations.syncStateFileURL,
        lockURL: URL = SnippetStorageLocations.libraryLockFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL,
        stateLockTimeout: TimeInterval = 2.0
    ) {
        self.transport = transport
        self.library = library
        self.sealer = sealer
        self.device = device
        self.baseURL = baseURL
        self.stateURL = stateURL
        self.lockURL = lockURL
        self.temporaryDirectory = temporaryDirectory
        self.stateLockTimeout = stateLockTimeout
        if case .loaded(let loaded) = SyncBaseFile.load(from: baseURL) {
            self.base = loaded
        } else {
            self.base = SyncBase()
        }
        switch SyncStateFile.load(from: stateURL) {
        case .loaded(let persisted):
            if let halt = persisted.halt {
                self.durableHalt = halt
                self.state = .halted(halt.reason, detail: halt.detail)
            }
        case .tooNew(let version):
            // Once halts live in state.json, an older build cannot assume a future file
            // contains no stop it understands. Fail closed without rewriting the file.
            self.state = .halted(
                .schemaTooNew,
                detail: "Sync/state.json is version \(version); this build understands "
                    + "\(SyncState.currentSchemaVersion) and will not sync over it.")
        case .fresh:
            break
        }
    }

    // MARK: - Halting

    /// Refuses to run again until a human clears it.
    func halt(_ reason: SyncState.HaltReason, detail: String) {
        enterHalt(reason, detail: detail)
    }

    /// The only way out of a halt. Named for what it demands rather than what it does,
    /// because "resume" would read as something safe to call automatically.
    func clearHaltAfterUserReview() {
        guard case .halted(let reason, let detail) = state else { return }
        switch updatePersistedHalt(nil, expecting: durableHalt) {
        case .written:
            durableHalt = nil
            consecutiveFailures = 0
            transition(to: .idle(lastSync: nil))
        case .superseded(let newer):
            // A peer stopped for a different reason after this pane was drawn. The
            // user's review covered the old stop, not this one; adopt it and ask again.
            durableHalt = newer
            transition(to: .halted(newer.reason, detail: newer.detail))
        case .tooNew(let version):
            durableHalt = nil
            transition(to: .halted(
                .schemaTooNew,
                detail: "Sync/state.json is version \(version); update Snippets before "
                    + "sync can resume."))
        case .failed:
            transition(to: .halted(
                reason,
                detail: detail + " The reviewed stop could not be cleared from disk; "
                    + "sync remains stopped."))
        }
    }

    // MARK: - One round

    @discardableResult
    func sync() async -> State {
        guard !state.isHalted else { return state }
        if case .syncing = state { return state }
        if case .offline(let retryAfter) = state, now() < retryAfter { return state }

        transition(to: .syncing)
        do {
            let deferred = try await performRound()
            consecutiveFailures = 0
            if let deferred {
                transition(to: .waitingForVault(
                    "\(deferred) secure snippet(s) from another Mac are waiting for a key "
                    + "this one does not have yet"))
            } else {
                transition(to: .idle(lastSync: now()))
            }
        } catch is CancellationError {
            // `SyncCoordinator.stop()` cancels and then waits for this round to drain
            // before a destructive local vault removal is allowed. Cancellation is a
            // lifecycle event, not an offline failure and never a reason to back off.
            transition(to: .disabled)
        } catch let failure as SyncTransportFailure {
            handle(failure)
        } catch let failure as SyncEngineFailure {
            enterHalt(failure.reason, detail: failure.detail)
        } catch {
            handle(.unreachable(detail: "\(error)"))
        }
        return state
    }

    /// - Returns: how many records had to be deferred, or `nil` when the round applied
    ///   everything it fetched. A deferred round is not a failure — the push half
    ///   completed, everything applicable was applied — so it must not back off or count
    ///   against `consecutiveFailures`; it simply did not finish arriving.
    private func performRound() async throws -> Int? {
        try Task.checkCancellation()
        // PUSH FIRST, deliberately.
        //
        // Fetching first and applying would rewrite local records before this device's
        // own changes have left it — and if the process dies between the two, those
        // changes are gone with nothing to recover them from. Pushing first means the
        // worst case is a duplicate round, not a lost edit.
        let current = try library.currentEnvelopes(agreedBase: base)
        let pending = base.pendingChanges(from: current)

        if !pending.isEmpty {
            guard transport.supportsPush else { throw SyncTransportFailure.pushUnsupported }
            let records = try pending.map { try WireCodec.seal($0, using: sealer) }
            try Task.checkCancellation()
            let submission = try await transport.submit(records, at: base.cursor)
            try Task.checkCancellation()

            // Matched by id, never by position.
            //
            // `SyncSubmission.results` is documented as parallel to the submitted batch,
            // and a conformant transport keeps it that way — but CloudKit answers a
            // modify with `modificationResultsByID`, a *dictionary*, so any transport
            // that forwards its backend's natural order is one refactor away from
            // pairing an outcome with the wrong record. Position matching makes that
            // mistake silent and permanent in the worst direction: the record that was
            // really accepted is re-pushed forever, which is harmless, and the record
            // wrongly recorded as accepted is never pushed again, which loses it on
            // every other device. Matching by id costs a dictionary and cannot.
            let pendingByID = Dictionary(pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            for result in submission.results {
                switch result.outcome {
                case .accepted:
                    // Only now is it agreed. Recording it before the backend accepted
                    // would make the next diff skip it, and the record would never be
                    // pushed again. An outcome for an id we did not submit is ignored
                    // rather than trusted.
                    guard let accepted = pendingByID[result.id] else { continue }
                    base.record(accepted)
                case .rejected(.authenticationRequired(let detail)):
                    // Not a halt. An expired token is an ordinary, recoverable state and
                    // halting for it would put a scary sticky error in front of someone
                    // who just needs to sign in again.
                    throw SyncTransportFailure.rejected(.authenticationRequired(detail: detail))
                case .rejected(.permanent(let detail)):
                    // `backendRefused`, not `manifestIntegrityFailed`. This branch
                    // catches a container whose schema was never deployed, a full
                    // account, an oversized record — none of which is an integrity
                    // failure, and all of which used to be reported as one.
                    //
                    // The backend's own words, unwrapped: `Rejection.description`
                    // prefixes "the backend permanently refused this snippet", and after
                    // a halt title that already says exactly that, the sentence said the
                    // same thing twice before reaching anything a reader could act on.
                    throw SyncEngineFailure(reason: .backendRefused, detail: detail)
                case .rejected(let rejection):
                    guard rejection.isRetryable else {
                        // Kept for a non-retryable kind added later, so a new case
                        // cannot silently become a record that is dropped in silence.
                        throw SyncEngineFailure(
                            reason: .backendRefused, detail: "\(rejection)")
                    }
                    // Retryable: leave it out of the base so the next round tries again.
                }
            }

            // The submission's cursor is deliberately NOT adopted as the fetch position.
            //
            // A cursor is a place in the backend's change feed. The one returned by a
            // submit points *after* our own writes — which is also after everything the
            // backend already held and we had not fetched yet. Adopting it silently skips
            // all of that: seed a record remotely, push a local one, and the remote record
            // is never seen. Only a fetch may advance the fetch position.
            try Task.checkCancellation()
            try persistBase()
        }

        // FETCH, possibly paged.
        var cursor = base.cursor
        var incoming: [SyncEnvelope] = []
        var isFullResync = false

        while true {
            try Task.checkCancellation()
            let fetch = try await transport.fetchChanges(since: cursor)
            try Task.checkCancellation()
            isFullResync = isFullResync || fetch.isFullResync
            for record in fetch.records {
                do {
                    incoming.append(try WireCodec.open(record, using: sealer))
                } catch {
                    // Undecryptable. Never applied, never dropped silently — a record we
                    // cannot read is either a key we do not have or a bug, and both need
                    // to be visible rather than inferred from missing data later.
                    quarantine(record, error: error)
                }
            }
            cursor = fetch.cursor
            guard fetch.hasMore else { break }
        }

        guard !incoming.isEmpty || isFullResync else {
            try Task.checkCancellation()
            base.cursor = cursor
            try persistBase()
            return nil
        }

        // Three-way merge against the base BEFORE the guard, so the guard judges what
        // would actually be applied rather than what arrived. A remote tombstone that
        // loses to a local edit is not a deletion, and counting it as one would trip the
        // breaker on a library that was never in danger.
        let localNow = try library.currentEnvelopes(agreedBase: base)
        var merged: [SyncEnvelope] = []
        for envelope in incoming {
            guard let resolved = SyncMerge.mergeEnvelope(
                base: base.envelope(envelope.id),
                local: localNow[envelope.id],
                remote: envelope
            ) else { continue }
            merged.append(resolved)
        }

        // Classify before the circuit breaker: a rival-vault tombstone is not a deletion
        // this library can apply and must not trip a sticky mass-deletion halt.
        let classification = library.classifyRemote(merged)

        // The circuit breaker.
        let live = library.liveIDs()
        let decision = DeletionGuard.evaluate(live: live, incoming: classification.applicable)
        if case .refuse(let refusal) = decision {
            throw SyncEngineFailure(reason: .massDeletion, detail: refusal.description)
        }

        try Task.checkCancellation()
        let outcome = try library.applyRemote(classification.applicable)
        let deferred = Set(classification.deferredIDs).union(outcome.deferredIDs)
        let incompatible = Set(classification.incompatibleVaultIDs)
            .union(outcome.incompatibleVaultIDs)
        let unapplied = deferred.union(incompatible)

        // The base records what the BACKEND said, not what we merged to. Recording the
        // merged value would make the next diff believe the backend has already seen our
        // side of the merge, and our half would never be pushed.
        //
        // An unapplied record is recorded neither in the base nor by advancing the cursor.
        // Both halves matter: leaving it out of the base keeps the local library from
        // looking like it deleted a record it never received, and holding the cursor keeps
        // it available after either a temporary deferral or a resolved incompatible-vault
        // halt. Everything that *did* apply is recorded normally, so a later re-fetch
        // re-applies it as a no-op rather than as churn.
        try Task.checkCancellation()
        for envelope in incoming where !unapplied.contains(envelope.id) {
            base.record(envelope)
        }
        if unapplied.isEmpty {
            base.cursor = cursor
        }
        try persistBase()
        if !incompatible.isEmpty {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "\(incompatible.count) secure snippet(s) belong to a different "
                    + "vault identity. Their ciphertext cannot be opened by this Mac; "
                    + "sync stopped instead of repeatedly fetching the same records.")
        }
        return deferred.isEmpty ? nil : deferred.count
    }

    // MARK: - Failure handling

    private func handle(_ failure: SyncTransportFailure) {
        switch failure {
        case .rejected(.authenticationRequired(let detail)):
            // Retrying an auth failure forever just locks the account out.
            transition(to: .needsAuthentication(detail))
        case .rejected(.permanent(let detail)):
            // Split out of the case above, where it used to sit. A permanent rejection is
            // not an authentication problem, and lumping the two together meant an
            // undeployed CloudKit schema — the commonest cause of a `.permanent` on the
            // *fetch* leg, since `fetchChanges` maps `.invalidArguments`/`.badContainer`
            // through the same table — told the user "iCloud needs attention", sending
            // them to check a sign-in that was never the problem. The submit leg already
            // routes this to `backendRefused`; the same condition must not describe
            // itself two different ways depending on which half of the round saw it.
            enterHalt(.backendRefused, detail: detail)
        case .pushUnsupported:
            transition(to: .needsAuthentication("this backend does not accept pushes"))
        case .unreachable, .rejected:
            consecutiveFailures += 1
            let delay = min(pow(2, Double(consecutiveFailures)), Self.maxBackoff)
            transition(to: .offline(retryAfter: now().addingTimeInterval(delay)))
        }
    }

    private func quarantine(_ record: WireRecord, error: any Error) {
        let folder = SnippetStorageLocations.syncQuarantineFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(record.id.uuidString).blob", isDirectory: false)
        try? AtomicFileWriter.write(record.blob, to: url, temporaryDirectory: temporaryDirectory)
        NSLog("Snippets: could not decrypt a synced record (\(error)); kept at \(url.lastPathComponent) and not applied.")
    }

    private func persistBase() throws {
        do {
            try SyncBaseFile.write(base, to: baseURL, temporaryDirectory: temporaryDirectory)
        } catch {
            // Not fatal: the base is derived, and losing it costs one full reconcile
            // rather than any data. Worth surfacing, not worth halting for.
            NSLog("Snippets: could not write the sync base: \(error)")
        }
    }

    /// Makes a safety stop survive process death and an ordinary relaunch.
    ///
    /// `SyncState.halt` has always promised this, but the engine previously kept its
    /// halt only in memory. A rival vault therefore stopped the two-minute poll in one
    /// process, then fetched the same held cursor and stopped again after every launch.
    /// Backend refusals and mass-deletion stops had the same hole. All safety halts now
    /// go through this one door.
    private func enterHalt(_ reason: SyncState.HaltReason, detail: String) {
        // JSON's ISO-8601 strategy stores whole seconds. Normalize before using the
        // value as a CAS token so an immediate same-process Resume compares equal to
        // what another decoder reads from disk.
        let at = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
        let halt = SyncState.Halt(reason: reason, detail: detail, at: at)
        switch updatePersistedHalt(halt, expecting: durableHalt) {
        case .written(let stored):
            durableHalt = stored
            transition(to: .halted(reason, detail: detail))
        case .superseded(let newer):
            durableHalt = newer
            transition(to: .halted(newer.reason, detail: newer.detail))
        case .tooNew(let version):
            durableHalt = nil
            transition(to: .halted(
                .schemaTooNew,
                detail: "Sync/state.json is version \(version); update Snippets before "
                    + "sync can resume."))
        case .failed:
            // The in-memory halt protects this process. Turning off the separate,
            // persisted opt-in protects the next process even when state.json itself
            // is unwritable or its lock cannot be taken.
            onSafetyHaltPersistenceFailure?()
            transition(to: .halted(
                reason,
                detail: detail + " The safety stop could not be saved to disk, so iCloud "
                    + "Sync was turned off before relaunch."))
        }
    }

    private enum HaltUpdateResult {
        case written(SyncState.Halt?)
        case superseded(SyncState.Halt)
        case tooNew(Int)
        case failed
    }

    /// Updates only the halt field while holding the same cross-process lock as every
    /// library writer. Loading and rewriting `state.json` without that lock can erase a
    /// generation bump or crash marker written by the CLI between the two operations.
    ///
    /// A future-version state file is never overwritten. The result distinguishes a
    /// newer peer halt, a future schema, and an I/O/locking failure so every caller can
    /// fail closed without erasing or stepping past the durable stop.
    private func updatePersistedHalt(
        _ halt: SyncState.Halt?, expecting expected: SyncState.Halt?
    ) -> HaltUpdateResult {
        let held: FileGuard.Held
        do {
            held = try FileGuard.acquire(at: lockURL, timeout: stateLockTimeout)
        } catch {
            NSLog("Snippets: could not lock sync state while changing its halt (\(error)).")
            return .failed
        }
        defer { held.release() }

        // `FileGuard.none` lets ordinary user-data writes use their verified retry path
        // on exotic filesystems. This read-modify-write has no such CAS verification:
        // proceeding unlocked could erase a concurrent crash marker, generation bump,
        // or newer halt. A safety marker must fail closed instead.
        guard !held.isUnlocked else {
            NSLog("Snippets: refusing to change a sync halt without a filesystem lock.")
            return .failed
        }

        var persisted: SyncState
        switch SyncStateFile.load(
            from: stateURL,
            makeFresh: { SyncState.fresh(deviceID: device, now: now()) }
        ) {
        case .loaded(let loaded), .fresh(let loaded):
            persisted = loaded
        case .tooNew(let version):
            NSLog("Snippets: refusing to change a halt in sync state version \(version).")
            return .tooNew(version)
        }

        if persisted.halt != expected {
            // A peer may have cleared the halt already. Clearing nil again is safe; a
            // different non-nil halt is a new stop this caller has not reviewed.
            if halt == nil, persisted.halt == nil { return .written(nil) }
            if let newer = persisted.halt { return .superseded(newer) }
        }

        if persisted.halt == halt { return .written(halt) }
        persisted.halt = halt
        do {
            try SyncStateFile.write(
                persisted, to: stateURL, temporaryDirectory: temporaryDirectory)
            return .written(halt)
        } catch {
            NSLog("Snippets: could not persist the sync halt (\(error)).")
            return .failed
        }
    }

    private func transition(to newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    /// Test seam: what the engine believes the backend has agreed to.
    var agreedBase: SyncBase { base }
}

/// A failure that must stop sync rather than be retried.
nonisolated struct SyncEngineFailure: Error {
    var reason: SyncState.HaltReason
    var detail: String
}
