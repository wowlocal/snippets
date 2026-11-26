package com.khm.snippets.android.feature.editor

import android.content.Intent
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.khm.snippets.android.R
import com.khm.snippets.android.app.AppContainer
import com.khm.snippets.android.feature.shared.CollectEffects
import com.khm.snippets.android.feature.shared.LocalAppSnackbars
import com.khm.snippets.android.feature.shared.requestFocusIfAttached
import com.khm.snippets.android.feature.shared.toUuidOrNull
import com.khm.snippets.android.nav.AppNavigator
import com.khm.snippets.android.nav.EditorRoute
import com.khm.snippets.android.nav.WindowLayout
import com.khm.snippets.android.platform.AppShortcut
import com.khm.snippets.android.platform.SecureWindowEffect
import com.khm.snippets.android.ui.components.rememberSnippetsHaptics
import com.khm.snippets.android.ui.model.SecurePanelState
import kotlinx.coroutines.android.awaitFrame

/**
 * The `editor/{id}` entry: the ViewModel of one entry, its effects (close, switch to a copy,
 * share, snackbars), `FLAG_SECURE` while a body is revealed or being unlocked, the stop flush,
 * the first focus of a new entry, and the editor's shortcuts.
 */
@Composable
fun EditorDestination(
    route: EditorRoute,
    container: AppContainer,
    navigator: AppNavigator,
    layout: WindowLayout,
) {
    val id = route.id.toUuidOrNull()
    if (id == null) {
        LaunchedEffect(route) { navigator.closeEditor(route.id) }
        return
    }
    val isTwoPane = layout.isTwoPane
    val standIn = stringResource(R.string.editor_preview_clipboard)
    val viewModel: EditorViewModel = viewModel(key = route.id, factory = EditorViewModel.factory(container, id, standIn))
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val countdown by viewModel.countdown.collectAsStateWithLifecycle()
    val focus = remember { EditorFocus() }
    val snackbars = LocalAppSnackbars.current
    val haptics = rememberSnippetsHaptics()
    val context = LocalContext.current
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    var focusSecureBody by remember { mutableStateOf(false) }

    CollectEffects(viewModel.effects) { effect ->
        when (effect) {
            // Two panes: after a delete here the library selects the neighbour itself.
            is EditorEffect.Close -> if (!isTwoPane || effect.reason != EditorCloseReason.Deleted) navigator.closeEditor(route.id)
            is EditorEffect.OpenEditor -> navigator.openEditor(effect.id)
            is EditorEffect.ShowSnackbar -> snackbars.show(effect.request)
            is EditorEffect.Haptic -> haptics.perform(effect.haptic)
            is EditorEffect.Share -> container.shareSheet.shareText(effect.text, effect.title)
            EditorEffect.HideKeyboard -> {
                keyboard?.hide()
                focusManager.clearFocus()
            }
            EditorEffect.FocusSecureBody -> focusSecureBody = true
            EditorEffect.OpenSecuritySettings -> context.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
            is EditorEffect.OpenSettings -> navigator.openSettings(effect.pane, isTwoPane)
        }
    }

    val panel = viewModel.securePanel
    SecureWindowEffect(active = panel is SecurePanelState.Revealed || panel == SecurePanelState.Unlocking)
    LaunchedEffect(focusSecureBody, panel is SecurePanelState.Revealed) {
        if (focusSecureBody && panel is SecurePanelState.Revealed) {
            awaitFrame()
            focus.secureBody.requestFocusIfAttached()
            focusSecureBody = false
        }
    }

    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { viewModel.onStop() }

    // A new entry opens with the body focused and the keyboard up, once (§2.2).
    var initialFocusDone by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state.status) {
        if (route.focusBody && !initialFocusDone && state.status == EditorStatus.Ready && !state.isSecure) {
            awaitFrame()
            initialFocusDone = focus.body.requestFocusIfAttached()
            keyboard?.show()
        }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(container.shortcuts, lifecycleOwner, isTwoPane, state.isSecure) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            container.shortcuts.shortcuts.collect { shortcut ->
                when (shortcut) {
                    // Two panes: the library moves focus to the list; a phone goes back.
                    AppShortcut.ReturnToList -> if (!isTwoPane) navigator.back(isTwoPane = false)
                    AppShortcut.EditSnippet -> if (isTwoPane) {
                        (if (state.isSecure) focus.name else focus.body).requestFocusIfAttached()
                    }
                    else -> Unit
                }
            }
        }
    }

    EditorScreen(
        state = state,
        draft = viewModel,
        countdown = countdown,
        actions = viewModel,
        isTwoPane = isTwoPane,
        onBack = { navigator.back(isTwoPane) },
        focus = focus,
        onClearClipboardNow = container.clipboard::clearSecureNow,
    )
}
