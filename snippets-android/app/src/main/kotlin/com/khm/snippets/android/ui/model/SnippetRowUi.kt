package com.khm.snippets.android.ui.model

import androidx.compose.runtime.Immutable
import com.khm.snippets.android.ui.theme.CONFLICT_TAG_FOLDED

/**
 * A tag as it is displayed.
 *
 * @param name The spelling shown to the user.
 * @param folded The case- and diacritic-folded identity; selects the colour and the test tag.
 * @param highlights Search matches inside [name].
 */
@Immutable
data class TagUi(
    val name: String,
    val folded: String,
    val highlights: List<TextHighlight> = emptyList(),
) {
    /** True for the tag that marks a conflict copy; it uses the warning style. */
    val isConflict: Boolean get() = folded == CONFLICT_TAG_FOLDED
}

/** A tag in the filter row or the filter sheet. [count] covers the whole library. */
@Immutable
data class TagFilterUi(
    val tag: TagUi,
    val count: Int,
    val selected: Boolean,
)

/** Line 2 of a library row, after the keyword token (components.md §1.2). */
@Immutable
sealed interface RowPreviewUi {
    /** A keyword and no content: nothing after the token. */
    @Immutable
    data object None : RowPreviewUi

    /** Neither keyword nor content: `No content`. */
    @Immutable
    data object NoContent : RowPreviewUi

    /** A secure entry: the fixed text `Secure snippet`. A secure body is never passed in. */
    @Immutable
    data object Secure : RowPreviewUi

    /**
     * Ordinary content.
     *
     * @param text The first non-blank content line with whitespace collapsed, or a search
     *   excerpt.
     * @param highlights Search matches inside [text].
     * @param isExcerpt True for a search hit that is not on the first line; the row prefixes `…`.
     */
    @Immutable
    data class Text(
        val text: String,
        val highlights: List<TextHighlight> = emptyList(),
        val isExcerpt: Boolean = false,
    ) : RowPreviewUi
}

/**
 * One library row.
 *
 * @param id Snippet id; part of every test tag of the row.
 * @param name Display name. Blank shows `Untitled Snippet`.
 * @param time Already formatted: time of day, `Yesterday`, weekday or `MMM d`.
 * @param keyword Without the backslash; null or blank when the entry has none.
 * @param isEnabled False draws the disabled-keyword style; the row stays interactive.
 * @param keywordHighlights Matches inside [keyword] (without the backslash).
 */
@Immutable
data class SnippetRowUi(
    val id: String,
    val name: String,
    val time: String,
    val preview: RowPreviewUi = RowPreviewUi.NoContent,
    val keyword: String? = null,
    val tags: List<TagUi> = emptyList(),
    val isSecure: Boolean = false,
    val isPinned: Boolean = false,
    val isEnabled: Boolean = true,
    val nameHighlights: List<TextHighlight> = emptyList(),
    val keywordHighlights: List<TextHighlight> = emptyList(),
) {
    val hasKeyword: Boolean get() = !keyword.isNullOrBlank()
}

/** What a tap and the trailing button of a row do. */
enum class SnippetRowLayout {
    /** Compact and medium widths: tap copies, the trailing button edits, swipes are on. */
    SinglePane,

    /** Expanded widths: tap selects, the trailing button copies, swipes are off. */
    TwoPane,

    /** The Insert Snippet activity: tap picks, no trailing button, no swipes. */
    Picker,
}

/** Everything a row can ask for. Which ones are offered depends on the layout and the entry. */
enum class SnippetRowAction(val menuTag: String) {
    Copy("copy"),
    Edit("edit"),
    TogglePin("pin"),
    ToggleEnabled("enabled"),
    ToggleSecure("secure"),
    Duplicate("duplicate"),
    CopyShareLink("copy-link"),
    Delete("delete"),
}

/**
 * The row menu's items, in display order (screens-library-editor.md §4). Items that do not apply
 * are absent, never disabled; Delete is last.
 */
fun rowMenuActions(layout: SnippetRowLayout, isSecure: Boolean): List<SnippetRowAction> = buildList {
    add(SnippetRowAction.Copy)
    if (layout != SnippetRowLayout.TwoPane) add(SnippetRowAction.Edit)
    add(SnippetRowAction.TogglePin)
    if (layout == SnippetRowLayout.TwoPane) {
        add(SnippetRowAction.ToggleEnabled)
        add(SnippetRowAction.ToggleSecure)
    }
    if (!isSecure) add(SnippetRowAction.Duplicate)
    if (layout == SnippetRowLayout.TwoPane && !isSecure) add(SnippetRowAction.CopyShareLink)
    add(SnippetRowAction.Delete)
}

/**
 * The row's accessibility custom actions, in order: Copy, Edit, Pin / Unpin, Duplicate
 * (ordinary), Delete (components.md §1.5).
 */
fun rowCustomActions(isSecure: Boolean): List<SnippetRowAction> = buildList {
    add(SnippetRowAction.Copy)
    add(SnippetRowAction.Edit)
    add(SnippetRowAction.TogglePin)
    if (!isSecure) add(SnippetRowAction.Duplicate)
    add(SnippetRowAction.Delete)
}

/** The actions a swipe can commit. Delete is never one of them (DESIGN.md D5). */
val SwipeActions: List<SnippetRowAction> = listOf(SnippetRowAction.Edit, SnippetRowAction.TogglePin)
