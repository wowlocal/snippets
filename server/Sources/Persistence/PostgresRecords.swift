import Foundation
import PostgresNIO
import SyncDomain

extension PostgresSyncStore {
    struct DatabaseRecord: Sendable {
        let value: ServerRecord
        let generation: Int64
    }

    struct SequencedRecord: Sendable {
        let sequence: Int64
        let value: ServerRecord
    }

    public func fetchChanges(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        cursor: String?,
        limit: Int
    ) async throws -> ChangesPage {
        guard (1...SyncLimits.maxPageRecords).contains(limit) else { throw SyncServiceError.invalidRequest }
        return try await withAuthorizedTransaction(principal) { connection, userID in
            let space = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            if cursor == nil {
                guard let highWater = try await queryScalar(
                    Int64.self,
                    connection: connection,
                    query: "SELECT next_sequence FROM spaces WHERE id = \(spaceID)"
                ) else { throw SyncServiceError.notFound }
                return try await self.snapshotPage(
                    connection: connection,
                    space: space,
                    after: nil,
                    highWater: highWater,
                    limit: limit
                )
            }

            let payload: CursorPayload = try self.tokenCodec.decode(CursorPayload.self, token: cursor!)
            guard payload.version == 1,
                  payload.serverInstanceID == self.serverInstanceID,
                  payload.spaceID == spaceID
            else { throw SyncServiceError.cursorInvalid }
            guard payload.datasetGeneration == space.scope.datasetGeneration else { throw SyncServiceError.datasetReset }
            guard payload.feedEpoch == space.scope.feedEpoch else { throw SyncServiceError.cursorInvalid }

            switch payload.kind {
            case .snapshot:
                return try await self.snapshotPage(
                    connection: connection,
                    space: space,
                    after: payload.snapshotAfterID,
                    highWater: payload.snapshotHighWater,
                    limit: limit
                )
            case .delta:
                let rows = try await connection.querySanitized("""
                    SELECT sequence, record_id, rev, deleted, blob, record_version
                      FROM changes
                     WHERE space_id = \(spaceID) AND sequence > \(payload.sequence)
                     ORDER BY sequence
                     LIMIT \(limit + 1)
                    """)
                var values: [SequencedRecord] = []
                for try await (sequence, id, rev, deleted, blob, version) in rows.decode(
                    (Int64, UUID, String, Bool, Data, String).self
                ) {
                    values.append(.init(
                        sequence: sequence,
                        value: .init(record: .init(id: id, rev: rev, deleted: deleted, blob: blob), recordVersion: version)
                    ))
                }
                let hasMore = values.count > limit
                if hasMore { values.removeLast() }
                let nextSequence = values.last?.sequence ?? payload.sequence
                let nextCursor = try self.tokenCodec.encode(CursorPayload(
                    kind: .delta,
                    serverInstanceID: self.serverInstanceID,
                    spaceID: spaceID,
                    datasetGeneration: space.scope.datasetGeneration,
                    feedEpoch: space.scope.feedEpoch,
                    sequence: nextSequence
                ))
                return ChangesPage(
                    scope: space.scope,
                    records: values.map(\.value),
                    cursor: nextCursor,
                    hasMore: hasMore,
                    fullSnapshot: false
                )
            }
        }
    }

