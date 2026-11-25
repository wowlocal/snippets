package com.khm.snippets.core.canonical

import com.khm.snippets.core.crypto.hex
import com.khm.snippets.core.crypto.unhex
import com.khm.snippets.core.crypto.utf8
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * `Tests/Core/VaultDocumentTests.swift`, suite "JSONValue" (the passthrough fidelity a bag
 * of unknown fields relies on), and the conveniences of `CanonicalJSON.Value`.
 */
class JsonValueTest {

    private fun parse(json: String): JsonValue = CanonicalJson.parse(utf8(json))

    // VaultDocumentTests.JSONValueTests

    /** `true` must not become `1`, and `600000` must not become `600000.0`: both would rewrite somebody else's field. */
    @Test fun scalarsKeepTheirJSONType() {
        val json = """{"t": true, "f": false, "i": 600000, "d": 12.5, "s": "1", "n": null}"""
        val decoded = parse(json) as JsonValue.Object

        assertEquals<JsonValue?>(JsonValue.Bool(true), decoded["t"])
        assertEquals<JsonValue?>(JsonValue.Bool(false), decoded["f"])
        assertEquals<JsonValue?>(JsonValue.Integer(600_000), decoded["i"])
        assertEquals<JsonValue?>(JsonValue.Real(12.5), decoded["d"])
        assertEquals<JsonValue?>(JsonValue.Text("1"), decoded["s"])
        assertEquals<JsonValue?>(JsonValue.Null, decoded["n"])

        assertEquals("""{"d":12.5,"f":false,"i":600000,"n":null,"s":"1","t":true}""", CanonicalJson.encodeToString(decoded))
    }

    @Test fun nestingAndEmptyContainersSurvive() {
        val json = """{"a":[],"b":{},"c":[[],[{"d":[null,{"e":1}]}]]}"""
        assertEquals(json, CanonicalJson.encodeToString(parse(json)))
    }

    // Added: what "lossless" has to mean for a passthrough bag.

    /**
     * Swift's `Codable` `JSONValue` admits one loss: `1.0` comes back as `1`. This model
     * does not have it, so a foreign field written as `1.0` stays a double.
     */
    @Test fun aWholeDoubleStaysADouble() {
        val decoded = parse("""{"whole":1.0,"int":1,"exp":1e2,"neg":-0.0}""") as JsonValue.Object
        assertEquals<JsonValue?>(JsonValue.Real(1.0), decoded["whole"])
        assertEquals<JsonValue?>(JsonValue.Integer(1), decoded["int"])
        assertEquals<JsonValue?>(JsonValue.Real(100.0), decoded["exp"])
        assertEquals("""{"exp":100.0,"int":1,"neg":-0.0,"whole":1.0}""", CanonicalJson.encodeToString(decoded))
    }

    /** Unknown keys, of any type and depth, come back out byte for byte once keys are sorted. */
    @Test fun anUnknownBagRoundTripsByteForByte() {
        val canonical =
            """{"":0,"conflictCopy.v1":{"fingerprint":"ab","sourceID":"00000000-0000-4000-8000-000000000021","version":1},""" +
                """"future":[1,2.5,"three",null,true,{"k":[]}],"local.x":"\u0000\"\\ é 😀","n":-9223372036854775808}"""
        val parsed = parse(canonical)
        assertEquals(canonical, CanonicalJson.encodeToString(parsed))
        // A second trip changes nothing either.
        assertEquals(parsed, parse(CanonicalJson.encodeToString(parsed)))
    }

    @Test fun integersAndDoublesAreNeverEqualAndNeverConfused() {
        assertNotEquals<JsonValue>(JsonValue.Integer(1), JsonValue.Real(1.0))
        assertNotEquals<JsonValue>(JsonValue.Real(1.0), JsonValue.Integer(1))
        assertNotEquals<JsonValue>(JsonValue.Bool(true), JsonValue.Integer(1))
        assertNotEquals<JsonValue>(JsonValue.Text("1"), JsonValue.Integer(1))
        assertNotEquals<JsonValue>(JsonValue.Null, JsonValue.Bool(false))
        assertNotEquals<JsonValue>(JsonValue.Text(""), JsonValue.Null)

        assertEquals(1L, JsonValue.Integer(1).longOrNull)
        assertNull(JsonValue.Real(1.0).longOrNull)
        // Swift's `Value.double` widens an integer; the envelope reader relies on it for timestamps.
        assertEquals(1.0, JsonValue.Integer(1).doubleOrNull)
        assertEquals(1.5, JsonValue.Real(1.5).doubleOrNull)
        assertNull(JsonValue.Text("1").doubleOrNull)
    }

