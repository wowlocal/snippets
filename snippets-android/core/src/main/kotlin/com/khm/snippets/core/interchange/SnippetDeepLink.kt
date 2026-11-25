package com.khm.snippets.core.interchange

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.crypto.Base64Url
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.json.FoundationJson
import com.khm.snippets.core.json.FoundationJsonException
import com.khm.snippets.core.json.FoundationJsonNode
import com.khm.snippets.core.json.FoundationJsonWriter
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.search.SwiftStrings
import com.khm.snippets.core.text.FoundationText
import java.io.ByteArrayOutputStream
import java.net.IDN
import java.util.Locale
import java.util.UUID

/**
 * `snippets://` links (`SnippetDeepLink.swift`).
 *
 * - `snippets://share?data=<payload>` is written by the app and carries one snippet:
 *   name, keyword, content and tags. No id, dates or flags travel.
 * - `snippets://new?name=…&keyword=…&content=…&tags=a,b` can be written by hand or by an
 *   automation tool. Every item is optional, but name, keyword and content must not all
 *   be empty.
 *
 * Links are taken as text and parsed here: platform URL helpers disagree with Foundation
 * (Android's `Uri.getQueryParameter` turns `+` into a space, for one). What is accepted
 * follows Foundation's `URL(string:)` and `URLComponents`, as measured from Swift.
 *
 * A link has no size limit, here or in Swift.
 */
object SnippetDeepLink {

    const val SCHEME: String = "snippets"

    private const val SHARE_HOST = "share"
    private const val CREATION_HOST = "new"
    private const val PAYLOAD_QUERY_ITEM = "data"
    private const val CURRENT_VERSION = 1L

    /**
     * A received link never becomes an active trigger by itself: the store saves the
     * snippet disabled, and the user enables it after reading it. The parser reports the
     * snippet as the link describes it, enabled; this is the value the importer applies.
     */
    const val RECEIVED_SNIPPET_IS_ENABLED: Boolean = false

    /** `SnippetDeepLinkError`. The app phrases these. */
    enum class Error {
        /** Not a `snippets://share` or `snippets://new` link. */
        UNSUPPORTED_URL,

        /** A share link without `data`, or a creation link that carries nothing. */
        MISSING_PAYLOAD,

        /** The payload is not base64 of the expected JSON. */
        INVALID_PAYLOAD,

        /** The payload's `version` is not one this app reads. */
        UNSUPPORTED_VERSION,

        /** Kept for parity with Swift; encoding cannot fail here. */
        CANNOT_ENCODE_PAYLOAD,

        /** A secure snippet was asked to be shared. A share link carries the text in plain sight. */
        SECURE_SNIPPET_NOT_SHAREABLE,
    }

    /** Carries the [error] only: never any part of the link or of a snippet. */
    class Failure(val error: Error) : Exception(error.name)

    enum class Kind { SHARE, CREATION }

    /** A parsed link. */
    class Received internal constructor(val kind: Kind, val snippet: Snippet) {
        /** [snippet] as it is to be saved: see [RECEIVED_SNIPPET_IS_ENABLED]. */
        val staged: Snippet get() = snippet.copy(isEnabled = RECEIVED_SNIPPET_IS_ENABLED)
    }

    /** `canHandle`: scheme `snippets` and host `share` or `new`, in any letter case. Path and fragment do not matter. */
    fun canHandle(url: String): Boolean = kindOf(url) != null

    /** `isCreationLink`: a link that asks for a new snippet rather than carrying a whole one. */
    fun isCreationLink(url: String): Boolean = kindOf(url) == Kind.CREATION

    /**
     * `url(for:isSecure:)`: the share link of an ordinary snippet.
     *
     * [isSecure] has no default on purpose: the caller has to say whether the snippet
     * lives in the vault, and a secure one is refused before anything is encoded.
     */
    @Throws(Failure::class)
    fun url(snippet: Snippet, isSecure: Boolean): String {
        if (isSecure) throw Failure(Error.SECURE_SNIPPET_NOT_SHAREABLE)
        // `JSONEncoder` with `.sortedKeys`: one line, keys in order, `tags` left out when empty.
        val json = ByteArrayOutputStream()
        json.writeAscii("{\"content\":")
        json.writeJsonString(snippet.content)
        json.writeAscii(",\"keyword\":")
        json.writeJsonString(snippet.normalizedKeyword)
        json.writeAscii(",\"name\":")
        json.writeJsonString(snippet.name)
        if (snippet.tags.isNotEmpty()) {
            json.writeAscii(",\"tags\":[")
            snippet.tags.forEachIndexed { index, tag ->
                if (index > 0) json.write(','.code)
                json.writeJsonString(tag)
            }
            json.write(']'.code)
        }
        json.writeAscii(",\"version\":$CURRENT_VERSION}")
        return "$SCHEME://$SHARE_HOST?$PAYLOAD_QUERY_ITEM=" + Base64Url.encode(json.toByteArray())
    }

