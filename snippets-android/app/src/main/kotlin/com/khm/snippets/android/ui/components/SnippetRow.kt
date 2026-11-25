package com.khm.snippets.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.model.RowPreviewUi
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.SnippetRowLayout
import com.khm.snippets.android.ui.model.SnippetRowUi
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.TextHighlight
import com.khm.snippets.android.ui.model.highlightedString
import com.khm.snippets.android.ui.model.rowCustomActions
import com.khm.snippets.android.ui.model.shiftHighlights
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import kotlin.math.max

/** M3 state-layer opacity for a pressed row; a row keeps it while its menu is open. */
private const val PRESSED_STATE_LAYER_ALPHA = 0.10f

/**
 * One library row (components.md §1): name, status glyphs and time; keyword token and preview;
 * tag pills. One component for the phone, two-pane and Insert Snippet layouts.
 *
 * The row is a single accessibility node. Its custom actions (Copy, Edit, Pin / Unpin,
 * Duplicate, Delete) and its trailing button report through [onAction]; a tap reports through
 * [onClick], because what a tap means depends on the layout.
 *
 * Wrap it in [SnippetRowSwipeBox] for the swipe actions, or use [SnippetListItem], which adds
 * the swipes and the row menu.
 *
 * @param copied Shows the `Copied` state on line 2 and flashes the container. The caller holds
 *   it for 1500 ms (see [CopiedRowState]).
 * @param showDivider Draws the inset divider under the row; pass false for the last row of a
 *   section. A selected row never draws one.
 * @param menuOpen Keeps the pressed state while the row menu is open.
 * @param onMenuRequest A long-press, right-click, Menu key or Shift+F10 asked for the row menu.
 *   The offset is the touch point relative to the row, or null for a keyboard request (anchor at
 *   the row's start). Null disables the menu gestures.
 * @param clickLabel Replaces the default click label (`copy`, `authenticate and copy`, `open`).
 * @param announceCopied Speaks `Copied “name”.` when [copied] turns true. Pass false where the
 *   countdown row already announces a secure copy.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SnippetRow(
    row: SnippetRowUi,
    onClick: () -> Unit,
    onAction: (SnippetRowAction) -> Unit,
    modifier: Modifier = Modifier,
    layout: SnippetRowLayout = SnippetRowLayout.SinglePane,
    selected: Boolean = false,
    copied: Boolean = false,
    showDivider: Boolean = true,
    menuOpen: Boolean = false,
    onMenuRequest: ((touchPoint: DpOffset?) -> Unit)? = null,
    clickLabel: String? = null,
    announceCopied: Boolean = true,
) {
    val colors = MaterialTheme.colorScheme
    val reducedMotion = SnippetsTheme.reducedMotion
    val rowTag = TestTags.row(row.id)
    val displayName = row.name.ifBlank { stringResource(R.string.library_row_untitled) }
    val isSelected = selected && layout == SnippetRowLayout.TwoPane
    val density = LocalDensity.current

    val flash by animateFloatAsState(
        targetValue = if (copied && !reducedMotion) 1f else 0f,
        animationSpec = tween(
            durationMillis = if (copied) Motion.COPIED_IN else Motion.COPIED_OUT,
            easing = Motion.EasingStandard,
        ),
        label = "copiedFlash",
    )
    val container = if (isSelected) colors.secondaryContainer else lerp(colors.surface, colors.secondaryContainer, flash)

    if (announceCopied) {
        val announcer = rememberAnnouncer()
        val announcement = stringResource(
            if (row.isSecure) R.string.library_row_copied_secure_announcement else R.string.library_row_copied_announcement,
            displayName,
        )
        LaunchedEffect(copied) {
            if (copied) announcer.announce(announcement)
        }
    }

    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val pressedOverlay = colors.onSurface.copy(alpha = PRESSED_STATE_LAYER_ALPHA)
    val shape = if (isSelected) MaterialTheme.shapes.medium else RectangleShape
    val focusShape = MaterialTheme.shapes.medium

    val currentOnAction by rememberUpdatedState(onAction)
    val currentOnMenuRequest by rememberUpdatedState(onMenuRequest)
    val lastPress = remember { PressPosition() }

    val resolvedClickLabel = clickLabel ?: stringResource(
        when {
            layout == SnippetRowLayout.TwoPane -> R.string.library_row_click_open
            row.isSecure -> R.string.library_row_click_authenticate
            else -> R.string.library_row_click_copy
        },
    )
    val stateText = rowStateDescription(row)
    val accessibilityActions = rowAccessibilityActions(row, onAction)

    val inset = if (isSelected) Dimens.rowSelectedInset else 0.dp
    val hasTrailing = layout != SnippetRowLayout.Picker
    val trailingWidth = if (hasTrailing) Dimens.touchTarget + Dimens.rowPaddingEnd else Dimens.rowPaddingStart

    Column(modifier = modifier.fillMaxWidth().background(colors.surface)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = inset)
                .clip(shape)
                .background(container)
                .drawWithContent {
                    drawContent()
                    if (menuOpen) drawRect(pressedOverlay)
                }
                .then(if (focused) Modifier.border(Dimens.focusOutline, colors.primary, focusShape) else Modifier)
                .onPreviewKeyEvent { event ->
                    val opensMenu = event.key == Key.Menu || (event.key == Key.F10 && event.isShiftPressed)
                    val copies = layout == SnippetRowLayout.TwoPane &&
                        (event.key == Key.Enter || event.key == Key.NumPadEnter)
                    when {
                        opensMenu && currentOnMenuRequest != null -> {
                            if (event.type == KeyEventType.KeyUp) currentOnMenuRequest?.invoke(null)
                            true
                        }
                        copies -> {
                            if (event.type == KeyEventType.KeyUp) currentOnAction(SnippetRowAction.Copy)
                            true
                        }
                        else -> false
                    }
                }
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        if (event.type != PointerEventType.Press) return@awaitEachGesture
                        val position = event.changes.firstOrNull()?.position ?: return@awaitEachGesture
                        lastPress.value = position
                        val request = currentOnMenuRequest
                        if (event.buttons.isSecondaryPressed && request != null) {
                            event.changes.forEach { it.consume() }
                            request(DpOffset(position.x.toDp(), position.y.toDp()))
                        }
                    }
                }
                .combinedClickable(
                    interactionSource = interactionSource,
                    indication = ripple(),
                    role = Role.Button,
                    onClickLabel = resolvedClickLabel,
                    onLongClick = if (onMenuRequest != null) {
                        {
                            val position = lastPress.value
                            with(density) {
                                currentOnMenuRequest?.invoke(DpOffset(position.x.toDp(), position.y.toDp()))
                            }
                        }
                    } else {
                        null
                    },
                    onClick = onClick,
                )
                .semantics {
                    contentDescription = displayName
                    stateDescription = stateText
                    customActions = accessibilityActions
                }
                .testTag(rowTag),
        ) {
            Row(
                modifier = Modifier.heightIn(
                    min = if (row.tags.isEmpty()) Dimens.rowMinHeightTwoLines else Dimens.rowMinHeightThreeLines,
                ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(
                            start = Dimens.rowPaddingStart - inset,
                            top = Dimens.rowPaddingVertical,
                            bottom = Dimens.rowPaddingVertical,
                            end = if (hasTrailing) 0.dp else Dimens.rowPaddingStart - inset,
                        ),
                ) {
                    RowFirstLine(row = row, displayName = displayName, rowTag = rowTag)
                    Box(modifier = Modifier.padding(top = Dimens.rowLineGap)) {
                        val restAlpha by animateFloatAsState(
                            targetValue = if (copied) 0f else 1f,
                            animationSpec = tween(if (copied) Motion.COPIED_IN else Motion.COPIED_OUT),
                            label = "secondLineAlpha",
                        )
                        RowSecondLine(
                            row = row,
                            rowTag = rowTag,
                            onSelectedRow = isSelected,
                            // The line is 16 dp start padding plus the trailing area narrower than the row.
                            rowExtraWidth = Dimens.rowPaddingStart + trailingWidth + inset,
                            modifier = Modifier.graphicsLayer { alpha = restAlpha },
                        )
                        androidx.compose.animation.AnimatedVisibility(
                            visible = copied,
                            enter = fadeIn(tween(Motion.COPIED_IN)),
                            exit = fadeOut(tween(Motion.COPIED_OUT)),
                        ) {
                            CopiedLine(modifier = Modifier.testTag(rowTag + TestTags.Row.COPIED))
                        }
                    }
                    if (row.tags.isNotEmpty()) {
                        RowTagLine(
                            tags = row.tags,
                            modifier = Modifier
                                .padding(top = Dimens.rowTagsGap)
                                .clearAndSetSemantics { testTag = rowTag + TestTags.Row.TAGS },
                        )
                    }
                }
                when (layout) {
                    SnippetRowLayout.SinglePane -> SnippetsIconButton(
                        icon = SnippetsIcon.Edit,
                        contentDescription = stringResource(R.string.action_edit),
                        onClick = { onAction(SnippetRowAction.Edit) },
                        modifier = Modifier.padding(end = Dimens.rowPaddingEnd - inset.coerceAtMost(Dimens.rowPaddingEnd)),
                        tag = rowTag + TestTags.Row.EDIT,
                        hiddenFromAccessibility = true,
                    )
                    SnippetRowLayout.TwoPane -> SnippetsIconButton(
                        icon = SnippetsIcon.ContentCopy,
                        contentDescription = stringResource(R.string.action_copy),
                        onClick = { onAction(SnippetRowAction.Copy) },
                        modifier = Modifier.padding(end = Dimens.rowPaddingEnd - inset.coerceAtMost(Dimens.rowPaddingEnd)),
                        tag = rowTag + TestTags.Row.COPY,
                        hiddenFromAccessibility = true,
                    )
                    SnippetRowLayout.Picker -> Unit
                }
            }
        }
        if (showDivider && !isSelected) {
            HorizontalDivider(
                modifier = Modifier.padding(start = Dimens.rowDividerInset),
                thickness = Dimens.borderThin,
                color = colors.outlineVariant,
            )
        }
    }
}

/** Mutable holder for the last pointer-down position; written outside composition. */
private class PressPosition {
    var value: Offset = Offset.Zero
}

