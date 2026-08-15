import Darwin
import Foundation

@MainActor
final class AppEnvironment {
    #if DEBUG
    static let emptyLibraryLaunchArgument = "--empty-library"
    static let launchPerformanceArgument = "--ui-testing-launch-performance"
    #endif

    let diagnostics: DiagnosticsService
    let store: SnippetStore
    let keychain: KeychainSecretStore
    let backendSelection: SyncBackendSelectionStore
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
        pasteboard: (any SnippetPasteboard)? = nil,
        secureContentLoader: SnippetActionService.SecureContentLoader? = nil
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
            UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
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
        keychain = KeychainSecretStore()
        backendSelection = SyncBackendSelectionStore()
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
            authenticationEvaluator: authenticationEvaluator
        )
        #else
        vaultSession = VaultSession(keychain: keychain)
        #endif
        secureStore = SecureSnippetStore(
            session: vaultSession,
            keychain: keychain,
            deviceID: store.deviceID
        )
        syncLibrary = SnippetLibraryBridge(store: store, secureStore: secureStore)
        let selectedBackend = backendSelection
        syncCoordinator = SyncCoordinator(
            library: syncLibrary,
            keys: SyncKeyStore(
                keychain: keychain,
                cloudKeys: backendSelection.cloudKeys,
                usesSnippetsCloud: { selectedBackend.provider == .snippetsCloud }),
            device: store.deviceID,
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
        guard !hasStarted else { return }
        hasStarted = true
        store.onChange?(.init(source: .external))
        syncCoordinator.startIfEnabled()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            TemporaryExportFiles.removeStale()
        }
    }

    func becameActive() {
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
