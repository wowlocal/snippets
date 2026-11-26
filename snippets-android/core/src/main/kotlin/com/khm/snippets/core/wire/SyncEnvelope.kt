package com.khm.snippets.core.wire

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID

/**
 * The full record as it exists inside the encrypted blob (`SyncEnvelope` in
 * `snippets/Core/SyncEnvelope.swift`). Every byte of its canonical form is hashed, so two
 * devices that hold the same record must produce the same bytes.
 *
 * ## The key set is frozen at exactly ten
 *
 * `schemaVersion`, `id`, `hlc`, `origin`, `secure`, `deleted`, `hash`, `contentHash`,
 * `fields`, `x`. A device that has not been updated round-trips every record in the
 * library, so the top-level key set never grows: a future field goes inside [x], which
 * every build preserves without understanding it. An envelope with an unknown top-level
 * key is refused, never stripped. `hash` and `contentHash` are computed, not stored, so an
 * envelope with a stale hash cannot be held.
 *
 * ## Two ways in
 *
 * - **New local values** go through the public constructor (and [plain], [secureRecord],
 *   [tombstone], [tombstoned]), which normalises: [origin] through [Hlc.normalizedDevice],
 *   tags through [SnippetTagging.normalizedTags], no [fields] on a tombstone, no
 *   `userDeletion.v1` on a live record.
 * - **Bytes already on the wire** go through [parse], which takes every member as it is
 *   spelled. Yesterday's hashed bytes are never fed through today's normalisers.
 *
 * Immutable. [copy] stands in for assigning one of Swift's `var` members and, like that
 * assignment, normalises nothing.
 *
 * Equality is Swift's: [origin] and the text of [fields] by canonical equivalence, bodies
 * and [x] values by their bytes. Two envelopes can be equal and still hash differently
 * (`é` precomposed and decomposed); compare [envelopeHash] where the bytes matter.
 */
