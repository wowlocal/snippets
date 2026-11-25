package com.khm.snippets.android.ui.theme

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext

/**
 * Motion tokens (DESIGN.md §9). The scheme is `MotionScheme.standard()`, which is what
 * `MaterialTheme` provides by default; these are the M3 duration and easing tokens the spec
 * names, plus the component timings built from them.
 */
object Motion {
    const val DURATION_SHORT_2 = 100
    const val DURATION_SHORT_4 = 200
    const val DURATION_MEDIUM_2 = 300
    const val DURATION_MEDIUM_4 = 400

    val EasingStandard: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
    val EasingEmphasized: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
    val EasingEmphasizedDecelerate: Easing = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)
    val EasingEmphasizedAccelerate: Easing = CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)

    /** Row `Copied` state: 100 ms in, hold 1500 ms, 300 ms out. */
    const val COPIED_IN = DURATION_SHORT_2
    const val COPIED_HOLD = 1_500
    const val COPIED_OUT = DURATION_MEDIUM_2

    /** Swipe background icon, 1.0 to [SWIPE_ARMED_SCALE] when armed. */
    const val SWIPE_ARM = DURATION_SHORT_2
    const val SWIPE_ARMED_SCALE = 1.15f

    /** Disclosures (`Details`, `Preview Placeholders`). */
    const val DISCLOSURE = DURATION_SHORT_4

    /** Progress step icon cross-fade. */
    const val STEP_ICON = DURATION_SHORT_2

    /** Full-screen dialog (compact): slide up and fade in, reverse out. */
    const val FULL_SCREEN_DIALOG_IN = DURATION_MEDIUM_4
    const val FULL_SCREEN_DIALOG_OUT = DURATION_SHORT_4

    /** Settings search-result highlight: hold, then fade. */
    const val HIGHLIGHT_HOLD = 400
    const val HIGHLIGHT_FADE = 300

    /** What slides and scales become under reduced motion. */
    const val REDUCED_FADE = DURATION_SHORT_2

    /** Secure-copy countdown: lifetime of the clip, and how long `Clipboard cleared.` stays. */
    const val COUNTDOWN_CLEARED_HOLD = 3_000
}

/**
 * True when the system animator duration scale is 0. Slides and scales then become short fades
 * or cuts; informational motion (the countdown bar) continues.
 */
val LocalReducedMotion = staticCompositionLocalOf { false }

/** Reads `Settings.Global.ANIMATOR_DURATION_SCALE` and follows its changes. */
@Composable
internal fun rememberReducedMotion(): Boolean {
    val resolver = LocalContext.current.applicationContext.contentResolver
    fun read(): Boolean = Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    var reduced by remember(resolver) { mutableStateOf(read()) }
    DisposableEffect(resolver) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                reduced = read()
            }
        }
        resolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
            false,
            observer,
        )
        onDispose { resolver.unregisterContentObserver(observer) }
    }
    return reduced
}
