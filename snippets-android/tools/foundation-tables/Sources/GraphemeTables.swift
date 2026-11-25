import Foundation

// Extended grapheme clusters as the Swift standard library draws them (`Character`,
// `String.count`, `prefix`, `removeFirst`, `hasPrefix`).
//
// Swift does not publish the properties its segmenter uses, so they are measured: every
// scalar is put into short strings whose `count` reveals its class. The segmenter's
// rules are then replayed by `GraphemeModel` from those classes and compared with Swift
// over a few million strings before anything is written.

enum GraphemeClass: UInt8, CaseIterable {
    case other = 0
    case carriageReturn, lineFeed, control
    case extend, zeroWidthJoiner, regionalIndicator, prepend, spacingMark
    case hangulL, hangulV, hangulT, hangulLV, hangulLVT
    case extendedPictographic
}

struct GraphemeTables {
    /// `GraphemeClass` raw value in the low four bits, then the three Indic flags.
    var value = [UInt8](repeating: 0, count: 0x110000)

    static let consonantFlag: UInt8 = 0x10      // Indic_Conjunct_Break=Consonant
    static let linkerFlag: UInt8 = 0x20         // Indic_Conjunct_Break=Linker
    static let conjunctExtendFlag: UInt8 = 0x40 // an Extend that may sit inside a conjunct

    @inline(__always) func graphemeClass(_ scalar: UInt32) -> GraphemeClass {
        GraphemeClass(rawValue: value[Int(scalar)] & 0x0F)!
    }
    @inline(__always) func has(_ flag: UInt8, _ scalar: UInt32) -> Bool {
        value[Int(scalar)] & flag != 0
    }
}

@inline(__always)
private func characterCount(_ values: Scalars) -> Int { makeString(values).count }

/// Scalar lengths of the `Character`s of a string, straight from Swift.
func swiftClusterLengths(_ values: Scalars) -> [Int] {
    makeString(values).map { $0.unicodeScalars.count }
}

func probeGraphemeTables() -> GraphemeTables {
    // One known member of each class; the probes below rely on these.
    let other: UInt32 = 0x1E00, extend: UInt32 = 0x0300, joiner: UInt32 = 0x200D
    let pictograph: UInt32 = 0x1F600, regional: UInt32 = 0x1F1E6
    let consonant: UInt32 = 0x0915, linker: UInt32 = 0x094D
    let leading: UInt32 = 0x1100, vowel: UInt32 = 0x1161, trailing: UInt32 = 0x11A8
    let syllableLV: UInt32 = 0xAC00, syllableLVT: UInt32 = 0xAC01

    var tables = GraphemeTables()
    for scalar in allScalars {
        var kind = GraphemeClass.other
        if characterCount([scalar, extend]) == 2 {
            // Only CR, LF and Control refuse a following Extend.
            if characterCount([scalar, 0x0A]) == 1 {
                kind = .carriageReturn
            } else if characterCount([0x0D, scalar]) == 1 {
                kind = .lineFeed
            } else {
                kind = .control
            }
        } else if characterCount([other, scalar]) == 1 {
            // Attaches to anything before it: Extend, ZWJ or SpacingMark.
            if characterCount([pictograph, scalar, pictograph]) == 1 {
                kind = .zeroWidthJoiner
            } else if characterCount([pictograph, scalar, joiner, pictograph]) == 1 {
                kind = .extend
            } else {
                kind = .spacingMark
            }
        } else if characterCount([scalar, other]) == 1 {
            kind = .prepend
        } else if characterCount([scalar, regional]) == 1, characterCount([regional, scalar]) == 1 {
            kind = .regionalIndicator
        } else if characterCount([scalar, syllableLV]) == 1 {
            kind = .hangulL
        } else if characterCount([syllableLV, scalar]) == 1, characterCount([leading, scalar]) == 1 {
            kind = .hangulV
        } else if characterCount([syllableLVT, scalar]) == 1 {
            kind = .hangulT
        } else if characterCount([scalar, vowel]) == 1 {
            kind = .hangulLV
        } else if characterCount([scalar, trailing]) == 1 {
            kind = .hangulLVT
        } else if characterCount([pictograph, joiner, scalar]) == 1 {
            kind = .extendedPictographic
        }

        var value = kind.rawValue
        if characterCount([scalar, linker, consonant]) == 1 { value |= GraphemeTables.consonantFlag }
        if characterCount([consonant, scalar, consonant]) == 1 { value |= GraphemeTables.linkerFlag }
        if characterCount([consonant, linker, scalar, consonant]) == 1 {
            value |= GraphemeTables.conjunctExtendFlag
        }
        tables.value[Int(scalar)] = value
    }

    // The representatives must have landed in their own classes, or the probes lied.
    let expected: [(UInt32, GraphemeClass)] = [
        (other, .other), (0x0D, .carriageReturn), (0x0A, .lineFeed), (0x0001, .control),
        (extend, .extend), (joiner, .zeroWidthJoiner), (regional, .regionalIndicator),
        (0x0600, .prepend), (0x0903, .spacingMark), (leading, .hangulL), (vowel, .hangulV),
        (trailing, .hangulT), (syllableLV, .hangulLV), (syllableLVT, .hangulLVT),
        (pictograph, .extendedPictographic), (consonant, .other), (linker, .extend),
    ]
    for (scalar, kind) in expected {
        require(tables.graphemeClass(scalar) == kind, "U+\(hex(scalar)) is not \(kind)")
    }
    require(tables.has(GraphemeTables.consonantFlag, consonant)
        && tables.has(GraphemeTables.linkerFlag, linker)
        && tables.has(GraphemeTables.conjunctExtendFlag, linker),
        "the Indic representatives lost their flags")
    for scalar in allScalars {
        let kind = tables.graphemeClass(scalar)
        if tables.has(GraphemeTables.consonantFlag, scalar) {
            require(kind == .other, "consonant U+\(hex(scalar)) is \(kind)")
        }
        if tables.has(GraphemeTables.linkerFlag, scalar) {
            require(kind == .extend && tables.has(GraphemeTables.conjunctExtendFlag, scalar),
                "linker U+\(hex(scalar)) is \(kind)")
        }
        if tables.has(GraphemeTables.conjunctExtendFlag, scalar) {
            require(kind == .extend || kind == .zeroWidthJoiner,
                "conjunct extender U+\(hex(scalar)) is \(kind)")
        }
    }
    return tables
}

