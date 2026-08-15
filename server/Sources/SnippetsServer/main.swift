import Foundation
import Hummingbird
import Logging
import Persistence
import PostgresNIO
import SyncHTTP

@main
enum SnippetsServerMain {
    static func main() async throws {
        let configuration = try ServerConfiguration.load()
        let database = try DatabaseConfiguration.load()
        if configuration.environment == .production, database.tlsMode != .require {
            throw StartupError.databaseTLSRequired
        }

        var logger = Logger(label: "snippets.sync.server")
        logger.logLevel = .info
        let client = PostgresClient(configuration: database.postgresConfiguration())
        let validator = try await OIDCAccessTokenValidator.make(configuration: configuration.oidc)
        let store = try PostgresSyncStore(
            client: client,
            serverInstanceID: configuration.serverInstanceID,
            tokenSecret: configuration.tokenSecret
        )
        let router = try SyncApplicationFactory.makeRouter(
            configuration: configuration,
            store: store,
            tokenValidator: validator
        )
        let app = Application(
            router: router,
            server: .http1(configuration: .init(
                idleTimeout: .seconds(Int64(configuration.httpIdleTimeoutSeconds))
            )),
            configuration: .init(
                address: .hostname(configuration.bindHost, port: configuration.port),
                serverName: "snippets-sync",
                backlog: min(configuration.httpMaximumConnections, 256),
                availableConnectionsDelegate: .maximum(
                    configuration.httpMaximumConnections,
                    logger: logger
                )
            ),
            services: [client],
            logger: logger
        )
        try await app.runService()
    }
}

private enum StartupError: Error {
    case databaseTLSRequired
}
