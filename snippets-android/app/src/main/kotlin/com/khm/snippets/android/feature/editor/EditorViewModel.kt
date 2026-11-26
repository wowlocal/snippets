package com.khm.snippets.android.feature.editor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.khm.snippets.android.app.AppContainer
import com.khm.snippets.android.R
import com.khm.snippets.android.data.KeywordAdvisor
import com.khm.snippets.android.data.KeywordDraft
import com.khm.snippets.android.data.LibraryAvailability
import com.khm.snippets.android.data.LibraryEntry
import com.khm.snippets.android.data.LibraryError
import com.khm.snippets.android.data.LibraryRepository
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.android.data.Outcome
import com.khm.snippets.android.data.SecureVault
import com.khm.snippets.android.data.SnippetEdit
import com.khm.snippets.android.data.SnippetResolver
import com.khm.snippets.android.data.SyncProvider
import com.khm.snippets.android.data.UndoToken
import com.khm.snippets.android.data.VaultError
import com.khm.snippets.android.data.VaultLockCause
import com.khm.snippets.android.data.VaultOwner
import com.khm.snippets.android.data.VaultResult
import com.khm.snippets.android.data.VaultState
import com.khm.snippets.android.data.VaultUnavailableCause
import com.khm.snippets.android.feature.shared.AppDialog
import com.khm.snippets.android.feature.shared.ConversionResult
import com.khm.snippets.android.feature.shared.CopyResult
import com.khm.snippets.android.feature.shared.EffectChannel
import com.khm.snippets.android.feature.shared.ErrorRecovery
import com.khm.snippets.android.feature.shared.Feedback
import com.khm.snippets.android.feature.shared.SnackbarRequest
import com.khm.snippets.android.feature.shared.SnippetOperations
import com.khm.snippets.android.feature.shared.UiText
import com.khm.snippets.android.feature.shared.errorDialog
import com.khm.snippets.android.feature.shared.libraryErrorText
import com.khm.snippets.android.feature.shared.uiText
import com.khm.snippets.android.feature.shared.vaultErrorText
import com.khm.snippets.android.feature.shared.vaultFailureFeedback
import com.khm.snippets.android.nav.SettingsSecureRoute
import com.khm.snippets.android.nav.SettingsSyncGitRoute
import com.khm.snippets.android.platform.CaptureRisk
import com.khm.snippets.android.platform.ClipboardService
import com.khm.snippets.android.platform.TimeFormatter
import com.khm.snippets.android.ui.components.SnippetsHaptic
import com.khm.snippets.android.ui.model.LockReason
import com.khm.snippets.android.ui.model.ProtectedCause
import com.khm.snippets.android.ui.model.SecurePanelState
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.TextHighlight
import com.khm.snippets.android.ui.model.UnavailableCause
import com.khm.snippets.android.ui.theme.Motion
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.EnumSet
import java.util.UUID

/**
 * EDIT (screens-library-editor.md §6, screens-secure.md §3, §4): one entry, saved as it is
 * typed. There is no Save and no discard dialog.
 *
 * Text fields are snapshot state ([name], [body], [keyword], [tagInput]); every change is
 * queued as a field-level [SnippetEdit] and written after [SAVE_DEBOUNCE_MILLIS] of quiet, at
 * once for tags and switches, and on blur, stop and leave. A remote change is applied field by
 * field, never to a field that has focus or an unsaved edit.
 *
 * The revealed secure body lives in [securePanel] only: never in saved state, wiped on lock.
 *
 * @param appScope Outlives the ViewModel: the final save and the blank-draft discard run there.
 * @param clipboardStandIn Shown for `{clipboard}` in the placeholder preview.
 * @param isPlainTextLibrary A plain-text Git library is active (the make-ordinary dialog says so).
 */
