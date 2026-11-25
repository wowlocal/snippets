package com.khm.snippets.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.model.TextHighlight
import com.khm.snippets.android.ui.model.highlightedString
import com.khm.snippets.android.ui.model.shiftHighlights
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing

/**
 * A keyword drawn as `\keyword` (components.md §2). Not a chip and not clickable; its semantics
 * belong to the row that shows it.
 *
 * @param keyword Without the backslash, which is display only.
 * @param enabled False strikes the token through and uses `onSurfaceVariant`.
 * @param onSelectedRow The background becomes `surface` so it stays visible on a selected row.
 * @param highlights Search matches inside [keyword].
 */
@Composable
fun KeywordToken(
    keyword: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onSelectedRow: Boolean = false,
    highlights: List<TextHighlight> = emptyList(),
) {
    val colors = MaterialTheme.colorScheme
    val display = stringResource(R.string.keyword_token, keyword)
    val highlightBackground = colors.tertiaryContainer
    val highlightForeground = colors.onTertiaryContainer
    val text = remember(display, keyword, highlights, highlightBackground, highlightForeground) {
        val prefixLength = (display.length - keyword.length).coerceAtLeast(0)
        highlightedString(
            text = display,
            ranges = shiftHighlights(highlights, prefixLength),
            background = highlightBackground,
            foreground = highlightForeground,
        )
    }
    Text(
        text = text,
        modifier = modifier
            .background(
                color = if (onSelectedRow) colors.surface else colors.surfaceContainerHighest,
                shape = MaterialTheme.shapes.extraSmall,
            )
            .padding(horizontal = Dimens.tokenPaddingHorizontal, vertical = Dimens.tokenPaddingVertical),
        color = if (enabled) colors.onSurface else colors.onSurfaceVariant,
        style = SnippetsTheme.typography.monoToken,
        textDecoration = if (enabled) null else TextDecoration.LineThrough,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Preview(name = "Keyword token, light")
@Composable
private fun KeywordTokenPreviewLight() = PreviewSurface(darkTheme = false) { KeywordTokenPreviewContent() }

@Preview(name = "Keyword token, dark")
@Composable
private fun KeywordTokenPreviewDark() = PreviewSurface(darkTheme = true) { KeywordTokenPreviewContent() }

@Composable
private fun KeywordTokenPreviewContent() {
    Column(verticalArrangement = Arrangement.spacedBy(Spacing.s)) {
        KeywordToken("notes")
        KeywordToken("notes", enabled = false)
        KeywordToken("notes", onSelectedRow = true)
        KeywordToken("atlas-token", highlights = listOf(TextHighlight(0, 2), TextHighlight(6, 7)))
    }
}
