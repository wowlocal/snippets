package com.khm.snippets.core.review.crypto

import org.junit.Assume.assumeTrue
import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The reviewer's exchange with the Swift recorder. Skipped unless `REVIEW_CRYPTO_XCHECK_DIR`
 * names an existing directory.
 *
 * 1. `exportInputs` writes `<group>.in.tsv` there (`REVIEW_CRYPTO_SCALE` widens the random
 *    part; `REVIEW_CRYPTO_SWEEP=1` adds every Unicode scalar).
 * 2. `xcheck judge < group.in.tsv > group.out.tsv` records what Swift does.
 * 3. `compareRecorded` reads every `*.out.tsv` there and writes `<group>.diff.tsv`.
 *
 * The checked-in fixtures are the scale-1 `*.out.tsv`, gzipped.
 */
class ReviewExchangeTest {

    @Test
    fun exportInputs() {
        val directory = ReviewCrypto.exchangeDirectory
        assumeTrue("REVIEW_CRYPTO_XCHECK_DIR is not set", directory != null)
        val scale = System.getenv("REVIEW_CRYPTO_SCALE")?.toIntOrNull() ?: 1
        val inputs = ReviewInputs(scale)
        for ((group, make) in ReviewInputs.groups) {
            File(directory, "$group.in.tsv").writeText(make(inputs).joinToString("\n", postfix = "\n"))
        }
        if (System.getenv("REVIEW_CRYPTO_SWEEP") == "1") {
            File(directory, "sweep.in.tsv").bufferedWriter().use { writer ->
                for (line in inputs.everyScalar()) writer.append(line).append('\n')
            }
        }
    }

    @Test
    fun compareRecorded() {
        val directory = ReviewCrypto.exchangeDirectory
        assumeTrue("REVIEW_CRYPTO_XCHECK_DIR is not set", directory != null)
        val recorded = directory!!.listFiles { file -> file.name.endsWith(".out.tsv") }.orEmpty().sortedBy { it.name }
        assumeTrue("no recorded verdicts yet", recorded.isNotEmpty())
        val summary = StringBuilder()
        var disagreements = 0
        for (file in recorded) {
            var checked = 0
            val perKind = sortedMapOf<String, IntArray>()
            File(directory, file.name.removeSuffix(".out.tsv") + ".diff.tsv").bufferedWriter().use { diff ->
                file.useLines { lines ->
                    for (line in lines) {
                        if (line.isEmpty()) continue
                        val fields = line.split('\t')
                        val counts = perKind.getOrPut(fields[0]) { IntArray(2) }
                        counts[0] += 1
                        checked += 1
                        val actual = KotlinJudge.disagreement(fields.dropLast(1), fields.last()) ?: continue
                        counts[1] += 1
                        disagreements += 1
                        diff.append(line).append('\t').append(actual).append('\n')
                    }
                }
            }
            summary.append("${file.name}: $checked checked\n")
            for ((kind, counts) in perKind) summary.append("  $kind: ${counts[0]} checked, ${counts[1]} disagree\n")
        }
        File(directory, "summary.txt").writeText(summary.toString())
        assertTrue(disagreements == 0, "the port disagrees with Swift on $disagreements recorded lines:\n$summary")
    }
}
