package com.khm.snippets.core.interchange

import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.json.SwiftVectors
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.search.UtilitiesFixture
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.text.SeededRandom
import java.security.MessageDigest
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The share-link suite of `Tests/Core/ReviewRegressionTests.swift`, the review rules of
 * `snippets-ios-tests/IncomingSnippetLinkCoordinatorTests.swift`, the L06 link vectors and
 * 352 links as Swift's `URL(string:)` and `SnippetDeepLink` judge them.
 */
class SnippetDeepLinkTest {

    private fun secret() = Snippet(name = "AWS root", keyword = "awsroot", content = "hunter2")

    private fun error(swiftCase: String): SnippetDeepLink.Error = when (swiftCase.substringAfterLast('.')) {
        "unsupportedURL", "noURL" -> SnippetDeepLink.Error.UNSUPPORTED_URL
        "missingPayload" -> SnippetDeepLink.Error.MISSING_PAYLOAD
        "invalidPayload" -> SnippetDeepLink.Error.INVALID_PAYLOAD
        "unsupportedVersion" -> SnippetDeepLink.Error.UNSUPPORTED_VERSION
        "cannotEncodePayload" -> SnippetDeepLink.Error.CANNOT_ENCODE_PAYLOAD
        "secureSnippetNotShareable" -> SnippetDeepLink.Error.SECURE_SNIPPET_NOT_SHAREABLE
        else -> throw IllegalStateException(swiftCase)
    }

    // "Share link refuses secrets"

    @Test
    fun aSecureSnippetCannotBeTurnedIntoAShareLink() {
        val failure = assertFailsWith<SnippetDeepLink.Failure> { SnippetDeepLink.url(secret(), isSecure = true) }
        assertEquals(SnippetDeepLink.Error.SECURE_SNIPPET_NOT_SHAREABLE, failure.error)
    }

    @Test
    fun anOrdinarySnippetStillShares() {
        assertTrue(SnippetDeepLink.canHandle(SnippetDeepLink.url(secret(), isSecure = false)))
    }

    @Test
    fun theRefusalMentionsNoContent() {
        val failure = assertFailsWith<SnippetDeepLink.Failure> { SnippetDeepLink.url(secret(), isSecure = true) }
        val text = "$failure ${failure.message} ${failure.localizedMessage}"
        assertFalse(text.contains("hunter2") || text.contains("awsroot") || text.contains("AWS"))
        // No failure of parsing repeats any part of the link either.
        val parse = assertFailsWith<SnippetDeepLink.Failure> { SnippetDeepLink.snippet("snippets://share?data=aHVudGVyMg") }
        assertEquals("INVALID_PAYLOAD", parse.message)
    }

    // The review-before-change rules of the iOS coordinator

    @Test
    fun aReceivedSnippetIsStagedDisabledWhateverTheLinkSays() {
        val link = SnippetDeepLink.url(Snippet(name = "n", keyword = "k", content = "c", isEnabled = true, isPinned = true), isSecure = false)
        val share = SnippetDeepLink.receive(link)
        assertEquals(SnippetDeepLink.Kind.SHARE, share.kind)
        assertTrue(share.snippet.isEnabled, "the parser reports the snippet as the link describes it")
        assertFalse(share.staged.isEnabled)
        assertFalse(share.staged.isPinned)
        assertEquals(share.snippet.copy(isEnabled = false), share.staged)
        assertFalse(SnippetDeepLink.RECEIVED_SNIPPET_IS_ENABLED)

        val creation = SnippetDeepLink.receive("snippets://new?name=Greeting&keyword=hello&content=Hello%20world&tags=Work")
        assertEquals(SnippetDeepLink.Kind.CREATION, creation.kind)
        assertFalse(creation.staged.isEnabled)
        assertEquals(listOf("Greeting", "hello", "Hello world", listOf("Work")), creation.staged.let { listOf(it.name, it.keyword, it.content, it.tags) })
    }

