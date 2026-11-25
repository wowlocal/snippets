import Foundation

// `String.lowercased()` and `String.uppercased()` of the Swift standard library (not
// Foundation's `lowercased(with:)`): no locale, and no context either. The JVM's
// `lowercase(Locale.ROOT)` differs: it writes a final sigma at the end of a word, and it
// only knows the case pairs of the runtime's Unicode version.
//
// Swift maps each scalar on its own and concatenates the results. The per-scalar
// mappings are measured here, and that rule is compared with Swift over a few million
// strings before anything is written.

struct CaseTables {
    /** `String(scalar).lowercased()` where it differs from the scalar. */
    var lower: [UInt32: Scalars] = [:]
    /** `String(scalar).uppercased()` where it differs from the scalar. */
    var upper: [UInt32: Scalars] = [:]

    func lowercased(_ input: Scalars) -> Scalars { input.flatMap { lower[$0] ?? [$0] } }
    func uppercased(_ input: Scalars) -> Scalars { input.flatMap { upper[$0] ?? [$0] } }
}

func probeCaseTables() -> CaseTables {
    var tables = CaseTables()
    for scalar in allScalars {
        let text = makeString([scalar])
        let lower = scalarValues(text.lowercased())
        if lower != [scalar] { tables.lower[scalar] = lower }
        let upper = scalarValues(text.uppercased())
        if upper != [scalar] { tables.upper[scalar] = upper }
    }
    require(tables.lower[0x41] == [0x61] && tables.upper[0xDF] == [0x53, 0x53]
        && tables.lower[0x130] == [0x69, 0x307] && tables.lower[0x3A3] == [0x3C3],
        "the case mappings of A, ß, İ or Σ are not what the port expects")
    for (scalar, mapping) in tables.lower { require(!mapping.isEmpty, "U+\(hex(scalar)) lowercases to nothing") }
    for (scalar, mapping) in tables.upper { require(!mapping.isEmpty, "U+\(hex(scalar)) uppercases to nothing") }
    return tables
}

/// Words in which context or locale would matter if Swift looked at either.
private let caseWords: [String] = [
    "", "ΑΣ", "ΑΣ ΒΣ", "Σ", "ΣΑΣ", "ΣΣ", "ΑΣ.", "ΑΣ\u{301}", "ΑΣ\u{301}Β", "Σ\u{301}", "\u{301}Σ", "ΌΣΟΣ", "ὈΔΥΣΣΕΎΣ", "οδυσσεύς",
    "ς", "σ", "ας", "ασ", "ἈΣ", "Α\u{313}Σ", "ΑΣ́", "aΣ", "Σa", "AΣ B", "1Σ", "Σ1", "ΑΣ-ΒΣ", "ΑΣ'", "'ΑΣ'", "ΑΣ\u{200D}", "ΑΣ\u{AD}Α",
    "I", "i", "İ", "ı", "I\u{307}", "i\u{307}", "İstanbul", "ISTANBUL", "ıstanbul", "DİYARBAKIR", "diyarbakır", "TITLE", "title",
    "Į", "į", "Į\u{307}", "J\u{307}", "Ì", "Í", "Ĩ", "i\u{300}", "LIETUVA",
    "ß", "ẞ", "Straße", "STRASSE", "GROẞ", "groß", "ﬁ", "ﬂ", "ﬀ", "ﬃ", "ﬄ", "ﬅ", "ﬆ", "ﬁnance", "ŉ", "ǰ", "ẖ", "ẗ", "ẘ", "ẙ", "ẚ",
    "ǅ", "Ǆ", "ǆ", "ǈ", "Ǉ", "ǉ", "ǋ", "ǲ", "Ǳ", "ǳ", "ǅungla", "ǄUNGLA",
    "ά", "Ά", "α\u{301}", "Α\u{301}", "ΐ", "ι\u{308}\u{301}", "ΰ", "ᾳ", "ᾼ", "ᾀ", "ᾈ", "α\u{345}", "Α\u{345}", "\u{345}", "ᾷ", "ῼ", "ῳ",
    "ΆΣΟΣ", "άσος", "Ελληνικά", "ΕΛΛΗΝΙΚΆ", "ελληνικά", "ΜΆΪΟΣ", "μάιος",
    "Привет", "ПРИВЕТ", "привет", "Ёлка", "Ґ", "ґ", "Ꙁ", "ᲀ", "Ა", "ა", "Ⴀ", "ⴀ", "Ꭰ", "ꭰ", "ᏸ", "Ᏸ",
    "Ա", "ա", "և", "ﬓ", "ﬔ", "ﬕ", "ﬖ", "ﬗ", "ԵՎ", "Եւ",
    "Å", "\u{212B}", "\u{212A}", "\u{2126}", "å", "k", "ω", "µ", "Μ", "ſ", "S", "s", "ẛ", "Ṡ", "ṡ",
    "ＡＢＣ", "ａｂｃ", "Ⓐ", "ⓐ", "Ⅰ", "ⅰ", "ↄ", "Ↄ", "𐐀", "𐐨", "𞤀", "𞤢", "𑢠", "𑣀", "𖹀", "𖹠",
    "Hello, World!", "hello, world!", "HELLO, WORLD!", "Tiếng Việt", "TIẾNG VIỆT", "Łódź", "ŁÓDŹ", "Ærø", "ÆRØ", "Þórr", "ÞÓRR",
    "日本語", "한국어", "العربية", "עברית", "हिन्दी", "👩🏽‍💻", "🇩🇪", "e\u{301}", "E\u{301}", "\u{0}A\u{0}", "a\u{FE0F}", "A\u{20DD}",
    "My Snippet Name", "my-snippet-name", "MY_SNIPPET_NAME", "CamelCaseSlug", "snake_case_slug", "Größe & Maße", "GRÖSSE & MASSE",
]

