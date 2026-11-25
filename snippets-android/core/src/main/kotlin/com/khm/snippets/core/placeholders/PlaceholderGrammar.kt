package com.khm.snippets.core.placeholders

import com.khm.snippets.core.text.FoundationText

/**
 * The placeholder grammar (`PlaceholderResolver.swift`, `parsePlaceholder` and below).
 *
 * A candidate is `{…}` with no brace, CR or LF inside. Its body is one of:
 *
 * - `clipboard`
 * - `kind`, where kind is `date`, `time` or `datetime`
 * - `kind:FORMAT` with FORMAT made of `a-z A-Z 0-9 : _ -` only
 * - `kind "FORMAT"`, the spelling of old Raycast exports
 * - `kind` followed by one to three attributes, each once: `format="…"`, `locale="…"`
 *   (not together with `format`) and `offset=…`
 *
 * Anything else is not a placeholder and stays in the text as written. Names are
 * case-sensitive.
 *
 * Swift examines the body `Character` by `Character`, so a delimiter that carries a
 * combining mark is not a delimiter. The body is handled here as a list of `Character`s
 * for the same reason.
 */
internal object PlaceholderGrammar {

    const val ATTRIBUTE_TEXT_CHARACTERS = 1024
    const val FORMAT_CHARACTERS = 512
    const val LOCALE_CHARACTERS = 64
    const val OFFSET_TERMS = 8
    const val OFFSET_MAGNITUDE = 100_000
    const val MAXIMUM_ATTRIBUTES = 3

    enum class TemporalKind(val keyword: String) { DATE("date"), TIME("time"), DATETIME("datetime") }

    class Offset(val value: Int, val unit: DateRenderer.Unit)

    sealed class Parsed {
        object Clipboard : Parsed()

        class Temporal(
            val kind: TemporalKind,
            val format: String?,
            val localeIdentifier: String?,
            val offsets: List<Offset>,
        ) : Parsed()
    }

    /** `{`, a body without `{`, `}`, CR or LF, `}`: the regular expression `\{([^{}\r\n]*)\}`. */
    class Candidate(val start: Int, val end: Int) {
        fun body(template: String): String = template.substring(start + 1, end - 1)
    }

    /** Every candidate of [template], left to right. They never overlap. */
    inline fun forEachCandidate(template: String, action: (Candidate) -> Unit) {
        var index = template.indexOf('{')
        while (index >= 0) {
            var cursor = index + 1
            while (cursor < template.length) {
                val unit = template[cursor]
                if (unit == '{' || unit == '}' || unit == '\r' || unit == '\n') break
                cursor += 1
            }
            if (cursor >= template.length) return
            if (template[cursor] == '}') {
                action(Candidate(index, cursor + 1))
                index = template.indexOf('{', cursor + 1)
            } else if (template[cursor] == '{') {
                index = cursor
            } else {
                index = template.indexOf('{', cursor + 1)
            }
        }
    }

    /** The whole of [text] as one candidate, or `null`. */
    fun soleCandidateBody(text: String): String? {
        if (text.length < 2 || text[0] != '{' || text[text.length - 1] != '}') return null
        for (index in 1 until text.length - 1) {
            val unit = text[index]
            if (unit == '{' || unit == '}' || unit == '\r' || unit == '\n') return null
        }
        return text.substring(1, text.length - 1)
    }

    /**
     * `parsePlaceholder`.
     *
     * @param isAvailableLocale whether the platform knows a locale, given its core (see [localeCore]).
     */
    fun parse(body: String, isAvailableLocale: (String) -> Boolean): Parsed? {
        if (body == "clipboard") return Parsed.Clipboard
        if (!body.startsWith("date") && !body.startsWith("time")) return null
        // As written, not normalized: the format goes to the date formatter scalar for
        // scalar, and every delimiter is an ASCII character that nothing else equals.
        val characters = FoundationText.characters(body)

        for (kind in TemporalKind.entries) {
            val keyword = kind.keyword
            if (body == keyword) return Parsed.Temporal(kind, null, null, emptyList())
            if (!startsWith(characters, keyword)) continue
            val rest = characters.subList(keyword.length, characters.size)

            if (rest[0] == ":") {
                val format = join(rest, 1, rest.size)
                return if (isCompactFormat(format)) Parsed.Temporal(kind, format, null, emptyList()) else null
            }
            if (rest[0] != " ") continue

            // Old Raycast exports wrote `{date "…"}`. A body of exactly `date "` reads its
            // one quote as both the opening and the closing one; Swift traps on it, and
            // here it is not a placeholder.
            if (rest.size >= 2 && rest[1] == "\"" && rest[rest.size - 1] == "\"") {
                if (rest.size < 3) return null
                val format = join(rest, 2, rest.size - 1)
                return if (isExplicitFormat(format)) Parsed.Temporal(kind, format, null, emptyList()) else null
            }
            return parseTemporalAttributes(rest.subList(1, rest.size), kind, isAvailableLocale)
        }
        return null
    }

