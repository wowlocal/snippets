package com.khm.snippets.android.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.launch

/**
 * A click handler for Paste buttons. The clipboard is read only when the returned function is
 * called, never before (DESIGN.md D39); [onText] receives the text of the primary clip, or
 * nothing happens when the clipboard holds no text.
 */
@Composable
fun rememberClipboardPaste(onText: (String) -> Unit): () -> Unit {
    val clipboard = LocalClipboard.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val currentOnText by rememberUpdatedState(onText)
    return remember(clipboard, context, scope) {
        val paste: () -> Unit = {
            scope.launch {
                val clip = clipboard.getClipEntry()?.clipData ?: return@launch
                if (clip.itemCount == 0) return@launch
                val text = clip.getItemAt(0).coerceToText(context)?.toString()
                if (!text.isNullOrEmpty()) currentOnText(text)
            }
        }
        paste
    }
}
