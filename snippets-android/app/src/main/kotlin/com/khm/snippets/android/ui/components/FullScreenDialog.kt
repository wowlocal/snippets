package com.khm.snippets.android.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.window.SecureFlagPolicy
import androidx.core.view.WindowCompat
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/** Above this luminance a surface is light and takes dark system-bar icons. */
private const val LIGHT_SURFACE_LUMINANCE = 0.5f

/** True when the window is compact: full-screen dialogs fill it instead of floating. */
@Composable
fun isCompactWindow(): Boolean {
    val widthPx = LocalWindowInfo.current.containerSize.width
    val width = with(LocalDensity.current) { widthPx.toDp() }
    return width < Dimens.compactMaxWidth
}

/**
 * The layout of a full-screen dialog (DESIGN.md §3): a close `X` at the top start, the title, an
 * optional top-end action, scrolling content and an optional pinned bottom bar.
 *
 * Compact: fills its window and applies the safe-drawing insets (status bar, cut-out, navigation
 * bar, IME). Larger: a 560 dp surface with the dialog shape whose height the host limits to 90 %
 * of the window. This composable draws no window of its own: show it as a navigation scene or
 * inside [FullScreenDialogHost].
 *
 * @param showClose False where the screen cannot be cancelled (most secret screens).
 * @param closeEnabled False while work is running; the host also blocks back then.
 * @param closeDescription Content description of the close button; `Close` by default.
 * @param bottomBar Pinned under the content, for the primary button.
 */
@Composable
fun FullScreenDialogScaffold(
    title: String,
    onClose: () -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
    showClose: Boolean = true,
    closeEnabled: Boolean = true,
    closeDescription: String = stringResource(R.string.action_close),
    closeTag: String = TestTags.TOPBAR_CLOSE,
    topAction: (@Composable () -> Unit)? = null,
    bottomBar: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val margin = if (compact) Dimens.marginCompact else Dimens.marginMedium
    Surface(
        modifier = modifier
            .then(if (compact) Modifier.fillMaxSize() else Modifier.width(Dimens.fullScreenDialogWidth))
            .semantics { paneTitle = title },
        shape = if (compact) RectangleShape else MaterialTheme.shapes.extraLarge,
        color = if (compact) colors.surface else colors.surfaceContainerHigh,
        contentColor = colors.onSurface,
    ) {
        Column(
            modifier = if (compact) Modifier.windowInsetsPadding(WindowInsets.safeDrawing) else Modifier,
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = Dimens.fullScreenDialogBarMinHeight)
                    .padding(horizontal = Spacing.xs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (showClose) {
                    SnippetsIconButton(
                        icon = SnippetsIcon.Close,
                        contentDescription = closeDescription,
                        onClick = onClose,
                        tag = closeTag,
                        enabled = closeEnabled,
                        tint = colors.onSurface,
                    )
                }
                Text(
                    text = title,
                    modifier = Modifier
                        .weight(1f)
                        .padding(horizontal = if (showClose) Spacing.xs else Spacing.m)
                        .testTag(TestTags.TOPBAR_TITLE)
                        .semantics { heading() },
                    style = MaterialTheme.typography.titleLarge,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                topAction?.invoke()
            }
            Column(
                modifier = Modifier
                    .weight(1f, fill = compact)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = margin)
                    .padding(bottom = Spacing.l),
                content = content,
            )
            if (bottomBar != null) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = margin)
                        .padding(top = Spacing.s, bottom = if (compact) Spacing.l else Spacing.xl),
                ) {
                    bottomBar()
                }
            }
        }
    }
}

/**
 * A window for a full-screen dialog: the whole window when compact, otherwise centred over a
 * scrim with a height of at most 90 %. An outside tap never dismisses it.
 *
 * @param onDismissRequest Back. Pass a no-op while work is running, or open the leave dialog of
 *   a secret screen.
 * @param secure The content shows secret material: `SecureFlagPolicy.SecureOn`.
 * @param content Receives whether the window is compact, for [FullScreenDialogScaffold].
 */
@Composable
fun FullScreenDialogHost(
    onDismissRequest: () -> Unit,
    secure: Boolean = false,
    content: @Composable (compact: Boolean) -> Unit,
) {
    val compact = isCompactWindow()
    val windowHeightPx = LocalWindowInfo.current.containerSize.height
    val maxHeight: Dp = with(LocalDensity.current) { (windowHeightPx * Dimens.fullScreenDialogMaxHeightFraction).toDp() }
    val reducedMotion = SnippetsTheme.reducedMotion
    Dialog(
        onDismissRequest = onDismissRequest,
        properties = DialogProperties(
            dismissOnClickOutside = false,
            securePolicy = if (secure) SecureFlagPolicy.SecureOn else SecureFlagPolicy.Inherit,
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = !compact,
        ),
    ) {
        if (compact) {
            // The dialog is its own window: its system-bar icons must follow the theme too.
            val view = LocalView.current
            val lightBars = MaterialTheme.colorScheme.surface.luminance() > LIGHT_SURFACE_LUMINANCE
            SideEffect {
                val window = (view.parent as? DialogWindowProvider)?.window
                if (window != null) {
                    val controller = WindowCompat.getInsetsController(window, view)
                    controller.isAppearanceLightStatusBars = lightBars
                    controller.isAppearanceLightNavigationBars = lightBars
                }
            }
            val visible = remember { MutableTransitionState(false).apply { targetState = true } }
            AnimatedVisibility(
                visibleState = visible,
                enter = if (reducedMotion) {
                    fadeIn(tween(Motion.REDUCED_FADE))
                } else {
                    slideInVertically(tween(Motion.FULL_SCREEN_DIALOG_IN, easing = Motion.EasingEmphasized)) { it } +
                        fadeIn(tween(Motion.FULL_SCREEN_DIALOG_IN, easing = Motion.EasingEmphasized))
                },
                exit = if (reducedMotion) {
                    fadeOut(tween(Motion.REDUCED_FADE))
                } else {
                    slideOutVertically(tween(Motion.FULL_SCREEN_DIALOG_OUT, easing = Motion.EasingEmphasizedAccelerate)) { it } +
                        fadeOut(tween(Motion.FULL_SCREEN_DIALOG_OUT, easing = Motion.EasingEmphasizedAccelerate))
                },
            ) {
                content(true)
            }
        } else {
            Box(modifier = Modifier.heightIn(max = maxHeight)) {
                content(false)
            }
        }
    }
}

@Preview(name = "Full-screen dialog, compact", widthDp = 375, heightDp = 480)
@Composable
private fun FullScreenDialogPreviewCompact() = PreviewSurface(darkTheme = false, padded = false) {
    FullScreenDialogPreviewContent(compact = true)
}

@Preview(name = "Full-screen dialog, large, dark", widthDp = 700, heightDp = 480)
@Composable
private fun FullScreenDialogPreviewLarge() = PreviewSurface(darkTheme = true) {
    FullScreenDialogPreviewContent(compact = false)
}

@Composable
private fun FullScreenDialogPreviewContent(compact: Boolean) {
    FullScreenDialogScaffold(
        title = "Restore Vault Key",
        onClose = {},
        compact = compact,
        bottomBar = { SnippetsButton("Restore", onClick = {}, modifier = Modifier.fillMaxWidth()) },
    ) {
        Text(
            text = "Enter the recovery key created when Secure Snippets was set up.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Box(Modifier.size(Spacing.xl))
    }
}
