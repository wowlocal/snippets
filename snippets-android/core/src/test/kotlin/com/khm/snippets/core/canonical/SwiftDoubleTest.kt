package com.khm.snippets.core.canonical

import com.khm.snippets.core.crypto.Fixtures
import com.khm.snippets.core.crypto.SeededRandom
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.math.BigInteger
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Swift's `Double.description`, three ways:
 * 1. the frozen corpus of the Swift 6.2 runtime's own formatter (`swift-double-v1.tsv`,
 *    11 903 lines) and the literals of `snippets-linux/src/canonical.rs`;
 * 2. an exact reference written here with `BigInteger` rationals, which shares no code and
 *    no idea with the Schubfach implementation under test, over every power of two, every
 *    binade's edges, the tie family and a random stream;
 * 3. optionally a larger corpus printed by a local Swift toolchain (see [localSwiftCorpus]).
 */
class SwiftDoubleTest {

    // canonical.rs

    /** `independent_swift_runtime_reference_matches_every_float_byte`: every line, both directions. */
    @Test fun independentSwiftRuntimeReferenceMatchesEveryFloatByte() {
        val lines = Fixtures.text("fixtures/linux/swift-double-v1.tsv").lines().filter { it.isNotEmpty() }
        assertEquals(11_903, lines.size)
        for (line in lines) {
            val (bits, expected) = line.split('\t')
            val value = Double.fromBits(java.lang.Long.parseUnsignedLong(bits, 16))
            assertEquals(expected, SwiftDouble.description(value), "bits $bits")
            val parsed = CanonicalJson.parse(expected.toByteArray(Charsets.US_ASCII))
            val real = parsed as? JsonValue.Real ?: error("bits $bits parsed as ${parsed::class.simpleName}")
            assertEquals(value.toRawBits(), real.value.toRawBits(), "bits $bits")
        }
    }

    /** `float_spelling_preserves_negative_zero_and_swift_thresholds` */
    @Test fun floatSpellingPreservesNegativeZeroAndSwiftThresholds() {
        val spellings = listOf(
            0.0 to "0.0",
            -0.0 to "-0.0",
            1.0 to "1.0",
            1e-4 to "0.0001",
            1e-5 to "1e-05",
            1e15 to "1000000000000000.0",
            1e16 to "1e+16",
            Double.fromBits(1) to "5e-324",
        )
        for ((value, text) in spellings) assertEquals(text, SwiftDouble.description(value))

        var bits = 0x1234_5678_9abc_def0
        repeat(10_000) {
            bits = bits xor (bits shl 13)
            bits = bits xor (bits ushr 7)
            bits = bits xor (bits shl 17)
            val value = Double.fromBits(bits)
            if (value.isFinite()) {
                val encoded = SwiftDouble.description(value)
                val parsed = CanonicalJson.parse(encoded.toByteArray(Charsets.US_ASCII)).doubleOrNull!!
                assertEquals(value.toRawBits(), parsed.toRawBits(), encoded)
            }
        }
        assertFailsWith<CanonicalJson.Failure.NonFiniteNumber> { CanonicalJson.encode(JsonValue.Real(Double.NaN)) }
    }

    // Swift's layout rules

    /** Scientific exactly when the decimal exponent is below -4 or the magnitude is above 2^53. */
    @Test fun theSwitchBetweenPositionalAndScientificIsWhereSwiftPutsIt() {
        val spellings = listOf(
            9007199254740992.0 to "9007199254740992.0",          // 2^53 itself stays positional
            9007199254740994.0 to "9.007199254740994e+15",       // the next double does not
            9007199254740991.0 to "9007199254740991.0",
            -9007199254740992.0 to "-9007199254740992.0",
            -9007199254740994.0 to "-9.007199254740994e+15",
            1e16 to "1e+16",
            0.0001 to "0.0001",
            0.00012345 to "0.00012345",
            0.00009999 to "9.999e-05",
            123456.789 to "123456.789",
            100.0 to "100.0",
            0.5 to "0.5",
            1.5e-7 to "1.5e-07",
            1e22 to "1e+22",
            1e23 to "1e+23",
            1.2345678901234568e17 to "1.2345678901234568e+17",
            1e100 to "1e+100",
            1e-100 to "1e-100",
            Double.MAX_VALUE to "1.7976931348623157e+308",
            java.lang.Double.MIN_NORMAL to "2.2250738585072014e-308",
            Double.MIN_VALUE to "5e-324",
            Double.fromBits(2) to "1e-323",
            -Double.MIN_VALUE to "-5e-324",
            0.1 + 0.2 to "0.30000000000000004",
            812578800.123456 to "812578800.123456",
            807004800.0 to "807004800.0",
            9.5367431640625e-07 to "9.5367431640625e-07",
            144115188075855872.0 to "1.4411518807585587e+17",
        )
        for ((value, text) in spellings) assertEquals(text, SwiftDouble.description(value))
    }

