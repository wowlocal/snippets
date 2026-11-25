package com.khm.snippets.core.canonical

import com.khm.snippets.core.crypto.SeededRandom
import com.khm.snippets.core.crypto.SwiftReference
import com.khm.snippets.core.crypto.array
import com.khm.snippets.core.crypto.hex
import com.khm.snippets.core.crypto.string
import com.khm.snippets.core.crypto.unhex
import com.khm.snippets.core.crypto.utf8
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

private fun obj(vararg members: Pair<String, JsonValue>): JsonValue = JsonValue.obj(*members)
private fun str(value: String): JsonValue = JsonValue.Text(value)
private fun int(value: Long): JsonValue = JsonValue.Integer(value)
private fun real(value: Double): JsonValue = JsonValue.Real(value)
private fun parse(json: String): JsonValue = CanonicalJson.parse(utf8(json))

/**
 * `Tests/Core/WireTests.swift`, suite 1 "Canonical JSON". Test names are the Swift ones;
 * `CanonicalJSON.data` / `.string` / `.value` are `encode` / `encodeToString` / `parse` here.
 */
class CanonicalJsonTest {

    /** The whole reason the type exists: the bytes may not depend on the order members were inserted in. */
    @Test fun objectBytesAreIdenticalNoMatterWhatOrderTheKeysWereInserted() {
        val members = listOf(
            "zeta" to int(1), "alpha" to str("one"), "Mid" to JsonValue.Bool(true),
            "nested" to obj("b" to int(2), "a" to int(3)),
            "ärger" to JsonValue.Null, "m" to JsonValue.array(int(1), int(2), int(3)), "0" to real(0.5),
        )

        val random = SeededRandom(0xC0FF_EE01)
        val produced = HashSet<String>()
        repeat(64) {
            val shuffled = LinkedHashMap<String, JsonValue>()
            for ((key, value) in random.shuffled(members)) shuffled[key] = value
            produced.add(CanonicalJson.encode(JsonValue.Object(shuffled)).hex())
        }

        assertEquals(1, produced.size, "insertion order leaked into the canonical bytes")
    }

    /** This string was produced by a different run of a different binary, in a different language. */
    @Test fun theByteLayoutIsPinnedToALiteralRatherThanToWhateverThisRunProduces() {
        val value = obj("b" to int(2), "a" to str("x"), "ä" to JsonValue.Bool(true), "A" to JsonValue.Null)

        // Sorted by UTF-8 bytes: "A" (0x41), "a" (0x61), "b" (0x62), "ä" (0xC3 0xA4).
        assertEquals("""{"A":null,"a":"x","b":2,"ä":true}""", CanonicalJson.encodeToString(value))
    }

    /**
     * UTF-8 byte order is code-point order, not UTF-16 order. Surrogates (D800 to DFFF) sort
     * below U+E000, so `String.compareTo` would put the supplementary-plane key first.
     */
    @Test fun keysSortByUTF8BytesAndNotByUTF16CodeUnits() {
        val encoded = CanonicalJson.encode(obj("\uFFFD" to int(1), "\uD800\uDC00" to int(2)))
        val text = String(encoded, Charsets.UTF_8)

        assertEquals("{\"\uFFFD\":1,\"\uD800\uDC00\":2}", text)
        assertTrue(
            encoded.indexOf(0xEF.toByte()) < encoded.indexOf(0xF0.toByte()),
            "U+FFFD must come first; UTF-16 ordering would have put U+10000 first",
        )
        // The trap, stated: Kotlin's own string order disagrees.
        assertTrue("\uD800\uDC00" < "\uFFFD")
    }

    @Test fun ordinaryKeysSortByTheirBytesToo() {
        val text = CanonicalJson.encodeToString(obj("ä" to int(1), "b" to int(2), "a" to int(3), "Z" to int(4)))
        assertEquals("""{"Z":4,"a":3,"b":2,"ä":1}""", text)
    }

    @Test fun stringsEscapeOnlyWhatJSONRequires() {
        val text = CanonicalJson.encodeToString(
            str("quote\" back\\ slash/ tab\t nl\n cr\r bs\u0008 ff\u000c nul\u0000 unit\u001f é 😀"),
        )

        val expected = """"quote\" back\\ slash/ tab\t nl\n cr\r bs\b ff\f """ + """nul\u0000 unit\u001f é 😀""""
        assertEquals(expected, text)
    }

