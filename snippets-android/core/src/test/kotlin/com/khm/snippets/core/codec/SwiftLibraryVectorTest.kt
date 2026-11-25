package com.khm.snippets.core.codec

import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetDisplayOrder
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/** `L01-library-json`: `snippets.json` bytes, decode outcomes, display order and display names from Swift. */
class SwiftLibraryVectorTest {

    private val file = "L01-library-json"

    private fun snippet(case: SwiftVectors.Case): Snippet {
        val content = case.string("content")
        assertContentEquals(case.bytes("contentUtf8Hex"), content.toByteArray(), case.label)
        return Snippet(
            Uuids.parseLowercase(case.string("id")) ?: fail("${case.label}: bad id"),
            case.string("name"), case.string("keyword"), content, case.strings("tags"),
            case.boolean("isEnabled"), case.boolean("isPinned"), case.double("createdAt"), case.double("updatedAt"),
        )
    }

    private fun assertSameSnippets(expected: List<Snippet>, actual: List<Snippet>, label: String) {
        assertEquals(expected, actual, label)
        // Snippet equality is canonical equivalence; the vectors pin the exact scalars and bits too.
        for ((want, got) in expected.zip(actual)) {
            assertEquals(listOf(want.name, want.keyword, want.content, want.tags), listOf(got.name, got.keyword, got.content, got.tags), label)
            assertEquals(want.createdAt.toRawBits(), got.createdAt.toRawBits(), label)
            assertEquals(want.updatedAt.toRawBits(), got.updatedAt.toRawBits(), label)
        }
    }

    @Test
    fun encodeWritesTheBytesFoundationWrites() {
        val cases = SwiftVectors.cases(file, "encode")
        assertEquals(3, cases.size)
        for (case in cases) {
            val snippets = case.objects("snippets").map(::snippet)
            val bytes = when (case.string("shape")) {
                "array" -> SnippetLibraryCodec.encode(snippets)
                "collection" -> SnippetLibraryCodec.encodeCollection(snippets)
                else -> fail("${case.label}: unknown shape")
            }
            assertEquals(case.string("fileText"), String(bytes, Charsets.UTF_8), case.label)
            assertContentEquals(case.bytes("fileHex"), bytes, case.label)
            assertEquals(case.string("digest"), SnippetLibraryCodec.digest(bytes), case.label)
            assertSameSnippets(snippets, SnippetLibraryCodec.decode(bytes), case.label)
        }
    }

    @Test
    fun decodeAcceptsAndRefusesWhatSwiftDoes() {
        val cases = SwiftVectors.cases(file, "decode")
        assertEquals(34, cases.size)
        for (case in cases) {
            val data = case.bytes("fileHex")
            assertEquals(case.string("digest"), SnippetLibraryCodec.digest(data), case.label)
            val actual = try {
                SnippetLibraryCodec.decode(data) { fail("${case.label}: no record here lacks createdAt") }
            } catch (_: SnippetLibraryCodec.Unreadable) {
                null
            }
            if (case.has("error")) {
                assertEquals("SnippetLibraryCodec.Failure.unreadable", case.string("error").substringAfter("SnippetsCore."), case.label)
                if (actual != null) fail("${case.label}: Swift refuses this, Kotlin decoded ${actual.size} snippets")
            } else {
                if (actual == null) fail("${case.label}: Swift decodes this, Kotlin refuses it")
                assertSameSnippets(case.objects("ok").map(::snippet), actual, case.label)
            }
        }
    }

    /** A record without `createdAt` gets the decode time in Swift; the vector records the relationships, the clock is injected here. */
    @Test
    fun missingDatesDefaultToTheInjectedClock() {
        val cases = SwiftVectors.cases(file, "decode-defaults")
        assertEquals(2, cases.size)
        val now = 812_578_800.125
        for (case in cases) {
            var reads = 0
            val snippet = SnippetLibraryCodec.decode(case.string("fileText").toByteArray()) { reads += 1; now }.single()
            assertTrue(case.boolean("createdAtIsDecodeTime"), case.label)
            assertEquals(now, snippet.createdAt, case.label)
            assertEquals(1, reads, case.label)
            if (case.has("updatedAtEqualsCreatedAt")) {
                assertEquals(case.boolean("updatedAtEqualsCreatedAt"), snippet.updatedAt == snippet.createdAt, case.label)
                assertEquals(case.strings("tags"), snippet.tags, case.label)
                assertEquals(case.boolean("isEnabled"), snippet.isEnabled, case.label)
                assertEquals(case.boolean("isPinned"), snippet.isPinned, case.label)
            }
            if (case.has("updatedAt")) assertEquals(case.double("updatedAt").toRawBits(), snippet.updatedAt.toRawBits(), case.label)
        }
    }

    @Test
    fun displayOrderIsSwifts() {
        val case = SwiftVectors.cases(file, "display-order").single()
        val input = case.objects("input").map {
            Snippet(Uuids.parseLowercase(it.string("id"))!!, "", "", "", isPinned = it.boolean("isPinned"), createdAt = it.double("createdAt"), updatedAt = 0.0)
        }
        val expected = case.strings("sortedIDs")
        assertEquals(expected, SnippetDisplayOrder.sorted(input).map { Uuids.lowercase(it.id) }, case.label)
        assertEquals(expected, SnippetDisplayOrder.sorted(input.reversed()).map { Uuids.lowercase(it.id) }, case.label)
    }

    @Test
    fun displayNamesAndFirstLinesAreSwifts() {
        val cases = SwiftVectors.cases(file, "display")
        assertEquals(14, cases.size)
        for (case in cases) {
            val snippet = Snippet(name = case.text("snippetName"), keyword = "", content = case.text("content"))
            assertEquals(case.text("displayName"), snippet.displayName, case.label)
            assertEquals(case.text("contentFirstLine"), snippet.contentFirstLine, case.label)
            assertEquals(case.text("contentFirstLineUntruncated"), snippet.contentFirstLineUntruncated, case.label)
        }
    }

    /** Every kind in the file is either tested above or named here as someone else's. */
    @Test
    fun everyKindIsAccountedFor() {
        val kinds = SwiftVectors.cases(file).groupingBy { it.kind }.eachCount()
        // secure-shell is VaultRecord.shell, which belongs to the vault port.
        assertEquals(setOf("encode", "decode", "decode-defaults", "display-order", "display", "secure-shell"), kinds.keys)
        assertEquals(55, kinds.values.sum())
    }
}
