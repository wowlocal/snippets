package com.khm.snippets.core.sync.base

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.state.TEST_DEVICE
import com.khm.snippets.core.state.testEnvelope
import com.khm.snippets.core.state.testId
import com.khm.snippets.core.state.testTombstone
import com.khm.snippets.core.state.utf8
import com.khm.snippets.core.sync.transport.SyncAccountIdentity
import com.khm.snippets.core.sync.transport.SyncCursor
import com.khm.snippets.core.sync.transport.SyncCursorKind
import com.khm.snippets.core.sync.transport.SyncDatasetIdentity
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.sync.transport.SyncRejection
import com.khm.snippets.core.sync.transport.SyncSubmitOutcome
import com.khm.snippets.core.sync.transport.SyncSubmitResult
import com.khm.snippets.core.wire.SyncEnvelope
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** `SyncBase` as a value: every engine mutation is a pure function returning a new base. */
class SyncBaseTest {

    private val id = testId(1)
    private val accountA = SyncAccountIdentity(utf8("account-a"))
    private val accountB = SyncAccountIdentity(utf8("account-b"))
    private val datasetA = SyncDatasetIdentity(utf8("dataset-a"))

    private fun version(text: String) = SyncRecordVersion(utf8(text))

    /** `confirmedMutationAtomicallyReplacesOrRemovesItsVersion` (SyncRecordCASTests). */
    @Test
    fun confirmedMutationAtomicallyReplacesOrRemovesItsVersion() {
        val first = version("system-fields-v1")
        val second = version("system-fields-v2")
        val confirmed = testEnvelope(1, "confirmed", 100)
        val edited = testEnvelope(1, "edited", 200)
        var base = SyncBase()

        base = base.recordingConfirmed(confirmed, first)
        assertEquals(confirmed, base.envelope(id))
        assertEquals(first, base.recordVersion(id))

        base = base.recording(edited)
        assertEquals(edited, base.envelope(id))
        assertEquals(first, base.recordVersion(id), "ordinary envelope replacement must not silently discard CAS ancestry")

        base = base.recordingConfirmed(confirmed, second)
        assertEquals(second, base.recordVersion(id))

        base = base.recordingConfirmed(edited, null)
        assertEquals(edited, base.envelope(id))
        assertNull(base.recordVersion(id))

        base = base.recordingConfirmed(confirmed, first).removingRecordVersion(id)
        assertEquals(confirmed, base.envelope(id))
        assertNull(base.recordVersion(id))
    }

    @Test
    fun everyOperationLeavesTheOriginalAsItWas() {
        val original = SyncBase(
            envelopes = mapOf(id to testEnvelope(1)),
            recordVersions = mapOf(id to version("v1")),
            cursor = SyncCursor("c1"),
            accountIdentity = accountA,
        )
        val snapshot = SyncBase(
            envelopes = mapOf(id to testEnvelope(1)),
            recordVersions = mapOf(id to version("v1")),
            cursor = SyncCursor("c1"),
            accountIdentity = accountA,
        )
        val results = listOf(
            original.recording(testEnvelope(2)),
            original.recordingConfirmed(testEnvelope(1, "x"), null),
            original.removingRecordVersion(id),
            original.retainingRecordVersions(emptySet()),
            original.adoptingCursor(null, null),
            original.establishingJournal(),
            original.binding(accountB, datasetA),
            original.requiringTransportFullResync(),
            original.stagingTransportRekey(),
            original.reviewingRecoveredPrimary(emptyMap(), testId(99)),
            original.mappingEnvelopes { null },
        )
        for (result in results) assertNotEquals(original, result)
        assertEquals(snapshot, original)
        // The exposed maps cannot be changed either.
        assertFailsWith<UnsupportedOperationException> { (original.recordVersions as MutableMap<UUID, SyncRecordVersion>).clear() }
    }

