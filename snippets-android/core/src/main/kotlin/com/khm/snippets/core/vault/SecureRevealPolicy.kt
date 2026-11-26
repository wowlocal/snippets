package com.khm.snippets.core.vault

/** What the editor must do to its text after a [SecureRevealPolicy] transition. */
enum class SecureRevealTransition { NONE, REVEAL, REDACT }

/**
 * Identifies one authentication request of one binding. A result that arrives for an
 * older token (the editor was rebound, locked, or asked again meanwhile) is discarded.
 */
class SecureRevealAuthenticationToken internal constructor(
    internal val bindingGeneration: Long,
    internal val requestGeneration: Long,
) {
    override fun equals(other: Any?): Boolean = other is SecureRevealAuthenticationToken &&
        bindingGeneration == other.bindingGeneration && requestGeneration == other.requestGeneration

    override fun hashCode(): Int = 31 * bindingGeneration.hashCode() + requestGeneration.hashCode()
}

/**
 * The fail-closed policy of one secure editor session (`SecureSnippetRevealPolicy` in
 * `snippets-ios/SecureSnippetReveal.swift`).
 *
 * Plaintext may be shown only while the app and its window are active, no screen capture
 * is active and the protected presentation is healthy; editing is allowed only in
 * [State.PROTECTED_PLAINTEXT]. Any loss of one of those redacts at once. Returning to the
 * foreground does not reveal again: the user asks, which costs no prompt while the
 * [VaultSession] is still open.
 *
 * On Android: "app and scene active" is the activity being resumed with window focus;
 * "capture inactive" and "renderer healthy" are the window carrying `FLAG_SECURE`
 * ([SecureCapturePresentationPolicy]).
 *
 * Mutable and not thread-safe: it belongs to the editor, on the main thread.
 */
class SecureRevealPolicy {

    enum class State {
        ORDINARY,
        LOCKED,
        AUTHENTICATING,
        AUTHENTICATED_REDACTED,
        PRESENTING_PLAINTEXT,
        PROTECTED_PLAINTEXT,
        FAILED_CLOSED,
    }

    var state: State = State.ORDINARY
        private set
    var bindingGeneration: Long = 0
        private set
    var appAndSceneAreActive: Boolean = false
        private set
    var sceneCaptureIsInactive: Boolean = false
        private set
    var rendererIsHealthy: Boolean = false
        private set

    private var authenticationRequestGeneration: Long = 0

    val isSecure: Boolean get() = state != State.ORDINARY
    val isProtectedPlaintext: Boolean get() = state == State.PROTECTED_PLAINTEXT
    val isAuthenticated: Boolean
        get() = state == State.AUTHENTICATED_REDACTED || state == State.PRESENTING_PLAINTEXT ||
            state == State.PROTECTED_PLAINTEXT
    val isAuthenticating: Boolean get() = state == State.AUTHENTICATING
    val isCaptureBlocked: Boolean get() = isSecure && !sceneCaptureIsInactive
    val permitsTextMutation: Boolean
        get() = state == State.PROTECTED_PLAINTEXT && environmentPermitsReveal

    private val environmentPermitsReveal: Boolean
        get() = appAndSceneAreActive && sceneCaptureIsInactive && rendererIsHealthy

    /** The editor now shows an ordinary snippet. */
    fun bindOrdinary() {
        bindingGeneration += 1
        authenticationRequestGeneration += 1
        rendererIsHealthy = false
        state = State.ORDINARY
    }

    /** The editor now shows a secure snippet, redacted. */
    fun bindSecure(rendererIsHealthy: Boolean, appAndSceneAreActive: Boolean, sceneCaptureIsInactive: Boolean) {
        bindingGeneration += 1
        authenticationRequestGeneration += 1
        this.rendererIsHealthy = rendererIsHealthy
        this.appAndSceneAreActive = appAndSceneAreActive
        this.sceneCaptureIsInactive = sceneCaptureIsInactive
        state = if (rendererIsHealthy) State.LOCKED else State.FAILED_CLOSED
    }

