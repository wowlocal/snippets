package com.khm.snippets.core.crypto

import com.khm.snippets.core.text.FoundationText
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * Wrapping a 32-byte key under a human passphrase (`snippets/Core/PassphraseKDF.swift`).
 * Used by the encrypted backup for its export key; `vault.json` reserves the fields.
 *
 * ```
 * pw       = UTF-8(precomposed(passphrase))                // must be non-empty
 * wrapKey  = PBKDF2-HMAC-SHA512(pw, salt, iterations, 32)
 * aad      = domainSeparated("snip.kdf.v1", [alg, u64be(iterations), salt BYTES, kid])
 * envelope = SnippetCrypto.seal(key32, key = wrapKey, aad)
 * ```
 *
 * `precomposed` is Foundation's `precomposedStringWithCanonicalMapping`, reproduced by
 * [FoundationText.foundationPrecomposed]. It is not Unicode NFC: for a few passphrases
 * (a Hangul syllable before a final consonant, U+0F73 after another mark, a supplementary
 * character before a mark, archaic jamo) the two give different bytes, and an Apple device
 * derives from Foundation's.
 *
 * 600 000 rounds take a noticeable fraction of a second, and a file may ask for up to
 * [MAXIMUM_ITERATIONS]: call [wrap], [unwrap] and [derive] off the main thread with a
 * `checkCancelled`, or use [deriveSuspending], [wrapSuspending] and [unwrapSuspending],
 * which run on a background dispatcher and stop when their coroutine is cancelled.
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
     * PBKDF2-HMAC-SHA512 over the UTF-8 of the passphrase in Foundation's precomposed form.
     * The caller wipes [passphrase] and the returned key. The passphrase never becomes a
     * `String`: the normalisation works on arrays and wipes them.
     *
     * [checkCancelled] is called every [Pbkdf2HmacSha512.CANCELLATION_INTERVAL] rounds; what
     * it throws ends the derivation (pass `{ coroutineContext.ensureActive() }`).
     */
    @Throws(Failure::class)
    fun derive(
        passphrase: CharArray,
        salt: ByteArray,
        iterations: Long,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
        checkCancelled: () -> Unit = {},
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
                pbkdf2.derive(password, salt, iterations.toInt(), DERIVED_KEY_BYTE_COUNT, checkCancelled)
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
        checkCancelled: () -> Unit = {},
    ): ByteArray {
        val characters = passphrase.toCharArray()
        try {
            return derive(characters, salt, iterations, pbkdf2, checkCancelled)
        } finally {
            characters.fill('\u0000')
        }
    }

    /**
     * `Array(passphrase.precomposedStringWithCanonicalMapping.utf8)`. Text below U+0300 is
     * never changed by it (the generator checks that against Foundation) and is encoded as
     * it stands; anything else goes through [FoundationText.foundationPrecomposed], whose
     * arrays are wiped here and inside it.
     */
    internal fun normalizedPassword(passphrase: CharArray): ByteArray {
        if (passphrase.all { it.code < 0x0300 }) return Utf8.encode(passphrase)
        val precomposed = FoundationText.foundationPrecomposed(passphrase)
        try {
            return Utf8.encode(precomposed)
        } finally {
            precomposed.fill('\u0000')
        }
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
        checkCancelled: () -> Unit = {},
    ): WrappedKey {
        if (key.size != SnippetCrypto.KEY_BYTE_COUNT) throw SnippetCrypto.Failure.WrongKeySize(key.size)

        val wrapping = derive(passphrase, salt, iterations, pbkdf2, checkCancelled)
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
        checkCancelled: () -> Unit = {},
    ): WrappedKey {
        val characters = passphrase.toCharArray()
        try {
            return wrap(key, characters, salt, kid, iterations, nonces, pbkdf2, checkCancelled)
        } finally {
            characters.fill('\u0000')
        }
    }

    /**
     * Recovers the wrapped key, or throws; the caller wipes the result.
     *
     * [Failure.WrongPassphrase] only for a failed tag. A structural problem with the record
     * keeps its own error, so "wrong passphrase" is never shown for a truncated file, and a
     * platform AES-GCM that fails for another reason stays
     * [SnippetCrypto.Failure.CryptoUnavailable]. As in
     * Swift, the derivation runs before the envelope is parsed.
     */
    @Throws(Failure::class, SnippetCrypto.Failure::class)
    fun unwrap(
        wrapped: WrappedKey,
        passphrase: CharArray,
        kid: String,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
        checkCancelled: () -> Unit = {},
    ): ByteArray {
        if (wrapped.alg != ALGORITHM) throw Failure.UnsupportedAlgorithm(wrapped.alg)
        val salt = Base64Url.decode(wrapped.salt)
        if (salt == null || salt.isEmpty()) throw Failure.InvalidParameters("salt is not base64url")

        val wrapping = derive(passphrase, salt, wrapped.iterations, pbkdf2, checkCancelled)
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
        checkCancelled: () -> Unit = {},
    ): ByteArray {
        val characters = passphrase.toCharArray()
        try {
            return unwrap(wrapped, characters, kid, pbkdf2, checkCancelled)
        } finally {
            characters.fill('\u0000')
        }
    }

    // Suspending conveniences: on [dispatcher], and cancelled with their coroutine.

    /** [derive] on [dispatcher], stopping within [Pbkdf2HmacSha512.CANCELLATION_INTERVAL] rounds of a cancellation. */
    @Throws(Failure::class)
    suspend fun deriveSuspending(
        passphrase: CharArray,
        salt: ByteArray,
        iterations: Long,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
        dispatcher: CoroutineDispatcher = Dispatchers.Default,
    ): ByteArray = withContext(dispatcher) {
        val context = coroutineContext
        derive(passphrase, salt, iterations, pbkdf2) { context.ensureActive() }
    }

    /** [wrap] on [dispatcher], cancelled with its coroutine. */
    @Throws(Failure::class, SnippetCrypto.Failure::class)
    suspend fun wrapSuspending(
        key: ByteArray,
        passphrase: CharArray,
        salt: ByteArray,
        kid: String,
        iterations: Long = ITERATIONS,
        nonces: NonceSource = NonceSource.System,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
        dispatcher: CoroutineDispatcher = Dispatchers.Default,
    ): WrappedKey = withContext(dispatcher) {
        val context = coroutineContext
        wrap(key, passphrase, salt, kid, iterations, nonces, pbkdf2) { context.ensureActive() }
    }

    /** [unwrap] on [dispatcher], cancelled with its coroutine. */
    @Throws(Failure::class, SnippetCrypto.Failure::class)
    suspend fun unwrapSuspending(
        wrapped: WrappedKey,
        passphrase: CharArray,
        kid: String,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
        dispatcher: CoroutineDispatcher = Dispatchers.Default,
    ): ByteArray = withContext(dispatcher) {
        val context = coroutineContext
        unwrap(wrapped, passphrase, kid, pbkdf2) { context.ensureActive() }
    }
}
