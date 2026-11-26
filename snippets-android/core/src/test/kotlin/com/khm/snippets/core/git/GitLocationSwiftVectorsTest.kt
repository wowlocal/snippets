package com.khm.snippets.core.git

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * `GitRepositoryLocation.parse` against about three thousand answers of the Swift
 * original.
 *
 * `core/src/test/resources/git/location-swift-vectors.jsonl` was produced on macOS by
 * compiling `snippets/Core/Git/GitObjects.swift`, `GitSmartHTTPClient.swift` and
 * `GitSSHClient.swift` unchanged with the small `main` kept next to it
 * (`location-swift-oracle.swift.txt`) and feeding it hand-picked addresses and a
 * structured random corpus. Each line holds the input, Swift's `spec` and
 * `canonicalIdentity` (`null`: Swift throws `invalidURL`), and what Android does:
 * `same`, or `refused` with the reason the generator assigned.
 *
 * The rules this pins:
 * - whatever Swift refuses, Android refuses;
 * - whatever both accept has the same `spec` and the same `canonicalIdentity`;
 * - Android refuses a Swift-accepted address only for one of the stated reasons.
 *
 * (While the parser was written, the same comparison ran against the Swift binary
 * over every Unicode scalar in nineteen positions of an address, about twenty million
 * addresses, and over 1.9 million random ones. The final parser accepted none that
 * Swift refuses or reads differently. That was one macOS release; an older Foundation
 * with older Unicode tables may differ for characters added since.)
 */
class GitLocationSwiftVectorsTest {
    private class Vector(val input: String, val spec: String?, val identity: String?, val android: String, val why: String?)

