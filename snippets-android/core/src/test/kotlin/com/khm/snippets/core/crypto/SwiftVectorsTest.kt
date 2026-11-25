package com.khm.snippets.core.crypto

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import java.util.UUID
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Swift-emitted golden vectors V01 to V09 (`tools/swift-interop`, written by the
 * unmodified Swift sources). Every case of every file is run; where a vector carries its
 * nonce it is checked in both directions: sealing with that nonce must give the recorded
 * text, and the recorded text must open.
 */
class SwiftVectorsTest {

    private fun keyring(case: JsonObject) =
        SnippetCrypto.Keyring(unhex(case.string("rootKeyHex")), unhex(case.string("saltHex")))

    private fun recordId(case: JsonObject): UUID =
        Uuids.parseLowercase(case.string("recordID")) ?: error("${case.string("name")}: not a lowercase id")

    // V01

    /** `SnippetCrypto.additionalData(for:)` and `SnippetCrypto.domainSeparated`. */
    @Test fun v01RecordAAD() {
        var contexts = 0
        var lists = 0
        for (case in SwiftVectors.sealed("V01-record-aad")) {
            val name = case.string("name")
            if ("aadHex" in case) {
                val context = SnippetCrypto.RecordContext(
                    scopeId = case.exactText("scopeID"),
                    recordId = recordId(case),
                    isDeleted = case.string("isDeleted").toBooleanStrict(),
                )
                assertEquals(case.string("aadHex"), SnippetCrypto.additionalData(context).hex(), name)
                contexts += 1
            } else {
                val fields = case.array("fieldsHex").map { unhex(it.jsonPrimitive.content) }
                assertEquals(case.string("outputHex"), DomainSeparated.encode(case.string("domain"), fields).hex(), name)
                assertEquals(case.string("outputHex"), SnippetCrypto.domainSeparated(case.string("domain"), fields).hex(), name)
                lists += 1
            }
        }
        assertEquals(7 to 5, contexts to lists)
    }

    // V02

    /** `Keyring.recordKey(for:)` and `Keyring.contentHashKey`, with the HKDF info they are derived under. */
    @Test fun v02RecordKeys() {
        for (case in SwiftVectors.sealed("V02-record-keys")) {
            val name = case.string("name")
            val ring = keyring(case)
            val info = unhex(case.string("hkdfInfoHex"))
            when (case.string("kind")) {
                "recordKey" -> {
                    val id = recordId(case)
                    assertEquals(case.string("uuid16Hex"), Uuids.toBytes(id).hex(), name)
                    assertEquals(case.string("keyHex"), ring.recordKey(id).hex(), name)
                    assertEquals(utf8("snip.wire.v1|").hex() + case.string("uuid16Hex"), info.hex(), name)
                }
                "contentHashKey" -> {
                    assertEquals(case.string("keyHex"), ring.contentHashKey().hex(), name)
                    assertEquals(utf8("snip.chash.v1").hex(), info.hex(), name)
                }
                else -> error("$name: unknown kind")
            }
            // The key is nothing but HKDF over the recorded info.
            assertEquals(
                case.string("keyHex"),
                Hkdf.deriveKey(unhex(case.string("rootKeyHex")), unhex(case.string("saltHex")), info, 32).hex(),
                name,
            )
        }
    }

    // V03

    /** `SnippetCrypto.seal(_:for:keyring:nonces:)` text at the padding boundaries, both directions, and `open` outcomes. */
    @Test fun v03RecordSeal() {
        var sealedCases = 0
        var openCases = 0
        for (case in SwiftVectors.sealed("V03-record-seal")) {
            val name = case.string("name")
            val ring = keyring(case)
            val context = SnippetCrypto.RecordContext(
                scopeId = case.string("scopeID"),
                recordId = recordId(case),
                isDeleted = case.string("isDeleted").toBooleanStrict(),
            )
            val sealed = case.string("sealed")
            if ("nonceHex" in case) {
                val plaintext = unhex(case.string("plaintextHex"))
                assertEquals(case.string("plaintextByteCount").toInt(), plaintext.size, name)

                // Seal direction: the injected nonce must reproduce the whole envelope text.
                val text = SnippetCrypto.seal(plaintext, context, ring, fixedNonce(unhex(case.string("nonceHex"))))
                assertEquals(sealed, text, name)
                assertEquals(case.string("sealedCharacterCount").toInt(), text.length, name)
                val parsed = SealedEnvelope.parse(text)
                assertEquals(case.string("nonceHex"), parsed.nonce.hex(), name)
                assertEquals(case.string("ciphertextAndTagHex"), parsed.sealed.hex(), name)

                // Open direction.
                assertContentEquals(plaintext, SnippetCrypto.open(sealed, context, ring), name)
                sealedCases += 1
            } else {
                val actual = SwiftVectors.outcome { SnippetCrypto.open(sealed, context, ring).hex() }
                assertEquals(SwiftVectors.expectedOutcome(case), actual, name)
                openCases += 1
            }
        }
        assertEquals(13 to 16, sealedCases to openCases)
    }

