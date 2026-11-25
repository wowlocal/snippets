package com.khm.snippets.core.interchange

import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.search.UtilitiesFixture
import com.khm.snippets.core.text.SeededRandom
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `Tests/Core/SnippetImportParserTests.swift`, the JSON half of
 * `snippets-ios-tests/IncomingDocumentLoaderTests.swift`, the export round trip of
 * `SnippetsIOSTests.swift` and the L06 import vectors.
 */
class SnippetImportParserTest {

    private fun utf8(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

    @Test
    fun nativeExportRoundTripsWithoutRaycastPrompt() {
        val expected = Snippet(name = "Résumé", keyword = "hello", content = "Body", tags = listOf("Work"))
        val prepared = SnippetImportParser.parse(SnippetLibraryCodec.encode(listOf(expected)))
        assertEquals(listOf(expected), prepared.snippets)
        assertEquals(listOf(expected), prepared.snippetsPreservingExclamationPrefix)
        assertFalse(prepared.hasRaycastExclamationKeywords)
    }

    @Test
    fun raycastPayloadIsDecodedOnceWithBothKeywordChoices() {
        val prepared = SnippetImportParser.parse(utf8("""[{"name":"Signature","keyword":"!sig","text":"Hello {clipboard}"}]"""))
        assertTrue(prepared.hasRaycastExclamationKeywords)
        assertEquals("sig", prepared.snippets.first().keyword)
        assertEquals("!sig", prepared.snippetsPreservingExclamationPrefix.first().keyword)
        assertEquals("Hello {clipboard}", prepared.snippets.first().content)
        assertEquals(prepared.snippets, prepared.snippets(preservingExclamationPrefix = false))
        assertEquals(prepared.snippetsPreservingExclamationPrefix, prepared.snippets(preservingExclamationPrefix = true))
    }

    @Test
    fun malformedDocumentIsRejectedAndEmptyNativeArrayRemainsAValidParse() {
        assertFailsWith<SnippetImportParser.InvalidFormat> { SnippetImportParser.parse(utf8("not json")) }
        assertTrue(SnippetImportParser.parse(utf8("[]")).snippets.isEmpty())
    }

    /** `testOrdinaryJSONIsLoadedAndPrepared` and `testOversizedFileIsRejectedBeforeItIsRead`, for the bytes the app has read. */
    @Test
    fun ordinaryJsonIsPreparedAndAnOversizedDocumentIsRejectedBeforeItIsParsed() {
        val prepared = SnippetImportParser.parseBounded(utf8("""[{"name":"Greeting","text":"Hello","keyword":"hi"}]"""))
        assertEquals(listOf("Greeting"), prepared.snippets.map { it.name })

        assertEquals(16 * 1024 * 1024, SnippetImportParser.MAXIMUM_JSON_BYTES)
        assertEquals(32 * 1024 * 1024, SnippetImportParser.MAXIMUM_FILE_BYTES)
        // Not JSON at all: were it parsed, the failure would be InvalidFormat.
        val oversized = ByteArray(SnippetImportParser.MAXIMUM_JSON_BYTES + 1) { 'x'.code.toByte() }
        assertEquals(SnippetImportParser.MAXIMUM_JSON_BYTES, assertFailsWith<SnippetImportParser.TooLarge> { SnippetImportParser.parseBounded(oversized) }.maximumBytes)
        val exactlyAtTheLimit = ByteArray(64) { ' '.code.toByte() }.also { it[0] = '['.code.toByte(); it[63] = ']'.code.toByte() }
        assertTrue(SnippetImportParser.parseBounded(exactlyAtTheLimit, maximumBytes = 64).snippets.isEmpty())
        assertFailsWith<SnippetImportParser.TooLarge> { SnippetImportParser.parseBounded(exactlyAtTheLimit, maximumBytes = 63) }
        assertFailsWith<SnippetImportParser.InvalidFormat> { SnippetImportParser.parseBounded(utf8("not json")) }
    }

    /**
     * `testExportExcludesSecureShells` and `testImportingTheSameExportTwiceCreatesNoDuplicates`,
     * as far as they concern the file: the export is the wrapped dialect, holds exactly
     * what it was given, and reads back to the same records with the same ids every time.
     */
    @Test
    fun theExportIsTheWrappedDialectAndReadsBackIdentically() {
        val ordinary = listOf(
            Snippet(UUID(1, 2), "Email signature", "sig", "Best regards,\nMichael", listOf("Work", "mail"), true, false, 100.0, 250.5),
            Snippet(UUID(3, 4), "", "", "Café / ☕ \"quoted\"", emptyList(), false, true, 90.0, 90.0),
        )
        val file = SnippetExport.encode(ordinary)
        assertContentEquals(SnippetLibraryCodec.encodeCollection(ordinary), file)
        val text = String(file, Charsets.UTF_8)
        assertTrue(text.startsWith("{\n  \"snippets\" : [\n    {\n      \"content\" : \"Best regards,\\nMichael\","), text)
        assertTrue(text.endsWith("\n  ]\n}"))
        assertEquals("Snippets-Export.json", SnippetExport.FILE_NAME)

        val first = SnippetImportParser.parse(file)
        val second = SnippetImportParser.parse(file)
        assertEquals(ordinary, first.snippets)
        assertEquals(first.snippets, second.snippets)
        assertFalse(first.hasRaycastExclamationKeywords)
        assertEquals("{\n  \"snippets\" : [\n\n  ]\n}", String(SnippetExport.encode(emptyList()), Charsets.UTF_8))
        assertFailsWith<SnippetLibraryCodec.NotEncodable> { SnippetExport.encode(listOf(ordinary[0].copy(createdAt = Double.NaN))) }
    }

    @Test
    fun raycastItemsBecomeNewRecordsStampedOncePerRecord() {
        var clock = 1000.0
        var nextId = 0L
        val prepared = SnippetImportParser.parse(
            utf8("""[{"name":"A","text":"a {date \"yyyy\"}","keyword":" \\!!x y "},{"name":"B","text":"b"}]"""),
            now = { clock++ }, newId = { UUID(9, ++nextId) },
        )
        // The reading that keeps `!` is built first; the two readings of an item do not share an id.
        assertEquals(listOf(UUID(9, 1), UUID(9, 2)), prepared.snippetsPreservingExclamationPrefix.map { it.id })
        assertEquals(listOf(UUID(9, 3), UUID(9, 4)), prepared.snippets.map { it.id })
        assertEquals(listOf(1000.0, 1001.0), prepared.snippetsPreservingExclamationPrefix.map { it.createdAt })
        for (snippet in prepared.snippets + prepared.snippetsPreservingExclamationPrefix) {
            assertEquals(snippet.createdAt.toRawBits(), snippet.updatedAt.toRawBits())
            assertTrue(snippet.isEnabled && !snippet.isPinned && snippet.tags.isEmpty())
        }
        assertEquals(listOf("!!x-y", ""), prepared.snippetsPreservingExclamationPrefix.map { it.keyword })
        assertEquals(listOf("!x-y", ""), prepared.snippets.map { it.keyword })
        assertEquals("a {date format=\"yyyy\"}", prepared.snippets[0].content)
        assertTrue(prepared.hasRaycastExclamationKeywords)
    }

    private fun describeNative(snippet: Snippet): List<Any?> = listOf(
        Uuids.lowercase(snippet.id), snippet.name, snippet.keyword, snippet.content, snippet.tags, snippet.isEnabled, snippet.isPinned,
        snippet.createdAt.toRawBits(), snippet.updatedAt.toRawBits(),
    )

    private fun describeRaycast(snippet: Snippet): List<Any?> =
        listOf(snippet.name, snippet.keyword, snippet.content, snippet.tags, snippet.isEnabled, snippet.isPinned)

    @Test
    fun swiftVectorsL06Import() {
        val cases = SwiftVectors.cases("L06-keywords-import-links", "import")
        assertEquals(18, cases.size)
        for (case in cases) {
            val data = utf8(case.string("fileText"))
            if (case.has("error")) {
                assertEquals("SnippetImportParser.Failure.invalidFormat", case.string("error"), case.label)
                assertFailsWith<SnippetImportParser.InvalidFormat>(case.label) { SnippetImportParser.parse(data) }
                continue
            }
            val prepared = SnippetImportParser.parse(data, now = { 5.0 })
            assertEquals(case.boolean("hasRaycastExclamationKeywords"), prepared.hasRaycastExclamationKeywords, case.label)
            // The emitter records ids and dates only for files that hold a "content" key.
            val native = case.string("dialect") == "native"
            for ((key, snippets) in listOf("snippets" to prepared.snippets, "snippetsPreservingExclamationPrefix" to prepared.snippetsPreservingExclamationPrefix)) {
                val wanted = case.objects(key)
                assertEquals(wanted.size, snippets.size, case.label)
                for ((expected, actual) in wanted.zip(snippets)) {
                    if (native) {
                        assertContentEquals(expected.bytes("contentUtf8Hex"), actual.content.toByteArray(), case.label)
                        assertEquals(
                            listOf(
                                expected.string("id"), expected.string("name"), expected.string("keyword"), expected.string("content"),
                                expected.strings("tags"), expected.boolean("isEnabled"), expected.boolean("isPinned"),
                                expected.double("createdAt").toRawBits(), expected.double("updatedAt").toRawBits(),
                            ),
                            describeNative(actual), case.label,
                        )
                    } else {
                        assertEquals(
                            listOf(
                                expected.string("name"), expected.string("keyword"), expected.string("content"),
                                expected.strings("tags"), expected.boolean("isEnabled"), expected.boolean("isPinned"),
                            ),
                            describeRaycast(actual), case.label,
                        )
                        assertEquals(5.0, actual.createdAt, case.label)
                        assertEquals(5.0, actual.updatedAt, case.label)
                    }
                }
            }
        }
    }

    @Test
    fun oneElementThatDoesNotFitFailsItsWholeDialect() {
        val native = """{"id":"11111111-2222-4333-8444-555555555555","name":"n","keyword":"k","content":"c"}"""
        // A short id is no native snippet (java.util.UUID would take it), and there is no "text" to make it Raycast.
        assertFailsWith<SnippetImportParser.InvalidFormat> { SnippetImportParser.parse(utf8("""[{"id":"1-1-1-1-1","name":"n","keyword":"k","content":"c"}]""")) }
        assertFailsWith<SnippetImportParser.InvalidFormat> { SnippetImportParser.parse(utf8("""[$native,{"id":"x","name":"n","keyword":"k","content":"c"}]""")) }
        // With a "text" member the same object is a Raycast item, and nothing of the native reading survives.
        val fallback = SnippetImportParser.parse(utf8("""[{"id":"1-1-1-1-1","name":"n","keyword":"k","content":"c","text":"t"}]"""))
        assertEquals(listOf("t"), fallback.snippets.map { it.content })
        assertNotEquals(UUID(1L shl 32 or (1L shl 16) or 1L, (1L shl 48) or 1L), fallback.snippets[0].id)
        // Raycast: wrong types, an object root, an empty array inside an object.
        for (document in listOf(
            """[{"name":"X","text":1}]""", """[{"name":"X","text":"x","keyword":1}]""", """[{"name":null,"text":"x"}]""",
            """{"name":"X","text":"x"}""", """[["name","text"]]""", """[null]""", """{"snippets":{}}""", """{"snippets":null}""",
            """[{"name":"X","text":"\x"}]""", "[", "", " ", "null", "\"text\"",
        )) {
            assertFailsWith<SnippetImportParser.InvalidFormat>(document) { SnippetImportParser.parse(utf8(document)) }
        }
        // What Foundation tolerates is tolerated: a trailing comma, unread members that are malformed, a byte order mark.
        val tolerant = SnippetImportParser.parse(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + utf8("""[{"name":"X","text":"x","other":01,},]"""))
        assertEquals(listOf("X"), tolerant.snippets.map { it.name })
    }

    /** Arbitrary bytes and arbitrary near-JSON: a parse, or `InvalidFormat`, and nothing else. */
    @Test
    fun arbitraryInputNeverThrowsAnythingButInvalidFormat() {
        val random = SeededRandom(0x1A907)
        val fragments = listOf(
            "[", "]", "{", "}", ",", ":", "\"name\"", "\"text\"", "\"keyword\"", "\"snippets\"", "\"id\"", "\"content\"", "\"tags\"",
            "\"createdAt\"", "\"x\"", "\"!k\"", "null", "true", "1", "-0", "1e999", "0.5", "\"11111111-2222-4333-8444-555555555555\"",
            "\"\\ud83d\"", "\"{date \\\"yyyy\\\"}\"", " ", "\n", "\"\\u0000\"", "\uFEFF", "é",
        )
        val keys = fragments.filter { it.startsWith("\"") && it.length > 2 }
        val values = listOf("\"v\"", "\"!k\"", "\" \\\\x y \"", "null", "true", "1", "0.5", "[]", "[\"a\",\"A\"]", "{}", "\"11111111-2222-4333-8444-555555555555\"", "\"{date \\\"yyyy\\\"}\"")
        var parsed = 0
        repeat(30_000) { round ->
            val data = when (round % 3) {
                0 -> ByteArray(random.int(40)) { random.int(256).toByte() }
                1 -> utf8(buildString { repeat(random.int(14)) { append(random.pick(fragments)) } })
                // Well-formed arrays of objects with members drawn at random: many are valid in one dialect.
                else -> utf8(
                    (0 until random.int(4)).joinToString(",", "[", "]") {
                        (0 until random.int(7)).joinToString(",", "{", "}") {
                            random.pick(keys) + ":" + random.pick(values)
                        }
                    }.let { if (random.int(5) == 0) "{\"snippets\":$it}" else it },
                )
            }
            try {
                val prepared = SnippetImportParser.parse(data)
                parsed += 1
                assertEquals(prepared.snippets.size, prepared.snippetsPreservingExclamationPrefix.size)
            } catch (_: SnippetImportParser.InvalidFormat) {
                // The declared failure.
            } catch (other: Throwable) {
                fail("${other::class.simpleName} for ${UtilitiesFixture.scalars(String(data, Charsets.ISO_8859_1))}")
            }
        }
        assertTrue(parsed > 500, "the generator should produce valid documents, got $parsed")
        // Deep nesting is refused, not a stack overflow.
        assertFailsWith<SnippetImportParser.InvalidFormat> { SnippetImportParser.parse(utf8("[".repeat(200_000))) }
        assertFailsWith<SnippetImportParser.InvalidFormat> { SnippetImportParser.parse(utf8("[{\"name\":".repeat(50_000))) }
    }
}
