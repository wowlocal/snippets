import Darwin
import Foundation

@MainActor
final class AppEnvironment {
    let store: SnippetStore
    let keychain: KeychainSecretStore
    let vaultSession: VaultSession
    let secureStore: SecureSnippetStore
    let syncLibrary: SnippetLibraryBridge
    let syncCoordinator: SyncCoordinator
    private var localSecureChangeDepth = 0

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--ui-testing-reset") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Snippets-iPad-UI-Tests", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
            UserDefaults.standard.set(false, forKey: SyncCoordinator.enabledDefaultsKey)
        }
        #endif
        store = SnippetStore(configuration: .iPad)
        keychain = KeychainSecretStore()
        vaultSession = VaultSession(keychain: keychain)
        secureStore = SecureSnippetStore(
            session: vaultSession,
            keychain: keychain,
            deviceID: store.deviceID
        )
        syncLibrary = SnippetLibraryBridge(store: store, secureStore: secureStore)
        syncCoordinator = SyncCoordinator(
            library: syncLibrary,
            keys: SyncKeyStore(keychain: keychain),
            device: store.deviceID
        )

        store.secureProvider = secureStore
        secureStore.onChange = { [weak self] in
            guard let self else { return }
            self.store.onChange?(self.localSecureChangeDepth > 0 ? .local : .external)
            self.syncCoordinator.libraryStructureChanged()
        }
        secureStore.reconcileInterruptedMove()
    }

    func start() {
        store.onChange?(.external)
        syncCoordinator.startIfEnabled()
    }

    func becameActive() {
        secureStore.reload()
        if SyncCoordinator.isEnabled {
            syncCoordinator.syncNow()
        }
    }

    func enteredBackground() {
        vaultSession.lock()
        store.flushPendingWrites()
    }

    func performLocalSecureChange<T>(_ change: () throws -> T) rethrows -> T {
        localSecureChangeDepth += 1
        defer { localSecureChangeDepth -= 1 }
        return try change()
    }
}
