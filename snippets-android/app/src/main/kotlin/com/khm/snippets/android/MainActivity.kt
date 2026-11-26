package com.khm.snippets.android

import android.os.Bundle
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.Menu
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.fragment.app.FragmentActivity
import com.khm.snippets.android.app.AppContainer
import com.khm.snippets.android.app.LaunchOptionsReader
import com.khm.snippets.android.app.SnippetsApp
import com.khm.snippets.android.data.LibraryAvailability
import com.khm.snippets.android.platform.ScreenCaptureMonitor
import com.khm.snippets.android.platform.appShortcutFor
import com.khm.snippets.android.platform.keyboardShortcutGroup

/**
 * The one activity. A [FragmentActivity], which `BiometricPrompt` needs. It applies the launch
 * extras once per process, keeps the splash until the library reports, feeds the hardware
 * keyboard shortcuts and capture state to the UI, and tells the container when the app leaves
 * the foreground.
 */
class MainActivity : FragmentActivity() {
    private val container: AppContainer get() = (application as SnippetsApplication).container
    private lateinit var captureMonitor: ScreenCaptureMonitor

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        container.applyLaunchOptions(LaunchOptionsReader.read(intent))
        splash.setKeepOnScreenCondition { container.library.snapshot.value.availability == LibraryAvailability.Loading }
        captureMonitor = ScreenCaptureMonitor(this, container.screenCapture)
        setContent { SnippetsApp(container) }
    }

    override fun onStart() {
        super.onStart()
        captureMonitor.start()
    }

    override fun onStop() {
        captureMonitor.stop()
        super.onStop()
        // A rotation is not leaving the app.
        if (!isChangingConfigurations) container.onAppBackgrounded()
    }

    override fun onProvideKeyboardShortcuts(data: MutableList<KeyboardShortcutGroup>, menu: Menu?, deviceId: Int) {
        super.onProvideKeyboardShortcuts(data, menu, deviceId)
        data += keyboardShortcutGroup(this)
    }

    /** A key press no view consumed may be an app shortcut (screens-library-editor.md §8). */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (event.repeatCount == 0) {
            val shortcut = appShortcutFor(keyCode, ctrl = event.isCtrlPressed, shift = event.isShiftPressed)
            if (shortcut != null && container.shortcuts.dispatch(shortcut)) return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
