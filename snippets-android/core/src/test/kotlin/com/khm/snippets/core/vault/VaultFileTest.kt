package com.khm.snippets.core.vault

import org.junit.Test
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The locked update loop of `VaultFile.update`: the read inside the lock, the
 * compare-and-swap on the file's bytes, the read-back verification, and what happens when
 * a writer that does not hold the lock interferes.
 */
class VaultFileTest {

    private fun named(index: Int) = record(index, name = "record $index", keyword = "kw$index")

    @Test fun updateCreatesTheVaultWhenThereIsNoneAndPassesNullToTheTransform() {
        val scratch = Scratch("update-create")
        try {
            var seen: VaultDocument? = document()
            val written = scratch.vaultFile().update(1000) { existing ->
                seen = existing
                document(records = emptyList())
            }
            assertNull(seen)
            assertEquals(document(records = emptyList()), written)
            assertContentEquals(VaultFile.encode(written), scratch.bytes())
        } finally {
            scratch.destroy()
        }
    }

    /** A caller's copy from a moment ago may be stale: the transform always sees what is on disk now. */
    @Test fun updateReadsInsideTheLockSoAStaleCopyCannotOverwriteANewerRecord() {
        val scratch = Scratch("update-stale")
        try {
            val file = scratch.vaultFile()
            file.write(document(records = listOf(named(0))))
            // Somebody else adds a record after this caller last looked.
            file.write(document(records = listOf(named(0), named(1))))

            val updated = file.update(1000) { existing -> existing!!.copy(records = existing.records + named(2)) }

            assertEquals(listOf(id(0), id(1), id(2)), updated.records.map { it.id })
            assertEquals(updated, file.load().valueOrNull)
        } finally {
            scratch.destroy()
        }
    }

    /**
     * A writer that does not take the lock changes the file between this attempt's read
     * and its write. The attempt must not write; the next one folds the change in.
     */
    @Test fun aWriteThatRacesTheCompareAndSwapIsFoldedInNotClobbered() {
        val scratch = Scratch("update-cas")
        try {
            val file = scratch.vaultFile()
            file.write(document(records = listOf(named(0))))

            var attempts = 0
            val updated = file.update(1000) { existing ->
                attempts += 1
                if (attempts == 1) {
                    // Outside the lock, behind this attempt's back.
                    Files.write(scratch.vault.toPath(), VaultFile.encode(document(records = listOf(named(0), named(7)))))
                }
                existing!!.copy(records = existing.records + named(2))
            }

            assertEquals(2, attempts)
            assertEquals(listOf(id(0), id(7), id(2)), updated.records.map { it.id }, "the racing writer's record was lost")
            assertEquals(updated, file.load().valueOrNull)
        } finally {
            scratch.destroy()
        }
    }

    /** The write is verified by reading the bytes back: a writer that replaces the file right after the rename is noticed. */
    @Test fun aWriteThatIsReplacedImmediatelyAfterwardsIsNoticedByTheReadBack() {
        val scratch = Scratch("update-readback")
        try {
            val io = FaultyIo()
            val file = scratch.vaultFile(io)
            file.write(document(records = listOf(named(0))))

            var interfered = false
            io.afterWrite = { destination ->
                if (!interfered && destination == scratch.vault) {
                    interfered = true
                    Files.write(scratch.vault.toPath(), VaultFile.encode(document(records = listOf(named(0), named(8)))))
                }
            }
            var attempts = 0
            val updated = file.update(1000) { existing ->
                attempts += 1
                existing!!.copy(records = existing.records + named(2))
            }

            assertEquals(2, attempts)
            assertEquals(listOf(id(0), id(8), id(2)), updated.records.map { it.id })
        } finally {
            scratch.destroy()
        }
    }

    @Test fun aFileThatChangesUnderEveryAttemptFailsAfterEightAndLeavesTheOtherWritersBytes() {
        val scratch = Scratch("update-exhausted")
        try {
            val file = scratch.vaultFile()
            file.write(document(records = listOf(named(0))))

            var attempts = 0
            val failure = assertFailsWith<VaultFileError.WriteFailed> {
                file.update(1000) { existing ->
                    attempts += 1
                    Files.write(scratch.vault.toPath(), VaultFile.encode(document(records = listOf(named(100 + attempts)))))
                    existing!!
                }
            }
            assertEquals(8, attempts)
            assertTrue(failure.detail.contains("changed under every write attempt"))
            assertEquals(listOf(id(108)), file.load().valueOrNull!!.records.map { it.id })
        } finally {
            scratch.destroy()
        }
    }

