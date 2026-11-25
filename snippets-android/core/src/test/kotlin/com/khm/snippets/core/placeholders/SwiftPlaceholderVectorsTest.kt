package com.khm.snippets.core.placeholders

import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.search.UtilitiesFixture
import com.khm.snippets.core.text.FoundationText
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * L05: `PlaceholderResolver` and `RaycastPlaceholders` in six Swift processes, en_US,
 * fr_FR and th_TH in UTC and in Europe/Paris, 349 cases each.
 *
 * Which placeholders resolve, how often the clipboard is read, and every output that
 * holds no locale text must be exactly Swift's. Output that holds locale text (medium
 * styles, month and weekday names, day periods, zone names) comes from the runtime's CLDR
 * data, which is not the Mac's: each such difference is listed, with both strings, in
 * `fixtures/utilities/L05-jvm-locale-data-differences.tsv`, and anything not listed there
 * fails the test.
 */
class SwiftPlaceholderVectorsTest {

    private class Environment(val file: String, val locale: String, val zone: String)

    private val environments = listOf(
        Environment("L05-placeholders-en_US-UTC", "en-US", "UTC"),
        Environment("L05-placeholders-en_US-Europe-Paris", "en-US", "Europe/Paris"),
        Environment("L05-placeholders-fr_FR-UTC", "fr-FR", "UTC"),
        Environment("L05-placeholders-fr_FR-Europe-Paris", "fr-FR", "Europe/Paris"),
        Environment("L05-placeholders-th_TH-UTC", "th-TH", "UTC"),
        Environment("L05-placeholders-th_TH-Europe-Paris", "th-TH", "Europe/Paris"),
    )

    /** The fixed instants of the emitter, in seconds since 1970. */
    private val nows = mapOf(
        "month-end" to 1_769_902_215.0, "dst-eve" to 1_774_699_200.0, "leap-day" to 1_709_200_800.0, "afternoon" to 1_785_340_805.75,
    )

    private val clipboardText = "Clip {date} 🔑"

    /** `{"text": …, "utf8Hex": …}`, or only the bytes for a long value. */
    private fun text(case: SwiftVectors.Case, key: String): String = UtilitiesFixture.text(case.obj(key).string("utf8Hex").ifEmpty { "-" })

    /**
     * Whether the output of [template] holds text from locale data: a placeholder in a
     * localized style, or a pattern with a field that prints a name. Everything else
     * (digits, padding, literals, ISO offsets, the calendar's year) is computed.
     */
    private fun dependsOnLocaleData(template: String): Boolean {
        var depends = false
        PlaceholderGrammar.forEachCandidate(template) { candidate ->
            val parsed = PlaceholderGrammar.parse(candidate.body(template)) { it in macLocaleCores } as? PlaceholderGrammar.Parsed.Temporal
                ?: return@forEachCandidate
            val format = parsed.format
            if (format == null) {
                depends = true
            } else {
                for (item in IcuDatePattern.parse(format).items) {
                    if (item !is IcuDatePattern.Item.Field) continue
                    val named = when (item.letter) {
                        'G', 'E', 'a', 'b', 'B', 'z', 'v', 'V', 'O' -> true
                        'M', 'L', 'Q', 'q', 'e', 'c', 'd' -> item.count >= 3
                        'Z' -> item.count == 4 || item.count >= 6
                        else -> false
                    }
                    if (named) depends = true
                }
            }
        }
        return depends
    }

    private val macLocaleCores: Set<String> by lazy {
        PlaceholderTestSupport.macLocaleIdentifiers.mapTo(HashSet(), PlaceholderGrammar::localeCore).let { cores ->
            // The prefix rule of the resolver, made a plain set for this helper.
            cores + cores.flatMap { core -> core.split('-').indices.map { core.split('-').take(it + 1).joinToString("-") } }
        }
    }

    private class Difference(val file: String, val case: String, val template: String, val expected: String, val actual: String) {
        val key: String get() = "$file\t$case"
    }

    private fun hex(text: String): String = if (text.isEmpty()) "-" else Bytes.toHex(text.toByteArray(Charsets.UTF_8))

