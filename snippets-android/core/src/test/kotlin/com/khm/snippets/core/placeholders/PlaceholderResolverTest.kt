package com.khm.snippets.core.placeholders

import com.khm.snippets.core.search.UtilitiesFixture
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.text.SeededRandom
import java.time.ZoneId
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `Tests/Core/PlaceholderResolverTests.swift` ("Placeholder resolver"). Like the Swift
 * suite, expected dates are made with the same formatter the resolver uses, so the tests
 * hold in any locale and zone; they run in three.
 *
 * Followed by Swift's verdict on 209 templates that probe the grammar, and by fuzzing.
 */
class PlaceholderResolverTest {

    /** 2026-02-15 12:00:00 UTC. */
    private val epoch = PlaceholderTestSupport.appleSeconds(1_771_156_800.0)
    private val epochMillis = 1_771_156_800_000L

    private class World(val renderer: DateRenderer) {
        val resolver = PlaceholderResolver(renderer)
    }

    private val worlds = listOf(
        World(PlaceholderTestSupport.macRenderer("en-US", "UTC")),
        World(PlaceholderTestSupport.macRenderer("fr-FR", "Europe/Paris")),
        World(PlaceholderTestSupport.macRenderer("th-TH", "America/New_York")),
    )

    private fun World.expand(template: String, clipboard: String? = "CLIPBOARD"): String =
        resolver.resolve(template, clipboard = { clipboard }, now = { epoch })

    private fun World.formatted(pattern: String, at: Long = epochMillis): String = renderer.format(at, pattern)

    private fun World.styled(date: DateRenderer.Style, time: DateRenderer.Style, at: Long = epochMillis, locale: String? = null): String =
        renderer.format(at, date, time, locale)

    private fun World.shifted(vararg offsets: Pair<DateRenderer.Unit, Int>): Long =
        offsets.fold(epochMillis) { instant, (unit, amount) -> renderer.add(instant, unit, amount) ?: fail("no date") }

    // Legacy and current Raycast round trips

    @Test
    fun legacyRaycastFormatsCanonicalizeToResolvableCurrentTokens() {
        val cases = listOf(
            Triple("""{date "MMM d, yyyy"}""", """{date format="MMM d, yyyy"}""", "MMM d, yyyy"),
            Triple("""{time "HH:mm:ss.SSS"}""", """{time format="HH:mm:ss.SSS"}""", "HH:mm:ss.SSS"),
            Triple("""{datetime "yyyy-MM-dd'T'HH:mm:ssZ"}""", """{datetime format="yyyy-MM-dd'T'HH:mm:ssZ"}""", "yyyy-MM-dd'T'HH:mm:ssZ"),
            Triple("""{date "yyyy年MM月dd日"}""", """{date format="yyyy年MM月dd日"}""", "yyyy年MM月dd日"),
        )
        for (world in worlds) {
            for ((legacy, token, pattern) in cases) {
                val converted = RaycastPlaceholders.converted(legacy)
                assertEquals(token, converted)
                assertTrue(world.resolver.isResolvablePlaceholder(converted))
                assertEquals(world.formatted(pattern), world.expand(converted))
                assertFalse(world.expand(converted).contains("{"))
            }
        }
    }

    @Test
    fun currentRaycastFormatsPassThroughAndExpand() {
        val cases = listOf(
            """{date format="EEEE, MMM d, yyyy"}""" to "EEEE, MMM d, yyyy",
            """{date format="MM/dd/yyyy"}""" to "MM/dd/yyyy",
            """{time format="HH:mm:ss.SSS"}""" to "HH:mm:ss.SSS",
            """{datetime format="yyyy-MM-dd'T'HH:mm:ssZ"}""" to "yyyy-MM-dd'T'HH:mm:ssZ",
            """{date format="h:mm 'on the eve of' MMMM d"}""" to "h:mm 'on the eve of' MMMM d",
        )
        for (world in worlds) {
            for ((source, pattern) in cases) {
                assertEquals(source, RaycastPlaceholders.converted(source))
                assertTrue(world.resolver.isResolvablePlaceholder(source))
                assertEquals(world.formatted(pattern), world.expand(source))
            }
        }
    }

