package com.khm.snippets.core.wire

import com.khm.snippets.core.crypto.NonceSource
import com.khm.snippets.core.crypto.SnippetCrypto

/**
 * The 64 bytes of a sync library's `K_sync` material and what the wire makes of them
 * (`SyncKeyStore.keyring(from:)` and `SyncKeyStore.account` in
 * `snippets/Sync/SyncKeyStore.swift`).
 *
 * Material is `key(32) ‖ salt(32)`. Where it is stored, and which provider may mint it, is
 * the key store's business and not part of this type.
 */
object SyncKeyMaterial {

    /**
     * The scope bound into every wire blob's associated data, for every provider. A
     * constant, so it can never be regenerated into something else. A vault body uses the
     * vault's `kid` instead; mixing the two only ever yields an authentication failure.
     */
    const val SCOPE_ID: String = "sync-v1"

    const val MATERIAL_BYTE_COUNT: Int = SnippetCrypto.KEY_BYTE_COUNT + SnippetCrypto.SALT_BYTE_COUNT

    /**
     * `SyncKeyStore.Failure.malformedMaterial`. The store's other cases (unavailable key
     * store, missing or unreadable provider record) belong to the store.
     */
    class MalformedMaterial(val count: Int) :
        Exception("the stored sync key must be $MATERIAL_BYTE_COUNT bytes; found $count")

    /**
     * Splits stored material into the keyring the sealer wants: the first 32 bytes are
     * the root key, the last 32 the HKDF salt. The keyring holds copies; [material] is
     * neither modified nor kept, and the caller wipes it.
     */
    @Throws(MalformedMaterial::class)
    fun keyring(material: ByteArray): SnippetCrypto.Keyring {
        if (material.size != MATERIAL_BYTE_COUNT) throw MalformedMaterial(material.size)
        val key = material.copyOfRange(0, SnippetCrypto.KEY_BYTE_COUNT)
        try {
            return SnippetCrypto.Keyring(key, material.copyOfRange(SnippetCrypto.KEY_BYTE_COUNT, MATERIAL_BYTE_COUNT))
        } finally {
            key.fill(0)
        }
    }

    /** The sealer every wire blob goes through: [keyring] of [material] under [SCOPE_ID]. */
    @Throws(MalformedMaterial::class)
    fun sealer(material: ByteArray, nonces: NonceSource = NonceSource.System): SnippetCryptoSealer =
        SnippetCryptoSealer(keyring(material), SCOPE_ID, nonces)
}
