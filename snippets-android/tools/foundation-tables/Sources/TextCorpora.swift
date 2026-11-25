import Foundation

// Character-set membership, trimming and splitting, and Swift's String equality and
// ordering. All values come from Foundation and the standard library.

func characterSetLines(environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "Membership of Foundation's CharacterSet.whitespaces, .newlines and .whitespacesAndNewlines",
        ["set<TAB>range, one line per run of member scalars"])
    let sets: [(String, CharacterSet)] = [
        ("whitespaces", .whitespaces),
        ("newlines", .newlines),
        ("whitespacesAndNewlines", .whitespacesAndNewlines),
    ]
    for (name, set) in sets {
        let ranges = rangeLines(
            skip: false, key: { set.contains(Unicode.Scalar($0)!) }, format: { _ in "" })
        lines += ranges.map { "\(name)\t\($0)" }
    }
    return lines
}

/// Scalars that make trimming and splitting interesting: every member of the sets, the
/// scalars the JVM treats differently, and things that combine with their neighbours.
let textPool: Scalars = {
    var pool: Scalars = [
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x180E,
        0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
        0x200B, 0x200C, 0x200D, 0x2028, 0x2029, 0x202F, 0x205F, 0x2060, 0x3000, 0xFEFF, 0x00,
        0x5C, 0x5C, 0x5C, 0x2D, 0x21, 0x2F, 0x22, 0x301, 0x308, 0x327, 0xFE0F, 0x20E3, 0x1F3FD,
        0x1F468, 0x1F469, 0x1F4BB, 0x1F1E9, 0x1F1EA, 0xE9, 0xC5, 0x130, 0x131, 0xDF, 0x3A3, 0x3C2,
        0x416, 0x5D0, 0x5B8, 0x627, 0x654, 0x915, 0x94D, 0x937, 0x93F, 0x4E2D, 0x6587, 0xAC00,
        0x1100, 0x1161, 0x11A8, 0x304B, 0x3099, 0xFF21, 0x10400, 0x1D11E,
    ]
    // Plain letters and spaces dominate, as they do in real text.
    for _ in 0..<3 {
        pool += Array(0x61...0x7A)
        pool += [0x20, 0x20, 0x20, 0x20, 0x09, 0x0A]
    }
    pool += Array(0x41...0x5A)
    pool += Array(0x30...0x39)
    return pool
}()

func randomText(_ random: inout SeededRandom, maxLength: Int) -> Scalars {
    let length = random.int(maxLength + 1)
    return (0..<length).map { _ in random.pick(textPool) }
}

/// `trim`, `trimWhitespaces` and `split` lines.
func trimAndSplitCorpusLines(environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "Foundation trimming and splitting",
        [
            "trim<TAB>input<TAB>trimmingCharacters(in: .whitespacesAndNewlines)",
            "trimWhitespaces<TAB>input<TAB>trimmingCharacters(in: .whitespaces)",
            "split<TAB>input<TAB>components(separatedBy: .whitespacesAndNewlines), joined by ;",
            "Strings are space-separated scalar values; - is the empty string.",
        ])
    var cases: [Scalars] = [
        [], [0x20], [0x20, 0x20], [0x61], [0x20, 0x61, 0x20], [0x20, 0x301, 0x61],
        [0x61, 0x20, 0x301], [0x200B, 0x61, 0x200B], [0x1C, 0x61, 0x1F], [0x85, 0x61, 0x85],
        [0xFEFF, 0x61], [0x180E, 0x61], [0x2060, 0x61], [0x0D, 0x0A, 0x61, 0x0D, 0x0A],
        [0x61, 0x0D, 0x0A, 0x62], [0x61, 0x20, 0x20, 0x62], [0x3000, 0x61, 0x3000, 0x62, 0x3000],
    ]
    var random = SeededRandom(seed: 0x7E27_0001)
    for _ in 0..<700 { cases.append(randomText(&random, maxLength: 24)) }

    for input in cases {
        let text = makeString(input)
        lines.append("trim\t\(hex(input))\t\(hex(text.trimmingCharacters(in: .whitespacesAndNewlines)))")
        lines.append("trimWhitespaces\t\(hex(input))\t\(hex(text.trimmingCharacters(in: .whitespaces)))")
        let pieces = text.components(separatedBy: .whitespacesAndNewlines)
        lines.append("split\t\(hex(input))\t\(pieces.map { hex($0) }.joined(separator: ";"))")
    }
    return lines
}

/// U+0F73, U+0F75 and U+0F81: starters whose canonical decomposition begins with a
/// non-starter. Apple's normalizers (the Swift standard library's and Foundation's) emit
/// the marks before one of these unsorted against its decomposition.
let appleNormalizationOutliers: Set<UInt32> = [0x0F73, 0x0F75, 0x0F81]

