package com.khm.snippets.core.canonical

import java.math.BigInteger

/**
 * Formats a finite IEEE-754 double exactly as Swift's `Double.description` does.
 *
 * Canonical JSON prints timestamps with it, and those bytes are hashed: one different
 * digit makes every record fail its hash on the other platform. `Double.toString()` is
 * no substitute (`1.0E16`, other thresholds, and at least two digits where Swift prints one).
 *
 * Two steps, as in Swift:
 * 1. The shortest decimal that reads back as the same double; among several of that
 *    length, the one nearest the exact value; on an exact tie, the even last digit.
 * 2. Swift's layout: `0.0` / `-0.0` for zero; scientific (`d[.ddd]e±XX`, sign always, at
 *    least two exponent digits) when the decimal exponent is below -4 or the magnitude is
 *    above 2^53; otherwise positional with at least one digit on each side of the point.
 *
 * Step 1 is Raffaello Giulietti's Schubfach algorithm ("The Schubfach way to render
 * doubles", 2020), the one behind `Double.toString` since JDK 19, with one change: the JDK
 * never returns fewer than two digits (`4.9E-324`), Swift does (`5e-324`), so the shorter
 * candidate is always considered here. The powers of ten it needs are computed once, exactly.
 */
object SwiftDouble {

    /** The value is `digits * 10^exponent`; [digits] is positive and does not end in zero. */
    class Decimal internal constructor(val digits: Long, val exponent: Int)

    /** `value.description` in Swift. Finite values only: canonical JSON has no spelling for the others. */
    fun description(value: Double): String {
        require(value.isFinite()) { "only a finite double has a canonical spelling" }
        val bits = value.toRawBits()
        val negative = bits < 0
        if ((bits and Long.MAX_VALUE) == 0L) return if (negative) "-0.0" else "0.0"

        val decimal = shortestDecimal(value)
        val digits = decimal.digits.toString()
        // d1.d2…dn × 10^order
        val order = decimal.exponent + digits.length - 1

        val out = StringBuilder(digits.length + 8)
        if (negative) out.append('-')
        if (order < -4 || Math.abs(value) > TWO_POW_53) {
            out.append(digits[0])
            if (digits.length > 1) out.append('.').append(digits, 1, digits.length)
            out.append('e').append(if (order < 0) '-' else '+')
            val magnitude = Math.abs(order)
            if (magnitude < 10) out.append('0')
            out.append(magnitude)
        } else {
            val point = order + 1
            when {
                point <= 0 -> {
                    out.append("0.")
                    repeat(-point) { out.append('0') }
                    out.append(digits)
                }
                point >= digits.length -> {
                    out.append(digits)
                    repeat(point - digits.length) { out.append('0') }
                    out.append(".0")
                }
                else -> out.append(digits, 0, point).append('.').append(digits, point, digits.length)
            }
        }
        return out.toString()
    }

    /** Step 1 alone, for the magnitude of a finite non-zero [value]. */
    fun shortestDecimal(value: Double): Decimal {
        require(value.isFinite() && value != 0.0) { "only a finite non-zero double has shortest digits" }
        val bits = value.toRawBits()
        val fraction = bits and FRACTION_MASK
        val biasedExponent = ((bits ushr (P - 1)) and EXPONENT_MASK).toInt()
        // value = c * 2^q
        val q: Int
        val c: Long
        if (biasedExponent > 0) {
            q = Q_MIN - 1 + biasedExponent
            c = C_MIN or fraction
        } else {
            q = Q_MIN
            c = fraction
        }

        // All comparisons below are on values scaled by 4, so the interval ends are integers.
        val out = (c and 1).toInt()            // 1 when the ends of the rounding interval are excluded
        val cb = c shl 2
        val cbr = cb + 2
        val cbl: Long
        val k: Int
        // k = floor(log10(width of the rounding interval)): 10^k is the finest useful grid.
        if (c != C_MIN || q == Q_MIN) {
            cbl = cb - 2
            k = floorLog10Pow2(q)
        } else {
            // A power of two: the gap below is half the gap above.
            cbl = cb - 1
            k = floorLog10ThreeQuartersPow2(q)
        }
        val h = q + floorLog2Pow10(-k) + 2

        val g1 = POWERS[(k - K_MIN) shl 1]
        val g0 = POWERS[((k - K_MIN) shl 1) or 1]
        // vb = 4 * value / 10^k and its interval ends, each rounded to odd so that
        // comparing them with integers gives the exact answer.
        val vb = roundToOdd(g1, g0, cb shl h)
        val vbl = roundToOdd(g1, g0, cbl shl h)
        val vbr = roundToOdd(g1, g0, cbr shl h)

        val s = vb shr 2
        // The interval is narrower than 10 * 10^k, so it holds at most one multiple of
        // 10^(k+1). If it holds one, that is the only candidate with fewer digits.
        val sp10 = s / 10 * 10
        val tp10 = sp10 + 10
        val lowerShortIn = vbl + out <= sp10 shl 2
        val upperShortIn = (tp10 shl 2) + out <= vbr
        if (lowerShortIn != upperShortIn) return stripped(if (lowerShortIn) sp10 else tp10, k)

        // Otherwise s and s + 1 bracket the value on the 10^k grid and at least one is inside.
        val t = s + 1
        val lowerIn = vbl + out <= s shl 2
        val upperIn = (t shl 2) + out <= vbr
        if (lowerIn != upperIn) return stripped(if (lowerIn) s else t, k)
        // Both inside (they are never both outside): the nearer one, and the even one on an exact tie.
        val comparison = vb - ((s + t) shl 1)
        return stripped(if (comparison < 0 || (comparison == 0L && (s and 1L) == 0L)) s else t, k)
    }

