package com.khm.snippets.core.crypto

import java.nio.CharBuffer
import java.text.Normalizer

/**
 * Wrapping a 32-byte key under a human passphrase (`snippets/Core/PassphraseKDF.swift`).
 * Used by the encrypted backup for its export key; `vault.json` reserves the fields.
 *
 * ```
 * pw       = UTF-8(NFC(passphrase))                        // must be non-empty
 * wrapKey  = PBKDF2-HMAC-SHA512(pw, salt, iterations, 32)
 * aad      = domainSeparated("snip.kdf.v1", [alg, u64be(iterations), salt BYTES, kid])
 * envelope = SnippetCrypto.seal(key32, key = wrapKey, aad)
 * ```
 *
 * 600 000 rounds take a noticeable fraction of a second: call [wrap], [unwrap] and
 * [derive] off the main thread.
 */
object PassphraseKdf {

    /** Recorded verbatim in every wrapped-key record. */
    const val ALGORITHM = "pbkdf2-hmac-sha512"

    /** Pinned. Not a preference and not calibrated to the device. */
    const val ITERATIONS = 600_000L

    /** The count is read from a file anybody can edit; without a ceiling a hostile file wedges the unlock. */
    const val MAXIMUM_ITERATIONS = 20_000_000L

    const val SALT_BYTE_COUNT = 16
    const val DERIVED_KEY_BYTE_COUNT = 32

    const val ADDITIONAL_DATA_DOMAIN = "snip.kdf.v1"

    sealed class Failure(message: String) : Exception(message) {

        class EmptyPassphrase : Failure("an empty passphrase cannot protect anything")

        class UnsupportedAlgorithm(val algorithm: String) :
            Failure("wrapped key uses \"$algorithm\"; this build understands \"$ALGORITHM\"")

        class InvalidParameters(val detail: String) : Failure("wrapped key has unusable parameters: $detail")

        /** Swift carries CommonCrypto's status. Here it is `-1`: the platform PBKDF2 or HMAC threw. */
        class DerivationFailed(val status: Int) : Failure("PBKDF2 failed with status $status")

        /**
         * The AEAD tag rejected the unwrap. Almost always a mistyped passphrase; also what an
         * edited `iterations` or `salt` produces. Never used for a structural problem.
         */
        class WrongPassphrase : Failure("that passphrase does not unlock this vault")
    }

    /**
     * Exactly what is stored: `{ "alg", "iterations", "salt", "envelope" }`. There is no
     * verifier field; the envelope's tag is the only gate.
     *
     * [iterations] is a `Long` because Swift decodes it as a 64-bit `Int`: a file claiming
     * five billion rounds must be refused as out of range, not fail to decode.
     */
    data class WrappedKey(
        val alg: String,
        val iterations: Long,
        /** base64url. Per-wrap, random, public. */
        val salt: String,
        /** A [SnippetCrypto] envelope over the 32 raw key bytes. */
        val envelope: String,
    )

    fun makeSalt(): ByteArray = Bytes.random(SALT_BYTE_COUNT)

    /** Binds the KDF parameters and the owner's identity. [salt] is the decoded bytes, not the base64url text. */
    fun additionalData(alg: String, iterations: Long, salt: ByteArray, kid: String): ByteArray {
        // Swift's `UInt64(iterations)` traps on a negative count; `derive` always rejects one first.
        require(iterations >= 0) { "iterations must not be negative" }
        return DomainSeparated.encode(
            ADDITIONAL_DATA_DOMAIN,
            Utf8.encode(alg),
            Bytes.u64be(iterations),
            salt,
            Utf8.encode(kid),
        )
    }

    /**
     * PBKDF2-HMAC-SHA512 over the NFC-normalised UTF-8 of the passphrase. The caller wipes
     * [passphrase] and the returned key.
     *
     * A passphrase that is already NFC (nearly all are) never becomes a `String`. One that
     * is not is normalised by `java.text.Normalizer`, which can only return a `String`.
     */
    @Throws(Failure::class)
    fun derive(
        passphrase: CharArray,
        salt: ByteArray,
        iterations: Long,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
    ): ByteArray {
        val password = normalizedPassword(passphrase)
        try {
            if (password.isEmpty()) throw Failure.EmptyPassphrase()
            if (salt.isEmpty()) throw Failure.InvalidParameters("empty salt")
            if (iterations <= 0) throw Failure.InvalidParameters("iterations must be positive")
            if (iterations > MAXIMUM_ITERATIONS) {
                throw Failure.InvalidParameters("$iterations iterations exceeds the $MAXIMUM_ITERATIONS ceiling")
            }
            return try {
                pbkdf2.derive(password, salt, iterations.toInt(), DERIVED_KEY_BYTE_COUNT)
            } catch (_: java.security.GeneralSecurityException) {
                throw Failure.DerivationFailed(-1)
            }
        } finally {
            password.fill(0)
        }
    }

