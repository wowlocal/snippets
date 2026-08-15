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
            XCTAssertEqual(discoveryJSON["protocolMinor"] as? Int, 4)
            XCTAssertEqual(discoveryJSON["recordProfile"] as? String, "snippets-wire-v1")
            XCTAssertEqual((discoveryJSON["limits"] as? [String: Any])?["maxBlobBytes"] as? Int, 900_000)
            let oidc = try XCTUnwrap(discoveryJSON["oidc"] as? [String: Any])
            XCTAssertEqual(oidc["resource"] as? String, "http://localhost:8080")
            XCTAssertEqual(oidc["authorizationFlow"] as? String, "authorization_code_pkce")
            XCTAssertNil(oidc["requiresVerifiedEmail"])
            XCTAssertEqual(oidc["maxAccessTokenAgeSeconds"] as? Int, 3_600)
            XCTAssertEqual(oidc["stepUpMaxAgeSeconds"] as? Int, 300)
            let capabilities = try XCTUnwrap(discoveryJSON["capabilities"] as? [String])
            XCTAssertTrue(capabilities.contains("oauth-resource-indicators"))
            XCTAssertTrue(capabilities.contains("oauth-token-revocation"))
            XCTAssertTrue(capabilities.contains("resource-session-revocation"))
            XCTAssertTrue(capabilities.contains("account-without-required-email"))
            XCTAssertTrue(capabilities.contains("pairing-v2"))
            XCTAssertTrue(capabilities.contains("offline-recovery-v1"))

            let protected = try await client.execute(uri: "/v1/spaces", method: .get)
            XCTAssertEqual(protected.status, .unauthorized)
            let errorJSON = try decodeJSONObject(protected.body)
            XCTAssertEqual(errorJSON["code"] as? String, "authentication_required")
            XCTAssertNotNil(errorJSON["requestId"] as? String)
            XCTAssertNil(errorJSON["message"])
        }
    }

    func testResourceLogoutImmediatelyRevokesOnlyPresentedAccessToken() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        let owner: HTTPFields = [.authorization: "Bearer owner"]
        let otherCredential: HTTPFields = [.authorization: "Bearer owner-step-up"]

        try await app.test(.router) { client in
            let before = try await client.execute(
                uri: "/v1/spaces", method: .get, headers: owner)
            XCTAssertEqual(before.status, .ok)
            let logout = try await client.execute(
                uri: "/v1/session", method: .delete, headers: owner)
            XCTAssertEqual(logout.status, .noContent)
            // A lost success response can be retried with the now-revoked token.
            let retry = try await client.execute(
                uri: "/v1/session", method: .delete, headers: owner)
            XCTAssertEqual(retry.status, .noContent)
            let replay = try await client.execute(
                uri: "/v1/spaces", method: .get, headers: owner)
            XCTAssertEqual(replay.status, .unauthorized)
            let other = try await client.execute(
                uri: "/v1/spaces",
                method: .get,
                headers: otherCredential)
            XCTAssertEqual(
                other.status, .ok,
                "Revoking one device credential must not revoke another credential"
            )
        }
    }

    func testRevocationIsRecheckedAfterBodyCollectionBeforeMutation() async throws {
        let configuration = try testConfiguration()
        let store = RevocationSequenceStore(results: [false, true])
        let router = try SyncApplicationFactory.makeRouter(
            configuration: configuration,
            store: store,
            tokenValidator: TestTokenValidator()
        )
        try await Application(router: router).test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [
                    .authorization: "Bearer owner",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: "{}")
            )
            XCTAssertEqual(response.status, .unauthorized)
        }
        let metrics = await store.metrics()
        XCTAssertEqual(metrics.checks, 2)
        XCTAssertEqual(metrics.handlerCalls, 0)
    }

    func testAlreadyRevokedLogoutShortCircuitsWithoutAnotherStoreWrite() async throws {
        let configuration = try testConfiguration()
        let store = RevocationSequenceStore(results: [true])
        let router = try SyncApplicationFactory.makeRouter(
            configuration: configuration,
            store: store,
            tokenValidator: TestTokenValidator()
        )
        try await Application(router: router).test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/session",
                method: .delete,
                headers: [.authorization: "Bearer owner"]
            )
            XCTAssertEqual(response.status, .noContent)
            XCTAssertEqual(response.headers[.cacheControl], "no-store")
        }
        let metrics = await store.metrics()
        XCTAssertEqual(metrics.checks, 1)
        XCTAssertEqual(metrics.revocations, 0)
        XCTAssertEqual(metrics.handlerCalls, 0)
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

    func testAuthenticationPrecedesBodyProcessingAndPublicGETRejectsBodies() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        try await app.test(.router) { client in
            let unauthenticated = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [.contentType: "application/json", .contentEncoding: "gzip"],
                body: ByteBuffer(string: "not-json")
            )
            XCTAssertEqual(unauthenticated.status, .unauthorized)
            XCTAssertEqual(
                try decodeJSONObject(unauthenticated.body)["code"] as? String,
                "authentication_required"
            )

            let publicBody = try await client.execute(
                uri: "/.well-known/snippets-sync",
                method: .get,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            )
            XCTAssertEqual(publicBody.status, .badRequest)
            XCTAssertEqual(publicBody.headers[.connection], "close")
        }
    }

    func testKeyGrantingOperationsRequireFreshPhishingResistantAuthentication() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        let body = ByteBuffer(string: #"{"expectedVersion":null,"keyEpoch":1,"algorithm":"snippets-recovery-hkdf-sha256-aes256gcm-v1","ciphertext":"AQ=="}"#)
        try await app.test(.router) { client in
            let createSpace = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: [.authorization: "Bearer owner", .contentType: "application/json"],
                body: ByteBuffer(string: "{}")
            )
            let spaceID = try XCTUnwrap(decodeJSONObject(createSpace.body)["spaceId"] as? String)

            let ordinary = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/key-envelopes/recovery",
                method: .put,
                headers: [.authorization: "Bearer owner", .contentType: "application/json"],
                body: body
            )
            XCTAssertEqual(ordinary.status, .unauthorized)
            XCTAssertEqual(
                try decodeJSONObject(ordinary.body)["code"] as? String,
                "reauthentication_required"
            )
            XCTAssertEqual(
                ordinary.headers[.wwwAuthenticate],
                #"Bearer error="insufficient_user_authentication""#
            )

            let steppedUp = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/key-envelopes/recovery",
                method: .put,
                headers: [.authorization: "Bearer owner-step-up", .contentType: "application/json"],
                body: ByteBuffer(string: #"{"expectedVersion":null,"keyEpoch":1,"algorithm":"snippets-recovery-hkdf-sha256-aes256gcm-v1","ciphertext":"AQ=="}"#)
            )
            XCTAssertEqual(steppedUp.status, .ok)
        }
    }

    func testPairingEnvelopeIsRedactedAndCanBeTakenOnlyOnce() async throws {
        let setup = try makeSetup()
        let app = Application(router: setup.router)
        let owner: HTTPFields = [.authorization: "Bearer owner", .contentType: "application/json"]
        let steppedUp: HTTPFields = [
            .authorization: "Bearer owner-step-up",
            .contentType: "application/json",
        ]
        let publicKey = "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
        let nonce = Data(repeating: 0x42, count: 32).base64EncodedString()
        try await app.test(.router) { client in
            let createSpace = try await client.execute(
                uri: "/v1/spaces",
                method: .post,
                headers: owner,
                body: ByteBuffer(string: "{}"))
            let spaceID = try XCTUnwrap(decodeJSONObject(createSpace.body)["spaceId"] as? String)

            let create = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/pairings",
                method: .post,
                headers: owner,
                body: ByteBuffer(string:
                    #"{"recipientPublicKey":"\#(publicKey)","nonce":"\#(nonce)","expiresInSeconds":300}"#))
            XCTAssertEqual(create.status, .created)
            let created = try decodeJSONObject(create.body)
            let pairingID = try XCTUnwrap(created["pairingId"] as? String)
            XCTAssertEqual(created["state"] as? String, "pending")
            XCTAssertNil(created["algorithm"])
            XCTAssertNil(created["ciphertext"])
            XCTAssertNotNil((created["authenticationTag"] as? String)?.range(
                of: #"^[A-Z2-9]{8}$"#,
                options: .regularExpression))

            let crossTenant = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/pairings/\(pairingID)",
                method: .get,
                headers: [.authorization: "Bearer attacker"])
            XCTAssertEqual(crossTenant.status, .notFound)

            let approve = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/pairings/\(pairingID)/approval",
                method: .put,
                headers: steppedUp,
                body: ByteBuffer(string:
                    #"{"recipientKeyHash":"aYvqY9xEo0RmP/FCmuoQhC3ye2uZHvJYZrLGwCzcxb4=","algorithm":"snippets-pairing-p256-hkdf-sha256-aes256gcm-v1","ciphertext":"AQID"}"#))
            XCTAssertEqual(approve.status, .ok)
            let approved = try decodeJSONObject(approve.body)
            XCTAssertEqual(approved["state"] as? String, "approved")
            XCTAssertNil(approved["algorithm"])
            XCTAssertNil(approved["ciphertext"])

            let poll = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/pairings/\(pairingID)",
                method: .get,
                headers: [.authorization: "Bearer owner"])
            XCTAssertEqual(poll.status, .ok)
            XCTAssertNil(try decodeJSONObject(poll.body)["ciphertext"])

            let take = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/pairings/\(pairingID)/consume",
                method: .post,
                headers: [.authorization: "Bearer owner"])
            XCTAssertEqual(take.status, .ok)
            let taken = try decodeJSONObject(take.body)
            XCTAssertEqual(taken["algorithm"] as? String,
                           "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1")
            XCTAssertEqual(taken["ciphertext"] as? String, "AQID")

            let replay = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/pairings/\(pairingID)/consume",
                method: .post,
                headers: [.authorization: "Bearer owner"])
            XCTAssertEqual(replay.status, .notFound)
        }
    }

    func testGlobalAndPerPrincipalRateLimitsFailClosed() async throws {
        let globalConfiguration = try testConfiguration(
            globalRequestsPerSecond: 1,
            globalRequestBurst: 1
        )
        let globalStore = try MemorySyncStore(
            serverInstanceID: globalConfiguration.serverInstanceID,
            tokenSecret: globalConfiguration.tokenSecret
        )
        let globalRouter = try SyncApplicationFactory.makeRouter(
            configuration: globalConfiguration,
            store: globalStore,
            tokenValidator: TestTokenValidator()
        )
        try await Application(router: globalRouter).test(.router) { client in
            let first = try await client.execute(uri: "/.well-known/snippets-sync", method: .get)
            let second = try await client.execute(uri: "/.well-known/snippets-sync", method: .get)
            XCTAssertEqual(first.status, .ok)
            XCTAssertEqual(second.status, .tooManyRequests)
        }

        let principalConfiguration = try testConfiguration(
            principalRequestsPerSecond: 1,
            principalRequestBurst: 1
        )
        let principalStore = try MemorySyncStore(
            serverInstanceID: principalConfiguration.serverInstanceID,
            tokenSecret: principalConfiguration.tokenSecret
        )
        let principalRouter = try SyncApplicationFactory.makeRouter(
            configuration: principalConfiguration,
            store: principalStore,
            tokenValidator: TestTokenValidator()
        )
        try await Application(router: principalRouter).test(.router) { client in
            let headers: HTTPFields = [.authorization: "Bearer owner"]
            let first = try await client.execute(uri: "/v1/spaces", method: .get, headers: headers)
            let second = try await client.execute(uri: "/v1/spaces", method: .get, headers: headers)
            XCTAssertEqual(first.status, .ok)
            XCTAssertEqual(second.status, .tooManyRequests)
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

    func testContainerRuntimeExcludesMigrationPrivilegesAndPinsImages() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let serverRoot = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dockerfile = try String(
            contentsOf: serverRoot.appendingPathComponent("Dockerfile"),
            encoding: .utf8
        )
        let compose = try String(
            contentsOf: serverRoot.appendingPathComponent("docker-compose.yml"),
            encoding: .utf8
        )

        let serverStage = try XCTUnwrap(
            dockerfile.components(separatedBy: "FROM runtime AS server").last
        )
        XCTAssertFalse(serverStage.contains("snippets-migrate"))
        XCTAssertFalse(serverStage.contains("Migrations"))
        for line in dockerfile.split(separator: "\n").filter({ $0.hasPrefix("FROM ") && !$0.contains("FROM runtime") }) {
            XCTAssertNotNil(line.range(of: #"@sha256:[0-9a-f]{64}"#, options: .regularExpression))
        }
        XCTAssertNotNil(compose.range(
            of: #"image: postgres:[^\n]+@sha256:[0-9a-f]{64}"#,
            options: .regularExpression
        ))

        let serverService = try XCTUnwrap(
            compose.components(separatedBy: "  server:\n").last?
                .components(separatedBy: "\nvolumes:").first
        )
        XCTAssertFalse(serverService.contains("DATABASE_OWNER_"))
        XCTAssertTrue(serverService.contains("*database-runtime-environment"))
    }

    func testStrictConfigurationRejectsInsecureOIDCAndWeakSecrets() throws {
        XCTAssertThrowsError(try OIDCConfiguration(
            issuer: URL(string: "http://issuer.example")!,
            audience: "snippets",
            clientID: "client",
            scopes: ["openid"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 300,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 32)
        ))
        XCTAssertThrowsError(try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example?tenant=wrong")!,
            audience: "snippets",
            clientID: "client",
            scopes: ["openid"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 300,
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
            maximumTokenAge: 300,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 31)
        ))

        let noBackgroundScope = try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example")!,
            audience: "https://sync.example",
            clientID: "client",
            scopes: ["openid"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 300,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 32)
        )
        XCTAssertThrowsError(try ServerConfiguration(
            environment: .production,
            bindHost: "127.0.0.1",
            port: 8_080,
            publicBaseURL: URL(string: "https://sync.example")!,
            serverInstanceID: UUID(),
            serverVersion: "test",
            tokenSecret: Data(repeating: 2, count: 32),
            oidc: noBackgroundScope
        ))

        let confusedAudience = try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example")!,
            audience: "https://sync.example",
            clientID: "https://sync.example",
            scopes: ["openid", "offline_access"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 300,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 32)
        )
        XCTAssertThrowsError(try ServerConfiguration(
            environment: .production,
            bindHost: "127.0.0.1",
            port: 8_080,
            publicBaseURL: URL(string: "https://sync.example")!,
            serverInstanceID: UUID(),
            serverVersion: "test",
            tokenSecret: Data(repeating: 2, count: 32),
            oidc: confusedAudience
        ))

        let wrongResource = try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example")!,
            audience: "https://other-sync.example",
            clientID: "client",
            scopes: ["openid", "offline_access"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 300,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 32)
        )
        XCTAssertThrowsError(try ServerConfiguration(
            environment: .production,
            bindHost: "127.0.0.1",
            port: 8_080,
            publicBaseURL: URL(string: "https://sync.example")!,
            serverInstanceID: UUID(),
            serverVersion: "test",
            tokenSecret: Data(repeating: 2, count: 32),
            oidc: wrongResource
        ))

        let longLivedAccessTokens = try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example")!,
            audience: "https://sync.example",
            clientID: "client",
            scopes: ["openid", "offline_access"],
            jwksURL: URL(string: "https://issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 3_600,
            clockSkew: 60,
            identityPepper: Data(repeating: 1, count: 32)
        )
        XCTAssertThrowsError(try ServerConfiguration(
            environment: .production,
            bindHost: "127.0.0.1",
            port: 8_080,
            publicBaseURL: URL(string: "https://sync.example")!,
            serverInstanceID: UUID(),
            serverVersion: "test",
            tokenSecret: Data(repeating: 2, count: 32),
            oidc: longLivedAccessTokens
        ))
    }

    func testProductionEnvironmentRequiresExplicitStrongAuthenticationMapping() throws {
        let secret = Data(repeating: 0x31, count: 32).base64EncodedString()
        var environment = [
            "SNIPPETS_ENV": "production",
            "PUBLIC_BASE_URL": "https://sync.example",
            "SERVER_INSTANCE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "TOKEN_HMAC_SECRET": secret,
            "IDENTITY_PEPPER": Data(repeating: 0x32, count: 32).base64EncodedString(),
            "OIDC_ISSUER": "https://issuer.example/",
            "OIDC_JWKS_URL": "https://issuer.example/jwks",
            "OIDC_AUDIENCE": "https://sync.example",
            "OIDC_CLIENT_ID": "native-client",
            "OIDC_SCOPES": "openid offline_access",
            "OIDC_ALLOWED_ALGORITHMS": "RS256",
        ]

        XCTAssertThrowsError(try ServerConfiguration.load(environment: environment)) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .missing("OIDC_STEP_UP_AMR_VALUES or OIDC_STEP_UP_ACR_VALUES")
            )
        }

        environment["OIDC_STEP_UP_AMR_VALUES"] = "webauthn"
        XCTAssertNoThrow(try ServerConfiguration.load(environment: environment))

        environment["OIDC_SCOPES"] = "openid"
        XCTAssertThrowsError(try ServerConfiguration.load(environment: environment))
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

    private func testConfiguration(
        globalRequestsPerSecond: Int = 256,
        globalRequestBurst: Int = 512,
        principalRequestsPerSecond: Int = 30,
        principalRequestBurst: Int = 60
    ) throws -> ServerConfiguration {
        let oidc = try OIDCConfiguration(
            issuer: URL(string: "https://issuer.example")!,
            audience: "http://localhost:8080",
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
            oidc: oidc,
            httpGlobalRequestsPerSecond: globalRequestsPerSecond,
            httpGlobalRequestBurst: globalRequestBurst,
            httpPrincipalRequestsPerSecond: principalRequestsPerSecond,
            httpPrincipalRequestBurst: principalRequestBurst
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
        case "owner", "owner-step-up":
            try AuthenticatedPrincipal(
                identityDigest: Data(repeating: 1, count: 32),
                credentialDigest: Data(repeating: bearerToken == "owner" ? 11 : 12, count: 32),
                credentialExpiresAt: Date().addingTimeInterval(300))
        case "attacker":
            try AuthenticatedPrincipal(
                identityDigest: Data(repeating: 2, count: 32),
                credentialDigest: Data(repeating: 22, count: 32),
                credentialExpiresAt: Date().addingTimeInterval(300))
        default: throw SyncServiceError.authenticationRequired
        }
    }

    func validate(
        bearerToken: String,
        requirement: AuthenticationRequirement
    ) async throws -> AuthenticatedPrincipal {
        if case .recentPhishingResistant = requirement,
           bearerToken != "owner-step-up" {
            throw SyncServiceError.reauthenticationRequired
        }
        return try await validate(bearerToken: bearerToken)
    }
}

