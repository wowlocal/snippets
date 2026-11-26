package com.khm.snippets.android.feature.editor

import com.khm.snippets.android.R
import com.khm.snippets.android.data.KeywordAdvice
import com.khm.snippets.android.feature.shared.UiText
import com.khm.snippets.android.feature.shared.uiText
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText

/** The editor's typing rules (screens-library-editor.md §6.5), as pure functions. */
object EditorInput {
    /** What an edit of the keyword field becomes. */
    sealed interface KeywordEdit {
        /** The text to show and store: the sanitised form of what was typed. */
        data class Text(val keyword: String) : KeywordEdit

        /** Space at the end: complete the next keyword part, if there is one. */
        data object CompleteAtEnd : KeywordEdit

        /** Space elsewhere: nothing happens. */
        data object Ignore : KeywordEdit
    }

    /**
     * Space never inserts a space: a single whitespace typed at the end asks for completion, one
     * typed elsewhere does nothing. Anything else is sanitised (trimmed, leading `\` removed,
     * whitespace runs become `-`), so pasted spaces become hyphens.
     */
    fun keywordEdit(old: String, new: String): KeywordEdit {
        val inserted = singleInsertion(old, new)
        if (inserted != null && FoundationText.isWhitespaceOrNewline(new[inserted].code)) {
            return if (inserted == old.length) KeywordEdit.CompleteAtEnd else KeywordEdit.Ignore
        }
        return KeywordEdit.Text(Snippet.sanitizedKeyword(new))
    }

    /** Index of the one character [new] adds to [old], or null when the edit is anything else. */
    private fun singleInsertion(old: String, new: String): Int? {
        if (new.length != old.length + 1) return null
        var index = 0
        while (index < old.length && old[index] == new[index]) index += 1
        return if (new.regionMatches(index + 1, old, index, old.length - index)) index else null
    }

    /** The result of an edit of the tag input. */
    data class TagInputEdit(val committed: List<String>, val pending: String)

    /** A comma or a line break commits what is before it; pasted lists become several tags. */
    fun tagInputEdit(text: String): TagInputEdit {
        if (text.none { it in TAG_SEPARATORS }) return TagInputEdit(emptyList(), text)
        val parts = text.split(*TAG_SEPARATORS)
        return TagInputEdit(parts.dropLast(1).filter { it.isNotBlank() }, parts.last())
    }

    /**
     * The tags after adding [added] to [current]: trimmed, inner whitespace collapsed, and
     * de-duplicated case- and diacritic-insensitively keeping the first spelling.
     */
    fun withTags(current: List<String>, added: List<String>): List<String> = SnippetTagging.normalizedTags(current + added)

    /** [current] without the tag whose folded key is [key]. */
    fun withoutTag(current: List<String>, key: String): List<String> = current.filterNot { SnippetTagging.filterKey(it) == key }

    /**
     * Up to eight library tags whose folded form starts with the typed text and that the entry
     * does not carry yet, alphabetical as the library lists them.
     */
    fun tagCompletions(input: String, libraryTags: List<TagUi>, entryTags: List<String>): List<TagUi> {
        val typed = SnippetTagging.filterKey(FoundationText.trimWhitespaceAndNewlines(input))
        if (typed.isEmpty()) return emptyList()
        val onEntry = entryTags.mapTo(HashSet(), SnippetTagging::filterKey)
        return libraryTags.filter { it.folded.startsWith(typed) && it.folded !in onEntry }.take(MAX_TAG_COMPLETIONS)
    }

    /** The keyword field's message (§6.5 table), or null when there is nothing to say. */
    fun keywordMessage(advice: KeywordAdvice): KeywordMessage? = when (advice) {
        KeywordAdvice.None -> null
        KeywordAdvice.MissingKeyword -> KeywordMessage(uiText(R.string.editor_keyword_missing), isWarning = false)
        is KeywordAdvice.EntryDisabled -> KeywordMessage(uiText(R.string.editor_keyword_disabled, advice.keyword), isWarning = false)
        is KeywordAdvice.InvalidCharacters -> KeywordMessage(uiText(R.string.editor_keyword_invalid, advice.keyword), isWarning = true)
        is KeywordAdvice.Duplicate -> KeywordMessage(uiText(R.string.editor_keyword_duplicate, advice.keyword, advice.otherName), isWarning = true)
        is KeywordAdvice.BlockedByLonger -> KeywordMessage(uiText(R.string.editor_keyword_blocked, advice.keyword, advice.longerKeyword), isWarning = true)
        is KeywordAdvice.BlocksShorter -> KeywordMessage(uiText(R.string.editor_keyword_blocks, advice.shorterKeyword), isWarning = true)
    }

    /**
     * The name field's placeholder: an unnamed ordinary entry with content shows its first
     * content line (cut to 50 characters); otherwise `Untitled Snippet`. A secure body is never
     * used.
     */
    fun namePlaceholder(content: String, isSecure: Boolean): UiText {
        val firstLine = if (isSecure) "" else Snippet(name = "", keyword = "", content = content).contentFirstLine
        return if (firstLine.isEmpty()) uiText(R.string.library_row_untitled) else UiText.Raw(firstLine)
    }

    /**
     * The top bar title: the trimmed name, else the first content line of an ordinary entry;
     * blank when both are missing (the screen then shows `Untitled Snippet`).
     */
    fun title(name: String, content: String, isSecure: Boolean): String {
        val trimmed = FoundationText.trimWhitespaceAndNewlines(name)
        if (trimmed.isNotEmpty() || isSecure) return trimmed
        return Snippet(name = "", keyword = "", content = content).contentFirstLine
    }

    private val TAG_SEPARATORS = charArrayOf(',', '\n', '\r')
    private const val MAX_TAG_COMPLETIONS = 8
}

/** A keyword message and its level: info is plain supporting text, a warning is coloured. */
data class KeywordMessage(val text: UiText, val isWarning: Boolean)
