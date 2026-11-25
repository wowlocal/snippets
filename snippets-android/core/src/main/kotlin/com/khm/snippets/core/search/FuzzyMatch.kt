package com.khm.snippets.core.search

import com.khm.snippets.core.text.FoundationText

/**
 * Subsequence matching over case- and diacritic-folded `Character`s, with an optional
 * score and the ranges to highlight (`FuzzyMatch.swift`).
 *
 * The score of an alignment is the sum over its matched characters of [SCORE_CHARACTER],
 * plus [SCORE_WORD_START] where a word starts, plus [SCORE_TARGET_START] when the first
 * query character sits on the first target character, plus [SCORE_STREAK] times the number
 * of immediately preceding adjacent matches. [score] returns the best alignment.
 *
 * Folding is [FoundationText.fold], the same for every user. The Swift sources fold with
 * the user's locale, which differs only for Turkish, Azeri and Lithuanian text.
 */
object FuzzyMatch {

    const val SCORE_CHARACTER: Int = 1
    const val SCORE_WORD_START: Int = 3
    const val SCORE_TARGET_START: Int = 5
    const val SCORE_STREAK: Int = 2

    /**
     * A matched stretch of the target in UTF-16 units, which are the indices of a Kotlin
     * `String`: `target.substring(start, end)` is the highlighted text. One range covers
     * one whole `Character` of the target.
     */
    data class MatchRange(val start: Int, val length: Int) {
        val end: Int get() = start + length
    }

    /**
     * @property matchedRanges one range per query character, in order. A target character
     * whose fold is several characters (`ß` folds to `ss`) can be listed more than once;
     * [highlightRanges] is the form to draw.
     */
    data class Result(val score: Int, val matched: Boolean, val matchedRanges: List<MatchRange>) {

        /** [matchedRanges] without repeats and with touching ranges joined, in ascending order. */
        val highlightRanges: List<MatchRange>
            get() {
                val merged = ArrayList<MatchRange>(matchedRanges.size)
                for (range in matchedRanges) {
                    val last = merged.lastOrNull()
                    when {
                        last == null || range.start > last.end -> merged.add(range)
                        range.end > last.end -> merged[merged.size - 1] = MatchRange(last.start, range.end - last.start)
                    }
                }
                return merged
            }

        companion object {
            val NO_MATCH = Result(0, matched = false, matchedRanges = emptyList())
        }
    }

    /** A folded query. Immutable; build once per keystroke. */
    class PreparedQuery(text: String) {
        internal val characters: Array<String> = normalize(text).characters

        val isEmpty: Boolean get() = characters.isEmpty()

        /** Whether this query starts with all of [previous], so its matches are among that query's matches. */
        fun extends(previous: PreparedQuery): Boolean {
            if (previous.characters.size > characters.size) return false
            for (index in previous.characters.indices) if (characters[index] != previous.characters[index]) return false
            return true
        }

        override fun equals(other: Any?): Boolean = other is PreparedQuery && characters.contentEquals(other.characters)
        override fun hashCode(): Int = characters.contentHashCode()
    }

    /** A folded target with the tables [score] needs. Immutable. */
    class PreparedTarget(text: String) {
        internal val characters: Array<String>
        internal val rangeStarts: IntArray
        internal val rangeLengths: IntArray
        internal val wordStarts: BooleanArray
        internal val positions: Map<String, IntArray>

        init {
            val normalized = normalize(text)
            characters = normalized.characters
            rangeStarts = normalized.rangeStarts
            rangeLengths = normalized.rangeLengths
            wordStarts = normalized.wordStarts
            val lists = HashMap<String, ArrayList<Int>>()
            for (index in characters.indices) lists.getOrPut(characters[index]) { ArrayList() }.add(index)
            positions = lists.mapValues { it.value.toIntArray() }
        }
    }

    /**
     * Scratch buffers for [score]. Give each search operation its own and reuse it across
     * that operation's targets; it must not be shared between threads.
     */
    class Workspace {
        internal var previous = States()
        internal var next = States()
        internal var traceTargets = IntArray(64)
        internal var traceParents = IntArray(64)
        internal var traceCount = 0

        internal fun appendTrace(targetIndex: Int, parent: Int): Int {
            if (traceCount == traceTargets.size) {
                traceTargets = traceTargets.copyOf(traceCount * 2)
                traceParents = traceParents.copyOf(traceCount * 2)
            }
            traceTargets[traceCount] = targetIndex
            traceParents[traceCount] = parent
            return traceCount++
        }
    }

    /** `State` in the Swift sources, as parallel arrays. */
    internal class States {
        var targetIndex = IntArray(32)
        var consecutive = IntArray(32)
        var score = IntArray(32)
        var start = IntArray(32)
        var trace = IntArray(32)
        var count = 0

