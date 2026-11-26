// swift-tools-version: 6.2
import PackageDescription

// Differential check for the Kotlin merge layer (`com.khm.snippets.core.merge`).
//
// Reads generated (base, local, remote) triples and prints what the shipping Swift
// `SyncMerge` makes of them. A package of its own, beside the vector emitter, so that
// building it never touches the emitter's sources, output or `.build` directory.
//
// It links the Swift core through the repository's `CorePackage` overlay (symlinks over
// `snippets/Core`, nothing copied), which is enough for the merge. `@testable import`
// needs `-enable-testing`: debug builds only.
let package = Package(
    name: "merge-differential",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../../../../CorePackage"),
    ],
    targets: [
        .executableTarget(
            name: "merge-differential",
            dependencies: [.product(name: "SnippetsCore", package: "CorePackage")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
