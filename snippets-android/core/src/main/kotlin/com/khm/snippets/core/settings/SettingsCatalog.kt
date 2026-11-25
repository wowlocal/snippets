package com.khm.snippets.core.settings

import com.khm.snippets.core.search.SwiftStrings
import com.khm.snippets.core.text.FoundationText

/** A settings screen: something a search result can lead to. */
interface SettingsScreen {
    /** The title shown for the screen and searched as part of each of its rows. */
    val title: String
}

/** A titled group of screens in the settings navigation. */
data class SettingsNavigationSection<D : SettingsScreen>(val title: String, val destinations: List<D>)

/**
 * One searchable settings row.
 *
 * @property rowId what the app scrolls to or highlights.
 * @property detail the second line of a search result; the Swift catalog uses the screen's title.
 * @property keywords further vocabulary the row is found by. Never shown.
 */
data class SettingsSearchEntry<R, D : SettingsScreen>(
    val rowId: R,
    val title: String,
    val detail: String?,
    val destination: D,
    val keywords: List<String>,
)

/**
 * The settings navigation and its search (`SettingsCatalog.swift`), independent of any UI
 * toolkit and of which rows an app has.
 *
 * Search runs over a fixed product vocabulary only. No user content and no runtime state
 * goes in, which keeps settings search safe for a library with secure snippets.
 *
 * The rows and screens are the app's: [SnippetsSettings] holds the ones of the Mac and iOS
 * apps, and an Android app builds its own catalog the same way.
 */
class SettingsCatalog<R, D : SettingsScreen>(
    val navigationSections: List<SettingsNavigationSection<D>>,
    entries: List<SettingsSearchEntry<R, D>>,
) {

    val entries: List<SettingsSearchEntry<R, D>> = entries.toList()

    private class Indexed<R, D : SettingsScreen>(
        val entry: SettingsSearchEntry<R, D>,
        val title: String,
        val destination: String,
        val keywords: List<String>,
        val searchable: String,
    )

    private val indexed: List<Indexed<R, D>> = this.entries.map { entry ->
        val title = normalized(entry.title)
        val destination = normalized(entry.destination.title)
        val keywords = entry.keywords.map(::normalized)
        Indexed(entry, title, destination, keywords, FoundationText.nfc((listOf(title, destination) + keywords).joinToString(" ")))
    }

    /**
     * `SettingsCatalog.search`. The query is folded and split at whitespace; a row matches
     * when every token is part of its title, its screen's title or a keyword. Per token a
     * row scores [SCORE_TITLE_EQUALS] when its title is the token, else [SCORE_TITLE_PREFIX]
     * when its title starts with it, else [SCORE_TITLE_CONTAINS], else
     * [SCORE_DESTINATION_PREFIX] when its screen's title starts with it, else
     * [SCORE_KEYWORD_PREFIX] when a keyword does, else [SCORE_OTHER]. Best first; equal
     * scores by screen title, then by row title.
     */
    fun search(query: String): List<SettingsSearchEntry<R, D>> {
        val tokens = SwiftStrings.split(normalized(query), SwiftStrings::isWhitespaceCharacter)
        if (tokens.isEmpty()) return emptyList()

        class Scored(val row: Indexed<R, D>, val score: Int)

        val scored = ArrayList<Scored>()
        for (row in indexed) {
            if (!tokens.all { SwiftStrings.containsNormalized(row.searchable, it) }) continue
            var score = 0
            for (token in tokens) {
                score += when {
                    row.title == token -> SCORE_TITLE_EQUALS
                    SwiftStrings.hasPrefix(row.title, token) -> SCORE_TITLE_PREFIX
                    SwiftStrings.containsNormalized(row.title, token) -> SCORE_TITLE_CONTAINS
                    SwiftStrings.hasPrefix(row.destination, token) -> SCORE_DESTINATION_PREFIX
                    row.keywords.any { SwiftStrings.hasPrefix(it, token) } -> SCORE_KEYWORD_PREFIX
                    else -> SCORE_OTHER
                }
            }
            scored.add(Scored(row, score))
        }
        scored.sortWith { first, second ->
            when {
                first.score != second.score -> second.score.compareTo(first.score)
                first.row.entry.destination != second.row.entry.destination ->
                    FoundationText.compare(first.row.entry.destination.title, second.row.entry.destination.title)
                else -> FoundationText.compare(first.row.entry.title, second.row.entry.title)
            }
        }
        return scored.map { it.row.entry }
    }

    companion object {
        const val SCORE_TITLE_EQUALS: Int = 100
        const val SCORE_TITLE_PREFIX: Int = 60
        const val SCORE_TITLE_CONTAINS: Int = 35
        const val SCORE_DESTINATION_PREFIX: Int = 20
        const val SCORE_KEYWORD_PREFIX: Int = 12
        const val SCORE_OTHER: Int = 1

        // Swift folds with the user's locale; this is the fixed fold, in Form C so that
        // plain equality is Swift's string equality.
        private fun normalized(value: String): String = FoundationText.nfc(FoundationText.fold(value))
    }
}
