package com.khm.snippets.android.feature.library

import android.content.res.Configuration
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.shared.SyncMenuAction
import com.khm.snippets.android.feature.shared.SyncPresentation
import com.khm.snippets.android.feature.shared.resolve
import com.khm.snippets.android.ui.components.LibrarySearchBar
import com.khm.snippets.android.ui.components.SnippetsMenuDivider
import com.khm.snippets.android.ui.components.SnippetsMenuItem
import com.khm.snippets.android.ui.components.TagFilterRow
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens

/**
 * The part above the list that never scrolls: the search bar with the More menu, and the tag
 * filter row (components.md §3.2, §4.1). [modifier] carries the scrolled-state background,
 * [contentModifier] the centred maximum width.
 */
@Composable
internal fun LibraryTopArea(
    query: String,
    state: LibraryUiState,
    actions: LibraryActions,
    searchFocus: FocusRequester,
    topInset: Dp,
    modifier: Modifier = Modifier,
    contentModifier: Modifier = Modifier,
) {
    var menuOpen by rememberSaveable { mutableStateOf(false) }
    Column(modifier = modifier.padding(top = topInset)) {
        Column(modifier = contentModifier) {
            LibrarySearchBar(
                query = query,
                onQueryChange = actions::onQueryChange,
                onMoreClick = { menuOpen = true },
                modifier = Modifier
                    .padding(horizontal = Dimens.marginCompact)
                    .padding(top = Dimens.searchBarTopGap, bottom = Dimens.searchBarBottomGap),
                focusRequester = searchFocus,
                moreMenu = {
                    LibraryMoreMenu(
                        expanded = menuOpen,
                        onDismiss = { menuOpen = false },
                        syncAction = state.syncMenu,
                        actions = actions,
                    )
                },
            )
            if (state.showFilterRow) {
                TagFilterRow(
                    tags = state.filterChips,
                    onToggleTag = actions::onToggleTag,
                    onOpenFilters = actions::onOpenTagSheet,
                )
            }
        }
    }
}

/** LIB-MORE (screens-library-editor.md §3): flat, groups split by dividers. */
@Composable
private fun LibraryMoreMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    syncAction: SyncMenuAction,
    actions: LibraryActions,
) {
    val configuration = LocalConfiguration.current
    val hasHardwareKeyboard = configuration.keyboard != Configuration.KEYBOARD_NOKEYS &&
        configuration.hardKeyboardHidden == Configuration.HARDKEYBOARDHIDDEN_NO
    fun item(action: () -> Unit): () -> Unit = {
        onDismiss()
        action()
    }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        SnippetsMenuItem(
            label = stringResource(R.string.library_menu_new_from_clipboard),
            icon = SnippetsIcon.ContentPaste,
            action = LibraryTags.ACTION_NEW_FROM_CLIPBOARD,
            onClick = item(actions::onNewFromClipboard),
        )
        SnippetsMenuDivider()
        SnippetsMenuItem(
            label = stringResource(R.string.library_menu_import),
            icon = SnippetsIcon.FileOpen,
            action = LibraryTags.ACTION_IMPORT,
            onClick = item(actions::onImport),
        )
        SnippetsMenuItem(
            label = stringResource(R.string.library_menu_export),
            icon = SnippetsIcon.FileSave,
            action = LibraryTags.ACTION_EXPORT,
            onClick = item(actions::onExport),
        )
        SnippetsMenuItem(
            label = stringResource(R.string.library_menu_backup),
            icon = SnippetsIcon.EnhancedEncryption,
            action = LibraryTags.ACTION_BACKUP,
            onClick = item(actions::onEncryptedBackup),
        )
        SnippetsMenuDivider()
        SnippetsMenuItem(
            label = syncMenuTitle(syncAction),
            icon = SnippetsIcon.Sync,
            action = LibraryTags.ACTION_SYNC,
            onClick = item(actions::onSyncMenuAction),
        )
        if (hasHardwareKeyboard) {
            SnippetsMenuItem(
                label = stringResource(R.string.library_menu_shortcuts),
                icon = SnippetsIcon.Keyboard,
                action = LibraryTags.ACTION_SHORTCUTS,
                onClick = item(actions::onShowKeyboardShortcuts),
            )
        }
        SnippetsMenuItem(
            label = stringResource(R.string.library_menu_settings),
            icon = SnippetsIcon.Settings,
            action = LibraryTags.ACTION_SETTINGS,
            onClick = item(actions::onOpenSettings),
        )
    }
}

/** The title of the menu's sync item, first match (§3). */
@Composable
internal fun syncMenuTitle(action: SyncMenuAction): String = when (action) {
    is SyncMenuAction.Recovery -> stringResource(SyncPresentation.recoveryTitle(action.action))
    SyncMenuAction.OpenSyncSettings -> stringResource(R.string.sync_action_open_settings)
    SyncMenuAction.SyncNow -> stringResource(R.string.sync_action_sync_now)
    is SyncMenuAction.TurnOn -> stringResource(R.string.sync_action_turn_on, action.provider.resolve())
    SyncMenuAction.SetUp -> stringResource(R.string.sync_action_set_up)
}