    // V04

    /** `Padding.pad` and `Padding.unpad` at the block boundaries, and every refusal. */
    @Test fun v04Padding() {
        for (case in SwiftVectors.sealed("V04-padding")) {
            val name = case.string("name")
            when (case.string("kind")) {
                "pad" -> {
                    val input = unhex(case.string("inputHex"))
                    assertEquals(case.string("inputByteCount").toInt(), input.size, name)
                    val padded = Padding.pad(input)
                    assertEquals(case.string("paddedByteCount").toInt(), padded.size, name)
                    assertEquals(case.string("paddedHex"), padded.hex(), name)
                    // And back.
                    assertContentEquals(input, Padding.unpad(unhex(case.string("paddedHex"))), name)
                }
                "unpad" -> {
                    val actual = SwiftVectors.outcome { Padding.unpad(unhex(case.string("paddedHex"))).hex() }
                    assertEquals(SwiftVectors.expectedOutcome(case), actual, name)
                }
                else -> error("$name: unknown kind")
            }
        }
    }

    // V05

    /** `SnippetCrypto.contentHash(of:keyring:)`. */
    @Test fun v05ContentHash() {
        for (case in SwiftVectors.sealed("V05-content-hash")) {
            val name = case.string("name")
            val ring = keyring(case)
            val plaintext = unhex(case.string("plaintextHex"))
            assertEquals(case.string("contentHashKeyHex"), ring.contentHashKey().hex(), name)
            assertEquals(case.string("contentHash"), SnippetCrypto.contentHash(plaintext, ring), name)
            assertEquals(case.string("contentHash"), SnippetCrypto.contentHash(plaintext, unhex(case.string("contentHashKeyHex"))), name)
        }
    }

    // V06

    /**
     * `PassphraseKDF.derive`: ASCII, `Café` in both normal forms, astral characters, the
     * Ångström sign, Hangul jamo, a ligature; 1, 2, 4096 and 600 000 rounds; refusals. Each
     * derivation runs through both PBKDF2 implementations, and the bytes handed to PBKDF2
     * are compared with the ones Swift recorded.
     */
    @Test fun v06Pbkdf2() {
        var derived = 0
        var refused = 0
        for (case in SwiftVectors.sealed("V06-pbkdf2")) {
            val name = case.string("name")
            val passphrase = case.exactText("passphrase")
            val salt = unhex(case.string("saltHex"))
            val iterations = case.long("iterations")
            if ("derivedKeyHex" in case) {
                val recording = RecordingPbkdf2()
                PassphraseKdf.derive(passphrase, salt, 1, recording)
                assertEquals(case.string("passwordBytesHex"), recording.passwordHex, "$name: bytes fed to PBKDF2")

                for ((label, pbkdf2) in listOf("Mac" to MacPbkdf2HmacSha512, "JCA" to JcaPbkdf2HmacSha512)) {
                    assertEquals(
                        case.string("derivedKeyHex"),
                        PassphraseKdf.derive(passphrase, salt, iterations, pbkdf2).hex(),
                        "$name ($label)",
                    )
                }
                if (iterations < 600_000) {
                    assertEquals(case.string("derivedKeyHex"), PassphraseKdf.derive(passphrase.toCharArray(), salt, iterations).hex(), name)
                }
                derived += 1
            } else {
                val actual = SwiftVectors.outcome { PassphraseKdf.derive(passphrase, salt, iterations).hex() }
                assertEquals(SwiftVectors.expectedOutcome(case), actual, name)
                refused += 1
            }
        }
        assertEquals(30 to 5, derived to refused)
    }

