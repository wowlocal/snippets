package com.khm.snippets.core.text

/**
 * `String.precomposedStringWithCanonicalMapping` on Apple platforms, which is
 * CoreFoundation's `CFStringNormalize(_, kCFStringNormalizationFormC)`. It is **not**
 * Unicode NFC, and Swift's `PassphraseKDF.derive` stretches exactly its output, so the
 * passphrase path must reproduce it to derive the key an Apple device derives. Use it there
 * and nowhere else; everything else follows the standard ([FoundationText.nfc]).
 *
 * Where it departs from NFC (all reproduced here):
 * - a Hangul syllable is never decomposed, so `AC00 11AB` stays as it is;
 * - conjoining jamo compose with off-by-one bounds (`L` up to U+1113, `V` up to U+1176,
 *   `T` from U+11A7 to U+11C3), giving wrong syllables, unassigned scalars, or a lone
 *   surrogate that the Swift string then reads as U+FFFD;
 * - a BMP mark looks its base up by the low 16 bits, so `10041 030A` becomes `00C5`;
 * - a class-0 scalar that decomposes into marks (U+0F73, U+0F75, U+0F81) is decomposed in
 *   place and never reordered with the marks before it;
 * - every mark of a run composes onto the run's first scalar, a class-0 scalar inside a
 *   decomposition does not block, and a decomposable mark that finds fewer than its share of
 *   CoreFoundation's 64-scalar buffer free is dropped.
 *
 * The function is CoreFoundation's, statement for statement, on a UTF-16 buffer edited in
 * place; the data (`foundation-precomposed.txt`) is measured from Foundation by
 * `tools/foundation-tables`, which also checks the same rule against Foundation on about
 * 39 million strings. `FoundationPrecomposedTest` replays all of them from their digests.
 *
 * Every array used for the text is wiped before it is dropped, so a passphrase never
 * outlives the call except in the array returned, which the caller owns and wipes.
 */
internal object FoundationPrecomposed {

    private const val SYLLABLE_BASE = 0xAC00
    private const val SYLLABLE_COUNT = 11172
    private const val BUFFER_LENGTH = 64
    private const val NONE = 0xFFFD

    internal class Tables(
        val decomposition: ScalarMap,
        val rank: RangeTable,
        /** `mark shl 21 or base`, sorted; the composite at the same index of [composites]. */
        val composeKeys: LongArray,
        val composites: IntArray,
        val nonBaseStarters: IntArray,
        val markSpaceKeys: IntArray,
        val markSpaceValues: IntArray,
    )

    private val tables: Tables by lazy(LazyThreadSafetyMode.PUBLICATION) {
        parse(FoundationTables.open("foundation-precomposed.txt"))
    }

    fun warmUp() {
        tables
    }

    internal fun parse(reader: TableReader): Tables {
        val decomposition = ScalarMap.Builder(2200)
        val rank = RangeTable.Builder(512)
        val composeKeys = ArrayList<Long>(1024)
        val composites = IntList(1024)
        val starters = IntList(64)
        val spaceKeys = IntList(8)
        val spaceValues = IntList(8)
        var section = ""
        var lastComposeKey = -1L
        while (true) {
            val first = reader.nextLine()
            if (first < 0) break
            if (first == '['.code) {
                section = reader.restOfLine()
                if (section !in SECTIONS) reader.fail("unexpected section $section")
                continue
            }
            when (section) {
                "[decomposition]" -> {
                    decomposition.begin(reader.hex())
                    while (reader.accept(' ')) decomposition.append(reader.hex())
                    if (decomposition.currentLength == 0) reader.fail("an empty decomposition")
                }
                "[rank]" -> {
                    val start = reader.range()
                    val end = reader.rangeEnd
                    reader.expect(' ')
                    val value = reader.decimal()
                    if (value !in 1..255) reader.fail("a rank outside 1...255")
                    rank.add(start, end, value)
                }
                "[compose]" -> {
                    val mark = reader.hex()
                    reader.expect(' ')
                    val base = reader.hex()
                    reader.expect(' ')
                    val composite = reader.hex()
                    if (mark < 0x10000 && base > 0xFFFF) reader.fail("a BMP mark with a base wider than 16 bits")
                    val key = (mark.toLong() shl 21) or base.toLong()
                    if (key <= lastComposeKey) reader.fail("compositions out of order")
                    lastComposeKey = key
                    composeKeys.add(key)
                    composites.add(composite)
                }
                "[nonbasestarter]" -> starters.add(reader.hex())
                "[markspace]" -> {
                    spaceKeys.add(reader.hex())
                    reader.expect(' ')
                    spaceValues.add(reader.decimal())
                }
                else -> reader.fail("data before the first section")
            }
            reader.endOfLine()
        }
        val starterArray = starters.toArray().also { it.sort() }
        return Tables(
            decomposition.build(), rank.build(), composeKeys.toLongArray(), composites.toArray(),
            starterArray, spaceKeys.toArray(), spaceValues.toArray(),
        )
    }

