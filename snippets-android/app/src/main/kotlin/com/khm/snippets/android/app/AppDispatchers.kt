package com.khm.snippets.android.app

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * The dispatchers the app injects instead of naming `Dispatchers.*` in place, so tests can run
 * everything on one test dispatcher.
 *
 * @param main The UI thread, immediate: work started from an event runs before the next frame.
 * @param default CPU work: search, row mapping, projections.
 */
class AppDispatchers(
    val main: CoroutineDispatcher = Dispatchers.Main.immediate,
    val default: CoroutineDispatcher = Dispatchers.Default,
)
