package com.khm.snippets.core.library

import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.io.AtomicFileWriter
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.state.DurableFileIo
import com.khm.snippets.core.state.FaultInjectingIo
import com.khm.snippets.core.state.Halt
import com.khm.snippets.core.state.HaltDetail
import com.khm.snippets.core.state.HaltReason
import com.khm.snippets.core.state.SimulatedCrash
import com.khm.snippets.core.state.StateSandbox
import com.khm.snippets.core.state.SyncState
import com.khm.snippets.core.state.SyncStateFile
import com.khm.snippets.core.state.TEST_DEVICE
import com.khm.snippets.core.state.entriesOf
import com.khm.snippets.core.state.fileIdentity
import com.khm.snippets.core.state.sandbox
import com.khm.snippets.core.state.seedState
import com.khm.snippets.core.state.testSnippet
import com.khm.snippets.core.state.utf8
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The write funnel (`LibraryWriterTests.swift`: the compare-and-swap funnel, unreadable
 * input and the generation counter) and `ReviewRegressionTests.swift` (missing is not
 * empty, unreadable throws, a racing write is folded in). The atomic writer itself and
 * the frozen codec format are tested with `core.io` and `core.codec`.
 */
class LibraryWriterTest {

    private fun StateSandbox.writer(io: DurableFileIo = DurableFileIo.Default, ids: Iterator<java.util.UUID>? = null) =
        LibraryWriter(
            library, SyncStateFile(locations, io), locations.guard, tmp, io,
            now = { 0.0 }, newId = { ids?.next() ?: java.util.UUID.randomUUID() },
        )

    private fun StateSandbox.state(): SyncState? = SyncStateFile(locations).load().loadedState

    private fun StateSandbox.seed(generation: Long) = seedState(this, SyncState(TEST_DEVICE, generation = generation))

    private fun StateSandbox.put(snippets: List<Snippet>) = Files.write(library.toPath(), SnippetLibraryCodec.encode(snippets))

    private fun StateSandbox.onDisk(): List<Snippet> = SnippetLibraryCodec.decode(Files.readAllBytes(library.toPath()))

    // The compare-and-swap funnel

    @Test
    fun updateFoldsInAConcurrentForeignWriteAndKeepsTheOtherWritersRecord() = sandbox("fold-in") { s ->
        val mine = testSnippet(1, "Signature", "Best, Ada")
        val theirs = testSnippet(2, "Address", "1 Analytical Way")
        val first = s.writer().update(1_000, null) { listOf(mine) }
        assertTrue(!first.foldedInForeignWrite)

        val foreign = SnippetLibraryCodec.encode(listOf(mine, theirs))
        AtomicFileWriter.write(foreign, s.library, s.tmp)
        val foreignDigest = SnippetLibraryCodec.digest(foreign)
        assertNotEquals(first.digest, foreignDigest)

        val edited = mine.copy(content = "Warmly, Ada")
        var seen: String? = null
        val outcome = s.writer().update(1_000, first.digest) { snapshot ->
            seen = snapshot.digest
            snapshot.snippets.map { if (it.id == edited.id) edited else it }
        }
        assertEquals(foreignDigest, seen, "the transform was handed the caller's stale belief instead of what is on disk")
        assertTrue(outcome.foldedInForeignWrite)
        val disk = s.onDisk()
        assertEquals(2, disk.size)
        assertTrue(disk.any { it.id == theirs.id && it.content == theirs.content }, "the other writer's record was clobbered")
        assertTrue(disk.any { it.id == mine.id && it.content == "Warmly, Ada" })
        assertEquals(SnippetLibraryCodec.digest(Files.readAllBytes(s.library.toPath())), outcome.digest)
    }

    @Test
    fun aReformattedFileStillCountsAsAForeignWriteEvenThoughItDecodesIdentically() = sandbox("reformatted") { s ->
        val snippets = listOf(testSnippet(1), testSnippet(2))
        val canonical = SnippetLibraryCodec.encode(snippets)
        val reformatted = SnippetLibraryCodec.encodeCollection(snippets)
        assertEquals(snippets, SnippetLibraryCodec.decode(reformatted))
        Files.write(s.library.toPath(), reformatted)

        val outcome = s.writer().update(1_000, SnippetLibraryCodec.digest(canonical)) { it.snippets }
        assertTrue(outcome.foldedInForeignWrite)
        assertContentEquals(canonical, outcome.data, "identical records in other bytes are rewritten once, canonically")
        val settled = s.writer().update(1_000, outcome.digest) { it.snippets }
        assertTrue(!settled.foldedInForeignWrite)
        assertTrue(!settled.wrote)
    }

