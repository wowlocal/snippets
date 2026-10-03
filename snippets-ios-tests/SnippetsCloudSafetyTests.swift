import XCTest

@testable import Snippets

@MainActor
final class SnippetsCloudSafetyTests: XCTestCase {
    func testSignInDiagnosticsKeepOriginalFailureWhenCleanupMasksIt() async throws {
        var events: [DiagnosticEvent] = []
        let diagnostics = SnippetsCloudSignInDiagnostics { events.append($0) }
        do {
            try await diagnostics.run {
                try await diagnostics.run {
                    diagnostics.storedSessionPresent = true
                    diagnostics.enter(.sessionBinding)
                    diagnostics.reason = .storedIssuerMismatch
                    diagnostics.capture(NSError(domain: NSCocoaErrorDomain, code: 4864))
                    diagnostics.enter(.credentialCleanup)
                    throw NSError(domain: NSURLErrorDomain, code: -1001,
                        userInfo: [NSLocalizedDescriptionKey: "PRIVATE-TOKEN"])
                }
            }
            XCTFail("Expected failure")
        } catch {}
        let terminal = events.filter {
            if case .cloudSignIn(_, let outcome, _, _, _, _) = $0 { return outcome != .entered }
            return false
        }
        XCTAssertEqual(terminal.count, 1)
        guard case .cloudSignIn(let stage, let outcome, _, let present, let reason, _) = terminal.first else {
            return XCTFail("Missing terminal sign-in diagnostic")
        }
        XCTAssertEqual(stage, .sessionBinding)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(present, true)
        XCTAssertEqual(reason, .storedIssuerMismatch)
    }

    func testSignInDiagnosticsSeparateCancellationFromFailureAndSuccess() async throws {
        var events: [DiagnosticEvent] = []
        let cancelled = SnippetsCloudSignInDiagnostics { events.append($0) }
        do {
            try await cancelled.run {
                cancelled.enter(.browserWaiting)
                throw CancellationError()
            }
        } catch {}
        guard case .cloudSignIn(.browserWaiting, .cancelled, _, _, .authorizationCancelled, _) = events.last else {
            return XCTFail("Cancellation must remain an informational outcome")
        }
        events.removeAll()
        let succeeded = SnippetsCloudSignInDiagnostics { events.append($0) }
        let result = try await succeeded.run {
            try await succeeded.run {
                succeeded.enter(.librarySetup)
                return 42
            }
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(events.filter {
            if case .cloudSignIn(_, .succeeded, _, _, _, _) = $0 { return true }
            return false
        }.count, 1)
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
