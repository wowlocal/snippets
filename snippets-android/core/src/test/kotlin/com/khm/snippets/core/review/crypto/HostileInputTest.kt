package com.khm.snippets.core.review.crypto

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.crypto.Base64Std
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.DeterministicUuid
import com.khm.snippets.core.crypto.KeyWrap
import com.khm.snippets.core.crypto.PassphraseKdf
import com.khm.snippets.core.crypto.RecoveryKey
import com.khm.snippets.core.crypto.SealedEnvelope
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Hostile and malformed input to every parser of this layer: only the declared failure
 * types (or `null`) may come back. These pass; they are here to keep it that way.
 */
class HostileInputTest {

    /** UTF-16 that Swift cannot even hold: unpaired surrogates, NULs, format controls, among ordinary text. */
    private fun wildText(rng: SplitMix64, maximum: Int): String {
        val out = StringBuilder()
        repeat(rng.below(maximum + 1)) {
            when (rng.below(12)) {
                0 -> out.append((0xD800 + rng.below(0x800)).toChar())                       // a lone surrogate, either half
                1 -> out.append(rng.pick("\u0000﻿‍́￾￿ \r\n"))
                2 -> out.appendCodePoint(0x10000 + rng.below(0x100000))
                3 -> out.append((rng.below(0xD800)).toChar())
                4 -> out.append(rng.pick(".-_=+/ v1"))
                else -> out.append(rng.pick("0123456789ABCDEFGHJKMNPQRSTVWXYZabcdefilou-"))
            }
        }
        return out.toString()
    }

    private inline fun onlyDeclared(what: String, input: String, block: () -> Unit) {
        try {
            block()
        } catch (_: SnippetCrypto.Failure) {
        } catch (_: KeyWrap.Failure) {
        } catch (_: PassphraseKdf.Failure) {
        } catch (_: RecoveryKey.Failure) {
        } catch (_: CanonicalJson.Failure) {
        } catch (escaped: Throwable) {
            fail("$what let ${escaped.javaClass.name} escape for UTF-16 ${input.map { "%04x".format(it.code) }.joinToString(" ")}: ${escaped.message}")
        }
    }

    @Test
    fun textParsersSurviveArbitraryUtf16() {
        val rng = SplitMix64(0xBADC0DE)
        val key = ByteArray(32) { 7 }
        val salt = ByteArray(16) { 9 }
        val namespace = UUID(1, 2)
        repeat(60_000) {
            val text = wildText(rng, 40)
            onlyDeclared("RecoveryKey.decode", text) { RecoveryKey.decode(text) }
            onlyDeclared("RecoveryKey.normalized", text) { RecoveryKey.normalized(text) }
            onlyDeclared("RecoveryKey.grouped", text) { RecoveryKey.grouped(text) }
            onlyDeclared("SealedEnvelope.parse", text) { SealedEnvelope.parse(text) }
            onlyDeclared("SnippetCrypto.open", text) { SnippetCrypto.open(text, key, salt) }
            onlyDeclared("SnippetCrypto.open(v1)", text) { SnippetCrypto.open("v1.$text", key, salt) }
            onlyDeclared("Base64Url.decode", text) { Base64Url.decode(text) }
            onlyDeclared("Base64Std.decodeCanonical", text) { Base64Std.decodeCanonical(text) }
            onlyDeclared("Uuids.parse", text) { Uuids.parse(text); Uuids.parseLowercase(text); Uuids.parseUppercase(text) }
            onlyDeclared("KeyWrap.unwrap", text) { KeyWrap.unwrap(text, key, KeyWrap.Purpose.RECOVERY, text, salt) }
            onlyDeclared("KeyWrap.additionalData", text) { KeyWrap.additionalData(KeyWrap.Purpose.CLI, text) }
            onlyDeclared("SnippetCrypto.additionalData", text) { SnippetCrypto.additionalData(SnippetCrypto.RecordContext(text, namespace)) }
            onlyDeclared("DeterministicUuid.make", text) { DeterministicUuid.make(namespace, text) }
            onlyDeclared("CanonicalJson.encode", text) { CanonicalJson.encode(JsonValue.obj(text to JsonValue.of(text))) }
            if (it % 16 == 0) {
                onlyDeclared("PassphraseKdf.derive", text) { PassphraseKdf.derive(text, salt, 1) }
                onlyDeclared("PassphraseKdf.unwrap", text) {
                    PassphraseKdf.unwrap(PassphraseKdf.WrappedKey(PassphraseKdf.ALGORITHM, 1, text, text), text, text)
                }
            }
        }
    }

