import Foundation
import Testing
@testable import SnippetsCore

private func plainEnvelope(
    _ id: UUID = UUID(), name: String = "Greeting", keyword: String = "hi", content: String = "Hello there!",
    tags: [String] = ["work"], ms: UInt64 = 1_786_579_200_000, device: String = "a1b2c3d4"
) -> SyncEnvelope {
    SyncEnvelope(
        id: id, hlc: HLC(wallMs: ms, counter: 3, device: device), origin: device, secure: false, deleted: false,
        fields: SyncEnvelope.Fields(
            name: name, keyword: keyword, content: Data(content.utf8), tags: tags, isEnabled: true,
            isPinned: false, createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.125),
            updatedAt: Date(timeIntervalSinceReferenceDate: 810_000_000.5)))
}

@Suite struct GitPlainSnippetFileTests {
    @Test func aWrittenFileReadsBackAsTheSameEnvelope() throws {
        for content in ["Hello there!", "two\nlines\n", "", "trailing blank\n\n", "тест 🙂", "---\nnot a header"] {
            let envelope = plainEnvelope(content: content)
            let data = try GitPlainSnippetFile.render(envelope)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.hasPrefix("---\nname: \"Greeting\"\nkeyword: \"hi\"\ntags: [\"work\"]\n"))
            #expect(text.contains("\n---\n\(content)\n"), "the body is the text, verbatim")
            let (read, edited) = try GitPlainSnippetFile.read(data, path: "snippets/x.md")
            #expect(!edited, "\(content.debugDescription)")
            #expect(read == envelope)
            #expect(try read.envelopeHash() == envelope.envelopeHash())
        }
    }

    @Test func secureRecordsAndDeletionsAreNeverRendered() {
        let secure = SyncEnvelope.secureRecord(
            id: UUID(), name: "PIN", keyword: "pin", plaintext: Data("1234".utf8), createdAt: Date(),
            updatedAt: Date(), hlc: HLC(wallMs: 1, counter: 0, device: "a1b2c3d4"), origin: "a1b2c3d4")
        #expect(!GitPlainSnippetFile.canRender(secure))
        #expect(throws: GitPlainSnippetFile.Failure.malformed) { _ = try GitPlainSnippetFile.render(secure) }
        let tombstone = plainEnvelope().tombstoned(hlc: HLC(wallMs: 2, counter: 0, device: "a1b2c3d4"), origin: "a1b2c3d4")
        #expect(!GitPlainSnippetFile.canRender(tombstone))
    }

    /// Every device derives the same revision from the same edited file, after the one
    /// it was written with.
    @Test func anEditIsDetectedAndDeterministic() throws {
        let original = plainEnvelope()
        var text = String(decoding: try GitPlainSnippetFile.render(original), as: UTF8.self)
        text = text.replacingOccurrences(of: "Hello there!", with: "Hello, edited on GitHub")
            .replacingOccurrences(of: "name: \"Greeting\"", with: "name: Greeting edited")
            .replacingOccurrences(of: "tags: [\"work\"]", with: "tags: [work, Mail]")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let (first, edited) = try GitPlainSnippetFile.read(Data(text.utf8), path: "snippets/a.md")
        let (second, _) = try GitPlainSnippetFile.read(Data(text.utf8), path: "snippets/a.md")
        #expect(edited)
        #expect(first == second)
        #expect(first.id == original.id)
        #expect(first.hlc > original.hlc)
        #expect(first.origin == HLC.foreignDevice)
        #expect(first.plainSnippet?.content == "Hello, edited on GitHub")
        #expect(first.plainSnippet?.name == "Greeting edited")
        #expect(first.fields?.tags == SnippetTagging.normalizedTags(["work", "Mail"]))
        #expect(first.fields?.createdAt == original.fields?.createdAt)

        // Rewritten with fresh metadata, the file reads as exactly that revision.
        let normalized = try GitPlainSnippetFile.render(first)
        let (again, editedAgain) = try GitPlainSnippetFile.read(normalized, path: "snippets/a.md")
        #expect(!editedAgain)
        #expect(again == first)
    }

    @Test func aFileAddedByHandBecomesASnippet() throws {
        let bare = Data("Just some text\n".utf8)
        let (envelope, edited) = try GitPlainSnippetFile.read(bare, path: "snippets/Meeting notes.md")
        #expect(edited)
        #expect(envelope.id == GitPlainSnippetFile.derivedID(path: "snippets/Meeting notes.md"))
        #expect(envelope.plainSnippet?.name == "Meeting notes")
        #expect(envelope.plainSnippet?.content == "Just some text")

        let front = Data("---\n# a comment\nname: 'Sig'\nkeyword: sig\ntags: a, b\nenabled: yes\npinned: no\n---\nBest,\nM\n".utf8)
        let (withFront, _) = try GitPlainSnippetFile.read(front, path: "snippets/sig.md")
        #expect(withFront.plainSnippet?.name == "Sig")
        #expect(withFront.plainSnippet?.keyword == "sig")
        #expect(withFront.plainSnippet?.content == "Best,\nM")
        #expect(withFront.fields?.tags == SnippetTagging.normalizedTags(["a", "b"]))
        #expect(withFront.fields?.isPinned == false)
        #expect(GitPlainSnippetFile.declaredID(front, path: "snippets/sig.md") == withFront.id)
    }

    /// Extension data can carry a secure loser's conflict snapshot; such a record and
    /// anything that would not read back exactly stay ciphertext.
    @Test func onlyExactlyRoundTrippingSnippetsWithoutExtensionsAreRendered() throws {
        var withExtension = plainEnvelope()
        withExtension.x["contentConflict.v1.example"] = .string("sealed secure loser")
        #expect(!GitPlainSnippetFile.canRender(withExtension))
        #expect(!GitPlainSnippetFile.canRender(plainEnvelope(name: "\u{FEFF}Name")))
        for content in ["ends with CR\r", "\r", "crlf\r\nbody\r\n"] {
            let envelope = plainEnvelope(content: content)
            let (read, edited) = try GitPlainSnippetFile.read(try GitPlainSnippetFile.render(envelope), path: "snippets/x.md")
            #expect(!edited && read == envelope, "\(content.debugDescription)")
        }
    }

    /// A file a newer Snippets wrote (a later `sync` schema, or `sync` keys this build
    /// does not know) is never read as a hand edit, so it is never rewritten downward.
    @Test func filesFromANewerFormatAreNeverReadAsHandEdits() throws {
        let path = "snippets/greeting.md"
        let text = String(decoding: try GitPlainSnippetFile.render(plainEnvelope()), as: UTF8.self)
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("sync: ") })
        var base64 = String(line.dropFirst("sync: ".count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let json = try #require(Data(base64Encoded: base64))
        let object = try #require(try CanonicalJSON.value(json).object)
        var newer = object
        newer["schemaVersion"] = .int(Int64(SyncEnvelope.currentSchemaVersion + 1))
        var extended = object
        extended["future"] = .string("value")
        for changed in [newer, extended] {
            let encoded = try CanonicalJSON.data(.object(changed)).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let file = Data(text.replacingOccurrences(of: String(line), with: "sync: \(encoded)").utf8)
            #expect(throws: GitPlainSnippetFile.Failure.tooNew) { _ = try GitPlainSnippetFile.read(file, path: path) }
        }
    }

    @Test func frontMatterAsEditorsWriteItParses() throws {
        let obsidian = Data("\u{FEFF}---\nname: Sig\nkeyword: sig\ntags:\n  - work\n  - \"mail\"\nenabled: 1\npinned: 0\nstray line\n---\nBody\n".utf8)
        let (envelope, _) = try GitPlainSnippetFile.read(obsidian, path: "snippets/sig.md")
        #expect(envelope.fields?.tags == SnippetTagging.normalizedTags(["work", "mail"]))
        #expect(envelope.fields?.isEnabled == true)
        #expect(envelope.fields?.isPinned == false)
        #expect(envelope.plainSnippet?.content == "Body")
        // Broken front matter is a mistake, never a new snippet made of the whole file.
        let unclosed = Data("---\nname: Sig\nid: 617a0002-0000-4000-8000-000000000002\nBody\n".utf8)
        let unclosedCRLF = Data("---\r\nname: Sig\r\nid: 617a0002-0000-4000-8000-000000000002\r\nBody\r\n".utf8)
        #expect(GitPlainSnippetFile.declaredID(unclosedCRLF, path: "snippets/sig.md")
            == UUID(uuidString: "617a0002-0000-4000-8000-000000000002"), "CRLF files scan too")
        #expect(throws: GitPlainSnippetFile.Failure.malformed) { _ = try GitPlainSnippetFile.read(unclosed, path: "snippets/sig.md") }
        #expect(GitPlainSnippetFile.declaredID(unclosed, path: "snippets/sig.md")
            == UUID(uuidString: "617a0002-0000-4000-8000-000000000002"))
        // The first valid id wins; a later invalid or second id never replaces it.
        let twice = Data("---\nid: 617a0002-0000-4000-8000-000000000002\nid: nope\nid: 617a0003-0000-4000-8000-000000000003\n---\nx\n".utf8)
        #expect(try GitPlainSnippetFile.parse(twice).id == UUID(uuidString: "617a0002-0000-4000-8000-000000000002"))
        // A crafted sync line naming an older schema is not an exact file.
        let exact = try GitPlainSnippetFile.render(plainEnvelope())
        let crafted = String(decoding: exact, as: UTF8.self)
        #expect(try GitPlainSnippetFile.read(Data(crafted.utf8), path: "snippets/x.md").edited == false)
    }

    @Test func fileNamesAreReadableAndStable() {
        let id = UUID(uuidString: "617a0002-0000-4000-8000-000000000002")!
        #expect(GitPlainSnippetFile.fileName(name: "Hello, World!", id: id) == "hello-world-617a0002.md")
        #expect(GitPlainSnippetFile.fileName(name: "Привет мир", id: id) == "privet-mir-617a0002.md")
        #expect(GitPlainSnippetFile.fileName(name: "🙂", id: id) == "snippet-617a0002.md")
        #expect(GitPlainSnippetFile.slug(String(repeating: "a", count: 80)).count == 48)
    }

    @Test func theManifestNamesTheMode() throws {
        let plain = GitSyncManifest(datasetID: UUID(), mode: .plainText)
        #expect(try GitSyncManifest.decode(try plain.encoded()) == plain)
        #expect(String(decoding: try plain.encoded(), as: UTF8.self).contains("snippets-plain-v1"))
        let future = String(decoding: try plain.encoded(), as: UTF8.self)
            .replacingOccurrences(of: "snippets-plain-v1", with: "snippets-plain-v9")
        #expect(throws: GitSyncLayoutError.incompatibleSchema) { _ = try GitSyncManifest.decode(Data(future.utf8)) }
    }
}

