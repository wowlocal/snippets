import CryptoKit
import Foundation

// Tables for `String.precomposedStringWithCanonicalMapping`, which `PassphraseKDF.derive`
// stretches. On Apple platforms it is CoreFoundation's `CFStringNormalize(_, .C)`, which is
// not Unicode NFC: it never decomposes a Hangul syllable, composes conjoining jamo with
// off-by-one bounds, looks a base up by its low 16 bits for a BMP mark, does not reorder a
// mark across a class-0 character that decomposes into marks, and composes every mark of a
// run onto its first character. `PrecomposedModel` is that function, statement for
// statement, over tables measured here by calling Foundation; it is compared with Foundation
// on about 30 million strings before anything is written.

@inline(__always)
func foundationPrecomposed(_ values: Scalars) -> Scalars {
    scalarValues(makeString(values).precomposedStringWithCanonicalMapping)
}

@inline(__always)
func foundationDecomposed(_ values: Scalars) -> Scalars {
    scalarValues(makeString(values).decomposedStringWithCanonicalMapping)
}

let hangulSyllableBase: UInt32 = 0xAC00
let hangulSyllableCount: UInt32 = 11172

/// CoreFoundation's buffer for one decomposed run (`MAX_DECOMP_BUF`).
let precomposeBufferLength = 64

struct PrecomposedTables {
    /// CoreFoundation's own canonical decomposition of a scalar, unsorted, where it has one.
    /// Hangul syllables are algorithmic and never decomposed by this function, so absent.
    var decomposition: [UInt32: Scalars] = [:]
    /// A rank that orders and ties exactly as CoreFoundation's combining class does; 0 is
    /// class 0. Measured for every scalar.
    var rank = [UInt8](repeating: 0, count: 0x110000)
    /// Decomposable scalars of non-zero class: only zero versus non-zero is ever asked of them.
    var decomposableMark = Set<UInt32>()
    /// `CFUniCharPrecomposeCharacter`: mark -> base -> composite. For a BMP mark the base is
    /// looked up by its low 16 bits.
    var compose: [UInt32: [UInt32: UInt32]] = [:]
    /// Class-0 marks that CoreFoundation's "non-base" set holds; only those that compose
    /// with something are listed, the only ones whose membership changes a result.
    var nonBaseStarter = Set<UInt32>()
    /// Free buffer slots a decomposable mark needs before it is decomposed into the run.
    var markSpace: [UInt32: Int] = [:]

    func isDecomposable(_ value: UInt32) -> Bool {
        decomposition[value] != nil || (value >= hangulSyllableBase && value < hangulSyllableBase + hangulSyllableCount)
    }

    func rankOf(_ value: UInt32) -> UInt8 { value < 0x110000 ? rank[Int(value)] : 0 }

    func precompose(_ base: UInt32, _ mark: UInt32) -> UInt32 {
        guard let bases = compose[mark] else { return 0xFFFD }
        let key = mark < 0x10000 ? base & 0xFFFF : base
        return bases[key] ?? 0xFFFD
    }
}

