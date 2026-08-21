import CryptoKit
import Foundation
import Security
import XCTest

@testable import Snippets

/// Query-level tests for the different availability promises made by keychain items.
///
/// These use the same injected operations seam for the shared key store and the local
/// CKSyncEngine checkpoint key. No test reaches or mutates the simulator's real
/// keychain, and assertions inspect the attributes Security.framework would receive.
@MainActor
final class KeychainAccessibilityPolicyTests: XCTestCase {
    private let accessGroup = "TESTTEAM.com.khm.snippets"
    private let service = "com.khm.snippets.keychain-policy-tests"

    func testCloudLibraryIdentifierUsesEightHexCharacters() {
        let choice = SnippetsCloudLibraryChoice(
            spaceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            serverInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
            role: "owner")

        XCTAssertEqual(choice.libraryID, "1A60C0E7")
        XCTAssertNotNil(choice.libraryID.range(
            of: "^[0-9A-F]{8}$",
            options: .regularExpression))
    }

    func testAmbiguousCloudLibrariesRequireExplicitSelection() {
        let server = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        let first = SnippetsCloudLibraryChoice(
            spaceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            serverInstanceID: server,
            role: "owner")
        let second = SnippetsCloudLibraryChoice(
            spaceID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            serverInstanceID: server,
            role: "owner")

        XCTAssertNil(automaticSnippetsCloudLibraryChoice(
            [first, second],
            existingSpaceID: nil))
        XCTAssertEqual(
            automaticSnippetsCloudLibraryChoice(
                [first, second],
                existingSpaceID: second.spaceID),
            second.spaceID)
    }

