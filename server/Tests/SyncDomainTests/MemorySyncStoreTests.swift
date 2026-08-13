import Foundation
import XCTest
@testable import SyncDomain

final class MemorySyncStoreTests: XCTestCase {
    private let instanceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let tokenSecret = Data(repeating: 0x41, count: 32)

    func testCASConflictReturnsAuthoritativeRecordAndPartialBatchCommitsIndependentItem() async throws {
        let store = try MemorySyncStore(serverInstanceID: instanceID, tokenSecret: tokenSecret)
        let user = try principal(1)
        let space = try await store.createSpace(for: user, idempotencyKey: nil)
        let first = wire(id: UUID(), rev: "1", byte: 0x10)

        let create = try await store.submit(
            for: user,
            spaceID: space.scope.spaceID,
            items: [BatchItem(record: first, expectedRecordVersion: nil)]
        )
        let firstVersion = try acceptedVersion(create.outcomes[0])

        let second = wire(id: UUID(), rev: "1", byte: 0x20)
        let staleFirst = wire(id: first.id, rev: "2", byte: 0x30)
        let partial = try await store.submit(
            for: user,
            spaceID: space.scope.spaceID,
            items: [
                BatchItem(record: staleFirst, expectedRecordVersion: String(repeating: "x", count: 32)),
                BatchItem(record: second, expectedRecordVersion: nil),
            ]
        )

        XCTAssertTrue(partial.partial)
        guard case .conflict(let authoritative?) = partial.outcomes[0] else {
            return XCTFail("Expected authoritative conflict")
        }
        XCTAssertEqual(authoritative.record, first)
        XCTAssertEqual(authoritative.recordVersion, firstVersion)
        _ = try acceptedVersion(partial.outcomes[1])

        let update = try await store.submit(
            for: user,
            spaceID: space.scope.spaceID,
            items: [BatchItem(record: staleFirst, expectedRecordVersion: firstVersion)]
        )
        _ = try acceptedVersion(update.outcomes[0])
    }

    func testBlobBoundaryIsAcceptedAndOversizeIsPositionalRejection() async throws {
        let store = try MemorySyncStore(serverInstanceID: instanceID, tokenSecret: tokenSecret)
        let user = try principal(2)
        let space = try await store.createSpace(for: user, idempotencyKey: nil)
        let exact = OpaqueWireRecord(id: UUID(), rev: "r", deleted: false, blob: Data(repeating: 7, count: 900_000))
        let tooLarge = OpaqueWireRecord(id: UUID(), rev: "r", deleted: false, blob: Data(repeating: 8, count: 900_001))

        let result = try await store.submit(
            for: user,
            spaceID: space.scope.spaceID,
            items: [BatchItem(record: exact, expectedRecordVersion: nil), BatchItem(record: tooLarge, expectedRecordVersion: nil)]
        )
        _ = try acceptedVersion(result.outcomes[0])
        XCTAssertEqual(result.outcomes[1], .rejected(code: .invalidRequest))

        let snapshot = try await store.fetchChanges(for: user, spaceID: space.scope.spaceID, cursor: nil, limit: 50)
        XCTAssertEqual(snapshot.records.first?.record.blob, exact.blob)
    }

    func testSnapshotPaginationThenOrderedDelta() async throws {
        let store = try MemorySyncStore(serverInstanceID: instanceID, tokenSecret: tokenSecret)
        let user = try principal(3)
        let space = try await store.createSpace(for: user, idempotencyKey: nil)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        ]
        _ = try await store.submit(
            for: user,
            spaceID: space.scope.spaceID,
            items: ids.map { BatchItem(record: wire(id: $0, rev: "1", byte: 1), expectedRecordVersion: nil) }
        )