func probePrecomposedTables() -> PrecomposedTables {
    var tables = PrecomposedTables()

    // 1. Decompositions. A class-0 scalar that is the last character of the string is
    //    decomposed and not sorted, so its normal form D alone is the raw decomposition.
    for scalar in allScalars {
        if scalar >= hangulSyllableBase && scalar < hangulSyllableBase + hangulSyllableCount { continue }
        let decomposed = foundationDecomposed([scalar])
        if decomposed != [scalar] { tables.decomposition[scalar] = decomposed }
    }
    for (scalar, pieces) in tables.decomposition {
        for piece in pieces {
            require(tables.decomposition[piece] == nil, "U+\(hex(scalar)) decomposes into a decomposable U+\(hex(piece))")
        }
    }

    // 2. Combining classes. After `a`, a run of non-zero marks is sorted; a class-0 scalar
    //    ends the run. U+0345 has the highest class and U+0334 the lowest.
    let highest: UInt32 = 0x0345, lowest: UInt32 = 0x0334
    func isMark(_ scalar: UInt32) -> Bool {
        // A class-0 scalar stays out of the run before it (and, decomposed, takes the
        // marks after it into its own run, so only the first probe applies to it).
        if let pieces = tables.decomposition[scalar] {
            return foundationDecomposed([0x61, highest, scalar]) != [0x61, highest] + pieces
        }
        if foundationDecomposed([0x61, highest, scalar]) != [0x61, highest, scalar] { return true }
        return foundationDecomposed([0x61, scalar, lowest]) != [0x61, scalar, lowest]
    }
    var marks: [UInt32] = []
    let syllables = hangulSyllableBase..<(hangulSyllableBase + hangulSyllableCount)
    for scalar in allScalars where scalar != 0x61 && !syllables.contains(scalar) && isMark(scalar) {
        if tables.decomposition[scalar] != nil {
            tables.decomposableMark.insert(scalar)
        } else {
            marks.append(scalar)
        }
    }
    func keepsOrder(_ first: UInt32, _ second: UInt32) -> Bool {
        foundationDecomposed([0x61, first, second]) == [0x61, first, second]
    }
    var representative: [UInt8: UInt32] = [:]
    for mark in marks {
        let guess = Unicode.Scalar(mark)!.properties.canonicalCombiningClass.rawValue
        if guess != 0, representative[guess] == nil { representative[guess] = mark }
    }
    let ladder = representative.keys.sorted()
    for (lower, higher) in zip(ladder, ladder.dropFirst()) {
        let a = representative[lower]!, b = representative[higher]!
        require(keepsOrder(a, b) && !keepsOrder(b, a), "classes \(lower) and \(higher) are not ordered as expected")
    }
    for mark in marks {
        func ties(_ value: UInt8) -> Bool {
            let other = representative[value]!
            return keepsOrder(mark, other) && keepsOrder(other, mark)
        }
        let guess = Unicode.Scalar(mark)!.properties.canonicalCombiningClass.rawValue
        if representative[guess] != nil, ties(guess) {
            tables.rank[Int(mark)] = guess
        } else if let found = ladder.first(where: ties) {
            tables.rank[Int(mark)] = found
        } else {
            require(false, "U+\(hex(mark)) has a combining class outside the ladder")
        }
    }
    for mark in tables.decomposableMark { tables.rank[Int(mark)] = 255 }   // non-zero; never compared

    // 3. Compositions. Decomposing a class-0 scalar at the end of a string and composing
    //    the pieces onto the first is the composition loop alone, so a scalar that comes
    //    back from its own decomposition composes from (its pieces but the last) and the
    //    last. Shorter decompositions first, so the prefix of a longer one is known.
    let byLength = tables.decomposition.keys.sorted {
        let a = tables.decomposition[$0]!.count, b = tables.decomposition[$1]!.count
        return a != b ? a < b : $0 < $1
    }
    var model = PrecomposedModel(tables: tables)
    for scalar in byLength {
        let pieces = tables.decomposition[scalar]!
        guard pieces.count >= 2 else { continue }
        guard foundationPrecomposed([scalar]) == [scalar] else { continue }
        let prefix = model.precomposedRun(Array(pieces.dropLast()))
        require(prefix.count == 1, "U+\(hex(scalar)) composes from a prefix that does not compose")
        let mark = pieces.last!
        let key = mark < 0x10000 ? prefix[0] & 0xFFFF : prefix[0]
        tables.compose[mark, default: [:]][key] = scalar
        model = PrecomposedModel(tables: tables)
    }

    // 4. Which class-0 marks join a run after a base that does not decompose. For a BMP
    //    mark any base with the same low 16 bits will do, so try a supplementary one too.
    for (mark, bases) in tables.compose where tables.rankOf(mark) == 0 {
        var probes: [(UInt32, UInt32)] = []
        for (base, composite) in bases {
            if !tables.isDecomposable(base) { probes.append((base, composite)) }
            if mark < 0x10000 {
                for plane in UInt32(1)...16 {
                    let wide = (plane << 16) | base
                    if !tables.isDecomposable(wide) && tables.rankOf(wide) == 0 { probes.append((wide, composite)); break }
                }
            }
        }
        require(!probes.isEmpty, "no probe for the class-0 mark U+\(hex(mark))")
        let joins = probes.map { foundationPrecomposed([$0.0, mark]) == [$0.1] }
        require(Set(joins).count == 1, "U+\(hex(mark)) joins some bases and not others")
        if joins[0] { tables.nonBaseStarter.insert(mark) }
    }

    // 5. A decomposable mark is decomposed into the run only while the buffer has room.
    for mark in tables.decomposableMark.sorted() {
        var matching: [Int] = []
        for candidate in 1...8 {
            var trial = tables
            trial.markSpace[mark] = candidate
            let trialModel = PrecomposedModel(tables: trial)
            let agrees = (0...10).allSatisfy { free in
                let filler = Scalars(repeating: lowest, count: precomposeBufferLength - 1 - free)
                let input = [0x05D0] + filler + [mark, 0x05B0]
                return trialModel.precomposed(input) == foundationPrecomposed(input)
            }
            if agrees { matching.append(candidate) }
        }
        require(!matching.isEmpty, "could not measure the space U+\(hex(mark)) needs")
        tables.markSpace[mark] = matching[0]
    }
    return tables
}

