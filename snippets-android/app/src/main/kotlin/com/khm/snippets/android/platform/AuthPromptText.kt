package com.khm.snippets.android.platform

import androidx.annotation.StringRes
import com.khm.snippets.android.R

/**
 * Title and subtitle of the system prompt for one [AuthReason] (screens-secure.md §2).
 *
 * @param name Format argument of [title] for the reasons that name a snippet, else null.
 */
data class AuthPromptText(@param:StringRes val title: Int, val name: String?, @param:StringRes val subtitle: Int)

/** The one mapping from a reason to its prompt copy; the `BiometricPrompt` wrapper uses it. */
fun authPromptText(reason: AuthReason): AuthPromptText = when (reason) {
    is AuthReason.CopySnippet -> AuthPromptText(R.string.auth_copy_title, reason.name, R.string.auth_copy_subtitle)
    is AuthReason.InsertSnippet -> AuthPromptText(R.string.auth_insert_title, reason.name, R.string.auth_insert_subtitle)
    is AuthReason.RevealSnippet -> AuthPromptText(R.string.auth_reveal_title, reason.name, R.string.auth_reveal_subtitle)
    AuthReason.MakeSecure -> AuthPromptText(R.string.auth_make_secure_title, null, R.string.auth_make_secure_subtitle)
    AuthReason.MakeOrdinary -> AuthPromptText(R.string.auth_make_ordinary_title, null, R.string.auth_make_ordinary_subtitle)
    AuthReason.CreateRecoveryKey -> AuthPromptText(R.string.auth_recovery_key_title, null, R.string.auth_recovery_key_subtitle)
    AuthReason.ExportBackup -> AuthPromptText(R.string.auth_export_backup_title, null, R.string.auth_backup_subtitle)
    AuthReason.ImportBackup -> AuthPromptText(R.string.auth_import_backup_title, null, R.string.auth_backup_subtitle)
    AuthReason.GitCreateRecoveryCode -> AuthPromptText(R.string.auth_git_create_title, null, R.string.auth_git_create_subtitle)
    AuthReason.GitNewRecoveryCode -> AuthPromptText(R.string.auth_git_new_code_title, null, R.string.auth_git_new_code_subtitle)
    AuthReason.GitReplaceKeys -> AuthPromptText(R.string.auth_git_replace_keys_title, null, R.string.auth_git_replace_keys_subtitle)
    AuthReason.GitMoveSecureSnippets -> AuthPromptText(R.string.auth_git_move_title, null, R.string.auth_git_move_subtitle)
}
