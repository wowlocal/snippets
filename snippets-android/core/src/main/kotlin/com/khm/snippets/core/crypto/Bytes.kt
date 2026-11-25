package com.khm.snippets.core.crypto

import java.security.SecureRandom

/** Byte-level helpers shared by every format in this package. Nothing here allocates a `String` from key material. */
object Bytes {

    private const val HEX_DIGITS = "0123456789abcdef"

    /** Lowercase hex (`%02x` per byte), the only spelling any Snippets format writes. */
    fun toHex(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset): String {
        require(offset >= 0 && length >= 0 && offset + length <= bytes.size) { "range outside the array" }
        val out = CharArray(length * 2)
        for (index in 0 until length) {
            val byte = bytes[offset + index].toInt() and 0xFF
            out[index * 2] = HEX_DIGITS[byte ushr 4]
            out[index * 2 + 1] = HEX_DIGITS[byte and 0x0F]
        }
        return String(out)
    }

    /** Decodes hex of either case. `null` for an odd length or a non-hex character. */
    fun fromHex(text: CharSequence): ByteArray? = decodeHex(text, allowUppercase = true)

    /** Decodes hex that must be lowercase, for readers that require `text == lowercase(text)`. */
    fun fromLowercaseHex(text: CharSequence): ByteArray? = decodeHex(text, allowUppercase = false)

    private fun decodeHex(text: CharSequence, allowUppercase: Boolean): ByteArray? {
        if (text.length % 2 != 0) return null
        val out = ByteArray(text.length / 2)
        for (index in out.indices) {
            val high = hexValue(text[index * 2], allowUppercase)
            val low = hexValue(text[index * 2 + 1], allowUppercase)
            if (high < 0 || low < 0) return null
            out[index] = ((high shl 4) or low).toByte()
        }
        return out
    }

    private fun hexValue(character: Char, allowUppercase: Boolean): Int = when (character) {
        in '0'..'9' -> character - '0'
        in 'a'..'f' -> character - 'a' + 10
        in 'A'..'F' -> if (allowUppercase) character - 'A' + 10 else -1
        else -> -1
    }

    /**
     * Compares without an early exit on the first differing byte. Arrays of different
     * length are unequal; only the length, which is public in every format here, leaks.
     */
    fun constantTimeEquals(first: ByteArray, second: ByteArray): Boolean {
        if (first.size != second.size) return false
        var difference = 0
        for (index in first.indices) {
            difference = difference or (first[index].toInt() xor second[index].toInt())
        }
        return difference == 0
    }

    /** Best-effort zeroing of a buffer the caller owns. The JVM may still hold copies it made itself. */
    fun wipe(bytes: ByteArray?) {
        bytes?.fill(0)
    }

    fun wipe(characters: CharArray?) {
        characters?.fill('\u0000')
    }

    fun concat(vararg parts: ByteArray): ByteArray {
        var total = 0
        for (part in parts) total += part.size
        val out = ByteArray(total)
        var position = 0
        for (part in parts) {
            part.copyInto(out, position)
            position += part.size
        }
        return out
    }

    /** `u32be(value)`: four bytes, most significant first. */
    fun u32be(value: Int): ByteArray = byteArrayOf(
        (value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte(),
    )

    /** `u64be(value)`: eight bytes, most significant first. */
    fun u64be(value: Long): ByteArray = ByteArray(8) { index -> (value ushr (56 - 8 * index)).toByte() }

    /** `count` bytes from the system CSPRNG. */
    fun random(count: Int): ByteArray {
        require(count >= 0) { "count must not be negative" }
        return ByteArray(count).also(SystemRandom.instance::nextBytes)
    }

    /** One process-wide generator: `SecureRandom` is thread-safe and seeding one per call is wasteful. */
    private object SystemRandom {
        val instance = SecureRandom()
    }
}
