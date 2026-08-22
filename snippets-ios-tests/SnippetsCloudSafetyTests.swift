import XCTest

@testable import Snippets

@MainActor
final class SnippetsCloudSafetyTests: XCTestCase {
    func testOwnerAndWriterRequireExplicitInitialLibrarySelection() {
        let server = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        let owner = SnippetsCloudLibraryChoice(
            spaceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            serverInstanceID: server,
            role: "owner")
        let writer = SnippetsCloudLibraryChoice(
            spaceID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            serverInstanceID: server,
            role: "writer")

        XCTAssertNil(automaticSnippetsCloudLibraryChoice(
            [owner, writer],
            existingSpaceID: nil))
    }

    func testStepUpBindingRequiresTheExactWritableMembership() throws {
        let serverURL = try XCTUnwrap(URL(string: "https://cloud.example"))
        let server = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        let space = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let expected = SnippetsCloudStepUpBinding(
            serverURL: serverURL,
            serverInstanceID: server,
            spaceID: space,
            scopeBinding: "membership-a-000000000000000000000")

        XCTAssertTrue(expected.matches(
            serverURL: serverURL,
            serverInstanceID: server,
            spaceID: space,
            scopeBinding: expected.scopeBinding,
            role: "owner"))
        XCTAssertFalse(expected.matches(
            serverURL: serverURL,
            serverInstanceID: server,
            spaceID: space,
            scopeBinding: "membership-b-000000000000000000000",
            role: "owner"))
        XCTAssertFalse(expected.matches(
            serverURL: serverURL,
            serverInstanceID: server,
            spaceID: space,
            scopeBinding: expected.scopeBinding,
            role: "reader"))
    }

    func testAppleRecoveryVerificationIsBoundToCurrentEnvelopeAndMembership() throws {
        let serverURL = try XCTUnwrap(URL(string: "https://cloud.example"))
        let server = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        let space = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let dataset = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
        let feed = UUID(uuidString: "00000000-0000-4000-8000-000000000030")!
        let ciphertext = Data([1, 2, 3])
        let scope = SnippetsCloudBootstrapClient.Scope(
            protocolMajor: 2,
            serverInstanceID: server,
            spaceID: space,
            scopeBinding: "membership-a-000000000000000000000",
            datasetGeneration: dataset,
            feedEpoch: feed)
        let envelope = SnippetsCloudBootstrapClient.RecoveryState.Envelope(
            version: 3,
            keyEpoch: 7,
            algorithm: LibraryKeyBootstrap.recoveryAlgorithm,
            ciphertext: ciphertext)
        let remote = SnippetsCloudBootstrapClient.RecoveryState(
            keyEpoch: 7,
            recovery: envelope,
            scope: scope)
        let coordinates = SyncBackendSelectionStore.CloudCoordinates(
            serverURL: serverURL,
            apiBaseURL: serverURL.appending(path: "v2"),
            spaceID: space,
            serverInstanceID: server,
            protocolMajor: 2)
        let record = SnippetsCloudAccountBootstrap.RecoveryVerificationRecord(
            serverURL: serverURL,
            serverInstanceID: server,
            protocolMajor: 2,
            spaceID: space,
            scopeBinding: scope.scopeBinding,
            keyEpoch: 7,
            envelopeVersion: 3,
            envelopeCiphertextFingerprint:
                SnippetsCloudAccountBootstrap.RecoveryVerificationRecord.fingerprint(ciphertext),
            kitFingerprint: String(repeating: "b", count: 64))

        XCTAssertTrue(record.matches(coordinates: coordinates, remote: remote))
        XCTAssertFalse(record.matches(
            coordinates: coordinates,
            remote: .init(
                keyEpoch: 7,
                recovery: envelope,
                scope: .init(
                    protocolMajor: 2,
                    serverInstanceID: server,
                    spaceID: space,
                    scopeBinding: "membership-b-000000000000000000000",
                    datasetGeneration: dataset,
                    feedEpoch: feed))))
        XCTAssertFalse(record.matches(
            coordinates: coordinates,
            remote: .init(
                keyEpoch: 7,
                recovery: .init(
                    version: 4,
                    keyEpoch: 7,
                    algorithm: LibraryKeyBootstrap.recoveryAlgorithm,
                    ciphertext: Data([4, 5, 6])),
                scope: scope)))
    }
}
