import Crypto
import Foundation
import PostgresNIO

public struct MigrationRunner: Sendable {
    private let client: PostgresClient
    private let directory: URL

    public init(client: PostgresClient, directory: URL) {
        self.client = client
        self.directory = directory
    }

    public func run() async throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "sql" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw MigrationError.noMigrations }

        try await client.withConnection { connection in
            _ = try await connection.simpleQuery("SELECT pg_advisory_lock(734928517204173);").get()
            do {
                _ = try await connection.simpleQuery("""
                    CREATE TABLE IF NOT EXISTS migration_history (
                        version text PRIMARY KEY,
                        sha256 text NOT NULL CHECK (length(sha256) = 64),
                        applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
                    );
                    """).get()

                for file in files {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw MigrationError.invalidInput
                    }
                    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                    guard data.count <= 2_000_000, let sql = String(data: data, encoding: .utf8) else {
                        throw MigrationError.invalidInput
                    }
                    let version = file.lastPathComponent
                    let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    var existing: String?
                    let rows = try await connection.querySanitized("SELECT sha256 FROM migration_history WHERE version = \(version)")
                    for try await value in rows.decode(String.self) { existing = value }
                    if let existing {
                        guard existing == checksum else { throw MigrationError.checksumMismatch }
                        continue
                    }
                    let combined = """
                    BEGIN;
                    \(sql)
                    INSERT INTO migration_history(version, sha256)
                    VALUES (\(quote(version)), \(quote(checksum)));
                    COMMIT;
                    """
                    do {
                        _ = try await connection.simpleQuery(combined).get()
                    } catch {
                        _ = try? await connection.simpleQuery("ROLLBACK;").get()
                        throw MigrationError.applyFailed
                    }
                }
                _ = try await connection.simpleQuery("SELECT pg_advisory_unlock(734928517204173);").get()
            } catch {
                _ = try? await connection.simpleQuery("SELECT pg_advisory_unlock(734928517204173);").get()
                throw error
            }
        }
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

public enum MigrationError: Error, Equatable, Sendable {
    case noMigrations
    case invalidInput
    case checksumMismatch
    case applyFailed
}
