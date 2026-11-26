package com.khm.snippets.core.state

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The halt vocabulary, its compare-and-swap through `state.json`, stickiness, and the
 * recovery claim (`SyncEngine.recoveryAction`, `updatePersistedHalt`,
 * `SyncAccountBindingTests` claim and takeover cases, at the state layer).
 */
class HaltTest {

    private val fresh = { SyncState(TEST_DEVICE) }

    private fun halt(reason: HaltReason, at: Double = 790_000_000.0, context: RecoveryContext? = null) =
        Halt(reason, HaltDetail.of("detail_${reason.rawValue}"), at, context)

    private val deletion = halt(HaltReason.MASS_DELETION, context = RecoveryContext.MassDeletion(117, 49, "a".repeat(64)))

    private fun StateSandbox.file() = SyncStateFile(locations)

    // Vocabulary

    @Test
    fun everyReasonHasItsOwnRawValueAndAction() {
        val expected = mapOf(
            HaltReason.MASS_DELETION to ("massDeletion" to SyncRecoveryAction.APPLY_REMOTE_DELETIONS),
            HaltReason.BACKEND_REFUSED to ("backendRefused" to SyncRecoveryAction.RETRY_SYNC),
            HaltReason.ACCOUNT_CHANGED to ("accountChanged" to SyncRecoveryAction.USE_CURRENT_ACCOUNT),
            HaltReason.CHECKPOINT_UNREADABLE to ("checkpointUnreadable" to SyncRecoveryAction.REPAIR_CHECKPOINT),
            HaltReason.REMOTE_DATA_RESET to ("remoteDataReset" to SyncRecoveryAction.RESTORE_CLOUD_FROM_THIS_DEVICE),
            HaltReason.MANIFEST_INTEGRITY_FAILED to ("manifestIntegrityFailed" to SyncRecoveryAction.CHECK_AGAIN),
            HaltReason.LOCAL_LIBRARY_QUARANTINED to ("localLibraryQuarantined" to SyncRecoveryAction.CHECK_AGAIN),
            HaltReason.VAULT_UNREADABLE to ("vaultUnreadable" to SyncRecoveryAction.CHECK_AGAIN),
            HaltReason.SCHEMA_TOO_NEW to ("schemaTooNew" to null),
        )
        assertEquals(HaltReason.entries.toSet(), expected.keys)
        for ((reason, pair) in expected) {
            assertEquals(pair.first, reason.rawValue)
            assertSame(reason, HaltReason.fromRawValue(pair.first))
            assertEquals(pair.second, reason.recoveryAction)
        }
        assertNull(HaltReason.fromRawValue("MassDeletion"), "raw values are exact")
        assertTrue(SyncRecoveryAction.APPLY_REMOTE_DELETIONS.isDestructiveConfirmation)
        assertEquals(
            setOf(
                SyncRecoveryAction.APPLY_REMOTE_DELETIONS, SyncRecoveryAction.USE_CURRENT_ACCOUNT,
                SyncRecoveryAction.RESTORE_CLOUD_FROM_THIS_DEVICE, SyncRecoveryAction.RECLAIM_RECOVERY,
            ),
            SyncRecoveryAction.entries.filter { it.requiresConfirmation }.toSet(),
        )
    }

    @Test
    fun aMassDeletionWithoutItsContextOnlyOffersARefresh() {
        val legacy = halt(HaltReason.MASS_DELETION)
        assertEquals(SyncRecoveryAction.REFRESH_DELETION_REVIEW, legacy.recoveryAction { error("no claim") })
        assertEquals(SyncRecoveryAction.APPLY_REMOTE_DELETIONS, deletion.recoveryAction { error("no claim") })
    }

    @Test
    fun haltDetailIsBoundedTypedData() {
        assertFailsWith<IllegalArgumentException> { HaltDetail.of("a sentence, not a code") }
        assertFailsWith<IllegalArgumentException> { HaltDetail.of("") }
        assertFailsWith<IllegalArgumentException> { HaltDetail.of("x".repeat(129)) }
        assertFailsWith<IllegalArgumentException> { HaltDetail.of("c", (0..16).associate { "k$it" to "v" }) }
        val long = HaltDetail.of("c", mapOf("v" to "x".repeat(2_000)))
        assertEquals(HaltDetail.MAXIMUM_ARGUMENT_CHARACTERS, long.arguments.getValue("v").length)
        val surrogate = HaltDetail.of("c", mapOf("v" to "a\uD800b"))
        assertEquals("a�b", surrogate.arguments.getValue("v"))
        val state = SyncState(TEST_DEVICE, halt = Halt(HaltReason.BACKEND_REFUSED, long, 1.5))
        assertEquals(state, SyncStateCodec.decode(SyncStateCodec.encode(state)))
    }

