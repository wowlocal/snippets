package com.khm.snippets.core.codec

import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.io.AtomicFileWriter
import com.khm.snippets.core.json.FoundationJson
import com.khm.snippets.core.json.FoundationJsonNode
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.text.FoundationFixture
import com.khm.snippets.core.text.SeededRandom
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.Base64
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The `SnippetLibraryCodec` cases of `LibraryWriterTests.swift` and
 * `ReviewRegressionTests.swift`, then the corpus produced by the Swift codec itself.
 */
class SnippetLibraryCodecTest {

    private val root: File = Files.createTempDirectory("snippets-codec").toFile()
    private val library = File(root, "snippets.json")
    private val tmpFolder = File(root, "Tmp")

    @AfterTest
    fun removeSandbox() {
        root.deleteRecursively()
    }

    private val now: () -> Double = { NOW }

    private fun decode(text: String): List<Snippet> = SnippetLibraryCodec.decode(text.toByteArray(), now)

    private fun unreadable(text: String) {
        assertFailsWith<SnippetLibraryCodec.Unreadable>(text) { decode(text) }
    }

    // LibraryWriterTests.swift: the frozen format

    @Test
    fun encodingADecodedLibraryReproducesTheOriginalBytesExactly() {
        val snippets = makeRealisticLibrary(40, 0x5EED_1234L)
        val original = SnippetLibraryCodec.encode(snippets)
        AtomicFileWriter.write(original, library, tmpFolder)

        val fromDisk = library.readBytes()
        assertContentEquals(original, fromDisk)

        val decoded = SnippetLibraryCodec.decode(fromDisk)
        assertEquals(snippets, decoded)
        val reencoded = SnippetLibraryCodec.encode(decoded)
        assertContentEquals(fromDisk, reencoded, "re-encoding a decoded library changed the bytes")
        assertEquals(SnippetLibraryCodec.digest(fromDisk), SnippetLibraryCodec.digest(reencoded))
        assertContentEquals(fromDisk, SnippetLibraryCodec.encode(SnippetLibraryCodec.decode(reencoded)))
    }

    @Test
    fun everyEncodedSnippetCarriesExactlyTheNineFrozenKeys() {
        val snippets = makeRealisticLibrary(12, 0xC0FFEEL)
        val objects = assertIs<FoundationJsonNode.Array>(FoundationJson.parse(SnippetLibraryCodec.encode(snippets))).elements
        assertEquals(snippets.size, objects.size)
        val frozenKeys = listOf("content", "createdAt", "id", "isEnabled", "isPinned", "keyword", "name", "tags", "updatedAt")
        val text = String(SnippetLibraryCodec.encode(snippets), Charsets.UTF_8)
        val keyLine = Regex("""^ {4}"([^"]+)" : """, RegexOption.MULTILINE)
        assertEquals(snippets.flatMap { frozenKeys }, keyLine.findAll(text).map { it.groupValues[1] }.toList())

        // The exact form Foundation writes, pinned in the Swift test.
        val pinned = Snippet(
            id = UUID.fromString("00000000-0000-4000-8000-000000000001"),
            name = "Sig \"quoted\"", keyword = "sig", content = "line1\nline2\ttab\\slash",
            tags = listOf("Work"), isEnabled = true, isPinned = false,
            createdAt = 700_000_000.25, updatedAt = 700_000_123.5,
        )
        val expected = """
            [
              {
                "content" : "line1\nline2\ttab\\slash",
                "createdAt" : 700000000.25,
                "id" : "00000000-0000-4000-8000-000000000001",
                "isEnabled" : true,
                "isPinned" : false,
                "keyword" : "sig",
                "name" : "Sig \"quoted\"",
                "tags" : [
                  "Work"
                ],
                "updatedAt" : 700000123.5
              }
            ]
        """.trimIndent()
        assertEquals(expected, String(SnippetLibraryCodec.encode(listOf(pinned)), Charsets.UTF_8))
    }

