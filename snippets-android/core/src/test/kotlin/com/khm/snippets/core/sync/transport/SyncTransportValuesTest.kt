package com.khm.snippets.core.sync.transport

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.wire.WireFixtures.id
import com.khm.snippets.core.wire.WireFixtures.utf8
import com.khm.snippets.core.wire.WireRecord
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The value types of `SyncTransport.swift`: the opaque tokens and their closed JSON form
 * (`opaqueVersionUsesClosedStrictVersionedCodable` in `SyncRecordCASTests.swift`), the
 * fetch and submission values, the rejection and failure taxonomy, and the protocol's
 * fail-closed defaults.
 */
class SyncTransportValuesTest {

    private fun json(text: String): JsonValue = CanonicalJson.parse(utf8(text))

    // SyncRecordCASTests.swift

    @Test fun opaqueVersionUsesClosedStrictVersionedCodable() {
        val expected = SyncRecordVersion(byteArrayOf(0, 1, 2, 0xFE.toByte(), 0xFF.toByte()))
        val encoded = expected.toJsonValue()
        val members = encoded.objectOrNull!!

        assertEquals(setOf("schemaVersion", "data"), members.keys)
        assertEquals(SyncRecordVersion.CURRENT_SCHEMA_VERSION.toLong(), members.getValue("schemaVersion").longOrNull)
        assertEquals("AAEC/v8=", members.getValue("data").textOrNull)
        assertEquals(expected, SyncRecordVersion.fromJsonValue(encoded))
        // Through bytes, as a base stores it.
        assertEquals("{\"data\":\"AAEC/v8=\",\"schemaVersion\":1}", CanonicalJson.encodeToString(encoded))
        assertEquals(expected, SyncRecordVersion.fromJsonValue(json("{\"schemaVersion\":1,\"data\":\"AAEC/v8=\"}")))

        val invalidDocuments = listOf(
            "{}",
            "{\"schemaVersion\":1}",
            "{\"data\":\"AA==\"}",
            "{\"schemaVersion\":null,\"data\":\"AA==\"}",
            "{\"schemaVersion\":1,\"data\":null}",
            "{\"schemaVersion\":\"1\",\"data\":\"AA==\"}",
            "{\"schemaVersion\":1,\"data\":7}",
            "{\"schemaVersion\":0,\"data\":\"AA==\"}",
            "{\"schemaVersion\":2,\"data\":\"AA==\"}",
            "{\"schemaVersion\":1,\"data\":\"%%%\"}",
            "{\"schemaVersion\":1,\"data\":\"AA==\",\"extra\":true}",
            // Not in the Swift list: other top-level types, and spellings a lenient decoder lets through.
            "[]", "null", "\"AA==\"", "1",
            "{\"schemaVersion\":1.0,\"data\":\"AA==\"}",
            "{\"schemaVersion\":true,\"data\":\"AA==\"}",
            "{\"schemaVersion\":1,\"data\":\"AA\"}",
            "{\"schemaVersion\":1,\"data\":\"AB==\"}",
            "{\"schemaVersion\":1,\"data\":\"AA==\\n\"}",
            "{\"schemaVersion\":1,\"data\":\"AA-_\"}",
            "{\"schemaVersion\":1,\"data\":[\"AA==\"]}",
            "{\"schemaversion\":1,\"data\":\"AA==\"}",
        )
        for (document in invalidDocuments) {
            assertFailsWith<SyncTokenCodingFailure.Decoding>("must reject $document") {
                SyncRecordVersion.fromJsonValue(json(document))
            }
        }

        val oversized = JsonValue.obj(
            "schemaVersion" to JsonValue.of(1),
            "data" to JsonValue.of(Base64Std.encode(ByteArray(2 * 1_024 * 1_024) { 0xA5.toByte() })),
        )
        assertFailsWith<SyncTokenCodingFailure.Decoding> { SyncRecordVersion.fromJsonValue(oversized) }
        // The limit is on the decoded bytes, and writing is refused at the same limit.
        val atLimit = SyncRecordVersion(ByteArray(SyncRecordVersion.MAXIMUM_DATA_BYTES))
        assertEquals(atLimit, SyncRecordVersion.fromJsonValue(atLimit.toJsonValue()))
        assertFailsWith<SyncTokenCodingFailure.Encoding> {
            SyncRecordVersion(ByteArray(SyncRecordVersion.MAXIMUM_DATA_BYTES + 1)).toJsonValue()
        }
        // An empty generation is a value like any other.
        assertEquals(SyncRecordVersion(ByteArray(0)), SyncRecordVersion.fromJsonValue(json("{\"schemaVersion\":1,\"data\":\"\"}")))
    }

