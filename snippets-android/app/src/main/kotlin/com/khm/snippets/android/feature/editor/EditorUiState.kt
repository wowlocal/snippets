package com.khm.snippets.android.feature.editor

import androidx.compose.runtime.Immutable
import com.khm.snippets.android.data.ExistingKeywords
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.feature.shared.SnackbarRequest
import com.khm.snippets.android.feature.shared.UiText
import com.khm.snippets.android.nav.SettingsDestination
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.TextHighlight

/** Whether the entry is there to edit. */
enum class EditorStatus {
    /** The store has not listed the entry yet. */
    Loading,
    Ready,

    /** The entry no longer exists; the screen is closing. */
    Gone,
}

/** The fields whose focus decides whether a remote change may overwrite them (§6.7). */
enum class EditorField { Name, Body, Keyword, Tags, SecureBody }

/**
 * Everything the editor draws except the text of the fields being typed in, which is snapshot
 * state on the ViewModel ([EditorViewModel.name] and friends) so the keyboard never waits.
 *
 * @param title Display name; blank shows `Untitled Snippet`.
 * @param bodyPlaceholders Recognised placeholders of the ordinary body, tinted `primary`.
 * @param preview The body with placeholders resolved; null when it has none or is secure.
 * @param keywordSuggestions Up to three, offered while the keyword is empty and focused.
 * @param existingKeywords Offered while the keyword is non-empty and focused.
 * @param tagCompletions Up to eight library tags that complete the typed tag.
 * @param savedAt `Saved … at …` for an ordinary entry; null before the first save is known.
 * @param saveError The last save failed; cleared by the next successful save.
 * @param showsCopiedCheck The top bar's copy icon shows `check` for 1.5 s.
 * @param isConverting The Secure switch is moving the entry.
 */
@Immutable
data class EditorUiState(
    val status: EditorStatus = EditorStatus.Loading,
    val title: String = "",
    val isSecure: Boolean = false,
    val namePlaceholder: UiText = UiText.Raw(""),
    val bodyPlaceholders: List<TextHighlight> = emptyList(),
    val preview: String? = null,
    val keywordMessage: KeywordMessage? = null,
    val keywordSuggestions: List<String> = emptyList(),
    val existingKeywords: ExistingKeywords = ExistingKeywords.None,
    val tags: List<TagUi> = emptyList(),
    val tagCompletions: List<TagUi> = emptyList(),
    val isEnabled: Boolean = true,
    val isPinned: Boolean = false,
    val savedAt: UiText? = null,
    val saveError: UiText? = null,
    val showsCopiedCheck: Boolean = false,
    val isConverting: Boolean = false,
    val dialog: AppDialog? = null,
) {
    /** The `Details` tab carries the warning dot. */
    val hasKeywordWarning: Boolean get() = keywordMessage?.isWarning == true
}

/** Why the editor leaves. */
enum class EditorCloseReason {
    /** Deleted here: the library shows the snackbar the delete raised. */
    Deleted,

    /** Deleted on another device while open. */
    DeletedElsewhere,

    /** The route names an entry that does not exist (for example after the library changed). */
    Missing,
}

/** One-shot effects of the editor (docs/app-architecture.md, "State and effects"). */
sealed interface EditorEffect {
    data class Close(val reason: EditorCloseReason) : EditorEffect

    /** Duplicate: the editor switches to the copy. */
    data class OpenEditor(val id: String) : EditorEffect
    data class ShowSnackbar(val request: SnackbarRequest) : EditorEffect
    data class Haptic(val haptic: SnippetsHaptic) : EditorEffect

    /** The Android Sharesheet with plain text. */
    data class Share(val text: String, val title: String) : EditorEffect
    data object HideKeyboard : EditorEffect
    data object FocusSecureBody : EditorEffect
    data object OpenSecuritySettings : EditorEffect
    data class OpenSettings(val pane: SettingsDestination) : EditorEffect
}
