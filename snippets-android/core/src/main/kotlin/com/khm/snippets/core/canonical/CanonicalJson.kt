package com.khm.snippets.core.canonical

import com.khm.snippets.core.crypto.Utf8
import java.nio.charset.StandardCharsets
import java.text.Normalizer

/**
 * Deterministic JSON: exactly one byte sequence per value (`CanonicalJSON` in
 * `snippets/Core/SyncEnvelope.swift`). These bytes are hashed and then sealed, so they are
 * written out by hand and never come from a JSON library's printer.
 *
 * Emitter:
 * 1. No whitespace.
 * 2. Object keys sorted by their UTF-8 bytes, unsigned. That is code-point order, not the
 *    UTF-16 order of `String.compareTo`; the two differ for supplementary-plane keys
 *    against U+E000…U+FFFF.
 * 3. Strings escape only `"`, `\` and the C0 controls (`\b \t \n \f \r`, otherwise
 *    `\u00xx` in lowercase hex). `/`, U+007F, U+2028 and all non-ASCII are raw UTF-8.
 * 4. Integers print as `Int64` decimal, doubles as [SwiftDouble.description]. A finite
 *    double always carries a `.` or an `e`, so the two stay distinguishable.
 *
 * Parser: strict JSON, every string returned as bytes ([JsonValue.Utf8]), nesting limited
 * to [MAXIMUM_DEPTH], duplicate keys refused. Swift applies no size limit at this layer (its
 * 674 815-byte ceiling, `SyncMerge.maximumWireCanonicalBytes`, is on what it seals), so
 * neither does this: a caller reading untrusted bytes bounds them first.
 */
object CanonicalJson {

    /** Deeper nesting is refused so a hostile blob cannot overflow the stack. Nothing we produce nests more than three deep. */
    const val MAXIMUM_DEPTH = 32

    sealed class Failure(message: String) : Exception(message) {

        class NonFiniteNumber :
            Failure("a canonical JSON number must be finite; NaN and infinity have no JSON spelling")

        class InvalidUtf8 : Failure("a canonical JSON string must be valid UTF-8")

        class UnexpectedEnd : Failure("the JSON input ended in the middle of a value")

        class UnexpectedByte(val offset: Int) : Failure("unexpected byte at offset $offset")

        /** [key] is the second spelling met. Two keys that differ only in Unicode normalisation are duplicates. */
        class DuplicateKey(val key: String) :
            Failure("duplicate object key \"$key\"; canonical JSON has no last-one-wins rule")

        class TrailingBytes(val offset: Int) : Failure("trailing bytes after the top-level value at offset $offset")

        class TooDeep : Failure("JSON nested deeper than $MAXIMUM_DEPTH levels")
    }

    // Emitting

    /** Swift `CanonicalJSON.data`. The caller wipes the result when [value] held a secret. */
    @Throws(Failure::class)
    fun encode(value: JsonValue): ByteArray {
        val out = ByteSink(512)
        try {
            emit(value, out)
            return out.toByteArray()
        } finally {
            out.wipe()
        }
    }

    /** Swift `CanonicalJSON.string`. For tests and diagnostics; never for a value that contains a secret. */
    @Throws(Failure::class)
    fun encodeToString(value: JsonValue): String = Utf8.decodeStrict(encode(value)) ?: throw Failure.InvalidUtf8()

    private fun emit(value: JsonValue, out: ByteSink) {
        when (value) {
            JsonValue.Null -> out.appendAscii("null")
            is JsonValue.Bool -> out.appendAscii(if (value.value) "true" else "false")
            is JsonValue.Integer -> out.appendAscii(value.value.toString())
            is JsonValue.Real -> {
                if (!value.value.isFinite()) throw Failure.NonFiniteNumber()
                out.appendAscii(SwiftDouble.description(value.value))
            }
            is JsonValue.Text -> emitString(Utf8.encodeStrict(value.value) ?: throw Failure.InvalidUtf8(), out)
            is JsonValue.Utf8 -> emitString(value.bytes, out)
            is JsonValue.Array -> {
                out.append('['.code)
                for ((index, element) in value.elements.withIndex()) {
                    if (index > 0) out.append(','.code)
                    emit(element, out)
                }
                out.append(']'.code)
            }
            is JsonValue.Object -> {
                val sorted = value.members.entries
                    .map { Member(it.key, Utf8.encodeStrict(it.key) ?: throw Failure.InvalidUtf8(), it.value) }
                    .sortedWith { first, second -> compareUnsigned(first.bytes, second.bytes) }
                refuseEquivalentKeys(sorted)
                out.append('{'.code)
                for ((index, member) in sorted.withIndex()) {
                    if (index > 0) out.append(','.code)
                    emitString(member.bytes, out)
                    out.append(':'.code)
                    emit(member.value, out)
                }
                out.append('}'.code)
            }
        }
    }

