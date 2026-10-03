package com.khm.snippets.android

import org.json.JSONObject
import java.math.BigInteger
import java.net.URI
import java.nio.ByteBuffer
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Instant
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * End-to-end bootstrap for a Snippets library key.
 *
 * Pairing QR payloads contain only a server/space/pairing binding, a fresh nonce,
 * and the recipient's ephemeral public key. Recovery QR payloads contain a random
 * recovery secret, never the library key. The sync service stores only AEAD blobs.
 */
object LibraryKeyBootstrap {
    const val PAIRING_ALGORITHM =
        "snippets-pairing-p256-hkdf-sha256-aes256gcm-v1"
    const val RECOVERY_ALGORITHM =
        "snippets-recovery-hkdf-sha256-aes256gcm-v1"
    const val DEFAULT_PAIRING_SECONDS = 300

    private const val PAIRING_SCHEMA = 2
    private const val DEVICE_SIGN_IN_SCHEMA = 1
    private const val DEVICE_SIGN_IN_KIND = "snippets-device-sign-in"
    private const val RECOVERY_SCHEMA = 1
    private const val MAX_QR_BYTES = 4_096
    private const val MAX_ENVELOPE_BYTES = 4_096
    private const val P256_PUBLIC_KEY_BYTES = 65
    private const val RECOVERY_SECRET_BYTES = 32
    private const val PAIRING_NONCE_BYTES = 32
    private const val GCM_NONCE_BYTES = 12
    private const val GCM_TAG_BITS = 128
    private val random = SecureRandom()

    data class PairingDraft(
        val recipientPublicKey: ByteArray,
        val nonce: ByteArray,
        val privateKeyPKCS8: ByteArray,
    ) {
        fun toJSON(): String = JSONObject()
            .put("schemaVersion", PAIRING_SCHEMA)
            .put("recipientPublicKey", recipientPublicKey.base64URL())
            .put("nonce", nonce.base64URL())
            .put("privateKey", privateKeyPKCS8.base64URL())
            .toString()

        companion object {
            fun fromJSON(raw: String): PairingDraft {
                val value = strictObject(
                    raw,
                    setOf("schemaVersion", "recipientPublicKey", "nonce", "privateKey"),
                )
                require(value.getInt("schemaVersion") == PAIRING_SCHEMA)
                return PairingDraft(
                    recipientPublicKey = value.getString("recipientPublicKey")
                        .base64URLBytes(P256_PUBLIC_KEY_BYTES),
                    nonce = value.getString("nonce").base64URLBytes(PAIRING_NONCE_BYTES),
                    privateKeyPKCS8 = value.getString("privateKey").base64URLBytes(256),
                ).also { draft ->
                    require(draft.recipientPublicKey[0] == 0x04.toByte())
                    val privateKey = decodePrivateKey(draft.privateKeyPKCS8)
                    // Prove the persisted private/public pair still matches before use.
                    validateKeyPair(privateKey, decodePublicKey(draft.recipientPublicKey))
                }
            }
        }
    }