    /** Many writers through the lock: every record arrives exactly once and the file is never torn. */
    @Test fun concurrentWritersThroughTheLockLoseNothing() {
        val scratch = Scratch("update-concurrent")
        try {
            val file = scratch.vaultFile()
            file.write(document(records = emptyList()))

            val writers = 8
            val perWriter = 12
            val pool = Executors.newFixedThreadPool(writers)
            val start = CountDownLatch(1)
            val failures = java.util.Collections.synchronizedList(ArrayList<Throwable>())
            for (writer in 0 until writers) {
                pool.execute {
                    start.await()
                    for (item in 0 until perWriter) {
                        try {
                            // Each writer has its own VaultFile, as independent components do; the guard is per root.
                            scratch.vaultFile().update(30_000) { existing ->
                                existing!!.copy(records = existing.records + named(writer * 100 + item))
                            }
                        } catch (failure: Throwable) {
                            failures.add(failure)
                        }
                    }
                }
            }
            start.countDown()
            pool.shutdown()
            assertTrue(pool.awaitTermination(120, TimeUnit.SECONDS))

            assertEquals(emptyList(), failures)
            val ids = file.load().valueOrNull!!.records.map { it.id }
            assertEquals(writers * perWriter, ids.size)
            assertEquals(writers * perWriter, ids.toSet().size)
        } finally {
            scratch.destroy()
        }
    }

    @Test fun aBusyLockIsReportedAndNothingRuns() {
        val scratch = Scratch("update-busy")
        try {
            val held = scratch.locations.guard.acquire(1000)!!
            try {
                var ran = false
                val failure = assertFailsWith<VaultFileError.WriteFailed> {
                    scratch.vaultFile().update(50) {
                        ran = true
                        document()
                    }
                }
                assertFalse(ran)
                assertTrue(failure.detail.contains("try again"))
                assertNull(scratch.bytes())
            } finally {
                held.close()
            }
            // And the lock is released by update on every path, including a throwing transform.
            assertFailsWith<IllegalStateException> { scratch.vaultFile().update(50) { error("boom") } }
            scratch.vaultFile().update(50) { document() }
        } finally {
            scratch.destroy()
        }
    }

    @Test fun aFailedWriteLeavesTheOldVaultAndNoDebris() {
        val scratch = Scratch("update-write-fails")
        try {
            val io = FaultyIo()
            val file = scratch.vaultFile(io)
            file.write(document(records = listOf(named(0))))
            val before = scratch.bytes()

            io.beforeWrite = { _, _ -> throw IOException("disk full") }
            assertFailsWith<VaultFileError.WriteFailed> { file.update(1000) { it!!.copy(records = emptyList()) } }
            assertFailsWith<VaultFileError.WriteFailed> { file.write(document(records = emptyList())) }

            assertContentEquals(before, scratch.bytes())
            assertEquals(listOf("vault.json"), entries(scratch.locations.vaultFolder))
            assertEquals(emptyList(), entries(scratch.locations.tmpFolder))
        } finally {
            scratch.destroy()
        }
    }

    /** An unreadable vault is never "no vault": the transform does not even run. */
    @Test fun updateRefusesAnUnreadableOrNewerVaultWithoutRunningTheTransform() {
        val scratch = Scratch("update-refused")
        try {
            val io = FaultyIo()
            val file = scratch.vaultFile(io)
            file.write(document())
            var ran = false

            io.beforeRead = { throw IOException("permission denied") }
            assertFailsWith<VaultFileError.WriteRefused> {
                file.update(1000) {
                    ran = true
                    document()
                }
            }
            io.beforeRead = {}

            scratch.put("""{"schemaVersion": 7, "anything": true}""")
            val bytes = scratch.bytes()
            assertFailsWith<VaultFileError.WriteRefused> {
                file.update(1000) {
                    ran = true
                    document()
                }
            }
            assertFalse(ran)
            assertContentEquals(bytes, scratch.bytes())
        } finally {
            scratch.destroy()
        }
    }

    /** What the vault file reports never includes a record's name or body, only paths and kinds of failure. */
    @Test fun errorTextNamesNoContents() {
        val scratch = Scratch("errors")
        try {
            scratch.put("""{"schemaVersion":1,"kid":"k","vaultSalt":"s","kdf":{"alg":"a","iterations":1,"saltP":"p"},
                "records":[{"id":"not-a-uuid","name":"TOP SECRET NAME","sealed":"s"}]}""")
            val failure = scratch.vaultFile().load().failure!!
            assertFalse(failure.message!!.contains("TOP SECRET NAME"))
            assertTrue(failure.message!!.contains("vault.json"))
        } finally {
            scratch.destroy()
        }
    }
}