@Suite(.serialized) struct GitPlainTextTransportTests {
    private let sealer = SnippetCryptoSealer(keyring: SnippetCrypto.Keyring.generate(), scopeID: "sync-v1")
    private var codec: GitPlainCodec { GitPlainCodec(sealer: sealer) }

    private func library(_ fixture: GitFixture) async throws -> (GitSyncTransport, GitSyncTransport) {
        let a = try fixture.transport("a", plainText: codec)
        _ = try await a.initializeRepository(mode: .plainText)
        #expect(try await a.inspectRepository() == .library(datasetID: try await datasetID(a), mode: .plainText))
        return (a, try fixture.transport("b", plainText: codec))
    }

    private func datasetID(_ transport: GitSyncTransport) async throws -> UUID {
        guard case .library(let id, _) = try await transport.inspectRepository() else { throw GitSyncLayoutError.notALibrary }
        return id
    }

    private func seal(_ envelope: SyncEnvelope, version: SyncRecordVersion? = nil) throws -> WireRecord {
        var record = try WireCodec.seal(envelope, using: sealer)
        record.recordVersion = version
        return record
    }

    private func accepted(_ submission: SyncSubmission) throws -> [UUID: SyncRecordVersion] {
        var versions: [UUID: SyncRecordVersion] = [:]
        for result in submission.results {
            guard case .accepted(_, let version) = result.outcome else {
                throw GitSyncLayoutError.malformedRecord
            }
            versions[result.id] = version
        }
        return versions
    }

