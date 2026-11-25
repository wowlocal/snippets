package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.ComposeContentTestRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.khm.snippets.android.ui.model.RowPreviewUi
import com.khm.snippets.android.ui.model.SnippetRowUi
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.theme.SnippetsTheme
import org.junit.Assert.assertTrue

/** Sets [content] inside the Snippets theme, optionally at another font scale. */
internal fun ComposeContentTestRule.setThemedContent(
    fontScale: Float = 1f,
    darkTheme: Boolean = false,
    content: @Composable () -> Unit,
) {
    setContent {
        SnippetsTheme(darkTheme = darkTheme) {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                Surface(color = MaterialTheme.colorScheme.surface) {
                    Box(modifier = Modifier.fillMaxWidth()) {
                        content()
                    }
                }
            }
        }
    }
}

internal fun tag(name: String) = TagUi(name = name, folded = name.lowercase())

internal fun sampleRow(
    id: String = "row",
    name: String = "Meeting notes",
    isSecure: Boolean = false,
    isPinned: Boolean = false,
    isEnabled: Boolean = true,
    tags: List<TagUi> = listOf(tag("work"), tag("notes")),
) = SnippetRowUi(
    id = id,
    name = name,
    time = "9:04 PM",
    preview = if (isSecure) RowPreviewUi.Secure else RowPreviewUi.Text("Meeting notes — {date:yyyy-MM-dd}"),
    keyword = "notes",
    tags = tags,
    isSecure = isSecure,
    isPinned = isPinned,
    isEnabled = isEnabled,
)

/** Nodes a user can activate: click or toggle, but not text fields (they are checked by height). */
internal val isActivatable: SemanticsMatcher = SemanticsMatcher("is clickable and not a text field") { node ->
    node.config.contains(SemanticsActions.OnClick) && !node.config.contains(SemanticsActions.SetText)
}

/** Asserts that the touch area of [node] is at least 48 × 48 dp. */
internal fun ComposeContentTestRule.assertTouchTarget(node: SemanticsNode, what: String) {
    val minimum = with(density) { 48.dp.toPx() } - 0.5f
    val bounds = node.touchBoundsInRoot
    assertTrue(
        "$what: touch target is ${bounds.width} × ${bounds.height} px, needs $minimum px",
        bounds.width >= minimum && bounds.height >= minimum,
    )
}

/** Describes a node for failure messages. */
internal fun SemanticsNode.describe(): String {
    val tag = config.getOrNull(SemanticsProperties.TestTag)
    val description = config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString()
    val text = config.getOrNull(SemanticsProperties.Text)?.joinToString { it.text }
    return listOfNotNull(tag, description, text).joinToString(" / ").ifEmpty { "node #$id" }
}

/** The text layouts of [node], when it is a text. */
internal fun SemanticsNode.textLayouts(): List<TextLayoutResult> {
    val results = ArrayList<TextLayoutResult>()
    config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(results)
    return results
}

/**
 * True when every line of the text lies inside the box it was laid out in.
 * `TextLayoutResult.hasVisualOverflow` cannot be used for this: it compares the box with the
 * width the paragraph was offered, not with the width the lines take.
 */
internal fun TextLayoutResult.fitsItsBox(): Boolean {
    if (lineCount == 0) return true
    val left = (0 until lineCount).minOf { getLineLeft(it) }
    val right = (0 until lineCount).maxOf { getLineRight(it) }
    val bottom = getLineBottom(lineCount - 1)
    return left >= -1f && right - left <= size.width + 1f && bottom <= size.height + 1f
}

/** True when no line was cut with an ellipsis and the text fits its box. */
internal fun TextLayoutResult.isFullyShown(): Boolean =
    fitsItsBox() && !multiParagraph.didExceedMaxLines && (0 until lineCount).none { isLineEllipsized(it) }

/** The measurements behind [fitsItsBox] and [isFullyShown], for failure messages. */
internal fun TextLayoutResult.measurements(): String =
    "lines ${(0 until lineCount).map { getLineLeft(it) to getLineRight(it) }} in a box of ${size.width} × ${size.height} px, " +
        "$lineCount line(s), exceededMaxLines=${multiParagraph.didExceedMaxLines}, " +
        "ellipsised=${(0 until lineCount).any { isLineEllipsized(it) }}"
