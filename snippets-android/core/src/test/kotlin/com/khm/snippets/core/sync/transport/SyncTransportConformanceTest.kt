package com.khm.snippets.core.sync.transport

import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.wire.SnippetCryptoSealer
import com.khm.snippets.core.wire.SyncEnvelope
import com.khm.snippets.core.wire.SyncKeyMaterial
import com.khm.snippets.core.wire.WireCodec
import com.khm.snippets.core.wire.WireFixtures
import com.khm.snippets.core.wire.WireRecord
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assume.assumeTrue
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

/**
 * What every [SyncTransport] owes the engine, written against the interface alone.
 *
 * A transport's test class extends this and supplies a transport on a fresh, empty
 * backend. The in-memory fake is the first subclass; the Git and Snippets Cloud
 * transports extend it next. Nothing here reads a concrete type, a fault switch or a
 * cursor's content.
 *
 * The suite covers: the shape of a fetch and of a submission, at-least-once delivery and
 * the cursor as a fixed point, per-record compare-and-swap in every direction, tombstones
 * as saves, replay of a submission, paging, the scope fields of every response, the
 * expected-scope rule of the resets, and the repeatable calls.
 */
abstract class SyncTransportConformanceTest {

    // What a subclass supplies

    /** A transport on a backend that holds nothing. Each call is a separate, empty backend. */
    protected abstract fun newTransport(): SyncTransport

    /**
     * Makes [records] the backend's current values as another device's writes, not through
     * [transport]. A record whose id the backend holds replaces that record; the others
     * are created. A transport with a second client can implement this with [submitAsPeer].
     */
    protected abstract suspend fun writeFromAnotherDevice(transport: SyncTransport, records: List<WireRecord>)

    /** A transport whose `supportsPush` is `false`, when the backend has such a mode. */
    protected open fun newPollOnlyTransport(): SyncTransport? = null

    /** How many records the paging test writes. Large enough to span several pages of the transport under test. */
    protected open val pagingRecordCount: Int get() = 25

    /** Runs a test body. Override for a transport that needs real time or a real dispatcher. */
    protected open fun runConformance(block: suspend CoroutineScope.() -> Unit) = runTest { block() }

    /**
     * Record [index] in its [revision]: a real sealed envelope, so a transport that reads
     * what it stores is given something readable. Override when the transport under test
     * needs another sealer. No `recordVersion`; see [built].
     */
    protected open fun record(index: Int, revision: Int = 0, deleted: Boolean = false): WireRecord {
        val live = SyncEnvelope.plain(
            WireFixtures.snippet(index, content = "record $index, revision $revision"),
            hlc = WireFixtures.clock(1_000L + revision, counter = index),
            origin = WireFixtures.THIS_DEVICE,
        )
        val envelope = if (deleted) live.tombstoned(WireFixtures.clock(2_000L + revision, counter = index), WireFixtures.THIS_DEVICE) else live
        return WireCodec.seal(envelope, sealer)
    }

    protected val sealer: SnippetCryptoSealer = SnippetCryptoSealer(
        SnippetCrypto.Keyring(WireFixtures.filled(0x51, 32), WireFixtures.filled(0x52, 32)), SyncKeyMaterial.SCOPE_ID,
    )

    protected fun id(index: Int): UUID = WireFixtures.id(index)

    // Helpers

    /** Everything one paged fetch delivered. */
    protected class Drained(val records: List<WireRecord>, val cursor: SyncCursor?, val pages: Int, val last: SyncFetch) {
        /** The last value delivered for each id, in first-delivery order: what the engine ends up holding. */
        val latest: Map<UUID, WireRecord> get() = LinkedHashMap<UUID, WireRecord>().also { map -> records.forEach { map[it.id] = it } }
    }

    /** Fetches from [since] until the transport says there is no more, as the engine does. */
    protected suspend fun drain(transport: SyncTransport, since: SyncCursor?): Drained {
        val records = ArrayList<WireRecord>()
        var cursor = since
        var pages = 0
        while (true) {
            val page = transport.fetchChanges(since = cursor)
            pages += 1
            if (page.replacesPriorPages) {
                assertTrue(page.isFullResync, "a page that replaces earlier pages starts a full resync")
                records.clear()
            }
            records.addAll(page.records)
            assertEquals(page.cursor == null, page.cursorKind == null, "a cursor has a kind and no cursor has none")
            cursor = page.cursor
            if (!page.hasMore) return Drained(records, cursor, pages, page)
            assertNotNull(page.cursor, "a page that promises more gives the place to continue from")
            if (pages > 10_000) fail("paging did not end")
        }
    }

