package com.khm.snippets.android.platform

import android.view.Window
import android.view.WindowManager
import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import java.util.WeakHashMap

/**
 * Keeps `FLAG_SECURE` on the activity window while [active] is true (DESIGN.md §11): the window
 * is then absent from screenshots, recordings, casting and the Recents preview.
 *
 * Compose it next to whatever can show secret material. Requests are counted per window, so the
 * flag clears only when no composable asks for it any more.
 */
@Composable
fun SecureWindowEffect(active: Boolean) {
    val window = LocalActivity.current?.window ?: return
    DisposableEffect(window, active) {
        if (active) SecureWindowFlag.acquire(window)
        onDispose {
            if (active) SecureWindowFlag.release(window)
        }
    }
}

/** Counts the requests for `FLAG_SECURE` per window. Main thread only. */
internal object SecureWindowFlag {
    private val requests = WeakHashMap<Window, Int>()

    fun acquire(window: Window) {
        val count = (requests[window] ?: 0) + 1
        requests[window] = count
        if (count == 1) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    fun release(window: Window) {
        val count = (requests[window] ?: 0) - 1
        if (count <= 0) {
            requests.remove(window)
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            requests[window] = count
        }
    }
}
