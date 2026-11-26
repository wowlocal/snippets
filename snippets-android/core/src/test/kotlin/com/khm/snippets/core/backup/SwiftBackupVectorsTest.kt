package com.khm.snippets.core.backup

import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.crypto.fixedNonce
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.vault.VaultDocumentCodec
import com.khm.snippets.core.vault.VaultTimestamp
import com.khm.snippets.core.vault.timestampBits
import com.khm.snippets.core.vault.vectorDocument
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Vector V15, emitted by the unmodified Swift sources (`tools/swift-interop`): the
 * `EncryptedSnippetBackup` container, the passphrase wrap, the payload AAD, the vault-key
 * wrap and the decrypted payload JSON, with and without a vault; the `open` outcomes; and
 * the unmodified Swift output with its random salt (`open/`). All 18 sealed cases and
 * both open-direction ones.
 */
class SwiftBackupVectorsTest {

    private val sealed = SwiftVectors.cases("V15-encrypted-backup")

    private val openDirection: List<SwiftVectors.Case> = run {
        val file = "V15-encrypted-backup.json"
        val stream = assertNotNull(javaClass.getResourceAsStream("/vectors/swift/open/$file"), "missing open/$file")
        val root = stream.bufferedReader(Charsets.UTF_8).use { Json.parseToJsonElement(it.readText()) }.jsonObject
        root.getValue("cases").jsonArray.map { SwiftVectors.Case("open/$file", it.jsonObject) }
    }

    private fun vectorSnippet(element: JsonElement): Snippet {
        val fields = element.jsonObject
        fun text(key: String) = fields.getValue(key).jsonPrimitive.content
        return Snippet(
            id = Uuids.parse(text("id"))!!,
            name = text("name"),
            keyword = text("keyword"),
            content = String(Bytes.fromHex(text("contentUtf8Hex"))!!, Charsets.UTF_8),
            tags = fields.getValue("tags").jsonArray.map { it.jsonPrimitive.content },
            isEnabled = fields.getValue("isEnabled").jsonPrimitive.boolean,
            isPinned = fields.getValue("isPinned").jsonPrimitive.boolean,
            createdAt = SwiftVectors.Case.double(fields.getValue("createdAt")),
            updatedAt = SwiftVectors.Case.double(fields.getValue("updatedAt")),
        )
    }

    private fun snippetBits(snippets: List<Snippet>) =
        snippets.flatMap { listOf(it.createdAt.toRawBits(), it.updatedAt.toRawBits()) }

    @Test fun theFilesHaveEveryCaseThisSuiteExpects() {
        assertEquals(18, sealed.size)
        assertEquals(mapOf("seal" to 2, "open" to 16), sealed.groupingBy { it.kind }.eachCount())
        assertEquals(listOf("with-vault-600000", "no-vault-low-iterations"), openDirection.map { it.name })
    }