    /** [record] as an update built on the generation the backend holds, or as a create when it holds none. */
    protected suspend fun built(transport: SyncTransport, record: WireRecord): WireRecord =
        record.copy(recordVersion = drain(transport, null).latest[record.id]?.recordVersion)

    /** Submits [records] through [peer] as updates of what the backend holds, and requires that all were stored. */
    protected suspend fun submitAsPeer(peer: SyncTransport, records: List<WireRecord>) {
        val current = drain(peer, null)
        val batch = records.map { it.copy(recordVersion = current.latest[it.id]?.recordVersion) }
        val submission = peer.submit(batch, at = current.cursor)
        assertEquals(records.map { it.id }, submission.acceptedIds, "the peer's writes were all stored")
    }

    private fun accepted(submission: SyncSubmission, index: Int): SyncSubmitOutcome.Accepted {
        val outcome = submission.results[index].outcome
        return outcome as? SyncSubmitOutcome.Accepted ?: fail("record $index was not accepted: $outcome")
    }

    private fun conflict(submission: SyncSubmission, index: Int): SyncRejection.Conflict {
        val outcome = submission.results[index].outcome
        val rejection = (outcome as? SyncSubmitOutcome.Rejected)?.rejection
        return rejection as? SyncRejection.Conflict ?: fail("record $index was not a conflict: $outcome")
    }

    /** Same id, rev, deletion flag and blob. The generation is the backend's and is compared separately. */
    private fun assertSameContent(expected: WireRecord, actual: WireRecord?, message: String) {
        assertNotNull(actual, message)
        assertEquals(expected.id, actual.id, message)
        assertEquals(expected.deleted, actual.deleted, message)
        assertContentEquals(expected.blob, actual.blob, message)
    }

    // Identity of the transport

    @Test fun theIdentifierIsStableAndThePollIntervalIsUsable() = runConformance {
        val transport = newTransport()
        assertTrue(transport.identifier.isNotEmpty())
        assertEquals(transport.identifier, transport.identifier)
        assertEquals(transport.identifier, newTransport().identifier, "the identifier names the kind of backend")
        assertTrue(transport.pollInterval > 0 && transport.pollInterval.isFinite(), "a missed hint must degrade to slow, not to never")
        transport.roundPacing?.let { pacing ->
            assertTrue(pacing.localChangeDelay >= 0)
            assertTrue(pacing.localChangeMaximumWait >= pacing.localChangeDelay)
            assertTrue(pacing.activationRefreshInterval >= 0)
        }
    }

    // Fetch

    @Test fun anEmptyBackendDeliversNothingAndDoesNotPromiseMore() = runConformance {
        val transport = newTransport()
        val everything = drain(transport, null)
        assertEquals(emptyList(), everything.records)
        assertFalse(everything.last.hasMore)
    }

    @Test fun aFetchFromNoCursorIsEverythingAndEveryRecordCarriesItsGeneration() = runConformance {
        val transport = newTransport()
        val written = listOf(record(0), record(1), record(2))
        writeFromAnotherDevice(transport, written)

        val everything = drain(transport, null)
        assertEquals(written.map { it.id }.toSet(), everything.latest.keys)
        for (record in written) {
            val fetched = everything.latest.getValue(record.id)
            assertSameContent(record, fetched, "record ${record.id}")
            assertNotNull(fetched.recordVersion, "an update is built on the fetched generation, so a fetch must carry one")
        }
        assertNotNull(everything.cursor, "after delivering records the backend says where to resume")
    }

    @Test fun theCursorIsAFixedPointWhileNothingChanges() = runConformance {
        val transport = newTransport()
        writeFromAnotherDevice(transport, listOf(record(0), record(1)))
        val first = drain(transport, null)

        val second = drain(transport, first.cursor)
        // At-least-once: a redelivery is allowed, a change is not.
        for (record in second.records) assertEquals(first.latest[record.id], record, "a quiet backend delivered something new")
        assertFalse(second.last.isFullResync, "an honoured cursor is not a resync")
        assertNotNull(second.cursor, "a quiet fetch still says where it is")

        val third = drain(transport, second.cursor)
        assertEquals(second.cursor, third.cursor)
        assertFalse(third.last.hasMore)
    }

