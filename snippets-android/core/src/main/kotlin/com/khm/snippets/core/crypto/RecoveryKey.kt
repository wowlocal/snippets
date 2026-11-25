package com.khm.snippets.core.crypto

import com.khm.snippets.core.text.GraphemeBreaker
import java.text.Normalizer
import java.util.Locale

/**
 * The recovery key / recovery code text (`snippets/Core/RecoveryKey.swift`): 128 random
 * bits as 26 Crockford base32 symbols plus one check symbol.
 *
 * ```
 *  bytes:   16 (128 bits)
 *  symbols: 26 payload + 1 check = 27 characters
 *  shown:   XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX
 * ```
 *
 * The same format serves the vault recovery key and a Git library's recovery code. The
 * text is as secret as the bytes; it exists as a `String` only to be shown or typed.
 */
object RecoveryKey {

    const val BYTE_COUNT = 16

    /** 26 symbols carry 130 bits; the low 2 bits of the last one are zero and [decode] insists on it. */
    const val PAYLOAD_CHARACTER_COUNT = 26
    const val CHARACTER_COUNT = PAYLOAD_CHARACTER_COUNT + 1
    const val GROUP_SIZE = 4
    const val GROUP_SEPARATOR = '-'

    /** Crockford's alphabet, index = value: the digits, then the letters without `I`, `L`, `O`, `U`. */
    const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /** Distinct on purpose: a typo is reported as a typo, never as a wrong key. */
    sealed class Failure(message: String) : Exception(message) {

        class WrongByteCount(val count: Int) : Failure("a recovery key is $BYTE_COUNT bytes, got $count")

        class WrongLength(val count: Int) : Failure("a recovery key is $CHARACTER_COUNT characters, got $count")

        /** [character] is one user-perceived character, so it may be more than one `Char`. Never part of a valid key. */
        class InvalidCharacter(val character: String) : Failure("\"$character\" is not part of a recovery key")

        class ChecksumMismatch : Failure("that recovery key has a typo in it")

        /** The 26th symbol had non-zero trailing bits, which [encode] never produces. */
        class NonCanonical : Failure("that recovery key is not a well-formed encoding")
    }

    /** 128 fresh bits from the system CSPRNG. The caller wipes them. */
    fun generate(): ByteArray = Bytes.random(BYTE_COUNT)

    /** The canonical form: 27 uppercase characters, no separators. */
    @Throws(Failure.WrongByteCount::class)
    fun encode(bytes: ByteArray): String {
        if (bytes.size != BYTE_COUNT) throw Failure.WrongByteCount(bytes.size)
        val payload = symbolsFromBytes(bytes)
        val out = StringBuilder(CHARACTER_COUNT)
        for (symbol in payload) out.append(ALPHABET[symbol])
        out.append(ALPHABET[checkSymbol(payload)])
        payload.fill(0)
        return out.toString()
    }

    /** The form shown to a person: groups of four joined by `-`, the last group three characters. */
    @Throws(Failure.WrongByteCount::class)
    fun formatted(bytes: ByteArray): String = grouped(encode(bytes))

    fun grouped(canonical: String): String {
        val out = StringBuilder(canonical.length + canonical.length / GROUP_SIZE)
        for ((offset, character) in characters(canonical).withIndex()) {
            if (offset > 0 && offset % GROUP_SIZE == 0) out.append(GROUP_SEPARATOR)
            out.append(character)
        }
        return out.toString()
    }

    /**
     * Accepts what a person types: either case, any grouping, spaces, line breaks,
     * non-breaking spaces, the dashes a notes app substitutes for `-`, and `I`/`L`/`O`
     * read for `1`/`1`/`0`. Rejects a key with a typo in it. The caller wipes the result.
     */
    @Throws(Failure::class)
    fun decode(text: CharSequence): ByteArray {
        val normalized = characters(normalized(text))
        if (normalized.size != CHARACTER_COUNT) throw Failure.WrongLength(normalized.size)

        val symbols = IntArray(CHARACTER_COUNT)
        for ((index, character) in normalized.withIndex()) {
            val folded = canonical(character)
            val value = if (folded.length == 1) ALPHABET.indexOf(folded[0]) else -1
            if (value < 0) throw Failure.InvalidCharacter(character)
            symbols[index] = value
        }

        val payload = symbols.copyOf(PAYLOAD_CHARACTER_COUNT)
        try {
            if (symbols[PAYLOAD_CHARACTER_COUNT] != checkSymbol(payload)) throw Failure.ChecksumMismatch()
            return bytesFromSymbols(payload)
        } finally {
            payload.fill(0)
            symbols.fill(0)
        }
    }

