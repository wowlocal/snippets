import Foundation
import SyncDomain
import SyncOpenAPI

enum OpenAPIMapping {
    static func scope(_ value: SpaceScope) -> Components.Schemas.Scope {
        .init(
            spaceId: value.spaceID.uuidString.lowercased(),
            scopeBinding: value.scopeBinding,
            datasetGeneration: value.datasetGeneration.uuidString.lowercased(),
            feedEpoch: value.feedEpoch.uuidString.lowercased()
        )
    }

    static func space(_ value: SpaceDescriptor) -> Components.Schemas.Space {
        .init(
            value1: scope(value.scope),
            value2: .init(role: .init(rawValue: value.role.rawValue)!, keyEpoch: value.keyEpoch)
        )
    }

    static func wire(_ value: OpaqueWireRecord) -> Components.Schemas.WireRecord {
        .init(
            id: value.id.uuidString.lowercased(),
            rev: value.rev,
            deleted: value.deleted,
            blob: value.blob.base64EncodedString()
        )
    }

    static func wire(_ value: Components.Schemas.WireRecord) throws -> OpaqueWireRecord {
        guard let id = UUID(uuidString: value.id),
              let blob = Data(base64Encoded: value.blob),
              blob.base64EncodedString() == value.blob
        else { throw SyncServiceError.invalidRequest }
        return OpaqueWireRecord(id: id, rev: value.rev, deleted: value.deleted, blob: blob)
    }

    static func serverRecord(_ value: ServerRecord) -> Components.Schemas.ServerRecord {
        .init(value1: wire(value.record), value2: .init(recordVersion: value.recordVersion))
    }

    static func changes(_ value: ChangesPage) -> Components.Schemas.ChangesPage {
        .init(
            value1: scope(value.scope),
            value2: .init(
                records: value.records.map(serverRecord),
                cursor: value.cursor,
                hasMore: value.hasMore,
                fullSnapshot: value.fullSnapshot
            )
        )
    }

    static func batch(_ value: BatchSubmission) -> Components.Schemas.BatchResponse {
        .init(
            value1: scope(value.scope),
            value2: .init(outcomes: value.outcomes.map(batchOutcome), partial: value.partial)
        )
    }

    static func batchOutcome(_ value: SyncDomain.BatchOutcome) -> Components.Schemas.BatchOutcome {
        switch value {
        case .accepted(let version, let revision):
            .init(kind: .accepted, recordVersion: version, revision: revision)
        case .conflict(let authoritative):
            .init(kind: .conflict, authoritativeRecord: authoritative.map(serverRecord))
        case .rejected(let code, let retry):
            .init(
                kind: .rejected,
                errorCode: .init(rawValue: code.rawValue),
                retryAfterSeconds: retry
            )
        }
    }

    static func keyEnvelope(_ value: KeyEnvelope) -> Components.Schemas.KeyEnvelope {
        .init(
            purpose: .recovery,
            version: value.version,
            keyEpoch: value.keyEpoch,
            algorithm: value.algorithm,
            ciphertext: value.ciphertext.base64EncodedString(),
            createdAt: value.createdAt
        )
    }

    static func pairing(_ value: SyncDomain.Pairing) -> Components.Schemas.Pairing {
        .init(
            pairingId: value.pairingID.uuidString.lowercased(),
            spaceId: value.spaceID.uuidString.lowercased(),
            recipientPublicKey: value.recipientPublicKey.base64EncodedString(),
            authenticationTag: value.authenticationTag,
            state: .init(rawValue: value.state.rawValue)!,
            algorithm: value.algorithm,
            ciphertext: value.ciphertext?.base64EncodedString(),
            expiresAt: value.expiresAt
        )
    }

    static func error(_ value: SyncServiceError, requestID: UUID = UUID()) -> Components.Schemas._Error {
        .init(
            code: .init(rawValue: value.code.rawValue) ?? .internalError,
            requestId: requestID.uuidString.lowercased(),
            retryAfterSeconds: value.safeRetryAfterSeconds,
            limit: value.safeLimit
        )
    }

    static func requiredPrincipal() throws -> AuthenticatedPrincipal {
        guard let principal = RequestIdentity.principal else { throw SyncServiceError.authenticationRequired }
        return principal
    }

    static func uuid(_ value: String) throws -> UUID {
        guard let value = UUID(uuidString: value) else { throw SyncServiceError.invalidRequest }
        return value
    }

    static func canonicalBase64(_ value: String, maximumBytes: Int) throws -> Data {
        guard let data = Data(base64Encoded: value),
              data.base64EncodedString() == value,
              data.count <= maximumBytes
        else { throw SyncServiceError.invalidRequest }
        return data
    }
}
