package com.khm.snippets.core.crypto

import java.security.GeneralSecurityException
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * AES-256-GCM with a caller-supplied 96-bit nonce and a 128-bit tag.
 *
 * Every key here is an in-memory format key (a record key, a wrapping key), so this uses
 * the default provider with a `SecretKeySpec`. The Android Keystore provider is the wrong
 * tool for these: its keys never leave it, and it chooses the IV itself unless randomized
 * encryption is switched off.
 *
 * A fresh `Cipher` per call: a JCA GCM cipher refuses to encrypt twice with one key and
 * IV on the same instance, and instances are not thread-safe.
 */
object AesGcm {

    const val KEY_BYTES = 32
    const val NONCE_BYTES = 12
    const val TAG_BYTES = 16

    /** `nonce ‖ ciphertext ‖ tag` cannot be shorter than this (CryptoKit's `SealedBox(combined:)` floor). */
    const val COMBINED_OVERHEAD_BYTES = NONCE_BYTES + TAG_BYTES

    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    /** The JCA transformation asked for. A test replaces it to make the provider fail; nothing else may. */
    @Volatile
    internal var transformation: String = TRANSFORMATION

    /** Returns `ciphertext ‖ tag`. */
    @Throws(GeneralSecurityException::class)
    fun seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, additionalData: ByteArray): ByteArray =
        cipher(Cipher.ENCRYPT_MODE, key, nonce, additionalData).doFinal(plaintext)

    /**
     * Opens `ciphertext ‖ tag`. `null` when it does not authenticate, whatever the reason:
     * wrong key, wrong nonce, wrong additional data or altered bytes are one answer on purpose.
     *
     * Only a failed tag ([AEADBadTagException]) is that answer. Any other
     * [GeneralSecurityException] (no AES-GCM provider, a provider refusing the key or the
     * parameters) is thrown: it says nothing about the key, and reporting it as one would
     * tell the user their passphrase or recovery key is wrong.
     */
    @Throws(GeneralSecurityException::class)
    fun open(key: ByteArray, nonce: ByteArray, sealed: ByteArray, additionalData: ByteArray): ByteArray? =
        open(key, nonce, sealed, 0, sealed.size, additionalData)

    /** CryptoKit's `SealedBox.combined`: `nonce ‖ ciphertext ‖ tag`, with no padding scheme. */
    @Throws(GeneralSecurityException::class)
    fun sealCombined(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, additionalData: ByteArray): ByteArray {
        val sealed = seal(key, nonce, plaintext, additionalData)
        return Bytes.concat(nonce, sealed)
    }

    /**
     * Opens `nonce ‖ ciphertext ‖ tag`. The caller checks the length first
     * ([COMBINED_OVERHEAD_BYTES]) because Swift reports a short box as a malformed file, not as a wrong key.
     * Throws as [open] for anything but a failed tag.
     */
    @Throws(GeneralSecurityException::class)
    fun openCombined(key: ByteArray, combined: ByteArray, additionalData: ByteArray): ByteArray? {
        require(combined.size >= COMBINED_OVERHEAD_BYTES) { "a combined box is at least $COMBINED_OVERHEAD_BYTES bytes" }
        val nonce = combined.copyOfRange(0, NONCE_BYTES)
        return open(key, nonce, combined, NONCE_BYTES, combined.size - NONCE_BYTES, additionalData)
    }

    private fun open(
        key: ByteArray, nonce: ByteArray, input: ByteArray, offset: Int, length: Int, additionalData: ByteArray,
    ): ByteArray? {
        if (length < TAG_BYTES) return null
        val cipher = cipher(Cipher.DECRYPT_MODE, key, nonce, additionalData)
        return try {
            cipher.doFinal(input, offset, length)
        } catch (_: AEADBadTagException) {
            null
        }
    }

    private fun cipher(mode: Int, key: ByteArray, nonce: ByteArray, additionalData: ByteArray): Cipher {
        require(key.size == KEY_BYTES) { "AES-256 needs a $KEY_BYTES-byte key" }
        require(nonce.size == NONCE_BYTES) { "AES-GCM needs a $NONCE_BYTES-byte nonce" }
        return Cipher.getInstance(transformation).apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BYTES * 8, nonce))
            updateAAD(additionalData)
        }
    }
}
