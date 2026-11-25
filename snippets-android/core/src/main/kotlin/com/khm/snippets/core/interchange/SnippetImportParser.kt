package com.khm.snippets.core.interchange

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.codec.SnippetLibraryCodec
import com.khm.snippets.core.json.FoundationJson
import com.khm.snippets.core.json.FoundationJsonException
import com.khm.snippets.core.json.FoundationJsonNode
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.placeholders.RaycastPlaceholders
import com.khm.snippets.core.search.SwiftStrings
import java.util.UUID

/**
 * A fully decoded import, ready to be checked against the library and applied
 * (`PreparedSnippetImport`). Parsing touches nothing, so a malformed document cannot leave
 * a half-applied import behind.
 *
 * A Raycast export may spell its keywords with a leading `!`. Both readings are prepared:
 * the user is asked which one to keep when [hasRaycastExclamationKeywords] is true.
 */
class PreparedSnippetImport internal constructor(
    /** With one leading `!` removed from each Raycast keyword. For a native import, the snippets as decoded. */
    val snippets: List<Snippet>,
    /** With Raycast keywords as written. */
    val snippetsPreservingExclamationPrefix: List<Snippet>,
    val hasRaycastExclamationKeywords: Boolean,
) {
    fun snippets(preservingExclamationPrefix: Boolean): List<Snippet> =
        if (preservingExclamationPrefix) snippetsPreservingExclamationPrefix else snippets
}

/**
 * Decodes an import document (`SnippetImportParser.swift`).
 *
 * Three dialects are tried on the same bytes, in this order, and one element that does not
 * fit fails its whole dialect:
 *
 * 1. a JSON array of native snippets, as `snippets.json` holds them;
 * 2. an object whose `snippets` member is that array, as the app exports;
 * 3. a non-empty array of Raycast snippets: `name` and `text`, and optionally `keyword`.
 *
 * `[]` is a native import of nothing; the store refuses it later as empty. A native
 * snippet keeps its id, dates and flags. A Raycast snippet becomes a new, enabled,
 * unpinned snippet created now, with legacy `{date "…"}` placeholders rewritten by
 * [RaycastPlaceholders.converted].
 *
 * Checking the import against the library (duplicate ids and keywords, secure snippets)
 * and merging it are the store's work, not this parser's.
 */
object SnippetImportParser {

    /** `IncomingDocumentLoader.maximumJSONBytes`: the iOS app refuses a larger JSON import before parsing it. */
    const val MAXIMUM_JSON_BYTES: Int = 16 * 1024 * 1024

    /**
     * `IncomingDocumentLoader.maximumEncryptedBackupBytes`: the most the iOS app reads of
     * any picked file, before it knows whether the file is JSON or an encrypted backup.
     */
    const val MAXIMUM_FILE_BYTES: Int = 32 * 1024 * 1024

    /** `Failure.invalidFormat`: the bytes are none of the three dialects. */
    class InvalidFormat : Exception("the document is not a snippet export")

    /** The document is larger than [maximumBytes] and was not parsed. */
    class TooLarge(val maximumBytes: Int) : Exception("the document is larger than $maximumBytes bytes")

    /**
     * `SnippetImportParser.parse`. No size limit, like the Swift parser; see [parseBounded].
     *
     * @param now seconds since 2001 for a native snippet without `createdAt` and for every Raycast snippet.
     * @param newId the id of a Raycast snippet. The two readings of one item get different ids, as in Swift.
     */
    @Throws(InvalidFormat::class)
    fun parse(
        data: ByteArray,
        now: () -> Double = AppleTime::now,
        newId: () -> UUID = UUID::randomUUID,
    ): PreparedSnippetImport {
        try {
            val native = SnippetLibraryCodec.decode(data, now)
            return PreparedSnippetImport(native, native, hasRaycastExclamationKeywords = false)
        } catch (_: SnippetLibraryCodec.Unreadable) {
            // Not native: try Raycast.
        }

        val items = raycastItems(data)
        if (items.isEmpty()) throw InvalidFormat()

        fun snippets(preserveExclamationPrefix: Boolean): List<Snippet> = items.map { item ->
            val time = now()
            Snippet(
                id = newId(),
                name = item.name,
                keyword = normalizedRaycastKeyword(item.keyword, preserveExclamationPrefix),
                content = RaycastPlaceholders.converted(item.text),
                createdAt = time,
                updatedAt = time,
            )
        }

        val preserving = snippets(preserveExclamationPrefix = true)
        val normalized = snippets(preserveExclamationPrefix = false)
        return PreparedSnippetImport(
            normalized, preserving,
            hasRaycastExclamationKeywords = preserving.any { SwiftStrings.hasPrefix(it.normalizedKeyword, "!") },
        )
    }

    /**
     * [parse] behind the size check the iOS document loader makes for a JSON import:
     * more than [maximumBytes] is refused without being parsed.
     */
    @Throws(InvalidFormat::class, TooLarge::class)
    fun parseBounded(
        data: ByteArray,
        maximumBytes: Int = MAXIMUM_JSON_BYTES,
        now: () -> Double = AppleTime::now,
        newId: () -> UUID = UUID::randomUUID,
    ): PreparedSnippetImport {
        if (data.size > maximumBytes) throw TooLarge(maximumBytes)
        return parse(data, now, newId)
    }

    private class RaycastItem(val name: String, val text: String, val keyword: String?)

    private fun raycastItems(data: ByteArray): List<RaycastItem> {
        try {
            val root = FoundationJson.parse(data) as? FoundationJsonNode.Array ?: throw InvalidFormat()
            return root.elements.map { element ->
                val members = (element as? FoundationJsonNode.Object ?: throw InvalidFormat()).members()
                RaycastItem(
                    name = (members["name"] as? FoundationJsonNode.Text ?: throw InvalidFormat()).value(),
                    text = (members["text"] as? FoundationJsonNode.Text ?: throw InvalidFormat()).value(),
                    keyword = when (val keyword = members["keyword"]) {
                        null, is FoundationJsonNode.Null -> null
                        is FoundationJsonNode.Text -> keyword.value()
                        else -> throw InvalidFormat()
                    },
                )
            }
        } catch (_: FoundationJsonException) {
            throw InvalidFormat()
        }
    }

    private fun normalizedRaycastKeyword(rawKeyword: String?, preserveExclamationPrefix: Boolean): String {
        val keyword = Snippet.sanitizedKeyword(rawKeyword ?: "")
        if (preserveExclamationPrefix || !SwiftStrings.hasPrefix(keyword, "!")) return keyword
        // `hasPrefix("!")` holds, so the first Character is the single unit `!`.
        return Snippet.sanitizedKeyword(keyword.substring(1))
    }
}
