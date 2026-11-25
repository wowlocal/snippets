package com.khm.snippets.core.json

import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.text.FoundationText

/** The input is not JSON as Foundation's `JSONDecoder` reads it, or a value in it is not what was asked for. */
class FoundationJsonException(message: String) : Exception(message)

/**
 * A JSON value as Foundation's `JSONDecoder` sees it (macOS 27, swift-foundation).
 *
 * Foundation reads in two steps, and both matter for which files count as a library:
 *
 * 1. A scan that only finds the structure. It accepts a trailing comma in arrays and
 *    objects, nests at most 512 deep, and does not look inside strings and numbers: a
 *    number is any run of `0-9 . + - e E` after a digit or `-`, and a string ends at the
 *    first unescaped quote.
 * 2. Strings and numbers are checked when a value is asked for with a type. So a bad
 *    escape, invalid UTF-8, a raw control character or `01` is an error where it is
 *    read, and passes unnoticed as the value of a key nobody reads.
 *
 * [Text.value], [Number.doubleValue] and [Object.members] are step 2 and throw
 * [FoundationJsonException]. Object keys are all decoded together, which is why one bad
 * key spoils its whole object.
 */
sealed class FoundationJsonNode {

    object Null : FoundationJsonNode()

    object True : FoundationJsonNode()

    object False : FoundationJsonNode()

    /** A string, still as the bytes between its quotes. */
    class Text internal constructor(
        private val source: ByteArray,
        private val start: Int,
        private val end: Int,
    ) : FoundationJsonNode() {

        /** The decoded string: valid UTF-8, valid escapes, no raw control characters. */
        @Throws(FoundationJsonException::class)
        fun value(): String = FoundationJson.decodeString(source, start, end)
    }

    /** A number, still as written. */
    class Number internal constructor(
        private val source: ByteArray,
        private val start: Int,
        private val end: Int,
    ) : FoundationJsonNode() {

        /**
         * The number as a `Double`: strict JSON spelling, correctly rounded. A value that
         * overflows to infinity, or a non-zero spelling that rounds to zero, is an error.
         */
        @Throws(FoundationJsonException::class)
        fun doubleValue(): Double = FoundationJson.decodeDouble(source, start, end)
    }

    class Array internal constructor(val elements: List<FoundationJsonNode>) : FoundationJsonNode()

    class Object internal constructor(
        private val keys: List<Text>,
        private val values: List<FoundationJsonNode>,
    ) : FoundationJsonNode() {

        /**
         * The members by decoded key. Of two members with the same key the first wins;
         * "the same" is Swift's string equality, so keys that differ only in normalization
         * form are one key.
         */
        @Throws(FoundationJsonException::class)
        fun members(): Members {
            val byKey = HashMap<String, FoundationJsonNode>(keys.size * 2)
            for (index in keys.indices) {
                val key = FoundationText.nfc(keys[index].value())
                if (!byKey.containsKey(key)) byKey[key] = values[index]
            }
            return Members(byKey)
        }
    }

    class Members internal constructor(private val byKey: Map<String, FoundationJsonNode>) {
        operator fun get(key: String): FoundationJsonNode? = byKey[FoundationText.nfc(key)]
    }
}

object FoundationJson {

    /** Foundation refuses deeper nesting of arrays and objects. */
    const val MAXIMUM_DEPTH: Int = 512

    /**
     * Scans [data]. Like Foundation, accepts UTF-8 with or without a byte order mark and
     * UTF-16 or UTF-32 in either byte order, recognised by the mark or by the zero bytes
     * around the first characters.
     */
    @Throws(FoundationJsonException::class)
    fun parse(data: ByteArray): FoundationJsonNode {
        val scanner = Scanner(utf8Representation(data))
        val value = scanner.scanValue()
        scanner.requireOnlyWhitespaceRemains()
        return value
    }

    private fun fail(message: String): Nothing = throw FoundationJsonException(message)

    // Step 1: structure

    private class Scanner(private val bytes: ByteArray) {
        private var index = 0
        private var depth = 0

        private fun peek(): Int = if (index < bytes.size) bytes[index].toInt() and 0xFF else -1

        /** Skips space, tab, CR and LF and returns the byte after them. The input must not end here. */
        private fun consumeWhitespace(): Int {
            while (index < bytes.size) {
                val byte = bytes[index].toInt() and 0xFF
                if (byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) return byte
                index += 1
            }
            fail("unexpected end of input")
        }

