package com.khm.snippets.core.backup

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.DomainSeparated
import com.khm.snippets.core.crypto.Hkdf
import com.khm.snippets.core.crypto.NonceSource
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.Pbkdf2HmacSha512
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.FoundationJsonWriter
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.vault.JsonDecodeException
import com.khm.snippets.core.vault.JsonNode
import com.khm.snippets.core.vault.LenientJson
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultDocumentCodec
import com.khm.snippets.core.vault.VaultEncodeException
import com.khm.snippets.core.vault.VaultTimestamp
import java.util.UUID

/**
 * A portable, password-protected snapshot of both halves of the library
 * (`EncryptedSnippetBackup.swift`): a `.snippetsbackup` file.
 *
 * Secure bodies are never opened while exporting. `vault.json` is copied as ciphertext
 * and the vault key is wrapped under a random per-backup key. The whole payload is then
 * sealed as one message, which also hides the secure metadata that is plaintext in the
 * live vault.
 *
 * ```
 * exportKey       = 32 random bytes
 * wrappedKey      = PassphraseKdf.wrap(exportKey, passphrase, salt16, kid = backupID)
 * payloadAAD      = domainSeparated("snip.backup.payload.v1", [format, u64be(schemaVersion), backupID,
 *                     alg, u64be(iterations), salt TEXT, envelope TEXT])
 * payload         = SnippetCrypto.seal(payloadJSON, exportKey, payloadAAD)
 * vaultWrapKey    = HKDF(exportKey, salt = vaultSalt, info = "snip.backup.vault-key.v1|" ‖ backupID ‖ 0x00 ‖ kid)
 * wrappedVaultKey = SnippetCrypto.seal(K_lib, vaultWrapKey,
 *                     domainSeparated("snip.backup.vault-key-aad.v1", ["v1", backupID, kid]))
 * ```
 *
 * The payload is `{ schemaVersion, snippets, vault?, wrappedVaultKey? }`. This writer
 * follows Swift: dates are numbers (seconds since 2001), ids uppercase, and `vault` and
 * `wrappedVaultKey` are absent, not `null`, without a vault. Its bytes equal Swift's for
 * the same input (vector V15). The reader also accepts ISO-8601 strings for dates and an
 * explicit `null` for the two optional keys, which is what the Linux app writes.
 *
 * 600 000 PBKDF2 rounds take a noticeable time: call [seal] and [open] off the main thread.
 */
object EncryptedBackup {

    const val FORMAT_IDENTIFIER = "com.khm.snippets.encrypted-backup"
    const val CURRENT_SCHEMA_VERSION: Long = 1
    const val PREFERRED_FILENAME_EXTENSION = "snippetsbackup"

    /** Larger files are refused before anything is parsed (the iOS and Linux import limit). */
    const val MAXIMUM_FILE_BYTES: Int = 32 * 1024 * 1024

    /** The plain JSON import limit of the iOS app, kept next to its sibling. */
    const val MAXIMUM_JSON_IMPORT_BYTES: Int = 16 * 1024 * 1024

    /** The export UI asks for at least this many characters; the format itself only needs a non-empty password. */
    const val MINIMUM_EXPORT_PASSWORD_CHARACTERS: Int = 12

    /** Limits of the Linux reader. Swift has none; a backup written here stays inside them so Linux can open it. */
    const val MAXIMUM_PASSPHRASE_BYTES: Int = 4096
    const val MAXIMUM_RECORDS: Int = 100_000

    private const val PAYLOAD_AAD_DOMAIN = "snip.backup.payload.v1"
    private const val VAULT_KEY_INFO_PREFIX = "snip.backup.vault-key.v1|"
    private const val VAULT_KEY_AAD_DOMAIN = "snip.backup.vault-key-aad.v1"

    private const val UNTITLED = "Untitled Snippet"

    /**
     * Why a backup could not be made or opened (`EncryptedSnippetBackup.Failure`). A wrong
     * password is distinct from every structural problem: a truncated or edited file is
     * never reported as a wrong password. Messages name no snippet.
     */
    sealed class Failure(message: String) : Exception(message) {
        class EmptyPassphrase : Failure("a password is required")

