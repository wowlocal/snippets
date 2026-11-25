package com.khm.snippets.core.text

/**
 * `String.lowercased()` and `String.uppercased()` of the Swift standard library.
 *
 * Swift maps every scalar on its own and concatenates the results: no locale, and no
 * context, so a capital sigma always becomes `σ`, also at the end of a word. The JVM's
 * `lowercase(Locale.ROOT)` writes `ς` there, and it only knows the case pairs of the
 * runtime's Unicode version. The mappings here are Swift's own, measured by
 * `tools/foundation-tables`, which also checked the scalar-by-scalar rule against Swift.
 */
internal object SwiftCase {

    private class Tables(val lower: ScalarMap, val upper: ScalarMap)

    private val tables: Tables by lazy(LazyThreadSafetyMode.PUBLICATION) { load() }

    fun warmUp() {
        tables
    }

    private fun load(): Tables {
        val reader = FoundationTables.open("swift-case.txt")
        val lower = ScalarMap.Builder(2048)
        val upper = ScalarMap.Builder(2048)
        var current: ScalarMap.Builder? = null
        while (true) {
            val first = reader.nextLine()
            if (first < 0) break
            if (first == '['.code) {
                current = when (val heading = reader.restOfLine()) {
                    "[lower]" -> lower
                    "[upper]" -> upper
                    else -> reader.fail("unexpected section $heading")
                }
                continue
            }
            val map = current ?: reader.fail("data before the first section")
            map.begin(reader.hex())
            while (reader.accept(' ')) map.append(reader.hex())
            if (map.currentLength == 0) reader.fail("a scalar cannot map to nothing")
            reader.endOfLine()
        }
        val loaded = Tables(lower.build(), upper.build())
        check(loaded.lower.size > 0 && loaded.upper.size > 0) { "the case tables are empty" }
        return loaded
    }

    fun lowercased(text: String): String {
        // ASCII needs no table: only A-Z changes.
        var index = 0
        while (index < text.length && text[index].code < 0x80) index += 1
        if (index == text.length) return mapAscii(text, 'A', 'Z', 'a' - 'A')
        return map(text, tables.lower)
    }

    fun uppercased(text: String): String {
        var index = 0
        while (index < text.length && text[index].code < 0x80) index += 1
        if (index == text.length) return mapAscii(text, 'a', 'z', 'A' - 'a')
        return map(text, tables.upper)
    }

    private fun mapAscii(text: String, first: Char, last: Char, shift: Int): String {
        var index = 0
        while (index < text.length && text[index] !in first..last) index += 1
        if (index == text.length) return text
        val out = CharArray(text.length)
        for (position in text.indices) {
            val character = text[position]
            out[position] = if (character in first..last) character + shift else character
        }
        return String(out)
    }

    private fun map(text: String, table: ScalarMap): String {
        val out = StringBuilder(text.length + 8)
        var index = 0
        while (index < text.length) {
            // An unpaired surrogate reads as itself, has no entry and is copied.
            val scalar = text.codePointAt(index)
            index += Character.charCount(scalar)
            val entry = table.indexOf(scalar)
            if (entry < 0) {
                out.appendCodePoint(scalar)
            } else {
                for (position in table.start(entry) until table.end(entry)) out.appendCodePoint(table.scalarAt(position))
            }
        }
        return out.toString()
    }
}
