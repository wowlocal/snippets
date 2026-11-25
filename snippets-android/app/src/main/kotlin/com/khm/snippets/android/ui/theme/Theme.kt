package com.khm.snippets.android.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.platform.LocalContext

/** The user's choice in Settings › Appearance. */
enum class ThemeMode { System, Light, Dark }

/** True where Material You dynamic colour can be offered (Android 12+). */
val isDynamicColorAvailable: Boolean
    get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

/**
 * The Snippets theme.
 *
 * The static brand scheme is the default. With [dynamicColor] on (Android 12+ only) the Material
 * roles come from the wallpaper; the extended colours ([SnippetsTheme.colors]) and the tag
 * palette ([SnippetsTheme.tagPalette]) stay fixed.
 */
@Composable
fun SnippetsTheme(
    themeMode: ThemeMode = ThemeMode.System,
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val darkTheme = when (themeMode) {
        ThemeMode.System -> isSystemInDarkTheme()
        ThemeMode.Light -> false
        ThemeMode.Dark -> true
    }
    SnippetsTheme(darkTheme = darkTheme, dynamicColor = dynamicColor, content = content)
}

/** The Snippets theme with the light or dark choice already resolved. */
@Composable
fun SnippetsTheme(
    darkTheme: Boolean,
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colorScheme: ColorScheme = when {
        dynamicColor && isDynamicColorAvailable -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> SnippetsDarkColorScheme
        else -> SnippetsLightColorScheme
    }
    CompositionLocalProvider(
        LocalSnippetsColors provides if (darkTheme) SnippetsDarkColors else SnippetsLightColors,
        LocalTagPalette provides if (darkTheme) SnippetsDarkTagPalette else SnippetsLightTagPalette,
        LocalSnippetsTypography provides DefaultSnippetsTypography,
        LocalReducedMotion provides rememberReducedMotion(),
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            shapes = SnippetsShapes,
            typography = SnippetsMaterialTypography,
            content = content,
        )
    }
}

/** Accessors for the parts of the theme that Material 3 does not carry. */
object SnippetsTheme {
    /** Extended semantic colours: secure, warning, success. */
    val colors: SnippetsColors
        @Composable @ReadOnlyComposable get() = LocalSnippetsColors.current

    /** Monospace styles. */
    val typography: SnippetsTypography
        @Composable @ReadOnlyComposable get() = LocalSnippetsTypography.current

    /** Tag colours for the current light or dark theme. */
    val tagPalette: TagPalette
        @Composable @ReadOnlyComposable get() = LocalTagPalette.current

    /** True when the system animator duration scale is 0. */
    val reducedMotion: Boolean
        @Composable @ReadOnlyComposable get() = LocalReducedMotion.current
}
