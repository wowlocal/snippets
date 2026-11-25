import CryptoKit
import Foundation
@testable import SnippetsCore

// V13–V19: secure conflict variant, vault file, encrypted backup, Git recovery
// envelope, Git key-store account, K_sync split, portable key bundle.

enum CryptoVectorsC {

    // MARK: V13

    static func secureEnvelope(
        id: UUID, name: String, body: Data, nonce: UInt8, hlc: HLC, origin: String,
        tags: [String] = ["home"], updatedAt: Date = Fixture.updated
    ) throws -> SyncEnvelope {
        let sealed = try CryptoVectorsB.sealedSecureBody(id: id, body: body, nonce: nonce)
        return SyncEnvelope.secureRecord(
            id: id, name: name, keyword: "wifi", plaintext: Data(sealed.utf8), tags: tags,
            isEnabled: true, isPinned: true, createdAt: Fixture.created, updatedAt: updatedAt,
            hlc: hlc, origin: origin,
            x: [
                SyncEnvelope.vaultContentHashExtensionKey:
                    .string(SnippetCrypto.contentHash(of: body, keyring: Fixture.vaultKeyring)),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(Fixture.kid),
            ])
    }

    static func v13() throws -> VectorFile {
        var cases: [J] = []
        let id = Fixture.uuidB
        let baseHLC = HLC(wallMs: 0x019f_ace3_0000, counter: 0, device: "aabbccdd")
        let localHLC = HLC(wallMs: 0x019f_ace3_39f4, counter: 3, device: "aabbccdd")
        let remoteHLC = HLC(wallMs: 0x019f_ace3_4000, counter: 0, device: "0badcafe")

        let scenarios: [(String, String, [String], Date)] = [
            ("named-loser", "Wi-Fi password", ["home"], Fixture.updated),
            ("unnamed-loser-with-conflict-tag", "", ["Conflict", "home"], Date(timeIntervalSinceReferenceDate: 120)),
        ]
        for (label, loserName, loserTags, loserUpdated) in scenarios {
            let base = try secureEnvelope(
                id: id, name: "Wi-Fi password", body: Data("base secret".utf8), nonce: 0x51,
                hlc: baseHLC, origin: "aabbccdd")
            let loserBody = Data("local secret ☕".utf8)
            let local = try secureEnvelope(
                id: id, name: loserName, body: loserBody, nonce: 0x52, hlc: localHLC,
                origin: "aabbccdd", tags: loserTags, updatedAt: loserUpdated)
            let remote = try secureEnvelope(
                id: id, name: "Wi-Fi password", body: Data("remote secret".utf8), nonce: 0x53,
                hlc: remoteHLC, origin: "0badcafe")

            let outcome = try SyncMerge.mergeEnvelopeOutcome(base: base, local: local, remote: remote)
            let mirrored = try SyncMerge.mergeEnvelopeOutcome(base: base, local: remote, remote: local)
            guard let survivor = outcome.survivor else { throw InteropFailure("V13 no survivor") }
            try require(mirrored.survivor == survivor, "V13 \(label) merge is symmetric")
            try require(outcome.conflictCopies.isEmpty, "V13 \(label) secure loser makes no plain copy")
            let variants = try SyncMerge.secureContentConflictVariants(in: survivor)
            try require(variants.count == 1, "V13 \(label) one variant")
            let variant = variants[0]
            guard case .object(let value) = survivor.x[variant.extensionKey]! else {
                throw InteropFailure("V13 variant is not an object")
            }
            var snapshot = value
            snapshot["copyID"] = nil
            let preimage = try CanonicalJSON.data(.object(snapshot))
            try require(sha256Hex(preimage) == variant.fingerprint, "V13 \(label) fingerprint preimage")
            let uuidName = "sync-content-conflict-v1|\(variant.fingerprint)"
            try require(
                SyncMerge.deterministicUUID(namespace: id, name: uuidName) == variant.copyID,
                "V13 \(label) copy id")

            let result = try SyncSecureConflictMaterializer.materialize(
                envelope: survivor, keyring: Fixture.vaultKeyring, vaultKID: Fixture.kid,
                existingSnippets: [], existingRecords: [])
            try require(result.records.count == 1 && result.materializedIDs == [variant.copyID], "V13 \(label) materialised")
            let copy = result.records[0]
            let reopened = try SnippetCrypto.open(
                copy.sealed, for: SnippetCrypto.RecordContext(scopeID: Fixture.kid, recordID: copy.id),
                keyring: Fixture.vaultKeyring)
            try require(reopened == loserBody, "V13 \(label) copy reseals the loser body")
            var copyMembers: [(String, J)] = []
            if case .obj(let members) = vaultRecordJ(copy) {
                // The resealed body draws a system nonce (no seam); it is checked above
                // and left out so the file stays deterministic.
                copyMembers = members.filter { $0.0 != "sealed" }
            }

            cases.append(vcase(label, [
                ("kind", .str("secure-conflict")),
                ("vaultKeyHex", .hex(Fixture.libraryKey)),
                ("vaultSaltHex", .hex(Fixture.vaultSalt)),
                ("kid", .str(Fixture.kid)),
                ("base", try envelopeJ(base)),
                ("local", try envelopeJ(local)),
                ("remote", try envelopeJ(remote)),
                ("loser", .str("local")),
                ("loserPlaintextHex", .hex(loserBody)),
                ("survivor", try envelopeJ(survivor)),
                ("variant", .obj([
                    ("extensionKey", .str(variant.extensionKey)),
                    ("fingerprint", .str(variant.fingerprint)),
                    ("fingerprintPreimageText", utf8Text(preimage)),
                    ("fingerprintPreimageHex", .hex(preimage)),
                    ("copyIDNamespace", .str(lower(id))),
                    ("copyIDName", .str(uuidName)),
                    ("copyID", .str(lower(variant.copyID))),
                    ("valueCanonical", .str(try CanonicalJSON.string(.object(value)))),
                ])),
                ("materializedCopy", .obj(copyMembers + [
                    ("sealedContext", .obj([
                        ("scopeID", .str(Fixture.kid)), ("recordID", .str(lower(copy.id))), ("isDeleted", .bool(false)),
                    ])),
                    ("sealedOpensToHex", .hex(reopened)),
                ])),
            ]))
        }

        let names: [(UUID, String)] = [
            (Fixture.uuidA, ""),
            (Fixture.uuidA, "sync-content-conflict-v1|" + String(repeating: "0", count: 64)),
            (Fixture.uuidB, "sync-content-conflict-v1|" + String(repeating: "ab", count: 32)),
            (UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, "www.example.com"),
            (Fixture.uuidD, "ünïcode ☕"),
        ]
        for (index, (namespace, name)) in names.enumerated() {
            cases.append(vcase("deterministic-uuid-\(index)", [
                ("kind", .str("deterministic-uuid")),
                ("namespace", .str(lower(namespace))),
                ("uuidName", .text(name)),
                ("uuid", .str(lower(SyncMerge.deterministicUUID(namespace: namespace, name: name)))),
            ]))
        }
        return VectorFile(
            name: "V13-secure-conflict",
            pins: "SyncMerge secure content-conflict variant (`contentConflict.v1.<fingerprint>` key and value, fingerprint, copyID), SyncMerge.deterministicUUID, and SyncSecureConflictMaterializer copy metadata (brief 02 §4.3)",
            notes: [
                "fingerprint = hex(SHA-256(canonical(value without copyID))). copyID = deterministicUUID(namespace: source id, name: \"sync-content-conflict-v1|\" + fingerprint): SHA-1 over uuid16(namespace) ‖ name, version nibble 5.",
                "deterministic-uuid-3 is RFC 4122's DNS namespace with www.example.com (2ed6657d-e927-568b-95e1-2665a8aea6a2).",
                "materializedCopy.sealed is omitted: SyncSecureConflictMaterializer reseals with a system nonce and has no seam. The tool opens it under (kid, copyID, live) and records the plaintext instead.",
            ],
            cases: cases)
    }

