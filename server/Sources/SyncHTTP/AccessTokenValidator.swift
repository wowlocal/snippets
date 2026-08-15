import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JWTKit
import SyncDomain

public enum AuthenticationRequirement: Sendable {
    case standard
    case recentPhishingResistant
}

public protocol AccessTokenValidating: Sendable {
    func validate(bearerToken: String) async throws -> AuthenticatedPrincipal
    func validate(
        bearerToken: String,
        requirement: AuthenticationRequirement
    ) async throws -> AuthenticatedPrincipal
}

public extension AccessTokenValidating {
    /// Test doubles and deliberately simple validators fail closed for step-up
    /// unless they explicitly implement assurance-aware validation.
    func validate(
        bearerToken: String,
        requirement: AuthenticationRequirement
    ) async throws -> AuthenticatedPrincipal {
        guard case .standard = requirement else {
            throw SyncServiceError.reauthenticationRequired
        }
        return try await validate(bearerToken: bearerToken)
    }
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
        let azp: String?
        let client_id: String?
        let auth_time: IssuedAtClaim?
        let amr: [String]?
        let acr: String?

        func verify(using _: some JWTAlgorithm) throws {
            // Signature verification is performed by JWTKit. Time and exact
            // issuer/audience checks need configured skew/age and run below.
        }
    }

    private struct JWKSIndex: Decodable {
        struct Key: Decodable { let kid: String? }
        let keys: [Key]
    }

    private typealias FetchedJWKS = (json: String, keyIDs: Set<String>)

    private struct RefreshWork: Sendable {
        let id: UUID
        let task: Task<FetchedJWKS, Error>
    }

    private let configuration: OIDCConfiguration
    private var keys: JWTKeyCollection
    private var knownKeyIDs: Set<String>
    private var lastRefresh: Date
    private var lastRefreshAttempt: Date
    private var rejectedKeyIDs: [String: Date] = [:]
    private var refreshWork: RefreshWork?
    private let session: URLSession
    private let now: @Sendable () -> Date

    public static func make(
        configuration: OIDCConfiguration,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> OIDCAccessTokenValidator {
        let fetched = try await fetchJWKS(configuration: configuration, session: session)
        let keys = try await JWTKeyCollection().add(jwksJSON: fetched.json)
        return OIDCAccessTokenValidator(
            configuration: configuration,
            keys: keys,
            knownKeyIDs: fetched.keyIDs,
            session: session,
            now: now
        )
    }

    private init(
        configuration: OIDCConfiguration,
        keys: JWTKeyCollection,
        knownKeyIDs: Set<String>,
        session: URLSession,
        now: @escaping @Sendable () -> Date
    ) {
        self.configuration = configuration
        self.keys = keys
        self.knownKeyIDs = knownKeyIDs
        self.lastRefresh = now()
        self.lastRefreshAttempt = self.lastRefresh
        self.session = session
        self.now = now
    }

    public func validate(bearerToken token: String) async throws -> AuthenticatedPrincipal {
        try await validate(bearerToken: token, requirement: .standard)
    }

    public func validate(
        bearerToken token: String,
        requirement: AuthenticationRequirement
    ) async throws -> AuthenticatedPrincipal {
        guard token.utf8.count <= 16_384 else { throw SyncServiceError.authenticationRequired }
        let header = try parseHeader(token)
        guard configuration.allowedAlgorithms.contains(header.alg),
              let keyID = header.kid, !keyID.isEmpty, keyID.utf8.count <= 256,
              header.jku == nil, header.x5u == nil, header.crit == nil
        else { throw SyncServiceError.authenticationRequired }

        let now = self.now()
        pruneRejectedKeyIDs(at: now)
        if knownKeyIDs.contains(keyID) {
            if now.timeIntervalSince(lastRefresh) >= configuration.jwksRefreshInterval,
               now.timeIntervalSince(lastRefreshAttempt) >= configuration.unknownKeyRefreshInterval {
                // A provider outage must not invalidate a token that still
                // verifies against the last successfully fetched key set.
                try? await refreshKeys()
            }
        } else {
            if let rejectedUntil = rejectedKeyIDs[keyID], rejectedUntil > now {
                throw SyncServiceError.authenticationRequired
            }
            let sinceLastAttempt = now.timeIntervalSince(lastRefreshAttempt)
            let refreshAllowed = sinceLastAttempt >= configuration.unknownKeyRefreshInterval
            if refreshAllowed {
                try await refreshKeys()
            }
            guard knownKeyIDs.contains(keyID) else {
                let ttl = refreshAllowed
                    ? configuration.unknownKeyCacheTTL
                    : max(1, configuration.unknownKeyRefreshInterval - sinceLastAttempt)
                rememberRejectedKeyID(keyID, at: now, ttl: ttl)
                throw SyncServiceError.authenticationRequired
            }
        }

        let payload: AccessTokenPayload
        do {
            payload = try await keys.verify(token, as: AccessTokenPayload.self)
        } catch {
            throw SyncServiceError.authenticationRequired
        }

        guard payload.iss.value == configuration.issuer.absoluteString,
              payload.aud.value == [configuration.audience],
              !payload.sub.value.isEmpty,
              payload.sub.value.utf8.count <= 256,
              authorizedParty(in: payload) == configuration.clientID,
              payload.exp.value > payload.iat.value,
              payload.exp.value.timeIntervalSince(now) >= -configuration.clockSkew,
              payload.exp.value.timeIntervalSince(now)
                <= configuration.maximumTokenAge + configuration.clockSkew,
              payload.exp.value.timeIntervalSince(payload.iat.value)
                <= configuration.maximumTokenAge,
              payload.iat.value.timeIntervalSince(now) <= configuration.clockSkew,
              now.timeIntervalSince(payload.iat.value) <= configuration.maximumTokenAge + configuration.clockSkew
        else { throw SyncServiceError.authenticationRequired }
        if let notBefore = payload.nbf,
           (notBefore.value.timeIntervalSince(now) > configuration.clockSkew
                || notBefore.value > payload.exp.value) {
                throw SyncServiceError.authenticationRequired
        }
        try validateAssuranceClaims(payload, requirement: requirement, now: now)

        var identityMaterial = Data("snippets-oidc-identity-v1".utf8)
        appendLengthPrefixed(Data(payload.iss.value.utf8), to: &identityMaterial)
        appendLengthPrefixed(Data(payload.sub.value.utf8), to: &identityMaterial)
        let identityDigest = Data(HMAC<SHA256>.authenticationCode(
            for: identityMaterial,
            using: SymmetricKey(data: configuration.identityPepper)
        ))
        var credentialMaterial = Data("snippets-oidc-credential-v1".utf8)
        appendLengthPrefixed(
            try canonicalCredentialToken(token, algorithm: header.alg),
            to: &credentialMaterial
        )
        let credentialDigest = Data(HMAC<SHA256>.authenticationCode(
            for: credentialMaterial,
            using: SymmetricKey(data: configuration.identityPepper)
        ))
        return try AuthenticatedPrincipal(
            identityDigest: identityDigest,
            credentialDigest: credentialDigest,
            credentialExpiresAt: payload.exp.value
        )
    }

    /// OAuth providers use either the OIDC `azp` claim or the JWT access-token
    /// profile's `client_id`. If both are present they must agree; otherwise an
    /// access token minted for another public client could be replayed here.
    private func authorizedParty(in payload: AccessTokenPayload) -> String? {
        let values = [payload.azp, payload.client_id].compactMap { $0 }
        guard !values.isEmpty,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              Set(values).count == 1 else { return nil }
        return values[0]
    }

    private func validateAssuranceClaims(
        _ payload: AccessTokenPayload,
        requirement: AuthenticationRequirement,
        now: Date
    ) throws {
        guard (payload.amr?.count ?? 0) <= 16,
              payload.amr?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              payload.acr?.utf8.count ?? 0 <= 256
        else { throw SyncServiceError.authenticationRequired }
        guard case .recentPhishingResistant = requirement else { return }

        guard let authenticationTime = payload.auth_time?.value,
              authenticationTime.timeIntervalSince(now) <= configuration.clockSkew,
              now.timeIntervalSince(authenticationTime)
                <= configuration.stepUpMaximumAge + configuration.clockSkew
        else { throw SyncServiceError.reauthenticationRequired }

        let methods = Set((payload.amr ?? []).map { $0.lowercased() })
        let hasStrongMethod = !methods.isDisjoint(with: configuration.stepUpAuthenticationMethods)
        let hasStrongContext = payload.acr.map {
            configuration.stepUpAuthenticationContexts.contains($0)
        } ?? false
        guard hasStrongMethod || hasStrongContext else {
            throw SyncServiceError.reauthenticationRequired
        }
    }

    private func parseHeader(_ token: String) throws -> TokenHeader {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let segment = segments.first,
              let data = Data(base64URL: String(segment)), data.count <= 4_096,
              let header = try? JSONDecoder().decode(TokenHeader.self, from: data)
        else { throw SyncServiceError.authenticationRequired }
        return header
    }

    /// Revocation is keyed by the concrete verified JWT, but ECDSA admits two
    /// byte-distinct signatures for the same `(header, payload)` pair: `(r, s)` and
    /// `(r, n-s)`. Normalizing ES256 to low-S prevents a copied token from evading the
    /// denylist by changing only its signature bytes. RS256 remains byte-identical.
    private func canonicalCredentialToken(
        _ token: String,
        algorithm: String
    ) throws -> Data {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let signature = Data(base64URL: String(segments[2])),
              !signature.isEmpty else {
            throw SyncServiceError.authenticationRequired
        }
        let canonicalSignature: Data
        if algorithm == "ES256" {
            canonicalSignature = try canonicalES256Signature(signature)
        } else {
            canonicalSignature = signature
        }
        return Data(
            "\(segments[0]).\(segments[1]).\(canonicalSignature.base64URL)".utf8
        )
    }

    private func canonicalES256Signature(_ signature: Data) throws -> Data {
        guard signature.count == 64 else { throw SyncServiceError.authenticationRequired }
        let bytes = [UInt8](signature)
        let s = Array(bytes[32..<64])
        let order: [UInt8] = [
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
            0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
        ]
        guard s.contains(where: { $0 != 0 }),
              s.lexicographicallyPrecedes(order),
              let reflected = subtractBigEndian(order, s) else {
            throw SyncServiceError.authenticationRequired
        }
        let normalized = s.lexicographicallyPrecedes(reflected) ? s : reflected
        return Data(bytes[0..<32] + normalized)
    }

    private func subtractBigEndian(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8]? {
        guard lhs.count == rhs.count else { return nil }
        var result = [UInt8](repeating: 0, count: lhs.count)
        var borrow = 0
        for index in lhs.indices.reversed() {
            var value = Int(lhs[index]) - Int(rhs[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        return borrow == 0 ? result : nil
    }

    private func refreshKeys() async throws {
        let work: RefreshWork
        if let refreshWork {
            work = refreshWork
        } else {
            let id = UUID()
            let configuration = self.configuration
            let session = self.session
            let task = Task { try await Self.fetchJWKS(configuration: configuration, session: session) }
            work = RefreshWork(id: id, task: task)
            refreshWork = work
            lastRefreshAttempt = now()
        }
        do {
            let fetched = try await work.task.value
            keys = try await JWTKeyCollection().add(jwksJSON: fetched.json)
            knownKeyIDs = fetched.keyIDs
            lastRefresh = now()
            rejectedKeyIDs = rejectedKeyIDs.filter { !fetched.keyIDs.contains($0.key) }
            if refreshWork?.id == work.id { refreshWork = nil }
        } catch {
            if refreshWork?.id == work.id { refreshWork = nil }
            throw SyncServiceError.dependencyUnavailable
        }
    }

    private func pruneRejectedKeyIDs(at now: Date) {
        rejectedKeyIDs = rejectedKeyIDs.filter { $0.value > now }
    }

    private func rememberRejectedKeyID(_ keyID: String, at now: Date, ttl: TimeInterval) {
        if rejectedKeyIDs.count >= 256,
           let oldest = rejectedKeyIDs.min(by: { $0.value < $1.value })?.key {
            rejectedKeyIDs[oldest] = nil
        }
        rejectedKeyIDs[keyID] = now.addingTimeInterval(ttl)
    }

    private static func fetchJWKS(
        configuration: OIDCConfiguration,
        session: URLSession
    ) async throws -> FetchedJWKS {
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