    data class PairingInvitation(
        val serverURL: String,
        val spaceID: String,
        val pairingID: String,
        val nonce: ByteArray,
        val recipientPublicKey: ByteArray,
        val expiresAtEpochSeconds: Long,
    ) {
        val confirmationCode: String
            get() = confirmationCode(nonce, recipientPublicKey)

        fun toQRPayload(): String = JSONObject()
            .put("schemaVersion", PAIRING_SCHEMA)
            .put("kind", "snippets-pairing")
            .put("server", serverURL)
            .put("spaceId", spaceID)
            .put("pairingId", pairingID)
            .put("nonce", nonce.base64URL())
            .put("recipientPublicKey", recipientPublicKey.base64URL())
            .put("expiresAt", expiresAtEpochSeconds)
            .toString()
            .also { require(it.toByteArray().size <= MAX_QR_BYTES) }

        companion object {
            fun fromQRPayload(raw: String, nowEpochSeconds: Long = Instant.now().epochSecond): PairingInvitation {
                val value = strictObject(
                    raw,
                    setOf(
                        "schemaVersion", "kind", "server", "spaceId", "pairingId",
                        "nonce", "recipientPublicKey", "expiresAt",
                    ),
                )
                require(value.getInt("schemaVersion") == PAIRING_SCHEMA)
                require(value.getString("kind") == "snippets-pairing")
                val invitation = PairingInvitation(
                    serverURL = canonicalServer(value.getString("server")),
                    spaceID = canonicalUUID(value.getString("spaceId")),
                    pairingID = canonicalUUID(value.getString("pairingId")),
                    nonce = value.getString("nonce").base64URLBytes(PAIRING_NONCE_BYTES),
                    recipientPublicKey = value.getString("recipientPublicKey")
                        .base64URLBytes(P256_PUBLIC_KEY_BYTES),
                    expiresAtEpochSeconds = value.getLong("expiresAt"),
                )
                require(invitation.recipientPublicKey[0] == 0x04.toByte())
                require(invitation.expiresAtEpochSeconds > nowEpochSeconds - 30)
                require(invitation.expiresAtEpochSeconds <= nowEpochSeconds + 630)
                // KeyFactory validates that the point is on the P-256 curve.
                decodePublicKey(invitation.recipientPublicKey)
                return invitation
            }
        }
    }

    data class PendingPairing(
        val draft: PairingDraft,
        val invitation: PairingInvitation,
    ) {
        fun toJSON(): String = JSONObject()
            .put("schemaVersion", PAIRING_SCHEMA)
            .put("draft", JSONObject(draft.toJSON()))
            .put("invitation", invitation.toQRPayload())
            .toString()

        companion object {
            fun fromJSON(raw: String): PendingPairing {
                val value = strictObject(raw, setOf("schemaVersion", "draft", "invitation"))
                require(value.getInt("schemaVersion") == PAIRING_SCHEMA)
                val draft = PairingDraft.fromJSON(value.getJSONObject("draft").toString())
                val invitation = PairingInvitation.fromQRPayload(value.getString("invitation"))
                require(draft.nonce.contentEquals(invitation.nonce))
                require(draft.recipientPublicKey.contentEquals(invitation.recipientPublicKey))
                return PendingPairing(draft, invitation)
            }
        }
    }

    /**
     * ADR 0007 `snippets-device-sign-in` payload shown by a signed-out device. It carries
     * only pairing recipient material and the request ID, never the poll token. Encoding
     * follows the pairing invitation conventions: sorted keys, unescaped slashes, unpadded
     * Base64url, lowercase UUID, canonical HTTPS origin and at most 4,096 bytes.
     */
    data class DeviceSignInRequest(
        val serverURL: String,
        val requestID: String,
        val nonce: ByteArray,
        val recipientPublicKey: ByteArray,
        val expiresAtEpochSeconds: Long,
    ) {
        /** Unchanged pairing derivation: equals the server tag of the approver's pairing. */
        val confirmationCode: String
            get() = confirmationCode(nonce, recipientPublicKey)

        fun toPayload(): String = canonicalJSON(sortedMapOf<String, Any>(
            "expiresAt" to expiresAtEpochSeconds,
            "kind" to DEVICE_SIGN_IN_KIND,
            "nonce" to nonce.base64URL(),
            "recipientPublicKey" to recipientPublicKey.base64URL(),
            "requestId" to requestID,
            "schemaVersion" to DEVICE_SIGN_IN_SCHEMA,
            "server" to serverURL,
        )).also { require(it.toByteArray(Charsets.UTF_8).size <= MAX_QR_BYTES) }

        override fun toString(): String = "DeviceSignInRequest(<redacted>)"

        companion object {
            fun fromPayload(raw: String, nowEpochSeconds: Long = Instant.now().epochSecond): DeviceSignInRequest {
                val value = strictObject(
                    raw,
                    setOf("expiresAt", "kind", "nonce", "recipientPublicKey", "requestId",
                        "schemaVersion", "server"),
                )
                require(value.get("schemaVersion") == DEVICE_SIGN_IN_SCHEMA)
                require(value.get("kind") == DEVICE_SIGN_IN_KIND)
                val expiresAt = value.get("expiresAt")
                require(expiresAt is Int || expiresAt is Long)
                val server = value.get("server") as? String ?: throw IllegalArgumentException()
                val requestID = value.get("requestId") as? String ?: throw IllegalArgumentException()
                val request = DeviceSignInRequest(
                    serverURL = canonicalServer(server).also { require(it == server) },
                    requestID = canonicalUUID(requestID).also { require(it == requestID) },
                    nonce = (value.get("nonce") as? String ?: throw IllegalArgumentException())
                        .base64URLBytes(PAIRING_NONCE_BYTES),
                    recipientPublicKey = (value.get("recipientPublicKey") as? String
                        ?: throw IllegalArgumentException()).base64URLBytes(P256_PUBLIC_KEY_BYTES),
                    expiresAtEpochSeconds = (expiresAt as Number).toLong(),
                )
                require(request.nonce.size == PAIRING_NONCE_BYTES)
                require(request.recipientPublicKey.size == P256_PUBLIC_KEY_BYTES)
                require(request.expiresAtEpochSeconds > nowEpochSeconds - 30)
                require(request.expiresAtEpochSeconds <= nowEpochSeconds + 630)
                // KeyFactory validates that the point is on the P-256 curve.
                decodePublicKey(request.recipientPublicKey)
                return request
            }

            /** `kind` only; full validation happens in [fromPayload]. */
            fun isDeviceSignInPayload(raw: String): Boolean = runCatching {
                raw.toByteArray(Charsets.UTF_8).size <= MAX_QR_BYTES &&
                    JSONObject(raw.trim()).opt("kind") == DEVICE_SIGN_IN_KIND
            }.getOrDefault(false)
        }
    }

