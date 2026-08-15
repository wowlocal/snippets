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
        let cloudKeys = SnippetsCloudKeyStore(
            keychain: cloudKeychain,
            coordinates: { .init(serverURL: server, spaceID: space) })

        let syncKeys = SyncKeyStore(
            keychain: makeStore(KeychainOperationsProbe()),
            cloudKeys: cloudKeys,
            usesSnippetsCloud: { true })
        XCTAssertThrowsError(try syncKeys.materialMintingIfNeeded()) { error in
            XCTAssertEqual(error as? SyncKeyStore.Failure, .cloudBootstrapRequired)
        }
        XCTAssertTrue(probe.addedAccounts.isEmpty)

        let material = Data(repeating: 0x91, count: 64)
        try cloudKeys.install(material, serverURL: server, spaceID: space)
        XCTAssertEqual(try syncKeys.material(), material)
        XCTAssertNil(try cloudKeys.material(serverURL: server, spaceID: UUID()))
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
        let cloudKeys = SnippetsCloudKeyStore(
            keychain: cloudKeychain,
            coordinates: { .init(serverURL: server, spaceID: space) })
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: credentials,
            cloudKeys: cloudKeys,
            bootstrapSecrets: bootstrap)
        try selection.selectSnippetsCloud(
            serverURL: server,
            spaceID: space,
            accessToken: "test-access-token")
        try cloudKeys.install(Data(repeating: 0x81, count: 64), serverURL: server, spaceID: space)
        try credentials.storeItem(
            Data("saved OAuth session".utf8),
            account: SyncBackendSelectionStore.oauthSessionAccount)
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
            bootstrapSecrets: bootstrap)

        XCTAssertNil(try cloudKeys.material(serverURL: server, spaceID: space))
        XCTAssertNil(try bootstrap.loadItem(account: SnippetsCloudAccountBootstrap.pairingAccount))
        XCTAssertNil(try credentials.loadItem(account: SyncBackendSelectionStore.oauthSessionAccount))
        XCTAssertNil(try credentials.loadItem(account: SyncBackendSelectionStore.pendingLocalEraseAccount))
        XCTAssertEqual(resumed.provider, .iCloud)
        XCTAssertNil(resumed.cloudCoordinates)
        XCTAssertFalse(resumed.hasCloudSession)
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

    func testConcurrentCloudRefreshesShareOneCredentialRotation() async throws {
        let gate = SnippetsCloudRefreshSingleFlight()
        var rotations = 0
        let first = Task { @MainActor in
            try await gate.run {
                rotations += 1
                try await Task.sleep(for: .milliseconds(100))
                return "one-rotated-access-token"
            }
        }
        while !gate.isActive { await Task.yield() }
        let second = Task { @MainActor in
            try await gate.run {
                rotations += 1
                return "unexpected-second-token"
            }
        }

        let firstValue = try await first.value
        let secondValue = try await second.value
        let values = [firstValue, secondValue]
        XCTAssertEqual(values, ["one-rotated-access-token", "one-rotated-access-token"])
        XCTAssertEqual(rotations, 1)
        XCTAssertFalse(gate.isActive)
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