@Composable
private fun rowStateDescription(row: SnippetRowUi): String {
    val parts = ArrayList<String>(5)
    parts += stringResource(if (row.isSecure) R.string.library_row_state_secure else R.string.library_row_state_standard)
    if (row.isPinned) parts += stringResource(R.string.library_row_state_pinned)
    parts += stringResource(if (row.isEnabled) R.string.library_row_state_enabled else R.string.library_row_state_disabled)
    val keyword = row.keyword
    if (!keyword.isNullOrBlank()) parts += stringResource(R.string.library_row_state_keyword, keyword)
    if (row.tags.isNotEmpty()) {
        parts += stringResource(R.string.library_row_state_tags, row.tags.joinToString(", ") { it.name })
    }
    return parts.joinToString(", ")
}

@Composable
private fun rowAccessibilityActions(
    row: SnippetRowUi,
    onAction: (SnippetRowAction) -> Unit,
): List<CustomAccessibilityAction> {
    val currentOnAction by rememberUpdatedState(onAction)
    val labels = rowCustomActions(row.isSecure).map { action -> action to rowActionLabel(action, row) }
    return remember(labels) {
        labels.map { (action, label) ->
            CustomAccessibilityAction(label) {
                currentOnAction(action)
                true
            }
        }
    }
}

