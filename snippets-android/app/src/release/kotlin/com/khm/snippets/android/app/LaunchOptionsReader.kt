package com.khm.snippets.android.app

import android.content.Intent

/** Release builds ignore every launch extra: they start empty, with no demo content. */
object LaunchOptionsReader {
    @Suppress("UNUSED_PARAMETER")
    fun read(intent: Intent?): LaunchOptions = LaunchOptions.Default
}
