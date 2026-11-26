package com.khm.snippets.android.platform

/**
 * Why the device owner is asked to authenticate (screens-secure.md §2). The prompt's title and
 * subtitle come from [authPromptText]; names are display names.
 */
sealed interface AuthReason {
    data class CopySnippet(val name: String) : AuthReason
    data class InsertSnippet(val name: String) : AuthReason
    data class RevealSnippet(val name: String) : AuthReason
    data object MakeSecure : AuthReason
    data object MakeOrdinary : AuthReason
    data object CreateRecoveryKey : AuthReason
    data object ExportBackup : AuthReason
    data object ImportBackup : AuthReason
    data object GitCreateRecoveryCode : AuthReason
    data object GitNewRecoveryCode : AuthReason
    data object GitReplaceKeys : AuthReason
    data object GitMoveSecureSnippets : AuthReason

    /** Copy and reveal skip the explicit confirmation step; everything else requires it. */
    val requiresConfirmation: Boolean
        get() = this !is CopySnippet && this !is RevealSnippet
}

/** How a prompt ended. */
sealed interface AuthResult {
    data object Success : AuthResult

    /** The user dismissed the prompt: silent everywhere. */
    data object Cancelled : AuthResult

    /** Lockout, timeout or unavailable hardware, with the system's own message. */
    data class Blocked(val systemMessage: String) : AuthResult

    /** The attempt was not approved. */
    data object NotApproved : AuthResult
}

/**
 * Proves the device owner is present: fingerprint, face or screen lock through the system
 * prompt. The app never draws authentication UI and never prompts without a user action.
 *
 * Contract: every call shows a fresh prompt; it suspends until the user answers; cancelling the
 * calling coroutine dismisses the prompt; prompts are never stacked.
 */
interface DeviceAuthenticator {
    /** False when the device has no screen lock (`KeyguardManager.isDeviceSecure`). */
    val isDeviceSecure: Boolean

    suspend fun authenticate(reason: AuthReason): AuthResult
}