    /**
     * The exact ties: `2^50 + 0.25` is as close to `…24.2` as to `…24.3`, and both read back
     * as it. Swift 6.4 prints the even digit; so must this. (JDK's own `Double.toString`
     * would print neither of the one-digit forms below at all.)
     */
    @Test fun anExactTieTakesTheEvenDigitAsSwiftDoes() {
        assertEquals("1125899906842624.2", SwiftDouble.description(1125899906842624.25))
        assertEquals("1125899906842624.8", SwiftDouble.description(1125899906842624.75))
        assertEquals("1125899906842625.2", SwiftDouble.description(1125899906842625.25))
        assertEquals("2251799813685247.8", SwiftDouble.description(2251799813685247.75))
        // Shortest means one digit when one digit round-trips, where Java insists on two.
        assertEquals("5e-324", SwiftDouble.description(4.9e-324))
        assertEquals("4.9E-324", (4.9e-324).toString())
    }

    /**
     * Below a power of two the next double is half as far away as the one above, so the
     * interval of decimals that read back is lopsided. For 255 powers of two that changes
     * the shortest digits; these 15 are spread across the range, with what Swift 6.4 prints.
     * Neither the frozen corpus nor the golden vectors happen to contain one.
     */
    @Test fun aPowerOfTwoUsesItsNarrowerLowerGapAsSwiftDoes() {
        val spellings: List<Pair<Long, String>> = listOf(
            0x0040000000000000 to "1.7800590868057611e-307",
            0x0640000000000000 to "1.4103081061443981e-278",
            0x0dd0000000000000 to "3.7492420347390774e-242",
            0x1080000000000000 to "3.2978681700337323e-229",
            0x1960000000000000 to "1.8386229439566682e-186",
            0x2160000000000000 to "6.256509672447191e-148",
            0x2930000000000000 to "2.6612249000050942e-110",
            0x3440000000000000 to "5.0978941156238473e-57",
            0x3e60000000000000 to "2.9802322387695312e-08",
            0x4ab0000000000000 to "5.986310706507379e+51",
            0x5500000000000000 to "2.7996809277222553e+101",
            0x5940000000000000 to "8.263199609878108e+121",
            0x6280000000000000 to "2.9484081443918292e+166",
            0x6fb0000000000000 to "9.703238076879431e+229",
            0x77f0000000000000 to "5.282945311356653e+269",
        )
        for ((bits, text) in spellings) {
            assertEquals(text, SwiftDouble.description(Double.fromBits(bits)), "bits %016x".format(bits))
            assertEquals("-$text", SwiftDouble.description(-Double.fromBits(bits)))
        }
    }

