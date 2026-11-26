package com.khm.snippets.android.ui.components

/**
 * Test tags owned by the component library (DESIGN.md §13; components.md). Format
 * `area.element[.qualifier]`: lower case, dots between levels, hyphens inside a level.
 */
object TestTags {
    // Shared
    const val SNACKBAR = "snackbar"
    const val SNACKBAR_ACTION = "snackbar.action"
    const val DIALOG_TITLE = "dialog.title"
    const val DIALOG_MESSAGE = "dialog.message"
    const val DIALOG_CONFIRM = "dialog.confirm"
    const val DIALOG_DISMISS = "dialog.dismiss"
    const val DIALOG_NEUTRAL = "dialog.neutral"
    const val DIALOG_ERROR = "dialog.error"
    const val DIALOG_SECRET_LEAVE = "dialog.secret-leave"
    const val TOPBAR_TITLE = "topbar.title"
    const val TOPBAR_BACK = "topbar.back"
    const val TOPBAR_CLOSE = "topbar.close"

    /** `menu.item.<action>`. */
    fun menuItem(action: String): String = "menu.item.$action"

    // Library
    const val LIBRARY_SEARCH = "library.search"
    const val LIBRARY_SEARCH_CLEAR = "library.search.clear"
    const val LIBRARY_SEARCH_BACK = "library.search.back"
    const val LIBRARY_MORE = "library.more"
    const val LIBRARY_FILTER = "library.filter"
    const val LIBRARY_FILTER_BADGE = "library.filter.badge"
    const val LIBRARY_HEADER_PINNED = "library.header.pinned"
    const val LIBRARY_COUNT = "library.count"
    const val LIBRARY_FAB = "library.fab"
    const val LIBRARY_SYNC_ROW = "library.sync-row"
    const val LIBRARY_SYNC_ROW_TEXT = "library.sync-row.text"
    const val LIBRARY_SYNC_CARD = "library.sync-card"
    const val LIBRARY_SYNC_CARD_TITLE = "library.sync-card.title"
    const val LIBRARY_SYNC_CARD_TEXT = "library.sync-card.text"
    const val LIBRARY_SYNC_CARD_ACTION = "library.sync-card.action"

    /** `library.tag-chip.<foldedTag>`. */
    const val LIBRARY_TAG_ROW = "library.tag-row"
    fun tagChip(foldedTag: String): String = "library.tag-chip.$foldedTag"

    /** `library.row.<id>`; parts append [Row] suffixes. */
    fun row(id: String): String = "library.row.$id"

    /** Suffixes of the row parts (components.md §1.6). */
    object Row {
        const val NAME = ".name"
        const val PREVIEW = ".preview"
        const val KEYWORD = ".keyword"
        const val TIME = ".time"
        const val TAGS = ".tags"
        const val COPIED = ".copied"
        const val EDIT = ".edit"
        const val COPY = ".copy"
        const val GLYPH_SECURE = ".glyph.secure"
        const val GLYPH_PINNED = ".glyph.pinned"
        const val GLYPH_DISABLED = ".glyph.disabled"
    }

    // Tag filter sheet
    const val TAGS_SHEET = "tags.sheet"
    const val TAGS_TITLE = "tags.title"
    const val TAGS_CLEAR = "tags.clear"
    const val TAGS_SEARCH = "tags.search"
    const val TAGS_FOOTER = "tags.footer"
    const val TAGS_EMPTY = "tags.empty"
    const val TAGS_NO_MATCH = "tags.no-match"

    /** `tags.row.<foldedTag>`. */
    fun tagsRow(foldedTag: String): String = "tags.row.$foldedTag"

    // Empty state: `<area>.empty` plus these suffixes
    object Empty {
        const val ROOT = ".empty"
        const val TITLE = ".empty.title"
        const val MESSAGE = ".empty.message"
        const val ACTION = ".empty.action"
        const val ACTION_2 = ".empty.action-2"
        const val ACTION_3 = ".empty.action-3"
        const val NOTE = ".empty.note"
    }

    // Problem card: `<area>.error.<code>` plus these suffixes
    fun problem(area: String, code: String): String = "$area.error.$code"

    object Problem {
        const val TITLE = ".title"
        const val MESSAGE = ".message"
        const val ACTION = ".action"
        const val ACTION_2 = ".action-2"
        const val DETAILS = ".details"
        const val CODE = ".code"
        const val CODE_COPY = ".code-copy"
    }

    // Secure body panel
    const val SECURE_PANEL = "editor.secure-panel"
    const val SECURE_REVEAL = "editor.secure.reveal"
    const val SECURE_LOCK = "editor.secure.lock"
    const val SECURE_BODY = "editor.secure.body"
    const val SECURE_REASON = "editor.secure.reason"
    const val SECURE_STANDIN = "editor.secure.standin"
    const val SECURE_FOOTER = "editor.secure.footer"
    const val SECURE_MESSAGE = "editor.secure.message"
    const val SECURE_UNAVAILABLE_ACTION = "editor.secure.unavailable-action"

    // Secret block and secret screen
    const val SECRET_SCREEN = "secret.screen"
    const val SECRET_HEADING = "secret.heading"
    const val SECRET_BODY = "secret.body"
    const val SECRET_CODE = "secret.code"
    const val SECRET_COPY = "secret.copy"
    const val SECRET_COPIED = "secret.copied"
    const val SECRET_NOTE = "secret.note"
    const val SECRET_DONE = "secret.done"
    const val SECRET_CLOSE = "secret.close"
    const val SECRET_HIDDEN = "secret.hidden"

    // Countdown row
    const val COUNTDOWN_ROW = "countdown.row"
    const val COUNTDOWN_TEXT = "countdown.text"
    const val COUNTDOWN_CLEAR = "countdown.clear"
    const val COUNTDOWN_PROGRESS = "countdown.progress"

    /** `progress.step.<n>`, 1-based. */
    fun progressStep(number: Int): String = "progress.step.$number"

    // Settings row: `settings.row.<key>` plus these suffixes
    fun settingsRow(key: String): String = "settings.row.$key"

    object Settings {
        const val TITLE = ".title"
        const val DETAIL = ".detail"
        const val SWITCH = ".switch"
    }

    // Review screen
    const val REVIEW_SCREEN = "review.screen"
    const val REVIEW_HEADING = "review.heading"
    const val REVIEW_HAPPENED = "review.happened"
    const val REVIEW_EXPLANATION = "review.explanation"
    const val REVIEW_DEVICE = "review.device"
    const val REVIEW_DETAILS = "review.details"
    const val REVIEW_CODE = "review.code"
    const val REVIEW_CODE_COPY = "review.code-copy"
    const val REVIEW_CONFIRM = "review.confirm"
    const val REVIEW_DISMISS = "review.dismiss"

    /** Suffixes of form field parts: `<fieldTag>` plus these. */
    object Field {
        const val CAPTION = ".caption"
        const val MESSAGE = ".message"
        const val COUNTER = ".counter"
        const val PASTE = ".paste"
        const val VISIBILITY = ".visibility"
        const val WARNING_ICON = ".warning-icon"
        const val INPUT = ".input"
        const val REMOVE = ".remove"
    }

    /** `editor.tag.<foldedTag>`: a chip in the tag field. */
    fun editorTag(foldedTag: String): String = "editor.tag.$foldedTag"
}
