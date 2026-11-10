import Foundation
import Testing
@testable import SnippetsCore

/// Opt-in cost measurements against a real host. Each protocol gets its own new branch
/// in the given repository; nothing else is touched.
///
///   SNIPPETS_GIT_BENCH_HTTPS_URL=https://github.com/me/scratch \
///   SNIPPETS_GIT_BENCH_USERNAME=x-access-token SNIPPETS_GIT_BENCH_TOKEN=… \
///   SNIPPETS_GIT_BENCH_SSH_URL=git@github.com:me/scratch.git \
///   xcrun swift test --package-path CorePackage --filter GitSyncHostBenchmark
///
/// SSH uses the system ssh with the user's own agent and configuration, as the Mac app
/// does. Results are printed as `BENCH` lines.
enum GitSyncHostBenchmark {
    static var isConfigured: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["SNIPPETS_GIT_BENCH_HTTPS_URL"] != nil || environment["SNIPPETS_GIT_BENCH_SSH_URL"] != nil
    }
}

@Suite(.serialized, .enabled(if: GitSyncHostBenchmark.isConfigured))
struct GitSyncHostBenchmarkTests {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var recordCount: Int { Int(environment["SNIPPETS_GIT_BENCH_RECORDS"] ?? "") ?? 200 }

    @Test func https() async throws {
        let env = Self.environment
        guard let raw = env["SNIPPETS_GIT_BENCH_HTTPS_URL"], let token = env["SNIPPETS_GIT_BENCH_TOKEN"] else { return }
        let branch = "bench-https-\(UUID().uuidString.prefix(8).lowercased())"
        let remote = try GitRemote(
            url: try #require(URL(string: raw)), branch: branch,
            username: env["SNIPPETS_GIT_BENCH_USERNAME"] ?? "x-access-token", password: token)
        let meter = HTTPMeter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await run("https", meter: meter) { name in
            GitSyncTransport(
                configuration: .init(remote: remote, cacheDirectory: Self.cache(name)), session: session)
        }
    }

    @Test func ssh() async throws {
        guard let raw = Self.environment["SNIPPETS_GIT_BENCH_SSH_URL"],
              case .ssh(let location) = try GitRepositoryLocation.parse(raw) else { return }
        let branch = "bench-ssh-\(UUID().uuidString.prefix(8).lowercased())"
        let remote = try GitRemote(ssh: location, branch: branch)
        let meter = SSHMeter(inner: GitSystemSSHConnector())
        try await run("ssh", meter: meter) { name in
            GitSyncTransport(configuration: .init(
                remote: remote, cacheDirectory: Self.cache(name), sshConnector: meter))
        }
    }

    // MARK: - Scenarios

    private func run(
        _ label: String, meter: some Meter, transport make: (String) -> GitSyncTransport
    ) async throws {
        let a = make("\(label)-a")
        let b = make("\(label)-b")
        defer { Task { await a.shutdown(); await b.shutdown() } }

        func measure<T>(_ scenario: String, _ body: () async throws -> T) async throws -> T {
            meter.reset()
            let started = ContinuousClock.now
            let value = try await body()
            let elapsed = ContinuousClock.now - started
            let usage = meter.usage
            print(String(
                format: "BENCH %@ %-34@ %7.0f ms  requests %3d  connections %3d  up %9@  down %9@",
                label, scenario as NSString, elapsed.milliseconds, usage.requests, usage.connections,
                Self.bytes(usage.sent) as NSString, Self.bytes(usage.received) as NSString))
            return value
        }

        _ = try await measure("create library") { try await a.initializeRepository() }
        let records = (0..<Self.recordCount).map { Self.record(index: $0, rev: "r1") }
        let created = try await measure("upload \(records.count) snippets") {
            try await a.submit(records, at: nil)
        }
        var versions: [UUID: SyncRecordVersion] = [:]
        for result in created.results {
            guard case .accepted(_, let version) = result.outcome else {
                Issue.record("not accepted: \(result.outcome)")
                return
            }
            versions[result.id] = version
        }
        var cursorA = created.cursor

        // What every 60-second poll costs when nothing changed: preflight + fetch.
        for round in 1...3 {
            _ = try await measure("idle round \(round) (no changes)") {
                _ = try await a.preflightScope()
                return try await a.fetchChanges(since: cursorA)
            }
        }

        let first = try await measure("fresh device: full download") {
            _ = try await b.preflightScope()
            return try await b.fetchChanges(since: nil)
        }
        #expect(first.records.count == records.count)
        var cursorB = first.cursor

        // One edit on A, then B's next poll.
        var edited = Self.record(index: 0, rev: "r2", id: records[0].id)
        edited.recordVersion = versions[records[0].id]
        let editSubmission = try await measure("edit 1 snippet (round + push)") {
            _ = try await a.preflightScope()
            let fetched = try await a.fetchChanges(since: cursorA)
            cursorA = fetched.cursor
            return try await a.submit([edited], at: cursorA)
        }
        if case .accepted(_, let version) = editSubmission.results.first?.outcome {
            versions[records[0].id] = version
        }
        cursorA = editSubmission.cursor
        let incremental = try await measure("other device picks up 1 edit") {
            _ = try await b.preflightScope()
            return try await b.fetchChanges(since: cursorB)
        }
        #expect(incremental.records.count == 1)
        cursorB = incremental.cursor

        // A day of separate edits: 20 rounds of one change each.
        meter.reset()
        let started = ContinuousClock.now
        var perEditUsage = Usage()
        for index in 1...20 {
            var change = Self.record(index: index, rev: "r2", id: records[index].id)
            change.recordVersion = versions[records[index].id]
            let before = meter.usage
            _ = try await a.preflightScope()
            let fetched = try await a.fetchChanges(since: cursorA)
            let submission = try await a.submit([change], at: fetched.cursor)
            cursorA = submission.cursor
            if case .accepted(_, let version) = submission.results.first?.outcome {
                versions[records[index].id] = version
            }
            perEditUsage = meter.usage - before
        }
        let total = ContinuousClock.now - started
        print(String(
            format: "BENCH %@ %-34@ %7.0f ms  (%.0f ms per edit; last edit: requests %d, up %@, down %@)",
            label, "20 separate edits" as NSString, total.milliseconds, total.milliseconds / 20,
            perEditUsage.requests, Self.bytes(perEditUsage.sent) as NSString,
            Self.bytes(perEditUsage.received) as NSString))
        let caughtUp = try await measure("other device picks up 20 edits") {
            _ = try await b.preflightScope()
            return try await b.fetchChanges(since: cursorB)
        }
        #expect(caughtUp.records.count == 20)
    }