        let first = try await store.fetchChanges(for: user, spaceID: space.scope.spaceID, cursor: nil, limit: 2)
        XCTAssertTrue(first.fullSnapshot)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.records.map(\.record.id), Array(ids.sorted { $0.uuidString < $1.uuidString }.prefix(2)))

        let second = try await store.fetchChanges(for: user, spaceID: space.scope.spaceID, cursor: first.cursor, limit: 2)
        XCTAssertTrue(second.fullSnapshot)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(second.records.count, 1)

        let existing = second.records[0]
        _ = try await store.submit(
            for: user,
            spaceID: space.scope.spaceID,
            items: [BatchItem(record: wire(id: existing.record.id, rev: "2", byte: 9), expectedRecordVersion: existing.recordVersion)]
        )
        let delta = try await store.fetchChanges(for: user, spaceID: space.scope.spaceID, cursor: second.cursor, limit: 50)
        XCTAssertFalse(delta.fullSnapshot)
        XCTAssertEqual(delta.records.count, 1)
        XCTAssertEqual(delta.records[0].record.rev, "2")
    }

    func testCursorIsBoundToSpaceInstanceDatasetAndFeed() async throws {
        let store = try MemorySyncStore(serverInstanceID: instanceID, tokenSecret: tokenSecret)
        let user = try principal(4)
        let first = try await store.createSpace(for: user, idempotencyKey: nil)
        let second = try await store.createSpace(for: user, idempotencyKey: nil)
        let page = try await store.fetchChanges(for: user, spaceID: first.scope.spaceID, cursor: nil, limit: 50)

        await XCTAssertThrowsSyncError(.cursorInvalid) {
            _ = try await store.fetchChanges(for: user, spaceID: second.scope.spaceID, cursor: page.cursor, limit: 50)
        }
        await XCTAssertThrowsSyncError(.cursorInvalid) {
            _ = try await store.fetchChanges(for: user, spaceID: first.scope.spaceID, cursor: page.cursor + "x", limit: 50)
        }

        try await store.rotateDataset(spaceID: first.scope.spaceID)
        await XCTAssertThrowsSyncError(.datasetReset) {
            _ = try await store.fetchChanges(for: user, spaceID: first.scope.spaceID, cursor: page.cursor, limit: 50)
        }
    }

    func testCrossTenantIDsDoNotRevealOrAuthorize() async throws {
        let store = try MemorySyncStore(serverInstanceID: instanceID, tokenSecret: tokenSecret)
        let owner = try principal(5)
        let attacker = try principal(6)
        let space = try await store.createSpace(for: owner, idempotencyKey: nil)
        let record = wire(id: UUID(), rev: "1", byte: 1)
        _ = try await store.submit(for: owner, spaceID: space.scope.spaceID, items: [.init(record: record, expectedRecordVersion: nil)])

        let attackerSpaces = try await store.listSpaces(for: attacker)
        XCTAssertTrue(attackerSpaces.isEmpty)
        await XCTAssertThrowsSyncError(.notFound) {
            _ = try await store.fetchChanges(for: attacker, spaceID: space.scope.spaceID, cursor: nil, limit: 50)
        }
        await XCTAssertThrowsSyncError(.notFound) {
            _ = try await store.submit(for: attacker, spaceID: space.scope.spaceID, items: [.init(record: record, expectedRecordVersion: nil)])
        }
    }

    func testRecoveryEnvelopeCASAndPairingKeySubstitutionGuard() async throws {
        let store = try MemorySyncStore(serverInstanceID: instanceID, tokenSecret: tokenSecret)
        let user = try principal(7)
        let space = try await store.createSpace(for: user, idempotencyKey: nil)
        let encryptedBundle = Data(repeating: 0x77, count: 128)

        let envelope = try await store.putKeyEnvelope(
            for: user,
            spaceID: space.scope.spaceID,
            request: PutKeyEnvelope(expectedVersion: nil, keyEpoch: 1, algorithm: "HPKE-v1", ciphertext: encryptedBundle)
        )
        XCTAssertEqual(envelope.version, 1)
        await XCTAssertThrowsSyncError(.conflict) {
            _ = try await store.putKeyEnvelope(
                for: user,
                spaceID: space.scope.spaceID,
                request: PutKeyEnvelope(expectedVersion: nil, keyEpoch: 1, algorithm: "HPKE-v1", ciphertext: encryptedBundle)
            )
        }

        let recipientKey = Data(repeating: 0x22, count: 32)
        let pairing = try await store.createPairing(
            for: user,
            spaceID: space.scope.spaceID,
            request: CreatePairing(recipientPublicKey: recipientKey, authenticationTag: "ABCD23", expiresInSeconds: 120)
        )
        await XCTAssertThrowsSyncError(.conflict) {
            _ = try await store.approvePairing(
                for: user,
                spaceID: space.scope.spaceID,
                pairingID: pairing.pairingID,
                request: ApprovePairing(recipientKeyHash: Data(repeating: 0, count: 32), algorithm: "HPKE-v1", ciphertext: encryptedBundle)
            )
        }
        let approved = try await store.approvePairing(
            for: user,
            spaceID: space.scope.spaceID,
            pairingID: pairing.pairingID,
            request: ApprovePairing(recipientKeyHash: sha256(recipientKey), algorithm: "HPKE-v1", ciphertext: encryptedBundle)
        )
        XCTAssertEqual(approved.state, .approved)
        XCTAssertEqual(approved.ciphertext, encryptedBundle)
        try await store.consumePairing(for: user, spaceID: space.scope.spaceID, pairingID: pairing.pairingID)
        await XCTAssertThrowsSyncError(.notFound) {
            _ = try await store.pairing(for: user, spaceID: space.scope.spaceID, pairingID: pairing.pairingID)
        }
    }

    func testCreateSpaceIdempotency() async throws {
        let store = try MemorySyncStore(serverInstanceID: instanceID, tokenSecret: tokenSecret)
        let user = try principal(8)
        let key = UUID()
        let first = try await store.createSpace(for: user, idempotencyKey: key)
        let second = try await store.createSpace(for: user, idempotencyKey: key)
        XCTAssertEqual(first, second)
        let spaces = try await store.listSpaces(for: user)
        XCTAssertEqual(spaces.count, 1)
    }

    private func principal(_ value: UInt8) throws -> AuthenticatedPrincipal {
        try AuthenticatedPrincipal(identityDigest: Data(repeating: value, count: 32))
    }

    private func wire(id: UUID, rev: String, byte: UInt8) -> OpaqueWireRecord {
        OpaqueWireRecord(id: id, rev: rev, deleted: false, blob: Data(repeating: byte, count: 64))
    }

    private func acceptedVersion(_ outcome: BatchOutcome) throws -> String {
        guard case .accepted(let version, _) = outcome else {
            XCTFail("Expected accepted outcome")
            throw SyncServiceError.internalError
        }
        return version
    }
}

private func XCTAssertThrowsSyncError<T>(
    _ expected: SyncErrorCode,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected SyncServiceError", file: file, line: line)
    } catch let error as SyncServiceError {
        XCTAssertEqual(error.code, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error type", file: file, line: line)
    }
}
