package com.khm.snippets.android.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback

/**
 * The events that produce haptics (DESIGN.md §10). A cancelled authentication, a clipboard
 * cleared by its timer and background sync changes produce none, so they have no entry.
 */
enum class SnippetsHaptic {
    /** An ordinary or secure copy succeeded. */
    CopySucceeded,

    /** Nothing to copy; authentication failed or is locked out. */
    Rejected,

    /** A long-press opened the row menu. */
    RowMenuOpened,

    /** A swipe crossed the commit threshold. */
    SwipeArmed,

    /** A swipe fell back under the threshold. */
    SwipeDisarmed,

    /** Pin, or a switch turned on (`Enabled`, `Secure`, sync, appearance). */
    ToggledOn,

    /** Unpin, or a switch turned off. */
    ToggledOff,

    /** An ordinary delete, or a secure delete after its confirmation. */
    Deleted,

    /** A tag filter chip was toggled. */
    TagFilterToggled,

    /** `Copy` on a secret block. */
    SecretCopied,

    /** A submit failed validation (wrong code, password mismatch). */
    ValidationFailed,
}

/** The platform constant for [haptic]. Unavailable constants fall back inside Compose. */
fun hapticFeedbackTypeOf(haptic: SnippetsHaptic): HapticFeedbackType = when (haptic) {
    SnippetsHaptic.CopySucceeded -> HapticFeedbackType.Confirm
    SnippetsHaptic.Rejected -> HapticFeedbackType.Reject
    SnippetsHaptic.RowMenuOpened -> HapticFeedbackType.LongPress
    SnippetsHaptic.SwipeArmed -> HapticFeedbackType.GestureThresholdActivate
    SnippetsHaptic.SwipeDisarmed -> HapticFeedbackType.SegmentTick
    SnippetsHaptic.ToggledOn -> HapticFeedbackType.ToggleOn
    SnippetsHaptic.ToggledOff -> HapticFeedbackType.ToggleOff
    SnippetsHaptic.Deleted -> HapticFeedbackType.Confirm
    SnippetsHaptic.TagFilterToggled -> HapticFeedbackType.SegmentTick
    SnippetsHaptic.SecretCopied -> HapticFeedbackType.Confirm
    SnippetsHaptic.ValidationFailed -> HapticFeedbackType.Reject
}

/** Performs app haptics through `LocalHapticFeedback`, which follows the system setting. */
@Stable
class SnippetsHaptics internal constructor(private val feedback: HapticFeedback) {
    fun perform(haptic: SnippetsHaptic) {
        feedback.performHapticFeedback(hapticFeedbackTypeOf(haptic))
    }

    /** [SnippetsHaptic.ToggledOn] or [SnippetsHaptic.ToggledOff] for the new state [on]. */
    fun toggle(on: Boolean) {
        perform(if (on) SnippetsHaptic.ToggledOn else SnippetsHaptic.ToggledOff)
    }
}

@Composable
fun rememberSnippetsHaptics(): SnippetsHaptics {
    val feedback = LocalHapticFeedback.current
    return remember(feedback) { SnippetsHaptics(feedback) }
}