    /**
     * `snippet(from:)`: the snippet a link describes, as a new record: new id, enabled,
     * not pinned, created now. The keyword is sanitized and the tags are normalized.
     */
    @Throws(Failure::class)
    fun snippet(url: String, now: () -> Double = AppleTime::now, newId: () -> UUID = UUID::randomUUID): Snippet =
        receive(url, now, newId).snippet

    /** [snippet] together with which kind of link it was. */
    @Throws(Failure::class)
    fun receive(url: String, now: () -> Double = AppleTime::now, newId: () -> UUID = UUID::randomUUID): Received {
        val parsed = parse(url) ?: throw Failure(Error.UNSUPPORTED_URL)
        val kind = kindOf(parsed) ?: throw Failure(Error.UNSUPPORTED_URL)
        val items = queryItems(parsed.query)
        val fields = when (kind) {
            Kind.CREATION -> creationFields(items)
            Kind.SHARE -> sharedFields(items)
        }
        val time = now()
        return Received(
            kind,
            Snippet(
                id = newId(),
                name = fields.name,
                keyword = Snippet.sanitizedKeyword(fields.keyword),
                content = fields.content,
                tags = SnippetTagging.normalizedTags(fields.tags),
                createdAt = time,
                updatedAt = time,
            ),
        )
    }

    private class Fields(val name: String, val keyword: String, val content: String, val tags: List<String>)

    private fun sharedFields(items: List<QueryItem>): Fields {
        val item = items.firstOrNull { FoundationText.canonicalEquals(it.name, PAYLOAD_QUERY_ITEM) }
        val encoded = item?.value ?: throw Failure(Error.MISSING_PAYLOAD)
        val data = decodeBase64(encoded) ?: throw Failure(Error.INVALID_PAYLOAD)
        val fields: Fields
        val version: Long
        try {
            val members = (FoundationJson.parse(data) as? FoundationJsonNode.Object ?: throw Failure(Error.INVALID_PAYLOAD)).members()
            version = integer(members["version"]) ?: throw Failure(Error.INVALID_PAYLOAD)
            fields = Fields(
                name = string(members["name"]),
                keyword = string(members["keyword"]),
                content = string(members["content"]),
                // Optional so that links from older versions still decode.
                tags = when (val tags = members["tags"]) {
                    null, is FoundationJsonNode.Null -> emptyList()
                    is FoundationJsonNode.Array -> tags.elements.map(::string)
                    else -> throw Failure(Error.INVALID_PAYLOAD)
                },
            )
        } catch (_: FoundationJsonException) {
            throw Failure(Error.INVALID_PAYLOAD)
        }
        if (version != CURRENT_VERSION) throw Failure(Error.UNSUPPORTED_VERSION)
        return fields
    }

    /**
     * Plain query items, no envelope and no version: this link has to survive being typed
     * by hand. Names match in any letter case and the first item of a name counts.
     */
    private fun creationFields(items: List<QueryItem>): Fields {
        fun value(name: String): String =
            items.firstOrNull { FoundationText.canonicalEquals(it.name.lowercase(Locale.ROOT), name) }?.value ?: ""

        val name = value("name")
        val keyword = value("keyword")
        val content = value("content")
        if (name.isEmpty() && keyword.isEmpty() && content.isEmpty()) throw Failure(Error.MISSING_PAYLOAD)
        return Fields(name, keyword, content, splitTags(value("tags")))
    }

    // `components(separatedBy: ",")`: a comma that carries a combining mark is not a separator.
    private fun splitTags(text: String): List<String> {
        val pieces = ArrayList<String>()
        var pieceStart = 0
        for (index in text.indices) {
            if (text[index] == ',' && SwiftStrings.isCharacterBoundary(text, index + 1)) {
                pieces.add(text.substring(pieceStart, index))
                pieceStart = index + 1
            }
        }
        pieces.add(text.substring(pieceStart))
        return pieces
    }

    private fun string(node: FoundationJsonNode?): String =
        (node as? FoundationJsonNode.Text ?: throw Failure(Error.INVALID_PAYLOAD)).value()

    /**
     * A JSON number as Swift decodes an `Int`: any spelling of a whole number that fits
     * (`1`, `1.0`, `1e0`). One deviation: the reader hands over a `Double`, so the 512
     * integers around 2^63 cannot be told apart and all count as too large, where Swift
     * accepts 9223372036854775807 itself (and then refuses its version).
     */
    private fun integer(node: FoundationJsonNode?): Long? {
        val value = (node as? FoundationJsonNode.Number ?: return null).doubleValue()
        if (value != Math.rint(value) || value < -9.223372036854775808E18 || value >= 9.223372036854775808E18) return null
        return value.toLong()
    }