    // MARK: V14

    static func vaultRecord(
        id: UUID, name: String, keyword: String, body: Data, nonce: UInt8, tags: [String],
        isEnabled: Bool, isPinned: Bool, created: Date, updated: Date, hlc: HLC,
        x: [String: JSONValue] = [:]
    ) throws -> VaultRecord {
        VaultRecord(
            id: id, name: name, keyword: keyword, tags: tags, isEnabled: isEnabled, isPinned: isPinned,
            createdAt: created, updatedAt: updated, hlc: hlc,
            contentHash: SnippetCrypto.contentHash(of: body, keyring: Fixture.vaultKeyring),
            sealed: try CryptoVectorsB.sealedSecureBody(id: id, body: body, nonce: nonce), x: x)
    }

    static func vaultDocument(passthrough: Bool) throws -> VaultDocument {
        let wrapRecovery = try KeyWrap.wrap(
            SymmetricKey(data: Fixture.libraryKey), under: Fixture.recoverySecret, purpose: .recovery,
            kid: Fixture.kid, salt: Fixture.vaultSalt, nonces: fixedNonce(0x77))
        let first = try vaultRecord(
            id: Fixture.uuidB, name: "Wi-Fi password", keyword: "wifi", body: CryptoVectorsB.secureBody,
            nonce: 0x44, tags: ["home", "Ünïcode ☕"], isEnabled: true, isPinned: true,
            created: Fixture.created, updated: Date(timeIntervalSinceReferenceDate: 812_578_800.123),
            hlc: CryptoVectorsB.hlc,
            x: passthrough ? [
                "futureRecord": .array([.integer(1), .string("two"), .null]),
                "conflictCopy.v1": .object([
                    "version": .integer(1),
                    "sourceID": .string(lower(Fixture.uuidA)),
                    "fingerprint": .string(String(repeating: "ab", count: 32)),
                ]),
            ] : [:])
        let second = try vaultRecord(
            id: Fixture.uuidC, name: "", keyword: "", body: Data(), nonce: 0x45, tags: [],
            isEnabled: false, isPinned: false,
            created: Date(timeIntervalSinceReferenceDate: 0), updated: Date(timeIntervalSinceReferenceDate: 0),
            hlc: HLC(wallMs: 978_307_200_000, counter: 0, device: "00000000"))
        return VaultDocument(
            kid: Fixture.kid,
            vaultSalt: SnippetCrypto.base64URL(Fixture.vaultSalt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm, iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(Data.filled(0x55, 16)),
                x: passthrough ? ["futureKdf": .integer(7)] : [:]),
            wrapPass: nil, wrapRecovery: wrapRecovery, wrapCLI: nil,
            x: passthrough ? [
                "futureTop": .object([
                    "d": .double(12.5), "f": .bool(false), "i": .integer(600_000), "n": .null,
                    "s": .string("1"), "t": .bool(true), "slash": .string("a/b"),
                ]),
                VaultDocument.localConflictInstallReceiptsKey: .object([
                    String(repeating: "cd", count: 32): .string(lower(Fixture.uuidD)),
                ]),
            ] : [:],
            records: [first, second])
    }

