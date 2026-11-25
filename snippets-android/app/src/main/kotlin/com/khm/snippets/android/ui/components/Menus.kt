package com.khm.snippets.android.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.tooling.preview.Preview
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon

/**
 * One `DropdownMenu` item (components.md §18): a 24 dp leading icon and a `bodyLarge` label.
 * Unavailable items are omitted, not disabled. A menu holds at most seven items; destructive
 * ones come last.
 *
 * @param action Becomes the test tag `menu.item.<action>`.
 * @param destructive Icon and text in `error`.
 */
@Composable
fun SnippetsMenuItem(
    label: String,
    icon: SnippetsIcon,
    action: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    destructive: Boolean = false,
) {
    val colors = MaterialTheme.colorScheme
    DropdownMenuItem(
        text = { Text(text = label, style = MaterialTheme.typography.bodyLarge) },
        onClick = onClick,
        modifier = modifier.testTag(TestTags.menuItem(action)),
        leadingIcon = { Glyph(icon, contentDescription = null) },
        colors = if (destructive) {
            MenuDefaults.itemColors(textColor = colors.error, leadingIconColor = colors.error)
        } else {
            MenuDefaults.itemColors(textColor = colors.onSurface, leadingIconColor = colors.onSurfaceVariant)
        },
    )
}

/** Separates groups of menu items. */
@Composable
fun SnippetsMenuDivider(modifier: Modifier = Modifier) {
    HorizontalDivider(modifier = modifier, color = MaterialTheme.colorScheme.outlineVariant)
}

@Preview(name = "Menu items, light")
@Composable
private fun MenuItemsPreviewLight() = PreviewSurface(darkTheme = false) { MenuItemsPreviewContent() }

@Preview(name = "Menu items, dark")
@Composable
private fun MenuItemsPreviewDark() = PreviewSurface(darkTheme = true) { MenuItemsPreviewContent() }

@Composable
private fun MenuItemsPreviewContent() {
    Column {
        SnippetsMenuItem("Pin", SnippetsIcon.PushPin, action = "pin", onClick = {})
        SnippetsMenuItem("Duplicate", SnippetsIcon.FileCopy, action = "duplicate", onClick = {})
        SnippetsMenuDivider()
        SnippetsMenuItem("Delete", SnippetsIcon.Delete, action = "delete", onClick = {}, destructive = true)
    }
}