    // The other tokens

    @Test fun accountAndDatasetIdentitiesUseTheSameClosedFormAndAreNeverEmpty() {
        val bytes = byteArrayOf(1, 2, 3)
        val account = SyncAccountIdentity(bytes)
        val dataset = SyncDatasetIdentity(bytes)
        assertEquals("{\"data\":\"AQID\",\"schemaVersion\":1}", CanonicalJson.encodeToString(account.toJsonValue()))
        assertEquals("{\"data\":\"AQID\",\"schemaVersion\":1}", CanonicalJson.encodeToString(dataset.toJsonValue()))
        assertEquals(account, SyncAccountIdentity.fromJsonValue(account.toJsonValue()))
        assertEquals(dataset, SyncDatasetIdentity.fromJsonValue(dataset.toJsonValue()))
        assertEquals(1, account.schemaVersion)
        assertEquals(1, dataset.schemaVersion)

        val invalidDocuments = listOf(
            "{}", "{\"schemaVersion\":1}", "{\"data\":\"AQID\"}",
            "{\"schemaVersion\":2,\"data\":\"AQID\"}", "{\"schemaVersion\":0,\"data\":\"AQID\"}",
            "{\"schemaVersion\":null,\"data\":\"AQID\"}", "{\"schemaVersion\":1,\"data\":null}",
            "{\"schemaVersion\":1,\"data\":\"\"}",                       // empty
            "{\"schemaVersion\":1,\"data\":\"AQID\",\"extra\":1}",
            "{\"schemaVersion\":1,\"data\":\"%%%\"}",
            "\"AQID\"", "null",
        )
        for (document in invalidDocuments) {
            assertFailsWith<SyncTokenCodingFailure.Decoding>(document) { SyncAccountIdentity.fromJsonValue(json(document)) }
            assertFailsWith<SyncTokenCodingFailure.Decoding>(document) { SyncDatasetIdentity.fromJsonValue(json(document)) }
        }
        val tooLong = JsonValue.obj(
            "schemaVersion" to JsonValue.of(1), "data" to JsonValue.of(Base64Std.encode(ByteArray(1_025))),
        )
        assertFailsWith<SyncTokenCodingFailure.Decoding> { SyncAccountIdentity.fromJsonValue(tooLong) }
        assertFailsWith<SyncTokenCodingFailure.Decoding> { SyncDatasetIdentity.fromJsonValue(tooLong) }
        assertEquals(1_024, SyncAccountIdentity(ByteArray(1_024)).data.size)
        assertEquals(1_024, SyncDatasetIdentity(ByteArray(1_024)).data.size)

        // Swift's preconditions.
        for (count in listOf(0, 1_025)) {
            assertFailsWith<IllegalArgumentException> { SyncAccountIdentity(ByteArray(count)) }
            assertFailsWith<IllegalArgumentException> { SyncDatasetIdentity(ByteArray(count)) }
        }
    }

    @Test fun theByteTokensAreImmutableValuesThatNeverPrintTheirBytes() {
        val source = utf8("account-digest")
        val account = SyncAccountIdentity(source)
        val dataset = SyncDatasetIdentity(source)
        val version = SyncRecordVersion(source)
        source.fill(0)
        account.data.fill(0)
        dataset.data.fill(0)
        version.data.fill(0)

        assertContentEquals(utf8("account-digest"), account.data)
        assertContentEquals(utf8("account-digest"), dataset.data)
        assertContentEquals(utf8("account-digest"), version.data)
        assertEquals(14, version.byteCount)

        assertEquals(account, SyncAccountIdentity(utf8("account-digest")))
        assertEquals(account.hashCode(), SyncAccountIdentity(utf8("account-digest")).hashCode())
        assertNotEquals(account, SyncAccountIdentity(utf8("account-digesu")))
        assertEquals(dataset, SyncDatasetIdentity(utf8("account-digest")))
        assertEquals(version, SyncRecordVersion(utf8("account-digest")))
        assertNotEquals(version, SyncRecordVersion(utf8("account-digest2")))
        // The three are different types even over the same bytes.
        assertNotEquals<Any>(account, dataset)
        assertNotEquals<Any>(account, version)

        for (description in listOf(account.toString(), dataset.toString(), version.toString())) {
            assertFalse(description.contains("account"), description)
            assertFalse(description.contains("YWNjb3VudC1kaWdlc3Q"), description)
            assertFalse(description.contains("6163636f756e74"), description)
        }
    }

