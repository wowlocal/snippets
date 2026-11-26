package com.khm.snippets.core.crypto

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The crypto review's findings D1 and D4 to D7, each pinned. */
class CryptoReviewFixesTest {

    // D1: Foundation's `String(data:encoding:)` drops one leading U+FEFF.

    @Test fun decodingDropsOneLeadingByteOrderMarkAndKeepsTheRest() {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        assertEquals("A", Utf8.decodeStrict(bom + utf8("A")))
        assertEquals("﻿A", Utf8.decodeStrict(bom + bom + utf8("A")))
        assertEquals("", Utf8.decodeStrict(bom))
        assertEquals("A﻿", Utf8.decodeStrict(utf8("A") + bom))
        assertEquals("﻿A", Utf8.decodeKeepingByteOrderMark(bom + utf8("A")))
        assertNull(Utf8.decodeStrict(bom + byteArrayOf(0xC0.toByte(), 0x80.toByte())))
        assertEquals("pin", SnippetCrypto.plaintextString(bom + utf8("pin")))
    }

    // D5: one encode buffer, exact length, every kind of input.

    @Test fun encodingGivesExactBytesForEveryKindOfInput() {
        for (text in listOf("", "a", "é", "€uro", "🔑 key", "a\uD800b", "\uDC00", "\uD800", "x".repeat(10_000) + "😀")) {
            val expected = Utf8.decodeKeepingByteOrderMark(Utf8.encode(text))!!.toByteArray(Charsets.UTF_8)
            assertContentEquals(expected, Utf8.encode(text), text.take(12))
            assertContentEquals(Utf8.encode(text), Utf8.encode(text.toCharArray()))
        }
        assertContentEquals(utf8("a�b"), Utf8.encode("a\uD800b"))
        assertNull(Utf8.encodeStrict("a\uD800b"))
        assertContentEquals(utf8("🔑"), Utf8.encodeStrict("🔑"))
    }

    // D6: only a failed tag is "did not authenticate".

    @Test fun aProviderFailureIsNotAWrongKey() {
        val key = filled(0x11, 32)
        val aad = utf8("aad")
        val sealed = SnippetCrypto.seal(utf8("body"), key, aad, stationaryNonces())
        val wrap = KeyWrap.wrap(key, filled(0x22, 16), KeyWrap.Purpose.RECOVERY, "kid", filled(0x33, 32), stationaryNonces())
        val passphraseWrap = PassphraseKdf.wrap(key, "public fixture", filled(0x44, 16), "kid", 2, stationaryNonces())

        // A tag that fails is still the coarse answer.
        assertNull(AesGcm.open(key, filled(0, 12), ByteArray(32), ByteArray(0)))
        assertFailsWith<SnippetCrypto.Failure.AuthenticationFailed> { SnippetCrypto.open(sealed, filled(0x12, 32), aad) }

        val original = AesGcm.transformation
        AesGcm.transformation = "AES/GCM/NoSuchPadding"
        try {
            assertFailsWith<java.security.GeneralSecurityException> { AesGcm.open(key, filled(0, 12), ByteArray(32), ByteArray(0)) }
            assertFailsWith<SnippetCrypto.Failure.CryptoUnavailable> { SnippetCrypto.open(sealed, key, aad) }
            assertFailsWith<SnippetCrypto.Failure.CryptoUnavailable> { SnippetCrypto.seal(utf8("body"), key, aad) }
            assertFailsWith<SnippetCrypto.Failure.CryptoUnavailable> {
                KeyWrap.unwrap(wrap, filled(0x22, 16), KeyWrap.Purpose.RECOVERY, "kid", filled(0x33, 32))
            }
            assertFailsWith<SnippetCrypto.Failure.CryptoUnavailable> { PassphraseKdf.unwrap(passphraseWrap, "public fixture", "kid") }
        } finally {
            AesGcm.transformation = original
        }
        assertContentEquals(key, PassphraseKdf.unwrap(passphraseWrap, "public fixture", "kid"))
    }

    // D7: Swift's `uppercased()`, not the JVM's.

    @Test fun aRecoveryKeyIsUppercasedAsSwiftUppercasesIt() {
        // U+2C5F GLAGOLITIC SMALL LETTER CAUDATE CHRIVI (Unicode 14) has an uppercase in
        // Swift's tables and none in the JVM 17's.
        assertEquals("Ⱟ", RecoveryKey.normalized("ⱟ"))
        val typed = "ⱟ" + "0".repeat(RecoveryKey.CHARACTER_COUNT - 1)
        val failure = assertFailsWith<RecoveryKey.Failure.InvalidCharacter> { RecoveryKey.decode(typed) }
        assertEquals("Ⱟ", failure.character)
        assertEquals("SS", RecoveryKey.normalized("ß"))
        assertEquals("1", RecoveryKey.normalized("i"))
    }

