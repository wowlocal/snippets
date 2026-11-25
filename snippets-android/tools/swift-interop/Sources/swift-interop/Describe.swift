import CryptoKit
import Foundation
@testable import SnippetsCore

// Stable JSON descriptions of Swift model values. Dictionaries are always walked in
// canonical (UTF-8 byte) key order: Swift's own iteration order is seeded per process.

func sortedByUTF8<V>(_ dictionary: [String: V]) -> [(String, V)] {
    dictionary.map { ($0.key, $0.value) }
        .sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
}

/// A `CanonicalJSON.Value` as a typed tree a reader can rebuild without guessing
/// whether `1` was an int or a double, or whether a string was bytes.
func canonicalTree(_ value: CanonicalJSON.Value) -> J {
    switch value {
    case .null: return .obj([("t", .str("null"))])
    case .bool(let flag): return .obj([("t", .str("bool")), ("v", .bool(flag))])
    case .int(let number): return .obj([("t", .str("int")), ("v", .str(String(number)))])
    case .double(let number):
        return .obj([
            ("t", .str("double")),
            ("bits", .str(String(format: "%016llx", number.bitPattern))),
            ("swift", .str(number.description)),
        ])
    case .string(let text):
        return .obj([("t", .str("string")), ("v", .str(text)), ("utf8Hex", .hex(Data(text.utf8)))])
    case .utf8(let bytes):
        return .obj([("t", .str("utf8")), ("hex", .hex(bytes))])
    case .array(let elements):
        return .obj([("t", .str("array")), ("v", .arr(elements.map(canonicalTree)))])
    case .object(let members):
        return .obj([("t", .str("object")), ("v", .arr(sortedByUTF8(members).map { key, member in
            .obj([("k", .str(key)), ("kHex", .hex(Data(key.utf8))), ("v", canonicalTree(member))])
        }))])
    }
}

func jsonValueTree(_ value: JSONValue) -> J {
    switch value {
    case .null: return .obj([("t", .str("null"))])
    case .bool(let flag): return .obj([("t", .str("bool")), ("v", .bool(flag))])
    case .integer(let number): return .obj([("t", .str("integer")), ("v", .str(String(number)))])
    case .double(let number):
        return .obj([
            ("t", .str("double")),
            ("bits", .str(String(format: "%016llx", number.bitPattern))),
            ("swift", .str(number.description)),
        ])
    case .string(let text): return .obj([("t", .str("string")), ("v", .str(text))])
    case .array(let elements): return .obj([("t", .str("array")), ("v", .arr(elements.map(jsonValueTree)))])
    case .object(let members):
        return .obj([("t", .str("object")), ("v", .arr(sortedByUTF8(members).map { key, member in
            .obj([("k", .str(key)), ("v", jsonValueTree(member))])
        }))])
    }
}

func bagJ(_ bag: [String: JSONValue]) -> J {
    .arr(sortedByUTF8(bag).map { key, member in .obj([("k", .str(key)), ("v", jsonValueTree(member))]) })
}

func snippetJ(_ snippet: Snippet) -> J {
    .obj([
        ("id", .str(lower(snippet.id))),
        ("name", .str(snippet.name)),
        ("keyword", .str(snippet.keyword)),
        ("content", .str(snippet.content)),
        ("contentUtf8Hex", .hex(Data(snippet.content.utf8))),
        ("tags", .strings(snippet.tags)),
        ("isEnabled", .bool(snippet.isEnabled)),
        ("isPinned", .bool(snippet.isPinned)),
        ("createdAt", .date(snippet.createdAt)),
        ("updatedAt", .date(snippet.updatedAt)),
    ])
}

func fieldsJ(_ fields: SyncEnvelope.Fields) -> J {
    .obj([
        ("name", .str(fields.name)),
        ("keyword", .str(fields.keyword)),
        ("contentHex", .hex(fields.content)),
        ("contentText", utf8Text(fields.content)),
        ("tags", .strings(fields.tags)),
        ("isEnabled", .bool(fields.isEnabled)),
        ("isPinned", .bool(fields.isPinned)),
        ("createdAt", .date(fields.createdAt)),
        ("updatedAt", .date(fields.updatedAt)),
    ])
}

/// Every value of an envelope plus the three byte strings the protocol derives from it.
func envelopeJ(_ envelope: SyncEnvelope) throws -> J {
    let canonical = try envelope.canonicalData()
    let preimage = try CanonicalJSON.data(envelope.canonicalValue(includingHash: false))
    let hash = try envelope.envelopeHash()
    return .obj([
        ("schemaVersion", .n(envelope.schemaVersion)),
        ("id", .str(lower(envelope.id))),
        ("hlc", .str(envelope.hlc.string)),
        ("origin", .str(envelope.origin)),
        ("secure", .bool(envelope.secure)),
        ("deleted", .bool(envelope.deleted)),
        ("fields", envelope.fields.map(fieldsJ) ?? .null),
        ("x", canonicalTree(.object(envelope.x))),
        ("xCanonical", .str(try CanonicalJSON.string(.object(envelope.x)))),
        ("contentHash", .opt(envelope.contentHash)),
        ("hashPreimageText", utf8Text(preimage)),
        ("hashPreimageHex", .hex(preimage)),
        ("envelopeHash", .str(hash)),
        ("rev", .str(String(hash.prefix(32)))),
        ("canonicalText", utf8Text(canonical)),
        ("canonicalHex", .hex(canonical)),
    ])
}

func vaultRecordJ(_ record: VaultRecord) -> J {
    .obj([
        ("id", .str(lower(record.id))),
        ("name", .str(record.name)),
        ("keyword", .str(record.keyword)),
        ("tags", .strings(record.tags)),
        ("isEnabled", .bool(record.isEnabled)),
        ("isPinned", .bool(record.isPinned)),
        ("createdAt", .date(record.createdAt)),
        ("updatedAt", .date(record.updatedAt)),
        ("hlc", .str(record.hlc.string)),
        ("contentHash", .str(record.contentHash)),
        ("sealed", .str(record.sealed)),
        ("x", bagJ(record.x)),
    ])
}

func vaultDocumentJ(_ document: VaultDocument) -> J {
    .obj([
        ("schemaVersion", .n(document.schemaVersion)),
        ("kid", .str(document.kid)),
        ("vaultSalt", .str(document.vaultSalt)),
        ("kdf", .obj([
            ("alg", .str(document.kdf.alg)),
            ("iterations", .n(document.kdf.iterations)),
            ("saltP", .str(document.kdf.saltP)),
            ("x", bagJ(document.kdf.x)),
        ])),
        ("wrapPass", .opt(document.wrapPass)),
        ("wrapRecovery", .opt(document.wrapRecovery)),
        ("wrapCLI", .opt(document.wrapCLI)),
        ("x", bagJ(document.x)),
        ("records", .arr(document.records.map(vaultRecordJ))),
    ])
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha1Hex(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
