import XCTest
@testable import Snippets

final class IncomingDocumentLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingDocumentLoaderTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testLoadsAndPreparesOrdinaryJSON() throws {
        let url = directory.appendingPathComponent("library.json")
        let expected = Snippet(name: "A", keyword: "a", content: "body")
        try JSONEncoder().encode([expected]).write(to: url)

        guard case .snippets(let prepared) = try IncomingDocumentLoader.load(url) else {
            return XCTFail("Expected an ordinary snippets document")
        }
        XCTAssertEqual(prepared.snippets, [expected])
    }

    func testRejectsOversizedDocumentBeforeReadingIt() throws {
        let url = directory.appendingPathComponent("huge.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(IncomingDocumentLoader.maximumEncryptedBackupBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try IncomingDocumentLoader.load(url)) { error in
            XCTAssertEqual(
                error as? IncomingDocumentLoader.Failure,
                .tooLarge(maximumBytes: IncomingDocumentLoader.maximumEncryptedBackupBytes)
            )
        }
    }
}