    private val SECTIONS = setOf("[decomposition]", "[rank]", "[compose]", "[nonbasestarter]", "[markspace]")

    /** The precomposed form of [text]; an unpaired surrogate in [text] is first read as U+FFFD, as Swift does. */
    fun precomposed(text: CharSequence): String {
        val characters = CharArray(text.length) { text[it] }
        val out = precomposed(characters)
        try {
            return String(out)
        } finally {
            characters.fill('\u0000')
            out.fill('\u0000')
        }
    }

    /** As [precomposed] on an array the caller owns; the result is a new array the caller wipes. */
    fun precomposed(text: CharArray): CharArray = Run(tables, text).result()

    /** One normalisation. Owns two scratch buffers and wipes them. */
    private class Run(private val tables: Tables, input: CharArray) {

        private var units = CharArray(maxOf(16, input.size + 8))
        private var count = 0
        private var mapped = IntArray(BUFFER_LENGTH)
        private var mappedLength = 0

        init {
            // A Swift string is well-formed: an unpaired surrogate is U+FFFD before anything else happens.
            var index = 0
            while (index < input.size) {
                val unit = input[index]
                if (Character.isHighSurrogate(unit) && index + 1 < input.size && Character.isLowSurrogate(input[index + 1])) {
                    units[count++] = unit
                    units[count++] = input[index + 1]
                    index += 2
                } else {
                    units[count++] = if (Character.isSurrogate(unit)) '�' else unit
                    index += 1
                }
            }
        }

        fun result(): CharArray {
            try {
                normalize()
                // Back to a Swift string: a lone surrogate the composition produced is U+FFFD.
                val out = CharArray(count)
                var index = 0
                while (index < count) {
                    val unit = units[index]
                    if (Character.isHighSurrogate(unit) && index + 1 < count && Character.isLowSurrogate(units[index + 1])) {
                        out[index] = unit
                        out[index + 1] = units[index + 1]
                        index += 2
                    } else {
                        out[index] = if (Character.isSurrogate(unit)) '�' else unit
                        index += 1
                    }
                }
                return out
            } finally {
                units.fill('\u0000')
                mapped.fill(0)
            }
        }

        // Tables

        private fun rank(value: Int): Int = tables.rank.valueAt(value)

        private fun isSyllable(value: Int): Boolean = value >= SYLLABLE_BASE && value < SYLLABLE_BASE + SYLLABLE_COUNT

        private fun isDecomposable(value: Int): Boolean = isSyllable(value) || tables.decomposition.indexOf(value) >= 0

        private fun isNonBaseStarter(value: Int): Boolean = tables.nonBaseStarters.binarySearch(value) >= 0

        /** `CFUniCharPrecomposeCharacter`; [NONE] when the pair does not compose. */
        private fun precompose(base: Int, mark: Int): Int {
            val key = if (mark < 0x10000) base and 0xFFFF else base
            val index = tables.composeKeys.binarySearch((mark.toLong() shl 21) or key.toLong())
            return if (index >= 0) tables.composites[index] else NONE
        }

        // UTF-16

        private fun isHigh(unit: Int) = unit in 0xD800..0xDBFF

        private fun isLow(unit: Int) = unit in 0xDC00..0xDFFF

        private fun pair(high: Int, low: Int) = ((high - 0xD800) shl 10) + (low - 0xDC00) + 0x10000

