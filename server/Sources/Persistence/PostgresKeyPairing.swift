import Foundation
import PostgresNIO
import SyncDomain

extension PostgresSyncStore {
    public func currentKeyEnvelope(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID
    ) async throws -> (SpaceDescriptor, KeyEnvelope?) {
        try await withAuthorizedTransaction(principal) { connection, userID in
            let space = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            let envelope = try await self.loadRecoveryEnvelope(connection: connection, spaceID: spaceID, forUpdate: false)
            return (space, envelope)
        }
    }

    public func putKeyEnvelope(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        request: PutKeyEnvelope
    ) async throws -> KeyEnvelope {
        try request.validate()
        return try await withAuthorizedTransaction(principal) { connection, userID in
            let space = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            guard space.role == .owner else { throw SyncServiceError.forbidden }
            guard request.keyEpoch == space.keyEpoch else { throw SyncServiceError.conflict }
            let envelopeLock = "key-envelope:\(spaceID.uuidString):recovery"
            try await drain(connection.querySanitized(
                "SELECT pg_advisory_xact_lock(hashtextextended(\(envelopeLock), 0))"
            ))
            let current = try await self.loadRecoveryEnvelope(connection: connection, spaceID: spaceID, forUpdate: true)
            guard current?.version == request.expectedVersion else { throw SyncServiceError.conflict }
            let version = (current?.version ?? 0) + 1
            let createdAt = Date()
            try await drain(connection.querySanitized("""
                INSERT INTO key_envelopes(
                    space_id, purpose, version, key_epoch, algorithm, ciphertext, created_at, updated_at
                ) VALUES (
                    \(spaceID), 'recovery', \(version), \(request.keyEpoch),
                    \(request.algorithm), \(request.ciphertext), \(createdAt), clock_timestamp()
                )
                ON CONFLICT (space_id, purpose) DO UPDATE SET
                    version = EXCLUDED.version,
                    key_epoch = EXCLUDED.key_epoch,
                    algorithm = EXCLUDED.algorithm,
                    ciphertext = EXCLUDED.ciphertext,
                    created_at = EXCLUDED.created_at,
                    updated_at = clock_timestamp()
                """))
            return KeyEnvelope(
                version: version,
                keyEpoch: request.keyEpoch,
                algorithm: request.algorithm,
                ciphertext: request.ciphertext,
                createdAt: createdAt
            )
        }
    }

