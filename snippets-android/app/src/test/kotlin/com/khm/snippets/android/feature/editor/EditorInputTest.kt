package com.khm.snippets.android.feature.editor

import com.khm.snippets.android.R
import com.khm.snippets.android.data.KeywordAdvice
import com.khm.snippets.android.feature.shared.UiText
import com.khm.snippets.android.feature.shared.uiText
import com.khm.snippets.android.ui.model.TagUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorInputTest {
    @Test
    fun aSpaceTypedAtTheEndAsksForCompletion() {
        assertEquals(EditorInput.KeywordEdit.CompleteAtEnd, EditorInput.keywordEdit("git", "git "))
    }

    @Test
    fun aSpaceTypedElsewhereDoesNothing() {
        assertEquals(EditorInput.KeywordEdit.Ignore, EditorInput.keywordEdit("git", "g it"))
        // In an empty field the end is the only place: a space asks for completion there.
        assertEquals(EditorInput.KeywordEdit.CompleteAtEnd, EditorInput.keywordEdit("", "\t"))
    }

    @Test
    fun otherEditsAreSanitised() {
        assertEquals(EditorInput.KeywordEdit.Text("a-b-c"), EditorInput.keywordEdit("", "a b  c"))
        assertEquals(EditorInput.KeywordEdit.Text("sig"), EditorInput.keywordEdit("", "\\sig"))
        assertEquals(EditorInput.KeywordEdit.Text("sigx"), EditorInput.keywordEdit("sig", "sigx"))
        assertEquals(EditorInput.KeywordEdit.Text("si"), EditorInput.keywordEdit("sig", "si"))
    }

    @Test
    fun commasAndLineBreaksCommitTags() {
        assertEquals(EditorInput.TagInputEdit(emptyList(), "wor"), EditorInput.tagInputEdit("wor"))
        assertEquals(EditorInput.TagInputEdit(listOf("work"), ""), EditorInput.tagInputEdit("work,"))
        // Committed parts are raw; withTags trims and normalises them.
        assertEquals(EditorInput.TagInputEdit(listOf("a", " b"), "c"), EditorInput.tagInputEdit("a, b\nc"))
        assertEquals(EditorInput.TagInputEdit(listOf("a"), ""), EditorInput.tagInputEdit("a,,"))
    }

    @Test
    fun tagsAreNormalisedAndDeduplicatedKeepingTheFirstSpelling() {
        assertEquals(listOf("Café", "work"), EditorInput.withTags(listOf("Café"), listOf("cafe", "  work  ", "WORK")))
        assertEquals(listOf("a b"), EditorInput.withTags(emptyList(), listOf(" a   b ")))
        assertEquals(listOf("x"), EditorInput.withoutTag(listOf("Work", "x"), "work"))
    }

    @Test
    fun tagCompletionsArePrefixMatchesNotOnTheEntryAtMostEight() {
        val library = (1..10).map { TagUi("work$it", "work$it") } + TagUi("home", "home")
        val completions = EditorInput.tagCompletions("WO", library, listOf("work1"))
        assertEquals(8, completions.size)
        assertFalse(completions.any { it.folded == "work1" })
        assertTrue(EditorInput.tagCompletions("", library, emptyList()).isEmpty())
        assertEquals(listOf("home"), EditorInput.tagCompletions(" ho", library, emptyList()).map { it.name })
    }

    @Test
    fun keywordMessagesFollowTheTable() {
        assertNull(EditorInput.keywordMessage(KeywordAdvice.None))
        assertEquals(KeywordMessage(uiText(R.string.editor_keyword_missing), false), EditorInput.keywordMessage(KeywordAdvice.MissingKeyword))
        assertEquals(
            KeywordMessage(uiText(R.string.editor_keyword_disabled, "sig"), false),
            EditorInput.keywordMessage(KeywordAdvice.EntryDisabled("sig")),
        )
        assertEquals(
            KeywordMessage(uiText(R.string.editor_keyword_invalid, "a"), true),
            EditorInput.keywordMessage(KeywordAdvice.InvalidCharacters("a")),
        )
        assertEquals(
            KeywordMessage(uiText(R.string.editor_keyword_duplicate, "sig", "Mail"), true),
            EditorInput.keywordMessage(KeywordAdvice.Duplicate("sig", "Mail")),
        )
        assertEquals(
            KeywordMessage(uiText(R.string.editor_keyword_blocked, "sig", "sig-x"), true),
            EditorInput.keywordMessage(KeywordAdvice.BlockedByLonger("sig", "sig-x")),
        )
        assertEquals(
            KeywordMessage(uiText(R.string.editor_keyword_blocks, "si"), true),
            EditorInput.keywordMessage(KeywordAdvice.BlocksShorter("si")),
        )
    }

    @Test
    fun theNamePlaceholderNeverUsesASecureBody() {
        assertEquals(UiText.Raw("Hello"), EditorInput.namePlaceholder("\n  Hello  \nWorld", isSecure = false))
        assertEquals(uiText(R.string.library_row_untitled), EditorInput.namePlaceholder("Hello", isSecure = true))
        assertEquals(uiText(R.string.library_row_untitled), EditorInput.namePlaceholder("   ", isSecure = false))
        val long = "x".repeat(60)
        assertEquals(UiText.Raw("x".repeat(50) + "…"), EditorInput.namePlaceholder(long, isSecure = false))
    }

    @Test
    fun titleIsTheDisplayName() {
        assertEquals("Mail", EditorInput.title("  Mail ", "body", isSecure = false))
        assertEquals("body", EditorInput.title("", "body", isSecure = false))
        assertEquals("", EditorInput.title("", "body", isSecure = true))
        assertEquals("", EditorInput.title("", "", isSecure = false))
    }
}
