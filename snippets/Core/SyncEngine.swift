import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

/// What `applyRemote` managed to do.
///
/// `deferredIDs` exists because "this Mac cannot file this record *yet*" is a real state
/// and used to be expressed by throwing, which took the whole round down with it. A secure
/// record arriving at a Mac whose vault has not appeared — or whose vault is a different
/// one — is not an error in the batch; it is one record that has to wait. Every other
/// envelope in the same batch is perfectly applicable, and the plaintext ones have nothing
/// to do with vaults at all.
///
/// `nonisolated` like the rest of the wire model: the app target compiles this file with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and a value the fake library constructs
/// from a nonisolated context must not inherit that.
nonisolated struct ApplyOutcome: Equatable {
    /// Ids whose local state actually changed.
    var changedIDs: [UUID]
    /// Ids that could not be filed and must be offered again on a later round.
    var deferredIDs: [UUID]

    init(changedIDs: [UUID] = [], deferredIDs: [UUID] = []) {
        self.changedIDs = changedIDs
        self.deferredIDs = deferredIDs
    }
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
    func currentEnvelopes() throws -> [UUID: SyncEnvelope]
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
    private let temporaryDirectory: URL
    private let device: String
    private var base: SyncBase
    private var consecutiveFailures = 0

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
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) {
        self.transport = transport
        self.library = library
        self.sealer = sealer
        self.device = device
        self.baseURL = baseURL
        self.temporaryDirectory = temporaryDirectory
        if case .loaded(let loaded) = SyncBaseFile.load(from: baseURL) {
            self.base = loaded
        } else {
            self.base = SyncBase()
        }
    }

    // MARK: - Halting

    /// Refuses to run again until a human clears it.
    func halt(_ reason: SyncState.HaltReason, detail: String) {
        transition(to: .halted(reason, detail: detail))
    }

    /// The only way out of a halt. Named for what it demands rather than what it does,
    /// because "resume" would read as something safe to call automatically.
    func clearHaltAfterUserReview() {
        guard state.isHalted else { return }
        consecutiveFailures = 0
        transition(to: .idle(lastSync: nil))
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
        } catch let failure as SyncTransportFailure {
            handle(failure)
        } catch let failure as SyncEngineFailure {
            transition(to: .halted(failure.reason, detail: failure.detail))
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
        // PUSH FIRST, deliberately.
        //
        // Fetching first and applying would rewrite local records before this device's
        // own changes have left it — and if the process dies between the two, those
        // changes are gone with nothing to recover them from. Pushing first means the
        // worst case is a duplicate round, not a lost edit.
        let current = try library.currentEnvelopes()
        let pending = base.pendingChanges(from: current)

        if !pending.isEmpty {
            guard transport.supportsPush else { throw SyncTransportFailure.pushUnsupported }
            let records = try pending.map { try WireCodec.seal($0, using: sealer) }
            let submission = try await transport.submit(records, at: base.cursor)

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
            try persistBase()
        }

        // FETCH, possibly paged.
        var cursor = base.cursor
        var incoming: [SyncEnvelope] = []
        var isFullResync = false

        while true {
            let fetch = try await transport.fetchChanges(since: cursor)
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
            base.cursor = cursor
            try persistBase()
            return nil
        }

        // Three-way merge against the base BEFORE the guard, so the guard judges what
        // would actually be applied rather than what arrived. A remote tombstone that
        // loses to a local edit is not a deletion, and counting it as one would trip the
        // breaker on a library that was never in danger.
        let localNow = try library.currentEnvelopes()
        var merged: [SyncEnvelope] = []
        for envelope in incoming {
            guard let resolved = SyncMerge.mergeEnvelope(
                base: base.envelope(envelope.id),
                local: localNow[envelope.id],
                remote: envelope
            ) else { continue }
            merged.append(resolved)
        }

        // The circuit breaker.
        let live = library.liveIDs()
        let decision = DeletionGuard.evaluate(live: live, incoming: merged)
        if case .refuse(let refusal) = decision {
            throw SyncEngineFailure(reason: .massDeletion, detail: refusal.description)
        }

        let outcome = try library.applyRemote(merged)
        let deferred = Set(outcome.deferredIDs)

        // The base records what the BACKEND said, not what we merged to. Recording the
        // merged value would make the next diff believe the backend has already seen our
        // side of the merge, and our half would never be pushed.
        //
        // A deferred record is recorded neither in the base nor by advancing the cursor.
        // Both halves matter: leaving it out of the base keeps the local library from
        // looking like it deleted a record it never received, and holding the cursor is
        // what makes the backend offer it again. Everything that *did* apply is recorded
        // normally, so the re-fetch re-applies it as a no-op rather than as churn.
        for envelope in incoming where !deferred.contains(envelope.id) {
            base.record(envelope)
        }
        if deferred.isEmpty {
            base.cursor = cursor
        }
        try persistBase()
        return deferred.isEmpty ? nil : outcome.deferredIDs.count
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
            transition(to: .halted(.backendRefused, detail: detail))
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
