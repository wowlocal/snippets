package com.khm.snippets.core.text

/**
 * `String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: en_US_POSIX)`.
 *
 * Foundation (CoreFoundation's `CFStringFold`) does not fold scalar by scalar. It walks
 * the string in clusters: one leading scalar plus the "non-base" scalars that follow it.
 * The leading scalar is replaced by its own fold ([base]); what happens to the followers
 * depends on that fold:
 *
 * 1. U+0000 is copied and never leads a cluster.
 * 2. If the last scalar of the leader's fold is below U+0510 (Latin, Greek, Cyrillic),
 *    every follower is dropped. This is the diacritic-insensitive part.
 * 3. Otherwise the followers are kept. If the leader's fold is the leader itself, a
 *    first follower at or below U+050F is dropped all the same.
 * 4. Each kept follower is canonically decomposed ([markDecomposition]).
 * 5. A cluster holds at most 64 scalars. A follower that does not fit, or a decomposing
 *    one that finds fewer free slots than it asks for ([MarkDecomposition.space]), ends
 *    the cluster and leads the next one.
 * 6. The kept followers, together with the scalar before them, are stably sorted by
 *    combining class ([priority]).
 *
 * The tables are measured from Foundation, and the rule was checked against Foundation
 * on several million strings by the generator (`tools/foundation-tables`). The corpus in
 * the tests is a sample of that check.
 */
internal object FoundationFold {

    private const val STRIP_LIMIT = 0x0510
    private const val LOW_MARK_LIMIT = 0x050F
    private const val CLUSTER_BUFFER_LENGTH = 64
    private const val FIRST_POSSIBLE_NON_BASE = 0x0300

    private class MarkDecomposition(val space: Int, val pieces: IntArray)

    private class Tables(
        val baseKeys: IntArray,
        val baseValues: Array<IntArray>,
        val nonBase: RangeTable,
        val priority: RangeTable,
        val markKeys: IntArray,
        val markValues: Array<MarkDecomposition>,
    )

    private val tables: Tables by lazy(LazyThreadSafetyMode.PUBLICATION) { load() }

    private fun load(): Tables {
        val baseKeys = ArrayList<Int>(2048)
        val baseValues = ArrayList<IntArray>(2048)
        val nonBase = RangeTable.Builder()
        val priority = RangeTable.Builder()
        val markKeys = ArrayList<Int>()
        val markValues = ArrayList<MarkDecomposition>()
        var section = ""
        FoundationTables.forEachLine("foundation-fold.txt") { line ->
            if (line[0] == '[') {
                section = line
                return@forEachLine
            }
            val space = line.indexOf(' ')
            when (section) {
                "[base]" -> {
                    baseKeys.add(FoundationTables.scalar(line.substring(0, space)))
                    baseValues.add(FoundationTables.scalars(line.substring(space + 1)))
                }
                "[nonbase]" -> nonBase.add(line, 1)
                "[priority]" -> priority.add(line.substring(0, space), line.substring(space + 1).toInt())
                "[markdecomposition]" -> {
                    val second = line.indexOf(' ', space + 1)
                    markKeys.add(FoundationTables.scalar(line.substring(0, space)))
                    markValues.add(
                        MarkDecomposition(
                            space = line.substring(space + 1, second).toInt(),
                            pieces = FoundationTables.scalars(line.substring(second + 1)),
                        ),
                    )
                }
                else -> throw IllegalStateException("unexpected section $section")
            }
        }
        check(baseKeys.isNotEmpty() && markKeys.isNotEmpty()) { "the fold tables are empty" }
        val nonBaseTable = nonBase.build()
        // fold() and isNonBase() take shortcuts for scalars below U+0300.
        for (scalar in 0 until FIRST_POSSIBLE_NON_BASE) {
            check(nonBaseTable.valueAt(scalar) == 0) { "unexpected non-base scalar below U+0300" }
        }
        return Tables(
            baseKeys.toIntArray(), baseValues.toTypedArray(), nonBaseTable, priority.build(),
            markKeys.toIntArray(), markValues.toTypedArray(),
        )
    }

