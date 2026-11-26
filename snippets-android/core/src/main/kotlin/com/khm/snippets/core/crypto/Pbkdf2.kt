package com.khm.snippets.core.crypto

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
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

    /**
     * As [derive], calling [checkCancelled] before the first round and then every
     * [CANCELLATION_INTERVAL] rounds; whatever it throws (a `CancellationException` from
     * `ensureActive()`) ends the derivation, with every buffer wiped. Swift accepts up to
     * `PassphraseKdf.MAXIMUM_ITERATIONS` rounds from a file anyone can edit, and so does
     * this, so an unlock the user gave up on must be able to stop.
     *
     * The default implementation only checks before and after: an implementation that can
     * stop in the middle overrides it.
     */
    fun derive(
        password: ByteArray,
        salt: ByteArray,
        iterations: Int,
        derivedKeyByteCount: Int,
        checkCancelled: () -> Unit,
    ): ByteArray {
        checkCancelled()
        val key = derive(password, salt, iterations, derivedKeyByteCount)
        try {
            checkCancelled()
        } catch (cancelled: Throwable) {
            key.fill(0)
            throw cancelled
        }
        return key
    }

    companion object {
        /** Rounds between two calls of the cancellation check. */
        const val CANCELLATION_INTERVAL = 4_096

        /**
         * [MacPbkdf2HmacSha512]. It is the default because its correctness does not rest on
         * how a provider converts `char[]` to bytes: the bytes it is given are the bytes it hashes.
         */
        val Default: Pbkdf2HmacSha512 = MacPbkdf2HmacSha512
    }
}

/**
 * PBKDF2 written out in Kotlin. Works on the raw password bytes, so any byte string is a
 * valid password, including one that is not UTF-8.
 *
 * HMAC is computed by hand from two `MessageDigest("SHA-512")` states keyed once
 * (`SHA-512(K ⊕ ipad)` and `SHA-512(K ⊕ opad)` after one block each) and cloned for every
 * round, so a round is two compressions of the message and no allocation: a `Mac` re-hashes
 * the padded key every time it is reset, and Conscrypt's may allocate a native context per
 * `doFinal`. Where a provider's digest cannot be cloned the derivation falls back to
 * `Mac("HmacSHA512")`, which gives the same bytes ([macDerive], kept for that and for the tests).
 */
object MacPbkdf2HmacSha512 : Pbkdf2HmacSha512 {

    private const val ALGORITHM = "HmacSHA512"
    private const val DIGEST = "SHA-512"
    private const val HASH_BYTES = 64
    private const val BLOCK_BYTES = 128

    override fun derive(password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int): ByteArray =
        derive(password, salt, iterations, derivedKeyByteCount) {}

    override fun derive(
        password: ByteArray,
        salt: ByteArray,
        iterations: Int,
        derivedKeyByteCount: Int,
        checkCancelled: () -> Unit,
    ): ByteArray {
        require(iterations > 0) { "iterations must be positive" }
        require(derivedKeyByteCount > 0) { "derived key length must be positive" }
        checkCancelled()
        val keyed = KeyedSha512.of(password) ?: return macDerive(password, salt, iterations, derivedKeyByteCount, checkCancelled)
        try {
            return keyed.derive(salt, iterations, derivedKeyByteCount, checkCancelled)
        } catch (_: CloneNotSupportedException) {
            return macDerive(password, salt, iterations, derivedKeyByteCount, checkCancelled)
        }
    }

