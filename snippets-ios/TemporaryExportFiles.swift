import Foundation

/// Owns the app's short-lived document-picker exports. Each export gets a private,
/// unpredictable directory so concurrent scenes cannot overwrite one another, and old
/// crash residue is removed on the next root-controller creation.
nonisolated enum TemporaryExportFiles {
    private static let directoryPrefix = "Snippets-Export-"
    private static let staleAge: TimeInterval = 24 * 60 * 60

    static func makeURL(filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            directoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.complete,
            ]
        )
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.complete,
            ],
            ofItemAtPath: url.path
        )
    }

    static func remove(_ url: URL) {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        guard isOwnedDirectory(directory) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func removeStale(now: Date = Date()) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries where isOwnedDirectory(entry.standardizedFileURL) {
            guard let values = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            ),
            values.isDirectory == true,
            let modified = values.contentModificationDate,
            now.timeIntervalSince(modified) >= staleAge else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func isOwnedDirectory(_ directory: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        return directory.deletingLastPathComponent() == temporary
            && directory.lastPathComponent.hasPrefix(directoryPrefix)
    }
}