    /** `null` unless the editor is [State.LOCKED]. */
    fun beginAuthentication(): SecureRevealAuthenticationToken? {
        if (state != State.LOCKED) return null
        authenticationRequestGeneration += 1
        state = State.AUTHENTICATING
        return SecureRevealAuthenticationToken(bindingGeneration, authenticationRequestGeneration)
    }

    /** `false` when the result is stale and was ignored. */
    fun authenticationSucceeded(token: SecureRevealAuthenticationToken): Boolean {
        if (!isCurrent(token) || state != State.AUTHENTICATING) return false
        state = State.AUTHENTICATED_REDACTED
        return true
    }

    fun authenticationFailed(token: SecureRevealAuthenticationToken): Boolean {
        if (!isCurrent(token) || state != State.AUTHENTICATING) return false
        state = State.LOCKED
        return true
    }

    fun beginAuthenticatedReveal(): SecureRevealTransition =
        if (state == State.AUTHENTICATED_REDACTED && environmentPermitsReveal) {
            SecureRevealTransition.REVEAL
        } else {
            SecureRevealTransition.NONE
        }

    /** Called after the plaintext is in protected storage and before it can become visible. */
    fun beginPlaintextPresentation(): Boolean {
        if (state != State.AUTHENTICATED_REDACTED || !environmentPermitsReveal) return false
        state = State.PRESENTING_PLAINTEXT
        return true
    }

    /** Called when the protected presentation confirms the plaintext is on screen. */
    fun confirmProtectedPlaintext(): Boolean {
        if (state != State.PRESENTING_PLAINTEXT || !environmentPermitsReveal) return false
        state = State.PROTECTED_PLAINTEXT
        return true
    }

    @Suppress("UNUSED_PARAMETER")
    fun revealAttemptFailed(vaultIsStillUnlocked: Boolean) {
        if (state == State.ORDINARY || state == State.FAILED_CLOSED) return
        state = State.LOCKED
    }

    fun setAppAndSceneAreActive(active: Boolean): SecureRevealTransition {
        appAndSceneAreActive = active
        return if (active) SecureRevealTransition.NONE else plaintextToRedacted()
    }

    fun setSceneCaptureIsInactive(inactive: Boolean): SecureRevealTransition {
        sceneCaptureIsInactive = inactive
        return if (inactive) SecureRevealTransition.NONE else plaintextToRedacted()
    }

    fun cancelReveal(): SecureRevealTransition = plaintextToRedacted()

    fun rendererFailed(): SecureRevealTransition {
        if (state == State.ORDINARY) return SecureRevealTransition.NONE
        val needsRedaction = state == State.PRESENTING_PLAINTEXT || state == State.PROTECTED_PLAINTEXT
        rendererIsHealthy = false
        state = State.FAILED_CLOSED
        return if (needsRedaction) SecureRevealTransition.REDACT else SecureRevealTransition.NONE
    }

    /** The vault locked, the editor is leaving, or a modal is about to cover it. */
    fun lock(): SecureRevealTransition {
        if (state == State.ORDINARY) return SecureRevealTransition.NONE
        val needsRedaction = state == State.PRESENTING_PLAINTEXT || state == State.PROTECTED_PLAINTEXT
        bindingGeneration += 1
        authenticationRequestGeneration += 1
        state = if (rendererIsHealthy) State.LOCKED else State.FAILED_CLOSED
        return if (needsRedaction) SecureRevealTransition.REDACT else SecureRevealTransition.NONE
    }

    private fun isCurrent(token: SecureRevealAuthenticationToken): Boolean =
        token.bindingGeneration == bindingGeneration && token.requestGeneration == authenticationRequestGeneration

    private fun plaintextToRedacted(): SecureRevealTransition {
        if (state != State.PRESENTING_PLAINTEXT && state != State.PROTECTED_PLAINTEXT) return SecureRevealTransition.NONE
        state = State.AUTHENTICATED_REDACTED
        return SecureRevealTransition.REDACT
    }
}
