import CryptoKit
import Foundation
@testable import SnippetsCore

// L1–L3: snippets.json, the hybrid logical clock, keyword and tag normalisation.

enum LibraryVectorsA {

    // MARK: L1

    static let library: [Snippet] = [
        Snippet(
            id: Fixture.uuidA, name: "Email signature", keyword: "sig",
            content: "Best regards,\nMichael\n", tags: ["Work", "mail"],
            isEnabled: true, isPinned: false, createdAt: Fixture.created, updatedAt: Fixture.updated),
        Snippet(
            id: Fixture.uuidB, name: "Café \"quoted\" \\ name ☕", keyword: "café",
            content: "Tab\there\r\nCRLF, control \u{1}, slash a/b, emoji 🔑, e\u{301}, \u{2028}line sep, \u{7F}DEL",
            tags: ["Ünïcode", "日本語", "two words"],
            isEnabled: false, isPinned: true,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_123.5)),
        Snippet(
            id: Fixture.uuidC, name: "", keyword: "", content: "", tags: [],
            isEnabled: true, isPinned: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: -0.0)),
        Snippet(
            id: Fixture.uuidD, name: "Odd dates", keyword: "odd",
            content: "{date:yyyy-MM-dd} {clipboard}", tags: ["x"],
            isEnabled: true, isPinned: true,
            createdAt: Date(timeIntervalSinceReferenceDate: -31_622_400.25),
            updatedAt: Date(timeIntervalSinceReferenceDate: 1e16)),
    ]

    static func l1() throws -> VectorFile {
        var cases: [J] = []
        let array = try SnippetLibraryCodec.encode(library)
        let collection = try SnippetLibraryCodec.encodeCollection(library)
        try require(try SnippetLibraryCodec.decode(array) == library, "L1 array round trip")
        try require(try SnippetLibraryCodec.decode(collection) == library, "L1 collection round trip")
        cases.append(vcase("encode-array", [
            ("kind", .str("encode")),
            ("shape", .str("array")),
            ("snippets", .arr(library.map(snippetJ))),
            ("fileText", utf8Text(array)),
            ("fileHex", .hex(array)),
            ("digest", .str(SnippetLibraryCodec.digest(of: array))),
        ]))
        cases.append(vcase("encode-collection", [
            ("kind", .str("encode")),
            ("shape", .str("collection")),
            ("snippets", .arr(library.map(snippetJ))),
            ("fileText", utf8Text(collection)),
            ("fileHex", .hex(collection)),
            ("digest", .str(SnippetLibraryCodec.digest(of: collection))),
        ]))
        let empty = try SnippetLibraryCodec.encode([])
        cases.append(vcase("encode-empty-array", [
            ("kind", .str("encode")),
            ("shape", .str("array")),
            ("snippets", .arr([])),
            ("fileText", utf8Text(empty)),
            ("fileHex", .hex(empty)),
            ("digest", .str(SnippetLibraryCodec.digest(of: empty))),
        ]))

        let id = "\"id\":\"\(Fixture.uuidA.uuidString)\""
        let dates = "\"createdAt\":700000000.25,\"updatedAt\":700000123.5"
        let full = "{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"tags\":[\"t\"],\"isEnabled\":false,\"isPinned\":true,\(dates)}"
        let decodes: [(String, String)] = [
            ("full-record", "[\(full)]"),
            ("collection-shape", "{\"snippets\":[\(full)]}"),
            ("collection-with-extra-top-level-keys", "{\"version\":3,\"snippets\":[\(full)]}"),
            ("lowercase-id", "[{\"id\":\"\(lower(Fixture.uuidB))\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\(dates)}]"),
            ("optional-fields-absent-except-dates", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\(dates)}]"),
            ("only-createdAt", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"createdAt\":5}]"),
            ("unknown-keys-ignored", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\(dates),\"color\":\"red\",\"x\":{\"a\":1}}]"),
            ("tags-normalised-on-decode", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\(dates),\"tags\":[\"  Work \",\"work\",\"WÖRK\",\"two   words\",\"\",\"Two\\nWords\"]}]"),
            ("keyword-not-sanitised-on-decode", "[{\(id),\"name\":\"  n  \",\"keyword\":\" \\\\my key \",\"content\":\"c\",\(dates)}]"),
            ("integer-dates", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"createdAt\":700000000,\"updatedAt\":700000001}]"),
            ("exponent-dates", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"createdAt\":7e8,\"updatedAt\":7.000001235e+8}]"),
            ("null-optional-fields", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"tags\":null,\"isEnabled\":null,\"isPinned\":null,\(dates)}]"),
            ("duplicate-ids-accepted-by-codec", "[\(full),\(full)]"),
            ("escapes-and-unicode", "[{\(id),\"name\":\"a\\/b \\u00e9 \\ud83d\\udd11\",\"keyword\":\"k\",\"content\":\"l1\\nl2\\ttab\\\\\",\(dates)}]"),
            ("empty-array", "[]"),
            ("empty-collection", "{\"snippets\":[]}"),
            ("whitespace-only-array", " [ ] \n"),
            ("missing-name", "[{\(id),\"keyword\":\"k\",\"content\":\"c\",\(dates)}]"),
            ("missing-content", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\(dates)}]"),
            ("missing-id", "[{\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\(dates)}]"),
            ("id-not-uuid", "[{\"id\":\"1\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\(dates)}]"),
            ("id-without-hyphens", "[{\"id\":\"\(Fixture.uuidA.uuidString.replacingOccurrences(of: "-", with: ""))\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\(dates)}]"),
            ("name-is-number", "[{\(id),\"name\":1,\"keyword\":\"k\",\"content\":\"c\",\(dates)}]"),
            ("tags-is-string", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"tags\":\"work\",\(dates)}]"),
            ("flag-is-number", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"isEnabled\":1,\(dates)}]"),
            ("date-is-iso-string", "[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"createdAt\":\"2026-07-29T08:00:00Z\"}]"),
            ("one-bad-element-fails-all", "[\(full),{\"name\":\"n\"}]"),
            ("raycast-shape-not-accepted", "[{\"name\":\"n\",\"text\":\"c\",\"keyword\":\"k\"}]"),
            ("object-without-snippets-key", "{\"items\":[]}"),
            ("top-level-string", "\"snippets\""),
            ("not-json", "snippets"),
            ("empty-file", ""),
            ("bom-prefixed-array", "\u{FEFF}[]"),
            ("trailing-comma", "[\(full),]"),
        ]
        for (name, text) in decodes {
            let data = Data(text.utf8)
            cases.append(vcase("decode-\(name)", [
                ("kind", .str("decode")),
                ("fileText", .str(text)),
                ("fileHex", .hex(data)),
                ("digest", .str(SnippetLibraryCodec.digest(of: data))),
            ] + outcome { .arr(try SnippetLibraryCodec.decode(data).map(snippetJ)) }))
        }
        // createdAt absent: the decoder substitutes the current time, which no vector
        // can pin. Only the relationship is recorded.
        let now = try SnippetLibraryCodec.decode(Data("[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]".utf8))[0]
        let onlyUpdated = try SnippetLibraryCodec.decode(Data("[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"updatedAt\":9}]".utf8))[0]
        cases.append(vcase("decode-dates-absent", [
            ("kind", .str("decode-defaults")),
            ("fileText", .str("[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]")),
            ("createdAtIsDecodeTime", .bool(abs(now.createdAt.timeIntervalSinceNow) < 60)),
            ("updatedAtEqualsCreatedAt", .bool(now.updatedAt == now.createdAt)),
            ("tags", .strings(now.tags)),
            ("isEnabled", .bool(now.isEnabled)),
            ("isPinned", .bool(now.isPinned)),
        ]))
        cases.append(vcase("decode-only-updatedAt", [
            ("kind", .str("decode-defaults")),
            ("fileText", .str("[{\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"updatedAt\":9}]")),
            ("createdAtIsDecodeTime", .bool(abs(onlyUpdated.createdAt.timeIntervalSinceNow) < 60)),
            ("updatedAt", .date(onlyUpdated.updatedAt)),
        ]))

        // Display order.
        func item(_ id: String, pinned: Bool, created: Double) -> Snippet {
            Snippet(id: UUID(uuidString: id)!, name: id, keyword: "", content: "", isPinned: pinned,
                    createdAt: Date(timeIntervalSinceReferenceDate: created),
                    updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        }
        let unordered = [
            item("00000000-0000-4000-8000-00000000000A", pinned: false, created: 100),
            item("00000000-0000-4000-8000-000000000009", pinned: false, created: 100),
            item("F0000000-0000-4000-8000-000000000000", pinned: false, created: 100),
            item("80000000-0000-4000-8000-000000000000", pinned: false, created: 100),
            item("7FFFFFFF-0000-4000-8000-000000000000", pinned: false, created: 100),
            item("00000000-0000-4000-8000-000000000001", pinned: false, created: 100.00000000000001),
            item("00000000-0000-4000-8000-000000000002", pinned: true, created: 1),
            item("00000000-0000-4000-8000-000000000003", pinned: true, created: 2),
            item("00000000-0000-4000-8000-000000000004", pinned: false, created: -5),
            item("00000000-0000-4000-8000-000000000005", pinned: false, created: 1e12),
        ]
        cases.append(vcase("display-order", [
            ("kind", .str("display-order")),
            ("input", .arr(unordered.map { snippet in
                .obj([("id", .str(lower(snippet.id))), ("isPinned", .bool(snippet.isPinned)), ("createdAt", .date(snippet.createdAt))])
            })),
            ("sortedIDs", .strings(SnippetDisplayOrder.sorted(unordered).map { lower($0.id) })),
        ]))

        // displayName and first-line derivation.
        let fifty = String(repeating: "x", count: 50)
        let displays: [(String, String, String)] = [
            ("name-wins", "  Name  ", "body"),
            ("blank-name-first-line", " \n\t", "\n\n  first line  \nsecond"),
            ("empty-everything", "", ""),
            ("whitespace-body", "", " \n\t\u{00A0}\u{2028}"),
            ("crlf-body", "", "\r\nline one\r\nline two"),
            ("line-separator-body", "", "one\u{2028}two"),
            ("nel-body", "", "one\u{0085}two"),
            ("vertical-tab-and-form-feed", "", "\u{000B}\u{000C}one\u{000C}two"),
            ("exactly-50-characters", "", fifty),
            ("51-characters", "", fifty + "y"),
            ("51-emoji-clusters", "", String(repeating: "👨‍👩‍👧", count: 51)),
            ("combining-marks-count-as-one", "", String(repeating: "e\u{301}", count: 51)),
            ("zero-width-space-is-whitespace", "", "\u{200B}text\u{200B}"),
            ("name-only-zero-width-space", "\u{200B}", "body"),
        ]
        for (name, snippetName, content) in displays {
            let snippet = Snippet(id: Fixture.uuidA, name: snippetName, keyword: "", content: content)
            cases.append(vcase("display-\(name)", [
                ("kind", .str("display")),
                ("snippetName", .text(snippetName)),
                ("content", .text(content)),
                ("displayName", .text(snippet.displayName)),
                ("contentFirstLine", .text(snippet.contentFirstLine)),
                ("contentFirstLineUntruncated", .text(snippet.contentFirstLineUntruncated)),
            ]))
        }

        // A secure snippet has no row in snippets.json; the app sees this shell instead.
        let document = try CryptoVectorsC.vaultDocument(passthrough: false)
        cases.append(vcase("secure-shell-from-vault-record", [
            ("kind", .str("secure-shell")),
            ("vaultRecord", vaultRecordJ(document.records[0])),
            ("shell", snippetJ(document.records[0].shell)),
        ]))
        return VectorFile(
            name: "L01-library-json",
            pins: "SnippetLibraryCodec.encode / encodeCollection bytes and digest, SnippetLibraryCodec.decode outcomes, SnippetDisplayOrder, Snippet.displayName / contentFirstLine, VaultRecord.shell (brief 01 §2 `snippets.json`, §3)",
            notes: [
                "snippets.json is device-local: Kotlin needs to parse the same, not to write the same bytes. The bytes are recorded so drift in Foundation's printer is visible. Note `\\/` for a slash, the blank line inside an empty array, uppercase ids, and that dates are JSON numbers (seconds since 2001).",
                "decode errors are all SnippetLibraryCodec.Failure.unreadable; the codec does not say why.",
                "A secure snippet never has a row in snippets.json. `secure-shell-from-vault-record` shows the content-free Snippet the rest of the app sees for one.",
            ],
            cases: cases)
    }

    // MARK: L2

    static func hlcJ(_ hlc: HLC) -> J {
        .obj([
            ("wallMs", .str(String(hlc.wallMs))),
            ("counter", .n(Int(hlc.counter))),
            ("device", .str(hlc.device)),
            ("string", .str(hlc.string)),
        ])
    }

    static func l2() throws -> VectorFile {
        var cases: [J] = []
        let inits: [(UInt64, UInt16, String)] = [
            (0, 0, "00000000"), (1000, 2, "AA-BB-CC-DD"), (0x019f_ace3_39f4, 3, "aabbccdd"),
            (0xFFFF_FFFF_FFFF, 0xFFFF, "ffffffff"), (0x1_0000_0000_0000, 0, "1"),
            (UInt64.max, 1, ""), (1, 0xFFFF, "abcdef0123456789"), (255, 255, "not hex at all"),
            (978_307_200_000, 0, "0"), (42, 7, "00000000"), (42, 7, "0000-0000"),
        ]
        for (index, (wall, counter, device)) in inits.enumerated() {
            let hlc = HLC(wallMs: wall, counter: counter, device: device)
            try require(HLC(parsing: hlc.string) == hlc, "L2 init \(index) reparse")
            cases.append(vcase("init-\(index)", [
                ("kind", .str("init")),
                ("wallMs", .str(String(wall))),
                ("counter", .n(Int(counter))),
                ("device", .str(device)),
                ("hlc", hlcJ(hlc)),
            ]))
        }
        let parses = [
            "0000000003e8-0002-aabbccdd", "019face339f4-0003-aabbccdd", "ffffffffffff-ffff-ffffffff",
            "000000000000-0000-00000000", "0000000003E8-0002-aabbccdd", "0000000003e8-0002-AABBCCDD",
            "0000000003e8-000g-aabbccdd", "00000003e8-0002-aabbccdd", "0000000003e8-0002-aabbccdd ",
            " 0000000003e8-0002-aabbccdd", "0000000003e8_0002_aabbccdd", "0000000003e8-0002-aabbccd",
            "0000000003e8-0002-aabbccdde", "0000000003e8-00002-abbccdd", "", "0000000003e8-0002",
            "0000000003e8-0002-aabbccd\u{e9}", "\u{FF10}000000003e8-0002-aabbccdd",
            "0000000003e8-0002-aabbcc\u{0661}\u{0662}", "+00000003e8-0002-aabbccdd",
        ]
        for (index, text) in parses.enumerated() {
            cases.append(vcase("parse-\(index)", [
                ("kind", .str("parse")),
                ("input", .text(text)),
                ("hlc", HLC(parsing: text).map(hlcJ) ?? .null),
            ]))
        }
        let devices = [
            "ABCDEF01", "abcdef0123456789", "1", "ab-cd-ef-01", "not hex at all", "", "00000000",
            "0", "0000", "000000000", "0000-0000", "g", "GHIJ", "ffffffff", "FFFFFFFFF", "12345678",
            "\u{FF11}\u{FF12}", "\u{0661}", "éa", "A B C D E F 0 1 2", "00000001",
        ]
        for (index, raw) in devices.enumerated() {
            cases.append(vcase("device-\(index)", [
                ("kind", .str("normalizedDevice")),
                ("input", .text(raw)),
                ("normalized", .str(HLC.normalizedDevice(raw))),
                ("isCanonicalDeviceID", .bool(HLC.isCanonicalDeviceID(raw))),
            ]))
        }

        let ordered: [HLC] = [
            HLC(wallMs: 5, counter: 0, device: "00000001"), HLC(wallMs: 5, counter: 0, device: "00000002"),
            HLC(wallMs: 5, counter: 1, device: "00000001"), HLC(wallMs: 6, counter: 0, device: "00000000"),
            HLC(wallMs: 5, counter: 0, device: "a0000000"), HLC(wallMs: 5, counter: 0, device: "0a000000"),
            HLC(wallMs: 4, counter: 0xFFFF, device: "ffffffff"), HLC(wallMs: 5, counter: 0, device: "00000001"),
            HLC(wallMs: 0x1_0000_0000, counter: 0, device: "00000001"), HLC(wallMs: 0xFFFF_FFFF, counter: 9, device: "00000009"),
        ]
        var index = 0
        for left in ordered {
            for right in ordered {
                let relation = left < right ? "<" : (left == right ? "==" : ">")
                let stringRelation = left.string < right.string ? "<" : (left.string == right.string ? "==" : ">")
                try require(relation == stringRelation, "L2 order equals string order")
                cases.append(vcase("compare-\(index)", [
                    ("kind", .str("compare")),
                    ("left", .str(left.string)),
                    ("right", .str(right.string)),
                    ("relation", .str(relation)),
                ]))
                index += 1
            }
        }
        cases.append(vcase("sorted", [
            ("kind", .str("sort")),
            ("input", .strings(ordered.map(\.string))),
            ("sorted", .strings(ordered.sorted().map(\.string))),
            ("max", .str(ordered.max()!.string)),
        ]))

        let seconds: [Double] = [
            0, -1, 0.0004, 0.001, 0.0019999, 1, 1.9999, 1_785_312_000, 1_785_312_000.5,
            1_785_312_000.9999, 1_790_886_000.123456, 1_790_886_000.123, 281_474_976_710.655,
            281_474_976_710.656, 1e15, 1e300, .infinity, -.infinity, .nan, 1e-320, 978_307_200,
        ]
        for value in seconds {
            let date = Date(timeIntervalSince1970: value)
            cases.append(vcase("milliseconds-\(String(format: "%016llx", value.bitPattern))", [
                ("kind", .str("millisecondsSince1970")),
                ("secondsSince1970", .double(value)),
                ("secondsSince2001", .double(date.timeIntervalSinceReferenceDate)),
                ("secondsSince1970AsSwiftRecomputes", .double(date.timeIntervalSince1970)),
                ("milliseconds", .str(String(date.millisecondsSince1970))),
                ("foreignHLC", .str(HLC.foreign(updatedAt: date).string)),
            ]))
        }
        // The model's own dates are doubles since 2001; the clock reads them through
        // `timeIntervalSince1970`, i.e. after adding 978307200.0 in double arithmetic.
        for value in [807_004_800.5, 812_578_800.123456, 812_578_800.1229999, 812_578_800.999, 0.0, -978_307_200.0, -978_307_199.9995, 700_000_123.4567] {
            let date = Date(timeIntervalSinceReferenceDate: value)
            cases.append(vcase("milliseconds-from-2001-\(String(format: "%016llx", value.bitPattern))", [
                ("kind", .str("millisecondsSince1970")),
                ("secondsSince2001", .double(value)),
                ("secondsSince1970AsSwiftRecomputes", .double(date.timeIntervalSince1970)),
                ("milliseconds", .str(String(date.millisecondsSince1970))),
                ("foreignHLC", .str(HLC.foreign(updatedAt: date).string)),
            ]))
        }

        // Generator scripts.
        enum Step {
            case now(UInt64)
            case send
            case sendAtLeast(UInt64)
            case stamp(Double, HLC?)
            case observe(HLC)
        }
        let scripts: [(String, String, HLC?, UInt64, [Step])] = [
            ("send-monotonic", "aabbccdd", nil, 1000, [.send, .send, .now(1001), .send, .now(999), .send, .send]),
            ("init-with-newer-persisted", "aabbccdd", HLC(wallMs: 5000, counter: 9, device: "11111111"), 1000,
             [.send, .now(5000), .send, .now(5001), .send]),
            ("init-with-older-persisted", "AA-BB-CC-DD", HLC(wallMs: 10, counter: 9, device: "11111111"), 1000, [.send]),
            ("init-persisted-same-wall-higher-device", "00000001", HLC(wallMs: 1000, counter: 0, device: "00000002"), 1000, [.send]),
            ("counter-overflow-carries", "aabbccdd", HLC(wallMs: 2000, counter: 0xFFFE, device: "aabbccdd"), 1000,
             [.send, .send, .send]),
            ("send-at-least", "aabbccdd", nil, 1000,
             [.sendAtLeast(500), .sendAtLeast(1500), .sendAtLeast(1500), .sendAtLeast(1400), .now(3000), .sendAtLeast(1)]),
            ("stamp-above-base", "aabbccdd", nil, 1_785_312_000_000, [
                .stamp(807_004_800.5, nil),
                .stamp(807_004_800.5, HLC(wallMs: 1_785_312_000_500, counter: 7, device: "0badcafe")),
                .stamp(807_004_800.5, HLC(wallMs: 1_900_000_000_000, counter: 0, device: "0badcafe")),
                .stamp(900_000_000, nil),
                .stamp(-5, HLC(wallMs: 0xFFFF_FFFF_FFFF, counter: 0, device: "0badcafe")),
            ]),
            ("observe", "aabbccdd", nil, 1000, [
                .observe(HLC(wallMs: 900, counter: 5, device: "0badcafe")),
                .observe(HLC(wallMs: 1000, counter: 0, device: "0badcafe")),
                .observe(HLC(wallMs: 1000, counter: 0, device: "ffffffff")),
                .observe(HLC(wallMs: 2000, counter: 0xFFFF, device: "0badcafe")),
                .send,
                .observe(HLC(wallMs: 1000 + 86_400_000, counter: 1, device: "0badcafe")),
                .observe(HLC(wallMs: 1001 + 86_400_000, counter: 1, device: "0badcafe")),
                .now(2000),
                .observe(HLC(wallMs: 1001 + 86_400_000, counter: 1, device: "0badcafe")),
                .send,
            ]),
            ("journal-clock-now-ahead", "aabbccdd", HLC(wallMs: 500, counter: 3, device: "0badcafe"), 1000, [.send]),
            ("journal-clock-evidence-ahead", "aabbccdd", HLC(wallMs: 1500, counter: 3, device: "0badcafe"), 1000, [.send]),
            ("journal-clock-evidence-at-counter-max", "aabbccdd", HLC(wallMs: 1500, counter: 0xFFFF, device: "0badcafe"), 1000, [.send]),
        ]
        for (name, device, persisted, start, steps) in scripts {
            var now = start
            let generator = HLCGenerator(device: device, persisted: persisted, physicalNowMs: { now })
            var described: [J] = []
            let initial = generator.last
            for step in steps {
                switch step {
                case .now(let value):
                    now = value
                    generator.physicalNowMs = { value }
                    described.append(.obj([("op", .str("setNow")), ("nowMs", .str(String(value)))]))
                case .send:
                    let result = generator.send()
                    described.append(.obj([("op", .str("send")), ("result", .str(result.string))]))
                case .sendAtLeast(let floor):
                    let result = generator.send(atLeast: floor)
                    described.append(.obj([("op", .str("sendAtLeast")), ("floorMs", .str(String(floor))), ("result", .str(result.string))]))
                case .stamp(let updated, let base):
                    let result = generator.stamp(updatedAt: Date(timeIntervalSinceReferenceDate: updated), baseHLC: base)
                    described.append(.obj([
                        ("op", .str("stamp")), ("updatedAt", .double(updated)),
                        ("baseHLC", .opt(base?.string)), ("result", .str(result.string)),
                    ]))
                case .observe(let remote):
                    generator.observe(remote)
                    described.append(.obj([
                        ("op", .str("observe")), ("remote", .str(remote.string)),
                        ("last", .str(generator.last.string)),
                        ("rejectedSkewCount", .n(generator.rejectedSkewCount)),
                    ]))
                }
            }
            _ = now
            cases.append(vcase("generator-\(name)", [
                ("kind", .str("generator")),
                ("device", .str(device)),
                ("normalizedDevice", .str(generator.device)),
                ("persisted", .opt(persisted?.string)),
                ("nowMs", .str(String(start))),
                ("initialLast", .str(initial.string)),
                ("steps", .arr(described)),
            ]))
        }
        return VectorFile(
            name: "L02-hlc",
            pins: "HLC init / string / parsing / ordering, HLC.normalizedDevice, Date.millisecondsSince1970, HLC.foreign, HLCGenerator send / stamp / observe (brief 01 §3 Hybrid logical clock)",
            notes: [
                "wallMs and milliseconds are decimal strings (they exceed 2^53 at the clamp).",
                "The three journal-clock scripts model the private SyncJournal.clock(after:deviceID:now:): a generator seeded with persisted = max(evidence), then one send().",
                "HLC ordering equals lexicographic ordering of the string form; the tool asserts it for every compare case.",
            ],
            cases: cases)
    }

    // MARK: L3

    static func scalarsHex(_ text: String) -> String {
        text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
    }

    static func l3() throws -> [VectorFile] {
        var cases: [J] = []
        let keywords = [
            "sig", "  sig  ", "\\sig", "\\\\sig", " \\ \\ sig", "my key", "my   key\tword\nhere", "\\", "\\\\",
            "", "   ", "Sig", "SIG", "café", "cafe\u{301}", "\\\u{301}sig", "a\\b", "sig\\", "\u{00A0}sig\u{00A0}",
            "a\u{00A0}b", "a\u{2003}b", "a\u{200B}b", "\u{200B}sig", "a\u{3000}b", "a\u{0085}b", "a\u{2028}b",
            "a\u{001F}b", "a\u{000B}b", "a\u{FEFF}b", "a\u{2060}b", "a\u{180E}b", "🔑 key", "\\🔑", "\\ \\", "/sig", ";;sig",
            String(repeating: "k", count: 300), "a-b", "a--b", " - ", "a\r\nb", "\\\r\nsig", "\\ sig \\ more",
        ]
        for (index, raw) in keywords.enumerated() {
            let sanitized = Snippet.sanitizedKeyword(raw)
            cases.append(vcase("keyword-\(index)", [
                ("kind", .str("sanitizedKeyword")),
                ("input", .text(raw)),
                ("sanitized", .text(sanitized)),
                ("filterKey", .text(SnippetTagging.filterKey(for: sanitized))),
            ]))
        }

        let tagLists: [[String]] = [
            ["Work", "work", "WORK"], ["  Team\n Notes  ", "TEAM NOTES", "Café", "CAFE", " \t "],
            ["b", "a", "B", "A"], [], ["", " ", "\n"], ["two   words", "two words", "Two\tWords"],
            ["Ünïcode", "unicode", "UNICODE"], ["straße", "STRASSE", "strasse", "Straẞe"],
            ["ﬁle", "file", "FILE"], ["İstanbul", "istanbul", "ıstanbul", "ISTANBUL"],
            ["Ａ", "a", "ａ"], ["が", "か", "か\u{3099}"], ["日本語", "日本語 "], ["é", "e\u{301}", "E\u{301}", "e"],
            ["Å", "\u{212B}", "A\u{30A}", "a"], ["Σ", "σ", "ς"], ["ø", "o", "Ø"], ["conflict", "Conflict"],
            ["🔑", "🔑\u{FE0F}", "🔑 "], ["a\u{00A0}b", "a b"], ["a\u{200B}b", "a b", "ab"], ["#tag", "tag"],
            ["й", "и", "ё", "е"], ["x\u{20DD}", "x"], ["ǅ", "ǆ", "Ǆ"], ["tag, with comma", "tag", "with comma"],
            [String(repeating: "long", count: 100)], ["a", "a", "a"], ["  a  ", "\ta\n"],
        ]
        for (index, tags) in tagLists.enumerated() {
            let normalized = SnippetTagging.normalizedTags(tags)
            cases.append(vcase("tags-\(index)", [
                ("kind", .str("normalizedTags")),
                ("input", .arr(tags.map { .text($0) })),
                ("normalized", .arr(normalized.map { .text($0) })),
                ("inputFilterKeys", .arr(tags.map { .text(SnippetTagging.filterKey(for: $0)) })),
            ]))
        }

        let foldInputs = [
            "Work", "WÖRK", "wörk", "straße", "Straẞe", "ﬁ", "ŉ", "İ", "ı", "I", "i", "Σ", "ς", "Ω", "\u{2126}",
            "ǅ", "Ǆ", "é", "e\u{301}", "a\u{301}\u{301}", "\u{301}a", "Å", "\u{212B}", "й", "ё", "ΐ", "ø", "đ", "ł",
            "が", "か\u{3099}", "آ", "\u{627}\u{654}", "\u{915}\u{93C}", "\u{5D0}\u{5B8}", "Ａ", "ａ", "１", "x\u{20DD}",
            "a\u{FE0F}", "한\u{301}", "\u{13A0}", "\u{AB70}", "\u{23A}\u{301}", "\u{531}\u{301}", "\u{10A0}\u{301}",
            "\u{2160}\u{301}", "\u{510}\u{301}", "\u{511}\u{301}", "🔑", "👨‍👩‍👧", "🇫🇷", "e\u{301}\u{323}", "ệ", "ǖ",
            "Ǆ\u{301}", "ẞ", "ſ", "K", "\u{212A}", "µ", "\u{3BC}", "ǰ", "ΰ", "ﬃ", "ﬆ", "Ⅷ", "ⅷ", "Ⓐ", "ⓐ",
            "Ǉ", "ǈ", "ǉ", "Ð", "ð", "Þ", "þ", "Æ", "æ", "Œ", "œ", "ñ", "Ñ", "ç", "Ç", "ü", "Ü", "ÿ", "Ÿ",
            "А", "а", "Я", "я", "Ё", "Й", "ї", "Ї", "ґ", "Ґ", "α", "Α", "ά", "Ά", "ϊ", "Ϊ", "ῃ", "ᾳ", "ᾼ",
            "Hello World", "MiXeD cAsE 123", "tab\tsep", "naïve café", "ＦＵＬＬ", "ｈａｌｆ", "ｶﾞ", "㍿", "①",
            "Ⱥ", "ⱥ", "Ǆemal", "ǅemal", "\u{1E9E}\u{0301}", "ö\u{0301}", "o\u{0308}\u{0301}", "", " ",
        ]
        for (index, text) in foldInputs.enumerated() {
            let folded = SnippetTagging.filterKey(for: text)
            cases.append(vcase("filterKey-\(index)", [
                ("kind", .str("filterKey")),
                ("input", .text(text)),
                ("inputScalars", .str(scalarsHex(text))),
                ("folded", .text(folded)),
                ("foldedScalars", .str(scalarsHex(folded))),
            ]))
        }

        // Foundation character sets the model relies on, enumerated over every scalar.
        func members(_ set: CharacterSet) -> [String] {
            var ranges: [String] = []
            var start: UInt32?
            var previous: UInt32 = 0
            for value in UInt32(0)...0x10FFFF {
                guard let scalar = Unicode.Scalar(value) else { continue }
                if set.contains(scalar) {
                    if start == nil { start = value }
                    previous = value
                } else if let first = start {
                    ranges.append(first == previous ? String(format: "%04X", first) : String(format: "%04X-%04X", first, previous))
                    start = nil
                }
            }
            if let first = start {
                ranges.append(first == previous ? String(format: "%04X", first) : String(format: "%04X-%04X", first, previous))
            }
            return ranges
        }
        for (name, set) in [
            ("whitespacesAndNewlines", CharacterSet.whitespacesAndNewlines),
            ("whitespaces", CharacterSet.whitespaces),
            ("newlines", CharacterSet.newlines),
        ] {
            cases.append(vcase("characterSet-\(name)", [
                ("kind", .str("characterSet")),
                ("set", .str(name)),
                ("ranges", .strings(members(set))),
            ]))
        }

        // (a) Per-scalar table: every scalar whose filterKey is not itself.
        var changed: [J] = []
        var changedCount = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(scalar)
            let folded = SnippetTagging.filterKey(for: text)
            if folded != text || Array(folded.unicodeScalars) != Array(text.unicodeScalars) {
                changedCount += 1
                changed.append(.arr([.str(String(format: "%04X", value)), .str(scalarsHex(folded))]))
            }
        }
        // (b) Base + U+0301: where the mark is dropped, as ranges of base scalars.
        var strippedRanges: [String] = []
        var keptAfterChange: [J] = []
        var runStart: UInt32?
        var runEnd: UInt32 = 0
        for value in UInt32(0)..<0x30000 {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let alone = SnippetTagging.filterKey(for: String(scalar))
            var text = String(scalar)
            text.unicodeScalars.append(Unicode.Scalar(0x301)!)
            let folded = SnippetTagging.filterKey(for: text)
            let foldedScalars = Array(folded.unicodeScalars)
            let aloneScalars = Array(alone.unicodeScalars)
            let stripped = foldedScalars == aloneScalars
            if stripped {
                if runStart == nil { runStart = value }
                runEnd = value
            } else {
                if let first = runStart {
                    strippedRanges.append(first == runEnd ? String(format: "%04X", first) : String(format: "%04X-%04X", first, runEnd))
                    runStart = nil
                }
                // Anything other than "the folded base followed by U+0301" is listed.
                if foldedScalars != aloneScalars + [Unicode.Scalar(0x301)!] {
                    keptAfterChange.append(.arr([.str(String(format: "%04X", value)), .str(scalarsHex(folded))]))
                }
            }
        }
        if let first = runStart {
            strippedRanges.append(first == runEnd ? String(format: "%04X", first) : String(format: "%04X-%04X", first, runEnd))
        }

        let table = VectorFile(
            name: "L03b-filterkey-table",
            pins: "SnippetTagging.filterKey (String.folding, case- and diacritic-insensitive, locale en_US_POSIX) over every Unicode scalar, and over base + U+0301 for every base below U+30000 (brief 01 §3 Tags)",
            notes: [
                "scalar-table.entries: [scalar, folded scalars], hex code points, for each of the \(changedCount) scalars whose fold differs from itself. Every scalar not listed folds to itself.",
                "acute-after-base.strippedAfter: ranges of base scalars B (surrogates skipped) for which filterKey(B + U+0301) == filterKey(B), i.e. the mark is dropped. For every other base below U+30000 the result is filterKey(B) followed by U+0301, except the bases in `otherwise`, listed with their exact result.",
                "This is Foundation/ICU data of the OS that ran the emitter; rerun on an OS upgrade to see drift.",
            ],
            cases: [
                vcase("scalar-table", [("kind", .str("scalar-table")), ("count", .n(changedCount)), ("entries", .arr(changed))]),
                vcase("acute-after-base", [
                    ("kind", .str("mark-after-base")),
                    ("mark", .str("0301")),
                    ("strippedAfter", .strings(strippedRanges)),
                    ("otherwise", .arr(keptAfterChange)),
                ]),
            ])
        return [
            VectorFile(
                name: "L03-keyword-and-tags",
                pins: "Snippet.sanitizedKeyword, SnippetTagging.normalizedTags, SnippetTagging.filterKey, and the Foundation character sets they use (brief 01 §3 Snippet, Tags)",
                notes: [
                    "There is no keyword or tag length limit in the Swift model; the 300- and 400-character cases pass through unchanged.",
                    "Scalars are listed as hex code points wherever the visible text would hide the difference.",
                ],
                cases: cases),
            table,
        ]
    }
}
