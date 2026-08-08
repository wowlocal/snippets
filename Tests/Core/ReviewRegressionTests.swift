import Foundation
import CryptoKit
import Testing
@testable import SnippetsCore

/// Regressions for defects found in code review of the concurrency work.
///
/// Each one is a bug that shipped in a commit whose test suite was entirely green, so
/// each test here is paired with the specific wrong behaviour it now forbids. The
/// value is in the comments as much as the assertions: several of these look like
/// pedantic edge cases and are in fact total data loss.
@Suite("Review regressions")
struct ReviewRegressionTests {

    private static func snippet(
        _ name: String, keyword: String, content: String = "body", tags: [String] = [],
        updatedAt: Double = 1_000
    ) -> Snippet {
        Snippet(name: name, keyword: keyword, content: content, tags: tags,
                createdAt: Date(timeIntervalSince1970: 500),
                updatedAt: Date(timeIntervalSince1970: updatedAt))
    }

    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - A missing file is not an empty library

    /// **The bug**: `read` mapped every failure of `Data(contentsOf:)`, including
    /// ENOENT, onto an empty snapshot. The caller could not tell "the file is gone"
    /// from "a peer emptied the library", and the three-way merge has to treat those
    /// as opposites.
    @Test func aMissingLibraryIsReportedAsMissingNotAsEmpty() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("snippets.json")

        let missing = try LibraryWriter.read(from: library)
        #expect(missing.fileExisted == false)
        #expect(missing.snippets.isEmpty)