    @Test
    fun offsetsUseTheInjectedInstantAndCalendar() {
        for (world in worlds) {
            val formattedDate = world.shifted(
                DateRenderer.Unit.MONTH to 3, DateRenderer.Unit.DAY to -5, DateRenderer.Unit.HOUR to 2, DateRenderer.Unit.MINUTE to 30,
            )
            assertEquals(
                world.formatted("yyyy-MM-dd HH:mm", formattedDate),
                world.expand("""{date format="yyyy-MM-dd HH:mm" offset="+3M -5d +2h +30m"}"""),
            )
            assertEquals(
                world.styled(DateRenderer.Style.NONE, DateRenderer.Style.MEDIUM, world.shifted(DateRenderer.Unit.HOUR to 1)),
                world.expand("{time offset=+1h}"),
            )
            assertEquals(
                world.formatted("yyyy-MM-dd", world.shifted(DateRenderer.Unit.DAY to 1)),
                world.expand("""{date offset="+1d" format="yyyy-MM-dd"}"""),
            )
        }
        // Literally, in UTC: 15 February plus three months, minus five days, plus 2:30.
        assertEquals("2026-05-10 14:30", worlds[0].expand("""{date format="yyyy-MM-dd HH:mm" offset="+3M -5d +2h +30m"}"""))
    }

    @Test
    fun localeUsesLocalizedDefaultStyleAndCombinesWithOffset() {
        for (world in worlds) {
            val tomorrow = world.shifted(DateRenderer.Unit.DAY to 1)
            assertEquals(
                world.styled(DateRenderer.Style.MEDIUM, DateRenderer.Style.NONE, tomorrow, "fr-FR"),
                world.expand("""{date locale="fr-FR" offset="+1d"}"""),
            )
            assertEquals(
                world.styled(DateRenderer.Style.NONE, DateRenderer.Style.MEDIUM, locale = "en-US-u-hc-h23"),
                world.expand("""{time locale="en-US-u-hc-h23"}"""),
            )
        }
        assertEquals("16 févr. 2026", worlds[0].expand("""{date locale="fr-FR" offset="+1d"}"""))
        assertEquals("12:00:00", worlds[0].expand("""{time locale="en-US-u-hc-h23"}"""))
    }

    @Test
    fun severalLegacyRaycastTokensAreAllCanonicalized() {
        val source = """On {date "MMM d, yyyy"} at {time "HH:mm"} ({datetime "yyyy/MM/dd HH:mm"})"""
        val converted = RaycastPlaceholders.converted(source)
        assertEquals("""On {date format="MMM d, yyyy"} at {time format="HH:mm"} ({datetime format="yyyy/MM/dd HH:mm"})""", converted)
        for (world in worlds) {
            assertEquals(
                "On ${world.formatted("MMM d, yyyy")} at ${world.formatted("HH:mm")} (${world.formatted("yyyy/MM/dd HH:mm")})",
                world.expand(converted),
            )
        }
    }

    @Test
    fun importerNeverManufacturesAnInertToken() {
        for (source in listOf("""{date "{yyyy}"}""", """{date "x}{clipboard"}""", """{date "yyyy-MM-dd'T"}""", """{date "unterminated}""")) {
            assertEquals(source, RaycastPlaceholders.converted(source))
            for (world in worlds) assertFalse(world.resolver.isResolvablePlaceholder(source), source)
        }
    }

    // Negative controls: explicit syntax must not eat ordinary code

    private fun assertStaysVisible(sources: List<String>) {
        for (world in worlds) {
            for (source in sources) {
                assertEquals(source, world.expand(source))
                assertFalse(world.resolver.containsResolvablePlaceholder(source), source)
                assertFalse(world.resolver.isResolvablePlaceholder(source), source)
            }
        }
    }

    @Test
    fun compactCodeAndPathsPassThroughByteForByte() = assertStaysVisible(
        listOf(
            "{date:value,time:value}", "{date:value, time:value}", "const metadata={date:value,time:value}",
            "{date:path/to.file}", "{time:host/path.txt}", "{datetime:value,date:value}",
        ),
    )