    @Test
    fun decodeAcceptsBothTheBareArrayAndTheSnippetsWrapperButNoOtherDialect() {
        val snippets = makeRealisticLibrary(5, 0xABCDL)
        assertEquals(snippets, SnippetLibraryCodec.decode(SnippetLibraryCodec.encode(snippets)))
        assertEquals(snippets, SnippetLibraryCodec.decode(SnippetLibraryCodec.encodeCollection(snippets)))
        assertEquals(emptyList(), decode("[]"))
        unreadable("""{"snippets":[{"name":"Sig","text":"Best, Ada","keyword":"sig"}]}""")
    }

    @Test
    fun theDigestIsTakenOverBytesSoAReformatIsStillAChange() {
        val snippets = makeRealisticLibrary(6, 0xFACEL)
        val bare = SnippetLibraryCodec.encode(snippets)
        val wrapped = SnippetLibraryCodec.encodeCollection(snippets)
        assertEquals(SnippetLibraryCodec.decode(bare), SnippetLibraryCodec.decode(wrapped))
        assertNotEquals(SnippetLibraryCodec.digest(bare), SnippetLibraryCodec.digest(wrapped))
        assertEquals(SnippetLibraryCodec.digest(bare), SnippetLibraryCodec.digest(bare.copyOf()))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", SnippetLibraryCodec.digest(ByteArray(0)))
    }

    // LibraryWriterTests.swift / ReviewRegressionTests.swift: unreadable input

    @Test
    fun anUndecodableLibraryThrowsRatherThanPresentingAsAnEmptyLibrary() {
        val damaged = mapOf(
            "not JSON at all" to "this is not json",
            "truncated mid-record" to "[{\"id\":\"00000000-0000-4000-8000-0000000",
            "an object that is not the wrapper" to "{\"records\":[]}",
            "a record missing its id" to "[{\"name\":\"Sig\",\"keyword\":\"sig\",\"content\":\"x\"}]",
            "empty file" to "",
        )
        for ((description, text) in damaged) {
            val bytes = text.toByteArray()
            assertFailsWith<SnippetLibraryCodec.Unreadable>(description) { SnippetLibraryCodec.decode(bytes) }

            AtomicFileWriter.write(bytes, library, tmpFolder)
            val result = assertIs<SnippetLibraryCodec.ReadResult.Undecodable>(SnippetLibraryCodec.read(library), description)
            assertContentEquals(bytes, result.data)
            assertEquals(SnippetLibraryCodec.digest(bytes), result.digest)
            assertContentEquals(bytes, library.readBytes(), "$description was modified")
        }
    }

    /** `aMissingLibraryIsAnEmptyLibraryRatherThanAnError` and `aMissingLibraryIsReportedAsMissingNotAsEmpty`. */
    @Test
    fun aMissingLibraryIsReportedAsMissingNotAsEmpty() {
        assertSame(SnippetLibraryCodec.ReadResult.Missing, SnippetLibraryCodec.read(library))

        library.writeBytes(SnippetLibraryCodec.encode(emptyList()))
        val empty = assertIs<SnippetLibraryCodec.ReadResult.Loaded>(SnippetLibraryCodec.read(library))
        assertEquals(emptyList(), empty.snippets, "an empty ARRAY is a real file and a real statement")
        assertEquals("[\n\n]", String(empty.data))
        assertEquals(SnippetLibraryCodec.digest(empty.data), empty.digest)

        val snippets = makeRealisticLibrary(3, 7)
        library.writeBytes(SnippetLibraryCodec.encode(snippets))
        assertEquals(snippets, assertIs<SnippetLibraryCodec.ReadResult.Loaded>(SnippetLibraryCodec.read(library)).snippets)
    }

