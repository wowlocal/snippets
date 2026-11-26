package com.khm.snippets.android.nav

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.unit.Dp
import com.khm.snippets.android.ui.theme.Dimens

/** Width classes of DESIGN.md §4. */
enum class WidthClass { Compact, Medium, Expanded, Large }

/**
 * How the window is laid out (DESIGN.md §4).
 *
 * @param isTwoPane Width at least 840 dp and height at least 480 dp: list and detail side by
 *   side, a row tap selects. Medium widths stay single-pane with phone behaviour.
 * @param isShort Height below 480 dp: single pane whatever the width, small FAB.
 */
@Immutable
data class WindowLayout(val widthClass: WidthClass, val isTwoPane: Boolean, val isShort: Boolean) {
    /** Screen margin: 16 dp compact, 24 dp at medium widths and inside panes. */
    val horizontalMargin: Dp get() = if (widthClass == WidthClass.Compact) Dimens.marginCompact else Dimens.marginMedium

    /** Width of the library's list pane: 360 dp, 400 dp from 1200 dp on. */
    val listPaneWidth: Dp get() = if (widthClass == WidthClass.Large) Dimens.listPaneWidthWide else Dimens.listPaneWidth

    /** Width of the Settings list pane: 320 dp, 360 dp from 1200 dp on. */
    val settingsPaneWidth: Dp get() = if (widthClass == WidthClass.Large) Dimens.listPaneWidth else Dimens.settingsPaneWidth
}

/** The layout of a window of [width] × [height]. */
fun windowLayoutOf(width: Dp, height: Dp): WindowLayout {
    val widthClass = when {
        width < Dimens.compactMaxWidth -> WidthClass.Compact
        width < Dimens.twoPaneMinWidth -> WidthClass.Medium
        width < Dimens.largeMinWidth -> WidthClass.Expanded
        else -> WidthClass.Large
    }
    val isShort = height < Dimens.twoPaneMinHeight
    return WindowLayout(
        widthClass = widthClass,
        isTwoPane = !isShort && (widthClass == WidthClass.Expanded || widthClass == WidthClass.Large),
        isShort = isShort,
    )
}

/** The layout of the window the composition is in. Provided once, by the app shell. */
val LocalWindowLayout = staticCompositionLocalOf { windowLayoutOf(Dimens.defaultWindowWidth, Dimens.defaultWindowHeight) }

/** Which pane of a two-pane scene the composition is in; null in a single-pane scene. */
val LocalPaneRole = staticCompositionLocalOf<PaneRole?> { null }
