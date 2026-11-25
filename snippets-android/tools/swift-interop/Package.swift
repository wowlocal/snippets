// swift-tools-version: 6.2
import PackageDescription

// Swift-side interoperability tool for the pure-Kotlin Android rebuild.
//
// `SnippetsCore` here is a symlink overlay over the shipping sources, in the same
// style as `CorePackage`: nothing is copied and nothing is modified. It is not a path
// dependency on `CorePackage` because the tool also needs two app-layer files
// (`snippets/Sync/GitSyncKeyStore.swift`, `SyncKeyStore.swift`) that have no `import`
// of the core and therefore only compile inside the same module. The module keeps the
// name `SnippetsCore` so that two existing files compile unmodified against it:
// `Tests/Core/GitTestServer.swift` and
// `snippets-linux/tests/reference/git-plain-vectors.swift`, which both say
// `@testable import SnippetsCore`.
//
// Debug builds only: `@testable import` needs `-enable-testing`, which SwiftPM passes
// in the debug configuration.
let package = Package(
    name: "swift-interop",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SnippetsCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "swift-interop",
            dependencies: ["SnippetsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The repository's own generator for snippets-linux/tests/fixtures/git-plain-v1.json,
        // compiled as it stands. `swift-interop emit` runs it and wraps its output (G07).
        .executableTarget(
            name: "git-plain-reference",
            dependencies: ["SnippetsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
