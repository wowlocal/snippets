package com.khm.snippets.android.platform

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The backstop that clears a timed clip when the process is gone before its deadline
 * (DESIGN.md D40, screens-system.md §7). The application-scoped timer in [ClipboardService]
 * is the primary path; it cancels the alarm when it clears.
 */
interface ClipClearScheduler {
    /** Clears the clip [token] names at [atElapsedMillis] (`SystemClock.elapsedRealtime`). */
    fun schedule(token: ClipToken, atElapsedMillis: Long)

    fun cancel()
}

/** A one-shot inexact `AlarmManager` alarm; needs no exact-alarm permission. */
class AlarmClipClearScheduler(context: Context) : ClipClearScheduler {
    private val appContext = context.applicationContext
    private val alarms = appContext.getSystemService(AlarmManager::class.java)

    override fun schedule(token: ClipToken, atElapsedMillis: Long) {
        alarms.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, atElapsedMillis, pendingIntent(token))
    }

    override fun cancel() {
        alarms.cancel(pendingIntent(token = null))
    }

    private fun pendingIntent(token: ClipToken?): PendingIntent {
        val intent = Intent(appContext, ClipClearReceiver::class.java)
        if (token != null) intent.putExtra(ClipClearReceiver.EXTRA_TIMESTAMP, token.timestamp)
        return PendingIntent.getBroadcast(
            appContext,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private companion object {
        const val REQUEST_CODE = 1
    }
}

/**
 * Clears the clip the alarm was set for. When the clipboard cannot be read (the app is in the
 * background), ownership cannot be verified and the clip is cleared anyway.
 */
class ClipClearReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val clipboard = AndroidSnippetClipboard(context)
        val token = ClipToken(intent.getLongExtra(EXTRA_TIMESTAMP, NO_TIMESTAMP))
        if (clipboard.ownership(token) != ClipOwnership.Replaced) clipboard.clear()
    }

    companion object {
        const val EXTRA_TIMESTAMP = "clip-timestamp"
        private const val NO_TIMESTAMP = -1L
    }
}