    public func createPairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        request: CreatePairing
    ) async throws -> Pairing {
        try request.validate()
        return try await withAuthorizedTransaction(principal) { connection, userID in
            let space = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            guard space.role.canWrite else { throw SyncServiceError.forbidden }
            try await drain(connection.querySanitized("DELETE FROM pairings WHERE space_id = \(spaceID) AND expires_at <= clock_timestamp()"))
            let count = try await queryScalar(
                Int64.self,
                connection: connection,
                query: "SELECT count(*) FROM pairings WHERE space_id = \(spaceID)"
            ) ?? 0
            guard count < 16 else { throw SyncServiceError.rateLimited(retryAfterSeconds: 60) }
            let pairingID = UUID()
            let expiresAt = Date().addingTimeInterval(TimeInterval(request.expiresInSeconds))
            let keyHash = sha256(request.recipientPublicKey)
            try await drain(connection.querySanitized("""
                INSERT INTO pairings(
                    space_id, pairing_id, recipient_public_key, recipient_key_hash,
                    authentication_tag, expires_at
                ) VALUES (
                    \(spaceID), \(pairingID), \(request.recipientPublicKey), \(keyHash),
                    \(request.authenticationTag), \(expiresAt)
                )
                """))
            return Pairing(
                pairingID: pairingID,
                spaceID: spaceID,
                recipientPublicKey: request.recipientPublicKey,
                authenticationTag: request.authenticationTag,
                state: .pending,
                algorithm: nil,
                ciphertext: nil,
                expiresAt: expiresAt
            )
        }
    }

    public func approvePairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID,
        request: ApprovePairing
    ) async throws -> Pairing {
        try request.validate()
        return try await withAuthorizedTransaction(principal) { connection, userID in
            let space = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            guard space.role.canWrite else { throw SyncServiceError.forbidden }
            guard let stored = try await self.loadPairing(
                connection: connection,
                spaceID: spaceID,
                pairingID: pairingID,
                forUpdate: true
            ) else { throw SyncServiceError.notFound }
            guard stored.value.expiresAt > Date() else { throw SyncServiceError.pairingExpired }
            guard stored.value.state == .pending,
                  constantTimeEqual(stored.recipientKeyHash, request.recipientKeyHash)
            else { throw SyncServiceError.conflict }
            let approvedAt = Date()
            try await drain(connection.querySanitized("""
                UPDATE pairings
                   SET algorithm = \(request.algorithm), ciphertext = \(request.ciphertext), approved_at = \(approvedAt)
                 WHERE space_id = \(spaceID) AND pairing_id = \(pairingID) AND approved_at IS NULL
                """))
            return Pairing(
                pairingID: pairingID,
                spaceID: spaceID,
                recipientPublicKey: stored.value.recipientPublicKey,
                authenticationTag: stored.value.authenticationTag,
                state: .approved,
                algorithm: request.algorithm,
                ciphertext: request.ciphertext,
                expiresAt: stored.value.expiresAt
            )
        }
    }

    public func pairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID
    ) async throws -> Pairing {
        try await withAuthorizedTransaction(principal) { connection, userID in
            _ = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            guard let stored = try await self.loadPairing(
                connection: connection,
                spaceID: spaceID,
                pairingID: pairingID,
                forUpdate: false
            ) else { throw SyncServiceError.notFound }
            guard stored.value.expiresAt > Date() else { throw SyncServiceError.pairingExpired }
            return stored.value
        }
    }

    public func consumePairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID
    ) async throws {
        try await withAuthorizedTransaction(principal) { connection, userID in
            _ = try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
            guard try await self.loadPairing(
                connection: connection,
                spaceID: spaceID,
                pairingID: pairingID,
                forUpdate: true
            ) != nil else { throw SyncServiceError.notFound }
            try await drain(connection.querySanitized("DELETE FROM pairings WHERE space_id = \(spaceID) AND pairing_id = \(pairingID)"))
        }
    }

    struct StoredPairing: Sendable {
        let value: Pairing
        let recipientKeyHash: Data
    }

    func loadRecoveryEnvelope(
        connection: PostgresConnection,
        spaceID: UUID,
        forUpdate: Bool
    ) async throws -> KeyEnvelope? {
        let rows: PostgresRowSequence
        if forUpdate {
            rows = try await connection.querySanitized("""
                SELECT version, key_epoch, algorithm, ciphertext, created_at
                  FROM key_envelopes
                 WHERE space_id = \(spaceID) AND purpose = 'recovery'
                 FOR UPDATE
                """)
        } else {
            rows = try await connection.querySanitized("""
                SELECT version, key_epoch, algorithm, ciphertext, created_at
                  FROM key_envelopes
                 WHERE space_id = \(spaceID) AND purpose = 'recovery'
                """)
        }
        var result: KeyEnvelope?
        for try await (version, keyEpoch, algorithm, ciphertext, createdAt) in rows.decode(
            (Int, Int, String, Data, Date).self
        ) {
            result = .init(
                version: version,
                keyEpoch: keyEpoch,
                algorithm: algorithm,
                ciphertext: ciphertext,
                createdAt: createdAt
            )
        }
        return result
    }

    func loadPairing(
        connection: PostgresConnection,
        spaceID: UUID,
        pairingID: UUID,
        forUpdate: Bool
    ) async throws -> StoredPairing? {
        let rows: PostgresRowSequence
        if forUpdate {
            rows = try await connection.querySanitized("""
                SELECT recipient_public_key, recipient_key_hash, authentication_tag,
                       algorithm, ciphertext, approved_at, expires_at
                  FROM pairings
                 WHERE space_id = \(spaceID) AND pairing_id = \(pairingID)
                 FOR UPDATE
                """)
        } else {
            rows = try await connection.querySanitized("""
                SELECT recipient_public_key, recipient_key_hash, authentication_tag,
                       algorithm, ciphertext, approved_at, expires_at
                  FROM pairings
                 WHERE space_id = \(spaceID) AND pairing_id = \(pairingID)
                """)
        }
        var result: StoredPairing?
        for try await (publicKey, keyHash, tag, algorithm, ciphertext, approvedAt, expiresAt) in rows.decode(
            (Data, Data, String, String?, Data?, Date?, Date).self
        ) {
            result = .init(
                value: Pairing(
                    pairingID: pairingID,
                    spaceID: spaceID,
                    recipientPublicKey: publicKey,
                    authenticationTag: tag,
                    state: approvedAt == nil ? .pending : .approved,
                    algorithm: algorithm,
                    ciphertext: ciphertext,
                    expiresAt: expiresAt
                ),
                recipientKeyHash: keyHash
            )
        }
        return result
    }
}
