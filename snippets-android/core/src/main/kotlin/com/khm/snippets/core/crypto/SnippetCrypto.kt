package com.khm.snippets.core.crypto

import java.security.GeneralSecurityException
import java.util.UUID

/**
 * The AEAD layer for sealed bodies: vault records, wire blobs and every key wrap
 * (`snippets/Core/SnippetCrypto.swift`).
 *
 * ```
 * K_lib  (256 random bits; never used to encrypt)
 *   ├── K_rec(id) = HKDF-SHA256(ikm: K_lib, salt: vaultSalt, info: "snip.wire.v1|" ‖ uuid16(id))
 *   └── K_hash    = HKDF-SHA256(ikm: K_lib, salt: vaultSalt, info: "snip.chash.v1")
 * ```
 *
 * Plaintext and keys are `ByteArray` throughout. Every array a function returns belongs
 * to the caller, who wipes it; arrays passed in are never modified or kept, except by
 * [Keyring], which copies. The JVM cannot wipe the copy it makes inside a `SecretKeySpec`,
 * the same honest limit Swift states for `String`.
 */
object SnippetCrypto {

    /** The envelope prefix, and a field of every AAD, so it cannot be edited without breaking the tag. */
    const val WIRE_VERSION = "v1"

    const val NONCE_BYTE_COUNT = AesGcm.NONCE_BYTES
    const val TAG_BYTE_COUNT = AesGcm.TAG_BYTES
    const val KEY_BYTE_COUNT = AesGcm.KEY_BYTES

    /** The per-vault public HKDF salt. Swift accepts any non-empty salt; this is what a new vault gets. */
    const val SALT_BYTE_COUNT = 32

    const val RECORD_KEY_INFO_PREFIX = "snip.wire.v1|"
    const val CONTENT_HASH_INFO = "snip.chash.v1"
    const val ADDITIONAL_DATA_DOMAIN = "snip.aad.v1"

    /** 128 bits of an HMAC, hex-encoded. */
    const val CONTENT_HASH_BYTE_COUNT = 16

    /**
     * Deliberately coarse where it matters: [AuthenticationFailed] covers a wrong key,
     * altered ciphertext, an altered nonce, mismatched AAD and a ciphertext lifted from
     * another record. Telling them apart would be an oracle, and a caller cannot do
     * anything different with the answer.
     */
    sealed class Failure(message: String) : Exception(message) {

        class MalformedEnvelope(val detail: String) :
            Failure("the sealed record is not a well-formed envelope: $detail")

        class UnsupportedWireVersion(val version: String) :
            Failure("sealed record uses wire version \"$version\"; this build understands \"$WIRE_VERSION\"")

        class AuthenticationFailed : Failure("the sealed record did not authenticate")

        class MalformedPadding :
            Failure("the decrypted record was not padded by a build that speaks this format")

        class MalformedNonce(val count: Int) :
            Failure("a nonce source produced $count bytes; AES-GCM needs $NONCE_BYTE_COUNT")

        class WrongKeySize(val count: Int) : Failure("expected a $KEY_BYTE_COUNT-byte key, got $count")

        /**
         * The platform's AES-GCM failed for a reason other than a failed tag: no provider,
         * or a provider that refused the key or the parameters. Never a statement about the
         * key, so [KeyWrap] and [PassphraseKdf] pass it on instead of reporting a wrong
         * recovery key or passphrase. Swift has no such case (CryptoKit is always there).
         */
        class CryptoUnavailable(cause: GeneralSecurityException) :
            Failure("the platform's AES-GCM is unavailable (${cause.javaClass.simpleName})") {
            init {
                initCause(cause)
            }
        }
    }

    /**
     * A root key and the salt it is bound to; every other key is derived on demand and
     * nothing is cached. Used for `K_lib` with `vaultSalt`, and for the two halves of a
     * sync library's `K_sync` material.
     *
     * The constructor copies both arrays. Call [close] to wipe the copy when the vault locks.
     *
     * A closed keyring fails closed: every accessor, and every seal, open or content hash
     * through it, throws [IllegalStateException]. It never answers from the wiped (all-zero)
     * key, which would seal records anyone holding the public salt could open. Swift has no
     * such state, its keyring being a value that cannot be emptied.
     */
    class Keyring(libraryKey: ByteArray, salt: ByteArray) : AutoCloseable {

