package com.khm.snippets.core.library

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.LibraryGuard
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.state.DurableFileIo
import com.khm.snippets.core.state.SyncStateFile
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * The one path that writes `snippets.json` (`LibraryWriter` in `LibraryGeneration.swift`).
 *
 * ## Why the write re-reads inside the guard
 *
 * Holding the guard serialises writers, but a writer that saves its own in-memory array
 * can still erase an edit another writer made since that array was read: every actor
 * behaves correctly and the edit is gone. So [update] hands its transform what is on
 * disk *now*, inside the guard, and the caller reconciles its change against that
 * (`LocalMerge.mergeLocal`).
 *
 * ## Invariants
 *
 * - **Missing is not empty.** A missing file is [Snapshot.MISSING] with
 *   [Snapshot.fileExisted] `false`; a caller must never feed it to a merge as "the peer
 *   deleted everything". A file that exists and cannot be read or decoded throws
 *   [Failure.Unreadable] and is never treated as empty, and never written over by
 *   [update]: the transform does not even run.
 * - **No-op suppression.** A transform whose result encodes to the bytes already on disk
 *   writes nothing and leaves the generation alone.
 * - **Compare-and-swap.** Each attempt re-reads before writing and confirms after. With
 *   one process and the guard these checks fire only when something wrote the file
 *   without the guard; they then retry the transform against what it left (up to
 *   [MAXIMUM_ATTEMPTS] times, then [Failure.Busy]).
 * - **Publish after durability.** An [Outcome] is returned only after the bytes and the
 *   directory entry were forced.
 *
 * All calls block on file I/O. [read] takes no lock: every writer publishes with a
 * rename, so a reader sees a complete old file or a complete new one.
 */
