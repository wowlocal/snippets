package com.khm.snippets.android.feature.library

import androidx.compose.runtime.Immutable
import com.khm.snippets.android.data.SyncRecoveryAction
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.feature.shared.LibrarySyncUi
import com.khm.snippets.android.feature.shared.SnackbarRequest
import com.khm.snippets.android.feature.shared.SyncMenuAction
import com.khm.snippets.android.feature.shared.UiText
import com.khm.snippets.android.nav.Route
import com.khm.snippets.android.nav.SettingsDestination
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.model.SnippetRowUi
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.TagFilterUi

/** The one button of the "first fetch stalled" empty state. */
@Immutable
sealed interface StalledAction {
    @Immutable
    data class Recovery(val action: SyncRecoveryAction) : StalledAction

    @Immutable
    data object OpenSyncSettings : StalledAction

    @Immutable
    data object TryAgain : StalledAction
}

/** Why the list is empty (screens-library-editor.md §2.4). */
@Immutable
sealed interface LibraryEmptyUi {
    /** First run: the library is empty and sync is off. Only the search bar shows above it. */
    @Immutable
    data class FirstRun(val syncAction: SyncMenuAction) : LibraryEmptyUi

    @Immutable
    data class SyncedEmpty(val sentence: UiText) : LibraryEmptyUi

    /** @param started False before the first round starts. */
    @Immutable
    data class FirstFetchRunning(val provider: UiText, val started: Boolean) : LibraryEmptyUi

    @Immutable
    data class FirstFetchStalled(val sentence: UiText, val action: StalledAction) : LibraryEmptyUi

    @Immutable
    data class Quarantined(val sentence: UiText) : LibraryEmptyUi

    @Immutable
    data class NoResults(val hasFilters: Boolean) : LibraryEmptyUi

    @Immutable
    data object NoFilterMatch : LibraryEmptyUi
}

/** What fills the list area. */
@Immutable
sealed interface LibraryContent {
    /** The store is not ready. Nothing is drawn for 300 ms, then a spinner. */
    @Immutable
    data class Loading(val showSpinner: Boolean) : LibraryContent

    @Immutable
    data object Rows : LibraryContent

    @Immutable
    data class Empty(val reason: LibraryEmptyUi) : LibraryContent
}

/** The sheet that is open over the library. */
enum class LibrarySheet { Tags, Sync }

/** Content of the sync status sheet (screens-library-editor.md §5). */
@Immutable
data class SyncSheetUi(
    val provider: UiText,
    val glyph: SyncGlyph,
    val sentence: UiText,
    val canSyncNow: Boolean,
    val isSyncing: Boolean,
    val conflictCount: Int,
)

/**
 * Everything the library screen draws, except the search text, which is snapshot state on the
 * ViewModel so typing never waits for a flow.
 *
 * @param pinned Pinned matches, in display order; [others] the rest.
 * @param filterChips The chip row: selected chips first in selection order, then alphabetical.
 * @param sheetTags The filter sheet's rows: every tag, alphabetical.
 * @param copiedId The row that shows `Copied`, for 1500 ms.
 */
@Immutable
data class LibraryUiState(
    val content: LibraryContent = LibraryContent.Loading(showSpinner = false),
    val pinned: List<SnippetRowUi> = emptyList(),
    val others: List<SnippetRowUi> = emptyList(),
    val totalCount: Int = 0,
    val isFiltering: Boolean = false,
    val filterChips: List<TagFilterUi> = emptyList(),
    val sheetTags: List<TagFilterUi> = emptyList(),
    val activeFilterCount: Int = 0,
    val sync: LibrarySyncUi = LibrarySyncUi.Hidden,
    val syncMenu: SyncMenuAction = SyncMenuAction.SetUp,
    val syncSheet: SyncSheetUi? = null,
    val isSyncActionRunning: Boolean = false,
    val isRefreshing: Boolean = false,
    val copiedId: String? = null,
    val sheet: LibrarySheet? = null,
    val dialog: AppDialog? = null,
) {
    val visibleCount: Int get() = pinned.size + others.size

    /** The tag row shows when the library has a tag or a filter is active; never on first run. */
    val showFilterRow: Boolean
        get() = filterChips.isNotEmpty() && !isFirstRun

    val isFirstRun: Boolean
        get() = (content as? LibraryContent.Empty)?.reason is LibraryEmptyUi.FirstRun

    /** The FAB is hidden on first run, while quarantined and while loading. */
    val showFab: Boolean
        get() = when (content) {
            is LibraryContent.Loading -> false
            LibraryContent.Rows -> true
            is LibraryContent.Empty -> content.reason !is LibraryEmptyUi.FirstRun && content.reason !is LibraryEmptyUi.Quarantined
        }
}

/** One-shot effects of the library (docs/app-architecture.md, "State and effects"). */
sealed interface LibraryEffect {
    data class OpenEditor(val id: String, val focusBody: Boolean = false) : LibraryEffect

    /** Two-pane: the selected entry was deleted here; select [id], or nothing when null. */
    data class SelectAfterRemoval(val id: String?) : LibraryEffect
    data class Navigate(val route: Route) : LibraryEffect
    data class OpenSettings(val pane: SettingsDestination?) : LibraryEffect

    data class ShowSnackbar(val request: SnackbarRequest) : LibraryEffect
    data class Haptic(val haptic: SnippetsHaptic) : LibraryEffect
    data class Announce(val message: UiText) : LibraryEffect
    data object OpenSecuritySettings : LibraryEffect
    data object ShowKeyboardShortcuts : LibraryEffect
}