    /**
     * The payload decoder of the Swift sources: both base64 alphabets, with or without
     * `=` padding, and nothing else. Unused bits in the last symbol are ignored, as
     * Foundation ignores them.
     */
    private fun decodeBase64(text: String): ByteArray? {
        var end = text.length
        while (end > 0 && text[end - 1] == '=') end -= 1
        val symbols = StringBuilder(end)
        for (index in 0 until end) {
            symbols.append(
                when (val unit = text[index]) {
                    '+' -> '-'
                    '/' -> '_'
                    else -> unit
                },
            )
        }
        return Base64Url.decode(symbols)
    }

    // URL parsing

    private class ParsedUrl(val scheme: String, val host: String?, val query: String?)

    private class QueryItem(val name: String, val value: String?)

    private fun kindOf(url: String): Kind? = parse(url)?.let(::kindOf)

    private fun kindOf(url: ParsedUrl): Kind? {
        if (!url.scheme.equals(SCHEME, ignoreCase = true)) return null
        return when (url.host) {
            SHARE_HOST -> Kind.SHARE
            CREATION_HOST -> Kind.CREATION
            else -> null
        }
    }

    /**
     * `scheme://[userinfo@]host[:port][/path][?query][#fragment]`. `null` for text that
     * has no scheme or whose authority Foundation refuses (a port that is not digits,
     * unbalanced brackets). The host comes back lowercased, or `null` when there is none.
     */
    private fun parse(text: String): ParsedUrl? {
        val colon = text.indexOf(':')
        if (colon <= 0) return null
        val scheme = text.substring(0, colon)
        if (!isAsciiLetter(scheme[0])) return null
        for (unit in scheme) if (!isAsciiLetter(unit) && unit !in '0'..'9' && unit != '+' && unit != '-' && unit != '.') return null

        if (!text.startsWith("//", colon + 1)) return ParsedUrl(scheme, host = null, query = null)
        val authorityStart = colon + 3
        var authorityEnd = authorityStart
        while (authorityEnd < text.length && text[authorityEnd] != '/' && text[authorityEnd] != '?' && text[authorityEnd] != '#') {
            authorityEnd += 1
        }
        val host = host(text.substring(authorityStart, authorityEnd)) ?: return null

        val fragmentStart = text.indexOf('#', authorityEnd)
        val beforeFragment = if (fragmentStart < 0) text.length else fragmentStart
        val queryMark = text.indexOf('?', authorityEnd)
        val query = if (queryMark < 0 || queryMark >= beforeFragment) null else text.substring(queryMark + 1, beforeFragment)
        return ParsedUrl(scheme, host.ifEmpty { null }, query)
    }

    /** The host of an authority, lowercased; empty when there is none; `null` when the authority is malformed. */
    private fun host(authority: String): String? {
        val hostAndPort = authority.substring(authority.lastIndexOf('@') + 1)
        val rawHost: String
        val port: String
        if (hostAndPort.startsWith("[")) {
            val close = hostAndPort.indexOf(']')
            if (close < 0) return null
            rawHost = hostAndPort.substring(1, close)
            val rest = hostAndPort.substring(close + 1)
            if (rest.isNotEmpty() && rest[0] != ':') return null
            port = if (rest.isEmpty()) "" else rest.substring(1)
        } else {
            val portMark = hostAndPort.indexOf(':')
            rawHost = if (portMark < 0) hostAndPort else hostAndPort.substring(0, portMark)
            port = if (portMark < 0) "" else hostAndPort.substring(portMark + 1)
        }
        if (rawHost.indexOf('[') >= 0 || rawHost.indexOf(']') >= 0) return null
        for (unit in port) if (unit !in '0'..'9') return null

        var host = percentDecoded(rawHost) ?: return null
        if (!isAscii(host)) {
            // Foundation maps an international host name to its ASCII form before comparing.
            host = try {
                IDN.toASCII(host, IDN.ALLOW_UNASSIGNED)
            } catch (_: RuntimeException) {
                return null
            }
        }
        return host.lowercase(Locale.ROOT)
    }

    /**
     * `URLComponents.queryItems`: items between `&`, each split at its first `=`. An item
     * without `=` has no value. A value that does not decode to UTF-8 is no value either.
     *
     * Percent-escapes are decoded only in a query that is valid as written. `URL(string:)`
     * repairs any other query (one with a raw space, a non-ASCII character, a quote, or a
     * `%` that does not start two hex digits) by percent-encoding all of it, `%` included,
     * so there every escape comes back as the three characters that were typed:
     * `name=a b%20c` is the name `a b%20c`, and `100%` is `100%`.
     */
    private fun queryItems(query: String?): List<QueryItem> {
        if (query == null) return emptyList()
        val decode = isValidQuery(query)
        fun text(start: Int, end: Int): String? {
            val piece = query.substring(start, end)
            // A Swift string cannot hold half a surrogate pair; U+FFFD stands in for one.
            return if (decode) percentDecoded(piece) else Utf8.decodeStrict(Utf8.encode(piece))
        }
        val items = ArrayList<QueryItem>()
        var start = 0
        while (start <= query.length) {
            var end = query.indexOf('&', start)
            if (end < 0) end = query.length
            val equals = query.indexOf('=', start)
            if (equals < 0 || equals >= end) {
                items.add(QueryItem(text(start, end) ?: "", value = null))
            } else {
                items.add(QueryItem(text(start, equals) ?: "", text(equals + 1, end)))
            }
            start = end + 1
        }
        return items
    }

