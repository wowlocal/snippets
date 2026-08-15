import Foundation
import PostgresNIO
import SyncDomain

public final class PostgresSyncStore: SyncStore, Sendable {
    let client: PostgresClient
    let serverInstanceID: UUID
    let tokenCodec: OpaqueTokenCodec

    public init(client: PostgresClient, serverInstanceID: UUID, tokenSecret: Data) throws {
        self.client = client
        self.serverInstanceID = serverInstanceID
        self.tokenCodec = try OpaqueTokenCodec(secret: tokenSecret)
    }

    public func readiness() async throws {
        try await drain(client.query("SELECT 1"))
    }

    public func listSpaces(for principal: AuthenticatedPrincipal) async throws -> [SpaceDescriptor] {
        try await withAuthorizedTransaction(principal) { connection, userID in
            let rows = try await connection.querySanitized("""
                SELECT s.id, s.dataset_generation, s.feed_epoch, s.key_epoch,
                       sm.role, sm.scope_binding
                  FROM spaces s
                  JOIN space_memberships sm ON sm.space_id = s.id
                 WHERE sm.user_id = \(userID)
                 ORDER BY s.id
                """)
            var result: [SpaceDescriptor] = []
            for try await (spaceID, dataset, feed, keyEpoch, role, binding) in rows.decode(
                (UUID, UUID, UUID, Int, String, Data).self
            ) {
                guard let role = SpaceRole(rawValue: role) else { throw SyncServiceError.internalError }
                result.append(self.descriptor(
                    spaceID: spaceID,
                    dataset: dataset,
                    feed: feed,
                    keyEpoch: keyEpoch,
                    role: role,
                    scopeBinding: binding
                ))
            }
            return result
        }
    }

    public func createSpace(
        for principal: AuthenticatedPrincipal,
        idempotencyKey: UUID?
    ) async throws -> SpaceDescriptor {
        try await withAuthorizedTransaction(principal) { connection, userID in
            let createLock = "space-create:\(userID.uuidString)"
            try await drain(connection.querySanitized(
                "SELECT pg_advisory_xact_lock(hashtextextended(\(createLock), 0))"
            ))
            if let idempotencyKey {
                if let existingID = try await queryScalar(
                    UUID.self,
                    connection: connection,
                    query: "SELECT space_id FROM space_creation_requests WHERE user_id = \(userID) AND idempotency_key = \(idempotencyKey)"
                ) {
                    return try await self.loadScope(connection: connection, userID: userID, spaceID: existingID)
                }
            }
            let ownedSpaceCount = try await queryScalar(
                Int64.self,
                connection: connection,
                query: "SELECT count(*) FROM spaces WHERE owner_user_id = \(userID)"
            ) ?? 0
            guard ownedSpaceCount < SyncLimits.maxSpacesPerUser else {
                throw SyncServiceError.quotaExceeded(limit: SyncLimits.maxSpacesPerUser)
            }

            let spaceID = UUID()
            let dataset = UUID()
            let feed = UUID()
            let binding = randomBytes(count: 32)
            try await drain(connection.querySanitized("""
                INSERT INTO spaces(id, owner_user_id, dataset_generation, feed_epoch, key_epoch, next_sequence)
                VALUES (\(spaceID), \(userID), \(dataset), \(feed), 1, 0)
                """))
            try await drain(connection.querySanitized("""
                INSERT INTO space_memberships(space_id, user_id, role, scope_binding)
                VALUES (\(spaceID), \(userID), 'owner', \(binding))
                """))
            if let idempotencyKey {
                try await drain(connection.querySanitized("""
                    INSERT INTO space_creation_requests(user_id, idempotency_key, space_id)
                    VALUES (\(userID), \(idempotencyKey), \(spaceID))
                    """))
            }
            return self.descriptor(
                spaceID: spaceID,
                dataset: dataset,
                feed: feed,
                keyEpoch: 1,
                role: .owner,
                scopeBinding: binding
            )
        }
    }

    public func scope(for principal: AuthenticatedPrincipal, spaceID: UUID) async throws -> SpaceDescriptor {
        try await withAuthorizedTransaction(principal) { connection, userID in
            try await self.loadScope(connection: connection, userID: userID, spaceID: spaceID)
        }
    }

    func withAuthorizedTransaction<Result: Sendable>(
        _ principal: AuthenticatedPrincipal,
        _ operation: @escaping @Sendable (PostgresConnection, UUID) async throws -> Result
    ) async throws -> Result {
        do {
            return try await client.withTransaction(logger: disabledPostgresLogger) { connection in
                try await self.lockAccessCredential(connection: connection, principal: principal)
                let revoked = try await queryScalar(
                    Bool.self,
                    connection: connection,
                    query: "SELECT snippets_private.is_access_token_revoked(\(principal.credentialDigest))"
                ) ?? true
                guard !revoked else { throw SyncServiceError.authenticationRequired }
                let candidate = UUID()
                guard let userID = try await queryScalar(
                    UUID.self,
                    connection: connection,
                    query: "SELECT snippets_private.resolve_identity(\(principal.identityDigest), \(candidate))"
                ) else { throw SyncServiceError.internalError }
                try await drain(connection.querySanitized("SELECT set_config('app.user_id', \(userID.uuidString), true)"))
                guard let status = try await queryScalar(
                    String.self,
                    connection: connection,
                    query: "SELECT status FROM users WHERE id = \(userID)"
                ), status == "active" else { throw SyncServiceError.authenticationRequired }
                return try await operation(connection, userID)
            }
        } catch let transactionError as PostgresTransactionError {
            // postgres-nio wraps every error thrown by a transaction closure so it
            // can also report rollback failures. Preserve an intentional service
            // result only when the rollback itself succeeded; infrastructure
            // failures must stay collapsed to the dependency boundary.
            if transactionError.rollbackError == nil,
               let serviceError = transactionError.closureError as? SyncServiceError {
                throw serviceError
            }
            throw SyncServiceError.dependencyUnavailable
        } catch let error as SyncServiceError {
            throw error
        } catch {
            // Database errors never cross the service boundary with query, bind,
            // path, identifier, or vendor-provided arbitrary text attached.
            throw SyncServiceError.dependencyUnavailable
        }
    }

    func loadScope(connection: PostgresConnection, userID: UUID, spaceID: UUID) async throws -> SpaceDescriptor {
        let rows = try await connection.querySanitized("""
            SELECT s.dataset_generation, s.feed_epoch, s.key_epoch, sm.role, sm.scope_binding
              FROM spaces s
              JOIN space_memberships sm ON sm.space_id = s.id
             WHERE s.id = \(spaceID) AND sm.user_id = \(userID)
            """)
        for try await (dataset, feed, keyEpoch, roleValue, binding) in rows.decode(
            (UUID, UUID, Int, String, Data).self
        ) {
            guard let role = SpaceRole(rawValue: roleValue) else { throw SyncServiceError.internalError }
            return descriptor(
                spaceID: spaceID,
                dataset: dataset,
                feed: feed,
                keyEpoch: keyEpoch,
                role: role,
                scopeBinding: binding
            )
        }
        throw SyncServiceError.notFound
    }

    func descriptor(
        spaceID: UUID,
        dataset: UUID,
        feed: UUID,
        keyEpoch: Int,
        role: SpaceRole,
        scopeBinding: Data
    ) -> SpaceDescriptor {
        SpaceDescriptor(
            scope: .init(
                spaceID: spaceID,
                scopeBinding: scopeBinding.base64URL,
                datasetGeneration: dataset,
                feedEpoch: feed
            ),
            role: role,
            keyEpoch: keyEpoch
        )
    }
}
