package com.khm.snippets.core.io

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** `ClockAndStateTests.Layout` ("Storage layout"), plus the lock and the three-way file read. */
class StorageAndGuardTest {

    private val root: File = Files.createTempDirectory("snippets-layout").toFile()
    private val locations = StorageLocations(File(root, "SnippetsClone"))

    @AfterTest
    fun removeSandbox() {
        root.deleteRecursively()
    }

    private val files: List<Pair<String, File>> = listOf(
        "Sync/state.json" to locations.syncStateFile,
        "Sync/library-quarantine" to locations.libraryQuarantineMarkerFile,
        "Sync/provider-switch.json" to locations.syncProviderSwitchFile,
        "Sync/library-metadata.json" to locations.syncLibraryMetadataFile,
        "Vault/vault.json" to locations.vaultFile,
    )

    private val folders: List<Pair<String, File>> = listOf(
        "Sync" to locations.syncFolder,
        "Sync/Quarantine" to locations.syncQuarantineFolder,
        "Sync/Providers" to locations.syncProvidersFolder,
        "Vault" to locations.vaultFolder,
        "Diagnostics" to locations.diagnosticsFolder,
        "Diagnostics/Logs" to locations.diagnosticsLogsFolder,
        "Backups" to locations.backupsFolder,
        "Tmp" to locations.tmpFolder,
    )

    private fun below(file: File): String = file.relativeTo(locations.root).invariantSeparatorsPath

    // Layout

    @Test
    fun noSubsystemWritesAFileDirectlyIntoTheSupportFolder() {
        for ((label, file) in files) {
            assertEquals(label, below(file))
            assertTrue(label.count { it == '/' } >= 1, "$label must be inside a subdirectory")
        }
        // The exception, stated once and on purpose.
        assertEquals("snippets.json", below(locations.snippetsFile))
        for ((label, folder) in folders) assertEquals(label, below(folder))

        // No two subsystems may share a path.
        val everything = files.map { it.second } + folders.map { it.second } + locations.snippetsFile + locations.root
        assertEquals(everything.size, everything.toSet().size)
    }

    @Test
    fun everyFileLivesInADirectoryThatCreateAllDirectoriesPromisesToCreate() {
        val created = locations.folders.toSet()
        assertEquals((folders.map { it.second } + locations.root).toSet(), created)
        for ((label, file) in files) assertTrue(file.parentFile in created, "nothing creates the directory for $label")
        assertTrue(locations.snippetsFile.parentFile in created)
    }

    @Test
    fun createAllDirectoriesCreatesEverythingItPromisesAndIsIdempotent() {
        assertFalse(locations.root.exists())
        locations.createAllDirectories()
        for (folder in locations.folders) assertTrue(folder.isDirectory, "$folder was never created")
        // Exactly the promised folders, and no file.
        val found = locations.root.walkTopDown().toSet()
        assertEquals(locations.folders.toSet(), found)

        locations.createAllDirectories()
        assertEquals(found, locations.root.walkTopDown().toSet())
    }

    @Test
    fun providerLocationsIsolateEachProvidersState() {
        val first = assertNotNull(locations.protocolLocations("a".repeat(32)))
        val second = assertNotNull(locations.protocolLocations("b".repeat(32)))
        assertEquals("http-" + "a".repeat(32), first.identifier)
        assertEquals("Sync/Providers/" + "a".repeat(32), below(first.folder))
        assertNotEquals(first.baseFile, second.baseFile)
        assertEquals(first.folder, first.baseFile.parentFile)
        assertEquals(first.folder, first.journalFile.parentFile)
        assertEquals(first.folder, first.quarantineFolder.parentFile)
        assertEquals(first.folder, first.switchReceiptFile.parentFile)
        assertEquals(listOf("base.json", "journal.json", "Quarantine", "switch-receipt.json"),
            listOf(first.baseFile, first.journalFile, first.quarantineFolder, first.switchReceiptFile).map { it.name })

        // The key is lowercased, and nothing but 32 hex digits is a key.
        assertEquals(first, locations.protocolLocations("A".repeat(32)))
        assertNull(locations.protocolLocations("../icloud"))
        assertNull(locations.protocolLocations("a".repeat(31)))
        assertNull(locations.protocolLocations("a".repeat(33)))
        assertNull(locations.protocolLocations("g".repeat(32)))
        assertNull(locations.protocolLocations("a".repeat(31) + "/"))
        assertNull(locations.protocolLocations("１".repeat(32)))
        assertNull(locations.protocolLocations(""))
    }

    @Test
    fun providerFoldersAreCreatedOwnerOnly() {
        val provider = assertNotNull(locations.protocolLocations("0123456789abcdef".repeat(2)))
        provider.createDirectories()
        provider.createDirectories()
        for (folder in listOf(provider.folder, provider.quarantineFolder)) {
            assertTrue(folder.isDirectory)
            assertEquals("rwx------", PosixFilePermissions.toString(Files.getPosixFilePermissions(folder.toPath())))
        }
    }

