package com.khm.snippets.android.data.fake

import com.khm.snippets.android.data.AppSettings
import com.khm.snippets.android.data.AppearanceSettings
import com.khm.snippets.android.data.HintSettings
import com.khm.snippets.android.data.ThemePreference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** [AppSettings] held in memory: every launch starts from the defaults. */
class FakeAppSettings(
    appearance: AppearanceSettings = AppearanceSettings(),
    hints: HintSettings = HintSettings(),
) : AppSettings {
    private val currentAppearance = MutableStateFlow(appearance)
    private val currentHints = MutableStateFlow(hints)

    override val appearance: StateFlow<AppearanceSettings> = currentAppearance.asStateFlow()
    override val hints: StateFlow<HintSettings> = currentHints.asStateFlow()

    override suspend fun setTheme(theme: ThemePreference) = currentAppearance.update { it.copy(theme = theme) }

    override suspend fun setDynamicColor(enabled: Boolean) = currentAppearance.update { it.copy(useDynamicColor = enabled) }

    override suspend fun markSwipeTipShown() = currentHints.update { it.copy(swipeTipShown = true) }

    override suspend fun resetHints() {
        currentHints.value = HintSettings()
    }
}