    /**
     * New-device state for a device-approved sign-in. The recipient private key and the
     * poll token (a claim credential) live only in the device-bound encrypted store.
     */
    class PendingDeviceSignIn(
        val draft: PairingDraft,
        val request: DeviceSignInRequest,
        val pollToken: String,
    ) {
        init {
            require(draft.nonce.contentEquals(request.nonce))
            require(draft.recipientPublicKey.contentEquals(request.recipientPublicKey))
            require(isDevicePollToken(pollToken))
        }

        fun toJSON(): String = JSONObject()
            .put("schemaVersion", DEVICE_SIGN_IN_SCHEMA)
            .put("draft", JSONObject(draft.toJSON()))
            .put("request", request.toPayload())
            .put("pollToken", pollToken)
            .toString()

        override fun toString(): String = "PendingDeviceSignIn(<redacted>)"

        companion object {
            fun fromJSON(raw: String, nowEpochSeconds: Long = Instant.now().epochSecond): PendingDeviceSignIn {
                val value = strictObject(raw, setOf("schemaVersion", "draft", "request", "pollToken"))
                require(value.get("schemaVersion") == DEVICE_SIGN_IN_SCHEMA)
                return PendingDeviceSignIn(
                    PairingDraft.fromJSON(value.getJSONObject("draft").toString()),
                    DeviceSignInRequest.fromPayload(value.getString("request"), nowEpochSeconds),
                    value.getString("pollToken"),
                )
            }
        }
    }

    /**
     * Approver state, written only after fresh device-owner authentication starts the
     * approval. [pairing] is recorded before approval so a retry reuses the same pairing.
     */
    class PendingDeviceApproval(
        val request: DeviceSignInRequest,
        val pairing: PairingInvitation?,
    ) {
        init {
            pairing?.let {
                require(it.serverURL == request.serverURL)
                require(it.nonce.contentEquals(request.nonce))
                require(it.recipientPublicKey.contentEquals(request.recipientPublicKey))
            }
        }

        fun toJSON(): String = JSONObject()
            .put("schemaVersion", DEVICE_SIGN_IN_SCHEMA)
            .put("request", request.toPayload())
            .put("pairing", pairing?.toQRPayload() ?: JSONObject.NULL)
            .toString()

        override fun toString(): String = "PendingDeviceApproval(<redacted>)"

        companion object {
            fun fromJSON(raw: String, nowEpochSeconds: Long = Instant.now().epochSecond): PendingDeviceApproval {
                val value = strictObject(raw, setOf("schemaVersion", "request", "pairing"))
                require(value.get("schemaVersion") == DEVICE_SIGN_IN_SCHEMA)
                return PendingDeviceApproval(
                    DeviceSignInRequest.fromPayload(value.getString("request"), nowEpochSeconds),
                    if (value.isNull("pairing")) null
                    else PairingInvitation.fromQRPayload(value.getString("pairing"), nowEpochSeconds),
                )
            }
        }
    }

