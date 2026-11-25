package com.khm.snippets.core.crypto

/**
 * The text form of a sealed body (`SnippetCrypto.Envelope` in Swift):
 *
 * ```
 * "v1" "." b64url(nonce) "." b64url(ciphertext ‖ tag)
 * ```
 *
 * [parse] checks the grammar only. The version, the nonce length and the minimum body
 * length are judged by [SnippetCrypto.open], which reports each differently.
 */
class SealedEnvelope private constructor(
    val version: String,
    internal val nonceBytes: ByteArray,
    internal val sealedBytes: ByteArray,
    @Suppress("UNUSED_PARAMETER") ownsArrays: Unit,
) {

    /** Copies both arrays, so later changes to the arguments do not reach the envelope. */
    constructor(version: String, nonce: ByteArray, sealed: ByteArray) :
        this(version, nonce.copyOf(), sealed.copyOf(), Unit)

    /** A copy; neither field is secret. */
    val nonce: ByteArray get() = nonceBytes.copyOf()

    /** AES-GCM ciphertext with its 16-byte tag appended. A copy. */
    val sealed: ByteArray get() = sealedBytes.copyOf()

    val nonceByteCount: Int get() = nonceBytes.size
    val sealedByteCount: Int get() = sealedBytes.size

    val text: String
        get() = "$version.${Base64Url.encode(nonceBytes)}.${Base64Url.encode(sealedBytes)}"

    override fun equals(other: Any?): Boolean =
        this === other || (
            other is SealedEnvelope && version == other.version &&
                nonceBytes.contentEquals(other.nonceBytes) && sealedBytes.contentEquals(other.sealedBytes)
            )

    override fun hashCode(): Int =
        (version.hashCode() * 31 + nonceBytes.contentHashCode()) * 31 + sealedBytes.contentHashCode()

    override fun toString(): String = "SealedEnvelope($version, ${nonceBytes.size}-byte nonce, ${sealedBytes.size} bytes)"

    companion object {

        /** Takes the arrays without copying. For callers that just produced them and keep no reference. */
        internal fun adopting(version: String, nonce: ByteArray, sealed: ByteArray): SealedEnvelope =
            SealedEnvelope(version, nonce, sealed, Unit)

        /**
         * Exactly three dot-separated fields; empty fields count, so `v1..x` has three and
         * fails on its empty nonce. Both byte fields must be strict unpadded base64url.
         */
        @Throws(SnippetCrypto.Failure.MalformedEnvelope::class)
        fun parse(text: String): SealedEnvelope {
            val parts = text.split('.')
            if (parts.size != 3) {
                throw SnippetCrypto.Failure.MalformedEnvelope("expected 3 dot-separated fields, found ${parts.size}")
            }
            val nonce = Base64Url.decode(parts[1])
                ?: throw SnippetCrypto.Failure.MalformedEnvelope("nonce is not base64url")
            val sealed = Base64Url.decode(parts[2])
                ?: throw SnippetCrypto.Failure.MalformedEnvelope("body is not base64url")
            return SealedEnvelope(parts[0], nonce, sealed, Unit)
        }
    }
}
