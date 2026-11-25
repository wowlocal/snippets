package com.khm.snippets.core.canonical

import com.khm.snippets.core.crypto.SwiftVectors
import com.khm.snippets.core.crypto.array
import com.khm.snippets.core.crypto.hex
import com.khm.snippets.core.crypto.obj
import com.khm.snippets.core.crypto.string
import com.khm.snippets.core.crypto.unhex
import com.khm.snippets.core.crypto.utf8
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * The Swift-emitted golden vectors of `V10-canonical-json` (`tools/swift-interop`): 77
 * emitter cases (escapes, key order, integer limits, 43 doubles, refusals) and 72 parser
 * inputs. Every case is run, and in both directions where it has two: what Swift emitted
 * must be emitted here, and must parse back to the value it came from.
 */
class SwiftCanonicalVectorsTest {

    private val cases = SwiftVectors.sealed("V10-canonical-json")

    @Test fun v10Emitter() {
        var emitted = 0
        var refused = 0
        for (case in cases.filter { it.string("kind") == "emit" }) {
            val name = case.string("name")
            val value = value(case.obj("value"))
            when {
                "error" in case -> {
                    assertEquals(
                        SwiftVectors.expectedOutcome(case),
                        SwiftVectors.outcome { CanonicalJson.encode(value).hex() },
                        name,
                    )
                    refused += 1
                }
                "ok" in case -> {
                    assertEquals(case.string("ok"), CanonicalJson.encode(value).hex(), name)
                    emitted += 1
                }
                else -> {
                    val expected = utf8(case.string("canonicalText"))
                    if ("canonicalHex" in case) assertEquals(case.string("canonicalHex"), expected.hex(), "$name: the vector's text and hex")
                    // Emit direction.
                    assertEquals(expected.hex(), CanonicalJson.encode(value).hex(), name)
                    // Parse direction: the canonical bytes come back as the same typed value and re-emit unchanged.
                    val parsed = CanonicalJson.parse(expected)
                    assertEquals(tree(case.obj("value")), tree(parsed), "$name: parsed back")
                    assertEquals(expected.hex(), CanonicalJson.encode(parsed).hex(), "$name: re-emitted")
                    emitted += 1
                }
            }
        }
        assertEquals(66 to 11, emitted to refused)
    }

    /** The 43 doubles on their own: `Double.description` for each recorded bit pattern. */
    @Test fun v10Doubles() {
        var checked = 0
        for (case in cases.filter { it.string("name").startsWith("double-") }) {
            val value = case.obj("value")
            val double = Double.fromBits(java.lang.Long.parseUnsignedLong(value.string("bits"), 16))
            assertEquals(value.string("swift"), SwiftDouble.description(double), case.string("name"))
            assertEquals(case.string("canonicalText"), SwiftDouble.description(double), case.string("name"))
            checked += 1
        }
        assertEquals(43, checked)
    }

    @Test fun v10Parser() {
        var accepted = 0
        var refused = 0
        for (case in cases.filter { it.string("kind") == "parse" }) {
            val name = case.string("name")
            val input = unhex(case.string("inputHex"))
            if ("error" in case) {
                assertEquals(
                    SwiftVectors.expectedOutcome(case),
                    SwiftVectors.outcome { tree(CanonicalJson.parse(input)) },
                    name,
                )
                refused += 1
                continue
            }
            val parsed = CanonicalJson.parse(input)
            assertEquals(tree(case.obj("parsed")), tree(parsed), name)
            if ("reemitError" in case) {
                assertEquals(
                    "error:" + case.string("reemitError"),
                    SwiftVectors.outcome { CanonicalJson.encode(parsed).hex() },
                    "$name: re-emitting",
                )
            } else {
                assertEquals(case.string("reemittedHex"), CanonicalJson.encode(parsed).hex(), "$name: re-emitted")
                assertEquals(case.string("reemittedText"), CanonicalJson.encodeToString(parsed), "$name: re-emitted")
            }
            accepted += 1
        }
        assertEquals(29 to 43, accepted to refused)
    }

    /** By name: `1e400` parses to infinity, as in Swift, and then has no spelling to be emitted with. */
    @Test fun v10AnOutOfRangeExponentParsesToInfinityAndCannotBeReemitted() {
        val case = cases.single { it.string("name") == "parse-number-overflow-to-infinity" }
        assertEquals("1e400", case.string("inputText"))
        assertEquals("7ff0000000000000", case.obj("parsed").string("bits"))
        assertEquals("CanonicalJSON.Failure.nonFiniteNumber", case.string("reemitError"))

        val parsed = CanonicalJson.parse(unhex(case.string("inputHex")))
        assertTrue(parsed is JsonValue.Real)
        assertEquals(Double.POSITIVE_INFINITY, parsed.doubleOrNull)
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { CanonicalJson.encode(parsed) }
    }

