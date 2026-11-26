package com.khm.snippets.core.sync.base

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.state.LETTERED_ID
import com.khm.snippets.core.state.StrictDecodeFailure
import com.khm.snippets.core.state.anotherType
import com.khm.snippets.core.state.bytes
import com.khm.snippets.core.state.dotted
import com.khm.snippets.core.state.edited
import com.khm.snippets.core.state.objectAt
import com.khm.snippets.core.state.parseJson
import com.khm.snippets.core.state.testEnvelope
import com.khm.snippets.core.state.testId
import com.khm.snippets.core.state.testTombstone
import com.khm.snippets.core.state.utf8
import com.khm.snippets.core.sync.transport.SyncAccountIdentity
import com.khm.snippets.core.sync.transport.SyncCursor
import com.khm.snippets.core.sync.transport.SyncCursorKind
import com.khm.snippets.core.sync.transport.SyncDatasetIdentity
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.wire.SyncEnvelope
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The strict `base.json` codec: `SyncEngineJournalSafetyTests` (strict base decoding),
 * `SyncRecordCASTests` (record versions in the base), `SyncAccountBindingTests` (damaged
 * binding), and the strictness this app adds.
 */
class SyncBaseCodecTest {

    private val id = LETTERED_ID
    private val validEnvelope: String = Base64Std.encode(testEnvelope(1).canonicalBytes())
    private val letteredEnvelope: String = Base64Std.encode(
        SyncEnvelope.tombstone(LETTERED_ID, secure = false, hlc = Hlc.of(1, 0, "a1b2c3d4"), origin = "a1b2c3d4").canonicalBytes(),
    )

    /** Every key present: a reviewed fence with a prior ancestor, a bound cursor and versions. */
    private val full = SyncBase(
        envelopes = mapOf(testId(1) to testEnvelope(1), testId(2) to testTombstone(2)),
        recordVersions = mapOf(testId(1) to SyncRecordVersion(utf8("g1")), testId(3) to SyncRecordVersion(ByteArray(0))),
        cursor = SyncCursor("cursor/with+slash"),
        cursorKind = SyncCursorKind.LEGACY,
        journalEstablished = true,
        accountIdentity = SyncAccountIdentity(utf8("account")),
        datasetIdentity = SyncDatasetIdentity(utf8("dataset")),
        requiresTransportFullResync = true,
        requiresNonDestructiveLibraryMerge = true,
        nonDestructiveMergeMode = SyncBase.NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT,
        preRecoveryConfirmedEnvelopes = mapOf(testId(4) to testEnvelope(4)),
        nonDestructiveReviewId = testId(5),
    )

    private val document: JsonValue = parseJson(SyncBaseCodec.encode(full))

    /** Objects whose keys are record ids, not format. */
    private val maps = setOf("envelopes", "recordVersions", "preRecoveryConfirmedEnvelopes")

    private fun undecodable(bytes: ByteArray, label: String): StrictDecodeFailure {
        val result = SyncBaseCodec.read(bytes)
        if (result !is SyncBaseCodec.ReadResult.Undecodable) fail("$label decoded as $result")
        return result.failure
    }

    private fun minimal(vararg members: Pair<String, JsonValue>): ByteArray {
        val base = linkedMapOf(
            "schemaVersion" to JsonValue.of(7),
            "envelopes" to JsonValue.Object(emptyMap()),
            "recordVersions" to JsonValue.Object(emptyMap()),
            "journalEstablished" to JsonValue.of(true),
            "requiresTransportFullResync" to JsonValue.of(false),
            "requiresNonDestructiveLibraryMerge" to JsonValue.of(false),
        )
        for ((key, value) in members) base[key] = value
        return JsonValue.Object(base).bytes()
    }

    @Test
    fun aFullBaseRoundTripsAndTheMinimalDocumentIsTheEmptyBase() {
        val decoded = SyncBaseCodec.decode(SyncBaseCodec.encode(full))
        assertEquals(full, decoded)
        assertEquals(SyncBase(journalEstablished = true), SyncBaseCodec.decode(minimal()))
        assertEquals(SyncBaseCodec.KEYS, document.objectOrNull!!.keys)
        val text = String(SyncBaseCodec.encode(full), Charsets.UTF_8)
        assertTrue(text.contains("\"nonDestructiveReviewID\" : \"${testId(5)}\""), "the review id is lowercase")
        assertTrue(text.contains("\"cursorKind\" : \"legacy\""))
    }

