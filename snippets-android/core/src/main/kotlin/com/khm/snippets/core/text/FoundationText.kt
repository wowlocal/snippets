package com.khm.snippets.core.text

import java.text.Normalizer

/**
 * The text behaviour of Foundation and of Swift's `String` that the Swift sources rely
 * on and that Kotlin's own string functions do not have.
 *
 * - Character sets: Foundation's `.whitespaces`, `.newlines` and `.whitespacesAndNewlines`
 *   differ from `Char.isWhitespace` (U+0085 and U+200B are members, U+001C…U+001F are not).
 * - Characters: a Swift `Character` is an extended grapheme cluster, so `count`, `prefix`
 *   and `hasPrefix` work on clusters, not on UTF-16 units.
 * - Equality and order: Swift's `==` on strings is canonical equivalence and `<` is
 *   documented as the scalar order of the normalized form. Kotlin's are UTF-16 code unit
 *   comparisons. See [compare] for where Swift's own `<` departs from its documentation.
 *
 * A Kotlin string can hold an unpaired surrogate, which a Swift string cannot. Every
 * function here accepts one and leaves it where it is.
 * - Case: `lowercased()` and `uppercased()` map scalar by scalar, without the JVM's
 *   final-sigma rule.
 * - Folding: `String.folding(options:locale:)` as `SnippetTagging.filterKey` calls it.
 *
 * Expected results for all of these are generated from Foundation
 * (`tools/foundation-tables`) and checked in the tests.
 */
object FoundationText {

    // Character sets

    /** `CharacterSet.whitespaces.contains(_:)`. */
    fun isWhitespace(scalar: Int): Boolean = when (scalar) {
        0x0009, 0x0020, 0x00A0, 0x1680, 0x202F, 0x205F, 0x3000 -> true
        else -> scalar in 0x2000..0x200B
    }

    /** `CharacterSet.newlines.contains(_:)`. */
    fun isNewline(scalar: Int): Boolean =
        scalar in 0x000A..0x000D || scalar == 0x0085 || scalar == 0x2028 || scalar == 0x2029

    /** `CharacterSet.whitespacesAndNewlines.contains(_:)`. */
    fun isWhitespaceOrNewline(scalar: Int): Boolean = isWhitespace(scalar) || isNewline(scalar)

    /** `text.trimmingCharacters(in: .whitespacesAndNewlines)`. */
    fun trimWhitespaceAndNewlines(text: String): String = trim(text, ::isWhitespaceOrNewline)

    /** `text.trimmingCharacters(in: .whitespaces)`. */
    fun trimWhitespace(text: String): String = trim(text, ::isWhitespace)

    // Every member of the three sets is one UTF-16 unit, so scanning units is scanning scalars.
    private inline fun trim(text: String, isMember: (Int) -> Boolean): String {
        var start = 0
        var end = text.length
        while (start < end && isMember(text[start].code)) start += 1
        while (end > start && isMember(text[end - 1].code)) end -= 1
        return if (start == 0 && end == text.length) text else text.substring(start, end)
    }

    /**
     * `text.components(separatedBy: .whitespacesAndNewlines)`: one piece per separator
     * plus one, so adjacent separators and separators at either end yield empty pieces.
     */
    fun splitOnWhitespaceAndNewlines(text: String): List<String> {
        val pieces = ArrayList<String>()
        var pieceStart = 0
        for (index in text.indices) {
            if (isWhitespaceOrNewline(text[index].code)) {
                pieces.add(text.substring(pieceStart, index))
                pieceStart = index + 1
            }
        }
        pieces.add(text.substring(pieceStart))
        return pieces
    }

    // Characters (extended grapheme clusters)

    /**
     * The index just past the `Character` that starts at [index]. [index] must be the
     * start of a `Character`: 0, or a value this function returned.
     */
    fun nextCharacterBoundary(text: CharSequence, index: Int): Int {
        require(index >= 0 && index < text.length) { "index outside the text" }
        return GraphemeBreaker.clusterEnd(text, index)
    }

    /** `text.count` in Swift. */
    fun characterCount(text: CharSequence): Int {
        var count = 0
        var index = 0
        while (index < text.length) {
            index = GraphemeBreaker.clusterEnd(text, index)
            count += 1
        }
        return count
    }

    /** `String(text.prefix(maxCount))` in Swift: the first [maxCount] `Character`s, or all of them. */
    fun characterPrefix(text: String, maxCount: Int): String {
        require(maxCount >= 0) { "maxCount must not be negative" }
        var index = 0
        var taken = 0
        while (taken < maxCount && index < text.length) {
            index = GraphemeBreaker.clusterEnd(text, index)
            taken += 1
        }
        return if (index == text.length) text else text.substring(0, index)
    }

    /** `text.map(String.init)` in Swift: the `Character`s of [text], in order. */
    fun characters(text: String): List<String> {
        val result = ArrayList<String>()
        var index = 0
        while (index < text.length) {
            val end = GraphemeBreaker.clusterEnd(text, index)
            result.add(text.substring(index, end))
            index = end
        }
        return result
    }

