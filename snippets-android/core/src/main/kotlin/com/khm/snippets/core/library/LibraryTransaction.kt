package com.khm.snippets.core.library

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.state.DurableFileIo
import com.khm.snippets.core.state.SyncStateFile
import com.khm.snippets.core.state.SyncStateLoad
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultFile
import com.khm.snippets.core.vault.VaultFileError
import com.khm.snippets.core.vault.VaultFileIo
import com.khm.snippets.core.vault.VaultLoadOutcome
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * One critical section over **both** `snippets.json` and `Vault/vault.json`
 * (`LibraryTransaction.swift`): promoting and demoting a secure snippet, and the sync
 * bridge's applies that touch both files.
 *
 * Both files share one acquisition of the library guard, which is not reentrant, so no
 * other writer can see a record gone from one file and not yet in the other.
 *
 * ## What it promises across a crash
 *
 * Two files cannot be replaced atomically together. The transaction writes each move's
 * destination before it removes the source and leaves a [CrashMarker] in
 * `Sync/state.json`, so an interrupted move can only produce a **duplicate** (the record
 * in both files), never a disappearance. The next launch repairs a duplicate with the
 * marker (`SecureSnippetStore.reconcileAfterCrash`): the vault copy wins, except for
 * the id of a [CrashMarker.Demoting] marker, whose plaintext copy wins.
 *
 * The write order comes from the actual movement of ids, not from the marker, so a stale
 * or mistaken marker cannot pick the one order that could lose a record:
 *
 * | movement | writes, in order |
 * |---|---|
 * | some id leaves the library and arrives in the vault (a promotion, also mixed with demotions) | library with the final records *and* the old sources of the promoted ids; marker; vault; final library |
 * | some id leaves the vault and arrives in the library (a demotion) | library; marker; vault |
 * | neither, marker [CrashMarker.Demoting] | library; marker; vault |
 * | neither | vault; marker; library |
 *
 * After both halves the marker is cleared. Only files that changed are written. An
 * encoding refusal happens before the first write and leaves both files as they were.
 *
 * The marker is best effort, as in Swift: it is written only into a `state.json` that
 * loads, and a failure to write it never fails a move whose data landed. Without a
 * marker an interrupted demotion is completed as "the vault wins", i.e. rolled back.
 *
 * All calls block on file I/O.
 */
