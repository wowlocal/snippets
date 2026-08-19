import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

/// The durable local side of the sync protocol.
///
/// `SyncBase` says what the backend has confirmed. This journal records the other two
/// states that a request/response transport cannot reconstruct after a crash:
///
/// - `desired` is the latest state observed in the local library, including an explicit
///   tombstone for a deletion;
/// - `offered` is the exact snapshot handed to the transport whose acknowledgement is
///   still ambiguous.
///
/// An unresolved offer is never replaced by a newer desired value. It is either proved
/// confirmed by `SyncBase`, explicitly rejected after a fetch, or submitted again. That
/// fence is what makes create/update/delete safe when the server commits and the process
/// dies before receiving the acknowledgement.
nonisolated struct SyncJournal: Equatable {

    /// Schema 2 adds the durable ordering edge used by conflict preservation. An older
    /// build must stop before it can erase that edge and submit a carrier-free source
    /// beside (or before) the only copy of the losing body.
    /// Schema 3 persists the exact acceptance receipt for a conflict prerequisite.
    /// A later same-provenance C1 is not proof that the immutable C0 snapshot was ever
    /// accepted, and an older build must not erase that ordering fact on rewrite.
    /// Schema 4 persists reviewed primary existence until the first backend ACK. This
    /// closes the edit/delete window while an async checkpoint reset is in flight.
    /// Schema 5 keeps the reviewed state (including reviewed absence) separate from the
    /// older merge ancestor. Recovery can therefore preserve pre-review/lost-ACK intent
    /// and still recognize edits or deletions made after the user reviewed recovery.
    static let currentSchemaVersion = 5

    struct Offered: Equatable {
        var envelope: SyncEnvelope
        /// The desired generation this snapshot came from. A later local edit advances
        /// `Entry.generation` without changing this value.
        var generation: UInt64
        /// The exact backend generation used for this offer. It is inseparable from the
        /// offered bytes: after a fetched B/V2 is persisted, a crash may leave older
        /// offer A in the journal. Retrying A with V2 would pass CAS and overwrite B;
        /// retrying it with its original V1/nil safely conflicts.
        var recordVersion: SyncRecordVersion?

        init(
            envelope: SyncEnvelope,
            generation: UInt64,
            recordVersion: SyncRecordVersion? = nil
        ) {
            self.envelope = envelope
            self.generation = generation
            self.recordVersion = recordVersion
        }
    }

    struct Entry: Equatable {
        var desired: SyncEnvelope
        var offered: Offered?
        var generation: UInt64
        var modifiedAt: Date
        /// Exact primary value accepted by Repair/Check Again. Unlike an offer this says
        /// nothing about the backend. It proves that a later primary absence is a real
        /// local deletion and remains the three-way ancestor until that intent is ACKed.
        var reviewedLocalAncestor: SyncEnvelope?
        /// True when an explicit review captured this id. `reviewedLocalAncestor == nil`
        /// then means the exact reviewed state was absence, not “unknown”.
        var reviewedLocalSnapshotKnown: Bool
        /// Older confirmed/tentative ancestor used while local intent is still exactly
        /// the state shown at review time. Once local changes after review, merge uses
        /// `reviewedLocalAncestor` (including its known-absent state) instead.
        var preReviewMergeAncestor: SyncEnvelope?
        var reviewedLocalExistence: Bool {
            reviewedLocalSnapshotKnown && reviewedLocalAncestor != nil
        }

        init(
            desired: SyncEnvelope,
            offered: Offered?,
            generation: UInt64,
            modifiedAt: Date,
            reviewedLocalAncestor: SyncEnvelope? = nil,
            reviewedLocalSnapshotKnown: Bool? = nil,
            preReviewMergeAncestor: SyncEnvelope? = nil
        ) {
            self.desired = desired
            self.offered = offered
            self.generation = generation
            self.modifiedAt = modifiedAt
            self.reviewedLocalAncestor = reviewedLocalAncestor
            self.reviewedLocalSnapshotKnown = reviewedLocalSnapshotKnown
                ?? (reviewedLocalAncestor != nil)
            self.preReviewMergeAncestor = preReviewMergeAncestor
        }
    }

    /// One losing body which must exist as an ordinary backend record before its source
    /// is allowed to stop carrying the preservation metadata.
    struct ConflictRequirement: Equatable {
        var copyID: UUID
        var fingerprint: String
        /// Present for a secure losing body. Plain conflict copies are independent
        /// envelopes immediately and therefore have no source carrier to remove.
        var carrierKey: String?
        var carrierValue: CanonicalJSON.Value?
        /// Last authenticated/live local representation of the deterministic copy. It
        /// is retained even when the user deletes the copy before its first ACK, so the
        /// preservation write can finish before that deletion is released.
        var snapshot: SyncEnvelope?
        /// Dependency-owned and deliberately independent of `Entry.offered`: an edit,
        /// delete, or undo of the copy may advance ordinary intent but cannot replace
        /// the immutable prerequisite handed to the backend.
        var offered: Offered?
        /// Returned server generation for an accepted write of `snapshot` itself.
        /// This remains true when the backend later advances to an authenticated C1;
        /// provenance alone can never manufacture it.
        var acceptedRecordVersion: SyncRecordVersion?
    }

    /// Durable copy -> source edge. There is one edge per source and one requirement per
    /// independently mergeable losing body.
    struct ConflictDependency: Equatable {
        var sourceSnapshot: SyncEnvelope
        var requirements: [String: ConflictRequirement]
        /// The first source state released after every copy is confirmed. Keeping this
        /// offer separate lets a later edit/delete remain desired while an ambiguous
        /// carrier-free source write is retried exactly.
        var sourceOffered: Offered?
    }

    /// A conditional, content-preserving cleanup requested from primary storage. The
    /// bridge removes only these exact key/value pairs from the latest source record;
    /// every user field and every unrelated/future extension stays untouched.
    struct ConflictCarrierResolution: Equatable {
        var sourceID: UUID
        var expected: [String: CanonicalJSON.Value]
        var resolvedEnvelope: SyncEnvelope
    }

    /// Exact carrier recovery which is still owed to primary storage. The immutable C0
    /// bytes have already been published in this journal; `sources` are retained only
    /// to authenticate those bytes under the vault key, and `heldIntents` are later
    /// local C1/tombstone generations which must be reapplied in the same transaction.
    struct ConflictPrerequisiteRecovery: Equatable {
        var sources: [SyncEnvelope]
        var evidence: [SyncEnvelope]
        var heldIntents: [UUID: SyncEnvelope]
        var expectedPrimary: [UUID: SyncPrimaryState]
    }

    var schemaVersion: Int
    private(set) var entries: [String: Entry]
    private(set) var conflictDependencies: [String: ConflictDependency]
    /// Global identity of the reviewed snapshot whose per-entry two-phase ancestors are
    /// stored above. A changed explicit review clears/supersedes all older authority.
    private(set) var reviewedRecoveryFingerprint: String?
    /// Transient upgrade marker. Schema-1 bytes have no dependency map; the first engine
    /// reconciliation inspects current/base state before the file is rewritten as v2.
    private var needsDependencyMigration: Bool

    init(
        schemaVersion: Int = SyncJournal.currentSchemaVersion,
        entries: [String: Entry] = [:],
        conflictDependencies: [String: ConflictDependency] = [:],
        reviewedRecoveryFingerprint: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.conflictDependencies = conflictDependencies
        self.reviewedRecoveryFingerprint = reviewedRecoveryFingerprint
        needsDependencyMigration = schemaVersion < SyncJournal.currentSchemaVersion
    }

    func entry(_ id: UUID) -> Entry? {
        entries[SyncBase.key(id)]
    }

    func dependency(_ sourceID: UUID) -> ConflictDependency? {
        conflictDependencies[SyncBase.key(sourceID)]
    }

    /// Validates authoritative backend occupants before merge can treat them as
    /// ordinary snippets. Dependency-owned deterministic ids are reserved until the
    /// edge closes; an unrelated live record at one of those ids is a collision, not a
    /// competing content revision which may overwrite the local preservation copy.
    func validateDependencyOccupants(
        _ incoming: [UUID: SyncEnvelope]
    ) throws {
        for dependency in conflictDependencies.values {
            for requirement in dependency.requirements.values {
                guard let occupant = incoming[requirement.copyID], !occupant.deleted else {
                    continue
                }
                guard SyncMerge.hasValidConflictCopyIdentity(occupant),
                      SyncMerge.matchesConflictCopyProvenance(
                        occupant,
                        sourceID: dependency.sourceSnapshot.id,
                        fingerprint: requirement.fingerprint)
                else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
            }
        }
    }

    var requiresDependencyMigration: Bool { needsDependencyMigration }

    var carrierSourcesAwaitingMaterialization: [SyncEnvelope] {
        conflictDependencies.values.compactMap { dependency in
            let missing = dependency.requirements.values.filter {
                $0.carrierKey != nil && $0.snapshot == nil && $0.offered == nil
            }
            guard !missing.isEmpty else { return nil }
            // Feed the materializer only prerequisites which are still absent. A
            // satisfied sibling may since have been demoted/edited; revisiting every
            // carrier in the historical source would turn that legitimate occupant
            // into an identifier collision and permanently block scope maintenance.
            let missingKeys = Set(missing.compactMap(\.carrierKey))
            var filtered = dependency.sourceSnapshot
            filtered.x = filtered.x.filter {
                !SyncMerge.isContentConflictExtension($0.key)
                    || missingKeys.contains($0.key)
            }
            return filtered
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    var hasFrozenConflictPrerequisitesAwaitingPrimaryCheck: Bool {
        conflictDependencies.values.contains { dependency in
            dependency.requirements.values.contains {
                $0.carrierKey != nil
                    && $0.snapshot != nil
                    && $0.acceptedRecordVersion == nil
            }
        }
    }

    /// Device-local C0 receipts may be discarded only after a journal write has made
    /// the corresponding dependency completion/removal durable. Keeping this set on
    /// the journal makes that journal-first ordering explicit at the persistence seam.
    var activeConflictPrerequisiteCopyIDs: Set<UUID> {
        Set(conflictDependencies.values.flatMap {
            $0.requirements.values.map(\.copyID)
        })
    }

    /// Builds a recovery batch only for frozen, unaccepted secure C0 snapshots whose
    /// deterministic primary id is currently absent. A present C1/plain demotion is a
    /// later user generation and must never be overwritten by recovery. Once C0 has an
    /// acceptance receipt, primary absence is likewise a real local deletion which
    /// ordinary reconciliation turns into T instead of resurrecting C0.
    func conflictPrerequisiteRecovery(
        primaryStates: [UUID: SyncPrimaryState],
        installedHashes: [UUID: String] = [:]
    ) -> ConflictPrerequisiteRecovery {
        var sources: [SyncEnvelope] = []
        var evidence: [SyncEnvelope] = []
        var held: [UUID: SyncEnvelope] = [:]
        var expected: [UUID: SyncPrimaryState] = [:]

        for dependency in conflictDependencies.values.sorted(by: {
            $0.sourceSnapshot.id.uuidString < $1.sourceSnapshot.id.uuidString
        }) {
            let missing = dependency.requirements.values.filter { requirement in
                guard requirement.carrierKey != nil,
                      let snapshot = requirement.snapshot,
                      requirement.acceptedRecordVersion == nil,
                      !snapshot.deleted else { return false }
                // The receipt is committed atomically with C0 in the primary vault and
                // survives a later user deletion. Exact hash binding distinguishes that
                // real deletion from the pre-install crash shape, where recovery still
                // owes C0. A stale receipt for an earlier nonce/epoch proves nothing.
                if let installedHash = installedHashes[requirement.copyID],
                   (try? snapshot.envelopeHash()) == installedHash {
                    return false
                }
                // A durable post-C0 tombstone is the intended primary state. Recovery
                // still authenticates/offers frozen C0 from the journal, but must not
                // resurrect it merely to delete it again on every restart/reset.
                if entry(requirement.copyID)?.desired.deleted == true { return false }
                return (primaryStates[requirement.copyID] ?? .absent) == .absent
            }
            guard !missing.isEmpty else { continue }
            let keys = Set(missing.compactMap(\.carrierKey))
            var source = dependency.sourceSnapshot
            source.x = source.x.filter {
                !SyncMerge.isContentConflictExtension($0.key) || keys.contains($0.key)
            }
            sources.append(source)
            evidence.append(contentsOf: missing.compactMap(\.snapshot))
            for requirement in missing {
                expected[requirement.copyID] = primaryStates[requirement.copyID] ?? .absent
                if let intent = entry(requirement.copyID)?.desired {
                    held[requirement.copyID] = intent
                }
            }
        }
        return ConflictPrerequisiteRecovery(
            sources: sources,
            evidence: evidence.sorted { $0.id.uuidString < $1.id.uuidString },
            heldIntents: held,
            expectedPrimary: expected)
    }

    /// Converts primary absence into a durable deletion only when the primary-atomic
    /// receipt proves this exact C0 previously existed on this device. This runs before
    /// any recovery replay and before the first transport await, so a stale held C1 can
    /// never be re-applied over a deletion observed after a crash.
    mutating func reconcileInstalledConflictPrerequisiteAbsence(
        current: [UUID: SyncEnvelope],
        installedHashes: [UUID: String],
        confirmed: SyncBase,
        deviceID: String,
        now: Date
    ) throws {
        var candidate = entries
        for dependency in conflictDependencies.values {
            for requirement in dependency.requirements.values {
                guard let snapshot = requirement.snapshot,
                      !snapshot.deleted,
                      requirement.acceptedRecordVersion == nil,
                      let installedHash = installedHashes[requirement.copyID],
                      try snapshot.envelopeHash() == installedHash
                else { continue }

                if let occupant = current[requirement.copyID], !occupant.deleted {
                    guard SyncMerge.matchesConflictCopyProvenance(
                        occupant,
                        sourceID: dependency.sourceSnapshot.id,
                        fingerprint: requirement.fingerprint)
                    else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
                    continue
                }

                let key = SyncBase.key(requirement.copyID)
                if candidate[key]?.desired.deleted == true { continue }
                let previous = candidate[key]
                let confirmedEnvelope = confirmed.envelope(requirement.copyID)
                if let confirmedEnvelope, !confirmedEnvelope.deleted,
                   !SyncMerge.matchesConflictCopyProvenance(
                    confirmedEnvelope,
                    sourceID: dependency.sourceSnapshot.id,
                    fingerprint: requirement.fingerprint) {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                let source = Self.newestLive(
                    previous?.desired,
                    Self.newestLive(confirmedEnvelope, snapshot)) ?? snapshot
                let evidence = [
                    previous?.desired,
                    previous?.offered?.envelope,
                    confirmedEnvelope,
                    snapshot,
                ]
                    .compactMap { $0 }
                let tombstone = source.tombstoned(
                    hlc: Self.clock(
                        after: evidence.map(\.hlc),
                        deviceID: deviceID,
                        now: now),
                    origin: deviceID)
                candidate[key] = Entry(
                    desired: tombstone,
                    offered: previous?.offered,
                    generation: Self.nextGeneration(after: previous?.generation),
                    modifiedAt: now,
                    reviewedLocalAncestor: previous?.reviewedLocalAncestor,
                    reviewedLocalSnapshotKnown:
                        previous?.reviewedLocalSnapshotKnown ?? false,
                    preReviewMergeAncestor: previous?.preReviewMergeAncestor)
            }
        }
        entries = candidate
    }

    /// A fetched generation can disprove an old conditional source attempt without
    /// disproving the payload bytes (another peer may have written byte-identical E).
    /// Rebase only dependency-owned source offers whose bytes exactly match the new
    /// authoritative base. Different bytes remain frozen until normal merge/rejection.
    mutating func rebaseIdenticalSourceOffers(confirmed: SyncBase) {
        for key in Array(conflictDependencies.keys) {
            guard var dependency = conflictDependencies[key],
                  let offered = dependency.sourceOffered,
                  let confirmedEnvelope = confirmed.envelope(
                    dependency.sourceSnapshot.id),
                  let confirmedVersion = confirmed.recordVersion(
                    dependency.sourceSnapshot.id),
                  Self.sameVersion(offered.envelope, confirmedEnvelope),
                  offered.recordVersion != confirmedVersion
            else { continue }
            dependency.sourceOffered = Offered(
                envelope: offered.envelope,
                generation: offered.generation,
                recordVersion: confirmedVersion)
            conflictDependencies[key] = dependency
        }
    }

    /// Repairs the base-first crash window for prerequisite ACKs. This accepts only the
    /// exact dependency-owned offer at the exact durable server generation; a fetched
    /// C1 with matching provenance is deliberately insufficient.
    mutating func recoverAcceptedPrerequisiteOffers(confirmed: SyncBase) {
        for sourceKey in Array(conflictDependencies.keys) {
            guard var dependency = conflictDependencies[sourceKey] else { continue }
            for fingerprint in Array(dependency.requirements.keys) {
                guard var requirement = dependency.requirements[fingerprint],
                      requirement.acceptedRecordVersion == nil,
                      let offered = requirement.offered,
                      requirement.snapshot.map({
                        Self.sameVersion($0, offered.envelope)
                      }) == true,
                      Self.sameVersion(
                        offered.envelope, confirmed.envelope(requirement.copyID)),
                      let version = confirmed.recordVersion(requirement.copyID)
                else { continue }
                requirement.acceptedRecordVersion = version
                requirement.offered = nil
                dependency.requirements[fingerprint] = requirement
            }
            conflictDependencies[sourceKey] = dependency
        }
    }

    /// Installs the copy-before-source edge before the merged records reach primary
    /// storage. If the process dies after this write but before `applyRemote`, refetch
    /// recreates the same deterministic copies; if it dies after apply, the journal is
    /// already able to withhold the source.
    mutating func stageConflictDependency(
        source: SyncEnvelope,
        conflictCopies: [SyncEnvelope]
    ) throws {
        var additions: [String: ConflictRequirement] = [:]

        for variant in try SyncMerge.secureContentConflictVariants(in: source) {
            guard let value = source.x[variant.extensionKey] else {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
            additions[variant.fingerprint] = ConflictRequirement(
                copyID: variant.copyID,
                fingerprint: variant.fingerprint,
                carrierKey: variant.extensionKey,
                carrierValue: value,
                snapshot: nil,
                offered: nil,
                acceptedRecordVersion: nil)
        }

        for copy in conflictCopies {
            guard let provenance = SyncMerge.conflictCopyProvenance(in: copy),
                  provenance.sourceID == source.id,
                  SyncMerge.hasValidConflictCopyIdentity(copy) else {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
            additions[provenance.fingerprint] = ConflictRequirement(
                copyID: copy.id,
                fingerprint: provenance.fingerprint,
                carrierKey: nil,
                carrierValue: nil,
                snapshot: copy,
                offered: nil,
                acceptedRecordVersion: nil)
        }

        guard !additions.isEmpty else { return }
        let key = SyncBase.key(source.id)
        var dependency = conflictDependencies[key] ?? ConflictDependency(
            sourceSnapshot: source,
            requirements: [:],
            sourceOffered: nil)
        guard dependency.sourceSnapshot.id == source.id else {
            throw SyncMerge.EnvelopeFailure.malformedContentConflict
        }

        // Keep a monotonic recovery snapshot. A later conflict (or the last, older v1
        // migration candidate) may omit an active carrier that has not reached primary
        // copy storage yet. Preserve that exact member while adopting the newest source
        // envelope; reconcile retires it only after a CAS-confirmed copy proves the
        // losing body is independently durable. This makes the stage→apply crash window
        // both decoder-valid and materialisable.
        let keepExistingSnapshot = dependency.sourceSnapshot.hlc > source.hlc
        var recoverySource = keepExistingSnapshot ? dependency.sourceSnapshot : source
        let alternateSource = keepExistingSnapshot ? source : dependency.sourceSnapshot
        for (carrierKey, carrierValue) in alternateSource.x where
            SyncMerge.isContentConflictExtension(carrierKey) {
            if let replacement = recoverySource.x[carrierKey] {
                guard replacement == carrierValue else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
            } else {
                // Unknown versions are opaque causal evidence. An older build may carry
                // them forward but is never authorized to erase them merely because a
                // newer source candidate omitted the member.
                recoverySource.x[carrierKey] = carrierValue
            }
        }
        for existing in dependency.requirements.values {
            guard let carrierKey = existing.carrierKey,
                  let carrierValue = existing.carrierValue else { continue }
            if let replacement = recoverySource.x[carrierKey] {
                guard replacement == carrierValue else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
            } else {
                recoverySource.x[carrierKey] = carrierValue
            }
        }
        for addition in additions.values {
            guard let carrierKey = addition.carrierKey,
                  let carrierValue = addition.carrierValue else { continue }
            if let replacement = recoverySource.x[carrierKey] {
                guard replacement == carrierValue else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
            } else {
                recoverySource.x[carrierKey] = carrierValue
            }
        }
        try SyncMerge.validateContentConflictExtensions(in: recoverySource)
        dependency.sourceSnapshot = recoverySource
        var invalidatesSourceEpoch = false
        for (fingerprint, addition) in additions {
            if let existing = dependency.requirements[fingerprint] {
                guard existing.copyID == addition.copyID else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                if let additionKey = addition.carrierKey,
                   let additionValue = addition.carrierValue {
                    if let existingKey = existing.carrierKey,
                       let existingValue = existing.carrierValue {
                        guard existingKey == additionKey,
                              existingValue == additionValue else {
                            throw SyncMerge.EnvelopeFailure.malformedContentConflict
                        }
                    } else {
                        // Exact redelivery of a retired secure member re-opens cleanup;
                        // fingerprint/copyID and the strict carrier parser authenticate
                        // that this is the same prerequisite, not a plain-copy collision.
                        dependency.requirements[fingerprint]?.carrierKey = additionKey
                        dependency.requirements[fingerprint]?.carrierValue = additionValue
                        invalidatesSourceEpoch = true
                    }
                } else if existing.carrierKey != nil {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                if existing.snapshot == nil {
                    dependency.requirements[fingerprint]?.snapshot = addition.snapshot
                }
            } else {
                dependency.requirements[fingerprint] = addition
                invalidatesSourceEpoch = true
            }
        }
        if invalidatesSourceEpoch {
            // A source release orders only the prerequisite set that existed when it
            // was offered. A newly introduced (or re-opened) carrier starts another
            // copy-before-source epoch and therefore invalidates that exact offer.
            dependency.sourceOffered = nil
        }
        conflictDependencies[key] = dependency
        schemaVersion = Self.currentSchemaVersion
        needsDependencyMigration = false
    }

    /// Refreshes prerequisite snapshots from primary storage and upgrades schema-1
    /// journals conservatively. This operation never treats a plain id match as proof:
    /// the exact provenance tuple must still be present.
    mutating func reconcileDependencies(
        current: [UUID: SyncEnvelope],
        confirmed: SyncBase,
        acceptedSourceIDs: Set<UUID> = [],
        discoverSecureCarriers: Bool = true
    ) throws {
        if needsDependencyMigration {
            let candidates = Array(current.values)
                + Array(confirmed.envelopes.values)
                + entries.values.map(\.desired)
                + entries.values.compactMap { $0.offered?.envelope }
            if discoverSecureCarriers {
                for source in candidates where
                    SyncMerge.hasUnresolvedContentConflict(source) {
                    try stageConflictDependency(source: source, conflictCopies: [])
                }
            }
            for copy in candidates {
                guard let provenance = SyncMerge.conflictCopyProvenance(in: copy) else { continue }
                let source = current[provenance.sourceID]
                    ?? entries[SyncBase.key(provenance.sourceID)]?.desired
                    ?? confirmed.envelope(provenance.sourceID)
                guard let source else { continue }
                try stageConflictDependency(source: source, conflictCopies: [copy])
            }
            schemaVersion = Self.currentSchemaVersion
            needsDependencyMigration = false
        }

        // Primary storage can change while transport is awaited (macOS also supports
        // external writers). Discover every understood carrier on every reread, not
        // only during the schema-1 migration. This must happen before an acceptance
        // receipt is considered: a newly restored C2 member starts a larger epoch and
        // invalidates the C1-only source release.
        if discoverSecureCarriers {
            for source in current.values where
                !(try SyncMerge.secureContentConflictVariants(in: source)).isEmpty {
                try stageConflictDependency(source: source, conflictCopies: [])
            }
        }
        // A plain source has no carrier, so an externally restored pair is discovered
        // through its strict deterministic provenance. Do not recreate an already
        // completed edge: both records having backend generations means this can be an
        // ordinary, previously ordered copy. An unconfirmed member is precisely the
        // unsafe shape which still needs copy-before-source sequencing.
        for copy in current.values where
            !copy.deleted && SyncMerge.hasValidConflictCopyIdentity(copy) {
            guard let provenance = SyncMerge.conflictCopyProvenance(in: copy),
                  conflictDependencies[SyncBase.key(provenance.sourceID)] == nil,
                  entries[SyncBase.key(copy.id)].map({
                      !Self.sameVersion($0.desired, copy)
                  }) ?? true,
                  let source = current[provenance.sourceID], !source.deleted,
                  !(confirmed.recordVersion(copy.id) != nil
                    && confirmed.recordVersion(source.id) != nil
                    && Self.sameVersion(copy, confirmed.envelope(copy.id))
                    && Self.sameVersion(source, confirmed.envelope(source.id)))
            else { continue }
            try stageConflictDependency(source: source, conflictCopies: [copy])
        }
        for sourceKey in Array(conflictDependencies.keys) {
            guard var dependency = conflictDependencies[sourceKey] else { continue }
            for fingerprint in Array(dependency.requirements.keys) {
                guard var requirement = dependency.requirements[fingerprint] else { continue }
                if let occupant = current[requirement.copyID], !occupant.deleted,
                   !SyncMerge.matchesConflictCopyProvenance(
                    occupant,
                    sourceID: dependency.sourceSnapshot.id,
                    fingerprint: requirement.fingerprint) {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                if let occupant = confirmed.envelope(requirement.copyID),
                   !occupant.deleted,
                   !SyncMerge.matchesConflictCopyProvenance(
                    occupant,
                    sourceID: dependency.sourceSnapshot.id,
                    fingerprint: requirement.fingerprint) {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                // A plain losing snapshot is immutable from the moment the edge is
                // staged. For secure variants `nil` means materialisation has not yet
                // happened; fill that one slot exactly once from authenticated primary
                // storage, then retain it across edits/deletes until the first ACK.
                if requirement.carrierKey == nil,
                   requirement.snapshot == nil,
                   requirement.offered == nil,
                   let local = current[requirement.copyID]
                    ?? confirmed.envelope(requirement.copyID),
                   !local.deleted,
                   SyncMerge.matchesConflictCopyProvenance(
                    local,
                    sourceID: dependency.sourceSnapshot.id,
                    fingerprint: requirement.fingerprint) {
                    requirement.snapshot = local
                }
                // Exact frozen C0 in the durable base is itself the preservation fact.
                // This also heals base-first crashes and schema-2 journals. A C1 or a
                // tombstone never compares equal to the immutable snapshot.
                if requirement.acceptedRecordVersion == nil,
                   let snapshot = requirement.snapshot,
                   Self.sameVersion(snapshot, confirmed.envelope(requirement.copyID)),
                   let version = confirmed.recordVersion(requirement.copyID) {
                    requirement.acceptedRecordVersion = version
                    if requirement.offered.map({
                        Self.sameVersion($0.envelope, snapshot)
                    }) == true {
                        requirement.offered = nil
                    }
                }
                // Once this exact copy has a CAS generation in the durable base, an
                // absent carrier in the latest primary source means its cleanup barrier
                // completed. Retire only the active member; keep the immutable copy
                // proof in the dependency until the later source CAS is acknowledged.
                // A same key with different bytes is corruption/concurrent collision,
                // never evidence of cleanup.
                if let carrierKey = requirement.carrierKey,
                   let carrierValue = requirement.carrierValue,
                   requirementConfirmed(
                    requirement,
                    sourceID: dependency.sourceSnapshot.id,
                    in: confirmed),
                   let localSource = current[dependency.sourceSnapshot.id],
                   !localSource.deleted {
                    if let currentValue = localSource.x[carrierKey] {
                        guard currentValue == carrierValue else {
                            throw SyncMerge.EnvelopeFailure.malformedContentConflict
                        }
                    } else {
                        requirement.carrierKey = nil
                        requirement.carrierValue = nil
                    }
                }
                // A retired member can reappear from restored/stale primary projection
                // even without a fresh inbox event. Its fingerprint and deterministic
                // copy id authenticate the exact v1 member; reactivate cleanup so the
                // old carrier cannot outlive the dependency barrier.
                if requirement.carrierKey == nil,
                   requirement.carrierValue == nil,
                   let localSource = current[dependency.sourceSnapshot.id],
                   let key = localSource.x.keys.first(where: {
                       $0 == SyncMerge.contentConflictV1ExtensionPrefix
                            + requirement.fingerprint
                   }),
                   let value = localSource.x[key],
                   let variant = try? SyncMerge.secureContentConflictVariants(
                    in: localSource).first(where: {
                        $0.fingerprint == requirement.fingerprint
                    }),
                   variant.copyID == requirement.copyID {
                    requirement.carrierKey = key
                    requirement.carrierValue = value
                    // An earlier source offer proves only the prior cleanup epoch. Once
                    // that exact offer is confirmed, reopening starts a new source CAS.
                    if let offered = dependency.sourceOffered,
                       confirmed.recordVersion(localSource.id) != nil,
                       Self.sameVersion(
                        offered.envelope, confirmed.envelope(localSource.id)) {
                        dependency.sourceOffered = nil
                    }
                }
                if requirement.carrierKey != nil,
                   let localSource = current[dependency.sourceSnapshot.id],
                   !localSource.deleted,
                   let offered = dependency.sourceOffered,
                   offered.envelope.deleted,
                   confirmed.recordVersion(localSource.id) != nil,
                   Self.sameVersion(
                    offered.envelope, confirmed.envelope(localSource.id)) {
                    // The post-copy delete epoch completed, but primary storage now has
                    // a live recreation that still carries this member. Do not let the
                    // old tombstone proof prune the reopened edge; cleanup and CAS the
                    // live source in a fresh epoch first.
                    dependency.sourceOffered = nil
                }
                dependency.requirements[fingerprint] = requirement
            }
            // Before carrier cleanup, retain the carrier-bearing snapshot as recovery
            // material. Plain dependencies have no carrier and may safely track fresh
            // user fields until their source offer is frozen.
            if dependency.sourceOffered == nil,
               let local = current[dependency.sourceSnapshot.id] {
                let active = dependency.requirements.values.compactMap { requirement -> (
                    String, CanonicalJSON.Value
                )? in
                    guard let key = requirement.carrierKey,
                          let value = requirement.carrierValue else { return nil }
                    return (key, value)
                }
                if active.allSatisfy({ local.x[$0.0] == $0.1 }) {
                    // Every live recovery member is represented. Retired members are
                    // intentionally absent, so this transition is persisted atomically
                    // with their retirement and cannot create an unreadable v2 graph.
                    var refreshed = local
                    // Only understood v1 requirements may be retired here. Opaque
                    // future members are causal evidence owned by a newer protocol and
                    // must survive a frozen primary representation which cannot store
                    // them. Same-key disagreement is corruption, never LWW authority.
                    for (memberKey, memberValue) in dependency.sourceSnapshot.x where
                        SyncMerge.isContentConflictExtension(memberKey)
                            && !memberKey.hasPrefix(
                                SyncMerge.contentConflictV1ExtensionPrefix) {
                        if let replacement = refreshed.x[memberKey] {
                            guard replacement == memberValue else {
                                throw SyncMerge.EnvelopeFailure.malformedContentConflict
                            }
                        } else {
                            refreshed.x[memberKey] = memberValue
                        }
                    }
                    try SyncMerge.validateContentConflictExtensions(in: refreshed)
                    dependency.sourceSnapshot = refreshed
                }
            }
            conflictDependencies[sourceKey] = dependency
        }
        pruneConfirmedDependencies(
            confirmed: confirmed,
            acceptedSourceIDs: acceptedSourceIDs)
    }

    /// Resolutions whose copy prerequisites are durably proved. The engine passes these
    /// to the library's conditional primary-storage operation before it can calculate a
    /// carrier-free source offer.
    func carrierResolutions(
        current: [UUID: SyncEnvelope],
        confirmed: SyncBase
    ) -> [ConflictCarrierResolution] {
        conflictDependencies.values.compactMap { dependency in
            guard requirementsConfirmed(dependency, in: confirmed),
                  dependency.sourceOffered == nil,
                  let source = current[dependency.sourceSnapshot.id],
                  !source.deleted else { return nil }
            let expected = dependency.requirements.values.reduce(
                into: [String: CanonicalJSON.Value]()) { result, requirement in
                    if let key = requirement.carrierKey,
                       let value = requirement.carrierValue {
                        result[key] = value
                    }
                }
            guard !expected.isEmpty,
                  let resolved = SyncMerge.resolvingContentConflicts(
                    in: source, expected: expected) else { return nil }
            return ConflictCarrierResolution(
                sourceID: source.id,
                expected: expected,
                resolvedEnvelope: resolved)
        }.sorted { $0.sourceID.uuidString < $1.sourceID.uuidString }
    }

    /// Moves exact understood carrier removals into durable journal knowledge before
    /// primary cleanup. This is deliberately reversible by `reconcileDependencies`:
    /// if primary still carries an exact member (operation failed or the process died),
    /// the normal reread reopens it. No transport operation is allowed between this
    /// publication and that conditional cleanup/reread in `SyncEngine`.
    mutating func beginCarrierResolutions(
        _ resolutions: [ConflictCarrierResolution]
    ) throws {
        var candidateEntries = entries
        var candidateDependencies = conflictDependencies
        for resolution in resolutions {
            let sourceKey = SyncBase.key(resolution.sourceID)
            guard var dependency = candidateDependencies[sourceKey],
                  dependency.sourceOffered == nil else {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
            var removed = Set<String>()
            for fingerprint in Array(dependency.requirements.keys) {
                guard var requirement = dependency.requirements[fingerprint],
                      let key = requirement.carrierKey,
                      let value = requirement.carrierValue,
                      resolution.expected[key] == value else { continue }
                requirement.carrierKey = nil
                requirement.carrierValue = nil
                dependency.requirements[fingerprint] = requirement
                removed.insert(key)
            }
            guard removed == Set(resolution.expected.keys),
                  removed.allSatisfy({ dependency.sourceSnapshot.x[$0]
                    == resolution.expected[$0] }) else {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
            for key in removed { dependency.sourceSnapshot.x[key] = nil }
            try SyncMerge.validateContentConflictExtensions(
                in: dependency.sourceSnapshot)
            if var entry = candidateEntries[sourceKey] {
                if let offered = entry.offered,
                   removed.contains(where: { offered.envelope.x[$0] != nil }) {
                    guard removed.allSatisfy({ key in
                        offered.envelope.x[key].map {
                            $0 == resolution.expected[key]
                        } ?? true
                    }) else {
                        throw SyncMerge.EnvelopeFailure.malformedContentConflict
                    }
                    // Dependency ownership replaces a stale generic source offer. The
                    // desired generation remains intact and will be offered only after
                    // the copy-before-source barrier is satisfied.
                    entry.offered = nil
                }
                guard removed.allSatisfy({ key in
                    entry.desired.x[key].map { $0 == resolution.expected[key] } ?? true
                }) else {
                    throw SyncMerge.EnvelopeFailure.malformedContentConflict
                }
                for key in removed { entry.desired.x[key] = nil }
                candidateEntries[sourceKey] = entry
            }
            candidateDependencies[sourceKey] = dependency
        }
        entries = candidateEntries
        conflictDependencies = candidateDependencies
    }

    /// Later local values for implicit secure copies created by these carrier sources.
    /// They remain ordinary journal intent; returning them here does not acknowledge or
    /// otherwise advance either the copy prerequisite or its backend CAS generation.
    func heldConflictCopyIntents(
        forSourceIDs sourceIDs: Set<UUID>
    ) -> [UUID: SyncEnvelope] {
        var result: [UUID: SyncEnvelope] = [:]
        for dependency in conflictDependencies.values where
            sourceIDs.contains(dependency.sourceSnapshot.id) {
            for requirement in dependency.requirements.values {
                guard let desired = entry(requirement.copyID)?.desired else { continue }
                result[requirement.copyID] = desired
            }
        }
        return result
    }

    /// Freezes exact authenticated carrier-derived C0 bytes before primary apply can
    /// replace them with a later C1/tombstone. Evidence is accepted only by the existing
    /// deterministic dependency identity; it never creates an edge on its own.
    mutating func recordConflictCopyEvidence(
        _ evidence: [SyncEnvelope]
    ) throws {
        var candidate = conflictDependencies
        for envelope in evidence {
            guard !envelope.deleted,
                  SyncMerge.hasValidConflictCopyIdentity(envelope),
                  let provenance = SyncMerge.conflictCopyProvenance(in: envelope),
                  var dependency = candidate[SyncBase.key(provenance.sourceID)],
                  var requirement = dependency.requirements[provenance.fingerprint],
                  requirement.copyID == envelope.id,
                  SyncMerge.matchesConflictCopyProvenance(
                    envelope,
                    sourceID: dependency.sourceSnapshot.id,
                    fingerprint: requirement.fingerprint),
                  envelope.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                    == (try SyncMerge.secureContentConflictVariants(
                        in: dependency.sourceSnapshot).first {
                            $0.fingerprint == requirement.fingerprint
                        })?.sourceExtensions[SyncEnvelope.vaultKeyIDExtensionKey]?.text
            else {
                throw SyncMerge.EnvelopeFailure.malformedContentConflict
            }
            // AES-GCM resealing uses a fresh nonce. Once exact C0 bytes are frozen (or
            // offered), a later valid preparation proves the same carrier lineage but
            // must not replace the immutable transport snapshot with new ciphertext.
            if requirement.snapshot == nil, requirement.offered == nil {
                requirement.snapshot = envelope
            }
            dependency.requirements[provenance.fingerprint] = requirement
            candidate[SyncBase.key(provenance.sourceID)] = dependency
        }
        conflictDependencies = candidate
    }

    /// Retains a later C1/tombstone while the dependency deliberately overwrites the
    /// backend copy with immutable C0. Equality with today's fetched base is not enough
    /// to discard it: after C0 is accepted that later value has to be restored.
    mutating func holdPostPrerequisiteCopyIntents(
        _ envelopes: [SyncEnvelope],
        now: Date
    ) throws {
        var candidate = entries
        for envelope in envelopes {
            guard let owner = conflictRequirement(for: envelope.id) else { continue }
            if !envelope.deleted {
                guard SyncMerge.matchesConflictCopyProvenance(
                    envelope,
                    sourceID: owner.sourceID,
                    fingerprint: owner.requirement.fingerprint)
                else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
            }
            guard owner.requirement.snapshot.map({ !Self.sameVersion($0, envelope) }) == true
            else { continue }
            let key = SyncBase.key(envelope.id)
            let previous = candidate[key]
            let changed = !Self.sameVersion(previous?.desired, envelope)
            candidate[key] = Entry(
                desired: envelope,
                offered: previous?.offered,
                generation: changed
                    ? Self.nextGeneration(after: previous?.generation)
                    : (previous?.generation ?? 1),
                modifiedAt: changed ? now : (previous?.modifiedAt ?? now),
                reviewedLocalAncestor: previous?.reviewedLocalAncestor,
                reviewedLocalSnapshotKnown:
                    previous?.reviewedLocalSnapshotKnown ?? false,
                preReviewMergeAncestor: previous?.preReviewMergeAncestor)
        }
        entries = candidate
    }

    /// Returns the canonical already-frozen bytes for prepared evidence identities. This
    /// is used after a crash: a new preparation has a new AES-GCM nonce, but primary apply
    /// must use the exact snapshot which was durably published before the crash.
    func frozenConflictCopyEvidence(
        matching evidence: [SyncEnvelope]
    ) throws -> [SyncEnvelope] {
        try evidence.map { candidate in
            guard let provenance = SyncMerge.conflictCopyProvenance(in: candidate),
                  let frozen = dependency(provenance.sourceID)?
                    .requirements[provenance.fingerprint]?.snapshot,
                  frozen.id == candidate.id
            else { throw SyncMerge.EnvelopeFailure.malformedContentConflict }
            return frozen
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Exact immutable offer, regardless of whether ordinary user intent or a conflict
    /// dependency owns it.
    func offeredSnapshot(for envelope: SyncEnvelope) -> Offered? {
        for dependency in conflictDependencies.values {
            if let offered = dependency.sourceOffered,
               Self.sameVersion(offered.envelope, envelope) { return offered }
            for requirement in dependency.requirements.values {
                if let offered = requirement.offered,
                   Self.sameVersion(offered.envelope, envelope) { return offered }
            }
        }
        guard let offered = entry(envelope.id)?.offered,
              Self.sameVersion(offered.envelope, envelope) else { return nil }
        return offered
    }

    /// Reconciles live local files with confirmed and ambiguous protocol state.
    ///
    /// Absence becomes a deletion only when a live confirmed or offered value proves
    /// that this device has seen the record. Consequently a fresh install creates no
    /// tombstones, and a create removed before it was ever offered simply disappears.
    mutating func reconcile(
        current: [UUID: SyncEnvelope],
        confirmed: SyncBase,
        deviceID: String,
        now: Date,
        userInitiatedDeletionIDs: Set<UUID> = []
    ) {
        let ids = Set(current.keys)
            .union(confirmed.envelopes.values.map(\.id))
            .union(entries.values.map { $0.desired.id })
            .union(conflictDependencies.values.map { $0.sourceSnapshot.id })
            .union(conflictDependencies.values.flatMap {
                $0.requirements.values.map(\.copyID)
            })

        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let key = SyncBase.key(id)
            let previous = entries[key]
            let confirmedEnvelope = confirmed.envelope(id)

            // A crash after base.json was made durable but before the journal was
            // acknowledged leaves this exact shape. The durable base is sufficient
            // proof to finish the acknowledgement idempotently on restart.
            var offered = previous?.offered
            if let snapshot = offered?.envelope,
               Self.sameVersion(snapshot, confirmedEnvelope) {
                offered = nil
            }

            let desired: SyncEnvelope?
            if let local = current[id] {
                // Generic reconciliation cannot distinguish a byte-identical protocol
                // replay from an exact user Undo. Protocol materialization is therefore
                // handled explicitly and atomically at the bridge boundary; every live
                // primary value observed here is genuine local intent.
                desired = Self.restampedIfNeeded(
                    local,
                    previousDesired: previous?.desired,
                    offered: offered?.envelope,
                    confirmed: confirmedEnvelope,
                    deviceID: deviceID,
                    now: now)
            } else if let previousDesired = previous?.desired,
                      previousDesired.deleted {
                // Reconciliation may run repeatedly while an offer is in flight. Reuse
                // the one deletion event rather than minting a new clock every time.
                desired = previousDesired
            } else if conflictDependencies[key] == nil,
                      let protected = [previous?.desired, offered?.envelope, confirmedEnvelope]
                .compactMap({ $0 })
                .filter({ SyncMerge.hasUnresolvedContentConflict($0) })
                .max(by: { $0.hlc < $1.hlc }) {
                // A secure losing version is still encrypted under this source id.
                // Turning the only envelope carrying it into a body-free tombstone
                // would be irreversible. Keep the live value until a key-aware layer
                // materialises/resolves its variants; deletion is intentionally held.
                desired = protected
            } else if let existenceProof = Self.newestLive(
                offered?.envelope,
                Self.newestLive(
                    confirmedEnvelope,
                    Self.newestLive(
                        (!isDependencyOwned(id)
                            && previous?.reviewedLocalExistence != true)
                            ? nil : previous?.desired,
                        conflictExistenceProof(for: id)))) {
                let evidence = [previous?.desired, offered?.envelope, confirmedEnvelope]
                    .compactMap { $0 }
                // Offered/confirmed state proves that something may exist remotely;
                // once that proof exists, tombstone the newest local representation so
                // a promote/demote or newly learned vault scope is not rolled back.
                let deletionSource = Self.newestLive(
                    previous?.desired, existenceProof) ?? existenceProof
                desired = deletionSource.tombstoned(
                    hlc: Self.clock(after: evidence.map(\.hlc), deviceID: deviceID, now: now),
                    origin: deviceID)
            } else if let offeredEnvelope = offered?.envelope,
                      offeredEnvelope.deleted {
                // A tombstone handed to the transport remains desired until its exact
                // snapshot is either confirmed or rejected.
                desired = offeredEnvelope
            } else {
                // No confirmed/offered live value means an absent local create never
                // escaped this device. There is nothing remote to delete.
                desired = nil
            }

            guard var desired else {
                entries[key] = nil
                continue
            }

            // The delete action itself is the user's review. Bind that intent to every
            // exact live ancestor this journal knows the action may be removing. The
            // confirmed hash lets an ordinary peer recognize the permission; newer
            // desired/offered hashes cover a delete of an edit whose ACK is pending.
            // A replay after recreation cannot match the recreated envelope and stays
            // behind the mass-deletion breaker.
            if desired.deleted,
               userInitiatedDeletionIDs.contains(id),
               !desired.carriesUserInitiatedDeletion {
                let ancestorHashes = Set([
                    previous?.desired,
                    offered?.envelope,
                    confirmedEnvelope,
                    previous?.reviewedLocalAncestor,
                    conflictExistenceProof(for: id),
                ].compactMap { envelope -> String? in
                    guard let envelope, !envelope.deleted else { return nil }
                    return try? envelope.envelopeHash()
                }).sorted()
                if !ancestorHashes.isEmpty {
                    desired.x[SyncEnvelope.userInitiatedDeletionExtensionKey] = .array(
                        ancestorHashes.prefix(8).map(CanonicalJSON.Value.string))
                }
            }

            if offered == nil,
               Self.sameVersion(desired, confirmedEnvelope),
               !mustRetainPostPrerequisiteIntent(desired) {
                entries[key] = nil
                continue
            }

            let desiredChanged = !Self.sameVersion(desired, previous?.desired)
            let generation: UInt64
            if let previous, !desiredChanged {
                generation = previous.generation
            } else {
                generation = Self.nextGeneration(after: previous?.generation)
            }
            let modifiedAt = desiredChanged ? now : (previous?.modifiedAt ?? now)
            entries[key] = Entry(
                desired: desired,
                offered: offered,
                generation: generation,
                modifiedAt: modifiedAt,
                reviewedLocalAncestor: previous?.reviewedLocalAncestor,
                reviewedLocalSnapshotKnown:
                    previous?.reviewedLocalSnapshotKnown ?? false,
                preReviewMergeAncestor: previous?.preReviewMergeAncestor)
        }
    }

    /// Snapshots ready for transport, in deterministic record-id order.
    ///
    /// An ambiguous offer takes precedence over a newer desired state. Advancing to the
    /// newer value before resolving the older one loses the only tentative ancestor
    /// capable of distinguishing our own server echo from an independent remote edit.
    func pending(confirmed: SyncBase) -> [SyncEnvelope] {
        var resultByID: [UUID: SyncEnvelope] = [:]
        var blockedIDs = Set<UUID>()

        for dependency in conflictDependencies.values {
            let sourceID = dependency.sourceSnapshot.id
            let copiesConfirmed = requirementsConfirmed(dependency, in: confirmed)

            if !copiesConfirmed {
                blockedIDs.insert(sourceID)
                for requirement in dependency.requirements.values {
                    blockedIDs.insert(requirement.copyID)
                    if let offered = requirement.offered,
                       !Self.sameVersion(
                        offered.envelope, confirmed.envelope(requirement.copyID)) {
                        resultByID[requirement.copyID] = offered.envelope
                    } else if !requirementConfirmed(
                        requirement, sourceID: sourceID, in: confirmed),
                              let snapshot = requirement.snapshot {
                        resultByID[requirement.copyID] = snapshot
                    }
                }
                continue
            }

            // Once every prerequisite is confirmed, the edge still exclusively owns
            // source and copy ids until its post-copy source offer is itself confirmed.
            // This also covers a temporarily unavailable release: ordinary copy delete
            // intent must not leak through and make the prerequisite false again.
            blockedIDs.insert(sourceID)
            blockedIDs.formUnion(dependency.requirements.values.map(\.copyID))

            // The dependency's exact source release is a second barrier. A source
            // deletion is allowed here, but copy deletion remains held until that source
            // state has been confirmed, preventing an arbitrary accepted prefix from
            // deleting the copy while an old carrier is still authoritative.
            if let offered = dependency.sourceOffered,
               !Self.sameVersion(offered.envelope, confirmed.envelope(sourceID)) {
                resultByID[sourceID] = offered.envelope
            } else if let entry = entries[SyncBase.key(sourceID)],
                      !SyncMerge.hasUnresolvedContentConflict(entry.desired),
                      !Self.sameVersion(entry.desired, confirmed.envelope(sourceID)) {
                resultByID[sourceID] = entry.desired
            } else if let currentSource = dependencySourceRelease(
                dependency, confirmed: confirmed) {
                resultByID[sourceID] = currentSource
            }
        }

        for entry in entries.values where !blockedIDs.contains(entry.desired.id) {
            if let offered = entry.offered,
               !Self.sameVersion(offered.envelope, confirmed.envelope(offered.envelope.id)) {
                resultByID[offered.envelope.id] = offered.envelope
                continue
            }
            guard !Self.sameVersion(entry.desired, confirmed.envelope(entry.desired.id)) else {
                continue
            }
            resultByID[entry.desired.id] = entry.desired
        }
        return resultByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Durably called before the corresponding snapshots are handed to a transport.
    /// Existing unresolved offers are deliberately immutable.
    mutating func markOffered(
        _ envelopes: [SyncEnvelope],
        confirmed: SyncBase? = nil
    ) {
        for envelope in envelopes {
            var dependencyHandled = false
            for sourceKey in Array(conflictDependencies.keys) {
                guard var dependency = conflictDependencies[sourceKey] else { continue }
                if dependency.sourceSnapshot.id == envelope.id,
                   requirementsConfirmed(dependency, in: confirmed ?? SyncBase()),
                   dependency.sourceOffered == nil,
                   !SyncMerge.hasUnresolvedContentConflict(envelope) {
                    let generation = entries[SyncBase.key(envelope.id)]?.generation ?? 1
                    dependency.sourceOffered = Offered(
                        envelope: envelope,
                        generation: generation,
                        recordVersion: confirmed?.recordVersion(envelope.id))
                    conflictDependencies[sourceKey] = dependency
                    dependencyHandled = true
                    break
                }
                for fingerprint in Array(dependency.requirements.keys) {
                    guard var requirement = dependency.requirements[fingerprint],
                          requirement.copyID == envelope.id,
                          requirement.offered == nil,
                          requirement.snapshot.map({ Self.sameVersion($0, envelope) }) == true
                    else { continue }
                    requirement.offered = Offered(
                        envelope: envelope,
                        generation: 1,
                        recordVersion: confirmed?.recordVersion(envelope.id))
                    dependency.requirements[fingerprint] = requirement
                    conflictDependencies[sourceKey] = dependency
                    dependencyHandled = true
                    break
                }
                if dependencyHandled { break }
            }
            if dependencyHandled { continue }

            let key = SyncBase.key(envelope.id)
            guard var entry = entries[key], entry.offered == nil,
                  Self.sameVersion(entry.desired, envelope) else { continue }
            entry.offered = Offered(
                envelope: envelope,
                generation: entry.generation,
                recordVersion: confirmed?.recordVersion(envelope.id))
            entries[key] = entry
        }
    }

    /// Clears only offers whose exact snapshot is already present in the confirmed
    /// base. The caller must persist that base before invoking this method.
    mutating func acknowledge(_ ids: [UUID], confirmed: SyncBase) {
        for id in ids {
            for sourceKey in Array(conflictDependencies.keys) {
                guard var dependency = conflictDependencies[sourceKey] else { continue }
                if let offered = dependency.sourceOffered,
                   offered.envelope.id == id,
                   Self.sameVersion(offered.envelope, confirmed.envelope(id)) {
                    // Keep the exact offer until `pruneConfirmedDependencies` removes
                    // the whole edge. On a restart this is the only proof that the
                    // confirmed source write happened *after* its copy prerequisites,
                    // rather than being an older carrier-free base value.
                    dependency.sourceOffered = offered
                }
                for fingerprint in Array(dependency.requirements.keys) {
                    guard var requirement = dependency.requirements[fingerprint],
                          let offered = requirement.offered,
                          offered.envelope.id == id,
                          Self.sameVersion(offered.envelope, confirmed.envelope(id))
                    else { continue }
                    if requirement.snapshot.map({
                        Self.sameVersion($0, offered.envelope)
                    }) == true,
                       let acceptedVersion = confirmed.recordVersion(id) {
                        requirement.acceptedRecordVersion = acceptedVersion
                    }
                    requirement.offered = nil
                    dependency.requirements[fingerprint] = requirement
                }
                conflictDependencies[sourceKey] = dependency
            }
            let key = SyncBase.key(id)
            guard var entry = entries[key], let offered = entry.offered,
                  Self.sameVersion(offered.envelope, confirmed.envelope(id)) else { continue }

            entry.offered = nil
            if Self.sameVersion(entry.desired, confirmed.envelope(id)) {
                entries[key] = nil
            } else {
                entries[key] = entry
            }
        }
        // Do not prune here. The backend acknowledgement can arrive while primary
        // storage changes during the awaited submit (for example an exact secure
        // carrier is restored locally). Only `reconcileDependencies`, after rereading
        // that primary state, may decide that the source fence is complete.
    }

    /// An authoritative fetch proved that the currently offered snapshot was not the
    /// accepted server value. Keep the latest desired generation and permit it to be
    /// offered on the next round.
    mutating func reject(_ ids: [UUID]) {
        for id in ids {
            for sourceKey in Array(conflictDependencies.keys) {
                guard var dependency = conflictDependencies[sourceKey] else { continue }
                if dependency.sourceOffered?.envelope.id == id {
                    dependency.sourceOffered = nil
                }
                for fingerprint in Array(dependency.requirements.keys) {
                    guard var requirement = dependency.requirements[fingerprint],
                          requirement.offered?.envelope.id == id else { continue }
                    requirement.offered = nil
                    dependency.requirements[fingerprint] = requirement
                }
                conflictDependencies[sourceKey] = dependency
            }
            let key = SyncBase.key(id)
            guard var entry = entries[key] else { continue }
            entry.offered = nil
            entries[key] = entry
        }
    }

    /// Before a transport-key reset clears the confirmed base, every confirmed envelope
    /// becomes an exact offer to be resealed under the new key. Existing ambiguous offers
    /// and newer desired generations take precedence and are never replaced.
    mutating func stageConfirmedForTransportRekey(
        _ confirmed: SyncBase,
        now: Date
    ) {
        let dependencyOwnedIDs = Set(conflictDependencies.values.flatMap { dependency in
            [dependency.sourceSnapshot.id] + dependency.requirements.values.map(\.copyID)
        })

        // Dependency ids already have their own ordered offers. Refresh a confirmed
        // prerequisite to the latest provenance-bearing server value (which may include
        // user edits made after the frozen generated snapshot), then clear its old
        // backend-scoped offer so the empty replacement base reoffers it under the new
        // wire key. The source remains dependency-owned too: pending chooses the latest
        // ordinary desired release, never a generic stale confirmed ancestor.
        for sourceKey in Array(conflictDependencies.keys) {
            guard var dependency = conflictDependencies[sourceKey] else { continue }
            dependency.sourceOffered = nil
            for fingerprint in Array(dependency.requirements.keys) {
                guard var requirement = dependency.requirements[fingerprint] else { continue }
                requirement.acceptedRecordVersion = nil
                requirement.offered = nil
                dependency.requirements[fingerprint] = requirement
            }
            conflictDependencies[sourceKey] = dependency
        }

        // An id protected by the dependency graph must have exactly one owner during
        // the replacement key epoch. A schema-1 migration or crash can leave an older
        // ordinary offer beside the edge (for example C0/S0 while confirmed storage is
        // already C1 and ordinary desired intent is E). Retaining that generic offer
        // would make it visible again as soon as C1 -> E completes and the edge is
        // pruned, rolling both records backwards. The full-resync CAS generations keep
        // any genuinely newer server value safe; preserve `desired`, but retire the old
        // backend-scoped ordinary offer in favour of the dependency-owned sequence.
        for id in dependencyOwnedIDs {
            let key = SyncBase.key(id)
            guard var entry = entries[key] else { continue }
            entry.offered = nil
            entries[key] = entry
        }

        for envelope in confirmed.envelopes.values.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            guard !dependencyOwnedIDs.contains(envelope.id) else { continue }
            let key = SyncBase.key(envelope.id)
            if var entry = entries[key] {
                if entry.offered == nil {
                    entry.offered = Offered(
                        envelope: envelope,
                        generation: entry.generation,
                        recordVersion: confirmed.recordVersion(envelope.id))
                    entries[key] = entry
                }
            } else {
                entries[key] = Entry(
                    desired: envelope,
                    offered: Offered(
                        envelope: envelope,
                        generation: 1,
                        recordVersion: confirmed.recordVersion(envelope.id)),
                    generation: 1,
                    modifiedAt: now)
            }
        }
    }

    /// Re-establishes completed plain copy -> source edges at an intentional backend
    /// scope boundary. Ordinary reconciliation must leave a fully acknowledged pair
    /// quiescent; a replacement account or transport epoch is different because both
    /// records must be uploaded again and their old ordering proof no longer applies.
    private mutating func recoverPlainDependenciesForScopeReset(
        current: [UUID: SyncEnvelope],
        confirmedSourceFallback: SyncBase? = nil
    ) throws {
        for copy in current.values.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) where !copy.deleted && SyncMerge.hasValidConflictCopyIdentity(copy) {
            guard let provenance = SyncMerge.conflictCopyProvenance(in: copy),
                  conflictDependencies[SyncBase.key(provenance.sourceID)] == nil,
                  let source = current[provenance.sourceID]
                    ?? confirmedSourceFallback?.envelope(provenance.sourceID)
            else { continue }
            try stageConflictDependency(source: source, conflictCopies: [copy])
        }
    }

    /// Prepares a reviewed transport-key epoch replacement. Unlike the lower-level
    /// staging primitive, this entry point has the primary snapshot needed to recover
    /// already-completed plain dependencies before their records are resealed.
    mutating func prepareForTransportRekey(
        current: [UUID: SyncEnvelope],
        confirmed: SyncBase,
        now: Date
    ) throws {
        try reconcileDependencies(current: current, confirmed: confirmed)
        // A completed pair may already have a confirmed source tombstone, so primary
        // storage legitimately contains only C. Rekey still has to reseal C before E:
        // accepting E first could leave the sole losing body encrypted under the old
        // transport key. The old confirmed tombstone is valid only for this same-scope
        // key epoch replacement, never as local intent for an account migration.
        try recoverPlainDependenciesForScopeReset(
            current: current,
            confirmedSourceFallback: confirmed)
        stageConfirmedForTransportRekey(confirmed, now: now)
    }

    /// Rebuilds pending intent at an explicitly reviewed backend-account boundary.
    ///
    /// First reconcile against the old checkpoint so an edit or deletion that existed
    /// only in primary storage becomes durable. Then discard every old-account offer:
    /// neither its acknowledgement ambiguity nor its per-record CAS generation has any
    /// meaning in the new private database. All live local values are materialized as
    /// desired entries because the replacement base will intentionally be empty.
    mutating func prepareForAccountChange(
        current: [UUID: SyncEnvelope],
        confirmed: SyncBase,
        deviceID: String,
        now: Date,
        discoverSecureCarriers: Bool = true
    ) throws {
        try reconcileDependencies(
            current: current,
            confirmed: confirmed,
            discoverSecureCarriers: discoverSecureCarriers)
        try recoverPlainDependenciesForScopeReset(current: current)
        guard conflictDependencies.values.allSatisfy({ dependency in
            dependency.requirements.values.allSatisfy {
                $0.snapshot != nil || $0.offered != nil
            }
        }) else {
            // A carrier-only secure requirement has not reached primary storage yet.
            // Clearing the old account's base/inbox now would erase the only event able
            // to materialise it and leave the source permanently fenced in a new empty
            // database. The reviewed reset must wait for an ordinary round to finish it.
            throw SyncMerge.EnvelopeFailure.malformedContentConflict
        }
        reconcile(
            current: current,
            confirmed: confirmed,
            deviceID: deviceID,
            now: now)

        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            entry.offered = nil
            // A reviewed local ancestor is causal authority only inside the backend
            // membership where it was captured. Carrying it into another account can
            // make a same-UUID tombstone delete an unrelated record there.
            entry.reviewedLocalAncestor = nil
            entry.reviewedLocalSnapshotKnown = false
            entry.preReviewMergeAncestor = nil
            entries[key] = entry
        }
        reviewedRecoveryFingerprint = nil
        // Backend generations and ambiguity do not cross an account boundary. Retain
        // dependency snapshots, but require every prerequisite and source release to be
        // offered afresh in the replacement private database.
        for key in Array(conflictDependencies.keys) {
            guard var dependency = conflictDependencies[key] else { continue }
            dependency.sourceOffered = nil
            for fingerprint in Array(dependency.requirements.keys) {
                dependency.requirements[fingerprint]?.acceptedRecordVersion = nil
                dependency.requirements[fingerprint]?.offered = nil
            }
            conflictDependencies[key] = dependency
        }

        for envelope in current.values.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            let key = SyncBase.key(envelope.id)
            guard entries[key] == nil else { continue }
            entries[key] = Entry(
                desired: envelope,
                offered: nil,
                generation: 1,
                modifiedAt: now)
        }
    }

    /// Rebuilds outbound intent after an unreadable primary library was replaced with a
    /// readable recovery candidate.
    ///
    /// The candidate may be a partial export, a backup from another moment, or even a
    /// starter file written by an older downgraded build. Its present values are useful
    /// local intent; its absences are not proof of deletion. Preserve already-durable
    /// journal intent, add every recovered current value, clear old offers/generations,
    /// and deliberately reconcile against an empty ancestor so no old-base absence can
    /// become a tombstone. A subsequent full fetch merges remote-only records back in.
    mutating func prepareForNonDestructiveLibraryRecovery(
        current: [UUID: SyncEnvelope],
        confirmed: SyncBase,
        deviceID: String,
        now: Date,
        discoverSecureCarriers: Bool = true
    ) throws {
        try reconcileDependencies(
            current: current,
            confirmed: confirmed,
            discoverSecureCarriers: discoverSecureCarriers)
        try recoverPlainDependenciesForScopeReset(current: current)
        guard conflictDependencies.values.allSatisfy({ dependency in
            dependency.requirements.values.allSatisfy {
                $0.snapshot != nil || $0.offered != nil
            }
        }) else {
            throw SyncMerge.EnvelopeFailure.malformedContentConflict
        }

        var recoveryValues = current
        // Journal entries are already durable evidence. When the restored candidate is
        // missing one, preserve the recorded desired value instead of interpreting that
        // absence as a later user deletion.
        for entry in entries.values where recoveryValues[entry.desired.id] == nil {
            recoveryValues[entry.desired.id] = entry.desired
        }
        reconcile(
            current: recoveryValues,
            confirmed: SyncBase(),
            deviceID: deviceID,
            now: now)

        for key in Array(entries.keys) {
            entries[key]?.offered = nil
        }
        for key in Array(conflictDependencies.keys) {
            guard var dependency = conflictDependencies[key] else { continue }
            dependency.sourceOffered = nil
            for fingerprint in Array(dependency.requirements.keys) {
                dependency.requirements[fingerprint]?.acceptedRecordVersion = nil
                dependency.requirements[fingerprint]?.offered = nil
            }
            conflictDependencies[key] = dependency
        }

        for envelope in current.values.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            let key = SyncBase.key(envelope.id)
            guard entries[key] == nil else { continue }
            entries[key] = Entry(
                desired: envelope,
                offered: nil,
                generation: 1,
                modifiedAt: now)
        }
    }

    /// Folds edits made after an exact Repair/Check Again snapshot into durable intent
    /// before the conservative full-merge path can materialize missing journal values.
    ///
    /// Entries absent from `reviewedSnapshot` are older journal-only evidence: primary
    /// storage could not express them when the user reviewed the library, so continued
    /// absence is not a new deletion and they must remain recoverable. Entries present
    /// in the snapshot are different. Their exact reviewed envelope is an ancestor, so
    /// a later primary absence is a real deletion and ordinary reconciliation can mint
    /// its tombstone. This distinction closes both the immediate startup-Repair race
    /// and the arbitrarily long Check Again-while-sync-off window.
    mutating func reconcileAfterReviewedLocalSnapshot(
        current: [UUID: SyncEnvelope],
        reviewedSnapshot: SyncBase,
        deviceID: String,
        now: Date
    ) throws {
        guard reviewedSnapshot.requiresNonDestructiveLibraryMerge,
              reviewedSnapshot.nonDestructiveMergeMode == .reviewedLocalSnapshot else {
            return
        }

        guard let fingerprint = reviewedSnapshot.nonDestructiveReviewFingerprint() else {
            throw SyncMerge.EnvelopeFailure.malformedContentConflict
        }

        if reviewedRecoveryFingerprint != fingerprint {
            let reviewedCurrent = Dictionary(uniqueKeysWithValues:
                reviewedSnapshot.envelopes.values.map { ($0.id, $0) })
            let preRecoveryBase = reviewedSnapshot.preRecoveryConfirmedEnvelopes.map {
                SyncBase(envelopes: $0)
            }
            var preReviewAncestors: [UUID: SyncEnvelope] = [:]
            if let preRecoveryBase {
                for envelope in preRecoveryBase.envelopes.values {
                    preReviewAncestors[envelope.id] = envelope
                }
            }
            for entry in entries.values {
                if let offered = entry.offered?.envelope {
                    preReviewAncestors[offered.id] = offered
                }
            }
            let authoritativeIDs = Set(entries.values.map { $0.desired.id })
                .union(preRecoveryBase?.envelopes.values.map(\.id) ?? [])
                .union(reviewedCurrent.keys)

            if let preRecoveryBase {
                try prepareForAccountChange(
                    current: reviewedCurrent,
                    confirmed: preRecoveryBase,
                    deviceID: deviceID,
                    now: now)
            } else {
                try prepareForNonDestructiveLibraryRecovery(
                    current: reviewedCurrent,
                    confirmed: SyncBase(),
                    deviceID: deviceID,
                    now: now)
            }

            // This is a new explicit review epoch. Clear every older per-entry causal
            // fact before publishing the exact live/absent state from this review.
            for key in Array(entries.keys) {
                entries[key]?.reviewedLocalAncestor = nil
                entries[key]?.reviewedLocalSnapshotKnown = false
                entries[key]?.preReviewMergeAncestor = nil
            }
            reviewedRecoveryFingerprint = fingerprint
            for id in authoritativeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let key = SyncBase.key(id)
                guard var entry = entries[key] else { continue }
                if let reviewed = reviewedCurrent[id] {
                    entry.reviewedLocalSnapshotKnown = true
                    entry.reviewedLocalAncestor = reviewed
                    entry.preReviewMergeAncestor = preReviewAncestors[id]
                } else if preRecoveryBase != nil {
                    // Checkpoint Repair reviewed an intact primary, so absence for every
                    // previously known id is authoritative. Primary-file recovery omits
                    // the old base and deliberately leaves such absences unknown.
                    entry.reviewedLocalSnapshotKnown = true
                    entry.reviewedLocalAncestor = nil
                    entry.preReviewMergeAncestor = preReviewAncestors[id]
                }
                entries[key] = entry
            }
        }

        let journalOnly = entries.filter { _, entry in
            !entry.reviewedLocalSnapshotKnown && current[entry.desired.id] == nil
        }
        let emptyBase = SyncBase()
        try reconcileDependencies(current: current, confirmed: emptyBase)
        reconcile(current: current, confirmed: emptyBase, deviceID: deviceID, now: now)

        // Reconciliation intentionally drops an unoffered live value absent from both
        // current and confirmed state. Here that exact shape means “survived only in the
        // pre-repair journal”, not “the user deleted it after review”. Restore it until
        // the non-destructive reset materializes it under primary CAS.
        for (key, entry) in journalOnly where entries[key] == nil {
            entries[key] = entry
        }
        // A previous attempt may have committed only part of journal materialization
        // and crashed before its journal write. Exact live primary values now prove
        // their own materialization, but must not replace the explicit review ancestor
        // of any row that was already present when the user reviewed recovery.
        markReviewedLocalSnapshot(current.values)
    }

    /// Replaces an older user-review fence with the exact snapshot accepted by the
    /// newest explicit Repair/Check Again action. This is intentionally different from
    /// technical materialization below: a second recovery review supersedes the first.
    mutating func replaceReviewedLocalSnapshot<S: Sequence>(_ envelopes: S)
    where S.Element == SyncEnvelope {
        for envelope in envelopes where !envelope.deleted {
            let key = SyncBase.key(envelope.id)
            guard var entry = entries[key] else { continue }
            entry.reviewedLocalAncestor = envelope
            entry.reviewedLocalSnapshotKnown = true
            entry.preReviewMergeAncestor = nil
            entries[key] = entry
        }
    }

    /// Adds an existence fence before an awaited scheduler reset or immediately after
    /// journal-only materialization. Never replace an earlier explicit review ancestor:
    /// later local edits are intent relative to that original snapshot, not a new review.
    mutating func markReviewedLocalSnapshot<S: Sequence>(_ envelopes: S)
    where S.Element == SyncEnvelope {
        for envelope in envelopes where !envelope.deleted {
            let key = SyncBase.key(envelope.id)
            guard var entry = entries[key] else { continue }
            if !entry.reviewedLocalSnapshotKnown {
                entry.reviewedLocalAncestor = envelope
                entry.reviewedLocalSnapshotKnown = true
            }
            entries[key] = entry
        }
    }

    /// Removes intent owned by a vault deliberately forgotten on this device while
    /// retaining ordinary pending edits. A secure offer followed by an ordinary desired
    /// value is a demotion; only its now-invalid offer is cleared so the ordinary intent
    /// remains pending.
    mutating func forgetSecureIntent(forgottenIDs: Set<UUID> = []) {
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            if forgottenIDs.contains(entry.desired.id) || entry.desired.secure {
                entries[key] = nil
                continue
            } else if entry.offered?.envelope.secure == true {
                entry.offered = nil
            }
            // A plain survivor may carry the encrypted losing body of a secure edit.
            // Explicit vault forget authorizes dropping that body; retaining it after
            // removing the dependency would later upload forgotten ciphertext without
            // the copy-before-source fence.
            entry.desired = Self.removingUnderstoodSecureConflictCarriers(entry.desired)
            if let offered = entry.offered {
                entry.offered?.envelope = Self.removingUnderstoodSecureConflictCarriers(
                    offered.envelope)
            }
            entries[key] = entry
        }
        // Forget is an explicit destructive operation for this device's vault. Remove
        // dependency state whose source or required snapshot is secure; retaining it
        // would later recreate the deliberately forgotten vault contents.
        for key in Array(conflictDependencies.keys) {
            guard let dependency = conflictDependencies[key] else { continue }
            if forgottenIDs.contains(dependency.sourceSnapshot.id)
                || dependency.requirements.values.contains(where: {
                    forgottenIDs.contains($0.copyID)
                })
                || dependency.sourceSnapshot.secure
                || dependency.requirements.values.contains(where: {
                    $0.carrierKey != nil
                        || $0.snapshot?.secure == true
                        || $0.offered?.envelope.secure == true
                }) {
                conflictDependencies[key] = nil
            }
        }
    }

    /// Metadata supplied to local projection. Overlaying desired state keeps clocks and
    /// extension fields stable even when the best-effort projection sidecar is missing.
    func projectionKnowledge(over confirmed: SyncBase) -> SyncBase {
        var knowledge = confirmed
        for entry in entries.values {
            // While an offer is ambiguous it is the tentative ancestor: those are the
            // bytes that may already exist remotely. The newer desired value remains in
            // the journal and is overlaid explicitly on the merge's local side.
            knowledge.record(entry.offered?.envelope ?? entry.desired)
        }
        for dependency in conflictDependencies.values {
            // This value is projection input, never backend confirmation. A frozen
            // dependency snapshot is the only durable owner of fields (notably `x`)
            // which the primary Snippet model cannot represent. Include it even before
            // the first offer so a failed derived-sidecar write can be healed after a
            // restart without turning the generated copy into an unrelated record.
            if let sourceOffered = dependency.sourceOffered {
                knowledge.record(sourceOffered.envelope)
            } else if entries[SyncBase.key(dependency.sourceSnapshot.id)] == nil {
                knowledge.record(dependency.sourceSnapshot)
            }
            for requirement in dependency.requirements.values {
                if let offered = requirement.offered {
                    knowledge.record(offered.envelope)
                } else if let snapshot = requirement.snapshot {
                    knowledge.record(snapshot)
                }
            }
        }
        return knowledge
    }

    // MARK: - Reconciliation helpers

    private func conflictExistenceProof(for id: UUID) -> SyncEnvelope? {
        for dependency in conflictDependencies.values {
            if dependency.sourceSnapshot.id == id {
                // Staging preserves carrier bytes before primary apply. Until the
                // source itself is offered, that recovery snapshot does not prove an
                // absent local source was ever created remotely.
                return dependency.sourceOffered?.envelope
            }
            if let requirement = dependency.requirements.values.first(where: {
                $0.copyID == id
            }) {
                // Purely frozen C0 bytes may not have reached primary or backend yet.
                // Treating that preparation as existence manufactures a local deletion
                // in the journal after a post-fsync/pre-apply crash. An actual offer or
                // exact acceptance receipt is the first durable existence fact.
                if let offered = requirement.offered?.envelope { return offered }
                if requirement.acceptedRecordVersion != nil { return requirement.snapshot }
                return nil
            }
        }
        return nil
    }

    private func conflictRequirement(
        for copyID: UUID
    ) -> (sourceID: UUID, requirement: ConflictRequirement)? {
        for dependency in conflictDependencies.values {
            if let requirement = dependency.requirements.values.first(where: {
                $0.copyID == copyID
            }) {
                return (dependency.sourceSnapshot.id, requirement)
            }
        }
        return nil
    }

    private func isDependencyOwned(_ id: UUID) -> Bool {
        conflictDependencies.values.contains { dependency in
            dependency.sourceSnapshot.id == id
                || dependency.requirements.values.contains { $0.copyID == id }
        }
    }

    private func mustRetainPostPrerequisiteIntent(_ envelope: SyncEnvelope) -> Bool {
        guard let owner = conflictRequirement(for: envelope.id),
              let snapshot = owner.requirement.snapshot else { return false }
        return !Self.sameVersion(snapshot, envelope)
    }

    private func requirementConfirmed(
        _ requirement: ConflictRequirement,
        sourceID: UUID,
        in confirmed: SyncBase
    ) -> Bool {
        guard requirement.acceptedRecordVersion != nil,
              let snapshot = requirement.snapshot,
              !snapshot.deleted,
              SyncMerge.matchesConflictCopyProvenance(
                snapshot, sourceID: sourceID, fingerprint: requirement.fingerprint)
        else { return false }
        return true
    }

    private func requirementsConfirmed(
        _ dependency: ConflictDependency,
        in confirmed: SyncBase
    ) -> Bool {
        !dependency.requirements.isEmpty
            && dependency.requirements.values.allSatisfy {
                requirementConfirmed(
                    $0, sourceID: dependency.sourceSnapshot.id, in: confirmed)
            }
    }

    /// Source state eligible for the dependency-owned release. Secure carriers are
    /// removed through primary storage first, so this fallback is used only for plain
    /// dependencies (or an explicit tombstone already captured in ordinary intent).
    private func dependencySourceRelease(
        _ dependency: ConflictDependency,
        confirmed: SyncBase
    ) -> SyncEnvelope? {
        let sourceID = dependency.sourceSnapshot.id
        if let desired = entries[SyncBase.key(sourceID)]?.desired {
            // Understood v1 members are removed by the primary-storage resolution.
            // Any member left here is either a future version or a concurrently added
            // carrier and must remain opaque; falling back to an older confirmed source
            // would silently strip it for one ordered CAS round.
            guard !SyncMerge.hasUnresolvedContentConflict(desired) else { return nil }
            return desired
        }
        // A schema-1 client could have had the server accept the source tombstone before
        // the conflict copy. Re-submit that exact tombstone under its current CAS
        // generation after the copy is confirmed; this duplicate write is the durable
        // ordering proof that old clients never recorded.
        if dependency.sourceSnapshot.deleted {
            return dependency.sourceSnapshot
        }
        if dependency.requirements.values.allSatisfy({ $0.carrierKey == nil }) {
            return dependency.sourceSnapshot
        }
        // Carrier cleanup can legitimately restore bytes that already exist in the
        // pre-conflict base. Re-submit those exact bytes with that base's CAS generation
        // anyway: acceptance is the durable proof that this source write happened after
        // the copy prerequisites, not merely an old carrier-free ancestor.
        guard let carrierFree = confirmed.envelope(sourceID),
              !carrierFree.deleted,
              !SyncMerge.hasUnresolvedContentConflict(carrierFree)
        else { return nil }
        return carrierFree
    }

    private mutating func pruneConfirmedDependencies(
        confirmed: SyncBase,
        acceptedSourceIDs: Set<UUID>
    ) {
        for key in Array(conflictDependencies.keys) {
            guard let dependency = conflictDependencies[key],
                  acceptedSourceIDs.contains(dependency.sourceSnapshot.id),
                  requirementsConfirmed(dependency, in: confirmed),
                  let sourceOffered = dependency.sourceOffered,
                  let confirmedSource = confirmed.envelope(dependency.sourceSnapshot.id),
                  Self.sameVersion(sourceOffered.envelope, confirmedSource),
                  (sourceOffered.envelope.deleted
                    || dependency.requirements.values.allSatisfy({ $0.carrierKey == nil })),
                  !SyncMerge.hasUnresolvedContentConflict(confirmedSource)
            else { continue }

            // If ordinary source intent still differs, the confirmed carrier-free value
            // already proves the ordering fence; the newer edit/delete can continue as a
            // normal journal generation. Copy deletes were held while the edge existed
            // and are released by this removal.
            if let entry = entries[key], entry.offered == nil,
               Self.sameVersion(entry.desired, sourceOffered.envelope) {
                entries[key] = nil
            }
            conflictDependencies[key] = nil
        }
    }

    private static func newestLive(
        _ first: SyncEnvelope?, _ second: SyncEnvelope?
    ) -> SyncEnvelope? {
        [first, second].compactMap { $0 }.filter { !$0.deleted }.max { $0.hlc < $1.hlc }
    }

    private static func removingUnderstoodSecureConflictCarriers(
        _ envelope: SyncEnvelope
    ) -> SyncEnvelope {
        var result = envelope
        for key in result.x.keys where key.hasPrefix(
            SyncMerge.contentConflictV1ExtensionPrefix) {
            result.x[key] = nil
        }
        return result
    }

    private static func restampedIfNeeded(
        _ local: SyncEnvelope,
        previousDesired: SyncEnvelope?,
        offered: SyncEnvelope?,
        confirmed: SyncEnvelope?,
        deviceID: String,
        now: Date
    ) -> SyncEnvelope {
        if sameVersion(local, previousDesired)
            || sameVersion(local, offered)
            || sameVersion(local, confirmed) {
            return local
        }

        // The frozen local files cannot store HLC/origin. After a stale recreation is
        // restamped, the next projection can therefore present the same user payload
        // with its old clock again. Preserve the already-restamped desired envelope so
        // reconcile is a fixed point instead of minting a generation every round.
        if let previousDesired,
           local.hlc <= previousDesired.hlc,
           sameRepresentablePayload(local, previousDesired) {
            return previousDesired
        }

        let priorEvidence = [previousDesired, offered, confirmed].compactMap { $0 }
        guard let highest = priorEvidence.map(\.hlc).max(), local.hlc <= highest else {
            return local
        }

        return SyncEnvelope(
            schemaVersion: local.schemaVersion,
            id: local.id,
            hlc: clock(
                after: ([local] + priorEvidence).map(\.hlc),
                deviceID: deviceID,
                now: now),
            origin: deviceID,
            secure: local.secure,
            deleted: local.deleted,
            fields: local.fields,
            x: local.x)
    }

    private static func sameRepresentablePayload(
        _ lhs: SyncEnvelope, _ rhs: SyncEnvelope
    ) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.id == rhs.id
            && lhs.secure == rhs.secure
            && lhs.deleted == rhs.deleted
            && lhs.fields == rhs.fields
            && lhs.x == rhs.x
    }

    private static func clock(after clocks: [HLC], deviceID: String, now: Date) -> HLC {
        let generator = HLCGenerator(
            device: deviceID,
            persisted: clocks.max(),
            physicalNowMs: { now.millisecondsSince1970 })
        return generator.send()
    }

    private static func nextGeneration(after previous: UInt64?) -> UInt64 {
        guard let previous else { return 1 }
        return previous == UInt64.max ? UInt64.max : previous + 1
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
}

// MARK: - Persistence

/// Hand-written for the same reason as `SyncBase`: an envelope has one canonical wire
/// representation, and the journal stores those exact bytes rather than inventing a
/// second synthesized representation that can drift.
nonisolated extension SyncJournal: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, entries, conflictDependencies, reviewedRecoveryFingerprint
    }

    private struct StoredOffered: Codable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case envelope, generation, recordVersion
        }
        var envelope: String
        var generation: UInt64
        /// Additive for pre-CAS journal compatibility. Missing means the offer was
        /// created by an older build; nil is the safe conditional-create token.
        var recordVersion: SyncRecordVersion?

        init(
            envelope: String,
            generation: UInt64,
            recordVersion: SyncRecordVersion?
        ) {
            self.envelope = envelope
            self.generation = generation
            self.recordVersion = recordVersion
        }

        init(from decoder: Decoder) throws {
            try SyncJournal.rejectUnknownFields(decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            envelope = try container.decode(String.self, forKey: .envelope)
            generation = try container.decode(UInt64.self, forKey: .generation)
            recordVersion = try container.decodeIfPresent(
                SyncRecordVersion.self, forKey: .recordVersion)
        }
    }

    private struct StoredEntry: Codable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case desired, offered, generation, modifiedAt, reviewedLocalExistence
            case reviewedLocalAncestor, reviewedLocalSnapshotKnown
            case preReviewMergeAncestor
        }
        var desired: String
        var offered: StoredOffered?
        var generation: UInt64
        /// `Date`'s stored `Double`, without ISO-8601's subsecond truncation. Journal
        /// round trips must be value-exact because equality suppresses needless writes.
        var modifiedAt: Double
        var reviewedLocalExistence: Bool?
        var reviewedLocalAncestor: String?
        var reviewedLocalSnapshotKnown: Bool?
        var preReviewMergeAncestor: String?

        init(
            desired: String, offered: StoredOffered?, generation: UInt64,
            modifiedAt: Double, reviewedLocalExistence: Bool?,
            reviewedLocalAncestor: String?, reviewedLocalSnapshotKnown: Bool?,
            preReviewMergeAncestor: String?
        ) {
            self.desired = desired
            self.offered = offered
            self.generation = generation
            self.modifiedAt = modifiedAt
            self.reviewedLocalExistence = reviewedLocalExistence
            self.reviewedLocalAncestor = reviewedLocalAncestor
            self.reviewedLocalSnapshotKnown = reviewedLocalSnapshotKnown
            self.preReviewMergeAncestor = preReviewMergeAncestor
        }

        init(from decoder: Decoder) throws {
            try SyncJournal.rejectUnknownFields(decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            desired = try container.decode(String.self, forKey: .desired)
            offered = try container.decodeIfPresent(StoredOffered.self, forKey: .offered)
            generation = try container.decode(UInt64.self, forKey: .generation)
            modifiedAt = try container.decode(Double.self, forKey: .modifiedAt)
            reviewedLocalExistence = try container.decodeIfPresent(
                Bool.self, forKey: .reviewedLocalExistence)
            reviewedLocalAncestor = try container.decodeIfPresent(
                String.self, forKey: .reviewedLocalAncestor)
            reviewedLocalSnapshotKnown = try container.decodeIfPresent(
                Bool.self, forKey: .reviewedLocalSnapshotKnown)
            preReviewMergeAncestor = try container.decodeIfPresent(
                String.self, forKey: .preReviewMergeAncestor)
        }
    }

    private struct StoredRequirement: Codable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case copyID, fingerprint, carrierKey, carrierValue, snapshot, offered
            case acceptedRecordVersion
        }
        var copyID: String
        var fingerprint: String
        var carrierKey: String?
        var carrierValue: String?
        var snapshot: String?
        var offered: StoredOffered?
        var acceptedRecordVersion: SyncRecordVersion?

        init(
            copyID: String, fingerprint: String, carrierKey: String?,
            carrierValue: String?, snapshot: String?, offered: StoredOffered?,
            acceptedRecordVersion: SyncRecordVersion?
        ) {
            self.copyID = copyID
            self.fingerprint = fingerprint
            self.carrierKey = carrierKey
            self.carrierValue = carrierValue
            self.snapshot = snapshot
            self.offered = offered
            self.acceptedRecordVersion = acceptedRecordVersion
        }

        init(from decoder: Decoder) throws {
            try SyncJournal.rejectUnknownFields(decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            copyID = try container.decode(String.self, forKey: .copyID)
            fingerprint = try container.decode(String.self, forKey: .fingerprint)
            carrierKey = try container.decodeIfPresent(String.self, forKey: .carrierKey)
            carrierValue = try container.decodeIfPresent(String.self, forKey: .carrierValue)
            snapshot = try container.decodeIfPresent(String.self, forKey: .snapshot)
            offered = try container.decodeIfPresent(StoredOffered.self, forKey: .offered)
            acceptedRecordVersion = try container.decodeIfPresent(
                SyncRecordVersion.self, forKey: .acceptedRecordVersion)
        }
    }

    private struct StoredDependency: Codable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case sourceSnapshot, requirements, sourceOffered
        }
        var sourceSnapshot: String
        var requirements: [String: StoredRequirement]
        var sourceOffered: StoredOffered?

        init(
            sourceSnapshot: String,
            requirements: [String: StoredRequirement],
            sourceOffered: StoredOffered?
        ) {
            self.sourceSnapshot = sourceSnapshot
            self.requirements = requirements
            self.sourceOffered = sourceOffered
        }

        init(from decoder: Decoder) throws {
            try SyncJournal.rejectUnknownFields(decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceSnapshot = try container.decode(String.self, forKey: .sourceSnapshot)
            requirements = try container.decode(
                [String: StoredRequirement].self, forKey: .requirements)
            sourceOffered = try container.decodeIfPresent(
                StoredOffered.self, forKey: .sourceOffered)
        }
    }

    init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let actual = Set(allFields.allKeys.map(\.stringValue))
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        guard actual.isSubset(of: expected) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unexpected sync-journal fields"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...SyncJournal.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported sync-journal schema version")
        }
        // Both fields are required. A syntactically valid truncated write such as `{}`
        // or `{"schemaVersion":1}` must halt, never become an authoritative empty
        // journal that silently discards desired/offered intent.
        let stored = try container.decode([String: StoredEntry].self, forKey: .entries)

        if schemaVersion >= 5 {
            reviewedRecoveryFingerprint = try container.decodeIfPresent(
                String.self, forKey: .reviewedRecoveryFingerprint)
            if let reviewedRecoveryFingerprint,
               !Self.isLowercaseSHA256(reviewedRecoveryFingerprint) {
                throw DecodingError.dataCorruptedError(
                    forKey: .reviewedRecoveryFingerprint,
                    in: container,
                    debugDescription: "invalid reviewed recovery fingerprint")
            }
        } else {
            guard !container.contains(.reviewedRecoveryFingerprint) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .reviewedRecoveryFingerprint,
                    in: container,
                    debugDescription: "review fingerprint requires journal schema 5")
            }
            reviewedRecoveryFingerprint = nil
        }

        var decoded: [String: Entry] = [:]
        decoded.reserveCapacity(stored.count)
        for (key, value) in stored {
            guard value.generation > 0,
                  let desiredData = Data(base64Encoded: value.desired),
                  let desired = try? SyncEnvelope.parse(desiredData),
                  SyncBase.key(desired.id) == key else {
                throw DecodingError.dataCorruptedError(
                    forKey: .entries,
                    in: container,
                    debugDescription: "invalid desired sync-journal entry")
            }

            let offered: Offered?
            if let storedOffered = value.offered {
                guard storedOffered.generation > 0,
                      storedOffered.generation <= value.generation,
                      let offeredData = Data(base64Encoded: storedOffered.envelope),
                      let envelope = try? SyncEnvelope.parse(offeredData),
                      envelope.id == desired.id else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entries,
                        in: container,
                        debugDescription: "invalid offered sync-journal entry")
                }
                offered = Offered(
                    envelope: envelope,
                    generation: storedOffered.generation,
                    recordVersion: storedOffered.recordVersion)
            } else {
                offered = nil
            }

            let reviewedLocalAncestor: SyncEnvelope?
            if let encoded = value.reviewedLocalAncestor {
                guard let data = Data(base64Encoded: encoded),
                      let ancestor = try? SyncEnvelope.parse(data),
                      ancestor.id == desired.id,
                      !ancestor.deleted else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entries,
                        in: container,
                        debugDescription: "invalid reviewed local ancestor")
                }
                reviewedLocalAncestor = ancestor
            } else {
                reviewedLocalAncestor = nil
            }
            let reviewedLocalSnapshotKnown: Bool
            let preReviewMergeAncestor: SyncEnvelope?
            if schemaVersion >= 5 {
                guard let storedKnown = value.reviewedLocalSnapshotKnown else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entries,
                        in: container,
                        debugDescription: "journal schema 5 requires reviewed snapshot facts")
                }
                reviewedLocalSnapshotKnown = storedKnown
                if let encoded = value.preReviewMergeAncestor {
                    guard let data = Data(base64Encoded: encoded),
                          let ancestor = try? SyncEnvelope.parse(data),
                          ancestor.id == desired.id else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .entries,
                            in: container,
                            debugDescription: "invalid pre-review merge ancestor")
                    }
                    preReviewMergeAncestor = ancestor
                } else {
                    preReviewMergeAncestor = nil
                }
            } else {
                guard value.reviewedLocalSnapshotKnown == nil,
                      value.preReviewMergeAncestor == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entries,
                        in: container,
                        debugDescription: "two-phase review facts require journal schema 5")
                }
                reviewedLocalSnapshotKnown = reviewedLocalAncestor != nil
                preReviewMergeAncestor = nil
            }
            guard (value.reviewedLocalExistence ?? false)
                    == (reviewedLocalSnapshotKnown && reviewedLocalAncestor != nil),
                  reviewedLocalSnapshotKnown || (reviewedLocalAncestor == nil
                    && preReviewMergeAncestor == nil) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .entries,
                    in: container,
                    debugDescription: "reviewed state must bind exact recovery ancestry")
            }

            decoded[key] = Entry(
                desired: desired,
                offered: offered,
                generation: value.generation,
                modifiedAt: Date(timeIntervalSinceReferenceDate: value.modifiedAt),
                reviewedLocalAncestor: reviewedLocalAncestor,
                reviewedLocalSnapshotKnown: reviewedLocalSnapshotKnown,
                preReviewMergeAncestor: preReviewMergeAncestor)
        }
        entries = decoded

        if schemaVersion < 4,
           stored.values.contains(where: {
               $0.reviewedLocalExistence != nil || $0.reviewedLocalAncestor != nil
           }) {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: container,
                debugDescription: "reviewed local existence requires journal schema 4")
        }
        if schemaVersion >= 4,
           stored.values.contains(where: { $0.reviewedLocalExistence == nil }) {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: container,
                debugDescription: "journal schema 4 requires reviewed existence facts")
        }

        if schemaVersion == 1 {
            guard !container.contains(.conflictDependencies) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .conflictDependencies,
                    in: container,
                    debugDescription: "conflict dependencies require sync-journal schema 2")
            }
            conflictDependencies = [:]
            needsDependencyMigration = true
            // The next write is the downgrade fence even when there is no carrier to
            // reconstruct. Engines reconcile before transport, so no intent is skipped.
            schemaVersion = Self.currentSchemaVersion
            return
        }

        let storedDependencies = try container.decode(
            [String: StoredDependency].self,
            forKey: .conflictDependencies)
        var dependencies: [String: ConflictDependency] = [:]
        var dependencyCopyIDs = Set<UUID>()
        for (sourceKey, storedDependency) in storedDependencies {
            guard let sourceData = Data(base64Encoded: storedDependency.sourceSnapshot),
                  let source = try? SyncEnvelope.parse(sourceData),
                  SyncBase.key(source.id) == sourceKey,
                  !storedDependency.requirements.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .conflictDependencies,
                    in: container,
                    debugDescription: "invalid conflict dependency source")
            }
            let sourceOffered = try Self.decodeStoredOffered(
                storedDependency.sourceOffered,
                expectedID: source.id,
                forKey: .conflictDependencies,
                in: container)
            guard sourceOffered.map({
                !SyncMerge.hasUnresolvedContentConflict($0.envelope)
            }) ?? true else {
                throw DecodingError.dataCorruptedError(
                    forKey: .conflictDependencies,
                    in: container,
                    debugDescription: "conflict dependency source offer still has a carrier")
            }
            var requirements: [String: ConflictRequirement] = [:]
            var activeCarrierKeys = Set<String>()
            for (fingerprint, storedRequirement) in storedDependency.requirements {
                guard Self.isLowercaseSHA256(fingerprint),
                      storedRequirement.fingerprint == fingerprint,
                      let copyID = UUID(uuidString: storedRequirement.copyID),
                      storedRequirement.copyID == copyID.uuidString.lowercased(),
                      copyID == SyncMerge.deterministicUUID(
                        namespace: source.id,
                        name: "sync-content-conflict-v1|\(fingerprint)"),
                      dependencyCopyIDs.insert(copyID).inserted,
                      (storedRequirement.carrierKey == nil)
                        == (storedRequirement.carrierValue == nil) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .conflictDependencies,
                        in: container,
                        debugDescription: "invalid conflict dependency requirement")
                }
                let carrierValue: CanonicalJSON.Value?
                if let encoded = storedRequirement.carrierValue,
                   let bytes = Data(base64Encoded: encoded),
                   let value = try? CanonicalJSON.value(bytes) {
                    carrierValue = value
                } else if storedRequirement.carrierValue == nil {
                    carrierValue = nil
                } else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .conflictDependencies,
                        in: container,
                        debugDescription: "invalid conflict dependency carrier")
                }
                if let carrierKey = storedRequirement.carrierKey,
                   let carrierValue {
                    guard carrierKey == SyncMerge.contentConflictV1ExtensionPrefix
                            + fingerprint,
                          source.x[carrierKey] == carrierValue,
                          let variant = try? SyncMerge.secureContentConflictVariants(
                            in: source).first(where: { $0.fingerprint == fingerprint }),
                          variant.copyID == copyID,
                          variant.sourceID == source.id
                    else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .conflictDependencies,
                            in: container,
                            debugDescription: "invalid secure conflict dependency carrier")
                    }
                    activeCarrierKeys.insert(carrierKey)
                }
                let snapshot = try Self.decodeStoredEnvelope(
                    storedRequirement.snapshot,
                    expectedID: copyID,
                    forKey: .conflictDependencies,
                    in: container)
                let offered = try Self.decodeStoredOffered(
                    storedRequirement.offered,
                    expectedID: copyID,
                    forKey: .conflictDependencies,
                    in: container)
                let acceptedRecordVersion = storedRequirement.acceptedRecordVersion
                if schemaVersion < 3, acceptedRecordVersion != nil {
                    throw DecodingError.dataCorruptedError(
                        forKey: .conflictDependencies,
                        in: container,
                        debugDescription: "conflict prerequisite receipts require schema 3")
                }
                guard [snapshot, offered?.envelope].compactMap({ $0 }).allSatisfy({
                    !$0.deleted && SyncMerge.matchesConflictCopyProvenance(
                        $0, sourceID: source.id, fingerprint: fingerprint)
                }),
                      (offered == nil || snapshot != nil),
                      snapshot != nil || storedRequirement.carrierKey != nil,
                      offered.map({ Self.sameVersion(snapshot, $0.envelope) }) ?? true,
                      acceptedRecordVersion == nil || snapshot != nil
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .conflictDependencies,
                        in: container,
                        debugDescription: "invalid conflict dependency copy snapshot")
                }
                requirements[fingerprint] = ConflictRequirement(
                    copyID: copyID,
                    fingerprint: fingerprint,
                    carrierKey: storedRequirement.carrierKey,
                    carrierValue: carrierValue,
                    snapshot: snapshot,
                    offered: offered,
                    acceptedRecordVersion: acceptedRecordVersion)
            }
            let understoodSourceCarrierKeys = Set(source.x.keys.filter {
                $0.hasPrefix(SyncMerge.contentConflictV1ExtensionPrefix)
            })
            guard understoodSourceCarrierKeys == activeCarrierKeys else {
                throw DecodingError.dataCorruptedError(
                    forKey: .conflictDependencies,
                    in: container,
                    debugDescription: "conflict dependency carrier set is inconsistent")
            }
            dependencies[sourceKey] = ConflictDependency(
                sourceSnapshot: source,
                requirements: requirements,
                sourceOffered: sourceOffered)
        }
        conflictDependencies = dependencies
        needsDependencyMigration = schemaVersion < Self.currentSchemaVersion
        if needsDependencyMigration {
            schemaVersion = Self.currentSchemaVersion
        }
    }

    func encode(to encoder: Encoder) throws {
        guard !needsDependencyMigration else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "sync-journal v1 dependency migration is incomplete"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        if schemaVersion >= 5 {
            try container.encodeIfPresent(
                reviewedRecoveryFingerprint, forKey: .reviewedRecoveryFingerprint)
        } else if reviewedRecoveryFingerprint != nil {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: container.codingPath,
                      debugDescription: "review fingerprint requires journal schema 5"))
        }
        var stored: [String: StoredEntry] = [:]
        stored.reserveCapacity(entries.count)
        for (key, entry) in entries {
            guard entry.reviewedLocalSnapshotKnown
                    || (entry.reviewedLocalAncestor == nil
                        && entry.preReviewMergeAncestor == nil),
                  entry.reviewedLocalAncestor.map({
                    $0.id == entry.desired.id && !$0.deleted
                  }) ?? true,
                  entry.preReviewMergeAncestor.map({
                    $0.id == entry.desired.id
                  }) ?? true else {
                throw EncodingError.invalidValue(
                    entry,
                    .init(codingPath: container.codingPath,
                          debugDescription: "invalid reviewed recovery ancestry"))
            }
            if schemaVersion < 5,
               (entry.preReviewMergeAncestor != nil
                    || (entry.reviewedLocalSnapshotKnown
                        && entry.reviewedLocalAncestor == nil)) {
                throw EncodingError.invalidValue(
                    entry,
                    .init(codingPath: container.codingPath,
                          debugDescription: "two-phase recovery ancestry requires schema 5"))
            }
            let offered = try entry.offered.map {
                StoredOffered(
                    envelope: try $0.envelope.canonicalData().base64EncodedString(),
                    generation: $0.generation,
                    recordVersion: $0.recordVersion)
            }
            stored[key] = StoredEntry(
                desired: try entry.desired.canonicalData().base64EncodedString(),
                offered: offered,
                generation: entry.generation,
                modifiedAt: entry.modifiedAt.timeIntervalSinceReferenceDate,
                reviewedLocalExistence: schemaVersion >= 4
                    ? entry.reviewedLocalExistence
                    : nil,
                reviewedLocalAncestor: schemaVersion >= 4
                    ? try entry.reviewedLocalAncestor?.canonicalData().base64EncodedString()
                    : nil,
                reviewedLocalSnapshotKnown: schemaVersion >= 5
                    ? entry.reviewedLocalSnapshotKnown
                    : nil,
                preReviewMergeAncestor: schemaVersion >= 5
                    ? try entry.preReviewMergeAncestor?.canonicalData().base64EncodedString()
                    : nil)
        }
        try container.encode(stored, forKey: .entries)
        var storedDependencies: [String: StoredDependency] = [:]
        for (sourceKey, dependency) in conflictDependencies {
            var requirements: [String: StoredRequirement] = [:]
            for (fingerprint, requirement) in dependency.requirements {
                requirements[fingerprint] = StoredRequirement(
                    copyID: requirement.copyID.uuidString.lowercased(),
                    fingerprint: requirement.fingerprint,
                    carrierKey: requirement.carrierKey,
                    carrierValue: try requirement.carrierValue.map {
                        try CanonicalJSON.data($0).base64EncodedString()
                    },
                    snapshot: try requirement.snapshot.map {
                        try $0.canonicalData().base64EncodedString()
                    },
                    offered: try requirement.offered.map(Self.storedOffered),
                    acceptedRecordVersion: requirement.acceptedRecordVersion)
            }
            storedDependencies[sourceKey] = StoredDependency(
                sourceSnapshot: try dependency.sourceSnapshot.canonicalData()
                    .base64EncodedString(),
                requirements: requirements,
                sourceOffered: try dependency.sourceOffered.map(Self.storedOffered))
        }
        try container.encode(storedDependencies, forKey: .conflictDependencies)
    }

    private static func storedOffered(_ offered: Offered) throws -> StoredOffered {
        StoredOffered(
            envelope: try offered.envelope.canonicalData().base64EncodedString(),
            generation: offered.generation,
            recordVersion: offered.recordVersion)
    }

    private static func decodeStoredEnvelope<K: CodingKey>(
        _ encoded: String?,
        expectedID: UUID,
        forKey key: K,
        in container: KeyedDecodingContainer<K>
    ) throws -> SyncEnvelope? {
        guard let encoded else { return nil }
        guard let data = Data(base64Encoded: encoded),
              let envelope = try? SyncEnvelope.parse(data),
              envelope.id == expectedID else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "invalid conflict dependency envelope")
        }
        return envelope
    }

    private static func decodeStoredOffered<K: CodingKey>(
        _ stored: StoredOffered?,
        expectedID: UUID,
        forKey key: K,
        in container: KeyedDecodingContainer<K>
    ) throws -> Offered? {
        guard let stored else { return nil }
        guard stored.generation > 0,
              let envelope = try decodeStoredEnvelope(
                stored.envelope, expectedID: expectedID, forKey: key, in: container)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "invalid conflict dependency offer")
        }
        return Offered(
            envelope: envelope,
            generation: stored.generation,
            recordVersion: stored.recordVersion)
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    private static func rejectUnknownFields<K: CodingKey & CaseIterable>(
        _ decoder: Decoder,
        allowed: [K]
    ) throws where K.AllCases == [K] {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        let expected = Set(allowed.map(\.stringValue))
        guard actual.isSubset(of: expected) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unexpected conflict-dependency fields"))
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

nonisolated enum SyncJournalFile {

    enum Outcome {
        case missing(SyncJournal)
        case loaded(SyncJournal)
        case tooNew(version: Int)
        case unreadable(String)
    }

    static func load(
        from url: URL = SnippetStorageLocations.syncJournalFileURL
    ) -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing(SyncJournal())
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable("sync journal could not be read")
        }

        if let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data),
           let version = probe.schemaVersion,
           version > SyncJournal.currentSchemaVersion {
            return .tooNew(version: version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode(SyncJournal.self, from: data))
        } catch {
            return .unreadable("sync journal is malformed")
        }
    }

    static func write(
        _ journal: SyncJournal,
        to url: URL = SnippetStorageLocations.syncJournalFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(
            encoder.encode(journal), to: url, temporaryDirectory: temporaryDirectory)
    }
}
