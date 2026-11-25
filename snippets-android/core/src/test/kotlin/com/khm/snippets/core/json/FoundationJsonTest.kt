package com.khm.snippets.core.json

import com.khm.snippets.core.canonical.JsonValue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame

/**
 * The rules of Foundation's reader and writer, one at a time. That they add up to what
 * Foundation does is the codec corpus's job (`SnippetLibraryCodecCorpusTest`).
 */
class FoundationJsonTest {

    private fun parse(text: String) = FoundationJson.parse(text.toByteArray())

    private fun refuses(text: String) {
        assertFailsWith<FoundationJsonException>(text) { parse(text) }
    }

    private fun string(text: String): String = assertIs<FoundationJsonNode.Text>(parse(text)).value()

    private fun double(text: String): Double = assertIs<FoundationJsonNode.Number>(parse(text)).doubleValue()

    @Test
    fun structureIsScannedWithFoundationsLeniencies() {
        assertEquals(2, assertIs<FoundationJsonNode.Array>(parse(" [1 , 2 ,\n] ")).elements.size)
        assertIs<FoundationJsonNode.Object>(parse("{\"a\":1,}"))
        assertSame(FoundationJsonNode.Null, parse("\tnull\r\n"))
        assertSame(FoundationJsonNode.True, parse("true"))
        assertSame(FoundationJsonNode.False, parse("false"))

        for (text in listOf(
            "", " ", "[", "[1", "[1,", "[,]", "[1,,2]", "[1 2]", "{", "{\"a\"}", "{\"a\":}", "{\"a\":1,,}", "{,}", "{a:1}",
            "{1:2}", "[] x", "[]\u000C", "\u00A0[]", "nul", "nulL", "tru", "truex", "'a'", "+1", ".5", "NaN", "[1]]", "\"abc",
            "\"a\\", "\"\\u12\"", "\"\\u\"\"\"", "[]\u0000",
        )) refuses(text)
    }

    @Test
    fun nestingStopsAtFiveHundredAndTwelve() {
        fun nested(depth: Int) = "[".repeat(depth) + "]".repeat(depth)
        assertIs<FoundationJsonNode.Array>(parse(nested(512)))
        refuses(nested(513))
        assertIs<FoundationJsonNode.Object>(parse("{\"a\":".repeat(512) + "1" + "}".repeat(512)))
        refuses("{\"a\":".repeat(513) + "1" + "}".repeat(513))
    }

    /** What sits inside a string or a number is only examined when it is read. */
    @Test
    fun stringsAndNumbersAreCheckedWhenTheyAreRead() {
        val lazy = assertIs<FoundationJsonNode.Array>(parse("[\"\\x\", \"raw\ttab\", 01, -, 1.2.3, 1e999, \"\\ud83d\"]")).elements
        assertEquals(7, lazy.size)
        for (node in lazy) {
            when (node) {
                is FoundationJsonNode.Text -> assertFailsWith<FoundationJsonException> { node.value() }
                is FoundationJsonNode.Number -> assertFailsWith<FoundationJsonException> { node.doubleValue() }
                else -> error("unexpected node")
            }
        }
        val invalidUtf8 = byteArrayOf('"'.code.toByte(), 0xC3.toByte(), '"'.code.toByte())
        assertFailsWith<FoundationJsonException> { assertIs<FoundationJsonNode.Text>(FoundationJson.parse(invalidUtf8)).value() }
    }

    @Test
    fun stringEscapes() {
        assertEquals("a/b\"\\\b\u000C\n\r\t", string("\"a\\/b\\\"\\\\\\b\\f\\n\\r\\t\""))
        assertEquals("éé😀\u0000", string("\"\\u00e9\\u00E9\\ud83d\\uDE00\\u0000\""))
        assertEquals("é😀\u007F\u2028", string("\"é😀\u007F\u2028\""))
        assertEquals("", string("\"\""))
        for (text in listOf("\"\\ud83d\"", "\"\\ud83dx\"", "\"\\ud83d\\u0041\"", "\"\\ude00\"", "\"\\u12G4\"", "\"\\U0041\"", "\"\\'\"", "\"\\0\"", "\"a\u0001b\"")) {
            assertFailsWith<FoundationJsonException>(text) { string(text) }
        }
    }

    @Test
    fun numbersAreStrictJsonCorrectlyRoundedAndRepresentable() {
        assertEquals(700000000.25, double("700000000.25"))
        assertEquals(500.0, double("5e2"))
        assertEquals(100.0, double("1E+2"))
        assertEquals(0.1, double("0.1000000000000000055511151231257827021181583404541015625"))
        assertEquals(1.2345678901234568e29, double("123456789012345678901234567890"))
        assertEquals(java.lang.Double.doubleToRawLongBits(-0.0), java.lang.Double.doubleToRawLongBits(double("-0.0")))
        assertEquals(Double.MIN_VALUE, double("5e-324"))
        assertEquals(Double.MIN_VALUE, double("2.5e-324"))
        assertEquals(Double.MAX_VALUE, double("1.7976931348623158e308"))
        assertEquals(0.0, double("0e999"))
        assertEquals(1e5, double("1.0e005"))
        for (text in listOf("1e999", "-1e999", "1.8e308", "1e-999", "2e-324", "01", "-01", "1.", "1.e5", "1e", "1e+", "-", "1.2.3", "1e5e5", "1-1", "0x10")) {
            assertFailsWith<FoundationJsonException>(text) { double(text) }
        }
    }