    @Test
    fun aHaltTimeMustBeFiniteAndComparesAsADouble() {
        assertFailsWith<IllegalArgumentException> { Halt(HaltReason.VAULT_UNREADABLE, HaltDetail.of("x"), Double.NaN) }
        assertFailsWith<IllegalArgumentException> { Halt(HaltReason.VAULT_UNREADABLE, HaltDetail.of("x"), Double.POSITIVE_INFINITY) }
        assertEquals(halt(HaltReason.VAULT_UNREADABLE, at = 0.0), halt(HaltReason.VAULT_UNREADABLE, at = -0.0))
        assertNotEquals(halt(HaltReason.VAULT_UNREADABLE, at = 1.0), halt(HaltReason.VAULT_UNREADABLE, at = 1.0000000000000002))
    }

    // Compare-and-swap

    @Test
    fun updateHaltIsACompareAndSwapOnTheWholeHalt() = sandbox("cas") { s ->
        val file = s.file()
        val first = halt(HaltReason.REMOTE_DATA_RESET)
        assertEquals(HaltUpdateResult.Written(first), file.updateHalt(1_000, first, expecting = null, fresh))
        assertEquals(first, file.load().loadedState?.halt)
        assertEquals(TEST_DEVICE, file.load().loadedState?.deviceId, "a first halt is written into the caller's identity")

        // Same value again: nothing to write, still the durable one.
        assertEquals(HaltUpdateResult.Written(first), file.updateHalt(1_000, first, expecting = first, fresh))

        // A stale reviewer that expects nothing sees the newer stop.
        val other = halt(HaltReason.ACCOUNT_CHANGED)
        assertEquals(HaltUpdateResult.Superseded(first), file.updateHalt(1_000, other, expecting = null, fresh))
        // One that expects a different halt sees it too, even with a time that differs by a fraction.
        assertEquals(
            HaltUpdateResult.Superseded(first),
            file.updateHalt(1_000, null, expecting = first.copy(at = first.at + 0.5), fresh),
        )
        assertEquals(first, file.load().loadedState?.halt)

        // Clearing the exact halt works; clearing it again is harmless.
        assertEquals(HaltUpdateResult.Written(null), file.updateHalt(1_000, null, expecting = first, fresh))
        assertNull(file.load().loadedState?.halt)
        assertEquals(HaltUpdateResult.Written(null), file.updateHalt(1_000, null, expecting = first, fresh))

        // A stale reviewer must not recreate a stop a peer already completed.
        assertSame(HaltUpdateResult.Cleared, file.updateHalt(1_000, first.claimedBy(RecoveryClaim(testId(1), testId(2), testId(3))), expecting = first, fresh))
        assertNull(file.load().loadedState?.halt)
    }

    @Test
    fun anUnsupportedStateFileIsNeverWrittenByAHalt() = sandbox("cas-unsupported") { s ->
        java.nio.file.Files.write(s.stateFile.toPath(), utf8("""{"schemaVersion":6}"""))
        assertEquals(HaltUpdateResult.Unsupported(6), s.file().updateHalt(1_000, deletion, null, fresh))
        val held = s.locations.guard.acquire(1_000)!!
        try {
            assertEquals(HaltUpdateResult.Unsupported(6), s.file().replaceHaltWhileHolding(held, deletion, fresh))
        } finally {
            held.close()
        }
        assertEquals("""{"schemaVersion":6}""", String(java.nio.file.Files.readAllBytes(s.stateFile.toPath())))
    }

    @Test
    fun aHaltThatCannotBeWrittenIsReportedAndNotPublished() = sandbox("cas-failed") { s ->
        val io = FaultInjectingIo().apply { fail = { _, _ -> true } }
        val result = SyncStateFile(s.locations, io).updateHalt(1_000, deletion, null, fresh)
        assertEquals(HaltUpdateResult.Failed(HaltUpdateResult.Failed.Reason.WRITE_FAILED), result)
        assertTrue(!s.stateFile.exists())
    }

    // Stickiness

