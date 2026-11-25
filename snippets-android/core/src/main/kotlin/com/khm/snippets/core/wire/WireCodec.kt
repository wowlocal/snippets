package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.crypto.Uuids

/** Turns an envelope into a [WireRecord] and back (`WireCodec` in `snippets/Core/SyncEnvelope.swift`). */
object WireCodec {

    /**
     * Seals the envelope's ten-key canonical bytes. `rev` is the sealer's revision token
     * for the envelope hash; the record carries no `recordVersion`, which only a backend
     * assigns.
     *
     * @throws CanonicalJson.Failure when the envelope has no canonical form.
     * @throws Exception whatever [sealer] reports.
     */
    @Throws(Exception::class)
    fun seal(envelope: SyncEnvelope, sealer: BlobSealer): WireRecord {
        val rev = sealer.revisionToken(envelope.envelopeHash())
        val identity = WireIdentity(id = envelope.id, rev = rev, deleted = envelope.deleted)
        val blob = sealer.seal(envelope.canonicalBytes(), identity)
        return WireRecord(id = identity.id, rev = identity.rev, deleted = identity.deleted, blob = blob)
    }

    /**
     * Opens a record and refuses anything that does not describe itself consistently.
     *
     * Three checks, each closing a different hole a compromised backend could use:
     * the sealer's authentication (a blob moved onto another record), the envelope's own
     * `hash` ([SyncEnvelope.parse]: a plaintext that parsed but is not what was sealed),
     * and the comparison of id, deletion flag and `rev` (clear-text fields that were
     * edited, or an old revision advertised as a new one). The `rev` check happens here,
     * after opening; with the shipping sealer it is not part of the associated data.
     *
     * `recordVersion` plays no part: it is backend metadata outside the sealed identity.
     *
     * @throws Exception whatever [sealer] reports for a blob it cannot open
     *   ([com.khm.snippets.core.crypto.SnippetCrypto.Failure] from the shipping sealer).
     * @throws CanonicalJson.Failure when the opened bytes are not JSON.
     * @throws SyncEnvelope.Failure when they are not a valid envelope, or
     *   [SyncEnvelope.Failure.IdentityMismatch] when the envelope is not the one the
     *   record claims to carry.
     */
    @Throws(Exception::class)
    fun open(record: WireRecord, sealer: BlobSealer): SyncEnvelope {
        val identity = WireIdentity(id = record.id, rev = record.rev, deleted = record.deleted)
        val plaintext = sealer.open(record.blobBytes, identity)
        val envelope = SyncEnvelope.parse(plaintext)

        if (envelope.id != record.id) {
            throw SyncEnvelope.Failure.IdentityMismatch(
                "blob is for ${Uuids.lowercase(envelope.id)}, record is ${Uuids.lowercase(record.id)}",
            )
        }
        if (envelope.deleted != record.deleted) {
            throw SyncEnvelope.Failure.IdentityMismatch("deletion flag disagrees with the blob")
        }
        if (sealer.revisionToken(envelope.envelopeHash()) != record.rev) {
            throw SyncEnvelope.Failure.IdentityMismatch("rev does not describe the blob")
        }
        return envelope
    }
}
