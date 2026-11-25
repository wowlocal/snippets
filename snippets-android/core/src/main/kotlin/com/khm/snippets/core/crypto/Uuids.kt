package com.khm.snippets.core.crypto

import java.util.UUID

/**
 * Strict UUID text and byte conversions.
 *
 * `java.util.UUID.fromString` accepts `1-1-1-1-1` and other short forms. Foundation's
 * `UUID(uuidString:)` does not: it wants exactly 8-4-4-4-12 hex digits, in either case.
 * Every Snippets format additionally fixes the case it writes (lowercase in envelopes,
 * AADs and Git files; uppercase where Foundation's `JSONEncoder` wrote the id), so the
 * case is always an explicit choice here.
 */
object Uuids {

    const val TEXT_LENGTH = 36
    const val BYTE_COUNT = 16

    /**
     * `UUID(uuidString:)`: exactly `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, hex of either case.
     *
     * One deliberate difference: Foundation reads the text as a C string, so it accepts a
     * valid id followed by an embedded NUL (observed with Swift 6.4). That is rejected here.
     */
    fun parse(text: CharSequence): UUID? = parse(text, allowUppercase = true, allowLowercase = true)

    /** As [parse], and the text must already be the lowercase form: `text == lowercase(parse(text))`. */
    fun parseLowercase(text: CharSequence): UUID? = parse(text, allowUppercase = false, allowLowercase = true)

    /** As [parse], and the text must already be the uppercase form Foundation's `uuidString` produces. */
    fun parseUppercase(text: CharSequence): UUID? = parse(text, allowUppercase = true, allowLowercase = false)

    private fun parse(text: CharSequence, allowUppercase: Boolean, allowLowercase: Boolean): UUID? {
        if (text.length != TEXT_LENGTH) return null
        var high = 0L
        var low = 0L
        var digits = 0
        for (index in 0 until TEXT_LENGTH) {
            val character = text[index]
            if (index == 8 || index == 13 || index == 18 || index == 23) {
                if (character != '-') return null
                continue
            }
            val value = when (character) {
                in '0'..'9' -> character - '0'
                in 'a'..'f' -> if (allowLowercase) character - 'a' + 10 else return null
                in 'A'..'F' -> if (allowUppercase) character - 'A' + 10 else return null
                else -> return null
            }
            if (digits < 16) high = (high shl 4) or value.toLong() else low = (low shl 4) or value.toLong()
            digits += 1
        }
        return UUID(high, low)
    }

    /** `uuidString.lowercased()`. */
    fun lowercase(id: UUID): String = id.toString()

    /** Foundation's `uuidString`, which is uppercase. */
    fun uppercase(id: UUID): String = id.toString().uppercase(java.util.Locale.ROOT)

    /** The 16 raw bytes in RFC 4122 order: the order of the hex digits in the text form. */
    fun toBytes(id: UUID): ByteArray = Bytes.concat(
        Bytes.u64be(id.mostSignificantBits), Bytes.u64be(id.leastSignificantBits),
    )

    fun fromBytes(bytes: ByteArray): UUID {
        require(bytes.size == BYTE_COUNT) { "a UUID is $BYTE_COUNT bytes, got ${bytes.size}" }
        var high = 0L
        var low = 0L
        for (index in 0 until 8) high = (high shl 8) or (bytes[index].toLong() and 0xFF)
        for (index in 8 until 16) low = (low shl 8) or (bytes[index].toLong() and 0xFF)
        return UUID(high, low)
    }
}
