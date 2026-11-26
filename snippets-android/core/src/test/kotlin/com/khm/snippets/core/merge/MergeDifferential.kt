package com.khm.snippets.core.merge

import com.khm.snippets.core.canonical.CanonicalJson
import com.khm.snippets.core.crypto.Bytes
import com.khm.snippets.core.crypto.Utf8
import com.khm.snippets.core.crypto.Uuids
import com.khm.snippets.core.model.Snippet
import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import com.khm.snippets.core.wire.SyncEnvelope
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.UUID

/**
 * The Kotlin side of the Swift differential (`tools/swift-interop/checks/merge-differential`).
 *
 * [kotlinOutput] computes, for every input the Swift tool understands, the answer in the
 * tool's own output shape; [compare] lines the two documents up. Texts travel as hex of
 * their UTF-8 and doubles as their IEEE bits, so no JSON reader can normalise anything.
 *
 * A difference is either a **disagreement** (a bug on one side) or one of the stated
 * **deviations**, each of which is a decision of this port:
 *
 * - `date-range`: a conflict copy needs a name for an `updatedAt` outside 1582-10-15 to
 *   9999-12-31 UTC. Kotlin refuses ([MergeFailure.UnrepresentableConflictDate]); Swift
 *   prints a Julian date, a five-digit year or an empty stamp.
 * - `tag-order`: tags whose fold Foundation returns unnormalized, added on one side,
 *   come out in another order, in `mergeTags` itself or in the survivor of a merge.
 *   Swift's `<` is not an order for such keys; Kotlin uses [FoundationText.order]. Same
 *   tags, same spellings, everything else byte for byte.
 */
internal object MergeDifferential {

    const val MALFORMED = "SyncMerge.EnvelopeFailure.malformedContentConflict"
    const val UNRESOLVED_DELETION = "SyncMerge.EnvelopeFailure.unresolvedContentConflictDeletion"

    // Encoding

    fun hex(bytes: ByteArray): String = Bytes.toHex(bytes)
    fun hexText(text: String): String = hex(Utf8.encode(text))
    fun unhex(text: String): ByteArray = Bytes.fromHex(text) ?: error("not hex: $text")
    fun textOf(hex: String): String = String(unhex(hex), Charsets.UTF_8)
    fun bits(value: Double): String = "%016x".format(value.toRawBits())
    fun double(bits: String): Double = java.lang.Double.longBitsToDouble(java.lang.Long.parseUnsignedLong(bits, 16))

    fun str(value: String): JsonPrimitive = JsonPrimitive(value)
    private fun arr(values: List<JsonElement>): JsonArray = JsonArray(values)
    private fun obj(vararg members: Pair<String, JsonElement>): JsonObject = JsonObject(linkedMapOf(*members))

    fun envelopeHex(envelope: SyncEnvelope?): JsonElement = envelope?.let { str(hex(it.canonicalBytes())) } ?: JsonNull

    fun errorName(failure: Throwable): String = when (failure) {
        is MergeFailure.MalformedContentConflict -> MALFORMED
        is MergeFailure.UnresolvedContentConflictDeletion -> UNRESOLVED_DELETION
        is MergeFailure.UnrepresentableConflictDate -> "kotlin:UnrepresentableConflictDate"
        is MergeFailure.MismatchedIdentity -> "kotlin:MismatchedIdentity"
        is CanonicalJson.Failure -> "CanonicalJSON.Failure"
        else -> "kotlin:" + failure.javaClass.name
    }

    fun snippetJson(snippet: Snippet): JsonObject = obj(
        "id" to str(Uuids.lowercase(snippet.id)),
        "name" to str(hexText(snippet.name)),
        "keyword" to str(hexText(snippet.keyword)),
        "content" to str(hexText(snippet.content)),
        "tags" to arr(snippet.tags.map { str(hexText(it)) }),
        "isEnabled" to JsonPrimitive(snippet.isEnabled),
        "isPinned" to JsonPrimitive(snippet.isPinned),
        "createdAt" to str(bits(snippet.createdAt)),
        "updatedAt" to str(bits(snippet.updatedAt)),
    )

    fun snippet(json: JsonElement): Snippet {
        val o = json.jsonObject
        fun s(key: String) = o.getValue(key).jsonPrimitive.content
        return Snippet(
            id = UUID.fromString(s("id")), name = textOf(s("name")), keyword = textOf(s("keyword")),
            content = textOf(s("content")), tags = o.getValue("tags").jsonArray.map { textOf(it.jsonPrimitive.content) },
            isEnabled = o.getValue("isEnabled").jsonPrimitive.boolean, isPinned = o.getValue("isPinned").jsonPrimitive.boolean,
            createdAt = double(s("createdAt")), updatedAt = double(s("updatedAt")),
        )
    }

