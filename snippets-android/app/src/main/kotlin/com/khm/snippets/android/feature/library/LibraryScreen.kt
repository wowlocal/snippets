package com.khm.snippets.android.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.shared.AppDialogHost
import com.khm.snippets.android.feature.shared.LocalAppSnackbars
import com.khm.snippets.android.nav.WidthClass
import com.khm.snippets.android.nav.WindowLayout
import com.khm.snippets.android.ui.components.NewSnippetFab
import com.khm.snippets.android.ui.components.SecureCopyCountdown
import com.khm.snippets.android.ui.components.SnippetsSnackbarHost
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.theme.Dimens

/**
 * LIB — the library (screens-library-editor.md §1 to §5): search bar, tag filter row,
 * countdown row, then the scrolling list (sync row, `Pinned`, rows, count footer) or an empty
 * state, under pull to refresh. The FAB, sheets and dialogs belong to it as well.
 *
 * @param query The search text, read from the ViewModel's snapshot state so typing never waits.
 * @param selectedId The entry the detail pane shows (two-pane only).
 * @param showsSnackbars This pane hosts the window's snackbars (always, in every layout).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun LibraryScreen(
    state: LibraryUiState,
    query: String,
    countdown: CountdownUi?,
    actions: LibraryActions,
    layout: WindowLayout,
    isTwoPane: Boolean,
    selectedId: String?,
    onSelect: (String) -> Unit,
    searchFocus: FocusRequester,
    firstRowFocus: FocusRequester,
    onRowFocused: (String?) -> Unit,
    modifier: Modifier = Modifier,
    listState: LazyListState = rememberLazyListState(),
) {
    val snackbars = LocalAppSnackbars.current
    val scrolled by remember(listState) { derivedStateOf { listState.canScrollBackward } }
    val atTop by remember(listState) { derivedStateOf { listState.firstVisibleItemIndex == 0 } }
    val imeVisible = WindowInsets.isImeVisible
    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .testTag(LibraryTags.SCREEN),
        snackbarHost = {
            SnippetsSnackbarHost(snackbars.controller.hostState, compact = !isTwoPane && layout.widthClass == WidthClass.Compact)
        },
        floatingActionButton = {
            if (state.showFab && !imeVisible) {
                NewSnippetFab(onClick = actions::onNewSnippet, expanded = atTop, small = layout.isShort)
            }
        },
        contentWindowInsets = WindowInsets.safeDrawing,
        containerColor = MaterialTheme.colorScheme.surface,
    ) { padding ->
        val direction = LocalLayoutDirection.current
        val paneTitle = stringResource(R.string.library_pane_title)
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(start = padding.calculateStartPadding(direction), end = padding.calculateEndPadding(direction))
                .semantics { this.paneTitle = paneTitle },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val contentWidth = Modifier
                .fillMaxWidth()
                .then(if (isTwoPane) Modifier else Modifier.widthIn(max = Dimens.contentMaxWidthMedium))
            LibraryTopArea(
                query = query,
                state = state,
                actions = actions,
                searchFocus = searchFocus,
                topInset = padding.calculateTopPadding(),
                modifier = Modifier
                    .fillMaxWidth()
                    .background(if (scrolled) MaterialTheme.colorScheme.surfaceContainer else MaterialTheme.colorScheme.surface),
                contentModifier = contentWidth,
            )
            if (countdown != null) {
                SecureCopyCountdown(state = countdown, onClearNow = actions::onClearClipboardNow)
            }
            val pullState = rememberPullToRefreshState()
            PullToRefreshBox(
                isRefreshing = state.isRefreshing,
                onRefresh = actions::onRefresh,
                modifier = contentWidth.weight(1f),
                state = pullState,
                indicator = {
                    PullToRefreshDefaults.Indicator(
                        state = pullState,
                        isRefreshing = state.isRefreshing,
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .testTag(LibraryTags.REFRESH),
                        containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                        color = MaterialTheme.colorScheme.primary,
                    )
                },
            ) {
                when (val content = state.content) {
                    is LibraryContent.Loading -> LibraryLoading(showSpinner = content.showSpinner)
                    LibraryContent.Rows -> LibraryList(
                        state = state,
                        actions = actions,
                        isTwoPane = isTwoPane,
                        selectedId = selectedId,
                        onSelect = onSelect,
                        listState = listState,
                        bottomPadding = padding.calculateBottomPadding() +
                            if (state.showFab) Dimens.listBottomPaddingWithFab else Dimens.listBottomPadding,
                        firstRowFocus = firstRowFocus,
                        onRowFocused = onRowFocused,
                    )
                    is LibraryContent.Empty -> LibraryEmpty(
                        reason = content.reason,
                        state = state,
                        actions = actions,
                        bottomPadding = padding.calculateBottomPadding(),
                    )
                }
            }
        }
    }
    LibrarySheets(state = state, actions = actions)
    AppDialogHost(dialog = state.dialog, onConfirm = actions::onConfirmDialog, onDismiss = actions::onDismissDialog)
}

@Composable
private fun LibraryLoading(showSpinner: Boolean) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (showSpinner) {
            val description = stringResource(R.string.library_loading)
            CircularProgressIndicator(
                modifier = Modifier
                    .size(Dimens.spinnerEmptyState)
                    .testTag(LibraryTags.LOADING)
                    .semantics { contentDescription = description },
                strokeWidth = Dimens.spinnerStroke,
            )
        }
    }
}
