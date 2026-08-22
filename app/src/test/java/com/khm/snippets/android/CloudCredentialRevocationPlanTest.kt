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

    @Test
    fun cancelledInteractiveGrantRetiresOnlyTheCandidate() {
        val plan = cloudCredentialReplacementCleanupPlan(
            currentAccessToken = "old-access-token",
            currentRefreshToken = "old-refresh-token",
            journalAccessTokens = listOf("old-access-token", "new-access-token"),
            journalRefreshTokens = listOf("old-refresh-token", "new-refresh-token"),
        )

        assertEquals(listOf("new-access-token"), plan?.accessTokensToRetire)
        assertEquals(listOf("new-refresh-token"), plan?.refreshTokensToRetire)
    }

    @Test
    fun committedInteractiveGrantRetiresOnlyTheSupersededGeneration() {
        val plan = cloudCredentialReplacementCleanupPlan(
            currentAccessToken = "new-access-token",
            currentRefreshToken = "new-refresh-token",
            journalAccessTokens = listOf("old-access-token", "new-access-token"),
            journalRefreshTokens = listOf("old-refresh-token", "new-refresh-token"),
        )

        assertEquals(listOf("old-access-token"), plan?.accessTokensToRetire)
        assertEquals(listOf("old-refresh-token"), plan?.refreshTokensToRetire)
    }

    @Test
    fun committedRotatedCandidateRetiresOldAccountAndEarlierCandidateGeneration() {
        val plan = cloudCredentialReplacementCleanupPlan(
            currentAccessToken = "candidate-access-2",
            currentRefreshToken = "candidate-refresh-2",
            journalAccessTokens = listOf(
                "old-access-token", "candidate-access-1", "candidate-access-2",
            ),
            journalRefreshTokens = listOf(
                "old-refresh-token", "candidate-refresh-1", "candidate-refresh-2",
            ),
        )

        assertEquals(
            listOf("old-access-token", "candidate-access-1"),
            plan?.accessTokensToRetire,
        )
        assertEquals(
            listOf("old-refresh-token", "candidate-refresh-1"),
            plan?.refreshTokensToRetire,
        )
    }

    @Test
    fun abandonedFirstGrantIsEntirelyRetired() {
        val plan = cloudCredentialReplacementCleanupPlan(
            currentAccessToken = null,
            currentRefreshToken = null,
            journalAccessTokens = listOf("new-access-token"),
            journalRefreshTokens = listOf("new-refresh-token"),
        )

        assertEquals(listOf("new-access-token"), plan?.accessTokensToRetire)
        assertEquals(listOf("new-refresh-token"), plan?.refreshTokensToRetire)
    }
}
