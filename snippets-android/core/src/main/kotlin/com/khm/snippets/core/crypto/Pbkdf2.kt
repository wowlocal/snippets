package com.khm.snippets.core.crypto

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * PBKDF2-HMAC-SHA512 (RFC 8018) over password **bytes**, as `CCKeyDerivationPBKDF` takes them.
 *
 * The caller owns [derive]'s arguments and its result, and wipes them.
 */
fun interface Pbkdf2HmacSha512 {

    fun derive(password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int): ByteArray

    companion object {
        /**
         * [MacPbkdf2HmacSha512]. It is the default because its correctness does not rest on
         * how a provider converts `char[]` to bytes: the bytes it is given are the bytes it hashes.
         */
        val Default: Pbkdf2HmacSha512 = MacPbkdf2HmacSha512
    }
}

/**
 * PBKDF2 written out in Kotlin over `Mac("HmacSHA512")`. Works on the raw password bytes,
 * so any byte string is a valid password, including one that is not UTF-8.
 */
object MacPbkdf2HmacSha512 : Pbkdf2HmacSha512 {

    private const val ALGORITHM = "HmacSHA512"
    private const val HASH_BYTES = 64

    override fun derive(password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int): ByteArray {
        require(iterations > 0) { "iterations must be positive" }
        require(derivedKeyByteCount > 0) { "derived key length must be positive" }

        // `SecretKeySpec` refuses an empty key; HMAC zero-pads, so one zero byte is the same key.
        val key = if (password.isEmpty()) ByteArray(1) else password
        val mac = Mac.getInstance(ALGORITHM).apply { init(SecretKeySpec(key, ALGORITHM)) }

        val out = ByteArray(derivedKeyByteCount)
        val running = ByteArray(HASH_BYTES)
        val block = ByteArray(HASH_BYTES)
        try {
            var blockIndex = 1
            var position = 0
            while (position < derivedKeyByteCount) {
                // U1 = PRF(password, salt ‖ INT_32_BE(i))
                mac.update(salt)
                mac.update(Bytes.u32be(blockIndex))
                mac.doFinal(running, 0)
                running.copyInto(block)
                for (round in 1 until iterations) {
                    // Un = PRF(password, Un-1); T = U1 xor U2 xor … xor Uc
                    mac.update(running)
                    mac.doFinal(running, 0)
                    for (index in 0 until HASH_BYTES) {
                        block[index] = (block[index].toInt() xor running[index].toInt()).toByte()
                    }
                }
                val take = minOf(HASH_BYTES, derivedKeyByteCount - position)
                block.copyInto(out, position, 0, take)
                position += take
                blockIndex += 1
            }
            return out
        } finally {
            running.fill(0)
            block.fill(0)
        }
    }
}

/**
 * The platform's `SecretKeyFactory("PBKDF2WithHmacSHA512")`.
 *
 * `PBEKeySpec` only takes `char[]`, and the provider turns it back into bytes itself.
 * SunJCE encodes them as UTF-8, which the tests confirm for decomposed, astral and
 * compatibility characters; Android documents the same for this algorithm name (API 26+)
 * but that has not been measured on a device. A password that is not valid UTF-8 cannot be
 * expressed as `char[]` at all and is refused with [IllegalArgumentException]. Kept as an
 * alternative to measure and cross-check against; it is not the default.
 */
object JcaPbkdf2HmacSha512 : Pbkdf2HmacSha512 {

    private const val ALGORITHM = "PBKDF2WithHmacSHA512"

    override fun derive(password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int): ByteArray {
        require(iterations > 0) { "iterations must be positive" }
        require(derivedKeyByteCount > 0) { "derived key length must be positive" }

        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val decoded = try {
            decoder.decode(ByteBuffer.wrap(password))
        } catch (_: CharacterCodingException) {
            throw IllegalArgumentException("the JCA PBKDF2 provider can only take a UTF-8 password")
        }
        val characters = CharArray(decoded.remaining())
        decoded.get(characters)
        if (decoded.hasArray()) decoded.array().fill('\u0000')

        val spec = PBEKeySpec(characters, salt, iterations, derivedKeyByteCount * 8)
        try {
            return SecretKeyFactory.getInstance(ALGORITHM).generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
            characters.fill('\u0000')
        }
    }
}
