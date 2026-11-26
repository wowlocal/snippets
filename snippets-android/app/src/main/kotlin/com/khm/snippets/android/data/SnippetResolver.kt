package com.khm.snippets.android.data

/**
 * Resolves placeholders (`{date…}`, `{time…}`, `{datetime…}`, `{clipboard}`) for copy, share and
 * the editor preview. A secure body is passed in only for a copy the user authenticated; it is
 * never passed to [preview] or [placeholderRanges].
 */
interface SnippetResolver {
    /** The tokens of [template] that resolve, in order. Empty: no preview and nothing to tint. */
    fun placeholderRanges(template: String): List<TextRange>

    /** True when resolving [template] needs the clipboard. Read it only then (DESIGN.md D39). */
    fun usesClipboard(template: String): Boolean

    /**
     * The text to copy or share: every resolvable token replaced, everything else kept byte for
     * byte. Inserted text is not scanned again.
     *
     * @param clipboardText The clipboard read at this moment, or null when it holds no text.
     */
    fun resolve(template: String, clipboardText: String?): String

    /** As [resolve] with the real date and time, and [clipboardStandIn] for `{clipboard}`. */
    fun preview(template: String, clipboardStandIn: String): String
}