    // The guard

    @Test
    fun oneRootHasOneGuardHoweverItIsSpelled() {
        locations.createAllDirectories()
        val guard = locations.guard
        assertSame(guard, StorageLocations(File(locations.root, "Sync/..")).guard)
        assertSame(guard, LibraryGuard.forRoot(File(locations.root.path + File.separator)))
        assertNotSame(guard, LibraryGuard.forRoot(File(root, "another-root")))
    }

    /** `aHeldLockMakesAnotherAcquireTimeOutInsteadOfHanging`, without the second process. */
    @Test
    fun aHeldLockMakesAnotherAcquireTimeOutInsteadOfHanging() {
        val guard = locations.guard
        val held = assertNotNull(guard.acquire(1_000))
        assertTrue(guard.isHeld)

        val started = System.nanoTime()
        assertNull(guard.acquire(150), "a second acquire must report busy")
        // Not reentrant: the holder's own thread is refused too, and the body never runs.
        var bodyRan = false
        assertFailsWith<LibraryGuard.Busy> { guard.withLock(0) { bodyRan = true } }
        assertFalse(bodyRan)
        val waitedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertTrue(waitedMillis in 100..10_000, "waited $waitedMillis ms")

        held.close()
        held.close() // closing twice must not hand out a second permit
        assertFalse(guard.isHeld)
        val again = assertNotNull(guard.acquire(0))
        assertNull(guard.acquire(0))
        again.close()
    }

    @Test
    fun theLockIsMutuallyExclusiveAcrossThreadsAndReleasedWhenTheBodyThrows() {
        val guard = locations.guard
        val inside = AtomicInteger(0)
        val overlaps = AtomicInteger(0)
        val start = CountDownLatch(1)
        val threads = (0 until 6).map {
            Thread {
                start.await()
                repeat(200) {
                    guard.withLock(30_000) {
                        if (inside.incrementAndGet() != 1) overlaps.incrementAndGet()
                        Thread.yield()
                        inside.decrementAndGet()
                    }
                }
            }
        }
        threads.forEach(Thread::start)
        start.countDown()
        threads.forEach { it.join(60_000) }
        assertEquals(0, overlaps.get())

        assertFailsWith<IllegalStateException> { guard.withLock(0) { error("boom") } }
        assertFalse(guard.isHeld)
        assertEquals(7, guard.withLock(0) { 7 })
    }

    @Test
    fun aLockCanBeReleasedFromAnotherThreadAndAnInterruptIsBusy() {
        val guard = locations.guard
        val held = assertNotNull(guard.acquire(0))
        Thread { held.close() }.also { it.start(); it.join() }
        assertFalse(guard.isHeld)

        val blocker = assertNotNull(guard.acquire(0))
        Thread.currentThread().interrupt()
        assertNull(guard.acquire(5_000))
        assertTrue(Thread.interrupted(), "the interrupt flag must survive")
        blocker.close()
    }

    // Missing, bytes, unreadable

    /** `aMissingLibraryIsReportedAsMissingNotAsEmpty` and `anUnreadableButPresentLibraryThrows…` at the file level. */
    @Test
    fun aMissingFileAnEmptyFileAndAnUnreadableFileAreThreeDifferentThings() {
        locations.createAllDirectories()
        val file = locations.snippetsFile

        assertSame(FileRead.Missing, FileRead.read(file))
        assertSame(FileRead.Missing, FileRead.read(File(locations.root, "no/such/folder/snippets.json")))

        file.writeBytes(ByteArray(0))
        assertEquals(0, assertIs<FileRead.Bytes>(FileRead.read(file)).data.size)
        file.writeBytes(byteArrayOf(1, 2, 3))
        assertContentEquals(byteArrayOf(1, 2, 3), assertIs<FileRead.Bytes>(FileRead.read(file)).data)

        // Present but refused. Swift: NSCocoaErrorDomain 257, not "no such file".
        Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("---------"))
        try {
            if (!Files.isReadable(file.toPath())) assertIs<FileRead.Unreadable>(FileRead.read(file))
        } finally {
            Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-------"))
        }

        // A directory at the path, and a path through a regular file (ENOTDIR): unreadable in Swift too.
        assertIs<FileRead.Unreadable>(FileRead.read(locations.syncFolder))
        assertIs<FileRead.Unreadable>(FileRead.read(File(file, "child.json")))

        // A dangling link is ENOENT, hence missing.
        val link = File(locations.root, "dangling")
        Files.createSymbolicLink(link.toPath(), File(locations.root, "gone").toPath())
        assertSame(FileRead.Missing, FileRead.read(link))
    }
}
