import Foundation

// Tables for `SnippetTagging.filterKey`, which is
// `String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: en_US_POSIX)`.
//
// Foundation folds a string one "character cluster" at a time (CoreFoundation's
// `CFStringFold`). A cluster is one scalar plus the non-base scalars that follow it, and
// what happens to those followers depends on the scalar that leads the cluster. So the
// whole-string result is not the concatenation of per-scalar folds. Everything the rule
// needs is measured here by calling Foundation, then the rule is replayed by `FoldModel`
// and compared with Foundation over a few million strings before anything is written.

/// The fold the app uses, called through the app's own source file.
@inline(__always)
func foundationFold(_ values: Scalars) -> Scalars {
    scalarValues(SnippetTagging.filterKey(for: makeString(values)))
}

struct FoldTables {
    /// Fold of a scalar that stands alone, where it differs from the scalar.
    var base: [UInt32: Scalars] = [:]
    /// Scalars Foundation attaches to the scalar before them ("non-base").
    var nonBase = [Bool](repeating: false, count: 0x110000)
    /// Canonical combining class used to order the kept non-base scalars.
    var priority = [UInt8](repeating: 0, count: 0x110000)
    /// What a kept non-base scalar is replaced by, where that is not itself.
    var markDecomposition: [UInt32: Scalars] = [:]
    /// Free buffer slots a decomposing mark needs before it is taken into a cluster.
    /// CoreFoundation checks the space once per level of a nested decomposition, so
    /// this can exceed the number of scalars the mark turns into.
    var markSpace: [UInt32: Int] = [:]

    func space(for mark: UInt32) -> Int { markSpace[mark] ?? 1 }
}

/// Marks at or below this value are dropped when they are the first follower of an
/// unchanged leading scalar; leading scalars below `stripLimit` drop every follower.
let lowMarkLimit: UInt32 = 0x050F
let stripLimit: UInt32 = 0x0510
/// CoreFoundation folds a cluster in a buffer of this many scalars.
let clusterBufferLength = 64

private let lowProbeMark: UInt32 = 0x0301    // non-base, at or below lowMarkLimit
private let highProbeMark: UInt32 = 0x0591   // non-base, above lowMarkLimit, no decomposition
private let keepAllBase: UInt32 = 0x10A0     // folds to U+2D00 and keeps every follower
private let keepAllBaseFolded: UInt32 = 0x2D00
private let classZeroMark: UInt32 = 0x20DD   // non-base, class 0, above lowMarkLimit
private let classOneMark: UInt32 = 0x20D2    // non-base, lowest non-zero class, above lowMarkLimit