    // D4: PBKDF2 over precomputed HMAC states, cancellable.

    @Test fun theKeyedDigestDerivationIsTheMacDerivation() {
        val random = java.util.Random(7)
        for (passwordLength in listOf(0, 1, 31, 64, 127, 128, 129, 200, 300)) {
            for (length in listOf(1, 32, 63, 64, 65, 130)) {
                val password = ByteArray(passwordLength).also(random::nextBytes)
                val salt = ByteArray(passwordLength % 20 + 1).also(random::nextBytes)
                for (iterations in listOf(1, 2, 3, 4097)) {
                    assertContentEquals(
                        MacPbkdf2HmacSha512.macDerive(password, salt, iterations, length),
                        MacPbkdf2HmacSha512.derive(password, salt, iterations, length),
                        "password $passwordLength, length $length, $iterations rounds",
                    )
                }
            }
        }
        // RFC 6070-style check against the platform's own PBKDF2.
        assertContentEquals(
            JcaPbkdf2HmacSha512.derive(utf8("password"), utf8("salt"), 4096, 64),
            MacPbkdf2HmacSha512.derive(utf8("password"), utf8("salt"), 4096, 64),
        )
    }

    @Test fun theCancellationCheckRunsEveryIntervalAndStopsTheDerivation() {
        for (implementation in listOf<(() -> Unit) -> ByteArray>(
            { check -> MacPbkdf2HmacSha512.derive(utf8("p"), utf8("salt"), 20_000, 32, check) },
            { check -> MacPbkdf2HmacSha512.macDerive(utf8("p"), utf8("salt"), 20_000, 32, check) },
        )) {
            val calls = AtomicInteger()
            implementation { calls.incrementAndGet() }
            // Before the first round, then at 4096, 8192, 12288 and 16384.
            assertEquals(5, calls.get())

            class Stop : RuntimeException()
            val stoppedAt = AtomicInteger()
            assertFailsWith<Stop> {
                implementation { if (stoppedAt.incrementAndGet() == 2) throw Stop() }
            }
            assertEquals(2, stoppedAt.get())
        }
    }

    @Test fun aCancelledSuspendingDerivationStopsPromptly() = runBlocking {
        val started = System.nanoTime()
        val derivation = async(Dispatchers.Default) {
            PassphraseKdf.deriveSuspending("public fixture".toCharArray(), filled(0x55, 16), PassphraseKdf.MAXIMUM_ITERATIONS)
        }
        delay(50)
        withTimeout(2_000) { derivation.cancelAndJoin() }
        assertTrue(derivation.isCancelled)
        assertFailsWith<CancellationException> { derivation.await() }
        // 20 million rounds take tens of seconds; a cancelled one ends within one interval.
        assertTrue(System.nanoTime() - started < 3_000_000_000L, "the derivation did not stop")
    }

    @Test fun theSuspendingFormsGiveTheBlockingResults() = runBlocking {
        val salt = filled(0x66, 16)
        val key = filled(0x77, 32)
        assertContentEquals(
            PassphraseKdf.derive("public fixture", salt, 3),
            PassphraseKdf.deriveSuspending("public fixture".toCharArray(), salt, 3),
        )
        val wrapped = PassphraseKdf.wrapSuspending(key, "public fixture".toCharArray(), salt, "kid", 3)
        assertContentEquals(key, PassphraseKdf.unwrapSuspending(wrapped, "public fixture".toCharArray(), "kid"))
    }

    /** Not a test of speed: prints both implementations' time for the shipping count. `PBKDF2_BENCHMARK=1` to run. */
    @Test fun benchmark() {
        if (System.getenv("PBKDF2_BENCHMARK") != "1") return
        val password = utf8("correct horse battery staple")
        val salt = filled(0x5A, 16)
        fun time(label: String, derive: () -> ByteArray) {
            derive()
            val samples = (1..5).map {
                val start = System.nanoTime()
                derive()
                (System.nanoTime() - start) / 1_000_000
            }.sorted()
            println("PBKDF2 600000 rounds, $label: median ${samples[2]} ms (min ${samples[0]}, max ${samples[4]})")
        }
        time("Mac (before)") { MacPbkdf2HmacSha512.macDerive(password, salt, 600_000, 32) }
        time("keyed digests (after)") { MacPbkdf2HmacSha512.derive(password, salt, 600_000, 32) }
        time("JCA SecretKeyFactory") { JcaPbkdf2HmacSha512.derive(password, salt, 600_000, 32) }
    }
}
