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

    @Test
    fun recoveryVerificationIsVersionedAndBoundToTheCurrentLibrary() {
        val kit = LibraryKeyBootstrap.RecoveryKit(
            serverURL = "https://cloud.example",
            spaceID = "00000000-0000-4000-8000-000000000001",
            keyEpoch = 7,
            secret = ByteArray(32) { it.toByte() },
        )
        val stored = RecoveryKitVerification.fromRecoveryKit(kit)
        val restored = RecoveryKitVerification.fromJSON(stored.toJSON())

        assertEquals(stored, restored)
        assertTrue(restored!!.matches(CloudConfiguration(
            serverURL = "https://cloud.example",
            spaceID = "00000000-0000-4000-8000-000000000001",
        )))
        assertFalse(restored.matches(CloudConfiguration(
            serverURL = "https://cloud.example",
            spaceID = "00000000-0000-4000-8000-000000000002",
        )))
        assertEquals(null, RecoveryKitVerification.fromJSON("true"))
    }

    @Test
    fun unfinishedRecoveryReplacementBlocksDisconnectAcrossBothDurableStages() {
        assertTrue(disconnectBlockedForRecovery(CloudKeyStatus.RECOVERY_AUTH_REQUIRED))
        assertTrue(disconnectBlockedForRecovery(CloudKeyStatus.RECOVERY_KIT_LOCKED))
        assertFalse(disconnectBlockedForRecovery(CloudKeyStatus.READY))
    }

    @Test
    fun ambiguousLibrariesRequireAnExplicitChoiceInsteadOfRepeatingOAuth() {
        val first = HttpSyncClient.SpaceCandidate(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000010",
            "owner",
        )
        val second = first.copy(
            spaceID = "00000000-0000-4000-8000-000000000002",
        )

        assertEquals(null, automaticPersonalSpace(listOf(first, second), null))
        assertEquals(
            second.spaceID,
            automaticPersonalSpace(listOf(first, second), second.spaceID)?.spaceID,
        )
    }

    @Test
    fun libraryIdentifierNamesTheLibraryAndUsesEightHexCharacters() {
        val identifier = cloudLibraryID(
            "00000000-0000-4000-8000-000000000010",
            "00000000-0000-4000-8000-000000000001",
        )
        assertEquals("1A60C0E7", identifier)
        assertTrue(identifier.matches(Regex("^[0-9A-F]{8}$")))
    }
}