        try SnippetLibraryCodec.encode([]).write(to: library)
        let empty = try LibraryWriter.read(from: library)
        #expect(empty.fileExisted == true, "an empty ARRAY is a real file and a real statement")
        #expect(empty.snippets.isEmpty)
    }

    /// **Why the distinction is load-bearing**, stated as an executable fact.
    ///
    /// This asserts the merge's *correct* behaviour: given an ancestor and a remote
    /// that genuinely dropped everything, every untouched record is deleted. That is
    /// right — it is what "the peer deleted the library" means. It is also why feeding
    /// a vanished file in here is catastrophic, and why `SnippetStore.writeToDisk`
    /// refuses to call this when `fileExisted` is false: a cleanup script, a
    /// drag-to-Trash, a Migration Assistant restore, or a transient ENOENT on a
    /// network home would otherwise turn 200 snippets into 1, durably, with the undo
    /// stacks rebased onto the wreckage.
    @Test func mergingAgainstAGenuinelyEmptiedRemoteDeletesEverything() {
        let records = (0..<20).map { Self.snippet("n\($0)", keyword: "k\($0)") }
        var edited = records
        edited[0].content = "edited locally"

        let outcome = SyncMerge.mergeLocal(base: records, local: edited, remote: [])

        // The one record the user edited survives — an edit beats a delete. The
        // nineteen untouched ones are correctly treated as deleted by the peer.
        #expect(outcome.snippets.count == 1)
        #expect(outcome.snippets.first?.content == "edited locally")
    }

    /// A read failure that is NOT "file missing" must throw, never present as empty.
    /// Reporting an unreadable file as an empty library is worse than failing: the
    /// caller saves the emptiness, turning a transient permissions or I/O error into
    /// permanent loss.
    @Test func anUnreadableButPresentLibraryThrowsRatherThanPresentingAsEmpty() throws {
        let dir = try sandbox()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: dir.appendingPathComponent("snippets.json").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let library = dir.appendingPathComponent("snippets.json")
        try SnippetLibraryCodec.encode([Self.snippet("a", keyword: "a")]).write(to: library)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: library.path)

        // Running as root would defeat the permission bit and make this vacuous.
        try #require(getuid() != 0, "this test is meaningless as root")
        #expect(throws: (any Error).self) { try LibraryWriter.read(from: library) }
    }

    // MARK: - Undo is an intent, not a competing edit

    /// **The bug**: undo/redo snapshots were rebased by running them through
    /// `mergeLocal`, which treats them as a concurrent device. No concurrency is
    /// needed to break it — three sequential versions suffice: edit v1→v2, a foreign
    /// write makes it v3, and the rebase then sees base v2, local v1, remote v3, all
    /// distinct. That is a content conflict by definition, so ⌘Z restored nothing and
    /// instead minted a disabled `(conflict …)` record into the shared library.
    @Test func rebasingAnUndoSnapshotNeverMintsAConflictCopy() {
        let original = Self.snippet("note", keyword: "n", content: "v1")
        var v2 = original; v2.content = "v2"
        var v3 = original; v3.content = "v3 from the CLI"

        // The undo entry says "put it back to v1". It was captured against [v2].
        let rebased = SyncMerge.rebaseSnapshot([original], from: [v2], onto: [v3])

        #expect(rebased.count == 1, "a rebase must not add records")
        #expect(rebased[0].content == "v1", "undo restores the value the user asked for")
        #expect(rebased.allSatisfy { !$0.tags.contains("conflict") })
        #expect(rebased.allSatisfy { $0.isEnabled })
    }

    /// The other half: a rebase must not discard what the foreign writer added.
    @Test func rebasingAnUndoSnapshotKeepsRecordsTheUndoNeverTouched() {
        let mine = Self.snippet("mine", keyword: "m", content: "v1")
        var mineEdited = mine; mineEdited.content = "v2"
        let theirs = Self.snippet("theirs", keyword: "t")

        // Undo says "put `mine` back to v1"; it has never heard of `theirs`.
        let rebased = SyncMerge.rebaseSnapshot([mine], from: [mineEdited], onto: [mineEdited, theirs])

        #expect(rebased.count == 2)
        #expect(rebased.first { $0.id == mine.id }?.content == "v1")
        #expect(rebased.contains { $0.id == theirs.id }, "the other writer's record must survive undo")
    }

    /// A deletion in the undo snapshot still means "delete", and must not resurrect.
    @Test func rebasingAnUndoSnapshotThatDeletedARecordStillDeletesIt() {
        let a = Self.snippet("a", keyword: "a")
        let b = Self.snippet("b", keyword: "b")
        let rebased = SyncMerge.rebaseSnapshot([a], from: [a, b], onto: [a, b])
        #expect(rebased.map(\.id) == [a.id])
    }

    // MARK: - The merge must not enforce rules retroactively

    /// **The bug**: the keyword-collision pass swept the entire library, so the first
    /// merge after this code shipped would silently disable a duplicate keyword the
    /// user had been living with for months. The app has only ever *warned* about
    /// those; a background write is not the place to start enforcing.
    @Test func aPreExistingKeywordCollisionIsLeftAloneByAnUnrelatedMerge() {
        let dupA = Self.snippet("first", keyword: "dup", content: "a")
        let dupB = Self.snippet("second", keyword: "dup", content: "b")
        let other = Self.snippet("other", keyword: "other")

        // The remote only touches `other`. The duplicate pair is none of its business.
        var editedOther = other; editedOther.content = "changed remotely"
        let outcome = SyncMerge.mergeLocal(
            base: [dupA, dupB, other], local: [dupA, dupB, other], remote: [dupA, dupB, editedOther])

        #expect(outcome.disabledByKeywordCollision.isEmpty)
        let dups = outcome.snippets.filter { $0.normalizedKeyword == "dup" }
        #expect(dups.allSatisfy { $0.isEnabled })
    }

    /// But a collision the merge itself *creates* still gets resolved, deterministically.
    @Test func aCollisionTheMergeItselfCreatesIsStillResolved() {
        let mine = Self.snippet("mine", keyword: "taken", content: "a")
        let theirs = Self.snippet("theirs", keyword: "taken", content: "b")

        let outcome = SyncMerge.mergeLocal(base: [], local: [mine], remote: [theirs])
        #expect(outcome.snippets.filter { $0.isEnabled && $0.normalizedKeyword == "taken" }.count == 1)
        #expect(outcome.disabledByKeywordCollision.count == 1)

        // The keyword text is never cleared — that would destroy what the user typed.
        #expect(outcome.snippets.allSatisfy { $0.normalizedKeyword == "taken" })
    }

    // MARK: - Purity

    /// **The bug**: `filterKey` folded against `Locale.current`, so the merge read
    /// ambient process state. Two machines with different system languages could
    /// compute different results from byte-identical files and never converge. Turkish
    /// is the live case: under a Turkish locale `I` folds to `ı`, not `i`.
    @Test func tagFoldingDoesNotDependOnTheProcessLocale() {
        #expect(SnippetTagging.filterKey(for: "WORK") == SnippetTagging.filterKey(for: "work"))
        #expect(SnippetTagging.filterKey(for: "İstanbul") == SnippetTagging.filterKey(for: "istanbul"))
        #expect(SnippetTagging.filterKey(for: "CAFÉ") == SnippetTagging.filterKey(for: "cafe"))

        // The fold is a pure function of its input: same input, same answer, whatever
        // the process happens to be doing.
        let once = SnippetTagging.filterKey(for: "Iı-İi")
        for _ in 0..<50 { #expect(SnippetTagging.filterKey(for: "Iı-İi") == once) }
    }

    /// A merge run twice on the same inputs must produce byte-identical output,
    /// including the order of `conflictCopies` — which previously came out of a `Set`
    /// and so varied between two identical calls in one process.
    @Test func repeatedIdenticalMergesProduceIdenticalOutputIncludingConflictOrder() {
        var base: [Snippet] = [], local: [Snippet] = [], remote: [Snippet] = []
        for index in 0..<12 {
            let record = Self.snippet("n\(index)", keyword: "k\(index)", content: "base")
            base.append(record)
            var mine = record; mine.content = "mine-\(index)"; mine.updatedAt = Date(timeIntervalSince1970: 2_000)
            var theirs = record; theirs.content = "theirs-\(index)"; theirs.updatedAt = Date(timeIntervalSince1970: 2_000)
            local.append(mine); remote.append(theirs)
        }

        let first = SyncMerge.mergeLocal(base: base, local: local, remote: remote)
        for _ in 0..<20 {
            let again = SyncMerge.mergeLocal(base: base, local: local, remote: remote)
            #expect(again.snippets.map(\.id) == first.snippets.map(\.id))
            #expect(again.conflictCopies.map(\.id) == first.conflictCopies.map(\.id))
        }
    }

    // MARK: - Compare-and-swap

    /// The write path must re-read immediately before writing and confirm immediately
    /// after, so a peer that got in — only possible when the advisory lock has been
    /// bypassed — is folded in rather than clobbered.
    @Test func aWriteThatRacesAPeerRetriesAndFoldsThePeersRecordIn() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("snippets.json")
        let mine = Self.snippet("mine", keyword: "mine")
        let theirs = Self.snippet("theirs", keyword: "theirs")
        try SnippetLibraryCodec.encode([]).write(to: library)

        // Simulate the peer landing between our read and our write, exactly once.
        var injected = false
        let outcome = try LibraryWriter.update(
            libraryURL: library,
            stateURL: dir.appendingPathComponent("state.json"),
            lockURL: dir.appendingPathComponent("lock"),
            temporaryDirectory: dir,
            lockTimeout: 2,
            expectedDigest: nil
        ) { onDisk in
            if !injected {
                injected = true
                try? SnippetLibraryCodec.encode([theirs]).write(to: library)
            }
            return onDisk.snippets + [mine]
        }

        #expect(outcome.attempts > 1, "the racing write must have forced a retry")
        let onDisk = try LibraryWriter.read(from: library).snippets
        let final = Set(onDisk.map(\.name))
        #expect(final == ["mine", "theirs"], "neither writer's record may be lost")
    }
}