        private fun unit(position: Int): Int = units[position].code

        private fun charAt(position: Int): Int {
            val first = unit(position)
            if (isHigh(first) && position + 1 < count && isLow(unit(position + 1))) return pair(first, unit(position + 1))
            return first
        }

        // The run of scalars being normalised (`mappedCharacters`)

        private fun append(value: Int) {
            if (mappedLength == mapped.size) {
                val grown = mapped.copyOf(mapped.size * 2)
                mapped.fill(0)
                mapped = grown
            }
            mapped[mappedLength++] = value
        }

        private fun removeAt(index: Int) {
            System.arraycopy(mapped, index + 1, mapped, index, mappedLength - index - 1)
            mappedLength -= 1
            mapped[mappedLength] = 0
        }

        /** `CFUniCharDecomposeCharacter` into the run, with the room CoreFoundation allows; nothing when it does not fit. */
        private fun decompose(value: Int, room: Int) {
            if (value >= SYLLABLE_BASE && value <= SYLLABLE_BASE + SYLLABLE_COUNT) {
                val index = value - SYLLABLE_BASE
                val length = if (index % 28 != 0) 3 else 2
                if (length > room) return
                append(index / 588 + 0x1100)
                append((index % 588) / 28 + 0x1161)
                if (length == 3) append(index % 28 + 0x11A7)
                return
            }
            val entry = tables.decomposition.indexOf(value)
            if (entry < 0) return
            val start = tables.decomposition.start(entry)
            val end = tables.decomposition.end(entry)
            val spaceIndex = tables.markSpaceKeys.indexOf(value)
            val needed = if (spaceIndex >= 0) tables.markSpaceValues[spaceIndex] else end - start
            if (needed > room) return
            for (position in start until end) append(tables.decomposition.scalarAt(position))
        }

        /** `CFUniCharPrioritySort`: skip the leading class-0 scalars, then bubble by class. */
        private fun sortByClass() {
            var start = 0
            while (start < mappedLength && rank(mapped[start]) == 0) start += 1
            if (mappedLength - start <= 1) return
            var changes = true
            while (changes) {
                changes = false
                var p2 = rank(mapped[start])
                for (index in start + 1 until mappedLength) {
                    val p1 = p2
                    p2 = rank(mapped[index])
                    if (p1 > p2) {
                        val swap = mapped[index - 1]
                        mapped[index - 1] = mapped[index]
                        mapped[index] = swap
                        changes = true
                    }
                }
            }
        }

        /** Composes every scalar of the run that may onto its first one. */
        private fun composeRun() {
            if (mappedLength <= 1) return
            var current = mapped[0]
            var lastClass = 0
            var didCombine = false
            for (consumed in 1 until mappedLength) {
                val next = mapped[consumed]
                val currentClass = rank(next)
                if (lastClass == 0 || currentClass > lastClass) {
                    val composite = precompose(current, next)
                    if (composite == NONE) {
                        lastClass = currentClass
                    } else {
                        mapped[consumed] = NONE
                        didCombine = true
                        current = composite
                    }
                }
            }
            mapped[0] = current
            if (didCombine) {
                var index = mappedLength - 1
                while (index > 0) {
                    if (mapped[index] == NONE) removeAt(index)
                    index -= 1
                }
            }
        }

        /** Replaces `units[from, from + length)` with the run in UTF-16; returns its length. */
        private fun replace(from: Int, length: Int): Int {
            var width = 0
            for (index in 0 until mappedLength) width += if (mapped[index] > 0xFFFF) 2 else 1
            val newCount = count - length + width
            if (newCount > units.size) {
                val grown = units.copyOf(maxOf(newCount, units.size * 2))
                units.fill('\u0000')
                units = grown
            }
            System.arraycopy(units, from + length, units, from + width, count - from - length)
            if (newCount < count) units.fill('\u0000', newCount, count)
            count = newCount
            var position = from
            for (index in 0 until mappedLength) {
                val value = mapped[index]
                if (value > 0xFFFF) {
                    units[position++] = (((value - 0x10000) shr 10) + 0xD800).toChar()
                    units[position++] = (((value - 0x10000) and 0x3FF) + 0xDC00).toChar()
                } else {
                    units[position++] = value.toChar()
                }
            }
            return width
        }