    /** The other boundaries the emitter's notes call out, by name. */
    @Test fun v10TheNamedBoundariesHold() {
        val byName = cases.associateBy { it.string("name") }
        for (accepted in listOf("parse-raw-del-in-string", "parse-depth-33-arrays", "parse-depth-32-objects", "parse-number-int64-max-plus-one")) {
            assertTrue("parsed" in byName.getValue(accepted), accepted)
        }
        for ((refused, error) in mapOf(
            "parse-depth-34-arrays" to "tooDeep",
            "parse-depth-33-objects" to "tooDeep",
            "parse-duplicate-key-nfc-vs-nfd" to "duplicateKey",
            "parse-duplicate-key-escaped-vs-raw" to "duplicateKey",
            "parse-form-feed-is-not-whitespace" to "unexpectedByte",
        )) {
            assertEquals("CanonicalJSON.Failure.$error", byName.getValue(refused).string("error"), refused)
        }
    }

    // The vector's typed tree: t = null | bool | int | double | string | utf8 | array | object.

    private fun value(node: JsonObject): JsonValue = when (val type = node.string("t")) {
        "null" -> JsonValue.Null
        "bool" -> JsonValue.Bool(node.string("v").toBooleanStrict())
        "int" -> JsonValue.Integer(node.string("v").toLong())
        "double" -> JsonValue.Real(Double.fromBits(java.lang.Long.parseUnsignedLong(node.string("bits"), 16)))
        "string" -> {
            assertEquals(node.string("utf8Hex"), utf8(node.string("v")).hex(), "a string changed on its way into the test")
            JsonValue.Text(node.string("v"))
        }
        "utf8" -> JsonValue.Utf8(unhex(node.string("hex")))
        "array" -> JsonValue.Array(node.array("v").map { value(it.jsonObject) })
        "object" -> {
            val members = LinkedHashMap<String, JsonValue>()
            // Inserted in reverse, so the emitter cannot pass by keeping insertion order.
            for (member in node.array("v").map { it.jsonObject }.reversed()) {
                assertEquals(member.string("kHex"), utf8(member.string("k")).hex(), "a key changed on its way into the test")
                members[member.string("k")] = value(member.obj("v"))
            }
            JsonValue.Object(members)
        }
        else -> error("unknown value type $type")
    }

    /**
     * One spelling for a vector tree and for a [JsonValue], strict where equality is not:
     * integers and doubles differ, doubles compare by bits (so `0.0` is not `-0.0`), and
     * object members are listed in the vector's order, which is canonical order. A string
     * is its bytes whichever case holds it.
     */
    private fun tree(node: JsonObject): String = when (val type = node.string("t")) {
        "null" -> "null"
        "bool" -> "bool:" + node.string("v")
        "int" -> "int:" + node.string("v")
        "double" -> "double:" + node.string("bits")
        "string" -> "str:" + node.string("utf8Hex")
        "utf8" -> "str:" + node.string("hex")
        "array" -> node.array("v").joinToString(",", "[", "]") { tree(it.jsonObject) }
        "object" -> node.array("v").joinToString(",", "{", "}") { it.string("kHex") + "=" + tree(it.jsonObject.obj("v")) }
        else -> error("unknown value type $type")
    }

    private fun tree(value: JsonValue): String = when (value) {
        JsonValue.Null -> "null"
        is JsonValue.Bool -> "bool:" + value.value
        is JsonValue.Integer -> "int:" + value.value
        is JsonValue.Real -> "double:" + "%016x".format(value.value.toRawBits())
        is JsonValue.Text -> "str:" + utf8(value.value).hex()
        is JsonValue.Utf8 -> "str:" + value.bytes.hex()
        is JsonValue.Array -> value.elements.joinToString(",", "[", "]") { tree(it) }
        is JsonValue.Object -> value.members.entries
            .sortedWith { a, b -> compareCodePoints(a.key, b.key) }
            .joinToString(",", "{", "}") { utf8(it.key).hex() + "=" + tree(it.value) }
    }

    /** Code-point order, which is UTF-8 byte order, computed without the emitter under test. */
    private fun compareCodePoints(first: String, second: String): Int {
        val a = first.codePoints().toArray()
        val b = second.codePoints().toArray()
        for (index in 0 until minOf(a.size, b.size)) if (a[index] != b[index]) return a[index].compareTo(b[index])
        return a.size.compareTo(b.size)
    }
}