func probeFoldTables() -> FoldTables {
    var tables = FoldTables()

    // 1. Non-base scalars: after an ASCII letter every follower is dropped.
    for mark in allScalars where foundationFold([0x61, mark]) == [0x61] {
        tables.nonBase[Int(mark)] = true
    }
    require(tables.nonBase[Int(lowProbeMark)] && tables.nonBase[Int(highProbeMark)]
        && tables.nonBase[Int(classZeroMark)] && tables.nonBase[Int(classOneMark)],
        "a probe mark is no longer a non-base scalar")

    // 2. The fold of each scalar on its own.
    for scalar in allScalars {
        let folded = foundationFold([scalar])
        if folded != [scalar] { tables.base[scalar] = folded }
    }
    require(tables.base[keepAllBase] == [keepAllBaseFolded], "U+10A0 no longer folds to U+2D00")

    // 3. What the leading scalar does to its followers follows from its own fold. Check
    //    that for every scalar, so the Kotlin side can derive it instead of storing it:
    //    - last scalar of the fold below U+0510: every follower is dropped;
    //    - otherwise, fold differs from the scalar: every follower is kept;
    //    - otherwise: followers are kept, except a first follower at or below U+050F.
    //    U+0000 never leads a cluster.
    for scalar in allScalars where scalar != 0 {
        let folded = tables.base[scalar] ?? [scalar]
        let withLow = foundationFold([scalar, lowProbeMark])
        let withHigh = foundationFold([scalar, highProbeMark])
        let strips = folded.last! < stripLimit
        if strips {
            require(withLow == folded && withHigh == folded,
                "U+\(hex(scalar)) should drop its followers")
        } else if tables.base[scalar] != nil {
            require(withLow.count == folded.count + 1 && withHigh.count == folded.count + 1,
                "U+\(hex(scalar)) should keep every follower")
        } else {
            require(withLow == folded && withHigh.count == folded.count + 1,
                "U+\(hex(scalar)) should drop only a low first follower")
        }
    }
    require(foundationFold([0, lowProbeMark]) == [0, lowProbeMark]
        && foundationFold([0, highProbeMark, lowProbeMark]) == [0, highProbeMark],
        "U+0000 should not lead a cluster")

    // 4. Kept followers are canonically decomposed.
    for mark in allScalars where tables.nonBase[Int(mark)] {
        let folded = foundationFold([keepAllBase, mark])
        require(folded.first == keepAllBaseFolded, "unexpected fold after U+10A0")
        let kept = Array(folded.dropFirst())
        if kept != [mark] { tables.markDecomposition[mark] = kept }
    }
    for (mark, pieces) in tables.markDecomposition {
        require(!pieces.isEmpty && pieces.allSatisfy { tables.nonBase[Int($0)] },
            "U+\(hex(mark)) decomposes into something that is not a non-base scalar")
    }

    // 5. Kept followers are stably sorted by combining class. Build a ladder with one
    //    representative per class and place every non-base scalar on it by asking
    //    Foundation to order pairs.
    func keepsOrder(_ first: UInt32, _ second: UInt32) -> Bool {
        foundationFold([keepAllBase, first, second]) == [keepAllBaseFolded, first, second]
    }
    var representative: [UInt8: UInt32] = [:]
    for mark in allScalars where tables.nonBase[Int(mark)] && tables.markDecomposition[mark] == nil {
        let combiningClass = Unicode.Scalar(mark)!.properties.canonicalCombiningClass.rawValue
        if representative[combiningClass] == nil { representative[combiningClass] = mark }
    }
    let ladder = representative.keys.sorted()
    require(ladder.first == 0, "no class 0 representative")
    for (lower, higher) in zip(ladder, ladder.dropFirst()) {
        let a = representative[lower]!, b = representative[higher]!
        require(keepsOrder(a, b) && !keepsOrder(b, a),
            "classes \(lower) and \(higher) are not ordered as expected")
    }
    for mark in allScalars where tables.nonBase[Int(mark)] && tables.markDecomposition[mark] == nil {
        func ties(_ combiningClass: UInt8) -> Bool {
            let other = representative[combiningClass]!
            return keepsOrder(mark, other) && keepsOrder(other, mark)
        }
        let guess = Unicode.Scalar(mark)!.properties.canonicalCombiningClass.rawValue
        if representative[guess] != nil, ties(guess) {
            tables.priority[Int(mark)] = guess
        } else if let found = ladder.first(where: ties) {
            tables.priority[Int(mark)] = found
        } else {
            require(false, "U+\(hex(mark)) has a combining class outside the ladder")
        }
    }

    // 6. Everything else must sort as class 0. A scalar can only be observed in the
    //    sorted run as its first element, which is enough to rule out a non-zero class.
    for scalar in allScalars where scalar != 0 {
        let isPlainMark = tables.nonBase[Int(scalar)] && tables.markDecomposition[scalar] == nil
        if isPlainMark { continue }
        let folded = tables.base[scalar] ?? [scalar]
        if folded.last! < stripLimit { continue }
        require(foundationFold([scalar, classZeroMark]) == folded + [classZeroMark]
            && foundationFold([scalar, classOneMark]) == folded + [classOneMark],
            "U+\(hex(scalar)) sorts after a follower, so it has a non-zero class")
    }

    // 7. A decomposing mark joins a cluster only while enough of the 64-scalar buffer is
    //    free, and CoreFoundation asks for more than the mark's final length when the
    //    decomposition is nested. Fill the buffer to each level near the end and keep the
    //    one requirement for which the rule reproduces Foundation at every level.
    for (mark, pieces) in tables.markDecomposition {
        var matching: [Int] = []
        for candidate in pieces.count...8 {
            var trial = tables
            trial.markSpace[mark] = candidate
            let model = FoldModel(tables: trial)
            let agrees = (1...9).allSatisfy { free in
                // U+05D0 leads, class-0 marks fill the buffer until `free` slots are left,
                // and a low-class mark after the probe shows which cluster it ended up in.
                let filler = Scalars(repeating: classZeroMark, count: clusterBufferLength - 1 - free)
                let input = [0x05D0] + filler + [mark, 0x05B0, highProbeMark]
                return model.fold(input) == foundationFold(input)
            }
            if agrees { matching.append(candidate) }
        }
        require(matching.count == 1, "could not measure the space U+\(hex(mark)) needs: \(matching)")
        tables.markSpace[mark] = matching[0]
    }

    return tables
}