/// `CFStringNormalize(string, kCFStringNormalizationFormC)` over the measured tables,
/// on a UTF-16 buffer as CoreFoundation does it, then read back as a Swift string would be
/// (a lone surrogate it produced becomes U+FFFD). `FoundationPrecomposed.kt` is this function.
struct PrecomposedModel {
    let tables: PrecomposedTables

    @inline(__always) private func isHigh(_ unit: UInt32) -> Bool { unit >= 0xD800 && unit <= 0xDBFF }
    @inline(__always) private func isLow(_ unit: UInt32) -> Bool { unit >= 0xDC00 && unit <= 0xDFFF }
    @inline(__always) private func pair(_ high: UInt32, _ low: UInt32) -> UInt32 { ((high - 0xD800) << 10) + (low - 0xDC00) + 0x10000 }
    @inline(__always) private func rank(_ value: UInt32) -> UInt8 { tables.rankOf(value) }

    private func decompose(_ value: UInt32, room: Int) -> Scalars {
        if value >= hangulSyllableBase && value <= hangulSyllableBase + hangulSyllableCount {
            let index = value - hangulSyllableBase
            var out: Scalars = [index / 588 + 0x1100, (index % 588) / 28 + 0x1161]
            if index % 28 != 0 { out.append(index % 28 + 0x11A7) }
            return out.count <= room ? out : []
        }
        guard let pieces = tables.decomposition[value] else { return [] }
        let needed = tables.markSpace[value] ?? pieces.count
        return needed <= room ? pieces : []
    }

    private func sortByClass(_ buffer: inout Scalars) {
        var start = 0
        while start < buffer.count && rank(buffer[start]) == 0 { start += 1 }
        guard buffer.count - start > 1 else { return }
        var changes = true
        while changes {
            changes = false
            var p2 = rank(buffer[start])
            var index = start + 1
            while index < buffer.count {
                let p1 = p2
                p2 = rank(buffer[index])
                if p1 > p2 {
                    buffer.swapAt(index - 1, index)
                    changes = true
                }
                index += 1
            }
        }
    }

    /// The composition loop on a run whose first scalar is the base; for the probe.
    func precomposedRun(_ run: Scalars) -> Scalars {
        var mapped = run
        composeRun(&mapped)
        return mapped
    }

