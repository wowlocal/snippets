import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JWTKit
import SyncDomain

public protocol AccessTokenValidating: Sendable {
    func validate(bearerToken: String) async throws -> AuthenticatedPrincipal
}

public actor OIDCAccessTokenValidator: AccessTokenValidating {
    private struct TokenHeader: Decodable {
        let alg: String
        let kid: String?
        let jku: String?
        let x5u: String?
        let crit: [String]?
    }

    private struct AccessTokenPayload: JWTPayload {
        let iss: IssuerClaim
        let sub: SubjectClaim
        let aud: AudienceClaim
        let exp: ExpirationClaim
        let nbf: NotBeforeClaim?
        let iat: IssuedAtClaim

        func verify(using _: some JWTAlgorithm) throws {
            // Signature verification is performed by JWTKit. Time and exact
            // issuer/audience checks need configured skew/age and run below.
        }
    }

    private struct JWKSIndex: Decodable {
        struct Key: Decodable { let kid: String? }
        let keys: [Key]
    }

    private let configuration: OIDCConfiguration
    private var keys: JWTKeyCollection
    private var knownKeyIDs: Set<String>
    private var lastRefresh: Date
    private let session: URLSession

    public static func make(configuration: OIDCConfiguration, session: URLSession = .shared) async throws -> OIDCAccessTokenValidator {
        let fetched = try await fetchJWKS(configuration: configuration, session: session)
        let keys = try await JWTKeyCollection().add(jwksJSON: fetched.json)
        return OIDCAccessTokenValidator(
            configuration: configuration,
            keys: keys,
            knownKeyIDs: fetched.keyIDs,
            session: session
        )
    }

    private init(
        configuration: OIDCConfiguration,
        keys: JWTKeyCollection,
        knownKeyIDs: Set<String>,
        session: URLSession
    ) {
        self.configuration = configuration
        self.keys = keys
        self.knownKeyIDs = knownKeyIDs
        self.lastRefresh = Date()
        self.session = session
    }

    public func validate(bearerToken token: String) async throws -> AuthenticatedPrincipal {
        guard token.utf8.count <= 16_384 else { throw SyncServiceError.authenticationRequired }
        let header = try parseHeader(token)
        guard configuration.allowedAlgorithms.contains(header.alg),
              let keyID = header.kid, !keyID.isEmpty, keyID.utf8.count <= 256,
              header.jku == nil, header.x5u == nil, header.crit == nil
        else { throw SyncServiceError.authenticationRequired }

        if !knownKeyIDs.contains(keyID) || Date().timeIntervalSince(lastRefresh) >= configuration.jwksRefreshInterval {
            try await refreshKeys()
        }
        guard knownKeyIDs.contains(keyID) else { throw SyncServiceError.authenticationRequired }

        let payload: AccessTokenPayload
        do {
            payload = try await keys.verify(token, as: AccessTokenPayload.self)
        } catch {
            throw SyncServiceError.authenticationRequired
        }

        let now = Date()
        guard payload.iss.value == configuration.issuer.absoluteString,
              payload.aud.value.contains(configuration.audience),
              !payload.sub.value.isEmpty,
              payload.sub.value.utf8.count <= 256,
              payload.exp.value.timeIntervalSince(now) >= -configuration.clockSkew,
              payload.iat.value.timeIntervalSince(now) <= configuration.clockSkew,
              now.timeIntervalSince(payload.iat.value) <= configuration.maximumTokenAge + configuration.clockSkew
        else { throw SyncServiceError.authenticationRequired }
        if let notBefore = payload.nbf,
           notBefore.value.timeIntervalSince(now) > configuration.clockSkew {
            throw SyncServiceError.authenticationRequired
        }

        var identityMaterial = Data("snippets-oidc-identity-v1".utf8)
        appendLengthPrefixed(Data(payload.iss.value.utf8), to: &identityMaterial)
        appendLengthPrefixed(Data(payload.sub.value.utf8), to: &identityMaterial)
        let digest = Data(HMAC<SHA256>.authenticationCode(
            for: identityMaterial,
            using: SymmetricKey(data: configuration.identityPepper)
        ))
        return try AuthenticatedPrincipal(identityDigest: digest)
    }

    private func parseHeader(_ token: String) throws -> TokenHeader {
        guard let segment = token.split(separator: ".", omittingEmptySubsequences: false).first,
              let data = Data(base64URL: String(segment)), data.count <= 4_096,
              let header = try? JSONDecoder().decode(TokenHeader.self, from: data)
        else { throw SyncServiceError.authenticationRequired }
        return header
    }

    private func refreshKeys() async throws {
        do {
            let fetched = try await Self.fetchJWKS(configuration: configuration, session: session)
            keys = try await JWTKeyCollection().add(jwksJSON: fetched.json)
            knownKeyIDs = fetched.keyIDs
            lastRefresh = Date()
        } catch {
            throw SyncServiceError.dependencyUnavailable
        }
    }

    private static func fetchJWKS(
        configuration: OIDCConfiguration,
        session: URLSession
    ) async throws -> (json: String, keyIDs: Set<String>) {
        var request = URLRequest(url: configuration.jwksURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == configuration.jwksURL,
              !data.isEmpty, data.count <= 524_288,
              let json = String(data: data, encoding: .utf8),
              let index = try? JSONDecoder().decode(JWKSIndex.self, from: data),
              !index.keys.isEmpty, index.keys.count <= 64
        else { throw SyncServiceError.dependencyUnavailable }
        let keyIDs = Set(index.keys.compactMap(\.kid))
        guard keyIDs.count == index.keys.count,
              keyIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else { throw SyncServiceError.dependencyUnavailable }
        return (json, keyIDs)
    }

    private func appendLengthPrefixed(_ value: Data, to target: inout Data) {
        var count = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &count) { target.append(contentsOf: $0) }
        target.append(value)
    }
}
