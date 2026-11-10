import Foundation
import Testing
@testable import SnippetsCore

@Suite("Git primitives")
struct GitPrimitivesTests {
    @Test func objectIDsMatchGit() throws {
        #expect(GitObjectID.hash(type: .blob, content: Array("hello\n".utf8)).hex
                == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(GitObjectID.hash(type: .tree, content: []).hex
                == "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
        let id = try #require(GitObjectID(hex: "ce013625030ba8dba906f756967f9e9ca394464a"))
        #expect(id.hex == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(GitObjectID(hex: "CE013625030BA8DBA906F756967F9E9CA394464A") == nil)
        #expect(GitObjectID(hex: "ce01") == nil)
        #expect(GitObjectID.zero.isZero)
    }

    @Test func treeSerializationUsesGitOrderAndMatchesGitMktree() throws {
        let fixture = try GitFixture()
        let blob = GitObjectID.hash(type: .blob, content: Array("x".utf8))
        let subtree = GitObjectID.hash(type: .tree, content: [])
        let entries: [GitTreeEntry] = [
            .tree("a", subtree), .blob("a.b", blob), .blob("a-b", blob), .blob("B", blob),
        ]
        let content = GitTree.serialize(entries)
        let names = try GitTree.parse(content).map { String(decoding: $0.name, as: UTF8.self) }
        // "a" sorts as "a/", after "a.b" and "a-b".
        #expect(names == ["B", "a-b", "a.b", "a"])

        let listing = """
            040000 tree \(subtree.hex)\ta
            100644 blob \(blob.hex)\ta.b
            100644 blob \(blob.hex)\ta-b
            100644 blob \(blob.hex)\tB
            """
        let gitID = try fixture.git(
            ["--git-dir", fixture.bare.path, "mktree", "--missing"], input: Data((listing + "\n").utf8))
        #expect(GitObjectID.hash(type: .tree, content: content).hex == gitID)
    }

    @Test func commitParsingReadsTreeAndParents() throws {
        let tree = GitObjectID.hash(type: .tree, content: [])
        let parent = GitObjectID.hash(type: .blob, content: Array("p".utf8))
        let data = GitCommit.serialize(
            tree: tree, parents: [parent], date: Date(timeIntervalSince1970: 1_700_000_000),
            message: "Sync 1 record")
        let commit = try GitCommit.parse(data)
        #expect(commit.tree == tree)
        #expect(commit.parents == [parent])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("author Snippets Sync <sync@snippets.invalid> 1700000000 +0000"))
    }

    @Test func packRoundTripsUndeltifiedObjects() throws {
        let objects = [
            GitObject(type: .blob, content: Data()),
            GitObject(type: .blob, content: Data(repeating: 7, count: 70_000)),
            GitObject(type: .tree, content: GitTree.serialize([
                .blob("x", GitObjectID.hash(type: .blob, content: [])),
            ])),
        ]
        let parsed = try GitPack.parse(try GitPack.build(objects))
        #expect(parsed.count == 3)
        for object in objects { #expect(parsed[object.id] == object) }
    }

    @Test func packRejectsCorruption() throws {
        var pack = try GitPack.build([GitObject(type: .blob, content: Data("abc".utf8))])
        pack[pack.count - 25] ^= 0xff
        #expect(throws: GitFormatError.self) { _ = try GitPack.parse(pack) }
        #expect(throws: GitFormatError.self) { _ = try GitPack.parse(Data("PACK".utf8)) }
    }

    /// Real packs are deltified. Git's own `pack-objects` emits offset deltas with
    /// `--delta-base-offset` and reference deltas without it.
    @Test func parsesDeltifiedPacksProducedByGit() throws {
        let fixture = try GitFixture()
        let work = fixture.root.appending(path: "work", directoryHint: .isDirectory)
        try fixture.git(["init", "--quiet", work.path])
        var text = (0..<4_000).map { "line \($0) of a long, repetitive file\n" }.joined()
        for revision in 0..<12 {
            text = text.replacingOccurrences(of: "line \(revision * 100) ", with: "edited \(revision) ")
            try text.write(to: work.appending(path: "file.txt"), atomically: true, encoding: .utf8)
            try fixture.git(["-C", work.path, "add", "-A"])
            try fixture.git(["-C", work.path, "commit", "--quiet", "-m", "r\(revision)"])
        }
        // Offset deltas, then reference deltas (pack-objects without --delta-base-offset).
        for useOffsets in [true, false] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", work.path, "pack-objects", "--stdout", "--window=50", "--depth=50",
                                 "--no-reuse-delta"] + (useOffsets ? ["--delta-base-offset"] : [])
            process.environment = GitFixture.isolatedEnvironment(home: fixture.root)
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let ids = try fixture.git(["-C", work.path, "rev-list", "--objects", "--all"])
                .split(separator: "\n").map { $0.prefix(40) }.joined(separator: "\n") + "\n"
            input.fileHandleForWriting.write(Data(ids.utf8))
            try input.fileHandleForWriting.close()
            let pack = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            let objects = try GitPack.parse(pack)
            let expected = Set(ids.split(separator: "\n").map(String.init))
            #expect(Set(objects.keys.map(\.hex)) == expected)
            let head = try fixture.git(["-C", work.path, "rev-parse", "HEAD:file.txt"])
            let headID = try #require(GitObjectID(hex: head))
            let blob = try #require(objects[headID])
            #expect(String(decoding: blob.content, as: UTF8.self) == text)
            // A delta-compressed pack is far smaller than twelve copies of the file.
            #expect(pack.count < text.utf8.count * 3)
        }
    }

