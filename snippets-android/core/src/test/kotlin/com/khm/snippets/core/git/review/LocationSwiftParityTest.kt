package com.khm.snippets.core.git.review

import com.khm.snippets.core.git.GitRemoteConfigurationException
import com.khm.snippets.core.git.GitRepositoryLocation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Review: `GitRepositoryLocation.parse` against the Swift original.
 *
 * Every expected value here was produced by compiling `snippets/Core/Git/GitObjects.swift`,
 * `GitSmartHTTPClient.swift` and `GitSSHClient.swift` unchanged into a small command-line
 * program on macOS and printing `GitRepositoryLocation.parse(input)`'s `spec` and
 * `canonicalIdentity` (null: Swift throws `invalidURL`). `canonicalIdentity` feeds the
 * library key scope and the dataset digests, so it must be the same text on every
 * platform; `spec` is the address the client really connects to.
 *
 * Tests marked "failed before the fix" demonstrated a defect of the reviewed code; they
 * pass now and guard the fix.
 */
class LocationSwiftParityTest {
    private class Vector(val input: String, val spec: String?, val identity: String?)

    private class Parsed(val spec: String?, val identity: String?)

    private fun parse(input: String): Parsed = try {
        val location = GitRepositoryLocation.parse(input)
        Parsed(location.spec, location.canonicalIdentity)
    } catch (_: GitRemoteConfigurationException) {
        Parsed(null, null)
    }

    private fun printable(text: String): String =
        text.map { if (it.code in 0x20..0x7e) it.toString() else "\\u%04x".format(it.code) }.joinToString("")

    /**
     * Failed before the fix.
     *
     * `GitUrlNormalizer.normalizedHost` (GitRepositoryLocation.kt:298-306) converts a
     * non-ASCII host with `java.net.IDN.toASCII`, which implements IDNA 2003. Foundation
     * (and every current browser) uses UTS #46 without the transitional mappings. The
     * two disagree on sharp s, final sigma and the zero-width joiners:
     *
     *     https://strasse.de/me/lib written with a sharp s
     *         Apple:  xn--strae-oqa.de
     *         Kotlin: strasse.de
     *
     * `strasse.de` is a different registrable domain. Android would send the Basic
     * token to it, and would derive another `canonicalIdentity` (so another library key
     * scope) than an iPhone given the same address. Refusing such a host would be safe;
     * silently connecting somewhere else is not.
     */
    @Test fun anInternationalHostIsTheHostAppleDevicesUseOrIsRefused() {
        val problems = ArrayList<String>()
        for (vector in listOf(
            Vector("https://stra\u00dfe.de/me/lib", "https://xn--strae-oqa.de/me/lib", "xn--strae-oqa.de/me/lib"),
            Vector("https://fa\u00df.example/a", "https://xn--fa-hia.example/a", "xn--fa-hia.example/a"),
            Vector("https://\u1e9e.example/a", "https://xn--zca.example/a", "xn--zca.example/a"),
            Vector("https://\u03b2\u03cc\u03bb\u03bf\u03c2.example/a", "https://xn--nxasmm1c.example/a", "xn--nxasmm1c.example/a"),
            // Persian with a zero-width non-joiner, as registered names really use it.
            Vector("https://\u0646\u0627\u0645\u0647\u200c\u0627\u06cc.example/a", "https://xn--mgba3gch31f060k.example/a", "xn--mgba3gch31f060k.example/a"),
            // Foundation refuses a joiner between Latin letters; dropping it names another host.
            Vector("https://a\u200db.example/a", null, null),
            Vector("https://a\u200cb.example/a", null, null),
        )) {
            val parsed = parse(vector.input)
            if (parsed.spec == null) continue // Refused: safe.
            if (parsed.spec != vector.spec || parsed.identity != vector.identity) {
                problems.add("${printable(vector.input)}: Apple ${vector.spec ?: "refuses it"}, Kotlin ${parsed.spec}")
            }
        }
        assertTrue(problems.isEmpty(), problems.joinToString("\n", prefix = "\n"))
    }

