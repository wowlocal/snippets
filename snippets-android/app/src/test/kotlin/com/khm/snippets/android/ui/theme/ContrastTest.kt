package com.khm.snippets.android.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

/**
 * Recomputes the WCAG 2.x contrast of every pair listed in DESIGN.md §5.4 from the colour
 * constants the theme really uses, and holds each to the ratio the specification states.
 */
class ContrastTest {
    private class Theme(val name: String, val scheme: ColorScheme, val extended: SnippetsColors, val tags: TagPalette)

    private val light = Theme("light", SnippetsLightColorScheme, SnippetsLightColors, SnippetsLightTagPalette)
    private val dark = Theme("dark", SnippetsDarkColorScheme, SnippetsDarkColors, SnippetsDarkTagPalette)

    private class Pair(
        val name: String,
        val statedLight: Double,
        val statedDark: Double,
        val isText: Boolean = true,
        val colors: (Theme) -> kotlin.Pair<Color, Color>,
    )

    private val pairs = listOf(
        Pair("onSurface on surface", 16.30, 14.32) { it.scheme.onSurface to it.scheme.surface },
        Pair("onSurface on surfaceContainerHigh", 14.01, 11.18) { it.scheme.onSurface to it.scheme.surfaceContainerHigh },
        Pair("onSurface on surfaceContainerHighest", 13.25, 9.56) { it.scheme.onSurface to it.scheme.surfaceContainerHighest },
        Pair("onSurface on secondaryContainer", 13.26, 7.25) { it.scheme.onSurface to it.scheme.secondaryContainer },
        Pair("onSurfaceVariant on surface", 8.94, 10.90) { it.scheme.onSurfaceVariant to it.scheme.surface },
        Pair("onSurfaceVariant on surfaceContainer", 8.06, 9.65) { it.scheme.onSurfaceVariant to it.scheme.surfaceContainer },
        Pair("onSurfaceVariant on surfaceContainerHigh", 7.68, 8.51) { it.scheme.onSurfaceVariant to it.scheme.surfaceContainerHigh },
        Pair("onSurfaceVariant on surfaceContainerHighest", 7.27, 7.27) { it.scheme.onSurfaceVariant to it.scheme.surfaceContainerHighest },
        Pair("onSurfaceVariant on secondaryContainer", 7.27, 5.51) { it.scheme.onSurfaceVariant to it.scheme.secondaryContainer },
        Pair("primary on surface", 6.16, 10.89) { it.scheme.primary to it.scheme.surface },
        Pair("primary on surfaceContainerHighest", 5.00, 7.27) { it.scheme.primary to it.scheme.surfaceContainerHighest },
        Pair("primary on secondaryContainer", 5.01, 5.51) { it.scheme.primary to it.scheme.secondaryContainer },
        Pair("onPrimary on primary", 6.47, 7.74) { it.scheme.onPrimary to it.scheme.primary },
        Pair("onPrimaryContainer on primaryContainer", 7.24, 7.24) { it.scheme.onPrimaryContainer to it.scheme.primaryContainer },
        Pair("onSecondaryContainer on secondaryContainer", 7.25, 7.25) { it.scheme.onSecondaryContainer to it.scheme.secondaryContainer },
        Pair("onTertiaryContainer on tertiaryContainer", 7.27, 7.27) { it.scheme.onTertiaryContainer to it.scheme.tertiaryContainer },
        Pair("error on surface", 6.15, 10.90) { it.scheme.error to it.scheme.surface },
        Pair("error on surfaceContainerHigh", 5.28, 8.51) { it.scheme.error to it.scheme.surfaceContainerHigh },
        Pair("onError on error", 6.46, 7.72) { it.scheme.onError to it.scheme.error },
        Pair("onErrorContainer on errorContainer", 7.24, 7.24) { it.scheme.onErrorContainer to it.scheme.errorContainer },
        Pair("inverseOnSurface on inverseSurface", 11.54, 10.13) { it.scheme.inverseOnSurface to it.scheme.inverseSurface },
        Pair("inversePrimary on inverseSurface", 7.71, 5.00) { it.scheme.inversePrimary to it.scheme.inverseSurface },
        Pair("secure on surface", 6.18, 10.86) { it.extended.secure to it.scheme.surface },
        Pair("secure on surfaceContainerHighest", 5.02, 7.25) { it.extended.secure to it.scheme.surfaceContainerHighest },
        Pair("secure on secondaryContainer", 5.03, 5.49) { it.extended.secure to it.scheme.secondaryContainer },
        Pair("onSecureContainer on secureContainer", 7.26, 7.26) { it.extended.onSecureContainer to it.extended.secureContainer },
        Pair("warning on surface", 6.16, 10.87) { it.extended.warning to it.scheme.surface },
        Pair("warning on surfaceContainerHighest", 5.01, 7.26) { it.extended.warning to it.scheme.surfaceContainerHighest },
        Pair("onWarningContainer on warningContainer", 7.23, 7.23) { it.extended.onWarningContainer to it.extended.warningContainer },
        Pair("success on surface", 6.15, 10.85) { it.extended.success to it.scheme.surface },
        Pair("success on surfaceContainerHighest", 5.00, 7.24) { it.extended.success to it.scheme.surfaceContainerHighest },
        Pair("outline on surface", 4.25, 5.84, isText = false) { it.scheme.outline to it.scheme.surface },
        Pair("outline on surfaceContainerHigh", 3.65, 4.56, isText = false) { it.scheme.outline to it.scheme.surfaceContainerHigh },
    )