/** The label of [action] for [row]: menu item title and accessibility action name. */
@Composable
internal fun rowActionLabel(action: SnippetRowAction, row: SnippetRowUi): String = stringResource(
    when (action) {
        SnippetRowAction.Copy -> R.string.action_copy
        SnippetRowAction.Edit -> R.string.action_edit
        SnippetRowAction.TogglePin -> if (row.isPinned) R.string.action_unpin else R.string.action_pin
        SnippetRowAction.ToggleEnabled -> if (row.isEnabled) R.string.action_disable else R.string.action_enable
        SnippetRowAction.ToggleSecure -> if (row.isSecure) R.string.action_make_ordinary else R.string.action_make_secure
        SnippetRowAction.Duplicate -> R.string.action_duplicate
        SnippetRowAction.CopyShareLink -> R.string.action_copy_share_link
        SnippetRowAction.Delete -> R.string.action_delete
    },
)

@Composable
private fun RowFirstLine(
    row: SnippetRowUi,
    displayName: String,
    rowTag: String,
) {
    val colors = MaterialTheme.colorScheme
    val highlightBackground = colors.tertiaryContainer
    val highlightForeground = colors.onTertiaryContainer
    val name = remember(displayName, row.name, row.nameHighlights, highlightBackground, highlightForeground) {
        // Highlights index the real name; the placeholder name has none.
        val ranges = if (row.name.isBlank()) emptyList() else row.nameHighlights
        highlightedString(displayName, ranges, highlightBackground, highlightForeground)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = name,
            modifier = Modifier
                .weight(1f)
                .testTag(rowTag + TestTags.Row.NAME),
            color = if (row.isEnabled) colors.onSurface else colors.onSurfaceVariant,
            style = MaterialTheme.typography.titleMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (row.isSecure || row.isPinned || !row.isEnabled) {
            Spacer(Modifier.width(Dimens.rowGlyphLeading - Dimens.rowGlyphGap))
            if (row.isSecure) {
                Glyph(
                    icon = SnippetsIcon.Lock,
                    contentDescription = null,
                    modifier = Modifier
                        .padding(start = Dimens.rowGlyphGap)
                        .testTag(rowTag + TestTags.Row.GLYPH_SECURE),
                    tint = SnippetsTheme.colors.secure,
                    size = Dimens.iconStatus,
                )
            }
            if (row.isPinned) {
                Glyph(
                    icon = SnippetsIcon.PushPinFilled,
                    contentDescription = null,
                    modifier = Modifier
                        .padding(start = Dimens.rowGlyphGap)
                        .testTag(rowTag + TestTags.Row.GLYPH_PINNED),
                    tint = colors.primary,
                    size = Dimens.iconStatus,
                )
            }
            if (!row.isEnabled) {
                Glyph(
                    icon = SnippetsIcon.PauseCircle,
                    contentDescription = null,
                    modifier = Modifier
                        .padding(start = Dimens.rowGlyphGap)
                        .testTag(rowTag + TestTags.Row.GLYPH_DISABLED),
                    tint = colors.onSurfaceVariant,
                    size = Dimens.iconStatus,
                )
            }
        }
        Text(
            text = row.time,
            modifier = Modifier
                .padding(start = Dimens.rowTimeLeading)
                .testTag(rowTag + TestTags.Row.TIME),
            color = colors.onSurfaceVariant,
            style = MaterialTheme.typography.labelMedium,
            maxLines = 1,
            softWrap = false,
        )
    }
}

