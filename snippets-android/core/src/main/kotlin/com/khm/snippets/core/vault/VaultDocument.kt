package com.khm.snippets.core.vault

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.text.FoundationText
import java.util.UUID

/**
 * `Vault/vault.json`: the secure snippets as they are on disk (`VaultDocument` in
 * `VaultDocument.swift`).
 *
 * Secure snippets live here and never in `snippets.json`. Their metadata (name, keyword,
 * tags, flags, timestamps, clock) is plaintext on purpose, so the list, search and
 * keyword checks work with the vault locked; only [VaultRecord.sealed] is ciphertext.
 * This type is the format, not the cryptography: [VaultRecord.sealed], the wraps and
 * [VaultRecord.contentHash] are opaque strings here.
 *
 * Every object of the format carries an [x] bag with the keys this build does not know,
 * and writes them back. A stripped copy would be the copy that syncs next.
 *
 * Values are immutable. Equality is Swift's: text by canonical equivalence, timestamps as
 * IEEE doubles. It decides whether the file is rewritten and whether observers are told.
 */
data class VaultDocument(
    /** Raised only for a change an older build cannot write back safely. Additive fields go into [x]. */
    val schemaVersion: Long = CURRENT_SCHEMA_VERSION,
    /** Names the library key every sealed body is under. Opaque. */
    val kid: String,
    /** base64url, unpadded. Separates every key derived from the library key. See [vaultSaltBytes]. */
    val vaultSalt: String,
    /** Parameters of the optional passphrase wrap; present even without one. */
    val kdf: VaultKdfParameters,
    /** The library key under a passphrase. No shipping path writes one; preserved and written as `null`. */
    val wrapPass: String? = null,
    /** The library key under the printable recovery key (`KeyWrap`, purpose `recovery`). */
    val wrapRecovery: String? = null,
    /** Reserved. Preserved, never written by this app, and encoded as an explicit `null`. */
    val wrapCLI: String? = null,
    /** Unknown document-level keys, kept verbatim. */
    val x: Map<String, JsonValue> = emptyMap(),
    /** In the user's order; nothing sorts it. */
    val records: List<VaultRecord> = emptyList(),
) {

    fun record(id: UUID): VaultRecord? = records.firstOrNull { it.id == id }

    /** Every record as a content-free [Snippet], in file order. */
    val shells: List<Snippet> get() = records.map { it.shell }

    /**
     * [vaultSalt] as bytes, or `null` when the field is not base64url: the document is
     * corrupt then. Never substitute an empty salt for `null`; keys derived under it
     * would produce a file no correct build can read.
     */
    val vaultSaltBytes: ByteArray? get() = Base64Url.decode(vaultSalt)

    /** The passphrase wrap in the shape [PassphraseKdf] reads, or `null` without one (the default). */
    val passphraseWrap: PassphraseKdf.WrappedKey?
        get() = wrapPass?.let { PassphraseKdf.WrappedKey(kdf.alg, kdf.iterations, kdf.saltP, it) }

    /**
     * This device's receipts for secure conflict prerequisites that reached primary
     * storage: deterministic copy id to the SHA-256 envelope hash of its snapshot.
     * `null` when the stored value is malformed or a newer version of it exists; a
     * caller must not treat that as empty. Device-local: never exported, never shared.
     */
    val localConflictInstallReceipts: Map<UUID, String>?
        get() {
            val reserved = x.keys.filter { it.startsWith(LOCAL_CONFLICT_INSTALL_RECEIPTS_PREFIX) }
            if (reserved.isNotEmpty() && reserved != listOf(LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY)) return null
            val value = x[LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY] ?: return emptyMap()
            val members = value.objectOrNull ?: return null
            val receipts = LinkedHashMap<UUID, String>()
            for ((hash, marker) in members) {
                val rawId = (marker as? JsonValue.Text)?.value ?: (marker as? JsonValue.Utf8)?.textOrNull ?: return null
                if (!isLowercaseSha256(hash)) return null
                val id = Uuids.parseLowercase(rawId) ?: return null
                if (receipts.put(id, hash) != null) return null
            }
            return receipts
        }

    /** Adds or replaces receipts. Throws [MalformedConflictReceipts] rather than overwrite a value it cannot read. */
    @Throws(MalformedConflictReceipts::class)
    fun recordingLocalConflictInstallReceiptHashes(additions: Map<UUID, String>): VaultDocument {
        val receipts = LinkedHashMap(localConflictInstallReceipts ?: throw MalformedConflictReceipts())
        for ((id, hash) in additions) {
            if (!isLowercaseSha256(hash)) throw MalformedConflictReceipts()
            receipts[id] = hash
        }
        return copy(x = x + (LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY to receiptsValue(receipts)))
    }

    /** Drops every version of the receipts. Used for anything that leaves this device or this vault. */
    fun removingLocalConflictInstallReceipts(): VaultDocument {
        if (x.keys.none { it.startsWith(LOCAL_CONFLICT_INSTALL_RECEIPTS_PREFIX) }) return this
        return copy(x = x.filterKeys { !it.startsWith(LOCAL_CONFLICT_INSTALL_RECEIPTS_PREFIX) })
    }

    @Throws(MalformedConflictReceipts::class)
    fun retainingLocalConflictInstallReceipts(ids: Set<UUID>): VaultDocument {
        val receipts = localConflictInstallReceipts ?: throw MalformedConflictReceipts()
        val retained = receipts.filterKeys { it in ids }
        if (retained.isEmpty()) return removingLocalConflictInstallReceipts()
        return copy(x = x + (LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY to receiptsValue(retained)))
    }

    private fun receiptsValue(receipts: Map<UUID, String>): JsonValue =
        JsonValue.Object(receipts.entries.associate { (id, hash) -> hash to JsonValue.Text(Uuids.lowercase(id)) })

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is VaultDocument) return false
        return schemaVersion == other.schemaVersion &&
            sameText(kid, other.kid) &&
            sameText(vaultSalt, other.vaultSalt) &&
            kdf == other.kdf &&
            sameText(wrapPass, other.wrapPass) &&
            sameText(wrapRecovery, other.wrapRecovery) &&
            sameText(wrapCLI, other.wrapCLI) &&
            x == other.x &&
            records == other.records
    }

    override fun hashCode(): Int = 31 * schemaVersion.hashCode() + records.size

    /** Names nothing a log should not hold: no record names, no key id. */
    override fun toString(): String = "VaultDocument(schemaVersion=$schemaVersion, records=${records.size})"

    /** The stored receipts are malformed, or written by a newer build. */
    class MalformedConflictReceipts : Exception("the local conflict receipts cannot be read")

    companion object {
        const val CURRENT_SCHEMA_VERSION: Long = 1

        const val LOCAL_CONFLICT_INSTALL_RECEIPTS_PREFIX = "local.syncConflictC0Receipts."
        const val LOCAL_CONFLICT_INSTALL_RECEIPTS_KEY = LOCAL_CONFLICT_INSTALL_RECEIPTS_PREFIX + "v1"

        private fun isLowercaseSha256(value: String): Boolean =
            value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }
    }
}