struct CasePools {
    var changing: Scalars = []
    let specials: Scalars = [
        0x3A3, 0x3C3, 0x3C2, 0x391, 0x3B1, 0x49, 0x69, 0x130, 0x131, 0x307, 0x301, 0x345, 0xDF, 0x1E9E, 0xFB01, 0x149,
        0x1C5, 0x1C4, 0x1C6, 0x20, 0x2E, 0x27, 0x2D, 0xAD, 0x200D, 0x41, 0x61, 0x5A, 0x7A, 0x31, 0x4E2D, 0x1F600, 0x587,
    ]

    init(_ tables: CaseTables) {
        changing = Set(tables.lower.keys).union(tables.upper.keys).sorted()
    }

    func randomString(_ random: inout SeededRandom, maxLength: Int) -> Scalars {
        let length = 1 + random.int(maxLength)
        return (0..<length).map { _ in
            switch random.int(10) {
            case 0...3: return random.pick(changing)
            case 4...7: return random.pick(specials)
            case 8: return UInt32(0x20 + random.int(0x5F))
            default: return random.pick(allScalars)
            }
        }
    }
}

func verifyCaseModel(_ tables: CaseTables) -> Int {
    var checked = 0
    func check(_ input: Scalars) {
        let text = makeString(input)
        checked += 1
        require(scalarValues(text.lowercased()) == tables.lowercased(input),
            "lowercased() is not scalar by scalar for [\(hex(input))]: Swift [\(hex(text.lowercased()))]")
        require(scalarValues(text.uppercased()) == tables.uppercased(input),
            "uppercased() is not scalar by scalar for [\(hex(input))]: Swift [\(hex(text.uppercased()))]")
    }
    for word in caseWords { check(scalarValues(word)) }
    // Sigma in every position of short words made of letters, marks and punctuation.
    let around: Scalars = [0x391, 0x3B1, 0x3A3, 0x3C3, 0x3C2, 0x301, 0x20, 0x2E, 0x27, 0xAD, 0x41]
    for a in around { for b in around { for c in around {
        check([a, 0x3A3, b, c])
        check([a, b, 0x3A3, c])
        check([a, b, c, 0x3A3])
        check([0x3A3, a, b, c])
    } } }
    // Every scalar between two others, so no neighbour changes its mapping.
    for scalar in allScalars {
        check([0x41, scalar, 0x3A3])
        check([0x3A3, scalar, 0x69, 0x307])
    }
    let pools = CasePools(tables)
    var random = SeededRandom(seed: 0xCA5E_0001)
    for _ in 0..<2_000_000 { check(pools.randomString(&random, maxLength: 10)) }
    return checked
}

func caseResourceLines(_ tables: CaseTables, environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "Case mappings of the Swift standard library: String.lowercased() and String.uppercased()",
        [
            "Sections [lower] and [upper]: scalar -> its mapping. A scalar that is not listed maps to",
            "itself. A string is mapped scalar by scalar: no locale, and no context (no final sigma).",
        ])
    lines.append("[lower]")
    for scalar in tables.lower.keys.sorted() { lines.append("\(hex(scalar)) \(hex(tables.lower[scalar]!))") }
    lines.append("[upper]")
    for scalar in tables.upper.keys.sorted() { lines.append("\(hex(scalar)) \(hex(tables.upper[scalar]!))") }
    return lines
}

/// `lower<TAB>input<TAB>output` and `upper<TAB>input<TAB>output`, straight from Swift.
func caseCorpusLines(_ tables: CaseTables, environment: GeneratorEnvironment) -> [String] {
    var seen = Set<Scalars>()
    var cases: [Scalars] = []
    func add(_ values: Scalars) {
        if seen.insert(values).inserted { cases.append(values) }
    }

    // Every scalar that has a mapping, on its own. The test maps every other scalar too
    // and expects it unchanged.
    for scalar in CasePools(tables).changing { add([scalar]) }
    for word in caseWords {
        add(scalarValues(word))
        add(scalarValues(word.decomposedStringWithCanonicalMapping))
        add(scalarValues(word + " " + word))
    }
    // Sigma in every position.
    let around: Scalars = [0x391, 0x3B1, 0x3C3, 0x3C2, 0x301, 0x20, 0x2E, 0x41]
    for a in around { for b in around {
        add([0x3A3, a, b])
        add([a, 0x3A3, b])
        add([a, b, 0x3A3])
        add([a, 0x3A3, 0x3A3, b])
    } }
    let pools = CasePools(tables)
    var random = SeededRandom(seed: 0xCA5E_C0DE)
    for _ in 0..<2_500 { add(pools.randomString(&random, maxLength: 12)) }
    add(scalarValues(String(repeating: "ΟΔΥΣΣΕΎΣ ΚΑΙ İSTANBUL STRAẞE ﬁ ǅ ", count: 100)))

    var lines = environment.header(
        "Swift's String.lowercased() and String.uppercased()",
        [
            "lower<TAB>input<TAB>lowercased(); upper<TAB>input<TAB>uppercased()",
            "Strings are space-separated scalar values; - is the empty string.",
            "Every scalar whose mapping is not itself has a line of its own.",
        ])
    for input in cases {
        let text = makeString(input)
        lines.append("lower\t\(hex(input))\t\(hex(text.lowercased()))")
        lines.append("upper\t\(hex(input))\t\(hex(text.uppercased()))")
    }
    return lines
}
