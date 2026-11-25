import Foundation

// Results of the app's own model code (`snippets/Core/Snippet.swift`,
// `SnippetLibraryCodec.swift`), which this tool compiles in unchanged. They pin how
// Foundation composes: trimming plus grapheme-aware prefix checks in `sanitizedKeyword`,
// folding plus `Set<String>` identity in `normalizedTags`, `JSONDecoder`'s leniency and
// `JSONEncoder`'s spelling in the codec.

private func bits(_ date: Date) -> String {
    let raw = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - raw.count) + raw
}

/// `ID,name,keyword,content,tags,isEnabled,isPinned,createdAt,updatedAt`. Strings are
/// scalar values, tags are joined by `;` (empty field: no tags), timestamps are the 16
/// hex digits of the Double's bit pattern, or `now` where the decoder filled in the
/// current time (told apart by decoding twice: `twin` is the second result).
private func describe(_ snippet: Snippet, twin: Snippet? = nil) -> String {
    let createdIsNow = twin.map { $0.createdAt != snippet.createdAt } ?? false
    let updatedIsNow = twin.map { $0.updatedAt != snippet.updatedAt } ?? false
    return [
        snippet.id.uuidString,
        hex(snippet.name),
        hex(snippet.keyword),
        hex(snippet.content),
        snippet.tags.map { hex($0) }.joined(separator: ";"),
        snippet.isEnabled ? "1" : "0",
        snippet.isPinned ? "1" : "0",
        createdIsNow ? "now" : bits(snippet.createdAt),
        updatedIsNow ? "now" : bits(snippet.updatedAt),
    ].joined(separator: ",")
}

// MARK: - Keyword, tags, display name, display order

