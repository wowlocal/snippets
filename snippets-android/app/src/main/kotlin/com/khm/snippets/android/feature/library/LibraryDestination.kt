package com.khm.snippets.android.feature.library

import android.content.Intent
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.pluralStringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.khm.snippets.android.R
import com.khm.snippets.android.app.AppContainer
import com.khm.snippets.android.feature.shared.CollectEffects
import com.khm.snippets.android.feature.shared.LocalAppSnackbars
import com.khm.snippets.android.feature.shared.requestFocusIfAttached
import com.khm.snippets.android.feature.shared.resolve
import com.khm.snippets.android.nav.AppNavigator
import com.khm.snippets.android.nav.WindowLayout
import com.khm.snippets.android.platform.AppShortcut
import com.khm.snippets.android.ui.components.rememberAnnouncer
import com.khm.snippets.android.ui.components.rememberSnippetsHaptics
import com.khm.snippets.android.ui.model.SnippetRowAction
import kotlinx.coroutines.android.awaitFrame
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first

/**
 * The `library` entry of the navigation host: creates the ViewModel, turns its effects into
 * navigation, snackbars, haptics and announcements, handles the hardware-keyboard shortcuts
 * and back with a query (DESIGN.md §3.3 rule 4), then draws [LibraryScreen].
 */
@Composable
fun LibraryDestination(
    container: AppContainer,
    navigator: AppNavigator,
    layout: WindowLayout,
) {
    val viewModel: LibraryViewModel = viewModel(factory = LibraryViewModel.factory(container))
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val countdown by viewModel.countdown.collectAsStateWithLifecycle()
    val isTwoPane = layout.isTwoPane
    val selectedId = if (isTwoPane) navigator.selectedSnippetId else null
    val searchFocus = remember { FocusRequester() }
    val firstRowFocus = remember { FocusRequester() }
    var focusedRowId by remember { mutableStateOf<String?>(null) }
    val snackbars = LocalAppSnackbars.current
    val haptics = rememberSnippetsHaptics()
    val announcer = rememberAnnouncer()
    val context = LocalContext.current
    val activity = LocalActivity.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current

    LaunchedEffect(selectedId) { viewModel.onSelectionChanged(selectedId) }

    CollectEffects(viewModel.effects) { effect ->
        when (effect) {
            is LibraryEffect.OpenEditor -> navigator.openEditor(effect.id, effect.focusBody)
            is LibraryEffect.SelectAfterRemoval -> if (isTwoPane) {
                val next = effect.id
                if (next != null) navigator.openEditor(next) else navigator.selectedSnippetId?.let(navigator::closeEditor)
            }
            is LibraryEffect.Navigate -> navigator.navigate(effect.route)
            is LibraryEffect.OpenSettings -> navigator.openSettings(effect.pane, isTwoPane)
            is LibraryEffect.ShowSnackbar -> snackbars.show(effect.request)
            is LibraryEffect.Haptic -> haptics.perform(effect.haptic)
            is LibraryEffect.Announce -> announcer.announce(effect.message.resolve(context.resources))
            LibraryEffect.OpenSecuritySettings -> context.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
            LibraryEffect.ShowKeyboardShortcuts -> activity?.requestShowKeyboardShortcuts()
        }
    }

    // Rule 4 of back: a query is cleared first. Tag filters stay.
    BackHandler(enabled = viewModel.query.isNotEmpty() && state.sheet == null && state.dialog == null) {
        viewModel.onClearQuery()
        focusManager.clearFocus(force = true)
    }

    // `%d results`, once typing has paused for a second (§2.9).
    val results = pluralStringResource(R.plurals.library_results_announcement, state.visibleCount, state.visibleCount)
    LaunchedEffect(viewModel.query, state.visibleCount) {
        if (viewModel.query.isBlank()) return@LaunchedEffect
        delay(RESULTS_ANNOUNCEMENT_DELAY_MILLIS)
        announcer.announce(results)
    }

    // A hardware-keyboard launch starts with focus on the first row (§8). Decided once, when
    // the first rows appear: switching input mode later must never move focus.
    val inputModeManager = LocalInputModeManager.current
    var initialFocusDecided by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (initialFocusDecided) return@LaunchedEffect
        snapshotFlow { viewModel.uiState.value.content }.first { it !is LibraryContent.Loading }
        initialFocusDecided = true
        if (inputModeManager.inputMode == InputMode.Keyboard && viewModel.uiState.value.content == LibraryContent.Rows) {
            awaitFrame()
            firstRowFocus.requestFocusIfAttached()
        }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(container.shortcuts, lifecycleOwner, isTwoPane) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            container.shortcuts.shortcuts.collect { shortcut ->
                when (shortcut) {
                    AppShortcut.Search -> {
                        searchFocus.requestFocusIfAttached()
                        keyboard?.show()
                    }
                    AppShortcut.NewSnippet -> viewModel.onNewSnippet()
                    AppShortcut.NewFromClipboard -> viewModel.onNewFromClipboard()
                    AppShortcut.EditSnippet -> if (!isTwoPane) focusedRowId?.let { navigator.openEditor(it) }
                    AppShortcut.DeleteSnippet -> (selectedId ?: focusedRowId)?.let { viewModel.onRowAction(it, SnippetRowAction.Delete) }
                    AppShortcut.ReturnToList -> firstRowFocus.requestFocusIfAttached()
                    AppShortcut.Import -> viewModel.onImport()
                    AppShortcut.Export -> viewModel.onExport()
                    AppShortcut.Undo -> snackbars.undoIfShowing()
                    AppShortcut.Settings -> viewModel.onOpenSettings()
                }
            }
        }
    }

    LibraryScreen(
        state = state,
        query = viewModel.query,
        countdown = countdown,
        actions = viewModel,
        layout = layout,
        isTwoPane = isTwoPane,
        selectedId = selectedId,
        onSelect = { id -> navigator.openEditor(id) },
        searchFocus = searchFocus,
        firstRowFocus = firstRowFocus,
        onRowFocused = { id ->
            val movedBetweenRows = focusedRowId != null
            focusedRowId = id
            // Two panes: the selection follows focus moving from row to row (§8, ↓ / ↑). Focus
            // arriving in the list from elsewhere (first focus, a resized window) keeps it.
            if (isTwoPane && movedBetweenRows && id != null && id != navigator.selectedSnippetId) navigator.openEditor(id)
        },
    )
}

private const val RESULTS_ANNOUNCEMENT_DELAY_MILLIS = 1_000L