    @Test
    fun unrelatedBracedTextStillPassesThroughByteForByte() = assertStaysVisible(
        listOf(
            "{date: value}", "{date: 1}", "{time: 300}", "{ date }", "{style: {color: red}}", "let x = {date: 1, time: 2}",
            "{nonsense}", "{unknown token with spaces}", "{date:}", "no tokens at all", "",
        ),
    )

    @Test
    fun invalidOrAmbiguousModifiersStayVisible() = assertStaysVisible(
        listOf(
            """{date format="yyyy-MM-dd" locale="fr-FR"}""", "{date format=yyyy-MM-dd}", "{date locale=fr-FR}",
            """{date locale="en_US"}""", """{date locale="zz-ZZ"}""", """{date offset="+ 2d"}""", """{date offset="+1w"}""",
            """{date offset="+100001d"}""", """{date offset="+1d" offset="+2d"}""", """{date format="yyyy-MM-dd" unknown="x"}""",
            """{date format="yyyy-MM-dd'T"}""", """{date format=""}""",
        ),
    )

    @Test
    fun anEmptyDateFormatIsStillNotResolvable() {
        for (world in worlds) {
            assertFalse(world.resolver.containsResolvablePlaceholder("{date:}"))
            assertEquals("{date:}", world.expand("{date:}"))
        }
    }

    @Test
    fun aTokenCannotSpanFromOneBracePairIntoTheNext() {
        for (world in worlds) {
            assertEquals("a ${world.formatted("MMM d, yyyy")} b CLIPBOARD c", world.expand("""a {date format="MMM d, yyyy"} b {clipboard} c"""))
            assertEquals("{a} and {b}", world.expand("{a} and {b}"))
        }
    }

    // The unchanged native vocabulary

    @Test
    fun bareAndCompactNativeTokensBehaveExactlyAsBefore() {
        for (world in worlds) {
            assertEquals("CLIPBOARD", world.expand("{clipboard}"))
            assertEquals("", world.expand("{clipboard}", clipboard = null))
            assertEquals(world.formatted("yyyy-MM-dd"), world.expand("{date:yyyy-MM-dd}"))
            assertEquals("TP-${world.formatted("yyyyMMdd")}-CLIPBOARD", world.expand("TP-{date:yyyyMMdd}-{clipboard}"))
            for (bare in listOf("{date}", "{time}", "{datetime}")) assertFalse(world.expand(bare).contains("{"), "$bare is replaced")
        }
        assertEquals("2026-02-15", worlds[0].expand("{date:yyyy-MM-dd}"))
        assertEquals("2569-02-15", worlds[2].expand("{date:yyyy-MM-dd}"), "the Thai locale counts Buddhist years")
    }

    @Test
    fun theCompletionMenuOnlyOffersTokensTheResolverReplaces() {
        for (world in worlds) {
            assertTrue(world.resolver.completionTokensAllResolve())
            for (token in PlaceholderResolver.COMPLETION_TOKENS) {
                assertTrue(token.startsWith("{") && token.endsWith("}"))
                assertTrue(world.resolver.isResolvablePlaceholder(token))
            }
        }
        assertTrue(PlaceholderResolver.COMPLETION_TOKENS.isNotEmpty())
        assertEquals(listOf("{date}", "{datetime}", "{date:yyyy-MM-dd}"), PlaceholderResolver.COMPLETION_TOKENS.filter { it.startsWith("{da") })
        // With the JVM's own list of locales too.
        assertTrue(PlaceholderResolver(JvmDateRenderer(Locale.ROOT, ZoneId.of("UTC"))).completionTokensAllResolve())
    }

    // Dependency injection and previews

    @Test
    fun theClipboardIsOnlyReadWhenATemplateActuallyAsksForIt() {
        var reads = 0
        val read: () -> String? = { reads += 1; "CLIP" }
        val resolver = worlds[0].resolver
        resolver.resolve("{date}", read) { epoch }
        resolver.containsClipboardPlaceholder("{clipboard}")
        resolver.resolveForPreview("{clipboard:x} {CLIPBOARD}", read) { epoch }
        assertEquals(0, reads)
        resolver.resolve("{clipboard}", read) { epoch }
        assertEquals(1, reads)
    }

