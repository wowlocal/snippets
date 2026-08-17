import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Version-2 HTTP transport for Snippets Cloud and compatible self-hosted servers.
///
/// The type only handles opaque `WireRecord` values. It never receives a `Snippet`, a
/// vault plaintext, or key material, and it deliberately uses Core's existing cursor,
/// account-binding and record-CAS contracts instead of adding a second sync engine.
actor SnippetsCloudTransport: SyncTransport {
    typealias AccessTokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    nonisolated struct Configuration: Sendable, Equatable {
        let baseURL: URL
        let spaceID: UUID
        let serverInstanceID: UUID
        let protocolMajor: Int
        let accessToken: String

        init(
            baseURL: URL,
            spaceID: UUID,
            serverInstanceID: UUID,
            protocolMajor: Int = 2,
            accessToken: String
        ) throws {
            guard baseURL.scheme?.lowercased() == "https",
                  baseURL.host != nil,
                  baseURL.user == nil,
                  baseURL.password == nil,
                  baseURL.query == nil,
                  baseURL.fragment == nil else {
                throw ConfigurationFailure.invalidServerURL
            }
            guard (8...16_384).contains(accessToken.utf8.count) else {
                throw ConfigurationFailure.invalidAccessToken
            }
            guard protocolMajor == 2 else {
                throw ConfigurationFailure.incompatibleProtocol
            }
            self.baseURL = baseURL
            self.spaceID = spaceID
            self.serverInstanceID = serverInstanceID
            self.protocolMajor = protocolMajor
            self.accessToken = accessToken
        }
    }

    nonisolated enum ConfigurationFailure: Error, Equatable {
        case invalidServerURL
        case invalidAccessToken
        case incompatibleProtocol
    }

    nonisolated let identifier = "snippets-cloud"
    nonisolated let supportsPush = true
    nonisolated let pollInterval: TimeInterval = 60
    nonisolated let events: AsyncStream<SyncTransportEvent>

    private let configuration: Configuration
    private let session: URLSession
    private let accessTokenProvider: AccessTokenProvider?
    /// The scope Core admitted for data-plane use. Ordinary preflight requests observe
    /// changes without moving this pin; only an explicit account review may change the
    /// owner binding, and remote-reset review may rotate dataset/feed generations while
    /// retaining that same owner.
    private var resolvedScope: ScopeDTO?
    private var resolvedIdentity: SyncAccountIdentity?

    init(
        configuration: Configuration,
        session: URLSession? = nil,
        accessTokenProvider: AccessTokenProvider? = nil
    ) {
        self.configuration = configuration
        self.session = session ?? Self.secureSession
        self.accessTokenProvider = accessTokenProvider
        events = AsyncStream { $0.finish() }
    }

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        try await preflightScope().identity
    }

    func preflightScope() async throws -> SyncScopePreflight {
        let scope = try await currentScope()
        let identity = Self.accountIdentity(configuration: configuration, scope: scope)
        let datasetIdentity = Self.datasetIdentity(configuration: configuration, scope: scope)

        if let previous = resolvedScope, let resolvedIdentity {
            // Feed rotation is cursor maintenance, not a new account or a remote purge.
            // Adopt it before push-first work so a pending batch does not retry forever
            // with an obsolete feed precondition. Account/dataset changes remain pinned
            // to the old scope until Core obtains the corresponding explicit review.
            if resolvedIdentity == identity,
               Self.datasetIdentity(configuration: configuration, scope: previous)
                == datasetIdentity {
                resolvedScope = scope
            }
        } else {
            resolvedScope = scope
            resolvedIdentity = identity
        }

        return SyncScopePreflight(
            identity: identity,
            datasetIdentity: datasetIdentity,
            // Identities written before server-instance pinning cannot prove which
            // deployment produced them. A meaningful old checkpoint therefore gets
            // the normal explicit account review instead of a silent migration.
            legacyAccountIdentities: [])
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        let established = try await establishedScope()
        let page: ChangesPageDTO
        let replacesPriorPages: Bool
        do {
            page = try await changes(since: cursor)
            replacesPriorPages = false
        } catch let failure as HTTPFailure where failure.code == "cursor_invalid" {
            page = try await changes(since: nil)
            replacesPriorPages = true
            guard page.fullSnapshot else {
                throw SyncTransportFailure.rejected(.permanent(
                    detail: "incomplete_full_snapshot"))
            }
            try adoptFeedRotation(
                page.scope,
                expectedIdentity: established.identity,
                expectedDatasetIdentity: established.datasetIdentity)
        }
        // A nil cursor has no ancestor with which a delta can be interpreted. This is
        // also true after cursor_invalid: replacing already accumulated pages is safe
        // only with the server's explicit complete-snapshot assertion.
        guard cursor != nil || page.fullSnapshot else {
            throw SyncTransportFailure.rejected(.permanent(
                detail: "incomplete_full_snapshot"))
        }
        try validate(
            page.scope,
            against: established.identity,
            datasetIdentity: established.datasetIdentity)
        return SyncFetch(
            records: page.records.map(\.wireRecord),
            cursor: SyncCursor(page.cursor),
            cursorKind: .legacy,
            hasMore: page.hasMore,
            isFullResync: page.fullSnapshot,
            replacesPriorPages: replacesPriorPages,
            accountIdentity: established.identity,
            datasetIdentity: established.datasetIdentity)
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        guard !records.isEmpty, records.count <= 50 else {
            throw SyncTransportFailure.rejected(.permanent(detail: "invalid_batch_size"))
        }
        guard records.allSatisfy({ $0.blob.count <= 900_000 && $0.rev.utf8.count <= 256 }) else {
            throw SyncTransportFailure.rejected(.permanent(detail: "record_too_large"))
        }

        let established = try await establishedScope()
        var expectedScope = established.scope
        var results: [SyncSubmitResult] = []
        results.reserveCapacity(records.count)

        // Ten near-limit encrypted blobs remain below both the server's 16 MiB request
        // ceiling and this client's 16 MiB response ceiling after JSON/base64 overhead.
        // Core may still offer its protocol-level maximum of 50; keep that API atomic
        // from the engine's perspective while issuing bounded HTTP messages here.
        for start in stride(from: 0, to: records.count, by: Self.maximumRecordsPerHTTPMessage) {
            let end = min(start + Self.maximumRecordsPerHTTPMessage, records.count)
            let chunk = records[start..<end]
            let items = try chunk.map { record in
                BatchItemDTO(
                    record: ServerRecordDTO(record),
                    expectedRecordVersion: try Self.recordVersionString(record.recordVersion))
            }
            let response: BatchResponseDTO
            do {
                response = try await submitBatch(items, expectedScope: expectedScope)
            } catch let failure as HTTPFailure where failure.code == "cursor_invalid" {
                // The feed may rotate after preflight or between chunks. Re-read and
                // adopt only within the exact same membership and dataset, then retry
                // this CAS-protected chunk once with the new feed precondition.
                let current = try await currentScope()
                try adoptFeedRotation(
                    current,
                    expectedIdentity: established.identity,
                    expectedDatasetIdentity: established.datasetIdentity)
                expectedScope = current
                response = try await submitBatch(items, expectedScope: expectedScope)
            } catch let failure as HTTPFailure where failure.code == "forbidden" {
                // A replacement deployment rejects the old instance precondition
                // before touching records. Re-read its signed scope so Core sees an
                // account boundary instead of presenting a generic backend refusal.
                _ = try await currentScope()
                throw failure
            }
            try validate(
                response.scope,
                against: established.identity,
                datasetIdentity: established.datasetIdentity)
            guard response.outcomes.count == chunk.count else {
                throw SyncTransportFailure.unreachable(detail: "invalid_batch_response")
            }
            results.append(contentsOf: try zip(chunk, response.outcomes).map { record, outcome in
                SyncSubmitResult(id: record.id, outcome: try Self.outcome(outcome))
            })
        }
        return SyncSubmission(
            results: results,
            cursor: cursor,
            accountIdentity: established.identity,
            datasetIdentity: established.datasetIdentity)
    }

    func resetAfterAccountReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        let scope = try await currentScope()
        guard Self.accountIdentity(configuration: configuration, scope: scope) == expectedIdentity
        else {
            throw SyncTransportFailure.accountChanged
        }
        guard Self.datasetIdentity(configuration: configuration, scope: scope)
                == expectedDatasetIdentity else {
            throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
        }
        resolvedScope = scope
        resolvedIdentity = expectedIdentity
    }

    func resetAfterCheckpointReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        let scope = try await currentScope()
        guard Self.accountIdentity(configuration: configuration, scope: scope) == expectedIdentity
        else {
            throw SyncTransportFailure.accountChanged
        }
        guard Self.datasetIdentity(configuration: configuration, scope: scope)
                == expectedDatasetIdentity else {
            throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
        }
        // HTTP transport has no device-local scheduler checkpoint. Adopting a newer
        // feed epoch after explicit repair is safe only inside the same dataset.
        resolvedScope = scope
    }

    func resetAfterRemoteDataResetReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        let scope = try await currentScope()
        // The expected membership identity comes from Core's durable base. It remains
        // available after relaunch, unlike this actor's full generation pin, and makes
        // remote restore authority impossible to reuse under another credential.
        guard Self.accountIdentity(configuration: configuration, scope: scope) == expectedIdentity
        else {
            throw SyncTransportFailure.accountChanged
        }
        guard Self.datasetIdentity(configuration: configuration, scope: scope)
                == expectedDatasetIdentity else {
            throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
        }
        resolvedScope = scope
        resolvedIdentity = expectedIdentity
    }

    func resetForLocalFullResync(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        let scope = try await currentScope()
        guard Self.accountIdentity(configuration: configuration, scope: scope) == expectedIdentity
        else {
            throw SyncTransportFailure.accountChanged
        }
        guard Self.datasetIdentity(configuration: configuration, scope: scope)
                == expectedDatasetIdentity else {
            throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
        }
        // The HTTP feed cursor lives in Core's base, so there is no device-local
        // scheduler blob to erase. Pin the exact reviewed scope for the ensuing full fetch.
        resolvedScope = scope
        resolvedIdentity = expectedIdentity
    }

    private func establishedScope() async throws -> (
        identity: SyncAccountIdentity,
        datasetIdentity: SyncDatasetIdentity,
        scope: ScopeDTO
    ) {
        if resolvedScope == nil || resolvedIdentity == nil {
            _ = try await preflightScope()
        }
        guard let resolvedIdentity, let resolvedScope else {
            throw SyncTransportFailure.unreachable(detail: "scope_identity_missing")
        }
        return (
            resolvedIdentity,
            Self.datasetIdentity(configuration: configuration, scope: resolvedScope),
            resolvedScope)
    }

    private func currentScope() async throws -> ScopeDTO {
        let descriptor: SpaceDTO = try await request(method: "GET", path: scopePath)
        let scope = descriptor.scope
        guard scope.serverInstanceId == configuration.serverInstanceID else {
            throw SyncTransportFailure.accountChanged
        }
        guard scope.spaceId == configuration.spaceID else {
            throw SyncTransportFailure.unreachable(detail: "invalid_scope_response")
        }
        return scope
    }

    private func submitBatch(
        _ items: [BatchItemDTO],
        expectedScope: ScopeDTO
    ) async throws -> BatchResponseDTO {
        try await request(
            method: "POST",
            path: recordsPath,
            body: BatchRequestDTO(
                items: items,
                expectedScope: expectedScope))
    }

    private func changes(since cursor: SyncCursor?) async throws -> ChangesPageDTO {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(
            name: "limit",
            value: String(Self.maximumRecordsPerHTTPMessage))]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor.rawValue)) }
        return try await request(
            method: "GET",
            path: changesPath,
            percentEncodedQuery: components.percentEncodedQuery)
    }

    private func validate(
        _ scope: ScopeDTO,
        against identity: SyncAccountIdentity,
        datasetIdentity: SyncDatasetIdentity
    ) throws {
        guard scope.serverInstanceId == configuration.serverInstanceID else {
            throw SyncTransportFailure.accountChanged
        }
        guard scope.spaceId == configuration.spaceID else {
            throw SyncTransportFailure.unreachable(detail: "invalid_scope_response")
        }
        guard Self.accountIdentity(configuration: configuration, scope: scope) == identity else {
            throw SyncTransportFailure.accountChanged
        }
        guard Self.datasetIdentity(configuration: configuration, scope: scope)
                == datasetIdentity else {
            throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
        }
        guard resolvedScope == nil || resolvedScope == scope else {
            throw SyncTransportFailure.unreachable(detail: "feed_changed_during_response")
        }
    }

    private func adoptFeedRotation(
        _ scope: ScopeDTO,
        expectedIdentity: SyncAccountIdentity,
        expectedDatasetIdentity: SyncDatasetIdentity
    ) throws {
        guard scope.serverInstanceId == configuration.serverInstanceID else {
            throw SyncTransportFailure.accountChanged
        }
        guard scope.spaceId == configuration.spaceID else {
            throw SyncTransportFailure.unreachable(detail: "invalid_scope_response")
        }
        guard let previous = resolvedScope,
              Self.accountIdentity(configuration: configuration, scope: scope) == expectedIdentity,
              scope.scopeBinding == previous.scopeBinding else {
            throw SyncTransportFailure.accountChanged
        }
        guard Self.datasetIdentity(configuration: configuration, scope: scope)
                == expectedDatasetIdentity,
              scope.datasetGeneration == previous.datasetGeneration else {
            throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
        }
        resolvedScope = scope
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        percentEncodedQuery: String? = nil
    ) async throws -> Response {
        try await request(
            method: method,
            path: path,
            percentEncodedQuery: percentEncodedQuery,
            bodyData: nil)
    }

    private func request<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Body
    ) async throws -> Response {
        let encoder = JSONEncoder()
        return try await request(
            method: method,
            path: path,
            percentEncodedQuery: nil,
            bodyData: encoder.encode(body))
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        percentEncodedQuery: String?,
        bodyData: Data?
    ) async throws -> Response {
        var components = URLComponents(
            url: configuration.baseURL.appending(path: path),
            resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = percentEncodedQuery
        guard let url = components?.url else {
            throw SyncTransportFailure.unreachable(detail: "invalid_request_url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let accessToken: String
        do {
            accessToken = try await accessTokenProvider?(false) ?? configuration.accessToken
        } catch {
            throw SyncTransportFailure.rejected(.authenticationRequired(detail: "sign_in_required"))
        }
        guard (8...16_384).contains(accessToken.utf8.count),
              !accessToken.contains(where: \.isWhitespace) else {
            throw SyncTransportFailure.rejected(.authenticationRequired(detail: "invalid_access_token"))
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if bodyData != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        var (data, http) = try await perform(request)
        if http.statusCode == 401,
           (try? JSONDecoder().decode(ErrorDTO.self, from: data).code) == "authentication_required",
           let accessTokenProvider {
            let refreshedToken: String
            do {
                refreshedToken = try await accessTokenProvider(true)
            } catch {
                throw SyncTransportFailure.rejected(.authenticationRequired(detail: "sign_in_required"))
            }
            guard (8...16_384).contains(refreshedToken.utf8.count),
                  !refreshedToken.contains(where: \.isWhitespace) else {
                throw SyncTransportFailure.rejected(.authenticationRequired(detail: "invalid_access_token"))
            }
            request.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
            (data, http) = try await perform(request)
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = (try? JSONDecoder().decode(ErrorDTO.self, from: data))
            throw Self.failure(status: http.statusCode, error: error)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SyncTransportFailure.unreachable(detail: "invalid_json_response")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  response.url == request.url,
                  response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw SyncTransportFailure.unreachable(detail: "invalid_http_response")
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else {
                    throw SyncTransportFailure.unreachable(detail: "response_too_large")
                }
                data.append(byte)
            }
            return (data, http)
        } catch let failure as SyncTransportFailure {
            throw failure
        } catch {
            throw SyncTransportFailure.unreachable(detail: "network_request_failed")
        }
    }

    private nonisolated static let maximumResponseBytes = 16 * 1_024 * 1_024
    private nonisolated static let maximumRecordsPerHTTPMessage = 10
    private nonisolated static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: SnippetsCloudNoRedirectDelegate(),
            delegateQueue: nil)
    }()

    private var scopePath: String { "v2/spaces/\(configuration.spaceID.uuidString.lowercased())" }
    private var changesPath: String { "v2/spaces/\(configuration.spaceID.uuidString.lowercased())/changes" }
    private var recordsPath: String { "v2/spaces/\(configuration.spaceID.uuidString.lowercased())/records/batch" }

    private nonisolated static func accountIdentity(
        configuration: Configuration,
        scope: ScopeDTO
    ) -> SyncAccountIdentity {
        accountIdentity(
            baseURL: configuration.baseURL,
            protocolMajor: configuration.protocolMajor,
            serverInstanceID: configuration.serverInstanceID,
            spaceID: configuration.spaceID,
            scopeBinding: scope.scopeBinding)
    }

    nonisolated static func accountIdentity(
        baseURL: URL,
        protocolMajor: Int,
        serverInstanceID: UUID,
        spaceID: UUID,
        scopeBinding: String
    ) -> SyncAccountIdentity {
        let fields = [
            "snippets-cloud-membership-v2",
            baseURL.absoluteString,
            String(protocolMajor),
            serverInstanceID.uuidString.lowercased(),
            spaceID.uuidString.lowercased(),
            scopeBinding,
        ]
        var material = Data()
        for field in fields {
            withUnsafeBytes(of: UInt32(field.utf8.count).bigEndian) {
                material.append(contentsOf: $0)
            }
            material.append(contentsOf: field.utf8)
        }
        return SyncAccountIdentity(Data(SHA256.hash(data: material)))
    }

    private nonisolated static func datasetIdentity(
        configuration: Configuration,
        scope: ScopeDTO
    ) -> SyncDatasetIdentity {
        datasetIdentity(
            baseURL: configuration.baseURL,
            protocolMajor: configuration.protocolMajor,
            serverInstanceID: configuration.serverInstanceID,
            spaceID: configuration.spaceID,
            scopeBinding: scope.scopeBinding,
            datasetGeneration: scope.datasetGeneration)
    }

    nonisolated static func datasetIdentity(
        baseURL: URL,
        protocolMajor: Int,
        serverInstanceID: UUID,
        spaceID: UUID,
        scopeBinding: String,
        datasetGeneration: UUID
    ) -> SyncDatasetIdentity {
        let fields = [
            "snippets-cloud-dataset-v2",
            baseURL.absoluteString,
            String(protocolMajor),
            serverInstanceID.uuidString.lowercased(),
            spaceID.uuidString.lowercased(),
            scopeBinding,
            datasetGeneration.uuidString.lowercased(),
        ]
        return SyncDatasetIdentity(digest(fields))
    }

    private nonisolated static func digest(_ fields: [String]) -> Data {
        var material = Data()
        for field in fields {
            withUnsafeBytes(of: UInt32(field.utf8.count).bigEndian) {
                material.append(contentsOf: $0)
            }
            material.append(contentsOf: field.utf8)
        }
        return Data(SHA256.hash(data: material))
    }

    private nonisolated static func recordVersionString(_ version: SyncRecordVersion?) throws -> String? {
        guard let version else { return nil }
        guard let value = String(data: version.data, encoding: .utf8),
              (32...2_048).contains(value.utf8.count) else {
            throw SyncTransportFailure.rejected(.permanent(detail: "invalid_record_version"))
        }
        return value
    }

    private nonisolated static func outcome(_ value: BatchOutcomeDTO) throws -> SyncSubmitOutcome {
        switch value.kind {
        case "accepted":
            guard let revision = value.revision,
                  let recordVersion = value.recordVersion else {
                throw SyncTransportFailure.unreachable(detail: "invalid_accepted_outcome")
            }
            return .accepted(
                rev: revision,
                recordVersion: SyncRecordVersion(Data(recordVersion.utf8)))
        case "conflict":
            return .rejected(.conflict(remote: value.authoritativeRecord?.wireRecord))
        case "rejected":
            switch value.errorCode {
            case "authentication_required":
                return .rejected(.authenticationRequired(detail: "authentication_required"))
            case "rate_limited":
                return .rejected(.rateLimited(retryAfter: TimeInterval(value.retryAfterSeconds ?? 60)))
            default:
                return .rejected(.permanent(detail: value.errorCode ?? "record_rejected"))
            }
        default:
            throw SyncTransportFailure.unreachable(detail: "invalid_batch_outcome")
        }
    }

    private nonisolated static func failure(status: Int, error: ErrorDTO?) -> Error {
        let code = error?.code ?? "http_\(status)"
        switch code {
        case "authentication_required", "reauthentication_required":
            return SyncTransportFailure.rejected(.authenticationRequired(detail: code))
        case "rate_limited":
            return SyncTransportFailure.rejected(.rateLimited(
                retryAfter: TimeInterval(error?.retryAfterSeconds ?? 60)))
        case "dataset_reset":
            return SyncTransportFailure.remoteDataReset(detail: code)
        case "server_identity_changed":
            return SyncTransportFailure.rejected(
                .authenticationRequired(detail: code))
        case "cursor_invalid":
            return HTTPFailure(code: code)
        case "dependency_unavailable" where status >= 500:
            return SyncTransportFailure.unreachable(detail: code)
        default:
            return SyncTransportFailure.rejected(.permanent(detail: code))
        }
    }
}

