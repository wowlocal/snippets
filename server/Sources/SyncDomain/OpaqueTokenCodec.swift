import Crypto
import Foundation

public enum CursorKind: String, Codable, Sendable {
    case snapshot
    case delta
}

public struct CursorPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let kind: CursorKind
    public let serverInstanceID: UUID
    public let spaceID: UUID
    public let datasetGeneration: UUID
    public let feedEpoch: UUID
    public let sequence: Int64
    public let snapshotAfterID: UUID?
    public let snapshotHighWater: Int64

    public init(
        kind: CursorKind,
        serverInstanceID: UUID,
        spaceID: UUID,
        datasetGeneration: UUID,
        feedEpoch: UUID,
        sequence: Int64,
        snapshotAfterID: UUID? = nil,
        snapshotHighWater: Int64 = 0
    ) {
        self.version = 1
        self.kind = kind
        self.serverInstanceID = serverInstanceID
        self.spaceID = spaceID
        self.datasetGeneration = datasetGeneration
        self.feedEpoch = feedEpoch
        self.sequence = sequence
        self.snapshotAfterID = snapshotAfterID
        self.snapshotHighWater = snapshotHighWater
    }
}

public struct RecordVersionPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let serverInstanceID: UUID
    public let spaceID: UUID
    public let datasetGeneration: UUID
    public let recordID: UUID
    public let generation: Int64

    public init(serverInstanceID: UUID, spaceID: UUID, datasetGeneration: UUID, recordID: UUID, generation: Int64) {
        self.version = 1
        self.serverInstanceID = serverInstanceID
        self.spaceID = spaceID
        self.datasetGeneration = datasetGeneration
        self.recordID = recordID
        self.generation = generation
    }
}

public struct OpaqueTokenCodec: Sendable {
    private let secret: Data

    public init(secret: Data) throws {
        guard (32...64).contains(secret.count) else { throw SyncServiceError.internalError }
        self.secret = secret
    }

    public func encode<T: Encodable & Sendable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)))
        return "v1.\(data.base64URL).\(signature.base64URL)"
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, token: String) throws -> T {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
              let data = Data(base64URL: String(parts[1])),
              let suppliedSignature = Data(base64URL: String(parts[2]))
        else { throw SyncServiceError.cursorInvalid }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)))
        guard constantTimeEqual(suppliedSignature, expected) else { throw SyncServiceError.cursorInvalid }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SyncServiceError.cursorInvalid
        }
    }
}

public func randomBytes(count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

public func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

public func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
    return difference == 0
}

extension Data {
    public var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URL: String) {
        guard base64URL.utf8.count <= 8_192,
              base64URL.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: value), decoded.base64URL == base64URL else { return nil }
        self = decoded
    }
}