    /** ADR 0007: `expiresInSeconds = clamp(expiresAt − now − 5, 60, 600)`. */
    fun deviceSignInPairingSeconds(requestExpiresAtEpochSeconds: Long, nowEpochSeconds: Long): Int =
        (requestExpiresAtEpochSeconds - nowEpochSeconds - 5).coerceIn(60L, 600L).toInt()

    /** `sn_d_` plus 43 unpadded Base64url symbols encoding 32 bytes. */
    fun isDevicePollToken(value: String): Boolean = value.length == 48 && value.startsWith("sn_d_") &&
        runCatching { value.substring(5).base64URLBytes(32).size == 32 }.getOrDefault(false)

    data class RecoveryKit(
        val serverURL: String,
        val spaceID: String,
        val keyEpoch: Int,
        val secret: ByteArray,
    ) {
        val longCode: String get() = base32Encode(secret).chunked(4).joinToString("-")

        fun toQRPayload(): String = JSONObject()
            .put("schemaVersion", RECOVERY_SCHEMA)
            .put("kind", "snippets-recovery")
            .put("server", serverURL)
            .put("spaceId", spaceID)
            .put("keyEpoch", keyEpoch)
            .put("secret", secret.base64URL())
            .toString()
            .also { require(it.toByteArray().size <= MAX_QR_BYTES) }

        companion object {
            fun fromQRPayload(raw: String): RecoveryKit {
                val value = strictObject(
                    raw,
                    setOf("schemaVersion", "kind", "server", "spaceId", "keyEpoch", "secret"),
                )
                require(value.getInt("schemaVersion") == RECOVERY_SCHEMA)
                require(value.getString("kind") == "snippets-recovery")
                return RecoveryKit(
                    serverURL = canonicalServer(value.getString("server")),
                    spaceID = canonicalUUID(value.getString("spaceId")),
                    keyEpoch = value.getInt("keyEpoch").also { require(it > 0) },
                    secret = value.getString("secret").base64URLBytes(RECOVERY_SECRET_BYTES),
                )
            }

            fun fromLongCode(
                code: String,
                serverURL: String,
                spaceID: String,
                keyEpoch: Int,
            ): RecoveryKit = RecoveryKit(
                serverURL = canonicalServer(serverURL),
                spaceID = canonicalUUID(spaceID),
                keyEpoch = keyEpoch.also { require(it > 0) },
                secret = base32Decode(code).also { require(it.size == RECOVERY_SECRET_BYTES) },
            )
        }
    }

    data class RecoveryEnvelope(val kit: RecoveryKit, val ciphertext: ByteArray)

    fun createPairingDraft(): PairingDraft {
        val keyPair = generateP256KeyPair()
        return PairingDraft(
            recipientPublicKey = publicBytes(keyPair.public),
            nonce = randomBytes(PAIRING_NONCE_BYTES),
            privateKeyPKCS8 = requireNotNull(keyPair.private.encoded),
        )
    }

    fun sealForPairing(portableBundleJSON: String, invitation: PairingInvitation): ByteArray {
        validatePortableBundle(portableBundleJSON)
        val sender = generateP256KeyPair()
        val shared = agree(sender.private, decodePublicKey(invitation.recipientPublicKey))
        try {
            val aad = pairingAAD(invitation)
            val key = hkdf(shared, invitation.nonce, aad, 32)
            try {
                val nonce = randomBytes(GCM_NONCE_BYTES)
                val sealed = aesGCMEncrypt(
                    portableBundleJSON.toByteArray(Charsets.UTF_8), key, nonce, aad)
                val result = JSONObject()
                    .put("schemaVersion", 1)
                    .put("senderPublicKey", publicBytes(sender.public).base64URL())
                    .put("nonce", nonce.base64URL())
                    .put("sealed", sealed.base64URL())
                    .toString()
                    .toByteArray(Charsets.UTF_8)
                require(result.size <= MAX_ENVELOPE_BYTES)
                return result
            } finally {
                key.fill(0)
            }
        } finally {
            shared.fill(0)
        }
    }

