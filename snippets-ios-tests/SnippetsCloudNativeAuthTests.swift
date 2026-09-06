import Foundation
import Security
import XCTest
@testable import Snippets

@MainActor
final class SnippetsCloudNativeAuthTests: XCTestCase {
    private var previousSupportRoot: String?
    private var supportRoot: URL!

    override func setUpWithError() throws {
        previousSupportRoot = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        supportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAuth-\(UUID())")
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, supportRoot.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        if let previousSupportRoot {
            setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousSupportRoot, 1)
        } else { unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey) }
        try? FileManager.default.removeItem(at: supportRoot)
    }

    func testNativeSignInShowsFormBeforeNetworkingAndCommitsVerifiedAccount() async throws {
        let fixture = Fixture()
        let result = try await fixture.signIn { flow in
            XCTAssertTrue(fixture.driver.requests.isEmpty)
            let challenge = try await flow.sendCode(to: "  TESTER@example.test  ")
            XCTAssertEqual(challenge.email, "tester@example.test")
            XCTAssertEqual(challenge.codeLength, 6)
            try await flow.verify(code: "123456")
        }
        XCTAssertEqual(result.spaceID, fixture.driver.spaceID)
        XCTAssertEqual(fixture.client.verifiedProfile()?.email, "tester@example.test")
        XCTAssertEqual(fixture.client.verifiedProfile()?.subject, "account-fixture")
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        XCTAssertEqual(fixture.driver.requests.map(\.path), [
            "/.well-known/snippets-sync", "/v2/auth/email/start", "/v2/auth/email/verify", "/v2/spaces",
            "/v2/spaces/\(fixture.driver.spaceID.uuidString.lowercased())"])
    }

    func testIncorrectCodeCanBeRetriedWithoutReopeningOrResending() async throws {
        let fixture = Fixture(mode: .rejectFirstCode)
        _ = try await fixture.signIn { flow in
            _ = try await flow.sendCode(to: "tester@example.test")
            do { try await flow.verify(code: "000000"); XCTFail("Expected invalid code") }
            catch { XCTAssertEqual(error as? SnippetsCloudEmailSignInFailure, .invalidCode) }
            try await flow.verify(code: "123456")
        }
        XCTAssertEqual(fixture.driver.requests.filter { $0.path == "/v2/auth/email/start" }.count, 1)
        XCTAssertEqual(fixture.driver.requests.filter { $0.path == "/v2/auth/email/verify" }.count, 2)
    }

    func testDiscoveryCannotRedirectEmailToAnotherOrigin() async throws {
        let fixture = Fixture(mode: .foreignEndpoint)
        do {
            _ = try await fixture.signIn { flow in _ = try await flow.sendCode(to: "tester@example.test") }
            XCTFail("Expected discovery rejection")
        } catch {
            guard case SnippetsCloudNativeAuthClient.Failure.insecureServerProfile = error else {
                return XCTFail("Expected pinned endpoint rejection")
            }
        }
        XCTAssertEqual(fixture.driver.requests.map(\.path), ["/.well-known/snippets-sync"])
    }

    func testCancellationAfterVerificationRetiresCandidateAndKeepsNoSession() async throws {
        let fixture = Fixture()
        do {
            _ = try await fixture.signIn { flow in
                _ = try await flow.sendCode(to: "tester@example.test")
                try await flow.verify(code: "123456")
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        let revoked = fixture.driver.requests.filter { $0.path == "/v2/auth/revoke" }
        XCTAssertTrue(revoked.contains { $0.body["token"] == fixture.driver.refreshA && $0.body["tokenTypeHint"] == "refresh_token" })
        XCTAssertFalse(fixture.driver.requests.contains { $0.path == "/v2/spaces" })
    }

    func testRefreshRotationPreservesFamilyAndLogoutKeepsDurableEraseIntent() async throws {
        let fixture = Fixture()
        _ = try await fixture.completeSignIn()
        let token = try await fixture.client.freshAccessToken(expectedServerURL: fixture.origin,
            expectedServerInstanceID: fixture.driver.serverID, expectedProtocolMajor: 2, forceRefresh: true)
        XCTAssertEqual(token, fixture.driver.accessB)
        let refresh = try XCTUnwrap(fixture.driver.requests.first { $0.path == "/v2/auth/refresh" })
        XCTAssertEqual(refresh.body, ["refreshToken": fixture.driver.refreshA])
        XCTAssertFalse(fixture.driver.requests.contains { $0.path == "/v2/auth/revoke" && $0.body["tokenTypeHint"] == "refresh_token" })
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        try await fixture.client.revokeCurrentSession(expectedServerURL: fixture.origin)
        XCTAssertTrue(fixture.driver.requests.contains {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.driver.refreshB && $0.body["tokenTypeHint"] == "refresh_token"
        })
        // The selection/bootstrap owner records local erase after remote revocation.
        // Keep its durable authority until that handoff, and reject further data access.
        XCTAssertNotNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertNotNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthRevocationAccount))
        let requestsAfterRevocation = fixture.driver.requests.count
        do {
            _ = try await fixture.client.freshAccessToken(expectedServerURL: fixture.origin,
                expectedServerInstanceID: fixture.driver.serverID, expectedProtocolMajor: 2, forceRefresh: true)
            XCTFail("Revoked session must not access the data plane")
        } catch { }
        XCTAssertEqual(fixture.driver.requests.count, requestsAfterRevocation)
    }

    func testBootstrapDisconnectAfterRotationRelaunchesSignedOutAndKeepsLocalLibrary() async throws {
        let fixture = try DisconnectFixture()
        defer { fixture.removeDefaults() }
        try await fixture.prepareRotatedAccount()
        let retainedFile = SnippetStorageLocations.snippetsFileURL
        let retainedBytes = Data("[]\n".utf8)
        try retainedBytes.write(to: retainedFile)
        XCTAssertEqual(fixture.bootstrap.cloudSessionState, .connected)
        XCTAssertNotNil(try fixture.cloudKeys.materialForConfiguredAccount())

        try await fixture.bootstrap.signOutThisDevice()

        XCTAssertTrue(fixture.auth.driver.requests.contains {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.auth.driver.refreshB
                && $0.body["tokenTypeHint"] == "refresh_token"
        })
        try assertSignedOut(fixture.relaunchSelection(), fixture: fixture)
        let relaunchedClient = fixture.auth.makeClient()
        XCTAssertNil(relaunchedClient.verifiedProfile())
        let requestCount = fixture.auth.driver.requests.count
        do {
            _ = try await relaunchedClient.freshAccessToken(expectedServerURL: fixture.auth.origin,
                expectedServerInstanceID: fixture.auth.driver.serverID, expectedProtocolMajor: 2)
            XCTFail("Relaunch must require sign-in, not reuse a revoked credential")
        } catch { }
        XCTAssertEqual(fixture.auth.driver.requests.count, requestCount)
        XCTAssertEqual(try Data(contentsOf: retainedFile), retainedBytes)
    }

    func testFailedRemoteDisconnectKeepsDurableIntentAndStartupRetriesRotatedFamily() async throws {
        let fixture = try DisconnectFixture()
        defer { fixture.removeDefaults() }
        try await fixture.prepareRotatedAccount()
        fixture.auth.driver.setRefreshRevocationFailure(true)
        do { try await fixture.bootstrap.signOutThisDevice(); XCTFail("Expected remote revocation failure") }
        catch { }

        XCTAssertNotNil(try fixture.auth.keychain.loadItem(account: SyncBackendSelectionStore.oauthRevocationAccount))
        XCTAssertNil(try fixture.auth.keychain.loadItem(account: SyncBackendSelectionStore.pendingLocalEraseAccount))
        XCTAssertNotNil(try fixture.auth.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertNotNil(try fixture.cloudKeys.materialForConfiguredAccount())
        XCTAssertNotNil(fixture.selection.cloudCoordinates)
        let requestCount = fixture.auth.driver.requests.count
        do {
            _ = try await fixture.auth.makeClient().freshAccessToken(expectedServerURL: fixture.auth.origin,
                expectedServerInstanceID: fixture.auth.driver.serverID, expectedProtocolMajor: 2, forceRefresh: true)
            XCTFail("Pending logout must block refresh and data access")
        } catch { }
        XCTAssertEqual(fixture.auth.driver.requests.count, requestCount)

        fixture.auth.driver.setRefreshRevocationFailure(false)
        let relaunched = fixture.relaunchSelection()
        // Construction owns the retry task; the test never calls local erase itself.
        for _ in 0..<200 where relaunched.cloudCoordinates != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try assertSignedOut(relaunched, fixture: fixture)
        let refreshRevocations = fixture.auth.driver.requests.filter {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.auth.driver.refreshB
                && $0.body["tokenTypeHint"] == "refresh_token"
        }
        XCTAssertEqual(refreshRevocations.count, 2, "Startup must retry the same rotated family")
        XCTAssertEqual(fixture.auth.driver.requests.filter { $0.path == "/v2/auth/refresh" }.count, 1)
    }

    func testInterruptedLocalDisconnectErasesRootFirstAndFinishesAtRelaunchWithoutNetwork() async throws {
        let probe = NativeBootstrapEraseProbe()
        let fixture = try DisconnectFixture(bootstrapSecrets: probe.makeStore())
        defer { fixture.removeDefaults() }
        try await fixture.prepareRotatedAccount()
        do { try await fixture.bootstrap.signOutThisDevice(); XCTFail("Expected local erase failure") }
        catch { }

        XCTAssertNil(try fixture.cloudKeys.materialForConfiguredAccount(), "The library capability is erased before bootstrap journals")
        XCTAssertNotNil(try fixture.auth.keychain.loadItem(account: SyncBackendSelectionStore.pendingLocalEraseAccount))
        XCTAssertNotNil(try fixture.auth.keychain.loadItem(account: SyncBackendSelectionStore.oauthRevocationAccount))
        XCTAssertNotNil(try fixture.auth.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertNil(fixture.selection.cloudCoordinates, "Pending local erase must hide coordinates from the data plane")
        XCTAssertEqual(fixture.selection.provider, .snippetsCloud, "The saved provider changes only after secrets are erased")
        XCTAssertNotNil(try fixture.secrets.loadItem(account: SnippetsCloudAccountBootstrap.pairingAccount))

        let requestCount = fixture.auth.driver.requests.count
        probe.allowDeletion()
        let relaunched = fixture.relaunchSelection()
        try assertSignedOut(relaunched, fixture: fixture)
        await Task.yield()
        XCTAssertEqual(fixture.auth.driver.requests.count, requestCount, "Durable local erase must finish offline")
    }

    private func assertSignedOut(_ selection: SyncBackendSelectionStore, fixture: DisconnectFixture) throws {
        XCTAssertEqual(selection.provider, .iCloud)
        XCTAssertNil(selection.cloudCoordinates)
        XCTAssertFalse(selection.hasCloudSession)
        XCTAssertEqual(SnippetsCloudAccountBootstrap(selection: selection, secrets: fixture.secrets).cloudSessionState, .signedOut)
        XCTAssertNil(try fixture.cloudKeys.materialForConfiguredAccount())
        for account in [SyncBackendSelectionStore.oauthSessionAccount,
                        SyncBackendSelectionStore.oauthSessionReplacementAccount,
                        SyncBackendSelectionStore.oauthRevocationAccount,
                        SyncBackendSelectionStore.pendingLocalEraseAccount] {
            XCTAssertNil(try fixture.auth.keychain.loadItem(account: account))
        }
        for account in SnippetsCloudAccountBootstrap.bootstrapSecretAccounts {
            XCTAssertNil(try fixture.secrets.loadItem(account: account))
        }
    }

    func testRefreshRejectsAccountSubstitution() async throws {
        let fixture = Fixture(mode: .wrongRefreshAccount)
        _ = try await fixture.completeSignIn()
        do {
            _ = try await fixture.client.freshAccessToken(expectedServerURL: fixture.origin,
                expectedServerInstanceID: fixture.driver.serverID, expectedProtocolMajor: 2, forceRefresh: true)
            XCTFail("Expected identity mismatch")
        } catch {
            guard case SnippetsCloudNativeAuthClient.Failure.tokenExchangeFailed = error else {
                return XCTFail("Expected refresh rejection")
            }
        }
        XCTAssertEqual(fixture.client.verifiedProfile()?.subject, "account-fixture")
    }

    func testRateLimitProvidesBoundedRetryDelay() async throws {
        let fixture = Fixture(mode: .rateLimited)
        do {
            _ = try await fixture.signIn { flow in _ = try await flow.sendCode(to: "tester@example.test") }
            XCTFail("Expected rate limiting")
        } catch { XCTAssertEqual(error as? SnippetsCloudEmailSignInFailure, .rateLimited(90)) }
    }

    func testLegacySessionFailsClosedWithoutSendingCredentials() async throws {
        let fixture = Fixture()
        _ = try await fixture.completeSignIn()
        let data = try XCTUnwrap(fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 5
        try fixture.keychain.storeItem(JSONSerialization.data(withJSONObject: object), account: SyncBackendSelectionStore.oauthSessionAccount)
        let count = fixture.driver.requests.count
        do {
            _ = try await fixture.client.freshAccessToken(expectedServerURL: fixture.origin,
                expectedServerInstanceID: fixture.driver.serverID, expectedProtocolMajor: 2, forceRefresh: true)
            XCTFail("Expected old session rejection")
        } catch {}
        XCTAssertEqual(fixture.driver.requests.count, count)
    }

    func testOneSecondAccessTokenLifetimeIsAccepted() async throws {
        let fixture = Fixture(mode: .shortAccessTokenLifetime)
        let result = try await fixture.completeSignIn()
        XCTAssertEqual(result.spaceID, fixture.driver.spaceID)
        XCTAssertEqual(fixture.client.verifiedProfile()?.email, "tester@example.test")
    }

    func testRejectedIdentityIsJournaledBeforeFailureAndRevokedOnCancellation() async throws {
        let fixture = Fixture(mode: .wrongVerificationEmail)
        do {
            _ = try await fixture.signIn { flow in
                _ = try await flow.sendCode(to: "tester@example.test")
                do {
                    try await flow.verify(code: "123456")
                    XCTFail("Expected email mismatch")
                } catch {
                    guard case SnippetsCloudNativeAuthClient.Failure.authorizationMismatch = error else {
                        return XCTFail("Expected rejected identity")
                    }
                    XCTAssertNotNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
                    XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
                    throw CancellationError()
                }
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        XCTAssertTrue(fixture.driver.requests.contains {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.driver.refreshA
        })
    }

    func testFlowDrainsVerificationThatFinishesAfterCancellation() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var completed = false
        let flow = SnippetsCloudEmailSignInFlow(sendCode: { email in
            .init(email: email, expiresAt: Date().addingTimeInterval(600), resendAvailableAt: Date(), codeLength: 6)
        }, verifyCode: { _ in
            await withCheckedContinuation { continuation = $0 }
            completed = true
        })
        _ = try await flow.sendCode(to: "tester@example.test")
        let verification = Task { try await flow.verify(code: "123456") }
        while continuation == nil { await Task.yield() }
        flow.cancel()
        let drain = Task { await flow.cancelAndWait() }
        await Task.yield()
        XCTAssertFalse(completed)
        continuation?.resume()
        await drain.value
        XCTAssertTrue(completed)
        do { try await verification.value; XCTFail("Cancelled flow must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private final class Fixture {
        let driver: NativeAuthTestDriver
        let keychain: KeychainSecretStore
        let client: SnippetsCloudNativeAuthClient
        let origin: URL

        init(mode: NativeAuthTestDriver.Mode = .normal) {
            origin = URL(string: "https://\(UUID().uuidString.lowercased()).example.test")!
            driver = NativeAuthTestDriver(origin: origin, mode: mode)
            NativeAuthTestProtocol.register(driver, host: origin.host!)
            keychain = KeychainSecretStore(tier: .deviceOnly, service: "native-auth-tests", itemAccessibility: .afterFirstUnlock, inMemory: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NativeAuthTestProtocol.self]
            client = SnippetsCloudNativeAuthClient(keychain: keychain, sessionConfiguration: configuration)
        }

        func completeSignIn() async throws -> SnippetsCloudNativeAuthClient.SignInResult {
            try await signIn { flow in
                _ = try await flow.sendCode(to: "tester@example.test")
                try await flow.verify(code: "123456")
            }
        }

        func makeClient() -> SnippetsCloudNativeAuthClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NativeAuthTestProtocol.self]
            return SnippetsCloudNativeAuthClient(keychain: keychain, sessionConfiguration: configuration)
        }

        func signIn(authenticate: @escaping @MainActor @Sendable (SnippetsCloudEmailSignInFlow) async throws -> Void) async throws -> SnippetsCloudNativeAuthClient.SignInResult {
            try await client.signIn(serverURL: origin, existingSpaceID: nil, requiresStrongAuthentication: false,
                chooseAccount: false, expectedStepUpTarget: nil, expectedPostAuthorizationTarget: nil,
                chooseLibrary: { _ in XCTFail("One library should be automatic"); throw CancellationError() },
                authenticate: authenticate, validateStepUpTarget: {}, prepareCoordinatesCommit: { _ in }, commitCoordinates: { _ in })
        }
    }
    private final class DisconnectFixture {
        let auth = Fixture()
        let defaultsName = "NativeAuthDisconnect.\(UUID())"
        let defaults: UserDefaults
        let secrets: KeychainSecretStore
        let cloudKeys: SnippetsCloudKeyStore
        let selection: SyncBackendSelectionStore
        let sessionConfiguration: URLSessionConfiguration
        var bootstrap: SnippetsCloudAccountBootstrap { .init(selection: selection, secrets: secrets) }

        init(bootstrapSecrets: KeychainSecretStore? = nil) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            secrets = bootstrapSecrets ?? KeychainSecretStore(tier: .deviceOnly,
                service: "native-disconnect-bootstrap", itemAccessibility: .afterFirstUnlock, inMemory: true)
            let origin = auth.origin, serverID = auth.driver.serverID, spaceID = auth.driver.spaceID
            sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [NativeAuthTestProtocol.self]
            cloudKeys = SnippetsCloudKeyStore(keychain: .init(tier: .deviceOnly,
                service: "native-disconnect-root", itemAccessibility: .afterFirstUnlock, inMemory: true),
                coordinates: { .init(serverURL: origin, apiBaseURL: origin.appending(path: "v2"),
                    spaceID: spaceID, serverInstanceID: serverID, protocolMajor: 2) })
            selection = SyncBackendSelectionStore(defaults: defaults, keychain: auth.keychain,
                cloudKeys: cloudKeys, bootstrapSecrets: secrets, snippetsCloudEnabled: true,
                nativeAuthSessionConfiguration: sessionConfiguration)
            if bootstrapSecrets == nil {
                try secrets.storeItem(Data("pending pairing fixture".utf8), account: SnippetsCloudAccountBootstrap.pairingAccount)
            }
        }

        func prepareRotatedAccount() async throws {
            _ = try await auth.completeSignIn()
            try selection.selectSnippetsCloud(serverURL: auth.origin, spaceID: auth.driver.spaceID,
                serverInstanceID: auth.driver.serverID, accessToken: auth.driver.accessA)
            try cloudKeys.install(Data(repeating: 0x71, count: 64), serverURL: auth.origin,
                spaceID: auth.driver.spaceID, serverInstanceID: auth.driver.serverID, protocolMajor: 2)
            _ = try await auth.client.freshAccessToken(expectedServerURL: auth.origin,
                expectedServerInstanceID: auth.driver.serverID, expectedProtocolMajor: 2, forceRefresh: true)
        }

        func relaunchSelection() -> SyncBackendSelectionStore {
            .init(defaults: defaults, keychain: auth.keychain, cloudKeys: cloudKeys,
                bootstrapSecrets: secrets, snippetsCloudEnabled: true,
                nativeAuthSessionConfiguration: sessionConfiguration)
        }

        func removeDefaults() { defaults.removePersistentDomain(forName: defaultsName) }
    }
}

private nonisolated final class NativeAuthTestDriver: @unchecked Sendable {
    enum Mode { case normal, rejectFirstCode, foreignEndpoint, wrongRefreshAccount, rateLimited, shortAccessTokenLifetime, wrongVerificationEmail }
    struct Request { let path: String; let body: [String: String] }
    let origin: URL
    let mode: Mode
    let serverID = UUID()
    let spaceID = UUID()
    let accessA = String(repeating: "a", count: 43)
    let refreshA = String(repeating: "r", count: 43)
    let accessB = String(repeating: "b", count: 43)
    let refreshB = String(repeating: "s", count: 43)
    private let lock = NSLock()
    private var history: [Request] = []
    private var refreshRevocationFails = false
    var requests: [Request] { lock.withLock { history } }
    func setRefreshRevocationFailure(_ value: Bool) { lock.withLock { refreshRevocationFails = value } }

    init(origin: URL, mode: Mode) { self.origin = origin; self.mode = mode }

    func respond(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let path = request.url!.path
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
        let body = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        lock.withLock { history.append(.init(path: path, body: body)) }
        var status = 200
        var headers = ["Content-Type": "application/json"]
        let value: [String: Any]
        let scope: [String: Any] = ["serverInstanceId": serverID.uuidString, "spaceId": spaceID.uuidString,
            "scopeBinding": String(repeating: "c", count: 43), "datasetGeneration": serverID.uuidString, "feedEpoch": spaceID.uuidString]
        let space: [String: Any] = ["scope": scope, "role": "owner"]
        switch path {
        case "/.well-known/snippets-sync":
            value = ["protocolMajor": 2, "serverInstanceId": serverID.uuidString, "apiBase": origin.absoluteString + "/v2",
                "recordProfile": "snippets-wire-v1",
                "capabilities": ["native-email-code-v1", "library-action-proof-v1", "pairing-v2", "offline-recovery-v1", "resource-session-revocation"],
                "limits": ["maxBlobBytes": 900_000, "maxRevisionBytes": 256, "maxBatchRecords": 50, "maxPageRecords": 50,
                    "maxRequestBytes": 16 * 1024 * 1024, "maxResponseBytes": 64 * 1024 * 1024, "maxKeyEnvelopeBytes": 4096, "maxPairingSeconds": 600],
                "nativeAuth": ["flow": "email_code", "startEndpoint": mode == .foreignEndpoint ? "https://foreign.example.test/v2/auth/email/start" : origin.absoluteString + "/v2/auth/email/start",
                    "verifyEndpoint": origin.absoluteString + "/v2/auth/email/verify", "refreshEndpoint": origin.absoluteString + "/v2/auth/refresh", "revokeEndpoint": origin.absoluteString + "/v2/auth/revoke"]]
        case "/v2/auth/email/start":
            if mode == .rateLimited {
                status = 429; headers["Retry-After"] = "90"; value = ["code": "rate_limited"]
            } else { value = ["challengeId": String(repeating: "q", count: 43), "expiresIn": 600, "resendAfter": 60, "codeLength": 6] }
        case "/v2/auth/email/verify":
            if mode == .rejectFirstCode && requests.filter({ $0.path == path }).count == 1 {
                status = 401; value = ["code": "invalid_code"]
            } else { value = token(access: accessA, refresh: refreshA, account: "account-fixture") }
        case "/v2/auth/refresh":
            value = token(access: accessB, refresh: refreshB, account: mode == .wrongRefreshAccount ? "different-account" : "account-fixture")
        case "/v2/spaces": value = ["spaces": [space]]
        case "/v2/spaces/\(spaceID.uuidString.lowercased())": value = space
        case "/v2/auth/revoke" where body["tokenTypeHint"] == "refresh_token" && lock.withLock({ refreshRevocationFails }):
            status = 503; value = ["code": "unavailable"]
        case "/v2/session", "/v2/auth/revoke": status = 204; value = [:]
        default: throw URLError(.unsupportedURL)
        }
        return (status, headers, status == 204 ? Data() : try JSONSerialization.data(withJSONObject: value))
    }

    private func token(access: String, refresh: String, account: String) -> [String: Any] {
        ["access_token": access, "refresh_token": refresh, "expires_in": mode == .shortAccessTokenLifetime ? 1 : 300, "token_type": "Bearer",
         "account": ["id": account, "email": mode == .wrongVerificationEmail ? "other@example.test" : "tester@example.test"]]
    }
}

/// Only a pairing journal exists. Deletion initially fails without touching any
/// Security.framework item; the next simulated process receives the same bytes.
private nonisolated final class NativeBootstrapEraseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: Data? = Data("pending pairing fixture".utf8)
    private var deletionAllowed = false
    func allowDeletion() { lock.withLock { deletionAllowed = true } }

    @MainActor
    func makeStore() -> KeychainSecretStore {
        let pairingAccount = SnippetsCloudAccountBootstrap.pairingAccount
        return .init(tier: .deviceOnly, service: "native-disconnect-failing-bootstrap",
            itemAccessibility: .afterFirstUnlock, keychainOperations: .init(
                copyMatching: { [self] query, result in
                    let attributes = query as NSDictionary
                    return lock.withLock {
                        guard attributes[kSecAttrAccount] as? String == pairingAccount,
                              let pairing else { return errSecItemNotFound }
                        if attributes[kSecReturnAttributes] as? Bool == true {
                            result?.pointee = [kSecValueData as String: pairing,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
                        } else { result?.pointee = pairing as CFData }
                        return errSecSuccess
                    }
                }, update: { _, _ in errSecItemNotFound }, add: { _, _ in errSecParam },
                delete: { [self] query in
                    guard (query as NSDictionary)[kSecAttrAccount] as? String == pairingAccount else { return errSecItemNotFound }
                    return lock.withLock {
                        guard deletionAllowed else { return errSecInteractionNotAllowed }
                        pairing = nil
                        return errSecSuccess
                    }
                }))
    }
}

private nonisolated final class NativeAuthTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var drivers: [String: NativeAuthTestDriver] = [:]
    static func register(_ driver: NativeAuthTestDriver, host: String) { lock.withLock { drivers[host] = driver } }
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
