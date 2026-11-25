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
        // Within the wall clock's millisecond; one more allowed for the double's rounding.
        assertTrue(AppleTime.unixSeconds(now) * 1000 in (before - 1.0)..(after + 1.0))
        assertTrue(AppleTime.systemUnixMillis() >= before)
    }

    /** 500 records without dates must not share a time: the display order would fall back to their ids. */
    @Test
    fun nowNeverRepeatsOrGoesBackOnAnyThread() {
        var previous = AppleTime.now()
        repeat(200_000) {
            val next = AppleTime.now()
            assertTrue(next > previous)
            previous = next
        }
        val perThread = List(8) { DoubleArray(20_000) }
        val threads = perThread.map { values -> Thread { for (index in values.indices) values[index] = AppleTime.now() } }
        threads.forEach(Thread::start)
        threads.forEach { it.join(60_000) }
        for (values in perThread) for (index in 1 until values.size) assertTrue(values[index] > values[index - 1])
        assertEquals(8 * 20_000, perThread.flatMap { it.asList() }.toSet().size)
    }

    @Test
    fun theClockReadsInsideTheWallClocksMillisecondAndAnchorsAgainWhenTheTwoSourcesDisagree() {
        var wall = 978_307_200_000L + 5_000 // five seconds into 2001
        var nanos = 1_000_000_000L
        val clock = AppleClock({ wall }, { nanos })

        assertEquals(5.0, clock.now())
        nanos += 250_000 // a quarter of a millisecond later, same wall millisecond
        assertEquals(5.00025, clock.now(), 1e-9)
        // Both sources frozen: still strictly increasing, by the smallest step there is.
        val frozen = clock.now()
        assertEquals(Math.nextUp(5.00025), frozen, 1e-12)
        assertTrue(clock.now() > frozen)

        // The wall clock ticks with the monotonic clock: the fraction carries on.
        wall += 1
        nanos += 1_000_000
        assertEquals(5.00125, clock.now(), 1e-9)

        // The device slept: the wall clock moved an hour, the monotonic clock did not.
        wall += 3_600_000
        assertEquals(3605.001, clock.now(), 1e-9)
        nanos += 500_000
        assertEquals(3605.0015, clock.now(), 1e-9)

        // The wall clock is set back: readings creep forward instead of repeating.
        wall -= 7_200_000
        val afterStepBack = clock.now()
        assertEquals(Math.nextUp(3605.0015), afterStepBack, 1e-12)
        assertTrue(clock.now() > afterStepBack)

        // A change of centuries must not overflow.
        wall += 10_000_000_000_000L
        assertTrue(clock.now() > 9_000_000_000.0)
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
