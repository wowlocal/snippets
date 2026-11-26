package com.khm.snippets.android.platform

import android.content.Context
import android.content.Intent

/** The Android Sharesheet for plain text. */
interface ShareSheet {
    /** @param title Shown as the preview title (`EXTRA_TITLE`), or null. */
    fun shareText(text: String, title: String?)
}

class AndroidShareSheet(context: Context) : ShareSheet {
    private val appContext = context.applicationContext

    override fun shareText(text: String, title: String?) {
        val send = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_TEXT, text)
        if (title != null) send.putExtra(Intent.EXTRA_TITLE, title)
        // The system default chooser title is kept (screens-system.md §10).
        appContext.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
