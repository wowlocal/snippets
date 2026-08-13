import CryptoKit
import Foundation
import XCTest
#if os(macOS)
@testable import Snippets_Debug
#else
@testable import Snippets
#endif

/// Opt-in, multi-process integration test used by `scripts/test-cross-platform-sync.sh`.
///
/// Every invocation gets a fresh local installation but shares one disposable server
/// space with the other platforms. That makes a successful phase prove that the
/// production store/bridge/coordinator stack can consume the previous client's durable
/// result, not merely an in-process fixture.
@MainActor
final class SnippetsCloudAppIntegrationTests: XCTestCase {
    private struct FileConfiguration: Decodable {
        let serverURL: String
        let accessToken: String
        let spaceID: String
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
        let selection = SyncBackendSelectionStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(selection.provider, .iCloud)
        try selection.selectSnippetsCloud(
            serverURL: try XCTUnwrap(URL(string: serverText)),
            spaceID: try XCTUnwrap(UUID(uuidString: spaceText)),
            accessToken: token)
        XCTAssertTrue(try selection.makeTransport().supportsPush)
        XCTAssertTrue(selection.hasPendingProviderSwitch)
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
            keys: SyncKeyStore(keychain: keychain),
            device: store.deviceID,
            backendSelection: selection)
        store.syncDelegate = coordinator
        defer { coordinator.stop() }

        try await sync(coordinator)
        XCTAssertFalse(selection.hasPendingProviderSwitch)
        assertConfirmedRecordCount(confirmedRecordCount(for: phase))
        try await assertRemoteLibrary(selection, expected: remoteBeforeLocalMutation(for: phase))
        switch phase {
        case .macSeed:
            assertLibrary(store, expected: ["mac-e2e": Self.macInitial])

        case .iosSeed:
            assertLibrary(store, expected: ["mac-e2e": Self.macInitial])
            var snippet = store.addSnippet(
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
            atPath: SnippetStorageLocations.syncBaseFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncJournalFileURL.path))
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
        guard case .loaded(let base) = SyncBaseFile.load(
            from: SnippetStorageLocations.syncBaseFileURL) else {
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