    /** An unpaired surrogate is U+FFFD wherever text feeds a hash, a KDF or an AAD, on both the `String` and the `CharArray` path. */
    @Test
    fun anUnpairedSurrogateIsTheReplacementCharacterOnEveryPath() {
        val salt = ByteArray(16) { 1 }
        for (lone in listOf("\uD800", "\uDFFF", "a\uDC00b", "\uD83D", "\uDE00\uD83D")) {
            val repaired = lone.map { if (it.isSurrogate()) '�' else it }.joinToString("")
            assertContentEquals(Utf8.encode(repaired), Utf8.encode(lone))
            assertContentEquals(Utf8.encode(repaired), Utf8.encode(lone.toCharArray()))
            assertNull(Utf8.encodeStrict(lone))
            assertContentEquals(PassphraseKdf.derive(repaired, salt, 1), PassphraseKdf.derive(lone, salt, 1))
            assertContentEquals(PassphraseKdf.derive(repaired, salt, 1), PassphraseKdf.derive(lone.toCharArray(), salt, 1))
            assertContentEquals(KeyWrap.additionalData(KeyWrap.Purpose.CLI, repaired), KeyWrap.additionalData(KeyWrap.Purpose.CLI, lone))
            assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { CanonicalJson.encode(JsonValue.of(lone)) }
            assertFailsWith<CanonicalJson.Failure.InvalidUtf8> { CanonicalJson.encode(JsonValue.obj(lone to JsonValue.Null)) }
        }
    }

    @Test
    fun randomBytesNeverCrashTheCanonicalParserAndWhatParsesIsAFixedPoint() {
        val rng = SplitMix64(0xC0FFEE)
        val alphabet = "{}[]\",:\\ \n-+.eE0123456789tfnrualsbu/".toByteArray(Charsets.US_ASCII)
        var parsed = 0
        repeat(400_000) {
            val bytes = ByteArray(rng.below(14)) { if (rng.chance(20)) rng.next().toByte() else alphabet[rng.below(alphabet.size)] }
            val value = try {
                CanonicalJson.parse(bytes)
            } catch (_: CanonicalJson.Failure) {
                return@repeat
            } catch (escaped: Throwable) {
                fail("parse let ${escaped.javaClass.name} escape for ${ReviewCrypto.hex(bytes)}")
            }
            val canonical = try {
                CanonicalJson.encode(value)
            } catch (_: CanonicalJson.Failure.NonFiniteNumber) {
                return@repeat   // `1e999` parses to infinity, as in Swift, and cannot be written
            }
            parsed += 1
            val again = CanonicalJson.parse(canonical)
            assertEquals(value, again, ReviewCrypto.hex(bytes))
            assertEquals(value.hashCode(), again.hashCode(), ReviewCrypto.hex(bytes))
            assertEquals(KotlinJudge.dump(value), KotlinJudge.dump(again), "an integer and a double must stay what they were: ${ReviewCrypto.hex(bytes)}")
            assertContentEquals(canonical, CanonicalJson.encode(again))
        }
        assertTrue(parsed > 10_000, "only $parsed random inputs parsed; the generator is too wild to say anything")
    }

