package com.khm.snippets.core.text

/**
 * `String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: en_US_POSIX)`.
 *
 * Foundation (CoreFoundation's `CFStringFold`) does not fold scalar by scalar. It walks
 * the string in clusters: one leading scalar plus the "non-base" scalars that follow it.
 * The leading scalar is replaced by its own fold (`base`); what happens to the followers
 * depends on that fold:
 *
 * 1. U+0000 is copied and never leads a cluster.
 * 2. If the last scalar of the leader's fold is below U+0510 (Latin, Greek, Cyrillic),
 *    every follower is dropped. This is the diacritic-insensitive part.
 * 3. Otherwise the followers are kept. If the leader's fold is the leader itself, a
 *    first follower at or below U+050F is dropped all the same.
 * 4. Each kept follower is canonically decomposed (`marks`).
 * 5. A cluster holds at most 64 scalars. A follower that does not fit, or a decomposing
 *    one that finds fewer free slots than it asks for (`markSpace`), ends the cluster
 *    and leads the next one.
 * 6. The kept followers, together with the scalar before them, are stably sorted by
 *    combining class (`priority`).
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

    internal class Tables(
        /** Leader → its own fold. */
        val base: ScalarMap,
        val nonBase: RangeTable,
        val priority: RangeTable,
        /** Kept follower → what replaces it. */
        val marks: ScalarMap,
        /** Free buffer slots each entry of [marks] needs, by entry index. */
        val markSpace: IntArray,
    )

    private val tables: Tables by lazy(LazyThreadSafetyMode.PUBLICATION) {
        parse(FoundationTables.open("foundation-fold.txt"))
    }

    fun warmUp() {
        tables
    }

    /** Fails with the table's name and line for anything [fold] could not use safely. */
    internal fun parse(reader: TableReader): Tables {
        val base = ScalarMap.Builder(2048)
        val nonBase = RangeTable.Builder(512)
        val priority = RangeTable.Builder(512)
        val marks = ScalarMap.Builder(64)
        val markSpace = IntList(64)
        var section = 0
        while (true) {
            val first = reader.nextLine()
            if (first < 0) break
            if (first == '['.code) {
                section = when (val heading = reader.restOfLine()) {
                    "[base]" -> SECTION_BASE
                    "[nonbase]" -> SECTION_NON_BASE
                    "[priority]" -> SECTION_PRIORITY
                    "[markdecomposition]" -> SECTION_MARKS
                    else -> reader.fail("unexpected section $heading")
                }
                continue
            }
            when (section) {
                SECTION_BASE -> {
                    base.begin(reader.hex())
                    while (reader.accept(' ')) base.append(reader.hex())
                    // fold() reads the last scalar of every entry and copies it into the cluster buffer.
                    if (base.currentLength == 0) reader.fail("a scalar cannot fold to nothing")
                    if (base.currentLength > MAXIMUM_BASE_LENGTH) reader.fail("a fold longer than $MAXIMUM_BASE_LENGTH scalars")
                }
                SECTION_NON_BASE -> nonBase.add(reader.range(), reader.rangeEnd, 1)
                SECTION_PRIORITY -> {
                    val start = reader.range()
                    reader.expect(' ')
                    priority.add(start, reader.rangeEnd, reader.decimal())
                }
                SECTION_MARKS -> {
                    marks.begin(reader.hex())
                    reader.expect(' ')
                    val space = reader.decimal()
                    while (reader.accept(' ')) marks.append(reader.hex())
                    if (marks.currentLength == 0 || space < marks.currentLength || space > CLUSTER_BUFFER_LENGTH) {
                        reader.fail("a mark's replacement must be non-empty and fit the space it asks for")
                    }
                    markSpace.add(space)
                }
                else -> reader.fail("data before the first section")
            }
            reader.endOfLine()
        }
        val tables = Tables(base.build(), nonBase.build(), priority.build(), marks.build(), markSpace.toArray())
        check(tables.base.size > 0 && tables.marks.size > 0) { "the fold tables are empty" }
        // fold() and isNonBase() take shortcuts for scalars below U+0300.
        for (scalar in 0 until FIRST_POSSIBLE_NON_BASE) {
            check(tables.nonBase.valueAt(scalar) == 0) { "unexpected non-base scalar below U+0300" }
        }
        return tables
    }

    private const val MAXIMUM_BASE_LENGTH = 8
    private const val SECTION_BASE = 1
    private const val SECTION_NON_BASE = 2
    private const val SECTION_PRIORITY = 3
    private const val SECTION_MARKS = 4

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

            val mapped = tables.base.indexOf(lead)
            var filled = 0
            if (mapped < 0) {
                buffer[filled++] = lead
            } else {
                for (position in tables.base.start(mapped) until tables.base.end(mapped)) {
                    buffer[filled++] = tables.base.scalarAt(position)
                }
            }

            if (buffer[filled - 1] < STRIP_LIMIT) {
                index = skipNonBase(tables, text, index)
                appendScalars(out, buffer, filled)
                continue
            }

            if (mapped < 0) {
                val first = nonBaseAt(tables, text, index)
                if (first < 0) {
                    out.appendCodePoint(lead)
                    continue
                }
                index += Character.charCount(first)
                if (first > LOW_MARK_LIMIT) filled = appendMark(tables, first, tables.marks.indexOf(first), buffer, filled)
            }

            while (filled < CLUSTER_BUFFER_LENGTH) {
                val mark = nonBaseAt(tables, text, index)
                if (mark < 0) break
                val decomposition = tables.marks.indexOf(mark)
                if (decomposition >= 0 && tables.markSpace[decomposition] > CLUSTER_BUFFER_LENGTH - filled) break
                filled = appendMark(tables, mark, decomposition, buffer, filled)
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

    /** [decomposition] is the mark's entry in `marks`, or negative when it is kept as it is. */
    private fun appendMark(tables: Tables, mark: Int, decomposition: Int, buffer: IntArray, filled: Int): Int {
        var count = filled
        if (decomposition < 0) {
            buffer[count++] = mark
        } else {
            for (position in tables.marks.start(decomposition) until tables.marks.end(decomposition)) {
                buffer[count++] = tables.marks.scalarAt(position)
            }
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
