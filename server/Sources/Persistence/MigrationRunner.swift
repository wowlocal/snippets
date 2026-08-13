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
                    do {
                        let statements = try Self.statements(in: sql)
                        try await connection.withTransaction(logger: disabledPostgresLogger) { transaction in
                            for statement in statements {
                                try await drain(transaction.querySanitized(
                                    PostgresQuery(unsafeSQL: statement)))
                            }
                            try await drain(transaction.querySanitized("""
                                INSERT INTO migration_history(version, sha256)
                                VALUES (\(version), \(checksum))
                                """))
                        }
                    } catch {
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

    /// Splits a trusted, checksum-pinned migration into statements for PostgreSQL's
    /// extended query protocol. postgres-nio's historical `simpleQuery` spelling now
    /// uses that protocol, which rejects a whole multi-statement migration. This small
    /// lexer recognizes the PostgreSQL quoting/comment forms in which a semicolon is
    /// data rather than a statement terminator, notably PL/pgSQL dollar-quoted bodies.
    static func statements(in sql: String) throws -> [String] {
        enum Mode: Equatable {
            case normal
            case singleQuote
            case doubleQuote
            case lineComment
            case blockComment(depth: Int)
            case dollarQuote([UInt8])
        }

        let bytes = Array(sql.utf8)
        var mode = Mode.normal
        var current: [UInt8] = []
        var result: [String] = []
        var hasSQL = false
        var index = 0

        func dollarDelimiter(at start: Int) -> [UInt8]? {
            guard bytes[start] == 0x24 else { return nil } // $
            var end = start + 1
            while end < bytes.count, bytes[end] != 0x24 {
                let byte = bytes[end]
                let valid = byte == 0x5f
                    || (0x41...0x5a).contains(byte)
                    || (0x61...0x7a).contains(byte)
                    || (end > start + 1 && (0x30...0x39).contains(byte))
                guard valid else { return nil }
                end += 1
            }
            guard end < bytes.count else { return nil }
            return Array(bytes[start...end])
        }

        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil

            switch mode {
            case .normal:
                if byte == 0x2d, next == 0x2d { // --
                    current.append(byte); current.append(next!)
                    index += 2
                    mode = .lineComment
                    continue
                }
                if byte == 0x2f, next == 0x2a { // /*
                    current.append(byte); current.append(next!)
                    index += 2
                    mode = .blockComment(depth: 1)
                    continue
                }
                if byte == 0x27 { mode = .singleQuote; hasSQL = true }
                else if byte == 0x22 { mode = .doubleQuote; hasSQL = true }
                else if byte == 0x24, let delimiter = dollarDelimiter(at: index) {
                    current.append(contentsOf: delimiter)
                    index += delimiter.count
                    mode = .dollarQuote(delimiter)
                    hasSQL = true
                    continue
                } else if byte == 0x3b { // ;
                    if hasSQL {
                        current.append(byte)
                        guard let statement = String(bytes: current, encoding: .utf8) else {
                            throw MigrationError.invalidInput
                        }
                        result.append(statement)
                    }
                    current.removeAll(keepingCapacity: true)
                    hasSQL = false
                    index += 1
                    continue
                } else if ![0x09, 0x0a, 0x0d, 0x20].contains(byte) {
                    hasSQL = true
                }
                current.append(byte)

            case .singleQuote:
                current.append(byte)
                if byte == 0x27 {
                    if next == 0x27 {
                        current.append(next!)
                        index += 2
                        continue
                    }
                    mode = .normal
                }

            case .doubleQuote:
                current.append(byte)
                if byte == 0x22 {
                    if next == 0x22 {
                        current.append(next!)
                        index += 2
                        continue
                    }
                    mode = .normal
                }

            case .lineComment:
                current.append(byte)
                if byte == 0x0a { mode = .normal }

            case .blockComment(let depth):
                current.append(byte)
                if byte == 0x2f, next == 0x2a {
                    current.append(next!)
                    index += 2
                    mode = .blockComment(depth: depth + 1)
                    continue
                }
                if byte == 0x2a, next == 0x2f {
                    current.append(next!)
                    index += 2
                    mode = depth == 1 ? .normal : .blockComment(depth: depth - 1)
                    continue
                }

            case .dollarQuote(let delimiter):
                if bytes[index...].starts(with: delimiter) {
                    current.append(contentsOf: delimiter)
                    index += delimiter.count
                    mode = .normal
                    continue
                }
                current.append(byte)
            }
            index += 1
        }

        guard mode == .normal || mode == .lineComment else {
            throw MigrationError.invalidInput
        }
        if hasSQL {
            guard let statement = String(bytes: current, encoding: .utf8) else {
                throw MigrationError.invalidInput
            }
            result.append(statement)
        }
        return result
    }
}

public enum MigrationError: Error, Equatable, Sendable {
    case noMigrations
    case invalidInput
    case checksumMismatch
    case applyFailed
}