    @Test
    fun aCursorAndItsKindTravelTogether() {
        val adopted = SyncBase().adoptingCursor(SyncCursor("91"), null)
        assertEquals(SyncCursorKind.LEGACY, adopted.cursorKind)
        val forgotten = adopted.adoptingCursor(null, SyncCursorKind.LEGACY)
        assertNull(forgotten.cursor)
        assertNull(forgotten.cursorKind)
        assertNull(SyncBase(cursorKind = SyncCursorKind.LEGACY).cursorKind)
    }

    @Test
    fun theRecoveryFenceCarriesItsModeAndReviewId() {
        val incomplete = SyncBase(requiresNonDestructiveLibraryMerge = true)
        assertEquals(SyncBase.NonDestructiveMergeMode.INCOMPLETE_PRIMARY, incomplete.nonDestructiveMergeMode)
        assertNull(incomplete.nonDestructiveReviewId)
        assertNull(incomplete.nonDestructiveReviewFingerprint())

        val reviewed = SyncBase(
            requiresNonDestructiveLibraryMerge = true,
            nonDestructiveMergeMode = SyncBase.NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT,
        )
        assertNotNull(reviewed.nonDestructiveReviewId, "a reviewed fence always has a review id")
        assertTrue(reviewed.isReviewedRecovery)

        val lowered = reviewed.copy(requiresNonDestructiveLibraryMerge = false)
        assertNull(lowered.nonDestructiveMergeMode)
        assertNull(lowered.nonDestructiveReviewId)
        assertFailsWith<IllegalArgumentException> { SyncBase(preRecoveryConfirmedEnvelopes = emptyMap()) }
        assertFailsWith<IllegalArgumentException> { SyncBase(envelopes = mapOf(testId(2) to testEnvelope(1))) }
    }

    // pendingChanges

    @Test
    fun pendingChangesComparesByHashAndOrdersByUppercaseId() {
        val unchanged = testEnvelope(1)
        val changed = testEnvelope(2)
        val base = SyncBase(envelopes = mapOf(testId(1) to unchanged, testId(2) to changed))
        val editedTwo = testEnvelope(2, "renamed")
        val created = testEnvelope(0xABCDEF)
        val pending = base.pendingChanges(
            mapOf(testId(1) to testEnvelope(1), testId(2) to editedTwo, testId(0xABCDEF) to created),
        )
        assertEquals(listOf(testId(2), testId(0xABCDEF)), pending.map { it.id })
        assertEquals(editedTwo, pending[0])
        // Re-saving byte-identical content is not a change, however often it happens.
        assertEquals(emptyList(), base.pendingChanges(mapOf(testId(1) to testEnvelope(1), testId(2) to testEnvelope(2))))
    }

    @Test
    fun aLiveBaseRecordMissingLocallyBecomesItsOwnTombstone() {
        val live = testEnvelope(1).withExtension("futureMember", JsonValue.of(true))
        val pending = SyncBase(envelopes = mapOf(id to live)).pendingChanges(emptyMap())
        assertEquals(1, pending.size)
        val tombstone = pending.single()
        assertTrue(tombstone.deleted)
        assertEquals(live.hlc, tombstone.hlc)
        assertEquals(live.origin, tombstone.origin)
        assertNull(tombstone.fields)
        assertEquals(emptyMap(), tombstone.x, "a tombstone carries no extension data")
    }

    @Test
    fun aBaseTombstoneIsKeptAndYieldsNothing() {
        val base = SyncBase(envelopes = mapOf(id to testTombstone(1)))
        assertEquals(emptyList(), base.pendingChanges(emptyMap()))
        // Kept for good: nothing in the base drops it.
        val advanced = base.adoptingCursor(SyncCursor("2"), null).establishingJournal().binding(accountA, datasetA)
        assertEquals(testTombstone(1), advanced.envelope(id))
        // A recreated record over a tombstone is pending.
        assertEquals(listOf(id), base.pendingChanges(mapOf(id to testEnvelope(1))).map { it.id })
    }

