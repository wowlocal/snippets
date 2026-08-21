package com.khm.snippets.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CloudAccountUxTest {
    @Test
    fun recoveryVerificationNormalizesSeparatorsAndRequiresTheSavedSuffix() {
        val code = "ABCD-EFGH-IJKL-MNPQ-RSTU-VWXY-2345-6789-ABCD-EFGH-IJKL-MNPQ-QRST"

        assertTrue(recoveryKitVerificationMatches(code, "mnpq-qrst"))
        assertFalse(recoveryKitVerificationMatches(code, "00000000"))
        assertFalse(recoveryKitVerificationMatches(code, "QRST"))
    }

    @Test
    fun recoveryInputAcceptsPasteAndFormatsBase32Groups() {
        assertEquals(
            "ABCD-EF23-4567",
            formattedRecoveryCode("ab cd-ef23 4567!"),
        )
    }

    @Test
    fun cloudConfigurationPersistsLastConfirmedSyncWithoutBreakingOlderState() {
        val value = CloudConfiguration(
            provider = SyncProvider.SNIPPETS_CLOUD,
            serverURL = "https://cloud.example",
            apiBaseURL = "https://cloud.example/v2",
            protocolMajor = 2,
            spaceID = "00000000-0000-0000-0000-000000000001",
            lastSuccessfulSyncEpochSeconds = 1_788_000_000,
        )

        assertEquals(value, cloudConfiguration(value.toJSON()))
        assertEquals(
            null,
            cloudConfiguration(
                value.toJSON().replace(
                    ",\"lastSuccessfulSyncEpochSeconds\":1788000000",
                    "",
                ),
            ).lastSuccessfulSyncEpochSeconds,
        )
    }
}
