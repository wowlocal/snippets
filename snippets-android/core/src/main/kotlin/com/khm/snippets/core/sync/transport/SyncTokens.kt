package com.khm.snippets.core.sync.transport

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Base64Std

// The opaque tokens of `snippets/Core/SyncTransport.swift`. Core stores them, compares
// them and hands them back; it never interprets one.

/**
 * A stored token is not a value this build can read or write (Swift throws a
 * `DecodingError` or an `EncodingError` in the same places). A base or journal that holds
 * such a token is unreadable as a whole; it is never loaded without the token.
 */
sealed class SyncTokenCodingFailure(message: String) : Exception(message) {
    class Decoding(val detail: String) : SyncTokenCodingFailure(detail)
    class Encoding(val detail: String) : SyncTokenCodingFailure(detail)
}

/**
 * Where a backend is in its stream of changes (`SyncCursor`).
 *
 * Opaque by contract: a commit and dataset name to Git, a sequence number to
 * [com.khm.snippets.core.sync.testing.InMemoryTransport]. The engine stores it, hands it
 * back and never parses it.
 *
 * [toString] does not print the value. Use [rawValue] where the value itself is needed.
 */
@JvmInline
value class SyncCursor(val rawValue: String) {

    /** The persisted form: one JSON string. */
    fun toJsonValue(): JsonValue = JsonValue.Text(rawValue)

    override fun toString(): String = "SyncCursor(${rawValue.length} chars)"

    companion object {
        /** A JSON string and nothing else; `null`, a number or an object is refused. */
        @Throws(SyncTokenCodingFailure.Decoding::class)
        fun fromJsonValue(value: JsonValue): SyncCursor {
            if (value !is JsonValue.Text && value !is JsonValue.Utf8) {
                throw SyncTokenCodingFailure.Decoding("a sync cursor must be a string")
            }
            val text = value.textOrNull ?: throw SyncTokenCodingFailure.Decoding("a sync cursor must be valid text")
            return SyncCursor(text)
        }
    }
}

/**
 * Which transport protocol issued a cursor (`SyncCursorKind`). A base persists it beside
 * the cursor so that two unrelated cursor formats are never mistaken for each other.
 *
 * [CLOUD_KIT_SYNC_ENGINE] is never produced on Android. It stays in the vocabulary so a
 * stored value is recognised and refused by the reader, not silently read as [LEGACY].
 */
enum class SyncCursorKind(val rawValue: String) {
    LEGACY("legacy"),
    CLOUD_KIT_SYNC_ENGINE("cloudKitSyncEngine");

