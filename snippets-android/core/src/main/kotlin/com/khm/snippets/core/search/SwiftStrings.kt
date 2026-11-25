package com.khm.snippets.core.search

import com.khm.snippets.core.text.FoundationText

/**
 * The Swift `String` operations the utilities are written with, built on [FoundationText].
 *
 * A Swift `String` is a sequence of `Character`s (extended grapheme clusters) and compares
 * them by canonical equivalence. `hasPrefix`, `contains`, `split` and `==` therefore never
 * match half a `Character`: `"e\u{301}x".hasPrefix("e")` is false, and `"\r\n"` does not
 * contain `"\n"`. Kotlin's functions of the same names compare UTF-16 units.
 */
internal object SwiftStrings {

    /** Below U+0300 no scalar combines with its neighbour, except CR LF. */
    private const val FIRST_COMBINING_UNIT = 0x0300

    fun isPlain(text: CharSequence): Boolean {
        for (index in text.indices) {
            val unit = text[index].code
            if (unit >= FIRST_COMBINING_UNIT || unit == '\r'.code) return false
        }
        return true
    }

    /** The `Character`s of [text], each in Normalization Form C, so `==` on two of them is Swift's `==`. */
    fun characters(text: String): List<String> {
        if (isPlain(text)) return List(text.length) { text[it].toString() }
        return FoundationText.characters(text).map(FoundationText::nfc)
    }

    /**
     * Whether [index] is a `Character` boundary of [text]. Walks from the start only when
     * the neighbours could belong to one cluster.
     */
    fun isCharacterBoundary(text: String, index: Int): Boolean {
        if (index <= 0 || index >= text.length) return index == 0 || index == text.length
        val before = text[index - 1].code
        val after = text[index].code
        if (before < FIRST_COMBINING_UNIT && after < FIRST_COMBINING_UNIT) {
            return !(before == '\r'.code && after == '\n'.code)
        }
        var boundary = 0
        while (boundary < index) boundary = FoundationText.nextCharacterBoundary(text, boundary)
        return boundary == index
    }

    /**
     * Foundation's `text.contains(needle)` for two strings that are already in
     * Normalization Form C: [needle] occurs as a run of whole `Character`s. An empty
     * needle is never contained.
     */
    fun containsNormalized(text: String, needle: String): Boolean {
        if (needle.isEmpty() || needle.length > text.length) return false
        var from = 0
        while (true) {
            val found = text.indexOf(needle, from)
            if (found < 0) return false
            if (isCharacterBoundary(text, found) && isCharacterBoundary(text, found + needle.length)) return true
            from = found + 1
        }
    }

    /** Foundation's `text.contains(needle)`. */
    fun contains(text: String, needle: String): Boolean =
        containsNormalized(FoundationText.nfc(text), FoundationText.nfc(needle))

    /** Swift's `text.hasPrefix(prefix)`. Every string has the empty prefix. */
    fun hasPrefix(text: String, prefix: String): Boolean {
        if (prefix.isEmpty()) return true
        val normalizedText = FoundationText.nfc(text)
        val normalizedPrefix = FoundationText.nfc(prefix)
        return normalizedText.startsWith(normalizedPrefix) &&
            isCharacterBoundary(normalizedText, normalizedPrefix.length)
    }

    /**
     * Swift's `Character.isWhitespace` for one `Character`: a single scalar with the
     * Unicode `White_Space` property, or CR LF.
     */
    fun isWhitespaceCharacter(character: String): Boolean {
        if (character == "\r\n") return true
        if (character.length != 1) return false
        return when (val scalar = character[0].code) {
            0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 -> true
            else -> scalar in 0x2000..0x200A
        }
    }

    /** Swift's `text.split(whereSeparator:)` on `Character`s, empty pieces omitted. */
    inline fun split(text: String, isSeparator: (String) -> Boolean): List<String> {
        val pieces = ArrayList<String>()
        val piece = StringBuilder()
        for (character in characters(text)) {
            if (isSeparator(character)) {
                if (piece.isNotEmpty()) {
                    pieces.add(piece.toString())
                    piece.setLength(0)
                }
            } else {
                piece.append(character)
            }
        }
        if (piece.isNotEmpty()) pieces.add(piece.toString())
        return pieces
    }
}