/// The rule, replayed from the tables. `FoundationText.fold` in Kotlin is this function.
struct FoldModel {
    let tables: FoldTables

    func fold(_ input: Scalars) -> Scalars {
        var output: Scalars = []
        output.reserveCapacity(input.count)
        var index = 0
        let count = input.count

        @inline(__always) func isNonBase(_ value: UInt32) -> Bool { tables.nonBase[Int(value)] }

        while index < count {
            let lead = input[index]
            index += 1
            if lead == 0 {
                output.append(0)
                continue
            }

            let mapped = tables.base[lead]
            var buffer = mapped ?? [lead]

            if buffer[buffer.count - 1] < stripLimit {
                while index < count, isNonBase(input[index]) { index += 1 }
                output += buffer
                continue
            }

            if mapped == nil {
                guard index < count, isNonBase(input[index]) else {
                    output.append(lead)
                    continue
                }
                let first = input[index]
                index += 1
                if first > lowMarkLimit { buffer += tables.markDecomposition[first] ?? [first] }
            }

            while buffer.count < clusterBufferLength, index < count, isNonBase(input[index]) {
                let pieces = tables.markDecomposition[input[index]] ?? [input[index]]
                if tables.space(for: input[index]) > clusterBufferLength - buffer.count { break }
                buffer += pieces
                index += 1
            }

            if buffer.count > 1 {
                var start = buffer.count - 1
                while start > 0, isNonBase(buffer[start]) { start -= 1 }
                if buffer.count - start > 1 {
                    // Stable: equal classes keep their order.
                    let sorted = buffer[start...].enumerated().sorted { a, b in
                        let pa = tables.priority[Int(a.element)], pb = tables.priority[Int(b.element)]
                        return pa != pb ? pa < pb : a.offset < b.offset
                    }.map { $0.element }
                    buffer.replaceSubrange(start..., with: sorted)
                }
            }
            output += buffer
        }
        return output
    }
}

/// Pools the random strings are drawn from, chosen so every branch of the rule is hit.
struct FoldPools {
    var stripBases: Scalars = []
    var keepAllBases: Scalars = []
    var plainBases: Scalars = []
    var lowMarks: Scalars = []
    var highMarks: Scalars = []
    var decomposingMarks: Scalars = []
    let specials: Scalars = [
        0x0000, 0x0020, 0x200C, 0x200D, 0xFE0F, 0x20DD, 0x20D2, 0x0345, 0x0307, 0x0049, 0x0130,
        0x0131, 0x00DF, 0x1E9E, 0x03A3, 0x03C2, 0xFB01, 0x0149, 0x1F468, 0x1F469, 0x1F3FB,
        0x1F1E6, 0xAC00, 0x1100, 0x1161, 0x11A8, 0x304B, 0x3099, 0x0627, 0x0654, 0x0915, 0x093C,
        0x094D, 0x05D0, 0x05B8, 0x0F3E, 0x0F71, 0x0F73, 0x1D165, 0x1D15E, 0xFF21, 0x212B,
    ]

