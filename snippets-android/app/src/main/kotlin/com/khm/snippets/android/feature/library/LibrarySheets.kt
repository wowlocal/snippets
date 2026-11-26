package com.khm.snippets.android.feature.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.khm.snippets.android.R
import com.khm.snippets.android.feature.shared.resolve
import com.khm.snippets.android.ui.components.ButtonLevel
import com.khm.snippets.android.ui.components.SnippetsButton
import com.khm.snippets.android.ui.components.SyncStatusGlyph
import com.khm.snippets.android.ui.components.TagFilterSheetContent
import com.khm.snippets.android.ui.icons.Glyph
import com.khm.snippets.android.ui.icons.SnippetsIcon
import com.khm.snippets.android.ui.theme.Dimens
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.Spacing
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText

/** The sheet open over the library, if any: the tag filter sheet or the sync status sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LibrarySheets(state: LibraryUiState, actions: LibraryActions) {
    when (state.sheet) {
        LibrarySheet.Tags -> ModalBottomSheet(
            onDismissRequest = actions::onDismissSheet,
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
            sheetMaxWidth = Dimens.sheetMaxWidth,
        ) {
            TagSheet(state, actions)
        }
        LibrarySheet.Sync -> {
            val sheet = state.syncSheet ?: return
            ModalBottomSheet(
                onDismissRequest = actions::onDismissSheet,
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                sheetMaxWidth = Dimens.sheetMaxWidth,
            ) {
                SyncSheet(sheet, actions)
            }
        }
        null -> Unit
    }
}

/** LIB-FILTER (components.md §3.3): rows apply at once; `Search tags` above 12 tags. */
@Composable
private fun TagSheet(state: LibraryUiState, actions: LibraryActions) {
    var query by rememberSaveable { mutableStateOf("") }
    val shown = remember(state.sheetTags, query) {
        val needle = SnippetTagging.filterKey(FoundationText.trimWhitespaceAndNewlines(query))
        if (needle.isEmpty()) state.sheetTags else state.sheetTags.filter { needle in it.tag.folded }
    }
    TagFilterSheetContent(
        tags = shown,
        libraryTagCount = state.sheetTags.size,
        activeFilterCount = state.activeFilterCount,
        query = query,
        onQueryChange = { query = it },
        onToggleTag = actions::onToggleTag,
        onClear = actions::onClearFilters,
        modifier = Modifier.navigationBarsPadding(),
    )
}

/** The sync status sheet (screens-library-editor.md §5). */
@Composable
private fun SyncSheet(sheet: SyncSheetUi, actions: LibraryActions) {
    val colors = MaterialTheme.colorScheme
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(bottom = Spacing.l)
            .testTag(LibraryTags.SYNC_SHEET),
    ) {
        Text(
            text = stringResource(R.string.sync_sheet_title),
            modifier = Modifier
                .padding(horizontal = Dimens.marginCompact)
                .testTag(LibraryTags.SYNC_SHEET_TITLE)
                .semantics { heading() },
            style = MaterialTheme.typography.titleLarge,
        )
        Row(
            modifier = Modifier.padding(horizontal = Dimens.marginCompact, vertical = Spacing.m),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Glyph(SnippetsIcon.Commit, contentDescription = null, tint = colors.onSurfaceVariant)
            Spacer(Modifier.width(Spacing.m))
            Text(
                text = sheet.provider.resolve(),
                modifier = Modifier.testTag(LibraryTags.SYNC_SHEET_PROVIDER),
                style = MaterialTheme.typography.bodyLarge,
            )
        }
        Row(
            modifier = Modifier.padding(horizontal = Dimens.marginCompact),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SyncStatusGlyph(sheet.glyph, size = Dimens.icon)
            Spacer(Modifier.width(Spacing.m))
            Text(
                text = sheet.sentence.resolve(),
                modifier = Modifier
                    .testTag(LibraryTags.SYNC_SHEET_STATUS)
                    .semantics { liveRegion = LiveRegionMode.Polite },
                style = MaterialTheme.typography.bodyMedium,
                color = colors.onSurfaceVariant,
            )
        }
        HorizontalDivider(
            modifier = Modifier.padding(vertical = Spacing.l),
            thickness = Dimens.borderThin,
            color = colors.outlineVariant,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Dimens.marginCompact),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SnippetsButton(
                label = stringResource(if (sheet.isSyncing) R.string.sync_sheet_syncing else R.string.sync_action_sync_now),
                onClick = actions::onSheetSyncNow,
                modifier = Modifier.testTag(LibraryTags.SYNC_SHEET_SYNC_NOW),
                level = ButtonLevel.Secondary,
                icon = SnippetsIcon.Sync,
                enabled = sheet.canSyncNow,
                working = sheet.isSyncing,
            )
            SnippetsButton(
                label = stringResource(R.string.sync_sheet_settings),
                onClick = actions::onSheetOpenSettings,
                modifier = Modifier.testTag(LibraryTags.SYNC_SHEET_SETTINGS),
                level = ButtonLevel.Tertiary,
            )
        }
        if (sheet.conflictCount > 0) {
            ListItem(
                headlineContent = {
                    Text(pluralStringResource(R.plurals.sync_sheet_conflicts, sheet.conflictCount, sheet.conflictCount))
                },
                modifier = Modifier
                    .padding(top = Spacing.s)
                    .clickable(role = Role.Button, onClick = actions::onReviewConflicts)
                    .testTag(LibraryTags.SYNC_SHEET_CONFLICTS),
                leadingContent = { Glyph(SnippetsIcon.Warning, contentDescription = null, tint = SnippetsTheme.colors.warning) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
    }
}