/// Swift's forward segmenter, replayed from the tables. `GraphemeBreaker` in Kotlin is
/// this type. The state is reset at the start of every cluster.
struct GraphemeModel {
    let tables: GraphemeTables

    private struct State {
        var inEmojiSequence = false
        var inConjunct = false
        var sawLinker = false
        var oddRegionalIndicators = false
    }

    private func shouldBreak(_ left: UInt32, _ right: UInt32, _ state: inout State) -> Bool {
        let x = tables.graphemeClass(left), y = tables.graphemeClass(right)
        var enterEmojiSequence = false
        var enterConjunct = false
        defer {
            state.inEmojiSequence = enterEmojiSequence
            state.inConjunct = enterConjunct
        }

        if x == .carriageReturn && y == .lineFeed { return false }
        if x == .carriageReturn || x == .lineFeed || x == .control { return true }
        if y == .carriageReturn || y == .lineFeed || y == .control { return true }

        switch (x, y) {
        case (.hangulL, .hangulL), (.hangulL, .hangulV), (.hangulL, .hangulLV), (.hangulL, .hangulLVT),
             (.hangulLV, .hangulV), (.hangulV, .hangulV), (.hangulLV, .hangulT), (.hangulV, .hangulT),
             (.hangulLVT, .hangulT), (.hangulT, .hangulT):
            return false
        case (_, .extend), (_, .zeroWidthJoiner):
            if state.inConjunct || tables.has(GraphemeTables.consonantFlag, left) {
                if y == .extend && !tables.has(GraphemeTables.conjunctExtendFlag, right) { return false }
                enterConjunct = true
                if tables.has(GraphemeTables.linkerFlag, right) { state.sawLinker = true }
            }
            if x == .extendedPictographic || (state.inEmojiSequence && x == .extend) {
                enterEmojiSequence = true
            }
            return false
        case (_, .spacingMark):
            return false
        case (.prepend, _):
            return false
        case (.zeroWidthJoiner, .extendedPictographic):
            return !state.inEmojiSequence
        case (.regionalIndicator, .regionalIndicator):
            defer { state.oddRegionalIndicators.toggle() }
            return state.oddRegionalIndicators
        default:
            if state.inConjunct, state.sawLinker, tables.has(GraphemeTables.consonantFlag, right) {
                state.sawLinker = false
                return false
            }
            return true
        }
    }