        /** Not a Snippets encrypted backup, or its key record is unusable (unknown algorithm, bad salt, rounds out of range). */
        class InvalidFormat : Failure("this is not a Snippets encrypted backup")
        class UnsupportedSchemaVersion(val version: Long) : Failure("backup format version $version is not supported")

        /** The password does not unlock the backup. Also what a changed `backupID` produces: it is authenticated with the key. */
        class WrongPassphrase : Failure("that password does not unlock this backup")

        /** Authenticated layers did not verify or did not decode. Nothing is returned. */
        class DamagedBackup : Failure("the backup is damaged or has been modified")

        /** The library inside is not valid. [reason] says how; the other fields are for the UI and never in the message. */
        class InvalidPayload(
            val reason: Reason,
            val id: UUID? = null,
            val keyword: String? = null,
            val firstName: String? = null,
            val secondName: String? = null,
        ) : Failure("the backup contains an invalid snippet library: $reason") {
            enum class Reason {
                EMPTY_BACKUP_ID,
                DUPLICATE_ID,
                DUPLICATE_KEYWORD,
                VAULT_TOO_NEW,
                EMPTY_VAULT,
                VAULT_KEY_WRONG_SIZE,
                VAULT_SALT_INVALID,
                VAULT_KEY_WITHOUT_VAULT,
                VAULT_KEY_MISSING,
                WRAPPED_VAULT_KEY_WITHOUT_VAULT,
                WRAPPED_VAULT_KEY_MISSING,

                /** Not in Swift: [MAXIMUM_RECORDS] or [MAXIMUM_PASSPHRASE_BYTES] exceeded while sealing. */
                TOO_MANY_RECORDS,
                PASSPHRASE_TOO_LONG,

                /** A timestamp or a passthrough number is not finite, so the payload has no JSON spelling. Swift's encoder throws here too. */
                NOT_ENCODABLE,
            }
        }

        /** Not in Swift's core: the file exceeds [MAXIMUM_FILE_BYTES]. */
        class FileTooLarge : Failure("the encrypted backup exceeds the size limit")
    }

    /**
     * An authenticated, validated backup. [vaultKey] is the vault's library key when the
     * backup holds a vault; [close] wipes it.
     */
    class Opened internal constructor(
        val snippets: List<Snippet>,
        val vault: VaultDocument?,
        private var key: ByteArray?,
    ) : AutoCloseable {
        val ordinaryCount: Int get() = snippets.size
        val secureCount: Int get() = vault?.records?.size ?: 0
        val totalCount: Int get() = ordinaryCount + secureCount

        /** A copy of the vault key the caller wipes, or `null` without a vault or after [close]. */
        fun vaultKey(): ByteArray? = key?.copyOf()

        override fun close() {
            key?.fill(0)
            key = null
        }

        override fun toString(): String = "Opened(ordinary=$ordinaryCount, secure=$secureCount)"
    }

    /** Cheap format detection for the import UI. Proof of nothing: authentication happens in [open]. */
    fun isEncryptedBackup(data: ByteArray): Boolean = try {
        val members = LenientJson.members(LenientJson.parseOrCorrupt(data))
        LenientJson.string(LenientJson.required(members, "format")) == FORMAT_IDENTIFIER
    } catch (_: JsonDecodeException) {
        false
    }

