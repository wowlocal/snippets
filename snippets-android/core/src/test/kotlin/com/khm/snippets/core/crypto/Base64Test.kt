package com.khm.snippets.core.crypto

import kotlinx.serialization.json.jsonObject
import org.junit.Test
import java.util.Base64
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** `CryptoTests.swift`, suite 10 "base64url", plus the padded standard dialect of the Git key files. */
class Base64Test {

    // CryptoTests.Base64URL

    /** The envelope is compared for equality by the merge, so it must have exactly one spelling. */
    @Test fun encodingIsURLSafeAndUnpadded() {
        val random = SeededRandom(0xB64B_64B6)
        for (length in 0 until 40) {
            val text = Base64Url.encode(random.bytes(length))
            assertFalse(text.contains("="))
            assertFalse(text.contains("+"))
            assertFalse(text.contains("/"))
        }
    }

    @Test fun decodingInvertsEncodingAtEveryLength() {
        val random = SeededRandom(0x4B64_B64B)
        for (length in 1 until 200) {
            val data = random.bytes(length)
            assertContentEquals(data, Base64Url.decode(Base64Url.encode(data)))
        }
    }

    @Test fun anythingOutsideTheCanonicalAlphabetIsRefused() {
        for (text in listOf("", "a", "ab=", "a+b", "a/b", "abc=", "!!!!", "AAAAA ")) {
            assertNull(Base64Url.decode(text), "\"$text\"")
        }
    }

    // Added

    @Test fun urlEncodingAgreesWithThePlatformEncoderAtEveryLength() {
        val random = SeededRandom(0xB64)
        val platform = Base64.getUrlEncoder().withoutPadding()
        for (length in 0 until 300) {
            val data = random.bytes(length)
            assertEquals(platform.encodeToString(data), Base64Url.encode(data))
        }
        // The two symbols that differ from the standard alphabet.
        assertEquals("-_-_", Base64Url.encode(unhex("fbffbf")))
    }

    /** Every outcome below was produced by `SnippetCrypto.data(fromBase64URL:)` itself. */
    @Test fun decodingMatchesSwiftOnEveryReferenceInput() {
        for (case in SwiftReference.json.array("b64url")) {
            val text = case.string("text")
            val decoded = Base64Url.decode(text)
            val actual = decoded?.let { "ok:" + it.hex() } ?: "nil"
            assertEquals(case.string("result"), actual, "\"$text\"")
        }
    }

    /**
     * Where Swift is lenient, on purpose or not, and this follows it: the unused low bits of
     * the last symbol are not checked, so `Zh` and `Zg` are the same byte. (The Rust reader
     * refuses `Zh`; see `crypto.rs`, `noncanonical_encodings_…`.) Everything else in that
     * Rust list is refused here too.
     */
    @Test fun nonZeroTrailingBitsAreAcceptedAsInSwift() {
        assertEquals("66", Base64Url.decode("Zg")!!.hex())
        assertEquals("66", Base64Url.decode("Zh")!!.hex())
        assertEquals("666f", Base64Url.decode("Zm8")!!.hex())
        assertEquals("666f", Base64Url.decode("Zm9")!!.hex())
        for (text in listOf("Zg==", "AA+_", "", "x")) assertNull(Base64Url.decode(text), text)
    }

    @Test fun whitespaceLineBreaksAndLookalikesAreRefused() {
        for (text in listOf("AAAA\n", "AA AA", " AAAA", "AAAA\r\n", "AAA\u00C5", "\u212AAAA", "A\u0301AAA", "AAA\uFF21", "AAAA=", "====")) {
            assertNull(Base64Url.decode(text), text)
        }
    }

    // Padded standard base64, canonical spelling only

    @Test fun standardEncodingAgreesWithThePlatformEncoderAtEveryLength() {
        val random = SeededRandom(0x57D)
        for (length in 0 until 300) {
            val data = random.bytes(length)
            val text = Base64Std.encode(data)
            assertEquals(Base64.getEncoder().encodeToString(data), text)
            assertContentEquals(data, Base64Std.decodeCanonical(text))
        }
    }

