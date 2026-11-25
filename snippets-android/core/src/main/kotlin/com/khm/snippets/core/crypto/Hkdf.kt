package com.khm.snippets.core.crypto

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** HMAC-SHA256 over the platform `Mac`. The key is copied into a `SecretKeySpec` the JVM owns and cannot be wiped. */
internal object HmacSha256 {

    const val OUTPUT_BYTES = 32
    private const val ALGORITHM = "HmacSHA256"

    fun mac(key: ByteArray): Mac {
        // `SecretKeySpec` refuses an empty key. HMAC zero-pads its key to the block size,
        // so one zero byte is the same key as the empty one.
        val material = if (key.isEmpty()) ByteArray(1) else key
        return Mac.getInstance(ALGORITHM).apply { init(SecretKeySpec(material, ALGORITHM)) }
    }

    fun authenticationCode(key: ByteArray, message: ByteArray): ByteArray = mac(key).doFinal(message)
}

/**
 * HKDF-SHA256 (RFC 5869): extract, then expand. Android has no JCA provider for it.
 *
 * Mirrors CryptoKit's `HKDF<SHA256>.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`.
 * Returned arrays belong to the caller, who wipes them.
 */
object Hkdf {

    const val HASH_BYTES = HmacSha256.OUTPUT_BYTES
    const val MAXIMUM_OUTPUT_BYTES = 255 * HASH_BYTES

    /** `PRK = HMAC(salt, IKM)`. An empty salt is `HASH_BYTES` zero bytes, per the RFC. */
    fun extract(salt: ByteArray, inputKeyMaterial: ByteArray): ByteArray =
        HmacSha256.authenticationCode(salt, inputKeyMaterial)

    /** `OKM = T(1) ‖ T(2) ‖ …`, `T(n) = HMAC(PRK, T(n-1) ‖ info ‖ n)`, truncated to [outputByteCount]. */
    fun expand(pseudoRandomKey: ByteArray, info: ByteArray, outputByteCount: Int): ByteArray {
        require(outputByteCount in 0..MAXIMUM_OUTPUT_BYTES) { "HKDF-SHA256 yields at most $MAXIMUM_OUTPUT_BYTES bytes" }
        val mac = HmacSha256.mac(pseudoRandomKey)
        val out = ByteArray(outputByteCount)
        var block = ByteArray(0)
        var position = 0
        var counter = 1
        while (position < outputByteCount) {
            mac.update(block)
            mac.update(info)
            mac.update(counter.toByte())
            block.fill(0)
            block = mac.doFinal()
            val take = minOf(block.size, outputByteCount - position)
            block.copyInto(out, position, 0, take)
            position += take
            counter += 1
        }
        block.fill(0)
        return out
    }

    fun deriveKey(
        inputKeyMaterial: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        outputByteCount: Int = HASH_BYTES,
    ): ByteArray {
        val pseudoRandomKey = extract(salt, inputKeyMaterial)
        try {
            return expand(pseudoRandomKey, info, outputByteCount)
        } finally {
            pseudoRandomKey.fill(0)
        }
    }
}
