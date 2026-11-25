package com.khm.snippets.core.clock

import com.khm.snippets.core.text.SeededRandom
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** `ClockAndStateTests.WireFormat` ("HLC wire format") in `Tests/Core/ClockAndStateTests.swift`. */
class HlcTest {

    private companion object {
        // 2020-01-01 and a fifteen-year span: readings a shipping build can produce.
        const val EPOCH_FLOOR_MS = 1_577_836_800_000L
        const val EPOCH_SPAN_MS = 15L * 365 * 24 * 60 * 60 * 1000
        val CLUSTERED_DEVICES = listOf("00000000", "00000001", "0fffffff", "10000000", "fffffffe", "ffffffff")
    }

    private fun SeededRandom.hlc(): Hlc =
        Hlc.of(EPOCH_FLOOR_MS + below(EPOCH_SPAN_MS), (next() and 0xFFFF).toInt(), deviceId())

    /** Draws from a tiny pool so exact ties and one-bit differences are common. */
    private fun SeededRandom.clusteredHlc(): Hlc =
        Hlc.of(EPOCH_FLOOR_MS + below(3), below(3).toInt(), CLUSTERED_DEVICES[below(CLUSTERED_DEVICES.size.toLong()).toInt()])

    @Test
    fun lexicographicStringOrderIsExactlyTheComparableOrder() {
        val random = SeededRandom(0xC10C_C10CL)
        val clocks = mutableListOf(
            Hlc.of(0, 0, "00000000"),
            Hlc.of(0, 0xFFFF, "ffffffff"),
            Hlc.of(0xFFFF_FFFF_FFFFL, 0, "00000000"),
            Hlc.of(0xFFFF_FFFF_FFFFL, 0xFFFF, "ffffffff"),
        )
        repeat(4_000) { clocks.add(random.hlc()) }
        repeat(2_000) { clocks.add(random.clusteredHlc()) }

        val byValue = clocks.sorted().map { it.string }
        val byString = clocks.map { it.string }.sorted()
        assertEquals(byString, byValue)

        repeat(3_000) {
            val a = random.clusteredHlc()
            val b = random.clusteredHlc()
            assertEquals(a.string < b.string, a < b, "${a.string} vs ${b.string}")
            assertEquals(a.string == b.string, a == b, "${a.string} vs ${b.string}")
            if (a == b) assertEquals(a.hashCode(), b.hashCode())
        }
    }

    @Test
    fun theStringFormIsAlwaysTwelveFourEightLowercaseHex() {
        val random = SeededRandom(0x1D_1D_1DL)
        repeat(1_000) {
            val string = random.hlc().string
            assertEquals(listOf(12, 4, 8), string.split('-').map { it.length }, string)
            assertTrue(string.all { it in '0'..'9' || it in 'a'..'f' || it == '-' }, string)
        }

        assertEquals("000000000000-0000-00000000", Hlc.of(0, 0, "00000000").string)
        // wallMs saturates at 48 bits and the device id is cut to eight, so neither can widen the string.
        assertEquals("ffffffffffff-ffff-ffffffff", Hlc.of(-1L, 0xFFFF, "ffffffffffffffff").string)
        assertEquals("ffffffffffff-0000-00000001", Hlc.of(0x1_0000_0000_0000L, 0, "1").string)
        assertEquals("000000000001-0001-00000001", Hlc.of(1, 1, "1").string)
        assertEquals("000000000001-0001-00000001", Hlc.of(1, 1, "1").toString())
    }

    /** Swift also round-trips through `Codable`; here the JSON form is the same single string, written by the callers. */
    @Test
    fun everyClockRoundTripsThroughItsString() {
        val random = SeededRandom(0xBEEF_CAFEL)
        repeat(1_000) {
            val clock = random.hlc()
            val parsed = Hlc.parse(clock.string)
            assertEquals(clock, parsed, clock.string)
            assertEquals(clock.string, parsed?.string)
        }
    }

    @Test
    fun malformedStringsParseToNullRatherThanBecomingAZeroClock() {
        val malformed = listOf(
            "",
            "0",
            "0-0-0",
            "000000000000-0000-0000000",
            "000000000000-0000-000000000",
            "00000000000-0000-00000000",
            "0000000000000-0000-00000000",
            "000000000000-000-00000000",
            "zzzzzzzzzzzz-0000-00000000",
            "000000000000-000g-00000000",
            "00000000000g-0000-00000000",
            "000000000000-0000-0000000g",
            "000000000000_0000_00000000",
            "000000000000-0000-00000000-00000000",
            "-000000000000-0000-0000000",
            "000000000000-0000",
            // Not in the Swift list: what `toLong(16)` would have accepted.
            "+00000000000-0000-00000000",
            "000000000000-+000-00000000",
            "００００００００００００-0000-00000000",
            "000000000000-0000-0000000١",
        )
        for (raw in malformed) assertNull(Hlc.parse(raw), "\"$raw\" must not parse")

        // The zero clock itself is legal: the rejections are about shape, not value.
        assertEquals(Hlc.of(0, 0, Hlc.FOREIGN_DEVICE), Hlc.parse("000000000000-0000-00000000"))
    }

