package com.khm.snippets.core.crypto

// Both dialects are written out rather than taken from `java.util.Base64`: its decoders
// accept padding, line breaks and other spellings that Swift's readers refuse, and which
// inputs a reader accepts is part of each format here.

private const val STANDARD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
private const val URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

private fun reverseTable(alphabet: String): IntArray =
    IntArray(128) { -1 }.also { table -> alphabet.forEachIndexed { value, character -> table[character.code] = value } }

private val STANDARD_VALUES = reverseTable(STANDARD_ALPHABET)
private val URL_VALUES = reverseTable(URL_ALPHABET)

private fun encode(bytes: ByteArray, alphabet: String, padded: Boolean): String {
    val out = StringBuilder((bytes.size + 2) / 3 * 4)
    var index = 0
    while (index + 3 <= bytes.size) {
        val chunk = ((bytes[index].toInt() and 0xFF) shl 16) or
            ((bytes[index + 1].toInt() and 0xFF) shl 8) or
            (bytes[index + 2].toInt() and 0xFF)
        out.append(alphabet[chunk ushr 18]).append(alphabet[(chunk ushr 12) and 0x3F])
            .append(alphabet[(chunk ushr 6) and 0x3F]).append(alphabet[chunk and 0x3F])
        index += 3
    }
    when (bytes.size - index) {
        1 -> {
            val chunk = (bytes[index].toInt() and 0xFF) shl 16
            out.append(alphabet[chunk ushr 18]).append(alphabet[(chunk ushr 12) and 0x3F])
            if (padded) out.append("==")
        }
        2 -> {
            val chunk = ((bytes[index].toInt() and 0xFF) shl 16) or ((bytes[index + 1].toInt() and 0xFF) shl 8)
            out.append(alphabet[chunk ushr 18]).append(alphabet[(chunk ushr 12) and 0x3F])
                .append(alphabet[(chunk ushr 6) and 0x3F])
            if (padded) out.append('=')
        }
    }
    return out.toString()
}

/**
 * Decodes [length] symbols with no padding among them. The unused low bits of a final
 * partial group are dropped without being checked, which is what Foundation's
 * `Data(base64Encoded:)` does. `null` for a symbol outside the alphabet or a length of `4n + 1`.
 */
private fun decodeSymbols(text: CharSequence, length: Int, values: IntArray): ByteArray? {
    if (length % 4 == 1) return null
    val out = ByteArray(length * 6 / 8)
    var accumulator = 0
    var bits = 0
    var position = 0
    for (index in 0 until length) {
        val character = text[index]
        val value = if (character.code < 128) values[character.code] else -1
        if (value < 0) {
            out.fill(0)
            return null
        }
        accumulator = (accumulator shl 6) or value
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out[position++] = (accumulator ushr bits).toByte()
            accumulator = accumulator and ((1 shl bits) - 1)
        }
    }
    return out
}

/**
 * Unpadded URL-safe base64: sealed envelopes, `vaultSalt`, `saltP` and passphrase-wrap salts.
 * Mirrors `SnippetCrypto.base64URL` and `SnippetCrypto.data(fromBase64URL:)`.
 */
object Base64Url {

    fun encode(bytes: ByteArray): String = encode(bytes, URL_ALPHABET, padded = false)

    /**
     * `null` for empty text, any character outside `A-Z a-z 0-9 - _` (so `=`, `+`, `/` and
     * whitespace are refused) and a length of `4n + 1`.
     *
     * Swift is lenient in exactly one way and this follows it: non-zero unused bits in
     * the last symbol are ignored, so `Zh` decodes to the same byte as `Zg`. The Rust
     * reader refuses those spellings.
     */
    fun decode(text: CharSequence): ByteArray? {
        if (text.isEmpty()) return null
        return decodeSymbols(text, text.length, URL_VALUES)
    }
}

/**
 * Padded standard base64 in its canonical spelling: Git key files, the portable key
 * bundle and Snippets Cloud recovery envelopes.
 */
object Base64Std {

    fun encode(bytes: ByteArray): String = encode(bytes, STANDARD_ALPHABET, padded = true)

    /**
     * Swift readers decode with `Data(base64Encoded:)` and then require
     * `decoded.base64EncodedString() == text`. This does the same two steps, so the only
     * accepted spelling is the one [encode] writes: full groups of four, `=` padding,
     * zero unused bits, no whitespace. Empty text decodes to no bytes, as it does in Swift.
     */
    fun decodeCanonical(text: CharSequence): ByteArray? {
        if (text.length % 4 != 0) return null
        var symbols = text.length
        if (symbols > 0 && text[symbols - 1] == '=') symbols -= 1
        if (symbols > 0 && text[symbols - 1] == '=') symbols -= 1
        val decoded = decodeSymbols(text, symbols, STANDARD_VALUES) ?: return null
        if (!encode(decoded).contentEquals(text)) {
            decoded.fill(0)
            return null
        }
        return decoded
    }
}