    private fun envelopeOrNull(json: JsonElement?): SyncEnvelope? =
        if (json == null || json is JsonNull) null else SyncEnvelope.parse(unhex(json.jsonPrimitive.content))

    // Inputs

    /** Input documents for the Swift tool; also what the property tests draw from. */
    class InputBuilder {
        val merge = ArrayList<JsonElement>()
        val copy = ArrayList<JsonElement>()
        val tags = ArrayList<JsonElement>()
        val local = ArrayList<JsonElement>()
        val stamp = ArrayList<JsonElement>()
        val inspect = ArrayList<JsonElement>()
        val converge = ArrayList<JsonElement>()

        fun merge(base: SyncEnvelope?, local: SyncEnvelope?, remote: SyncEnvelope?) {
            merge.add(obj("base" to envelopeHex(base), "local" to envelopeHex(local), "remote" to envelopeHex(remote)))
        }

        fun tags(case: MergeGenerator.TagCase) {
            tags.add(
                obj(
                    "base" to (case.base?.let { list -> arr(list.map { str(hexText(it)) }) } ?: JsonNull),
                    "local" to arr(case.local.map { str(hexText(it)) }),
                    "remote" to arr(case.remote.map { str(hexText(it)) }),
                    "localWins" to JsonPrimitive(case.localWins),
                ),
            )
        }

        fun local(case: MergeGenerator.LocalCase) {
            local.add(
                obj(
                    "base" to arr(case.base.map(::snippetJson)),
                    "local" to arr(case.local.map(::snippetJson)),
                    "remote" to arr(case.remote.map(::snippetJson)),
                ),
            )
        }

        fun converge(ancestor: List<String>, a: List<String>, b: List<String>, first: String, rounds: Int = 8) {
            fun fields(tags: List<String>) = obj(
                "name" to str(hexText("Shared")), "content" to str(hexText("body")), "tags" to arr(tags.map { str(hexText(it)) }),
            )
            converge.add(
                obj("ancestor" to fields(ancestor), "a" to fields(a), "b" to fields(b), "first" to str(first), "rounds" to JsonPrimitive(rounds)),
            )
        }

        fun build(): JsonObject = obj(
            "merge" to arr(merge), "copy" to arr(copy), "tags" to arr(tags), "local" to arr(local),
            "stamp" to arr(stamp), "inspect" to arr(inspect), "converge" to arr(converge),
        )
    }

    // Kotlin's answers, in the tool's output shape

    fun mergeResult(entry: JsonElement): JsonElement {
        val o = entry.jsonObject
        val base: SyncEnvelope?
        val local: SyncEnvelope?
        val remote: SyncEnvelope?
        try {
            base = envelopeOrNull(o["base"])
            local = envelopeOrNull(o["local"])
            remote = envelopeOrNull(o["remote"])
        } catch (failure: Exception) {
            return obj("error" to str("input:" + failure.javaClass.simpleName))
        }
        return try {
            val outcome = EnvelopeMerge.merge(base, local, remote)
            obj("survivor" to envelopeHex(outcome.survivor), "copies" to arr(outcome.conflictCopies.map(::envelopeHex)))
        } catch (failure: Exception) {
            obj("error" to str(errorName(failure)))
        }
    }

    fun copyResult(entry: JsonElement): JsonElement = try {
        val source = SyncEnvelope.parse(unhex(entry.jsonPrimitive.content))
        try {
            obj("copy" to envelopeHex(ConflictCopies.makePlainContentConflictCopy(source)))
        } catch (failure: Exception) {
            obj("error" to str(errorName(failure)))
        }
    } catch (failure: Exception) {
        obj("error" to str("input:" + failure.javaClass.simpleName))
    }

    fun tagsResult(entry: JsonElement): JsonElement {
        val o = entry.jsonObject
        val base = o["base"]?.takeIf { it !is JsonNull }?.jsonArray?.map { textOf(it.jsonPrimitive.content) }
        val local = o.getValue("local").jsonArray.map { textOf(it.jsonPrimitive.content) }
        val remote = o.getValue("remote").jsonArray.map { textOf(it.jsonPrimitive.content) }
        val merged = FieldMerge.mergeTags(base, local, remote, o.getValue("localWins").jsonPrimitive.boolean)
        return arr(merged.map { str(hexText(it)) })
    }

    fun localResult(entry: JsonElement): JsonElement {
        val o = entry.jsonObject
        fun list(key: String) = o.getValue(key).jsonArray.map(::snippet)
        return try {
            val outcome = LocalMerge.mergeLocal(list("base"), list("local"), list("remote"))
            obj(
                "snippets" to arr(outcome.snippets.map(::snippetJson)),
                "copies" to arr(outcome.conflictCopies.map(::snippetJson)),
                "disabled" to arr(outcome.disabledByKeywordCollision.map { str(Uuids.lowercase(it)) }),
                "attention" to JsonPrimitive(outcome.needsUserAttention),
            )
        } catch (failure: MergeFailure) {
            obj("error" to str(errorName(failure)))
        }
    }

