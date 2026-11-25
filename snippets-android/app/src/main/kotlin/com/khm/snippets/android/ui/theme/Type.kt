package com.khm.snippets.android.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.isSpecified
import androidx.compose.ui.unit.sp
import com.khm.snippets.android.R
import kotlin.math.min

@OptIn(ExperimentalTextApi::class)
private fun jetBrainsMono(weight: FontWeight): Font = Font(
    resId = R.font.jetbrains_mono,
    weight = weight,
    variationSettings = FontVariation.Settings(FontVariation.weight(weight.weight)),
)

/**
 * Bundled JetBrains Mono (variable font, weights 400 to 600). Glyphs it lacks fall back to the
 * system fonts. Sans text uses [FontFamily.Default].
 */
val JetBrainsMono: FontFamily = FontFamily(
    jetBrainsMono(FontWeight.Normal),
    jetBrainsMono(FontWeight.Medium),
    jetBrainsMono(FontWeight.SemiBold),
)

/** Material 3 roles (DESIGN.md §6.1). Sizes are the M3 defaults; the device sans font is kept. */
val SnippetsMaterialTypography: Typography = Typography().run {
    copy(
        headlineSmall = headlineSmall.copy(fontSize = 24.sp, lineHeight = 32.sp, fontWeight = FontWeight.Normal),
        titleLarge = titleLarge.copy(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Normal),
        titleMedium = titleMedium.copy(fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.Medium),
        titleSmall = titleSmall.copy(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium),
        bodyLarge = bodyLarge.copy(fontSize = 16.sp, lineHeight = 24.sp, fontWeight = FontWeight.Normal),
        bodyMedium = bodyMedium.copy(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal),
        bodySmall = bodySmall.copy(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Normal),
        labelLarge = labelLarge.copy(fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium),
        labelMedium = labelMedium.copy(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium),
        labelSmall = labelSmall.copy(fontSize = 11.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium),
    )
}

/** Ligatures are off in every monospace style so `0 O 1 l I` and operators stay literal. */
private const val MONO_FEATURES = "liga 0, calt 0"

/** Tabular digits, for texts that tick (the countdown row). */
const val TABULAR_DIGITS_FEATURES = "tnum"

/** Monospace styles (DESIGN.md §6.2), exposed through [LocalSnippetsTypography]. */
@Immutable
data class SnippetsTypography(
    /** Snippet body field, placeholder preview, link-review preview. */
    val monoBody: TextStyle,
    /** Keyword token, keyword field, `Existing ·` line, suggestion chips. */
    val monoToken: TextStyle,
    /** SSH public key, fingerprints, failure codes. */
    val monoKey: TextStyle,
    /** Recovery key, recovery code, account key. Use [cappedAtFontScale] where it is drawn. */
    val monoCode: TextStyle,
    /** Pairing confirmation code (short codes only). */
    val monoCodeLarge: TextStyle,
    /** Input style of recovery key and code fields: `monoToken` at 16 sp. */
    val monoField: TextStyle,
)

private fun monoStyle(
    size: TextUnit,
    lineHeight: TextUnit,
    weight: FontWeight,
    letterSpacing: TextUnit = 0.sp,
) = TextStyle(
    fontFamily = JetBrainsMono,
    fontSize = size,
    lineHeight = lineHeight,
    fontWeight = weight,
    letterSpacing = letterSpacing,
    fontFeatureSettings = MONO_FEATURES,
)

val DefaultSnippetsTypography = SnippetsTypography(
    monoBody = monoStyle(14.sp, 20.sp, FontWeight.Normal),
    monoToken = monoStyle(13.sp, 20.sp, FontWeight.Medium),
    monoKey = monoStyle(13.sp, 20.sp, FontWeight.Normal),
    monoCode = monoStyle(22.sp, 32.sp, FontWeight.SemiBold, letterSpacing = 0.5.sp),
    monoCodeLarge = monoStyle(28.sp, 36.sp, FontWeight.SemiBold, letterSpacing = 1.sp),
    monoField = monoStyle(16.sp, 24.sp, FontWeight.Medium),
)

val LocalSnippetsTypography = staticCompositionLocalOf { DefaultSnippetsTypography }

/** The largest font scale applied to `monoCode`, so a four-symbol group never breaks. */
const val MONO_CODE_MAX_FONT_SCALE = 1.3f

/** Factor that turns an `sp` value into one that stops growing at [maxScale]. */
fun fontScaleCapFactor(fontScale: Float, maxScale: Float): Float =
    if (fontScale <= 0f) 1f else min(fontScale, maxScale) / fontScale

/** This style with its `sp` sizes capped at [maxScale] times their nominal size. */
@Composable
fun TextStyle.cappedAtFontScale(maxScale: Float = MONO_CODE_MAX_FONT_SCALE): TextStyle {
    val factor = fontScaleCapFactor(LocalDensity.current.fontScale, maxScale)
    if (factor == 1f) return this
    return copy(
        fontSize = fontSize.scaledBy(factor),
        lineHeight = lineHeight.scaledBy(factor),
        letterSpacing = letterSpacing.scaledBy(factor),
    )
}

private fun TextUnit.scaledBy(factor: Float): TextUnit = if (isSpecified && isSp) (value * factor).sp else this
