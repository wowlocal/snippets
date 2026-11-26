package com.khm.snippets.core.sync.base

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.FoundationJsonWriter
import com.khm.snippets.core.state.SchemaVersionProbe
import com.khm.snippets.core.state.StrictDecodeFailure
import com.khm.snippets.core.state.StrictObject
import com.khm.snippets.core.sync.transport.SyncAccountIdentity
import com.khm.snippets.core.sync.transport.SyncCursor
import com.khm.snippets.core.sync.transport.SyncCursorKind
import com.khm.snippets.core.sync.transport.SyncDatasetIdentity
import com.khm.snippets.core.sync.transport.SyncRecordVersion
import com.khm.snippets.core.sync.transport.SyncTokenCodingFailure
import com.khm.snippets.core.wire.SyncEnvelope
import java.util.UUID

/**
 * The bytes of a provider's `base.json` (`SyncBase`'s hand-written `Codable`).
 *
 * | key | type | |
 * |---|---|---|
 * | `schemaVersion` | integer | always [SyncBase.CURRENT_SCHEMA_VERSION] (7) |
 * | `envelopes` | object | lowercase id → standard padded base64 of the canonical envelope bytes; the id inside must be the key |
 * | `recordVersions` | object | lowercase id → `{"schemaVersion":1,"data":"<base64>"}`; may name an id without an envelope |
 * | `cursor` | string | optional, opaque; present exactly when `cursorKind` is |
 * | `cursorKind` | string | `legacy`; `cloudKitSyncEngine` is recognised and refused |
 * | `journalEstablished` | bool | |
 * | `accountIdentity`, `datasetIdentity` | object | optional; `{"schemaVersion":1,"data":"<base64 of 1…1024 bytes>"}` |
 * | `requiresTransportFullResync` | bool | |
 * | `requiresNonDestructiveLibraryMerge` | bool | the recovery fence |
 * | `nonDestructiveMergeMode` | string | `incompletePrimary` or `reviewedLocalSnapshot`; present exactly while the fence is up |
 * | `preRecoveryConfirmedEnvelopes` | object | like `envelopes`; only with a reviewed fence; absent means unknown, `{}` known-empty |
 * | `nonDestructiveReviewID` | string | lowercase UUID; present exactly with a reviewed fence |
 *
 * ## Compared with Swift
 *
 * Swift's key names and nesting are kept, so a Swift test maps onto this one. The file
 * is this app's own: only schema 7 is read or written, and every other version is
 * [ReadResult.Unsupported] (never empty, never migrated). The decoder is stricter than
 * Swift's in three ways, each of which only refuses something this app never writes:
 *
 * - every key the writer always writes is required (`recordVersions`,
 *   `journalEstablished`, `requiresTransportFullResync`); Swift defaults the first two
 *   for files older than schema 7, and a default here is how a truncated or foreign
 *   rewrite would silently drop compare-and-swap tokens or the journal fence;
 * - an explicit `null` is refused everywhere, also for the three keys Swift reads with
 *   `decodeIfPresent` (`cursor`, `cursorKind`, `nonDestructiveReviewID`);
 * - the review id is the lowercase spelling (Foundation writes uppercase), and base64
 *   must be the canonical padded spelling.
 *
 * The encoder refuses a base the decoder would refuse, so a write can never produce an
 * unreadable checkpoint. Output is deterministic: keys sorted, pretty-printed as
 * Foundation's encoder would, independent of map order.
 */
object SyncBaseCodec {

    /** What [read] made of the bytes. */
    sealed class ReadResult {
        class Decoded(val base: SyncBase) : ReadResult()

        /** The file declares another schema. It must not be decoded, and never written over. */
        data class Unsupported(val version: Long) : ReadResult()

        data class Undecodable(val failure: StrictDecodeFailure) : ReadResult()
    }

