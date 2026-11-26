package com.khm.snippets.core.backup

import com.khm.snippets.core.backup.EncryptedBackup.Failure.InvalidPayload.Reason
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.Hlc
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.Fixtures
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.filled
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultFile
import com.khm.snippets.core.vault.VaultKdfParameters
import com.khm.snippets.core.vault.VaultRecord
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `Tests/Core/EncryptedSnippetBackupTests.swift` (Swift names kept) and
 * `snippets-linux/src/backup_tests.rs` (Rust names in the comments), plus a tamper test
 * for every field of the container.
 */
class EncryptedBackupTest {

    private val fastIterations = 2_000L
    private val passphrase = "correct horse battery staple"

    private fun appleSeconds(unixSeconds: Double) = unixSeconds - 978_307_200.0

    private fun contains(haystack: ByteArray, needle: ByteArray): Boolean {
        outer@ for (start in 0..haystack.size - needle.size) {
            for (offset in needle.indices) if (haystack[start + offset] != needle[offset]) continue@outer
            return true
        }
        return false
    }

    private class Vault(val document: VaultDocument, val key: ByteArray)

    private fun makeVault(
        body: ByteArray,
        recordId: UUID = UUID.fromString("00000000-0000-0000-0000-000000000202"),
        keyword: String = "prod-secret",
    ): Vault {
        val ring = SnippetCrypto.Keyring.generate()
        val kid = "k-backup-tests"
        val record = VaultRecord(
            id = recordId,
            name = "Production password",
            keyword = keyword,
            tags = listOf("Private"),
            isEnabled = true,
            isPinned = true,
            createdAt = appleSeconds(300.0),
            updatedAt = appleSeconds(400.0),
            hlc = Hlc.of(400_000, 0, "aabbccdd"),
            contentHash = SnippetCrypto.contentHash(body, ring),
            sealed = SnippetCrypto.seal(body, SnippetCrypto.RecordContext(kid, recordId), ring),
        )
        val document = VaultDocument(
            kid = kid,
            vaultSalt = Base64Url.encode(ring.salt()),
            kdf = VaultKdfParameters(PassphraseKdf.ALGORITHM, PassphraseKdf.ITERATIONS, Base64Url.encode(PassphraseKdf.makeSalt())),
            records = listOf(record),
        )
        return Vault(document, ring.libraryKey())
    }

    private fun ordinary(name: String = "A", keyword: String = "a", content: String = "body") =
        Snippet(name = name, keyword = keyword, content = content)

    private fun sealOrdinary(vararg snippets: Snippet = arrayOf(ordinary())): ByteArray =
        EncryptedBackup.seal(snippets.toList(), null, null, passphrase.toCharArray(), fastIterations)

    // EncryptedSnippetBackupTests.swift

    @Test fun roundTripKeepsBothLibrariesAndAllMetadataInsideCiphertext() {
        val ordinary = Snippet(
            id = UUID.fromString("00000000-0000-0000-0000-000000000101"),
            name = "Team greeting",
            keyword = "hello-team",
            content = "Hello colleagues",
            tags = listOf("Shared"),
            createdAt = appleSeconds(100.0),
            updatedAt = appleSeconds(200.0),
        )
        val secureBody = "swordfish-9134".toByteArray()
        val vault = makeVault(secureBody)

        val data = EncryptedBackup.seal(listOf(ordinary), vault.document, vault.key, passphrase.toCharArray(), fastIterations)

        assertTrue(EncryptedBackup.isEncryptedBackup(data))
        for (secret in listOf(
            ordinary.name, ordinary.keyword, ordinary.content,
            vault.document.records[0].name, vault.document.records[0].keyword, "swordfish-9134", vault.document.kid,
        )) {
            assertFalse(contains(data, secret.toByteArray()), "'$secret' is legible in the backup")
        }
        assertFalse(contains(data, vault.key))
        assertFalse(contains(data, passphrase.toByteArray()))

        val opened = EncryptedBackup.open(data, passphrase.toCharArray())
        assertEquals(listOf(ordinary), opened.snippets)
        assertEquals(vault.document, opened.vault)
        assertEquals(1, opened.ordinaryCount)
        assertEquals(1, opened.secureCount)
        assertEquals(2, opened.totalCount)
        assertContentEquals(vault.key, opened.vaultKey())
    }