    private class RecordingPbkdf2 : Pbkdf2HmacSha512 {
        var passwordHex = ""
        override fun derive(password: ByteArray, salt: ByteArray, iterations: Int, derivedKeyByteCount: Int): ByteArray {
            passwordHex = password.hex()
            return ByteArray(derivedKeyByteCount)
        }
    }

    // V07

    private fun wrappedKey(case: JsonObject): PassphraseKdf.WrappedKey {
        val record = case.obj("wrappedKey")
        assertEquals(setOf("alg", "iterations", "salt", "envelope"), record.keys)
        return PassphraseKdf.WrappedKey(
            alg = record.string("alg"),
            iterations = record.long("iterations"),
            salt = record.string("salt"),
            envelope = record.string("envelope"),
        )
    }

    /** `PassphraseKDF.wrap` with a fixed nonce (the whole `WrappedKey`), its AAD and key, and `unwrap` outcomes. */
    @Test fun v07PassphraseWrap() {
        var wraps = 0
        var unwraps = 0
        for (case in SwiftVectors.sealed("V07-passphrase-wrap")) {
            val name = case.string("name")
            val passphrase = case.exactText("passphrase")
            val kid = case.string("kid")
            val expected = wrappedKey(case)
            if ("nonceHex" in case) {
                val key = unhex(case.string("keyHex"))
                val salt = unhex(case.string("saltHex"))
                val iterations = case.long("iterations")

                assertEquals(case.string("wrappingKeyHex"), PassphraseKdf.derive(passphrase, salt, iterations).hex(), name)
                assertEquals(
                    case.string("aadHex"),
                    PassphraseKdf.additionalData(PassphraseKdf.ALGORITHM, iterations, salt, kid).hex(),
                    name,
                )
                // Seal direction.
                val wrapped = PassphraseKdf.wrap(key, passphrase, salt, kid, iterations, fixedNonce(unhex(case.string("nonceHex"))))
                assertEquals(expected, wrapped, name)
                // Open direction.
                assertContentEquals(key, PassphraseKdf.unwrap(expected, passphrase, kid), name)
                wraps += 1
            } else {
                val actual = SwiftVectors.outcome { PassphraseKdf.unwrap(expected, passphrase, kid).hex() }
                assertEquals(SwiftVectors.expectedOutcome(case), actual, name)
                unwraps += 1
            }
        }
        assertEquals(4 to 12, wraps to unwraps)
    }

    // V08

    private fun purpose(case: JsonObject): KeyWrap.Purpose =
        KeyWrap.Purpose.values().single { it.rawValue == case.string("purpose") }

    /** `KeyWrap.wrap` for `recovery` and `cli` with fixed nonces, the wrapping key and AAD, and `unwrap` outcomes. */
    @Test fun v08KeyWrap() {
        var wraps = 0
        var unwraps = 0
        val purposes = HashSet<KeyWrap.Purpose>()
        for (case in SwiftVectors.sealed("V08-key-wrap")) {
            val name = case.string("name")
            val material = unhex(case.string("materialHex"))
            val salt = unhex(case.string("saltHex"))
            val kid = case.string("kid")
            val purpose = purpose(case)
            val wrapped = case.string("wrapped")
            if ("nonceHex" in case) {
                val libraryKey = unhex(case.string("libraryKeyHex"))
                assertEquals(case.string("wrappingKeyHex"), KeyWrap.wrappingKey(material, purpose, salt).hex(), name)
                assertEquals(case.string("aadHex"), KeyWrap.additionalData(purpose, kid).hex(), name)
                // Seal direction.
                assertEquals(
                    wrapped,
                    KeyWrap.wrap(libraryKey, material, purpose, kid, salt, fixedNonce(unhex(case.string("nonceHex")))),
                    name,
                )
                // Open direction.
                assertContentEquals(libraryKey, KeyWrap.unwrap(wrapped, material, purpose, kid, salt), name)
                purposes.add(purpose)
                wraps += 1
            } else {
                val actual = SwiftVectors.outcome { KeyWrap.unwrap(wrapped, material, purpose, kid, salt).hex() }
                assertEquals(SwiftVectors.expectedOutcome(case), actual, name)
                unwraps += 1
            }
        }
        assertEquals(4 to 12, wraps to unwraps)
        assertEquals(setOf(KeyWrap.Purpose.RECOVERY, KeyWrap.Purpose.CLI), purposes)
    }

