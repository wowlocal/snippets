package com.khm.snippets.core.search

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetDisplayOrder
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.SeededRandom
import java.util.Locale
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `Tests/Core/SnippetSearchIndexTests.swift`, the L04 search vectors, the Swift tag order
 * and properties of the index. The Swift pipeline tests have no counterpart: the
 * latest-wins worker is the app's coroutine, not part of `:core`.
 */
class SnippetSearchIndexTest {

    private val english = SnippetLibraryProjection.collatingTagOrder(Locale.US)

    private fun snippet(
        name: String,
        keyword: String,
        content: String,
        tags: List<String> = emptyList(),
        isPinned: Boolean = false,
        id: UUID = UUID.randomUUID(),
        createdAt: Double = AppleTime.now(),
    ) = Snippet(id, name, keyword, content, tags, isPinned = isPinned, createdAt = createdAt, updatedAt = createdAt)

    @Test
    fun searchPreservesInputOrderAndMatchesEveryField() {
        val first = snippet("Café Reply", "respond-now", "Bonjour from Paris", listOf("Work", "Urgent"), isPinned = true)
        val second = snippet("Résumé", "career", "Experience and education", listOf("Personal"))
        val third = snippet("Status", "weekly", "Everything is green", listOf("Work"))
        val index = SnippetSearchIndex()
        val snippets = listOf(first, second, third)

        assertEquals(snippets, index.results(snippets, "", emptySet()))
        assertEquals(listOf(first), index.results(snippets, "reply", emptySet()))
        assertEquals(listOf(first), index.results(snippets, "respond", emptySet()))
        assertEquals(listOf(first), index.results(snippets, "from par", emptySet()))
        assertEquals(listOf(first), index.results(snippets, "urgent", emptySet()))
    }

    @Test
    fun searchIsCaseAndDiacriticInsensitiveAndTrimsQuery() {
        val snippet = snippet("CAFÉ Notes", "Résumé", "À bientôt", listOf("Crème Brûlée"))
        val index = SnippetSearchIndex()
        for (query in listOf("  cafe\n", "resume", "A BIENTOT", "creme brulee")) {
            assertEquals(listOf(snippet), index.results(listOf(snippet), query, emptySet()), "expected \"$query\" to match")
        }
    }

    @Test
    fun tagFiltersUseAndSemanticsAndCanonicalKeys() {
        val both = snippet("Both", "both", "", listOf("Wörk", "Urgent"))
        val work = snippet("Work", "work", "", listOf("WORK"))
        val personal = snippet("Personal", "personal", "", listOf("Personal"))
        val index = SnippetSearchIndex()
        val workKey = SnippetTagging.filterKey("work")
        val urgentKey = SnippetTagging.filterKey("URGENT")
        val snippets = listOf(both, work, personal)

        assertEquals(listOf(both, work), index.results(snippets, "", setOf(workKey)))
        assertEquals(listOf(both), index.results(snippets, "", setOf(workKey, urgentKey)))
        assertEquals(listOf(both, work), SnippetSearchSnapshot.resultsForEmptySearch(snippets, setOf(workKey)))
        assertEquals(listOf(both), SnippetSearchSnapshot.resultsForEmptySearch(snippets, setOf(workKey, urgentKey)))
        assertSame(snippets, SnippetSearchSnapshot.resultsForEmptySearch(snippets, emptySet()))
        // A key in another normalization form is the same key, as in a Swift Set.
        val cafe = snippet("Cafe", "c", "", listOf("가"))
        assertEquals(listOf(cafe), index.results(listOf(cafe), "c", setOf("\u1100\u1161")))
    }

