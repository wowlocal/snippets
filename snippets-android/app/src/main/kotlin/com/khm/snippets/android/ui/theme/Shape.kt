package com.khm.snippets.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

/**
 * Shape scale (DESIGN.md §7): the M3 defaults, set explicitly. `full` is `CircleShape`.
 *
 * extraSmall: keyword token, search highlight. small: tag pill, chips. medium: field surfaces,
 * secure panel, secret block, selected row, cards. large: FAB. extraLarge: dialogs, sheets.
 */
val SnippetsShapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(8.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp),
    extraLarge = RoundedCornerShape(28.dp),
)
