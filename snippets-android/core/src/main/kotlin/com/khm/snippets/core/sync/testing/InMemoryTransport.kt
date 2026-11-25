package com.khm.snippets.core.sync.testing

import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.sync.transport.SyncAccountIdentity
import com.khm.snippets.core.sync.transport.SyncCursor
import com.khm.snippets.core.sync.transport.SyncDatasetIdentity
import com.khm.snippets.core.sync.transport.SyncFetch
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.sync.transport.SyncRejection
import com.khm.snippets.core.sync.transport.SyncSubmission
import com.khm.snippets.core.sync.transport.SyncSubmitOutcome
import com.khm.snippets.core.sync.transport.SyncSubmitResult
import com.khm.snippets.core.sync.transport.SyncTransport
import com.khm.snippets.core.sync.transport.SyncTransportEvent
import com.khm.snippets.core.sync.transport.SyncTransportFailure
import com.khm.snippets.core.wire.WireRecord
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import java.util.Collections
import java.util.UUID
import kotlin.time.Duration

/**
 * A complete backend that lives in a map and can be told to misbehave
 * (`snippets/Core/InMemoryTransport.swift`). **A reference fake, not a product transport.**
 *
 * It is in the main source set so that tests of other modules can use it, and it is not a
 * mock: it implements the whole [SyncTransport] contract (cursors, paging, revisions,
 * tombstones, per-record compare-and-swap), and the engine is developed against it. The
 * interesting failures of a sync engine are the ones nobody can reproduce on demand
 * against a real backend:
 *
 * - a batch half accepted, then a crash before the rest is retried
 * - a cursor invalidated between two pages of a resync
 * - the same page delivered twice
 * - a retryable rejection arriving next to one that is not
 *
 * Every one of those is a switch in [Faults].
 *
 * ## How it behaves
 *
 * - State is `id → (record, sequence)`. Sequences start at 1 and every write takes the
 *   next one, so a record written twice moves to the end of the stream. Every stored
 *   record gets `recordVersion = "memory-<sequence>"` (UTF-8).
 * - The cursor is the decimal sequence of the last record delivered. A cursor this
 *   transport did not mint reads as "from the beginning".
 * - There is no account and no dataset identity.
 *
 * ## Concurrency
 *
 * One lock, held only around map access and never across a suspension, so injected
 * latency cannot deadlock a test. Events are sent outside the lock.
 *
 * @param pageSize the most records one fetch returns before it says `hasMore`.
 * @param sleeper applies [Faults.latency]. The default suspends with `delay`, which costs
 *   no wall-clock time under a test scheduler. A test that asserts on latency injects one
 *   that records.
 */