    init(_ tables: FoldTables) {
        for scalar in allScalars where scalar != 0 {
            let isNonBase = tables.nonBase[Int(scalar)]
            if isNonBase {
                if tables.markDecomposition[scalar] != nil {
                    decomposingMarks.append(scalar)
                } else if scalar <= lowMarkLimit {
                    lowMarks.append(scalar)
                } else {
                    highMarks.append(scalar)
                }
                continue
            }
            let folded = tables.base[scalar] ?? [scalar]
            if folded.last! < stripLimit {
                // Thousands of unassigned scalars would otherwise drown the letters.
                if scalar < 0x2000 || tables.base[scalar] != nil { stripBases.append(scalar) }
            } else if tables.base[scalar] != nil {
                keepAllBases.append(scalar)
            } else if Unicode.Scalar(scalar)!.properties.generalCategory != .unassigned,
                      Unicode.Scalar(scalar)!.properties.generalCategory != .privateUse {
                plainBases.append(scalar)
            }
        }
    }

    func randomString(_ random: inout SeededRandom, maxLength: Int) -> Scalars {
        let length = 1 + random.int(maxLength)
        var values: Scalars = []
        values.reserveCapacity(length)
        for _ in 0..<length {
            switch random.int(20) {
            case 0...2: values.append(random.pick(stripBases))
            case 3...4: values.append(random.pick(keepAllBases))
            case 5...7: values.append(random.pick(plainBases))
            case 8...10: values.append(random.pick(lowMarks))
            case 11...14: values.append(random.pick(highMarks))
            case 15: values.append(random.pick(decomposingMarks))
            case 16...17: values.append(random.pick(specials))
            case 18: values.append(UInt32(0x20 + random.int(0x5F)))
            default: values.append(random.pick(allScalars))
            }
        }
        return values
    }
}

/// Compares the model with Foundation. Returns the number of strings checked.
func verifyFoldModel(_ tables: FoldTables) -> Int {
    let model = FoldModel(tables: tables)
    let pools = FoldPools(tables)
    var checked = 0

    func check(_ input: Scalars) {
        let expected = foundationFold(input)
        let actual = model.fold(input)
        checked += 1
        require(expected == actual,
            "fold model mismatch for [\(hex(input))]: Foundation [\(hex(expected))], model [\(hex(actual))]")
    }

    // Every scalar alone, and with low/high followers in both orders.
    for scalar in allScalars {
        check([scalar])
        check([scalar, lowProbeMark, highProbeMark])
        check([scalar, highProbeMark, lowProbeMark])
        check([scalar, 0x05B0, highProbeMark, 0x0327, lowProbeMark])
    }

    // Every non-base scalar after one base of each kind, alone and between two others.
    let bases: Scalars = [0x61, 0x00E9, 0x03A9, 0x0416, 0x05D0, 0x0627, 0x0915, 0x4E2D, 0xAC00,
                          0x10A0, 0x13A0, 0x0531, 0x10400, 0x1F600, 0x0F40, 0x0591]
    for mark in allScalars where tables.nonBase[Int(mark)] {
        for base in bases {
            check([base, mark])
            check([base, highProbeMark, mark, 0x05B0])
            check([base, mark, mark, classOneMark])
        }
    }

    // Random strings.
    var random = SeededRandom(seed: 0xF01D_0001)
    for _ in 0..<2_000_000 { check(pools.randomString(&random, maxLength: 9)) }

    // Runs longer than the cluster buffer, with classes mixed so the split shows.
    for base in bases {
        for length in [60, 62, 63, 64, 65, 66, 100, 127, 128, 129, 200, 300] {
            var values: Scalars = [base]
            for position in 0..<length {
                values.append(position % 2 == 0 ? highProbeMark : 0x05B0)
            }
            check(values)
            values.insert(0x0F73, at: 1 + length / 2)
            check(values)
        }
    }
    for _ in 0..<20_000 {
        var values: Scalars = [random.pick(pools.plainBases + pools.keepAllBases)]
        let length = 40 + random.int(120)
        for _ in 0..<length {
            switch random.int(8) {
            case 0: values.append(random.pick(pools.decomposingMarks))
            case 1: values.append(random.pick(pools.lowMarks))
            default: values.append(random.pick(pools.highMarks))
            }
        }
        check(values)
    }
    return checked
}

