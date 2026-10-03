import CryptoKit
import Foundation
import XCTest
#if os(macOS)
@testable import Snippets_Debug
#else
@testable import Snippets
#endif

/// Opt-in, multi-process integration test used by `scripts/test-cross-platform-sync.sh`
/// and `scripts/test-native-cloud-integration.py`.
///
/// Every invocation gets a fresh local installation but shares one disposable server
/// space with the other platforms. That makes a successful phase prove that the
/// production store/bridge/coordinator stack can consume the previous client's durable
/// result, not merely an in-process fixture.
@MainActor
final class SnippetsCloudAppIntegrationTests: XCTestCase {
    private var activeProtocolLocations: SyncProtocolLocations?

    private struct FileConfiguration: Decodable {
        let serverURL: String
        let accessToken: String
        let spaceID: String
        let serverInstanceID: String
        let phase: String
    }

    private enum Phase: String {
        case macSeed = "mac-seed"
        case iosSeed = "ios-seed"
        case macUpdateAndroid = "mac-update-android"
        case iosUpdateMac = "ios-update-mac"
        case macVerify = "mac-verify"
        case iosVerify = "ios-verify"
        case macVerifyDeletion = "mac-verify-deletion"
        case macChaosTruncatedFetch = "mac-chaos-truncated-fetch"
        case iosVerifyDeletion = "ios-verify-deletion"
    }

    func testCrossPlatformSyncPhase() async throws {
        let environment = try integrationEnvironment()
        guard environment["SNIPPETS_CLOUD_E2E"] == "1" else {
            throw XCTSkip("Set SNIPPETS_CLOUD_E2E=1 to run the disposable live-server test")
        }
        let serverText = try XCTUnwrap(environment["SNIPPETS_CLOUD_E2E_SERVER_URL"])
        let token = try XCTUnwrap(environment["SNIPPETS_CLOUD_E2E_ACCESS_TOKEN"])
        let spaceText = try XCTUnwrap(environment["SNIPPETS_CLOUD_E2E_SPACE_ID"])
        let serverInstanceText = try XCTUnwrap(
            environment["SNIPPETS_CLOUD_E2E_SERVER_INSTANCE_ID"])
        let phase = try XCTUnwrap(Phase(rawValue:
            try XCTUnwrap(environment["SNIPPETS_CLOUD_E2E_APPLE_PHASE"])))
        try requirePhaseForCurrentPlatform(phase)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnippetsCloudAppE2E-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "SnippetsCloudAppE2E-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let wireKeyFingerprintDefaultsKey = "SnippetsSyncWireKeyFingerprint"
        let previousWireKeyFingerprint = UserDefaults.standard.object(
            forKey: wireKeyFingerprintDefaultsKey)
        let previousSupportDirectory = ProcessInfo.processInfo.environment[
            SnippetStorageLocations.rootOverrideEnvironmentKey]
        let previousRuntimeEnabledOverride = SyncCoordinator.runtimeEnabledOverride
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
        SyncCoordinator.runtimeEnabledOverride = true
        defer {
            SyncCoordinator.runtimeEnabledOverride = previousRuntimeEnabledOverride
            if let previousSupportDirectory {
                setenv(
                    SnippetStorageLocations.rootOverrideEnvironmentKey,
                    previousSupportDirectory,
                    1)
            } else {
                unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
            }
            if let previousWireKeyFingerprint {
                UserDefaults.standard.set(
                    previousWireKeyFingerprint, forKey: wireKeyFingerprintDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: wireKeyFingerprintDefaultsKey)
            }
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }

        SnippetStorageLocations.createAllDirectories()
        let initial = phase == .macSeed ? [Self.macSnippet(content: Self.macInitial)] : []
        try SnippetLibraryCodec.encode(initial).write(
            to: SnippetStorageLocations.snippetsFileURL, options: .atomic)

        let keychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        try keychain.storeItem(Self.portableSyncMaterial, account: SyncKeyStore.account)
        let serverURL = try XCTUnwrap(URL(string: serverText))
        let spaceID = try XCTUnwrap(UUID(uuidString: spaceText))
        let serverInstanceID = try XCTUnwrap(UUID(uuidString: serverInstanceText))
        let cloudKeys = SnippetsCloudKeyStore(
            keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            coordinates: {
                .init(serverURL: serverURL, apiBaseURL: serverURL.appending(path: "v2"),
                      spaceID: spaceID, serverInstanceID: serverInstanceID, protocolMajor: 2)
            })
        // The portable fixture is explicit test authority, never the user's shared
        // iCloud or device Cloud key. Exercise the production provider key selector.
        try cloudKeys.install(Self.portableSyncMaterial, serverURL: serverURL,
                              spaceID: spaceID, serverInstanceID: serverInstanceID,
                              protocolMajor: 2)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: keychain,
            cloudKeys: cloudKeys,
            bootstrapSecrets: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            snippetsCloudEnabled: true)
        XCTAssertEqual(selection.provider, .iCloud)
        try selection.selectSnippetsCloud(
            serverURL: serverURL,
            spaceID: spaceID,
            serverInstanceID: serverInstanceID,
            accessToken: token)
        activeProtocolLocations = try selection.protocolLocations()
        defer { activeProtocolLocations = nil }
        XCTAssertTrue(try selection.makeTransport().supportsPush)
        if phase == .macChaosTruncatedFetch {
            try await assertTruncatedFetchRecovers(selection)
        }

