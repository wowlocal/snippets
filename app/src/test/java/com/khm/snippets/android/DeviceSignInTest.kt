package com.khm.snippets.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64

/** ADR 0007 device-approved sign-in codecs and protocol parsing. */
class DeviceSignInTest {
    private val origin = "https://cloud.example.test"
    private val requestID = "5f0c3a1e-9b2d-4c7e-8a41-0d6b2e9f7c13"
    private val now = Instant.now().epochSecond
    private val draft = LibraryKeyBootstrap.createPairingDraft()
    private val pollToken = "sn_d_" + Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { it.toByte() })

    private fun request(expiresAt: Long = now + 600) = LibraryKeyBootstrap.DeviceSignInRequest(
        serverURL = origin,
        requestID = requestID,
        nonce = draft.nonce,
        recipientPublicKey = draft.recipientPublicKey,
        expiresAtEpochSeconds = expiresAt,
    )

    private fun b64url(bytes: ByteArray) = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    private fun payloadObject() = JSONObject(request().toPayload())

    private fun rejectsPayload(raw: String) {
        assertThrows(Exception::class.java) { LibraryKeyBootstrap.DeviceSignInRequest.fromPayload(raw, now) }
    }

    private fun rejects(code: String, block: () -> Unit) {
        try { block(); fail("Expected rejection") }
        catch (failure: CloudAuthFailure) { assertEquals(code, failure.code) }
    }

    @Test fun payloadUsesSortedKeysUnescapedSlashesAndUnpaddedBase64url() {
        val expected = "{\"expiresAt\":${now + 600},\"kind\":\"snippets-device-sign-in\"," +
            "\"nonce\":\"${b64url(draft.nonce)}\",\"recipientPublicKey\":\"${b64url(draft.recipientPublicKey)}\"," +
            "\"requestId\":\"$requestID\",\"schemaVersion\":1,\"server\":\"$origin\"}"
        val payload = request().toPayload()
        assertEquals(expected, payload)
        assertFalse(payload.contains("\\/"))
        assertFalse(payload.contains("="))
        assertTrue(payload.toByteArray().size <= 4_096)
    }

    @Test fun payloadRoundTripsAndBindsEveryField() {
        val parsed = LibraryKeyBootstrap.DeviceSignInRequest.fromPayload(request().toPayload(), now)
        assertEquals(origin, parsed.serverURL)
        assertEquals(requestID, parsed.requestID)
        assertArrayEquals(draft.nonce, parsed.nonce)
        assertArrayEquals(draft.recipientPublicKey, parsed.recipientPublicKey)
        assertEquals(now + 600, parsed.expiresAtEpochSeconds)
        // Escaped slashes from a generic encoder are still the same JSON value.
        assertEquals(origin, LibraryKeyBootstrap.DeviceSignInRequest
            .fromPayload(request().toPayload().replace("/", "\\/"), now).serverURL)
        assertTrue(LibraryKeyBootstrap.DeviceSignInRequest.isDeviceSignInPayload(request().toPayload()))
        assertFalse(LibraryKeyBootstrap.DeviceSignInRequest.isDeviceSignInPayload("{\"kind\":\"snippets-pairing\"}"))
        assertFalse(LibraryKeyBootstrap.DeviceSignInRequest.isDeviceSignInPayload("not json"))
        assertFalse(request().toString().contains(requestID))
    }

    @Test fun payloadParsingIsStrictAboutKeysAndValues() {
        rejectsPayload(payloadObject().put("pollToken", pollToken).toString())
        rejectsPayload(payloadObject().put("extra", 1).toString())
        rejectsPayload(payloadObject().apply { remove("nonce") }.toString())
        rejectsPayload(payloadObject().put("kind", "snippets-pairing").toString())
        rejectsPayload(payloadObject().put("schemaVersion", 2).toString())
        rejectsPayload(payloadObject().put("schemaVersion", "1").toString())
        rejectsPayload(payloadObject().put("expiresAt", (now + 600).toString()).toString())
        rejectsPayload(payloadObject().put("requestId", requestID.uppercase()).toString())
        rejectsPayload(payloadObject().put("requestId", "not-a-uuid").toString())
        rejectsPayload(payloadObject().put("server", "$origin/").toString())
        rejectsPayload(payloadObject().put("server", "http://cloud.example.test").toString())
        rejectsPayload(payloadObject().put("nonce", b64url(draft.nonce) + "=").toString())
        rejectsPayload(payloadObject().put("nonce", Base64.getEncoder().encodeToString(draft.nonce)).toString())
        rejectsPayload(payloadObject().put("nonce", b64url(ByteArray(31))).toString())
        rejectsPayload(payloadObject().put("recipientPublicKey",
            b64url(byteArrayOf(4) + ByteArray(64))).toString()) // not on the curve
        rejectsPayload(JSONObject(request(expiresAt = now - 31).toPayload()).toString())
        rejectsPayload(JSONObject(request(expiresAt = now + 631).toPayload()).toString())
        rejectsPayload(" ".repeat(4_097))
    }

    @Test fun confirmationCodeIsTheUnchangedPairingDerivation() {
        val pairing = LibraryKeyBootstrap.PairingInvitation(
            serverURL = origin,
            spaceID = "00000000-0000-4000-8000-000000000001",
            pairingID = "00000000-0000-4000-8000-000000000002",
            nonce = draft.nonce,
            recipientPublicKey = draft.recipientPublicKey,
            expiresAtEpochSeconds = now + 300,
        )
        assertEquals(pairing.confirmationCode, request().confirmationCode)
        val digest = MessageDigest.getInstance("SHA-256").run {
            update("snippets-pairing-confirm-v1".toByteArray())
            update(draft.nonce)
            update(draft.recipientPublicKey)
            digest()
        }
        val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        assertEquals(digest.take(8).map { alphabet[it.toInt() and 31] }.joinToString(""),
            request().confirmationCode)
    }

    @Test fun pendingNewDeviceStateRoundTripsAndRequiresMatchingMaterial() {
        val pending = LibraryKeyBootstrap.PendingDeviceSignIn(draft, request(), pollToken)
        val restored = LibraryKeyBootstrap.PendingDeviceSignIn.fromJSON(pending.toJSON(), now)
        assertEquals(pollToken, restored.pollToken)
        assertEquals(request().toPayload(), restored.request.toPayload())
        assertArrayEquals(draft.privateKeyPKCS8, restored.draft.privateKeyPKCS8)
        assertFalse(pending.toString().contains(pollToken))
        val other = LibraryKeyBootstrap.createPairingDraft()
        assertThrows(IllegalArgumentException::class.java) {
            LibraryKeyBootstrap.PendingDeviceSignIn(other, request(), pollToken)
        }
        for (token in listOf("sn_a_" + pollToken.drop(5), pollToken.dropLast(1), pollToken + "A", "")) {
            assertThrows(IllegalArgumentException::class.java) {
                LibraryKeyBootstrap.PendingDeviceSignIn(draft, request(), token)
            }
        }
    }

    @Test fun pendingApprovalRecordsThePairingBeforeApproval() {
        val initial = LibraryKeyBootstrap.PendingDeviceApproval(request(), null)
        assertNull(LibraryKeyBootstrap.PendingDeviceApproval.fromJSON(initial.toJSON(), now).pairing)
        val pairing = LibraryKeyBootstrap.PairingInvitation(origin,
            "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002",
            draft.nonce, draft.recipientPublicKey, now + 300)
        val recorded = LibraryKeyBootstrap.PendingDeviceApproval.fromJSON(
            LibraryKeyBootstrap.PendingDeviceApproval(request(), pairing).toJSON(), now)
        assertEquals(pairing.pairingID, recorded.pairing?.pairingID)
        assertThrows(IllegalArgumentException::class.java) {
            LibraryKeyBootstrap.PendingDeviceApproval(request(),
                pairing.copy(nonce = LibraryKeyBootstrap.createPairingDraft().nonce))
        }
    }

    @Test fun approverPairingLifetimeIsClampedToTheRequest() {
        assertEquals(595, LibraryKeyBootstrap.deviceSignInPairingSeconds(now + 600, now))
        assertEquals(600, LibraryKeyBootstrap.deviceSignInPairingSeconds(now + 900, now))
        assertEquals(115, LibraryKeyBootstrap.deviceSignInPairingSeconds(now + 120, now))
        assertEquals(60, LibraryKeyBootstrap.deviceSignInPairingSeconds(now + 65, now))
        assertEquals(60, LibraryKeyBootstrap.deviceSignInPairingSeconds(now + 10, now))
        assertEquals(60, LibraryKeyBootstrap.deviceSignInPairingSeconds(now - 100, now))
    }

    @Test fun pollingHonorsRetryAfterAndBacksOff() {
        assertEquals(2_000, deviceSignInPollDelayMillis(0, null))
        assertEquals(4_000, deviceSignInPollDelayMillis(1, null))
        assertEquals(30_000, deviceSignInPollDelayMillis(9, null))
        assertEquals(17_000, deviceSignInPollDelayMillis(0, 17))
    }

    // MARK: - Protocol

    private fun discovery(capabilities: List<String>) = JSONObject().put("protocolMajor", 2)
        .put("apiBase", "$origin/v2")
        .put("capabilities", JSONArray(capabilities))
        .put("nativeAuth", JSONObject().put("flow", "account_key")
            .put("createAccountEndpoint", "$origin/v2/auth/accounts")
            .put("signInEndpoint", "$origin/v2/auth/sign-in")
            .put("refreshEndpoint", "$origin/v2/auth/refresh")
            .put("revokeEndpoint", "$origin/v2/auth/revoke"))

    private val baseCapabilities = listOf("native-account-key-v1", "library-action-proof-v1",
        "pairing-v2", "offline-recovery-v1", "resource-session-revocation")

    @Test fun deviceSignInRequiresItsCapabilityAndUsesFixedPaths() {
        rejects("device_sign_in_unavailable") {
            NativeCloudAuthority.parseWithDeviceSignIn(origin, discovery(baseCapabilities))
        }
        val authority = NativeCloudAuthority.parseWithDeviceSignIn(origin,
            discovery(baseCapabilities + "native-device-sign-in-v1"))
        assertEquals("$origin/v2/auth/device-requests", authority.deviceRequestsEndpoint)
        assertEquals("$origin/v2/auth/device-requests/$requestID/claim",
            authority.deviceClaimEndpoint(requestID.uppercase()))
        assertThrows(IllegalArgumentException::class.java) { authority.deviceClaimEndpoint("../accounts") }
    }

    private fun isoSeconds(epoch: Long) = Instant.ofEpochSecond(epoch).toString()

    @Test fun deviceRequestResponseHasExactMembers() {
        val response = JSONObject().put("requestId", requestID).put("pollToken", pollToken)
            .put("expiresAt", "2026-10-03T12:10:00.123456Z")
        val nowAtCreation = Instant.parse("2026-10-03T12:00:00Z").epochSecond
        val parsed = NativeCloudDeviceRequest.parse(response, nowAtCreation)
        assertEquals(requestID, parsed.requestID)
        assertEquals(nowAtCreation + 600, parsed.expiresAtEpochSeconds)
        assertFalse(parsed.toString().contains(pollToken))
        for (bad in listOf(
            JSONObject(response.toString()).put("extra", true),
            JSONObject(response.toString()).put("pollToken", "sn_a_" + pollToken.drop(5)),
            JSONObject(response.toString()).put("requestId", "x"),
            JSONObject(response.toString()).put("expiresAt", "2026-10-03T13:00:00Z"),
            JSONObject(response.toString()).put("expiresAt", 1_790_000_000),
        )) {
            rejects("server_response_invalid") { NativeCloudDeviceRequest.parse(bad, nowAtCreation) }
        }
    }

    private val tokens = JSONObject().put("access_token", "opaque-access-token-without-jwt")
        .put("refresh_token", "opaque-refresh-token").put("expires_in", 300).put("token_type", "Bearer")
        .put("account", JSONObject().put("id", "5f0c3a1e-9b2d-4c7e-8a41-0d6b2e9f7c13"))
    private val requestExpires = now + 600

    private fun pendingClaim() = JSONObject().put("state", "pending").put("expiresAt", isoSeconds(requestExpires))

    private fun approvedClaim() = JSONObject().put("state", "approved").put("expiresAt", isoSeconds(requestExpires))
        .put("spaceId", "00000000-0000-4000-8000-000000000001")
        .put("pairingId", "00000000-0000-4000-8000-000000000002")
        .put("session", JSONObject(tokens.toString()))

    private fun parseClaim(value: JSONObject, journal: MutableList<NativeCloudCredentialGeneration>) =
        NativeCloudDeviceClaim.parseAfterJournaling(value, "issued-grant", requestExpires, journal::add)

    @Test fun pendingClaimHasExactlyStateAndExpiry() {
        val journal = mutableListOf<NativeCloudCredentialGeneration>()
        assertSame(NativeCloudDeviceClaim.Pending, parseClaim(pendingClaim(), journal))
        assertTrue(journal.isEmpty())
        rejects("server_response_invalid") { parseClaim(pendingClaim().put("spaceId", "x"), journal) }
        rejects("server_response_invalid") {
            parseClaim(pendingClaim().put("expiresAt", isoSeconds(requestExpires + 60)), journal)
        }
        rejects("server_response_invalid") { parseClaim(pendingClaim().put("state", "denied"), journal) }
    }

    @Test fun approvedClaimCarriesLibraryPairingAndSession() {
        val journal = mutableListOf<NativeCloudCredentialGeneration>()
        val claim = parseClaim(approvedClaim(), journal) as NativeCloudDeviceClaim.Approved
        assertEquals("00000000-0000-4000-8000-000000000001", claim.spaceID)
        assertEquals("00000000-0000-4000-8000-000000000002", claim.pairingID)
        assertEquals("5f0c3a1e-9b2d-4c7e-8a41-0d6b2e9f7c13", claim.session.accountID)
        assertEquals("opaque-refresh-token", journal.single().refreshToken)
    }

    @Test fun malformedApprovedClaimStillJournalsItsSessionForRevocation() {
        for (bad in listOf(
            approvedClaim().put("extra", 1),
            approvedClaim().apply { remove("pairingId") },
            approvedClaim().put("spaceId", "not-a-uuid"),
            approvedClaim().put("expiresAt", isoSeconds(requestExpires - 120)),
        )) {
            val journal = mutableListOf<NativeCloudCredentialGeneration>()
            rejects("server_response_invalid") { parseClaim(bad, journal) }
            assertEquals(1, journal.size)
        }
        val journal = mutableListOf<NativeCloudCredentialGeneration>()
        rejects("server_response_invalid") { parseClaim(approvedClaim().apply { remove("session") }, journal) }
        assertTrue(journal.isEmpty())
    }

    @Test fun deviceSignInCopyMatchesTheContract() {
        assertEquals("This device was signed in by another device. View the account key on a device that has it.",
            DEVICE_SIGNED_IN_ACCOUNT_KEY_COPY)
        assertEquals("Sign in a new device to this account? It will also receive this library's key. " +
            "Continue only if this code matches the code on the new device.", DEVICE_SIGN_IN_APPROVAL_COPY)
        assertEquals("The new device is signed in.", DEVICE_SIGN_IN_APPROVED_COPY)
        assertEquals(CloudErrorAction.SIGN_IN, cloudErrorPresentation("device_sign_in_unavailable").action)
    }
}