    public func submit(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        items: [BatchItem]
    ) async throws -> BatchSubmission {
        guard !items.isEmpty, items.count <= SyncLimits.maxBatchRecords,
              Set(items.map(\.record.id)).count == items.count
        else { throw SyncServiceError.invalidRequest }

        return try await withAuthorizedTransaction(principal) { connection, userID in
            let space = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            guard space.role.canWrite else { throw SyncServiceError.forbidden }
            var results: [Int: BatchOutcome] = [:]
            let ordered = items.enumerated().sorted { $0.element.record.id.uuidString < $1.element.record.id.uuidString }

            for (index, item) in ordered {
                do {
                    try item.record.validate()
                    if let expected = item.expectedRecordVersion,
                       !(32...2_048).contains(expected.utf8.count) {
                        throw SyncServiceError.invalidRequest
                    }
                } catch let error as SyncServiceError {
                    results[index] = .rejected(code: error.code)
                    continue
                }

                // A row lock cannot serialize two concurrent creates because
                // there is no row yet. The transaction-scoped advisory lock
                // makes create and update CAS linearizable for this record.
                let recordLock = "record:\(spaceID.uuidString):\(item.record.id.uuidString)"
                try await drain(connection.querySanitized(
                    "SELECT pg_advisory_xact_lock(hashtextextended(\(recordLock), 0))"
                ))
                let current = try await self.loadRecord(
                    connection: connection,
                    spaceID: spaceID,
                    recordID: item.record.id,
                    forUpdate: true
                )
                let matches: Bool
                if let expected = item.expectedRecordVersion {
                    matches = current?.value.recordVersion == expected
                } else {
                    matches = current == nil
                }
                guard matches else {
                    results[index] = .conflict(authoritative: current?.value)
                    continue
                }

                guard let sequence = try await queryScalar(
                    Int64.self,
                    connection: connection,
                    query: "UPDATE spaces SET next_sequence = next_sequence + 1 WHERE id = \(spaceID) RETURNING next_sequence"
                ) else { throw SyncServiceError.notFound }
                let generation = (current?.generation ?? 0) + 1
                let version = try self.tokenCodec.encode(RecordVersionPayload(
                    serverInstanceID: self.serverInstanceID,
                    spaceID: spaceID,
                    datasetGeneration: space.scope.datasetGeneration,
                    recordID: item.record.id,
                    generation: generation
                ))
                try await drain(connection.querySanitized("""
                    INSERT INTO records(
                        space_id, record_id, rev, deleted, blob,
                        record_generation, record_version, last_sequence, updated_at
                    ) VALUES (
                        \(spaceID), \(item.record.id), \(item.record.rev), \(item.record.deleted), \(item.record.blob),
                        \(generation), \(version), \(sequence), clock_timestamp()
                    )
                    ON CONFLICT (space_id, record_id) DO UPDATE SET
                        rev = EXCLUDED.rev,
                        deleted = EXCLUDED.deleted,
                        blob = EXCLUDED.blob,
                        record_generation = EXCLUDED.record_generation,
                        record_version = EXCLUDED.record_version,
                        last_sequence = EXCLUDED.last_sequence,
                        updated_at = clock_timestamp()
                    """))
                try await drain(connection.querySanitized("""
                    INSERT INTO changes(
                        space_id, sequence, record_id, rev, deleted, blob,
                        record_generation, record_version
                    ) VALUES (
                        \(spaceID), \(sequence), \(item.record.id), \(item.record.rev),
                        \(item.record.deleted), \(item.record.blob), \(generation), \(version)
                    )
                    """))
                results[index] = .accepted(recordVersion: version, revision: item.record.rev)
            }

            let outcomes = items.indices.map { results[$0] ?? .rejected(code: .internalError) }
            let partial = outcomes.contains { value in
                if case .accepted = value { return false }
                return true
            }
            return BatchSubmission(scope: space.scope, outcomes: outcomes, partial: partial)
        }
    }

    func snapshotPage(
        connection: PostgresConnection,
        space: SpaceDescriptor,
        after: UUID?,
        highWater: Int64,
        limit: Int
    ) async throws -> ChangesPage {
        let rows: PostgresRowSequence
        if let after {
            rows = try await connection.querySanitized("""
                SELECT record_id, rev, deleted, blob, record_version
                  FROM records
                 WHERE space_id = \(space.scope.spaceID)
                   AND record_id > \(after)
                   AND last_sequence <= \(highWater)
                 ORDER BY record_id
                 LIMIT \(limit + 1)
                """)
        } else {
            rows = try await connection.querySanitized("""
                SELECT record_id, rev, deleted, blob, record_version
                  FROM records
                 WHERE space_id = \(space.scope.spaceID)
                   AND last_sequence <= \(highWater)
                 ORDER BY record_id
                 LIMIT \(limit + 1)
                """)
        }
        var records: [ServerRecord] = []
        for try await (id, rev, deleted, blob, version) in rows.decode((UUID, String, Bool, Data, String).self) {
            records.append(.init(record: .init(id: id, rev: rev, deleted: deleted, blob: blob), recordVersion: version))
        }
        let hasMore = records.count > limit
        if hasMore { records.removeLast() }
        let payload: CursorPayload
        if hasMore, let lastID = records.last?.record.id {
            payload = CursorPayload(
                kind: .snapshot,
                serverInstanceID: serverInstanceID,
                spaceID: space.scope.spaceID,
                datasetGeneration: space.scope.datasetGeneration,
                feedEpoch: space.scope.feedEpoch,
                sequence: 0,
                snapshotAfterID: lastID,
                snapshotHighWater: highWater
            )
        } else {
            payload = CursorPayload(
                kind: .delta,
                serverInstanceID: serverInstanceID,
                spaceID: space.scope.spaceID,
                datasetGeneration: space.scope.datasetGeneration,
                feedEpoch: space.scope.feedEpoch,
                sequence: highWater
            )
        }
        return ChangesPage(
            scope: space.scope,
            records: records,
            cursor: try tokenCodec.encode(payload),
            hasMore: hasMore,
            fullSnapshot: true
        )
    }

    func loadRecord(
        connection: PostgresConnection,
        spaceID: UUID,
        recordID: UUID,
        forUpdate: Bool
    ) async throws -> DatabaseRecord? {
        let rows: PostgresRowSequence
        if forUpdate {
            rows = try await connection.querySanitized("""
                SELECT rev, deleted, blob, record_version, record_generation
                  FROM records
                 WHERE space_id = \(spaceID) AND record_id = \(recordID)
                 FOR UPDATE
                """)
        } else {
            rows = try await connection.querySanitized("""
                SELECT rev, deleted, blob, record_version, record_generation
                  FROM records
                 WHERE space_id = \(spaceID) AND record_id = \(recordID)
                """)
        }
        var result: DatabaseRecord?
        for try await (rev, deleted, blob, version, generation) in rows.decode((String, Bool, Data, String, Int64).self) {
            result = .init(
                value: .init(record: .init(id: recordID, rev: rev, deleted: deleted, blob: blob), recordVersion: version),
                generation: generation
            )
        }
        return result
    }
}