    @Test
    fun noncanonicalClockSpellingsAreRejectedRatherThanNormalized() {
        assertNull(Hlc.parse("0000018FE1A2-00FF-AbCdEf01"))
        assertEquals("0000018fe1a2-00ff-abcdef01", Hlc.parse("0000018fe1a2-00ff-abcdef01")?.string)

        assertTrue(Hlc.isCanonicalDeviceId("abcdef01"))
        assertFalse(Hlc.isCanonicalDeviceId("ABCDEF01"))
        assertFalse(Hlc.isCanonicalDeviceId("abcdef0"))
        assertFalse(Hlc.isCanonicalDeviceId("１２３４５６７８"))
    }

    @Test
    fun theForeignDeviceIdSortsStrictlyBelowEveryRealDeviceId() {
        val random = SeededRandom(0xF0DE_1234L)
        val wallMs = 1_770_000_000_000L
        val foreign = Hlc.foreign(AppleTime.fromUnixSeconds(wallMs.toDouble() / 1000))
        assertEquals(Hlc.FOREIGN_DEVICE, foreign.device)
        assertEquals(wallMs, foreign.wallMs)
        assertEquals(0, foreign.counter)

        var checked = 0
        repeat(5_000) {
            val device = random.deviceId()
            if (device == Hlc.FOREIGN_DEVICE) return@repeat
            checked += 1
            val inApp = Hlc.of(wallMs, 0, device)
            assertTrue(foreign < inApp, "foreign must lose the tie against $device")
            assertFalse(inApp < foreign)
            assertTrue(Hlc.FOREIGN_DEVICE < device)
            // Only the tie is narrowed: a later foreign write still wins outright.
            assertTrue(inApp < Hlc.of(wallMs + 1, 0, Hlc.FOREIGN_DEVICE))
        }
        assertTrue(checked > 4_900)
    }

    @Test
    fun aDeviceIdIsAlwaysNormalizedToEightLowercaseHexDigits() {
        assertEquals("abcdef01", Hlc.normalizedDevice("ABCDEF01"))
        assertEquals("abcdef01", Hlc.normalizedDevice("abcdef0123456789"))
        assertEquals("00000001", Hlc.normalizedDevice("1"))
        assertEquals("abcdef01", Hlc.normalizedDevice("ab-cd-ef-01"))
        assertEquals("00000eaa", Hlc.normalizedDevice("not hex at all"))

        // Reserved id: only the literal foreign id normalizes to itself.
        assertEquals(Hlc.FOREIGN_DEVICE, Hlc.normalizedDevice(Hlc.FOREIGN_DEVICE))
        assertNotEquals(Hlc.FOREIGN_DEVICE, Hlc.normalizedDevice(""))
        assertNotEquals(Hlc.FOREIGN_DEVICE, Hlc.normalizedDevice("zzzz"))
        assertEquals("00000001", Hlc.normalizedDevice("0000-0000"))
        repeat(200) {
            val made = Hlc.makeDeviceId()
            assertNotEquals(Hlc.FOREIGN_DEVICE, made)
            assertTrue(Hlc.isCanonicalDeviceId(made), made)
        }
        assertEquals("00000001", Hlc.makeDeviceId(object : java.util.Random() {
            override fun nextInt(): Int = 0
        }))

        val random = SeededRandom(0xDEAD_10CCL)
        repeat(500) {
            assertTrue(Hlc.isCanonicalDeviceId(Hlc.of(0, 0, random.deviceId()).device))
        }
    }

    /**
     * Measured from Swift on macOS 27.2: `Character.isHexDigit` keeps a fullwidth digit
     * and drops a digit that carries a combining mark or a joiner, because the filter
     * works on `Character`s.
     */
    @Test
    fun normalizedDeviceFiltersCharactersTheWaySwiftDoes() {
        assertEquals("000000１２", Hlc.normalizedDevice("１２"))
        assertEquals("0000ａｂcd", Hlc.normalizedDevice("ＡＢcd"))
        assertEquals("ａｂｃｄｅｆ０１", Hlc.normalizedDevice("ａｂｃｄｅｆ０１２"))
        assertEquals("000000bc", Hlc.normalizedDevice("ábc"))
        assertEquals("0000000b", Hlc.normalizedDevice("a‍b"))
        assertEquals("00000001", Hlc.normalizedDevice("a️1"))
        assertEquals("00000001", Hlc.normalizedDevice("١"))
        assertEquals("0000000a", Hlc.normalizedDevice("éa"))
        assertEquals("000000ab", Hlc.normalizedDevice("ǅAB"))
        assertEquals("0000000a", Hlc.normalizedDevice("İa"))
        assertEquals("000000000005-0001-000000１２", Hlc.of(5, 1, "１２").string)
        assertNull(Hlc.parse(Hlc.of(5, 1, "１２").string))
    }

    @Test
    fun aCounterOutsideSixteenBitsIsRefused() {
        assertTrue(runCatching { Hlc.of(0, -1, "1") }.isFailure)
        assertTrue(runCatching { Hlc.of(0, 0x1_0000, "1") }.isFailure)
        assertEquals(0xFFFF, Hlc.of(0, 0xFFFF, "1").counter)
    }
}