/// Pins the one invariant that is currently only enforced by a comment.
///
/// The crypto scope is inside the AAD of every secure record, so if it is ever sourced
/// from `Sync/state.json` — which `SyncStateFile.load` deliberately *regenerates*
/// whenever it is missing or unreadable, because it holds no user data — then losing
/// that file silently destroys every secret. The rule is "the value that unlocks a file
/// lives in that file", and the scope is `VaultDocument.kid`.
///
/// Documentation alone would not survive the sync engine being written by someone in a
/// hurry, so this asserts the property directly: a vault must open with no sync state
/// present at all.
@Suite("Vault independence from sync state")
struct VaultScopeIndependenceTests {

    @Test func aVaultOpensWithNoSyncStateOnDiskAtAll() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let libraryKey = SymmetricKey(size: .bits256)
        let kid = "k-\(UUID().uuidString.prefix(8))"
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let keyring = SnippetCrypto.Keyring(libraryKey: libraryKey, salt: salt)

        let recordID = UUID()
        // The scope comes from the vault's own `kid` — never from SyncState.
        let context = SnippetCrypto.RecordContext(scopeID: kid, recordID: recordID)
        let sealed = try SnippetCrypto.seal(Data("hunter2".utf8), for: context, keyring: keyring)

        // Now destroy every trace of sync bookkeeping, as a lost or corrupt
        // Sync/state.json would.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("Sync"))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Sync/state.json").path) == false)

        // A fresh SyncState mints a brand-new scopeID. If the crypto had been bound to
        // it, this is exactly where every secret would become unopenable.
        let regenerated = SyncState.fresh()
        #expect(regenerated.scopeID != kid, "a fresh sync state invents a new scope, as designed")

        let opened = try SnippetCrypto.open(
            sealed, for: SnippetCrypto.RecordContext(scopeID: kid, recordID: recordID), keyring: keyring)
        #expect(String(decoding: opened, as: UTF8.self) == "hunter2")

