package com.khm.snippets.core.git

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Port of `GitRepositoryLocationTests` (Tests/Core/GitSSHTests.swift), same test
 * names, followed by the Linux identity vectors (`snippets-linux/src/git_tests.rs`).
 *
 * Not ported: `sharedConnectionsAreKeptApartPerAlias` and
 * `systemSSHNeverPromptsAndEndsOptionsBeforeTheHost`, which test the macOS
 * `/usr/bin/ssh` process connector that Android does not have.
 */
class GitRepositoryLocationTest {
    private fun parse(text: String, allowsInsecureLoopback: Boolean = false) =
        GitRepositoryLocation.parse(text, allowsInsecureLoopback)

    private fun ssh(text: String): GitSshLocation = (parse(text) as GitRepositoryLocation.Ssh).location

    private fun assertInvalid(text: String, allowsInsecureLoopback: Boolean = false) {
        val failure = assertFailsWith<GitRemoteConfigurationException>(text) { parse(text, allowsInsecureLoopback) }
        assertEquals(GitRemote.Failure.INVALID_URL, failure.failure, text)
    }

    // MARK: Swift

    @Test fun everySpellingOfOneRepositoryHasOneIdentity() {
        val spellings = listOf(
            "https://github.com/me/lib",
            "https://GitHub.com/me/lib.git",
            "https://github.com/me/lib/",
            "github.com/me/lib",
            "git@github.com:me/lib.git",
            "git@GitHub.com:me/lib",
            "ssh://git@github.com/me/lib.git",
            "ssh://git@github.com:22/me/lib",
            "git+ssh://git@github.com/me/lib.git",
        )
        for (spelling in spellings) assertEquals("github.com/me/lib", parse(spelling).canonicalIdentity, spelling)
        assertEquals("github.com/me/Lib", parse("git@github.com:me/Lib").canonicalIdentity)
        assertEquals("gitverse.ru/me/lib x", parse("https://gitverse.ru/me/lib%20x").canonicalIdentity)
    }

    @Test fun sshSpellingsParseIntoTheirParts() {
        val scp = ssh(" git@github.com:me/lib.git\n")
        assertEquals(GitSshLocation(user = "git", host = "github.com", port = null, path = "me/lib.git", scpStyle = true), scp)
        assertEquals("git@github.com:me/lib.git", scp.spec)

        val url = ssh("ssh://git@[::1]:2222/srv/lib.git")
        assertEquals("::1", url.host)
        assertEquals(2222, url.port)
        assertEquals("/srv/lib.git", url.path)
        assertEquals("ssh://git@[::1]:2222/srv/lib.git", url.spec)
        assertEquals(GitRepositoryLocation.Ssh(url), parse(url.spec))

        // An ssh alias without a user is still ssh.
        val alias = ssh("work-github:team/lib")
        assertNull(alias.user)
        assertEquals("work-github", alias.destination)
        assertFalse(parse("https://host/a").isSsh)
    }

    @Test fun valuesThatCouldReachAShellOrAnOptionAreRefused() {
        for (hostile in listOf(
            "-oProxyCommand=evil:repo", "git@-oProxyCommand=x:repo", "git@host:-repo",
            "git@host:repo;rm", "git@host:'repo'", "git@host:$(id)", "git@host:a/../b",
            "git@host:repo name", "ssh://git@host/repo`x`", "ssh://user:pw@host/repo",
            "ssh://host/repo?x=1", "git@.host:repo", "git@host:", "ftp://host/repo",
            "http://example.com/repo",
        )) {
            assertInvalid(hostile)
        }
    }

    /** Settings stores `spec` and requires that reading it back gives the same text. */
    @Test fun savedAddressesRoundTrip() {
        for (raw in listOf(
            "git@github.com:me/lib.git", "ssh://git@github.com/me/lib.git", "ssh://git@[::1]:2222/srv/lib.git",
            "git+ssh://git@host/r.git", "SSH://git@Host:22/r", "work-alias:team/lib", "ssh://h/~me/lib.git",
            "https://github.com/me/lib", "https://gitverse.ru/me/lib.git/", "https://h:8443/a/b",
            "git@host:päth/lib.git",
        )) {
            val location = parse(raw)
            assertEquals(location, parse(location.spec), raw)
            assertEquals(location.spec, parse(location.spec).spec, raw)
        }
        // A decoded `%` would be re-decoded on the next read; refuse it.
        assertInvalid("ssh://git@host/a%2541")
        assertInvalid("git@host:a%41")
    }