func foldResourceLines(_ tables: FoldTables, environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "Foundation fold tables for String.folding([.caseInsensitive, .diacriticInsensitive], en_US_POSIX)",
        [
            "Sections: [base] scalar -> fold of that scalar alone; [nonbase] scalars attached to",
            "the scalar before them; [priority] combining class of non-base scalars (0 if absent);",
            "[markdecomposition] mark, free buffer slots it needs, replacement of the kept mark.",
            "The rule that uses them is FoundationText.fold; see tools/foundation-tables/README.md.",
            "cluster-buffer: \(clusterBufferLength)",
        ])

    lines.append("[base]")
    for scalar in tables.base.keys.sorted() {
        lines.append("\(hex(scalar)) \(hex(tables.base[scalar]!))")
    }
    lines.append("[nonbase]")
    lines += rangeLines(skip: false, key: { tables.nonBase[Int($0)] }, format: { _ in "" })
    lines.append("[priority]")
    lines += rangeLines(skip: 0, key: { tables.priority[Int($0)] }, format: { String($0) })
    lines.append("[markdecomposition]")
    for mark in tables.markDecomposition.keys.sorted() {
        lines.append("\(hex(mark)) \(tables.space(for: mark)) \(hex(tables.markDecomposition[mark]!))")
    }
    return lines
}

