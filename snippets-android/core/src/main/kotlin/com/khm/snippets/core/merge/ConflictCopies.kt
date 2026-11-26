package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.crypto.DeterministicUuid
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.model.SnippetDisplayOrder
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.search.SwiftStrings
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.wire.SyncEnvelope
import java.util.Collections
import java.util.UUID

/**
 * Everything about a preserved losing body: the conflict copy of an ordinary record, the
 * conflict variant of a secure one, their names, ids, fingerprints and provenance, and
 * the validators of the reserved members of `x` (the conflict half of `SyncMerge.swift`).
 *
 * Other devices derive every one of these values independently and hash them, so each is
 * byte-exact:
 *
 * - **Snapshot** of a losing envelope: the canonical object `{fields, secure, sourceHLC,
 *   sourceID, sourceOrigin, version: 1, x}`, where `x` holds only `vaultContentHash` and
 *   `vaultKID` when the source has them. Its lowercase hex SHA-256 is the **fingerprint**.
 * - **Copy id**: [copyId], a version 5 UUID in the namespace of the source id.
 * - **Plain copy** ([makePlainContentConflictCopy]): an ordinary disabled record under
 *   the copy id that carries the **provenance** `x["conflictCopy.v1"]`.
 * - **Secure variant** ([makeSecureContentConflictVariant]): one member of the
 *   survivor's `x`, `contentConflict.v1.<fingerprint>`, holding the snapshot plus
 *   `copyID`. A vault seal is bound to its record id, so it cannot be filed under the
 *   copy id until a layer with the vault key opens and reseals it.
 *
 * Every secure losing version is its own member of `x`, never a nested map: a client that
 * knows nothing of this and merges `x` shallowly then unions the members by itself.
 *
 * Pure functions over immutable values.
 */
object ConflictCopies {

    // Reserved members of `x`

    /** Every unresolved losing version of a record, of any format version, is a member with this prefix. */
    const val CONTENT_CONFLICT_EXTENSION_PREFIX: String = "contentConflict."

    /** The members this build understands: `contentConflict.v1.<fingerprint>`. */
    const val CONTENT_CONFLICT_V1_EXTENSION_PREFIX: String = "contentConflict.v1."

    /**
     * How a variant is mirrored into `VaultRecord.x`, so that it survives the loss of the
     * sync sidecars: the member `contentConflict.<suffix>` is stored under this prefix
     * plus `<suffix>`. See [opaqueCarrierKey] and [opaqueCarrierValue].
     */
    const val CONTENT_CONFLICT_OPAQUE_CARRIER_PREFIX: String = "contentConflictOpaque.v1."

    /** The provenance of a conflict copy, plain or materialised secure. */
    const val PLAIN_CONFLICT_COPY_EXTENSION_KEY: String = "conflictCopy.v1"

    const val MAXIMUM_CONTENT_CONFLICT_VARIANT_COUNT: Int = 128

    /**
     * The most bytes all `contentConflict.*` members of one envelope may take, keys plus
     * canonical values. It bounds parsing work and fan-out on its own; the whole envelope
     * is measured against [MAXIMUM_WIRE_CANONICAL_BYTES] as well.
     */
    const val MAXIMUM_CONTENT_CONFLICT_VARIANT_BYTES: Int = 512 * 1_024

    /**
     * The largest canonical envelope the shipping sealer encodes below CloudKit's
     * 900 000-byte field ceiling: padding rounds `P + 1` up to 256 bytes, AES-GCM adds
     * 16, base64url expands by 4/3 and the `v1.<nonce>.<body>` wrapper adds 20. 674 815
     * bytes seal to 899 796; one more byte enters the next padding block and seals to
     * 900 138.
     *
     * Every merge input and every merge output is measured against it
     * ([validateContentConflictExtensions]). An input over it, a survivor that grew over
     * it by gaining a variant, and a generated copy whose longer name pushed it over all
     * throw [MergeFailure.MalformedContentConflict]; nothing is truncated.
     */
    const val MAXIMUM_WIRE_CANONICAL_BYTES: Int = 674_815