    func testPendingRecoveryKitBlocksCloudDisconnectBeforeRevocation() async throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.recovery-disconnect.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.recovery-disconnect-credentials",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let bootstrapSecrets = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.recovery-disconnect-bootstrap",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        try bootstrapSecrets.storeItem(
            Data("pending recovery kit".utf8),
            account: SnippetsCloudAccountBootstrap.recoveryPresentationAccount)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            bootstrapSecrets: bootstrapSecrets,
            snippetsCloudEnabled: true)
        let bootstrap = SnippetsCloudAccountBootstrap(
            selection: selection,
            secrets: bootstrapSecrets)

        do {
            try await bootstrap.signOutThisDevice()
            XCTFail("Expected pending recovery setup to block disconnect")
        } catch let failure as SnippetsCloudAccountBootstrap.Failure {
            guard case .invalidState = failure else {
                return XCTFail("Expected invalidState, got \(failure)")
            }
        }
        XCTAssertNotNil(try bootstrapSecrets.loadItem(
            account: SnippetsCloudAccountBootstrap.recoveryPresentationAccount))
    }

    func testSynchronizableSyncKeyUsesAfterFirstUnlockWhileVaultItemsStayWhenUnlocked() throws {
        let probe = KeychainOperationsProbe()
        let keychain = makeStore(probe)

        _ = try SyncKeyStore(keychain: keychain).materialMintingIfNeeded()
        try keychain.store(Data(repeating: 0xA1, count: 32), keyID: "vault-key-id")
        try keychain.storeItem(
            Data("vault identity document".utf8),
            account: VaultIdentityStore.account)

        XCTAssertEqual(
            probe.accessibility(for: SyncKeyStore.account),
            kSecAttrAccessibleAfterFirstUnlock as String,
            "background CKSyncEngine rounds need K_sync after the device's first unlock")
        XCTAssertEqual(
            probe.accessibility(for: "vault-key-id"),
            kSecAttrAccessibleWhenUnlocked as String,
            "K_lib must retain the vault's existing unlocked-device policy")
        XCTAssertEqual(
            probe.accessibility(for: VaultIdentityStore.account),
            kSecAttrAccessibleWhenUnlocked as String,
            "vault/recovery identity material must not inherit K_sync's policy")
    }

    func testExistingWhenUnlockedSyncKeyMigratesWithoutChangingItsBytesOrVaultPolicy() throws {
        let probe = KeychainOperationsProbe()
        let syncMaterial = Data(repeating: 0x51, count: 64)
        let vaultKey = Data(repeating: 0x61, count: 32)
        let vaultIdentity = Data("existing vault identity".utf8)
        probe.seed(
            syncMaterial,
            account: SyncKeyStore.account,
            accessibility: kSecAttrAccessibleWhenUnlocked)
        probe.seed(
            vaultKey,
            account: "existing-vault-key",
            accessibility: kSecAttrAccessibleWhenUnlocked)
        probe.seed(
            vaultIdentity,
            account: VaultIdentityStore.account,
            accessibility: kSecAttrAccessibleWhenUnlocked)
        let keychain = makeStore(probe)

        XCTAssertEqual(try SyncKeyStore(keychain: keychain).material(), syncMaterial)
        XCTAssertEqual(try keychain.loadKey(keyID: "existing-vault-key"), vaultKey)
        XCTAssertEqual(
            try keychain.loadItem(account: VaultIdentityStore.account),
            vaultIdentity)

        XCTAssertEqual(
            probe.accessibility(for: SyncKeyStore.account),
            kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(
            probe.accessibility(for: "existing-vault-key"),
            kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertEqual(
            probe.accessibility(for: VaultIdentityStore.account),
            kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertEqual(
            probe.accessibilityUpdates,
            [SyncKeyStore.account],
            "migration must narrowly update only the fixed K_sync account")
    }

    func testDeviceOnlyBackgroundSessionUsesAfterFirstUnlockWithoutSynchronizing() throws {
        let probe = KeychainOperationsProbe()
        let keychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.oauth-policy-tests",
            itemAccessibility: .afterFirstUnlock,
            keychainOperations: makeOperations(probe))

        try keychain.storeItem(Data("refresh-token".utf8), account: "oidc-session-v1")

        XCTAssertEqual(
            probe.accessibility(for: "oidc-session-v1"),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testSnippetsCloudKeyIsDeviceOnlyBoundAndNeverMintedBySyncStartup() throws {
        let probe = KeychainOperationsProbe()
        let cloudKeychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: SnippetsCloudKeyStore.service,
            itemAccessibility: .afterFirstUnlock,
            keychainOperations: makeOperations(probe))
        let server = try XCTUnwrap(URL(string: "https://sync.example"))
        let space = UUID()
        let serverInstanceID = UUID()
        let cloudKeys = SnippetsCloudKeyStore(
            keychain: cloudKeychain,
            coordinates: {
                .init(
                    serverURL: server,
                    apiBaseURL: server.appending(path: "v2"),
                    spaceID: space,
                    serverInstanceID: serverInstanceID,
                    protocolMajor: 2)
            })

        let syncKeys = SyncKeyStore(
            keychain: makeStore(KeychainOperationsProbe()),
            cloudKeys: cloudKeys,
            usesSnippetsCloud: { true })
        XCTAssertThrowsError(try syncKeys.materialMintingIfNeeded()) { error in
            XCTAssertEqual(error as? SyncKeyStore.Failure, .cloudBootstrapRequired)
        }
        XCTAssertTrue(probe.addedAccounts.isEmpty)

        let material = Data(repeating: 0x91, count: 64)
        try cloudKeys.install(
            material,
            serverURL: server,
            spaceID: space,
            serverInstanceID: serverInstanceID,
            protocolMajor: 2)
        XCTAssertEqual(try syncKeys.material(), material)
        XCTAssertNil(try cloudKeys.material(
            serverURL: server,
            spaceID: UUID(),
            serverInstanceID: serverInstanceID,
            protocolMajor: 2))
        XCTAssertNil(try cloudKeys.material(
            serverURL: server,
            spaceID: space,
            serverInstanceID: UUID(),
            protocolMajor: 2))
        XCTAssertEqual(
            probe.accessibility(for: SnippetsCloudKeyStore.account),
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testPendingCloudLogoutResumesRootFirstCleanupDuringStartup() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.cloud-logout.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.logout-credentials-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let bootstrap = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.logout-bootstrap-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let cloudKeychain = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.logout-root-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let server = try XCTUnwrap(URL(string: "https://sync.example"))
        let space = UUID()
        let serverInstanceID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555")!
        let cloudKeys = SnippetsCloudKeyStore(
            keychain: cloudKeychain,
            coordinates: {
                .init(
                    serverURL: server,
                    apiBaseURL: server.appending(path: "v2"),
                    spaceID: space,
                    serverInstanceID: serverInstanceID,
                    protocolMajor: 2)
            })
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            cloudKeys: cloudKeys,
            bootstrapSecrets: bootstrap,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: server,
            spaceID: space,
            serverInstanceID: serverInstanceID,
            accessToken: "test-access-token")
        try cloudKeys.install(
            Data(repeating: 0x81, count: 64),
            serverURL: server,
            spaceID: space,
            serverInstanceID: serverInstanceID,
            protocolMajor: 2)
        try credentials.storeItem(
            Data("saved OAuth session".utf8),
            account: SyncBackendSelectionStore.oauthSessionAccount)
        try credentials.storeItem(
            Data("saved replacement lineage".utf8),
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount)
        try bootstrap.storeItem(
            Data("pairing private state".utf8),
            account: SnippetsCloudAccountBootstrap.pairingAccount)
        try credentials.storeItem(
            Data("pending".utf8),
            account: SyncBackendSelectionStore.pendingLocalEraseAccount)

        let resumed = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            cloudKeys: cloudKeys,
            bootstrapSecrets: bootstrap,
            snippetsCloudEnabled: true)

        XCTAssertNil(try cloudKeys.material(
            serverURL: server,
            spaceID: space,
            serverInstanceID: serverInstanceID,
            protocolMajor: 1))
        XCTAssertNil(try bootstrap.loadItem(account: SnippetsCloudAccountBootstrap.pairingAccount))
        XCTAssertNil(try credentials.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertNil(try credentials.loadItem(
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount))
        XCTAssertNil(try credentials.loadItem(account: SyncBackendSelectionStore.pendingLocalEraseAccount))
        XCTAssertEqual(resumed.provider, .iCloud)
        XCTAssertNil(resumed.cloudCoordinates)
        XCTAssertFalse(resumed.hasCloudSession)
    }

    func testDarkLaunchGateKeepsStoredCloudSelectionOffTheDataPlane() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.cloud-gate.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(
            SyncBackendSelectionStore.Provider.snippetsCloud.rawValue,
            forKey: SyncBackendSelectionStore.providerDefaultsKey)
        defaults.set(true, forKey: "SnippetsSyncProviderSwitchPending")
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.cloud-gate-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: false)

        XCTAssertEqual(selection.availableProviders, [.iCloud])
        XCTAssertEqual(selection.provider, .iCloud)
        XCTAssertNil(defaults.object(forKey: "SnippetsSyncProviderSwitchPending"))
        XCTAssertThrowsError(try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            serverInstanceID: UUID(),
            accessToken: "test-access-token")) { error in
            guard let failure = error as? SyncBackendSelectionStore.Failure,
                  case .featureDisabled = failure else {
                return XCTFail("Expected the dark-launch gate, got \(type(of: error))")
            }
        }
    }

    func testDarkLaunchGateSkipsUnrelatedCredentialLineageQueries() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.cloud-launch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let probe = KeychainOperationsProbe()
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.cloud-launch-tests",
            itemAccessibility: .afterFirstUnlock,
            keychainOperations: makeOperations(probe))

        _ = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: false)

        XCTAssertEqual(
            probe.copyAttempts,
            1,
            "shipping iCloud launch should inspect only the crash-safe local erase marker")
    }

    func testICloudTransportDoesNotDependOnSnippetsCloudKeychainAvailability() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.icloud-launch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let probe = KeychainOperationsProbe()
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.icloud-launch-tests",
            itemAccessibility: .afterFirstUnlock,
            keychainOperations: makeOperations(probe))
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        probe.failCopies(
            account: SyncBackendSelectionStore.pendingLocalEraseAccount,
            status: errSecNotAvailable)

        let transport = try selection.makeTransport()

        XCTAssertEqual(transport.identifier, "icloud")
    }

    func testPendingLogoutQueryFailureClosesTransportInsteadOfLookingAbsent() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.marker-query.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let probe = KeychainOperationsProbe()
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.marker-query-tests",
            itemAccessibility: .afterFirstUnlock,
            keychainOperations: makeOperations(probe))
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            serverInstanceID: UUID(),
            accessToken: "still-readable-legacy-token")

        probe.failCopies(
            account: SyncBackendSelectionStore.pendingLocalEraseAccount,
            status: errSecNotAvailable)

        XCTAssertTrue(
            selection.hasPendingLocalErase,
            "a non-throwing presence hint must fail closed when Keychain is unavailable")
        XCTAssertThrowsError(try selection.makeTransport()) { error in
            guard let failure = error as? SyncBackendSelectionStore.Failure,
                  case .credentialStoreUnavailable = failure else {
                return XCTFail("Expected unavailable credential store, got \(error)")
            }
        }
    }

    func testLogoutJournalWinsAfterRefreshCrashBeforeSessionReplacement() {
        let oldAccess = "old-access-token"
        let newAccess = "new-access-token"
        let oldRefresh = "old-refresh-token"
        let newRefresh = "new-refresh-token"

        // Fault-injection shape: refresh durably extended the journal, then the
        // process died before AUTH_SESSION was replaced and it still reads as old.
        let plan = SnippetsCloudCredentialRevocationPlan(
            sessionAccessToken: oldAccess,
            sessionRefreshToken: oldRefresh,
            journalAccessTokens: [oldAccess, newAccess],
            journalRefreshTokens: [oldRefresh, newRefresh])

        XCTAssertEqual(plan.accessTokens, [oldAccess, newAccess])
        XCTAssertEqual(plan.refreshTokens, [oldRefresh, newRefresh])
    }

    func testInteractiveSessionReplacementLogoutRevokesBothTokenFamilies() {
        let plan = SnippetsCloudCredentialRevocationPlan(
            sessionAccessToken: "session-b-access",
            sessionRefreshToken: "session-b-refresh",
            journalAccessTokens: ["session-a-access", "session-b-access"],
            journalRefreshTokens: ["session-a-refresh", "session-b-refresh"])

        // The same plan drives both the resource-session DELETE loop and provider
        // RFC 7009 loops; keeping both generations here proves neither is forgotten.
        XCTAssertEqual(plan.accessTokens, ["session-a-access", "session-b-access"])
        XCTAssertEqual(plan.refreshTokens, ["session-a-refresh", "session-b-refresh"])
    }

    func testReplacementCleanupRevokesAbandonedNewRefreshBeforeSessionCommit() throws {
        let plan = try XCTUnwrap(SnippetsCloudCredentialReplacementCleanupPlan(
            currentAccessToken: "access-a",
            currentRefreshToken: "refresh-a",
            journalAccessTokens: ["access-a", "access-b"],
            journalRefreshTokens: ["refresh-a", "refresh-b"],
            replacementKind: .refreshRotation))

        XCTAssertEqual(plan.accessTokensToRetire, ["access-b"])
        XCTAssertEqual(plan.abandonedRefreshTokens, ["refresh-b"])
    }

    func testReplacementCleanupNeverRevokesOldRefreshAfterSessionCommit() throws {
        let plan = try XCTUnwrap(SnippetsCloudCredentialReplacementCleanupPlan(
            currentAccessToken: "access-b",
            currentRefreshToken: "refresh-b",
            journalAccessTokens: ["access-a", "access-b"],
            journalRefreshTokens: ["refresh-a", "refresh-b"],
            replacementKind: .refreshRotation))

        XCTAssertEqual(plan.accessTokensToRetire, ["access-a"])
        XCTAssertTrue(
            plan.abandonedRefreshTokens.isEmpty,
            "provider family revocation must not kill the committed B generation")
    }

    func testInteractiveReplacementRevokesOldGrantAfterNewSessionCommit() throws {
        let plan = try XCTUnwrap(SnippetsCloudCredentialReplacementCleanupPlan(
            currentAccessToken: "access-b",
            currentRefreshToken: "refresh-b",
            journalAccessTokens: ["access-a", "access-b"],
            journalRefreshTokens: ["refresh-a", "refresh-b"],
            replacementKind: .interactiveReplacement))

        XCTAssertEqual(plan.accessTokensToRetire, ["access-a"])
        XCTAssertEqual(plan.abandonedRefreshTokens, ["refresh-a"])
    }

    func testUnreadableInteractiveReplacementOffersCrashSafeLocalReset() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.replacement-fence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let server = try XCTUnwrap(URL(string: "https://sync.example"))
        let spaceID = UUID()
        let serverInstanceID = UUID()
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.replacement-fence-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let cloudCredentialStore = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.replacement-cloud-key-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let bootstrap = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.replacement-bootstrap-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let cloudKeys = SnippetsCloudKeyStore(
            keychain: cloudCredentialStore,
            coordinates: {
                .init(
                    serverURL: server,
                    spaceID: spaceID,
                    serverInstanceID: serverInstanceID,
                    protocolMajor: 1)
            })
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            cloudKeys: cloudKeys,
            bootstrapSecrets: bootstrap,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: server,
            spaceID: spaceID,
            serverInstanceID: serverInstanceID,
            accessToken: "test-access-token")
        try credentials.storeItem(
            Data("durable replacement lineage".utf8),
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount)

        XCTAssertTrue(selection.hasPendingCredentialCleanup)
        XCTAssertTrue(selection.cloudCredentialResetRequired)
        XCTAssertFalse(selection.hasCloudSession)
        XCTAssertThrowsError(try selection.makeTransport()) { error in
            guard let failure = error as? SyncBackendSelectionStore.Failure,
                  case .credentialResetRequired = failure else {
                return XCTFail("Expected reset fence, got \(error)")
            }
        }

        try selection.resetUnreadableCloudCredentialsLocally(
            bootstrapSecrets: bootstrap)

        XCTAssertFalse(selection.hasPendingCredentialCleanup)
        XCTAssertFalse(selection.cloudCredentialResetRequired)
        XCTAssertNil(try credentials.loadItem(
            account: SyncBackendSelectionStore.pendingLocalEraseAccount))
        XCTAssertNil(selection.cloudCoordinates)
        XCTAssertEqual(selection.provider, .iCloud)
    }

    func testReadableInteractiveReplacementRemainsARetryableCleanupFence() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.readable-replacement.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.readable-replacement-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            serverInstanceID: UUID(),
            accessToken: "test-access-token")
        let journal: [String: Any] = [
            "schemaVersion": 1,
            "serverURL": "https://sync.example",
            "issuer": "https://identity.example",
            "resource": "https://sync.example",
            "revocationEndpoint": "https://identity.example/revoke",
            "clientID": "snippets-native",
            "accessTokens": ["old-access-token"],
            "refreshTokens": ["old-refresh-token"],
        ]
        try credentials.storeItem(
            JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]),
            account: SyncBackendSelectionStore.oauthSessionReplacementAccount)

        XCTAssertTrue(selection.hasPendingCredentialCleanup)
        XCTAssertFalse(selection.cloudCredentialResetRequired)
        XCTAssertThrowsError(try selection.makeTransport()) { error in
            guard let failure = error as? SyncBackendSelectionStore.Failure,
                  case .credentialCleanupRequired = failure else {
                return XCTFail("Expected cleanup fence, got \(error)")
            }
        }
    }

    func testUnreadablePrimaryOAuthSessionRequiresExplicitReset() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.primary-session-reset.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.primary-session-reset-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            serverInstanceID: UUID(),
            accessToken: "test-access-token")
        try credentials.storeItem(
            Data("unreadable primary session".utf8),
            account: SyncBackendSelectionStore.oauthSessionAccount)

        XCTAssertTrue(selection.cloudCredentialResetRequired)
        XCTAssertThrowsError(try selection.makeTransport()) { error in
            guard let failure = error as? SyncBackendSelectionStore.Failure,
                  case .credentialResetRequired = failure else {
                return XCTFail("Expected reset fence, got \(error)")
            }
        }
    }

    func testUnreadableRevocationJournalRequiresExplicitReset() throws {
        let defaultsName = "KeychainAccessibilityPolicyTests.revocation-reset.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let credentials = KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.revocation-reset-tests",
            itemAccessibility: .afterFirstUnlock,
            inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: XCTUnwrap(URL(string: "https://sync.example")),
            spaceID: UUID(),
            serverInstanceID: UUID(),
            accessToken: "test-access-token")
        try credentials.storeItem(
            Data("unreadable revocation lineage".utf8),
            account: SyncBackendSelectionStore.oauthRevocationAccount)

        XCTAssertTrue(selection.cloudCredentialResetRequired)
        XCTAssertThrowsError(try selection.makeTransport()) { error in
            guard let failure = error as? SyncBackendSelectionStore.Failure,
                  case .credentialResetRequired = failure else {
                return XCTFail("Expected reset fence, got \(error)")
            }
        }
    }

    func testCredentialMutationGateSerializesAcrossAwaitedOperations() async throws {
        let gate = SnippetsCloudCredentialMutationGate()
        var events: [String] = []
        let first = Task { @MainActor in
            try await gate.run {
                events.append("first-start")
                try await Task.sleep(for: .milliseconds(100))
                events.append("first-end")
                return "first"
            }
        }
        while events.isEmpty { await Task.yield() }
        let second = Task { @MainActor in
            try await gate.run {
                events.append("second")
                return "second"
            }
        }

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual([firstValue, secondValue], ["first", "second"])
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }

    func testCancelledCredentialMutationWaiterNeverRuns() async throws {
        let gate = SnippetsCloudCredentialMutationGate()
        var events: [String] = []
        let first = Task { @MainActor in
            try await gate.run {
                events.append("first-start")
                try await Task.sleep(for: .milliseconds(100))
                events.append("first-end")
            }
        }
        while events.isEmpty { await Task.yield() }
        let cancelled = Task { @MainActor in
            try await gate.run {
                events.append("cancelled-operation-ran")
            }
        }
        cancelled.cancel()

        do {
            try await cancelled.value
            XCTFail("A cancelled gate waiter must not acquire credential authority")
        } catch is CancellationError {
            // Expected: cancellation removes and resumes the queued continuation.
        }
        try await first.value
        XCTAssertEqual(events, ["first-start", "first-end"])
    }

    func testRecoveryPresentationAuthorityIsSingleUseAndRelocksAcrossProcesses() {
        var firstProcess = SnippetsCloudRecoveryPresentationGate()
        XCTAssertFalse(firstProcess.isAuthorized)
        firstProcess.authorize()
        XCTAssertTrue(firstProcess.isAuthorized)
        XCTAssertTrue(firstProcess.consumeAuthorization())
        XCTAssertFalse(firstProcess.consumeAuthorization())
        XCTAssertFalse(firstProcess.isAuthorized)

        let relaunchedProcess = SnippetsCloudRecoveryPresentationGate()
        XCTAssertFalse(
            relaunchedProcess.isAuthorized,
            "durable pending recovery must not inherit UI disclosure authority")
    }

    func testOpeningCheckpointCiphertextWithoutItsLocalKeyNeverMintsAReplacement() throws {
        let originalKey = SymmetricKey(data: Data(repeating: 0x71, count: 32))
        let sealed = try AES.GCM.seal(
            Data("opaque scheduler checkpoint".utf8),
            using: originalKey)
        let ciphertext = try XCTUnwrap(sealed.combined)
        let probe = KeychainOperationsProbe()
        let keys = LocalCloudKitSyncCheckpointKeyStore(
            keychainOperations: makeOperations(probe))
        let cryptor = LocalCloudKitSyncCheckpointCryptor(keys: keys)

        XCTAssertThrowsError(try cryptor.open(ciphertext))
        XCTAssertTrue(
            probe.addedAccounts.isEmpty,
            "ciphertext plus an absent key is evidence requiring Review, not first-use minting")
        XCTAssertGreaterThan(probe.copyAttempts, 0)
    }

    private func makeStore(_ probe: KeychainOperationsProbe) -> KeychainSecretStore {
        KeychainSecretStore(
            tier: .synchronizable(accessGroup: accessGroup),
            service: service,
            keychainOperations: makeOperations(probe))
    }

    private func makeOperations(_ probe: KeychainOperationsProbe) -> KeychainItemOperations {
        KeychainItemOperations(
            copyMatching: { query, result in probe.copyMatching(query, result) },
            update: { query, values in probe.update(query, values) },
            add: { attributes, result in probe.add(attributes, result) },
            delete: { query in probe.delete(query) })
    }
}

