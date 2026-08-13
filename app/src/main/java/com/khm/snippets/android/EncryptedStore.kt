package com.khm.snippets.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound encryption for local library, credentials, keys and sync checkpoints. */
class EncryptedStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "SnippetsClone").apply {
        check(mkdirs() || isDirectory)
    }
    private val alias = "com.khm.snippets.android.local-v1"

    fun read(name: String): String? {
        val file = File(root, safeName(name))
        if (!file.exists()) return null
        val bytes = file.readBytes()
        require(bytes.size >= 4 + NONCE_BYTES + 16 && bytes.copyOfRange(0, 4).contentEquals(MAGIC))
        val nonce = bytes.copyOfRange(4, 4 + NONCE_BYTES)
        val ciphertext = bytes.copyOfRange(4 + NONCE_BYTES, bytes.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, nonce))
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        return cipher.doFinal(ciphertext).toString(Charsets.UTF_8)
    }

    @Synchronized
    fun write(name: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        val payload = ByteBuffer.allocate(4 + NONCE_BYTES + value.toByteArray().size + 16)
            .put(MAGIC)
            .put(cipher.iv)
            .put(cipher.doFinal(value.toByteArray(Charsets.UTF_8)))
            .array()

        val destination = File(root, safeName(name))
        val temporary = File(root, ".${destination.name}.tmp")
        FileOutputStream(temporary).use { output ->
            output.write(payload)
            output.fd.sync()
        }
        Files.move(
            temporary.toPath(), destination.toPath(),
            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build())
        return generator.generateKey()
    }

    private fun safeName(name: String): String {
        require(name.matches(Regex("[a-z0-9-]+\\.enc")))
        return name
    }

    private companion object {
        val MAGIC = byteArrayOf(0x53, 0x4E, 0x49, 0x50) // SNIP
        const val NONCE_BYTES = 12
    }
}