    @Test
    fun aHaltSurvivesReloadAndEveryUnrelatedWriter() = sandbox("sticky") { s ->
        val file = s.file()
        file.loadOrCreate(1_000) { SyncState(TEST_DEVICE) }
        file.updateHalt(1_000, deletion, null, fresh)

        // Unrelated writers of the same document.
        file.update(1_000, makeFresh = null) { it.copy(generation = it.generation + 5) }
        file.update(1_000, makeFresh = null) { it.copy(promoting = testId(9)) }
        file.update(1_000, makeFresh = null) { it.copy(promoting = null, demoting = null) }
        file.loadOrCreate(1_000)

        val reloaded = SyncStateFile(s.locations).load()
        assertEquals(deletion, reloaded.loadedState?.halt)
        assertEquals(5L, reloaded.loadedState?.generation)
    }

    @Test
    fun noOrdinaryUpdateMayChangeAHalt() = sandbox("sticky-update") { s ->
        val file = s.file()
        file.updateHalt(1_000, deletion, null, fresh)
        assertFailsWith<IllegalArgumentException> { file.update(1_000, makeFresh = null) { it.copy(halt = null) } }
        assertFailsWith<IllegalArgumentException> {
            file.update(1_000, makeFresh = null) { it.copy(halt = deletion.copy(at = 0.0)) }
        }
        assertEquals(deletion, file.load().loadedState?.halt)
        // And the guard was released after the refusal.
        assertTrue(!s.locations.guard.isHeld)
    }

    @Test
    fun onlyTheExactReviewedHaltCanBeCleared() = sandbox("sticky-clear") { s ->
        val file = s.file()
        file.updateHalt(1_000, deletion, null, fresh)
        val impostors = listOf(
            null,
            deletion.copy(at = deletion.at + 1),
            deletion.copy(detail = HaltDetail.of("other")),
            deletion.copy(recoveryContext = RecoveryContext.MassDeletion(117, 48, "a".repeat(64))),
            deletion.copy(recoveryContext = null),
            deletion.copy(reason = HaltReason.ACCOUNT_CHANGED),
            deletion.claimedBy(RecoveryClaim(testId(1), testId(2), testId(3))),
        )
        for (impostor in impostors) {
            assertEquals(HaltUpdateResult.Superseded(deletion), file.updateHalt(1_000, null, impostor, fresh), "$impostor")
        }
        assertEquals(deletion, file.load().loadedState?.halt)
        assertEquals(HaltUpdateResult.Written(null), file.updateHalt(1_000, null, deletion, fresh))
    }

    // Recovery claims

    @Test
    fun claimDispositionDistinguishesOwnerLivePeerClosedPeerAndAnotherLaunch() {
        val launch = UUID.randomUUID()
        val owners = RecoveryClaimOwners(launch)
        val me = owners.register()
        val peer = owners.register()
        val mine = owners.newClaim(me)
        val peers = owners.newClaim(peer)

        assertEquals(RecoveryClaimDisposition.OWNED_BY_THIS_ENGINE, owners.disposition(mine, me))
        assertEquals(RecoveryClaimDisposition.ACTIVE_IN_THIS_LAUNCH, owners.disposition(peers, me))
        owners.deregister(peer)
        assertEquals(RecoveryClaimDisposition.ABANDONED_IN_THIS_LAUNCH, owners.disposition(peers, me))
        assertEquals(RecoveryClaimDisposition.ABANDONED_IN_THIS_LAUNCH, owners.disposition(peers, me), "asking twice gives the same answer")

        // The same pid in a new launch is a new launch id: nothing of the old one is live.
        val nextLaunch = RecoveryClaimOwners(UUID.randomUUID())
        val successor = nextLaunch.register(me)
        assertEquals(RecoveryClaimDisposition.ABANDONED_BY_ANOTHER_LAUNCH, nextLaunch.disposition(mine, successor))
        assertFailsWith<IllegalArgumentException> { owners.newClaim(peer) }
    }

    @Test
    fun theOfferedActionFollowsTheClaim() {
        val owners = RecoveryClaimOwners(UUID.randomUUID())
        val me = owners.register()
        val peer = owners.register()
        val reset = halt(HaltReason.REMOTE_DATA_RESET)

        assertEquals(SyncRecoveryAction.RESTORE_CLOUD_FROM_THIS_DEVICE, reset.recoveryAction { owners.disposition(it, me) })
        val claimedByPeer = reset.claimedBy(owners.newClaim(peer))
        assertNull(claimedByPeer.recoveryAction { owners.disposition(it, me) }, "a live peer is working: offer nothing")
        owners.deregister(peer)
        assertEquals(
            SyncRecoveryAction.RESTORE_CLOUD_FROM_THIS_DEVICE,
            claimedByPeer.recoveryAction { owners.disposition(it, me) },
        )
        val foreign = reset.claimedBy(RecoveryClaim(UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID()))
        assertEquals(SyncRecoveryAction.RECLAIM_RECOVERY, foreign.recoveryAction { owners.disposition(it, me) })
        assertEquals(SyncRecoveryAction.RECLAIM_RECOVERY, deletion.claimedBy(foreign.recoveryClaim!!).recoveryAction { owners.disposition(it, me) })
        assertEquals(reset, foreign.withoutClaim())
    }

