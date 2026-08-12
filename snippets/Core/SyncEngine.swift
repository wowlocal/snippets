import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

nonisolated extension VaultDocument {
    /// Sync-aware validation wrapper around the Foundation-only receipt storage. Keep
    /// this out of VaultDocument.swift: that file also builds in snippets-cli, whose
    /// safety boundary deliberately excludes SyncEnvelope and CloudKit/sync code.
    mutating func recordLocalConflictInstallReceipts(
        for evidence: [SyncEnvelope]
    ) throws {
        var additions: [UUID: String] = [:]
        for envelope in evidence {
            guard !envelope.deleted,
                  envelope.secure,
                  SyncMerge.hasValidConflictCopyIdentity(envelope),
                  additions.updateValue(
                    try envelope.envelopeHash(), forKey: envelope.id) == nil
            else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
        }
        do {
            try recordLocalConflictInstallReceiptHashes(additions)
        } catch {
            throw SyncMerge.EnvelopeFailure.malformedContentConflict
        }
    }
}

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
    /// Ids whose primary representation changed after the engine captured its merge
    /// input. They need a fresh three-way merge, not a vault-key wait or a sticky halt.
    var retryIDs: [UUID]
    /// Exact authenticated C0 envelopes derived from secure carrier snapshots. These
    /// bytes are journal evidence, never fetched/backend confirmation. The engine must
    /// fsync them before it can advance base or cursor past the carrier batch.
    var conflictCopyEvidence: [SyncEnvelope]

    init(
        changedIDs: [UUID] = [], deferredIDs: [UUID] = [],
        incompatibleVaultIDs: [UUID] = [], retryIDs: [UUID] = [],
        conflictCopyEvidence: [SyncEnvelope] = []
    ) {
        self.changedIDs = changedIDs
        self.deferredIDs = deferredIDs
        self.incompatibleVaultIDs = incompatibleVaultIDs
        self.retryIDs = retryIDs
        self.conflictCopyEvidence = conflictCopyEvidence
    }
}

/// Exact primary-storage comparison token captured alongside the envelope projection.
/// Derived sync metadata is deliberately absent: a stale sidecar must never authorize
/// overwriting a newer snippet/vault write which landed during a network await.
nonisolated enum SyncPrimaryState: Equatable {
    case absent
    case plain(Snippet)
    case secure(record: VaultRecord, vaultKID: String, vaultSalt: String)
    case duplicate(
        snippet: Snippet,
        record: VaultRecord,
        vaultKID: String,
        vaultSalt: String)
    /// Value-only test libraries do not expose primary files. Their default protocol
    /// implementation uses this token and retains their existing apply semantics.
    case projected(SyncEnvelope)
}

