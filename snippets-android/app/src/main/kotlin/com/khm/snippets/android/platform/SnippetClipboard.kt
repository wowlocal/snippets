package com.khm.snippets.android.platform

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle

/** Identifies a clip this app wrote, without keeping its text. */
data class ClipToken(val timestamp: Long)

/** Whether the primary clip is still the one a [ClipToken] names. */
enum class ClipOwnership {
    Ours,

    /** Readable, and another clip took its place: leave it alone. */
    Replaced,

    /** The clipboard cannot be read now (the app is in the background): clear anyway. */
    Unknown,
}

/**
 * The system clipboard, reduced to what the app does with it. Reads happen only on an explicit
 * user action (DESIGN.md D39); every clip is labelled `Snippets`, never with a snippet's name.
 */
interface SnippetClipboard {
    /** The text of the primary clip, or null when there is none or it cannot be read. */
    fun readText(): String?

    /** Writes [text]. [sensitive] sets `EXTRA_IS_SENSITIVE`, which masks the system overlay. */
    fun write(text: String, sensitive: Boolean): ClipToken

    fun ownership(token: ClipToken): ClipOwnership

    fun clear()

    /** Calls [listener] whenever the primary clip changes. Close the handle to stop. */
    fun addChangeListener(listener: () -> Unit): AutoCloseable
}

class AndroidSnippetClipboard(context: Context) : SnippetClipboard {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(ClipboardManager::class.java)

    override fun readText(): String? = try {
        val clip = manager.primaryClip
        if (clip == null || clip.itemCount == 0) {
            null
        } else {
            clip.getItemAt(0).coerceToText(appContext)?.toString()?.takeIf { it.isNotEmpty() }
        }
    } catch (_: SecurityException) {
        null
    }

    override fun write(text: String, sensitive: Boolean): ClipToken {
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        if (sensitive) {
            clip.description.extras = PersistableBundle().apply { putBoolean(EXTRA_IS_SENSITIVE, true) }
        }
        manager.setPrimaryClip(clip)
        return ClipToken(currentTimestamp() ?: NO_TIMESTAMP)
    }

    override fun ownership(token: ClipToken): ClipOwnership {
        val timestamp = currentTimestamp() ?: return ClipOwnership.Unknown
        if (token.timestamp == NO_TIMESTAMP) return ClipOwnership.Unknown
        return if (timestamp == token.timestamp) ClipOwnership.Ours else ClipOwnership.Replaced
    }

    override fun clear() {
        try {
            manager.clearPrimaryClip()
        } catch (_: SecurityException) {
            // Some devices refuse a clear from the background; the next foreground clear succeeds.
        }
    }

    override fun addChangeListener(listener: () -> Unit): AutoCloseable {
        val platformListener = ClipboardManager.OnPrimaryClipChangedListener { listener() }
        manager.addPrimaryClipChangedListener(platformListener)
        return AutoCloseable { manager.removePrimaryClipChangedListener(platformListener) }
    }

    private fun currentTimestamp(): Long? = try {
        manager.primaryClipDescription?.timestamp
    } catch (_: SecurityException) {
        null
    }

    private companion object {
        const val CLIP_LABEL = "Snippets"
        const val NO_TIMESTAMP = -1L

        /** `ClipDescription.EXTRA_IS_SENSITIVE`; the platform honours the literal before API 33. */
        val EXTRA_IS_SENSITIVE: String =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE"
    }
}
