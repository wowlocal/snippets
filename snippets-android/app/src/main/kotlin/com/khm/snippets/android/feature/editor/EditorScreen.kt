package com.khm.snippets.android.feature.editor

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.shared.AppDialogHost
import com.khm.snippets.android.feature.shared.LocalAppSnackbars
import com.khm.snippets.android.feature.shared.resolve
import com.khm.snippets.android.ui.components.SecureCopyCountdown
import com.khm.snippets.android.ui.components.SnippetsIconButton
import com.khm.snippets.android.ui.components.SnippetsSnackbarHost
import com.khm.snippets.android.ui.components.TestTags
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/** The two tabs of the phone editor (DESIGN.md D10). */
enum class EditorTab { Content, Details }

/** Focus targets the destination moves focus to (new entry, reveal, Next, Ctrl+E). */
class EditorFocus {
    val name = FocusRequester()
    val body = FocusRequester()
    val secureBody = FocusRequester()
    val keyword = FocusRequester()
    val tags = FocusRequester()
}

/**
 * EDIT (screens-library-editor.md §6): the top bar (Up, title, Copy, More), the `Content` /
 * `Details` tabs on phones and one form in a detail pane, the countdown row or save-error
 * banner, the fields. Autosave only: back is never intercepted.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(
    state: EditorUiState,
    draft: EditorDraft,
    countdown: CountdownUi?,
    actions: EditorActions,
    isTwoPane: Boolean,
    onBack: () -> Unit,
    focus: EditorFocus,
    onClearClipboardNow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var tab by rememberSaveable { mutableStateOf(EditorTab.Content) }
    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior()
    val untitled = stringResource(R.string.library_row_untitled)
    val title = state.title.ifBlank { untitled }
    val snackbars = LocalAppSnackbars.current
    Scaffold(
        modifier = modifier
            .fillMaxSize()
            .nestedScroll(scrollBehavior.nestedScrollConnection)
            .semantics { paneTitle = title }
            .testTag(EditorTags.SCREEN),
        topBar = {
            Column {
                EditorTopBar(
                    title = title,
                    state = state,
                    actions = actions,
                    showUp = !isTwoPane,
                    onBack = onBack,
                    scrollBehavior = scrollBehavior,
                )
                if (!isTwoPane) {
                    EditorTabs(selected = tab, onSelect = { tab = it }, hasWarning = state.hasKeywordWarning)
                }
            }
        },
        // In two panes the list pane hosts the window's snackbars.
        snackbarHost = { if (!isTwoPane) SnippetsSnackbarHost(snackbars.controller.hostState) },
        contentWindowInsets = WindowInsets.safeDrawing,
        containerColor = MaterialTheme.colorScheme.surface,
    ) { padding ->
        val direction = LocalLayoutDirection.current
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(
                    top = padding.calculateTopPadding(),
                    start = padding.calculateStartPadding(direction),
                    end = padding.calculateEndPadding(direction),
                ),
        ) {
            if (countdown != null) SecureCopyCountdown(state = countdown, onClearNow = onClearClipboardNow)
            state.saveError?.let { SaveErrorBanner(it.resolve()) }
            val bottom = padding.calculateBottomPadding() + Dimens.formSectionGap
            if (isTwoPane) {
                EditorForm(state, draft, actions, focus, bottom)
            } else {
                val reducedMotion = SnippetsTheme.reducedMotion
                val slidePx = with(LocalDensity.current) { Dimens.sharedAxisOffset.roundToPx() }
                AnimatedContent(
                    targetState = tab,
                    transitionSpec = {
                        if (reducedMotion) {
                            fadeIn(tween(Motion.REDUCED_FADE)) togetherWith fadeOut(tween(Motion.REDUCED_FADE))
                        } else {
                            val forward = targetState.ordinal > initialState.ordinal
                            val slide = tween<IntOffset>(Motion.DURATION_MEDIUM_2, easing = Motion.EasingEmphasizedDecelerate)
                            (slideInHorizontally(slide) { if (forward) slidePx else -slidePx } + fadeIn(tween(Motion.DURATION_MEDIUM_2))) togetherWith
                                (slideOutHorizontally(slide) { if (forward) -slidePx else slidePx } + fadeOut(tween(Motion.DURATION_SHORT_2)))
                        }
                    },
                    label = "editorTab",
                ) { shown ->
                    when (shown) {
                        EditorTab.Content -> EditorContentTab(state, draft, actions, focus, bottom)
                        EditorTab.Details -> EditorDetailsTab(state, draft, actions, focus, bottom)
                    }
                }
            }
        }
    }
    AppDialogHost(dialog = state.dialog, onConfirm = actions::onConfirmDialog, onDismiss = actions::onDismissDialog)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditorTopBar(
    title: String,
    state: EditorUiState,
    actions: EditorActions,
    showUp: Boolean,
    onBack: () -> Unit,
    scrollBehavior: TopAppBarScrollBehavior,
) {
    var menuOpen by rememberSaveable { mutableStateOf(false) }
    TopAppBar(
        title = {
            Text(
                text = title,
                modifier = Modifier.testTag(TestTags.TOPBAR_TITLE),
                style = MaterialTheme.typography.titleMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        navigationIcon = {
            if (showUp) {
                SnippetsIconButton(
                    icon = SnippetsIcon.ArrowBack,
                    contentDescription = stringResource(R.string.action_back),
                    onClick = onBack,
                    tag = TestTags.TOPBAR_BACK,
                )
            }
        },
        actions = {
            SnippetsIconButton(
                icon = when {
                    state.isSecure -> SnippetsIcon.LockOpen
                    state.showsCopiedCheck -> SnippetsIcon.Check
                    else -> SnippetsIcon.ContentCopy
                },
                contentDescription = stringResource(if (state.isSecure) R.string.editor_copy_secure else R.string.editor_copy),
                onClick = actions::onCopy,
                tag = EditorTags.COPY,
            )
            Box {
                SnippetsIconButton(
                    icon = SnippetsIcon.MoreVert,
                    contentDescription = stringResource(R.string.action_more),
                    onClick = {
                        actions.onMenuOpened()
                        menuOpen = true
                    },
                    tag = EditorTags.MORE,
                )
                EditorMoreMenu(
                    expanded = menuOpen,
                    onDismiss = { menuOpen = false },
                    isSecure = state.isSecure,
                    isPinned = state.isPinned,
                    actions = actions,
                )
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MaterialTheme.colorScheme.surface,
            scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
        scrollBehavior = scrollBehavior,
    )
}

@Composable
private fun EditorTabs(selected: EditorTab, onSelect: (EditorTab) -> Unit, hasWarning: Boolean) {
    val detailsWarning = stringResource(R.string.editor_tab_details_warning)
    SecondaryTabRow(selectedTabIndex = selected.ordinal, containerColor = MaterialTheme.colorScheme.surface) {
        Tab(
            selected = selected == EditorTab.Content,
            onClick = { onSelect(EditorTab.Content) },
            modifier = Modifier.testTag(EditorTags.TAB_CONTENT),
            text = { Text(stringResource(R.string.editor_tab_content), style = MaterialTheme.typography.labelLarge) },
        )
        Tab(
            selected = selected == EditorTab.Details,
            onClick = { onSelect(EditorTab.Details) },
            modifier = Modifier
                .testTag(EditorTags.TAB_DETAILS)
                .then(if (hasWarning) Modifier.semantics { contentDescription = detailsWarning } else Modifier),
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.editor_tab_details), style = MaterialTheme.typography.labelLarge)
                    if (hasWarning) {
                        Spacer(Modifier.width(Spacing.s))
                        Box(
                            modifier = Modifier
                                .size(Dimens.warningDot)
                                .background(SnippetsTheme.colors.warning, CircleShape)
                                .testTag(EditorTags.TAB_DETAILS_DOT),
                        )
                    }
                }
            },
        )
    }
}

/** The save-error banner (§6.7): `errorContainer`, assertive. */
@Composable
private fun SaveErrorBanner(message: String) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(EditorTags.SAVE_ERROR)
            .semantics { liveRegion = LiveRegionMode.Assertive },
        color = MaterialTheme.colorScheme.errorContainer,
        contentColor = MaterialTheme.colorScheme.onErrorContainer,
    ) {
        Row(
            modifier = Modifier.padding(horizontal = Dimens.marginCompact, vertical = Spacing.m),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Glyph(SnippetsIcon.Error, contentDescription = null, tint = MaterialTheme.colorScheme.error)
            Spacer(Modifier.width(Spacing.m))
            Text(text = message, style = MaterialTheme.typography.bodyMedium)
        }
    }
}