class SyncEnvelope private constructor(
    /** Swift holds an `Int`; a parsed envelope may carry any value up to [CURRENT_SCHEMA_VERSION], including zero and below. */
    val schemaVersion: Long,
    val id: UUID,
    val hlc: Hlc,
    /** The device that produced this version. Eight lowercase hex characters; inside the blob. */
    val origin: String,
    /** Whether the record belongs in `Vault/vault.json` and not in `snippets.json`. Inside the blob. */
    val secure: Boolean,
    /** A tombstone. Always accompanied by `fields == null`. */
    val deleted: Boolean,
    fields: Fields?,
    x: Map<String, JsonValue>,
    @Suppress("UNUSED_PARAMETER") verbatim: Unit,
) {

    /**
     * The user-meaningful payload; `null` exactly on a tombstone. The pairing cannot be
     * broken from outside: a deleted secret must not linger in the blob, in the tombstone
     * the backend keeps, or in a dump of an envelope.
     */
    val fields: Fields? = if (deleted) null else fields

    /**
     * The forward-compatibility bag: anything a newer build added, preserved by every
     * older build, plus narrowly typed encrypted protocol metadata (vault scope, explicit
     * tombstone intent). Unmodifiable; keys keep the order they were given in, which the
     * canonical emitter ignores.
     */
    val x: Map<String, JsonValue> = Collections.unmodifiableMap(LinkedHashMap(x))

    /**
     * A new local envelope. Normalises [origin], drops [fields] when [deleted], and
     * removes `userDeletion.v1` from [x] unless [deleted].
     *
     * Swift declares `schemaVersion` first; it is last here so the common call needs no
     * placeholder for it.
     */
    constructor(
        id: UUID,
        hlc: Hlc,
        origin: String,
        secure: Boolean,
        deleted: Boolean,
        fields: Fields?,
        x: Map<String, JsonValue> = emptyMap(),
        schemaVersion: Long = CURRENT_SCHEMA_VERSION,
    ) : this(
        schemaVersion, id, hlc, Hlc.normalizedDevice(origin), secure, deleted, fields,
        if (deleted) x else x - USER_INITIATED_DELETION_EXTENSION_KEY,
        Unit,
    )

    /**
     * This envelope with some members replaced, exactly as given: [origin] is not
     * normalised and [x] is not stripped, as when Swift assigns `envelope.origin` or
     * `envelope.x[key]`. [deleted] and [fields] cannot be changed this way; use
     * [tombstoned] or build a new envelope.
     */
    fun copy(
        id: UUID = this.id,
        hlc: Hlc = this.hlc,
        origin: String = this.origin,
        secure: Boolean = this.secure,
        x: Map<String, JsonValue> = this.x,
        schemaVersion: Long = this.schemaVersion,
    ): SyncEnvelope = SyncEnvelope(schemaVersion, id, hlc, origin, secure, deleted, fields, x, Unit)

    /** [copy] with one member of [x] set (`envelope.x[key] = value`), or removed when [value] is `null`. */
    fun withExtension(key: String, value: JsonValue?): SyncEnvelope =
        copy(x = if (value == null) x - key else x + (key to value))

    /**
     * The user-meaningful payload, and the shape of a vault record (`SyncEnvelope.Fields`).
     *
     * [content] is bytes, not a `String`: a secure record's body passes through here and
     * a string cannot be wiped. For a secure record the bytes are the vault's sealed text,
     * not the plaintext.
     *
     * The public constructor is for new local values and normalises [tags] with
     * [SnippetTagging.normalizedTags]; it also repairs an unpaired surrogate in a text
     * member to U+FFFD, which is what Swift does when the string is created. Parsed
     * fields keep every spelling. [copy] replaces members exactly as given.
     *
     * It also drops every leading U+FEFF from [name], [keyword] and each tag. Swift reads
     * those members back with `String(data:encoding: .utf8)`, which drops one leading
     * U+FEFF, so an envelope that hashed one fails its hash on every Apple device
     * (`hashMismatch`, Swift refusing even its own such envelopes). This constructor is the
     * one place every locally made envelope passes through (`plain`, `secureRecord` and the
     * merge's conflict copies all build their fields here), so it is the choke point: what
     * Android writes, every device reads back as written. The body is bytes and untouched.
     *
     * Timestamps are raw doubles of seconds since 2001 and are emitted with Swift's
     * `Double.description`; they must never pass through milliseconds or an instant.
     */
    class Fields private constructor(
        val name: String,
        val keyword: String,
        /** Owned by this value and never modified. */
        internal val contentBytes: ByteArray,
        tags: List<String>,
        val isEnabled: Boolean,
        val isPinned: Boolean,
        val createdAt: Double,
        val updatedAt: Double,
        @Suppress("UNUSED_PARAMETER") verbatim: Unit,
    ) {

        val tags: List<String> = Collections.unmodifiableList(ArrayList(tags))

        constructor(
            name: String,
            keyword: String,
            content: ByteArray,
            tags: List<String>,
            isEnabled: Boolean,
            isPinned: Boolean,
            createdAt: Double,
            updatedAt: Double,
        ) : this(
            readableBack(name), readableBack(keyword), content.copyOf(),
            SnippetTagging.normalizedTags(tags.map(::readableBack)),
            isEnabled, isPinned, createdAt, updatedAt, Unit,
        )

        /** The snippet body. A copy. */
        val content: ByteArray get() = contentBytes.copyOf()

        val contentByteCount: Int get() = contentBytes.size

        /** Whether the body is exactly [bytes], without copying it. */
        fun contentEquals(bytes: ByteArray): Boolean = contentBytes.contentEquals(bytes)

        /** Whether the two bodies are byte for byte the same. */
        fun contentEquals(other: Fields): Boolean = contentBytes.contentEquals(other.contentBytes)

        /**
         * These fields with some members replaced, exactly as given: [tags] are not
         * normalised, as when Swift assigns `fields.tags`.
         */
        fun copy(
            name: String = this.name,
            keyword: String = this.keyword,
            content: ByteArray = this.contentBytes,
            tags: List<String> = this.tags,
            isEnabled: Boolean = this.isEnabled,
            isPinned: Boolean = this.isPinned,
            createdAt: Double = this.createdAt,
            updatedAt: Double = this.updatedAt,
        ): Fields = Fields(
            name, keyword, if (content === contentBytes) contentBytes else content.copyOf(), tags,
            isEnabled, isPinned, createdAt, updatedAt, Unit,
        )

        /** The eight-key canonical object. Its `content` is a copy of the body. */
        val canonicalValue: JsonValue get() = canonicalValue(shareContent = false)

        internal fun canonicalValue(shareContent: Boolean): JsonValue = JsonValue.obj(
            "name" to JsonValue.Text(name),
            "keyword" to JsonValue.Text(keyword),
            "content" to JsonValue.Utf8(if (shareContent) contentBytes else contentBytes.copyOf()),
            "tags" to JsonValue.Array(tags.map { JsonValue.Text(it) }),
            "isEnabled" to JsonValue.Bool(isEnabled),
            "isPinned" to JsonValue.Bool(isPinned),
            // Seconds since the 2001 reference epoch, the number the model stores, so the
            // round trip is bit-exact.
            "createdAt" to JsonValue.Real(createdAt),
            "updatedAt" to JsonValue.Real(updatedAt),
        )

        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Fields) return false
            return isEnabled == other.isEnabled &&
                isPinned == other.isPinned &&
                sameInstant(createdAt, other.createdAt) &&
                sameInstant(updatedAt, other.updatedAt) &&
                FoundationText.canonicalEquals(name, other.name) &&
                FoundationText.canonicalEquals(keyword, other.keyword) &&
                tags.size == other.tags.size &&
                tags.indices.all { FoundationText.canonicalEquals(tags[it], other.tags[it]) } &&
                contentBytes.contentEquals(other.contentBytes)
        }

        override fun hashCode(): Int =
            (FoundationText.nfc(keyword).hashCode() * 31 + contentBytes.contentHashCode()) * 31 + tags.size

        /** Names nothing: a snippet's text must not reach a log by accident. */
        override fun toString(): String = "Fields(${contentBytes.size}-byte body, ${tags.size} tags)"

        companion object {

            /** Exactly these, forever. */
            val KEYS: Set<String> = Collections.unmodifiableSet(
                linkedSetOf("name", "keyword", "content", "tags", "isEnabled", "isPinned", "createdAt", "updatedAt"),
            )

            /**
             * Reads the eight-key object. Every member is taken as spelled: nothing is
             * normalised. An unknown key, a missing key, an explicit `null` and a wrong
             * type are all [Failure.Malformed]. `createdAt` and `updatedAt` accept an
             * integer token as a number.
             */
            @Throws(Failure::class)
            fun parse(value: JsonValue): Fields {
                val members = value.objectOrNull ?: throw Failure.Malformed("\"fields\" is not an object")
                val unknown = members.keys - KEYS
                if (unknown.isNotEmpty()) {
                    throw Failure.Malformed("unknown key(s) in \"fields\": ${sortedList(unknown)}")
                }
                fun require(key: String): JsonValue =
                    members[key] ?: throw Failure.Malformed("\"fields\" is missing \"$key\"")

                fun wrongType(): Nothing = throw Failure.Malformed("a \"fields\" member has the wrong type")

                // In Swift's order, so a missing later key is reported only when every
                // earlier member has the right type.
                val name = require("name").textOrNull ?: wrongType()
                val keyword = require("keyword").textOrNull ?: wrongType()
                val content = require("content").utf8OrNull ?: wrongType()
                val tagValues = require("tags").arrayOrNull ?: wrongType()
                val isEnabled = require("isEnabled").boolOrNull ?: wrongType()
                val isPinned = require("isPinned").boolOrNull ?: wrongType()
                val createdAt = require("createdAt").doubleOrNull ?: wrongType()
                val updatedAt = require("updatedAt").doubleOrNull ?: wrongType()

                val tags = tagValues.map {
                    it.textOrNull ?: throw Failure.Malformed("\"tags\" must be an array of strings")
                }
                return Fields(name, keyword, content.copyOf(), tags, isEnabled, isPinned, createdAt, updatedAt, Unit)
            }

            // Swift's `Date ==` is the doubles' `==`; not-a-number is made equal to itself for `equals`.
            private fun sameInstant(first: Double, second: Double): Boolean =
                first == second || (first.isNaN() && second.isNaN())
        }
    }

    /** What [parse] and [WireCodec.open] refuse (`SyncEnvelope.Failure`). Instances compare by case and payload. */
    sealed class Failure(message: String) : Exception(message) {

        /** Written by a newer build. Show it, never push it back. */
        class TooNew(val version: Long) :
            Failure("this record was written by a newer version of Snippets (envelope schema $version)")

        class Malformed(val detail: String) : Failure("malformed sync envelope: $detail")

        /**
         * The envelope parsed, but its `hash` or `contentHash` does not describe its
         * contents. Behind the AEAD tag, this also catches an encoder that drifted.
         */
        class HashMismatch : Failure("sync envelope hash does not match its contents")

        /**
         * The blob's id, rev or deletion flag disagrees with the [WireRecord] that carried
         * it: a backend swapping blobs between records.
         */
        class IdentityMismatch(val detail: String) :
            Failure("sync envelope does not match the record that carried it: $detail")

        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Failure || javaClass != other.javaClass) return false
            return when (this) {
                is TooNew -> version == (other as TooNew).version
                is Malformed -> detail == (other as Malformed).detail
                is IdentityMismatch -> detail == (other as IdentityMismatch).detail
                is HashMismatch -> true
            }
        }

        override fun hashCode(): Int = when (this) {
            is TooNew -> version.hashCode()
            is Malformed -> detail.hashCode()
            is IdentityMismatch -> detail.hashCode()
            is HashMismatch -> 0
        } * 31 + javaClass.hashCode()
    }

    /**
     * SHA-256 of the body bytes, lowercase hex; `null` for a tombstone, which carries no
     * digest of what it used to contain.
     *
     * This is not [com.khm.snippets.core.crypto.SnippetCrypto.contentHash] and the two are
     * never compared: that one is a keyed HMAC of the plaintext, stored in `vault.json` in
     * the clear. This one is unkeyed and exists only inside the sealed blob. For a secure
     * record it covers the vault's sealed text.
     */
    val contentHash: String?
        get() {
            val current = fields
            if (deleted || current == null) return null
            return sha256Hex(current.contentBytes)
        }

    /**
     * The canonical JSON object. With [includingHash] `false` it is the nine-key form the
     * hash is computed over. `fields` and `contentHash` are present as `null` on a
     * tombstone, so the key count never varies.
     *
     * @throws CanonicalJson.Failure when [includingHash] and the hash cannot be computed.
     */
    @Throws(CanonicalJson.Failure::class)
    fun canonicalValue(includingHash: Boolean = true): JsonValue = canonicalValue(includingHash, shareContent = false)

    private fun canonicalValue(includingHash: Boolean, shareContent: Boolean): JsonValue {
        val members = LinkedHashMap<String, JsonValue>()
        members["schemaVersion"] = JsonValue.Integer(schemaVersion)
        members["id"] = JsonValue.Text(Uuids.lowercase(id))
        members["hlc"] = JsonValue.Text(hlc.string)
        members["origin"] = JsonValue.Text(origin)
        members["secure"] = JsonValue.Bool(secure)
        members["deleted"] = JsonValue.Bool(deleted)
        members["contentHash"] = contentHash?.let { JsonValue.Text(it) } ?: JsonValue.Null
        // `if (deleted) null else fields`, although the constructor already enforces it:
        // this is the one point where bytes leave the process.
        members["fields"] = (if (deleted) null else fields)?.canonicalValue(shareContent) ?: JsonValue.Null
        members["x"] = JsonValue.Object(x)
        if (includingHash) members["hash"] = JsonValue.Text(envelopeHash())
        return JsonValue.Object(members)
    }

    /**
     * The full ten-key canonical bytes: what gets sealed, and what a base stores (Swift
     * `canonicalData()`). The caller owns the array.
     *
     * @throws CanonicalJson.Failure for what canonical JSON cannot spell: a number in [x]
     *   that is not finite, a body or a string that is not valid UTF-8, two keys of one
     *   object in [x] that differ only in normalisation.
     */
    @Throws(CanonicalJson.Failure::class)
    fun canonicalBytes(): ByteArray = CanonicalJson.encode(canonicalValue(includingHash = true, shareContent = true))

    /**
     * SHA-256 over the nine-key canonical form, lowercase hex.
     *
     * @throws CanonicalJson.Failure as [canonicalBytes]: a hash of nothing is never returned.
     */
    @Throws(CanonicalJson.Failure::class)
    fun envelopeHash(): String {
        val preimage = CanonicalJson.encode(canonicalValue(includingHash = false, shareContent = true))
        try {
            return sha256Hex(preimage)
        } finally {
            preimage.fill(0)
        }
    }

    // Conversions

    /**
     * The exact live-envelope hashes an explicit delete action in a Snippets UI meant to
     * remove, from `x["userDeletion.v1"]` of a tombstone. Empty unless the marker is one
     * to eight unique lowercase SHA-256 strings.
     */
    val userInitiatedDeletionAncestorHashes: Set<String>
        get() {
            if (!deleted) return emptySet()
            val values = x[USER_INITIATED_DELETION_EXTENSION_KEY]?.arrayOrNull ?: return emptySet()
            return validUserDeletionHashes(values)?.toCollection(LinkedHashSet()) ?: emptySet()
        }

    /** Whether this tombstone proves it came from an explicit delete action. */
    val carriesUserInitiatedDeletion: Boolean get() = userInitiatedDeletionAncestorHashes.isNotEmpty()

    /**
     * Turns a live record into its own tombstone: the only supported way to delete an
     * envelope, because it cannot leave the body attached.
     *
     * [x] does not travel: a future build could have put anything in there, including
     * something derived from the content. One structural exception survives on a secure
     * record, `vaultKID`, which stops a rival vault's tombstone from deleting a record
     * that was authenticated under another crypto scope.
     */
    fun tombstoned(hlc: Hlc, origin: String): SyncEnvelope {
        val extensions = LinkedHashMap<String, JsonValue>()
        if (secure) x[VAULT_KEY_ID_EXTENSION_KEY]?.let { extensions[VAULT_KEY_ID_EXTENSION_KEY] = it }
        return SyncEnvelope(
            id = id, hlc = hlc, origin = origin, secure = secure, deleted = true, fields = null, x = extensions,
        )
    }

    /**
     * The `snippets.json` view. `null` for a tombstone, for a secure record (a secure body
     * is never handed to a caller that expects text for the plaintext library) and for a
     * body that is not valid UTF-8.
     */
    val plainSnippet: Snippet?
        get() {
            val current = fields
            if (deleted || secure || current == null) return null
            // The final hop: the body becomes a `String` here and nowhere earlier. Swift's
            // `String(data:encoding: .utf8)`, so one leading U+FEFF of the body is dropped.
            val content = Utf8.decodeStrict(current.contentBytes) ?: return null
            return Snippet(
                id = id, name = current.name, keyword = current.keyword, content = content,
                tags = current.tags, isEnabled = current.isEnabled, isPinned = current.isPinned,
                createdAt = current.createdAt, updatedAt = current.updatedAt,
            )
        }

    /** The `Vault/vault.json` view: metadata plus the body as bytes. `null` unless live and secure. */
    val vaultFields: Fields? get() = if (!deleted && secure) fields else null

    /** The body, as bytes, whichever store the record belongs to. A copy; `null` for a tombstone. */
    val plaintext: ByteArray? get() = if (deleted) null else fields?.content

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SyncEnvelope) return false
        return schemaVersion == other.schemaVersion &&
            id == other.id &&
            secure == other.secure &&
            deleted == other.deleted &&
            hlc == other.hlc &&
            FoundationText.canonicalEquals(origin, other.origin) &&
            fields == other.fields &&
            x == other.x
    }

    override fun hashCode(): Int = (id.hashCode() * 31 + hlc.hashCode()) * 31 + deleted.hashCode()

    /** Names the record only: nothing of its text. */
    override fun toString(): String = "SyncEnvelope(id=$id, hlc=$hlc, secure=$secure, deleted=$deleted)"

    companion object {

        const val CURRENT_SCHEMA_VERSION: Long = 1

        /**
         * The vault's keyed plaintext hash, inside [x].
         *
         * The top-level `contentHash` is the SHA-256 of `fields.content`, which for a
         * secure record is the sealed value, so it can never be written to
         * `VaultRecord.contentHash`. Keeping the HMAC in [x] lets a locked peer preserve it.
         */
        const val VAULT_CONTENT_HASH_EXTENSION_KEY: String = "vaultContentHash"

        /**
         * The `kid` of the vault whose key sealed this record's body, inside [x], so that
         * an import can compare vaults before it writes. Absent on old records, which
         * means "assume it matches".
         */
        const val VAULT_KEY_ID_EXTENSION_KEY: String = "vaultKID"

        /**
         * Authenticated proof that a tombstone came from an explicit delete action: the
         * bounded set of live-envelope hashes that action meant to remove. Tombstone-only,
         * and it does not survive a recreation.
         */
        const val USER_INITIATED_DELETION_EXTENSION_KEY: String = "userDeletion.v1"

        /** The most ancestor hashes a `userDeletion.v1` marker may hold. */
        const val MAXIMUM_USER_DELETION_ANCESTORS: Int = 8

        /** Exactly these, forever. */
        val TOP_LEVEL_KEYS: Set<String> = Collections.unmodifiableSet(
            linkedSetOf(
                "schemaVersion", "id", "hlc", "origin", "secure", "deleted",
                "hash", "contentHash", "fields", "x",
            ),
        )

        /** Lowercase hex SHA-256 of [bytes]. */
        fun sha256Hex(bytes: ByteArray): String = Bytes.toHex(MessageDigest.getInstance("SHA-256").digest(bytes))

        /** An ordinary snippet from `snippets.json`. */
        fun plain(
            snippet: Snippet,
            hlc: Hlc,
            origin: String,
            x: Map<String, JsonValue> = emptyMap(),
        ): SyncEnvelope = SyncEnvelope(
            id = snippet.id, hlc = hlc, origin = origin, secure = false, deleted = false,
            fields = Fields(
                name = snippet.name, keyword = snippet.keyword,
                content = Utf8.encode(snippet.content), tags = snippet.tags,
                isEnabled = snippet.isEnabled, isPinned = snippet.isPinned,
                createdAt = snippet.createdAt, updatedAt = snippet.updatedAt,
            ),
            x = x,
        )

        /**
         * A vault record. [plaintext] is the body as the envelope carries it, which on the
         * sync path is the vault's sealed text; it arrives as bytes and stays bytes.
         */
        fun secureRecord(
            id: UUID,
            name: String,
            keyword: String,
            plaintext: ByteArray,
            tags: List<String> = emptyList(),
            isEnabled: Boolean = true,
            isPinned: Boolean = false,
            createdAt: Double,
            updatedAt: Double,
            hlc: Hlc,
            origin: String,
            x: Map<String, JsonValue> = emptyMap(),
        ): SyncEnvelope = SyncEnvelope(
            id = id, hlc = hlc, origin = origin, secure = true, deleted = false,
            fields = Fields(
                name = name, keyword = keyword, content = plaintext, tags = tags,
                isEnabled = isEnabled, isPinned = isPinned, createdAt = createdAt, updatedAt = updatedAt,
            ),
            x = x,
        )

        /** A deletion. `fields` is `null` by construction. */
        fun tombstone(
            id: UUID,
            secure: Boolean,
            hlc: Hlc,
            origin: String,
            x: Map<String, JsonValue> = emptyMap(),
        ): SyncEnvelope = SyncEnvelope(
            id = id, hlc = hlc, origin = origin, secure = secure, deleted = true, fields = null, x = x,
        )

        /**
         * Reads an envelope back out of canonical bytes and checks that it describes
         * itself honestly. Nothing is normalised on the way in.
         *
         * In order: the bytes are strict JSON and an object; `schemaVersion` is an integer
         * and not newer than this build ([Failure.TooNew], before anything else, so a
         * newer record is never reported as corrupt); no top-level key outside the ten;
         * every member present, not `null` where a value is required, and of its type;
         * `origin` already in its canonical spelling; `userDeletion.v1` well-formed and
         * only on a tombstone; `fields` and `contentHash` both `null` on a tombstone and
         * `fields` present on a live record; then the declared `hash` and `contentHash`
         * equal the recomputed ones ([Failure.HashMismatch]).
         *
         * An `id` in uppercase is read as the same UUID, as Foundation reads it. The hash
         * always covers the lowercase spelling, so such bytes pass only if their `hash`
         * was computed over the lowercase id, and they are re-emitted in lowercase.
         *
         * @throws CanonicalJson.Failure when [data] is not canonical-parser JSON, or holds
         *   a number that cannot be emitted again.
         * @throws Failure for everything else.
         */
        @Throws(CanonicalJson.Failure::class, Failure::class)
        fun parse(data: ByteArray): SyncEnvelope {
            val members = CanonicalJson.parse(data).objectOrNull
                ?: throw Failure.Malformed("the envelope is not a JSON object")

            val version = members["schemaVersion"]?.longOrNull
                ?: throw Failure.Malformed("missing or non-integer \"schemaVersion\"")
            if (version > CURRENT_SCHEMA_VERSION) throw Failure.TooNew(version)

            val unknown = members.keys - TOP_LEVEL_KEYS
            if (unknown.isNotEmpty()) {
                // Fatal for this record, not ignored: ignoring means re-emitting the
                // record without those keys.
                throw Failure.Malformed(
                    "unknown top-level key(s): ${sortedList(unknown)}; future fields belong in \"x\"",
                )
            }

            fun require(key: String): JsonValue = members[key] ?: throw Failure.Malformed("missing \"$key\"")

            val id = require("id").textOrNull?.let { Uuids.parse(it) }
                ?: throw Failure.Malformed("\"id\" is not a UUID")
            val hlc = require("hlc").textOrNull?.let { Hlc.parse(it) }
                ?: throw Failure.Malformed("\"hlc\" is not a clock reading")
            val origin = require("origin").textOrNull ?: throw Failure.Malformed("\"origin\" is not a string")
            if (!Hlc.isCanonicalDeviceId(origin)) {
                throw Failure.Malformed("\"origin\" is not an eight-character lowercase hexadecimal device id")
            }
            val secure = require("secure").boolOrNull
                ?: throw Failure.Malformed("\"secure\" and \"deleted\" must be booleans")
            val deleted = require("deleted").boolOrNull
                ?: throw Failure.Malformed("\"secure\" and \"deleted\" must be booleans")
            val declaredHash = require("hash").textOrNull ?: throw Failure.Malformed("\"hash\" is not a string")
            val x = require("x").objectOrNull ?: throw Failure.Malformed("\"x\" is not an object")

            x[USER_INITIATED_DELETION_EXTENSION_KEY]?.let { marker ->
                val values = marker.arrayOrNull
                if (!deleted || values == null || validUserDeletionHashes(values) == null) {
                    throw Failure.Malformed(
                        "\"userDeletion.v1\" must contain one to eight unique lowercase " +
                            "SHA-256 ancestor hashes and may appear only on a tombstone",
                    )
                }
            }

            val fieldsValue = require("fields")
            val fields = if (fieldsValue.isNull) null else Fields.parse(fieldsValue)

            // The tombstone invariant, checked on the way in as well as enforced on the
            // way out.
            if (deleted && fields != null) throw Failure.Malformed("a tombstone must not carry \"fields\"")
            if (!deleted && fields == null) throw Failure.Malformed("a live record must carry \"fields\"")
            val declaredContentHash = require("contentHash")
            if (deleted && !declaredContentHash.isNull) {
                throw Failure.Malformed("a tombstone must not carry \"contentHash\"")
            }

            val envelope = SyncEnvelope(version, id, hlc, origin, secure, deleted, fields, x, Unit)

            if (envelope.envelopeHash() != declaredHash) throw Failure.HashMismatch()
            val expected = envelope.contentHash
            if (expected != null && declaredContentHash.textOrNull != expected) throw Failure.HashMismatch()
            return envelope
        }

        /** The hashes, when [values] is one to eight unique lowercase SHA-256 strings; otherwise `null`. */
        private fun validUserDeletionHashes(values: List<JsonValue>): List<String>? {
            if (values.isEmpty() || values.size > MAXIMUM_USER_DELETION_ANCESTORS) return null
            val hashes = ArrayList<String>(values.size)
            for (value in values) hashes.add(value.textOrNull ?: return null)
            if (hashes.toSet().size != hashes.size) return null
            return if (hashes.all(::isLowercaseSha256)) hashes else null
        }

        private fun isLowercaseSha256(value: String): Boolean =
            value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

        /** `unknown.sorted().joined(separator: ", ")`, in Swift's string order. */
        private fun sortedList(keys: Set<String>): String = keys.sortedWith(FoundationText.order).joinToString(", ")

        /** [wellFormed], without the leading U+FEFFs a Swift reader would not read back. */
        private fun readableBack(text: String): String = Utf8.withoutLeadingByteOrderMarks(wellFormed(text))

        /**
         * A Swift `String` is always well-formed: an unpaired surrogate becomes U+FFFD when
         * the string is created. A Kotlin `String` can hold one, and canonical JSON would
         * refuse it.
         */
        private fun wellFormed(text: String): String {
            var index = 0
            while (index < text.length) {
                val unit = text[index]
                if (unit.isHighSurrogate() && index + 1 < text.length && text[index + 1].isLowSurrogate()) {
                    index += 2
                } else if (unit.isSurrogate()) {
                    return repaired(text)
                } else {
                    index += 1
                }
            }
            return text
        }

        private fun repaired(text: String): String {
            val out = StringBuilder(text.length)
            var index = 0
            while (index < text.length) {
                val unit = text[index]
                if (unit.isHighSurrogate() && index + 1 < text.length && text[index + 1].isLowSurrogate()) {
                    out.append(unit).append(text[index + 1])
                    index += 2
                } else {
                    out.append(if (unit.isSurrogate()) '�' else unit)
                    index += 1
                }
            }
            return out.toString()
        }
    }
}
