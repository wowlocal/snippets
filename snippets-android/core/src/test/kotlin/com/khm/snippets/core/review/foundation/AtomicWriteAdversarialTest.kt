package com.khm.snippets.core.review.foundation

import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.io.AtomicFileWriter
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Review: `AtomicFileWriter`, `FileRead` and `LibraryGuard` against what the Swift
 * originals do in the same situations. Swift's answers come from a scratch probe that
 * links the real `AtomicFileWriter.swift` and `SnippetLibraryCodec.swift` (`io/main.swift`).
 */
class AtomicWriteAdversarialTest {

    private val root: File = Files.createTempDirectory("review-atomic").toFile()
    private val tmp = File(root, "Tmp")

    @AfterTest
    fun cleanUp() {
        Thread.interrupted()
        root.walkBottomUp().forEach { it.setWritable(true); it.setReadable(true) }
        root.deleteRecursively()
    }

    private fun mode(file: File): String = PosixFilePermissions.toString(Files.getPosixFilePermissions(file.toPath()))

    private fun leftovers(): List<String> = tmp.list()?.sorted() ?: emptyList()

    // Defects: these fail by design.

    /**
     * Swift loops on `EINTR` ("Looping is not defensive programming here; it is the
     * contract"): a signal never fails a save. `FileChannel` is an interruptible channel:
     * with the thread's interrupt flag set (a cancelled `runInterruptible` block, a
     * `Future.cancel(true)`, an executor's `shutdownNow`, a stopped worker) the first
     * write closes the channel and throws, so the save that a stopping component makes
     * last is the one that is lost.
     */
    @Test
    fun aThreadWithItsInterruptFlagSetCanStillSaveTheLibrary() {
        val destination = File(root, "snippets.json")
        AtomicFileWriter.write("old".toByteArray(), destination, tmp)
        Thread.currentThread().interrupt()
        try {
            AtomicFileWriter.write("new".toByteArray(), destination, tmp)
        } catch (failure: AtomicFileWriter.Failure) {
            Thread.interrupted()
            fail(
                "an interrupted thread could not save: ${failure.javaClass.simpleName} caused by ${failure.cause?.javaClass?.name}; " +
                    "the file still holds \"${destination.readText()}\", leftovers ${leftovers()}",
            )
        } finally {
            Thread.interrupted()
        }
        assertEquals("new", destination.readText())
    }

    /**
     * The same flag makes the guard report busy although nobody holds it
     * (`Semaphore.tryAcquire(timeout)` throws before looking at the permit).
     */
    @Test
    fun aFreeGuardIsNotBusyForAThreadWithItsInterruptFlagSet() {
        val guard = LibraryGuard.forRoot(root)
        Thread.currentThread().interrupt()
        val held = try {
            guard.acquire(1_000)
        } finally {
            Thread.interrupted()
        }
        assertNotNull(held, "the guard was free, yet acquire() answered busy")
        held.close()
    }

    /**
     * Swift: `fchmod` on the open descriptor, so any result mode can be written
     * (0400, 0444 and even 0000 succeed, and can be overwritten). Here the mode is set on
     * the path before the file is opened for writing, so a mode without owner-write cannot
     * be written at all.
     */
    @Test
    fun aResultModeWithoutOwnerWriteCanBeWrittenAndOverwritten() {
        val failures = ArrayList<String>()
        for ((bits, text) in listOf(256 to "r--------", 292 to "r--r--r--", 128 to "-w-------")) {
            val destination = File(root, "mode-$bits.json")
            try {
                AtomicFileWriter.write("x".toByteArray(), destination, tmp, permissions = bits)
                AtomicFileWriter.write("y".toByteArray(), destination, tmp, permissions = bits)
                if (mode(destination) != text) failures.add("$text: mode on disk is ${mode(destination)}")
            } catch (failure: AtomicFileWriter.Failure) {
                failures.add("$text: ${failure.javaClass.simpleName} (${failure.cause?.javaClass?.simpleName})")
            }
        }
        assertEquals(emptyList(), leftovers(), "temporary files left behind")
        assertTrue(failures.isEmpty(), "Swift writes every one of these: $failures")
    }

    // Behaviour that matches Swift: these pass.

    @Test
    fun failuresPastTheTemporaryFileLeaveNothingBehindAndKeepTheOldContents() {
        val destination = File(root, "snippets.json")
        AtomicFileWriter.write("old".toByteArray(), destination, tmp)

        // Destination folder missing: Swift renameFailed(ENOENT).
        assertFailsWith<AtomicFileWriter.Failure.RenameFailed> {
            AtomicFileWriter.write("x".toByteArray(), File(root, "no/such/f.json"), tmp)
        }
        // Destination is a directory: Swift renameFailed(EISDIR).
        val directory = File(root, "adir").apply { mkdirs() }
        assertFailsWith<AtomicFileWriter.Failure.RenameFailed> {
            AtomicFileWriter.write("x".toByteArray(), directory, tmp)
        }
        assertTrue(directory.isDirectory)
        // Staging folder is a file: Swift cannotCreateTemporary(ENOTDIR).
        assertFailsWith<AtomicFileWriter.Failure.CannotCreateTemporary> {
            AtomicFileWriter.write("x".toByteArray(), File(root, "z.json"), destination)
        }
        assertEquals(emptyList(), leftovers())
        assertEquals("old", destination.readText())

        // Removal: missing is success; a missing parent is a directory-sync failure in Swift too.
        AtomicFileWriter.removeDurablyIfPresent(File(root, "never.json"))
        assertFailsWith<AtomicFileWriter.Failure.DirectorySyncFailed> {
            AtomicFileWriter.removeDurablyIfPresent(File(root, "no/never.json"))
        }
    }