    private func composeRun(_ mapped: inout Scalars) {
        guard mapped.count > 1 else { return }
        var current = mapped[0]
        var lastClass: UInt8 = 0
        var didCombine = false
        var consumed = 1
        while consumed < mapped.count {
            let next = mapped[consumed]
            let currentClass = rank(next)
            if lastClass == 0 || currentClass > lastClass {
                let composite = tables.precompose(current, next)
                if composite == 0xFFFD {
                    lastClass = currentClass
                } else {
                    mapped[consumed] = 0xFFFD
                    didCombine = true
                    current = composite
                }
            }
            consumed += 1
        }
        mapped[0] = current
        if didCombine {
            var index = mapped.count - 1
            while index > 0 {
                if mapped[index] == 0xFFFD { mapped.remove(at: index) }
                index -= 1
            }
        }
    }

    func precomposed(_ input: Scalars) -> Scalars {
        // The UTF-16 buffer CoreFoundation edits in place.
        var units: [UInt32] = []
        units.reserveCapacity(input.count * 2)
        for value in input {
            if value > 0xFFFF {
                units.append(((value - 0x10000) >> 10) + 0xD800)
                units.append(((value - 0x10000) & 0x3FF) + 0xDC00)
            } else {
                units.append(value)
            }
        }

        var currentIndex = 0
        var contents = 0
        while contents < units.count {
            var currentChar: UInt32
            var currentLength: Int
            if isHigh(units[contents]) && contents + 1 < units.count && isLow(units[contents + 1]) {
                currentChar = pair(units[contents], units[contents + 1])
                currentLength = 2
                contents += 2
            } else {
                currentChar = units[contents]
                currentLength = 1
                contents += 1
            }
            var mapped: Scalars = []

            if tables.isDecomposable(currentChar) && rank(currentChar) == 0 {
                if currentChar < hangulSyllableBase || currentChar > hangulSyllableBase + hangulSyllableCount {
                    mapped = decompose(currentChar, room: precomposeBufferLength)
                }
            }

            @inline(__always) func charAt(_ position: Int) -> UInt32 {
                if isHigh(units[position]) && position + 1 < units.count && isLow(units[position + 1]) {
                    return pair(units[position], units[position + 1])
                }
                return units[position]
            }

            if contents < units.count || mapped.isEmpty {
                if !mapped.isEmpty { currentChar = charAt(contents) }
                if rank(currentChar) != 0 {
                    let width = currentChar > 0xFFFF ? 2 : 1
                    if mapped.isEmpty {
                        contents -= width
                        if currentIndex > 0 {
                            if isLow(units[contents - 1]) && currentIndex > 1 && isHigh(units[contents - 2]) {
                                mapped.append(pair(units[contents - 2], units[contents - 1]))
                                currentIndex -= 2
                                currentLength += 2
                            } else {
                                mapped.append(units[contents - 1])
                                currentIndex -= 1
                                currentLength += 1
                            }
                        }
                    } else {
                        currentLength += width
                    }
                    contents += width

                    if tables.isDecomposable(currentChar) {
                        mapped += decompose(currentChar, room: precomposeBufferLength - mapped.count)
                    } else {
                        mapped.append(currentChar)
                    }

                    while contents < units.count {
                        currentChar = charAt(contents)
                        if rank(currentChar) == 0 { break }
                        if currentChar > 0xFFFF {
                            contents += 2
                            currentLength += 2
                        } else {
                            contents += 1
                            currentLength += 1
                        }
                        if tables.isDecomposable(currentChar) {
                            mapped += decompose(currentChar, room: precomposeBufferLength - mapped.count)
                        } else {
                            mapped.append(currentChar)
                        }
                    }
                }
                if mapped.count > 1 { sortByClass(&mapped) }
            }

            if mapped.count > 1 {
                composeRun(&mapped)
            } else if currentChar >= 0x1100 && currentChar < 0x1100 + 0xFF {
                let lIndex = Int(Int8(truncatingIfNeeded: currentChar - 0x1100))
                if contents < units.count && lIndex >= 0 && lIndex <= 19 {
                    let vIndex = Int(Int16(truncatingIfNeeded: units[contents])) - 0x1161
                    if vIndex >= 0 && vIndex <= 21 {
                        var tIndex = 0
                        contents += 1
                        currentLength += 1
                        if contents < units.count {
                            tIndex = Int(Int16(truncatingIfNeeded: units[contents])) - 0x11A7
                            if tIndex < 0 || tIndex > 28 {
                                tIndex = 0
                            } else {
                                contents += 1
                                currentLength += 1
                            }
                        }
                        mapped = [UInt32((lIndex * 21 + vIndex) * 28 + tIndex) + hangulSyllableBase]
                    }
                }
            } else {
                while contents < units.count {
                    let next = charAt(contents)
                    if !tables.nonBaseStarter.contains(next) || rank(next) != 0 { break }
                    currentChar = tables.precompose(currentChar, next)
                    if currentChar == 0xFFFD { break }
                    if next < 0x10000 {
                        contents += 1
                        currentLength += 1
                    } else {
                        contents += 2
                        currentLength += 2
                    }
                    mapped = [currentChar]
                }
            }

            if !mapped.isEmpty {
                var replacement: [UInt32] = []
                for value in mapped {
                    if value > 0xFFFF {
                        replacement.append(((value - 0x10000) >> 10) + 0xD800)
                        replacement.append(((value - 0x10000) & 0x3FF) + 0xDC00)
                    } else {
                        replacement.append(value)
                    }
                }
                units.replaceSubrange(currentIndex..<(currentIndex + currentLength), with: replacement)
                currentLength = replacement.count
                contents = currentIndex + currentLength
            }
            currentIndex += currentLength
        }

        // Back to scalars as a Swift string reads them: an unpaired surrogate is U+FFFD.
        var out: Scalars = []
        out.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            let unit = units[index]
            if isHigh(unit) && index + 1 < units.count && isLow(units[index + 1]) {
                out.append(pair(unit, units[index + 1]))
                index += 2
            } else {
                out.append(isHigh(unit) || isLow(unit) ? 0xFFFD : unit)
                index += 1
            }
        }
        return out
    }
}

