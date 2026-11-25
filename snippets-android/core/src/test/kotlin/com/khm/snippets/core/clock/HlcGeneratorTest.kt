package com.khm.snippets.core.clock

import com.khm.snippets.core.text.SeededRandom
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * `ClockAndStateTests.Generator` ("HLC generator"). The three `observe` cases
 * (`aRemoteClockBeyondTheDriftLimit…`, `aRemoteClockTwentyThreeHoursAhead…`,
 * `theDriftLimitIsInclusive…`) have no counterpart: `observe` is not ported because no
 * production code calls it.
 */
class HlcGeneratorTest {

    private class ManualPhysicalClock(var nowMs: Long) {
        val reader: () -> Long = { nowMs }
    }

    private companion object {
        const val EPOCH_FLOOR_MS = 1_577_836_800_000L
        const val EPOCH_SPAN_MS = 15L * 365 * 24 * 60 * 60 * 1000
    }

    private fun appleSeconds(unixMillis: Long): Double = AppleTime.fromUnixSeconds(unixMillis.toDouble() / 1000)

    private fun SeededRandom.hlc(): Hlc =
        Hlc.of(EPOCH_FLOOR_MS + below(EPOCH_SPAN_MS), (next() and 0xFFFF).toInt(), deviceId())

    private fun assertStrictlyIncreasing(issued: List<Hlc>) {
        for (index in 1 until issued.size) {
            assertTrue(issued[index - 1] < issued[index], "${issued[index - 1]} then ${issued[index]}")
        }
        assertEquals(issued.size, issued.map { it.string }.toSet().size)
    }

    @Test
    fun sendIsStrictlyMonotonicWhileThePhysicalClockFreezesStepsBackAndJumpsHours() {
        val baseMs = 1_770_000_000_000L
        val clock = ManualPhysicalClock(baseMs)
        val generator = HlcGenerator("a1b2c3d4", physicalNowMs = clock.reader)

        val issued = ArrayList<Hlc>()
        repeat(64) { issued.add(generator.send()) } // frozen
        clock.nowMs -= 250 // small NTP step back
        repeat(64) { issued.add(generator.send()) }
        clock.nowMs -= 3 * 60 * 60 * 1000 // DST / timezone jump
        repeat(64) { issued.add(generator.send()) }
        clock.nowMs = baseMs + 5 // clock recovers
        val firstAfterRecovery = generator.send()
        issued.add(firstAfterRecovery)
        repeat(63) { issued.add(generator.send()) }

        assertStrictlyIncreasing(issued)
        assertTrue(issued.all { it.wallMs >= baseMs })
        assertTrue(issued.all { it.device == "a1b2c3d4" })
        assertEquals(issued.last(), generator.last)

        // Once the clock is ahead again the counter resets.
        assertEquals(baseMs + 5, firstAfterRecovery.wallMs)
        assertEquals(0, firstAfterRecovery.counter)
        assertEquals(baseMs + 5, issued.last().wallMs)
    }

    @Test
    fun stampNeverReturnsAValueAtOrBelowTheRecordsOwnAncestor() {
        val random = SeededRandom(0x5741_4D50L)
        val clock = ManualPhysicalClock(EPOCH_FLOOR_MS)
        val generator = HlcGenerator("0f1e2d3c", physicalNowMs = clock.reader)

        repeat(3_000) {
            clock.nowMs = EPOCH_FLOOR_MS + random.below(EPOCH_SPAN_MS)
            val ancestor = random.hlc()
            val updatedAt = appleSeconds(EPOCH_FLOOR_MS + random.below(EPOCH_SPAN_MS))

            val stamped = generator.stamp(updatedAt, ancestor)
            assertTrue(stamped > ancestor, "$stamped must beat $ancestor")
            assertEquals(generator.last, stamped)
            assertEquals("0f1e2d3c", stamped.device)
            assertTrue(stamped.wallMs >= AppleTime.hlcMillis(updatedAt))
        }
    }

    @Test
    fun undoOutranksTheRemoteEditItIsReverting() {
        val t0 = 1_770_000_000_000L
        val clock = ManualPhysicalClock(t0)
        val generator = HlcGenerator("0f1e2d3c", physicalNowMs = clock.reader)

        val original = generator.stamp(appleSeconds(t0), null)

        // Another writer edits the same record thirty seconds later.
        val remoteEdit = Hlc.of(t0 + 30_000, 0, Hlc.FOREIGN_DEVICE)
        assertTrue(original < remoteEdit)

        // Our clock is a minute behind, and undo restores the ORIGINAL updatedAt.
        clock.nowMs = t0 - 60_000
        val naive = Hlc.of(t0, 0, "0f1e2d3c")
        assertTrue(naive < remoteEdit)

        val undone = generator.stamp(appleSeconds(t0), remoteEdit)
        assertTrue(undone > remoteEdit)
        assertEquals(remoteEdit.wallMs + 1, undone.wallMs)
    }