    /** `.string` and `.utf8` are the same JSON value. */
    @Test fun aStringAndItsBytesProduceIdenticalOutputAndCompareEqual() {
        val value = "Best,\nMike \u2014 ✍\uFE0F"
        assertEquals<JsonValue>(JsonValue.Text(value), JsonValue.Utf8(utf8(value)))
        assertEquals<JsonValue>(JsonValue.Utf8(utf8(value)), JsonValue.Text(value))
        assertEquals(JsonValue.Text(value).hashCode(), JsonValue.Utf8(utf8(value)).hashCode())
        assertContentEquals(CanonicalJson.encode(JsonValue.Text(value)), CanonicalJson.encode(JsonValue.Utf8(utf8(value))))
    }

    /** `Date` is a double; a timestamp that shifted by one ulp per sync would rewrite the library forever. */
    @Test fun everyDoubleRoundTripsExactlyThroughEmitAndParse() {
        val epoch = 1_785_312_000.0 - 978_307_200.0     // the Swift suite's fixed epoch, as seconds since 2001
        val numbers = listOf(
            0.0, -0.0, 1.0, -1.0, 0.5, 1e-300, 1e300, java.lang.Double.MIN_NORMAL, Double.MIN_VALUE,
            Double.MAX_VALUE, 795_312_000.123_456_78, epoch, epoch + 0.000_000_123,
        )

        for (number in numbers) {
            val data = CanonicalJson.encode(real(number))
            val parsed = CanonicalJson.parse(data)
            assertEquals(number.toRawBits(), parsed.doubleOrNull?.toRawBits(), "lost bits on $number")
        }
    }

    @Test fun integersAndWholeDoublesStayDistinguishable() {
        assertEquals("1", CanonicalJson.encodeToString(int(1)))
        assertEquals("1.0", CanonicalJson.encodeToString(real(1.0)))
        assertEquals(int(1), parse("1"))
        assertEquals(real(1.0), parse("1.0"))
        assertNotEquals(parse("1"), parse("1.0"))
    }

    @Test fun nonFiniteNumbersAreRefusedRatherThanEmittedAsSomethingUnparseable() {
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { CanonicalJson.encode(real(Double.NaN)) }
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { CanonicalJson.encode(real(Double.POSITIVE_INFINITY)) }
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { CanonicalJson.encode(real(Double.NEGATIVE_INFINITY)) }
    }