    @Test fun changesAfterACursorAreDeliveredFromThatCursor() = runConformance {
        val transport = newTransport()
        writeFromAnotherDevice(transport, listOf(record(0), record(1)))
        val before = drain(transport, null)

        val created = record(2)
        val updated = record(0, revision = 1)
        writeFromAnotherDevice(transport, listOf(created, updated))

        val delta = drain(transport, before.cursor)
        assertSameContent(created, delta.latest[created.id], "the record created after the cursor")
        assertSameContent(updated, delta.latest[updated.id], "the record updated after the cursor")
        assertNotEquals(
            before.latest.getValue(updated.id).recordVersion, delta.latest.getValue(updated.id).recordVersion,
            "a new value is a new generation",
        )
        // And a fetch from no cursor still shows the whole dataset, with the newest values.
        val everything = drain(transport, null)
        assertEquals(setOf(id(0), id(1), id(2)), everything.latest.keys)
        assertSameContent(updated, everything.latest[updated.id], "the newest value wins in a snapshot")
    }

    @Test fun aRepeatedFetchFromAnOlderCursorDeliversAtLeastTheSameChanges() = runConformance {
        val transport = newTransport()
        writeFromAnotherDevice(transport, listOf(record(0)))
        val before = drain(transport, null)
        writeFromAnotherDevice(transport, listOf(record(1), record(2)))

        // The engine persists a cursor only after applying the page. After a crash it asks again.
        val first = drain(transport, before.cursor)
        val again = drain(transport, before.cursor)
        assertTrue(again.latest.keys.containsAll(listOf(id(1), id(2))))
        assertEquals(first.latest.filterKeys { it != id(0) }, again.latest.filterKeys { it != id(0) })
    }

    @Test fun aCursorTheBackendNeverIssuedIsNotAnsweredWithSilence() = runConformance {
        val transport = newTransport()
        writeFromAnotherDevice(transport, listOf(record(0), record(1)))

        val drained = drain(transport, SyncCursor("a cursor this backend never issued"))
        // Sending too much costs bandwidth; sending too little looks like deletions.
        assertEquals(setOf(id(0), id(1)), drained.latest.keys)
    }

    @Test fun pagingDeliversEverythingAndEnds() = runConformance {
        val transport = newTransport()
        val written = (0 until pagingRecordCount).map { record(it) }
        writeFromAnotherDevice(transport, written)

        val everything = drain(transport, null)
        assertEquals(written.map { it.id }.toSet(), everything.latest.keys)
        for (record in written) assertSameContent(record, everything.latest[record.id], "record ${record.id}")
        // Nothing is left behind the last page.
        assertEquals(emptySet(), drain(transport, everything.cursor).latest.keys - written.map { it.id }.toSet())
    }

    // Submit

    @Test fun aCreateIsAcceptedWithItsGenerationAndComesBackOnAFetch() = runConformance {
        val transport = newTransport()
        val batch = listOf(record(0), record(1))

        val submission = transport.submit(batch, at = null)
        assertEquals(batch.map { it.id }, submission.results.map { it.id }, "one result per record, in the submitted order")
        assertEquals(batch.map { it.id }, submission.acceptedIds)
        assertFalse(submission.isPartial)

        val everything = drain(transport, null)
        for ((index, record) in batch.withIndex()) {
            val outcome = accepted(submission, index)
            val fetched = everything.latest[record.id]
            assertSameContent(record, fetched, "record $index")
            assertEquals(outcome.rev, fetched!!.rev, "the accepted rev is what the backend holds")
            assertEquals(outcome.recordVersion, fetched.recordVersion, "the accepted generation is what the backend holds")
        }
    }

    @Test fun anEmptyBatchIsAnEmptyResult() = runConformance {
        val transport = newTransport()
        val submission = transport.submit(emptyList(), at = null)
        assertEquals(emptyList(), submission.results)
        assertEquals(emptyList(), drain(transport, null).records)
    }

