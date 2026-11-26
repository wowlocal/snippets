package com.khm.snippets.core.state

import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.io.StorageLocations
import com.khm.snippets.core.text.FoundationText
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * Durable evidence, independent of `state.json`, that the primary library was
 * quarantined (`LibraryQuarantineMarker`, the file `Sync/library-quarantine`).
 *
 * The file's existence is the fact; the random id inside names this recovery
 * transaction. The order around it is the contract:
 *
 * 1. It is written, durably, **before** the unreadable `snippets.json` is moved aside.
 * 2. While it exists, a missing `snippets.json` is never an empty library, even if
 *    `state.json` and its halt are lost.
 * 3. It is removed only after the confirmed base carries the same review id and the
 *    quarantine halt has been cleared.
 *
 * The content is the lowercase id and a newline. A file with anything else still
 * [exists] and has no [reviewId].
 */
class LibraryQuarantineMarker(
    val file: File,
    private val temporaryDirectory: File,
    private val io: DurableFileIo = DurableFileIo.Default,
) {

    constructor(locations: StorageLocations, io: DurableFileIo = DurableFileIo.Default) :
        this(locations.libraryQuarantineMarkerFile, locations.tmpFolder, io)

    fun exists(): Boolean = io.exists(file)

    /**
     * Makes the marker durable and returns its review id. Idempotent: a marker that is
     * already there and readable keeps its id, so a crash and a retry stay one review.
     *
     * @param requestedReviewId the id to write when there is no readable marker; a random
     *   one from [newId] otherwise.
     */
    @Throws(IOException::class)
    fun write(requestedReviewId: UUID? = null, newId: () -> UUID = UUID::randomUUID): UUID {
        reviewId()?.let { return it }
        val identity = requestedReviewId ?: newId()
        io.writeAtomically(Utf8.encode(Uuids.lowercase(identity) + "\n"), file, temporaryDirectory)
        return identity
    }

    /** The id of the review in progress, or `null` without a marker or with one that does not hold an id. */
    fun reviewId(): UUID? {
        val data = (io.read(file) as? FileRead.Bytes)?.data ?: return null
        val text = Utf8.decodeStrict(data) ?: return null
        return Uuids.parse(FoundationText.trimWhitespaceAndNewlines(text))
    }

    /** Removes the marker and makes its absence durable. A marker that is already gone is success. */
    @Throws(IOException::class)
    fun removeDurably() {
        io.removeDurably(file)
    }

    companion object {
        /** The marker beside a given state file (`LibraryQuarantineMarker.url(beside:)`). */
        fun fileBeside(stateFile: File): File = File(stateFile.absoluteFile.parentFile, "library-quarantine")
    }
}
