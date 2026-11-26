package com.khm.snippets.android.feature.shared

import androidx.annotation.StringRes
import com.khm.snippets.android.data.VaultError

/** How a failure is shown: a dialog for something the user must read, a snackbar otherwise. */
sealed interface Feedback {
    data class Dialog(val dialog: AppDialog) : Feedback

    /** A system authentication message (lockout, timeout), shown as the system phrased it. */
    data class Snackbar(val message: UiText) : Feedback
}

/**
 * The feedback for a vault failure of an action titled [title] (`Couldn’t Copy Snippet`, …).
 * A missing screen lock gets its own dialog; lockout and hardware messages go to a snackbar
 * (screens-secure.md §2). Every case here also deserves the `Reject` haptic.
 */
fun vaultFailureFeedback(@StringRes title: Int, error: VaultError): Feedback = when (error) {
    VaultError.ScreenLockRequired -> Feedback.Dialog(AppDialog.ScreenLockRequired)
    is VaultError.AuthenticationBlocked -> Feedback.Snackbar(UiText.Raw(error.systemMessage))
    VaultError.GitVaultSetupRequired ->
        Feedback.Dialog(errorDialog(title, vaultErrorText(error), ErrorRecovery.OpenGitRepository))
    else -> Feedback.Dialog(errorDialog(title, vaultErrorText(error)))
}
