package com.khm.snippets.core.model

import com.khm.snippets.core.text.FoundationText

/** Tag normalization and identity (`SnippetTagging` in `Snippet.swift`). */
object SnippetTagging {

    /**
     * `SnippetTagging.normalizedTags`: each tag trimmed, its inner runs of whitespace and
     * newlines collapsed to one space, empty tags dropped, and of the tags that share a
     * [filterKey] only the first spelling kept. Input order is preserved.
     */
    fun normalizedTags(rawTags: List<String>): List<String> {
        val seenKeys = HashSet<String>()
        val normalized = ArrayList<String>(rawTags.size)
        for (rawTag in rawTags) {
            val tag = collapseWhitespace(rawTag)
            if (tag.isEmpty()) continue
            if (seenKeys.add(filterKey(tag))) normalized.add(tag)
        }
        return normalized
    }

    /**
     * The key that decides tag identity, tag filtering and keyword collisions: the tag
     * folded without regard to case or diacritics, against a fixed locale so that every
     * device computes the same key from the same text.
     *
     * Swift compares these keys with `==`, `<` and `Set<String>`, all of which treat
     * canonically equivalent strings as one. So the key is returned in Normalization
     * Form C: two keys are the same key in Swift exactly when they are `==` here, and
     * [FoundationText.compareScalars] orders them as Swift's `<` does.
     */
    fun filterKey(tag: String): String = FoundationText.nfc(FoundationText.fold(tag))

    /**
     * The key scalar for scalar as Foundation returns it, not normalized. Only for code
     * that reads the key's bytes, such as the hash that picks a tag's colour.
     */
    fun rawFilterKey(tag: String): String = FoundationText.fold(tag)

    private fun collapseWhitespace(rawTag: String): String {
        val out = StringBuilder(rawTag.length)
        for (piece in FoundationText.splitOnWhitespaceAndNewlines(rawTag)) {
            if (piece.isEmpty()) continue
            if (out.isNotEmpty()) out.append(' ')
            out.append(piece)
        }
        return out.toString()
    }
}
