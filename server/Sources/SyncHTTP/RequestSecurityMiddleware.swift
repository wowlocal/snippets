import Foundation
import HTTPTypes
import OpenAPIRuntime
import SyncDomain

enum RequestIdentity {
    @TaskLocal static var principal: AuthenticatedPrincipal?
}

public struct RequestSecurityMiddleware: ServerMiddleware {
    private let tokenValidator: any AccessTokenValidating
    private let store: any SyncStore
    private let publicOperations: Set<String> = ["getDiscovery", "getLiveness", "getReadiness"]
    /// These operations can replace recovery material or deliver a library key
    /// to another device, so a background-refreshed token is insufficient.
    private let stepUpOperations: Set<String> = ["putRecoveryKeyEnvelope", "approvePairing"]
    private let bodyTimeoutSeconds: Int
    private let concurrencyLimiter: RequestConcurrencyLimiter
    private let bodyMemoryLimiter: BodyMemoryLimiter
    private let globalRateLimiter: RequestRateLimiter
    private let principalRateLimiter: RequestRateLimiter

    public init(
        tokenValidator: any AccessTokenValidating,
        store: any SyncStore,
        bodyTimeoutSeconds: Int = 15,
        maximumConcurrentRequests: Int = 128,
        bodyMemoryBudgetBytes: Int = 256 * 1_024 * 1_024,
        globalRequestsPerSecond: Int = 256,
        globalRequestBurst: Int = 512,
        principalRequestsPerSecond: Int = 30,
        principalRequestBurst: Int = 60
    ) {
        self.tokenValidator = tokenValidator
        self.store = store
        self.bodyTimeoutSeconds = bodyTimeoutSeconds
        self.concurrencyLimiter = RequestConcurrencyLimiter(limit: maximumConcurrentRequests)
        self.bodyMemoryLimiter = BodyMemoryLimiter(limit: bodyMemoryBudgetBytes)
        self.globalRateLimiter = RequestRateLimiter(
            refillPerSecond: globalRequestsPerSecond,
            burst: globalRequestBurst,
            maximumKeys: 1
        )
        self.principalRateLimiter = RequestRateLimiter(
            refillPerSecond: principalRequestsPerSecond,
            burst: principalRequestBurst,
            maximumKeys: 10_000
        )
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard await globalRateLimiter.allow(key: Data()) else {
            return try errorResponse(.rateLimited(retryAfterSeconds: 1), closeConnection: body != nil)
        }
        guard await concurrencyLimiter.tryAcquire() else {
            return try errorResponse(.rateLimited(retryAfterSeconds: 1), closeConnection: body != nil)
        }
        var bodyReservation = 0
        do {
            if publicOperations.contains(operationID) {
                if hasBody(body, request: request) {
                    let response = try errorResponse(.invalidRequest, closeConnection: true)
                    await concurrencyLimiter.release()
                    return response
                }
                let response = try await next(request, nil, metadata)
                await concurrencyLimiter.release()
                return response
            }
            let token = try bearerToken(from: request)
            let requirement: AuthenticationRequirement = stepUpOperations.contains(operationID)
                ? .recentPhishingResistant
                : .standard
            let principal = try await tokenValidator.validate(
                bearerToken: token,
                requirement: requirement
            )
            let alreadyRevoked = try await store.isAccessTokenRevoked(for: principal)
            if alreadyRevoked {
                // A lost logout response can be retried, but the denied credential
                // must not reach PostgreSQL cleanup again or consume another
                // principal bucket indefinitely.
                if operationID == "revokeCurrentSession" {
                    await concurrencyLimiter.release()
                    return noContentResponse()
                }
                throw SyncServiceError.authenticationRequired
            }
            guard await principalRateLimiter.allow(key: principal.identityDigest) else {
                let response = try errorResponse(.rateLimited(retryAfterSeconds: 1), closeConnection: body != nil)
                await concurrencyLimiter.release()
                return response
            }
            bodyReservation = requiredBodyReservation(body, request: request)
            guard await bodyMemoryLimiter.tryReserve(bodyReservation) else {
                bodyReservation = 0
                let response = try errorResponse(.rateLimited(retryAfterSeconds: 1), closeConnection: true)
                await concurrencyLimiter.release()
                return response
            }
            let boundedBody = try await collectBoundedBody(body, request: request, operationID: operationID)
            // Authentication happened before reading an untrusted body so malformed
            // requests cannot become an unauthenticated parsing oracle. Recheck after
            // the bounded read so a client cannot hold a request open, wait for this
            // credential to be logged out, and then commit a data-plane mutation.
            if operationID != "revokeCurrentSession",
               try await store.isAccessTokenRevoked(for: principal) {
                throw SyncServiceError.authenticationRequired
            }
            let response = try await RequestIdentity.$principal.withValue(principal) {
                try await next(request, boundedBody, metadata)
            }
            await bodyMemoryLimiter.release(bodyReservation)
            bodyReservation = 0
            await concurrencyLimiter.release()
            return response
        } catch let error as SyncServiceError {
            await bodyMemoryLimiter.release(bodyReservation)
            await concurrencyLimiter.release()
            return try errorResponse(error, closeConnection: body != nil)
        } catch let error as ServerError {
            await bodyMemoryLimiter.release(bodyReservation)
            await concurrencyLimiter.release()
            if let serviceError = error.underlyingError as? SyncServiceError {
                return try errorResponse(serviceError, closeConnection: body != nil)
            }
            switch error.httpStatus.code {
            case 400, 406, 415, 422:
                return try errorResponse(.invalidRequest, closeConnection: body != nil)
            default:
                return try errorResponse(.internalError, closeConnection: body != nil)
            }
        } catch {
            await bodyMemoryLimiter.release(bodyReservation)
            await concurrencyLimiter.release()
            return try errorResponse(.internalError, closeConnection: body != nil)
        }
    }