    @Test
    fun anUnreadableButPresentLibraryIsNeverPresentedAsEmpty() {
        library.writeBytes(SnippetLibraryCodec.encode(makeRealisticLibrary(1, 1)))
        Files.setPosixFilePermissions(library.toPath(), PosixFilePermissions.fromString("---------"))
        try {
            // Running as root would defeat the permission bit and make this vacuous.
            if (!Files.isReadable(library.toPath())) {
                assertIs<SnippetLibraryCodec.ReadResult.Unreadable>(SnippetLibraryCodec.read(library))
            }
        } finally {
            Files.setPosixFilePermissions(library.toPath(), PosixFilePermissions.fromString("rw-------"))
        }
        assertIs<SnippetLibraryCodec.ReadResult.Unreadable>(SnippetLibraryCodec.read(root))
    }

    // Decoding rules, one at a time

    private val id = "\"id\":\"00000000-0000-4000-8000-000000000001\""
    private val required = "$id,\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\""

    /** A file as Foundation writes it: `"key" : value`, sorted keys, `\/`, a blank line in an empty array. */
    @Test
    fun aFoundationStylePrettyPrintedFileDecodes() {
        val file = """
            [
              {
                "content" : "https:\/\/example.com\/a\tb\n\u00e9 \ud83d\ude00",
                "createdAt" : 700000000,
                "id" : "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
                "isEnabled" : false,
                "isPinned" : true,
                "keyword" : "\\link",
                "name" : "Link \"one\"",
                "tags" : [

                ],
                "updatedAt" : 1e+16
              },
              {
                "content" : "",
                "createdAt" : -0,
                "id" : "abcdefab-cdef-4abc-8def-abcdefabcdee",
                "isEnabled" : true,
                "isPinned" : false,
                "keyword" : "",
                "name" : "",
                "tags" : [
                  "Work",
                  "Réf"
                ],
                "updatedAt" : 1e-05
              }
            ]
        """.trimIndent()
        val decoded = decode(file)
        assertEquals(
            listOf(
                Snippet(
                    UUID.fromString("abcdefab-cdef-4abc-8def-abcdefabcdef"), "Link \"one\"", "\\link",
                    "https://example.com/a\tb\né 😀", emptyList(), isEnabled = false, isPinned = true,
                    createdAt = 700000000.0, updatedAt = 1e16,
                ),
                Snippet(
                    UUID.fromString("abcdefab-cdef-4abc-8def-abcdefabcdee"), "", "", "", listOf("Work", "Réf"),
                    createdAt = -0.0, updatedAt = 1e-5,
                ),
            ),
            decoded,
        )
        assertEquals(java.lang.Double.doubleToRawLongBits(-0.0), java.lang.Double.doubleToRawLongBits(decoded[1].createdAt))
        // And this port writes those very bytes back; Foundation spells non-ASCII text raw.
        val rewritten = file.replace("\\u00e9 \\ud83d\\ude00", "é 😀").replace("abcdefab-cdef-4abc-8def-abcdefabcdee", "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEE")
        assertNotEquals(file, rewritten)
        assertEquals(rewritten, String(SnippetLibraryCodec.encode(decoded), Charsets.UTF_8))
    }

    @Test
    fun unknownKeysAreIgnoredAndMissingOrNullOptionalKeysTakeTheirDefaults() {
        val minimal = decode("[{$required}]").single()
        assertEquals(Snippet(UUID.fromString("00000000-0000-4000-8000-000000000001"), "n", "k", "c", emptyList(), true, false, NOW, NOW), minimal)

        val nulls = decode("[{$required,\"tags\":null,\"isEnabled\":null,\"isPinned\":null,\"createdAt\":null,\"updatedAt\":null}]").single()
        assertEquals(minimal, nulls)

        assertEquals(minimal, decode("[{$required,\"color\":\"red\",\"secure\":true,\"x\":{\"a\":[1,2,null]},\"bad\":01,\"worse\":\"\\x\"}]").single())

        // updatedAt falls back to createdAt, not to the clock; createdAt alone falls back to the clock.
        assertEquals(5.0, decode("[{$required,\"createdAt\":5}]").single().updatedAt)
        val onlyUpdated = decode("[{$required,\"updatedAt\":7}]").single()
        assertEquals(NOW, onlyUpdated.createdAt)
        assertEquals(7.0, onlyUpdated.updatedAt)

        // The clock is read once per record that needs it.
        var reads = 0
        val two = SnippetLibraryCodec.decode("[{$required},{$required,\"createdAt\":1},{$required}]".toByteArray()) { (++reads).toDouble() }
        assertEquals(listOf(1.0, 1.0, 2.0), two.map { it.createdAt })
        assertEquals(listOf(1.0, 1.0, 2.0), two.map { it.updatedAt })
        assertEquals(2, reads)
    }

