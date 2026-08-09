import XCTest
@testable import Snippets

final class TemporaryExportFilesTests: XCTestCase {
    func testExportUsesPrivateUniqueDirectoryAndRemovalOwnsOnlyThatDirectory() throws {
        let first = try TemporaryExportFiles.makeURL(filename: "Snippets-Export.json")
        let second = try TemporaryExportFiles.makeURL(filename: "Snippets-Export.json")
        defer {
            TemporaryExportFiles.remove(first)
            TemporaryExportFiles.remove(second)
        }

        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        try Data("private".utf8).write(to: first)
        try TemporaryExportFiles.protect(first)

        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let directory = first.deletingLastPathComponent()
        TemporaryExportFiles.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path))
    }
}