    @Test
    fun theReplacementTargetIsTheSameIdOrElseTheSameFoldedKeyword() {
        val byKeyword = Snippet(UUID(1, 1), "Old", "Café", "old", createdAt = 1.0, updatedAt = 1.0)
        val other = Snippet(UUID(1, 2), "Other", "", "x", createdAt = 1.0, updatedAt = 1.0)
        val library = listOf(other, byKeyword)
        val incoming = SnippetDeepLink.snippet("snippets://new?keyword=%5CCAFE&content=new")

        assertEquals(byKeyword, SnippetLinkReview.replacementTarget(incoming, library))
        assertEquals(other, SnippetLinkReview.replacementTarget(incoming.copy(id = other.id), library), "the id comes first")
        assertNull(SnippetLinkReview.replacementTarget(incoming.copy(keyword = ""), library), "no keyword replaces nothing")
        assertNull(SnippetLinkReview.replacementTarget(incoming.copy(keyword = "cafes"), library))
        // The check before importing: an edit of the reviewed record makes the two reviews differ.
        val edited = library.map { if (it.id == byKeyword.id) it.copy(content = "edited meanwhile") else it }
        assertNotEquals(SnippetLinkReview.replacementTarget(incoming, library), SnippetLinkReview.replacementTarget(incoming, edited))
    }

    @Test
    fun theReviewPreviewIsTrimmedAndCutAt280Characters() {
        assertEquals("", SnippetLinkReview.contentPreview(" \n\t "))
        assertEquals("body", SnippetLinkReview.contentPreview("\n body \u00A0"))
        val exact = "👩🏽\u200D💻".repeat(280)
        assertEquals(exact, SnippetLinkReview.contentPreview(exact))
        assertEquals("$exact…", SnippetLinkReview.contentPreview(exact + "x"))
        assertEquals(280, FoundationText.characterCount(SnippetLinkReview.contentPreview("e\u0301".repeat(500)).dropLast(1)))
    }

    // L06

    private fun snippet(case: SwiftVectors.Case): Snippet = Snippet(
        Uuids.parseLowercase(case.string("id")) ?: fail("${case.label}: bad id"),
        case.string("name"), case.string("keyword"), case.string("content"), case.strings("tags"),
        case.boolean("isEnabled"), case.boolean("isPinned"), case.double("createdAt"), case.double("updatedAt"),
    )