        #if os(macOS)
        let store = SnippetStore(configuration: .macOSDefault)
        #else
        let store = SnippetStore(configuration: .iOS)
        #endif
        let vaultSession = VaultSession(
            keychain: keychain,
            authenticationEvaluator: { _ in true })
        let secureStore = SecureSnippetStore(
            session: vaultSession,
            keychain: keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        let library = SnippetLibraryBridge(store: store, secureStore: secureStore)
        let coordinator = SyncCoordinator(
            library: library,
            keys: SyncKeyStore(keychain: keychain, cloudKeys: cloudKeys,
                               usesSnippetsCloud: { true }),
            device: store.deviceID,
            backendSelection: selection)
        store.syncDelegate = coordinator
        defer { coordinator.stop() }

        try await sync(coordinator)
        assertConfirmedRecordCount(confirmedRecordCount(for: phase))
        try await assertRemoteLibrary(selection, expected: remoteBeforeLocalMutation(for: phase))
        switch phase {
        case .macSeed:
            assertLibrary(store, expected: ["mac-e2e": Self.macInitial])

        case .iosSeed:
            assertLibrary(store, expected: ["mac-e2e": Self.macInitial])
            var snippet = try! store.addSnippet(
                name: "iOS E2E", content: Self.iosInitial, tags: ["integration", "ios"])
            snippet.keyword = "ios-e2e"
            snippet.isPinned = true
            store.update(snippet)
            try await sync(coordinator)
            assertConfirmedRecordCount(2)
            try await assertRemoteLibrary(selection, expected: [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
            ])
            assertLibrary(store, expected: [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
            ])

        case .macUpdateAndroid:
            assertLibrary(store, expected: [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
                "android-e2e": Self.androidInitial,
            ])
            var android = try XCTUnwrap(store.snippets.first {
                $0.normalizedKeyword == "android-e2e"
            })
            android.content = Self.androidFinal
            android.tags.append("edited-on-macos")
            store.update(android)
            try await sync(coordinator)
            assertConfirmedRecordCount(3)
            try await assertRemoteLibrary(selection, expected: [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
                "android-e2e": Self.androidFinal,
            ])
            assertLibrary(store, expected: [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
                "android-e2e": Self.androidFinal,
            ])

        case .iosUpdateMac:
            assertLibrary(store, expected: [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
                "android-e2e": Self.androidFinal,
            ])
            var mac = try XCTUnwrap(store.snippets.first {
                $0.normalizedKeyword == "mac-e2e"
            })
            mac.content = Self.macFinal
            mac.tags.append("edited-on-ios")
            store.update(mac)
            try await sync(coordinator)
            assertConfirmedRecordCount(3)
            try await assertRemoteLibrary(selection, expected: Self.convergedLibrary)
            assertConverged(store)

        case .macVerify, .iosVerify:
            assertConverged(store)

        case .macVerifyDeletion, .macChaosTruncatedFetch, .iosVerifyDeletion:
            assertLibrary(store, expected: Self.convergedAfterDeletion)
        }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(activeProtocolLocations).baseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(activeProtocolLocations).journalURL.path))
    }

    private func integrationEnvironment() throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        #if os(macOS)
        if environment["SNIPPETS_CLOUD_E2E"] != "1",
           let path = environment["SNIPPETS_CLOUD_E2E_CONFIG_PATH"],
           FileManager.default.fileExists(atPath: path) {
            let configuration = try JSONDecoder().decode(
                FileConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            environment["SNIPPETS_CLOUD_E2E"] = "1"
            environment["SNIPPETS_CLOUD_E2E_SERVER_URL"] = configuration.serverURL
            environment["SNIPPETS_CLOUD_E2E_ACCESS_TOKEN"] = configuration.accessToken
            environment["SNIPPETS_CLOUD_E2E_SPACE_ID"] = configuration.spaceID
            environment["SNIPPETS_CLOUD_E2E_SERVER_INSTANCE_ID"] =
                configuration.serverInstanceID
            environment["SNIPPETS_CLOUD_E2E_APPLE_PHASE"] = configuration.phase
        }
        #endif
        return environment
    }

    private func sync(_ coordinator: SyncCoordinator) async throws {
        let result = await coordinator.requestSync(trigger: .manual)
        guard case .completed(let state) = result else {
            return XCTFail("sync did not start: \(result)")
        }
        guard case .idle(let lastSync) = state, lastSync != nil else {
            return XCTFail("sync did not become idle after a successful round: \(state)")
        }
    }

    private func assertLibrary(_ store: SnippetStore, expected: [String: String]) {
        XCTAssertEqual(store.snippets.count, expected.count)
        let actual = Dictionary(uniqueKeysWithValues: store.snippets.map {
            ($0.normalizedKeyword, $0.content)
        })
        XCTAssertEqual(actual, expected)
    }

    private func assertConverged(_ store: SnippetStore) {
        assertLibrary(store, expected: Self.convergedLibrary)
    }

    private func assertConfirmedRecordCount(_ expected: Int) {
        guard let activeProtocolLocations,
              case .loaded(let base) = SyncBaseFile.load(
            from: activeProtocolLocations.baseURL) else {
            return XCTFail("sync base was not readable")
        }
        XCTAssertEqual(base.envelopes.count, expected)
    }

    private func assertRemoteLibrary(
        _ selection: SyncBackendSelectionStore,
        expected: [String: String]
    ) async throws {
        let transport = try selection.makeTransport()
        _ = try await transport.resolveAccountIdentity()
        let fetched = try await transport.fetchChanges(since: nil)
        let sealer = SnippetCryptoSealer(
            keyring: try SyncKeyStore.keyring(from: Self.portableSyncMaterial),
            scopeID: SyncKeyStore.account)
        let snippets = try fetched.records.filter { !$0.deleted }.compactMap {
            try WireCodec.open($0, using: sealer).plainSnippet
        }
        let actual = Dictionary(uniqueKeysWithValues: snippets.map {
            ($0.normalizedKeyword, $0.content)
        })
        XCTAssertEqual(actual, expected)
    }

    private func assertTruncatedFetchRecovers(
        _ selection: SyncBackendSelectionStore
    ) async throws {
        let transport = try selection.makeTransport()
        _ = try await transport.resolveAccountIdentity()
        do {
            _ = try await transport.fetchChanges(since: nil)
            XCTFail("the deterministic proxy did not truncate the first change page")
        } catch let failure as SyncTransportFailure {
            guard case .unreachable(let detail) = failure else {
                return XCTFail("unexpected truncated-response classification: \(failure)")
            }
            XCTAssertEqual(detail, "invalid_json_response")
        }

        let recovered = try await transport.fetchChanges(since: nil)
        XCTAssertTrue(recovered.isFullResync)
        XCTAssertFalse(recovered.hasMore)
        XCTAssertEqual(recovered.records.count, 3) // Two live records and one tombstone.
    }

    private func remoteBeforeLocalMutation(for phase: Phase) -> [String: String] {
        switch phase {
        case .macSeed:
            return ["mac-e2e": Self.macInitial]
        case .iosSeed:
            return ["mac-e2e": Self.macInitial]
        case .macUpdateAndroid:
            return [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
                "android-e2e": Self.androidInitial,
            ]
        case .iosUpdateMac:
            return [
                "mac-e2e": Self.macInitial,
                "ios-e2e": Self.iosInitial,
                "android-e2e": Self.androidFinal,
            ]
        case .macVerify, .iosVerify:
            return Self.convergedLibrary
        case .macVerifyDeletion, .macChaosTruncatedFetch, .iosVerifyDeletion:
            return Self.convergedAfterDeletion
        }
    }

    private func confirmedRecordCount(for phase: Phase) -> Int {
        switch phase {
        case .macVerifyDeletion, .macChaosTruncatedFetch, .iosVerifyDeletion:
            return 3 // Two live records plus the retained iOS tombstone.
        default:
            return remoteBeforeLocalMutation(for: phase).count
        }
    }

    private func requirePhaseForCurrentPlatform(_ phase: Phase) throws {
        #if os(macOS)
        let valid: Set<Phase> = [
            .macSeed, .macUpdateAndroid, .macVerify, .macVerifyDeletion,
            .macChaosTruncatedFetch,
        ]
        #else
        let valid: Set<Phase> = [
            .iosSeed, .iosUpdateMac, .iosVerify, .iosVerifyDeletion,
        ]
        #endif
        guard valid.contains(phase) else {
            throw XCTSkip("phase \(phase.rawValue) belongs to the other Apple platform")
        }
    }

    private static func macSnippet(content: String) -> Snippet {
        let timestamp = Date(timeIntervalSince1970: 1_786_579_200)
        return Snippet(
            id: UUID(uuidString: "a11ce001-0000-4000-8000-000000000001")!,
            name: "macOS E2E",
            keyword: "mac-e2e",
            content: content,
            tags: ["integration", "macos"],
            isEnabled: true,
            isPinned: true,
            createdAt: timestamp,
            updatedAt: timestamp)
    }

    private static let portableSyncMaterial =
        Data(repeating: 0x42, count: 32) + Data(repeating: 0x24, count: 32)
    private static let macInitial = "snippets-macos-e2e-initial-8d134f53"
    private static let macFinal = "snippets-macos-e2e-final-from-ios-8d134f53"
    private static let iosInitial = "snippets-ios-e2e-initial-91a8c211"
    private static let androidInitial = "snippets-android-e2e-initial-4f6c77f8"
    private static let androidFinal = "snippets-android-e2e-final-from-macos-4f6c77f8"
    private static let convergedLibrary = [
        "mac-e2e": macFinal,
        "ios-e2e": iosInitial,
        "android-e2e": androidFinal,
    ]
    private static let convergedAfterDeletion = [
        "mac-e2e": macFinal,
        "android-e2e": androidFinal,
    ]
}