func modelCorpusLines(environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "Results of Snippet.sanitizedKeyword, SnippetTagging.normalizedTags, Snippet.displayName, "
            + "contentFirstLine and SnippetDisplayOrder.sorted",
        [
            "keyword<TAB>input<TAB>sanitizedKeyword",
            "tags<TAB>inputs joined by ;<TAB>normalizedTags joined by ; (empty field: no tags)",
            "display<TAB>name<TAB>content<TAB>displayName<TAB>contentFirstLine<TAB>contentFirstLineUntruncated",
            "order<TAB>id,isPinned,createdAt bits joined by ;<TAB>ids in display order joined by ;",
            "Strings are space-separated scalar values; - is the empty string.",
        ])
    var random = SeededRandom(seed: 0x30DE_0001)

    // Keywords.
    var keywords: [Scalars] = [
        [], [0x5C], [0x5C, 0x5C], [0x5C, 0x20, 0x5C, 0x61], [0x5C, 0x301, 0x61], [0x5C, 0x5C, 0x301, 0x61],
        [0x20, 0x5C, 0x20, 0x61, 0x20, 0x62, 0x20], [0x5C, 0x200D, 0x61], [0x5C, 0xFE0F], [0x5C, 0x0D, 0x0A, 0x61],
        [0x5C, 0x200B, 0x5C, 0x61], [0x61, 0x5C, 0x62], [0x5C, 0x1F3FB, 0x61], [0x5C, 0x20E3, 0x61],
        [0x5C, 0x85, 0x5C, 0x2028, 0x61], [0x61, 0x09, 0x62, 0x0A, 0x63], [0x5C, 0x903, 0x61], [0x5C, 0x94D, 0x915],
    ]
    for _ in 0..<600 {
        var values = randomText(&random, maxLength: 14)
        // Lead with backslashes often: that is the branch with grapheme semantics.
        if random.int(3) == 0 { values.insert(0x5C, at: 0) }
        if random.int(5) == 0 { values.insert(contentsOf: [0x20, 0x5C], at: 0) }
        keywords.append(values)
    }
    for input in keywords {
        lines.append("keyword\t\(hex(input))\t\(hex(Snippet.sanitizedKeyword(makeString(input))))")
    }

    // Tags. Spellings that fold alike must collapse onto the first one.
    let tagWords: [Scalars] = [
        "Work", "work", "WORK", "wörk", "Wo\u{308}rk", "Café", "cafe", "CAFE\u{301}", "İstanbul", "istanbul",
        "Straße", "STRASSE", "Ωmega", "ωmega", "σ", "ς", "Σ", "が", "か\u{3099}", "آ", "ا\u{653}",
        "한", "\u{1112}\u{1161}\u{11AB}", "ＡＢ", "ａｂ", "ab", "Ⴀ", "ⴀ", "Ꭰ", "ꭰ", "👩🏽‍💻", "", " ",
        "a  b", "a b", " a\tb ", "a\u{A0}b", "a\u{200B}b", "ab\u{301}", "ábc", "abc",
    ].map { scalarValues($0) }
    var tagLists: [[Scalars]] = [[], [[]], [[0x20]], [[0x61], [0x41]], tagWords]
    for _ in 0..<400 {
        let count = random.int(7)
        tagLists.append((0..<count).map { _ in
            random.int(3) == 0 ? randomText(&random, maxLength: 8) : random.pick(tagWords)
        })
    }
    for list in tagLists {
        let output = SnippetTagging.normalizedTags(list.map(makeString))
        lines.append("tags\t\(list.map { hex($0) }.joined(separator: ";"))\t\(output.map { hex($0) }.joined(separator: ";"))")
    }

    // Display name and the first content line.
    var displays: [(Scalars, Scalars)] = [
        ([], []), ([0x20], []), ([], [0x20, 0x0A, 0x20]), ([0x20, 0x4E, 0x20], [0x62]),
        ([], scalarValues(" \t\r\n\n  café 👩🏽‍💻  \nignored")),
        ([], scalarValues(String(repeating: "x", count: 50))),
        ([], scalarValues(String(repeating: "x", count: 51))),
        ([], scalarValues(String(repeating: "e\u{301}", count: 50))),
        ([], scalarValues(String(repeating: "e\u{301}", count: 51))),
        ([], scalarValues(String(repeating: "👨‍👩‍👧‍👦", count: 50) + "x")),
        ([], scalarValues(String(repeating: "🇩🇪", count: 51))),
        ([], scalarValues(String(repeating: "a", count: 49) + "\r\n" + "b")),
        ([], scalarValues(String(repeating: "क्ष", count: 60))),
        ([], scalarValues("\u{2028}\u{2029}\u{85}\u{0B}\u{0C}first\u{85}second")),
        ([], scalarValues("\u{1C}\u{1D}\u{1E}\u{1F}x")),
        ([], scalarValues("\u{200B} \u{200B}x\u{200B}")),
        ([], scalarValues(" \u{301}x")),
        ([0x200B], [0x61]),
    ]
    for _ in 0..<500 {
        let name = random.int(3) == 0 ? randomText(&random, maxLength: 6) : []
        var content = randomText(&random, maxLength: 30)
        if random.int(4) == 0 {
            // Long first lines, to cross the 50-Character cut.
            let unit = random.pick([[0x61], [0x65, 0x301], [0x1F468, 0x200D, 0x1F469], [0x915, 0x94D, 0x937],
                                    [0x1F1E9, 0x1F1EA], [0xAC00], [0x1100, 0x1161, 0x11A8]] as [Scalars])
            content = []
            for _ in 0..<(40 + random.int(25)) { content += unit }
            if random.bool() { content += [0x0A] + randomText(&random, maxLength: 5) }
        }
        displays.append((name, content))
    }
    for (name, content) in displays {
        let snippet = Snippet(name: makeString(name), keyword: "", content: makeString(content))
        lines.append([
            "display", hex(name), hex(content), hex(snippet.displayName),
            hex(snippet.contentFirstLine), hex(snippet.contentFirstLineUntruncated),
        ].joined(separator: "\t"))
    }

    // Display order: few distinct timestamps and nearby ids, so every tie-break runs.
    let stamps: [Double] = [0, -0.0, 1, 1.0000000000000002, -1, 700_000_000, 700_000_000.25, 1e300, -1e300]
    for _ in 0..<120 {
        let count = 1 + random.int(12)
        var seenIDs = Set<UUID>()
        var snippets: [Snippet] = []
        for _ in 0..<count {
            var bytes = [UInt8](repeating: 0, count: 16)
            // Vary the first and ninth bytes: the ones `java.util.UUID.compareTo` reads as signed.
            bytes[0] = UInt8(random.pick([0x00, 0x01, 0x7F, 0x80, 0xFF]))
            bytes[8] = UInt8(random.pick([0x00, 0x7F, 0x80, 0xFF]))
            bytes[15] = UInt8(random.int(4))
            let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                 bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            guard seenIDs.insert(id).inserted else { continue }
            snippets.append(Snippet(
                id: id, name: "", keyword: "", content: "", isPinned: random.int(3) == 0,
                createdAt: Date(timeIntervalSinceReferenceDate: random.pick(stamps)),
                updatedAt: Date(timeIntervalSinceReferenceDate: random.pick(stamps))))
        }
        let input = snippets.map { "\($0.id.uuidString),\($0.isPinned ? 1 : 0),\(bits($0.createdAt))" }
        let sorted = SnippetDisplayOrder.sorted(snippets).map { $0.id.uuidString }
        // 0.0 and -0.0 compare equal, so the result is only defined where the comparator is
        // a strict order; ids are unique here, which makes it one.
        lines.append("order\t\(input.joined(separator: ";"))\t\(sorted.joined(separator: ";"))")
    }
    return lines
}