    fun openPairedEnvelope(pending: PendingPairing, envelope: ByteArray): String {
        require(envelope.size <= MAX_ENVELOPE_BYTES)
        val value = strictObject(
            envelope.toString(Charsets.UTF_8),
            setOf("schemaVersion", "senderPublicKey", "nonce", "sealed"),
        )
        require(value.getInt("schemaVersion") == 1)
        val senderPublicKey = value.getString("senderPublicKey")
            .base64URLBytes(P256_PUBLIC_KEY_BYTES)
        require(senderPublicKey[0] == 0x04.toByte())
        val nonce = value.getString("nonce").base64URLBytes(GCM_NONCE_BYTES)
        val sealed = value.getString("sealed").base64URLBytes(MAX_ENVELOPE_BYTES)
        val privateKey = decodePrivateKey(pending.draft.privateKeyPKCS8)
        val shared = agree(privateKey, decodePublicKey(senderPublicKey))
        try {
            val aad = pairingAAD(pending.invitation)
            val key = hkdf(shared, pending.invitation.nonce, aad, 32)
            try {
                val plaintext = aesGCMDecrypt(sealed, key, nonce, aad)
                try {
                    val bundle = plaintext.toString(Charsets.UTF_8)
                    validatePortableBundle(bundle)
                    return bundle
                } finally {
                    plaintext.fill(0)
                }
            } finally {
                key.fill(0)
            }
        } finally {
            shared.fill(0)
        }
    }

    fun createRecoveryEnvelope(
        portableBundleJSON: String,
        serverURL: String,
        spaceID: String,
        keyEpoch: Int,
    ): RecoveryEnvelope {
        validatePortableBundle(portableBundleJSON)
        val kit = RecoveryKit(
            canonicalServer(serverURL),
            canonicalUUID(spaceID),
            keyEpoch.also { require(it > 0) },
            randomBytes(RECOVERY_SECRET_BYTES),
        )
        val aad = recoveryAAD(kit)
        val key = hkdf(
            kit.secret,
            "snippets-recovery-salt-v1".toByteArray(Charsets.UTF_8),
            aad,
            32,
        )
        try {
            val nonce = randomBytes(GCM_NONCE_BYTES)
            val sealed = aesGCMEncrypt(
                portableBundleJSON.toByteArray(Charsets.UTF_8), key, nonce, aad)
            val result = ByteBuffer.allocate(nonce.size + sealed.size)
                .put(nonce)
                .put(sealed)
                .array()
            require(result.size <= MAX_ENVELOPE_BYTES)
            return RecoveryEnvelope(kit, result)
        } finally {
            key.fill(0)
        }
    }

    fun openRecoveryEnvelope(kit: RecoveryKit, ciphertext: ByteArray): String {
        require(ciphertext.size in (GCM_NONCE_BYTES + 16)..MAX_ENVELOPE_BYTES)
        val aad = recoveryAAD(kit)
        val key = hkdf(
            kit.secret,
            "snippets-recovery-salt-v1".toByteArray(Charsets.UTF_8),
            aad,
            32,
        )
        try {
            val nonce = ciphertext.copyOfRange(0, GCM_NONCE_BYTES)
            val sealed = ciphertext.copyOfRange(GCM_NONCE_BYTES, ciphertext.size)
            val plaintext = aesGCMDecrypt(sealed, key, nonce, aad)
            try {
                val bundle = plaintext.toString(Charsets.UTF_8)
                validatePortableBundle(bundle)
                return bundle
            } finally {
                plaintext.fill(0)
            }
        } finally {
            key.fill(0)
        }
    }