    @Test fun aCursorIsAnOpaqueStringThatDoesNotPrintItself() {
        val cursor = SyncCursor("dataset-7f3a/commit-0badcafe")
        assertEquals("dataset-7f3a/commit-0badcafe", cursor.rawValue)
        assertEquals(cursor, SyncCursor("dataset-7f3a/commit-0badcafe"))
        assertNotEquals(cursor, SyncCursor("dataset-7f3a/commit-0badcaff"))
        assertEquals(setOf(cursor), setOf(cursor, SyncCursor("dataset-7f3a/commit-0badcafe")))
        assertFalse(cursor.toString().contains("0badcafe"))
        assertFalse("$cursor".contains("dataset"))

        // One JSON string, as Swift's single-value container.
        assertEquals("\"dataset-7f3a/commit-0badcafe\"", CanonicalJson.encodeToString(cursor.toJsonValue()))
        assertEquals(cursor, SyncCursor.fromJsonValue(json("\"dataset-7f3a/commit-0badcafe\"")))
        assertEquals(SyncCursor(""), SyncCursor.fromJsonValue(json("\"\"")))
        for (document in listOf("null", "7", "true", "[\"c\"]", "{\"rawValue\":\"c\"}")) {
            assertFailsWith<SyncTokenCodingFailure.Decoding>(document) { SyncCursor.fromJsonValue(json(document)) }
        }
    }

    @Test fun theCursorKindVocabularyIsClosed() {
        assertEquals(listOf("legacy", "cloudKitSyncEngine"), SyncCursorKind.entries.map { it.rawValue })
        assertEquals(SyncCursorKind.LEGACY, SyncCursorKind.fromRawValue("legacy"))
        assertEquals(SyncCursorKind.CLOUD_KIT_SYNC_ENGINE, SyncCursorKind.fromRawValue("cloudKitSyncEngine"))
        for (unknown in listOf("", "Legacy", "LEGACY", "git", "cloudkitsyncengine")) {
            assertNull(SyncCursorKind.fromRawValue(unknown), unknown)
        }
    }

    // Fetch and submission

    private fun record(index: Int, version: String? = null) = WireRecord(
        id = id(index), rev = "rev-$index", deleted = false, blob = utf8("blob-$index"),
        recordVersion = version?.let { SyncRecordVersion(utf8(it)) },
    )

    @Test fun aFetchWithACursorAndNoKindIsLegacyAndAFetchWithoutACursorHasNoKind() {
        assertEquals(SyncCursorKind.LEGACY, SyncFetch(emptyList(), SyncCursor("1")).cursorKind)
        assertEquals(
            SyncCursorKind.CLOUD_KIT_SYNC_ENGINE,
            SyncFetch(emptyList(), SyncCursor("1"), cursorKind = SyncCursorKind.CLOUD_KIT_SYNC_ENGINE).cursorKind,
        )
        assertNull(SyncFetch(emptyList(), null).cursorKind)
        assertNull(SyncFetch(emptyList(), null, cursorKind = SyncCursorKind.CLOUD_KIT_SYNC_ENGINE).cursorKind)

        // The defaults.
        val fetch = SyncFetch(listOf(record(0)), SyncCursor("1"))
        assertFalse(fetch.hasMore)
        assertFalse(fetch.isFullResync)
        assertFalse(fetch.replacesPriorPages)
        assertNull(fetch.accountIdentity)
        assertNull(fetch.datasetIdentity)

        // `copy` keeps the rule.
        assertNull(fetch.copy(cursor = null).cursorKind)
        assertEquals(SyncCursorKind.LEGACY, fetch.copy(cursor = null).copy(cursor = SyncCursor("2")).cursorKind)
    }

