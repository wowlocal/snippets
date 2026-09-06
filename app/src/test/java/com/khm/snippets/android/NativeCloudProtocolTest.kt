package com.khm.snippets.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class NativeCloudProtocolTest {
    private val origin = "https://cloud.example.test"

    private fun discovery() = JSONObject().put("protocolMajor", 2).put("apiBase", "$origin/v2")
        .put("capabilities", JSONArray(listOf("native-email-code-v1", "library-action-proof-v1",
            "pairing-v2", "offline-recovery-v1", "resource-session-revocation")))
        .put("nativeAuth", JSONObject().put("flow", "email_code")
            .put("startEndpoint", "$origin/v2/auth/email/start")
            .put("verifyEndpoint", "$origin/v2/auth/email/verify")
            .put("refreshEndpoint", "$origin/v2/auth/refresh")
            .put("revokeEndpoint", "$origin/v2/auth/revoke"))

    private fun tokens() = JSONObject().put("access_token", "opaque-access-token-without-jwt")
        .put("refresh_token", "opaque-refresh-token").put("expires_in", 300).put("token_type", "Bearer")
        .put("account", JSONObject().put("id", "immutable-account-id").put("email", "test@example.test"))

    private fun rejects(code: String, block: () -> Unit) {
        try { block(); fail("Expected rejection") }
        catch (failure: CloudAuthFailure) { assertEquals(code, failure.code) }
    }

    @Test fun nativeDiscoveryWorksWithoutOIDCOrCallbackConfiguration() {
        assertEquals(NativeCloudAuthority.forServer(origin), NativeCloudAuthority.parse(origin, discovery()))
    }

    @Test fun refusesToSendEmailOrTokensToCrossOriginDiscoveryEndpoints() {
        for (key in listOf("startEndpoint", "verifyEndpoint", "refreshEndpoint", "revokeEndpoint")) {
            val document = discovery()
            document.getJSONObject("nativeAuth").put(key, "https://other.example.test/v2/auth/verify")
            rejects("server_identity_mismatch") { NativeCloudAuthority.parse(origin, document) }
        }
    }

    @Test fun refusesDowngradeToBrowserFlow() {
        val document = discovery()
        document.getJSONObject("nativeAuth").put("flow", "authorization_code_pkce")
        rejects("server_auth_insecure") { NativeCloudAuthority.parse(origin, document) }
    }

    @Test fun acceptsOpaqueTokensAndAuthoritativeAccountIdentity() {
        val response = NativeCloudTokenResponse.parse(tokens())
        assertEquals("opaque-access-token-without-jwt", response.accessToken)
        assertEquals("immutable-account-id", response.accountID)
        assertEquals("test@example.test", response.email)
    }

    @Test fun refreshMustRotateAndPreserveAccountID() {
        rejects("refresh_token_not_rotated") {
            NativeCloudTokenResponse.parse(tokens(), previousRefreshToken = "opaque-refresh-token")
        }
        rejects("authorization_response_mismatch") {
            NativeCloudTokenResponse.parse(tokens(), expectedAccountID = "other-account-id")
        }
    }

    @Test fun tokenLifetimeCannotOutliveNativePolicy() {
        rejects("token_exchange_failed") { NativeCloudTokenResponse.parse(tokens().put("expires_in", 301)) }
    }

    @Test fun malformedProfileCannotBecomeAccountIdentity() {
        val response = tokens()
        response.getJSONObject("account").put("email", "test@example.test\nInjected")
        rejects("authorization_response_mismatch") { NativeCloudTokenResponse.parse(response) }
    }

    @Test fun refusesUnsafeNativeOrigins() {
        for (url in listOf("http://cloud.example.test", "https://user@cloud.example.test",
            "https://cloud.example.test?token=x", "https://cloud.example.test/prefix")) {
            rejects("server_url_invalid") { nativeCloudServerURL(url) }
        }
    }

    @Test fun validatesChallengeLengthAndServerBounds() {
        val challenge = JSONObject().put("challengeId", "opaque-challenge-identifier")
            .put("expiresIn", 600).put("resendAfter", 60).put("codeLength", 6)
        assertEquals(6, CloudEmailChallenge.parse(challenge).codeLength)
        rejects("server_response_invalid") { CloudEmailChallenge.parse(challenge.put("codeLength", 4)) }
    }

    @Test fun committingRotatedCandidateKeepsItsEntireRefreshFamily() {
        val old = NativeCloudCredentialGeneration("old-grant", "old-access", "old-refresh")
        val candidate1 = NativeCloudCredentialGeneration("new-grant", "candidate-access-1", "candidate-refresh-1")
        val candidate2 = NativeCloudCredentialGeneration("new-grant", "candidate-access-2", "candidate-refresh-2")
        val plan = nativeCloudReplacementCleanupPlan(candidate2, listOf(old, candidate1, candidate2))!!
        assertEquals(listOf("old-access", "candidate-access-1"), plan.accessTokensToRetire)
        assertEquals(listOf("old-refresh"), plan.refreshTokensToRetire)
    }

    @Test fun cancellingRotatedCandidateRetiresItsWholeFamily() {
        val old = NativeCloudCredentialGeneration("old-grant", "old-access", "old-refresh")
        val candidate1 = NativeCloudCredentialGeneration("new-grant", "candidate-access-1", "candidate-refresh-1")
        val candidate2 = NativeCloudCredentialGeneration("new-grant", "candidate-access-2", "candidate-refresh-2")
        val plan = nativeCloudReplacementCleanupPlan(old, listOf(old, candidate1, candidate2))!!
        assertEquals(listOf("candidate-refresh-1", "candidate-refresh-2"), plan.refreshTokensToRetire)
    }

    @Test fun unrecognizedCurrentGenerationCannotGuessCleanup() {
        val old = NativeCloudCredentialGeneration("old-grant", "old-access", "old-refresh")
        val other = NativeCloudCredentialGeneration("other-grant", "other-access", "other-refresh")
        assertNull(nativeCloudReplacementCleanupPlan(other, listOf(old)))
    }

    @Test fun crashBeforePublishingFirstGrantCanRetireJournal() {
        val candidate = NativeCloudCredentialGeneration("new-grant", "candidate-access", "candidate-refresh")
        val plan = nativeCloudReplacementCleanupPlan(null, listOf(candidate))!!
        assertEquals(listOf("candidate-access"), plan.accessTokensToRetire)
        assertEquals(listOf("candidate-refresh"), plan.refreshTokensToRetire)
    }

    @Test fun acceptsFinalSecondsOfRefreshFamilyLifetime() {
        assertEquals(1, NativeCloudTokenResponse.parse(tokens().put("expires_in", 1)).expiresIn)
        rejects("token_exchange_failed") { NativeCloudTokenResponse.parse(tokens().put("expires_in", 0)) }
    }

    @Test fun dailyRetryAfterRemainsOneFullDay() {
        assertEquals(86_400, nativeCloudRetryAfter("86400"))
        assertEquals(86_400, nativeCloudRetryAfter("999999"))
        assertNull(nativeCloudRetryAfter("unexpected value"))
    }

    @Test fun rejectedProfileLeavesIssuedCredentialsAvailableForRevocation() {
        val response = tokens()
        response.getJSONObject("account").put("email", "bad email")
        val journal = mutableListOf<NativeCloudCredentialGeneration>()
        rejects("authorization_response_mismatch") {
            NativeCloudTokenResponse.parseAfterJournaling(response, "issued-grant", persistIssued = journal::add)
        }
        assertEquals(listOf(NativeCloudCredentialGeneration("issued-grant",
            "opaque-access-token-without-jwt", "opaque-refresh-token")), journal)
    }

    @Test fun rejectedLifetimeAndTokenTypeStillJournalRevocablePair() {
        for (response in listOf(tokens().put("expires_in", 301), tokens().put("token_type", "Other"))) {
            val journal = mutableListOf<NativeCloudCredentialGeneration>()
            rejects("token_exchange_failed") {
                NativeCloudTokenResponse.parseAfterJournaling(response, "issued-grant", persistIssued = journal::add)
            }
            assertEquals(1, journal.size)
        }
    }

    @Test fun rejectedRefreshAccountStillJournalsRotatedCredentials() {
        val journal = mutableListOf<NativeCloudCredentialGeneration>()
        rejects("authorization_response_mismatch") {
            NativeCloudTokenResponse.parseAfterJournaling(tokens(), "existing-grant", "previous-refresh",
                "different-account", journal::add)
        }
        assertEquals("opaque-refresh-token", journal.single().refreshToken)
    }

    @Test fun committedRefreshRetiresOnlyPriorAccessToken() {
        val previous = NativeCloudCredentialGeneration("grant", "previous-access", "previous-refresh")
        val issued = NativeCloudCredentialGeneration("grant", "issued-access", "issued-refresh")
        assertEquals(NativeCloudRefreshCleanupPlan(listOf("previous-access"), emptyList(), false),
            nativeCloudRefreshCleanupPlan(issued, previous, issued))
    }

    @Test fun rejectedOrInterruptedRefreshRetiresIssuedFamilyAndDiscardsExpiredPrimary() {
        val previous = NativeCloudCredentialGeneration("grant", "previous-access", "previous-refresh")
        val issued = NativeCloudCredentialGeneration("grant", "issued-access", "issued-refresh")
        val expected = NativeCloudRefreshCleanupPlan(listOf("issued-access"), listOf("issued-refresh"), true)
        assertEquals(expected, nativeCloudRefreshCleanupPlan(previous, previous, issued))
        assertEquals(expected, nativeCloudRefreshCleanupPlan(null, previous, issued))
    }

    @Test fun unrotatedResponseCannotMasqueradeAsCommittedRefresh() {
        val previous = NativeCloudCredentialGeneration("grant", "previous-access", "previous-refresh")
        assertEquals(NativeCloudRefreshCleanupPlan(listOf("previous-access"), listOf("previous-refresh"), true),
            nativeCloudRefreshCleanupPlan(previous, previous, previous))
    }

    @Test fun refreshCleanupRejectsUnrelatedPrimaryOrMixedGrant() {
        val previous = NativeCloudCredentialGeneration("grant", "previous-access", "previous-refresh")
        val issued = NativeCloudCredentialGeneration("grant", "issued-access", "issued-refresh")
        val other = NativeCloudCredentialGeneration("other", "other-access", "other-refresh")
        assertNull(nativeCloudRefreshCleanupPlan(other, previous, issued))
        assertNull(nativeCloudRefreshCleanupPlan(previous, previous, other))
    }

}