    private class Member(val key: String, val bytes: ByteArray, val value: JsonValue)

    /** `lexicographicallyPrecedes` on `[UInt8]`: byte by byte, unsigned, the shorter of two equal prefixes first. */
    private fun compareUnsigned(first: ByteArray, second: ByteArray): Int {
        val shared = minOf(first.size, second.size)
        for (index in 0 until shared) {
            val difference = (first[index].toInt() and 0xFF) - (second[index].toInt() and 0xFF)
            if (difference != 0) return difference
        }
        return first.size - second.size
    }

    /**
     * A Swift dictionary cannot hold two canonically equivalent keys, so Swift's emitter
     * never meets them. A Kotlin map can; emitting both would write an object that no
     * Swift reader accepts.
     */
    private fun refuseEquivalentKeys(members: List<Member>) {
        if (members.none { member -> member.bytes.any { it < 0 } }) return   // all ASCII: distinct keys are distinct
        val seen = HashSet<String>(members.size * 2)
        for (member in members) {
            if (!seen.add(Normalizer.normalize(member.key, Normalizer.Form.NFC))) throw Failure.DuplicateKey(member.key)
        }
    }

    private fun emitString(bytes: ByteArray, out: ByteSink) {
        if (!isValidUtf8(bytes)) throw Failure.InvalidUtf8()
        out.append('"'.code)
        for (signed in bytes) {
            val byte = signed.toInt() and 0xFF
            when {
                byte == '"'.code -> out.appendAscii("\\\"")
                byte == '\\'.code -> out.appendAscii("\\\\")
                byte == 0x08 -> out.appendAscii("\\b")
                byte == 0x09 -> out.appendAscii("\\t")
                byte == 0x0A -> out.appendAscii("\\n")
                byte == 0x0C -> out.appendAscii("\\f")
                byte == 0x0D -> out.appendAscii("\\r")
                byte <= 0x1F -> {
                    // Lowercase hex, fixed width. The only controls without a short escape.
                    out.appendAscii("\\u00")
                    out.append(HEX[byte ushr 4].code)
                    out.append(HEX[byte and 0x0F].code)
                }
                // Everything else, including `/` and every non-ASCII byte, verbatim.
                else -> out.append(byte)
            }
        }
        out.append('"'.code)
    }

    private const val HEX = "0123456789abcdef"

    /**
     * Validates UTF-8 without building a `String`. Rejects over-long forms, surrogates,
     * values above U+10FFFF and truncated sequences.
     */
    fun isValidUtf8(bytes: ByteArray): Boolean {
        var index = 0
        while (index < bytes.size) {
            val lead = bytes[index].toInt() and 0xFF
            val continuationCount: Int
            var scalar: Int
            val lowerBound: Int
            if (lead < 0x80) {
                index += 1
                continue
            } else if ((lead and 0xE0) == 0xC0) {
                continuationCount = 1; scalar = lead and 0x1F; lowerBound = 0x80
            } else if ((lead and 0xF0) == 0xE0) {
                continuationCount = 2; scalar = lead and 0x0F; lowerBound = 0x800
            } else if ((lead and 0xF8) == 0xF0) {
                continuationCount = 3; scalar = lead and 0x07; lowerBound = 0x1_0000
            } else {
                return false
            }

            if (index + continuationCount >= bytes.size) return false
            for (offset in 1..continuationCount) {
                val byte = bytes[index + offset].toInt() and 0xFF
                if ((byte and 0xC0) != 0x80) return false
                scalar = (scalar shl 6) or (byte and 0x3F)
            }
            if (scalar < lowerBound || scalar > 0x10_FFFF) return false
            if (scalar in 0xD800..0xDFFF) return false
            index += continuationCount + 1
        }
        return true
    }