    @Test
    fun aRecordHoldingAnUnresolvedContentConflictIsNotTombstoned() {
        val holding = testEnvelope(1).withExtension("contentConflict.v1.${"b".repeat(64)}", JsonValue.obj("copyID" to JsonValue.of("x")))
        val base = SyncBase(envelopes = mapOf(id to holding))
        assertEquals(emptyList(), base.pendingChanges(emptyMap()), "the only copy of a losing body must not be deleted")
        assertEquals(1, base.pendingChanges(emptyMap()) { false }.size)
    }

    // Folding a submission

    @Test
    fun acceptedSubmissionsAreMatchedByIdAndForeignOutcomesIgnored() {
        val one = testEnvelope(1)
        val two = testEnvelope(2)
        val offered = mapOf(testId(1) to one, testId(2) to two)
        val results = listOf(
            SyncSubmitResult(testId(2), SyncSubmitOutcome.Accepted("rev2", version("g2"))),
            SyncSubmitResult(testId(1), SyncSubmitOutcome.Rejected(SyncRejection.Conflict(null))),
            SyncSubmitResult(testId(77), SyncSubmitOutcome.Accepted("rev77", version("g77"))),
            SyncSubmitResult(testId(2), SyncSubmitOutcome.Accepted("rev2", version("g2b"))),
        )
        val base = SyncBase(recordVersions = mapOf(testId(1) to version("g1")))
        val folded = base.foldingAccepted(offered, results)
        assertEquals(setOf(testId(2)), folded.acceptedIds)
        assertEquals(two, folded.base.envelope(testId(2)))
        assertEquals(version("g2b"), folded.base.recordVersion(testId(2)), "the backend's last generation wins")
        assertNull(folded.base.envelope(testId(1)), "a rejection records nothing")
        assertEquals(version("g1"), folded.base.recordVersion(testId(1)))
        assertNull(folded.base.envelope(testId(77)), "an outcome for an id that was not offered is not trusted")
        assertSame(base, base.foldingAccepted(offered, emptyList()).base)
    }

    // Binding and checkpoint facts

    @Test
    fun bindingReplacesExactlyTheScope() {
        val bound = SyncBase(cursor = SyncCursor("c")).binding(accountA, datasetA)
        assertEquals(accountA, bound.accountIdentity)
        assertEquals(datasetA, bound.datasetIdentity)
        assertEquals(SyncCursor("c"), bound.cursor)
        val unbound = bound.binding(null, null)
        assertNull(unbound.accountIdentity)
        assertNull(unbound.datasetIdentity)
    }

    @Test
    fun checkpointFactsAreCursorEnvelopesOrVersions() {
        assertTrue(!SyncBase().holdsCheckpointFacts)
        assertTrue(!SyncBase(journalEstablished = true, accountIdentity = accountA).holdsCheckpointFacts)
        assertTrue(SyncBase(cursor = SyncCursor("")).holdsCheckpointFacts)
        assertTrue(SyncBase(envelopes = mapOf(id to testTombstone(1))).holdsCheckpointFacts)
        assertTrue(SyncBase(recordVersions = mapOf(id to version("v"))).holdsCheckpointFacts)
    }

    @Test
    fun aTransportResyncRequestIsRaisedAndCompleted() {
        val requested = SyncBase().requiringTransportFullResync()
        assertTrue(requested.requiresTransportFullResync)
        assertTrue(!requested.completingTransportFullResync().requiresTransportFullResync)
        assertSame(requested, requested.requiringTransportFullResync(true))
    }

    // Recovery transitions

    @Test
    fun aReviewedResetStartsFromNothingBoundToThePreflightScope() {
        val reset = SyncBase.afterReviewedReset(accountA, datasetA)
        assertEquals(SyncBase(journalEstablished = true, accountIdentity = accountA, datasetIdentity = datasetA), reset)
        assertTrue(!reset.holdsCheckpointFacts)
    }

