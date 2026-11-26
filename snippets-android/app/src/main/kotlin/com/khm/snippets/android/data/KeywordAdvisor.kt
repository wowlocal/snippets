package com.khm.snippets.android.data

import java.util.UUID

/**
 * The entry whose keyword is being edited.
 *
 * @param keyword Already sanitised.
 * @param contentFirstLine First non-blank content line; always empty for a secure entry.
 */
data class KeywordDraft(
    val entryId: UUID,
    val keyword: String,
    val name: String,
    val contentFirstLine: String,
    val isEnabled: Boolean,
)

/** The one message the keyword field shows (screens-library-editor.md §6.5), in priority order. */
sealed interface KeywordAdvice {
    val isWarning: Boolean get() = false

    /** A keyword is set and nothing is wrong with it. */
    data object None : KeywordAdvice

    data object MissingKeyword : KeywordAdvice

    /** The entry is disabled, so the keyword will not expand. */
    data class EntryDisabled(val keyword: String) : KeywordAdvice

    /** The keyword contains a multi-scalar character (emoji, combined glyph). */
    data class InvalidCharacters(val keyword: String) : KeywordAdvice {
        override val isWarning: Boolean get() = true
    }

    /** Another enabled entry, ordinary or secure, has the same keyword. */
    data class Duplicate(val keyword: String, val otherName: String) : KeywordAdvice {
        override val isWarning: Boolean get() = true
    }

    /** Another enabled keyword starts with this one. */
    data class BlockedByLonger(val keyword: String, val longerKeyword: String) : KeywordAdvice {
        override val isWarning: Boolean get() = true
    }

    /** This keyword starts with another enabled keyword. */
    data class BlocksShorter(val shorterKeyword: String) : KeywordAdvice {
        override val isWarning: Boolean get() = true
    }
}

/** Existing keywords that match what was typed: at most eight [shown], and how many more exist. */
data class ExistingKeywords(val shown: List<String>, val moreCount: Int) {
    companion object {
        val None = ExistingKeywords(emptyList(), 0)
    }
}

/** Keyword suggestions and warnings for the editor. Pure and fast: called on every keystroke. */
interface KeywordAdvisor {
    fun advice(draft: KeywordDraft, snapshot: LibrarySnapshot): KeywordAdvice

    /** Up to three suggestions for an empty keyword; none collides with an enabled keyword. */
    fun suggestions(draft: KeywordDraft, snapshot: LibrarySnapshot): List<String>

    /** Keywords of other entries that match [query], best first. */
    fun existingMatches(query: String, entryId: UUID, snapshot: LibrarySnapshot): ExistingKeywords

    /**
     * What Space or Tab completes [query] to: the common continuation of the matching keywords
     * up to and including the next `.` or `-`, or null when there is none.
     */
    fun completion(query: String, entryId: UUID, snapshot: LibrarySnapshot): String?
}