    @Test
    fun tagsAreNormalizedOnDecodeAndNothingElseIs() {
        val snippet = decode("[{$id,\"name\":\"  n  \",\"keyword\":\" \\\\my key \",\"content\":\" c \",\"tags\":[\"  Work \",\"work\",\"two   words\",\"\"]}]").single()
        assertEquals(listOf("Work", "two words"), snippet.tags)
        assertEquals("  n  ", snippet.name)
        assertEquals(" \\my key ", snippet.keyword)
        assertEquals(" c ", snippet.content)
    }

    @Test
    fun wrongTypesAndMissingRequiredKeysFailTheWholeLibrary() {
        val good = "{$required}"
        for (text in listOf(
            "[$good,{\"name\":\"n\"}]",
            "[{\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]",
            "[{$id,\"keyword\":\"k\",\"content\":\"c\"}]",
            "[{$id,\"name\":\"n\",\"content\":\"c\"}]",
            "[{$id,\"name\":\"n\",\"keyword\":\"k\"}]",
            "[{$id,\"name\":null,\"keyword\":\"k\",\"content\":\"c\"}]",
            "[{$id,\"name\":1,\"keyword\":\"k\",\"content\":\"c\"}]",
            "[{\"id\":5,\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]",
            "[{\"id\":\"1-1-1-1-1\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]",
            "[{\"id\":\"00000000000040008000000000000001\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\"}]",
            "[{$required,\"tags\":\"work\"}]", "[{$required,\"tags\":[\"a\",1]}]", "[{$required,\"tags\":[null]}]",
            "[{$required,\"isEnabled\":1}]", "[{$required,\"isPinned\":\"true\"}]",
            "[{$required,\"createdAt\":\"2026-07-29T08:00:00Z\"}]", "[{$required,\"updatedAt\":true}]",
            "[null]", "[[]]", "[\"x\"]", "null", "\"snippets\"", "1", "{}", "{\"snippets\":null}", "{\"snippets\":{}}", "{\"items\":[]}",
        )) unreadable(text)
    }