    private val vectors: List<Vector> by lazy {
        val stream = checkNotNull(javaClass.getResourceAsStream("/git/location-swift-vectors.jsonl")) { "vector resource is missing" }
        stream.bufferedReader(Charsets.UTF_8).useLines { lines ->
            lines.filter { it.isNotBlank() }.map { line ->
                val row = Json.parseToJsonElement(line).jsonObject
                val swift = row.getValue("swift")
                Vector(
                    input = row.getValue("input").jsonPrimitive.content,
                    spec = (swift as? JsonObject)?.getValue("spec")?.jsonPrimitive?.content,
                    identity = (swift as? JsonObject)?.getValue("identity")?.jsonPrimitive?.content,
                    android = row.getValue("android").jsonPrimitive.content,
                    why = row["why"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content,
                )
            }.toList()
        }
    }

    private fun printable(text: String): String =
        text.map { if (it.code in 0x20..0x7e) it.toString() else "\\u%04x".format(it.code) }.joinToString("")

    private fun parse(input: String): GitRepositoryLocation? = try {
        GitRepositoryLocation.parse(input)
    } catch (_: GitRemoteConfigurationException) {
        null
    }

    /** The reasons for which Android refuses an address Swift accepts. Each is documented where the parser decides it. */
    private val statedReasons = setOf(
        "stray percent", "dot segment", "backslash", "escaped host", "port out of range", "empty host",
        "empty port after brackets", "zone identifier", "punycode in brackets", "punycode prefix not in ascii",
        "escape not utf-8", "joiner in host", "delimiter inside a cluster", "scheme named twice",
    )

    @Test fun everySwiftVectorIsReadAsSwiftReadsItOrRefusedForAStatedReason() {
        val problems = ArrayList<String>()
        var same = 0
        var refusedByBoth = 0
        var refusedByAndroidOnly = 0
        for (vector in vectors) {
            val parsed = parse(vector.input)
            when {
                vector.spec == null -> {
                    if (parsed != null) problems.add("${printable(vector.input)}: Swift refuses it, Kotlin reads ${printable(parsed.spec)}")
                    assertEquals("same", vector.android)
                    refusedByBoth += 1
                }
                vector.android == "refused" -> {
                    if (parsed != null) problems.add("${printable(vector.input)}: pinned as refused, Kotlin reads ${printable(parsed.spec)}")
                    assertTrue(vector.why in statedReasons, "${printable(vector.input)}: ${vector.why}")
                    refusedByAndroidOnly += 1
                }
                parsed == null -> problems.add("${printable(vector.input)}: Swift ${printable(vector.spec)}, Kotlin refuses it")
                parsed.spec != vector.spec || parsed.canonicalIdentity != vector.identity -> problems.add(
                    "${printable(vector.input)}: Swift ${printable(vector.spec)} [${printable(vector.identity!!)}], " +
                        "Kotlin ${printable(parsed.spec)} [${printable(parsed.canonicalIdentity)}]",
                )
                else -> same += 1
            }
        }
        assertTrue(problems.isEmpty(), problems.take(40).joinToString("\n", prefix = "${problems.size} problems\n"))
        // Not vacuous in any of the three groups.
        assertTrue(same > 400 && refusedByBoth > 1_500 && refusedByAndroidOnly > 100, "$same same, $refusedByBoth refused by both, $refusedByAndroidOnly by Android only")
    }

    /** Settings stores `spec` and requires that reading it back gives the same location. */
    @Test fun everyAcceptedVectorSurvivesBeingSavedAndReadBack() {
        for (vector in vectors) {
            val location = parse(vector.input) ?: continue
            val again = parse(location.spec) ?: fail("${printable(vector.input)}: its own spec ${printable(location.spec)} is refused")
            assertEquals(location, again, printable(vector.input))
            assertEquals(location.spec, again.spec, printable(vector.input))
            assertEquals(location.canonicalIdentity, again.canonicalIdentity, printable(vector.input))
            assertTrue(location.sameEndpoint(again))
            // An accepted HTTPS address is one the HTTP client reads with the same host, or refuses.
            if (location is GitRepositoryLocation.Https) {
                val url = location.url
                assertEquals(url.host, url.host.lowercase(), printable(vector.input))
                assertTrue(url.host.all { it.code in 0x21..0x7e }, printable(vector.input))
                assertTrue(url.encodedPath.startsWith("/") && !url.encodedPath.endsWith("/"), printable(vector.input))
            }
        }
    }

    /** Whatever is typed, the only failure is the closed configuration error. */
    @Test fun arbitraryTextNeverEscapesTheClosedConfigurationError() {
        val random = Random(20261126)
        val pieces = listOf(
            "https://", "http://", "ssh://", "git+ssh://", "://", "//", "/", ":", "@", "#", "?", "%", "%2e", "%2F", "%C3", "%ff", "%00", ".", "..", "[", "]",
            "[::1]", "xn--", "xn--a", "xn--zca", "h", "example.com", "git", "22", "0", "65536", "99999999999999999999", "-", "_", "~", "!", "\\", " ", "\t", "\n",
            "\u0000", "\u007f", "\u00e9", "\u00df", "\u0301", "\u200d", "\u200c", "\u0600", "\u05d0", "\u0663", "\uff0e", "\u3002", "\uff41", "\ufe0f",
            "\ud83d\ude00", "\ud83d", "\ude00", "\udbff\udfff", "\ufffe", "\u0e33", "a".repeat(70), "\u00e9".repeat(70),
        )
        repeat(60_000) {
            val text = (0 until 1 + random.nextInt(8)).joinToString("") { pieces[random.nextInt(pieces.size)] }
            for (loopback in listOf(false, true)) {
                try {
                    val location = GitRepositoryLocation.parse(text, allowsInsecureLoopback = loopback)
                    // What is accepted can be saved, read back, and turned into a remote.
                    assertEquals(location, GitRepositoryLocation.parse(location.spec, allowsInsecureLoopback = loopback), printable(text))
                    location.canonicalIdentity
                } catch (_: GitRemoteConfigurationException) {
                } catch (error: Throwable) {
                    fail("${printable(text)}: ${error.javaClass.name}: ${error.message}")
                }
                try {
                    GitRemote.https(text, "main", "user", "token", allowsInsecureLoopback = loopback)
                } catch (_: GitRemoteConfigurationException) {
                } catch (error: Throwable) {
                    fail("GitRemote.https(${printable(text)}): ${error.javaClass.name}: ${error.message}")
                }
            }
        }
    }
}