        fun add(targetIndex: Int, consecutive: Int, score: Int, start: Int, trace: Int) {
            if (count == this.targetIndex.size) {
                val capacity = count * 2
                this.targetIndex = this.targetIndex.copyOf(capacity)
                this.consecutive = this.consecutive.copyOf(capacity)
                this.score = this.score.copyOf(capacity)
                this.start = this.start.copyOf(capacity)
                this.trace = this.trace.copyOf(capacity)
            }
            this.targetIndex[count] = targetIndex
            this.consecutive[count] = consecutive
            this.score[count] = score
            this.start[count] = start
            this.trace[count] = trace
            count += 1
        }
    }

    /** `score(query:target:)`. */
    fun score(query: String, target: String): Result = score(PreparedQuery(query), PreparedTarget(target))

    /**
     * `score(query:target:includingRanges:workspace:)`. An empty query matches everything
     * with score 0. Without [includingRanges] the result carries no ranges and no trace is
     * recorded.
     *
     * Ties are broken by the higher score, then the earlier last match, then the earlier
     * first match, then the longer final streak. Alignments that tie on all four may
     * highlight different middle characters; which one is returned is not part of the contract.
     */
    fun score(
        query: PreparedQuery,
        target: PreparedTarget,
        includingRanges: Boolean = true,
        workspace: Workspace = Workspace(),
    ): Result {
        val pattern = query.characters
        if (pattern.isEmpty()) return Result(0, matched = true, matchedRanges = emptyList())
        if (!matches(query, target)) return Result.NO_MATCH

        var previous = workspace.previous.also { it.count = 0 }
        var next = workspace.next.also { it.count = 0 }
        workspace.traceCount = 0
        val targetCount = target.characters.size

        val firstPositions = target.positions.getValue(pattern[0])
        val lastPossibleFirst = targetCount - pattern.size
        for (index in firstPositions) {
            if (index > lastPossibleFirst) continue
            val score = SCORE_CHARACTER + (if (target.wordStarts[index]) SCORE_WORD_START else 0) +
                (if (index == 0) SCORE_TARGET_START else 0)
            val trace = if (includingRanges) workspace.appendTrace(index, -1) else -1
            previous.add(index, 0, score, target.rangeStarts[index], trace)
        }

        for (queryIndex in 1 until pattern.size) {
            next.count = 0
            var prefixCursor = 0
            var bestGap = -1
            val lastPossible = targetCount - (pattern.size - queryIndex)
            for (index in target.positions.getValue(pattern[queryIndex])) {
                if (index > lastPossible) continue
                // Every non-adjacent predecessor extends with the same bonus: keep the best
                // score, then the earliest start, instead of every path.
                while (prefixCursor < previous.count && previous.targetIndex[prefixCursor] < index - 1) {
                    if (bestGap < 0 || previous.score[prefixCursor] > previous.score[bestGap] ||
                        (previous.score[prefixCursor] == previous.score[bestGap] &&
                            previous.start[prefixCursor] < previous.start[bestGap])
                    ) {
                        bestGap = prefixCursor
                    }
                    prefixCursor += 1
                }
                val base = SCORE_CHARACTER + (if (target.wordStarts[index]) SCORE_WORD_START else 0)
                if (bestGap >= 0) {
                    val trace = if (includingRanges) workspace.appendTrace(index, previous.trace[bestGap]) else -1
                    next.add(index, 0, previous.score[bestGap] + base, previous.start[bestGap], trace)
                }
                // Every adjacent streak is kept: a lower score now can win later, because
                // the streak bonus grows with its length.
                var adjacent = prefixCursor
                while (adjacent < previous.count && previous.targetIndex[adjacent] == index - 1) {
                    val streak = previous.consecutive[adjacent] + 1
                    val trace = if (includingRanges) workspace.appendTrace(index, previous.trace[adjacent]) else -1
                    next.add(index, streak, previous.score[adjacent] + base + streak * SCORE_STREAK, previous.start[adjacent], trace)
                    adjacent += 1
                }
            }
            val swap = previous
            previous = next
            next = swap
            if (previous.count == 0) {
                workspace.previous = previous
                workspace.next = next
                return Result.NO_MATCH
            }
        }
        workspace.previous = previous
        workspace.next = next

        var best = 0
        for (candidate in 1 until previous.count) if (ranks(previous, candidate, best)) best = candidate
        if (!includingRanges) return Result(previous.score[best], matched = true, matchedRanges = emptyList())

        val ranges = arrayOfNulls<MatchRange>(pattern.size)
        var node = previous.trace[best]
        var slot = pattern.size
        while (node >= 0 && slot > 0) {
            val targetIndex = workspace.traceTargets[node]
            ranges[--slot] = MatchRange(target.rangeStarts[targetIndex], target.rangeLengths[targetIndex])
            node = workspace.traceParents[node]
        }
        return Result(previous.score[best], matched = true, matchedRanges = ranges.filterNotNull())
    }

