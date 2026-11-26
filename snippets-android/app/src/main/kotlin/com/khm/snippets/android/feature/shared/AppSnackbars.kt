package com.khm.snippets.android.feature.shared

import android.content.res.Resources
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.khm.snippets.android.R
import com.khm.snippets.android.data.UndoToken
import com.khm.snippets.android.ui.components.SnackbarController
import com.khm.snippets.android.ui.components.SnackbarKind

/**
 * A snackbar a ViewModel asks for, through its effects. The screen hands it to [AppSnackbars].
 *
 * @param undo Adds the `Undo` action for this deletion.
 */
@Immutable
data class SnackbarRequest(
    val message: UiText,
    val kind: SnackbarKind = SnackbarKind.Result,
    val undo: UndoToken? = null,
)

/**
 * The window's snackbars (components.md §17): one host for every screen, so a snackbar raised
 * by a screen that closes (delete in the editor) stays visible on the one that follows. Undo is
 * performed through [onUndo], which is application-scoped, never through a ViewModel that may
 * already be gone.
 */
@Stable
class AppSnackbars internal constructor(
    val controller: SnackbarController,
    private val resources: Resources,
    private val undoLabel: String,
    private val onUndo: (UndoToken) -> Unit,
) {
    fun show(request: SnackbarRequest) {
        val token = request.undo
        controller.show(
            message = request.message.resolve(resources),
            actionLabel = if (token != null) undoLabel else null,
            kind = request.kind,
            onAction = token?.let { { onUndo(it) } },
        )
    }

    /** Ctrl+Z with list focus: undoes the deletion whose `Undo` snackbar is showing. */
    fun undoIfShowing(): Boolean {
        val data = controller.hostState.currentSnackbarData ?: return false
        if (data.visuals.actionLabel != undoLabel) return false
        data.performAction()
        return true
    }
}

@Composable
fun rememberAppSnackbars(controller: SnackbarController, onUndo: (UndoToken) -> Unit): AppSnackbars {
    val resources = LocalContext.current.resources
    val undoLabel = stringResource(R.string.action_undo)
    return remember(controller, resources, undoLabel, onUndo) { AppSnackbars(controller, resources, undoLabel, onUndo) }
}

/** The window's [AppSnackbars]; provided by the app shell. */
val LocalAppSnackbars = staticCompositionLocalOf<AppSnackbars> { error("AppSnackbars are provided by the app shell") }