    @Test func deltaApplicationValidatesEveryBound() throws {
        let base = Array("hello world".utf8)
        // source 11, target 5, copy offset 6 size 5
        let delta: [UInt8] = [11, 5, 0x91, 6, 5]
        #expect(try GitDelta.apply(delta, to: base, maximumSize: 100) == Array("world".utf8))
        #expect(throws: GitFormatError.invalidDelta) {
            _ = try GitDelta.apply([12, 5, 0x91, 6, 5], to: base, maximumSize: 100)
        }
        #expect(throws: GitFormatError.invalidDelta) {
            _ = try GitDelta.apply([11, 5, 0x91, 8, 5], to: base, maximumSize: 100)
        }
        #expect(throws: GitFormatError.invalidDelta) {
            _ = try GitDelta.apply([11, 1, 0], to: base, maximumSize: 100)
        }
        #expect(throws: GitFormatError.limitExceeded("delta_target")) {
            _ = try GitDelta.apply([11, 50, 1, 65], to: base, maximumSize: 10)
        }
    }

    @Test func zlibInflateReportsExactConsumption() throws {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        var stream = try GitZlib.deflate(payload)
        let compressedLength = stream.count
        stream.append(contentsOf: [1, 2, 3, 4])
        let (content, consumed) = try stream.withUnsafeBytes { raw in
            try GitZlib.inflate(raw.bindMemory(to: UInt8.self), from: 0, expectedSize: payload.count)
        }
        #expect(Data(content) == payload)
        #expect(consumed == compressedLength)
        #expect(throws: GitFormatError.compression) {
            _ = try stream.withUnsafeBytes { raw in
                try GitZlib.inflate(raw.bindMemory(to: UInt8.self), from: 0, expectedSize: payload.count - 1)
            }
        }
    }

    @Test func pktLineFramingRoundTrips() throws {
        var data = try GitPktLine.line("hello")
        data.append(GitPktLine.flush)
        data.append(Data("0001".utf8))
        var reader = GitPktLine.Reader([UInt8](data))
        #expect(try reader.next() == .data(Array("hello\n".utf8)))
        #expect(try reader.next() == .flush)
        #expect(try reader.next() == .delimiter)
        #expect(try reader.next() == nil)
        var bad = GitPktLine.Reader(Array("zz12".utf8))
        #expect(throws: GitFormatError.invalidPktLine) { _ = try bad.next() }
        // `Int(_:radix:)` accepts a sign; a hostile "-005" length must not trap.
        for hostile in ["-005", "+005", " 005", "-0001234"] {
            var reader = GitPktLine.Reader(Array(hostile.utf8))
            #expect(throws: GitFormatError.invalidPktLine) { _ = try reader.next() }
        }
        #expect(throws: GitFormatError.invalidPktLine) {
            _ = try GitPktLine.encode([UInt8](repeating: 0, count: GitPktLine.maximumPayload + 1))
        }
    }

    @Test func advertisementParsingHandlesEmptyAndPopulatedRepositories() throws {
        let zero = String(repeating: "0", count: 40)
        var empty = try GitPktLine.line("# service=git-receive-pack")
        empty.append(GitPktLine.flush)
        var line = Array("\(zero) capabilities^{}".utf8)
        line.append(0)
        line.append(contentsOf: Array("report-status side-band-64k object-format=sha1 agent=git/2\n".utf8))
        empty.append(try GitPktLine.encode(line))
        empty.append(GitPktLine.flush)
        let parsedEmpty = try GitSmartHTTPClient.parseAdvertisement(empty, service: .receivePack)
        #expect(parsedEmpty.refs.isEmpty)
        #expect(parsedEmpty.supports("report-status"))
        #expect(parsedEmpty.capabilities["agent"] == .some("git/2"))

        let id = "ce013625030ba8dba906f756967f9e9ca394464a"
        var populated = try GitPktLine.line("# service=git-upload-pack")
        populated.append(GitPktLine.flush)
        var first = Array("\(id) HEAD".utf8)
        first.append(0)
        first.append(contentsOf: Array("shallow side-band-64k symref=HEAD:refs/heads/main\n".utf8))
        populated.append(try GitPktLine.encode(first))
        populated.append(try GitPktLine.line("\(id) refs/heads/main"))
        populated.append(try GitPktLine.line("\(id) refs/tags/v1^{}"))
        populated.append(GitPktLine.flush)
        let parsed = try GitSmartHTTPClient.parseAdvertisement(populated, service: .uploadPack)
        #expect(parsed.refs["refs/heads/main"]?.hex == id)
        #expect(parsed.refs["refs/tags/v1^{}"] == nil)
        #expect(throws: GitRemoteFailure.self) {
            _ = try GitSmartHTTPClient.parseAdvertisement(populated, service: .receivePack)
        }

        var sha256 = try GitPktLine.line("# service=git-upload-pack")
        sha256.append(GitPktLine.flush)
        var shaLine = Array("\(zero) capabilities^{}".utf8)
        shaLine.append(0)
        shaLine.append(contentsOf: Array("object-format=sha256\n".utf8))
        sha256.append(try GitPktLine.encode(shaLine))
        sha256.append(GitPktLine.flush)
        #expect(throws: GitRemoteFailure.unsupportedServer("object_format")) {
            _ = try GitSmartHTTPClient.parseAdvertisement(sha256, service: .uploadPack)
        }
    }

    @Test func zeroPaddedTreeModeIsStillATree() throws {
        let entry = GitTreeEntry(mode: Array("040000".utf8), name: Array("records".utf8),
                                 id: GitObjectID.hash(type: .tree, content: []))
        #expect(entry.isTree)
        #expect(!GitTreeEntry.blob("x", GitObjectID.zero).isTree)
    }

    @Test func remoteNeverPrintsItsToken() throws {
        let remote = try GitRemote(
            url: try #require(URL(string: "https://github.com/me/library")), branch: "main",
            username: "me", password: "secret-token-value")
        var dumped = ""
        dump(remote, to: &dumped)
        for text in [String(describing: remote), String(reflecting: remote), dumped, "\(remote)"] {
            #expect(!text.contains("secret-token-value"), "\(text)")
        }
    }

    @Test func remoteValidationRejectsUnsafeConfiguration() throws {
        let https = try #require(URL(string: "https://GitHub.com/me/library/"))
        let remote = try GitRemote(url: https, branch: "main", username: "me", password: "token")
        #expect(remote.url.absoluteString == "https://github.com/me/library")
        let dotGit = try GitRemote(
            url: try #require(URL(string: "https://github.com/me/library.git")),
            branch: "main", username: "x", password: "y")
        #expect(dotGit.canonicalLocation == remote.canonicalLocation)

        for raw in ["http://github.com/me/r", "https://me:pw@github.com/me/r",
                    "https://github.com/me/r?x=1", "https://github.com", "ssh://git@github.com/me/r"] {
            #expect(throws: GitRemote.Failure.invalidURL) {
                _ = try GitRemote(url: URL(string: raw)!, branch: "main", username: "u", password: "p")
            }
        }
        for branch in ["", "-x", "a..b", "a/", ".hidden", "a/.b", "x.lock", "has space", "HEAD"] {
            #expect(!GitRemote.isValidBranch(branch), "\(branch)")
        }
        #expect(GitRemote.isValidBranch("snippets/sync-v1"))
        #expect(throws: GitRemote.Failure.invalidCredential) {
            _ = try GitRemote(url: https, branch: "main", username: "a:b", password: "p")
        }
        #expect(throws: GitRemote.Failure.invalidCredential) {
            _ = try GitRemote(url: https, branch: "main", username: "u", password: "line\nbreak")
        }
        #expect(throws: GitRemote.Failure.invalidURL) {
            _ = try GitRemote(url: URL(string: "http://example.com/r")!, branch: "main",
                              username: "u", password: "p", allowsInsecureLoopback: true)
        }
    }
}