    private func requiredBodyReservation(_ body: HTTPBody?, request: HTTPRequest) -> Int {
        guard body != nil else { return 0 }
        if request.method == .get,
           request.headerFields[.contentLength] == nil,
           request.headerFields[.transferEncoding] == nil {
            return 0
        }
        // Reserve the full per-request ceiling. Content-Length may be absent or
        // dishonest, so reserving only its claimed value would not bound total
        // live body memory across concurrent requests.
        return SyncLimits.maxRequestBytes
    }

    private func hasBody(_ body: HTTPBody?, request: HTTPRequest) -> Bool {
        if let rawLength = request.headerFields[.contentLength], rawLength != "0" { return true }
        if request.headerFields[.transferEncoding] != nil { return true }
        // Hummingbird supplies an empty HTTPBody value for bodyless HTTP/1
        // requests, so framing headers are the authoritative distinction here.
        _ = body
        return false
    }

    private func bearerToken(from request: HTTPRequest) throws -> String {
        guard let header = request.headerFields[.authorization], header.utf8.count <= 16_384,
              header.count > 7,
              header.prefix(7).lowercased() == "bearer "
        else {
            throw SyncServiceError.authenticationRequired
        }
        let token = header.dropFirst(7)
        guard !token.contains(where: \.isWhitespace)
        else { throw SyncServiceError.authenticationRequired }
        return String(token)
    }

