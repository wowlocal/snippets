import Foundation
import XCTest
@testable import Snippets

/// Server ADR 0007 device-approved sign-in on Apple: the new device's request, claim and
/// commit path, and the approving device's pairing-then-bind path. Everything runs
/// against an in-process driver, in-memory Keychains and a temporary support directory.
@MainActor
final class SnippetsCloudDeviceSignInTests: XCTestCase {
    private var previousSupportRoot: String?
    private var supportRoot: URL!

    override func setUpWithError() throws {
        previousSupportRoot = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        supportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceSignIn-\(UUID())")
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, supportRoot.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        if let previousSupportRoot {
            setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousSupportRoot, 1)
        } else { unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey) }
        try? FileManager.default.removeItem(at: supportRoot)
    }

    // MARK: New device

    func testAvailabilityIsDiscoveryOnlyAndRequiresTheCapability() async throws {
        let supported = Fixture()
        _ = try? await supported.signIn { flow in
            XCTAssertTrue(supported.driver.requests.isEmpty, "The sheet appears before any request")
            let available = await flow.isDeviceSignInAvailable()
            XCTAssertTrue(available)
            XCTAssertEqual(supported.driver.requests.map(\.path), ["/.well-known/snippets-sync"])
            throw CancellationError()
        }
        let unsupported = Fixture(mode: .noDeviceSignIn)
        _ = try? await unsupported.signIn { flow in
            let available = await flow.isDeviceSignInAvailable()
            XCTAssertFalse(available)
            do {
                _ = try await flow.beginDeviceSignIn()
                XCTFail("A server without the capability must not open a request")
            } catch {
                XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .deviceSignInUnavailable)
            }
            throw CancellationError()
        }
        XCTAssertFalse(unsupported.driver.requests.contains { $0.path == "/v2/auth/device-requests" })
        let changingAccount = Fixture()
        _ = try? await changingAccount.signIn(chooseAccount: true) { flow in
            let available = await flow.isDeviceSignInAvailable()
            XCTAssertFalse(available, "Only a signed-out sheet offers Sign In with Another Device")
            throw CancellationError()
        }
    }

    func testApprovedClaimCommitsKeylessSessionForTheApprovedLibraryAndPairing() async throws {
        let fixture = Fixture(pendingClaims: 2)
        var presentation: SnippetsCloudDeviceSignInPresentation?
        var delays: [TimeInterval] = []
        let result = try await fixture.signIn { flow in
            let shown = try await flow.beginDeviceSignIn()
            presentation = shown
            let request = try LibraryKeyBootstrap.DeviceSignInRequest(qrPayload: shown.qrPayload)
            XCTAssertEqual(request.serverURL, fixture.origin)
            XCTAssertEqual(request.requestID, fixture.driver.requestID)
            XCTAssertEqual(shown.confirmationCode, request.confirmationCode)
            XCTAssertFalse(shown.qrPayload.contains(fixture.driver.pollToken), "The payload never carries the poll token")
            let stored = try XCTUnwrap(fixture.bootstrapSecrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceSignInAccount))
            let pending = try LibraryKeyBootstrap.PendingDeviceSignIn(jsonData: stored)
            XCTAssertEqual(pending.pollToken, fixture.driver.pollToken)
            try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { delays.append($0) })
        }
        XCTAssertEqual(delays, [2, 2])
        XCTAssertEqual(result.spaceID, fixture.driver.spaceID)
        let pairing = try XCTUnwrap(result.recipientPairing)
        let invitation = try pairing.invitation
        XCTAssertEqual(invitation.pairingID, fixture.driver.pairingID)
        XCTAssertEqual(invitation.spaceID, fixture.driver.spaceID)
        XCTAssertEqual(invitation.confirmationCode, presentation?.confirmationCode)
        XCTAssertEqual(fixture.client.storedAccountID(), fixture.driver.accountID)
        XCTAssertNil(try fixture.client.storedAccountKey(), "A device signed in by another device never holds the key")
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        XCTAssertNil(try fixture.bootstrapSecrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceSignInAccount),
            "The request ends with the attempt; the draft lives on only as the recipient pairing")
        let create = try XCTUnwrap(fixture.driver.requests.first { $0.path == "/v2/auth/device-requests" })
        XCTAssertEqual(Set(create.body.keys), ["recipientPublicKey", "nonce"])
        XCTAssertEqual(Data(base64Encoded: create.body["recipientPublicKey"] ?? "")?.count, 65)
        XCTAssertEqual(Data(base64Encoded: create.body["nonce"] ?? "")?.count, 32)
        let claims = fixture.driver.requests.filter { $0.path == fixture.driver.claimPath }
        XCTAssertEqual(claims.count, 3)
        XCTAssertTrue(claims.allSatisfy { $0.body == ["pollToken": fixture.driver.pollToken] })
        XCTAssertEqual(fixture.driver.requests.map(\.path).suffix(3), [
            "/v2/spaces", "/v2/spaces/\(fixture.driver.spaceID.uuidString.lowercased())",
            "/v2/spaces/\(fixture.driver.spaceID.uuidString.lowercased())/pairings/\(fixture.driver.pairingID.uuidString.lowercased())"])
        for account in [SyncBackendSelectionStore.oauthSessionAccount, SyncBackendSelectionStore.oauthRevocationAccount] {
            if let data = try fixture.keychain.loadItem(account: account) {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(fixture.driver.pollToken))
            }
        }
    }

    func testClaimShapesAreExactAndAnApprovedGrantIsJournaledBeforeItsShapeIsChecked() async throws {
        let pending = Fixture(mode: .claimPendingExtraMember)
        _ = try? await pending.signIn { flow in
            let shown = try await flow.beginDeviceSignIn()
            do {
                try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { _ in })
                XCTFail("A pending claim with an extra member is rejected")
            } catch {
                XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .invalidResponse)
            }
            throw CancellationError()
        }
        XCTAssertNil(try pending.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))

        let approved = Fixture(mode: .claimApprovedExtraMember)
        do {
            _ = try await approved.signIn { flow in
                let shown = try await flow.beginDeviceSignIn()
                do {
                    try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { _ in })
                    XCTFail("An approved claim with an extra member is rejected")
                } catch {
                    XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .invalidResponse)
                    XCTAssertNotNil(try approved.keychain.loadItem(
                        account: SyncBackendSelectionStore.oauthSessionReplacementAccount),
                        "The issued tokens were journaled before the shape check")
                    XCTAssertNil(try approved.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
                }
                throw CancellationError()
            }
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try approved.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        XCTAssertTrue(approved.driver.requests.contains {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == approved.driver.refresh
                && $0.body["tokenTypeHint"] == "refresh_token"
        }, "Cancellation retires the rejected grant")
    }

    func testPollingHonorsRetryAfterAndBacksOffAfterTransportFailures() async throws {
        let limited = Fixture(mode: .claimRateLimitedOnce)
        var limitedDelays: [TimeInterval] = []
        _ = try await limited.signIn { flow in
            let shown = try await flow.beginDeviceSignIn()
            try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { limitedDelays.append($0) })
        }
        XCTAssertEqual(limitedDelays, [7])

        let offline = Fixture(mode: .claimTransportFailures)
        var offlineDelays: [TimeInterval] = []
        _ = try await offline.signIn { flow in
            let shown = try await flow.beginDeviceSignIn()
            try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { offlineDelays.append($0) })
        }
        XCTAssertEqual(offlineDelays, [4, 8, 2])
    }

    func testExpiredOrRejectedRequestDiscardsLocalStateAndCommitsNothing() async throws {
        for mode in [Driver.Mode.claimExpired, .claimRejected] {
            let fixture = Fixture(mode: mode)
            _ = try? await fixture.signIn { flow in
                let shown = try await flow.beginDeviceSignIn()
                do {
                    try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { _ in })
                    XCTFail("Expected a final claim answer")
                } catch {
                    XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure,
                        mode == .claimExpired ? .deviceSignInExpired : .deviceSignInRejected)
                }
                XCTAssertNil(try fixture.bootstrapSecrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceSignInAccount))
                throw CancellationError()
            }
            XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        }
        let local = Fixture()
        var clock = Date()
        _ = try? await local.signIn { flow in
            let shown = try await flow.beginDeviceSignIn()
            clock = shown.expiresAt
            do {
                try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, now: { clock }, sleep: { _ in })
                XCTFail("Expected local expiry")
            } catch {
                XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .deviceSignInExpired)
            }
            throw CancellationError()
        }
        XCTAssertFalse(local.driver.requests.contains { $0.path == local.driver.claimPath },
            "An expired request is not polled")
    }

    func testMissingLibraryOrForeignPairingFailsClosedAndRetiresTheGrant() async throws {
        for mode in [Driver.Mode.claimUnknownSpace, .foreignPairing] {
            let fixture = Fixture(mode: mode)
            var chooserShown = false
            do {
                _ = try await fixture.signIn(chooseLibrary: { _ in chooserShown = true; throw CancellationError() }) { flow in
                    let shown = try await flow.beginDeviceSignIn()
                    try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { _ in })
                }
                XCTFail("Expected \(mode) to fail closed")
            } catch {
                if mode == .claimUnknownSpace {
                    guard case SnippetsCloudNativeAuthClient.Failure.spaceSelectionRequired = error else {
                        return XCTFail("Expected a closed library failure, got \(error)")
                    }
                }
            }
            XCTAssertFalse(chooserShown, "A device grant never shows a chooser")
            XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
            XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
            XCTAssertTrue(fixture.driver.requests.contains {
                $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.driver.refresh
            })
        }
    }

    func testSignedInByAnotherDeviceExplainsInsteadOfRevealingAKey() async throws {
        let fixture = Fixture()
        _ = try await fixture.completeDeviceSignIn()
        let defaultsName = "DeviceSignIn.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let selection = SyncBackendSelectionStore(defaults: defaults, keychain: fixture.keychain,
            bootstrapSecrets: fixture.bootstrapSecrets, snippetsCloudEnabled: true)
        XCTAssertEqual(selection.cloudAccountIdentifier,
            SnippetsCloudAccountIdentifier.displayForm(fixture.driver.accountID))
        XCTAssertFalse(selection.cloudAccountKeyIsStored)
        XCTAssertThrowsError(try selection.cloudAccountKeyAfterLocalAuthentication())
        XCTAssertEqual(SnippetsCloudAccountKeyCopy.signedInByAnotherDevice,
            "This device was signed in by another device. View the account key on a device that has it.")
    }

    // MARK: Approving device

    func testApprovalPreparationShowsCodeWithoutNetworkAndRejectsAnotherOrigin() async throws {
        let fixture = try ApproverFixture()
        defer { fixture.removeDefaults() }
        try await fixture.prepareApprovingDevice()
        let requestCount = fixture.auth.driver.requests.count
        let request = try fixture.deviceRequest()
        let state = try await fixture.bootstrap.prepareApproval(qrPayload: request.qrPayload())
        XCTAssertEqual(state, .deviceSignInApprovalReady(confirmationCode: request.confirmationCode))
        XCTAssertEqual(fixture.auth.driver.requests.count, requestCount, "The code is shown before any network call")
        XCTAssertEqual(fixture.bootstrap.stateForDisplay(), .deviceSignInApprovalReady(confirmationCode: request.confirmationCode))
        try fixture.bootstrap.cancelApproval()
        XCTAssertNil(try fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceApprovalAccount))

        let foreign = try fixture.deviceRequest(server: XCTUnwrap(URL(string: "https://other.example.test")))
        do {
            _ = try await fixture.bootstrap.prepareApproval(qrPayload: foreign.qrPayload())
            XCTFail("A request for another origin must be refused")
        } catch {
            guard case SnippetsCloudAccountBootstrap.Failure.accountMismatch = error else {
                return XCTFail("Expected an origin mismatch, got \(error)")
            }
        }
        XCTAssertNil(try fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceApprovalAccount))
        XCTAssertEqual(fixture.auth.driver.requests.count, requestCount)
    }

    func testFreshApprovalCreatesClampedPairingRecordsItAndBindsTheRequest() async throws {
        let fixture = try ApproverFixture(mode: .createdPairingAlreadyApproved)
        defer { fixture.removeDefaults() }
        try await fixture.prepareApprovingDevice()
        let request = try fixture.deviceRequest()
        fixture.auth.driver.setDeviceRecipient(key: request.recipientPublicKey, nonce: request.nonce)
        _ = try fixture.bootstrap.prepareDeviceSignInApproval(qrPayload: request.qrPayload())
        let raw = try XCTUnwrap(fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceApprovalAccount))
        var events: [DiagnosticEvent] = []
        let state = try await fixture.bootstrap.finishDeviceSignInApproval(
            raw, coordinates: XCTUnwrap(fixture.selection.cloudCoordinates), client: fixture.client(),
            record: { events.append($0) })
        XCTAssertEqual(state, .deviceSignInApproved)
        let create = try XCTUnwrap(fixture.auth.driver.requests.first {
            $0.method == "POST" && $0.path == fixture.auth.driver.pairingsPath })
        let seconds = try XCTUnwrap(create.json["expiresInSeconds"] as? Int)
        XCTAssertTrue((593...595).contains(seconds), "clamp(expiresAt − now − 5, 60, 600), got \(seconds)")
        let approval = try XCTUnwrap(fixture.auth.driver.requests.first { $0.path == fixture.auth.driver.approvalPath })
        XCTAssertEqual(approval.body, [
            "spaceId": fixture.auth.driver.spaceID.uuidString.lowercased(),
            "pairingId": fixture.auth.driver.pairingID.uuidString.lowercased(),
        ])
        XCTAssertEqual(approval.authorization, "Bearer \(ApproverFixture.accessToken)")
        XCTAssertNil(try fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceApprovalAccount))
        guard case .cloudSignInRequest(.deviceApproval, .succeeded, _, nil, nil, nil)? = events.last else {
            return XCTFail("Expected one aggregate approval outcome")
        }
        let text = String(decoding: try DiagnosticRecord(event: events[0], timestamp: "2026-10-03T12:00:00.000Z",
            elapsedMilliseconds: 1, sessionIdentifier: "test", sequence: 1).jsonLine(), as: UTF8.self)
        for secret in [request.confirmationCode, request.requestID.uuidString.lowercased(),
                       fixture.auth.driver.pairingID.uuidString.lowercased()] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertEqual(SnippetsCloudPairingApprovalCopy.deviceSignInApprovedMessage, "The new device is signed in.")
    }

    func testInterruptedApprovalRetriesTheBindingWithoutASecondPairing() async throws {
        let fixture = try ApproverFixture(mode: .approvalTransportFailureOnce)
        defer { fixture.removeDefaults() }
        try await fixture.prepareApprovingDevice()
        let request = try fixture.deviceRequest()
        fixture.auth.driver.setDeviceRecipient(key: request.recipientPublicKey, nonce: request.nonce)
        let recorded = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: fixture.auth.origin, spaceID: fixture.auth.driver.spaceID,
            pairingID: fixture.auth.driver.pairingID, nonce: request.nonce,
            recipientPublicKey: request.recipientPublicKey,
            expiresAtEpochSeconds: Int64(Date().timeIntervalSince1970) + 300)
        let raw = try LibraryKeyBootstrap.PendingDeviceApproval(request: request, pairing: recorded).jsonData
        try fixture.secrets.storeItem(raw, account: SnippetsCloudAccountBootstrap.deviceApprovalAccount)
        let state = try await fixture.bootstrap.finishDeviceSignInApproval(
            raw, coordinates: XCTUnwrap(fixture.selection.cloudCoordinates), client: fixture.client(),
            record: { _ in })
        XCTAssertEqual(state, .deviceSignInApproved)
        XCTAssertFalse(fixture.auth.driver.requests.contains { $0.method == "POST" && $0.path == fixture.auth.driver.pairingsPath },
            "A recorded pairing is reused, never replaced")
        XCTAssertFalse(fixture.auth.driver.requests.contains { $0.method == "PUT" },
            "An already approved pairing is not approved again")
        XCTAssertEqual(fixture.auth.driver.requests.filter { $0.path == fixture.auth.driver.approvalPath }.count, 2,
            "A transport failure retries the idempotent binding")
        XCTAssertNil(try fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceApprovalAccount))
    }

    func testMismatchedPairingTagOrFinalAnswerEndsTheApprovalIntent() async throws {
        for mode in [Driver.Mode.createdPairingWrongTag, .approvalConflict] {
            let fixture = try ApproverFixture(mode: mode)
            defer { fixture.removeDefaults() }
            try await fixture.prepareApprovingDevice()
            let request = try fixture.deviceRequest()
            fixture.auth.driver.setDeviceRecipient(key: request.recipientPublicKey, nonce: request.nonce)
            _ = try fixture.bootstrap.prepareDeviceSignInApproval(qrPayload: request.qrPayload())
            let raw = try XCTUnwrap(fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceApprovalAccount))
            do {
                _ = try await fixture.bootstrap.finishDeviceSignInApproval(
                    raw, coordinates: XCTUnwrap(fixture.selection.cloudCoordinates), client: fixture.client(),
                    record: { _ in })
                XCTFail("Expected \(mode) to end the approval")
            } catch {
                switch (mode, error) {
                case (.createdPairingWrongTag, SnippetsCloudAccountBootstrap.Failure.invalidInvitation),
                     (.approvalConflict, SnippetsCloudAccountBootstrap.Failure.deviceSignInRequestEnded):
                    break
                default: XCTFail("Unexpected failure for \(mode): \(error)")
                }
            }
            XCTAssertNil(try fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.deviceApprovalAccount))
            if mode == .createdPairingWrongTag {
                XCTAssertFalse(fixture.auth.driver.requests.contains { $0.path == fixture.auth.driver.approvalPath },
                    "A tag mismatch stops before the request is bound")
            }
        }
    }

    // MARK: Fixtures

    private final class Fixture {
        let driver: Driver
        let keychain: KeychainSecretStore
        let bootstrapSecrets: KeychainSecretStore
        let client: SnippetsCloudNativeAuthClient
        let origin: URL

        init(mode: Driver.Mode = .normal, pendingClaims: Int = 1) {
            origin = URL(string: "https://\(UUID().uuidString.lowercased()).example.test")!
            driver = Driver(origin: origin, mode: mode, pendingClaims: pendingClaims)
            DriverProtocol.register(driver, host: origin.host!)
            keychain = KeychainSecretStore(tier: .deviceOnly, service: "device-sign-in-tests", itemAccessibility: .afterFirstUnlock, inMemory: true)
            bootstrapSecrets = KeychainSecretStore(tier: .deviceOnly, service: "device-sign-in-bootstrap-tests", itemAccessibility: .afterFirstUnlock, inMemory: true)
            client = SnippetsCloudNativeAuthClient(keychain: keychain, sessionConfiguration: Self.configuration())
        }

        static func configuration() -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriverProtocol.self]
            return configuration
        }

        func signIn(
            chooseAccount: Bool = false,
            chooseLibrary: @escaping ([SnippetsCloudLibraryChoice]) async throws -> UUID = { _ in
                XCTFail("No chooser is expected"); throw CancellationError()
            },
            authenticate: @escaping @MainActor (SnippetsCloudAccountKeySignInFlow) async throws -> Void
        ) async throws -> SnippetsCloudNativeAuthClient.SignInResult {
            try await client.signIn(serverURL: origin, existingSpaceID: nil, requiresStrongAuthentication: false,
                chooseAccount: chooseAccount, expectedStepUpTarget: nil, expectedPostAuthorizationTarget: nil,
                deviceSignInStore: bootstrapSecrets, chooseLibrary: chooseLibrary,
                authenticate: authenticate, validateStepUpTarget: {}, prepareCoordinatesCommit: { _ in },
                commitCoordinates: { _ in })
        }

        func completeDeviceSignIn() async throws -> SnippetsCloudNativeAuthClient.SignInResult {
            try await signIn { flow in
                let shown = try await flow.beginDeviceSignIn()
                try await flow.waitForDeviceApproval(expiresAt: shown.expiresAt, sleep: { _ in })
            }
        }
    }

    /// A signed-in device that already opens the library and approves another one.
    private final class ApproverFixture {
        static let accessToken = "approver-access-token-0123456789abcdef"
        let auth: Fixture
        let defaultsName = "DeviceApproval.\(UUID())"
        let defaults: UserDefaults
        let secrets: KeychainSecretStore
        let cloudKeys: SnippetsCloudKeyStore
        let selection: SyncBackendSelectionStore
        let bootstrap: SnippetsCloudAccountBootstrap

        init(mode: Driver.Mode = .normal) throws {
            auth = Fixture(mode: mode)
            defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            secrets = KeychainSecretStore(tier: .deviceOnly, service: "device-approval-bootstrap",
                itemAccessibility: .afterFirstUnlock, inMemory: true)
            let origin = auth.origin, serverID = auth.driver.serverID, spaceID = auth.driver.spaceID
            cloudKeys = SnippetsCloudKeyStore(keychain: .init(tier: .deviceOnly,
                service: "device-approval-root", itemAccessibility: .afterFirstUnlock, inMemory: true),
                coordinates: { .init(serverURL: origin, apiBaseURL: origin.appending(path: "v2"),
                    spaceID: spaceID, serverInstanceID: serverID, protocolMajor: 2) })
            selection = SyncBackendSelectionStore(defaults: defaults, keychain: auth.keychain,
                cloudKeys: cloudKeys, bootstrapSecrets: secrets, snippetsCloudEnabled: true,
                nativeAuthSessionConfiguration: Fixture.configuration())
            bootstrap = SnippetsCloudAccountBootstrap(selection: selection, secrets: secrets)
        }

        func prepareApprovingDevice() async throws {
            _ = try await auth.signIn { flow in try await flow.signIn(accountKey: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7") }
            try selection.selectSnippetsCloud(serverURL: auth.origin, spaceID: auth.driver.spaceID,
                serverInstanceID: auth.driver.serverID, accessToken: auth.driver.access)
            try cloudKeys.install(Data(repeating: 0x71, count: 64), serverURL: auth.origin,
                spaceID: auth.driver.spaceID, serverInstanceID: auth.driver.serverID, protocolMajor: 2)
            XCTAssertTrue(selection.hasCloudSession)
        }

        func deviceRequest(server: URL? = nil) throws -> LibraryKeyBootstrap.DeviceSignInRequest {
            let draft = LibraryKeyBootstrap.PairingDraft()
            return try .init(serverURL: server ?? auth.origin, requestID: auth.driver.requestID,
                nonce: draft.nonce, recipientPublicKey: draft.recipientPublicKey,
                expiresAtEpochSeconds: Int64(Date().timeIntervalSince1970) + 600)
        }

        func client() throws -> SnippetsCloudBootstrapClient {
            try SnippetsCloudBootstrapClient(baseURL: auth.origin, spaceID: auth.driver.spaceID,
                serverInstanceID: auth.driver.serverID, accessToken: { ApproverFixture.accessToken },
                session: URLSession(configuration: Fixture.configuration()))
        }

        func removeDefaults() { defaults.removePersistentDomain(forName: defaultsName) }
    }
}

private nonisolated final class Driver: @unchecked Sendable {
    enum Mode {
        case normal, noDeviceSignIn, claimPendingExtraMember, claimApprovedExtraMember
        case claimRateLimitedOnce, claimTransportFailures, claimExpired, claimRejected
        case claimUnknownSpace, foreignPairing
        case createdPairingAlreadyApproved, createdPairingWrongTag, approvalTransportFailureOnce, approvalConflict
    }
    struct Request {
        let method: String
        let path: String
        let body: [String: String]
        let json: [String: Any]
        let authorization: String?
    }

    let origin: URL
    let mode: Mode
    let pendingClaims: Int
    let serverID = UUID()
    let spaceID = UUID()
    let pairingID = UUID()
    let requestID = UUID()
    let accountID = UUID(uuidString: "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")!
    let pollToken = "sn_d_" + Data(repeating: 0x5A, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let access = String(repeating: "a", count: 43)
    let refresh = String(repeating: "r", count: 43)
    private let lock = NSLock()
    private var history: [Request] = []
    private var deviceKey: Data?
    private var deviceNonce: Data?
    var requests: [Request] { lock.withLock { history } }
    var claimPath: String { "/v2/auth/device-requests/\(requestID.uuidString.lowercased())/claim" }
    var approvalPath: String { "/v2/auth/device-requests/\(requestID.uuidString.lowercased())/approval" }
    var pairingsPath: String { "/v2/spaces/\(spaceID.uuidString.lowercased())/pairings" }
    var pairingPath: String { "\(pairingsPath)/\(pairingID.uuidString.lowercased())" }

    init(origin: URL, mode: Mode, pendingClaims: Int) {
        self.origin = origin
        self.mode = mode
        self.pendingClaims = pendingClaims
    }

    func setDeviceRecipient(key: Data, nonce: Data) {
        lock.withLock { deviceKey = key; deviceNonce = nonce }
    }

    func respond(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            data = collected
        }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let body = json.compactMapValues { $0 as? String }
        let previous = lock.withLock { () -> [Request] in
            let earlier = history
            history.append(.init(method: method, path: path, body: body, json: json,
                authorization: request.value(forHTTPHeaderField: "Authorization")))
            return earlier
        }
        let sameRoute = previous.filter { $0.path == path && $0.method == method }.count
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var value: [String: Any] = [:]
        let scope: [String: Any] = ["serverInstanceId": serverID.uuidString, "spaceId": spaceID.uuidString,
            "scopeBinding": String(repeating: "c", count: 43), "datasetGeneration": serverID.uuidString,
            "feedEpoch": spaceID.uuidString]
        let formatter = ISO8601DateFormatter()
        let expiresAt = formatter.string(from: Date().addingTimeInterval(600))
        switch (method, path) {
        case (_, "/.well-known/snippets-sync"):
            var capabilities = ["native-account-key-v1", "library-action-proof-v1", "pairing-v2",
                "offline-recovery-v1", "resource-session-revocation"]
            if mode != .noDeviceSignIn { capabilities.append("native-device-sign-in-v1") }
            value = ["protocolMajor": 2, "serverInstanceId": serverID.uuidString, "apiBase": origin.absoluteString + "/v2",
                "recordProfile": "snippets-wire-v1", "capabilities": capabilities,
                "limits": ["maxBlobBytes": 900_000, "maxRevisionBytes": 256, "maxBatchRecords": 50, "maxPageRecords": 50,
                    "maxRequestBytes": 16 * 1024 * 1024, "maxResponseBytes": 64 * 1024 * 1024, "maxKeyEnvelopeBytes": 4096, "maxPairingSeconds": 600],
                "nativeAuth": ["flow": "account_key", "createAccountEndpoint": origin.absoluteString + "/v2/auth/accounts",
                    "signInEndpoint": origin.absoluteString + "/v2/auth/sign-in",
                    "refreshEndpoint": origin.absoluteString + "/v2/auth/refresh", "revokeEndpoint": origin.absoluteString + "/v2/auth/revoke"]]
        case ("POST", "/v2/auth/sign-in"):
            value = token()
        case ("POST", "/v2/auth/device-requests"):
            lock.withLock {
                deviceKey = Data(base64Encoded: body["recipientPublicKey"] ?? "")
                deviceNonce = Data(base64Encoded: body["nonce"] ?? "")
            }
            value = ["requestId": requestID.uuidString.lowercased(), "pollToken": pollToken, "expiresAt": expiresAt]
        case ("POST", claimPath):
            guard body["pollToken"] == pollToken else { status = 404; value = ["code": "not_found"]; break }
            switch mode {
            case .claimRateLimitedOnce where sameRoute == 0:
                status = 429; headers["Retry-After"] = "7"; value = ["code": "rate_limited"]
            case .claimTransportFailures where sameRoute < 2:
                throw URLError(.timedOut)
            case .claimExpired:
                status = 410; value = ["code": "pairing_expired"]
            case .claimRejected:
                status = 409; value = ["code": "conflict"]
            case .claimPendingExtraMember:
                value = ["state": "pending", "expiresAt": expiresAt, "pairingId": pairingID.uuidString.lowercased()]
            default:
                // Claims before approval: rate limited answers once then approves; two
                // transport failures are followed by one pending answer, then approval.
                let pendingCount = switch mode {
                case .claimRateLimitedOnce: 1
                case .claimTransportFailures: 3
                default: pendingClaims
                }
                if sameRoute < pendingCount {
                    value = ["state": "pending", "expiresAt": expiresAt]
                } else {
                    value = ["state": "approved", "expiresAt": expiresAt,
                        "spaceId": (mode == .claimUnknownSpace ? UUID() : spaceID).uuidString.lowercased(),
                        "pairingId": pairingID.uuidString.lowercased(), "session": token()]
                    if mode == .claimApprovedExtraMember { value["accountKey"] = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7" }
                }
            }
        case ("GET", "/v2/spaces"):
            value = ["spaces": [["scope": scope, "role": "owner"]]]
        case ("GET", "/v2/spaces/\(spaceID.uuidString.lowercased())"):
            value = ["scope": scope, "role": "owner"]
        case ("POST", pairingsPath):
            value = ["scope": scope, "pairing": pairing(state: "pending",
                tagOverride: mode == .createdPairingWrongTag ? "AAAAAAAA" : nil)]
        case ("GET", pairingPath):
            value = ["scope": scope, "pairing": pairing(state: "approved",
                foreign: mode == .foreignPairing)]
        case ("POST", approvalPath):
            if mode == .approvalTransportFailureOnce && sameRoute == 0 { throw URLError(.networkConnectionLost) }
            if mode == .approvalConflict { status = 409; value = ["code": "conflict"]; break }
            status = 204
        case (_, "/v2/session"), ("POST", "/v2/auth/revoke"):
            status = 204
        default:
            throw URLError(.unsupportedURL)
        }
        return (status, headers, status == 204 ? Data() : try JSONSerialization.data(withJSONObject: value))
    }

    private func pairing(state: String, tagOverride: String? = nil, foreign: Bool = false) -> [String: Any] {
        let (key, nonce) = lock.withLock { (deviceKey ?? Data(), deviceNonce ?? Data()) }
        let servedNonce = foreign ? Data(repeating: 9, count: 32) : nonce
        return ["pairingId": pairingID.uuidString.lowercased(),
                "recipientPublicKey": key.base64EncodedString(),
                "nonce": servedNonce.base64EncodedString(),
                "authenticationTag": tagOverride ?? LibraryKeyBootstrap.confirmationCode(nonce: servedNonce, recipientPublicKey: key),
                "state": state,
                "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))]
    }

    private func token() -> [String: Any] {
        ["access_token": access, "refresh_token": refresh, "expires_in": 300, "token_type": "Bearer",
         "account": ["id": accountID.uuidString.lowercased()]]
    }
}

private nonisolated final class DriverProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var drivers: [String: Driver] = [:]
    static func register(_ driver: Driver, host: String) { lock.withLock { drivers[host] = driver } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".example.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let host = request.url?.host, let driver = Self.lock.withLock({ Self.drivers[host] }) else { throw URLError(.unsupportedURL) }
            let (status, headers, data) = try driver.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
