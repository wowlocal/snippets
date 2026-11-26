package com.khm.snippets.android.feature.library

import androidx.compose.runtime.Stable
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.TagUi

/**
 * Every event the library screen reports. [LibraryViewModel] implements it; the screen takes it
 * as one stable parameter instead of a lambda per event, and a test or preview can pass its own.
 */
@Stable
interface LibraryActions {
    fun onQueryChange(text: String)
    fun onClearQuery()
    fun onToggleTag(tag: TagUi)
    fun onClearFilters()
    fun onOpenTagSheet()
    fun onDismissSheet()

    /**
     * Copies an entry: the row tap on a phone, the trailing button in two panes.
     *
     * @param swipeTipEligible Compact or medium width with touch exploration off: the one-time
     *   swipe tip may follow the first successful copy.
     */
    fun onCopy(id: String, swipeTipEligible: Boolean)
    fun onRowAction(id: String, action: SnippetRowAction)

    /** Two-pane: the row the detail pane shows, or null. Lets a deletion pick its neighbour. */
    fun onSelectionChanged(id: String?)
    fun onNewSnippet()
    fun onNewFromClipboard()
    fun onImport()
    fun onExport()
    fun onEncryptedBackup()
    fun onOpenSettings()
    fun onShowKeyboardShortcuts()
    fun onSyncMenuAction()
    fun onSyncRowClick()
    fun onSyncCardClick()
    fun onSyncCardAction()
    fun onRefresh()
    fun onSheetSyncNow()
    fun onSheetOpenSettings()
    fun onReviewConflicts()

    /** The button of an empty state, by position: 0 is the filled button or the only button. */
    fun onEmptyAction(index: Int)
    fun onClearClipboardNow()
    fun onDismissDialog()
    fun onConfirmDialog(dialog: AppDialog)
}
