package com.khm.snippets.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
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
import com.khm.snippets.android.ui.model.rowMenuActions
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlin.math.abs

/** Test tag of the swipe background, with `.edit` or `.pin` while that side is revealed. */
const val SWIPE_BACKGROUND_TAG = "library.row.swipe"

/**
 * The row's swipe container (components.md §1.4): right commits Edit, left commits Pin or Unpin,
 * and the row always returns. Delete is never reachable by a swipe.
 *
 * The action commits on release past 40 % of the row width. Crossing that point arms the action
 * (icon scales, haptic), moving back disarms it. Swipes are off while touch exploration is on;
 * pass `enabled = false` in two-pane layouts.
 *
 * @param pinned Chooses the left action's label, `Pin` or `Unpin`.
 */
@Composable
fun SnippetRowSwipeBox(
    pinned: Boolean,
    onEdit: () -> Unit,
    onTogglePin: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    val threshold = Dimens.rowSwipeThresholdFraction
    // Not saveable: a row that comes back never restores a half-finished swipe.
    val state = remember { SwipeToDismissBoxState(SwipeToDismissBoxValue.Settled) { it * threshold } }
    val scope = rememberCoroutineScope()
    val haptics = rememberSnippetsHaptics()
    val touchExploration = rememberTouchExplorationEnabled()
    val reducedMotion = SnippetsTheme.reducedMotion
    val currentOnEdit by rememberUpdatedState(onEdit)
    val currentOnTogglePin by rememberUpdatedState(onTogglePin)

    var widthPx by remember { mutableIntStateOf(0) }
    var returning by remember { mutableStateOf(false) }
    val armed by remember {
        derivedStateOf {
            val direction = state.dismissDirection
            if (widthPx == 0 || direction == SwipeToDismissBoxValue.Settled) {
                SwipeToDismissBoxValue.Settled
            } else if (abs(state.requireOffset()) >= widthPx * threshold) {
                direction
            } else {
                SwipeToDismissBoxValue.Settled
            }
        }
    }
    LaunchedEffect(state) {
        snapshotFlow { armed }.drop(1).collect { value ->
            if (returning) return@collect
            haptics.perform(
                if (value == SwipeToDismissBoxValue.Settled) SnippetsHaptic.SwipeDisarmed else SnippetsHaptic.SwipeArmed,
            )
        }
    }
    // Stable: SwipeToDismissBox calls it again whenever its identity changes while dismissed.
    val onDismiss = remember(state, scope) {
        val commit: (SwipeToDismissBoxValue) -> Unit = { direction ->
            when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> currentOnEdit()
                SwipeToDismissBoxValue.EndToStart -> currentOnTogglePin()
                SwipeToDismissBoxValue.Settled -> Unit
            }
            scope.launch {
                returning = true
                try {
                    state.reset()
                } finally {
                    returning = false
                }
            }
        }
        commit
    }
    SwipeToDismissBox(
        state = state,
        backgroundContent = {
            val isArmed = armed != SwipeToDismissBoxValue.Settled
            when (state.dismissDirection) {
                SwipeToDismissBoxValue.StartToEnd -> SwipeBackground(
                    icon = SnippetsIcon.Edit,
                    label = stringResource(R.string.action_edit),
                    container = MaterialTheme.colorScheme.primaryContainer,
                    content = MaterialTheme.colorScheme.onPrimaryContainer,
                    atStart = true,
                    armed = isArmed,
                    scaleWhenArmed = !reducedMotion,
                    tag = "$SWIPE_BACKGROUND_TAG.edit",
                )
                SwipeToDismissBoxValue.EndToStart -> SwipeBackground(
                    icon = SnippetsIcon.PushPin,
                    label = stringResource(if (pinned) R.string.action_unpin else R.string.action_pin),
                    container = MaterialTheme.colorScheme.secondaryContainer,
                    content = MaterialTheme.colorScheme.onSecondaryContainer,
                    atStart = false,
                    armed = isArmed,
                    scaleWhenArmed = !reducedMotion,
                    tag = "$SWIPE_BACKGROUND_TAG.pin",
                )
                SwipeToDismissBoxValue.Settled -> Unit
            }
        },
        modifier = modifier.onSizeChanged { widthPx = it.width },
        gesturesEnabled = enabled && !touchExploration,
        onDismiss = onDismiss,
    ) {
        content()
    }
}