    /**
     * Builds a backup without decrypting a secure body.
     *
     * [vault] and [vaultKey] go together: both, or neither. A vault without records must
     * be omitted. Neither [passphrase] nor [vaultKey] is modified; the caller wipes them.
     *
     * The parameters after [iterations] exist for tests and vectors; production callers
     * leave them alone. Swift draws [passphraseSalt] internally and has no seam for it.
     *
     * @throws Failure.InvalidPayload for a library that cannot be backed up.
     * @throws PassphraseKdf.Failure for unusable KDF parameters.
     */
    @Throws(Failure::class, PassphraseKdf.Failure::class, SnippetCrypto.Failure::class)
    fun seal(
        snippets: List<Snippet>,
        vault: VaultDocument?,
        vaultKey: ByteArray?,
        passphrase: CharArray,
        iterations: Long = PassphraseKdf.ITERATIONS,
        backupId: String = "b-" + Uuids.lowercase(UUID.randomUUID()),
        exportKey: ByteArray? = null,
        passphraseSalt: ByteArray = PassphraseKdf.makeSalt(),
        keyNonce: NonceSource = NonceSource.System,
        vaultKeyNonce: NonceSource = NonceSource.System,
        payloadNonce: NonceSource = NonceSource.System,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
    ): ByteArray {
        if (passphrase.isEmpty()) throw Failure.EmptyPassphrase()
        // Measured as typed, as the Linux reader measures it, and without making a `String` of the password.
        val passphraseBytes = Utf8.encode(passphrase)
        val passphraseByteCount = passphraseBytes.size
        passphraseBytes.fill(0)
        if (passphraseByteCount > MAXIMUM_PASSPHRASE_BYTES) {
            throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.PASSPHRASE_TOO_LONG)
        }
        if (backupId.isEmpty()) throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.EMPTY_BACKUP_ID)
        if (snippets.size + (vault?.records?.size ?: 0) > MAXIMUM_RECORDS) {
            throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.TOO_MANY_RECORDS)
        }
        validateLibrary(snippets, vault)

        val key = exportKey?.copyOf() ?: Bytes.random(SnippetCrypto.KEY_BYTE_COUNT)
        try {
            val wrappedExportKey = PassphraseKdf.wrap(key, passphrase, passphraseSalt, backupId, iterations, keyNonce, pbkdf2)

            val wrappedVaultKey: String? = when {
                vault == null && vaultKey == null -> null
                vault != null && vaultKey != null -> {
                    if (vaultKey.size != SnippetCrypto.KEY_BYTE_COUNT) {
                        throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.VAULT_KEY_WRONG_SIZE)
                    }
                    val salt = vault.vaultSaltBytes
                        ?: throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.VAULT_SALT_INVALID)
                    val wrapping = vaultWrappingKey(key, salt, backupId, vault.kid)
                    try {
                        SnippetCrypto.seal(vaultKey, wrapping, vaultKeyAad(backupId, vault.kid), vaultKeyNonce)
                    } finally {
                        wrapping.fill(0)
                    }
                }
                vault == null -> throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.VAULT_KEY_WITHOUT_VAULT)
                else -> throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.VAULT_KEY_MISSING)
            }

            val payloadData = payloadBytes(snippets, vault, wrappedVaultKey)
            val sealedPayload = try {
                SnippetCrypto.seal(payloadData, key, payloadAad(backupId, CURRENT_SCHEMA_VERSION, wrappedExportKey), payloadNonce)
            } finally {
                payloadData.fill(0)
            }

            return FoundationJsonWriter.prettyPrinted(
                JsonValue.Object(
                    linkedMapOf(
                        "format" to JsonValue.Text(FORMAT_IDENTIFIER),
                        "schemaVersion" to JsonValue.Integer(CURRENT_SCHEMA_VERSION),
                        "backupID" to JsonValue.Text(backupId),
                        "wrappedKey" to VaultDocumentCodec.value(wrappedExportKey),
                        "payload" to JsonValue.Text(sealedPayload),
                    ),
                ),
            )
        } finally {
            key.fill(0)
        }
    }

    /**
     * Authenticates every layer before returning anything importable: the password, the
     * payload, the library's validity, the vault key, and every secure record together
     * with its keyed content hash.
     *
     * @param now seconds since 2001 for an ordinary snippet without `createdAt`.
     */
    @Throws(Failure::class)
    fun open(
        data: ByteArray,
        passphrase: CharArray,
        pbkdf2: Pbkdf2HmacSha512 = Pbkdf2HmacSha512.Default,
        now: () -> Double = AppleTime::now,
    ): Opened {
        if (passphrase.isEmpty()) throw Failure.EmptyPassphrase()
        if (data.size > MAXIMUM_FILE_BYTES) throw Failure.FileTooLarge()

        val container = try {
            container(LenientJson.parseOrCorrupt(data))
        } catch (_: JsonDecodeException) {
            throw Failure.InvalidFormat()
        }
        if (container.format != FORMAT_IDENTIFIER) throw Failure.InvalidFormat()
        if (container.schemaVersion != CURRENT_SCHEMA_VERSION) throw Failure.UnsupportedSchemaVersion(container.schemaVersion)
        if (container.backupId.isEmpty()) throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.EMPTY_BACKUP_ID)

        val exportKey = try {
            PassphraseKdf.unwrap(container.wrappedKey, passphrase, container.backupId, pbkdf2)
        } catch (_: PassphraseKdf.Failure.WrongPassphrase) {
            throw Failure.WrongPassphrase()
        } catch (_: PassphraseKdf.Failure.EmptyPassphrase) {
            throw Failure.EmptyPassphrase()
        } catch (_: PassphraseKdf.Failure) {
            throw Failure.InvalidFormat()
        } catch (_: SnippetCrypto.Failure) {
            throw Failure.InvalidFormat()
        }

        try {
            val payloadData = try {
                SnippetCrypto.open(
                    container.payload, exportKey,
                    payloadAad(container.backupId, container.schemaVersion, container.wrappedKey),
                )
            } catch (_: SnippetCrypto.Failure) {
                throw Failure.DamagedBackup()
            }
            val payload = try {
                payload(LenientJson.parseOrCorrupt(payloadData), now)
            } catch (_: JsonDecodeException) {
                throw Failure.DamagedBackup()
            } finally {
                payloadData.fill(0)
            }
            if (payload.schemaVersion != CURRENT_SCHEMA_VERSION) throw Failure.UnsupportedSchemaVersion(payload.schemaVersion)
            validateLibrary(payload.snippets, payload.vault)

            val vault = payload.vault
            val envelope = payload.wrappedVaultKey
            val libraryKey: ByteArray? = when {
                vault == null && envelope == null -> null
                vault != null && envelope != null -> {
                    val salt = vault.vaultSaltBytes
                        ?: throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.VAULT_SALT_INVALID)
                    val wrapping = vaultWrappingKey(exportKey, salt, container.backupId, vault.kid)
                    val recovered = try {
                        SnippetCrypto.open(envelope, wrapping, vaultKeyAad(container.backupId, vault.kid))
                    } catch (_: SnippetCrypto.Failure) {
                        throw Failure.DamagedBackup()
                    } finally {
                        wrapping.fill(0)
                    }
                    try {
                        if (recovered.size != SnippetCrypto.KEY_BYTE_COUNT) throw Failure.DamagedBackup()
                        verify(vault, recovered, salt)
                    } catch (failure: Failure) {
                        recovered.fill(0)
                        throw failure
                    }
                    recovered
                }
                vault == null -> throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.WRAPPED_VAULT_KEY_WITHOUT_VAULT)
                else -> throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.WRAPPED_VAULT_KEY_MISSING)
            }
            return Opened(payload.snippets, vault, libraryKey)
        } finally {
            exportKey.fill(0)
        }
    }

    /** As [seal] for a caller that only has a `String`, which cannot be wiped. */
    @Throws(Failure::class, PassphraseKdf.Failure::class, SnippetCrypto.Failure::class)
    fun seal(
        snippets: List<Snippet>,
        vault: VaultDocument?,
        vaultKey: ByteArray?,
        passphrase: String,
        iterations: Long = PassphraseKdf.ITERATIONS,
    ): ByteArray {
        val characters = passphrase.toCharArray()
        try {
            return seal(snippets, vault, vaultKey, characters, iterations)
        } finally {
            characters.fill('\u0000')
        }
    }

    /** As [open] for a caller that only has a `String`, which cannot be wiped. */
    @Throws(Failure::class)
    fun open(data: ByteArray, passphrase: String): Opened {
        val characters = passphrase.toCharArray()
        try {
            return open(data, characters)
        } finally {
            characters.fill('\u0000')
        }
    }

    // Authenticated data and keys

    /** The salt and the envelope go in as their text here, unlike the passphrase wrap's own AAD, which takes the salt bytes. */
    internal fun payloadAad(backupId: String, schemaVersion: Long, wrappedKey: PassphraseKdf.WrappedKey): ByteArray =
        DomainSeparated.encode(
            PAYLOAD_AAD_DOMAIN,
            Utf8.encode(FORMAT_IDENTIFIER),
            Bytes.u64be(schemaVersion),
            Utf8.encode(backupId),
            Utf8.encode(wrappedKey.alg),
            Bytes.u64be(wrappedKey.iterations),
            Utf8.encode(wrappedKey.salt),
            Utf8.encode(wrappedKey.envelope),
        )

    internal fun vaultWrappingKey(exportKey: ByteArray, salt: ByteArray, backupId: String, vaultKeyId: String): ByteArray =
        Hkdf.deriveKey(
            inputKeyMaterial = exportKey,
            salt = salt,
            info = Bytes.concat(
                Utf8.encode(VAULT_KEY_INFO_PREFIX), Utf8.encode(backupId), byteArrayOf(0), Utf8.encode(vaultKeyId),
            ),
            outputByteCount = SnippetCrypto.KEY_BYTE_COUNT,
        )

    internal fun vaultKeyAad(backupId: String, vaultKeyId: String): ByteArray = DomainSeparated.encode(
        VAULT_KEY_AAD_DOMAIN,
        Utf8.encode(SnippetCrypto.WIRE_VERSION),
        Utf8.encode(backupId),
        Utf8.encode(vaultKeyId),
    )

    // Validation

    /**
     * No id twice across ordinary and secure records; no non-empty keyword twice after
     * sanitizing and folding; no vault from a newer build; no vault without records.
     */
    @Throws(Failure.InvalidPayload::class)
    internal fun validateLibrary(snippets: List<Snippet>, vault: VaultDocument?) {
        val ids = HashSet<UUID>()
        val keywords = HashMap<String, String>()

        fun accept(id: UUID, keyword: String, displayName: String) {
            if (!ids.add(id)) throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.DUPLICATE_ID, id = id)
            val sanitized = Snippet.sanitizedKeyword(keyword)
            val folded = SnippetTagging.filterKey(sanitized)
            if (folded.isEmpty()) return
            val existing = keywords[folded]
            if (existing != null) {
                throw Failure.InvalidPayload(
                    Failure.InvalidPayload.Reason.DUPLICATE_KEYWORD,
                    keyword = sanitized, firstName = existing, secondName = displayName,
                )
            }
            keywords[folded] = displayName
        }

        for (snippet in snippets) accept(snippet.id, snippet.keyword, snippet.displayName)
        if (vault != null) {
            if (vault.schemaVersion > VaultDocument.CURRENT_SCHEMA_VERSION) {
                throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.VAULT_TOO_NEW)
            }
            if (vault.records.isEmpty()) throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.EMPTY_VAULT)
            for (record in vault.records) {
                val name = FoundationText.trimWhitespaceAndNewlines(record.name)
                accept(record.id, record.keyword, name.ifEmpty { UNTITLED })
            }
        }
    }

    /** Every record must open under the recovered key and match its keyed hash. */
    private fun verify(document: VaultDocument, libraryKey: ByteArray, salt: ByteArray) {
        SnippetCrypto.Keyring(libraryKey, salt).use { keyring ->
            for (record in document.records) {
                val plaintext = try {
                    SnippetCrypto.open(record.sealed, SnippetCrypto.RecordContext(document.kid, record.id), keyring)
                } catch (_: SnippetCrypto.Failure) {
                    throw Failure.DamagedBackup()
                }
                try {
                    if (SnippetCrypto.contentHash(plaintext, keyring) != record.contentHash) throw Failure.DamagedBackup()
                } finally {
                    plaintext.fill(0)
                }
            }
        }
    }

    // JSON

    private class Container(
        val format: String,
        val schemaVersion: Long,
        val backupId: String,
        val wrappedKey: PassphraseKdf.WrappedKey,
        val payload: String,
    )

    private class Payload(
        val schemaVersion: Long,
        val snippets: List<Snippet>,
        val vault: VaultDocument?,
        val wrappedVaultKey: String?,
    )

    private fun container(node: JsonNode): Container {
        val members = LenientJson.members(node)
        return Container(
            format = LenientJson.string(LenientJson.required(members, "format")),
            schemaVersion = LenientJson.long(LenientJson.required(members, "schemaVersion")),
            backupId = LenientJson.string(LenientJson.required(members, "backupID")),
            wrappedKey = VaultDocumentCodec.wrappedKey(LenientJson.required(members, "wrappedKey")),
            payload = LenientJson.string(LenientJson.required(members, "payload")),
        )
    }

    private fun payload(node: JsonNode, now: () -> Double): Payload {
        val members = LenientJson.members(node)
        return Payload(
            schemaVersion = LenientJson.long(LenientJson.required(members, "schemaVersion")),
            snippets = LenientJson.array(LenientJson.required(members, "snippets")).map { snippet(it, now) },
            vault = LenientJson.present(members, "vault")?.let {
                VaultDocumentCodec.document(it, VaultDocumentCodec.Dates.BACKUP_PAYLOAD)
            },
            wrappedVaultKey = LenientJson.present(members, "wrappedVaultKey")?.let(LenientJson::string),
        )
    }

    /** `Snippet.init(from:)`: four required strings; the rest may be missing or null, and a wrong type is an error. */
    private fun snippet(node: JsonNode, now: () -> Double): Snippet {
        val members = LenientJson.members(node)
        val id = VaultDocumentCodec.uuid(LenientJson.string(LenientJson.required(members, "id")))
        val name = LenientJson.string(LenientJson.required(members, "name"))
        val keyword = LenientJson.string(LenientJson.required(members, "keyword"))
        val content = LenientJson.string(LenientJson.required(members, "content"))
        val tags = SnippetTagging.normalizedTags(
            LenientJson.present(members, "tags")?.let { LenientJson.array(it).map(LenientJson::string) } ?: emptyList(),
        )
        val isEnabled = LenientJson.present(members, "isEnabled")?.let(LenientJson::boolean) ?: true
        val isPinned = LenientJson.present(members, "isPinned")?.let(LenientJson::boolean) ?: false
        val createdAt = LenientJson.present(members, "createdAt")?.let(::date) ?: now()
        val updatedAt = LenientJson.present(members, "updatedAt")?.let(::date) ?: createdAt
        return Snippet(id, name, keyword, content, tags, isEnabled, isPinned, createdAt, updatedAt)
    }

    // A number is seconds since 2001 (Swift). An ISO-8601 string is accepted as well.
    private fun date(node: JsonNode): Double {
        if (node is JsonNode.Num) return LenientJson.double(node)
        return VaultTimestamp.parse(LenientJson.string(node)) ?: throw LenientJson.corrupted("malformed timestamp")
    }

    private fun payloadBytes(snippets: List<Snippet>, vault: VaultDocument?, wrappedVaultKey: String?): ByteArray {
        val members = LinkedHashMap<String, JsonValue>()
        members["schemaVersion"] = JsonValue.Integer(CURRENT_SCHEMA_VERSION)
        members["snippets"] = JsonValue.Array(snippets.map(::value))
        try {
            // Absent, not null, without a vault: that is what Swift's synthesized encoder writes.
            if (vault != null) members["vault"] = VaultDocumentCodec.value(vault, VaultDocumentCodec.Dates.BACKUP_PAYLOAD)
            if (wrappedVaultKey != null) members["wrappedVaultKey"] = JsonValue.Text(wrappedVaultKey)
            return FoundationJsonWriter.prettyPrinted(JsonValue.Object(members))
        } catch (_: VaultEncodeException) {
            throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.NOT_ENCODABLE)
        } catch (_: FoundationJsonWriter.NonFiniteNumber) {
            throw Failure.InvalidPayload(Failure.InvalidPayload.Reason.NOT_ENCODABLE)
        }
    }

    // The nine keys of `Snippet.encode(to:)`, as `SnippetLibraryCodec` writes them.
    private fun value(snippet: Snippet): JsonValue = JsonValue.Object(
        linkedMapOf(
            "id" to JsonValue.Text(Uuids.uppercase(snippet.id)),
            "name" to JsonValue.Text(snippet.name),
            "keyword" to JsonValue.Text(snippet.keyword),
            "content" to JsonValue.Text(snippet.content),
            "tags" to JsonValue.Array(snippet.tags.map { JsonValue.Text(it) }),
            "isEnabled" to JsonValue.Bool(snippet.isEnabled),
            "isPinned" to JsonValue.Bool(snippet.isPinned),
            "createdAt" to JsonValue.Real(snippet.createdAt),
            "updatedAt" to JsonValue.Real(snippet.updatedAt),
        ),
    )
}
