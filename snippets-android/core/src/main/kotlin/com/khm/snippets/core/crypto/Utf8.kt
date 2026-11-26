package com.khm.snippets.core.crypto

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CoderResult
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * UTF-8 conversions with the behaviour of a Swift `String`.
 *
 * A Swift `String` is always well-formed Unicode: ill-formed input is repaired with
 * U+FFFD when the string is created, so `string.utf8` never fails. A Kotlin `String` is
 * UTF-16 code units and may hold an unpaired surrogate, which `toByteArray()` would turn
 * into `?`. Every place that feeds text into a hash, a KDF or an AAD goes through here
 * so that choice is made once.
 *
 * Bytes become text in two ways in Swift, and they differ in one byte order mark:
 * Foundation's `String(data:encoding: .utf8)` (and `String(bytes:encoding:)`) drops **one**
 * leading U+FEFF, the standard library's validating initialisers keep it. [decodeStrict]
 * is the first, [decodeKeepingByteOrderMark] the second; each call site follows the Swift
 * line it ports.
 */
object Utf8 {

    private const val BYTE_ORDER_MARK = '﻿'

    private val REPLACEMENT = byteArrayOf(0xEF.toByte(), 0xBF.toByte(), 0xBD.toByte())

    /** `Array(text.utf8)` in Swift: an unpaired surrogate becomes U+FFFD, as it does when Swift creates the string. */
    fun encode(text: CharSequence): ByteArray = encode(CharBuffer.wrap(text), strict = false)!!

    /** As [encode], reading a caller-owned array so no `String` has to exist. */
    fun encode(characters: CharArray): ByteArray = encode(CharBuffer.wrap(characters), strict = false)!!

    /** `null` when [text] holds an unpaired surrogate, for bytes that must round-trip exactly. */
    fun encodeStrict(text: CharSequence): ByteArray? = encode(CharBuffer.wrap(text), strict = true)

    /**
     * Encodes into one buffer of `3 × length` bytes, which is enough for any UTF-16 input
     * (a supplementary scalar is 2 units and 4 bytes; a replacement is 1 unit and 3), so the
     * encoder never abandons an outgrown buffer holding part of a passphrase. That buffer is
     * wiped; the result is an exact-length copy.
     */
    private fun encode(input: CharBuffer, strict: Boolean): ByteArray? {
        val action = if (strict) CodingErrorAction.REPORT else CodingErrorAction.REPLACE
        val encoder = StandardCharsets.UTF_8.newEncoder()
            .onMalformedInput(action)
            .onUnmappableCharacter(action)
        if (!strict) encoder.replaceWith(REPLACEMENT)
        val scratch = ByteArray(3 * input.remaining())
        try {
            val buffer = ByteBuffer.wrap(scratch)
            val result = encoder.encode(input, buffer, true)
            if (result.isError) return null
            check(!result.isOverflow) { "UTF-8 needs at most three bytes per UTF-16 unit" }
            val flushed: CoderResult = encoder.flush(buffer)
            check(!flushed.isOverflow) { "UTF-8 needs at most three bytes per UTF-16 unit" }
            return scratch.copyOf(buffer.position())
        } finally {
            scratch.fill(0)
        }
    }

    /**
     * Foundation's `String(data:encoding: .utf8)`: `null` for anything that is not
     * well-formed UTF-8 (over-long forms, surrogates, values above U+10FFFF, truncated
     * sequences), and **one** leading U+FEFF dropped (`EF BB BF 41` is `"A"`,
     * `EF BB BF EF BB BF 41` is `"\u{FEFF}A"`, measured on macOS 27.2).
     */
    fun decodeStrict(bytes: ByteArray): String? {
        val text = decodeKeepingByteOrderMark(bytes) ?: return null
        return if (text.isNotEmpty() && text[0] == BYTE_ORDER_MARK) text.substring(1) else text
    }

    /**
     * The standard library's `String(validating: bytes, as: UTF8.self)`: `null` for
     * ill-formed UTF-8, and a leading U+FEFF kept like any other scalar. What
     * `JSONDecoder` does for the text of a JSON string.
     */
    fun decodeKeepingByteOrderMark(bytes: ByteArray): String? {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }

    /** [text] without its leading U+FEFFs: a string Swift's `String(data:encoding:)` reads back as itself. */
    fun withoutLeadingByteOrderMarks(text: String): String {
        var start = 0
        while (start < text.length && text[start] == BYTE_ORDER_MARK) start += 1
        return if (start == 0) text else text.substring(start)
    }
}
