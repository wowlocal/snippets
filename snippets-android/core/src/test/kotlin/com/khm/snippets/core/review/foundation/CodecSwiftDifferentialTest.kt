package com.khm.snippets.core.review.foundation

import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.model.Snippet
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Review: about 2,000 hostile and ordinary `snippets.json` inputs, each judged by the real
 * Swift `SnippetLibraryCodec` (fixture `codec-differential.tsv.gz`, produced by a scratch
 * tool that compiles `Snippet.swift` and `SnippetLibraryCodec.swift` unmodified).
 *
 * Kotlin must accept and refuse exactly the same inputs, decode the same nine fields bit
 * for bit, and re-encode to the bytes Swift writes.
 */
class CodecSwiftDifferentialTest {

    private val nowSentinel = 1.0e9 + 0.125

    private fun utf8Hex(text: String): String = ReviewFixture.hex(text.toByteArray(Charsets.UTF_8))

    private fun summary(snippets: List<Snippet>): String = if (snippets.isEmpty()) "-" else snippets.joinToString(";") { s ->
        listOf(
            s.id.toString(), utf8Hex(s.name), utf8Hex(s.keyword), utf8Hex(s.content),
            if (s.tags.isEmpty()) "-" else s.tags.joinToString(",") { utf8Hex(it) },
            if (s.isEnabled) "1" else "0", if (s.isPinned) "1" else "0",
            date(s.createdAt), date(s.updatedAt),
        ).joinToString("|")
    }

    private fun date(value: Double): String =
        if (value == nowSentinel) "now" else "%016x".format(value.toRawBits())

    @Test
    fun kotlinAndSwiftAgreeOnEveryInput() {
        val rows = ReviewFixture.rows("codec-differential.tsv.gz")
        assertTrue(rows.size > 2000, "fixture is unexpectedly small: ${rows.size}")
        val failures = ArrayList<String>()
        var accepted = 0
        for ((line, row) in rows.withIndex()) {
            val input = ReviewFixture.unhex(row[0])
            val swift = row[1]
            val shown = String(input, Charsets.ISO_8859_1).take(160).replace("\n", "\\n")
            val decoded = try {
                SnippetLibraryCodec.decode(input) { nowSentinel }
            } catch (_: SnippetLibraryCodec.Unreadable) {
                null
            } catch (other: Throwable) {
                failures.add("#$line Kotlin threw ${other.javaClass.simpleName} (${other.message}) for: $shown")
                continue
            }
            if (swift == "E") {
                if (decoded != null) failures.add("#$line Swift refuses, Kotlin decodes ${decoded.size}: $shown")
                continue
            }
            if (decoded == null) {
                failures.add("#$line Swift decodes, Kotlin refuses: $shown")
                continue
            }
            accepted += 1
            val parts = swift.split(' ')
            val kotlinSummary = summary(decoded)
            if (parts[2] != kotlinSummary) {
                failures.add("#$line decoded differently: $shown\n   swift  ${parts[2].take(300)}\n   kotlin ${kotlinSummary.take(300)}")
                continue
            }
            if (parts[3] != "-" && parts[3] != "!") {
                val reencoded = ReviewFixture.hex(SnippetLibraryCodec.encode(decoded))
                if (reencoded != parts[3]) {
                    val want = String(ReviewFixture.unhex(parts[3]), Charsets.UTF_8)
                    val got = String(ReviewFixture.unhex(reencoded), Charsets.UTF_8)
                    failures.add("#$line re-encoded differently: $shown\n   swift  ${want.take(400)}\n   kotlin ${got.take(400)}")
                }
            }
        }
        assertTrue(accepted > 500, "too few accepted inputs to mean anything: $accepted")
        if (failures.isNotEmpty()) {
            fail("${failures.size} of ${rows.size} inputs differ from Swift:\n" + failures.take(60).joinToString("\n"))
        }
    }
}