    @Test
    fun aTransformThatChangesNothingLeavesTheFileCompletelyUntouched() = sandbox("no-op") { s ->
        val written = s.writer().update(1_000, null) { listOf(testSnippet(1), testSnippet(2)) }
        val before = fileIdentity(s.library)
        Thread.sleep(5)
        val outcome = s.writer().update(1_000, written.digest) { it.snippets }
        assertEquals(before, fileIdentity(s.library), "an identical library was republished")
        assertContentEquals(written.data, outcome.data)
        assertEquals(written.digest, outcome.digest)
        assertTrue(!outcome.foldedInForeignWrite && !outcome.wrote)
        assertEquals(emptyList(), entriesOf(s.tmp), "a no-op write still staged a temporary file")

        // Reordering is a storage change: the digest is over exact bytes.
        val reordered = s.writer().update(1_000, outcome.digest) { it.snippets.reversed() }
        assertNotEquals(before, fileIdentity(s.library))
        assertNotEquals(written.digest, reordered.digest)
    }

    @Test
    fun aNoOpUpdateStillReportsThatSomebodyElseWroteTheFile() = sandbox("no-op-foreign") { s ->
        s.writer().update(1_000, null) { listOf(testSnippet(1)) }
        val before = fileIdentity(s.library)
        val outcome = s.writer().update(1_000, "0".repeat(64)) { it.snippets }
        assertTrue(outcome.foldedInForeignWrite)
        assertEquals(before, fileIdentity(s.library))
    }

    @Test
    fun aDenormalizedFileIsCanonicalizedOnceAndThenStopsChanging() = sandbox("canonicalize") { s ->
        s.put(listOf(testSnippet(1).copy(tags = listOf("Work", " work ", "WORK", "  ", "Email"))))
        val beforeFirst = fileIdentity(s.library)
        val first = s.writer().update(1_000, null) { it.snippets }
        assertNotEquals(beforeFirst, fileIdentity(s.library))
        assertEquals(listOf("Work", "Email"), first.snippets.single().tags)
        val afterFirst = fileIdentity(s.library)
        val second = s.writer().update(1_000, first.digest) { it.snippets }
        assertEquals(afterFirst, fileIdentity(s.library), "canonicalisation did not converge")
        assertEquals(first.digest, second.digest)
    }

    // Unreadable input

    @Test
    fun anUndecodableLibraryThrowsRatherThanPresentingAsAnEmptyLibrary() = sandbox("undecodable") { s ->
        val damaged = mapOf(
            "not JSON at all" to utf8("this is not json"),
            "truncated mid-record" to utf8("[{\"id\":\"00000000-0000-4000-8000-0000000"),
            "an object that is not the wrapper" to utf8("{\"records\":[]}"),
            "a record missing its id" to utf8("[{\"name\":\"Sig\",\"keyword\":\"sig\",\"content\":\"x\"}]"),
            "empty file" to ByteArray(0),
        )
        for ((label, bytes) in damaged) {
            Files.write(s.library.toPath(), bytes)
            val before = fileIdentity(s.library)
            val read = assertFailsWith<LibraryWriter.Failure.Unreadable>(label) { s.writer().read() }
            assertEquals(LibraryWriter.Failure.Unreadable.Reason.UNDECODABLE, read.reason, label)
            var ran = false
            assertFailsWith<LibraryWriter.Failure.Unreadable>(label) { s.writer().update(1_000, null) { ran = true; emptyList() } }
            assertTrue(!ran, "the transform saw $label as a library it could edit")
            assertContentEquals(bytes, Files.readAllBytes(s.library.toPath()), "$label was modified")
            assertEquals(before, fileIdentity(s.library))
        }
    }

    @Test
    fun explicitRecoveryPreservesAndReplacesAnUndecodablePrimaryWithoutDecodingIt() = sandbox("raw-recovery") { s ->
        val damaged = utf8("{not-a-library")
        Files.write(s.library.toPath(), damaged)
        s.seed(7)
        val replacement = listOf(testSnippet(1, "Recovered"))
        val preservedId = java.util.UUID.fromString("0f0e0d0c-0b0a-4908-8706-050403020100")

        val outcome = s.writer(ids = listOf(preservedId).iterator())
            .replaceQuarantinedPrimary(replacement, 1_000, SnippetLibraryCodec.digest(damaged))

        assertEquals(replacement, outcome.snippets)
        assertEquals(replacement, s.onDisk())
        val preserved = entriesOf(s.locations.root).filter { it.startsWith(LibraryWriter.PRESERVED_PREFIX) }
        assertEquals(listOf("snippets.json.recovery-preserved-$preservedId"), preserved)
        val preservedFile = File(s.locations.root, preserved.single())
        assertContentEquals(damaged, Files.readAllBytes(preservedFile.toPath()))
        assertEquals(setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE), Files.getPosixFilePermissions(preservedFile.toPath()))
        assertEquals(8L, s.state()?.generation)
        assertTrue(!outcome.foldedInForeignWrite)

