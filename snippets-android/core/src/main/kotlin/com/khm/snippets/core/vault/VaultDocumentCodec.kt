package com.khm.snippets.core.vault

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.FoundationJsonWriter
import com.khm.snippets.core.model.SnippetTagging
import java.util.UUID

/** The bytes are not a vault document. [kind] is the `DecodingError` case Swift reports for the same input. */
class VaultDecodeException internal constructor(val kind: Kind, detail: String) : Exception(detail) {
    enum class Kind { KEY_NOT_FOUND, VALUE_NOT_FOUND, TYPE_MISMATCH, DATA_CORRUPTED }
}

/** The document cannot be written as JSON: a timestamp or a passthrough number is not finite. */
class VaultEncodeException internal constructor(detail: String) : Exception(detail)

/**
 * The hand-written `Codable` conformances of `VaultDocument.swift`, for both places a
 * vault document is stored.
 *
 * The rule for a record: `id` and `sealed` are required; every other field that is
 * missing or has the wrong type takes a default, because the ciphertext is the only part
 * that cannot be retyped. Document keys are the opposite: `schemaVersion`, `kid`,
 * `vaultSalt`, `kdf` and `records` are required, and a missing `records` array is a
 * decode failure, never an empty vault.
 *
 * Encoding is deterministic: `VaultFile.update` compares the file's bytes with what it
 * wrote. The bytes are the ones Foundation's `JSONEncoder` produces with
 * `[.prettyPrinted, .sortedKeys]` (vector V14), so a Swift build rewriting the same
 * document changes nothing.
 */
internal object VaultDocumentCodec {

    /** How record timestamps are spelled. */
    enum class Dates {
        /** `vault.json`: ISO-8601 strings with milliseconds. A number is not a date there and reads as absent. */
        ISO_8601,

        /**
         * The backup payload. Written as numbers (seconds since 2001), which is what Swift
         * writes. Read as a number or as an ISO-8601 string: Linux writes strings, and
         * Swift silently turns those into `distantPast`, which this deliberately does not.
         */
        BACKUP_PAYLOAD,
    }

    private val DOCUMENT_KEYS = setOf(
        "schemaVersion", "kid", "vaultSalt", "kdf", "wrapPass", "wrapRecovery", "wrapCLI", "records",
    )
    private val KDF_KEYS = setOf("alg", "iterations", "saltP")
    private val RECORD_KEYS = setOf(
        "id", "name", "keyword", "tags", "isEnabled", "isPinned",
        "createdAt", "updatedAt", "hlc", "contentHash", "sealed",
    )

    // Encoding

    @Throws(VaultEncodeException::class)
    fun encode(document: VaultDocument, dates: Dates): ByteArray = try {
        FoundationJsonWriter.prettyPrinted(value(document, dates))
    } catch (_: FoundationJsonWriter.NonFiniteNumber) {
        throw VaultEncodeException("a number in the vault is not finite")
    }

    @Throws(VaultEncodeException::class)
    fun value(document: VaultDocument, dates: Dates): JsonValue {
        val members = LinkedHashMap<String, JsonValue>()
        members["schemaVersion"] = JsonValue.Integer(document.schemaVersion)
        members["kid"] = JsonValue.Text(document.kid)
        members["vaultSalt"] = JsonValue.Text(document.vaultSalt)
        members["kdf"] = value(document.kdf)
        // Explicit nulls: a key that vanishes looks exactly like an older build stripping it.
        members["wrapPass"] = optionalText(document.wrapPass)
        members["wrapRecovery"] = optionalText(document.wrapRecovery)
        members["wrapCLI"] = optionalText(document.wrapCLI)
        members["records"] = JsonValue.Array(document.records.map { value(it, dates) })
        putBag(members, document.x, DOCUMENT_KEYS)
        return JsonValue.Object(members)
    }

    private fun value(kdf: VaultKdfParameters): JsonValue {
        val members = LinkedHashMap<String, JsonValue>()
        members["alg"] = JsonValue.Text(kdf.alg)
        members["iterations"] = JsonValue.Integer(kdf.iterations)
        members["saltP"] = JsonValue.Text(kdf.saltP)
        putBag(members, kdf.x, KDF_KEYS)
        return JsonValue.Object(members)
    }