    /** Nesting is refused by depth, never by the size of the thread's stack, and at the same depth as Swift (V10 pins 33 arrays / 32 objects). */
    @Test
    fun absurdNestingIsRefusedWithoutRecursing() {
        var caught: Throwable? = null
        val small = Thread(null, {
            try {
                for (opener in listOf("[", "{\"a\":", "[{\"\":", " [ ")) {
                    assertFailsWith<CanonicalJson.Failure.TooDeep> { CanonicalJson.parse(opener.repeat(2_000_000).toByteArray()) }
                }
                assertNotNull(CanonicalJson.parse(("[".repeat(33) + "]".repeat(33)).toByteArray()))
                assertFailsWith<CanonicalJson.Failure.TooDeep> { CanonicalJson.parse(("[".repeat(34) + "]".repeat(34)).toByteArray()) }
                assertNotNull(CanonicalJson.parse(("{\"a\":".repeat(32) + "1" + "}".repeat(32)).toByteArray()))
                assertFailsWith<CanonicalJson.Failure.TooDeep> { CanonicalJson.parse(("{\"a\":".repeat(33) + "1" + "}".repeat(33)).toByteArray()) }
            } catch (failure: Throwable) {
                caught = failure
            }
        }, "small-stack", 128 * 1024)
        small.start()
        small.join()
        caught?.let { throw it }
    }

    /**
     * Each of these is linear in its input on the JVM (measured: 4 MB in 5 to 140 ms). The
     * bound is two orders of magnitude above that, so it only trips on a quadratic regression.
     */
    @Test
    fun largeInputsTakeLinearTime() {
        val size = 3_000_000
        fun bounded(what: String, block: () -> Unit) {
            val start = System.nanoTime()
            try {
                block()
            } catch (_: Exception) {
            }
            val millis = (System.nanoTime() - start) / 1_000_000
            assertTrue(millis < 15_000, "$what took $millis ms for $size bytes")
        }
        bounded("a long integer token") { CanonicalJson.parse(("1" + "0".repeat(size)).toByteArray()) }
        bounded("a long fraction") { CanonicalJson.parse(("0." + "0".repeat(size) + "1").toByteArray()) }
        bounded("a long exponent") { CanonicalJson.parse(("1e" + "9".repeat(size)).toByteArray()) }
        bounded("a long escaped string") { CanonicalJson.parse(("\"" + "\\u00e9".repeat(size / 6) + "\"").toByteArray()) }
        bounded("many keys with one hash code") {
            // "Aa" and "BB" hash alike, and so does every string built from them.
            val text = StringBuilder("{")
            for (index in 0 until size / 40) {
                text.append('"')
                for (bit in 0 until 17) text.append(if ((index shr bit) and 1 == 0) "Aa" else "BB")
                text.append("\":1,")
            }
            CanonicalJson.encode(CanonicalJson.parse(text.append("\"z\":1}").toString().toByteArray()))
        }
        bounded("many non-ASCII keys") {
            val text = StringBuilder("{")
            for (index in 0 until size / 16) text.append("\"é").append(index).append("\":1,")
            CanonicalJson.encode(CanonicalJson.parse(text.append("\"z\":1}").toString().toByteArray()))
        }
        bounded("an envelope of dots") { SealedEnvelope.parse(".".repeat(size)) }
        bounded("a huge envelope body") { SnippetCrypto.open("v1.AAAAAAAAAAAAAAAA." + "A".repeat(size), ByteArray(32), ByteArray(0)) }
        bounded("a recovery key of separators") { RecoveryKey.decode(" -".repeat(size / 2)) }
        bounded("a recovery key of combining marks") { RecoveryKey.decode("A" + "́".repeat(size)) }
        bounded("standard base64") { Base64Std.decodeCanonical("A".repeat(size)) }
    }

    /**
     * Stricter than Swift on purpose, as `Uuids.parse` documents: Foundation reads a C string,
     * so `UUID(uuidString:)` accepts a valid id followed by NUL and anything (recorded in
     * `codecs.tsv.gz`). Pinned here so the difference stays a decision.
     */
    @Test
    fun aUuidFollowedByAnEmbeddedNulIsRefusedAlthoughFoundationAcceptsIt() {
        val recorded = ReviewCrypto.rows("codecs.tsv.gz").filter { KnownDefects.isUuidWithEmbeddedNul(it.dropLast(1), it.last()) }
        assertTrue(recorded.isNotEmpty())
        for (row in recorded) {
            assertNull(Uuids.parse(ReviewCrypto.text(row[1])), "Swift read this as ${row.last()}")
        }
    }
}
