package com.khm.snippets.android.platform

import com.khm.snippets.android.data.MonotonicClock
import com.khm.snippets.android.ui.model.CountdownUi
import com.khm.snippets.android.ui.theme.Motion
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** What the app knows about the device that changes behaviour. */
class PlatformInfo(val sdkInt: Int = android.os.Build.VERSION.SDK_INT) {
    /** Android 13+ confirms every copy with its own overlay, so the app adds no snackbar. */
    val showsSystemCopyConfirmation: Boolean get() = sdkInt >= ANDROID_13

    private companion object {
        const val ANDROID_13 = 33
    }
}

/**
 * Everything the app copies goes through here. Application-scoped: the secure-copy countdown
 * survives navigation between the library and the editor and keeps running while the app is in
 * the background (components.md §10).
 *
 * @param clock `SystemClock.elapsedRealtime` in production: the countdown row and the
 *   [backstop] alarm measure deadlines on it.
 * @param scope Application scope; owns the clearing timers.
 * @param backstop Clears a clip whose timer died with the process.
 * @param secureClipLifetimeMillis 60 s; a UI test shortens it.
 */
class ClipboardService(
    private val clipboard: SnippetClipboard,
    private val clock: MonotonicClock,
    private val scope: CoroutineScope,
    private val backstop: ClipClearScheduler,
    private val platform: PlatformInfo = PlatformInfo(),
    @Volatile var secureClipLifetimeMillis: Long = CountdownUi.SECURE_CLIP_LIFETIME_MILLIS,
) {
    private val countdownState = MutableStateFlow<CountdownUi?>(null)
    private var secureToken: ClipToken? = null
    private var secureJob: Job? = null
    private var secretJob: Job? = null

    /** The countdown row to show, or null. Both the library and the editor draw it. */
    val countdown: StateFlow<CountdownUi?> = countdownState.asStateFlow()

    val showsSystemCopyConfirmation: Boolean get() = platform.showsSystemCopyConfirmation

    init {
        clipboard.addChangeListener {
            val token = secureToken
            if (token != null && clipboard.ownership(token) == ClipOwnership.Replaced) forgetSecureClip()
        }
    }

    /** The clipboard text, read now. Call only for an explicit user action. */
    fun readText(): String? = clipboard.readText()

    /** An ordinary copy. It replaces a secure clip, so a running countdown leaves silently. */
    fun copyOrdinary(text: String) {
        forgetSecureClip()
        clipboard.write(text, sensitive = false)
    }

    /** A secure body: sensitive clip, countdown row, cleared at the deadline. */
    fun copySecure(name: String, text: String) {
        forgetSecureClip()
        val lifetime = secureClipLifetimeMillis
        val token = clipboard.write(text, sensitive = true)
        val deadline = clock.nowMillis() + lifetime
        secureToken = token
        backstop.schedule(token, deadline)
        countdownState.value = CountdownUi.Running(name, deadlineMillis = deadline, totalMillis = lifetime)
        secureJob = scope.launch {
            delay(lifetime)
            finishSecureClip(token)
        }
    }

    /** Recovery material: sensitive clip, cleared after [lifetimeMillis], no countdown row. */
    fun copySecret(text: String, lifetimeMillis: Long) {
        forgetSecureClip()
        val token = clipboard.write(text, sensitive = true)
        backstop.schedule(token, clock.nowMillis() + lifetimeMillis)
        secretJob?.cancel()
        secretJob = scope.launch {
            delay(lifetimeMillis)
            clearUnlessReplaced(token)
            backstop.cancel()
        }
    }

    /** `Clear Now` on the countdown row. */
    fun clearSecureNow() {
        val token = secureToken ?: return
        secureJob?.cancel()
        secureJob = scope.launch { finishSecureClip(token) }
    }

    private suspend fun finishSecureClip(token: ClipToken) {
        secureToken = null
        backstop.cancel()
        if (!clearUnlessReplaced(token)) {
            countdownState.value = null
            return
        }
        countdownState.value = CountdownUi.Cleared
        delay(Motion.COUNTDOWN_CLEARED_HOLD.toLong())
        countdownState.value = null
    }

    /** False when another clip verifiably took ours: it is left alone. */
    private fun clearUnlessReplaced(token: ClipToken): Boolean {
        if (clipboard.ownership(token) == ClipOwnership.Replaced) return false
        clipboard.clear()
        return true
    }

    private fun forgetSecureClip() {
        if (secureToken != null) backstop.cancel()
        secureJob?.cancel()
        secureJob = null
        secureToken = null
        countdownState.value = null
    }
}