    /** Why a base cannot be written. Nothing was written; the base holds a value no reader would accept. */
    class EncodeFailure(val reason: Reason) : Exception("sync base not encodable: $reason") {
        enum class Reason {
            /** A [SyncCursorKind.CLOUD_KIT_SYNC_ENGINE] cursor: never produced on Android, refused by the reader. */
            UNSUPPORTED_CURSOR_KIND,

            /** A record version longer than [SyncRecordVersion.MAXIMUM_DATA_BYTES]. */
            RECORD_VERSION_TOO_LARGE,

            /** An envelope has no canonical form. */
            ENVELOPE_NOT_CANONICAL,
        }
    }

    // Keys

    private const val SCHEMA_VERSION = "schemaVersion"
    private const val ENVELOPES = "envelopes"
    private const val RECORD_VERSIONS = "recordVersions"
    private const val CURSOR = "cursor"
    private const val CURSOR_KIND = "cursorKind"
    private const val JOURNAL_ESTABLISHED = "journalEstablished"
    private const val ACCOUNT_IDENTITY = "accountIdentity"
    private const val DATASET_IDENTITY = "datasetIdentity"
    private const val REQUIRES_TRANSPORT_FULL_RESYNC = "requiresTransportFullResync"
    private const val REQUIRES_NON_DESTRUCTIVE_MERGE = "requiresNonDestructiveLibraryMerge"
    private const val NON_DESTRUCTIVE_MERGE_MODE = "nonDestructiveMergeMode"
    private const val PRE_RECOVERY_ENVELOPES = "preRecoveryConfirmedEnvelopes"
    private const val REVIEW_ID = "nonDestructiveReviewID"

    /** The closed key set of the top-level object. */
    val KEYS: Set<String> = setOf(
        SCHEMA_VERSION, ENVELOPES, RECORD_VERSIONS, CURSOR, CURSOR_KIND, JOURNAL_ESTABLISHED,
        ACCOUNT_IDENTITY, DATASET_IDENTITY, REQUIRES_TRANSPORT_FULL_RESYNC, REQUIRES_NON_DESTRUCTIVE_MERGE,
        NON_DESTRUCTIVE_MERGE_MODE, PRE_RECOVERY_ENVELOPES, REVIEW_ID,
    )

    // Encoding

    /** The exact bytes [SyncBaseFile.write] stores. */
    @Throws(EncodeFailure::class)
    fun encode(base: SyncBase): ByteArray = FoundationJsonWriter.prettyPrinted(document(base))

    private fun document(base: SyncBase): JsonValue {
        val members = HashMap<String, JsonValue>()
        members[SCHEMA_VERSION] = JsonValue.of(SyncBase.CURRENT_SCHEMA_VERSION)
        base.cursor?.let { cursor ->
            val kind = base.cursorKind ?: SyncCursorKind.LEGACY
            if (kind != SyncCursorKind.LEGACY) throw EncodeFailure(EncodeFailure.Reason.UNSUPPORTED_CURSOR_KIND)
            members[CURSOR] = cursor.toJsonValue()
            members[CURSOR_KIND] = JsonValue.of(kind.rawValue)
        }
        members[JOURNAL_ESTABLISHED] = JsonValue.of(base.journalEstablished)
        base.accountIdentity?.let { members[ACCOUNT_IDENTITY] = it.toJsonValue() }
        base.datasetIdentity?.let { members[DATASET_IDENTITY] = it.toJsonValue() }
        members[REQUIRES_TRANSPORT_FULL_RESYNC] = JsonValue.of(base.requiresTransportFullResync)
        members[REQUIRES_NON_DESTRUCTIVE_MERGE] = JsonValue.of(base.requiresNonDestructiveLibraryMerge)
        base.nonDestructiveMergeMode?.let { members[NON_DESTRUCTIVE_MERGE_MODE] = JsonValue.of(it.rawValue) }
        base.nonDestructiveReviewId?.let { members[REVIEW_ID] = JsonValue.of(Uuids.lowercase(it)) }
        members[ENVELOPES] = envelopeObject { base.encodedEnvelopes() }
        base.encodedPreRecoveryEnvelopes()?.let { encoded ->
            members[PRE_RECOVERY_ENVELOPES] = envelopeObject { encoded }
        }
        val versions = HashMap<String, JsonValue>(base.recordVersions.size * 2)
        for ((id, version) in base.recordVersions) {
            versions[Uuids.lowercase(id)] = try {
                version.toJsonValue()
            } catch (_: SyncTokenCodingFailure.Encoding) {
                throw EncodeFailure(EncodeFailure.Reason.RECORD_VERSION_TOO_LARGE)
            }
        }
        members[RECORD_VERSIONS] = JsonValue.Object(versions)
        return JsonValue.Object(members)
    }

