package com.khm.snippets.core.placeholders

/**
 * The syntax of an ICU date pattern (UTS 35), read the way ICU's `SimpleDateFormat` reads
 * it while formatting, which is what Foundation's `DateFormatter.dateFormat` does.
 *
 * - A run of one ASCII letter is a field; the run's length selects its form.
 * - `'…'` quotes literal text, `''` is an apostrophe inside or outside quotes, and an
 *   unterminated quote runs to the end.
 * - Every other character is literal.
 * - Formatting stops at the first letter that is not a field letter. What was produced up
 *   to there is the result, plus one quirk of ICU's loop: the character that follows the
 *   invalid run is still emitted when it is literal. So `yyyy-MM-ddTHH` gives the date
 *   (`T` is not a field), `yyyyp-MM` gives the year and `-`, and `foo` gives nothing.
 *   The letter `l` is deprecated and silently skipped.
 * - Six or more `B` in a row crash Foundation (macOS 27.2). Here they are an ordinary
 *   field, and [formattablePrefix] writes five.
 *
 * This is not `java.text.SimpleDateFormat` or `java.time` syntax: those give `Y`, `u`,
 * `e`, `c`, `a`, `B`, `L`, `Q` and others different meanings, or none, and throw on
 * letters they do not know.
 */
object IcuDatePattern {

    /** The letters ICU formats. Any other ASCII letter except `l` ends the output. */
    const val FIELD_LETTERS: String = "GyMdkHmsSEDFwWahKzYeugAZvcLQqVUOXxrbB"

    sealed class Item {
        /** [count] repetitions of the field letter [letter]. */
        data class Field(val letter: Char, val count: Int) : Item()

        data class Literal(val text: String) : Item()
    }

    /**
     * @property items what ICU formats, in order.
     * @property isComplete false when an invalid letter cut the pattern short.
     */
    class Parsed internal constructor(val items: List<Item>, val isComplete: Boolean)

    fun parse(pattern: String): Parsed {
        val items = ArrayList<Item>()
        val literal = StringBuilder()
        var inQuote = false
        var runLetter = '\u0000'
        var runLength = 0
        var failed = false

        fun flushLiteral() {
            if (literal.isNotEmpty()) {
                items.add(Item.Literal(literal.toString()))
                literal.setLength(0)
            }
        }

        // False when the run is not a field: ICU reports an error and formats no further.
        fun flushRun(): Boolean {
            val letter = runLetter
            val count = runLength
            runLength = 0
            if (letter == 'l') return true
            if (FIELD_LETTERS.indexOf(letter) < 0) return false
            flushLiteral()
            items.add(Item.Field(letter, count))
            return true
        }

        var index = 0
        while (index < pattern.length && !failed) {
            val unit = pattern[index]
            if (unit != runLetter && runLength > 0) failed = !flushRun()
            if (unit == '\'') {
                if (index + 1 < pattern.length && pattern[index + 1] == '\'') {
                    literal.append('\'')
                    index += 1
                } else {
                    inQuote = !inQuote
                }
            } else if (!inQuote && isAsciiLetter(unit)) {
                runLetter = unit
                runLength += 1
            } else {
                literal.append(unit)
            }
            index += 1
        }
        if (!failed && runLength > 0) failed = !flushRun()
        flushLiteral()
        return Parsed(items, isComplete = !failed)
    }

    /**
     * A pattern that every ICU accepts and that formats to what Foundation produces for
     * [pattern]: its fields up to the first invalid letter, with all literal text quoted.
     * An `android.icu.text.SimpleDateFormat` built from the result behaves like
     * Foundation's formatter built from the original, where ICU4J would throw on the
     * original.
     */
    fun formattablePrefix(pattern: String): String {
        val out = StringBuilder(pattern.length + 8)
        for (item in parse(pattern).items) {
            when (item) {
                // Six or more `B` crash Foundation's formatter outright. No ICU is handed
                // that: the widest form that exists is five.
                is Item.Field -> repeat(if (item.letter == 'B') minOf(item.count, MAXIMUM_DAY_PERIOD_COUNT) else item.count) { out.append(item.letter) }
                is Item.Literal -> appendQuoted(item.text, out)
            }
        }
        return out.toString()
    }

    // One pair of quotes around the text, apostrophes doubled. Text that is nothing but
    // apostrophes is written without the pair: four apostrophes read as two doubled ones.
    private fun appendQuoted(text: String, out: StringBuilder) {
        val onlyApostrophes = text.all { it == APOSTROPHE }
        if (!onlyApostrophes) out.append(APOSTROPHE)
        for (unit in text) {
            if (unit == APOSTROPHE) out.append(APOSTROPHE).append(APOSTROPHE) else out.append(unit)
        }
        if (!onlyApostrophes) out.append(APOSTROPHE)
    }

    private const val APOSTROPHE = '\''
    private const val MAXIMUM_DAY_PERIOD_COUNT = 5

    private fun isAsciiLetter(unit: Char): Boolean = unit in 'a'..'z' || unit in 'A'..'Z'
}