/**
 * How a passphrase is stretched (`VaultKDFParameters`). Stored in the file so raising
 * the count for new vaults does not lock existing ones out.
 *
 * There are no `alg` or `iterations` constants here on purpose: [PassphraseKdf] is the
 * single source of truth. Build these from a wrap with [of], or from
 * [PassphraseKdf.ALGORITHM] and [PassphraseKdf.ITERATIONS].
 */
data class VaultKdfParameters(
    val alg: String,
    /** A `Long` because Swift decodes a 64-bit `Int`; the KDF refuses a count out of range. */
    val iterations: Long,
    /** base64url, unpadded. */
    val saltP: String,
    /** Unknown KDF keys, kept verbatim. */
    val x: Map<String, JsonValue> = emptyMap(),
) {

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is VaultKdfParameters) return false
        return sameText(alg, other.alg) && iterations == other.iterations && sameText(saltP, other.saltP) && x == other.x
    }

    override fun hashCode(): Int = iterations.hashCode()

    companion object {
        /** The parameters that produced a wrap, copied from the wrap so they cannot disagree with it. */
        fun of(wrapped: PassphraseKdf.WrappedKey, x: Map<String, JsonValue> = emptyMap()): VaultKdfParameters =
            VaultKdfParameters(wrapped.alg, wrapped.iterations, wrapped.salt, x)
    }
}

