package com.khm.snippets.core.clock

import com.khm.snippets.core.json.SwiftVectors
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/** `L02-hlc`: HLC construction, string form, parsing, order, `millisecondsSince1970` and generator scripts from Swift. */
class SwiftHlcVectorTest {

    private val file = "L02-hlc"

    private fun unsigned(text: String): Long = java.lang.Long.parseUnsignedLong(text)

    private fun assertHlc(expected: SwiftVectors.Case, actual: Hlc, label: String) {
        assertEquals(unsigned(expected.string("wallMs")), actual.wallMs, label)
        assertEquals(expected.int("counter"), actual.counter, label)
        assertEquals(expected.string("device"), actual.device, label)
        assertEquals(expected.string("string"), actual.string, label)
    }

    @Test
    fun construction() {
        val cases = SwiftVectors.cases(file, "init")
        assertEquals(11, cases.size)
        for (case in cases) {
            val hlc = Hlc.of(unsigned(case.string("wallMs")), case.int("counter"), case.string("device"))
            assertHlc(case.obj("hlc"), hlc, case.label)
            assertEquals(hlc, Hlc.parse(hlc.string), case.label)
        }
    }

    @Test
    fun parsing() {
        val cases = SwiftVectors.cases(file, "parse")
        assertEquals(20, cases.size)
        for (case in cases) {
            val parsed = Hlc.parse(case.text("input"))
            if (case.isNull("hlc")) {
                assertNull(parsed, case.label)
            } else {
                assertHlc(case.obj("hlc"), parsed ?: fail("${case.label}: Swift parses this"), case.label)
            }
        }
    }

    @Test
    fun deviceNormalization() {
        val cases = SwiftVectors.cases(file, "normalizedDevice")
        assertEquals(21, cases.size)
        for (case in cases) {
            val input = case.text("input")
            assertEquals(case.string("normalized"), Hlc.normalizedDevice(input), case.label)
            assertEquals(case.boolean("isCanonicalDeviceID"), Hlc.isCanonicalDeviceId(input), case.label)
        }
    }

    @Test
    fun order() {
        val cases = SwiftVectors.cases(file, "compare")
        assertEquals(100, cases.size)
        for (case in cases) {
            val left = Hlc.parse(case.string("left")) ?: fail(case.label)
            val right = Hlc.parse(case.string("right")) ?: fail(case.label)
            val relation = when {
                left < right -> "<"
                left == right -> "=="
                else -> ">"
            }
            assertEquals(case.string("relation"), relation, case.label)
            assertEquals(relation == "==", left.compareTo(right) == 0, case.label)
        }

        val sort = SwiftVectors.cases(file, "sort").single()
        val input = sort.strings("input").map { Hlc.parse(it) ?: fail(sort.label) }
        assertEquals(sort.strings("sorted"), input.sorted().map { it.string }, sort.label)
        assertEquals(sort.string("max"), input.max().string, sort.label)
    }

    @Test
    fun millisecondsSince1970() {
        val cases = SwiftVectors.cases(file, "millisecondsSince1970")
        assertEquals(29, cases.size)
        for (case in cases) {
            val appleSeconds = case.double("secondsSince2001")
            if (case.has("secondsSince1970")) {
                assertEquals(appleSeconds.toRawBits(), AppleTime.fromUnixSeconds(case.double("secondsSince1970")).toRawBits(), case.label)
            }
            assertEquals(
                case.double("secondsSince1970AsSwiftRecomputes").toRawBits(), AppleTime.unixSeconds(appleSeconds).toRawBits(), case.label,
            )
            assertEquals(unsigned(case.string("milliseconds")), AppleTime.hlcMillis(appleSeconds), case.label)
            assertEquals(case.string("foreignHLC"), Hlc.foreign(appleSeconds).string, case.label)
        }
    }

    @Test
    fun generatorScripts() {
        val cases = SwiftVectors.cases(file, "generator")
        assertEquals(11, cases.size)
        var replayed = 0
        for (case in cases) {
            val steps = case.objects("steps")
            if (steps.any { it.string("op") == "observe" }) {
                // `HLCGenerator.observe` has no production caller and is not ported.
                assertEquals("generator-observe", case.name)
                continue
            }
            replayed += 1
            var now = unsigned(case.string("nowMs"))
            val persisted = case.stringOrNull("persisted")?.let { Hlc.parse(it) ?: fail(case.label) }
            val generator = HlcGenerator(case.string("device"), persisted) { now }
            assertEquals(case.string("normalizedDevice"), generator.device, case.label)
            assertEquals(case.string("initialLast"), generator.last.string, case.label)
            for ((index, step) in steps.withIndex()) {
                val label = "${case.label} step $index"
                when (val op = step.string("op")) {
                    "setNow" -> now = unsigned(step.string("nowMs"))
                    "send" -> assertEquals(step.string("result"), generator.send().string, label)
                    "sendAtLeast" -> assertEquals(step.string("result"), generator.sendAtLeast(unsigned(step.string("floorMs"))).string, label)
                    "stamp" -> {
                        val base = step.stringOrNull("baseHLC")?.let { Hlc.parse(it) ?: fail(label) }
                        assertEquals(step.string("result"), generator.stamp(step.double("updatedAt"), base).string, label)
                    }
                    else -> fail("$label: unknown op $op")
                }
                if (step.has("result")) assertEquals(step.string("result"), generator.last.string, label)
            }
        }
        assertEquals(10, replayed)
    }

    @Test
    fun everyKindIsAccountedFor() {
        val kinds = SwiftVectors.cases(file).groupingBy { it.kind }.eachCount()
        assertEquals(setOf("init", "parse", "normalizedDevice", "compare", "sort", "millisecondsSince1970", "generator"), kinds.keys)
        assertTrue(kinds.values.sum() == 193, kinds.toString())
    }
}