    @Test
    fun repeatedQueriesReuseNormalizedFieldsAndRelevantChangesInvalidateExactlyOneEntry() {
        val first = snippet("First", "one", "shared phrase")
        var second = snippet("Second", "two", "other phrase")
        val index = SnippetSearchIndex()

        index.results(listOf(first, second), "shared", emptySet())
        assertEquals(2, index.statistics.normalizedEntryBuildCount)
        assertEquals(2, index.statistics.lastSnapshotEntryBuildCount)

        index.results(listOf(first, second), "other", emptySet())
        assertEquals(2, index.statistics.normalizedEntryBuildCount)
        assertEquals(0, index.statistics.lastSnapshotEntryBuildCount)

        // A change of presentation alone returns the current value without refolding text.
        second = second.copy(isPinned = true)
        val pinned = index.results(listOf(first, second), "other", emptySet())
        assertTrue(pinned.single().isPinned)
        assertEquals(2, index.statistics.normalizedEntryBuildCount)
        assertEquals(0, index.statistics.lastSnapshotEntryBuildCount)

        // The text fields, not updatedAt, decide what is refolded.
        second = second.copy(content = "replacement phrase")
        assertEquals(listOf(second), index.results(listOf(first, second), "replacement", emptySet()))
        assertEquals(3, index.statistics.normalizedEntryBuildCount)
        assertEquals(1, index.statistics.lastSnapshotEntryBuildCount)
    }

    @Test
    fun removedEntriesAreNotRetainedAndNewEntriesAreNormalizedOnce() {
        val first = snippet("First", "first", "one")
        val second = snippet("Second", "second", "two")
        val index = SnippetSearchIndex()

        index.results(listOf(first, second), "", emptySet())
        index.results(listOf(second), "", emptySet())
        assertEquals(2, index.statistics.normalizedEntryBuildCount)
        assertEquals(0, index.statistics.lastSnapshotEntryBuildCount)

        val replacement = snippet("Replacement", "new", "three")
        index.results(listOf(second, replacement), "", emptySet())
        assertEquals(3, index.statistics.normalizedEntryBuildCount)
        assertEquals(1, index.statistics.lastSnapshotEntryBuildCount)
    }

