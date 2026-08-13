import Foundation

public enum SyncLimits {
    public static let maxBlobBytes = 900_000
    public static let maxRevisionBytes = 256
    public static let maxBatchRecords = 50
    public static let maxPageRecords = 50
    public static let maxRequestBytes = 16 * 1_024 * 1_024
    public static let maxResponseBytes = 64 * 1_024 * 1_024
    public static let maxSpacesPerUser = 100
    public static let maxKeyEnvelopeBytes = 262_144
    public static let maxPairingPublicKeyBytes = 384
    public static let maxPairingSeconds = 600
}

/// An authenticated identity reduced to a keyed, non-reversible lookup digest.
/// Raw OIDC issuer/subject values never enter persistence or application logs.
public struct AuthenticatedPrincipal: Hashable, Sendable {
    public let identityDigest: Data

    public init(identityDigest: Data) throws {
        guard identityDigest.count == 32 else { throw SyncServiceError.authenticationRequired }
        self.identityDigest = identityDigest
    }
}

public enum SpaceRole: String, Codable, Sendable {
    case owner
    case writer
    case reader

    public var canWrite: Bool { self == .owner || self == .writer }
}

public struct SpaceScope: Codable, Equatable, Sendable {
    public let spaceID: UUID
    public let scopeBinding: String
    public let datasetGeneration: UUID
    public let feedEpoch: UUID

    public init(spaceID: UUID, scopeBinding: String, datasetGeneration: UUID, feedEpoch: UUID) {
        self.spaceID = spaceID
        self.scopeBinding = scopeBinding
        self.datasetGeneration = datasetGeneration
        self.feedEpoch = feedEpoch
    }
}

public struct SpaceDescriptor: Codable, Equatable, Sendable {
    public let scope: SpaceScope
    public let role: SpaceRole
    public let keyEpoch: Int

    public init(scope: SpaceScope, role: SpaceRole, keyEpoch: Int) {
        self.scope = scope
        self.role = role
        self.keyEpoch = keyEpoch
    }
}

/// The exact outer record shared by CloudKit and the HTTP transport.
/// `blob` is never interpreted by server code.
public struct OpaqueWireRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let rev: String
    public let deleted: Bool
    public let blob: Data

    public init(id: UUID, rev: String, deleted: Bool, blob: Data) {
        self.id = id
        self.rev = rev
        self.deleted = deleted
        self.blob = blob
    }

    public func validate() throws {
        let revisionBytes = rev.lengthOfBytes(using: .utf8)
        guard revisionBytes > 0, revisionBytes <= SyncLimits.maxRevisionBytes else {
            throw SyncServiceError.invalidRecord(.revisionSize)
        }
        guard blob.count <= SyncLimits.maxBlobBytes else {
            throw SyncServiceError.invalidRecord(.blobSize)
        }
    }
}

public struct ServerRecord: Codable, Equatable, Sendable {
    public let record: OpaqueWireRecord
    public let recordVersion: String

    public init(record: OpaqueWireRecord, recordVersion: String) {
        self.record = record
        self.recordVersion = recordVersion
    }
}

public struct BatchItem: Codable, Equatable, Sendable {
    public let record: OpaqueWireRecord
    public let expectedRecordVersion: String?

    public init(record: OpaqueWireRecord, expectedRecordVersion: String?) {
        self.record = record
        self.expectedRecordVersion = expectedRecordVersion
    }
}

public enum BatchOutcome: Equatable, Sendable {
    case accepted(recordVersion: String, revision: String)
    case conflict(authoritative: ServerRecord?)
    case rejected(code: SyncErrorCode, retryAfterSeconds: Int? = nil)
}