class InMemoryTransport(
    override val identifier: String = "memory",
    override val supportsPush: Boolean = true,
    override val pollInterval: Double = 30.0,
    val pageSize: Int = 100,
    private val sleeper: suspend (Duration) -> Unit = { delay(it) },
) : SyncTransport {

    // Fault injection

    /**
     * Every way this transport can be told to behave badly. All of them default to
     * "behave", so a test opts into exactly the one failure it is about. Immutable; change
     * the transport's faults with [configure].
     */
    data class Faults(
        /** Refuse every record in every submission with this rejection. */
        val rejectEverything: SyncRejection? = null,
        /** Refuse these records. Survives across submissions until cleared. */
        val rejectRecords: Map<UUID, SyncRejection> = emptyMap(),
        /** Fail the next N fetches outright, as if the network were down. Counts down. */
        val failFetches: Int = 0,
        /** Fail the next N submissions outright. Counts down. */
        val failSubmits: Int = 0,
        /**
         * Fail the next N local full-resync resets: a crash or network failure after
         * recovery intent was made durable but before the transport reset completed.
         */
        val failLocalFullResets: Int = 0,
        /** Fail every fetch and submission until cleared. */
        val unreachable: Boolean = false,
        /** Delay applied to every fetch and submission, through the injected sleeper. */
        val latency: Duration = Duration.ZERO,
        /**
         * Accept at most this many records per submission and reject the rest with
         * [partialBatchRejection].
         */
        val acceptAtMostPerBatch: Int? = null,
        val partialBatchRejection: SyncRejection = SyncRejection.RateLimited(retryAfter = 1.0),
        /**
         * The next fetch ignores the cursor it was given, emits
         * [SyncTransportEvent.CursorInvalidated] and returns the store from the beginning
         * as a full resync. Cleared once it fires.
         */
        val invalidateCursorOnNextFetch: Boolean = false,
        /**
         * Deliver every fetched page this many times over. `1` is honest delivery. The
         * page repeats as a block (r1, r2, r1, r2), which is what a retried request looks
         * like.
         */
        val deliverPagesTimes: Int = 1,
        /** Return no cursor on the next fetch, as a backend that lost its place does. Cleared once it fires. */
        val dropCursorOnNextFetch: Boolean = false,
        /** Hand back another rev than the one submitted: `srv-<sequence>-<rev>`. */
        val rewriteAcceptedRevs: Boolean = false,
    ) {
        companion object {
            val NONE: Faults = Faults()
        }
    }

    /**
     * The mutable view [configure] hands to its block, standing in for Swift's
     * `inout Faults`: `transport.configure { failFetches = 2 }`.
     */
    class MutableFaults internal constructor(from: Faults) {
        var rejectEverything: SyncRejection? = from.rejectEverything
        var rejectRecords: MutableMap<UUID, SyncRejection> = LinkedHashMap(from.rejectRecords)
        var failFetches: Int = from.failFetches
        var failSubmits: Int = from.failSubmits
        var failLocalFullResets: Int = from.failLocalFullResets
        var unreachable: Boolean = from.unreachable
        var latency: Duration = from.latency
        var acceptAtMostPerBatch: Int? = from.acceptAtMostPerBatch
        var partialBatchRejection: SyncRejection = from.partialBatchRejection
        var invalidateCursorOnNextFetch: Boolean = from.invalidateCursorOnNextFetch
        var deliverPagesTimes: Int = from.deliverPagesTimes
        var dropCursorOnNextFetch: Boolean = from.dropCursorOnNextFetch
        var rewriteAcceptedRevs: Boolean = from.rewriteAcceptedRevs

        internal fun snapshot(): Faults = Faults(
            rejectEverything = rejectEverything,
            rejectRecords = Collections.unmodifiableMap(LinkedHashMap(rejectRecords)),
            failFetches = failFetches,
            failSubmits = failSubmits,
            failLocalFullResets = failLocalFullResets,
            unreachable = unreachable,
            latency = latency,
            acceptAtMostPerBatch = acceptAtMostPerBatch,
            partialBatchRejection = partialBatchRejection,
            invalidateCursorOnNextFetch = invalidateCursorOnNextFetch,
            deliverPagesTimes = deliverPagesTimes,
            dropCursorOnNextFetch = dropCursorOnNextFetch,
            rewriteAcceptedRevs = rewriteAcceptedRevs,
        )
    }

    // Stored state

    /**
     * [sequence] is monotonic and reassigned on every write, which makes "changes since" a
     * comparison and makes a record that is written twice appear at its new position.
     */
    private class Stored(val record: WireRecord, val sequence: Long)

    private val lock = Any()
    private val stored = HashMap<UUID, Stored>()
    private var nextSequence = 1L
    private var faultsStorage = Faults.NONE
    private val submissionLog = ArrayList<List<WireRecord>>()
    private var fetchCount = 0
    private var localFullResetCount = 0

    // Unlimited on purpose: a dropped event would be indistinguishable from a fake that
    // discards them, and tests that assert on event order would be flaky.
    private val eventChannel = Channel<SyncTransportEvent>(Channel.UNLIMITED)

    override val events: Flow<SyncTransportEvent> = eventChannel.receiveAsFlow()

    // Test control surface

    /** The faults in force now. */
    val faults: Faults
        get() = synchronized(lock) { faultsStorage }

    /** Changes the faults in one step: `configure { unreachable = true }`. */
    fun configure(mutate: MutableFaults.() -> Unit) {
        synchronized(lock) {
            val mutable = MutableFaults(faultsStorage)
            mutable.mutate()
            faultsStorage = mutable.snapshot()
        }
    }

    /** Puts records in as if another device had written them, bypassing every fault. */
    fun seed(records: List<WireRecord>) {
        synchronized(lock) {
            for (record in records) store(record)
        }
    }

    /** Everything the backend holds, in sequence order. */
    val snapshot: List<WireRecord>
        get() = synchronized(lock) { stored.values.sortedBy { it.sequence }.map { it.record } }

    /**
     * Every batch handed to `submit`, in order, including the ones that were rejected or
     * failed outright.
     */
    val submittedBatches: List<List<WireRecord>>
        get() = synchronized(lock) { ArrayList(submissionLog) }

    /** Every `fetchChanges` call, including the ones that failed. */
    val fetchAttempts: Int
        get() = synchronized(lock) { fetchCount }

    /** Every `resetForLocalFullResync` call that passed its scope check, including the ones that failed. */
    val localFullResetAttempts: Int
        get() = synchronized(lock) { localFullResetCount }

    /** The sequence of the newest stored record as a cursor; `null` while the store is empty. */
    val currentCursor: SyncCursor?
        get() = synchronized(lock) { cursorLocked() }

    /** Emits a push hint, as a backend notification would. */
    fun notify(event: SyncTransportEvent = SyncTransportEvent.ChangesAvailable) {
        eventChannel.trySend(event)
    }

    /**
     * Ends [events]: collectors finish once they have drained what was sent. Swift ends
     * the stream when the transport is deallocated; a JVM object has no such moment.
     */
    fun finishEvents() {
        eventChannel.close()
    }

    // SyncTransport

    override suspend fun fetchChanges(since: SyncCursor?): SyncFetch {
        val latency = faults.latency
        if (latency != Duration.ZERO) sleeper(latency)

        val result = performFetch(since)
        // Sent outside the lock.
        result.invalidationReason?.let { eventChannel.trySend(SyncTransportEvent.CursorInvalidated(it)) }
        return result.fetch
    }

    override suspend fun submit(records: List<WireRecord>, at: SyncCursor?): SyncSubmission {
        val latency = faults.latency
        if (latency != Duration.ZERO) sleeper(latency)
        return performSubmit(records)
    }

    /**
     * This backend has no transport-private scheduler, account binding or remote dataset
     * lifecycle, so Core's reviewed reset is a safe no-op here. Stateful transports keep
     * the fail-closed default.
     */
    override suspend fun resetAfterRemoteDataResetReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?,
    ) {
        if (expectedIdentity != null) throw SyncTransportFailure.AccountChanged()
        if (expectedDatasetIdentity != null) throw SyncTransportFailure.RemoteDataReset("unexpected dataset scope")
    }

    override suspend fun resetForLocalFullResync(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?,
    ) {
        if (expectedIdentity != null) throw SyncTransportFailure.AccountChanged()
        if (expectedDatasetIdentity != null) throw SyncTransportFailure.RemoteDataReset("unexpected dataset scope")
        synchronized(lock) {
            localFullResetCount += 1
            if (faultsStorage.failLocalFullResets > 0) {
                faultsStorage = faultsStorage.copy(failLocalFullResets = faultsStorage.failLocalFullResets - 1)
                throw SyncTransportFailure.Unreachable("injected full-resync failure")
            }
        }
    }

    // Internals

    private class FetchResult(val fetch: SyncFetch, val invalidationReason: String?)

    private fun performFetch(cursor: SyncCursor?): FetchResult = synchronized(lock) {
        fetchCount += 1

        if (faultsStorage.unreachable) {
            throw SyncTransportFailure.Unreachable("InMemoryTransport.faults.unreachable")
        }
        if (faultsStorage.failFetches > 0) {
            faultsStorage = faultsStorage.copy(failFetches = faultsStorage.failFetches - 1)
            throw SyncTransportFailure.Unreachable("injected fetch failure")
        }

        var effectiveCursor = cursor
        var isFullResync = false
        var invalidationReason: String? = null
        if (faultsStorage.invalidateCursorOnNextFetch) {
            faultsStorage = faultsStorage.copy(invalidateCursorOnNextFetch = false)
            effectiveCursor = null
            isFullResync = true
            invalidationReason = "injected cursor invalidation"
        }
        // A cursor minted before the backend was rewound points past the end of the store.
        // Serving it as it is returns an empty page for ever, which reads as "nothing has
        // changed" while the whole library sits there unfetched.
        val position = position(effectiveCursor)
        if (position != null && position > highWaterMarkLocked()) {
            effectiveCursor = null
            isFullResync = true
            invalidationReason = "cursor is ahead of the backend"
        }

        val after = position(effectiveCursor) ?: 0L
        val pending = stored.values.filter { it.sequence > after }.sortedBy { it.sequence }

        val page = pending.take(pageSize)
        val hasMore = pending.size > page.size

        val records = ArrayList<WireRecord>(page.size * maxOf(1, faultsStorage.deliverPagesTimes))
        for (entry in page) records.add(entry.record)
        // Duplicate delivery repeats the page as a block, not interleaved.
        if (faultsStorage.deliverPagesTimes > 1) {
            val once = ArrayList(records)
            repeat(faultsStorage.deliverPagesTimes - 1) { records.addAll(once) }
        }

        var nextCursor = page.lastOrNull()?.let { SyncCursor(it.sequence.toString()) } ?: effectiveCursor
        if (faultsStorage.dropCursorOnNextFetch) {
            faultsStorage = faultsStorage.copy(dropCursorOnNextFetch = false)
            nextCursor = null
        }

        FetchResult(
            SyncFetch(
                records = records,
                cursor = nextCursor,
                hasMore = hasMore,
                isFullResync = isFullResync,
                replacesPriorPages = isFullResync && cursor != null,
            ),
            invalidationReason,
        )
    }

    private fun performSubmit(records: List<WireRecord>): SyncSubmission = synchronized(lock) {
        submissionLog.add(Collections.unmodifiableList(ArrayList(records)))

        if (!supportsPush) throw SyncTransportFailure.PushUnsupported()
        if (faultsStorage.unreachable) {
            throw SyncTransportFailure.Unreachable("InMemoryTransport.faults.unreachable")
        }
        if (faultsStorage.failSubmits > 0) {
            faultsStorage = faultsStorage.copy(failSubmits = faultsStorage.failSubmits - 1)
            throw SyncTransportFailure.Unreachable("injected submit failure")
        }

        val results = ArrayList<SyncSubmitResult>(records.size)
        var accepted = 0

        for (record in records) {
            val blanket = faultsStorage.rejectEverything
            if (blanket != null) {
                results.add(SyncSubmitResult(record.id, SyncSubmitOutcome.Rejected(blanket)))
                continue
            }
            val targeted = faultsStorage.rejectRecords[record.id]
            if (targeted != null) {
                results.add(SyncSubmitResult(record.id, SyncSubmitOutcome.Rejected(targeted)))
                continue
            }
            val limit = faultsStorage.acceptAtMostPerBatch
            if (limit != null && accepted >= limit) {
                results.add(
                    SyncSubmitResult(record.id, SyncSubmitOutcome.Rejected(faultsStorage.partialBatchRejection)),
                )
                continue
            }
            // Real per-record optimistic concurrency. The submitted generation must be the
            // exact one returned by the last fetch or save. A create carries none and
            // conflicts if the id already exists, which is how a lost create
            // acknowledgement becomes a merge and not an unconditional overwrite.
            val existing = stored[record.id]
            if (existing != null && existing.record.recordVersion != record.recordVersion) {
                results.add(
                    SyncSubmitResult(
                        record.id, SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = existing.record)),
                    ),
                )
                continue
            }
            if (existing == null && record.recordVersion != null) {
                results.add(
                    SyncSubmitResult(record.id, SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = null))),
                )
                continue
            }

            val toStore =
                if (faultsStorage.rewriteAcceptedRevs) record.copy(rev = "srv-$nextSequence-${record.rev}") else record
            val saved = store(toStore)
            accepted += 1
            results.add(
                SyncSubmitResult(
                    record.id,
                    SyncSubmitOutcome.Accepted(rev = saved.rev, recordVersion = saved.recordVersion!!),
                ),
            )
        }

        SyncSubmission(results = results, cursor = cursorLocked())
    }

    /** Caller holds [lock]. Returns the record as stored, with its new generation. */
    private fun store(record: WireRecord): WireRecord {
        val version = SyncRecordVersion(Utf8.encode("memory-$nextSequence"))
        val versioned = record.copy(recordVersion = version)
        stored[record.id] = Stored(versioned, nextSequence)
        nextSequence += 1
        return versioned
    }

    /** Caller holds [lock]. */
    private fun cursorLocked(): SyncCursor? =
        stored.values.maxOfOrNull { it.sequence }?.let { SyncCursor(it.toString()) }

    /** Caller holds [lock]. */
    private fun highWaterMarkLocked(): Long = stored.values.maxOfOrNull { it.sequence } ?: 0L

    private companion object {

        /**
         * A cursor this transport did not mint parses to `null` and is treated as "from the
         * beginning", not as an error: that is the safe direction.
         *
         * Swift's `Int(String)`: an optional sign, then ASCII digits, within 64 bits.
         */
        fun position(cursor: SyncCursor?): Long? {
            val text = cursor?.rawValue ?: return null
            if (text.isEmpty()) return null
            val negative = text[0] == '-'
            val start = if (negative || text[0] == '+') 1 else 0
            if (start == text.length) return null
            var value = 0L
            for (index in start until text.length) {
                val character = text[index]
                if (character !in '0'..'9') return null
                val digit = (character - '0').toLong()
                // Accumulated as a negative number, whose range is one larger.
                if (value < (Long.MIN_VALUE + digit) / 10) return null
                value = value * 10 - digit
            }
            if (!negative && value == Long.MIN_VALUE) return null
            return if (negative) value else -value
        }
    }
}
