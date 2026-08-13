import Foundation
import Logging
import Persistence
import PostgresNIO
import SyncDomain
import XCTest

final class PostgresIntegrationTests: XCTestCase {
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

    private func exerciseDatabase(_ runtimeClient: PostgresClient, ownerClient: PostgresClient) async throws {
        let serverID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let store = try PostgresSyncStore(
            client: runtimeClient,
            serverInstanceID: serverID,
            tokenSecret: Data(repeating: 0x42, count: 32)
        )
        let alice = try AuthenticatedPrincipal(identityDigest: Data(repeating: 0x01, count: 32))
        let mallory = try AuthenticatedPrincipal(identityDigest: Data(repeating: 0x02, count: 32))
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
    }

    private var serverRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
