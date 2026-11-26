package com.khm.snippets.core.state

import java.nio.file.Files
import java.util.Random
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** Crash points, concurrent writers, the quarantine marker, and encode→decode identity. */
class SyncStateDurabilityTest {

    private val fresh = { SyncState(TEST_DEVICE) }

    // Crash consistency

    /** One write per change, so a crash at either side of it leaves exactly the old or the new document. */
    @Test
    fun aCrashAroundEveryStateWriteLeavesTheOldOrTheNewState() = sandbox("crash") { s ->
        val old = SyncState(TEST_DEVICE, generation = 1)
        val halt = Halt(HaltReason.VAULT_UNREADABLE, HaltDetail.of("v"), 1.0)
        class Case(val label: String, val seed: SyncState?, val expected: SyncState, val run: (SyncStateFile) -> Unit)
        val cases = listOf(
            Case("update", old, old.copy(generation = 2)) { it.update(1_000, null) { state -> state.copy(generation = 2) } },
            Case("updateHalt", old, old.copy(halt = halt)) { it.updateHalt(1_000, halt, null, fresh) },
            Case("loadOrCreate", null, old) { it.loadOrCreate(1_000) { old } },
        )
        for (case in cases) {
            for (crashAfter in listOf(false, true)) {
                s.stateFile.delete()
                case.seed?.let { seedState(s, it) }
                val io = FaultInjectingIo()
                if (crashAfter) io.crashAfter = 1 else io.crashBefore = 1
                assertFailsWith<SimulatedCrash> { case.run(SyncStateFile(s.locations, io)) }
                assertTrue(!s.locations.guard.isHeld, "${case.label} released the guard")
                val reloaded = SyncStateFile(s.locations).load { SyncState("00000000") }
                val label = "${case.label}, crash ${if (crashAfter) "after" else "before"} the write"
                when {
                    crashAfter -> assertEquals(case.expected, reloaded.loadedState, label)
                    case.seed == null -> assertTrue(reloaded is SyncStateLoad.Fresh, label)
                    else -> assertEquals(case.seed, reloaded.loadedState, label)
                }
                assertEquals(emptyList(), entriesOf(s.tmp), "$label left a staged file")
            }
        }
    }

    // Concurrency

    @Test
    fun concurrentWritersThroughTheGuardLoseNothing() = sandbox("concurrent") { s ->
        seedState(s, SyncState(TEST_DEVICE))
        val threads = 8
        val perThread = 40
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(threads)
        val haltWriter = SyncStateFile(s.locations)
        val halt = Halt(HaltReason.REMOTE_DATA_RESET, HaltDetail.of("r"), 3.0)
        try {
            val futures = (0 until threads).map { index ->
                pool.submit<Unit> {
                    start.await()
                    val file = SyncStateFile(s.locations)
                    repeat(perThread) {
                        while (file.update(5_000, null) { it.copy(generation = it.generation + 1) } is SyncStateUpdate.Busy) Unit
                        if (index == 0 && it == perThread / 2) haltWriter.updateHalt(5_000, halt, null, fresh)
                    }
                }
            }
            start.countDown()
            futures.forEach { it.get(60, TimeUnit.SECONDS) }
        } finally {
            pool.shutdownNow()
        }
        val state = SyncStateFile(s.locations).load().loadedState!!
        assertEquals((threads * perThread).toLong(), state.generation, "an increment was lost")
        assertEquals(halt, state.halt, "a concurrent writer erased the halt")
    }

    // Quarantine marker

    @Test
    fun quarantineMarkerRetainsOneReviewIdAcrossCrashRetries() = sandbox("marker") { s ->
        val marker = LibraryQuarantineMarker(s.locations)
        assertTrue(!marker.exists())
        val first = marker.write()
        val retry = marker.write()
        assertEquals(first, retry)
        assertEquals(first, marker.reviewId())
        assertEquals(first.toString() + "\n", String(Files.readAllBytes(marker.file.toPath()), Charsets.UTF_8))

        marker.removeDurably()
        assertTrue(!marker.exists())
        marker.removeDurably() // already gone: success
        val next = marker.write()
        assertTrue(next != first)

        marker.removeDurably()
        val requested = UUID.randomUUID()
        assertEquals(requested, marker.write(requested))
        assertEquals(requested, marker.write(UUID.randomUUID()), "an existing readable marker keeps its id")
        assertEquals(s.locations.libraryQuarantineMarkerFile, LibraryQuarantineMarker.fileBeside(s.stateFile))
    }

