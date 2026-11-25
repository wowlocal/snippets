package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Utf8
import java.util.Base64

/**
 * The JSON that carries a library's `sync-v1` key material inside a pairing or recovery
 * envelope (`LibraryKeyBootstrap.PortableKeyBundle` in
 * `snippets/Core/LibraryKeyBootstrap.swift`):
 *
 * ```
 * {"key":"<base64 of 32 bytes>","salt":"<base64 of 32 bytes>","schemaVersion":1,"scopeID":"sync-v1"}
 * ```
 *
 * Compact, keys sorted, standard padded base64, `/` not escaped. [jsonData] writes exactly
 * those bytes; they are the plaintext of an AEAD envelope, so they are sealed, never stored.
 *
 * Swift keeps the two halves as base64 strings. This keeps the 64 bytes and never builds a
 * `String` from them, because a JVM string cannot be wiped. [close] zeroes the copy held
 * here.
 */
class PortableKeyBundle private constructor(
    private val materialBytes: ByteArray,
    @Suppress("UNUSED_PARAMETER") owned: Unit,
) : AutoCloseable {

    /**
     * `PortableKeyBundle(material:scopeID:)`. Copies [material].
     *
     * @throws Failure.InvalidFormat unless [material] is 64 bytes and [scopeId] is `sync-v1`.
     */
    @Throws(Failure::class)
    constructor(material: ByteArray, scopeId: String = SyncKeyMaterial.SCOPE_ID) : this(
        if (material.size == SyncKeyMaterial.MATERIAL_BYTE_COUNT && scopeId == SyncKeyMaterial.SCOPE_ID) {
            material.copyOf()
        } else {
            throw Failure.InvalidFormat()
        },
        Unit,
    )

    val schemaVersion: Int get() = SCHEMA_VERSION

    val scopeId: String get() = SyncKeyMaterial.SCOPE_ID

    /** The 64 bytes, `key ‖ salt`, as [SyncKeyMaterial.keyring] takes them. A copy the caller wipes. */
    fun material(): ByteArray = materialBytes.copyOf()

    /** The exact bytes Swift's `jsonData` produces. A new array the caller wipes. */
    fun jsonData(): ByteArray {
        val keyHalf = materialBytes.copyOfRange(0, SnippetCrypto.KEY_BYTE_COUNT)
        val saltHalf = materialBytes.copyOfRange(SnippetCrypto.KEY_BYTE_COUNT, SyncKeyMaterial.MATERIAL_BYTE_COUNT)
        val key = Base64.getEncoder().encode(keyHalf)
        val salt = Base64.getEncoder().encode(saltHalf)
        try {
            return Bytes.concat(
                Utf8.encode("{\"key\":\""), key,
                Utf8.encode("\",\"salt\":\""), salt,
                Utf8.encode("\",\"schemaVersion\":$SCHEMA_VERSION,\"scopeID\":\"${SyncKeyMaterial.SCOPE_ID}\"}"),
            )
        } finally {
            keyHalf.fill(0)
            key.fill(0)
        }
    }

    /** Zeroes the material held here. The bundle is unusable afterwards. */
    override fun close() {
        materialBytes.fill(0)
    }

    override fun equals(other: Any?): Boolean =
        other is PortableKeyBundle && Bytes.constantTimeEquals(materialBytes, other.materialBytes)

    // Not derived from the key: equal bundles are equal anyway, and nothing hashes these.
    override fun hashCode(): Int = SCHEMA_VERSION

    override fun toString(): String = "PortableKeyBundle(redacted)"

    /**
     * Swift throws `LibraryKeyBootstrap.Failure.invalidFormat` for a bundle that is
     * well-formed JSON with the wrong content, and lets Foundation's own error out for
     * input that is not JSON or has a member of the wrong JSON type. Those are the two
     * cases here.
     */
    sealed class Failure(message: String) : Exception(message) {
        class InvalidFormat : Failure("the key bundle is not in a format this build understands")
        class Undecodable : Failure("the key bundle is not readable JSON")
    }

    companion object {

        const val SCHEMA_VERSION: Int = 1

        /** A reader refuses anything longer before it parses. */
        const val MAXIMUM_JSON_BYTES: Int = 2_048

        private val KEYS = setOf("schemaVersion", "scopeID", "key", "salt")

        /**
         * `PortableKeyBundle(jsonData:)`: at most [MAXIMUM_JSON_BYTES] bytes, a JSON object
         * with exactly the four keys in any order and with any JSON whitespace,
         * `schemaVersion` 1 (`1.0` is read as 1, as Foundation does), `scopeID` `sync-v1`,
         * and both values the canonical padded base64 of 32 bytes.
         *
         * The JSON reader is the strict canonical one, so input Foundation tolerates and no
         * Snippets build writes (a byte order mark, UTF-16, duplicate keys) is refused.
         *
         * @throws Failure.Undecodable when [jsonData] is not JSON, is a bare scalar, or a
         *   member has the wrong JSON type.
         * @throws Failure.InvalidFormat for everything else.
         */
        @Throws(Failure::class)
        fun fromJson(jsonData: ByteArray): PortableKeyBundle {
            if (jsonData.size > MAXIMUM_JSON_BYTES) throw Failure.InvalidFormat()
            val root = try {
                CanonicalJson.parse(jsonData)
            } catch (_: CanonicalJson.Failure) {
                throw Failure.Undecodable()
            }
            val wipeable = ArrayList<ByteArray>(6)
            try {
                val members = when (root) {
                    is JsonValue.Object -> root.members
                    is JsonValue.Array -> throw Failure.InvalidFormat()
                    // Foundation refuses a top-level scalar outright.
                    else -> throw Failure.Undecodable()
                }
                // The parser's own copies of the two values, one of which is the key.
                for (value in members.values) (value as? JsonValue.Utf8)?.let { wipeable.add(it.bytes) }
                if (members.keys != KEYS) throw Failure.InvalidFormat()

                val schemaVersion = integer(members.getValue("schemaVersion")) ?: throw Failure.Undecodable()
                val scope = members.getValue("scopeID").let {
                    if (it is JsonValue.Utf8 || it is JsonValue.Text) it.textOrNull else null
                } ?: throw Failure.Undecodable()
                val keyText = string(members.getValue("key")) ?: throw Failure.Undecodable()
                val saltText = string(members.getValue("salt")) ?: throw Failure.Undecodable()

                if (schemaVersion != SCHEMA_VERSION.toLong() || scope != SyncKeyMaterial.SCOPE_ID) {
                    throw Failure.InvalidFormat()
                }
                val key = canonicalBase64(keyText)?.also { wipeable.add(it) } ?: throw Failure.InvalidFormat()
                if (key.size != SnippetCrypto.KEY_BYTE_COUNT) throw Failure.InvalidFormat()
                val salt = canonicalBase64(saltText) ?: throw Failure.InvalidFormat()
                if (salt.size != SnippetCrypto.SALT_BYTE_COUNT) throw Failure.InvalidFormat()
                return PortableKeyBundle(Bytes.concat(key, salt), Unit)
            } finally {
                for (bytes in wipeable) bytes.fill(0)
            }
        }

        /** A JSON string's bytes; `null` for any other JSON type. */
        private fun string(value: JsonValue): ByteArray? =
            if (value is JsonValue.Utf8 || value is JsonValue.Text) value.utf8OrNull else null

        /** `JSONDecoder` reading an `Int`: an integer token, or a number that is a whole 64-bit value. */
        private fun integer(value: JsonValue): Long? = when (value) {
            is JsonValue.Integer -> value.value
            is JsonValue.Real -> {
                val number = value.value
                val whole = number.toLong()
                // 2^63 itself rounds down to `Long.MAX_VALUE` and is not a 64-bit integer.
                if (whole.toDouble() == number && number < 9.223372036854775807E18) whole else null
            }
            else -> null
        }

        /**
         * `Data(base64Encoded:)` followed by `data.base64EncodedString() == value`: only
         * the canonical spelling passes. Works on bytes, so the key never becomes a `String`.
         */
        private fun canonicalBase64(text: ByteArray): ByteArray? {
            val decoded = try {
                Base64.getDecoder().decode(text)
            } catch (_: IllegalArgumentException) {
                return null
            }
            val again = Base64.getEncoder().encode(decoded)
            val isCanonical = again.contentEquals(text)
            again.fill(0)
            if (!isCanonical) {
                decoded.fill(0)
                return null
            }
            return decoded
        }
    }
}
