package com.khm.snippets.core.model

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.text.FoundationText
import java.util.UUID

/**
 * One ordinary snippet: the nine fields `snippets.json` stores (`Snippet` in
 * `Snippet.swift`). Immutable; change one with [copy].
 *
 * Timestamps are doubles of seconds since 2001-01-01 UTC, kept exactly as read; see
 * [AppleTime]. [createdAt] never changes after creation and drives the display order.
 *
 * Equality is Swift's: text fields compare by canonical equivalence (`é` equals `e` +
 * U+0301) and timestamps as IEEE doubles (`0.0` equals `-0.0`). Whole-snippet equality
 * decides whether the library is written, so it has to give the answers Swift gives.
 * Unlike Swift, a not-a-number timestamp equals itself, which `equals` requires; the
 * decoder cannot produce one. Canonical equivalence is computed by the runtime
 * ([com.khm.snippets.core.text.FoundationText.canonicalEquals]).
 *
 * Text fields should be well-formed: the codec writes an unpaired surrogate as U+FFFD.
 */
data class Snippet(
    val id: UUID = UUID.randomUUID(),
    val name: String,
    /** As typed. The store saves [normalizedKeyword]; empty means no trigger. */
    val keyword: String,
    val content: String,
    val tags: List<String> = emptyList(),
    val isEnabled: Boolean = true,
    val isPinned: Boolean = false,
    val createdAt: Double = AppleTime.now(),
    val updatedAt: Double = AppleTime.now(),
) {

    /** The trimmed [name]; without one, the first content line; without that, `Untitled Snippet`. */
    val displayName: String
        get() {
            val trimmed = FoundationText.trimWhitespaceAndNewlines(name)
            if (trimmed.isNotEmpty()) return trimmed
            val firstLine = contentFirstLine
            return if (firstLine.isEmpty()) UNTITLED else firstLine
        }

    /** `sanitizedKeyword(keyword)`. */
    val normalizedKeyword: String
        get() = sanitizedKeyword(keyword)

    /**
     * The line that stands in for an unnamed snippet, whole: the first line of [content]
     * that is not blank, trimmed of whitespace and newlines; empty if there is none.
     * Lines end at any scalar of Foundation's `.newlines`.
     */
    val contentFirstLineUntruncated: String
        get() {
            val text = content
            var lineStart = 0
            var index = 0
            // Every newline and whitespace scalar is one UTF-16 unit.
            while (index <= text.length) {
                if (index == text.length || FoundationText.isNewline(text[index].code)) {
                    val line = trimmedLine(text, lineStart, index)
                    if (line != null) return line
                    lineStart = index + 1
                }
                index += 1
            }
            return ""
        }

    /** [contentFirstLineUntruncated] cut to 50 `Character`s plus `…` when it is longer. */
    val contentFirstLine: String
        get() {
            val line = contentFirstLineUntruncated
            val prefix = FoundationText.characterPrefix(line, FIRST_LINE_CHARACTERS)
            return if (prefix.length == line.length) line else "$prefix…"
        }

    /** Whether a tag of this snippet has the filter key [key] (from [SnippetTagging.filterKey]). */
    fun hasTag(key: String): Boolean =
        tags.any { FoundationText.canonicalEquals(SnippetTagging.filterKey(it), key) }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Snippet) return false
        return id == other.id &&
            isEnabled == other.isEnabled &&
            isPinned == other.isPinned &&
            sameInstant(createdAt, other.createdAt) &&
            sameInstant(updatedAt, other.updatedAt) &&
            FoundationText.canonicalEquals(name, other.name) &&
            FoundationText.canonicalEquals(keyword, other.keyword) &&
            tags.size == other.tags.size &&
            tags.indices.all { FoundationText.canonicalEquals(tags[it], other.tags[it]) } &&
            FoundationText.canonicalEquals(content, other.content)
    }

    // Equal snippets have equal ids; hashing the text would mean normalizing it first.
    override fun hashCode(): Int = id.hashCode()

    /** Names the record only: a snippet's text must not reach a log or a crash report by accident. */
    override fun toString(): String = "Snippet(id=$id)"

    companion object {

        private const val UNTITLED = "Untitled Snippet"
        private const val FIRST_LINE_CHARACTERS = 50

        /**
         * `Snippet.sanitizedKeyword`: trim whitespace and newlines; while the keyword
         * starts with a backslash, drop it and trim again; then join the pieces between
         * whitespace with `-`. Case is kept.
         *
         * "Starts with a backslash" is Swift's `hasPrefix`, which compares `Character`s:
         * a backslash followed by a combining mark is one `Character` and stays.
         */
        fun sanitizedKeyword(rawKeyword: String): String {
            var keyword = FoundationText.trimWhitespaceAndNewlines(rawKeyword)
            while (keyword.isNotEmpty() && keyword[0] == '\\' &&
                FoundationText.nextCharacterBoundary(keyword, 0) == 1
            ) {
                keyword = FoundationText.trimWhitespaceAndNewlines(keyword.substring(1))
            }
            val out = StringBuilder(keyword.length)
            for (piece in FoundationText.splitOnWhitespaceAndNewlines(keyword)) {
                if (piece.isEmpty()) continue
                if (out.isNotEmpty()) out.append('-')
                out.append(piece)
            }
            return out.toString()
        }

        private fun trimmedLine(text: String, start: Int, end: Int): String? {
            var trimmedStart = start
            while (trimmedStart < end && FoundationText.isWhitespaceOrNewline(text[trimmedStart].code)) trimmedStart += 1
            if (trimmedStart >= end) return null
            var trimmedEnd = end
            while (trimmedEnd > trimmedStart && FoundationText.isWhitespaceOrNewline(text[trimmedEnd - 1].code)) trimmedEnd -= 1
            return text.substring(trimmedStart, trimmedEnd)
        }

        // Swift's `Date ==` is the doubles' `==`; NaN is made equal to itself for `equals`.
        private fun sameInstant(first: Double, second: Double): Boolean =
            first == second || (first.isNaN() && second.isNaN())
    }
}