    fun stampResult(entry: JsonElement): JsonElement = try {
        str(hexText(ConflictCopies.conflictStamp(double(entry.jsonPrimitive.content))))
    } catch (failure: MergeFailure) {
        obj("error" to str(errorName(failure)))
    }

    fun inspectResult(entry: JsonElement): JsonElement {
        val envelope = try {
            SyncEnvelope.parse(unhex(entry.jsonPrimitive.content))
        } catch (failure: Exception) {
            return obj("error" to str("input:" + failure.javaClass.simpleName))
        }
        val validate = try {
            ConflictCopies.validateContentConflictExtensions(envelope)
            str("ok")
        } catch (failure: Exception) {
            str(errorName(failure))
        }
        val variants: JsonElement = try {
            arr(
                ConflictCopies.secureContentConflictVariants(envelope).map {
                    obj("key" to str(it.extensionKey), "copyID" to str(Uuids.lowercase(it.copyId)))
                },
            )
        } catch (failure: Exception) {
            str(errorName(failure))
        }
        val provenance = ConflictCopies.conflictCopyProvenance(envelope)
        return obj(
            "validate" to validate,
            "variants" to variants,
            "unresolved" to JsonPrimitive(ConflictCopies.hasUnresolvedContentConflict(envelope)),
            "unknownVersion" to JsonPrimitive(ConflictCopies.hasUnknownContentConflictVersion(envelope)),
            "provenance" to (
                provenance?.let { obj("sourceID" to str(Uuids.lowercase(it.sourceId)), "fingerprint" to str(it.fingerprint)) }
                    ?: JsonNull
                ),
            "validIdentity" to JsonPrimitive(ConflictCopies.hasValidConflictCopyIdentity(envelope)),
        )
    }

    // Comparison

    class Report {
        val counts = LinkedHashMap<String, Int>()
        val deviations = LinkedHashMap<String, Int>()
        val disagreements = ArrayList<String>()

        fun count(section: String) {
            counts[section] = (counts[section] ?: 0) + 1
        }

        fun deviation(kind: String) {
            deviations[kind] = (deviations[kind] ?: 0) + 1
        }

        override fun toString(): String = buildString {
            append("compared: ").append(counts).append('\n')
            append("deviations: ").append(deviations).append('\n')
            append("disagreements: ").append(disagreements.size).append('\n')
            for (line in disagreements.take(40)) append(line).append('\n')
        }
    }

    /** Lines [input] up with [swift], the tool's output for it. */
    fun compare(input: JsonObject, swift: JsonObject): Report {
        val report = Report()
        fun section(name: String, kotlin: (JsonElement) -> JsonElement, classify: (JsonElement, JsonElement, JsonElement) -> String?) {
            val entries = input[name]?.jsonArray ?: return
            val answers = swift[name]?.jsonArray ?: error("Swift output has no \"$name\"")
            check(entries.size == answers.size) { "\"$name\": ${entries.size} inputs, ${answers.size} answers" }
            for (index in entries.indices) {
                report.count(name)
                val mine = kotlin(entries[index])
                val theirs = answers[index]
                if (mine == theirs) continue
                val deviation = classify(entries[index], mine, theirs)
                if (deviation != null) {
                    report.deviation("$name:$deviation")
                } else {
                    report.disagreements.add("$name[$index]: input=${entries[index]} kotlin=$mine swift=$theirs")
                }
            }
        }
        fun dateRange(mine: JsonElement): Boolean =
            (mine as? JsonObject)?.get("error")?.jsonPrimitive?.content == "kotlin:UnrepresentableConflictDate"

        section("merge", ::mergeResult) { entry, mine, theirs ->
            when {
                dateRange(mine) -> "date-range"
                hasUnnormalizedTagKey(entry) && sameUpToSurvivorTagOrder(mine, theirs) -> "tag-order"
                else -> null
            }
        }
        section("copy", ::copyResult) { _, mine, _ -> if (dateRange(mine)) "date-range" else null }
        section("tags", ::tagsResult) { entry, mine, theirs -> if (isTagOrderDeviation(entry, mine, theirs)) "tag-order" else null }
        section("local", ::localResult) { entry, mine, theirs ->
            when {
                dateRange(mine) -> "date-range"
                hasUnnormalizedTagKey(entry) && sameUpToSnippetTagOrder(mine, theirs) -> "tag-order"
                else -> null
            }
        }
        section("stamp", ::stampResult) { entry, mine, theirs ->
            if (dateRange(mine) && isOutsideFourDigitGregorian(double(entry.jsonPrimitive.content), textOf(theirs.jsonPrimitive.content))) {
                "date-range"
            } else {
                null
            }
        }
        section("inspect", ::inspectResult) { _, _, _ -> null }
        return report
    }

