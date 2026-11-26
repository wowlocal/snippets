package com.khm.snippets.core.merge

import com.khm.snippets.core.wire.SyncEnvelope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The merge against the shipping Swift merge, run by the Swift tool in
 * `tools/swift-interop/checks/merge-differential` (see `run.sh` there).
 *
 * - Always: `fixtures/merge/differential-sample.json`, a few hundred generated inputs
 *   with the answers Swift gave for them, must still be what Kotlin computes.
 * - With `MERGE_DIFFERENTIAL_DIR` set: the live run. Without `output.json` in that
 *   directory the test writes `input.json` (thousands of generated inputs; seed and size
 *   from `MERGE_DIFFERENTIAL_SEED` and `MERGE_DIFFERENTIAL_COUNT`); with it, it compares,
 *   writes `report.txt` and `sample.json`, and fails on any disagreement.
 */
class MergeDifferentialTest {

    private val json = Json { prettyPrint = false }

    // The checked-in sample

    private fun sample(): JsonObject {
        val text = javaClass.getResource("/fixtures/merge/differential-sample.json")?.readText()
            ?: error("fixtures/merge/differential-sample.json is missing")
        return json.parseToJsonElement(text).jsonObject
    }

    @Test fun theCheckedInSwiftAnswersStillHold() {
        val sample = sample()
        val input = fromSampleEncoding(sample.getValue("input").jsonObject)
        val output = fromSampleEncoding(sample.getValue("output").jsonObject)
        val report = MergeDifferential.compare(input, output)
        assertEquals(emptyList(), report.disagreements, report.toString())
        assertTrue((report.counts["merge"] ?: 0) >= 200, "the sample holds at least 200 merge triples: $report")
        for (section in listOf("copy", "tags", "local", "stamp", "inspect")) {
            assertTrue((report.counts[section] ?: 0) > 0, "the sample covers \"$section\"")
        }
    }

    /**
     * What the shipping Swift engine did with concurrent tag edits (`converge` in the
     * sample, two real `SyncEngine`s over `InMemoryTransport`), and the merge step that
     * drives it, recomputed here. See [FieldMerge.mergeTags], "Tag order does not always
     * converge".
     */
    @Test fun swiftsEngineRewritesConcurrentTagAdditionsForeverAndThisMergeTakesTheSameStep() {
        val sample = sample()
        val cases = sample.getValue("input").jsonObject.getValue("converge").jsonArray
        val answers = sample.getValue("output").jsonObject.getValue("converge").jsonArray
        assertEquals(cases.size, answers.size)
        var loops = 0
        for (index in cases.indices) {
            val case = cases[index].jsonObject
            fun tags(o: JsonElement?) = o?.takeIf { it !is JsonNull }?.jsonObject?.getValue("tags")?.jsonArray
                ?.map { MergeDifferential.textOf(it.jsonPrimitive.content) }
            val answer = answers[index].jsonObject
            val lastRound = answer.getValue("submittedPerRound").jsonArray.last().jsonPrimitive.int
            val a = tags(answer["a"])!!
            val b = tags(answer["b"])!!
            if (lastRound == 0) {
                assertEquals(a, b, "a settled pair holds one tag order: $answer")
                continue
            }
            loops += 1
            // Still rewriting: the two devices hold one tag set in two orders, and
            // merging the other's version over one's own keeps one's own.
            assertEquals(a.sorted(), b.sorted(), "$answer")
            assertTrue(a != b, "$answer")
            assertEquals(a, FieldMerge.mergeTags(a, a, b, localWins = false), "device A keeps its order")
            assertEquals(b, FieldMerge.mergeTags(b, b, a, localWins = false), "device B keeps its order")
            assertTrue(tags(case["ancestor"]) != null)
        }
        assertTrue(loops >= 2, "the sample keeps the cases that never settle")
    }

    // The live run

    @Test fun liveRunAgainstSwift() {
        val directory = System.getenv("MERGE_DIFFERENTIAL_DIR")
        assumeTrue("MERGE_DIFFERENTIAL_DIR is not set", !directory.isNullOrEmpty())
        val dir = File(directory!!)
        dir.mkdirs()
        val inputFile = File(dir, "input.json")
        val outputFile = File(dir, "output.json")
        if (!outputFile.exists()) {
            val seed = System.getenv("MERGE_DIFFERENTIAL_SEED")?.toLong() ?: 0x5EED_D1FFL
            val count = System.getenv("MERGE_DIFFERENTIAL_COUNT")?.toInt() ?: 6_000
            inputFile.writeText(json.encodeToString(JsonObject.serializer(), generate(seed, count)))
            return
        }
        val input = json.parseToJsonElement(inputFile.readText()).jsonObject
        val output = json.parseToJsonElement(outputFile.readText()).jsonObject
        val report = MergeDifferential.compare(input, output)
        File(dir, "report.txt").writeText(report.toString())
        File(dir, "sample.json").writeText(json.encodeToString(JsonObject.serializer(), sampleOf(input, output)))
        assertEquals(emptyList(), report.disagreements, report.toString())
    }

