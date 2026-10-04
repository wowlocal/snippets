package com.khm.snippets.android

import android.os.Build
import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Opt-in: real Android crypto and HTTP approve a disposable Linux recipient. */
class NativeDeviceApprovalEndToEndTest {
    @Test
    fun approvesLinuxRecipientWithLibraryAuthority() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("snippetsDeviceApprovalE2E") == "disposable-emulator")
        assumeTrue(Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish")
        val server = requireNotNull(args.getString("snippetsServerUrl"))
        require(BuildConfig.SNIPPETS_CLOUD_ENABLED && BuildConfig.SNIPPETS_CLOUD_URL == server)
        val space = requireNotNull(args.getString("snippetsSpaceId"))
        val instance = requireNotNull(args.getString("snippetsServerInstanceId"))
        val token = requireNotNull(args.getString("snippetsAccessToken"))
        val request = LibraryKeyBootstrap.DeviceSignInRequest.fromPayload(
            requireNotNull(args.getString("snippetsDeviceRequest")))
        assertEquals(server, request.serverURL)
        val bundle = JSONObject().put("schemaVersion", 1).put("scopeID", "sync-v1")
            .put("key", Base64.encodeToString(ByteArray(32) { 0x42 }, Base64.NO_WRAP))
            .put("salt", Base64.encodeToString(ByteArray(32) { 0x24 }, Base64.NO_WRAP)).toString()
        val client = HttpSyncClient()
        client.verifyAuthority(server, space, token, instance, bundle)
        val pairing = client.createPairing(server, space, token,
            request.recipientPublicKey, request.nonce, instance, 300)
        assertEquals(request.confirmationCode, pairing.authenticationTag)
        val invitation = LibraryKeyBootstrap.PairingInvitation(server, space, pairing.pairingID,
            request.nonce, request.recipientPublicKey, pairing.expiresAtEpochSeconds)
        val ciphertext = LibraryKeyBootstrap.sealForPairing(bundle, invitation)
        val approved = client.approvePairing(server, space, pairing.pairingID,
            request.recipientPublicKey, ciphertext, token, instance, bundle)
        assertEquals("approved", approved.state)
        repeat(2) {
            client.approveDeviceSignInRequest(server, request.requestID, space, pairing.pairingID, token)
        }
    }
}