    private fun stripped(digits: Long, exponent: Int): Decimal {
        var f = digits
        var e = exponent
        while (f % 10 == 0L) {
            f /= 10
            e += 1
        }
        return Decimal(f, e)
    }

    private const val TWO_POW_53 = 9_007_199_254_740_992.0

    /** Significand precision of binary64. */
    private const val P = 53
    private const val FRACTION_MASK = (1L shl (P - 1)) - 1
    private const val EXPONENT_MASK = 0x7FFL

    /** Exponent of the smallest subnormal as an integer significand: `MIN_VALUE = 1 * 2^Q_MIN`. */
    private const val Q_MIN = -1074

    /** Smallest normal significand. */
    private const val C_MIN = 1L shl (P - 1)

    /** Range of k over all doubles: `floor(log10(2^-1074))` … `floor(log10(2^971))`. */
    internal const val K_MIN = -324
    internal const val K_MAX = 292

    // floor(log10(2^e)), floor(log10(3/4 * 2^e)) and floor(log2(10^e)) as fixed-point
    // multiplications. `SwiftDoubleTest` checks each against exact arithmetic over the
    // whole range used here.
    private const val LOG10_2_Q41 = 661_971_961_083L          // floor(log10(2) * 2^41)
    private const val LOG10_3_4_Q41 = -274_743_187_321L       // floor(log10(3/4) * 2^41)
    private const val LOG2_10_Q38 = 913_124_641_741L          // floor(log2(10) * 2^38)

    internal fun floorLog10Pow2(e: Int): Int = ((e * LOG10_2_Q41) shr 41).toInt()

    internal fun floorLog10ThreeQuartersPow2(e: Int): Int = ((e * LOG10_2_Q41 + LOG10_3_4_Q41) shr 41).toInt()

    internal fun floorLog2Pow10(e: Int): Int = ((e * LOG2_10_Q38) shr 38).toInt()

    /**
     * For each k in [K_MIN]…[K_MAX], the 126-bit `g = floor(beta) + 1` where
     * `10^-k = beta * 2^r` and `2^125 <= beta < 2^126`, stored as two 63-bit halves
     * `g1`, `g0` (`g = g1 * 2^63 + g0`).
     */
    private val POWERS: LongArray = LongArray((K_MAX - K_MIN + 1) * 2).also { table ->
        val mask63 = BigInteger.ONE.shiftLeft(63).subtract(BigInteger.ONE)
        for (k in K_MIN..K_MAX) {
            val floorBeta = if (k <= 0) {
                val power = BigInteger.TEN.pow(-k)
                val shift = power.bitLength() - 126
                if (shift <= 0) power.shiftLeft(-shift) else power.shiftRight(shift)
            } else {
                val power = BigInteger.TEN.pow(k)
                BigInteger.ONE.shiftLeft(125 + power.bitLength()).divide(power)
            }
            val g = floorBeta.add(BigInteger.ONE)
            table[(k - K_MIN) shl 1] = g.shiftRight(63).toLong()
            table[((k - K_MIN) shl 1) or 1] = g.and(mask63).toLong()
        }
    }

    internal fun powerHigh(k: Int): Long = POWERS[(k - K_MIN) shl 1]

    internal fun powerLow(k: Int): Long = POWERS[((k - K_MIN) shl 1) or 1]

    /** `floor(g * cp / 2^127)`, with the lowest bit set when anything was discarded. All operands are below 2^63. */
    private fun roundToOdd(g1: Long, g0: Long, cp: Long): Long {
        val x1 = multiplyHigh(g0, cp)
        val y0 = g1 * cp
        val y1 = multiplyHigh(g1, cp)
        val z = (y0 ushr 1) + x1
        val vbp = y1 + (z ushr 63)
        return vbp or (((z and Long.MAX_VALUE) + Long.MAX_VALUE) ushr 63)
    }

    /** The high 64 bits of the 128-bit product of two non-negative longs. `Math.multiplyHigh` needs API 31. */
    internal fun multiplyHigh(x: Long, y: Long): Long {
        val x1 = x ushr 32
        val x0 = x and 0xFFFF_FFFFL
        val y1 = y ushr 32
        val y0 = y and 0xFFFF_FFFFL
        val low = x0 * y0
        val middle1 = x1 * y0 + (low ushr 32)
        val middle2 = x0 * y1 + (middle1 and 0xFFFF_FFFFL)
        return x1 * y1 + (middle1 ushr 32) + (middle2 ushr 32)
    }
}
