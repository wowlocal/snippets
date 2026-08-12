// swift-tools-version: 6.2
import PackageDescription

// TEST-ONLY OVERLAY over `snippets/Core/`. Neither the Snippets app target nor the
// snippets-cli target depends on this package; it compiles the very same files the
// Xcode targets compile directly, so `swift test` can exercise both the pure logic and
// the small AppKit pasteboard boundary with no GUI app, signed bundle, or keychain.
//
//   swift test --package-path CorePackage
//
// ## Why this manifest is not at the repository root
//
// SwiftPM reserves a directory named `Snippets/` at the package root for "snippets"
// — standalone example programs, each compiled as its own module. This repository's
// source directory is named `snippets/`, and macOS filesystems are case-insensitive,
// so a root-level manifest makes SwiftPM compile every file in `snippets/` a second
// time as a one-file module. That fails immediately (no AppKit context, no access to
// sibling types) and there is no flag to turn it off. Rooting the package one level
// down means there is no `Snippets/` beside the manifest and the convention never
// fires. The sources themselves stay exactly where the Xcode targets expect them,
// reached through the symlinks in `Sources/` and `Tests/`.
//
// `.defaultIsolation` is deliberately NOT set. The app target builds this code with
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor and snippets-cli builds it with no
// default, so every declaration under `snippets/Core/` is explicitly `nonisolated`.
// Building here with no default is what proves those annotations are complete rather
// than merely matching one of the two targets.
let package = Package(
    name: "SnippetsCore",
    platforms: [.macOS(.v15)],
    products: [
        // Explicitly static: were this ever linked into the bare Mach-O CLI, a dynamic
        // library would leave an unresolvable @rpath in a binary that has no bundle to
        // put a Frameworks directory in.
        .library(name: "SnippetsCore", type: .static, targets: ["SnippetsCore"]),
    ],
    targets: [
        .target(name: "SnippetsCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // AppKit stays out of SnippetsCore's Foundation-only boundary. This small sibling
        // target exists so the shipping pasteboard lease runs under the normal test command.
        .target(name: "SnippetsPasteboard", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The event-tap AX budget is another AppKit boundary that must be exercised without
        // launching a signed app or requiring Accessibility permission.
        .target(name: "SnippetsAX", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The secure NSTextView is an AppKit boundary just like pasteboard and AX.
        // Compile the shipping source itself so responder/pasteboard/text-service
        // overrides are exercised without launching the full application.
        .target(name: "SnippetsSecureEditor", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "SnippetsCoreTests",
            dependencies: ["SnippetsCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SnippetsPasteboardTests",
            dependencies: ["SnippetsPasteboard"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SnippetsAXTests",
            dependencies: ["SnippetsAX"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SnippetsSecureEditorTests",
            dependencies: ["SnippetsSecureEditor"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