    @Test
    fun reviewingARecoveredPrimaryKeepsOnlyScopeAndJournalMarker() {
        val prior = SyncBase(
            envelopes = mapOf(testId(5) to testEnvelope(5)),
            recordVersions = mapOf(testId(5) to version("v5")),
            cursor = SyncCursor("old"),
            journalEstablished = true,
            accountIdentity = accountA,
            datasetIdentity = datasetA,
            requiresTransportFullResync = true,
        )
        val reviewId = testId(42)
        val reviewed = prior.reviewingRecoveredPrimary(mapOf(id to testEnvelope(1)), reviewId)
        assertEquals(mapOf(id to testEnvelope(1)), reviewed.envelopes)
        assertEquals(emptyMap(), reviewed.recordVersions, "a local witness is not backend confirmation")
        assertNull(reviewed.cursor)
        assertTrue(reviewed.journalEstablished)
        assertEquals(accountA, reviewed.accountIdentity)
        assertEquals(datasetA, reviewed.datasetIdentity)
        assertTrue(!reviewed.requiresTransportFullResync)
        assertEquals(SyncBase.NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT, reviewed.nonDestructiveMergeMode)
        assertEquals(reviewId, reviewed.nonDestructiveReviewId)
        assertEquals(reviewId, reviewed.resumableReviewId)
        assertNull(reviewed.preRecoveryConfirmedEnvelopes, "old absences are not trusted after a primary quarantine")
        assertNull(prior.resumableReviewId)
    }

    @Test
    fun repairKeepsAnActiveReviewAndOtherwiseRetainsTheOldAncestor() {
        val current = mapOf(id to testEnvelope(1, "now"))
        val prior = SyncBase(
            envelopes = mapOf(testId(5) to testEnvelope(5)),
            recordVersions = mapOf(testId(5) to version("v5")),
            cursor = SyncCursor("old"),
            accountIdentity = accountA,
            datasetIdentity = datasetA,
        )
        val repaired = SyncBase.repairingCheckpoint(prior, current, testId(50))
        assertEquals(current, repaired.envelopes)
        assertEquals(prior.envelopes, repaired.preRecoveryConfirmedEnvelopes)
        assertEquals(emptyMap(), repaired.recordVersions)
        assertNull(repaired.cursor)
        assertTrue(repaired.journalEstablished)
        assertEquals(accountA, repaired.accountIdentity)
        assertEquals(testId(50), repaired.nonDestructiveReviewId)

        // A crash after this base and before its journal: the same review continues.
        val again = SyncBase.repairingCheckpoint(repaired, mapOf(testId(2) to testEnvelope(2)), testId(51))
        assertEquals(repaired, again)

        // A prior unreviewed fence has no trustworthy ancestor of its own.
        val incomplete = SyncBase(envelopes = mapOf(testId(5) to testEnvelope(5)), requiresNonDestructiveLibraryMerge = true)
        assertNull(SyncBase.repairingCheckpoint(incomplete, current, testId(52)).preRecoveryConfirmedEnvelopes)
        // No readable prior at all.
        val unknown = SyncBase.repairingCheckpoint(null, current, testId(53))
        assertNull(unknown.preRecoveryConfirmedEnvelopes)
        assertNull(unknown.accountIdentity)
        // A known-empty ancestor stays distinct from an unknown one.
        assertEquals(emptyMap(), SyncBase.repairingCheckpoint(SyncBase(), current, testId(54)).preRecoveryConfirmedEnvelopes)
    }

