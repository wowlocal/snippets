import CryptoKit
import Darwin
import Foundation
import Security
import XCTest

@testable import Snippets

@MainActor
final class SecureVaultProviderIsolationTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?
    private var provider: SyncBackendSelectionStore.Provider? = .snippetsCloud
    private var syncEnabled = true

    override func setUpWithError() throws {
        previousRoot = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SecureVaultProviderIsolation-\(UUID())")
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
        SnippetStorageLocations.createAllDirectories()
        provider = .snippetsCloud
        syncEnabled = true
    }

    override func tearDownWithError() throws {
        if let previousRoot { setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousRoot, 1) }
        else { unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey) }
        try? FileManager.default.removeItem(at: root)
    }

    func testNativeMissingVaultNeverReadsSharedIdentityIncludingExplicitCreation() async throws {
        for background in [false, true] {
            let probe = try probeWithSharedIdentity()
            let fixture = makeFixture(probe, background: background)
            fixture.store.reload()
            XCTAssertFalse(fixture.store.joinSharedVaultIfAvailable())
            let pending = try XCTUnwrap(fixture.store.prepareVaultCreationIfNeeded())
            pending.cancel()
            await Task.yield()
            XCTAssertNil(fixture.store.document)
            XCTAssertFalse(FileManager.default.fileExists(atPath: SnippetStorageLocations.vaultFileURL.path))
            XCTAssertEqual(probe.identityReads, 0)
            XCTAssertEqual(probe.identityWrites, 0)
        }
    }

    func testUnknownProviderCannotFallBackToICloudIdentity() throws {
        provider = nil
        let probe = try probeWithSharedIdentity()
        let fixture = makeFixture(probe)
        XCTAssertFalse(fixture.store.joinSharedVaultIfAvailable())
        try fixture.store.prepareVaultCreationIfNeeded()?.cancel()
        XCTAssertNil(fixture.store.document)
        XCTAssertEqual(probe.identityReads, 0)
        XCTAssertEqual(probe.identityWrites, 0)
    }

    func testNativeCreationPublishesNoSharedIdentity() throws {
        let probe = try probeWithSharedIdentity()
        let fixture = makeFixture(probe)
        let pending = try XCTUnwrap(fixture.store.prepareVaultCreationIfNeeded())
        let created = try fixture.store.commitVaultCreation(pending)
        XCTAssertNotEqual(created.kid, Self.sharedIdentity.kid)
        XCTAssertEqual(fixture.store.document?.kid, created.kid)
        XCTAssertEqual(probe.identityReads, 0)
        XCTAssertEqual(probe.identityWrites, 0)
        XCTAssertTrue(probe.hasValue(created.kid), "the new local vault key still must be durably stored")
    }

    func testNativeReloadAndRecoveryAdditionNeverPublishIntoICloudSlot() async throws {
        let probe = try probeWithSharedIdentity()
        let local = Self.identity(kid: "local-native-vault")
        probe.seed(Data(repeating: 0x34, count: 32), account: local.kid)
        try VaultFile.write(local, to: SnippetStorageLocations.vaultFileURL,
                            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let fixture = makeFixture(probe)
        fixture.store.reload()
        _ = try await fixture.session.unlock(reason: "Isolated provider test")
        let recovery = try XCTUnwrap(fixture.store.prepareRecoveryKeyAddition())
        XCTAssertTrue(try fixture.store.commitRecoveryKeyAddition(recovery))
        XCTAssertNotNil(fixture.store.document?.wrapRecovery)
        XCTAssertEqual(fixture.store.document?.kid, local.kid)
        XCTAssertEqual(probe.identityReads, 0)
        XCTAssertEqual(probe.identityWrites, 0)
    }

    func testNativeBackgroundReloadDoesNotScheduleIdentityPublication() async throws {
        let probe = try probeWithSharedIdentity()
        let local = Self.identity(kid: "local-native-vault")
        try VaultFile.write(local, to: SnippetStorageLocations.vaultFileURL,
                            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let fixture = makeFixture(probe, background: true)
        fixture.store.reload()
        await Task.yield()
        XCTAssertEqual(probe.identityReads, 0)
        XCTAssertEqual(probe.identityWrites, 0)
    }

    func testICloudAutomaticAdoptionStillRequiresSyncEnabled() throws {
        provider = .iCloud
        syncEnabled = false
        let probe = try probeWithSharedIdentity()
        let fixture = makeFixture(probe)
        XCTAssertNil(fixture.store.document)
        XCTAssertEqual(probe.identityReads, 0)
        syncEnabled = true
        fixture.store.reload()
        XCTAssertEqual(fixture.store.document?.kid, Self.sharedIdentity.kid)
        XCTAssertGreaterThan(probe.identityReads, 0)
    }

    func testICloudExplicitCreationStillAdoptsWhileSyncIsOff() throws {
        provider = .iCloud
        syncEnabled = false
        let probe = try probeWithSharedIdentity()
        let fixture = makeFixture(probe)
        XCTAssertNil(try fixture.store.prepareVaultCreationIfNeeded())
        XCTAssertEqual(fixture.store.document?.kid, Self.sharedIdentity.kid)
        XCTAssertGreaterThan(probe.identityReads, 0)
    }

    func testICloudCreationAndReloadStillPublishIdentity() throws {
        provider = .iCloud
        syncEnabled = false
        let probe = VaultIdentityAccessProbe()
        let fixture = makeFixture(probe)
        let pending = try XCTUnwrap(fixture.store.prepareVaultCreationIfNeeded())
        let created = try fixture.store.commitVaultCreation(pending)
        XCTAssertGreaterThan(probe.identityWrites, 0)
        XCTAssertTrue(probe.hasValue(VaultIdentityStore.account))
        let writes = probe.identityWrites
        fixture.store.reload()
        XCTAssertEqual(fixture.store.document?.kid, created.kid)
        XCTAssertEqual(probe.identityWrites, writes, "an unchanged identity needs only its correctness read")
    }

    func testICloudRecoveryAdditionRepublishesExistingIdentity() async throws {
        provider = .iCloud
        let probe = try probeWithSharedIdentity()
        try VaultFile.write(Self.sharedIdentity, to: SnippetStorageLocations.vaultFileURL,
                            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        let fixture = makeFixture(probe)
        _ = try await fixture.session.unlock(reason: "Isolated recovery publication test")
        let priorWrites = probe.identityWrites
        let recovery = try XCTUnwrap(fixture.store.prepareRecoveryKeyAddition())
        XCTAssertTrue(try fixture.store.commitRecoveryKeyAddition(recovery))
        XCTAssertGreaterThan(probe.identityWrites, priorWrites)
    }

    func testDeviceOnlyForgetTouchesSharedIdentityOnlyForICloud() throws {
        syncEnabled = false
        for selection in [SyncBackendSelectionStore.Provider.snippetsCloud, .iCloud] {
            provider = selection
            let probe = try probeWithSharedIdentity()
            try VaultFile.write(Self.sharedIdentity, to: SnippetStorageLocations.vaultFileURL,
                                temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
            let fixture = makeFixture(probe)
            let priorWrites = probe.identityWrites
            try fixture.store.forgetEverything(syncIsQuiescent: true)
            XCTAssertNil(fixture.store.document)
            XCTAssertFalse(probe.hasValue(Self.sharedIdentity.kid))
            if selection == .snippetsCloud {
                XCTAssertTrue(probe.hasValue(VaultIdentityStore.account))
                XCTAssertEqual(probe.identityReads, 0)
                XCTAssertEqual(probe.identityWrites, priorWrites)
            } else {
                XCTAssertFalse(probe.hasValue(VaultIdentityStore.account))
                XCTAssertGreaterThan(probe.identityWrites, priorWrites)
            }
        }
    }

    func testProviderSwitchRejectsInFlightBackgroundIdentityLookup() async throws {
        provider = .iCloud
        let probe = try probeWithSharedIdentity()
        let began = expectation(description: "shared identity lookup started")
        let release = DispatchSemaphore(value: 0)
        probe.beforeIdentityRead = { began.fulfill(); _ = release.wait(timeout: .now() + 3) }
        let fixture = makeFixture(probe, background: true)
        await fulfillment(of: [began], timeout: 2)
        provider = .snippetsCloud
        let noAdoption = expectation(description: "native provider must not adopt delayed iCloud identity")
        noAdoption.isInverted = true
        fixture.store.onChange = { noAdoption.fulfill() }
        release.signal()
        await fulfillment(of: [noAdoption], timeout: 0.2)
        XCTAssertNil(fixture.store.document)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SnippetStorageLocations.vaultFileURL.path))
        XCTAssertEqual(probe.identityWrites, 0)
    }

    func testProviderSwitchBeforeBackgroundTaskStartsPreventsLookupAndPublication() async throws {
        for hasLocalVault in [false, true] {
            provider = .iCloud
            let probe = try probeWithSharedIdentity()
            if hasLocalVault {
                try VaultFile.write(Self.sharedIdentity, to: SnippetStorageLocations.vaultFileURL,
                                    temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
            }
            let noIdentityAccess = expectation(description: "queued iCloud task loses authority after switch")
            noIdentityAccess.isInverted = true
            probe.beforeIdentityRead = { noIdentityAccess.fulfill() }
            let fixture = makeFixture(probe, background: true)
            // No suspension: the main-actor maintenance task has not started yet.
            provider = .snippetsCloud
            await fulfillment(of: [noIdentityAccess], timeout: 0.2)
            XCTAssertEqual(fixture.store.document != nil, hasLocalVault)
            XCTAssertEqual(probe.identityReads, 0)
            XCTAssertEqual(probe.identityWrites, 0)
        }
    }

    func testNativeWireVaultIDDoesNotAuthorizeSharedIdentityAdoption() throws {
        let probe = try probeWithSharedIdentity()
        let fixture = makeFixture(probe)
        let ordinary = SnippetStore(configuration: .iOS)
        let bridge = SnippetLibraryBridge(store: ordinary, secureStore: fixture.store)
        let recordID = UUID()
        let envelope = SyncEnvelope.secureRecord(
            id: recordID, name: "Synthetic secure record", keyword: "provider-test",
            plaintext: Data("opaque-test-ciphertext".utf8),
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
            hlc: HLC(wallMs: 1_000, counter: 0, device: "aabbccdd"), origin: "aabbccdd",
            x: [SyncEnvelope.vaultKeyIDExtensionKey: .utf8(Data(Self.sharedIdentity.kid.utf8))])
        let classification = bridge.classifyRemote([envelope])
        XCTAssertTrue(classification.applicable.isEmpty)
        XCTAssertEqual(classification.deferredIDs, [recordID])
        XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)
        XCTAssertNil(fixture.store.document)
        XCTAssertEqual(probe.identityReads, 0)
    }

    private func makeFixture(_ probe: VaultIdentityAccessProbe, background: Bool = false)
        -> (store: SecureSnippetStore, session: VaultSession) {
        let keychain = KeychainSecretStore(tier: .deviceOnly,
            service: "isolated-vault-provider-tests", keychainOperations: probe.operations)
        let session = VaultSession(keychain: keychain, authenticationEvaluator: { _ in true })
        let store = SecureSnippetStore(session: session, keychain: keychain,
            maintainsKeychainInBackground: background, selectedSyncProvider: { self.provider },
            syncIsEnabled: { self.syncEnabled }, deviceID: "aabbccdd")
        return (store, session)
    }

    private func probeWithSharedIdentity() throws -> VaultIdentityAccessProbe {
        let probe = VaultIdentityAccessProbe()
        probe.seed(try VaultFile.encode(Self.sharedIdentity), account: VaultIdentityStore.account)
        probe.seed(Data(repeating: 0x42, count: 32), account: Self.sharedIdentity.kid)
        return probe
    }

    private static var sharedIdentity: VaultDocument { identity(kid: "unrelated-icloud-vault") }
    private static func identity(kid: String) -> VaultDocument {
        VaultDocument(kid: kid, vaultSalt: SnippetCrypto.base64URL(Data(repeating: 0x21, count: 32)),
            kdf: VaultKDFParameters(alg: PassphraseKDF.algorithm, iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(Data(repeating: 0x22, count: 16))))
    }
}

private nonisolated final class VaultIdentityAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var reads = 0
    private var writes = 0
    var beforeIdentityRead: (@Sendable () -> Void)?
    var identityReads: Int { lock.withLock { reads } }
    var identityWrites: Int { lock.withLock { writes } }
    func seed(_ value: Data, account: String) { lock.withLock { values[account] = value } }
    func hasValue(_ account: String) -> Bool { lock.withLock { values[account] != nil } }

    var operations: KeychainItemOperations {
        KeychainItemOperations(copyMatching: { [self] query, result in
            let attributes = query as NSDictionary
            guard let account = attributes[kSecAttrAccount] as? String else { return errSecParam }
            if account == VaultIdentityStore.account {
                lock.withLock { reads += 1 }
                beforeIdentityRead?()
            }
            guard let value = lock.withLock({ values[account] }) else { return errSecItemNotFound }
            if attributes[kSecReturnAttributes] as? Bool == true {
                result?.pointee = [kSecValueData as String: value,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary
            } else if attributes[kSecReturnData] as? Bool == true {
                result?.pointee = value as CFData
            }
            return errSecSuccess
        }, update: { [self] query, update in
            let attributes = query as NSDictionary
            guard let account = attributes[kSecAttrAccount] as? String else { return errSecParam }
            return lock.withLock {
                if account == VaultIdentityStore.account { writes += 1 }
                guard values[account] != nil else { return errSecItemNotFound }
                if let data = (update as NSDictionary)[kSecValueData] as? Data { values[account] = data }
                return errSecSuccess
            }
        }, add: { [self] query, _ in
            let attributes = query as NSDictionary
            guard let account = attributes[kSecAttrAccount] as? String,
                  let data = attributes[kSecValueData] as? Data else { return errSecParam }
            return lock.withLock {
                if account == VaultIdentityStore.account { writes += 1 }
                guard values[account] == nil else { return errSecDuplicateItem }
                values[account] = data
                return errSecSuccess
            }
        }, delete: { [self] query in
            guard let account = (query as NSDictionary)[kSecAttrAccount] as? String else { return errSecParam }
            return lock.withLock {
                if account == VaultIdentityStore.account { writes += 1 }
                values[account] = nil
                return errSecSuccess
            }
        })
    }
}
