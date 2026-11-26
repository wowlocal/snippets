package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.TextRange
import com.khm.snippets.android.testing.resolver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreSnippetResolverTest {
    private val resolver = resolver()

    @Test
    fun candidatesFollowTheGrammar() {
        assertEquals(listOf(TextRange(2, 8), TextRange(11, 14)), CoreSnippetResolver.candidates("a {date} {x{y} {b\n}"))
        assertTrue(CoreSnippetResolver.candidates("no braces").isEmpty())
        assertTrue(CoreSnippetResolver.candidates("{unterminated").isEmpty())
    }

    @Test
    fun placeholderRangesKeepOnlyResolvableCandidates() {
        val template = "x {date} {nope} {clipboard}"
        assertEquals(listOf(TextRange(2, 8), TextRange(16, 27)), resolver.placeholderRanges(template))
    }

    @Test
    fun usesClipboardOnlyForTheClipboardPlaceholder() {
        assertTrue(resolver.usesClipboard("Hi {clipboard}"))
        assertFalse(resolver.usesClipboard("Hi {date}"))
    }

    @Test
    fun resolveInsertsTheClipboardAndTheDate() {
        assertEquals("Hi you!", resolver.resolve("Hi {clipboard}!", "you"))
        assertEquals("Hi !", resolver.resolve("Hi {clipboard}!", null))
        assertEquals("2026-01-31", resolver.resolve("{date:yyyy-MM-dd}", null))
    }

    @Test
    fun insertedTextIsNotScannedAgain() {
        assertEquals("{date}", resolver.resolve("{clipboard}", "{date}"))
    }

    @Test
    fun previewUsesTheStandIn() {
        assertEquals("[Clipboard content] 2026", resolver.preview("{clipboard} {date:yyyy}", "[Clipboard content]"))
    }
}
