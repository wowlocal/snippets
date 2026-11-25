package com.khm.snippets.core.sync.testing

import com.khm.snippets.core.sync.transport.SyncAccountIdentity
import com.khm.snippets.core.sync.transport.SyncCursor
import com.khm.snippets.core.sync.transport.SyncCursorKind
import com.khm.snippets.core.sync.transport.SyncDatasetIdentity
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.sync.transport.SyncRejection
import com.khm.snippets.core.sync.transport.SyncScopePreflight
import com.khm.snippets.core.sync.transport.SyncSubmitOutcome
import com.khm.snippets.core.sync.transport.SyncTransportEvent
import com.khm.snippets.core.sync.transport.SyncTransportFailure
import com.khm.snippets.core.wire.SyncEnvelope
import com.khm.snippets.core.wire.TestSealer
import com.khm.snippets.core.wire.WireCodec
import com.khm.snippets.core.wire.WireFixtures
import com.khm.snippets.core.wire.WireFixtures.clock
import com.khm.snippets.core.wire.WireFixtures.id
import com.khm.snippets.core.wire.WireFixtures.snippet
import com.khm.snippets.core.wire.WireFixtures.utf8
import com.khm.snippets.core.wire.WireRecord
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * `WireTests.swift`, suite "In-memory transport", test for test and under the same names,
 * followed by what the engine tests rely on and that suite does not spell out: the exact
 * cursors and generations, the order of the fault checks, the call log, the reset
 * overrides and the event stream.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class InMemoryTransportTest {

    private val thisDevice = WireFixtures.THIS_DEVICE

    private fun records(indices: List<Int>): List<WireRecord> {
        val sealer = TestSealer()
        return indices.map {
            WireCodec.seal(SyncEnvelope.plain(snippet(it), hlc = clock(it.toLong() + 1), origin = thisDevice), sealer)
        }
    }

    private fun records(vararg indices: Int): List<WireRecord> = records(indices.toList())

    /** A latency sink that records and does not wait (`LatencyRecorder`). */
    private class LatencyRecorder {
        val durations = ArrayList<Duration>()
        val sleeper: suspend (Duration) -> Unit = { synchronized(durations) { durations.add(it) } }
    }

    private fun memoryVersion(sequence: Int) = SyncRecordVersion(utf8("memory-$sequence"))

    // WireTests.swift: In-memory transport

    @Test fun aQuietBackendDeliversEverythingOnceAndThenNothing() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0, 1, 2))

        val first = transport.fetchChanges(since = null)
        assertEquals(listOf(id(0), id(1), id(2)), first.records.map { it.id })
        assertFalse(first.hasMore)
        assertFalse(first.isFullResync)

        val second = transport.fetchChanges(since = first.cursor)
        assertTrue(second.records.isEmpty())
        assertEquals(first.cursor, second.cursor)
    }

    @Test fun pagingStopsAtThePageSizeAndSaysThereIsMore() = runTest {
        val transport = InMemoryTransport(pageSize = 2)
        transport.seed(records(0, 1, 2, 3, 4))

        var cursor: SyncCursor? = null
        val seen = ArrayList<UUID>()
        var pages = 0
        do {
            val page = transport.fetchChanges(since = cursor)
            seen.addAll(page.records.map { it.id })
            cursor = page.cursor
            pages += 1
            if (!page.hasMore) break
        } while (pages < 10)

        assertEquals((0 until 5).map(::id), seen)
        assertEquals(3, pages)
    }

    // Fault: rejection

    @Test fun aBlanketRejectionRefusesEveryRecordAndStoresNone() = runTest {
        val transport = InMemoryTransport()
        transport.configure { rejectEverything = SyncRejection.Permanent(detail = "record too large") }

        val submission = transport.submit(records(0, 1), at = null)

        assertTrue(submission.acceptedIds.isEmpty())
        assertEquals(2, submission.rejections.size)
        assertTrue(submission.rejections.all { !it.rejection.isRetryable })
        assertTrue(transport.snapshot.isEmpty())
    }

    @Test fun aPerRecordRejectionLetsTheRestOfTheBatchThrough() = runTest {
        val transport = InMemoryTransport()
        transport.configure { rejectRecords[id(1)] = SyncRejection.Conflict(remote = null) }

        val submission = transport.submit(records(0, 1, 2), at = null)

        assertEquals(listOf(id(0), id(2)), submission.acceptedIds)
        assertEquals(listOf(id(1)), submission.rejections.map { it.id })
        assertTrue(submission.isPartial)
        assertEquals(listOf(id(0), id(2)), transport.snapshot.map { it.id })
    }

    // Fault: network failure

    @Test fun anUnreachableBackendFailsFetchAndSubmitUntilItIsCleared() = runTest {
        val transport = InMemoryTransport()
        transport.configure { unreachable = true }

        assertFailsWith<SyncTransportFailure.Unreachable> { transport.fetchChanges(since = null) }
        assertFailsWith<SyncTransportFailure.Unreachable> { transport.submit(records(0), at = null) }

        transport.configure { unreachable = false }
        transport.submit(records(0), at = null)
        assertEquals(1, transport.snapshot.size)
    }

    @Test fun countedFlakinessFailsExactlyTheNumberOfCallsItWasToldTo() = runTest {
        val transport = InMemoryTransport()
        transport.configure { failFetches = 2 }

        assertFailsWith<SyncTransportFailure.Unreachable> { transport.fetchChanges(since = null) }
        assertFailsWith<SyncTransportFailure.Unreachable> { transport.fetchChanges(since = null) }
        transport.fetchChanges(since = null)

        assertEquals(3, transport.fetchAttempts)
        assertEquals(0, transport.faults.failFetches)
    }

    // Fault: latency

    @Test fun configuredLatencyIsAppliedToEveryCallThroughTheInjectedSleeper() = runTest {
        val recorder = LatencyRecorder()
        val transport = InMemoryTransport(sleeper = recorder.sleeper)
        transport.configure { latency = 250.milliseconds }

        transport.fetchChanges(since = null)
        transport.submit(records(0), at = null)

        // Recorded, not slept: the suite stays fast and the assertion stays exact.
        assertEquals(listOf(250.milliseconds, 250.milliseconds), recorder.durations)
    }

    @Test fun zeroLatencyDoesNotTouchTheSleeperAtAll() = runTest {
        val recorder = LatencyRecorder()
        val transport = InMemoryTransport(sleeper = recorder.sleeper)

        transport.fetchChanges(since = null)
        assertTrue(recorder.durations.isEmpty())
    }

    // Fault: partial batch acceptance

    /** An engine that assumes a submission is all-or-nothing drops the unaccepted tail silently. */
    @Test fun aPartiallyAcceptedBatchStoresThePrefixAndRejectsTheTail() = runTest {
        val transport = InMemoryTransport()
        transport.configure {
            acceptAtMostPerBatch = 2
            partialBatchRejection = SyncRejection.RateLimited(retryAfter = 30.0)
        }

        val submission = transport.submit(records(0, 1, 2, 3), at = null)

        assertEquals(listOf(id(0), id(1)), submission.acceptedIds)
        assertEquals(listOf(id(2), id(3)), submission.rejections.map { it.id })
        assertTrue(submission.rejections.all { it.rejection == SyncRejection.RateLimited(retryAfter = 30.0) })
        assertTrue(submission.isPartial)
        assertEquals(listOf(id(0), id(1)), transport.snapshot.map { it.id })
    }

    // Fault: cursor invalidation

    @Test fun aninvalidatedCursorForcesAFullResyncAndAnnouncesItself() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0, 1, 2))
        val first = transport.fetchChanges(since = null)
        assertEquals(3, first.records.size)

        transport.configure { invalidateCursorOnNextFetch = true }
        val resync = transport.fetchChanges(since = first.cursor)

        assertTrue(resync.isFullResync)
        assertEquals(3, resync.records.size, "a resync is a snapshot, not a delta")

        val event = transport.events.first()
        assertEquals(SyncTransportEvent.CursorInvalidated(reason = "injected cursor invalidation"), event)

        // And it fires exactly once.
        val after = transport.fetchChanges(since = resync.cursor)
        assertFalse(after.isFullResync)
        assertTrue(after.records.isEmpty())
    }

    /** A cursor minted before the backend was rewound points past the end of the store. */
    @Test fun aCursorFromTheFutureIsTreatedAsAResyncRatherThanAsSilence() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0, 1))

        val fetch = transport.fetchChanges(since = SyncCursor("9999"))

        assertTrue(fetch.isFullResync)
        assertEquals(2, fetch.records.size)
    }

    @Test fun aDroppedCursorDoesNotLookLikeStartOver() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0, 1))
        transport.configure { dropCursorOnNextFetch = true }

        val fetch = transport.fetchChanges(since = null)

        assertNull(fetch.cursor)
        assertFalse(fetch.isFullResync, "losing the cursor is not the same as a resync")
    }

    // Fault: duplicate delivery

    /** Every real backend is at-least-once. The engine is required to be idempotent. */
    @Test fun duplicateDeliveryRepeatsThePageAsABlockJustLikeARetriedRequest() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0, 1))
        transport.configure { deliverPagesTimes = 3 }

        val fetch = transport.fetchChanges(since = null)

        assertEquals(listOf(id(0), id(1), id(0), id(1), id(0), id(1)), fetch.records.map { it.id })
        assertEquals(2, fetch.records.map { it.id }.toSet().size)
    }

    // Fault: a backend that assigns its own revisions

    @Test fun aBackendThatRewritesRevsIsReportedRatherThanAssumedAway() = runTest {
        val transport = InMemoryTransport()
        transport.configure { rewriteAcceptedRevs = true }
        val submitted = records(0)

        val submission = transport.submit(submitted, at = null)

        val outcome = submission.results[0].outcome as? SyncSubmitOutcome.Accepted
            ?: fail("the record should have been accepted")
        assertNotEquals(submitted[0].rev, outcome.rev)
        assertEquals(outcome.rev, transport.snapshot[0].rev)
        assertEquals(outcome.recordVersion, transport.snapshot[0].recordVersion)
        // The exact rewrite: `srv-<sequence>-<rev>`.
        assertEquals("srv-1-${submitted[0].rev}", outcome.rev)
    }

    // Conflicts and push support

    /** Two devices pushing the same record from stale views is a conflict, not a lost update. */
    @Test fun pushingOverARecordWrittenAfterOurCursorIsAConflict() = runTest {
        val transport = InMemoryTransport()
        val sealer = TestSealer()

        val mine = WireCodec.seal(
            SyncEnvelope.plain(snippet(0, content = "mine"), hlc = clock(1), origin = thisDevice), sealer,
        )
        val theirs = WireCodec.seal(
            SyncEnvelope.plain(snippet(0, content = "theirs"), hlc = clock(2), origin = "11112222"), sealer,
        )

        // Our view of the world predates their write.
        val staleCursor = transport.currentCursor
        transport.seed(listOf(theirs))

        val submission = transport.submit(listOf(mine), at = staleCursor)

        assertTrue(submission.acceptedIds.isEmpty())
        val authoritative = (submission.rejections.firstOrNull()?.rejection as? SyncRejection.Conflict)?.remote
            ?: fail("the stale write must disclose the authoritative record")
        assertEquals(theirs.id, authoritative.id)
        assertEquals(theirs.rev, authoritative.rev)
        assertEquals(theirs.deleted, authoritative.deleted)
        assertContentEquals(theirs.blob, authoritative.blob)
        assertNotNull(authoritative.recordVersion)

        // Re-reading first, then resubmitting, succeeds.
        val fresh = transport.fetchChanges(since = staleCursor)
        val retriedMine = mine.copy(recordVersion = fresh.records.firstOrNull { it.id == mine.id }?.recordVersion)
        val retried = transport.submit(listOf(retriedMine), at = fresh.cursor)
        assertEquals(listOf(id(0)), retried.acceptedIds)
    }

    @Test fun aPollOnlyBackendRefusesAPushRatherThanPretendingToAcceptIt() = runTest {
        val transport = InMemoryTransport(supportsPush = false)

        assertFalse(transport.supportsPush)
        val failure = assertFailsWith<SyncTransportFailure.PushUnsupported> { transport.submit(records(0), at = null) }
        assertEquals(SyncTransportFailure.PushUnsupported(), failure)
    }

    @Test fun everySubmissionIsLoggedIncludingTheRejectedOnes() = runTest {
        val transport = InMemoryTransport()
        transport.configure { rejectEverything = SyncRejection.Permanent(detail = "nope") }

        transport.submit(records(0), at = null)
        transport.submit(records(1, 2), at = null)

        assertEquals(listOf(1, 2), transport.submittedBatches.map { it.size })
    }

    @Test fun aPushHintReachesTheEventStream() = runTest {
        val transport = InMemoryTransport()
        transport.notify(SyncTransportEvent.ChangesAvailable)

        assertEquals(SyncTransportEvent.ChangesAvailable, transport.events.first())
    }

    // What the engine tests rely on: defaults, cursors and generations

    @Test fun theDefaultsAreSwifts() = runTest {
        val transport = InMemoryTransport()
        assertEquals("memory", transport.identifier)
        assertTrue(transport.supportsPush)
        assertEquals(30.0, transport.pollInterval)
        assertEquals(100, transport.pageSize)
        assertNull(transport.roundPacing)
        assertEquals(InMemoryTransport.Faults.NONE, transport.faults)
        assertEquals(InMemoryTransport.Faults(), InMemoryTransport.Faults.NONE)
        assertEquals(SyncRejection.RateLimited(retryAfter = 1.0), transport.faults.partialBatchRejection)
        assertEquals(1, transport.faults.deliverPagesTimes)
        assertEquals(Duration.ZERO, transport.faults.latency)

        // No account, no dataset, nothing stored.
        assertNull(transport.resolveAccountIdentity())
        assertEquals(SyncScopePreflight(identity = null), transport.preflightScope())
        assertNull(transport.currentCursor)
        assertTrue(transport.snapshot.isEmpty())
        assertTrue(transport.submittedBatches.isEmpty())
        assertEquals(0, transport.fetchAttempts)
        assertEquals(0, transport.localFullResetAttempts)

        val empty = transport.fetchChanges(since = null)
        assertTrue(empty.records.isEmpty())
        assertNull(empty.cursor)
        assertNull(empty.cursorKind)
        assertNull(empty.accountIdentity)
        assertNull(empty.datasetIdentity)
        assertFalse(empty.hasMore)
        assertFalse(empty.replacesPriorPages)
    }

    @Test fun everyWriteTakesTheNextSequenceAndTheGenerationNamesIt() = runTest {
        val transport = InMemoryTransport()
        val batch = records(0, 1)

        val submission = transport.submit(batch, at = null)
        assertEquals(
            listOf(SyncSubmitOutcome.Accepted(batch[0].rev, memoryVersion(1)), SyncSubmitOutcome.Accepted(batch[1].rev, memoryVersion(2))),
            submission.results.map { it.outcome },
        )
        assertEquals(SyncCursor("2"), submission.cursor)
        assertEquals(SyncCursor("2"), transport.currentCursor)
        assertNull(submission.accountIdentity)
        assertNull(submission.datasetIdentity)

        // A seeded write takes a sequence too.
        transport.seed(records(2))
        assertEquals(memoryVersion(3), transport.snapshot.last().recordVersion)

        // Writing a record again moves it to the end of the stream, like a log-shaped backend.
        val update = batch[0].copy(recordVersion = memoryVersion(1))
        val second = transport.submit(listOf(update), at = SyncCursor("3"))
        assertEquals(SyncSubmitOutcome.Accepted(batch[0].rev, memoryVersion(4)), second.results.single().outcome)
        assertEquals(listOf(id(1), id(2), id(0)), transport.snapshot.map { it.id })
        assertEquals(SyncCursor("4"), second.cursor)

        // The cursor is the sequence of the last record delivered, with the legacy kind.
        val fetch = transport.fetchChanges(since = SyncCursor("2"))
        assertEquals(listOf(id(2), id(0)), fetch.records.map { it.id })
        assertEquals(SyncCursor("4"), fetch.cursor)
        assertEquals(SyncCursorKind.LEGACY, fetch.cursorKind)
        assertEquals(listOf(memoryVersion(3), memoryVersion(4)), fetch.records.map { it.recordVersion })
    }

    @Test fun whatIsStoredIsTheSubmittedRecordWithTheNewGenerationAndNothingElseChanged() = runTest {
        val transport = InMemoryTransport()
        val record = records(0).single()
        transport.submit(listOf(record), at = null)

        val stored = transport.snapshot.single()
        assertEquals(record.copy(recordVersion = memoryVersion(1)), stored)
        assertEquals(stored, transport.fetchChanges(since = null).records.single())
        // The submitted batch is logged as it was handed in.
        assertEquals(listOf(listOf(record)), transport.submittedBatches)
    }

    @Test fun aCursorThisTransportDidNotMintReadsAsFromTheBeginningWithoutClaimingAResync() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0, 1, 2))

        // Not an integer to Swift's `Int(String)`: everything, and no resync flag.
        for (foreign in listOf("abc", "", " 1", "1 ", "1.5", "0x1", "١", "１", "99999999999999999999", "-", "+")) {
            val fetch = transport.fetchChanges(since = SyncCursor(foreign))
            assertEquals(3, fetch.records.size, "cursor \"$foreign\"")
            assertFalse(fetch.isFullResync, "cursor \"$foreign\"")
            assertFalse(fetch.replacesPriorPages, "cursor \"$foreign\"")
            assertEquals(SyncCursor("3"), fetch.cursor)
        }
        // Integers, as Swift reads them: a sign is allowed, and a negative position is before everything.
        assertEquals(listOf(id(1), id(2)), transport.fetchChanges(since = SyncCursor("+1")).records.map { it.id })
        assertEquals(listOf(id(2)), transport.fetchChanges(since = SyncCursor("02")).records.map { it.id })
        assertEquals(3, transport.fetchChanges(since = SyncCursor("-5")).records.size)
        assertEquals(3, transport.fetchChanges(since = SyncCursor("0")).records.size)
        assertEquals(3, transport.fetchChanges(since = SyncCursor("-9223372036854775808")).records.size)
        assertFalse(transport.fetchChanges(since = SyncCursor("-5")).isFullResync)
        // At the end: nothing, and the same cursor back.
        val quiet = transport.fetchChanges(since = SyncCursor("3"))
        assertTrue(quiet.records.isEmpty())
        assertEquals(SyncCursor("3"), quiet.cursor)
        assertFalse(quiet.isFullResync)
        // One past the end, and the largest integer: ahead of the backend.
        for (ahead in listOf("4", "9223372036854775807")) {
            val resync = transport.fetchChanges(since = SyncCursor(ahead))
            assertTrue(resync.isFullResync)
            assertTrue(resync.replacesPriorPages)
            assertEquals(3, resync.records.size)
        }
    }

    @Test fun aCursorAheadOfTheBackendAnnouncesItselfWithItsOwnReason() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0))

        transport.fetchChanges(since = SyncCursor("5"))
        assertEquals(SyncTransportEvent.CursorInvalidated("cursor is ahead of the backend"), transport.events.first())

        // An empty backend is behind every positive cursor.
        val empty = InMemoryTransport()
        val fetch = empty.fetchChanges(since = SyncCursor("1"))
        assertTrue(fetch.isFullResync)
        assertTrue(fetch.replacesPriorPages)
        assertNull(fetch.cursor, "the resync restarted from no cursor and delivered nothing")
        assertFalse(empty.fetchChanges(since = SyncCursor("0")).isFullResync)
    }

    @Test fun aResyncReplacesPriorPagesOnlyWhenACursorWasGiven() = runTest {
        val transport = InMemoryTransport(pageSize = 2)
        transport.seed(records(0, 1, 2, 3, 4))

        transport.configure { invalidateCursorOnNextFetch = true }
        val fromNothing = transport.fetchChanges(since = null)
        assertTrue(fromNothing.isFullResync)
        assertFalse(fromNothing.replacesPriorPages, "there are no prior pages when the fetch started from no cursor")
        assertTrue(fromNothing.hasMore)

        // Invalidated between two pages of a paged fetch: the stream restarts at the first record.
        val firstPage = transport.fetchChanges(since = null)
        assertEquals(listOf(id(0), id(1)), firstPage.records.map { it.id })
        assertFalse(firstPage.isFullResync)
        transport.configure { invalidateCursorOnNextFetch = true }
        val restarted = transport.fetchChanges(since = firstPage.cursor)
        assertTrue(restarted.isFullResync)
        assertTrue(restarted.replacesPriorPages)
        assertEquals(listOf(id(0), id(1)), restarted.records.map { it.id })
        assertTrue(restarted.hasMore)
        // The following pages of the replacement stream are ordinary pages.
        val next = transport.fetchChanges(since = restarted.cursor)
        assertEquals(listOf(id(2), id(3)), next.records.map { it.id })
        assertFalse(next.isFullResync)
        assertFalse(next.replacesPriorPages)
        assertFalse(transport.faults.invalidateCursorOnNextFetch)
    }

    @Test fun pagingCursorsAndDuplicateDeliveryCompose() = runTest {
        val transport = InMemoryTransport(pageSize = 2)
        transport.seed(records(0, 1, 2))
        transport.configure { deliverPagesTimes = 2 }

        val first = transport.fetchChanges(since = null)
        assertEquals(listOf(id(0), id(1), id(0), id(1)), first.records.map { it.id })
        assertEquals(SyncCursor("2"), first.cursor)
        assertTrue(first.hasMore)
        val second = transport.fetchChanges(since = first.cursor)
        assertEquals(listOf(id(2), id(2)), second.records.map { it.id })
        assertFalse(second.hasMore)
        // An empty page repeated is still empty, and hands back the incoming cursor.
        val third = transport.fetchChanges(since = second.cursor)
        assertTrue(third.records.isEmpty())
        assertEquals(second.cursor, third.cursor)
    }

    @Test fun aDroppedCursorFiresOnceAndTheNextFetchHasOneAgain() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0, 1))
        transport.configure { dropCursorOnNextFetch = true }

        assertNull(transport.fetchChanges(since = SyncCursor("1")).cursor)
        assertFalse(transport.faults.dropCursorOnNextFetch)
        assertEquals(SyncCursor("2"), transport.fetchChanges(since = SyncCursor("1")).cursor)
    }

    // The order of the checks in a submission

    @Test fun compareAndSwapIsPerRecordAndExact() = runTest {
        val transport = InMemoryTransport()
        val original = records(0, 1)
        transport.submit(original, at = null)

        val next = records(0, 1, 2).map { it.copy(rev = "next-${it.rev}") }
        val submission = transport.submit(
            listOf(
                next[0].copy(recordVersion = memoryVersion(1)),      // the exact generation
                next[1].copy(recordVersion = memoryVersion(1)),      // another record's generation
                next[2].copy(recordVersion = memoryVersion(2)),      // an update of nothing
                next[1],                                             // a create over an existing record
                next[1].copy(recordVersion = SyncRecordVersion(utf8("memory-02"))),   // the bytes, not the number
            ),
            at = null,
        )

        val stored1 = original[1].copy(recordVersion = memoryVersion(2))
        assertEquals(
            listOf(
                SyncSubmitOutcome.Accepted("next-${original[0].rev}", memoryVersion(3)),
                SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = stored1)),
                SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = null)),
                SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = stored1)),
                SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = stored1)),
            ),
            submission.results.map { it.outcome },
        )
        assertEquals(listOf(id(0), id(1), id(2), id(1), id(1)), submission.results.map { it.id })
        assertEquals(listOf(id(1), id(0)), transport.snapshot.map { it.id })
    }

    @Test fun theSameIdTwiceInOneBatchIsTwoResults() = runTest {
        val transport = InMemoryTransport()
        val first = records(0).single()
        val second = first.copy(rev = "second")

        val submission = transport.submit(listOf(first, second, second.copy(recordVersion = memoryVersion(1))), at = null)
        // The create lands; the second create conflicts with it; the update built on it lands.
        assertEquals(
            listOf(
                SyncSubmitOutcome.Accepted(first.rev, memoryVersion(1)),
                SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = first.copy(recordVersion = memoryVersion(1)))),
                SyncSubmitOutcome.Accepted("second", memoryVersion(2)),
            ),
            submission.results.map { it.outcome },
        )
        assertEquals(listOf(id(0), id(0)), submission.acceptedIds)
        assertTrue(submission.isPartial)
    }

    @Test fun faultsAreCheckedInSwiftsOrder() = runTest {
        // A blanket rejection wins over a per-record one, which wins over the batch limit,
        // which wins over the generation check.
        val transport = InMemoryTransport()
        transport.seed(records(3))
        transport.configure {
            rejectRecords[id(1)] = SyncRejection.Permanent("targeted")
            acceptAtMostPerBatch = 1
        }
        val batch = records(0, 1, 2, 3)

        val limited = transport.submit(batch, at = null)
        assertEquals(
            listOf(
                SyncSubmitOutcome.Accepted(batch[0].rev, memoryVersion(2)),
                SyncSubmitOutcome.Rejected(SyncRejection.Permanent("targeted")),
                SyncSubmitOutcome.Rejected(SyncRejection.RateLimited(1.0)),
                // Past the limit, so the stale generation is never looked at.
                SyncSubmitOutcome.Rejected(SyncRejection.RateLimited(1.0)),
            ),
            limited.results.map { it.outcome },
        )

        transport.configure { rejectEverything = SyncRejection.AuthenticationRequired("signed out") }
        val blanket = transport.submit(batch, at = null)
        assertTrue(blanket.rejections.all { it.rejection == SyncRejection.AuthenticationRequired("signed out") })
        assertEquals(4, blanket.rejections.size)

        // A refused record does not use up the limit; only stored ones count.
        transport.configure {
            rejectEverything = null
            rejectRecords.clear()
            acceptAtMostPerBatch = 2
        }
        val counted = transport.submit(records(3, 4, 5, 6), at = null)   // 3 conflicts (a create over the seed)
        assertEquals(listOf(id(4), id(5)), counted.acceptedIds)
        assertTrue(counted.results[0].outcome is SyncSubmitOutcome.Rejected)
        assertEquals(SyncSubmitOutcome.Rejected(SyncRejection.RateLimited(1.0)), counted.results[3].outcome)

        transport.configure { acceptAtMostPerBatch = 0 }
        assertTrue(transport.submit(records(7, 8), at = null).acceptedIds.isEmpty())
    }

    @Test fun aFailedOrRefusedSubmissionIsStillLoggedAndStoresNothing() = runTest {
        val transport = InMemoryTransport()
        transport.configure { failSubmits = 2 }

        val first = assertFailsWith<SyncTransportFailure.Unreachable> { transport.submit(records(0), at = null) }
        assertEquals("injected submit failure", first.detail)
        assertFailsWith<SyncTransportFailure.Unreachable> { transport.submit(records(0, 1), at = null) }
        assertEquals(0, transport.faults.failSubmits)
        transport.submit(records(0), at = null)

        assertEquals(listOf(1, 2, 1), transport.submittedBatches.map { it.size })
        assertEquals(listOf(id(0)), transport.snapshot.map { it.id })

        // Unreachable is a switch, not a countdown, and does not use the counters up.
        transport.configure {
            unreachable = true
            failFetches = 1
            failSubmits = 1
        }
        val switchedOff = assertFailsWith<SyncTransportFailure.Unreachable> { transport.fetchChanges(since = null) }
        assertEquals("InMemoryTransport.faults.unreachable", switchedOff.detail)
        assertFailsWith<SyncTransportFailure.Unreachable> { transport.submit(records(1), at = null) }
        assertEquals(1, transport.faults.failFetches)
        assertEquals(1, transport.faults.failSubmits)
        assertEquals(1, transport.fetchAttempts, "a failed fetch is still an attempt")
        transport.configure { unreachable = false }
        assertEquals("injected fetch failure", assertFailsWith<SyncTransportFailure.Unreachable> { transport.fetchChanges(since = null) }.detail)

        // A poll-only backend logs the push it refuses.
        val pollOnly = InMemoryTransport(supportsPush = false)
        assertFailsWith<SyncTransportFailure.PushUnsupported> { pollOnly.submit(records(0), at = null) }
        assertEquals(1, pollOnly.submittedBatches.size)
        pollOnly.seed(records(0))
        assertEquals(1, pollOnly.fetchChanges(since = null).records.size)
    }

    @Test fun seedingBypassesEveryFault() = runTest {
        val transport = InMemoryTransport(supportsPush = false)
        transport.configure {
            unreachable = true
            rejectEverything = SyncRejection.Permanent("no")
            acceptAtMostPerBatch = 0
        }
        transport.seed(records(0, 1))
        assertEquals(listOf(id(0), id(1)), transport.snapshot.map { it.id })
        assertTrue(transport.submittedBatches.isEmpty(), "a seed is not a submission")
        // A seed overwrites unconditionally, whatever generation the record claims.
        transport.seed(listOf(records(0).single().copy(rev = "theirs", recordVersion = SyncRecordVersion(utf8("anything")))))
        assertEquals(listOf(id(1), id(0)), transport.snapshot.map { it.id })
        assertEquals(memoryVersion(3), transport.snapshot.last().recordVersion)
    }

    @Test fun configureChangesFaultsInOneStepAndFaultsIsAValue() = runTest {
        val transport = InMemoryTransport()
        val before = transport.faults
        transport.configure {
            failFetches = 2
            rejectRecords[id(1)] = SyncRejection.Permanent("p")
            latency = 2.seconds
        }
        assertEquals(InMemoryTransport.Faults.NONE, before, "a snapshot taken earlier does not move")
        val after = transport.faults
        assertEquals(2, after.failFetches)
        assertEquals(mapOf(id(1) to SyncRejection.Permanent("p")), after.rejectRecords)
        assertEquals(2.seconds, after.latency)
        assertEquals(after, InMemoryTransport.Faults(failFetches = 2, rejectRecords = mapOf(id(1) to SyncRejection.Permanent("p")), latency = 2.seconds))
        assertNotEquals(InMemoryTransport.Faults.NONE, after)

        // A later change starts from the current faults, and can clear a per-record rejection.
        transport.configure { rejectRecords.remove(id(1)) }
        assertEquals(2, transport.faults.failFetches)
        assertTrue(transport.faults.rejectRecords.isEmpty())
        transport.configure { rejectRecords = mutableMapOf(id(2) to SyncRejection.Conflict(null)) }
        assertEquals(setOf(id(2)), transport.faults.rejectRecords.keys)
    }

    // Resets

    @Test fun aLocalFullResyncResetIsCountedAndFailsAsOftenAsToldTo() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0))
        transport.configure { failLocalFullResets = 1 }

        val failure = assertFailsWith<SyncTransportFailure.Unreachable> { transport.resetForLocalFullResync(null, null) }
        assertEquals("injected full-resync failure", failure.detail)
        assertEquals(1, transport.localFullResetAttempts)
        assertEquals(0, transport.faults.failLocalFullResets)

        transport.resetForLocalFullResync(null, null)
        assertEquals(2, transport.localFullResetAttempts)
        // The backend's data is untouched: this resets a scheduler the fake does not have.
        assertEquals(1, transport.snapshot.size)
        assertEquals(SyncCursor("1"), transport.currentCursor)
    }

    @Test fun everyResetRefusesAnExpectedScopeBecauseTheFakeHasNone() = runTest {
        val transport = InMemoryTransport()
        val identity = SyncAccountIdentity(byteArrayOf(1))
        val dataset = SyncDatasetIdentity(byteArrayOf(2))
        val resets: List<suspend (SyncAccountIdentity?, SyncDatasetIdentity?) -> Unit> = listOf(
            transport::resetAfterAccountReview,
            transport::resetAfterCheckpointReview,
            transport::resetAfterRemoteDataResetReview,
            transport::resetForLocalFullResync,
        )
        for (reset in resets) {
            assertFailsWith<SyncTransportFailure.AccountChanged> { reset(identity, null) }
            assertFailsWith<SyncTransportFailure.AccountChanged> { reset(identity, dataset) }
            val failure = assertFailsWith<SyncTransportFailure.RemoteDataReset> { reset(null, dataset) }
            assertEquals("unexpected dataset scope", failure.detail)
        }
        assertEquals(0, transport.localFullResetAttempts, "a refused reset is not an attempt")

        // With nothing expected they are all safe no-ops, the reviewed remote-data reset included:
        // the fake opts in, where a stateful transport keeps the fail-closed default.
        for (reset in resets) reset(null, null)
        assertEquals(1, transport.localFullResetAttempts)
        transport.acknowledgeFetched(through = SyncCursor("1"))
        transport.acknowledgeFetched(through = null)
        transport.shutdown()
    }

    // Latency and cancellation

    @Test fun theDefaultSleeperSuspendsForTheLatencyWithoutBlocking() = runTest {
        val transport = InMemoryTransport()
        transport.configure { latency = 5.seconds }

        val before = currentTime
        transport.fetchChanges(since = null)
        transport.submit(records(0), at = null)
        // Virtual time: ten seconds passed and none were waited.
        assertEquals(10_000L, currentTime - before)
        assertEquals(1, transport.snapshot.size)
    }

    @Test fun latencyComesBeforeTheWorkAndACancelledCallDoesNothing() = runTest {
        val entered = CompletableDeferred<Unit>()
        val transport = InMemoryTransport(
            sleeper = {
                entered.complete(Unit)
                CompletableDeferred<Unit>().await()   // never returns
            },
        )
        transport.configure { latency = 1.milliseconds }

        val fetch = launch { transport.fetchChanges(since = null) }
        entered.await()
        fetch.cancelAndJoin()
        assertTrue(fetch.isCancelled)
        assertEquals(0, transport.fetchAttempts, "the fetch was cancelled before it reached the backend")

        val submitted = CompletableDeferred<Throwable?>()
        val submit = launch {
            try {
                transport.submit(records(0), at = null)
                submitted.complete(null)
            } catch (cancellation: CancellationException) {
                submitted.complete(cancellation)
                throw cancellation
            }
        }
        yield()
        submit.cancelAndJoin()
        // Cancellation reaches the caller as cancellation, never as a transport failure.
        assertTrue(submitted.await() is CancellationException)
        assertTrue(transport.submittedBatches.isEmpty())
        assertTrue(transport.snapshot.isEmpty())
    }

    // Events

    @Test fun eventsAreBufferedInOrderUntilSomeoneCollectsAndEndWhenTheStreamIsFinished() = runTest {
        val transport = InMemoryTransport()
        transport.seed(records(0))
        // Sent before anyone listens: nothing is dropped.
        transport.notify()
        transport.notify(SyncTransportEvent.AuthenticationRequired)
        transport.configure { invalidateCursorOnNextFetch = true }
        transport.fetchChanges(since = null)
        transport.notify(SyncTransportEvent.CursorInvalidated("by hand"))
        transport.finishEvents()

        assertEquals(
            listOf(
                SyncTransportEvent.ChangesAvailable,
                SyncTransportEvent.AuthenticationRequired,
                SyncTransportEvent.CursorInvalidated("injected cursor invalidation"),
                SyncTransportEvent.CursorInvalidated("by hand"),
            ),
            transport.events.toList(),
        )
        // Finished: a late hint is dropped quietly and a late collector ends at once.
        transport.notify()
        assertEquals(emptyList(), transport.events.toList())
        // The transport itself still works.
        assertEquals(1, transport.fetchChanges(since = null).records.size)
    }

    @Test fun anEventReachesExactlyOneCollector() = runTest {
        val transport = InMemoryTransport()
        val first = ArrayList<SyncTransportEvent>()
        val second = ArrayList<SyncTransportEvent>()
        val collectors = listOf(
            launch { transport.events.collect { first.add(it) } },
            launch { transport.events.collect { second.add(it) } },
        )
        yield()
        repeat(10) { transport.notify(SyncTransportEvent.CursorInvalidated("event $it")) }
        transport.finishEvents()
        collectors.forEach { it.join() }

        // Single-consumer, like the `AsyncStream` it stands in for: shared out, never duplicated.
        assertEquals(10, first.size + second.size)
        assertEquals((0 until 10).map { "event $it" }.toSet(), (first + second).map { (it as SyncTransportEvent.CursorInvalidated).reason }.toSet())
    }

    @Test fun cancellingACollectorLeavesTheStreamOpenForTheNext() = runTest {
        val transport = InMemoryTransport()
        val collector = launch { transport.events.collect { } }
        yield()
        collector.cancelAndJoin()

        transport.notify(SyncTransportEvent.AuthenticationRequired)
        assertEquals(SyncTransportEvent.AuthenticationRequired, transport.events.first())
    }

    // Threads

    @Test fun concurrentCallersNeverShareASequence() = runTest {
        val transport = InMemoryTransport(pageSize = 1_000)
        val batches = (0 until 16).map { batch -> records((0 until 25).map { batch * 25 + it }) }

        withContext(Dispatchers.Default) {
            batches.map { batch ->
                async {
                    transport.submit(batch, at = null)
                    transport.fetchChanges(since = null)
                }
            }.awaitAll()
        }

        val snapshot = transport.snapshot
        assertEquals(400, snapshot.size)
        assertEquals(400, snapshot.map { it.recordVersion }.toSet().size)
        assertEquals(SyncCursor("400"), transport.currentCursor)
        assertEquals(16, transport.submittedBatches.size)
        assertEquals(16, transport.fetchAttempts)
        assertEquals(400, transport.fetchChanges(since = null).records.size)
    }
}
