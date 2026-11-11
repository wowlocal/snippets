import Foundation
import Testing
@testable import SnippetsCore

/// Every test talks to a real bare repository through `git http-backend`.
@Suite("Git sync transport")
struct GitSyncTransportTests {
    // MARK: Setup and scope

    @Test func initializesOnlyAnEmptyBranchAndAdoptsAnExistingLibrary() async throws {
        let fixture = try GitFixture()
        let device = try fixture.transport("a")
        #expect(try await device.inspectRepository() == .empty)

        let dataset = try await device.initializeRepository()
        #expect(try await device.inspectRepository() == .library(datasetID: dataset))
        let files = try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
        #expect(files.split(separator: "\n") == ["README.md", "snippets-sync.json"])

        // A second device adopts the same library instead of minting another one.
        let other = try fixture.transport("b")
        #expect(try await other.initializeRepository() == dataset)
        let commits = try fixture.git(["--git-dir", fixture.bare.path, "rev-list", "--count", "main"])
        #expect(commits == "1")

        let first = try await device.preflightScope()
        let second = try await other.preflightScope()
        #expect(first.identity != nil)
        #expect(first.identity == second.identity)
        #expect(first.datasetIdentity != nil)
        #expect(first.datasetIdentity == second.datasetIdentity)
    }