    fun recipientKeyHash(publicKey: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(publicKey)

    private fun validatePortableBundle(raw: String) {
        require(raw.toByteArray().size <= 2_048)
        val value = strictObject(raw, setOf("schemaVersion", "scopeID", "key", "salt"))
        require(value.getInt("schemaVersion") == 1)
        require(value.getString("scopeID") == "sync-v1")
        listOf(value.getString("key"), value.getString("salt")).forEach { encoded ->
            require(encoded.length == 44 && encoded.matches(Regex("[A-Za-z0-9+/]{43}=")))
            val decoded = Base64.getDecoder().decode(encoded)
            require(decoded.size == 32 && Base64.getEncoder().encodeToString(decoded) == encoded)
        }
    }

    private fun pairingAAD(invitation: PairingInvitation): ByteArray = listOf(
        "snippets-pairing-v2",
        invitation.serverURL,
        invitation.spaceID,
        invitation.pairingID,
        invitation.nonce.base64URL(),
        invitation.recipientPublicKey.base64URL(),
    ).joinToString("\u0000").toByteArray(Charsets.UTF_8)

    private fun recoveryAAD(kit: RecoveryKit): ByteArray = listOf(
        "snippets-recovery-v1",
        kit.serverURL,
        kit.spaceID,
        kit.keyEpoch.toString(),
    ).joinToString("\u0000").toByteArray(Charsets.UTF_8)

    private fun confirmationCode(nonce: ByteArray, recipientPublicKey: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("snippets-pairing-confirm-v1".toByteArray(Charsets.UTF_8))
        digest.update(nonce)
        digest.update(recipientPublicKey)
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return digest.digest().take(8).map { alphabet[it.toInt() and 31] }.joinToString("")
    }

    private fun generateP256KeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").run {
        initialize(ECGenParameterSpec("secp256r1"), random)
        generateKeyPair()
    }

    private fun decodePrivateKey(encoded: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(encoded))

