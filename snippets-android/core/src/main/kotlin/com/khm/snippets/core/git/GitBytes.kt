package com.khm.snippets.core.git

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest

// Small byte and text helpers private to the git package.

private const val HEX_DIGITS = "0123456789abcdef"

internal fun ByteArray.toLowerHex(): String {
    val out = CharArray(size * 2)
    for (index in indices) {
        val value = this[index].toInt() and 0xff
        out[2 * index] = HEX_DIGITS[value ushr 4]
        out[2 * index + 1] = HEX_DIGITS[value and 0x0f]
    }
    return String(out)
}

/** A hex digit of either case, or -1. */
internal fun hexValue(character: Int): Int = when (character) {
    in '0'.code..'9'.code -> character - '0'.code
    in 'a'.code..'f'.code -> character - 'a'.code + 10
    in 'A'.code..'F'.code -> character - 'A'.code + 10
    else -> -1
}

internal fun ByteArray.indexOfByte(value: Byte, from: Int = 0, until: Int = size): Int {
    for (index in from until until) if (this[index] == value) return index
    return -1
}

internal fun ByteArray.startsWithBytes(prefix: ByteArray, from: Int = 0, until: Int = size): Boolean {
    if (until - from < prefix.size) return false
    for (index in prefix.indices) if (this[from + index] != prefix[index]) return false
    return true
}

/** Lexicographic order on unsigned bytes: Kotlin's `Byte` is signed, git's order is not. */
internal fun compareUnsigned(left: ByteArray, right: ByteArray): Int {
    val common = minOf(left.size, right.size)
    for (index in 0 until common) {
        val difference = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
        if (difference != 0) return difference
    }
    return left.size - right.size
}

internal fun sha1(): MessageDigest = MessageDigest.getInstance("SHA-1")

/** Decodes like Swift's `String(decoding:as: UTF8.self)`: invalid bytes become U+FFFD. */
internal fun ByteArray.decodeUtf8Lossy(from: Int = 0, until: Int = size): String =
    String(this, from, until - from, Charsets.UTF_8)

/** The text, or null when the bytes are not valid UTF-8. */
internal fun ByteArray.decodeUtf8Strict(): String? = try {
    Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(this))
        .toString()
} catch (_: CharacterCodingException) {
    null
}

/**
 * Foundation's `CharacterSet.whitespacesAndNewlines`, which differs from Kotlin's
 * `Char.isWhitespace` (U+200B is in, U+001C...U+001F are out).
 */
private fun isFoundationWhitespaceOrNewline(character: Char): Boolean = when (character.code) {
    0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 -> true
    in 0x2000..0x200b -> true
    else -> false
}

internal fun String.trimFoundationWhitespace(): String {
    var start = 0
    var end = length
    while (start < end && isFoundationWhitespaceOrNewline(this[start])) start += 1
    while (end > start && isFoundationWhitespaceOrNewline(this[end - 1])) end -= 1
    return substring(start, end)
}

/** True when every scalar passes `allowed` and no surrogate is unpaired. */
internal inline fun String.allScalars(allowed: (Int) -> Boolean): Boolean {
    var index = 0
    while (index < length) {
        val scalar = codePointAt(index)
        if (scalar in 0xd800..0xdfff || !allowed(scalar)) return false
        index += Character.charCount(scalar)
    }
    return true
}

internal fun String.utf8Size(): Int = toByteArray(Charsets.UTF_8).size

/**
 * Foundation's `removingPercentEncoding` with the fallback the Apple and Linux code
 * share: a malformed escape or a result that is not UTF-8 leaves the text as it was.
 */
internal fun percentDecoded(text: String): String {
    if (!text.contains('%')) return text
    val source = text.toByteArray(Charsets.UTF_8)
    val out = ByteArray(source.size)
    var length = 0
    var index = 0
    while (index < source.size) {
        val byte = source[index]
        if (byte == '%'.code.toByte()) {
            val high = if (index + 1 < source.size) hexValue(source[index + 1].toInt()) else -1
            val low = if (index + 2 < source.size) hexValue(source[index + 2].toInt()) else -1
            if (high < 0 || low < 0) return text
            out[length++] = (high * 16 + low).toByte()
            index += 3
        } else {
            out[length++] = byte
            index += 1
        }
    }
    return out.copyOf(length).decodeUtf8Strict() ?: text
}

/** Accumulates a stream of unknown length without the doubling copies of a growing array. */
internal class ByteAccumulator(private val blockSize: Int = 64 * 1024) {
    private val blocks = ArrayList<ByteArray>()
    private var current = ByteArray(0)
    private var used = 0

    var size: Long = 0
        private set

    fun append(source: ByteArray, offset: Int, length: Int) {
        var from = offset
        var remaining = length
        while (remaining > 0) {
            if (used == current.size) {
                current = ByteArray(blockSize)
                blocks.add(current)
                used = 0
            }
            val count = minOf(remaining, current.size - used)
            System.arraycopy(source, from, current, used, count)
            used += count
            from += count
            remaining -= count
        }
        size += length
    }

    /** One contiguous copy. The accumulator must hold less than 2 GiB. */
    fun toByteArray(): ByteArray {
        check(size <= Int.MAX_VALUE) { "accumulated bytes exceed one array" }
        val out = ByteArray(size.toInt())
        var position = 0
        for ((index, block) in blocks.withIndex()) {
            val count = if (index == blocks.lastIndex) used else block.size
            System.arraycopy(block, 0, out, position, count)
            position += count
        }
        return out
    }
}
