import Foundation
import Testing
@testable import SnippetsCore

@Suite struct GitRepositoryLocationTests {
    @Test func everySpellingOfOneRepositoryHasOneIdentity() throws {
        let spellings = [
            "https://github.com/me/lib",
            "https://GitHub.com/me/lib.git",
            "https://github.com/me/lib/",
            "github.com/me/lib",
            "git@github.com:me/lib.git",
            "git@GitHub.com:me/lib",
            "ssh://git@github.com/me/lib.git",
            "ssh://git@github.com:22/me/lib",
            "git+ssh://git@github.com/me/lib.git",
        ]
        for spelling in spellings {
            #expect(try GitRepositoryLocation.parse(spelling).canonicalIdentity == "github.com/me/lib", "\(spelling)")
        }
        #expect(try GitRepositoryLocation.parse("git@github.com:me/Lib").canonicalIdentity == "github.com/me/Lib")
        #expect(try GitRepositoryLocation.parse("https://gitverse.ru/me/lib%20x").canonicalIdentity == "gitverse.ru/me/lib x")
    }

    @Test func sshSpellingsParseIntoTheirParts() throws {
        guard case .ssh(let scp) = try GitRepositoryLocation.parse(" git@github.com:me/lib.git\n") else {
            Issue.record("expected ssh")
            return
        }
        #expect(scp == (try GitSSHLocation(user: "git", host: "github.com", port: nil, path: "me/lib.git", scpStyle: true)))
        #expect(scp.spec == "git@github.com:me/lib.git")

        guard case .ssh(let url) = try GitRepositoryLocation.parse("ssh://git@[::1]:2222/srv/lib.git") else {
            Issue.record("expected ssh")
            return
        }
        #expect(url.host == "::1")
        #expect(url.port == 2222)
        #expect(url.path == "/srv/lib.git")
        #expect(url.spec == "ssh://git@[::1]:2222/srv/lib.git")
        #expect(try GitRepositoryLocation.parse(url.spec) == .ssh(url))

        guard case .ssh(let alias) = try GitRepositoryLocation.parse("work-github:team/lib") else {
            Issue.record("an ~/.ssh/config alias without a user is still ssh")
            return
        }
        #expect(alias.user == nil)
        #expect(alias.destination == "work-github")
        #expect(try GitRepositoryLocation.parse("https://host/a").isSSH == false)
    }

