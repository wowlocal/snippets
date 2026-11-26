package com.khm.snippets.android.feature.shared

import com.khm.snippets.android.data.BodyPurpose
import com.khm.snippets.android.data.Deletion
import com.khm.snippets.android.data.LibraryError
import com.khm.snippets.android.data.LibraryRepository
import com.khm.snippets.android.data.Outcome
import com.khm.snippets.android.data.SecureVault
import com.khm.snippets.android.data.SnippetResolver
import com.khm.snippets.android.data.UndoToken
import com.khm.snippets.android.data.VaultError
import com.khm.snippets.android.data.VaultResult
import com.khm.snippets.android.platform.ClipboardService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.util.UUID

/** How a copy ended (screens-library-editor.md §2.3). */
sealed interface CopyResult {
    data class Copied(val name: String, val wasSecure: Boolean) : CopyResult

    /** The resolved text is empty: nothing was written. */
    data class NothingToCopy(val name: String) : CopyResult

    /** The authentication prompt was dismissed: silent. */
    data object Cancelled : CopyResult

    /** The entry no longer exists. */
    data object Missing : CopyResult
    data class Failed(val error: VaultError) : CopyResult
}

/** How making a snippet secure or ordinary ended (screens-secure.md §4). */
sealed interface ConversionResult {
    data object Done : ConversionResult

    /** A prompt or the recovery-key screen was cancelled: nothing changed, nothing is shown. */
    data object Cancelled : ConversionResult

    /** The vault could not be prepared (`Couldn’t Set Up Secure Snippets`). */
    data class SetupFailed(val error: VaultError) : ConversionResult

    /** The move itself failed (`Couldn’t Make Snippet Secure` / `… Ordinary`). */
    data class Failed(val error: VaultError) : ConversionResult
}

/**
 * The entry actions the library and the editor share: copy, delete with undo, share link and the
 * secure conversion. Application-scoped, so an undo still works after the screen that offered
 * it has gone.
 */
class SnippetOperations(
    private val library: LibraryRepository,
    private val vault: SecureVault,
    private val resolver: SnippetResolver,
    private val clipboard: ClipboardService,
    private val recoveryKeys: RecoveryKeyPresenter,
    private val appScope: CoroutineScope,
) {
    private val locallyRemoved = ArrayDeque<UUID>()

    /**
     * Copies an entry. Placeholders are resolved now; `{clipboard}` reads the clipboard at this
     * moment and only when the text uses it. A secure entry authenticates every time and its
     * clip is marked sensitive and cleared after 60 seconds.
     */
    suspend fun copy(id: UUID): CopyResult {
        val entry = library.snapshot.value.entry(id) ?: return CopyResult.Missing
        val name = entry.displayName
        if (!entry.isSecure) {
            val text = resolved(entry.snippet.content)
            if (text.isEmpty()) return CopyResult.NothingToCopy(name)
            clipboard.copyOrdinary(text)
            return CopyResult.Copied(name, wasSecure = false)
        }
        val result = vault.withBodyOnce(id, BodyPurpose.Copy) { body ->
            val text = resolved(body)
            if (text.isNotEmpty()) clipboard.copySecure(name, text)
            text.isNotEmpty()
        }
        return when (result) {
            is VaultResult.Success -> if (result.value) CopyResult.Copied(name, wasSecure = true) else CopyResult.NothingToCopy(name)
            VaultResult.Cancelled -> CopyResult.Cancelled
            is VaultResult.Failure -> if (result.error == VaultError.SnippetMissing) CopyResult.Missing else CopyResult.Failed(result.error)
        }
    }

    /** The resolved text of an ordinary entry for `Share Text`; null when the entry is gone. */
    fun resolvedText(id: UUID): String? {
        val entry = library.snapshot.value.entry(id)?.takeIf { !it.isSecure } ?: return null
        return resolved(entry.snippet.content)
    }

    /** Puts the `snippets://share` link of an ordinary entry on the clipboard. */
    suspend fun copyShareLink(id: UUID): Outcome<Unit, LibraryError> = when (val link = library.shareLink(id)) {
        is Outcome.Success -> {
            clipboard.copyOrdinary(link.value)
            Outcome.Success(Unit)
        }
        is Outcome.Failure -> link
    }

    suspend fun delete(id: UUID): Outcome<Deletion, LibraryError> {
        // Marked first: observers see the entry vanish before this call returns.
        markRemovedLocally(id)
        return library.delete(id).also { if (it is Outcome.Failure) unmarkRemovedLocally(id) }
    }

    /** Restores a deleted entry; safe to call from a snackbar action after its screen has gone. */
    fun undoDelete(token: UndoToken) {
        unmarkRemovedLocally(token.id)
        appScope.launch { library.restore(token) }
    }

    suspend fun discardBlankDraft(id: UUID): Boolean {
        markRemovedLocally(id)
        return library.discardBlankDraft(id).also { discarded -> if (!discarded) unmarkRemovedLocally(id) }
    }

    /**
     * True when this device removed [id] just now (delete, blank-draft discard). An entry that
     * disappears otherwise was deleted on another device.
     */
    fun wasRemovedLocally(id: UUID): Boolean = synchronized(locallyRemoved) { id in locallyRemoved }

    /** Ordinary to secure: prepare a vault if there is none, show its recovery key, then move. */
    suspend fun makeSecure(id: UUID): ConversionResult {
        library.flush()
        when (val setup = vault.prepareVaultSetup()) {
            VaultResult.Cancelled -> return ConversionResult.Cancelled
            is VaultResult.Failure -> return ConversionResult.SetupFailed(setup.error)
            is VaultResult.Success -> {
                val pending = setup.value
                if (pending != null) {
                    if (!recoveryKeys.present(pending, RecoveryKeyMode.Setup)) {
                        vault.discard(pending)
                        return ConversionResult.Cancelled
                    }
                    when (val commit = vault.commitVaultSetup(pending)) {
                        is VaultResult.Failure -> return ConversionResult.SetupFailed(commit.error)
                        VaultResult.Cancelled -> return ConversionResult.Cancelled
                        is VaultResult.Success -> Unit
                    }
                }
            }
        }
        return vault.makeSecure(id).toConversion()
    }

    /** Secure to ordinary, after the user confirmed `Make This Snippet Ordinary?`. */
    suspend fun makeOrdinary(id: UUID): ConversionResult = vault.makeOrdinary(id).toConversion()

    private fun resolved(template: String): String {
        val clipboardText = if (resolver.usesClipboard(template)) clipboard.readText() else null
        return resolver.resolve(template, clipboardText)
    }

    private fun markRemovedLocally(id: UUID) = synchronized(locallyRemoved) {
        locallyRemoved.addLast(id)
        while (locallyRemoved.size > REMEMBERED_REMOVALS) locallyRemoved.removeFirst()
    }

    private fun unmarkRemovedLocally(id: UUID) = synchronized(locallyRemoved) { locallyRemoved.remove(id) }

    private fun VaultResult<Unit>.toConversion(): ConversionResult = when (this) {
        is VaultResult.Success -> ConversionResult.Done
        VaultResult.Cancelled -> ConversionResult.Cancelled
        is VaultResult.Failure -> ConversionResult.Failed(error)
    }

    private companion object {
        const val REMEMBERED_REMOVALS = 16
    }
}
