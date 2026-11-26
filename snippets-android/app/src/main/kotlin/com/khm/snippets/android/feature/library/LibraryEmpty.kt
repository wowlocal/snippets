package com.khm.snippets.android.feature.library

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.shared.SyncMenuAction
import com.khm.snippets.android.feature.shared.SyncPresentation
import com.khm.snippets.android.feature.shared.resolve
import com.khm.snippets.android.ui.components.EmptyState
import com.khm.snippets.android.ui.components.rememberAnnouncer
import com.khm.snippets.android.ui.components.rememberTouchExplorationEnabled
import com.khm.snippets.android.ui.icons.SnippetsIcon

/**
 * The library's empty states (screens-library-editor.md §2.4), under the sync row where one
 * shows. The block scrolls by itself, so pull to refresh stays available.
 */
@Composable
internal fun LibraryEmpty(
    reason: LibraryEmptyUi,
    state: LibraryUiState,
    actions: LibraryActions,
    bottomPadding: Dp,
) {
    Column(modifier = Modifier.fillMaxSize().padding(bottom = bottomPadding)) {
        if (reason !is LibraryEmptyUi.FirstRun) LibrarySyncStatus(state.sync, state.isSyncActionRunning, actions)
        val content = emptyContent(reason)
        EmptyState(
            tagArea = LibraryTags.EMPTY_AREA,
            title = content.title,
            message = content.message,
            modifier = Modifier.weight(1f),
            icon = content.icon,
            iconTint = if (reason is LibraryEmptyUi.Quarantined) MaterialTheme.colorScheme.error else Color.Unspecified,
            loading = reason is LibraryEmptyUi.FirstFetchRunning,
            primaryAction = content.primary,
            onPrimaryAction = { actions.onEmptyAction(0) },
            textActions = content.textActions,
            onTextAction = { index -> actions.onEmptyAction(index + 1) },
            note = content.note,
        )
        if (reason is LibraryEmptyUi.NoResults) AnnounceNoResults(content.title)
    }
}

private class EmptyContent(
    val title: String,
    val message: String,
    val icon: SnippetsIcon?,
    val primary: String? = null,
    val textActions: List<String> = emptyList(),
    val note: String? = null,
)

@Composable
private fun emptyContent(reason: LibraryEmptyUi): EmptyContent = when (reason) {
    is LibraryEmptyUi.FirstRun -> EmptyContent(
        title = stringResource(R.string.library_empty_title),
        message = stringResource(R.string.library_empty_first_run_message),
        icon = SnippetsIcon.Description,
        primary = stringResource(R.string.library_empty_new),
        textActions = listOf(
            stringResource(R.string.library_empty_import),
            when (val sync = reason.syncAction) {
                is SyncMenuAction.TurnOn -> stringResource(R.string.sync_action_turn_on, sync.provider.resolve())
                else -> stringResource(R.string.sync_action_set_up)
            },
        ),
        note = stringResource(R.string.library_empty_note),
    )
    is LibraryEmptyUi.SyncedEmpty -> EmptyContent(
        title = stringResource(R.string.library_empty_title),
        message = stringResource(R.string.library_empty_synced_message, reason.sentence.resolve()),
        icon = SnippetsIcon.Description,
    )
    is LibraryEmptyUi.FirstFetchRunning -> EmptyContent(
        title = stringResource(R.string.library_fetching_title),
        message = stringResource(
            if (reason.started) R.string.library_fetching_message else R.string.library_fetching_preparing_message,
            reason.provider.resolve(),
        ),
        icon = null,
    )
    is LibraryEmptyUi.FirstFetchStalled -> EmptyContent(
        title = stringResource(R.string.library_stalled_title),
        message = stringResource(R.string.library_stalled_message, reason.sentence.resolve()),
        icon = SnippetsIcon.CloudOff,
        primary = when (val action = reason.action) {
            is StalledAction.Recovery -> stringResource(SyncPresentation.recoveryTitle(action.action))
            StalledAction.OpenSyncSettings -> stringResource(R.string.sync_action_open_settings)
            StalledAction.TryAgain -> stringResource(R.string.sync_recovery_try_again)
        },
    )
    is LibraryEmptyUi.Quarantined -> EmptyContent(
        title = stringResource(R.string.library_quarantined_title),
        message = stringResource(R.string.library_quarantined_message, reason.sentence.resolve()),
        icon = SnippetsIcon.Error,
        primary = stringResource(R.string.library_empty_import),
    )
    is LibraryEmptyUi.NoResults -> EmptyContent(
        title = stringResource(R.string.library_no_results_title),
        message = stringResource(
            if (reason.hasFilters) R.string.library_no_results_filtered_message else R.string.library_no_results_message,
        ),
        icon = SnippetsIcon.SearchOff,
        textActions = if (reason.hasFilters) listOf(stringResource(R.string.library_clear_filters)) else emptyList(),
        note = stringResource(R.string.library_no_results_note),
    )
    LibraryEmptyUi.NoFilterMatch -> EmptyContent(
        title = stringResource(R.string.library_no_match_title),
        message = stringResource(R.string.library_no_match_message),
        icon = SnippetsIcon.FilterList,
        textActions = listOf(stringResource(R.string.library_clear_filters)),
    )
}

/** With TalkBack on, a search that finds nothing is spoken: the empty title is its heading. */
@Composable
private fun AnnounceNoResults(title: String) {
    val announcer = rememberAnnouncer()
    val touchExploration = rememberTouchExplorationEnabled()
    LaunchedEffect(title, touchExploration) {
        if (touchExploration) announcer.announce(title)
    }
}
