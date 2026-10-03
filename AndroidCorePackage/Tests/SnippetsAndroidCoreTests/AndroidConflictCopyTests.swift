import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SnippetsAndroidCore

// Android's side of docs/issues/cloud-account-key/01-concurrent-body-loss.md. Before
// the fix Android preserved a losing body under the snippet-level id
// `conflict|content|updatedAt` with no `conflictCopy.v1` provenance, so a Mac body
// that Android and Linux both preserved became two records (the audit's
// 4388d2c6… and 5d85adc5…). The inputs are the audit's exact envelopes.

private let audit: [Int: SyncEnvelope] = {
    struct Change: Decodable { let sequence: Int; let envelope: String }
    struct File: Decodable { let minimalThree: [Change] }
    var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    while !FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) {
        url = url.deletingLastPathComponent()
    }
    let data = try! Data(contentsOf: url.appendingPathComponent(
        "snippets-linux/tests/fixtures/audit-concurrent-v1.json"))
    let file = try! JSONDecoder().decode(File.self, from: data)
    return Dictionary(uniqueKeysWithValues: file.minimalThree.map {
        ($0.sequence, try! SyncEnvelope.parse(Data($0.envelope.utf8)))
    })
}()

private let keyData = Data(repeating: 21, count: SnippetCrypto.keyByteCount)
private let saltData = Data(repeating: 22, count: 32)
private let sealer = SnippetCryptoSealer(
    keyring: SnippetCrypto.Keyring(libraryKey: SymmetricKey(data: keyData), salt: saltData),
    scopeID: "sync-v1")
private let androidDevice = "d317f015"

private func libraryJSON(_ snippets: [Snippet]) throws -> String {
    String(decoding: try SnippetLibraryCodec.encode(snippets), as: UTF8.self)
}

private func records(_ envelopes: [SyncEnvelope]) throws -> String {
    let sealed = try envelopes.enumerated().map { index, envelope in
        var record = try WireCodec.seal(envelope, using: sealer)
        record.recordVersion = SyncRecordVersion(Data("audit-generation-\(index)".utf8))
        return record
    }
    return String(decoding: try JSONEncoder().encode(sealed), as: UTF8.self)
}

private struct Reconciled {
    let library: [Snippet]
    let records: [WireRecord]
    let offers: [SyncEnvelope]
    let offerRecords: String
}

