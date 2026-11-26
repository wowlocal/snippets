package com.khm.snippets.core.library

import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.state.FaultInjectingIo
import com.khm.snippets.core.state.Halt
import com.khm.snippets.core.state.HaltDetail
import com.khm.snippets.core.state.HaltReason
import com.khm.snippets.core.state.LibraryQuarantineMarker
import com.khm.snippets.core.state.RecoveryContext
import com.khm.snippets.core.state.SimulatedCrash
import com.khm.snippets.core.state.StateSandbox
import com.khm.snippets.core.state.SyncState
import com.khm.snippets.core.state.SyncStateFile
import com.khm.snippets.core.state.TEST_DEVICE
import com.khm.snippets.core.state.entriesOf
import com.khm.snippets.core.state.sandbox
import com.khm.snippets.core.state.seedState
import com.khm.snippets.core.state.testSnippet
import com.khm.snippets.core.state.utf8
import java.io.File
import java.nio.file.Files
import java.util.TimeZone
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** The unreadable-library rule (`SnippetStore.quarantineUnreadableLibrary`, `SnippetStorePersistenceTests`). */
class LibraryQuarantineTest {

    private val utc: TimeZone = TimeZone.getTimeZone("UTC")

    /** 2026-02-02T02:40:00.75Z, seconds since 2001. */
    private val now = 1_770_000_000.75 - 978_307_200.0

    private val damaged = utf8("{not-a-library")

    private fun StateSandbox.quarantine(io: FaultInjectingIo? = null) =
        if (io == null) LibraryQuarantine(locations) else LibraryQuarantine(locations, io)

    private fun StateSandbox.state(): SyncState? = SyncStateFile(locations).load().loadedState

    private fun StateSandbox.marker() = LibraryQuarantineMarker(locations)

    @Test
    fun theMarkerThenTheHaltThenTheMove() = sandbox("order") { s ->
        Files.write(s.library.toPath(), damaged)
        val io = FaultInjectingIo()
        val outcome = s.quarantine(io).quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc)
        assertIs<LibraryQuarantine.Outcome.Quarantined>(outcome)
        assertEquals(listOf("write:library-quarantine", "write:state.json", "move:snippets.json"), io.log)

        assertEquals(outcome.reviewId, s.marker().reviewId())
        val halt = s.state()!!.halt!!
        assertEquals(HaltReason.LOCAL_LIBRARY_QUARANTINED, halt.reason)
        assertSame(RecoveryContext.LocalLibraryQuarantine, halt.recoveryContext)
        assertEquals(Math.floor(now), halt.at, "whole seconds, as Swift stores it")
        assertEquals(TEST_DEVICE, s.state()!!.deviceId, "a state that had to be created carries the app's device id")