    private const val COPY_ID_NAME_PREFIX = "sync-content-conflict-v1|"
    private const val CONFLICT_TAG = "conflict"

    private const val VAULT_CONTENT_HASH = SyncEnvelope.VAULT_CONTENT_HASH_EXTENSION_KEY
    private const val VAULT_KEY_ID = SyncEnvelope.VAULT_KEY_ID_EXTENSION_KEY
    private const val MAXIMUM_VAULT_EXTENSION_BYTES = 256

    private val VARIANT_KEYS: Set<String> =
        setOf("version", "copyID", "sourceID", "sourceHLC", "sourceOrigin", "secure", "fields", "x")
    private val PROVENANCE_KEYS: Set<String> = setOf("version", "sourceID", "fingerprint")

    /** One understood secure losing version, read back out of a survivor's `x` (`SecureContentConflictVariant`). */
    class SecureContentConflictVariant(
        /** `contentConflict.v1.<fingerprint>`. */
        val extensionKey: String,
        val fingerprint: String,
        /** Where the materialised copy will live. */
        val copyId: UUID,
        /** The record that lost; always the id of the envelope that carries the variant. */
        val sourceId: UUID,
        val sourceHlc: Hlc,
        val sourceOrigin: String,
        /** The losing version. Its body is the vault's sealed text, bound to [sourceId]. */
        val fields: SyncEnvelope.Fields,
        /** Exactly `vaultContentHash` and `vaultKID` of the losing version. */
        sourceExtensions: Map<String, JsonValue>,
    ) {
        val sourceExtensions: Map<String, JsonValue> = Collections.unmodifiableMap(LinkedHashMap(sourceExtensions))

        /** The keyed hash of the losing plaintext, as the vault wrote it. */
        val vaultContentHash: String?
            get() = SwiftSemantics.get(sourceExtensions, VAULT_CONTENT_HASH)?.textOrNull

        /** The `kid` of the vault that sealed the losing body. */
        val vaultKeyId: String?
            get() = SwiftSemantics.get(sourceExtensions, VAULT_KEY_ID)?.textOrNull

        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is SecureContentConflictVariant) return false
            return extensionKey == other.extensionKey &&
                fingerprint == other.fingerprint &&
                copyId == other.copyId &&
                sourceId == other.sourceId &&
                sourceHlc == other.sourceHlc &&
                FoundationText.canonicalEquals(sourceOrigin, other.sourceOrigin) &&
                fields == other.fields &&
                SwiftSemantics.dictionariesEqual(sourceExtensions, other.sourceExtensions)
        }

        override fun hashCode(): Int = extensionKey.hashCode()

        /** Names the variant only: nothing of the losing version's text. */
        override fun toString(): String = "SecureContentConflictVariant(copyId=$copyId, sourceId=$sourceId)"
    }

    /** What a conflict copy says about where it came from (`conflictCopy.v1`). */
    data class Provenance(val sourceId: UUID, val fingerprint: String)

    // Names

    private const val FIRST_GREGORIAN_MILLIS = -12_219_292_800_000.0   // 1582-10-15T00:00:00.000Z
    private const val LAST_FOUR_DIGIT_MILLIS = 253_402_300_799_999.0   // 9999-12-31T23:59:59.999Z

    /**
     * `yyyy-MM-dd HH:mm 'UTC'` for [updatedAt] (seconds since 2001), as Foundation's
     * `DateFormatter` writes it in `en_US_POSIX` and UTC: the time is first rounded to
     * the nearest millisecond, a half going up, and then cut to the minute. So `59.9994`
     * is `00:00` and `59.9996` is `00:01`. No locale, time zone or runtime date library
     * is consulted.
     *
     * @throws MergeFailure.UnrepresentableConflictDate outside 1582-10-15 00:00 to
     *   9999-12-31 23:59 UTC and for a value that is not a number.
     */
    @Throws(MergeFailure::class)
    fun conflictStamp(updatedAt: Double): String {
        val millis = Math.floor((updatedAt + AppleTime.UNIX_EPOCH_OFFSET_SECONDS) * 1000.0 + 0.5)
        // Written so that not-a-number fails the test.
        if (!(millis >= FIRST_GREGORIAN_MILLIS && millis <= LAST_FOUR_DIGIT_MILLIS)) {
            throw MergeFailure.UnrepresentableConflictDate()
        }
        val minutes = Math.floorDiv(millis.toLong(), 60_000L)
        val minuteOfDay = Math.floorMod(minutes, 1_440L).toInt()

        // Days since 1970-01-01 to a proleptic Gregorian date, in 400-year eras that
        // start on 1 March so the leap day is the last day of a year.
        val shifted = Math.floorDiv(minutes, 1_440L) + 719_468L
        val era = Math.floorDiv(shifted, 146_097L)
        val dayOfEra = shifted - era * 146_097L
        val yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        val shiftedMonth = (5 * dayOfYear + 2) / 153
        val day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        val month = if (shiftedMonth < 10) shiftedMonth + 3 else shiftedMonth - 9
        val year = yearOfEra + era * 400 + (if (month <= 2) 1 else 0)

        val out = StringBuilder(20)
        appendPadded(out, year, 4)
        out.append('-')
        appendPadded(out, month, 2)
        out.append('-')
        appendPadded(out, day, 2)
        out.append(' ')
        appendPadded(out, (minuteOfDay / 60).toLong(), 2)
        out.append(':')
        appendPadded(out, (minuteOfDay % 60).toLong(), 2)
        out.append(" UTC")
        return out.toString()
    }

    // ASCII digits whatever the device locale is.
    private fun appendPadded(out: StringBuilder, value: Long, width: Int) {
        val digits = value.toString()
        repeat(width - digits.length) { out.append('0') }
        out.append(digits)
    }

    /**
     * `"<displayName> (conflict <stamp>)"`: the name of a conflict copy, a synced field.
     *
     * The caller chooses [displayName], and the two kinds of copy choose differently: a
     * plain copy uses [com.khm.snippets.core.model.Snippet.displayName] (trimmed name,
     * else the first line of the body, else `Untitled Snippet`); a materialised secure
     * copy uses the name as stored, or `Untitled` when it is empty, and never looks at
     * the body.
     *
     * @throws MergeFailure.UnrepresentableConflictDate as [conflictStamp].
     */
    @Throws(MergeFailure::class)
    fun conflictName(displayName: String, updatedAt: Double): String =
        "$displayName (conflict ${conflictStamp(updatedAt)})"

    /**
     * The name of a materialised secure conflict copy (`conflictName(name:updatedAt:)` in
     * `SyncSecureConflictMaterializer.swift`): the stored [name] untouched, or `Untitled`
     * when it is empty. The body is never looked at; it is sealed.
     *
     * @throws MergeFailure.UnrepresentableConflictDate as [conflictStamp].
     */
    @Throws(MergeFailure::class)
    fun secureConflictName(name: String, updatedAt: Double): String =
        conflictName(if (name.isEmpty()) "Untitled" else name, updatedAt)

    // Identity

    /**
     * The id of the copy of the losing version with this [fingerprint]:
     * `deterministicUUID(namespace: sourceId, name: "sync-content-conflict-v1|" + fingerprint)`.
     * Every device computes the same id, so exactly one copy exists however many of them
     * preserve the same version.
     */
    fun copyId(sourceId: UUID, fingerprint: String): UUID =
        DeterministicUuid.make(sourceId, COPY_ID_NAME_PREFIX + fingerprint)

    /** `SyncMerge.deterministicUUID`, for callers that hold their own name recipe. */
    fun deterministicUuid(namespace: UUID, name: String): UUID = DeterministicUuid.make(namespace, name)

    /**
     * The order of `uuidString`. Conflict copies, variants' copy ids and every other id
     * list the merge returns are sorted by it, never by `UUID.compareTo`.
     */
    val idOrder: Comparator<UUID> = Comparator(SnippetDisplayOrder::compareUuidStrings)

    /**
     * The fingerprint of [source] as a losing version: lowercase hex SHA-256 of its
     * canonical snapshot. It covers the eight fields, the clock, the origin, the id, the
     * `secure` flag and the two vault members of `x`; nothing else of `x`, so an earlier
     * variant never becomes part of a later one.
     *
     * @throws MergeFailure.MalformedContentConflict for a tombstone.
     */
    @Throws(MergeFailure::class, CanonicalJson.Failure::class)
    fun contentConflictFingerprint(source: SyncEnvelope): String = fingerprint(snapshot(source))

    private fun fingerprint(snapshot: Map<String, JsonValue>): String =
        SyncEnvelope.sha256Hex(CanonicalJson.encode(JsonValue.Object(snapshot)))

    /** The canonical snapshot the fingerprint is taken over (`contentConflictSnapshot`). Internal: for the vectors. */
    @Throws(MergeFailure::class)
    internal fun contentConflictSnapshot(source: SyncEnvelope): Map<String, JsonValue> = snapshot(source)

    private fun snapshot(source: SyncEnvelope): LinkedHashMap<String, JsonValue> {
        val fields = source.fields
        if (fields == null || source.deleted) throw MergeFailure.MalformedContentConflict()
        // `VaultRecord.x` is plaintext primary storage and a secure snapshot is mirrored
        // there, so copying an arbitrary future member of `x` would widen that plaintext
        // boundary. These two are all that is needed to authenticate and file the body.
        val approved = LinkedHashMap<String, JsonValue>()
        for ((key, value) in source.x) if (isVaultExtension(key)) approved[key] = value
        val snapshot = LinkedHashMap<String, JsonValue>()
        snapshot["version"] = JsonValue.Integer(1)
        snapshot["sourceID"] = JsonValue.Text(Uuids.lowercase(source.id))
        snapshot["sourceHLC"] = JsonValue.Text(source.hlc.string)
        snapshot["sourceOrigin"] = JsonValue.Text(source.origin)
        snapshot["secure"] = JsonValue.Bool(source.secure)
        snapshot["fields"] = fields.canonicalValue
        snapshot["x"] = JsonValue.Object(approved)
        return snapshot
    }

    // Swift compares these keys with `==`, which is canonical equivalence.
    private fun isVaultExtension(key: String): Boolean =
        FoundationText.canonicalEquals(key, VAULT_CONTENT_HASH) || FoundationText.canonicalEquals(key, VAULT_KEY_ID)

    // Making a copy or a variant

    /**
     * The conflict copy of one exact losing ordinary envelope (`makePlainContentConflictCopy`).
     * A function of [source] alone: Apple, Linux and Android derive the same bytes from
     * the same published version.
     *
     * - `id` = [copyId]; `hlc` and `origin` are the source's; `secure` is false.
     * - Fields are the source's, except `name` = [conflictName] of its display name,
     *   `keyword` empty, disabled, unpinned, and `conflict` appended to the tags.
     * - `x` = the source's without `contentConflict.*`, `vaultContentHash` and
     *   `vaultKID`, plus the provenance.
     *
     * @throws MergeFailure.MalformedContentConflict when [source] is a tombstone, secure,
     *   or its body is not UTF-8.
     * @throws MergeFailure.UnrepresentableConflictDate see there. Not in Swift.
     */
    @Throws(MergeFailure::class, CanonicalJson.Failure::class)
    fun makePlainContentConflictCopy(source: SyncEnvelope): SyncEnvelope {
        val snippet = source.plainSnippet ?: throw MergeFailure.MalformedContentConflict()
        val fingerprint = contentConflictFingerprint(source)
        val copy = snippet.copy(
            id = copyId(source.id, fingerprint),
            name = conflictName(snippet.displayName, snippet.updatedAt),
            // Two live snippets may never share a keyword, and the copy must never be
            // reachable by typing.
            keyword = "",
            isEnabled = false,
            isPinned = false,
            tags = SnippetTagging.normalizedTags(snippet.tags + CONFLICT_TAG),
        )
        val extensions = LinkedHashMap<String, JsonValue>()
        for ((key, value) in source.x) {
            if (!isContentConflictExtension(key) && !isVaultExtension(key)) extensions[key] = value
        }
        SwiftSemantics.set(extensions, PLAIN_CONFLICT_COPY_EXTENSION_KEY, conflictCopyProvenance(source.id, fingerprint))
        return SyncEnvelope.plain(copy, hlc = source.hlc, origin = source.origin, x = extensions)
    }

    /**
     * The member that preserves one exact losing secure envelope inside the survivor's
     * `x`: key `contentConflict.v1.<fingerprint>`, value the snapshot plus `copyID`
     * (`makeSecureContentConflictVariant`). The fingerprint is computed before `copyID`
     * is added.
     *
     * A source without `vaultContentHash` or `vaultKID` yields a member that
     * [secureContentConflictVariants] refuses, so a merge that needs it throws: a legacy
     * unstamped secure body cannot be preserved as a variant.
     *
     * @throws MergeFailure.MalformedContentConflict when [source] is not secure or is a tombstone.
     */
    @Throws(MergeFailure::class, CanonicalJson.Failure::class)
    fun makeSecureContentConflictVariant(source: SyncEnvelope): Pair<String, JsonValue> {
        if (!source.secure) throw MergeFailure.MalformedContentConflict()
        val snapshot = snapshot(source)
        val fingerprint = fingerprint(snapshot)
        snapshot["copyID"] = JsonValue.Text(Uuids.lowercase(copyId(source.id, fingerprint)))
        return Pair(CONTENT_CONFLICT_V1_EXTENSION_PREFIX + fingerprint, JsonValue.Object(snapshot))
    }

    // Reading the reserved members

    /** Whether [key] names an unresolved losing version of any format version (`String.hasPrefix`, so by `Character`). */
    fun isContentConflictExtension(key: String): Boolean =
        SwiftStrings.hasPrefix(key, CONTENT_CONFLICT_EXTENSION_PREFIX)

    /** Whether [key] names a version 1 variant. */
    fun isContentConflictV1Extension(key: String): Boolean =
        SwiftStrings.hasPrefix(key, CONTENT_CONFLICT_V1_EXTENSION_PREFIX)

    /** Whether [envelope] still carries a losing body nobody has filed. `false` for `null`. */
    fun hasUnresolvedContentConflict(envelope: SyncEnvelope?): Boolean =
        envelope != null && envelope.x.keys.any(::isContentConflictExtension)

    /**
     * Whether [envelope] carries a member written by a newer format. Such members stay
     * opaque: preserved, counted against the limits, and they keep the record unresolved
     * and undeletable until a build that understands them files them.
     */
    fun hasUnknownContentConflictVersion(envelope: SyncEnvelope): Boolean =
        envelope.x.keys.any { isContentConflictExtension(it) && !isContentConflictV1Extension(it) }

    /**
     * The understood variants of [envelope], sorted by key (`secureContentConflictVariants`).
     * Members of other versions are skipped.
     *
     * A version 1 member must be an object with exactly `version` (integer 1), `copyID`,
     * `sourceID`, `sourceHLC`, `sourceOrigin`, `secure` (true), `fields` and `x`; both ids
     * in canonical lowercase; `sourceID` this envelope's id; a clock that parses; a
     * canonical device id; fields that parse; an inner `x` of exactly `vaultContentHash`
     * and `vaultKID`, both text of at most 256 UTF-8 bytes; and its key's fingerprint and
     * its `copyID` must be the ones recomputed from the rest.
     *
     * @throws MergeFailure.MalformedContentConflict for anything else, and for a
     *   tombstone that carries any `contentConflict.*` member.
     */
    @Throws(MergeFailure::class, CanonicalJson.Failure::class)
    fun secureContentConflictVariants(envelope: SyncEnvelope): List<SecureContentConflictVariant> {
        if (envelope.deleted && hasUnresolvedContentConflict(envelope)) throw MergeFailure.MalformedContentConflict()
        val variants = ArrayList<SecureContentConflictVariant>()
        for ((key, raw) in envelope.x) {
            if (!isContentConflictExtension(key) || !isContentConflictV1Extension(key)) continue
            variants.add(parseVariant(envelope, key, raw) ?: throw MergeFailure.MalformedContentConflict())
        }
        variants.sortWith { first, second -> FoundationText.compare(first.extensionKey, second.extensionKey) }
        return variants
    }

    private fun parseVariant(envelope: SyncEnvelope, key: String, raw: JsonValue): SecureContentConflictVariant? {
        val fingerprint = key.substring(CONTENT_CONFLICT_V1_EXTENSION_PREFIX.length)
        if (!isLowercaseSha256(fingerprint)) return null
        val members = raw.objectOrNull ?: return null
        if (members.keys != VARIANT_KEYS) return null
        if (members.getValue("version").longOrNull != 1L) return null
        if (members.getValue("secure").boolOrNull != true) return null
        val copyId = members.getValue("copyID").textOrNull?.let(Uuids::parseLowercase) ?: return null
        val sourceId = members.getValue("sourceID").textOrNull?.let(Uuids::parseLowercase) ?: return null
        if (sourceId != envelope.id) return null
        val sourceHlc = members.getValue("sourceHLC").textOrNull?.let(Hlc::parse) ?: return null
        val sourceOrigin = members.getValue("sourceOrigin").textOrNull ?: return null
        if (!Hlc.isCanonicalDeviceId(sourceOrigin)) return null
        val fields = try {
            SyncEnvelope.Fields.parse(members.getValue("fields"))
        } catch (_: SyncEnvelope.Failure) {
            return null
        }
        val sourceExtensions = members.getValue("x").objectOrNull ?: return null
        if (sourceExtensions.size != 2) return null
        for (name in arrayOf(VAULT_CONTENT_HASH, VAULT_KEY_ID)) {
            // `x[name]?.text?.utf8.count`: the bytes of the text as `.text` reads it,
            // which is not always the stored bytes (see `JsonValue.textOrNull`).
            val text = SwiftSemantics.get(sourceExtensions, name)?.textOrNull ?: return null
            if (Utf8.encode(text).size > MAXIMUM_VAULT_EXTENSION_BYTES) return null
        }

        val snapshot = LinkedHashMap(members)
        snapshot.remove("copyID")
        if (fingerprint(snapshot) != fingerprint) return null
        if (copyId != copyId(sourceId, fingerprint)) return null

        return SecureContentConflictVariant(
            extensionKey = key, fingerprint = fingerprint, copyId = copyId, sourceId = sourceId,
            sourceHlc = sourceHlc, sourceOrigin = sourceOrigin, fields = fields, sourceExtensions = sourceExtensions,
        )
    }

    /**
     * Checks an envelope before the merge reads it and before the merge returns it
     * (`validateContentConflictExtensions`):
     *
     * - its canonical bytes are at most [MAXIMUM_WIRE_CANONICAL_BYTES];
     * - a tombstone carries no `contentConflict.*` member;
     * - there are at most [MAXIMUM_CONTENT_CONFLICT_VARIANT_COUNT] such members, and
     *   their keys and canonical values take at most [MAXIMUM_CONTENT_CONFLICT_VARIANT_BYTES];
     * - every such key is `contentConflict.v<1 to 3 digits>.<64 lowercase hex>`, so a
     *   typo cannot become an immortal member while a future version stays acceptable;
     * - every version 1 member passes [secureContentConflictVariants].
     *
     * @throws MergeFailure.MalformedContentConflict when a check fails.
     * @throws CanonicalJson.Failure when the envelope cannot be written at all.
     */
    @Throws(MergeFailure::class, CanonicalJson.Failure::class)
    fun validateContentConflictExtensions(envelope: SyncEnvelope) {
        val canonical = envelope.canonicalBytes()
        val size = canonical.size
        canonical.fill(0)
        if (size > MAXIMUM_WIRE_CANONICAL_BYTES) throw MergeFailure.MalformedContentConflict()
        if (envelope.deleted && hasUnresolvedContentConflict(envelope)) throw MergeFailure.MalformedContentConflict()

        if (envelope.x.keys.count(::isContentConflictExtension) > MAXIMUM_CONTENT_CONFLICT_VARIANT_COUNT) {
            throw MergeFailure.MalformedContentConflict()
        }
        var aggregateBytes = 0
        for ((key, value) in envelope.x) {
            if (!isContentConflictExtension(key)) continue
            if (!hasVariantKeyGrammar(key)) throw MergeFailure.MalformedContentConflict()
            val keyBytes = key.length   // ASCII, by the grammar
            val valueBytes = CanonicalJson.encode(value).size
            if (keyBytes > MAXIMUM_CONTENT_CONFLICT_VARIANT_BYTES - aggregateBytes ||
                valueBytes > MAXIMUM_CONTENT_CONFLICT_VARIANT_BYTES - aggregateBytes - keyBytes
            ) {
                throw MergeFailure.MalformedContentConflict()
            }
            aggregateBytes += keyBytes + valueBytes
        }
        secureContentConflictVariants(envelope)
    }

    // `contentConflict` `.` `v` 1…3 ASCII digits `.` 64 lowercase hex digits.
    private fun hasVariantKeyGrammar(key: String): Boolean {
        var index = CONTENT_CONFLICT_EXTENSION_PREFIX.length
        if (!key.startsWith(CONTENT_CONFLICT_EXTENSION_PREFIX)) return false
        if (index >= key.length || key[index] != 'v') return false
        index += 1
        val digitsStart = index
        while (index < key.length && key[index] in '0'..'9') index += 1
        if (index - digitsStart !in 1..3) return false
        if (index >= key.length || key[index] != '.') return false
        return isLowercaseSha256(key.substring(index + 1))
    }

    private fun isLowercaseSha256(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    // Provenance

    /** The value of `x["conflictCopy.v1"]`: `{"fingerprint", "sourceID", "version": 1}`. */
    fun conflictCopyProvenance(sourceId: UUID, fingerprint: String): JsonValue = JsonValue.obj(
        "version" to JsonValue.Integer(1),
        "sourceID" to JsonValue.Text(Uuids.lowercase(sourceId)),
        "fingerprint" to JsonValue.Text(fingerprint),
    )

    /**
     * The provenance [envelope] carries, read strictly: exactly the three keys, `version`
     * an integer 1, a canonical lowercase id, a 64-digit lowercase hex fingerprint.
     * `null` for anything else, including a future shape: a value that cannot be read can
     * never prove that a deterministic copy is durable.
     */
    fun conflictCopyProvenance(envelope: SyncEnvelope): Provenance? {
        val members = SwiftSemantics.get(envelope.x, PLAIN_CONFLICT_COPY_EXTENSION_KEY)?.objectOrNull ?: return null
        if (members.keys != PROVENANCE_KEYS) return null
        if (members.getValue("version").longOrNull != 1L) return null
        val sourceId = members.getValue("sourceID").textOrNull?.let(Uuids::parseLowercase) ?: return null
        val fingerprint = members.getValue("fingerprint").textOrNull ?: return null
        if (!isLowercaseSha256(fingerprint)) return null
        return Provenance(sourceId, fingerprint)
    }

    /** Whether [envelope] carries exactly the provenance of this source and fingerprint. */
    fun matchesConflictCopyProvenance(envelope: SyncEnvelope, sourceId: UUID, fingerprint: String): Boolean =
        SwiftSemantics.optionalValuesEqual(
            SwiftSemantics.get(envelope.x, PLAIN_CONFLICT_COPY_EXTENSION_KEY),
            conflictCopyProvenance(sourceId, fingerprint),
        )

    /**
     * Whether [envelope] is a conflict copy by identity: its provenance reads, and its id
     * is the one that provenance derives. The id check is what stops an arbitrary record
     * from acquiring conflict-copy semantics by copying that small object. A tombstone
     * that kept the provenance still has the identity. Secure body bytes are
     * authenticated elsewhere.
     */
    fun hasValidConflictCopyIdentity(envelope: SyncEnvelope): Boolean {
        val provenance = conflictCopyProvenance(envelope) ?: return false
        return envelope.id == copyId(provenance.sourceId, provenance.fingerprint)
    }

    /**
     * Whether [envelope] is the same copy as the generated [candidate]: same id and the
     * same `conflictCopy.v1` value. Fields may differ, so a copy the user renamed or
     * edited still matches. The id of a generated copy is reserved: a live record there
     * that does not match stops sync before anything is applied.
     */
    fun isMatchingPlainConflictCopy(envelope: SyncEnvelope, candidate: SyncEnvelope): Boolean {
        if (envelope.id != candidate.id) return false
        val expected = SwiftSemantics.get(candidate.x, PLAIN_CONFLICT_COPY_EXTENSION_KEY) ?: return false
        val actual = SwiftSemantics.get(envelope.x, PLAIN_CONFLICT_COPY_EXTENSION_KEY) ?: return false
        return SwiftSemantics.valuesEqual(actual, expected)
    }

    /**
     * [envelope] without the given version 1 members, or `null` when it is a tombstone,
     * when a key of [expected] is not a version 1 key, or when a member no longer holds
     * exactly the expected value. The journal calls this once the copies are confirmed;
     * members of unknown versions stay and keep the record unresolved.
     */
    fun resolvingContentConflicts(envelope: SyncEnvelope, expected: Map<String, JsonValue>): SyncEnvelope? {
        if (envelope.deleted) return null
        for ((key, value) in expected) {
            if (!isContentConflictV1Extension(key)) return null
            val current = SwiftSemantics.get(envelope.x, key) ?: return null
            if (!SwiftSemantics.valuesEqual(current, value)) return null
        }
        val remaining = LinkedHashMap(envelope.x)
        for (key in expected.keys) SwiftSemantics.set(remaining, key, null)
        return envelope.copy(x = remaining)
    }

    // The vault carrier of a variant

    /**
     * The key under which the member [extensionKey] of an envelope's `x` is mirrored into
     * `VaultRecord.x`: `contentConflictOpaque.v1.` plus the key without its
     * `contentConflict.` prefix, so `contentConflictOpaque.v1.v1.<fingerprint>`.
     */
    fun opaqueCarrierKey(extensionKey: String): String {
        require(isContentConflictExtension(extensionKey)) { "not a contentConflict member" }
        return CONTENT_CONFLICT_OPAQUE_CARRIER_PREFIX + extensionKey.substring(CONTENT_CONFLICT_EXTENSION_PREFIX.length)
    }

    /**
     * The carrier's value: a JSON string holding the padded standard base64 of the
     * member's canonical bytes. Swift reads it back with `Data(base64Encoded:)` and the
     * canonical parser.
     */
    @Throws(CanonicalJson.Failure::class)
    fun opaqueCarrierValue(value: JsonValue): JsonValue = JsonValue.Text(Base64Std.encode(CanonicalJson.encode(value)))

    // A deleted copy's identity

    /**
     * What is remembered of a plain conflict copy that left primary storage: a body-free
     * tombstone with the same id, clock and origin whose `x` is only the provenance
     * (`retainedCopyIdentity` in `SyncLibraryProjection.swift`). `null` unless
     * [envelope] is not secure and has a valid copy identity; a tombstone is carried
     * forward only if it already has exactly this shape.
     *
     * An ordinary tombstone carries no `x`, so without this memory a restored copy would
     * come back on its reserved id without provenance and halt every peer. The memory
     * never leaves the device.
     */
    fun retainedCopyIdentity(envelope: SyncEnvelope): SyncEnvelope? {
        if (envelope.secure || !hasValidConflictCopyIdentity(envelope)) return null
        val provenance = SwiftSemantics.get(envelope.x, PLAIN_CONFLICT_COPY_EXTENSION_KEY) ?: return null
        val identity = SyncEnvelope.tombstone(
            id = envelope.id, secure = false, hlc = envelope.hlc, origin = envelope.origin,
            x = mapOf(PLAIN_CONFLICT_COPY_EXTENSION_KEY to provenance),
        )
        if (envelope.deleted && !SwiftSemantics.envelopesEqual(envelope, identity)) return null
        return identity
    }
}
