package com.khm.snippets.core.vault

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.json.FoundationJson
import com.khm.snippets.core.json.FoundationJsonException
import com.khm.snippets.core.text.FoundationText

/**
 * A JSON tree as Foundation's `JSONDecoder` reads `vault.json` and a backup, with the two
 * things the passthrough bags need and `FoundationJsonNode` does not offer: the list of
 * an object's keys, and a number's own spelling (so `600000` stays an integer and an
 * integer beyond 2^53 is not rounded through a double).
 *
 * The rules are Foundation's (`core.json.FoundationJson` documents them): a structural
 * scan that accepts one trailing comma and nests at most 512 deep, and strings and
 * numbers that are only checked where they are read. That laziness is what makes a
 * damaged `name` degrade to a default instead of failing the vault.
 *
 * Strings and doubles are decoded by `FoundationJson` itself; only the scan is repeated
 * here.
 *
 * Deviation: input must be UTF-8, with or without a byte order mark. Foundation also
 * reads UTF-16 and UTF-32; no writer of these files produces them.
 */
internal sealed class JsonNode {

    object Null : JsonNode()

    object True : JsonNode()

    object False : JsonNode()

    class Str(private val source: ByteArray, private val start: Int, private val end: Int) : JsonNode() {

        @Throws(FoundationJsonException::class)
        fun value(): String = FoundationJson.decodeString(source, start, end)
    }

    class Num(private val source: ByteArray, private val start: Int, private val end: Int) : JsonNode() {

        @Throws(FoundationJsonException::class)
        fun double(): Double = FoundationJson.decodeDouble(source, start, end)

        /**
         * `decode(Int64.self)`: plain integer digits are read exactly; any other spelling
         * (`1.0`, `1e3`, digits that overflow) goes through a double and must come out a
         * whole number that fits, so `1.0` is `1` and `1.5` or 2^64 is an error.
         */
        @Throws(FoundationJsonException::class)
        fun long(): Long {
            exactInteger()?.let { return it }
            val value = double()
            if (value != Math.rint(value) || value < -TWO_POW_63 || value >= TWO_POW_63) {
                throw FoundationJsonException("number does not fit a 64-bit integer")
            }
            return value.toLong()
        }

        // `-?(0|[1-9][0-9]*)` that fits; anything else is left to the double path.
        private fun exactInteger(): Long? {
            var index = start
            val negative = index < end && source[index].toInt() == '-'.code
            if (negative) index += 1
            val digits = end - index
            if (digits == 0 || digits > 19) return null
            if (source[index].toInt() == '0'.code && digits > 1) return null
            var magnitude = 0L
            while (index < end) {
                val digit = source[index].toInt() - '0'.code
                if (digit < 0 || digit > 9) return null
                // Accumulated as a negative number, which has the larger range.
                if (magnitude < (Long.MIN_VALUE + digit) / 10) return null
                magnitude = magnitude * 10 - digit
                index += 1
            }
            if (negative) return magnitude
            return if (magnitude == Long.MIN_VALUE) null else -magnitude
        }

        private companion object {
            const val TWO_POW_63 = 9.223372036854775808E18
        }
    }

    class Arr(val elements: List<JsonNode>) : JsonNode()

    class Obj(private val keys: List<Str>, private val values: List<JsonNode>) : JsonNode() {

        /**
         * The members by decoded key. All keys are decoded together, so one malformed key
         * spoils the object. Of two members with the same key the first wins, and keys
         * that differ only in normalization form are one key, as in a Swift dictionary.
         */
        @Throws(FoundationJsonException::class)
        fun members(): Members {
            val byKey = LinkedHashMap<String, Member>(keys.size * 2)
            for (index in keys.indices) {
                val key = keys[index].value()
                val identity = FoundationText.nfc(key)
                if (!byKey.containsKey(identity)) byKey[identity] = Member(key, values[index])
            }
            return Members(byKey)
        }
    }

    class Member(val key: String, val node: JsonNode)

    class Members(private val byKey: Map<String, Member>) {

        operator fun get(key: String): JsonNode? = byKey[FoundationText.nfc(key)]?.node

        /** Every distinct key as first spelled, in file order (`allKeys`). */
        val all: Collection<Member> get() = byKey.values
    }
}

/** How a typed read failed, with Foundation's four `DecodingError` cases. */
internal class JsonDecodeException(val kind: Kind, detail: String) : Exception(detail) {
    enum class Kind { KEY_NOT_FOUND, VALUE_NOT_FOUND, TYPE_MISMATCH, DATA_CORRUPTED }
}