        assertTrue(!s.library.exists())
        assertEquals(File(s.locations.root, "snippets.json.corrupt-20260202-024000"), outcome.preservedAs)
        assertContentEquals(damaged, Files.readAllBytes(outcome.preservedAs!!.toPath()), "moved, not copied or changed")
        assertTrue(s.quarantine().isQuarantined(), "a missing library is never an empty one now")
    }

    @Test
    fun aRepairedFileIsAdoptedAndNothingIsWritten() = sandbox("repaired") { s ->
        val snippets = listOf(testSnippet(1))
        Files.write(s.library.toPath(), SnippetLibraryCodec.encode(snippets))
        val io = FaultInjectingIo()
        val outcome = s.quarantine(io).quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc)
        assertIs<LibraryQuarantine.Outcome.Repaired>(outcome)
        assertEquals(snippets, outcome.snippets)
        assertEquals(false, outcome.markerPresent)
        assertEquals(emptyList(), io.log)

        // The store's own reader decides what "repaired" means.
        val refusing = s.quarantine(io).quarantineUnreadable(1_000, TEST_DEVICE, now, decode = { null }, zone = utc)
        assertIs<LibraryQuarantine.Outcome.Quarantined>(refusing)
    }

    @Test
    fun aFailedStepStopsTheSequenceAndKeepsTheFileInPlace() = sandbox("failed-steps") { s ->
        Files.write(s.library.toPath(), damaged)
        val markerFails = FaultInjectingIo().apply { fail = { _, file -> file.name == "library-quarantine" } }
        assertIs<LibraryQuarantine.Outcome.MarkerNotWritten>(s.quarantine(markerFails).quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc))
        assertTrue(s.library.exists() && !s.marker().exists() && !s.stateFile.exists())

        val haltFails = FaultInjectingIo().apply { fail = { _, file -> file.name == "state.json" } }
        assertSame(LibraryQuarantine.Outcome.HaltNotWritten, s.quarantine(haltFails).quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc))
        assertTrue(s.library.exists() && s.marker().exists())
        assertTrue(s.quarantine().isQuarantined(), "the marker alone already fences the library")

        val moveFails = FaultInjectingIo().apply { fail = { kind, _ -> kind == "move" } }
        val retained = s.quarantine(moveFails).quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc)
        assertIs<LibraryQuarantine.Outcome.Quarantined>(retained)
        assertNull(retained.preservedAs)
        assertTrue(retained.moveFailure != null)
        assertContentEquals(damaged, Files.readAllBytes(s.library.toPath()), "conservative: the durable stop is in place")
        assertEquals(s.marker().reviewId(), retained.reviewId, "one review id across retries")
    }

    @Test
    fun aStateFileOfAnotherSchemaStopsTheMoveAndIsNotWritten() = sandbox("unsupported") { s ->
        Files.write(s.library.toPath(), damaged)
        Files.write(s.stateFile.toPath(), utf8("{\"schemaVersion\":6}"))
        val outcome = s.quarantine().quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc)
        assertEquals(6L, (outcome as LibraryQuarantine.Outcome.StateUnsupported).version)
        assertEquals("{\"schemaVersion\":6}", String(Files.readAllBytes(s.stateFile.toPath())))
        assertTrue(s.library.exists())
    }

    @Test
    fun theQuarantineHaltReplacesAnyOtherHaltAndKeepsTheIdentity() = sandbox("replaces") { s ->
        Files.write(s.library.toPath(), damaged)
        seedState(s, SyncState("0badc0de", generation = 4, halt = Halt(HaltReason.MASS_DELETION, HaltDetail.of("m"), 1.0)))
        s.quarantine().quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc)
        val state = s.state()!!
        assertEquals(HaltReason.LOCAL_LIBRARY_QUARANTINED, state.halt?.reason)
        assertEquals("0badc0de", state.deviceId)
        assertEquals(4L, state.generation)
    }

    @Test
    fun aBusyGuardChangesNothing() = sandbox("busy") { s ->
        Files.write(s.library.toPath(), damaged)
        val held = s.locations.guard.acquire(1_000)!!
        try {
            assertSame(LibraryQuarantine.Outcome.Busy, s.quarantine().quarantineUnreadable(20, TEST_DEVICE, now, zone = utc))
        } finally {
            held.close()
        }
        assertTrue(s.library.exists() && !s.marker().exists())
    }

    @Test
    fun aSecondQuarantineInTheSameSecondNeverOverwritesTheFirst() = sandbox("same-second") { s ->
        Files.write(s.library.toPath(), damaged)
        s.quarantine().quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc)
        Files.write(s.library.toPath(), utf8("{other"))
        val second = s.quarantine().quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc) as LibraryQuarantine.Outcome.Quarantined
        assertEquals("snippets.json.corrupt-20260202-024000-2", second.preservedAs!!.name)
        assertEquals(2, entriesOf(s.locations.root).count { it.startsWith(LibraryQuarantine.CORRUPT_PREFIX) })
    }

    @Test
    fun aCrashBetweenAnyTwoStepsLeavesTheLibraryFenced() = sandbox("crash") { s ->
        for (step in 1..3) for (after in listOf(false, true)) {
            s.marker().removeDurably()
            s.stateFile.delete()
            entriesOf(s.locations.root).filter { it.startsWith(LibraryQuarantine.CORRUPT_PREFIX) }.forEach { File(s.locations.root, it).delete() }
            Files.write(s.library.toPath(), damaged)
            val io = FaultInjectingIo().apply { if (after) crashAfter = step else crashBefore = step }
            assertFailsWith<SimulatedCrash> { s.quarantine(io).quarantineUnreadable(1_000, TEST_DEVICE, now, zone = utc) }
            val label = "crash ${if (after) "after" else "before"} step $step"
            val bytesSurvive = s.library.exists() || entriesOf(s.locations.root).any { it.startsWith(LibraryQuarantine.CORRUPT_PREFIX) }
            assertTrue(bytesSurvive, "$label lost the unreadable bytes")
            if (!s.library.exists()) assertTrue(s.quarantine().isQuarantined(), "$label: a moved library must stay fenced")
            if (step == 1 && !after) {
                // Nothing happened: the next launch fails to read the file again and repeats the rule.
                assertTrue(s.library.exists() && !s.marker().exists())
            }
        }
    }

    @Test
    fun quarantineInEffect() = sandbox("in-effect") { s ->
        val q = s.quarantine()
        assertTrue(!q.isQuarantined(), "a first launch: no library, no marker, no state")

        Files.write(s.library.toPath(), SnippetLibraryCodec.encode(emptyList()))
        assertTrue(!q.isQuarantined())
        s.marker().write()
        assertTrue(q.isQuarantined(), "a restored file is only a candidate while the marker exists")

        s.library.delete()
        s.marker().removeDurably()
        seedState(s, SyncState(TEST_DEVICE, halt = Halt(HaltReason.LOCAL_LIBRARY_QUARANTINED, HaltDetail.of("q"), 0.0, RecoveryContext.LocalLibraryQuarantine)))
        assertTrue(q.isQuarantined(), "the halt alone fences a missing library")
        seedState(s, SyncState(TEST_DEVICE, halt = Halt(HaltReason.MASS_DELETION, HaltDetail.of("m"), 0.0)))
        assertTrue(!q.isQuarantined(), "another halt does not")
        Files.write(s.stateFile.toPath(), utf8("{\"schemaVersion\":6}"))
        assertTrue(q.isQuarantined(), "a state of another schema may hold the fence")
        s.stateFile.delete()
        s.marker().write()
        assertTrue(q.isQuarantined(), "the marker alone fences when state.json is lost")
    }
}