    // MARK: - Fixtures

    /// Ciphertext-sized blobs: real records are sealed, so they are incompressible and
    /// mostly between a few hundred bytes and a few kilobytes.
    static func record(index: Int, rev: String, id: UUID = UUID()) -> WireRecord {
        let size = 400 + (index * 37 + rev.count * 101) % 2_600
        var generator = SystemRandomNumberGenerator()
        let blob = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
        return WireRecord(id: id, rev: "\(rev)-\(index)", deleted: false, blob: blob, recordVersion: nil)
    }

    static func cache(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "git-bench-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func bytes(_ count: Int64) -> String {
        count < 10_240 ? "\(count) B" : String(format: "%.1f KB", Double(count) / 1024)
    }
}

// MARK: - Meters

struct Usage {
    var requests = 0
    var connections = 0
    var sent: Int64 = 0
    var received: Int64 = 0

    static func - (lhs: Usage, rhs: Usage) -> Usage {
        Usage(requests: lhs.requests - rhs.requests, connections: lhs.connections - rhs.connections,
              sent: lhs.sent - rhs.sent, received: lhs.received - rhs.received)
    }
}

protocol Meter: Sendable {
    var usage: Usage { get }
    func reset()
}

/// HTTP requests, new TCP/TLS connections and bytes on the wire (headers included).
final class HTTPMeter: NSObject, URLSessionTaskDelegate, Meter, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Usage()

    var usage: Usage { lock.withLock { current } }
    func reset() { lock.withLock { current = Usage() } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock {
            for transaction in metrics.transactionMetrics where transaction.resourceFetchType == .networkLoad {
                current.requests += 1
                if !transaction.isReusedConnection { current.connections += 1 }
                current.sent += transaction.countOfRequestHeaderBytesSent + transaction.countOfRequestBodyBytesSent
                current.received += transaction.countOfResponseHeaderBytesReceived
                    + transaction.countOfResponseBodyBytesReceived
            }
        }
    }
}

/// SSH exchanges (each its own connection) and git payload bytes; SSH framing and the
/// handshake itself are not included.
final class SSHMeter: GitSSHConnector, Meter, @unchecked Sendable {
    private let inner: any GitSSHConnector
    private let lock = NSLock()
    private var current = Usage()

    init(inner: any GitSSHConnector) { self.inner = inner }

    var usage: Usage { lock.withLock { current } }
    func reset() { lock.withLock { current = Usage() } }

    func exchange(
        command: String, location: GitSSHLocation, maximumBytes: Int,
        request: @escaping @Sendable ([UInt8]) throws -> Data?
    ) async throws -> GitSSHExchange {
        let exchange = try await inner.exchange(command: command, location: location, maximumBytes: maximumBytes) {
            [self] advertisement in
            let body = try request(advertisement)
            lock.withLock { current.sent += Int64(body?.count ?? 4) }
            return body
        }
        lock.withLock {
            current.requests += 1
            current.connections += 1
            current.received += Int64(exchange.advertisement.count + exchange.response.count)
        }
        return exchange
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
