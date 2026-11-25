import Foundation

// Compile-only stand-ins for two app-layer declarations that live in
// `snippets/Sync/SyncBackendSelectionStore.swift`. That file needs CloudKit and most
// of the app, so it cannot join this overlay. `SyncKeyStore.swift` (symlinked,
// unmodified) names these types in code the interop tool never runs; the only member
// the tool calls is `SyncKeyStore.keyring(from:)`, which touches neither.

nonisolated enum SnippetsCloudKeychainScope {
    enum Store: String, CaseIterable {
        case credentials = "interop.unused.sync-http"
        case bootstrap = "interop.unused.cloud-bootstrap"
        case libraryKey = "interop.unused.cloud-library-key"
    }

    static func service(for store: Store, bundleIdentifier: String? = nil) -> String {
        "\(store.rawValue).interop-unused"
    }
}

@MainActor
final class SyncBackendSelectionStore {
    struct CloudCoordinates: Equatable {
        var serverURL: URL
        var apiBaseURL: URL? = nil
        var spaceID: UUID
        var serverInstanceID: UUID? = nil
        var protocolMajor: Int? = nil
    }

    var cloudCoordinates: CloudCoordinates? { nil }

    init() {}
}