    private inline fun envelopeObject(encoded: () -> Map<String, String>): JsonValue {
        val texts = try {
            encoded()
        } catch (_: CanonicalJson.Failure) {
            throw EncodeFailure(EncodeFailure.Reason.ENVELOPE_NOT_CANONICAL)
        }
        val members = HashMap<String, JsonValue>(texts.size * 2)
        for ((key, text) in texts) members[key] = JsonValue.Text(text)
        return JsonValue.Object(members)
    }

    // Decoding

    /**
     * The version probe first, then the strict decode. The order is the point: a file
     * from another schema lands in [ReadResult.Unsupported] even when the rest of it
     * means nothing to this build.
     */
    fun read(data: ByteArray): ReadResult {
        val version = SchemaVersionProbe.probe(data)
        if (version != null && version != SyncBase.CURRENT_SCHEMA_VERSION) return ReadResult.Unsupported(version)
        return try {
            ReadResult.Decoded(decode(data))
        } catch (failure: StrictDecodeFailure) {
            ReadResult.Undecodable(failure)
        }
    }

    /** A document of the current schema, or the reason it is not one. */
    @Throws(StrictDecodeFailure::class)
    fun decode(data: ByteArray): SyncBase {
        val root = StrictObject(StrictObject.parseDocument(data), "", KEYS)
        if (root.long(SCHEMA_VERSION) != SyncBase.CURRENT_SCHEMA_VERSION) {
            StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, SCHEMA_VERSION)
        }

