package com.khm.snippets.core.placeholders

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.placeholders.PlaceholderGrammar.Parsed

/**
 * Expands `{…}` placeholders in snippet text (`PlaceholderResolver.swift`): the last code
 * that runs before a snippet is copied or typed into someone else's document.
 *
 * ```
 * {clipboard}                         the clipboard text
 * {date} {time} {datetime}            the localized medium style
 * {date:yyyy-MM-dd}                   a compact ICU pattern (letters, digits, : _ -)
 * {date format="EEEE, MMMM d"}        any ICU pattern, quoted
 * {date locale="fr-FR"}               the medium style of another locale
 * {date offset="+1M -2d"}             moved by m, h, d, M or y; combines with the others
 * {date "yyyy-MM-dd"}                 the spelling of old Raycast exports
 * ```
 *
 * Everything else between braces, including a placeholder with a mistake in it, stays in
 * the text exactly as written. One pass: text that a placeholder inserts is never scanned
 * again, so a clipboard that holds `{date}` is pasted as `{date}`.
 *
 * The clipboard and the clock are parameters; dates come from [dates]. Nothing here reads
 * a platform default. Instances are immutable and safe to share.
 */
class PlaceholderResolver(private val dates: DateRenderer) {

    private enum class Mode { EXPANSION, PREVIEW }

    // `availableLocaleCores`, computed on first use: asking the platform for its locales is slow.
    private val availableLocaleCores: Set<String> by lazy(LazyThreadSafetyMode.PUBLICATION) {
        dates.availableLocaleIdentifiers().mapTo(HashSet(), PlaceholderGrammar::localeCore)
    }

    private val isAvailableLocale: (String) -> Boolean = { core ->
        core in availableLocaleCores || availableLocaleCores.any { it.startsWith("$core-") }
    }

    /** `completionTokensAllResolve()`: every offered token is one the resolver replaces. */
    fun completionTokensAllResolve(): Boolean = COMPLETION_TOKENS.all(::containsResolvablePlaceholder)

    /**
     * `resolve(template:clipboard:now:)`.
     *
     * @param clipboard read once for each `{clipboard}` in the template, last one first,
     * and not at all when there is none. `null` inserts nothing.
     * @param now seconds since 2001 ([AppleTime]); sampled exactly once, whatever the template holds.
     */
    fun resolve(template: String, clipboard: () -> String?, now: () -> Double = AppleTime::now): String =
        resolve(template, Mode.EXPANSION, clipboard, now())

    /**
     * `resolveForPreview(template:clipboard:now:)`: [resolve] for showing in the editor.
     * Each clipboard value is cut to [PREVIEW_CLIPBOARD_CHARACTERS] and the whole result to
     * [PREVIEW_RENDERED_CHARACTERS], each followed by a line that says so.
     */
    fun resolveForPreview(template: String, clipboard: () -> String?, now: () -> Double = AppleTime::now): String =
        PlaceholderGrammar.limitedPreview(
            resolve(template, Mode.PREVIEW, clipboard, now()), PREVIEW_RENDERED_CHARACTERS, PREVIEW_TRUNCATED_MARKER,
        )

    /** `containsResolvablePlaceholder(in:)`: the template holds at least one placeholder that [resolve] replaces. */
    fun containsResolvablePlaceholder(template: String): Boolean = containsPlaceholder(template) { true }

    /** `containsClipboardPlaceholder(in:)`. */
    fun containsClipboardPlaceholder(template: String): Boolean = containsPlaceholder(template) { it is Parsed.Clipboard }

    /**
     * `isResolvablePlaceholder(_:)`: [text] is exactly one placeholder, with nothing
     * before, after or beside it.
     */
    fun isResolvablePlaceholder(text: String): Boolean {
        val body = PlaceholderGrammar.soleCandidateBody(text) ?: return false
        return PlaceholderGrammar.parse(body, isAvailableLocale) != null
    }

    private inline fun containsPlaceholder(template: String, predicate: (Parsed) -> Boolean): Boolean {
        PlaceholderGrammar.forEachCandidate(template) { candidate ->
            val parsed = PlaceholderGrammar.parse(candidate.body(template), isAvailableLocale)
            if (parsed != null && predicate(parsed)) return true
        }
        return false
    }

