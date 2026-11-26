package com.khm.snippets.android.feature.library

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.shared.LibrarySyncUi
import com.khm.snippets.android.feature.shared.SyncCardAction
import com.khm.snippets.android.feature.shared.SyncPresentation
import com.khm.snippets.android.feature.shared.resolve
import com.khm.snippets.android.ui.components.GroupDivider
import com.khm.snippets.android.ui.components.LibraryCountFooter
import com.khm.snippets.android.ui.components.PinnedHeader
import com.khm.snippets.android.ui.components.SnippetListItem
import com.khm.snippets.android.ui.components.SyncReviewCard
import com.khm.snippets.android.ui.components.SyncStatusRow
import com.khm.snippets.android.ui.components.rememberTouchExplorationEnabled
import com.khm.snippets.android.ui.model.SnippetRowLayout
import com.khm.snippets.android.ui.model.SnippetRowUi
import com.khm.snippets.android.ui.model.SyncReviewUi
import com.khm.snippets.android.ui.model.SyncStatusUi

/**
 * The scrolling part of the library: sync row or Review card, `Pinned` and its rows, the group
 * divider, the other rows, the count footer. Every item is keyed, so rows animate to their new
 * place on pin, delete and undo.
 */
@Composable
internal fun LibraryList(
    state: LibraryUiState,
    actions: LibraryActions,
    isTwoPane: Boolean,
    selectedId: String?,
    onSelect: (String) -> Unit,
    listState: LazyListState,
    bottomPadding: Dp,
    firstRowFocus: FocusRequester,
    onRowFocused: (String?) -> Unit,
) {
    val touchExploration = rememberTouchExplorationEnabled()
    val layout = if (isTwoPane) SnippetRowLayout.TwoPane else SnippetRowLayout.SinglePane
    val firstId = state.pinned.firstOrNull()?.id ?: state.others.firstOrNull()?.id
    val rowItem: @Composable (SnippetRowUi, Boolean, Modifier) -> Unit = { row, showDivider, itemModifier ->
        SnippetListItem(
            row = row,
            onClick = {
                if (isTwoPane) onSelect(row.id) else actions.onCopy(row.id, swipeTipEligible = !touchExploration)
            },
            onAction = { action -> actions.onRowAction(row.id, action) },
            modifier = itemModifier
                .onFocusChanged { if (it.isFocused) onRowFocused(row.id) }
                .then(if (row.id == firstId) Modifier.focusRequester(firstRowFocus) else Modifier),
            layout = layout,
            selected = row.id == selectedId,
            copied = row.id == state.copiedId,
            showDivider = showDivider,
            // The countdown row announces a secure copy.
            announceCopied = !row.isSecure,
        )
    }
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .onFocusChanged { if (!it.hasFocus) onRowFocused(null) }
            .testTag(LibraryTags.LIST),
        state = listState,
        contentPadding = PaddingValues(bottom = bottomPadding),
    ) {
        syncItem(state, actions)
        if (state.pinned.isNotEmpty()) {
            item(key = KEY_PINNED_HEADER) { PinnedHeader(Modifier.animateItem()) }
            rows(state.pinned, selectedId, rowItem)
            if (state.others.isNotEmpty()) item(key = KEY_GROUP_DIVIDER) { GroupDivider(Modifier.animateItem()) }
        }
        rows(state.others, selectedId, rowItem)
        item(key = KEY_FOOTER) {
            LibraryCountFooter(
                visibleCount = state.visibleCount,
                totalCount = state.totalCount,
                filtered = state.isFiltering,
                modifier = Modifier.animateItem(),
            )
        }
    }
}

private fun LazyListScope.rows(
    rows: List<SnippetRowUi>,
    selectedId: String?,
    content: @Composable (SnippetRowUi, Boolean, Modifier) -> Unit,
) {
    itemsIndexed(items = rows, key = { _, row -> row.id }, contentType = { _, _ -> CONTENT_TYPE_ROW }) { index, row ->
        // No divider under the last row of a section, nor next to the selected row.
        val next = rows.getOrNull(index + 1)
        val showDivider = next != null && next.id != selectedId
        content(row, showDivider, Modifier.animateItem())
    }
}

/** The sync row or the Review card as the first list item; nothing while sync is off. */
internal fun LazyListScope.syncItem(state: LibraryUiState, actions: LibraryActions) {
    val sync = state.sync
    if (sync == LibrarySyncUi.Hidden) return
    item(key = KEY_SYNC) { LibrarySyncStatus(sync, state.isSyncActionRunning, actions) }
}

@Composable
internal fun LibrarySyncStatus(sync: LibrarySyncUi, actionRunning: Boolean, actions: LibraryActions, modifier: Modifier = Modifier) {
    when (sync) {
        LibrarySyncUi.Hidden -> Unit
        is LibrarySyncUi.Quiet -> SyncStatusRow(
            status = SyncStatusUi(sync.glyph, sync.text.resolve()),
            onClick = actions::onSyncRowClick,
            modifier = modifier,
        )
        is LibrarySyncUi.Card -> SyncReviewCard(
            review = SyncReviewUi(
                kind = sync.kind,
                glyph = sync.glyph,
                text = sync.text.resolve(),
                actionTitle = when (val action = sync.action) {
                    is SyncCardAction.Recovery -> stringResource(SyncPresentation.recoveryTitle(action.action))
                    SyncCardAction.OpenSyncSettings -> stringResource(R.string.sync_action_open_settings)
                    null -> null
                },
                isActionRunning = actionRunning,
            ),
            onClick = actions::onSyncCardClick,
            onAction = actions::onSyncCardAction,
            modifier = modifier,
        )
    }
}

private const val KEY_SYNC = "sync"
private const val KEY_PINNED_HEADER = "pinned-header"
private const val KEY_GROUP_DIVIDER = "group-divider"
private const val KEY_FOOTER = "footer"
private const val CONTENT_TYPE_ROW = "row"
