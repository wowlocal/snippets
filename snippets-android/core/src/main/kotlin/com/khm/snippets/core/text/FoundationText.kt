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
 * - Equality and order: Swift's `==` on strings is canonical equivalence and `<` is the
 *   scalar order of the normalized form. Kotlin's are UTF-16 code unit comparisons.
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

    /** Normalization Form C. Two Swift strings are `==` exactly when their NFC forms are identical. */
    fun nfc(text: String): String = if (isUnaffectedByNormalization(text)) text else Normalizer.normalize(text, Normalizer.Form.NFC)

    /**
     * Swift's `a == b` for strings: canonical equivalence.
     *
     * Normalization comes from the runtime, so a scalar newer than the runtime's Unicode
     * version is compared as it stands. Normalization of assigned scalars never changes.
     */
    fun canonicalEquals(first: String, second: String): Boolean {
        if (first == second) return true
        if (isUnaffectedByNormalization(first) && isUnaffectedByNormalization(second)) return false
        return nfc(first) == nfc(second)
    }

    /**
     * Swift's `<` for strings as a three-way result: scalar-value order of the NFC forms.
     * Zero exactly when [canonicalEquals] is true.
     */
    fun compare(first: String, second: String): Int = compareScalars(nfc(first), nfc(second))

    /** [compare] as a `Comparator`, for `sortedWith` where Swift calls `sorted()` on strings. */
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

    // Folding

    /**
     * `text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))`,
     * scalar for scalar what Foundation returns. The result is not normalized: compare two
     * folds with [canonicalEquals] or [compare], as Swift does, never with `==`.
     */
    fun fold(text: String): String = FoundationFold.fold(text)
}