    @Test
    fun oneResolutionSamplesTheClockExactlyOnce() {
        for (world in worlds) {
            var reads = 0
            val rendered = world.resolver.resolve(
                """{date format="HH:mm:ss"} {time offset=+1h} {date:yyyy-MM-dd}""", clipboard = { null }, now = { reads += 1; epoch },
            )
            assertEquals(1, reads)
            assertEquals(
                world.formatted("HH:mm:ss") + " " +
                    world.styled(DateRenderer.Style.NONE, DateRenderer.Style.MEDIUM, world.shifted(DateRenderer.Unit.HOUR to 1)) +
                    " " + world.formatted("yyyy-MM-dd"),
                rendered,
            )
            reads = 0
            world.resolver.resolve("no placeholder", { null }) { reads += 1; epoch }
            world.resolver.resolveForPreview("{clipboard}", { null }) { reads += 1; epoch }
            assertEquals(2, reads, "sampled once per call even when nothing needs it, as in Swift")
        }
    }

    @Test
    fun theClipboardPreviewIsStillTruncated() {
        val huge = "x".repeat(3_000)
        val preview = worlds[0].resolver.resolveForPreview("{clipboard}", { huge }) { epoch }
        assertTrue(preview.endsWith("[clipboard preview truncated]"))
        assertTrue(preview.length < huge.length)
        assertEquals("x".repeat(1_000) + "\n... [clipboard preview truncated]", preview)
    }

    // Beyond the Swift suite

    @Test
    fun previewLimitsCountCharactersNotUnits() {
        val resolver = worlds[0].resolver
        val family = "👨\u200D👩\u200D👧"
        assertEquals(family.repeat(1_000), resolver.resolveForPreview("{clipboard}", { family.repeat(1_000) }) { epoch })
        assertEquals(family.repeat(1_000) + "\n... [clipboard preview truncated]", resolver.resolveForPreview("{clipboard}", { family.repeat(1_001) }) { epoch })
        // Two clipboard values of 1 000 make 2 001 Characters with the space: the whole is cut at 2 000.
        val both = resolver.resolveForPreview("{clipboard} {clipboard}", { "e\u0301".repeat(1_000) }) { epoch }
        assertEquals("e\u0301".repeat(1_000) + " " + "e\u0301".repeat(999) + "\n... [preview truncated]", both)
        assertEquals(2_000, FoundationText.characterCount(both.removeSuffix("\n... [preview truncated]")))
        // Expansion is never cut.
        assertEquals(6_001, resolver.resolve("{clipboard} {clipboard}", { "x".repeat(3_000) }) { epoch }.length)
    }

    @Test
    fun insertedTextIsNeverScannedAgain() {
        val resolver = worlds[0].resolver
        assertEquals(" 2026 ", resolver.resolve("{clipboard} {date:yyyy} {clipboard}", { null }) { epoch })
        assertEquals("{date}|{clipboard}|{time}", resolver.resolve("{clipboard}", { "{date}|{clipboard}|{time}" }) { epoch })
        assertEquals("{da2026te}", resolver.resolve("{da{date:yyyy}te}", { null }) { epoch }, "the inner token resolves; the result is not a token")
        // Evaluation runs from the last placeholder to the first, as Swift's does.
        val order = ArrayList<Int>()
        var next = 0
        assertEquals("3 2 1", resolver.resolve("{clipboard} {clipboard} {clipboard}", { next += 1; order.add(next); next.toString() }) { epoch })
        assertEquals(listOf(1, 2, 3), order)
    }