    func clusterLengths(_ values: Scalars) -> [Int] {
        guard !values.isEmpty else { return [] }
        var lengths: [Int] = []
        var state = State()
        var length = 1
        for index in 1..<values.count {
            if shouldBreak(values[index - 1], values[index], &state) {
                lengths.append(length)
                length = 1
                state = State()
            } else {
                length += 1
            }
        }
        lengths.append(length)
        return lengths
    }
}

struct GraphemePools {
    var byValue: [Scalars] = []
    let specials: Scalars = [
        0x0915, 0x094D, 0x200D, 0x200C, 0x1F600, 0x1F468, 0x1F469, 0x1F467, 0x2764, 0xFE0F, 0x1F3FB,
        0x1F3FF, 0x1F1E6, 0x1F1FA, 0x0300, 0x0301, 0x093C, 0x0D, 0x0A, 0x0020, 0x0061, 0x00A9, 0x1100,
        0x1161, 0x11A8, 0xAC00, 0xAC01, 0x0600, 0x0903, 0x0E33, 0x20E3, 0x0023, 0xE0067, 0xE007F,
        0x1F3F4, 0x09CD, 0x0995, 0x0D4D, 0x0D15, 0x0AB0, 0x0ACD, 0x1F9D1, 0x1F91D,
    ]

    init(_ tables: GraphemeTables) {
        var groups: [UInt8: Scalars] = [:]
        for scalar in allScalars { groups[tables.value[Int(scalar)], default: []].append(scalar) }
        byValue = groups.keys.sorted().map { groups[$0]! }
    }

    func randomString(_ random: inout SeededRandom, maxLength: Int) -> Scalars {
        let length = 1 + random.int(maxLength)
        var values: Scalars = []
        values.reserveCapacity(length)
        for _ in 0..<length {
            switch random.int(10) {
            case 0...5: values.append(random.pick(random.pick(byValue)))
            case 6...8: values.append(random.pick(specials))
            default: values.append(random.pick(allScalars))
            }
        }
        return values
    }
}

func verifyGraphemeModel(_ tables: GraphemeTables) -> Int {
    let model = GraphemeModel(tables: tables)
    let pools = GraphemePools(tables)
    var checked = 0

    func check(_ input: Scalars) {
        let expected = swiftClusterLengths(input)
        let actual = model.clusterLengths(input)
        checked += 1
        require(expected == actual,
            "grapheme model mismatch for [\(hex(input))]: Swift \(expected), model \(actual)")
    }

    // Every scalar next to one member of every class, on both sides.
    let neighbours = pools.byValue.map { $0[0] }
    for scalar in allScalars {
        for neighbour in neighbours {
            check([scalar, neighbour])
            check([neighbour, scalar])
        }
    }
    var random = SeededRandom(seed: 0x6EA9_0001)
    for _ in 0..<4_000_000 { check(pools.randomString(&random, maxLength: 12)) }
    return checked
}

func graphemeResourceLines(_ tables: GraphemeTables, environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "Grapheme cluster break classes of the Swift standard library",
        [
            "range value; value = class + flags. Classes: 0 other, 1 CR, 2 LF, 3 control, 4 extend,",
            "5 ZWJ, 6 regional indicator, 7 prepend, 8 spacing mark, 9 L, 10 V, 11 T, 12 LV, 13 LVT,",
            "14 extended pictographic. Flags: 16 conjunct consonant, 32 conjunct linker,",
            "64 extender allowed inside a conjunct. Scalars not listed are 0.",
        ])
    lines += rangeLines(skip: 0, key: { tables.value[Int($0)] }, format: { String($0) })
    return lines
}

