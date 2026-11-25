package com.khm.snippets.core.placeholders

/**
 * The import-only rewrite of old Raycast placeholders (`RaycastPlaceholders.swift`).
 *
 * Old Raycast exports wrote `{date "…"}`, `{time "…"}` and `{datetime "…"}`. They become
 * `{date format="…"}`, the spelling Raycast uses now and [PlaceholderResolver] reads, but
 * only when the resolver can read the whole result back. Otherwise the old spelling is
 * left exactly as written: visibly foreign text is better than a token that looks native
 * and does nothing. Placeholders already in the current spelling pass through untouched.
 *
 * Only the import path calls this. The library codec must never know that the Raycast
 * dialect exists.
 */
object RaycastPlaceholders {

    private val LEGACY_TEMPORAL = Regex("""\{(date|time|datetime) "([^"]+)"\}""")

    /** `RaycastPlaceholders.converted`. */
    fun converted(text: String): String {
        if (text.indexOf('{') < 0) return text
        var converted: StringBuilder? = null
        var cursor = 0
        for (match in LEGACY_TEMPORAL.findAll(text)) {
            val body = "${match.groupValues[1]} format=\"${match.groupValues[2]}\""
            if (!isResolvableBody(body)) continue
            val out = converted ?: StringBuilder(text.length + 16).also { converted = it }
            out.append(text, cursor, match.range.first).append('{').append(body).append('}')
            cursor = match.range.last + 1
        }
        return converted?.append(text, cursor, text.length)?.toString() ?: text
    }

    // `PlaceholderResolver.isResolvablePlaceholder` for `{body}`. The body names no
    // locale, so the answer does not depend on which locales the platform has.
    private fun isResolvableBody(body: String): Boolean {
        for (unit in body) if (unit == '{' || unit == '}' || unit == '\r' || unit == '\n') return false
        return PlaceholderGrammar.parse(body) { false } != null
    }
}
