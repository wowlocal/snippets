package com.khm.snippets.core.sync.transport

import com.khm.snippets.core.wire.WireRecord
import java.util.Collections
import java.util.UUID

// The value types of `snippets/Core/SyncTransport.swift`. All are immutable; where Swift
// mutates a member, use `copy`.

/**
 * Account and transport-private checkpoint in one preflight decision (`SyncScopePreflight`).
 *
 * The issue travels beside the identity, not instead of it, so an explicitly reviewed
 * reset stays bound to the exact scope that was current when it was reviewed.
 */
data class SyncScopePreflight(
    /** The current account scope; `null` for a transport whose data is not account scoped. */
    val identity: SyncAccountIdentity?,
    /** The physical remote dataset generation. `null` for accountless transports and backends without a resettable dataset. */
    val datasetIdentity: SyncDatasetIdentity? = null,
    /**
     * Identities an older transport version emitted for this same scope. Core may use them
     * only for a schema migration before any data-plane call.
     */
    val legacyAccountIdentities: List<SyncAccountIdentity> = emptyList(),
    val checkpointIssue: CheckpointIssue? = null,
) {
    enum class CheckpointIssue {
        /** The transport's private checkpoint belongs to another account. */
        ACCOUNT_CHANGED,

        /** The transport's private checkpoint cannot be authenticated or decoded. */
        UNREADABLE,
    }
}

/**
 * Something the backend told us out of band (`SyncTransportEvent`).
 *
 * A hint that costs nothing to be wrong about: the engine reacts by scheduling a fetch,
 * which is what the poll timer does, so a duplicated, delayed or dropped event degrades to
 * polling and never to a wrong result.
 */
sealed class SyncTransportEvent {

    /** Something changed remotely. Fetch when convenient. */
    object ChangesAvailable : SyncTransportEvent() {
        override fun toString(): String = "ChangesAvailable"
    }

    /**
     * The cursor the engine holds is no longer meaningful and the next fetch will be a
     * full resync. Sent separately from the fetch result so a UI can explain the traffic.
     */
    data class CursorInvalidated(val reason: String) : SyncTransportEvent()

    /** Credentials expired or were revoked. Sync stops until the user signs in again. */
    object AuthenticationRequired : SyncTransportEvent() {
        override fun toString(): String = "AuthenticationRequired"
    }
}

/**
 * One page of remote changes (`SyncFetch`).
 *
 * [cursorKind] follows Swift's initializer: `null` without a cursor, and
 * [SyncCursorKind.LEGACY] for a cursor given without a kind. [copy] applies the same rule.
 */
class SyncFetch(
    records: List<WireRecord>,
    /**
     * Where to resume. Persist it only after the page has been applied and durably
     * written; persisting it first turns a crash into permanent data loss.
     */
    val cursor: SyncCursor?,
    cursorKind: SyncCursorKind? = null,
    /** More pages are waiting. The engine loops at once and does not wait for the next poll. */
    val hasMore: Boolean = false,
    /**
     * The backend could not honour the cursor it was given and restarted the stream. The
     * page is a snapshot, not a delta: nothing may be inferred from a record's absence.
     */
    val isFullResync: Boolean = false,
    /**
     * This page starts a replacement stream after a cursor failed during the current
     * paged fetch: pages already accumulated in this fetch belong to the obsolete feed and
     * must be discarded. Comes with [isFullResync], which alone cannot say this because
     * every page of an ordinary multi-page snapshot may carry it.
     */
    val replacesPriorPages: Boolean = false,
    /**
     * The account scope that produced this page. It must equal the identity resolved
     * before the round's first data-plane call; otherwise the engine discards the response
     * before applying a record or advancing its cursor.
     */
    val accountIdentity: SyncAccountIdentity? = null,
    /** The dataset generation that produced this page. It must equal the preflight value. */
    val datasetIdentity: SyncDatasetIdentity? = null,
) {
    /**
     * In backend order, which is the order the engine applies them in. May hold the same
     * id more than once: every real backend is at-least-once, and the engine is required
     * to be idempotent, not the transport to be exactly-once.
     */
    val records: List<WireRecord> = Collections.unmodifiableList(ArrayList(records))

    /** The protocol family that issued [cursor]. */
    val cursorKind: SyncCursorKind? = if (cursor == null) null else (cursorKind ?: SyncCursorKind.LEGACY)

    fun copy(
        records: List<WireRecord> = this.records,
        cursor: SyncCursor? = this.cursor,
        cursorKind: SyncCursorKind? = this.cursorKind,
        hasMore: Boolean = this.hasMore,
        isFullResync: Boolean = this.isFullResync,
        replacesPriorPages: Boolean = this.replacesPriorPages,
        accountIdentity: SyncAccountIdentity? = this.accountIdentity,
        datasetIdentity: SyncDatasetIdentity? = this.datasetIdentity,
    ): SyncFetch = SyncFetch(
        records, cursor, cursorKind, hasMore, isFullResync, replacesPriorPages, accountIdentity, datasetIdentity,
    )

    override fun equals(other: Any?): Boolean =
        this === other || (
            other is SyncFetch &&
                records == other.records &&
                cursor == other.cursor &&
                cursorKind == other.cursorKind &&
                hasMore == other.hasMore &&
                isFullResync == other.isFullResync &&
                replacesPriorPages == other.replacesPriorPages &&
                accountIdentity == other.accountIdentity &&
                datasetIdentity == other.datasetIdentity
            )

    override fun hashCode(): Int {
        var result = records.hashCode()
        result = result * 31 + (cursor?.hashCode() ?: 0)
        result = result * 31 + (cursorKind?.hashCode() ?: 0)
        result = result * 31 + hasMore.hashCode()
        result = result * 31 + isFullResync.hashCode()
        result = result * 31 + replacesPriorPages.hashCode()
        result = result * 31 + (accountIdentity?.hashCode() ?: 0)
        result = result * 31 + (datasetIdentity?.hashCode() ?: 0)
        return result
    }

    override fun toString(): String =
        "SyncFetch(records=${records.size}, cursor=$cursor, cursorKind=$cursorKind, hasMore=$hasMore, " +
            "isFullResync=$isFullResync, replacesPriorPages=$replacesPriorPages)"
}

