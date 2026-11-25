package com.khm.snippets.android.ui.model

/**
 * Pure helpers for values shown or typed in groups: recovery keys and codes, account keys,
 * fingerprints. The stored value is always the raw symbols; separators exist on screen only.
 */
object CodeFormat {
    const val DEFAULT_GROUP_SIZE = 4
    const val SEPARATOR = '-'

    /**
     * Raw symbols of typed or pasted input: upper-cased, with spaces, line breaks and hyphens
     * removed. Characters outside the alphabet are kept so validation can name them.
     */
    fun sanitize(input: String): String = buildString(input.length) {
        for (char in input) {
            if (!isSeparator(char)) append(char.uppercaseChar())
        }
    }

    /**
     * [sanitize] for a field edit: also returns where the caret lands, which is after the same
     * symbol it was after before sanitising. [caret] is an index into [input].
     */
    fun sanitizeEdit(input: String, caret: Int): Pair<String, Int> {
        val bounded = caret.coerceIn(0, input.length)
        var symbolsBeforeCaret = 0
        for (index in 0 until bounded) {
            if (!isSeparator(input[index])) symbolsBeforeCaret++
        }
        return sanitize(input) to symbolsBeforeCaret
    }

    /** The raw symbols split into groups of [groupSize]; the last group may be shorter. */
    fun groups(raw: String, groupSize: Int = DEFAULT_GROUP_SIZE): List<String> {
        require(groupSize > 0) { "groupSize must be positive" }
        return raw.chunked(groupSize)
    }

    /** `7K2M-9QXD-4F`: a separator after every complete group that has a successor. */
    fun grouped(raw: String, groupSize: Int = DEFAULT_GROUP_SIZE): String =
        groups(raw, groupSize).joinToString(SEPARATOR.toString())

    /** Index in the grouped text of the raw caret position [rawOffset]. */
    fun rawToGroupedOffset(rawOffset: Int, rawLength: Int, groupSize: Int = DEFAULT_GROUP_SIZE): Int {
        val offset = rawOffset.coerceIn(0, rawLength)
        if (offset == 0) return 0
        // A caret at the end of a complete group sits before the separator, not after it.
        return offset + (offset - 1) / groupSize
    }

    /** Raw caret position of the index [groupedOffset] in the grouped text. */
    fun groupedToRawOffset(groupedOffset: Int, rawLength: Int, groupSize: Int = DEFAULT_GROUP_SIZE): Int {
        val groupedLength = rawToGroupedOffset(rawLength, rawLength, groupSize)
        val offset = groupedOffset.coerceIn(0, groupedLength)
        val raw = offset - offset / (groupSize + 1)
        return raw.coerceIn(0, rawLength)
    }

    /** `7 K 2 M, 9 Q X D`: what a screen reader speaks so the value is spelled, not read. */
    fun spelled(raw: String, groupSize: Int = DEFAULT_GROUP_SIZE): String =
        groups(raw, groupSize).joinToString(", ") { group -> group.toList().joinToString(" ") }

    /** The last [count] characters, for `SSH public key, ending in …`. */
    fun ending(value: String, count: Int = 6): String = value.trim().takeLast(count)

    private fun isSeparator(char: Char): Boolean = char == SEPARATOR || char.isWhitespace()
}

/** Formatting of the secure-copy countdown (components.md §10). */
object CountdownFormat {
    /** `m:ss` of the time left, rounded up to the next whole second; never negative. */
    fun remaining(remainingMillis: Long): String {
        val seconds = if (remainingMillis <= 0) 0 else (remainingMillis + 999) / 1000
        return "%d:%02d".format(java.util.Locale.ROOT, seconds / 60, seconds % 60)
    }

    /** Fraction of the lifetime that is left, from 1 down to 0. */
    fun fraction(remainingMillis: Long, totalMillis: Long): Float {
        if (totalMillis <= 0) return 0f
        return (remainingMillis.toFloat() / totalMillis.toFloat()).coerceIn(0f, 1f)
    }
}
