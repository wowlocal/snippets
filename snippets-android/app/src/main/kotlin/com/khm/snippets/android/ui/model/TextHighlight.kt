package com.khm.snippets.android.ui.model

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString

/** A matched character range in a displayed text. [end] is exclusive. */
@Immutable
data class TextHighlight(val start: Int, val end: Int)

/**
 * Makes ranges safe to draw on a text of [textLength] characters: clamps them to the text,
 * drops empty and inverted ones, sorts them and merges ranges that overlap or touch.
 */
fun mergeHighlights(ranges: List<TextHighlight>, textLength: Int): List<TextHighlight> {
    if (ranges.isEmpty() || textLength <= 0) return emptyList()
    val clamped = ranges
        .map { TextHighlight(it.start.coerceIn(0, textLength), it.end.coerceIn(0, textLength)) }
        .filter { it.start < it.end }
        .sortedBy { it.start }
    if (clamped.isEmpty()) return emptyList()
    val merged = ArrayList<TextHighlight>(clamped.size)
    var current = clamped.first()
    for (index in 1 until clamped.size) {
        val next = clamped[index]
        if (next.start <= current.end) {
            if (next.end > current.end) current = current.copy(end = next.end)
        } else {
            merged += current
            current = next
        }
    }
    merged += current
    return merged
}

/** Moves every range by [offset] characters, for a text that gained a prefix. */
fun shiftHighlights(ranges: List<TextHighlight>, offset: Int): List<TextHighlight> =
    if (offset == 0 || ranges.isEmpty()) ranges else ranges.map { TextHighlight(it.start + offset, it.end + offset) }

/**
 * [text] with the highlight span on every matched range (components.md §4.2). Out-of-range
 * input never throws. Highlights are visual only: the string content is unchanged.
 */
fun highlightedString(
    text: String,
    ranges: List<TextHighlight>,
    background: Color,
    foreground: Color,
): AnnotatedString {
    val merged = mergeHighlights(ranges, text.length)
    if (merged.isEmpty()) return AnnotatedString(text)
    val style = SpanStyle(background = background, color = foreground)
    return buildAnnotatedString {
        append(text)
        merged.forEach { addStyle(style, it.start, it.end) }
    }
}