    @Test
    fun resolveMatchesSwiftInEveryEnvironment() {
        val differences = ArrayList<Difference>()
        var exact = 0
        var total = 0
        for (environment in environments) {
            val resolver = PlaceholderResolver(PlaceholderTestSupport.macRenderer(environment.locale, environment.zone))
            val cases = SwiftVectors.cases(environment.file, "resolve")
            assertEquals(317, cases.size, environment.file)
            for (case in cases) {
                total += 1
                val template = text(case, "template")
                val now = PlaceholderTestSupport.appleSeconds(nows.getValue(case.string("now")))
                var clipboardReads = 0
                var clockReads = 0
                val resolved = resolver.resolve(template, clipboard = { clipboardReads += 1; clipboardText }, now = { clockReads += 1; now })
                val preview = resolver.resolveForPreview(template, clipboard = { clipboardText }, now = { now })

                // The grammar: never a matter of locale data.
                assertEquals(1, clockReads, case.label)
                assertEquals(case.int("clipboardReads"), clipboardReads, case.label)
                assertEquals(case.boolean("containsResolvablePlaceholder"), resolver.containsResolvablePlaceholder(template), case.label)
                assertEquals(case.boolean("containsClipboardPlaceholder"), resolver.containsClipboardPlaceholder(template), case.label)
                assertEquals(case.boolean("isResolvablePlaceholder"), resolver.isResolvablePlaceholder(template), case.label)
                assertEquals(case.boolean("unchanged"), resolved == template, "${case.label}: ${UtilitiesFixture.scalars(resolved)}")
                assertEquals(case.boolean("previewEqualsResolved"), preview == resolved, case.label)

                val expected = text(case, "resolved")
                if (resolved == expected) {
                    exact += 1
                    continue
                }
                if (!dependsOnLocaleData(template)) {
                    fail("${case.label} holds no locale text: ${UtilitiesFixture.scalars(template)} expected ${UtilitiesFixture.scalars(expected)} got ${UtilitiesFixture.scalars(resolved)}")
                }
                differences.add(Difference(environment.file, case.name, template, expected, resolved))
            }
        }
        assertEquals(6 * 317, total)

        System.getenv("SNIPPETS_L05_DIFFERENCES")?.let { path ->
            File(path).writeText(differences.joinToString("") { "${it.key}\t${hex(it.template)}\t${hex(it.expected)}\t${hex(it.actual)}\n" })
        }

        // The list was recorded on JDK 17 (CLDR 39). Another runtime has other data: there
        // the list is not comparable, and the checks above are what the test asserts.
        val listed = UtilitiesFixture.rows(ALLOW_LIST).associateBy { "${it[0]}\t${it[1]}" }
        if (Runtime.version().feature() != RECORDED_JDK) return
        val unlisted = differences.filter { difference ->
            val row = listed[difference.key]
            row == null || UtilitiesFixture.text(row[7]) != difference.expected || UtilitiesFixture.text(row[8]) != difference.actual
        }
        if (unlisted.isNotEmpty()) {
            fail(
                "${unlisted.size} differences from Swift are not in $ALLOW_LIST:\n" + unlisted.take(30).joinToString("\n") {
                    "${it.key}: ${UtilitiesFixture.scalars(it.template)} expected ${UtilitiesFixture.scalars(it.expected)} got ${UtilitiesFixture.scalars(it.actual)}"
                },
            )
        }
        val stale = listed.keys - differences.map { it.key }.toSet()
        assertTrue(stale.isEmpty(), "listed in $ALLOW_LIST but no longer different: ${stale.take(10)}")
        assertEquals(listed.size, differences.size)
        assertEquals(6 * 317 - listed.size, exact)
        for (row in listed.values) {
            assertTrue(row[2] in CLASSES, "unknown class ${row[2]}")
            // The readable columns are the hex columns.
            assertEquals(listOf(row[3], row[4], row[5]), listOf(row[6], row[7], row[8]).map(UtilitiesFixture::text), row[1])
        }
        assertEquals(218, listed.size)
    }

    @Test
    fun clipboardPreviewAndCompletionCases() {
        for (environment in environments) {
            val resolver = PlaceholderResolver(PlaceholderTestSupport.macRenderer(environment.locale, environment.zone))
            val now = PlaceholderTestSupport.appleSeconds(nows.getValue("month-end"))

            val clipboard = SwiftVectors.cases(environment.file, "clipboard").single()
            assertTrue(clipboard.isNull("clipboard"))
            assertEquals(clipboard.string("resolved"), resolver.resolve(clipboard.string("template"), { null }, { now }))

            val previews = SwiftVectors.cases(environment.file, "preview")
            assertEquals(6, previews.size)
            for (case in previews) {
                val preview = if (case.has("clipboardCharacterCount")) {
                    val clip = "c".repeat(case.int("clipboardCharacterCount"))
                    resolver.resolveForPreview(case.string("template"), { clip }, { now })
                } else {
                    resolver.resolveForPreview("t".repeat(case.int("templateCharacterCount")), { null }, { now })
                }
                assertEquals(case.int("previewCharacterCount"), FoundationText.characterCount(preview), case.label)
                assertTrue(preview.endsWith(case.string("previewSuffix")), case.label)
            }

            val completion = SwiftVectors.cases(environment.file, "completion").single()
            assertEquals(completion.strings("tokens"), PlaceholderResolver.COMPLETION_TOKENS)
            assertEquals(completion.boolean("allResolve"), resolver.completionTokensAllResolve())
        }
    }

    @Test
    fun raycastConversionMatchesSwift() {
        for (environment in environments) {
            val cases = SwiftVectors.cases(environment.file, "raycast")
            assertEquals(24, cases.size)
            for (case in cases) {
                val input = text(case, "input")
                val converted = RaycastPlaceholders.converted(input)
                assertEquals(text(case, "converted"), converted, case.label)
                assertEquals(case.boolean("changed"), converted != input, case.label)
            }
        }
    }

    private companion object {
        const val ALLOW_LIST = "L05-jvm-locale-data-differences.tsv"
        const val RECORDED_JDK = 17
        val CLASSES = setOf(
            "medium-style-pattern", "narrow-no-break-space", "name-spelling", "day-period", "zone-name", "calendar-not-in-jdk",
        )
    }
}
