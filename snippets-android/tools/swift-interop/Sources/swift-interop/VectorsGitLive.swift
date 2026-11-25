import CryptoKit
import Foundation
@testable import SnippetsCore

// G4: the objects of real repositories, written by the unmodified GitSyncTransport
// through `git http-backend` (the harness of Tests/Core/GitTestServer.swift, compiled
// as it stands), then read back with the git CLI.

final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ unixSeconds: TimeInterval) { value = Date(timeIntervalSince1970: unixSeconds) }
    var now: Date { lock.withLock { value } }
    func set(_ unixSeconds: TimeInterval) { lock.withLock { value = Date(timeIntervalSince1970: unixSeconds) } }
}

enum GitLiveVectors {

    /// One bare repository behind a fixed loopback host name, so the identities that
    /// hash the location are the same on every run.
    final class Repository {
        let fixture: GitFixture
        let host: String
        let clock = FixedClock(1_785_312_000)
        let token = "fixture-token-not-a-secret"

        init(host: String) throws {
            fixture = try GitFixture()
            self.host = host
            GitHTTPBackendProtocol.register(host: host, .init(
                projectRoot: fixture.root, username: "tester", password: token))
        }

        deinit { GitHTTPBackendProtocol.unregister(host: host) }

        func remote() throws -> GitRemote {
            try GitRemote(
                url: URL(string: "http://\(host)/repo.git")!, branch: "main", username: "tester",
                password: token, allowsInsecureLoopback: true)
        }

        func transport(_ name: String, plainText: GitPlainCodec? = nil) throws -> GitSyncTransport {
            let clock = clock
            return GitSyncTransport(
                configuration: .init(
                    remote: try remote(), cacheDirectory: fixture.cacheDirectory(name), plainText: plainText),
                session: fixture.session, now: { clock.now })
        }

        func git(_ arguments: [String]) throws -> String {
            try fixture.git(["--git-dir", fixture.bare.path] + arguments)
        }