    @Test fun remoteCommandsQuoteThePathLikeGit() {
        val scp = GitSshLocation(user = "git", host = "h", port = null, path = "me/lib.git", scpStyle = true)
        assertEquals("git-upload-pack 'me/lib.git'", GitSshClient.remoteCommand(GitService.UPLOAD_PACK, scp))
        val home = GitSshLocation(user = null, host = "h", port = null, path = "/~me/lib.git", scpStyle = false)
        assertEquals("git-receive-pack '~me/lib.git'", GitSshClient.remoteCommand(GitService.RECEIVE_PACK, home))
    }

    @Test fun remoteDescriptionsNeverCarryTheToken() {
        val remote = GitRemote.https("https://h/r", "main", "u", "tok-secret")
        assertFalse(remote.toString().contains("tok-secret"))
        val ssh = GitRemote.ssh(GitSshLocation(user = "git", host = "h", port = null, path = "r", scpStyle = true), "main")
        assertEquals("h/r", ssh.canonicalLocation)
        assertTrue(ssh.password.isEmpty())
        assertNull(ssh.url)
    }

    // MARK: Linux vectors (git_tests.rs)

    /** `repository_identity_matches_the_apple_rule` */
    @Test fun repositoryIdentityMatchesTheLinuxVectors() {
        fun canonical(text: String) = parse(text).canonicalIdentity
        for (text in listOf(
            "git@github.com:me/lib.git",
            "ssh://git@GitHub.com:22/me/lib.git",
            "git+ssh://git@github.com/me/lib",
            "https://github.com/me/lib/",
            "https://GITHUB.com/me/lib.git",
            "github.com/me/lib",
            "  https://github.com/me/lib  ",
        )) {
            assertEquals("github.com/me/lib", canonical(text), text)
        }
        // Path case is preserved; the path is percent-decoded; only one ".git" goes.
        assertEquals("gitverse.ru/Me/Lib X", canonical("https://gitverse.ru/Me/Lib%20X.git"))
        assertEquals("host/~/repo", canonical("ssh://host/~/repo.git"))
        assertEquals("host/~/repo", canonical("host:~/repo.git"))
        assertEquals("host/lib.git", canonical("git@host:lib.git.git"))
        // ".git" is removed before trailing slashes, exactly as on Apple.
        assertEquals("host/lib.git", canonical("git@host:lib.git/"))
        assertEquals("::1/srv/lib", canonical("ssh://[::1]:2222/srv/lib.git"))
        // One percent-decoding pass; a '%' left after it is refused, as on Apple.
        assertEquals("host/aAb", canonical("ssh://host/a%41b.git"))
        for (refused in listOf("git@host:li%41b", "ssh://host/a%2541", "git@host:100%")) assertInvalid(refused)
        assertEquals("example.com/a/b", canonical("https://Example.com:8443/a/b"))
        // Specs are normalized for storage; user and port are kept there.
        fun spec(text: String) = parse(text).spec
        assertEquals("ssh://git@GitHub.com:22/me/lib.git", spec("ssh://git@GitHub.com:22/me/lib.git"))
        assertEquals("git@github.com:me/lib.git", spec("git@github.com:me/lib.git"))
        assertEquals("https://github.com/me/lib", spec("HTTPS://GitHub.com/me/lib/"))
        assertEquals("https://github.com/me/lib", spec("github.com/me/lib"))
        assertTrue(parse("git@github.com:me/lib.git").isSsh)
        assertFalse(parse("github.com/me/lib").isSsh)
    }

