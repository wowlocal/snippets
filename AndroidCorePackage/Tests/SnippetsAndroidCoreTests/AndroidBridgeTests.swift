import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SnippetsAndroidCore

@Test func bridgeCrudUsesFrozenLibraryShape() throws {
    let created = upsertSnippet("[]", "00000000-0000-0000-0000-000000000001",
                                "Greeting", " hello world ", "Hello", "[\"work\"]",
                                true, false)
    let response = try #require(created.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    let value = try #require(object["value"] as? String)
    let snippets = try SnippetLibraryCodec.decode(Data(value.utf8))
    #expect(snippets.count == 1)
    #expect(snippets[0].keyword == "hello-world")
}

@Test func reconcileRoundTripsEncryptedWireRecords() throws {
    let library = upsertSnippet("[]", "00000000-0000-0000-0000-000000000002",
                                "Greeting", "hi", "Hello", "[]", true, false)
    let value = try bridgeValue(library)
    let key = Data(repeating: 7, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 9, count: 32).base64EncodedString()

    let first = reconcileLibrary(value, "[]", "[]", key, salt, "sync-v1", "01234567")
    let firstPayload = try bridgeValue(first)
    let firstObject = try #require(
        JSONSerialization.jsonObject(with: Data(firstPayload.utf8)) as? [String: Any])
    let records = try #require(firstObject["records"] as? String)

    let second = reconcileLibrary(value, value, records, key, salt, "sync-v1", "89abcdef")
    let secondPayload = try bridgeValue(second)
    let secondObject = try #require(
        JSONSerialization.jsonObject(with: Data(secondPayload.utf8)) as? [String: Any])
    #expect(secondObject["offers"] as? String == "[]")
    let secondRecords = try #require(secondObject["records"] as? String)
    #expect(try JSONDecoder().decode([WireRecord].self, from: Data(secondRecords.utf8))
            == JSONDecoder().decode([WireRecord].self, from: Data(records.utf8)),
            "switching providers must preserve the exact encrypted WireRecord fields")
}

@Test func reconcilePreservesOpaqueSecureRecordsWithoutOfferingADeletion() throws {
    let keyData = Data(repeating: 3, count: SnippetCrypto.keyByteCount)
    let saltData = Data(repeating: 5, count: 32)
    let key = keyData.base64EncodedString()
    let salt = saltData.base64EncodedString()
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: keyData), salt: saltData),
        scopeID: "sync-v1")
    let envelope = SyncEnvelope.secureRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Opaque", keyword: "secret", plaintext: Data("private".utf8),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
        hlc: HLC(wallMs: 1_700_000_001_000, counter: 0, device: "01234567"),
        origin: "01234567")
    var record = try WireCodec.seal(envelope, using: sealer)
    record.recordVersion = SyncRecordVersion(Data("server-cas-7".utf8))
    let records = String(decoding: try JSONEncoder().encode([record]), as: UTF8.self)

    let response = reconcileLibrary("[]", "[]", records, key, salt, "sync-v1", "89abcdef")
    let payload = try bridgeValue(response)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

    let library = try #require(object["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(library.utf8)).isEmpty)
    #expect(object["offers"] as? String == "[]")
    let preservedRecords = try #require(object["records"] as? String)
    #expect(try JSONDecoder().decode([WireRecord].self, from: Data(preservedRecords.utf8))
            == [record])
}

private func bridgeValue(_ response: String) throws -> String {
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    return try #require(object["value"] as? String)
}
