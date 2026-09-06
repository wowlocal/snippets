import XCTest
import CryptoKit

@testable import Snippets

@MainActor
final class SnippetsCloudSafetyTests: XCTestCase {
    func testVerifiedProfileBindsSignatureNonceAudienceAndResourceSubject() throws {
        let key = P256.Signing.PrivateKey()
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let point = key.publicKey.x963Representation
        let jwks = try JSONDecoder().decode(SnippetsCloudVerifiedProfile.Keys.self, from: JSONSerialization.data(withJSONObject: [
            "keys": [["kid": "fixture", "kty": "EC", "crv": "P-256", "alg": "ES256",
                      "x": encode(point.subdata(in: 1..<33)), "y": encode(point.subdata(in: 33..<65))]]]))
        func token(_ audience: String, subject: String = "account-a", expires: Double = 300) throws -> String {
            let now = Date().timeIntervalSince1970
            let claims: [String: Any] = ["iss": "https://identity.example/oidc", "sub": subject,
                "aud": audience, "nonce": "nonce-a", "iat": now, "exp": now + expires,
                "name": "Test Account", "email": "fixture@example.test", "email_verified": true]
            let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "fixture"])
            let message = encode(header) + "." + encode(try JSONSerialization.data(withJSONObject: claims))
            return message + "." + encode(try key.signature(for: Data(message.utf8)).rawRepresentation)
        }
        let identity = try token("native-client"), access = try token("https://sync.example")
        func verify(_ id: String, _ resource: String, nonce: String = "nonce-a") throws -> SnippetsCloudVerifiedProfile {
            try .verify(idToken: id, accessToken: resource, keys: jwks,
                issuer: "https://identity.example/oidc", clientID: "native-client",
                resource: "https://sync.example", nonce: nonce)
        }
        XCTAssertEqual(try verify(identity, access).displayName, "Test Account")
        XCTAssertThrowsError(try verify(identity, access, nonce: "nonce-b"))
        XCTAssertThrowsError(try verify(identity, token("https://sync.example", subject: "account-b")))
        XCTAssertThrowsError(try verify(token("other-client"), access))
        XCTAssertThrowsError(try verify(token("native-client", expires: -10), access))
    }

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

    func testInterruptedPostAuthorizationBootstrapSurvivesRestartWithoutClaimingLock() throws {
        let serverURL = try XCTUnwrap(URL(string: "https://cloud.example"))
        let server = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        let space = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let pending = SnippetsCloudAccountBootstrap.PendingPostAuthorization(
            schemaVersion: 1,
            phase: "bootstrapPending",
            serverURL: serverURL,
            serverInstanceID: server,
            protocolMajor: 2,
            spaceID: space,
            scopeBinding: "membership-a-000000000000000000000",
            operation: .changeLibrary)
        let decoded = try JSONDecoder().decode(
            SnippetsCloudAccountBootstrap.PendingPostAuthorization.self,
            from: JSONEncoder().encode(pending))
        XCTAssertEqual(decoded, pending)
        XCTAssertTrue(decoded.matches(.init(
            serverURL: serverURL,
            apiBaseURL: serverURL.appending(path: "v2"),
            spaceID: space,
            serverInstanceID: server,
            protocolMajor: 2)))

        let defaultsName = "SnippetsCloudSafetyTests.pending-bootstrap.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.pending-bootstrap-credentials",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let secrets = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.pending-bootstrap-state",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        try secrets.storeItem(
            JSONEncoder().encode(pending),
            account: SnippetsCloudAccountBootstrap.pendingPostAuthorizationAccount)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            bootstrapSecrets: secrets,
            snippetsCloudEnabled: true)
        let bootstrap = SnippetsCloudAccountBootstrap(
            selection: selection,
            secrets: secrets)

        XCTAssertEqual(try bootstrap.state(), .setupInterrupted)
    }

    func testMalformedPostAuthorizationBootstrapNeverLooksSignedOut() throws {
        let defaultsName = "SnippetsCloudSafetyTests.malformed-bootstrap.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.malformed-bootstrap-credentials",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let secrets = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.malformed-bootstrap-state",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            bootstrapSecrets: secrets,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            serverInstanceID: UUID(),
            accessToken: "test-access-token")
        try secrets.storeItem(
            Data("not a bootstrap transaction".utf8),
            account: SnippetsCloudAccountBootstrap.pendingPostAuthorizationAccount)
        let bootstrap = SnippetsCloudAccountBootstrap(
            selection: selection,
            secrets: secrets)

        XCTAssertThrowsError(try bootstrap.state())
        XCTAssertEqual(bootstrap.stateForDisplay(), .setupStateUnverified)
        XCTAssertThrowsError(try selection.makeTransport()) { error in
            guard let failure = error as? SyncBackendSelectionStore.Failure,
                  case .postAuthorizationSetupRequired = failure else {
                return XCTFail("Expected malformed marker to keep sync fenced, got \(error)")
            }
        }
    }

    func testPostAuthorizationCrashUsesTargetBoundReauthentication() {
        XCTAssertTrue(
            SyncBackendSelectionStore.Failure.missingCredential
                .requiresTargetBoundPostAuthorizationReauthentication)
        XCTAssertTrue(
            SyncBackendSelectionStore.Failure.postAuthorizationMembershipMismatch
                .requiresTargetBoundPostAuthorizationReauthentication,
            "an old session left active before candidate publication must reauthenticate the marker target")
        XCTAssertFalse(
            SyncBackendSelectionStore.Failure.postAuthorizationStateUnavailable
                .requiresTargetBoundPostAuthorizationReauthentication)
    }
}
