import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Version-1 HTTP transport for Snippets Cloud and compatible self-hosted servers.
///
/// The type only handles opaque `WireRecord` values. It never receives a `Snippet`, a
/// vault plaintext, or key material, and it deliberately uses Core's existing cursor,
/// account-binding and record-CAS contracts instead of adding a second sync engine.
actor SnippetsCloudTransport: SyncTransport {
    nonisolated struct Configuration: Sendable, Equatable {
        let baseURL: URL
        let spaceID: UUID
        let accessToken: String

        init(baseURL: URL, spaceID: UUID, accessToken: String) throws {
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
            self.baseURL = baseURL
            self.spaceID = spaceID
            self.accessToken = accessToken
        }
    }

    nonisolated enum ConfigurationFailure: Error, Equatable {
        case invalidServerURL
        case invalidAccessToken
    }

    nonisolated let identifier = "snippets-cloud"
    nonisolated let supportsPush = false
    nonisolated let pollInterval: TimeInterval = 60
    nonisolated let events: AsyncStream<SyncTransportEvent>

    private let configuration: Configuration
    private let session: URLSession
    private var resolvedScope: ScopeDTO?
    private var resolvedIdentity: SyncAccountIdentity?

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        events = AsyncStream { $0.finish() }
    }

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        let scope: ScopeDTO = try await request(method: "GET", path: scopePath)
        guard scope.spaceId == configuration.spaceID else {
            throw SyncTransportFailure.unreachable(detail: "invalid_scope_response")
        }
        let identity = Self.identity(configuration: configuration, scope: scope)
        resolvedScope = scope
        resolvedIdentity = identity
        return identity
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        let identity = try await establishedIdentity()
        let page: ChangesPageDTO
        do {
            page = try await changes(since: cursor)
        } catch let failure as HTTPFailure where failure.code == "cursor_invalid" {
            page = try await changes(since: nil)
        }
        try validate(page.scope, against: identity)
        return SyncFetch(
            records: page.records.map(\.wireRecord),
            cursor: SyncCursor(page.cursor),
            cursorKind: .legacy,
            hasMore: page.hasMore,
            isFullResync: page.fullSnapshot,
            accountIdentity: identity)
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        guard !records.isEmpty, records.count <= 50 else {
            throw SyncTransportFailure.rejected(.permanent(detail: "invalid_batch_size"))
        }
        guard records.allSatisfy({ $0.blob.count <= 900_000 && $0.rev.utf8.count <= 256 }) else {
            throw SyncTransportFailure.rejected(.permanent(detail: "record_too_large"))
        }

        let identity = try await establishedIdentity()
        let items = try records.map { record in
            BatchItemDTO(
                record: ServerRecordDTO(record),
                expectedRecordVersion: try Self.recordVersionString(record.recordVersion))
        }
        let response: BatchResponseDTO = try await request(
            method: "POST",
            path: recordsPath,
            body: BatchRequestDTO(items: items))
        try validate(response.scope, against: identity)
        guard response.outcomes.count == records.count else {
            throw SyncTransportFailure.unreachable(detail: "invalid_batch_response")
        }

        let results = try zip(records, response.outcomes).map { record, outcome in
            SyncSubmitResult(id: record.id, outcome: try Self.outcome(outcome))
        }
        return SyncSubmission(results: results, cursor: cursor, accountIdentity: identity)
    }

    func resetAfterAccountReview() async throws {
        resolvedScope = nil
        resolvedIdentity = nil
        _ = try await resolveAccountIdentity()
    }

    private func establishedIdentity() async throws -> SyncAccountIdentity {
        if let resolvedIdentity { return resolvedIdentity }
        guard let identity = try await resolveAccountIdentity() else {
            throw SyncTransportFailure.unreachable(detail: "scope_identity_missing")
        }
        return identity
    }

    private func changes(since cursor: SyncCursor?) async throws -> ChangesPageDTO {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
        if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor.rawValue)) }
        return try await request(
            method: "GET",
            path: changesPath,
            percentEncodedQuery: components.percentEncodedQuery)
    }

    private func validate(_ scope: ScopeDTO, against identity: SyncAccountIdentity) throws {
        guard scope.spaceId == configuration.spaceID else {
            throw SyncTransportFailure.unreachable(detail: "invalid_scope_response")
        }
        let responseIdentity = Self.identity(configuration: configuration, scope: scope)
        guard responseIdentity == identity,
              resolvedScope == nil || resolvedScope == scope else {
            throw SyncTransportFailure.accountChanged
        }
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
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Snippets-Protocol")
        if bodyData != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncTransportFailure.unreachable(detail: "network_request_failed")
        }
        guard data.count <= 16 * 1_024 * 1_024,
              let http = response as? HTTPURLResponse else {
            throw SyncTransportFailure.unreachable(detail: "invalid_http_response")
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

    private var scopePath: String { "v1/spaces/\(configuration.spaceID.uuidString.lowercased())/scope" }
    private var changesPath: String { "v1/spaces/\(configuration.spaceID.uuidString.lowercased())/changes" }
    private var recordsPath: String { "v1/spaces/\(configuration.spaceID.uuidString.lowercased())/records:batch" }

    private nonisolated static func identity(
        configuration: Configuration,
        scope: ScopeDTO
    ) -> SyncAccountIdentity {
        let fields = [
            configuration.baseURL.absoluteString,
            configuration.spaceID.uuidString.lowercased(),
            scope.scopeBinding,
            scope.datasetGeneration.uuidString.lowercased(),
            scope.feedEpoch.uuidString.lowercased(),
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
        case "authentication_required":
            return SyncTransportFailure.rejected(.authenticationRequired(detail: code))
        case "rate_limited":
            return SyncTransportFailure.rejected(.rateLimited(
                retryAfter: TimeInterval(error?.retryAfterSeconds ?? 60)))
        case "dataset_reset":
            return SyncTransportFailure.remoteDataReset(detail: code)
        case "cursor_invalid":
            return HTTPFailure(code: code)
        case "dependency_unavailable" where status >= 500:
            return SyncTransportFailure.unreachable(detail: code)
        default:
            return SyncTransportFailure.rejected(.permanent(detail: code))
        }
    }
}