    /**
     * Failed before the fix.
     *
     * `HostPort.split` (GitRepositoryLocation.kt:210-213) cuts an unbracketed authority
     * at its last colon, so an IPv6 literal written without brackets becomes a wrong
     * host and a port: `ssh://git@2001:db8::5/srv/r` is host `2001:db8:`, port 5, and
     * `GitSshLocation` accepts it because `:` is a legal host character. Swift
     * (`URLComponents`) refuses all of these.
     */
    @Test fun anUnbracketedIpv6AddressIsRefusedNotSplitIntoAHostAndAPort() {
        val accepted = listOf(
            "ssh://git@::1/r", "ssh://::1/r", "ssh://git@2001:db8::5/srv/r", "ssh://git@fe80::1/r", "ssh://git@a:b:22/r",
            "ssh://git@host:22:22/r",
        ).mapNotNull { input ->
            val location = try {
                GitRepositoryLocation.parse(input)
            } catch (_: GitRemoteConfigurationException) {
                return@mapNotNull null
            }
            val ssh = (location as GitRepositoryLocation.Ssh).location
            "$input -> host \"${ssh.host}\", port ${ssh.port}, saved as ${location.spec}"
        }
        assertTrue(accepted.isEmpty(), accepted.joinToString("\n", prefix = "Swift refuses these; Kotlin reads:\n"))
    }

    /**
     * A percent-escape that is not UTF-8. Swift's `URL.path` gives an empty string for
     * such a path, so its `canonicalIdentity` is `host/` (every such repository on a
     * host gets the same identity); the Linux mirror keeps the escaped text. Three
     * platforms, two answers, for a value documented as shared byte for byte.
     */
    @Test fun aPathThatIsNotUtf8IsRefused() {
        // Owner decision (review finding 7): Android refuses these addresses, so it
        // never shares a key scope with either reading. (Swift: identity `h/`.)
        assertEquals(null, parse("https://h/a%FFb").spec)
        assertEquals(null, parse("https://h/a%C3b").spec)
        assertEquals(null, parse("https://h/%ED%A0%80").spec)
        // Well-formed UTF-8 escapes are not affected.
        assertEquals("h/\u00e4", parse("https://h/%C3%A4").identity)
    }

    /**
     * Every vector: what Swift refuses, Kotlin refuses; what both accept has the same
     * `spec` and `canonicalIdentity`; and Kotlin refuses a Swift-accepted address only
     * when it is one of [refusedOnlyByKotlin].
     */
    @Test fun everyVectorMatchesSwift() {
        var compared = 0
        val problems = ArrayList<String>()
        for (vector in vectors) {
            val parsed = parse(vector.input)
            if (vector.input in refusedOnlyByKotlin) {
                if (vector.spec == null) problems.add("${printable(vector.input)}: listed as refused only by Kotlin, but Swift refuses it too")
                if (parsed.spec != null) problems.add("${printable(vector.input)}: listed as refused by Kotlin, but it reads ${parsed.spec}")
                continue
            }
            compared += 1
            if (parsed.spec != vector.spec || parsed.identity != vector.identity) {
                problems.add("${printable(vector.input)}: Swift ${vector.spec} [${vector.identity}], Kotlin ${parsed.spec} [${parsed.identity}]")
            }
        }
        assertTrue(problems.isEmpty(), problems.joinToString("\n", prefix = "\n"))
        assertTrue(compared > 170, "compared $compared")
        assertTrue(vectors.map { it.input }.containsAll(refusedOnlyByKotlin), "every listed address is a vector")
    }