// MARK: - Families, verification and output

/// The strings the model is checked on, in a fixed order that the Kotlin test
/// (`FoundationPrecomposedTest`) walks too. `pool` is written to the digest file.
let precomposedLeaders: Scalars = [0x00E7, 0x0F40, 0xAC00, 0xAC01, 0x1100, 0x1113, 0x10041, 0x11100, 0x0DD9, 0x0B47, 0x1D157, 0x05D0, 0x1E0C]
let precomposedFollowers: Scalars = [0x0327, 0x0F39, 0x0F73, 0x11AB, 0x1161, 0x1176, 0x11A7, 0x11C3, 0x0DCF, 0x0334, 0x0345, 0x0344, 0x3099]

func precomposedPool(_ tables: PrecomposedTables) -> Scalars {
    var pool = Set<UInt32>()
    for scalar in allScalars where tables.rank[Int(scalar)] != 0 || tables.decomposition[scalar] != nil {
        pool.insert(scalar)
    }
    for (mark, bases) in tables.compose {
        pool.insert(mark)
        for (base, composite) in bases {
            pool.insert(base)
            pool.insert(composite)
            pool.insert(base | 0x10000)
        }
    }
    for jamo in UInt32(0x1100)...0x11FF { pool.insert(jamo) }
    for extra in [0xAC00, 0xAC01, 0xD7A3, 0x61, 0x41, 0x10041, 0xFFFD, 0x20, 0x0F40] as Scalars { pool.insert(extra) }
    return pool.filter { $0 <= 0x10FFFF && !(0xD800...0xDFFF).contains($0) }.sorted()
}