@Composable
private fun SwipeBackground(
    icon: SnippetsIcon,
    label: String,
    container: Color,
    content: Color,
    atStart: Boolean,
    armed: Boolean,
    scaleWhenArmed: Boolean,
    tag: String,
) {
    val scale by animateFloatAsState(
        targetValue = if (armed && scaleWhenArmed) Motion.SWIPE_ARMED_SCALE else 1f,
        animationSpec = tween(Motion.SWIPE_ARM, easing = Motion.EasingStandard),
        label = "swipeIconScale",
    )
    Row(
        modifier = Modifier
            .fillMaxSize()
            .background(container)
            .padding(horizontal = Dimens.rowSwipeContentInset)
            .testTag(tag),
        horizontalArrangement = if (atStart) Arrangement.Start else Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Glyph(
            icon = icon,
            contentDescription = null,
            modifier = Modifier.graphicsLayer {
                scaleX = scale
                scaleY = scale
            },
            tint = content,
        )
        Spacer(Modifier.width(Spacing.s))
        Text(text = label, color = content, style = MaterialTheme.typography.labelLarge, maxLines = 1)
    }
}

/**
 * The row menu (screens-library-editor.md §4). Items that do not apply are absent; Delete is
 * last, in `error`. Place it inside the box it should anchor to.
 *
 * @param offset Position relative to the anchor box, as `DropdownMenu` defines it.
 */
@Composable
fun SnippetRowMenu(
    row: SnippetRowUi,
    layout: SnippetRowLayout,
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    onAction: (SnippetRowAction) -> Unit,
    modifier: Modifier = Modifier,
    offset: DpOffset = DpOffset.Zero,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        modifier = modifier,
        offset = offset,
    ) {
        rowMenuActions(layout, row.isSecure).forEach { action ->
            SnippetsMenuItem(
                label = rowActionLabel(action, row),
                icon = rowActionIcon(action, row),
                action = action.menuTag,
                onClick = {
                    onDismissRequest()
                    onAction(action)
                },
                destructive = action == SnippetRowAction.Delete,
            )
        }
    }
}

private fun rowActionIcon(action: SnippetRowAction, row: SnippetRowUi): SnippetsIcon = when (action) {
    SnippetRowAction.Copy -> if (row.isSecure) SnippetsIcon.Lock else SnippetsIcon.ContentCopy
    SnippetRowAction.Edit -> SnippetsIcon.Edit
    SnippetRowAction.TogglePin -> SnippetsIcon.PushPin
    SnippetRowAction.ToggleEnabled -> SnippetsIcon.PauseCircle
    SnippetRowAction.ToggleSecure -> if (row.isSecure) SnippetsIcon.LockOpen else SnippetsIcon.Lock
    SnippetRowAction.Duplicate -> SnippetsIcon.FileCopy
    SnippetRowAction.CopyShareLink -> SnippetsIcon.Link
    SnippetRowAction.Delete -> SnippetsIcon.Delete
}

/**
 * A library row with its swipe actions and its row menu: what a library list item is made of.
 *
 * Swipes are on in the single-pane layout only. A long-press, right-click, Menu key or
 * Shift+F10 opens the menu at the touch point (or at the row's start for the keyboard) with the
 * `LongPress` haptic; choosing an item reports it through [onAction].
 *
 * @param onClick The tap: copy in single-pane, select in two-pane, pick in the picker.
 */
