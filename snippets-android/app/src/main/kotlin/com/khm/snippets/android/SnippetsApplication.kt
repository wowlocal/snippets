package com.khm.snippets.android

import android.app.Application
import androidx.annotation.VisibleForTesting
import com.khm.snippets.android.app.AppContainer
import com.khm.snippets.core.text.FoundationTables
import kotlinx.coroutines.launch

/** Builds the [AppContainer] once per process and warms the text tables off the main thread. */
class SnippetsApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        // The fold and grapheme tables take a few milliseconds to parse; never on the main thread.
        container.appScope.launch(container.dispatchers.default) { FoundationTables.warmUp() }
    }

    /** Instrumented tests start each case from a fresh graph, configured before the activity launches. */
    @VisibleForTesting
    fun replaceContainer(replacement: AppContainer) {
        container = replacement
    }
}