        private val rootKey = libraryKey.copyOf()
        private val saltBytes = salt.copyOf()

        @Volatile
        private var closed = false

        /** Whether [close] has been called. */
        val isClosed: Boolean get() = closed

        private fun checkOpen() {
            check(!closed) { "the keyring was closed; its key has been wiped" }
        }

        /** The root never seals anything itself. A copy the caller wipes. */
        fun libraryKey(): ByteArray {
            checkOpen()
            return rootKey.copyOf()
        }

        /** Public, stored in the clear beside the wrapped key. A copy. */
        fun salt(): ByteArray {
            checkOpen()
            return saltBytes.copyOf()
        }

        /** `K_rec(id)`. The info string takes the 16 raw UUID bytes, never the text form. */
        fun recordKey(recordId: UUID): ByteArray {
            checkOpen()
            val key = Hkdf.deriveKey(
                inputKeyMaterial = rootKey,
                salt = saltBytes,
                info = Bytes.concat(Utf8.encode(RECORD_KEY_INFO_PREFIX), Uuids.toBytes(recordId)),
                outputByteCount = KEY_BYTE_COUNT,
            )
            return checkedAfterUse(key)
        }

        /** `K_hash`, separate from every record key. */
        fun contentHashKey(): ByteArray {
            checkOpen()
            val key = Hkdf.deriveKey(
                inputKeyMaterial = rootKey,
                salt = saltBytes,
                info = Utf8.encode(CONTENT_HASH_INFO),
                outputByteCount = KEY_BYTE_COUNT,
            )
            return checkedAfterUse(key)
        }

        /** A [close] that raced the derivation may have zeroed the root under it: refuse that key. */
        private fun checkedAfterUse(key: ByteArray): ByteArray {
            if (closed) {
                key.fill(0)
                checkOpen()
            }
            return key
        }

        /** Zeroes the root key held here. Every later use of this keyring throws [IllegalStateException]. */
        override fun close() {
            closed = true
            rootKey.fill(0)
        }

        override fun toString(): String = "Keyring(redacted)"

        companion object {
            /** A new library: 256 random bits and a fresh salt from the system CSPRNG. */
            fun generate(): Keyring {
                val key = Bytes.random(KEY_BYTE_COUNT)
                try {
                    return Keyring(key, Bytes.random(SALT_BYTE_COUNT))
                } finally {
                    key.fill(0)
                }
            }
        }
    }

    /**
     * Everything a ciphertext is pinned to. None of it is secret; all of it is authenticated.
     *
     * [scopeId] is the vault's `kid` for a vault body and the constant `sync-v1` for a wire
     * blob. It must come from the document that holds the ciphertext, never from sync state.
     */
    data class RecordContext(val scopeId: String, val recordId: UUID, val isDeleted: Boolean = false)

    /** The one AAD builder for records: `domainSeparated("snip.aad.v1", ["v1", scope, uuid16(id), deleted])`. */
    fun additionalData(context: RecordContext): ByteArray = DomainSeparated.encode(
        ADDITIONAL_DATA_DOMAIN,
        Utf8.encode(WIRE_VERSION),
        Utf8.encode(context.scopeId),
        Uuids.toBytes(context.recordId),
        byteArrayOf(if (context.isDeleted) 1 else 0),
    )

    /** See [DomainSeparated]. Kept here under its Swift name. */
    fun domainSeparated(domain: String, fields: List<ByteArray>): ByteArray = DomainSeparated.encode(domain, fields)

    // Seal and open

    /** Seals a record body: derives the record key and builds the AAD from the same [context]. */
    @Throws(Failure::class)
    fun seal(
        plaintext: ByteArray,
        context: RecordContext,
        keyring: Keyring,
        nonces: NonceSource = NonceSource.System,
    ): String {
        val key = keyring.recordKey(context.recordId)
        try {
            return seal(plaintext, key, additionalData(context), nonces)
        } finally {
            key.fill(0)
        }
    }

