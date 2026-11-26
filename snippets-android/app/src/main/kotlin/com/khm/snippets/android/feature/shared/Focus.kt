package com.khm.snippets.android.feature.shared

import androidx.compose.ui.focus.FocusRequester

/**
 * Requests focus when the requester is attached to a composed node; false otherwise. Keyboard
 * shortcuts and effects can arrive while the target is not on screen (another tab, an empty
 * list), and moving focus then must not throw.
 */
fun FocusRequester.requestFocusIfAttached(): Boolean = try {
    requestFocus()
} catch (_: IllegalStateException) {
    false
}
