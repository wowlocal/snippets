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
    /// Explicitly verifies and adopts a primary restored while the library was
    /// quarantined. Ordinary projection must not perform this adoption: if state.json
    /// was lost, only the recovery action may cross this boundary.
    func reviewRecoveredLibrary(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope]
    /// Releases the library's in-process mutation quarantine only after Core has made
    /// the non-destructive recovery fence durable and retired the independent marker.
    /// Value-only implementations have no separate mutation gate.
    func finalizeRecoveredLibraryReview() throws
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

    func reviewRecoveredLibrary(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        try currentEnvelopes(agreedBase: agreedBase)
    }

    func finalizeRecoveredLibraryReview() throws {}

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

    private final class WeakRecoveryClaimOwner {
        weak var value: SyncEngine?

        init(_ value: SyncEngine) {
            self.value = value
        }
    }

    /// Same-process peers need more than a PID: tests, multiple windows, and scene
    /// coordinators can each own an engine while sharing one process incarnation.
    /// Weak ownership also makes a simulated/process restart immediately reclaimable.
    private static var recoveryClaimOwners: [UUID: WeakRecoveryClaimOwner] = [:]

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
        /// The backend rejected work for a condition that cannot be repaired by a
        /// timer, but retrying after the user fixes the backend is safe. This is not a
        /// persisted safety halt because no destructive decision is being authorized.
        case needsAttention(String)
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
    var onUserDeletionIntentsConsumed: ((Set<UUID>) -> Void)?

    /// Injected. Nothing here reads the system clock directly.
    var now: () -> Date = { Date() }

    private let transport: any SyncTransport
    private let library: any SyncLibraryAccess
    private let sealer: any SyncBlobSealing
    private let baseURL: URL
    private let journalURL: URL
    private let stateURL: URL
    private let libraryQuarantineMarkerURL: URL
    private let lockURL: URL
    private let temporaryDirectory: URL
    private let stateLockTimeout: TimeInterval
    private let device: String
    private let recoveryClaimOwnerID = UUID()
    /// Process-local bridge between an explicit UI delete and the next durable journal
    /// tombstone. If the process dies before journal persistence, the marker is lost in
    /// the conservative direction and another device may ask for review as before.
    private var userInitiatedDeletionIDs: Set<UUID> = []
    private var base: SyncBase
    private var journal: SyncJournal
    /// Once journal.json exists, base.json must also exist: the engine establishes them
    /// in that order before first transport. Losing confirmed state afterwards makes
    /// local absence ambiguous and therefore requires repair/review, not a blind reset.
    private var baseRequiresReload = false
    /// A corrupt/future journal must be repaired or deliberately removed before even an
    /// explicit recovery action can proceed. Otherwise recovery would overwrite the only
    /// remaining evidence of an ambiguous server commit with a fresh empty journal.
    private var journalRequiresReload = false
    /// One process-local authorization granted by clearing a recoverable transport
    /// halt. It is consumed before the journal-first reset begins. A crash therefore
    /// loses the authorization and asks for review again rather than guessing that the
    /// replacement completed.
    private enum ApprovedTransportReset { case account, checkpoint, remoteData }
    private var approvedTransportReset: ApprovedTransportReset?
    private enum ApprovedMassDeletion {
        case reviewedBatch(
            liveCount: Int,
            requestedDeletions: Int,
            fingerprint: String)

        func matches(_ refusal: DeletionGuard.Refusal, fingerprint: String) -> Bool {
            switch self {
            case .reviewedBatch(let liveCount, let requestedDeletions, let reviewedFingerprint):
                refusal.liveCount == liveCount
                    && refusal.requestedDeletions == requestedDeletions
                    && reviewedFingerprint == fingerprint
            }
        }
    }
    /// One round only. A crash or a changed deletion batch asks again.
    private var approvedMassDeletion: ApprovedMassDeletion?
    /// The exact deletion halt remains durable while its approved round runs. It is
    /// cleared only after the library, base, journal and cursor are all durable. This
    /// is deliberately separate from the process-local authority above: consuming the
    /// authority before apply must not also remove the restart fence.
    private var reviewedMassDeletionInFlight: SyncState.Halt?
    /// A legacy halt has no exact deletion fingerprint. Its Refresh action authorizes
    /// one read-only inspection round, not any deletion at all. Keep the old halt
    /// durable until that round either records exact facts or proves there are no
    /// effective deletions left.
    private var refreshingLegacyDeletionReview = false
    /// A reviewed checkpoint reset may fail transiently after its one-shot authority is
    /// consumed. Keep the public result retryable for that attempt, but require a new
    /// Review before any later data-plane call (and persist the halt for a restart).
    private var checkpointResetRequiresReview = false
    private var remoteResetRequiresReview = false
    private var consecutiveFailures = 0
    /// The exact halt value read from or written to disk. It is a compare-and-swap
    /// token: recovery may clear only this halt, never a newer stop written by a peer.
    private var durableHalt: SyncState.Halt?
    /// A peer completed the claimed recovery and may have replaced transport-private
    /// scheduler state. Core can reload base/journal, but this transport instance must
    /// never touch its old checkpoint again; the coordinator observes this and rebuilds
    /// the complete engine/transport after an awaited shutdown barrier.
    private(set) var requiresTransportRestart = false

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
        libraryQuarantineMarkerURL: URL? = nil,
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
        self.libraryQuarantineMarkerURL = libraryQuarantineMarkerURL
            ?? LibraryQuarantineMarker.url(beside: stateURL)
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
        Self.recoveryClaimOwners[recoveryClaimOwnerID] = WeakRecoveryClaimOwner(self)
    }

    // MARK: - Halting

    func noteUserInitiatedDeletions(_ ids: Set<UUID>) {
        userInitiatedDeletionIDs.formUnion(ids)
    }

    func cancelUserInitiatedDeletions(_ ids: Set<UUID>) {
        userInitiatedDeletionIDs.subtract(ids)
    }

    /// Refuses to run again until a human clears it.
    func halt(_ reason: SyncState.HaltReason, detail: String) {
        enterHalt(reason, detail: detail)
    }

    /// Reconstructs the typed halt from the independent quarantine marker when
    /// state.json was lost. Used by the app's local-only recovery path while cloud sync
    /// is disabled; no transport or sealing operation is needed to review a restored
    /// primary file and publish its base.json crash fence.
    func reassertPrimaryLibraryQuarantine() {
        if durableHalt?.recoveryContext == .localLibraryQuarantine { return }
        if case .halted(.schemaTooNew, _) = state { return }
        if durableHalt != nil {
            // A concurrently persisted account/deletion stop must survive local-file
            // recovery. Present the more fundamental primary quarantine in memory; once
            // its independent marker is retired, the preserved halt becomes visible to
            // a normal transport-backed engine again.
            transition(to: .halted(
                .localLibraryQuarantined,
                detail: "the primary snippet library was preserved for recovery; restore "
                    + "or import a valid library, then check again"))
            return
        }
        enterHalt(
            .localLibraryQuarantined,
            detail: "the primary snippet library was preserved for recovery; restore "
                + "or import a valid library, then check again",
            recoveryContext: .localLibraryQuarantine)
    }

    /// The action that can clear the exact stop currently held by this engine.
    ///
    /// Old schema-3 mass-deletion halts contain counts only in human-readable text, not
    /// the fingerprint of the exact UUID set. Matching that text could authorize a
    /// different same-sized deletion batch, so those halts may only be refreshed. The
    /// following fetch writes a typed context and presents the real confirmation.
    var recoveryAction: SyncRecoveryAction? {
        guard case .halted(let reason, _) = state else { return nil }
        if let claim = durableHalt?.recoveryClaim {
            switch recoveryClaimDisposition(claim) {
            case .ownedByThisEngine, .abandonedInThisProcess:
                break
            case .activeInThisProcess:
                return nil
            case .unknownProcessOrHost:
                return .reclaimRecovery
            }
        }
        if reason == .massDeletion, durableHalt?.recoveryContext == nil {
            return .refreshDeletionReview
        }
        return reason.recoveryAction
    }

    var recoveryClaimNeedsTakeover: Bool {
        guard let claim = durableHalt?.recoveryClaim else { return false }
        return recoveryClaimDisposition(claim) == .unknownProcessOrHost
    }

    private func haltByClaimingRecovery(_ halt: SyncState.Halt) -> SyncState.Halt {
        var claimed = halt
        let processID = ProcessInfo.processInfo.processIdentifier
        let generation = SentinelLock.processGeneration(for: processID)
        claimed.recoveryClaim = SyncState.Halt.RecoveryClaim(
            id: UUID(),
            ownerID: recoveryClaimOwnerID,
            hostName: ProcessInfo.processInfo.hostName,
            processID: processID,
            processGenerationSeconds: generation?.seconds,
            processGenerationMicroseconds: generation?.microseconds)
        return claimed
    }

    private enum RecoveryClaimDisposition: Equatable {
        case ownedByThisEngine
        case activeInThisProcess
        case abandonedInThisProcess
        case unknownProcessOrHost
    }

    /// Process-local weak ownership is the only namespace we can prove. Hostnames and
    /// PIDs are not globally unique, so they must never authorize stealing a claim from
    /// a different process or Mac. An unknown owner instead gets an explicit takeover
    /// confirmation that clears only the claim; the original action is confirmed again.
    private func recoveryClaimDisposition(
        _ claim: SyncState.Halt.RecoveryClaim
    ) -> RecoveryClaimDisposition {
        if claim.ownerID == recoveryClaimOwnerID { return .ownedByThisEngine }
        if let knownOwner = Self.recoveryClaimOwners[claim.ownerID] {
            if knownOwner.value != nil { return .activeInThisProcess }
            Self.recoveryClaimOwners.removeValue(forKey: claim.ownerID)
            return .abandonedInThisProcess
        }
        return .unknownProcessOrHost
    }

    /// Performs the action the UI described and the user selected. The action must
    /// still match the exact durable halt: a stale button can never clear a newer stop.
    func performRecovery(_ action: SyncRecoveryAction) {
        guard case .halted(let reason, let detail) = state else { return }
        guard recoveryAction == action else { return }

        if action == .reclaimRecovery {
            guard let claimedHalt = durableHalt,
                  let claim = claimedHalt.recoveryClaim,
                  recoveryClaimDisposition(claim) == .unknownProcessOrHost else { return }
            var unclaimedHalt = claimedHalt
            unclaimedHalt.recoveryClaim = nil
            switch updatePersistedHalt(unclaimedHalt, expecting: claimedHalt) {
            case .written(let stored):
                guard let stored else {
                    durableHalt = nil
                    requiresTransportRestart = true
                    transition(to: .needsAttention("transport_restart_required"))
                    return
                }
                durableHalt = stored
                transition(to: .halted(stored.reason, detail: stored.detail))
            case .superseded(let newer):
                durableHalt = newer
                transition(to: .halted(newer.reason, detail: newer.detail))
            case .cleared:
                durableHalt = nil
                requiresTransportRestart = true
                transition(to: .needsAttention("transport_restart_required"))
            case .tooNew(let version):
                durableHalt = nil
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/state.json is version \(version); update Snippets before "
                        + "sync can resume."))
            case .failed:
                transition(to: .halted(
                    reason,
                    detail: detail + " The interrupted recovery claim could not be "
                        + "cleared from disk; no recovery action was applied."))
            }
            return
        }

        let isPrimaryLibraryRecovery = action == .checkAgain
            && (durableHalt?.recoveryContext == .localLibraryQuarantine
                || LibraryQuarantineMarker.exists(at: libraryQuarantineMarkerURL))
        var reviewedPrimary: [UUID: SyncEnvelope]?
        if isPrimaryLibraryRecovery {
            // This marker was written before the unreadable primary moved aside. Never
            // clear it merely because a button was tapped: prove that the restored or
            // imported primary can be projected first. On failure the exact durable
            // marker remains, so a relaunch still refuses to seed/project an empty file.
            do {
                reviewedPrimary = try library.reviewRecoveredLibrary(
                    agreedBase: journal.projectionKnowledge(over: base))
            } catch {
                enterHalt(
                    .localLibraryQuarantined,
                    detail: "the restored snippet library still cannot be read; choose a "
                        + "valid export or quarantined backup, then check again",
                    recoveryContext: .localLibraryQuarantine)
                return
            }
        }
        guard let reviewedProtocolPair = reloadProtocolPairAfterReview() else { return }

        if isPrimaryLibraryRecovery {
            // Existing sync ancestry needs a crash fence before clearing state.json:
            // every future round must do a full merge without inferring deletion from
            // old-base absence. A never-synced installation has no ancestor to protect;
            // keep the opt-in contract by retiring only the quarantine marker and leave
            // base.json/journal.json absent until the user actually enables sync.
            do {
                if reviewedProtocolPair == .existing {
                    var recoveryBase = base
                    recoveryBase.upgradeToCurrentSchema()
                    recoveryBase.envelopes = Dictionary(uniqueKeysWithValues:
                        (reviewedPrimary ?? [:]).values.map {
                            (SyncBase.key($0.id), $0)
                        })
                    // These envelopes are a local edit/delete witness, not backend
                    // confirmation. The reviewed full reset obtains fresh CAS tokens.
                    recoveryBase.recordVersions = [:]
                    recoveryBase.cursor = nil
                    recoveryBase.cursorKind = nil
                    recoveryBase.requiresTransportFullResync = false
                    recoveryBase.requiresNonDestructiveLibraryMerge = true
                    recoveryBase.nonDestructiveMergeMode = .reviewedLocalSnapshot
                    // A crash after base.json was written but before the independent
                    // marker was retired must resume the same review transaction. If
                    // an older broken ordering already lost the marker, the active
                    // base fence is the only safe identity to restore here.
                    let resumableReviewID = base.requiresNonDestructiveLibraryMerge
                        && base.nonDestructiveMergeMode == .reviewedLocalSnapshot
                        ? base.nonDestructiveReviewID
                        : nil
                    recoveryBase.nonDestructiveReviewID = try LibraryQuarantineMarker.write(
                        reviewID: resumableReviewID,
                        to: libraryQuarantineMarkerURL,
                        temporaryDirectory: temporaryDirectory)
                    // A restored export may be incomplete; old confirmed absences are
                    // deliberately not an ancestor for this recovery epoch.
                    recoveryBase.preRecoveryConfirmedEnvelopes = nil
                    try persistBase(recoveryBase)
                }

                // Keep the independent marker until this recovery's durable halt is
                // gone. Otherwise a crash in this interval starts with a writable
                // primary plus a stale local-recovery halt; a second Check Again could
                // mint a new review epoch and forget what the first review observed.
                if let reviewedHalt = durableHalt,
                   reviewedHalt.recoveryContext == .localLibraryQuarantine {
                    switch updatePersistedHalt(nil, expecting: reviewedHalt) {
                    case .written:
                        durableHalt = nil
                    case .cleared:
                        durableHalt = nil
                    case .superseded(let newer):
                        durableHalt = newer
                        if newer.recoveryContext == .localLibraryQuarantine {
                            transition(to: .halted(newer.reason, detail: newer.detail))
                            return
                        }
                        // A different transport halt is independent of the primary
                        // recovery. Finish retiring this marker, then reveal it below.
                    case .tooNew(let version):
                        durableHalt = nil
                        transition(to: .halted(
                            .schemaTooNew,
                            detail: "Sync/state.json is version \(version); update Snippets "
                                + "before sync can resume."))
                        return
                    case .failed:
                        transition(to: .halted(
                            reason,
                            detail: detail + " The reviewed stop could not be cleared "
                                + "from disk; library recovery remains locked."))
                        return
                    }
                }
                try LibraryQuarantineMarker.removeDurably(at: libraryQuarantineMarkerURL)
                try library.finalizeRecoveredLibraryReview()
            } catch {
                enterHalt(
                    .localLibraryQuarantined,
                    detail: "the restored library was readable, but its safe recovery "
                        + "transaction could not be finalized; sync remains stopped",
                    recoveryContext: .localLibraryQuarantine)
                return
            }

            // `reassertPrimaryLibraryQuarantine` may have deliberately kept a different
            // concurrent durable halt intact. Local recovery is complete once its own
            // marker/fence transaction commits; never clear the unrelated stop with the
            // Check Again action that did not review it.
            if let preservedHalt = durableHalt,
               preservedHalt.recoveryContext != .localLibraryQuarantine {
                transition(to: .halted(
                    preservedHalt.reason,
                    detail: preservedHalt.detail))
                return
            }

            consecutiveFailures = 0
            transition(to: .idle(lastSync: nil))
            return
        }

        switch action {
        case .applyRemoteDeletions:
            approvedMassDeletion = switch durableHalt?.recoveryContext {
            case .massDeletion(
                let liveCount,
                let requestedDeletions,
                let batchFingerprint):
                .reviewedBatch(
                    liveCount: liveCount,
                    requestedDeletions: requestedDeletions,
                    fingerprint: batchFingerprint)
            case .localLibraryQuarantine, nil:
                // Unreachable for a valid action: a legacy halt exposes only
                // `refreshDeletionReview`, which grants no deletion authority.
                nil
            }
        case .useCurrentAccount:
            approvedTransportReset = .account
        case .repairCheckpoint:
            approvedTransportReset = .checkpoint
        case .restoreCloudFromThisDevice:
            approvedTransportReset = .remoteData
        case .refreshDeletionReview:
            refreshingLegacyDeletionReview = true
        case .reclaimRecovery:
            return
        case .retrySync, .checkAgain:
            break
        }

        if refreshingLegacyDeletionReview {
            guard let reviewedHalt = durableHalt,
                  reviewedHalt.reason == .massDeletion,
                  reviewedHalt.recoveryContext == nil else {
                refreshingLegacyDeletionReview = false
                transition(to: .halted(
                    reason,
                    detail: detail + " The legacy deletion stop changed; refresh it again."))
                return
            }
            // Keep the old stop as the crash/retry fence. The process may inspect one
            // batch, but a restart or a failed fetch must ask for Refresh again.
            switch updatePersistedHalt(reviewedHalt, expecting: reviewedHalt) {
            case .written(let stored):
                durableHalt = stored
                consecutiveFailures = 0
                transition(to: .idle(lastSync: nil))
            case .superseded(let newer):
                refreshingLegacyDeletionReview = false
                durableHalt = newer
                transition(to: .halted(newer.reason, detail: newer.detail))
            case .cleared:
                refreshingLegacyDeletionReview = false
                durableHalt = nil
                transition(to: .idle(lastSync: nil))
            case .tooNew(let version):
                refreshingLegacyDeletionReview = false
                durableHalt = nil
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/state.json is version \(version); update Snippets before "
                        + "sync can resume."))
            case .failed:
                refreshingLegacyDeletionReview = false
                transition(to: .halted(
                    reason,
                    detail: detail + " The legacy deletion stop could not be verified "
                        + "on disk; sync remains stopped."))
            }
            return
        }

        if approvedTransportReset != nil {
            // A reviewed scheduler/remote reset can mutate transport state before the
            // replacement base is durable. Keep the exact halt on disk throughout that
            // window while letting this process run the one approved attempt. A crash
            // therefore starts halted again instead of reconciling against the old base.
            guard let reviewedHalt = durableHalt else {
                approvedTransportReset = nil
                transition(to: .halted(
                    reason,
                    detail: detail + " The safety stop is not durable, so the reviewed "
                        + "reset cannot start."))
                return
            }
            let claimedHalt = haltByClaimingRecovery(reviewedHalt)
            switch updatePersistedHalt(claimedHalt, expecting: reviewedHalt) {
            case .written(let stored):
                durableHalt = stored
                consecutiveFailures = 0
                transition(to: .idle(lastSync: nil))
            case .superseded(let newer):
                approvedTransportReset = nil
                durableHalt = newer
                transition(to: .halted(newer.reason, detail: newer.detail))
            case .cleared:
                approvedTransportReset = nil
                durableHalt = nil
                requiresTransportRestart = true
                transition(to: .needsAttention("transport_restart_required"))
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
                    detail: detail + " The reviewed stop could not be verified on disk; "
                        + "sync remains stopped."))
            }
            return
        }

        if approvedMassDeletion != nil {
            // Applying a reviewed deletion can mutate the primary library before the
            // replacement base/cursor commit. Keep the exact typed stop on disk for
            // that entire interval. A crash therefore cannot turn a previously large
            // batch into an unreviewed below-threshold deletion on the next launch.
            guard let reviewedHalt = durableHalt,
                  reviewedHalt.reason == .massDeletion,
                  reviewedHalt.recoveryContext != nil else {
                approvedMassDeletion = nil
                transition(to: .halted(
                    reason,
                    detail: detail + " The exact deletion stop is not durable, so the "
                        + "reviewed deletion cannot start."))
                return
            }
            let claimedHalt = haltByClaimingRecovery(reviewedHalt)
            switch updatePersistedHalt(claimedHalt, expecting: reviewedHalt) {
            case .written(let stored):
                durableHalt = stored
                reviewedMassDeletionInFlight = stored
                consecutiveFailures = 0
                transition(to: .idle(lastSync: nil))
            case .superseded(let newer):
                approvedMassDeletion = nil
                durableHalt = newer
                transition(to: .halted(newer.reason, detail: newer.detail))
            case .cleared:
                approvedMassDeletion = nil
                reviewedMassDeletionInFlight = nil
                durableHalt = nil
                requiresTransportRestart = true
                transition(to: .needsAttention("transport_restart_required"))
            case .tooNew(let version):
                approvedMassDeletion = nil
                durableHalt = nil
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/state.json is version \(version); update Snippets before "
                        + "sync can resume."))
            case .failed:
                approvedMassDeletion = nil
                transition(to: .halted(
                    reason,
                    detail: detail + " The reviewed deletion stop could not be verified "
                        + "on disk; sync remains stopped."))
            }
            return
        }

        switch updatePersistedHalt(nil, expecting: durableHalt) {
        case .written:
            durableHalt = nil
            consecutiveFailures = 0
            transition(to: .idle(lastSync: nil))
        case .cleared:
            durableHalt = nil
            consecutiveFailures = 0
            transition(to: .idle(lastSync: nil))
        case .superseded(let newer):
            approvedTransportReset = nil
            approvedMassDeletion = nil
            // A peer stopped for a different reason after this pane was drawn. The
            // user's review covered the old stop, not this one; adopt it and ask again.
            durableHalt = newer
            transition(to: .halted(newer.reason, detail: newer.detail))
        case .tooNew(let version):
            approvedTransportReset = nil
            approvedMassDeletion = nil
            durableHalt = nil
            transition(to: .halted(
                .schemaTooNew,
                detail: "Sync/state.json is version \(version); update Snippets before "
                    + "sync can resume."))
        case .failed:
            approvedTransportReset = nil
            approvedMassDeletion = nil
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
    /// then recovery would create an empty journal over evidence of lost intent. Reading
    /// the pair every time also catches damage that happened after engine initialization.
    private enum ReviewedProtocolPair {
        case absent
        case existing
    }

    private func reloadProtocolPairAfterReview() -> ReviewedProtocolPair? {
        let baseOutcome = SyncBaseFile.load(from: baseURL)
        let journalOutcome = SyncJournalFile.load(from: journalURL)

        switch baseOutcome {
        case .tooNew(let version):
            baseRequiresReload = true
            transition(to: .halted(
                .schemaTooNew,
                detail: "Sync/base.json is version \(version); update Snippets before "
                    + "sync can resume."))
            return nil
        case .unreadable:
            baseRequiresReload = true
            transition(to: .halted(
                .localLibraryQuarantined,
                detail: "the confirmed sync base is unreadable; repair it or "
                    + "deliberately remove both protocol files before sync can resume"))
            return nil
        case .missing:
            switch journalOutcome {
            case .missing:
                // Deliberately removing both files after review is the explicit reset.
                base = SyncBase()
                journal = SyncJournal()
                baseRequiresReload = false
                journalRequiresReload = false
                return .absent
            case .tooNew(let version):
                journalRequiresReload = true
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/journal.json is version \(version); update Snippets "
                        + "before sync can resume."))
                return nil
            case .loaded, .unreadable:
                baseRequiresReload = true
                transition(to: .halted(
                    .localLibraryQuarantined,
                    detail: "Sync/base.json is missing while journal.json still exists; "
                        + "restore the base or deliberately remove both protocol files "
                        + "before sync can resume"))
                return nil
            }
        case .loaded(let repairedBase):
            switch journalOutcome {
            case .loaded(let repairedJournal):
                base = repairedBase
                journal = repairedJournal
                baseRequiresReload = false
                journalRequiresReload = false
                return .existing
            case .missing(let emptyJournal):
                guard !repairedBase.journalEstablished else {
                    journalRequiresReload = true
                    transition(to: .halted(
                        .localLibraryQuarantined,
                        detail: "Sync/journal.json is missing while base.json proves it "
                            + "was established; restore it or deliberately remove both "
                            + "protocol files before sync can resume"))
                    return nil
                }
                // Legacy base from before the journal shipped. It will receive the
                // additive established marker before the next network operation.
                base = repairedBase
                journal = emptyJournal
                baseRequiresReload = false
                journalRequiresReload = false
                return .existing
            case .tooNew(let version):
                journalRequiresReload = true
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/journal.json is version \(version); update Snippets "
                        + "before sync can resume."))
                return nil
            case .unreadable(let journalDetail):
                journalRequiresReload = true
                transition(to: .halted(
                    .localLibraryQuarantined,
                    detail: "\(journalDetail); repair it or deliberately remove both "
                        + "protocol files before sync can resume"))
                return nil
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
    func sync(bypassingBackoff: Bool = false) async -> State {
        if requiresTransportRestart { return state }
        if state.isHalted,
           let claimedHalt = durableHalt,
           claimedHalt.recoveryClaim != nil {
            // A live peer owns this reviewed mutation, so this engine exposes no
            // duplicate action. Its normal poll still acts as a read-only completion
            // watch: once the owner clears/replaces the durable halt, stop showing a
            // permanent stale banner. Reload protocol ancestry before any later round.
            switch updatePersistedHalt(claimedHalt, expecting: claimedHalt) {
            case .written(let stored):
                durableHalt = stored
            case .superseded(let newer):
                durableHalt = newer
                transition(to: .halted(newer.reason, detail: newer.detail))
            case .cleared:
                durableHalt = nil
                requiresTransportRestart = true
                transition(to: .needsAttention("transport_restart_required"))
            case .tooNew(let version):
                durableHalt = nil
                transition(to: .halted(
                    .schemaTooNew,
                    detail: "Sync/state.json is version \(version); update Snippets "
                        + "before sync can resume."))
            case .failed:
                break
            }
            return state
        }
        guard !state.isHalted else { return state }
        if case .syncing = state { return state }
        if !bypassingBackoff,
           case .offline(let retryAfter) = state,
           now() < retryAfter { return state }

        // A mass-deletion confirmation belongs to exactly this immediate attempt. If
        // the task is cancelled, fails before apply, or sees a different batch, it must
        // never leak into a later round.
        defer {
            approvedMassDeletion = nil
            reviewedMassDeletionInFlight = nil
            refreshingLegacyDeletionReview = false
        }

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
            if refreshingLegacyDeletionReview,
               !finalizeLegacyDeletionRefresh() {
                return state
            }
            if reviewedMassDeletionInFlight != nil,
               !finalizeReviewedMassDeletionHalt() {
                return state
            }
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
            if let reviewed = reviewedMassDeletionInFlight {
                transition(to: .halted(reviewed.reason, detail: reviewed.detail))
            } else {
                transition(to: .disabled)
            }
        } catch let failure as SyncTransportFailure {
            // A reviewed reset can persist a fresh review-required halt and then fail
            // at the transport boundary. Do not immediately overwrite that durable,
            // actionable state with a generic offline/backoff presentation.
            if let reviewed = reviewedMassDeletionInFlight {
                switch failure {
                case .accountChanged, .checkpointUnreadable, .remoteDataReset:
                    handle(failure)
                case .unreachable, .rejected, .pushUnsupported:
                    transition(to: .halted(reviewed.reason, detail: reviewed.detail))
                }
            } else if refreshingLegacyDeletionReview,
               let legacyHalt = pendingLegacyDeletionRefreshHalt {
                switch failure {
                case .accountChanged, .checkpointUnreadable, .remoteDataReset:
                    handle(failure)
                case .unreachable, .rejected, .pushUnsupported:
                    transition(to: .halted(
                        legacyHalt.reason,
                        detail: legacyHalt.detail))
                }
            } else if !state.isHalted {
                handle(failure)
            }
        } catch let failure as SyncEngineFailure {
            if reviewedMassDeletionInFlight != nil,
               failure.reason != .massDeletion,
               failure.reason != .backendRefused {
                enterHalt(
                    failure.reason,
                    detail: failure.detail,
                    recoveryContext: failure.recoveryContext)
            } else if let reviewed = reviewedMassDeletionInFlight,
                      failure.reason == .backendRefused {
                transition(to: .halted(reviewed.reason, detail: reviewed.detail))
            } else if refreshingLegacyDeletionReview,
               failure.reason == .backendRefused,
               let legacyHalt = pendingLegacyDeletionRefreshHalt {
                transition(to: .halted(legacyHalt.reason, detail: legacyHalt.detail))
            } else if failure.reason == .backendRefused {
                transition(to: .needsAttention(failure.detail))
            } else {
                enterHalt(
                    failure.reason,
                    detail: failure.detail,
                    recoveryContext: failure.recoveryContext)
            }
        } catch {
            if let reviewed = reviewedMassDeletionInFlight {
                transition(to: .halted(reviewed.reason, detail: reviewed.detail))
            } else if refreshingLegacyDeletionReview,
               let legacyHalt = pendingLegacyDeletionRefreshHalt {
                transition(to: .halted(legacyHalt.reason, detail: legacyHalt.detail))
            } else if !state.isHalted {
                handle(.unreachable(detail: "\(error)"))
            }
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
        let roundDatasetIdentity: SyncDatasetIdentity?
        do {
            let preflight = try await transport.preflightScope()
            roundAccountIdentity = preflight.identity
            roundDatasetIdentity = preflight.datasetIdentity
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
            try await reconcileScope(preflight)
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
        if base.requiresNonDestructiveLibraryMerge {
            let recovery = try await resetForNonDestructiveLibraryMerge(
                accountIdentity: roundAccountIdentity,
                datasetIdentity: roundDatasetIdentity)
            round.merged += recovery.changedIDs.count
            round.deferred += recovery.deferredIDs.count
            round.retryNeeded = !recovery.retryIDs.isEmpty
            guard recovery.deferredIDs.isEmpty,
                  recovery.incompatibleVaultIDs.isEmpty,
                  recovery.retryIDs.isEmpty else {
                if !recovery.incompatibleVaultIDs.isEmpty {
                    throw SyncEngineFailure(
                        reason: .vaultUnreadable,
                        detail: "a journaled secure snippet from before local-library "
                            + "recovery belongs to a different vault")
                }
                return round
            }
        }

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
            try await transport.resetForLocalFullResync(
                expectedIdentity: roundAccountIdentity,
                expectedDatasetIdentity: roundDatasetIdentity)
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
            established.upgradeToCurrentSchema()
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
            current: current,
            confirmed: base,
            deviceID: device,
            now: now(),
            userInitiatedDeletionIDs: userInitiatedDeletionIDs)
        try persistJournal(reconciled)
        consumeUserDeletionIntents(afterReconciling: current)

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
                now: now(),
                userInitiatedDeletionIDs: userInitiatedDeletionIDs)
            try persistJournal(resolvedJournal)
            consumeUserDeletionIntents(afterReconciling: resolvedCurrent)
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
            guard submission.datasetIdentity == roundDatasetIdentity else {
                throw SyncEngineFailure(
                    reason: .remoteDataReset,
                    detail: "the remote library was replaced while pending snippets were "
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
        var pageFullResyncMode: Bool?
        var fetchedPageRecordCount = 0
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
            guard fetch.datasetIdentity == roundDatasetIdentity else {
                throw SyncEngineFailure(
                    reason: .remoteDataReset,
                    detail: "the remote library was replaced while changes were being "
                        + "downloaded; no response from that operation was trusted")
            }
            if fetch.replacesPriorPages {
                guard fetch.isFullResync else {
                    throw SyncEngineFailure(
                        reason: .checkpointUnreadable,
                        detail: "the backend restarted a paged fetch without returning "
                            + "a complete snapshot")
                }
                // Retain authoritative records returned by this round's CAS conflicts,
                // but throw away every page from the obsolete feed. A feed can rotate
                // more than once during a large snapshot, so this is page-token driven
                // rather than only the first false→true full-resync transition.
                rawIncoming.removeAll { !$0.fromConflict }
                round.downloaded -= fetchedPageRecordCount
                fetchedPageRecordCount = 0
                isFullResync = false
                pageFullResyncMode = nil
            }
            if let pageFullResyncMode,
               pageFullResyncMode != fetch.isFullResync {
                throw SyncEngineFailure(
                    reason: .checkpointUnreadable,
                    detail: "the backend changed between snapshot and delta mode "
                        + "inside one paged fetch; no records or cursor were trusted")
            }
            pageFullResyncMode = fetch.isFullResync
            isFullResync = isFullResync || fetch.isFullResync
            round.downloaded += fetch.records.count
            fetchedPageRecordCount += fetch.records.count
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
        var mergeAncestorsByID: [UUID: SyncEnvelope] = [:]
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
                let entry = journal.entry(envelope.id)
                if let entry, entry.reviewedLocalSnapshotKnown {
                    let reviewedState = entry.reviewedLocalAncestor
                    let desiredState = entry.desired.deleted ? nil : entry.desired
                    let changedAfterReview = !Self.sameVersion(
                        desiredState, reviewedState)
                    // A readable pre-recovery base remains the causal ancestor even
                    // when the user edits or deletes the reviewed primary afterward.
                    // Using the reviewed value instead would make an unchanged remote
                    // copy look like a concurrent edit and could resurrect it. The
                    // reviewed value is an ancestor only for a row that had no older
                    // confirmed ancestry and changed after the explicit review.
                    ancestor = entry.preReviewMergeAncestor
                        ?? (changedAfterReview ? reviewedState : nil)
                } else {
                    ancestor = base.envelope(envelope.id)
                }
            }
            mergeAncestorsByID[envelope.id] = ancestor
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
        let approvedDeletionIDs = Set(classification.applicable.lazy.filter {
            Self.hasMatchingUserDeletionAncestor(
                $0,
                knownLiveEnvelopes: [
                    projectedLocal[$0.id],
                    mergeAncestorsByID[$0.id],
                ])
        }.map(\.id)).intersection(live)
        // Evaluate unexplained deletions against the library that remains after the
        // already-authorized UI deletions. Otherwise a large intentional batch could
        // make a second, genuinely unexplained batch look artificially small.
        let guardedLive = live.subtracting(approvedDeletionIDs)
        let effectiveDeletionIDs = Set(classification.applicable.lazy.filter {
            $0.deleted && !approvedDeletionIDs.contains($0.id)
        }.map(\.id)).intersection(guardedLive)
        let decision = DeletionGuard.evaluate(
            liveCount: guardedLive.count,
            deletions: effectiveDeletionIDs.count)
        let hasExactReviewBoundary = refreshingLegacyDeletionReview
            || approvedMassDeletion != nil
            || reviewedMassDeletionInFlight != nil
        let refusal: DeletionGuard.Refusal? = if hasExactReviewBoundary,
                                                !effectiveDeletionIDs.isEmpty {
            DeletionGuard.Refusal(
                liveCount: guardedLive.count,
                requestedDeletions: effectiveDeletionIDs.count,
                allowedDeletions: DeletionGuard.allowedDeletions(
                    liveCount: guardedLive.count))
        } else if case .refuse(let refusal) = decision {
            refusal
        } else {
            nil
        }
        if let refusal {
            let fingerprint = Self.massDeletionFingerprint(
                live: guardedLive,
                incoming: classification.applicable.filter {
                    !approvedDeletionIDs.contains($0.id)
                })
            if approvedMassDeletion?.matches(refusal, fingerprint: fingerprint) == true {
                // Consume before the first fallible apply step. A failure or crash asks
                // again instead of carrying destructive authority into another round.
                approvedMassDeletion = nil
            } else {
                approvedMassDeletion = nil
                let detail: String
                if hasExactReviewBoundary, decision.isAllowed {
                    detail = "the deletion batch changed or was refreshed; cloud sync "
                        + "now reports \(refusal.requestedDeletions) deletions among "
                        + "\(refusal.liveCount) snippets. Sync paused before completing "
                        + "this batch. Review this exact replacement batch before "
                        + "letting sync finish it"
                } else {
                    detail = refusal.description
                }
                throw SyncEngineFailure(
                    reason: .massDeletion,
                    detail: detail,
                    recoveryContext: .massDeletion(
                        liveCount: refusal.liveCount,
                        requestedDeletions: refusal.requestedDeletions,
                batchFingerprint: fingerprint))
            }
        } else if approvedMassDeletion != nil {
            // The reviewed set disappeared completely. There is no destructive action
            // left to authorize; consume the one-shot and let non-deletion work finish.
            approvedMassDeletion = nil
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

    /// Establishes or verifies stable account membership and the physical remote dataset
    /// generation before Core projects local user data. Feed epochs stay transport-local:
    /// rotating one is ordinary cursor maintenance, while changing a dataset is a sticky
    /// restore review even after process death.
    private func reconcileScope(_ preflight: SyncScopePreflight) async throws {
        let resolved = preflight.identity
        let resolvedDataset = preflight.datasetIdentity
        let meaningfulCheckpoint = base.cursor != nil
            || !base.envelopes.isEmpty
            || !base.recordVersions.isEmpty
            || !journal.entries.isEmpty
            || !journal.conflictDependencies.isEmpty

        // Snippets Cloud originally folded dataset and feed into accountIdentity. The
        // exact current legacy digest proves the same membership, dataset and feed, so it
        // can be migrated without a misleading account review. No fuzzy/partial alias is
        // accepted: a feed that changed before upgrade still needs conservative review.
        if let stored = base.accountIdentity,
           (base.schemaVersion < 4 || base.datasetIdentity == nil),
           preflight.legacyAccountIdentities.contains(stored) {
            var migrated = base
            migrated.upgradeToCurrentSchema()
            migrated.accountIdentity = resolved
            migrated.datasetIdentity = resolvedDataset
            try persistBase(migrated)
        }

        // A truly empty installation has no old scope-bearing fact to protect and may be
        // bound directly. This also covers the first accountless backend round.
        if !meaningfulCheckpoint,
           base.accountIdentity == nil,
           base.datasetIdentity == nil {
            var bound = base
            bound.upgradeToCurrentSchema()
            bound.accountIdentity = resolved
            bound.datasetIdentity = resolvedDataset
            try persistBase(bound)
        }

        if case .account? = approvedTransportReset {
            // Account notifications and checkpoint binding failures can require a fresh
            // scheduler epoch even when the stable identity resolves to the same value.
            // The reset still revalidates the exact account and dataset from preflight.
            if base.accountIdentity == resolved,
               base.datasetIdentity != resolvedDataset {
                approvedTransportReset = nil
                throw SyncEngineFailure(
                    reason: .remoteDataReset,
                    detail: "the remote library changed while the account review was "
                        + "open; review the remote restore separately")
            }
            approvedTransportReset = nil
            do {
                try await resetTransportCheckpoint(
                    resolvedAccount: resolved,
                    resolvedDataset: resolvedDataset,
                    finalizingReviewedHalt: .accountChanged,
                    reset: {
                        try await self.transport.resetAfterAccountReview(
                            expectedIdentity: resolved,
                            expectedDatasetIdentity: resolvedDataset)
                    })
            } catch let failure as ReviewedTransportHaltCommitFailure {
                throw failure
            } catch {
                enterHalt(
                    .accountChanged,
                    detail: "the reviewed account change could not replace the old "
                        + "checkpoint; review is required before retrying")
                throw error
            }
            return
        }

        if base.accountIdentity != resolved {
            let detail: String
            if base.accountIdentity == nil {
                detail = "the confirmed sync checkpoint predates account binding; "
                    + "review the signed-in account before starting a fresh merge"
            } else if resolved == nil {
                detail = "the selected sync backend has no account scope but the "
                    + "confirmed checkpoint belongs to an account"
            } else {
                detail = "the signed-in account no longer owns the confirmed sync "
                    + "checkpoint; review the account before starting a fresh merge"
            }
            throw SyncEngineFailure(reason: .accountChanged, detail: detail)
        }

        let datasetMatches = base.datasetIdentity == resolvedDataset
        let missingDatasetFence = resolvedDataset != nil
            && base.datasetIdentity == nil
            && meaningfulCheckpoint
        let datasetChanged = !datasetMatches || missingDatasetFence

        if case .remoteData? = approvedTransportReset {
            // Consume before the first fallible operation. The reset checks both values
            // observed by this exact preflight, closing account/dataset changes between
            // review and transport checkpoint replacement.
            approvedTransportReset = nil
            do {
                try await resetTransportCheckpoint(
                    resolvedAccount: resolved,
                    resolvedDataset: resolvedDataset,
                    finalizingReviewedHalt: .remoteDataReset,
                    reset: {
                        try await self.transport.resetAfterRemoteDataResetReview(
                            expectedIdentity: resolved,
                            expectedDatasetIdentity: resolvedDataset)
                    })
                remoteResetRequiresReview = false
            } catch let failure as ReviewedTransportHaltCommitFailure {
                throw failure
            } catch let failure as SyncTransportFailure {
                if case .accountChanged = failure { throw failure }
                remoteResetRequiresReview = true
                enterHalt(
                    .remoteDataReset,
                    detail: "the reviewed cloud-library restore could not replace the "
                        + "remote-reset checkpoint; review is required before retrying")
                throw failure
            } catch {
                remoteResetRequiresReview = true
                enterHalt(
                    .remoteDataReset,
                    detail: "the reviewed cloud-library restore could not replace the "
                        + "remote-reset checkpoint; review is required before retrying")
                throw error
            }
            return
        }

        if remoteResetRequiresReview {
            throw SyncEngineFailure(
                reason: .remoteDataReset,
                detail: "the previous reviewed cloud-library restore did not complete; "
                    + "review is required again")
        }
        if datasetChanged {
            let detail = missingDatasetFence
                ? "the confirmed checkpoint has no durable remote-dataset binding; "
                    + "review this device before restoring the cloud library"
                : "the remote library was replaced; review before restoring it from "
                    + "this device"
            throw SyncEngineFailure(reason: .remoteDataReset, detail: detail)
        }

        if case .checkpoint? = approvedTransportReset {
            approvedTransportReset = nil
            do {
                try await resetTransportCheckpoint(
                    resolvedAccount: resolved,
                    resolvedDataset: resolvedDataset,
                    finalizingReviewedHalt: .checkpointUnreadable,
                    reset: {
                        try await self.transport.resetAfterCheckpointReview(
                            expectedIdentity: resolved,
                            expectedDatasetIdentity: resolvedDataset)
                    })
                checkpointResetRequiresReview = false
            } catch let failure as ReviewedTransportHaltCommitFailure {
                throw failure
            } catch {
                checkpointResetRequiresReview = true
                enterHalt(
                    .checkpointUnreadable,
                    detail: "the reviewed local scheduler checkpoint could not be "
                        + "replaced; review is required before retrying")
                throw error
            }
            return
        }

        if checkpointResetRequiresReview {
            throw SyncEngineFailure(
                reason: .checkpointUnreadable,
                detail: "the previous reviewed scheduler reset did not complete; review "
                    + "is required again")
        }

        if base.schemaVersion < SyncBase.currentSchemaVersion {
            var upgraded = base
            upgraded.upgradeToCurrentSchema()
            try persistBase(upgraded)
        }
        approvedTransportReset = nil
    }

    /// Converts a restored-but-possibly-incomplete primary library into durable outbound
    /// intent without deriving any deletion from the old base. The base marker was
    /// written before the quarantine halt was cleared, so a crash at every point either
    /// remains stopped or repeats this idempotent full-merge preparation.
    private func resetForNonDestructiveLibraryMerge(
        accountIdentity: SyncAccountIdentity?,
        datasetIdentity: SyncDatasetIdentity?
    ) async throws -> ApplyOutcome {
        // A durable live journal entry may be the only copy of an edit that had not yet
        // reached the backend when snippets.json became unreadable. Materialize those
        // exact values back into primary storage before emptying the base; otherwise the
        // ordinary reconciliation immediately after reset would see primary absence and
        // discard them. Tombstone entries remain journal-owned and need no primary row.
        let snapshot = try library.currentSnapshot(
            agreedBase: journal.projectionKnowledge(over: base))
        if base.nonDestructiveMergeMode == .reviewedLocalSnapshot {
            // Mutate a candidate, not the published in-memory journal. The persistence
            // helper compares candidate vs published state before writing; mutating the
            // property in place would make a real tombstone look unchanged and leave
            // only the older live entry on disk across a crash.
            var reviewedJournal = journal
            try reviewedJournal.reconcileAfterReviewedLocalSnapshot(
                current: snapshot.envelopes,
                reviewedSnapshot: base,
                deviceID: device,
                now: now())
            // The tombstone for a post-review deletion must reach disk before an older
            // journal-only live value can be materialized below. A crash then repeats
            // from the exact same reviewed ancestor instead of resurrecting the row.
            try persistJournal(reviewedJournal)
        }
        let missingJournalValues = journal.entries.values
            .map(\.desired)
            .filter { !$0.deleted && snapshot.envelopes[$0.id] == nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let materialized: ApplyOutcome
        if missingJournalValues.isEmpty {
            materialized = ApplyOutcome()
        } else {
            materialized = try library.applyRemote(
                missingJournalValues,
                expectedPrimary: Dictionary(
                    uniqueKeysWithValues: missingJournalValues.map { ($0.id, .absent) }))
            // `applyRemote` is the exact primary commit point for a journal-only value.
            // Publish every successfully applied row immediately, even when another row
            // in this batch was deferred/retried. An external/user deletion can land in
            // the inter-round interval and must become a tombstone rather than letting
            // that exact live journal value be materialized again.
            let unapplied = Set(materialized.deferredIDs)
                .union(materialized.incompatibleVaultIDs)
                .union(materialized.retryIDs)
            let appliedJournalValues = missingJournalValues.filter {
                !unapplied.contains($0.id)
            }
            var materializedJournal = journal
            materializedJournal.markReviewedLocalSnapshot(appliedJournalValues)
            if !appliedJournalValues.isEmpty {
                try persistJournal(materializedJournal)
            }
            guard unapplied.isEmpty else { return materialized }
        }
        try await resetTransportCheckpoint(
            resolvedAccount: accountIdentity,
            resolvedDataset: datasetIdentity,
            reset: {
                try await self.transport.resetForLocalFullResync(
                    expectedIdentity: accountIdentity,
                    expectedDatasetIdentity: datasetIdentity)
            })
        return materialized
    }

    /// Rebuilds same-account local intent before replacing an unreadable/poisoned
    /// scheduler checkpoint. This intentionally uses the same conservative fence as an
    /// account migration: cursor and record generations cannot be trusted once the
    /// scheduler epoch is replaced.
    private func resetTransportCheckpoint(
        resolvedAccount: SyncAccountIdentity?,
        resolvedDataset: SyncDatasetIdentity?,
        finalizingReviewedHalt: SyncState.HaltReason? = nil,
        reset: () async throws -> Void
    ) async throws {
        // Replacing a poisoned scheduler can discard the only replayable inbox event in
        // exactly the same way as an account reset. Materialise journal-owned carriers
        // while the old checkpoint is still intact, then persist their copy snapshots.
        let nonDestructiveLibraryRecovery = base.requiresNonDestructiveLibraryMerge
        let recovery = try recoverConflictPrerequisitesBeforeSchedulerReset(
            inferLocalAbsences: !nonDestructiveLibraryRecovery)
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
        if nonDestructiveLibraryRecovery {
            try resetJournal.prepareForNonDestructiveLibraryRecovery(
                current: current,
                confirmed: base,
                deviceID: device,
                now: now(),
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
            resetJournal.markReviewedLocalSnapshot(current.values)
        } else {
            try resetJournal.prepareForAccountChange(
                current: current,
                confirmed: base,
                deviceID: device,
                now: now(),
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        }
        try persistJournal(resetJournal)
        try await reset()
        do {
            try persistBase(SyncBase(
                journalEstablished: true,
                accountIdentity: resolvedAccount,
                datasetIdentity: resolvedDataset))
            if let finalizingReviewedHalt {
                try finalizeReviewedTransportHalt(reason: finalizingReviewedHalt)
            }
        } catch let failure as ReviewedTransportHaltCommitFailure {
            throw failure
        } catch {
            guard let finalizingReviewedHalt else { throw error }
            // The transport has already discarded/replaced its private checkpoint. The
            // old durable halt is therefore the only crash-safe authorization fence
            // until the replacement base commits. Keep presenting that exact action;
            // translating this storage failure into a generic local Check Again would
            // let the wrong button clear the still-required remote/account review.
            transition(to: .halted(
                finalizingReviewedHalt,
                detail: "the reviewed reset changed its transport checkpoint, but the "
                    + "replacement sync base could not be committed; review again"))
            throw ReviewedTransportHaltCommitFailure.persistenceFailed
        }
    }

    private enum ReviewedTransportHaltCommitFailure: Error {
        case missingOrMismatched
        case superseded
        case futureSchema
        case persistenceFailed
    }

    private var pendingLegacyDeletionRefreshHalt: SyncState.Halt? {
        guard let halt = durableHalt,
              halt.reason == .massDeletion,
              halt.recoveryContext == nil else { return nil }
        return halt
    }

    /// A successful inspection with no effective deletion is the only path that may
    /// retire a legacy stop without replacing it with exact review facts. This happens
    /// after the complete round (including durable apply/base/cursor writes), so every
    /// earlier failure or crash leaves the legacy Refresh action intact.
    private func finalizeLegacyDeletionRefresh() -> Bool {
        guard let reviewed = pendingLegacyDeletionRefreshHalt else {
            transition(to: .halted(
                .massDeletion,
                detail: "the legacy deletion review changed while it was being "
                    + "refreshed; review it again"))
            return false
        }
        switch updatePersistedHalt(nil, expecting: reviewed) {
        case .written:
            durableHalt = nil
            return true
        case .cleared:
            durableHalt = nil
            return true
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
            onSafetyHaltPersistenceFailure?()
            transition(to: .halted(
                .massDeletion,
                detail: "the deletion check found nothing to remove, but its old "
                    + "safety stop could not be cleared from disk"))
        }
        return false
    }

    /// Retires only the exact deletion stop whose batch the user approved, and only
    /// after the whole round has committed. A same-reason halt written meanwhile may
    /// describe a different fingerprint, so matching just the reason is insufficient.
    private func finalizeReviewedMassDeletionHalt() -> Bool {
        guard let reviewed = reviewedMassDeletionInFlight,
              durableHalt == reviewed else {
            if let durableHalt {
                transition(to: .halted(durableHalt.reason, detail: durableHalt.detail))
            } else {
                transition(to: .halted(
                    .massDeletion,
                    detail: "the reviewed deletion completed, but its exact safety "
                        + "stop changed; review the current state again"))
            }
            return false
        }
        switch updatePersistedHalt(nil, expecting: reviewed) {
        case .written:
            durableHalt = nil
            return true
        case .cleared:
            durableHalt = nil
            return true
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
            onSafetyHaltPersistenceFailure?()
            transition(to: .halted(
                .massDeletion,
                detail: "the reviewed deletions were applied, but their safety stop "
                    + "could not be cleared; review again before syncing"))
        }
        return false
    }

    /// Clears the exact still-durable halt only after journal, transport checkpoint,
    /// and replacement base have all committed. This is the final commit record for a
    /// reviewed reset; every earlier crash remains visibly review-required.
    private func finalizeReviewedTransportHalt(
        reason: SyncState.HaltReason
    ) throws {
        guard let reviewed = durableHalt, reviewed.reason == reason else {
            transition(to: .halted(
                reason,
                detail: "the reviewed reset completed, but its safety stop no longer "
                    + "matches; review again before syncing"))
            throw ReviewedTransportHaltCommitFailure.missingOrMismatched
        }
        switch updatePersistedHalt(nil, expecting: reviewed) {
        case .written:
            durableHalt = nil
        case .cleared:
            durableHalt = nil
        case .superseded(let newer):
            durableHalt = newer
            transition(to: .halted(newer.reason, detail: newer.detail))
            throw ReviewedTransportHaltCommitFailure.superseded
        case .tooNew(let version):
            durableHalt = nil
            transition(to: .halted(
                .schemaTooNew,
                detail: "Sync/state.json is version \(version); update Snippets before "
                    + "sync can resume."))
            throw ReviewedTransportHaltCommitFailure.futureSchema
        case .failed:
            onSafetyHaltPersistenceFailure?()
            transition(to: .halted(
                reason,
                detail: "the reviewed reset completed, but its safety stop could not "
                    + "be cleared from disk; sync remains stopped"))
            throw ReviewedTransportHaltCommitFailure.persistenceFailed
        }
    }

    /// Closes stage/evidence/apply crash windows before a reviewed scheduler reset.
    /// Exact random-nonce C0 bytes become journal-durable before primary installation;
    /// a later C1/tombstone is held and reapplied atomically with that installation.
    private func recoverConflictPrerequisitesBeforeSchedulerReset(
        inferLocalAbsences: Bool = true
    ) throws -> ApplyOutcome {
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
        if inferLocalAbsences {
            recoveredJournal.reconcile(
                current: current,
                confirmed: base,
                deviceID: device,
                now: now())
        }
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
        if inferLocalAbsences {
            recoveredJournal.reconcile(
                current: recoveredCurrent,
                confirmed: base,
                deviceID: device,
                now: now())
        }
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
            transition(to: .needsAttention(detail))
        case .pushUnsupported:
            transition(to: .needsAttention("this backend does not accept pushes"))
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

    /// Retires process-local UI intent only after the journal owns the corresponding
    /// marker (or proves there is no deletion left to publish). A conflict-protected
    /// live desired value keeps the intent for the later round that can finally make
    /// its tombstone.
    private func consumeUserDeletionIntents(
        afterReconciling current: [UUID: SyncEnvelope]
    ) {
        guard !userInitiatedDeletionIDs.isEmpty else { return }
        let consumed = Set(userInitiatedDeletionIDs.filter { id in
            if current[id] != nil { return true }
            guard let desired = journal.entry(id)?.desired else { return true }
            return desired.carriesUserInitiatedDeletion
        })
        guard !consumed.isEmpty else { return }
        userInitiatedDeletionIDs.subtract(consumed)
        onUserDeletionIntentsConsumed?(consumed)
    }

    /// A UI-delete marker authorizes only deletion of a live generation named by the
    /// producing journal. The encrypted marker proves who created the authority; this
    /// causal match bounds what it can destroy. In particular, replaying an old valid
    /// marked tombstone after a newer recreation cannot bypass the circuit breaker.
    private static func hasMatchingUserDeletionAncestor(
        _ deletion: SyncEnvelope,
        knownLiveEnvelopes: [SyncEnvelope?]
    ) -> Bool {
        let permittedHashes = deletion.userInitiatedDeletionAncestorHashes
        guard !permittedHashes.isEmpty else { return false }
        return knownLiveEnvelopes.compactMap { envelope -> String? in
            guard let envelope, !envelope.deleted else { return nil }
            return try? envelope.envelopeHash()
        }.contains(where: permittedHashes.contains)
    }

    /// Opaque, local-only binding for a destructive confirmation. Hashing the sorted
    /// effective UUID set means duplicate delivery and batch order do not matter, while
    /// replacing even one deletion requires a fresh review. The value is never logged.
    private static func massDeletionFingerprint(
        live: Set<UUID>,
        incoming: [SyncEnvelope]
    ) -> String {
        let deleting = Set(incoming.lazy.filter(\.deleted).map(\.id)).intersection(live)
        return SyncDeletionSafety.fingerprint(ids: deleting)
    }

    /// Makes a safety stop survive process death and an ordinary relaunch.
    ///
    /// `SyncState.halt` has always promised this, but the engine previously kept its
    /// halt only in memory. A rival vault therefore stopped one scheduler round in one
    /// process, then fetched the same held cursor and stopped again after every launch.
    /// Historical backend-refusal halts and mass-deletion stops had the same hole. All
    /// persisted safety halts now go through this one door.
    private func enterHalt(
        _ reason: SyncState.HaltReason,
        detail: String,
        recoveryContext: SyncState.Halt.RecoveryContext? = nil
    ) {
        // JSON's ISO-8601 strategy stores whole seconds. Normalize before using the
        // value as a CAS token so immediate same-process recovery compares equal to
        // what another decoder reads from disk.
        let at = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
        let halt = SyncState.Halt(
            reason: reason,
            detail: detail,
            at: at,
            recoveryContext: recoveryContext)
        switch updatePersistedHalt(halt, expecting: durableHalt) {
        case .written(let stored):
            durableHalt = stored
            transition(to: .halted(reason, detail: detail))
        case .superseded(let newer):
            durableHalt = newer
            transition(to: .halted(newer.reason, detail: newer.detail))
        case .cleared:
            durableHalt = nil
            transition(to: .idle(lastSync: nil))
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
        case cleared
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
            // A stale reviewer must not recreate a stop that a peer already completed.
            // In particular, writing `expected` here would manufacture fresh one-shot
            // authority for a second account/checkpoint/remote reset.
            return .cleared
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
    var recoveryContext: SyncState.Halt.RecoveryContext? = nil
}