    fun fold(text: String): String {
        val length = text.length
        // Plain ASCII has no followers and only A-Z changes.
        var index = 0
        while (index < length && text[index].code < 0x80) index += 1
        if (index == length) return foldAscii(text)

        val tables = tables
        val out = StringBuilder(length)
        val buffer = IntArray(CLUSTER_BUFFER_LENGTH)
        index = 0
        while (index < length) {
            val lead = text.codePointAt(index)
            index += Character.charCount(lead)
            if (lead == 0) {
                out.append('\u0000')
                continue
            }

            val mapped = baseOf(tables, lead)
            var filled = 0
            if (mapped == null) {
                buffer[filled++] = lead
            } else {
                for (scalar in mapped) buffer[filled++] = scalar
            }

            if (buffer[filled - 1] < STRIP_LIMIT) {
                index = skipNonBase(tables, text, index)
                appendScalars(out, buffer, filled)
                continue
            }

            if (mapped == null) {
                val first = nonBaseAt(tables, text, index)
                if (first < 0) {
                    out.appendCodePoint(lead)
                    continue
                }
                index += Character.charCount(first)
                if (first > LOW_MARK_LIMIT) filled = appendMark(tables, first, buffer, filled)
            }

            while (filled < CLUSTER_BUFFER_LENGTH) {
                val mark = nonBaseAt(tables, text, index)
                if (mark < 0) break
                val decomposition = markOf(tables, mark)
                if (decomposition != null && decomposition.space > CLUSTER_BUFFER_LENGTH - filled) break
                filled = appendMark(tables, mark, buffer, filled)
                index += Character.charCount(mark)
            }

            if (filled > 1) sortTrailingRun(tables, buffer, filled)
            appendScalars(out, buffer, filled)
        }
        return out.toString()
    }

    private fun foldAscii(text: String): String {
        var index = 0
        while (index < text.length && text[index] !in 'A'..'Z') index += 1
        if (index == text.length) return text
        val out = CharArray(text.length)
        for (position in text.indices) {
            val character = text[position]
            out[position] = if (character in 'A'..'Z') character + ('a' - 'A') else character
        }
        return String(out)
    }

    private fun baseOf(tables: Tables, scalar: Int): IntArray? {
        val position = tables.baseKeys.binarySearch(scalar)
        return if (position >= 0) tables.baseValues[position] else null
    }

    private fun markOf(tables: Tables, scalar: Int): MarkDecomposition? {
        val position = tables.markKeys.binarySearch(scalar)
        return if (position >= 0) tables.markValues[position] else null
    }

    private fun isNonBase(tables: Tables, scalar: Int): Boolean =
        scalar >= FIRST_POSSIBLE_NON_BASE && tables.nonBase.valueAt(scalar) != 0

    /** The non-base scalar at [index], or -1 when the text ends there or holds something else. */
    private fun nonBaseAt(tables: Tables, text: String, index: Int): Int {
        if (index >= text.length) return -1
        val scalar = text.codePointAt(index)
        return if (isNonBase(tables, scalar)) scalar else -1
    }

    private fun skipNonBase(tables: Tables, text: String, start: Int): Int {
        var index = start
        while (true) {
            val mark = nonBaseAt(tables, text, index)
            if (mark < 0) return index
            index += Character.charCount(mark)
        }
    }

    private fun appendMark(tables: Tables, mark: Int, buffer: IntArray, filled: Int): Int {
        var count = filled
        val decomposition = markOf(tables, mark)
        if (decomposition == null) {
            buffer[count++] = mark
        } else {
            for (piece in decomposition.pieces) buffer[count++] = piece
        }
        return count
    }

    /**
     * Sorts the non-base scalars at the end of the cluster, and the scalar before them,
     * by combining class. Insertion sort: stable, and the run is nearly always short.
     */
    private fun sortTrailingRun(tables: Tables, buffer: IntArray, filled: Int) {
        var start = filled - 1
        while (start > 0 && isNonBase(tables, buffer[start])) start -= 1
        for (position in start + 1 until filled) {
            val scalar = buffer[position]
            val priority = tables.priority.valueAt(scalar)
            var slot = position
            while (slot > start && tables.priority.valueAt(buffer[slot - 1]) > priority) {
                buffer[slot] = buffer[slot - 1]
                slot -= 1
            }
            buffer[slot] = scalar
        }
    }

    private fun appendScalars(out: StringBuilder, buffer: IntArray, filled: Int) {
        for (position in 0 until filled) out.appendCodePoint(buffer[position])
    }
}