    /** Whether some tag anywhere in [entry] folds to a key Foundation leaves unnormalized. */
    private fun hasUnnormalizedTagKey(entry: JsonElement): Boolean {
        val tags = ArrayList<String>()
        fun walk(element: JsonElement, key: String?) {
            when (element) {
                is JsonObject -> element.forEach { (k, v) -> walk(v, k) }
                is JsonArray -> element.forEach { walk(it, key) }
                is JsonPrimitive -> if (element.isString) {
                    val text = element.content
                    if (key == "tags") tags.add(textOf(text))
                    if (key in setOf("base", "local", "remote") && text.length % 2 == 0 && text.all { it in "0123456789abcdef" }) {
                        // A whole envelope: look inside its fields.
                        runCatching { SyncEnvelope.parse(unhex(text)) }.getOrNull()?.fields?.tags?.let(tags::addAll)
                    }
                }
            }
        }
        walk(entry, null)
        return tags.any { SnippetTagging.rawFilterKey(it) != SnippetTagging.filterKey(it) }
    }

    /** Both merges succeeded and their survivors differ in nothing but the order of `fields.tags` (and so `hash`). */
    private fun sameUpToSurvivorTagOrder(mine: JsonElement, theirs: JsonElement): Boolean {
        val a = mine as? JsonObject ?: return false
        val b = theirs as? JsonObject ?: return false
        if (a["copies"] != b["copies"]) return false
        val left = (a["survivor"] as? JsonPrimitive)?.content ?: return false
        val right = (b["survivor"] as? JsonPrimitive)?.content ?: return false
        fun normalized(hex: String): JsonObject? {
            val envelope = runCatching { SyncEnvelope.parse(unhex(hex)) }.getOrNull() ?: return null
            val fields = envelope.fields ?: return null
            val sorted = SyncEnvelope(
                envelope.id, envelope.hlc, envelope.origin, envelope.secure, envelope.deleted,
                fields.copy(tags = fields.tags.sorted()), envelope.x, envelope.schemaVersion,
            )
            return kotlinx.serialization.json.Json.parseToJsonElement(String(sorted.canonicalBytes(), Charsets.UTF_8)).jsonObject
        }
        val l = normalized(left) ?: return false
        return l == normalized(right) && SyncEnvelope.parse(unhex(left)).fields!!.tags != SyncEnvelope.parse(unhex(right)).fields!!.tags
    }

    private fun sameUpToSnippetTagOrder(mine: JsonElement, theirs: JsonElement): Boolean {
        val a = mine as? JsonObject ?: return false
        val b = theirs as? JsonObject ?: return false
        if (a["disabled"] != b["disabled"] || a["attention"] != b["attention"]) return false
        fun sortedTags(list: JsonElement?): List<JsonElement>? = list?.jsonArray?.map { snippet ->
            val o = snippet.jsonObject
            JsonObject(o + ("tags" to JsonArray(o.getValue("tags").jsonArray.sortedBy { it.jsonPrimitive.content })))
        }
        return sortedTags(a["snippets"]) == sortedTags(b["snippets"]) && sortedTags(a["copies"]) == sortedTags(b["copies"])
    }

    private fun isTagOrderDeviation(entry: JsonElement, mine: JsonElement, theirs: JsonElement): Boolean {
        val a = mine.jsonArray.map { it.jsonPrimitive.content }
        val b = theirs.jsonArray.map { it.jsonPrimitive.content }
        if (a.sorted() != b.sorted()) return false
        val o = entry.jsonObject
        val all = listOfNotNull(o["base"]?.takeIf { it !is JsonNull }?.jsonArray, o.getValue("local").jsonArray, o.getValue("remote").jsonArray)
            .flatten().map { textOf(it.jsonPrimitive.content) }
        return all.any { SnippetTagging.rawFilterKey(it) != SnippetTagging.filterKey(it) }
    }

    /** Whether Swift's [text] for [updatedAt] lies where this port refuses to name a copy. */
    private fun isOutsideFourDigitGregorian(updatedAt: Double, text: String): Boolean {
        val unixMillis = Math.floor((updatedAt + 978_307_200.0) * 1000.0 + 0.5)
        val outside = !(unixMillis >= -12_219_292_800_000.0 && unixMillis <= 253_402_300_799_999.0)
        return outside && (text.isEmpty() || text.length > 20 || text < "1582-10-15")
    }
}