class LibraryWriter(
    val libraryFile: File,
    private val stateFile: SyncStateFile,
    private val guard: LibraryGuard,
    private val temporaryDirectory: File,
    private val io: DurableFileIo = DurableFileIo.Default,
    /** Seconds since 2001 for a record read without `createdAt` (`SnippetLibraryCodec.decode`). */
    private val now: () -> Double = AppleTime::now,
    /** The id in the name of a preserved quarantined primary. */
    private val newId: () -> UUID = UUID::randomUUID,
) {

    constructor(locations: StorageLocations, io: DurableFileIo = DurableFileIo.Default) :
        this(locations.snippetsFile, SyncStateFile(locations, io), locations.guard, locations.tmpFolder, io)

    /** The library as it is on disk at one instant (`LibraryWriter.Snapshot`). */
    class Snapshot(
        val snippets: List<Snippet>,
        /** Lowercase hex SHA-256 of [data]; `""` for a missing file. */
        val digest: String,
        data: ByteArray,
        /**
         * Whether a file was actually there. **Not a detail:** a missing file and a file
         * holding an empty array are the same [snippets] and opposite facts. The second
         * is a peer saying it deleted everything; the first is nobody saying anything.
         */
        val fileExisted: Boolean,
    ) {
        private val bytes: ByteArray = data.copyOf()

        /** A copy of the raw bytes, the byte-exact ancestor for the next merge. */
        val data: ByteArray get() = bytes.copyOf()

        internal fun sameBytes(other: ByteArray): Boolean = bytes.contentEquals(other)

        override fun equals(other: Any?): Boolean =
            other is Snapshot && fileExisted == other.fileExisted && digest == other.digest &&
                bytes.contentEquals(other.bytes) && snippets == other.snippets

        override fun hashCode(): Int = digest.hashCode()

        override fun toString(): String = "Snapshot(${snippets.size} snippets, existed=$fileExisted)"

        companion object {
            /** No file: an empty library that nobody stated. */
            val MISSING = Snapshot(emptyList(), "", ByteArray(0), fileExisted = false)
        }
    }

    /** What is on disk after [update] or [replaceQuarantinedPrimary]. */
    class Outcome(
        val snippets: List<Snippet>,
        val digest: String,
        data: ByteArray,
        /**
         * The transform saw bytes the caller had not seen: its expected digest was given
         * and differed from what was on disk. The caller tells the UI the library moved.
         */
        val foldedInForeignWrite: Boolean,
        /** Whether this call wrote the file. `false` for a no-op. */
        val wrote: Boolean,
        /** How many times the transform ran. Above 1 means a writer bypassed the guard. */
        val attempts: Int,
    ) {
        private val bytes: ByteArray = data.copyOf()

        val data: ByteArray get() = bytes.copyOf()

        override fun toString(): String = "Outcome(${snippets.size} snippets, wrote=$wrote, attempts=$attempts)"
    }

    /** Why nothing was written. Messages are technical and name no path or content. */
    sealed class Failure(message: String, cause: Throwable?) : Exception(message, cause) {

        /** The guard was busy for the whole timeout, or the file kept changing. Retry later; never drop the write. */
        class Busy : Failure("the snippet library is busy", null)

        /** The file exists, or may, and is not a library. Never an empty library. */
        class Unreadable(val reason: Reason, cause: IOException?) : Failure("the snippet library is unreadable: $reason", cause) {
            enum class Reason {
                /** The bytes could not be read: permissions, an I/O error. */
                IO,

                /** The bytes are not a library ([SnippetLibraryCodec.decode] refused them). */
                UNDECODABLE,
            }
        }

        class WriteFailed(val step: Step, cause: Throwable?) : Failure("the snippet library was not written: $step", cause) {
            enum class Step {
                /** A snippet has a timestamp JSON cannot spell. */
                ENCODE,

                /** The atomic write of `snippets.json` failed. */
                WRITE,

                /** The copy of a quarantined primary could not be written. */
                PRESERVE,

                /** The copy of a quarantined primary did not read back equal. */
                VERIFY_PRESERVED,
            }
        }
    }

    // Reading

    /**
     * Reads the library without the guard (`LibraryWriter.read`).
     *
     * @throws Failure.Unreadable for anything but a missing file or a decodable library.
     */
    @Throws(Failure.Unreadable::class)
    fun read(): Snapshot = snapshotOf(io.read(libraryFile), now)

    // Writing

    /**
     * A locked read-modify-write (`LibraryWriter.update`).
     *
     * [transform] receives what is on disk now and returns what should replace it. It may
     * run up to [MAXIMUM_ATTEMPTS] times and must have no side effects; what it throws
     * propagates and nothing is written.
     *
     * @param expectedDigest what the caller believed was on disk. Informational only: it
     *   decides [Outcome.foldedInForeignWrite], never whether the write proceeds.
     * @throws Failure.Busy, Failure.Unreadable, Failure.WriteFailed
     */
    @Throws(Failure::class)
    fun update(lockTimeoutMillis: Long, expectedDigest: String?, transform: (Snapshot) -> List<Snippet>): Outcome {
        val held = guard.acquire(lockTimeoutMillis) ?: throw Failure.Busy()
        try {
            for (attempt in 1..MAXIMUM_ATTEMPTS) {
                val current = read()
                val updated = transform(current)
                val data = encode(updated)
                val foldedIn = expectedDigest != null && expectedDigest != current.digest

                // Nothing changed: no write, no generation, no observer event. Two synced
                // devices would otherwise answer each other's identical writes forever.
                if (current.sameBytes(data)) {
                    return Outcome(current.snippets, current.digest, data, foldedIn, wrote = false, attempts = attempt)
                }

                // Did anything land between the read and now?
                if (read().digest != current.digest) continue

                write(data)
                val digest = SnippetLibraryCodec.digest(data)

                // Ours must be what survived; otherwise fold the other write in.
                if (read().digest != digest) continue

                recordGeneration(held, digest, observedOnDisk = current.digest)
                return Outcome(updated, digest, data, foldedIn, wrote = true, attempts = attempt)
            }
            throw Failure.Busy()
        } finally {
            held.close()
        }
    }

    /**
     * Replaces a quarantined primary without decoding it (`replaceQuarantinedPrimary`):
     * the explicit, authoritative recovery of an unreadable library.
     *
     * The bytes on disk, whatever they are, are first copied to
     * `snippets.json.recovery-preserved-<lowercase uuid>` beside the library and read back
     * for equality; only then is [replacement] published. The preserved copy is never
     * deleted by this code. A missing primary preserves nothing.
     *
     * @throws Failure.Busy, Failure.Unreadable (the primary cannot be read at all, or the
     *   replacement does not read back), Failure.WriteFailed
     */
    @Throws(Failure::class)
    fun replaceQuarantinedPrimary(replacement: List<Snippet>, lockTimeoutMillis: Long, expectedDigest: String?): Outcome {
        val held = guard.acquire(lockTimeoutMillis) ?: throw Failure.Busy()
        try {
            val replacementData = encode(replacement)
            val replacementDigest = SnippetLibraryCodec.digest(replacementData)
            for (attempt in 1..MAXIMUM_ATTEMPTS) {
                val current = raw()
                val foldedIn = expectedDigest != null && expectedDigest != current.digest
                if (current.data != null && current.data.contentEquals(replacementData)) {
                    return Outcome(replacement, replacementDigest, replacementData, foldedIn, wrote = false, attempts = attempt)
                }

                current.data?.let(::preserve)

                val recheck = raw()
                if (recheck.digest != current.digest || (recheck.data == null) != (current.data == null)) continue

                write(replacementData)
                val confirmed = read()
                if (confirmed.digest != replacementDigest) continue

                recordGeneration(held, replacementDigest, observedOnDisk = current.digest)
                return Outcome(confirmed.snippets, confirmed.digest, confirmed.data, foldedIn, wrote = true, attempts = attempt)
            }
            throw Failure.Busy()
        } finally {
            held.close()
        }
    }

    private class Raw(val data: ByteArray?, val digest: String)

    private fun raw(): Raw = when (val read = io.read(libraryFile)) {
        is FileRead.Missing -> Raw(null, "")
        is FileRead.Unreadable -> throw Failure.Unreadable(Failure.Unreadable.Reason.IO, read.cause)
        is FileRead.Bytes -> Raw(read.data, SnippetLibraryCodec.digest(read.data))
    }

    private fun preserve(data: ByteArray) {
        val backup = File(libraryFile.absoluteFile.parentFile, "$PRESERVED_PREFIX${Uuids.lowercase(newId())}")
        try {
            io.writeAtomically(data, backup, temporaryDirectory)
        } catch (failure: IOException) {
            throw Failure.WriteFailed(Failure.WriteFailed.Step.PRESERVE, failure)
        }
        val readBack = (io.read(backup) as? FileRead.Bytes)?.data
        if (readBack == null || !readBack.contentEquals(data)) {
            throw Failure.WriteFailed(Failure.WriteFailed.Step.VERIFY_PRESERVED, null)
        }
    }

    private fun encode(snippets: List<Snippet>): ByteArray = try {
        SnippetLibraryCodec.encode(snippets)
    } catch (failure: SnippetLibraryCodec.NotEncodable) {
        throw Failure.WriteFailed(Failure.WriteFailed.Step.ENCODE, failure)
    }

    private fun write(data: ByteArray) {
        try {
            io.writeAtomically(data, libraryFile, temporaryDirectory)
        } catch (failure: IOException) {
            throw Failure.WriteFailed(Failure.WriteFailed.Step.WRITE, failure)
        }
    }

    /** Best effort, into an existing state only: see [LibraryGeneration]. */
    private fun recordGeneration(held: LibraryGuard.Held, written: String, observedOnDisk: String) {
        stateFile.updateWhileHolding(held, makeFresh = null) { LibraryGeneration.advanced(it, written, observedOnDisk) }
    }

    companion object {

        /** Bounded so a writer that bypasses the guard cannot spin this forever. */
        const val MAXIMUM_ATTEMPTS: Int = 24

        /** The name prefix of a preserved quarantined primary, beside `snippets.json`. */
        const val PRESERVED_PREFIX: String = "snippets.json.recovery-preserved-"

        /**
         * The snapshot of an earlier [FileRead] of `snippets.json`, shared with
         * [LibraryTransaction].
         *
         * @throws Failure.Unreadable for anything but a missing file or a decodable library.
         */
        @Throws(Failure.Unreadable::class)
        internal fun snapshotOf(read: FileRead, now: () -> Double): Snapshot = when (read) {
            is FileRead.Missing -> Snapshot.MISSING
            is FileRead.Unreadable -> throw Failure.Unreadable(Failure.Unreadable.Reason.IO, read.cause)
            is FileRead.Bytes -> {
                val snippets = try {
                    SnippetLibraryCodec.decode(read.data, now)
                } catch (_: SnippetLibraryCodec.Unreadable) {
                    throw Failure.Unreadable(Failure.Unreadable.Reason.UNDECODABLE, null)
                }
                Snapshot(snippets, SnippetLibraryCodec.digest(read.data), read.data, fileExisted = true)
            }
        }
    }
}
