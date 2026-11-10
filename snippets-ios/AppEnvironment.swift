import UIKit
import Darwin
import Foundation

@MainActor
final class AppEnvironment {
    #if DEBUG
    static let emptyLibraryLaunchArgument = "--empty-library"
    static let launchPerformanceArgument = "--ui-testing-launch-performance"
    private var isIsolatedCloudIntegrationHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SNIPPETS_CLOUD_E2E"] == "1"
            && !(environment[SnippetStorageLocations.rootOverrideEnvironmentKey] ?? "").isEmpty
    }
    #endif

    let diagnostics: DiagnosticsService
    let store: SnippetStore
    let keychain: KeychainSecretStore
    let backendSelection: SyncBackendSelectionStore
    let cloudBootstrap: SnippetsCloudAccountBootstrap
    let vaultSession: VaultSession
    let secureStore: SecureSnippetStore
    let syncLibrary: SnippetLibraryBridge
    let syncCoordinator: SyncCoordinator
    let snippetActions: SnippetActionService
    private var localSecureChangeDepth = 0
    private var localEditorChangeDepth = 0
    private var hasStarted = false

    /// True only while an editor is synchronously publishing its own UI state.
    ///
    /// Store and sync notifications still run normally. The iOS roots use this
    /// narrow context to avoid immediately feeding the same values back through the
    /// editor and to defer list work that does not need to block a keystroke.
    var isPerformingLocalEditorChange: Bool { localEditorChangeDepth > 0 }

    init(
        keychain: KeychainSecretStore? = nil,
        cloudCredentialStore: KeychainSecretStore? = nil,
        cloudBootstrapSecrets: KeychainSecretStore? = nil,
        syncTransportFactory: (() throws -> any SyncTransport)? = nil,
        pasteboard: (any SnippetPasteboard)? = nil,
        secureContentLoader: SnippetActionService.SecureContentLoader? = nil,
        snippetsCloudEnabled: Bool = SnippetsCloudFeature.isEnabled
    ) {
        #if DEBUG
        let isUITestReset = CommandLine.arguments.contains("--ui-testing-reset")
        let isLaunchPerformanceRun =
            CommandLine.arguments.contains(Self.launchPerformanceArgument)
        if isUITestReset || isLaunchPerformanceRun {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Snippets-iOS-UI-Tests", isDirectory: true)
            if isUITestReset {
                try? FileManager.default.removeItem(at: root)
            }
            setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
            if isUITestReset {
                // Sync on/off is process-only and the provider choice lives in a
                // disposable suite, so a fixture that connects and switches providers
                // cannot change the next normal launch of this Debug app or the unit
                // tests hosted in it.
                SyncCoordinator.runtimeEnabledOverride = false
            } else {
                UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
            }
        } else if CommandLine.arguments.contains(Self.emptyLibraryLaunchArgument) {
            // Device-only visual verification must never erase or overwrite the real
            // Debug library. Redirect every store to a clean process-local root and
            // override the sync preference in memory so a normal relaunch restores the
            // user's existing Debug data and setting.
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Snippets-iOS-Empty-Library", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
            SyncCoordinator.runtimeEnabledOverride = false
        }
        #endif
        diagnostics = DiagnosticsService.shared
        store = SnippetStore(configuration: .iOS)
        #if DEBUG
        // UI fixtures already isolate files and disable sync. Isolate their keys
        // too: unsigned simulator builds cannot use the app's shared access group.
        self.keychain = keychain ?? KeychainSecretStore(inMemory: isUITestReset)
        #else
        self.keychain = keychain ?? KeychainSecretStore()
        #endif
        let keychain = self.keychain
        #if DEBUG
        // UI fixtures talk to a disposable loopback git server and keep the Git key and
        // token in memory, never in the simulator's Keychain.
        let gitKeys = isUITestReset
            ? GitSyncKeyStore(keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true)) : nil
        let gitCredentials = isUITestReset
            ? KeychainSecretStore(tier: .deviceOnly, inMemory: true) : nil
        let gitAllowsInsecureLoopback = isUITestReset
            || ProcessInfo.processInfo.environment["SNIPPETS_GIT_ALLOW_LOOPBACK_HTTP"] == "1"
        let selectionDefaults: UserDefaults
        if isUITestReset, let suite = UserDefaults(suiteName: "SnippetsUITestSelection") {
            suite.removePersistentDomain(forName: "SnippetsUITestSelection")
            selectionDefaults = suite
        } else {
            selectionDefaults = .standard
        }
        // The device's SSH key and trusted host keys; UI fixtures keep both disposable.
        let sshIdentity = isUITestReset
            ? GitSSHDeviceIdentity(
                keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
                hostKeys: GitSSHHostKeyStore(defaults: selectionDefaults), comment: Self.sshKeyComment)
            : GitSSHDeviceIdentity(comment: Self.sshKeyComment)
        #else
        let gitKeys: GitSyncKeyStore? = nil
        let gitCredentials: KeychainSecretStore? = nil
        let gitAllowsInsecureLoopback = false
        let selectionDefaults = UserDefaults.standard
        let sshIdentity = GitSSHDeviceIdentity(comment: Self.sshKeyComment)
        #endif
        backendSelection = SyncBackendSelectionStore(
            defaults: selectionDefaults,
            keychain: cloudCredentialStore,
            bootstrapSecrets: cloudBootstrapSecrets,
            snippetsCloudEnabled: snippetsCloudEnabled,
            defersCredentialRecovery: true,
            gitKeys: gitKeys,
            gitCredentials: gitCredentials,
            gitAllowsInsecureLoopback: gitAllowsInsecureLoopback,
            gitSSH: GitSSHSupport(connector: GitNIOSSHConnector(identity: sshIdentity), device: sshIdentity))
        cloudBootstrap = SnippetsCloudAccountBootstrap(
            selection: backendSelection, secrets: cloudBootstrapSecrets)
        #if DEBUG
        let usesDeterministicUITestAuthentication =
            isUITestReset
            && CommandLine.arguments.contains("--ui-testing-authentication-succeeds")
        let authenticationEvaluator: VaultSession.AuthenticationEvaluator?
        if usesDeterministicUITestAuthentication {
            authenticationEvaluator = { _ in true }
        } else {
            authenticationEvaluator = nil
        }
        vaultSession = VaultSession(
            keychain: keychain,
            checksKeychainInBackground: true,
            authenticationEvaluator: authenticationEvaluator
        )
        #else
        vaultSession = VaultSession(keychain: keychain, checksKeychainInBackground: true)
        #endif
        secureStore = SecureSnippetStore(
            session: vaultSession,
            keychain: keychain,
            maintainsKeychainInBackground: true,
            deviceID: store.deviceID
        )
        syncLibrary = SnippetLibraryBridge(store: store, secureStore: secureStore)
        let selectedBackend = backendSelection
        syncCoordinator = SyncCoordinator(
            library: syncLibrary,
            keys: SyncKeyStore(
                keychain: keychain,
                cloudKeys: backendSelection.cloudKeys,
                usesSnippetsCloud: { selectedBackend.provider == .snippetsCloud },
                gitKeys: backendSelection.gitKeys,
                gitScope: {
                    selectedBackend.provider == .git
                        ? .some(selectedBackend.gitCoordinates?.keyScope) : nil
                }),
            device: store.deviceID,
            transportFactory: syncTransportFactory,
            preparesKeyInBackground: true,
            backendSelection: backendSelection
        )
        snippetActions = SnippetActionService(
            store: store,
            vaultSession: vaultSession,
            secureStore: secureStore,
            pasteboard: pasteboard,
            secureContentLoader: secureContentLoader
        )

        store.secureProvider = secureStore
        store.syncDelegate = syncCoordinator
        secureStore.onChange = { [weak self] in
            guard let self else { return }
            self.store.onChange?(.init(
                source: self.localSecureChangeDepth > 0 ? .local : .external))
            self.syncCoordinator.libraryStructureChanged()
        }
        secureStore.reconcileInterruptedMove()
    }

    func start() {
        #if DEBUG
        // The integration test owns a separate isolated production stack. Its global
        // sync override must not activate this application's automatic coordinator.
        if isIsolatedCloudIntegrationHost { return }
        #endif
        guard !hasStarted else { return }
        hasStarted = true
        store.onChange?(.init(source: .external))
        Task { @MainActor [weak self, cloudBootstrap] in
            do {
                let requiresResume = try await cloudBootstrap.requiresPostAuthorizationResume()
                guard let self else { return }
                if requiresResume {
                    let resumed = try await cloudBootstrap.resumePostAuthorizationSetup()
                    if resumed == .ready { self.syncCoordinator.startIfEnabled() }
                } else {
                    self.syncCoordinator.startIfEnabled()
                }
            } catch {
                // Preserve the durable setup fence on an unavailable/malformed marker.
                // Local library presentation is independent; Settings exposes retry.
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            TemporaryExportFiles.removeStale()
        }
    }

    func becameActive() {
        #if DEBUG
        if isIsolatedCloudIntegrationHost { return }
        #endif
        Diagnostics.record(.lifecycle(.becameActive))
        let previousDocument = secureStore.document
        let wasUnreadable = secureStore.isUnreadable
        secureStore.reload(notifyChange: false)

        if secureStore.document != previousDocument
            || secureStore.isUnreadable != wasUnreadable {
            // A real vault change refreshes the UI and is itself the one foreground sync
            // request. A read-only reload must not manufacture a local-library change.
            store.onChange?(.init(source: .external))
            syncCoordinator.libraryStructureChanged()
        } else if SyncCoordinator.isEnabled {
            // No structural callback was emitted, so the lifecycle request is the one
            // round this activation needs.
            _ = syncCoordinator.syncNow(trigger: .becameActive)
        }
    }

    func enteredBackground() {
        Diagnostics.record(.lifecycle(.enteredBackground))
        vaultSession.lock()
        store.flushPendingWrites()
        Diagnostics.flush()
    }

    func receivedMemoryWarning() {
        Diagnostics.record(.lifecycle(.memoryWarning))
        Diagnostics.flush()
    }

    func performLocalSecureChange<T>(_ change: () throws -> T) rethrows -> T {
        localSecureChangeDepth += 1
        defer { localSecureChangeDepth -= 1 }
        return try change()
    }

    func performLocalEditorChange<T>(_ change: () throws -> T) rethrows -> T {
        localEditorChangeDepth += 1
        defer { localEditorChangeDepth -= 1 }
        return try change()
    }
}

extension AppEnvironment {
    /// Labels this device's SSH key in the host's key list.
    static var sshKeyComment: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "snippets-ipad" : "snippets-iphone"
    }
}