    @Test
    fun aMarkerWithoutAnIdStillExistsAndIsReplacedByAReadableOne() = sandbox("marker-damaged") { s ->
        val marker = LibraryQuarantineMarker(s.locations)
        for (content in listOf("", "not-a-uuid\n", "1-1-1-1-1", "\u0000")) {
            Files.write(marker.file.toPath(), utf8(content))
            assertTrue(marker.exists())
            assertEquals(null, marker.reviewId(), content)
        }
        Files.write(marker.file.toPath(), utf8("  " + testId(3).toString().uppercase() + " \n"))
        assertEquals(testId(3), marker.reviewId(), "either case, trimmed, as Swift reads it")
        Files.write(marker.file.toPath(), utf8("garbage"))
        val written = marker.write(testId(4))
        assertEquals(testId(4), written)
        assertEquals(testId(4), marker.reviewId())
    }

    @Test
    fun aCrashAroundTheMarkerWriteLeavesNoMarkerOrAReadableOne() = sandbox("marker-crash") { s ->
        for (after in listOf(false, true)) {
            LibraryQuarantineMarker(s.locations).removeDurably()
            val io = FaultInjectingIo().apply { if (after) crashAfter = 1 else crashBefore = 1 }
            assertFailsWith<SimulatedCrash> { LibraryQuarantineMarker(s.locations, io).write(testId(1)) }
            val marker = LibraryQuarantineMarker(s.locations)
            assertEquals(after, marker.exists())
            assertEquals(if (after) testId(1) else null, marker.reviewId())
        }
    }

    // Property: encode→decode identity

    @Test
    fun randomStatesRoundTripExactlyIncludingExtremeDoubles() {
        val random = Random(0x5EED_5717L)
        val extremes = doubleArrayOf(
            0.0, -0.0, Double.MIN_VALUE, -Double.MIN_VALUE, Double.MAX_VALUE, -Double.MAX_VALUE,
            java.lang.Double.MIN_NORMAL, 1e-300, 1e300, 9_007_199_254_740_992.0, 9_007_199_254_740_993.0 * 2,
            -9_007_199_254_740_992.0, 0.1, 1.0 / 3.0, 790_692_600.123456789, 1e16, 1e-5, 123456789012345678.0,
        )
        val reasons = HaltReason.entries
        repeat(2_000) { iteration ->
            val at = if (iteration < extremes.size) extremes[iteration] else randomFiniteDouble(random)
            val context = when (random.nextInt(3)) {
                0 -> null
                1 -> RecoveryContext.LocalLibraryQuarantine
                else -> RecoveryContext.MassDeletion(random.nextInt(), random.nextInt(), hex(random, 32))
            }
            val claim = if (random.nextBoolean()) RecoveryClaim(UUID(random.nextLong(), random.nextLong()), UUID.randomUUID(), UUID.randomUUID()) else null
            val arguments = (0 until random.nextInt(HaltDetail.MAXIMUM_ARGUMENTS + 1)).associate { "k$it" to randomText(random) }
            val halt = if (random.nextInt(4) == 0) null else Halt(reasons[random.nextInt(reasons.size)], HaltDetail.of("c$iteration", arguments), at, context, claim)
            val state = SyncState(
                deviceId = hex(random, 4),
                generation = if (iteration % 7 == 0) Long.MAX_VALUE else random.nextLong() and Long.MAX_VALUE,
                librarySha256 = if (random.nextBoolean()) hex(random, 32) else null,
                halt = halt,
                promoting = if (random.nextBoolean()) UUID(random.nextLong(), random.nextLong()) else null,
                demoting = if (random.nextBoolean()) UUID(random.nextLong(), random.nextLong()) else null,
            )
            val bytes = SyncStateCodec.encode(state)
            val decoded = SyncStateCodec.decode(bytes)
            assertEquals(state, decoded, "iteration $iteration")
            if (halt != null) {
                assertEquals(java.lang.Double.doubleToLongBits(halt.at.let { if (it == 0.0) 0.0 else it }),
                    java.lang.Double.doubleToLongBits(decoded.halt!!.at.let { if (it == 0.0) 0.0 else it }), "bit-exact time")
            }
            assertContentEquals(bytes, SyncStateCodec.encode(decoded), "deterministic re-encoding")
        }
    }

    private fun randomFiniteDouble(random: Random): Double {
        while (true) {
            val value = java.lang.Double.longBitsToDouble(random.nextLong())
            if (value.isFinite()) return value
        }
    }

    private fun hex(random: Random, bytes: Int): String =
        (0 until bytes).joinToString("") { "%02x".format(random.nextInt(256)) }

    private fun randomText(random: Random): String {
        val pool = listOf("", "plain", "slash/and\\back", "quote\"", "line\nbreak\ttab", "Café", "é", "😀", "\u0000\u001f", "日本語")
        return pool[random.nextInt(pool.size)] + pool[random.nextInt(pool.size)]
    }
}
