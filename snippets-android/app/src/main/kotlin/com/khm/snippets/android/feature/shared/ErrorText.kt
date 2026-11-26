package com.khm.snippets.android.feature.shared

import com.khm.snippets.android.R
import com.khm.snippets.android.data.LibraryError
import com.khm.snippets.android.data.VaultError

/** The sentence for a vault failure (screens-secure.md §9, D16). A cancellation never gets here. */
fun vaultErrorText(error: VaultError): UiText = when (error) {
    VaultError.Locked -> uiText(R.string.error_vault_locked)
    VaultError.NoKey -> uiText(R.string.error_vault_no_key)
    VaultError.KeyNotOnDevice -> uiText(R.string.error_vault_key_not_on_device)
    VaultError.GitVaultSetupRequired -> uiText(R.string.error_vault_git_setup_required)
    VaultError.ScreenLockRequired -> uiText(R.string.dialog_screen_lock_message)
    VaultError.AuthenticationNotApproved -> uiText(R.string.error_auth_not_approved)
    is VaultError.AuthenticationBlocked -> UiText.Raw(error.systemMessage)
    VaultError.NewerMetadata -> uiText(R.string.error_vault_newer_metadata)
    VaultError.KeywordExists -> uiText(R.string.error_vault_keyword_exists)
    VaultError.SnippetMissing -> uiText(R.string.error_snippet_missing)
    VaultError.InvalidText -> uiText(R.string.error_vault_invalid_text)
    VaultError.RecoveryKeyTypo -> uiText(R.string.error_recovery_key_typo)
    is VaultError.RecoveryKeyInvalidCharacter -> uiText(R.string.error_recovery_key_character, error.character)
    is VaultError.RecoveryKeyWrongLength -> uiText(R.string.error_recovery_key_length, error.expected, error.actual)
    VaultError.NoRecoveryKey -> uiText(R.string.error_recovery_key_none)
    VaultError.RecoveryKeyMismatch -> uiText(R.string.error_recovery_key_mismatch)
    VaultError.SyncIsOn -> uiText(R.string.error_vault_sync_is_on)
    VaultError.SetupChanged, VaultError.Unknown -> uiText(R.string.error_generic)
}

/** The sentence for a library failure. */
fun libraryErrorText(error: LibraryError): UiText = when (error) {
    LibraryError.NotFound -> uiText(R.string.error_snippet_missing)
    LibraryError.RecoveryRequired -> uiText(R.string.error_library_recovery_required)
    LibraryError.WriteFailed -> uiText(R.string.error_library_write_failed)
    LibraryError.NotAvailableForSecure,
    LibraryError.UndoUnavailable,
    LibraryError.EmptyImport,
    is LibraryError.ImportConflicts,
    -> uiText(R.string.error_generic)
}
