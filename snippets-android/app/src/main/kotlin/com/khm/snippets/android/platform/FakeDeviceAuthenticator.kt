package com.khm.snippets.android.platform

import kotlinx.coroutines.CompletableDeferred

/**
 * The authenticator of tests, of the demo and of every build until the `BiometricPrompt`
 * implementation lands. It shows nothing: it answers with [answer] and records each request.
 */
class FakeDeviceAuthenticator(
    @Volatile var answer: AuthResult = AuthResult.Success,
    @Volatile override var isDeviceSecure: Boolean = true,
) : DeviceAuthenticator {
    private val recorded = ArrayList<AuthReason>()
    private var held: CompletableDeferred<AuthResult>? = null

    /** Every prompt that was requested, oldest first. */
    val requests: List<AuthReason> get() = synchronized(recorded) { recorded.toList() }

    /**
     * Keeps the next prompt "on screen" until the returned deferred is completed, so a test can
     * observe the authenticating state.
     */
    fun holdNext(): CompletableDeferred<AuthResult> = CompletableDeferred<AuthResult>().also { held = it }

    override suspend fun authenticate(reason: AuthReason): AuthResult {
        synchronized(recorded) { recorded += reason }
        val pending = held
        held = null
        return pending?.await() ?: answer
    }
}