/// `a<TAB>b<TAB>equal<TAB>order<TAB>normalizedOrder<TAB>outlier`: Swift's `a == b` (0/1), the
/// sign of `a <=> b`, and the order of the NFC forms.
///
/// The Kotlin side answers both through `java.text.Normalizer`, whose Unicode version is
/// the runtime's. Android API 28 ships Unicode 10, so the scalars here are limited to
/// those assigned by then; normalization of assigned scalars never changes afterwards.
func comparisonCorpusLines(environment: GeneratorEnvironment) -> [String] {
    var marks: Scalars = []
    var composites: Scalars = []
    var letters: Scalars = []
    for scalar in allScalars {
        let properties = Unicode.Scalar(scalar)!.properties
        guard let age = properties.age, age.major <= 10 else { continue }
        switch properties.generalCategory {
        case .unassigned, .privateUse, .surrogate, .control:
            continue
        default:
            break
        }
        let text = String(Unicode.Scalar(scalar)!)
        if properties.canonicalCombiningClass != .notReordered {
            marks.append(scalar)
        } else if scalarValues(text.decomposedStringWithCanonicalMapping) != [scalar] {
            // Compared as scalars: Swift's own != would call the two forms equal.
            composites.append(scalar)
        } else if properties.isAlphabetic, scalar < 0x3100 || scalar > 0xFFFF {
            letters.append(scalar)
        }
    }
    let edges: Scalars = [
        0x00, 0x41, 0x5A, 0x61, 0x7A, 0x7F, 0x80, 0xFF, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xF8FF,
        0xFFFD, 0xFFFF, 0x10000, 0x10FFFF, 0x1F600, 0x212A, 0x212B, 0x2126, 0x1100, 0x1161, 0x11A8,
        0xAC00, 0xAC01, 0x0958, 0xFB1D, 0x0344, 0x0F73, 0x0F75, 0x0F81, 0x1D15E,
    ]

    var random = SeededRandom(seed: 0xC0A9_0001)
    func randomString(maxLength: Int) -> Scalars {
        let length = random.int(maxLength + 1)
        return (0..<length).map { _ in
            switch random.int(10) {
            case 0...2: return random.pick(marks)
            case 3...4: return random.pick(composites)
            case 5...6: return random.pick(letters)
            case 7: return random.pick(edges)
            default: return UInt32(0x41 + random.int(26))
            }
        }
    }
    func variant(of values: Scalars) -> Scalars {
        let text = makeString(values)
        switch random.int(8) {
        case 0: return values
        case 1: return scalarValues(text.decomposedStringWithCanonicalMapping)
        case 2: return scalarValues(text.precomposedStringWithCanonicalMapping)
        case 3:
            var copy = values
            if copy.count >= 2 { copy.swapAt(random.int(copy.count), random.int(copy.count)) }
            return copy
        case 4: return values + [random.pick(edges)]
        case 5: return Array(values.dropLast())
        case 6:
            var copy = values
            if !copy.isEmpty { copy[random.int(copy.count)] = random.pick(edges + marks) }
            return copy
        default: return randomString(maxLength: 6)
        }
    }

    var pairs: [(Scalars, Scalars)] = [
        ([], []), ([], [0x61]), ([0xE9], [0x65, 0x301]), ([0x5A], [0x61]), ([0xFFFF], [0x10000]),
        ([0xE000], [0x10000]), ([0xFF21], [0x1F600]), ([0x212B], [0xC5]), ([0x212A], [0x4B]),
        ([0x41, 0x30A], [0xC5]), ([0x65, 0x327, 0x301], [0x65, 0x301, 0x327]),
        ([0x1100, 0x1161], [0xAC00]), ([0x1100, 0x1161, 0x11A8], [0xAC01]),
        ([0x915, 0x93C], [0x958]), ([0x0D, 0x0A], [0x0D]), ([0x61, 0x00], [0x61]),
        ([0x61], [0x41]), ([0x61, 0x62], [0x61, 0x62, 0x63]),
    ]
    for _ in 0..<3_000 {
        let first = randomString(maxLength: 8)
        pairs.append((first, variant(of: first)))
    }

    var lines = environment.header(
        "Swift String equality and ordering",
        [
            "a<TAB>b<TAB>equal<TAB>order<TAB>normalizedOrder<TAB>outlier",
            "equal is a == b; order is -1, 0 or 1 for a < b, a == b, a > b, as the standard library answers;",
            "normalizedOrder is the scalar order of the two NFC forms (precomposedStringWithCanonicalMapping).",
            "The two orders differ only where one string's bytes are a prefix of the other's: Swift then",
            "answers by length without normalizing, although a mark in the longer string may sort before",
            "the end of the shorter one.",
            "Scalars are limited to those assigned in Unicode 10.0 or earlier.",
            "outlier is 1 when a or b holds U+0F73, U+0F75 or U+0F81. Their class is 0 but they decompose",
            "into marks of class 129/130, and neither Swift nor Foundation reorders earlier marks past",
            "them as Unicode's canonical ordering requires. Only for these rows may a conforming",
            "normalizer (java.text.Normalizer) disagree with the recorded answer.",
        ])
    for (first, second) in pairs {
        let a = makeString(first), b = makeString(second)
        let order = a < b ? -1 : (b < a ? 1 : 0)
        require((a == b) == (order == 0), "Swift == and < disagree for [\(hex(first))] [\(hex(second))]")
        let apple = (first + second).contains { appleNormalizationOutliers.contains($0) } ? 1 : 0
        // The order the documentation promises: scalar order of the NFC forms, here from
        // Foundation's normalizer rather than from the standard library's comparison.
        let normalizedA = scalarValues(a.precomposedStringWithCanonicalMapping)
        let normalizedB = scalarValues(b.precomposedStringWithCanonicalMapping)
        let normalizedOrder = normalizedA.lexicographicallyPrecedes(normalizedB)
            ? -1 : (normalizedB.lexicographicallyPrecedes(normalizedA) ? 1 : 0)
        lines.append("\(hex(first))\t\(hex(second))\t\(a == b ? 1 : 0)\t\(order)\t\(normalizedOrder)\t\(apple)")
    }
    return lines
}