/** The preview text of line 2 and its highlight ranges, after the fixed texts are applied. */
internal data class RowPreviewText(val text: String, val highlights: List<TextHighlight>)

/** The fixed texts line 2 is built from; resolved from resources by the row. */
internal data class RowPreviewStrings(
    val noContent: String,
    val secure: String,
    val disabled: String,
    /** Formats `Disabled · %s`. */
    val disabledWith: (String) -> String,
    /** Formats `…%s`. */
    val excerpt: (String) -> String,
)

/**
 * Line 2's preview text (components.md §1.2), or null when nothing follows the token. Highlight
 * ranges are moved behind any prefix; secure entries never highlight.
 */
internal fun rowPreviewText(
    preview: RowPreviewUi,
    isEnabled: Boolean,
    strings: RowPreviewStrings,
): RowPreviewText? {
    val base: RowPreviewText? = when (preview) {
        RowPreviewUi.None -> null
        RowPreviewUi.NoContent -> RowPreviewText(strings.noContent, emptyList())
        RowPreviewUi.Secure -> RowPreviewText(strings.secure, emptyList())
        is RowPreviewUi.Text -> if (preview.isExcerpt) {
            prefixed(strings.excerpt, preview.text, preview.highlights)
        } else {
            RowPreviewText(preview.text, preview.highlights)
        }
    }
    if (isEnabled) return base
    if (base == null) return RowPreviewText(strings.disabled, emptyList())
    return prefixed(strings.disabledWith, base.text, base.highlights)
}

private fun prefixed(
    format: (String) -> String,
    text: String,
    highlights: List<TextHighlight>,
): RowPreviewText {
    val formatted = format(text)
    // The argument sits at the end of both formats; anything else loses the highlights.
    val offset = formatted.length - text.length
    val shifted = if (offset >= 0 && formatted.endsWith(text)) shiftHighlights(highlights, offset) else emptyList()
    return RowPreviewText(formatted, shifted)
}

