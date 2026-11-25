package com.khm.snippets.core.assist

import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.text.FoundationText

/**
 * What the snippet editor says about the keyword being edited: one warning, or the
 * suggestions to offer while it is empty. These are the rules of the two iOS editors
 * (`updateKeywordWarning` and `updateSuggestions` in `PhoneSnippetEditorViewController.swift`
 * and `SnippetEditorViewController.swift`), as data; the app phrases them.
 */
object KeywordAdvice {

    /** The iOS editors offer this many suggestions. */
    const val SUGGESTION_LIMIT: Int = 3

    sealed class Warning {
        /** No keyword: the snippet cannot be expanded by typing. */
        object MissingKeyword : Warning()

        /** The snippet is disabled, so its keyword does nothing. Other conflicts are not reported. */
        object Disabled : Warning()

        /** The keyword holds a `Character` of several scalars, which the expansion engine does not match. */
        object UnsupportedCharacters : Warning()

        /** [other] already uses this keyword. */
        data class Duplicate(val other: Snippet) : Warning()

        /** [other]'s keyword starts with this one, so this one never expands. */
        data class BlockedByLonger(val other: Snippet) : Warning()

        /** This keyword starts with [other]'s, which stops expanding. */
        data class BlocksShorter(val other: Snippet) : Warning()
    }

    /**
     * The first problem with [snippet]'s keyword, in the order the editors check them, or
     * `null`.
     *
     * @param enabledOthers the enabled ordinary snippets (longer keyword first, then the
     * more recently updated), followed by the enabled secure shells. [snippet] itself may
     * be among them and is skipped. The first conflicting entry is the one reported.
     *
     * An entry without a keyword is skipped. The iOS editors do not skip one: an enabled
     * secure snippet with no keyword makes them report that every keyword "prevents" it
     * from expanding, because the empty keyword is a prefix of all others.
     */
    fun warning(snippet: Snippet, enabledOthers: List<Snippet>): Warning? {
        val normalized = snippet.normalizedKeyword
        val keyword = KeywordRelation.folded(normalized)
        if (keyword.isEmpty()) return Warning.MissingKeyword
        if (!snippet.isEnabled) return Warning.Disabled
        if (hasMultiScalarCharacter(normalized)) return Warning.UnsupportedCharacters
        for (other in enabledOthers) {
            if (other.id == snippet.id) continue
            val otherKeyword = KeywordRelation.folded(other.normalizedKeyword)
            if (otherKeyword.isEmpty()) continue
            when (KeywordRelation.between(keyword, otherKeyword)) {
                KeywordRelation.DUPLICATE -> return Warning.Duplicate(other)
                KeywordRelation.BLOCKED_BY_LONGER -> return Warning.BlockedByLonger(other)
                KeywordRelation.BLOCKS_SHORTER -> return Warning.BlocksShorter(other)
                KeywordRelation.UNRELATED -> Unit
            }
        }
        return null
    }

    /**
     * The keywords to offer while the keyword field is empty: the first [limit]
     * [KeywordSuggestions.candidates] that are unrelated to every keyword in use.
     *
     * @param contentFirstLine the first content line of an ordinary snippet. Pass the
     * empty string for a secure snippet: its body must not leak into a suggestion.
     * @param enabledKeywords the keywords of the other enabled snippets, ordinary and secure.
     * Empty ones are ignored (on iOS one empty keyword suppresses every suggestion).
     */
    fun suggestions(
        name: String,
        contentFirstLine: String,
        enabledKeywords: List<String>,
        limit: Int = SUGGESTION_LIMIT,
    ): List<String> {
        val existing = enabledKeywords.map(KeywordRelation::folded).filter { it.isNotEmpty() }
        return KeywordSuggestions.candidates(name, contentFirstLine)
            .filter { candidate -> existing.all { KeywordRelation.between(candidate, it) == KeywordRelation.UNRELATED } }
            .take(maxOf(0, limit))
    }

    private fun hasMultiScalarCharacter(text: String): Boolean {
        var index = 0
        while (index < text.length) {
            val end = FoundationText.nextCharacterBoundary(text, index)
            if (end - index > Character.charCount(text.codePointAt(index))) return true
            index = end
        }
        return false
    }
}