    /**
     * Replaces `testLocaleChangeInvalidatesNormalizedEntries`: Swift refolds when the
     * user's locale changes; Android's fold does not depend on a locale at all, including
     * the JVM's default.
     */
    @Test
    fun foldingDoesNotFollowTheDefaultLocale() {
        val snippet = snippet("ISTANBUL TITLE", "city", "")
        val previous = Locale.getDefault()
        try {
            for (tag in listOf("en-US", "tr-TR", "az-AZ", "lt-LT")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                val index = SnippetSearchIndex()
                assertEquals(listOf(snippet), index.results(listOf(snippet), "istanbul", emptySet()), tag)
                assertEquals(listOf(snippet), index.results(listOf(snippet), "TITLE", emptySet()), tag)
                assertEquals("istanbul", SnippetSearchSnapshot.normalizedQuery(" İSTANBUL "), tag)
                assertTrue(FuzzyMatch.score("title", "TITLE").matched, tag)
            }
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun secureShellSearchNeverRequiresPlaintextContent() {
        val secureShell = snippet("Private Token", "token", "", listOf("Secrets"))
        val index = SnippetSearchIndex()
        assertEquals(listOf(secureShell), index.results(listOf(secureShell), "private", emptySet()))
        assertTrue(index.results(listOf(secureShell), "decrypted body", emptySet()).isEmpty())
    }

    @Test
    fun normalizedPayloadIsBoundedAndOverflowStillSearchesCorrectly() {
        val index = SnippetSearchIndex(maximumNormalizedUnits = 1_024)
        val small = snippet("Small", "small", "short")
        val oversized = snippet("Large", "large", "bounded searchable body ".repeat(100))

        assertEquals(listOf(oversized), index.results(listOf(small, oversized), "searchable body", emptySet()))
        assertTrue(index.statistics.estimatedNormalizedUnits <= 1_024)
        assertEquals(1, index.statistics.uncachedEntryCount)

        val builds = index.statistics.normalizedEntryBuildCount
        assertEquals(listOf(oversized), index.results(listOf(small, oversized), "bounded", emptySet()))
        assertEquals(builds, index.statistics.normalizedEntryBuildCount, "an identical library must reuse its bounded snapshot")
    }

    @Test
    fun fuzzyMetadataAndLiteralBodiesIncludingUncachedFallback() {
        val name = snippet("Project Alpha", "", "")
        val keyword = snippet("Shortcut", "project-alpha", "")
        val tag = snippet("Tagged", "", "", listOf("Project Alpha"))
        val body = snippet("Body", "", "Project Alpha")
        val unnamed = snippet("", "", "Project Alpha")
        val snippets = listOf(name, keyword, tag, body, unnamed)
        for (budget in listOf(0, 1_000_000)) {
            val index = SnippetSearchIndex(maximumNormalizedUnits = budget)
            assertEquals(listOf(name, keyword, tag), index.results(snippets, "prjal", emptySet()), "budget $budget")
            assertEquals(snippets, index.results(snippets, "project", emptySet()), "budget $budget")
            assertTrue(index.results(snippets, "ajrp", emptySet()).isEmpty(), "budget $budget")
            assertEquals(if (budget == 0) 5 else 0, index.statistics.uncachedEntryCount)
        }
    }

    @Test
    fun prefixNarrowingRetainsUnfilteredMatchesAndInvalidatesOnEdits() {
        val work = snippet("Alpha", "", "", listOf("work"))
        val home = snippet("Alpine", "", "", listOf("home"))
        var third = snippet("Beta", "", "")
        var snippets = listOf(work, home, third)
        val index = SnippetSearchIndex()
        assertEquals(listOf(work), index.results(snippets, "al", setOf("work")))
        assertEquals(3, index.statistics.lastCandidateCount)
        assertEquals(listOf(work, home), index.results(snippets, "alp", emptySet()))
        assertEquals(2, index.statistics.lastCandidateCount)
        assertEquals(snippets, index.results(snippets, "a", emptySet()))
        assertEquals(3, index.statistics.lastCandidateCount, "backspace must reconsider excluded rows")
        index.results(snippets, "alp", emptySet())
        third = third.copy(name = "Alpaca")
        snippets = listOf(work, home, third)
        assertEquals(listOf(third), index.results(snippets, "alpac", emptySet()))
        assertEquals(3, index.statistics.lastCandidateCount, "an edit invalidates the candidate set")
        assertEquals(listOf(home), index.results(snippets, "ine", emptySet()))
        assertEquals(3, index.statistics.lastCandidateCount, "a replaced query is not a prefix extension")
    }

    @Test
    fun presentationProjectionCachesOrderAndTagsButReturnsCurrentPayload() {
        val projection = SnippetLibraryProjection(english)
        var first = snippet("Ordinary", "ordinary", "Before", listOf("Work"))
        val secure = snippet("Secure shell", "secure", "", listOf("wörk"), isPinned = true)
        val original = projection.snapshot(listOf(first), listOf(secure))
        assertEquals(listOf(secure, first), original.sorted)
        assertEquals(listOf("Work"), original.tags)
        assertEquals(listOf(2), original.tagUsage.map { it.count })
        assertEquals(setOf("work"), original.tagKeys)
        assertSame(original, projection.snapshot(listOf(first), listOf(secure)))
        assertEquals(1, projection.buildCount)
        first = first.copy(content = "After")
        val edited = projection.snapshot(listOf(first), emptyList())
        assertEquals(listOf(first), edited.sorted)
        assertEquals(listOf(1), edited.tagUsage.map { it.count })
        assertEquals("Before", original.sorted.last().content)
        assertEquals(2, projection.buildCount)
    }

    // L04

    private fun snippet(case: SwiftVectors.Case): Snippet {
        val content = case.string("content")
        assertContentEquals(case.bytes("contentUtf8Hex"), content.toByteArray(), case.label)
        return Snippet(
            Uuids.parseLowercase(case.string("id")) ?: fail("${case.label}: bad id"),
            case.string("name"), case.string("keyword"), content, case.strings("tags"),
            case.boolean("isEnabled"), case.boolean("isPinned"), case.double("createdAt"), case.double("updatedAt"),
        )
    }

    private fun ids(snippets: List<Snippet>): List<String> = snippets.map { Uuids.lowercase(it.id) }

    @Test
    fun swiftVectorsL04LibraryProjection() {
        val library = SwiftVectors.cases("L04-search", "search-library").single()
        val ordinary = library.objects("ordinary").map(::snippet)
        val secure = library.objects("secureShells").map(::snippet)
        assertTrue(secure.all { it.content.isEmpty() })
        val snapshot = SnippetLibraryProjection(english).snapshot(ordinary, secure)
        assertEquals(library.strings("projectionSortedIDs"), ids(snapshot.sorted))
        assertEquals(library.strings("displayOrderIDs"), ids(SnippetDisplayOrder.sorted(ordinary + secure)))
        assertEquals(library.objects("tagUsage").map { it.string("tag") to it.int("count") }, snapshot.tagUsage.map { it.tag to it.count })
        assertEquals(library.strings("tagKeys").toSet(), snapshot.tagKeys)
    }

    @Test
    fun swiftVectorsL04Search() {
        val library = SwiftVectors.cases("L04-search", "search-library").single()
        val sorted = SnippetDisplayOrder.sorted(library.objects("ordinary").map(::snippet) + library.objects("secureShells").map(::snippet))
        val cases = SwiftVectors.cases("L04-search", "search")
        assertEquals(45, cases.size)
        val index = SnippetSearchIndex()
        val uncached = SnippetSearchIndex(maximumNormalizedUnits = 0)
        val query = SnippetLibraryQuery(english)
        for (case in cases) {
            val searchText = case.text("query")
            val tagKeys = case.strings("activeTagKeys").toSet()
            assertEquals(case.text("normalizedQuery"), SnippetSearchSnapshot.normalizedQuery(searchText), case.label)
            assertEquals(case.boolean("usesEmptySearchPath"), SnippetSearchSnapshot.normalizedQuery(searchText).isEmpty(), case.label)
            val wanted = case.strings("resultIDs")
            if (case.boolean("usesEmptySearchPath")) {
                assertEquals(wanted, ids(SnippetSearchSnapshot.resultsForEmptySearch(sorted, tagKeys)), case.label)
            } else {
                for (candidate in listOf(index, uncached)) {
                    val evaluation = candidate.evaluate(sorted, searchText, tagKeys)
                    assertEquals(case.strings("searchMatchIDs"), ids(evaluation.searchMatches), case.label)
                    assertEquals(wanted, ids(evaluation.snippets), case.label)
                }
                assertEquals(wanted, ids(SnippetSearchSnapshot.build(sorted).results(searchText, tagKeys)), case.label)
            }
            // The index gives the same answer for an empty query as the shortcut does.
            assertEquals(wanted, ids(index.results(sorted, searchText, tagKeys)), case.label)
            val results = query.results(sorted, searchText, tagKeys)
            assertEquals(wanted, ids(results.all.sortedWith(SnippetDisplayOrder.comparator)), case.label)
            assertTrue(results.pinned.all { it.isPinned } && results.snippets.none { it.isPinned }, case.label)
            assertEquals(wanted.isEmpty(), results.isEmpty, case.label)
        }
    }

    /**
     * The tag list of six libraries as Swift orders it under en_US. The first three and
     * the last use only letters and digits, where every collator agrees. The other two
     * order punctuation, emoji and scripts, which is collation data: Foundation and
     * Android use ICU's, a desktop JVM its own, so there only the tags and counts are compared.
     */
    @Test
    fun swiftTagUsageAndOrder() {
        val rows = UtilitiesFixture.rows("swift-tags.tsv")
        assertEquals(6, rows.size)
        val collationDataDependent = setOf("tags-3", "tags-4")
        var id = 0L
        fun snippets(field: String): List<Snippet> =
            if (field == "-") emptyList() else field.split('|').map { tags ->
                snippet("n", "", "", if (tags.isEmpty()) emptyList() else tags.split(';').map(UtilitiesFixture::text), id = UUID(0, ++id))
            }
        for (row in rows) {
            val snapshot = SnippetLibraryProjection.build(snippets(row[1]), snippets(row[2]), english)
            val wanted = row[3].split(';').map { UtilitiesFixture.text(it.substringBefore(':')) to it.substringAfter(':').toInt() }
            val actual = snapshot.tagUsage.map { it.tag to it.count }
            if (row[0] in collationDataDependent) assertEquals(wanted.toSet(), actual.toSet(), row[0]) else assertEquals(wanted, actual, row[0])
            assertEquals(row[4].split(';').map(UtilitiesFixture::text).toSet(), snapshot.tagKeys, row[0])
        }
    }

    // SnippetLibraryQuery

    /** `testLibraryQueryCombinesSearchAndTagFilters` in `snippets-ios-tests/SnippetsIOSTests.swift`. */
    @Test
    fun libraryQueryCombinesSearchAndTagFilters() {
        val pinned = snippet("Café Reply", "reply", "Hello", listOf("Work", "Urgent"), isPinned = true)
        val workOnly = snippet("Status", "status", "Café update", listOf("Work"))
        val personal = snippet("Café List", "coffee", "Beans", listOf("Personal"))
        val query = SnippetLibraryQuery(english)

        val unfiltered = query.results(listOf(pinned, workOnly, personal), "", emptySet())
        assertEquals(listOf(pinned.id), unfiltered.pinned.map { it.id })
        assertEquals(listOf(workOnly.id, personal.id), unfiltered.snippets.map { it.id })

        val filtered = query.results(listOf(pinned, workOnly, personal), "cafe", setOf("work", "urgent"))
        assertEquals(listOf(pinned.id), filtered.all.map { it.id })
    }

    @Test
    fun libraryReloadOrdersCountsTagsPrunesFiltersAndNeverSearchesSecureBodies() {
        val old = snippet("Old note", "old", "alpha body", listOf("Work"), createdAt = 10.0)
        val recent = snippet("New note", "new", "beta body", listOf("work", "Home"), createdAt = 30.0)
        val pinned = snippet("Pinned", "pin", "gamma", emptyList(), isPinned = true, createdAt = 5.0)
        val shell = snippet("Bank PIN", "bank", "", listOf("Secret", "HOME"), createdAt = 20.0)
        val query = SnippetLibraryQuery(english)

        val all = query.library(listOf(old, recent, pinned), listOf(shell), "", emptySet())
        assertEquals(listOf(pinned, recent, shell, old), all.sorted)
        assertEquals(listOf(pinned), all.results.pinned)
        assertEquals(listOf(recent, shell, old), all.results.snippets)
        assertEquals(listOf("Home" to 2, "Secret" to 1, "Work" to 2), all.tagUsage.map { it.tag to it.count })
        assertEquals(setOf("home", "secret", "work"), all.tagKeys)

        // A filter whose tag no longer exists is dropped instead of hiding everything.
        val pruned = query.library(listOf(old, recent, pinned), listOf(shell), "", setOf("home", "gone"))
        assertEquals(setOf("home"), pruned.activeTagKeys)
        assertEquals(listOf(recent, shell), pruned.results.all)

        val searched = query.library(listOf(old, recent, pinned), listOf(shell), " BODY ", setOf(SnippetLibraryQuery.tagKey("WORK")))
        assertEquals(listOf(recent, old), searched.results.all)

        // A shell that arrives with a body is neither matched by it nor returned with it.
        val leaking = shell.copy(content = "hunter2 secret body")
        val guarded = query.library(listOf(old), listOf(leaking), "hunter2", emptySet())
        assertTrue(guarded.results.isEmpty)
        val byName = query.library(listOf(old), listOf(leaking), "bank", emptySet())
        assertEquals(listOf(shell.id), byName.results.all.map { it.id })
        assertEquals("", byName.results.all.single().content)
        assertTrue(byName.sorted.none { it.content.contains("hunter2") })
    }

    // Properties

    private val words = listOf("alpha", "Beta", "gamma", "Délta", "straße", "日本", "🔑", "wi-fi", "x\u0301", "a\r\nb", "", " ", "Work", "home")

    private fun randomSnippet(random: SeededRandom): Snippet = snippet(
        name = if (random.int(5) == 0) "" else random.pick(words) + " " + random.pick(words),
        keyword = if (random.bool()) random.pick(words) else "",
        content = (0 until random.int(4)).joinToString("\n") { random.pick(words) + " " + random.pick(words) },
        tags = SnippetTagging.normalizedTags((0 until random.int(3)).map { random.pick(words) }),
        isPinned = random.int(4) == 0,
        id = random.uuid(),
        createdAt = random.int(50).toDouble(),
    )

    /** Which snippets match does not depend on the order they are given in, and results keep the given order. */
    @Test
    fun searchResultsAreStableUnderInputPermutation() {
        val random = SeededRandom(0x9E44)
        repeat(300) {
            val snippets = (0 until 1 + random.int(12)).map { randomSnippet(random) }
            val shuffled = snippets.toMutableList().apply {
                for (index in size - 1 downTo 1) {
                    val other = random.int(index + 1)
                    val moved = this[index]
                    this[index] = this[other]
                    this[other] = moved
                }
            }
            val searchText = if (random.int(6) == 0) "" else random.pick(words).take(1 + random.int(3))
            val tagKeys = if (random.int(3) == 0) setOf(SnippetTagging.filterKey(random.pick(words))) - "" else emptySet()

            val first = SnippetSearchIndex().evaluate(snippets, searchText, tagKeys)
            val second = SnippetSearchIndex(maximumNormalizedUnits = 0).evaluate(shuffled, searchText, tagKeys)
            assertEquals(first.snippets.map { it.id }.toSet(), second.snippets.map { it.id }.toSet())
            assertEquals(first.searchMatches.map { it.id }.toSet(), second.searchMatches.map { it.id }.toSet())
            // Order kept, and the tag filter only removes.
            assertEquals(snippets.filter { it in first.snippets }.map { it.id }, first.snippets.map { it.id })
            assertEquals(shuffled.filter { it in second.snippets }.map { it.id }, second.snippets.map { it.id })
            assertTrue(first.searchMatches.containsAll(first.snippets))

            // The whole reload is independent of the stored order.
            val query = SnippetLibraryQuery(english)
            val one = query.library(snippets, emptyList(), searchText, tagKeys)
            val two = SnippetLibraryQuery(english).library(shuffled, emptyList(), searchText, tagKeys)
            assertEquals(one.sorted.map { it.id }, two.sorted.map { it.id })
            assertEquals(one.results.all.map { it.id }, two.results.all.map { it.id })
            assertEquals(one.tagUsage.map { it.count }.sum(), two.tagUsage.map { it.count }.sum())
            assertEquals(one.tagKeys, two.tagKeys)
        }
    }

    /** A query that extends the previous one is answered from that scan's matches, with the same result as a fresh scan. */
    @Test
    fun narrowedScansEqualFreshScans() {
        val random = SeededRandom(0x4A11)
        repeat(200) {
            val snippets = (0 until 1 + random.int(15)).map { randomSnippet(random) }
            val index = SnippetSearchIndex()
            val word = random.pick(words) + random.pick(words)
            for (length in 1..minOf(word.length, 6)) {
                val searchText = word.substring(0, length)
                assertEquals(
                    SnippetSearchSnapshot.build(snippets).results(searchText, emptySet()).map { it.id },
                    index.results(snippets, searchText, emptySet()).map { it.id },
                    UtilitiesFixture.scalars(searchText),
                )
            }
        }
    }

    /**
     * The corpus and queries of `Tests/Harnesses/LibrarySearchBenchmark.swift`
     * (`scripts/benchmark-library-search.sh`): 10 000 snippets with 512-byte bodies, each
     * measured query typed one character after the previous one. Typing has to stay
     * interactive; the bounds are loose so that a busy machine does not fail the build.
     */
    @Test
    fun tenThousandSnippetsStayInteractive() {
        fun body(count: Int): String = "abcdefghijklmnopqrstuvwxyz ".repeat((count + 26) / 27).substring(0, count)
        val snippets = (0 until 10_000).map { i ->
            snippet(
                name = "${if (i % 5 == 0) "Ghost" else "Project"} $i",
                keyword = "${if (i % 5 == 0) "ghost" else "project"}.$i",
                content = body(512) + i,
                tags = listOf("Work", "tag${i % 8}"),
                isPinned = i % 9 == 0,
                id = UUID(7, i.toLong()),
                createdAt = AppleTime.fromUnixSeconds(i.toDouble()),
            )
        }
        val index = SnippetSearchIndex()
        val projection = SnippetLibraryProjection(english)

        val coldStart = System.nanoTime()
        val initial = projection.snapshot(snippets, emptyList())
        index.results(initial.sorted, "g", emptySet())
        val prepareMillis = (System.nanoTime() - coldStart) / 1e6

        val report = StringBuilder("library rows=10000 body_bytes=512 prepare=%.1fms".format(Locale.ROOT, prepareMillis))
        var worstMedian = 0.0
        for (query in listOf("g", "gh", "gho", "ghost", "ghx", "zz")) {
            val times = ArrayList<Double>()
            var count = 0
            repeat(23) { iteration ->
                index.results(initial.sorted, query.dropLast(1), emptySet())
                val start = System.nanoTime()
                val snapshot = projection.snapshot(snippets, emptyList())
                count = index.results(snapshot.sorted, query, emptySet()).size
                val elapsed = (System.nanoTime() - start) / 1e6
                if (iteration >= 3) times.add(elapsed)
            }
            times.sort()
            val median = times[times.size / 2]
            val p95 = times[Math.ceil(times.size * 0.95).toInt() - 1]
            worstMedian = maxOf(worstMedian, median)
            report.append("\n  query=%s matches=%d median=%.2fms p95=%.2fms".format(Locale.ROOT, query, count, median, p95))
            // Every body holds "fgh"; only the 2 000 "Ghost" names hold "gho".
            val wanted = when (query) {
                "g", "gh" -> 10_000
                "gho", "ghost" -> 2_000
                else -> 0
            }
            assertEquals(wanted, count, query)
        }

        // One edited snippet refolds one entry, not ten thousand.
        val edited = snippets.toMutableList().also { it[4_321] = it[4_321].copy(content = "edited body") }
        val editStart = System.nanoTime()
        val afterEdit = index.results(projection.snapshot(edited, emptyList()).sorted, "edited", emptySet())
        val editMillis = (System.nanoTime() - editStart) / 1e6
        assertEquals(1, afterEdit.size)
        assertEquals(1, index.statistics.lastSnapshotEntryBuildCount)
        assertEquals(1, projection.buildCount - 1)
        report.append("\n  one edit, then query: %.1fms".format(Locale.ROOT, editMillis))
        report.append("\n  folded text held: %d UTF-16 units".format(Locale.ROOT, index.statistics.estimatedNormalizedUnits))
        println(report)

        assertTrue(prepareMillis < 5_000, "indexing 10 000 snippets took $prepareMillis ms")
        assertTrue(worstMedian < 250, "a query over 10 000 snippets took $worstMedian ms (median)")
        assertTrue(editMillis < 2_000, "an edit and a query took $editMillis ms")
    }
}
