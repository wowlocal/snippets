import Foundation
import Testing

@testable import SnippetsCore

/// Canonical conflict-copy identity shared with Linux (`merge::plain_copy`) and
/// Android (`AndroidBridge` reconciliation). See docs/cloud-sync.md,
/// "Conflict-copy identity". The vectors are real Linux outputs from the
/// 2026-10-03 audit, so equality here is byte-for-byte cross-client agreement.
@Suite("Cross-client conflict-copy vectors")
struct SyncConflictCopyVectorTests {
    private struct Vector: Decodable {
        let name: String
        let source: String
        let copy: String
        let copyID: String
        let fingerprint: String
    }

    private static func vectors() throws -> [Vector] {
        struct File: Decodable { let vectors: [Vector] }
        // Resolve through the package's symlinked test directory to the repository.
        var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        while !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("AGENTS.md").path) {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { throw CocoaError(.fileNoSuchFile) }
            url = parent
        }
        let data = try Data(contentsOf: url.appendingPathComponent(
            "snippets-linux/tests/fixtures/conflict-copy-v1.json"))
        return try JSONDecoder().decode(File.self, from: data).vectors
    }

    @Test func plainCopiesReproduceTheLinuxBytesExactly() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 2)
        for vector in vectors {
            let source = try SyncEnvelope.parse(Data(vector.source.utf8))
            let expected = try SyncEnvelope.parse(Data(vector.copy.utf8))
            let copy = try SyncMerge.makePlainContentConflictCopy(from: source)
            #expect(try copy.canonicalData() == expected.canonicalData(), "\(vector.name)")
            #expect(copy.id.uuidString.lowercased() == vector.copyID)
            #expect(SyncMerge.conflictCopyProvenance(in: copy)?.fingerprint == vector.fingerprint)
            #expect(SyncMerge.hasValidConflictCopyIdentity(copy))
        }
    }

    @Test func theEnvelopeMergeMintsTheSameCopyFromEitherSide() throws {
        let vector = try #require(try Self.vectors().first)
        let loser = try SyncEnvelope.parse(Data(vector.source.utf8))
        let snippet = try #require(loser.plainSnippet)
        var newer = snippet
        newer.content = "a newer concurrent body"
        let winner = SyncEnvelope.plain(
            newer,
            hlc: HLC(wallMs: loser.hlc.wallMs + 1_000, counter: 0, device: "0a0b0c0d"),
            origin: "0a0b0c0d")
        var original = snippet
        original.content = "the common ancestor"
        let ancestor = SyncEnvelope.plain(
            original, hlc: HLC(wallMs: 1, counter: 0, device: "0a0b0c0d"),
            origin: "0a0b0c0d")
        let asLocal = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor, local: loser, remote: winner)
        let asRemote = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor, local: winner, remote: loser)
        #expect(asLocal.conflictCopies.map(\.id) == [try #require(UUID(uuidString: vector.copyID))])
        #expect(try asLocal.conflictCopies.map { try $0.canonicalData() }
            == asRemote.conflictCopies.map { try $0.canonicalData() })
    }
}