    @Test fun aFetchIsAnImmutableValue() {
        val records = mutableListOf(record(0), record(1))
        val identity = SyncAccountIdentity(byteArrayOf(9))
        val fetch = SyncFetch(records, SyncCursor("2"), hasMore = true, accountIdentity = identity)
        records.clear()
        assertEquals(listOf(id(0), id(1)), fetch.records.map { it.id })
        assertFailsWith<UnsupportedOperationException> { (fetch.records as MutableList<WireRecord>).clear() }

        val same = SyncFetch(listOf(record(0), record(1)), SyncCursor("2"), hasMore = true, accountIdentity = SyncAccountIdentity(byteArrayOf(9)))
        assertEquals(fetch, same)
        assertEquals(fetch.hashCode(), same.hashCode())
        assertNotEquals(fetch, same.copy(hasMore = false))
        assertNotEquals(fetch, same.copy(isFullResync = true))
        assertNotEquals(fetch, same.copy(replacesPriorPages = true))
        assertNotEquals(fetch, same.copy(cursor = SyncCursor("3")))
        assertNotEquals(fetch, same.copy(records = listOf(record(0))))
        assertNotEquals(fetch, same.copy(accountIdentity = null))
        assertNotEquals(fetch, same.copy(datasetIdentity = SyncDatasetIdentity(byteArrayOf(1))))
        assertFalse(fetch.toString().contains("blob"))
    }

    @Test fun aSubmissionKeepsBatchOrderAndReportsAPartialBatch() {
        val version = SyncRecordVersion(utf8("v"))
        val accepted = SyncSubmitOutcome.Accepted(rev = "r", recordVersion = version)
        val rateLimited = SyncRejection.RateLimited(retryAfter = 30.0)
        val submission = SyncSubmission(
            results = listOf(
                SyncSubmitResult(id(0), accepted),
                SyncSubmitResult(id(1), SyncSubmitOutcome.Rejected(rateLimited)),
                // The same id twice stays two results: a map would collapse them.
                SyncSubmitResult(id(0), SyncSubmitOutcome.Rejected(SyncRejection.Conflict(remote = null))),
                SyncSubmitResult(id(2), accepted),
            ),
            cursor = SyncCursor("9"),
        )
        assertEquals(listOf(id(0), id(2)), submission.acceptedIds)
        assertEquals(
            listOf(
                SyncSubmission.RejectedRecord(id(1), rateLimited),
                SyncSubmission.RejectedRecord(id(0), SyncRejection.Conflict(remote = null)),
            ),
            submission.rejections,
        )
        assertTrue(submission.isPartial)
        assertNull(submission.accountIdentity)
        assertNull(submission.datasetIdentity)

        val allAccepted = SyncSubmission(listOf(SyncSubmitResult(id(0), accepted)), cursor = null)
        val allRejected = SyncSubmission(listOf(SyncSubmitResult(id(0), SyncSubmitOutcome.Rejected(rateLimited))), cursor = null)
        val empty = SyncSubmission(emptyList(), cursor = null)
        for (whole in listOf(allAccepted, allRejected, empty)) assertFalse(whole.isPartial)

        assertEquals(allAccepted, SyncSubmission(listOf(SyncSubmitResult(id(0), accepted)), cursor = null))
        assertNotEquals(allAccepted, allRejected)
        assertNotEquals(allAccepted, allAccepted.copy(cursor = SyncCursor("1")))
        assertNotEquals(allAccepted, allAccepted.copy(accountIdentity = SyncAccountIdentity(byteArrayOf(1))))
        assertNotEquals(
            SyncSubmitOutcome.Accepted("r", version), SyncSubmitOutcome.Accepted("r", SyncRecordVersion(utf8("w"))),
        )
    }

    @Test fun aScopePreflightDefaultsToNoDatasetNoLegacyIdentitiesAndNoIssue() {
        val identity = SyncAccountIdentity(byteArrayOf(1))
        val preflight = SyncScopePreflight(identity = identity)
        assertEquals(identity, preflight.identity)
        assertNull(preflight.datasetIdentity)
        assertEquals(emptyList(), preflight.legacyAccountIdentities)
        assertNull(preflight.checkpointIssue)
        assertEquals(preflight, SyncScopePreflight(SyncAccountIdentity(byteArrayOf(1))))
        assertNotEquals(preflight, preflight.copy(checkpointIssue = SyncScopePreflight.CheckpointIssue.UNREADABLE))
        assertNotEquals(preflight, preflight.copy(checkpointIssue = SyncScopePreflight.CheckpointIssue.ACCOUNT_CHANGED))
        assertEquals(2, SyncScopePreflight.CheckpointIssue.entries.size)
    }

