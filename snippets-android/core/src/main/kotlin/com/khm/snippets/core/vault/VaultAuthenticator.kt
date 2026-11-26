package com.khm.snippets.core.vault

/**
 * Why the device owner is being asked to authenticate. The app phrases the prompt;
 * [text] is the English wording the Apple apps show, for parity and for logs that name no
 * snippet ([text] of [Reveal] and [Copy] contains a snippet name: never log those two).
 *
 * A prompt the user can connect to an action is one they do not learn to approve by
 * reflex, so every call site states its own reason.
 */
sealed class VaultAuthenticationReason(val text: String) {

    /** Show a secure body in the editor. No prompt inside an open session. */
    class Reveal(val snippetName: String) : VaultAuthenticationReason("Reveal “$snippetName”")

    /** Copy a secure snippet. Always prompts. */
    class Copy(val displayName: String) : VaultAuthenticationReason("Copy $displayName")

    object MakeSecure : VaultAuthenticationReason("Make this snippet secure")

    object MakeOrdinary : VaultAuthenticationReason("Make this secure snippet ordinary")

    object CreateRecoveryKey : VaultAuthenticationReason("Create and display a recovery key")

    object ExportBackup : VaultAuthenticationReason("Export an encrypted backup including secure snippets")

    object ImportBackup : VaultAuthenticationReason("Import secure snippets from an encrypted backup")

    /** Any other action, already phrased. Used by providers (publishing or re-sealing a library's vault). */
    class Other(text: String) : VaultAuthenticationReason(text)

    override fun toString(): String = javaClass.simpleName
}

/** How an authentication ended. Only [SUCCESS] opens anything. */
enum class VaultAuthenticationResult {
    SUCCESS,

    /** The user dismissed the prompt. The app shows nothing for this. */
    CANCELLED,

    /** The device cannot authenticate its owner now: no secure lock screen, no hardware, policy. */
    UNAVAILABLE,

    /** Too many failed attempts; the system refuses for a while or until the device credential is entered. */
    LOCKOUT,

    /** The attempt was not approved, or the prompt failed for any other reason. */
    FAILED,
}

/**
 * Proves the device owner is present: biometrics or the device credential, as
 * `LAPolicy.deviceOwnerAuthentication` on Apple. The app implements this with
 * `BiometricPrompt` (strong biometric or device credential).
 *
 * Contract:
 *
 * - Every call shows a fresh prompt. No result may be reused from an earlier call; the
 *   session supplies its own five-minute window.
 * - Suspend until the user answers. Return a [VaultAuthenticationResult]; do not throw
 *   for an ordinary refusal. An exception is treated as [VaultAuthenticationResult.FAILED].
 * - Honour cancellation of the calling coroutine by dismissing the prompt.
 * - [VaultSession] never calls this while another call of its own is in flight, so
 *   prompts are never stacked.
 * - It may be called on any dispatcher (the backup flows call it from their I/O
 *   context). Switch to the main thread for `BiometricPrompt` yourself.
 * - Do not log `reason.text`.
 */
fun interface VaultAuthenticator {
    suspend fun authenticate(reason: VaultAuthenticationReason): VaultAuthenticationResult
}

/**
 * A clock that only moves forward and keeps counting while the device sleeps, in
 * milliseconds from an arbitrary origin. The session's deadlines are measured on it, so a
 * change of the wall clock can neither extend nor cut short an unlock.
 *
 * On Android pass `SystemClock.elapsedRealtime()`. [System] uses `System.nanoTime()`,
 * which on Android stops during deep sleep and is meant for the JVM and for tests.
 * Swift measures the same deadlines on the wall clock (`Date()`).
 */
fun interface MonotonicClock {
    fun nowMillis(): Long

    companion object {
        val System: MonotonicClock = MonotonicClock { java.lang.System.nanoTime() / 1_000_000 }
    }
}