    // Parsing

    /**
     * Swift `CanonicalJSON.value`. Every string comes back as [JsonValue.Utf8], so a secret
     * can be read out of a blob without becoming a `String`. Object keys are `String`s; a
     * key is never a secret.
     *
     * Numbers follow Swift exactly: a token with `.` or an exponent is a [JsonValue.Real]
     * (an out-of-range one is infinite, and emitting it then fails); any other token is a
     * [JsonValue.Integer], or a [JsonValue.Real] when it does not fit in 64 bits.
     *
     * A key is Foundation's `String(data:encoding: .utf8)` of its bytes, which drops one
     * leading U+FEFF: `{"\u{FEFF}a":1}` has the key `a` and is re-emitted as `{"a":1}`, and
     * `{"\u{FEFF}a":1,"a":2}` is [Failure.DuplicateKey], as in Swift. String values are bytes
     * and keep every byte; [JsonValue.textOrNull] drops the mark when they become text.
     */
    @Throws(Failure::class)
    fun parse(bytes: ByteArray): JsonValue = parse(bytes, keysAsFoundationReadsThem = true)

    /**
     * [parse], with [keysAsFoundationReadsThem] `false` for a reader that ports a Swift
     * `JSONDecoder` rather than `CanonicalJSON.value`: there a key keeps a leading U+FEFF,
     * so it is another key than the one without it.
     */
    @Throws(Failure::class)
    internal fun parse(bytes: ByteArray, keysAsFoundationReadsThem: Boolean): JsonValue {
        val parser = Parser(bytes, keysAsFoundationReadsThem)
        val value = parser.parseValue(0)
        parser.skipWhitespace()
        if (parser.index != bytes.size) throw Failure.TrailingBytes(parser.index)
        return value
    }

    private class Parser(private val bytes: ByteArray, private val keysAsFoundationReadsThem: Boolean) {
        var index = 0

        private fun byteAt(position: Int): Int = bytes[position].toInt() and 0xFF

        fun skipWhitespace() {
            while (index < bytes.size) {
                when (byteAt(index)) {
                    0x20, 0x09, 0x0A, 0x0D -> index += 1
                    else -> return
                }
            }
        }

        fun parseValue(depth: Int): JsonValue {
            if (depth > MAXIMUM_DEPTH) throw Failure.TooDeep()
            skipWhitespace()
            if (index >= bytes.size) throw Failure.UnexpectedEnd()

            return when (byteAt(index)) {
                '{'.code -> parseObject(depth)
                '['.code -> parseArray(depth)
                '"'.code -> JsonValue.Utf8(parseString())
                't'.code -> { expect("true"); JsonValue.Bool(true) }
                'f'.code -> { expect("false"); JsonValue.Bool(false) }
                'n'.code -> { expect("null"); JsonValue.Null }
                else -> parseNumber()
            }
        }

        private fun expect(literal: String) {
            if (index + literal.length > bytes.size) throw Failure.UnexpectedByte(index)
            for (offset in literal.indices) {
                if (byteAt(index + offset) != literal[offset].code) throw Failure.UnexpectedByte(index)
            }
            index += literal.length
        }

        private fun parseObject(depth: Int): JsonValue {
            index += 1  // '{'
            val members = LinkedHashMap<String, JsonValue>()
            // Swift's dictionary compares keys by canonical equivalence; NFC stands in for that.
            val seen = HashSet<String>()
            skipWhitespace()
            if (index < bytes.size && byteAt(index) == '}'.code) {
                index += 1
                return JsonValue.Object(members)
            }
            while (true) {
                skipWhitespace()
                if (index >= bytes.size || byteAt(index) != '"'.code) throw Failure.UnexpectedByte(index)
                val keyBytes = parseString()
                val key = (if (keysAsFoundationReadsThem) Utf8.decodeStrict(keyBytes) else Utf8.decodeKeepingByteOrderMark(keyBytes))
                    ?: throw Failure.InvalidUtf8()
                if (!seen.add(normalizedKey(key))) throw Failure.DuplicateKey(key)

                skipWhitespace()
                if (index >= bytes.size || byteAt(index) != ':'.code) throw Failure.UnexpectedByte(index)
                index += 1
                members[key] = parseValue(depth + 1)

                skipWhitespace()
                if (index >= bytes.size) throw Failure.UnexpectedEnd()
                when (byteAt(index)) {
                    ','.code -> index += 1
                    '}'.code -> {
                        index += 1
                        return JsonValue.Object(members)
                    }
                    else -> throw Failure.UnexpectedByte(index)
                }
            }
        }