    /** `unsafe_or_ambiguous_locations_are_refused` */
    @Test fun unsafeOrAmbiguousLocationsAreRefused() {
        for (text in listOf(
            "",
            "-oProxyCommand=x:lib",
            "git@-host:lib",
            "git@.host:lib",
            "-user@host:lib",
            "git@host:-lib",
            "git@host:lib;rm",
            "git@host:li\$b",
            "git@host:a/../b",
            "git@host:lib name",
            "ssh://host",
            "ssh://user:pw@host/lib",
            "ssh://host:0/lib",
            "ssh://host:70000/lib",
            "ssh://host/lib?x",
            "http://example.com/lib",
            "http://127.0.0.1/lib",
            "https://user:pw@github.com/me/lib",
            "https://github.com/me/lib?x=1",
            "https://github.com/me/lib#x",
            "https://github.com",
            "https://github.com/",
            "file:///tmp/lib.git",
            "ftp://host/lib",
        )) {
            assertInvalid(text)
        }
        // Plain HTTP only to loopback, only when a test harness opts in.
        assertEquals("http://127.0.0.1:8080/lib.git", parse("http://127.0.0.1:8080/lib.git", true).spec)
        assertEquals("http://[::1]:8080/lib.git", parse("http://[::1]:8080/lib.git", true).spec)
        for (name in listOf("http://example.com/lib.git", "http://127.0.0.1.example.com/lib.git")) {
            assertInvalid(name, allowsInsecureLoopback = true)
        }
        assertInvalid("http://127.0.0.1:8080/lib.git", allowsInsecureLoopback = false)
        // Where the platforms differ, Android follows Swift: Linux refuses loopback
        // *names* (`git_location.rs:335`), Swift accepts `localhost` and `*.localhost`.
        assertTrue(parse("http://localhost/lib.git", true) is GitRepositoryLocation.Https)
        assertTrue(parse("http://repo.localhost/lib.git", true) is GitRepositoryLocation.Https)
        assertInvalid("http://localhost/lib.git", allowsInsecureLoopback = false)
        assertInvalid("http://repo.localhost/lib.git", allowsInsecureLoopback = false)
    }

    /** The `same_endpoint` vectors (Swift: `GitSyncSetup.sameEndpoint`). */
    @Test fun oneRepositoryReachedTwoWaysIsTheSameEndpoint() {
        fun same(a: String, b: String) = parse(a).sameEndpoint(parse(b))
        assertTrue(same("https://github.com/me/lib", "git@github.com:me/lib.git"))
        assertTrue(same("https://github.com/me/lib", "https://GitHub.com/me/lib.git/"))
        assertFalse(same("https://github.com/me/lib", "https://github.com:8443/me/lib"))
        assertFalse(same("git@host.example:lib", "other@host.example:lib"))
        assertFalse(same("ssh://git@host.example/lib", "ssh://git@host.example:2222/lib"))
        assertTrue(same("ssh://git@host.example:22/lib", "git@host.example:lib"))
        assertFalse(same("https://github.com/me/lib", "https://github.com/me/other"))
    }

    // MARK: Android additions

    @Test fun httpsNormalizationKeepsWhatWasWrittenAndRefusesWhatAClientWouldRewrite() {
        assertEquals("https://h:8443/a/b", GitRemote.normalizedUrl("HTTPS://H:8443/a/b//").toString())
        assertEquals("https://h/a%20b/c", GitRemote.normalizedUrl("https://h/a%20b/c").toString())
        // Characters a URL cannot carry are escaped as UTF-8; the identity is decoded again.
        val unicode = GitRemote.normalizedUrl("https://h/päth/lib")
        assertEquals("https://h/p%C3%A4th/lib", unicode.toString())
        assertEquals("h/päth/lib", GitRepositoryLocation.Https(unicode).canonicalIdentity)
        assertEquals("https://[::1]:8443/r", GitRemote.normalizedUrl("https://[::1]:8443/r").toString())
        // An empty port is no port, and leading zeros are dropped, as in Swift.
        assertEquals("https://h/a", GitRemote.normalizedUrl("https://h:/a").toString())
        assertEquals("https://h:8443/a", GitRemote.normalizedUrl("https://h:08443/a").toString())
        // Brackets stay where they were written, IPv6 literal or not.
        assertEquals("https://[h]/r", GitRemote.normalizedUrl("https://[H]/r").toString())
        for (refused in listOf(
            "https://h/a/../b", "https://h/./a", "https://h/a/%2e%2E/b", "https://h/100%", "https://h/a\\b",
            "https://h:0/a", "https://h:65536/a", "https://h:x/a", "https://@h/a", "https:///a", "https://h a/b",
            "https://h/a b", "https://[::1/a", "https://[]/a", "https://[::1]:/a", "https://[fe80::1%25en0]/a",
            "https://ho%73t/a", "https://h/a%FFb", "//h/a", "h/a",
        )) {
            assertFailsWith<GitRemoteConfigurationException>(refused) { GitRemote.normalizedUrl(refused) }
        }
    }

