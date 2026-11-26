package com.khm.snippets.android.feature.editor

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import com.khm.snippets.android.ui.model.TextHighlight
import com.khm.snippets.android.ui.model.mergeHighlights

/**
 * Tints the placeholders the resolver recognises in the body (`{date…}`, `{clipboard}`) in
 * `primary`. Visual only: the text and every offset are unchanged.
 */
class PlaceholderTint(private val ranges: List<TextHighlight>, private val color: Color) : VisualTransformation {
    override fun filter(text: AnnotatedString): TransformedText {
        val merged = mergeHighlights(ranges, text.length)
        if (merged.isEmpty()) return TransformedText(text, OffsetMapping.Identity)
        val tinted = buildAnnotatedString {
            append(text)
            merged.forEach { addStyle(SpanStyle(color = color), it.start, it.end) }
        }
        return TransformedText(tinted, OffsetMapping.Identity)
    }

    override fun equals(other: Any?): Boolean = other is PlaceholderTint && other.ranges == ranges && other.color == color

    override fun hashCode(): Int = 31 * ranges.hashCode() + color.hashCode()
}