    @Test
    fun everyListedPairReachesItsStatedRatio() {
        val failures = ArrayList<String>()
        for (pair in pairs) {
            for ((theme, stated) in listOf(light to pair.statedLight, dark to pair.statedDark)) {
                val (foreground, background) = pair.colors(theme)
                val ratio = contrast(foreground, background)
                // The specification states ratios to two decimals.
                if (ratio < stated - ROUNDING) failures += "${pair.name} (${theme.name}): %.3f < %.2f".format(ratio, stated)
            }
        }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    @Test
    fun everyTextPairIsAtLeastFourPointFive() {
        for (pair in pairs.filter { it.isText }) {
            for (theme in listOf(light, dark)) {
                val (foreground, background) = pair.colors(theme)
                val ratio = contrast(foreground, background)
                assertTrue("${pair.name} (${theme.name}) is $ratio", ratio >= 4.5)
            }
        }
    }

    @Test
    fun nonTextPairsAreAtLeastThree() {
        for (pair in pairs.filterNot { it.isText }) {
            for (theme in listOf(light, dark)) {
                val (foreground, background) = pair.colors(theme)
                assertTrue("${pair.name} (${theme.name})", contrast(foreground, background) >= 3.0)
            }
        }
    }

    @Test
    fun worstTagTextOnItsFillReachesTheStatedRatio() {
        val worstLight = light.tags.slots.minOf { contrast(it.text, it.fill) }
        val worstDark = dark.tags.slots.minOf { contrast(it.text, it.fill) }
        assertTrue("light: $worstLight", worstLight >= 4.87 - ROUNDING)
        assertTrue("dark: $worstDark", worstDark >= 8.35 - ROUNDING)
        (light.tags.slots + dark.tags.slots).forEach { slot ->
            assertTrue(contrast(slot.text, slot.fill) >= 4.5)
        }
    }

    @Test
    fun tagFillsAreOpaque() {
        (light.tags.slots + dark.tags.slots).forEach { assertEquals(1f, it.fill.alpha, 0f) }
    }

    @Test
    fun conflictPillUsesTheWarningContainerPair() {
        for (theme in listOf(light, dark)) {
            assertTrue(contrast(theme.extended.onWarningContainer, theme.extended.warningContainer) >= 4.5)
        }
    }

    @Test
    fun contrastFormulaMatchesTheWcagReferencePoints() {
        assertEquals(21.0, contrast(Color.Black, Color.White), 0.0001)
        assertEquals(1.0, contrast(Color.White, Color.White), 0.0001)
        // #767676 on white is the well-known 4.54:1 boundary grey.
        assertEquals(4.54, contrast(Color(0xFF767676), Color.White), 0.005)
    }

    private fun contrast(first: Color, second: Color): Double {
        val a = luminance(first)
        val b = luminance(second)
        return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
    }

    private fun luminance(color: Color): Double {
        val argb = color.toArgb()
        fun channel(value: Int): Double {
            val srgb = value / 255.0
            return if (srgb <= 0.03928) srgb / 12.92 else ((srgb + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * channel((argb shr 16) and 0xff) +
            0.7152 * channel((argb shr 8) and 0xff) +
            0.0722 * channel(argb and 0xff)
    }

    private companion object {
        /** Half of the last stated decimal. */
        const val ROUNDING = 0.005
    }
}
