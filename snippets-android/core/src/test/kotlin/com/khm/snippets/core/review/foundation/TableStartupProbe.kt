package com.khm.snippets.core.review.foundation

import com.khm.snippets.core.model.SnippetTagging
import com.khm.snippets.core.text.FoundationText
import java.lang.management.ManagementFactory

/**
 * Run in a fresh JVM by [TableStartupTest]: the cost of the first fold and the first
 * grapheme segmentation, which is when the two generated tables are parsed.
 */
object TableStartupProbe {

    private fun allocated(): Long {
        val bean = ManagementFactory.getThreadMXBean() as com.sun.management.ThreadMXBean
        return bean.getThreadAllocatedBytes(Thread.currentThread().id)
    }

    @JvmStatic
    fun main(arguments: Array<String>) {
        // Touch the classes that any app start loads anyway, so only the tables are measured.
        FoundationText.trimWhitespaceAndNewlines(" a ")
        FoundationText.fold("abc")
        val latin = ReviewFixture.text("0043 0061 0066 00E9")
        val combining = ReviewFixture.text("0065 0301 0078")
        val mixed = ReviewFixture.text("0043 0061 0066 00E9 0020 0915 093C")

        var bytes = allocated()
        var start = System.nanoTime()
        if (arguments.contains("read-first")) {
            // Separates opening and reading the resource from parsing it.
            val raw = TableStartupProbe::class.java.getResourceAsStream("/com/khm/snippets/core/text/foundation-fold.txt")!!.use { it.readBytes() }
            println("resource_read_ms=%.2f bytes=%d".format((System.nanoTime() - start) / 1e6, raw.size))
            bytes = allocated()
            start = System.nanoTime()
        }
        SnippetTagging.filterKey(latin)
        val foldNanos = System.nanoTime() - start
        val foldBytes = allocated() - bytes

        bytes = allocated()
        start = System.nanoTime()
        FoundationText.characterCount(combining)
        val graphemeNanos = System.nanoTime() - start
        val graphemeBytes = allocated() - bytes

        start = System.nanoTime()
        repeat(1000) { SnippetTagging.filterKey(mixed) }
        val warmNanos = (System.nanoTime() - start) / 1000

        println("fold_first_ms=%.2f fold_first_alloc_kb=%d grapheme_first_ms=%.2f grapheme_first_alloc_kb=%d fold_warm_us=%.2f".format(
            foldNanos / 1e6, foldBytes / 1024, graphemeNanos / 1e6, graphemeBytes / 1024, warmNanos / 1e3))
    }
}