        fun requireOnlyWhitespaceRemains() {
            while (index < bytes.size) {
                val byte = bytes[index].toInt() and 0xFF
                if (byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D) {
                    fail("unexpected content after the top-level value")
                }
                index += 1
            }
        }

        fun scanValue(): FoundationJsonNode = when (val byte = consumeWhitespace()) {
            '"'.code -> scanString()
            '{'.code -> scanObject()
            '['.code -> scanArray()
            't'.code -> {
                expectLiteral("true")
                FoundationJsonNode.True
            }
            'f'.code -> {
                expectLiteral("false")
                FoundationJsonNode.False
            }
            'n'.code -> {
                expectLiteral("null")
                FoundationJsonNode.Null
            }
            else -> if (byte == '-'.code || isDigit(byte)) scanNumber() else fail("unexpected character")
        }

        private fun expectLiteral(literal: String) {
            if (bytes.size - index < literal.length) fail("unexpected end of input")
            for (offset in literal.indices) {
                if (bytes[index + offset].toInt() != literal[offset].code) fail("unexpected character in a literal")
            }
            index += literal.length
        }

        private fun enterContainer() {
            if (depth >= MAXIMUM_DEPTH) fail("too many nested arrays or objects")
            depth += 1
        }

        private fun scanArray(): FoundationJsonNode {
            index += 1
            enterContainer()
            val elements = ArrayList<FoundationJsonNode>()
            if (consumeWhitespace() == ']'.code) {
                index += 1
            } else {
                while (true) {
                    elements.add(scanValue())
                    val next = consumeWhitespace()
                    index += 1
                    if (next == ']'.code) break
                    if (next != ','.code) fail("unexpected character in an array")
                    // Foundation accepts one trailing comma.
                    if (consumeWhitespace() == ']'.code) {
                        index += 1
                        break
                    }
                }
            }
            depth -= 1
            return FoundationJsonNode.Array(elements)
        }

        private fun scanObject(): FoundationJsonNode {
            index += 1
            enterContainer()
            val keys = ArrayList<FoundationJsonNode.Text>()
            val values = ArrayList<FoundationJsonNode>()
            if (consumeWhitespace() == '}'.code) {
                index += 1
            } else {
                while (true) {
                    // After `{` or `,` and whitespace, only a string may follow.
                    if (peek() != '"'.code) fail("unexpected character in an object")
                    keys.add(scanString())
                    if (consumeWhitespace() != ':'.code) fail("unexpected character in an object")
                    index += 1
                    values.add(scanValue())
                    val next = consumeWhitespace()
                    index += 1
                    if (next == '}'.code) break
                    if (next != ','.code) fail("unexpected character in an object")
                    if (consumeWhitespace() == '}'.code) {
                        index += 1
                        break
                    }
                }
            }
            depth -= 1
            return FoundationJsonNode.Object(keys, values)
        }

        private fun scanString(): FoundationJsonNode.Text {
            index += 1
            val start = index
            while (true) {
                if (index >= bytes.size) fail("unexpected end of input in a string")
                val byte = bytes[index].toInt() and 0xFF
                if (byte == '"'.code) break
                if (byte == '\\'.code) {
                    // Which escapes are valid is decided when the string is read. Only the
                    // shape matters here: `\u` owns the next four bytes, none of them a quote.
                    index += 1
                    if (index >= bytes.size) fail("unexpected end of input in a string")
                    val escaped = bytes[index].toInt() and 0xFF
                    index += 1
                    if (escaped == 'u'.code) {
                        if (bytes.size - index < 4) fail("unexpected end of input in a string")
                        for (offset in 0 until 4) {
                            if (bytes[index + offset].toInt() == '"'.code) fail("invalid \\u escape")
                        }
                        index += 4
                    }
                } else {
                    index += 1
                }
            }
            val end = index
            index += 1
            return FoundationJsonNode.Text(bytes, start, end)
        }

        private fun scanNumber(): FoundationJsonNode.Number {
            val start = index
            index += 1
            while (index < bytes.size) {
                val byte = bytes[index].toInt() and 0xFF
                val continues = isDigit(byte) || byte == '.'.code || byte == '+'.code || byte == '-'.code ||
                    byte == 'e'.code || byte == 'E'.code
                if (!continues) break
                index += 1
            }
            return FoundationJsonNode.Number(bytes, start, index)
        }
    }