@Composable
fun SnippetListItem(
    row: SnippetRowUi,
    onClick: () -> Unit,
    onAction: (SnippetRowAction) -> Unit,
    modifier: Modifier = Modifier,
    layout: SnippetRowLayout = SnippetRowLayout.SinglePane,
    selected: Boolean = false,
    copied: Boolean = false,
    showDivider: Boolean = true,
    announceCopied: Boolean = true,
) {
    val haptics = rememberSnippetsHaptics()
    var menuOpen by remember { mutableStateOf(false) }
    var menuAnchor by remember { mutableStateOf<DpOffset?>(null) }
    val hasMenu = layout != SnippetRowLayout.Picker
    Box(modifier = modifier) {
        SnippetRowSwipeBox(
            pinned = row.isPinned,
            onEdit = { onAction(SnippetRowAction.Edit) },
            onTogglePin = { onAction(SnippetRowAction.TogglePin) },
            enabled = layout == SnippetRowLayout.SinglePane,
        ) {
            SnippetRow(
                row = row,
                onClick = onClick,
                onAction = onAction,
                layout = layout,
                selected = selected,
                copied = copied,
                showDivider = showDivider,
                menuOpen = menuOpen,
                onMenuRequest = if (hasMenu) {
                    { touchPoint ->
                        // A touch long-press already produced its haptic in the row.
                        if (touchPoint == null) haptics.perform(SnippetsHaptic.RowMenuOpened)
                        menuAnchor = touchPoint
                        menuOpen = true
                    }
                } else {
                    null
                },
                announceCopied = announceCopied,
            )
        }
        if (hasMenu) {
            val anchor = menuAnchor
            // A zero-size box at the touch point, or at the row's bottom start for the keyboard.
            Box(
                modifier = if (anchor != null) {
                    Modifier.offset(x = anchor.x, y = anchor.y).size(0.dp)
                } else {
                    Modifier.align(Alignment.BottomStart).size(0.dp)
                },
            ) {
                SnippetRowMenu(
                    row = row,
                    layout = layout,
                    expanded = menuOpen,
                    onDismissRequest = { menuOpen = false },
                    onAction = onAction,
                )
            }
        }
    }
}

/**
 * Holds which row shows the `Copied` state. [show] starts (or restarts) the 1500 ms hold; a
 * second copy during the state restarts it.
 */
@Stable
class CopiedRowState internal constructor(private val scope: CoroutineScope) {
    var copiedId: String? by mutableStateOf(null)
        private set

    private var job: Job? = null

    fun show(id: String) {
        job?.cancel()
        copiedId = id
        job = scope.launch {
            delay(Motion.COPIED_HOLD.toLong())
            copiedId = null
        }
    }

    fun isCopied(id: String): Boolean = copiedId == id
}

@Composable
fun rememberCopiedRowState(): CopiedRowState {
    val scope = rememberCoroutineScope()
    return remember(scope) { CopiedRowState(scope) }
}

@Preview(name = "Snippet list item, light", widthDp = 375)
@Composable
private fun SnippetListItemPreviewLight() = PreviewSurface(darkTheme = false, padded = false) { SnippetListItemPreviewContent() }

@Preview(name = "Snippet list item, dark", widthDp = 375)
@Composable
private fun SnippetListItemPreviewDark() = PreviewSurface(darkTheme = true, padded = false) { SnippetListItemPreviewContent() }

@Composable
private fun SnippetListItemPreviewContent() {
    val row = SnippetRowUi(
        id = "1",
        name = "Meeting notes",
        time = "9:04 PM",
        preview = RowPreviewUi.Text("Meeting notes — {date:yyyy-MM-dd}"),
        keyword = "notes",
        tags = listOf(TagUi("work", "work"), TagUi("notes", "notes"), TagUi("links", "links"), TagUi("a", "a")),
    )
    Column {
        SnippetListItem(row = row, onClick = {}, onAction = {})
        SnippetRowMenu(row = row, layout = SnippetRowLayout.SinglePane, expanded = false, onDismissRequest = {}, onAction = {})
    }
}