extension BatchOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, recordVersion, revision, authoritativeRecord, errorCode, retryAfterSeconds
    }

    private enum Kind: String, Codable { case accepted, conflict, rejected }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .accepted:
            self = .accepted(
                recordVersion: try values.decode(String.self, forKey: .recordVersion),
                revision: try values.decode(String.self, forKey: .revision)
            )
        case .conflict:
            self = .conflict(authoritative: try values.decodeIfPresent(ServerRecord.self, forKey: .authoritativeRecord))
        case .rejected:
            self = .rejected(
                code: try values.decode(SyncErrorCode.self, forKey: .errorCode),
                retryAfterSeconds: try values.decodeIfPresent(Int.self, forKey: .retryAfterSeconds)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted(let version, let revision):
            try values.encode(Kind.accepted, forKey: .kind)
            try values.encode(version, forKey: .recordVersion)
            try values.encode(revision, forKey: .revision)
        case .conflict(let authoritative):
            try values.encode(Kind.conflict, forKey: .kind)
            try values.encodeIfPresent(authoritative, forKey: .authoritativeRecord)
        case .rejected(let code, let retry):
            try values.encode(Kind.rejected, forKey: .kind)
            try values.encode(code, forKey: .errorCode)
            try values.encodeIfPresent(retry, forKey: .retryAfterSeconds)
        }
    }
}

public struct BatchSubmission: Codable, Equatable, Sendable {
    public let scope: SpaceScope
    public let outcomes: [BatchOutcome]
    public let partial: Bool

    public init(scope: SpaceScope, outcomes: [BatchOutcome], partial: Bool) {
        self.scope = scope
        self.outcomes = outcomes
        self.partial = partial
    }
}

public struct ChangesPage: Codable, Equatable, Sendable {
    public let scope: SpaceScope
    public let records: [ServerRecord]
    public let cursor: String
    public let hasMore: Bool
    public let fullSnapshot: Bool

    public init(scope: SpaceScope, records: [ServerRecord], cursor: String, hasMore: Bool, fullSnapshot: Bool) {
        self.scope = scope
        self.records = records
        self.cursor = cursor
        self.hasMore = hasMore
        self.fullSnapshot = fullSnapshot
    }
}

public struct KeyEnvelope: Codable, Equatable, Sendable {
    public let purpose: String
    public let version: Int
    public let keyEpoch: Int
    public let algorithm: String
    public let ciphertext: Data
    public let createdAt: Date

    public init(purpose: String = "recovery", version: Int, keyEpoch: Int, algorithm: String, ciphertext: Data, createdAt: Date) {
        self.purpose = purpose
        self.version = version
        self.keyEpoch = keyEpoch
        self.algorithm = algorithm
        self.ciphertext = ciphertext
        self.createdAt = createdAt
    }
}

public struct PutKeyEnvelope: Codable, Equatable, Sendable {
    public let expectedVersion: Int?
    public let keyEpoch: Int
    public let algorithm: String
    public let ciphertext: Data

    public init(expectedVersion: Int?, keyEpoch: Int, algorithm: String, ciphertext: Data) {
        self.expectedVersion = expectedVersion
        self.keyEpoch = keyEpoch
        self.algorithm = algorithm
        self.ciphertext = ciphertext
    }

    public func validate() throws {
        guard keyEpoch > 0, !algorithm.isEmpty, algorithm.utf8.count <= 64 else {
            throw SyncServiceError.invalidRequest
        }
        guard ciphertext.count <= SyncLimits.maxKeyEnvelopeBytes else {
            throw SyncServiceError.payloadTooLarge(limit: SyncLimits.maxKeyEnvelopeBytes)
        }
    }
}

public enum PairingState: String, Codable, Sendable { case pending, approved }

public struct Pairing: Codable, Equatable, Sendable {
    public let pairingID: UUID
    public let spaceID: UUID
    public let recipientPublicKey: Data
    public let authenticationTag: String
    public let state: PairingState
    public let algorithm: String?
    public let ciphertext: Data?
    public let expiresAt: Date

