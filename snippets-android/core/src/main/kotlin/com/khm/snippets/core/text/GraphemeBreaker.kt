package com.khm.snippets.core.text

/**
 * Extended grapheme clusters as the Swift standard library draws them: what Swift calls
 * a `Character`, and therefore what `count`, `prefix`, `removeFirst` and `hasPrefix` mean
 * in the Swift sources.
 *
 * This is Swift's forward segmenter (`_GraphemeBreakingState`), replayed over classes
 * measured from Swift by `tools/foundation-tables`; that tool compared the two on tens
 * of millions of strings. `java.text.BreakIterator` is not used: its rules follow the
 * runtime's ICU, which on Android API 28 predates emoji ZWJ handling as Swift does it
 * and the Indic conjunct rule entirely.
 *
 * A Kotlin string can hold an unpaired surrogate, which Swift cannot represent. It is
 * treated as a control character: a cluster of its own.
 */
internal object GraphemeBreaker {

    private const val CLASS_MASK = 0x0F
    private const val OTHER = 0
    private const val CARRIAGE_RETURN = 1
    private const val LINE_FEED = 2
    private const val CONTROL = 3
    private const val EXTEND = 4
    private const val ZERO_WIDTH_JOINER = 5
    private const val REGIONAL_INDICATOR = 6
    private const val PREPEND = 7
    private const val SPACING_MARK = 8
    private const val HANGUL_L = 9
    private const val HANGUL_V = 10
    private const val HANGUL_T = 11
    private const val HANGUL_LV = 12
    private const val HANGUL_LVT = 13
    private const val EXTENDED_PICTOGRAPHIC = 14

    private const val CONSONANT_FLAG = 0x10
    private const val LINKER_FLAG = 0x20
    private const val CONJUNCT_EXTEND_FLAG = 0x40

    private val table: RangeTable by lazy(LazyThreadSafetyMode.PUBLICATION) { load() }

    fun warmUp() {
        table
    }

    private fun load(): RangeTable {
        val reader = FoundationTables.open("grapheme-break.txt")
        val builder = RangeTable.Builder(2048)
        while (reader.nextLine() >= 0) {
            val start = reader.range()
            reader.expect(' ')
            builder.add(start, reader.rangeEnd, reader.decimal())
            reader.endOfLine()
        }
        val loaded = builder.build()
        check(loaded.valueAt(0x0D) == CARRIAGE_RETURN && loaded.valueAt(0x1F600) == EXTENDED_PICTOGRAPHIC) {
            "the grapheme table is damaged"
        }
        // clusterEnd() takes a shortcut for two scalars below U+0300: nothing there
        // may attach to its neighbour.
        for (scalar in 0 until 0x0300) {
            val value = loaded.valueAt(scalar)
            check(
                value == OTHER || value == CARRIAGE_RETURN || value == LINE_FEED ||
                    value == CONTROL || value == EXTENDED_PICTOGRAPHIC,
            ) { "unexpected grapheme class below U+0300" }
        }
        return loaded
    }

    private fun valueAt(table: RangeTable, scalar: Int): Int =
        if (scalar in 0xD800..0xDFFF) CONTROL else table.valueAt(scalar)

    /**
     * The index just past the cluster that starts at [start]. [start] must be the start
     * of a cluster (0, or a value this function returned) and less than the length.
     */
    fun clusterEnd(text: CharSequence, start: Int): Int {
        val table = table
        val length = text.length
        var left = Character.codePointAt(text, start)
        var index = start + Character.charCount(left)
        if (index >= length) return index

        // Two scalars below U+0300 always break, except CR LF.
        val next = text[index].code
        if (left < 0x0300 && next < 0x0300) {
            return if (left == 0x0D && next == 0x0A) index + 1 else index
        }

        var leftValue = valueAt(table, left)
        var inEmojiSequence = false
        var inConjunct = false
        var sawLinker = false
        var oddRegionalIndicators = false

        while (index < length) {
            val right = Character.codePointAt(text, index)
            val rightValue = valueAt(table, right)
            val x = leftValue and CLASS_MASK
            val y = rightValue and CLASS_MASK

            var enterEmojiSequence = false
            var enterConjunct = false
            val breaks: Boolean = when {
                x == CARRIAGE_RETURN && y == LINE_FEED -> false
                x == CARRIAGE_RETURN || x == LINE_FEED || x == CONTROL -> true
                y == CARRIAGE_RETURN || y == LINE_FEED || y == CONTROL -> true
                x == HANGUL_L && (y == HANGUL_L || y == HANGUL_V || y == HANGUL_LV || y == HANGUL_LVT) -> false
                (x == HANGUL_LV || x == HANGUL_V) && (y == HANGUL_V || y == HANGUL_T) -> false
                (x == HANGUL_LVT || x == HANGUL_T) && y == HANGUL_T -> false
                y == EXTEND || y == ZERO_WIDTH_JOINER -> {
                    // An extender with class 0 ends a conjunct without ending the cluster.
                    val conjunctBroken = (inConjunct || leftValue and CONSONANT_FLAG != 0) &&
                        y == EXTEND && rightValue and CONJUNCT_EXTEND_FLAG == 0
                    if (!conjunctBroken) {
                        if (inConjunct || leftValue and CONSONANT_FLAG != 0) {
                            enterConjunct = true
                            if (rightValue and LINKER_FLAG != 0) sawLinker = true
                        }
                        if (x == EXTENDED_PICTOGRAPHIC || (inEmojiSequence && x == EXTEND)) {
                            enterEmojiSequence = true
                        }
                    }
                    false
                }
                y == SPACING_MARK -> false
                x == PREPEND -> false
                x == ZERO_WIDTH_JOINER && y == EXTENDED_PICTOGRAPHIC -> !inEmojiSequence
                x == REGIONAL_INDICATOR && y == REGIONAL_INDICATOR -> {
                    val result = oddRegionalIndicators
                    oddRegionalIndicators = !oddRegionalIndicators
                    result
                }
                inConjunct && sawLinker && rightValue and CONSONANT_FLAG != 0 -> {
                    sawLinker = false
                    false
                }
                else -> true
            }
            if (breaks) return index
            inEmojiSequence = enterEmojiSequence
            inConjunct = enterConjunct
            left = right
            leftValue = rightValue
            index += Character.charCount(right)
        }
        return index
    }
}