    @Test func valuesThatCouldReachAShellOrAnOptionAreRefused() {
        for hostile in [
            "-oProxyCommand=evil:repo", "git@-oProxyCommand=x:repo", "git@host:-repo",
            "git@host:repo;rm", "git@host:'repo'", "git@host:$(id)", "git@host:a/../b",
            "git@host:repo name", "ssh://git@host/repo`x`", "ssh://user:pw@host/repo",
            "ssh://host/repo?x=1", "git@.host:repo", "git@host:", "ftp://host/repo",
            "http://example.com/repo",
        ] {
            #expect(throws: GitRemote.Failure.invalidURL, "\(hostile)") {
                _ = try GitRepositoryLocation.parse(hostile)
            }
        }
    }

    /// Settings stores `spec` and requires that reading it back gives the same text.
    @Test func savedAddressesRoundTrip() throws {
        for raw in [
            "git@github.com:me/lib.git", "ssh://git@github.com/me/lib.git", "ssh://git@[::1]:2222/srv/lib.git",
            "git+ssh://git@host/r.git", "SSH://git@Host:22/r", "work-alias:team/lib", "ssh://h/~me/lib.git",
            "https://github.com/me/lib", "https://gitverse.ru/me/lib.git/", "https://h:8443/a/b",
            "git@host:päth/lib.git",
        ] {
            let location = try GitRepositoryLocation.parse(raw)
            #expect(try GitRepositoryLocation.parse(location.spec) == location, "\(raw)")
            #expect(try GitRepositoryLocation.parse(location.spec).spec == location.spec, "\(raw)")
        }
        // A decoded `%` would be re-decoded on the next read; refuse it.
        #expect(throws: GitRemote.Failure.invalidURL) { _ = try GitRepositoryLocation.parse("ssh://git@host/a%2541") }
        #expect(throws: GitRemote.Failure.invalidURL) { _ = try GitRepositoryLocation.parse("git@host:a%41") }
    }

    @Test func remoteCommandsQuoteThePathLikeGit() throws {
        let scp = try GitSSHLocation(user: "git", host: "h", port: nil, path: "me/lib.git", scpStyle: true)
        #expect(GitSSHClient.remoteCommand(.uploadPack, location: scp) == "git-upload-pack 'me/lib.git'")
        let home = try GitSSHLocation(user: nil, host: "h", port: nil, path: "/~me/lib.git", scpStyle: false)
        #expect(GitSSHClient.remoteCommand(.receivePack, location: home) == "git-receive-pack '~me/lib.git'")
    }

    /// Two `~/.ssh/config` aliases for one host (a deploy key each) must not share a
    /// connection: `%C` alone hashes the resolved host, not the alias.
    @Test func sharedConnectionsAreKeptApartPerAlias() throws {
        let connector = GitSystemSSHConnector()
        func controlPath(_ spec: String) throws -> String? {
            guard case .ssh(let location) = try GitRepositoryLocation.parse(spec) else { return nil }
            return connector.arguments(command: "git-upload-pack 'x'", location: location)
                .first { $0.hasPrefix("ControlPath=") }
        }
        let first = try #require(try controlPath("git@github-work:me/a.git"))
        let second = try #require(try controlPath("git@github-home:me/b.git"))
        #expect(first != second)
        #expect(first == (try controlPath("git@github-work:me/other.git")), "one alias still shares")
        #expect(first.count < 80, "unix socket paths are limited to 104 bytes once %C expands")
    }

    @Test func systemSSHNeverPromptsAndEndsOptionsBeforeTheHost() throws {
        let location = try GitSSHLocation(user: "git", host: "h", port: 2222, path: "r", scpStyle: true)
        let arguments = GitSystemSSHConnector().arguments(command: "git-upload-pack 'r'", location: location)
        #expect(arguments.suffix(3) == ["--", "git@h", "git-upload-pack 'r'"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains { $0.hasPrefix("ControlPath=/tmp/snippets-ssh-") && $0.contains("/%C-") })
        #expect(!GitSystemSSHConnector(sharesConnections: false)
            .arguments(command: "c", location: location).contains("ControlMaster=auto"))
        for reset in ["RemoteCommand=none", "SessionType=default", "StdinNull=no", "ForkAfterAuthentication=no"] {
            #expect(arguments.contains(reset), "\(reset)")
        }
        #expect(arguments.contains("-a"))
        let port = try #require(arguments.firstIndex(of: "-p"))
        #expect(arguments[port + 1] == "2222")
    }

    @Test func remoteDescriptionsNeverCarryTheToken() throws {
        let remote = try GitRemote(
            url: try #require(URL(string: "https://h/r")), branch: "main", username: "u", password: "tok-secret")
        #expect(!String(describing: remote).contains("tok-secret"))
        let ssh = try GitRemote(ssh: try GitSSHLocation(user: "git", host: "h", port: nil, path: "r", scpStyle: true), branch: "main")
        #expect(ssh.canonicalLocation == "h/r")
        #expect(ssh.password.isEmpty)
    }
}

@Suite struct GitSSHFramingTests {
    /// GitHub acknowledges every common have, not just the first.
    @Test func extraAcknowledgementsBeforeThePackAreSkipped() throws {
        var bytes = [UInt8]()
        for line in ["ACK \(String(repeating: "a", count: 40))", "ACK \(String(repeating: "b", count: 40))", "NAK"] {
            bytes += [UInt8](try GitPktLine.line(line))
        }
        bytes += [UInt8](try GitPktLine.encode([1] + Array("PACK".utf8)))
        bytes += [UInt8](GitPktLine.flush)
        let pack = try GitSmartHTTPClient.extractPack(from: bytes, expectsShallowInfo: false, sideBand: "side-band-64k")
        #expect(pack == Data("PACK".utf8))
    }

