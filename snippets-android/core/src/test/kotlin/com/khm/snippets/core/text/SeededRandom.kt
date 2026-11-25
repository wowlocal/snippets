package com.khm.snippets.core.text

import java.util.UUID

/**
 * xorshift64, the generator the Swift tests use (`ClockRandom`, `SeededRandom`), so a
 * ported property test walks the same values as its original and a failure reproduces.
 */
class SeededRandom(seed: Long) {

    private var state: Long = if (seed == 0L) -0x61C8864680B583EBL else seed // 0x9E3779B97F4A7C15

    /** A full 64-bit value; read it as unsigned. */
    fun next(): Long {
        state = state xor (state shl 13)
        state = state xor (state ushr 7)
        state = state xor (state shl 17)
        return state
    }

    /** `next() % bound` on unsigned values; 0 for a bound of 0. */
    fun below(bound: Long): Long = if (bound == 0L) 0L else java.lang.Long.remainderUnsigned(next(), bound)

    fun int(upperBound: Int): Int = if (upperBound <= 0) 0 else below(upperBound.toLong()).toInt()

    fun bool(): Boolean = next() and 1L == 0L

    fun <T> pick(options: List<T>): T = options[int(options.size)]

    /** `String(format: "%08x", UInt32(truncatingIfNeeded: next()))`. */
    fun deviceId(): String = (next() and 0xFFFF_FFFFL).toString(16).padStart(8, '0')

    /** Sixteen bytes from two draws, least significant byte first, as the Swift fixture builds a UUID. */
    fun uuid(): UUID {
        val a = next()
        val b = next()
        return UUID(java.lang.Long.reverseBytes(a), java.lang.Long.reverseBytes(b))
    }
}
