package com.khm.snippets.core.review.crypto

import java.io.File
import java.util.zip.GZIPInputStream

// Shared by the crypto reviewer's tests. Every key, password and body here is fictional
// public test data.
//
// The differential tests compare the Kotlin port with verdicts recorded from the shipping
// Swift code. The recorder is a small SwiftPM executable (`xcheck`) that links
// `snippets/Core` through the same symlink overlay as `tools/swift-interop` and answers
// TSV lines `kind \t hex-argument…` with one verdict each. Its source is kept beside the
// fixtures as `fixtures/review-crypto/xcheck-recorder.swift.txt`.

internal object ReviewCrypto {

    private const val DIRECTORY = "/fixtures/review-crypto/"

    /** Rows of a recorded fixture: `kind, argument…, verdict`. */
    fun rows(name: String): List<List<String>> {
        val stream = ReviewCrypto::class.java.getResourceAsStream(DIRECTORY + name)
            ?: throw IllegalStateException("missing reviewer fixture $name")
        val input = if (name.endsWith(".gz")) GZIPInputStream(stream) else stream
        return input.bufferedReader(Charsets.UTF_8).useLines { lines ->
            lines.filter { it.isNotEmpty() && !it.startsWith("#") }.map { it.split('\t') }.toList()
        }
    }

    fun lines(name: String): List<String> {
        val stream = ReviewCrypto::class.java.getResourceAsStream(DIRECTORY + name)
            ?: throw IllegalStateException("missing reviewer fixture $name")
        val input = if (name.endsWith(".gz")) GZIPInputStream(stream) else stream
        return input.bufferedReader(Charsets.UTF_8).useLines { it.filter(String::isNotEmpty).toList() }
    }

    /**
     * Where a full-scale exchange with the Swift recorder happens, or `null` on a normal
     * run. Set `REVIEW_CRYPTO_XCHECK_DIR` to an existing directory to export inputs and to
     * compare a full-scale `judge-out.tsv` that the recorder wrote there.
     */
    val exchangeDirectory: File?
        get() = System.getenv("REVIEW_CRYPTO_XCHECK_DIR")?.takeIf(String::isNotEmpty)?.let(::File)?.takeIf(File::isDirectory)

    private const val HEX = "0123456789abcdef"

    fun hex(bytes: ByteArray): String {
        val out = CharArray(bytes.size * 2)
        for (index in bytes.indices) {
            val byte = bytes[index].toInt() and 0xFF
            out[index * 2] = HEX[byte ushr 4]
            out[index * 2 + 1] = HEX[byte and 0x0F]
        }
        return String(out)
    }

    fun hex(text: String): String = hex(text.toByteArray(Charsets.UTF_8))

    fun unhex(text: String): ByteArray {
        require(text.length % 2 == 0) { "odd hex" }
        return ByteArray(text.length / 2) {
            ((Character.digit(text[it * 2], 16) shl 4) or Character.digit(text[it * 2 + 1], 16)).toByte()
        }
    }

    fun text(hex: String): String = String(unhex(hex), Charsets.UTF_8)
}

/** splitmix64, the generator the Swift recorder uses too, so both sides walk the same values. */
internal class SplitMix64(seed: Long) {
    private var state = seed

    fun next(): Long {
        state += 0x9E3779B97F4A7C15uL.toLong()
        var z = state
        z = (z xor (z ushr 30)) * 0xBF58476D1CE4E5B9uL.toLong()
        z = (z xor (z ushr 27)) * 0x94D049BB133111EBuL.toLong()
        return z xor (z ushr 31)
    }

    /** Uniform enough for test data: `next() mod bound`, unsigned. */
    fun below(bound: Int): Int = java.lang.Long.remainderUnsigned(next(), bound.toLong()).toInt()

    fun chance(oneIn: Int): Boolean = below(oneIn) == 0

    fun bytes(count: Int): ByteArray = ByteArray(count) { next().toByte() }

    fun <T> pick(items: List<T>): T = items[below(items.size)]

    fun pick(items: String): Char = items[below(items.length)]
}

/**
 * The shared recipe for a "random" finite double; `nextDouble` in the recorder is the same
 * statement for statement. It mixes uniform bit patterns with the values canonical JSON
 * really carries (decimals, timestamps) and the layout thresholds.
 */
internal fun nextReviewDouble(rng: SplitMix64): Double {
    while (true) {
        val selector = java.lang.Long.remainderUnsigned(rng.next(), 8).toInt()
        val raw = rng.next()
        val value: Double = when (selector) {
            0, 1, 2, 3 -> Double.fromBits(raw)
            4 -> {
                val digits = java.lang.Long.remainderUnsigned(raw, 100_000_000_000_000_000L).toDouble()
                val power = java.lang.Long.remainderUnsigned(rng.next(), 40).toInt()
                if (rng.next() and 1L == 0L) digits / reviewPow10(power) else digits * reviewPow10(power)
            }
            5 -> {
                val whole = java.lang.Long.remainderUnsigned(raw, 2_000_000_000L).toDouble()
                val fractionInteger = java.lang.Long.remainderUnsigned(rng.next(), 1_000_000L)
                val fraction = fractionInteger.toDouble()
                if (rng.next() and 1L == 0L) whole + fraction / 1_000_000 else whole + (fractionInteger / 1000).toDouble() / 1000
            }
            6 -> {
                val magnitude = if (java.lang.Long.remainderUnsigned(raw, 3) == 0L) {
                    java.lang.Long.remainderUnsigned(raw, 1000)
                } else {
                    (1L shl 53) + java.lang.Long.remainderUnsigned(raw, 4096) - 2048
                }
                magnitude.toDouble()
            }
            else -> {
                val exponent = java.lang.Long.remainderUnsigned(raw, 2098).toInt() - 1074
                var moved = Math.scalb(1.0, exponent)
                val step = java.lang.Long.remainderUnsigned(rng.next(), 5).toInt() - 2
                if (step > 0) repeat(step) { moved = Math.nextUp(moved) }
                if (step < 0) repeat(-step) { moved = Math.nextDown(moved) }
                moved
            }
        }
        if (value.isFinite()) return if (rng.next() and 1L == 0L) value else -value
    }
}

internal fun reviewPow10(power: Int): Double {
    var out = 1.0
    repeat(power) { out *= 10 }
    return out
}