// MARK: - snippets.json

private func base64(_ data: Data) -> String { data.base64EncodedString() }

private func decodeLine(_ data: Data) -> String {
    guard let first = try? SnippetLibraryCodec.decode(data) else {
        return "decode\t\(base64(data))\tunreadable"
    }
    // A second decode a moment later exposes the timestamps that defaulted to "now".
    usleep(50)
    guard let second = try? SnippetLibraryCodec.decode(data), second.count == first.count else {
        fatalError("decoding the same bytes twice gave different outcomes")
    }
    let described = zip(first, second).map { describe($0, twin: $1) }
    return "decode\t\(base64(data))\tok\t\(described.joined(separator: "|"))"
}

func codecCorpusLines(environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "SnippetLibraryCodec results (Foundation JSONEncoder and JSONDecoder)",
        [
            "decode<TAB>base64 input<TAB>unreadable",
            "decode<TAB>base64 input<TAB>ok<TAB>snippets joined by |",
            "encode<TAB>snippets joined by |<TAB>base64 of encode()<TAB>base64 of encodeCollection()",
            "snippet = ID,name,keyword,content,tags joined by ;,isEnabled,isPinned,createdAt,updatedAt",
            "Strings are space-separated scalar values (- is empty); timestamps are the bit pattern of",
            "the Double (seconds since 2001) in hex, or now where the decoder used the current time.",
        ])
    var random = SeededRandom(seed: 0xC0DE_C001)

    // Encoding.
    let stamps: [Double] = [
        0, -0.0, 1, -1, 0.5, 0.1, 700_000_000, 700_000_000.25, 700_000_123.5, 817_319_319.570309,
        1e15, 1e16, 9_007_199_254_740_992, 9_007_199_254_740_994, 1e21, 1.5e300, 1e-4, 1e-5, 1.25e-7,
        5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, -700_000_000.125, 123_456_789.125,
        0.30000000000000004, 100, 1e22, 1e23, 4.35, 2.675, 1_000_000.5, 999_999_999_999_999.9,
    ]
    let jsonScalars: Scalars = [
        0x00, 0x01, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1B, 0x1F, 0x20, 0x22, 0x27, 0x2F, 0x3C,
        0x3E, 0x26, 0x5C, 0x7F, 0x80, 0x9F, 0xA0, 0xE9, 0x301, 0x2028, 0x2029, 0xFEFF, 0xFFFD, 0xFFFF,
        0x1F600, 0x10FFFF, 0x4E2D, 0x61, 0x62, 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C,
    ]
    func randomJSONText(maxLength: Int) -> String {
        makeString((0..<random.int(maxLength + 1)).map { _ in random.pick(jsonScalars) })
    }
    func randomSnippet() -> Snippet {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 { bytes[index] = UInt8(truncatingIfNeeded: random.next()) }
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let stamp: () -> Double = {
            random.int(4) == 0
                ? Double(bitPattern: random.next() & 0x7FEF_FFFF_FFFF_FFFF | (random.next() & 1) << 63)
                : random.pick(stamps)
        }
        return Snippet(
            id: id, name: randomJSONText(maxLength: 12), keyword: randomJSONText(maxLength: 6),
            content: randomJSONText(maxLength: 30),
            tags: (0..<random.int(4)).map { _ in randomJSONText(maxLength: 5) },
            isEnabled: random.bool(), isPinned: random.bool(),
            createdAt: Date(timeIntervalSinceReferenceDate: stamp()),
            updatedAt: Date(timeIntervalSinceReferenceDate: stamp()))
    }
    var libraries: [[Snippet]] = [[]]
    for _ in 0..<160 { libraries.append((0..<(1 + random.int(3))).map { _ in randomSnippet() }) }
    for library in libraries {
        guard let bare = try? SnippetLibraryCodec.encode(library),
              let wrapped = try? SnippetLibraryCodec.encodeCollection(library) else {
            fatalError("encoding a finite library failed")
        }
        lines.append("encode\t\(library.map { describe($0) }.joined(separator: "|"))\t\(base64(bare))\t\(base64(wrapped))")
        // What the encoder wrote must also decode, here and in Kotlin.
        lines.append(decodeLine(bare))
        lines.append(decodeLine(wrapped))
    }

    // Decoding: hand-written edge cases.
    let id = "\"id\":\"00000000-0000-4000-8000-000000000001\""
    let required = "\(id),\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\""
    func nested(_ depth: Int) -> String {
        String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    }
    var documents: [Data] = [
        "[{\(required)}]", " \n\t\r[ {\(required)} ] \n", "\u{FEFF}[{\(required)}]", "[{\(required)}] x",
        "[{\(required)},]", "[{\(required),}]", "[{\(required)}] // c", "[{\(required)},,]", "[,{\(required)}]",
        "[{,\(required)}]", "[{\(required),,}]", "[{\(required),\"name\":\"second\"}]",
        "[{\(required),\"id\":\"00000000-0000-4000-8000-000000000002\"}]",
        "[{\"name\":\"first\",\(required)}]", "[{\"na\\u006de\":\"escaped\",\(required)}]",
        "[{\(required),\"zzz\":{\"a\":[1,2,null]},\"secure\":true}]", "[{\(required),\"tags\":null}]",
        "[{\(required),\"isEnabled\":null,\"isPinned\":null,\"createdAt\":5,\"updatedAt\":null}]",
        "[{\(required),\"createdAt\":null,\"updatedAt\":7}]", "[{\(required),\"updatedAt\":7}]",
        "[{\(required),\"createdAt\":7}]", "[{\(id),\"name\":null,\"keyword\":\"k\",\"content\":\"c\"}]",
        "[{\(id),\"name\":\"n\",\"keyword\":\"k\"}]", "[{\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]",
        "[{\(required)},{\(required)}]", "{\"snippets\":[{\(required)}]}",
        "{\"version\":2,\"snippets\":[{\(required)}],\"x\":null}", "{\"snippets\":[],\"snippets\":[{\(required)}]}",
        "{\"snippets\":[{\(required)}],\"snippets\":[]}", "{\"snippets\":null}", "{}", "{\"snippets\":{}}",
        "{\"snippets\":[{\(required)}],\"bad\\xkey\":1}", "{\"snippets\":[{\(required)}],\"raw\tkey\":1}",
        "{\"snippets\":[{\(required)}],}", "{\"Snippets\":[{\(required)}]}", "{\"snippets\":[{\(required)}]}{}",
        "{\"snippets\":[{\"name\":\"Sig\",\"text\":\"Best, Ada\",\"keyword\":\"sig\"}]}",
        "[]", "[\n\n]", "[ ]", "[,]", "null", "\"x\"", "1", "", "  ", "[[]]", "[null]", "[1]", "[\"a\"]",
        "\u{A0}[]", "\u{0C}[]", "[]\u{0C}", "[{1:2}]", "[{'id':'x'}]", "[{id:\"x\"}]", "[{\(required)}",
        "[{\(required)]", "{\(required)}", "[{\(required)}]]", "[{\(required) \"x\":1}]", "[{\(required),\"x\"}]",
        "[{\(required),\"x\":}]", "[{\(required),\"x\" 1}]", "[{\(required)}{\(required)}]",
        "[{\(required),\"z\":\(nested(509))}]", "[{\(required),\"z\":\(nested(510))}]",
        "[{\(required),\"z\":\(nested(511))}]", nested(512), nested(513),
        "[{\"id\":\"00000000-0000-4000-8000-000000000001\\u0000tail\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]",
        "[{\"id\":\"00000000-0000-4000-8000-00000000000\\u0000\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]",
    ].map { Data($0.utf8) }
    func surround(_ bytes: [UInt8]) -> Data {
        Data(Array("[{\(id),\"name\":\"".utf8) + bytes + Array("\",\"keyword\":\"k\",\"content\":\"c\"}]".utf8))
    }
    documents += [
        surround([0xFF, 0xC3]), surround([0xC0, 0x80]), surround([0xED, 0xA0, 0x80]), surround([0xF4, 0x90, 0x80, 0x80]),
        surround([0xC3]), surround([0xEF, 0xBB, 0xBF]), surround([0x7F]), surround([0x1F]), surround([0x00]),
        Data([0xEF, 0xBB, 0xBF]), Data([0xEF, 0xBB]), Data([0xEF, 0xBB, 0xBF, 0x5B, 0x5D]),
        Data("[]".utf8) + Data([0x00]), Data([0x00]) + Data("[]".utf8),
    ]
    func utf16(_ text: String, bigEndian: Bool, mark: Bool) -> Data {
        var bytes: [UInt8] = mark ? (bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) : []
        for unit in text.utf16 {
            bytes += bigEndian ? [UInt8(unit >> 8), UInt8(unit & 0xFF)] : [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        return Data(bytes)
    }
    func utf32(_ text: String, bigEndian: Bool, mark: Bool) -> Data {
        var bytes: [UInt8] = mark ? (bigEndian ? [0x00, 0x00, 0xFE, 0xFF] : [0xFF, 0xFE, 0x00, 0x00]) : []
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let big = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            bytes += bigEndian ? big : big.reversed()
        }
        return Data(bytes)
    }
    let wide = ["[]", "[{\(required)}]", " [{\(required),\"name\":\"é😀\"}]", "[{\(id),\"name\":\"é😀\",\"keyword\":\"k\",\"content\":\"c\"}]", "1", "[", "{}"]
    for text in wide {
        for bigEndian in [true, false] {
            for mark in [true, false] {
                documents.append(utf16(text, bigEndian: bigEndian, mark: mark))
                documents.append(utf32(text, bigEndian: bigEndian, mark: mark))
            }
        }
    }
    // Damaged wide encodings: an odd byte, an unpaired surrogate, a value past U+10FFFF.
    documents += [
        utf16("[]", bigEndian: false, mark: true) + Data([0x20]),
        utf16("[]", bigEndian: true, mark: false) + Data([0x00]),
        Data([0xFF, 0xFE, 0x5B, 0x00, 0x22, 0x00, 0x00, 0xD8, 0x22, 0x00, 0x5D, 0x00]),
        Data([0xFF, 0xFE, 0x5B, 0x00, 0x00, 0xDC, 0x5D, 0x00]),
        Data([0x5B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00, 0x5D, 0x00, 0x00, 0x00]),
        utf32("[]", bigEndian: false, mark: false) + Data([0x20, 0x00]),
    ]
    // The same, where the damage sits in a name that is decoded, and Foundation's
    // reading of the four-byte marks.
    func wideUnits(_ units: [UInt16], bigEndian: Bool) -> Data {
        Data(units.flatMap { bigEndian ? [UInt8($0 >> 8), UInt8($0 & 0xFF)] : [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }
    func wideScalars(_ values: [UInt32], bigEndian: Bool) -> Data {
        Data(values.flatMap { value -> [UInt8] in
            let big = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
            return bigEndian ? big : big.reversed()
        })
    }
    let before = Array("[{\(id),\"keyword\":\"k\",\"content\":\"c\",\"createdAt\":1,\"name\":\"a".utf16)
    let after = Array("b\"}]".utf16)
    for bigEndian in [false, true] {
        for middle in [[], [0xD83D], [0xDE00], [0xDE00, 0xD83D], [0xD83D, 0xDE00], [0xFFFE], [0xFEFF], [0x0000]] as [[UInt16]] {
            documents.append(wideUnits(before + middle + after, bigEndian: bigEndian))
        }
        documents.append(wideUnits(before + after, bigEndian: bigEndian) + Data([0x20]))
        documents.append(wideUnits(before + after + [0xD83D], bigEndian: bigEndian))
        for middle in [[], [0xD83D], [0x110000], [0x1F600], [0xFFFFFFFF]] as [[UInt32]] {
            documents.append(wideScalars(before.map(UInt32.init) + middle + after.map(UInt32.init), bigEndian: bigEndian))
        }
        for extra in 1...3 {
            documents.append(wideScalars((before + after).map(UInt32.init), bigEndian: bigEndian) + Data(repeating: 0x20, count: extra))
            documents.append(wideScalars((before + after).map(UInt32.init), bigEndian: bigEndian) + Data(repeating: 0x00, count: extra))
        }
        documents.append(Data([0xFF, 0xFE, 0x00, 0x00]) + wideScalars([0x5B, 0x5D], bigEndian: bigEndian))
        documents.append(Data([0xFE, 0xFF, 0x00, 0x00]) + wideScalars([0x5B, 0x5D], bigEndian: bigEndian))
        documents.append(Data([0x00, 0x00, 0xFE, 0xFF]) + wideScalars([0x5B, 0x5D], bigEndian: bigEndian))
        documents.append(Data([0x00, 0x00, 0xFF, 0xFE]) + wideScalars([0x5B, 0x5D], bigEndian: bigEndian))
    }
    documents.append(Data([0xFE, 0xFF, 0x00, 0x5B, 0x00, 0x5D]))
    documents.append(Data([0xFF, 0xFE, 0x5B, 0x00, 0x5D, 0x00, 0x00]))
    for document in documents { lines.append(decodeLine(document)) }

    // Decoding: one record assembled from interesting spellings of every part.
    let ids = [
        "\"00000000-0000-4000-8000-000000000001\"", "\"abcdefab-cdef-4abc-8def-abcdefabcdef\"",
        "\"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF\"", "\"AbCdEfAb-cDeF-4aBc-8DeF-aBcDeFaBcDeF\"",
        "\"abcdefabcdef4abc8defabcdefabcdef\"", "\"{abcdefab-cdef-4abc-8def-abcdefabcdef}\"",
        "\"abcdefab-cdef-4abc-8def-abcdefabcdef \"", "\" abcdefab-cdef-4abc-8def-abcdefabcdef\"",
        "\"1-1-1-1-1\"", "\"gbcdefab-cdef-4abc-8def-abcdefabcdef\"", "\"abcdefa-bcdef-4abc-8def-abcdefabcdef\"",
        "\"\\u0061bcdefab-cdef-4abc-8def-abcdefabcdef\"", "\"abcdefab-cdef-4abc-8def-abcdefabcdefX\"",
        "\"\"", "5", "null", "\"abcdefab-cdef-4abc-8def-abcdefabcde\\u0000\"",
        "\"abcdefab-cdef-4abc-8def-abcdefabcdef\\u0000\"", "\"abcdefab-cdef-4abc-8def-abcdefabcdef\\u0000zz\"",
        "\"abcdefab_cdef_4abc_8def_abcdefabcdef\"", "\"１bcdefab-cdef-4abc-8def-abcdefabcdef\"",
    ]
    let strings = [
        "\"n\"", "\"\"", "\"\\u00e9\"", "\"\\u00E9\\/\\\\\\\"\"", "\"\\ud83d\\ude00\"", "\"\\uD83D\\uDE00\"",
        "\"\\ud83d\"", "\"\\ude00\"", "\"\\ud83d\\u0041\"", "\"\\ud83dx\"", "\"a\\u0000b\"", "\"\\x\"",
        "\"raw\ttab\"", "\"raw\nnewline\"", "\"raw\u{7F}delete\"", "\"\\b\\f\\n\\r\\t\"", "\"é😀\u{2028}\"",
        "\"\\u12\"", "\"\\u12G4\"", "\"\\u 123\"", "\"\\U0041\"", "\"\\'\"", "\"\\0\"", "\"\\\"", "null",
        "1", "true", "[]", "{}", "\"e\\u0301\"", "\"\\ufeff\"", "\"\\uffff\"",
    ]
    let numbers = [
        "0", "-0", "-0.0", "5", "5.0", "5e2", "5E2", "5e+2", "5e-2", "1E+2", "0.1", "700000000.25",
        "0.1000000000000000055511151231257827021181583404541015625", "123456789012345678901234567890",
        "1e308", "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308", "1.8e308",
        "1e999", "-1e999", "1e-999", "5e-324", "4.9e-324", "3e-324", "2.5e-324", "2.4e-324", "2e-324",
        "1e-320", "2.2250738585072011e-308", "2.2250738585072014e-308", "0e999", "0.0e-999", "-0e5",
        "0.000", "00", "01", "-01", "0x10", "+1", ".5", "1.", "1.e5", "1e", "1e+", "-", "--1", "1.2.3",
        "1e5e5", "1e5.5", "1-1", "1+1", "1e05", "1.0e-005", "0e", "0.", "-.5", "- 1", "1 2", "1e 5",
        "NaN", "Infinity", "-Infinity", "nan", "inf", "true", "false", "null", "\"5\"", "[5]", "{}",
        "1E400", "9" + String(repeating: "9", count: 400), "0." + String(repeating: "0", count: 400) + "1",
        "1" + String(repeating: "0", count: 308), "1" + String(repeating: "0", count: 309),
        "0.5e1", "5e0", "5E-0", "100e-2", "9007199254740993", "-9007199254740993", "4.35", "1e23",
    ]
    let unknownValues = [
        "1", "01", "-", "--", "-e", "-.", "1.2.3", "1e", "1+", "1-1", "9e9e9", "0x10", "+1", ".5", "NaN", "1x",
        "\"\\x\"", "\"\\ud83d\"", "\"raw\u{01}control\"", "\"raw\ttab\"", "\"\\u12\"", "\"\\u\\u\\u\\u\"",
        "\"\\u\"\"", "\"\\uzzzz\"", "\"\\\"", "\"unterminated", "{\"a\":[1,2,{\"b\":null}]}", "[,]", "[1,]",
        "[1,,2]", "{\"a\":1,}", "{,}", "{\"a\"}", "{\"a\":}", "{1:2}", "'x'", "nul", "null", "nulll", "tru",
        "true", "truefalse", "false", "False", "[\"\\x\",01,-]", "{\"\\x\":1}", "{\"a\":1,\"a\":2}", "[] []",
        "\"é\"", "1e999", "-0", "[[[[[]]]]]", "{\"k\":\"v\"} ", " 7 ", "\"\\u0000\"", "",
    ]
    let tagValues = [
        "[]", "[\"a\"]", "[\"a\",\"A\",\" b  c \"]", "null", "\"a\"", "[1]", "[null]", "[\"a\",]", "[[\"a\"]]",
        "{}", "[\"\\u00e9\",\"e\\u0301\",\"E\"]", "[\"\",\" \",\"x\"]", "[\"a\" \"b\"]", "[\"\\x\"]", "[\"a\",1]",
        "[\"Work\",\"work\",\"WORK\"]", "[true]", "[\"a\tb\"]", "[\"\\ta\\nb \"]",
    ]
    let flags = ["true", "false", "null", "1", "0", "\"true\"", "[]", "TRUE", "tru", "true "]
    let separators = [",", " , ", ",\n  ", "\t,\t"]
    let colons = [":", " : ", ": ", "\t:\n"]
    for _ in 0..<2_600 {
        var members: [(String, String)] = []
        func member(_ key: String, _ value: String, omit: Int) {
            if random.int(omit) != 0 { members.append((key, value)) }
        }
        // Mostly valid parts, so a case is usually decided by a single odd one.
        func usually(_ ordinary: String, _ choices: [String]) -> String {
            random.int(5) == 0 ? random.pick(choices) : ordinary
        }
        member("id", usually(ids[random.int(4)], ids), omit: 40)
        member("name", usually("\"n\"", strings), omit: 40)
        member("keyword", usually("\"k\"", strings), omit: 40)
        member("content", usually("\"c\"", strings), omit: 40)
        member("tags", usually("[\"t\"]", tagValues), omit: 4)
        member("isEnabled", usually("false", flags), omit: 3)
        member("isPinned", usually("true", flags), omit: 3)
        member("createdAt", usually("5", numbers), omit: 3)
        member("updatedAt", usually("7.5", numbers), omit: 3)
        if random.int(2) == 0 { members.append(("zzz", random.pick(unknownValues))) }
        if random.int(12) == 0, let again = members.randomElement(using: &random.generator) {
            members.append((again.0, random.pick(strings + numbers + flags)))
        }
        if random.int(3) == 0 { members.shuffle(using: &random.generator) }

        let colon = random.pick(colons), separator = random.pick(separators)
        var object = "{" + members.map { "\"\($0.0)\"\(colon)\($0.1)" }.joined(separator: separator)
        if random.int(15) == 0 { object += "," }
        object += "}"
        var document = "[" + object + "]"
        switch random.int(12) {
        case 0: document = "{\"snippets\":" + document + "}"
        case 1: document = "[" + object + "," + object + "]"
        case 2: document = " " + document + "\n"
        default: break
        }
        lines.append(decodeLine(Data(document.utf8)))
    }

    // Decoding: valid documents with random byte damage.
    // Compact, and with sorted keys: an unsorted encoder orders keys differently in every process.
    let compactEncoder = JSONEncoder()
    compactEncoder.outputFormatting = [.sortedKeys]
    let sources: [Data] = libraries.prefix(12).compactMap { try? SnippetLibraryCodec.encode($0) }
        + libraries.prefix(6).compactMap { try? compactEncoder.encode($0) }
        + libraries.prefix(4).compactMap { try? SnippetLibraryCodec.encodeCollection($0) }
    let alphabet = Array("{}[]\",:\\/ \n\t0123456789.-+eEtfnulraxs".utf8) + [0x00, 0x1F, 0x7F, 0xC3, 0xA9, 0xFF, 0xEF]
    for _ in 0..<700 {
        var bytes = Array(random.pick(sources))
        for _ in 0..<(1 + random.int(2)) where !bytes.isEmpty {
            let position = random.int(bytes.count)
            switch random.int(6) {
            case 0: bytes.remove(at: position)
            case 1: bytes.insert(random.pick(alphabet), at: position)
            case 2: bytes[position] = random.pick(alphabet)
            case 3: bytes.removeSubrange(position..<min(bytes.count, position + 1 + random.int(8)))
            case 4:
                let end = min(bytes.count, position + 1 + random.int(12))
                bytes.insert(contentsOf: bytes[position..<end], at: position)
            default: bytes.removeSubrange(position...)
            }
        }
        lines.append(decodeLine(Data(bytes)))
    }
    return lines
}

extension SeededRandom {
    /// `RandomNumberGenerator` view, for `shuffle(using:)` and `randomElement(using:)`.
    struct Generator: RandomNumberGenerator {
        var random: SeededRandom
        mutating func next() -> UInt64 { random.next() }
    }

    var generator: Generator {
        get { Generator(random: self) }
        set { self = newValue.random }
    }
}
