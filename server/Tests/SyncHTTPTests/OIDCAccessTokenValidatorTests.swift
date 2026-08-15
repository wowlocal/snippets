import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JWTKit
import SyncDomain
@testable import SyncHTTP
import XCTest

final class OIDCAccessTokenValidatorTests: XCTestCase {
    func testUnknownKeyIDsCannotAmplifyJWKSRefreshes() async throws {
        let keyID = "stable-key"
        let signingKey = ES256PrivateKey()
        let parameters = try XCTUnwrap(signingKey.parameters)
        let jwks = try JSONSerialization.data(withJSONObject: [
            "keys": [[
                "kty": "EC",
                "crv": "P-256",
                "alg": "ES256",
                "use": "sig",
                "kid": keyID,
                "x": base64URL(parameters.x),
                "y": base64URL(parameters.y),
            ]]
        ], options: [.sortedKeys])
        let requests = LockedCounter()
        OIDCJWKSURLProtocol.handler = { _ in
            requests.increment()
            return (200, jwks)
        }
        defer { OIDCJWKSURLProtocol.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OIDCJWKSURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let clock = LockedClock(date: Date(timeIntervalSince1970: 1_000))
        let configuration = try OIDCConfiguration(
            issuer: try XCTUnwrap(URL(string: "https://oidc.integration.example/")),
            audience: "snippets-integration",
            clientID: "integration-client",
            scopes: ["openid"],
            jwksURL: try XCTUnwrap(URL(string: "https://oidc.integration.example/jwks")),
            allowedAlgorithms: ["ES256"],
            maximumTokenAge: 3_600,
            clockSkew: 60,
            identityPepper: Data(repeating: 0x61, count: 32),
            jwksRefreshInterval: 900,
            unknownKeyRefreshInterval: 60,
            unknownKeyCacheTTL: 300
        )
        let validator = try await OIDCAccessTokenValidator.make(
            configuration: configuration,
            session: session,
            now: { clock.value }
        )
        XCTAssertEqual(requests.value, 1)

        for index in 0..<16 {
            await XCTAssertAuthenticationRequired {
                _ = try await validator.validate(bearerToken: unknownKeyToken("initial-\(index)"))
            }
        }
        XCTAssertEqual(requests.value, 1, "Startup cooldown must reject unknown kids without network I/O")

        clock.advance(by: 61)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<32 {
                group.addTask {
                    do {
                        _ = try await validator.validate(bearerToken: unknownKeyToken("parallel-\(index)"))
                        return false
                    } catch let error as SyncServiceError {
                        return error.code == .authenticationRequired
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(requests.value, 2, "Concurrent unknown kids may share at most one bounded refresh")
    }

    func testSignedTokenValidationAndIdentityBinding() async throws {
        let keyID = "integration-es256"
        let issuer = "https://oidc.integration.example/"
        let audience = "snippets-integration"
        let signingKey = ES256PrivateKey()
        let parameters = try XCTUnwrap(signingKey.parameters)
        let jwks = try JSONSerialization.data(withJSONObject: [
            "keys": [[
                "kty": "EC",
                "crv": "P-256",
                "alg": "ES256",
                "use": "sig",
                "kid": keyID,
                "x": base64URL(parameters.x),
                "y": base64URL(parameters.y),
            ]]
        ], options: [.sortedKeys])
        OIDCJWKSURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://oidc.integration.example/jwks")
            return (200, jwks)
        }
        defer { OIDCJWKSURLProtocol.handler = nil }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [OIDCJWKSURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let configuration = try OIDCConfiguration(
            issuer: try XCTUnwrap(URL(string: issuer)),
            audience: audience,
            clientID: "integration-client",
            scopes: ["openid"],
            jwksURL: try XCTUnwrap(URL(string: "https://oidc.integration.example/jwks")),
            allowedAlgorithms: ["ES256"],
            maximumTokenAge: 3_600,
            clockSkew: 60,
            identityPepper: Data(repeating: 0x61, count: 32)
        )
        let validator = try await OIDCAccessTokenValidator.make(
            configuration: configuration,
            session: session
        )
        let keys = await JWTKeyCollection().add(ecdsa: signingKey, kid: JWKIdentifier(string: keyID))
        let firstToken = try await keys.sign(
            tokenPayload(issuer: issuer, audience: audience, subject: "subject-a"),
            kid: JWKIdentifier(string: keyID)
        )
        let repeatedToken = try await keys.sign(
            tokenPayload(issuer: issuer, audience: audience, subject: "subject-a"),
            kid: JWKIdentifier(string: keyID)
        )
        let secondSubjectToken = try await keys.sign(
            tokenPayload(issuer: issuer, audience: audience, subject: "subject-b"),
            kid: JWKIdentifier(string: keyID)
        )

        let first = try await validator.validate(bearerToken: firstToken)
        let malleatedToken = try malleatedES256Token(firstToken)
        let malleated = try await validator.validate(bearerToken: malleatedToken)
        let repeated = try await validator.validate(bearerToken: repeatedToken)
        let secondSubject = try await validator.validate(bearerToken: secondSubjectToken)
        XCTAssertEqual(first.identityDigest, repeated.identityDigest)
        XCTAssertNotEqual(firstToken, malleatedToken)
        XCTAssertEqual(
            first.credentialDigest,
            malleated.credentialDigest,
            "Equivalent high-S/low-S encodings must share one revocation identity"
        )
        XCTAssertNotEqual(
            first.credentialDigest,
            repeated.credentialDigest,
            "Each concrete bearer JWT must be independently revocable"
        )
        XCTAssertNotEqual(first, secondSubject)
        XCTAssertEqual(first.identityDigest.count, 32)
        XCTAssertEqual(first.credentialDigest.count, 32)
        _ = try await validator.validate(
            bearerToken: firstToken,
            requirement: .recentPhishingResistant
        )

        let unverifiedEmail = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                emailVerified: false
            ),
            kid: JWKIdentifier(string: keyID)
        )
        _ = try await validator.validate(bearerToken: unverifiedEmail)
        let missingEmailVerification = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                emailVerified: nil
            ),
            kid: JWKIdentifier(string: keyID)
        )
        _ = try await validator.validate(bearerToken: missingEmailVerification)

        let weakAuthentication = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                authenticationMethods: ["pwd"]
            ),
            kid: JWKIdentifier(string: keyID)
        )
        await XCTAssertReauthenticationRequired {
            _ = try await validator.validate(
                bearerToken: weakAuthentication,
                requirement: .recentPhishingResistant
            )
        }

        let staleAuthentication = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                authenticationTime: Date().addingTimeInterval(-900)
            ),
            kid: JWKIdentifier(string: keyID)
        )
        await XCTAssertReauthenticationRequired {
            _ = try await validator.validate(
                bearerToken: staleAuthentication,
                requirement: .recentPhishingResistant
            )
        }

        let wrongAuthorizedParty = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                authorizedParty: "other-client"
            ),
            kid: JWKIdentifier(string: keyID)
        )
        await XCTAssertAuthenticationRequired {
            _ = try await validator.validate(bearerToken: wrongAuthorizedParty)
        }
        let jwtProfileClient = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                authorizedParty: nil,
                accessTokenClientID: "integration-client"
            ),
            kid: JWKIdentifier(string: keyID)
        )
        _ = try await validator.validate(bearerToken: jwtProfileClient)

        let missingAuthorizedParty = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                authorizedParty: nil
            ),
            kid: JWKIdentifier(string: keyID)
        )
        await XCTAssertAuthenticationRequired {
            _ = try await validator.validate(bearerToken: missingAuthorizedParty)
        }

        let conflictingAuthorizedParties = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                authorizedParty: "integration-client",
                accessTokenClientID: "other-client"
            ),
            kid: JWKIdentifier(string: keyID)
        )
        await XCTAssertAuthenticationRequired {
            _ = try await validator.validate(bearerToken: conflictingAuthorizedParties)
        }

        let wrongAudience = try await keys.sign(
            tokenPayload(issuer: issuer, audience: "another-service", subject: "subject-a"),
            kid: JWKIdentifier(string: keyID)
        )
        do {
            _ = try await validator.validate(bearerToken: wrongAudience)
            XCTFail("A valid signature with the wrong audience must fail closed")
        } catch let error as SyncServiceError {
            XCTAssertEqual(error.code, .authenticationRequired)
        }

        let multiResourceAudience = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                additionalAudiences: ["https://other-resource.example"]
            ),
            kid: JWKIdentifier(string: keyID)
        )
        await XCTAssertAuthenticationRequired {
            _ = try await validator.validate(bearerToken: multiResourceAudience)
        }

        let excessiveLifetime = try await keys.sign(
            tokenPayload(
                issuer: issuer,
                audience: audience,
                subject: "subject-a",
                expirationTime: Date().addingTimeInterval(7_200)
            ),
            kid: JWKIdentifier(string: keyID)
        )
        await XCTAssertAuthenticationRequired {
            _ = try await validator.validate(bearerToken: excessiveLifetime)
        }

        let wrongIssuer = try await keys.sign(
            tokenPayload(
                issuer: "https://other-issuer.integration.example/",
                audience: audience,
                subject: "subject-a"
            ),
            kid: JWKIdentifier(string: keyID)
        )
        do {
            _ = try await validator.validate(bearerToken: wrongIssuer)
            XCTFail("A valid signature with the wrong issuer must fail closed")
        } catch let error as SyncServiceError {
            XCTAssertEqual(error.code, .authenticationRequired)
        }
    }

    private func tokenPayload(
        issuer: String,
        audience: String,
        subject: String,
        authorizedParty: String? = "integration-client",
        accessTokenClientID: String? = nil,
        emailVerified: Bool? = true,
        authenticationTime: Date? = nil,
        authenticationMethods: [String]? = ["webauthn"],
        additionalAudiences: [String] = [],
        expirationTime: Date? = nil
    ) -> OIDCTestPayload {
        let now = Date()
        return OIDCTestPayload(
            iss: .init(value: issuer),
            sub: .init(value: subject),
            aud: .init(value: [audience] + additionalAudiences),
            exp: .init(value: expirationTime ?? now.addingTimeInterval(300)),
            nbf: .init(value: now.addingTimeInterval(-5)),
            iat: .init(value: now),
            azp: authorizedParty,
            client_id: accessTokenClientID,
            email_verified: emailVerified,
            auth_time: .init(value: authenticationTime ?? now),
            amr: authenticationMethods,
            acr: nil
        )
    }

    private func base64URL(_ value: String) -> String {
        value
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func malleatedES256Token(_ token: String) throws -> String {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(segments.count, 3)
        let signature = try XCTUnwrap(Data(base64URL: String(segments[2])))
        XCTAssertEqual(signature.count, 64)
        let order: [UInt8] = [
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
            0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
        ]
        let bytes = [UInt8](signature)
        let s = Array(bytes[32..<64])
        var reflected = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in order.indices.reversed() {
            var value = Int(order[index]) - Int(s[index]) - borrow
            if value < 0 { value += 256; borrow = 1 } else { borrow = 0 }
            reflected[index] = UInt8(value)
        }
        XCTAssertEqual(borrow, 0)
        let alternate = Data(bytes[0..<32] + reflected).base64URL
        return "\(segments[0]).\(segments[1]).\(alternate)"
    }
}

