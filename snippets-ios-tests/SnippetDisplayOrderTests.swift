import Darwin
import XCTest

@testable import Snippets

@MainActor
final class SnippetDisplayOrderIntegrationTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetDisplayOrderTests-\(UUID().uuidString)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testStoreSortsPlaintextAndSecureRecordsTogetherRegardlessOfFileOrder() throws {
        let plainNew = snippet(4, createdAt: 400)
        let plainOldPinned = snippet(2, createdAt: 100, isPinned: true)
        let secureOld = snippet(3, createdAt: 200)
        let secureNewPinned = snippet(1, createdAt: 300, isPinned: true)

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try SnippetLibraryCodec.encode([plainNew, plainOldPinned])
            .write(to: SnippetStorageLocations.snippetsFileURL)

        let store = SnippetStore(configuration: .iOS)
        let provider = DisplayOrderSecureProvider(shells: [secureOld, secureNewPinned])
        store.secureProvider = provider

        XCTAssertEqual(
            store.snippetsSortedForDisplay().map(\.id),
            [secureNewPinned.id, plainOldPinned.id, plainNew.id, secureOld.id]
        )
        XCTAssertEqual(store.snippets.map(\.id), [plainNew.id, plainOldPinned.id])
        XCTAssertEqual(provider.secureShellsForDisplay().map(\.id), [secureOld.id, secureNewPinned.id])
    }

    private func snippet(_ id: Int, createdAt: Double, isPinned: Bool = false) -> Snippet {
        Snippet(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            name: "Snippet \(id)",
            keyword: "k\(id)",
            content: "",
            isPinned: isPinned,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

@MainActor
private final class DisplayOrderSecureProvider: SecureSnippetProviding {
    private let shells: [Snippet]

    init(shells: [Snippet]) {
        self.shells = shells
    }

    func secureShellsForDisplay() -> [Snippet] { shells }
    func isSecure(_ id: UUID) -> Bool { shells.contains { $0.id == id } }
}
