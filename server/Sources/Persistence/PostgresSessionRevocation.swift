import Foundation
import PostgresNIO
import SyncDomain

extension PostgresSyncStore {
    func lockAccessCredential(
        connection: PostgresConnection,
        principal: AuthenticatedPrincipal
    ) async throws {
        // Every data-plane transaction and logout use this same transaction-scoped
        // lock. Across all server instances, either an already-authorized operation
        // commits before logout's 204, or logout commits first and the operation sees
        // the denylist entry while still holding the lock.
        try await drain(connection.querySanitized("""
            SELECT pg_advisory_xact_lock(
                hashtextextended('credential:' || encode(\(principal.credentialDigest), 'hex'), 0)
            )
            """))
    }

    public func isAccessTokenRevoked(for principal: AuthenticatedPrincipal) async throws -> Bool {
        do {
            return try await client.withConnection { connection in
                try await queryScalar(
                    Bool.self,
                    connection: connection,
                    query: "SELECT snippets_private.is_access_token_revoked(\(principal.credentialDigest))"
                ) ?? true
            }
        } catch let error as SyncServiceError {
            throw error
        } catch {
            // Authentication must fail closed when the shared revocation registry
            // cannot be consulted on a multi-instance deployment.
            throw SyncServiceError.dependencyUnavailable
        }
    }

    public func revokeAccessToken(for principal: AuthenticatedPrincipal) async throws {
        do {
            try await client.withTransaction(logger: disabledPostgresLogger) { connection in
                try await self.lockAccessCredential(connection: connection, principal: principal)
                try await drain(connection.querySanitized(
                    "SELECT snippets_private.revoke_access_token(\(principal.credentialDigest), \(principal.credentialExpiresAt))"
                ))
            }
        } catch let transactionError as PostgresTransactionError {
            if transactionError.rollbackError == nil,
               let serviceError = transactionError.closureError as? SyncServiceError {
                throw serviceError
            }
            throw SyncServiceError.dependencyUnavailable
        } catch let error as SyncServiceError {
            throw error
        } catch {
            throw SyncServiceError.dependencyUnavailable
        }
    }
}
