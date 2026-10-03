package com.khm.snippets.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class NativeCloudProtocolTest {
    private val origin = "https://cloud.example.test"

    private val accountID = "5f0c3a1e-9b2d-4c7e-8a41-0d6b2e9f7c13"
    private val canonicalKey = "7KQF9M2XR4TDH8WBZN3CP6YE1AQ7"

    private fun discovery() = JSONObject().put("protocolMajor", 2).put("apiBase", "$origin/v2")
        .put("capabilities", JSONArray(listOf("native-account-key-v1", "library-action-proof-v1",
            "pairing-v2", "offline-recovery-v1", "resource-session-revocation")))
        .put("nativeAuth", JSONObject().put("flow", "account_key")
            .put("createAccountEndpoint", "$origin/v2/auth/accounts")
            .put("signInEndpoint", "$origin/v2/auth/sign-in")
            .put("refreshEndpoint", "$origin/v2/auth/refresh")
            .put("revokeEndpoint", "$origin/v2/auth/revoke"))

    private fun tokens() = JSONObject().put("access_token", "opaque-access-token-without-jwt")
        .put("refresh_token", "opaque-refresh-token").put("expires_in", 300).put("token_type", "Bearer")
        .put("account", JSONObject().put("id", accountID))

    private fun creation() = JSONObject().put("accountKey", canonicalKey).put("session", tokens())

    private fun rejects(code: String, block: () -> Unit) {
        try { block(); fail("Expected rejection") }
        catch (failure: CloudAuthFailure) { assertEquals(code, failure.code) }
    }

    @Test fun nativeDiscoveryWorksWithoutOIDCOrCallbackConfiguration() {
        assertEquals(NativeCloudAuthority.forServer(origin), NativeCloudAuthority.parse(origin, discovery()))
    }

    @Test fun discoveryPinsAccountKeyEndpointsToExactPaths() {
        val authority = NativeCloudAuthority.parse(origin, discovery())
        assertEquals("$origin/v2/auth/accounts", authority.createAccountEndpoint)
        assertEquals("$origin/v2/auth/sign-in", authority.signInEndpoint)
        assertEquals("$origin/v2/auth/refresh", authority.refreshEndpoint)
        assertEquals("$origin/v2/auth/revoke", authority.revokeEndpoint)
    }

    @Test fun refusesToSendKeysOrTokensToCrossOriginOrMovedDiscoveryEndpoints() {
        for (key in listOf("createAccountEndpoint", "signInEndpoint", "refreshEndpoint", "revokeEndpoint")) {
            for (endpoint in listOf("https://other.example.test/v2/auth/sign-in",
                "$origin/v2/auth/other", "$origin:8443/v2/auth/sign-in", "")) {
                val document = discovery()
                document.getJSONObject("nativeAuth").put(key, endpoint)
                rejects("server_identity_mismatch") { NativeCloudAuthority.parse(origin, document) }
            }
        }
    }

    @Test fun refusesDowngradeToBrowserOrRemovedEmailFlow() {
        for (flow in listOf("authorization_code_pkce", "email_code")) {
            val document = discovery()
            document.getJSONObject("nativeAuth").put("flow", flow)
            rejects("server_auth_insecure") { NativeCloudAuthority.parse(origin, document) }
        }
        val legacy = discovery().put("capabilities", JSONArray(listOf("native-email-code-v1",
            "library-action-proof-v1", "pairing-v2", "offline-recovery-v1", "resource-session-revocation")))
        rejects("server_auth_insecure") { NativeCloudAuthority.parse(origin, legacy) }
    }

    @Test fun acceptsOpaqueTokensAndAuthoritativeAccountIdentity() {
        val response = NativeCloudTokenResponse.parse(tokens())
        assertEquals("opaque-access-token-without-jwt", response.accessToken)
        assertEquals(accountID, response.accountID)
    }

    @Test fun accountIdentityIsAnImmutableUUIDDisplayedByItsFirstEightDigits() {
        val upper = tokens()
        upper.getJSONObject("account").put("id", accountID.uppercase())
        assertEquals(accountID, NativeCloudTokenResponse.parse(upper).accountID)
        assertEquals("5F0C-3A1E", nativeCloudAccountIDDisplay(accountID))
        for (id in listOf("immutable-account-id", "$accountID\n", "{$accountID}", "")) {
            val response = tokens()
            response.getJSONObject("account").put("id", id)
            rejects("authorization_response_mismatch") { NativeCloudTokenResponse.parse(response) }
        }
    }

    @Test fun refreshMustRotateAndPreserveAccountID() {
        rejects("refresh_token_not_rotated") {
            NativeCloudTokenResponse.parse(tokens(), previousRefreshToken = "opaque-refresh-token")
        }
        rejects("authorization_response_mismatch") {
            NativeCloudTokenResponse.parse(tokens(),
                expectedAccountID = "00000000-0000-4000-8000-000000000001")
        }
    }

    @Test fun accountCreationReturnsCanonicalKeyWithItsSession() {
        val journal = mutableListOf<NativeCloudCredentialGeneration>()
        val created = NativeCloudAccountCreation.parseAfterJournaling(creation(), "issued-grant", journal::add)
        assertEquals(canonicalKey, created.accountKey)
        assertEquals(accountID, created.session.accountID)
        assertEquals("opaque-refresh-token", journal.single().refreshToken)
        assertFalse(created.toString().contains(canonicalKey))
    }

    @Test fun rejectedCreationKeyStillJournalsIssuedSessionForRevocation() {
        for (key in listOf<Any?>("7KQF-9M2X-R4TD-H8WB-ZN3C-P6YE-1AQ7", "7kqf9m2xr4tdh8wbzn3cp6ye1aq7",
            "7KQF9M2XR4TDH8WBZN3CP6YE1AQ8", 42, null)) {
            val journal = mutableListOf<NativeCloudCredentialGeneration>()
            val response = creation().put("accountKey", key ?: JSONObject.NULL)
            rejects("server_response_invalid") {
                NativeCloudAccountCreation.parseAfterJournaling(response, "issued-grant", journal::add)
            }
            assertEquals(1, journal.size)
        }
    }

    @Test fun creationWithoutSessionHasNothingToJournal() {
        val journal = mutableListOf<NativeCloudCredentialGeneration>()
        rejects("server_response_invalid") {
            NativeCloudAccountCreation.parseAfterJournaling(JSONObject().put("accountKey", canonicalKey),
                "issued-grant", journal::add)
        }
        assertTrue(journal.isEmpty())
    }

    @Test fun tokenLifetimeCannotOutliveNativePolicy() {
        rejects("token_exchange_failed") { NativeCloudTokenResponse.parse(tokens().put("expires_in", 301)) }
    }

    @Test fun malformedProfileCannotBecomeAccountIdentity() {
        val response = tokens()
        response.getJSONObject("account").put("id", "$accountID\nInjected")
        rejects("authorization_response_mismatch") { NativeCloudTokenResponse.parse(response) }
    }

    @Test fun refusesUnsafeNativeOrigins() {
        for (url in listOf("http://cloud.example.test", "https://user@cloud.example.test",
            "https://cloud.example.test?token=x", "https://cloud.example.test/prefix")) {
            rejects("server_url_invalid") { nativeCloudServerURL(url) }
        }
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
        response.getJSONObject("account").put("id", "not a uuid")
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
                "00000000-0000-4000-8000-000000000001", journal::add)
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