        private fun normalizedKey(key: String): String =
            if (key.all { it.code < 0x80 }) key else Normalizer.normalize(key, Normalizer.Form.NFC)

        private fun parseArray(depth: Int): JsonValue {
            index += 1  // '['
            val elements = ArrayList<JsonValue>()
            skipWhitespace()
            if (index < bytes.size && byteAt(index) == ']'.code) {
                index += 1
                return JsonValue.Array(elements)
            }
            while (true) {
                elements.add(parseValue(depth + 1))
                skipWhitespace()
                if (index >= bytes.size) throw Failure.UnexpectedEnd()
                when (byteAt(index)) {
                    ','.code -> index += 1
                    ']'.code -> {
                        index += 1
                        return JsonValue.Array(elements)
                    }
                    else -> throw Failure.UnexpectedByte(index)
                }
            }
        }

        private fun parseString(): ByteArray {
            index += 1  // opening quote
            val out = ByteSink(32)
            try {
                while (true) {
                    if (index >= bytes.size) throw Failure.UnexpectedEnd()
                    val byte = byteAt(index)
                    if (byte == '"'.code) {
                        index += 1
                        val decoded = out.toByteArray()
                        if (!isValidUtf8(decoded)) {
                            decoded.fill(0)
                            throw Failure.InvalidUtf8()
                        }
                        return decoded
                    }
                    if (byte == '\\'.code) {
                        index += 1
                        parseEscape(out)
                        continue
                    }
                    // A raw control character inside a string is malformed JSON.
                    if (byte < 0x20) throw Failure.UnexpectedByte(index)
                    out.append(byte)
                    index += 1
                }
            } finally {
                out.wipe()
            }
        }

        private fun parseEscape(out: ByteSink) {
            if (index >= bytes.size) throw Failure.UnexpectedEnd()
            val escape = byteAt(index)
            index += 1
            when (escape) {
                '"'.code -> out.append('"'.code)
                '\\'.code -> out.append('\\'.code)
                '/'.code -> out.append('/'.code)
                'b'.code -> out.append(0x08)
                'f'.code -> out.append(0x0C)
                'n'.code -> out.append(0x0A)
                'r'.code -> out.append(0x0D)
                't'.code -> out.append(0x09)
                'u'.code -> {
                    var scalar = parseHex4()
                    if (scalar in 0xD800..0xDBFF) {
                        // A high surrogate must be followed by `\uDC00`-`\uDFFF`; the pair
                        // encodes one supplementary-plane scalar.
                        if (index + 1 >= bytes.size || byteAt(index) != '\\'.code || byteAt(index + 1) != 'u'.code) {
                            throw Failure.UnexpectedByte(index)
                        }
                        index += 2
                        val low = parseHex4()
                        if (low !in 0xDC00..0xDFFF) throw Failure.UnexpectedByte(index)
                        scalar = 0x1_0000 + ((scalar - 0xD800) shl 10) + (low - 0xDC00)
                    } else if (scalar in 0xDC00..0xDFFF) {
                        throw Failure.UnexpectedByte(index)
                    }
                    appendScalar(scalar, out)
                }
                else -> throw Failure.UnexpectedByte(index - 1)
            }
        }

