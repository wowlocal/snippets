package com.khm.snippets.core.sync.base

import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.ProtocolLocations
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.state.DurableFileIo
import com.khm.snippets.core.state.StrictDecodeFailure
import java.io.File
import java.io.IOException

/** What loading `base.json` found (`SyncBaseFile.Outcome`). */
sealed class SyncBaseLoad {

    class Loaded(val base: SyncBase) : SyncBaseLoad()

    /** No file: a provider that has never agreed on anything, or both protocol files removed on purpose. */
    object Missing : SyncBaseLoad()

    /**
     * The file declares a schema other than [SyncBase.CURRENT_SCHEMA_VERSION]. Never
     * decoded, never written over; the engine starts halted with `schemaTooNew`.
     */
    data class Unsupported(val version: Long) : SyncBaseLoad() {
        val isNewer: Boolean get() = version > SyncBase.CURRENT_SCHEMA_VERSION
    }

    /**
     * The file is there and is not a base this build wrote. There is no quarantine and no
     * regeneration: the engine starts halted and the file is left exactly as it is, for
     * repair or a deliberate removal of both protocol files.
     */
    data class Unreadable(val cause: Cause) : SyncBaseLoad() {
        sealed class Cause {
            /** The bytes could not be read at all. */
            class Io(val failure: IOException) : Cause()

            data class Undecodable(val failure: StrictDecodeFailure) : Cause()
        }
    }

    val loadedBase: SyncBase? get() = (this as? Loaded)?.base
}

/** The result of [SyncBaseFile.write]. Only [Written] means the base is durable. */
sealed class SyncBaseWrite {

    /** [base] is on disk and its directory entry forced. Publish it now, not before. */
    class Written(val base: SyncBase) : SyncBaseWrite()

    /** The guard could not be taken in time. Nothing was written. */
    object Busy : SyncBaseWrite()

    /** The base holds a value the reader would refuse. Nothing was written. */
    class NotEncodable(val failure: SyncBaseCodec.EncodeFailure) : SyncBaseWrite()

    /** The write failed: the file holds the old base, or (after a failed directory force) possibly the new one. */
    class Failed(val failure: IOException) : SyncBaseWrite()
}

/**
 * Loading and writing one provider's `base.json` (`SyncBaseFile`).
 *
 * ## Invariants the engine upholds
 *
 * - **Durable before published.** The engine builds a candidate with one of [SyncBase]'s
 *   pure operations, writes it here, and replaces its in-memory base with
 *   [SyncBaseWrite.Written.base] only. Anything else leaves the old base in memory and
 *   on disk (or, after a failed directory force, possibly the new one on disk; the
 *   engine then halts and reloads).
 * - **Base before acknowledgement.** The journal forgets an accepted offer only after
 *   the base that records it is written; the transport's `acknowledgeFetched` follows
 *   the base that adopts the cursor.
 * - **An unreadable or unsupported file is never written over** by the engine at start;
 *   only an explicit reviewed recovery replaces it.
 *
 * [read] and [decode] are separate so a round can take the bytes at one instant and
 * decode them elsewhere; [load] is `decode(read())`. Reading takes no lock: every
 * writer publishes with a rename. Writing takes the library guard of the storage root,
 * so two engines of one provider cannot interleave; the encoding happens before the
 * guard is taken, so a large base does not hold up library writers.
 *
 * All calls block on file I/O.
 */
class SyncBaseFile(
    val file: File,
    private val guard: LibraryGuard,
    private val temporaryDirectory: File,
    private val io: DurableFileIo = DurableFileIo.Default,
) {

    constructor(storage: StorageLocations, provider: ProtocolLocations, io: DurableFileIo = DurableFileIo.Default) :
        this(provider.baseFile, storage.guard, storage.tmpFolder, io)

    fun read(): FileRead = io.read(file)

    fun load(): SyncBaseLoad = decode(read())

    /**
     * Encodes outside the guard, then writes under it.
     *
     * @return [SyncBaseWrite.Written] with [base] once it is durable.
     */
    fun write(base: SyncBase, lockTimeoutMillis: Long): SyncBaseWrite {
        val data = try {
            SyncBaseCodec.encode(base)
        } catch (failure: SyncBaseCodec.EncodeFailure) {
            return SyncBaseWrite.NotEncodable(failure)
        }
        val held = guard.acquire(lockTimeoutMillis) ?: return SyncBaseWrite.Busy
        try {
            return store(base, data)
        } finally {
            held.close()
        }
    }

    /** [write] for a caller that already holds the library guard. */
    fun writeWhileHolding(@Suppress("UNUSED_PARAMETER") held: LibraryGuard.Held, base: SyncBase): SyncBaseWrite {
        // The guard cannot tell which caller holds it; this catches the caller that holds none.
        require(guard.isHeld) { "the library guard must be held" }
        val data = try {
            SyncBaseCodec.encode(base)
        } catch (failure: SyncBaseCodec.EncodeFailure) {
            return SyncBaseWrite.NotEncodable(failure)
        }
        return store(base, data)
    }

    private fun store(base: SyncBase, data: ByteArray): SyncBaseWrite = try {
        io.writeAtomically(data, file, temporaryDirectory)
        SyncBaseWrite.Written(base)
    } catch (failure: IOException) {
        SyncBaseWrite.Failed(failure)
    }

    companion object {

        /** The outcome for bytes read earlier by [read]. Pure: no file access. */
        fun decode(read: FileRead): SyncBaseLoad = when (read) {
            is FileRead.Missing -> SyncBaseLoad.Missing
            is FileRead.Unreadable -> SyncBaseLoad.Unreadable(SyncBaseLoad.Unreadable.Cause.Io(read.cause))
            is FileRead.Bytes -> when (val result = SyncBaseCodec.read(read.data)) {
                is SyncBaseCodec.ReadResult.Decoded -> SyncBaseLoad.Loaded(result.base)
                is SyncBaseCodec.ReadResult.Unsupported -> SyncBaseLoad.Unsupported(result.version)
                is SyncBaseCodec.ReadResult.Undecodable ->
                    SyncBaseLoad.Unreadable(SyncBaseLoad.Unreadable.Cause.Undecodable(result.failure))
            }
        }
    }
}
