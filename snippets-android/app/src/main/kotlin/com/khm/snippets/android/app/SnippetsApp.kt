package com.khm.snippets.android.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.khm.snippets.android.data.ThemePreference
import com.khm.snippets.android.data.UndoToken
import com.khm.snippets.android.feature.secure.RecoveryKeyHost
import com.khm.snippets.android.feature.shared.LocalAppSnackbars
import com.khm.snippets.android.feature.shared.rememberAppSnackbars
import com.khm.snippets.android.nav.LocalWindowLayout
import com.khm.snippets.android.nav.windowLayoutOf
import com.khm.snippets.android.ui.components.rememberSnackbarController
import com.khm.snippets.android.ui.theme.SnippetsTheme
import com.khm.snippets.android.ui.theme.ThemeMode

/**
 * The root of the UI: theme from Settings › Appearance, the window layout of DESIGN.md §4, the
 * window's snackbars, the navigation host and the recovery-key screen over everything.
 *
 * The layout comes from the size the root is given, which is the window: tests can force any
 * size or rotation (`DeviceConfigurationOverride`) and get the layout that window would have.
 */
@Composable
fun SnippetsApp(container: AppContainer) {
    val appearance by container.settings.appearance.collectAsStateWithLifecycle()
    SnippetsTheme(
        themeMode = when (appearance.theme) {
            ThemePreference.System -> ThemeMode.System
            ThemePreference.Light -> ThemeMode.Light
            ThemePreference.Dark -> ThemeMode.Dark
        },
        dynamicColor = appearance.useDynamicColor,
    ) {
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surface)
                .semantics { testTagsAsResourceId = true },
        ) {
            val layout = windowLayoutOf(maxWidth, maxHeight)
            val controller = rememberSnackbarController()
            val onUndo: (UndoToken) -> Unit = remember(container) { { token -> container.operations.undoDelete(token) } }
            val snackbars = rememberAppSnackbars(controller, onUndo)
            CompositionLocalProvider(LocalWindowLayout provides layout, LocalAppSnackbars provides snackbars) {
                SnippetsNavHost(container, layout)
                RecoveryKeyHost(container.recoveryKeys, container.clipboard)
            }
        }
    }
}
