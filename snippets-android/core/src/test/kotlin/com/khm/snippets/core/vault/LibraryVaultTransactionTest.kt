package com.khm.snippets.core.vault

import com.khm.snippets.core.codec.SnippetLibraryCodec
import org.junit.Test
import java.io.IOException
import java.nio.file.Files
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The one critical section over `snippets.json` and `Vault/vault.json`
 * (`LibraryTransaction.swift`), on its own. What it means for promotion and demotion is
 * in `SecureSnippetStoreTest`.
 */
class LibraryVaultTransactionTest {

    private class Fixture(label: String) {
        val scratch = Scratch(label)
        val io = FaultyIo()
        val markers = RecordingMarkers()
        val transaction = LibraryVaultTransaction(scratch.locations, io, markers)

        fun putLibrary(vararg indices: Int) {
            Files.write(scratch.library.toPath(), SnippetLibraryCodec.encode(indices.map { snippet(it) }))
        }

        fun libraryIds() = SnippetLibraryCodec.decode(Files.readAllBytes(scratch.library.toPath())).map { it.id }
    }

    private fun fixture(label: String, block: (Fixture) -> Unit) {
        val fixture = Fixture(label)
        try {
            block(fixture)
        } finally {
            fixture.scratch.destroy()
        }
    }

    @Test fun aBodyThatChangesNothingWritesNothing() = fixture("unchanged") { f ->
        f.putLibrary(1, 2)
        f.scratch.vaultFile().write(document())

        val outcome = f.transaction.perform(1000) { contents ->
            assertTrue(contents.libraryExisted)
            contents.snippets.size to contents.vault?.records?.size
        }

        assertEquals(2 to 2, outcome.value)
        assertFalse(outcome.wroteLibrary)
        assertFalse(outcome.wroteVault)
        assertEquals(1, outcome.attempts)
        assertEquals(emptyList(), f.io.log)
        assertEquals(emptyList(), f.markers.written, "no move, no marker")
    }

    @Test fun onlyTheFileThatChangedIsWritten() = fixture("one-file") { f ->
        f.putLibrary(1)
        f.scratch.vaultFile().write(document())

        val outcome = f.transaction.perform(1000) { it.snippets = it.snippets + snippet(2) }
        assertTrue(outcome.wroteLibrary)
        assertFalse(outcome.wroteVault)
        assertEquals(listOf("write:snippets.json"), f.io.log)
        assertEquals(listOf(id(1), id(2)), f.libraryIds())

        f.io.log.clear()
        f.transaction.perform(1000) { it.vault = it.vault!!.copy(records = emptyList()) }
        assertEquals(listOf("write:vault.json"), f.io.log)
    }

    /** A missing library is a legitimately empty one; a missing vault is "no vault". Neither is created by looking. */
    @Test fun missingFilesAreEmptyNotErrors() = fixture("missing") { f ->
        val outcome = f.transaction.perform(1000) { contents ->
            assertFalse(contents.libraryExisted)
            assertEquals(emptyList(), contents.snippets)
            assertNull(contents.vault)
        }
        assertFalse(outcome.wroteLibrary || outcome.wroteVault)
        assertFalse(f.scratch.library.exists() || f.scratch.vault.exists())
    }

    /** A file that is there and cannot be read or decoded is never an empty library or "no vault": the body does not run. */
    @Test fun unreadableFilesStopTheTransactionBeforeTheBody() = fixture("unreadable") { f ->
        var ran = false
        val body: (LibraryVaultTransaction.Contents) -> Unit = { ran = true }

        Files.write(f.scratch.library.toPath(), "{ not a library".toByteArray())
        assertFailsWith<LibraryVaultTransaction.Failure.LibraryUnreadable> { f.transaction.perform(1000, body) }

        f.putLibrary(1)
        f.io.beforeRead = { if (it == f.scratch.library) throw IOException("permission denied") }
        assertFailsWith<LibraryVaultTransaction.Failure.LibraryUnreadable> { f.transaction.perform(1000, body) }
        f.io.beforeRead = {}

        f.scratch.put("{ not a vault")
        assertFailsWith<LibraryVaultTransaction.Failure.VaultUnreadable> { f.transaction.perform(1000, body) }
        f.scratch.put("""{"schemaVersion": 9}""")
        assertFailsWith<LibraryVaultTransaction.Failure.VaultUnreadable> { f.transaction.perform(1000, body) }
        assertFalse(ran)
    }

