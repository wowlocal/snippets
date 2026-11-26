package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.ExistingKeywords
import com.khm.snippets.android.data.KeywordAdvice
import com.khm.snippets.android.data.KeywordAdvisor
import com.khm.snippets.android.data.KeywordDraft
import com.khm.snippets.android.data.LibraryEntry
import com.khm.snippets.android.data.LibrarySnapshot
import com.khm.snippets.core.assist.KeywordSuggestions
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.text.FoundationText
import java.util.UUID
import com.khm.snippets.core.assist.KeywordAdvice as CoreAdvice

/**
 * [KeywordAdvisor] on `core.assist`: the warnings and suggestions of the iOS editors, the
 * ranked existing-keyword references and the shell-style completion.
 */
class CoreKeywordAdvisor : KeywordAdvisor {
    override fun advice(draft: KeywordDraft, snapshot: LibrarySnapshot): KeywordAdvice {
        val edited = Snippet(id = draft.entryId, name = draft.name, keyword = draft.keyword, content = "", isEnabled = draft.isEnabled)
        val keyword = edited.normalizedKeyword
        return when (val warning = CoreAdvice.warning(edited, enabledOthersInEngineOrder(draft.entryId, snapshot))) {
            null -> KeywordAdvice.None
            CoreAdvice.Warning.MissingKeyword -> KeywordAdvice.MissingKeyword
            CoreAdvice.Warning.Disabled -> KeywordAdvice.EntryDisabled(keyword)
            CoreAdvice.Warning.UnsupportedCharacters -> KeywordAdvice.InvalidCharacters(keyword)
            is CoreAdvice.Warning.Duplicate -> KeywordAdvice.Duplicate(keyword, nameOf(warning.other, snapshot))
            is CoreAdvice.Warning.BlockedByLonger -> KeywordAdvice.BlockedByLonger(keyword, warning.other.normalizedKeyword)
            is CoreAdvice.Warning.BlocksShorter -> KeywordAdvice.BlocksShorter(warning.other.normalizedKeyword)
        }
    }

    override fun suggestions(draft: KeywordDraft, snapshot: LibrarySnapshot): List<String> {
        val enabled = snapshot.entries.filter { it.id != draft.entryId && it.snippet.isEnabled }.map { it.keyword }
        return CoreAdvice.suggestions(draft.name, draft.contentFirstLine, enabled)
    }

    override fun existingMatches(query: String, entryId: UUID, snapshot: LibrarySnapshot): ExistingKeywords {
        val matches = KeywordSuggestions.existingMatches(query, otherKeywords(entryId, snapshot))
        return if (matches.isEmpty()) {
            ExistingKeywords.None
        } else {
            ExistingKeywords(matches.take(MAX_EXISTING), (matches.size - MAX_EXISTING).coerceAtLeast(0))
        }
    }

    override fun completion(query: String, entryId: UUID, snapshot: LibrarySnapshot): String? =
        KeywordSuggestions.tabCompletion(query, otherKeywords(entryId, snapshot))

    private fun otherKeywords(entryId: UUID, snapshot: LibrarySnapshot): List<String> =
        snapshot.entries.filter { it.id != entryId && it.keyword.isNotEmpty() }.map { it.keyword }

    /**
     * The order `KeywordAdvice.warning` expects: enabled ordinary entries, longest keyword first
     * (in `Character`s), then the most recently updated; then the enabled secure shells.
     */
    private fun enabledOthersInEngineOrder(entryId: UUID, snapshot: LibrarySnapshot): List<Snippet> {
        val enabled = snapshot.entries.filter { it.id != entryId && it.snippet.isEnabled }
        val ordinary = enabled.filterNot(LibraryEntry::isSecure)
            .filter { it.keyword.isNotEmpty() }
            .sortedWith(
                compareByDescending<LibraryEntry> { FoundationText.characterCount(it.keyword) }
                    .thenByDescending { it.snippet.updatedAt },
            )
        return (ordinary + enabled.filter(LibraryEntry::isSecure)).map(LibraryEntry::snippet)
    }

    /** The other entry's display name; a secure shell never contributes its body. */
    private fun nameOf(other: Snippet, snapshot: LibrarySnapshot): String =
        snapshot.entry(other.id)?.displayName ?: other.displayName

    private companion object {
        const val MAX_EXISTING = 8
    }
}
