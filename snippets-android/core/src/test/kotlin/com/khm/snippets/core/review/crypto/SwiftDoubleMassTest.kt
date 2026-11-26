package com.khm.snippets.core.review.crypto

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.canonical.SwiftDouble
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.fail

/**
 * `SwiftDouble.description` against Swift's own `Double.description` for ten million values.
 *
 * The Swift recorder walked `nextReviewDouble` from seed 20261125 and wrote one SHA-256 per
 * 50 000 descriptions (`xcheck dbl-digest 20261125 200 50000`, Swift 6.4, arm64 macOS).
 * Half of the values are uniform bit patterns; the rest are decimals, timestamps, integers
 * around 2^53 and powers of two with their neighbours.
 */
class SwiftDoubleMassTest {

    @Test
    fun tenMillionDescriptionsHashToWhatSwiftPrinted() {
        val expected = ReviewCrypto.lines("double-digests.txt")
        assertEquals(200, expected.size)
        val rng = SplitMix64(20261125)
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = StringBuilder(1 shl 21)
        for ((chunk, wanted) in expected.withIndex()) {
            buffer.setLength(0)
            repeat(CHUNK) { buffer.append(SwiftDouble.description(nextReviewDouble(rng))).append('\n') }
            val actual = ReviewCrypto.hex(digest.digest(buffer.toString().toByteArray(Charsets.US_ASCII)))
            if (actual != wanted) {
                fail("chunk $chunk (values ${chunk * CHUNK} until ${(chunk + 1) * CHUNK}) differs from Swift; bisect with `xcheck dbl-list 20261125 ${chunk * CHUNK} $CHUNK`")
            }
        }
    }

    /** Every description must read back, through the canonical parser, as the same bits and re-emit as the same text. */
    @Test
    fun twoMillionDescriptionsRoundTripThroughTheCanonicalParser() {
        val rng = SplitMix64(77)
        repeat(2_000_000) {
            val value = nextReviewDouble(rng)
            val text = SwiftDouble.description(value)
            val parsed = CanonicalJson.parse(text.toByteArray(Charsets.US_ASCII))
            if (parsed !is JsonValue.Real || parsed.value.toRawBits() != value.toRawBits()) {
                fail("$text (${java.lang.Long.toHexString(value.toRawBits())}) parsed as ${KotlinJudge.dump(parsed)}")
            }
            assertEquals(text, CanonicalJson.encodeToString(parsed))
        }
    }

    private companion object {
        const val CHUNK = 50_000
    }
}
