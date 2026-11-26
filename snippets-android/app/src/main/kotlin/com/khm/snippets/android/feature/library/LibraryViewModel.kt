package com.khm.snippets.android.feature.library

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.khm.snippets.android.R
import com.khm.snippets.android.app.AppContainer
import com.khm.snippets.android.data.AppSettings
import com.khm.snippets.android.data.LibraryAvailability
import com.khm.snippets.android.data.LibraryEntry
import com.khm.snippets.android.data.LibraryError
import com.khm.snippets.android.data.LibraryQuery
import com.khm.snippets.android.data.LibraryQueryEngine
import com.khm.snippets.android.data.LibraryQueryResult
import com.khm.snippets.android.data.LibraryRepository
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.android.data.NewSnippet
import com.khm.snippets.android.data.Outcome
import com.khm.snippets.android.data.SyncController
import com.khm.snippets.android.data.SyncProvider
import com.khm.snippets.android.data.SyncRecoveryAction
import com.khm.snippets.android.data.SyncState
import com.khm.snippets.android.data.SyncStatus
import com.khm.snippets.android.data.UndoToken
import com.khm.snippets.android.data.VaultError
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.feature.shared.ConversionResult
import com.khm.snippets.android.feature.shared.CopyResult
import com.khm.snippets.android.feature.shared.EffectChannel
import com.khm.snippets.android.feature.shared.ErrorRecovery
import com.khm.snippets.android.feature.shared.Feedback
import com.khm.snippets.android.feature.shared.LibrarySyncUi
import com.khm.snippets.android.feature.shared.SnackbarRequest
import com.khm.snippets.android.feature.shared.SnippetOperations
import com.khm.snippets.android.feature.shared.SyncCardAction
import com.khm.snippets.android.feature.shared.SyncMenuAction
import com.khm.snippets.android.feature.shared.SyncOptIn
import com.khm.snippets.android.feature.shared.SyncPresentation
import com.khm.snippets.android.feature.shared.UiText
import com.khm.snippets.android.feature.shared.errorDialog
import com.khm.snippets.android.feature.shared.libraryErrorText
import com.khm.snippets.android.feature.shared.toUuidOrNull
import com.khm.snippets.android.feature.shared.uiText
import com.khm.snippets.android.feature.shared.vaultFailureFeedback
import com.khm.snippets.android.nav.BackupNewPasswordRoute
import com.khm.snippets.android.nav.ExportRoute
import com.khm.snippets.android.nav.ImportRoute
import com.khm.snippets.android.nav.SettingsSyncGitRoute
import com.khm.snippets.android.nav.SettingsSyncRoute
import com.khm.snippets.android.nav.SyncReviewRoute
import com.khm.snippets.android.platform.ClipboardService
import com.khm.snippets.android.platform.TimeFormatter
import com.khm.snippets.android.ui.components.SnackbarKind
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.model.SnippetRowAction
import com.khm.snippets.android.ui.model.SnippetRowUi
import com.khm.snippets.android.ui.model.SyncGlyph
import com.khm.snippets.android.ui.model.TagFilterUi
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.theme.CONFLICT_TAG_FOLDED
import com.khm.snippets.android.ui.theme.Motion
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * The library screen's state and events (screens-library-editor.md §1 to §5).
 *
 * The search text and the tag filters live in [SavedStateHandle]: they survive rotation and
 * process death and are gone on a cold start. Searching and row mapping run off the main thread
 * and a newer query cancels an older one.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class LibraryViewModel(
    private val savedState: SavedStateHandle,
    private val library: LibraryRepository,
    private val queryEngine: LibraryQueryEngine,
    private val sync: SyncController,
    private val settings: AppSettings,
    private val operations: SnippetOperations,
    private val clipboard: ClipboardService,
    private val time: TimeFormatter,
    private val defaultDispatcher: CoroutineDispatcher,
) : ViewModel(), LibraryActions {
    private class Listing(val snapshot: LibrarySnapshot, val result: LibraryQueryResult, val rows: List<SnippetRowUi>)

    private val mapper = LibraryRowMapper(time)
    private val state = MutableStateFlow(LibraryUiState())
    private val effectChannel = EffectChannel<LibraryEffect>()
    private val queryText = MutableStateFlow(savedState.get<String>(KEY_QUERY).orEmpty())
    private val filterKeys = MutableStateFlow(savedState.get<ArrayList<String>>(KEY_FILTERS)?.toList().orEmpty())
    private var listing: Listing? = null
    private var selectedId: String? = null
    private var copiedJob: Job? = null
    private var spinnerJob: Job? = null

    val uiState: StateFlow<LibraryUiState> = state.asStateFlow()

    /** The secure-copy countdown row; application-scoped, shared with the editor. */
    val countdown: StateFlow<CountdownUi?> = clipboard.countdown
    val effects: Flow<LibraryEffect> = effectChannel.flow

    /** The search field's text. Snapshot state, so the field never lags behind the keyboard. */
    var query: String by mutableStateOf(queryText.value)
        private set

    init {
        viewModelScope.launch {
            combine(library.snapshot, queryText, filterKeys) { snapshot, text, keys -> Triple(snapshot, text, keys) }
                .mapLatest { (snapshot, text, keys) ->
                    val result = queryEngine.search(snapshot, LibraryQuery(text, keys))
                    val rows = withContext(defaultDispatcher) { result.rows.map(mapper::row) }
                    Listing(snapshot, result, rows)
                }
                .collect(::onListing)
        }
        viewModelScope.launch { sync.status.collect { publish() } }
    }

    // region Search and filters

    override fun onQueryChange(text: String) {
        query = text
        queryText.value = text
        savedState[KEY_QUERY] = text
    }

    override fun onClearQuery() = onQueryChange("")

    override fun onToggleTag(tag: TagUi) {
        val keys = filterKeys.value
        val wasActive = tag.folded in keys
        setFilters(if (wasActive) keys - tag.folded else keys + tag.folded)
        effectChannel.send(LibraryEffect.Haptic(SnippetsHaptic.TagFilterToggled))
    }

    override fun onClearFilters() {
        if (filterKeys.value.isEmpty()) return
        setFilters(emptyList())
        effectChannel.send(LibraryEffect.Announce(uiText(R.string.tags_cleared_announcement)))
    }

    override fun onOpenTagSheet() = state.update { it.copy(sheet = LibrarySheet.Tags) }

    override fun onDismissSheet() = state.update { it.copy(sheet = null) }

    private fun setFilters(keys: List<String>) {
        filterKeys.value = keys
        savedState[KEY_FILTERS] = ArrayList(keys)
    }

    // endregion

    // region Rows

    override fun onCopy(id: String, swipeTipEligible: Boolean) {
        val uuid = id.toUuidOrNull() ?: return
        viewModelScope.launch {
            when (val result = operations.copy(uuid)) {
                is CopyResult.Copied -> {
                    showCopied(id)
                    effectChannel.send(LibraryEffect.Haptic(SnippetsHaptic.CopySucceeded))
                    if (!result.wasSecure && !clipboard.showsSystemCopyConfirmation) {
                        effectChannel.send(snackbar(uiText(R.string.snackbar_copied, result.name)))
                    }
                    if (swipeTipEligible) showSwipeTipOnce()
                }
                is CopyResult.NothingToCopy -> {
                    effectChannel.send(snackbar(uiText(R.string.snackbar_nothing_to_copy, result.name)))
                    effectChannel.send(LibraryEffect.Haptic(SnippetsHaptic.Rejected))
                }
                CopyResult.Cancelled -> Unit
                CopyResult.Missing -> showDialog(errorDialog(R.string.error_title_copy, uiText(R.string.error_snippet_missing)))
                is CopyResult.Failed -> showVaultFailure(R.string.error_title_copy, result.error)
            }
        }
    }

    override fun onRowAction(id: String, action: SnippetRowAction) {
        when (action) {
            SnippetRowAction.Copy -> onCopy(id, swipeTipEligible = false)
            SnippetRowAction.Edit -> effectChannel.send(LibraryEffect.OpenEditor(id))
            SnippetRowAction.TogglePin -> togglePin(id)
            SnippetRowAction.ToggleEnabled -> toggleEnabled(id)
            SnippetRowAction.ToggleSecure -> toggleSecure(id)
            SnippetRowAction.Duplicate -> duplicate(id)
            SnippetRowAction.CopyShareLink -> copyShareLink(id)
            SnippetRowAction.Delete -> delete(id)
        }
    }

    override fun onSelectionChanged(id: String?) {
        selectedId = id
    }

    private fun togglePin(id: String) = withEntry(id) { uuid, entry ->
        val pinned = !entry.snippet.isPinned
        when (val result = library.setPinned(uuid, pinned)) {
            is Outcome.Success -> effectChannel.send(
                LibraryEffect.Haptic(if (pinned) SnippetsHaptic.ToggledOn else SnippetsHaptic.ToggledOff),
            )
            is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_pin, libraryErrorText(result.error)))
        }
    }

    private fun toggleEnabled(id: String) = withEntry(id) { uuid, entry ->
        val enabled = !entry.snippet.isEnabled
        when (val result = library.setEnabled(uuid, enabled)) {
            is Outcome.Success -> effectChannel.send(
                LibraryEffect.Haptic(if (enabled) SnippetsHaptic.ToggledOn else SnippetsHaptic.ToggledOff),
            )
            is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_update, libraryErrorText(result.error)))
        }
    }

    private fun toggleSecure(id: String) = withEntry(id) { uuid, entry ->
        if (entry.isSecure) {
            val plainText = (sync.status.value.provider as? SyncProvider.Git)?.isPlainText == true && sync.status.value.isEnabled
            showDialog(AppDialog.MakeOrdinary(id, plainText))
        } else {
            showConversion(operations.makeSecure(uuid), madeSecure = true)
        }
    }

    private fun duplicate(id: String) = withEntry(id) { uuid, _ ->
        when (val result = library.duplicate(uuid)) {
            is Outcome.Success -> effectChannel.send(LibraryEffect.OpenEditor(result.value.toString()))
            is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_update, libraryErrorText(result.error)))
        }
    }

    private fun copyShareLink(id: String) = withEntry(id) { uuid, _ ->
        when (val result = operations.copyShareLink(uuid)) {
            is Outcome.Success -> if (!clipboard.showsSystemCopyConfirmation) {
                effectChannel.send(snackbar(uiText(R.string.snackbar_copied_share_link)))
            }
            is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_copy_link, libraryErrorText(result.error)))
        }
    }

    private fun delete(id: String) = withEntry(id) { uuid, entry ->
        if (entry.isSecure) {
            showDialog(AppDialog.DeleteSecure(id, entry.displayName))
        } else {
            performDelete(uuid)
        }
    }

    private suspend fun performDelete(uuid: UUID) {
        when (val result = operations.delete(uuid)) {
            is Outcome.Success -> {
                val deletion = result.value
                effectChannel.send(LibraryEffect.Haptic(SnippetsHaptic.Deleted))
                effectChannel.send(
                    if (deletion.wasSecure) {
                        snackbar(uiText(R.string.snackbar_secure_deleted))
                    } else {
                        snackbar(uiText(R.string.snackbar_deleted, deletion.name), undo = deletion.undo)
                    },
                )
            }
            is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_delete, libraryErrorText(result.error)))
        }
    }

    // endregion

    // region Creating

    override fun onNewSnippet() = create(NewSnippet())

    /** Reads the clipboard now: this is the explicit user action that permits it. */
    override fun onNewFromClipboard() {
        val text = clipboard.readText()
        if (text.isNullOrBlank()) {
            showDialog(AppDialog.ClipboardEmpty)
        } else {
            create(NewSnippet(content = text))
        }
    }

    private fun create(draft: NewSnippet) {
        viewModelScope.launch {
            when (val result = library.create(draft)) {
                is Outcome.Success -> effectChannel.send(LibraryEffect.OpenEditor(result.value.toString(), focusBody = true))
                is Outcome.Failure -> showDialog(
                    if (result.error == LibraryError.RecoveryRequired) {
                        errorDialog(R.string.error_title_recovery_required, uiText(R.string.error_library_recovery_required))
                    } else {
                        errorDialog(R.string.error_title_update, libraryErrorText(result.error))
                    },
                )
            }
        }
    }

    // endregion

    // region More menu, sync row, pull to refresh

    override fun onImport() = effectChannel.send(LibraryEffect.Navigate(ImportRoute))

    override fun onExport() = effectChannel.send(LibraryEffect.Navigate(ExportRoute))

    override fun onEncryptedBackup() = effectChannel.send(LibraryEffect.Navigate(BackupNewPasswordRoute))

    override fun onOpenSettings() = effectChannel.send(LibraryEffect.OpenSettings(null))

    override fun onShowKeyboardShortcuts() = effectChannel.send(LibraryEffect.ShowKeyboardShortcuts)

    /** The More menu's sync item. */
    override fun onSyncMenuAction() {
        when (val action = state.value.syncMenu) {
            is SyncMenuAction.Recovery -> runRecovery(action.action)
            SyncMenuAction.OpenSyncSettings, SyncMenuAction.SetUp -> openSyncSettings()
            SyncMenuAction.SyncNow -> {
                effectChannel.send(snackbar(uiText(R.string.snackbar_syncing)))
                viewModelScope.launch { sync.syncNow() }
            }
            is SyncMenuAction.TurnOn -> showStartSync()
        }
    }

    override fun onSyncRowClick() = state.update { it.copy(sheet = LibrarySheet.Sync) }

    /** A tap on the Review card's body. */
    override fun onSyncCardClick() {
        val card = state.value.sync as? LibrarySyncUi.Card ?: return
        if (card.isHalt) effectChannel.send(LibraryEffect.Navigate(SyncReviewRoute)) else openSyncSettings()
    }

    /** The Review card's button. */
    override fun onSyncCardAction() {
        when (val action = (state.value.sync as? LibrarySyncUi.Card)?.action) {
            is SyncCardAction.Recovery -> runRecovery(action.action)
            SyncCardAction.OpenSyncSettings -> openSyncSettings()
            null -> Unit
        }
    }

    /** Pull to refresh (screens-library-editor.md §2.8). */
    override fun onRefresh() {
        val status = sync.status.value
        val recovery = status.recoveryAction
        when {
            recovery != null -> runRecovery(recovery)
            status.isEnabled -> viewModelScope.launch {
                state.update { it.copy(isRefreshing = true) }
                try {
                    sync.syncNow()
                } finally {
                    state.update { it.copy(isRefreshing = false) }
                }
            }
            else -> showDialog(AppDialog.SyncOptInPrompt(optInVariant(status)))
        }
    }

    override fun onSheetSyncNow() {
        viewModelScope.launch { sync.syncNow() }
    }

    override fun onSheetOpenSettings() {
        onDismissSheet()
        openSyncSettings()
    }

    /** `Review Conflict Copies`: closes the sheet, clears the query, filters by `conflict`. */
    override fun onReviewConflicts() {
        onDismissSheet()
        onClearQuery()
        setFilters(listOf(CONFLICT_TAG_FOLDED))
    }

    override fun onEmptyAction(index: Int) {
        when (val reason = (state.value.content as? LibraryContent.Empty)?.reason) {
            is LibraryEmptyUi.FirstRun -> when (index) {
                0 -> onNewSnippet()
                1 -> onImport()
                else -> if (reason.syncAction is SyncMenuAction.TurnOn) showStartSync() else openSyncSettings()
            }
            is LibraryEmptyUi.FirstFetchStalled -> when (val action = reason.action) {
                is StalledAction.Recovery -> runRecovery(action.action)
                StalledAction.OpenSyncSettings -> openSyncSettings()
                StalledAction.TryAgain -> viewModelScope.launch { sync.syncNow() }
            }
            is LibraryEmptyUi.Quarantined -> onImport()
            is LibraryEmptyUi.NoResults, LibraryEmptyUi.NoFilterMatch -> onClearFilters()
            is LibraryEmptyUi.SyncedEmpty, is LibraryEmptyUi.FirstFetchRunning, null -> Unit
        }
    }

    private fun openSyncSettings() = effectChannel.send(LibraryEffect.OpenSettings(SettingsSyncRoute))

    private fun showStartSync() {
        val status = sync.status.value
        val provider = status.provider ?: return openSyncSettings()
        showDialog(
            AppDialog.StartSync(
                provider = SyncPresentation.providerName(provider),
                destination = SyncPresentation.destination(provider),
                snippetCount = library.snapshot.value.counts.total,
                plainText = (provider as? SyncProvider.Git)?.isPlainText == true,
            ),
        )
    }

    /** An action that needs confirmation opens the Review screen; the others run at once. */
    private fun runRecovery(action: SyncRecoveryAction) {
        if (action.needsConfirmation) {
            effectChannel.send(LibraryEffect.Navigate(SyncReviewRoute))
            return
        }
        if (state.value.isSyncActionRunning) return
        viewModelScope.launch {
            state.update { it.copy(isSyncActionRunning = true) }
            try {
                sync.performRecovery(action)
            } finally {
                state.update { it.copy(isSyncActionRunning = false) }
                publish()
            }
        }
    }

    private fun optInVariant(status: SyncStatus): SyncOptIn = when (val provider = status.provider) {
        null -> SyncOptIn.NothingSetUp
        is SyncProvider.Git -> if (provider.isPlainText) SyncOptIn.PlainTextGit else SyncOptIn.Encrypted(SyncPresentation.providerName(provider))
        is SyncProvider.SnippetsCloud -> SyncOptIn.Encrypted(SyncPresentation.providerName(provider))
    }

    // endregion

    // region Dialogs

    override fun onClearClipboardNow() = clipboard.clearSecureNow()

    override fun onDismissDialog() = state.update { it.copy(dialog = null) }

    override fun onConfirmDialog(dialog: AppDialog) {
        onDismissDialog()
        when (dialog) {
            is AppDialog.DeleteSecure -> dialog.id.toUuidOrNull()?.let { uuid -> viewModelScope.launch { performDelete(uuid) } }
            is AppDialog.MakeOrdinary -> dialog.id.toUuidOrNull()?.let { uuid ->
                viewModelScope.launch { showConversion(operations.makeOrdinary(uuid), madeSecure = false) }
            }
            is AppDialog.SyncOptInPrompt -> if (dialog.variant == SyncOptIn.NothingSetUp) openSyncSettings() else turnSyncOn()
            is AppDialog.StartSync -> turnSyncOn()
            AppDialog.ScreenLockRequired -> effectChannel.send(LibraryEffect.OpenSecuritySettings)
            is AppDialog.Error -> if (dialog.recovery == ErrorRecovery.OpenGitRepository) {
                effectChannel.send(LibraryEffect.OpenSettings(SettingsSyncGitRoute))
            }
            AppDialog.ClipboardEmpty -> Unit
        }
    }

    private fun turnSyncOn() {
        val provider = SyncPresentation.providerName(sync.status.value.provider)
        effectChannel.send(snackbar(uiText(R.string.snackbar_connecting, provider)))
        viewModelScope.launch { sync.setEnabled(true) }
    }

    private fun showConversion(result: ConversionResult, madeSecure: Boolean) {
        when (result) {
            ConversionResult.Done -> effectChannel.send(
                snackbar(uiText(if (madeSecure) R.string.snackbar_made_secure else R.string.snackbar_made_ordinary)),
            )
            ConversionResult.Cancelled -> Unit
            is ConversionResult.SetupFailed -> showVaultFailure(R.string.error_title_secure_setup, result.error)
            is ConversionResult.Failed -> showVaultFailure(
                if (madeSecure) R.string.error_title_make_secure else R.string.error_title_make_ordinary,
                result.error,
            )
        }
    }

    private fun showVaultFailure(title: Int, error: VaultError) {
        effectChannel.send(LibraryEffect.Haptic(SnippetsHaptic.Rejected))
        when (val feedback = vaultFailureFeedback(title, error)) {
            is Feedback.Dialog -> showDialog(feedback.dialog)
            is Feedback.Snackbar -> effectChannel.send(snackbar(feedback.message))
        }
    }

    private fun showDialog(dialog: AppDialog) = state.update { it.copy(dialog = dialog) }

    // endregion

    // region State

    private fun onListing(next: Listing) {
        val previous = listing
        listing = next
        // Filters for tags that no longer exist drop silently.
        if (next.result.query.tagKeys != filterKeys.value) setFilters(next.result.query.tagKeys)
        selectNeighbourIfSelectedWasDeleted(previous, next)
        publish()
    }

    private fun selectNeighbourIfSelectedWasDeleted(previous: Listing?, next: Listing) {
        val selected = selectedId ?: return
        val uuid = selected.toUuidOrNull() ?: return
        if (previous == null || uuid in next.snapshot || !operations.wasRemovedLocally(uuid)) return
        val index = previous.rows.indexOfFirst { it.id == selected }
        val neighbour = if (index < 0) null else (next.rows.getOrNull(index) ?: next.rows.getOrNull(index - 1))?.id
        selectedId = neighbour
        effectChannel.send(LibraryEffect.SelectAfterRemoval(neighbour))
    }

    private fun publish() {
        val current = listing
        val status = sync.status.value
        if (current == null || current.snapshot.availability == LibraryAvailability.Loading) {
            startSpinnerTimer()
            return
        }
        spinnerJob?.cancel()
        spinnerJob = null
        val result = current.result
        val activeKeys = result.query.tagKeys
        val allTags = result.tags.map { TagFilterUi(TagUi(it.name, it.key), it.count, selected = it.key in activeKeys) }
        val byKey = allTags.associateBy { it.tag.folded }
        val libraryIsEmpty = result.totalCount == 0
        val syncUi = SyncPresentation.libraryRow(status, libraryIsEmpty, time)
        val empty = emptyReason(current, status)
        state.update { old ->
            old.copy(
                content = if (empty == null) LibraryContent.Rows else LibraryContent.Empty(empty),
                pinned = current.rows.filter { it.isPinned },
                others = current.rows.filterNot { it.isPinned },
                totalCount = result.totalCount,
                isFiltering = result.query.isFiltering,
                filterChips = activeKeys.mapNotNull(byKey::get) + allTags.filterNot { it.selected },
                sheetTags = allTags,
                activeFilterCount = activeKeys.size,
                sync = syncUi,
                syncMenu = SyncPresentation.menuAction(status),
                syncSheet = SyncSheetUi(
                    provider = SyncPresentation.providerLine(status.provider),
                    glyph = when (syncUi) {
                        is LibrarySyncUi.Quiet -> syncUi.glyph
                        is LibrarySyncUi.Card -> syncUi.glyph
                        LibrarySyncUi.Hidden -> SyncGlyph.Off
                    },
                    sentence = SyncPresentation.sentence(status, time),
                    canSyncNow = status.canSyncManually,
                    isSyncing = status.state is SyncState.Syncing,
                    conflictCount = byKey[CONFLICT_TAG_FOLDED]?.count ?: 0,
                ),
            )
        }
    }

    private fun emptyReason(listing: Listing, status: SyncStatus): LibraryEmptyUi? {
        if (listing.snapshot.availability == LibraryAvailability.Quarantined) {
            return LibraryEmptyUi.Quarantined(SyncPresentation.sentence(status, time))
        }
        if (listing.rows.isNotEmpty()) return null
        val query = listing.result.query
        if (query.hasText) return LibraryEmptyUi.NoResults(hasFilters = query.tagKeys.isNotEmpty())
        if (query.tagKeys.isNotEmpty()) return LibraryEmptyUi.NoFilterMatch
        if (!status.isEnabled) return LibraryEmptyUi.FirstRun(SyncPresentation.menuAction(status))
        if (status.hasFetchedLibrary) return LibraryEmptyUi.SyncedEmpty(SyncPresentation.sentence(status, time))
        val provider = SyncPresentation.providerName(status.provider)
        return when (val syncState = status.state) {
            SyncState.Syncing -> LibraryEmptyUi.FirstFetchRunning(provider, started = true)
            SyncState.Starting -> LibraryEmptyUi.FirstFetchRunning(provider, started = false)
            is SyncState.Idle -> if (syncState.lastSyncedAt == null) {
                LibraryEmptyUi.FirstFetchRunning(provider, started = false)
            } else {
                LibraryEmptyUi.SyncedEmpty(SyncPresentation.sentence(status, time))
            }
            else -> LibraryEmptyUi.FirstFetchStalled(
                sentence = SyncPresentation.sentence(status, time),
                action = when {
                    status.recoveryAction != null -> StalledAction.Recovery(status.recoveryAction)
                    status.needsAttention -> StalledAction.OpenSyncSettings
                    else -> StalledAction.TryAgain
                },
            )
        }
    }

    private fun startSpinnerTimer() {
        if (spinnerJob != null || state.value.content != LibraryContent.Loading(showSpinner = false)) return
        spinnerJob = viewModelScope.launch {
            delay(LOADING_SPINNER_DELAY_MILLIS)
            state.update { if (it.content is LibraryContent.Loading) it.copy(content = LibraryContent.Loading(showSpinner = true)) else it }
        }
    }

    private fun showCopied(id: String) {
        copiedJob?.cancel()
        state.update { it.copy(copiedId = id) }
        copiedJob = viewModelScope.launch {
            delay(Motion.COPIED_HOLD.toLong())
            state.update { it.copy(copiedId = null) }
        }
    }

    private fun showSwipeTipOnce() {
        if (settings.hints.value.swipeTipShown) return
        viewModelScope.launch {
            settings.markSwipeTipShown()
            delay(SWIPE_TIP_DELAY_MILLIS)
            effectChannel.send(snackbar(uiText(R.string.snackbar_swipe_tip), kind = SnackbarKind.Tip))
        }
    }

    private fun snackbar(message: UiText, kind: SnackbarKind = SnackbarKind.Result, undo: UndoToken? = null) =
        LibraryEffect.ShowSnackbar(SnackbarRequest(message, kind, undo))

    private fun withEntry(id: String, block: suspend (UUID, LibraryEntry) -> Unit) {
        val uuid = id.toUuidOrNull() ?: return
        val entry = library.snapshot.value.entry(uuid) ?: return
        viewModelScope.launch { block(uuid, entry) }
    }

    // endregion

    companion object {
        private const val KEY_QUERY = "library.query"
        private const val KEY_FILTERS = "library.filters"
        const val LOADING_SPINNER_DELAY_MILLIS = 300L
        const val SWIPE_TIP_DELAY_MILLIS = 2_400L

        fun factory(container: AppContainer): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                LibraryViewModel(
                    savedState = createSavedStateHandle(),
                    library = container.library,
                    queryEngine = container.newQueryEngine(),
                    sync = container.sync,
                    settings = container.settings,
                    operations = container.operations,
                    clipboard = container.clipboard,
                    time = container.timeFormatter,
                    defaultDispatcher = container.dispatchers.default,
                )
            }
        }
    }
}
