package com.khm.snippets.core.state

import com.khm.snippets.core.io.AtomicFileWriter
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.StorageLocations
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * The file operations of the local sync state, the confirmed base and the library
 * writer, as a seam so that a test can fail or stop at any one of them. [Default] is the
 * real file system: every write is [AtomicFileWriter]'s temporary file, force, rename
 * and directory force, and every read is [FileRead]'s three-way answer.
 *
 * This is the `core.io` convention, kept as one interface: blocking calls, a missing
 * file distinct from an unreadable one, whole-file atomic replacement staged in the
 * root's `Tmp/`, and a durable removal. Nothing in `core.state`, `core.sync.base` or
 * `core.library` suspends: call them off the main thread.
 *
 * An implementation may throw anything from any call. The code here catches only
 * [IOException] (a failed step); anything else (a test's simulated crash) passes
 * through untouched, which is how the crash-consistency tests stop a write sequence at
 * an exact point.
 */
interface DurableFileIo {

    /** The file's bytes, or why there are none. A missing file and an unreadable one stay apart. */
    fun read(file: File): FileRead

    /** Replaces [destination] atomically and durably at mode 0600, staging in [temporaryDirectory]. */
    @Throws(IOException::class)
    fun writeAtomically(data: ByteArray, destination: File, temporaryDirectory: File)

    /** Removes [file] and makes its absence durable. A file that is already gone is success. */
    @Throws(IOException::class)
    fun removeDurably(file: File)

    /** Renames [source] to [destination], which must not exist, within one directory. */
    @Throws(IOException::class)
    fun moveAside(source: File, destination: File)

    fun exists(file: File): Boolean

    object Default : DurableFileIo {
        override fun read(file: File): FileRead = FileRead.read(file)

        override fun writeAtomically(data: ByteArray, destination: File, temporaryDirectory: File) {
            AtomicFileWriter.write(data, destination, temporaryDirectory)
        }

        override fun removeDurably(file: File) {
            AtomicFileWriter.removeDurablyIfPresent(file)
        }

        override fun moveAside(source: File, destination: File) {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            // The rename has happened; a directory that cannot be forced only delays its durability.
            try {
                AtomicFileWriter.synchronizeDirectory(destination.absoluteFile.parentFile ?: return)
            } catch (_: IOException) {
            }
        }

        override fun exists(file: File): Boolean = Files.exists(file.toPath())
    }
}

/** What loading `Sync/state.json` found (`SyncStateFile.Outcome`). */
sealed class SyncStateLoad {

    data class Loaded(val state: SyncState) : SyncStateLoad()

    /**
     * The file declares a schema other than [SyncState.CURRENT_SCHEMA_VERSION] (Swift's
     * `tooNew`; this app also refuses older numbers, which it never wrote). It may hold a
     * safety stop this build cannot read: callers must not write the file and must not
     * sync over it.
     */
    data class Unsupported(val version: Long) : SyncStateLoad() {
        val isNewer: Boolean get() = version > SyncState.CURRENT_SCHEMA_VERSION
    }

    /**
     * No usable file, so [state] is a new one that has not been written. As in Swift, a
     * file that cannot be read or decoded is replaced, not repaired: it holds no user
     * data. [cause] says which of the three it was, because the last two mean that a
     * halt may have been lost and are worth a diagnostic.
     */
    data class Fresh(val state: SyncState, val cause: Cause) : SyncStateLoad() {
        sealed class Cause {
            object Missing : Cause()
            object Unreadable : Cause()
            data class Undecodable(val failure: StrictDecodeFailure) : Cause()
        }
    }

    val loadedState: SyncState? get() = (this as? Loaded)?.state
    val freshState: SyncState? get() = (this as? Fresh)?.state
    val unsupportedVersion: Long? get() = (this as? Unsupported)?.version
}

/** The result of a locked read-modify-write of `state.json`. */
sealed class SyncStateUpdate {

    /** The transform's result is durable. */
    data class Written(val state: SyncState) : SyncStateUpdate()

    /** The transform changed nothing, so nothing was written (not even a fresh state). */
    data class Unchanged(val state: SyncState) : SyncStateUpdate()

    /** There is no decodable state and the caller asked not to create one. The transform did not run. */
    data class NotLoaded(val cause: SyncStateLoad.Fresh.Cause) : SyncStateUpdate()

    /** Another schema owns the file. Nothing was written and the transform did not run. */
    data class Unsupported(val version: Long) : SyncStateUpdate()

    /** The guard could not be taken in time. Nothing ran. */
    object Busy : SyncStateUpdate()

    /** The write failed; the file holds what it held before, or (after a failed directory force) the new state. */
    class WriteFailed(val cause: IOException) : SyncStateUpdate()

    /** The durable state after the call, when the call knows it. */
    val stateOrNull: SyncState?
        get() = when (this) {
            is Written -> state
            is Unchanged -> state
            else -> null
        }
}

/**
 * The result of [SyncStateFile.updateHalt] (`HaltUpdateResult` in `SyncEngine.swift`) and
 * of [SyncStateFile.replaceHaltWhileHolding].
 */
sealed class HaltUpdateResult {

    /** The file now holds exactly [halt] (`null`: no halt). The engine publishes it only now. */
    data class Written(val halt: Halt?) : HaltUpdateResult()

    /** The file holds a different halt than the caller expected. The caller reviewed the old one, not [newer]. */
    data class Superseded(val newer: Halt) : HaltUpdateResult()

    /**
     * The caller expected a halt and the file holds none: somebody completed the
     * recovery. Nothing was written, so a stale reviewer cannot recreate the stop and
     * with it a second one-shot authority.
     */
    object Cleared : HaltUpdateResult()

    /** Another schema owns the file. Nothing was written. */
    data class Unsupported(val version: Long) : HaltUpdateResult()

    /** The halt is not durable. The in-memory halt must stay, and the caller fails closed. */
    data class Failed(val reason: Reason) : HaltUpdateResult() {
        enum class Reason { LOCK_BUSY, WRITE_FAILED }
    }
}

/**
 * Loading and writing `Sync/state.json` (`SyncStateFile`), and the doors through which
 * its halt is changed.
 *
 * ## Invariants the callers uphold
 *
 * - **Every change is a read-modify-write of the whole document under the library
 *   guard.** Four things live in the file (device identity, library generation, move
 *   marker, halt); a writer that does not hold the guard can erase what another just
 *   wrote. Use [update], [updateHalt] or [loadOrCreate]. A caller that already holds the
 *   guard (it is not reentrant) passes its [LibraryGuard.Held] to the `…WhileHolding`
 *   form instead.
 * - **Publish after durability.** Each result that carries a state or a halt is returned
 *   only after the bytes and their directory entry were forced. Replace an in-memory
 *   copy with the returned value, never with the value you asked for.
 * - **[SyncStateLoad.Unsupported] is never written over.** No function here does.
 * - **A halt is sticky.** [update] refuses a transform that changes the halt; the only
 *   ways a halt changes are [updateHalt] (compare-and-swap, for the engine) and
 *   [replaceHaltWhileHolding] (unconditional, only for the primary-library quarantine).
 *   Every other writer of this file carries the stored halt through unchanged.
 *
 * [load] takes no lock: every writer publishes with a rename, so a reader sees a complete
 * old file or a complete new one.
 *
 * All calls block on file I/O.
 */
class SyncStateFile(
    val file: File,
    private val guard: LibraryGuard,
    private val temporaryDirectory: File,
    private val io: DurableFileIo = DurableFileIo.Default,
) {

    constructor(locations: StorageLocations, io: DurableFileIo = DurableFileIo.Default) :
        this(locations.syncStateFile, locations.guard, locations.tmpFolder, io)

    /**
     * Swift's three outcomes, with the reason for a fresh state kept.
     *
     * @param makeFresh builds the state for [SyncStateLoad.Fresh]; called at most once,
     *   and only for that outcome. The default mints a new random device id.
     */
    fun load(makeFresh: () -> SyncState = { SyncState.fresh() }): SyncStateLoad =
        when (val read = io.read(file)) {
            is FileRead.Missing -> SyncStateLoad.Fresh(makeFresh(), SyncStateLoad.Fresh.Cause.Missing)
            is FileRead.Unreadable -> SyncStateLoad.Fresh(makeFresh(), SyncStateLoad.Fresh.Cause.Unreadable)
            is FileRead.Bytes -> when (val result = SyncStateCodec.read(read.data)) {
                is SyncStateCodec.ReadResult.Decoded -> SyncStateLoad.Loaded(result.state)
                is SyncStateCodec.ReadResult.Unsupported -> SyncStateLoad.Unsupported(result.version)
                is SyncStateCodec.ReadResult.Undecodable ->
                    SyncStateLoad.Fresh(makeFresh(), SyncStateLoad.Fresh.Cause.Undecodable(result.failure))
            }
        }

    /**
     * Whole-document write (`SyncStateFile.write`) by a caller that holds the guard and
     * has just loaded the state it replaces. Prefer [update]; this exists for seeding a
     * file in tests and for callers that must write a state they built themselves.
     *
     * @throws IOException when the write fails; the file then holds what it held before,
     *   or (after a failed directory force) already the new state.
     */
    @Throws(IOException::class)
    fun write(held: LibraryGuard.Held, state: SyncState) {
        requireHeld(held)
        io.writeAtomically(SyncStateCodec.encode(state), file, temporaryDirectory)
    }

    /**
     * Locked read-modify-write.
     *
     * @param makeFresh what to start from when there is no decodable file. `null` means
     *   "only if a state loads": the transform does not run and nothing is created, which
     *   is the rule for bookkeeping that must never stand in for a lost identity (the
     *   generation counter, the move marker).
     * @param transform runs once, under the guard, on what is on disk now. It must have
     *   no side effects and must return the same halt it was given.
     * @throws IllegalArgumentException when [transform] changed the halt.
     */
    fun update(
        lockTimeoutMillis: Long,
        makeFresh: (() -> SyncState)?,
        transform: (SyncState) -> SyncState,
    ): SyncStateUpdate {
        val held = guard.acquire(lockTimeoutMillis) ?: return SyncStateUpdate.Busy
        try {
            return modify(makeFresh, transform)
        } finally {
            held.close()
        }
    }

    /**
     * [update] for a caller that already holds the library guard, which it proves by
     * passing the lock it holds. The guard is not reentrant, so [update] would wait for
     * that caller's own lock and report busy.
     */
    fun updateWhileHolding(
        held: LibraryGuard.Held,
        makeFresh: (() -> SyncState)?,
        transform: (SyncState) -> SyncState,
    ): SyncStateUpdate {
        requireHeld(held)
        return modify(makeFresh, transform)
    }

    private fun modify(makeFresh: (() -> SyncState)?, transform: (SyncState) -> SyncState): SyncStateUpdate {
        val current = when (val loaded = load(makeFresh ?: { PLACEHOLDER })) {
            is SyncStateLoad.Loaded -> loaded.state
            is SyncStateLoad.Unsupported -> return SyncStateUpdate.Unsupported(loaded.version)
            is SyncStateLoad.Fresh -> if (makeFresh == null) return SyncStateUpdate.NotLoaded(loaded.cause) else loaded.state
        }
        val next = transform(current)
        require(next.halt == current.halt) { "only updateHalt and replaceHaltWhileHolding change a halt" }
        // Nothing is written, not even a fresh state: use loadOrCreate to create one.
        if (next == current) return SyncStateUpdate.Unchanged(current)
        return try {
            io.writeAtomically(SyncStateCodec.encode(next), file, temporaryDirectory)
            SyncStateUpdate.Written(next)
        } catch (failure: IOException) {
            SyncStateUpdate.WriteFailed(failure)
        }
    }

    /**
     * The state on disk, persisting a fresh one when there is none
     * (`SnippetStore.adoptDeviceIdentity`). Deliberately tolerant: the device id only
     * breaks exact merge ties, so a launch never fails over it.
     *
     * - [SyncStateLoad.Loaded]: what is on disk.
     * - [SyncStateLoad.Fresh]: a new state. It was written, unless the guard was busy or
     *   the write failed; then it is good for this session and the next launch tries again.
     * - [SyncStateLoad.Unsupported]: nothing was written. Use a random device id for the
     *   session.
     */
    fun loadOrCreate(lockTimeoutMillis: Long, makeFresh: () -> SyncState = { SyncState.fresh() }): SyncStateLoad {
        val held = guard.acquire(lockTimeoutMillis) ?: return load(makeFresh)
        try {
            val loaded = load(makeFresh)
            if (loaded is SyncStateLoad.Fresh) {
                try {
                    io.writeAtomically(SyncStateCodec.encode(loaded.state), file, temporaryDirectory)
                } catch (_: IOException) {
                    // As in Swift (`try?`): the identity still serves this session.
                }
            }
            return loaded
        } finally {
            held.close()
        }
    }

    /**
     * Replaces the halt by compare-and-swap (`SyncEngine.updatePersistedHalt`): the only
     * way the engine sets, claims, unclaims or clears a halt.
     *
     * Under the guard, the state is loaded (a missing or undecodable file counts as a
     * fresh state without a halt, as in Swift) and its halt is compared with [expecting]:
     *
     * | on disk | result |
     * |---|---|
     * | equals [expecting], equals [halt] | [HaltUpdateResult.Written], nothing written |
     * | equals [expecting] | [halt] is written: [HaltUpdateResult.Written] |
     * | differs, and both it and [halt] are `null` | [HaltUpdateResult.Written] of `null` |
     * | differs and is a halt | [HaltUpdateResult.Superseded] with it |
     * | differs and is `null` | [HaltUpdateResult.Cleared] |
     *
     * Passing the same value for [halt] and [expecting] is the read-only "is my halt
     * still the durable one" check.
     *
     * A halt is therefore sticky by construction: it survives every other writer of this
     * file, and only this function with `halt = null` and the exact stored value in
     * [expecting] clears one.
     *
     * @param makeFresh the state a first halt is written into when there is no decodable
     *   file; pass the device id the app already uses.
     */
    fun updateHalt(
        lockTimeoutMillis: Long,
        halt: Halt?,
        expecting: Halt?,
        makeFresh: () -> SyncState,
    ): HaltUpdateResult {
        val held = guard.acquire(lockTimeoutMillis) ?: return HaltUpdateResult.Failed(HaltUpdateResult.Failed.Reason.LOCK_BUSY)
        try {
            return compareAndSwapHalt(halt, expecting, makeFresh)
        } finally {
            held.close()
        }
    }

    /** [updateHalt] for a caller that already holds the guard. */
    fun updateHaltWhileHolding(
        held: LibraryGuard.Held,
        halt: Halt?,
        expecting: Halt?,
        makeFresh: () -> SyncState,
    ): HaltUpdateResult {
        requireHeld(held)
        return compareAndSwapHalt(halt, expecting, makeFresh)
    }

    private fun compareAndSwapHalt(halt: Halt?, expecting: Halt?, makeFresh: () -> SyncState): HaltUpdateResult {
        val persisted = when (val loaded = load(makeFresh)) {
            is SyncStateLoad.Loaded -> loaded.state
            is SyncStateLoad.Fresh -> loaded.state
            is SyncStateLoad.Unsupported -> return HaltUpdateResult.Unsupported(loaded.version)
        }
        if (persisted.halt != expecting) {
            // Clearing a halt that is already gone is safe; a different halt is a stop
            // this caller has not reviewed. Writing `expecting` back would mint a second
            // one-shot authority for a review a peer already completed.
            if (halt == null && persisted.halt == null) return HaltUpdateResult.Written(null)
            persisted.halt?.let { return HaltUpdateResult.Superseded(it) }
            return HaltUpdateResult.Cleared
        }
        if (persisted.halt == halt) return HaltUpdateResult.Written(halt)
        return writeHalt(persisted, halt)
    }

    /**
     * Writes [halt] whatever the file holds (`SnippetStore.quarantineUnreadableLibrary`):
     * the primary-library quarantine is more fundamental than any other stop, and the
     * store raises it before it moves unreadable user data aside. No other caller may use
     * this; the engine changes halts only by [updateHalt].
     *
     * @return [HaltUpdateResult.Written], [HaltUpdateResult.Unsupported] (nothing
     *   written) or [HaltUpdateResult.Failed].
     */
    fun replaceHaltWhileHolding(held: LibraryGuard.Held, halt: Halt, makeFresh: () -> SyncState): HaltUpdateResult {
        requireHeld(held)
        val persisted = when (val loaded = load(makeFresh)) {
            is SyncStateLoad.Loaded -> loaded.state
            is SyncStateLoad.Fresh -> loaded.state
            is SyncStateLoad.Unsupported -> return HaltUpdateResult.Unsupported(loaded.version)
        }
        return writeHalt(persisted, halt)
    }

    private fun writeHalt(persisted: SyncState, halt: Halt?): HaltUpdateResult = try {
        io.writeAtomically(SyncStateCodec.encode(persisted.copy(halt = halt)), file, temporaryDirectory)
        HaltUpdateResult.Written(halt)
    } catch (_: IOException) {
        HaltUpdateResult.Failed(HaltUpdateResult.Failed.Reason.WRITE_FAILED)
    }

    // The guard cannot tell which caller holds it; this catches the caller that holds none.
    private fun requireHeld(@Suppress("UNUSED_PARAMETER") held: LibraryGuard.Held) {
        require(guard.isHeld) { "the library guard must be held" }
    }

    private companion object {
        // Never returned: stands in for "no fresh state wanted" so that `load` needs no second code path.
        val PLACEHOLDER = SyncState("00000001")
    }
}