/** What happened to one submitted record (`SyncSubmitOutcome`). */
sealed class SyncSubmitOutcome {

    /**
     * Stored. [rev] is what the backend now holds, which differs from the submitted rev
     * when the backend assigns its own. [recordVersion] is mandatory: an adapter that did
     * not receive the saved generation cannot tell success from an ambiguous
     * acknowledgement and must report a retryable rejection instead.
     */
    data class Accepted(val rev: String, val recordVersion: SyncRecordVersion) : SyncSubmitOutcome()

    data class Rejected(val rejection: SyncRejection) : SyncSubmitOutcome()
}

/** The outcome for one record of a submitted batch (`SyncSubmitResult`). */
data class SyncSubmitResult(val id: UUID, val outcome: SyncSubmitOutcome)

/**
 * The result of one `submit` (`SyncSubmission`).
 *
 * [results] is an ordered list parallel to the submitted batch, not a map: a map collapses
 * a batch that holds the same id twice, and losing half of a partially accepted batch is
 * the bug this type exists to make visible.
 */
class SyncSubmission(
    results: List<SyncSubmitResult>,
    /**
     * The backend's position after this submission. The engine never adopts it as its
     * fetch position.
     */
    val cursor: SyncCursor?,
    /** The account scope that took or refused this batch. See [SyncFetch.accountIdentity]. */
    val accountIdentity: SyncAccountIdentity? = null,
    /** The dataset generation that took or refused this batch. */
    val datasetIdentity: SyncDatasetIdentity? = null,
) {
    val results: List<SyncSubmitResult> = Collections.unmodifiableList(ArrayList(results))

    /** One refused record, as Swift's `(id:, rejection:)` tuple. */
    data class RejectedRecord(val id: UUID, val rejection: SyncRejection)

    /** The ids of the accepted records, in batch order. */
    val acceptedIds: List<UUID>
        get() = results.mapNotNull { if (it.outcome is SyncSubmitOutcome.Accepted) it.id else null }

    /** The refused records, in batch order. */
    val rejections: List<RejectedRecord>
        get() = results.mapNotNull { result ->
            (result.outcome as? SyncSubmitOutcome.Rejected)?.let { RejectedRecord(result.id, it.rejection) }
        }

    /** The backend took some of the batch and refused the rest. */
    val isPartial: Boolean get() = acceptedIds.isNotEmpty() && rejections.isNotEmpty()

    fun copy(
        results: List<SyncSubmitResult> = this.results,
        cursor: SyncCursor? = this.cursor,
        accountIdentity: SyncAccountIdentity? = this.accountIdentity,
        datasetIdentity: SyncDatasetIdentity? = this.datasetIdentity,
    ): SyncSubmission = SyncSubmission(results, cursor, accountIdentity, datasetIdentity)

    override fun equals(other: Any?): Boolean =
        this === other || (
            other is SyncSubmission &&
                results == other.results &&
                cursor == other.cursor &&
                accountIdentity == other.accountIdentity &&
                datasetIdentity == other.datasetIdentity
            )

    override fun hashCode(): Int {
        var result = results.hashCode()
        result = result * 31 + (cursor?.hashCode() ?: 0)
        result = result * 31 + (accountIdentity?.hashCode() ?: 0)
        result = result * 31 + (datasetIdentity?.hashCode() ?: 0)
        return result
    }

    override fun toString(): String = "SyncSubmission(results=$results, cursor=$cursor)"
}

/**
 * Pacing for automatic rounds, declared by a transport whose rounds are costly
 * (`SyncRoundPacing`; Git: a commit and a push). Explicit requests (Sync Now, setup,
 * recovery) are never paced. Read by the coordinator only, never by the engine.
 *
 * All three are seconds, as Swift's `TimeInterval`.
 */
data class SyncRoundPacing(
    /** Quiet period after the last local change before the round that pushes it. */
    val localChangeDelay: Double,
    /** Longest a local change waits while further changes keep restarting the delay. */
    val localChangeMaximumWait: Double,
    /** An app activation this soon after a successful round is left to the poll. */
    val activationRefreshInterval: Double,
)