@Composable
private fun RowSecondLine(
    row: SnippetRowUi,
    rowTag: String,
    onSelectedRow: Boolean,
    rowExtraWidth: Dp,
    modifier: Modifier = Modifier,
) {
    val colors = MaterialTheme.colorScheme
    val strings = RowPreviewStrings(
        noContent = stringResource(R.string.library_row_no_content),
        secure = stringResource(R.string.library_row_secure_preview),
        disabled = stringResource(R.string.library_row_disabled),
        disabledWith = stringResource(R.string.library_row_disabled_preview, FORMAT_ARGUMENT).let { template ->
            { argument: String -> template.replace(FORMAT_ARGUMENT, argument) }
        },
        excerpt = stringResource(R.string.library_row_excerpt, FORMAT_ARGUMENT).let { template ->
            { argument: String -> template.replace(FORMAT_ARGUMENT, argument) }
        },
    )
    val highlightBackground = colors.tertiaryContainer
    val highlightForeground = colors.onTertiaryContainer
    val preview: AnnotatedString? = remember(row.preview, row.isEnabled, strings.noContent, strings.secure, strings.disabled, highlightBackground, highlightForeground) {
        rowPreviewText(row.preview, row.isEnabled, strings)?.let {
            highlightedString(it.text, it.highlights, highlightBackground, highlightForeground)
        }
    }
    val keyword = row.keyword?.takeIf { it.isNotBlank() }
    val previewMaxLines = if (LocalDensity.current.fontScale >= Dimens.largeFontScale) 2 else 1
    Layout(
        contents = listOf(
            {
                if (keyword != null) {
                    KeywordToken(
                        keyword = keyword,
                        modifier = Modifier.testTag(rowTag + TestTags.Row.KEYWORD),
                        enabled = row.isEnabled,
                        onSelectedRow = onSelectedRow,
                        highlights = row.keywordHighlights,
                    )
                }
            },
            {
                if (preview != null) {
                    Text(
                        text = preview,
                        modifier = Modifier.testTag(rowTag + TestTags.Row.PREVIEW),
                        color = colors.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = previewMaxLines,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            },
        ),
        modifier = modifier,
    ) { (tokenMeasurables, previewMeasurables), constraints ->
        val gap = Dimens.rowTokenGap.roundToPx()
        val rowWidth = if (constraints.hasBoundedWidth) constraints.maxWidth + rowExtraWidth.roundToPx() else Constraints.Infinity
        val tokenMaxWidth = if (rowWidth == Constraints.Infinity) {
            Constraints.Infinity
        } else {
            (rowWidth * Dimens.rowTokenMaxWidthFraction).toInt().coerceAtMost(constraints.maxWidth)
        }
        val token = tokenMeasurables.firstOrNull()?.measure(Constraints(maxWidth = tokenMaxWidth))
        val previewLeft = if (token != null) token.width + gap else 0
        val previewMaxWidth = if (constraints.hasBoundedWidth) {
            (constraints.maxWidth - previewLeft).coerceAtLeast(0)
        } else {
            Constraints.Infinity
        }
        val previewPlaceable = previewMeasurables.firstOrNull()?.measure(Constraints(maxWidth = previewMaxWidth))

        val tokenBaseline = token?.get(FirstBaseline) ?: 0
        val previewBaseline = previewPlaceable?.get(FirstBaseline) ?: 0
        val baseline = max(tokenBaseline, previewBaseline)
        val tokenY = if (token != null) baseline - tokenBaseline else 0
        val previewY = if (previewPlaceable != null) baseline - previewBaseline else 0
        val height = max(
            tokenY + (token?.height ?: 0),
            previewY + (previewPlaceable?.height ?: 0),
        )
        val width = if (constraints.hasBoundedWidth) {
            constraints.maxWidth
        } else {
            previewLeft + (previewPlaceable?.width ?: 0)
        }
        layout(width, height.coerceIn(constraints.minHeight, constraints.maxHeight)) {
            token?.placeRelative(0, tokenY)
            previewPlaceable?.placeRelative(previewLeft, previewY)
        }
    }
}

/** Stands in for the argument while a format string is split around it. */
private const val FORMAT_ARGUMENT = "\u0000"

@Composable
private fun CopiedLine(modifier: Modifier = Modifier) {
    val primary = MaterialTheme.colorScheme.primary
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        Glyph(SnippetsIcon.Check, contentDescription = null, tint = primary, size = Dimens.iconStatus)
        Spacer(Modifier.width(Dimens.rowGlyphGap))
        Text(
            text = stringResource(R.string.library_row_copied),
            color = primary,
            style = MaterialTheme.typography.labelLarge,
            maxLines = 1,
        )
    }
}

/**
 * How many of the first pills fit on one line together with the `+N` label for the rest.
 * At least one pill is always shown (it is then cut with an ellipsis).
 *
 * @param pillWidths Widths of the candidate pills, in order (at most three).
 * @param totalTags Number of tags on the entry.
 * @param overflowWidth Width of the `+N` label for N hidden tags.
 */
internal fun fittingPillCount(
    pillWidths: List<Int>,
    totalTags: Int,
    gap: Int,
    maxWidth: Int,
    overflowWidth: (hidden: Int) -> Int,
): Int {
    if (pillWidths.isEmpty()) return 0
    for (count in pillWidths.size downTo 1) {
        val hidden = totalTags - count
        var width = pillWidths.take(count).sum() + gap * (count - 1)
        if (hidden > 0) width += gap + overflowWidth(hidden)
        if (width <= maxWidth) return count
    }
    return 1
}

@Composable
private fun RowTagLine(
    tags: List<TagUi>,
    modifier: Modifier = Modifier,
) {
    val candidates = tags.take(Dimens.rowMaxPills)
    SubcomposeLayout(modifier = modifier) { constraints ->
        val gap = Dimens.rowPillGap.roundToPx()
        val maxWidth = constraints.maxWidth
        val loose = Constraints(maxWidth = maxWidth)
        val pills = subcompose(TagLineSlot.Pills) {
            candidates.forEach { TagPill(it) }
        }.map { it.measure(loose) }

        val overflowLabels = HashMap<Int, Placeable>()
        fun overflowLabel(hidden: Int): Placeable = overflowLabels.getOrPut(hidden) {
            subcompose(TagLineSlot.Overflow(hidden)) { MoreTagsLabel(hidden) }.first().measure(loose)
        }

        val count = fittingPillCount(
            pillWidths = pills.map { it.width },
            totalTags = tags.size,
            gap = gap,
            maxWidth = maxWidth,
            overflowWidth = { overflowLabel(it).width },
        )
        val hidden = tags.size - count
        val overflow = if (hidden > 0) overflowLabel(hidden) else null
        val overflowSpace = if (overflow != null) overflow.width + gap else 0

        var shown = pills.take(count)
        if (count == 1 && shown.first().width + overflowSpace > maxWidth) {
            // A single pill wider than the line: measure it again inside what is left.
            val available = (maxWidth - overflowSpace).coerceAtLeast(0)
            shown = subcompose(TagLineSlot.Constrained) { TagPill(candidates.first()) }
                .map { it.measure(Constraints(maxWidth = available)) }
        }
        val height = max(shown.maxOfOrNull { it.height } ?: 0, overflow?.height ?: 0)
        layout(maxWidth, height) {
            var x = 0
            shown.forEach { pill ->
                pill.placeRelative(x, (height - pill.height) / 2)
                x += pill.width + gap
            }
            overflow?.placeRelative(x, (height - overflow.height) / 2)
        }
    }
}

private sealed interface TagLineSlot {
    data object Pills : TagLineSlot
    data object Constrained : TagLineSlot
    data class Overflow(val hidden: Int) : TagLineSlot
}

@Composable
private fun MoreTagsLabel(hidden: Int) {
    Text(
        text = stringResource(R.string.library_row_more_tags, hidden),
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.labelSmall,
        maxLines = 1,
        softWrap = false,
    )
}

private val PreviewRows = listOf(
    SnippetRowUi(
        id = "1",
        name = "Meeting room",
        time = "9:02 PM",
        preview = RowPreviewUi.Text("https://meet.example.com/design-review"),
        keyword = "meet",
        tags = listOf(TagUi("work", "work"), TagUi("links", "links")),
        isPinned = true,
    ),
    SnippetRowUi(
        id = "2",
        name = "Atlas API token",
        time = "Yesterday",
        preview = RowPreviewUi.Secure,
        keyword = "atlas-token",
        tags = listOf(TagUi("work", "work"), TagUi("tokens", "tokens")),
        isSecure = true,
    ),
    SnippetRowUi(
        id = "3",
        name = "Quick reply",
        time = "Mon",
        preview = RowPreviewUi.Text("Thanks for reaching out. I will take a look."),
        keyword = "reply",
        isEnabled = false,
    ),
)

@Preview(name = "Snippet row, light", widthDp = 375)
@Composable
private fun SnippetRowPreviewLight() = PreviewSurface(darkTheme = false, padded = false) { SnippetRowPreviewContent() }

@Preview(name = "Snippet row, dark", widthDp = 375)
@Composable
private fun SnippetRowPreviewDark() = PreviewSurface(darkTheme = true, padded = false) { SnippetRowPreviewContent() }

@Composable
private fun SnippetRowPreviewContent() {
    Column {
        PreviewRows.forEach { SnippetRow(row = it, onClick = {}, onAction = {}) }
        SnippetRow(row = PreviewRows[0], onClick = {}, onAction = {}, copied = true)
        SnippetRow(
            row = PreviewRows[1],
            onClick = {},
            onAction = {},
            layout = SnippetRowLayout.TwoPane,
            selected = true,
        )
    }
}