    /**
     * `matches(query:target:)`: whether the query is a subsequence of the target. Agrees
     * with [score]'s `matched`.
     */
    fun matches(query: PreparedQuery, target: PreparedTarget): Boolean {
        if (query.characters.size > target.characters.size) return false
        var earliest = -1
        for (character in query.characters) {
            val positions = target.positions[character] ?: return false
            var found = -1
            for (position in positions) {
                if (position > earliest) {
                    found = position
                    break
                }
            }
            if (found < 0) return false
            earliest = found
        }
        return true
    }

    /**
     * `matches(query:foldedTarget:)`: the subsequence test against text that is already
     * folded, as the library index stores it. An empty query matches.
     */
    fun matches(query: PreparedQuery, foldedTarget: String): Boolean {
        val pattern = query.characters
        if (pattern.isEmpty()) return true
        var next = 0
        if (SwiftStrings.isPlain(foldedTarget)) {
            for (index in foldedTarget.indices) {
                val wanted = pattern[next]
                if (wanted.length == 1 && wanted[0] == foldedTarget[index]) {
                    next += 1
                    if (next == pattern.size) return true
                }
            }
            return false
        }
        var index = 0
        while (index < foldedTarget.length) {
            val end = FoundationText.nextCharacterBoundary(foldedTarget, index)
            if (sameCharacter(foldedTarget, index, end, pattern[next])) {
                next += 1
                if (next == pattern.size) return true
            }
            index = end
        }
        return false
    }

    private fun sameCharacter(text: String, start: Int, end: Int, normalized: String): Boolean {
        if (text.regionMatches(start, normalized, 0, normalized.length) && end - start == normalized.length) return true
        // Different scalars can still be one Character: compare normalized.
        if (end - start == 1 && text[start].code < 0x0300) return false
        return FoundationText.nfc(text.substring(start, end)) == normalized
    }

    // `ranks(_:before:)`.
    private fun ranks(states: States, first: Int, second: Int): Boolean {
        if (states.score[first] != states.score[second]) return states.score[first] > states.score[second]
        if (states.targetIndex[first] != states.targetIndex[second]) return states.targetIndex[first] < states.targetIndex[second]
        if (states.start[first] != states.start[second]) return states.start[first] < states.start[second]
        return states.consecutive[first] > states.consecutive[second]
    }

    private class Normalized(
        val characters: Array<String>,
        val rangeStarts: IntArray,
        val rangeLengths: IntArray,
        val wordStarts: BooleanArray,
    )

    /**
     * One entry per `Character` of the fold of each `Character` of [text]. Every entry
     * carries the range of the source `Character` it came from; only the first entry of a
     * source `Character` can start a word, and only when the source `Character` before it
     * is not a letter.
     */
    private fun normalize(text: String): Normalized {
        if (isAsciiWithoutCrLf(text)) {
            val count = text.length
            val characters = arrayOfNulls<String>(count)
            val wordStarts = BooleanArray(count)
            var previousWasLetter = false
            for (index in 0 until count) {
                val unit = text[index]
                val folded = if (unit in 'A'..'Z') unit + ('a' - 'A') else unit
                characters[index] = ASCII[folded.code]
                wordStarts[index] = !previousWasLetter
                previousWasLetter = folded in 'a'..'z'
            }
            @Suppress("UNCHECKED_CAST")
            return Normalized(characters as Array<String>, IntArray(count) { it }, IntArray(count) { 1 }, wordStarts)
        }

        val characters = ArrayList<String>(text.length)
        val starts = ArrayList<Int>(text.length)
        val lengths = ArrayList<Int>(text.length)
        val wordStarts = ArrayList<Boolean>(text.length)
        var offset = 0
        var previousWasLetter = false
        while (offset < text.length) {
            val end = FoundationText.nextCharacterBoundary(text, offset)
            val original = text.substring(offset, end)
            var first = true
            for (character in FoundationText.characters(FoundationText.fold(original))) {
                characters.add(FoundationText.nfc(character))
                starts.add(offset)
                lengths.add(end - offset)
                wordStarts.add(first && !previousWasLetter)
                first = false
            }
            // Swift's `Character.isLetter` is the Alphabetic property of the first scalar.
            previousWasLetter = Character.isAlphabetic(original.codePointAt(0))
            offset = end
        }
        return Normalized(
            characters.toTypedArray(), starts.toIntArray(), lengths.toIntArray(), wordStarts.toBooleanArray(),
        )
    }

    private fun isAsciiWithoutCrLf(text: String): Boolean {
        for (index in text.indices) {
            val unit = text[index]
            if (unit.code >= 0x80) return false
            if (unit == '\n' && index > 0 && text[index - 1] == '\r') return false
        }
        return true
    }

    private val ASCII: Array<String> = Array(128) { it.toChar().toString() }
}
