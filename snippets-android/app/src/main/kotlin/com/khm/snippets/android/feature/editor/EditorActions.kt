package com.khm.snippets.android.feature.editor

import androidx.compose.runtime.Stable
import androidx.compose.ui.text.input.TextFieldValue
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.TagUi

/** Every event of the editor. [EditorViewModel] implements it; see [com.khm.snippets.android.feature.library.LibraryActions]. */
@Stable
interface EditorActions {
    fun onNameChange(text: String)
    fun onBodyChange(text: String)
    fun onKeywordChange(value: TextFieldValue)

    /** A hardware Tab in the keyword field. True when it completed: then focus does not move. */
    fun onKeywordTab(): Boolean
    fun onKeywordSuggestion(keyword: String)
    fun onTagInputChange(text: String)

    /** IME Done, a comma, or focus leaving the input: commits the pending text. */
    fun onTagCommit()

    /** A hardware Enter: accepts the first completion when there is one, else commits. */
    fun onTagEnter()
    fun onTagCompletion(tag: TagUi)
    fun onRemoveTag(tag: TagUi)
    fun onRemoveLastTag()
    fun onFieldFocusChanged(field: EditorField, focused: Boolean)
    fun onEnabledChange(enabled: Boolean)
    fun onSecureChange(secure: Boolean)
    fun onCopy()
    fun onTogglePin()
    fun onShareText()
    fun onShareLink()
    fun onCopyShareLink()
    fun onDuplicate()
    fun onDelete()
    fun onReveal()
    fun onLock()
    fun onSecureBodyChange(text: String)
    fun onSecureUnavailableAction()

    /** The editor menu or a dialog opens: a revealed body locks first. */
    fun onMenuOpened()

    /** The app stops: pending edits are written now. */
    fun onStop()
    fun onDismissDialog()
    fun onConfirmDialog(dialog: AppDialog)
}

/**
 * The text the editor's fields show, as snapshot state: read in composition, so a keystroke
 * recomposes the field at once. [EditorViewModel] implements it.
 */
@Stable
interface EditorDraft {
    val name: String
    val body: String
    val keyword: TextFieldValue
    val tagInput: String

    /** [SecurePanelState.Revealed] carries the only plaintext of a secure body. */
    val securePanel: SecurePanelState
}