private actor RevocationSequenceStore: SyncStore {
    private var results: [Bool]
    private var checkCount = 0
    private var revocationCount = 0
    private var handlerCallCount = 0

    init(results: [Bool]) {
        self.results = results
    }

    func metrics() -> (checks: Int, revocations: Int, handlerCalls: Int) {
        (checkCount, revocationCount, handlerCallCount)
    }

    func readiness() async throws {}

    func isAccessTokenRevoked(for principal: AuthenticatedPrincipal) async throws -> Bool {
        _ = principal
        checkCount += 1
        guard !results.isEmpty else { return false }
        return results.removeFirst()
    }

    func revokeAccessToken(for principal: AuthenticatedPrincipal) async throws {
        _ = principal
        revocationCount += 1
    }

    func listSpaces(for principal: AuthenticatedPrincipal) async throws -> [SpaceDescriptor] {
        try unexpected()
    }

    func createSpace(
        for principal: AuthenticatedPrincipal,
        idempotencyKey: UUID?
    ) async throws -> SpaceDescriptor {
        try unexpected()
    }

    func scope(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID
    ) async throws -> SpaceDescriptor {
        try unexpected()
    }

    func fetchChanges(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        cursor: String?,
        limit: Int
    ) async throws -> ChangesPage {
        try unexpected()
    }

    func submit(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        items: [BatchItem]
    ) async throws -> BatchSubmission {
        try unexpected()
    }

    func currentKeyEnvelope(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID
    ) async throws -> (SpaceDescriptor, KeyEnvelope?) {
        try unexpected()
    }

    func putKeyEnvelope(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        request: PutKeyEnvelope
    ) async throws -> KeyEnvelope {
        try unexpected()
    }

    func createPairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        request: CreatePairing
    ) async throws -> Pairing {
        try unexpected()
    }

    func approvePairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID,
        request: ApprovePairing
    ) async throws -> Pairing {
        try unexpected()
    }

    func pairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID
    ) async throws -> Pairing {
        try unexpected()
    }

    func takeApprovedPairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID
    ) async throws -> Pairing {
        try unexpected()
    }

    func consumePairing(
        for principal: AuthenticatedPrincipal,
        spaceID: UUID,
        pairingID: UUID
    ) async throws {
        handlerCallCount += 1
        throw SyncServiceError.internalError
    }

    private func unexpected<T>() throws -> T {
        handlerCallCount += 1
        throw SyncServiceError.internalError
    }
}
