package com.khm.snippets.android.data

import kotlinx.coroutines.flow.StateFlow

/** The theme choice of Settings › Appearance. */
enum class ThemePreference { System, Light, Dark }

/** @param useDynamicColor Material You; honoured on Android 12+ only, off by default. */
data class AppearanceSettings(
    val theme: ThemePreference = ThemePreference.System,
    val useDynamicColor: Boolean = false,
)

/** One-time hints that were already shown on this install. */
data class HintSettings(val swipeTipShown: Boolean = false)

/** Preferences that are not part of the library. Everything is observable and main-safe. */
interface AppSettings {
    val appearance: StateFlow<AppearanceSettings>
    val hints: StateFlow<HintSettings>

    suspend fun setTheme(theme: ThemePreference)
    suspend fun setDynamicColor(enabled: Boolean)

    /** The swipe tip was shown; it never shows again. */
    suspend fun markSwipeTipShown()

    /** Shows every one-time hint again (UI-test reset). */
    suspend fun resetHints()
}