private nonisolated final class SnippetsCloudNoRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        _ = session
        _ = task
        _ = response
        _ = request
        completionHandler(nil)
    }
}

private nonisolated struct HTTPFailure: Error { let code: String }

private nonisolated struct ScopeDTO: Codable, Equatable, Sendable {
    let serverInstanceId: UUID
    let spaceId: UUID
    let scopeBinding: String
    let datasetGeneration: UUID
    let feedEpoch: UUID
}

private nonisolated struct SpaceDTO: Decodable, Sendable {
    let scope: ScopeDTO
    let role: String
    let keyEpoch: Int
}

private nonisolated struct ServerRecordDTO: Codable, Sendable {
    let id: UUID
    let rev: String
    let deleted: Bool
    let blob: Data
    let recordVersion: String?

    init(_ record: WireRecord) {
        id = record.id
        rev = record.rev
        deleted = record.deleted
        blob = record.blob
        recordVersion = nil
    }

    var wireRecord: WireRecord {
        WireRecord(
            id: id,
            rev: rev,
            deleted: deleted,
            blob: blob,
            recordVersion: recordVersion.map { SyncRecordVersion(Data($0.utf8)) })
    }
}

private nonisolated struct ChangesPageDTO: Decodable, Sendable {
    let scope: ScopeDTO
    let records: [ServerRecordDTO]
    let cursor: String
    let hasMore: Bool
    let fullSnapshot: Bool

}