    /// Without side-band the pack follows the acknowledgement raw; it is not a pkt-line.
    @Test func aPackWithoutSideBandIsReadRaw() throws {
        var bytes = [UInt8](try GitPktLine.line("NAK"))
        bytes += Array("PACK\u{0}\u{0}\u{0}\u{2}rest".utf8)
        let pack = try GitSmartHTTPClient.extractPack(from: bytes, expectsShallowInfo: false, sideBand: nil)
        #expect(pack == Data("PACK\u{0}\u{0}\u{0}\u{2}rest".utf8))
    }

    @Test func onlyAnEmptyCacheAsksForAShallowTip() throws {
        let present: String? = nil
        var advertisement = GitRefAdvertisement(refs: [:], capabilities: ["shallow": present, "side-band-64k": present])
        let want = GitObjectID.hash(type: .blob, content: Array("w".utf8))
        let have = GitObjectID.hash(type: .blob, content: Array("h".utf8))
        let fresh = try GitSmartHTTPClient.uploadRequest(want: want, haves: [], advertisement: advertisement)
        #expect(fresh.shallow)
        #expect(String(decoding: fresh.body, as: UTF8.self).contains("deepen 1"))
        let incremental = try GitSmartHTTPClient.uploadRequest(want: want, haves: [have], advertisement: advertisement)
        #expect(!incremental.shallow)
        let text = String(decoding: incremental.body, as: UTF8.self)
        #expect(!text.contains("deepen") && !text.contains("shallow"))
        #expect(text.contains("have \(have.hex)"))
        advertisement.capabilities.removeValue(forKey: "shallow")
        #expect(!(try GitSmartHTTPClient.uploadRequest(want: want, haves: [], advertisement: advertisement)).shallow)
    }

    @Test func advertisementEndIsTheFirstFlush() throws {
        let line = try GitPktLine.line("abc")
        var bytes = [UInt8](line) + [UInt8](GitPktLine.flush)
        #expect(try GitPktLine.advertisementEnd(in: Array(bytes.prefix(3))) == nil)
        #expect(try GitPktLine.advertisementEnd(in: Array(bytes.dropLast())) == nil)
        #expect(try GitPktLine.advertisementEnd(in: bytes) == bytes.count)
        bytes += Array("PACK".utf8)
        #expect(try GitPktLine.advertisementEnd(in: bytes) == bytes.count - 4)
        #expect(throws: GitFormatError.invalidPktLine) { _ = try GitPktLine.advertisementEnd(in: Array("-00a".utf8)) }
        #expect(throws: GitFormatError.invalidPktLine) { _ = try GitPktLine.advertisementEnd(in: Array("0002".utf8)) }
    }