    @Test fun eventsAndPacingAreValues() {
        assertEquals(SyncTransportEvent.CursorInvalidated("why"), SyncTransportEvent.CursorInvalidated("why"))
        assertNotEquals(SyncTransportEvent.CursorInvalidated("why"), SyncTransportEvent.CursorInvalidated("other"))
        assertNotEquals<SyncTransportEvent>(SyncTransportEvent.ChangesAvailable, SyncTransportEvent.AuthenticationRequired)

        val git = SyncRoundPacing(localChangeDelay = 30.0, localChangeMaximumWait = 120.0, activationRefreshInterval = 30.0)
        assertEquals(git, SyncRoundPacing(30.0, 120.0, 30.0))
        assertNotEquals(git, git.copy(localChangeMaximumWait = 60.0))
    }

    // Rejections and failures

    @Test fun onlyAConflictAndARateLimitAreRetriedWithoutTheUser() {
        assertTrue(SyncRejection.Conflict(remote = null).isRetryable)
        assertTrue(SyncRejection.Conflict(remote = record(0)).isRetryable)
        assertTrue(SyncRejection.RateLimited(retryAfter = 1.0).isRetryable)
        assertFalse(SyncRejection.AuthenticationRequired(detail = "expired").isRetryable)
        assertFalse(SyncRejection.Permanent(detail = "too large").isRetryable)
    }

    @Test fun rejectionsDescribeThemselvesAsSwiftDoes() {
        assertEquals("the backend has a newer version of this snippet", SyncRejection.Conflict(remote = null).description)
        assertEquals(
            "the backend has a newer version of this snippet (rev-3)", SyncRejection.Conflict(remote = record(3)).description,
        )
        assertEquals("the backend is rate-limiting; retry in 30s", SyncRejection.RateLimited(30.0).description)
        // `Int(after.rounded())`: half away from zero.
        assertEquals("the backend is rate-limiting; retry in 1s", SyncRejection.RateLimited(0.5).description)
        assertEquals("the backend is rate-limiting; retry in 0s", SyncRejection.RateLimited(0.49999999999999994).description)
        assertEquals("the backend is rate-limiting; retry in 3s", SyncRejection.RateLimited(2.5).description)
        assertEquals("the backend is rate-limiting; retry in -1s", SyncRejection.RateLimited(-0.5).description)
        assertEquals(
            "the backend needs you to sign in again: token expired",
            SyncRejection.AuthenticationRequired("token expired").description,
        )
        assertEquals(
            "the backend permanently refused this snippet: git_key_required",
            SyncRejection.Permanent("git_key_required").description,
        )
    }

    @Test fun rejectionsCompareByCaseAndPayload() {
        assertEquals(SyncRejection.RateLimited(30.0), SyncRejection.RateLimited(30.0))
        assertNotEquals(SyncRejection.RateLimited(30.0), SyncRejection.RateLimited(31.0))
        assertEquals(SyncRejection.RateLimited(0.0), SyncRejection.RateLimited(-0.0))
        assertEquals(SyncRejection.RateLimited(0.0).hashCode(), SyncRejection.RateLimited(-0.0).hashCode())
        assertEquals(SyncRejection.Conflict(record(1, "v1")), SyncRejection.Conflict(record(1, "v1")))
        assertNotEquals(SyncRejection.Conflict(record(1, "v1")), SyncRejection.Conflict(record(1, "v2")))
        assertNotEquals(SyncRejection.Conflict(record(1)), SyncRejection.Conflict(null))
        assertNotEquals<SyncRejection>(SyncRejection.Permanent("x"), SyncRejection.AuthenticationRequired("x"))
        assertEquals(SyncRejection.Permanent("x"), SyncRejection.Permanent("x"))
    }