    @Test
    fun readingTellsMissingFromUnreadableExactlyWhereSwiftDoes() {
        val plain = File(root, "plain.json").apply { writeText("[]") }
        // Swift: nil (missing).
        assertIs<FileRead.Missing>(FileRead.read(File(root, "nope/snippets.json")))
        val dangling = File(root, "dangling.json")
        Files.createSymbolicLink(dangling.toPath(), File(root, "gone").toPath())
        assertIs<FileRead.Missing>(FileRead.read(dangling))
        // Swift: throws (NSCocoaErrorDomain 256 or 258), never an empty library.
        assertIs<FileRead.Unreadable>(FileRead.read(File(plain, "child.json")), "parent is a file")
        assertIs<FileRead.Unreadable>(FileRead.read(root), "a directory")
        val loop = File(root, "loop.json")
        Files.createSymbolicLink(loop.toPath(), loop.toPath())
        assertIs<FileRead.Unreadable>(FileRead.read(loop), "a symlink loop")
        assertIs<FileRead.Unreadable>(FileRead.read(File(root, "a".repeat(300) + ".json")), "name too long")
        // An empty file exists and is not a library.
        val empty = File(root, "empty.json").apply { writeBytes(ByteArray(0)) }
        assertIs<SnippetLibraryCodec.ReadResult.Undecodable>(SnippetLibraryCodec.read(empty))
        assertIs<SnippetLibraryCodec.ReadResult.Unreadable>(SnippetLibraryCodec.read(File(plain, "child.json")))
    }

    /** An interrupt that lands while a large write is in flight must leave the old or the new file, whole, and no temporary. */
    @Test
    fun anInterruptInTheMiddleOfAWriteLeavesAWholeFileAndNoTemporary() {
        val destination = File(root, "big.bin")
        val old = ByteArray(1 shl 20) { 1 }
        val new = ByteArray(48 shl 20) { 2 }
        AtomicFileWriter.write(old, destination, tmp)
        repeat(6) { round ->
            val started = CountDownLatch(1)
            var failure: Throwable? = null
            val writer = thread {
                started.countDown()
                try {
                    AtomicFileWriter.write(new, destination, tmp)
                } catch (thrown: Throwable) {
                    failure = thrown
                }
            }
            started.await()
            Thread.sleep(1L + round * 3)
            writer.interrupt()
            writer.join(60_000)
            val now = destination.readBytes()
            assertTrue(now.contentEquals(old) || now.contentEquals(new), "round $round: the file is neither the old nor the new contents (${now.size} bytes)")
            assertEquals(emptyList(), leftovers(), "round $round after ${failure?.javaClass?.simpleName}")
            if (now.contentEquals(new)) AtomicFileWriter.write(old, destination, tmp)
        }
    }

    @Test
    fun unguardedConcurrentWritersLeaveOneWholePayloadAndNoTemporary() {
        val destination = File(root, "race.json")
        val payloads = (0 until 8).map { index -> ByteArray(200_000) { (index + 1).toByte() } }
        val start = CountDownLatch(1)
        val writers = payloads.map { payload ->
            thread {
                start.await()
                repeat(25) { AtomicFileWriter.write(payload, destination, tmp) }
            }
        }
        start.countDown()
        writers.forEach { it.join(60_000) }
        val result = destination.readBytes()
        assertTrue(payloads.any { it.contentEquals(result) }, "the file is a mixture")
        assertEquals("rw-------", mode(destination))
        assertEquals(emptyList(), leftovers())
    }

    // LibraryGuard

    @Test
    fun waitersGetTheGuardInArrivalOrderAndAReentrantAcquireTimesOut() {
        val guard = LibraryGuard.forRoot(File(root, "fair"))
        val first = assertNotNull(guard.acquire(0))
        assertEquals(null, guard.acquire(50), "the lock is not reentrant, like a second flock on a new descriptor")
        val order = java.util.Collections.synchronizedList(ArrayList<Int>())
        val waiters = (0 until 6).map { index ->
            val waiter = thread {
                guard.withLock(30_000) { order.add(index) }
            }
            // Let each waiter queue before the next one starts.
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (waiter.state != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) Thread.sleep(1)
            waiter
        }
        first.close()
        first.close()
        waiters.forEach { it.join(30_000) }
        assertEquals((0 until 6).toList(), order)
        assertEquals(false, guard.isHeld)
        // A late arrival does not barge past a queue with a zero timeout, and gets it once the queue is empty.
        guard.acquire(0)!!.close()
        assertContentEquals(listOf(true), listOf(LibraryGuard.forRoot(File(root, "fair/../fair")) === guard))
    }
}
