import Foundation
import HTTPTypes
import OpenAPIRuntime
import SyncDomain

enum RequestIdentity {
    @TaskLocal static var principal: AuthenticatedPrincipal?
}

public struct RequestSecurityMiddleware: ServerMiddleware {
    private let tokenValidator: any AccessTokenValidating
    private let publicOperations: Set<String> = ["getDiscovery", "getLiveness", "getReadiness"]

    public init(tokenValidator: any AccessTokenValidating) {
        self.tokenValidator = tokenValidator
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        metadata: ServerRequestMetadata,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        do {
            let boundedBody = try await collectBoundedBody(body, request: request, operationID: operationID)
            if publicOperations.contains(operationID) {
                return try await next(request, boundedBody, metadata)
            }
            let token = try bearerToken(from: request)
            let principal = try await tokenValidator.validate(bearerToken: token)
            return try await RequestIdentity.$principal.withValue(principal) {
                try await next(request, boundedBody, metadata)
            }
        } catch let error as SyncServiceError {
            return try errorResponse(error)
        } catch let error as ServerError {
            if let serviceError = error.underlyingError as? SyncServiceError {
                return try errorResponse(serviceError)
            }
            switch error.httpStatus.code {
            case 400, 406, 415, 422:
                return try errorResponse(.invalidRequest)
            default:
                return try errorResponse(.internalError)
            }
        } catch {
            return try errorResponse(.internalError)
        }
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
        let reservedCapacity: Int
        if let rawLength = request.headerFields[.contentLength] {
            guard let length = Int(rawLength), length >= 0 else {
                throw SyncServiceError.invalidRequest
            }
            guard length <= SyncLimits.maxRequestBytes else {
                throw SyncServiceError.payloadTooLarge(limit: SyncLimits.maxRequestBytes)
            }
            reservedCapacity = length
        } else {
            reservedCapacity = 0
        }
        var data = Data()
        data.reserveCapacity(reservedCapacity)
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

    private func errorResponse(_ error: SyncServiceError) throws -> (HTTPResponse, HTTPBody?) {
        let requestID = UUID()
        let payload = OpenAPIMapping.error(error, requestID: requestID)
        let data = try JSONEncoder().encode(payload)
        var response = HTTPResponse(status: status(for: error))
        response.headerFields[.contentType] = "application/json; charset=utf-8"
        response.headerFields[.cacheControl] = "no-store"
        if error.code == .authenticationRequired {
            response.headerFields[.wwwAuthenticate] = "Bearer"
        }
        if let retry = error.safeRetryAfterSeconds {
            response.headerFields[.retryAfter] = String(retry)
        }
        response.headerFields[.contentLength] = String(data.count)
        return (response, HTTPBody(data))
    }

    private func status(for error: SyncServiceError) -> HTTPResponse.Status {
        switch error.code {
        case .invalidRequest: .badRequest
        case .authenticationRequired: .unauthorized
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