    @Test func sshFailuresBecomeClosedCodes() {
        func code(_ text: String, _ status: Int32 = 255) -> GitRemoteFailure {
            GitSSHDiagnosis.failure(stderr: Array(text.utf8), exitStatus: status)
        }
        #expect(code("Host key verification failed.") == .sshHostKeyUnknown)
        #expect(code("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.") == .sshHostKeyChanged)
        #expect(code("git@github.com: Permission denied (publickey).") == .sshPermissionDenied)
        #expect(code("ERROR: Permission to me/lib.git denied to deploy key", 128) == .sshPermissionDenied)
        #expect(code("ERROR: Repository not found.", 128) == .repositoryNotFound)
        #expect(code("fatal: '/x' does not appear to be a git repository", 128) == .repositoryNotFound)
        #expect(code("ssh: Could not resolve hostname nope: nodename nor servname provided") == .unreachable("ssh_connection"))
        #expect(code("Unable to negotiate with 1.2.3.4 port 22: no matching host key type found") == .unsupportedServer("ssh_algorithms"))
        #expect(code("sh: git-upload-pack: command not found", 127) == .unsupportedServer("ssh_no_git"))
        #expect(code("something else") == .unreachable("ssh_failed"))
        // A login script's noise on an ssh-level failure is not the remote git speaking.
        #expect(code("bash: brew: command not found\nclient_loop: send disconnect: Broken pipe") == .unreachable("ssh_connection"))
        #expect(code(".profile: line 3: /opt/x: No such file or directory\nConnection to h closed by remote host.") == .unreachable("ssh_connection"))
        #expect(code("bash: brew: command not found", 255) == .unreachable("ssh_failed"))
        #expect(code("The repository is temporarily read-only. Please try again later.", 1) == .unreachable("ssh_remote_temporary"))
        #expect(code("ERROR: The key you are authenticating with has been marked as read only.", 1) == .sshPermissionDenied)
    }
}

@Suite(.serialized) struct GitSSHTransportTests {
    private func record(rev: String, body: String) -> WireRecord {
        WireRecord(id: UUID(), rev: rev, deleted: false, blob: Data(body.utf8), recordVersion: nil)
    }

    /// The same repository reached over SSH and HTTPS is one library: the same records,
    /// versions and compare-and-swap, whichever way each device connects.
    @Test func sshAndHTTPSDevicesShareOneLibrary() async throws {
        let fixture = try GitFixture()
        let overSSH = try fixture.sshTransport("ssh")
        let datasetID = try await overSSH.initializeRepository()
        let overHTTPS = try fixture.transport("https")
        #expect(try await overHTTPS.inspectRepository() == .library(datasetID: datasetID))

        let first = record(rev: "r1", body: "from ssh")
        let submitted = try await overSSH.submit([first], at: nil)
        guard case .accepted(_, let version) = submitted.results.first?.outcome else {
            Issue.record("ssh submit: \(submitted.results)")
            return
        }
        let fetched = try await overHTTPS.fetchChanges(since: nil)
        #expect(fetched.records.map(\.id) == [first.id])
        #expect(fetched.records.first?.recordVersion == version)

        var edit = record(rev: "r2", body: "from https")
        edit.id = first.id
        edit.recordVersion = version
        _ = try await overHTTPS.submit([edit], at: fetched.cursor)
        // The SSH device's stale generation is now a conflict, exactly as over HTTPS.
        var stale = record(rev: "r2b", body: "late ssh edit")
        stale.id = first.id
        stale.recordVersion = version
        let conflicted = try await overSSH.submit([stale], at: nil)
        guard case .rejected(.conflict) = conflicted.results.first?.outcome else {
            Issue.record("expected conflict: \(conflicted.results)")
            return
        }
        #expect(try await overSSH.fetchChanges(since: nil).records.first?.rev == "r2")
        #expect(fixture.sshInvocations.allSatisfy { $0.contains("BatchMode=yes") && $0.contains("-- git@ssh.fixture.invalid") })
        #expect(fixture.sshInvocations.contains { $0.hasSuffix("git-receive-pack 'repo.git'") })
    }

    @Test func aStalePushIsRefusedWithoutUploadingThePack() async throws {
        let fixture = try GitFixture()
        let a = try fixture.sshTransport("a")
        _ = try await a.initializeRepository()
        _ = try await a.preflightScope()
        // Another writer moves the branch between this device's discovery and push.
        let b = try fixture.transport("b")
        _ = try await b.submit([record(rev: "r", body: "b")], at: nil)
        let submission = try await a.submit([record(rev: "r", body: "a")], at: nil)
        guard case .accepted = submission.results.first?.outcome else {
            Issue.record("the retry after a lost race must land: \(submission.results)")
            return
        }
        #expect(try await b.fetchChanges(since: nil).records.count == 2)
    }