class EditorViewModel(
    private val id: UUID,
    private val library: LibraryRepository,
    private val vault: SecureVault,
    private val resolver: SnippetResolver,
    private val advisor: KeywordAdvisor,
    private val operations: SnippetOperations,
    private val clipboard: ClipboardService,
    private val time: TimeFormatter,
    private val captureRisk: StateFlow<CaptureRisk>,
    private val appScope: CoroutineScope,
    private val clipboardStandIn: String,
    private val isPlainTextLibrary: () -> Boolean,
) : ViewModel(), EditorActions, EditorDraft {
    private val state = MutableStateFlow(EditorUiState())
    private val effectChannel = EffectChannel<EditorEffect>()
    private val saveMutex = Mutex()
    private val focused: MutableSet<EditorField> = EnumSet.noneOf(EditorField::class.java)
    private var pending = SnippetEdit()
    private var saveJob: Job? = null
    private var tags: List<String> = emptyList()
    private var enabled = true
    private var pinned = false
    private var isSecure = false
    private var entrySeen = false
    private var secureBodyPending: String? = null
    private var secureSaveJob: Job? = null
    private var copiedJob: Job? = null
    private var secureSaveError: UiText? = null
    private var librarySaveError: UiText? = null
    private val preLockHook: AutoCloseable

    val uiState: StateFlow<EditorUiState> = state.asStateFlow()
    val effects: Flow<EditorEffect> = effectChannel.flow

    /** The countdown row after a secure copy; shared with the library. */
    val countdown = clipboard.countdown

    final override var name: String by mutableStateOf("")
        private set
    final override var body: String by mutableStateOf("")
        private set
    final override var keyword: TextFieldValue by mutableStateOf(TextFieldValue(""))
        private set
    final override var tagInput: String by mutableStateOf("")
        private set

    /** The secure body panel; [SecurePanelState.Revealed] holds the only plaintext copy. */
    final override var securePanel: SecurePanelState by mutableStateOf(SecurePanelState.Locked())
        private set

    init {
        onSnapshot(library.snapshot.value)
        viewModelScope.launch { library.snapshot.collect(::onSnapshot) }
        viewModelScope.launch { vault.state.collect(::onVaultState) }
        viewModelScope.launch { captureRisk.collect(::onCaptureRisk) }
        // The vault saves a pending secure edit through this before every lock.
        preLockHook = vault.addPreLockHook { saveSecureBody() }
    }

    // region Fields

    override fun onNameChange(text: String) {
        name = text
        queue(SnippetEdit(name = text))
    }

    override fun onBodyChange(text: String) {
        if (isSecure) return
        body = text
        queue(SnippetEdit(content = text))
    }

    override fun onKeywordChange(value: TextFieldValue) {
        val old = keyword.text
        when (val edit = EditorInput.keywordEdit(old, value.text)) {
            EditorInput.KeywordEdit.CompleteAtEnd -> complete()
            EditorInput.KeywordEdit.Ignore -> Unit
            is EditorInput.KeywordEdit.Text -> {
                keyword = if (edit.keyword == value.text) value else TextFieldValue(edit.keyword, TextRange(edit.keyword.length))
                if (edit.keyword != old) queue(SnippetEdit(keyword = edit.keyword))
            }
        }
    }

    override fun onKeywordTab(): Boolean = complete()

    override fun onKeywordSuggestion(keyword: String) {
        this.keyword = TextFieldValue(keyword, TextRange(keyword.length))
        queue(SnippetEdit(keyword = keyword))
    }

    /** Completes the next unambiguous keyword part; false when there is none. */
    private fun complete(): Boolean {
        val completed = advisor.completion(keyword.text, id, library.snapshot.value) ?: return false
        keyword = TextFieldValue(completed, TextRange(completed.length))
        queue(SnippetEdit(keyword = completed))
        return true
    }

    override fun onTagInputChange(text: String) {
        val edit = EditorInput.tagInputEdit(text)
        tagInput = edit.pending
        if (edit.committed.isNotEmpty()) setTags(EditorInput.withTags(tags, edit.committed)) else publish()
    }

    override fun onTagCommit() {
        val typed = tagInput
        tagInput = ""
        if (typed.isBlank()) publish() else setTags(EditorInput.withTags(tags, listOf(typed)))
    }

    override fun onTagEnter() {
        val completion = state.value.tagCompletions.firstOrNull()
        if (completion != null) onTagCompletion(completion) else onTagCommit()
    }

    override fun onTagCompletion(tag: TagUi) {
        tagInput = ""
        setTags(EditorInput.withTags(tags, listOf(tag.name)))
    }

    override fun onRemoveTag(tag: TagUi) = setTags(EditorInput.withoutTag(tags, tag.folded))

    override fun onRemoveLastTag() {
        if (tags.isNotEmpty()) setTags(tags.dropLast(1))
    }

    private fun setTags(newTags: List<String>) {
        if (newTags != tags) {
            tags = newTags
            queue(SnippetEdit(tags = newTags), immediate = true)
        } else {
            publish()
        }
    }

    override fun onFieldFocusChanged(field: EditorField, focused: Boolean) {
        if (focused) {
            this.focused += field
            return
        }
        this.focused -= field
        if (field == EditorField.SecureBody) {
            viewModelScope.launch { saveSecureBody() }
            return
        }
        // Blur writes at once; afterwards the field follows the store again.
        saveJob?.cancel()
        viewModelScope.launch {
            commit()
            library.snapshot.value.entry(id)?.let(::applyRemote)
        }
    }

    override fun onEnabledChange(enabled: Boolean) {
        this.enabled = enabled
        queue(SnippetEdit(isEnabled = enabled), immediate = true)
        effectChannel.send(EditorEffect.Haptic(if (enabled) SnippetsHaptic.ToggledOn else SnippetsHaptic.ToggledOff))
    }

    override fun onTogglePin() {
        lockRevealed()
        pinned = !pinned
        queue(SnippetEdit(isPinned = pinned), immediate = true)
        effectChannel.send(EditorEffect.Haptic(if (pinned) SnippetsHaptic.ToggledOn else SnippetsHaptic.ToggledOff))
    }

    // endregion

    // region Saving

    private fun queue(edit: SnippetEdit, immediate: Boolean = false) {
        pending = pending.mergedWith(edit)
        saveJob?.cancel()
        saveJob = viewModelScope.launch {
            if (!immediate) delay(SAVE_DEBOUNCE_MILLIS)
            commit()
        }
        publish()
    }

    /** Writes the queued edit. Once taken from the queue it is written even if the caller is cancelled. */
    private suspend fun commit() = saveMutex.withLock {
        val edit = pending
        pending = SnippetEdit()
        if (edit.isEmpty) return@withLock
        withContext(NonCancellable) {
            librarySaveError = when (val result = library.update(id, edit)) {
                is Outcome.Success -> null
                // The entry is gone; the snapshot observer closes the editor.
                is Outcome.Failure -> if (result.error == LibraryError.NotFound) null else uiText(R.string.editor_save_error, libraryErrorText(result.error))
            }
            publish()
        }
    }

    private suspend fun saveSecureBody() {
        val text = secureBodyPending ?: return
        secureBodyPending = null
        secureSaveJob?.cancel()
        withContext(NonCancellable) {
            secureSaveError = when (val result = vault.updateBody(id, text)) {
                is VaultResult.Failure -> uiText(R.string.editor_secure_save_error, vaultErrorText(result.error))
                VaultResult.Cancelled, is VaultResult.Success -> null
            }
            publish()
        }
    }

    override fun onStop() {
        saveJob?.cancel()
        viewModelScope.launch {
            commit()
            saveSecureBody()
        }
    }

    override fun onCleared() {
        preLockHook.close()
        saveJob?.cancel()
        val blank = !isSecure && name.isBlank() && keyword.text.isEmpty() && body.isBlank() && tags.isEmpty()
        appScope.launch {
            commit()
            saveSecureBody()
            library.flush()
            if (blank) operations.discardBlankDraft(id)
        }
    }

    // endregion

    // region Store and vault

    private fun onSnapshot(snapshot: LibrarySnapshot) {
        val entry = snapshot.entry(id)
        if (entry == null) {
            if (snapshot.availability != LibraryAvailability.Ready || state.value.status == EditorStatus.Gone) return
            state.update { it.copy(status = EditorStatus.Gone) }
            when {
                // Deleted here: the delete that removed it already closed the editor.
                operations.wasRemovedLocally(id) -> Unit
                entrySeen -> {
                    effectChannel.send(
                        EditorEffect.ShowSnackbar(
                            SnackbarRequest(uiText(R.string.snackbar_deleted_elsewhere, displayName())),
                        ),
                    )
                    effectChannel.send(EditorEffect.Close(EditorCloseReason.DeletedElsewhere))
                }
                else -> effectChannel.send(EditorEffect.Close(EditorCloseReason.Missing))
            }
            return
        }
        if (!entrySeen) {
            entrySeen = true
            load(entry)
        } else {
            applyRemote(entry)
        }
    }

    private fun load(entry: LibraryEntry) {
        val snippet = entry.snippet
        name = snippet.name
        keyword = TextFieldValue(snippet.normalizedKeyword, TextRange(snippet.normalizedKeyword.length))
        isSecure = entry.isSecure
        body = if (entry.isSecure) "" else snippet.content
        tags = snippet.tags
        enabled = snippet.isEnabled
        pinned = snippet.isPinned
        publish()
    }

    /** A change from the store: applied to every field without focus or a queued edit. */
    private fun applyRemote(entry: LibraryEntry) {
        val snippet = entry.snippet
        if (EditorField.Name !in focused && pending.name == null) name = snippet.name
        if (EditorField.Keyword !in focused && pending.keyword == null && keyword.text != snippet.normalizedKeyword) {
            keyword = TextFieldValue(snippet.normalizedKeyword, TextRange(snippet.normalizedKeyword.length))
        }
        if (pending.tags == null) tags = snippet.tags
        if (pending.isEnabled == null) enabled = snippet.isEnabled
        if (pending.isPinned == null) pinned = snippet.isPinned
        if (entry.isSecure != isSecure) {
            // Made secure or ordinary: the editor rebinds to the other kind of body.
            isSecure = entry.isSecure
            wipeSecureBody()
            securePanel = SecurePanelState.Locked()
            body = if (entry.isSecure) "" else snippet.content
        } else if (!entry.isSecure && EditorField.Body !in focused && pending.content == null) {
            body = snippet.content
        }
        publish()
    }

    private fun onVaultState(vaultState: VaultState) {
        if (!isSecure) return
        val panel = securePanel
        securePanel = when (vaultState) {
            is VaultState.Unavailable -> when (vaultState.cause) {
                VaultUnavailableCause.NoScreenLock -> SecurePanelState.Unavailable(UnavailableCause.NoScreenLock)
                VaultUnavailableCause.Unreadable -> lockedFrom(panel, null)
            }
            is VaultState.KeyMissing -> SecurePanelState.Unavailable(
                if (vaultState.owner == VaultOwner.GitLibrary) UnavailableCause.GitVaultNotSetUp else UnavailableCause.VaultKeyMissing,
            )
            VaultState.NoVault -> SecurePanelState.Unavailable(UnavailableCause.VaultKeyMissing)
            is VaultState.Locked -> lockedFrom(panel, reasonOf(vaultState.lastLock))
            is VaultState.Unlocked -> if (panel is SecurePanelState.Unavailable) SecurePanelState.Locked() else panel
        }
    }

    /** The panel after the session ended: a revealed body locks with the reason; an open prompt keeps waiting. */
    private fun lockedFrom(panel: SecurePanelState, reason: LockReason?): SecurePanelState = when (panel) {
        SecurePanelState.Unlocking, is SecurePanelState.Locked -> panel
        is SecurePanelState.Revealed -> {
            wipeSecureBody()
            SecurePanelState.Locked(reason)
        }
        is SecurePanelState.Protected, is SecurePanelState.Unavailable -> SecurePanelState.Locked()
    }

    private fun reasonOf(cause: VaultLockCause?): LockReason? = when (cause) {
        VaultLockCause.IdleTimeout -> LockReason.IdleTimeout
        VaultLockCause.SessionExpired -> LockReason.SessionExpired
        VaultLockCause.LeftApp -> LockReason.LeftApp
        VaultLockCause.Manual, VaultLockCause.OneUseAuthentication, null -> null
    }

    private fun onCaptureRisk(risk: CaptureRisk) {
        val panel = securePanel
        when {
            risk != CaptureRisk.None && panel is SecurePanelState.Revealed -> {
                viewModelScope.launch { saveSecureBody() }
                securePanel = SecurePanelState.Protected(causeOf(risk))
            }
            risk == CaptureRisk.None && panel is SecurePanelState.Protected -> securePanel = SecurePanelState.Locked()
        }
    }

    private fun causeOf(risk: CaptureRisk): ProtectedCause =
        if (risk == CaptureRisk.ScreenRecording) ProtectedCause.ScreenRecording else ProtectedCause.UnprotectedDisplay

    // endregion

    // region Secure body

    override fun onReveal() {
        if (securePanel !is SecurePanelState.Locked) return
        securePanel = SecurePanelState.Unlocking
        viewModelScope.launch {
            when (val result = vault.reveal(id)) {
                is VaultResult.Success -> {
                    val risk = captureRisk.value
                    if (risk != CaptureRisk.None) {
                        securePanel = SecurePanelState.Protected(causeOf(risk))
                    } else {
                        securePanel = SecurePanelState.Revealed(result.value)
                        effectChannel.send(EditorEffect.FocusSecureBody)
                    }
                }
                VaultResult.Cancelled -> securePanel = SecurePanelState.Locked()
                is VaultResult.Failure -> {
                    securePanel = SecurePanelState.Locked()
                    showVaultFailure(R.string.error_title_reveal, result.error)
                }
            }
        }
    }

    override fun onSecureBodyChange(text: String) {
        if (securePanel !is SecurePanelState.Revealed) return
        securePanel = SecurePanelState.Revealed(text)
        secureBodyPending = text
        secureSaveJob?.cancel()
        secureSaveJob = viewModelScope.launch {
            delay(SAVE_DEBOUNCE_MILLIS)
            saveSecureBody()
        }
    }

    override fun onLock() {
        lockRevealed()
        viewModelScope.launch { vault.lock(VaultLockCause.Manual) }
    }

    override fun onSecureUnavailableAction() {
        val cause = (securePanel as? SecurePanelState.Unavailable)?.cause ?: return
        effectChannel.send(
            when (cause) {
                UnavailableCause.NoScreenLock -> EditorEffect.OpenSecuritySettings
                UnavailableCause.GitVaultNotSetUp -> EditorEffect.OpenSettings(SettingsSyncGitRoute)
                UnavailableCause.VaultKeyMissing -> EditorEffect.OpenSettings(SettingsSecureRoute)
            },
        )
    }

    override fun onMenuOpened() = lockRevealed()

    /** Re-locks a revealed body: a pending edit is saved, then the plaintext leaves composition. */
    private fun lockRevealed() {
        if (securePanel !is SecurePanelState.Revealed) return
        viewModelScope.launch { saveSecureBody() }
        securePanel = SecurePanelState.Locked()
    }

    private fun wipeSecureBody() {
        if (securePanel is SecurePanelState.Revealed) securePanel = SecurePanelState.Locked()
    }

    // endregion

    // region Actions

    override fun onCopy() {
        lockRevealed()
        viewModelScope.launch {
            commit()
            when (val result = operations.copy(id)) {
                is CopyResult.Copied -> {
                    effectChannel.send(EditorEffect.Haptic(SnippetsHaptic.CopySucceeded))
                    if (!result.wasSecure) {
                        showCopiedCheck()
                        if (!clipboard.showsSystemCopyConfirmation) snackbar(uiText(R.string.snackbar_copied, result.name))
                    }
                }
                is CopyResult.NothingToCopy -> {
                    snackbar(uiText(R.string.snackbar_nothing_to_copy, result.name))
                    effectChannel.send(EditorEffect.Haptic(SnippetsHaptic.Rejected))
                }
                CopyResult.Cancelled -> Unit
                CopyResult.Missing -> showDialog(errorDialog(R.string.error_title_copy, uiText(R.string.error_snippet_missing)))
                is CopyResult.Failed -> showVaultFailure(R.string.error_title_copy, result.error)
            }
        }
    }

    override fun onShareText() {
        viewModelScope.launch {
            commit()
            val text = operations.resolvedText(id) ?: return@launch
            if (text.isEmpty()) {
                snackbar(uiText(R.string.snackbar_nothing_to_copy, displayName()))
            } else {
                effectChannel.send(EditorEffect.Share(text, displayName()))
            }
        }
    }

    override fun onShareLink() {
        viewModelScope.launch {
            commit()
            when (val link = library.shareLink(id)) {
                is Outcome.Success -> effectChannel.send(EditorEffect.Share(link.value, displayName()))
                is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_share, libraryErrorText(link.error)))
            }
        }
    }

    override fun onCopyShareLink() {
        viewModelScope.launch {
            commit()
            when (val result = operations.copyShareLink(id)) {
                is Outcome.Success -> if (!clipboard.showsSystemCopyConfirmation) snackbar(uiText(R.string.snackbar_copied_share_link))
                is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_copy_link, libraryErrorText(result.error)))
            }
        }
    }

    override fun onDuplicate() {
        viewModelScope.launch {
            commit()
            when (val copy = library.duplicate(id)) {
                is Outcome.Success -> effectChannel.send(EditorEffect.OpenEditor(copy.value.toString()))
                is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_update, libraryErrorText(copy.error)))
            }
        }
    }

    override fun onDelete() {
        lockRevealed()
        if (isSecure) {
            showDialog(AppDialog.DeleteSecure(id.toString(), displayName()))
        } else {
            viewModelScope.launch { delete() }
        }
    }

    private suspend fun delete() {
        commit()
        when (val result = operations.delete(id)) {
            is Outcome.Success -> {
                val deletion = result.value
                effectChannel.send(EditorEffect.Haptic(SnippetsHaptic.Deleted))
                snackbar(
                    if (deletion.wasSecure) uiText(R.string.snackbar_secure_deleted) else uiText(R.string.snackbar_deleted, deletion.name),
                    undo = deletion.undo,
                )
                effectChannel.send(EditorEffect.Close(EditorCloseReason.Deleted))
            }
            is Outcome.Failure -> showDialog(errorDialog(R.string.error_title_delete, libraryErrorText(result.error)))
        }
    }

    override fun onSecureChange(secure: Boolean) {
        if (secure == isSecure || state.value.isConverting) return
        effectChannel.send(EditorEffect.HideKeyboard)
        if (!secure) {
            lockRevealed()
            showDialog(AppDialog.MakeOrdinary(id.toString(), plainTextLibrary = isPlainTextLibrary()))
            return
        }
        viewModelScope.launch {
            commit()
            convert(madeSecure = true) { operations.makeSecure(id) }
        }
    }

    private suspend fun convert(madeSecure: Boolean, move: suspend () -> ConversionResult) {
        state.update { it.copy(isConverting = true) }
        val result = try {
            move()
        } finally {
            state.update { it.copy(isConverting = false) }
        }
        when (result) {
            ConversionResult.Done -> snackbar(uiText(if (madeSecure) R.string.snackbar_made_secure else R.string.snackbar_made_ordinary))
            ConversionResult.Cancelled -> Unit
            is ConversionResult.SetupFailed -> showVaultFailure(R.string.error_title_secure_setup, result.error)
            is ConversionResult.Failed -> showVaultFailure(
                if (madeSecure) R.string.error_title_make_secure else R.string.error_title_make_ordinary,
                result.error,
            )
        }
    }

    override fun onDismissDialog() = state.update { it.copy(dialog = null) }

    override fun onConfirmDialog(dialog: AppDialog) {
        onDismissDialog()
        when (dialog) {
            is AppDialog.DeleteSecure -> viewModelScope.launch { delete() }
            is AppDialog.MakeOrdinary -> viewModelScope.launch { convert(madeSecure = false) { operations.makeOrdinary(id) } }
            AppDialog.ScreenLockRequired -> effectChannel.send(EditorEffect.OpenSecuritySettings)
            is AppDialog.Error -> if (dialog.recovery == ErrorRecovery.OpenGitRepository) {
                effectChannel.send(EditorEffect.OpenSettings(SettingsSyncGitRoute))
            }
            AppDialog.ClipboardEmpty, is AppDialog.StartSync, is AppDialog.SyncOptInPrompt -> Unit
        }
    }

    // endregion

    // region State

    /** Recomputes everything derived from the fields and the library. Cheap; runs on every keystroke. */
    private fun publish() {
        val snapshot = library.snapshot.value
        val entry = snapshot.entry(id) ?: return
        val content = if (isSecure) "" else body
        val draft = KeywordDraft(
            entryId = id,
            keyword = keyword.text,
            name = name,
            contentFirstLine = Snippet(name = "", keyword = "", content = content).contentFirstLine,
            isEnabled = enabled,
        )
        val placeholders = if (isSecure) emptyList() else resolver.placeholderRanges(body)
        val libraryTags = snapshot.tags.map { TagUi(it.name, it.key) }
        state.update {
            it.copy(
                status = EditorStatus.Ready,
                title = EditorInput.title(name, body, isSecure),
                isSecure = isSecure,
                namePlaceholder = EditorInput.namePlaceholder(body, isSecure),
                bodyPlaceholders = placeholders.map { range -> TextHighlight(range.start, range.end) },
                preview = if (placeholders.isEmpty()) null else resolver.preview(body, clipboardStandIn),
                keywordMessage = EditorInput.keywordMessage(advisor.advice(draft, snapshot)),
                keywordSuggestions = if (keyword.text.isEmpty()) advisor.suggestions(draft, snapshot) else emptyList(),
                existingKeywords = advisor.existingMatches(keyword.text, id, snapshot),
                tags = tags.map { tag -> TagUi(tag, SnippetTagging.filterKey(tag)) },
                tagCompletions = EditorInput.tagCompletions(tagInput, libraryTags, tags),
                isEnabled = enabled,
                isPinned = pinned,
                savedAt = if (isSecure) null else savedText(entry.snippet.updatedAt),
                saveError = librarySaveError ?: secureSaveError,
            )
        }
    }

    private fun savedText(appleSeconds: Double): UiText =
        uiText(R.string.editor_footer_saved, time.mediumDate(appleSeconds), time.shortTime(appleSeconds))

    private fun displayName(): String = library.snapshot.value.entry(id)?.displayName ?: Snippet(name = name, keyword = "", content = "").displayName

    private fun showCopiedCheck() {
        copiedJob?.cancel()
        state.update { it.copy(showsCopiedCheck = true) }
        copiedJob = viewModelScope.launch {
            delay(Motion.COPIED_HOLD.toLong())
            state.update { it.copy(showsCopiedCheck = false) }
        }
    }

    private fun snackbar(message: UiText, undo: UndoToken? = null) =
        effectChannel.send(EditorEffect.ShowSnackbar(SnackbarRequest(message, undo = undo)))

    private fun showVaultFailure(title: Int, error: VaultError) {
        effectChannel.send(EditorEffect.Haptic(SnippetsHaptic.Rejected))
        when (val feedback = vaultFailureFeedback(title, error)) {
            is Feedback.Dialog -> showDialog(feedback.dialog)
            is Feedback.Snackbar -> snackbar(feedback.message)
        }
    }

    private fun showDialog(dialog: AppDialog) {
        lockRevealed()
        state.update { it.copy(dialog = dialog) }
    }

    // endregion

    companion object {
        /** Text fields are written after this much quiet (§6.7). */
        const val SAVE_DEBOUNCE_MILLIS = 300L

        fun factory(container: AppContainer, id: UUID, clipboardStandIn: String): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                EditorViewModel(
                    id = id,
                    library = container.library,
                    vault = container.vault,
                    resolver = container.resolver,
                    advisor = container.keywordAdvisor,
                    operations = container.operations,
                    clipboard = container.clipboard,
                    time = container.timeFormatter,
                    captureRisk = container.screenCapture.risk,
                    appScope = container.appScope,
                    clipboardStandIn = clipboardStandIn,
                    isPlainTextLibrary = {
                        val status = container.sync.status.value
                        status.isEnabled && (status.provider as? SyncProvider.Git)?.isPlainText == true
                    },
                )
            }
        }
    }
}