    @Test
    fun aTransportRekeyDropsPayloadAndCursorButKeepsGenerations() {
        val prior = SyncBase(
            envelopes = mapOf(id to testEnvelope(1)),
            recordVersions = mapOf(id to version("v1"), testId(2) to version("v2")),
            cursor = SyncCursor("c"),
            accountIdentity = accountA,
            datasetIdentity = datasetA,
        )
        val staged = prior.stagingTransportRekey()
        assertEquals(emptyMap(), staged.envelopes)
        assertEquals(prior.recordVersions, staged.recordVersions, "a generation outlives its envelope during a rekey")
        assertNull(staged.cursor)
        assertTrue(staged.journalEstablished)
        assertTrue(staged.requiresTransportFullResync)
        assertEquals(accountA, staged.accountIdentity)

        val reviewed = SyncBase.repairingCheckpoint(prior, mapOf(id to testEnvelope(1)), testId(9))
        val stagedReview = reviewed.stagingTransportRekey()
        assertEquals(reviewed.envelopes, stagedReview.envelopes, "a recovery fence keeps its reviewed snapshot")
        assertTrue(!stagedReview.requiresTransportFullResync, "the fence already implies a full reset")
        assertEquals(reviewed.nonDestructiveReviewId, stagedReview.nonDestructiveReviewId)
        assertEquals(reviewed.preRecoveryConfirmedEnvelopes, stagedReview.preRecoveryConfirmedEnvelopes)
    }

    @Test
    fun retainingRecordVersionsDropsOrphanedGenerations() {
        val base = SyncBase(recordVersions = mapOf(testId(1) to version("a"), testId(2) to version("b")))
        assertEquals(setOf(testId(2)), base.retainingRecordVersions(setOf(testId(2), testId(3))).recordVersions.keys)
    }

    @Test
    fun mappingEnvelopesCannotChangeAnId() {
        val base = SyncBase(envelopes = mapOf(id to testEnvelope(1)))
        assertFailsWith<IllegalArgumentException> { base.mappingEnvelopes { testEnvelope(2) } }
        val tombstoned = base.mappingEnvelopes { it.tombstoned(it.hlc, it.origin) }
        assertTrue(tombstoned.envelope(id)!!.deleted)
    }

    // The review fingerprint

    @Test
    fun theReviewFingerprintBindsTheReviewIdAndBothSnapshots() {
        val snapshot = mapOf(id to testEnvelope(1))
        fun reviewed(reviewId: UUID, prior: Map<UUID, SyncEnvelope>?) = SyncBase(
            envelopes = snapshot,
            requiresNonDestructiveLibraryMerge = true,
            nonDestructiveMergeMode = SyncBase.NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT,
            preRecoveryConfirmedEnvelopes = prior,
            nonDestructiveReviewId = reviewId,
        )
        val first = reviewed(testId(10), null).nonDestructiveReviewFingerprint()!!
        assertEquals(64, first.length)
        assertEquals(first, reviewed(testId(10), null).nonDestructiveReviewFingerprint(), "stable")
        assertNotEquals(first, reviewed(testId(11), null).nonDestructiveReviewFingerprint(), "two reviews of identical bytes are two epochs")
        assertNotEquals(first, reviewed(testId(10), emptyMap()).nonDestructiveReviewFingerprint(), "known-empty is not unknown")
        val material = "review-id:${testId(10)}|reviewed:36:${testId(1)}64:${testEnvelope(1).envelopeHash()}|prior:unknown"
        assertEquals(SyncEnvelope.sha256Hex(utf8(material)), first)
    }

    @Test
    fun equalityIsByValue() {
        val one = SyncBase(envelopes = mapOf(id to testEnvelope(1)), recordVersions = mapOf(id to version("v")))
        val two = SyncBase(envelopes = mapOf(id to testEnvelope(1)), recordVersions = mapOf(id to SyncRecordVersion(utf8("v"))))
        assertEquals(one, two)
        assertEquals(one.hashCode(), two.hashCode())
        assertNotEquals(one, two.recording(testEnvelope(1, wallMs = 5)))
        assertTrue(TEST_DEVICE !in one.toString() && testId(1).toString() !in one.toString(), "toString names counts only")
        assertEquals(Hlc.of(1_001, 0, TEST_DEVICE), one.envelope(id)!!.hlc)
    }
}