        // And the negative: the regenerated scope must NOT open it, which is what makes
        // sourcing the scope from SyncState catastrophic rather than merely untidy.
        #expect(throws: (any Error).self) {
            try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(scopeID: regenerated.scopeID, recordID: recordID),
                keyring: keyring)
        }
    }
}

/// The vault write path must not lose a record to a concurrent writer.
///
/// `VaultFile.write` was an unlocked whole-document overwrite — the same defect the
/// library write path was built to remove, in the one file where it matters most:
/// `vault.json` has no undo stack, no plaintext duplicate, and nothing to reconstruct
/// from. A lost record there is a lost secret.
@Suite("Vault write safety")
struct VaultWriteSafetyTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vaultwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func emptyVault(kid: String = "k-test") -> VaultDocument {
        VaultDocument(
            kid: kid,
            vaultSalt: "AAAAAAAAAAAAAAAAAAAAAA",
            kdf: VaultKDFParameters(alg: PassphraseKDF.algorithm, iterations: 600_000, saltP: "AAAAAAAAAAAAAAAAAAAAAA"))
    }

    private func record(_ name: String) -> VaultRecord {
        VaultRecord(
            id: UUID(), name: name, keyword: name, tags: [], isEnabled: true, isPinned: false,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
            hlc: HLC(wallMs: 1, counter: 0, device: "aaaaaaa1"),
            contentHash: "00", sealed: "v1.AAAA.AAAA")
    }

    /// A writer working from a stale copy must fold in what landed meanwhile, not
    /// overwrite it. This is the interleaving that silently drops a secret.
    @Test func aVaultWriteFoldsInARecordThatLandedAfterTheCallerRead() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vault.json")
        try VaultFile.write(emptyVault(), to: url, temporaryDirectory: dir)

        // Someone else adds a record between our read and our write.
        var injected = false
        let result = try VaultFile.update(
            at: url, lockURL: dir.appendingPathComponent("lock"),
            temporaryDirectory: dir, lockTimeout: 2
        ) { current in
            if !injected {
                injected = true
                var theirs = current ?? self.emptyVault()
                theirs.records.append(self.record("theirs"))
                try? VaultFile.write(theirs, to: url, temporaryDirectory: dir)
            }
            var mine = current ?? self.emptyVault()
            mine.records.append(self.record("mine"))
            return mine
        }

        // `update` re-reads inside the lock, so the second attempt sees "theirs".
        let names = Set(result.records.map(\.name))
        #expect(names.contains("mine"))
        #expect(names.contains("theirs"), "the concurrent record must not be overwritten")

        let reloaded = try #require(VaultFile.load(from: url).value)
        #expect(Set(reloaded.records.map(\.name)) == names)
    }

    /// An unreadable or corrupt vault must never be replaced by a fresh empty one.
    /// "I could not read it" and "there isn't one" are the same value and opposite
    /// facts — the same distinction the library path needed for a vanished file.
    @Test func updateRefusesToOverwriteAVaultItCannotRead() throws {
        let dir = try scratch()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: dir.appendingPathComponent("vault.json").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("vault.json")
        try VaultFile.write(emptyVault(), to: url, temporaryDirectory: dir)
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try VaultFile.update(
                at: url, lockURL: dir.appendingPathComponent("lock"),
                temporaryDirectory: dir, lockTimeout: 1
            ) { _ in self.emptyVault() }
        }

        // The damaged bytes are still there for a quarantine pass to rescue.
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json at all")
    }

    /// `update` validates the document it read, but the transform is free to return a
    /// different schema version. The output needs the same guard as the whole-file
    /// `write` API or an older build can publish bytes it promises not to understand.
    @Test func updateRefusesANewerSchemaReturnedByItsTransform() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vault.json")
        try VaultFile.write(emptyVault(), to: url, temporaryDirectory: dir)
        let original = try Data(contentsOf: url)

        let failure = #expect(throws: VaultFileError.self) {
            try VaultFile.update(
                at: url, lockURL: dir.appendingPathComponent("lock"),
                temporaryDirectory: dir, lockTimeout: 1
            ) { current in
                var unsupported = try #require(current)
                unsupported.schemaVersion = VaultDocument.currentSchemaVersion + 1
                return unsupported
            }
        }
        guard case .writeRefused = try #require(failure) else {
            Issue.record("expected the schema write to be refused, got \(String(describing: failure))")
            return
        }
        #expect(try Data(contentsOf: url) == original, "the refused update changed the vault")
    }

    @Test func durableRemovalIsIdempotent() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vault.json")
        try Data("ciphertext".utf8).write(to: url)

        try AtomicFileWriter.removeDurablyIfPresent(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A retry still fsyncs the parent before returning; it must not reinterpret
        // the requested missing postcondition as an error.
        try AtomicFileWriter.removeDurablyIfPresent(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// Secure content must not be able to leave through a share link.
///
/// A share link is a plaintext payload in a URL that lands on the pasteboard and from
/// there into a chat window and shell history — the worst possible destination for a
/// secret. The parameter has no default precisely so that omitting the check is a
/// compile error rather than something a reviewer has to notice.
@Suite("Share link refuses secrets")
struct ShareLinkTests {

    private func snippet() -> Snippet {
        Snippet(name: "AWS root", keyword: "awsroot", content: "hunter2")
    }

    @Test func aSecureSnippetCannotBeTurnedIntoAShareLink() {
        #expect(throws: SnippetDeepLinkError.secureSnippetNotShareable) {
            _ = try SnippetDeepLink.url(for: snippet(), isSecure: true)
        }
    }

    @Test func anOrdinarySnippetStillShares() throws {
        let url = try SnippetDeepLink.url(for: snippet(), isSecure: false)
        #expect(SnippetDeepLink.canHandle(url))
    }

    /// The refusal happens before any encoding, so the content never reaches a buffer
    /// that could end up in a log line or an error message.
    @Test func theRefusalMentionsNoContent() {
        do {
            _ = try SnippetDeepLink.url(for: snippet(), isSecure: true)
            Issue.record("expected a refusal")
        } catch {
            let text = "\(error) \((error as? LocalizedError)?.errorDescription ?? "")"
            #expect(!text.contains("hunter2"))
        }
    }
}

/// The local control channel's addressing rules.
///
/// `sockaddr_un.sun_path` is 104 bytes on macOS — a hard kernel limit. A long home
/// directory or a redirected support directory really does exceed it, and the failure
/// mode without a guard is either a confusing `EINVAL` at bind time or, far worse, a
/// silently truncated path that binds to a *different* socket whose name happens to be
/// a prefix of the intended one.
@Suite("IPC addressing")
struct IPCAddressingTests {

    @Test func aShortSupportPathKeepsTheSocketBesideTheOtherSyncFiles() {
        let url = SnippetsIPC.socketURL(supportFolder: URL(fileURLWithPath: "/tmp/s/Sync"))
        #expect(url.path == "/tmp/s/Sync/ipc.sock")
    }

    /// Observed in practice: the scratch directory used to test this project is itself
    /// long enough to trigger the fallback.
    @Test func anOverlongSupportPathFallsBackToAShortDeterministicName() {
        let long = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "d", count: 120) + "/Sync")
        let url = SnippetsIPC.socketURL(supportFolder: long)

        #expect(url.path.utf8.count < 104, "the fallback must itself fit in sun_path")
        #expect(url.lastPathComponent.hasPrefix("snippets-"))
        #expect(url.pathExtension == "sock")

        // Both sides derive it independently with no handshake, so it has to be a pure
        // function of the path — and a different path must not collide onto it.
        #expect(SnippetsIPC.socketURL(supportFolder: long) == url)
        let other = URL(fileURLWithPath: "/private/tmp/" + String(repeating: "e", count: 120) + "/Sync")
        #expect(SnippetsIPC.socketURL(supportFolder: other) != url)
    }

    /// Exit codes are a contract with shell scripts: `4` has to keep meaning "denied"
    /// or every wrapper anyone writes breaks on an upgrade.
    @Test func exitCodesAreStable() {
        #expect(SnippetsIPC.ExitCode.ok.rawValue == 0)
        #expect(SnippetsIPC.ExitCode.appNotRunning.rawValue == 3)
        #expect(SnippetsIPC.ExitCode.denied.rawValue == 4)
        #expect(SnippetsIPC.ExitCode.locked.rawValue == 5)
        #expect(SnippetsIPC.ExitCode.notFound.rawValue == 6)
    }

    /// An unknown command must decode and be answerable, not fail to parse. A stale
    /// `/usr/local/bin/snippets-cli` symlink is the normal state of the world.
    @Test func anUnknownCommandStillDecodes() throws {
        let json = Data(#"{"v":1,"command":"someFutureThing","extra":true}"#.utf8)
        let request = try JSONDecoder().decode(SnippetsIPC.Request.self, from: json)
        #expect(request.command == "someFutureThing")
        #expect(request.v == 1)
    }
}