    /**
     * Swift readers require `Data(base64Encoded: x)?.base64EncodedString() == x`. Each of
     * these decodes under a lenient decoder (several under Foundation's own) and is refused
     * because it does not re-encode to itself.
     */
    @Test fun aStandardSpellingThatDoesNotReencodeIdenticallyIsRefused() {
        val refused = listOf(
            "Zh==",        // non-zero unused bits; Foundation decodes it to the byte of "Zg=="
            "Zm9=",        // the same with one padding character
            "Zg=",         // short padding
            "Zg",          // no padding
            "Zm8",         // no padding
            "====",        // Foundation decodes this to one zero byte
            "Z===",
            "Zg==Zg==",    // padding in the middle
            "Zg==\n",
            " Zg==",
            "Zm-_",        // the URL alphabet
            "Zm9v\r\nZm9v",
            "Zm9vZg=",
            "=Zg=",
        )
        for (text in refused) assertNull(Base64Std.decodeCanonical(text), "\"$text\"")
    }

    @Test fun theCanonicalStandardSpellingsDecode() {
        assertEquals("", Base64Std.decodeCanonical("")!!.hex())      // Swift decodes "" to no bytes
        assertEquals("66", Base64Std.decodeCanonical("Zg==")!!.hex())
        assertEquals("666f", Base64Std.decodeCanonical("Zm8=")!!.hex())
        assertEquals("666f6f", Base64Std.decodeCanonical("Zm9v")!!.hex())
        assertEquals("666fbf", Base64Std.decodeCanonical("Zm+/")!!.hex())
        // A 32-byte key and a 64-byte bundle half, as in the portable key bundle.
        assertNotNull(Base64Std.decodeCanonical(Base64Std.encode(counting(0, 32))))
    }

    /** The published Git vault file's ciphertext is canonical padded base64 of nonce ‖ ct ‖ tag. */
    @Test fun theKnownGitVaultCiphertextIsCanonical() {
        val decoded = assertNotNull(Base64Std.decodeCanonical(KeyWrapTest.GIT_VAULT_KNOWN_CIPHERTEXT))
        assertEquals(counting(0x20, 12).hex(), decoded.copyOf(12).hex())
        assertEquals(KeyWrapTest.GIT_VAULT_KNOWN_CIPHERTEXT, Base64Std.encode(decoded))
        // One changed padding bit is a different, refused, spelling of the same bytes.
        val text = KeyWrapTest.GIT_VAULT_KNOWN_CIPHERTEXT
        assertEquals('=', text.last())
        val index = text.length - 2
        val nonCanonical = text.substring(0, index) + (text[index] + 1) + "="
        assertNull(Base64Std.decodeCanonical(nonCanonical))
    }

    @Test fun envelopeOutcomesMatchSwiftOnEveryReferenceInput() {
        val key = counting(1, 32)
        for (case in SwiftReference.json.array("envelopes")) {
            val text = case.jsonObject.string("text")
            val actual = try {
                SnippetCrypto.open(text, key, ByteArray(0))
                "ok"
            } catch (failure: SnippetCrypto.Failure) {
                when (failure) {
                    is SnippetCrypto.Failure.MalformedEnvelope -> "malformedEnvelope:" + failure.detail
                    is SnippetCrypto.Failure.UnsupportedWireVersion -> "unsupportedWireVersion:" + failure.version
                    is SnippetCrypto.Failure.AuthenticationFailed -> "authenticationFailed"
                    is SnippetCrypto.Failure.MalformedPadding -> "malformedPadding"
                    is SnippetCrypto.Failure.MalformedNonce -> "malformedNonce:" + failure.count
                    is SnippetCrypto.Failure.WrongKeySize -> "wrongKeySize:" + failure.count
                    is SnippetCrypto.Failure.CryptoUnavailable -> "cryptoUnavailable"
                }
            }
            assertEquals(case.string("result"), actual, "\"$text\"")
        }
    }
}