        private fun normalize() {
            var currentIndex = 0
            var contents = 0
            while (contents < count) {
                var currentChar: Int
                var currentLength: Int
                if (isHigh(unit(contents)) && contents + 1 < count && isLow(unit(contents + 1))) {
                    currentChar = pair(unit(contents), unit(contents + 1))
                    currentLength = 2
                    contents += 2
                } else {
                    currentChar = unit(contents)
                    currentLength = 1
                    contents += 1
                }
                mappedLength = 0

                // A class-0 scalar that decomposes, except a Hangul syllable.
                if (isDecomposable(currentChar) && rank(currentChar) == 0) {
                    if (currentChar < SYLLABLE_BASE || currentChar > SYLLABLE_BASE + SYLLABLE_COUNT) {
                        decompose(currentChar, BUFFER_LENGTH)
                    }
                }

                if (contents < count || mappedLength == 0) {
                    if (mappedLength > 0) currentChar = charAt(contents)
                    if (rank(currentChar) != 0) {
                        val width = if (currentChar > 0xFFFF) 2 else 1
                        if (mappedLength == 0) {
                            // A mark: take the character before it into the run.
                            contents -= width
                            if (currentIndex > 0) {
                                if (isLow(unit(contents - 1)) && currentIndex > 1 && isHigh(unit(contents - 2))) {
                                    append(pair(unit(contents - 2), unit(contents - 1)))
                                    currentIndex -= 2
                                    currentLength += 2
                                } else {
                                    append(unit(contents - 1))
                                    currentIndex -= 1
                                    currentLength += 1
                                }
                            }
                        } else {
                            currentLength += width
                        }
                        contents += width

                        if (isDecomposable(currentChar)) decompose(currentChar, BUFFER_LENGTH - mappedLength) else append(currentChar)

                        while (contents < count) {
                            currentChar = charAt(contents)
                            if (rank(currentChar) == 0) break
                            if (currentChar > 0xFFFF) {
                                contents += 2
                                currentLength += 2
                            } else {
                                contents += 1
                                currentLength += 1
                            }
                            if (isDecomposable(currentChar)) decompose(currentChar, BUFFER_LENGTH - mappedLength) else append(currentChar)
                        }
                    }
                    if (mappedLength > 1) sortByClass()
                }

                if (mappedLength > 1) {
                    composeRun()
                } else if (currentChar >= 0x1100 && currentChar < 0x1100 + 0xFF) {
                    // Conjoining jamo, with CoreFoundation's bounds: `SInt8` for L, `<=` for every count.
                    val lIndex = (currentChar - 0x1100).toByte().toInt()
                    if (contents < count && lIndex in 0..19) {
                        val vIndex = unit(contents).toShort().toInt() - 0x1161
                        if (vIndex in 0..21) {
                            var tIndex = 0
                            contents += 1
                            currentLength += 1
                            if (contents < count) {
                                tIndex = unit(contents).toShort().toInt() - 0x11A7
                                if (tIndex < 0 || tIndex > 28) {
                                    tIndex = 0
                                } else {
                                    contents += 1
                                    currentLength += 1
                                }
                            }
                            mappedLength = 0
                            append((lIndex * 21 + vIndex) * 28 + tIndex + SYLLABLE_BASE)
                        }
                    }
                } else {
                    // Class-0 marks that compose onto the scalar before them.
                    while (contents < count) {
                        val next = charAt(contents)
                        if (!isNonBaseStarter(next) || rank(next) != 0) break
                        currentChar = precompose(currentChar, next)
                        if (currentChar == NONE) break
                        if (next < 0x10000) {
                            contents += 1
                            currentLength += 1
                        } else {
                            contents += 2
                            currentLength += 2
                        }
                        mappedLength = 0
                        append(currentChar)
                    }
                }

                if (mappedLength > 0) {
                    currentLength = replace(currentIndex, currentLength)
                    contents = currentIndex + currentLength
                }
                currentIndex += currentLength
            }
        }
    }
}
