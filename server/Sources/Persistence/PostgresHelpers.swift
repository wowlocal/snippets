import Logging
import PostgresNIO

let disabledPostgresLogger = Logger(label: "snippets.postgres.disabled") { _ in
    SwiftLogNoOpLogHandler()
}

func drain(_ rows: PostgresRowSequence) async throws {
    for try await _ in rows {}
}

extension PostgresConnection {
    func querySanitized(_ query: PostgresQuery) async throws -> PostgresRowSequence {
        try await self.query(query, logger: disabledPostgresLogger)
    }
}

func queryScalar<T: PostgresDecodable & Sendable>(
    _ type: T.Type,
    connection: PostgresConnection,
    query: PostgresQuery
) async throws -> T? {
    var result: T?
    for try await value in try await connection.querySanitized(query).decode(T.self) {
        result = value
    }
    return result
}
