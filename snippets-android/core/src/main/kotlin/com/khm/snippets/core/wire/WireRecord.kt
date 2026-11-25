package com.khm.snippets.core.wire

import com.khm.snippets.core.sync.transport.SyncRecordVersion
import java.util.UUID

/**
 * The application fields that leave the device, plus opaque backend concurrency state
 * (`WireRecord` in `snippets/Core/SyncEnvelope.swift`).
 *
 * Everything else (name, keyword, tags, body, `secure`, the clock, the originating device,
 * the timestamps) is inside [blob], encrypted. Whoever holds the backend sees opaque ids,
 * opaque revisions, a deletion flag, ciphertext and the backend's own generation token.
 *
 * [deleted] is in the clear on purpose: a backend has to be able to collect tombstones
 * without holding a key.
 *
 * Immutable. The constructor copies [blob] and [blob] returns a copy; where Swift assigns
 * a member, use [copy]. Two records are equal when all five members are, the blob byte
 * for byte.
 */
class WireRecord(
    /** The snippet's stable id. Visible so the backend can address a record at all. */
    val id: UUID,
    /** Opaque revision token. Compare for equality; never parse. */
    val rev: String,
    /** In the clear solely so a backend can collect tombstones. */
    val deleted: Boolean,
    blob: ByteArray,
    /**
     * Backend-owned optimistic-concurrency metadata. Outside the sealed identity on
     * purpose: a refreshed generation changes neither the user's content, the application
     * revision nor the ciphertext.
     */
    val recordVersion: SyncRecordVersion? = null,
) {

    /**
     * The sealed envelope, without a copy. Only for code in this module that reads it and
     * neither modifies nor keeps it.
     */
    internal val blobBytes: ByteArray = blob.copyOf()

    /** The sealed [SyncEnvelope]. A copy. */
    val blob: ByteArray get() = blobBytes.copyOf()

    val blobByteCount: Int get() = blobBytes.size

    fun copy(
        id: UUID = this.id,
        rev: String = this.rev,
        deleted: Boolean = this.deleted,
        blob: ByteArray = this.blobBytes,
        recordVersion: SyncRecordVersion? = this.recordVersion,
    ): WireRecord = WireRecord(id, rev, deleted, blob, recordVersion)

    override fun equals(other: Any?): Boolean =
        this === other || (
            other is WireRecord &&
                id == other.id &&
                rev == other.rev &&
                deleted == other.deleted &&
                recordVersion == other.recordVersion &&
                blobBytes.contentEquals(other.blobBytes)
            )

    override fun hashCode(): Int = (id.hashCode() * 31 + rev.hashCode()) * 31 + deleted.hashCode()

    override fun toString(): String =
        "WireRecord(id=$id, rev=$rev, deleted=$deleted, blob=${blobBytes.size} bytes, recordVersion=$recordVersion)"
}
