import Foundation
import Testing
@testable import SnippetsCore

/// Opt-in check against a real hosted repository (GitHub, GitLab, Gitea, GitVerse…).
///
/// ```sh
/// SNIPPETS_GIT_SYNC_LIVE_URL=https://github.com/me/scratch \
/// SNIPPETS_GIT_SYNC_LIVE_USERNAME=me \
/// SNIPPETS_GIT_SYNC_LIVE_TOKEN=… \
/// xcrun swift test --package-path CorePackage --filter GitSyncLiveHost
/// ```
///
/// Every run works on its own `snippets-live-test/<random>` branch and deletes it at
/// the end, so it never touches an existing library. Use a scratch repository anyway,
/// with at least one commit: hosts will not delete a repository's default branch.
/// A loopback `http://localhost` URL is accepted for a local Gitea container.
@Suite("Git sync live host", .enabled(if: GitLiveHostConfiguration.current != nil))
struct GitSyncLiveHostTests {
    @Test func fullRoundTripOnAScratchBranch() async throws {
        let configuration = try #require(GitLiveHostConfiguration.current)
        let branch = "snippets-live-test/\(UUID().uuidString.lowercased().prefix(12))"
        let root = FileManager.default.temporaryDirectory
            .appending(path: "git-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        func transport(_ name: String) throws -> GitSyncTransport {
            GitSyncTransport(configuration: .init(
                remote: try GitRemote(
                    url: configuration.url, branch: branch, username: configuration.username,
                    password: configuration.token, allowsInsecureLoopback: true),
                cacheDirectory: root.appending(path: name, directoryHint: .isDirectory)))
        }
        let a = try transport("a")
        let b = try transport("b")
        #expect(try await a.inspectRepository() == .empty)
        let dataset = try await a.initializeRepository()
        do {
            #expect(try await b.inspectRepository() == .library(datasetID: dataset))
            #expect(try await a.preflightScope().datasetIdentity == (try await b.preflightScope()).datasetIdentity)

            let records = (0..<3).map {
                WireRecord(id: UUID(), rev: "r1", deleted: false, blob: Data("ciphertext \($0)".utf8))
            }
            var versions: [UUID: SyncRecordVersion] = [:]
            for result in try await a.submit(records, at: nil).results {
                guard case .accepted(_, let version) = result.outcome else {
                    Issue.record("not accepted: \(result.outcome)")
                    continue
                }
                versions[result.id] = version
            }
            let cursorA = try await a.fetchChanges(since: nil).cursor

            let snapshot = try await b.fetchChanges(since: nil)
            #expect(snapshot.records.count == 3)
            #expect(snapshot.records.allSatisfy { versions[$0.id] == $0.recordVersion })

            var edit = records[1]
            edit.rev = "r2"
            edit.blob = Data("edited".utf8)
            edit.recordVersion = versions[edit.id]
            guard case .accepted = try await b.submit([edit], at: snapshot.cursor).results.first?.outcome else {
                Issue.record("edit was not accepted")
                return
            }

            var stale = records[1]
            stale.rev = "r3"
            stale.recordVersion = versions[stale.id]
            guard case .rejected(.conflict(let remote?)) = try await a.submit([stale], at: cursorA).results.first?.outcome
            else {
                Issue.record("stale write was not rejected with the authoritative record")
                return
            }
            #expect(remote.rev == "r2")

            let delta = try await a.fetchChanges(since: cursorA)
            #expect(!delta.isFullResync)
            #expect(delta.records.map(\.id) == [edit.id])
        } catch {
            try? await a.deleteRepositoryBranchForTesting()
            throw error
        }
        // Hosts refuse to delete a repository's default branch, which the scratch branch
        // becomes when the repository was empty. Give the repository any first commit.
        do {
            try await a.deleteRepositoryBranchForTesting()
            #expect(try await b.inspectRepository() == .empty)
        } catch {
            print("warning: could not delete scratch branch \(branch); it may be the default branch")
        }
    }
}

struct GitLiveHostConfiguration {
    var url: URL
    var username: String
    var token: String

    static var current: GitLiveHostConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["SNIPPETS_GIT_SYNC_LIVE_URL"], let url = URL(string: raw),
              let token = environment["SNIPPETS_GIT_SYNC_LIVE_TOKEN"], !token.isEmpty else { return nil }
        return GitLiveHostConfiguration(
            url: url, username: environment["SNIPPETS_GIT_SYNC_LIVE_USERNAME"] ?? "snippets", token: token)
    }
}
