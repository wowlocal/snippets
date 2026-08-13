// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SnippetsAndroidCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "SnippetsAndroidCore",
            type: .dynamic,
            targets: ["SnippetsAndroidCore"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-java.git",
            exact: "0.5.1"),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "3.15.1"),
    ],
    targets: [
        .target(
            name: "SnippetsAndroidCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java")
            ]),
        .testTarget(
            name: "SnippetsAndroidCoreTests",
            dependencies: ["SnippetsAndroidCore"]),
    ])