        val cursor = root.optional(CURSOR)?.let { token(CURSOR) { SyncCursor.fromJsonValue(it) } }
        val cursorKind = root.optionalString(CURSOR_KIND)?.let { raw ->
            val kind = SyncCursorKind.fromRawValue(raw)
            if (kind != SyncCursorKind.LEGACY) StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, CURSOR_KIND)
            kind
        }
        if ((cursor == null) != (cursorKind == null)) StrictObject.fail(StrictDecodeFailure.Kind.INCONSISTENT, CURSOR_KIND)

        val journalEstablished = root.bool(JOURNAL_ESTABLISHED)
        val accountIdentity = root.optional(ACCOUNT_IDENTITY)?.let {
            token(ACCOUNT_IDENTITY) { SyncAccountIdentity.fromJsonValue(it) }
        }
        val datasetIdentity = root.optional(DATASET_IDENTITY)?.let {
            token(DATASET_IDENTITY) { SyncDatasetIdentity.fromJsonValue(it) }
        }
        val requiresTransportFullResync = root.bool(REQUIRES_TRANSPORT_FULL_RESYNC)
        val fence = root.bool(REQUIRES_NON_DESTRUCTIVE_MERGE)

        val mode = root.optionalString(NON_DESTRUCTIVE_MERGE_MODE)?.let {
            SyncBase.NonDestructiveMergeMode.fromRawValue(it)
                ?: StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, NON_DESTRUCTIVE_MERGE_MODE)
        }
        if ((mode != null) != fence) StrictObject.fail(StrictDecodeFailure.Kind.INCONSISTENT, NON_DESTRUCTIVE_MERGE_MODE)
        val reviewed = mode == SyncBase.NonDestructiveMergeMode.REVIEWED_LOCAL_SNAPSHOT

        val reviewId = root.optional(REVIEW_ID)?.let {
            Uuids.parseLowercase(StrictObject.text(it, REVIEW_ID))
                ?: StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, REVIEW_ID)
        }
        if ((reviewId != null) != reviewed) StrictObject.fail(StrictDecodeFailure.Kind.INCONSISTENT, REVIEW_ID)

        val preRecovery = root.optional(PRE_RECOVERY_ENVELOPES)?.let { envelopes(it, PRE_RECOVERY_ENVELOPES) }
        if (preRecovery != null && !reviewed) StrictObject.fail(StrictDecodeFailure.Kind.INCONSISTENT, PRE_RECOVERY_ENVELOPES)

        val envelopes = envelopes(root.required(ENVELOPES), ENVELOPES)
        val recordVersions = recordVersions(root.required(RECORD_VERSIONS))

        // Every member was checked above, so the constructor has nothing to put in order.
        return SyncBase(
            envelopes = envelopes,
            recordVersions = recordVersions,
            cursor = cursor,
            cursorKind = cursorKind,
            journalEstablished = journalEstablished,
            accountIdentity = accountIdentity,
            datasetIdentity = datasetIdentity,
            requiresTransportFullResync = requiresTransportFullResync,
            requiresNonDestructiveLibraryMerge = fence,
            nonDestructiveMergeMode = mode,
            preRecoveryConfirmedEnvelopes = preRecovery,
            nonDestructiveReviewId = reviewId,
        )
    }

    /**
     * Every entry must decode, or the whole file is unreadable: dropping one would turn a
     * known remote record into an unknown one, and local absence into a fresh install.
     */
    private fun envelopes(value: JsonValue, path: String): Map<UUID, SyncEnvelope> {
        val members = value.objectOrNull ?: StrictObject.fail(StrictDecodeFailure.Kind.WRONG_TYPE, path)
        val out = HashMap<UUID, SyncEnvelope>(members.size * 2)
        for ((key, encoded) in members) {
            if (encoded.isNull) StrictObject.fail(StrictDecodeFailure.Kind.EXPLICIT_NULL, path)
            val text = StrictObject.text(encoded, path)
            val bytes = Base64Std.decodeCanonical(text) ?: StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, path)
            val envelope = try {
                SyncEnvelope.parse(bytes)
            } catch (_: SyncEnvelope.Failure) {
                StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, path)
            } catch (_: CanonicalJson.Failure) {
                StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, path)
            }
            if (SyncBase.key(envelope.id) != key) StrictObject.fail(StrictDecodeFailure.Kind.INCONSISTENT, path)
            out[envelope.id] = envelope
        }
        return out
    }

    private fun recordVersions(value: JsonValue): Map<UUID, SyncRecordVersion> {
        val members = value.objectOrNull ?: StrictObject.fail(StrictDecodeFailure.Kind.WRONG_TYPE, RECORD_VERSIONS)
        val out = HashMap<UUID, SyncRecordVersion>(members.size * 2)
        for ((key, entry) in members) {
            val id = Uuids.parseLowercase(key) ?: StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, RECORD_VERSIONS)
            if (entry.isNull) StrictObject.fail(StrictDecodeFailure.Kind.EXPLICIT_NULL, RECORD_VERSIONS)
            out[id] = token(RECORD_VERSIONS) { SyncRecordVersion.fromJsonValue(entry) }
        }
        return out
    }

    private inline fun <T> token(path: String, decode: () -> T): T = try {
        decode()
    } catch (_: SyncTokenCodingFailure) {
        StrictObject.fail(StrictDecodeFailure.Kind.INVALID_VALUE, path)
    }
}