    /** `baseLoadRejectsSyntacticallyValidTruncationsAndInvalidEnvelopes`. */
    @Test
    fun baseLoadRejectsSyntacticallyValidTruncationsAndInvalidEnvelopes() {
        val documents = listOf(
            "empty object" to utf8("{}"),
            "missing envelopes" to utf8("{\"schemaVersion\":7}"),
            "null envelopes" to minimal("envelopes" to JsonValue.Null),
            "wrong envelopes shape" to minimal("envelopes" to JsonValue.array()),
            "null journal marker" to minimal("journalEstablished" to JsonValue.Null),
            "malformed envelope" to minimal("envelopes" to JsonValue.obj(SyncBase.key(id) to JsonValue.of("not-base64"))),
            "envelope stored under a different key" to minimal("envelopes" to JsonValue.obj(SyncBase.key(testId(0x44)) to JsonValue.of(validEnvelope))),
            "envelope under its uppercase key" to minimal("envelopes" to JsonValue.obj(LETTERED_ID.toString().uppercase() to JsonValue.of(letteredEnvelope))),
            "non-canonical base64" to minimal("envelopes" to JsonValue.obj(SyncBase.key(testId(1)) to JsonValue.of(validEnvelope.trimEnd('=')))),
            "base64 of something else" to minimal("envelopes" to JsonValue.obj(SyncBase.key(testId(1)) to JsonValue.of(Base64Std.encode(utf8("{}"))))),
            "a null envelope" to minimal("envelopes" to JsonValue.obj(SyncBase.key(testId(1)) to JsonValue.Null)),
        )
        for ((label, data) in documents) undecodable(data, label)
    }

    /** `currentBaseRejectsUnknownFutureTopLevelField`, at every level. */
    @Test
    fun anUnknownKeyIsRefusedAtTheTopAndInsideEveryToken() {
        val top = undecodable(minimal("cursorGenerationKindV4" to JsonValue.of("unknown-protocol-sentinel")), "future field")
        assertEquals(StrictDecodeFailure.Kind.UNKNOWN_KEY, top.kind)
        for (key in listOf("accountIdentity", "datasetIdentity")) {
            val edited = document.edited(listOf(key)) { it["extra"] = JsonValue.of(true) }
            assertEquals(StrictDecodeFailure.Kind.INVALID_VALUE, undecodable(edited.bytes(), key).kind)
        }
        val version = document.edited(listOf("recordVersions", SyncBase.key(testId(1)))) { it["extra"] = JsonValue.of(true) }
        assertEquals(StrictDecodeFailure.Kind.INVALID_VALUE, undecodable(version.bytes(), "record version").kind)
    }

    @Test
    fun anExplicitNullIsRefusedForEveryKey() {
        for (key in document.objectOrNull!!.keys) {
            val edited = document.edited(emptyList()) { it[key] = JsonValue.Null }
            assertEquals(StrictDecodeFailure.Kind.EXPLICIT_NULL, undecodable(edited.bytes(), "null $key").kind, key)
        }
        for (map in maps) {
            val inner = document.objectAt(listOf(map)).keys.first()
            val edited = document.edited(listOf(map)) { it[inner] = JsonValue.Null }
            assertEquals(StrictDecodeFailure.Kind.EXPLICIT_NULL, undecodable(edited.bytes(), "null in $map").kind, map)
        }
    }

    @Test
    fun aWrongTypeIsRefusedForEveryKey() {
        for ((key, value) in document.objectOrNull!!) {
            val edited = document.edited(emptyList()) { it[key] = anotherType(value) }
            val failure = undecodable(edited.bytes(), "wrong type for $key")
            assertTrue(
                failure.kind in setOf(StrictDecodeFailure.Kind.WRONG_TYPE, StrictDecodeFailure.Kind.INVALID_VALUE),
                "$key: ${failure.kind}",
            )
        }
    }

    /** `currentBaseCannotLoseItsRequiredLibraryRecoveryFenceField`, and every other key the writer always writes. */
    @Test
    fun removingAnAlwaysWrittenKeyFailsClosedAndRemovingAnOptionalOneIsConsistentOrRefused() {
        val alwaysWritten = setOf(
            "schemaVersion", "envelopes", "recordVersions", "journalEstablished",
            "requiresTransportFullResync", "requiresNonDestructiveLibraryMerge",
        )
        for (key in document.objectOrNull!!.keys) {
            val edited = document.edited(emptyList()) { it.remove(key) }
            val result = SyncBaseCodec.read(edited.bytes())
            if (key in alwaysWritten) {
                assertIs<SyncBaseCodec.ReadResult.Undecodable>(result, "removing $key")
                assertEquals(StrictDecodeFailure.Kind.MISSING_KEY, result.failure.kind, key)
            } else {
                // Each optional key is part of a pair or a scope; alone it is either absent by right or inconsistent.
                when (key) {
                    "accountIdentity", "datasetIdentity", "preRecoveryConfirmedEnvelopes" ->
                        assertIs<SyncBaseCodec.ReadResult.Decoded>(result, "removing $key")
                    else -> assertEquals(
                        StrictDecodeFailure.Kind.INCONSISTENT,
                        (result as SyncBaseCodec.ReadResult.Undecodable).failure.kind, "removing $key",
                    )
                }
            }
        }
    }