    public init(
        pairingID: UUID,
        spaceID: UUID,
        recipientPublicKey: Data,
        authenticationTag: String,
        state: PairingState,
        algorithm: String?,
        ciphertext: Data?,
        expiresAt: Date
    ) {
        self.pairingID = pairingID
        self.spaceID = spaceID
        self.recipientPublicKey = recipientPublicKey
        self.authenticationTag = authenticationTag
        self.state = state
        self.algorithm = algorithm
        self.ciphertext = ciphertext
        self.expiresAt = expiresAt
    }
}

public struct CreatePairing: Codable, Equatable, Sendable {
    public let recipientPublicKey: Data
    public let authenticationTag: String
    public let expiresInSeconds: Int

    public init(recipientPublicKey: Data, authenticationTag: String, expiresInSeconds: Int) {
        self.recipientPublicKey = recipientPublicKey
        self.authenticationTag = authenticationTag
        self.expiresInSeconds = expiresInSeconds
    }

    public func validate() throws {
        guard !recipientPublicKey.isEmpty,
              recipientPublicKey.count <= SyncLimits.maxPairingPublicKeyBytes,
              (60...SyncLimits.maxPairingSeconds).contains(expiresInSeconds),
              authenticationTag.range(of: "^[A-Z2-9]{6,12}$", options: .regularExpression) != nil
        else { throw SyncServiceError.invalidRequest }
    }
}

public struct ApprovePairing: Codable, Equatable, Sendable {
    public let recipientKeyHash: Data
    public let algorithm: String
    public let ciphertext: Data

    public init(recipientKeyHash: Data, algorithm: String, ciphertext: Data) {
        self.recipientKeyHash = recipientKeyHash
        self.algorithm = algorithm
        self.ciphertext = ciphertext
    }

    public func validate() throws {
        guard recipientKeyHash.count == 32,
              !algorithm.isEmpty,
              algorithm.utf8.count <= 64,
              ciphertext.count <= SyncLimits.maxKeyEnvelopeBytes
        else { throw SyncServiceError.invalidRequest }
    }
}

public struct OIDCClientDescription: Codable, Equatable, Sendable {
    public let issuer: URL
    public let clientID: String
    public let scopes: [String]
}

public struct DiscoveryDocument: Codable, Equatable, Sendable {
    public let protocolMajor: Int
    public let protocolMinor: Int
    public let serverVersion: String
    public let serverInstanceID: UUID
    public let apiBase: URL
    public let oidc: OIDCClientDescription
    public let limits: DiscoveryLimits
    public let recordProfile: String
    public let capabilities: [String]

    public init(protocolMinor: Int = 0, serverVersion: String, serverInstanceID: UUID, apiBase: URL, oidc: OIDCClientDescription, capabilities: [String] = []) {
        self.protocolMajor = 1
        self.protocolMinor = protocolMinor
        self.serverVersion = serverVersion
        self.serverInstanceID = serverInstanceID
        self.apiBase = apiBase
        self.oidc = oidc
        self.limits = DiscoveryLimits()
        self.recordProfile = "snippets-wire-v1"
        self.capabilities = capabilities
    }
}

public struct DiscoveryLimits: Codable, Equatable, Sendable {
    public let maxBlobBytes: Int
    public let maxRevisionBytes: Int
    public let maxBatchRecords: Int
    public let maxPageRecords: Int
    public let maxRequestBytes: Int
    public let maxResponseBytes: Int
    public let maxKeyEnvelopeBytes: Int
    public let maxPairingSeconds: Int
    public init() {
        self.maxBlobBytes = SyncLimits.maxBlobBytes
        self.maxRevisionBytes = SyncLimits.maxRevisionBytes
        self.maxBatchRecords = SyncLimits.maxBatchRecords
        self.maxPageRecords = SyncLimits.maxPageRecords
        self.maxRequestBytes = SyncLimits.maxRequestBytes
        self.maxResponseBytes = SyncLimits.maxResponseBytes
        self.maxKeyEnvelopeBytes = SyncLimits.maxKeyEnvelopeBytes
        self.maxPairingSeconds = SyncLimits.maxPairingSeconds
    }
}
