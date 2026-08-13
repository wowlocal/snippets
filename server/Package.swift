// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SnippetsSyncServer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "snippets-server", targets: ["SnippetsServer"]),
        .executable(name: "snippets-migrate", targets: ["SnippetsMigrate"]),
        .library(name: "SyncDomain", targets: ["SyncDomain"]),
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.26.0"),
        .package(url: "https://github.com/hummingbird-project/swift-openapi-hummingbird.git", exact: "2.0.1"),
        .package(url: "https://github.com/apple/swift-openapi-generator.git", exact: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.12.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", exact: "1.33.1"),
        .package(url: "https://github.com/vapor/jwt-kit.git", exact: "5.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", exact: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.2"),
    ],
    targets: [
        .target(
            name: "SyncDomain",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "SyncOpenAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .target(
            name: "Persistence",
            dependencies: [
                "SyncDomain",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "SyncHTTP",
            dependencies: [
                "SyncDomain",
                "SyncOpenAPI",
                "Persistence",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .executableTarget(
            name: "SnippetsServer",
            dependencies: [
                "SyncHTTP",
                "Persistence",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "SnippetsMigrate",
            dependencies: [
                "Persistence",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "SyncDomainTests",
            dependencies: ["SyncDomain"]
        ),
        .testTarget(
            name: "SyncHTTPTests",
            dependencies: [
                "SyncHTTP",
                "SyncDomain",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "PersistenceIntegrationTests",
            dependencies: [
                "Persistence",
                "SyncDomain",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
