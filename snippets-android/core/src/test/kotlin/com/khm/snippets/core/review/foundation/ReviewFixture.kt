package com.khm.snippets.core.review.foundation

import java.util.zip.GZIPInputStream

/** Reviewer fixtures under `src/test/resources/fixtures/review-foundation`, recorded from the real Swift code. */
internal object ReviewFixture {

    fun rows(name: String): List<List<String>> {
        val stream = ReviewFixture::class.java.getResourceAsStream("/fixtures/review-foundation/$name")
            ?: throw IllegalStateException("missing reviewer fixture $name")
        val input = if (name.endsWith(".gz")) GZIPInputStream(stream) else stream
        return input.bufferedReader(Charsets.UTF_8).useLines { lines ->
            lines.filter { it.isNotEmpty() && !it.startsWith("#") }.map { it.split('\t') }.toList()
        }
    }

    fun unhex(text: String): ByteArray {
        if (text == "-") return ByteArray(0)
        return ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    fun hex(bytes: ByteArray): String = if (bytes.isEmpty()) "-" else bytes.joinToString("") { "%02x".format(it) }

    /** `0061 0301` gives the string; `-` gives empty. */
    fun text(scalars: String): String {
        if (scalars == "-") return ""
        val out = StringBuilder()
        for (scalar in scalars.split(' ')) out.appendCodePoint(scalar.toInt(16))
        return out.toString()
    }

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
