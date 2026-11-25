package com.khm.snippets.core.text

import java.nio.charset.StandardCharsets

/**
 * Reads the corpora that `tools/foundation-tables` generated from Foundation and the
 * Swift standard library (`src/test/resources/fixtures/foundation`). Strings in them are
 * space-separated scalar values, so no editor or terminal can change what a case means.
 */
object FoundationFixture {

    /** The tab-separated fields of every line that is not a `#` comment. */
    fun rows(name: String): List<List<String>> {
        val stream = FoundationFixture::class.java.getResourceAsStream("/fixtures/foundation/$name")
            ?: throw IllegalStateException("missing fixture $name; run tools/foundation-tables/regenerate.sh")
        return stream.bufferedReader(StandardCharsets.UTF_8).useLines { lines ->
            lines.filter { it.isNotEmpty() && !it.startsWith("#") }.map { it.split('\t') }.toList()
        }
    }

    /** `0061 0301` → the string; `-` → the empty string. */
    fun text(scalars: String): String {
        if (scalars == "-") return ""
        val out = StringBuilder()
        for (scalar in scalars.split(' ')) out.appendCodePoint(scalar.toInt(16))
        return out.toString()
    }

    /** A `;`-separated list of strings; the empty field is the empty list. */
    fun texts(field: String): List<String> = if (field.isEmpty()) emptyList() else field.split(';').map(::text)

    /** The inverse of [text], for failure messages. */
    fun scalars(text: String): String {
        if (text.isEmpty()) return "-"
        val out = StringBuilder()
        var index = 0
        while (index < text.length) {
            val scalar = text.codePointAt(index)
            if (out.isNotEmpty()) out.append(' ')
            out.append(scalar.toString(16).uppercase().padStart(4, '0'))
            index += Character.charCount(scalar)
        }
        return out.toString()
    }
}
