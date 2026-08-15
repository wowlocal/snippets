import Foundation
import Crypto
import Hummingbird
import HummingbirdTesting
import Logging
@testable import Persistence
import PostgresNIO
import SyncDomain
import SyncHTTP
import XCTest

final class PostgresIntegrationTests: XCTestCase {
    func testMigrationStatementLexerKeepsQuotedSemicolonsTogether() throws {
        let sql = #"""
        -- the first ; is only a comment
        CREATE TABLE "odd;name" (value text DEFAULT 'a;''b');
        /* an outer ; /* and nested ; */ comment */
        DO $migration$
        BEGIN
          PERFORM ';';
        END
        $migration$;
        SELECT 1
        """#

        let statements = try MigrationRunner.statements(in: sql)

        XCTAssertEqual(statements.count, 3)
        XCTAssertTrue(statements[0].contains(#"CREATE TABLE "odd;name""#))
        XCTAssertTrue(statements[1].contains("PERFORM ';';"))
        XCTAssertTrue(statements[2].contains("SELECT 1"))
    }

    func testMigrationsRLSBlindStorageAndConcurrentCAS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SNIPPETS_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set SNIPPETS_INTEGRATION_TESTS=1 and the documented test database variables")
        }

        let ownerConfiguration = try DatabaseConfiguration.load(environment: environment, owner: true)
        let runtimeConfiguration = try DatabaseConfiguration.load(environment: environment)
        guard ownerConfiguration.database == runtimeConfiguration.database,
              ownerConfiguration.database.hasSuffix("_test")
        else {
            XCTFail("Integration tests require one dedicated database whose name ends in _test")
            return
        }

        let ownerClient = PostgresClient(configuration: ownerConfiguration.postgresConfiguration())
        let runtimeClient = PostgresClient(configuration: runtimeConfiguration.postgresConfiguration())
        let migrationDirectory = serverRoot.appendingPathComponent("Migrations", isDirectory: true)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await ownerClient.run() }
            group.addTask { await runtimeClient.run() }
            do {
                try await MigrationRunner(client: ownerClient, directory: migrationDirectory).run()
                try await exerciseDatabase(runtimeClient, ownerClient: ownerClient)
                group.cancelAll()
                while let _ = try await group.next() {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func testHTTPIdentityContextAndPostgresRLSStayTenantScoped() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SNIPPETS_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set SNIPPETS_INTEGRATION_TESTS=1 and the documented test database variables")
        }

        let ownerConfiguration = try DatabaseConfiguration.load(environment: environment, owner: true)
        let runtimeConfiguration = try DatabaseConfiguration.load(environment: environment)
        guard ownerConfiguration.database == runtimeConfiguration.database,
              ownerConfiguration.database.hasSuffix("_test")
        else {
            XCTFail("Integration tests require one dedicated database whose name ends in _test")
            return
        }

        let ownerClient = PostgresClient(configuration: ownerConfiguration.postgresConfiguration())
        let runtimeClient = PostgresClient(configuration: runtimeConfiguration.postgresConfiguration())
        let migrationDirectory = serverRoot.appendingPathComponent("Migrations", isDirectory: true)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await ownerClient.run() }
            group.addTask { await runtimeClient.run() }
            do {
                try await MigrationRunner(client: ownerClient, directory: migrationDirectory).run()
                try await exerciseHTTPBoundary(runtimeClient)
                group.cancelAll()
                while let _ = try await group.next() {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func testHTTPNetworkChaosRetriesPartialBatchAndDeltaReplayStayConvergent() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SNIPPETS_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set SNIPPETS_INTEGRATION_TESTS=1 and the documented test database variables")
        }

        let ownerConfiguration = try DatabaseConfiguration.load(environment: environment, owner: true)
        let runtimeConfiguration = try DatabaseConfiguration.load(environment: environment)
        guard ownerConfiguration.database == runtimeConfiguration.database,
              ownerConfiguration.database.hasSuffix("_test")
        else {
            XCTFail("Integration tests require one dedicated database whose name ends in _test")
            return
        }

        let ownerClient = PostgresClient(configuration: ownerConfiguration.postgresConfiguration())
        let runtimeClient = PostgresClient(configuration: runtimeConfiguration.postgresConfiguration())
        let migrationDirectory = serverRoot.appendingPathComponent("Migrations", isDirectory: true)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await ownerClient.run() }
            group.addTask { await runtimeClient.run() }
            do {
                try await MigrationRunner(client: ownerClient, directory: migrationDirectory).run()
                try await exerciseHTTPNetworkChaos(runtimeClient, ownerClient: ownerClient)
                group.cancelAll()
                while let _ = try await group.next() {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func exerciseHTTPNetworkChaos(
        _ runtimeClient: PostgresClient,
        ownerClient: PostgresClient
    ) async throws {
        let configuration = try Self.integrationServerConfiguration()
        let store = try PostgresSyncStore(
            client: runtimeClient,
            serverInstanceID: configuration.serverInstanceID,
            tokenSecret: configuration.tokenSecret
        )
        let router = try SyncApplicationFactory.makeRouter(
            configuration: configuration,
            store: store,
            tokenValidator: IntegrationTokenValidator()
        )
        let application = Application(router: router)
        let headers: HTTPFields = [
            .authorization: "Bearer tenant-a",
            .contentType: "application/json",
        ]
        // Deliberately place the higher UUID first. PostgreSQL sorts record locks
        // by UUID internally, while HTTP outcomes must remain in request order.
        let existingRecordID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let newRecordID = "00000000-0000-4000-8000-000000000001"
        let initialBlob = Data([0x10, 0x00, 0xff])
        let updatedBlob = Data([0x20, 0x00, 0xfe])
        let independentBlob = Data([0x30, 0x00, 0xfd])

        let spaceID = try await application.test(.router) { client in
            let spaceID = try await Self.createSpace(client: client, headers: headers)
            let create = try await Self.executeBatch(
                client: client,
                headers: headers,
                spaceID: spaceID,
                items: [HTTPBatchFixture(
                    id: existingRecordID,
                    revision: "initial",
                    blob: initialBlob,
                    expectedRecordVersion: nil
                )]
            )
            let createOutcomes = try XCTUnwrap(create["outcomes"] as? [[String: Any]])
            XCTAssertEqual(createOutcomes[0]["kind"] as? String, "accepted")
            let initialVersion = try XCTUnwrap(createOutcomes[0]["recordVersion"] as? String)

            let snapshotResponse = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/changes?limit=50",
                method: .get,
                headers: [.authorization: "Bearer tenant-a"]
            )
            XCTAssertEqual(snapshotResponse.status, .ok)
            let snapshot = try decodeJSONObject(snapshotResponse.body)
            XCTAssertEqual(snapshot["fullSnapshot"] as? Bool, true)
            let checkpointCursor = try XCTUnwrap(snapshot["cursor"] as? String)

            let updateItems = [HTTPBatchFixture(
                id: existingRecordID,
                revision: "updated",
                blob: updatedBlob,
                expectedRecordVersion: initialVersion
            )]
            let updateBody = try Self.encodeBatchBody(updateItems)
            // Hummingbird returns only after PostgresSyncStore committed. Ignore
            // every response byte to model a network loss after that commit.
            _ = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/records:batch",
                method: .post,
                headers: headers,
                body: ByteBuffer(data: updateBody)
            )

            let retryResponse = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/records:batch",
                method: .post,
                headers: headers,
                body: ByteBuffer(data: updateBody)
            )
            XCTAssertEqual(retryResponse.status, .ok)
            let retry = try decodeJSONObject(retryResponse.body)
            XCTAssertEqual(retry["partial"] as? Bool, true)
            let retryOutcomes = try XCTUnwrap(retry["outcomes"] as? [[String: Any]])
            XCTAssertEqual(retryOutcomes[0]["kind"] as? String, "conflict")
            let committedUpdate = try XCTUnwrap(
                retryOutcomes[0]["authoritativeRecord"] as? [String: Any]
            )
            XCTAssertEqual(committedUpdate["rev"] as? String, "updated")
            XCTAssertEqual(
                Data(base64Encoded: try XCTUnwrap(committedUpdate["blob"] as? String)),
                updatedBlob
            )
            let updatedVersion = try XCTUnwrap(committedUpdate["recordVersion"] as? String)
            XCTAssertNotEqual(updatedVersion, initialVersion)

            let deltaURI = "/v1/spaces/\(spaceID)/changes?cursor=\(checkpointCursor)&limit=50"
            let firstDeltaResponse = try await client.execute(
                uri: deltaURI,
                method: .get,
                headers: [.authorization: "Bearer tenant-a"]
            )
            let replayedDeltaResponse = try await client.execute(
                uri: deltaURI,
                method: .get,
                headers: [.authorization: "Bearer tenant-a"]
            )
            XCTAssertEqual(firstDeltaResponse.status, .ok)
            XCTAssertEqual(replayedDeltaResponse.status, .ok)
            XCTAssertEqual(
                Data(firstDeltaResponse.body.readableBytesView),
                Data(replayedDeltaResponse.body.readableBytesView),
                "Replaying the same cursor must reproduce the same ordered delivery"
            )
            let firstDelta = try decodeJSONObject(firstDeltaResponse.body)
            XCTAssertEqual(firstDelta["fullSnapshot"] as? Bool, false)
            let firstDeltaRecords = try XCTUnwrap(firstDelta["records"] as? [[String: Any]])
            XCTAssertEqual(firstDeltaRecords.count, 1)
            XCTAssertEqual(firstDeltaRecords[0]["recordVersion"] as? String, updatedVersion)
            let deltaCursor = try XCTUnwrap(firstDelta["cursor"] as? String)

            let advanced = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/changes?cursor=\(deltaCursor)&limit=50",
                method: .get,
                headers: [.authorization: "Bearer tenant-a"]
            )
            let advancedRecords = try XCTUnwrap(
                decodeJSONObject(advanced.body)["records"] as? [[String: Any]]
            )
            XCTAssertTrue(advancedRecords.isEmpty, "The lost-response retry must not append a change")

            let partialItems = [
                HTTPBatchFixture(
                    id: existingRecordID,
                    revision: "stale-overwrite",
                    blob: Data([0x40]),
                    expectedRecordVersion: initialVersion
                ),
                HTTPBatchFixture(
                    id: newRecordID,
                    revision: "independent",
                    blob: independentBlob,
                    expectedRecordVersion: nil
                ),
            ]
            let partial = try await Self.executeBatch(
                client: client,
                headers: headers,
                spaceID: spaceID,
                items: partialItems
            )
            XCTAssertEqual(partial["partial"] as? Bool, true)
            let partialOutcomes = try XCTUnwrap(partial["outcomes"] as? [[String: Any]])
            XCTAssertEqual(partialOutcomes.map { $0["kind"] as? String }, ["conflict", "accepted"])
            let partialAuthoritative = try XCTUnwrap(
                partialOutcomes[0]["authoritativeRecord"] as? [String: Any]
            )
            XCTAssertEqual(partialAuthoritative["recordVersion"] as? String, updatedVersion)
            let independentVersion = try XCTUnwrap(partialOutcomes[1]["recordVersion"] as? String)

            let partialRetry = try await Self.executeBatch(
                client: client,
                headers: headers,
                spaceID: spaceID,
                items: partialItems
            )
            let partialRetryOutcomes = try XCTUnwrap(
                partialRetry["outcomes"] as? [[String: Any]]
            )
            XCTAssertEqual(partialRetryOutcomes.map { $0["kind"] as? String }, ["conflict", "conflict"])
            let independentAuthoritative = try XCTUnwrap(
                partialRetryOutcomes[1]["authoritativeRecord"] as? [String: Any]
            )
            XCTAssertEqual(independentAuthoritative["recordVersion"] as? String, independentVersion)
            XCTAssertEqual(
                Data(base64Encoded: try XCTUnwrap(independentAuthoritative["blob"] as? String)),
                independentBlob
            )

            let independentDeltaResponse = try await client.execute(
                uri: "/v1/spaces/\(spaceID)/changes?cursor=\(deltaCursor)&limit=50",
                method: .get,
                headers: [.authorization: "Bearer tenant-a"]
            )
            let independentDelta = try decodeJSONObject(independentDeltaResponse.body)
            let independentRecords = try XCTUnwrap(
                independentDelta["records"] as? [[String: Any]]
            )
            XCTAssertEqual(independentRecords.count, 1)
            XCTAssertEqual(independentRecords[0]["id"] as? String, newRecordID)
            XCTAssertEqual(independentRecords[0]["recordVersion"] as? String, independentVersion)

            return try XCTUnwrap(UUID(uuidString: spaceID))
        }

        var databaseCounts: (Int64, Int64, Int64)?
        let rows = try await ownerClient.query("""
            SELECT (SELECT count(*) FROM records WHERE space_id = \(spaceID)),
                   (SELECT count(*) FROM changes WHERE space_id = \(spaceID)),
                   (SELECT next_sequence FROM spaces WHERE id = \(spaceID))
            """)
        for try await values in rows.decode((Int64, Int64, Int64).self) {
            databaseCounts = values
        }
        XCTAssertEqual(databaseCounts?.0, 2, "Retries must not duplicate current records")
        XCTAssertEqual(databaseCounts?.1, 3, "Only create, update, and independent create append changes")
        XCTAssertEqual(databaseCounts?.2, 3, "Rejected retries must not consume feed sequence numbers")

        var noContextCount: Int64?
        for try await value in try await runtimeClient.query(
            "SELECT count(*) FROM records WHERE space_id = \(spaceID)"
        ).decode(Int64.self) {
            noContextCount = value
        }
        XCTAssertEqual(noContextCount, 0, "Chaos retries must not leak request identity into the pool")
    }

    private func exerciseHTTPBoundary(_ runtimeClient: PostgresClient) async throws {
        let configuration = try Self.integrationServerConfiguration()
        let store = try PostgresSyncStore(
            client: runtimeClient,
            serverInstanceID: configuration.serverInstanceID,
            tokenSecret: configuration.tokenSecret
        )
        let router = try SyncApplicationFactory.makeRouter(
            configuration: configuration,
            store: store,
            tokenValidator: IntegrationTokenValidator()
        )
        let application = Application(router: router)
        let tenantAHeaders: HTTPFields = [
            .authorization: "Bearer tenant-a",
            .contentType: "application/json",
        ]
        let tenantBHeaders: HTTPFields = [
            .authorization: "Bearer tenant-b",
            .contentType: "application/json",
        ]
        let sharedRecordID = UUID().uuidString.lowercased()
        let tenantABlob = Data([0x00, 0xff, 0x41, 0x7f])
        let tenantBBlob = Data([0x99, 0x00, 0x42])

        try await application.test(.router) { client in
            let tenantASpace = try await Self.createSpace(client: client, headers: tenantAHeaders)
            let tenantBSpace = try await Self.createSpace(client: client, headers: tenantBHeaders)

            try await Self.submit(
                client: client,
                headers: tenantAHeaders,
                spaceID: tenantASpace,
                recordID: sharedRecordID,
                revision: "tenant-a-r1",
                blob: tenantABlob
            )
            try await Self.submit(
                client: client,
                headers: tenantBHeaders,
                spaceID: tenantBSpace,
                recordID: sharedRecordID,
                revision: "tenant-b-r1",
                blob: tenantBBlob
            )

            let tenantAChanges = try await Self.fetchChanges(
                client: client,
                authorization: "Bearer tenant-a",
                spaceID: tenantASpace
            )
            let tenantBChanges = try await Self.fetchChanges(
                client: client,
                authorization: "Bearer tenant-b",
                spaceID: tenantBSpace
            )
            XCTAssertEqual(tenantAChanges.count, 1)
            XCTAssertEqual(tenantBChanges.count, 1)
            XCTAssertEqual(tenantAChanges[0].id, sharedRecordID)
            XCTAssertEqual(tenantBChanges[0].id, sharedRecordID)
            XCTAssertEqual(tenantAChanges[0].blob, tenantABlob)
            XCTAssertEqual(tenantBChanges[0].blob, tenantBBlob)

            let crossTenant = try await client.execute(
                uri: "/v1/spaces/\(tenantASpace)/scope",
                method: .get,
                headers: [.authorization: "Bearer tenant-b"]
            )
            XCTAssertEqual(crossTenant.status, .notFound)

            let unauthenticated = try await client.execute(
                uri: "/v1/spaces/\(tenantASpace)/changes?limit=50",
                method: .get
            )
            XCTAssertEqual(unauthenticated.status, .unauthorized)
        }

        var noContextRecordCount: Int64?
        for try await value in try await runtimeClient.query("SELECT count(*) FROM records").decode(Int64.self) {
            noContextRecordCount = value
        }
        XCTAssertEqual(
            noContextRecordCount,
            0,
            "HTTP requests must not leak transaction-local RLS identity into the connection pool"
        )
    }

    private static func createSpace(
        client: TestClientProtocol,
        headers: HTTPFields
    ) async throws -> String {
        let response = try await client.execute(
            uri: "/v1/spaces",
            method: .post,
            headers: headers,
            body: ByteBuffer(string: "{}")
        )
        XCTAssertEqual(response.status, .created)
        return try XCTUnwrap(decodeJSONObject(response.body)["spaceId"] as? String)
    }

    private static func submit(
        client: TestClientProtocol,
        headers: HTTPFields,
        spaceID: String,
        recordID: String,
        revision: String,
        blob: Data
    ) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "items": [[
                "record": [
                    "id": recordID,
                    "rev": revision,
                    "deleted": false,
                    "blob": blob.base64EncodedString(),
                ],
                "expectedRecordVersion": NSNull(),
            ]]
        ], options: [.sortedKeys])
        let response = try await client.execute(
            uri: "/v1/spaces/\(spaceID)/records:batch",
            method: .post,
            headers: headers,
            body: ByteBuffer(data: body)
        )
        XCTAssertEqual(response.status, .ok)
        let outcomes = try XCTUnwrap(decodeJSONObject(response.body)["outcomes"] as? [[String: Any]])
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes[0]["kind"] as? String, "accepted")
    }

    private static func executeBatch(
        client: TestClientProtocol,
        headers: HTTPFields,
        spaceID: String,
        items: [HTTPBatchFixture]
    ) async throws -> [String: Any] {
        let response = try await client.execute(
            uri: "/v1/spaces/\(spaceID)/records:batch",
            method: .post,
            headers: headers,
            body: ByteBuffer(data: try encodeBatchBody(items))
        )
        XCTAssertEqual(response.status, .ok)
        return try decodeJSONObject(response.body)
    }

    private static func encodeBatchBody(_ items: [HTTPBatchFixture]) throws -> Data {
        let values: [[String: Any]] = items.map { item in
            var result: [String: Any] = [
                "record": [
                    "id": item.id,
                    "rev": item.revision,
                    "deleted": false,
                    "blob": item.blob.base64EncodedString(),
                ]
            ]
            result["expectedRecordVersion"] = item.expectedRecordVersion ?? NSNull()
            return result
        }
        return try JSONSerialization.data(
            withJSONObject: ["items": values],
            options: [.sortedKeys]
        )
    }

    private static func fetchChanges(
        client: TestClientProtocol,
        authorization: String,
        spaceID: String
    ) async throws -> [(id: String, blob: Data)] {
        let response = try await client.execute(
            uri: "/v1/spaces/\(spaceID)/changes?limit=50",
            method: .get,
            headers: [.authorization: authorization]
        )
        XCTAssertEqual(response.status, .ok)
        let records = try XCTUnwrap(decodeJSONObject(response.body)["records"] as? [[String: Any]])
        return try records.map { record in
            (
                id: try XCTUnwrap(record["id"] as? String),
                blob: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(record["blob"] as? String)))
            )
        }
    }

    private static func integrationServerConfiguration() throws -> ServerConfiguration {
        let oidc = try OIDCConfiguration(
            issuer: URL(string: "https://integration-issuer.example")!,
            audience: "snippets-integration",
            clientID: "snippets-integration-client",
            scopes: ["openid"],
            jwksURL: URL(string: "https://integration-issuer.example/jwks")!,
            allowedAlgorithms: ["RS256"],
            maximumTokenAge: 3_600,
            clockSkew: 60,
            identityPepper: Data(repeating: 0x73, count: 32)
        )
        return try ServerConfiguration(
            environment: .testing,
            bindHost: "127.0.0.1",
            port: 8_080,
            publicBaseURL: URL(string: "http://127.0.0.1:8080")!,
            serverInstanceID: UUID(),
            serverVersion: "postgres-http-integration",
            tokenSecret: Data(repeating: 0x51, count: 32),
            oidc: oidc
        )
    }

    private func exerciseDatabase(_ runtimeClient: PostgresClient, ownerClient: PostgresClient) async throws {
        let serverID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let store = try PostgresSyncStore(
            client: runtimeClient,
            serverInstanceID: serverID,
            tokenSecret: Data(repeating: 0x42, count: 32)
        )
        let aliceRevokedCredential = try AuthenticatedPrincipal(
            identityDigest: Data(repeating: 0x01, count: 32),
            credentialDigest: Data(repeating: 0x11, count: 32),
            credentialExpiresAt: Date().addingTimeInterval(300))
        let alice = try AuthenticatedPrincipal(
            identityDigest: aliceRevokedCredential.identityDigest,
            credentialDigest: Data(repeating: 0x12, count: 32),
            credentialExpiresAt: Date().addingTimeInterval(300))
        let mallory = try AuthenticatedPrincipal(
            identityDigest: Data(repeating: 0x02, count: 32),
            credentialDigest: Data(repeating: 0x22, count: 32),
            credentialExpiresAt: Date().addingTimeInterval(300))
        let aliceInitiallyRevoked = try await store.isAccessTokenRevoked(
            for: aliceRevokedCredential)
        XCTAssertFalse(aliceInitiallyRevoked)
        try await store.revokeAccessToken(for: aliceRevokedCredential)
        let aliceRevoked = try await store.isAccessTokenRevoked(for: aliceRevokedCredential)
        XCTAssertTrue(aliceRevoked)
        do {
            _ = try await store.listSpaces(for: aliceRevokedCredential)
            XCTFail("A revoked credential must fail inside the authorized transaction")
        } catch let error as SyncServiceError {
            XCTAssertEqual(error.code, .authenticationRequired)
        }
        let otherCredentialRevoked = try await store.isAccessTokenRevoked(
            for: alice)
        XCTAssertFalse(otherCredentialRevoked)
        let aliceSpace = try await store.createSpace(for: alice, idempotencyKey: UUID())
        let mallorySpace = try await store.createSpace(for: mallory, idempotencyKey: UUID())

        do {
            _ = try await store.scope(for: mallory, spaceID: aliceSpace.scope.spaceID)
            XCTFail("A second tenant must not resolve the first tenant's space")
        } catch let error as SyncServiceError {
            XCTAssertEqual(error.code, .notFound)
        }

        let sharedRecordID = UUID()
        let aliceBlob = Data([0x00, 0xff, 0x7f, 0x13])
        let malloryBlob = Data([0x99, 0x98])
        let aliceCreate = try await store.submit(
            for: alice,
            spaceID: aliceSpace.scope.spaceID,
            items: [.init(
                record: .init(id: sharedRecordID, rev: "alice-r1", deleted: false, blob: aliceBlob),
                expectedRecordVersion: nil
            )]
        )
        let malloryCreate = try await store.submit(
            for: mallory,
            spaceID: mallorySpace.scope.spaceID,
            items: [.init(
                record: .init(id: sharedRecordID, rev: "mallory-r1", deleted: false, blob: malloryBlob),
                expectedRecordVersion: nil
            )]
        )
        XCTAssertAccepted(aliceCreate.outcomes[0])
        XCTAssertAccepted(malloryCreate.outcomes[0])

        let alicePage = try await store.fetchChanges(
            for: alice,
            spaceID: aliceSpace.scope.spaceID,
            cursor: nil,
            limit: 50
        )
        let malloryPage = try await store.fetchChanges(
            for: mallory,
            spaceID: mallorySpace.scope.spaceID,
            cursor: nil,
            limit: 50
        )
        XCTAssertEqual(alicePage.records.map(\.record.blob), [aliceBlob])
        XCTAssertEqual(malloryPage.records.map(\.record.blob), [malloryBlob])

        let concurrentRecordID = UUID()
        async let first = store.submit(
            for: alice,
            spaceID: aliceSpace.scope.spaceID,
            items: [.init(
                record: .init(id: concurrentRecordID, rev: "candidate-a", deleted: false, blob: Data([0xa0])),
                expectedRecordVersion: nil
            )]
        )
        async let second = store.submit(
            for: alice,
            spaceID: aliceSpace.scope.spaceID,
            items: [.init(
                record: .init(id: concurrentRecordID, rev: "candidate-b", deleted: false, blob: Data([0xb0])),
                expectedRecordVersion: nil
            )]
        )
        let concurrentOutcomes = try await [first.outcomes[0], second.outcomes[0]]
        let acceptedCount = concurrentOutcomes.filter {
            if case .accepted = $0 { return true }
            return false
        }.count
        let conflictCount = concurrentOutcomes.filter {
            if case .conflict = $0 { return true }
            return false
        }.count
        XCTAssertEqual(acceptedCount, 1)
        XCTAssertEqual(conflictCount, 1)

        var noContextRecordCount: Int64?
        for try await value in try await runtimeClient.query("SELECT count(*) FROM records").decode(Int64.self) {
            noContextRecordCount = value
        }
        XCTAssertEqual(noContextRecordCount, 0, "FORCE RLS must deny a pooled connection with no request context")

        let integrationLogger = Logger(label: "snippets.persistence.integration") { _ in
            SwiftLogNoOpLogHandler()
        }
        var malloryUserID: UUID?
        let candidate = UUID()
        let identityRows = try await runtimeClient.query(
            "SELECT snippets_private.resolve_identity(\(mallory.identityDigest), \(candidate))",
            logger: integrationLogger
        )
        for try await value in identityRows.decode(UUID.self) { malloryUserID = value }
        let resolvedMalloryUserID = try XCTUnwrap(malloryUserID)
        let wrongContextCount = try await runtimeClient.withTransaction(logger: integrationLogger) { connection in
            for try await _ in try await connection.query(
                "SELECT set_config('app.user_id', \(resolvedMalloryUserID.uuidString), true)",
                logger: integrationLogger
            ) {}
            var count: Int64?
            for try await value in try await connection.query(
                "SELECT count(*) FROM records WHERE space_id = \(aliceSpace.scope.spaceID)",
                logger: integrationLogger
            ).decode(Int64.self) {
                count = value
            }
            return count
        }
        XCTAssertEqual(wrongContextCount, 0)

        do {
            try await runtimeClient.withTransaction(logger: integrationLogger) { connection in
                for try await _ in try await connection.query(
                    "SELECT set_config('app.user_id', \(resolvedMalloryUserID.uuidString), true)",
                    logger: integrationLogger
                ) {}
                for try await _ in try await connection.query(
                    """
                    INSERT INTO space_memberships(space_id, user_id, role, scope_binding)
                    VALUES (\(aliceSpace.scope.spaceID), \(resolvedMalloryUserID), 'owner', \(Data(repeating: 7, count: 32)))
                    """,
                    logger: integrationLogger
                ) {}
            }
            XCTFail("Runtime SQL must not attach the current user to another tenant's known space")
        } catch {
            // Expected RLS WITH CHECK violation. Do not stringify database errors.
        }

        var roleProperties: (Bool, Bool, Bool)?
        let roleRows = try await runtimeClient.query("""
            SELECT r.rolsuper, r.rolbypassrls,
                   EXISTS (
                       SELECT 1 FROM pg_class c
                       WHERE c.relname IN ('spaces', 'records', 'changes')
                         AND pg_get_userbyid(c.relowner) = current_user
                   )
              FROM pg_roles r
             WHERE r.rolname = current_user
            """)
        for try await values in roleRows.decode((Bool, Bool, Bool).self) {
            roleProperties = values
        }
        XCTAssertEqual(roleProperties?.0, false, "runtime role must not be superuser")
        XCTAssertEqual(roleProperties?.1, false, "runtime role must not bypass RLS")
        XCTAssertEqual(roleProperties?.2, false, "runtime role must not own protected tables")

        let validRecipientPublicKey = Data(
            P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        let pairingResults = try await withThrowingTaskGroup(
            of: SyncErrorCode?.self,
            returning: [SyncErrorCode?].self
        ) { group in
            for index in 0..<24 {
                group.addTask {
                    do {
                        _ = try await store.createPairing(
                            for: alice,
                            spaceID: aliceSpace.scope.spaceID,
                            request: .init(
                                recipientPublicKey: validRecipientPublicKey,
                                nonce: Data(repeating: UInt8(index + 1), count: 32),
                                expiresInSeconds: 600
                            )
                        )
                        return nil
                    } catch let error as SyncServiceError {
                        return error.code
                    }
                }
            }
            var results: [SyncErrorCode?] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(
            pairingResults.filter { $0 == nil }.count,
            16,
            "unexpected pairing outcomes: \(pairingResults)")
        XCTAssertEqual(
            pairingResults.filter { $0 == .rateLimited }.count,
            8,
            "unexpected pairing outcomes: \(pairingResults)")

        let cursorBeforeRestore = alicePage.cursor
        let recordVersionBeforeRestore = try XCTUnwrap(
            alicePage.records.first(where: { $0.record.id == sharedRecordID })?.recordVersion
        )
        for try await _ in try await ownerClient.query(
            "SELECT snippets_private.rotate_dataset_after_restore(\(aliceSpace.scope.spaceID))"
        ) {}
        do {
            _ = try await store.fetchChanges(
                for: alice,
                spaceID: aliceSpace.scope.spaceID,
                cursor: cursorBeforeRestore,
                limit: 50
            )
            XCTFail("A pre-restore cursor must require dataset-reset review")
        } catch let error as SyncServiceError {
            XCTAssertEqual(error.code, .datasetReset)
        }
        let restoredSnapshot = try await store.fetchChanges(
            for: alice,
            spaceID: aliceSpace.scope.spaceID,
            cursor: nil,
            limit: 50
        )
        XCTAssertFalse(restoredSnapshot.records.isEmpty)
        XCTAssertNotEqual(
            restoredSnapshot.records.first(where: { $0.record.id == sharedRecordID })?.recordVersion,
            recordVersionBeforeRestore
        )

        // Put the accounting row exactly at its hard change quota without
        // inserting a large fixture. The next application write must be a
        // positional quota rejection and must not consume a feed sequence.
        try await drain(ownerClient.query("""
            UPDATE spaces
               SET change_history_bytes = 536870912 - current_record_bytes,
                   change_count = 250000
             WHERE id = \(aliceSpace.scope.spaceID)
            """))
        try await drain(ownerClient.query("""
            UPDATE users u
               SET storage_bytes = usage.total_bytes
              FROM (
                  SELECT owner_user_id, sum(current_record_bytes + change_history_bytes) AS total_bytes
                    FROM spaces
                   GROUP BY owner_user_id
              ) usage
             WHERE u.id = usage.owner_user_id
            """))
        var sequenceBeforeQuota: Int64?
        for try await value in try await ownerClient.query(
            "SELECT next_sequence FROM spaces WHERE id = \(aliceSpace.scope.spaceID)"
        ).decode(Int64.self) {
            sequenceBeforeQuota = value
        }
        let quotaResult = try await store.submit(
            for: alice,
            spaceID: aliceSpace.scope.spaceID,
            items: [.init(
                record: .init(id: UUID(), rev: "quota", deleted: false, blob: Data([1])),
                expectedRecordVersion: nil
            )]
        )
        XCTAssertEqual(quotaResult.outcomes, [.rejected(code: .quotaExceeded)])
        var sequenceAfterQuota: Int64?
        for try await value in try await ownerClient.query(
            "SELECT next_sequence FROM spaces WHERE id = \(aliceSpace.scope.spaceID)"
        ).decode(Int64.self) {
            sequenceAfterQuota = value
        }
        XCTAssertEqual(sequenceAfterQuota, sequenceBeforeQuota)
    }

    private var serverRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct HTTPBatchFixture: Sendable {
    let id: String
    let revision: String
    let blob: Data
    let expectedRecordVersion: String?
}

private func decodeJSONObject(_ buffer: ByteBuffer) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any])
}

private struct IntegrationTokenValidator: AccessTokenValidating {
    func validate(bearerToken: String) async throws -> AuthenticatedPrincipal {
        switch bearerToken {
        case "tenant-a":
            try AuthenticatedPrincipal(
                identityDigest: Data(repeating: 0xa1, count: 32),
                credentialDigest: Data(repeating: 0xc1, count: 32),
                credentialExpiresAt: Date().addingTimeInterval(300))
        case "tenant-b":
            try AuthenticatedPrincipal(
                identityDigest: Data(repeating: 0xb2, count: 32),
                credentialDigest: Data(repeating: 0xd2, count: 32),
                credentialExpiresAt: Date().addingTimeInterval(300))
        default:
            throw SyncServiceError.authenticationRequired
        }
    }
}

private func XCTAssertAccepted(
    _ outcome: BatchOutcome,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .accepted = outcome else {
        XCTFail("Expected an accepted outcome", file: file, line: line)
        return
    }
}