    @Test fun transportFailuresMirrorTheSwiftCasesAndTheirDescriptions() {
        val failures: List<Pair<SyncTransportFailure, String>> = listOf(
            SyncTransportFailure.Unreachable("no route") to "the sync backend could not be reached: no route",
            SyncTransportFailure.Rejected(SyncRejection.Permanent("quota")) to "the backend permanently refused this snippet: quota",
            SyncTransportFailure.PushUnsupported() to "this sync backend does not accept pushes",
            SyncTransportFailure.AccountChanged() to "the sync backend account changed during the operation",
            SyncTransportFailure.CheckpointUnreadable("bad tag") to "the sync scheduler checkpoint could not be read: bad tag",
            SyncTransportFailure.RemoteDataReset("zone gone") to "the remote sync data was reset: zone gone",
        )
        for ((failure, message) in failures) assertEquals(message, failure.message)
        // Six cases, as the Swift enum; every one is an exception a transport can throw.
        assertEquals(
            listOf("unreachable", "rejected", "pushUnsupported", "accountChanged", "checkpointUnreadable", "remoteDataReset"),
            failures.map { swiftCase(it.first) },
        )
        for ((failure, _) in failures) assertTrue((failure as Any) is Exception)
    }

    // Exhaustive without an `else`: a case added to or removed from a hierarchy stops this file compiling.

    private fun swiftCase(failure: SyncTransportFailure): String = when (failure) {
        is SyncTransportFailure.Unreachable -> "unreachable"
        is SyncTransportFailure.Rejected -> "rejected"
        is SyncTransportFailure.PushUnsupported -> "pushUnsupported"
        is SyncTransportFailure.AccountChanged -> "accountChanged"
        is SyncTransportFailure.CheckpointUnreadable -> "checkpointUnreadable"
        is SyncTransportFailure.RemoteDataReset -> "remoteDataReset"
    }

    private fun swiftCase(rejection: SyncRejection): String = when (rejection) {
        is SyncRejection.Conflict -> "conflict"
        is SyncRejection.RateLimited -> "rateLimited"
        is SyncRejection.AuthenticationRequired -> "authenticationRequired"
        is SyncRejection.Permanent -> "permanent"
    }

    private fun swiftCase(outcome: SyncSubmitOutcome): String = when (outcome) {
        is SyncSubmitOutcome.Accepted -> "accepted"
        is SyncSubmitOutcome.Rejected -> "rejected"
    }

    private fun swiftCase(event: SyncTransportEvent): String = when (event) {
        SyncTransportEvent.ChangesAvailable -> "changesAvailable"
        is SyncTransportEvent.CursorInvalidated -> "cursorInvalidated"
        SyncTransportEvent.AuthenticationRequired -> "authenticationRequired"
    }

    @Test fun theTaxonomiesHaveExactlyTheSwiftCases() {
        assertEquals(
            listOf("conflict", "rateLimited", "authenticationRequired", "permanent"),
            listOf(
                SyncRejection.Conflict(null), SyncRejection.RateLimited(1.0),
                SyncRejection.AuthenticationRequired("d"), SyncRejection.Permanent("d"),
            ).map { swiftCase(it) },
        )
        assertEquals(
            listOf("accepted", "rejected"),
            listOf(
                SyncSubmitOutcome.Accepted("r", SyncRecordVersion(byteArrayOf(1))),
                SyncSubmitOutcome.Rejected(SyncRejection.Permanent("d")),
            ).map { swiftCase(it) },
        )
        assertEquals(
            listOf("changesAvailable", "cursorInvalidated", "authenticationRequired"),
            listOf(
                SyncTransportEvent.ChangesAvailable, SyncTransportEvent.CursorInvalidated("r"),
                SyncTransportEvent.AuthenticationRequired,
            ).map { swiftCase(it) },
        )
    }