internal object LenientJson {

    /** Foundation refuses deeper nesting of arrays and objects. */
    const val MAXIMUM_DEPTH = FoundationJson.MAXIMUM_DEPTH

    @Throws(FoundationJsonException::class)
    fun parse(data: ByteArray): JsonNode {
        val scanner = Scanner(data, if (hasByteOrderMark(data)) 3 else 0)
        val value = scanner.scanValue()
        scanner.requireOnlyWhitespaceRemains()
        return value
    }

    /** As [parse], with every failure reported as `DecodingError.dataCorrupted`. */
    @Throws(JsonDecodeException::class)
    fun parseOrCorrupt(data: ByteArray): JsonNode = try {
        parse(data)
    } catch (failure: FoundationJsonException) {
        throw corrupted(failure.message ?: "the data is not JSON")
    }

    private fun hasByteOrderMark(data: ByteArray): Boolean =
        data.size >= 3 && data[0] == 0xEF.toByte() && data[1] == 0xBB.toByte() && data[2] == 0xBF.toByte()

    private fun fail(message: String): Nothing = throw FoundationJsonException(message)

    private class Scanner(private val bytes: ByteArray, private var index: Int) {
        private var depth = 0

        private fun peek(): Int = if (index < bytes.size) bytes[index].toInt() and 0xFF else -1

        private fun isWhitespace(byte: Int): Boolean = byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D

        private fun isDigit(byte: Int): Boolean = byte >= '0'.code && byte <= '9'.code

        private fun consumeWhitespace(): Int {
            while (index < bytes.size) {
                val byte = bytes[index].toInt() and 0xFF
                if (!isWhitespace(byte)) return byte
                index += 1
            }
            fail("unexpected end of input")
        }

        fun requireOnlyWhitespaceRemains() {
            while (index < bytes.size) {
                if (!isWhitespace(bytes[index].toInt() and 0xFF)) fail("unexpected content after the top-level value")
                index += 1
            }
        }

        fun scanValue(): JsonNode = when (val byte = consumeWhitespace()) {
            '"'.code -> scanString()
            '{'.code -> scanObject()
            '['.code -> scanArray()
            't'.code -> literal("true", JsonNode.True)
            'f'.code -> literal("false", JsonNode.False)
            'n'.code -> literal("null", JsonNode.Null)
            else -> if (byte == '-'.code || isDigit(byte)) scanNumber() else fail("unexpected character")
        }

        private fun literal(text: String, node: JsonNode): JsonNode {
            if (bytes.size - index < text.length) fail("unexpected end of input")
            for (offset in text.indices) {
                if (bytes[index + offset].toInt() != text[offset].code) fail("unexpected character in a literal")
            }
            index += text.length
            return node
        }

        private fun enterContainer() {
            if (depth >= MAXIMUM_DEPTH) fail("too many nested arrays or objects")
            depth += 1
        }

        private fun scanArray(): JsonNode {
            index += 1
            enterContainer()
            val elements = ArrayList<JsonNode>()
            if (consumeWhitespace() == ']'.code) {
                index += 1
            } else {
                while (true) {
                    elements.add(scanValue())
                    val next = consumeWhitespace()
                    index += 1
                    if (next == ']'.code) break
                    if (next != ','.code) fail("unexpected character in an array")
                    if (consumeWhitespace() == ']'.code) {
                        index += 1
                        break
                    }
                }
            }
            depth -= 1
            return JsonNode.Arr(elements)
        }

