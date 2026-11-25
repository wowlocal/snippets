package com.khm.snippets.core.placeholders

import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.search.UtilitiesFixture
import java.time.ZoneId
import java.util.Locale

/** Shared by the placeholder tests. */
internal object PlaceholderTestSupport {

    /** `Locale.availableIdentifiers` on the Mac that emitted the vectors (macOS 27.2). */
    val macLocaleIdentifiers: List<String> by lazy { UtilitiesFixture.lines("swift-available-locales.txt") }

    /**
     * [JvmDateRenderer] with the Mac's list of locales in place of the JVM's, so that
     * which `locale="…"` attributes are accepted is the same as in the Swift vectors.
     */
    class MacLocales(private val delegate: DateRenderer) : DateRenderer by delegate {
        override fun availableLocaleIdentifiers(): Collection<String> = macLocaleIdentifiers
    }

    fun macRenderer(localeTag: String, zone: String): DateRenderer =
        MacLocales(JvmDateRenderer(Locale.forLanguageTag(localeTag), ZoneId.of(zone)))

    /** A renderer that must not be asked to format: for tests of the grammar alone. */
    object GrammarOnly : DateRenderer {
        override fun availableLocaleIdentifiers(): Collection<String> = macLocaleIdentifiers
        override fun add(epochMillis: Long, unit: DateRenderer.Unit, amount: Int): Long? = epochMillis
        override fun format(epochMillis: Long, pattern: String): String = "<$pattern>"
        override fun format(epochMillis: Long, dateStyle: DateRenderer.Style, timeStyle: DateRenderer.Style, localeTag: String?): String =
            "<$dateStyle/$timeStyle/$localeTag>"
    }

    fun appleSeconds(unixSeconds: Double): Double = AppleTime.fromUnixSeconds(unixSeconds)
}
