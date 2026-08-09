import CryptoKit
import UIKit
import XCTest
@testable import Snippets

@MainActor
final class SecureRemediationTests: XCTestCase {
    private var rootURL: URL!
    private var previousSyncPreference: Any?

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureRemediationTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey)
        UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(previousSyncPreference, forKey: SyncCoordinator.enabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        previousSyncPreference = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testPreparedVaultCreationWritesNothingUntilAcknowledgedAndCancelIsFinal() throws {
        let components = makeComponents()

        let cancelled = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        XCTAssertFalse(components.secureStore.hasVault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))

        cancelled.cancel()
        XCTAssertThrowsError(try components.secureStore.commitVaultCreation(cancelled))
        XCTAssertFalse(components.secureStore.hasVault)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))

        let acknowledged = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        let document = try components.secureStore.commitVaultCreation(acknowledged)

        XCTAssertTrue(components.secureStore.hasVault)
        XCTAssertTrue(components.secureStore.hasRecoveryKey)
        XCTAssertTrue(components.keychain.hasKey(keyID: document.kid))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SnippetStorageLocations.vaultFileURL.path))
    }

    func testPromoteAndDemoteReloadBothStoresWithoutPlaintextResurrection() async throws {
        let components = makeComponents()
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)

        let original = components.store.addSnippet(
            name: "Transition Test",
            content: "stale body")
        var latest = original
        latest.keyword = "transition-test"
        latest.content = "LATEST-PENDING-PLAINTEXT-SENTINEL"
        components.store.update(latest) // Deliberately leave the debounce pending.

        _ = try await components.session.unlock(reason: "Test promotion")
        try SecureSnippetTransitionCoordinator.promote(
            snippetID: original.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertNil(components.store.snippet(id: original.id))
        XCTAssertTrue(components.secureStore.isSecure(original.id))
        XCTAssertFalse(components.store.enabledSnippetsSorted().contains { $0.id == original.id })

        let ordinaryBytesAfterPromotion = try Data(
            contentsOf: SnippetStorageLocations.snippetsFileURL)
        let ordinaryTextAfterPromotion = String(decoding: ordinaryBytesAfterPromotion, as: UTF8.self)
        XCTAssertFalse(ordinaryTextAfterPromotion.contains("LATEST-PENDING-PLAINTEXT-SENTINEL"))
        XCTAssertFalse(ordinaryTextAfterPromotion.contains(original.id.uuidString))

        let exportURL = rootURL.appendingPathComponent("ordinary-export.json")
        XCTAssertEqual(try components.store.exportSnippets(to: exportURL), 0)
        let exportText = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertFalse(exportText.contains("LATEST-PENDING-PLAINTEXT-SENTINEL"))
        XCTAssertFalse(exportText.contains(original.id.uuidString))

        _ = try await components.session.unlock(reason: "Test secure content")
        XCTAssertEqual(
            try components.secureStore.content(for: original.id),
            "LATEST-PENDING-PLAINTEXT-SENTINEL")
        try components.secureStore.setContent(
            "LATEST-SECURE-EDIT-SENTINEL",
            for: original.id)

        try SecureSnippetTransitionCoordinator.demote(
            recordID: original.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertFalse(components.secureStore.isSecure(original.id))
        XCTAssertEqual(
            components.store.snippet(id: original.id)?.content,
            "LATEST-SECURE-EDIT-SENTINEL")
        XCTAssertFalse(components.secureStore.document?.records.contains {
            $0.id == original.id
        } == true)
    }

    func testCoordinatedMovesPublishOnceOnlyAfterBothCachesAgreeOnOwnership() async throws {
        let components = makeComponents()
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)
        let snippet = components.store.addSnippet(
            name: "Atomic transition",
            content: "body")
        components.store.flushPendingWrites()
        _ = try await components.session.unlock(reason: "Test atomic transition")

        var observedOwnership: [(ordinary: Bool, secure: Bool)] = []
        var syncChangeCount = 0
        components.store.onChange = { _ in
            observedOwnership.append((
                ordinary: components.store.snippet(id: snippet.id) != nil,
                secure: components.secureStore.isSecure(snippet.id)))
        }
        // Match AppEnvironment's production wiring: one secure structural change
        // refreshes the merged library and requests one sync round.
        components.secureStore.onChange = {
            components.store.onChange?(.local)
            syncChangeCount += 1
        }

        try SecureSnippetTransitionCoordinator.promote(
            snippetID: snippet.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertEqual(observedOwnership.count, 1)
        XCTAssertEqual(observedOwnership.first?.ordinary, false)
        XCTAssertEqual(observedOwnership.first?.secure, true)
        XCTAssertEqual(syncChangeCount, 1)

        observedOwnership.removeAll()
        syncChangeCount = 0
        _ = try await components.session.unlock(reason: "Test atomic demotion")
        try SecureSnippetTransitionCoordinator.demote(
            recordID: snippet.id,
            store: components.store,
            secureStore: components.secureStore)

        XCTAssertEqual(observedOwnership.count, 1)
        XCTAssertEqual(observedOwnership.first?.ordinary, true)
        XCTAssertEqual(observedOwnership.first?.secure, false)
        XCTAssertFalse(observedOwnership.contains { !$0.ordinary && !$0.secure })
        XCTAssertEqual(syncChangeCount, 1)
    }

    func testRecoveryAdditionIsFreshlyAuthenticatedButNotCommittedBeforeAcknowledgement() async throws {
        var authenticationCount = 0
        let components = try makeComponentsWithVaultMissingRecovery(
            authenticationEvaluator: { _ in
                authenticationCount += 1
                return true
            })

        let cancelledOptional = try await components.session.withOneUseAuthentication(
            reason: "Test recovery preparation"
        ) {
            try components.secureStore.prepareRecoveryKeyAddition()
        }
        let cancelled = try XCTUnwrap(cancelledOptional)
        XCTAssertFalse(components.secureStore.hasRecoveryKey)
        XCTAssertEqual(components.session.state, .locked)

        cancelled.cancel()
        XCTAssertThrowsError(
            try components.secureStore.commitRecoveryKeyAddition(cancelled))
        XCTAssertFalse(components.secureStore.hasRecoveryKey)

        let acknowledgedOptional = try await components.session.withOneUseAuthentication(
            reason: "Test recovery acknowledgement"
        ) {
            try components.secureStore.prepareRecoveryKeyAddition()
        }
        let acknowledged = try XCTUnwrap(acknowledgedOptional)
        XCTAssertFalse(components.secureStore.hasRecoveryKey)
        XCTAssertTrue(try components.secureStore.commitRecoveryKeyAddition(acknowledged))

        XCTAssertEqual(authenticationCount, 2)
        XCTAssertTrue(components.secureStore.hasRecoveryKey)
        XCTAssertThrowsError(
            try components.secureStore.commitRecoveryKeyAddition(acknowledged))
    }

    func testVaultWillLockHookCanUseKeyAfterDeadlineBeforeKeyIsDestroyed() async throws {
        let components = makeComponents(duration: 1)
        let pending = try XCTUnwrap(
            components.secureStore.prepareVaultCreationIfNeeded())
        _ = try components.secureStore.commitVaultCreation(pending)
        let snippet = components.store.addSnippet(name: "Pre-lock", content: "initial")
        let start = Date(timeIntervalSince1970: 10_000)
        var currentTime = start
        components.session.now = { currentTime }
        _ = try await components.session.unlock(reason: "Test promotion")
        try SecureSnippetTransitionCoordinator.promote(
            snippetID: snippet.id,
            store: components.store,
            secureStore: components.secureStore)
        _ = try await components.session.unlock(reason: "Test pre-lock ordering")
        currentTime = start.addingTimeInterval(2)

        let probe = PreLockProbe()
        let token = NotificationCenter.default.addObserver(
            forName: .snippetsVaultWillLock,
            object: components.session,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                probe.deliveryCount += 1
                probe.keyWasReadable = (try? components.session.currentKey()) != nil
                do {
                    try components.secureStore.setContent(
                        "PRELOCK-FLUSH-SENTINEL",
                        for: snippet.id)
                    probe.flushSucceeded = true
                } catch {
                    probe.flushSucceeded = false
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        components.session.lock()

        XCTAssertEqual(probe.deliveryCount, 1)
        XCTAssertTrue(probe.keyWasReadable)
        XCTAssertTrue(probe.flushSucceeded)
        XCTAssertEqual(components.session.state, .locked)
        XCTAssertThrowsError(try components.session.currentKey())

        _ = try await components.session.unlock(reason: "Verify pre-lock flush")
        XCTAssertEqual(
            try components.secureStore.content(for: snippet.id),
            "PRELOCK-FLUSH-SENTINEL")
    }

    func testSecureTextViewBlocksAmbientDisclosureAndRecoveryClipboardIsLocalAndExpiring() {
        let textView = SecureSnippetTextView()
        textView.text = "secure body"
        textView.isSecureContentMode = true

        for selectorName in [
            "copy:", "cut:", "undo:", "redo:", "_share:", "_define:", "translate:"
        ] {
            XCTAssertFalse(textView.canPerformAction(
                NSSelectorFromString(selectorName),
                withSender: nil))
        }
        XCTAssertEqual(textView.autocorrectionType, .no)
        XCTAssertEqual(textView.spellCheckingType, .no)
        XCTAssertEqual(textView.smartInsertDeleteType, .no)
        XCTAssertEqual(textView.textContentType, .password)
        XCTAssertEqual(textView.writingToolsBehavior, .none)
        XCTAssertFalse(textView.isFindInteractionEnabled)
        XCTAssertFalse(AppDelegate.allowsExtensionPoint(.keyboard))

        let instant = Date(timeIntervalSince1970: 20_000)
        let options = RecoveryKeyPasteboard.options(now: instant)
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        XCTAssertEqual(
            options[.expirationDate] as? Date,
            instant.addingTimeInterval(RecoveryKeyPasteboard.lifetime))
    }

    func testEncryptedBackupKDFYieldsMainActorAndStillRoundTrips() async throws {
        let components = makeComponents()
        _ = components.store.addSnippet(name: "Backup", content: "body")
        let probe = MainActorHeartbeat()
        Task { @MainActor in probe.didRun = true }

        let result = try await components.secureStore.makeEncryptedBackup(
            store: components.store,
            passphrase: "test passphrase",
            iterations: 1)

        XCTAssertTrue(probe.didRun)
        let opened = try EncryptedSnippetBackup.open(
            result.data,
            passphrase: "test passphrase")
        XCTAssertEqual(opened.snippets.count, 1)
        XCTAssertEqual(result.ordinaryCount, 1)
    }

    func testNotificationObserversDoNotRetainEditors() {
        let environment = AppEnvironment()
        let snippet = environment.store.addSnippet(name: "Lifecycle", content: "body")
        weak var phoneEditor: PhoneSnippetEditorViewController?
        weak var tabletEditor: SnippetEditorViewController?

        autoreleasepool {
            let phone = PhoneSnippetEditorViewController(
                environment: environment,
                snippetID: snippet.id)
            phone.loadViewIfNeeded()
            phoneEditor = phone

            let tablet = SnippetEditorViewController(environment: environment)
            tablet.loadViewIfNeeded()
            tablet.bind(to: snippet.id)
            tabletEditor = tablet
        }

        XCTAssertNil(phoneEditor)
        XCTAssertNil(tabletEditor)
    }

    private func makeComponents(
        duration: TimeInterval = VaultSession.defaultDuration,
        authenticationEvaluator: @escaping VaultSession.AuthenticationEvaluator = { _ in true }
    ) -> Components {
        let keychain = makeKeychain()
        let session = VaultSession(
            keychain: keychain,
            duration: duration,
            authenticationEvaluator: authenticationEvaluator)
        let store = SnippetStore(configuration: .iOS)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        return Components(
            store: store,
            secureStore: secureStore,
            session: session,
            keychain: keychain)
    }

    private func makeComponentsWithVaultMissingRecovery(
        authenticationEvaluator: @escaping VaultSession.AuthenticationEvaluator
    ) throws -> Components {
        let keychain = makeKeychain()
        let keyring = SnippetCrypto.Keyring.generate()
        let keyID = "test-vault-\(UUID().uuidString.lowercased())"
        try keychain.store(
            keyring.libraryKey.withUnsafeBytes { Data($0) },
            keyID: keyID)
        let document = VaultDocument(
            kid: keyID,
            vaultSalt: SnippetCrypto.base64URL(keyring.salt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(SnippetCrypto.randomBytes(16))))
        try VaultFile.write(document)

        let session = VaultSession(
            keychain: keychain,
            authenticationEvaluator: authenticationEvaluator)
        let store = SnippetStore(configuration: .iOS)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        return Components(
            store: store,
            secureStore: secureStore,
            session: session,
            keychain: keychain)
    }

    private func makeKeychain() -> KeychainSecretStore {
        KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
    }
}

@MainActor
private struct Components {
    let store: SnippetStore
    let secureStore: SecureSnippetStore
    let session: VaultSession
    let keychain: KeychainSecretStore
}

@MainActor
private final class PreLockProbe {
    var deliveryCount = 0
    var keyWasReadable = false
    var flushSucceeded = false
}

@MainActor
private final class MainActorHeartbeat {
    var didRun = false
}