    @Test func uninitializedRepositoryIsReportedAndNeverCreatedImplicitly() async throws {
        let fixture = try GitFixture()
        let device = try fixture.transport()
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_repository_not_initialized"))) {
            _ = try await device.preflightScope()
        }
        let refs = try fixture.git(["--git-dir", fixture.bare.path, "for-each-ref"])
        #expect(refs.isEmpty)
    }

    @Test func foreignBranchIsNeverOverwritten() async throws {
        let fixture = try GitFixture()
        try seedForeignBranch(fixture)
        let device = try fixture.transport()
        #expect(try await device.inspectRepository() == .foreign)
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_branch_not_snippets_library"))) {
            _ = try await device.initializeRepository()
        }
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_branch_not_snippets_library"))) {
            _ = try await device.preflightScope()
        }
        let files = try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
        #expect(files == "main.c")
    }

    @Test func differentBranchesAreDifferentAccounts() async throws {
        let fixture = try GitFixture()
        let main = try fixture.transport("main")
        let other = try fixture.transport("other", branch: "snippets/other")
        _ = try await main.initializeRepository()
        _ = try await other.initializeRepository()
        let mainScope = try await main.preflightScope()
        let otherScope = try await other.preflightScope()
        #expect(mainScope.identity != otherScope.identity)
        #expect(mainScope.datasetIdentity != otherScope.datasetIdentity)
    }

    /// Hosts that canonicalize `/owner/repo` to `/owner/repo.git` redirect discovery.
    /// POSTs cannot follow redirects, so later requests must use the redirected base.
    @Test func sameHostRedirectIsFollowedAndRebasesLaterRequests() async throws {
        let fixture = try GitFixture()
        GitHTTPBackendProtocol.update(host: fixture.host) {
            $0.redirect = (prefix: "/repo.git/", base: "http://\(fixture.host)/repo.git")
        }
        let device = GitSyncTransport(
            configuration: .init(
                remote: try GitRemote(
                    url: URL(string: "http://\(fixture.host)/repo")!, branch: "main",
                    username: fixture.username, password: fixture.password, allowsInsecureLoopback: true),
                cacheDirectory: fixture.cacheDirectory("redirected")),
            session: fixture.session)
        _ = try await device.initializeRepository()
        _ = try await device.submit([record(rev: "r1", body: "x")], at: nil)
        let redirects = fixture.requests.filter { $0.hasPrefix("REDIRECT") }
        #expect(!redirects.isEmpty)
        #expect(redirects.allSatisfy { $0.hasPrefix("REDIRECT GET") }, "\(fixture.requests)")
        #expect(fixture.requests.contains("POST git-receive-pack"))
    }

    @Test func crossHostRedirectNeverReceivesTheCredential() async throws {
        let fixture = try GitFixture()
        let attacker = try GitFixture()
        GitHTTPBackendProtocol.update(host: fixture.host) {
            $0.redirect = (prefix: "/never/", base: "http://\(attacker.host)/repo.git")
        }
        let device = try fixture.transport()
        await #expect(throws: SyncTransportFailure.unreachable(detail: "git_protocol_http_301")) {
            _ = try await device.inspectRepository()
        }
        #expect(GitHTTPBackendProtocol.authorizationHeaders(host: attacker.host).isEmpty)
        #expect(!GitRedirectGuard.permits(
            from: URLRequest(url: URL(string: "https://a.example/x")!),
            to: URLRequest(url: URL(string: "https://b.example/x")!)))
        var post = URLRequest(url: URL(string: "https://a.example/x")!)
        post.httpMethod = "POST"
        #expect(!GitRedirectGuard.permits(from: post, to: URLRequest(url: URL(string: "https://a.example/y")!)))
        #expect(!GitRedirectGuard.permits(
            from: URLRequest(url: URL(string: "https://a.example/x")!),
            to: URLRequest(url: URL(string: "http://a.example/x")!)))
        #expect(GitRedirectGuard.permits(
            from: URLRequest(url: URL(string: "https://a.example/x")!),
            to: URLRequest(url: URL(string: "https://A.example/x.git")!)))
    }

    @Test func wrongCredentialRequiresAuthentication() async throws {
        let fixture = try GitFixture()
        _ = try await fixture.transport().initializeRepository()
        let device = try fixture.transport(password: "not-the-token")
        await #expect(throws: SyncTransportFailure.rejected(.authenticationRequired(detail: "git_http_401"))) {
            _ = try await device.preflightScope()
        }
    }

    // MARK: Data plane

    @Test func submittedRecordsReachAnotherDevice() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        _ = try await a.initializeRepository()
        let first = record(rev: "r1", body: "one")
        let second = record(rev: "r1", body: "two", deleted: true)
        let submission = try await a.submit([first, second], at: nil)
        let versions = try accepted(submission)
        #expect(versions.count == 2)

        let b = try fixture.transport("b")
        let fetch = try await b.fetchChanges(since: nil)
        #expect(fetch.isFullResync)
        #expect(!fetch.hasMore)
        #expect(Set(fetch.records.map(\.id)) == [first.id, second.id])
        for fetched in fetch.records {
            let original = fetched.id == first.id ? first : second
            #expect(fetched.rev == original.rev)
            #expect(fetched.blob == original.blob)
            #expect(fetched.deleted == original.deleted)
            #expect(fetched.recordVersion == versions[fetched.id])
        }
        let preflight = try await b.preflightScope()
        #expect(fetch.accountIdentity == preflight.identity)
        #expect(fetch.datasetIdentity == preflight.datasetIdentity)

        let again = try await b.fetchChanges(since: fetch.cursor)
        #expect(again.records.isEmpty)
        #expect(again.cursor == fetch.cursor)
        #expect(!again.isFullResync)

        let commits = try fixture.git(["--git-dir", fixture.bare.path, "rev-list", "--count", "main"])
        #expect(commits == "2")
        let message = try fixture.git(["--git-dir", fixture.bare.path, "log", "-1", "--format=%an <%ae>|%s", "main"])
        #expect(message == "Snippets Sync <sync@snippets.invalid>|Sync 2 records")
    }

    @Test func recordCASRejectsStaleBlindAndOrphanedWrites() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        let b = try fixture.transport("b")
        _ = try await a.initializeRepository()
        var original = record(rev: "r1", body: "v1")
        let v1 = try #require(try accepted(try await a.submit([original], at: nil))[original.id])

        _ = try await b.fetchChanges(since: nil)
        var update = original
        update.rev = "r2"
        update.blob = Data("v2".utf8)
        update.recordVersion = v1
        let v2 = try #require(try accepted(try await b.submit([update], at: nil))[original.id])
        #expect(v2 != v1)

        // Stale: built on v1, the branch now holds v2.
        original.rev = "r3"
        original.recordVersion = v1
        let stale = try await a.submit([original], at: nil)
        guard case .rejected(.conflict(let remote?)) = stale.results.first?.outcome else {
            Issue.record("expected a conflict carrying the authoritative record")
            return
        }
        #expect(remote.rev == "r2")
        #expect(remote.recordVersion == v2)

        // Blind create of an existing id.
        original.recordVersion = nil
        let blind = try await a.submit([original], at: nil)
        guard case .rejected(.conflict(let existing?)) = blind.results.first?.outcome else {
            Issue.record("expected a create conflict")
            return
        }
        #expect(existing.recordVersion == v2)

        // An update whose generation exists nowhere: tombstones are saves, so the file
        // was removed by hand. That is remote data loss for review, not a conflict loop.
        var orphan = record(rev: "r1", body: "orphan")
        orphan.recordVersion = v1
        await #expect(throws: SyncTransportFailure.remoteDataReset(detail: "git_record_removed")) {
            _ = try await a.submit([orphan], at: nil)
        }

        // The same id twice in one batch behaves like two sequential writes.
        let twice = record(rev: "x1", body: "x")
        var again = twice
        again.rev = "x2"
        let pair = try await a.submit([twice, again], at: nil)
        guard case .accepted = pair.results[0].outcome,
              case .rejected(.conflict(let sibling?)) = pair.results[1].outcome else {
            Issue.record("expected accept then conflict")
            return
        }
        #expect(sibling.rev == "x1")
    }

    @Test func identicalReuploadIsAcceptedWithoutACommit() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        var value = record(rev: "r1", body: "same")
        let version = try #require(try accepted(try await a.submit([value], at: nil))[value.id])
        value.recordVersion = version
        let again = try await a.submit([value], at: nil)
        #expect(try accepted(again)[value.id] == version)
        let commits = try fixture.git(["--git-dir", fixture.bare.path, "rev-list", "--count", "main"])
        #expect(commits == "2")
    }

    @Test func deltaFetchReturnsExactlyTheChangedRecordsAcrossManyCommits() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        let b = try fixture.transport("b")
        _ = try await a.initializeRepository()
        let batch = (0..<30).map { record(rev: "r1", body: "body \($0)") }
        let versions = try accepted(try await a.submit(batch, at: nil))
        let snapshot = try await b.fetchChanges(since: nil)
        #expect(snapshot.records.count == 30)

        var expected: [UUID: String] = [:]
        for index in [3, 7, 19] {
            var edit = batch[index]
            edit.rev = "r2-\(index)"
            edit.blob = Data("edited \(index)".utf8)
            edit.recordVersion = versions[edit.id]
            _ = try accepted(try await a.submit([edit], at: nil))
            expected[edit.id] = edit.rev
        }
        let created = record(rev: "new", body: "new")
        _ = try accepted(try await a.submit([created], at: nil))
        expected[created.id] = "new"

        let delta = try await b.fetchChanges(since: snapshot.cursor)
        #expect(!delta.isFullResync)
        #expect(Dictionary(uniqueKeysWithValues: delta.records.map { ($0.id, $0.rev) }) == expected)
    }

    @Test func lostPushRaceRebasesOntoTheNewHeadAndPreservesForeignFiles() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        fixture.beforeNextReceivePack {
            try fixture.commitAsAnotherWriter { work in
                try Data("hello\n".utf8).write(to: work.appending(path: "NOTES.md"))
            }
        }
        let value = record(rev: "r1", body: "raced")
        let before = fixture.requests.count
        _ = try accepted(try await a.submit([value], at: nil))

        // Rejected push, re-discovery, download of only the new head, successful push.
        #expect(Array(fixture.requests.dropFirst(before)) == [
            "GET refs?git-upload-pack", "GET refs?git-receive-pack", "POST git-receive-pack",
            "GET refs?git-receive-pack", "POST git-upload-pack", "POST git-receive-pack",
        ])
        let files = try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
        let path = GitSyncLayout.recordPath(value.id)
        #expect(files.split(separator: "\n").map(String.init).sorted()
                == ["NOTES.md", "README.md", "records/\(path.prefix)/\(path.name)", "snippets-sync.json"])
    }

    @Test func recordChangedDuringRaceIsReportedAsConflictOnRetry() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        var value = record(rev: "r1", body: "v1")
        value.recordVersion = try accepted(try await a.submit([value], at: nil))[value.id]

        var external = value
        external.rev = "external"
        external.blob = Data("from another device".utf8)
        fixture.beforeNextReceivePack {
            try fixture.commitAsAnotherWriter { work in
                let path = GitSyncLayout.recordPath(external.id)
                try GitRecordFile.encode(external).write(
                    to: work.appending(path: "records/\(path.prefix)/\(path.name)"))
            }
        }
        value.rev = "r2"
        value.blob = Data("v2".utf8)
        let submission = try await a.submit([value], at: nil)
        guard case .rejected(.conflict(let remote?)) = submission.results.first?.outcome else {
            Issue.record("expected the racing write to surface as a conflict")
            return
        }
        #expect(remote.rev == "external")
    }

    @Test func rejectionThatDoesNotMoveTheBranchIsPermanent() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        let hook = fixture.bare.appending(path: "hooks/pre-receive")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_push_rejected"))) {
            _ = try await a.submit([record(rev: "r1", body: "x")], at: nil)
        }
    }

    @Test func tombstoneIsARecordSave() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        let b = try fixture.transport("b")
        _ = try await a.initializeRepository()
        var value = record(rev: "r1", body: "alive")
        value.recordVersion = try accepted(try await a.submit([value], at: nil))[value.id]
        let cursor = try await b.fetchChanges(since: nil).cursor

        value.rev = "r2"
        value.deleted = true
        value.blob = Data("sealed tombstone".utf8)
        _ = try accepted(try await a.submit([value], at: nil))
        let delta = try await b.fetchChanges(since: cursor)
        #expect(delta.records.count == 1)
        #expect(delta.records.first?.deleted == true)
    }

    @Test func missingCacheFallsBackToAFullSnapshot() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        _ = try await a.initializeRepository()
        _ = try accepted(try await a.submit([record(rev: "r1", body: "x"), record(rev: "r1", body: "y")], at: nil))
        let cursor = try await fixture.transport("b").fetchChanges(since: nil).cursor
        _ = try accepted(try await a.submit([record(rev: "r1", body: "z")], at: nil))

        try FileManager.default.removeItem(at: fixture.cacheDirectory("b"))
        let fresh = try fixture.transport("b")
        let fetch = try await fresh.fetchChanges(since: cursor)
        #expect(fetch.isFullResync)
        #expect(fetch.replacesPriorPages)
        #expect(fetch.records.count == 3)
    }

    @Test func corruptCachedObjectIsRefetched() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        _ = try await a.initializeRepository()
        _ = try accepted(try await a.submit([record(rev: "r1", body: "x")], at: nil))
        let b = try fixture.transport("b")
        let cursor = try await b.fetchChanges(since: nil).cursor
        let objects = fixture.cacheDirectory("b").appending(path: "objects")
        for path in try FileManager.default.subpathsOfDirectory(atPath: objects.path) {
            let file = objects.appending(path: path)
            guard !file.hasDirectoryPath,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try Data("garbage".utf8).write(to: file)
        }
        _ = try accepted(try await a.submit([record(rev: "r1", body: "y")], at: nil))
        let fetch = try await fixture.transport("b").fetchChanges(since: cursor)
        #expect(fetch.isFullResync)
        #expect(fetch.records.count == 2)
    }

    @Test func manualRevertIsDeliveredEvenThoughItsBlobIsOnlyInHistory() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        let b = try fixture.transport("b")
        _ = try await a.initializeRepository()
        var value = record(rev: "r1", body: "v1")
        let v1 = try #require(try accepted(try await a.submit([value], at: nil))[value.id])
        _ = try await b.fetchChanges(since: nil)
        value.rev = "r2"
        value.blob = Data("v2".utf8)
        value.recordVersion = v1
        _ = try accepted(try await a.submit([value], at: nil))
        let cursor = try await b.fetchChanges(since: nil).cursor

        try fixture.commitAsAnotherWriter { work in
            try fixture.git(["-C", work.path, "revert", "--no-edit", "--no-commit", "HEAD"])
        }
        let delta = try await b.fetchChanges(since: cursor)
        #expect(delta.records.map(\.rev) == ["r1"])
        #expect(delta.records.first?.recordVersion == v1)
    }

    @Test func removedRecordFileRequiresReview() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        let b = try fixture.transport("b")
        _ = try await a.initializeRepository()
        let value = record(rev: "r1", body: "x")
        _ = try accepted(try await a.submit([value, record(rev: "r1", body: "y")], at: nil))
        let cursor = try await b.fetchChanges(since: nil).cursor
        try fixture.commitAsAnotherWriter { work in
            let path = GitSyncLayout.recordPath(value.id)
            try FileManager.default.removeItem(at: work.appending(path: "records/\(path.prefix)/\(path.name)"))
        }
        await #expect(throws: SyncTransportFailure.remoteDataReset(detail: "git_record_removed")) {
            _ = try await b.fetchChanges(since: cursor)
        }
    }

    @Test func replacedManifestIsARemoteResetUntilReviewed() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        _ = try await a.initializeRepository()
        _ = try accepted(try await a.submit([record(rev: "r1", body: "x")], at: nil))
        let before = try await a.preflightScope()

        try fixture.commitAsAnotherWriter { work in
            try GitSyncManifest(datasetID: UUID()).encoded()
                .write(to: work.appending(path: GitSyncLayout.manifestName))
        }
        let after = try await a.preflightScope()
        #expect(after.identity == before.identity)
        #expect(after.datasetIdentity != before.datasetIdentity)
        await #expect(throws: SyncTransportFailure.remoteDataReset(detail: "dataset_reset")) {
            _ = try await a.fetchChanges(since: nil)
        }
        await #expect(throws: SyncTransportFailure.remoteDataReset(detail: "dataset_reset")) {
            _ = try await a.submit([record(rev: "r1", body: "y")], at: nil)
        }
        await #expect(throws: SyncTransportFailure.remoteDataReset(detail: "dataset_reset")) {
            try await a.resetAfterRemoteDataResetReview(
                expectedIdentity: before.identity, expectedDatasetIdentity: before.datasetIdentity)
        }
        await #expect(throws: SyncTransportFailure.accountChanged) {
            try await a.resetAfterRemoteDataResetReview(
                expectedIdentity: SyncAccountIdentity(Data([1])), expectedDatasetIdentity: after.datasetIdentity)
        }
        try await a.resetAfterRemoteDataResetReview(
            expectedIdentity: after.identity, expectedDatasetIdentity: after.datasetIdentity)
        let fetch = try await a.fetchChanges(since: nil)
        #expect(fetch.datasetIdentity == after.datasetIdentity)
        #expect(fetch.records.count == 1)
    }

    @Test func manifestFromANewerSchemaStopsSync() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        _ = try await a.initializeRepository()
        try fixture.commitAsAnotherWriter { work in
            let newer = #"{"datasetID":"\#(UUID().uuidString.lowercased())","format":"snippets-git-sync","recordProfile":"snippets-wire-v2","schemaVersion":2}"#
            try Data(newer.utf8).write(to: work.appending(path: GitSyncLayout.manifestName))
        }
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_sync_schema_unsupported"))) {
            _ = try await fixture.transport("b").preflightScope()
        }
    }

    @Test func anEmptyBatchIsRejectedBeforeAnyRequest() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "invalid_batch_size"))) {
            _ = try await a.submit([], at: nil)
        }
        #expect(fixture.requests.isEmpty)
    }

    /// The engine offers everything pending in one call; the transport splits it into
    /// bounded commits instead of refusing it.
    @Test func largeBatchesAreSplitIntoBoundedCommits() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        _ = try await a.initializeRepository()
        let batch = (0..<120).map { record(rev: "r1", body: "body \($0)") }
        let submission = try await a.submit(batch, at: nil)
        #expect(submission.results.map(\.id) == batch.map(\.id))
        #expect(try accepted(submission).count == 120)
        let commits = try fixture.git(["--git-dir", fixture.bare.path, "rev-list", "--count", "main"])
        #expect(commits == "4") // creation + 50 + 50 + 20
        #expect(try await fixture.transport("b").fetchChanges(since: nil).records.count == 120)
    }

    @Test func anOversizedRecordIsRefusedAloneAndTheRestSync() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        var huge = record(rev: "r", body: "x")
        huge.blob = Data(count: GitSyncTransport.maximumBlobBytes + 1)
        let small = record(rev: "r", body: "small")
        let submission = try await a.submit([huge, small], at: nil)
        #expect(submission.results[0].outcome == .rejected(.permanent(detail: "record_too_large")))
        guard case .accepted = submission.results[1].outcome else {
            Issue.record("the small record must still be accepted")
            return
        }
        #expect(try await fixture.transport("b").fetchChanges(since: nil).records.map(\.id) == [small.id])
    }

    @Test func aMalformedRecordFileIsQuarantinedNotFatal() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        _ = try await a.initializeRepository()
        let good = record(rev: "r1", body: "good")
        _ = try accepted(try await a.submit([good], at: nil))
        let damaged = UUID()
        try fixture.commitAsAnotherWriter { work in
            let path = GitSyncLayout.recordPath(damaged)
            let folder = work.appending(path: "records/\(path.prefix)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: folder.appending(path: path.name))
        }
        let records = try await fixture.transport("b").fetchChanges(since: nil).records
        #expect(Set(records.map(\.id)) == [good.id, damaged])
        let unreadable = try #require(records.first { $0.id == damaged })
        #expect(unreadable.blob.isEmpty)
        #expect(unreadable.recordVersion != nil)
    }

    @Test func aDeletedBranchIsReportedAsUninitializedOnEveryPath() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        _ = try await a.preflightScope()
        try fixture.git(["--git-dir", fixture.bare.path, "update-ref", "-d", "refs/heads/main"])
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_repository_not_initialized"))) {
            _ = try await a.submit([record(rev: "r1", body: "x")], at: nil)
        }
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_repository_not_initialized"))) {
            _ = try await a.fetchChanges(since: nil)
        }
    }

    @Test func shutdownStopsFurtherWork() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        await a.shutdown()
        await #expect(throws: SyncTransportFailure.unreachable(detail: "git_transport_shut_down")) {
            _ = try await a.fetchChanges(since: nil)
        }
    }

    @Test func pollingAnUnchangedBranchCostsOneDiscoveryRequest() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        _ = try accepted(try await a.submit([record(rev: "r1", body: "x")], at: nil))
        let cursor = try await a.fetchChanges(since: nil).cursor
        let before = fixture.requests.count
        _ = try await a.fetchChanges(since: cursor)
        #expect(Array(fixture.requests.dropFirst(before)) == ["GET refs?git-upload-pack"])
    }

    // MARK: Helpers

    private func record(rev: String, body: String, deleted: Bool = false) -> WireRecord {
        WireRecord(id: UUID(), rev: rev, deleted: deleted, blob: Data(body.utf8))
    }

    private func accepted(_ submission: SyncSubmission) throws -> [UUID: SyncRecordVersion] {
        var versions: [UUID: SyncRecordVersion] = [:]
        for result in submission.results {
            guard case .accepted(_, let version) = result.outcome else {
                throw GitFixtureError.commandFailed("record was not accepted: \(result.outcome)")
            }
            versions[result.id] = version
        }
        return versions
    }

    private func seedForeignBranch(_ fixture: GitFixture) throws {
        let work = fixture.root.appending(path: "foreign", directoryHint: .isDirectory)
        try fixture.git(["init", "--quiet", "--initial-branch=main", work.path])
        try Data("int main(void) { return 0; }\n".utf8).write(to: work.appending(path: "main.c"))
        try fixture.git(["-C", work.path, "add", "-A"])
        try fixture.git(["-C", work.path, "commit", "--quiet", "-m", "code"])
        try fixture.git(["-C", work.path, "push", "--quiet", fixture.bare.path, "HEAD:refs/heads/main"])
    }
}