    private fun value(record: VaultRecord, dates: Dates): JsonValue {
        val members = LinkedHashMap<String, JsonValue>()
        members["id"] = JsonValue.Text(Uuids.uppercase(record.id))
        members["name"] = JsonValue.Text(record.name)
        members["keyword"] = JsonValue.Text(record.keyword)
        members["tags"] = JsonValue.Array(record.tags.map { JsonValue.Text(it) })
        members["isEnabled"] = JsonValue.Bool(record.isEnabled)
        members["isPinned"] = JsonValue.Bool(record.isPinned)
        members["createdAt"] = date(record.createdAt, dates)
        members["updatedAt"] = date(record.updatedAt, dates)
        members["hlc"] = JsonValue.Text(record.hlc.string)
        members["contentHash"] = JsonValue.Text(record.contentHash)
        members["sealed"] = JsonValue.Text(record.sealed)
        putBag(members, record.x, RECORD_KEYS)
        return JsonValue.Object(members)
    }

    private fun date(appleSeconds: Double, dates: Dates): JsonValue {
        if (!appleSeconds.isFinite()) throw VaultEncodeException("a record timestamp is not finite")
        return when (dates) {
            Dates.ISO_8601 -> JsonValue.Text(VaultTimestamp.string(appleSeconds))
            Dates.BACKUP_PAYLOAD -> JsonValue.Real(appleSeconds)
        }
    }

    private fun optionalText(text: String?): JsonValue = if (text == null) JsonValue.Null else JsonValue.Text(text)

    // A bag entry named after a real field is never written: two keys with one name
    // would make the file mean different things to different parsers.
    private fun putBag(members: MutableMap<String, JsonValue>, bag: Map<String, JsonValue>, known: Set<String>) {
        for ((name, value) in bag) {
            if (name !in known) members[name] = value
        }
    }

    // Decoding

    @Throws(VaultDecodeException::class)
    fun decode(data: ByteArray, dates: Dates): VaultDocument = translating {
        document(LenientJson.parseOrCorrupt(data), dates)
    }

    @Throws(VaultDecodeException::class)
    fun decodeMetadata(data: ByteArray): VaultMetadata = translating {
        val members = LenientJson.members(LenientJson.parseOrCorrupt(data))
        val schemaVersion = LenientJson.long(LenientJson.required(members, "schemaVersion"))
        val records = LenientJson.array(LenientJson.required(members, "records"))
        VaultMetadata(schemaVersion, records.map { record(it, Dates.ISO_8601).shell })
    }

    /** `VaultFile.probeSchemaVersion`: `schemaVersion` alone; `null` when it cannot be read or is absent. */
    fun probeSchemaVersion(data: ByteArray): Long? = try {
        val members = LenientJson.members(LenientJson.parseOrCorrupt(data))
        LenientJson.present(members, "schemaVersion")?.let(LenientJson::long)
    } catch (_: JsonDecodeException) {
        null
    }

    @Throws(JsonDecodeException::class)
    fun document(node: JsonNode, dates: Dates): VaultDocument {
        val members = LenientJson.members(node)
        return VaultDocument(
            schemaVersion = LenientJson.long(LenientJson.required(members, "schemaVersion")),
            kid = LenientJson.string(LenientJson.required(members, "kid")),
            vaultSalt = LenientJson.string(LenientJson.required(members, "vaultSalt")),
            kdf = kdf(LenientJson.required(members, "kdf")),
            // Absent and explicit null both mean "no such wrap"; a value of another type is an error.
            wrapPass = LenientJson.present(members, "wrapPass")?.let(LenientJson::string),
            wrapRecovery = LenientJson.present(members, "wrapRecovery")?.let(LenientJson::string),
            wrapCLI = LenientJson.present(members, "wrapCLI")?.let(LenientJson::string),
            records = LenientJson.array(LenientJson.required(members, "records")).map { record(it, dates) },
            x = LenientJson.bag(members, DOCUMENT_KEYS),
        )
    }

    private fun kdf(node: JsonNode): VaultKdfParameters {
        val members = LenientJson.members(node)
        return VaultKdfParameters(
            alg = LenientJson.string(LenientJson.required(members, "alg")),
            iterations = LenientJson.long(LenientJson.required(members, "iterations")),
            saltP = LenientJson.string(LenientJson.required(members, "saltP")),
            x = LenientJson.bag(members, KDF_KEYS),
        )
    }

