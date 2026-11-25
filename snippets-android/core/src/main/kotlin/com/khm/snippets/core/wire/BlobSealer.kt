package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.NonceSource
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.text.FoundationText
import java.util.UUID

/**
 * The three clear-text fields of a [WireRecord]: everything that travels beside the blob
 * (`WireIdentity` in `snippets/Core/SyncEnvelope.swift`).
 *
 * A record is bound to all three, which is the defence against a backend that shuffles
 * records around. The shipping sealer binds [id] and [deleted] through the AEAD tag and
 * [WireCodec.open] checks [rev] after opening; see [SnippetCryptoSealer].
 */
data class WireIdentity(val id: UUID, val rev: String, val deleted: Boolean) {

    /**
     * Canonical JSON of the three fields, `{"deleted":…,"id":"<lowercase>","rev":"…"}`,
     * for a [BlobSealer] that wants pre-rendered associated data.
     *
     * [SnippetCryptoSealer] does **not** use this. Its associated data is
     * [SnippetCrypto.additionalData], which has no `rev` in it. Feeding these bytes to
     * the shipping cipher produces blobs no other device can open.
     */
    @Throws(CanonicalJson.Failure::class)
    fun associatedData(): ByteArray = CanonicalJson.encode(
        JsonValue.obj(
            "id" to JsonValue.of(Uuids.lowercase(id)),
            "rev" to JsonValue.of(rev),
            "deleted" to JsonValue.of(deleted),
        ),
    )
}

/**
 * Sealing and opening one record's bytes (`SyncBlobSealing`).
 *
 * The wire layer knows nothing about key derivation, key storage or the cipher. This
 * interface is the whole seam, which is what lets the sync engine run against the
 * in-memory transport and a throwaway key.
 *
 * The identity is passed, not pre-rendered associated data, because [SnippetCrypto]
 * derives a per-record key from the record id.
 *
 * Arrays: an implementation neither modifies nor keeps the array it is given, and the
 * array it returns belongs to the caller.
 */
interface BlobSealer {

    /** @throws Exception whatever the cipher reports; [WireCodec.seal] lets it through. */
    fun seal(plaintext: ByteArray, identity: WireIdentity): ByteArray

    /**
     * @throws Exception when the blob is not one this sealer made for [identity]: a wrong
     *   key, altered bytes, or a blob moved onto another id or deletion flag.
     */
    fun open(ciphertext: ByteArray, identity: WireIdentity): ByteArray

    /**
     * The value that goes in [WireRecord.rev]. The default is the first 32 characters of
     * the envelope hash, 128 bits.
     *
     * That makes `rev` deterministic in the plaintext envelope: an operator can see that
     * two records are byte-identical, and can confirm a guess only by reconstructing a
     * whole envelope exactly. The determinism is what makes a re-push of unchanged content
     * a no-op. A conformer that wants to close the gap overrides this with an HMAC under a
     * key the fleet holds.
     */
    fun revisionToken(envelopeHash: String): String {
        // `String(envelopeHash.prefix(32))` counts `Character`s. A hash is ASCII hex, where
        // a `Character` is one UTF-16 unit.
        val isPlainAscii = envelopeHash.all { it in '0'..'9' || it in 'a'..'z' || it in 'A'..'Z' }
        return if (isPlainAscii) envelopeHash.take(REVISION_TOKEN_LENGTH)
        else FoundationText.characterPrefix(envelopeHash, REVISION_TOKEN_LENGTH)
    }

    companion object {
        const val REVISION_TOKEN_LENGTH: Int = 32
    }
}

/**
 * The shipping conformance: [SnippetCrypto] driving the wire (`SnippetCryptoSealer`).
 *
 * - The key is per record, derived from the record id by [SnippetCrypto.Keyring.recordKey].
 * - The associated data is [SnippetCrypto.additionalData] for `(scopeId, id, deleted)`.
 *   `rev` is deliberately not in it: [WireCodec.open] recomputes the revision token from
 *   the opened envelope and refuses a mismatch, so a rolled-back revision is caught
 *   without a second associated-data dialect.
 *
 * [scopeId] is the constant [SyncKeyMaterial.SCOPE_ID] for every wire blob; build the
 * sealer with [SyncKeyMaterial.sealer]. A vault body is sealed under the vault's `kid`
 * instead and can never be opened as a wire blob.
 *
 * The sealer keeps the [keyring] it is given and does not copy or close it.
 */
class SnippetCryptoSealer(
    val keyring: SnippetCrypto.Keyring,
    val scopeId: String,
    val nonces: NonceSource = NonceSource.System,
) : BlobSealer {

    private fun context(identity: WireIdentity): SnippetCrypto.RecordContext =
        SnippetCrypto.RecordContext(scopeId = scopeId, recordId = identity.id, isDeleted = identity.deleted)

    /** The blob is the UTF-8 of the `v1.<nonce>.<body>` text [SnippetCrypto.seal] returns. */
    @Throws(SnippetCrypto.Failure::class)
    override fun seal(plaintext: ByteArray, identity: WireIdentity): ByteArray =
        Utf8.encode(SnippetCrypto.seal(plaintext, context(identity), keyring, nonces))

    @Throws(SnippetCrypto.Failure::class)
    override fun open(ciphertext: ByteArray, identity: WireIdentity): ByteArray {
        val text = Utf8.decodeStrict(ciphertext)
            ?: throw SnippetCrypto.Failure.MalformedEnvelope("blob is not a SnippetCrypto envelope")
        return SnippetCrypto.open(text, context(identity), keyring)
    }

    override fun toString(): String = "SnippetCryptoSealer(scopeId=$scopeId)"
}
