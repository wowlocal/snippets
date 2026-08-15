import Foundation

public enum InvalidRecordReason: Sendable {
    case revisionSize
    case blobSize
}

public enum SyncErrorCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case authenticationRequired = "authentication_required"
    case reauthenticationRequired = "reauthentication_required"
    case forbidden
    case notFound = "not_found"
    case conflict
    case cursorInvalid = "cursor_invalid"
    case datasetReset = "dataset_reset"
    case incompatibleVersion = "incompatible_version"
    case payloadTooLarge = "payload_too_large"
    case quotaExceeded = "quota_exceeded"
    case rateLimited = "rate_limited"
    case pairingExpired = "pairing_expired"
    case dependencyUnavailable = "dependency_unavailable"
    case internalError = "internal_error"
}

public enum SyncServiceError: Error, Sendable {
    case invalidRequest
    case invalidRecord(InvalidRecordReason)
    case authenticationRequired
    case reauthenticationRequired
    case forbidden
    case notFound
    case conflict
    case cursorInvalid
    case datasetReset
    case incompatibleVersion
    case payloadTooLarge(limit: Int)
    case quotaExceeded(limit: Int?)
    case rateLimited(retryAfterSeconds: Int)
    case pairingExpired
    case dependencyUnavailable
    case internalError

    public var code: SyncErrorCode {
        switch self {
        case .invalidRequest, .invalidRecord: .invalidRequest
        case .authenticationRequired: .authenticationRequired
        case .reauthenticationRequired: .reauthenticationRequired
        case .forbidden: .forbidden
        case .notFound: .notFound
        case .conflict: .conflict
        case .cursorInvalid: .cursorInvalid
        case .datasetReset: .datasetReset
        case .incompatibleVersion: .incompatibleVersion
        case .payloadTooLarge: .payloadTooLarge
        case .quotaExceeded: .quotaExceeded
        case .rateLimited: .rateLimited
        case .pairingExpired: .pairingExpired
        case .dependencyUnavailable: .dependencyUnavailable
        case .internalError: .internalError
        }
    }

    public var safeLimit: Int? {
        switch self {
        case .payloadTooLarge(let limit), .quotaExceeded(let limit?): limit
        default: nil
        }
    }

    public var safeRetryAfterSeconds: Int? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }
}

public struct ErrorResponse: Codable, Equatable, Sendable {
    public let code: SyncErrorCode
    public let requestID: UUID
    public let retryAfterSeconds: Int?
    public let limit: Int?

    private enum CodingKeys: String, CodingKey {
        case code
        case requestID = "requestId"
        case retryAfterSeconds
        case limit
    }

    public init(error: SyncServiceError, requestID: UUID = UUID()) {
        self.code = error.code
        self.requestID = requestID
        self.retryAfterSeconds = error.safeRetryAfterSeconds
        self.limit = error.safeLimit
    }
}
