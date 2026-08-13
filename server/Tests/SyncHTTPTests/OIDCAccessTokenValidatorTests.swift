import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import JWTKit
import SyncDomain
@testable import SyncHTTP
import XCTest

final class OIDCAccessTokenValidatorTests: XCTestCase {
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
        let repeated = try await validator.validate(bearerToken: repeatedToken)
        let secondSubject = try await validator.validate(bearerToken: secondSubjectToken)
        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, secondSubject)
        XCTAssertEqual(first.identityDigest.count, 32)

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
        subject: String
    ) -> OIDCTestPayload {
        let now = Date()
        return OIDCTestPayload(
            iss: .init(value: issuer),
            sub: .init(value: subject),
            aud: .init(value: [audience]),
            exp: .init(value: now.addingTimeInterval(300)),
            nbf: .init(value: now.addingTimeInterval(-5)),
            iat: .init(value: now)
        )
    }

    private func base64URL(_ value: String) -> String {
        value
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct OIDCTestPayload: JWTPayload {
    let iss: IssuerClaim
    let sub: SubjectClaim
    let aud: AudienceClaim
    let exp: ExpirationClaim
    let nbf: NotBeforeClaim
    let iat: IssuedAtClaim

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
