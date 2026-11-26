package com.khm.snippets.core.merge

import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.wire.SyncEnvelope
import org.junit.Test
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The "Deletion guard" suite of `Tests/Core/WireTests.swift` (all seven cases, Swift
 * names) and Rust `deletion_review_matches_exact_uppercase_uuid_fingerprint_and_changed_
 * small_batch`. L07 pins the boundaries against Swift as well (`SwiftMergeVectorsTest`).
 */
class DeletionSafetyTest {

    private fun id(index: Int): UUID = MergeFixtures.id(index)
    private val clock = Hlc.of(1, 0, "aabbccdd")

    @Test fun theFloorGovernsSmallLibrariesAndThePercentageGovernsLargeOnes() {
        for ((live, allowed) in listOf(0 to 5, 1 to 5, 24 to 5, 25 to 5, 26 to 6, 50 to 10, 100 to 20, 101 to 21)) {
            assertEquals(allowed, DeletionGuard.allowedDeletions(live), "liveCount $live")
        }
    }

    @Test fun exactlyFiveIsAllowedAndSixIsNotWhenTheFloorGoverns() {
        assertTrue(DeletionGuard.evaluate(liveCount = 3, deletions = 5).isAllowed)
        assertFalse(DeletionGuard.evaluate(liveCount = 3, deletions = 6).isAllowed)
        assertTrue(DeletionGuard.evaluate(liveCount = 25, deletions = 5).isAllowed)
        assertFalse(DeletionGuard.evaluate(liveCount = 25, deletions = 6).isAllowed)
    }

    @Test fun exactlyTwentyPercentIsAllowedAndOneMoreIsNot() {
        assertTrue(DeletionGuard.evaluate(liveCount = 100, deletions = 20).isAllowed)
        assertFalse(DeletionGuard.evaluate(liveCount = 100, deletions = 21).isAllowed)
        assertTrue(DeletionGuard.evaluate(liveCount = 500, deletions = 100).isAllowed)
        assertFalse(DeletionGuard.evaluate(liveCount = 500, deletions = 101).isAllowed)
    }

    @Test fun deletingNothingIsAlwaysAllowedIncludingAgainstAnEmptyLibrary() {
        assertTrue(DeletionGuard.evaluate(liveCount = 0, deletions = 0).isAllowed)
        assertTrue(DeletionGuard.evaluate(liveCount = 10_000, deletions = 0).isAllowed)
    }

    @Test fun aBackendThatLostMostOfTheLibraryIsRefusedWithTheNumbersItWasRefusedOn() {
        val refusal = assertNotNull(DeletionGuard.evaluate(liveCount = 48, deletions = 40).refusalOrNull)
        assertEquals(48, refusal.liveCount)
        assertEquals(40, refusal.requestedDeletions)
        assertEquals(10, refusal.allowedDeletions)
        assertTrue(refusal.requestedFraction > 0.8)
        assertTrue("40 of 48" in refusal.description)
        assertTrue("paused before completing" in refusal.description)
        assertTrue("at least 8" in refusal.description)
    }

    @Test fun duplicatedAndUnknownDeletionsDoNotInflateTheCount() {
        val live = (0 until 10).map(::id).toSet()
        assertTrue(DeletionGuard.evaluate(live, listOf(id(0), id(0), id(0), id(1), id(99), id(98))).isAllowed)
        assertFalse(DeletionGuard.evaluate(live, (0 until 10).map(::id) + (0 until 10).map(::id)).isAllowed)
    }

    @Test fun aBatchOfEnvelopesIsCountedByItsTombstonesAlone() {
        val live = (0 until 10).map(::id).toSet()
        val incoming = (0 until 8).map { SyncEnvelope.tombstone(id(it), secure = false, hlc = clock, origin = "aabbccdd") } +
            (8 until 10).map { SyncEnvelope.plain(MergeFixtures.snippet(id(it)), clock, "aabbccdd") }
        val refusal = DeletionGuard.evaluateIncoming(live, incoming).refusalOrNull
        assertEquals(8, refusal?.requestedDeletions)
        assertEquals(5, refusal?.allowedDeletions)
    }

    @Test fun deletionReviewMatchesExactUppercaseUuidFingerprintAndChangedSmallBatch() {
        assertEquals(5, DeletionSafety.allowedDeletions(0))
        assertEquals(5, DeletionSafety.allowedDeletions(25))
        assertEquals(6, DeletionSafety.allowedDeletions(26))
        assertTrue(DeletionSafety.allowedDeletions(Int.MAX_VALUE) > 5, "no overflow at the top")
        assertEquals(5, DeletionSafety.allowedDeletions(-7), "a negative count reads as zero")
        val live = (0L until 30L).map { UUID(0, it) }.toSet()
        assertNull(DeletionSafety.review(live, live.drop(6).toSet()))
        assertEquals(7, DeletionSafety.review(live, live.drop(7).toSet())?.requestedDeletions)
        val onlyOne = live.drop(1).toSet()
        assertNull(DeletionSafety.review(live, onlyOne))
        assertEquals(1, DeletionSafety.facts(live, onlyOne)?.requestedDeletions)
        assertNull(DeletionSafety.facts(live, live))
        assertNotEquals(DeletionSafety.facts(live, onlyOne)?.batchFingerprint, DeletionSafety.facts(live, live.drop(7).toSet())?.batchFingerprint)
    }

    @Test fun theFingerprintSortsTheUppercaseTextNotTheSignedLongs() {
        val ids = setOf(UUID.fromString("f0000000-0000-4000-8000-000000000000"), UUID.fromString("00000000-0000-4000-8000-000000000001"))
        val material = "00000000-0000-4000-8000-000000000001\nF0000000-0000-4000-8000-000000000000"
        assertEquals(SyncEnvelope.sha256Hex(material.toByteArray(Charsets.UTF_8)), DeletionSafety.fingerprint(ids))
        assertEquals(SyncEnvelope.sha256Hex(ByteArray(0)), DeletionSafety.fingerprint(emptySet()))
    }
}