    @Test fun onlyFiniteValuesHaveASpelling() {
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertFailsWith<IllegalArgumentException> { SwiftDouble.description(value) }
        }
        assertFailsWith<IllegalArgumentException> { SwiftDouble.shortestDecimal(0.0) }
    }

    // The exact reference

    /** Every power of two there is (the asymmetric rounding intervals), with both neighbours. */
    @Test fun everyPowerOfTwoAndItsNeighboursMatchTheExactReference() {
        var checked = 0
        for (biased in 0..2046) {
            val base = biased.toLong() shl 52
            for (bits in longArrayOf(base, base + 1, base + 2, base - 1, base - 2, base or FRACTION_MASK, base or (FRACTION_MASK - 1))) {
                if (bits <= 0) continue
                assertMatchesReference(bits)
                checked += 1
            }
        }
        for (shift in 0 until 52) {
            for (bits in longArrayOf(1L shl shift, (1L shl shift) + 1, (1L shl shift) - 1)) {
                if (bits <= 0) continue
                assertMatchesReference(bits)
                checked += 1
            }
        }
        assertTrue(checked > 14_000)
    }

    /** Values whose exact decimal expansion ends in 5 one place past the shortest length. */
    @Test fun theTieFamilyMatchesTheExactReference() {
        val random = SeededRandom(0x71E5)
        var ties = 0
        for (exponent in 46..53) {
            repeat(3_000) {
                val bits = ((1023L + exponent) shl 52) or (random.next() and FRACTION_MASK)
                if (assertMatchesReference(bits)) ties += 1
            }
        }
        // The family really is exercised: about one value in four in [2^50, 2^51) is a tie.
        assertTrue(ties > 500, "only $ties exact ties met")
    }

    @Test fun powersOfTenAndTheirNeighboursMatchTheExactReference() {
        for (exponent in -323..308) {
            val bits = "1e$exponent".toDouble().toRawBits()
            for (delta in -3L..3L) if (bits + delta > 0) assertMatchesReference(bits + delta)
        }
    }

    @Test fun aRandomStreamMatchesTheExactReference() {
        val random = SeededRandom(0x5C0B_FAC4)
        var checked = 0
        while (checked < 40_000) {
            val bits = random.next() and Long.MAX_VALUE
            if (!Double.fromBits(bits).isFinite() || bits == 0L) continue
            assertMatchesReference(bits)
            checked += 1
        }
        // Timestamps as the app stores them: seconds since 2001 with a fractional part.
        repeat(10_000) {
            val seconds = java.lang.Long.remainderUnsigned(random.next(), 2_000_000_000L).toDouble()
            val fraction = java.lang.Long.remainderUnsigned(random.next(), 1_000_000L) / 1_000_000.0
            assertMatchesReference((seconds + fraction).toRawBits())
        }
    }

    /** The digits are the shortest that read back, for every value met above; this checks the reading-back directly. */
    @Test fun everySpellingReadsBackAsTheSameDouble() {
        val random = SeededRandom(0xBAC4)
        repeat(100_000) {
            val value = Double.fromBits(random.next())
            if (value.isFinite()) {
                val text = SwiftDouble.description(value)
                assertEquals(value.toRawBits(), text.toDouble().toRawBits(), text)
                assertTrue(text.contains('.') || text.contains('e'), text)
            }
        }
    }

    // The integer machinery, against exact arithmetic over the whole range it is used on

    @Test fun theFixedPointLogarithmsAreExactOverTheirWholeRange() {
        // floor(log10(2^e)) and floor(log10(3/4 * 2^e)) for every binary exponent of a double.
        for (e in -1074..971) {
            val k = SwiftDouble.floorLog10Pow2(e)
            assertTrue(compareScaled(BigInteger.ONE, e, k) >= 0 && compareScaled(BigInteger.ONE, e, k + 1) < 0, "2^$e, k=$k")
            val kThreeQuarters = SwiftDouble.floorLog10ThreeQuartersPow2(e)
            // 3/4 * 2^e = 3 * 2^(e-2)
            assertTrue(
                compareScaled(BigInteger.valueOf(3), e - 2, kThreeQuarters) >= 0 &&
                    compareScaled(BigInteger.valueOf(3), e - 2, kThreeQuarters + 1) < 0,
                "3/4 * 2^$e, k=$kThreeQuarters",
            )
            assertTrue(k in SwiftDouble.K_MIN..SwiftDouble.K_MAX && kThreeQuarters in SwiftDouble.K_MIN..SwiftDouble.K_MAX)
        }
        // floor(log2(10^e)) for every decimal exponent the table spans.
        for (e in -SwiftDouble.K_MAX..-SwiftDouble.K_MIN) {
            val r = SwiftDouble.floorLog2Pow10(e)
            // 2^r <= 10^e < 2^(r+1)
            assertTrue(compareScaled(BigInteger.ONE, r, e) <= 0 && compareScaled(BigInteger.ONE, r + 1, e) > 0, "10^$e, r=$r")
        }
    }

    /** `g = floor(10^-k / 2^r) + 1` with `2^125 <= 10^-k / 2^r < 2^126`, checked from the definition. */
    @Test fun thePowerTableHoldsTheDefinedApproximations() {
        for (k in SwiftDouble.K_MIN..SwiftDouble.K_MAX) {
            val high = SwiftDouble.powerHigh(k)
            val low = SwiftDouble.powerLow(k)
            assertTrue(high in (1L shl 62) until Long.MAX_VALUE && low >= 0, "k=$k")
            val g = BigInteger.valueOf(high).shiftLeft(63).add(BigInteger.valueOf(low))
            val r = SwiftDouble.floorLog2Pow10(-k) - 125
            // g - 1 <= 10^-k / 2^r < g
            assertTrue(compareScaled(g.subtract(BigInteger.ONE), r, -k) <= 0, "k=$k lower")
            assertTrue(compareScaled(g, r, -k) > 0, "k=$k upper")
        }
        // The two entries everyone can check by eye: 10^0 and 10^1, each one above an exact value.
        assertEquals(0x4000_0000_0000_0000L, SwiftDouble.powerHigh(0))
        assertEquals(1L, SwiftDouble.powerLow(0))
        assertEquals(0x5000_0000_0000_0000L, SwiftDouble.powerHigh(-1))
        assertEquals(1L, SwiftDouble.powerLow(-1))
    }

    @Test fun multiplyHighMatchesBigIntegerForNonNegativeOperands() {
        val random = SeededRandom(0x4D55)
        val edges = longArrayOf(0, 1, 2, 0xFFFF_FFFFL, 0x1_0000_0000L, Long.MAX_VALUE, Long.MAX_VALUE - 1, 1L shl 62)
        val operands = edges.toList() + List(2_000) { random.next() and Long.MAX_VALUE }
        for (x in operands) {
            for (y in operands.take(40)) {
                val expected = BigInteger.valueOf(x).multiply(BigInteger.valueOf(y)).shiftRight(64).toLong()
                assertEquals(expected, SwiftDouble.multiplyHigh(x, y), "$x * $y")
            }
        }
    }

    // A larger corpus from a real Swift toolchain, when one has been generated

    /**
     * Set `SNIPPETS_SWIFT_DOUBLE_CORPUS` to a file of `<16 hex digits of the bit pattern>\t<Double.description>`
     * lines to check every one of them. Used during the port with 2 090 221 lines printed
     * by Swift 6.4 (every binade's edges, powers of ten, ties, timestamps, 1.5 million random
     * patterns); the Swift vector emitter can produce the same file.
     */
    @Test fun localSwiftCorpus() {
        val path = System.getenv("SNIPPETS_SWIFT_DOUBLE_CORPUS")
        assumeTrue("no local Swift double corpus configured", path != null && File(path).isFile)
        var checked = 0
        File(path!!).useLines { lines ->
            for (line in lines) {
                if (line.isEmpty()) continue
                val tab = line.indexOf('\t')
                val value = Double.fromBits(java.lang.Long.parseUnsignedLong(line.substring(0, tab), 16))
                assertEquals(line.substring(tab + 1), SwiftDouble.description(value), "bits ${line.substring(0, tab)}")
                checked += 1
            }
        }
        println("Swift double corpus: $checked lines match")
        assertTrue(checked > 0)
    }

    // Reference

    /** Compares one value with the exact reference. Returns whether it was an exact tie. */
    private fun assertMatchesReference(bits: Long): Boolean {
        val value = Double.fromBits(bits)
        val expected = Reference.shortest(bits)
        val actual = SwiftDouble.shortestDecimal(value)
        val label = "bits %016x".format(bits)
        assertEquals(expected.digits, BigInteger.valueOf(actual.digits), label)
        assertEquals(expected.exponent, actual.exponent, label)
        // And the layout on top of the digits reads back as the same double.
        assertEquals(bits, SwiftDouble.description(value).toDouble().toRawBits(), label)
        return expected.wasTie
    }

    /** Sign of `mantissa * 2^binary - 10^decimal`, exactly. */
    private fun compareScaled(mantissa: BigInteger, binary: Int, decimal: Int): Int {
        var left = mantissa
        var right = BigInteger.ONE
        if (binary >= 0) left = left.shiftLeft(binary) else right = right.shiftLeft(-binary)
        if (decimal >= 0) right = right.multiply(BigInteger.TEN.pow(decimal)) else left = left.multiply(BigInteger.TEN.pow(-decimal))
        return left.compareTo(right)
    }

    /**
     * The definition, computed with exact rationals and no cleverness: of all decimals
     * inside the rounding interval of the double, the one with the fewest significant
     * digits; of several, the nearest to the double's exact value; of two equally near, the
     * one whose last digit is even.
     */
    private object Reference {

        class Result(val digits: BigInteger, val exponent: Int, val wasTie: Boolean)

        private val TEN = BigInteger.TEN
        private val powers = HashMap<Int, BigInteger>()
        private fun pow10(exponent: Int): BigInteger = powers.getOrPut(exponent) { TEN.pow(exponent) }

        fun shortest(bits: Long): Result {
            val magnitude = bits and Long.MAX_VALUE
            val biased = (magnitude ushr 52).toInt()
            val fraction = magnitude and FRACTION_MASK
            require(biased != 0x7FF && magnitude != 0L)
            val c = if (biased == 0) fraction else fraction or (1L shl 52)
            val q = if (biased == 0) -1074 else biased - 1075

            // value = c * 2^q. The doubles on either side are one unit of 2^q away, except
            // below a power of two (above the subnormal range), where the lower one is half
            // a unit away. The interval reaches half-way to each. Scaled by 4 to stay integral:
            val lowerGap = if (c == (1L shl 52) && biased > 1) 1L else 2L
            var value = BigInteger.valueOf(4 * c)
            var low = BigInteger.valueOf(4 * c - lowerGap)
            var high = BigInteger.valueOf(4 * c + 2)
            var denominator = BigInteger.ONE
            val shift = q - 2
            if (shift >= 0) {
                value = value.shiftLeft(shift); low = low.shiftLeft(shift); high = high.shiftLeft(shift)
            } else {
                denominator = denominator.shiftLeft(-shift)
            }
            // IEEE round-half-even: the ends themselves read back as this double only when its significand is even.
            val inclusive = (c and 1L) == 0L

            // order = floor(log10(value / denominator))
            var order = Math.floor(Math.log10(Double.fromBits(magnitude))).toInt()
            while (compare(value, denominator, order) < 0) order -= 1
            while (compare(value, denominator, order + 1) >= 0) order += 1

            for (count in 1..17) {
                val grid = order - count + 1     // candidates are multiples of 10^grid
                var numerator = value
                var lowScaled = low
                var highScaled = high
                var scale = denominator
                if (grid >= 0) {
                    scale = scale.multiply(pow10(grid))
                } else {
                    val factor = pow10(-grid)
                    numerator = numerator.multiply(factor); lowScaled = lowScaled.multiply(factor); highScaled = highScaled.multiply(factor)
                }
                val floor = numerator.divide(scale)
                val below = floor.multiply(scale)
                val above = below.add(scale)
                val belowIn = below.compareTo(lowScaled).let { it > 0 || (inclusive && it == 0) }
                val aboveIn = above.compareTo(highScaled).let { it < 0 || (inclusive && it == 0) }
                if (!belowIn && !aboveIn) continue

                val distanceBelow = numerator.subtract(below)
                val distanceAbove = above.subtract(numerator)
                val comparison = distanceBelow.compareTo(distanceAbove)
                val tie = belowIn && aboveIn && comparison == 0
                val takeBelow = when {
                    !aboveIn -> true
                    !belowIn -> false
                    comparison != 0 -> comparison < 0
                    else -> !floor.testBit(0)
                }
                var digits = if (takeBelow) floor else floor.add(BigInteger.ONE)
                var exponent = grid
                while (digits.mod(TEN).signum() == 0) {
                    digits = digits.divide(TEN)
                    exponent += 1
                }
                return Result(digits, exponent, tie)
            }
            error("no decimal of 17 digits round-trips %016x".format(bits))
        }

        /** Sign of `numerator / denominator - 10^exponent`. */
        private fun compare(numerator: BigInteger, denominator: BigInteger, exponent: Int): Int =
            if (exponent >= 0) numerator.compareTo(denominator.multiply(pow10(exponent)))
            else numerator.multiply(pow10(-exponent)).compareTo(denominator)
    }

    private companion object {
        const val FRACTION_MASK = (1L shl 52) - 1
    }
}