    /** Known quirks of the Swift resolver, each pinned by the vectors or measured from Swift. */
    @Test
    fun swiftQuirksAreKeptAndTheCrashIsNot() {
        val world = worlds[0]
        // Swift traps on a body of exactly `date "`: here it is text.
        for (kind in listOf("date", "time", "datetime")) {
            val source = "{$kind \"}"
            assertEquals(source, world.expand(source))
            assertFalse(world.resolver.containsResolvablePlaceholder(source))
            assertFalse(world.resolver.isResolvablePlaceholder(source))
            assertEquals(source, RaycastPlaceholders.converted(source))
            assertEquals("a${source}b 2026", world.expand("a${source}b {date:yyyy}"))
        }
        // Six `B` crash Foundation (SIGSEGV in DateFormatter, measured on macOS 27.2): here they print the day period.
        for (source in listOf("{date:BBBBBB}", "{time:BBBBBBB}", "{date:BBBBBB-d}", """{date format="BBBBBB"}""")) {
            assertTrue(world.resolver.isResolvablePlaceholder(source))
            assertTrue(world.expand(source).startsWith("PM"), world.expand(source))
        }
        assertEquals("BBBBB'-'d", IcuDatePattern.formattablePrefix("BBBBBBBB-d"))
        // An invalid pattern letter ends the output: nothing for `i`, the date for the unquoted `T`.
        assertEquals("", world.expand("""{date format="it''s"}"""))
        assertEquals("", world.expand("{date:foo}"))
        assertEquals("[]", world.expand("[{date:foo}]"))
        assertEquals("2026-02-15", world.expand("{date:yyyy-MM-ddTHH:mm}"))
        assertEquals("quoted 'PM", world.expand("""{date format="'quoted' ''apostrophe'' yyyy"}"""))
        assertTrue(world.resolver.containsResolvablePlaceholder("{date:foo}"), "it is a placeholder, and it resolves to nothing")
        // A long run of letters is padded to ten digits at most.
        assertEquals("0000002026", world.expand("{date:${"y".repeat(600)}}"))
        // A date ICU cannot represent formats as nothing, as in Foundation.
        for (now in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, 1e15, -1e15, 1e300)) {
            assertEquals("[]", world.resolver.resolve("[{date:yyyy-MM-dd}]", { null }) { now }, "$now")
            assertEquals("[][]", world.resolver.resolve("[{date}][{datetime offset=+1y}]", { null }) { now }, "$now")
        }
    }

    @Test
    fun aRendererThatThrowsIsNotACrash() {
        val throwing = object : DateRenderer by PlaceholderTestSupport.GrammarOnly {
            override fun format(epochMillis: Long, pattern: String): String = throw IllegalArgumentException("Illegal pattern character")
            override fun add(epochMillis: Long, unit: DateRenderer.Unit, amount: Int): Long? = throw ArithmeticException("overflow")
        }
        val resolver = PlaceholderResolver(throwing)
        assertEquals("[] [] c", resolver.resolve("[{date:yyyy}] [{date offset=+1d}] {clipboard}", { "c" }) { epoch })
        assertEquals("[]", resolver.resolveForPreview("[{date:yyyy}]", { null }) { epoch })
    }

    @Test
    fun aHugeExpansionIsCappedInsteadOfExhaustingMemory() {
        val resolver = worlds[0].resolver
        val clipboard = "c".repeat(1 shl 20)
        var reads = 0
        val rendered = resolver.resolve("{clipboard}".repeat(100), { reads += 1; clipboard }) { epoch }
        assertEquals(100, reads, "the clipboard is still read for every placeholder")
        assertTrue(rendered.length <= PlaceholderResolver.MAXIMUM_RESOLVED_LENGTH)
        // 63 values fit under 64 MiB; the other 37 placeholders, the first ones, stay as written.
        assertTrue(rendered.startsWith("{clipboard}".repeat(37) + "ccc"))
        assertEquals(37 * "{clipboard}".length + 63 * (1 shl 20), rendered.length)
        // Ordinary sizes are untouched.
        assertEquals(30 * 100_000, resolver.resolve("{clipboard}".repeat(30), { "c".repeat(100_000) }) { epoch }.length)
    }

    /**
     * 209 templates built to probe the grammar: combining marks on delimiters, limits of
     * 1 024, 512 and 64 Characters, 3 and 4 attributes, 8 and 9 offset terms, locale
     * spellings. Swift's three verdicts for each; no date is formatted.
     */
    @Test
    fun theGrammarAcceptsExactlyWhatSwiftAccepts() {
        val resolver = PlaceholderResolver(PlaceholderTestSupport.GrammarOnly)
        val rows = UtilitiesFixture.rows("swift-grammar.tsv")
        assertEquals(209, rows.size)
        var resolvable = 0
        for (row in rows) {
            val template = UtilitiesFixture.text(row[0])
            val label = UtilitiesFixture.scalars(if (template.length > 200) template.take(200) + "…" else template)
            assertEquals(row[1] == "1", resolver.containsResolvablePlaceholder(template), "contains $label")
            assertEquals(row[2] == "1", resolver.containsClipboardPlaceholder(template), "clipboard $label")
            assertEquals(row[3] == "1", resolver.isResolvablePlaceholder(template), "is $label")
            // A template without a live placeholder comes back as the same text.
            if (row[1] == "0") assertEquals(template, resolver.resolve(template, { "c" }) { epoch }, label) else resolvable += 1
        }
        assertTrue(resolvable in 60..150, "resolvable $resolvable")
    }

    @Test
    fun theFormatReachesTheFormatterScalarForScalar() {
        var seen = ""
        val recording = object : DateRenderer by PlaceholderTestSupport.GrammarOnly {
            override fun format(epochMillis: Long, pattern: String): String {
                seen = pattern
                return "ok"
            }
        }
        val resolver = PlaceholderResolver(recording)
        // Not normalized: `e` + U+0301 is the pattern letter `e` and a literal mark, not a literal `é`.
        for (format in listOf("e\u0301", "yy\u0301y", "a\"\u0301b", "x\u0301'y'", "é", "가", "\u1100\u1161", "y\u2028y")) {
            assertEquals("ok", resolver.resolve("{date format=\"$format\"}", { null }) { epoch }, UtilitiesFixture.scalars(format))
            assertEquals(UtilitiesFixture.scalars(format), UtilitiesFixture.scalars(seen))
        }
        // A closing apostrophe that carries a mark closes nothing: Swift compares Characters.
        val unbalanced = "{date format=\"'x'\u0301\"}"
        assertEquals(unbalanced, resolver.resolve(unbalanced, { null }) { epoch })
    }

    // Fuzzing

    private val fragments = listOf(
        "{", "}", "{", "}", "date", "time", "datetime", "clipboard", ":", " ", "  ", "\"", "'", "''", "=", "format", "locale", "offset", "format=\"", "locale=\"",
        "offset=", "yyyy", "MM", "dd", "HH:mm", "EEEE", "T", "p", "+1d", "-2h", "+100000y", "-100000M", "+100001d", "+", "-", "1", "d", "M", "y", "m", "h", "w",
        "en-US", "fr", "th-TH-u-ca-gregory", "ar-SA", "fa-IR", "xx", "en_US", "en-US-u-hc-h23", "ja-JP-u-ca-japanese", "\u0301", "é", "🔑", "\r", "\n", "\r\n",
        "\u2028", "\u0000", "\uD83D", "\uDD11", "\t", "\u00A0", "x",
        "{date}", "{clipboard}", "{time:HH}", "{date offset=+1M}", "{datetime locale=\"fr\"}", "{date \"yyyy\"}",
    )

    /**
     * Arbitrary templates through every entry point, in three environments, with dates
     * from 1 AD to the year 100 000: never an exception, a template without a live
     * placeholder comes back unchanged, and the preview is the expansion or its cut.
     */
    @Test
    fun arbitraryTemplatesNeverThrow() {
        val random = SeededRandom(0x71ACE)
        val nows = doubleArrayOf(epoch, 0.0, -63_113_904_000.0, 3e12, -1e9, 1e18, Double.NaN, 825_465_600.75)
        var resolvedSomething = 0
        repeat(40_000) { round ->
            val template = when (round % 4) {
                0 -> buildString { repeat(random.int(14)) { append(random.pick(fragments)) } }
                1 -> "{" + random.pick(listOf("date", "time", "datetime")) + random.pick(listOf(" ", ":", " \"", "")) +
                    buildString { repeat(random.int(8)) { append(random.pick(fragments.subList(4, fragments.size))) } } + random.pick(listOf("}", "\"}", ""))
                2 -> "{date " + (0 until 1 + random.int(4)).joinToString(random.pick(listOf(" ", "  ", ""))) {
                    random.pick(listOf("format", "locale", "offset", "x")) + "=" + random.pick(listOf("\"", "")) +
                        buildString { repeat(random.int(4)) { append(random.pick(fragments.subList(20, fragments.size))) } } + random.pick(listOf("\"", ""))
                } + "}"
                else -> buildString { repeat(random.int(5)) { append("{").append(random.pick(fragments)).append(random.pick(fragments)).append("}").append(random.pick(fragments)) } }
            }
            val world = worlds[round % worlds.size]
            val now = nows[random.int(nows.size)]
            val label = UtilitiesFixture.scalars(template)
            try {
                var reads = 0
                val resolved = world.resolver.resolve(template, { reads += 1; "Clip {date}" }) { now }
                val contains = world.resolver.containsResolvablePlaceholder(template)
                val containsClipboard = world.resolver.containsClipboardPlaceholder(template)
                val isPlaceholder = world.resolver.isResolvablePlaceholder(template)
                val preview = world.resolver.resolveForPreview(template, { "Clip {date}" }) { now }
                RaycastPlaceholders.converted(template)

                if (!contains) assertEquals(template, resolved, label) else resolvedSomething += 1
                assertEquals(containsClipboard, reads > 0, label)
                if (containsClipboard || isPlaceholder) assertTrue(contains, label)
                if (FoundationText.characterCount(resolved) <= 1_000) assertEquals(resolved, preview, label)
                // The converter only ever produces something the resolver reads, and never grows the set of dead tokens.
                assertEquals(RaycastPlaceholders.converted(template), RaycastPlaceholders.converted(RaycastPlaceholders.converted(template)), label)
            } catch (failure: AssertionError) {
                throw failure
            } catch (other: Throwable) {
                fail("${other::class.simpleName}: ${other.message} for $label at $now")
            }
        }
        assertTrue(resolvedSomething > 4_000, "the generator should produce live placeholders, got $resolvedSomething")
    }

    /** Patterns and instants at random straight into the renderer: text out, never an exception. */
    @Test
    fun arbitraryPatternsAndInstantsNeverThrowInTheRenderer() {
        val random = SeededRandom(0xDA7E)
        val letters = "GyMdkHmsSEDFwWahKzYeugAZvcLQqVUOXxrbBlCIJNPRTfijnopt'' -:/.,年😀\u0301\"{}\n"
        val locales = listOf("en-US", "fr-FR", "th-TH", "ar-SA", "fa-IR", "ja-JP-u-ca-japanese", "zh-Hant-TW", "en-US-u-ca-roc", "en-US-u-ca-islamic-umalqura", "he-IL-u-ca-hebrew", "und", "tr-TR-u-nu-arab", "en-US-u-hc-h11")
        val zones = listOf("UTC", "Europe/Paris", "America/St_Johns", "Asia/Kathmandu", "Pacific/Kiritimati", "Antarctica/Troll", "+13:45", "-18:00")
        val styles = DateRenderer.Style.entries
        val units = DateRenderer.Unit.entries
        repeat(30_000) {
            val renderer = JvmDateRenderer(Locale.forLanguageTag(random.pick(locales)), ZoneId.of(random.pick(zones)))
            val instant = when (random.int(6)) {
                0 -> random.next()
                1 -> Long.MAX_VALUE - random.int(1000)
                2 -> Long.MIN_VALUE + random.int(1000)
                3 -> random.next() % 4_000_000_000_000L
                else -> random.next() % 300_000_000_000_000L
            }
            val pattern = buildString { repeat(random.int(12)) { append(random.pick(letters.toList()).toString().repeat(1 + random.int(if (random.int(9) == 0) 30 else 5))) } }
            try {
                renderer.format(instant, pattern)
                renderer.format(instant, random.pick(styles), random.pick(styles), if (random.bool()) null else random.pick(locales))
                val moved = renderer.add(instant, random.pick(units), random.int(200_001) - 100_000)
                if (moved != null) renderer.format(moved, "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX G")
                assertEquals(IcuDatePattern.formattablePrefix(pattern), IcuDatePattern.formattablePrefix(IcuDatePattern.formattablePrefix(pattern)))
            } catch (failure: AssertionError) {
                throw failure
            } catch (other: Throwable) {
                fail("${other::class.simpleName}: ${other.message} for ${UtilitiesFixture.scalars(pattern)} at $instant")
            }
        }
    }
}
