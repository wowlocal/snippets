package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Spacing

/**
 * An empty state (components.md §6), centred in the area it is given. The block scrolls by
 * itself so it never clips at large font scales or in short windows.
 *
 * Test tags are `<tagArea>.empty` with `.title`, `.message`, `.note` and, for the actions in the
 * order they are shown, `.action`, `.action-2`, `.action-3`.
 *
 * @param icon Glyph (40 dp), or null for none. Ignored while [loading].
 * @param loading Shows a 24 dp spinner in place of the glyph.
 * @param primaryAction Label of the filled button.
 * @param textActions Labels of up to two text buttons; [onTextAction] receives the index.
 * @param note Small print under the actions.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun EmptyState(
    tagArea: String,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    icon: SnippetsIcon? = null,
    iconTint: Color = Color.Unspecified,
    loading: Boolean = false,
    primaryAction: String? = null,
    onPrimaryAction: () -> Unit = {},
    textActions: List<String> = emptyList(),
    onTextAction: (index: Int) -> Unit = {},
    note: String? = null,
) {
    val colors = MaterialTheme.colorScheme
    BoxWithConstraints(
        modifier = modifier.fillMaxWidth().testTag(tagArea + TestTags.Empty.ROOT),
        contentAlignment = Alignment.Center,
    ) {
        // In an area of its own the block scrolls; inside a scrolling parent it just takes its height.
        val scroll = if (constraints.hasBoundedHeight) Modifier.verticalScroll(rememberScrollState()) else Modifier
        Column(
            modifier = scroll.padding(horizontal = Dimens.marginMedium, vertical = Spacing.l),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(Dimens.spinnerEmptyState),
                    strokeWidth = Dimens.spinnerStroke,
                )
                Spacer(Modifier.height(Spacing.l))
            } else if (icon != null) {
                Glyph(
                    icon = icon,
                    contentDescription = null,
                    tint = if (iconTint.isSpecified) iconTint else colors.onSurfaceVariant,
                    size = Dimens.iconEmptyState,
                )
                Spacer(Modifier.height(Spacing.l))
            }
            Text(
                text = title,
                modifier = Modifier
                    .testTag(tagArea + TestTags.Empty.TITLE)
                    .semantics { heading() },
                style = MaterialTheme.typography.titleLarge,
                color = colors.onSurface,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(Spacing.s))
            Text(
                text = message,
                modifier = Modifier
                    .widthIn(max = Dimens.emptyStateMessageMaxWidth)
                    .testTag(tagArea + TestTags.Empty.MESSAGE),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            val actionTags = listOf(TestTags.Empty.ACTION, TestTags.Empty.ACTION_2, TestTags.Empty.ACTION_3)
            var nextTag = 0
            if (primaryAction != null) {
                Spacer(Modifier.height(Spacing.xl))
                SnippetsButton(
                    label = primaryAction,
                    onClick = onPrimaryAction,
                    modifier = Modifier.testTag(tagArea + actionTags[nextTag++]),
                )
            }
            val shownTextActions = textActions.take(actionTags.size - nextTag)
            if (shownTextActions.isNotEmpty()) {
                Spacer(Modifier.height(if (primaryAction != null) Spacing.s else Spacing.xl))
                FlowRow(horizontalArrangement = Arrangement.Center) {
                    shownTextActions.forEachIndexed { index, label ->
                        SnippetsButton(
                            label = label,
                            onClick = { onTextAction(index) },
                            modifier = Modifier.testTag(tagArea + actionTags[nextTag + index]),
                            level = ButtonLevel.Tertiary,
                        )
                    }
                }
            }
            if (note != null) {
                Spacer(Modifier.height(Spacing.l))
                Text(
                    text = note,
                    modifier = Modifier
                        .widthIn(max = Dimens.emptyStateMessageMaxWidth)
                        .testTag(tagArea + TestTags.Empty.NOTE),
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Preview(name = "Empty state, light")
@Composable
private fun EmptyStatePreviewLight() = PreviewSurface(darkTheme = false) { EmptyStatePreviewContent() }

@Preview(name = "Empty state, dark")
@Composable
private fun EmptyStatePreviewDark() = PreviewSurface(darkTheme = true) { EmptyStatePreviewContent() }

@Composable
private fun EmptyStatePreviewContent() {
    EmptyState(
        tagArea = "library",
        title = "Your Library Is Empty",
        message = "Create a snippet, import a library, or set up sync to fetch the library from your other devices.",
        icon = SnippetsIcon.Description,
        primaryAction = "New Snippet",
        textActions = listOf("Import…", "Set Up Sync"),
        note = "Sync is optional. Everything works on this device without an account.",
    )
}