    private fun isDigit(byte: Int): Boolean = byte >= '0'.code && byte <= '9'.code

    // Step 2: values

    internal fun decodeString(bytes: ByteArray, start: Int, end: Int): String {
        var index = start
        while (index < end) {
            val byte = bytes[index].toInt() and 0xFF
            if (byte == '\\'.code || byte < 0x20) break
            index += 1
        }
        if (index == end) return decodeUtf8(bytes, start, end)

        val out = StringBuilder(end - start)
        out.append(decodeUtf8(bytes, start, index))
        var chunkStart = index
        while (index < end) {
            val byte = bytes[index].toInt() and 0xFF
            if (byte == '\\'.code) {
                out.append(decodeUtf8(bytes, chunkStart, index))
                index = decodeEscape(bytes, index + 1, end, out)
                chunkStart = index
            } else {
                if (byte < 0x20) fail("unescaped control character in a string")
                index += 1
            }
        }
        out.append(decodeUtf8(bytes, chunkStart, index))
        return out.toString()
    }

    private fun decodeUtf8(bytes: ByteArray, start: Int, end: Int): String {
        if (start == end) return ""
        return Utf8.decodeStrict(bytes.copyOfRange(start, end)) ?: fail("a string is not valid UTF-8")
    }

    /** [index] is just past the backslash. Returns the index after the escape. */
    private fun decodeEscape(bytes: ByteArray, index: Int, end: Int, out: StringBuilder): Int {
        // The scan saw a byte after every backslash and four after every `\u`.
        when (bytes[index].toInt().toChar()) {
            '"' -> out.append('"')
            '\\' -> out.append('\\')
            '/' -> out.append('/')
            'b' -> out.append('\b')
            'f' -> out.append('\u000C')
            'n' -> out.append('\n')
            'r' -> out.append('\r')
            't' -> out.append('\t')
            'u' -> {
                val unit = hexUnit(bytes, index + 1)
                var next = index + 5
                if (unit in 0xD800..0xDBFF) {
                    // A lead surrogate must be followed by an escaped trail surrogate.
                    if (end - next < 2 || bytes[next].toInt() != '\\'.code || bytes[next + 1].toInt() != 'u'.code) {
                        fail("expected a low surrogate after a high surrogate")
                    }
                    val trail = hexUnit(bytes, next + 2)
                    if (trail !in 0xDC00..0xDFFF) fail("expected a low surrogate after a high surrogate")
                    out.append(unit.toChar()).append(trail.toChar())
                    next += 6
                } else {
                    if (unit in 0xDC00..0xDFFF) fail("a lone low surrogate is not a Unicode scalar")
                    out.append(unit.toChar())
                }
                return next
            }
            else -> fail("invalid escape in a string")
        }
        return index + 1
    }

    private fun hexUnit(bytes: ByteArray, start: Int): Int {
        var unit = 0
        for (offset in 0 until 4) {
            val digit = when (val character = bytes[start + offset].toInt().toChar()) {
                in '0'..'9' -> character - '0'
                in 'a'..'f' -> character - 'a' + 10
                in 'A'..'F' -> character - 'A' + 10
                else -> fail("invalid \\u escape")
            }
            unit = (unit shl 4) or digit
        }
        return unit
    }

    internal fun decodeDouble(bytes: ByteArray, start: Int, end: Int): Double {
        if (!isJsonNumber(bytes, start, end)) fail("malformed number")
        val text = String(bytes, start, end - start, Charsets.US_ASCII)
        // The spelling is plain ASCII JSON here, which `parseDouble` reads with correct rounding.
        val value = java.lang.Double.parseDouble(text)
        if (value.isInfinite()) fail("number is not representable")
        if (value == 0.0 && !isTrueZero(bytes, start, end)) fail("number is not representable")
        return value
    }