// Opt-in protocol E2E: a real Linux recipient retains its private key in the VM,
// while this Apple app target signs the approval and seals the library material.
// All authority and request coordinates come from a disposable test fixture.
extension SnippetsCloudAppIntegrationTests {
    func testLiveDeviceApprovalForLinuxRecipient() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SNIPPETS_DEVICE_APPROVAL_E2E"] == "disposable-backend")
        let server = try XCTUnwrap(URL(string: try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_SERVER_URL"])))
        let space = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_SPACE_ID"])))
        let instance = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_SERVER_INSTANCE_ID"])))
        let token = try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_ACCESS_TOKEN"])
        let request = try LibraryKeyBootstrap.DeviceSignInRequest(
            qrPayload: try XCTUnwrap(env["SNIPPETS_DEVICE_REQUEST_QR"]))
        XCTAssertEqual(request.serverURL, server)
        let client = try SnippetsCloudBootstrapClient(
            baseURL: server, spaceID: space, serverInstanceID: instance, accessToken: { token })
        let material = Data(repeating: 0x42, count: 32) + Data(repeating: 0x24, count: 32)
        let bundle = try LibraryKeyBootstrap.PortableKeyBundle(material: material)
        let state = try await client.recoveryState()
        if state.recovery == nil {
            let recovery = try LibraryKeyBootstrap.createRecoveryEnvelope(
                for: bundle, serverURL: server, spaceID: space, keyEpoch: 1)
            _ = try await client.bootstrapLibraryKey(keyEpoch: 1, ciphertext: recovery.ciphertext, material: material)
        }
        try await client.verifyAuthority(material: material)
        let pairing = try await client.createPairing(
            recipientPublicKey: request.recipientPublicKey, nonce: request.nonce, expiresInSeconds: 300)
        XCTAssertEqual(pairing.authenticationTag, request.confirmationCode)
        let invitation = try LibraryKeyBootstrap.PairingInvitation(
            serverURL: server, spaceID: space, pairingID: pairing.pairingID,
            nonce: request.nonce, recipientPublicKey: request.recipientPublicKey,
            expiresAtEpochSeconds: Int64(pairing.expiresAt.timeIntervalSince1970))
        let ciphertext = try LibraryKeyBootstrap.seal(bundle, for: invitation)
        let approved = try await client.approvePairing(
            pairing.pairingID, publicKey: request.recipientPublicKey, nonce: request.nonce,
            ciphertext: ciphertext, material: material)
        XCTAssertEqual(approved.state, "approved")
        try await client.approveDeviceSignInRequest(request.requestID, pairingID: pairing.pairingID)
        // Lost acknowledgement: repeating the identical binding must remain idempotent.
        try await client.approveDeviceSignInRequest(request.requestID, pairingID: pairing.pairingID)
    }
}

// Stateful opt-in fault audit. The runner owns a disposable installation and keeps
// its library/checkpoint between processes so recovery cannot pass by starting fresh.
extension SnippetsCloudAppIntegrationTests {
    func testStatefulFaultAudit() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SNIPPETS_STATEFUL_AUDIT"] == "disposable-installation")
        let stage = try XCTUnwrap(env["SNIPPETS_AUDIT_STAGE"])
        let role = try XCTUnwrap(env["SNIPPETS_AUDIT_ROLE"])
        let run = try XCTUnwrap(env["SNIPPETS_AUDIT_RUN"])
        _ = try XCTUnwrap(UUID(uuidString: run))
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/SnippetsFaultAudit-" + run)
        let defaultsName = "SnippetsFaultAudit-" + run
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let previous = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
        let oldEnabled = SyncCoordinator.runtimeEnabledOverride
        SyncCoordinator.runtimeEnabledOverride = true
        defer {
            SyncCoordinator.runtimeEnabledOverride = oldEnabled
            if let previous { setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previous, 1) }
            else { unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey) }
        }
        SnippetStorageLocations.createAllDirectories()
        if !FileManager.default.fileExists(atPath: SnippetStorageLocations.snippetsFileURL.path) {
            var initial: [Snippet] = []
            if stage == "seed" {
                for (index, keyword) in ["race", "fields", "delete-edit"].enumerated() {
                    initial.append(Snippet(id: UUID(uuidString: String(format: "a11ce002-0000-4000-8000-%012d", index + 1))!,
                        name: keyword, keyword: keyword, content: "audit-original-" + keyword,
                        tags: ["audit"], isEnabled: true, isPinned: false,
                        createdAt: Date(timeIntervalSince1970: 1_786_579_200), updatedAt: Date(timeIntervalSince1970: 1_786_579_200)))
                }
            }
            try SnippetLibraryCodec.encode(initial).write(to: SnippetStorageLocations.snippetsFileURL, options: .atomic)
        }
        let serverText = try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_SERVER_URL"])
        let spaceText = try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_SPACE_ID"])
        let serverInstanceText = try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_SERVER_INSTANCE_ID"])
        let token = try XCTUnwrap(env["SNIPPETS_CLOUD_E2E_ACCESS_TOKEN"])
        let keychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        try keychain.storeItem(Self.portableSyncMaterial, account: SyncKeyStore.account)
        let serverURL = try XCTUnwrap(URL(string: serverText))
        let spaceID = try XCTUnwrap(UUID(uuidString: spaceText))
        let serverInstanceID = try XCTUnwrap(UUID(uuidString: serverInstanceText))
        let cloudKeys = SnippetsCloudKeyStore(
            keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            coordinates: {
                .init(serverURL: serverURL, apiBaseURL: serverURL.appending(path: "v2"),
                      spaceID: spaceID, serverInstanceID: serverInstanceID, protocolMajor: 2)
            })
        // The portable fixture is explicit test authority, never the user's shared
        // iCloud or device Cloud key. Exercise the production provider key selector.
        try cloudKeys.install(Self.portableSyncMaterial, serverURL: serverURL,
                              spaceID: spaceID, serverInstanceID: serverInstanceID,
                              protocolMajor: 2)
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: keychain,
            cloudKeys: cloudKeys,
            bootstrapSecrets: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            snippetsCloudEnabled: true)
        try selection.selectSnippetsCloud(
            serverURL: serverURL,
            spaceID: spaceID,
            serverInstanceID: serverInstanceID,
            accessToken: token)
        activeProtocolLocations = try selection.protocolLocations()
        defer { activeProtocolLocations = nil }
        XCTAssertTrue(try selection.makeTransport().supportsPush)

        #if os(macOS)
        let store = SnippetStore(configuration: .macOSDefault)
        #else
        let store = SnippetStore(configuration: .iOS)
        #endif
        let vaultSession = VaultSession(
            keychain: keychain,
            authenticationEvaluator: { _ in true })
        let secureStore = SecureSnippetStore(
            session: vaultSession,
            keychain: keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        let library = SnippetLibraryBridge(store: store, secureStore: secureStore)
        let coordinator = SyncCoordinator(
            library: library,
            keys: SyncKeyStore(keychain: keychain, cloudKeys: cloudKeys,
                               usesSnippetsCloud: { true }),
            device: store.deviceID,
            backendSelection: selection)
        store.syncDelegate = coordinator
        defer { coordinator.stop() }


        if stage == "prepare" {
            try await sync(coordinator)
            XCTAssertEqual(store.snippets.count, 3)
            // stop() alone can schedule a replacement transport after shutdown.
            // Disable the runtime and detach mutations for a real offline phase.
            SyncCoordinator.runtimeEnabledOverride = false
            coordinator.stop()
            store.syncDelegate = nil
            var race = try XCTUnwrap(store.snippets.first { $0.keyword == "race" })
            race.content = "audit-concurrent-" + role
            XCTAssertTrue(store.update(race))
            var fields = try XCTUnwrap(store.snippets.first { $0.keyword == "fields" })
            if role == "macos" { fields.name = "audit-name-macos" }
            if role == "iphone" { fields.isPinned = true }
            if role == "ipad" { fields.tags.append("audit-ipad") }
            XCTAssertTrue(store.update(fields))
            if role == "iphone" {
                var edited = try XCTUnwrap(store.snippets.first { $0.keyword == "delete-edit" })
                edited.content = "audit-edit-survives-delete"
                XCTAssertTrue(store.update(edited))
            }
            try store.flushPendingWritesForSync()
        } else if stage == "switch" {
            var edited = try XCTUnwrap(store.snippets.first { $0.keyword == "fields" })
            edited.content = "audit-account-switch-" + role
            XCTAssertTrue(store.update(edited))
            try store.flushPendingWritesForSync()
            let round = Task { await coordinator.requestSync(trigger: .manual) }
            let signal = root.appendingPathComponent("switch-now")
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: signal.path) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: signal.path))
            SyncCoordinator.runtimeEnabledOverride = false
            let nextSpace = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(env["SNIPPETS_AUDIT_NEXT_SPACE"])))
            let nextToken = try XCTUnwrap(env["SNIPPETS_AUDIT_NEXT_TOKEN"])
            try await coordinator.withQuiescedCloudTransport {
                try selection.selectSnippetsCloud(serverURL: serverURL, spaceID: nextSpace,
                    serverInstanceID: serverInstanceID, accessToken: nextToken)
            }
            _ = await round.value
            XCTAssertTrue(coordinator.isQuiescent)
            let nextTransport = try selection.makeTransport()
            _ = try await nextTransport.resolveAccountIdentity()
            let nextPage = try await nextTransport.fetchChanges(since: nil)
            XCTAssertTrue(nextPage.records.isEmpty)
            await nextTransport.shutdown()
            let locations = try XCTUnwrap(activeProtocolLocations)
            let oldBase = try? Data(contentsOf: locations.baseURL)
            let oldJournal = try? Data(contentsOf: locations.journalURL)
            try Data().write(to: root.appendingPathComponent("switch-completed"))
            try await Task.sleep(for: .seconds(2))
            XCTAssertEqual(try? Data(contentsOf: locations.baseURL), oldBase)
            XCTAssertEqual(try? Data(contentsOf: locations.journalURL), oldJournal)
        } else {
            if stage == "crash" {
                var fields = try XCTUnwrap(store.snippets.first { $0.keyword == "fields" })
                fields.content = "audit-crash-" + role
                XCTAssertTrue(store.update(fields))
                try store.flushPendingWritesForSync()
            }
            try await sync(coordinator)
            try store.flushPendingWritesForSync()
        }
        let snapshot = store.snippets.map { s -> [String: Any] in
            ["id": s.id.uuidString.lowercased(), "keyword": s.keyword, "name": s.name,
             "content": s.content, "tags": s.tags.sorted(), "isPinned": s.isPinned, "isEnabled": s.isEnabled]
        }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]).write(to: root.appendingPathComponent("audit-snapshot.json"), options: .atomic)
    }
}