    /** `schemaFiveRecoveryFenceRequiresItsExactReviewedSnapshotMode` and the other pairs. */
    @Test
    fun pairedMembersMustAgree() {
        val cases = listOf(
            "a cursor without its kind" to minimal("cursor" to JsonValue.of("c")),
            "a kind without a cursor" to minimal("cursorKind" to JsonValue.of("legacy")),
            "a fence without its mode" to minimal("requiresNonDestructiveLibraryMerge" to JsonValue.of(true)),
            "a mode without the fence" to minimal("nonDestructiveMergeMode" to JsonValue.of("incompletePrimary")),
            "a reviewed fence without its id" to minimal(
                "requiresNonDestructiveLibraryMerge" to JsonValue.of(true),
                "nonDestructiveMergeMode" to JsonValue.of("reviewedLocalSnapshot"),
            ),
            "a review id on an incomplete fence" to minimal(
                "requiresNonDestructiveLibraryMerge" to JsonValue.of(true),
                "nonDestructiveMergeMode" to JsonValue.of("incompletePrimary"),
                "nonDestructiveReviewID" to JsonValue.of(testId(1).toString()),
            ),
            "a pre-recovery ancestor without a reviewed fence" to minimal(
                "preRecoveryConfirmedEnvelopes" to JsonValue.Object(emptyMap()),
            ),
        )
        for ((label, data) in cases) assertEquals(StrictDecodeFailure.Kind.INCONSISTENT, undecodable(data, label).kind, label)

        val valueCases = listOf(
            "an unknown mode" to minimal("requiresNonDestructiveLibraryMerge" to JsonValue.of(true), "nonDestructiveMergeMode" to JsonValue.of("everything")),
            "an uppercase review id" to minimal(
                "requiresNonDestructiveLibraryMerge" to JsonValue.of(true),
                "nonDestructiveMergeMode" to JsonValue.of("reviewedLocalSnapshot"),
                "nonDestructiveReviewID" to JsonValue.of(LETTERED_ID.toString().uppercase()),
            ),
            "the CloudKit cursor kind" to minimal("cursor" to JsonValue.of("c"), "cursorKind" to JsonValue.of("cloudKitSyncEngine")),
            "an unknown cursor kind" to minimal("cursor" to JsonValue.of("c"), "cursorKind" to JsonValue.of("future")),
            "an empty identity" to minimal("accountIdentity" to JsonValue.obj("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of(""))),
            "an oversized identity" to minimal(
                "datasetIdentity" to JsonValue.obj("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of(Base64Std.encode(ByteArray(1_025)))),
            ),
        )
        for ((label, data) in valueCases) assertEquals(StrictDecodeFailure.Kind.INVALID_VALUE, undecodable(data, label).kind, label)
    }

    /** `explicitNullMalformedAndFutureRecordVersionsMakeTheWholeBaseUnreadable`. */
    @Test
    fun explicitNullMalformedAndFutureRecordVersionsMakeTheWholeBaseUnreadable() {
        val key = SyncBase.key(id)
        fun token(vararg members: Pair<String, JsonValue>) = JsonValue.Object(linkedMapOf(*members))
        val documents = listOf(
            "null" to JsonValue.Null,
            "array" to JsonValue.array(),
            "null entry" to JsonValue.obj(key to JsonValue.Null),
            "missing version schema" to JsonValue.obj(key to token("data" to JsonValue.of("AA=="))),
            "future nested schema" to JsonValue.obj(key to token("schemaVersion" to JsonValue.of(2), "data" to JsonValue.of("AA=="))),
            "malformed archive" to JsonValue.obj(key to token("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of("%%%"))),
            "unknown version field" to JsonValue.obj(
                key to token("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of("AA=="), "extra" to JsonValue.of(true)),
            ),
            "noncanonical key" to JsonValue.obj(id.toString().uppercase() to token("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of("AA=="))),
            "short key" to JsonValue.obj("1-1-1-1-1" to token("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of("AA=="))),
            "oversized" to JsonValue.obj(
                key to token("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of(Base64Std.encode(ByteArray(SyncRecordVersion.MAXIMUM_DATA_BYTES + 1)))),
            ),
        )
        for ((label, recordVersions) in documents) {
            undecodable(minimal("envelopes" to JsonValue.obj(SyncBase.key(testId(1)) to JsonValue.of(validEnvelope)), "recordVersions" to recordVersions), label)
        }
        // A version may exist without its envelope (a staged rekey).
        val orphan = SyncBaseCodec.decode(minimal("recordVersions" to JsonValue.obj(key to token("schemaVersion" to JsonValue.of(1), "data" to JsonValue.of("AA==")))))
        assertEquals(SyncRecordVersion(ByteArray(1)), orphan.recordVersion(id))
    }

    /** `damagedExplicitAccountBindingMakesTheWholeCheckpointUnreadable`. */
    @Test
    fun damagedExplicitAccountBindingMakesTheWholeCheckpointUnreadable() {
        val bound = parseJson(SyncBaseCodec.encode(SyncBase(journalEstablished = true, accountIdentity = SyncAccountIdentity(utf8("a")))))
        val damaged = bound.edited(emptyList()) { it["accountIdentity"] = JsonValue.Null }
        assertEquals(StrictDecodeFailure.Kind.EXPLICIT_NULL, undecodable(damaged.bytes(), "null binding").kind)
    }

    /** Owner decision: Swift's schemas 1…6 (and anything newer) are not read and never migrated. */
    @Test
    fun everyOtherSchemaIsUnsupported() {
        for (version in listOf(1L, 2L, 3L, 4L, 5L, 6L, 8L, 99L, 0L, -7L)) {
            assertEquals(SyncBaseCodec.ReadResult.Unsupported(version), SyncBaseCodec.read(utf8("{\"schemaVersion\":$version,\"envelopes\":{}}")))
        }
        // `legacyBaseWithoutRecordVersionsLoadsAsEmpty…` and `legacySchemaOne…`: a legacy file is
        // a typed "unsupported", not a loaded base and not an empty one.
        assertEquals(SyncBaseCodec.ReadResult.Unsupported(1), SyncBaseCodec.read(utf8("{\"schemaVersion\":1,\"envelopes\":{}}")))
        assertEquals(StrictDecodeFailure.Kind.WRONG_TYPE, undecodable(minimal("schemaVersion" to JsonValue.of(7.0)), "7.0").kind)
    }

    @Test
    fun everyTruncationAndTheEmptyFileAreNotJson() {
        val bytes = SyncBaseCodec.encode(SyncBase(envelopes = mapOf(testId(1) to testEnvelope(1)), cursor = SyncCursor("c")))
        for (length in 0 until bytes.size) {
            assertEquals(StrictDecodeFailure.Kind.NOT_JSON, undecodable(bytes.copyOf(length), "prefix $length").kind, "prefix $length")
        }
    }

    @Test
    fun theEncoderRefusesWhatTheReaderWouldRefuse() {
        val cloudKit = SyncBase(cursor = SyncCursor("c"), cursorKind = SyncCursorKind.CLOUD_KIT_SYNC_ENGINE)
        val failure = runCatching { SyncBaseCodec.encode(cloudKit) }.exceptionOrNull()
        assertEquals(SyncBaseCodec.EncodeFailure.Reason.UNSUPPORTED_CURSOR_KIND, (failure as SyncBaseCodec.EncodeFailure).reason)
        val oversized = SyncBase(recordVersions = mapOf(id to SyncRecordVersion(ByteArray(SyncRecordVersion.MAXIMUM_DATA_BYTES + 1))))
        val tooLarge = runCatching { SyncBaseCodec.encode(oversized) }.exceptionOrNull()
        assertEquals(SyncBaseCodec.EncodeFailure.Reason.RECORD_VERSION_TOO_LARGE, (tooLarge as SyncBaseCodec.EncodeFailure).reason)
    }

    @Test
    fun encodingIsDeterministicWhateverTheMapOrder() {
        val ids = (1..50).map(::testId)
        val forward = SyncBase(envelopes = ids.associateWith { testEnvelope(it.leastSignificantBits.toInt()) })
        val backward = SyncBase(envelopes = LinkedHashMap(ids.reversed().associateWith { testEnvelope(it.leastSignificantBits.toInt()) }))
        assertContentEquals(SyncBaseCodec.encode(forward), SyncBaseCodec.encode(backward))
        assertContentEquals(SyncBaseCodec.encode(forward), SyncBaseCodec.encode(SyncBaseCodec.decode(SyncBaseCodec.encode(forward))))
    }

    @Test
    fun aSlashInsideBase64IsReadEitherWay() {
        // Foundation's encoder escapes `/`; this writer does too. Both spellings parse.
        val withSlash = SyncBase(cursor = SyncCursor("a/b"))
        val text = String(SyncBaseCodec.encode(withSlash), Charsets.UTF_8)
        assertTrue(text.contains("a\\/b"))
        assertEquals(withSlash, SyncBaseCodec.decode(utf8(text.replace("a\\/b", "a/b"))))
        assertEquals("", dotted(emptyList()))
    }
}
