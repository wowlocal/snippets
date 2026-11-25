package com.khm.snippets.android.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/** Text colour and opaque fill of one tag slot. */
@Immutable
data class TagColor(val text: Color, val fill: Color)

/**
 * The twelve tag slots (DESIGN.md §5.3), in the order of the Apple apps: red, orange, yellow,
 * green, mint, teal, cyan, blue, indigo, purple, pink, brown. Fills are opaque literals.
 */
@Immutable
data class TagPalette(val slots: List<TagColor>) {
    init {
        require(slots.size == SLOT_COUNT) { "A tag palette has $SLOT_COUNT slots." }
    }

    /** The slot of a tag, selected by its folded form. */
    fun colorFor(foldedTag: String): TagColor = slots[tagColorIndex(foldedTag)]

    companion object {
        const val SLOT_COUNT = 12
    }
}

val SnippetsLightTagPalette = TagPalette(
    listOf(
        TagColor(text = Color(0xFFBA1A1A), fill = Color(0xFFF3DBDF)),
        TagColor(text = Color(0xFFA63C00), fill = Color(0xFFF1E0DC)),
        TagColor(text = Color(0xFF785900), fill = Color(0xFFEBE3DC)),
        TagColor(text = Color(0xFF2D6A35), fill = Color(0xFFE1E6E3)),
        TagColor(text = Color(0xFF006B5B), fill = Color(0xFFDBE6E8)),
        TagColor(text = Color(0xFF006A6A), fill = Color(0xFFDBE6EA)),
        TagColor(text = Color(0xFF00677A), fill = Color(0xFFDBE5EC)),
        TagColor(text = Color(0xFF005AC1), fill = Color(0xFFDBE3F5)),
        TagColor(text = Color(0xFF4F56A9), fill = Color(0xFFE6E3F2)),
        TagColor(text = Color(0xFF7B4E9D), fill = Color(0xFFEBE2F1)),
        TagColor(text = Color(0xFFA43A69), fill = Color(0xFFF1DFEA)),
        TagColor(text = Color(0xFF765847), fill = Color(0xFFEBE3E5)),
    ),
)

val SnippetsDarkTagPalette = TagPalette(
    listOf(
        TagColor(text = Color(0xFFFFB4AB), fill = Color(0xFF332829)),
        TagColor(text = Color(0xFFFFB691), fill = Color(0xFF332826)),
        TagColor(text = Color(0xFFF5C344), fill = Color(0xFF312A1C)),
        TagColor(text = Color(0xFF91D69A), fill = Color(0xFF242C27)),
        TagColor(text = Color(0xFF76D9C3), fill = Color(0xFF212D2C)),
        TagColor(text = Color(0xFF80D5D5), fill = Color(0xFF222C2F)),
        TagColor(text = Color(0xFF5DD5EF), fill = Color(0xFF1D2C32)),
        TagColor(text = Color(0xFFA9C7FF), fill = Color(0xFF272A34)),
        TagColor(text = Color(0xFFBEC2FF), fill = Color(0xFF2A2A34)),
        TagColor(text = Color(0xFFE9B7FF), fill = Color(0xFF302834)),
        TagColor(text = Color(0xFFFFB0CD), fill = Color(0xFF33272E)),
        TagColor(text = Color(0xFFE5BFA9), fill = Color(0xFF2F2929)),
    ),
)

val LocalTagPalette = staticCompositionLocalOf { SnippetsLightTagPalette }

/** The folded form of the tag that marks a conflict copy (DESIGN.md D33). */
const val CONFLICT_TAG_FOLDED = "conflict"

private val FNV_OFFSET_BASIS = 0xcbf29ce484222325UL.toLong()
private const val FNV_PRIME = 0x100000001b3L

/** FNV-1a 64 over the UTF-8 bytes, as the Apple apps compute it. */
fun fnv1a64(text: String): Long {
    var hash = FNV_OFFSET_BASIS
    for (byte in text.toByteArray(Charsets.UTF_8)) {
        hash = hash xor (byte.toLong() and 0xff)
        hash *= FNV_PRIME
    }
    return hash
}

/** Palette slot of a folded tag: `fnv1a64(foldedTag) mod 12`, unsigned. */
fun tagColorIndex(foldedTag: String): Int =
    java.lang.Long.remainderUnsigned(fnv1a64(foldedTag), TagPalette.SLOT_COUNT.toLong()).toInt()