/// `input<TAB>cluster lengths in scalars`, straight from Swift.
func graphemeCorpusLines(_ tables: GraphemeTables, environment: GeneratorEnvironment) -> [String] {
    var seen = Set<Scalars>()
    var cases: [Scalars] = []
    func add(_ values: Scalars) {
        if !values.isEmpty, seen.insert(values).inserted { cases.append(values) }
    }
    func add(_ text: String) { add(scalarValues(text)) }

    let samples = [
        "a", "ab", "e\u{301}", "é", "\r\n", "\n\r", "\r\r\n\n", "a\r\nb", "\u{1}a", "a\u{0}b",
        "👨‍👩‍👧‍👦", "👩🏽‍💻", "🧑‍🤝‍🧑", "🏳️‍🌈", "🏴󠁧󠁢󠁥󠁮󠁧󠁿", "👍🏿", "👍🏿👍", "❤️", "❤️‍🔥", "#️⃣", "1️⃣2️⃣",
        "🇩🇪", "🇩🇪🇫🇷", "🇩🇪🇫", "🇩🇪🇫🇷🇬", "a🇩🇪b", "🇩\u{200D}🇪", "©️", "©\u{200D}®", "™️",
        "👨\u{200D}", "\u{200D}👨", "👨\u{200D}\u{200D}👩", "👨\u{301}\u{200D}👩", "👨\u{903}\u{200D}👩",
        "👨🏽\u{200D}👩", "a\u{200D}👩", "👨\u{200D}a", "\u{1F3FB}", "a\u{1F3FB}",
        "क्ष", "क्षि", "क्‍ष", "क्‌ष", "क़्ष", "क्क्क", "कि", "क्", "त्र्य", "श्री", "ज्ञ",
        "ক্ষ", "র্ক", "ক্‍ষ", "ക്ഷ", "ന്‍", "ക്‌ഷ", "ક્ષ", "ଙ୍କ", "క్ష", "ಕ್ಷ", "க்ஷ", "ක්‍ෂ",
        "ก็", "กำ", "เก", "ກໍ່", "မြန်", "ខ្មែរ", "བོད", "\u{600}a", "\u{600}\u{600}a", "\u{600}\r",
        "한국어", "\u{1100}\u{1161}\u{11A8}", "\u{1100}\u{1100}\u{1161}", "\u{AC00}\u{11A8}",
        "\u{AC01}\u{11A8}", "\u{AC01}\u{1161}", "\u{1161}\u{1161}", "\u{11A8}\u{1100}", "가각갂",
        "Z͑ͫ̓ͪ̂ͫ̽͏̴̙̤̞͉͚̯̞̠͍A̴̵̜̰͔ͫ͗͢L̠ͨͧͩ͘G̴̻͈͍͔̹̑͗̎̅͛́Ǫ̵̹̻̝̳͂̌̌͘!͖̬̰̙̗̿̋ͥͥ̂ͣ̐́́͜͞", "a\u{308}\u{301}\u{FE0F}\u{20E3}",
        "日本語", "ｶﾞ", "が", "か\u{3099}", "العربية", "עִבְרִית", "\u{FEFF}a", "a\u{2028}b", "a\u{85}b",
        "\\\u{301}x", "\\x", "\\\\", " \u{301}", "\u{301}", "\u{301}\u{301}", "\t\u{301}",
    ]
    for sample in samples {
        add(sample)
        add(sample + sample)
        add("x" + sample + "y")
        add(sample.decomposedStringWithCanonicalMapping)
    }

    // Each class next to each class, then random strings from the verification pools.
    let pools = GraphemePools(tables)
    let representatives = pools.byValue.map { $0[$0.count / 2] }
    for left in representatives {
        for right in representatives {
            add([left, right])
            add([0x0915, left, right, 0x0915])
            add([0x1F600, left, right, 0x1F600])
        }
    }
    var random = SeededRandom(seed: 0x6EA9_C0DE)
    for _ in 0..<2_500 { add(pools.randomString(&random, maxLength: 14)) }
    for _ in 0..<20 {
        var values: Scalars = []
        for _ in 0..<(100 + random.int(400)) { values += pools.randomString(&random, maxLength: 3) }
        add(values)
    }

    var lines = environment.header(
        "Extended grapheme clusters as Swift's String draws them",
        ["input<TAB>scalar length of each Character, space-separated; input as scalar values"])
    for input in cases {
        let lengths = swiftClusterLengths(input).map(String.init).joined(separator: " ")
        lines.append("\(hex(input))\t\(lengths)")
    }
    return lines
}
