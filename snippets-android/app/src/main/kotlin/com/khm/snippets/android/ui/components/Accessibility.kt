package com.khm.snippets.android.ui.components

import android.content.Context
import android.view.View
import android.view.accessibility.AccessibilityManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView

/** Speaks one-off messages that have no node of their own (`Copied “name”.`). */
@Stable
class Announcer internal constructor(private val view: View) {
    /** Polite announcement; does nothing when no accessibility service is listening. */
    fun announce(message: String) {
        if (message.isBlank()) return
        // The message belongs to a state that has no node to mark as a live region.
        @Suppress("DEPRECATION")
        view.announceForAccessibility(message)
    }
}

@Composable
fun rememberAnnouncer(): Announcer {
    val view = LocalView.current
    return remember(view) { Announcer(view) }
}

/** True while touch exploration (TalkBack) is on. Row swipes are off then. */
@Composable
fun rememberTouchExplorationEnabled(): Boolean {
    val context = LocalContext.current
    val manager = remember(context) {
        context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
    }
    var enabled by remember(manager) { mutableStateOf(manager?.isTouchExplorationEnabled == true) }
    DisposableEffect(manager) {
        val listener = AccessibilityManager.TouchExplorationStateChangeListener { enabled = it }
        manager?.addTouchExplorationStateChangeListener(listener)
        onDispose { manager?.removeTouchExplorationStateChangeListener(listener) }
    }
    return enabled
}