    private fun resolve(template: String, mode: Mode, clipboard: () -> String?, now: Double): String {
        val candidates = ArrayList<PlaceholderGrammar.Candidate>()
        PlaceholderGrammar.forEachCandidate(template) { candidates.add(it) }
        if (candidates.isEmpty()) return template

        // Swift replaces back to front, so the last placeholder is evaluated first. The
        // order is kept because the clipboard closure can observe it.
        val replacements = arrayOfNulls<String>(candidates.size)
        var resolvedLength = template.length.toLong()
        for (index in candidates.indices.reversed()) {
            val candidate = candidates[index]
            val parsed = PlaceholderGrammar.parse(candidate.body(template), isAvailableLocale) ?: continue
            val replacement = replacementValue(parsed, mode, clipboard, now) ?: continue
            resolvedLength += replacement.length - (candidate.end - candidate.start)
            // Not in Swift: see MAXIMUM_RESOLVED_LENGTH.
            if (resolvedLength > MAXIMUM_RESOLVED_LENGTH) {
                resolvedLength -= replacement.length - (candidate.end - candidate.start)
                continue
            }
            replacements[index] = replacement
        }

        val rendered = StringBuilder(resolvedLength.toInt())
        var cursor = 0
        for (index in candidates.indices) {
            val replacement = replacements[index] ?: continue
            val candidate = candidates[index]
            rendered.append(template, cursor, candidate.start).append(replacement)
            cursor = candidate.end
        }
        if (cursor == 0) return template
        return rendered.append(template, cursor, template.length).toString()
    }

    private fun replacementValue(parsed: Parsed, mode: Mode, clipboard: () -> String?, now: Double): String? = when (parsed) {
        is Parsed.Clipboard -> {
            val value = clipboard() ?: ""
            if (mode == Mode.PREVIEW) {
                PlaceholderGrammar.limitedPreview(value, PREVIEW_CLIPBOARD_CHARACTERS, CLIPBOARD_TRUNCATED_MARKER)
            } else {
                value
            }
        }
        is Parsed.Temporal -> temporalValue(parsed, now)
    }

    private fun temporalValue(temporal: Parsed.Temporal, now: Double): String? {
        // Foundation formats a date it cannot represent as the empty string.
        var instant = epochMillis(now) ?: return ""
        try {
            for (offset in temporal.offsets) {
                instant = dates.add(instant, offset.unit, offset.value) ?: return null
            }
            val format = temporal.format
            if (format != null) return dates.format(instant, format)
            val dateStyle = if (temporal.kind == PlaceholderGrammar.TemporalKind.TIME) DateRenderer.Style.NONE else DateRenderer.Style.MEDIUM
            val timeStyle = if (temporal.kind == PlaceholderGrammar.TemporalKind.DATE) DateRenderer.Style.NONE else DateRenderer.Style.MEDIUM
            return dates.format(instant, dateStyle, timeStyle, temporal.localeIdentifier)
        } catch (_: RuntimeException) {
            // A renderer must not throw. If a platform formatter does anyway, the user
            // gets what Foundation gives for a pattern it cannot format: nothing.
            return ""
        }
    }

    companion object {

        /** `PreviewLimit.clipboardCharacters`, in `Character`s. */
        const val PREVIEW_CLIPBOARD_CHARACTERS: Int = 1_000

        /** `PreviewLimit.renderedCharacters`, in `Character`s. */
        const val PREVIEW_RENDERED_CHARACTERS: Int = 2_000

        private const val CLIPBOARD_TRUNCATED_MARKER = "[clipboard preview truncated]"
        private const val PREVIEW_TRUNCATED_MARKER = "[preview truncated]"

        /**
         * A defensive cap that Swift does not have: a replacement that would take the
         * result past this many UTF-16 units is skipped and its placeholder stays as
         * written. A template with a hundred thousand `{clipboard}` and a large clipboard
         * would otherwise exhaust memory. 64 million units is far beyond any real snippet.
         */
        const val MAXIMUM_RESOLVED_LENGTH: Long = 64L * 1024 * 1024

        /**
         * `completionTokens`: what typing `{` in the content editor offers. Every one of
         * them resolves ([completionTokensAllResolve]).
         */
        val COMPLETION_TOKENS: List<String> = listOf("{clipboard}", "{date}", "{time}", "{datetime}", "{date:yyyy-MM-dd}")

        /** The range ICU's calendars cover, in milliseconds since 1970. */
        private const val MINIMUM_MILLIS = -184_303_902_528_000_000L
        private const val MAXIMUM_MILLIS = 183_882_168_921_600_000L

        /** Seconds since 2001 as whole milliseconds since 1970, rounded down as ICU does; `null` outside ICU's range. */
        internal fun epochMillis(appleSeconds: Double): Long? {
            val millis = Math.floor(AppleTime.unixSeconds(appleSeconds) * 1000.0)
            if (!(millis >= MINIMUM_MILLIS.toDouble() && millis <= MAXIMUM_MILLIS.toDouble())) return null
            return millis.toLong()
        }
    }
}
