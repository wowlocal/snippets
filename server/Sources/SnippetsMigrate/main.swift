import Foundation
import Persistence
import PostgresNIO

@main
enum SnippetsMigrateMain {
    static func main() async throws {
        let configuration = try DatabaseConfiguration.load(owner: true)
        let client = PostgresClient(configuration: configuration.postgresConfiguration())
        let migrationsDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["MIGRATIONS_DIR"] ?? "Migrations",
            isDirectory: true
        ).standardizedFileURL
        let runner = MigrationRunner(client: client, directory: migrationsDirectory)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }
            do {
                try await runner.run()
                group.cancelAll()
                while let _ = try await group.next() {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