    /** Review finding 1: the host an international name converts to is the one Apple devices use. */
    @Test fun internationalHostsConvertAsOnAppleDevicesOrAreRefused() {
        fun identity(text: String) = parse(text).canonicalIdentity
        // UTS #46 without the transitional mappings: sharp s and final sigma stay.
        assertEquals("xn--strae-oqa.de/me/lib", identity("https://stra\u00dfe.de/me/lib"))
        assertEquals("https://xn--strae-oqa.de/me/lib", parse("https://stra\u00dfe.de/me/lib").spec)
        assertEquals("xn--nxasmm1c.example/a", identity("https://\u03b2\u03cc\u03bb\u03bf\u03c2.example/a"))
        assertEquals("xn--bcher-kva.example/me/lib", identity("https://B\u00dcCHER.example/me/lib"))
        // The name and its `xn--` spelling are one host and one identity.
        assertEquals(identity("https://b\u00fccher.example/r"), identity("https://XN--BCHER-KVA.example/r"))
        // Compatibility forms of ASCII are that ASCII, in HTTPS and in ssh:// alike.
        assertEquals("h.example/a", identity("https://\uff48.example/a"))
        assertEquals("ssh://git@h.example/r", parse("ssh://git@\uff28.Example/r").spec)
        // An international name has no SSH form in Swift, in either spelling; scp-like text is not a URL.
        assertInvalid("ssh://git@b\u00fccher.example/r")
        assertInvalid("ssh://git@xn--bcher-kva.example/r")
        assertEquals("xn--bcher-kva.example/r", identity("git@xn--bcher-kva.example:r"))
        // Not valid as international names: bad Punycode, joiners, the bidi rule,
        // hyphens and empty labels (which a plain ASCII name may have).
        for (refused in listOf(
            "https://xn--a.example/a", "https://xn--ss-.example/a", "https://xn--.example/a", "https://a\u200db.example/a",
            "https://\u0663.example/a", "https://1\u05d0.example/a", "https://\u05d0.1a.example/a", "https://\u00e9.-a.example/a",
            "https://\u00e9..a/a", "https://\u00e9.ab--c.example/a", "https://a.\u0301b.example/a",
        )) {
            assertInvalid(refused)
        }
        // A character that merely lowercases to ASCII (the Kelvin sign) is not ASCII
        // where Foundation does no IDNA mapping, and not guessed at next to an escape.
        assertInvalid("https://[\u212ah]/lib")
        assertInvalid("ssh://\u212a%41/r")
        assertEquals("ssh://k/r", parse("ssh://\u212a/r").spec)
        assertEquals("-a.ab--c..example/a", identity("https://-a.ab--c..example/a"))
        assertEquals("xn--4db.a1.example/a", identity("https://\u05d0.a1.example/a"))
    }

    /** Review finding 6: an IPv6 literal needs its brackets. */
    @Test fun anUnbracketedIpv6LiteralIsRefused() {
        for (refused in listOf("ssh://git@2001:db8::5/srv/r", "ssh://::1/r", "ssh://git@host:22:22/r", "https://::1/a", "https://a:b:c/a")) {
            assertInvalid(refused)
        }
        assertEquals("ssh://git@[2001:db8::5]/srv/r", parse("ssh://git@[2001:db8::5]/srv/r").spec)
        assertEquals("ssh://git@h/abs", parse("ssh://git@h:/abs").spec)
        assertEquals("ssh://git@h:22/r", parse("ssh://git@h:022/r").spec)
    }