    /** Both files are compare-and-swapped before either is touched: a writer that slips in makes the body run again. */
    @Test fun aChangeBehindTheTransactionsBackIsFoldedInOnTheNextAttempt() = fixture("cas") { f ->
        f.putLibrary(1)
        f.scratch.vaultFile().write(document(records = emptyList()))

        var attempts = 0
        val outcome = f.transaction.perform(1000) { contents ->
            attempts += 1
            if (attempts == 1) f.putLibrary(1, 7) // outside the lock
            contents.snippets = contents.snippets + snippet(2)
        }

        assertEquals(2, outcome.attempts)
        assertEquals(listOf(id(1), id(7), id(2)), f.libraryIds(), "the other writer's snippet was lost")

        // A file that changes under every attempt: busy, after twelve tries, with nothing half-applied.
        var tries = 0
        assertFailsWith<LibraryVaultTransaction.Failure.Busy> {
            f.transaction.perform(1000) { contents ->
                tries += 1
                f.scratch.vaultFile().write(document(records = listOf(record(tries))))
                contents.snippets = emptyList()
            }
        }
        assertEquals(12, tries)
        assertEquals(listOf(id(1), id(7), id(2)), f.libraryIds())
    }

    @Test fun aBusyLockRunsNothing() = fixture("busy") { f ->
        val held = f.scratch.locations.guard.acquire(1000)!!
        try {
            var ran = false
            assertFailsWith<LibraryVaultTransaction.Failure.Busy> { f.transaction.perform(50) { ran = true } }
            assertFalse(ran)
        } finally {
            held.close()
        }
        // What a body throws propagates, the lock is released, and nothing is written.
        f.putLibrary(1)
        val before = Files.readAllBytes(f.scratch.library.toPath())
        assertFailsWith<IllegalStateException> {
            f.transaction.perform(50) { contents ->
                contents.snippets = emptyList()
                error("changed my mind")
            }
        }
        assertContentEquals(before, Files.readAllBytes(f.scratch.library.toPath()))
        f.transaction.perform(50) { }
    }

    /**
     * The direction of a move comes from what actually changed owner, not from the
     * marker: a wrong marker cannot select the ordering that could lose the record.
     */
    @Test fun theWriteOrderFollowsTheActualMoveNotTheMarker() = fixture("direction") { f ->
        f.putLibrary(1, 2)
        f.scratch.vaultFile().write(document(records = emptyList()))

        // A promotion mislabelled as a demotion still writes the vault before the source disappears.
        f.transaction.perform(1000) { contents ->
            contents.vault = contents.vault!!.copy(records = listOf(record(2)))
            contents.snippets = contents.snippets.filter { it.id != id(2) }
            contents.marker = MoveMarker.Demoting(id(2))
        }
        assertEquals(listOf("write:snippets.json", "write:vault.json", "write:snippets.json"), f.io.log)

        // A demotion mislabelled as a promotion still writes the library first.
        f.io.log.clear()
        f.transaction.perform(1000) { contents ->
            contents.snippets = listOf(snippet(2)) + contents.snippets
            contents.vault = contents.vault!!.copy(records = emptyList())
            contents.marker = MoveMarker.Promoting(id(2))
        }
        assertEquals(listOf("write:snippets.json", "write:vault.json"), f.io.log)
        assertEquals(MoveMarker.None, f.markers.current)

        // With no move at all the marker decides, and the default is the vault first.
        f.io.log.clear()
        f.transaction.perform(1000) { contents ->
            contents.snippets = contents.snippets + snippet(9)
            contents.vault = contents.vault!!.copy(records = listOf(record(8)))
        }
        assertEquals(listOf("write:vault.json", "write:snippets.json"), f.io.log)
    }

    /** A promotion that also adds an ordinary record keeps the old source until the vault has landed. */
    @Test fun theIntermediateLibraryKeepsEveryPromotedSourceNextToTheFinalRecords() = fixture("intermediate") { f ->
        f.putLibrary(1, 2)
        f.scratch.vaultFile().write(document(records = emptyList()))
        val libraries = ArrayList<List<java.util.UUID>>()
        f.io.afterWrite = { if (it == f.scratch.library) libraries.add(f.libraryIds()) }

        f.transaction.perform(1000) { contents ->
            contents.vault = contents.vault!!.copy(records = listOf(record(2)))
            // The source goes, and a new ordinary record (a conflict copy, say) arrives in the same transaction.
            contents.snippets = listOf(snippet(1), snippet(5))
            contents.marker = MoveMarker.Promoting(id(2))
        }

        assertEquals(listOf(listOf(id(1), id(5), id(2)), listOf(id(1), id(5))), libraries)
    }
}