func forEachPrecomposedCase(_ pool: Scalars, _ visit: (String, Scalars) -> Void) {
    for scalar in allScalars { visit("single", [scalar]) }
    for scalar in allScalars { visit("after 0061", [0x61, scalar]) }
    for scalar in allScalars { visit("before 0301", [scalar, 0x0301]) }
    for leader in precomposedLeaders {
        let name = "after \(hex(leader))"
        for scalar in allScalars { visit(name, [leader, scalar]) }
    }
    for follower in precomposedFollowers {
        let name = "before \(hex(follower))"
        for scalar in allScalars { visit(name, [scalar, follower]) }
    }
    for scalar in allScalars { visit("before 0F39 0F73", [scalar, 0x0F39, 0x0F73]) }
    for scalar in allScalars { visit("before 0301 0327", [scalar, 0x0301, 0x0327]) }
    for scalar in allScalars { visit("between 0061 0301", [0x61, scalar, 0x0301]) }
    for lead in UInt32(0x1100)...0x11FF { for vowel in UInt32(0x1100)...0x11FF { visit("jamo pairs", [lead, vowel]) } }
    for lead in UInt32(0x1100)...0x1114 {
        for vowel in UInt32(0x1160)...0x1177 {
            for trail in UInt32(0x11A6)...0x11C4 { visit("jamo triples", [lead, vowel, trail]) }
        }
    }
    for syllable in UInt32(0xAC00)...0xD7A4 {
        for trail in UInt32(0x11A6)...0x11C4 { visit("syllable and trail", [syllable, trail]) }
    }
    var random = SeededRandom(seed: 12345)
    for _ in 0..<3_000_000 {
        let length = 1 + random.int(8)
        var input: Scalars = []
        for _ in 0..<length {
            input.append(random.int(10) == 0 ? allScalars[random.int(allScalars.count)] : pool[random.int(pool.count)])
        }
        visit("random", input)
    }
    // Runs that reach CoreFoundation's 64-scalar buffer, where a decomposable mark is dropped.
    let fillers: Scalars = [0x0334, 0x0301, 0x0345, 0x05B0]
    for length in 55...75 {
        for mark in [0x0344, 0x0340, 0x0341, 0x0343, 0x0301] as Scalars {
            for leader in [0x61, 0x00E9, 0x05D0, 0x1E09] as Scalars {
                for filler in fillers {
                    for position in [length - 1, length - 3, length / 2] {
                        var input = [leader] + Scalars(repeating: filler, count: length)
                        input[position] = mark
                        visit("long runs", input)
                        visit("long runs", input + [0x0344, 0x0301])
                        visit("long runs", input + [0x61])
                    }
                }
            }
        }
    }
    var long = SeededRandom(seed: 67890)
    for _ in 0..<20_000 {
        let length = 40 + long.int(40)
        var input: Scalars = [pool[long.int(pool.count)]]
        for _ in 0..<length { input.append(pool[long.int(pool.count)]) }
        visit("random long", input)
    }
}

/// Families whose changed strings are written out one per line, for readable failures.
private let listedFamilies: Set<String> = ["single", "after 0061", "before 0301", "after 10041", "after AC00", "after 1113", "jamo triples"]

let precomposedBlockSize = 65_536

