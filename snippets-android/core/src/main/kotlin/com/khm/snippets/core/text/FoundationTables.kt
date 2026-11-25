package com.khm.snippets.core.text

import java.io.BufferedReader
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets

/**
 * Loaders for the tables generated from Foundation and the Swift standard library by
 * `snippets-android/tools/foundation-tables`. The files are plain text so a regenerated
 * table shows up as a readable diff.
 */
internal object FoundationTables {

    private const val FOLDER = "/com/khm/snippets/core/text/"

    /** Calls [line] for every line that is neither empty nor a `#` comment. */
    fun forEachLine(name: String, line: (String) -> Unit) {
        val stream = FoundationTables::class.java.getResourceAsStream(FOLDER + name)
            ?: throw IllegalStateException("missing resource $name")
        BufferedReader(InputStreamReader(stream, StandardCharsets.UTF_8)).use { reader ->
            while (true) {
                val text = reader.readLine() ?: break
                if (text.isNotEmpty() && text[0] != '#') line(text)
            }
        }
    }

    fun scalar(text: String): Int = text.toInt(16)

    /** `0061 0301` → the two scalars; `-` → none. */
    fun scalars(text: String): IntArray {
        if (text == "-") return IntArray(0)
        val parts = text.split(' ')
        return IntArray(parts.size) { scalar(parts[it]) }
    }
}

/** Sorted, non-overlapping scalar ranges, each with a value; scalars outside every range have value 0. */
internal class RangeTable private constructor(
    private val starts: IntArray,
    private val ends: IntArray,
    private val values: IntArray,
) {

    fun valueAt(scalar: Int): Int {
        var low = 0
        var high = starts.size - 1
        while (low <= high) {
            val middle = (low + high) ushr 1
            when {
                scalar < starts[middle] -> high = middle - 1
                scalar > ends[middle] -> low = middle + 1
                else -> return values[middle]
            }
        }
        return 0
    }

    class Builder {
        private var starts = IntArray(256)
        private var ends = IntArray(256)
        private var values = IntArray(256)
        private var count = 0

        /** [range] is `XXXX` or `XXXX-YYYY`; ranges must arrive in ascending order. */
        fun add(range: String, value: Int) {
            val dash = range.indexOf('-')
            val start = FoundationTables.scalar(if (dash < 0) range else range.substring(0, dash))
            val end = if (dash < 0) start else FoundationTables.scalar(range.substring(dash + 1))
            check(start <= end && (count == 0 || start > ends[count - 1])) { "ranges out of order at $range" }
            if (count == starts.size) {
                starts = starts.copyOf(count * 2)
                ends = ends.copyOf(count * 2)
                values = values.copyOf(count * 2)
            }
            starts[count] = start
            ends[count] = end
            values[count] = value
            count += 1
        }

        fun build(): RangeTable = RangeTable(starts.copyOf(count), ends.copyOf(count), values.copyOf(count))
    }
}
