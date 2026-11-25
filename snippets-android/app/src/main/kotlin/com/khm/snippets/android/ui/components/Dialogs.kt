package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Spacing
import kotlin.math.max

/**
 * The confirmation dialog template (components.md §16.1).
 *
 * The title names the object and the action; the body states the consequence; the confirm
 * button is the verb (never `Yes`). Back and an outside tap equal the dismiss button. Buttons
 * are end-aligned in the order dismiss, neutral, confirm; when they do not fit, or with three
 * buttons, they are stacked with confirm on top.
 *
 * @param tag The dialog's route tag on its root, for example `dialog.delete-secure`.
 * @param paragraphs The body, one entry per paragraph.
 * @param confirmLabel The verb, or null for a dialog that only informs (`Turn off sync first.`).
 * @param destructive Draws the confirm button in `error`.
 * @param warningIcon Shows the `warning` icon in `error` tint (changed host key and the like).
 * @param showsSecret The dialog itself shows secret material: `SecureFlagPolicy.SecureOn`.
 */
@Composable
fun ConfirmDialog(
    tag: String,
    title: String,
    paragraphs: List<String>,
    dismissLabel: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    confirmLabel: String? = null,
    onConfirm: () -> Unit = {},
    neutralLabel: String? = null,
    onNeutral: () -> Unit = {},
    destructive: Boolean = false,
    warningIcon: Boolean = false,
    showsSecret: Boolean = false,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            DialogButtons(alwaysStacked = confirmLabel != null && neutralLabel != null) {
                // Declared in stacking order: confirm on top.
                if (confirmLabel != null) {
                    SnippetsButton(
                        label = confirmLabel,
                        onClick = onConfirm,
                        modifier = Modifier.testTag(TestTags.DIALOG_CONFIRM),
                        level = ButtonLevel.Tertiary,
                        destructive = destructive,
                    )
                }
                if (neutralLabel != null) {
                    SnippetsButton(
                        label = neutralLabel,
                        onClick = onNeutral,
                        modifier = Modifier.testTag(TestTags.DIALOG_NEUTRAL),
                        level = ButtonLevel.Tertiary,
                    )
                }
                SnippetsButton(
                    label = dismissLabel,
                    onClick = onDismiss,
                    modifier = Modifier.testTag(TestTags.DIALOG_DISMISS),
                    level = ButtonLevel.Tertiary,
                )
            }
        },
        modifier = modifier.testTag(tag),
        icon = if (warningIcon) {
            { Glyph(SnippetsIcon.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error) }
        } else {
            null
        },
        title = {
            Text(
                text = title,
                modifier = Modifier
                    .testTag(TestTags.DIALOG_TITLE)
                    .semantics { heading() },
            )
        },
        text = {
            Column(
                modifier = Modifier
                    .verticalScroll(rememberScrollState())
                    .semantics(mergeDescendants = true) { }
                    .testTag(TestTags.DIALOG_MESSAGE),
                verticalArrangement = Arrangement.spacedBy(Dimens.dialogParagraphGap),
            ) {
                paragraphs.forEach { Text(it) }
            }
        },
        properties = DialogProperties(
            securePolicy = if (showsSecret) SecureFlagPolicy.SecureOn else SecureFlagPolicy.Inherit,
        ),
    )
}

/**
 * Lays dialog buttons out end-aligned on one row in reverse declaration order (so the first
 * child, confirm, is last), or stacked in declaration order when they do not fit.
 */
@Composable
private fun DialogButtons(
    alwaysStacked: Boolean,
    content: @Composable () -> Unit,
) {
    Layout(content = content) { measurables, constraints ->
        val gap = Spacing.s.roundToPx()
        val placeables = measurables.map { it.measure(Constraints(maxWidth = constraints.maxWidth)) }
        val rowWidth = placeables.sumOf { it.width } + gap * (placeables.size - 1).coerceAtLeast(0)
        val stacked = alwaysStacked || rowWidth > constraints.maxWidth
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else rowWidth
        if (stacked) {
            val height = placeables.sumOf { it.height }
            layout(width, height) {
                var y = 0
                placeables.forEach { placeable ->
                    placeable.placeRelative(width - placeable.width, y)
                    y += placeable.height
                }
            }
        } else {
            val height = placeables.fold(0) { acc, placeable -> max(acc, placeable.height) }
            layout(width, height) {
                var x = width
                placeables.forEach { placeable ->
                    x -= placeable.width
                    placeable.placeRelative(x, (height - placeable.height) / 2)
                    x -= gap
                }
            }
        }
    }
}

/**
 * The error dialog (components.md §16.2): a `Couldn’t …` title, the error sentence and `OK`.
 * `OK` is the dismiss button (`dialog.dismiss`); an optional recovery button is the confirm
 * button (`dialog.confirm`). The root tag is `dialog.error`.
 */
@Composable
fun ErrorDialog(
    title: String,
    message: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    recoveryLabel: String? = null,
    onRecovery: () -> Unit = {},
) {
    ConfirmDialog(
        tag = TestTags.DIALOG_ERROR,
        title = title,
        paragraphs = listOf(message),
        dismissLabel = stringResource(R.string.action_ok),
        onDismiss = onDismiss,
        modifier = modifier,
        confirmLabel = recoveryLabel,
        onConfirm = onRecovery,
    )
}

/**
 * The leave dialog of a secret screen (components.md §16.3): `Have You Saved It?`, the screen's
 * own sentence, `Go Back` and the screen's primary button title.
 *
 * @param onGoBack Returns to the secret screen.
 * @param onLeave Same result as the screen's primary button.
 */
@Composable
fun SecretLeaveDialog(
    message: String,
    leaveLabel: String,
    onGoBack: () -> Unit,
    onLeave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ConfirmDialog(
        tag = TestTags.DIALOG_SECRET_LEAVE,
        title = stringResource(R.string.secret_leave_title),
        paragraphs = listOf(message),
        dismissLabel = stringResource(R.string.action_go_back),
        onDismiss = onGoBack,
        modifier = modifier,
        confirmLabel = leaveLabel,
        onConfirm = onLeave,
    )
}

/**
 * A dialog that reports progress (`dialog/switch-progress`): no buttons, and neither back nor an
 * outside tap dismisses it.
 */
@Composable
fun ProgressDialog(
    tag: String,
    title: String,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    AlertDialog(
        onDismissRequest = {},
        confirmButton = {},
        modifier = modifier.testTag(tag),
        title = {
            Text(
                text = title,
                modifier = Modifier
                    .testTag(TestTags.DIALOG_TITLE)
                    .semantics { heading() },
            )
        },
        text = content,
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
    )
}

@Preview(name = "Confirm dialog, light")
@Composable
private fun ConfirmDialogPreviewLight() = PreviewSurface(darkTheme = false) { ConfirmDialogPreviewContent() }

@Preview(name = "Confirm dialog, dark")
@Composable
private fun ConfirmDialogPreviewDark() = PreviewSurface(darkTheme = true) { ConfirmDialogPreviewContent() }

@Composable
private fun ConfirmDialogPreviewContent() {
    ConfirmDialog(
        tag = "dialog.delete-secure",
        title = "Delete “Atlas API token”?",
        paragraphs = listOf(
            "This permanently removes the encrypted snippet from this device and, when sync is on, from your other devices.",
        ),
        dismissLabel = "Cancel",
        onDismiss = {},
        confirmLabel = "Delete",
        destructive = true,
    )
}
