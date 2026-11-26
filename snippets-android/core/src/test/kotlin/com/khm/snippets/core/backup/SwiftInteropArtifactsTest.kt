package com.khm.snippets.core.backup

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.crypto.counting
import com.khm.snippets.core.crypto.filled
import com.khm.snippets.core.crypto.sha256Hex
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.vault.Components
import com.khm.snippets.core.vault.VaultDocument
import com.khm.snippets.core.vault.VaultFile
import com.khm.snippets.core.vault.VaultKdfParameters
import com.khm.snippets.core.vault.at
import com.khm.snippets.core.vault.id
import com.khm.snippets.core.vault.secureRecord
import com.khm.snippets.core.vault.snippet
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Test
import java.io.File
import java.nio.file.Files
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.assertTrue

/**
 * Writes files with the Kotlin implementation for the Swift implementation to judge:
 * `vault.json` files and encrypted backups, with and without a vault. They land in
 * `core/build/interop/vault-backup/` together with `expected.json`, which lists each
 * file, the `swift-interop check` arguments for it and the values Swift must report.
 *
 * `tools/swift-interop/checks/vault-backup.sh` runs this class and then the Swift tool.
 * On its own this test only proves the files can be written; the script is the check.
 * Every key, code and password here is fictional public test data.
 */
class SwiftInteropArtifactsTest {

    private val out = File("build/interop/vault-backup")

    /** The interop tool's default password, so the backups open without an option; and its decomposed spelling. */
    private val password = "Café public backup fixture"
    private val decomposedPassword = "Café public backup fixture"

    private val fixtureKey = filled(0x11, 32)
    private val fixtureSalt = filled(0x22, 32)
    private val fixtureKid = "k-7f3a91c0-1b2"

    /** `M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ` */
    private val recoverySecret = counting(0xa0, 16)
    private val recoveryCode = "M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ"

    private val expectations = ArrayList<JsonElement>()

    private fun write(name: String, bytes: ByteArray) {
        Files.createDirectories(out.toPath())
        Files.write(File(out, name).toPath(), bytes)
    }

    private fun expect(kind: String, file: String, arguments: List<String>, vararg values: Pair<String, JsonElement>) {
        expectations.add(
            JsonObject(
                mapOf(
                    "kind" to JsonPrimitive(kind),
                    "file" to JsonPrimitive(file),
                    "arguments" to JsonArray(arguments.map { JsonPrimitive(it) }),
                    "expect" to JsonObject(mapOf(*values)),
                ),
            ),
        )
    }

    private fun strings(values: List<String>) = JsonArray(values.map { JsonPrimitive(it) })

