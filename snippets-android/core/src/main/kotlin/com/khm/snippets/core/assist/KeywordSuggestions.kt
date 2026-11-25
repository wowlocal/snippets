package com.khm.snippets.core.assist

import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.search.SwiftStrings
import com.khm.snippets.core.text.FoundationText

/**
 * How one keyword relates to another enabled keyword, in the terms of the expansion
 * engine: a keyword expands when it is the only exact match and no longer enabled keyword
 * starts with it (`KeywordRelation` in `KeywordSuggestions.swift`).
 *
 * The prefix relation runs one way, so its two ends are two different failures on two
 * different snippets.
 */
enum class KeywordRelation {
    UNRELATED,
    DUPLICATE,

    /** The other keyword extends this one, so this one never expands on its own. */
    BLOCKED_BY_LONGER,

    /** This keyword extends the other, so the other stops expanding. */
    BLOCKS_SHORTER;

    companion object {

        /**
         * `KeywordRelation.between`. Both sides must already be folded with [folded]. An
         * empty keyword is a prefix of every keyword.
         */
        fun between(keyword: String, other: String): KeywordRelation = when {
            FoundationText.canonicalEquals(keyword, other) -> DUPLICATE
            SwiftStrings.hasPrefix(other, keyword) -> BLOCKED_BY_LONGER
            SwiftStrings.hasPrefix(keyword, other) -> BLOCKS_SHORTER
            else -> UNRELATED
        }

        /** The fold the engine compares keywords by: sanitized, then [SnippetTagging.filterKey]. */
        fun folded(keyword: String): String = SnippetTagging.filterKey(Snippet.sanitizedKeyword(keyword))
    }
}

/**
 * Keywords a person might plausibly type for a snippet, and help with the keywords the
 * library already has (`KeywordSuggestions`).
 */
object KeywordSuggestions {

    /** A longer word is abbreviated instead of offered whole. */
    private const val WHOLE_WORD_MAX_LENGTH = 6
    private val ABBREVIATION_LENGTHS = intArrayOf(4, 3)

    /** One character triggers on nearly anything, so two is the shortest keyword offered. */
    private const val MINIMUM_LENGTH = 2
    private const val MAXIMUM_INITIALS = 5

    /** A first line that opens with a URL: step over the scheme to the host. */
    private val IGNORED_LEADING_WORDS = setOf("http", "https", "www")

    /**
     * `existingMatches(query:among:)`: the library's keywords that relate to what is being
     * typed. They are references for keeping a naming convention, not suggestions: an
     * exact result already belongs to another snippet.
     *
     * Keywords with the same fold are one keyword; the first spelling is returned. Best
     * first: the keyword itself, keywords it is a prefix of, keywords with a dot-separated
     * part equal to it, with a part it is a prefix of, keywords that contain it, and last,
     * for a query of several parts, keywords in which every part is found in a part of its
     * own, in any order. Equal ranks are ordered by fold, then by spelling.
     */
    fun existingMatches(query: String, among: List<String>): List<String> {
        val foldedQuery = foldedKeyword(query)
        if (foldedQuery.isEmpty()) return emptyList()

        class Match(val keyword: String, val folded: String, val rank: Int)

        val seen = HashSet<String>()
        val matches = ArrayList<Match>()
        for (rawKeyword in among) {
            val keyword = Snippet.sanitizedKeyword(rawKeyword)
            val folded = foldedKeyword(keyword)
            if (folded.isEmpty() || !seen.add(folded)) continue
            val rank = existingMatchRank(foldedQuery, folded) ?: continue
            matches.add(Match(keyword, folded, rank))
        }
        matches.sortWith { first, second ->
            when {
                first.rank != second.rank -> first.rank.compareTo(second.rank)
                first.folded != second.folded -> FoundationText.compareScalars(first.folded, second.folded)
                else -> FoundationText.compare(first.keyword, second.keyword)
            }
        }
        return matches.map { it.keyword }
    }

    /**
     * `tabCompletion(query:among:)`: the part a shell-style Tab can add without choosing
     * between keywords, or `null` when there is none.
     *
     * Only keywords that the typed text is a prefix of count. Each offers its continuation
     * up to and including the next `.`, `-` or whitespace; the result is what all of them
     * share, spelled as the first one spells it and appended to the text as typed. So a
     * later Tab advances one part at a time, and Tab never picks one keyword over another.
     */
    fun tabCompletion(query: String, among: List<String>): String? {
        val typed = Snippet.sanitizedKeyword(query)
        val foldedQuery = foldedKeyword(typed)
        if (foldedQuery.isEmpty()) return null

        val seen = HashSet<String>()
        val targets = ArrayList<String>()
        for (rawKeyword in among) {
            val candidate = Snippet.sanitizedKeyword(rawKeyword)
            val foldedCandidate = foldedKeyword(candidate)
            if (foldedCandidate.isEmpty() || !seen.add(foldedCandidate)) continue
            val suffixStart = suffixStart(candidate, foldedQuery) ?: continue
            if (suffixStart >= candidate.length) continue

            var end = candidate.length
            var index = suffixStart
            while (index < candidate.length) {
                val next = FoundationText.nextCharacterBoundary(candidate, index)
                if (isCompletionBoundary(candidate.substring(index, next))) {
                    end = next
                    break
                }
                index = next
            }
            targets.add(typed + candidate.substring(suffixStart, end))
        }
        val first = targets.firstOrNull() ?: return null

        var common = SwiftStrings.characters(foldedKeyword(first))
        for (index in 1 until targets.size) {
            val other = SwiftStrings.characters(foldedKeyword(targets[index]))
            var shared = 0
            while (shared < common.size && shared < other.size && common[shared] == other[shared]) shared += 1
            common = common.subList(0, shared)
        }
        if (common.size <= FoundationText.characterCount(foldedQuery)) return null
        val result = prefixFoldingTo(first, common.joinToString("")) ?: return null
        return if (foldedKeyword(result) == foldedQuery) null else result
    }

