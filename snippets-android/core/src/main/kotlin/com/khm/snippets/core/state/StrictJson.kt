package com.khm.snippets.core.state

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.FoundationJson
import com.khm.snippets.core.json.FoundationJsonException
import com.khm.snippets.core.json.FoundationJsonNode
import java.util.UUID

/**
 * Why a local sync file (`state.json`, `base.json`) is not a document this build wrote.
 *
 * [path] names keys of the format only (`halt.reason`, `recordVersions`), never a value
 * from the file, so the failure is safe to log.
 */
class StrictDecodeFailure(val kind: Kind, val path: String) :
    Exception("local sync file rejected: $kind at ${path.ifEmpty { "the document" }}") {

    enum class Kind {
        /** Not JSON at all: an empty file, a truncated one, binary, a duplicate key. */
        NOT_JSON,

        /** JSON, but the value at [path] is not an object where one is required. */
        NOT_AN_OBJECT,

        /** A key this build does not write. Ignoring it would erase it on the next write. */
        UNKNOWN_KEY,

        MISSING_KEY,

        /** `null` where this build writes a value or omits the key. Never read as "absent". */
        EXPLICIT_NULL,

        WRONG_TYPE,

        /** The right type with a value outside the format: an unknown enum case, a malformed id, bad base64. */
        INVALID_VALUE,

        /** Each value is valid alone and they contradict each other (a cursor without its kind, …). */
        INCONSISTENT,
    }

    override fun equals(other: Any?): Boolean = other is StrictDecodeFailure && kind == other.kind && path == other.path
    override fun hashCode(): Int = kind.hashCode() * 31 + path.hashCode()
}

/**
 * Reads `schemaVersion` without decoding the rest (`SchemaVersionProbe` in
 * `SyncStateFile.swift`).
 *
 * The probe exists because decoding a file from another schema may fail outright, and
 * that failure has to land in "this build must not touch the file", never in "the file
 * is damaged, start over". So it reads as leniently as Foundation's `JSONDecoder` does:
 * only the structure is scanned, and nothing but the one key is looked at.
 */
internal object SchemaVersionProbe {

    /** `null` when the bytes are not a JSON object or hold no integral `schemaVersion`. */
    fun probe(data: ByteArray): Long? = try {
        val root = FoundationJson.parse(data) as? FoundationJsonNode.Object
        val node = root?.members()?.get("schemaVersion") as? FoundationJsonNode.Number
        node?.doubleValue()?.let(::integral)
    } catch (_: FoundationJsonException) {
        null
    }

    /** The same answer from an already parsed document. */
    fun of(document: JsonValue): Long? = when (val value = document.objectOrNull?.get("schemaVersion")) {
        is JsonValue.Integer -> value.value
        is JsonValue.Real -> integral(value.value)
        else -> null
    }

    /**
     * The integer a version number spells, or `null` for a fraction or a value no `Long`
     * holds. Beyond 2^53 the double is not exact, but no such number is a version this
     * build reads, so an approximate [Long] still lands the file in "unsupported".
     */
    private fun integral(value: Double): Long? {
        if (value.isNaN() || value != Math.rint(value)) return null
        if (value < -9.223372036854775807E18 || value >= 9.223372036854775807E18) return null
        return value.toLong()
    }
}

/**
 * A JSON object read with a closed key set: every key must be one the caller names, and
 * an explicit `null` is never the same as an absent key unless the caller asks for the
 * Swift `decodeIfPresent` reading with [nullable].
 */
internal class StrictObject(value: JsonValue, private val path: String, allowed: Set<String>) {

    private val members: Map<String, JsonValue> =
        value.objectOrNull ?: fail(StrictDecodeFailure.Kind.NOT_AN_OBJECT, path)

    init {
        for (key in members.keys) {
            if (key !in allowed) fail(StrictDecodeFailure.Kind.UNKNOWN_KEY, path)
        }
    }

    val size: Int get() = members.size

    fun contains(key: String): Boolean = members.containsKey(key)

    fun pathOf(key: String): String = if (path.isEmpty()) key else "$path.$key"

    /** The value, which must be there and must not be `null`. */
    fun required(key: String): JsonValue {
        val value = members[key] ?: fail(StrictDecodeFailure.Kind.MISSING_KEY, pathOf(key))
        if (value.isNull) fail(StrictDecodeFailure.Kind.EXPLICIT_NULL, pathOf(key))
        return value
    }

    /** The value or `null` when the key is absent. An explicit `null` is refused. */
    fun optional(key: String): JsonValue? {
        val value = members[key] ?: return null
        if (value.isNull) fail(StrictDecodeFailure.Kind.EXPLICIT_NULL, pathOf(key))
        return value
    }

    /** Swift's `decodeIfPresent`: an absent key and an explicit `null` are both `null`. */
    fun nullable(key: String): JsonValue? = members[key]?.takeUnless { it.isNull }

    fun string(key: String): String = text(required(key), pathOf(key))

    fun optionalString(key: String): String? = optional(key)?.let { text(it, pathOf(key)) }

    fun bool(key: String): Boolean = required(key).boolOrNull ?: fail(StrictDecodeFailure.Kind.WRONG_TYPE, pathOf(key))

    fun optionalBool(key: String): Boolean? =
        optional(key)?.let { it.boolOrNull ?: fail(StrictDecodeFailure.Kind.WRONG_TYPE, pathOf(key)) }

    /** An integer token. `5.0` is a real and is refused. */
    fun long(key: String): Long = required(key).longOrNull ?: fail(StrictDecodeFailure.Kind.WRONG_TYPE, pathOf(key))

    fun int(key: String): Int {
        val value = long(key)
        if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) fail(StrictDecodeFailure.Kind.INVALID_VALUE, pathOf(key))
        return value.toInt()
    }

    /** A finite number; an integer token is widened. */
    fun finiteDouble(key: String): Double {
        val value = required(key).doubleOrNull ?: fail(StrictDecodeFailure.Kind.WRONG_TYPE, pathOf(key))
        if (!value.isFinite()) fail(StrictDecodeFailure.Kind.INVALID_VALUE, pathOf(key))
        return value
    }

    /** A UUID in the lowercase spelling this app writes. */
    fun optionalLowercaseUuid(key: String): UUID? = optionalString(key)?.let {
        Uuids.parseLowercase(it) ?: fail(StrictDecodeFailure.Kind.INVALID_VALUE, pathOf(key))
    }

    fun lowercaseUuid(key: String): UUID =
        Uuids.parseLowercase(string(key)) ?: fail(StrictDecodeFailure.Kind.INVALID_VALUE, pathOf(key))

    companion object {

        fun fail(kind: StrictDecodeFailure.Kind, path: String): Nothing = throw StrictDecodeFailure(kind, path)

        /** Strict JSON: no trailing comma, no duplicate key, valid UTF-8, nothing after the value. */
        fun parseDocument(data: ByteArray): JsonValue = try {
            CanonicalJson.parse(data)
        } catch (_: CanonicalJson.Failure) {
            fail(StrictDecodeFailure.Kind.NOT_JSON, "")
        }

        fun text(value: JsonValue, path: String): String {
            if (value !is JsonValue.Text && value !is JsonValue.Utf8) fail(StrictDecodeFailure.Kind.WRONG_TYPE, path)
            return value.textOrNull ?: fail(StrictDecodeFailure.Kind.INVALID_VALUE, path)
        }
    }
}
