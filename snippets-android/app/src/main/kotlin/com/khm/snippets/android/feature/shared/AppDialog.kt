package com.khm.snippets.android.feature.shared

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import com.khm.snippets.android.R
import com.khm.snippets.android.ui.components.ConfirmDialog
import com.khm.snippets.android.ui.components.ErrorDialog

/** A follow-up an error dialog can offer next to `OK`. */
enum class ErrorRecovery { OpenGitRepository }

/** Which sync opt-in dialog pull to refresh raises (screens-library-editor.md §7.3). */
@Immutable
sealed interface SyncOptIn {
    /** A provider is set up and encrypts records before upload. */
    @Immutable
    data class Encrypted(val provider: UiText) : SyncOptIn

    /** A plain-text Git library. */
    @Immutable
    data object PlainTextGit : SyncOptIn

    /** Nothing is set up: the confirm button opens Sync settings. */
    @Immutable
    data object NothingSetUp : SyncOptIn
}

/**
 * The alert dialogs the library and the editor share (screens-library-editor.md §7,
 * screens-secure.md §4.2 and §10). They are state of the screen that raised them, not back-stack
 * entries; the root is tagged with the route name (`dialog.delete-secure`).
 */
@Immutable
sealed interface AppDialog {
    @Immutable
    data class DeleteSecure(val id: String, val name: String) : AppDialog

    @Immutable
    data object ClipboardEmpty : AppDialog

    @Immutable
    data class SyncOptInPrompt(val variant: SyncOptIn) : AppDialog

    /** `dialog/switch`, "sync currently off" variant: start syncing with the provider set up. */
    @Immutable
    data class StartSync(val provider: UiText, val destination: UiText, val snippetCount: Int, val plainText: Boolean) : AppDialog

    @Immutable
    data object ScreenLockRequired : AppDialog

    @Immutable
    data class MakeOrdinary(val id: String, val plainTextLibrary: Boolean) : AppDialog

    @Immutable
    data class Error(val title: UiText, val message: UiText, val recovery: ErrorRecovery? = null) : AppDialog
}

/** `dialog/error` for a `Couldn’t …` title and an error sentence. */
fun errorDialog(title: Int, message: UiText, recovery: ErrorRecovery? = null): AppDialog.Error =
    AppDialog.Error(uiText(title), message, recovery)

/**
 * Draws [dialog] with the confirmation or error template.
 *
 * @param onConfirm The confirm button; the dialog is not dismissed by the host.
 * @param onDismiss The dismiss button, back, or a tap outside.
 */
@Composable
fun AppDialogHost(
    dialog: AppDialog?,
    onConfirm: (AppDialog) -> Unit,
    onDismiss: () -> Unit,
) {
    when (dialog) {
        null -> Unit
        is AppDialog.DeleteSecure -> ConfirmDialog(
            tag = "dialog.delete-secure",
            title = stringResource(R.string.dialog_delete_secure_title, dialog.name),
            paragraphs = listOf(stringResource(R.string.dialog_delete_secure_message)),
            dismissLabel = stringResource(R.string.action_cancel),
            onDismiss = onDismiss,
            confirmLabel = stringResource(R.string.action_delete),
            onConfirm = { onConfirm(dialog) },
            destructive = true,
        )
        AppDialog.ClipboardEmpty -> ConfirmDialog(
            tag = "dialog.clipboard-empty",
            title = stringResource(R.string.dialog_clipboard_empty_title),
            paragraphs = listOf(stringResource(R.string.dialog_clipboard_empty_message)),
            dismissLabel = stringResource(R.string.action_ok),
            onDismiss = onDismiss,
        )
        is AppDialog.SyncOptInPrompt -> SyncOptInDialog(dialog, onConfirm, onDismiss)
        is AppDialog.StartSync -> {
            val provider = dialog.provider.resolve()
            val count = pluralStringResource(R.plurals.library_count, dialog.snippetCount, dialog.snippetCount)
            ConfirmDialog(
                tag = "dialog.switch",
                title = stringResource(R.string.dialog_switch_start_title, provider),
                paragraphs = listOfNotNull(
                    stringResource(R.string.dialog_switch_start_message, count, dialog.destination.resolve()),
                    if (dialog.plainText) stringResource(R.string.dialog_switch_plain_text) else null,
                ),
                dismissLabel = stringResource(R.string.action_cancel),
                onDismiss = onDismiss,
                confirmLabel = stringResource(R.string.dialog_switch_confirm),
                onConfirm = { onConfirm(dialog) },
            )
        }
        AppDialog.ScreenLockRequired -> ConfirmDialog(
            tag = "dialog.screen-lock-required",
            title = stringResource(R.string.dialog_screen_lock_title),
            paragraphs = listOf(stringResource(R.string.dialog_screen_lock_message)),
            dismissLabel = stringResource(R.string.action_cancel),
            onDismiss = onDismiss,
            confirmLabel = stringResource(R.string.secure_panel_open_settings),
            onConfirm = { onConfirm(dialog) },
        )
        is AppDialog.MakeOrdinary -> ConfirmDialog(
            tag = "dialog.make-ordinary",
            title = stringResource(R.string.dialog_make_ordinary_title),
            paragraphs = listOfNotNull(
                stringResource(R.string.dialog_make_ordinary_message),
                if (dialog.plainTextLibrary) stringResource(R.string.dialog_make_ordinary_plain_text) else null,
            ),
            dismissLabel = stringResource(R.string.action_cancel),
            onDismiss = onDismiss,
            confirmLabel = stringResource(R.string.action_make_ordinary),
            onConfirm = { onConfirm(dialog) },
            destructive = true,
        )
        is AppDialog.Error -> ErrorDialog(
            title = dialog.title.resolve(),
            message = dialog.message.resolve(),
            onDismiss = onDismiss,
            recoveryLabel = dialog.recovery?.let { stringResource(R.string.secure_panel_open_git) },
            onRecovery = { onConfirm(dialog) },
        )
    }
}

@Composable
private fun SyncOptInDialog(
    dialog: AppDialog.SyncOptInPrompt,
    onConfirm: (AppDialog) -> Unit,
    onDismiss: () -> Unit,
) {
    val title: String
    val message: String
    val confirm: String
    when (val variant = dialog.variant) {
        is SyncOptIn.Encrypted -> {
            val provider = variant.provider.resolve()
            title = stringResource(R.string.dialog_sync_opt_in_title, provider)
            message = stringResource(R.string.dialog_sync_opt_in_message, provider)
            confirm = stringResource(R.string.dialog_sync_opt_in_confirm)
        }
        SyncOptIn.PlainTextGit -> {
            title = stringResource(R.string.dialog_sync_opt_in_title, stringResource(R.string.sync_provider_git))
            message = stringResource(R.string.dialog_sync_opt_in_plain_message)
            confirm = stringResource(R.string.dialog_sync_opt_in_confirm)
        }
        SyncOptIn.NothingSetUp -> {
            title = stringResource(R.string.dialog_sync_set_up_title)
            message = stringResource(R.string.dialog_sync_set_up_message)
            confirm = stringResource(R.string.sync_action_set_up)
        }
    }
    ConfirmDialog(
        tag = "dialog.sync-opt-in",
        title = title,
        paragraphs = listOf(message),
        dismissLabel = stringResource(R.string.action_not_now),
        onDismiss = onDismiss,
        confirmLabel = confirm,
        onConfirm = { onConfirm(dialog) },
    )
}
