// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SnippetsCore",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "SnippetsCore",
            path: "snippets",
            exclude: ["Assets.xcassets", "Base.lproj", "Snippet.icon"],
            sources: [
                "Snippet.swift", "FuzzyMatch.swift", "SnippetFrecency.swift",
                "SnippetUsageDocument.swift", "SnippetUsageStore.swift", "SnippetStore.swift",
                "SuggestionTriggerContext.swift", "AccessibilityTextReplacement.swift",
                "SyntheticEventTag.swift", "SnippetInjectionGate.swift",
                "SnippetPasteConfirmation.swift", "TemporaryPasteboardLease.swift",
                "SnippetInjectionQueue.swift", "PlaceholderResolver.swift",
                "ChromiumBundleIDSettings.swift", "AXCoordinateSpace.swift",
                "SnippetDeepLink.swift",
            ],
            swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]
        ),
    ]
)