    /**
     * Addresses Swift accepts and Kotlin refuses, each for a stated reason. (After
     * the review: nothing Swift refuses is accepted by Kotlin any more, and an empty
     * port, brackets around a name, a full-width ASCII host and `ssh://ssh://…` are
     * read exactly as Swift reads them.)
     */
    private val refusedOnlyByKotlin = setOf(
        // An HTTP client would rewrite these, so the address requested would not be the
        // one saved: a stray `%`, `.` and `..` segments, a backslash.
        "https://h/a%zzb", "https://h/%", "https://h/a%", "https://h/a%4",
        "https://h/a/./b", "https://h/a/../b", "https://h/a/%2e%2e/b", "https://h/a/%2E/b", "https://h/a\\b",
        // An escaped host: Foundation unescapes it once here (`h%2ecom`), twice
        // elsewhere (`h%2525x`) and not at all for `h%00x`.
        "https://h%2ecom/a", "https://h%41/a",
        // Port 0 and ports above 65535 (Swift keeps them, or takes a very long one for
        // no port): stacks disagree about which endpoint such a number names.
        "https://h:0/a", "https://h:65536/a", "ssh://git@h:99999999999999999999/r",
        // No host at all: every such address would share the identity `/path`.
        "https://[]/r",
        // A zone identifier: Foundation unescapes it a varying number of times
        // (`%en0`, `%25en0` and `%2525en0` are one address to it), and it names a
        // network interface of one device.
        "https://[fe80::1%25en0]/a",
        // Owner decision (review finding 7): escapes that are not UTF-8.
        "https://h/a%FFb", "https://h/a%C3b",
        // A joiner (here in a Persian name, where it is valid): the context rules
        // need tables this code does not have, and a host is refused rather than
        // guessed. The same name written as `xn--mgba3gch31f060k` is refused too.
        "https://\u0646\u0627\u0645\u0647\u200c\u0627\u06cc.example/a",
    )