    // Equality and order

    /**
     * Normalization Form C, from `java.text.Normalizer`. The data is the runtime's: a
     * scalar assigned after the runtime's Unicode version (10.0 on Android API 28) is
     * left as it stands, where a newer runtime or Swift would decompose or reorder it.
     */
    fun nfc(text: String): String = if (isUnaffectedByNormalization(text)) text else Normalizer.normalize(text, Normalizer.Form.NFC)

    /**
     * Canonical equivalence: `true` exactly when the [nfc] forms are identical. This is
     * what Swift's `a == b` on strings means.
     *
     * Two limits, both far from ordinary text. Normalization follows the runtime's
     * Unicode version (see [nfc]), so for scalars newer than that the answer can differ
     * from Swift's and between two Android versions. And Apple's normalizers do not move
     * an earlier mark behind the decomposition of U+0F73, U+0F75 or U+0F81 as the
     * standard requires, so Swift calls a few such strings different that are equal here.
     */
    fun canonicalEquals(first: String, second: String): Boolean {
        if (first == second) return true
        if (isUnaffectedByNormalization(first) && isUnaffectedByNormalization(second)) return false
        return nfc(first) == nfc(second)
    }

    /**
     * The order of two strings by the scalar values of their [nfc] forms: a total order,
     * zero exactly when [canonicalEquals] is true.
     *
     * This is the order Swift documents for `<` on strings, and for two strings that are
     * already in NFC it is the answer Swift gives. It is deliberately **not** a copy of
     * Swift's `<` beyond that: on strings that are not in NFC, Swift's operator is not an
     * order at all (it has cycles, and pairs for which neither `a < b` nor `b < a` holds,
     * so `sorted()` returns them in either order from one launch to the next), and a
     * comparator that copied it could not be sorted with. Swift differs from this
     * function in three classes of pairs:
     *
     * 1. Binary prefix: one string's code units are a prefix of the other's. Swift
     *    answers by length without normalizing; here a mark in the longer string may
     *    sort before the end of the shorter one (`U+0627 U+0653` is `U+0622`, below `U+0627`).
     * 2. U+0F73, U+0F75, U+0F81 after an earlier mark: Apple's normalizers leave that
     *    mark in front of the decomposition, the standard moves it behind.
     * 3. NFC prefix: the NFC forms are in a prefix relation but the code units are not
     *    (`U+0958` against `U+0915`). Swift answers "neither is smaller" although the
     *    strings are not equal.
     *
     * Anything that must come out the same on Apple devices, such as the order of tags
     * in a merged record, is only guaranteed to for NFC input.
     */
    fun compare(first: String, second: String): Int = compareScalars(nfc(first), nfc(second))

    /** [compare] as a `Comparator`: a total order, safe for `sortedWith`. See [compare] for how it relates to Swift's `sorted()`. */
    val order: Comparator<String> = Comparator { first, second -> compare(first, second) }

    /**
     * Order by scalar value without normalizing, which is also the order of the UTF-8
     * bytes. `String.compareTo` differs: it puts U+E000…U+FFFF after supplementary scalars.
     */
    fun compareScalars(first: String, second: String): Int {
        val common = minOf(first.length, second.length)
        for (index in 0 until common) {
            val a = first[index]
            val b = second[index]
            if (a != b) return scalarRank(a) - scalarRank(b)
        }
        return first.length - second.length
    }

    // Moves the surrogates above U+E000…U+FFFF: at the first differing unit, two
    // supplementary scalars compare by their surrogates, and a surrogate against a BMP
    // unit must count as the larger.
    private fun scalarRank(unit: Char): Int = when {
        unit < '\uD800' -> unit.code
        unit <= '\uDFFF' -> unit.code + 0x2000
        else -> unit.code - 0x0800
    }

    // Below U+0300 nothing decomposes, composes or reorders.
    private fun isUnaffectedByNormalization(text: String): Boolean {
        for (unit in text) if (unit.code >= 0x0300) return false
        return true
    }

    // Case

    /**
     * Swift's `text.lowercased()`: every scalar mapped on its own with Swift's tables. No
     * locale and no context, so `ΑΣ` becomes `ασ`; `lowercase(Locale.ROOT)` would write a
     * final sigma and depends on the runtime's Unicode version. Use this wherever the
     * Swift source says `lowercased()`.
     */
    fun swiftLowercased(text: String): String = SwiftCase.lowercased(text)

    /** Swift's `text.uppercased()`, scalar by scalar like [swiftLowercased]: `ß` becomes `SS`, `ǅ` becomes `Ǆ`. */
    fun swiftUppercased(text: String): String = SwiftCase.uppercased(text)

    // Folding

    /**
     * `text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))`,
     * scalar for scalar what Foundation returns. The result is not normalized: compare two
     * folds with [canonicalEquals] or [compare], as Swift does, never with `==`.
     */
    fun fold(text: String): String = FoundationFold.fold(text)
}
