package com.khm.snippets.android.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * The static brand scheme (DESIGN.md §5.1). Seed `#6D5EF5`; the values are literals and are
 * never generated at run time.
 */
val SnippetsLightColorScheme: ColorScheme = lightColorScheme(
    primary = Color(0xFF5544DC),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFE4DFFF),
    onPrimaryContainer = Color(0xFF3C24C5),
    inversePrimary = Color(0xFFC5C0FF),
    secondary = Color(0xFF5E5C74),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFE4DFFC),
    onSecondaryContainer = Color(0xFF46445C),
    tertiary = Color(0xFF874780),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFFFD7F5),
    onTertiaryContainer = Color(0xFF6C2F67),
    error = Color(0xFFBA1A1A),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF93000A),
    background = Color(0xFFFCF8FD),
    onBackground = Color(0xFF1C1B1F),
    surface = Color(0xFFFCF8FD),
    onSurface = Color(0xFF1C1B1F),
    surfaceVariant = Color(0xFFE5E0ED),
    onSurfaceVariant = Color(0xFF474550),
    surfaceTint = Color(0xFF5544DC),
    inverseSurface = Color(0xFF313034),
    inverseOnSurface = Color(0xFFF4EFF4),
    outline = Color(0xFF787681),
    outlineVariant = Color(0xFFC8C5D1),
    scrim = Color(0xFF000000),
    surfaceDim = Color(0xFFDDD9DD),
    surfaceBright = Color(0xFFFCF8FD),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFF6F2F7),
    surfaceContainer = Color(0xFFF1ECF1),
    surfaceContainerHigh = Color(0xFFEBE7EC),
    surfaceContainerHighest = Color(0xFFE5E1E6),
)

val SnippetsDarkColorScheme: ColorScheme = darkColorScheme(
    primary = Color(0xFFC5C0FF),
    onPrimary = Color(0xFF2600A1),
    primaryContainer = Color(0xFF3C24C5),
    onPrimaryContainer = Color(0xFFE4DFFF),
    inversePrimary = Color(0xFF5544DC),
    secondary = Color(0xFFC7C3E0),
    onSecondary = Color(0xFF302E44),
    secondaryContainer = Color(0xFF46445C),
    onSecondaryContainer = Color(0xFFE4DFFC),
    tertiary = Color(0xFFFBADEE),
    onTertiary = Color(0xFF52184F),
    tertiaryContainer = Color(0xFF6C2F67),
    onTertiaryContainer = Color(0xFFFFD7F5),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = Color(0xFF141316),
    onBackground = Color(0xFFE5E1E6),
    surface = Color(0xFF141316),
    onSurface = Color(0xFFE5E1E6),
    surfaceVariant = Color(0xFF474550),
    onSurfaceVariant = Color(0xFFC8C5D1),
    surfaceTint = Color(0xFFC5C0FF),
    inverseSurface = Color(0xFFE5E1E6),
    inverseOnSurface = Color(0xFF313034),
    outline = Color(0xFF928F9B),
    outlineVariant = Color(0xFF474550),
    scrim = Color(0xFF000000),
    surfaceDim = Color(0xFF141316),
    surfaceBright = Color(0xFF3A393C),
    surfaceContainerLowest = Color(0xFF0E0E11),
    surfaceContainerLow = Color(0xFF1C1B1F),
    surfaceContainer = Color(0xFF201F23),
    surfaceContainerHigh = Color(0xFF2A292D),
    surfaceContainerHighest = Color(0xFF353438),
)

/**
 * Extended semantic colours (DESIGN.md §5.2). They stay fixed when dynamic colour is on.
 *
 * `secure` is never used without a lock icon or the word "Secure"; `warning` never without a
 * warning icon or a title.
 */
@Immutable
data class SnippetsColors(
    val secure: Color,
    val onSecure: Color,
    val secureContainer: Color,
    val onSecureContainer: Color,
    val warning: Color,
    val onWarning: Color,
    val warningContainer: Color,
    val onWarningContainer: Color,
    val success: Color,
    val onSuccess: Color,
    val successContainer: Color,
    val onSuccessContainer: Color,
)

val SnippetsLightColors = SnippetsColors(
    secure = Color(0xFF7D5700),
    onSecure = Color(0xFFFFFFFF),
    secureContainer = Color(0xFFFFDEAB),
    onSecureContainer = Color(0xFF5F4100),
    warning = Color(0xFF9B4500),
    onWarning = Color(0xFFFFFFFF),
    warningContainer = Color(0xFFFFDBC9),
    onWarningContainer = Color(0xFF763300),
    success = Color(0xFF216C2E),
    onSuccess = Color(0xFFFFFFFF),
    successContainer = Color(0xFFA7F5A7),
    onSuccessContainer = Color(0xFF00531A),
)

val SnippetsDarkColors = SnippetsColors(
    secure = Color(0xFFFFBA30),
    onSecure = Color(0xFF422C00),
    secureContainer = Color(0xFF5F4100),
    onSecureContainer = Color(0xFFFFDEAB),
    warning = Color(0xFFFFB68E),
    onWarning = Color(0xFF532200),
    warningContainer = Color(0xFF763300),
    onWarningContainer = Color(0xFFFFDBC9),
    success = Color(0xFF8BD88D),
    onSuccess = Color(0xFF00390F),
    successContainer = Color(0xFF00531A),
    onSuccessContainer = Color(0xFFA7F5A7),
)

val LocalSnippetsColors = staticCompositionLocalOf { SnippetsLightColors }
