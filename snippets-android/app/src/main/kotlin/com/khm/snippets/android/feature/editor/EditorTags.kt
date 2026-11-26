package com.khm.snippets.android.feature.editor

/** Test tags of the editor (screens-library-editor.md §6.11); shared ones are in `TestTags`. */
object EditorTags {
    const val SCREEN = "editor.screen"
    const val COPY = "editor.copy"
    const val MORE = "editor.more"
    const val TAB_CONTENT = "editor.tab.content"
    const val TAB_DETAILS = "editor.tab.details"
    const val TAB_DETAILS_DOT = "editor.tab.details.dot"
    const val NAME = "editor.name"
    const val BODY = "editor.body"
    const val PREVIEW_TOGGLE = "editor.preview.toggle"
    const val PREVIEW_TEXT = "editor.preview.text"
    const val FOOTER = "editor.footer"
    const val SAVE_ERROR = "editor.save-error"
    const val KEYWORD = "editor.keyword"
    const val KEYWORD_EXISTING = "editor.keyword.existing"
    const val TAGS = "editor.tags"
    const val ENABLED = "editor.enabled"
    const val SECURE = "editor.secure"

    /** `editor.keyword.suggestion.<keyword>`. */
    fun keywordSuggestion(keyword: String): String = "editor.keyword.suggestion.$keyword"

    /** `editor.tags.completion.<foldedTag>`. */
    fun tagCompletion(foldedTag: String): String = "editor.tags.completion.$foldedTag"

    // Editor More menu items: `menu.item.<action>`.
    const val ACTION_PIN = "pin"
    const val ACTION_SHARE_TEXT = "share-text"
    const val ACTION_SHARE_LINK = "share-link"
    const val ACTION_COPY_LINK = "copy-link"
    const val ACTION_DUPLICATE = "duplicate"
    const val ACTION_DELETE = "delete"
}