    private fun validateKeyPair(privateKey: PrivateKey, publicKey: java.security.PublicKey) {
        val challenge = randomBytes(32)
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey, random)
            update(challenge)
            sign()
        }
        require(Signature.getInstance("SHA256withECDSA").run {
            initVerify(publicKey)
            update(challenge)
            verify(signature)
        })
        challenge.fill(0)
        signature.fill(0)
    }

    private fun decodePublicKey(raw: ByteArray): java.security.PublicKey {
        require(raw.size == P256_PUBLIC_KEY_BYTES && raw[0] == 0x04.toByte())
        val parameters = AlgorithmParameters.getInstance("EC").apply {
            init(ECGenParameterSpec("secp256r1"))
        }.getParameterSpec(ECParameterSpec::class.java)
        val point = ECPoint(
            BigInteger(1, raw.copyOfRange(1, 33)),
            BigInteger(1, raw.copyOfRange(33, 65)),
        )
        // Not every KeyFactory provider checks the point, so verify y² = x³ + ax + b (mod p).
        val curve = parameters.curve
        val prime = (curve.field as java.security.spec.ECFieldFp).p
        val x = point.affineX
        val y = point.affineY
        require(x < prime && y < prime)
        require(y.multiply(y).mod(prime) ==
            x.pow(3).add(curve.a.multiply(x)).add(curve.b).mod(prime))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, parameters))
    }

    private fun publicBytes(key: java.security.PublicKey): ByteArray {
        val point = (key as ECPublicKey).w
        return byteArrayOf(0x04) + unsigned32(point.affineX) + unsigned32(point.affineY)
    }

    private fun unsigned32(value: BigInteger): ByteArray {
        val raw = value.toByteArray()
        val unsigned = if (raw.size == 33 && raw[0] == 0.toByte()) raw.copyOfRange(1, 33) else raw
        require(unsigned.size <= 32)
        return ByteArray(32 - unsigned.size) + unsigned
    }

    private fun agree(privateKey: PrivateKey, publicKey: java.security.PublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(privateKey)
            doPhase(publicKey, true)
            generateSecret()
        }

    private fun hkdf(input: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val extract = Mac.getInstance("HmacSHA256")
        extract.init(SecretKeySpec(salt, "HmacSHA256"))
        val pseudorandomKey = extract.doFinal(input)
        try {
            val output = ByteArray(length)
            var previous = ByteArray(0)
            var offset = 0
            var counter = 1
            while (offset < length) {
                val expand = Mac.getInstance("HmacSHA256")
                expand.init(SecretKeySpec(pseudorandomKey, "HmacSHA256"))
                expand.update(previous)
                expand.update(info)
                expand.update(counter.toByte())
                previous.fill(0)
                previous = expand.doFinal()
                val count = minOf(previous.size, length - offset)
                previous.copyInto(output, offset, 0, count)
                offset += count
                counter += 1
            }
            previous.fill(0)
            return output
        } finally {
            pseudorandomKey.fill(0)
        }
    }

    private fun aesGCMEncrypt(
        plaintext: ByteArray,
        key: ByteArray,
        nonce: ByteArray,
        aad: ByteArray,
    ): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
        init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        updateAAD(aad)
        doFinal(plaintext)
    }

    private fun aesGCMDecrypt(
        ciphertext: ByteArray,
        key: ByteArray,
        nonce: ByteArray,
        aad: ByteArray,
    ): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run {
        init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(GCM_TAG_BITS, nonce))
        updateAAD(aad)
        doFinal(ciphertext)
    }

    private fun randomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)

    private fun ByteArray.base64URL(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(this)

    private fun String.base64URLBytes(maximumBytes: Int): ByteArray {
        require(length <= ((maximumBytes + 2) / 3) * 4)
        require(matches(Regex("[A-Za-z0-9_-]+")))
        val decoded = Base64.getUrlDecoder().decode(this)
        require(decoded.size <= maximumBytes && decoded.base64URL() == this)
        return decoded
    }

    /** Compact JSON with sorted keys and no escaped slashes, for flat string/number maps. */
    private fun canonicalJSON(fields: java.util.SortedMap<String, Any>): String =
        fields.entries.joinToString(",", "{", "}") { (key, value) ->
            jsonString(key) + ":" + when (value) {
                is String -> jsonString(value)
                is Int, is Long -> value.toString()
                else -> throw IllegalArgumentException()
            }
        }

    private fun jsonString(value: String): String = buildString(value.length + 2) {
        append('"')
        for (character in value) {
            when {
                character == '"' -> append("\\\"")
                character == '\\' -> append("\\\\")
                character < ' ' -> append("\\u%04x".format(character.code))
                else -> append(character)
            }
        }
        append('"')
    }

    private fun strictObject(raw: String, expectedKeys: Set<String>): JSONObject {
        require(raw.toByteArray().size <= MAX_QR_BYTES)
        val value = JSONObject(raw)
        val keys = value.keys().asSequence().toSet()
        require(keys == expectedKeys)
        return value
    }

    private fun canonicalServer(raw: String): String {
        val uri = URI(raw.trim().trimEnd('/'))
        require(uri.scheme == "https" && uri.host != null)
        require(uri.userInfo == null && uri.query == null && uri.fragment == null)
        return uri.toString()
    }

    private fun canonicalUUID(raw: String): String =
        UUID.fromString(raw).toString().also { require(it.equals(raw, ignoreCase = true)) }

    private fun base32Encode(bytes: ByteArray): String {
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        var buffer = 0
        var bits = 0
        val output = StringBuilder((bytes.size * 8 + 4) / 5)
        for (byte in bytes) {
            buffer = (buffer shl 8) or (byte.toInt() and 0xff)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                output.append(alphabet[(buffer shr bits) and 31])
            }
        }
        if (bits > 0) output.append(alphabet[(buffer shl (5 - bits)) and 31])
        return output.toString()
    }

    private fun base32Decode(raw: String): ByteArray {
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val normalized = raw.uppercase().filterNot { it == '-' || it.isWhitespace() }
        require(normalized.length == 52)
        var buffer = 0
        var bits = 0
        val output = ArrayList<Byte>(RECOVERY_SECRET_BYTES)
        for (character in normalized) {
            val value = alphabet.indexOf(character)
            require(value >= 0)
            buffer = (buffer shl 5) or value
            bits += 5
            if (bits >= 8) {
                bits -= 8
                output += ((buffer shr bits) and 0xff).toByte()
            }
        }
        require(output.size == RECOVERY_SECRET_BYTES)
        return output.toByteArray().also { require(base32Encode(it) == normalized) }
    }
}
