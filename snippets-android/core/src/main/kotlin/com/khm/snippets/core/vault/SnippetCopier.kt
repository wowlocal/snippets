package com.khm.snippets.core.vault

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.crypto.SnippetCrypto
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.placeholders.PlaceholderResolver
import kotlinx.coroutines.CancellationException

/**
 * The system clipboard as copying needs it. The app implements it on `ClipboardManager`.
 *
 * Android has no clip expiry and no "local only" flag (spec §7.4). A secure clip is one
 * plain-text item whose `ClipDescription` carries `EXTRA_IS_SENSITIVE`, which the app
 * removes again after the lifetime it is given. Whether it may clear a clip that is no
 * longer its own is owner decision Q8; this interface leaves that to the implementation.
 */
interface SecureClipboard {

    /** The clipboard's plain text now, for `{clipboard}`; `null` when there is none or it cannot be read. */
    fun currentText(): String?

    /** An ordinary clip. */
    fun writeOrdinaryText(text: String)

    /**
     * A secure clip: marked sensitive, removed after [lifetimeMillis]. [text] is the one
     * unwipeable `String` the copy has to make; keep no reference to it.
     */
    fun writeSecureText(text: String, lifetimeMillis: Long)
}

/** How long each kind of secret stays on the clipboard (Swift's constants). */
object SecureClipboardLifetimes {
    /** `SnippetActionService.secureClipboardLifetime`: a copied secure snippet. */
    const val SECURE_SNIPPET_MILLIS: Long = 60_000

    /** The vault recovery key shown at setup (`SecureUIKit.swift`). */
    const val VAULT_RECOVERY_KEY_MILLIS: Long = 5 * 60_000

    /** A Git library's recovery code (`GitSyncSettingsViewController.swift`). */
    const val GIT_RECOVERY_CODE_MILLIS: Long = 120_000
}

/**
 * Copying a snippet to the clipboard (`SnippetActionService.swift`, `copy`).
 *
 * - Ordinary: placeholders resolved, a plain clip, no prompt.
 * - Secure: a fresh device-owner authentication every time, even inside an open reveal
 *   session (which it ends, because a one-use authentication locks first and after).
 *   The body lives in a [SecurePlaintextLease] until the placeholders are resolved;
 *   the lease is wiped on every exit. An empty result copies nothing.
 *
 * @param now seconds since 2001, for date placeholders.
 */
class SnippetCopier(
    private val secureStore: SecureSnippetStore,
    private val placeholders: PlaceholderResolver,
    private val clipboard: SecureClipboard,
    private val now: () -> Double = AppleTime::now,
) {

    sealed class Result {
        /** The name to show; never log it for a secure snippet. */
        abstract val name: String

        /** Copied. The confirmation for a secure clip says it expires in 60 seconds. */
        class Copied(override val name: String, val secure: Boolean) : Result()

        /** The snippet resolved to nothing; the clipboard was not touched. */
        class Empty(override val name: String) : Result()

        final override fun toString(): String = javaClass.simpleName
    }

    /** The secure body is not valid UTF-8 (`invalidSecureContent`). Nothing was copied. */
    class InvalidSecureContent : Exception("the secure snippet does not contain valid text")

    /**
     * Copies [snippet], which for a secure snippet is its content-free shell.
     *
     * @throws VaultSession.Failure when the owner check did not succeed (a cancelled
     *   prompt is [VaultSession.Failure.Authentication] with `CANCELLED`, silent in the UI),
     *   or there is no key.
     * @throws SecureSnippetStore.Failure when the record is gone or the vault unreadable.
     * @throws SnippetCrypto.Failure when the sealed body does not open.
     */
    @Throws(
        VaultSession.Failure::class, SecureSnippetStore.Failure::class, SnippetCrypto.Failure::class,
        InvalidSecureContent::class, CancellationException::class,
    )
    suspend fun copy(snippet: Snippet): Result =
        if (secureStore.isSecure(snippet.id)) copySecure(snippet) else copyOrdinary(snippet)

    fun copyOrdinary(snippet: Snippet): Result {
        val text = placeholders.resolve(snippet.content, clipboard::currentText, now)
        if (text.isEmpty()) return Result.Empty(snippet.displayName)
        clipboard.writeOrdinaryText(text)
        return Result.Copied(snippet.displayName, secure = false)
    }

    private suspend fun copySecure(snippet: Snippet): Result {
        val name = snippet.displayName
        secureStore.leaseContent(snippet.id, VaultAuthenticationReason.Copy(name)).use { lease ->
            val template = lease.makeUtf8String() ?: throw InvalidSecureContent()
            val resolved = placeholders.resolve(template, clipboard::currentText, now)
            if (resolved.isEmpty()) return Result.Empty(name)
            clipboard.writeSecureText(resolved, SecureClipboardLifetimes.SECURE_SNIPPET_MILLIS)
            return Result.Copied(name, secure = true)
        }
    }
}
