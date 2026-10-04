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

    func testCreateAccountShowsFormBeforeNetworkingJournalsGrantAndCommitsKey() async throws {
        let fixture = Fixture()
        var journalAtKeyPresentation: Data?
        let result = try await fixture.signIn { flow in
            XCTAssertTrue(fixture.driver.requests.isEmpty)
            let key = try await flow.createAccount()
            XCTAssertEqual(key.canonical, fixture.driver.accountKey)
            XCTAssertEqual(key.displayForm, "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7")
            // The grant is journaled before the save screen appears, and it is not yet
            // the active session until the user acknowledges the key.
            journalAtKeyPresentation = try fixture.keychain.loadItem(
                account: SyncBackendSelectionStore.oauthSessionReplacementAccount)
            XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        }
        let journal = try XCTUnwrap(journalAtKeyPresentation)
        XCTAssertFalse(String(decoding: journal, as: UTF8.self).contains(fixture.driver.accountKey),
            "Credential journals carry revocation authority only, never the account key")
        XCTAssertEqual(result.spaceID, fixture.driver.spaceID)
        XCTAssertEqual(fixture.client.storedAccountID(), fixture.driver.accountID)
        XCTAssertEqual(try fixture.client.storedAccountKey()?.canonical, fixture.driver.accountKey)
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        XCTAssertEqual(fixture.driver.requests.map(\.path), [
            "/.well-known/snippets-sync", "/v2/auth/accounts", "/v2/spaces",
            "/v2/spaces/\(fixture.driver.spaceID.uuidString.lowercased())"])
        let create = try XCTUnwrap(fixture.driver.requests.first { $0.path == "/v2/auth/accounts" })
        XCTAssertEqual(create.bodyBytes, 0, "Account creation is a bodyless POST")
        XCTAssertNil(create.contentType)
    }

    func testSignInNormalizesTypedKeyAndSendsOnlyCanonicalForm() async throws {
        let fixture = Fixture()
        _ = try await fixture.signIn { flow in
            XCTAssertTrue(fixture.driver.requests.isEmpty)
            try await flow.signIn(accountKey: " 7kqf 9m2x-r4td-h8wb-zn3c-p6ye-iaq7 ")
        }
        let signIn = try XCTUnwrap(fixture.driver.requests.first { $0.path == "/v2/auth/sign-in" })
        XCTAssertEqual(signIn.body, ["accountKey": "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"])
        XCTAssertEqual(signIn.contentType, "application/json")
        XCTAssertEqual(fixture.client.storedAccountID(), fixture.driver.accountID)
        XCTAssertEqual(try fixture.client.storedAccountKey()?.canonical, "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7")
        XCTAssertFalse(fixture.driver.requests.contains { $0.path == "/v2/auth/accounts" })
    }

    func testLocallyInvalidKeyIsNeverSentAndLeavesNoNetworkTrace() async throws {
        let fixture = Fixture()
        do {
            _ = try await fixture.signIn { flow in
                for typo in ["7KQF9M2XR4TDH8WBZN3CP6YE1AQ8", "7KQF9M2XR4TDH8WBZN3CP6YE1AQU",
                             String(repeating: " ", count: 40) + "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"] {
                    do {
                        try await flow.signIn(accountKey: typo)
                        XCTFail("Expected a local typing error")
                    } catch {
                        XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .invalidAccountKey)
                        XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                            "This isn’t a valid account key. Check it for typos.")
                    }
                }
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.driver.requests.isEmpty)
    }

    func testRejectedKeyShowsServerCopyAndCanBeRetriedWithoutRediscovery() async throws {
        let fixture = Fixture(mode: .rejectFirstKey)
        _ = try await fixture.signIn { flow in
            do {
                try await flow.signIn(accountKey: fixture.driver.accountKey)
                XCTFail("Expected rejected key")
            } catch {
                XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .accountKeyNotAccepted)
                XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                    "That account key wasn’t accepted. Check it and try again.")
            }
            try await flow.signIn(accountKey: fixture.driver.accountKey)
        }
        XCTAssertEqual(fixture.driver.requests.filter { $0.path == "/.well-known/snippets-sync" }.count, 1)
        XCTAssertEqual(fixture.driver.requests.filter { $0.path == "/v2/auth/sign-in" }.count, 2)
    }

    func testDiscoveryCannotRedirectSignInOrCreationToAnotherOrigin() async throws {
        for mode in [NativeAuthTestDriver.Mode.foreignSignInEndpoint, .foreignCreateEndpoint,
                     .emailFlowAndCapability, .legacyEmailDiscovery] {
            let fixture = Fixture(mode: mode)
            do {
                _ = try await fixture.signIn { flow in
                    if mode == .foreignCreateEndpoint {
                        _ = try await flow.createAccount()
                    } else {
                        try await flow.signIn(accountKey: fixture.driver.accountKey)
                    }
                }
                XCTFail("Expected discovery rejection")
            } catch {
                switch (mode, error) {
                case (.legacyEmailDiscovery, SnippetsCloudNativeAuthClient.Failure.discoveryUnavailable):
                    // An email-era document has no account-key endpoints to decode.
                    break
                case (.foreignSignInEndpoint, SnippetsCloudNativeAuthClient.Failure.insecureServerProfile),
                     (.foreignCreateEndpoint, SnippetsCloudNativeAuthClient.Failure.insecureServerProfile),
                     (.emailFlowAndCapability, SnippetsCloudNativeAuthClient.Failure.insecureServerProfile):
                    break
                default:
                    XCTFail("Unexpected discovery result for \(mode): \(error)")
                }
            }
            XCTAssertEqual(fixture.driver.requests.map(\.path), ["/.well-known/snippets-sync"])
        }
    }

    func testCancellationOnSaveScreenRetiresCreatedCandidateAndKeepsNoSession() async throws {
        let fixture = Fixture()
        do {
            _ = try await fixture.signIn { flow in
                _ = try await flow.createAccount()
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertNil(try fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        XCTAssertNil(fixture.client.storedAccountID())
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
        let relaunchedSelection = fixture.relaunchSelection()
        try assertSignedOut(relaunchedSelection, fixture: fixture)
        let relaunchedClient = fixture.auth.makeClient()
        XCTAssertNil(relaunchedClient.storedAccountID())
        XCTAssertNil(try relaunchedClient.storedAccountKey(), "The key is removed with the session")
        XCTAssertNil(relaunchedSelection.cloudAccountIdentifier)
        XCTAssertThrowsError(try relaunchedSelection.cloudAccountKeyAfterLocalAuthentication())
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

    // MARK: - Deferred (iOS) startup credential preflight

    func testDeferredStartupResumesUnfinishedSignOutAfterOffMainLineagePreflight() async throws {
        let probe = CredentialKeychainProbe()
        defer { probe.release() }
        let fixture = try DisconnectFixture(credentialStore: probe.keychain())
        defer { fixture.removeDefaults() }
        try await fixture.prepareRotatedAccount()
        fixture.auth.driver.setRefreshRevocationFailure(true)
        do { try await fixture.bootstrap.signOutThisDevice(); XCTFail("Expected remote revocation failure") }
        catch { }
        XCTAssertNotNil(probe.storedValue(for: SyncBackendSelectionStore.oauthRevocationAccount))
        XCTAssertNil(probe.storedValue(for: SyncBackendSelectionStore.pendingLocalEraseAccount))
        fixture.auth.driver.setRefreshRevocationFailure(false)
        let requestCount = fixture.auth.driver.requests.count

        // The revocation journal is the preflight's last read: holding it keeps the whole
        // snapshot, and the credential mutation gate around it, in flight.
        probe.clearLog()
        probe.hold([SyncBackendSelectionStore.oauthRevocationAccount])
        let relaunched = fixture.relaunchSelection(defersCredentialRecovery: true)
        let entered = await waitUntil { probe.hasEnteredHeldRead }
        XCTAssertTrue(entered, "Snippets Cloud startup must inspect the credential lineage")
        // Construction returned and MainActor keeps running while Security.framework is
        // stuck; nothing is revoked or erased before the lineage is known.
        XCTAssertEqual(probe.mainThreadLineageReads, [])
        XCTAssertEqual(fixture.auth.driver.requests.count, requestCount)
        XCTAssertEqual(relaunched.provider, .snippetsCloud)
        XCTAssertNotNil(probe.storedValue(for: SyncBackendSelectionStore.oauthSessionAccount))

        probe.release()
        let erased = await waitUntil {
            relaunched.provider == .iCloud
                && probe.storedValue(for: SyncBackendSelectionStore.pendingLocalEraseAccount) == nil
        }
        XCTAssertTrue(erased, "Startup must still resume the interrupted sign-out")
        try assertSignedOut(relaunched, fixture: fixture)
        let refreshRevocations = fixture.auth.driver.requests.filter {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.auth.driver.refreshB
                && $0.body["tokenTypeHint"] == "refresh_token"
        }
        XCTAssertEqual(refreshRevocations.count, 2, "Startup must retry the same rotated family")
        // Journal-first erase: the durable marker precedes credential deletion and is
        // removed last.
        let log = probe.operations
        let markerWritten = try XCTUnwrap(log.firstIndex {
            $0.kind == .write && $0.account == SyncBackendSelectionStore.pendingLocalEraseAccount
        })
        let sessionDeleted = try XCTUnwrap(log.firstIndex {
            $0.kind == .delete && $0.account == SyncBackendSelectionStore.oauthSessionAccount
        })
        let markerDeleted = try XCTUnwrap(log.lastIndex {
            $0.kind == .delete && $0.account == SyncBackendSelectionStore.pendingLocalEraseAccount
        })
        XCTAssertLessThan(markerWritten, sessionDeleted)
        XCTAssertLessThan(sessionDeleted, markerDeleted)
    }

    func testDeferredStartupRetiresUnfinishedReplacementAfterOffMainLineagePreflight() async throws {
        let probe = CredentialKeychainProbe()
        defer { probe.release() }
        let fixture = try DisconnectFixture(credentialStore: probe.keychain())
        defer { fixture.removeDefaults() }
        // Capture the device state of a process that died after the first grant was
        // journaled but before AUTH_SESSION was committed.
        var journalAtCrash: Data?
        do {
            _ = try await fixture.auth.signIn { flow in
                _ = try await flow.createAccount()
                journalAtCrash = probe.storedValue(
                    for: SyncBackendSelectionStore.oauthSessionReplacementAccount)
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        try fixture.auth.keychain.storeItem(
            try XCTUnwrap(journalAtCrash),
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount)
        XCTAssertNil(probe.storedValue(for: SyncBackendSelectionStore.oauthSessionAccount))
        let requestCount = fixture.auth.driver.requests.count

        probe.clearLog()
        probe.hold([SyncBackendSelectionStore.oauthSessionReplacementAccount])
        let relaunched = fixture.relaunchSelection(defersCredentialRecovery: true)
        let entered = await waitUntil { probe.hasEnteredHeldRead }
        XCTAssertTrue(entered, "Snippets Cloud startup must inspect the credential lineage")
        XCTAssertEqual(probe.mainThreadLineageReads, [])
        XCTAssertEqual(fixture.auth.driver.requests.count, requestCount)
        XCTAssertNotNil(probe.storedValue(for: SyncBackendSelectionStore.oauthSessionReplacementAccount))

        probe.release()
        let retired = await waitUntil {
            probe.storedValue(for: SyncBackendSelectionStore.oauthSessionReplacementAccount) == nil
        }
        XCTAssertTrue(retired, "Startup must still retire the superseded grant")
        let startupRequests = fixture.auth.driver.requests.dropFirst(requestCount)
        XCTAssertTrue(startupRequests.contains { $0.path == "/v2/session" })
        XCTAssertTrue(startupRequests.contains {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.auth.driver.refreshA
                && $0.body["tokenTypeHint"] == "refresh_token"
        })
        XCTAssertNil(probe.storedValue(for: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertEqual(relaunched.provider, .iCloud)
    }

    func testSignOutDuringDeferredStartupPreflightIsSerializedBehindLineageSnapshot() async throws {
        let probe = CredentialKeychainProbe()
        defer { probe.release() }
        let fixture = try DisconnectFixture(credentialStore: probe.keychain())
        defer { fixture.removeDefaults() }
        try await fixture.prepareRotatedAccount()
        func revocationRequests() -> Int {
            fixture.auth.driver.requests.filter {
                $0.path == "/v2/auth/revoke" || $0.path == "/v2/session"
            }.count
        }
        let revocationsBefore = revocationRequests()

        probe.clearLog()
        probe.hold([SyncBackendSelectionStore.oauthRevocationAccount])
        let relaunched = fixture.relaunchSelection(defersCredentialRecovery: true)
        let entered = await waitUntil { probe.hasEnteredHeldRead }
        XCTAssertTrue(entered)

        let bootstrap = SnippetsCloudAccountBootstrap(selection: relaunched, secrets: fixture.secrets)
        let signOut = Task { try await bootstrap.signOutThisDevice() }
        // The last unserialized step before logout takes the gate is the coordinates
        // check, which reads the local-erase marker on MainActor.
        let reachedGate = await waitUntil {
            probe.operations.filter {
                $0.onMainThread && $0.account == SyncBackendSelectionStore.pendingLocalEraseAccount
            }.count >= 2
        }
        XCTAssertTrue(reachedGate)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(probe.operations.contains {
            $0.kind != .read && $0.account == SyncBackendSelectionStore.oauthRevocationAccount
        }, "Logout must not publish revocation authority while the preflight snapshot is open")
        XCTAssertEqual(revocationRequests(), revocationsBefore)
        XCTAssertEqual(probe.mainThreadLineageReads, [])

        probe.release()
        try await signOut.value
        try assertSignedOut(relaunched, fixture: fixture)
        let log = probe.operations
        let snapshotCompleted = try XCTUnwrap(log.firstIndex {
            $0.kind == .read && !$0.onMainThread
                && $0.account == SyncBackendSelectionStore.oauthRevocationAccount
        })
        let journalWritten = try XCTUnwrap(log.firstIndex {
            $0.kind == .write && $0.account == SyncBackendSelectionStore.oauthRevocationAccount
        })
        XCTAssertLessThan(snapshotCompleted, journalWritten)
        // The preflight saw an ordinary session, so startup adds no second revocation.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.auth.driver.requests.filter {
            $0.path == "/v2/auth/revoke" && $0.body["token"] == fixture.auth.driver.refreshB
                && $0.body["tokenTypeHint"] == "refresh_token"
        }.count, 1)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
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
        XCTAssertEqual(fixture.client.storedAccountID(), fixture.driver.accountID)
    }

    func testRateLimitProvidesBoundedRetryDelay() async throws {
        let fixture = Fixture(mode: .rateLimited)
        do {
            _ = try await fixture.signIn { flow in _ = try await flow.createAccount() }
            XCTFail("Expected rate limiting")
        } catch { XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .rateLimited(90)) }
    }

    func testEmailEraSessionFailsClosedWithoutSendingCredentials() async throws {
        let fixture = Fixture()
        _ = try await fixture.completeSignIn()
        let data = try XCTUnwrap(fixture.keychain.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Schema 6 stored an email profile and no account key. Treat it like any other
        // unreadable session: no refresh, no data plane, sign in again.
        object["schemaVersion"] = 6
        object["profile"] = ["issuer": fixture.origin.absoluteString, "subject": fixture.driver.accountID.uuidString]
        object.removeValue(forKey: "accountKey")
        try fixture.keychain.storeItem(JSONSerialization.data(withJSONObject: object), account: SyncBackendSelectionStore.oauthSessionAccount)
        let count = fixture.driver.requests.count
        XCTAssertNil(fixture.client.storedAccountID())
        XCTAssertThrowsError(try fixture.client.storedAccountKey())
        XCTAssertThrowsError(try fixture.client.inspectCredentialLineage())
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
        XCTAssertEqual(fixture.client.storedAccountID(), fixture.driver.accountID)
    }

    func testMalformedCreatedKeyOrAccountIsJournaledBeforeFailureAndRevokedOnCancellation() async throws {
        for mode in [NativeAuthTestDriver.Mode.malformedCreatedKey, .malformedAccountID] {
            let fixture = Fixture(mode: mode)
            do {
                _ = try await fixture.signIn { flow in
                    do {
                        _ = try await flow.createAccount()
                        XCTFail("Expected rejected creation response")
                    } catch {
                        if mode == .malformedCreatedKey {
                            XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .invalidResponse)
                        } else {
                            guard case SnippetsCloudNativeAuthClient.Failure.tokenExchangeFailed = error else {
                                return XCTFail("Expected rejected account metadata")
                            }
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
    }

    func testFlowDrainsSignInThatFinishesAfterCancellation() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var completed = false
        var created = 0
        let flow = SnippetsCloudAccountKeySignInFlow(createAccount: {
            created += 1
            throw SnippetsCloudAccountKeySignInFailure.unavailable
        }, signIn: { _ in
            await withCheckedContinuation { continuation = $0 }
            completed = true
        })
        let signIn = Task { try await flow.signIn(accountKey: "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7") }
        while continuation == nil { await Task.yield() }
        do {
            _ = try await flow.createAccount()
            XCTFail("A second request cannot overlap the first")
        } catch { XCTAssertEqual(error as? SnippetsCloudAccountKeySignInFailure, .rateLimited(1)) }
        XCTAssertEqual(created, 0)
        flow.cancel()
        let drain = Task { await flow.cancelAndWait() }
        await Task.yield()
        XCTAssertFalse(completed)
        continuation?.resume()
        await drain.value
        XCTAssertTrue(completed)
        do { try await signIn.value; XCTFail("Cancelled flow must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await flow.signIn(accountKey: "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"); XCTFail("Cancelled flow is finished") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSignedInSelectionShowsShortAccountIDAndKeepsKeyOutOfDefaults() async throws {
        let fixture = try DisconnectFixture()
        defer { fixture.removeDefaults() }
        try await fixture.prepareRotatedAccount()
        XCTAssertEqual(fixture.selection.cloudAccountIdentifier, "E621-E1F8")
        XCTAssertEqual(try fixture.selection.cloudAccountKeyAfterLocalAuthentication().canonical,
            fixture.auth.driver.accountKey)
        let defaults = String(describing: fixture.defaults.dictionaryRepresentation())
        XCTAssertFalse(defaults.contains(fixture.auth.driver.accountKey))
        XCTAssertFalse(defaults.contains("7KQF-9M2X"))
        for account in [SyncBackendSelectionStore.oauthSessionReplacementAccount,
                        SyncBackendSelectionStore.oauthRevocationAccount] {
            if let data = try fixture.auth.keychain.loadItem(account: account) {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(fixture.auth.driver.accountKey))
            }
        }
    }

    private final class Fixture {
        let driver: NativeAuthTestDriver
        let keychain: KeychainSecretStore
        let client: SnippetsCloudNativeAuthClient
        let origin: URL

        init(mode: NativeAuthTestDriver.Mode = .normal, keychain credentialStore: KeychainSecretStore? = nil) {
            origin = URL(string: "https://\(UUID().uuidString.lowercased()).example.test")!
            driver = NativeAuthTestDriver(origin: origin, mode: mode)
            NativeAuthTestProtocol.register(driver, host: origin.host!)
            keychain = credentialStore ?? KeychainSecretStore(tier: .deviceOnly, service: "native-auth-tests", itemAccessibility: .afterFirstUnlock, inMemory: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NativeAuthTestProtocol.self]
            client = SnippetsCloudNativeAuthClient(keychain: keychain, sessionConfiguration: configuration)
        }

        func completeSignIn() async throws -> SnippetsCloudNativeAuthClient.SignInResult {
            try await signIn { flow in
                try await flow.signIn(accountKey: "7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7")
            }
        }

        func makeClient() -> SnippetsCloudNativeAuthClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NativeAuthTestProtocol.self]
            return SnippetsCloudNativeAuthClient(keychain: keychain, sessionConfiguration: configuration)
        }

        func signIn(authenticate: @escaping @MainActor @Sendable (SnippetsCloudAccountKeySignInFlow) async throws -> Void) async throws -> SnippetsCloudNativeAuthClient.SignInResult {
            try await client.signIn(serverURL: origin, existingSpaceID: nil, requiresStrongAuthentication: false,
                chooseAccount: false, expectedStepUpTarget: nil, expectedPostAuthorizationTarget: nil,
                chooseLibrary: { _ in XCTFail("One library should be automatic"); throw CancellationError() },
                authenticate: authenticate, validateStepUpTarget: {}, prepareCoordinatesCommit: { _ in }, commitCoordinates: { _ in })
        }
    }
    private final class DisconnectFixture {
        let auth: Fixture
        let defaultsName = "NativeAuthDisconnect.\(UUID())"
        let defaults: UserDefaults
        let secrets: KeychainSecretStore
        let cloudKeys: SnippetsCloudKeyStore
        let selection: SyncBackendSelectionStore
        let sessionConfiguration: URLSessionConfiguration
        var bootstrap: SnippetsCloudAccountBootstrap { .init(selection: selection, secrets: secrets) }

        init(bootstrapSecrets: KeychainSecretStore? = nil, credentialStore: KeychainSecretStore? = nil) throws {
            auth = Fixture(keychain: credentialStore)
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

        func relaunchSelection(defersCredentialRecovery: Bool = false) -> SyncBackendSelectionStore {
            .init(defaults: defaults, keychain: auth.keychain, cloudKeys: cloudKeys,
                bootstrapSecrets: secrets, snippetsCloudEnabled: true,
                defersCredentialRecovery: defersCredentialRecovery,
                nativeAuthSessionConfiguration: sessionConfiguration)
        }

        func removeDefaults() { defaults.removePersistentDomain(forName: defaultsName) }
    }
}

private nonisolated final class NativeAuthTestDriver: @unchecked Sendable {
    enum Mode {
        case normal, rejectFirstKey, foreignSignInEndpoint, foreignCreateEndpoint, emailFlowAndCapability
        case legacyEmailDiscovery
        case wrongRefreshAccount, rateLimited, shortAccessTokenLifetime, malformedCreatedKey, malformedAccountID
    }
    struct Request { let path: String; let body: [String: String]; let bodyBytes: Int; let contentType: String? }
    let origin: URL
    let mode: Mode
    let serverID = UUID()
    let spaceID = UUID()
    /// ADR 0006 test vector. A fixture only; real keys are never persisted in tests.
    let accountKey = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"
    let accountID = UUID(uuidString: "e621e1f8-c36c-495a-93fc-0c247a3e6e5f")!
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
        lock.withLock { history.append(.init(path: path, body: body, bodyBytes: data?.count ?? 0,
            contentType: request.value(forHTTPHeaderField: "Content-Type"))) }
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
                "capabilities": [[.legacyEmailDiscovery, .emailFlowAndCapability].contains(mode)
                        ? "native-email-code-v1" : "native-account-key-v1",
                    "library-action-proof-v1", "pairing-v2", "offline-recovery-v1", "resource-session-revocation"],
                "limits": ["maxBlobBytes": 900_000, "maxRevisionBytes": 256, "maxBatchRecords": 50, "maxPageRecords": 50,
                    "maxRequestBytes": 16 * 1024 * 1024, "maxResponseBytes": 64 * 1024 * 1024, "maxKeyEnvelopeBytes": 4096, "maxPairingSeconds": 600],
                "nativeAuth": mode == .legacyEmailDiscovery
                    ? ["flow": "email_code", "startEndpoint": origin.absoluteString + "/v2/auth/email/start",
                       "verifyEndpoint": origin.absoluteString + "/v2/auth/email/verify",
                       "refreshEndpoint": origin.absoluteString + "/v2/auth/refresh", "revokeEndpoint": origin.absoluteString + "/v2/auth/revoke"]
                    : ["flow": mode == .emailFlowAndCapability ? "email_code" : "account_key",
                       "createAccountEndpoint": mode == .foreignCreateEndpoint ? "https://foreign.example.test/v2/auth/accounts" : origin.absoluteString + "/v2/auth/accounts",
                       "signInEndpoint": mode == .foreignSignInEndpoint ? "https://foreign.example.test/v2/auth/sign-in" : origin.absoluteString + "/v2/auth/sign-in",
                       "refreshEndpoint": origin.absoluteString + "/v2/auth/refresh", "revokeEndpoint": origin.absoluteString + "/v2/auth/revoke"]]
        case "/v2/auth/accounts":
            if mode == .rateLimited {
                status = 429; headers["Retry-After"] = "90"; value = ["code": "rate_limited"]
            } else {
                value = ["accountKey": mode == .malformedCreatedKey ? "7KQF9M2XR4TDH8WBZN3CP6YE1AQ8" : accountKey,
                         "session": token(access: accessA, refresh: refreshA,
                            account: mode == .malformedAccountID ? "account-fixture" : accountID.uuidString.lowercased())]
            }
        case "/v2/auth/sign-in":
            if mode == .rejectFirstKey && requests.filter({ $0.path == path }).count == 1 {
                status = 401; value = ["code": "invalid_account_key"]
            } else if body["accountKey"] != accountKey {
                status = 401; value = ["code": "invalid_account_key"]
            } else { value = token(access: accessA, refresh: refreshA, account: accountID.uuidString.lowercased()) }
        case "/v2/auth/refresh":
            value = token(access: accessB, refresh: refreshB,
                account: mode == .wrongRefreshAccount ? UUID().uuidString.lowercased() : accountID.uuidString.lowercased())
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
         "account": ["id": account]]
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