    private fun startsWith(characters: List<String>, keyword: String): Boolean {
        // One more Character must follow: the bare keyword was handled by the caller.
        if (characters.size <= keyword.length) return false
        for (index in keyword.indices) {
            val character = characters[index]
            if (character.length != 1 || character[0] != keyword[index]) return false
        }
        return true
    }

    private fun join(characters: List<String>, start: Int, end: Int): String {
        val out = StringBuilder()
        for (index in start until end) out.append(characters[index])
        return out.toString()
    }

    private class Attribute(val key: String, val value: List<String>, val wasQuoted: Boolean)

    private fun parseTemporalAttributes(
        text: List<String>,
        kind: TemporalKind,
        isAvailableLocale: (String) -> Boolean,
    ): Parsed.Temporal? {
        if (text.size > ATTRIBUTE_TEXT_CHARACTERS) return null
        val attributes = parseAttributes(text) ?: return null
        if (attributes.isEmpty() || attributes.size > MAXIMUM_ATTRIBUTES) return null

        var format: String? = null
        var localeIdentifier: String? = null
        var offsets: List<Offset> = emptyList()
        val seen = HashSet<String>()
        for (attribute in attributes) {
            if (!seen.add(attribute.key)) return null
            when (attribute.key) {
                "format" -> {
                    val value = join(attribute.value, 0, attribute.value.size)
                    if (!attribute.wasQuoted || !isExplicitFormat(attribute.value)) return null
                    format = value
                }
                "locale" -> {
                    val value = join(attribute.value, 0, attribute.value.size)
                    if (!attribute.wasQuoted || !isValidLocaleIdentifier(value, attribute.value.size, isAvailableLocale)) return null
                    localeIdentifier = value
                }
                "offset" -> offsets = parseOffsets(attribute.value) ?: return null
                else -> return null
            }
        }
        // A pattern fully specifies the output; a locale selects the localized default style.
        if (format != null && localeIdentifier != null) return null
        return Parsed.Temporal(kind, format, localeIdentifier, offsets)
    }

    /**
     * `key=value` pairs separated by spaces. A value is `"…"` (no escapes; spaces allowed)
     * or a run without spaces, and must be followed by a space or the end.
     */
    private fun parseAttributes(text: List<String>): List<Attribute>? {
        val attributes = ArrayList<Attribute>()
        var index = 0
        while (index < text.size) {
            while (index < text.size && text[index] == " ") index += 1
            if (index >= text.size) break

            val keyStart = index
            while (index < text.size && text[index] != "=" && text[index] != " ") index += 1
            if (index >= text.size || text[index] != "=" || keyStart == index) return null
            val key = join(text, keyStart, index)
            index += 1
            if (index >= text.size) return null

            val value: List<String>
            val wasQuoted: Boolean
            if (text[index] == "\"") {
                wasQuoted = true
                index += 1
                val valueStart = index
                while (index < text.size && text[index] != "\"") index += 1
                if (index >= text.size) return null
                value = text.subList(valueStart, index)
                index += 1
            } else {
                wasQuoted = false
                val valueStart = index
                while (index < text.size && text[index] != " ") index += 1
                if (valueStart == index) return null
                value = text.subList(valueStart, index)
            }
            if (index < text.size && text[index] != " ") return null
            attributes.add(Attribute(key, value, wasQuoted))
        }
        return attributes
    }

