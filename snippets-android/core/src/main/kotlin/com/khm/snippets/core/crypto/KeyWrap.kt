package com.khm.snippets.core.crypto

/**
 * Wrapping `K_lib` under material that is already uniformly random: the recovery key, or
 * a 32-byte stored secret (`snippets/Core/KeyWrap.swift`). One HKDF to separate domains
 * and one AEAD seal; no stretching, because nothing here was chosen by a human.
 *
 * ```
 * wrapKey  = HKDF(ikm = material, salt = vaultSalt, info = "snip.wrap.v1|" ‖ purpose)
 * aad      = domainSeparated("snip.wrap.v1", ["v1", purpose, kid])
 * wrapText = SnippetCrypto.seal(K_lib, key = wrapKey, aad)
 * ```
 *
 * The recovery door is 128 bits strong, not 256: HKDF does not create entropy.
 */
object KeyWrap {

    const val ADDITIONAL_DATA_DOMAIN = "snip.wrap.v1"
    const val WRAPPING_KEY_INFO_PREFIX = "snip.wrap.v1|"

    /** A floor, not a recommendation: anything shorter is not key material. */
    const val MINIMUM_MATERIAL_BYTE_COUNT = 16

    /** Which door a blob belongs to. [rawValue] is in the AAD and the HKDF info, so it is format. */
    enum class Purpose(val rawValue: String) {
        /** `VaultDocument.wrapRecovery` and a Git library's `keys/vault.json`, under recovery-key bytes. */
        RECOVERY("recovery"),

        /** `VaultDocument.wrapCLI`. Reserved: no shipping path writes it, but a reader must be able to open one. */
        CLI("cli"),
    }

    sealed class Failure(message: String) : Exception(message) {

        class MaterialTooShort(val count: Int) :
            Failure("key material is $count bytes; a wrap needs at least $MINIMUM_MATERIAL_BYTE_COUNT")

        /**
         * The AEAD tag rejected the unwrap: wrong material, or a blob from another purpose,
         * another `kid` or another vault. The only failure that depends on what the user supplied.
         */
        class WrongKey(val purpose: Purpose) : Failure(
            when (purpose) {
                Purpose.RECOVERY -> "that recovery key does not unlock this vault"
                Purpose.CLI -> "the stored CLI secret does not unlock this vault"
            },
        )

        class InvalidParameters(val detail: String) : Failure("key wrap has unusable parameters: $detail")
    }

    /** The bytes every wrap of this purpose authenticates. */
    fun additionalData(purpose: Purpose, kid: String): ByteArray = DomainSeparated.encode(
        ADDITIONAL_DATA_DOMAIN,
        Utf8.encode(SnippetCrypto.WIRE_VERSION),
        Utf8.encode(purpose.rawValue),
        Utf8.encode(kid),
    )

    /** Expands raw material into the AES key that wraps `K_lib`. The caller wipes the result. */
    @Throws(Failure::class)
    fun wrappingKey(material: ByteArray, purpose: Purpose, salt: ByteArray): ByteArray {
        if (material.size < MINIMUM_MATERIAL_BYTE_COUNT) throw Failure.MaterialTooShort(material.size)
        if (salt.isEmpty()) throw Failure.InvalidParameters("empty salt")
        return Hkdf.deriveKey(
            inputKeyMaterial = material,
            salt = salt,
            info = Bytes.concat(Utf8.encode(WRAPPING_KEY_INFO_PREFIX), Utf8.encode(purpose.rawValue)),
            outputByteCount = SnippetCrypto.KEY_BYTE_COUNT,
        )
    }

    /** Seals [libraryKey] under [material]: the text for `wrapRecovery` or `wrapCLI`, always 383 characters. */
    @Throws(Failure::class, SnippetCrypto.Failure::class)
    fun wrap(
        libraryKey: ByteArray,
        material: ByteArray,
        purpose: Purpose,
        kid: String,
        salt: ByteArray,
        nonces: NonceSource = NonceSource.System,
    ): String {
        if (libraryKey.size != SnippetCrypto.KEY_BYTE_COUNT) throw SnippetCrypto.Failure.WrongKeySize(libraryKey.size)
        val wrapping = wrappingKey(material, purpose, salt)
        try {
            return SnippetCrypto.seal(libraryKey, wrapping, additionalData(purpose, kid), nonces)
        } finally {
            wrapping.fill(0)
        }
    }

    /**
     * Recovers `K_lib`, or throws; the caller wipes the result. [Failure.WrongKey] only for
     * a failed tag: a structural problem with the blob keeps its own [SnippetCrypto.Failure],
     * so a truncated blob is never reported as a wrong recovery key, and a platform AES-GCM
     * that fails for another reason stays [SnippetCrypto.Failure.CryptoUnavailable].
     */
    @Throws(Failure::class, SnippetCrypto.Failure::class)
    fun unwrap(envelope: String, material: ByteArray, purpose: Purpose, kid: String, salt: ByteArray): ByteArray {
        val wrapping = wrappingKey(material, purpose, salt)
        val recovered = try {
            SnippetCrypto.open(envelope, wrapping, additionalData(purpose, kid))
        } catch (_: SnippetCrypto.Failure.AuthenticationFailed) {
            throw Failure.WrongKey(purpose)
        } finally {
            wrapping.fill(0)
        }
        if (recovered.size != SnippetCrypto.KEY_BYTE_COUNT) {
            val count = recovered.size
            recovered.fill(0)
            throw Failure.InvalidParameters("wrapped key is $count bytes")
        }
        return recovered
    }
}