    static func v14() throws -> VectorFile {
        var cases: [J] = []
        for (name, passthrough) in [("document-with-passthrough", true), ("document-plain", false)] {
            let document = try vaultDocument(passthrough: passthrough)
            let data = try VaultFile.encode(document)
            // Not `decode(data) == document`: a millisecond ISO-8601 round trip through
            // Foundation does not return the same double (see the timestamp cases).
            let decoded = try VaultFile.decode(data)
            try require(try VaultFile.encode(decoded) == data, "V14 \(name) is a fixed point")
            try require(try VaultFile.decode(try VaultFile.encode(decoded)) == decoded, "V14 \(name) decoded round trip")
            cases.append(vcase(name, [
                ("kind", .str("encode")),
                ("vaultKeyHex", .hex(Fixture.libraryKey)),
                ("recoverySecretHex", .hex(Fixture.recoverySecret)),
                ("document", vaultDocumentJ(document)),
                ("fileText", utf8Text(data)),
                ("fileHex", .hex(data)),
                ("decodedDocument", vaultDocumentJ(decoded)),
            ]))
        }

        let timestamps = VaultTimestampCodec()
        let instants: [Double] = [
            0, 0.5, 0.001, 0.0004, 0.0005, 0.0006, 0.9994, 0.9995, 0.9996, 0.999999, 1.2345,
            807_004_800.5, 812_578_800.123, 812_578_800.123456, 812_578_800.1229999, 812_578_800.1235,
            812_578_800.0005, 812_578_799.9995, -0.001, -0.5, -1.5, -978_307_200, -978_307_200.001,
            -63_114_076_800, 63_113_904_000, 1e9 + 0.1, 1e9 + 0.7,
        ]
        // Empirical model of Foundation's ISO8601DateFormatter with fractional seconds,
        // asserted for every case below: it goes through whole milliseconds since 1970
        // held in a double.
        //   format: ms = round-half-away((t + 978307200.0) * 1000.0)
        //   parse:  t  = Double(ms) / 1000.0 - 978307200.0   (digits past the third are dropped)
        func modelMilliseconds(_ value: Double) -> Double { ((value + 978_307_200.0) * 1000.0).rounded() }
        func modelDate(_ milliseconds: Double) -> Double { milliseconds / 1000.0 - 978_307_200.0 }
        for value in instants {
            let text = timestamps.string(from: Date(timeIntervalSinceReferenceDate: value))
            guard let back = timestamps.date(from: text) else { throw InteropFailure("V14 timestamp \(text) does not parse") }
            let milliseconds = modelMilliseconds(value)
            try require(
                modelDate(milliseconds).bitPattern == back.timeIntervalSinceReferenceDate.bitPattern,
                "V14 timestamp model for \(value): \(modelDate(milliseconds)) vs \(back.timeIntervalSinceReferenceDate)")
            cases.append(vcase("timestamp-format-\(String(format: "%016llx", value.bitPattern))", [
                ("kind", .str("timestamp-format")),
                ("date", .double(value)),
                ("text", .str(text)),
                ("epochMilliseconds", .str(String(Int64(milliseconds)))),
                ("parsedBack", .date(back)),
            ]))
        }
        let texts = [
            "2026-10-01T20:20:00.123Z", "2026-10-01T20:20:00.1Z", "2026-10-01T20:20:00.12Z",
            "2026-10-01T20:20:00.1234Z", "2026-10-01T20:20:00.123456Z", "2026-10-01T20:20:00.999Z",
            "2026-10-01T20:20:00.9999Z", "2026-10-01T20:20:00.000Z", "2026-10-01T20:20:00Z",
            "2026-10-01T20:20:00+00:00", "2026-10-01T22:20:00.123+02:00", "2026-10-01T20:20:00.123+0000",
            "2026-10-01T20:20:00.123z", "2026-10-01t20:20:00.123Z", "2026-10-01 20:20:00.123Z",
            "2026-10-01T20:20:00.123", "2026-10-01T20:20:00", "2026-10-01", "2026-10-01T20:20Z",
            "2026-10-01T20:20:60Z", "2026-02-30T00:00:00Z", "2024-02-29T23:59:59.999Z",
            "2001-01-01T00:00:00.000Z", "1970-01-01T00:00:00.000Z", "0001-01-01T00:00:00.000Z",
            "1969-12-31T23:59:59.999Z", "9999-12-31T23:59:59.999Z", " 2026-10-01T20:20:00.123Z",
            "2026-10-01T20:20:00,123Z", "",
        ]
        for (index, text) in texts.enumerated() {
            cases.append(vcase("timestamp-parse-\(index)", [
                ("kind", .str("timestamp-parse")),
                ("text", .str(text)),
                ("date", timestamps.date(from: text).map { .date($0) } ?? .null),
            ]))
        }

        let empty = VaultDocument(
            kid: Fixture.kid, vaultSalt: SnippetCrypto.base64URL(Fixture.vaultSalt),
            kdf: VaultKDFParameters(alg: PassphraseKDF.algorithm, iterations: 600_000, saltP: "VVVVVVVVVVVVVVVVVVVVVQ"))
        let emptyData = try VaultFile.encode(empty)
        cases.append(vcase("document-empty-all-wraps-null", [
            ("kind", .str("encode")),
            ("document", vaultDocumentJ(empty)),
            ("fileText", utf8Text(emptyData)),
            ("fileHex", .hex(emptyData)),
        ]))

        let sealed = try CryptoVectorsB.sealedSecureBody(id: Fixture.uuidB)
        func file(_ records: String, extra: String = "", wraps: String = "\"wrapPass\":null,\"wrapRecovery\":null,\"wrapCLI\":null,") -> Data {
            Data(("{\"schemaVersion\":1,\"kid\":\"\(Fixture.kid)\",\"vaultSalt\":\"IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI\","
                + "\"kdf\":{\"alg\":\"pbkdf2-hmac-sha512\",\"iterations\":600000,\"saltP\":\"VVVVVVVVVVVVVVVVVVVVVQ\"},"
                + wraps + extra + "\"records\":[\(records)]}").utf8)
        }
        let id = "\"id\":\"\(lower(Fixture.uuidB))\""
        let decodes: [(String, Data)] = [
            ("record-only-id-and-sealed", file("{\(id),\"sealed\":\"\(sealed)\"}")),
            ("record-uppercase-id", file("{\"id\":\"\(Fixture.uuidB.uuidString)\",\"sealed\":\"\(sealed)\"}")),
            ("record-whole-second-timestamps", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"createdAt\":\"2026-07-29T08:00:00Z\",\"updatedAt\":\"2026-10-01T20:20:00Z\"}")),
            ("record-fractional-timestamps", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"createdAt\":\"2026-07-29T08:00:00.500Z\",\"updatedAt\":\"2026-10-01T20:20:00.123Z\"}")),
            ("record-microsecond-timestamp", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"createdAt\":\"2026-07-29T08:00:00.123456Z\",\"updatedAt\":\"2026-07-29T08:00:00.1Z\"}")),
            ("record-offset-timestamp", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"createdAt\":\"2026-07-29T10:00:00+02:00\",\"updatedAt\":\"2026-07-29T10:00:00.250+02:00\"}")),
            ("record-numeric-timestamps", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"createdAt\":807004800.5,\"updatedAt\":812578800.123456}")),
            ("record-only-updatedAt", file("{\(id),\"sealed\":\"\(sealed)\",\"updatedAt\":\"2026-10-01T20:20:00.123Z\"}")),
            ("record-only-createdAt", file("{\(id),\"sealed\":\"\(sealed)\",\"createdAt\":\"2026-07-29T08:00:00.500Z\"}")),
            ("record-wrong-typed-fields", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"name\":7,\"keyword\":null,\"tags\":\"home\",\"isEnabled\":\"no\",\"isPinned\":1,\"contentHash\":[],\"hlc\":\"nonsense\"}")),
            ("record-tags-not-normalised", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"tags\":[\"  Home \",\"home\",\"\",\"two   words\",\"HÖME\",\"höme\"]}")),
            ("record-hlc-kept", file("{\(id),\"sealed\":\"\(sealed)\",\"hlc\":\"019face339f4-0003-aabbccdd\"}")),
            ("record-hlc-uppercase-falls-back", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"hlc\":\"019FACE339F4-0003-AABBCCDD\",\"updatedAt\":\"2026-10-01T20:20:00.123Z\"}")),
            ("record-passthrough-values", file(
                "{\(id),\"sealed\":\"\(sealed)\",\"future\":{\"d\":12.5,\"f\":false,\"i\":600000,\"n\":null,\"s\":\"1\",\"t\":true,\"one\":1.0,\"big\":18446744073709551616,\"neg\":-3}}")),
            ("record-missing-sealed", file("{\(id)}")),
            ("record-missing-id", file("{\"sealed\":\"\(sealed)\"}")),
            ("record-id-not-uuid", file("{\"id\":\"nope\",\"sealed\":\"\(sealed)\"}")),
            ("wraps-absent", file("", wraps: "")),
            ("unknown-top-level-keys-kept", file("", extra: "\"futureTop\":{\"a\":[1,2.5,null]},\"local.syncConflictC0Receipts.v1\":{},")),
            ("schema-2-still-decodes", Data(String(decoding: file(""), as: UTF8.self)
                .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)),
            ("missing-records", Data(String(decoding: file(""), as: UTF8.self)
                .replacingOccurrences(of: ",\"records\":[]", with: "").utf8)),
            ("missing-kid", Data(String(decoding: file(""), as: UTF8.self)
                .replacingOccurrences(of: "\"kid\":\"\(Fixture.kid)\",", with: "").utf8)),
            ("missing-kdf", Data("{\"schemaVersion\":1,\"kid\":\"k\",\"vaultSalt\":\"IiIi\",\"records\":[]}".utf8)),
            ("kdf-passthrough", Data(("{\"schemaVersion\":1,\"kid\":\"k\",\"vaultSalt\":\"IiIi\","
                + "\"kdf\":{\"alg\":\"a\",\"iterations\":1,\"saltP\":\"VVVV\",\"memory\":65536},\"records\":[]}").utf8)),
            ("not-json", Data("vault".utf8)),
            ("empty-file", Data()),
        ]
        for (name, input) in decodes {
            var members: [(String, J)] = [
                ("kind", .str("decode")),
                ("fileText", utf8Text(input)),
                ("probeSchemaVersion", VaultFile.probeSchemaVersion(input).map { .n($0) } ?? .null),
            ]
            do {
                let document = try VaultFile.decode(input)
                members.append(("document", vaultDocumentJ(document)))
                members.append(("reencodedText", utf8Text(try VaultFile.encode(document))))
            } catch {
                members.append(("error", .str(errorName(error))))
            }
            cases.append(vcase("decode-\(name)", members))
        }
        return VectorFile(
            name: "V14-vault-document",
            pins: "VaultFile.encode full bytes (Foundation JSONEncoder, .prettyPrinted + .sortedKeys, ISO-8601 millisecond timestamps) and VaultFile.decode leniency (brief 02 §2.11, hazards H7–H9)",
            notes: [
                "Swift and Rust bytes differ by design; Kotlin needs field-level compatibility. The bytes are recorded because VaultFile.update compares them (H7) and so that drift in Foundation's pretty printer is visible.",
                "Foundation writes record ids uppercase.",
                "Timestamps are NOT bit-exact through vault.json. `document` holds the doubles given to the encoder, `decodedDocument` the doubles Swift holds after reading the file back: 812578800.123 is written as …00.123Z and read back as 812578800.1229999 (one ulp lower). Those read-back doubles are what a secure record's createdAt/updatedAt carry onto the wire, where they are hashed. The timestamp-format and timestamp-parse cases pin Foundation's ISO8601DateFormatter arithmetic for both directions.",
                "Date.distantPast is -63114076800.0 seconds since 2001 (0001-01-01T00:00:00Z).",
            ],
            cases: cases)
    }

    // MARK: V15

    /// Field-for-field mirror of `EncryptedSnippetBackup.Container`, which is private.
    private struct MirrorContainer: Codable {
        var format: String
        var schemaVersion: Int
        var backupID: String
        var wrappedKey: PassphraseKDF.WrappedKey
        var payload: String
    }

    /// Transcription of the private `EncryptedSnippetBackup.payloadAAD`.
    static func backupPayloadAAD(backupID: String, wrappedKey: PassphraseKDF.WrappedKey) -> Data {
        SnippetCrypto.domainSeparated("snip.backup.payload.v1", [
            Data(EncryptedSnippetBackup.formatIdentifier.utf8),
            withUnsafeBytes(of: UInt64(EncryptedSnippetBackup.currentSchemaVersion).bigEndian) { Data($0) },
            Data(backupID.utf8),
            Data(wrappedKey.alg.utf8),
            withUnsafeBytes(of: UInt64(wrappedKey.iterations).bigEndian) { Data($0) },
            Data(wrappedKey.salt.utf8),
            Data(wrappedKey.envelope.utf8),
        ])
    }

    /// Transcription of the private `vaultWrappingKey` and `vaultKeyAAD`.
    static func backupVaultWrap(exportKey: SymmetricKey, vaultSalt: Data, backupID: String, kid: String)
        -> (key: SymmetricKey, info: Data, aad: Data) {
        var info = Data("snip.backup.vault-key.v1|".utf8)
        info.append(Data(backupID.utf8))
        info.append(0)
        info.append(Data(kid.utf8))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: exportKey, salt: vaultSalt, info: info, outputByteCount: 32)
        let aad = SnippetCrypto.domainSeparated("snip.backup.vault-key-aad.v1", [
            Data(SnippetCrypto.wireVersion.utf8), Data(backupID.utf8), Data(kid.utf8),
        ])
        return (key, info, aad)
    }

    /// The container `EncryptedSnippetBackup.seal` would write for this passphrase
    /// salt. `seal` itself draws the salt from `PassphraseKDF.makeSalt()` with no
    /// seam, so the deterministic vector is assembled here from the same public
    /// pieces and proven equal to the real output at the real salt.
    static func assembleBackup(
        payloadJSON: Data, exportKey: SymmetricKey, backupID: String, passphrase: String,
        salt: Data, iterations: Int, keyNonce: SnippetCrypto.NonceSource,
        payloadNonce: SnippetCrypto.NonceSource
    ) throws -> (container: Data, wrappedKey: PassphraseKDF.WrappedKey, aad: Data, payload: String) {
        let wrapped = try PassphraseKDF.wrap(
            exportKey, passphrase: passphrase, salt: salt, kid: backupID, iterations: iterations,
            nonces: keyNonce)
        let aad = backupPayloadAAD(backupID: backupID, wrappedKey: wrapped)
        let payload = try SnippetCrypto.seal(payloadJSON, key: exportKey, aad: aad, nonces: payloadNonce)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let container = try encoder.encode(MirrorContainer(
            format: EncryptedSnippetBackup.formatIdentifier,
            schemaVersion: EncryptedSnippetBackup.currentSchemaVersion,
            backupID: backupID, wrappedKey: wrapped, payload: payload))
        return (container, wrapped, aad, payload)
    }

    static let backupSnippets: [Snippet] = [
        Snippet(
            id: Fixture.uuidA, name: "Email signature", keyword: "sig",
            content: "Best regards,\nMichael ☕\n", tags: ["Work", "mail"],
            isEnabled: true, isPinned: false, createdAt: Fixture.created, updatedAt: Fixture.updated),
        Snippet(
            id: Fixture.uuidD, name: "", keyword: "", content: "", tags: [], isEnabled: false,
            isPinned: true, createdAt: Date(timeIntervalSinceReferenceDate: 123.25),
            updatedAt: Date(timeIntervalSinceReferenceDate: 456.5)),
    ]

    struct BackupScenario {
        var name: String
        var vault: VaultDocument?
        var iterations: Int
        var backupID: String
    }

    static func backupVectors() throws -> [VectorFile] {
        var sealedCases: [J] = []
        var openCases: [J] = []
        let exportKey = SymmetricKey(data: Data.filled(0x88, 32))
        let vaultKey = SymmetricKey(data: Fixture.libraryKey)
        let salt = Data.filled(0x99, 16)
        let keyNonce = Data.filled(0xaa, 12), vaultKeyNonce = Data.filled(0xbb, 12), payloadNonce = Data.filled(0xcc, 12)
        let passphrase = "Café public backup fixture"
        let decomposed = "Cafe\u{301} public backup fixture"
        var vault = try vaultDocument(passthrough: true)
        vault.removeLocalConflictInstallReceipts()

        let scenarios = [
            BackupScenario(name: "with-vault-600000", vault: vault, iterations: PassphraseKDF.iterations,
                           backupID: "b-617a0001-0000-4000-8000-0000000000aa"),
            BackupScenario(name: "no-vault-low-iterations", vault: nil, iterations: 2,
                           backupID: "b-00000000-0000-4000-8000-000000000001"),
        ]
        var firstContainer: Data?
        var firstPayload: Data?
        for scenario in scenarios {
            let real = try EncryptedSnippetBackup.seal(
                snippets: backupSnippets, vault: scenario.vault,
                vaultKey: scenario.vault == nil ? nil : vaultKey,
                passphrase: passphrase, iterations: scenario.iterations, backupID: scenario.backupID,
                exportKey: exportKey, keyNonce: fixedNonce(keyNonce),
                vaultKeyNonce: fixedNonce(vaultKeyNonce), payloadNonce: fixedNonce(payloadNonce))
            let realContainer = try JSONDecoder().decode(MirrorContainer.self, from: real)
            guard let realSalt = SnippetCrypto.data(fromBase64URL: realContainer.wrappedKey.salt) else {
                throw InteropFailure("V15 salt")
            }
            let payloadJSON = try SnippetCrypto.open(
                realContainer.payload, key: exportKey,
                aad: backupPayloadAAD(backupID: scenario.backupID, wrappedKey: realContainer.wrappedKey))

            // The transcription reproduces Swift byte for byte at Swift's own salt …
            let replay = try assembleBackup(
                payloadJSON: payloadJSON, exportKey: exportKey, backupID: scenario.backupID,
                passphrase: passphrase, salt: realSalt, iterations: scenario.iterations,
                keyNonce: fixedNonce(keyNonce), payloadNonce: fixedNonce(payloadNonce))
            try require(replay.container == real, "V15 \(scenario.name): transcription equals EncryptedSnippetBackup.seal")
            // … so the same assembly at a fixed salt is what Swift would have written.
            let fixed = try assembleBackup(
                payloadJSON: payloadJSON, exportKey: exportKey, backupID: scenario.backupID,
                passphrase: passphrase, salt: salt, iterations: scenario.iterations,
                keyNonce: fixedNonce(keyNonce), payloadNonce: fixedNonce(payloadNonce))
            for (label, data, phrase) in [("fixed", fixed.container, decomposed), ("real", real, passphrase)] {
                let opened = try EncryptedSnippetBackup.open(data, passphrase: phrase)
                try require(opened.snippets == backupSnippets, "V15 \(scenario.name) \(label) snippets")
                try require(opened.vault == scenario.vault, "V15 \(scenario.name) \(label) vault")
                try require(opened.vaultKey?.raw == (scenario.vault == nil ? nil : vaultKey.raw), "V15 \(scenario.name) \(label) key")
            }
            if firstContainer == nil { firstContainer = fixed.container; firstPayload = payloadJSON }

            var common: [(String, J)] = [
                ("passphrase", .text(passphrase)),
                ("iterations", .n(scenario.iterations)),
                ("backupID", .str(scenario.backupID)),
                ("exportKeyHex", .hex(exportKey.raw)),
                ("keyNonceHex", .hex(keyNonce)),
                ("vaultKeyNonceHex", .hex(vaultKeyNonce)),
                ("payloadNonceHex", .hex(payloadNonce)),
                ("snippets", .arr(backupSnippets.map(snippetJ))),
                ("vault", scenario.vault.map(vaultDocumentJ) ?? .null),
                ("vaultKeyHex", scenario.vault == nil ? .null : .hex(vaultKey.raw)),
                ("payloadJSONText", utf8Text(payloadJSON)),
                ("payloadJSONHex", .hex(payloadJSON)),
            ]
            if let document = scenario.vault, let vaultSalt = document.vaultSaltBytes {
                let wrap = backupVaultWrap(
                    exportKey: exportKey, vaultSalt: vaultSalt, backupID: scenario.backupID, kid: document.kid)
                let wrappedVaultKey = try SnippetCrypto.seal(
                    vaultKey.raw, key: wrap.key, aad: wrap.aad, nonces: fixedNonce(vaultKeyNonce))
                try require(
                    String(decoding: payloadJSON, as: UTF8.self).contains(wrappedVaultKey),
                    "V15 \(scenario.name): vault-key wrap transcription matches the payload")
                common += [
                    ("vaultWrapHKDFInfoHex", .hex(wrap.info)),
                    ("vaultWrapKeyHex", .hex(wrap.key.raw)),
                    ("vaultKeyAADHex", .hex(wrap.aad)),
                    ("wrappedVaultKey", .str(wrappedVaultKey)),
                ]
            }
            func wrappedJ(_ wrapped: PassphraseKDF.WrappedKey) -> J {
                .obj([
                    ("alg", .str(wrapped.alg)), ("iterations", .n(wrapped.iterations)),
                    ("salt", .str(wrapped.salt)), ("envelope", .str(wrapped.envelope)),
                ])
            }
            sealedCases.append(vcase(scenario.name, [("kind", .str("seal")), ("passphraseSaltHex", .hex(salt))] + common + [
                ("wrappedKey", wrappedJ(fixed.wrappedKey)),
                ("payloadAADHex", .hex(fixed.aad)),
                ("payload", .str(fixed.payload)),
                ("containerText", utf8Text(fixed.container)),
                ("containerHex", .hex(fixed.container)),
            ]))
            openCases.append(vcase(scenario.name, [("kind", .str("open")), ("passphraseSaltHex", .hex(realSalt))] + common + [
                ("wrappedKey", wrappedJ(realContainer.wrappedKey)),
                ("payloadAADHex", .hex(backupPayloadAAD(backupID: scenario.backupID, wrappedKey: realContainer.wrappedKey))),
                ("payload", .str(realContainer.payload)),
                ("containerText", utf8Text(real)),
                ("containerHex", .hex(real)),
            ]))
        }

        // Hazard H2, measured: the same backup with the vault records' dates written as
        // ISO-8601 strings (what the Linux writer and backup-v1.json do).
        guard let container = firstContainer, let payload = firstPayload,
              var tree = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              var vaultTree = tree["vault"] as? [String: Any],
              let records = vaultTree["records"] as? [[String: Any]] else {
            throw InteropFailure("V15 payload shape")
        }
        let timestamps = VaultTimestampCodec()
        vaultTree["records"] = records.map { record -> [String: Any] in
            var copy = record
            for key in ["createdAt", "updatedAt"] {
                if let seconds = copy[key] as? Double {
                    copy[key] = timestamps.string(from: Date(timeIntervalSinceReferenceDate: seconds))
                }
            }
            return copy
        }
        tree["vault"] = vaultTree
        let isoPayload = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys, .prettyPrinted])
        let iso = try assembleBackup(
            payloadJSON: isoPayload, exportKey: exportKey, backupID: scenarios[0].backupID,
            passphrase: passphrase, salt: salt, iterations: 2,
            keyNonce: fixedNonce(keyNonce), payloadNonce: fixedNonce(payloadNonce))
        let isoOpened = try EncryptedSnippetBackup.open(iso.container, passphrase: passphrase)
        sealedCases.append(vcase("h2-iso-vault-dates-as-read-by-swift", [
            ("kind", .str("open")),
            ("passphrase", .text(passphrase)),
            ("vaultKeyHex", .hex(vaultKey.raw)),
            ("payloadJSONText", utf8Text(isoPayload)),
            ("containerText", utf8Text(iso.container)),
            ("swiftOpened", .obj([
                ("snippets", .arr(isoOpened.snippets.map(snippetJ))),
                ("vault", isoOpened.vault.map(vaultDocumentJ) ?? .null),
                ("vaultKeyHex", isoOpened.vaultKey.map { .hex($0.raw) } ?? .null),
            ])),
            ("expectedVaultRecordDates", .arr(vault.records.map { record in
                .obj([("createdAt", .date(record.createdAt)), ("updatedAt", .date(record.updatedAt))])
            })),
        ]))

        var decoded = try JSONDecoder().decode(MirrorContainer.self, from: container)
        func reencoded(_ edit: (inout MirrorContainer) -> Void) throws -> Data {
            var copy = decoded
            edit(&copy)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(copy)
        }
        decoded.schemaVersion = 1
        let low = try assembleBackup(
            payloadJSON: firstPayload!, exportKey: exportKey, backupID: scenarios[0].backupID, passphrase: passphrase,
            salt: salt, iterations: 2, keyNonce: fixedNonce(keyNonce), payloadNonce: fixedNonce(payloadNonce))
        decoded = try JSONDecoder().decode(MirrorContainer.self, from: low.container)
        var tamperedPayload = Array(decoded.payload); tamperedPayload[40] = tamperedPayload[40] == "A" ? "B" : "A"
        let opens: [(String, Data, String)] = [
            ("open-ok", low.container, passphrase),
            ("open-ok-decomposed-passphrase", low.container, decomposed),
            ("open-wrong-passphrase", low.container, "Cafe public backup fixture"),
            ("open-empty-passphrase", low.container, ""),
            ("open-not-json", Data("backup".utf8), passphrase),
            ("open-wrong-format", try reencoded { $0.format = "com.example.other" }, passphrase),
            ("open-schema-2", try reencoded { $0.schemaVersion = 2 }, passphrase),
            ("open-empty-backup-id", try reencoded { $0.backupID = "" }, passphrase),
            ("open-changed-backup-id", try reencoded { $0.backupID = "b-other" }, passphrase),
            ("open-unknown-alg", try reencoded { $0.wrappedKey.alg = "argon2id" }, passphrase),
            ("open-zero-iterations", try reencoded { $0.wrappedKey.iterations = 0 }, passphrase),
            ("open-bad-salt", try reencoded { $0.wrappedKey.salt = "***" }, passphrase),
            ("open-tampered-payload", try reencoded { $0.payload = String(tamperedPayload) }, passphrase),
            ("open-payload-not-an-envelope", try reencoded { $0.payload = "v1.AAAA" }, passphrase),
            ("open-missing-payload-key", Data(String(decoding: low.container, as: UTF8.self)
                .replacingOccurrences(of: "\"payload\"", with: "\"payloadX\"").utf8), passphrase),
        ]
        for (name, data, phrase) in opens {
            sealedCases.append(vcase(name, [
                ("kind", .str("open")),
                ("containerText", utf8Text(data)),
                ("passphrase", .text(phrase)),
            ] + outcome {
                let opened = try EncryptedSnippetBackup.open(data, passphrase: phrase)
                return .obj([("ordinaryCount", .n(opened.ordinaryCount)), ("secureCount", .n(opened.secureCount))])
            }))
        }

        let pins = "EncryptedSnippetBackup container, passphrase wrap (kid = backupID), payload AAD, vault-key wrap and the decrypted payload JSON (brief 02 §2.14, hazard H2)"
        return [
            VectorFile(
                name: "V15-encrypted-backup",
                pins: pins,
                notes: [
                    "EncryptedSnippetBackup.seal draws the passphrase salt from PassphraseKDF.makeSalt() and offers no seam for it, so its output cannot be pinned directly. These containers are assembled by this tool from PassphraseKDF.wrap, SnippetCrypto.seal and a field-for-field mirror of the private Container, using the payload JSON that the real seal produced. Before writing, the tool proves the assembly equal, byte for byte, to the real EncryptedSnippetBackup.seal output at that run's random salt, and opens the fixed-salt container with EncryptedSnippetBackup.open.",
                    "H2 settled: payloadJSONText shows what Swift writes. Snippet dates AND the vault records' createdAt/updatedAt are JSON numbers (seconds since 2001-01-01T00:00:00Z); record ids are uppercase; `vault` and `wrappedVaultKey` are absent, not null, when there is no vault.",
                    "h2-iso-vault-dates-as-read-by-swift: the same payload with ISO-8601 strings for the vault records' dates opens without error in Swift, and the dates silently become Date.distantPast (-63114076800.0). See swiftOpened versus expectedVaultRecordDates.",
                    "with-vault-600000 is opened by the self-check with the decomposed (NFD) spelling of the passphrase.",
                ],
                cases: sealedCases),
            VectorFile(
                name: "V15-encrypted-backup",
                direction: .open,
                pins: pins,
                notes: [
                    "Unmodified EncryptedSnippetBackup.seal output. The export key, backup id and all three nonces are fixed through the function's own parameters; the passphrase salt is random per run (no seam).",
                ],
                cases: openCases),
        ]
    }

    // MARK: V16

    private struct MirrorKeyFile: Codable {
        let algorithm: String
        let ciphertext: String
        let datasetID: String
        let schemaVersion: Int
    }

    /// Transcription of `GitSyncRecovery.seal` with the nonce as a parameter.
    static func assembleRecovery(material: Data, datasetID: UUID, secret: Data, nonce: Data)
        throws -> (file: Data, aad: Data, key: SymmetricKey, plaintext: Data) {
        let bundle = try LibraryKeyBootstrap.PortableKeyBundle(material: material)
        let plaintext = try bundle.jsonData
        let aad = Data(["snippets-git-recovery-v1", lower(datasetID)].joined(separator: "\0").utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("snippets-git-recovery-salt-v1".utf8), info: aad, outputByteCount: 32)
        let sealed = try AES.GCM.seal(
            plaintext, using: key, nonce: try AES.GCM.Nonce(data: nonce), authenticating: aad)
        guard let combined = sealed.combined else { throw InteropFailure("V16 combined") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(MirrorKeyFile(
            algorithm: GitSyncRecovery.algorithm, ciphertext: combined.base64EncodedString(),
            datasetID: lower(datasetID), schemaVersion: GitSyncRecovery.schemaVersion))
        data.append(UInt8(ascii: "\n"))
        return (data, aad, key, plaintext)
    }

    static func recoveryVectors() throws -> [VectorFile] {
        var sealedCases: [J] = []
        var openCases: [J] = []
        let scenarios: [(String, Data, UUID, Data, Data)] = [
            ("material-0-63", Data.counting(from: 0, 64), Fixture.datasetID, Fixture.recoverySecret, Data.counting(from: 0x30, 12)),
            ("material-99-aa", Fixture.syncMaterial, Fixture.uuidA, Data.filled(0x66, 16), Data.filled(0x31, 12)),
        ]
        var firstFile = Data()
        for (name, material, datasetID, secret, nonce) in scenarios {
            let kit = GitSyncRecovery.Kit(datasetID: datasetID, secret: secret)
            let real = try GitSyncRecovery.seal(material: material, kit: kit)
            let realFile = try JSONDecoder().decode(MirrorKeyFile.self, from: real)
            guard let realCombined = Data(base64Encoded: realFile.ciphertext) else { throw InteropFailure("V16 base64") }
            let realNonce = Data(realCombined.prefix(12))
            let replay = try assembleRecovery(material: material, datasetID: datasetID, secret: secret, nonce: realNonce)
            try require(replay.file == real, "V16 \(name): transcription equals GitSyncRecovery.seal")
            let fixed = try assembleRecovery(material: material, datasetID: datasetID, secret: secret, nonce: nonce)
            try require(try GitSyncRecovery.open(fixed.file, kit: kit) == material, "V16 \(name) fixed opens")
            try require(try GitSyncRecovery.open(real, kit: kit) == material, "V16 \(name) real opens")
            try require(
                try GitSyncRecovery.open(fixed.file, kit: try GitSyncRecovery.Kit(code: kit.code.lowercased(), datasetID: datasetID)) == material,
                "V16 \(name) opens from the typed code")
            if firstFile.isEmpty { firstFile = fixed.file }
            let common: [(String, J)] = [
                ("materialHex", .hex(material)),
                ("datasetID", .str(lower(datasetID))),
                ("recoverySecretHex", .hex(secret)),
                ("recoveryCode", .str(kit.code)),
                ("aadHex", .hex(fixed.aad)),
                ("hkdfSaltText", .str("snippets-git-recovery-salt-v1")),
                ("keyHex", .hex(fixed.key.raw)),
                ("plaintextText", utf8Text(fixed.plaintext)),
                ("plaintextHex", .hex(fixed.plaintext)),
            ]
            sealedCases.append(vcase(name, [("kind", .str("seal"))] + common + [
                ("nonceHex", .hex(nonce)),
                ("fileText", utf8Text(fixed.file)),
                ("fileHex", .hex(fixed.file)),
            ]))
            openCases.append(vcase(name, [("kind", .str("open"))] + common + [
                ("nonceHex", .hex(realNonce)),
                ("fileText", utf8Text(real)),
                ("fileHex", .hex(real)),
            ]))
        }

        let material = Data.counting(from: 0, 64)
        let kit = GitSyncRecovery.Kit(datasetID: Fixture.datasetID, secret: Fixture.recoverySecret)
        let text = String(decoding: firstFile, as: UTF8.self)
        let decoded = try JSONDecoder().decode(MirrorKeyFile.self, from: firstFile)
        let combined = Data(base64Encoded: decoded.ciphertext)!
        func file(ciphertext: String, algorithm: String = GitSyncRecovery.algorithm,
                  datasetID: String = lower(Fixture.datasetID), version: String = "1", extra: String = "") -> Data {
            Data(("{\"algorithm\":\"\(algorithm)\",\"ciphertext\":\"\(ciphertext)\",\"datasetID\":\"\(datasetID)\","
                + extra + "\"schemaVersion\":\(version)}").utf8)
        }
        var tampered = combined; tampered[20] ^= 0x01
        // A valid AEAD over a plaintext that is not a strict portable bundle.
        func sealing(_ plaintext: Data) throws -> String {
            let aad = Data(["snippets-git-recovery-v1", lower(Fixture.datasetID)].joined(separator: "\0").utf8)
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: Fixture.recoverySecret),
                salt: Data("snippets-git-recovery-salt-v1".utf8), info: aad, outputByteCount: 32)
            return try AES.GCM.seal(
                plaintext, using: key, nonce: try AES.GCM.Nonce(data: Data.filled(0x32, 12)),
                authenticating: aad).combined!.base64EncodedString()
        }
        let bundleText = String(decoding: try LibraryKeyBootstrap.PortableKeyBundle(material: material).jsonData, as: UTF8.self)
        let opens: [(String, Data, GitSyncRecovery.Kit)] = [
            ("open-ok", firstFile, kit),
            ("open-ok-compact-framing", file(ciphertext: decoded.ciphertext), kit),
            ("open-ok-without-final-newline", Data(text.dropLast().utf8), kit),
            ("open-wrong-code", firstFile, GitSyncRecovery.Kit(datasetID: Fixture.datasetID, secret: Data.filled(0x66, 16))),
            ("open-kit-for-another-dataset", firstFile, GitSyncRecovery.Kit(datasetID: Fixture.uuidA, secret: Fixture.recoverySecret)),
            ("open-file-names-another-dataset", file(ciphertext: decoded.ciphertext, datasetID: lower(Fixture.uuidA)),
             GitSyncRecovery.Kit(datasetID: Fixture.uuidA, secret: Fixture.recoverySecret)),
            ("open-dataset-id-uppercase", file(ciphertext: decoded.ciphertext, datasetID: Fixture.datasetID.uuidString), kit),
            ("open-unknown-algorithm", file(ciphertext: decoded.ciphertext, algorithm: "other"), kit),
            ("open-schema-2", file(ciphertext: decoded.ciphertext, version: "2"), kit),
            ("open-schema-as-string", file(ciphertext: decoded.ciphertext, version: "\"1\""), kit),
            ("open-extra-key", file(ciphertext: decoded.ciphertext, extra: "\"note\":\"x\","), kit),
            ("open-tampered-ciphertext", file(ciphertext: tampered.base64EncodedString()), kit),
            ("open-ciphertext-unpadded-base64", file(ciphertext: decoded.ciphertext.replacingOccurrences(of: "=", with: "") + (decoded.ciphertext.hasSuffix("=") ? "" : "A")), kit),
            ("open-ciphertext-base64url", file(ciphertext: SnippetCrypto.base64URL(combined)), kit),
            ("open-ciphertext-27-bytes", file(ciphertext: Data.filled(1, 27).base64EncodedString()), kit),
            ("open-ciphertext-28-bytes", file(ciphertext: Data.filled(1, 28).base64EncodedString()), kit),
            ("open-ciphertext-empty", file(ciphertext: ""), kit),
            ("open-not-json", Data("recovery".utf8), kit),
            ("open-json-array", Data("[]".utf8), kit),
            ("open-over-8192-bytes", firstFile + Data(repeating: 0x20, count: 8_192), kit),
            ("open-bundle-with-extra-key", file(ciphertext: try sealing(Data(
                bundleText.replacingOccurrences(of: "{", with: "{\"extra\":1,").utf8))), kit),
            ("open-bundle-scope-other", file(ciphertext: try sealing(Data(
                bundleText.replacingOccurrences(of: "sync-v1", with: "sync-v2").utf8))), kit),
            ("open-bundle-not-json", file(ciphertext: try sealing(Data("hello".utf8))), kit),
            ("open-bundle-pretty-printed", file(ciphertext: try sealing(Data(
                bundleText.replacingOccurrences(of: ",", with: ", ").utf8))), kit),
        ]
        for (name, data, kit) in opens {
            sealedCases.append(vcase(name, [
                ("kind", .str("open")),
                ("fileText", utf8Text(data)),
                ("fileByteCount", .n(data.count)),
                ("datasetID", .str(lower(kit.datasetID))),
                ("recoverySecretHex", .hex(kit.secret)),
            ] + outcome { .hex(try GitSyncRecovery.open(data, kit: kit)) }))
        }
        for (name, code) in [
            ("kit-from-display-code", kit.code), ("kit-from-lowercase-code", kit.code.lowercased()),
            ("kit-from-typo", "X" + kit.code.dropFirst()), ("kit-from-empty", ""),
        ] {
            sealedCases.append(vcase(name, [
                ("kind", .str("kit")),
                ("code", .str(code)),
            ] + outcome { .hex(try GitSyncRecovery.Kit(code: code, datasetID: Fixture.datasetID).secret) }))
        }

        let pins = "keys/recovery.json: GitSyncRecovery.seal file bytes, HKDF key, AAD, plaintext bundle; GitSyncRecovery.open outcomes (brief 02 §2.12, brief 03 §2.7)"
        return [
            VectorFile(
                name: "V16-git-recovery",
                pins: pins,
                notes: [
                    "GitSyncRecovery.seal has no nonce parameter (brief 02 Q13). The seal cases are assembled by this tool from the same CryptoKit calls with a fixed nonce; before writing, the tool proves that assembly equal, byte for byte, to the real GitSyncRecovery.seal output at that run's random nonce, and opens the fixed file with GitSyncRecovery.open.",
                    "ciphertext = base64(nonce(12) ‖ ct ‖ tag(16)); the plaintext is not padded.",
                    "`ok` in open cases is the recovered 64-byte material.",
                ],
                cases: sealedCases),
            VectorFile(
                name: "V16-git-recovery",
                direction: .open,
                pins: pins,
                notes: ["Unmodified GitSyncRecovery.seal output; the nonce is random per run (no seam)."],
                cases: openCases),
        ]
    }

    // MARK: V17

    static func v17() throws -> VectorFile {
        var cases: [J] = []
        let scopes: [(String, String, String, UUID)] = [
            ("github-main", "github.com/example/snippets-library", "refs/heads/main", Fixture.datasetID),
            ("github-other-branch", "github.com/example/snippets-library", "refs/heads/snippets", Fixture.datasetID),
            ("github-other-dataset", "github.com/example/snippets-library", "refs/heads/main", Fixture.uuidA),
            ("gitea-nested-path", "git.example.org/team/sub/library", "refs/heads/release/1.0", Fixture.uuidB),
            ("loopback", "127.0.0.1/library", "refs/heads/main", Fixture.uuidC),
        ]
        for (name, location, refName, datasetID) in scopes {
            let scope = GitSyncKeyStore.Scope(location: location, refName: refName, datasetID: datasetID)
            let preimage = "snippets-git-key-v1\n\(location)\n\(refName)\n\(lower(datasetID))"
            try require(
                scope.account == "git-library-v1-" + String(sha256Hex(Data(preimage.utf8)).prefix(32)),
                "V17 \(name) preimage")
            cases.append(vcase(name, [
                ("location", .str(location)),
                ("refName", .str(refName)),
                ("datasetID", .str(lower(datasetID))),
                ("preimageHex", .hex(Data(preimage.utf8))),
                ("account", .str(scope.account)),
            ]))
        }
        let remotes: [(String, String, String)] = [
            ("from-https-remote", "https://GitHub.com/Example/Snippets-Library.git", "main"),
            ("from-scp-remote", "git@github.com:Example/Snippets-Library.git", "main"),
            ("from-ssh-url-remote", "ssh://git@GitHub.com:2222/Example/Snippets-Library.git/", "main"),
        ]
        for (name, spec, branch) in remotes {
            let location = try GitRepositoryLocation.parse(spec)
            let remote: GitRemote
            switch location {
            case .https(let url): remote = try GitRemote(url: url, branch: branch, username: "fixture-user", password: "fixture-token")
            case .ssh(let ssh): remote = try GitRemote(ssh: ssh, branch: branch)
            }
            let scope = GitSyncKeyStore.Scope(remote: remote, datasetID: Fixture.datasetID)
            cases.append(vcase(name, [
                ("remote", .str(spec)),
                ("branch", .str(branch)),
                ("location", .str(scope.location)),
                ("refName", .str(scope.refName)),
                ("datasetID", .str(lower(Fixture.datasetID))),
                ("account", .str(scope.account)),
            ]))
        }
        return VectorFile(
            name: "V17-git-key-account",
            pins: "GitSyncKeyStore.Scope.account: \"git-library-v1-\" + hex(SHA-256(\"snippets-git-key-v1\" LF location LF refName LF lower(datasetID))[0..<16]) (brief 02 §6.2, brief 03 §2.12)",
            notes: ["snippets/Sync/GitSyncKeyStore.swift is compiled unmodified into the tool; no Keychain is touched."],
            cases: cases)
    }

    // MARK: V18

    static func v18() throws -> VectorFile {
        var cases: [J] = []
        let plain = try CryptoVectorsB.envelopes()[0].1
        for (name, material, nonce) in [
            ("material-99-aa", Fixture.syncMaterial, UInt8(0xd0)),
            ("material-0-63", Data.counting(from: 0, 64), UInt8(0xd1)),
            ("material-slice-of-larger-buffer", (Data.filled(0xee, 5) + Data.counting(from: 0x40, 64) + Data.filled(0xee, 3))[5..<69], UInt8(0xd2)),
        ] {
            let keyring = try SyncKeyStore.keyring(from: material)
            let sealer = SnippetCryptoSealer(keyring: keyring, scopeID: SyncKeyStore.account, nonces: fixedNonce(nonce))
            let record = try WireCodec.seal(plain, using: sealer)
            try require(try WireCodec.open(record, using: sealer) == plain, "V18 \(name)")
            cases.append(vcase(name, [
                ("materialHex", .hex(Data(material))),
                ("keyHex", .hex(keyring.libraryKey.raw)),
                ("saltHex", .hex(keyring.salt)),
                ("scopeID", .str(SyncKeyStore.account)),
                ("recordKeyHex", .hex(keyring.recordKey(for: plain.id).raw)),
                ("nonceHex", .hex(Data.filled(nonce, 12))),
                ("envelopeCanonicalText", utf8Text(try plain.canonicalData())),
                ("wire", .obj([
                    ("id", .str(lower(record.id))),
                    ("rev", .str(record.rev)),
                    ("deleted", .bool(record.deleted)),
                    ("blobText", utf8Text(record.blob)),
                ])),
            ]))
        }
        for count in [0, 32, 63, 65] {
            cases.append(vcase("material-\(count)-bytes", [
                ("materialHex", .hex(Data.filled(1, count))),
            ] + outcome { .hex(try SyncKeyStore.keyring(from: Data.filled(1, count)).salt) }))
        }
        return VectorFile(
            name: "V18-sync-key-split",
            pins: "SyncKeyStore.keyring(from:) (64-byte K_sync material = key ‖ salt) followed by one WireCodec.seal under scope sync-v1 (brief 02 §2.7)",
            notes: [
                "snippets/Sync/SyncKeyStore.swift is compiled unmodified; two app-layer types it names (SnippetsCloudKeychainScope, SyncBackendSelectionStore) are compile-only shims the tool never runs.",
                "The sealed envelope is V11's `plain`.",
            ],
            cases: cases)
    }

    // MARK: V19

    static func v19() throws -> VectorFile {
        var cases: [J] = []
        for (name, material) in [
            ("material-0-63", Data.counting(from: 0, 64)),
            ("material-99-aa", Fixture.syncMaterial),
            ("material-ff", Data.filled(0xff, 64)),
            ("material-with-slash-and-plus", Data.filled(0xfb, 32) + Data.filled(0xff, 32)),
        ] {
            let bundle = try LibraryKeyBootstrap.PortableKeyBundle(material: material)
            let data = try bundle.jsonData
            try require(try LibraryKeyBootstrap.PortableKeyBundle(jsonData: data).material == material, "V19 \(name)")
            cases.append(vcase(name, [
                ("kind", .str("encode")),
                ("materialHex", .hex(material)),
                ("jsonText", utf8Text(data)),
                ("jsonHex", .hex(data)),
            ]))
        }
        let good = String(decoding: try LibraryKeyBootstrap.PortableKeyBundle(material: Data.counting(from: 0, 64)).jsonData, as: UTF8.self)
        let key = Data.counting(from: 0, 32).base64EncodedString()
        let parses: [(String, String)] = [
            ("ok", good),
            ("ok-pretty-and-reordered", "{\n  \"scopeID\": \"sync-v1\",\n  \"schemaVersion\": 1,\n  \"salt\": \"\(Data.counting(from: 32, 32).base64EncodedString())\",\n  \"key\": \"\(key)\"\n}"),
            ("extra-key", good.replacingOccurrences(of: "{", with: "{\"extra\":1,")),
            ("missing-salt", "{\"key\":\"\(key)\",\"schemaVersion\":1,\"scopeID\":\"sync-v1\"}"),
            ("schema-2", good.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")),
            ("schema-as-double", good.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0")),
            ("scope-other", good.replacingOccurrences(of: "sync-v1", with: "sync-v2")),
            ("key-31-bytes", good.replacingOccurrences(of: key, with: Data.counting(from: 0, 31).base64EncodedString())),
            ("key-unpadded", good.replacingOccurrences(of: key, with: key.replacingOccurrences(of: "=", with: ""))),
            ("key-base64url", good.replacingOccurrences(of: key, with: SnippetCrypto.base64URL(Data.counting(from: 0, 32)))),
            ("key-non-canonical-trailing-bits", good.replacingOccurrences(of: key, with: String(key.dropLast(2)) + "9=")),
            ("not-json", "bundle"),
            ("over-2048-bytes", good + String(repeating: " ", count: 2_048)),
        ]
        for (name, text) in parses {
            cases.append(vcase("parse-\(name)", [
                ("kind", .str("parse")),
                ("jsonText", .str(text)),
                ("jsonByteCount", .n(text.utf8.count)),
            ] + outcome { .hex(try LibraryKeyBootstrap.PortableKeyBundle(jsonData: Data(text.utf8)).material) }))
        }
        for count in [0, 63, 65] {
            cases.append(vcase("encode-\(count)-bytes", [
                ("kind", .str("encode")),
                ("materialHex", .hex(Data.filled(1, count))),
            ] + outcome { utf8Text(try LibraryKeyBootstrap.PortableKeyBundle(material: Data.filled(1, count)).jsonData) }))
        }
        return VectorFile(
            name: "V19-portable-key-bundle",
            pins: "LibraryKeyBootstrap.PortableKeyBundle.jsonData (compact, sorted keys, slashes unescaped) and its strict reader (brief 02 §2.7)",
            notes: ["`ok` in parse cases is the 64-byte material."],
            cases: cases)
    }
}
