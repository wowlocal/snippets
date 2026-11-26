package com.khm.snippets.core.vault

import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.model.Snippet
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * A move between the two files that is part-done, so that a crash is repairable.
 *
 * Only [Demoting] is strictly load-bearing: an interrupted promotion leaves the record in
 * both files and "the vault copy wins" completes it; an interrupted demotion leaves the
 * same duplicate, and without the marker that rule would undo what the user asked for.
 */
sealed class MoveMarker {
    object None : MoveMarker()
    data class Promoting(val id: UUID) : MoveMarker()
    data class Demoting(val id: UUID) : MoveMarker()
}

/**
 * Where the [MoveMarker] is kept across a crash. Swift keeps it in `Sync/state.json`
 * (`promoting` / `demoting`); the state file's owner implements this.
 *
 * Both functions are best effort and must not throw: the marker improves a recovery, and
 * failing to write it must never fail a move whose data has already landed. [write] is
 * called with [MoveMarker.None] when a move completes.
 */
interface MoveMarkerStore {
    fun read(): MoveMarker
    fun write(marker: MoveMarker)

    /** Keeps nothing. Without a marker an interrupted demotion is completed as "the vault wins". */
    object None : MoveMarkerStore {
        override fun read(): MoveMarker = MoveMarker.None
        override fun write(marker: MoveMarker) = Unit
    }
}

/**
 * One locked critical section spanning both `snippets.json` and `Vault/vault.json`
 * (`LibraryTransaction.swift`).
 *
 * Marking a snippet secure moves it from one file to the other. Both files share one lock
 * acquisition (the lock is not reentrant), so no other writer can see the record gone
 * from one file and not yet in the other.
 *
 * Two files cannot be changed atomically with respect to a crash. The transaction writes
 * each move's destination before it removes the source and leaves a [MoveMarker], so the
 * window can only ever produce a duplicate, never a disappearance;
 * [SecureSnippetStore.reconcileInterruptedMove] finishes the job on the next launch.
 */
