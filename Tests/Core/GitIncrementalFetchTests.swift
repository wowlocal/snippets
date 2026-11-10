import Foundation
import Testing
@testable import SnippetsCore

/// Polling devices must download what changed, not the whole library again.
@Suite(.serialized) struct GitIncrementalFetchTests {
    @Test func catchingUpDownloadsOnlyWhatChanged() async throws {
        let fixture = try GitFixture()
        let meter = SSHMeter(inner: { var c = GitSystemSSHConnector(); c.executable = try! fixture.fakeSSH(); return c }())
        func transport(_ name: String) throws -> GitSyncTransport {
            GitSyncTransport(configuration: .init(
                remote: try fixture.sshRemote(), cacheDirectory: fixture.cacheDirectory(name), sshConnector: meter))
        }
        let a = try transport("a")
        let b = try transport("b")
        _ = try await a.initializeRepository()
        let records = (0..<200).map { GitSyncHostBenchmarkTests.record(index: $0, rev: "r1") }
        let created = try await a.submit(records, at: nil)
        var versions: [UUID: SyncRecordVersion] = [:]
        for result in created.results { if case .accepted(_, let v) = result.outcome { versions[result.id] = v } }

        meter.reset()
        let full = try await b.fetchChanges(since: nil)
        let fullBytes = meter.usage.received
        #expect(full.records.count == 200)

        for (round, count) in [(1, 1), (2, 20)].map({ $0 }) {
            for index in 0..<count {
                let i = (round == 1 ? 100 : 150) + index
                var change = GitSyncHostBenchmarkTests.record(index: i, rev: "r\(round + 1)", id: records[i].id)
                change.recordVersion = versions[records[i].id]
                let submission = try await a.submit([change], at: nil)
                if case .accepted(_, let v) = submission.results.first?.outcome { versions[records[i].id] = v }
            }
            meter.reset()
            let changes = try await b.fetchChanges(since: full.cursor)
            print("INCREMENTAL \(count) edit(s): \(meter.usage.received) bytes down, full was \(fullBytes)")
            #expect(changes.records.count >= count)
            #expect(meter.usage.received < fullBytes / 4, "\(count) edit(s) re-downloaded \(meter.usage.received) of \(fullBytes) bytes")
        }
    }

    /// A poll that finds nothing new costs one request: the fetch reuses the view of the
    /// branch its preflight just read. After this device pushes, it asks again.
    @Test func anIdleRoundIsOneRequestAndAPushIsNeverHiddenByReuse() async throws {
        let fixture = try GitFixture()
        let meter = SSHMeter(inner: { var c = GitSystemSSHConnector(); c.executable = try! fixture.fakeSSH(); return c }())
        let a = GitSyncTransport(configuration: .init(
            remote: try fixture.sshRemote(), cacheDirectory: fixture.cacheDirectory("a"), sshConnector: meter))
        _ = try await a.initializeRepository()
        let first = try await a.submit([GitSyncHostBenchmarkTests.record(index: 1, rev: "r1")], at: nil)
        _ = try await a.preflightScope()
        let synced = try await a.fetchChanges(since: first.cursor)

        meter.reset()
        _ = try await a.preflightScope()
        let idle = try await a.fetchChanges(since: synced.cursor)
        #expect(meter.usage.requests == 1)
        #expect(idle.records.isEmpty)

        // Preflight, then a push by this device, then the fetch: it must see the push.
        _ = try await a.preflightScope()
        let pushed = try await a.submit([GitSyncHostBenchmarkTests.record(index: 2, rev: "r1")], at: idle.cursor)
        let after = try await a.fetchChanges(since: idle.cursor)
        #expect(after.cursor == pushed.cursor)
    }
}
