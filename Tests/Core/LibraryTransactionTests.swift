import Foundation
import Testing
@testable import SnippetsCore

/// The two-file critical section that promoting and demoting a secure snippet runs in.
///
/// Everything here is about the window between two `rename(2)` calls. Two files cannot
/// be swapped atomically with respect to a crash, so the guarantee is narrower and has
/// to be exact: **an interrupted move leaves the record in both files, never in
/// neither.** A duplicate is repairable at next launch; a disappearance is a secret
/// gone. Each test below pins one half of that.
@Suite("Library transaction")
struct LibraryTransactionTests {

    private struct Fixture {
        let dir: URL
        var library: URL { dir.appendingPathComponent("snippets.json") }
        var vault: URL { dir.appendingPathComponent("vault.json") }
        var lock: URL { dir.appendingPathComponent("library.lock") }
        var state: URL { dir.appendingPathComponent("state.json") }
    }

    private func fixture() throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Fixture(dir: dir)
    }

    private func snippet(_ name: String, id: UUID = UUID()) -> Snippet {
        Snippet(id: id, name: name, keyword: name, content: "body-\(name)",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }

    private func vaultDocument(kid: String = "k-test") -> VaultDocument {
        VaultDocument(
            kid: kid,
            vaultSalt: "AAAAAAAAAAAAAAAAAAAAAA",
            kdf: VaultKDFParameters(alg: PassphraseKDF.algorithm, iterations: 600_000,
                                    saltP: "AAAAAAAAAAAAAAAAAAAAAA"))
    }

    private func record(_ id: UUID, name: String) -> VaultRecord {
        VaultRecord(
            id: id, name: name, keyword: name, tags: [], isEnabled: true, isPinned: false,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
            hlc: HLC(wallMs: 1, counter: 0, device: "aaaaaaa1"),
            contentHash: "00", sealed: "v1.AAAA.AAAA")
    }

    private func perform<T>(
        _ f: Fixture, body: @escaping (inout LibraryTransaction.Contents) throws -> T
    ) throws -> LibraryTransaction.Outcome<T> {
        try LibraryTransaction.perform(
            libraryURL: f.library, vaultURL: f.vault, stateURL: f.state,
            lockURL: f.lock, temporaryDirectory: f.dir, lockTimeout: 2, body: body)
    }

    // MARK: - The move itself

    @Test func aPromotionWritesBothFilesAndLeavesNoMarker() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let id = UUID()
        try SnippetLibraryCodec.encode([snippet("a", id: id)]).write(to: f.library)
        try SyncStateFile.write(.fresh(), to: f.state, temporaryDirectory: f.dir)

        let outcome = try perform(f) { contents in
            var vault = self.vaultDocument()
            vault.records.append(self.record(id, name: "a"))
            contents.vault = vault
            contents.snippets.removeAll { $0.id == id }
            contents.marker = .promoting(id)
        }

        #expect(outcome.wroteLibrary)
        #expect(outcome.wroteVault)
        #expect(try LibraryWriter.read(from: f.library).snippets.isEmpty)
        #expect(VaultFile.load(from: f.vault).value?.records.map(\.id) == [id])
        #expect(LibraryTransaction.pendingMarker(stateURL: f.state) == .none,
                "a completed move must not leave a marker for reconcile to act on")
    }

    /// The ordering contract. If the library write fails, the vault write must already
    /// have landed and the marker must survive — that is what makes the crash window
    /// produce a duplicate rather than a vanished secret.
    @Test func whenTheLibraryWriteFailsTheVaultWriteHasAlreadyLandedAndTheMarkerRemains() throws {
        let f = try fixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.dir.path)
            try? FileManager.default.removeItem(at: f.dir)
        }
        let id = UUID()
        try SnippetLibraryCodec.encode([snippet("a", id: id)]).write(to: f.library)
        try SyncStateFile.write(.fresh(), to: f.state, temporaryDirectory: f.dir)

        // Stage somewhere writable, but make the destination directory refuse the
        // rename — the closest reachable analogue of dying between the two writes.
        let readOnly = f.dir.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        let blockedLibrary = readOnly.appendingPathComponent("snippets.json")
        try SnippetLibraryCodec.encode([snippet("a", id: id)]).write(to: blockedLibrary)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }

        try #require(getuid() != 0, "meaningless as root")

        #expect(throws: (any Error).self) {
            try LibraryTransaction.perform(
                libraryURL: blockedLibrary, vaultURL: f.vault, stateURL: f.state,
                lockURL: f.lock, temporaryDirectory: f.dir, lockTimeout: 2
            ) { contents in
                var vault = self.vaultDocument()
                vault.records.append(self.record(id, name: "a"))
                contents.vault = vault
                contents.snippets.removeAll { $0.id == id }
                contents.marker = .promoting(id)
            }
        }

        // The secret exists in the vault…
        #expect(VaultFile.load(from: f.vault).value?.records.map(\.id) == [id])
        // …the plaintext copy is still in the library, so nothing was lost…
        #expect(try LibraryWriter.read(from: blockedLibrary).snippets.map(\.id) == [id])
        // …and reconcile is told what was in flight.
        #expect(LibraryTransaction.pendingMarker(stateURL: f.state) == .promoting(id))
    }

    @Test func aTransactionThatChangesNothingWritesNothing() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try SnippetLibraryCodec.encode([snippet("a")]).write(to: f.library)
        try VaultFile.write(vaultDocument(), to: f.vault, temporaryDirectory: f.dir)

        let before = try FileManager.default.attributesOfItem(atPath: f.library.path)[.modificationDate] as? Date
        let outcome = try perform(f) { _ in }
        let after = try FileManager.default.attributesOfItem(atPath: f.library.path)[.modificationDate] as? Date

        #expect(outcome.wroteLibrary == false)
        #expect(outcome.wroteVault == false)
        // Not merely cosmetic: a needless write fires the folder monitor the app
        // watches, and once sync is live it is what makes two devices ping-pong.
        #expect(before == after)
    }

    // MARK: - Compare-and-swap

    @Test func aConcurrentLibraryWriteForcesARetryAndIsFoldedIn() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let mine = snippet("mine")
        let theirs = snippet("theirs")
        try SnippetLibraryCodec.encode([]).write(to: f.library)

        var injected = false
        let outcome = try perform(f) { contents in
            if !injected {
                injected = true
                try? SnippetLibraryCodec.encode([theirs]).write(to: f.library)
            }
            contents.snippets.append(mine)
        }

        #expect(outcome.attempts > 1)
        let names = Set(try LibraryWriter.read(from: f.library).snippets.map(\.name))
        #expect(names == ["mine", "theirs"], "the concurrent record must survive")
    }

    @Test func aConcurrentVaultWriteForcesARetryAndIsFoldedIn() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try SnippetLibraryCodec.encode([]).write(to: f.library)
        try VaultFile.write(vaultDocument(), to: f.vault, temporaryDirectory: f.dir)
        let mineID = UUID(), theirsID = UUID()

        var injected = false
        let outcome = try perform(f) { contents in
            if !injected {
                injected = true
                var theirs = self.vaultDocument()
                theirs.records.append(self.record(theirsID, name: "theirs"))
                try? VaultFile.write(theirs, to: f.vault, temporaryDirectory: f.dir)
            }
            var vault = contents.vault ?? self.vaultDocument()
            vault.records.append(self.record(mineID, name: "mine"))
            contents.vault = vault
        }

        #expect(outcome.attempts > 1)
        let ids = Set(VaultFile.load(from: f.vault).value?.records.map(\.id) ?? [])
        #expect(ids == [mineID, theirsID], "the concurrent secure record must survive")
    }

    // MARK: - Refusals

    /// An unreadable vault must abort the whole transaction, including the library
    /// half. Proceeding would write half a move against a file we cannot see.
    @Test func anUnreadableVaultAbortsWithoutTouchingTheLibrary() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let original = [snippet("a")]
        try SnippetLibraryCodec.encode(original).write(to: f.library)
        try "not json".write(to: f.vault, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try perform(f) { contents in contents.snippets.append(self.snippet("b")) }
        }
        #expect(try LibraryWriter.read(from: f.library).snippets.map(\.name) == ["a"])
        #expect(try String(contentsOf: f.vault, encoding: .utf8) == "not json")
    }

    /// A vanished library is not an empty one — the same distinction the single-file
    /// write path needed, and the same catastrophe if it is got wrong.
    @Test func aVanishedLibraryIsReportedAsMissingToTheBody() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }

        var sawExisted = true
        _ = try perform(f) { contents in
            sawExisted = contents.libraryExisted
            contents.snippets.append(self.snippet("recreated"))
        }
        #expect(sawExisted == false)
        #expect(try LibraryWriter.read(from: f.library).snippets.map(\.name) == ["recreated"])
    }

    // MARK: - Marker semantics

    @Test func theMarkerDistinguishesAnInterruptedPromoteFromAnInterruptedDemote() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try SyncStateFile.write(.fresh(), to: f.state, temporaryDirectory: f.dir)
        try SnippetLibraryCodec.encode([]).write(to: f.library)
        let id = UUID()

        // A marker survives only until the move completes.
        _ = try perform(f) { contents in
            contents.snippets.append(self.snippet("x", id: id))
            contents.marker = .demoting(id)
        }
        #expect(LibraryTransaction.pendingMarker(stateURL: f.state) == .none)

        // And is readable while set, which is what reconcile keys off. Written directly
        // because the only way to leave one behind is to crash.
        var state = SyncState.fresh()
        state.demoting = id
        try SyncStateFile.write(state, to: f.state, temporaryDirectory: f.dir)
        #expect(LibraryTransaction.pendingMarker(stateURL: f.state) == .demoting(id))
    }
}
