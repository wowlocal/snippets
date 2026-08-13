package com.khm.snippets.android

import androidx.compose.ui.graphics.Color
import java.text.Normalizer
import java.util.Locale

data class TagUsage(
    val tag: String,
    val key: String,
    val count: Int,
)

/** Matches the Apple clients' case- and diacritic-insensitive tag identity. */
fun tagFilterKey(tag: String): String {
    val decomposed = Normalizer.normalize(tag, Normalizer.Form.NFD)
    val withoutDiacritics = buildString(decomposed.length) {
        decomposed.forEach { character ->
            when (Character.getType(character)) {
                Character.NON_SPACING_MARK.toInt(),
                Character.COMBINING_SPACING_MARK.toInt(),
                Character.ENCLOSING_MARK.toInt() -> Unit
                else -> append(character)
            }
        }
    }
    // Uppercase-then-lowercase covers full folds used by Foundation, including ß -> ss
    // and both forms of Greek sigma -> σ, while the fixed locale avoids Turkish-I drift.
    return withoutDiacritics.uppercase(Locale.US).lowercase(Locale.US)
}

fun normalizedTags(rawTags: List<String>): List<String> {
    val seenKeys = mutableSetOf<String>()
    return buildList {
        rawTags.forEach { rawTag ->
            val tag = buildString(rawTag.length) {
                var pendingSeparator = false
                rawTag.forEach { character ->
                    if (character.isWhitespace() || Character.isSpaceChar(character)) {
                        pendingSeparator = isNotEmpty()
                    } else {
                        if (pendingSeparator) append(' ')
                        append(character)
                        pendingSeparator = false
                    }
                }
            }
            if (tag.isNotEmpty() && seenKeys.add(tagFilterKey(tag))) add(tag)
        }
    }
}

fun tagUsage(snippets: List<SnippetItem>): List<TagUsage> {
    val canonical = linkedMapOf<String, String>()
    val counts = mutableMapOf<String, Int>()
    snippets.forEach { snippet ->
        snippet.tags.forEach { tag ->
            val key = tagFilterKey(tag)
            canonical.putIfAbsent(key, tag)
            counts[key] = counts.getOrDefault(key, 0) + 1
        }
    }
    return canonical.map { (key, tag) -> TagUsage(tag, key, counts.getValue(key)) }
        .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.tag })
}

fun filterLibrary(
    snippets: List<SnippetItem>,
    query: String,
    activeTagKeys: Set<String>,
): List<SnippetItem> {
    val normalizedQuery = query.trim()
    return snippets.filter { snippet ->
        val snippetTagKeys = snippet.tags.mapTo(mutableSetOf(), ::tagFilterKey)
        val matchesEveryTag = activeTagKeys.all(snippetTagKeys::contains)
        val matchesQuery = normalizedQuery.isEmpty() ||
            listOf(snippet.name, snippet.keyword, snippet.content)
                .plus(snippet.tags)
                .any { it.contains(normalizedQuery, ignoreCase = true) }
        matchesEveryTag && matchesQuery
    }
}

/** FNV-1a is shared with iOS so the same normalized tag selects the same palette slot. */
fun tagColorIndex(tag: String): Int {
    var hash = -3_750_763_034_362_895_579L // UInt64 0xcbf29ce484222325.
    tagFilterKey(tag).toByteArray(Charsets.UTF_8).forEach { byte ->
        hash = hash xor (byte.toLong() and 0xff)
        hash *= 1_099_511_628_211L
    }
    return java.lang.Long.remainderUnsigned(hash, TAG_COLORS_LIGHT.size.toLong()).toInt()
}

fun tagAccentColor(tag: String, darkTheme: Boolean): Color =
    (if (darkTheme) TAG_COLORS_DARK else TAG_COLORS_LIGHT)[tagColorIndex(tag)]

private val TAG_COLORS_LIGHT = listOf(
    Color(0xFFBA1A1A), // red
    Color(0xFFA63C00), // orange
    Color(0xFF785900), // yellow
    Color(0xFF2D6A35), // green
    Color(0xFF006B5B), // mint
    Color(0xFF006A6A), // teal
    Color(0xFF00677A), // cyan
    Color(0xFF005AC1), // blue
    Color(0xFF4F56A9), // indigo
    Color(0xFF7B4E9D), // purple
    Color(0xFFA43A69), // pink
    Color(0xFF765847), // brown
)

private val TAG_COLORS_DARK = listOf(
    Color(0xFFFFB4AB),
    Color(0xFFFFB691),
    Color(0xFFF5C344),
    Color(0xFF91D69A),
    Color(0xFF76D9C3),
    Color(0xFF80D5D5),
    Color(0xFF5DD5EF),
    Color(0xFFA9C7FF),
    Color(0xFFBEC2FF),
    Color(0xFFE9B7FF),
    Color(0xFFFFB0CD),
    Color(0xFFE5BFA9),
)
