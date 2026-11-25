package com.khm.snippets.core.codec

import com.khm.snippets.core.canonical.JsonValue
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.io.FileRead
import com.khm.snippets.core.json.FoundationJson
import com.khm.snippets.core.json.FoundationJsonException
import com.khm.snippets.core.json.FoundationJsonNode
import com.khm.snippets.core.json.FoundationJsonWriter
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

/**
 * The one place `snippets.json` is encoded and decoded (`SnippetLibraryCodec.swift`).
 *
 * The format is frozen: a JSON array of objects with exactly the nine keys of [Snippet].
 * Clocks, revisions and tombstones live in `Sync/`, secure snippets in `Vault/`.
 *
 * Decoding accepts and refuses exactly what the Swift codec does, including what
 * Foundation's `JSONDecoder` tolerates (see [FoundationJsonNode]), because a library
 * exported on one platform is imported on another and a file one of them rejects is
 * quarantined, never treated as empty. Encoding writes the bytes Foundation would.
 */
object SnippetLibraryCodec {

    /** The bytes are not a snippet library. The Swift codec does not say why either. */
    class Unreadable : Exception("the snippet library could not be decoded as JSON")

    /** A timestamp that is not finite has no JSON spelling; Swift's encoder throws for it too. */
    class NotEncodable : IllegalArgumentException("a snippet timestamp is not a finite number")

    /** What [read] found at the library's path. */
    sealed class ReadResult {

        /** No file. A legitimately empty library: first launch. */
        object Missing : ReadResult()

        /** The decoded library, the bytes it came from and their [digest]. */
        class Loaded(val snippets: List<Snippet>, val data: ByteArray, val digest: String) : ReadResult()

        /** The file is there and is not a library. Never an empty library; the bytes are kept for quarantine. */
        class Undecodable(val data: ByteArray, val digest: String) : ReadResult()

        /** The file could not be read at all. Never an empty library. */
        class Unreadable(val cause: IOException) : ReadResult()
    }

    /**
     * `encode(_:)`: the bare array, as the app writes `snippets.json`.
     *
     * An unpaired surrogate in a text field is written as U+FFFD, since UTF-8 cannot
     * hold one (and neither can a Swift string). Such a snippet does not read back equal
     * to itself, so callers must repair text from the clipboard or an editor before they
     * store it, or every save will look like a change.
     */
    @Throws(NotEncodable::class)
    fun encode(snippets: List<Snippet>): ByteArray = write(arrayOf(snippets))

    /** `encodeCollection(_:)`: the `{"snippets": [...]}` dialect that export produces. */
    @Throws(NotEncodable::class)
    fun encodeCollection(snippets: List<Snippet>): ByteArray =
        write(JsonValue.Object(mapOf("snippets" to arrayOf(snippets))))

    /**
     * `decode(_:)`: the bare array, or else the `{"snippets": [...]}` dialect. Never the
     * Raycast dialect: that belongs to the import path.
     *
     * Unknown keys are ignored. `tags` (normalized on the way in), `isEnabled`,
     * `isPinned`, `createdAt` and `updatedAt` may be missing or `null` and default to no
     * tags, `true`, `false`, [now] and `createdAt`. One element that cannot be decoded
     * fails the whole library. Duplicate ids are not this codec's concern.
     *
     * @param now seconds since 2001 for a record without `createdAt`; read at most once per record.
     */
    @Throws(Unreadable::class)
    fun decode(data: ByteArray, now: () -> Double = AppleTime::now): List<Snippet> {
        try {
            return when (val root = FoundationJson.parse(data)) {
                is FoundationJsonNode.Array -> decodeArray(root, now)
                is FoundationJsonNode.Object -> {
                    val snippets = root.members()["snippets"] as? FoundationJsonNode.Array ?: throw Unreadable()
                    decodeArray(snippets, now)
                }
                else -> throw Unreadable()
            }
        } catch (_: FoundationJsonException) {
            throw Unreadable()
        }
    }

    /**
     * `digest(of:)`: lowercase hex SHA-256 of the exact bytes. This is the local
     * compare-and-swap token, taken over bytes on purpose: a writer that reformatted the
     * file has changed it, even if it decodes to the same snippets.
     */
    fun digest(data: ByteArray): String = Bytes.toHex(MessageDigest.getInstance("SHA-256").digest(data))