    /** Swift looks for `://`, `:`, `@` and `/` as whole characters; what it would read differently is refused. */
    @Test fun aDelimiterInsideACombiningSequenceIsRefused() {
        for (refused in listOf(
            "https://\u0301a.example/a", "git@h:\u0301r", "git@h:r/\u0301x", "git@h\u0600:x", "git@h:x\u0600/", "git@h:x\u0600.git",
            "https://h/\u0e33", "https://h/%CC%81a", "ssh://h/%CC%81a", "https://h/a/\ud83c\udffb",
        )) {
            assertInvalid(refused)
        }
        // A mark after a letter is an ordinary decomposed character.
        assertEquals("h/e\u0301/lib", parse("git@h:e\u0301/lib.git").canonicalIdentity)
        assertEquals("h/e\u0301/lib", parse("https://h/e\u0301/lib.git").canonicalIdentity)
    }

    /** Foundation's own quirks, reproduced because they decide the identity. */
    @Test fun pathsAreEscapedAndUnescapedAsFoundationDoes() {
        // A path that needs escaping is escaped whole, `%` included.
        assertEquals("https://h/%2541/%5Bx%5D", parse("https://h/%41/[x]").spec)
        assertEquals("h/%41/[x]", parse("https://h/%41/[x]").canonicalIdentity)
        assertEquals("h/A", parse("https://h/%41").canonicalIdentity)
        // `URL.path` drops trailing slashes, escaped ones too, before `.git` is looked for.
        assertEquals("h/a", parse("https://h/a.git%2F%2F").canonicalIdentity)
        assertEquals("h/a.git", parse("https://h/a.git/%2F.git").canonicalIdentity)
        // In ssh:// the escaped `%` then makes the path one Swift refuses.
        assertInvalid("ssh://h/%41/\u00e4")
        assertEquals("ssh://h/A", parse("ssh://h/%41").spec)
    }

    @Test fun credentialRulesMatchSwift() {
        assertTrue(GitRemote.isValidUsername("x-access-token"))
        assertTrue(GitRemote.isValidUsername("u".repeat(256)))
        assertFalse(GitRemote.isValidUsername("u".repeat(257)))
        assertFalse(GitRemote.isValidUsername(""))
        assertFalse(GitRemote.isValidUsername("a\u007fb"))
        assertTrue(GitRemote.isValidToken("t".repeat(4_096)))
        assertFalse(GitRemote.isValidToken("t".repeat(4_097)))
        assertFalse(GitRemote.isValidToken(""))
        assertFalse(GitRemote.isValidToken("tab\tinside"))
        // Limits count UTF-8 bytes, not characters.
        assertTrue(GitRemote.isValidUsername("é".repeat(128)))
        assertFalse(GitRemote.isValidUsername("é".repeat(129)))
        assertEquals(
            GitRemote.Failure.INVALID_BRANCH,
            assertFailsWith<GitRemoteConfigurationException> { GitRemote.https("https://h/r", "a..b", "u", "p") }.failure,
        )
        assertTrue(GitRemote.isValidBranch("b".repeat(200)))
        assertFalse(GitRemote.isValidBranch("b".repeat(201)))
    }

    @Test fun sshValueLimitsMatchSwift() {
        fun location(path: String, port: Int? = null, host: String = "h", user: String? = "git") =
            GitSshLocation(user, host, port, path, scpStyle = true)
        location("p".repeat(1_024))
        assertFailsWith<GitRemoteConfigurationException> { location("p".repeat(1_025)) }
        assertFailsWith<GitRemoteConfigurationException> { location("é".repeat(513)) }
        assertFailsWith<GitRemoteConfigurationException> { location("r", port = 0) }
        assertFailsWith<GitRemoteConfigurationException> { location("r", port = 65_536) }
        location("r", port = 65_535)
        assertFailsWith<GitRemoteConfigurationException> { location("r", user = "") }
        assertFailsWith<GitRemoteConfigurationException> { location("r", user = "a b") }
        assertFailsWith<GitRemoteConfigurationException> { location("r", host = "h/x") }
        assertFailsWith<GitRemoteConfigurationException> { location("r", host = "hôst") }
        for (forbidden in "'\\\"`$;&|<>(){}*?[]!#%") {
            assertFailsWith<GitRemoteConfigurationException>(forbidden.toString()) { location("a${forbidden}b") }
        }
        assertEquals("ssh://h:2222/r", GitSshLocation(null, "h", 2222, "/r", scpStyle = false).spec)
    }
}