    private func files(_ fixture: GitFixture) throws -> [String] {
        try fixture.git(["--git-dir", fixture.bare.path, "ls-tree", "-r", "--name-only", "main"])
            .split(separator: "\n").map(String.init)
    }

    private func show(_ fixture: GitFixture, _ path: String) throws -> String {
        try fixture.git(["--git-dir", fixture.bare.path, "show", "main:\(path)"])
    }

    @Test func ordinarySnippetsAreReadableAndSecureOnesAreNot() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let plain = plainEnvelope(content: "Readable body 51c2")
        let secure = SyncEnvelope.secureRecord(
            id: UUID(), name: "Bank PIN 7d1e", keyword: "pin", plaintext: Data("secret 9e44".utf8),
            createdAt: Date(), updatedAt: Date(), hlc: HLC(wallMs: 5, counter: 0, device: "a1b2c3d4"),
            origin: "a1b2c3d4")
        _ = try accepted(try await a.submit([try seal(plain), try seal(secure)], at: nil))

        let paths = try files(fixture)
        let markdown = try #require(paths.first { $0.hasPrefix("snippets/") })
        #expect(markdown == "snippets/greeting-\(plain.id.uuidString.lowercased().prefix(8)).md")
        #expect(try show(fixture, markdown).contains("Readable body 51c2"))
        #expect(paths.contains("records/\(GitSyncLayout.recordPath(secure.id).prefix)/\(GitSyncLayout.recordPath(secure.id).name)"))
        #expect(!paths.contains { $0.hasPrefix("records/") && $0.contains(plain.id.uuidString.lowercased()) })
        let history = try fixture.git(["--git-dir", fixture.bare.path, "log", "-p", "main"])
        #expect(!history.contains("secret 9e44") && !history.contains("Bank PIN 7d1e"))
        #expect(try show(fixture, "README.md").contains("plain text"))

