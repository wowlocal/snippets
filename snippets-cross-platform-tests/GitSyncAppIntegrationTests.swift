import CryptoKit
import Foundation
import XCTest
#if os(macOS)
@testable import Snippets_Debug
#else
@testable import Snippets
#endif

/// Opt-in, multi-process Git sync integration test driven by
/// `scripts/test-git-sync-integration.sh`.
///
/// Every phase is a fresh installation (temporary support directory, fresh defaults,
/// in-memory keychains) running the production store, bridge, coordinator and
/// `GitSyncSetup` against one disposable repository served by the real
/// `git http-backend`. A later phase therefore proves the other platform can consume
/// the earlier one's durable result, including the recovery-code key handoff. Secure
/// snippets take part: each platform reads the other's with nothing but that code.
@MainActor
final class GitSyncAppIntegrationTests: XCTestCase {
    private struct Configuration: Decodable {
        let repositoryURL: String
        let username: String
        let token: String
        let phase: String
        let recoveryCode: String?
        /// The code `recoveryCode` replaced, which must no longer open the library.
        var previousRecoveryCode: String? = nil
        let handoffPath: String?
        /// Defaults to `main`; hosted runs use a fresh branch per run.
        var branch: String? = nil
        /// SSH phases on macOS: a private ssh configuration and agent socket, so the
        /// system ssh never reads the user's own configuration, keys or agent. Without a
        /// configuration (a run against a real host) the user's own ssh setup is used,
        /// exactly as the app does.
        var sshConfigPath: String? = nil
        var sshAgentSocket: String? = nil
        /// SSH phases on iOS: the device key the test sshd authorizes (PEM, base64) and
        /// the host key fingerprint(s), comma-separated, the user would be asked to confirm.
        var sshDeviceKey: String? = nil
        var sshHostFingerprint: String? = nil
    }

    private enum Phase: String {
        case macCreate = "mac-create"
        case iosJoin = "ios-join"
        case macJoin = "mac-join"
        case iosVerify = "ios-verify"
        /// After the iOS UI test created a library through Settings: join it with the
        /// code the UI copied and find the snippet typed into the UI.
        case macVerifyUI = "mac-verify-ui"
        /// Over SSH: the system ssh with an agent-held key creates a library, the iOS
        /// SwiftNIO client joins with its device key after trusting the host key, and a
        /// fresh Mac sees the iOS edit.
        case macSSHCreate = "mac-ssh-create"
        case iosSSHJoin = "ios-ssh-join"
        case macSSHVerify = "mac-ssh-verify"
        /// A plain-text library: macOS creates it, iOS joins and adds a snippet, the
        /// script edits the macOS snippet's Markdown file with plain git, and a fresh Mac
        /// sees the edit.
        case macPlainCreate = "mac-plain-create"
        case iosPlainJoin = "ios-plain-join"
        case macPlainVerify = "mac-plain-verify"
        /// Replacing the keys: a Mac joins, replaces them and hands over the new
        /// recovery code; a fresh iOS installation is refused with the old code and
        /// opens everything, secure snippets included, with the new one.
        case macRotate = "mac-rotate"
        case iosRotated = "ios-rotated"
    }