    /**
     * With the vector's export key, backup id, salt and three nonces, `seal` writes the
     * bytes Swift writes: container, payload JSON (dates as numbers, ids uppercase, no
     * `vault` key without a vault) and every intermediate value.
     */
    @Test fun sealingWithFixedRandomnessReproducesSwiftsContainerByteForByte() {
        for (case in sealed.filter { it.kind == "seal" }) {
            val snippets = case.array("snippets").map(::vectorSnippet)
            val vault = case.element("vault").takeUnless { it is JsonNull }?.let(::vectorDocument)
            val vaultKey = case.stringOrNull("vaultKeyHex")?.let { Bytes.fromHex(it)!! }
            val exportKey = case.bytes("exportKeyHex")
            val backupId = case.string("backupID")

            val container = EncryptedBackup.seal(
                snippets = snippets,
                vault = vault,
                vaultKey = vaultKey,
                passphrase = case.text("passphrase").toCharArray(),
                iterations = case.string("iterations").toLong(),
                backupId = backupId,
                exportKey = exportKey,
                passphraseSalt = case.bytes("passphraseSaltHex"),
                keyNonce = fixedNonce(case.bytes("keyNonceHex")),
                vaultKeyNonce = fixedNonce(case.bytes("vaultKeyNonceHex")),
                payloadNonce = fixedNonce(case.bytes("payloadNonceHex")),
            )

            // The decrypted payload first: when the container differs, this says where.
            val wrappedKey = case.obj("wrappedKey")
            val wrapped = com.khm.snippets.core.crypto.PassphraseKdf.WrappedKey(
                wrappedKey.string("alg"), wrappedKey.string("iterations").toLong(), wrappedKey.string("salt"), wrappedKey.string("envelope"),
            )
            val aad = EncryptedBackup.payloadAad(backupId, 1, wrapped)
            assertEquals(case.string("payloadAADHex"), Bytes.toHex(aad), case.label)
            val ours = Json.parseToJsonElement(String(container, Charsets.UTF_8)).jsonObject
            val payload = SnippetCrypto.open(ours.getValue("payload").jsonPrimitive.content, exportKey, aad)
            assertEquals(case.string("payloadJSONText"), String(payload, Charsets.UTF_8), case.label)
            assertEquals(case.string("payloadJSONHex"), Bytes.toHex(payload), case.label)

            if (vault != null) {
                val salt = vault.vaultSaltBytes!!
                assertEquals(case.string("vaultWrapKeyHex"), Bytes.toHex(EncryptedBackup.vaultWrappingKey(exportKey, salt, backupId, vault.kid)), case.label)
                assertEquals(case.string("vaultKeyAADHex"), Bytes.toHex(EncryptedBackup.vaultKeyAad(backupId, vault.kid)), case.label)
                assertTrue(String(payload, Charsets.UTF_8).contains("\"wrappedVaultKey\" : \"${case.string("wrappedVaultKey")}\""), case.label)
            } else {
                assertTrue(!String(payload, Charsets.UTF_8).contains("vault"), "${case.label}: `vault` must be absent, not null")
            }

            assertEquals(case.string("payload"), ours.getValue("payload").jsonPrimitive.content, case.label)
            assertEquals(case.string("containerText"), String(container, Charsets.UTF_8), case.label)
            assertEquals(case.string("containerHex"), Bytes.toHex(container), case.label)
        }
    }

    /** Swift's containers, the deterministic ones and the unmodified output with a random salt, open to what went in. */
    @Test fun swiftsContainersOpenToTheLibraryThatWasSealed() {
        for (case in sealed.filter { it.kind == "seal" } + openDirection) {
            val opened = EncryptedBackup.open(case.bytes("containerHex"), case.text("passphrase").toCharArray())

            val snippets = case.array("snippets").map(::vectorSnippet)
            assertEquals(snippets, opened.snippets, case.label)
            assertEquals(snippetBits(snippets), snippetBits(opened.snippets), case.label)

            if (case.isNull("vault")) {
                assertNull(opened.vault, case.label)
                assertNull(opened.vaultKey(), case.label)
            } else {
                // Numbers in the payload: the vault's dates come back bit for bit, unlike through vault.json.
                val expected = vectorDocument(case.element("vault"))
                assertEquals(expected, opened.vault, case.label)
                assertEquals(timestampBits(expected), timestampBits(opened.vault!!), case.label)
                assertEquals(case.string("vaultKeyHex"), Bytes.toHex(opened.vaultKey()!!), case.label)
                // The device-local receipts travel inside this vector's vault; stripping them is the importer's job.
                assertEquals(expected.x.keys, opened.vault!!.x.keys, case.label)
            }
            assertEquals(snippets.size, opened.ordinaryCount, case.label)
            opened.close()
            assertNull(opened.vaultKey(), "${case.label}: closing must wipe the key")
        }
    }

    @Test fun openOutcomesMatchSwiftsTaxonomy() {
        for (case in sealed.filter { it.kind == "open" && it.has("containerText") && !it.has("payloadJSONText") }) {
            val data = case.string("containerText").toByteArray(Charsets.UTF_8)
            val passphrase = case.text("passphrase").toCharArray()
            if (case.has("ok")) {
                val opened = EncryptedBackup.open(data, passphrase)
                val ok = case.obj("ok")
                assertEquals(ok.int("ordinaryCount"), opened.ordinaryCount, case.label)
                assertEquals(ok.int("secureCount"), opened.secureCount, case.label)
                continue
            }
            val failure = try {
                EncryptedBackup.open(data, passphrase)
                fail("${case.label}: Swift refuses this container with ${case.string("error")}")
            } catch (failure: EncryptedBackup.Failure) {
                failure
            }
            val expected = when (val name = case.string("error").removePrefix("EncryptedSnippetBackup.Failure.")) {
                "emptyPassphrase" -> EncryptedBackup.Failure.EmptyPassphrase::class
                "invalidFormat" -> EncryptedBackup.Failure.InvalidFormat::class
                "unsupportedSchemaVersion" -> EncryptedBackup.Failure.UnsupportedSchemaVersion::class
                "wrongPassphrase" -> EncryptedBackup.Failure.WrongPassphrase::class
                "damagedBackup" -> EncryptedBackup.Failure.DamagedBackup::class
                "invalidPayload" -> EncryptedBackup.Failure.InvalidPayload::class
                else -> error("unknown Swift failure $name")
            }
            assertEquals(expected, failure::class, case.label)
        }
        // Every open case is one of the two shapes handled here and below.
        assertEquals(1, sealed.count { it.kind == "open" && it.has("payloadJSONText") })
    }

