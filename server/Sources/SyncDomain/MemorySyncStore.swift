import Foundation

/// Complete reference implementation used by unit/API conformance tests.
/// Production composition never selects it; production uses `PostgresSyncStore`.
public actor MemorySyncStore: SyncStore {
    private struct Membership: Sendable {
        let role: SpaceRole
        let scopeBinding: String
    }

    private struct StoredRecord: Sendable {
        var value: ServerRecord
        var generation: Int64
    }

    private struct Change: Sendable {
        let sequence: Int64
        let value: ServerRecord
    }

    private struct StoredPairing: Sendable {
        var value: Pairing
        let recipientKeyHash: Data
    }

    private struct SpaceState: Sendable {
        var datasetGeneration: UUID
        var feedEpoch: UUID
        var keyEpoch: Int
        var nextSequence: Int64
        var memberships: [Data: Membership]
        var records: [UUID: StoredRecord]
        var changes: [Change]
        var recoveryEnvelope: KeyEnvelope?
        var pairings: [UUID: StoredPairing]
    }

    private let serverInstanceID: UUID
    private let tokenCodec: OpaqueTokenCodec
    private var spaces: [UUID: SpaceState] = [:]
    private var idempotentSpaces: [Data: [UUID: UUID]] = [:]

    public init(serverInstanceID: UUID, tokenSecret: Data) throws {
        self.serverInstanceID = serverInstanceID
        self.tokenCodec = try OpaqueTokenCodec(secret: tokenSecret)
    }

    public func readiness() async throws {}

    public func listSpaces(for principal: AuthenticatedPrincipal) async throws -> [SpaceDescriptor] {
        spaces.compactMap { spaceID, state in
            guard let membership = state.memberships[principal.identityDigest] else { return nil }
            return descriptor(spaceID: spaceID, state: state, membership: membership)
        }.sorted { $0.scope.spaceID.uuidString < $1.scope.spaceID.uuidString }
    }

    public func createSpace(for principal: AuthenticatedPrincipal, idempotencyKey: UUID?) async throws -> SpaceDescriptor {
        if let idempotencyKey,
           let existingID = idempotentSpaces[principal.identityDigest]?[idempotencyKey],
           let existing = spaces[existingID],
           let membership = existing.memberships[principal.identityDigest] {
            return descriptor(spaceID: existingID, state: existing, membership: membership)
        }
        let ownedSpaceCount = spaces.values.filter { $0.memberships[principal.identityDigest]?.role == .owner }.count
        guard ownedSpaceCount < SyncLimits.maxSpacesPerUser else {
            throw SyncServiceError.quotaExceeded(limit: SyncLimits.maxSpacesPerUser)
        }

        let spaceID = UUID()
        let membership = Membership(role: .owner, scopeBinding: randomBytes(count: 32).base64URL)
        let state = SpaceState(
            datasetGeneration: UUID(),
            feedEpoch: UUID(),
            keyEpoch: 1,
            nextSequence: 0,
            memberships: [principal.identityDigest: membership],
            records: [:],
            changes: [],
            recoveryEnvelope: nil,
            pairings: [:]
        )
        spaces[spaceID] = state
        if let idempotencyKey {
            idempotentSpaces[principal.identityDigest, default: [:]][idempotencyKey] = spaceID
        }
        return descriptor(spaceID: spaceID, state: state, membership: membership)
    }

    public func scope(for principal: AuthenticatedPrincipal, spaceID: UUID) async throws -> SpaceDescriptor {
        let (state, membership) = try authorizedState(principal: principal, spaceID: spaceID)
        return descriptor(spaceID: spaceID, state: state, membership: membership)
    }

    public func fetchChanges(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        cursor: String?,
        limit: Int
    ) async throws -> ChangesPage {
        guard (1...SyncLimits.maxPageRecords).contains(limit) else { throw SyncServiceError.invalidRequest }
        let (state, membership) = try authorizedState(principal: principal, spaceID: spaceID)
        let scope = descriptor(spaceID: spaceID, state: state, membership: membership).scope

        if cursor == nil {
            return try snapshotPage(state: state, scope: scope, after: nil, highWater: state.nextSequence, limit: limit)
        }

        let payload: CursorPayload = try tokenCodec.decode(CursorPayload.self, token: cursor!)
        guard payload.version == 1,
              payload.serverInstanceID == serverInstanceID,
              payload.spaceID == spaceID
        else { throw SyncServiceError.cursorInvalid }
        guard payload.datasetGeneration == state.datasetGeneration else { throw SyncServiceError.datasetReset }
        guard payload.feedEpoch == state.feedEpoch else { throw SyncServiceError.cursorInvalid }

        switch payload.kind {
        case .snapshot:
            return try snapshotPage(
                state: state,
                scope: scope,
                after: payload.snapshotAfterID,
                highWater: payload.snapshotHighWater,
                limit: limit
            )
        case .delta:
            let available = state.changes.filter { $0.sequence > payload.sequence }
            let selected = Array(available.prefix(limit))
            let sequence = selected.last?.sequence ?? payload.sequence
            let nextPayload = CursorPayload(
                kind: .delta,
                serverInstanceID: serverInstanceID,
                spaceID: spaceID,
                datasetGeneration: state.datasetGeneration,
                feedEpoch: state.feedEpoch,
                sequence: sequence
            )
            return ChangesPage(
                scope: scope,
                records: selected.map(\.value),
                cursor: try tokenCodec.encode(nextPayload),
                hasMore: available.count > selected.count,
                fullSnapshot: false
            )
        }
    }

    public func submit(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        items: [BatchItem]
    ) async throws -> BatchSubmission {
        guard !items.isEmpty, items.count <= SyncLimits.maxBatchRecords else { throw SyncServiceError.invalidRequest }
        guard Set(items.map(\.record.id)).count == items.count else { throw SyncServiceError.invalidRequest }
        let (initial, membership) = try authorizedState(principal: principal, spaceID: spaceID)
        guard membership.role.canWrite else { throw SyncServiceError.forbidden }

        var state = initial
        var indexedOutcomes: [Int: BatchOutcome] = [:]
        let ordered = items.enumerated().sorted { $0.element.record.id.uuidString < $1.element.record.id.uuidString }

        for (index, item) in ordered {
            do {
                try item.record.validate()
                if let expected = item.expectedRecordVersion,
                   !(32...2_048).contains(expected.utf8.count) {
                    throw SyncServiceError.invalidRequest
                }
            } catch let error as SyncServiceError {
                indexedOutcomes[index] = .rejected(code: error.code)
                continue
            } catch {
                indexedOutcomes[index] = .rejected(code: .invalidRequest)
                continue
            }

            let current = state.records[item.record.id]
            let matches: Bool
            if let expected = item.expectedRecordVersion {
                matches = current?.value.recordVersion == expected
            } else {
                matches = current == nil
            }
            guard matches else {
                indexedOutcomes[index] = .conflict(authoritative: current?.value)
                continue
            }

            let generation = (current?.generation ?? 0) + 1
            state.nextSequence += 1
            let versionPayload = RecordVersionPayload(
                serverInstanceID: serverInstanceID,
                spaceID: spaceID,
                datasetGeneration: state.datasetGeneration,
                recordID: item.record.id,
                generation: generation
            )
            let version = try tokenCodec.encode(versionPayload)
            let serverRecord = ServerRecord(record: item.record, recordVersion: version)
            state.records[item.record.id] = StoredRecord(value: serverRecord, generation: generation)
            state.changes.append(Change(sequence: state.nextSequence, value: serverRecord))
            indexedOutcomes[index] = .accepted(recordVersion: version, revision: item.record.rev)
        }

        spaces[spaceID] = state
        let outcomes = items.indices.map { indexedOutcomes[$0] ?? .rejected(code: .internalError) }
        let partial = outcomes.contains { outcome in
            if case .accepted = outcome { return false }
            return true
        }
        return BatchSubmission(
            scope: descriptor(spaceID: spaceID, state: state, membership: membership).scope,
            outcomes: outcomes,
            partial: partial
        )
    }

    public func currentKeyEnvelope(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID
    ) async throws -> (SpaceDescriptor, KeyEnvelope?) {
        let (state, membership) = try authorizedState(principal: principal, spaceID: spaceID)
        return (descriptor(spaceID: spaceID, state: state, membership: membership), state.recoveryEnvelope)
    }

    public func putKeyEnvelope(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        request: PutKeyEnvelope
    ) async throws -> KeyEnvelope {
        try request.validate()
        let (initial, membership) = try authorizedState(principal: principal, spaceID: spaceID)
        guard membership.role == .owner else { throw SyncServiceError.forbidden }
        guard request.keyEpoch == initial.keyEpoch else { throw SyncServiceError.conflict }
        let currentVersion = initial.recoveryEnvelope?.version
        guard request.expectedVersion == currentVersion else { throw SyncServiceError.conflict }

        var state = initial
        let envelope = KeyEnvelope(
            version: (currentVersion ?? 0) + 1,
            keyEpoch: request.keyEpoch,
            algorithm: request.algorithm,
            ciphertext: request.ciphertext,
            createdAt: Date()
        )
        state.recoveryEnvelope = envelope
        spaces[spaceID] = state
        return envelope
    }

    public func createPairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        request: CreatePairing
    ) async throws -> Pairing {
        try request.validate()
        let (initial, membership) = try authorizedState(principal: principal, spaceID: spaceID)
        guard membership.role.canWrite else { throw SyncServiceError.forbidden }
        var state = initial
        state.pairings = state.pairings.filter { $0.value.value.expiresAt > Date() }
        guard state.pairings.count < 16 else { throw SyncServiceError.rateLimited(retryAfterSeconds: 60) }
        let value = Pairing(
            pairingID: UUID(),
            spaceID: spaceID,
            recipientPublicKey: request.recipientPublicKey,
            authenticationTag: request.authenticationTag,
            state: .pending,
            algorithm: nil,
            ciphertext: nil,
            expiresAt: Date().addingTimeInterval(TimeInterval(request.expiresInSeconds))
        )
        state.pairings[value.pairingID] = StoredPairing(value: value, recipientKeyHash: sha256(request.recipientPublicKey))
        spaces[spaceID] = state
        return value
    }

    public func approvePairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID,
        request: ApprovePairing
    ) async throws -> Pairing {
        try request.validate()
        let (initial, membership) = try authorizedState(principal: principal, spaceID: spaceID)
        guard membership.role.canWrite else { throw SyncServiceError.forbidden }
        guard var stored = initial.pairings[pairingID] else { throw SyncServiceError.notFound }
        guard stored.value.expiresAt > Date() else { throw SyncServiceError.pairingExpired }
        guard stored.value.state == .pending else { throw SyncServiceError.conflict }
        guard constantTimeEqual(request.recipientKeyHash, stored.recipientKeyHash) else {
            throw SyncServiceError.conflict
        }

        var state = initial
        stored.value = Pairing(
            pairingID: pairingID,
            spaceID: spaceID,
            recipientPublicKey: stored.value.recipientPublicKey,
            authenticationTag: stored.value.authenticationTag,
            state: .approved,
            algorithm: request.algorithm,
            ciphertext: request.ciphertext,
            expiresAt: stored.value.expiresAt
        )
        state.pairings[pairingID] = stored
        spaces[spaceID] = state
        return stored.value
    }

    public func pairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID
    ) async throws -> Pairing {
        let (state, _) = try authorizedState(principal: principal, spaceID: spaceID)
        guard let pairing = state.pairings[pairingID] else { throw SyncServiceError.notFound }
        guard pairing.value.expiresAt > Date() else { throw SyncServiceError.pairingExpired }
        return pairing.value
    }

    public func consumePairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID
    ) async throws {
        let (initial, _) = try authorizedState(principal: principal, spaceID: spaceID)
        guard initial.pairings[pairingID] != nil else { throw SyncServiceError.notFound }
        var state = initial
        state.pairings[pairingID] = nil
        spaces[spaceID] = state
    }

    /// Test/operator hook modeling restore or accepted-data loss. Production exposes
    /// the equivalent only through a migration-owner runbook, never an HTTP endpoint.
    public func rotateDataset(spaceID: UUID) throws {
        guard var state = spaces[spaceID] else { throw SyncServiceError.notFound }
        state.datasetGeneration = UUID()
        state.feedEpoch = UUID()
        state.nextSequence = 0
        state.changes = []
        for (recordID, stored) in state.records {
            let payload = RecordVersionPayload(
                serverInstanceID: serverInstanceID,
                spaceID: spaceID,
                datasetGeneration: state.datasetGeneration,
                recordID: recordID,
                generation: stored.generation
            )
            let version = try tokenCodec.encode(payload)
            state.records[recordID]?.value = ServerRecord(record: stored.value.record, recordVersion: version)
        }
        spaces[spaceID] = state
    }

    public func rotateFeedEpoch(spaceID: UUID) throws {
        guard var state = spaces[spaceID] else { throw SyncServiceError.notFound }
        state.feedEpoch = UUID()
        state.changes = []
        state.nextSequence = 0
        spaces[spaceID] = state
    }

    private func snapshotPage(
        state: SpaceState,
        scope: SpaceScope,
        after: UUID?,
        highWater: Int64,
        limit: Int
    ) throws -> ChangesPage {
        let ordered = state.records.values.sorted { $0.value.record.id.uuidString < $1.value.record.id.uuidString }
        let available = ordered.filter { stored in
            guard let after else { return true }
            return stored.value.record.id.uuidString > after.uuidString
        }
        let selected = Array(available.prefix(limit))
        let hasMore = available.count > selected.count
        let payload: CursorPayload
        if hasMore, let lastID = selected.last?.value.record.id {
            payload = CursorPayload(
                kind: .snapshot,
                serverInstanceID: serverInstanceID,
                spaceID: scope.spaceID,
                datasetGeneration: scope.datasetGeneration,
                feedEpoch: scope.feedEpoch,
                sequence: 0,
                snapshotAfterID: lastID,
                snapshotHighWater: highWater
            )
        } else {
            payload = CursorPayload(
                kind: .delta,
                serverInstanceID: serverInstanceID,
                spaceID: scope.spaceID,
                datasetGeneration: scope.datasetGeneration,
                feedEpoch: scope.feedEpoch,
                sequence: highWater
            )
        }
        return ChangesPage(
            scope: scope,
            records: selected.map(\.value),
            cursor: try tokenCodec.encode(payload),
            hasMore: hasMore,
            fullSnapshot: true
        )
    }

    private func authorizedState(
        principal: AuthenticatedPrincipal,
        spaceID: UUID
    ) throws -> (SpaceState, Membership) {
        guard let state = spaces[spaceID], let membership = state.memberships[principal.identityDigest] else {
            // Do not reveal whether another tenant owns the identifier.
            throw SyncServiceError.notFound
        }
        return (state, membership)
    }

    private func descriptor(spaceID: UUID, state: SpaceState, membership: Membership) -> SpaceDescriptor {
        SpaceDescriptor(
            scope: SpaceScope(
                spaceID: spaceID,
                scopeBinding: membership.scopeBinding,
                datasetGeneration: state.datasetGeneration,
                feedEpoch: state.feedEpoch
            ),
            role: membership.role,
            keyEpoch: state.keyEpoch
        )
    }
}