    @Test fun duplicateObjectKeysAreAParseErrorRatherThanALastOneWinsMerge() {
        assertEquals("a", assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("""{"a":1,"a":2}""") }.key)
    }

    /**
     * Two spellings of one character are distinct byte sequences but a single Swift `String`
     * key. A Kotlin map would happily hold both, so the parser has to refuse them itself.
     */
    @Test fun canonicallyEquivalentKeysCountAsDuplicatesRatherThanBeingFoldedTogether() {
        // U+00E9, then e + U+0301
        val failure = assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("{\"\u00E9\":1,\"e\u0301\":2}") }
        assertEquals("e\u0301", failure.key)
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("{\"e\u0301\":1,\"\u00E9\":2}") }
    }

    @Test fun trailingBytesAfterTheTopLevelValueAreRejected() {
        assertEquals(8, assertFailsWith<CanonicalJson.Failure.TrailingBytes> { parse("""{"a":1} {"b":2}""") }.offset)
    }

    @Test fun nestingDeeperThanTheLimitIsRefusedRatherThanOverflowingTheStack() {
        val deep = "[".repeat(200) + "]".repeat(200)
        assertFailsWith<CanonicalJson.Failure.TooDeep> { parse(deep) }
    }

    @Test fun malformedJSONNumbersAreRejectedRatherThanCoerced() {
        for (bad in listOf("01", "+1", ".5", "1.", "1e", "NaN", "Infinity", "-")) {
            assertFailsWith<CanonicalJson.Failure.UnexpectedByte>("$bad parsed") { parse(bad) }
        }
    }

    @Test fun surrogatePairsDecodeToOneScalarAndLoneSurrogatesAreRejected() {
        val parsed = parse("\"\\ud83d\\ude00\"")
        assertEquals("😀", parsed.textOrNull)
        assertEquals("f09f9880", parsed.utf8OrNull!!.hex())

        assertFailsWith<CanonicalJson.Failure.UnexpectedByte> { parse("\"\\ud83d\"") }
    }

    /** Over-long encodings are the classic way to smuggle a `"` past an escaper. */
    @Test fun invalidUTF8IsRefusedRatherThanEmittedAsBrokenJSON() {
        assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { CanonicalJson.encode(JsonValue.Utf8(unhex("c022"))) }
        assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { CanonicalJson.encode(JsonValue.Utf8(unhex("eda080"))) }  // lone surrogate
    }

    @Test fun anEmptyObjectAndAnEmptyArrayHaveTheObviousSpelling() {
        assertEquals("{}", CanonicalJson.encodeToString(obj()))
        assertEquals("[]", CanonicalJson.encodeToString(JsonValue.array()))
    }

    // snippets-linux/src/canonical.rs

    /** `small_wire_json_does_not_allocate_or_erase_a_maximum_size_buffer`, for its round trip and literal prefix. */
    @Test fun smallWireJsonRoundTripsWithItsEscapesExpanded() {
        val input = obj("content" to str("Public small canonical fixture"), "escaped" to str("\n".repeat(300)))
        val encoded = CanonicalJson.encode(input)
        assertEquals(input, CanonicalJson.parse(encoded))
        assertTrue(String(encoded, Charsets.UTF_8).startsWith("{\"content\":\"Public small canonical fixture\",\"escaped\":\"\\n"))
        assertEquals("{\"content\":\"Public small canonical fixture\",\"escaped\":\"".length + 600 + 2, encoded.size)
    }

    /**
     * `resized_output_keeps_the_exact_wire_ceiling_including_escape_expansion`. The Rust
     * emitter enforces the 674 815-byte wire ceiling itself. Swift's `CanonicalJSON` has no
     * ceiling (the merge applies it to what it is about to seal), so this pins the sizes without a refusal.
     */
    @Test fun outputAtTheWireCeilingIsExactIncludingEscapeExpansion() {
        val ceiling = 674_815
        val encoded = CanonicalJson.encode(str("x".repeat(ceiling - 2)))
        assertEquals(ceiling, encoded.size)
        assertEquals(str("x".repeat(ceiling - 2)), CanonicalJson.parse(encoded))
        // Each NUL becomes six bytes.
        assertEquals(6 * 1000 + 2, CanonicalJson.encode(str("\u0000".repeat(1000))).size)
        assertEquals(ceiling + 1, CanonicalJson.encode(str("x".repeat(ceiling - 1))).size)
    }

    /** `escaping_key_order_duplicates_and_depth_match_the_contract` */
    @Test fun escapingKeyOrderDuplicatesAndDepthMatchTheContract() {
        val raw = "{\"\uD800\uDC00\":1,\"\uE000\":2,\"ascii\":\"a/β\\u0001\\n\\t\\b\\f\\r\\\\\\\"\"}"
        val encoded = CanonicalJson.encode(parse(raw))
        val text = String(encoded, Charsets.UTF_8)
        assertTrue(text.startsWith("{\"ascii\":"))
        assertTrue(text.indexOf('\uE000') < text.indexOf("\uD800\uDC00") && text.contains("a/β\\u0001"))
        assertEquals("{\"ascii\":\"a/β\\u0001\\n\\t\\b\\f\\r\\\\\\\"\",\"\uE000\":2,\"\uD800\uDC00\":1}", text)

        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("{\"a\":1,\"a\":2}") }
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("{\"\u00E9\":1,\"e\u0301\":2}") }
        assertFailsWith<CanonicalJson.Failure.TrailingBytes> { parse("{\"a\":1} null") }
        assertFailsWith<CanonicalJson.Failure.UnexpectedByte> { parse("\"\\ud800\"") }
        assertFailsWith<CanonicalJson.Failure.TooDeep> { parse("[".repeat(33) + "0" + "]".repeat(33)) }
    }

    /**
     * Where the Rust wire parser is stricter than Swift, and Swift is followed: an integer
     * beyond `Int64` becomes a double and an out-of-range exponent becomes infinity (Rust
     * refuses all three; its `parse_lenient_numbers` is the Swift behaviour). Neither value
     * survives a round trip unnoticed: the first re-emits in another spelling, so an envelope
     * hash over it cannot verify, and the second cannot be emitted at all.
     */
    @Test fun numbersBeyondTheRepresentableRangeFollowSwiftNotRust() {
        assertEquals(real(9.223372036854775807e18), parse("9223372036854775808"))
        assertEquals("9.223372036854776e+18", CanonicalJson.encodeToString(parse("9223372036854775808")))
        assertEquals(real(1.8446744073709552e20), parse("184467440737095516160"))
        assertEquals(real(-9.223372036854775807e18), parse("-9223372036854775809"))

        val infinite = parse("1e400")
        assertEquals(Double.POSITIVE_INFINITY, infinite.doubleOrNull)
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { CanonicalJson.encode(infinite) }
        assertEquals(Double.NEGATIVE_INFINITY, parse("-1e400").doubleOrNull)
        assertEquals(0.0, parse("1e-400").doubleOrNull)
    }

    /** `integer_negative_zero_unicode_and_hostile_lexemes_keep_the_frozen_grammar` */
    @Test fun integerNegativeZeroUnicodeAndHostileLexemesKeepTheFrozenGrammar() {
        assertEquals(int(0), parse("-0"))
        assertEquals((-0.0).toRawBits(), (parse("-0.0") as JsonValue.Real).value.toRawBits())
        assertEquals(Long.MIN_VALUE, parse("-9223372036854775808").longOrNull)
        assertEquals(Long.MAX_VALUE, parse("9223372036854775807").longOrNull)

        val escapes = mapOf(
            "\"\\ud800\\udc00\"" to "\uD800\uDC00",
            "\"\\udbff\\udfff\"" to "\uDBFF\uDFFF",
            "\"\\u0065\\u0301\"" to "e\u0301",
            "\"\\/\\b\\f\\n\\r\\t\\u0000\\u001f\"" to "/\b\u000c\n\r\t\u0000\u001f",
        )
        for ((escaped, reference) in escapes) assertEquals(reference, parse(escaped).textOrNull, escaped)

        for (raw in listOf(
            "[null,]", "{\"a\":1,}", "[01]", "[1.e0]", "1e+-1", "-.1", "+1", "[truefalse]",
            "\"unterminated\\", "\"\\udc00\"", "\"\\ud800\\u0041\"", "\"\\u12\"", "\"\\x00\"",
        )) {
            assertFailsWith<CanonicalJson.Failure>(raw) { parse(raw) }
        }
        for (raw in listOf("22c0af22", "22eda08022", "220022", "ff")) {
            assertFailsWith<CanonicalJson.Failure>(raw) { CanonicalJson.parse(unhex(raw)) }
        }
        CanonicalJson.parse(utf8("[".repeat(32) + "0" + "]".repeat(32)))
        // Rust refuses more than 100 000 nodes; Swift counts none, and neither does this.
        assertEquals(100_001, CanonicalJson.parse(utf8("[" + "null,".repeat(100_000) + "null]")).arrayOrNull!!.size)
    }

    // Swift itself

    /**
     * `CanonicalJSON.value` followed by `CanonicalJSON.data`, as Swift ran them on 150
     * inputs: every grammar corner, every escape, surrogates, invalid UTF-8, duplicate and
     * canonically equivalent keys, number limits, depth 32 against 33. For each: the parsed
     * value (with its integer/double distinction and exact bits), the re-emitted bytes, or
     * the exact failure with its byte offset.
     */
    @Test fun parsingAndReemittingMatchSwiftOnEveryReferenceInput() {
        val cases = SwiftReference.json.array("parses")
        assertEquals(150, cases.size)
        var accepted = 0
        for (case in cases) {
            val input = unhex(case.string("input"))
            val actual = try {
                val value = CanonicalJson.parse(input)
                accepted += 1
                val reemitted = try {
                    CanonicalJson.encode(value).hex()
                } catch (failure: CanonicalJson.Failure) {
                    "!" + failure.message
                }
                "ok " + describe(value) + " => " + reemitted
            } catch (failure: CanonicalJson.Failure) {
                when (failure) {
                    is CanonicalJson.Failure.NonFiniteNumber -> "nonFiniteNumber"
                    is CanonicalJson.Failure.InvalidUtf8 -> "invalidUTF8"
                    is CanonicalJson.Failure.UnexpectedEnd -> "unexpectedEnd"
                    is CanonicalJson.Failure.UnexpectedByte -> "unexpectedByte:${failure.offset}"
                    is CanonicalJson.Failure.DuplicateKey -> "duplicateKey:" + utf8(failure.key).hex()
                    is CanonicalJson.Failure.TrailingBytes -> "trailingBytes:${failure.offset}"
                    is CanonicalJson.Failure.TooDeep -> "tooDeep"
                }
            }
            assertEquals(case.string("result"), actual, "input ${case.string("input")}")
        }
        assertEquals(cases.count { it.string("result").startsWith("ok ") }, accepted)
        assertTrue(accepted > 40, "$accepted accepted")
    }

    private fun describe(value: JsonValue): String = when (value) {
        JsonValue.Null -> "null"
        is JsonValue.Bool -> "bool(${value.value})"
        is JsonValue.Integer -> "int(${value.value})"
        is JsonValue.Real -> "double(${java.lang.Long.toHexString(value.value.toRawBits())})"
        is JsonValue.Text -> "string(${utf8(value.value).hex()})"
        is JsonValue.Utf8 -> "utf8(${value.bytes.hex()})"
        is JsonValue.Array -> value.elements.joinToString(",", "[", "]") { describe(it) }
        is JsonValue.Object -> value.members.entries
            .sortedWith { a, b -> compareCodePoints(a.key, b.key) }
            .joinToString(",", "{", "}") { utf8(it.key).hex() + ":" + describe(it.value) }
    }

    /** Code-point order, which is UTF-8 byte order, computed without the emitter under test. */
    private fun compareCodePoints(first: String, second: String): Int {
        val a = first.codePoints().toArray()
        val b = second.codePoints().toArray()
        for (index in 0 until minOf(a.size, b.size)) if (a[index] != b[index]) return a[index].compareTo(b[index])
        return a.size.compareTo(b.size)
    }

    /**
     * `CanonicalJSON.data` from Swift for one value holding every C0 control, `"`, `\`, `/`,
     * U+007F, U+0080, U+2028, U+2029, U+FFFD, the first and last astral scalars, the integer
     * limits, twelve doubles, a byte-string, empty containers and keys chosen to separate
     * byte order from every other order.
     */
    @Test fun emittingAValueThatExercisesEveryRuleMatchesSwift() {
        val escapes = (0..0x1f).joinToString("") { it.toChar().toString() } +
            " \"\\/\u007f\u0080\u2028\u2029\uFFFD\uD800\uDC00\uDBFF\uDFFF\u00E9"
        val value = obj(
            "escapes" to str(escapes),
            "ints" to JsonValue.array(int(0), int(-1), int(Long.MAX_VALUE), int(Long.MIN_VALUE), int(600000)),
            "doubles" to JsonValue.array(
                real(0.0), real(-0.0), real(1.0), real(0.1), real(1e-5), real(1e16), real(812578800.123456),
                real(5e-324), real(1.7976931348623157e308), real(9007199254740992.0), real(9007199254740994.0),
                real(-123456.789e-10),
            ),
            "nested" to obj(
                "\uD800\uDC00" to JsonValue.Null, "\uFFFD" to JsonValue.Bool(false), "\uE000" to JsonValue.Bool(true),
                "" to JsonValue.array(), "a\u0000b" to obj(), "\u00E9" to int(1), "z" to JsonValue.Utf8(utf8("bytes ✓")),
            ),
            "A" to JsonValue.Null, "a" to JsonValue.Null, "Z" to JsonValue.Null, "~" to JsonValue.Null,
            "\u007f" to JsonValue.Null, "\"" to JsonValue.Null, "\\" to JsonValue.Null, "/" to JsonValue.Null,
        )
        val expected = SwiftReference.json.string("canonicalBig")
        assertEquals(expected, CanonicalJson.encodeToString(value))
        // And it parses back to an equal value whose re-emission is the same bytes.
        val parsed = CanonicalJson.parse(utf8(expected))
        assertEquals(value, parsed)
        assertEquals(expected, CanonicalJson.encodeToString(parsed))
    }

    /**
     * The parser hands number tokens to the platform's decimal-to-double conversion, as
     * Swift hands them to its own. These are the literals where a conversion that is not
     * correctly rounded goes wrong: the edges of the subnormal range, the largest finite
     * value, exact half-way cases (short and 54 digits long), and overflow. The expected bit
     * patterns were printed by Swift 6.4's `Double(String)`.
     */
    @Test fun hardToRoundDecimalsParseToTheSameDoubleAsSwift() {
        val expectations: List<Pair<String, Long>> = listOf(
            "2.2250738585072011e-308" to 0x000fffffffffffff,
            "2.2250738585072012e-308" to 0x0010000000000000,
            "2.2250738585072014e-308" to 0x0010000000000000,
            "2.225073858507201e-308" to 0x000fffffffffffff,
            "1.7976931348623157e308" to 0x7fefffffffffffff,
            "1.7976931348623158e308" to 0x7fefffffffffffff,
            "1.7976931348623159e308" to 0x7ff0000000000000,
            "1.797693134862315807e308" to 0x7fefffffffffffff,
            "1.797693134862315808e308" to 0x7ff0000000000000,
            "9007199254740993.0" to 0x4340000000000000,
            "9007199254740995.0" to 0x4340000000000002,
            "9007199254740992.5" to 0x4340000000000000,
            "9007199254740993.000000000000000000000001" to 0x4340000000000001,
            "2.4703282292062327e-324" to 0x0000000000000000,
            "2.4703282292062328e-324" to 0x0000000000000001,
            "2.5e-324" to 0x0000000000000001,
            "2.4e-324" to 0x0000000000000000,
            "4.9e-324" to 0x0000000000000001,
            "4.94065645841246544e-324" to 0x0000000000000001,
            "7.4e-324" to 0x0000000000000001,
            "7.5e-324" to 0x0000000000000002,
            "1.00000000000000011102230246251565404236316680908203125" to 0x3ff0000000000000,
            "1.000000000000000111022302462515654042363166809082031250000001" to 0x3ff0000000000001,
            "1.00000000000000011102230246251565404236316680908203124999999" to 0x3ff0000000000000,
            "0.1" to 0x3fb999999999999a,
            "0.30000000000000004" to 0x3fd3333333333334,
            "1e23" to 0x44b52d02c7e14af6,
            "8.5e22" to 0x44b1ffdbf6b2b2eb,
            "9.5e22" to 0x44b41df5d77c6d9d,
            "123456789012345678901234567890.0e-10" to 0x43e56a95319d63e1,
            "0.000000000000000000000000000000000000000000001e45" to 0x3ff0000000000000,
            "1e0" to 0x3ff0000000000000,
            "1E+0" to 0x3ff0000000000000,
            "-1e-0" to -0x4010000000000000,                       // 0xbff0000000000000
            "1.0e00012" to 0x426d1a94a2000000,
            "0." + "0".repeat(400) + "1" to 0x0000000000000000,
            "1" + "0".repeat(400) to 0x7ff0000000000000,           // an integer token beyond Int64, then beyond Double
            "1" + "0".repeat(400) + ".0" to 0x7ff0000000000000,
            "0.5e-323" to 0x0000000000000001,
            "1e-323" to 0x0000000000000002,
            "1e-324" to 0x0000000000000000,
            "1e-325" to 0x0000000000000000,
            "5e-324" to 0x0000000000000001,
            "3e-324" to 0x0000000000000001,
            "1.5e-323" to 0x0000000000000003,
            "6.0221409e+23" to 0x44dfe185d6c70058,
            "3.141592653589793238462643383279502884197169399375105820974944" to 0x400921fb54442d18,
            "0.1e1" to 0x3ff0000000000000,
            "100e-2" to 0x3ff0000000000000,
            "4.35" to 0x4011666666666666,
            "0.000001" to 0x3eb0c6f7a0b5ed8d,
            "1e308" to 0x7fe1ccf385ebc8a0,
            "1e309" to 0x7ff0000000000000,
            "-1e309" to -0x10000000000000,                        // 0xfff0000000000000
            "9223372036854775807.0" to 0x43e0000000000000,
            "9223372036854775808.0" to 0x43e0000000000000,
            "18446744073709551616" to 0x43f0000000000000,
            "-18446744073709551616" to -0x3c10000000000000,       // 0xc3f0000000000000
            "99999999999999999999" to 0x4415af1d78b58c40,
            "12345678901234567890" to 0x43e56a95319d63e1,
        )
        for ((token, bits) in expectations) {
            val parsed = parse(token)
            assertTrue(parsed is JsonValue.Real, "$token parsed as ${parsed::class.simpleName}")
            assertEquals(bits, parsed.value.toRawBits(), token.take(40))
        }
        // The largest integer token is still an integer, not the double next to it.
        assertEquals(int(Long.MAX_VALUE), parse("9223372036854775807"))
    }

    // Added

    /** The escape table, one byte at a time, including the two that look like they might need escaping and do not. */
    @Test fun theEscapeTableIsExact() {
        val short = mapOf(0x08 to "\\b", 0x09 to "\\t", 0x0A to "\\n", 0x0C to "\\f", 0x0D to "\\r")
        for (byte in 0..0x1f) {
            val expected = short[byte] ?: "\\u%04x".format(byte)
            assertEquals("\"$expected\"", CanonicalJson.encodeToString(JsonValue.Utf8(byteArrayOf(byte.toByte()))), "byte $byte")
        }
        assertEquals("\"\\u000b\"", CanonicalJson.encodeToString(str("\u000b")))   // lowercase hex
        assertEquals("\"\\\"\"", CanonicalJson.encodeToString(str("\"")))
        assertEquals("\"\\\\\"", CanonicalJson.encodeToString(str("\\")))
        for (raw in listOf("/", "\u007f", "\u0080", "\u2028", "\u2029", "<", ">", "&", "'", "é", "😀")) {
            assertContentEquals(utf8("\"$raw\""), CanonicalJson.encode(str(raw)), raw)
        }
        // Keys go through the same escaper.
        assertEquals("{\"a\\nb\\u0000\":1}", CanonicalJson.encodeToString(obj("a\nb\u0000" to int(1))))
    }

    @Test fun integersPrintAsPlainDecimal() {
        for (value in listOf(0L, -1L, 7L, 600_000L, Long.MAX_VALUE, Long.MIN_VALUE)) {
            assertEquals(value.toString(), CanonicalJson.encodeToString(int(value)))
            assertEquals(int(value), parse(value.toString()))
        }
        assertEquals("[true,false,null]", CanonicalJson.encodeToString(JsonValue.array(JsonValue.Bool(true), JsonValue.Bool(false), JsonValue.Null)))
    }

    /** Random keys from every plane: the emitted order is code-point order whatever `String.compareTo` thinks. */
    @Test fun keyOrderIsCodePointOrderForRandomKeysFromEveryPlane() {
        val random = SeededRandom(0x50B7)
        val pool = intArrayOf(0x00, 0x1f, 0x20, 0x22, 0x41, 0x5c, 0x61, 0x7f, 0x80, 0xe9, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xfffd, 0xffff, 0x10000, 0x1f600, 0x10ffff)
        repeat(50) {
            val keys = HashSet<String>()
            while (keys.size < 30) {
                val length = 1 + java.lang.Long.remainderUnsigned(random.next(), 4).toInt()
                keys.add(buildString { repeat(length) { appendCodePoint(pool[java.lang.Long.remainderUnsigned(random.next(), pool.size.toLong()).toInt()]) } })
            }
            val value = JsonValue.Object(keys.associateWith { JsonValue.Null })
            val parsed = CanonicalJson.parse(CanonicalJson.encode(value)) as JsonValue.Object
            val emittedOrder = parsed.members.keys.toList()
            assertEquals(keys.sortedWith { a, b -> compareCodePoints(a, b) }, emittedOrder)
            assertEquals(value, parsed)
        }
    }

    /**
     * A Swift dictionary cannot hold two canonically equivalent keys, so Swift's emitter never
     * sees them. A Kotlin map can; writing both would produce bytes no Swift device accepts.
     */
    @Test fun theEmitterRefusesAnObjectASwiftDictionaryCouldNotHold() {
        val value = obj("\u00E9" to int(1), "e\u0301" to int(2))
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { CanonicalJson.encode(value) }
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { CanonicalJson.encode(obj("\u212B" to int(1), "\u00C5" to int(2))) }
        // Different characters that merely look alike are different keys.
        assertEquals("{\"A\":1,\"\u0391\":2}", CanonicalJson.encodeToString(obj("A" to int(1), "\u0391" to int(2))))
        // A key is emitted in the spelling it was given, never normalised.
        assertContentEquals(utf8("{\"e\u0301\":1}"), CanonicalJson.encode(obj("e\u0301" to int(1))))
    }

    /** A Kotlin `String` can hold what a Swift `String` cannot: an unpaired surrogate has no UTF-8. */
    @Test fun textThatIsNotWellFormedUnicodeCannotBeEmitted() {
        assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { CanonicalJson.encode(str("a\uD83D")) }
        assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { CanonicalJson.encode(obj("\uDE00" to int(1))) }
    }

    /** The validator's own boundaries: the shortest and longest legal sequence of each length. */
    @Test fun theUTF8ValidatorAcceptsExactlyTheLegalSequences() {
        for (valid in listOf("", "00", "7f", "c280", "dfbf", "e0a080", "ed9fbf", "ee8080", "efbfbf", "f0908080", "f48fbfbf")) {
            assertTrue(CanonicalJson.isValidUtf8(unhex(valid)), valid)
        }
        for (invalid in listOf(
            "80", "bf", "c0", "c080", "c1bf", "c2", "c27f", "c2c0", "e08080", "e09fbf", "e0a0", "eda080", "edbfbf",
            "f0808080", "f08fbfbf", "f09080", "f4908080", "f5808080", "f8888080", "ff", "fe", "41c2",
        )) {
            assertTrue(!CanonicalJson.isValidUtf8(unhex(invalid)), invalid)
        }
    }

    @Test fun whitespaceIsOnlySpaceTabLineFeedAndCarriageReturn() {
        assertEquals(obj("a" to JsonValue.array(int(1), int(2))), parse(" \t\r\n{ \"a\" : [ 1 , 2 ] } \n"))
        for (other in listOf("\u000b", "\u000c", "\u00a0", "\u2028", "\ufeff")) {
            assertFailsWith<CanonicalJson.Failure>("U+%04X".format(other[0].code)) { parse("${other}1") }
            assertFailsWith<CanonicalJson.Failure> { parse("1$other") }
        }
    }

    /** Depth counts containers from zero: 33 nested arrays may hold nothing, and may not hold a value. */
    @Test fun theDepthLimitIsExactlyThirtyTwoLevelsBelowTheTop() {
        assertEquals(32, CanonicalJson.MAXIMUM_DEPTH)
        parse("[".repeat(32) + "0" + "]".repeat(32))
        parse("[".repeat(33) + "]".repeat(33))
        assertFailsWith<CanonicalJson.Failure.TooDeep> { parse("[".repeat(33) + "0" + "]".repeat(33)) }
        assertFailsWith<CanonicalJson.Failure.TooDeep> { parse("[".repeat(34) + "]".repeat(34)) }
        parse("{\"a\":".repeat(32) + "1" + "}".repeat(32))
        assertFailsWith<CanonicalJson.Failure.TooDeep> { parse("{\"a\":".repeat(33) + "1" + "}".repeat(33)) }
        // Depth is judged before the input is, so 100 000 unclosed brackets do not recurse.
        assertFailsWith<CanonicalJson.Failure.TooDeep> { parse("[".repeat(100_000)) }
    }

    /** The same key under different parents is not a duplicate; the same key twice in one object is, wherever it sits. */
    @Test fun duplicatesAreJudgedPerObject() {
        parse("""{"a":{"a":1},"b":{"a":2}}""")
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("""{"x":{"a":1,"b":2,"a":3}}""") }
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("""[{"a":1,"a":1}]""") }
        // An escaped spelling of a key is the same key.
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("{\"a\":1,\"\\u0061\":2}") }
        assertFailsWith<CanonicalJson.Failure.DuplicateKey> { parse("{\"\\u00e9\":1,\"e\\u0301\":2}") }
        // Case and compatibility variants are different keys.
        parse("{\"a\":1,\"A\":2,\"\uFF41\":3}")   // fullwidth a
    }

    /** Every parsed string is bytes, so a secret can be read out of a blob without becoming a `String`. */
    @Test fun parsedStringsAreBytesAndKeepInputOrder() {
        val parsed = parse("""{"z":"zed","a":["x",{"k":"v"}]}""") as JsonValue.Object
        assertEquals(listOf("z", "a"), parsed.members.keys.toList())
        assertTrue(parsed["z"] is JsonValue.Utf8)
        assertTrue(parsed["a"]!!.arrayOrNull!![0] is JsonValue.Utf8)
        assertEquals("""{"a":["x",{"k":"v"}],"z":"zed"}""", CanonicalJson.encodeToString(parsed))
    }

    /** Output that grows past its first buffer many times over is still exact. */
    @Test fun aLargeValueIsEmittedIntact() {
        val random = SeededRandom(0xB16)
        val elements = List(5_000) { index ->
            obj("id" to int(index.toLong()), "body" to JsonValue.Utf8(utf8("payload ${random.next()} ✓\n")), "at" to real(index + 0.25))
        }
        val value = JsonValue.Array(elements)
        val encoded = CanonicalJson.encode(value)
        assertTrue(encoded.size > 200_000)
        assertEquals(value, CanonicalJson.parse(encoded))
        assertContentEquals(encoded, CanonicalJson.encode(CanonicalJson.parse(encoded)))
    }
}