private nonisolated final class KeychainOperationsProbe: @unchecked Sendable {
    private struct Item {
        var data: Data
        var accessibility: String
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var retainedResults: [AnyObject] = []
    private var addedAccountsStorage: [String] = []
    private var accessibilityUpdatesStorage: [String] = []
    private var copyAttemptsStorage = 0
    private var copyFailuresByAccount: [String: OSStatus] = [:]

    var addedAccounts: [String] { lock.withLock { addedAccountsStorage } }
    var accessibilityUpdates: [String] {
        lock.withLock { accessibilityUpdatesStorage }
    }
    var copyAttempts: Int { lock.withLock { copyAttemptsStorage } }

    func seed(_ data: Data, account: String, accessibility: CFString) {
        lock.withLock {
            items[account] = Item(data: data, accessibility: accessibility as String)
        }
    }

    func accessibility(for account: String) -> String? {
        lock.withLock { items[account]?.accessibility }
    }

    func failCopies(account: String, status: OSStatus) {
        lock.withLock { copyFailuresByAccount[account] = status }
    }

    func copyMatching(
        _ rawQuery: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        let query = dictionary(rawQuery)
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        return lock.withLock {
            copyAttemptsStorage += 1
            if let failure = copyFailuresByAccount[account] { return failure }
            guard let item = items[account] else { return errSecItemNotFound }

            let wantsAttributes = query[kSecReturnAttributes as String] as? Bool == true
            let wantsData = query[kSecReturnData as String] as? Bool == true
            let object: AnyObject
            if wantsAttributes {
                var attributes: [String: Any] = [
                    kSecAttrAccount as String: account,
                    kSecAttrAccessible as String: item.accessibility,
                ]
                if wantsData { attributes[kSecValueData as String] = item.data }
                object = attributes as NSDictionary
            } else if wantsData {
                object = item.data as NSData
            } else {
                object = kCFBooleanTrue
            }
            retainedResults.append(object)
            result?.pointee = object
            return errSecSuccess
        }
    }

    func update(_ rawQuery: CFDictionary, _ rawValues: CFDictionary) -> OSStatus {
        let query = dictionary(rawQuery)
        let values = dictionary(rawValues)
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        return lock.withLock {
            guard var item = items[account] else { return errSecItemNotFound }
            if let data = values[kSecValueData as String] as? Data { item.data = data }
            if let accessibility = values[kSecAttrAccessible as String] {
                item.accessibility = string(accessibility)
                accessibilityUpdatesStorage.append(account)
            }
            items[account] = item
            return errSecSuccess
        }
    }

    func add(
        _ rawAttributes: CFDictionary,
        _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        _ = result
        let attributes = dictionary(rawAttributes)
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data,
              let accessibility = attributes[kSecAttrAccessible as String]
        else { return errSecParam }
        return lock.withLock {
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = Item(
                data: data,
                accessibility: string(accessibility))
            addedAccountsStorage.append(account)
            return errSecSuccess
        }
    }

    func delete(_ rawQuery: CFDictionary) -> OSStatus {
        let query = dictionary(rawQuery)
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        return lock.withLock {
            items.removeValue(forKey: account) == nil
                ? errSecItemNotFound
                : errSecSuccess
        }
    }

    private func dictionary(_ value: CFDictionary) -> [String: Any] {
        value as NSDictionary as? [String: Any] ?? [:]
    }

    private func string(_ value: Any) -> String {
        if let value = value as? String { return value }
        return String(describing: value)
    }
}
