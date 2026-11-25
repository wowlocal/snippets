package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FloatingActionButtonDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TooltipAnchorPosition
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.Dp
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens

/** Emphasis of an action button (components.md §18). */
enum class ButtonLevel {
    /** Filled: the one action that completes the screen. */
    Primary,

    /** Filled tonal: prominent, but does not complete the screen. */
    Secondary,

    /** Outlined: a refusal with the weight of the primary next to it. */
    Peer,

    /** Text: dialog buttons, inline actions, links inside cards. */
    Tertiary,
}

/**
 * The app's action button. Labels are `labelLarge` and wrap instead of truncating.
 *
 * While [working] it shows a 16 dp spinner in place of its icon and is disabled; pass the
 * in-progress label as [label] where the screen has one.
 *
 * @param destructive Error colours: an `error` container for [ButtonLevel.Primary], `error` text
 *   otherwise.
 */
@Composable
fun SnippetsButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    level: ButtonLevel = ButtonLevel.Primary,
    icon: SnippetsIcon? = null,
    enabled: Boolean = true,
    working: Boolean = false,
    destructive: Boolean = false,
) {
    val content: @Composable RowScope.() -> Unit = {
        if (working) {
            CircularProgressIndicator(
                modifier = Modifier.size(Dimens.spinnerSmall),
                color = LocalContentColor.current,
                strokeWidth = Dimens.spinnerStroke,
            )
            Spacer(Modifier.width(Dimens.buttonSpinnerGap))
        } else if (icon != null) {
            Glyph(icon, contentDescription = null, size = Dimens.iconSmall)
            Spacer(Modifier.width(Dimens.buttonSpinnerGap))
        }
        Text(text = label, textAlign = TextAlign.Center)
    }
    val isEnabled = enabled && !working
    when (level) {
        ButtonLevel.Primary -> Button(
            onClick = onClick,
            modifier = modifier,
            enabled = isEnabled,
            colors = if (destructive) destructiveFilledColors() else ButtonDefaults.buttonColors(),
            content = content,
        )
        ButtonLevel.Secondary -> FilledTonalButton(
            onClick = onClick,
            modifier = modifier,
            enabled = isEnabled,
            content = content,
        )
        ButtonLevel.Peer -> OutlinedButton(
            onClick = onClick,
            modifier = modifier,
            enabled = isEnabled,
            colors = if (destructive) {
                ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error)
            } else {
                ButtonDefaults.outlinedButtonColors()
            },
            content = content,
        )
        ButtonLevel.Tertiary -> TextButton(
            onClick = onClick,
            modifier = modifier,
            enabled = isEnabled,
            colors = if (destructive) {
                ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
            } else {
                ButtonDefaults.textButtonColors()
            },
            content = content,
        )
    }
}

@Composable
private fun destructiveFilledColors(): ButtonColors = ButtonDefaults.buttonColors(
    containerColor = MaterialTheme.colorScheme.error,
    contentColor = MaterialTheme.colorScheme.onError,
)

/**
 * An icon-only button: 48 dp target, content description equal to its tooltip, which shows on
 * long-press and hover.
 *
 * @param modifier Layout of the button in its parent.
 * @param tag Test tag of the button node.
 * @param tonal `FilledTonalIconButton`, for an "on" state.
 * @param stateDescription Spoken state, for example the number of active filters.
 * @param clickLabel What a screen reader says the double-tap does.
 * @param hiddenFromAccessibility Removes the button from the semantics tree (only its [tag]
 *   stays) where a parent node already offers the action.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SnippetsIconButton(
    icon: SnippetsIcon,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tag: String? = null,
    enabled: Boolean = true,
    tonal: Boolean = false,
    tint: Color = Color.Unspecified,
    iconSize: Dp = Dimens.icon,
    stateDescription: String? = null,
    clickLabel: String? = null,
    hiddenFromAccessibility: Boolean = false,
) {
    // A hidden button clears the whole anchor, so the tooltip's own semantics go with it.
    val anchorModifier = if (hiddenFromAccessibility) {
        modifier.clearAndSetSemantics { if (tag != null) testTag = tag }
    } else {
        modifier
    }
    val buttonModifier = if (hiddenFromAccessibility) {
        Modifier
    } else {
        Modifier
            .then(if (tag != null) Modifier.testTag(tag) else Modifier)
            .semantics {
                if (stateDescription != null) this.stateDescription = stateDescription
                if (clickLabel != null) onClick(label = clickLabel, action = null)
            }
    }
    TooltipBox(
        positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Above),
        tooltip = { PlainTooltip { Text(contentDescription) } },
        state = rememberTooltipState(),
        modifier = anchorModifier,
    ) {
        if (tonal) {
            FilledTonalIconButton(onClick = onClick, modifier = buttonModifier, enabled = enabled) {
                Glyph(icon, contentDescription = contentDescription, size = iconSize)
            }
        } else {
            val enabledTint = if (tint.isSpecified) tint else MaterialTheme.colorScheme.onSurfaceVariant
            IconButton(onClick = onClick, modifier = buttonModifier, enabled = enabled) {
                // Disabled: the button's own disabled content colour.
                Glyph(
                    icon = icon,
                    contentDescription = contentDescription,
                    tint = if (enabled) enabledTint else LocalContentColor.current,
                    size = iconSize,
                )
            }
        }
    }
}

/**
 * The library's `New Snippet` FAB: extended while the list is at the top, collapsed after
 * scrolling, and the small variant in windows lower than 480 dp.
 */
@Composable
fun NewSnippetFab(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    expanded: Boolean = true,
    small: Boolean = false,
) {
    val description = stringResource(R.string.library_fab_description)
    val tagged = modifier.testTag(TestTags.LIBRARY_FAB)
    val container = MaterialTheme.colorScheme.primaryContainer
    val content = MaterialTheme.colorScheme.onPrimaryContainer
    if (small) {
        SmallFloatingActionButton(
            onClick = onClick,
            modifier = tagged,
            containerColor = container,
            contentColor = content,
            elevation = FloatingActionButtonDefaults.elevation(),
        ) {
            Glyph(SnippetsIcon.Add, contentDescription = description)
        }
    } else {
        ExtendedFloatingActionButton(
            text = { Text(stringResource(R.string.library_fab_label)) },
            icon = { Glyph(SnippetsIcon.Add, contentDescription = description) },
            onClick = onClick,
            modifier = tagged,
            expanded = expanded,
            containerColor = container,
            contentColor = content,
        )
    }
}

@Preview(name = "Buttons, light")
@Composable
private fun ButtonsPreviewLight() = PreviewSurface(darkTheme = false) { ButtonsPreviewContent() }

@Preview(name = "Buttons, dark")
@Composable
private fun ButtonsPreviewDark() = PreviewSurface(darkTheme = true) { ButtonsPreviewContent() }

@Composable
private fun ButtonsPreviewContent() {
    Column(verticalArrangement = Arrangement.spacedBy(Dimens.chipGap)) {
        SnippetsButton("Connect", onClick = {})
        SnippetsButton("Working…", onClick = {}, working = true)
        SnippetsButton("Copy", onClick = {}, level = ButtonLevel.Secondary, icon = SnippetsIcon.ContentCopy)
        SnippetsButton("Deny", onClick = {}, level = ButtonLevel.Peer)
        SnippetsButton("Apply Deletions", onClick = {}, destructive = true)
        SnippetsButton("Delete", onClick = {}, level = ButtonLevel.Tertiary, destructive = true)
        SnippetsIconButton(SnippetsIcon.MoreVert, contentDescription = "More", onClick = {})
        NewSnippetFab(onClick = {})
    }
}