    /** Opens a body sealed for [context]. Another id, scope or deleted flag fails as [Failure.AuthenticationFailed]. */
    @Throws(Failure::class)
    fun open(envelope: String, context: RecordContext, keyring: Keyring): ByteArray {
        val key = keyring.recordKey(context.recordId)
        try {
            return open(envelope, key, additionalData(context))
        } finally {
            key.fill(0)
        }
    }

    /**
     * Pads, then seals under [key] with one nonce from [nonces].
     *
     * [aad] must come from one of the AAD builders. AES-GCM accepts empty AAD and nothing
     * here can tell the difference.
     */
    @Throws(Failure::class)
    fun seal(
        plaintext: ByteArray,
        key: ByteArray,
        aad: ByteArray,
        nonces: NonceSource = NonceSource.System,
    ): String {
        if (key.size != KEY_BYTE_COUNT) throw Failure.WrongKeySize(key.size)

        val nonce = nonces.nextNonce()
        if (nonce.size != NONCE_BYTE_COUNT) throw Failure.MalformedNonce(nonce.size)

        val padded = Padding.pad(plaintext)
        val sealed = try {
            AesGcm.seal(key, nonce, padded, aad)
        } catch (failure: GeneralSecurityException) {
            // Not reachable with a 32-byte key and a 12-byte nonce on a working provider.
            // Reported rather than crashing, as Swift does: this runs on the sync path.
            throw Failure.CryptoUnavailable(failure)
        } finally {
            padded.fill(0)
        }
        return SealedEnvelope.adopting(WIRE_VERSION, nonce.copyOf(), sealed).text
    }

    /** Parses, authenticates, decrypts and unpads. Returns the exact bytes handed to `seal`. */
    @Throws(Failure::class)
    fun open(envelope: String, key: ByteArray, aad: ByteArray): ByteArray {
        if (key.size != KEY_BYTE_COUNT) throw Failure.WrongKeySize(key.size)

        val parsed = SealedEnvelope.parse(envelope)
        if (parsed.version != WIRE_VERSION) throw Failure.UnsupportedWireVersion(parsed.version)
        if (parsed.nonceByteCount != NONCE_BYTE_COUNT) {
            throw Failure.MalformedEnvelope("nonce is ${parsed.nonceByteCount} bytes, expected $NONCE_BYTE_COUNT")
        }
        if (parsed.sealedByteCount <= TAG_BYTE_COUNT) {
            throw Failure.MalformedEnvelope("body is too short to contain a tag")
        }

        val padded = try {
            AesGcm.open(key, parsed.nonceBytes, parsed.sealedBytes, aad)
        } catch (failure: GeneralSecurityException) {
            throw Failure.CryptoUnavailable(failure)
        } ?: throw Failure.AuthenticationFailed()
        try {
            return Padding.unpad(padded)
        } finally {
            padded.fill(0)
        }
    }

    // Content hash

    /**
     * A keyed hash of the plaintext body: `hex(HMAC-SHA256(K_hash, body)[0..<16])`, 32
     * lowercase characters. Keyed because it is stored in the clear next to the ciphertext;
     * an unkeyed hash of a PIN is the PIN.
     *
     * This is `VaultRecord.contentHash` and the wire's `x.vaultContentHash`. It is not the
     * envelope's top-level `contentHash`, which is a plain SHA-256.
     */
    fun contentHash(plaintext: ByteArray, key: ByteArray): String {
        val code = HmacSha256.authenticationCode(key, plaintext)
        return Bytes.toHex(code, 0, CONTENT_HASH_BYTE_COUNT)
    }

    fun contentHash(plaintext: ByteArray, keyring: Keyring): String {
        val key = keyring.contentHashKey()
        try {
            return contentHash(plaintext, key)
        } finally {
            key.fill(0)
        }
    }

    // Plumbing

    /**
     * The final hop, and the only place plaintext becomes a `String`, which can never be
     * wiped. `null` for invalid UTF-8 rather than replacement characters.
     */
    fun plaintextString(plaintext: ByteArray): String? = Utf8.decodeStrict(plaintext)

    fun randomBytes(count: Int): ByteArray = Bytes.random(count)

    fun uuidBytes(id: UUID): ByteArray = Uuids.toBytes(id)
}
