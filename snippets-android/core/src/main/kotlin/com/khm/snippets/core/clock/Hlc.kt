package com.khm.snippets.core.clock

import com.khm.snippets.core.text.FoundationText
import java.security.SecureRandom

/**
 * A hybrid logical clock reading (`HLC` in `HybridLogicalClock.swift`): wall-clock
 * milliseconds that only move forward, a counter for readings within one millisecond,
 * and the device that issued it.
 *
 * [string] is fixed-width lowercase hex, 12-4-8, and is the clock inside every sync
 * envelope: its bytes are hashed, so it is formatted and parsed here by hand. The order
 * of two readings is exactly the lexicographic order of their strings.
 */
class Hlc private constructor(
    /** Milliseconds since 1970, at most 48 bits. Swift holds it as `UInt64`; it is never negative here. */
    val wallMs: Long,
    /** 0…65535. Swift holds it as `UInt16`. */
    val counter: Int,
    /** Eight lowercase hex digits for every value this code creates. */
    val device: String,
) : Comparable<Hlc> {

    /** `HLC.string`: `%012llx-%04hx-%@`. */
    val string: String
        get() {
            val out = StringBuilder(WIRE_LENGTH)
            appendHex(out, wallMs, 12)
            out.append('-')
            appendHex(out, counter.toLong(), 4)
            out.append('-')
            out.append(device)
            return out.toString()
        }

    override fun toString(): String = string

    override fun compareTo(other: Hlc): Int {
        if (wallMs != other.wallMs) return if (wallMs < other.wallMs) -1 else 1
        if (counter != other.counter) return if (counter < other.counter) -1 else 1
        return FoundationText.compare(device, other.device)
    }

    override fun equals(other: Any?): Boolean =
        other is Hlc && wallMs == other.wallMs && counter == other.counter &&
            FoundationText.canonicalEquals(device, other.device)

    override fun hashCode(): Int = 31 * (31 * wallMs.hashCode() + counter) + FoundationText.nfc(device).hashCode()

    companion object {

        /**
         * The device of a record written by something with no clock of its own
         * (`HLC.foreignDevice`). Sorts below every real device id.
         */
        const val FOREIGN_DEVICE: String = "00000000"

        /** `wallMs` is cut off here, as in Swift's initializer. */
        const val MAX_WALL_MS: Long = AppleTime.MAX_HLC_MILLIS

        const val MAX_COUNTER: Int = 0xFFFF

        private const val WIRE_LENGTH = 26

        /**
         * `HLC(wallMs:counter:device:)`. [wallMs] is read as unsigned and cut off at 48
         * bits, so a negative `Long` is the largest reading; [device] goes through
         * [normalizedDevice].
         */
        fun of(wallMs: Long, counter: Int, device: String): Hlc {
            require(counter in 0..MAX_COUNTER) { "counter outside 0…65535" }
            val clamped = if (wallMs < 0 || wallMs > MAX_WALL_MS) MAX_WALL_MS else wallMs
            return Hlc(clamped, counter, normalizedDevice(device))
        }

        /** `HLC.foreign(updatedAt:)`: the clock of a record that arrived without one. */
        fun foreign(updatedAt: Double): Hlc = of(AppleTime.hlcMillis(updatedAt), 0, FOREIGN_DEVICE)

        /**
         * `HLC(parsing:)`: exactly 12 lowercase hex digits, `-`, 4, `-`, 8, as ASCII.
         * Uppercase, other digits and any other length give `null`; nothing is normalized,
         * because the spelling is part of a hashed envelope.
         */
        fun parse(raw: String): Hlc? {
            if (raw.length != WIRE_LENGTH) return null
            if (raw[12] != '-' || raw[17] != '-') return null
            var wall = 0L
            for (index in 0 until 12) {
                val digit = lowercaseHexValue(raw[index])
                if (digit < 0) return null
                wall = (wall shl 4) or digit.toLong()
            }
            var counter = 0
            for (index in 13 until 17) {
                val digit = lowercaseHexValue(raw[index])
                if (digit < 0) return null
                counter = (counter shl 4) or digit
            }
            for (index in 18 until WIRE_LENGTH) {
                if (lowercaseHexValue(raw[index]) < 0) return null
            }
            return Hlc(wall, counter, raw.substring(18))
        }

        /** `HLC.isCanonicalDeviceID`: exactly eight ASCII characters from `0-9a-f`. */
        fun isCanonicalDeviceId(raw: String): Boolean =
            raw.length == 8 && raw.all { lowercaseHexValue(it) >= 0 }

        /**
         * `HLC.normalizedDevice`: lowercase, keep the hex digits, then the first eight or
         * zero-padded on the left to eight. All zeroes is reserved for [FOREIGN_DEVICE], so
         * any other input that would land there becomes `00000001`.
         *
         * Swift filters with `Character.isHexDigit`, which also accepts the fullwidth forms
         * (U+FF10…, U+FF21…, U+FF41…) and leaves them as they are. That is reproduced: such
         * input yields a device that [isCanonicalDeviceId] rejects, as it does in Swift.
         */
        fun normalizedDevice(raw: String): String {
            val digits = ArrayList<String>(8)
            for (character in FoundationText.characters(FoundationText.swiftLowercased(raw))) {
                if (isSwiftHexDigit(character)) digits.add(character)
            }
            val padded = StringBuilder(8)
            if (digits.size >= 8) {
                for (index in 0 until 8) padded.append(digits[index])
            } else {
                repeat(8 - digits.size) { padded.append('0') }
                for (digit in digits) padded.append(digit)
            }
            val result = padded.toString()
            return if (result == FOREIGN_DEVICE && raw != FOREIGN_DEVICE) "00000001" else result
        }

        /** `HLC.makeDeviceID`: a random device id that is never [FOREIGN_DEVICE]. */
        fun makeDeviceId(random: java.util.Random = SecureRandom()): String {
            var value = random.nextInt()
            if (value == 0) value = 1
            val out = StringBuilder(8)
            appendHex(out, value.toLong() and 0xFFFF_FFFFL, 8)
            return out.toString()
        }

        private fun lowercaseHexValue(character: Char): Int = when (character) {
            in '0'..'9' -> character - '0'
            in 'a'..'f' -> character - 'a' + 10
            else -> -1
        }

        // `Character.isHexDigit`: one scalar, ASCII or fullwidth, of either case.
        private fun isSwiftHexDigit(character: String): Boolean {
            if (character.length != 1) return false
            return when (character[0]) {
                in '0'..'9', in 'a'..'f', in 'A'..'F' -> true
                in '０'..'９', in 'Ａ'..'Ｆ', in 'ａ'..'ｆ' -> true
                else -> false
            }
        }

        private fun appendHex(out: StringBuilder, value: Long, width: Int) {
            for (shift in (width - 1) * 4 downTo 0 step 4) {
                out.append("0123456789abcdef"[((value ushr shift) and 0xF).toInt()])
            }
        }
    }
}
