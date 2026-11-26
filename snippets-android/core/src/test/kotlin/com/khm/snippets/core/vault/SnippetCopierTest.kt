package com.khm.snippets.core.vault

import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.placeholders.JvmDateRenderer
import com.khm.snippets.core.placeholders.PlaceholderResolver
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.time.ZoneOffset
import java.util.Locale
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Copying: the secure parts of `snippets-ios-tests/SnippetsIOSTests.swift` (Swift names
 * kept) against [SnippetCopier], with a real vault underneath instead of Swift's
 * content-loader stub.
 */
class SnippetCopierTest {

    private class TestClipboard(var text: String? = null) : SecureClipboard {
        var ordinaryWrites = 0
        var secureWrites = 0
        var lifetimeMillis: Long? = null

        override fun currentText(): String? = text

        override fun writeOrdinaryText(text: String) {
            ordinaryWrites += 1
            this.text = text
        }

        override fun writeSecureText(text: String, lifetimeMillis: Long) {
            secureWrites += 1
            this.lifetimeMillis = lifetimeMillis
            this.text = text
        }
    }

    private val placeholders = PlaceholderResolver(JvmDateRenderer(Locale.US, ZoneOffset.UTC))

    private fun withCopier(label: String, clipboard: TestClipboard, block: suspend (Components, SnippetCopier) -> Unit) = runTest {
        val components = Components(label)
        try {
            block(components, SnippetCopier(components.store, placeholders, clipboard) { components.now })
        } finally {
            components.destroy()
        }
    }

    private suspend fun Components.addSecure(name: String, keyword: String, body: String): Snippet {
        if (!store.hasVault) createVault()
        session.unlock(reveal).fill(0)
        val id = store.addSecure(name, keyword, body.toByteArray(), emptyList(), true, false)
        session.lock()
        return store.shells.single { it.id == id }
    }

    /** `testPhoneOrdinaryCopyResolvesClipboardAndNeverClearsItForEmptyContent` */
    @Test fun testPhoneOrdinaryCopyResolvesClipboardAndNeverClearsItForEmptyContent() {
        val clipboard = TestClipboard("source")
        withCopier("ordinary", clipboard) { c, copier ->
            val greeting = Snippet(id(1), "Greeting", "", "Hello {clipboard}", emptyList(), true, false, at(1.0), at(1.0))
            val copied = assertIs<SnippetCopier.Result.Copied>(copier.copy(greeting))
            assertEquals("Greeting", copied.name)
            assertEquals(false, copied.secure)
            assertEquals("Hello source", clipboard.text)
            assertEquals(0, c.owner.count.get(), "an ordinary copy asks nobody")

            val empty = Snippet(id(2), "Empty", "", "", emptyList(), true, false, at(1.0), at(1.0))
            clipboard.text = "keep me"
            assertEquals("Empty", assertIs<SnippetCopier.Result.Empty>(copier.copy(empty)).name)
            assertEquals("keep me", clipboard.text)
            assertEquals(1, clipboard.ordinaryWrites)
            assertEquals(0, clipboard.secureWrites)
        }
    }

    /** `testPhoneSecureCopyAuthenticatesEveryUseAndUsesLocalExpiringPasteboard` */
    @Test fun testPhoneSecureCopyAuthenticatesEveryUseAndUsesLocalExpiringPasteboard() {
        val clipboard = TestClipboard("clipboard")
        withCopier("secure", clipboard) { c, copier ->
            val shell = c.addSecure("Token", "token", "secret-{clipboard}")
            val promptsBefore = c.owner.count.get()
            c.session.unlock(c.reveal).fill(0)
            assertTrue(c.session.isUnlocked, "an open reveal session does not excuse the prompt")

            val copied = assertIs<SnippetCopier.Result.Copied>(copier.copy(shell))
            assertEquals("Token", copied.name)
            assertTrue(copied.secure)
            assertEquals("secret-clipboard", clipboard.text)
            assertEquals(SecureClipboardLifetimes.SECURE_SNIPPET_MILLIS, clipboard.lifetimeMillis)
            assertEquals(60_000L, clipboard.lifetimeMillis)
            assertEquals(1, clipboard.secureWrites)
            assertEquals(0, clipboard.ordinaryWrites)
            assertEquals(VaultAuthenticationReason.Copy("Token").text, c.owner.reasons.last().text)
            assertEquals("Copy Token", c.owner.reasons.last().text)
            assertEquals(VaultSession.State.LOCKED, c.session.state.value, "a copy leaves nothing open")

            copier.copy(shell)
            assertEquals(promptsBefore + 3, c.owner.count.get(), "every copy is a new disclosure")
            assertEquals(2, clipboard.secureWrites)
        }
    }

    @Test fun aSecureCopyThatResolvesToNothingCopiesNothingAndADeclinedPromptCopiesNothing() {
        val clipboard = TestClipboard(null)
        withCopier("secure-empty", clipboard) { c, copier ->
            val empty = c.addSecure("Only clipboard", "onlyclip", "{clipboard}")
            assertEquals("Only clipboard", assertIs<SnippetCopier.Result.Empty>(copier.copy(empty)).name)
            assertNull(clipboard.text)

            val token = c.addSecure("Token", "token", "secret")
            c.owner.result = VaultAuthenticationResult.CANCELLED
            val failure = assertFailsWith<VaultSession.Failure.Authentication> { copier.copy(token) }
            assertEquals(VaultAuthenticationResult.CANCELLED, failure.result)
            assertEquals(0, clipboard.secureWrites + clipboard.ordinaryWrites)
            assertEquals(VaultSession.State.LOCKED, c.session.state.value)

            // A secure shell whose record has gone is not copied as an empty ordinary snippet.
            c.owner.result = VaultAuthenticationResult.SUCCESS
            c.store.delete(token.id)
            val ordinaryNow = copier.copy(token)
            assertIs<SnippetCopier.Result.Empty>(ordinaryNow, "a shell has no content of its own to leak")
            assertEquals(0, clipboard.secureWrites + clipboard.ordinaryWrites)
        }
    }
}
