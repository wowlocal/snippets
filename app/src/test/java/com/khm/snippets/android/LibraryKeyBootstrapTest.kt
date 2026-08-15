package com.khm.snippets.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import java.time.Instant
import java.util.Base64
import java.util.UUID

class LibraryKeyBootstrapTest {
    private val server = "https://sync.example"
    private val space = UUID.randomUUID().toString()

    @Test
    fun pairingRoundTripBindsEveryInvitationFieldAndIsTamperEvident() {
        val draft = LibraryKeyBootstrap.createPairingDraft()
        val invitation = LibraryKeyBootstrap.PairingInvitation(
            serverURL = server,
            spaceID = space,
            pairingID = UUID.randomUUID().toString(),
            nonce = draft.nonce,
            recipientPublicKey = draft.recipientPublicKey,
            expiresAtEpochSeconds = Instant.now().epochSecond + 300,
        )
        val parsedInvitation = LibraryKeyBootstrap.PairingInvitation.fromQRPayload(
            invitation.toQRPayload(),
        )
        assertEquals(invitation.confirmationCode, parsedInvitation.confirmationCode)
        assertFalse(invitation.toQRPayload().contains(bundle()))

        val pending = LibraryKeyBootstrap.PendingPairing(draft, parsedInvitation)
        val restoredPending = LibraryKeyBootstrap.PendingPairing.fromJSON(pending.toJSON())
        val envelope = LibraryKeyBootstrap.sealForPairing(bundle(), parsedInvitation)
        assertEquals(
            keyBundle(bundle()),
            keyBundle(LibraryKeyBootstrap.openPairedEnvelope(restoredPending, envelope)),
        )

        val tampered = envelope.clone().also { it[it.lastIndex] = (it.last() + 1).toByte() }
        assertThrows(Exception::class.java) {
            LibraryKeyBootstrap.openPairedEnvelope(restoredPending, tampered)
        }
        val wrongPairing = parsedInvitation.copy(pairingID = UUID.randomUUID().toString())
        assertThrows(Exception::class.java) {
            LibraryKeyBootstrap.openPairedEnvelope(
                LibraryKeyBootstrap.PendingPairing(draft, wrongPairing),
                envelope,
            )
        }
    }

    @Test
    fun recoveryRoundTripWorksFromQrAndLongCodeWithoutEmbeddingLibraryKey() {
        val recovery = LibraryKeyBootstrap.createRecoveryEnvelope(bundle(), server, space, 1)
        val qr = recovery.kit.toQRPayload()
        assertFalse(qr.contains(keyBundle(bundle()).key))
        assertFalse(qr.contains(keyBundle(bundle()).salt))

        val fromQR = LibraryKeyBootstrap.RecoveryKit.fromQRPayload(qr)
        assertEquals(
            keyBundle(bundle()),
            keyBundle(LibraryKeyBootstrap.openRecoveryEnvelope(fromQR, recovery.ciphertext)),
        )
        val fromCode = LibraryKeyBootstrap.RecoveryKit.fromLongCode(
            recovery.kit.longCode,
            server,
            space,
            1,
        )
        assertEquals(recovery.kit.secret.toList(), fromCode.secret.toList())
        assertEquals(
            keyBundle(bundle()),
            keyBundle(LibraryKeyBootstrap.openRecoveryEnvelope(fromCode, recovery.ciphertext)),
        )
    }

    @Test
    fun recoveryWireVectorMatchesAppleImplementation() {
        // The Apple CorePackage test opens the identical fixture. This catches
        // cross-platform drift in HKDF, AES-GCM layout, AAD, and bundle JSON.
        val kit = LibraryKeyBootstrap.RecoveryKit(
            serverURL = server,
            spaceID = "01234567-89ab-cdef-0123-456789abcdef",
            keyEpoch = 7,
            secret = ByteArray(32) { (it + 160).toByte() },
        )
        val ciphertext = Base64.getDecoder().decode(
            "4OHi4+Tl5ufo6errM76BnjJgguPvUmhNd5AgnCU/ER/39RuP1lz7aQdmGbMn6cg9" +
                "UVPGUWIVUXzZEEvueXiuszpMILWrVMGyOTHKM1xJMdbfIbuiaYnIU1y9WFVuZXzj" +
                "a72yY7PtDhh1hzCl4wnwNSAViH5YH/x582U8C8eLuw5o9ykjjonPqIrZH8/fOsA" +
                "gq4NCirT5lxn4PdAsZvNMgCIb9g6ZygGGsKp70/YP",
        )
        val opened = keyBundle(LibraryKeyBootstrap.openRecoveryEnvelope(kit, ciphertext))
        assertEquals(
            (0 until 32).map { it.toByte() },
            Base64.getDecoder().decode(opened.key).toList(),
        )
        assertEquals(
            (32 until 64).map { it.toByte() },
            Base64.getDecoder().decode(opened.salt).toList(),
        )
    }

    private fun bundle(): String = KeyBundle(
        key = Base64.getEncoder().encodeToString(ByteArray(32) { (it + 1).toByte() }),
        salt = Base64.getEncoder().encodeToString(ByteArray(32) { (it + 33).toByte() }),
    ).toJSON()
}