    /**
     * Hazard H2. A payload whose vault dates are ISO-8601 strings (what the Linux app
     * writes) opens in Swift with those dates silently turned into `Date.distantPast`.
     * Owner decision: this reader accepts both spellings and keeps the dates.
     */
    @Test fun isoVaultDatesInAPayloadAreReadNotLost() {
        val case = sealed.single { it.name == "h2-iso-vault-dates-as-read-by-swift" }
        val payloadText = case.string("payloadJSONText")
        assertTrue(payloadText.contains("\"createdAt\" : \"2026-07-29T08:00:00.500Z\""), "the vector's vault dates are ISO strings")

        // What Swift did with them.
        val swift = vectorDocument(case.obj("swiftOpened").element("vault"))
        assertTrue(swift.records.all { it.createdAt == VaultTimestamp.DISTANT_PAST && it.updatedAt == VaultTimestamp.DISTANT_PAST })

        val opened = EncryptedBackup.open(case.string("containerText").toByteArray(Charsets.UTF_8), case.text("passphrase").toCharArray())
        val records = assertNotNull(opened.vault).records
        val expected = case.array("expectedVaultRecordDates").map { it.jsonObject }
        assertEquals(expected.size, records.size)
        for ((record, dates) in records.zip(expected)) {
            // The strings carry milliseconds, so the dates are the originals to within one.
            assertTrue(Math.abs(record.createdAt - SwiftVectors.Case.double(dates.getValue("createdAt"))) < 0.001, case.label)
            assertTrue(Math.abs(record.updatedAt - SwiftVectors.Case.double(dates.getValue("updatedAt"))) < 0.001, case.label)
            assertTrue(record.createdAt != VaultTimestamp.DISTANT_PAST)
        }
        // Exactly: what Foundation's own ISO reader returns for those strings.
        assertEquals(VaultTimestamp.parse("2026-07-29T08:00:00.500Z"), records[0].createdAt)
        assertEquals(VaultTimestamp.parse("2026-10-01T20:20:00.123Z"), records[0].updatedAt)
        // Everything else is what Swift read.
        assertEquals(swift.records.map { it.sealed }, records.map { it.sealed })
        assertEquals(swift.records.map { it.hlc.string }, records.map { it.hlc.string })
        assertEquals(case.string("vaultKeyHex"), Bytes.toHex(opened.vaultKey()!!))

        // And a payload written here from that result uses numbers again, as Swift does.
        val rewritten = String(
            VaultDocumentCodec.encode(opened.vault!!, VaultDocumentCodec.Dates.BACKUP_PAYLOAD), Charsets.UTF_8,
        )
        assertTrue(rewritten.contains("\"createdAt\" : 807004800.5"))
    }

    @Test fun aWrongPasswordIsNeverAStructuralErrorAndAStructuralErrorIsNeverAWrongPassword() {
        val case = sealed.single { it.name == "open-ok" }
        val data = case.string("containerText").toByteArray(Charsets.UTF_8)
        assertFailsWith<EncryptedBackup.Failure.WrongPassphrase> { EncryptedBackup.open(data, "not the password".toCharArray()) }

        // A truncated file, at every length, with the right password.
        for (length in listOf(0, 1, data.size / 4, data.size / 2, data.size - 2, data.size - 1)) {
            val failure = assertFailsWith<EncryptedBackup.Failure>("truncated to $length") {
                EncryptedBackup.open(data.copyOf(length), case.text("passphrase").toCharArray())
            }
            assertTrue(failure is EncryptedBackup.Failure.InvalidFormat, "truncated to $length: ${failure::class.simpleName}")
        }
        assertContentEquals(data, data.copyOf(data.size))
    }
}
