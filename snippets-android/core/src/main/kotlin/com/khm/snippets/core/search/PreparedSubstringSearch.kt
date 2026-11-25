package com.khm.snippets.core.search

import com.khm.snippets.core.text.FoundationText

/**
 * Literal "contains" over text that is already case- and diacritic-folded
 * (`PreparedSubstringSearch.swift`).
 *
 * `Field(text).contains(Query(needle))` is Swift's `text.contains(needle)`, except that an
 * empty needle is contained nowhere: canonically equivalent spellings match (`é` and `e` +
 * U+0301, the Kelvin sign and `K`), and a hit has to cover whole `Character`s, so `\n` is
 * not in `a\r\nb` and one emoji scalar is not in the sequence it belongs to.
 *
 * Both sides are normalized once when they are built; a search is then a plain substring
 * search plus a boundary check at each hit. Neither queries nor fields are stored or logged.
 */
object PreparedSubstringSearch {

    class Query(foldedText: String) {
        val text: String = foldedText
        internal val normalized: String = FoundationText.nfc(foldedText)
    }

    class Field(foldedText: String) {
        private val normalized: String = FoundationText.nfc(foldedText)

        /** UTF-16 units held, for the index's memory estimate. */
        internal val length: Int get() = normalized.length

        fun contains(query: Query): Boolean = SwiftStrings.containsNormalized(normalized, query.normalized)
    }
}