    private fun sha256(text: String): String = Bytes.toHex(MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)))

    @Test
    fun swiftVectorsL06LinkEncode() {
        val cases = SwiftVectors.cases("L06-keywords-import-links", "link-encode")
        assertEquals(8, cases.size)
        for (case in cases) {
            if (case.has("error")) {
                val failure = assertFailsWith<SnippetDeepLink.Failure>(case.label) { SnippetDeepLink.url(secret(), isSecure = true) }
                assertEquals(error(case.string("error")), failure.error, case.label)
                continue
            }
            val description = case.obj("snippet")
            val original = if (description.has("contentCharacterCount")) {
                assertEquals(100_000, description.int("contentCharacterCount"))
                Snippet(name = description.string("name"), keyword = description.string("keyword"), content = "0123456789".repeat(10_000))
            } else {
                snippet(description)
            }
            val url = SnippetDeepLink.url(original, isSecure = false)
            assertEquals(case.int("urlCharacterCount"), url.length, case.label)
            assertEquals(case.string("urlSHA256"), sha256(url), case.label)
            if (!case.isNull("url")) assertEquals(case.string("url"), url, case.label)
            if (!case.isNull("payloadJSON")) {
                val payload = Base64Url.decode(url.removePrefix("snippets://share?data=")) ?: fail(case.label)
                assertEquals(case.string("payloadJSON"), String(payload, Charsets.UTF_8), case.label)
            }
            val decoded = case.obj("decoded")
            val back = SnippetDeepLink.snippet(url)
            assertEquals(decoded.string("name"), back.name, case.label)
            assertEquals(decoded.string("keyword"), back.keyword, case.label)
            if (!decoded.isNull("content")) assertEquals(decoded.string("content"), back.content, case.label)
            assertEquals(decoded.boolean("contentEqualsOriginal"), back.content == original.content, case.label)
            assertEquals(decoded.strings("tags"), back.tags, case.label)
            assertEquals(decoded.boolean("isEnabled"), back.isEnabled, case.label)
            assertEquals(decoded.boolean("isPinned"), back.isPinned, case.label)
            assertEquals(decoded.boolean("idEqualsOriginal"), back.id == original.id, case.label)
        }
    }

    @Test
    fun swiftVectorsL06LinkParse() {
        val cases = SwiftVectors.cases("L06-keywords-import-links", "link-parse")
        assertEquals(33, cases.size)
        for (case in cases) {
            val url = case.string("url")
            assertEquals(case.boolean("canHandle"), SnippetDeepLink.canHandle(url), case.label)
            assertEquals(case.boolean("isCreationLink"), SnippetDeepLink.isCreationLink(url), case.label)
            if (case.has("error")) {
                val failure = assertFailsWith<SnippetDeepLink.Failure>(case.label) { SnippetDeepLink.snippet(url) }
                assertEquals(error(case.string("error")), failure.error, case.label)
                continue
            }
            val expected = case.obj("ok")
            val snippet = SnippetDeepLink.snippet(url, now = { 42.5 })
            assertEquals(
                listOf(expected.string("name"), expected.string("keyword"), expected.string("content"), expected.strings("tags"), expected.boolean("isEnabled"), expected.boolean("isPinned")),
                listOf(snippet.name, snippet.keyword, snippet.content, snippet.tags, snippet.isEnabled, snippet.isPinned), case.label,
            )
            assertEquals(42.5, snippet.createdAt, case.label)
            assertEquals(42.5, snippet.updatedAt, case.label)
        }
    }

    /**
     * 352 links through Swift: whether `URL(string:)` takes the text at all, `canHandle`,
     * `isCreationLink`, and the snippet or the error. Text Swift's `URL(string:)` refuses
     * never reaches `SnippetDeepLink` there; here it is an unsupported link.
     *
     * One row differs by design, see the comment on the integer decoder: a `version` of
     * 9223372036854775807 is `invalidPayload` here and `unsupportedVersion` in Swift.
     */
    @Test
    fun linksAreJudgedAsSwiftJudgesThem() {
        val rows = UtilitiesFixture.rows("swift-links.tsv")
        assertEquals(352, rows.size)
        var deviations = 0
        for (row in rows) {
            val url = UtilitiesFixture.text(row[0])
            val label = UtilitiesFixture.scalars(if (url.length > 300) url.take(300) + "…" else url)
            assertEquals(row[2] == "1", SnippetDeepLink.canHandle(url), "canHandle $label")
            assertEquals(row[3] == "1", SnippetDeepLink.isCreationLink(url), "isCreationLink $label")
            if (row[4] == "ok") {
                val snippet = SnippetDeepLink.snippet(url)
                assertEquals(
                    listOf(row[5], row[6], row[7], row[8]).map { field -> if (field === row[8]) UtilitiesFixture.texts(field) else UtilitiesFixture.text(field) }
                        .map { if (it is String) UtilitiesFixture.scalars(it) else (it as List<*>).map { tag -> UtilitiesFixture.scalars(tag as String) } },
                    listOf(UtilitiesFixture.scalars(snippet.name), UtilitiesFixture.scalars(snippet.keyword), UtilitiesFixture.scalars(snippet.content), snippet.tags.map(UtilitiesFixture::scalars)),
                    label,
                )
                assertTrue(snippet.isEnabled && !snippet.isPinned, label)
                continue
            }
            val actual = assertFailsWith<SnippetDeepLink.Failure>(label) { SnippetDeepLink.snippet(url) }.error
            val wanted = error(row[5])
            if (wanted == SnippetDeepLink.Error.UNSUPPORTED_VERSION && actual == SnippetDeepLink.Error.INVALID_PAYLOAD) {
                val payload = String(Base64Url.decode(url.substringAfter("data=")) ?: fail(label), Charsets.UTF_8)
                assertTrue(payload.contains("\"version\":9223372036854775807}"), label)
                deviations += 1
                continue
            }
            assertEquals(wanted, actual, label)
        }
        assertEquals(1, deviations)
    }

    /** Six snippets with every kind of character that needs a JSON escape, as `JSONEncoder` spells them. */
    @Test
    fun shareLinksAreByteForByteSwiftsLinks() {
        val rows = UtilitiesFixture.rows("swift-link-encode.tsv")
        assertEquals(6, rows.size)
        for (row in rows) {
            val snippet = Snippet(
                name = UtilitiesFixture.text(row[0]), keyword = UtilitiesFixture.text(row[1]),
                content = UtilitiesFixture.text(row[2]), tags = UtilitiesFixture.texts(row[3]),
            )
            assertEquals(row[4], SnippetDeepLink.url(snippet, isSecure = false), UtilitiesFixture.scalars(snippet.name))
        }
    }

    // Properties

    private val pieces = listOf(
        "a", "Z", "0", " ", "\n", "\r\n", "\t", "\"", "\\", "/", "?", "&", "=", "#", "+", "%", "%41", "'", "<", ">", "{date}", ",", ";", ".", "-", "_", "~", "!",
        "é", "e\u0301", "ß", "日本語", "🔑", "👩🏽\u200D💻", "🇫🇷", "\u0000", "\u001F", "\u007F", "\u0085", "\u00A0", "\u2028", "\u200B", "\uFEFF", "\uFFFD", "\uFFFF", "\uD7FF", "\uE000",
    )

    private fun randomText(random: SeededRandom, maxPieces: Int): String = buildString { repeat(random.int(maxPieces + 1)) { append(random.pick(pieces)) } }

    /**
     * Encode, then decode, for arbitrary snippets with every flag: name, content and tags
     * come back as they went in (tags are normalized by the store before they are shared),
     * the keyword comes back normalized, and id, dates and flags do not travel.
     */
    @Test
    fun encodeThenDecodeRoundTripsArbitrarySnippets() {
        val random = SeededRandom(0x11CC)
        repeat(4_000) { round ->
            val original = Snippet(
                id = random.uuid(),
                name = randomText(random, 6),
                keyword = randomText(random, 4),
                content = if (round % 500 == 0) randomText(random, 20).repeat(2_000) else randomText(random, 30),
                tags = SnippetTagging.normalizedTags((0 until random.int(4)).map { randomText(random, 3) }),
                isEnabled = random.bool(),
                isPinned = random.bool(),
                createdAt = random.int(1_000_000).toDouble(),
                updatedAt = random.int(1_000_000) + 0.5,
            )
            val url = SnippetDeepLink.url(original, isSecure = false)
            assertTrue(url.startsWith("snippets://share?data="))
            assertTrue(url.removePrefix("snippets://share?data=").all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' }, "only URL-safe characters")
            assertTrue(SnippetDeepLink.canHandle(url) && !SnippetDeepLink.isCreationLink(url))

            val newId = UUID(77, round.toLong())
            val back = SnippetDeepLink.snippet(url, now = { 123.25 }, newId = { newId })
            assertEquals(original.name, back.name)
            assertEquals(original.content, back.content)
            assertEquals(original.tags, back.tags)
            assertEquals(original.normalizedKeyword, back.keyword)
            assertEquals(listOf<Any>(newId, true, false, 123.25, 123.25), listOf(back.id, back.isEnabled, back.isPinned, back.createdAt, back.updatedAt))
            // The link is stable: decoding and encoding again gives the same link.
            assertEquals(url, SnippetDeepLink.url(back, isSecure = false))
            // The padded and the standard-alphabet spellings of the same payload are the same link.
            val data = url.removePrefix("snippets://share?data=")
            val standard = data.replace('-', '+').replace('_', '/') + "=".repeat((4 - data.length % 4) % 4)
            assertEquals(back.content, SnippetDeepLink.snippet("SNIPPETS://Share/x?y=1&data=$standard#f", newId = { newId }).content)
        }
    }

    /** A creation link built with percent-encoding carries any text through. */
    @Test
    fun creationLinksCarryArbitraryPercentEncodedText() {
        fun encode(text: String): String = buildString {
            for (byte in text.toByteArray(Charsets.UTF_8)) {
                val unit = (byte.toInt() and 0xFF).toChar()
                if (unit in 'a'..'z' || unit in 'A'..'Z' || unit in '0'..'9') append(unit) else append('%').append("%02X".format(byte.toInt() and 0xFF))
            }
        }
        val random = SeededRandom(0xC2EA)
        repeat(3_000) {
            // Surrogate halves cannot be written as UTF-8; everything else can.
            val name = randomText(random, 5)
            val content = randomText(random, 12)
            val keyword = randomText(random, 3)
            // Crypto review D1: a value that is only U+FEFF is empty once `URLComponents` has read it.
            if (listOf(name, keyword, content).all { it.removePrefix("\uFEFF").isEmpty() }) return@repeat
            val url = "snippets://new?name=${encode(name)}&KEYWORD=${encode(keyword)}&content=${encode(content)}"
            val snippet = SnippetDeepLink.snippet(url)
            // Crypto review D1: `URLComponents.queryItems` drops one leading U+FEFF of a value (measured, macOS 27.2).
            assertEquals(name.removePrefix("\uFEFF"), snippet.name)
            assertEquals(content.removePrefix("\uFEFF"), snippet.content)
            assertEquals(Snippet.sanitizedKeyword(keyword.removePrefix("\uFEFF")), snippet.keyword)
            assertTrue(SnippetDeepLink.isCreationLink(url))
        }
    }

    /** Any text at all is a snippet or a `Failure`; `canHandle` agrees with which. */
    @Test
    fun arbitraryLinksNeverThrowAnythingButFailure() {
        val random = SeededRandom(0xBADC0DE)
        val fragments = listOf(
            "snippets", "SNIPPETS", "snippet", "https", ":", "//", "/", "?", "#", "&", "=", "@", "[", "]", "share", "new", "NEW", "data", "name", "keyword",
            "content", "tags", "%", "%4", "%41", "%FF", "%00", "%E2%82%AC", "+", " ", "\n", "\u0000", "é", "ｎｅｗ", "\u00AD", "\uD83D", "\uDC69", "🔑", ",", ".", "80", "-1",
            "eyJjb250ZW50IjoiYyIsImtleXdvcmQiOiJrIiwibmFtZSI6Im4iLCJ2ZXJzaW9uIjoxfQ", "e30", "W10", "bnVsbA", "===", "A", "xn--", "\\",
        )
        var handled = 0
        var parsed = 0
        repeat(60_000) { round ->
            val url = when (round % 3) {
                0 -> buildString { repeat(random.int(12)) { append(random.pick(fragments)) } }
                1 -> "snippets://" + random.pick(listOf("share", "new", "New", "share:80", "u@new")) + "?" +
                    (0 until random.int(5)).joinToString("&") {
                        random.pick(listOf("name", "keyword", "content", "tags", "data", "NAME", "x")) + "=" +
                            buildString { repeat(random.int(4)) { append(random.pick(fragments)) } }
                    }
                else -> "snippets://share?data=" + Base64Url.encode(ByteArray(random.int(60)) { random.int(256).toByte() })
            }
            val canHandle: Boolean
            try {
                canHandle = SnippetDeepLink.canHandle(url)
                assertEquals(canHandle && SnippetDeepLink.isCreationLink(url), SnippetDeepLink.isCreationLink(url))
            } catch (other: Throwable) {
                fail("canHandle threw ${other::class.simpleName} for ${UtilitiesFixture.scalars(url)}")
            }
            if (canHandle) handled += 1
            try {
                val received = SnippetDeepLink.receive(url)
                parsed += 1
                assertTrue(canHandle, UtilitiesFixture.scalars(url))
                assertEquals(SnippetDeepLink.isCreationLink(url), received.kind == SnippetDeepLink.Kind.CREATION)
                assertEquals(received.snippet.tags, SnippetTagging.normalizedTags(received.snippet.tags))
                assertEquals(received.snippet.keyword, Snippet.sanitizedKeyword(received.snippet.keyword))
            } catch (failure: SnippetDeepLink.Failure) {
                assertEquals(!canHandle, failure.error == SnippetDeepLink.Error.UNSUPPORTED_URL, UtilitiesFixture.scalars(url))
            } catch (other: Throwable) {
                fail("${other::class.simpleName} for ${UtilitiesFixture.scalars(url)}")
            }
        }
        assertTrue(handled > 20_000 && parsed > 1_000, "handled=$handled parsed=$parsed")
    }

    @Test
    fun aVeryLongLinkIsHandledWithoutALimit() {
        val body = "0123456789".repeat(200_000) // 2 MB
        val url = SnippetDeepLink.url(Snippet(name = "Long", keyword = "long", content = body), isSecure = false)
        assertTrue(url.length > 2_600_000)
        assertEquals(body, SnippetDeepLink.snippet(url).content)
        val failure = assertFailsWith<SnippetDeepLink.Failure> { SnippetDeepLink.snippet("snippets://share?data=" + "A".repeat(3_000_000)) }
        assertEquals(SnippetDeepLink.Error.INVALID_PAYLOAD, failure.error)
        val creation = SnippetDeepLink.snippet("snippets://new?content=" + "%F0%9F%94%91".repeat(100_000))
        assertEquals(100_000, creation.content.codePointCount(0, creation.content.length))
    }
}
