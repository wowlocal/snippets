package com.khm.snippets.core.vault

import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.json.SwiftVectors
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Vector V14, emitted by the unmodified Swift sources (`tools/swift-interop`):
 * `VaultFile.encode` bytes, `VaultFile.decode` leniency, and the arithmetic of
 * Foundation's ISO-8601 formatter in both directions. All 86 cases.
 */
class SwiftVaultVectorsTest {

    private val cases = SwiftVectors.cases("V14-vault-document")

    @Test fun theFileHasEveryCaseThisSuiteExpects() {
        assertEquals(86, cases.size)
        assertEquals(
            mapOf("encode" to 3, "timestamp-format" to 27, "timestamp-parse" to 30, "decode" to 26),
            cases.groupingBy { it.kind }.eachCount(),
        )
    }

    /** `VaultFile.encode`: byte for byte what Foundation writes, passthrough keys, explicit nulls and all. */
    @Test fun encodedDocumentsAreByteIdenticalToSwift() {
        for (case in cases.filter { it.kind == "encode" }) {
            val document = vectorDocument(case.element("document"))
            val encoded = VaultFile.encode(document)
            assertEquals(case.string("fileText"), String(encoded, Charsets.UTF_8), case.label)
            assertEquals(case.string("fileHex"), com.khm.snippets.core.crypto.Bytes.toHex(encoded), case.label)
        }
    }

    /** What Swift holds after reading its own file back: the timestamps are not the ones that went in. */
    @Test fun decodingSwiftsFileYieldsTheDoublesSwiftReadsBack() {
        for (case in cases.filter { it.kind == "encode" }) {
            val decoded = VaultFile.decode(case.bytes("fileHex"))
            val expected = vectorDocument(case.element(if (case.has("decodedDocument")) "decodedDocument" else "document"))
            assertEquals(expected, decoded, case.label)
            assertEquals(timestampBits(expected), timestampBits(decoded), case.label)
            // A decode and encode cycle is a fixed point, or two builds would rewrite the file at each other.
            assertEquals(case.string("fileText"), String(VaultFile.encode(decoded), Charsets.UTF_8), case.label)
        }
    }

    /** The sealed bodies and the recovery wrap of the encode cases are real: they open with the vector's key. */
    @Test fun theVectorVaultOpensWithItsKeyAndItsRecoveryKey() {
        for (case in cases.filter { it.kind == "encode" && it.has("vaultKeyHex") }) {
            val document = VaultFile.decode(case.bytes("fileHex"))
            val key = case.bytes("vaultKeyHex")
            val salt = assertNotNull(document.vaultSaltBytes, case.label)
            val keyring = SnippetCrypto.Keyring(key, salt)
            for (record in document.records) {
                val body = SnippetCrypto.open(record.sealed, SnippetCrypto.RecordContext(document.kid, record.id), keyring)
                assertEquals(record.contentHash, SnippetCrypto.contentHash(body, keyring), case.label)
            }
            val recovered = KeyWrap.unwrap(
                assertNotNull(document.wrapRecovery), case.bytes("recoverySecretHex"), KeyWrap.Purpose.RECOVERY, document.kid, salt,
            )
            assertEquals(case.string("vaultKeyHex"), com.khm.snippets.core.crypto.Bytes.toHex(recovered), case.label)
        }
    }

    @Test fun decodeLeniencyAndRefusalsMatchSwift() {
        for (case in cases.filter { it.kind == "decode" }) {
            val bytes = case.string("fileText").toByteArray(Charsets.UTF_8)

            val probe = case.element("probeSchemaVersion")
            assertEquals(if (probe is JsonNull) null else probe.jsonPrimitive.long, VaultFile.probeSchemaVersion(bytes), case.label)

            if (case.has("error")) {
                val failure = assertFailsWith<VaultDecodeException>(case.label) { VaultFile.decode(bytes) }
                assertEquals(swiftErrorKind(case.string("error")), failure.kind, case.label)
                continue
            }
            val decoded = VaultFile.decode(bytes)
            val expected = vectorDocument(case.element("document"))
            assertEquals(expected, decoded, case.label)
            assertEquals(timestampBits(expected), timestampBits(decoded), case.label)
            assertEquals(expected.records.map { it.hlc.string }, decoded.records.map { it.hlc.string }, case.label)
            assertEquals(case.string("reencodedText"), String(VaultFile.encode(decoded), Charsets.UTF_8), case.label)
        }
    }

    @Test fun timestampsAreWrittenWithFoundationsMillisecondArithmetic() {
        for (case in cases.filter { it.kind == "timestamp-format" }) {
            val date = case.double("date")
            assertEquals(case.string("epochMilliseconds").toLong(), VaultTimestamp.epochMillis(date), case.label)
            assertEquals(case.string("text"), VaultTimestamp.string(date), case.label)
            val back = assertNotNull(VaultTimestamp.parse(case.string("text")), case.label)
            assertEquals(case.double("parsedBack").toRawBits(), back.toRawBits(), case.label)
        }
    }

    @Test fun timestampsAreReadWithFoundationsArithmeticAndLeniency() {
        for (case in cases.filter { it.kind == "timestamp-parse" }) {
            val parsed = VaultTimestamp.parse(case.string("text"))
            if (case.isNull("date")) {
                assertNull(parsed, "${case.label}: ${case.string("text")}")
            } else {
                assertNotNull(parsed, "${case.label}: ${case.string("text")}")
                assertEquals(case.double("date").toRawBits(), parsed.toRawBits(), "${case.label}: ${case.string("text")}")
            }
        }
    }

    /** The metadata-only reader agrees with the full one on every file the full one accepts. */
    @Test fun metadataOnlyDecodeAgreesWithTheFullDecode() {
        for (case in cases.filter { it.kind == "decode" && !it.has("error") }) {
            val bytes = case.string("fileText").toByteArray(Charsets.UTF_8)
            val metadata = VaultDocumentCodec.decodeMetadata(bytes)
            val document = VaultFile.decode(bytes)
            assertEquals(document.schemaVersion, metadata.schemaVersion, case.label)
            assertEquals(document.shells, metadata.shells, case.label)
            assertTrue(metadata.shells.all { it.content.isEmpty() }, case.label)
        }
    }

    private fun swiftErrorKind(name: String): VaultDecodeException.Kind = when (name) {
        "Swift.DecodingError.keyNotFound" -> VaultDecodeException.Kind.KEY_NOT_FOUND
        "Swift.DecodingError.valueNotFound" -> VaultDecodeException.Kind.VALUE_NOT_FOUND
        "Swift.DecodingError.typeMismatch" -> VaultDecodeException.Kind.TYPE_MISMATCH
        "Swift.DecodingError.dataCorrupted" -> VaultDecodeException.Kind.DATA_CORRUPTED
        else -> error("unknown Swift error $name")
    }
}