    @Test
    fun theFirstOfTwoEqualKeysWinsAndEqualIsCanonicalEquivalence() {
        val members = assertIs<FoundationJsonNode.Object>(parse("{\"a\":1,\"a\":2,\"\\u0061\":3,\"é\":4,\"e\\u0301\":5}")).members()
        assertEquals(1.0, assertIs<FoundationJsonNode.Number>(members["a"]).doubleValue())
        assertEquals(4.0, assertIs<FoundationJsonNode.Number>(members["e\u0301"]).doubleValue())
        assertNull(members["b"])
        // One undecodable key spoils the object, because all keys are decoded together.
        assertFailsWith<FoundationJsonException> { assertIs<FoundationJsonNode.Object>(parse("{\"a\":1,\"\\x\":2}")).members() }
    }

    @Test
    fun theEncodingIsDetectedLikeFoundation() {
        fun utf16(text: String, bigEndian: Boolean) = text.toByteArray(if (bigEndian) Charsets.UTF_16BE else Charsets.UTF_16LE)
        fun utf32(text: String, bigEndian: Boolean) = text.toByteArray(charset(if (bigEndian) "UTF-32BE" else "UTF-32LE"))
        val text = "[\"é😀\"]"
        val variants = listOf(
            byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + text.toByteArray(),
            utf16(text, true), utf16(text, false), utf32(text, true), utf32(text, false),
            byteArrayOf(0xFE.toByte(), 0xFF.toByte()) + utf16(text, true),
            byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + utf16(text, false),
            byteArrayOf(0, 0, 0xFE.toByte(), 0xFF.toByte()) + utf32(text, true),
        )
        for (bytes in variants) {
            val element = assertIs<FoundationJsonNode.Array>(FoundationJson.parse(bytes)).elements.single()
            assertEquals("é😀", assertIs<FoundationJsonNode.Text>(element).value())
        }
        // An incomplete code unit at the end is ignored; an unpaired surrogate or a non-scalar is refused.
        assertIs<FoundationJsonNode.Array>(FoundationJson.parse(utf16("[]", false) + byteArrayOf(0x20)))
        assertIs<FoundationJsonNode.Array>(FoundationJson.parse(utf32("[]", true) + byteArrayOf(0x20, 0x20, 0x20)))
        assertFailsWith<FoundationJsonException> {
            FoundationJson.parse(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x5B, 0, 0, 0xD8.toByte(), 0x5D, 0))
        }
        assertFailsWith<FoundationJsonException> {
            FoundationJson.parse(byteArrayOf(0x5B, 0, 0, 0, 0, 0, 0x11, 0, 0x5D, 0, 0, 0))
        }
        // Foundation's table reads FE FF 00 00 as a UTF-32 little-endian mark, and so
        // takes a real one (FF FE 00 00) for UTF-16 followed by a NUL, which is not JSON.
        assertIs<FoundationJsonNode.Array>(FoundationJson.parse(byteArrayOf(0xFE.toByte(), 0xFF.toByte(), 0, 0) + utf32("[]", false)))
        assertFailsWith<FoundationJsonException> {
            FoundationJson.parse(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0, 0) + utf32("[]", false))
        }
    }

    @Test
    fun theWriterSpellsValuesAsFoundationDoes() {
        fun written(value: JsonValue) = String(FoundationJsonWriter.prettyPrinted(value), Charsets.UTF_8)
        assertEquals("[\n\n]", written(JsonValue.Array(emptyList())))
        assertEquals("{\n\n}", written(JsonValue.Object(emptyMap())))
        assertEquals(
            "{\n  \"a\" : [\n    1,\n    null,\n    true\n  ],\n  \"b\" : {\n    \"c\" : [\n\n    ]\n  },\n  \"é\" : false\n}",
            written(
                JsonValue.obj(
                    "é" to JsonValue.of(false),
                    "b" to JsonValue.obj("c" to JsonValue.array()),
                    "a" to JsonValue.array(JsonValue.of(1), JsonValue.Null, JsonValue.of(true)),
                ),
            ),
        )
        // Keys sort by scalar value: U+FF21 before U+1F600, which UTF-16 order would reverse.
        assertEquals("{\n  \"Z\" : 1,\n  \"a\" : 2,\n  \"\uFF21\" : 3,\n  \"\uD83D\uDE00\" : 4\n}", written(
            JsonValue.obj("\uD83D\uDE00" to JsonValue.of(4), "a" to JsonValue.of(2), "\uFF21" to JsonValue.of(3), "Z" to JsonValue.of(1)),
        ))

        val numbers = listOf(
            700000000.0 to "700000000", 700000000.25 to "700000000.25", 1e16 to "1e+16", 1e-5 to "1e-05", -0.0 to "-0",
            0.0 to "0", 0.1 to "0.1", 9007199254740992.0 to "9007199254740992", 5e-324 to "5e-324",
            1.7976931348623157e308 to "1.7976931348623157e+308", 100.0 to "100", -1.5 to "-1.5",
        )
        for ((value, spelling) in numbers) assertEquals(spelling, written(JsonValue.of(value)))
        assertEquals("-9223372036854775808", written(JsonValue.of(Long.MIN_VALUE)))
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertFailsWith<FoundationJsonWriter.NonFiniteNumber> { written(JsonValue.of(value)) }
        }

        val controls = (0 until 0x20).joinToString("") { it.toChar().toString() }
        assertEquals(
            "\"\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007\\b\\t\\n\\u000b\\f\\r\\u000e\\u000f" +
                "\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017\\u0018\\u0019\\u001a\\u001b\\u001c\\u001d\\u001e\\u001f" +
                " \\/\\\\\\\"\u007F\u0080\u2028é😀<>&'\"",
            written(JsonValue.of("$controls /\\\"\u007F\u0080\u2028é😀<>&'")),
        )
        assertEquals("\"a\\/b\"", written(JsonValue.Utf8("a/b".toByteArray())))
    }
}
