package com.khm.snippets.android.feature.shared

import com.khm.snippets.android.data.PendingRecoveryKey
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Why the recovery key is on screen (`secure/recovery-key?mode=…`). */
enum class RecoveryKeyMode { Setup, Add }

/** A recovery key waiting for the user's acknowledgement. Never saved: it dies with the process. */
class RecoveryKeyRequest internal constructor(
    val key: PendingRecoveryKey,
    val mode: RecoveryKeyMode,
    private val answer: CompletableDeferred<Boolean>,
) {
    /** `I’ve Saved It`. */
    fun acknowledge() {
        answer.complete(true)
    }

    /** `X` or back: nothing is stored. */
    fun cancel() {
        answer.complete(false)
    }
}

/**
 * Shows a recovery key once (components.md §14). The key lives in this application-scoped
 * holder only while its screen is up: it is never part of the back stack or of saved state, so
 * after process death the screen is simply gone and nothing was changed.
 */
class RecoveryKeyPresenter {
    private val current = MutableStateFlow<RecoveryKeyRequest?>(null)

    /** The secret screen to show, or null. The app shell draws it over everything else. */
    val request: StateFlow<RecoveryKeyRequest?> = current.asStateFlow()

    /** Shows [key] and suspends until the user acknowledges (true) or cancels (false). */
    suspend fun present(key: PendingRecoveryKey, mode: RecoveryKeyMode): Boolean {
        val answer = CompletableDeferred<Boolean>()
        val request = RecoveryKeyRequest(key, mode, answer)
        current.value = request
        try {
            return answer.await()
        } finally {
            current.compareAndSet(request, null)
        }
    }
}