        private fun scanObject(): JsonNode {
            index += 1
            enterContainer()
            val keys = ArrayList<JsonNode.Str>()
            val values = ArrayList<JsonNode>()
            if (consumeWhitespace() == '}'.code) {
                index += 1
            } else {
                while (true) {
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
            return JsonNode.Obj(keys, values)
        }

        private fun scanString(): JsonNode.Str {
            index += 1
            val start = index
            while (true) {
                if (index >= bytes.size) fail("unexpected end of input in a string")
                val byte = bytes[index].toInt() and 0xFF
                if (byte == '"'.code) break
                if (byte == '\\'.code) {
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
            return JsonNode.Str(bytes, start, end)
        }

        private fun scanNumber(): JsonNode.Num {
            val start = index
            index += 1
            while (index < bytes.size) {
                val byte = bytes[index].toInt() and 0xFF
                val continues = isDigit(byte) || byte == '.'.code || byte == '+'.code || byte == '-'.code ||
                    byte == 'e'.code || byte == 'E'.code
                if (!continues) break
                index += 1
            }
            return JsonNode.Num(bytes, start, index)
        }
    }

    // Typed reads, with `KeyedDecodingContainer`'s outcomes

    fun corrupted(detail: String) = JsonDecodeException(JsonDecodeException.Kind.DATA_CORRUPTED, detail)

    private fun mismatch(expected: String) =
        JsonDecodeException(JsonDecodeException.Kind.TYPE_MISMATCH, "expected $expected")

    /** `decoder.container(keyedBy:)`. */
    @Throws(JsonDecodeException::class)
    fun members(node: JsonNode): JsonNode.Members {
        val container = node as? JsonNode.Obj ?: throw mismatch("an object")
        return try {
            container.members()
        } catch (failure: FoundationJsonException) {
            throw corrupted(failure.message ?: "malformed object key")
        }
    }

    /** `container.decode(_:forKey:)`: the node, or the error for a missing key or an explicit null. */
    @Throws(JsonDecodeException::class)
    fun required(members: JsonNode.Members, key: String): JsonNode {
        val node = members[key]
            ?: throw JsonDecodeException(JsonDecodeException.Kind.KEY_NOT_FOUND, "no value for \"$key\"")
        if (node === JsonNode.Null) {
            throw JsonDecodeException(JsonDecodeException.Kind.VALUE_NOT_FOUND, "\"$key\" is null")
        }
        return node
    }

    /** `decodeIfPresent`: `null` for a missing key and for an explicit null. */
    fun present(members: JsonNode.Members, key: String): JsonNode? =
        members[key]?.takeUnless { it === JsonNode.Null }

    @Throws(JsonDecodeException::class)
    fun string(node: JsonNode): String {
        val text = node as? JsonNode.Str ?: throw mismatch("a string")
        return try {
            text.value()
        } catch (failure: FoundationJsonException) {
            throw corrupted(failure.message ?: "malformed string")
        }
    }

    @Throws(JsonDecodeException::class)
    fun boolean(node: JsonNode): Boolean = when (node) {
        JsonNode.True -> true
        JsonNode.False -> false
        else -> throw mismatch("a boolean")
    }

    @Throws(JsonDecodeException::class)
    fun long(node: JsonNode): Long {
        val number = node as? JsonNode.Num ?: throw mismatch("a number")
        return try {
            number.long()
        } catch (failure: FoundationJsonException) {
            throw corrupted(failure.message ?: "malformed number")
        }
    }

    @Throws(JsonDecodeException::class)
    fun double(node: JsonNode): Double {
        val number = node as? JsonNode.Num ?: throw mismatch("a number")
        return try {
            number.double()
        } catch (failure: FoundationJsonException) {
            throw corrupted(failure.message ?: "malformed number")
        }
    }

    @Throws(JsonDecodeException::class)
    fun array(node: JsonNode): List<JsonNode> = (node as? JsonNode.Arr)?.elements ?: throw mismatch("an array")

    /**
     * Swift's `JSONValue.init(from:)`: null, then Bool, then Int64, then Double, then
     * String, array and object. A value that is none of them (a malformed number or
     * string anywhere inside) fails as a whole.
     */
    @Throws(JsonDecodeException::class)
    fun passthrough(node: JsonNode): JsonValue = when (node) {
        JsonNode.Null -> JsonValue.Null
        JsonNode.True -> JsonValue.Bool(true)
        JsonNode.False -> JsonValue.Bool(false)
        is JsonNode.Num -> try {
            JsonValue.Integer(node.long())
        } catch (_: FoundationJsonException) {
            JsonValue.Real(double(node))
        }
        is JsonNode.Str -> JsonValue.Text(string(node))
        is JsonNode.Arr -> JsonValue.Array(node.elements.map(::passthrough))
        is JsonNode.Obj -> {
            val out = LinkedHashMap<String, JsonValue>()
            for (member in members(node).all) out[member.key] = passthrough(member.node)
            JsonValue.Object(out)
        }
    }

    /**
     * `JSONPassthroughBag.decode`: every key that is not [known], with a value that
     * cannot be represented left out rather than failing the load.
     */
    fun bag(members: JsonNode.Members, known: Set<String>): Map<String, JsonValue> {
        val bag = LinkedHashMap<String, JsonValue>()
        for (member in members.all) {
            if (member.key in known) continue
            try {
                bag[member.key] = passthrough(member.node)
            } catch (_: JsonDecodeException) {
                // Swift: `try?`, so one unrepresentable value cannot quarantine a vault.
            }
        }
        return bag
    }
}