private nonisolated struct BatchRequestDTO: Encodable, Sendable {
    let items: [BatchItemDTO]
    /// Checked atomically before the first mutation. Record CAS alone cannot stop a
    /// stale client from creating records in a replaced dataset.
    let expectedScope: ScopeDTO
}
private nonisolated struct BatchItemDTO: Encodable, Sendable {
    let record: ServerRecordDTO
    let expectedRecordVersion: String?

    private enum CodingKeys: String, CodingKey {
        case record, expectedRecordVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(record, forKey: .record)
        if let expectedRecordVersion {
            try container.encode(expectedRecordVersion, forKey: .expectedRecordVersion)
        } else {
            // The v2 schema distinguishes a create's explicit null from a missing
            // member. Synthesized Encodable omits nil optionals, so spell it out.
            try container.encodeNil(forKey: .expectedRecordVersion)
        }
    }
}

private nonisolated struct BatchResponseDTO: Decodable, Sendable {
    let scope: ScopeDTO
    let outcomes: [BatchOutcomeDTO]
    let partial: Bool
}

private nonisolated struct BatchOutcomeDTO: Decodable, Sendable {
    let kind: String
    let recordVersion: String?
    let revision: String?
    let authoritativeRecord: ServerRecordDTO?
    let errorCode: String?
    let retryAfterSeconds: Int?
}

private nonisolated struct ErrorDTO: Decodable, Sendable {
    let code: String
    let retryAfterSeconds: Int?
}
