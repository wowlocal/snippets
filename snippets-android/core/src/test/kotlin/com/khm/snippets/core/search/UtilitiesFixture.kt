package com.khm.snippets.core.search

import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Utf8
import java.nio.charset.StandardCharsets

/**
 * Reads the fixtures in `src/test/resources/fixtures/utilities`. They were emitted by
 * running the unmodified Swift sources (`generator/main.swift` there). Text fields are the
 * hex of their UTF-8 bytes, so no editor or terminal can change what a case means.
 */
object UtilitiesFixture {

    /** The lines that are not `#` comments. */
    fun lines(name: String): List<String> {
        val stream = UtilitiesFixture::class.java.getResourceAsStream("/fixtures/utilities/$name")
            ?: throw IllegalStateException("missing fixture $name; run fixtures/utilities/generator/regenerate.sh")
        return stream.bufferedReader(StandardCharsets.UTF_8).useLines { lines ->
            lines.filter { it.isNotEmpty() && !it.startsWith("#") }.toList()
        }
    }

    /** The tab-separated fields of every line that is not a `#` comment. */
    fun rows(name: String): List<List<String>> = lines(name).map { it.split('\t') }

    /** UTF-8 hex to text; `-` is the empty string. */
    fun text(hex: String): String {
        if (hex == "-") return ""
        val bytes = Bytes.fromHex(hex) ?: throw IllegalStateException("not hex: $hex")
        return Utf8.decodeStrict(bytes) ?: throw IllegalStateException("not UTF-8: $hex")
    }

    /** A `;`-separated list of [text]; `-` alone is the empty list. */
    fun texts(field: String): List<String> = if (field == "-") emptyList() else field.split(';').map(::text)

    /** For failure messages: the scalars of [text], which survive any terminal. */
    fun scalars(text: String): String {
        val out = StringBuilder("\"")
        var index = 0
        while (index < text.length) {
            val scalar = text.codePointAt(index)
            if (scalar in 0x20..0x7E) out.appendCodePoint(scalar) else out.append("\\u{").append(scalar.toString(16)).append('}')
            index += Character.charCount(scalar)
        }
        return out.append('"').toString()
    }
}