    /**
     * Uppercases, drops the separators a person or an app may have inserted, and folds the
     * confusable glyphs onto the characters Crockford means.
     *
     * Swift does this per `Character`, comparing by canonical equivalence, and this follows
     * it. Two consequences worth knowing:
     * - a Windows line break (`\r\n`) is a single character there, equal to neither `\r`
     *   nor `\n`, so it is **not** dropped and the key fails as [Failure.WrongLength];
     * - U+212A KELVIN SIGN is canonically equal to `K` and decodes as `K`.
     *
     * Characters that are kept are kept as typed: nothing but the case is rewritten.
     */
    fun normalized(text: CharSequence): String {
        // Root locale: the default one turns `i` into `I-with-dot (U+0130)` on a Turkish device.
        val upper = text.toString().uppercase(Locale.ROOT)
        val out = StringBuilder(upper.length)
        for (character in characters(upper)) {
            when (canonical(character)) {
                " ", "\t", "\n", "\r", "\u00A0",                     // whitespace, incl. non-breaking
                "-", "\u2010", "\u2011", "\u2012",                   // hyphen and its Unicode cousins
                "\u2013", "\u2014", "\u2212", "_",                   // en dash, em dash, minus sign
                -> continue
                "I", "L" -> out.append('1')
                "O" -> out.append('0')
                else -> out.append(character)
            }
        }
        return out.toString()
    }

    /**
     * What Swift's `Character ==` compares: after NFC, a character canonically equal to an
     * ASCII one *is* that one.
     */
    private fun canonical(character: String): String =
        if (character.length == 1 && character[0].code < 0x80) character
        else Normalizer.normalize(character, Normalizer.Form.NFC)

    /** `sum((2i + 1) * symbol[i]) mod 32`. Every weight is odd, so every single-symbol change moves the sum. */
    fun checkSymbol(payload: IntArray): Int {
        var sum = 0
        for ((index, symbol) in payload.withIndex()) {
            sum = (sum + (2 * index + 1) * symbol) % 32
        }
        return sum
    }

    // Plain big-endian base32: bits leave the bytes most significant first, five per
    // symbol. 128 bits fill 25 symbols and leave 3, the top of a 26th whose low 2 bits are zero.

    fun symbolsFromBytes(bytes: ByteArray): IntArray {
        val symbols = IntArray((bytes.size * 8 + 4) / 5)
        var count = 0
        var accumulator = 0
        var bits = 0
        for (byte in bytes) {
            accumulator = (accumulator shl 8) or (byte.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                symbols[count++] = (accumulator ushr bits) and 0x1F
                accumulator = accumulator and ((1 shl bits) - 1)
            }
        }
        if (bits > 0) symbols[count] = (accumulator shl (5 - bits)) and 0x1F
        return symbols
    }

    @Throws(Failure::class)
    fun bytesFromSymbols(symbols: IntArray): ByteArray {
        val bytes = ByteArray(symbols.size * 5 / 8)
        var count = 0
        var accumulator = 0
        var bits = 0
        for (symbol in symbols) {
            accumulator = (accumulator shl 5) or symbol
            bits += 5
            if (bits >= 8) {
                bits -= 8
                bytes[count++] = (accumulator ushr bits).toByte()
                accumulator = accumulator and ((1 shl bits) - 1)
            }
        }
        // The leftover bits must be zero, or two different strings would decode to one key.
        if (accumulator != 0) {
            bytes.fill(0)
            throw Failure.NonCanonical()
        }
        if (count != BYTE_COUNT) {
            bytes.fill(0)
            throw Failure.WrongByteCount(count)
        }
        return bytes
    }

    /** What Swift iterates as `Character`s: extended grapheme clusters, so `\r\n` is one. */
    private fun characters(text: String): List<String> {
        val out = ArrayList<String>(text.length)
        var index = 0
        while (index < text.length) {
            val end = GraphemeBreaker.clusterEnd(text, index)
            out.add(text.substring(index, end))
            index = end
        }
        return out
    }
}