    /** Swift compares doubles with `==`: the two zeros are equal. NaN is equal to itself here so `equals` stays lawful. */
    @Test fun doublesCompareAsNumbers() {
        assertEquals<JsonValue>(JsonValue.Real(0.0), JsonValue.Real(-0.0))
        assertEquals(JsonValue.Real(0.0).hashCode(), JsonValue.Real(-0.0).hashCode())
        assertEquals<JsonValue>(JsonValue.Real(Double.NaN), JsonValue.Real(Double.NaN))
        assertNotEquals<JsonValue>(JsonValue.Real(1.0), JsonValue.Real(1.0000000000000002))
        // Equal as values, but each keeps its own spelling.
        assertEquals("0.0", CanonicalJson.encodeToString(JsonValue.Real(0.0)))
        assertEquals("-0.0", CanonicalJson.encodeToString(JsonValue.Real(-0.0)))
    }

    @Test fun aStringIsTheSameValueWhetherHeldAsTextOrAsBytes() {
        val text = JsonValue.Text("naïve 🔐")
        val bytes = JsonValue.Utf8(utf8("naïve 🔐"))
        assertEquals<JsonValue>(text, bytes)
        assertEquals<JsonValue>(bytes, text)
        assertEquals(text.hashCode(), bytes.hashCode())
        assertEquals(setOf<JsonValue>(text), setOf<JsonValue>(bytes))
        assertNotEquals<JsonValue>(text, JsonValue.Utf8(utf8("naive 🔐")))
        // Not normalised: two spellings of é are two strings, as their bytes are.
        assertNotEquals<JsonValue>(JsonValue.Text("\u00E9"), JsonValue.Text("e\u0301"))
        assertNotEquals<JsonValue>(JsonValue.Text("\u00E9"), JsonValue.Utf8(utf8("e\u0301")))

        assertEquals("naïve 🔐", bytes.textOrNull)
        assertContentEquals(utf8("naïve 🔐"), text.utf8OrNull)
        assertNull(JsonValue.Utf8(unhex("c328")).textOrNull)          // not UTF-8: no text, never U+FFFD
        assertNull(JsonValue.Integer(1).textOrNull)
        assertNull(JsonValue.Integer(1).utf8OrNull)
    }

    /** A secret body lives in one array that can be zeroed; nothing copies it behind the caller's back. */
    @Test fun aByteStringSharesItsArraySoItCanBeWiped() {
        val secret = utf8("hunter2")
        val value = JsonValue.Utf8(secret)
        assertSame(secret, value.bytes)
        assertSame(secret, value.utf8OrNull)
        assertFalse(value.toString().contains("hunter2"))
        assertFalse(JsonValue.Text("hunter2").toString().contains("hunter2"))

        value.wipe()
        assertEquals("00000000000000", secret.hex())
    }

    /** Containers are copies: changing the list or map they were built from does not change the value. */
    @Test fun containersAreImmutableSnapshots() {
        val source = mutableListOf<JsonValue>(JsonValue.Integer(1))
        val array = JsonValue.Array(source)
        source.add(JsonValue.Integer(2))
        assertEquals(1, array.elements.size)
        assertFailsWith<UnsupportedOperationException> { (array.elements as MutableList<JsonValue>).add(JsonValue.Null) }

        val members = linkedMapOf<String, JsonValue>("a" to JsonValue.Integer(1))
        val obj = JsonValue.Object(members)
        members["b"] = JsonValue.Integer(2)
        assertEquals(setOf("a"), obj.members.keys)
        assertFailsWith<UnsupportedOperationException> { (obj.members as MutableMap<String, JsonValue>).clear() }
    }

    @Test fun objectsCompareWithoutRegardToOrderAndArraysWithIt() {
        assertEquals(
            JsonValue.obj("a" to JsonValue.of(1), "b" to JsonValue.of("x")),
            JsonValue.obj("b" to JsonValue.Utf8(utf8("x")), "a" to JsonValue.of(1L)),
        )
        assertNotEquals(JsonValue.array(JsonValue.of(1), JsonValue.of(2)), JsonValue.array(JsonValue.of(2), JsonValue.of(1)))
        assertNotEquals(JsonValue.obj("a" to JsonValue.of(1)), JsonValue.obj("a" to JsonValue.of(1.0)))
        assertNotEquals<JsonValue>(JsonValue.obj(), JsonValue.array())
    }

    @Test fun theAccessorsAnswerOnlyForTheirOwnCase() {
        val array = JsonValue.array(JsonValue.Null)
        val obj = JsonValue.obj("k" to JsonValue.of(true))
        assertTrue(JsonValue.Null.isNull)
        assertFalse(JsonValue.of(false).isNull)
        assertEquals(true, JsonValue.of(true).boolOrNull)
        assertNull(JsonValue.of(1).boolOrNull)
        assertEquals(listOf<JsonValue>(JsonValue.Null), array.arrayOrNull)
        assertNull(obj.arrayOrNull)
        assertEquals(mapOf<String, JsonValue>("k" to JsonValue.Bool(true)), obj.objectOrNull)
        assertNull(array.objectOrNull)
        assertEquals<JsonValue?>(JsonValue.Bool(true), (obj as JsonValue.Object)["k"])
        assertNull(obj["missing"])
    }
}