    companion object {
        /** The case with exactly this raw value, or `null`. */
        fun fromRawValue(rawValue: String): SyncCursorKind? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * The closed JSON form the three byte tokens share: exactly `schemaVersion` and `data`,
 * `{"schemaVersion":1,"data":"<base64>"}`.
 *
 * Stricter than Foundation's decoder in two ways, both on files only this app writes:
 * `schemaVersion` must be an integer token, and `data` must be the canonical padded
 * base64 spelling.
 */
private object OpaqueTokenJson {

    private val FIELDS = setOf("schemaVersion", "data")

    fun encode(schemaVersion: Int, data: ByteArray): JsonValue = JsonValue.obj(
        "schemaVersion" to JsonValue.of(schemaVersion),
        "data" to JsonValue.of(Base64Std.encode(data)),
    )

    /** The decoded `data`, not yet checked for length. */
    fun decode(kind: String, value: JsonValue, currentSchemaVersion: Int): ByteArray {
        val members = value.objectOrNull
            ?: throw SyncTokenCodingFailure.Decoding("a $kind must be an object")
        if (members.keys != FIELDS) throw SyncTokenCodingFailure.Decoding("unexpected $kind fields")
        val schemaVersion = members.getValue("schemaVersion").longOrNull
            ?: throw SyncTokenCodingFailure.Decoding("a $kind schema version must be an integer")
        if (schemaVersion != currentSchemaVersion.toLong()) {
            throw SyncTokenCodingFailure.Decoding("unsupported $kind schema version")
        }
        val dataValue = members.getValue("data")
        if (dataValue !is JsonValue.Text && dataValue !is JsonValue.Utf8) {
            throw SyncTokenCodingFailure.Decoding("$kind data must be a string")
        }
        val text = dataValue.textOrNull ?: throw SyncTokenCodingFailure.Decoding("invalid $kind data")
        return Base64Std.decodeCanonical(text) ?: throw SyncTokenCodingFailure.Decoding("invalid $kind data")
    }
}

/**
 * An opaque identity for the account or database scope that owns a confirmed checkpoint
 * (`SyncAccountIdentity`).
 *
 * A cursor and a per-record generation mean something only inside the scope that issued
 * them, so Core persists this digest beside them. It is never interpreted and never
 * rendered: [toString] prints nothing of it, because stable account identifiers and hashes
 * derived from them must not reach diagnostics or error text.
 *
 * Immutable; the constructor copies [data] and [data] returns a copy.
 *
 * @throws IllegalArgumentException when [data] is empty or longer than [MAXIMUM_DATA_BYTES]
 *   (a Swift `precondition`).
 */
class SyncAccountIdentity(data: ByteArray) {

    init {
        require(data.isNotEmpty() && data.size <= MAXIMUM_DATA_BYTES) {
            "a sync account identity is 1…$MAXIMUM_DATA_BYTES bytes"
        }
    }

    val schemaVersion: Int get() = CURRENT_SCHEMA_VERSION

    private val bytes: ByteArray = data.copyOf()

    /** A copy of the opaque bytes. */
    val data: ByteArray get() = bytes.copyOf()

    fun toJsonValue(): JsonValue = OpaqueTokenJson.encode(CURRENT_SCHEMA_VERSION, bytes)

    override fun equals(other: Any?): Boolean = other is SyncAccountIdentity && bytes.contentEquals(other.bytes)
    override fun hashCode(): Int = bytes.contentHashCode()
    override fun toString(): String = "SyncAccountIdentity(redacted)"

    companion object {
        const val CURRENT_SCHEMA_VERSION: Int = 1
        const val MAXIMUM_DATA_BYTES: Int = 1_024

        @Throws(SyncTokenCodingFailure.Decoding::class)
        fun fromJsonValue(value: JsonValue): SyncAccountIdentity {
            val data = OpaqueTokenJson.decode("sync-account-identity", value, CURRENT_SCHEMA_VERSION)
            if (data.isEmpty() || data.size > MAXIMUM_DATA_BYTES) {
                throw SyncTokenCodingFailure.Decoding("invalid sync-account-identity data")
            }
            return SyncAccountIdentity(data)
        }
    }
}

/**
 * An opaque identity for one physical generation of an account-owned remote dataset
 * (`SyncDatasetIdentity`).
 *
 * Account membership and dataset lifetime are separate. A changed dataset generation
 * means the remote library was physically replaced, and local values must not be uploaded
 * until the user chooses this device as the restore source. Like [SyncAccountIdentity] it
 * is persisted as opaque bytes and never rendered.
 *
 * @throws IllegalArgumentException when [data] is empty or longer than [MAXIMUM_DATA_BYTES].
 */
class SyncDatasetIdentity(data: ByteArray) {

    init {
        require(data.isNotEmpty() && data.size <= MAXIMUM_DATA_BYTES) {
            "a sync dataset identity is 1…$MAXIMUM_DATA_BYTES bytes"
        }
    }

    val schemaVersion: Int get() = CURRENT_SCHEMA_VERSION

    private val bytes: ByteArray = data.copyOf()

    /** A copy of the opaque bytes. */
    val data: ByteArray get() = bytes.copyOf()

    fun toJsonValue(): JsonValue = OpaqueTokenJson.encode(CURRENT_SCHEMA_VERSION, bytes)

    override fun equals(other: Any?): Boolean = other is SyncDatasetIdentity && bytes.contentEquals(other.bytes)
    override fun hashCode(): Int = bytes.contentHashCode()
    override fun toString(): String = "SyncDatasetIdentity(redacted)"

    companion object {
        const val CURRENT_SCHEMA_VERSION: Int = 1
        const val MAXIMUM_DATA_BYTES: Int = 1_024

        @Throws(SyncTokenCodingFailure.Decoding::class)
        fun fromJsonValue(value: JsonValue): SyncDatasetIdentity {
            val data = OpaqueTokenJson.decode("sync-dataset-identity", value, CURRENT_SCHEMA_VERSION)
            if (data.isEmpty() || data.size > MAXIMUM_DATA_BYTES) {
                throw SyncTokenCodingFailure.Decoding("invalid sync-dataset-identity data")
            }
            return SyncDatasetIdentity(data)
        }
    }
}

/**
 * A backend-owned optimistic-concurrency token for one record (`SyncRecordVersion`).
 *
 * `WireRecord.rev` cannot fill this role: it is derived from the sealed envelope and says
 * which value is being written, not which server generation was read before writing it.
 * Git stores the record file's blob id here, the in-memory fake `memory-<sequence>`. Core
 * treats the bytes as opaque and compares them for equality only.
 *
 * These bytes become part of the durable merge ancestor, which is why the JSON form is
 * closed and versioned: a build that cannot read one must stop, not drop the token.
 *
 * Immutable; the constructor copies [data] and [data] returns a copy. Any length is
 * accepted here, as in Swift; [toJsonValue] refuses more than [MAXIMUM_DATA_BYTES].
 */
class SyncRecordVersion(data: ByteArray) {

    val schemaVersion: Int get() = CURRENT_SCHEMA_VERSION

    private val bytes: ByteArray = data.copyOf()

    /** A copy of the opaque bytes. */
    val data: ByteArray get() = bytes.copyOf()

    val byteCount: Int get() = bytes.size

    @Throws(SyncTokenCodingFailure.Encoding::class)
    fun toJsonValue(): JsonValue {
        if (bytes.size > MAXIMUM_DATA_BYTES) throw SyncTokenCodingFailure.Encoding("invalid sync-record-version value")
        return OpaqueTokenJson.encode(CURRENT_SCHEMA_VERSION, bytes)
    }

    override fun equals(other: Any?): Boolean = other is SyncRecordVersion && bytes.contentEquals(other.bytes)
    override fun hashCode(): Int = bytes.contentHashCode()
    override fun toString(): String = "SyncRecordVersion(${bytes.size} bytes)"

    companion object {
        const val CURRENT_SCHEMA_VERSION: Int = 1
        const val MAXIMUM_DATA_BYTES: Int = 1_048_576

        @Throws(SyncTokenCodingFailure.Decoding::class)
        fun fromJsonValue(value: JsonValue): SyncRecordVersion {
            val data = OpaqueTokenJson.decode("sync-record-version", value, CURRENT_SCHEMA_VERSION)
            if (data.size > MAXIMUM_DATA_BYTES) {
                throw SyncTokenCodingFailure.Decoding("sync-record-version data is too large")
            }
            return SyncRecordVersion(data)
        }
    }
}