    /** The previous implementation over `Mac("HmacSHA512")`: the fallback, and a reference for the tests. */
    internal fun macDerive(
        password: ByteArray,
        salt: ByteArray,
        iterations: Int,
        derivedKeyByteCount: Int,
        checkCancelled: () -> Unit = {},
    ): ByteArray {
        require(iterations > 0) { "iterations must be positive" }
        require(derivedKeyByteCount > 0) { "derived key length must be positive" }

        checkCancelled()
        // `SecretKeySpec` refuses an empty key; HMAC zero-pads, so one zero byte is the same key.
        val key = if (password.isEmpty()) ByteArray(1) else password
        val mac = Mac.getInstance(ALGORITHM).apply { init(SecretKeySpec(key, ALGORITHM)) }

        val out = ByteArray(derivedKeyByteCount)
        val running = ByteArray(HASH_BYTES)
        val block = ByteArray(HASH_BYTES)
        var succeeded = false
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
                    if (round % Pbkdf2HmacSha512.CANCELLATION_INTERVAL == 0) checkCancelled()
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
            succeeded = true
            return out
        } finally {
            running.fill(0)
            block.fill(0)
            if (!succeeded) out.fill(0)
        }
    }

    /**
     * `SHA-512(K' ⊕ ipad)` and `SHA-512(K' ⊕ opad)` with one block absorbed each, where
     * `K'` is the password, or its SHA-512 when it is longer than a block, zero-padded.
     * Cloning one of them is where an HMAC computation starts.
     */
    private class KeyedSha512(private val inner: MessageDigest, private val outer: MessageDigest) {

        /** @throws CloneNotSupportedException when the provider's digest cannot be copied. */
        fun derive(salt: ByteArray, iterations: Int, derivedKeyByteCount: Int, checkCancelled: () -> Unit): ByteArray {
            val out = ByteArray(derivedKeyByteCount)
            val running = ByteArray(HASH_BYTES)
            val block = ByteArray(HASH_BYTES)
            val counter = ByteArray(4)
            var succeeded = false
            try {
                var blockIndex = 1
                var position = 0
                while (position < derivedKeyByteCount) {
                    counter[0] = (blockIndex ushr 24).toByte()
                    counter[1] = (blockIndex ushr 16).toByte()
                    counter[2] = (blockIndex ushr 8).toByte()
                    counter[3] = blockIndex.toByte()

                    // U1 = HMAC(salt ‖ INT_32_BE(i))
                    val first = inner.clone() as MessageDigest
                    first.update(salt)
                    first.update(counter)
                    finish(first, running)
                    running.copyInto(block)

                    for (round in 1 until iterations) {
                        if (round % Pbkdf2HmacSha512.CANCELLATION_INTERVAL == 0) checkCancelled()
                        val digest = inner.clone() as MessageDigest
                        digest.update(running, 0, HASH_BYTES)
                        finish(digest, running)
                        for (index in 0 until HASH_BYTES) {
                            block[index] = (block[index].toInt() xor running[index].toInt()).toByte()
                        }
                    }
                    val take = minOf(HASH_BYTES, derivedKeyByteCount - position)
                    block.copyInto(out, position, 0, take)
                    position += take
                    blockIndex += 1
                }
                succeeded = true
                return out
            } finally {
                running.fill(0)
                block.fill(0)
                inner.reset()
                outer.reset()
                if (!succeeded) out.fill(0)
            }
        }

        /** Completes the inner hash in [digest] and the outer one over it, writing the HMAC to [into]. */
        private fun finish(digest: MessageDigest, into: ByteArray) {
            digest.digest(into, 0, HASH_BYTES)
            val second = outer.clone() as MessageDigest
            second.update(into, 0, HASH_BYTES)
            second.digest(into, 0, HASH_BYTES)
        }

        companion object {
            /** `null` when the provider's SHA-512 cannot be cloned, which the caller learns before any round. */
            fun of(password: ByteArray): KeyedSha512? {
                val inner = MessageDigest.getInstance(DIGEST)
                val outer = MessageDigest.getInstance(DIGEST)
                val padded = ByteArray(BLOCK_BYTES)
                try {
                    if (password.size > BLOCK_BYTES) {
                        val hashed = MessageDigest.getInstance(DIGEST)
                        hashed.update(password)
                        hashed.digest(padded, 0, HASH_BYTES)
                    } else {
                        password.copyInto(padded)
                    }
                    for (index in padded.indices) padded[index] = (padded[index].toInt() xor 0x36).toByte()
                    inner.update(padded)
                    for (index in padded.indices) padded[index] = (padded[index].toInt() xor (0x36 xor 0x5C)).toByte()
                    outer.update(padded)
                    // A provider that cannot clone says so here, before anything else is computed.
                    try {
                        (inner.clone() as MessageDigest).reset()
                    } catch (_: CloneNotSupportedException) {
                        inner.reset()
                        outer.reset()
                        return null
                    }
                    return KeyedSha512(inner, outer)
                } finally {
                    padded.fill(0)
                }
            }
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
 * alternative to measure and cross-check against; it is not the default. It cannot stop in
 * the middle: [derive] with a cancellation check only checks before and after.
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
