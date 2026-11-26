package com.khm.snippets.android.feature.shared

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.withContext

/**
 * One-shot effects of a ViewModel: things that happen once and are not state (navigate, show a
 * snackbar, perform a haptic, move focus). The ViewModel [send]s; exactly one collector, the
 * screen, handles each effect once through [CollectEffects]. Effects sent while no screen is
 * collecting (rotation) wait in the buffer.
 */
class EffectChannel<E> {
    private val channel = Channel<E>(Channel.BUFFERED)

    val flow: Flow<E> = channel.receiveAsFlow()

    fun send(effect: E) {
        channel.trySend(effect)
    }
}

/**
 * Handles the effects of a ViewModel while the screen is at least started. [handler] runs on
 * the main thread, immediately, so an effect is not lost between a state change and a stop.
 */
@Composable
fun <E> CollectEffects(effects: Flow<E>, handler: suspend (E) -> Unit) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentHandler by rememberUpdatedState(handler)
    LaunchedEffect(effects, lifecycleOwner) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
            withContext(Dispatchers.Main.immediate) {
                effects.collect { currentHandler(it) }
            }
        }
    }
}
