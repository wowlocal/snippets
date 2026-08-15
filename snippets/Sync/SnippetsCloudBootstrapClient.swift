import Foundation

/// Narrow HTTP client for zero-knowledge library-key bootstrap.
///
/// All ciphertext is produced and opened by `LibraryKeyBootstrap`; this type only
/// moves bounded opaque envelopes and verifies that every response remains bound to
/// the expected server, space, pairing and ephemeral recipient key.
nonisolated struct SnippetsCloudBootstrapClient: Sendable {
    typealias AccessTokenProvider = @Sendable () async throws -> String

    struct RecoveryState: Sendable, Equatable {
        struct Envelope: Sendable, Equatable {
            let version: Int
            let keyEpoch: Int
            let algorithm: String
            let ciphertext: Data
        }
        let keyEpoch: Int
        let recovery: Envelope?
    }

    struct Pairing: Sendable, Equatable {
        let pairingID: UUID
        let spaceID: UUID
        let recipientPublicKey: Data
        let nonce: Data
        let authenticationTag: String
        let state: String
        let algorithm: String?
        let ciphertext: Data?
        let expiresAt: Date
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidConfiguration
        case invalidResponse
        case service(String)
        case network

        var description: String {
            switch self {
            case .invalidConfiguration: "invalid Snippets Cloud bootstrap configuration"
            case .invalidResponse: "Snippets Cloud returned an invalid bootstrap response"
            case .service(let code): code
            case .network: "Snippets Cloud bootstrap request failed"
            }
        }
    }

    private struct RecoveryStateDTO: Decodable {
        let keyEpoch: Int
        let recovery: RecoveryEnvelopeDTO?
    }

    private struct RecoveryEnvelopeDTO: Decodable {
        let version: Int
        let keyEpoch: Int
        let algorithm: String
        let ciphertext: Data
    }

    private struct PairingDTO: Decodable {
        let pairingId: UUID
        let spaceId: UUID
        let recipientPublicKey: Data
        let nonce: Data
        let authenticationTag: String
        let state: String
        let algorithm: String?
        let ciphertext: Data?
        let expiresAt: String
    }

    private struct CreatePairingDTO: Encodable {
        let recipientPublicKey: Data
        let nonce: Data
        let expiresInSeconds: Int
    }

    private struct ApprovePairingDTO: Encodable {
        let recipientKeyHash: Data
        let algorithm: String
        let ciphertext: Data
    }

    private struct PutRecoveryDTO: Encodable {
        let expectedVersion: Int?
        let keyEpoch: Int
        let algorithm: String
        let ciphertext: Data

        private enum CodingKeys: String, CodingKey {
            case expectedVersion, keyEpoch, algorithm, ciphertext
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            if let expectedVersion {
                try values.encode(expectedVersion, forKey: .expectedVersion)
            } else {
                try values.encodeNil(forKey: .expectedVersion)
            }
            try values.encode(keyEpoch, forKey: .keyEpoch)
            try values.encode(algorithm, forKey: .algorithm)
            try values.encode(ciphertext, forKey: .ciphertext)
        }
    }

    private struct ErrorDTO: Decodable { let code: String }

    let baseURL: URL
    let spaceID: UUID
    private let accessToken: AccessTokenProvider
    private let session: URLSession

    init(
        baseURL: URL,
        spaceID: UUID,
        accessToken: @escaping AccessTokenProvider,
        session: URLSession? = nil
    ) throws {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              !baseURL.absoluteString.hasSuffix("/") else {
            throw Failure.invalidConfiguration
        }
        self.baseURL = baseURL
        self.spaceID = spaceID
        self.accessToken = accessToken
        self.session = session ?? Self.secureSession
    }

    func recoveryState() async throws -> RecoveryState {
        let dto: RecoveryStateDTO = try await request(
            method: "GET", path: "key-envelopes/current")
        guard dto.keyEpoch > 0 else { throw Failure.invalidResponse }
        let envelope = try dto.recovery.map { value in
            guard value.version > 0,
                  value.keyEpoch == dto.keyEpoch,
                  value.algorithm == LibraryKeyBootstrap.recoveryAlgorithm,
                  value.ciphertext.count <= Self.maximumEnvelopeBytes else {
                throw Failure.invalidResponse
            }
            return RecoveryState.Envelope(
                version: value.version,
                keyEpoch: value.keyEpoch,
                algorithm: value.algorithm,
                ciphertext: value.ciphertext)
        }
        return RecoveryState(keyEpoch: dto.keyEpoch, recovery: envelope)
    }

    func hasRemoteRecords() async throws -> Bool {
        struct Changes: Decodable { let records: [Record] }
        struct Record: Decodable { let id: UUID }
        let response: Changes = try await request(
            method: "GET", path: "changes", query: "limit=1")
        return !response.records.isEmpty
    }

    func putRecoveryEnvelope(
        keyEpoch: Int,
        expectedVersion: Int?,
        ciphertext: Data
    ) async throws -> RecoveryState.Envelope {
        guard keyEpoch > 0, ciphertext.count <= Self.maximumEnvelopeBytes else {
            throw Failure.invalidConfiguration
        }
        let value: RecoveryEnvelopeDTO = try await request(
            method: "PUT",
            path: "key-envelopes/recovery",
            body: PutRecoveryDTO(
                expectedVersion: expectedVersion,
                keyEpoch: keyEpoch,
                algorithm: LibraryKeyBootstrap.recoveryAlgorithm,
                ciphertext: ciphertext))
        guard value.version > 0,
              value.keyEpoch == keyEpoch,
              value.algorithm == LibraryKeyBootstrap.recoveryAlgorithm,
              value.ciphertext.count <= Self.maximumEnvelopeBytes else {
            throw Failure.invalidResponse
        }
        return .init(
            version: value.version,
            keyEpoch: value.keyEpoch,
            algorithm: value.algorithm,
            ciphertext: value.ciphertext)
    }

    func createPairing(_ draft: LibraryKeyBootstrap.PairingDraft) async throws -> Pairing {
        let value: PairingDTO = try await request(
            method: "POST",
            path: "pairings",
            body: CreatePairingDTO(
                recipientPublicKey: draft.recipientPublicKey,
                nonce: draft.nonce,
                expiresInSeconds: LibraryKeyBootstrap.defaultPairingSeconds))
        return try validatedPairing(
            value,
            pairingID: nil,
            publicKey: draft.recipientPublicKey,
            nonce: draft.nonce,
            requireEnvelope: false)
    }

    func pairing(_ pairingID: UUID, publicKey: Data, nonce: Data) async throws -> Pairing {
        let value: PairingDTO = try await request(method: "GET", path: "pairings/\(pairingID.uuidString.lowercased())")
        return try validatedPairing(
            value,
            pairingID: pairingID,
            publicKey: publicKey,
            nonce: nonce,
            requireEnvelope: false)
    }

    func approvePairing(
        _ pairingID: UUID,
        publicKey: Data,
        nonce: Data,
        ciphertext: Data
    ) async throws -> Pairing {
        let value: PairingDTO = try await request(
            method: "PUT",
            path: "pairings/\(pairingID.uuidString.lowercased())/approval",
            body: ApprovePairingDTO(
                recipientKeyHash: LibraryKeyBootstrap.recipientKeyHash(publicKey),
                algorithm: LibraryKeyBootstrap.pairingAlgorithm,
                ciphertext: ciphertext))
        return try validatedPairing(
            value,
            pairingID: pairingID,
            publicKey: publicKey,
            nonce: nonce,
            requireEnvelope: false)
    }

    func takeApprovedPairing(
        _ pairingID: UUID,
        publicKey: Data,
        nonce: Data
    ) async throws -> Pairing {
        let value: PairingDTO = try await request(
            method: "POST", path: "pairings/\(pairingID.uuidString.lowercased())/consume")
        return try validatedPairing(
            value,
            pairingID: pairingID,
            publicKey: publicKey,
            nonce: nonce,
            requireEnvelope: true)
    }

    func cancelPairing(_ pairingID: UUID) async throws {
        _ = try await requestData(
            method: "DELETE",
            path: "pairings/\(pairingID.uuidString.lowercased())",
            query: nil,
            body: nil)
    }

    private func validatedPairing(
        _ value: PairingDTO,
        pairingID: UUID?,
        publicKey: Data,
        nonce: Data,
        requireEnvelope: Bool
    ) throws -> Pairing {
        guard let expiresAt = Self.parseServerDate(value.expiresAt),
              pairingID == nil || value.pairingId == pairingID,
              value.spaceId == spaceID,
              value.recipientPublicKey == publicKey,
              value.nonce == nonce,
              value.recipientPublicKey.count == 65,
              value.recipientPublicKey.first == 0x04,
              value.nonce.count == 32,
              value.authenticationTag.range(
                of: #"^[A-Z2-9]{8}$"#,
                options: .regularExpression) != nil,
              value.state == "pending" || value.state == "approved",
              expiresAt.timeIntervalSinceNow > -30,
              expiresAt.timeIntervalSinceNow <= 630 else {
            throw Failure.invalidResponse
        }
        if requireEnvelope {
            guard value.state == "approved",
                  value.algorithm == LibraryKeyBootstrap.pairingAlgorithm,
                  let ciphertext = value.ciphertext,
                  ciphertext.count <= Self.maximumEnvelopeBytes else {
                throw Failure.invalidResponse
            }
        } else if value.algorithm != nil || value.ciphertext != nil {
            // Poll and approval responses are intentionally redacted. Only the atomic
            // consume endpoint is allowed to release the one-time envelope.
            throw Failure.invalidResponse
        }
        return Pairing(
            pairingID: value.pairingId,
            spaceID: value.spaceId,
            recipientPublicKey: value.recipientPublicKey,
            nonce: value.nonce,
            authenticationTag: value.authenticationTag,
            state: value.state,
            algorithm: value.algorithm,
            ciphertext: value.ciphertext,
            expiresAt: expiresAt)
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        query: String? = nil
    ) async throws -> Response {
        try decode(try await requestData(method: method, path: path, query: query, body: nil))
    }

    private func request<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        body: Body
    ) async throws -> Response {
        let data: Data
        do { data = try JSONEncoder().encode(body) }
        catch { throw Failure.invalidConfiguration }
        return try decode(try await requestData(method: method, path: path, query: nil, body: data))
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw Failure.invalidResponse }
    }

    /// Swift's built-in `.iso8601` decoding has differed across OS releases in its
    /// handling of fractional seconds. Accept the two RFC 3339 forms emitted by the
    /// server explicitly and reject every other representation.
    private static func parseServerDate(_ value: String) -> Date? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func requestData(
        method: String,
        path: String,
        query: String?,
        body: Data?
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appending(path: "v1/spaces/\(spaceID.uuidString.lowercased())/\(path)"),
            resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = query
        guard let url = components?.url else { throw Failure.invalidConfiguration }
        let token: String
        do { token = try await accessToken() }
        catch { throw Failure.service("sign_in_required") }
        guard (8...16_384).contains(token.utf8.count),
              !token.contains(where: \.isWhitespace) else {
            throw Failure.service("sign_in_required")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Snippets-Protocol")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  response.url == url,
                  response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                throw Failure.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { throw Failure.invalidResponse }
                data.append(byte)
            }
            guard (200..<300).contains(http.statusCode) else {
                let code = (try? JSONDecoder().decode(ErrorDTO.self, from: data).code)
                    ?? "http_\(http.statusCode)"
                throw Failure.service(code)
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network
        }
    }

    private static let maximumEnvelopeBytes = 4_096
    private static let maximumResponseBytes = 64 * 1_024
    private static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: SnippetsCloudBootstrapNoRedirectDelegate(),
            delegateQueue: nil)
    }()
}

private nonisolated final class SnippetsCloudBootstrapNoRedirectDelegate:
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