        let fetched = try await b.fetchChanges(since: nil)
        let opened = try fetched.records.map { try WireCodec.open($0, using: sealer) }
        #expect(Set(opened.map(\.id)) == [plain.id, secure.id])
        #expect(opened.first { $0.id == plain.id } == plain)
        #expect(opened.first { $0.id == secure.id } == secure)
    }

    @Test func renamesDeletionsAndRecreationsMoveTheFile() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let original = plainEnvelope()
        var version = try #require(try accepted(try await a.submit([try seal(original)], at: nil))[original.id])

        let renamed = plainEnvelope(original.id, name: "Welcome", ms: 1_786_579_300_000)
        version = try #require(try accepted(try await a.submit([try seal(renamed, version: version)], at: nil))[original.id])
        #expect(try files(fixture).filter { $0.hasPrefix("snippets/") } == ["snippets/welcome-\(original.id.uuidString.lowercased().prefix(8)).md"])

        let deleted = renamed.tombstoned(hlc: HLC(wallMs: 1_786_579_400_000, counter: 0, device: "a1b2c3d4"), origin: "a1b2c3d4")
        version = try #require(try accepted(try await a.submit([try seal(deleted, version: version)], at: nil))[original.id])
        #expect(try files(fixture).filter { $0.hasPrefix("snippets/") }.isEmpty)
        #expect(try await b.fetchChanges(since: nil).records.map { try WireCodec.open($0, using: sealer) } == [deleted])

        let recreated = plainEnvelope(original.id, name: "Back", ms: 1_786_579_500_000)
        _ = try accepted(try await a.submit([try seal(recreated, version: version)], at: nil))
        #expect(try files(fixture).filter { $0.contains(original.id.uuidString.lowercased()) || $0.hasPrefix("snippets/") }
            == ["snippets/back-\(original.id.uuidString.lowercased().prefix(8)).md"])
    }

    /// An edit made in the repository reaches every device as the same revision, the
    /// file is rewritten once with fresh metadata, and a second edit orders after it.
    @Test func editsMadeInTheRepositorySync() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let original = plainEnvelope()
        _ = try accepted(try await a.submit([try seal(original)], at: nil))
        let cursorA = try await a.fetchChanges(since: nil).cursor
        let cursorB = try await b.fetchChanges(since: nil).cursor
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })

        try fixture.commitAsAnotherWriter { work in
            let url = work.appending(path: path)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "Hello there!", with: "Edited in git").utf8).write(to: url)
        }
        let seenByB = try await b.fetchChanges(since: cursorB)
        let edited = try WireCodec.open(try #require(seenByB.records.first), using: sealer)
        #expect(edited.plainSnippet?.content == "Edited in git")
        #expect(edited.hlc > original.hlc)
        // B rewrote the file; A, still behind, derives exactly the same revision.
        #expect(try fixture.git(["--git-dir", fixture.bare.path, "log", "-1", "--format=%s", "main"]).hasPrefix("Normalize"))
        let seenByA = try await a.fetchChanges(since: cursorA)
        #expect(seenByA.records.map(\.rev) == seenByB.records.map(\.rev))
        #expect(try await b.fetchChanges(since: seenByB.cursor).records.isEmpty, "the rewrite is not a new change")

        try fixture.commitAsAnotherWriter { work in
            let url = work.appending(path: path)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "Edited in git", with: "Edited twice").utf8).write(to: url)
        }
        let second = try WireCodec.open(try #require(try await a.fetchChanges(since: seenByA.cursor).records.first), using: sealer)
        #expect(second.plainSnippet?.content == "Edited twice")
        #expect(second.hlc > edited.hlc, "a later edit outranks the earlier one")
    }

    /// A device joining after a hand edit (no earlier snapshot) normalizes it too.
    @Test func aFreshDeviceNormalizesAnEditItFinds() async throws {
        let fixture = try GitFixture()
        let (a, _) = try await library(fixture)
        _ = try accepted(try await a.submit([try seal(plainEnvelope())], at: nil))
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try fixture.commitAsAnotherWriter { work in
            let url = work.appending(path: path)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "Hello there!", with: "Edited before joining").utf8).write(to: url)
        }
        let fresh = try fixture.transport("fresh", plainText: codec)
        _ = try await fresh.preflightScope()
        let fetched = try await fresh.fetchChanges(since: nil)
        #expect(try WireCodec.open(try #require(fetched.records.first), using: sealer).plainSnippet?.content
            == "Edited before joining")
        #expect(try fixture.git(["--git-dir", fixture.bare.path, "log", "-1", "--format=%s", "main"]).hasPrefix("Normalize"))
    }

    @Test func filesDeletedOrAddedByHandSync() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let kept = plainEnvelope(name: "Kept")
        let removed = plainEnvelope(name: "Removed")
        _ = try accepted(try await a.submit([try seal(kept), try seal(removed)], at: nil))
        let cursor = try await b.fetchChanges(since: nil).cursor
        let removedPath = try #require(try files(fixture).first { $0.hasPrefix("snippets/removed-") })

        try fixture.commitAsAnotherWriter { work in
            try FileManager.default.removeItem(at: work.appending(path: removedPath))
            try Data("---\nname: Added\nkeyword: added\n---\nAdded by hand\n".utf8)
                .write(to: work.appending(path: "snippets/added.md"))
        }
        let changes = try await b.fetchChanges(since: cursor).records.map { try WireCodec.open($0, using: sealer) }
        let deletion = try #require(changes.first { $0.id == removed.id })
        #expect(deletion.deleted)
        #expect(!deletion.carriesUserInitiatedDeletion, "goes through the unexplained-deletion safety")
        let added = try #require(changes.first { $0.plainSnippet?.name == "Added" })
        #expect(added.plainSnippet?.content == "Added by hand")
        #expect(added.id == GitPlainSnippetFile.derivedID(path: "snippets/added.md"))
        // The deletion is recorded as a tombstone, so other devices see the same thing.
        let tombstonePath = "records/\(GitSyncLayout.recordPath(removed.id).prefix)/\(GitSyncLayout.recordPath(removed.id).name)"
        #expect(try files(fixture).contains(tombstonePath))
    }

    private func editFile(_ fixture: GitFixture, _ path: String, _ change: (String) -> String) throws {
        try fixture.commitAsAnotherWriter { work in
            let url = work.appending(path: path)
            try Data(change(try String(contentsOf: url, encoding: .utf8)).utf8).write(to: url)
        }
    }

    /// A broken edit quarantines the snippet; it neither deletes it nor creates another.
    @Test func brokenFrontMatterQuarantinesInsteadOfDeleting() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let original = plainEnvelope()
        _ = try accepted(try await a.submit([try seal(original)], at: nil))
        let cursor = try await b.fetchChanges(since: nil).cursor
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try editFile(fixture, path) { $0.replacingOccurrences(of: "\n---\nHello", with: "\nHello") }
        let records = try await b.fetchChanges(since: cursor).records
        #expect(records.count == 1)
        #expect(records.first?.id == original.id)
        #expect(records.first?.blob.isEmpty == true, "delivered as unreadable, so the engine keeps its copy")
        #expect(!(try files(fixture)).contains { $0.hasPrefix("records/") }, "no tombstone")
    }

    @Test func aMistypedIDLineKeepsTheSnippet() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let original = plainEnvelope()
        _ = try accepted(try await a.submit([try seal(original)], at: nil))
        let cursor = try await b.fetchChanges(since: nil).cursor
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try editFile(fixture, path) {
            $0.replacingOccurrences(of: "id: \(original.id.uuidString.lowercased())", with: "id: oops")
                .replacingOccurrences(of: "Hello there!", with: "Edited with a typo")
        }
        let opened = try await b.fetchChanges(since: cursor).records.map { try WireCodec.open($0, using: sealer) }
        #expect(opened.map(\.id) == [original.id])
        #expect(opened.first?.plainSnippet?.content == "Edited with a typo")
        #expect(try show(fixture, path).contains("id: \(original.id.uuidString.lowercased())"), "normalizing restored it")
    }

    /// Only the `id` line changed, to another valid id: still that snippet, and the
    /// line is put back.
    @Test func aReplacedIDLineAloneIsRestored() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let original = plainEnvelope()
        _ = try accepted(try await a.submit([try seal(original)], at: nil))
        let cursor = try await b.fetchChanges(since: nil).cursor
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try editFile(fixture, path) {
            $0.replacingOccurrences(of: "id: \(original.id.uuidString.lowercased())", with: "id: \(UUID().uuidString.lowercased())")
        }
        let opened = try await b.fetchChanges(since: cursor).records.map { try WireCodec.open($0, using: sealer) }
        #expect(opened.map(\.id) == [original.id])
        #expect(try show(fixture, path).contains("id: \(original.id.uuidString.lowercased())"))
    }

    /// Which snippet a file is depends only on the file (its hash-covered `sync` id),
    /// never on a device's history: a device with a cache and a fresh one agree, and no
    /// two devices keep rewriting the `id` line to their own value.
    @Test func aDamagedIDLineReadsTheSameOnEveryDevice() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let original = plainEnvelope()
        _ = try accepted(try await a.submit([try seal(original)], at: nil))
        var cursorB = try await b.fetchChanges(since: nil).cursor
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try editFile(fixture, path) {
            $0.replacingOccurrences(of: "id: \(original.id.uuidString.lowercased())\n", with: "")
        }
        let fresh = try fixture.transport("fresh", plainText: codec)
        let fromHistory = try await b.fetchChanges(since: cursorB)
        cursorB = fromHistory.cursor
        let fromNothing = try await fresh.fetchChanges(since: nil).records
        #expect(fromHistory.records.map(\.id) == [original.id])
        #expect(fromNothing.map(\.id) == [original.id])
        #expect(try show(fixture, path).contains("id: \(original.id.uuidString.lowercased())"))
        let commits = try fixture.git(["--git-dir", fixture.bare.path, "rev-list", "--count", "main"])
        for _ in 0..<3 {
            cursorB = try await b.fetchChanges(since: cursorB).cursor
            _ = try await fixture.transport("fresh-\(UUID())", plainText: codec).fetchChanges(since: nil)
        }
        #expect(try fixture.git(["--git-dir", fixture.bare.path, "rev-list", "--count", "main"]) == commits,
                "no device keeps rewriting the file")
    }

    /// A device that lost its (disposable) cache still meets a hand deletion as a
    /// conflict, never as a remote-data-reset halt.
    @Test func anEditAfterAHandDeletionWithoutACacheIsAConflict() async throws {
        let fixture = try GitFixture()
        let (a, _) = try await library(fixture)
        let original = plainEnvelope()
        let version = try #require(try accepted(try await a.submit([try seal(original)], at: nil))[original.id])
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try fixture.commitAsAnotherWriter { work in try FileManager.default.removeItem(at: work.appending(path: path)) }
        let restored = try fixture.transport("restored", plainText: codec)
        let edit = plainEnvelope(original.id, content: "late edit", ms: 1_786_579_900_000)
        let submission = try await restored.submit([try seal(edit, version: version)], at: nil)
        guard case .rejected(.conflict(let remote?)) = submission.results.first?.outcome else {
            Issue.record("expected a conflict: \(submission.results)")
            return
        }
        let tombstone = try WireCodec.open(remote, using: sealer)
        #expect(tombstone.deleted)
        #expect(tombstone.hlc < edit.hlc, "the edit outranks a deletion this device cannot date")
    }

    /// Someone with push access cannot turn an encrypted library into plain text: a
    /// device refuses a manifest that names another mode than the one it agreed to.
    @Test func aChangedLibraryModeStopsSync() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a", expectedMode: .encrypted)
        _ = try await a.initializeRepository()
        _ = try await a.fetchChanges(since: nil)
        try fixture.commitAsAnotherWriter { work in
            let manifest = work.appending(path: GitSyncLayout.manifestName)
            let text = try String(contentsOf: manifest, encoding: .utf8)
            try Data(text.replacingOccurrences(of: GitLibraryMode.encrypted.rawValue, with: GitLibraryMode.plainText.rawValue).utf8)
                .write(to: manifest)
        }
        let victim = try fixture.transport("victim", plainText: codec, expectedMode: .encrypted)
        for attempt in [{ _ = try await victim.fetchChanges(since: nil) },
                        { _ = try await victim.submit([try seal(plainEnvelope())], at: nil) }] {
            do {
                try await attempt()
                Issue.record("a changed mode must stop sync")
            } catch SyncTransportFailure.rejected(.permanent(let detail)) {
                #expect(detail == "git_library_mode_changed")
            }
        }
        #expect(!(try files(fixture)).contains { $0.hasPrefix("snippets/") }, "nothing was published")
    }

    /// A Markdown file restored by hand while a tombstone shadows it must not take over
    /// the snippet when it comes back: the live snippet overwrites that file.
    @Test func aRestoredFileDoesNotTakeOverARecreatedSnippet() async throws {
        let fixture = try GitFixture()
        let (a, _) = try await library(fixture)
        let original = plainEnvelope()
        var version = try #require(try accepted(try await a.submit([try seal(original)], at: nil))[original.id])
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        let deleted = original.tombstoned(hlc: HLC(wallMs: 1_786_579_300_000, counter: 0, device: "a1b2c3d4"), origin: "a1b2c3d4")
        version = try #require(try accepted(try await a.submit([try seal(deleted, version: version)], at: nil))[original.id])
        #expect(!(try files(fixture)).contains(path))
        try fixture.commitAsAnotherWriter { work in
            try fixture.git(["-C", work.path, "checkout", "HEAD~1", "--", path])
        }
        let back = plainEnvelope(original.id, content: "Back again", ms: 1_786_579_400_000)
        _ = try accepted(try await a.submit([try seal(back, version: version)], at: nil))
        let snippetFiles = try files(fixture).filter { $0.hasPrefix("snippets/") }
        #expect(snippetFiles == [path], "the restored file was overwritten, not copied around")
        let fresh = try await fixture.transport("fresh", plainText: codec).fetchChanges(since: nil).records
            .map { try WireCodec.open($0, using: sealer) }
        #expect(fresh.map(\.id) == [original.id])
        #expect(fresh.first?.plainSnippet?.content == "Back again")
    }

    @Test func aCopiedFileBecomesItsOwnSnippet() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let original = plainEnvelope()
        _ = try accepted(try await a.submit([try seal(original)], at: nil))
        let cursor = try await b.fetchChanges(since: nil).cursor
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try fixture.commitAsAnotherWriter { work in
            let text = try String(contentsOf: work.appending(path: path), encoding: .utf8)
            try Data(text.replacingOccurrences(of: "Hello there!", with: "A copy").utf8)
                .write(to: work.appending(path: "snippets/address.md"))
        }
        let opened = try await b.fetchChanges(since: cursor).records.map { try WireCodec.open($0, using: sealer) }
        #expect(opened.count == 1)
        #expect(opened.first?.id == GitPlainSnippetFile.derivedID(path: "snippets/address.md"))
        #expect(opened.first?.plainSnippet?.content == "A copy")
        let all = try await fixture.transport("c", plainText: codec).fetchChanges(since: nil).records
            .map { try WireCodec.open($0, using: sealer) }
        #expect(all.first { $0.id == original.id } == original, "the original is untouched")
    }

    /// An edit pending on a device whose file was deleted by hand meets the deletion as a
    /// conflict, never as a remote-data-reset halt, and the deletion is then recorded.
    @Test func anEditOfAFileDeletedByHandIsAConflict() async throws {
        let fixture = try GitFixture()
        let (a, _) = try await library(fixture)
        let original = plainEnvelope()
        let version = try #require(try accepted(try await a.submit([try seal(original)], at: nil))[original.id])
        _ = try await a.fetchChanges(since: nil)
        let path = try #require(try files(fixture).first { $0.hasPrefix("snippets/") })
        try fixture.commitAsAnotherWriter { work in try FileManager.default.removeItem(at: work.appending(path: path)) }
        let edit = plainEnvelope(original.id, content: "late edit", ms: 1_786_579_900_000)
        let submission = try await a.submit([try seal(edit, version: version)], at: nil)
        guard case .rejected(.conflict(let remote?)) = submission.results.first?.outcome else {
            Issue.record("expected a conflict: \(submission.results)")
            return
        }
        #expect(try WireCodec.open(remote, using: sealer).deleted)
        _ = try await a.fetchChanges(since: nil)
        let tombstone = "records/\(GitSyncLayout.recordPath(original.id).prefix)/\(GitSyncLayout.recordPath(original.id).name)"
        #expect(try files(fixture).contains(tombstone), "the derived deletion was recorded")
    }

    @Test func aReadableFileNeverShadowsASecureRecord() async throws {
        let fixture = try GitFixture()
        let (a, b) = try await library(fixture)
        let secure = SyncEnvelope.secureRecord(
            id: UUID(), name: "PIN", keyword: "pin", plaintext: Data("1234".utf8), createdAt: Date(),
            updatedAt: Date(), hlc: HLC(wallMs: 5, counter: 0, device: "a1b2c3d4"), origin: "a1b2c3d4")
        _ = try accepted(try await a.submit([try seal(secure)], at: nil))
        try fixture.commitAsAnotherWriter { work in
            try FileManager.default.createDirectory(at: work.appending(path: "snippets"), withIntermediateDirectories: true)
            try Data("---\nname: PIN\nkeyword: pin\nid: \(secure.id.uuidString.lowercased())\n---\nattacker text\n".utf8)
                .write(to: work.appending(path: "snippets/pin.md"))
        }
        let records = try await b.fetchChanges(since: nil).records.map { try WireCodec.open($0, using: sealer) }
        #expect(records == [secure])
    }

    @Test func aPlainLibraryNeedsTheKey() async throws {
        let fixture = try GitFixture()
        let (a, _) = try await library(fixture)
        _ = try accepted(try await a.submit([try seal(plainEnvelope())], at: nil))
        let keyless = try fixture.transport("keyless")
        await #expect(throws: SyncTransportFailure.rejected(.permanent(detail: "git_key_required"))) {
            _ = try await keyless.fetchChanges(since: nil)
        }
    }

    @Test func encryptedLibrariesAreUnchanged() async throws {
        let fixture = try GitFixture()
        let a = try fixture.transport("a", plainText: codec)
        _ = try await a.initializeRepository()
        _ = try accepted(try await a.submit([try seal(plainEnvelope(content: "never readable 4f1a"))], at: nil))
        #expect(!(try files(fixture)).contains { $0.hasPrefix("snippets/") })
        #expect(!(try fixture.git(["--git-dir", fixture.bare.path, "log", "-p", "main"])).contains("never readable 4f1a"))
    }
}
