package com.khm.snippets.android.platform

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.khm.snippets.core.clock.AppleTime
import com.khm.snippets.core.placeholders.DateRenderer
import com.khm.snippets.core.placeholders.PlaceholderResolver
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.Locale

/**
 * The core L05 placeholder vectors (six Swift processes: en_US, fr_FR, th_TH in UTC and
 * Europe/Paris) resolved through [IcuDateRenderer] on the device's ICU.
 *
 * The grammar must match Swift exactly, as on the JVM. For output that holds locale text the
 * JVM renderer differs from Swift in 218 recorded cases (`L05-jvm-locale-data-differences.tsv`);
 * this test counts how many of those the device's ICU gets right and requires that ICU gets
 * right every case the JVM gets right. The summary is logged under the tag `L05`, the full
 * list written to `l05-icu-report.txt` in the app's external files directory.
 */
@RunWith(AndroidJUnit4::class)
class IcuDateRendererL05Test {
    private class Environment(val file: String, val locale: String, val zone: String)

    private val environments = listOf(
        Environment("L05-placeholders-en_US-UTC", "en-US", "UTC"),
        Environment("L05-placeholders-en_US-Europe-Paris", "en-US", "Europe/Paris"),
        Environment("L05-placeholders-fr_FR-UTC", "fr-FR", "UTC"),
        Environment("L05-placeholders-fr_FR-Europe-Paris", "fr-FR", "Europe/Paris"),
        Environment("L05-placeholders-th_TH-UTC", "th-TH", "UTC"),
        Environment("L05-placeholders-th_TH-Europe-Paris", "th-TH", "Europe/Paris"),
    )

    /** The emitter's fixed instants, in seconds since 1970. */
    private val nows = mapOf(
        "month-end" to 1_769_902_215.0,
        "dst-eve" to 1_774_699_200.0,
        "leap-day" to 1_709_200_800.0,
        "afternoon" to 1_785_340_805.75,
    )
    private val clipboardText = "Clip {date} 🔑"
    private val assets = InstrumentationRegistry.getInstrumentation().context.assets

    private fun lines(name: String): List<String> =
        assets.open("l05/$name").bufferedReader().readLines().filter { it.isNotEmpty() && !it.startsWith("#") }

    private val macLocales: List<String> by lazy { lines("swift-available-locales.txt") }

    /** Locale availability as on the Mac that emitted the vectors, as the core test does. */
    private inner class MacLocales(private val delegate: DateRenderer) : DateRenderer by delegate {
        override fun availableLocaleIdentifiers(): Collection<String> = macLocales
    }

    private fun cases(file: String): List<JsonObject> {
        val root = assets.open("l05/$file.json").bufferedReader().use { Json.parseToJsonElement(it.readText()) }.jsonObject
        return root.getValue("cases").jsonArray.map { it.jsonObject }.filter { it.getValue("kind").jsonPrimitive.content == "resolve" }
    }

    private fun JsonObject.text(key: String): String {
        val hex = getValue(key).jsonObject.getValue("utf8Hex").jsonPrimitive.content
        return hexText(hex)
    }

    private fun hexText(hex: String): String =
        if (hex == "-") "" else String(ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }, Charsets.UTF_8)

    @Test
    fun resolvesTheL05VectorsOnTheDevicesIcu() {
        // file \t case -> the JVM's (wrong) output for that case
        val jvmDifferences = lines("L05-jvm-locale-data-differences.tsv").map { it.split('\t') }.associate { "${it[0]}\t${it[1]}" to hexText(it[8]) }
        assertEquals(218, jvmDifferences.size)
        var total = 0
        var exact = 0
        val fixed = ArrayList<String>()
        val stillDifferent = ArrayList<String>()
        val newDifferences = ArrayList<String>()
        for (environment in environments) {
            val resolver = PlaceholderResolver(MacLocales(IcuDateRenderer(Locale.forLanguageTag(environment.locale), environment.zone)))
            for (case in cases(environment.file)) {
                total += 1
                val name = case.getValue("name").jsonPrimitive.content
                val label = "${environment.file}/$name"
                val template = case.text("template")
                val now = AppleTime.fromUnixSeconds(nows.getValue(case.getValue("now").jsonPrimitive.content))
                var clipboardReads = 0
                val resolved = resolver.resolve(template, clipboard = { clipboardReads += 1; clipboardText }, now = { now })
                // The grammar is never a matter of locale data.
                assertEquals(label, case.getValue("clipboardReads").jsonPrimitive.int, clipboardReads)
                assertEquals(label, case.getValue("containsResolvablePlaceholder").jsonPrimitive.boolean, resolver.containsResolvablePlaceholder(template))
                assertEquals(label, case.getValue("unchanged").jsonPrimitive.boolean, resolved == template)
                val expected = case.text("resolved")
                val key = "${environment.file}\t$name"
                val listed = key in jvmDifferences
                if (resolved == expected) {
                    exact += 1
                    if (listed) fixed += key
                } else if (listed) {
                    stillDifferent += "$label: ${scalars(template)} expected ${scalars(expected)} icu ${scalars(resolved)} jvm ${scalars(jvmDifferences.getValue(key))}"
                } else {
                    newDifferences += "$label: ${scalars(template)} expected ${scalars(expected)} icu ${scalars(resolved)}"
                }
            }
        }
        val summary = "L05 on ICU: $exact of $total exact; ${fixed.size} of ${jvmDifferences.size} JVM differences disappear, ${stillDifferent.size} remain, ${newDifferences.size} new"
        Log.i(TAG, summary)
        // The full list is too long for logcat; it goes to the app's external files directory.
        val report = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "l05-icu-report.txt")
        report.writeText(buildString {
            appendLine(summary)
            fixed.forEach { appendLine("fixed ${it.replace('\t', '/')}") }
            stillDifferent.forEach { appendLine("remaining $it") }
            newDifferences.forEach { appendLine("new $it") }
        })
        assertEquals(6 * 317, total)
        // The device's ICU gets right everything the JVM gets right, and more.
        assertTrue("ICU differs where the JVM matches Swift:\n${newDifferences.take(20).joinToString("\n")}", newDifferences.isEmpty())
        assertTrue("ICU exact $exact < JVM exact ${total - jvmDifferences.size}", exact >= total - jvmDifferences.size)
    }

    private fun scalars(text: String): String = buildString {
        append('"')
        var index = 0
        while (index < text.length) {
            val scalar = text.codePointAt(index)
            if (scalar in 0x20..0x7E) appendCodePoint(scalar) else append("\\u{").append(scalar.toString(16)).append('}')
            index += Character.charCount(scalar)
        }
        append('"')
    }

    private companion object {
        const val TAG = "L05"
    }
}