    /** RFC 3986 `query`: unreserved and sub-delimiter characters, `:`, `@`, `/`, `?`, and well-formed escapes. */
    private fun isValidQuery(query: String): Boolean {
        var index = 0
        while (index < query.length) {
            val unit = query[index]
            if (unit == '%') {
                if (index + 2 >= query.length || hexValue(query[index + 1]) < 0 || hexValue(query[index + 2]) < 0) return false
                index += 3
                continue
            }
            if (!isAsciiLetter(unit) && unit !in '0'..'9' && "-._~!$&'()*+,;=:@/?".indexOf(unit) < 0) return false
            index += 1
        }
        return true
    }

    /**
     * `removingPercentEncoding`: `%XX` is a byte, other text stands for its UTF-8 bytes,
     * and the bytes together must be UTF-8. `null` otherwise, and for a `%` that does not
     * start two hex digits.
     */
    private fun percentDecoded(text: String): String? {
        if (text.indexOf('%') < 0) return text
        val bytes = ByteArrayOutputStream(text.length)
        var literalStart = 0
        var index = 0
        while (index < text.length) {
            if (text[index] != '%') {
                index += 1
                continue
            }
            val high = if (index + 1 < text.length) hexValue(text[index + 1]) else -1
            val low = if (index + 2 < text.length) hexValue(text[index + 2]) else -1
            if (high < 0 || low < 0) return null
            if (literalStart < index) bytes.write(Utf8.encode(text.substring(literalStart, index)))
            bytes.write((high shl 4) or low)
            index += 3
            literalStart = index
        }
        if (literalStart < text.length) bytes.write(Utf8.encode(text.substring(literalStart)))
        return Utf8.decodeStrict(bytes.toByteArray())
    }

    private fun hexValue(unit: Char): Int = when (unit) {
        in '0'..'9' -> unit - '0'
        in 'a'..'f' -> unit - 'a' + 10
        in 'A'..'F' -> unit - 'A' + 10
        else -> -1
    }

    private fun isAsciiLetter(unit: Char): Boolean = unit in 'a'..'z' || unit in 'A'..'Z'

    private fun isAscii(text: String): Boolean = text.all { it.code < 0x80 }

    private fun ByteArrayOutputStream.writeAscii(text: String) {
        for (unit in text) write(unit.code)
    }

    // The writer's output for a lone string is that string with Foundation's escapes.
    private fun ByteArrayOutputStream.writeJsonString(text: String) {
        write(FoundationJsonWriter.prettyPrinted(JsonValue.Text(text)))
    }
}

/**
 * What the app shows before a received link changes the library, and what it checks when
 * the user agrees (`IncomingSnippetLinkCoordinator.swift`). Parsing a link changes nothing.
 */
object SnippetLinkReview {

    /** The review shows at most this many `Character`s of the content. */
    const val PREVIEW_CHARACTERS: Int = 280

    /**
     * The ordinary snippet a shared snippet would replace: the one with its id, else the
     * one whose keyword folds to the same non-empty key. A creation link never replaces
     * anything.
     *
     * Call it for the review and again right before importing: the import may only go
     * ahead when both calls name the same snippet, unchanged.
     */
    fun replacementTarget(incoming: Snippet, ordinary: List<Snippet>): Snippet? {
        ordinary.firstOrNull { it.id == incoming.id }?.let { return it }
        val keyword = incoming.normalizedKeyword
        if (keyword.isEmpty()) return null
        val key = SnippetTagging.filterKey(keyword)
        return ordinary.firstOrNull { it.normalizedKeyword.isNotEmpty() && SnippetTagging.filterKey(it.normalizedKeyword) == key }
    }

    /**
     * The content as the review shows it: trimmed, and cut to [PREVIEW_CHARACTERS] plus
     * `…` when longer. Empty when there is nothing to show.
     */
    fun contentPreview(content: String): String {
        val trimmed = FoundationText.trimWhitespaceAndNewlines(content)
        val prefix = FoundationText.characterPrefix(trimmed, PREVIEW_CHARACTERS)
        return if (prefix.length == trimmed.length) trimmed else "$prefix…"
    }
}
