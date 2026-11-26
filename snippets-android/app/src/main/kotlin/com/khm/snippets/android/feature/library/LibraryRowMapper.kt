package com.khm.snippets.android.feature.library

import com.khm.snippets.android.data.LibraryEntry
import com.khm.snippets.android.data.QueryRow
import com.khm.snippets.android.data.TextRange
import com.khm.snippets.android.platform.TimeFormatter
import com.khm.snippets.android.ui.model.RowPreviewUi
import com.khm.snippets.android.ui.model.SnippetRowUi
import com.khm.snippets.android.ui.model.TagUi
import com.khm.snippets.android.ui.model.TextHighlight
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText

/**
 * Turns a query result row into the row the list draws (components.md §1.1, §1.2). Pure apart
 * from [time]; runs off the main thread.
 */
class LibraryRowMapper(private val time: TimeFormatter) {
    fun row(match: QueryRow): SnippetRowUi {
        val entry = match.entry
        val snippet = entry.snippet
        val (name, nameHighlights) = nameOf(entry, match.name)
        return SnippetRowUi(
            id = entry.id.toString(),
            name = name,
            time = time.rowTime(snippet.updatedAt),
            preview = previewOf(entry, match.content),
            keyword = entry.keyword.ifEmpty { null },
            tags = snippet.tags.map { tag ->
                val key = SnippetTagging.filterKey(tag)
                TagUi(name = tag, folded = key, highlights = match.tags[key].orEmpty().map(::highlight))
            },
            isSecure = entry.isSecure,
            isPinned = snippet.isPinned,
            isEnabled = snippet.isEnabled,
            nameHighlights = nameHighlights,
            keywordHighlights = match.keyword.map(::highlight),
        )
    }

    /** The trimmed name with its matches, else the first content line; blank shows `Untitled Snippet`. */
    private fun nameOf(entry: LibraryEntry, matches: List<TextRange>): Pair<String, List<TextHighlight>> {
        val raw = entry.snippet.name
        val trimmed = FoundationText.trimWhitespaceAndNewlines(raw)
        if (trimmed.isEmpty()) {
            // A secure shell has no content, so a secure body never supplies a name.
            return entry.snippet.contentFirstLine to emptyList()
        }
        val offset = raw.indexOf(trimmed)
        val highlights = matches.mapNotNull { range ->
            val start = (range.start - offset).coerceIn(0, trimmed.length)
            val end = (range.end - offset).coerceIn(0, trimmed.length)
            if (start < end) TextHighlight(start, end) else null
        }
        return trimmed to highlights
    }

    private fun previewOf(entry: LibraryEntry, contentMatch: TextRange?): RowPreviewUi {
        if (entry.isSecure) return RowPreviewUi.Secure
        val content = entry.snippet.content
        val firstLine = firstNonBlankLine(content)
            ?: return if (entry.keyword.isEmpty()) RowPreviewUi.NoContent else RowPreviewUi.None
        if (contentMatch == null || contentMatch.start in firstLine.start until firstLine.end) {
            val collapsed = collapse(content, firstLine.start, firstLine.end, contentMatch)
            return RowPreviewUi.Text(collapsed.text, collapsed.highlights)
        }
        // A hit below the first line: an excerpt of its line, from a little before the match.
        val line = lineAround(content, contentMatch.start)
        val start = maxOf(line.start, contentMatch.start - EXCERPT_LEAD)
        val collapsed = collapse(content, start, line.end, contentMatch)
        return RowPreviewUi.Text(collapsed.text, collapsed.highlights, isExcerpt = true)
    }

    private fun highlight(range: TextRange) = TextHighlight(range.start, range.end)

    private class Collapsed(val text: String, val highlights: List<TextHighlight>)

    /**
     * [text] from [start] to [end] with outer whitespace dropped and inner runs collapsed to one
     * space, cut to [MAX_PREVIEW_LENGTH]; [match] is carried over to the new indices.
     */
    private fun collapse(text: String, start: Int, end: Int, match: TextRange?): Collapsed {
        val out = StringBuilder()
        var matchStart = -1
        var matchEnd = -1
        var pendingSpace = false
        var index = start
        while (index < end && out.length < MAX_PREVIEW_LENGTH) {
            val char = text[index]
            if (FoundationText.isWhitespaceOrNewline(char.code)) {
                pendingSpace = out.isNotEmpty()
            } else {
                if (pendingSpace) out.append(' ')
                pendingSpace = false
                if (match != null && index >= match.start && index < match.end) {
                    if (matchStart < 0) matchStart = out.length
                    matchEnd = out.length + 1
                }
                out.append(char)
            }
            index += 1
        }
        val highlights = if (matchStart >= 0) listOf(TextHighlight(matchStart, matchEnd)) else emptyList()
        return Collapsed(out.toString(), highlights)
    }

    private fun firstNonBlankLine(content: String): TextRange? {
        var lineStart = 0
        for (index in 0..content.length) {
            if (index == content.length || FoundationText.isNewline(content[index].code)) {
                val isBlank = (lineStart until index).all { FoundationText.isWhitespaceOrNewline(content[it].code) }
                if (!isBlank) return TextRange(lineStart, index)
                lineStart = index + 1
            }
        }
        return null
    }

    private fun lineAround(content: String, position: Int): TextRange {
        var start = position.coerceIn(0, content.length)
        while (start > 0 && !FoundationText.isNewline(content[start - 1].code)) start -= 1
        var end = position.coerceIn(0, content.length)
        while (end < content.length && !FoundationText.isNewline(content[end].code)) end += 1
        return TextRange(start, end)
    }

    private companion object {
        /** An excerpt starts up to this many characters before its match. */
        const val EXCERPT_LEAD = 16

        /** A preview is one or two lines; nothing beyond this can show. */
        const val MAX_PREVIEW_LENGTH = 240
    }
}
