package com.khm.snippets.core.text

/**
 * The tables generated from Foundation and the Swift standard library by
 * `snippets-android/tools/foundation-tables`: the fold, the grapheme classes and the
 * case mappings. They are plain text, so a regenerated table shows up as a readable diff.
 *
 * Each table is parsed on first use, which costs a few milliseconds once. An app that
 * does not want to pay that on its main thread calls [warmUp] from a background thread
 * at start.
 */
object FoundationTables {

    private const val FOLDER = "/com/khm/snippets/core/text/"

    /** Parses every table now. Safe to call from any thread, and more than once. */
    fun warmUp() {
        FoundationFold.warmUp()
        GraphemeBreaker.warmUp()
        SwiftCase.warmUp()
    }

    internal fun open(name: String): TableReader {
        val stream = FoundationTables::class.java.getResourceAsStream(FOLDER + name)
            ?: throw IllegalStateException("missing resource $name")
        return TableReader(name, stream.use { it.readBytes() })
    }
}

/**
 * Reads a table byte by byte, without building a string or a list per line: the tables
 * hold a few thousand lines and are parsed while the app starts.
 */
internal class TableReader(private val name: String, private val bytes: ByteArray) {

    private var position = 0

    /** Moves to the next line that holds data and returns its first byte, or -1 at the end. Skips `#` lines. */
    fun nextLine(): Int {
        while (position < bytes.size) {
            val byte = bytes[position].toInt()
            if (byte == '\n'.code) {
                position += 1
            } else if (byte == '#'.code) {
                skipLine()
            } else {
                return byte
            }
        }
        return -1
    }

    fun peek(): Int = if (position < bytes.size) bytes[position].toInt() else -1

    fun skip() {
        position += 1
    }

    fun skipLine() {
        while (position < bytes.size && bytes[position].toInt() != '\n'.code) position += 1
    }

    /** The rest of the line as text. For the few section headings only. */
    fun restOfLine(): String {
        val start = position
        skipLine()
        return String(bytes, start, position - start, Charsets.US_ASCII)
    }

    /** `true`, and the byte consumed, if the next byte is [byte]. */
    fun accept(byte: Char): Boolean {
        if (peek() != byte.code) return false
        position += 1
        return true
    }

    fun expect(byte: Char) {
        if (!accept(byte)) fail("expected '$byte'")
    }

    /** A scalar value in hex, at least one digit. */
    fun hex(): Int {
        var value = 0
        val start = position
        while (position < bytes.size) {
            val byte = bytes[position].toInt()
            val digit = when {
                byte >= '0'.code && byte <= '9'.code -> byte - '0'.code
                byte >= 'A'.code && byte <= 'F'.code -> byte - 'A'.code + 10
                else -> break
            }
            value = (value shl 4) or digit
            position += 1
        }
        if (position == start || value > 0x10FFFF) fail("expected a scalar value")
        return value
    }

    fun decimal(): Int {
        var value = 0
        val start = position
        while (position < bytes.size) {
            val byte = bytes[position].toInt()
            if (byte < '0'.code || byte > '9'.code) break
            value = value * 10 + (byte - '0'.code)
            position += 1
        }
        if (position == start) fail("expected a number")
        return value
    }

    /** `XXXX` or `XXXX-YYYY`; returns the start, and the end through [rangeEnd]. */
    fun range(): Int {
        val start = hex()
        rangeEnd = if (accept('-')) hex() else start
        if (rangeEnd < start) fail("a range that ends before it starts")
        return start
    }

    var rangeEnd = 0
        private set

    fun endOfLine() {
        if (position < bytes.size && bytes[position].toInt() != '\n'.code) fail("unexpected text at the end of a line")
    }

    fun fail(message: String): Nothing {
        var line = 1
        for (index in 0 until minOf(position, bytes.size)) if (bytes[index].toInt() == '\n'.code) line += 1
        throw IllegalStateException("$name line $line: $message")
    }
}

/** A growing `IntArray`. */
internal class IntList(capacity: Int) {
    private var values = IntArray(capacity)
    var size = 0
        private set

    fun add(value: Int) {
        if (size == values.size) values = values.copyOf(size * 2)
        values[size++] = value
    }

    fun toArray(): IntArray = values.copyOf(size)
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

    class Builder(capacity: Int) {
        private val starts = IntList(capacity)
        private val ends = IntList(capacity)
        private val values = IntList(capacity)
        private var lastEnd = -1

        /** Ranges must arrive in ascending order. */
        fun add(start: Int, end: Int, value: Int) {
            check(start > lastEnd) { "ranges out of order at U+${start.toString(16)}" }
            starts.add(start)
            ends.add(end)
            values.add(value)
            lastEnd = end
        }

        fun build(): RangeTable = RangeTable(starts.toArray(), ends.toArray(), values.toArray())
    }
}

/** Scalar → short run of scalars, as two flat arrays. */
internal class ScalarMap(private val keys: IntArray, private val offsets: IntArray, private val scalars: IntArray) {

    /** The index of [scalar]'s entry, or a negative value. */
    fun indexOf(scalar: Int): Int = keys.binarySearch(scalar)

    fun start(index: Int): Int = offsets[index]

    fun end(index: Int): Int = offsets[index + 1]

    fun scalarAt(position: Int): Int = scalars[position]

    val size: Int get() = keys.size

    class Builder(capacity: Int) {
        private val keys = IntList(capacity)
        private val offsets = IntList(capacity + 1)
        private val scalars = IntList(capacity * 2)
        private var lastKey = -1
        private var currentStart = 0

        /** Starts the entry of [key]; keys must arrive in ascending order. */
        fun begin(key: Int) {
            check(key > lastKey) { "entries out of order at U+${key.toString(16)}" }
            keys.add(key)
            offsets.add(scalars.size)
            currentStart = scalars.size
            lastKey = key
        }

        fun append(scalar: Int) {
            scalars.add(scalar)
        }

        /** How many scalars the entry begun last holds so far. */
        val currentLength: Int get() = scalars.size - currentStart

        fun build(): ScalarMap {
            offsets.add(scalars.size)
            return ScalarMap(keys.toArray(), offsets.toArray(), scalars.toArray())
        }
    }
}