    private val vectors = listOf(
        Vector("https://fa\u00df.example/a", "https://xn--fa-hia.example/a", "xn--fa-hia.example/a"),
        Vector("https://stra\u00dfe.de/me/lib", "https://xn--strae-oqa.de/me/lib", "xn--strae-oqa.de/me/lib"),
        Vector("https://\u03b2\u03cc\u03bb\u03bf\u03c2.example/a", "https://xn--nxasmm1c.example/a", "xn--nxasmm1c.example/a"),
        Vector("https://a\u200db.example/a", null, null),
        Vector("https://a\u200cb.example/a", null, null),
        Vector("https://\u0515.example/a", "https://xn--s7a.example/a", "xn--s7a.example/a"),
        Vector("https://\u0514.example/a", "https://xn--s7a.example/a", "xn--s7a.example/a"),
        Vector("https://\ud83d\ude00.example/a", "https://xn--e28h.example/a", "xn--e28h.example/a"),
        Vector("https://\u01c5.example/a", "https://xn--d-toa.example/a", "xn--d-toa.example/a"),
        Vector("https://i\u0307.example/a", "https://xn--i-9bb.example/a", "xn--i-9bb.example/a"),
        Vector("https://\u0130stanbul.example/a", "https://xn--istanbul-o0e.example/a", "xn--istanbul-o0e.example/a"),
        Vector("https://\uff41.example/a", "https://a.example/a", "a.example/a"),
        Vector("https://a\u3002b/a", "https://a.b/a", "a.b/a"),
        Vector("https://a\uff0eb/a", "https://a.b/a", "a.b/a"),
        Vector("https://\u210c.example/a", "https://h.example/a", "h.example/a"),
        Vector("https://\u3392.example/a", "https://mhz.example/a", "mhz.example/a"),
        Vector("https://\ufb01.example/a", "https://fi.example/a", "fi.example/a"),
        Vector("https://a\u00adb.example/a", "https://ab.example/a", "ab.example/a"),
        Vector("https://\u00e9.example/a", "https://xn--9ca.example/a", "xn--9ca.example/a"),
        Vector("https://e\u0301.example/a", "https://xn--9ca.example/a", "xn--9ca.example/a"),
        Vector("https://xn--fa-hia.example/a", "https://xn--fa-hia.example/a", "xn--fa-hia.example/a"),
        Vector("https://XN--BCHER-KVA.example/a", "https://xn--bcher-kva.example/a", "xn--bcher-kva.example/a"),
        Vector("https://xn--a.example/a", null, null),
        Vector("https://-a.example/a", "https://-a.example/a", "-a.example/a"),
        Vector("https://a-.example/a", "https://a-.example/a", "a-.example/a"),
        Vector("https://ab--c.example/a", "https://ab--c.example/a", "ab--c.example/a"),
        Vector("https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example/a", "https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example/a", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example/a"),
        Vector("https://1.2.3.4.5/a", "https://1.2.3.4.5/a", "1.2.3.4.5/a"),
        Vector("https://0x7f.0.0.1/a", "https://0x7f.0.0.1/a", "0x7f.0.0.1/a"),
        Vector("https://127.1/a", "https://127.1/a", "127.1/a"),
        Vector("https://a_b.example/a", "https://a_b.example/a", "a_b.example/a"),
        Vector("https://a..b/a", "https://a..b/a", "a..b/a"),
        Vector("https://.a/a", "https://.a/a", ".a/a"),
        Vector("https://a./a", "https://a./a", "a./a"),
        Vector("https://a../a", "https://a../a", "a../a"),
        Vector("https://\u0663.example/a", null, null),
        Vector("https://\u0661\u0662\u0667.\u0660.\u0660.\u0661/a", null, null),
        Vector("https://K.example/a", "https://k.example/a", "k.example/a"),
        Vector("https://\u00c5.example/a", "https://xn--5ca.example/a", "xn--5ca.example/a"),
        Vector("ssh://git@2001:db8::5/srv/r", null, null),
        Vector("ssh://git@a:b:22/r", null, null),
        Vector("ssh://git@fe80::1/r", null, null),
        Vector("ssh://git@::1/r", null, null),
        Vector("ssh://git@[2001:db8::5]/srv/r", "ssh://git@[2001:db8::5]/srv/r", "2001:db8::5/srv/r"),
        Vector("ssh://::1/r", null, null),
        Vector("ssh://git@host:22:22/r", null, null),
        Vector("ssh://[::1]:22:22/r", null, null),
        Vector("ssh://[::1]x/r", null, null),
        Vector("ssh://[]/r", null, null),
        Vector("ssh://[]:22/r", null, null),
        Vector("ssh://[a]/r", "ssh://a/r", "a/r"),
        Vector("ssh://[::1]]/r", null, null),
        Vector("ssh://[[::1]]/r", null, null),
        Vector("ssh://git@[h]/r", "ssh://git@h/r", "h/r"),
        Vector("ssh://git@[h]:22/r", "ssh://git@h:22/r", "h/r"),
        Vector("https://[h]/r", "https://[h]/r", "h/r"),
        Vector("https://[::1]]/r", null, null),
        Vector("https://[]/r", "https://[]/r", "/r"),
        Vector("https://\u1e9e.example/a", "https://xn--zca.example/a", "xn--zca.example/a"),
        Vector("https://\u0646\u0627\u0645\u0647\u200c\u0627\u06cc.example/a", "https://xn--mgba3gch31f060k.example/a", "xn--mgba3gch31f060k.example/a"),
        Vector("https://b\u00fccher.example/me/lib", "https://xn--bcher-kva.example/me/lib", "xn--bcher-kva.example/me/lib"),
        Vector("https://B\u00dcCHER.example/me/lib", "https://xn--bcher-kva.example/me/lib", "xn--bcher-kva.example/me/lib"),
        Vector("https://xn--bcher-kva.example/a", "https://xn--bcher-kva.example/a", "xn--bcher-kva.example/a"),
        Vector("https://h/a%20b", "https://h/a%20b", "h/a b"),
        Vector("https://h/\u00e4/lib.git", "https://h/%C3%A4/lib.git", "h/\u00e4/lib"),
        Vector("https://h/%C3%A4/lib.git", "https://h/%C3%A4/lib.git", "h/\u00e4/lib"),
        Vector("https://h/a%FFb", "https://h/a%FFb", "h/"),
        Vector("https://h/a%zzb", "https://h/a%25zzb", "h/a%zzb"),
        Vector("https://h//a//b//", "https://h//a//b", "h/a//b"),
        Vector("https://h/a/./b", "https://h/a/./b", "h/a/./b"),
        Vector("https://h/a/../b", "https://h/a/../b", "h/a/../b"),
        Vector("https://h/a/%2e%2e/b", "https://h/a/%2e%2e/b", "h/a/../b"),
        Vector("https://h:443/a", "https://h:443/a", "h/a"),
        Vector("https://H:8443/a/", "https://h:8443/a", "h/a"),
        Vector("https://h/a.git/", "https://h/a.git", "h/a"),
        Vector("https://h/a.GIT", "https://h/a.GIT", "h/a.GIT"),
        Vector("https://h/.git", "https://h/.git", "h/"),
        Vector("https://h/a.git.git", "https://h/a.git.git", "h/a.git"),
        Vector("https://[::1]/a", "https://[::1]/a", "::1/a"),
        Vector("https://[::1]:8443/a", "https://[::1]:8443/a", "::1/a"),
        Vector("https://[::FFFF:1.2.3.4]/a", "https://[::ffff:1.2.3.4]/a", "::ffff:1.2.3.4/a"),
        Vector("https://[fe80::1%25en0]/a", "https://[fe80::1%25en0]/a", "fe80::1%en0/a"),
        Vector("https://h/a;b=c", "https://h/a;b=c", "h/a;b=c"),
        Vector("https://h/a|b", "https://h/a%7Cb", "h/a|b"),
        Vector("https://h/a[b]", "https://h/a%5Bb%5D", "h/a[b]"),
        Vector("https://h/a\\b", "https://h/a%5Cb", "h/a\\b"),
        Vector("https://h./a", "https://h./a", "h./a"),
        Vector("https://h/a%2Egit", "https://h/a%2Egit", "h/a"),
        Vector("https://h/a%2Fb", "https://h/a%2Fb", "h/a/b"),
        Vector("https://h/a%2fb.git", "https://h/a%2fb.git", "h/a/b"),
        Vector("h/a", "https://h/a", "h/a"),
        Vector("h:8443/a", "h:8443/a", "h/8443/a"),
        Vector("https://h/a?", null, null),
        Vector("https://h/a#", null, null),
        Vector("https://user@h/a", null, null),
        Vector("https://h/%", "https://h/%25", "h/%"),
        Vector("https://h/a%", "https://h/a%25", "h/a%"),
        Vector("https://h/a%4", "https://h/a%254", "h/a%4"),
        Vector("HTTPS://H/A", "https://h/A", "h/A"),
        Vector("https://h/a%00b", "https://h/a%00b", "h/a\u0000b"),
        Vector("https://h/a%0Ab", "https://h/a%0Ab", "h/a\u000ab"),
        Vector("https://h/a+b", "https://h/a+b", "h/a+b"),
        Vector("https://h/a%2Bb", "https://h/a%2Bb", "h/a+b"),
        Vector("https://h/a~b", "https://h/a~b", "h/a~b"),
        Vector("https://h/a^b", "https://h/a%5Eb", "h/a^b"),
        Vector("https://h/a{b}", "https://h/a%7Bb%7D", "h/a{b}"),
        Vector("https://h/a\"b", "https://h/a%22b", "h/a\"b"),
        Vector("https://h/a<b>", "https://h/a%3Cb%3E", "h/a<b>"),
        Vector("https://h/%41", "https://h/%41", "h/A"),
        Vector("https://h//", null, null),
        Vector("https://h/", null, null),
        Vector("https://h", null, null),
        Vector("https://-h/a", "https://-h/a", "-h/a"),
        Vector("https://h_x/a", "https://h_x/a", "h_x/a"),
        Vector("https://h..x/a", "https://h..x/a", "h..x/a"),
        Vector("https://1.2.3.4/a", "https://1.2.3.4/a", "1.2.3.4/a"),
        Vector("https://h:0/a", "https://h:0/a", "h/a"),
        Vector("https://h:65536/a", "https://h:65536/a", "h/a"),
        Vector("https://h:/a", "https://h/a", "h/a"),
        Vector("https://h:08443/a", "https://h:8443/a", "h/a"),
        Vector("https://h/a%25b", "https://h/a%25b", "h/a%b"),
        Vector("https://h/a%2525b", "https://h/a%2525b", "h/a%25b"),
        Vector("https://h/a:b", "https://h/a:b", "h/a:b"),
        Vector("https://h/a@b", "https://h/a@b", "h/a@b"),
        Vector("https://h/a=b&c", "https://h/a=b&c", "h/a=b&c"),
        Vector("https://h/a'b", "https://h/a'b", "h/a'b"),
        Vector("https://h/a(b)", "https://h/a(b)", "h/a(b)"),
        Vector("https://h/a*b", "https://h/a*b", "h/a*b"),
        Vector("https://h/a,b", "https://h/a,b", "h/a,b"),
        Vector("https://h/a!b", "https://h/a!b", "h/a!b"),
        Vector("https://h/a\$b", "https://h/a\$b", "h/a\$b"),
        Vector("https://h/a`b", "https://h/a%60b", "h/a`b"),
        Vector("https://h/\ud83d\ude00/lib", "https://h/%F0%9F%98%80/lib", "h/\ud83d\ude00/lib"),
        Vector("https://h/%F0%9F%98%80/lib", "https://h/%F0%9F%98%80/lib", "h/\ud83d\ude00/lib"),
        Vector("https://h/a%C3b", "https://h/a%C3b", "h/"),
        Vector("https://\u02b0/a", "https://h/a", "h/a"),
        Vector("https://\uff48.example/a", "https://h.example/a", "h.example/a"),
        Vector("https://h%2ecom/a", "https://h.com/a", "h.com/a"),
        Vector("https://h%41/a", "https://ha/a", "ha/a"),
        Vector("https://h/a%2F/", "https://h/a%2F", "h/a"),
        Vector("https://h/a/.git", "https://h/a/.git", "h/a"),
        Vector("https://h/a.git/.git", "https://h/a.git/.git", "h/a.git"),
        Vector("ssh://git@h:/abs", "ssh://git@h/abs", "h/abs"),
        Vector("ssh://git@h/~user/r", "ssh://git@h/~user/r", "h/~user/r"),
        Vector("ssh://h/a%20b", null, null),
        Vector("ssh://GIT@H/r", "ssh://GIT@H/r", "h/r"),
        Vector("ssh://h:22/r.git/", "ssh://h:22/r.git/", "h/r.git"),
        Vector("git@h:r.git/", "git@h:r.git/", "h/r.git"),
        Vector("ssh://[::1]/r", "ssh://[::1]/r", "::1/r"),
        Vector("ssh://[fe80::1%25en0]/r", null, null),
        Vector("ssh://h/a%2Fb", "ssh://h/a/b", "h/a/b"),
        Vector("git+ssh://h/r", "ssh://h/r", "h/r"),
        Vector("GIT+SSH://h/r", "ssh://h/r", "h/r"),
        Vector("Git+Ssh://h/r", "ssh://h/r", "h/r"),
        Vector("ssh://h", null, null),
        Vector("ssh:///r", null, null),
        Vector("ssh://a@b@h/r", null, null),
        Vector("ssh://h/r#f", null, null),
        Vector("ssh://h//r", "ssh://h//r", "h/r"),
        Vector("ssh://h/r%", null, null),
        Vector("ssh://%67it@h/r", "ssh://git@h/r", "h/r"),
        Vector("ssh://h%2e/r", "ssh://h./r", "h./r"),
        Vector("ssh://h%2ex/r", "ssh://h.x/r", "h.x/r"),
        Vector("git@h:~/r", "git@h:~/r", "h/~/r"),
        Vector("git@h:/abs/r.git", "git@h:/abs/r.git", "h/abs/r"),
        Vector("h:r", "h:r", "h/r"),
        Vector("a@b@h:r", null, null),
        Vector("ssh://git@h:22a/r", null, null),
        Vector("ssh://git@h:022/r", "ssh://git@h:22/r", "h/r"),
        Vector("ssh://git@h:0/r", null, null),
        Vector("ssh://git@h:65536/r", null, null),
        Vector("ssh://git@h:99999999999999999999/r", "ssh://git@h/r", "h/r"),
        Vector("ssh://git:@h/r", null, null),
        Vector("ssh://:pw@h/r", null, null),
        Vector("ssh://@h/r", null, null),
        Vector("ssh://git@/r", null, null),
        Vector("ssh://git@h/r?", null, null),
        Vector("ssh://git@h/r/../x", null, null),
        Vector("ssh://git@h/r/%2e%2e/x", null, null),
        Vector("ssh://git@h/\u00e4", "ssh://git@h/\u00e4", "h/\u00e4"),
        Vector("ssh://git@h/%C3%A4", "ssh://git@h/\u00e4", "h/\u00e4"),
        Vector("ssh://git@h/%FF", null, null),
        Vector("ssh://git@\uff48/r", "ssh://git@h/r", "h/r"),
        Vector("ssh://git@b\u00fccher.example/r", null, null),
        Vector("git@b\u00fccher.example:r", null, null),
        Vector("ssh://git@h/a%41", "ssh://git@h/aA", "h/aA"),
        Vector("ssh://git@h/a%2541", null, null),
        Vector("ssh://git@H.Example/Repo.GIT", "ssh://git@H.Example/Repo.GIT", "h.example/Repo.GIT"),
        Vector("ssh://git@h/.git", "ssh://git@h/.git", "h/"),
        Vector("ssh://git@h/r.git.git", "ssh://git@h/r.git.git", "h/r.git"),
        Vector("git@h:.git", "git@h:.git", "h/"),
        Vector("ssh://git@[::1]:22/r", "ssh://git@[::1]:22/r", "::1/r"),
        Vector("ssh://git@[::1/r", null, null),
        Vector("ssh://git@h/a:b", "ssh://git@h/a:b", "h/a:b"),
        Vector("git@h:a:b", "git@h:a:b", "h/a:b"),
        Vector("ssh://git@h/a@b", "ssh://git@h/a@b", "h/a@b"),
        Vector("ssh://git@h/a=b", "ssh://git@h/a=b", "h/a=b"),
        Vector("ssh://git@h/a+b", "ssh://git@h/a+b", "h/a+b"),
        Vector("ssh://git@h/a,b", "ssh://git@h/a,b", "h/a,b"),
        Vector("ssh://git@h/a~b", "ssh://git@h/a~b", "h/a~b"),
        Vector("ssh://git@h/a^b", "ssh://git@h/a^b", "h/a^b"),
        Vector("ssh://git@h/a%5Eb", "ssh://git@h/a^b", "h/a^b"),
        Vector("ssh://git@h/a b", null, null),
        Vector("ssh://git@h/a%09b", null, null),
        Vector("ssh://sSh://h/r", "ssh://sSh//h/r", "ssh/h/r"),
        Vector("ssh://git@h/r/", "ssh://git@h/r/", "h/r"),
        Vector("ssh://git@h//", "ssh://git@h//", "h/"),
        Vector("ssh://git@h/", "ssh://git@h/", "h/"),
        Vector("ssh://ssh://h/r", "ssh://ssh//h/r", "ssh/h/r"),
        Vector("git@h:r\\x", null, null),
        Vector("file:///tmp/r", null, null),
        Vector("git://h/r", null, null),
        Vector("https://h/a%E2%80%8Bb", "https://h/a%E2%80%8Bb", "h/a\u200bb"),
        Vector("https://h/a/%2E/b", "https://h/a/%2E/b", "h/a/./b"),
        Vector("ssh://git@h/%2e%2e/x", null, null),
        Vector("https://localhost/a", "https://localhost/a", "localhost/a"),
        Vector("http://localhost/a", null, null),
        Vector("https://h/a%3Fb", "https://h/a%3Fb", "h/a?b"),
        Vector("https://h/a%23b", "https://h/a%23b", "h/a#b"),
        Vector(" git@github.com:me/lib.git\u000a", "git@github.com:me/lib.git", "github.com/me/lib"),
        Vector("https://h/a\u200b", "https://h/a", "h/a"),
        Vector("\u200bhttps://h/a", "https://h/a", "h/a"),
        Vector("https://h/a\u00a0b", "https://h/a%C2%A0b", "h/a\u00a0b"),
        Vector("https://h/a\u0085", "https://h/a", "h/a"),
        Vector("https://h/a\u001fb", null, null),
        Vector("\u001fhttps://h/a", null, null),
        Vector("https://h/a\u007f", null, null),
    )
}
