package com.khm.snippets.android.feature.library

/**
 * Test tags of the library screen that the component library does not own
 * (screens-library-editor.md §2.10, §5). Shared tags are in `ui.components.TestTags`.
 */
object LibraryTags {
    const val SCREEN = "library.screen"
    const val LIST = "library.list"
    const val LOADING = "library.loading"
    const val REFRESH = "library.refresh"

    /** Area of the library's empty states: `library.empty`, `library.empty.title`, … */
    const val EMPTY_AREA = "library"

    /** Area of the two-pane placeholder: `editor.empty`, … */
    const val DETAIL_EMPTY_AREA = "editor"

    const val SYNC_SHEET = "sync-sheet"
    const val SYNC_SHEET_TITLE = "sync-sheet.title"
    const val SYNC_SHEET_PROVIDER = "sync-sheet.provider"
    const val SYNC_SHEET_STATUS = "sync-sheet.status"
    const val SYNC_SHEET_SYNC_NOW = "sync-sheet.sync-now"
    const val SYNC_SHEET_SETTINGS = "sync-sheet.settings"
    const val SYNC_SHEET_CONFLICTS = "sync-sheet.conflicts"

    // More menu items (§3): `menu.item.<action>`.
    const val ACTION_NEW_FROM_CLIPBOARD = "new-from-clipboard"
    const val ACTION_IMPORT = "import"
    const val ACTION_EXPORT = "export"
    const val ACTION_BACKUP = "backup"
    const val ACTION_SYNC = "sync"
    const val ACTION_SHORTCUTS = "shortcuts"
    const val ACTION_SETTINGS = "settings"
}