/** One secure snippet: plaintext metadata, opaque ciphertext (`VaultRecord`). */
data class VaultRecord(
    val id: UUID,
    val name: String,
    val keyword: String,
    /** As given; normalized where a file is read, exactly like [Snippet]. */
    val tags: List<String> = emptyList(),
    val isEnabled: Boolean = true,
    val isPinned: Boolean = false,
    /** Seconds since 2001, as the model stores every timestamp. */
    val createdAt: Double,
    val updatedAt: Double,
    /** Merge order. A record that arrives without one gets [Hlc.foreign] of [updatedAt]. */
    val hlc: Hlc,
    /**
     * `hex(HMAC-SHA256(K_hash, plaintext)[0..<16])`, or empty when unknown. Keyed,
     * because it sits beside the ciphertext in the clear. Never the envelope's SHA-256 of
     * the ciphertext text; the two must not be compared or copied into each other.
     */
    val contentHash: String,
    /** The AEAD envelope text. Its grammar belongs to `SnippetCrypto`. */
    val sealed: String,
    /** Unknown record keys, kept verbatim (`conflictCopy.v1`, `contentConflictOpaque.v1.<fingerprint>`, anything newer). */
    val x: Map<String, JsonValue> = emptyMap(),
) {

    /**
     * The record as an ordinary [Snippet] with empty content: how the list, search and
     * keyword checks see secure snippets with the vault locked. Empty rather than a
     * placeholder, because an empty expansion is inert everywhere a shell might end up.
     */
    val shell: Snippet
        get() = Snippet(id, name, keyword, "", tags, isEnabled, isPinned, createdAt, updatedAt)

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is VaultRecord) return false
        return id == other.id &&
            isEnabled == other.isEnabled &&
            isPinned == other.isPinned &&
            sameInstant(createdAt, other.createdAt) &&
            sameInstant(updatedAt, other.updatedAt) &&
            hlc == other.hlc &&
            sameText(name, other.name) &&
            sameText(keyword, other.keyword) &&
            tags.size == other.tags.size &&
            tags.indices.all { sameText(tags[it], other.tags[it]) } &&
            sameText(contentHash, other.contentHash) &&
            sameText(sealed, other.sealed) &&
            x == other.x
    }

    override fun hashCode(): Int = id.hashCode()

    /** Names the record only. */
    override fun toString(): String = "VaultRecord(id=$id)"
}

/**
 * What a listing needs and nothing else (`VaultMetadata`): read without looking at `kdf`
 * or the wraps, and at any schema version.
 */
data class VaultMetadata(
    val schemaVersion: Long,
    /** One content-free [Snippet] per record, in file order. */
    val shells: List<Snippet>,
) {
    val isNewerThanThisBuild: Boolean get() = schemaVersion > VaultDocument.CURRENT_SCHEMA_VERSION
}

private fun sameText(first: String?, second: String?): Boolean =
    if (first == null || second == null) first == second else FoundationText.canonicalEquals(first, second)

// Swift's `Date ==` is the doubles' `==`; NaN is made equal to itself because `equals` must be reflexive.
private fun sameInstant(first: Double, second: Double): Boolean =
    first == second || (first.isNaN() && second.isNaN())
