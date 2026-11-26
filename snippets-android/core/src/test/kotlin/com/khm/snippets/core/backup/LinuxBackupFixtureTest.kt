package com.khm.snippets.core.backup

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Fixtures
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.vault.VaultFile
import com.khm.snippets.core.vault.VaultTimestamp
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The independent backup fixtures of `snippets-linux/tests/fixtures/` (Python and
 * OpenSSL): `backup-v1.json`, and the backup inside
 * `restoration-additional-vault-v1.json`. Both write the vault's dates as ISO-8601
 * strings and run the KDF at the shipping 600 000 rounds.
 */
class LinuxBackupFixtureTest {

    private fun containerBytes(fixture: JsonElement): ByteArray =
        Json.encodeToString(JsonElement.serializer(), fixture.jsonObject.getValue("container")).toByteArray()

    /** `opens_independent_openssl_backup_with_nfc_password_and_preserved_future_fields` */
    @Test fun opensIndependentOpensslBackupWithNfcPasswordAndPreservedFutureFields() {
        val fixture = Fixtures.linux("backup-v1.json")
        val bytes = containerBytes(fixture)
        assertTrue(EncryptedBackup.isEncryptedBackup(bytes))

        // The fixture was sealed with the composed spelling; it is opened with the decomposed one.
        assertEquals("Café public backup fixture", fixture.getValue("password").jsonPrimitive.content)
        val opened = EncryptedBackup.open(bytes, "Café public backup fixture".toCharArray())

        assertEquals(1, opened.ordinaryCount)
        assertEquals(1, opened.secureCount)
        val expected = fixture.getValue("ordinary").jsonObject
        val snippet = opened.snippets.single()
        assertEquals(Uuids.parse(expected.getValue("id").jsonPrimitive.content), snippet.id)
        assertEquals(expected.getValue("name").jsonPrimitive.content, snippet.name)
        assertEquals(expected.getValue("keyword").jsonPrimitive.content, snippet.keyword)
        assertEquals(expected.getValue("content").jsonPrimitive.content, snippet.content)
        assertEquals(expected.getValue("tags").jsonArray.map { it.jsonPrimitive.content }, snippet.tags)
        assertEquals(expected.getValue("isPinned").jsonPrimitive.boolean, snippet.isPinned)
        assertEquals(expected.getValue("createdAt").jsonPrimitive.double, snippet.createdAt)
        assertEquals(expected.getValue("updatedAt").jsonPrimitive.double, snippet.updatedAt)

        val vault = assertNotNull(opened.vault)
        assertEquals("public-interop-fixture", vault.kid)
        // Unknown fields survive. The device-local receipt is still there: dropping it is the importer's job (as in Swift).
        assertEquals(JsonValue.obj("enabled" to JsonValue.of(true)), vault.x["futurePublicBackupField"])
        assertEquals(vault.x.keys.filter { it.startsWith("local.syncConflictC0Receipts.") }.size, 1)
        assertTrue(vault.removingLocalConflictInstallReceipts().x.keys.none { it.startsWith("local.syncConflictC0Receipts.") })

        // The vault's dates are ISO strings in this payload. They are read, not lost (hazard H2).
        val record = vault.records.single()
        assertEquals(VaultTimestamp.parse("2026-09-30T10:00:00.000Z"), record.createdAt)
        assertEquals(VaultTimestamp.parse("2026-09-30T10:01:00.000Z"), record.updatedAt)
        assertTrue(record.createdAt != VaultTimestamp.DISTANT_PAST)
        assertEquals("019f1a3d4880-0000-1234abcd", record.hlc.string)

        // The recovered key is the crypto fixture's root, and it opens the body.
        val key = assertNotNull(opened.vaultKey())
        assertEquals("11".repeat(32), Bytes.toHex(key))
        val keyring = SnippetCrypto.Keyring(key, vault.vaultSaltBytes!!)
        assertContentEquals(
            "Fictional secret 🦀\n".toByteArray(),
            SnippetCrypto.open(record.sealed, SnippetCrypto.RecordContext(vault.kid, record.id), keyring),
        )

        // The same vault is the document of crypto-v1.json plus the two added keys.
        val cryptoDocument = VaultFile.decode(
            Json.encodeToString(JsonElement.serializer(), Fixtures.linux("crypto-v1.json").getValue("document")).toByteArray(),
        )
        assertEquals(cryptoDocument.records, vault.records)
        assertEquals(cryptoDocument.wrapRecovery, vault.wrapRecovery)

        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { EncryptedBackup.open(bytes, "Cafe public backup fixture".toCharArray()) }
    }

    @Test fun opensTheSecondIndependentBackupAndFindsBothSecureRecords() {
        val fixture = Fixtures.linux("restoration-additional-vault-v1.json")
        val opened = EncryptedBackup.open(containerBytes(fixture), fixture.getValue("backupPassword").jsonPrimitive.content.toCharArray())

        val vault = assertNotNull(opened.vault)
        assertEquals("public-interop-fixture", vault.kid)
        assertEquals(fixture.getValue("rootKeyHex").jsonPrimitive.content, Bytes.toHex(opened.vaultKey()!!))
        val keyring = SnippetCrypto.Keyring(opened.vaultKey()!!, vault.vaultSaltBytes!!)
        val bodies = vault.records.map {
            String(SnippetCrypto.open(it.sealed, SnippetCrypto.RecordContext(vault.kid, it.id), keyring), Charsets.UTF_8)
        }
        assertTrue(fixture.getValue("plaintext").jsonPrimitive.content in bodies)
        assertTrue(vault.records.all { it.createdAt == VaultTimestamp.parse("2026-09-30T10:00:00.000Z") })
        assertEquals(opened.secureCount, vault.records.size)
    }
}