        private fun appendScalar(scalar: Int, out: ByteSink) {
            when {
                scalar < 0x80 -> out.append(scalar)
                scalar < 0x800 -> {
                    out.append(0xC0 or (scalar ushr 6))
                    out.append(0x80 or (scalar and 0x3F))
                }
                scalar < 0x1_0000 -> {
                    out.append(0xE0 or (scalar ushr 12))
                    out.append(0x80 or ((scalar ushr 6) and 0x3F))
                    out.append(0x80 or (scalar and 0x3F))
                }
                else -> {
                    out.append(0xF0 or (scalar ushr 18))
                    out.append(0x80 or ((scalar ushr 12) and 0x3F))
                    out.append(0x80 or ((scalar ushr 6) and 0x3F))
                    out.append(0x80 or (scalar and 0x3F))
                }
            }
        }

        private fun parseHex4(): Int {
            if (index + 4 > bytes.size) throw Failure.UnexpectedEnd()
            var value = 0
            repeat(4) {
                val digit = when (val byte = byteAt(index)) {
                    in '0'.code..'9'.code -> byte - '0'.code
                    in 'a'.code..'f'.code -> byte - 'a'.code + 10
                    in 'A'.code..'F'.code -> byte - 'A'.code + 10
                    else -> throw Failure.UnexpectedByte(index)
                }
                value = (value shl 4) or digit
                index += 1
            }
            return value
        }

        private fun isDigit(position: Int): Boolean = position < bytes.size && byteAt(position) in '0'.code..'9'.code

        /**
         * Strict JSON numbers: no leading `+`, no leading zeros, no bare `.5`, no
         * `NaN`/`Infinity`. A token with a `.` or an exponent becomes a double; everything
         * else an integer, falling back to a double on overflow.
         */
        private fun parseNumber(): JsonValue {
            val start = index
            if (index < bytes.size && byteAt(index) == '-'.code) index += 1

            val integerStart = index
            while (isDigit(index)) index += 1
            if (index == integerStart) throw Failure.UnexpectedByte(start)
            if (byteAt(integerStart) == '0'.code && index - integerStart > 1) {
                throw Failure.UnexpectedByte(integerStart)
            }

            var isFloating = false
            if (index < bytes.size && byteAt(index) == '.'.code) {
                isFloating = true
                index += 1
                val fractionStart = index
                while (isDigit(index)) index += 1
                if (index == fractionStart) throw Failure.UnexpectedByte(index)
            }
            if (index < bytes.size && (byteAt(index) == 'e'.code || byteAt(index) == 'E'.code)) {
                isFloating = true
                index += 1
                if (index < bytes.size && (byteAt(index) == '+'.code || byteAt(index) == '-'.code)) index += 1
                val exponentStart = index
                while (isDigit(index)) index += 1
                if (index == exponentStart) throw Failure.UnexpectedByte(index)
            }

            val token = String(bytes, start, index - start, StandardCharsets.US_ASCII)
            if (!isFloating) token.toLongOrNull()?.let { return JsonValue.Integer(it) }
            // The grammar above admits only what `parseDouble` reads as a decimal literal,
            // correctly rounded like Swift's `Double(String)`, with overflow becoming infinity.
            val number = token.toDoubleOrNull() ?: throw Failure.UnexpectedByte(start)
            return JsonValue.Real(number)
        }
    }
}

/**
 * A growable byte buffer that zeroes each array it outgrows: canonical bytes can be a
 * secure snippet's plaintext, and `ByteArrayOutputStream` would leave copies behind.
 */
internal class ByteSink(initialCapacity: Int) {

    private var buffer = ByteArray(initialCapacity.coerceAtLeast(16))
    private var count = 0

    fun append(byte: Int) {
        ensureCapacity(count + 1)
        buffer[count++] = byte.toByte()
    }

    fun appendAscii(text: String) {
        ensureCapacity(count + text.length)
        for (character in text) buffer[count++] = character.code.toByte()
    }

    private fun ensureCapacity(required: Int) {
        if (required < 0) throw OutOfMemoryError("canonical JSON output exceeds 2 GiB")
        if (required <= buffer.size) return
        val doubled = if (buffer.size > Int.MAX_VALUE / 2) Int.MAX_VALUE - 8 else buffer.size * 2
        val grown = buffer.copyOf(maxOf(doubled, required))
        buffer.fill(0)
        buffer = grown
    }

    /** An exactly sized copy that the caller owns. */
    fun toByteArray(): ByteArray = buffer.copyOf(count)

    fun wipe() {
        buffer.fill(0)
        count = 0
    }
}
