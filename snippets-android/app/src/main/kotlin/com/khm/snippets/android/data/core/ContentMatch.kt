package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.TextRange
import com.khm.snippets.core.text.FoundationText

/**
 * Where a folded query first occurs, as a contiguous run, in a raw text: the highlight of a
 * content match (components.md §4.2, open question 10).
 *
 * The text is folded one `Character` at a time with the same fold as the search index, so a
 * match maps back to whole `Character`s of the raw text even where folding changes lengths
 * (`ß` folds to `ss`). Whether an entry matches is decided by the index; this only says where.
 *
 * @param foldedQuery The query as `SnippetSearchSnapshot.normalizedQuery` produces it.
 */
class ContentMatch(foldedQuery: String) {
    private val needle = FoundationText.nfc(foldedQuery)
    private val asciiNeedle = needle.takeIf(::isAscii)

    /** The range of the first match in [text], UTF-16 indices; null when there is none. */
    fun find(text: String): TextRange? {
        if (needle.isEmpty() || text.isEmpty()) return null
        if (asciiNeedle != null && isAscii(text)) return asciiMatch(text, asciiNeedle)
        return foldedMatch(text)
    }

    private fun asciiMatch(text: String, query: String): TextRange? {
        var from = 0
        while (true) {
            val index = text.indexOf(query, from, ignoreCase = true)
            if (index < 0) return null
            // CR LF is one Character: a match may not start or end between the two.
            val end = index + query.length
            val splitsStart = index > 0 && text[index - 1] == '\r' && text[index] == '\n'
            val splitsEnd = end < text.length && text[end - 1] == '\r' && text[end] == '\n'
            if (!splitsStart && !splitsEnd) return TextRange(index, end)
            from = index + 1
        }
    }

    private fun foldedMatch(text: String): TextRange? {
        val folded = StringBuilder(text.length)
        // For every folded unit: the raw Character it came from.
        val sourceStart = IntArrayBuilder(text.length)
        val sourceEnd = IntArrayBuilder(text.length)
        var offset = 0
        while (offset < text.length) {
            val end = FoundationText.nextCharacterBoundary(text, offset)
            val piece = FoundationText.nfc(FoundationText.fold(text.substring(offset, end)))
            for (unit in piece) {
                folded.append(unit)
                sourceStart.add(offset)
                sourceEnd.add(end)
            }
            offset = end
        }
        var from = 0
        while (from <= folded.length - needle.length) {
            val index = folded.indexOf(needle, from)
            if (index < 0) return null
            val last = index + needle.length - 1
            val startsOnCharacter = index == 0 || sourceStart[index - 1] != sourceStart[index]
            val endsOnCharacter = last == folded.length - 1 || sourceStart[last + 1] != sourceStart[last]
            if (startsOnCharacter && endsOnCharacter) return TextRange(sourceStart[index], sourceEnd[last])
            from = index + 1
        }
        return null
    }

    private class IntArrayBuilder(capacity: Int) {
        private var values = IntArray(maxOf(capacity, 1))
        private var size = 0

        fun add(value: Int) {
            if (size == values.size) values = values.copyOf(size * 2)
            values[size++] = value
        }

        operator fun get(index: Int): Int = values[index]
    }

    private companion object {
        fun isAscii(text: String): Boolean = text.all { it.code < 0x80 }
    }
}