    // V09

    /**
     * `RecoveryKey.encode`, `formatted`, `normalized` and `decode`, with all five failures.
     * Includes the two things Swift does that a reader of the code may not expect: a
     * Windows line break is one `Character` and is not stripped, so such a code fails as
     * `wrongLength`; and `ß` upper-cases to two letters.
     */
    @Test fun v09RecoveryKey() {
        var encodes = 0
        var decodes = 0
        for (case in SwiftVectors.sealed("V09-recovery-key")) {
            val name = case.string("name")
            when (case.string("kind")) {
                "encode" -> {
                    val bytes = unhex(case.string("bytesHex"))
                    if ("error" in case) {
                        assertEquals(SwiftVectors.expectedOutcome(case), SwiftVectors.outcome { RecoveryKey.encode(bytes) }, name)
                        assertEquals(SwiftVectors.expectedOutcome(case), SwiftVectors.outcome { RecoveryKey.formatted(bytes) }, name)
                    } else {
                        assertEquals(case.string("canonical"), RecoveryKey.encode(bytes), name)
                        assertEquals(case.string("display"), RecoveryKey.formatted(bytes), name)
                        assertEquals(case.string("display"), RecoveryKey.grouped(case.string("canonical")), name)
                        val symbols = RecoveryKey.symbolsFromBytes(bytes)
                        assertEquals(case.array("symbols").map { it.jsonPrimitive.content.toInt() }, symbols.toList(), name)
                        assertEquals(case.string("checkSymbol").toInt(), RecoveryKey.checkSymbol(symbols), name)
                        // And back, from both printed forms.
                        assertContentEquals(bytes, RecoveryKey.decode(case.string("canonical")), name)
                        assertContentEquals(bytes, RecoveryKey.decode(case.string("display")), name)
                        assertContentEquals(bytes, RecoveryKey.bytesFromSymbols(symbols), name)
                    }
                    encodes += 1
                }
                "decode" -> {
                    val input = case.exactText("input")
                    assertEquals(case.string("normalized"), RecoveryKey.normalized(input), "$name: normalized")
                    assertEquals(SwiftVectors.expectedOutcome(case), SwiftVectors.outcome { RecoveryKey.decode(input).hex() }, name)
                    decodes += 1
                }
                else -> error("$name: unknown kind")
            }
        }
        assertEquals(12 to 35, encodes to decodes)
    }

    /** The CRLF cases by name, with the length Swift counts: each `\r\n` is one character that stays. */
    @Test fun v09ACodePastedWithWindowsLineEndingsFailsAsWrongLength() {
        val cases = SwiftVectors.sealed("V09-recovery-key").associateBy { it.string("name") }

        val trailing = cases.getValue("decode-trailing-crlf-is-one-character")
        assertEquals("M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ\r\n", trailing.exactText("input"))
        assertEquals("RecoveryKey.Failure.wrongLength", trailing.string("error"))
        assertEquals("M2GT58X4MPKAFA59NANTSBDENWJ\r\n", RecoveryKey.normalized(trailing.exactText("input")))
        assertEquals(28, kotlin.test.assertFailsWith<RecoveryKey.Failure.WrongLength> {
            RecoveryKey.decode(trailing.exactText("input"))
        }.count)

        val separators = cases.getValue("decode-crlf-separators")
        assertEquals("RecoveryKey.Failure.wrongLength", separators.string("error"))
        assertEquals(33, kotlin.test.assertFailsWith<RecoveryKey.Failure.WrongLength> {
            RecoveryKey.decode(separators.exactText("input"))
        }.count)

        // The same code with lone CR or lone LF decodes.
        assertTrue("ok" in cases.getValue("decode-carriage-returns"))
        assertTrue("ok" in cases.getValue("decode-tabs-and-line-feeds"))
    }
}
