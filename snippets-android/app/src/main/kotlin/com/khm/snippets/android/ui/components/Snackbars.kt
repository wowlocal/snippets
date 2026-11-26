package com.khm.snippets.android.ui.components

import android.content.Context
import android.os.Build
import android.view.accessibility.AccessibilityManager
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarData
import androidx.compose.material3.SnackbarDefaults
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.theme.Dimens
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** How long a snackbar stays (components.md §17). */
enum class SnackbarKind {
    /** The result of an action: 4 s without an action, 10 s (or longer for accessibility) with one. */
    Result,

    /** A progress note (`Reading import…`): stays until its result replaces it. */
    Progress,

    /** A one-time hint (the swipe tip): stays 5 s. */
    Tip,
}

/** Timings of the snackbar rules. */
object SnackbarTiming {
    const val WITHOUT_ACTION_MILLIS = 4_000L
    const val WITH_ACTION_MILLIS = 10_000L
    const val TOUCH_EXPLORATION_FLOOR_MILLIS = 20_000L
    const val TIP_MILLIS = 5_000L

    /**
     * How long a snackbar with an action stays: 10 s, or with touch exploration on the
     * accessibility-recommended timeout for 10 s with a floor of 20 s.
     *
     * @param recommended `AccessibilityManager.getRecommendedTimeoutMillis` for a base timeout.
     */
    fun withAction(touchExploration: Boolean, recommended: (baseMillis: Long) -> Long): Long =
        if (touchExploration) {
            maxOf(TOUCH_EXPLORATION_FLOOR_MILLIS, recommended(WITH_ACTION_MILLIS))
        } else {
            WITH_ACTION_MILLIS
        }
}

/**
 * Feeds the window's one `SnackbarHost` and applies the snackbar rules: a new snackbar replaces
 * the current one immediately, an action runs at most once, and durations follow
 * [SnackbarTiming].
 *
 * Snackbars are for results that need no decision and for progress notes: never for errors that
 * need a decision, routine sync, an ordinary copy on API 33+, a secure copy, or anything on a
 * secret screen.
 */
@Stable
class SnackbarController internal constructor(
    val hostState: SnackbarHostState,
    private val scope: CoroutineScope,
    private val actionTimeoutMillis: () -> Long,
) {
    private var current: Job? = null

    /**
     * Shows [message] (one or two sentences ending with a full stop; names in `“ ”`).
     *
     * @param actionLabel At most one action, a verb (`Undo`, `Share`).
     * @param onAction Runs at most once: it is cleared before it runs.
     */
    fun show(
        message: String,
        actionLabel: String? = null,
        kind: SnackbarKind = SnackbarKind.Result,
        onAction: (() -> Unit)? = null,
    ) {
        current?.cancel()
        var pendingAction = onAction
        current = scope.launch {
            hostState.currentSnackbarData?.dismiss()
            val result = when {
                kind == SnackbarKind.Progress -> hostState.showSnackbar(message, duration = SnackbarDuration.Indefinite)
                kind == SnackbarKind.Tip -> withTimeoutOrNull(SnackbarTiming.TIP_MILLIS) {
                    hostState.showSnackbar(message, duration = SnackbarDuration.Indefinite)
                }
                actionLabel == null -> hostState.showSnackbar(message, duration = SnackbarDuration.Short)
                else -> withTimeoutOrNull(actionTimeoutMillis()) {
                    hostState.showSnackbar(message, actionLabel = actionLabel, duration = SnackbarDuration.Indefinite)
                }
            }
            if (result == SnackbarResult.ActionPerformed) {
                val action = pendingAction
                pendingAction = null
                action?.invoke()
            }
        }
    }

    /** Removes the current snackbar, for example when its progress ended without a result. */
    fun dismiss() {
        current?.cancel()
        current = null
    }
}

@Composable
fun rememberSnackbarController(
    hostState: SnackbarHostState = remember { SnackbarHostState() },
): SnackbarController {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    return remember(hostState, scope, context) {
        val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        SnackbarController(hostState, scope) {
            SnackbarTiming.withAction(touchExploration = manager?.isTouchExplorationEnabled == true) { base ->
                // The recommended timeout exists from API 29; below it the floor alone applies.
                if (manager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    manager.getRecommendedTimeoutMillis(
                        base.toInt(),
                        AccessibilityManager.FLAG_CONTENT_TEXT or AccessibilityManager.FLAG_CONTENT_CONTROLS,
                    ).toLong()
                } else {
                    base
                }
            }
        }
    }
}

/**
 * The window's snackbar host (components.md §17). M3 colours; the text is tagged `snackbar`, its
 * action `snackbar.action`. A screen reader hears the message, or `message action available.`
 *
 * Place it in the root scaffold's `snackbarHost` slot, which keeps it above the navigation bar,
 * the IME and the FAB.
 *
 * @param compact True: full width with 16 dp margins. False: at most 400 dp wide at the bottom
 *   start of its pane, with 24 dp margins.
 */
@Composable
fun SnippetsSnackbarHost(
    hostState: SnackbarHostState,
    modifier: Modifier = Modifier,
    compact: Boolean = true,
) {
    SnackbarHost(hostState = hostState, modifier = modifier) { data ->
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    horizontal = if (compact) Dimens.marginCompact else Dimens.marginMedium,
                    vertical = if (compact) Dimens.marginCompact / 2 else Dimens.marginMedium,
                ),
            contentAlignment = if (compact) Alignment.Center else Alignment.CenterStart,
        ) {
            // No fillMaxWidth: M3's snackbar already takes the available width (up to 600 dp),
            // and tight width constraints make its one-row layout place the action at the start.
            SnippetsSnackbar(
                data = data,
                modifier = if (compact) Modifier else Modifier.widthIn(max = Dimens.snackbarMaxWidth),
            )
        }
    }
}

@Composable
private fun SnippetsSnackbar(
    data: SnackbarData,
    modifier: Modifier = Modifier,
) {
    val message = data.visuals.message
    val actionLabel = data.visuals.actionLabel
    val spoken = if (actionLabel != null) {
        stringResource(R.string.snackbar_action_available, message, actionLabel)
    } else {
        message
    }
    Snackbar(
        modifier = modifier,
        action = actionLabel?.let { label ->
            {
                TextButton(
                    onClick = { data.performAction() },
                    modifier = Modifier.testTag(TestTags.SNACKBAR_ACTION),
                    colors = ButtonDefaults.textButtonColors(contentColor = SnackbarDefaults.actionColor),
                ) {
                    Text(label)
                }
            }
        },
    ) {
        Text(
            text = message,
            modifier = Modifier
                .testTag(TestTags.SNACKBAR)
                .semantics { contentDescription = spoken },
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Preview(name = "Snackbar, light", widthDp = 375)
@Composable
private fun SnackbarPreviewLight() = PreviewSurface(darkTheme = false) { SnackbarPreviewContent() }

@Preview(name = "Snackbar, dark", widthDp = 375)
@Composable
private fun SnackbarPreviewDark() = PreviewSurface(darkTheme = true) { SnackbarPreviewContent() }

@Composable
private fun SnackbarPreviewContent() {
    Snackbar(
        action = {
            TextButton(
                onClick = {},
                colors = ButtonDefaults.textButtonColors(contentColor = SnackbarDefaults.actionColor),
            ) {
                Text("Undo")
            }
        },
    ) {
        Text("Deleted “Quick reply”.")
    }
}
