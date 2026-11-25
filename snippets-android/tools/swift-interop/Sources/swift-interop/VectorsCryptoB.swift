import CryptoKit
import Foundation
@testable import SnippetsCore

// V10–V12: canonical JSON, the sync envelope, the sealed wire record.

enum CryptoVectorsB {

    // MARK: V10

    static func v10() throws -> VectorFile {
        var cases: [J] = []

        var everyControl = ""
        for value in 0..<0x20 { everyControl.unicodeScalars.append(Unicode.Scalar(UInt8(value))) }
        let emits: [(String, CanonicalJSON.Value)] = [
            ("null", .null),
            ("true", .bool(true)),
            ("false", .bool(false)),
            ("empty-object", .object([:])),
            ("empty-array", .array([])),
            ("empty-string", .string("")),
            ("swift-test-literal", .object(["b": 2, "a": "x", "ä": true, "A": nil])),
            ("key-order-utf8-not-utf16", .object([
                "\u{FFFD}": 1, "\u{10000}": 2, "\u{E000}": 3, "\u{1F511}": 4, "z": 5, "": 6,
                "a": 7, "aa": 8, "A": 9, "é": 10, "\u{7F}": 11, "a\u{0}": 12,
            ])),
            ("every-c0-control", .string(everyControl)),
            ("quote-backslash-slash", .string("\"\\/")),
            ("del-and-line-separators", .string("\u{7F}\u{80}\u{2028}\u{2029}\u{FEFF}")),
            ("non-ascii-raw", .string("Café ☕ 日本語 🔑 e\u{301}")),
            ("utf8-bytes-value", .utf8(Data("bytes ✓\n".utf8))),
            ("escapes-in-keys", .object(["a\"b": 1, "a\\b": 2, "a\nb": 3, "a\u{1}b": 4])),
            ("int-zero", .int(0)),
            ("int-minus-one", .int(-1)),
            ("int-max", .int(Int64.max)),
            ("int-min", .int(Int64.min)),
            ("int-vs-double-one", .array([.int(1), .double(1)])),
            ("nested", .object([
                "x": .object(["y": .array([.object(["z": .array([])]), .null, .bool(false)])]),
                "list": .array([.int(3), .string("2"), .double(1.5), .array([.array([])])]),
            ])),
            ("array-keeps-order", .array(["b", "a", "c"])),
        ]
        for (name, value) in emits {
            let data = try CanonicalJSON.data(value)
            try require(try CanonicalJSON.data(try CanonicalJSON.value(data)) == data, "V10 \(name) reparse")
            cases.append(vcase("emit-\(name)", [
                ("kind", .str("emit")),
                ("value", canonicalTree(value)),
                ("canonicalText", utf8Text(data)),
                ("canonicalHex", .hex(data)),
            ]))
        }

        let doubles: [Double] = [
            0.0, -0.0, 1.0, -1.0, 0.1, 0.5, 1.5, 123.25, 0.0001, 0.00001, 1e-5, 1.5e-10, -1.5e-10,
            100.0, 1e15, 1e16, 1e17, 1e21, 1e22, 1e23, 9007199254740991, 9007199254740992,
            9007199254740994, 4503599627370496.5, 0.1 + 0.2, 1.0 / 3.0,
            812_578_800.123456, 807_004_800.5, 812_578_800.0, -63_114_076_800.0, 64_092_211_200.0,
            5e-324, 2.2250738585072014e-308, 2.225073858507201e-308, 1.7976931348623157e308,
            123456789012345680.0, 0.000123456789, 1234567.0, 12345678.9, 4.35, 2.675,
            299_792_458.0, 6.02214076e23, 1e-7, 1e-4, 9.999999999999999e22,
        ]
        var seenBits = Set<UInt64>()
        for value in doubles where seenBits.insert(value.bitPattern).inserted {
            let data = try CanonicalJSON.data(.double(value))
            cases.append(vcase("double-\(String(format: "%016llx", value.bitPattern))", [
                ("kind", .str("emit")),
                ("value", canonicalTree(.double(value))),
                ("canonicalText", utf8Text(data)),
            ]))
        }

        let emitFailures: [(String, CanonicalJSON.Value)] = [
            ("nan", .double(.nan)),
            ("infinity", .double(.infinity)),
            ("negative-infinity", .double(-.infinity)),
            ("utf8-lone-0xff", .utf8(Data([0xff]))),
            ("utf8-overlong-nul", .utf8(Data([0xc0, 0x80]))),
            ("utf8-overlong-slash", .utf8(Data([0xe0, 0x80, 0xaf]))),
            ("utf8-surrogate-d800", .utf8(Data([0xed, 0xa0, 0x80]))),
            ("utf8-above-10ffff", .utf8(Data([0xf4, 0x90, 0x80, 0x80]))),
            ("utf8-truncated", .utf8(Data([0xe2, 0x82]))),
            ("utf8-stray-continuation", .utf8(Data([0x41, 0x80]))),
            ("utf8-max-scalar-ok", .utf8(Data([0xf4, 0x8f, 0xbf, 0xbf]))),
            ("utf8-ed-9f-bf-ok", .utf8(Data([0xed, 0x9f, 0xbf]))),
            ("nested-nan", .object(["a": .array([.double(.nan)])])),
        ]
        for (name, value) in emitFailures {
            var described = canonicalTree(value)
            if case .double(let number) = value {
                described = .obj([("t", .str("double")), ("bits", .str(String(format: "%016llx", number.bitPattern)))])
            }
            cases.append(vcase("emit-\(name)", [
                ("kind", .str("emit")),
                ("value", described),
            ] + outcome { .hex(try CanonicalJSON.data(value)) }))
        }

        func nested(_ depth: Int) -> String {
            String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        }
        func nestedObjects(_ depth: Int) -> String {
            String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
        }
        let parses: [(String, Data)] = [
            ("canonical-object", Data("{\"A\":null,\"a\":\"x\",\"b\":2,\"ä\":true}".utf8)),
            ("whitespace-everywhere", Data(" \t\r\n{ \"a\" :\t[ 1 , 2 ]\n,\r\"b\" : { } } \n".utf8)),
            ("unsorted-keys", Data("{\"b\":1,\"a\":2}".utf8)),
            ("escape-solidus", Data("\"a\\/b\"".utf8)),
            ("escape-all-short", Data("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"".utf8)),
            ("escape-u-lowercase", Data("\"\\u00e9\"".utf8)),
            ("escape-u-uppercase", Data("\"\\u00E9\"".utf8)),
            ("escape-u-nul", Data("\"\\u0000\"".utf8)),
            ("escape-u-ascii-letter", Data("\"\\u0041\"".utf8)),
            ("escape-surrogate-pair", Data("\"\\uD83D\\uDD11\"".utf8)),
            ("escape-lone-high-surrogate", Data("\"\\uD83D\"".utf8)),
            ("escape-lone-low-surrogate", Data("\"\\uDD11\"".utf8)),
            ("escape-high-then-non-low", Data("\"\\uD83D\\u0041\"".utf8)),
            ("escape-high-then-text", Data("\"\\uD83Dab\"".utf8)),
            ("escape-unknown-x", Data("\"\\x41\"".utf8)),
            ("escape-short-hex", Data("\"\\u12\"".utf8)),
            ("escape-non-hex", Data("\"\\u12G4\"".utf8)),
            ("raw-control-0x01", Data([0x22, 0x01, 0x22])),
            ("raw-tab-in-string", Data([0x22, 0x09, 0x22])),
            ("raw-newline-in-string", Data([0x22, 0x0a, 0x22])),
            ("raw-del-in-string", Data([0x22, 0x7f, 0x22])),
            ("invalid-utf8-in-string", Data([0x22, 0xff, 0x22])),
            ("overlong-utf8-in-string", Data([0x22, 0xc0, 0x80, 0x22])),
            ("unterminated-string", Data("\"abc".utf8)),
            ("duplicate-key", Data("{\"a\":1,\"a\":2}".utf8)),
            ("duplicate-key-nfc-vs-nfd", Data("{\"\u{e9}\":1,\"e\u{301}\":2}".utf8)),
            ("duplicate-key-escaped-vs-raw", Data("{\"a\":1,\"\\u0061\":2}".utf8)),
            ("distinct-keys-case", Data("{\"a\":1,\"A\":2}".utf8)),
            ("number-zero", Data("0".utf8)),
            ("number-negative-zero-int", Data("-0".utf8)),
            ("number-negative-zero-double", Data("-0.0".utf8)),
            ("number-leading-zero", Data("01".utf8)),
            ("number-negative-leading-zero", Data("-01".utf8)),
            ("number-lone-minus", Data("-".utf8)),
            ("number-plus", Data("+1".utf8)),
            ("number-trailing-dot", Data("1.".utf8)),
            ("number-leading-dot", Data(".5".utf8)),
            ("number-bare-exponent", Data("1e".utf8)),
            ("number-exponent-sign-only", Data("1e+".utf8)),
            ("number-exponent-uppercase", Data("1E5".utf8)),
            ("number-exponent-negative", Data("25e-1".utf8)),
            ("number-one-point-zero", Data("1.0".utf8)),
            ("number-int64-max", Data("9223372036854775807".utf8)),
            ("number-int64-max-plus-one", Data("9223372036854775808".utf8)),
            ("number-int64-min", Data("-9223372036854775808".utf8)),
            ("number-int64-min-minus-one", Data("-9223372036854775809".utf8)),
            ("number-huge-integer", Data("123456789012345678901234567890".utf8)),
            ("number-overflow-to-infinity", Data("1e400".utf8)),
            ("number-underflow-to-zero", Data("1e-400".utf8)),
            ("number-long-fraction", Data("0.1000000000000000055511151231257827".utf8)),
            ("number-hex", Data("0x10".utf8)),
            ("number-nan-literal", Data("NaN".utf8)),
            ("literal-truncated", Data("nul".utf8)),
            ("literal-capitalised", Data("True".utf8)),
            ("empty-input", Data()),
            ("only-whitespace", Data(" \n".utf8)),
            ("bom-prefix", Data([0xef, 0xbb, 0xbf]) + Data("{}".utf8)),
            ("form-feed-is-not-whitespace", Data([0x0c]) + Data("{}".utf8)),
            ("trailing-value", Data("{} {}".utf8)),
            ("trailing-garbage", Data("1 x".utf8)),
            ("trailing-comma-array", Data("[1,]".utf8)),
            ("trailing-comma-object", Data("{\"a\":1,}".utf8)),
            ("missing-colon", Data("{\"a\" 1}".utf8)),
            ("non-string-key", Data("{1:2}".utf8)),
            ("single-quotes", Data("{'a':1}".utf8)),
            ("unclosed-array", Data("[1,2".utf8)),
            ("unclosed-object", Data("{\"a\":1".utf8)),
            ("depth-32-arrays", Data(nested(32).utf8)),
            ("depth-33-arrays", Data(nested(33).utf8)),
            ("depth-34-arrays", Data(nested(34).utf8)),
            ("depth-32-objects", Data(nestedObjects(32).utf8)),
            ("depth-33-objects", Data(nestedObjects(33).utf8)),
        ]
        for (name, input) in parses {
            var members: [(String, J)] = [
                ("kind", .str("parse")),
                ("inputHex", .hex(input)),
                ("inputText", utf8Text(input)),
            ]
            do {
                let value = try CanonicalJSON.value(input)
                members.append(("parsed", canonicalTree(value)))
                do {
                    let data = try CanonicalJSON.data(value)
                    members.append(("reemittedText", utf8Text(data)))
                    members.append(("reemittedHex", .hex(data)))
                } catch {
                    members.append(("reemitError", .str(errorName(error))))
                }
            } catch {
                members.append(("error", .str(errorName(error))))
            }
            cases.append(vcase("parse-\(name)", members))
        }

        return VectorFile(
            name: "V10-canonical-json",
            pins: "CanonicalJSON.data (emitter, including Double.description) and CanonicalJSON.value (parser) (brief 02 §2.9, hazards H1, H4, H5)",
            notes: [
                "`value` is a typed tree: t = null|bool|int|double|string|utf8|array|object. Object members are listed in canonical (UTF-8 byte) order; `int` is a decimal string; `double` carries the IEEE-754 bits.",
                "The parser returns every string as bytes (t = utf8).",
                "Failure payloads (byte offsets, the duplicated key) are not recorded.",
            ],
            cases: cases)
    }

    // MARK: V11 fixtures

    static let hlc = HLC(wallMs: 0x019f_ace3_39f4, counter: 3, device: "aabbccdd")
    static let laterHLC = HLC(wallMs: 0x019f_ace3_4000, counter: 0, device: "0badcafe")
    static let secureBody = Data("Fictional secret ☕\n".utf8)

    static func sealedSecureBody(id: UUID, body: Data = secureBody, nonce: UInt8 = 0x44) throws -> String {
        try SnippetCrypto.seal(
            body, for: SnippetCrypto.RecordContext(scopeID: Fixture.kid, recordID: id),
            keyring: Fixture.vaultKeyring, nonces: fixedNonce(nonce))
    }

    static func envelopes() throws -> [(String, SyncEnvelope)] {
        let plain = Snippet(
            id: Fixture.uuidA, name: "Email signature", keyword: "sig",
            content: "Best regards,\nMichael\n", tags: ["Work", "mail"],
            isEnabled: true, isPinned: false, createdAt: Fixture.created, updatedAt: Fixture.updated)
        let unicode = Snippet(
            id: Fixture.uuidC, name: "Café \"quoted\" \\ name ☕", keyword: "café",
            content: "Tab\there\r\nCRLF, NUL-free control \u{1}, slash /, emoji 🔑, e\u{301}, \u{2028}line sep",
            tags: ["Ünïcode", "日本語", "two words"],
            isEnabled: false, isPinned: true,
            createdAt: Date(timeIntervalSinceReferenceDate: -0.0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 812_578_800))
        let empty = Snippet(
            id: Fixture.uuidD, name: "", keyword: "", content: "", tags: [],
            isEnabled: true, isPinned: false,
            createdAt: Date(timeIntervalSinceReferenceDate: -31_622_400.25),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1e-7))
        let sealed = try sealedSecureBody(id: Fixture.uuidB)
        let secureX: [String: CanonicalJSON.Value] = [
            SyncEnvelope.vaultContentHashExtensionKey:
                .string(SnippetCrypto.contentHash(of: secureBody, keyring: Fixture.vaultKeyring)),
            SyncEnvelope.vaultKeyIDExtensionKey: .string(Fixture.kid),
        ]
        let secure = SyncEnvelope.secureRecord(
            id: Fixture.uuidB, name: "Wi-Fi password", keyword: "wifi", plaintext: Data(sealed.utf8),
            tags: ["home"], isEnabled: true, isPinned: true,
            createdAt: Fixture.created, updatedAt: Fixture.updated, hlc: hlc, origin: "aabbccdd",
            x: secureX)
        let ancestors = [
            String(repeating: "0a", count: 32), String(repeating: "f1", count: 32),
        ]
        return [
            ("plain", .plain(plain, hlc: hlc, origin: "aabbccdd")),
            ("plain-unicode-and-escapes", .plain(unicode, hlc: laterHLC, origin: "0badcafe")),
            ("plain-empty-fields", .plain(empty, hlc: HLC(wallMs: 0, counter: 0, device: "00000000"), origin: "00000000")),
            ("secure", secure),
            ("tombstone-plain", .tombstone(id: Fixture.uuidA, secure: false, hlc: laterHLC, origin: "0badcafe")),
            ("tombstone-secure-keeps-vaultKID", secure.tombstoned(hlc: laterHLC, origin: "0badcafe")),
            ("tombstone-secure-user-deletion", .tombstone(
                id: Fixture.uuidB, secure: true, hlc: laterHLC, origin: "0badcafe",
                x: [
                    SyncEnvelope.vaultKeyIDExtensionKey: .string(Fixture.kid),
                    SyncEnvelope.userInitiatedDeletionExtensionKey: .array(ancestors.map { .string($0) }),
                ])),
            ("plain-unknown-x-members", .plain(plain, hlc: hlc, origin: "aabbccdd", x: [
                "future.flag": true,
                "future.count": 42,
                "future.ratio": 0.25,
                "future.whole": .double(3),
                "future.null": nil,
                "future.list": [1, "two", [3.5], ["k": nil]],
                "future.nested": ["b": ["c": [:]], "a": "A"],
                "ünïcode-key": "é",
                "\u{FFFD}": 1,
                "\u{10000}": 2,
            ])),
            ("max-hlc", .plain(plain, hlc: HLC(wallMs: 0xFFFF_FFFF_FFFF, counter: 0xFFFF, device: "ffffffff"), origin: "ffffffff")),
        ]
    }

    static func rehashed(_ object: [String: CanonicalJSON.Value]) throws -> [String: CanonicalJSON.Value] {
        var copy = object
        copy["hash"] = nil
        copy["hash"] = .string(sha256Hex(try CanonicalJSON.data(.object(copy))))
        return copy
    }

    static func object(of envelope: SyncEnvelope) throws -> [String: CanonicalJSON.Value] {
        guard case .object(let object) = try envelope.canonicalValue() else {
            throw InteropFailure("envelope is not an object")
        }
        return object
    }

    // MARK: V11

    static func v11() throws -> VectorFile {
        var cases: [J] = []
        let all = try envelopes()
        for (name, envelope) in all {
            let canonical = try envelope.canonicalData()
            try require(try SyncEnvelope.parse(canonical) == envelope, "V11 \(name) reparse")
            cases.append(vcase(name, [("kind", .str("envelope")), ("envelope", try envelopeJ(envelope))]))
        }

        // What the constructor normalises (it is not what the parser does).
        let raw = SyncEnvelope(
            id: Fixture.uuidA, hlc: hlc, origin: "AB-CD-EF-01-99", secure: false, deleted: false,
            fields: SyncEnvelope.Fields(
                name: "  spaced  ", keyword: "\\kw", content: Data("x".utf8),
                tags: ["  Work ", "work", "WÖRK", "two   words", "", "Two Words", "wörk"],
                isEnabled: true, isPinned: false, createdAt: Fixture.created, updatedAt: Fixture.updated),
            x: [SyncEnvelope.userInitiatedDeletionExtensionKey: .array([.string(String(repeating: "0a", count: 32))])])
        cases.append(vcase("constructor-normalises-origin-tags-and-strips-userDeletion", [
            ("kind", .str("construct")),
            ("inputOrigin", .str("AB-CD-EF-01-99")),
            ("inputTags", .strings(["  Work ", "work", "WÖRK", "two   words", "", "Two Words", "wörk"])),
            ("inputX", .str("{\"userDeletion.v1\":[\"\(String(repeating: "0a", count: 32))\"]}")),
            ("envelope", try envelopeJ(raw)),
        ]))
        let deadWithFields = SyncEnvelope(
            id: Fixture.uuidA, hlc: hlc, origin: "7", secure: false, deleted: true,
            fields: SyncEnvelope.Fields(
                name: "n", keyword: "k", content: Data("gone".utf8), tags: [], isEnabled: true,
                isPinned: false, createdAt: Fixture.created, updatedAt: Fixture.updated))
        cases.append(vcase("constructor-drops-fields-of-a-tombstone-and-pads-origin", [
            ("kind", .str("construct")),
            ("inputOrigin", .str("7")),
            ("envelope", try envelopeJ(deadWithFields)),
        ]))

        // Parser outcomes.
        let plain = all[0].1
        let secureTombstone = all[6].1
        let base = try object(of: plain)
        let tomb = try object(of: secureTombstone)
        func edited(
            _ source: [String: CanonicalJSON.Value], rehash: Bool = true,
            _ edit: (inout [String: CanonicalJSON.Value]) -> Void
        ) throws -> Data {
            var copy = source
            edit(&copy)
            return try CanonicalJSON.data(.object(rehash ? try rehashed(copy) : copy))
        }
        func editedFields(
            rehash: Bool = true, _ edit: (inout [String: CanonicalJSON.Value]) -> Void
        ) throws -> Data {
            try edited(base, rehash: rehash) { object in
                guard case .object(var fields) = object["fields"]! else { return }
                edit(&fields)
                object["fields"] = .object(fields)
            }
        }
        let canonical = try plain.canonicalData()
        let tombCanonical = try secureTombstone.canonicalData()
        let tombText = String(decoding: tombCanonical, as: UTF8.self)
        let hashes = (0..<9).map { String(format: "%064x", $0 + 1) }
        var parses: [(String, Data)] = [
            ("ok-canonical", canonical),
            ("ok-surrounding-whitespace", Data(" \n".utf8) + canonical + Data("\t\r\n".utf8)),
            ("ok-tombstone", tombCanonical),
            ("ok-tombstone-keys-reordered", Data((
                "{\"x\":" + (try CanonicalJSON.string(tomb["x"]!)) + ",\"schemaVersion\":1,\"secure\":true,"
                + "\"origin\":\"0badcafe\",\"id\":\"\(lower(Fixture.uuidB))\",\"hlc\":\"\(laterHLC.string)\","
                + "\"hash\":\"\(try secureTombstone.envelopeHash())\",\"fields\":null,\"deleted\":true,\"contentHash\":null}").utf8)),
            ("not-json", Data("not json".utf8)),
            ("not-an-object", Data("[]".utf8)),
            ("trailing-bytes", canonical + Data("{}".utf8)),
            ("too-new-schema-2", try edited(base) { $0["schemaVersion"] = 2 }),
            ("too-new-wins-over-unknown-key", try edited(base, rehash: false) { $0["schemaVersion"] = 99; $0["future"] = 1 }),
            ("schema-0-rehashed", try edited(base) { $0["schemaVersion"] = 0 }),
            ("schema-negative-rehashed", try edited(base) { $0["schemaVersion"] = -1 }),
            ("schema-as-double", try edited(base) { $0["schemaVersion"] = .double(1) }),
            ("schema-as-string", try edited(base) { $0["schemaVersion"] = "1" }),
            ("schema-missing", try edited(base) { $0["schemaVersion"] = nil }),
            ("unknown-top-level-key", try edited(base) { $0["future"] = 1 }),
            ("missing-x", try edited(base) { $0["x"] = nil }),
            ("x-not-object", try edited(base) { $0["x"] = [] }),
            ("id-uppercase-rehashed", try edited(try object(of: all[3].1)) { $0["id"] = .string(Fixture.uuidB.uuidString) }),
            ("id-not-uuid", try edited(base) { $0["id"] = "not-a-uuid" }),
            ("id-without-hyphens", try edited(base) { $0["id"] = .string(lower(Fixture.uuidA).replacingOccurrences(of: "-", with: "")) }),
            ("hlc-uppercase", try edited(base) { $0["hlc"] = .string(hlc.string.uppercased()) }),
            ("hlc-short", try edited(base) { $0["hlc"] = "19face339f4-0003-aabbccdd" }),
            ("origin-uppercase", try edited(base) { $0["origin"] = "AABBCCDD" }),
            ("origin-seven-characters", try edited(base) { $0["origin"] = "abbccdd" }),
            ("origin-differs-from-hlc-device", try edited(base) { $0["origin"] = "12345678" }),
            ("secure-not-bool", try edited(base) { $0["secure"] = 0 }),
            ("hash-wrong", try edited(base, rehash: false) { $0["hash"] = .string(String(repeating: "0", count: 64)) }),
            ("hash-uppercase", try edited(base, rehash: false) {
                $0["hash"] = .string(((try? plain.envelopeHash()) ?? "").uppercased())
            }),
            ("hash-not-string", try edited(base, rehash: false) { $0["hash"] = nil; $0["hash"] = 1 }),
            ("content-hash-wrong-rehashed", try edited(base) { $0["contentHash"] = .string(String(repeating: "0", count: 64)) }),
            ("content-hash-null-on-live-rehashed", try edited(base) { $0["contentHash"] = nil; $0["contentHash"] = .null }),
            ("content-hash-missing", try edited(base) { $0["contentHash"] = nil }),
            ("live-without-fields", try edited(base) { $0["fields"] = .null; $0["contentHash"] = .null }),
            ("tombstone-with-fields", try edited(base) { $0["deleted"] = true }),
            ("tombstone-with-content-hash", try edited(tomb) { $0["contentHash"] = .string(String(repeating: "0", count: 64)) }),
            ("fields-unknown-key", try editedFields { $0["color"] = "red" }),
            ("fields-missing-key", try editedFields { $0["isPinned"] = nil }),
            ("fields-name-not-string", try editedFields { $0["name"] = 1 }),
            ("fields-tags-not-strings", try editedFields { $0["tags"] = [1] }),
            ("fields-flag-as-int", try editedFields { $0["isEnabled"] = 1 }),
            ("fields-date-as-string", try editedFields { $0["createdAt"] = "2026-07-29T08:00:00Z" }),
            ("fields-date-int-token-hash-over-int-form", try editedFields { $0["createdAt"] = 5 }),
            ("fields-tags-not-normalised-rehashed", try editedFields { $0["tags"] = ["  Work ", "work", ""] }),
            ("fields-content-changed-content-hash-stale", try editedFields { $0["content"] = "other" }),
            ("user-deletion-on-live-record", try edited(base) {
                $0["x"] = .object([SyncEnvelope.userInitiatedDeletionExtensionKey: .array([.string(hashes[0])])])
            }),
        ]
        // An integer token for a date parses only when the hash was computed over the
        // double spelling, because the parser re-emits it as a double.
        var intDate = base
        if case .object(var fields) = intDate["fields"]! {
            fields["createdAt"] = .double(5)
            intDate["fields"] = .object(fields)
        }
        let intDateText = String(decoding: try CanonicalJSON.data(.object(try rehashed(intDate))), as: UTF8.self)
        parses.append(("fields-date-int-token-hash-over-double-form",
            Data(intDateText.replacingOccurrences(of: "\"createdAt\":5.0", with: "\"createdAt\":5").utf8)))
        func tombX(_ value: CanonicalJSON.Value) throws -> Data {
            try edited(tomb) { $0["x"] = .object([
                SyncEnvelope.vaultKeyIDExtensionKey: .string(Fixture.kid),
                SyncEnvelope.userInitiatedDeletionExtensionKey: value,
            ]) }
        }
        parses += [
            ("user-deletion-eight-hashes", try tombX(.array(hashes.prefix(8).map { .string($0) }))),
            ("user-deletion-nine-hashes", try tombX(.array(hashes.map { .string($0) }))),
            ("user-deletion-empty", try tombX(.array([]))),
            ("user-deletion-duplicate", try tombX(.array([.string(hashes[0]), .string(hashes[0])]))),
            ("user-deletion-uppercase-hash", try tombX(.array([.string(String(repeating: "AB", count: 32))]))),
            ("user-deletion-short-hash", try tombX(.array([.string("abcd")]))),
            ("user-deletion-not-array", try tombX(.string(hashes[0]))),
            ("user-deletion-non-string-member", try tombX(.array([.string(hashes[0]), 1]))),
        ]
        try require(tombText.contains("\"fields\":null"), "V11 tombstone shape")
        for (name, input) in parses {
            cases.append(vcase("parse-\(name)", [
                ("kind", .str("parse")),
                ("inputText", utf8Text(input)),
                ("inputHex", .hex(input)),
            ] + outcome { .str(try SyncEnvelope.parse(input).envelopeHash()) }))
        }
        return VectorFile(
            name: "V11-sync-envelope",
            pins: "SyncEnvelope canonical ten-key bytes, the nine-key hash preimage, envelope hash, rev and contentHash; constructor normalisation; SyncEnvelope.parse outcomes (brief 02 §2.10)",
            notes: [
                "envelope.canonicalHex is the plaintext of the wire blob. envelopeHash = hex(SHA-256(hashPreimage)); rev = first 32 hex characters.",
                "Dates are doubles (seconds since 2001-01-01T00:00:00Z) given as IEEE-754 bits.",
                "parse cases: `ok` is the envelope hash recomputed by Swift. `…-rehashed` means the `hash` member was recomputed over the edited object, so the outcome shows what the parser itself checks.",
            ],
            cases: cases)
    }

    // MARK: V12

    static func v12() throws -> VectorFile {
        var cases: [J] = []
        var nonceByte: UInt8 = 0xb0
        var firstLive: WireRecord?
        for (name, envelope) in try envelopes() {
            let nonce = Data.filled(nonceByte, 12)
            nonceByte &+= 1
            let sealer = SnippetCryptoSealer(
                keyring: Fixture.syncKeyring, scopeID: Fixture.syncScope, nonces: fixedNonce(nonce))
            let record = try WireCodec.seal(envelope, using: sealer)
            try require(try WireCodec.open(record, using: sealer) == envelope, "V12 \(name) reopen")
            if firstLive == nil { firstLive = record }
            cases.append(vcase(name, [
                ("kind", .str("seal")),
                ("syncKeyHex", .hex(Data.filled(0x99, 32))),
                ("syncSaltHex", .hex(Data.filled(0xaa, 32))),
                ("scopeID", .str(Fixture.syncScope)),
                ("nonceHex", .hex(nonce)),
                ("plaintextText", utf8Text(try envelope.canonicalData())),
                ("plaintextHex", .hex(try envelope.canonicalData())),
                ("aadHex", .hex(SnippetCrypto.additionalData(for: SnippetCrypto.RecordContext(
                    scopeID: Fixture.syncScope, recordID: envelope.id, isDeleted: envelope.deleted)))),
                ("recordKeyHex", .hex(Fixture.syncKeyring.recordKey(for: envelope.id).raw)),
                ("wire", .obj([
                    ("id", .str(lower(record.id))),
                    ("rev", .str(record.rev)),
                    ("deleted", .bool(record.deleted)),
                    ("blobText", utf8Text(record.blob)),
                    ("blobBase64", .str(record.blob.base64EncodedString())),
                ])),
            ]))
        }

        let good = firstLive!
        let sealer = SnippetCryptoSealer(keyring: Fixture.syncKeyring, scopeID: Fixture.syncScope)
        let plain = try envelopes()[0].1
        // A blob that authenticates for one identity but carries another record's envelope.
        func forged(inner: SyncEnvelope, id: UUID, deleted: Bool, nonce: UInt8) throws -> WireRecord {
            let text = try SnippetCrypto.seal(
                try inner.canonicalData(),
                for: SnippetCrypto.RecordContext(scopeID: Fixture.syncScope, recordID: id, isDeleted: deleted),
                keyring: Fixture.syncKeyring, nonces: fixedNonce(nonce))
            return WireRecord(
                id: id, rev: String(try inner.envelopeHash().prefix(32)), deleted: deleted, blob: Data(text.utf8))
        }
        var wrongRev = good; wrongRev.rev = String(repeating: "0", count: 32)
        var longRev = good; longRev.rev = try plain.envelopeHash()
        var flippedDeleted = good; flippedDeleted.deleted = true
        var otherID = good; otherID.id = Fixture.uuidB
        var notUTF8 = good; notUTF8.blob = Data([0xff, 0xfe])
        var vaultScope = good
        vaultScope.blob = Data(try SnippetCrypto.seal(
            try plain.canonicalData(),
            for: SnippetCrypto.RecordContext(scopeID: Fixture.kid, recordID: plain.id),
            keyring: Fixture.syncKeyring, nonces: fixedNonce(0xc8)).utf8)
        let opens: [(String, WireRecord)] = [
            ("open-ok", good),
            ("open-wrong-rev", wrongRev),
            ("open-rev-is-full-hash", longRev),
            ("open-deleted-flag-flipped", flippedDeleted),
            ("open-other-record-id", otherID),
            ("open-blob-not-utf8", notUTF8),
            ("open-blob-sealed-under-vault-scope", vaultScope),
            ("open-inner-envelope-for-another-id", try forged(inner: plain, id: Fixture.uuidB, deleted: false, nonce: 0xc9)),
            ("open-inner-envelope-live-under-deleted-identity", try forged(inner: plain, id: plain.id, deleted: true, nonce: 0xca)),
            ("open-inner-not-an-envelope", WireRecord(
                id: Fixture.uuidA, rev: String(repeating: "0", count: 32), deleted: false,
                blob: Data(try SnippetCrypto.seal(
                    Data("{}".utf8),
                    for: SnippetCrypto.RecordContext(scopeID: Fixture.syncScope, recordID: Fixture.uuidA),
                    keyring: Fixture.syncKeyring, nonces: fixedNonce(0xcb)).utf8))),
        ]
        for (name, record) in opens {
            cases.append(vcase(name, [
                ("kind", .str("open")),
                ("syncKeyHex", .hex(Data.filled(0x99, 32))),
                ("syncSaltHex", .hex(Data.filled(0xaa, 32))),
                ("scopeID", .str(Fixture.syncScope)),
                ("wire", .obj([
                    ("id", .str(lower(record.id))),
                    ("rev", .str(record.rev)),
                    ("deleted", .bool(record.deleted)),
                    ("blobBase64", .str(record.blob.base64EncodedString())),
                ])),
            ] + outcome { .str(try WireCodec.open(record, using: sealer).envelopeHash()) }))
        }
        return VectorFile(
            name: "V12-wire-record",
            pins: "WireCodec.seal with SnippetCryptoSealer(scope sync-v1) and fixed nonces for the V11 envelopes; WireCodec.open outcomes (brief 02 §2.10)",
            notes: [
                "blobText is the `v1.<nonce>.<body>` envelope; the WireRecord blob is its UTF-8 bytes. `rev` is not in the AAD.",
                "open cases: `ok` is the envelope hash.",
            ],
            cases: cases)
    }
}