        /// Raw object bytes. `git cat-file` output goes through a file because the
        /// harness helper returns trimmed text.
        func object(_ type: String, _ id: String) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["--git-dir", fixture.bare.path, "cat-file", type, id]
            process.environment = GitFixture.isolatedEnvironment(home: fixture.root)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw InteropFailure("git cat-file \(type) \(id) failed") }
            return data
        }

        /// Every commit on the branch, oldest first, with its trees and blobs.
        func describe() throws -> (commits: [J], blobs: [J]) {
            var commits: [J] = []
            var blobs: [String: (paths: Set<String>, data: Data)] = [:]
            let ids = try git(["rev-list", "--reverse", "main"]).split(separator: "\n").map(String.init)
            for id in ids {
                let raw = try object("commit", id)
                guard let commitID = GitObjectID(hex: id) else { throw InteropFailure("commit id") }
                try require(GitObjectID.hash(type: .commit, content: raw) == commitID, "G4 commit \(id) hashes to its id")
                let parsed = try GitCommit.parse(raw)
                let text = String(decoding: raw, as: UTF8.self)
                let lines = text.components(separatedBy: "\n")
                guard let blank = lines.firstIndex(of: "") else { throw InteropFailure("commit shape") }
                let message = lines[(blank + 1)...].joined(separator: "\n")
                let author = lines.first { $0.hasPrefix("author ") } ?? ""
                let committer = lines.first { $0.hasPrefix("committer ") } ?? ""
                // The same bytes from the Swift serializer.
                let seconds = TimeInterval(author.split(separator: " ").dropLast().last.flatMap { Int($0) } ?? -1)
                let rebuilt = GitCommit.serialize(
                    tree: parsed.tree, parents: parsed.parents, date: Date(timeIntervalSince1970: seconds),
                    message: String(message.dropLast()))
                try require(rebuilt == raw, "G4 commit \(id) equals GitCommit.serialize")

                var entries: [J] = []
                var trees: [J] = []
                func walk(_ tree: GitObjectID, path: String) throws {
                    let treeBytes = try object("tree", tree.hex)
                    let parsedEntries = try GitTree.parse(treeBytes)
                    try require(GitTree.serialize(parsedEntries) == treeBytes, "G4 tree \(tree.hex) equals GitTree.serialize")
                    try require(GitObjectID.hash(type: .tree, content: treeBytes) == tree, "G4 tree \(tree.hex) hashes to its id")
                    trees.append(.obj([
                        ("path", .str(path)),
                        ("id", .str(tree.hex)),
                        ("entries", .arr(parsedEntries.map { entry in
                            .obj([
                                ("mode", .str(String(decoding: entry.mode, as: UTF8.self))),
                                ("name", .str(entry.nameString ?? "")),
                                ("id", .str(entry.id.hex)),
                            ])
                        })),
                        ("hex", .hex(treeBytes)),
                    ]))
                    for entry in parsedEntries {
                        let name = entry.nameString ?? ""
                        let full = path.isEmpty ? name : "\(path)/\(name)"
                        entries.append(.obj([
                            ("mode", .str(String(decoding: entry.mode, as: UTF8.self))),
                            ("type", .str(entry.isTree ? "tree" : "blob")),
                            ("id", .str(entry.id.hex)),
                            ("path", .str(full)),
                        ]))
                        if entry.isTree {
                            try walk(entry.id, path: full)
                        } else {
                            let data = try object("blob", entry.id.hex)
                            try require(GitObjectID.hash(type: .blob, content: data) == entry.id, "G4 blob hashes to its id")
                            blobs[entry.id.hex, default: ([], data)].paths.insert(full)
                        }
                    }
                }
                try walk(parsed.tree, path: "")
                commits.append(.obj([
                    ("id", .str(id)),
                    ("tree", .str(parsed.tree.hex)),
                    ("parents", .strings(parsed.parents.map(\.hex))),
                    ("author", .str(author)),
                    ("committer", .str(committer)),
                    ("message", .str(String(message.dropLast()))),
                    ("rawText", .str(text)),
                    ("rawHex", .hex(raw)),
                    ("entries", .arr(entries)),
                    ("trees", .arr(trees)),
                ]))
            }
            let described = blobs.keys.sorted().map { id -> J in
                let blob = blobs[id]!
                let isReadme = blob.paths.contains("README.md")
                return .obj([
                    ("id", .str(id)),
                    ("paths", .strings(blob.paths.sorted())),
                    ("byteCount", .n(blob.data.count)),
                    // README bytes are in G02; here only the id.
                    ("text", isReadme ? .null : utf8Text(blob.data)),
                    ("base64", isReadme ? .null : .str(blob.data.base64EncodedString())),
                ])
            }
            let fsck = try git(["fsck", "--strict", "--no-dangling", "--no-progress"])
            try require(fsck.isEmpty, "G4 git fsck --strict is clean, got: \(fsck)")
            return (commits, described)
        }
    }

    static func accepted(_ submission: SyncSubmission) throws -> [UUID: SyncRecordVersion] {
        var versions: [UUID: SyncRecordVersion] = [:]
        for result in submission.results {
            guard case .accepted(_, let version) = result.outcome else {
                throw InteropFailure("G4 record \(lower(result.id)) was not accepted: \(result.outcome)")
            }
            versions[result.id] = version
        }
        return versions
    }

    static func resultsJ(_ submission: SyncSubmission) -> J {
        .arr(submission.results.map { result in
            var members: [(String, J)] = [("id", .str(lower(result.id)))]
            if case .accepted(let rev, let version) = result.outcome {
                members += [
                    ("outcome", .str("accepted")), ("rev", .str(rev)),
                    ("recordVersionText", utf8Text(version.data)),
                ]
            } else {
                members.append(("outcome", .str("rejected")))
            }
            return .obj(members)
        })
    }

    static func sealed(_ envelope: SyncEnvelope, nonce: UInt8, version: SyncRecordVersion? = nil) throws -> WireRecord {
        var record = try WireCodec.seal(envelope, using: SnippetCryptoSealer(
            keyring: Fixture.syncKeyring, scopeID: Fixture.syncScope, nonces: fixedNonce(nonce)))
        record.recordVersion = version
        return record
    }

    static func g4() async throws -> VectorFile {
        var cases: [J] = []
        let envelopes = try CryptoVectorsB.envelopes()
        func envelope(_ name: String) throws -> SyncEnvelope {
            guard let found = envelopes.first(where: { $0.0 == name }) else { throw InteropFailure("no envelope \(name)") }
            return found.1
        }
        let material = Fixture.syncMaterial
        let recovery = try CryptoVectorsC.assembleRecovery(
            material: material, datasetID: Fixture.datasetID, secret: Fixture.recoverySecret,
            nonce: Data.counting(from: 0x30, 12)).file
        let wrap = try KeyWrap.wrap(
            SymmetricKey(data: Fixture.libraryKey), under: Fixture.recoverySecret, purpose: .recovery,
            kid: Fixture.kid, salt: Fixture.vaultSalt, nonces: fixedNonce(0x77))
        let identity = GitSyncVault.Identity(
            kid: Fixture.kid, vaultSalt: SnippetCrypto.base64URL(Fixture.vaultSalt),
            kdf: .init(alg: PassphraseKDF.algorithm, iterations: PassphraseKDF.iterations,
                       saltP: SnippetCrypto.base64URL(Data.filled(0x55, 16))),
            wrapRecovery: wrap)
        let vault = try GitSyncVault.seal(
            identity, material: material, datasetID: Fixture.datasetID,
            nonce: try AES.GCM.Nonce(data: Data.counting(from: 0x20, 12)))
        try require(try GitSyncVault.open(vault, material: material, datasetID: Fixture.datasetID) == identity, "G4 vault file opens")

        // MARK: Encrypted library

        do {
            let repository = try Repository(host: "snippets-interop.localhost")
            let device = try repository.transport("encrypted")
            let before = try await device.inspectRepository()
            try require(before == .empty, "G4 repository starts empty")
            var steps: [J] = []

            let datasetID = try await device.initializeRepository(
                datasetID: Fixture.datasetID,
                files: [GitSyncRecovery.path: recovery, GitSyncVault.path: vault], mode: .encrypted)
            try require(datasetID == Fixture.datasetID, "G4 dataset id")
            steps.append(.obj([
                ("call", .str("initializeRepository(datasetID:files:mode: .encrypted)")),
                ("clockUnixSeconds", .n(1_785_312_000)),
                ("files", .strings([GitSyncRecovery.path, GitSyncVault.path])),
            ]))
            let scope = try await device.preflightScope()
            let fetched = try await device.fetchChanges(since: nil)

            repository.clock.set(1_785_312_060.9)
            let first = try await device.submit([
                try sealed(try envelope("plain"), nonce: 0xb0),
                try sealed(try envelope("plain-unicode-and-escapes"), nonce: 0xb1),
                try sealed(try envelope("plain-empty-fields"), nonce: 0xb2),
                try sealed(try envelope("secure"), nonce: 0xb3),
            ], at: fetched.cursor)
            let versions = try accepted(first)
            steps.append(.obj([
                ("call", .str("submit(4 new records)")),
                ("clockUnixSeconds", .str("1785312060.9")),
                ("atCursor", .opt(fetched.cursor?.rawValue)),
                ("results", resultsJ(first)),
                ("cursor", .opt(first.cursor?.rawValue)),
            ]))

            repository.clock.set(1_785_312_120)
            let second = try await device.submit([
                try sealed(try envelope("tombstone-plain"), nonce: 0xb4, version: versions[Fixture.uuidA]),
            ], at: first.cursor)
            _ = try accepted(second)
            steps.append(.obj([
                ("call", .str("submit(1 tombstone replacing a live record)")),
                ("clockUnixSeconds", .n(1_785_312_120)),
                ("results", resultsJ(second)),
                ("cursor", .opt(second.cursor?.rawValue)),
            ]))

            // The identical bytes again: accepted, no commit.
            repository.clock.set(1_785_312_150)
            let headBefore = try repository.git(["rev-parse", "main"])
            let again = try await device.submit([
                try sealed(try envelope("tombstone-plain"), nonce: 0xb4,
                           version: try accepted(second)[Fixture.uuidA]),
            ], at: second.cursor)
            _ = try accepted(again)
            try require(try repository.git(["rev-parse", "main"]) == headBefore, "G4 identical re-upload makes no commit")
            steps.append(.obj([
                ("call", .str("submit(the identical tombstone again)")),
                ("results", resultsJ(again)),
                ("madeACommit", .bool(false)),
            ]))

            repository.clock.set(1_785_312_180)
            let newRecovery = try CryptoVectorsC.assembleRecovery(
                material: material, datasetID: Fixture.datasetID, secret: Data.filled(0x66, 16),
                nonce: Data.counting(from: 0x40, 12)).file
            let newWrap = try KeyWrap.wrap(
                SymmetricKey(data: Fixture.libraryKey), under: Data.filled(0x66, 16), purpose: .recovery,
                kid: Fixture.kid, salt: Fixture.vaultSalt, nonces: fixedNonce(0x78))
            let newVault = try GitSyncVault.seal(
                GitSyncVault.Identity(
                    kid: identity.kid, vaultSalt: identity.vaultSalt, kdf: identity.kdf, wrapRecovery: newWrap),
                material: material, datasetID: Fixture.datasetID,
                nonce: try AES.GCM.Nonce(data: Data.counting(from: 0x50, 12)))
            try await device.writeFiles(
                [GitSyncRecovery.path: newRecovery, GitSyncVault.path: newVault],
                message: "Replace recovery envelope")
            steps.append(.obj([
                ("call", .str("writeFiles([keys/recovery.json, keys/vault.json], message: \"Replace recovery envelope\")")),
                ("clockUnixSeconds", .n(1_785_312_180)),
            ]))

            repository.clock.set(1_785_312_240)
            let replacement = Fixture.uuidA
            let replacedMaterial = Data.counting(from: 0, 64)
            let replacedRecovery = try CryptoVectorsC.assembleRecovery(
                material: replacedMaterial, datasetID: replacement, secret: Data.filled(0x66, 16),
                nonce: Data.counting(from: 0x60, 12)).file
            try await device.replaceLibrary(
                Fixture.datasetID, with: replacement, files: [GitSyncRecovery.path: replacedRecovery],
                mode: .encrypted, expectedHead: GitObjectID(hex: try repository.git(["rev-parse", "main"])))
            steps.append(.obj([
                ("call", .str("replaceLibrary(current, with: new dataset, files: [keys/recovery.json], mode: .encrypted)")),
                ("clockUnixSeconds", .n(1_785_312_240)),
                ("newDatasetID", .str(lower(replacement))),
            ]))

            let described = try repository.describe()
            let remote = try repository.remote()
            let accountPreimage = "snippets-git-account-v1\n\(remote.canonicalLocation)\n\(remote.refName)"
            let datasetPreimage = "snippets-git-dataset-v1\n\(remote.canonicalLocation)\n\(remote.refName)\n\(lower(Fixture.datasetID))"
            try require(scope.identity?.data.hex == sha256Hex(Data(accountPreimage.utf8)), "G4 account identity formula")
            try require(scope.datasetIdentity?.data.hex == sha256Hex(Data(datasetPreimage.utf8)), "G4 dataset identity formula")
            cases.append(vcase("encrypted-library", [
                ("kind", .str("repository")),
                ("mode", .str("encrypted")),
                ("remoteURL", .str("http://snippets-interop.localhost/repo.git")),
                ("branch", .str("main")),
                ("datasetID", .str(lower(Fixture.datasetID))),
                ("syncKeyHex", .hex(Data.filled(0x99, 32))),
                ("syncSaltHex", .hex(Data.filled(0xaa, 32))),
                ("transportScope", .obj([
                    ("canonicalIdentity", .str(remote.canonicalLocation)),
                    ("refName", .str(remote.refName)),
                    ("accountIdentityHex", .opt(scope.identity?.data.hex)),
                    ("datasetIdentityHex", .opt(scope.datasetIdentity?.data.hex)),
                    ("cursorAfterCreation", .opt(fetched.cursor?.rawValue)),
                ])),
                ("steps", .arr(steps)),
                ("commits", .arr(described.commits)),
                ("blobs", .arr(described.blobs)),
                ("fsck", .str("git fsck --strict: clean")),
            ]))
        }

        // MARK: Plain-text library

        do {
            let repository = try Repository(host: "snippets-interop-plain.localhost")
            let codec = GitPlainCodec(sealer: SnippetCryptoSealer(keyring: Fixture.syncKeyring, scopeID: Fixture.syncScope))
            let device = try repository.transport("plain", plainText: codec)
            var steps: [J] = []
            _ = try await device.initializeRepository(
                datasetID: Fixture.datasetID, files: [GitSyncRecovery.path: recovery], mode: .plainText)
            steps.append(.obj([
                ("call", .str("initializeRepository(datasetID:files:mode: .plainText)")),
                ("clockUnixSeconds", .n(1_785_312_000)),
            ]))
            let fetched = try await device.fetchChanges(since: nil)

            // Two snippets with the same name whose ids share their first eight
            // characters: the second file name gets the "-2" suffix.
            func named(_ id: String, _ name: String, _ body: String) -> SyncEnvelope {
                .plain(Snippet(
                    id: UUID(uuidString: id)!, name: name, keyword: "", content: body, tags: ["Ünï", "two words"],
                    createdAt: Fixture.created, updatedAt: Fixture.updated),
                    hlc: CryptoVectorsB.hlc, origin: "aabbccdd")
            }
            let twinA = named("C0FFEE00-0000-4000-8000-000000000001", "Café Notes", "first\n")
            let twinB = named("C0FFEE00-0000-4000-8000-000000000002", "Café Notes", "second\r\n")
            // An ordinary snippet whose `x` bag is not empty cannot be Markdown; it stays
            // a sealed record under records/.
            let carriesExtension = SyncEnvelope.plain(
                Snippet(
                    id: UUID(uuidString: "0A000000-0000-4000-8000-00000000000A")!, name: "Carries x",
                    keyword: "", content: "body", createdAt: Fixture.created, updatedAt: Fixture.updated),
                hlc: CryptoVectorsB.hlc, origin: "aabbccdd", x: ["future.flag": true])
            repository.clock.set(1_785_312_060)
            let first = try await device.submit([
                try sealed(try envelope("plain"), nonce: 0xb0),
                try sealed(try envelope("plain-unicode-and-escapes"), nonce: 0xb1),
                try sealed(try envelope("plain-empty-fields"), nonce: 0xb2),
                try sealed(try envelope("secure"), nonce: 0xb3),
                try sealed(carriesExtension, nonce: 0xe3),
                try sealed(twinA, nonce: 0xe0),
                try sealed(twinB, nonce: 0xe1),
            ], at: fetched.cursor)
            let versions = try accepted(first)
            steps.append(.obj([
                ("call", .str("submit(new records: three renderable snippets, one secure, one carrying an x member, two that want the same file name)")),
                ("clockUnixSeconds", .n(1_785_312_060)),
                ("results", resultsJ(first)),
                ("cursor", .opt(first.cursor?.rawValue)),
            ]))

            // Rename one snippet (new file name) and delete another (Markdown file
            // goes, a sealed tombstone appears under records/).
            var renamed = try envelope("plain-unicode-and-escapes")
            if var fields = renamed.fields {
                fields.name = "Renamed snippet"
                renamed = SyncEnvelope(
                    id: renamed.id, hlc: CryptoVectorsB.laterHLC, origin: "0badcafe", secure: false,
                    deleted: false, fields: fields)
            }
            repository.clock.set(1_785_312_120)
            let second = try await device.submit([
                try sealed(renamed, nonce: 0xe2, version: versions[renamed.id]),
                try sealed(try envelope("tombstone-plain"), nonce: 0xb4, version: versions[Fixture.uuidA]),
            ], at: first.cursor)
            _ = try accepted(second)
            steps.append(.obj([
                ("call", .str("submit(rename of one snippet, tombstone of another)")),
                ("clockUnixSeconds", .n(1_785_312_120)),
                ("results", resultsJ(second)),
                ("cursor", .opt(second.cursor?.rawValue)),
            ]))

            let described = try repository.describe()
            cases.append(vcase("plain-text-library", [
                ("kind", .str("repository")),
                ("mode", .str("plainText")),
                ("remoteURL", .str("http://snippets-interop-plain.localhost/repo.git")),
                ("branch", .str("main")),
                ("datasetID", .str(lower(Fixture.datasetID))),
                ("syncKeyHex", .hex(Data.filled(0x99, 32))),
                ("syncSaltHex", .hex(Data.filled(0xaa, 32))),
                ("steps", .arr(steps)),
                ("commits", .arr(described.commits)),
                ("blobs", .arr(described.blobs)),
                ("fsck", .str("git fsck --strict: clean")),
            ]))
        }

        // MARK: Object primitives

        let ids = (1...6).map { GitObjectID(hex: String(repeating: String($0), count: 40))! }
        let treeEntries: [GitTreeEntry] = [
            .blob("a.b", ids[0]), .tree("a", ids[1]), .blob("a-b", ids[2]), .blob("B", ids[3]),
            .blob("a0", ids[4]), .tree("a.", ids[5]),
            GitTreeEntry(mode: Array("100755".utf8), name: Array("run.sh".utf8), id: ids[0]),
            GitTreeEntry(mode: Array("120000".utf8), name: Array("link".utf8), id: ids[1]),
            GitTreeEntry(mode: Array("160000".utf8), name: Array("submodule".utf8), id: ids[2]),
            GitTreeEntry(mode: Array("100644".utf8), name: [0x66, 0xff, 0x6f], id: ids[3]),
            .blob("é.md", ids[4]),
        ]
        let treeBytes = GitTree.serialize(treeEntries)
        cases.append(vcase("tree-sort-order", [
            ("kind", .str("tree")),
            ("inputEntries", .arr(treeEntries.map { entry in
                .obj([
                    ("mode", .str(String(decoding: entry.mode, as: UTF8.self))),
                    ("nameHex", .hex(entry.name)), ("id", .str(entry.id.hex)),
                ])
            })),
            ("sortedNamesHex", .arr(GitTree.sorted(treeEntries).map { .hex($0.name) })),
            ("treeHex", .hex(treeBytes)),
            ("treeID", .str(GitObjectID.hash(type: .tree, content: treeBytes).hex)),
        ]))
        for (name, date, parents, message) in [
            ("commit-creating", 1_785_312_000.0, [GitObjectID](), "Create Snippets library"),
            ("commit-with-parent-fractional-date", 1_785_312_060.999, [ids[0]], "Sync 1 record"),
            ("commit-negative-date-clamps-to-zero", -5.0, [ids[0]], "Sync 2 records"),
            ("commit-normalize-message", 0.0, [ids[1]], "Normalize 3 file(s) edited outside Snippets"),
        ] {
            let data = GitCommit.serialize(tree: ids[5], parents: parents, date: Date(timeIntervalSince1970: date), message: message)
            cases.append(vcase(name, [
                ("kind", .str("commit")),
                ("tree", .str(ids[5].hex)),
                ("parents", .strings(parents.map(\.hex))),
                ("unixSeconds", .double(date)),
                ("message", .str(message)),
                ("rawText", utf8Text(data)),
                ("rawHex", .hex(data)),
                ("commitID", .str(GitObjectID.hash(type: .commit, content: data).hex)),
            ]))
        }
        for (name, type, content) in [
            ("object-empty-blob", GitObjectType.blob, Data()),
            ("object-hello-blob", GitObjectType.blob, Data("hello\n".utf8)),
            ("object-empty-tree", GitObjectType.tree, Data()),
        ] {
            cases.append(vcase(name, [
                ("kind", .str("object-id")),
                ("type", .str(type.name)),
                ("contentHex", .hex(content)),
                ("headerHex", .hex(GitObjectType.header(type: type, size: content.count))),
                ("id", .str(GitObjectID.hash(type: type, content: content).hex)),
            ]))
        }
        return VectorFile(
            name: "G04-git-repository",
            pins: "Tree and commit object bytes and ids as GitSyncTransport builds them: two whole repositories (encrypted and plain-text) written through git http-backend, plus GitTree.serialize / GitCommit.serialize primitives (brief 03 §2.9–§2.11)",
            notes: [
                "The repositories are produced by the unmodified GitSyncTransport (initializeRepository, submit, writeFiles, replaceLibrary) against a real bare repository served by `git http-backend`, with the transport's clock injected. The tool then reads every object back with the git CLI, asserts that GitTree.serialize and GitCommit.serialize reproduce the stored bytes, that every object hashes to its id, and that `git fsck --strict` is clean.",
                "commits are oldest first. `entries` is the recursive listing (like `git ls-tree -r -t`), `trees` each tree object's raw bytes. Blob contents are in `blobs`, keyed by id; README.md is listed by id only (bytes in G02).",
                "Record blobs are sealed with the fixed nonces of V12; the key files use fixed nonces too, so all ids are stable across runs.",
                "transportScope is read from the running transport (preflightScope) and equals G06's `interop-loopback` case.",
                "replaceLibrary drops records/ and keys/ of the old library and writes the manifest with schemaVersion 2.",
            ],
            cases: cases)
    }
}