    @Test
    fun numbersThatAreNotFiniteDoublesAreRefused() {
        for (number in listOf("NaN", "Infinity", "-Infinity", "1e999", "-1e999", "1e-999", "01", "+1", ".5", "1.", "0x10")) {
            unreadable("[{$required,\"createdAt\":$number}]")
            unreadable("[{$required,\"updatedAt\":$number}]")
        }
        assertEquals(1.2345678901234568e29, decode("[{$required,\"createdAt\":123456789012345678901234567890}]").single().createdAt)

        val snippet = Snippet(name = "", keyword = "", content = "", createdAt = 0.0, updatedAt = 0.0)
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertFailsWith<SnippetLibraryCodec.NotEncodable> { SnippetLibraryCodec.encode(listOf(snippet.copy(createdAt = value))) }
            assertFailsWith<SnippetLibraryCodec.NotEncodable> { SnippetLibraryCodec.encodeCollection(listOf(snippet.copy(updatedAt = value))) }
        }
    }

    /** The codec does not police ids; the store and the import path do. */
    @Test
    fun duplicateIdsAndDuplicateKeysAreDecodedAsFoundationDecodesThem() {
        val twice = decode("[{$required},{$required}]")
        assertEquals(2, twice.size)
        assertEquals(twice[0].id, twice[1].id)

        // Of two members with one key the first wins.
        assertEquals("n", decode("[{$required,\"name\":\"second\"}]").single().name)
        assertEquals("first", decode("[{\"name\":\"first\",$required}]").single().name)
        assertEquals(emptyList(), decode("{\"snippets\":[],\"snippets\":[{$required}]}"))
        assertEquals(1, decode("{\"version\":3,\"snippets\":[{$required}],\"snippets\":[]}").size)
    }

    @Test
    fun anIdMayBeEitherCaseAndIsWrittenUppercase() {
        val lower = decode("[{\"id\":\"a0b1c2d3-e4f5-4607-8899-aabbccddeeff\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"createdAt\":1}]").single()
        val mixed = decode("[{\"id\":\"A0b1C2d3-E4f5-4607-8899-AAbbCCddEEff\",\"name\":\"n\",\"keyword\":\"k\",\"content\":\"c\",\"createdAt\":1}]").single()
        assertEquals(lower.id, mixed.id)
        assertTrue(String(SnippetLibraryCodec.encode(listOf(lower))).contains("\"id\" : \"A0B1C2D3-E4F5-4607-8899-AABBCCDDEEFF\""))
    }

    @Test
    fun aHugeLibraryDecodesAndReencodesToTheSameBytes() {
        val random = SeededRandom(0xB16L)
        val body = "line of text with ünïcödé and 🎉\n".repeat(64)
        val snippets = (0 until 4_000).map { index ->
            Snippet(random.uuid(), "Snippet $index", "kw$index", body, listOf("Tag ${index % 7}"), createdAt = 700_000_000.0 + index, updatedAt = 700_000_000.5 + index)
        }
        val bytes = SnippetLibraryCodec.encode(snippets)
        assertTrue(bytes.size > 8 * 1024 * 1024, "only ${bytes.size} bytes")
        val decoded = SnippetLibraryCodec.decode(bytes)
        assertEquals(snippets, decoded)
        assertContentEquals(bytes, SnippetLibraryCodec.encode(decoded))
    }

    @Test
    fun anUnpairedSurrogateIsWrittenAsTheReplacementCharacter() {
        // Swift cannot hold one; it repairs it when the string is created.
        val snippet = Snippet(name = "a\uD83Db", keyword = "", content = "", createdAt = 0.0, updatedAt = 0.0)
        assertEquals("a\uFFFDb", SnippetLibraryCodec.decode(SnippetLibraryCodec.encode(listOf(snippet))).single().name)
    }

    // The corpus written by the Swift codec

    @Test
    fun decodingAndEncodingMatchTheSwiftCodecOnTheWholeCorpus() {
        var decodes = 0
        var loaded = 0
        var encodes = 0
        val failures = ArrayList<String>()
        for (row in FoundationFixture.rows("codec-corpus.tsv")) {
            when (row[0]) {
                "decode" -> {
                    decodes += 1
                    val input = Base64.getDecoder().decode(row[1])
                    val actual = try {
                        SnippetLibraryCodec.decode(input, now)
                    } catch (_: SnippetLibraryCodec.Unreadable) {
                        null
                    }
                    val expected = if (row[2] == "unreadable") null else row.getOrElse(3) { "" }
                    if (expected != null) loaded += 1
                    val described = actual?.joinToString("|", transform = ::describe)
                    if (described != expected) {
                        failures.add("decode ${row[1].take(400)}\n    Swift:  ${expected ?: "unreadable"}\n    Kotlin: ${described ?: "unreadable"}")
                    }
                }
                "encode" -> {
                    encodes += 1
                    val snippets = if (row[1].isEmpty()) emptyList() else row[1].split('|').map(::snippetOf)
                    assertEquals(row[2], Base64.getEncoder().encodeToString(SnippetLibraryCodec.encode(snippets)), "encode ${row[1]}")
                    assertEquals(row[3], Base64.getEncoder().encodeToString(SnippetLibraryCodec.encodeCollection(snippets)), "encodeCollection ${row[1]}")
                }
                else -> fail("unknown row kind ${row[0]}")
            }
        }
        assertTrue(decodes > 3_000 && loaded > 1_000 && encodes > 150, "decodes $decodes, loaded $loaded, encodes $encodes")
        assertEquals(0, failures.size, "${failures.size} of $decodes libraries decode differently:\n" + failures.take(12).joinToString("\n"))
    }

    private fun bits(value: Double): String =
        if (java.lang.Double.doubleToRawLongBits(value) == java.lang.Double.doubleToRawLongBits(NOW)) "now"
        else java.lang.Long.toHexString(java.lang.Double.doubleToRawLongBits(value)).padStart(16, '0')

    /** The line format of the corpus; see `describe` in `tools/foundation-tables/Sources/ModelCorpora.swift`. */
    private fun describe(snippet: Snippet): String = listOf(
        Uuids.uppercase(snippet.id),
        FoundationFixture.scalars(snippet.name),
        FoundationFixture.scalars(snippet.keyword),
        FoundationFixture.scalars(snippet.content),
        snippet.tags.joinToString(";") { FoundationFixture.scalars(it) },
        if (snippet.isEnabled) "1" else "0",
        if (snippet.isPinned) "1" else "0",
        bits(snippet.createdAt),
        bits(snippet.updatedAt),
    ).joinToString(",")

    private fun snippetOf(description: String): Snippet {
        val parts = description.split(',')
        return Snippet(
            Uuids.parse(parts[0])!!, FoundationFixture.text(parts[1]), FoundationFixture.text(parts[2]), FoundationFixture.text(parts[3]),
            FoundationFixture.texts(parts[4]), parts[5] == "1", parts[6] == "1",
            Double.fromBits(java.lang.Long.parseUnsignedLong(parts[7], 16)), Double.fromBits(java.lang.Long.parseUnsignedLong(parts[8], 16)),
        )
    }

    private companion object {
        /** Stands in for "the current time" so a defaulted timestamp is recognisable. A quiet NaN payload no file can spell. */
        val NOW: Double = Double.fromBits(0x7FF8_0000_0000_0A11L)

        /**
         * `makeRealisticLibrary` from the Swift test: unicode, emoji, multi-line bodies,
         * quotes and backslashes, with normalized tags and timestamps in exact eighths.
         */
        fun makeRealisticLibrary(count: Int, seed: Long): List<Snippet> {
            val random = SeededRandom(seed)
            val names = listOf(
                "Email signature", "Zoom link", "Résumé blurb", "住所", "Shrug ¯\\_(ツ)_/¯",
                "Invoice footer", "PR checklist ✅", "Tab\tseparated", "He said \"hi\"",
            )
            val bodies = listOf(
                "Best,\nAda", "https://example.com/j/1234567890", "line one\nline two\tindented\nline three",
                "Path: C:\\Users\\ada\\notes.txt", "— em dash, ünïcödé, and an emoji 🎉", "{date:yyyyMMdd}-{clipboard}", "",
            )
            val tagPools = listOf(emptyList(), listOf("Work"), listOf("Work", "Email"), listOf("Personal"), listOf("Snippets", "Ops", "Réf"))
            return (0 until count).map { index ->
                Snippet(
                    id = random.uuid(),
                    name = random.pick(names) + " $index",
                    keyword = "kw$index",
                    content = random.pick(bodies),
                    tags = random.pick(tagPools),
                    isEnabled = random.bool(),
                    isPinned = random.bool(),
                    createdAt = 700_000_000 + random.int(8192) / 8.0,
                    updatedAt = 720_000_000 + random.int(8192) / 8.0,
                )
            }
        }
    }
}