class LibraryTransaction(
    private val libraryFile: File,
    private val vault: VaultFile,
    private val stateFile: SyncStateFile,
    private val guard: LibraryGuard,
    private val temporaryDirectory: File,
    private val io: DurableFileIo = DurableFileIo.Default,
    /** Seconds since 2001 for a record read without `createdAt`. */
    private val now: () -> Double = AppleTime::now,
) {

    /**
     * @param io the seam for `snippets.json` and `state.json`, and for removing the vault file.
     * @param vaultIo the seam [VaultFile] reads and writes `vault.json` through.
     */
    constructor(
        locations: StorageLocations,
        io: DurableFileIo = DurableFileIo.Default,
        vaultIo: VaultFileIo = VaultFileIo.Default,
    ) : this(
        locations.snippetsFile, VaultFile(locations, vaultIo), SyncStateFile(locations, io),
        locations.guard, locations.tmpFolder, io,
    )

    /**
     * A move that spans both files and is part-done (`LibraryTransaction.CrashMarker`),
     * stored as `promoting` / `demoting` in `Sync/state.json`.
     *
     * Only [Demoting] is strictly load-bearing: an interrupted promotion leaves a
     * duplicate that "the vault copy wins" completes; an interrupted demotion leaves the
     * same duplicate, and that rule would undo it without the marker.
     */
    sealed class CrashMarker {
        object None : CrashMarker() {
            override fun toString(): String = "None"
        }

        data class Promoting(val id: UUID) : CrashMarker()

        data class Demoting(val id: UUID) : CrashMarker()
    }

    /** What the body is given: both files as they are on disk in this attempt. Immutable. */
    class Contents internal constructor(
        /** The ordinary library. */
        val snippets: List<Snippet>,
        /** The vault, or `null` when there is none. */
        val vault: VaultDocument?,
        /** Whether `snippets.json` was there: a vanished file is not an empty library. */
        val libraryExisted: Boolean,
    ) {
        /** Changes nothing and returns [value]. */
        fun <T> keep(value: T): Change<T> = Change(snippets, vault, CrashMarker.None, value)

        /**
         * Replaces either file's contents. A `null` [vault] removes `vault.json`, which is
         * allowed only when the vault on disk holds no records.
         *
         * @param marker the move in flight; written between the two halves.
         */
        fun <T> change(
            value: T,
            snippets: List<Snippet> = this.snippets,
            vault: VaultDocument? = this.vault,
            marker: CrashMarker = CrashMarker.None,
        ): Change<T> = Change(snippets, vault, marker, value)

        /** [change] without a value. */
        fun change(
            snippets: List<Snippet> = this.snippets,
            vault: VaultDocument? = this.vault,
            marker: CrashMarker = CrashMarker.None,
        ): Change<Unit> = Change(snippets, vault, marker, Unit)
    }

    /** What the body returns: the new contents of both files, the move in flight, and a value for the caller. */
    class Change<out T> internal constructor(
        val snippets: List<Snippet>,
        val vault: VaultDocument?,
        val marker: CrashMarker,
        val value: T,
    )

    /** What is on disk after [perform]. */
    class Outcome<out T> internal constructor(
        val value: T,
        val snippets: List<Snippet>,
        val vault: VaultDocument?,
        val wroteLibrary: Boolean,
        val wroteVault: Boolean,
        /** How many times the body ran. Above 1 means a file changed under an attempt. */
        val attempts: Int,
    )

    /** Why nothing, or not everything, was written. Messages are technical and name no path or content. */
    sealed class Failure(message: String, cause: Throwable?) : Exception(message, cause) {

        /** The guard was busy for the whole timeout, or the files kept changing. Retry later. */
        class Busy : Failure("the snippet library is busy", null)

        /** `snippets.json` exists and cannot be read or decoded. Nothing ran. */
        class LibraryUnreadable(val reason: LibraryWriter.Failure.Unreadable.Reason, cause: Throwable?) :
            Failure("the snippet library is unreadable: $reason", cause)

        /**
         * `vault.json` cannot be used. Nothing ran: writing over it would destroy secrets a
         * quarantine pass could still rescue.
         */
        class VaultUnreadable(val reason: Reason, val version: Long? = null, cause: Throwable? = null) :
            Failure("the vault is unusable: $reason", cause) {
            enum class Reason {
                /** Written by a newer build ([version]). */
                TOO_NEW,

                /** The bytes could not be read. */
                UNREADABLE,

                /** The bytes are not a vault. */
                CORRUPT,
            }
        }

        /**
         * A step failed. Before the first write ([Step.ENCODE_LIBRARY],
         * [Step.ENCODE_INTERMEDIATE], [Step.VAULT_REMOVAL_REFUSED]) both files are as they
         * were. After it, the files are in one of the states the class documentation
         * describes: the original, or a duplicate the marker resolves.
         */
        class WriteFailed(val step: Step, cause: Throwable?) : Failure("the library transaction stopped at $step", cause) {
            enum class Step {
                ENCODE_LIBRARY,
                ENCODE_INTERMEDIATE,

                /** The body removed a vault that still holds records: deleting secrets by omission. */
                VAULT_REMOVAL_REFUSED,
                WRITE_LIBRARY,
                WRITE_VAULT,
                REMOVE_VAULT,
            }
        }
    }

    private sealed class WritePlan {
        object VaultThenLibrary : WritePlan()
        object LibraryThenVault : WritePlan()

        /**
         * A promotion can create another plaintext record in the same transaction (a
         * conflict copy). Writing the vault first would open a window in which the next
         * launch drops the old plaintext source before that copy lands, so every
         * promotion first writes a library that keeps the old sources next to every final
         * plaintext record.
         */
        class DuplicateLibraryThenVaultThenLibrary(val promoting: Set<UUID>) : WritePlan()
    }

    /**
     * Runs [body] on what is on disk now and writes back whichever file it changed
     * (`LibraryTransaction.perform`).
     *
     * [body] may run up to [MAXIMUM_ATTEMPTS] times and must have no side effects other
     * than its [Change]. What it throws propagates and nothing is written. A [Change]
     * that equals what was read writes nothing, whatever its marker says.
     *
     * Before writing, both files are compared byte for byte with what this attempt read;
     * if either moved (only possible for a writer that bypassed the guard), the body runs
     * again on the new contents.
     *
     * @throws Failure
     */
    @Throws(Failure::class)
    fun <T> perform(lockTimeoutMillis: Long, body: (Contents) -> Change<T>): Outcome<T> {
        val held = guard.acquire(lockTimeoutMillis) ?: throw Failure.Busy()
        try {
            for (attempt in 1..MAXIMUM_ATTEMPTS) {
                val library = readLibrary()
                val vaultBytes = vault.bytesOrNull()
                val before = readVault()

                val change = body(Contents(library.snippets, before, library.fileExisted))

                val libraryChanged = change.snippets != library.snippets
                val vaultChanged = change.vault != before
                if (!libraryChanged && !vaultChanged) {
                    return Outcome(change.value, change.snippets, change.vault, false, false, attempt)
                }

                // Compare-and-swap on both files before touching either: a half-applied
                // move is the one outcome worth more than a retry.
                val libraryNow = readLibraryBytes()
                val libraryThen = if (library.fileExisted) library.data else null
                if (!VaultFile.sameBytes(libraryNow, libraryThen) || !VaultFile.sameBytes(vault.bytesOrNull(), vaultBytes)) {
                    continue
                }

                if (vaultChanged && change.vault == null && before?.records.orEmpty().isNotEmpty()) {
                    throw Failure.WriteFailed(Failure.WriteFailed.Step.VAULT_REMOVAL_REFUSED, null)
                }

                // Encode before either half lands, so a refusal leaves both files as they were.
                val encodedLibrary = if (libraryChanged) encode(change.snippets, Failure.WriteFailed.Step.ENCODE_LIBRARY) else null

                // ORDER IS THE CONTRACT: destination, then marker, then the old source.
                when (val plan = writePlan(library.snippets, before, change)) {
                    is WritePlan.VaultThenLibrary -> {
                        writeVault(change.vault, vaultChanged)
                        writeMarker(held, change.marker)
                        writeLibrary(encodedLibrary)
                    }
                    is WritePlan.LibraryThenVault -> {
                        writeLibrary(encodedLibrary)
                        writeMarker(held, change.marker)
                        writeVault(change.vault, vaultChanged)
                    }
                    is WritePlan.DuplicateLibraryThenVaultThenLibrary -> {
                        val finalIds = change.snippets.mapTo(HashSet()) { it.id }
                        val retainedSources = library.snippets.filter { it.id in plan.promoting && it.id !in finalIds }
                        val intermediate = encode(change.snippets + retainedSources, Failure.WriteFailed.Step.ENCODE_INTERMEDIATE)
                        writeLibrary(intermediate)
                        writeMarker(held, change.marker)
                        writeVault(change.vault, vaultChanged)
                        writeLibrary(encodedLibrary)
                    }
                }

                // Both halves are on disk: the move is no longer in flight.
                writeMarker(held, CrashMarker.None)
                return Outcome(change.value, change.snippets, change.vault, libraryChanged, vaultChanged, attempt)
            }
            throw Failure.Busy()
        } finally {
            held.close()
        }
    }

    /** The marker a move that did not finish left behind, if any (`pendingMarker`). */
    fun pendingMarker(): CrashMarker {
        val state = (stateFile.load() as? SyncStateLoad.Loaded)?.state ?: return CrashMarker.None
        state.promoting?.let { return CrashMarker.Promoting(it) }
        state.demoting?.let { return CrashMarker.Demoting(it) }
        return CrashMarker.None
    }

    /**
     * Direction from actual ownership changes first, the marker only when the change
     * itself identifies no move.
     */
    private fun writePlan(beforeSnippets: List<Snippet>, beforeVault: VaultDocument?, after: Change<*>): WritePlan {
        val beforeLibraryIds = beforeSnippets.mapTo(HashSet()) { it.id }
        val afterLibraryIds = after.snippets.mapTo(HashSet()) { it.id }
        val beforeVaultIds = beforeVault?.records.orEmpty().mapTo(HashSet()) { it.id }
        val afterVaultIds = after.vault?.records.orEmpty().mapTo(HashSet()) { it.id }

        val promoting = beforeLibraryIds.filterTo(HashSet()) { it !in afterLibraryIds && it in afterVaultIds }
        val demoting = beforeVaultIds.any { it !in afterVaultIds && it in afterLibraryIds }

        if (promoting.isNotEmpty()) return WritePlan.DuplicateLibraryThenVaultThenLibrary(promoting)
        if (demoting) return WritePlan.LibraryThenVault
        return if (after.marker is CrashMarker.Demoting) WritePlan.LibraryThenVault else WritePlan.VaultThenLibrary
    }

    private fun readLibrary(): LibraryWriter.Snapshot = try {
        LibraryWriter.snapshotOf(io.read(libraryFile), now)
    } catch (failure: LibraryWriter.Failure.Unreadable) {
        throw Failure.LibraryUnreadable(failure.reason, failure.cause)
    }

    private fun readLibraryBytes(): ByteArray? = (io.read(libraryFile) as? FileRead.Bytes)?.data

    /** "No vault" and "a vault that cannot be read" stay apart. */
    private fun readVault(): VaultDocument? = when (val outcome = vault.load()) {
        is VaultLoadOutcome.Loaded -> outcome.value
        is VaultLoadOutcome.Missing -> null
        is VaultLoadOutcome.TooNew -> throw Failure.VaultUnreadable(Failure.VaultUnreadable.Reason.TOO_NEW, outcome.version)
        is VaultLoadOutcome.Unreadable -> throw Failure.VaultUnreadable(Failure.VaultUnreadable.Reason.UNREADABLE, cause = outcome.error)
        is VaultLoadOutcome.Corrupt -> throw Failure.VaultUnreadable(Failure.VaultUnreadable.Reason.CORRUPT, cause = outcome.error)
    }

    private fun encode(snippets: List<Snippet>, step: Failure.WriteFailed.Step): ByteArray = try {
        SnippetLibraryCodec.encode(snippets)
    } catch (failure: SnippetLibraryCodec.NotEncodable) {
        throw Failure.WriteFailed(step, failure)
    }

    private fun writeLibrary(data: ByteArray?) {
        if (data == null) return
        try {
            io.writeAtomically(data, libraryFile, temporaryDirectory)
        } catch (failure: IOException) {
            throw Failure.WriteFailed(Failure.WriteFailed.Step.WRITE_LIBRARY, failure)
        }
    }

    private fun writeVault(updated: VaultDocument?, changed: Boolean) {
        if (!changed) return
        if (updated != null) {
            try {
                vault.write(updated)
            } catch (failure: VaultFileError) {
                throw Failure.WriteFailed(Failure.WriteFailed.Step.WRITE_VAULT, failure)
            }
        } else {
            // Durable, unlike Swift's `removeItem`: the removal is half of a move.
            try {
                io.removeDurably(vault.file)
            } catch (failure: IOException) {
                throw Failure.WriteFailed(Failure.WriteFailed.Step.REMOVE_VAULT, failure)
            }
        }
    }

    /** Best effort, into an existing state only; unchanged markers are not rewritten. */
    private fun writeMarker(held: LibraryGuard.Held, marker: CrashMarker) {
        val promoting = (marker as? CrashMarker.Promoting)?.id
        val demoting = (marker as? CrashMarker.Demoting)?.id
        stateFile.updateWhileHolding(held, makeFresh = null) { state ->
            if (state.promoting == promoting && state.demoting == demoting) state else state.copy(promoting = promoting, demoting = demoting)
        }
    }

    companion object {
        /** Bounded so a writer that bypasses the guard cannot spin this forever. */
        const val MAXIMUM_ATTEMPTS: Int = 12
    }
}
