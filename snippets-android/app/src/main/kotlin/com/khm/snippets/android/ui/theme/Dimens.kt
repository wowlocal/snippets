package com.khm.snippets.android.ui.theme

import androidx.compose.ui.unit.dp

/** Spacing scale on a 4 dp grid (DESIGN.md §7). */
object Spacing {
    val xxs = 2.dp
    val xs = 4.dp
    val s = 8.dp
    val m = 12.dp
    val l = 16.dp
    val xl = 24.dp
    val xxl = 32.dp
    val xxxl = 48.dp
}

/** Measurements of components and layouts (DESIGN.md §4, §7, §8, §11; components.md). */
object Dimens {
    // Platform rules
    val touchTarget = 48.dp
    val borderThin = 1.dp
    val borderThick = 2.dp
    val focusOutline = 2.dp

    /** From this font scale on, single-line texts that say so may take a second line. */
    val largeFontScale = 1.3f

    // Icons
    val icon = 24.dp
    val iconSmall = 18.dp
    val iconStatus = 16.dp
    val iconSyncRow = 20.dp
    val iconEmptyState = 40.dp
    val iconPanel = 32.dp
    val iconPill = 12.dp
    val spinnerSmall = 16.dp
    val spinnerStep = 18.dp
    val spinnerEmptyState = 24.dp
    val spinnerStroke = 2.dp

    // Screen margins and widths
    val marginCompact = 16.dp
    val marginMedium = 24.dp
    val contentMaxWidthMedium = 640.dp
    val formMaxWidthExpanded = 720.dp
    val fullScreenDialogWidth = 560.dp
    val fullScreenDialogBarMinHeight = 64.dp
    val fullScreenDialogMaxHeightFraction = 0.9f
    val sheetMaxWidth = 640.dp
    val twoPaneMinWidth = 840.dp
    val twoPaneMinHeight = 480.dp
    val compactMaxWidth = 600.dp
    val listBottomPaddingWithFab = 88.dp
    val listBottomPadding = 16.dp

    // Library row
    val rowMinHeightTwoLines = 72.dp
    val rowMinHeightThreeLines = 96.dp
    val rowPaddingStart = 16.dp
    val rowPaddingEnd = 4.dp
    val rowPaddingVertical = 12.dp
    val rowLineGap = 2.dp
    val rowTagsGap = 6.dp
    val rowGlyphGap = 4.dp
    val rowGlyphLeading = 8.dp
    val rowTimeLeading = 8.dp
    val rowTokenGap = 8.dp
    val rowTokenMaxWidthFraction = 0.45f
    val rowPillGap = 6.dp
    val rowMaxPills = 3
    val rowSelectedInset = 8.dp
    val rowDividerInset = 16.dp
    val rowSwipeThresholdFraction = 0.4f
    val rowSwipeContentInset = 24.dp

    // Keyword token and tag pill
    val tokenPaddingHorizontal = 6.dp
    val tokenPaddingVertical = 1.dp
    val pillMinHeight = 20.dp
    val pillPaddingHorizontal = 8.dp
    val pillIconGap = 4.dp

    // Tag filter row and chips
    val filterRowMinHeight = 48.dp
    val chipGap = 8.dp
    val chipDot = 8.dp
    val tagFieldInputMinWidth = 96.dp
    val inputChipHeight = 32.dp

    // Search bar
    val searchBarMinHeight = 56.dp
    val searchBarTopGap = 8.dp
    val searchBarBottomGap = 4.dp

    // Section header, footer
    val headerPaddingTop = 16.dp
    val headerPaddingBottom = 8.dp
    val groupDividerSpace = 8.dp

    // Empty state
    val emptyStateMessageMaxWidth = 360.dp

    // Sync row and cards
    val syncRowMinHeight = 48.dp
    val cardPadding = 16.dp
    val cardMarginVertical = 8.dp
    val reviewCardMaxLines = 4

    // Secure body panel, secret block
    val securePanelMinHeight = 200.dp
    val securePanelHeaderMinHeight = 40.dp
    val securePanelBodyMinLines = 6
    val secretBlockPadding = 20.dp
    val fingerprintGroupSize = 8

    // Countdown row
    val countdownMinHeight = 56.dp
    val countdownBarHeight = 2.dp

    // Fields
    val fieldMinHeight = 56.dp
    val fieldCaptionGap = 4.dp
    val fieldSupportingInset = 16.dp
    val fieldGap = 16.dp
    val formSectionGap = 24.dp
    val bodyFieldMinHeight = 200.dp

    // Settings rows, progress steps
    val settingsRowMinHeight = 56.dp
    val settingsRowMinHeightTwoLines = 72.dp
    val stepRowMinHeight = 40.dp
    val stepIconSlot = 24.dp
    val stepGap = 12.dp

    // Dialogs, buttons, menus, snackbars
    val dialogParagraphGap = 12.dp
    val buttonSpinnerGap = 8.dp
    val snackbarMaxWidth = 400.dp
    val warningDot = 6.dp
    val menuMaxItems = 7
}