    /** The inputs of one live run: [count] triples and everything derived from them. */
    private fun generate(seed: Long, count: Int): JsonObject {
        val generator = MergeGenerator(seed)
        val builder = MergeDifferential.InputBuilder()
        val derived = ArrayList<Triple<SyncEnvelope?, SyncEnvelope?, SyncEnvelope?>>()
        val inspected = ArrayList<SyncEnvelope>()
        repeat(count) { index ->
            val (base, local, remote) = generator.triple()
            builder.merge(base, local, remote)
            listOfNotNull(base, local, remote).forEach { if (inspected.size < count / 2) inspected.add(it) }
            if (local != null && !local.deleted && !local.secure && builder.copy.size < count / 4) {
                builder.copy.add(MergeDifferential.envelopeHex(local))
            }
            if (index % 4 != 0) return@repeat
            // Derived triples, each with Swift's own answer: the mirror, and the result
            // merged with itself and against the side it came from.
            derived.add(Triple(base, remote, local))
            val survivor = try {
                EnvelopeMerge.merge(base, local, remote).survivor
            } catch (_: MergeFailure) {
                null
            }
            if (survivor != null) {
                derived.add(Triple(survivor, survivor, survivor))
                derived.add(Triple(remote, survivor, remote))
                inspected.add(survivor)
            }
        }
        for ((base, local, remote) in derived) builder.merge(base, local, remote)
        for (envelope in inspected) builder.inspect.add(MergeDifferential.envelopeHex(envelope))
        repeat(count / 2) { builder.tags(generator.tagTriple()) }
        repeat(count / 4) { builder.local(generator.localCase()) }
        repeat(count / 2) { builder.stamp.add(JsonPrimitive(MergeDifferential.bits(generator.stamp()))) }
        convergeCases(builder, generator)
        return builder.build()
    }

    private fun convergeCases(builder: MergeDifferential.InputBuilder, generator: MergeGenerator) {
        builder.converge(emptyList(), listOf("z", "y"), listOf("x"), "a")
        builder.converge(emptyList(), listOf("z", "y"), listOf("x"), "b")
        builder.converge(listOf("work"), listOf("work", "urgent"), listOf("work", "draft"), "a")
        builder.converge(listOf("work"), listOf("work", "urgent"), listOf("work", "draft"), "b")
        builder.converge(emptyList(), listOf("b", "a"), emptyList(), "a")
        builder.converge(listOf("original"), listOf("original"), listOf("original", "mobile"), "a")
        repeat(10) {
            val ancestor = generator.tags().filter { it.isNotBlank() }
            builder.converge(
                ancestor, ancestor + generator.tags().filter { it.isNotBlank() },
                ancestor.reversed() + generator.tags().filter { it.isNotBlank() }, if (generator.random.bool()) "a" else "b",
            )
        }
    }

    // The sample: a slice of one live run with Swift's answers

    private val sampleSizes = mapOf("merge" to 240, "copy" to 40, "tags" to 160, "local" to 60, "stamp" to 200, "inspect" to 80)

    private fun sampleOf(input: JsonObject, output: JsonObject): JsonObject {
        val inputs = LinkedHashMap<String, JsonElement>()
        val outputs = LinkedHashMap<String, JsonElement>()
        for ((section, entries) in input) {
            val answers = output.getValue(section).jsonArray
            val limit = sampleSizes[section] ?: entries.jsonArray.size
            val chosen = ArrayList<Int>()
            chosen.addAll(0 until minOf(limit, entries.jsonArray.size))
            if (section == "merge" || section == "stamp") {
                // Every refusal and every deviation beyond the slice as well, up to a bound.
                val extra = entries.jsonArray.indices.drop(limit).filter { index ->
                    val answer = answers[index]
                    answer is JsonObject && answer.containsKey("error") ||
                        section == "merge" && MergeDifferential.mergeResult(entries.jsonArray[index]) != answer
                }
                chosen.addAll(extra.take(60))
            }
            inputs[section] = JsonArray(chosen.map { entries.jsonArray[it] })
            outputs[section] = JsonArray(chosen.map { answers[it] })
        }
        return JsonObject(
            linkedMapOf(
                "format" to JsonPrimitive("merge-differential-sample/1"),
                "notes" to JsonPrimitive(
                    "Inputs generated by MergeGenerator and the answers the Swift tool in " +
                        "tools/swift-interop/checks/merge-differential gave for them. Envelopes are canonical JSON " +
                        "text here (the tool reads and writes hex); everything else is as the tool writes it. " +
                        "Regenerate with run.sh --refresh-sample.",
                ),
                "input" to toSampleEncoding(JsonObject(inputs)),
                "output" to toSampleEncoding(JsonObject(outputs)),
            ),
        )
    }

    // Envelopes are stored as their canonical text in the sample, to keep it readable and small.

    private val envelopeKeys = setOf("base", "local", "remote", "survivor", "copies", "copy")

    private fun toSampleEncoding(document: JsonObject): JsonObject = mapEnvelopes(document) { hex ->
        String(MergeDifferential.unhex(hex), Charsets.UTF_8)
    }

    private fun fromSampleEncoding(document: JsonObject): JsonObject = mapEnvelopes(document) { text ->
        MergeDifferential.hex(text.toByteArray(Charsets.UTF_8))
    }

    private fun mapEnvelopes(document: JsonObject, convert: (String) -> String): JsonObject {
        fun envelope(value: JsonElement): JsonElement = when (value) {
            is JsonPrimitive -> if (value.isString) JsonPrimitive(convert(value.content)) else value
            is JsonArray -> JsonArray(value.map(::envelope))
            else -> value
        }
        fun entry(value: JsonElement, section: String): JsonElement = when {
            section == "copy" && value is JsonPrimitive -> envelope(value)
            section == "inspect" && value is JsonPrimitive -> envelope(value)
            value is JsonObject && (section == "merge" || section == "copy") ->
                JsonObject(value.mapValues { (key, member) -> if (key in envelopeKeys) envelope(member) else member })
            else -> value
        }
        return JsonObject(document.mapValues { (section, entries) -> JsonArray(entries.jsonArray.map { entry(it, section) }) })
    }
}