    private fun record(node: JsonNode, dates: Dates): VaultRecord {
        val members = LenientJson.members(node)

        // The two that cannot be defaulted.
        val id = uuid(LenientJson.string(LenientJson.required(members, "id")))
        val sealed = LenientJson.string(LenientJson.required(members, "sealed"))

        // Everything below degrades the same way for a wrong type as for a missing key.
        val name = lenient(members, "name", LenientJson::string) ?: ""
        val keyword = lenient(members, "keyword", LenientJson::string) ?: ""
        val tags = SnippetTagging.normalizedTags(
            lenient(members, "tags") { node -> LenientJson.array(node).map(LenientJson::string) } ?: emptyList(),
        )
        val isEnabled = lenient(members, "isEnabled", LenientJson::boolean) ?: true
        val isPinned = lenient(members, "isPinned", LenientJson::boolean) ?: false
        val contentHash = lenient(members, "contentHash", LenientJson::string) ?: ""

        val decodedCreatedAt = lenient(members, "createdAt") { date(it, dates) }
        val decodedUpdatedAt = lenient(members, "updatedAt") { date(it, dates) }
        // The distant past, never "now": an undated record must lose every merge, not win them.
        val createdAt = decodedCreatedAt ?: decodedUpdatedAt ?: VaultTimestamp.DISTANT_PAST
        val updatedAt = decodedUpdatedAt ?: createdAt

        val hlc = lenient(members, "hlc") { node ->
            Hlc.parse(LenientJson.string(node)) ?: throw LenientJson.corrupted("malformed HLC")
        } ?: Hlc.foreign(updatedAt)

        return VaultRecord(
            id, name, keyword, tags, isEnabled, isPinned, createdAt, updatedAt, hlc, contentHash, sealed,
            LenientJson.bag(members, RECORD_KEYS),
        )
    }

    // `(try? container.decodeIfPresent(…))`: absent, null and undecodable are all `null`.
    private inline fun <T> lenient(members: JsonNode.Members, key: String, read: (JsonNode) -> T): T? {
        val node = LenientJson.present(members, key) ?: return null
        return try {
            read(node)
        } catch (_: JsonDecodeException) {
            null
        }
    }

    private fun date(node: JsonNode, dates: Dates): Double {
        if (node is JsonNode.Num && dates == Dates.BACKUP_PAYLOAD) return LenientJson.double(node)
        val raw = LenientJson.string(node)
        return VaultTimestamp.parse(raw) ?: throw LenientJson.corrupted("malformed timestamp; expected ISO-8601")
    }

    /**
     * `UUID(uuidString:)`: 8-4-4-4-12 hex digits of either case. Foundation hands the
     * text to C `uuid_parse`, which stops at a NUL, so anything after one is ignored.
     */
    internal fun uuid(text: String): UUID {
        val terminator = text.indexOf('\u0000')
        return Uuids.parse(if (terminator < 0) text else text.substring(0, terminator))
            ?: throw LenientJson.corrupted("not a UUID")
    }

    // `PassphraseKDF.WrappedKey`, whose `Codable` conformance Swift synthesizes: four required keys.

    fun value(wrapped: PassphraseKdf.WrappedKey): JsonValue = JsonValue.Object(
        linkedMapOf(
            "alg" to JsonValue.Text(wrapped.alg),
            "iterations" to JsonValue.Integer(wrapped.iterations),
            "salt" to JsonValue.Text(wrapped.salt),
            "envelope" to JsonValue.Text(wrapped.envelope),
        ),
    )

    @Throws(JsonDecodeException::class)
    fun wrappedKey(node: JsonNode): PassphraseKdf.WrappedKey {
        val members = LenientJson.members(node)
        return PassphraseKdf.WrappedKey(
            alg = LenientJson.string(LenientJson.required(members, "alg")),
            iterations = LenientJson.long(LenientJson.required(members, "iterations")),
            salt = LenientJson.string(LenientJson.required(members, "salt")),
            envelope = LenientJson.string(LenientJson.required(members, "envelope")),
        )
    }

    inline fun <T> translating(block: () -> T): T = try {
        block()
    } catch (failure: JsonDecodeException) {
        throw VaultDecodeException(VaultDecodeException.Kind.valueOf(failure.kind.name), failure.message ?: "")
    }
}

/**
 * The JSON form of [PassphraseKdf.WrappedKey] (`{ "alg", "iterations", "salt",
 * "envelope" }`), which Swift gets from a synthesized `Codable`. All four keys are
 * required; unknown keys are ignored on read.
 */
object WrappedKeyJson {

    fun encode(wrapped: PassphraseKdf.WrappedKey): JsonValue = VaultDocumentCodec.value(wrapped)

    @Throws(VaultDecodeException::class)
    fun decode(data: ByteArray): PassphraseKdf.WrappedKey = VaultDocumentCodec.translating {
        VaultDocumentCodec.wrappedKey(LenientJson.parseOrCorrupt(data))
    }
}