nonisolated struct SyncLibrarySnapshot: Equatable {
    var envelopes: [UUID: SyncEnvelope]
    var primaryStates: [UUID: SyncPrimaryState]
    /// Device-local, primary-atomic receipt keyed by deterministic copy id. The value
    /// is the exact immutable C0 envelope hash which reached this device's vault file.
    /// Value-only libraries leave this empty.
    var installedConflictPrerequisiteHashes: [UUID: String] = [:]

    func primaryState(for id: UUID) -> SyncPrimaryState {
        primaryStates[id] ?? .absent
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
    /// Whether this boundary can turn an authenticated secure carrier into a separately
    /// sealed deterministic vault record. Value-only Core fakes cannot do that safely;
    /// the production bridge can and opts in explicitly.
    var supportsSecureConflictMaterialization: Bool { get }
    /// Everything syncable, plaintext and secure, as envelopes ready to seal.
    ///
    /// The engine passes its live ancestor rather than asking the library to re-read
    /// `base.json`. A failed derived-state write must not make the projection forget
    /// secure records the running engine already knows the backend accepted.
    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope]
    /// Captures projection and exact primary comparison tokens as one logical read.
    func currentSnapshot(agreedBase: SyncBase) throws -> SyncLibrarySnapshot
    /// Partitions records before the deletion guard. A deletion the library cannot file
    /// must not count toward a mass-deletion halt, and must not be passed to `applyRemote`.
    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification
    /// Makes every secure losing snapshot durable in primary storage before a merge
    /// can replace its source representation. A locked vault may defer the affected
    /// records; it may never apply them and hope a best-effort sidecar survives.
    func prepareRemote(_ envelopes: [SyncEnvelope]) throws -> RemoteClassification
    /// Pure/key-aware preparation of immutable carrier-derived C0 bytes. The caller
    /// persists these in the dependency journal before any primary mutation.
    func prepareConflictCopyEvidence(
        from envelopes: [SyncEnvelope]
    ) throws -> [SyncEnvelope]
    /// Applies merged remote state, reporting what changed and what had to wait.
    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome
    /// Applies only if every affected primary record still equals the merge input.
    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome
    /// Applies dependency-held local copy intent after implicit carrier materialization,
    /// without treating that local value as fetched or backend-confirmed.
    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope]
    ) throws -> ApplyOutcome
    /// Removes only exact, already-preserved v1 carrier members from the latest primary
    /// representation. Implementations must preserve every user field and unrelated
    /// extension, and report a no-op when the expected value no longer matches.
    func resolveConflictCarriers(
        _ resolutions: [SyncJournal.ConflictCarrierResolution]
    ) throws -> ApplyOutcome
    /// Recovers dependency-owned secure copies from durable carrier snapshots without
    /// applying or releasing their source. Used before an account/checkpoint reset,
    /// when the old backend inbox may no longer be available to replay materialisation.
    func materializeConflictPrerequisites(
        from sources: [SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome
    /// Prunes device-local primary-install receipts after (and only after) the journal
    /// retaining exactly these dependency ids has been made durable.
    func retainConflictPrerequisiteInstallReceipts(for ids: Set<UUID>) throws
    /// Live ids, for the deletion guard.
    func liveIDs() -> Set<UUID>
}

@MainActor extension SyncLibraryAccess {
    var supportsSecureConflictMaterialization: Bool { false }
    func prepareRemote(_ envelopes: [SyncEnvelope]) throws -> RemoteClassification {
        classifyRemote(envelopes)
    }

    func prepareConflictCopyEvidence(
        from envelopes: [SyncEnvelope]
    ) throws -> [SyncEnvelope] { [] }

    func currentSnapshot(agreedBase: SyncBase) throws -> SyncLibrarySnapshot {
        let envelopes = try currentEnvelopes(agreedBase: agreedBase)
        return SyncLibrarySnapshot(
            envelopes: envelopes,
            primaryStates: envelopes.mapValues(SyncPrimaryState.projected),
            installedConflictPrerequisiteHashes: [:])
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState]
    ) throws -> ApplyOutcome {
        try applyRemote(envelopes)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope]
    ) throws -> ApplyOutcome {
        // Value-only libraries do not materialize implicit secure copies, so there is
        // no protocol-created primary value for a held intent to supersede here.
        try applyRemote(envelopes, expectedPrimary: expectedPrimary)
    }

    func applyRemote(
        _ envelopes: [SyncEnvelope],
        expectedPrimary: [UUID: SyncPrimaryState],
        heldConflictCopyIntents: [UUID: SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope]
    ) throws -> ApplyOutcome {
        try applyRemote(
            envelopes,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents)
    }

    func resolveConflictCarriers(
        _ resolutions: [SyncJournal.ConflictCarrierResolution]
    ) throws -> ApplyOutcome {
        // Value-only test libraries do not have a frozen primary representation. Apply
        // the already-conditional latest envelope through their ordinary boundary.
        try applyRemote(resolutions.map(\.resolvedEnvelope))
    }

    func materializeConflictPrerequisites(
        from sources: [SyncEnvelope],
        preparedConflictCopyEvidence: [SyncEnvelope] = [],
        heldConflictCopyIntents: [UUID: SyncEnvelope] = [:],
        expectedPrimary: [UUID: SyncPrimaryState] = [:]
    ) throws -> ApplyOutcome {
        // Value-only libraries already hold independent copy envelopes or cannot safely
        // interpret a secure carrier. Production opts in and overrides this boundary.
        ApplyOutcome(deferredIDs: sources.map(\.id))
    }

    func retainConflictPrerequisiteInstallReceipts(for ids: Set<UUID>) throws {}
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
    private let journalURL: URL
    private let stateURL: URL
    private let lockURL: URL
    private let temporaryDirectory: URL
    private let stateLockTimeout: TimeInterval
    private let device: String
    private var base: SyncBase
    private var journal: SyncJournal
    /// Once journal.json exists, base.json must also exist: the engine establishes them
    /// in that order before first transport. Losing confirmed state afterwards makes
    /// local absence ambiguous and therefore requires repair/review, not a blind reset.
    private var baseRequiresReload = false
    /// A corrupt/future journal must be repaired or deliberately removed before even an
    /// explicit Resume can proceed. Otherwise Resume would overwrite the only remaining
    /// evidence of an ambiguous server commit with a fresh empty journal.
    private var journalRequiresReload = false
    /// One process-local authorization granted by clearing a recoverable transport
    /// halt. It is consumed before the journal-first reset begins. A crash therefore
    /// loses the authorization and asks for review again rather than guessing that the
    /// replacement completed.
    private enum ApprovedTransportReset { case account, checkpoint }
    private var approvedTransportReset: ApprovedTransportReset?
    /// A reviewed checkpoint reset may fail transiently after its one-shot authority is
    /// consumed. Keep the public result retryable for that attempt, but require a new
    /// Review before any later data-plane call (and persist the halt for a restart).
    private var checkpointResetRequiresReview = false
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
        journalURL: URL? = nil,
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
        self.journalURL = journalURL ?? baseURL.deletingLastPathComponent()
            .appendingPathComponent("journal.json", isDirectory: false)
        self.stateURL = stateURL
        self.lockURL = lockURL
        self.temporaryDirectory = temporaryDirectory
        self.stateLockTimeout = stateLockTimeout
        let baseOutcome = SyncBaseFile.load(from: baseURL)
        let baseWasMissing: Bool
        switch baseOutcome {
        case .loaded(let loaded):
            self.base = loaded
            baseWasMissing = false
        case .missing:
            self.base = SyncBase()
            baseWasMissing = true
        case .tooNew(let version):
            self.base = SyncBase()
            baseWasMissing = false
            self.baseRequiresReload = true
            self.state = .halted(
                .schemaTooNew,
                detail: "Sync/base.json is version \(version); this build understands "
                    + "\(SyncBase.currentSchemaVersion) and will not sync over it.")
        case .unreadable:
            self.base = SyncBase()
            baseWasMissing = false
            self.baseRequiresReload = true
            self.state = .halted(
                .localLibraryQuarantined,
                detail: "the confirmed sync base could not be read; sync stopped "
                    + "instead of treating prior records as unknown")
        }

        let journalOutcome = SyncJournalFile.load(from: self.journalURL)
        let journalWasMissing: Bool
        switch journalOutcome {
        case .missing(let empty):
            self.journal = empty
            journalWasMissing = true
        case .loaded(let loaded):
            self.journal = loaded
            journalWasMissing = false
        case .tooNew(let version):
            self.journal = SyncJournal()
            journalWasMissing = false
            self.journalRequiresReload = true
            self.state = .halted(
                .schemaTooNew,
                detail: "Sync/journal.json is version \(version); this build understands "
                    + "\(SyncJournal.currentSchemaVersion) and will not sync over it.")
        case .unreadable(let detail):
            self.journal = SyncJournal()
            journalWasMissing = false
            self.journalRequiresReload = true
            self.state = .halted(
                .localLibraryQuarantined,
                detail: "\(detail); sync stopped because pending local changes cannot "
                    + "be reconstructed safely")
        }

        if baseWasMissing, !journalWasMissing {
            self.baseRequiresReload = true
            // Preserve a more specific future/corrupt-journal halt if one is already
            // active; otherwise explain the broken base-before-journal invariant.
            if !self.journalRequiresReload {
                self.state = .halted(
                    .localLibraryQuarantined,
                    detail: "Sync/base.json is missing even though journal.json proves "
                        + "sync was already initialized; sync stopped instead of "
                        + "guessing whether local absences are deletions")
            }
        }
        if !baseWasMissing, journalWasMissing, self.base.journalEstablished {
            self.journalRequiresReload = true
            self.state = .halted(
                .localLibraryQuarantined,
                detail: "Sync/journal.json is missing even though base.json records "
                    + "that the durable journal was established; restore it or "
                    + "deliberately remove both protocol files before resuming")
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
        guard reason.isUserRecoverable else { return }
        guard reloadProtocolPairAfterReview() else { return }

        switch updatePersistedHalt(nil, expecting: durableHalt) {
        case .written:
            durableHalt = nil
            consecutiveFailures = 0
            approvedTransportReset = switch reason {
            case .accountChanged: .account
            case .checkpointUnreadable: .checkpoint
            default: nil
            }
            transition(to: .idle(lastSync: nil))
        case .superseded(let newer):
            approvedTransportReset = nil
            // A peer stopped for a different reason after this pane was drawn. The
            // user's review covered the old stop, not this one; adopt it and ask again.
            durableHalt = newer
            transition(to: .halted(newer.reason, detail: newer.detail))
        case .tooNew(let version):
            approvedTransportReset = nil
            durableHalt = nil
            transition(to: .halted(
                .schemaTooNew,
                detail: "Sync/state.json is version \(version); update Snippets before "
                    + "sync can resume."))
        case .failed:
            approvedTransportReset = nil
            transition(to: .halted(
                reason,
                detail: detail + " The reviewed stop could not be cleared from disk; "
                    + "sync remains stopped."))
        }
    }

    /// Re-read both protocol files as one invariant before clearing any halt.
    ///
    /// Repairing one side can change what the other side means (most importantly, a
    /// repaired base may carry `journalEstablished = true`). Conditional reloads let a
    /// user replace an unreadable base with that shape while leaving journal missing,
    /// then Resume would create an empty journal over evidence of lost intent. Reading
    /// the pair every time also catches damage that happened after engine initialization.
    private func reloadProtocolPairAfterReview() -> Bool {
        let baseOutcome = SyncBaseFile.load(from: baseURL)
        let journalOutcome = SyncJournalFile.load(from: journalURL)

        switch baseOutcome {
        case .tooNew(let version):
            baseRequiresReload = true
            transition(to: .halted(
                .schemaTooNew,
                detail: "Sync/base.json is version \(version); update Snippets before "
                    + "sync can resume."))
            return false
        case .unreadable:
            baseRequiresReload = true
            transition(to: .halted(
                .localLibraryQuarantined,
                detail: "the confirmed sync base is unreadable; repair it or "
                    + "deliberately remove both protocol files before sync can resume"))
            return false
        case .missing:
            switch journalOutcome {
            case .missing:
                // Deliberately removing both files after review is the explicit reset.
                base = SyncBase()
                journal = SyncJournal()
                baseRequiresReload = false
                journalRequiresReload = false
                return true
            case .tooNew(let version):
                journalRequiresReload = true
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/journal.json is version \(version); update Snippets "
                        + "before sync can resume."))
                return false
            case .loaded, .unreadable:
                baseRequiresReload = true
                transition(to: .halted(
                    .localLibraryQuarantined,
                    detail: "Sync/base.json is missing while journal.json still exists; "
                        + "restore the base or deliberately remove both protocol files "
                        + "before sync can resume"))
                return false
            }
        case .loaded(let repairedBase):
            switch journalOutcome {
            case .loaded(let repairedJournal):
                base = repairedBase
                journal = repairedJournal
                baseRequiresReload = false
                journalRequiresReload = false
                return true
            case .missing(let emptyJournal):
                guard !repairedBase.journalEstablished else {
                    journalRequiresReload = true
                    transition(to: .halted(
                        .localLibraryQuarantined,
                        detail: "Sync/journal.json is missing while base.json proves it "
                            + "was established; restore it or deliberately remove both "
                            + "protocol files before sync can resume"))
                    return false
                }
                // Legacy base from before the journal shipped. It will receive the
                // additive established marker before the next network operation.
                base = repairedBase
                journal = emptyJournal
                baseRequiresReload = false
                journalRequiresReload = false
                return true
            case .tooNew(let version):
                journalRequiresReload = true
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/journal.json is version \(version); update Snippets "
                        + "before sync can resume."))
                return false
            case .unreadable(let journalDetail):
                journalRequiresReload = true
                transition(to: .halted(
                    .localLibraryQuarantined,
                    detail: "\(journalDetail); repair it or deliberately remove both "
                        + "protocol files before sync can resume"))
                return false
            }
        }
    }

    // MARK: - One round

    private struct RoundOutcome {
        var uploaded = 0
        var downloaded = 0
        var merged = 0
        var deferred = 0
        var quarantined = 0
        var fullResync = false
        var retryNeeded = false
    }

    @discardableResult
    func sync() async -> State {
        guard !state.isHalted else { return state }
        if case .syncing = state { return state }
        if case .offline(let retryAfter) = state, now() < retryAfter { return state }

        let startedAtUptime = ProcessInfo.processInfo.systemUptime
        var diagnosticRound = DiagnosticSyncRound(durationMilliseconds: 0)
        defer {
            diagnosticRound.durationMilliseconds = Int64(max(
                0,
                (ProcessInfo.processInfo.systemUptime - startedAtUptime) * 1_000))
            Diagnostics.record(.syncRound(diagnosticRound))
        }
        transition(to: .syncing)
        do {
            var outcome = try await performRound()
            // A primary CAS miss means a writer committed after our merge snapshot.
            // Re-read and re-merge once immediately so convergence does not depend on
            // an observer notification surviving/coalescing during this very round.
            // Bound this to one replay: a continuously active writer must not spin the
            // main actor, and the normal scheduler will retry the remaining race.
            if outcome.retryNeeded {
                let retry = try await performRound()
                outcome.uploaded += retry.uploaded
                outcome.downloaded += retry.downloaded
                outcome.merged += retry.merged
                // Deferred describes the final retryable state, not work accumulated
                // across attempts. A key/CAS condition healed by replay must not leave
                // the UI stuck in waitingForVault.
                outcome.deferred = retry.deferred
                outcome.quarantined += retry.quarantined
                outcome.fullResync = outcome.fullResync || retry.fullResync
                outcome.retryNeeded = retry.retryNeeded
            }
            diagnosticRound.uploaded = outcome.uploaded
            diagnosticRound.downloaded = outcome.downloaded
            diagnosticRound.merged = outcome.merged
            diagnosticRound.deferred = outcome.deferred
            diagnosticRound.quarantined = outcome.quarantined
            diagnosticRound.fullResync = outcome.fullResync
            consecutiveFailures = 0
            if outcome.deferred > 0 {
                transition(to: .waitingForVault(
                    "\(outcome.deferred) secure snippet(s) from another device are waiting for a key "
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
    private func performRound() async throws -> RoundOutcome {
        try Task.checkCancellation()
        var round = RoundOutcome()
        var offeredThisRound: [UUID: SyncEnvelope] = [:]
        var rejectedThisRound = Set<UUID>()
        var authoritativeConflictRecords: [WireRecord] = []
        var unresolvedConflictIDs = Set<UUID>()
        // A permanent per-record rejection is surfaced only after an authoritative
        // fetch has resolved the durable offer. Throwing immediately would pin that
        // frozen offer forever and prevent a later local fix from being submitted.
        var terminalEngineFailureAfterFetch: SyncEngineFailure?

        // ACCOUNT SCOPE FIRST, before reading local user data and before either network
        // data-plane leg. A cursor and CKRecord system fields are credentials issued by
        // one private database; using them under another Apple ID is never a migration.
        let roundAccountIdentity: SyncAccountIdentity?
        do {
            let preflight = try await transport.preflightScope()
            roundAccountIdentity = preflight.identity
            try Task.checkCancellation()
            switch preflight.checkpointIssue {
            case .accountChanged where approvedTransportReset != .account:
                throw SyncTransportFailure.accountChanged
            case .unreadable where approvedTransportReset != .checkpoint:
                throw SyncTransportFailure.checkpointUnreadable(
                    detail: "the authenticated local scheduler checkpoint is unreadable")
            case nil, .accountChanged, .unreadable:
                break
            }
            try await reconcileAccountIdentity(roundAccountIdentity)
        } catch {
            // Review authorizes exactly this immediate account-resolution attempt. If
            // iCloud is unavailable (or the task is cancelled) before a scope can be
            // fixed, carrying that permission into a later round could silently apply
            // it to an entirely different account.
            approvedTransportReset = nil
            throw error
        }

        // Local maintenance (wire-key convergence or secure-vault forget) has already
        // staged every surviving value and removed the scheduler cursor. Record-level
        // CAS generations survive a wire-key change because CloudKit change tags are
        // independent of payload encryption. Reset the transport-private scheduler
        // before any offer/fetch can observe its old encrypted inbox.
        if base.requiresTransportFullResync {
            // Maintenance can crash after scrubbing projection/base but before the old
            // carrier dependency is rewritten. Recover its deterministic copy from the
            // durable journal before replacing the scheduler that owns the replayable
            // inbox. This is the same fence used by reviewed resets, but an ordinary
            // locked-vault state waits rather than creating a sticky safety halt.
            let recovery = try recoverConflictPrerequisitesBeforeSchedulerReset()
            guard recovery.deferredIDs.isEmpty,
                  recovery.incompatibleVaultIDs.isEmpty,
                  recovery.retryIDs.isEmpty else {
                round.deferred += recovery.deferredIDs.count
                round.retryNeeded = !recovery.retryIDs.isEmpty
                if !recovery.incompatibleVaultIDs.isEmpty {
                    throw SyncEngineFailure(
                        reason: .vaultUnreadable,
                        detail: "a pending conflict prerequisite belongs to a different "
                            + "secure vault; the local scheduler was not reset")
                }
                return round
            }
            try await transport.resetForLocalFullResync()
            var resetComplete = base
            resetComplete.requiresTransportFullResync = false
            try persistBase(resetComplete)
        }

        // Establish the base-before-journal invariant before deriving or offering any
        // change. A later restart can therefore distinguish a truly fresh install
        // (both missing) from lost confirmation (journal exists, base missing).
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try persistBase(base)
        }
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            try persistJournal(journal)
        }
        if !base.journalEstablished || base.schemaVersion < SyncBase.currentSchemaVersion {
            // This marker closes the one-time migration ambiguity: old installations
            // legitimately have base.json without journal.json, but after this durable
            // write a missing journal is always a safety stop. It is set only after the
            // journal exists and before anything below can contact the backend.
            var established = base
            established.schemaVersion = SyncBase.currentSchemaVersion
            established.journalEstablished = true
            try persistBase(established)
        }

        // A previous round may have durably frozen random-nonce C0 evidence and then
        // crashed before the primary transaction installed it. Repair that boundary
        // before generic reconciliation can interpret primary absence as user intent,
        // and before push-first ordering can publish a copy which this device does not
        // itself retain. Reset paths call the same helper before discarding a scheduler.
        let preparedRecovery = try recoverFrozenConflictPrerequisitesInPrimary()
        guard preparedRecovery.deferredIDs.isEmpty,
              preparedRecovery.incompatibleVaultIDs.isEmpty else {
            round.deferred += preparedRecovery.deferredIDs.count
            if !preparedRecovery.incompatibleVaultIDs.isEmpty {
                throw SyncEngineFailure(
                    reason: .vaultUnreadable,
                    detail: "a frozen conflict prerequisite belongs to a different vault")
            }
            return round
        }

        // PUSH FIRST, deliberately.
        //
        // Fetching first and applying would rewrite local records before this device's
        // own changes have left it — and if the process dies between the two, those
        // changes are gone with nothing to recover them from. Pushing first means the
        // worst case is a duplicate round, not a lost edit.
        let current = try library.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        var reconciled = journal
        do {
            // A prior conditional source release may have conflicted with an
            // independently written, byte-identical generation which was persisted to
            // base before the process died. Retrying the stale CAS forever cannot make
            // progress; rebase the same immutable release bytes to that authoritative
            // generation, while keeping the dependency edge until a fresh acceptance.
            reconciled.rebaseIdenticalSourceOffers(confirmed: base)
            reconciled.recoverAcceptedPrerequisiteOffers(confirmed: base)
            try reconciled.reconcileDependencies(
                current: current,
                confirmed: base,
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a deterministic conflict-copy identifier is occupied by "
                    + "unrelated or malformed data; sync stopped without overwriting it")
        }
        reconciled.reconcile(
            current: current, confirmed: base, deviceID: device, now: now())
        try persistJournal(reconciled)

        let resolutions = journal.carrierResolutions(current: current, confirmed: base)
        if !resolutions.isEmpty {
            // Publish the exact cleanup intent before touching primary storage. A crash
            // before/inside the conditional bridge operation is conservative: the next
            // primary reread sees the still-present member and reopens the requirement.
            // Publishing afterwards leaves a crash window in which the stale journal is
            // the only projection owner and resurrects an already-removed plain carrier.
            var cleaningJournal = journal
            try cleaningJournal.beginCarrierResolutions(resolutions)
            try persistJournal(cleaningJournal)
            let resolutionOutcome = try library.resolveConflictCarriers(resolutions)
            guard resolutionOutcome.deferredIDs.isEmpty,
                  resolutionOutcome.incompatibleVaultIDs.isEmpty else {
                round.deferred += resolutionOutcome.deferredIDs.count
                return round
            }
            let resolvedCurrent = try library.currentEnvelopes(
                agreedBase: journal.projectionKnowledge(over: base))
            var resolvedJournal = journal
            do {
                try resolvedJournal.reconcileDependencies(
                    current: resolvedCurrent,
                    confirmed: base,
                    discoverSecureCarriers: library.supportsSecureConflictMaterialization)
            } catch {
                throw SyncEngineFailure(
                    reason: .localLibraryQuarantined,
                    detail: "resolved conflict dependency state no longer matches its "
                        + "primary records; sync stopped without overwriting them")
            }
            resolvedJournal.reconcile(
                current: resolvedCurrent,
                confirmed: base,
                deviceID: device,
                now: now())
            try persistJournal(resolvedJournal)
        }
        let pending = journal.pending(confirmed: base)

        if !pending.isEmpty {
            guard transport.supportsPush else { throw SyncTransportFailure.pushUnsupported }

            // Publish the exact offered snapshot durably before any operation that can
            // reach the backend. If sealing, cancellation, transport, or this process
            // fails afterwards, restart retries these bytes rather than guessing which
            // of a newer edit and our own server echo is authoritative.
            var marked = journal
            marked.markOffered(pending, confirmed: base)
            try persistJournal(marked)
            offeredThisRound = Dictionary(
                pending.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            let records = try pending.map { envelope in
                var record = try WireCodec.seal(envelope, using: sealer)
                // The generation belongs to this immutable offer, not merely this id.
                // A later fetched base may already contain B/V2 while crash replay still
                // owes old offer A; attaching V2 to A would authorize it to overwrite B.
                guard let offered = journal.offeredSnapshot(for: envelope) else {
                    throw SyncEngineFailure(
                        reason: .localLibraryQuarantined,
                        detail: "pending sync state lost its compare-and-swap snapshot")
                }
                record.recordVersion = offered.recordVersion
                return record
            }
            try Task.checkCancellation()
            let submission = try await transport.submit(records, at: base.cursor)
            try Task.checkCancellation()
            guard submission.accountIdentity == roundAccountIdentity else {
                throw SyncEngineFailure(
                    reason: .accountChanged,
                    detail: "the iCloud account changed while pending snippets were "
                        + "being submitted; no acknowledgement was trusted")
            }

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
            let pendingByID = offeredThisRound
            var nextBase = base
            var acceptedIDs = Set<UUID>()
            var terminalTransportFailure: SyncTransportFailure?

            for result in submission.results {
                switch result.outcome {
                case .accepted(_, let recordVersion):
                    // Only now is it agreed. Recording it before the backend accepted
                    // would make the next diff skip it, and the record would never be
                    // pushed again. An outcome for an id we did not submit is ignored
                    // rather than trusted.
                    guard let accepted = pendingByID[result.id] else { continue }
                    nextBase.recordConfirmed(
                        accepted,
                        recordVersion: recordVersion)
                    if acceptedIDs.insert(result.id).inserted { round.uploaded += 1 }
                case .rejected(.authenticationRequired(let detail)):
                    // Not a halt. An expired token is an ordinary, recoverable state and
                    // halting for it would put a scary sticky error in front of someone
                    // who just needs to sign in again.
                    guard pendingByID[result.id] != nil else { continue }
                    rejectedThisRound.insert(result.id)
                    terminalTransportFailure = terminalTransportFailure
                        ?? .rejected(.authenticationRequired(detail: detail))
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
                    guard pendingByID[result.id] != nil else { continue }
                    rejectedThisRound.insert(result.id)
                    terminalEngineFailureAfterFetch = terminalEngineFailureAfterFetch
                        ?? SyncEngineFailure(reason: .backendRefused, detail: detail)
                case .rejected(.conflict(let remote)):
                    guard pendingByID[result.id] != nil else { continue }
                    rejectedThisRound.insert(result.id)
                    if let remote, remote.id == result.id {
                        // This record is newer than (or is the accepted echo of) our
                        // offered generation. Process it before the subsequent change
                        // feed: a legacy cursor may already be past it and legitimately
                        // return an empty delta.
                        authoritativeConflictRecords.append(remote)
                    } else {
                        // A conflict without the server value disproves acceptance of
                        // this attempt but does not prove which earlier ambiguous offer
                        // is remote. Never clear it on the strength of an empty delta.
                        unresolvedConflictIDs.insert(result.id)
                    }
                case .rejected(let rejection):
                    guard pendingByID[result.id] != nil else { continue }
                    rejectedThisRound.insert(result.id)
                    guard rejection.isRetryable else {
                        // Kept for a non-retryable kind added later, so a new case
                        // cannot silently become a record that is dropped in silence.
                        terminalEngineFailureAfterFetch = terminalEngineFailureAfterFetch
                            ?? SyncEngineFailure(
                                reason: .backendRefused, detail: "\(rejection)")
                        continue
                    }
                    // Retryable: leave it offered until an authoritative fetch either
                    // confirms the same bytes or proves a different server value. A
                    // rejection of this attempt cannot disprove an earlier attempt whose
                    // acknowledgement was lost.
                }
            }

            if !acceptedIDs.isEmpty {
                // Ordering is load-bearing: confirmation reaches durable base.json
                // before the journal is allowed to forget the offered snapshot. A
                // dependency-owned source is stronger: only this submit response is
                // an acceptance receipt. A byte-identical value learned by fetch (even
                // with a newer generation) must never close its copy-before-source edge.
                try persistBase(nextBase)
                var acknowledged = journal
                acknowledged.acknowledge(Array(acceptedIDs), confirmed: base)
                try persistJournal(acknowledged)

                // Re-read primary storage after the awaited submit. If a carrier was
                // restored or another conflict enlarged the graph meanwhile, this
                // receipt belongs to the old epoch and reconcile keeps/reopens it. If
                // this step crashes, no receipt is persisted: restart retries the exact
                // source CAS conservatively, which is safe and eventually idempotent.
                let afterAcceptance = try library.currentEnvelopes(
                    agreedBase: journal.projectionKnowledge(over: base))
                var finalized = journal
                do {
                    try finalized.reconcileDependencies(
                        current: afterAcceptance,
                        confirmed: base,
                        acceptedSourceIDs: acceptedIDs,
                        discoverSecureCarriers: library.supportsSecureConflictMaterialization)
                } catch {
                    throw SyncEngineFailure(
                        reason: .localLibraryQuarantined,
                        detail: "accepted conflict dependency state no longer matches "
                            + "its primary records; sync stopped without releasing it")
                }
                finalized.reconcile(
                    current: afterAcceptance,
                    confirmed: base,
                    deviceID: device,
                    now: now())
                try persistJournal(finalized)
            }

            // Preserve an accepted prefix before surfacing a terminal result from a
            // different record in the same batch.
            if let failure = terminalTransportFailure { throw failure }

            // The submission's cursor is deliberately NOT adopted as the fetch position.
            //
            // A cursor is a place in the backend's change feed. The one returned by a
            // submit points *after* our own writes — which is also after everything the
            // backend already held and we had not fetched yet. Adopting it silently skips
            // all of that: seed a record remotely, push a local one, and the remote record
            // is never seen. Only a fetch may advance the fetch position.
        }

        // FETCH, possibly paged.
        var cursor = base.cursor
        var cursorKind = base.cursorKind
        struct OpenedRemote {
            var envelope: SyncEnvelope
            var recordVersion: SyncRecordVersion
        }
        var rawIncoming = authoritativeConflictRecords.map { (record: $0, fromConflict: true) }
        var isFullResync = false
        var opaqueFetchedIDs = Set<UUID>()
        var fetchedAuthoritativeIDs = Set<UUID>()
        round.downloaded += authoritativeConflictRecords.count

        while true {
            try Task.checkCancellation()
            let fetch = try await transport.fetchChanges(since: cursor)
            try Task.checkCancellation()
            guard fetch.accountIdentity == roundAccountIdentity else {
                throw SyncEngineFailure(
                    reason: .accountChanged,
                    detail: "the iCloud account changed while remote snippets were "
                        + "being fetched; no records or cursor were trusted")
            }
            isFullResync = isFullResync || fetch.isFullResync
            round.downloaded += fetch.records.count
            rawIncoming.append(contentsOf: fetch.records.map {
                (record: $0, fromConflict: false)
            })
            cursor = fetch.cursor
            cursorKind = fetch.cursorKind
            guard fetch.hasMore else { break }
        }

        // The transport inbox is ordered and may retain several generations of one
        // record. Only the last decodable occurrence is authoritative for Core. If the
        // last occurrence is opaque, no earlier plaintext generation may slip through.
        var latestIncomingByID: [UUID: OpenedRemote] = [:]
        var latestIncomingOrder: [UUID: Int] = [:]
        var opaqueLatestIDs = Set<UUID>()
        for (position, item) in rawIncoming.enumerated() {
            latestIncomingOrder[item.record.id] = position
            guard let recordVersion = item.record.recordVersion else {
                // A fetched value without the generation that guards its replacement is
                // incomplete protocol data. Hold the cursor/offer exactly like an
                // undecryptable blob; accepting the envelope alone would make the next
                // local edit a conditional create and lose the known ancestry.
                quarantine(item.record)
                opaqueFetchedIDs.insert(item.record.id)
                opaqueLatestIDs.insert(item.record.id)
                latestIncomingByID[item.record.id] = nil
                if item.fromConflict { unresolvedConflictIDs.insert(item.record.id) }
                round.quarantined += 1
                continue
            }
            do {
                let envelope = try WireCodec.open(item.record, using: sealer)
                latestIncomingByID[envelope.id] = OpenedRemote(
                    envelope: envelope,
                    recordVersion: recordVersion)
                opaqueLatestIDs.remove(envelope.id)
                opaqueFetchedIDs.remove(envelope.id)
                if !item.fromConflict {
                    fetchedAuthoritativeIDs.insert(envelope.id)
                }
            } catch {
                // Undecryptable. Never applied, never dropped silently — a record we
                // cannot read is either a key we do not have or a bug, and both need
                // to be visible rather than inferred from missing data later.
                quarantine(item.record)
                opaqueFetchedIDs.insert(item.record.id)
                opaqueLatestIDs.insert(item.record.id)
                latestIncomingByID[item.record.id] = nil
                if item.fromConflict { unresolvedConflictIDs.insert(item.record.id) }
                round.quarantined += 1
            }
        }
        let incoming = latestIncomingByID.values.sorted {
            (latestIncomingOrder[$0.envelope.id] ?? 0)
                < (latestIncomingOrder[$1.envelope.id] ?? 0)
        }
        // A newer undecodable generation supersedes any earlier decoded value of the
        // same id. Holding the cursor makes it retryable without applying stale data.
        opaqueFetchedIDs.formUnion(opaqueLatestIDs)

        // Capture edits — especially an absence that means delete — which happened
        // while submit/fetch was suspended. This write precedes remote apply so a crash
        // cannot let the apply erase the only remaining evidence of local intent.
        let localSnapshot = try library.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: base))
        let projectedLocal = localSnapshot.envelopes
        var beforeApply = journal
        do {
            try beforeApply.reconcileDependencies(
                current: projectedLocal,
                confirmed: base,
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a dependency-owned conflict copy changed identity while sync "
                    + "was waiting for iCloud; no remote value was applied")
        }
        beforeApply.reconcile(
            current: projectedLocal, confirmed: base, deviceID: device, now: now())
        try persistJournal(beforeApply)

        guard !incoming.isEmpty || isFullResync else {
            try Task.checkCancellation()
            // A complete normal delta from the durable base cursor is authoritative:
            // an earlier ambiguous commit would have appeared in this stream. A full
            // resync is explicitly a snapshot from which absence must not be inferred.
            if !isFullResync {
                var resolvedJournal = journal
                resolvedJournal.reject(Array(
                    rejectedThisRound
                        .subtracting(opaqueFetchedIDs)
                        .subtracting(unresolvedConflictIDs)))
                try persistJournal(resolvedJournal)
            }

            // Cursor advancement comes after durable offer resolution. If journal fsync
            // fails, retaining the old cursor lets a CAS-capable transport reject a
            // restart's stale offer against any remote value fetched in this round.
            // An undecryptable record was fetched but not applied, so hold the cursor.
            if opaqueFetchedIDs.isEmpty, unresolvedConflictIDs.isEmpty {
                var nextBase = base
                nextBase.adoptCursor(cursor, kind: cursorKind)
                try persistBase(nextBase)
                try await transport.acknowledgeFetched(through: cursor)
            }
            round.fullResync = isFullResync
            if let failure = terminalEngineFailureAfterFetch { throw failure }
            if !unresolvedConflictIDs.isEmpty {
                throw SyncTransportFailure.unreachable(
                    detail: "the backend reported a conflict without its authoritative record")
            }
            return round
        }

        // Three-way merge against the base BEFORE the guard, so the guard judges what
        // would actually be applied rather than what arrived. A remote tombstone that
        // loses to a local edit is not a deletion, and counting it as one would trip the
        // breaker on a library that was never in danger.
        var localNow = projectedLocal
        let authoritativeIncomingByID = Dictionary(
            uniqueKeysWithValues: incoming.map { ($0.envelope.id, $0.envelope) })
        do {
            try journal.validateDependencyOccupants(authoritativeIncomingByID)
            // A completed dependency can be pruned, but its live deterministic copy
            // identity remains reserved. Without this guard an unrelated remote value
            // could inherit the local provenance during merge and become legitimized.
            let reservedCopies = Array(projectedLocal.values)
                + journal.entries.values.map(\.desired)
                + Array(base.envelopes.values)
            for localCopy in reservedCopies where
                SyncMerge.hasValidConflictCopyIdentity(localCopy) {
                guard let remote = authoritativeIncomingByID[localCopy.id],
                      !remote.deleted else { continue }
                guard SyncMerge.isMatchingPlainConflictCopy(
                    remote,
                    candidate: localCopy)
                else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
            }
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "an iCloud record occupies a deterministic conflict-copy "
                    + "identifier; sync stopped before changing either local record")
        }

        // The local files contain live records only. The journal supplies explicit
        // tombstones and may also contain a restamped recreation that the frozen local
        // model cannot represent by itself.
        for remote in incoming {
            let envelope = remote.envelope
            if let desired = journal.entry(envelope.id)?.desired {
                localNow[envelope.id] = desired
            }
        }
        var mergedByID: [UUID: SyncEnvelope] = [:]
        var dependencyStages: [(source: SyncEnvelope, copies: [SyncEnvelope])] = []
        for remote in incoming {
            let envelope = remote.envelope
            let offered = journal.entry(envelope.id)?.offered?.envelope
                ?? offeredThisRound[envelope.id]
            let ancestor: SyncEnvelope?
            if Self.sameVersion(offered, envelope) {
                // An echo matching an ambiguous offer proves that offer is the
                // tentative ancestor. This is the distinction that makes a later local
                // delete beat our own echoed create/update instead of looking like a
                // delete racing an unrelated remote edit.
                ancestor = offered
            } else {
                ancestor = base.envelope(envelope.id)
            }
            let merge: SyncMerge.EnvelopeOutcome
            do {
                merge = try SyncMerge.mergeEnvelopeOutcome(
                    base: ancestor,
                    local: localNow[envelope.id],
                    remote: envelope)
            } catch {
                throw SyncEngineFailure(
                    reason: .localLibraryQuarantined,
                    detail: "a content-conflict snapshot was malformed or could not be "
                        + "preserved safely; sync stopped without applying it")
            }
            if let resolved = merge.survivor {
                mergedByID[resolved.id] = resolved
                localNow[resolved.id] = resolved
                let hasSecureVariants = try SyncMerge
                    .secureContentConflictVariants(in: resolved).isEmpty == false
                if !merge.conflictCopies.isEmpty
                    || (hasSecureVariants && library.supportsSecureConflictMaterialization) {
                    dependencyStages.append((resolved, merge.conflictCopies))
                }
            }
            for copy in merge.conflictCopies {
                let authoritative = authoritativeIncomingByID[copy.id]
                if let authoritative {
                    guard SyncMerge.isMatchingPlainConflictCopy(
                        authoritative, candidate: copy)
                    else {
                        throw SyncEngineFailure(
                            reason: .localLibraryQuarantined,
                            detail: "a generated conflict copy collided with an existing "
                                + "snippet; sync stopped without overwriting either record")
                    }
                    // The remote record may be a later user edit of the generated copy.
                    // Treat the pristine deterministic copy as its ancestor so it cannot
                    // become a second content conflict merely because both arrived in
                    // the same durable inbox batch.
                    let evolved = try SyncMerge.mergeEnvelopeOutcome(
                        base: copy,
                        local: localNow[copy.id] ?? copy,
                        remote: authoritative)
                    guard evolved.conflictCopies.isEmpty,
                          let survivor = evolved.survivor else {
                        throw SyncEngineFailure(
                            reason: .localLibraryQuarantined,
                            detail: "an existing conflict copy could not be reconciled safely")
                    }
                    mergedByID[copy.id] = survivor
                    localNow[copy.id] = survivor
                } else if let existing = localNow[copy.id] ?? mergedByID[copy.id] {
                    guard SyncMerge.isMatchingPlainConflictCopy(existing, candidate: copy) else {
                        throw SyncEngineFailure(
                            reason: .localLibraryQuarantined,
                            detail: "a generated conflict copy collided with an existing "
                                + "snippet; sync stopped without overwriting either record")
                    }
                    // A user may already have renamed or edited the copy. Deterministic
                    // redelivery identifies the same provenance but must never restore
                    // the original generated snapshot over that later user change.
                    mergedByID[copy.id] = existing
                    localNow[copy.id] = existing
                } else {
                    mergedByID[copy.id] = copy
                    localNow[copy.id] = copy
                }
            }
        }
        let merged = mergedByID.values.sorted { $0.id.uuidString < $1.id.uuidString }

        if !dependencyStages.isEmpty {
            var stagedJournal = journal
            for stage in dependencyStages {
                try stagedJournal.stageConflictDependency(
                    source: stage.source,
                    conflictCopies: stage.copies)
            }
            try persistJournal(stagedJournal)
        }

        // Classify before the circuit breaker: a rival-vault tombstone is not a deletion
        // this library can apply and must not trip a sticky mass-deletion halt.
        let classification = try library.prepareRemote(merged)

        // The circuit breaker.
        let live = library.liveIDs()
        let decision = DeletionGuard.evaluate(live: live, incoming: classification.applicable)
        if case .refuse(let refusal) = decision {
            throw SyncEngineFailure(reason: .massDeletion, detail: refusal.description)
        }

        try Task.checkCancellation()
        var expectedPrimary = Dictionary(
            uniqueKeysWithValues: classification.applicable.map {
                ($0.id, localSnapshot.primaryState(for: $0.id))
            })
        // A carrier source implicitly reads and may create each deterministic copy.
        // Those derived ids are part of the transaction's read/write set even when no
        // standalone copy envelope was fetched in this batch. Otherwise a local edit or
        // deletion between snapshot and apply could be overwritten outside the CAS.
        for envelope in classification.applicable {
            for variant in try SyncMerge.secureContentConflictVariants(in: envelope) {
                expectedPrimary[variant.copyID] = localSnapshot.primaryState(
                    for: variant.copyID)
            }
        }
        // A dependency may owe immutable C0 to the backend while ordinary local intent
        // has already advanced to C1 or T. Pass that later value as an explicitly local
        // post-materialization operation: the bridge applies it inside the SAME primary
        // transaction, after creating C0 but before explicit fetched C records. It is
        // never recorded as fetched/confirmed merely because it participated here.
        let carrierSourceIDs = Set(classification.applicable.compactMap { envelope in
            (try? SyncMerge.secureContentConflictVariants(in: envelope)).map {
                $0.isEmpty ? nil : envelope.id
            } ?? nil
        })
        let freshlyPreparedConflictCopyEvidence = try library.prepareConflictCopyEvidence(
            from: classification.applicable)
        var preparedConflictCopyEvidence = freshlyPreparedConflictCopyEvidence
        if !freshlyPreparedConflictCopyEvidence.isEmpty {
            var evidenceJournal = journal
            do {
                try evidenceJournal.recordConflictCopyEvidence(
                    freshlyPreparedConflictCopyEvidence)
                // The carrier may arrive alone while primary already contains a
                // confirmed C1 (notably a plaintext demotion). Now that immutable C0
                // exists, retain that exact later local generation behind it even when
                // generic reconciliation had correctly pruned it as base-equal earlier.
                try evidenceJournal.holdPostPrerequisiteCopyIntents(
                    Array(projectedLocal.values),
                    now: now())
            } catch {
                throw SyncEngineFailure(
                    reason: .localLibraryQuarantined,
                    detail: "prepared conflict-copy evidence did not match its durable dependency")
            }
            // This is the critical ordering boundary: exact random-nonce C0 bytes are
            // durable before the bridge can atomically apply a later C1/tombstone.
            try persistJournal(evidenceJournal)
            preparedConflictCopyEvidence = try journal.frozenConflictCopyEvidence(
                matching: freshlyPreparedConflictCopyEvidence)
        }
        // The dependency may have been staged only a few lines above by this fetch.
        // Compute C1/T from the now-durable graph/evidence, not from the pre-stage
        // journal which did not yet know that the deterministic id was dependency-owned.
        let heldConflictCopyIntents = journal.heldConflictCopyIntents(
            forSourceIDs: carrierSourceIDs)
        let outcome = try library.applyRemote(
            classification.applicable,
            expectedPrimary: expectedPrimary,
            heldConflictCopyIntents: heldConflictCopyIntents,
            preparedConflictCopyEvidence: preparedConflictCopyEvidence)
        let deferred = Set(classification.deferredIDs).union(outcome.deferredIDs)
        let incompatible = Set(classification.incompatibleVaultIDs)
            .union(outcome.incompatibleVaultIDs)
        let retry = Set(outcome.retryIDs)
        let unapplied = deferred.union(incompatible).union(retry)
        round.merged = outcome.changedIDs.count
        round.deferred = deferred.count
        round.fullResync = isFullResync
        round.retryNeeded = !retry.isEmpty

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
        var nextBase = base
        let confirmedIncoming = incoming.filter {
            !unapplied.contains($0.envelope.id)
        }
        for remote in confirmedIncoming {
            nextBase.recordConfirmed(
                remote.envelope,
                recordVersion: remote.recordVersion)
        }
        // First make fetched envelopes durable while deliberately retaining the old
        // compare-and-swap cursor. That old cursor is the safety net if journal
        // resolution fails or the process dies before its stale offer is cleared.
        // `applyRemote` above has already durably written the merged local result M;
        // storing server B here therefore rebases M onto B. On restart the pre-push
        // reconcile derives M-vs-B again before the frozen old journal offer can run.
        // Preserve explicit C1/tombstone from the same fetched batch before advancing
        // the base. The dependency is about to overwrite that backend generation with
        // C0, so equality with the fetched base cannot make the later intent disposable.
        var postApplyJournal = journal
        do {
            try postApplyJournal.holdPostPrerequisiteCopyIntents(
                classification.applicable,
                now: now())
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a later conflict-copy generation did not match its durable lineage")
        }
        try persistJournal(postApplyJournal)
        try persistBase(nextBase)

        // A fetched server value resolves ambiguity for that record. A matching offer
        // is acknowledged; a different value explicitly rejects the old offer while
        // retaining the latest desired generation for the next round.
        let confirmedIDs = Set(confirmedIncoming.map(\.envelope.id))
        // A conflict result may omit its server record, in which case the offer stays
        // frozen until a normal fetch supplies and applies that id. Once the fetched
        // value is durably confirmed it is exactly the authoritative proof we were
        // waiting for; retaining the unresolved marker would pin the stale offer and
        // back off forever despite already holding B/V2.
        unresolvedConflictIDs.subtract(
            confirmedIDs.intersection(fetchedAuthoritativeIDs))
        var resolvedJournal = journal
        resolvedJournal.acknowledge(Array(confirmedIDs), confirmed: base)
        let authoritativelyRejectedIDs: Set<UUID>
        if isFullResync {
            // Presence in a snapshot is authoritative; absence deliberately is not.
            authoritativelyRejectedIDs = rejectedThisRound.intersection(confirmedIDs)
        } else {
            // The exhaustive delta proves both present and absent server states. Keep
            // offers only for records whose fetched value could not be decoded/applied.
            authoritativelyRejectedIDs = rejectedThisRound
                .subtracting(unapplied)
                .subtracting(opaqueFetchedIDs)
                .subtracting(unresolvedConflictIDs)
        }
        resolvedJournal.reject(Array(authoritativelyRejectedIDs))

        // `applyRemote` may have written a field-level merge rather than the server
        // envelope recorded in base. Reproject it now so that difference becomes the
        // next durable desired state before this round is considered complete.
        let afterApply = try library.currentEnvelopes(
            agreedBase: resolvedJournal.projectionKnowledge(over: base))
        do {
            try resolvedJournal.reconcileDependencies(
                current: afterApply,
                confirmed: base,
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "applied conflict dependency state no longer matches its primary "
                    + "records; sync stopped without overwriting them")
        }
        resolvedJournal.reconcile(
            current: afterApply, confirmed: base, deviceID: device, now: now())
        try persistJournal(resolvedJournal)

        // Only after the journal no longer exposes a stale offer may the CAS ancestor
        // advance past the remote values just applied. On a transport that enforces that
        // ancestor, a crash in any preceding window causes a harmless conflict/refetch.
        if unapplied.isEmpty,
           opaqueFetchedIDs.isEmpty,
           unresolvedConflictIDs.isEmpty {
            var advancedBase = base
            advancedBase.adoptCursor(cursor, kind: cursorKind)
            try persistBase(advancedBase)
            try await transport.acknowledgeFetched(through: cursor)
        }

        if let failure = terminalEngineFailureAfterFetch { throw failure }

        if !unresolvedConflictIDs.isEmpty {
            throw SyncTransportFailure.unreachable(
                detail: "the backend reported a conflict without its authoritative record")
        }

        if !incompatible.isEmpty {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "\(incompatible.count) secure snippet(s) belong to a different "
                    + "vault identity. Their ciphertext cannot be opened by this device; "
                    + "sync stopped instead of repeatedly fetching the same records.")
        }
        return round
    }

    /// Establishes or verifies the account component of the confirmed checkpoint.
    ///
    /// A truly pristine legacy pair can be bound directly. Any meaningful unbound
    /// checkpoint may already straddle an account switch that happened before this
    /// version existed, and an explicit mismatch is equally ambiguous; both require the
    /// sticky review path before local data is even projected.
    private func reconcileAccountIdentity(
        _ resolved: SyncAccountIdentity?
    ) async throws {
        if case .checkpoint? = approvedTransportReset {
            // Consume before any fallible work. If reset fails, another human Review is
            // required; the authorization must never leak into a later scope.
            approvedTransportReset = nil
            do {
                try await resetTransportCheckpoint(
                    resolved: resolved,
                    reset: { try await self.transport.resetAfterCheckpointReview() })
                checkpointResetRequiresReview = false
            } catch {
                checkpointResetRequiresReview = true
                enterHalt(
                    .checkpointUnreadable,
                    detail: "the reviewed local scheduler checkpoint could not be replaced; review is required before retrying")
                throw error
            }
            return
        }

        if checkpointResetRequiresReview {
            throw SyncEngineFailure(
                reason: .checkpointUnreadable,
                detail: "the previous reviewed scheduler reset did not complete; review is required again")
        }

        if base.accountIdentity == resolved, approvedTransportReset == nil {
            return
        }

        let meaningfulCheckpoint = base.cursor != nil
            || !base.envelopes.isEmpty
            || !base.recordVersions.isEmpty
            || !journal.entries.isEmpty
            || !journal.conflictDependencies.isEmpty
        let isPristineLegacy = base.accountIdentity == nil
            && resolved != nil
            && !meaningfulCheckpoint

        if isPristineLegacy {
            var bound = base
            bound.schemaVersion = SyncBase.currentSchemaVersion
            bound.accountIdentity = resolved
            try persistBase(bound)
            approvedTransportReset = nil
            return
        }

        guard case .account? = approvedTransportReset else {
            let detail: String
            if base.accountIdentity == nil {
                detail = "the confirmed iCloud checkpoint predates account binding; review "
                    + "the signed-in account before starting a fresh merge"
            } else if resolved == nil {
                detail = "the selected sync backend has no account scope but the confirmed "
                    + "checkpoint belongs to an iCloud account"
            } else {
                detail = "the signed-in iCloud account no longer owns the confirmed sync "
                    + "checkpoint; review the account before starting a fresh merge"
            }
            throw SyncEngineFailure(
                reason: .accountChanged,
                detail: detail)
        }

        // Consume before the first fallible write. Failure or process death must not
        // leave a reusable authorization that can later target a different account.
        approvedTransportReset = nil

        // A crash can leave the durable dependency in the post-stage/pre-apply window:
        // the encrypted losing body exists only in its authenticated source carrier and
        // has not reached the vault copy yet. The old inbox may disappear as soon as the
        // account scheduler is reset, so recover that prerequisite from the journal's
        // frozen source before deriving replacement-account intent.
        let recovery = try recoverConflictPrerequisitesBeforeSchedulerReset()
        guard recovery.deferredIDs.isEmpty else {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "unlock the secure vault and review the sync reset again; "
                    + "the old checkpoint was retained because it still owns a "
                    + "conflict-copy prerequisite")
        }
        guard recovery.incompatibleVaultIDs.isEmpty else {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "the secure vault identity does not match a pending conflict "
                    + "copy; the old checkpoint was retained")
        }
        guard recovery.retryIDs.isEmpty else {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "primary conflict-copy state changed during reviewed recovery; "
                    + "the old checkpoint was retained for another review")
        }

        // Capture primary storage against the OLD projection before erasing its base.
        // This is the only point where an unjournaled local deletion can still be
        // distinguished from a fresh install.
        let current = try library.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        var resetJournal = journal
        try resetJournal.prepareForAccountChange(
            current: current,
            confirmed: base,
            deviceID: device,
            now: now(),
            discoverSecureCarriers: library.supportsSecureConflictMaterialization)

        // Journal first is the crash fence. If the next write fails, restart still sees
        // the old account-bound base plus complete latest local intent and asks for
        // review again. No old offered generation survives into the new account.
        try persistJournal(resetJournal)
        // Only now may transport-private account state be replaced. A failed CKSyncEngine
        // checkpoint reset leaves the old base intact and the one-shot approval already
        // consumed, so the next attempt must ask for Review again.
        try await transport.resetAfterAccountReview()
        try persistBase(SyncBase(
            journalEstablished: true,
            accountIdentity: resolved))
    }

    /// Rebuilds same-account local intent before replacing an unreadable/poisoned
    /// scheduler checkpoint. This intentionally uses the same conservative fence as an
    /// account migration: cursor and record generations cannot be trusted once the
    /// scheduler epoch is replaced.
    private func resetTransportCheckpoint(
        resolved: SyncAccountIdentity?,
        reset: () async throws -> Void
    ) async throws {
        // Replacing a poisoned scheduler can discard the only replayable inbox event in
        // exactly the same way as an account reset. Materialise journal-owned carriers
        // while the old checkpoint is still intact, then persist their copy snapshots.
        let recovery = try recoverConflictPrerequisitesBeforeSchedulerReset()
        guard recovery.deferredIDs.isEmpty else {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "unlock the secure vault and review the sync reset again; "
                    + "the old checkpoint was retained because it still owns a "
                    + "conflict-copy prerequisite")
        }
        guard recovery.incompatibleVaultIDs.isEmpty else {
            throw SyncEngineFailure(
                reason: .vaultUnreadable,
                detail: "the secure vault identity does not match a pending conflict "
                    + "copy; the old checkpoint was retained")
        }
        guard recovery.retryIDs.isEmpty else {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "primary conflict-copy state changed during reviewed recovery; "
                    + "the old checkpoint was retained for another review")
        }
        let current = try library.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        var resetJournal = journal
        try resetJournal.prepareForAccountChange(
            current: current,
            confirmed: base,
            deviceID: device,
            now: now(),
            discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        try persistJournal(resetJournal)
        try await reset()
        try persistBase(SyncBase(
            journalEstablished: true,
            accountIdentity: resolved))
    }

    /// Closes stage/evidence/apply crash windows before a reviewed scheduler reset.
    /// Exact random-nonce C0 bytes become journal-durable before primary installation;
    /// a later C1/tombstone is held and reapplied atomically with that installation.
    private func recoverConflictPrerequisitesBeforeSchedulerReset() throws -> ApplyOutcome {
        // First let already-present primary copies satisfy their requirements. A stale
        // crash-shaped journal may still say every sibling is missing even though one
        // has since been materialized or demoted; feeding that sibling back through the
        // materializer can collide with legitimate representation/user changes.
        let current = try library.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        var recoveredJournal = journal
        do {
            try recoveredJournal.reconcileDependencies(
                current: current,
                confirmed: base,
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a pending conflict-copy prerequisite no longer matched its "
                    + "primary record; the reviewed reset was not performed")
        }
        // Capture existing C1/plain demotions before freezing missing C0. They are real
        // later local intent and must remain primary after the recovery transaction.
        recoveredJournal.reconcile(
            current: current,
            confirmed: base,
            deviceID: device,
            now: now())
        let sources = recoveredJournal.carrierSourcesAwaitingMaterialization
        if !sources.isEmpty {
            let freshlyPrepared = try library.prepareConflictCopyEvidence(from: sources)
            guard !freshlyPrepared.isEmpty else {
                try persistJournal(recoveredJournal)
                return ApplyOutcome(deferredIDs: sources.map(\.id))
            }
            do {
                try recoveredJournal.recordConflictCopyEvidence(freshlyPrepared)
            } catch {
                throw SyncEngineFailure(
                    reason: .localLibraryQuarantined,
                    detail: "prepared reset evidence did not match its durable carrier")
            }
        }
        // Critical fence: a process death from here on leaves enough exact evidence to
        // finish primary installation on ordinary restart without the old inbox.
        try persistJournal(recoveredJournal)

        let outcome = try recoverFrozenConflictPrerequisitesInPrimary()
        guard outcome.deferredIDs.isEmpty,
              outcome.incompatibleVaultIDs.isEmpty,
              outcome.retryIDs.isEmpty else {
            return outcome
        }

        // Recovery may have converted a receipt-proven primary absence into T and
        // persisted it. Continue from that published journal; writing the pre-helper
        // local copy here would resurrect its stale C1 intent.
        recoveredJournal = journal
        let recoveredCurrent = try library.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: base))
        do {
            try recoveredJournal.reconcileDependencies(
                current: recoveredCurrent,
                confirmed: base,
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a recovered conflict-copy prerequisite did not match its "
                    + "durable source; the reviewed reset was not performed")
        }
        recoveredJournal.reconcile(
            current: recoveredCurrent,
            confirmed: base,
            deviceID: device,
            now: now())
        let recoveredPrimary = try library.currentSnapshot(
            agreedBase: recoveredJournal.projectionKnowledge(over: base))
        guard recoveredJournal.conflictPrerequisiteRecovery(
            primaryStates: recoveredPrimary.primaryStates,
            installedHashes: recoveredPrimary.installedConflictPrerequisiteHashes)
            .sources.isEmpty else {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a conflict-copy prerequisite remained incomplete after "
                    + "recovery; the reviewed reset was not performed")
        }
        try persistJournal(recoveredJournal)
        return outcome
    }

    /// Installs already-frozen C0 evidence which is absent from primary storage. The
    /// bridge authenticates the retained carrier and exact evidence and reapplies any
    /// dependency-held later C1/T inside one library transaction.
    private func recoverFrozenConflictPrerequisitesInPrimary() throws -> ApplyOutcome {
        guard journal.hasFrozenConflictPrerequisitesAwaitingPrimaryCheck else {
            return ApplyOutcome()
        }
        let snapshot = try library.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: base))
        var stabilized = journal
        do {
            try stabilized.reconcileInstalledConflictPrerequisiteAbsence(
                current: snapshot.envelopes,
                installedHashes: snapshot.installedConflictPrerequisiteHashes,
                confirmed: base,
                deviceID: device,
                now: now())
        } catch {
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "a local conflict-install receipt did not match its durable "
                    + "dependency; sync stopped without replaying the copy")
        }
        // This journal write is the crash fence for a user deletion observed after C0
        // reached primary. Only after T is durable may recovery decide not to replay C0.
        try persistJournal(stabilized)
        let recovery = journal.conflictPrerequisiteRecovery(
            primaryStates: snapshot.primaryStates,
            installedHashes: snapshot.installedConflictPrerequisiteHashes)
        guard !recovery.sources.isEmpty else { return ApplyOutcome() }
        return try library.materializeConflictPrerequisites(
            from: recovery.sources,
            preparedConflictCopyEvidence: recovery.evidence,
            heldConflictCopyIntents: recovery.heldIntents,
            expectedPrimary: recovery.expectedPrimary)
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
        case .accountChanged:
            enterHalt(
                .accountChanged,
                detail: "the iCloud account changed during an active sync operation; "
                    + "no response from that operation was trusted")
        case .checkpointUnreadable(let detail):
            enterHalt(.checkpointUnreadable, detail: detail)
        case .remoteDataReset(let detail):
            enterHalt(.remoteDataReset, detail: detail)
        case .unreachable, .rejected:
            consecutiveFailures += 1
            let delay = min(pow(2, Double(consecutiveFailures)), Self.maxBackoff)
            transition(to: .offline(retryAfter: now().addingTimeInterval(delay)))
        }
    }

    private func quarantine(_ record: WireRecord) {
        let folder = SnippetStorageLocations.syncQuarantineFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(record.id.uuidString).blob", isDirectory: false)
        do {
            try AtomicFileWriter.write(record.blob, to: url, temporaryDirectory: temporaryDirectory)
        } catch {
            Diagnostics.record(.storageFailure(
                area: .syncQuarantine,
                operation: .write,
                failure: DiagnosticFailure(error),
                attempt: nil))
        }
    }

    /// Makes a candidate confirmed state durable before publishing it in memory.
    ///
    /// The base used to be treated as disposable derived state. Once journal ACKs are
    /// fenced by it, a failed write cannot be ignored: doing so would let this process
    /// forget an offer that a restarted process still considers ambiguous.
    private func persistBase(_ candidate: SyncBase) throws {
        do {
            try SyncBaseFile.write(
                candidate, to: baseURL, temporaryDirectory: temporaryDirectory)
            base = candidate
        } catch {
            Diagnostics.record(.storageFailure(
                area: .syncBase,
                operation: .write,
                failure: DiagnosticFailure(error),
                attempt: nil))
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "the confirmed sync base could not be saved; sync stopped "
                    + "before acknowledging any pending local change")
        }
    }

    /// Same publish-after-durability rule for desired/offered state.
    private func persistJournal(_ candidate: SyncJournal) throws {
        let needsWrite = candidate != journal
            || !FileManager.default.fileExists(atPath: journalURL.path)
        do {
            if needsWrite {
                try SyncJournalFile.write(
                    candidate, to: journalURL, temporaryDirectory: temporaryDirectory)
                journal = candidate
            }
            // Journal first: a crash may leave an obsolete exact-hash receipt, which is
            // harmless. The inverse order could erase the only proof distinguishing a
            // real deletion from a pre-install crash.
            try library.retainConflictPrerequisiteInstallReceipts(
                for: journal.activeConflictPrerequisiteCopyIDs)
        } catch {
            Diagnostics.record(.storageFailure(
                area: .syncBase,
                operation: .write,
                failure: DiagnosticFailure(error),
                attempt: nil))
            throw SyncEngineFailure(
                reason: .localLibraryQuarantined,
                detail: "pending sync intent could not be saved; sync stopped before "
                    + "contacting or acknowledging the backend")
        }
    }

    private static func sameVersion(_ lhs: SyncEnvelope?, _ rhs: SyncEnvelope?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            if let left = try? lhs.envelopeHash(), let right = try? rhs.envelopeHash() {
                return left == right
            }
            return lhs == rhs
        case (.some, nil), (nil, .some): return false
        }
    }

    /// Makes a safety stop survive process death and an ordinary relaunch.
    ///
    /// `SyncState.halt` has always promised this, but the engine previously kept its
    /// halt only in memory. A rival vault therefore stopped one scheduler round in one
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
            Diagnostics.record(.storageFailure(
                area: .syncState,
                operation: .lock,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return .failed
        }
        defer { held.release() }

        // `FileGuard.none` lets ordinary user-data writes use their verified retry path
        // on exotic filesystems. This read-modify-write has no such CAS verification:
        // proceeding unlocked could erase a concurrent crash marker, generation bump,
        // or newer halt. A safety marker must fail closed instead.
        guard !held.isUnlocked else {
            Diagnostics.record(.storageState(
                area: .syncState,
                state: .degraded,
                value: nil))
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
            Diagnostics.record(.storageState(
                area: .syncState,
                state: .versionTooNew,
                value: version))
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
            Diagnostics.record(.storageFailure(
                area: .syncState,
                operation: .write,
                failure: DiagnosticFailure(error),
                attempt: nil))
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
