package com.khm.snippets.android

import org.junit.Assert.assertEquals
import org.junit.Test

class CloudCredentialRevocationPlanTest {
    @Test
    fun journalWinsAfterRefreshCrashBeforePrimarySessionReplacement() {
        val plan = cloudCredentialRevocationPlan(
            sessionAccessToken = "old-access-token",
            sessionRefreshToken = "old-refresh-token",
            journalAccessTokens = listOf("old-access-token", "new-access-token"),
            journalRefreshTokens = listOf("old-refresh-token", "new-refresh-token"),
        )

        assertEquals(
            listOf("old-access-token", "new-access-token"),
            plan.accessTokens,
        )
        assertEquals(
            listOf("old-refresh-token", "new-refresh-token"),
            plan.refreshTokens,
        )
    }
}