    @Test
    fun aGeneratorRestoredFromAClockAheadOfTheWallClockKeepsIssuingAboveIt() {
        val nowMs = 1_770_000_000_000L
        val persisted = Hlc.of(nowMs + 10 * 60 * 1000, 7, "abcdef01")
        val clock = ManualPhysicalClock(nowMs)
        val generator = HlcGenerator("abcdef01", persisted, clock.reader)

        assertEquals(persisted, generator.last)

        var previous = persisted
        repeat(32) {
            val next = generator.send()
            assertTrue(next > persisted)
            assertTrue(next > previous)
            assertEquals(persisted.wallMs, next.wallMs)
            previous = next
        }

        clock.nowMs = persisted.wallMs + 1
        val recovered = generator.send()
        assertEquals(persisted.wallMs + 1, recovered.wallMs)
        assertEquals(0, recovered.counter)
        assertTrue(recovered > previous)
    }

    @Test
    fun aGeneratorRestoredFromAStaleClockStartsFromTheWallClockInstead() {
        val nowMs = 1_770_000_000_000L
        val stale = Hlc.of(nowMs - 5_000, 900, "abcdef01")
        val generator = HlcGenerator("abcdef01", stale, ManualPhysicalClock(nowMs).reader)

        assertEquals(nowMs, generator.last.wallMs)
        assertEquals(0, generator.last.counter)
        assertTrue(generator.last > stale)
    }

    @Test
    fun aRelaunchNeverReissuesAReadingTheEarlierRunAlreadyHandedOut() {
        val random = SeededRandom(0x5211_0ADL)
        var clock = ManualPhysicalClock(1_770_000_000_000L)
        var generator = HlcGenerator("abcdef01", physicalNowMs = clock.reader)
        val issued = ArrayList<Hlc>()

        repeat(12) {
            repeat(8) { issued.add(generator.send()) }
            // Relaunch, with the wall clock anywhere within a day either side.
            val jitter = random.below(2L * 24 * 60 * 60 * 1000)
            clock = ManualPhysicalClock((1_770_000_000_000L - 24L * 60 * 60 * 1000) + jitter)
            generator = HlcGenerator("abcdef01", generator.last, clock.reader)
        }
        assertStrictlyIncreasing(issued)
    }

    /**
     * The generator starts at (now, 0), so the first `send` at an unchanged clock is
     * counter 1. `SyncJournal.clock(after:)` builds a generator and sends once; (now, 0)
     * instead would change merge outcomes against Swift devices.
     */
    @Test
    fun theFirstSendAfterConstructionCarriesCounterOne() {
        val generator = HlcGenerator("aabbccdd", physicalNowMs = { 1_000L })
        assertEquals("0000000003e8-0000-aabbccdd", generator.last.string)
        assertEquals("0000000003e8-0001-aabbccdd", generator.send().string)

        // Evidence ahead of the clock: its reading, one counter up, under our device.
        val ahead = HlcGenerator("aabbccdd", Hlc.of(1_500, 3, "0badcafe"), { 1_000L })
        assertEquals("0000000005dc-0004-aabbccdd", ahead.send().string)
    }

    /** `counter_carries…` in `snippets-linux/src/clock.rs`: a full counter carries into the wall reading. */
    @Test
    fun aFullCounterCarriesIntoTheWallReadingInsteadOfWrapping() {
        val generator = HlcGenerator("aabbccdd", Hlc.of(2_000, 0xFFFE, "aabbccdd"), { 1_000L })
        assertEquals("0000000007d0-ffff-aabbccdd", generator.send().string)
        assertEquals("0000000007d1-0000-aabbccdd", generator.send().string)
        assertEquals("0000000007d1-0001-aabbccdd", generator.send().string)
    }

    @Test
    fun sendAtLeastRaisesTheWallReadingButNeverLowersIt() {
        val clock = ManualPhysicalClock(1_000)
        val generator = HlcGenerator("AA-BB-CC-DD", physicalNowMs = clock.reader)
        assertEquals("aabbccdd", generator.device)
        assertEquals("0000000003e8-0001-aabbccdd", generator.sendAtLeast(500).string)
        assertEquals("0000000005dc-0000-aabbccdd", generator.sendAtLeast(1_500).string)
        assertEquals("0000000005dc-0001-aabbccdd", generator.sendAtLeast(1_500).string)
        assertEquals("0000000005dc-0002-aabbccdd", generator.sendAtLeast(1_400).string)
        clock.nowMs = 3_000
        assertEquals("000000000bb8-0000-aabbccdd", generator.sendAtLeast(1).string)
    }

    @Test
    fun theDefaultPhysicalClockIsTheSystemClock() {
        val before = System.currentTimeMillis()
        val reading = HlcGenerator("aabbccdd").send()
        val after = System.currentTimeMillis()
        assertTrue(reading.wallMs in before..after)
    }
}
