import Foundation
import Hummingbird
import HummingbirdTesting
import XCTest
@testable import SyncDomain
@testable import SyncHTTP

final class SyncHTTPTests: XCTestCase {
    func testDiscoveryIsPublicAndProtectedEndpointFailsClosed() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        try await app.test(.router) { client in
            let discovery = try await client.execute(uri: "/.well-known/snippets-sync", method: .get)
            XCTAssertEqual(discovery.status, .ok)
            let discoveryJSON = try decodeJSONObject(discovery.body)
            XCTAssertEqual(discoveryJSON["protocolMajor"] as? Int, 1)
            XCTAssertEqual(discoveryJSON["recordProfile"] as? String, "snippets-wire-v1")
            XCTAssertEqual((discoveryJSON["limits"] as? [String: Any])?["maxBlobBytes"] as? Int, 900_000)

            let protected = try await client.execute(uri: "/v1/spaces", method: .get)
            XCTAssertEqual(protected.status, .unauthorized)
            let errorJSON = try decodeJSONObject(protected.body)
            XCTAssertEqual(errorJSON["code"] as? String, "authentication_required")
            XCTAssertNotNil(errorJSON["requestId"] as? String)
            XCTAssertNil(errorJSON["message"])
        }
    }

    func testEndToEndCreateCASConflictAndByteExactBlob() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        let headers: HTTPFields = [.authorization: "Bearer owner", .contentType: "application/json"]
        let recordID = UUID().uuidString.lowercased()
        let blob = Data(repeating: 0x7f, count: 900_000)

        try await app.test(.router) { client in
            let createSpace = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
            XCTAssertEqual(createSpace.status, .created)
            let spaceID = try XCTUnwrap(decodeJSONObject(createSpace.body)["spaceId"] as? String)

            let createBody = try encodeBatchBody(id: recordID, rev: "r1", blob: blob, expected: nil)
            let createRecord = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/records:batch",
                method: .post,
                headers: headers,
                body: ByteBuffer(data: createBody)
            )
            XCTAssertEqual(createRecord.status, .ok)
            let createOutcomes = try XCTUnwrap(decodeJSONObject(createRecord.body)["outcomes"] as? [[String: Any]])
            XCTAssertEqual(createOutcomes[0]["kind"] as? String, "accepted")
            let recordVersion = try XCTUnwrap(createOutcomes[0]["recordVersion"] as? String)

            let conflictBody = try encodeBatchBody(
                id: recordID,
                rev: "r2",
                blob: Data([1]),
                expected: String(repeating: "x", count: 32)
            )
            let conflict = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/records:batch",
                method: .post,
                headers: headers,
                body: ByteBuffer(data: conflictBody)
            )
            XCTAssertEqual(conflict.status, .ok)
            let conflictOutcomes = try XCTUnwrap(decodeJSONObject(conflict.body)["outcomes"] as? [[String: Any]])
            let authoritative = try XCTUnwrap(conflictOutcomes[0]["authoritativeRecord"] as? [String: Any])
            XCTAssertEqual(authoritative["recordVersion"] as? String, recordVersion)
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(authoritative["blob"] as? String)), blob)

            let changes = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/changes?limit=50",
                method: .get,
                headers: [.authorization: "Bearer owner"]
            )
            XCTAssertEqual(changes.status, .ok)
            let records = try XCTUnwrap(decodeJSONObject(changes.body)["records"] as? [[String: Any]])
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(records[0]["blob"] as? String)), blob)
        }
    }

    func testCrossTenantAndOversizedCompressedRequestsFailClosed() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        try await app.test(.router) { client in
            let createSpace = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [.authorization: "Bearer owner", .contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            )
            let spaceID = try XCTUnwrap(decodeJSONObject(createSpace.body)["spaceId"] as? String)
            let crossTenant = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/scope",
                method: .get,
                headers: [.authorization: "Bearer attacker"]
            )
            XCTAssertEqual(crossTenant.status, .notFound)
            XCTAssertEqual(try decodeJSONObject(crossTenant.body)["code"] as? String, "not_found")
            let compressed = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [
                    .authorization: "Bearer owner",
                    .contentType: "application/json",
                    .contentEncoding: "gzip",
                ],
                body: ByteBuffer(string: "{}")
            )
            XCTAssertEqual(compressed.status, .badRequest)
        }
    }

    func testNormativeOpenAPIAndPluginInputAreIdentical() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let serverRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repositoryRoot = serverRoot.deletingLastPathComponent()
        let normative = try Data(contentsOf: repositoryRoot.appendingPathComponent("api/snippets-sync-v1.yaml"))
        let pluginInput = try Data(contentsOf: serverRoot.appendingPathComponent("Sources/SyncOpenAPI/openapi.yaml"))
        XCTAssertEqual(pluginInput, normative)
    }

    func testStrictConfigurationRejectsInsecureOIDCAndWeakSecrets() throws {
        XCTAssertThrowsError(try OIDCConfiguration(
            issuer: URL(string: "http://issuer.example")!,
            audience: "snippets",
            clientID: "client",
            scopes: ["openid"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 3_600,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 32)
        ))
        XCTAssertThrowsError(try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example")!,
            audience: "snippets",
            clientID: "client",
            scopes: ["openid"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["HS256"],
            maximumTokenAge: 3_600,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 31)
        ))
    }

    func testDuplicateUnknownAndMissingNullableFieldsFailClosed() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        let headers: HTTPFields = [.authorization: "Bearer owner", .contentType: "application/json"]
        try await app.test(.router) { client in
            let duplicate = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"idempotencyKey":"00000000-0000-0000-0000-000000000001","idempotencyKey":"00000000-0000-0000-0000-000000000001"}"#)
            )
            XCTAssertEqual(duplicate.status, .badRequest)
            XCTAssertEqual(try decodeJSONObject(duplicate.body)["code"] as? String, "invalid_request")

            let unknown = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"unexpected":true}"#)
            )
            XCTAssertEqual(unknown.status, .badRequest)

            let createSpace = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: "{}")
            )
            let spaceID = try XCTUnwrap(decodeJSONObject(createSpace.body)["spaceId"] as? String)
            let missingCAS = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/records:batch",
                method: .post,
                headers: headers,
                body: ByteBuffer(string: #"{"items":[{"record":{"id":"00000000-0000-0000-0000-000000000001","rev":"r","deleted":false,"blob":""}}]}"#)
            )
            XCTAssertEqual(missingCAS.status, .badRequest)
        }
    }

    private func makeSetup() throws -> (router: Router<BasicRequestContext>, store: MemorySyncStore) {
        let configuration = try testConfiguration()
        let store = try MemorySyncStore(
            serverInstanceID: configuration.serverInstanceID,
            tokenSecret: configuration.tokenSecret
        )
        let router = try SyncApplicationFactory.makeRouter(
            configuration: configuration,
            store: store,
            tokenValidator: TestTokenValidator()
        )
        return (router, store)
    }

    private func testConfiguration() throws -> ServerConfiguration {
        let oidc = try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example")!,
            audience: "snippets",
            clientID: "android-client",
            scopes: ["openid", "offline_access"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256", "ES256"],
            maximumTokenAge: 3_600,
            clockSkew: 60,
            identityPepper: Data(repeating: 0x11, count: 32)
        )
        return try ServerConfiguration(
            environment: .testing,
            bindHost: "127.0.0.1",
            port: 8_080,
            publicBaseURL: URL(string: "http://localhost:8080")!,
            serverInstanceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            serverVersion: "test",
            tokenSecret: Data(repeating: 0x22, count: 32),
            oidc: oidc
        )
    }

}

private func encodeBatchBody(id: String, rev: String, blob: Data, expected: String?) throws -> Data {
    var item: [String: Any] = [
        "record": [
            "id": id,
            "rev": rev,
            "deleted": false,
            "blob": blob.base64EncodedString(),
        ]
    ]
    item["expectedRecordVersion"] = expected ?? NSNull()
    return try JSONSerialization.data(withJSONObject: ["items": [item]], options: [.sortedKeys])
}

private func decodeJSONObject(_ buffer: ByteBuffer) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any])
}

private struct TestTokenValidator: AccessTokenValidating {
    func validate(bearerToken: String) async throws -> AuthenticatedPrincipal {
        switch bearerToken {
        case "owner": try AuthenticatedPrincipal(identityDigest: Data(repeating: 1, count: 32))
        case "attacker": try AuthenticatedPrincipal(identityDigest: Data(repeating: 2, count: 32))
        default: throw SyncServiceError.authenticationRequired
        }
    }
}
