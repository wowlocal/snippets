package com.khm.snippets.core.io

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The `AtomicFileWriter` section of `Tests/Core/LibraryWriterTests.swift`. */
class AtomicFileWriterTest {

    private val root: File = Files.createTempDirectory("snippets-atomic").toFile()
    private val library = File(root, "snippets.json")
    private val tmpFolder = File(root, "Tmp")

    @AfterTest
    fun removeSandbox() {
        root.deleteRecursively()
    }

    private fun entries(directory: File): List<String> = directory.list()?.sorted() ?: emptyList()

    private fun mode(file: File): String = PosixFilePermissions.toString(Files.getPosixFilePermissions(file.toPath()))

    private fun digest(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * A single-threaded before/after assertion cannot tell an atomic replace from a plain
     * write loop, so a reader runs across a series of replacements and everything it saw
     * is checked. The payloads differ in length and both states must have been seen.
     */
    @Test
    fun aConcurrentReaderNeverObservesAPartiallyWrittenFile() {
        val shorter = ByteArray(2 shl 20) { 0x41 }
        val longer = ByteArray(3 shl 20) { (it % 251).toByte() }
        val shorterDigest = digest(shorter)
        val longerDigest = digest(longer)

        AtomicFileWriter.write(shorter, library, tmpFolder)

        val seen = Collections.synchronizedSet(HashSet<String>())
        val stopped = AtomicBoolean(false)
        val firstObservation = CountDownLatch(1)
        val reader = Thread {
            while (!stopped.get()) {
                // A read can only fail here if the file vanished, which would be its own failure below.
                seen.add(try { digest(Files.readAllBytes(library.toPath())) } catch (failure: IOException) { "unreadable: $failure" })
                firstObservation.countDown()
            }
        }
        reader.start()
        assertTrue(firstObservation.await(60, TimeUnit.SECONDS), "the reader thread never ran")

        // The deadline only bounds a hang; the verdict is what the reader saw.
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
        var pass = 0
        while (System.nanoTime() < deadline) {
            AtomicFileWriter.write(if (pass % 2 == 0) longer else shorter, library, tmpFolder)
            pass += 1
            if (pass >= 12 && seen.contains(shorterDigest) && seen.contains(longerDigest)) break
        }
        AtomicFileWriter.write(shorter, library, tmpFolder)

        stopped.set(true)
        reader.join(60_000)
        assertFalse(reader.isAlive)

        assertTrue(seen.contains(shorterDigest) && seen.contains(longerDigest), "the reader never straddled a rename in $pass passes")
        assertEquals(setOf(shorterDigest, longerDigest), HashSet(seen), "a reader saw a state that was neither the old nor the new file")
        assertContentEquals(shorter, library.readBytes())
        assertEquals(emptyList(), entries(tmpFolder))
    }

    @Test
    fun writingTightensPermissionsToOwnerOnlyEvenOverAWideOpenExistingFile() {
        library.writeText("stale")
        Files.setPosixFilePermissions(library.toPath(), PosixFilePermissions.fromString("rw-r--r--"))
        assertEquals("rw-r--r--", mode(library))

        AtomicFileWriter.write("fresh".toByteArray(), library, tmpFolder)
        assertEquals("rw-------", mode(library))
        assertEquals("fresh", library.readText())

        // The parameter is honoured, for a caller that wants a shared file.
        val shared = File(root, "shared.json")
        AtomicFileWriter.write("x".toByteArray(), shared, tmpFolder, permissions = 420) // 0644
        assertEquals("rw-r--r--", mode(shared))
        assertEquals(384, AtomicFileWriter.OWNER_READ_WRITE)
    }

    @Test
    fun theWriteStagesInTheGivenTemporaryDirectoryAndLeavesNothingBehind() {
        // A directory that does not exist yet: its later existence shows the writer used it.
        val stagingArea = File(root, "Staging")
        assertFalse(stagingArea.exists())

        AtomicFileWriter.write("body".toByteArray(), library, stagingArea)

        assertTrue(stagingArea.isDirectory)
        assertEquals(emptyList(), entries(stagingArea), "a temporary file survived a successful write")
        assertEquals(listOf("Staging", "snippets.json"), entries(root))
    }

    /** A successful rename is not yet a durable write: the failed fence must reach the caller. */
    @Test
    fun aDirectorySyncFailurePropagatesAfterTheRename() {
        val replacement = "replacement already renamed into place".toByteArray()
        var synchronizedDirectory: File? = null

        val failure = assertFailsWith<AtomicFileWriter.Failure.DirectorySyncFailed> {
            AtomicFileWriter.write(replacement, library, tmpFolder, directorySync = { directory ->
                synchronizedDirectory = directory
                throw AtomicFileWriter.Failure.DirectorySyncFailed(directory.path, IOException("injected"))
            })
        }

        assertEquals(root.absoluteFile, synchronizedDirectory)
        assertEquals(root.absolutePath, failure.path)
        assertContentEquals(replacement, library.readBytes(), "the rename may precede the failed directory sync")
        assertEquals(emptyList(), entries(tmpFolder))
    }

    @Test
    fun aFailedWriteLeavesTheOldContentsIntactAndNoTemporaryFileBehind() {
        // The destination is a non-empty directory, so only the rename can fail: the
        // window in which a temporary file exists and could be orphaned.
        val occupied = File(root, "occupied")
        assertTrue(File(occupied, "inside").mkdirs())

        assertFailsWith<AtomicFileWriter.Failure.RenameFailed> {
            AtomicFileWriter.write("body".toByteArray(), occupied, tmpFolder)
        }
        assertEquals(emptyList(), entries(tmpFolder), "a failed write orphaned its temporary file")
        assertTrue(File(occupied, "inside").isDirectory)

        // A staging directory that cannot exist fails before anything is staged.
        AtomicFileWriter.write("original".toByteArray(), library, tmpFolder)
        val blocked = File(root, "not-a-directory")
        blocked.writeBytes(ByteArray(0))

        val failure = assertFailsWith<AtomicFileWriter.Failure.CannotCreateTemporary> {
            AtomicFileWriter.write("replacement".toByteArray(), library, blocked)
        }
        assertEquals(blocked.path, failure.directory)
        assertEquals("original", library.readText())
        assertEquals(emptyList(), entries(tmpFolder))
    }

    @Test
    fun anEmptyPayloadAndALargeOneAreBothWrittenWhole() {
        AtomicFileWriter.write(ByteArray(0), library, tmpFolder)
        assertEquals(0L, library.length())
        val large = ByteArray(5_000_003) { (it * 31).toByte() }
        AtomicFileWriter.write(large, library, tmpFolder)
        assertContentEquals(large, library.readBytes())
    }

    @Test
    fun theDefaultDirectorySyncWorksOnThisPlatform() {
        AtomicFileWriter.synchronizeDirectory(root)
        assertFailsWith<AtomicFileWriter.Failure.DirectorySyncFailed> {
            AtomicFileWriter.synchronizeDirectory(File(root, "missing"))
        }
    }

    /** `durableRemovalIsIdempotent` in `ReviewRegressionTests.swift`. */
    @Test
    fun durableRemovalIsIdempotent() {
        library.writeText("x")
        AtomicFileWriter.removeDurablyIfPresent(library)
        assertFalse(library.exists())
        AtomicFileWriter.removeDurablyIfPresent(library)

        // Something that cannot be unlinked is an error, not "already gone".
        val folder = File(root, "folder")
        assertTrue(File(folder, "child").mkdirs())
        assertFailsWith<AtomicFileWriter.Failure.RemoveFailed> { AtomicFileWriter.removeDurablyIfPresent(folder) }
        assertTrue(folder.isDirectory)
    }

    /** Many writers through one guard: every write lands whole and the count adds up. */
    @Test
    fun concurrentWritersThroughTheGuardNeverLoseAnUpdate() {
        val locations = StorageLocations(root)
        locations.createAllDirectories()
        val guard = locations.guard
        val counter = File(locations.syncFolder, "counter")
        AtomicFileWriter.write("0".toByteArray(), counter, locations.tmpFolder)

        val writers = 8
        val rounds = 40
        val failures = Collections.synchronizedList(ArrayList<Throwable>())
        val threads = (0 until writers).map {
            Thread {
                try {
                    repeat(rounds) {
                        guard.withLock(30_000) {
                            val value = counter.readText().toInt()
                            AtomicFileWriter.write((value + 1).toString().toByteArray(), counter, locations.tmpFolder)
                        }
                    }
                } catch (failure: Throwable) {
                    failures.add(failure)
                }
            }
        }
        threads.forEach(Thread::start)
        threads.forEach { it.join(120_000) }

        assertEquals(emptyList(), failures)
        assertEquals(writers * rounds, counter.readText().toInt())
        assertEquals(emptyList(), entries(locations.tmpFolder))
        assertFalse(guard.isHeld)
    }
}