    @Test fun ordinaryOnlyBackupsNeedNoVaultKey() {
        val snippet = Snippet(name = "Ordinary", keyword = "ordinary", content = "text")
        val data = EncryptedBackup.seal(listOf(snippet), null, null, passphrase.toCharArray(), fastIterations)

        val opened = EncryptedBackup.open(data, passphrase.toCharArray())
        assertEquals(listOf(snippet), opened.snippets)
        assertNull(opened.vault)
        assertNull(opened.vaultKey())
    }

    @Test fun wrongPasswordIsRefusedWithoutReturningPartialData() {
        val data = sealOrdinary()
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { EncryptedBackup.open(data, "wrong password".toCharArray()) }
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { EncryptedBackup.open(data, "wrong password") }
        assertFailsWith<EncryptedBackup.Failure.EmptyPassphrase> { EncryptedBackup.open(data, CharArray(0)) }
    }

    @Test fun modifyingThePayloadFailsAuthentication() {
        val json = Json.parseToJsonElement(String(sealOrdinary(), Charsets.UTF_8)).jsonObject
        val payload = json.getValue("payload").jsonPrimitive.content
        val last = if (payload.last() == 'A') 'B' else 'A'
        val tampered = JsonObject(json + ("payload" to JsonPrimitive(payload.dropLast(1) + last)))

        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> {
            EncryptedBackup.open(tampered.toString().toByteArray(), passphrase.toCharArray())
        }
    }

    @Test fun duplicateIdentityAcrossPlaintextAndVaultIsRefusedBeforeWritingAFile() {
        val id = UUID.randomUUID()
        val ordinary = Snippet(id = id, name = "Ordinary", keyword = "same", content = "body")
        val vault = makeVault("secret".toByteArray(), recordId = id)

        val failure = assertFailsWith<EncryptedBackup.Failure.InvalidPayload> {
            EncryptedBackup.seal(listOf(ordinary), vault.document, vault.key, passphrase.toCharArray(), fastIterations)
        }
        assertEquals(EncryptedBackup.Failure.InvalidPayload.Reason.DUPLICATE_ID, failure.reason)
        assertEquals(id, failure.id)
    }

    @Test fun anEmptyVaultIsOmittedRatherThanCarryingAnUnverifiableKey() {
        val vault = makeVault("secret".toByteArray())
        val failure = assertFailsWith<EncryptedBackup.Failure.InvalidPayload> {
            EncryptedBackup.seal(emptyList(), vault.document.copy(records = emptyList()), vault.key, passphrase.toCharArray(), fastIterations)
        }
        assertEquals(EncryptedBackup.Failure.InvalidPayload.Reason.EMPTY_VAULT, failure.reason)
    }

    // backup_tests.rs

    /** `round_trip_seals_metadata_and_bodies_with_independent_random_keys_and_nonces` */
    @Test fun twoBackupsOfTheSameLibraryShareNothing() {
        val vault = makeVault("body".toByteArray())
        fun seal() = EncryptedBackup.seal(listOf(ordinary()), vault.document, vault.key, passphrase.toCharArray(), fastIterations)
        val first = Json.parseToJsonElement(String(seal(), Charsets.UTF_8)).jsonObject
        val second = Json.parseToJsonElement(String(seal(), Charsets.UTF_8)).jsonObject

        for (key in listOf("backupID", "payload", "wrappedKey")) assertFalse(first[key] == second[key], "$key repeated")
        assertTrue(first.getValue("backupID").jsonPrimitive.content.matches(Regex("b-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")))
        // Exactly the five keys, and the four of the wrapped key: the Linux reader refuses anything else.
        assertEquals(setOf("backupID", "format", "payload", "schemaVersion", "wrappedKey"), first.keys)
        assertEquals(setOf("alg", "envelope", "iterations", "salt"), first.getValue("wrappedKey").jsonObject.keys)
        assertEquals(16, Base64Url.decode(first.getValue("wrappedKey").jsonObject.getValue("salt").jsonPrimitive.content)!!.size)
    }