    /** `overlappingRemoteResetReviewsClaimOneDurableAttempt`, at the state layer. */
    @Test
    fun overlappingReviewersClaimOneDurableAttempt() = sandbox("claim-overlap") { s ->
        val owners = RecoveryClaimOwners(UUID.randomUUID())
        val first = owners.register()
        val second = owners.register()
        val reset = halt(HaltReason.REMOTE_DATA_RESET)
        s.file().updateHalt(1_000, reset, null, fresh)

        // Both panes loaded the same unclaimed halt.
        val firstClaim = reset.claimedBy(owners.newClaim(first))
        val secondClaim = reset.claimedBy(owners.newClaim(second))
        assertEquals(HaltUpdateResult.Written(firstClaim), s.file().updateHalt(1_000, firstClaim, reset, fresh))
        val lost = s.file().updateHalt(1_000, secondClaim, reset, fresh)
        assertEquals(HaltUpdateResult.Superseded(firstClaim), lost)
        assertNull((lost as HaltUpdateResult.Superseded).newer.recoveryAction { owners.disposition(it, second) })

        // The owner completes and clears exactly its claimed halt; the stale pane cannot recreate it.
        assertEquals(HaltUpdateResult.Written(null), s.file().updateHalt(1_000, null, firstClaim, fresh))
        assertSame(HaltUpdateResult.Cleared, s.file().updateHalt(1_000, secondClaim, reset, fresh))
        assertNull(s.file().load().loadedState?.halt)
    }

    /** `unknownRecoveryClaimRequiresExplicitTwoStepTakeover`, at the state layer. */
    @Test
    fun aClaimFromAnotherLaunchNeedsAnExplicitTwoStepTakeover() = sandbox("claim-takeover") { s ->
        val previousLaunch = RecoveryClaimOwners(UUID.randomUUID())
        val oldEngine = previousLaunch.register()
        val reset = halt(HaltReason.REMOTE_DATA_RESET)
        val abandoned = reset.claimedBy(previousLaunch.newClaim(oldEngine))
        s.file().updateHalt(1_000, abandoned, null, fresh)

        // A relaunch: the same process id means nothing, the launch id does.
        val launch = RecoveryClaimOwners(UUID.randomUUID())
        val engine = launch.register()
        val loaded = s.file().load().loadedState!!.halt!!
        assertEquals(SyncRecoveryAction.RECLAIM_RECOVERY, loaded.recoveryAction { launch.disposition(it, engine) })

        // Step one clears only the claim, by compare-and-swap.
        assertEquals(HaltUpdateResult.Written(reset), s.file().updateHalt(1_000, loaded.withoutClaim(), loaded, fresh))
        val unclaimed = s.file().load().loadedState!!.halt!!
        assertEquals(reset, unclaimed)
        // Step two is the original review again; takeover alone executed nothing.
        assertEquals(SyncRecoveryAction.RESTORE_CLOUD_FROM_THIS_DEVICE, unclaimed.recoveryAction { launch.disposition(it, engine) })
        val mine = unclaimed.claimedBy(launch.newClaim(engine))
        assertEquals(HaltUpdateResult.Written(mine), s.file().updateHalt(1_000, mine, unclaimed, fresh))
        assertEquals(RecoveryClaimDisposition.OWNED_BY_THIS_ENGINE, launch.disposition(mine.recoveryClaim!!, engine))
    }

    @Test
    fun aClaimRoundTripsExactly() {
        val claimed = deletion.claimedBy(RecoveryClaim(testId(7), testId(8), testId(9)))
        val state = SyncState(TEST_DEVICE, halt = claimed)
        val decoded = SyncStateCodec.decode(SyncStateCodec.encode(state))
        assertEquals(claimed, decoded.halt)
        assertIs<RecoveryContext.MassDeletion>(decoded.halt!!.recoveryContext)
    }
}