    func testGitSyncPhase() async throws {
        let configuration = try loadConfiguration()
        let phase = try XCTUnwrap(Phase(rawValue: configuration.phase))
        #if os(macOS)
        guard [.macCreate, .macJoin, .macVerifyUI, .macSSHCreate, .macSSHVerify, .macPlainCreate, .macPlainVerify,
               .macRotate].contains(phase) else {
            throw XCTSkip("iOS phase")
        }
        #else
        guard [.iosJoin, .iosVerify, .iosSSHJoin, .iosPlainJoin, .iosRotated].contains(phase) else {
            throw XCTSkip("macOS phase")
        }
        #endif
        let usesSSH = [.macSSHCreate, .iosSSHJoin, .macSSHVerify].contains(phase)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitSyncAppE2E-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "GitSyncAppE2E-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let previousSupportDirectory = ProcessInfo.processInfo.environment[
            SnippetStorageLocations.rootOverrideEnvironmentKey]
        let previousRuntimeEnabledOverride = SyncCoordinator.runtimeEnabledOverride
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
        SyncCoordinator.runtimeEnabledOverride = true
        defer {
            SyncCoordinator.runtimeEnabledOverride = previousRuntimeEnabledOverride
            if let previousSupportDirectory {
                setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousSupportDirectory, 1)
            } else {
                unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
            }
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }

        SnippetStorageLocations.createAllDirectories()
        let initial = [.macCreate, .macSSHCreate, .macPlainCreate].contains(phase) ? [Self.macSnippet] : []
        try SnippetLibraryCodec.encode(initial).write(
            to: SnippetStorageLocations.snippetsFileURL, options: .atomic)

        let keychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        let ssh = usesSSH ? try sshSupport(configuration, defaults: defaults) : nil
        let selection = SyncBackendSelectionStore(
            defaults: defaults,
            keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            bootstrapSecrets: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            snippetsCloudEnabled: false,
            gitKeys: GitSyncKeyStore(keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true)),
            gitCredentials: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            gitAllowsInsecureLoopback: true,
            gitSSH: ssh)
        XCTAssertEqual(selection.provider, .iCloud)
        XCTAssertTrue(selection.availableProviders.contains(.git))

        #if os(macOS)
        let store = SnippetStore(configuration: .macOSDefault)
        #else
        let store = SnippetStore(configuration: .iOS)
        #endif
        let vaultSession = VaultSession(keychain: keychain, authenticationEvaluator: { _ in true })
        let secureStore = SecureSnippetStore(
            session: vaultSession, keychain: keychain,
            selectedSyncProvider: { selection.provider }, deviceID: store.deviceID)
        store.secureProvider = secureStore
        let library = SnippetLibraryBridge(store: store, secureStore: secureStore)
        let coordinator = SyncCoordinator(
            library: library,
            keys: SyncKeyStore(
                keychain: keychain,
                gitKeys: selection.gitKeys,
                gitScope: { selection.provider == .git ? .some(selection.gitCoordinates?.keyScope) : nil }),
            device: store.deviceID,
            backendSelection: selection)
        store.syncDelegate = coordinator
        defer { coordinator.stop() }

        let setup = GitSyncSetup(selection: selection, coordinator: coordinator)
        defer { setup.finish() }
        let branch = configuration.branch ?? "main"
        let form = usesSSH
            ? GitSyncSetup.Form(repositoryURL: configuration.repositoryURL, branch: branch)
            : GitSyncSetup.Form(
                repositoryURL: configuration.repositoryURL, branch: branch,
                username: configuration.username, token: configuration.token)
        XCTAssertEqual(form.usesSSH, usesSSH)

        if phase == .iosSSHJoin {
            // The first connection meets an untrusted host key, exactly as Settings does,
            // and offers its fingerprint for confirmation.
            do {
                _ = try await setup.inspect(form)
                return XCTFail("an untrusted host key must stop the first connection")
            } catch let failure as GitSyncSetup.Failure {
                guard case .sshHostKeyUnknown(let host) = failure else { return XCTFail("\(failure)") }
                let expected = try XCTUnwrap(setup.sshHost(form))
                XCTAssertEqual(host, expected)
                if let port = expected.port, port != 22 {
                    XCTAssertEqual(host.label, "[\(expected.host)]:\(port)", "a non-standard port is part of the label")
                }
            }
            let presented = try XCTUnwrap(setup.presentedHostKey(form))
            let fingerprints = try XCTUnwrap(configuration.sshHostFingerprint).split(separator: ",").map(String.init)
            XCTAssertTrue(fingerprints.contains(presented.fingerprint),
                          "presented \(presented.fingerprint), expected one of \(fingerprints)")
            XCTAssertFalse(presented.replacesTrustedKey)
            XCTAssertFalse(setup.trustPresentedHostKey(form, fingerprint: "SHA256:not-the-presented-key"))
            XCTAssertTrue(setup.trustPresentedHostKey(form, fingerprint: presented.fingerprint))
            XCTAssertTrue(try XCTUnwrap(setup.devicePublicKey()).hasPrefix("ecdsa-sha2-nistp256 "))
        }

        // 1. Connect through the same steps Settings performs.
        let inspection = try await setup.inspect(form)
        switch phase {
        case .macCreate, .macSSHCreate, .macPlainCreate:
            XCTAssertEqual(inspection, .empty)
            let mode: GitLibraryMode = phase == .macPlainCreate ? .plainText : .encrypted
            guard case .created(let code) = try await setup.createLibrary(form, mode: mode) else {
                return XCTFail("an empty branch must become a new library")
            }
            XCTAssertNoThrow(try GitSyncRecovery.Kit(code: code, datasetID: UUID()))
            let handoff = try XCTUnwrap(configuration.handoffPath)
            try JSONEncoder().encode(["recoveryCode": code]).write(
                to: URL(fileURLWithPath: handoff), options: .atomic)
        case .iosJoin, .macJoin, .iosVerify, .macVerifyUI, .iosSSHJoin, .macSSHVerify, .iosPlainJoin, .macPlainVerify,
             .macRotate, .iosRotated:
            guard case .library(let datasetID, let keyAvailable, let recoveryAvailable, let mode) = inspection else {
                return XCTFail("expected an existing library, found \(inspection)")
            }
            XCTAssertFalse(keyAvailable, "a fresh installation cannot already hold the key")
            XCTAssertEqual(mode, [.iosPlainJoin, .macPlainVerify].contains(phase) ? .plainText : .encrypted)
            XCTAssertTrue(recoveryAvailable)
            let code = try XCTUnwrap(configuration.recoveryCode)
            if phase == .iosJoin {
                // A different well-formed code is refused before anything is saved.
                let wrong = GitSyncRecovery.Kit(datasetID: datasetID).code
                do {
                    _ = try await setup.connect(form, datasetID: datasetID, recoveryCode: wrong, mode: mode)
                    XCTFail("a wrong recovery code opened the library")
                } catch let failure as GitSyncSetup.Failure {
                    XCTAssertEqual(failure, .incorrectRecoveryCode)
                }
                XCTAssertNil(selection.gitCoordinates)
            }
            if phase == .iosRotated {
                // The code the keys were replaced under opens nothing any more.
                let previous = try XCTUnwrap(configuration.previousRecoveryCode)
                XCTAssertNotEqual(previous, code)
                do {
                    _ = try await setup.connect(form, datasetID: datasetID, recoveryCode: previous, mode: mode)
                    XCTFail("the replaced recovery code opened the library")
                } catch let failure as GitSyncSetup.Failure {
                    XCTAssertEqual(failure, .incorrectRecoveryCode)
                }
                XCTAssertNil(selection.gitCoordinates)
            }
            let outcome = try await setup.connect(form, datasetID: datasetID, recoveryCode: code, mode: mode)
            XCTAssertEqual(outcome, .connected)
        }
        XCTAssertTrue(selection.gitIsReady)
        if [.macPlainCreate, .iosPlainJoin, .macPlainVerify].contains(phase) {
            XCTAssertEqual(selection.gitCoordinates?.mode, .plainText)
        }
        if usesSSH {
            XCTAssertEqual(selection.gitCoordinates?.usesSSH, true)
            XCTAssertNil(try selection.storedGitToken(), "SSH stores no token")
        }

        // 2. The explicit Switch and Sync.
        let switched = await coordinator.switchProvider(to: .git)
        guard case .completed(.idle(let lastSync)) = switched, lastSync != nil else {
            return XCTFail("switching to Git did not complete a sync: \(switched) · \(coordinator.statusDescription)")
        }
        XCTAssertEqual(selection.provider, .git)

        // 3. Phase-specific edits and checks, local and remote.
        switch phase {
        case .macCreate:
            assertLibrary(store, ["mac-git": Self.macInitial])
            try await addSecure("mac-secure", Self.macSecure, secureStore, vaultSession)
            try await sync(coordinator)
            try await assertRemote(selection, ["mac-git": Self.macInitial])

        case .iosJoin:
            assertLibrary(store, ["mac-git": Self.macInitial])
            // The recovery code alone brought the vault key: the Mac's secret opens here.
            try await assertSecure(["mac-secure": Self.macSecure], secureStore, vaultSession)
            try await addSecure("ios-secure", Self.iosSecure, secureStore, vaultSession)
            var snippet = try store.addSnippet(name: "iOS Git", content: Self.iosInitial, tags: ["git"])
            snippet.keyword = "ios-git"
            store.update(snippet)
            var mac = try XCTUnwrap(store.snippets.first { $0.normalizedKeyword == "mac-git" })
            mac.content = Self.macEditedOnIOS
            store.update(mac)
            try await sync(coordinator)
            assertLibrary(store, ["mac-git": Self.macEditedOnIOS, "ios-git": Self.iosInitial])
            try await assertRemote(selection, ["mac-git": Self.macEditedOnIOS, "ios-git": Self.iosInitial])

        case .macJoin:
            assertLibrary(store, ["mac-git": Self.macEditedOnIOS, "ios-git": Self.iosInitial])
            try await assertSecure(
                ["mac-secure": Self.macSecure, "ios-secure": Self.iosSecure], secureStore, vaultSession)
            let ios = try XCTUnwrap(store.snippets.first { $0.normalizedKeyword == "ios-git" })
            XCTAssertTrue(store.delete(snippetID: ios.id))
            try await sync(coordinator)
            assertLibrary(store, ["mac-git": Self.macEditedOnIOS])
            try await assertRemote(selection, ["mac-git": Self.macEditedOnIOS])

        case .iosVerify:
            assertLibrary(store, ["mac-git": Self.macEditedOnIOS])
            try await assertSecure(
                ["mac-secure": Self.macSecure, "ios-secure": Self.iosSecure], secureStore, vaultSession)

        case .macVerifyUI:
            XCTAssertEqual(store.snippets.map(\.name), ["Git UI Greeting"])
            XCTAssertEqual(store.snippets.map(\.content), ["Hello from the Git settings UI 4c9e"])

        case .macSSHCreate:
            assertLibrary(store, ["mac-git": Self.macInitial])
            try await assertRemote(selection, ["mac-git": Self.macInitial])

        case .iosSSHJoin:
            assertLibrary(store, ["mac-git": Self.macInitial])
            var snippet = try store.addSnippet(name: "iOS SSH", content: Self.iosOverSSH, tags: ["git"])
            snippet.keyword = "ios-ssh"
            store.update(snippet)
            try await sync(coordinator)
            try await assertRemote(selection, ["mac-git": Self.macInitial, "ios-ssh": Self.iosOverSSH])

        case .macSSHVerify:
            assertLibrary(store, ["mac-git": Self.macInitial, "ios-ssh": Self.iosOverSSH])

        case .macPlainCreate:
            assertLibrary(store, ["mac-git": Self.macInitial])
            try await addSecure("mac-secure", Self.macSecure, secureStore, vaultSession)
            try await sync(coordinator)
            try await assertRemote(selection, ["mac-git": Self.macInitial])

        case .iosPlainJoin:
            assertLibrary(store, ["mac-git": Self.macInitial])
            try await assertSecure(["mac-secure": Self.macSecure], secureStore, vaultSession)
            var snippet = try store.addSnippet(name: "iOS Plain", content: Self.iosPlain, tags: ["git"])
            snippet.keyword = "ios-plain"
            store.update(snippet)
            try await sync(coordinator)
            try await assertRemote(selection, ["mac-git": Self.macInitial, "ios-plain": Self.iosPlain])

        case .macPlainVerify:
            assertLibrary(store, ["mac-git": Self.macEditedInGit, "ios-plain": Self.iosPlain])
            try await assertSecure(["mac-secure": Self.macSecure], secureStore, vaultSession)

        case .macRotate:
            assertLibrary(store, ["mac-git": Self.macEditedOnIOS])
            let before = try XCTUnwrap(selection.gitCoordinates)
            let oldVault = try XCTUnwrap(secureStore.document?.kid)
            let newCode = try await setup.rotateKeys()
            XCTAssertNotEqual(newCode, configuration.recoveryCode)
            let after = try XCTUnwrap(selection.gitCoordinates)
            XCTAssertNotEqual(after.datasetID, before.datasetID)
            XCTAssertFalse(selection.gitKeys.hasMaterial(for: before.keyScope))
            XCTAssertNotEqual(secureStore.document?.kid, oldVault)
            try JSONEncoder().encode(["recoveryCode": newCode]).write(
                to: URL(fileURLWithPath: try XCTUnwrap(configuration.handoffPath)), options: .atomic)
            try await sync(coordinator)
            try await assertRemote(selection, ["mac-git": Self.macEditedOnIOS])
            try await assertSecure(
                ["mac-secure": Self.macSecure, "ios-secure": Self.iosSecure], secureStore, vaultSession)

        case .iosRotated:
            assertLibrary(store, ["mac-git": Self.macEditedOnIOS])
            try await assertSecure(
                ["mac-secure": Self.macSecure, "ios-secure": Self.iosSecure], secureStore, vaultSession)
        }
    }

    private func sshSupport(_ configuration: Configuration, defaults: UserDefaults) throws -> GitSSHSupport {
        #if os(macOS)
        guard let config = configuration.sshConfigPath else {
            return GitSSHSupport(
                connector: GitSystemSSHConnector(agentSocket: configuration.sshAgentSocket), device: nil)
        }
        return GitSSHSupport(
            connector: GitSystemSSHConnector(
                options: ["-F", config],
                agentSocket: try XCTUnwrap(configuration.sshAgentSocket), timeout: 60, sharesConnections: false),
            device: nil)
        #else
        let pem = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(configuration.sshDeviceKey)).flatMap { String(data: $0, encoding: .utf8) })
        let identity = GitSSHDeviceIdentity(
            keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            hostKeys: GitSSHHostKeyStore(defaults: defaults), allowsSecureEnclave: false)
        try identity.installSoftwareKeyForTesting(try P256.Signing.PrivateKey(pemRepresentation: pem))
        return GitSSHSupport(connector: GitNIOSSHConnector(identity: identity, timeout: .seconds(60)), device: identity)
        #endif
    }

    // MARK: - Helpers

    private func loadConfiguration() throws -> Configuration {
        let environment = ProcessInfo.processInfo.environment
        #if os(macOS)
        let path = environment["SNIPPETS_GIT_E2E_CONFIG_PATH"] ?? "/tmp/snippets-git-sync-e2e-macos.json"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Run scripts/test-git-sync-integration.sh for the Git sync integration test")
        }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #else
        guard environment["SNIPPETS_GIT_E2E"] == "1" else {
            throw XCTSkip("Run scripts/test-git-sync-integration.sh for the Git sync integration test")
        }
        return Configuration(
            repositoryURL: try XCTUnwrap(environment["SNIPPETS_GIT_E2E_URL"]),
            username: try XCTUnwrap(environment["SNIPPETS_GIT_E2E_USERNAME"]),
            token: try XCTUnwrap(environment["SNIPPETS_GIT_E2E_TOKEN"]),
            phase: try XCTUnwrap(environment["SNIPPETS_GIT_E2E_PHASE"]),
            recoveryCode: environment["SNIPPETS_GIT_E2E_RECOVERY_CODE"],
            previousRecoveryCode: environment["SNIPPETS_GIT_E2E_PREVIOUS_CODE"].flatMap { $0.isEmpty ? nil : $0 },
            handoffPath: nil,
            branch: environment["SNIPPETS_GIT_E2E_BRANCH"].flatMap { $0.isEmpty ? nil : $0 },
            sshDeviceKey: environment["SNIPPETS_GIT_E2E_SSH_DEVICE_KEY"],
            sshHostFingerprint: environment["SNIPPETS_GIT_E2E_SSH_HOST_FINGERPRINT"])
        #endif
    }

    private func sync(_ coordinator: SyncCoordinator) async throws {
        let result = await coordinator.requestSync(trigger: .manual)
        guard case .completed(.idle(let lastSync)) = result, lastSync != nil else {
            return XCTFail("sync did not complete: \(result) · \(coordinator.statusDescription)")
        }
    }

    private func addSecure(
        _ keyword: String, _ body: String, _ secureStore: SecureSnippetStore, _ session: VaultSession
    ) async throws {
        _ = try await session.unlock(reason: "integration test")
        _ = try secureStore.addSecure(
            name: "Secure \(keyword)", keyword: keyword, body: Data(body.utf8), tags: [],
            isEnabled: true, isPinned: false)
    }

    /// Secure snippets by keyword, decrypted with the vault key this installation holds.
    private func assertSecure(
        _ expected: [String: String], _ secureStore: SecureSnippetStore, _ session: VaultSession,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertEqual(secureStore.libraryVaultAvailability, .ready, file: file, line: line)
        _ = try await session.unlock(reason: "integration test")
        var actual: [String: String] = [:]
        for shell in secureStore.shells {
            actual[shell.normalizedKeyword] = try secureStore.content(for: shell.id)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertLibrary(
        _ store: SnippetStore, _ expected: [String: String], file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = Dictionary(uniqueKeysWithValues: store.snippets.map { ($0.normalizedKeyword, $0.content) })
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    /// Decrypts the repository's current records with the library key and compares
    /// live snippets. Tombstones stay as records; they are excluded here.
    private func assertRemote(
        _ selection: SyncBackendSelectionStore, _ expected: [String: String],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let coordinates = try XCTUnwrap(selection.gitCoordinates)
        let material = try XCTUnwrap(try selection.gitKeys.material(for: coordinates.keyScope))
        let transport = try selection.makeTransport()
        _ = try await transport.preflightScope()
        let fetched = try await transport.fetchChanges(since: nil)
        await transport.shutdown()
        let sealer = SnippetCryptoSealer(
            keyring: try SyncKeyStore.keyring(from: material), scopeID: SyncKeyStore.account)
        let snippets = try fetched.records.filter { !$0.deleted }.compactMap {
            try WireCodec.open($0, using: sealer).plainSnippet
        }
        let actual = Dictionary(uniqueKeysWithValues: snippets.map { ($0.normalizedKeyword, $0.content) })
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private static let macSnippet = Snippet(
        id: UUID(uuidString: "617a0001-0000-4000-8000-000000000001")!,
        name: "macOS Git",
        keyword: "mac-git",
        content: macInitial,
        tags: ["integration", "git"],
        isEnabled: true,
        isPinned: false,
        createdAt: Date(timeIntervalSince1970: 1_786_579_200),
        updatedAt: Date(timeIntervalSince1970: 1_786_579_200))
    static let macInitial = "snippets-git-macos-initial-5c2e91d0"
    static let iosInitial = "snippets-git-ios-initial-7f03ab64"
    static let macEditedOnIOS = "snippets-git-macos-edited-on-ios-0d6e44a9"
    static let iosOverSSH = "snippets-git-ios-over-ssh-91b7e2c4"
    static let iosPlain = "snippets-git-ios-plain-2d8b5f13"
    static let macEditedInGit = "snippets-git-macos-edited-in-git-3a7c19e0"
    static let macSecure = "snippets-git-macos-secure-b41f07c6"
    static let iosSecure = "snippets-git-ios-secure-e95a3d28"
}
