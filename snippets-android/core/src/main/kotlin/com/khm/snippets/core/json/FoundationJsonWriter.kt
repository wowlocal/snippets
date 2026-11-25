package com.khm.snippets.core.json

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.canonical.SwiftDouble
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.text.FoundationText
import java.io.ByteArrayOutputStream

/**
 * Writes a [JsonValue] the way Foundation's `JSONEncoder` does with
 * `[.prettyPrinted, .sortedKeys]`, byte for byte: two-space indent, `"key" : value`,
 * keys in UTF-8 byte order, a blank line inside an empty array or object, no trailing
 * newline, `/` escaped as `\/`, and a whole double without `.0`.
 *
 * Local files do not have to match Foundation's bytes, but one fixed spelling keeps the
 * output deterministic, and this is the one a Swift build of the same file would write.
 */
object FoundationJsonWriter {

    /** A number that JSON cannot spell (NaN or infinite). Foundation's encoder throws here too. */
    class NonFiniteNumber : IllegalArgumentException("JSON cannot represent a number that is not finite")

    @Throws(NonFiniteNumber::class)
    fun prettyPrinted(value: JsonValue): ByteArray {
        val out = ByteArrayOutputStream()
        write(value, 0, out)
        return out.toByteArray()
    }

    private fun write(value: JsonValue, indent: Int, out: ByteArrayOutputStream) {
        when (value) {
            is JsonValue.Null -> writeAscii("null", out)
            is JsonValue.Bool -> writeAscii(if (value.value) "true" else "false", out)
            is JsonValue.Integer -> writeAscii(value.value.toString(), out)
            is JsonValue.Real -> writeAscii(number(value.value), out)
            is JsonValue.Text -> writeString(Utf8.encode(value.value), out)
            is JsonValue.Utf8 -> writeString(value.bytes, out)
            is JsonValue.Array -> {
                out.write('['.code)
                out.write('\n'.code)
                var first = true
                for (element in value.elements) {
                    if (!first) writeAscii(",\n", out)
                    first = false
                    writeIndent(indent + 1, out)
                    write(element, indent + 1, out)
                }
                out.write('\n'.code)
                writeIndent(indent, out)
                out.write(']'.code)
            }
            is JsonValue.Object -> {
                out.write('{'.code)
                out.write('\n'.code)
                var first = true
                for (key in value.members.keys.sortedWith(FoundationText::compareScalars)) {
                    if (!first) writeAscii(",\n", out)
                    first = false
                    writeIndent(indent + 1, out)
                    writeString(Utf8.encode(key), out)
                    writeAscii(" : ", out)
                    write(value.members.getValue(key), indent + 1, out)
                }
                out.write('\n'.code)
                writeIndent(indent, out)
                out.write('}'.code)
            }
        }
    }

    /** Swift's `description` of the double, minus a trailing `.0`: `700000000`, `0.25`, `1e+16`, `-0`. */
    private fun number(value: Double): String {
        if (!value.isFinite()) throw NonFiniteNumber()
        val description = SwiftDouble.description(value)
        return if (description.endsWith(".0")) description.substring(0, description.length - 2) else description
    }

    private fun writeIndent(indent: Int, out: ByteArrayOutputStream) {
        repeat(indent) {
            out.write(' '.code)
            out.write(' '.code)
        }
    }

    private fun writeAscii(text: String, out: ByteArrayOutputStream) {
        for (character in text) out.write(character.code)
    }

    private fun writeString(utf8: ByteArray, out: ByteArrayOutputStream) {
        out.write('"'.code)
        for (byte in utf8) {
            when (val unsigned = byte.toInt() and 0xFF) {
                '"'.code -> writeAscii("\\\"", out)
                '\\'.code -> writeAscii("\\\\", out)
                '/'.code -> writeAscii("\\/", out)
                0x08 -> writeAscii("\\b", out)
                0x0C -> writeAscii("\\f", out)
                0x0A -> writeAscii("\\n", out)
                0x0D -> writeAscii("\\r", out)
                0x09 -> writeAscii("\\t", out)
                else -> if (unsigned < 0x20) {
                    writeAscii("\\u00", out)
                    out.write("0123456789abcdef"[unsigned ushr 4].code)
                    out.write("0123456789abcdef"[unsigned and 0x0F].code)
                } else {
                    out.write(unsigned)
                }
            }
        }
        out.write('"'.code)
    }
}
