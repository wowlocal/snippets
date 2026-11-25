package com.khm.snippets.core.crypto

/**
 * Length hiding for sealed bodies: ISO/IEC 7816-4 to a multiple of 256 bytes
 * (`SnippetCrypto.Padding` in Swift).
 *
 * Append `0x80`, then `0x00` up to the next multiple. There is always at least one pad
 * byte, so a body of exactly `256k` bytes grows by a whole block and an empty body seals
 * to one block. Git key files and Snippets Cloud envelopes are not padded.
 */
object Padding {

    const val BLOCK_SIZE = 256
    private const val MARKER = 0x80.toByte()

    /** A new array; the caller wipes it when [plaintext] was secret. */
    fun pad(plaintext: ByteArray): ByteArray {
        val paddedSize = (plaintext.size / BLOCK_SIZE + 1) * BLOCK_SIZE
        val padded = plaintext.copyOf(paddedSize)
        padded[plaintext.size] = MARKER
        return padded
    }

    /**
     * Strict: a non-empty multiple of the block size whose last non-zero byte is the marker.
     * This only runs on bytes that already passed the GCM tag, so a failure means a peer
     * padded with a scheme this build does not speak.
     */
    @Throws(SnippetCrypto.Failure.MalformedPadding::class)
    fun unpad(padded: ByteArray): ByteArray {
        if (padded.isEmpty() || padded.size % BLOCK_SIZE != 0) throw SnippetCrypto.Failure.MalformedPadding()
        var index = padded.size - 1
        while (index >= 0 && padded[index] == 0.toByte()) index -= 1
        if (index < 0 || padded[index] != MARKER) throw SnippetCrypto.Failure.MalformedPadding()
        return padded.copyOfRange(0, index)
    }
}