class LibraryVaultTransaction(
    private val libraryFile: File,
    private val vault: VaultFile,
    private val guard: LibraryGuard,
    private val temporaryDirectory: File,
    private val io: VaultFileIo = VaultFileIo.Default,
    private val markers: MoveMarkerStore = MoveMarkerStore.None,
) {

    constructor(
        locations: StorageLocations,
        io: VaultFileIo = VaultFileIo.Default,
        markers: MoveMarkerStore = MoveMarkerStore.None,
    ) : this(locations.snippetsFile, VaultFile(locations, io), locations.guard, locations.tmpFolder, io, markers)

    /** What the body sees and changes. A scratch value that lives for one attempt. */
    class Contents internal constructor(
        /** The ordinary library. Written back only if it changed. */
        var snippets: List<Snippet>,
        /** The vault, or `null` when none exists. */
        var vault: VaultDocument?,
        /** Whether `snippets.json` was there: a vanished file is not an empty library. */
        val libraryExisted: Boolean,
    ) {
        /** Set by the body to describe a move that spans both files. */
        var marker: MoveMarker = MoveMarker.None
    }

    class Outcome<T> internal constructor(
        val value: T,
        val snippets: List<Snippet>,
        val vault: VaultDocument?,
        val wroteLibrary: Boolean,
        val wroteVault: Boolean,
        val attempts: Int,
    )

    sealed class Failure(message: String) : Exception(message) {
        class Busy : Failure("another writer holds the snippet library; try again")
        class LibraryUnreadable(val detail: String) : Failure(detail)
        class VaultUnreadable(val detail: String) : Failure(detail)
        class WriteFailed(val detail: String) : Failure(detail)
    }

    /** Which durable write has to land first to keep every moved record recoverable. */
    private sealed class WritePlan {
        object VaultThenLibrary : WritePlan()
        object LibraryThenVault : WritePlan()

        /**
         * Every promotion first gets an intermediate library that still holds its old
         * plaintext source next to every final plaintext record. After that duplicate
         * stage either final file may be written without a window in which a record is in
         * neither.
         */
        class DuplicateLibraryThenVaultThenLibrary(val promoting: Set<UUID>) : WritePlan()
    }

    /**
     * Runs [body] on what is on disk now and writes back whichever file it changed.
     *
     * [body] may run up to twelve times and must have no side effects other than through
     * [Contents]. What it throws propagates, and nothing is written.
     *
     * @throws Failure.Busy when the lock is busy or the files changed under every attempt.
     */
    @Throws(Failure::class)
    fun <T> perform(lockTimeoutMillis: Long, body: (Contents) -> T): Outcome<T> {
        val held = guard.acquire(lockTimeoutMillis) ?: throw Failure.Busy()
        try {
            for (attempt in 1..MAXIMUM_ATTEMPTS) {
                val library = readLibrary()
                val vaultBytes = vault.bytesOrNull()
                val before = readVault()

                val contents = Contents(library.snippets, before, library.existed)
                val value = body(contents)

                val libraryChanged = contents.snippets != library.snippets
                val vaultChanged = contents.vault != before
                if (!libraryChanged && !vaultChanged) {
                    return Outcome(value, contents.snippets, contents.vault, false, false, attempt)
                }

                // Compare-and-swap on both files before touching either: a half-applied
                // move is the one outcome worth more than a retry.
                val libraryNow = (io.read(libraryFile) as? FileRead.Bytes)?.data
                if (!VaultFile.sameBytes(libraryNow, library.data) ||
                    !VaultFile.sameBytes(vault.bytesOrNull(), vaultBytes)
                ) {
                    if (attempt == MAXIMUM_ATTEMPTS) throw Failure.Busy()
                    continue
                }

                // Encode before either half lands, so a refusal leaves both files as they were.
                val encodedLibrary = if (libraryChanged) encodeLibrary(contents.snippets, "snippet library") else null

                when (val plan = writePlan(library.snippets, before, contents)) {
                    // The order is the contract: destination, then marker, then the old source.
                    is WritePlan.VaultThenLibrary -> {
                        writeVault(contents.vault, vaultChanged)
                        markers.write(contents.marker)
                        writeLibrary(encodedLibrary)
                    }
                    is WritePlan.LibraryThenVault -> {
                        writeLibrary(encodedLibrary)
                        markers.write(contents.marker)
                        writeVault(contents.vault, vaultChanged)
                    }
                    is WritePlan.DuplicateLibraryThenVaultThenLibrary -> {
                        val finalIds = contents.snippets.mapTo(HashSet()) { it.id }
                        val retainedSources = library.snippets.filter { it.id in plan.promoting && it.id !in finalIds }
                        val intermediate = encodeLibrary(
                            contents.snippets + retainedSources, "intermediate snippet library",
                        )
                        writeLibrary(intermediate)
                        markers.write(contents.marker)
                        writeVault(contents.vault, vaultChanged)
                        writeLibrary(encodedLibrary)
                    }
                }

                // Both halves are on disk, so the move is no longer in flight.
                markers.write(MoveMarker.None)
                return Outcome(value, contents.snippets, contents.vault, libraryChanged, vaultChanged, attempt)
            }
            throw Failure.Busy()
        } finally {
            held.close()
        }
    }

    /** The marker left by a move that did not finish, if any. */
    fun pendingMarker(): MoveMarker = markers.read()

    /**
     * Direction comes from the actual ownership changes first and from the marker only
     * when the difference does not identify a move, so a stale or mistaken marker cannot
     * select the one ordering that could delete a record from both files.
     */
    private fun writePlan(beforeSnippets: List<Snippet>, beforeVault: VaultDocument?, after: Contents): WritePlan {
        val beforeLibraryIds = beforeSnippets.mapTo(HashSet()) { it.id }
        val afterLibraryIds = after.snippets.mapTo(HashSet()) { it.id }
        val beforeVaultIds = beforeVault?.records.orEmpty().mapTo(HashSet()) { it.id }
        val afterVaultIds = after.vault?.records.orEmpty().mapTo(HashSet()) { it.id }

        val promoting = beforeLibraryIds.filterTo(HashSet()) { it !in afterLibraryIds && it in afterVaultIds }
        val demoting = beforeVaultIds.filter { it !in afterVaultIds && it in afterLibraryIds }

        if (promoting.isNotEmpty()) return WritePlan.DuplicateLibraryThenVaultThenLibrary(promoting)
        if (demoting.isNotEmpty()) return WritePlan.LibraryThenVault
        return when (after.marker) {
            is MoveMarker.Demoting -> WritePlan.LibraryThenVault
            else -> WritePlan.VaultThenLibrary
        }
    }

    private class LibrarySnapshot(val snippets: List<Snippet>, val data: ByteArray?, val existed: Boolean)

    /** A missing file is a legitimately empty library; a file that cannot be read or decoded never is. */
    private fun readLibrary(): LibrarySnapshot = when (val read = io.read(libraryFile)) {
        is FileRead.Missing -> LibrarySnapshot(emptyList(), null, false)
        is FileRead.Unreadable ->
            throw Failure.LibraryUnreadable("the snippet library could not be read: ${read.cause.javaClass.simpleName}")
        is FileRead.Bytes -> try {
            LibrarySnapshot(SnippetLibraryCodec.decode(read.data), read.data, true)
        } catch (_: SnippetLibraryCodec.Unreadable) {
            throw Failure.LibraryUnreadable("the snippet library exists but could not be decoded")
        }
    }

    /** "No vault" and "a vault that could not be read" stay apart: writing over the second destroys secrets. */
    private fun readVault(): VaultDocument? = when (val outcome = vault.load()) {
        is VaultLoadOutcome.Loaded -> outcome.value
        is VaultLoadOutcome.Missing -> null
        is VaultLoadOutcome.TooNew -> throw Failure.VaultUnreadable(
            "the vault is schemaVersion ${outcome.version}; this build understands ${VaultDocument.CURRENT_SCHEMA_VERSION}",
        )
        is VaultLoadOutcome.Unreadable -> throw Failure.VaultUnreadable("the vault could not be read: ${outcome.error.message}")
        is VaultLoadOutcome.Corrupt -> throw Failure.VaultUnreadable("the vault is damaged: ${outcome.error.message}")
    }

    private fun encodeLibrary(snippets: List<Snippet>, what: String): ByteArray = try {
        SnippetLibraryCodec.encode(snippets)
    } catch (_: SnippetLibraryCodec.NotEncodable) {
        throw Failure.WriteFailed("could not encode the $what")
    }

    private fun writeLibrary(data: ByteArray?) {
        if (data == null) return
        try {
            io.writeAtomically(data, libraryFile, temporaryDirectory)
        } catch (failure: IOException) {
            throw Failure.WriteFailed("could not save the snippet library: ${failure.javaClass.simpleName}")
        }
    }

    private fun writeVault(updated: VaultDocument?, changed: Boolean) {
        if (!changed) return
        if (updated != null) {
            try {
                vault.write(updated)
            } catch (failure: VaultFileError) {
                throw Failure.WriteFailed("could not save the vault: ${failure.message}")
            }
        } else {
            // Removing the vault file is only legitimate when the body decided it holds nothing.
            try {
                io.removeDurably(vault.file)
            } catch (failure: IOException) {
                throw Failure.WriteFailed("could not remove the empty vault: ${failure.javaClass.simpleName}")
            }
        }
    }

    private companion object {
        const val MAXIMUM_ATTEMPTS = 12
    }
}
