package com.khm.snippets.android.data.core

import com.khm.snippets.android.data.SnippetResolver
import com.khm.snippets.android.data.TextRange
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.placeholders.DateRenderer
import com.khm.snippets.core.placeholders.PlaceholderResolver

/**
 * [SnippetResolver] on `core.placeholders.PlaceholderResolver`.
 *
 * @param renderer The date renderer of the user's current environment (locale, zone, 12/24-hour
 *   setting). It is asked on every call; a new renderer instance builds a new resolver, so a
 *   locale change on the device takes effect at the next copy.
 * @param now Seconds since 2001; tests pass a fixed instant.
 */
class CoreSnippetResolver(
    private val renderer: () -> DateRenderer,
    private val now: () -> Double = AppleTime::now,
) : SnippetResolver {
    @Volatile private var cached: Pair<DateRenderer, PlaceholderResolver>? = null

    private fun resolver(): PlaceholderResolver {
        val current = renderer()
        cached?.let { (dates, resolver) -> if (dates === current) return resolver }
        return PlaceholderResolver(current).also { cached = current to it }
    }

    override fun placeholderRanges(template: String): List<TextRange> {
        val resolver = resolver()
        return candidates(template).filter { resolver.isResolvablePlaceholder(template.substring(it.start, it.end)) }
    }

    override fun usesClipboard(template: String): Boolean = resolver().containsClipboardPlaceholder(template)

    override fun resolve(template: String, clipboardText: String?): String =
        resolver().resolve(template, clipboard = { clipboardText }, now = now)

    override fun preview(template: String, clipboardStandIn: String): String =
        resolver().resolveForPreview(template, clipboard = { clipboardStandIn }, now = now)

    companion object {
        /**
         * Every `{…}` candidate of [template], left to right: `{`, a body without `{`, `}`, CR or
         * LF, then `}` (the resolver's own grammar). Whether one resolves is the resolver's call.
         */
        fun candidates(template: String): List<TextRange> {
            val found = ArrayList<TextRange>()
            var index = template.indexOf('{')
            while (index >= 0) {
                var cursor = index + 1
                while (cursor < template.length && template[cursor] !in BODY_TERMINATORS) cursor += 1
                if (cursor >= template.length) break
                index = when (template[cursor]) {
                    '}' -> {
                        found += TextRange(index, cursor + 1)
                        template.indexOf('{', cursor + 1)
                    }
                    '{' -> cursor
                    else -> template.indexOf('{', cursor + 1)
                }
            }
            return found
        }

        private const val BODY_TERMINATORS = "{}\r\n"
    }
}
