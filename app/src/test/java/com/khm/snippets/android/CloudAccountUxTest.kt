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
            pendingAuthorizationCommit = true,
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
        val envelope = HttpSyncClient.RecoveryEnvelopeRecord(
            version = 3,
            keyEpoch = 7,
            algorithm = LibraryKeyBootstrap.RECOVERY_ALGORITHM,
            ciphertext = byteArrayOf(1, 2, 3),
        )
        val stored = RecoveryKitVerification.fromRecoveryKit(kit, envelope)
        val restored = RecoveryKitVerification.fromJSON(stored.toJSON())
        val configuration = CloudConfiguration(
            serverURL = "https://cloud.example",
            spaceID = "00000000-0000-4000-8000-000000000001",
        )

        assertEquals(stored, restored)
        assertTrue(restored!!.matches(
            configuration,
            HttpSyncClient.RecoveryEnvelopeState(7, envelope),
        ))
        assertFalse(restored.matchesCoordinates(CloudConfiguration(
            serverURL = "https://cloud.example",
            spaceID = "00000000-0000-4000-8000-000000000002",
        )))
        assertFalse(restored.matches(
            configuration,
            HttpSyncClient.RecoveryEnvelopeState(
                7,
                envelope.copy(version = 4, ciphertext = byteArrayOf(4, 5, 6)),
            ),
        ))
        assertEquals(null, RecoveryKitVerification.fromJSON(stored.toJSON().replace(
            "\"schemaVersion\":2",
            "\"schemaVersion\":1",
        )))
        assertEquals(null, RecoveryKitVerification.fromJSON("true"))
    }

    @Test
    fun legacyPositiveRecoveryVerificationMigratesToUnconfirmed() {
        val kit = LibraryKeyBootstrap.RecoveryKit(
            serverURL = "https://cloud.example",
            spaceID = "00000000-0000-4000-8000-000000000001",
            keyEpoch = 7,
            secret = ByteArray(32) { it.toByte() },
        )
        val envelope = HttpSyncClient.RecoveryEnvelopeRecord(
            version = 3,
            keyEpoch = 7,
            algorithm = LibraryKeyBootstrap.RECOVERY_ALGORITHM,
            ciphertext = byteArrayOf(1, 2, 3),
        )
        val oldRecord = RecoveryKitVerification.fromRecoveryKit(kit, envelope).toJSON()
        val migrated = RecoveryKitVerificationState.fromJSON(oldRecord)

        assertEquals(RecoveryKitStatus.STATUS_UNCONFIRMED, migrated?.status)
        assertEquals(
            RecoveryKitStatus.STATUS_UNCONFIRMED,
            RecoveryKitVerificationState(
                RecoveryKitStatus.VERIFIED_CURRENT,
                migrated?.verification,
            ).loadedForDisplay().status,
        )
    }

    @Test
    fun knownReplacementSurvivesSerialization() {
        val migrated = requireNotNull(RecoveryKitVerificationState.fromJSON(
            RecoveryKitVerification(
                serverURL = "https://cloud.example",
                spaceID = "00000000-0000-4000-8000-000000000001",
                keyEpoch = 7,
                envelopeVersion = 3,
                envelopeFingerprint = "a".repeat(64),
                kitFingerprint = "b".repeat(64),
            ).toJSON(),
        ))
        val replaced = migrated.copy(status = RecoveryKitStatus.KNOWN_REPLACED)

        assertEquals(replaced, RecoveryKitVerificationState.fromJSON(replaced.toJSON()))
    }

    @Test
    fun unfinishedRecoveryReplacementBlocksDisconnectAcrossBothDurableStages() {
        assertTrue(disconnectBlockedForRecovery(CloudKeyStatus.RECOVERY_AUTH_REQUIRED))
        assertTrue(disconnectBlockedForRecovery(CloudKeyStatus.RECOVERY_KIT_LOCKED))
        assertFalse(disconnectBlockedForRecovery(CloudKeyStatus.READY))
        assertTrue(disconnectBlockedForRecovery(RecoveryKitStatus.REPLACEMENT_IN_PROGRESS))
        assertTrue(disconnectBlockedForRecovery(RecoveryKitStatus.KNOWN_REPLACED))
        assertFalse(disconnectBlockedForRecovery(RecoveryKitStatus.STATUS_UNCONFIRMED))
    }

    @Test
    fun ambiguousLibrariesRequireAnExplicitChoiceInsteadOfRepeatingOAuth() {
        val first = HttpSyncClient.SpaceCandidate(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000010",
            "owner",
            "membership-a-000000000000000000000",
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
    fun readerLibrariesAreNeverSelectedAsWritableStorage() {
        val reader = HttpSyncClient.SpaceCandidate(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000010",
            "reader",
            "membership-a-000000000000000000000",
        )
        val writer = reader.copy(
            spaceID = "00000000-0000-4000-8000-000000000002",
            role = "writer",
        )

        assertEquals(null, automaticPersonalSpace(listOf(reader), reader.spaceID))
        assertEquals(
            writer.spaceID,
            automaticPersonalSpace(listOf(reader, writer), reader.spaceID)?.spaceID,
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

    @Test
    fun ownerAndWriterRequireAnExplicitInitialLibraryChoice() {
        val owner = HttpSyncClient.SpaceCandidate(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000010",
            "owner",
            "membership-a-000000000000000000000",
        )
        val writer = owner.copy(
            spaceID = "00000000-0000-4000-8000-000000000002",
            role = "writer",
            scopeBinding = "membership-b-000000000000000000000",
        )

        assertEquals(null, automaticPersonalSpace(listOf(owner, writer), null))
    }

    @Test
    fun stepUpRequiresTheExactExistingMembership() {
        val expected = CloudStepUpBinding(
            serverURL = "https://cloud.example",
            serverInstanceID = "00000000-0000-4000-8000-000000000010",
            spaceID = "00000000-0000-4000-8000-000000000001",
            scopeBinding = "membership-a-000000000000000000000",
        )
        val sameMembership = HttpSyncClient.SpaceResolution(
            spaceID = expected.spaceID,
            serverInstanceID = expected.serverInstanceID,
            role = "owner",
            scopeBinding = expected.scopeBinding,
        )

        assertTrue(expected.matches("https://cloud.example", sameMembership))
        assertFalse(expected.matches(
            "https://cloud.example",
            sameMembership.copy(scopeBinding = "membership-b-000000000000000000000"),
        ))
        assertFalse(expected.matches(
            "https://cloud.example",
            sameMembership.copy(role = "reader"),
        ))
    }

    @Test
    fun interruptedPostAuthorizationBootstrapIsDurableAndExact() {
        val pending = PendingPostAuthorizationBootstrap(
            serverURL = "https://cloud.example",
            serverInstanceID = "00000000-0000-4000-8000-000000000010",
            spaceID = "00000000-0000-4000-8000-000000000001",
            scopeBinding = "membership-a-000000000000000000000",
            operation = CloudPostAuthorizationOperation.CHANGE_LIBRARY,
        )

        assertEquals(pending, PendingPostAuthorizationBootstrap.fromJSON(pending.toJSON()))
        assertTrue(pending.matches(CloudConfiguration(
            serverURL = pending.serverURL,
            serverInstanceID = pending.serverInstanceID,
            spaceID = pending.spaceID,
        )))
        assertFalse(pending.matches(HttpSyncClient.SpaceResolution(
            spaceID = pending.spaceID,
            serverInstanceID = pending.serverInstanceID,
            role = "writer",
            scopeBinding = "membership-b-000000000000000000000",
        )))
    }

    @Test
    fun cloudCleanupFailureKeepsLocalSnippetsVisibleAndOffersRetry() {
        val snippet = SnippetItem(
            id = "00000000-0000-4000-8000-000000000099",
            name = "Local",
            keyword = "local",
            content = "kept on device",
            tags = emptyList(),
            isEnabled = true,
            isPinned = false,
        )
        val state = cloudStartupFailureState(
            LibraryState(isBusy = true),
            listOf(snippet),
            "credential_revocation_failed",
        )
        val error = cloudErrorPresentation(requireNotNull(state.errorCode))

        assertEquals(listOf(snippet), state.snippets)
        assertEquals(CloudSetupStage.NEEDS_ATTENTION, state.setupStage)
        assertEquals(CloudErrorAction.RETRY_CLEANUP, error.action)
        assertEquals("Retry cleanup", error.actionTitle)
        assertTrue(disconnectBlockedForRecovery(CloudKeyStatus.SETUP_INTERRUPTED))
    }
}