    @Test func sshFailuresSurfaceAsActionableCodes() async throws {
        let fixture = try GitFixture()
        let transport = try fixture.sshTransport()
        let cases: [(Int32, String, SyncTransportFailure)] = [
            (255, "Host key verification failed.", .rejected(.authenticationRequired(detail: "git_ssh_host_key_unknown"))),
            (255, "git@x: Permission denied (publickey).", .rejected(.authenticationRequired(detail: "git_ssh_permission_denied"))),
            (128, "ERROR: Repository not found.", .rejected(.authenticationRequired(detail: "git_repository_not_found"))),
            (255, "ssh: connect to host x port 22: Connection refused", .unreachable(detail: "git_ssh_connection")),
        ]
        for (status, text, expected) in cases {
            try fixture.failSSH(status: status, stderr: text)
            await #expect(throws: expected) { _ = try await transport.inspectRepository() }
        }
        fixture.clearSSHFailure()
        #expect(try await transport.inspectRepository() == .empty)
    }

    /// A user's `ControlPersist` master can keep ssh's stderr open after ssh exits; the
    /// exchange must not wait for it.
    @Test func aLingeringSSHMasterDoesNotStallTheExchange() async throws {
        let fixture = try GitFixture()
        let transport = try fixture.sshTransport()
        try Data().write(to: fixture.root.appending(path: "ssh-linger"))
        let started = Date()
        #expect(try await transport.inspectRepository() == .empty)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// The service ends right after its advertisement (a dropped link, `StdinNull` in a
    /// user's config): the request writer must not race the reader closing ssh's input.
    @Test func aServiceThatEndsEarlyNeverCrashesTheWriter() async throws {
        let fixture = try GitFixture()
        let script = fixture.root.appending(path: "bin/early-ssh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf '0000'\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var connector = GitSystemSSHConnector()
        connector.executable = script
        let location = try GitSSHLocation(user: "git", host: "h", port: nil, path: "r.git", scpStyle: true)
        let pack = Data(count: 4 * 1024 * 1024)
        for _ in 0..<40 {
            let exchange = try? await connector.exchange(
                command: "git-receive-pack 'r.git'", location: location, maximumBytes: 1 << 20
            ) { _ in pack }
            #expect(exchange?.advertisement == Array("0000".utf8))
        }
    }

    @Test func cancellationIsReportedAsCancellation() async throws {
        let fixture = try GitFixture()
        let script = fixture.root.appending(path: "bin/slow-ssh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var connector = GitSystemSSHConnector()
        connector.executable = script
        let location = try GitSSHLocation(user: "git", host: "h", port: nil, path: "r.git", scpStyle: true)
        let task = Task {
            try await connector.exchange(command: "git-upload-pack 'r.git'", location: location, maximumBytes: 1024) { _ in nil }
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aStalledExchangeTimesOutButAMovingOneDoesNot() async throws {
        let fixture = try GitFixture()
        let script = fixture.root.appending(path: "bin/stall-ssh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var connector = GitSystemSSHConnector(timeout: 2)
        connector.executable = script
        let location = try GitSSHLocation(user: "git", host: "h", port: nil, path: "r.git", scpStyle: true)
        await #expect(throws: GitRemoteFailure.unreachable("ssh_timeout")) {
            _ = try await connector.exchange(command: "git-upload-pack 'r.git'", location: location, maximumBytes: 1024) { _ in nil }
        }
    }

    @Test func aMissingSSHExecutableIsReportedNotCrashed() async throws {
        let fixture = try GitFixture()
        var connector = GitSystemSSHConnector()
        connector.executable = fixture.root.appending(path: "no-such-ssh")
        let transport = GitSyncTransport(configuration: .init(
            remote: try fixture.sshRemote(), cacheDirectory: fixture.cacheDirectory("x"), sshConnector: connector))
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_unsupported_ssh_unavailable"))) {
            _ = try await transport.inspectRepository()
        }
    }
}

/// Through the real OpenSSH client and server, authenticated only by a key held in an
/// ssh-agent, as a Mac user's setup is.
@Suite(.serialized, .enabled(if: GitSSHServer.isAvailable))
struct GitRealSSHTests {
    private func transport(_ server: GitSSHServer, _ fixture: GitFixture, _ name: String) throws -> GitSyncTransport {
        GitSyncTransport(configuration: .init(
            remote: try GitRemote(ssh: try server.location(of: fixture.bare), branch: "main"),
            cacheDirectory: fixture.cacheDirectory(name), sshConnector: server.connector))
    }

    @Test func agentAuthenticatedSSHSyncsWithHTTPS() async throws {
        let fixture = try GitFixture()
        let server = try GitSSHServer(in: fixture.root)
        let ssh = try transport(server, fixture, "ssh")
        let datasetID = try await ssh.initializeRepository()
        let records = (0..<3).map { WireRecord(id: UUID(), rev: "r", deleted: false, blob: Data("s\($0)".utf8), recordVersion: nil) }
        _ = try await ssh.submit(records, at: nil)
        let https = try fixture.transport("https")
        #expect(try await https.inspectRepository() == .library(datasetID: datasetID))
        #expect(Set(try await https.fetchChanges(since: nil).records.map(\.id)) == Set(records.map(\.id)))
        try await ssh.verifyWriteAccess()
    }

    /// Polls reuse one authenticated connection instead of a handshake per request.
    @Test func connectionsAreSharedBetweenExchanges() async throws {
        let fixture = try GitFixture()
        let server = try GitSSHServer(in: fixture.root)
        var connector = server.connector
        connector.sharesConnections = true
        let location = try server.location(of: fixture.bare)
        let directory = try #require(GitSystemSSHConnector.controlDirectory())
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        let transport = GitSyncTransport(configuration: .init(
            remote: try GitRemote(ssh: location, branch: "main"),
            cacheDirectory: fixture.cacheDirectory("shared"), sshConnector: connector))
        #expect(try await transport.inspectRepository() == .empty)
        let sockets = Set(try FileManager.default.contentsOfDirectory(atPath: directory)).subtracting(before)
        #expect(sockets.count == 1, "one shared connection for this host")
        _ = try await transport.initializeRepository()
        _ = try await transport.preflightScope()
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory)).subtracting(before) == sockets)
        // Stop the shared connection now rather than after its idle period.
        for socket in sockets {
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            stop.arguments = ["-o", "ControlPath=\(directory)/\(socket)", "-O", "exit", "x"]
            stop.standardOutput = FileHandle.nullDevice
            stop.standardError = FileHandle.nullDevice
            try stop.run()
            stop.waitUntilExit()
        }
    }

    @Test func hostKeyAndAgentProblemsAreDistinguished() async throws {
        let fixture = try GitFixture()
        let server = try GitSSHServer(in: fixture.root)
        let ssh = try transport(server, fixture, "ssh")
        #expect(try await ssh.inspectRepository() == .empty)

        try server.distrustHostKey()
        await #expect(throws: SyncTransportFailure.rejected(.authenticationRequired(detail: "git_ssh_host_key_changed"))) {
            _ = try await ssh.inspectRepository()
        }
        try server.forgetHostKey()
        await #expect(throws: SyncTransportFailure.rejected(.authenticationRequired(detail: "git_ssh_host_key_unknown"))) {
            _ = try await ssh.inspectRepository()
        }
    }

    @Test func anEmptyAgentIsPermissionDenied() async throws {
        let fixture = try GitFixture()
        let server = try GitSSHServer(in: fixture.root)
        try server.removeAgentKeys()
        await #expect(throws: SyncTransportFailure.rejected(.authenticationRequired(detail: "git_ssh_permission_denied"))) {
            _ = try await self.transport(server, fixture, "ssh").inspectRepository()
        }
    }
}