    @Test fun anUpdateBuiltOnTheFetchedGenerationIsAccepted() = runConformance {
        val transport = newTransport()
        writeFromAnotherDevice(transport, listOf(record(0)))
        val before = drain(transport, null)
        val base = before.latest.getValue(id(0))

        val update = record(0, revision = 1).copy(recordVersion = base.recordVersion)
        val submission = transport.submit(listOf(update), at = before.cursor)
        val outcome = accepted(submission, 0)
        assertNotEquals(base.recordVersion, outcome.recordVersion, "a new value is a new generation")

        val after = drain(transport, null).latest.getValue(id(0))
        assertSameContent(update, after, "the update is what the backend holds")
        assertEquals(outcome.recordVersion, after.recordVersion)
    }

    @Test fun anUpdateBuiltOnAnAcceptedGenerationIsAcceptedWithoutAFetchInBetween() = runConformance {
        val transport = newTransport()
        val created = accepted(transport.submit(listOf(record(0)), at = null), 0)

        val second = record(0, revision = 1).copy(recordVersion = created.recordVersion)
        val updated = accepted(transport.submit(listOf(second), at = null), 0)
        val third = record(0, revision = 2).copy(recordVersion = updated.recordVersion)
        accepted(transport.submit(listOf(third), at = null), 0)

        assertSameContent(third, drain(transport, null).latest[id(0)], "the last update is what the backend holds")
    }

    @Test fun anUpdateBuiltOnAStaleGenerationIsAConflictAndOverwritesNothing() = runConformance {
        val transport = newTransport()
        val created = accepted(transport.submit(listOf(record(0)), at = null), 0)
        val current = record(0, revision = 1).copy(recordVersion = created.recordVersion)
        val currentOutcome = accepted(transport.submit(listOf(current), at = null), 0)

        // Built on the generation that revision 1 replaced.
        val stale = record(0, revision = 2).copy(recordVersion = created.recordVersion)
        val submission = transport.submit(listOf(stale), at = null)
        assertEquals(listOf(id(0)), submission.results.map { it.id })
        val rejection = conflict(submission, 0)
        assertTrue(rejection.isRetryable)
        rejection.remote?.let { remote ->
            assertSameContent(current, remote, "a disclosed conflict discloses the record the backend holds")
            assertEquals(currentOutcome.recordVersion, remote.recordVersion, "with the generation to build the retry on")
        }

        val held = drain(transport, null).latest.getValue(id(0))
        assertSameContent(current, held, "the stale write did not land")
        assertEquals(currentOutcome.recordVersion, held.recordVersion)
    }

    /** `pushingOverARecordWrittenAfterOurCursorIsAConflict` in `WireTests.swift`. */
    @Test fun aCreateOverARecordAnotherDeviceWroteIsAConflictUntilItIsRebuiltOnTheirs() = runConformance {
        val transport = newTransport()
        val staleCursor = drain(transport, null).cursor
        val theirs = record(0, revision = 7)
        writeFromAnotherDevice(transport, listOf(theirs))

        // Our view of the world predates their write: we still think the record is new.
        val mine = record(0, revision = 1)
        val submission = transport.submit(listOf(mine), at = staleCursor)
        assertEquals(emptyList(), submission.acceptedIds)
        conflict(submission, 0).remote?.let { assertSameContent(theirs, it, "the authoritative record") }
        assertSameContent(theirs, drain(transport, null).latest[id(0)], "their write was not overwritten")

        // Reading first, then submitting on what was read, succeeds.
        val fresh = drain(transport, staleCursor)
        val retried = mine.copy(recordVersion = fresh.latest.getValue(id(0)).recordVersion)
        assertEquals(listOf(id(0)), transport.submit(listOf(retried), at = fresh.cursor).acceptedIds)
        assertSameContent(mine, drain(transport, null).latest[id(0)], "the rebuilt write landed")
    }

    @Test fun anUpdateOfARecordTheBackendDoesNotHoldIsAConflict() = runConformance {
        val transport = newTransport()
        // A real generation, of another record.
        val generation = accepted(transport.submit(listOf(record(0)), at = null), 0).recordVersion

        val orphan = record(1).copy(recordVersion = generation)
        conflict(transport.submit(listOf(orphan), at = null), 0)
        assertEquals(setOf(id(0)), drain(transport, null).latest.keys, "nothing was created")
    }

