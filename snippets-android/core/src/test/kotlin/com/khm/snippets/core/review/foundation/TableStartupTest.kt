package com.khm.snippets.core.review.foundation

import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Review: what the lazily parsed tables cost on first use. Measured in a fresh JVM, once
 * with the JIT and once interpreted (`-Xint`), which is nearer to a cold start on a phone.
 * The numbers are printed; the bound only catches a regression by an order of magnitude.
 */
class TableStartupTest {

    private fun probe(vararg jvmOptions: String): Map<String, Double> {
        val java = File(System.getProperty("java.home"), "bin/java").path
        val command = listOf(java) + jvmOptions + listOf("-cp", System.getProperty("java.class.path"), TableStartupProbe::class.java.name)
        val process = ProcessBuilder(command).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        assertTrue(process.waitFor(120, TimeUnit.SECONDS), "probe did not finish")
        assertEquals(0, process.exitValue(), output)
        val line = output.lineSequence().first { it.startsWith("fold_first_ms") }
        return line.split(' ').associate { it.substringBefore('=') to it.substringAfter('=').toDouble() }
    }

    @Test
    fun firstUseOfTheTablesIsCheapEnoughForAppStart() {
        val runs = (1..5).map { probe() }
        val interpreted = (1..3).map { probe("-Xint") }
        fun median(values: List<Double>) = values.sorted()[values.size / 2]
        val fold = median(runs.map { it.getValue("fold_first_ms") })
        val grapheme = median(runs.map { it.getValue("grapheme_first_ms") })
        val foldInterpreted = median(interpreted.map { it.getValue("fold_first_ms") })
        val graphemeInterpreted = median(interpreted.map { it.getValue("grapheme_first_ms") })
        println(
            "review: first fold %.1f ms (%.0f KB allocated), first grapheme %.1f ms (%.0f KB); interpreted %.1f ms and %.1f ms; warm fold %.2f us".format(
                fold, runs[0].getValue("fold_first_alloc_kb"), grapheme, runs[0].getValue("grapheme_first_alloc_kb"),
                foldInterpreted, graphemeInterpreted, median(runs.map { it.getValue("fold_warm_us") }),
            ),
        )
        assertTrue(fold + grapheme < 250.0, "first use of the tables took ${fold + grapheme} ms")
    }
}
