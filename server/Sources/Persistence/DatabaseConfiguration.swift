import Foundation
import NIOSSL
import PostgresNIO

public enum DatabaseTLSMode: String, Sendable {
    case require
    case disable
}
public struct DatabaseConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let database: String
    public let username: String
    public let password: String
    public let tlsMode: DatabaseTLSMode
    public let maximumConnections: Int

    public init(
        host: String,
        port: Int,
        database: String,
        username: String,
        password: String,
        tlsMode: DatabaseTLSMode,
        maximumConnections: Int = 20
    ) throws {
        guard !host.isEmpty, host.utf8.count <= 255, (1...65_535).contains(port),
              !database.isEmpty, database.utf8.count <= 63,
              !username.isEmpty, username.utf8.count <= 63,
              !password.isEmpty, password.utf8.count <= 1_024,
              (1...100).contains(maximumConnections)
        else { throw DatabaseConfigurationError.invalidValue }
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.password = password
        self.tlsMode = tlsMode
        self.maximumConnections = maximumConnections
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        owner: Bool = false
    ) throws -> Self {
        func required(_ key: String) throws -> String {
            guard let value = environment[key], !value.isEmpty else {
                throw DatabaseConfigurationError.missing(key)
            }
            return value
        }
        let prefix = owner ? "DATABASE_OWNER_" : "DATABASE_RUNTIME_"
        guard let port = Int(environment["DATABASE_PORT"] ?? "5432"),
              let maximum = Int(environment["DATABASE_MAX_CONNECTIONS"] ?? "20"),
              let tls = DatabaseTLSMode(rawValue: environment["DATABASE_TLS_MODE"] ?? "require")
        else { throw DatabaseConfigurationError.invalidValue }
        return try .init(
            host: required("DATABASE_HOST"),
            port: port,
            database: required("DATABASE_NAME"),
            username: required(prefix + "USER"),
            password: required(prefix + "PASSWORD"),
            tlsMode: tls,
            maximumConnections: maximum
        )
    }

    public func postgresConfiguration() -> PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS
        switch tlsMode {
        case .require:
            tls = .require(.makeClientConfiguration())
        case .disable:
            tls = .disable
        }
        var result = PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tls
        )
        result.options.maximumConnections = maximumConnections
        result.options.minimumConnections = min(2, maximumConnections - 1)
        result.options.connectTimeout = .seconds(10)
        return result
    }
}

public enum DatabaseConfigurationError: Error, Equatable, Sendable {
    case missing(String)
    case invalidValue
}