        // A second call with the same replacement is a no-op and preserves nothing more.
        val again = s.writer().replaceQuarantinedPrimary(replacement, 1_000, outcome.digest)
        assertTrue(!again.wrote)
        assertEquals(1, entriesOf(s.locations.root).count { it.startsWith(LibraryWriter.PRESERVED_PREFIX) })
    }

    @Test
    fun anExplicitRecoveryOverAMissingPrimaryPreservesNothing() = sandbox("raw-recovery-missing") { s ->
        val outcome = s.writer().replaceQuarantinedPrimary(emptyList(), 1_000, null)
        assertTrue(outcome.wrote, "an empty library is written: recovery to an empty library is explicit")
        assertEquals(emptyList(), s.onDisk())
        assertEquals(0, entriesOf(s.locations.root).count { it.startsWith(LibraryWriter.PRESERVED_PREFIX) })
    }

    @Test
    fun aCrashDuringExplicitRecoveryKeepsTheOriginalBytesOrTheirPreservedCopy() = sandbox("raw-recovery-crash") { s ->
        val damaged = utf8("{not-a-library")
        // Mutations: 1 preserved copy, 2 the replacement, 3 the generation.
        for (step in 1..3) for (after in listOf(false, true)) {
            entriesOf(s.locations.root).filter { it.startsWith(LibraryWriter.PRESERVED_PREFIX) }.forEach { File(s.locations.root, it).delete() }
            Files.write(s.library.toPath(), damaged)
            s.seed(0)
            val io = FaultInjectingIo().apply { if (after) crashAfter = step else crashBefore = step }
            assertFailsWith<SimulatedCrash> { s.writer(io).replaceQuarantinedPrimary(listOf(testSnippet(1)), 1_000, null) }
            val preserved = entriesOf(s.locations.root).filter { it.startsWith(LibraryWriter.PRESERVED_PREFIX) }
            val primary = Files.readAllBytes(s.library.toPath())
            val label = "crash ${if (after) "after" else "before"} step $step"
            if (primary.contentEquals(damaged)) {
                // Not replaced yet: nothing was lost.
                assertTrue(step < 2 || (step == 2 && !after), label)
            } else {
                // Replaced: the unreadable bytes survive beside it.
                assertEquals(1, preserved.size, label)
                assertContentEquals(damaged, Files.readAllBytes(File(s.locations.root, preserved.single()).toPath()), label)
            }
        }
    }

    @Test
    fun aMissingLibraryIsAnEmptyLibraryRatherThanAnError() = sandbox("missing") { s ->
        val snapshot = s.writer().read()
        assertEquals(LibraryWriter.Snapshot.MISSING, snapshot)
        assertTrue(snapshot.snippets.isEmpty() && snapshot.digest.isEmpty() && !snapshot.fileExisted)
        val outcome = s.writer().update(1_000, null) { listOf(testSnippet(1)) }
        assertEquals(1, outcome.snippets.size)
        assertTrue(!outcome.foldedInForeignWrite, "a first write reported a foreign write it could not have seen")
        assertEquals(1, s.onDisk().size)
    }

    /** `ReviewRegressionTests.aMissingLibraryIsReportedAsMissingNotAsEmpty`. */
    @Test
    fun aMissingLibraryIsReportedAsMissingNotAsEmpty() = sandbox("missing-vs-empty") { s ->
        val missing = s.writer().read()
        assertTrue(!missing.fileExisted && missing.snippets.isEmpty())
        s.put(emptyList())
        val empty = s.writer().read()
        assertTrue(empty.fileExisted, "an empty ARRAY is a real file and a real statement")
        assertTrue(empty.snippets.isEmpty())
        assertNotEquals(missing, empty)
    }

    /** `ReviewRegressionTests.anUnreadableButPresentLibraryThrowsRatherThanPresentingAsEmpty`. */
    @Test
    fun anUnreadableButPresentLibraryThrowsRatherThanPresentingAsEmpty() = sandbox("unreadable") { s ->
        s.put(listOf(testSnippet(1)))
        Files.setPosixFilePermissions(s.library.toPath(), emptySet())
        try {
            if (s.library.canRead()) return@sandbox // running as root: meaningless
            val failure = assertFailsWith<LibraryWriter.Failure.Unreadable> { s.writer().read() }
            assertEquals(LibraryWriter.Failure.Unreadable.Reason.IO, failure.reason)
            assertFailsWith<LibraryWriter.Failure.Unreadable> { s.writer().update(1_000, null) { emptyList() } }
        } finally {
            Files.setPosixFilePermissions(s.library.toPath(), setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE))
        }
        assertEquals(1, s.onDisk().size)
    }

    /** `ReviewRegressionTests.aWriteThatRacesAPeerRetriesAndFoldsThePeersRecordIn`. */
    @Test
    fun aWriteThatRacesAPeerRetriesAndFoldsThePeersRecordIn() = sandbox("race") { s ->
        val mine = testSnippet(1, "mine")
        val theirs = testSnippet(2, "theirs")
        s.put(emptyList())
        var injected = false
        val outcome = s.writer().update(1_000, null) { onDisk ->
            if (!injected) {
                injected = true
                // A writer that bypasses the guard, between this read and the write.
                Files.write(s.library.toPath(), SnippetLibraryCodec.encode(listOf(theirs)))
            }
            onDisk.snippets + mine
        }
        assertTrue(outcome.attempts > 1, "the racing write must have forced a retry")
        assertEquals(setOf("mine", "theirs"), s.onDisk().map { it.name }.toSet(), "neither writer's record may be lost")
    }

    @Test
    fun aPeerThatLandsRightAfterOurWriteIsDetectedAndFoldedIn() = sandbox("race-after") { s ->
        s.put(emptyList())
        val io = FaultInjectingIo()
        var injected = false
        io.afterMutation = { _, file ->
            if (file == s.library && !injected) {
                injected = true
                // A writer that bypasses the guard, right after our rename: the confirming read sees it.
                Files.write(s.library.toPath(), SnippetLibraryCodec.encode(listOf(testSnippet(2, "theirs"))))
            }
        }
        val outcome = s.writer(io).update(1_000, null) { it.snippets + testSnippet(1, "mine") }
        assertEquals(2, outcome.attempts)
        assertEquals(setOf("mine", "theirs"), s.onDisk().map { it.name }.toSet())
    }

    @Test
    fun aBusyGuardRunsNothingAndWritesNothing() = sandbox("busy") { s ->
        val held = s.locations.guard.acquire(1_000)!!
        try {
            var ran = false
            assertFailsWith<LibraryWriter.Failure.Busy> { s.writer().update(20, null) { ran = true; emptyList() } }
            assertFailsWith<LibraryWriter.Failure.Busy> { s.writer().replaceQuarantinedPrimary(emptyList(), 20, null) }
            assertTrue(!ran)
        } finally {
            held.close()
        }
        assertTrue(!s.library.exists())
    }

    @Test
    fun aFailedWriteKeepsTheOldBytesAndTheGeneration() = sandbox("write-failed") { s ->
        s.seed(3)
        s.writer().update(1_000, null) { listOf(testSnippet(1)) }
        val before = Files.readAllBytes(s.library.toPath())
        val io = FaultInjectingIo().apply { fail = { _, file -> file.name == "snippets.json" } }
        val failure = assertFailsWith<LibraryWriter.Failure.WriteFailed> { s.writer(io).update(1_000, null) { emptyList() } }
        assertEquals(LibraryWriter.Failure.WriteFailed.Step.WRITE, failure.step)
        assertContentEquals(before, Files.readAllBytes(s.library.toPath()))
        assertEquals(4L, s.state()?.generation)
    }

    @Test
    fun aTimestampJsonCannotSpellIsAnEncodingFailureBeforeAnyWrite() = sandbox("not-encodable") { s ->
        val failure = assertFailsWith<LibraryWriter.Failure.WriteFailed> {
            s.writer().update(1_000, null) { listOf(testSnippet(1).copy(updatedAt = Double.NaN)) }
        }
        assertEquals(LibraryWriter.Failure.WriteFailed.Step.ENCODE, failure.step)
        assertTrue(!s.library.exists())
    }

    @Test
    fun aCrashAroundTheLibraryWriteLeavesOldOrNewBytesAndAtWorstAnUnrecordedGeneration() = sandbox("crash") { s ->
        val old = listOf(testSnippet(1))
        val new = listOf(testSnippet(1), testSnippet(2))
        // Mutations: 1 the library, 2 the generation in state.json.
        for (step in 1..2) for (after in listOf(false, true)) {
            s.put(old)
            s.seed(5)
            val io = FaultInjectingIo().apply { if (after) crashAfter = step else crashBefore = step }
            assertFailsWith<SimulatedCrash> { s.writer(io).update(1_000, null) { new } }
            assertTrue(!s.locations.guard.isHeld)
            val libraryLanded = step == 2 || after
            assertEquals(if (libraryLanded) new else old, s.onDisk(), "step $step after=$after")
            assertEquals(if (step == 2 && after) 6L else 5L, s.state()?.generation, "step $step after=$after")
        }
    }

    // The generation counter

    @Test
    fun aCooperatingWriteAdvancesTheGenerationByOneAndRecordsTheBytesItWrote() = sandbox("generation-one") { s ->
        s.seed(7)
        val outcome = s.writer().update(1_000, null) { listOf(testSnippet(1, "First")) }
        val state = s.state()!!
        assertEquals(8L, state.generation)
        assertEquals(outcome.digest, state.librarySha256)
        assertEquals(TEST_DEVICE, state.deviceId, "a library write has no business touching the identity")
    }

    @Test
    fun aWriteOverSomebodyElsesBytesAdvancesTheGenerationTwiceToLeaveAGap() = sandbox("generation-gap") { s ->
        s.seed(7)
        s.writer().update(1_000, null) { listOf(testSnippet(1, "First")) }
        assertEquals(8L, s.state()?.generation)
        AtomicFileWriter.write(SnippetLibraryCodec.encode(listOf(testSnippet(2, "Stranger"))), s.library, s.tmp)
        s.writer().update(1_000, null) { it.snippets + testSnippet(3, "Third") }
        assertEquals(10L, s.state()?.generation, "a foreign write between two cooperating writes must leave a detectable gap")
    }

    @Test
    fun aWriteThatChangesNothingLeavesTheGenerationAlone() = sandbox("generation-noop") { s ->
        s.seed(7)
        s.writer().update(1_000, null) { listOf(testSnippet(1, "First")) }
        val afterFirst = s.state()
        assertEquals(8L, afterFirst?.generation)
        s.writer().update(1_000, null) { it.snippets }
        assertEquals(afterFirst, s.state(), "an identity transform moved the generation counter")
    }

    @Test
    fun theGenerationCounterIsWrittenThroughTheInjectedTemporaryDirectory() = sandbox("generation-staging") { s ->
        s.seed(0)
        val staging = File(s.locations.root, "Staging")
        LibraryWriter(s.library, SyncStateFile(s.stateFile, s.locations.guard, staging), s.locations.guard, staging)
            .update(1_000, null) { listOf(testSnippet(1, "First")) }
        assertEquals(1L, s.state()?.generation, "the generation was not recorded at all")
        assertTrue(staging.isDirectory)
        assertEquals(emptyList(), entriesOf(staging), "a staged temporary file survived the write")
        assertEquals(emptyList(), entriesOf(s.locations.syncFolder).filter { it.startsWith("state.json.") })
    }

    @Test
    fun aMissingStateIsNeverCreatedByALibraryWrite() = sandbox("generation-no-state") { s ->
        s.writer().update(1_000, null) { listOf(testSnippet(1)) }
        assertTrue(!s.stateFile.exists(), "bookkeeping must never stand in for a lost device identity")
    }

    @Test
    fun aLibraryWriteKeepsTheHalt() = sandbox("generation-halt") { s ->
        val halt = Halt(HaltReason.MASS_DELETION, HaltDetail.of("m"), 1.0)
        seedState(s, SyncState(TEST_DEVICE, halt = halt))
        s.writer().update(1_000, null) { listOf(testSnippet(1)) }
        assertEquals(halt, s.state()?.halt)
        assertEquals(1L, s.state()?.generation)
    }

    // Concurrency

    @Test
    fun concurrentWritersThroughTheGuardLoseNoRecord() = sandbox("concurrent") { s ->
        s.seed(0)
        val threads = 6
        val perThread = 15
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(threads)
        try {
            val futures = (0 until threads).map { thread ->
                pool.submit<Unit> {
                    start.await()
                    repeat(perThread) { index ->
                        val snippet = testSnippet(thread * 1_000 + index + 1)
                        while (true) {
                            try {
                                s.writer().update(50, null) { it.snippets + snippet }
                                break
                            } catch (_: LibraryWriter.Failure.Busy) {
                                // The caller retries; it never drops the write.
                            }
                        }
                    }
                }
            }
            start.countDown()
            futures.forEach { it.get(120, TimeUnit.SECONDS) }
        } finally {
            pool.shutdownNow()
        }
        assertEquals(threads * perThread, s.onDisk().map { it.id }.toSet().size)
        assertEquals((threads * perThread).toLong(), s.state()?.generation, "every write advanced the generation once, with no gap")
        assertNull(s.state()?.halt)
    }
}
