package com.khm.snippets.core.merge

import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.wire.SyncEnvelope
import java.security.MessageDigest
import java.util.UUID

/**
 * The arithmetic of a destructive batch, shared by every platform (`SyncDeletionSafety`
 * in `SyncMerge.swift`): how many deletions go through without a review, and the exact
 * fingerprint of a set of ids. Keeping both in one place stops one client from silently
 * accepting a batch that another would ask the user about.
 */
object DeletionSafety {

    /** Below this many deletions the percentage is noise and the floor governs. */
    const val FLOOR: Int = 5

    /** The facts of one deletion batch (`SyncDeletionSafety.Review`). */
    data class Review(
        val liveCount: Int,
        val requestedDeletions: Int,
        /** [fingerprint] of the ids that would be deleted. Private recovery state, never a diagnostic field. */
        val batchFingerprint: String,
    )

    /**
     * `max(5, ceil(liveCount / 5))`: a fifth of the library, rounded up, and never fewer
     * than [FLOOR]. A negative count is read as zero.
     *
     * Swift writes `(2n + 9) / 10`, which is the same number for every count it can hold
     * without overflow; this form cannot overflow at all (it is the one Linux uses).
     */
    fun allowedDeletions(liveCount: Int): Int {
        val live = maxOf(0, liveCount)
        return maxOf(FLOOR, live / 5 + (if (live % 5 != 0) 1 else 0))
    }

    /**
     * The facts of the batch that takes [liveIds] to [resultingLiveIds], when it deletes
     * more than [allowedDeletions] allows; `null` when it does not.
     */
    fun review(liveIds: Set<UUID>, resultingLiveIds: Set<UUID>): Review? {
        val facts = facts(liveIds, resultingLiveIds) ?: return null
        return if (facts.requestedDeletions > allowedDeletions(liveIds.size)) facts else null
    }

    /**
     * The facts of any batch that deletes something, including one below the threshold;
     * `null` when nothing is deleted. A host needs this while a review is already on
     * screen: a batch that changed must not inherit the approval merely because it shrank.
     */
    fun facts(liveIds: Set<UUID>, resultingLiveIds: Set<UUID>): Review? {
        val deleting = liveIds - resultingLiveIds
        if (deleting.isEmpty()) return null
        return Review(liveCount = liveIds.size, requestedDeletions = deleting.size, batchFingerprint = fingerprint(deleting))
    }

    /**
     * Lowercase hex SHA-256 of the ids as Foundation's `uuidString` (UPPERCASE), sorted
     * ascending and joined with a line feed. The empty set hashes the empty string.
     */
    fun fingerprint(ids: Set<UUID>): String {
        val material = ids.sortedWith(ConflictCopies.idOrder).joinToString("\n", transform = Uuids::uppercase)
        return Bytes.toHex(MessageDigest.getInstance("SHA-256").digest(Utf8.encode(material)))
    }
}

/**
 * The circuit breaker for unexplained remote deletions (`DeletionGuard` in
 * `DeletionGuard.swift`): a pure function of two counts. A backend restored from an old
 * snapshot, or a peer with a damaged library, reads as "delete most of it"; such a batch
 * is refused and shown to the user, with the numbers it was refused on.
 */
object DeletionGuard {

    const val FLOOR: Int = DeletionSafety.FLOOR

    fun allowedDeletions(liveCount: Int): Int = DeletionSafety.allowedDeletions(liveCount)

    /** Why a batch was refused: the numbers, so that each surface can phrase them. */
    data class Refusal(
        val liveCount: Int,
        val requestedDeletions: Int,
        val allowedDeletions: Int,
    ) {
        /** The share of the library the batch would remove; `1.0` against an empty library. */
        val requestedFraction: Double
            get() = if (liveCount > 0) requestedDeletions.toDouble() / liveCount.toDouble() else 1.0

        /** Swift's `description`, word for word. English, for logs and the CLI; the app phrases its own. */
        val description: String
            get() {
                val remaining = maxOf(0, liveCount - requestedDeletions)
                return "cloud sync reported a batch deleting $requestedDeletions of $liveCount " +
                    "snippet${if (liveCount == 1) "" else "s"}. Sync paused before completing " +
                    "this batch. Applied in full to the reviewed library state, it keeps " +
                    "at least $remaining snippets; up to " +
                    "$allowedDeletions deletions may be applied without confirmation"
            }
    }

    sealed class Decision {
        object Allow : Decision()
        data class Refuse(val refusal: Refusal) : Decision()

        val isAllowed: Boolean get() = this === Allow

        /** The refusal, or `null` when the batch is allowed. */
        val refusalOrNull: Refusal? get() = (this as? Refuse)?.refusal
    }

    /**
     * The whole guard.
     *
     * @param liveCount how many live records the library holds before the batch is applied.
     * @param deletions how many of those the batch would remove.
     *
     * Refused only when [deletions] exceeds [allowedDeletions]. Zero deletions always
     * pass, also against an empty library.
     */
    fun evaluate(liveCount: Int, deletions: Int): Decision {
        val allowed = allowedDeletions(liveCount)
        if (deletions <= allowed) return Decision.Allow
        return Decision.Refuse(Refusal(liveCount = liveCount, requestedDeletions = deletions, allowedDeletions = allowed))
    }

    /**
     * The same decision from the ids: a deletion of something the library does not hold
     * is not counted, and an id that arrives twice is counted once.
     */
    fun evaluate(live: Set<UUID>, deleting: Iterable<UUID>): Decision {
        val effective = HashSet<UUID>()
        for (id in deleting) if (id in live) effective.add(id)
        return evaluate(liveCount = live.size, deletions = effective.size)
    }

    /** The same decision for a batch of opened envelopes: its tombstones. */
    fun evaluateIncoming(live: Set<UUID>, incoming: List<SyncEnvelope>): Decision =
        evaluate(live, incoming.filter { it.deleted }.map { it.id })
}