private nonisolated struct HTTPFailure: Error { let code: String }

private nonisolated struct ScopeDTO: Codable, Equatable, Sendable {
    let spaceId: UUID
    let scopeBinding: String
    let datasetGeneration: UUID
    let feedEpoch: UUID
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
    let spaceId: UUID
    let scopeBinding: String
    let datasetGeneration: UUID
    let feedEpoch: UUID
    let records: [ServerRecordDTO]
    let cursor: String
    let hasMore: Bool
    let fullSnapshot: Bool

    var scope: ScopeDTO { ScopeDTO(
        spaceId: spaceId,
        scopeBinding: scopeBinding,
        datasetGeneration: datasetGeneration,
        feedEpoch: feedEpoch) }
}

private nonisolated struct BatchRequestDTO: Encodable, Sendable { let items: [BatchItemDTO] }
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
            // The v1 schema distinguishes a create's explicit null from a missing
            // member. Synthesized Encodable omits nil optionals, so spell it out.
            try container.encodeNil(forKey: .expectedRecordVersion)
        }
    }
}

private nonisolated struct BatchResponseDTO: Decodable, Sendable {
    let spaceId: UUID
    let scopeBinding: String
    let datasetGeneration: UUID
    let feedEpoch: UUID
    let outcomes: [BatchOutcomeDTO]
    let partial: Bool

    var scope: ScopeDTO { ScopeDTO(
        spaceId: spaceId,
        scopeBinding: scopeBinding,
        datasetGeneration: datasetGeneration,
        feedEpoch: feedEpoch) }
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
