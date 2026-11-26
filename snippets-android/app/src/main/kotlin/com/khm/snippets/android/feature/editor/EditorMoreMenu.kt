package com.khm.snippets.android.feature.editor

import androidx.compose.material3.DropdownMenu
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.components.SnippetsMenuDivider
import com.khm.snippets.android.ui.components.SnippetsMenuItem
import com.khm.snippets.android.ui.icons.SnippetsIcon

/** EDIT-MORE (screens-library-editor.md §6.8): a secure entry offers Pin and Delete only. */
@Composable
internal fun EditorMoreMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    isSecure: Boolean,
    isPinned: Boolean,
    actions: EditorActions,
) {
    fun item(action: () -> Unit): () -> Unit = {
        onDismiss()
        action()
    }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        SnippetsMenuItem(
            label = stringResource(if (isPinned) R.string.action_unpin else R.string.action_pin),
            icon = SnippetsIcon.PushPin,
            action = EditorTags.ACTION_PIN,
            onClick = item(actions::onTogglePin),
        )
        if (!isSecure) {
            SnippetsMenuItem(
                label = stringResource(R.string.editor_menu_share_text),
                icon = SnippetsIcon.Share,
                action = EditorTags.ACTION_SHARE_TEXT,
                onClick = item(actions::onShareText),
            )
            SnippetsMenuItem(
                label = stringResource(R.string.editor_menu_share_link),
                icon = SnippetsIcon.Link,
                action = EditorTags.ACTION_SHARE_LINK,
                onClick = item(actions::onShareLink),
            )
            SnippetsMenuItem(
                label = stringResource(R.string.action_copy_share_link),
                icon = SnippetsIcon.Link,
                action = EditorTags.ACTION_COPY_LINK,
                onClick = item(actions::onCopyShareLink),
            )
            SnippetsMenuItem(
                label = stringResource(R.string.action_duplicate),
                icon = SnippetsIcon.FileCopy,
                action = EditorTags.ACTION_DUPLICATE,
                onClick = item(actions::onDuplicate),
            )
        }
        SnippetsMenuDivider()
        SnippetsMenuItem(
            label = stringResource(R.string.action_delete),
            icon = SnippetsIcon.Delete,
            action = EditorTags.ACTION_DELETE,
            onClick = item(actions::onDelete),
            destructive = true,
        )
    }
}