    /** As [derive] for a caller that only has a `String`, which cannot be wiped. */
    @Throws(Failure::class)
    fun derive(
        passphrase: String,
        salt: ByteArray,
        iterations: Long,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
    ): ByteArray {
        val characters = passphrase.toCharArray()
        try {
            return derive(characters, salt, iterations, pbkdf2)
        } finally {
            characters.fill('\u0000')
        }
    }

    /** `Array(passphrase.precomposedStringWithCanonicalMapping.utf8)`. */
    private fun normalizedPassword(passphrase: CharArray): ByteArray =
        if (Normalizer.isNormalized(CharBuffer.wrap(passphrase), Normalizer.Form.NFC)) {
            Utf8.encode(passphrase)
        } else {
            Utf8.encode(Normalizer.normalize(CharBuffer.wrap(passphrase), Normalizer.Form.NFC))
        }

    /**
     * Seals [key] under [passphrase]. [salt] is a parameter so that generating randomness
     * is a visible decision at the call site; a new wrap uses [makeSalt].
     */
    @Throws(Failure::class, SnippetCrypto.Failure::class)
    fun wrap(
        key: ByteArray,
        passphrase: CharArray,
        salt: ByteArray,
        kid: String,
        iterations: Long = ITERATIONS,
        nonces: NonceSource = NonceSource.System,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
    ): WrappedKey {
        if (key.size != SnippetCrypto.KEY_BYTE_COUNT) throw SnippetCrypto.Failure.WrongKeySize(key.size)

        val wrapping = derive(passphrase, salt, iterations, pbkdf2)
        try {
            val aad = additionalData(ALGORITHM, iterations, salt, kid)
            return WrappedKey(
                alg = ALGORITHM,
                iterations = iterations,
                salt = Base64Url.encode(salt),
                envelope = SnippetCrypto.seal(key, wrapping, aad, nonces),
            )
        } finally {
            wrapping.fill(0)
        }
    }

    @Throws(Failure::class, SnippetCrypto.Failure::class)
    fun wrap(
        key: ByteArray,
        passphrase: String,
        salt: ByteArray,
        kid: String,
        iterations: Long = ITERATIONS,
        nonces: NonceSource = NonceSource.System,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
    ): WrappedKey {
        val characters = passphrase.toCharArray()
        try {
            return wrap(key, characters, salt, kid, iterations, nonces, pbkdf2)
        } finally {
            characters.fill('\u0000')
        }
    }

    /**
     * Recovers the wrapped key, or throws; the caller wipes the result.
     *
     * [Failure.WrongPassphrase] only for a failed tag. A structural problem with the record
     * keeps its own error, so "wrong passphrase" is never shown for a truncated file. As in
     * Swift, the derivation runs before the envelope is parsed.
     */
    @Throws(Failure::class, SnippetCrypto.Failure::class)
    fun unwrap(
        wrapped: WrappedKey,
        passphrase: CharArray,
        kid: String,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
    ): ByteArray {
        if (wrapped.alg != ALGORITHM) throw Failure.UnsupportedAlgorithm(wrapped.alg)
        val salt = Base64Url.decode(wrapped.salt)
        if (salt == null || salt.isEmpty()) throw Failure.InvalidParameters("salt is not base64url")

        val wrapping = derive(passphrase, salt, wrapped.iterations, pbkdf2)
        val material = try {
            val aad = additionalData(wrapped.alg, wrapped.iterations, salt, kid)
            SnippetCrypto.open(wrapped.envelope, wrapping, aad)
        } catch (_: SnippetCrypto.Failure.AuthenticationFailed) {
            throw Failure.WrongPassphrase()
        } finally {
            wrapping.fill(0)
        }

        if (material.size != SnippetCrypto.KEY_BYTE_COUNT) {
            val count = material.size
            material.fill(0)
            throw Failure.InvalidParameters("wrapped key is $count bytes")
        }
        return material
    }

    @Throws(Failure::class, SnippetCrypto.Failure::class)
    fun unwrap(
        wrapped: WrappedKey,
        passphrase: String,
        kid: String,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
    ): ByteArray {
        val characters = passphrase.toCharArray()
        try {
            return unwrap(wrapped, characters, kid, pbkdf2)
        } finally {
            characters.fill('\u0000')
        }
    }
}