    @Test fun transportFailuresCompareByCaseAndPayload() {
        assertEquals(SyncTransportFailure.PushUnsupported(), SyncTransportFailure.PushUnsupported())
        assertEquals(SyncTransportFailure.AccountChanged(), SyncTransportFailure.AccountChanged())
        assertNotEquals<SyncTransportFailure>(SyncTransportFailure.PushUnsupported(), SyncTransportFailure.AccountChanged())
        assertEquals(SyncTransportFailure.Unreachable("a"), SyncTransportFailure.Unreachable("a"))
        assertEquals(SyncTransportFailure.Unreachable("a").hashCode(), SyncTransportFailure.Unreachable("a").hashCode())
        assertNotEquals(SyncTransportFailure.Unreachable("a"), SyncTransportFailure.Unreachable("b"))
        assertNotEquals<SyncTransportFailure>(SyncTransportFailure.Unreachable("a"), SyncTransportFailure.RemoteDataReset("a"))
        assertNotEquals<SyncTransportFailure>(SyncTransportFailure.CheckpointUnreadable("a"), SyncTransportFailure.RemoteDataReset("a"))
        assertEquals(
            SyncTransportFailure.Rejected(SyncRejection.RateLimited(1.0)), SyncTransportFailure.Rejected(SyncRejection.RateLimited(1.0)),
        )
        assertNotEquals(
            SyncTransportFailure.Rejected(SyncRejection.RateLimited(1.0)), SyncTransportFailure.Rejected(SyncRejection.RateLimited(2.0)),
        )
    }

    // The protocol's defaults

    /** A transport that implements only what has no default. */
    private class MinimalTransport(private val identity: SyncAccountIdentity? = null) : SyncTransport {
        override val identifier = "minimal"
        override val supportsPush = true
        override val pollInterval = 60.0
        override val events: Flow<SyncTransportEvent> = emptyFlow()
        override suspend fun resolveAccountIdentity(): SyncAccountIdentity? = identity
        override suspend fun fetchChanges(since: SyncCursor?) = SyncFetch(emptyList(), since)
        override suspend fun submit(records: List<WireRecord>, at: SyncCursor?) = SyncSubmission(emptyList(), at)
    }

    @Test fun theDefaultsAreNoPacingNoAccountAndAPreflightThatWrapsTheAccount() = runTest {
        val accountless = object : SyncTransport {
            override val identifier = "bare"
            override val supportsPush = false
            override val pollInterval = 30.0
            override val events: Flow<SyncTransportEvent> = emptyFlow()
            override suspend fun fetchChanges(since: SyncCursor?) = SyncFetch(emptyList(), since)
            override suspend fun submit(records: List<WireRecord>, at: SyncCursor?) = SyncSubmission(emptyList(), at)
        }
        assertNull(accountless.roundPacing)
        assertNull(accountless.resolveAccountIdentity())
        assertEquals(SyncScopePreflight(identity = null), accountless.preflightScope())

        val identity = SyncAccountIdentity(byteArrayOf(7))
        assertEquals(SyncScopePreflight(identity = identity), MinimalTransport(identity).preflightScope())

        // No-ops that never throw.
        accountless.acknowledgeFetched(through = null)
        accountless.acknowledgeFetched(through = SyncCursor("1"))
        accountless.shutdown()
        accountless.shutdown()
    }

    @Test fun theDefaultResetsFailClosed() = runTest {
        val transport = MinimalTransport()
        val identity = SyncAccountIdentity(byteArrayOf(1))
        val dataset = SyncDatasetIdentity(byteArrayOf(2))

        val scoped: List<suspend (SyncAccountIdentity?, SyncDatasetIdentity?) -> Unit> = listOf(
            transport::resetAfterAccountReview,
            transport::resetAfterCheckpointReview,
            transport::resetForLocalFullResync,
        )
        for (reset in scoped) {
            // Nothing expected: an accountless, stateless transport has nothing to reset.
            reset(null, null)
            // An account-scoped caller must not be told "done" by a transport that proved nothing.
            assertEquals(
                SyncTransportFailure.AccountChanged(),
                assertFailsWith<SyncTransportFailure.AccountChanged> { reset(identity, null) },
            )
            assertEquals(
                SyncTransportFailure.AccountChanged(),
                assertFailsWith<SyncTransportFailure.AccountChanged> { reset(identity, dataset) },
            )
            assertEquals(
                SyncTransportFailure.RemoteDataReset("unexpected dataset scope"),
                assertFailsWith<SyncTransportFailure.RemoteDataReset> { reset(null, dataset) },
            )
        }

        // Restoring a reset remote library is never a silent no-op: a transport must opt in.
        for ((expectedIdentity, expectedDataset) in listOf(null to null, identity to null, null to dataset, identity to dataset)) {
            val failure = assertFailsWith<SyncTransportFailure.RemoteDataReset> {
                transport.resetAfterRemoteDataResetReview(expectedIdentity, expectedDataset)
            }
            assertEquals("the selected transport cannot restore a reset remote library", failure.detail)
        }
    }
}
