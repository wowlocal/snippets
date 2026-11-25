package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.ReviewUi
import com.khm.snippets.android.ui.theme.Spacing

/**
 * The Review screen template (components.md §15): one layout for every sync halt and recovery
 * action. The order is fixed: heading, what happened, what this does, on this device, details,
 * actions.
 *
 * The primary button carries the confirmation title and uses the error colours when the action
 * is destructive. While the action runs it shows a spinner, both buttons and the close button
 * are disabled, and the host blocks back. A halt without an action has `Close` as its only
 * button. A failure of the action shows as a problem card above the buttons.
 *
 * @param onDismiss `Not Now`, `Close` and the close button: leave without changes.
 * @param onCopyCode An ordinary copy of the halt code (also the code of the problem card).
 */
@Composable
fun ReviewScreen(
    ui: ReviewUi,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    onCopyCode: () -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
    onProblemAction: () -> Unit = {},
) {
    val colors = MaterialTheme.colorScheme
    FullScreenDialogScaffold(
        title = ui.title,
        onClose = onDismiss,
        compact = compact,
        modifier = modifier.testTag(TestTags.REVIEW_SCREEN),
        closeEnabled = !ui.isRunning,
        bottomBar = {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = if (ui.confirmTitle != null) Arrangement.SpaceBetween else Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SnippetsButton(
                    label = stringResource(if (ui.confirmTitle != null) R.string.action_not_now else R.string.action_close),
                    onClick = onDismiss,
                    modifier = Modifier.testTag(TestTags.REVIEW_DISMISS),
                    level = ButtonLevel.Tertiary,
                    enabled = !ui.isRunning,
                )
                if (ui.confirmTitle != null) {
                    Spacer(Modifier.width(Spacing.s))
                    SnippetsButton(
                        label = ui.confirmTitle,
                        onClick = onConfirm,
                        modifier = Modifier.weight(1f, fill = false).testTag(TestTags.REVIEW_CONFIRM),
                        working = ui.isRunning,
                        destructive = ui.isDestructive,
                    )
                }
            }
        },
    ) {
        Spacer(Modifier.height(Spacing.s))
        Text(
            text = ui.heading,
            modifier = Modifier
                .testTag(TestTags.REVIEW_HEADING)
                .semantics { heading() },
            style = MaterialTheme.typography.headlineSmall,
        )
        ReviewSection(title = stringResource(R.string.review_happened)) {
            Text(
                text = ui.happened,
                modifier = Modifier.testTag(TestTags.REVIEW_HAPPENED),
                style = MaterialTheme.typography.bodyLarge,
            )
        }
        if (ui.explanation != null) {
            ReviewSection(title = stringResource(R.string.review_explanation)) {
                Text(
                    text = ui.explanation,
                    modifier = Modifier.testTag(TestTags.REVIEW_EXPLANATION),
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }
        ReviewSection(title = stringResource(R.string.review_device)) {
            Row(verticalAlignment = Alignment.Top) {
                Glyph(SnippetsIcon.Smartphone, contentDescription = null, tint = colors.onSurfaceVariant)
                Spacer(Modifier.width(Spacing.s))
                Text(
                    text = ui.onDevice,
                    modifier = Modifier.testTag(TestTags.REVIEW_DEVICE),
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }
        Spacer(Modifier.height(Spacing.l))
        CodeDisclosure(
            code = ui.code,
            onCopyCode = onCopyCode,
            detailsTag = TestTags.REVIEW_DETAILS,
            codeTag = TestTags.REVIEW_CODE,
            copyTag = TestTags.REVIEW_CODE_COPY,
        )
        if (ui.problem != null) {
            Spacer(Modifier.height(Spacing.l))
            ProblemCard(
                problem = ui.problem,
                tagArea = "review",
                onCopyCode = onCopyCode,
                onPrimaryAction = onProblemAction,
            )
        }
    }
}

@Composable
private fun ReviewSection(
    title: String,
    content: @Composable () -> Unit,
) {
    Spacer(Modifier.height(Spacing.xl))
    Text(
        text = title,
        modifier = Modifier.semantics { heading() },
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.titleSmall,
    )
    Spacer(Modifier.height(Spacing.xs))
    content()
}

private val PreviewReview = ReviewUi(
    title = "Sync Stopped",
    heading = "Apply These Deletions?",
    happened = "Stopped because an unusually large deletion arrived: sync reported a batch that would remove 96 of 128 snippets.",
    explanation = "These deletions did not include proof of intent. Applying them removes the snippets from this device.",
    onDevice = "128 snippets. Nothing has been changed on this device yet.",
    code = "mass_deletion",
    confirmTitle = "Apply Deletions",
    isDestructive = true,
)

@Preview(name = "Review screen, light", widthDp = 375, heightDp = 720)
@Composable
private fun ReviewScreenPreviewLight() = PreviewSurface(darkTheme = false, padded = false) {
    ReviewScreen(PreviewReview, onConfirm = {}, onDismiss = {}, onCopyCode = {}, compact = true)
}

@Preview(name = "Review screen, dark", widthDp = 375, heightDp = 720)
@Composable
private fun ReviewScreenPreviewDark() = PreviewSurface(darkTheme = true, padded = false) {
    ReviewScreen(PreviewReview, onConfirm = {}, onDismiss = {}, onCopyCode = {}, compact = true)
}