    @Test fun aReplayedSubmissionIsAConflictToMergeAndNeverASecondWrite() = runConformance {
        val transport = newTransport()
        val create = record(0)
        val first = accepted(transport.submit(listOf(create), at = null), 0)

        // The acknowledgement was lost: the engine submits the same batch again from its journal.
        val replay = transport.submit(listOf(create), at = null)
        conflict(replay, 0).remote?.let { remote ->
            assertSameContent(create, remote, "the conflict discloses the write that did land")
            assertEquals(first.recordVersion, remote.recordVersion)
        }
        val held = drain(transport, null)
        assertEquals(setOf(id(0)), held.latest.keys)
        assertEquals(first.recordVersion, held.latest.getValue(id(0)).recordVersion, "the replay did not write again")
    }

    @Test fun aDeletionIsStoredAsARecordAndStaysInTheFeed() = runConformance {
        val transport = newTransport()
        val created = accepted(transport.submit(listOf(record(0), record(1)), at = null), 0)
        val before = drain(transport, null)

        val tombstone = record(0, revision = 1, deleted = true).copy(recordVersion = created.recordVersion)
        assertTrue(tombstone.deleted)
        accepted(transport.submit(listOf(tombstone), at = before.cursor), 0)

        // In a delta and in a snapshot: present, and deleted.
        for (fetch in listOf(drain(transport, before.cursor), drain(transport, null))) {
            val held = fetch.latest[id(0)]
            assertSameContent(tombstone, held, "a tombstone is a record, never an absence")
            assertTrue(held!!.deleted)
        }
        assertFalse(drain(transport, null).latest.getValue(id(1)).deleted)

        // And it can be written over like any record: a recreation is an update of the tombstone.
        val heldTombstone = drain(transport, null).latest.getValue(id(0))
        val recreated = record(0, revision = 2).copy(recordVersion = heldTombstone.recordVersion)
        accepted(transport.submit(listOf(recreated), at = null), 0)
        assertFalse(drain(transport, null).latest.getValue(id(0)).deleted)
    }

    @Test fun aBatchWithAConflictReportsEveryRecordInOrderAndStoresExactlyWhatItSaysItStored() = runConformance {
        val transport = newTransport()
        val created = accepted(transport.submit(listOf(record(0)), at = null), 0)
        accepted(transport.submit(listOf(record(0, revision = 1).copy(recordVersion = created.recordVersion)), at = null), 0)
        val before = drain(transport, null)

        val batch = listOf(
            record(1),
            record(0, revision = 2).copy(recordVersion = created.recordVersion),   // stale
            record(2),
        )
        val submission = transport.submit(batch, at = before.cursor)
        assertEquals(batch.map { it.id }, submission.results.map { it.id }, "one result per record, in the submitted order")
        conflict(submission, 1)

        val after = drain(transport, null)
        for ((index, record) in batch.withIndex()) {
            when (val outcome = submission.results[index].outcome) {
                is SyncSubmitOutcome.Accepted -> {
                    assertSameContent(record, after.latest[record.id], "record $index was reported stored")
                    assertEquals(outcome.recordVersion, after.latest.getValue(record.id).recordVersion)
                }
                is SyncSubmitOutcome.Rejected ->
                    assertEquals(before.latest[record.id], after.latest[record.id], "record $index was reported refused")
            }
        }
        assertEquals(submission.acceptedIds.isNotEmpty(), submission.isPartial)
    }

    @Test fun aPollOnlyTransportRefusesAPushAndStillFetches() = runConformance {
        val transport = newPollOnlyTransport()
        assumeTrue("this backend has no poll-only mode", transport != null)
        transport!!
        assertFalse(transport.supportsPush)
        assertEquals(
            SyncTransportFailure.PushUnsupported(),
            assertFailsWith<SyncTransportFailure.PushUnsupported> { transport.submit(listOf(record(0)), at = null) },
        )
        assertEquals(emptyList(), drain(transport, null).records)
    }

    // Scope