    /** `-? (0 | [1-9][0-9]*) (\.[0-9]+)? ([eE][+-]?[0-9]+)?`, which is what Foundation's checks plus `strtod` accept. */
    private fun isJsonNumber(bytes: ByteArray, start: Int, end: Int): Boolean {
        var index = start
        fun at(position: Int): Int = if (position < end) bytes[position].toInt() and 0xFF else -1
        fun digits(): Boolean {
            val first = index
            while (isDigit(at(index))) index += 1
            return index > first
        }
        if (at(index) == '-'.code) index += 1
        if (at(index) == '0'.code) {
            index += 1
        } else if (!digits()) {
            return false
        }
        if (at(index) == '.'.code) {
            index += 1
            if (!digits()) return false
        }
        if (at(index) == 'e'.code || at(index) == 'E'.code) {
            index += 1
            if (at(index) == '+'.code || at(index) == '-'.code) index += 1
            if (!digits()) return false
        }
        return index == end
    }

    // No non-zero digit before the exponent.
    private fun isTrueZero(bytes: ByteArray, start: Int, end: Int): Boolean {
        for (index in start until end) {
            val byte = bytes[index].toInt() and 0xFF
            if (byte >= '1'.code && byte <= '9'.code) return false
            if (byte == 'e'.code || byte == 'E'.code) return true
        }
        return true
    }

    // Encodings (RFC 4627 section 3, plus byte order marks)

    private fun utf8Representation(data: ByteArray): ByteArray {
        fun byteAt(position: Int): Int = if (position < data.size) data[position].toInt() and 0xFF else -1
        val b0 = byteAt(0)
        val b1 = byteAt(1)
        val b2 = byteAt(2)
        val b3 = byteAt(3)
        return when {
            b0 == 0x00 && b1 == 0x00 && b2 == 0xFE && b3 == 0xFF -> fromUtf32(data, 4, bigEndian = true)
            b0 == 0xFE && b1 == 0xFF && b2 == 0x00 && b3 == 0x00 -> fromUtf32(data, 4, bigEndian = false)
            b0 == 0xFE && b1 == 0xFF -> fromUtf16(data, 2, bigEndian = true)
            b0 == 0xFF && b1 == 0xFE -> fromUtf16(data, 2, bigEndian = false)
            b0 == 0xEF && b1 == 0xBB && b2 == 0xBF -> data.copyOfRange(3, data.size)
            b0 == 0x00 && b1 == 0x00 && b2 == 0x00 && b3 > 0 -> fromUtf32(data, 0, bigEndian = true)
            b0 == 0x00 && b1 > 0 && b2 == 0x00 && b3 > 0 -> fromUtf16(data, 0, bigEndian = true)
            b0 > 0 && b1 == 0x00 && b2 == 0x00 && b3 == 0x00 -> fromUtf32(data, 0, bigEndian = false)
            b0 > 0 && b1 == 0x00 && b2 > 0 && b3 == 0x00 -> fromUtf16(data, 0, bigEndian = false)
            b0 == 0x00 && b1 > 0 && b2 < 0 -> fromUtf16(data, 0, bigEndian = true)
            b0 > 0 && b1 == 0x00 && b2 < 0 -> fromUtf16(data, 0, bigEndian = false)
            else -> data
        }
    }

    // Foundation ignores an incomplete code unit at the end of UTF-16 or UTF-32 input and
    // refuses an unpaired surrogate or a value that is not a scalar.

    private fun fromUtf16(data: ByteArray, offset: Int, bigEndian: Boolean): ByteArray {
        val units = CharArray((data.size - offset) / 2)
        for (index in units.indices) {
            val first = data[offset + index * 2].toInt() and 0xFF
            val second = data[offset + index * 2 + 1].toInt() and 0xFF
            units[index] = (if (bigEndian) (first shl 8) or second else (second shl 8) or first).toChar()
        }
        return Utf8.encodeStrict(String(units)) ?: fail("the input is not valid UTF-16")
    }

    private fun fromUtf32(data: ByteArray, offset: Int, bigEndian: Boolean): ByteArray {
        val out = StringBuilder((data.size - offset) / 4)
        var index = offset
        while (index + 4 <= data.size) {
            var scalar = 0
            for (position in 0 until 4) {
                val byte = data[index + if (bigEndian) position else 3 - position].toInt() and 0xFF
                scalar = (scalar shl 8) or byte
            }
            if (scalar < 0 || scalar > 0x10FFFF || scalar in 0xD800..0xDFFF) fail("the input is not valid UTF-32")
            out.appendCodePoint(scalar)
            index += 4
        }
        return Utf8.encodeStrict(out) ?: fail("the input is not valid UTF-32")
    }
}
