package com.khm.snippets.android.platform

import android.app.Activity
import android.os.Build
import android.view.Display
import android.view.WindowManager
import androidx.annotation.RequiresApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.function.Consumer

/** Why a revealed secure body must stay hidden although it was authenticated. */
enum class CaptureRisk { None, ScreenRecording, UnprotectedDisplay }

/**
 * What the activity knows about capture of its window (screens-secure.md §3.4): API 35+ reports
 * a recording of the window; any API level can tell whether the display it is on can show
 * protected content. The secure body panel reads [risk].
 */
class ScreenCaptureState {
    private val current = MutableStateFlow(CaptureRisk.None)

    val risk: StateFlow<CaptureRisk> = current.asStateFlow()

    fun update(recording: Boolean, displayIsSecure: Boolean) {
        current.value = when {
            recording -> CaptureRisk.ScreenRecording
            !displayIsSecure -> CaptureRisk.UnprotectedDisplay
            else -> CaptureRisk.None
        }
    }
}

/**
 * Feeds [ScreenCaptureState] from an activity between `onStart` and `onStop`. Needs the
 * `DETECT_SCREEN_RECORDING` permission on API 35+.
 */
class ScreenCaptureMonitor(private val activity: Activity, private val state: ScreenCaptureState) {
    private var recording = false
    private var callback: Consumer<Int>? = null

    fun start() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) startRecordingCallback()
        publish()
    }

    fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) stopRecordingCallback()
    }

    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    private fun startRecordingCallback() {
        val consumer = Consumer<Int> { visibility ->
            recording = visibility == WindowManager.SCREEN_RECORDING_STATE_VISIBLE
            publish()
        }
        val initial = activity.windowManager.addScreenRecordingCallback(activity.mainExecutor, consumer)
        recording = initial == WindowManager.SCREEN_RECORDING_STATE_VISIBLE
        callback = consumer
    }

    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    private fun stopRecordingCallback() {
        callback?.let(activity.windowManager::removeScreenRecordingCallback)
        callback = null
    }

    private fun publish() {
        val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay
        }
        state.update(recording = recording, displayIsSecure = display == null || display.flags and Display.FLAG_SECURE != 0)
    }
}