    @Test fun everyResponseCarriesTheScopeThePreflightEstablished() = runConformance {
        val transport = newTransport()
        val preflight = transport.preflightScope()
        assertNull(preflight.checkpointIssue, "a fresh transport has no checkpoint to disagree with")
        assertEquals(transport.resolveAccountIdentity(), preflight.identity)
        assertEquals(preflight, transport.preflightScope(), "a preflight changes nothing and can be repeated")

        val submission = transport.submit(listOf(record(0)), at = null)
        assertEquals(preflight.identity, submission.accountIdentity)
        assertEquals(preflight.datasetIdentity, submission.datasetIdentity)

        var cursor: SyncCursor? = null
        do {
            val page = transport.fetchChanges(since = cursor)
            assertEquals(preflight.identity, page.accountIdentity)
            assertEquals(preflight.datasetIdentity, page.datasetIdentity)
            cursor = page.cursor
        } while (page.hasMore)
    }

    @Test fun everyResetRefusesAScopeThatIsNotTheCurrentOne() = runConformance {
        val transport = newTransport()
        transport.submit(listOf(record(0)), at = null)
        val preflight = transport.preflightScope()
        val otherAccount = SyncAccountIdentity(WireFixtures.utf8("an account this transport is not scoped to"))
        val otherDataset = SyncDatasetIdentity(WireFixtures.utf8("a dataset this transport is not scoped to"))

        val resets: List<Pair<String, suspend (SyncAccountIdentity?, SyncDatasetIdentity?) -> Unit>> = listOf(
            "resetAfterAccountReview" to transport::resetAfterAccountReview,
            "resetAfterCheckpointReview" to transport::resetAfterCheckpointReview,
            "resetAfterRemoteDataResetReview" to transport::resetAfterRemoteDataResetReview,
            "resetForLocalFullResync" to transport::resetForLocalFullResync,
        )
        for ((name, reset) in resets) {
            assertFailsWith<SyncTransportFailure>("$name with another account") { reset(otherAccount, preflight.datasetIdentity) }
            assertFailsWith<SyncTransportFailure>("$name with another dataset") { reset(preflight.identity, otherDataset) }
        }
        // A refused reset destroyed nothing.
        assertEquals(setOf(id(0)), drain(transport, null).latest.keys)
    }

    @Test fun aResetForTheCurrentScopeCanBeRepeatedAndLeavesTheRemoteDataAlone() = runConformance {
        val transport = newTransport()
        transport.submit(listOf(record(0), record(1)), at = null)
        val preflight = transport.preflightScope()

        repeat(2) {
            transport.resetAfterAccountReview(preflight.identity, preflight.datasetIdentity)
            transport.resetAfterCheckpointReview(preflight.identity, preflight.datasetIdentity)
            transport.resetForLocalFullResync(preflight.identity, preflight.datasetIdentity)
            // Restoring a reset remote is either the transport's stated ability or refused; never anything else.
            try {
                transport.resetAfterRemoteDataResetReview(preflight.identity, preflight.datasetIdentity)
            } catch (_: SyncTransportFailure.RemoteDataReset) {
                // The fail-closed default.
            }
        }
        // After a reset of the transport's own progress, a fetch from no cursor is the whole dataset.
        assertEquals(setOf(id(0), id(1)), drain(transport, null).latest.keys)
    }

    // Repeatable calls

    @Test fun acknowledgingAFetchPositionCanBeRepeatedAndChangesNothingTheEngineSees() = runConformance {
        val transport = newTransport()
        writeFromAnotherDevice(transport, listOf(record(0), record(1)))
        val first = drain(transport, null)

        transport.acknowledgeFetched(through = first.cursor)
        transport.acknowledgeFetched(through = first.cursor)
        transport.acknowledgeFetched(through = null)

        val after = drain(transport, first.cursor)
        for (record in after.records) assertEquals(first.latest[record.id], record)
        assertEquals(setOf(id(0), id(1)), drain(transport, null).latest.keys)
    }

    @Test fun shutdownCanBeRepeated() = runConformance {
        val transport = newTransport()
        transport.submit(listOf(record(0)), at = null)
        transport.shutdown()
        transport.shutdown()
    }

    @Test fun theEventStreamCanBeCollectedAndLetGo() = runConformance {
        val transport = newTransport()
        val seen = ArrayList<SyncTransportEvent>()
        val collector = launch { transport.events.collect { seen.add(it) } }
        yield()
        // Work while a collector is attached, then leave: cancelling a collector must not hang or close the transport.
        transport.submit(listOf(record(0)), at = null)
        collector.cancelAndJoin()
        assertEquals(setOf(id(0)), drain(transport, null).latest.keys)
    }
}