    /**
     * `candidates(name:contentFirstLine:)`: best first, without repeats, already folded
     * the way [KeywordRelation] needs. Nothing is checked against the library; the caller
     * knows what is enabled.
     *
     * From the name: its first word, and the initials of its first five words when it has
     * more than one. From the content: its first word that is not `http`, `https` or
     * `www`. A word of more than six characters is offered as its first four and first
     * three. A word is a run of `a-z0-9` after folding, so every candidate can be typed.
     */
    fun candidates(name: String, contentFirstLine: String): List<String> {
        val candidates = ArrayList<String>()
        val nameWords = words(name)
        nameWords.firstOrNull()?.let { appendAbbreviations(it, candidates) }
        if (nameWords.size > 1) {
            val initials = StringBuilder()
            for (word in nameWords.take(MAXIMUM_INITIALS)) initials.append(word[0])
            append(initials.toString(), candidates)
        }
        words(contentFirstLine).firstOrNull { it !in IGNORED_LEADING_WORDS }?.let { appendAbbreviations(it, candidates) }
        return candidates
    }

    private fun appendAbbreviations(word: String, candidates: MutableList<String>) {
        if (word.length <= WHOLE_WORD_MAX_LENGTH) {
            append(word, candidates)
            return
        }
        for (length in ABBREVIATION_LENGTHS) append(word.substring(0, length), candidates)
    }

    private fun append(candidate: String, candidates: MutableList<String>) {
        if (candidate.length >= MINIMUM_LENGTH && candidate !in candidates) candidates.add(candidate)
    }

    // Folding first turns "Café Order" into "cafe". The fold already lowercases, and the
    // only characters Swift's `lowercased()` would still turn into ASCII are handled here.
    private fun words(phrase: String): List<String> =
        SwiftStrings.split(SnippetTagging.filterKey(phrase)) { character ->
            character.length != 1 || !isWordUnit(character[0])
        }.map { it.lowercase(java.util.Locale.ROOT) }

    private fun isWordUnit(unit: Char): Boolean =
        unit in 'a'..'z' || unit in 'A'..'Z' || unit in '0'..'9' || unit == '\u212A' // Kelvin sign lowercases to k

    private fun foldedKeyword(keyword: String): String = KeywordRelation.folded(keyword)

    /**
     * The index in [candidate] just past the `Character`s that fold to [foldedQuery], or
     * `null` when it does not start with them. Walks `Character`s of the source because
     * folding preserves neither length nor boundaries.
     */
    private fun suffixStart(candidate: String, foldedQuery: String): Int? {
        var end = 0
        while (end < candidate.length) {
            end = FoundationText.nextCharacterBoundary(candidate, end)
            val foldedPrefix = foldedKeyword(candidate.substring(0, end))
            if (foldedPrefix == foldedQuery) return end
            if (!SwiftStrings.hasPrefix(foldedQuery, foldedPrefix)) return null
        }
        return null
    }

    private fun isCompletionBoundary(character: String): Boolean =
        character == "." || character == "-" || SwiftStrings.isWhitespaceCharacter(character)

    private fun prefixFoldingTo(source: String, foldedPrefix: String): String? {
        var end = 0
        while (end < source.length) {
            end = FoundationText.nextCharacterBoundary(source, end)
            val candidate = source.substring(0, end)
            val foldedCandidate = foldedKeyword(candidate)
            if (foldedCandidate == foldedPrefix) return candidate
            if (!SwiftStrings.hasPrefix(foldedPrefix, foldedCandidate)) return null
        }
        return if (foldedKeyword(source) == foldedPrefix) source else null
    }

    /** Smaller is better; `null` is no match. */
    private fun existingMatchRank(query: String, candidate: String): Int? {
        if (candidate == query) return 0
        if (SwiftStrings.hasPrefix(candidate, query)) return 1

        val queryParts = keywordParts(query)
        val candidateParts = keywordParts(candidate)
        if (candidateParts.any { it == query }) return 2
        if (candidateParts.any { SwiftStrings.hasPrefix(it, query) }) return 3
        if (SwiftStrings.containsNormalized(candidate, query)) return 4
        if (queryParts.size > 1 && unorderedPartsMatch(queryParts, candidateParts)) return 5
        return null
    }

    private fun keywordParts(keyword: String): List<String> = SwiftStrings.split(keyword) { it == "." }

    /**
     * Query parts are placed longest first and each consumes the candidate part it lands
     * in, so `doc.doc` does not match a keyword with one `doc`, and a short part cannot
     * take the only part a longer one fits.
     */
    private fun unorderedPartsMatch(queryParts: List<String>, candidateParts: List<String>): Boolean {
        if (candidateParts.size < queryParts.size) return false
        val available = candidateParts.toMutableList()
        for (queryPart in queryParts.sortedByDescending { FoundationText.characterCount(it) }) {
            val index = available.indexOfFirst { SwiftStrings.containsNormalized(it, queryPart) }
            if (index < 0) return false
            available.removeAt(index)
        }
        return true
    }
}
