package com.khm.snippets.core.clock

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AppleTimeTest {

    @Test
    fun theEpochOffsetIsTheOneFoundationUses() {
        assertEquals(978_307_200.0, AppleTime.UNIX_EPOCH_OFFSET_SECONDS)
        assertEquals(0.0, AppleTime.fromUnixSeconds(978_307_200.0))
        assertEquals(978_307_200.0, AppleTime.unixSeconds(0.0))
        assertEquals(0.0, AppleTime.fromUnixMillis(978_307_200_000L))
        assertEquals(0.5, AppleTime.fromUnixMillis(978_307_200_500L))
        assertEquals(-978_307_200.0, AppleTime.fromUnixMillis(0L))
    }

    @Test
    fun nowIsTheSystemClockInSecondsSince2001() {
        val before = System.currentTimeMillis()
        val now = AppleTime.now()
        val after = System.currentTimeMillis()
        assertTrue(AppleTime.displayUnixMillis(now) in before..after)
        assertTrue(AppleTime.systemUnixMillis() >= before)
    }

    /** `Date.millisecondsSince1970`: truncation, never rounding; nothing before 1970; 48 bits at most. */
    @Test
    fun hlcMillisTruncatesAndSaturatesLikeSwift() {
        fun fromUnix(seconds: Double) = AppleTime.hlcMillis(AppleTime.fromUnixSeconds(seconds))
        assertEquals(0L, fromUnix(0.0))
        assertEquals(0L, fromUnix(-1.0))
        assertEquals(0L, fromUnix(0.0004))
        assertEquals(1L, fromUnix(0.0019999))
        assertEquals(1_999L, fromUnix(1.9999))
        assertEquals(1_785_312_000_500L, fromUnix(1_785_312_000.5))
        assertEquals(1_785_312_000_999L, fromUnix(1_785_312_000.9999))
        assertEquals(0xFFFF_FFFF_FFFFL, fromUnix(281_474_976_710.656))
        assertEquals(0xFFFF_FFFF_FFFFL, fromUnix(1e15))
        assertEquals(0xFFFF_FFFF_FFFFL, fromUnix(1e300))
        assertEquals(0L, AppleTime.hlcMillis(Double.POSITIVE_INFINITY))
        assertEquals(0L, AppleTime.hlcMillis(Double.NEGATIVE_INFINITY))
        assertEquals(0L, AppleTime.hlcMillis(Double.NaN))
        assertEquals(978_307_205_000L, AppleTime.hlcMillis(5.0))
        assertEquals(0L, AppleTime.hlcMillis(-978_307_200.0))
        assertEquals("000000000000-0000-00000000", Hlc.foreign(-978_307_199.9995).string)
    }

    @Test
    fun displayMillisRoundAndNeverThrow() {
        assertEquals(978_307_200_000L, AppleTime.displayUnixMillis(0.0))
        assertEquals(978_307_200_001L, AppleTime.displayUnixMillis(0.0006))
        assertEquals(0L, AppleTime.displayUnixMillis(Double.NaN))
        assertEquals(Long.MAX_VALUE, AppleTime.displayUnixMillis(Double.POSITIVE_INFINITY))
        assertEquals(Long.MIN_VALUE, AppleTime.displayUnixMillis(Double.NEGATIVE_INFINITY))
    }
}
