package com.khm.snippets.core.crypto

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
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
 */
object Utf8 {

    private val REPLACEMENT = byteArrayOf(0xEF.toByte(), 0xBF.toByte(), 0xBD.toByte())

    /** `Array(text.utf8)` in Swift: an unpaired surrogate becomes U+FFFD, as it does when Swift creates the string. */
    fun encode(text: CharSequence): ByteArray = encode(CharBuffer.wrap(text), strict = false)!!

    /** As [encode], reading a caller-owned array so no `String` has to exist. */
    fun encode(characters: CharArray): ByteArray = encode(CharBuffer.wrap(characters), strict = false)!!

    /** `null` when [text] holds an unpaired surrogate, for bytes that must round-trip exactly. */
    fun encodeStrict(text: CharSequence): ByteArray? = encode(CharBuffer.wrap(text), strict = true)

    private fun encode(input: CharBuffer, strict: Boolean): ByteArray? {
        val action = if (strict) CodingErrorAction.REPORT else CodingErrorAction.REPLACE
        val encoder = StandardCharsets.UTF_8.newEncoder()
            .onMalformedInput(action)
            .onUnmappableCharacter(action)
        if (!strict) encoder.replaceWith(REPLACEMENT)
        val buffer: ByteBuffer = try {
            encoder.encode(input)
        } catch (_: CharacterCodingException) {
            return null
        }
        val out = ByteArray(buffer.remaining())
        buffer.get(out)
        // The encoder's scratch buffer may hold a passphrase or a snippet body.
        if (buffer.hasArray()) buffer.array().fill(0)
        return out
    }

    /**
     * `String(data:encoding: .utf8)`: `null` for anything that is not well-formed UTF-8
     * (over-long forms, surrogates, values above U+10FFFF, truncated sequences).
     */
    fun decodeStrict(bytes: ByteArray): String? {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {
            null
        }
    }
}