    private func collectBoundedBody(
        _ body: HTTPBody?,
        request: HTTPRequest,
        operationID: String
    ) async throws -> HTTPBody? {
        guard let body else { return nil }
        if let encoding = request.headerFields[.contentEncoding], encoding.lowercased() != "identity" {
            throw SyncServiceError.invalidRequest
        }
        if let rawLength = request.headerFields[.contentLength] {
            guard let length = Int(rawLength), length >= 0 else {
                throw SyncServiceError.invalidRequest
            }
            guard length <= SyncLimits.maxRequestBytes else {
                throw SyncServiceError.payloadTooLarge(limit: SyncLimits.maxRequestBytes)
            }
        }
        return try await withThrowingTaskGroup(of: HTTPBody?.self) { group in
            group.addTask {
                var data = Data()
                for try await chunk in body {
                    guard data.count <= SyncLimits.maxRequestBytes - chunk.count else {
                        throw SyncServiceError.payloadTooLarge(limit: SyncLimits.maxRequestBytes)
                    }
                    data.append(contentsOf: chunk)
                }
                if !data.isEmpty {
                    try StrictJSONRequestValidator.validate(data, operationID: operationID)
                }
                return HTTPBody(data)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(bodyTimeoutSeconds))
                throw SyncServiceError.rateLimited(retryAfterSeconds: 1)
            }
            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func errorResponse(
        _ error: SyncServiceError,
        closeConnection: Bool = false
    ) throws -> (HTTPResponse, HTTPBody?) {
        let requestID = UUID()
        let payload = OpenAPIMapping.error(error, requestID: requestID)
        let data = try JSONEncoder().encode(payload)
        var response = HTTPResponse(status: status(for: error))
        response.headerFields[.contentType] = "application/json; charset=utf-8"
        response.headerFields[.cacheControl] = "no-store"
        switch error.code {
        case .authenticationRequired:
            response.headerFields[.wwwAuthenticate] = "Bearer"
        case .reauthenticationRequired:
            response.headerFields[.wwwAuthenticate] =
                #"Bearer error="insufficient_user_authentication""#
        default:
            break
        }
        if let retry = error.safeRetryAfterSeconds {
            response.headerFields[.retryAfter] = String(retry)
        }
        if closeConnection {
            response.headerFields[.connection] = "close"
        }
        response.headerFields[.contentLength] = String(data.count)
        return (response, HTTPBody(data))
    }

    private func noContentResponse() -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .noContent)
        response.headerFields[.cacheControl] = "no-store"
        response.headerFields[.contentLength] = "0"
        return (response, nil)
    }

    private func status(for error: SyncServiceError) -> HTTPResponse.Status {
        switch error.code {
        case .invalidRequest: .badRequest
        case .authenticationRequired, .reauthenticationRequired: .unauthorized
        case .forbidden: .forbidden
        case .notFound: .notFound
        case .conflict, .cursorInvalid, .datasetReset: .conflict
        case .incompatibleVersion: .upgradeRequired
        case .payloadTooLarge: .contentTooLarge
        case .quotaExceeded, .rateLimited: .tooManyRequests
        case .pairingExpired: .gone
        case .dependencyUnavailable: .serviceUnavailable
        case .internalError: .internalServerError
        }
    }
}

private actor RequestConcurrencyLimiter {
    private let limit: Int
    private var inFlight = 0

    init(limit: Int) {
        self.limit = limit
    }

    func tryAcquire() -> Bool {
        guard inFlight < limit else { return false }
        inFlight += 1
        return true
    }

    func release() {
        precondition(inFlight > 0)
        inFlight -= 1
    }
}

private actor BodyMemoryLimiter {
    private let limit: Int
    private var reserved = 0

    init(limit: Int) {
        self.limit = limit
    }

    func tryReserve(_ bytes: Int) -> Bool {
        guard bytes >= 0, bytes <= limit - reserved else { return false }
        reserved += bytes
        return true
    }

    func release(_ bytes: Int) {
        precondition(bytes >= 0 && bytes <= reserved)
        reserved -= bytes
    }
}

private actor RequestRateLimiter {
    private struct Bucket {
        var tokens: Double
        var lastRefillNanoseconds: UInt64
        var lastSeenNanoseconds: UInt64
    }

    private let refillPerSecond: Double
    private let burst: Double
    private let maximumKeys: Int
    private var buckets: [Data: Bucket] = [:]

    init(refillPerSecond: Int, burst: Int, maximumKeys: Int) {
        self.refillPerSecond = Double(refillPerSecond)
        self.burst = Double(burst)
        self.maximumKeys = maximumKeys
    }

    func allow(key: Data) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        var bucket = buckets[key] ?? Bucket(
            tokens: burst,
            lastRefillNanoseconds: now,
            lastSeenNanoseconds: now
        )
        let elapsed = Double(now - bucket.lastRefillNanoseconds) / 1_000_000_000
        bucket.tokens = min(burst, bucket.tokens + elapsed * refillPerSecond)
        bucket.lastRefillNanoseconds = now
        bucket.lastSeenNanoseconds = now
        guard bucket.tokens >= 1 else {
            buckets[key] = bucket
            return false
        }
        bucket.tokens -= 1
        if buckets[key] == nil, buckets.count >= maximumKeys,
           let oldestKey = buckets.min(by: { $0.value.lastSeenNanoseconds < $1.value.lastSeenNanoseconds })?.key {
            buckets[oldestKey] = nil
        }
        buckets[key] = bucket
        return true
    }
}