private func unknownKeyToken(_ keyID: String) -> String {
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID])
    let segment = header.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "\(segment).e30.invalid"
}

private func XCTAssertAuthenticationRequired(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected authentication_required", file: file, line: line)
    } catch let error as SyncServiceError {
        XCTAssertEqual(error.code, .authenticationRequired, file: file, line: line)
    } catch {
        XCTFail("Expected SyncServiceError", file: file, line: line)
    }
}

private func XCTAssertReauthenticationRequired(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected reauthentication_required", file: file, line: line)
    } catch let error as SyncServiceError {
        XCTAssertEqual(error.code, .reauthenticationRequired, file: file, line: line)
    } catch {
        XCTFail("Expected SyncServiceError", file: file, line: line)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) { self.date = date }
    var value: Date { lock.withLock { date } }
    func advance(by interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

private struct OIDCTestPayload: JWTPayload {
    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let nbf: NotBeforeClaim
    let iat: IssuedAtClaim
    let azp: String?
    let client_id: String?
    let email_verified: Bool?
    let auth_time: IssuedAtClaim?
    let amr: [String]?
    let acr: String?

    func verify(using _: some JWTAlgorithm) throws {}
}

private final class OIDCJWKSURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Cache-Control": "no-store",
                    "Content-Type": "application/json",
                ]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