    /**
     * `changed_header_ciphertext_or_password_never_returns_partial_data`, with Swift's
     * outcome for each field: structural damage is `InvalidFormat` or `DamagedBackup`,
     * and the only edits that read as a wrong password are those to values the passphrase
     * wrap itself authenticates.
     */
    @Test fun changingAnyHeaderFieldNeverReturnsPartialData() {
        val data = sealOrdinary()
        val original = Json.parseToJsonElement(String(data, Charsets.UTF_8)).jsonObject
        val wrappedKey = original.getValue("wrappedKey").jsonObject

        fun with(key: String, value: JsonElement) = JsonObject(original + (key to value)).toString().toByteArray()
        fun withWrapped(key: String, value: JsonElement) = with("wrappedKey", JsonObject(wrappedKey + (key to value)))
        fun open(bytes: ByteArray) = EncryptedBackup.open(bytes, passphrase.toCharArray())

        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(with("format", JsonPrimitive("public-other-format"))) }
        assertEquals(2L, assertFailsWith<EncryptedBackup.Failure.UnsupportedSchemaVersion> { open(with("schemaVersion", JsonPrimitive(2))) }.version)
        assertFailsWith<EncryptedBackup.Failure.UnsupportedSchemaVersion> { open(with("schemaVersion", JsonPrimitive(0))) }
        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(with("schemaVersion", JsonPrimitive("1"))) }
        // The backup id is in the passphrase wrap's AAD: Swift reports a changed one as a wrong password.
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { open(with("backupID", JsonPrimitive("public-other-backup"))) }
        assertEquals(
            EncryptedBackup.Failure.InvalidPayload.Reason.EMPTY_BACKUP_ID,
            assertFailsWith<EncryptedBackup.Failure.InvalidPayload> { open(with("backupID", JsonPrimitive(""))) }.reason,
        )
        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(withWrapped("alg", JsonPrimitive("public-unsupported-kdf"))) }
        // Iterations and salt feed the KDF and its AAD: a different key, so the tag fails.
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { open(withWrapped("iterations", JsonPrimitive(2001))) }
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { open(withWrapped("salt", JsonPrimitive(Base64Url.encode(filled(0x12, 16))))) }
        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(withWrapped("salt", JsonPrimitive("***"))) }
        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(withWrapped("salt", JsonPrimitive(""))) }
        // The payload in place of the key envelope, and the reverse: well-formed envelopes under the wrong key.
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { open(withWrapped("envelope", original.getValue("payload"))) }
        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(withWrapped("envelope", JsonPrimitive("v1.AAAA"))) }
        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(withWrapped("envelope", JsonPrimitive("v2.AAAAAAAAAAAAAAAA.AAAA"))) }
        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> { open(with("payload", wrappedKey.getValue("envelope"))) }
        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> { open(with("payload", JsonPrimitive("v1.AAAA"))) }

        // A missing key, or a key of the wrong type, anywhere in the container.
        for (key in original.keys) {
            assertFailsWith<EncryptedBackup.Failure.InvalidFormat>(key) { open(JsonObject(original - key).toString().toByteArray()) }
        }
        for (key in wrappedKey.keys) {
            assertFailsWith<EncryptedBackup.Failure.InvalidFormat>(key) { open(with("wrappedKey", JsonObject(wrappedKey - key))) }
        }
        assertFailsWith<EncryptedBackup.Failure.InvalidFormat> { open(with("wrappedKey", JsonPrimitive("not an object"))) }

        // Untouched, it still opens: every failure above came from the edit.
        assertEquals(1, open(data).ordinaryCount)
        // Unknown keys in the container do not matter to this reader (Swift ignores them too).
        assertEquals(1, open(with("comment", JsonPrimitive("added by hand"))).ordinaryCount)
    }

    /** `export_copies_secure_ciphertext_without_opening_it_but_import_authenticates_all_records` */
    @Test fun exportCopiesCiphertextWithoutOpeningItButImportAuthenticatesEveryRecord() {
        // A record whose stored hash is wrong: sealing does not notice (it never opens a body), opening does.
        val vault = makeVault("body".toByteArray())
        val damagedHash = vault.document.copy(records = listOf(vault.document.records[0].copy(contentHash = "00".repeat(16))))
        val sealed = EncryptedBackup.seal(listOf(ordinary()), damagedHash, vault.key, passphrase.toCharArray(), fastIterations)
        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> { EncryptedBackup.open(sealed, passphrase.toCharArray()) }

        // A vault key that is not the vault's.
        val wrongKey = EncryptedBackup.seal(emptyList(), vault.document, filled(0x33, 32), passphrase.toCharArray(), fastIterations)
        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> { EncryptedBackup.open(wrongKey, passphrase.toCharArray()) }

        // A body moved onto another record's id.
        val other = makeVault("other".toByteArray(), recordId = UUID.fromString("00000000-0000-0000-0000-000000000303"), keyword = "other")
        val swapped = vault.document.copy(records = listOf(vault.document.records[0].copy(sealed = other.document.records[0].sealed)))
        val swappedBackup = EncryptedBackup.seal(emptyList(), swapped, vault.key, passphrase.toCharArray(), fastIterations)
        assertFailsWith<EncryptedBackup.Failure.DamagedBackup> { EncryptedBackup.open(swappedBackup, passphrase.toCharArray()) }
    }

    /** `duplicate_identifiers_keywords_and_empty_vaults_are_refused_before_encryption` */
    @Test fun duplicateIdentifiersKeywordsAndMismatchedVaultPartsAreRefusedBeforeEncryption() {
        val vault = makeVault("secret".toByteArray())
        fun reason(block: () -> Unit) = assertFailsWith<EncryptedBackup.Failure.InvalidPayload> { block() }.reason

        // The same keyword in both halves, compared sanitized and folded.
        val clash = assertFailsWith<EncryptedBackup.Failure.InvalidPayload> {
            EncryptedBackup.seal(listOf(ordinary(name = "Mine", keyword = " \\PROD-secret ")), vault.document, vault.key, passphrase.toCharArray(), fastIterations)
        }
        assertEquals(Reason.DUPLICATE_KEYWORD, clash.reason)
        assertEquals("prod-secret", clash.keyword)
        assertEquals(listOf("Mine", "Production password"), listOf(clash.firstName, clash.secondName))
        assertFalse(clash.message!!.contains("Mine"), "a snippet's name must not be in an exception message")
        // Twice in the ordinary half; and an empty keyword is nobody's.
        assertEquals(Reason.DUPLICATE_KEYWORD, reason { sealOrdinary(ordinary(keyword = "Café"), ordinary(keyword = "cafe")) })
        assertEquals(Reason.DUPLICATE_ID, reason { ordinary().let { sealOrdinary(it, it.copy(keyword = "b")) } })
        EncryptedBackup.open(sealOrdinary(ordinary(keyword = ""), ordinary(keyword = " ")), passphrase.toCharArray())

        assertEquals(Reason.VAULT_KEY_MISSING, reason { EncryptedBackup.seal(emptyList(), vault.document, null, passphrase.toCharArray(), fastIterations) })
        assertEquals(Reason.VAULT_KEY_WITHOUT_VAULT, reason { EncryptedBackup.seal(emptyList(), null, vault.key, passphrase.toCharArray(), fastIterations) })
        assertEquals(Reason.VAULT_KEY_WRONG_SIZE, reason { EncryptedBackup.seal(emptyList(), vault.document, ByteArray(31), passphrase.toCharArray(), fastIterations) })
        assertEquals(Reason.VAULT_SALT_INVALID, reason { EncryptedBackup.seal(emptyList(), vault.document.copy(vaultSalt = "c2FsdA=="), vault.key, passphrase.toCharArray(), fastIterations) })
        assertEquals(Reason.VAULT_TOO_NEW, reason { EncryptedBackup.seal(emptyList(), vault.document.copy(schemaVersion = 2), vault.key, passphrase.toCharArray(), fastIterations) })
        assertEquals(Reason.EMPTY_BACKUP_ID, reason { EncryptedBackup.seal(listOf(ordinary()), null, null, passphrase.toCharArray(), fastIterations, backupId = "") })
        assertEquals(Reason.NOT_ENCODABLE, reason { sealOrdinary(ordinary().copy(createdAt = Double.NaN)) })
        assertFailsWith<EncryptedBackup.Failure.EmptyPassphrase> { EncryptedBackup.seal(listOf(ordinary()), null, null, CharArray(0), fastIterations) }
    }

    /** `large_ordinary_payloads_use_backup_limits_and_unsupported_parameters_fail_before_kdf` */
    @Test fun largePayloadsRoundTripAndTheLimitsHold() {
        val first = ordinary(keyword = "first", content = "a".repeat(200_000))
        val second = ordinary(keyword = "second", content = "a".repeat(200_000))
        val data = sealOrdinary(first, second)
        assertTrue(data.size > 256 * 1024)
        assertEquals(listOf(first, second), EncryptedBackup.open(data, passphrase.toCharArray()).snippets)

        // Rounds out of range are refused before the KDF runs: never minutes of work for a hostile file.
        val original = Json.parseToJsonElement(String(data, Charsets.UTF_8)).jsonObject
        for (rounds in listOf("0", "-1", "20000001", "18446744073709551615", "1.5")) {
            val wrapped = JsonObject(original.getValue("wrappedKey").jsonObject + ("iterations" to Json.parseToJsonElement(rounds)))
            val started = System.nanoTime()
            assertFailsWith<EncryptedBackup.Failure.InvalidFormat>(rounds) {
                EncryptedBackup.open(JsonObject(original + ("wrappedKey" to wrapped)).toString().toByteArray(), passphrase.toCharArray())
            }
            assertTrue(System.nanoTime() - started < 2_000_000_000L, "$rounds rounds were actually run")
        }

        assertFailsWith<EncryptedBackup.Failure.FileTooLarge> {
            EncryptedBackup.open(ByteArray(EncryptedBackup.MAXIMUM_FILE_BYTES + 1) { ' '.code.toByte() }, passphrase.toCharArray())
        }
        assertEquals(32 * 1024 * 1024, EncryptedBackup.MAXIMUM_FILE_BYTES)
        assertEquals(16 * 1024 * 1024, EncryptedBackup.MAXIMUM_JSON_IMPORT_BYTES)
        assertEquals("snippetsbackup", EncryptedBackup.PREFERRED_FILENAME_EXTENSION)

        // What this writer refuses so that the Linux reader can open everything it writes.
        assertEquals(
            EncryptedBackup.Failure.InvalidPayload.Reason.PASSPHRASE_TOO_LONG,
            assertFailsWith<EncryptedBackup.Failure.InvalidPayload> {
                EncryptedBackup.seal(listOf(ordinary()), null, null, CharArray(4097) { 'x' }, fastIterations)
            }.reason,
        )
        EncryptedBackup.seal(listOf(ordinary()), null, null, CharArray(4096) { 'x' }, 1)
    }

    // The payload

    @Test fun thePayloadIsWrittenAsSwiftWritesItAndBothSpellingsAreRead() {
        val vault = makeVault("body".toByteArray())
        val data = EncryptedBackup.seal(listOf(ordinary()), vault.document, vault.key, passphrase.toCharArray(), fastIterations)

        // A second writer's payload for the same library: explicit nulls, ISO dates, lowercase ids, an integer date.
        val container = Json.parseToJsonElement(String(data, Charsets.UTF_8)).jsonObject
        val wrapped = container.getValue("wrappedKey").jsonObject
        val wrappedKey = PassphraseKdf.WrappedKey(
            wrapped.getValue("alg").jsonPrimitive.content, wrapped.getValue("iterations").jsonPrimitive.content.toLong(),
            wrapped.getValue("salt").jsonPrimitive.content, wrapped.getValue("envelope").jsonPrimitive.content,
        )
        val backupId = container.getValue("backupID").jsonPrimitive.content
        val exportKey = PassphraseKdf.unwrap(wrappedKey, passphrase, backupId)
        val aad = EncryptedBackup.payloadAad(backupId, 1, wrappedKey)
        val payload = String(SnippetCrypto.open(container.getValue("payload").jsonPrimitive.content, exportKey, aad), Charsets.UTF_8)

        // What this writer wrote: numbers for every date, uppercase ids, the vault's explicit nulls.
        assertTrue(payload.contains("\"createdAt\" : ${-978306900}"), payload.take(400))
        assertTrue(payload.contains("\"id\" : \"00000000-0000-0000-0000-000000000202\""))
        assertTrue(payload.contains("\"wrapCLI\" : null"))
        assertFalse(payload.contains("T00:05:00"), "a vault date was written as an ISO string")

        fun reopened(payloadText: String): EncryptedBackup.Opened {
            val sealedPayload = SnippetCrypto.seal(payloadText.toByteArray(), exportKey, aad)
            return EncryptedBackup.open(
                JsonObject(container + ("payload" to JsonPrimitive(sealedPayload))).toString().toByteArray(), passphrase.toCharArray(),
            )
        }

        val linuxStyle = payload
            .replace("\"createdAt\" : ${-978306900}", "\"createdAt\" : \"1970-01-01T00:05:00.000Z\"")
            .replace("\"updatedAt\" : ${-978306800}", "\"updatedAt\" : \"1970-01-01T00:06:40Z\"")
        assertTrue(linuxStyle != payload)
        val fromIso = reopened(linuxStyle)
        assertEquals(vault.document, fromIso.vault, "ISO dates in the payload must read as the same dates")

        // No vault: absent keys and explicit nulls mean the same.
        val ordinaryOnly = """{"schemaVersion":1,"snippets":[],"vault":null,"wrappedVaultKey":null}"""
        assertNull(reopened(ordinaryOnly).vault)
        assertNull(reopened("""{"schemaVersion":1,"snippets":[]}""").vault)

        // The two optional keys go together.
        assertIs<EncryptedBackup.Failure.InvalidPayload>(runCatching { reopened(payload.replace(Regex(",\\s*\"wrappedVaultKey\" : \"[^\"]+\""), "")) }.exceptionOrNull())
        assertIs<EncryptedBackup.Failure.InvalidPayload>(
            runCatching { reopened("""{"schemaVersion":1,"snippets":[],"wrappedVaultKey":"v1.AAAAAAAAAAAAAAAA.AAAA"}""") }.exceptionOrNull(),
        )
        // A payload that authenticates but is not a library is damage, not a wrong password.
        assertIs<EncryptedBackup.Failure.DamagedBackup>(runCatching { reopened("[]") }.exceptionOrNull())
        assertIs<EncryptedBackup.Failure.DamagedBackup>(runCatching { reopened("""{"schemaVersion":1}""") }.exceptionOrNull())
        assertIs<EncryptedBackup.Failure.DamagedBackup>(
            runCatching { reopened("""{"schemaVersion":1,"snippets":[{"id":"x","name":"","keyword":"","content":""}]}""") }.exceptionOrNull(),
        )
        assertIs<EncryptedBackup.Failure.DamagedBackup>(
            runCatching {
                reopened("""{"schemaVersion":1,"snippets":[{"id":"00000000-0000-4000-8000-000000000001","name":"","keyword":"","content":"","createdAt":"yesterday"}]}""")
            }.exceptionOrNull(),
        )
        assertIs<EncryptedBackup.Failure.UnsupportedSchemaVersion>(runCatching { reopened("""{"schemaVersion":2,"snippets":[]}""") }.exceptionOrNull())
        // A library that would not be valid here is refused on the way in as well.
        val twice = """{"id":"00000000-0000-4000-8000-000000000001","name":"","keyword":"","content":""}"""
        assertIs<EncryptedBackup.Failure.InvalidPayload>(
            runCatching { reopened("""{"schemaVersion":1,"snippets":[$twice,$twice]}""") }.exceptionOrNull(),
        )

        // An ordinary snippet without dates gets the injected "now", and ISO or numeric dates otherwise.
        val undated = SnippetCrypto.seal(
            """{"schemaVersion":1,"snippets":[
                {"id":"00000000-0000-4000-8000-000000000001","name":"n","keyword":"one","content":"c"},
                {"id":"00000000-0000-4000-8000-000000000002","name":"n","keyword":"two","content":"c","createdAt":"2026-07-29T08:00:00.500Z","updatedAt":807004801}
            ]}""".toByteArray(),
            exportKey, aad,
        )
        val opened = EncryptedBackup.open(
            JsonObject(container + ("payload" to JsonPrimitive(undated))).toString().toByteArray(), passphrase.toCharArray(), now = { 42.0 },
        )
        assertEquals(listOf(42.0, 42.0, 807004800.5, 807004801.0), opened.snippets.flatMap { listOf(it.createdAt, it.updatedAt) })
    }

    @Test fun unknownVaultKeysTravelThroughABackup() {
        val vault = makeVault("body".toByteArray())
        val future = vault.document.copy(
            x = mapOf("futurePublicBackupField" to JsonValue.obj("enabled" to JsonValue.of(true))),
            kdf = vault.document.kdf.copy(x = mapOf("memoryKiB" to JsonValue.of(65536L))),
            records = listOf(vault.document.records[0].copy(x = mapOf("expiresAt" to JsonValue.of("2027-01-01T00:00:00.000Z")))),
        )
        val opened = EncryptedBackup.open(
            EncryptedBackup.seal(emptyList(), future, vault.key, passphrase.toCharArray(), fastIterations), passphrase.toCharArray(),
        )
        assertEquals(future, opened.vault)
        // And the vault in a backup is the vault file's document: it decodes from either spelling.
        assertEquals(future, VaultFile.decode(VaultFile.encode(assertNotNull(opened.vault))))
    }

    @Test fun formatDetectionIsCheapAndProvesNothing() {
        assertTrue(EncryptedBackup.isEncryptedBackup("""{"format":"com.khm.snippets.encrypted-backup"}""".toByteArray()))
        assertFalse(EncryptedBackup.isEncryptedBackup("""{"format":"com.example.other"}""".toByteArray()))
        assertFalse(EncryptedBackup.isEncryptedBackup("""{"snippets":[]}""".toByteArray()))
        assertFalse(EncryptedBackup.isEncryptedBackup("[]".toByteArray()))
        assertFalse(EncryptedBackup.isEncryptedBackup(ByteArray(0)))
        assertFalse(EncryptedBackup.isEncryptedBackup(Fixtures.bytes("fixtures/linux/crypto-v1.json")))
    }

    @Test fun thePasswordIsNormalizedSoEitherSpellingOpensTheBackup() {
        val composed = "Café public backup"
        val decomposed = "Café public backup"
        val data = EncryptedBackup.seal(listOf(ordinary()), null, null, composed.toCharArray(), fastIterations)
        assertEquals(1, EncryptedBackup.open(data, decomposed.toCharArray()).ordinaryCount)
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { EncryptedBackup.open(data, "Cafe public backup".toCharArray()) }
    }
}
