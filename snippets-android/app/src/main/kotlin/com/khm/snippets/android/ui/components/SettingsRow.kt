package com.khm.snippets.android.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing
import kotlinx.coroutines.delay

/** What a settings row is (components.md §12). Switch rows are [SettingsSwitchRow]. */
enum class SettingsRowKind {
    /** Opens a screen, sheet or dialog. */
    Navigation,

    /** Shows a live value or status; not clickable. */
    Value,

    /** Runs at once (`Sync Now`, `Lock Now`); headline in `primary`. */
    Action,

    /** A recovery action: `warning` headline and a leading warning icon. */
    Attention,

    /** Always opens a confirmation: `error` headline and icon. */
    Destructive,

    /** Unavailable: M3 disabled headline; the detail says why, at full opacity. */
    Disabled,

    /** Opens the browser: `primary` headline and a trailing `open_in_new`. */
    Link,
}

/**
 * A settings row (components.md §12): leading icon, headline, live supporting text. No chevrons.
 *
 * Test tags are `settings.row.<key>` with `.title` and `.detail`.
 *
 * @param detail The live state; it updates in place and wraps freely.
 * @param detailIsError Draws the detail in `error` with a leading error icon.
 * @param working An action row shows a 16 dp spinner and ignores taps while it runs.
 * @param highlighted Turning true flashes the container in `primaryContainer` (a settings
 *   search result): held 400 ms, faded over 300 ms.
 */
@Composable
fun SettingsRow(
    key: String,
    title: String,
    modifier: Modifier = Modifier,
    kind: SettingsRowKind = SettingsRowKind.Navigation,
    icon: SnippetsIcon? = null,
    detail: String? = null,
    detailIsError: Boolean = false,
    working: Boolean = false,
    highlighted: Boolean = false,
    onClick: () -> Unit = {},
) {
    val colors = MaterialTheme.colorScheme
    val warning = SnippetsTheme.colors.warning
    val tag = TestTags.settingsRow(key)
    val headlineColor = when (kind) {
        SettingsRowKind.Navigation, SettingsRowKind.Value -> colors.onSurface
        SettingsRowKind.Action, SettingsRowKind.Link -> colors.primary
        SettingsRowKind.Attention -> warning
        SettingsRowKind.Destructive -> colors.error
        SettingsRowKind.Disabled -> colors.onSurface.copy(alpha = DISABLED_CONTENT_ALPHA)
    }
    val iconTint = when (kind) {
        SettingsRowKind.Attention -> warning
        SettingsRowKind.Destructive -> colors.error
        SettingsRowKind.Disabled -> colors.onSurface.copy(alpha = DISABLED_CONTENT_ALPHA)
        else -> colors.onSurfaceVariant
    }
    val leadingIcon = if (kind == SettingsRowKind.Attention) SnippetsIcon.Warning else icon
    val clickable = kind != SettingsRowKind.Value && kind != SettingsRowKind.Disabled && !working

    val highlight = remember { Animatable(0f) }
    LaunchedEffect(highlighted) {
        if (highlighted) {
            highlight.snapTo(1f)
            delay(Motion.HIGHLIGHT_HOLD.toLong())
            highlight.animateTo(0f, tween(Motion.HIGHLIGHT_FADE, easing = Motion.EasingStandard))
        } else {
            highlight.snapTo(0f)
        }
    }
    val highlightColor = colors.primaryContainer

    ListItem(
        headlineContent = {
            Text(text = title, modifier = Modifier.testTag(tag + TestTags.Settings.TITLE), color = headlineColor)
        },
        modifier = modifier
            .background(highlightColor.copy(alpha = highlight.value))
            .then(if (clickable) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .testTag(tag),
        supportingContent = detail?.let {
            {
                Row(verticalAlignment = Alignment.Top) {
                    if (detailIsError) {
                        Glyph(SnippetsIcon.Error, contentDescription = null, tint = colors.error, size = Dimens.iconStatus)
                        Spacer(Modifier.width(Spacing.xs))
                    }
                    Text(
                        text = it,
                        modifier = Modifier.testTag(tag + TestTags.Settings.DETAIL),
                        color = if (detailIsError) colors.error else colors.onSurfaceVariant,
                    )
                }
            }
        },
        leadingContent = leadingIcon?.let { { Glyph(it, contentDescription = null, tint = iconTint) } },
        trailingContent = when {
            working -> {
                { CircularProgressIndicator(modifier = Modifier.size(Dimens.spinnerSmall), strokeWidth = Dimens.spinnerStroke) }
            }
            kind == SettingsRowKind.Link -> {
                { Glyph(SnippetsIcon.OpenInNew, contentDescription = null, tint = colors.primary, size = Dimens.iconSmall) }
            }
            else -> null
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

/**
 * A settings row with a switch; the whole row toggles. Test tags are `settings.row.<key>` with
 * `.title`, `.detail` and `.switch`.
 */
@Composable
fun SettingsSwitchRow(
    key: String,
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    icon: SnippetsIcon? = null,
    detail: String? = null,
    enabled: Boolean = true,
) {
    SwitchRow(
        title = title,
        checked = checked,
        onCheckedChange = onCheckedChange,
        modifier = modifier,
        tag = TestTags.settingsRow(key),
        supportingText = detail,
        enabled = enabled,
        icon = icon,
    )
}

@Preview(name = "Settings rows, light", widthDp = 375)
@Composable
private fun SettingsRowPreviewLight() = PreviewSurface(darkTheme = false, padded = false) { SettingsRowPreviewContent() }

@Preview(name = "Settings rows, dark", widthDp = 375)
@Composable
private fun SettingsRowPreviewDark() = PreviewSurface(darkTheme = true, padded = false) { SettingsRowPreviewContent() }

@Composable
private fun SettingsRowPreviewContent() {
    Column {
        SettingsRow(key = "sync", title = "Sync", icon = SnippetsIcon.Sync, detail = "On. Last synced at 9:04 PM.")
        SettingsRow(key = "lock-now", title = "Lock Now", kind = SettingsRowKind.Action, working = true)
        SettingsRow(key = "repair", title = "Repair Sync", kind = SettingsRowKind.Attention, detail = "Rebuilds the sync state on this device.")
        SettingsRow(key = "remove-vault", title = "Remove Secure Snippets from This Device", kind = SettingsRowKind.Destructive, icon = SnippetsIcon.Delete)
        SettingsRow(key = "provider", title = "Sync Provider", kind = SettingsRowKind.Disabled, detail = "Turn off Sync This Library first.")
        SettingsRow(key = "github", title = "Snippets on GitHub", kind = SettingsRowKind.Link, icon = SnippetsIcon.Info)
        SettingsSwitchRow(key = "sync-library", title = "Sync This Library", checked = true, onCheckedChange = {})
    }
}