    /**
     * `read(from:)`: the library and its digest in one pass, so the digest always
     * describes the bytes the snippets came from.
     */
    fun read(file: File, now: () -> Double = AppleTime::now): ReadResult =
        when (val contents = FileRead.read(file)) {
            is FileRead.Missing -> ReadResult.Missing
            is FileRead.Unreadable -> ReadResult.Unreadable(contents.cause)
            is FileRead.Bytes -> try {
                ReadResult.Loaded(decode(contents.data, now), contents.data, digest(contents.data))
            } catch (_: Unreadable) {
                ReadResult.Undecodable(contents.data, digest(contents.data))
            }
        }

    private fun write(value: JsonValue): ByteArray = try {
        FoundationJsonWriter.prettyPrinted(value)
    } catch (_: FoundationJsonWriter.NonFiniteNumber) {
        throw NotEncodable()
    }

    private fun arrayOf(snippets: List<Snippet>): JsonValue = JsonValue.Array(snippets.map(::objectOf))

    // The writer sorts the keys; these are the nine, and there will not be a tenth.
    private fun objectOf(snippet: Snippet): JsonValue = JsonValue.Object(
        mapOf(
            "id" to JsonValue.Text(Uuids.uppercase(snippet.id)),
            "name" to JsonValue.Text(snippet.name),
            "keyword" to JsonValue.Text(snippet.keyword),
            "content" to JsonValue.Text(snippet.content),
            "tags" to JsonValue.Array(snippet.tags.map { JsonValue.Text(it) }),
            "isEnabled" to JsonValue.Bool(snippet.isEnabled),
            "isPinned" to JsonValue.Bool(snippet.isPinned),
            "createdAt" to JsonValue.Real(snippet.createdAt),
            "updatedAt" to JsonValue.Real(snippet.updatedAt),
        ),
    )

    private fun decodeArray(array: FoundationJsonNode.Array, now: () -> Double): List<Snippet> =
        array.elements.map { decodeSnippet(it, now) }

    private fun decodeSnippet(node: FoundationJsonNode, now: () -> Double): Snippet {
        val members = (node as? FoundationJsonNode.Object ?: throw Unreadable()).members()
        val id = uuid(members["id"])
        val name = requiredString(members["name"])
        val keyword = requiredString(members["keyword"])
        val content = requiredString(members["content"])
        val tags = SnippetTagging.normalizedTags(optionalStrings(members["tags"]))
        val isEnabled = optionalBoolean(members["isEnabled"]) ?: true
        val isPinned = optionalBoolean(members["isPinned"]) ?: false
        val createdAt = optionalDouble(members["createdAt"]) ?: now()
        val updatedAt = optionalDouble(members["updatedAt"]) ?: createdAt
        return Snippet(id, name, keyword, content, tags, isEnabled, isPinned, createdAt, updatedAt)
    }

    private fun requiredString(node: FoundationJsonNode?): String =
        (node as? FoundationJsonNode.Text ?: throw Unreadable()).value()

    /**
     * `UUID(uuidString:)`: 8-4-4-4-12 hex digits of either case. Foundation hands the text
     * to C `uuid_parse`, which stops reading at a NUL character, so anything after one is
     * ignored here as well.
     */
    private fun uuid(node: FoundationJsonNode?): UUID {
        val text = requiredString(node)
        val terminator = text.indexOf('\u0000')
        return Uuids.parse(if (terminator < 0) text else text.substring(0, terminator)) ?: throw Unreadable()
    }

    private fun optionalBoolean(node: FoundationJsonNode?): Boolean? = when (node) {
        null, is FoundationJsonNode.Null -> null
        is FoundationJsonNode.True -> true
        is FoundationJsonNode.False -> false
        else -> throw Unreadable()
    }

    private fun optionalDouble(node: FoundationJsonNode?): Double? = when (node) {
        null, is FoundationJsonNode.Null -> null
        is FoundationJsonNode.Number -> node.doubleValue()
        else -> throw Unreadable()
    }

    private fun optionalStrings(node: FoundationJsonNode?): List<String> = when (node) {
        null, is FoundationJsonNode.Null -> emptyList()
        is FoundationJsonNode.Array -> node.elements.map(::requiredString)
        else -> throw Unreadable()
    }
}