/// `input<TAB>output`, both as scalar values, straight from Foundation.
func foldCorpusLines(_ tables: FoldTables, environment: GeneratorEnvironment) -> [String] {
    var seen = Set<Scalars>()
    var cases: [Scalars] = []
    func add(_ values: Scalars) {
        if seen.insert(values).inserted { cases.append(values) }
    }
    func add(_ text: String) { add(scalarValues(text)) }

    // Hand-picked: the cases the porting brief names, and each branch of the rule.
    let words = [
        "", "WORK", "work", "Work", "CAFÉ", "café", "Cafe\u{301}", "İstanbul", "istanbul", "ISTANBUL",
        "Iı-İi", "I\u{307}", "ı", "Straße", "STRASSE", "ẞ", "ﬁnance", "ﬃ", "ŉ", "ǅ", "Ǆ", "ǆ",
        "ΣΊΣΥΦΟΣ", "σίσυφος", "Σίσυφος", "ς", "Ω", "\u{2126}", "ΐ", "Ά", "ᾳ", "ᾼ", "ῼ",
        "Привет", "ПРИВЕТ", "Ёлка", "ёлка", "Йод", "йод", "Ђ", "Ѐ", "ѝ",
        "Å", "\u{212B}", "A\u{30A}", "ø", "Ø", "đ", "Đ", "ł", "Ł", "ñ", "Ñ", "ç", "Ç", "ü", "Ü",
        "ＡＢＣ", "ａｂｃ", "１２３", "ｶﾞ", "が", "か\u{3099}", "ガ", "ぱ", "は\u{309A}", "ヴ",
        "日本語", "中文", "한국어", "한\u{301}", "\u{1100}\u{1161}\u{11A8}", "각",
        "العربية", "آ", "ا\u{653}", "أ", "ا\u{654}", "إ", "لا", "مُحَمَّد", "ﷺ",
        "עברית", "שָׁלוֹם", "א\u{5B8}", "א\u{301}", "א\u{591}\u{5B0}", "א\u{5B0}\u{591}",
        "हिन्दी", "क़", "क\u{93C}", "क्ष", "বাংলা", "தமிழ்", "తెలుగు", "ಕನ್ನಡ", "മലയാളം", "ไทย", "ກຂຄ",
        "བོད་ཡིག", "\u{F40}\u{F73}", "\u{F40}\u{F71}\u{F72}", "\u{F73}", "မြန်မာ", "ខ្មែរ",
        "ᎠᎡᎢ", "ꭰꭱꭲ", "ᏸ", "Ⴀ", "ⴀ", "ა", "Ա", "ա", "և", "ﬓ", "𐐀", "𐐨", "𞤀", "𞤢",
        "👨‍👩‍👧‍👦", "👩🏽‍💻", "🇩🇪", "🇺🇸🇬🇧", "👍🏿", "❤️", "❤", "☺️", "#️⃣", "🏳️‍🌈", "🧑‍🤝‍🧑",
        "a\u{FE0F}", "x\u{20DD}", "a\u{301}\u{301}", "\u{301}", "\u{301}\u{301}", "\u{301}a",
        "a\u{345}", "\u{345}", "A\u{345}\u{301}", "e\u{327}\u{301}", "e\u{301}\u{327}",
        "\u{0}", "a\u{0}b", "\u{0}\u{301}", "A\u{0}\u{301}B", "a\u{200D}\u{301}", "a\u{200C}b",
        "Ⅰ", "ⅰ", "Ⓐ", "ⓐ", "Ⱥ", "ⱥ", "Ⱦ", "Ȿ", "ẚ", "ǰ", "ẖ", "ʼn", "K", "\u{212A}", "ſ", "ﬅ",
        "Łódź", "ŁÓDŹ", "Đà Nẵng", "ĐÀ NẴNG", "Tiếng Việt", "TIẾNG VIỆT", "Smörgåsbord", "naïve",
        "NAÏVE", "résumé", "RÉSUMÉ", "Zürich", "ZÜRICH", "São Paulo", "SÃO PAULO", "Ångström",
        "Dvořák", "DVOŘÁK", "Æther", "æther", "Œuvre", "œuvre", "Þór", "þór", "Ĳ", "ĳ",
        "tag with spaces", "Tag-With-Dashes", "tag_with_underscores", "UPPER lower 123",
        "tr-I", "az-İ", "lt-Į", "į\u{307}", "J\u{307}", "i\u{307}", "Ì", "Í", "Ĩ",
    ]
    for word in words {
        add(word)
        add(word.uppercased())
        add(word.lowercased())
        add(word.decomposedStringWithCanonicalMapping)
        add(word.precomposedStringWithCanonicalMapping)
        add(word.uppercased().decomposedStringWithCanonicalMapping)
    }

    // A sample of the scalars whose own fold changes, alone and with followers.
    for (position, scalar) in tables.base.keys.sorted().enumerated() where position % 6 == 0 {
        add([scalar])
        add([scalar, 0x0301])
        add([scalar, 0x0591, 0x05B0])
        add([0x61, scalar, 0x62])
    }

    // Each non-base scalar that is replaced when kept, and one of every combining class.
    var classesSeen = Set<UInt8>()
    for mark in allScalars where tables.nonBase[Int(mark)] {
        let isNewClass = classesSeen.insert(tables.priority[Int(mark)]).inserted
        if tables.markDecomposition[mark] != nil || isNewClass {
            add([0x05D0, mark])
            add([0x10A0, 0x0591, mark, 0x05B0])
            add([0x61, mark])
            add([mark, 0x0591])
        }
    }

    // Random strings from the same pools the model was verified with.
    let pools = FoldPools(tables)
    var random = SeededRandom(seed: 0xF01D_C0DE)
    for _ in 0..<2_600 { add(pools.randomString(&random, maxLength: 10)) }

    // Long strings: repeated text, and runs that cross the cluster buffer.
    add(String(repeating: "Größe ÇA İstanbul Ελληνικά Кириллица עִבְרִית ", count: 60))
    add(String(repeating: "e\u{301}", count: 500))
    add("a" + String(repeating: "\u{301}", count: 400))
    for base in [UInt32(0x05D0), 0x10A0, 0x0915, 0x1F600] {
        for length in [62, 63, 64, 65, 130, 300] {
            var values: Scalars = [base]
            for position in 0..<length { values.append(position % 2 == 0 ? 0x0591 : 0x05B0) }
            add(values)
            values.insert(0x0F73, at: 1 + length / 2)
            add(values)
        }
    }
    for _ in 0..<40 {
        var values: Scalars = []
        for _ in 0..<(200 + random.int(600)) { values += pools.randomString(&random, maxLength: 3) }
        add(values)
    }

    var lines = environment.header(
        "Foundation results for SnippetTagging.filterKey (whole-string fold)",
        ["input<TAB>output, as space-separated scalar values; - is the empty string"])
    for input in cases {
        lines.append("\(hex(input))\t\(hex(foundationFold(input)))")
    }
    return lines
}