/// Two complete sync engines, each with its own library, state and cache, converging
/// through one git repository.
@MainActor
@Suite("Git sync end to end")
struct GitSyncEndToEndTests {
    private final class Library: SyncLibraryAccess {
        var envelopes: [UUID: SyncEnvelope] = [:]

        func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] { envelopes }

        func classifyRemote(_ incoming: [SyncEnvelope]) -> RemoteClassification {
            RemoteClassification(applicable: incoming, deferredIDs: [], incompatibleVaultIDs: [])
        }

        func applyRemote(_ incoming: [SyncEnvelope]) throws -> ApplyOutcome {
            for envelope in incoming {
                envelopes[envelope.id] = envelope.deleted ? nil : envelope
            }
            return ApplyOutcome(changedIDs: incoming.map(\.id), deferredIDs: [])
        }

        func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
    }

    private struct Device {
        let library: Library
        let engine: SyncEngine
        let name: String
    }

    private func device(
        _ name: String, fixture: GitFixture, sealer: SnippetCryptoSealer, plainText: Bool = false
    ) throws -> Device {
        let directory = fixture.root.appending(path: "device-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = Library()
        let engine = SyncEngine(
            transport: try fixture.transport(name, plainText: plainText ? GitPlainCodec(sealer: sealer) : nil),
            library: library, sealer: sealer, device: name,
            baseURL: directory.appending(path: "base.json"),
            stateURL: directory.appending(path: "state.json"),
            lockURL: directory.appending(path: "library.lock"),
            temporaryDirectory: directory)
        return Device(library: library, engine: engine, name: name)
    }

    private func envelope(
        _ id: UUID, name: String, content: String, ms: UInt64, device: String
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: ms, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name, keyword: name, content: Data(content.utf8), tags: [],
                isEnabled: true, isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(ms) / 1_000)))
    }

    private func expectIdle(_ state: SyncEngine.State, sourceLocation: SourceLocation = #_sourceLocation) {
        if case .idle = state { return }
        Issue.record("engine is not idle: \(state)", sourceLocation: sourceLocation)
    }

    /// Two engines on a plain-text library: readable files, an edit made in the
    /// repository adopted by both, and an in-app edit on top of it.
    @Test func plainTextLibrariesConvergeIncludingAnEditMadeInTheRepository() async throws {
        let fixture = try GitFixture()
        _ = try await fixture.transport("setup").initializeRepository(mode: .plainText)
        let sealer = SnippetCryptoSealer(keyring: SnippetCrypto.Keyring.generate(), scopeID: "sync-v1")
        let mac = try device("aaaaaaa1", fixture: fixture, sealer: sealer, plainText: true)
        let phone = try device("bbbbbbb2", fixture: fixture, sealer: sealer, plainText: true)
        let id = UUID()
        mac.library.envelopes[id] = envelope(id, name: "Signature", content: "Best regards", ms: 1_000, device: mac.name)
        expectIdle(await mac.engine.sync())
        expectIdle(await phone.engine.sync())
        #expect(phone.library.envelopes[id]?.plainSnippet?.content == "Best regards")
        let path = try #require(try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
            .split(separator: "\n").map(String.init).first { $0.hasPrefix("snippets/signature-") })

        try fixture.commitAsAnotherWriter { work in
            let url = work.appending(path: path)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "Best regards", with: "Kind regards").utf8).write(to: url)
        }
        expectIdle(await phone.engine.sync())
        expectIdle(await mac.engine.sync())
        #expect(phone.library.envelopes[id]?.plainSnippet?.content == "Kind regards")
        #expect(mac.library.envelopes[id]?.plainSnippet?.content == "Kind regards")

        var local = try #require(mac.library.envelopes[id])
        local = envelope(id, name: "Signature", content: "Cheers", ms: 9_000, device: mac.name)
        mac.library.envelopes[id] = local
        expectIdle(await mac.engine.sync())
        expectIdle(await phone.engine.sync())
        #expect(phone.library.envelopes[id]?.plainSnippet?.content == "Cheers")
        #expect(try fixture.git(["--git-dir", fixture.bare.path, "show", "main:\(path)"]).contains("Cheers"))
    }

    @Test func aLibraryLargerThanOneBatchSyncs() async throws {
        let fixture = try GitFixture()
        _ = try await fixture.transport("setup").initializeRepository()
        let sealer = SnippetCryptoSealer(keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
        let mac = try device("aaaaaaa1", fixture: fixture, sealer: sealer)
        let phone = try device("bbbbbbb2", fixture: fixture, sealer: sealer)
        for index in 0..<60 {
            let id = UUID()
            mac.library.envelopes[id] = envelope(id, name: "s\(index)", content: "c\(index)", ms: 1_000, device: mac.name)
        }
        expectIdle(await mac.engine.sync())
        expectIdle(await phone.engine.sync())
        #expect(phone.library.envelopes.count == 60)
    }

    @Test func twoDevicesConvergeThroughOneRepository() async throws {
        let fixture = try GitFixture()
        _ = try await fixture.transport("setup").initializeRepository()
        let sealer = SnippetCryptoSealer(keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
        let mac = try device("aaaaaaa1", fixture: fixture, sealer: sealer)
        let phone = try device("bbbbbbb2", fixture: fixture, sealer: sealer)

        // Create on one device, receive on the other.
        let shared = UUID()
        let marker = "plaintext-marker-\(UUID().uuidString)"
        mac.library.envelopes[shared] = envelope(shared, name: marker, content: "https://meet", ms: 1_000, device: mac.name)
        expectIdle(await mac.engine.sync())
        expectIdle(await phone.engine.sync())
        #expect(phone.library.envelopes[shared]?.fields?.content == Data("https://meet".utf8))

        // Edit on the second device, receive on the first.
        phone.library.envelopes[shared] = envelope(shared, name: marker, content: "https://meet/2", ms: 2_000, device: phone.name)
        expectIdle(await phone.engine.sync())
        expectIdle(await mac.engine.sync())
        #expect(mac.library.envelopes[shared]?.fields?.content == Data("https://meet/2".utf8))

        // Concurrent edits to different records both survive.
        let fromMac = UUID()
        let fromPhone = UUID()
        mac.library.envelopes[fromMac] = envelope(fromMac, name: "a", content: "mac", ms: 3_000, device: mac.name)
        phone.library.envelopes[fromPhone] = envelope(fromPhone, name: "b", content: "phone", ms: 3_000, device: phone.name)
        expectIdle(await mac.engine.sync())
        expectIdle(await phone.engine.sync())
        expectIdle(await mac.engine.sync())
        #expect(Set(mac.library.envelopes.keys) == [shared, fromMac, fromPhone])
        #expect(Set(phone.library.envelopes.keys) == [shared, fromMac, fromPhone])

        // A deletion travels as a tombstone.
        mac.library.envelopes[fromPhone] = nil
        expectIdle(await mac.engine.sync())
        expectIdle(await phone.engine.sync())
        #expect(phone.library.envelopes[fromPhone] == nil)

        // The repository only ever holds ciphertext, in every historical version.
        let history = try fixture.git(["--git-dir", fixture.bare.path, "log", "-p", "main"])
        #expect(history.contains("records/"))
        #expect(!history.contains(marker))
        #expect(!history.contains("https://meet"))
    }

    /// The engine is developed against `InMemoryTransport`; the git transport must
    /// drive it to exactly the same outcome when two devices edit one record.
    @Test func concurrentEditsMatchTheReferenceTransport() async throws {
        func run(_ makeTransport: (String) throws -> any SyncTransport) async throws -> [[String]] {
            let sealer = SnippetCryptoSealer(keyring: SnippetCrypto.Keyring.generate(), scopeID: "k-test")
            let root = FileManager.default.temporaryDirectory
                .appending(path: "parity-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }
            var devices: [Device] = []
            for name in ["aaaaaaa1", "bbbbbbb2"] {
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let library = Library()
                devices.append(Device(library: library, engine: SyncEngine(
                    transport: try makeTransport(name), library: library, sealer: sealer, device: name,
                    baseURL: directory.appending(path: "base.json"),
                    stateURL: directory.appending(path: "state.json"),
                    lockURL: directory.appending(path: "library.lock"),
                    temporaryDirectory: directory), name: name))
            }
            let (mac, phone) = (devices[0], devices[1])
            let id = UUID()
            mac.library.envelopes[id] = envelope(id, name: "x", content: "base", ms: 1_000, device: mac.name)
            expectIdle(await mac.engine.sync())
            expectIdle(await phone.engine.sync())
            mac.library.envelopes[id] = envelope(id, name: "x", content: "mac edit", ms: 5_000, device: mac.name)
            phone.library.envelopes[id] = envelope(id, name: "x", content: "phone edit", ms: 6_000, device: phone.name)
            for device in [mac, phone, mac, phone, mac] { expectIdle(await device.engine.sync()) }
            return devices.map { device in
                device.library.envelopes.values
                    .map { String(decoding: $0.fields?.content ?? Data(), as: UTF8.self) }
                    .sorted()
            }
        }

        let memory = InMemoryTransport()
        let reference = try await run { _ in memory }
        let fixture = try GitFixture()
        _ = try await fixture.transport("setup").initializeRepository()
        let git = try await run { try fixture.transport($0) }
        #expect(git == reference)
        // Both devices hold the conflict copy; nothing was lost.
        #expect(git.allSatisfy { $0.contains("mac edit") })
        #expect(git.joined().contains("phone edit"))
    }
}

@Suite("Git sync recovery and library files")
struct GitSyncRecoveryTests {
    private static let material = Data((0..<64).map { UInt8($0) })

    @Test func recoveryEnvelopeOpensOnlyWithItsCodeAndLibrary() throws {
        let dataset = UUID()
        let kit = GitSyncRecovery.Kit(datasetID: dataset)
        let file = try GitSyncRecovery.seal(material: Self.material, kit: kit)
        #expect(!String(decoding: file, as: UTF8.self).contains(kit.code))

        // What a person types: lowercase, spaces, misread O and I.
        let typed = kit.code.lowercased().replacingOccurrences(of: "-", with: " ")
        let reopened = try GitSyncRecovery.Kit(code: typed, datasetID: dataset)
        #expect(try GitSyncRecovery.open(file, kit: reopened) == Self.material)

        let otherCode = GitSyncRecovery.Kit(datasetID: dataset)
        #expect(throws: GitSyncRecovery.Failure.incorrectCode) {
            _ = try GitSyncRecovery.open(file, kit: otherCode)
        }
        #expect(throws: GitSyncRecovery.Failure.invalidEnvelope) {
            _ = try GitSyncRecovery.open(file, kit: GitSyncRecovery.Kit(datasetID: UUID(), secret: kit.secret))
        }
        var typo = Array(kit.code)
        typo[0] = typo[0] == "A" ? "B" : "A"
        #expect(throws: GitSyncRecovery.Failure.invalidCode) {
            _ = try GitSyncRecovery.Kit(code: String(typo), datasetID: dataset)
        }
        #expect(throws: GitSyncRecovery.Failure.invalidCode) {
            _ = try GitSyncRecovery.Kit(code: "short", datasetID: dataset)
        }
        var tampered = try #require(String(data: file, encoding: .utf8))
        tampered = tampered.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
        #expect(throws: GitSyncRecovery.Failure.invalidEnvelope) {
            _ = try GitSyncRecovery.open(Data(tampered.utf8), kit: kit)
        }
    }

    @Test func libraryIsCreatedWithItsKeyFilesAndTheyCanBeReadAndReplaced() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        let dataset = UUID()
        let kit = GitSyncRecovery.Kit(datasetID: dataset)
        let envelope = try GitSyncRecovery.seal(material: Self.material, kit: kit)
        #expect(try await a.initializeRepository(datasetID: dataset, files: [GitSyncRecovery.path: envelope])
                == dataset)
        let files = try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
        #expect(files.split(separator: "\n") == ["README.md", "keys/recovery.json", "snippets-sync.json"])

        let b = try fixture.transport("b")
        #expect(try await b.readFile(GitSyncRecovery.path) == envelope)
        #expect(try await b.readFile("keys/absent.json") == nil)

        // A record commit in between must survive the key-file commit.
        _ = try await a.submit([WireRecord(id: UUID(), rev: "r1", deleted: false, blob: Data("x".utf8))], at: nil)
        let replacement = try GitSyncRecovery.seal(material: Self.material, kit: GitSyncRecovery.Kit(datasetID: dataset))
        try await b.writeFiles([GitSyncRecovery.path: replacement], message: "Replace recovery envelope")
        #expect(try await a.readFile(GitSyncRecovery.path) == replacement)
        let records = try await fixture.transport("c").fetchChanges(since: nil).records
        #expect(records.count == 1)
        let log = try fixture.git(["--git-dir", fixture.bare.path, "log", "--format=%s", "main"])
        #expect(log.split(separator: "\n").first == "Replace recovery envelope")

        // Identical content is not a commit.
        try await b.writeFiles([GitSyncRecovery.path: replacement], message: "No-op")
        #expect(try fixture.git(["--git-dir", fixture.bare.path, "log", "-1", "--format=%s", "main"])
                == "Replace recovery envelope")
    }

    @Test func keyFileWriteRetriesALostRace() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        let dataset = try await a.initializeRepository()
        fixture.beforeNextReceivePack {
            try fixture.commitAsAnotherWriter { work in
                try Data("notes\n".utf8).write(to: work.appending(path: "NOTES.md"))
            }
        }
        let envelope = try GitSyncRecovery.seal(material: Self.material, kit: GitSyncRecovery.Kit(datasetID: dataset))
        try await a.writeFiles([GitSyncRecovery.path: envelope], message: "Add recovery envelope")
        let files = try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
        #expect(files.contains("NOTES.md") && files.contains("keys/recovery.json"))
    }

    @Test func onlyKeyPathsCanBeReadOrWritten() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport()
        _ = try await a.initializeRepository()
        for path in ["snippets-sync.json", "records/aa/x.json", "keys", "keys/../records", "keys/.hidden",
                     "keys//x", "/keys/x", "keys/a b"] {
            await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_invalid_path"))) {
                try await a.writeFiles([path: Data("x".utf8)], message: "x")
            }
            await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_invalid_path"))) {
                _ = try await a.readFile(path)
            }
        }
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_invalid_path"))) {
            _ = try await fixture.transport("x").initializeRepository(files: ["README.md": Data()])
        }
    }

    /// Rotating a library's keys: one commit puts a new, empty library in the old
    /// one's place. Nothing of the old library stays in the tree, files that are not
    /// ours do, and every device connected to the old library stops.
    @Test func replacingALibraryLeavesNothingOfTheOldOneInTheTree() async throws {
        for mode in GitLibraryMode.allCases {
            let fixture = try GitFixture()
            let setup = try fixture.transport("setup")
            let old = UUID()
            let oldEnvelope = try GitSyncRecovery.seal(material: Self.material, kit: .init(datasetID: old))
            _ = try await setup.initializeRepository(
                datasetID: old, files: [GitSyncRecovery.path: oldEnvelope, "keys/extra.json": Data("x".utf8)],
                mode: mode)
            let connected = GitSyncTransport(
                configuration: .init(
                    remote: try fixture.remote(), cacheDirectory: fixture.cacheDirectory("connected"),
                    expectedDatasetID: old),
                session: fixture.session)
            _ = try await connected.preflightScope()
            let stale = GitSyncLayout.recordPath(UUID())
            try fixture.commitAsAnotherWriter { work in
                try Data("notes\n".utf8).write(to: work.appending(path: "NOTES.md"))
                try FileManager.default.createDirectory(
                    at: work.appending(path: "records/\(stale.prefix)"), withIntermediateDirectories: true)
                try GitRecordFile.encode(WireRecord(id: UUID(), rev: "r1", deleted: false, blob: Data("x".utf8)))
                    .write(to: work.appending(path: "records/\(stale.prefix)/\(stale.name)"))
                if mode == .plainText {
                    try FileManager.default.createDirectory(
                        at: work.appending(path: "snippets"), withIntermediateDirectories: true)
                    try Data("Hello\n".utf8).write(to: work.appending(path: "snippets/hello.md"))
                }
            }
            let head = try #require(GitObjectID(hex: try fixture.git(
                ["--git-dir", fixture.bare.path, "rev-parse", "main"])))

            let new = UUID()
            let envelope = try GitSyncRecovery.seal(material: Self.material, kit: .init(datasetID: new))
            // A library that is not the one named, or stored another way, is left alone.
            await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_library_replaced"))) {
                try await setup.replaceLibrary(
                    UUID(), with: new, files: [GitSyncRecovery.path: envelope], mode: mode)
            }
            let otherMode = GitLibraryMode.allCases.first { $0 != mode }!
            await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_library_mode_changed"))) {
                try await setup.replaceLibrary(
                    old, with: new, files: [GitSyncRecovery.path: envelope], mode: otherMode)
            }
            await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_invalid_path"))) {
                try await setup.replaceLibrary(old, with: new, files: ["README.md": Data()], mode: mode)
            }
            try await setup.replaceLibrary(
                old, with: new, files: [GitSyncRecovery.path: envelope], mode: mode, expectedHead: head)

            let files = try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
            #expect(files.split(separator: "\n") == ["NOTES.md", "README.md", "keys/recovery.json", "snippets-sync.json"])
            #expect(try fixture.git(["--git-dir", fixture.bare.path, "log", "-1", "--format=%s", "main"])
                    == "Replace library keys")
            #expect(try fixture.git(["--git-dir", fixture.bare.path, "rev-parse", "main^"]) == head.hex,
                    "an ordinary commit on top of the old head, never a rewrite")
            let manifest = try GitSyncManifest.decode(Data(try fixture.git(
                ["--git-dir", fixture.bare.path, "show", "main:snippets-sync.json"]).utf8))
            #expect(manifest == GitSyncManifest(
                datasetID: new, mode: mode, schemaVersion: GitSyncManifest.rotatedSchemaVersion))

            // The new library is empty and opens only with its own envelope.
            let joined = GitSyncTransport(
                configuration: .init(
                    remote: try fixture.remote(), cacheDirectory: fixture.cacheDirectory("joined"),
                    expectedDatasetID: new),
                session: fixture.session)
            #expect(try await joined.readFile(GitSyncRecovery.path) == envelope)
            #expect(try await joined.readFile("keys/extra.json") == nil)
            if mode == .encrypted {
                #expect(try await joined.fetchChanges(since: nil).records.isEmpty)
                let value = WireRecord(id: UUID(), rev: "r1", deleted: false, blob: Data("y".utf8))
                #expect(try await joined.submit([value], at: nil).results.count == 1)
            }
            // Every device of the old library stops instead of writing under its key.
            await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_library_replaced"))) {
                _ = try await connected.preflightScope()
            }
            // A repeated call (a lost response) is success and writes nothing.
            let before = try fixture.git(["--git-dir", fixture.bare.path, "rev-parse", "main"])
            try await setup.replaceLibrary(old, with: new, files: [GitSyncRecovery.path: envelope], mode: mode)
            #expect(try fixture.git(["--git-dir", fixture.bare.path, "rev-parse", "main"]) == before)
        }
    }

    /// The caller replaces only the library it has fully synced: a branch that moved
    /// since holds changes it has not merged.
    @Test func replacingALibraryIsRefusedWhenTheBranchMoved() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a")
        let old = try await a.initializeRepository()
        let synced = try #require(GitObjectID(hex: try fixture.git(
            ["--git-dir", fixture.bare.path, "rev-parse", "main"])))
        _ = try await fixture.transport("b").submit(
            [WireRecord(id: UUID(), rev: "r1", deleted: false, blob: Data("x".utf8))], at: nil)
        let envelope = try GitSyncRecovery.seal(material: Self.material, kit: .init(datasetID: old))
        await #expect(throws: SyncTransportFailure.unreachable(detail: "git_ref_moved")) {
            try await a.replaceLibrary(
                old, with: UUID(), files: [GitSyncRecovery.path: envelope], mode: .encrypted, expectedHead: synced)
        }
        // A writer that gets in between discovery and the push loses nothing either.
        let head = try #require(GitObjectID(hex: try fixture.git(
            ["--git-dir", fixture.bare.path, "rev-parse", "main"])))
        fixture.beforeNextReceivePack {
            try fixture.commitAsAnotherWriter { work in
                try Data("notes\n".utf8).write(to: work.appending(path: "NOTES.md"))
            }
        }
        await #expect(throws: SyncTransportFailure.unreachable(detail: "git_ref_moved")) {
            try await a.replaceLibrary(
                old, with: UUID(), files: [GitSyncRecovery.path: envelope], mode: .encrypted, expectedHead: head)
        }
        #expect(try await fixture.transport("c").fetchChanges(since: nil).records.count == 1)
        #expect(try await fixture.transport("c").inspectRepository() == .library(datasetID: old))
    }

    @Test func aRotatedLibrarysManifestKeepsOlderBuildsOut() throws {
        let rotated = GitSyncManifest(
            datasetID: UUID(), mode: .plainText, schemaVersion: GitSyncManifest.rotatedSchemaVersion)
        let text = String(decoding: try rotated.encoded(), as: UTF8.self)
        #expect(text.contains("\"schemaVersion\" : 2"))
        #expect(try GitSyncManifest.decode(Data(text.utf8)) == rotated)
        #expect(GitSyncManifest(datasetID: rotated.datasetID, mode: .plainText) != rotated)
        let future = text.replacingOccurrences(of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : 3")
        #expect(throws: GitSyncLayoutError.incompatibleSchema) { _ = try GitSyncManifest.decode(Data(future.utf8)) }
    }

    @Test func connectedLibraryReplacedUnderneathStopsTheDataPlane() async throws {
        let fixture = try GitFixture()
        let setup = try fixture.transport("setup")
        let dataset = try await setup.initializeRepository()
        let connected = GitSyncTransport(
            configuration: .init(
                remote: try fixture.remote(), cacheDirectory: fixture.cacheDirectory("connected"),
                expectedDatasetID: dataset),
            session: fixture.session)
        _ = try await connected.preflightScope()
        _ = try await connected.submit([WireRecord(id: UUID(), rev: "r1", deleted: false, blob: Data("x".utf8))], at: nil)

        try fixture.commitAsAnotherWriter { work in
            try GitSyncManifest(datasetID: UUID()).encoded()
                .write(to: work.appending(path: GitSyncLayout.manifestName))
        }
        for operation in ["preflight", "fetch", "submit"] {
            await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_library_replaced")), "\(operation)") {
                switch operation {
                case "preflight": _ = try await connected.preflightScope()
                case "fetch": _ = try await connected.fetchChanges(since: nil)
                default:
                    _ = try await connected.submit(
                        [WireRecord(id: UUID(), rev: "r1", deleted: false, blob: Data("y".utf8))], at: nil)
                }
            }
        }
        // A device connected to a different library never adopts this one either.
        let wrong = GitSyncTransport(
            configuration: .init(
                remote: try fixture.remote(), cacheDirectory: fixture.cacheDirectory("wrong"),
                expectedDatasetID: UUID()),
            session: fixture.session)
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_library_replaced"))) {
            _ = try await wrong.preflightScope()
        }
    }
}