private func reconcile(local: [Snippet], base: [Snippet], remote: String) throws -> Reconciled {
    let response = reconcileLibrary(
        try libraryJSON(local), try libraryJSON(base), remote,
        keyData.base64EncodedString(), saltData.base64EncodedString(),
        "sync-v1", androidDevice)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    #expect(object["ok"] as? Bool == true, "\(object["error"] ?? "")")
    let value = try #require(object["value"] as? String)
    let payload = try #require(
        JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    let offers = try #require(payload["offers"] as? String)
    let records = try #require(payload["records"] as? String)
    return Reconciled(
        library: try SnippetLibraryCodec.decode(
            Data(try #require(payload["library"] as? String).utf8)),
        records: try JSONDecoder().decode([WireRecord].self, from: Data(records.utf8)),
        offers: try JSONDecoder().decode([WireRecord].self, from: Data(offers.utf8))
            .map { try WireCodec.open($0, using: sealer) },
        offerRecords: offers)
}

/// Android prepared its edit from the verified seed (1-3); the Mac's 4-5 are remote.
private func androidReplay() throws -> (local: [Snippet], base: [Snippet], remote: String) {
    let base = try [1, 2, 3].map { try #require(audit[$0]?.plainSnippet) }
    var race = base[0]
    let published = try #require(audit[7]?.plainSnippet)
    race.content = published.content
    race.updatedAt = published.updatedAt
    var fields = base[1]
    fields.isEnabled = false
    fields.updatedAt = try #require(audit[8]?.plainSnippet).updatedAt
    let remote = try records([audit[4]!, audit[5]!, audit[3]!])
    return ([race, fields, base[2]], base, remote)
}

@Test func androidPreservesAPublishedLoserUnderTheCanonicalCrossClientIdentity() throws {
    let replay = try androidReplay()
    let result = try reconcile(local: replay.local, base: replay.base, remote: replay.remote)

    let copies = result.offers.filter { SyncMerge.conflictCopyProvenance(in: $0) != nil }
    #expect(copies.count == 1)
    let copy = try #require(copies.first)
    // Byte-for-byte the copy Linux minted for the same Mac envelope (sequence 9).
    #expect(try copy.canonicalData() == audit[9]!.canonicalData())
    #expect(SyncMerge.hasValidConflictCopyIdentity(copy))
    #expect(result.library.filter { $0.tags.contains("conflict") }.map(\.id) == [copy.id])
    #expect(!result.library.contains { $0.id.uuidString.lowercased().hasPrefix("4388d2c6") })

    // The merged source keeps Android's body and the Mac's independent rename.
    let source = try #require(result.offers.first { $0.id == audit[1]!.id })
    #expect(source.fields.map { String(decoding: $0.content, as: UTF8.self) }
            == "audit-concurrent-android")
    let mergedFields = try #require(result.offers.first { $0.id == audit[2]!.id })
    #expect(mergedFields.fields?.name == "audit-name-macos")
    #expect(mergedFields.fields?.isEnabled == false)
}

@Test func androidDeduplicatesWithACopyAnotherDeviceAlreadyUploaded() throws {
    let replay = try androidReplay()
    // Linux preserved the same Mac body first (sequence 9).
    let remote = try records([audit[4]!, audit[5]!, audit[3]!, audit[9]!])
    let result = try reconcile(local: replay.local, base: replay.base, remote: remote)
    #expect(!result.offers.contains { SyncMerge.conflictCopyProvenance(in: $0) != nil },
            "the identical remote copy must not be offered again")
    #expect(result.library.filter { $0.tags.contains("conflict") }.count == 1)
}

@Test func repeatedReconciliationBeforeTheBaseAdvancesMintsNoSecondCopy() throws {
    let replay = try androidReplay()
    let first = try reconcile(local: replay.local, base: replay.base, remote: replay.remote)
    let copyID = try #require(
        first.offers.first { SyncMerge.conflictCopyProvenance(in: $0) != nil }?.id)

    // The copy was accepted; the source lost its CAS race, so Kotlin keeps the old base
    // and reconciles the merged library again against the refreshed cache.
    var cache = try JSONDecoder().decode([WireRecord].self, from: Data(replay.remote.utf8))
    cache += first.records.filter { $0.id == copyID }
    let second = try reconcile(
        local: first.library, base: replay.base,
        remote: String(decoding: try JSONEncoder().encode(cache), as: UTF8.self))
    #expect(!second.offers.contains { $0.id != audit[1]!.id && $0.id != audit[2]!.id })
    #expect(second.library.filter { $0.tags.contains("conflict") }.map(\.id) == [copyID])
}

@Test func androidsOwnLosingEditIsCanonicalAndStable() throws {
    let base = try [1, 2, 3].map { try #require(audit[$0]?.plainSnippet) }
    var race = base[0]
    race.content = "audit-concurrent-android"
    race.updatedAt = try #require(audit[7]?.plainSnippet).updatedAt
    // Linux's later published body wins by modification time.
    let remote = try records([audit[11]!, audit[2]!, audit[3]!])
    let local = [race, base[1], base[2]]
    let first = try reconcile(local: local, base: base, remote: remote)
    let copy = try #require(first.offers.first { SyncMerge.conflictCopyProvenance(in: $0) != nil })
    #expect(SyncMerge.hasValidConflictCopyIdentity(copy))
    #expect(copy.fields.map { String(decoding: $0.content, as: UTF8.self) }
            == "audit-concurrent-android")
    #expect(copy.fields?.isEnabled == false && copy.fields?.keyword == "")
    let again = try reconcile(local: local, base: base, remote: remote)
    #expect(try again.offers.first { $0.id == copy.id }?.canonicalData() == copy.canonicalData())
}

@Test func editingAPreservedCopyKeepsItsProvenance() throws {
    let copy = try #require(audit[9])
    var renamed = try #require(copy.plainSnippet)
    let remote = try records([copy])
    renamed.name = "kept Mac version"
    renamed.updatedAt = renamed.updatedAt.addingTimeInterval(60)
    let result = try reconcile(
        local: [renamed], base: [try #require(copy.plainSnippet)], remote: remote)
    let offered = try #require(result.offers.first { $0.id == copy.id })
    #expect(offered.fields?.name == "kept Mac version")
    #expect(offered.x[SyncMerge.plainConflictCopyExtensionKey]
            == copy.x[SyncMerge.plainConflictCopyExtensionKey])
    #expect(SyncMerge.hasValidConflictCopyIdentity(offered))
}