    /** One to eight terms separated by spaces: a sign, ASCII digits up to 100 000, and a unit. */
    private fun parseOffsets(value: List<String>): List<Offset>? {
        val terms = ArrayList<List<String>>()
        var termStart = -1
        for (index in 0..value.size) {
            val isSeparator = index == value.size || value[index] == " "
            if (isSeparator) {
                if (termStart >= 0) terms.add(value.subList(termStart, index))
                termStart = -1
            } else if (termStart < 0) {
                termStart = index
            }
        }
        if (terms.isEmpty() || terms.size > OFFSET_TERMS) return null

        val offsets = ArrayList<Offset>(terms.size)
        for (term in terms) {
            if (term.size < 3) return null
            val sign = term[0]
            if (sign != "+" && sign != "-") return null
            val unit = when (term[term.size - 1]) {
                "m" -> DateRenderer.Unit.MINUTE
                "h" -> DateRenderer.Unit.HOUR
                "d" -> DateRenderer.Unit.DAY
                "M" -> DateRenderer.Unit.MONTH
                "y" -> DateRenderer.Unit.YEAR
                else -> return null
            }
            var magnitude = 0
            for (index in 1 until term.size - 1) {
                val digit = term[index]
                if (digit.length != 1 || digit[0] !in '0'..'9') return null
                // Swift's `Int(digits)` fails on overflow; anything above the limit is refused anyway.
                magnitude = magnitude * 10 + (digit[0] - '0')
                if (magnitude > OFFSET_MAGNITUDE) return null
            }
            offsets.add(Offset(if (sign == "-") -magnitude else magnitude, unit))
        }
        return offsets
    }

    private fun isCompactFormat(format: String): Boolean {
        if (format.isEmpty()) return false
        for (unit in format) {
            val allowed = unit in 'a'..'z' || unit in 'A'..'Z' || unit in '0'..'9' || unit == ':' || unit == '_' || unit == '-'
            if (!allowed) return false
        }
        return true
    }

    private fun isExplicitFormat(format: String): Boolean = isExplicitFormat(FoundationText.characters(format))

    /**
     * 1 to 512 `Character`s, none of them `"`, `{`, `}`, CR or LF, and ICU's apostrophe
     * quoting balanced: `''` is a literal apostrophe and does not open or close a quote.
     */
    private fun isExplicitFormat(format: List<String>): Boolean {
        if (format.isEmpty() || format.size > FORMAT_CHARACTERS) return false
        for (character in format) {
            if (character == "\"" || character == "{" || character == "}" || character == "\n" || character == "\r" || character == "\r\n") return false
        }
        var index = 0
        var isInsideLiteral = false
        while (index < format.size) {
            if (format[index] != "'") {
                index += 1
            } else if (index + 1 < format.size && format[index + 1] == "'") {
                index += 2
            } else {
                isInsideLiteral = !isInsideLiteral
                index += 1
            }
        }
        return !isInsideLiteral
    }

    private val LOCALE_SYNTAX = Regex("^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$")

    private fun isValidLocaleIdentifier(identifier: String, characterCount: Int, isAvailableLocale: (String) -> Boolean): Boolean {
        if (identifier.isEmpty() || characterCount > LOCALE_CHARACTERS) return false
        // The pattern admits ASCII only, which also rules out `_`.
        if (!LOCALE_SYNTAX.matches(identifier)) return false
        return isAvailableLocale(localeCore(identifier))
    }

    /**
     * `localeCore`: the identifier with `_` as `-`, lowercased, and cut before `@` or
     * `-u-`: language, script and region without preferences.
     */
    fun localeCore(identifier: String): String {
        var normalized = identifier.replace('_', '-').lowercase(java.util.Locale.ROOT)
        val legacyOptions = normalized.indexOf('@')
        if (legacyOptions >= 0) normalized = normalized.substring(0, legacyOptions)
        val unicodeExtension = normalized.indexOf("-u-")
        if (unicodeExtension >= 0) normalized = normalized.substring(0, unicodeExtension)
        return normalized
    }

    /** `limitedPreview`: [value], or its first [characterLimit] `Character`s and a marker line. */
    fun limitedPreview(value: String, characterLimit: Int, truncatedMarker: String): String {
        if (characterLimit <= 0) return value
        val prefix = FoundationText.characterPrefix(value, characterLimit)
        return if (prefix.length == value.length) value else "$prefix\n... $truncatedMarker"
    }
}