    /** The tool's `librarySummary`: canonical JSON of the nine fields, ids lowercase, dates as doubles. */
    private fun librarySummarySha256(snippets: List<Snippet>): String = sha256Hex(
        CanonicalJson.encode(
            JsonValue.Array(
                snippets.map { snippet ->
                    JsonValue.Object(
                        mapOf(
                            "id" to JsonValue.Text(Uuids.lowercase(snippet.id)),
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
                },
            ),
        ),
    )

    private fun fixtureVault(): VaultDocument {
        val keyring = SnippetCrypto.Keyring(fixtureKey, fixtureSalt)
        return VaultDocument(
            kid = fixtureKid,
            vaultSalt = Base64Url.encode(fixtureSalt),
            kdf = VaultKdfParameters(
                PassphraseKdf.ALGORITHM, PassphraseKdf.ITERATIONS, Base64Url.encode(filled(0x55, 16)),
                x = mapOf("futureKdf" to JsonValue.of(7L)),
            ),
            wrapRecovery = KeyWrap.wrap(fixtureKey, recoverySecret, KeyWrap.Purpose.RECOVERY, fixtureKid, fixtureSalt),
            x = mapOf(
                "futureTop" to JsonValue.obj(
                    "d" to JsonValue.of(12.5), "f" to JsonValue.of(false), "i" to JsonValue.of(600000L),
                    "n" to JsonValue.Null, "s" to JsonValue.of("1"), "slash" to JsonValue.of("a/b"), "ü" to JsonValue.of("☕"),
                ),
            ),
            records = listOf(
                secureRecord(fixtureKid, keyring, id(1), "Fictional secret ☕\n", 0, name = "Wi-Fi \"password\"", keyword = "wifi")
                    .copy(
                        updatedAt = 812578800.123,
                        x = mapOf("futureRecord" to JsonValue.array(JsonValue.of(1L), JsonValue.of("two"), JsonValue.Null)),
                    ),
                secureRecord(fixtureKid, keyring, id(2), "", 1, name = "", keyword = "empty-body"),
            ),
        )
    }

    @Test fun writeArtifactsForTheSwiftReaders() = runTest {
        out.deleteRecursively()
        val keyArguments = listOf("--key", Bytes.toHex(fixtureKey), "--code", recoveryCode)

        // 1. A vault file with passthrough keys at all three levels, written by `VaultFile`.
        val fixture = fixtureVault()
        write("vault-passthrough.json", VaultFile.encode(fixture))
        expect(
            "vault-document", "vault-passthrough.json", keyArguments,
            "schemaVersion" to JsonPrimitive(1),
            "kid" to JsonPrimitive(fixtureKid),
            "recordCount" to JsonPrimitive(2),
            "hasWrapRecovery" to JsonPrimitive(true),
            "hasWrapPass" to JsonPrimitive(false),
            "unknownTopLevelKeys" to strings(listOf("futureTop")),
            "vaultSaltByteCount" to JsonPrimitive(32),
            // Not required of Kotlin, but true: the encoder writes Foundation's bytes.
            "reencodesByteExact" to JsonPrimitive(true),
            "roundTripsByValue" to JsonPrimitive(true),
            "recordsWithDistantPastDates" to JsonPrimitive(0),
            "recordsWithForeignHLC" to JsonPrimitive(0),
            "recordsOpened" to JsonPrimitive(2),
            "contentHashMismatches" to JsonPrimitive(0),
            "recoveredVaultKeySHA256" to JsonPrimitive(sha256Hex(fixtureKey)),
        )

        // 2. A vault without records, every wrap an explicit null.
        write("vault-empty.json", VaultFile.encode(fixture.copy(wrapRecovery = null, x = emptyMap(), records = emptyList())))
        expect(
            "vault-document", "vault-empty.json", emptyList(),
            "recordCount" to JsonPrimitive(0),
            "hasWrapRecovery" to JsonPrimitive(false),
            "hasWrapPass" to JsonPrimitive(false),
            "unknownTopLevelKeys" to strings(emptyList()),
            "reencodesByteExact" to JsonPrimitive(true),
            "roundTripsByValue" to JsonPrimitive(true),
        )

        // 3. A vault and a library as the real store leaves them: created, filled, promoted, edited.
        val c = Components("interop")
        try {
            val code = c.createVault()
            c.writeLibrary(snippet(1, name = "Email signature", keyword = "sig", content = "Best regards,\nMichael ☕\n"), snippet(2), snippet(3, content = "to be promoted"))
            c.session.unlock(c.reveal).fill(0)
            val added = c.store.addSecure("AWS root", "awsroot", "hunter2".toByteArray(), listOf("Work", "prod"), true, true)
            c.store.addSecure("Unicode ünïcode", "uni", "päss wörd 🔐".toByteArray(), emptyList(), false, false)
            c.now = at(2000.123)
            c.store.promote(id(3))
            c.store.setContent("correct horse battery staple", added)
            c.store.updateMetadata(added, name = "AWS root password")
            c.session.lock()

            val document = c.store.document!!
            val key = c.keys.inner.load(document.kid)
            write("vault-store.json", Files.readAllBytes(c.scratch.vault.toPath()))
            write("library-store.json", Files.readAllBytes(c.scratch.library.toPath()))
            expect(
                "vault-document", "vault-store.json", listOf("--key", Bytes.toHex(key), "--code", code),
                "kid" to JsonPrimitive(document.kid),
                "recordCount" to JsonPrimitive(3),
                "hasWrapRecovery" to JsonPrimitive(true),
                "vaultSaltByteCount" to JsonPrimitive(32),
                "reencodesByteExact" to JsonPrimitive(true),
                "roundTripsByValue" to JsonPrimitive(true),
                "recordsWithDistantPastDates" to JsonPrimitive(0),
                "recordsWithForeignHLC" to JsonPrimitive(0),
                "recordsOpened" to JsonPrimitive(3),
                "contentHashMismatches" to JsonPrimitive(0),
                "recoveredVaultKeySHA256" to JsonPrimitive(sha256Hex(key)),
            )
            expect(
                "library-json", "library-store.json", emptyList(),
                "count" to JsonPrimitive(2),
                "duplicateIDs" to JsonPrimitive(0),
                "reencodesByteExact" to JsonPrimitive(true),
                "summarySHA256" to JsonPrimitive(librarySummarySha256(c.library())),
            )

            // 4. A backup of both halves, through the service, at the shipping 600 000 rounds.
            val host = object : OrdinaryLibraryHost {
                override val isLibraryQuarantined = false
                override fun flushPendingWrites() = Unit
                override fun reloadAfterExternalWrite() = Unit
            }
            val service = EncryptedBackupService(c.store, host, EmptyCoroutineContext, EmptyCoroutineContext)
            val export = service.makeEncryptedBackup(password.toCharArray())
            write("backup-with-vault.snippetsbackup", export.data)
            val backupExpectation = arrayOf<Pair<String, JsonElement>>(
                "ordinaryCount" to JsonPrimitive(2),
                "secureCount" to JsonPrimitive(3),
                "ordinaryIDs" to strings(c.library().map { Uuids.lowercase(it.id) }),
                "secureIDs" to strings(document.records.map { Uuids.lowercase(it.id) }),
                "vaultKID" to JsonPrimitive(document.kid),
                "vaultKeySHA256" to JsonPrimitive(sha256Hex(key)),
                "librarySummarySHA256" to JsonPrimitive(librarySummarySha256(c.library())),
                // Hazard H2: the vault's dates are written as numbers, so Swift keeps them.
                "vaultRecordsWithDistantPastDates" to JsonPrimitive(0),
            )
            expect("backup", "backup-with-vault.snippetsbackup", emptyList(), *backupExpectation)
            // The same file with a wrong password: refused as a wrong password, not as damage.
            expect(
                "backup", "backup-with-vault.snippetsbackup", listOf("--password", "not the password"),
                "ok" to JsonPrimitive(false), "error" to JsonPrimitive("EncryptedSnippetBackup.Failure.wrongPassphrase"),
            )

            // 5. A backup with a vault that carries unknown keys at every level.
            val passthrough = EncryptedBackup.seal(listOf(snippet(9)), fixture, fixtureKey, password.toCharArray(), 2)
            write("backup-passthrough-vault.snippetsbackup", passthrough)
            expect(
                "backup", "backup-passthrough-vault.snippetsbackup", emptyList(),
                "ordinaryCount" to JsonPrimitive(1),
                "secureCount" to JsonPrimitive(2),
                "secureIDs" to strings(fixture.records.map { Uuids.lowercase(it.id) }),
                "vaultKID" to JsonPrimitive(fixtureKid),
                "vaultKeySHA256" to JsonPrimitive(sha256Hex(fixtureKey)),
                "vaultRecordsWithDistantPastDates" to JsonPrimitive(0),
            )
        } finally {
            c.destroy()
        }

        // 6. An ordinary-only backup, sealed with the decomposed spelling of the password and opened with the composed one.
        val ordinary = listOf(
            snippet(1, name = "Email signature", keyword = "sig", content = "Best regards,\nMichael ☕\n"),
            Snippet(id(2), "", "", "", emptyList(), false, true, 123.25, 456.5),
            Snippet(id(3), "Edge \"quotes\" / slashes \\", "edge", "tab\there\u0001", listOf("Ünïcode ☕"), true, false, -0.0, 812578800.123456),
        )
        write("backup-no-vault.snippetsbackup", EncryptedBackup.seal(ordinary, null, null, decomposedPassword.toCharArray(), 2))
        expect(
            "backup", "backup-no-vault.snippetsbackup", emptyList(),
            "ordinaryCount" to JsonPrimitive(3),
            "secureCount" to JsonPrimitive(0),
            "ordinaryIDs" to strings(ordinary.map { Uuids.lowercase(it.id) }),
            "secureIDs" to strings(emptyList()),
            "vaultKID" to JsonNull,
            "vaultKeySHA256" to JsonNull,
            "librarySummarySHA256" to JsonPrimitive(librarySummarySha256(ordinary)),
            "vaultRecordsWithDistantPastDates" to JsonPrimitive(0),
        )

        write("expected.json", JsonArray(expectations).toString().toByteArray())
        assertTrue(File(out, "expected.json").length() > 0)
        assertTrue(password != decomposedPassword)
    }
}