/// Compares the model with Foundation on every family and returns the digest lines and
/// the listed rows. Stops the generator on the first difference.
func verifyPrecomposedModel(_ tables: PrecomposedTables, pool: Scalars) -> (checked: Int, digests: [String], rows: [String]) {
    let model = PrecomposedModel(tables: tables)

    // Nothing below U+0300 composes, decomposes into anything else, or joins a run.
    for first in UInt32(0)..<0x300 {
        for second in UInt32(0)..<0x300 {
            require(foundationPrecomposed([first, second]) == [first, second], "U+\(hex(first)) U+\(hex(second)) changes")
        }
    }

    var checked = 0
    var digests: [String] = []
    var rows: [String] = []
    var family = ""
    var block = 0
    var inBlock = 0
    var hasher = SHA256()

    func flush() {
        guard inBlock > 0 else { return }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        digests.append("digest\t\(family)\t\(block)\t\(inBlock)\t\(digest)")
        hasher = SHA256()
        inBlock = 0
        block += 1
    }

    forEachPrecomposedCase(pool) { name, input in
        if name != family {
            flush()
            family = name
            block = 0
        }
        let expected = foundationPrecomposed(input)
        let actual = model.precomposed(input)
        require(actual == expected, "\(name): \(hex(input)) is \(hex(expected)) in Foundation, \(hex(actual)) in the model")
        var bytes: [UInt8] = []
        bytes.reserveCapacity(expected.count * 4 + 4)
        for value in expected + [0xFFFF_FFFF] {
            bytes.append(UInt8(value >> 24)); bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF)); bytes.append(UInt8(value & 0xFF))
        }
        hasher.update(data: bytes)
        inBlock += 1
        checked += 1
        if inBlock == precomposedBlockSize { flush() }
        if expected != input && listedFamilies.contains(name) || name == "random" && checked % 97 == 0 {
            rows.append("\(name)\t\(hex(input))\t\(hex(expected))")
        }
    }
    flush()
    return (checked, digests, rows)
}

func precomposedResourceLines(_ tables: PrecomposedTables, environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "CoreFoundation tables for String.precomposedStringWithCanonicalMapping (CFStringNormalize, form C)",
        [
            "Sections: [decomposition] scalar -> its unsorted canonical decomposition (Hangul",
            "syllables are algorithmic and absent); [rank] a value that orders and ties as",
            "CoreFoundation's combining class (255: a decomposable mark, only ever tested for 0);",
            "[compose] mark, base, composite (a BMP mark looks its base up by the low 16 bits);",
            "[nonbasestarter] class-0 marks that join a run; [markspace] mark, free buffer slots",
            "it needs. The rule that uses them is FoundationPrecomposed.kt.",
        ])
    lines.append("[decomposition]")
    for scalar in tables.decomposition.keys.sorted() {
        lines.append("\(hex(scalar)) \(hex(tables.decomposition[scalar]!))")
    }
    lines.append("[rank]")
    lines += rangeLines(skip: 0, key: { tables.rank[Int($0)] }, format: { String($0) })
    lines.append("[compose]")
    for mark in tables.compose.keys.sorted() {
        for base in tables.compose[mark]!.keys.sorted() {
            lines.append("\(hex(mark)) \(hex(base)) \(hex(tables.compose[mark]![base]!))")
        }
    }
    lines.append("[nonbasestarter]")
    for mark in tables.nonBaseStarter.sorted() { lines.append(hex(mark)) }
    lines.append("[markspace]")
    for mark in tables.markSpace.keys.sorted() { lines.append("\(hex(mark)) \(tables.markSpace[mark]!)") }
    return lines
}

func precomposedDigestLines(_ pool: Scalars, digests: [String], checked: Int, environment: GeneratorEnvironment) -> [String] {
    var lines = environment.header(
        "SHA-256 of precomposedStringWithCanonicalMapping over \(checked) strings",
        [
            "pool<TAB>scalars the random families draw from (see forEachPrecomposedCase);",
            "digest<TAB>family<TAB>block<TAB>strings<TAB>SHA-256 of every result in the block,",
            "each as 32-bit big-endian scalars followed by FFFFFFFF. Blocks hold \(precomposedBlockSize) strings.",
        ])
    lines.append("pool\t\(hex(pool))")
    lines += digests
    return lines
}

func precomposedCorpusLines(_ rows: [String], environment: GeneratorEnvironment) -> [String] {
    environment.header(
        "String.precomposedStringWithCanonicalMapping, a readable sample of the digested families",
        ["family<TAB>input<TAB>result; every changed string of a few families and every 97th string overall of the random one"])
        + rows
}
